#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Inputs (set by GitHub Actions from action.yml `inputs`)
# ---------------------------------------------------------------------------
# Sanitize: replace / with - so raw values like "upbound/provider-upjet-aws"
# or "refs/heads/main" are safe to use as S3 key path segments.
REPOSITORY="$(echo "${INPUT_REPOSITORY}" | tr '/' '-')"
BRANCH="$(echo "${INPUT_BRANCH}" | tr '/' '-')"
KEY="${INPUT_KEY}"
RESTORE_KEYS="${INPUT_RESTORE_KEYS:-}"
BUCKET="${INPUT_BUCKET}"
AWS_REGION="${INPUT_AWS_REGION:-us-east-1}"
CACHE_PATH="${INPUT_PATH:-}"

# ---------------------------------------------------------------------------
# Resolve cache path — use explicit path input or fall back to GOCACHE
# ---------------------------------------------------------------------------
if [[ -n "${CACHE_PATH}" ]]; then
  CACHE_DIR="${CACHE_PATH}"
  echo "Cache path (explicit): ${CACHE_DIR}"
else
  CACHE_DIR="$(go env GOCACHE)"
  echo "Cache path (GOCACHE): ${CACHE_DIR}"
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
TEMP_ARCHIVE="/tmp/go-build-cache-$$.tar.zst"

# CACHE_HIT=true only on exact key match
# RESTORED=true on any successful extraction (exact or fallback)
CACHE_HIT="false"
RESTORED="false"

s3_object_exists() {
  aws s3api head-object \
    --bucket "${BUCKET}" \
    --key "$1" \
    --region "${AWS_REGION}" \
    --output json > /dev/null 2>&1
}

download_and_extract() {
  local object_key="$1"
  echo "Downloading s3://${BUCKET}/${object_key} ..."
  aws s3 cp "s3://${BUCKET}/${object_key}" "${TEMP_ARCHIVE}" \
    --region "${AWS_REGION}"

  local archive_size
  archive_size="$(du -sh "${TEMP_ARCHIVE}" | cut -f1)"
  echo "Archive size: ${archive_size}"

  echo "Extracting into $(dirname "${CACHE_DIR}") ..."
  mkdir -p "$(dirname "${CACHE_DIR}")"
  tar --zstd -xf "${TEMP_ARCHIVE}" -C "$(dirname "${CACHE_DIR}")"
  rm -f "${TEMP_ARCHIVE}"
  echo "Extraction complete: ${CACHE_DIR}"
}

# ---------------------------------------------------------------------------
# S3 object layout: <repository>/<branch>/<key>.tar.zst
# Exact key lookup
# ---------------------------------------------------------------------------
EXACT_OBJECT="${REPOSITORY}/${BRANCH}/${KEY}.tar.zst"
echo "::group::Restore Go Build Cache"
echo "Trying exact key: s3://${BUCKET}/${EXACT_OBJECT}"

if s3_object_exists "${EXACT_OBJECT}"; then
  echo "Exact cache hit!"
  download_and_extract "${EXACT_OBJECT}"
  CACHE_HIT="true"
  RESTORED="true"
else
  echo "Exact key not found."
fi

# ---------------------------------------------------------------------------
# Fallback prefix search
# Tier 1 (caller-supplied restore-keys): same branch prefixes, then any-branch
# prefixes — searched under <repository>/<branch>/ and <repository>/ respectively.
# The caller controls the fallback order via restore-keys.
# ---------------------------------------------------------------------------
if [[ "${RESTORED}" == "false" ]] && [[ -n "${RESTORE_KEYS}" ]]; then
  echo "Trying restore-key prefixes..."
  while IFS= read -r prefix; do
    prefix="$(echo "${prefix}" | xargs)"
    [[ -z "${prefix}" ]] && continue

    # Prefix is always scoped under <repository>/<branch>/ — fallback is
    # limited to the same branch. Cross-branch fallback is not supported
    # via restore-keys; add a separate action step for that if needed.
    S3_PREFIX="${REPOSITORY}/${BRANCH}/${prefix}"
    echo "  Searching prefix: s3://${BUCKET}/${S3_PREFIX}*"

    if ! latest_key="$(aws s3api list-objects-v2 \
      --bucket "${BUCKET}" \
      --prefix "${S3_PREFIX}" \
      --region "${AWS_REGION}" \
      --query 'sort_by(Contents, &LastModified)[-1].Key' \
      --output text 2>&1)"; then
      echo "  ERROR: Failed to list S3 objects: ${latest_key}"
      exit 1
    fi

    if [[ -n "${latest_key}" ]] && [[ "${latest_key}" != "None" ]]; then
      echo "  Fallback hit: s3://${BUCKET}/${latest_key}"
      download_and_extract "${latest_key}"
      RESTORED="true"
      break
    else
      echo "  No objects found."
    fi
  done <<< "${RESTORE_KEYS}"
fi

echo "::endgroup::"

# ---------------------------------------------------------------------------
# Fingerprint — hash of the artifact file list after restore.
# save.sh compares this against the post-build state to detect new artifacts.
# Only artifact files (depth 2 inside hash subdirs) are considered —
# trim.txt and other Go housekeeping files at depth 1 are excluded.
# ---------------------------------------------------------------------------
cache_fingerprint="$(find "${CACHE_DIR}" -mindepth 2 -maxdepth 2 -type f | sort | sha256sum | cut -d' ' -f1)"
echo "cache_fingerprint=${cache_fingerprint}" >> "${GITHUB_STATE}"
echo "cache_dir=${CACHE_DIR}" >> "${GITHUB_STATE}"

# ---------------------------------------------------------------------------
# Final output
# ---------------------------------------------------------------------------
echo "cache-hit=${CACHE_HIT}" >> "${GITHUB_OUTPUT}"
echo "cache_hit=${CACHE_HIT}" >> "${GITHUB_STATE}"

echo "--- Cache Restore Summary ---"
echo "  Bucket:     s3://${BUCKET}"
echo "  Repository: ${REPOSITORY}"
echo "  Branch:     ${BRANCH}"
echo "  Exact key:  ${KEY}"
echo "  Cache dir:  ${CACHE_DIR}"
if [[ "${CACHE_HIT}" == "true" ]]; then
  echo "  Result:     Exact hit — full reuse expected."
elif [[ "${RESTORED}" == "true" ]]; then
  echo "  Result:     Fallback hit — Go will reuse unchanged artifacts."
else
  echo "  Result:     Cold miss — no cache found, full build ahead."
fi
echo "-----------------------------"

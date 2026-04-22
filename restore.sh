#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Inputs (set by GitHub Actions from action.yml `inputs`)
# ---------------------------------------------------------------------------
PROVIDER="${INPUT_PROVIDER}"
KEY="${INPUT_KEY}"
RESTORE_KEYS="${INPUT_RESTORE_KEYS:-}"
BUCKET="${INPUT_BUCKET}"
AWS_REGION="${INPUT_AWS_REGION:-us-east-1}"

# ---------------------------------------------------------------------------
# Resolve GOCACHE path
# ---------------------------------------------------------------------------
GOCACHE="$(go env GOCACHE)"
echo "GOCACHE resolved to: ${GOCACHE}"

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

  echo "Extracting into $(dirname "${GOCACHE}") ..."
  mkdir -p "$(dirname "${GOCACHE}")"
  tar --zstd -xf "${TEMP_ARCHIVE}" -C "$(dirname "${GOCACHE}")"
  rm -f "${TEMP_ARCHIVE}"
  echo "Extraction complete: ${GOCACHE}"
}

# ---------------------------------------------------------------------------
# Exact key lookup
# ---------------------------------------------------------------------------
EXACT_OBJECT="${PROVIDER}/${KEY}.tar.zst"
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
# Fallback prefix search (tier 1: same branch, tier 2: any branch)
# ---------------------------------------------------------------------------
if [[ "${RESTORED}" == "false" ]] && [[ -n "${RESTORE_KEYS}" ]]; then
  echo "Trying restore-key prefixes..."
  while IFS= read -r prefix; do
    prefix="$(echo "${prefix}" | xargs)"
    [[ -z "${prefix}" ]] && continue

    S3_PREFIX="${PROVIDER}/${prefix}"
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
# Final output
# ---------------------------------------------------------------------------
echo "cache-hit=${CACHE_HIT}" >> "${GITHUB_OUTPUT}"
echo "cache-hit=${CACHE_HIT}" >> "${GITHUB_STATE}"

echo "--- Cache Restore Summary ---"
echo "  Bucket:    s3://${BUCKET}"
echo "  Provider:  ${PROVIDER}"
echo "  Exact key: ${KEY}"
if [[ "${CACHE_HIT}" == "true" ]]; then
  echo "  Result:    Exact hit — full reuse expected."
elif [[ "${RESTORED}" == "true" ]]; then
  echo "  Result:    Fallback hit — Go will reuse unchanged artifacts."
else
  echo "  Result:    Cold miss — no cache found, full build ahead."
fi
echo "-----------------------------"

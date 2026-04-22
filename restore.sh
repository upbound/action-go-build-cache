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

  echo "Extracting into $(dirname "${GOCACHE}") ..."
  mkdir -p "$(dirname "${GOCACHE}")"
  tar --zstd -xf "${TEMP_ARCHIVE}" -C "$(dirname "${GOCACHE}")"
  rm -f "${TEMP_ARCHIVE}"
  echo "Cache extracted to: ${GOCACHE}"
}

# ---------------------------------------------------------------------------
# Exact key lookup
# ---------------------------------------------------------------------------
EXACT_OBJECT="${PROVIDER}/${KEY}.tar.zst"
echo "Checking exact key: ${EXACT_OBJECT}"

CACHE_HIT="false"

if s3_object_exists "${EXACT_OBJECT}"; then
  echo "Exact cache hit: ${EXACT_OBJECT}"
  download_and_extract "${EXACT_OBJECT}"
  CACHE_HIT="true"
fi

# ---------------------------------------------------------------------------
# Fallback prefix search (tier 1: same branch, tier 2: any branch)
# Restore-keys is a newline-separated list of prefixes, tried in order.
# For each prefix we list all matching objects and pick the latest.
# ---------------------------------------------------------------------------
if [[ "${CACHE_HIT}" == "false" ]] && [[ -n "${RESTORE_KEYS}" ]]; then
  while IFS= read -r prefix; do
    # trim whitespace
    prefix="$(echo "${prefix}" | xargs)"
    [[ -z "${prefix}" ]] && continue

    S3_PREFIX="${PROVIDER}/${prefix}"
    echo "Trying restore-key prefix: ${S3_PREFIX}"

    latest_key="$(aws s3api list-objects-v2 \
      --bucket "${BUCKET}" \
      --prefix "${S3_PREFIX}" \
      --region "${AWS_REGION}" \
      --query 'sort_by(Contents, &LastModified)[-1].Key' \
      --output text 2>/dev/null || true)"

    # list-objects-v2 returns "None" when no objects match
    if [[ -n "${latest_key}" ]] && [[ "${latest_key}" != "None" ]]; then
      echo "Fallback cache hit: ${latest_key}"
      download_and_extract "${latest_key}"
      CACHE_HIT="false"   # partial hit — not an exact match
      break
    fi

    echo "No objects found for prefix: ${S3_PREFIX}"
  done <<< "${RESTORE_KEYS}"
fi

# ---------------------------------------------------------------------------
# Final output
# ---------------------------------------------------------------------------
echo "cache-hit=${CACHE_HIT}" >> "${GITHUB_OUTPUT}"

if [[ "${CACHE_HIT}" == "true" ]]; then
  echo "Result: exact cache hit — full reuse expected."
elif [[ -d "${GOCACHE}" ]]; then
  echo "Result: partial cache restored — Go will reuse unchanged artifacts."
else
  echo "Result: cold miss — no cache found, full build ahead."
fi

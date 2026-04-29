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
BUCKET="${INPUT_BUCKET}"
AWS_REGION="${INPUT_AWS_REGION:-us-east-1}"

# ---------------------------------------------------------------------------
# Resolve cache path — restore.sh saved the resolved dir in STATE; use it
# so both phases always operate on the same directory.
# ---------------------------------------------------------------------------
CACHE_DIR="${STATE_cache_dir:-}"
if [[ -z "${CACHE_DIR}" ]]; then
  CACHE_DIR="${INPUT_PATH:-}"
fi
if [[ -z "${CACHE_DIR}" ]]; then
  CACHE_DIR="$(go env GOCACHE)"
fi
echo "Cache path: ${CACHE_DIR}"

if [[ "${STATE_cache_hit:-false}" == "true" ]]; then
  current_fingerprint="$(find "${CACHE_DIR}" -mindepth 2 -maxdepth 2 -type f | sort | sha256sum | cut -d' ' -f1)"
  if [[ "${current_fingerprint}" == "${STATE_cache_fingerprint:-}" ]]; then
    echo "Exact cache hit and no new artifacts compiled — skipping upload."
    exit 0
  fi
  echo "Exact cache hit but cache dir has new artifacts — uploading enriched cache."
fi

if [[ ! -d "${CACHE_DIR}" ]] || [[ -z "$(ls -A "${CACHE_DIR}")" ]]; then
  echo "Cache directory is empty or does not exist: ${CACHE_DIR} — nothing to save."
  exit 0
fi

# ---------------------------------------------------------------------------
# Compress cache directory
# ---------------------------------------------------------------------------
TEMP_ARCHIVE="/tmp/go-build-cache-$$.tar.zst"

echo "Compressing ${CACHE_DIR} ..."
# -C to parent dir, archive the directory by name — mirrors the extract path in restore.sh
tar --zstd -cf "${TEMP_ARCHIVE}" -C "$(dirname "${CACHE_DIR}")" "$(basename "${CACHE_DIR}")"

ARCHIVE_SIZE="$(du -sh "${TEMP_ARCHIVE}" | cut -f1)"
echo "Archive size: ${ARCHIVE_SIZE}"

# ---------------------------------------------------------------------------
# Upload to S3 — layout: <repository>/<branch>/<key>.tar.zst
# ---------------------------------------------------------------------------
OBJECT_KEY="${REPOSITORY}/${BRANCH}/${KEY}.tar.zst"
echo "Uploading to s3://${BUCKET}/${OBJECT_KEY} ..."

aws s3 cp "${TEMP_ARCHIVE}" "s3://${BUCKET}/${OBJECT_KEY}" \
  --region "${AWS_REGION}"

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
rm -f "${TEMP_ARCHIVE}"
echo "Cache saved: s3://${BUCKET}/${OBJECT_KEY} (${ARCHIVE_SIZE})"

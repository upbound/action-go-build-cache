#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Inputs (set by GitHub Actions from action.yml `inputs`)
# ---------------------------------------------------------------------------
PROVIDER="${INPUT_PROVIDER}"
KEY="${INPUT_KEY}"
BUCKET="${INPUT_BUCKET}"
AWS_REGION="${INPUT_AWS_REGION:-us-east-1}"

# ---------------------------------------------------------------------------
# Resolve GOCACHE path
# ---------------------------------------------------------------------------
GOCACHE="$(go env GOCACHE)"
echo "GOCACHE resolved to: ${GOCACHE}"

if [[ "${STATE_cache_hit:-false}" == "true" ]]; then
  MARKER="${STATE_cache_marker:-}"
  if [[ -n "${MARKER}" ]] && [[ -f "${MARKER}" ]]; then
    new_files="$(find "${GOCACHE}" -newer "${MARKER}" -type f 2>/dev/null | wc -l)"
    if [[ "${new_files}" -eq 0 ]]; then
      echo "Exact cache hit and no new artifacts compiled — skipping upload."
      exit 0
    fi
    echo "Exact cache hit but ${new_files} new artifact(s) detected (e.g. additional arch) — uploading enriched cache."
  fi
fi

if [[ ! -d "${GOCACHE}" ]] || [[ -z "$(ls -A "${GOCACHE}")" ]]; then
  echo "GOCACHE is empty or does not exist: ${GOCACHE} — nothing to save."
  exit 0
fi

# ---------------------------------------------------------------------------
# Compress GOCACHE
# ---------------------------------------------------------------------------
TEMP_ARCHIVE="/tmp/go-build-cache-$$.tar.zst"

echo "Compressing ${GOCACHE} ..."
# -C to parent dir, archive the directory by name — mirrors the extract path in restore.sh
tar --zstd -cf "${TEMP_ARCHIVE}" -C "$(dirname "${GOCACHE}")" "$(basename "${GOCACHE}")"

ARCHIVE_SIZE="$(du -sh "${TEMP_ARCHIVE}" | cut -f1)"
echo "Archive size: ${ARCHIVE_SIZE}"

# ---------------------------------------------------------------------------
# Upload to S3
# ---------------------------------------------------------------------------
OBJECT_KEY="${PROVIDER}/${KEY}.tar.zst"
echo "Uploading to s3://${BUCKET}/${OBJECT_KEY} ..."

aws s3 cp "${TEMP_ARCHIVE}" "s3://${BUCKET}/${OBJECT_KEY}" \
  --region "${AWS_REGION}"

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
rm -f "${TEMP_ARCHIVE}"
echo "Cache saved: s3://${BUCKET}/${OBJECT_KEY} (${ARCHIVE_SIZE})"

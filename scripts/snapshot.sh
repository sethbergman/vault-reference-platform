#!/usr/bin/env bash
# Take a Raft snapshot and upload it to the configured backup bucket.
set -euo pipefail

TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="/tmp/vault-${TIMESTAMP}.snap"

vault operator raft snapshot save "${OUT}"

if [[ -n "${VAULT_BACKUP_BUCKET:-}" ]]; then
  aws s3 cp "${OUT}" "s3://${VAULT_BACKUP_BUCKET}/snapshots/vault-${TIMESTAMP}.snap"
  echo "Uploaded snapshot to s3://${VAULT_BACKUP_BUCKET}/snapshots/vault-${TIMESTAMP}.snap"
else
  echo "VAULT_BACKUP_BUCKET not set; snapshot left at ${OUT}"
fi

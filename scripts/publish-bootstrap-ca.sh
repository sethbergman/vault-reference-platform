#!/usr/bin/env bash
#
# publish-bootstrap-ca.sh — Publish the bootstrap CA where a new node can
#                           reach it, so a replacement signs its own leaf
#
# Usage:
#   ./publish-bootstrap-ca.sh --cluster-name vault-reference [options]
#
# Options:
#   --cluster-name <name>  Required. Must match the CA's subject.
#   --tls-dir <dir>        Where generate-cloud-certs.sh wrote the CA
#                          (default: ansible/files/tls).
#   --prefix <path>        SSM path (default: /<cluster-name>/tls).
#   --region <region>      AWS region (default: the CLI's).
#
# Run it once per cluster, after generate-cloud-certs.sh and the first
# playbook run. From then on a node the autoscaling group launches reads
# this CA at boot and issues its own certificate (scripts/
# issue-bootstrap-cert.sh), instead of waiting for someone to notice it.
#
# What it does:
#   1. Checks the local CA is this cluster's and that its key matches it.
#   2. Checks Terraform has created the two parameters, and reads which KMS
#      key the secret one is encrypted under.
#   3. Overwrites both, the key as a SecureString under that same KMS key.
#   4. Reads both back, decrypted, and compares them to the local files.
#
# DELIBERATE BEHAVIOURS
#
#   - It overwrites parameters Terraform created; it never creates them.
#     Terraform owns their lifecycle, so a teardown removes them, and
#     Terraform never holds the key: it wrote the placeholder as a
#     write-only argument, so a refresh does not read the key back into
#     state (tls.tf says why ignore_changes alone did).
#   - The secret parameter is overwritten with an explicit --key-id, read
#     from the parameter itself. `put-parameter --overwrite` without one
#     re-encrypts a SecureString under the account's aws/ssm key, which
#     the node role is not allowed to decrypt. The put succeeds; every
#     replacement node then fails to read the CA at boot, and the cluster
#     is exactly as un-self-healing as before, with a success message
#     from this script to prove otherwise.
#   - Success means the read-back matched, not that the put returned 0.
#   - The key is never printed. Its checksum is.
#
# Requirements: bash, openssl, aws (CLI v2), sha256sum

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

CLUSTER_NAME=""
TLS_DIR="${REPO_ROOT}/ansible/files/tls"
PREFIX=""
REGION_ARGS=()

log() { printf '%s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
    grep '^#' "$0" | sed -e '1d' -e 's/^# \{0,1\}//'
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --cluster-name) CLUSTER_NAME="$2"; shift 2 ;;
        --tls-dir)      TLS_DIR="$2"; shift 2 ;;
        --prefix)       PREFIX="${2%/}"; shift 2 ;;
        --region)       REGION_ARGS=(--region "$2"); shift 2 ;;
        -h|--help)      usage ;;
        *)              die "Unknown argument: $1" ;;
    esac
done

[[ -n "$CLUSTER_NAME" ]] || die "--cluster-name is required"
[[ -n "$PREFIX" ]] || PREFIX="/${CLUSTER_NAME}/tls"

for tool in openssl aws sha256sum; do
    command -v "$tool" >/dev/null 2>&1 || die "${tool} is not on PATH"
done

CERT_PARAM="${PREFIX}/bootstrap-ca.crt"
KEY_PARAM="${PREFIX}/bootstrap-ca.key"

# ---------------------------------------------------------------------------
# 1. The local CA
# ---------------------------------------------------------------------------
for f in ca.crt ca.key; do
    [[ -f "${TLS_DIR}/${f}" ]] || die "No ${f} in ${TLS_DIR}. Run generate-cloud-certs.sh first."
done

SUBJECT="$(openssl x509 -in "${TLS_DIR}/ca.crt" -noout -subject 2>/dev/null)" \
    || die "${TLS_DIR}/ca.crt does not parse"
[[ "$SUBJECT" == *"${CLUSTER_NAME} bootstrap CA"* ]] \
    || die "The CA in ${TLS_DIR} is not ${CLUSTER_NAME}'s: ${SUBJECT}"

CERT_PUB="$(openssl x509 -in "${TLS_DIR}/ca.crt" -noout -pubkey 2>/dev/null)"
KEY_PUB="$(openssl pkey -in "${TLS_DIR}/ca.key" -pubout 2>/dev/null)" \
    || die "${TLS_DIR}/ca.key does not parse"
[[ -n "$CERT_PUB" && "$CERT_PUB" == "$KEY_PUB" ]] \
    || die "${TLS_DIR}/ca.key does not belong to ${TLS_DIR}/ca.crt"

# ---------------------------------------------------------------------------
# 2. The parameters Terraform created, and the key the secret one uses
# ---------------------------------------------------------------------------
KMS_KEY="$(aws ssm describe-parameters "${REGION_ARGS[@]}" \
    --parameter-filters "Key=Name,Values=${KEY_PARAM}" \
    --query 'Parameters[0].KeyId' --output text 2>/dev/null || true)"
if [[ -z "$KMS_KEY" || "$KMS_KEY" == "None" ]]; then
    die "${KEY_PARAM} does not exist, or is not a SecureString.
       terraform/aws creates it; apply the profile first."
fi

HAS_CERT="$(aws ssm describe-parameters "${REGION_ARGS[@]}" \
    --parameter-filters "Key=Name,Values=${CERT_PARAM}" \
    --query 'length(Parameters)' --output text 2>/dev/null || true)"
[[ "$HAS_CERT" == "1" ]] || die "${CERT_PARAM} does not exist. Apply terraform/aws first."

log "Publishing the ${CLUSTER_NAME} bootstrap CA to ${PREFIX} (key under ${KMS_KEY})..."

# ---------------------------------------------------------------------------
# 3. Overwrite
# ---------------------------------------------------------------------------
aws ssm put-parameter "${REGION_ARGS[@]}" --name "$CERT_PARAM" --type String \
    --value "file://${TLS_DIR}/ca.crt" --overwrite >/dev/null \
    || die "Could not write ${CERT_PARAM}"
aws ssm put-parameter "${REGION_ARGS[@]}" --name "$KEY_PARAM" --type SecureString \
    --key-id "$KMS_KEY" --value "file://${TLS_DIR}/ca.key" --overwrite >/dev/null \
    || die "Could not write ${KEY_PARAM}"

# ---------------------------------------------------------------------------
# 4. Read back
# ---------------------------------------------------------------------------
readback() {
    aws ssm get-parameter "${REGION_ARGS[@]}" --name "$1" "${@:2}" \
        --query Parameter.Value --output text
}

sum_local()  { sha256sum < "$1" | cut -d' ' -f1; }
sum_remote() { printf '%s\n' "$1" | sha256sum | cut -d' ' -f1; }

REMOTE_CERT="$(readback "$CERT_PARAM")" || die "Could not read ${CERT_PARAM} back"
REMOTE_KEY="$(readback "$KEY_PARAM" --with-decryption)" || die "Could not read ${KEY_PARAM} back"

[[ "$(sum_remote "$REMOTE_CERT")" == "$(sum_local "${TLS_DIR}/ca.crt")" ]] \
    || die "${CERT_PARAM} does not read back as ${TLS_DIR}/ca.crt"
[[ "$(sum_remote "$REMOTE_KEY")" == "$(sum_local "${TLS_DIR}/ca.key")" ]] \
    || die "${KEY_PARAM} does not read back as ${TLS_DIR}/ca.key"
unset REMOTE_KEY

log "Published and read back: certificate $(sum_local "${TLS_DIR}/ca.crt" | cut -c1-12), key $(sum_local "${TLS_DIR}/ca.key" | cut -c1-12)."
log ""
log "Nodes launched from now on issue their own certificate at boot."
log "Nodes already running keep theirs; nothing on them changes."

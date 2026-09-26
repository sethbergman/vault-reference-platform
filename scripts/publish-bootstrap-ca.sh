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
#   - On Azure it CREATES the two secrets rather than overwriting
#     Terraform's, because azurerm has no write-only argument for a
#     secret's value: a Terraform-owned placeholder would carry the
#     published key into state on the next refresh. They live in the
#     cluster's own Key Vault and die with it. See the long note in
#     scripts/issue-bootstrap-cert.sh.
#   - On AWS it overwrites parameters Terraform created; it never creates them.
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
CLOUD="aws"
KEY_VAULT=""
SECRET_PREFIX="bootstrap-ca"
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
        --cloud)        CLOUD="$2"; shift 2 ;;
        --key-vault)    KEY_VAULT="$2"; shift 2 ;;
        --secret-prefix) SECRET_PREFIX="$2"; shift 2 ;;
        --tls-dir)      TLS_DIR="$2"; shift 2 ;;
        --prefix)       PREFIX="${2%/}"; shift 2 ;;
        --region)       REGION_ARGS=(--region "$2"); shift 2 ;;
        -h|--help)      usage ;;
        *)              die "Unknown argument: $1" ;;
    esac
done

[[ -n "$CLUSTER_NAME" ]] || die "--cluster-name is required"
case "$CLOUD" in
    aws)
        [[ -n "$PREFIX" ]] || PREFIX="/${CLUSTER_NAME}/tls"
        REQUIRED_TOOLS=(openssl aws sha256sum)
        ;;
    azure)
        [[ -n "$KEY_VAULT" ]] || die "--key-vault is required on azure (terraform output vault_autounseal_key_vault_name)"
        REQUIRED_TOOLS=(openssl az sha256sum)
        ;;
    *) die "--cloud must be aws or azure, got: ${CLOUD}" ;;
esac

for tool in "${REQUIRED_TOOLS[@]}"; do
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
# 2. Publish, and read back
# ---------------------------------------------------------------------------
sum_local()  { sha256sum < "$1" | cut -d' ' -f1; }
sum_remote() { printf '%s\n' "$1" | sha256sum | cut -d' ' -f1; }

if [[ "$CLOUD" == "azure" ]]; then
    # Two secrets in the cluster's own Key Vault, created here rather than
    # by Terraform: azurerm_key_vault_secret.value is required and read
    # back on refresh, so a Terraform-owned placeholder would carry the
    # published key into state on the next apply. See the note in
    # scripts/issue-bootstrap-cert.sh. Destroying the vault destroys these
    # with it, so nothing is orphaned by Terraform not owning them.
    #
    # --file, not --value: a PEM on a command line reaches the process
    # table and any shell history in between.
    CERT_SECRET="${SECRET_PREFIX}-crt"
    KEY_SECRET="${SECRET_PREFIX}-key"

    az keyvault show --name "$KEY_VAULT" --query name -o tsv >/dev/null 2>&1 \
        || die "Key Vault ${KEY_VAULT} not found, or this identity cannot see it. Apply terraform/azure first."

    log "Publishing the ${CLUSTER_NAME} bootstrap CA to Key Vault ${KEY_VAULT}..."

    az keyvault secret set --vault-name "$KEY_VAULT" --name "$CERT_SECRET" \
        --file "${TLS_DIR}/ca.crt" --content-type "application/x-pem-file" >/dev/null \
        || die "Could not write secret ${CERT_SECRET}. The signed-in identity needs Set on secrets."
    az keyvault secret set --vault-name "$KEY_VAULT" --name "$KEY_SECRET" \
        --file "${TLS_DIR}/ca.key" --content-type "application/x-pem-file" >/dev/null \
        || die "Could not write secret ${KEY_SECRET}. The signed-in identity needs Set on secrets."

    # Read back rather than trust the write: a set that reports success
    # and stores something else is the failure this repository is
    # arranged around.
    REMOTE_CERT="$(az keyvault secret show --vault-name "$KEY_VAULT" \
        --name "$CERT_SECRET" --query value -o tsv)" || die "Could not read ${CERT_SECRET} back"
    REMOTE_KEY="$(az keyvault secret show --vault-name "$KEY_VAULT" \
        --name "$KEY_SECRET" --query value -o tsv)" || die "Could not read ${KEY_SECRET} back"

    [[ "$(sum_remote "$REMOTE_CERT")" == "$(sum_local "${TLS_DIR}/ca.crt")" ]] \
        || die "${CERT_SECRET} does not read back as ${TLS_DIR}/ca.crt"
    [[ "$(sum_remote "$REMOTE_KEY")" == "$(sum_local "${TLS_DIR}/ca.key")" ]] \
        || die "${KEY_SECRET} does not read back as ${TLS_DIR}/ca.key"
    unset REMOTE_KEY

    log "Published and read back: certificate $(sum_local "${TLS_DIR}/ca.crt" | cut -c1-12), key $(sum_local "${TLS_DIR}/ca.key" | cut -c1-12)."
    log ""
    log "Nodes launched from now on issue their own certificate at boot."
    log "Nodes already running keep theirs; nothing on them changes."
    exit 0
fi

# ---------------------------------------------------------------------------
# 2a. AWS: the parameters Terraform created, and the key the secret one uses
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

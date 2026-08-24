#!/usr/bin/env bash
#
# terraform-to-ansible.sh — Turn Terraform outputs into Ansible group_vars
#
# Usage:
#   ./terraform-to-ansible.sh --cloud aws|azure [options]
#
# Example:
#   ./terraform-to-ansible.sh --cloud aws
#   ./terraform-to-ansible.sh --cloud azure --output ansible/group_vars/vault_nodes.yml
#
# The seam between "the infrastructure exists" and "Vault is configured on
# it". Terraform knows the KMS key id, the region, the snapshot bucket;
# the Ansible layer needs them to render vault.hcl. Until now that was a
# manual copy-paste from `terraform output` into a group_vars file, which
# is fine once and wrong by the third time somebody does it.
#
# What it does:
#   1. Reads `terraform output -json` from the chosen module.
#   2. Maps the outputs onto the variables ansible/roles/vault expects.
#   3. Writes a group_vars file, refusing to clobber one that exists
#      unless --force is given.
#
# What it deliberately does NOT do:
#   Write an inventory. Instances are discovered dynamically by tag —
#   see ansible/inventory/aws.yml and azure.yml — because a static
#   inventory goes stale the moment the scale set replaces a node, and
#   goes stale silently.
#
# Requirements: terraform, jq
#   --state-json lets you feed a saved `terraform output -json` instead,
#   which is what the tests use and what a pipeline with a separate plan
#   and apply stage would use.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

CLOUD=""
OUTPUT=""
STATE_JSON=""
FORCE=false

log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

usage() {
    grep '^#' "$0" | sed -e '1d' -e 's/^# \{0,1\}//'
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --cloud)      CLOUD="$2"; shift 2 ;;
        --output)     OUTPUT="$2"; shift 2 ;;
        --state-json) STATE_JSON="$2"; shift 2 ;;
        --force)      FORCE=true; shift ;;
        -h|--help)    usage ;;
        *) die "Unknown argument: $1" ;;
    esac
done

[[ -n "$CLOUD" ]] || die "--cloud is required (aws or azure)"
[[ "$CLOUD" == "aws" || "$CLOUD" == "azure" ]] || die "--cloud must be aws or azure, got: ${CLOUD}"
command -v jq >/dev/null 2>&1 || die "jq not found on PATH"

[[ -n "$OUTPUT" ]] || OUTPUT="${REPO_ROOT}/ansible/group_vars/vault_nodes.yml"

# ---------------------------------------------------------------------------
# Read the outputs
# ---------------------------------------------------------------------------
if [[ -n "$STATE_JSON" ]]; then
    [[ -f "$STATE_JSON" ]] || die "No such file: ${STATE_JSON}"
    OUTPUTS="$(cat "$STATE_JSON")"
else
    command -v terraform >/dev/null 2>&1 || die "terraform not found on PATH"
    MODULE_DIR="${REPO_ROOT}/terraform/${CLOUD}"
    [[ -d "$MODULE_DIR" ]] || die "No such module: ${MODULE_DIR}"

    log "Reading terraform outputs from ${MODULE_DIR}..."
    OUTPUTS="$(terraform -chdir="$MODULE_DIR" output -json 2>/dev/null)" \
        || die "Could not read terraform outputs — has ${CLOUD} been applied?"
fi

echo "$OUTPUTS" | jq -e . >/dev/null 2>&1 || die "Terraform output is not valid JSON"

# `terraform output -json` nests each value under .value. Fail loudly on a
# missing key rather than emitting a group_vars file with "null" in it,
# which would render a broken vault.hcl and fail much later, on the node.
#
# Every get() must run BEFORE the output file is opened. Inside a heredoc
# the die() below exits only the command substitution's subshell: the
# enclosing `cat` still succeeds, so the script would write the empty
# value it was trying to prevent and exit 0. Assigning to a variable in
# the main shell makes set -e see the failure.
get() {
    local key="$1"
    local value
    value="$(echo "$OUTPUTS" | jq -r --arg k "$key" '.[$k].value // empty')"
    [[ -n "$value" ]] || die "Terraform output '${key}' is missing or empty — was ${CLOUD} applied with the current configuration?"
    printf '%s' "$value"
}

# ---------------------------------------------------------------------------
# Refuse to clobber
# ---------------------------------------------------------------------------
if [[ -f "$OUTPUT" && "$FORCE" == false ]]; then
    die "${OUTPUT} already exists — pass --force to overwrite it"
fi

# ---------------------------------------------------------------------------
# Render
# ---------------------------------------------------------------------------
GENERATED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

# Resolved up front, before the output file exists — see the note on
# get(). A missing output has to abort with nothing written, not leave a
# half-populated file behind for the next run to trip over.
CLUSTER_TAG="$(get vault_cluster_tag)"
CLUSTER_NAME="${CLUSTER_TAG#*=}"
VAULT_ADDR_OUT="$(get vault_addr)"

case "$CLOUD" in
    aws)
        AWS_REGION="$(get aws_region)"
        KMS_REGION="$(get vault_autounseal_kms_region)"
        KMS_KEY_ID="$(get vault_autounseal_kms_key_id)"
        SNAPSHOT_BUCKET="$(get vault_snapshot_bucket)"
        ;;
    azure)
        SUBSCRIPTION_ID="$(get subscription_id)"
        TENANT_ID="$(get vault_autounseal_tenant_id)"
        KEY_VAULT_NAME="$(get vault_autounseal_key_vault_name)"
        KEY_NAME="$(get vault_autounseal_key_name)"
        SCALE_SET_NAME="$(get vault_scale_set_name)"
        RESOURCE_GROUP="$(get resource_group_name)"
        SNAPSHOT_ACCOUNT="$(get vault_snapshot_storage_account)"
        SNAPSHOT_CONTAINER="$(get vault_snapshot_container)"
        ;;
esac

mkdir -p "$(dirname "$OUTPUT")"

case "$CLOUD" in
    aws)
        cat > "$OUTPUT" <<EOF
---
# Generated by scripts/terraform-to-ansible.sh from terraform/aws
# outputs at ${GENERATED_AT}. Re-run it rather than editing this file;
# hand edits drift from the infrastructure they describe and nothing
# catches that.

vault_cloud: aws
vault_aws_region: ${AWS_REGION}

vault_seal_type: awskms
vault_awskms_region: ${KMS_REGION}
vault_awskms_key_id: ${KMS_KEY_ID}

# Raft peers are discovered through the EC2 API by this tag rather than
# listed statically, so replacing a node needs no inventory change. The
# same tag drives ansible/inventory/aws.yml.
vault_cluster_tag: ${CLUSTER_TAG}
vault_cluster_name: ${CLUSTER_NAME}

vault_snapshot_bucket: ${SNAPSHOT_BUCKET}
vault_api_addr: ${VAULT_ADDR_OUT}
EOF
        ;;
    azure)
        cat > "$OUTPUT" <<EOF
---
# Generated by scripts/terraform-to-ansible.sh from terraform/azure
# outputs at ${GENERATED_AT}. Re-run it rather than editing this file;
# hand edits drift from the infrastructure they describe and nothing
# catches that.

vault_cloud: azure
vault_azure_subscription_id: ${SUBSCRIPTION_ID}

vault_seal_type: azurekeyvault
vault_azurekeyvault_tenant_id: ${TENANT_ID}
vault_azurekeyvault_vault_name: ${KEY_VAULT_NAME}
vault_azurekeyvault_key_name: ${KEY_NAME}

# Raft peers are discovered by enumerating the scale set, not by tag:
# go-discover's azure provider rejects a mix of the two selectors, and
# its tag mode matches network-interface tags rather than the VM tags
# Terraform sets. See ansible/roles/vault/templates/vault.hcl.j2.
vault_scale_set_name: ${SCALE_SET_NAME}
vault_resource_group: ${RESOURCE_GROUP}

# Still emitted because ansible/inventory/azure.yml filters on it.
vault_cluster_tag: ${CLUSTER_TAG}
vault_cluster_name: ${CLUSTER_NAME}

vault_snapshot_storage_account: ${SNAPSHOT_ACCOUNT}
vault_snapshot_container: ${SNAPSHOT_CONTAINER}
vault_api_addr: ${VAULT_ADDR_OUT}
EOF
        ;;
esac

log "Wrote ${OUTPUT}"
log ""
log "Then run the playbook against the discovered nodes:"
log "  cd ansible && ansible-playbook -i inventory/${CLOUD}.yml playbooks/site.yml"

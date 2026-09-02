#!/usr/bin/env bash
#
# run-tests.sh — Tests for the Terraform → Ansible handoff
#
# Usage:
#   ./tests/ansible/run-tests.sh
#
# Covers the seam where Terraform's outputs become Vault's configuration:
#
#   1. scripts/terraform-to-ansible.sh maps outputs onto group_vars, and
#      fails loudly rather than emitting nulls when an output is missing.
#   2. The rendered vault.hcl actually clusters — the Raft retry_join
#      stanza is present and correct for each cloud.
#
# Both halves are checked against the *same* fixture, so a rename on one
# side of the handoff fails the test rather than producing a config that
# is syntactically fine and never forms a cluster.
#
# Requirements: bash, jq, python3 with jinja2 and pyyaml
#   No terraform and no cloud credentials — the fixtures are saved
#   `terraform output -json` payloads.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
FIXTURES="${SCRIPT_DIR}/fixtures"
HANDOFF="${REPO_ROOT}/scripts/terraform-to-ansible.sh"
RENDER="${SCRIPT_DIR}/render-config.py"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

green() { printf '\033[32m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*"; }

ok()   { PASS=$((PASS + 1)); green "  PASS  $1"; }
bad()  { FAIL=$((FAIL + 1)); red   "  FAIL  $1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; return 0; }

# assert_contains <label> <haystack> <needle>
assert_contains() {
    if [[ "$2" == *"$3"* ]]; then ok "$1"; else bad "$1" "expected to find: $3"; fi
}

# assert_not_contains <label> <haystack> <needle>
assert_not_contains() {
    if [[ "$2" != *"$3"* ]]; then ok "$1"; else bad "$1" "expected NOT to find: $3"; fi
}

# generate <label> <cloud> <fixture> <output> [extra args...]
# Runs the handoff script expecting success. Reports a failure rather
# than letting set -e abort the whole suite, so a break here still prints
# which assertion died and why instead of ending the run mid-sentence.
generate() {
    local label="$1" cloud="$2" fixture="$3" out="$4"; shift 4
    local err rc=0
    err="$("$HANDOFF" --cloud "$cloud" --state-json "$fixture" --output "$out" "$@" 2>&1)" || rc=$?
    if [[ $rc -ne 0 ]]; then
        bad "$label" "handoff script exited ${rc}: ${err}"
        return 0
    fi
    if [[ ! -s "$out" ]]; then
        bad "$label" "handoff script succeeded but wrote nothing to ${out}"
        return 0
    fi
    ok "$label"
}

# assert_fails <label> <expected message fragment> <command...>
# Asserts the command exits non-zero *and* says why. A script that fails
# with the wrong error is still a script that fails for the wrong reason.
assert_fails() {
    local label="$1" want="$2"; shift 2
    local out rc=0
    out="$("$@" 2>&1)" || rc=$?
    if [[ $rc -eq 0 ]]; then
        bad "$label" "expected a non-zero exit, got success"
    elif [[ "$out" != *"$want"* ]]; then
        bad "$label" "exited $rc but did not mention: ${want}"
    else
        ok "$label"
    fi
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
# Without these the assertions below degrade into passing vacuously,
# which is worse than not running them at all.
for dep in jq python3; do
    command -v "$dep" >/dev/null 2>&1 || { red "ERROR: ${dep} not found on PATH"; exit 1; }
done
python3 -c 'import jinja2, yaml' 2>/dev/null \
    || { red "ERROR: python3 needs the jinja2 and pyyaml modules"; exit 1; }
[[ -x "$HANDOFF" ]] || { red "ERROR: ${HANDOFF} is not executable"; exit 1; }

# ---------------------------------------------------------------------------
printf '\n=== Handoff script: argument handling ===\n'
# ---------------------------------------------------------------------------
assert_fails "rejects a missing --cloud" "--cloud is required" \
    "$HANDOFF" --state-json "${FIXTURES}/aws-outputs.json"

assert_fails "rejects an unknown --cloud" "must be aws or azure" \
    "$HANDOFF" --cloud gcp --state-json "${FIXTURES}/aws-outputs.json"

assert_fails "rejects an unknown argument" "Unknown argument" \
    "$HANDOFF" --cloud aws --wat

assert_fails "rejects a missing state file" "No such file" \
    "$HANDOFF" --cloud aws --state-json "${WORK}/nope.json"

echo '{ not json' > "${WORK}/bad.json"
assert_fails "rejects malformed JSON" "not valid JSON" \
    "$HANDOFF" --cloud aws --state-json "${WORK}/bad.json"

# ---------------------------------------------------------------------------
printf '\n=== Handoff script: missing outputs fail loudly ===\n'
# ---------------------------------------------------------------------------
# The failure mode this guards against: an output gets renamed, the
# script writes `vault_awskms_key_id: null`, the playbook succeeds, and
# Vault comes up unable to unseal. The error has to land here.
jq 'del(.vault_autounseal_kms_key_id)' "${FIXTURES}/aws-outputs.json" > "${WORK}/aws-missing.json"
assert_fails "missing AWS output aborts, naming the output" "vault_autounseal_kms_key_id" \
    "$HANDOFF" --cloud aws --state-json "${WORK}/aws-missing.json" --output "${WORK}/missing.yml"

jq 'del(.subscription_id)' "${FIXTURES}/azure-outputs.json" > "${WORK}/azure-missing.json"
assert_fails "missing Azure output aborts, naming the output" "subscription_id" \
    "$HANDOFF" --cloud azure --state-json "${WORK}/azure-missing.json" --output "${WORK}/missing.yml"

# An output present but empty is the same problem wearing a disguise.
jq '.vault_snapshot_bucket.value = ""' "${FIXTURES}/aws-outputs.json" > "${WORK}/aws-empty.json"
assert_fails "empty output aborts too" "vault_snapshot_bucket" \
    "$HANDOFF" --cloud aws --state-json "${WORK}/aws-empty.json" --output "${WORK}/empty.yml"

if [[ -f "${WORK}/missing.yml" || -f "${WORK}/empty.yml" ]]; then
    bad "aborts before writing a partial file" "a group_vars file was left behind"
else
    ok "aborts before writing a partial file"
fi

# ---------------------------------------------------------------------------
printf '\n=== Handoff script: refuses to clobber ===\n'
# ---------------------------------------------------------------------------
AWS_VARS="${WORK}/aws.yml"
generate "writes a group_vars file" aws "${FIXTURES}/aws-outputs.json" "$AWS_VARS"

assert_fails "refuses to overwrite without --force" "already exists" \
    "$HANDOFF" --cloud aws --state-json "${FIXTURES}/aws-outputs.json" --output "$AWS_VARS"

generate "overwrites with --force" aws "${FIXTURES}/aws-outputs.json" "$AWS_VARS" --force

# ---------------------------------------------------------------------------
printf '\n=== Handoff script: generated AWS group_vars ===\n'
# ---------------------------------------------------------------------------
if python3 -c 'import sys, yaml; yaml.safe_load(open(sys.argv[1]))' "$AWS_VARS"; then
    ok "AWS group_vars is valid YAML"
else
    bad "AWS group_vars is valid YAML"
fi

AWS_OUT="$(cat "$AWS_VARS")"
assert_contains "carries vault_cloud: aws"      "$AWS_OUT" "vault_cloud: aws"
assert_contains "carries the region"            "$AWS_OUT" "vault_aws_region: us-east-1"
assert_contains "carries the seal type"         "$AWS_OUT" "vault_seal_type: awskms"
assert_contains "carries the KMS key id"        "$AWS_OUT" "11111111-2222-3333-4444-555555555555"
assert_contains "carries the cluster tag"       "$AWS_OUT" "vault_cluster_tag: VaultCluster=vault-test"
assert_contains "derives the cluster name"      "$AWS_OUT" "vault_cluster_name: vault-test"
assert_contains "carries the snapshot bucket"   "$AWS_OUT" "vault_snapshot_bucket: vault-test-snapshots-abc123"
assert_not_contains "never emits null"          "$AWS_OUT" "null"

# ---------------------------------------------------------------------------
printf '\n=== Handoff script: generated Azure group_vars ===\n'
# ---------------------------------------------------------------------------
AZURE_VARS="${WORK}/azure.yml"
generate "writes a group_vars file" azure "${FIXTURES}/azure-outputs.json" "$AZURE_VARS"

if python3 -c 'import sys, yaml; yaml.safe_load(open(sys.argv[1]))' "$AZURE_VARS"; then
    ok "Azure group_vars is valid YAML"
else
    bad "Azure group_vars is valid YAML"
fi

AZURE_OUT="$(cat "$AZURE_VARS")"
assert_contains "carries vault_cloud: azure"    "$AZURE_OUT" "vault_cloud: azure"
assert_contains "carries the subscription id"   "$AZURE_OUT" "vault_azure_subscription_id: 00000000-1111-2222-3333-444444444444"
assert_contains "carries the seal type"         "$AZURE_OUT" "vault_seal_type: azurekeyvault"
assert_contains "carries the key vault name"    "$AZURE_OUT" "vault_azurekeyvault_vault_name: vaulttest-au-a1b2"
assert_contains "carries the scale set name"    "$AZURE_OUT" "vault_scale_set_name: vault-test-vault"
assert_contains "carries the resource group"    "$AZURE_OUT" "vault_resource_group: vault-test-rg"
assert_not_contains "never emits null"          "$AZURE_OUT" "null"

# ---------------------------------------------------------------------------
printf '\n=== Rendered vault.hcl: AWS ===\n'
# ---------------------------------------------------------------------------
# Rendered from the group_vars the script just produced, so a rename on
# either side of the handoff shows up here.
AWS_HCL="$(python3 "$RENDER" "$AWS_VARS" 2>&1 || echo "RENDER FAILED")"

assert_contains "has a retry_join stanza"       "$AWS_HCL" "retry_join {"
assert_contains "uses the aws provider"         "$AWS_HCL" "provider=aws"
assert_contains "filters on the cluster tag"    "$AWS_HCL" "tag_key=VaultCluster tag_value=vault-test"
assert_contains "passes the region"             "$AWS_HCL" "region=us-east-1"
assert_contains "joins over https"              "$AWS_HCL" 'auto_join_scheme    = "https"'
assert_contains "verifies peers against the CA" "$AWS_HCL" 'leader_ca_cert_file = "/etc/vault.d/tls/ca.crt"'
assert_contains "configures the KMS seal"       "$AWS_HCL" 'seal "awskms"'
assert_contains "requires client certs"         "$AWS_HCL" "tls_client_ca_file"
assert_not_contains "no unrendered Jinja left"  "$AWS_HCL" "{{"
assert_not_contains "no azure config leaked"    "$AWS_HCL" "provider=azure"

# ---------------------------------------------------------------------------
printf '\n=== Rendered vault.hcl: Azure ===\n'
# ---------------------------------------------------------------------------
AZURE_HCL="$(python3 "$RENDER" "$AZURE_VARS" 2>&1 || echo "RENDER FAILED")"

assert_contains "has a retry_join stanza"       "$AZURE_HCL" "retry_join {"
assert_contains "uses the azure provider"       "$AZURE_HCL" "provider=azure"
assert_contains "passes the subscription id"    "$AZURE_HCL" "subscription_id=00000000-1111-2222-3333-444444444444"
assert_contains "passes the resource group"     "$AZURE_HCL" "resource_group=vault-test-rg"
assert_contains "passes the scale set"          "$AZURE_HCL" "vm_scale_set=vault-test-vault"
assert_contains "configures the Key Vault seal" "$AZURE_HCL" 'seal "azurekeyvault"'
assert_not_contains "no unrendered Jinja left"  "$AZURE_HCL" "{{"
assert_not_contains "no aws config leaked"      "$AZURE_HCL" "provider=aws"

# go-discover's azure provider takes (tag_name + tag_value) OR
# (resource_group + vm_scale_set) and rejects any mix of the two with
# "unclear configuration: use (tag name and value) or (resouce_group and
# vm_scale_set)". A config carrying both parses fine, starts fine, and
# never forms a cluster — so this is pinned rather than left to review.
assert_not_contains "no tag_name in azure auto_join"  "$AZURE_HCL" "tag_name="
assert_not_contains "no tag_value in azure auto_join" "$AZURE_HCL" "tag_value="

# ---------------------------------------------------------------------------
printf '\n=== The same guard, on what cloud-init writes ===\n'
# ---------------------------------------------------------------------------
# The Ansible path and the cloud-init path configure the same thing two
# ways, so the constraint has to hold in both. It did not: the Azure
# cloud-init template shipped tag_name and resource_group together.
AZURE_INIT="${REPO_ROOT}/terraform/azure/templates/cloud-init.sh.tftpl"
AZURE_JOIN="$(grep -o 'auto_join *= *"provider=azure[^"]*"' "$AZURE_INIT" || true)"
if [[ -z "$AZURE_JOIN" ]]; then
    bad "azure cloud-init has an azure auto_join" "no auto_join line found in ${AZURE_INIT}"
else
    ok "azure cloud-init has an azure auto_join"
    assert_contains     "cloud-init passes vm_scale_set"  "$AZURE_JOIN" "vm_scale_set="
    assert_not_contains "cloud-init mixes in no tag_name" "$AZURE_JOIN" "tag_name="
fi

AWS_INIT="${REPO_ROOT}/terraform/aws/templates/user-data.sh.tftpl"
AWS_JOIN="$(grep -o 'auto_join *= *"provider=aws[^"]*"' "$AWS_INIT" || true)"
if [[ -z "$AWS_JOIN" ]]; then
    bad "aws cloud-init has an aws auto_join" "no auto_join line found in ${AWS_INIT}"
else
    ok "aws cloud-init has an aws auto_join"
    assert_contains "cloud-init filters on the cluster tag" "$AWS_JOIN" "tag_key=VaultCluster"
fi

# ---------------------------------------------------------------------------
printf '\n=== Rendered vault.hcl: no cloud configured ===\n'
# ---------------------------------------------------------------------------
# The local and single-node profiles have no cloud API to discover peers
# through, so retry_join must be omitted rather than rendered empty. An
# empty auto_join is not inert — Vault fails to start on it.
cat > "${WORK}/local.yml" <<'YAML'
---
vault_cluster_name: vault-local
YAML
LOCAL_HCL="$(python3 "$RENDER" "${WORK}/local.yml" 2>&1 || echo "RENDER FAILED")"

assert_not_contains "omits retry_join entirely"  "$LOCAL_HCL" "retry_join"
assert_not_contains "omits the auto_join line"   "$LOCAL_HCL" "auto_join"
assert_not_contains "omits any seal stanza"      "$LOCAL_HCL" "seal \""
assert_contains     "still configures storage"   "$LOCAL_HCL" 'storage "raft"'
assert_contains     "still configures a listener" "$LOCAL_HCL" 'listener "tcp"'

# ---------------------------------------------------------------------------
printf '\n=== Rendered vault.hcl: the web UI ===\n'
# ---------------------------------------------------------------------------
# The UI is served by the API listener, so enabling it widens what is
# reachable on a port that is already open. It was previously absent from
# the template altogether, which left it off by omission rather than by
# decision -- indistinguishable in behaviour, and invisible to anyone
# reading the config to find out.
assert_contains "defaults to off"        "$AWS_HCL"   "ui = false"
assert_contains "off on azure too"       "$AZURE_HCL" "ui = false"
assert_contains "off with no cloud"      "$LOCAL_HCL" "ui = false"

UI_ON="$(python3 "$RENDER" "${WORK}/local.yml" vault_ui_enabled=true 2>&1 || echo "RENDER FAILED")"
assert_contains "turns on when asked"    "$UI_ON" "ui = true"

# The value is rendered, not branched on. A conditional would read the
# string "false" as truthy and turn an explicit opt-out into ui = true --
# the quiet direction to fail in, since the config would then say the
# opposite of what was asked for.
UI_OFF="$(python3 "$RENDER" "${WORK}/local.yml" vault_ui_enabled=false 2>&1 || echo "RENDER FAILED")"
assert_contains "a string false is still off" "$UI_OFF" "ui = false"
assert_not_contains "and not on"              "$UI_OFF" "ui = true"

# ---------------------------------------------------------------------------
printf '\n=== Template fails closed on a missing variable ===\n'
# ---------------------------------------------------------------------------
# Jinja2's default is to render an undefined variable as the empty
# string. Under that default a dropped kms_key_id yields `kms_key_id =
# ""` — a config that parses and cannot unseal. render-config.py uses
# StrictUndefined; this proves it, so the tests above are load-bearing.
cat > "${WORK}/incomplete.yml" <<'YAML'
---
vault_cluster_name: vault-broken
vault_seal_type: awskms
YAML
assert_fails "undefined variable raises rather than rendering empty" "vault_awskms_region" \
    python3 "$RENDER" "${WORK}/incomplete.yml"

# ---------------------------------------------------------------------------
printf '\n=== Dynamic inventories ===\n'
# ---------------------------------------------------------------------------
# Not a substitute for running them against a live API, which needs
# credentials. This checks the part that can be checked offline: they
# parse, and they filter on the same tag Terraform sets.
for cloud in aws azure; do
    inv="${REPO_ROOT}/ansible/inventory/${cloud}.yml"
    if python3 -c 'import sys, yaml; yaml.safe_load(open(sys.argv[1]))' "$inv"; then
        ok "${cloud} inventory is valid YAML"
    else
        bad "${cloud} inventory is valid YAML"
    fi
    assert_contains "${cloud} inventory filters on VaultCluster" "$(cat "$inv")" "VaultCluster"
done

# ---------------------------------------------------------------------------
printf '\n=== Results ===\n'
# ---------------------------------------------------------------------------
printf 'passed: %d\nfailed: %d\n' "$PASS" "$FAIL"
if [[ $FAIL -gt 0 ]]; then
    red "FAILED"
    exit 1
fi
green "All ${PASS} assertions passed."

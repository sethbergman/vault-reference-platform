#!/usr/bin/env bash
#
# run-tests.sh — A replacement node issues its own certificate at boot
#
# Usage:
#   ./tests/bootstrap-cert/run-tests.sh
#
# Runs in a few seconds. No cloud, no credentials. The CA and every leaf
# are real openssl output; SSM and instance metadata are shims.
#
# WHY THIS EXISTS
#
# The first real AWS apply terminated a leader, and the autoscaling group
# replaced it with an instance whose Vault never started: certificates came
# only from an Ansible run keyed to an instance id that did not exist until
# the launch. scripts/issue-bootstrap-cert.sh now runs from user-data and
# signs the node's own leaf from a bootstrap CA that
# scripts/publish-bootstrap-ca.sh puts in SSM.
#
# Both scripts touch a CA key, and both fail quietly if they are wrong in
# the ordinary ways -- so most of what follows is about what they must
# refuse, and about the one property that makes the design safe to adopt:
# a leaf issued at boot is interchangeable with one generate-cloud-certs.sh
# issues. If they drift, a self-healed node fails a check its peers pass.
#
# WHAT A GREEN RUN DOES NOT MEAN
#
# That a node on AWS does this. The shims model SSM and IMDSv2 closely
# enough to catch a missing --with-decryption or a missing token, but no
# instance boots here and no KMS key decrypts anything. A replacement
# issuing its own certificate on a real cluster is checklist item 10 in
# docs/cloud-apply.md, and it has not been observed.
#
# Requirements: bash, openssl, sha256sum

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ISSUE="${REPO_ROOT}/scripts/issue-bootstrap-cert.sh"
PUBLISH="${REPO_ROOT}/scripts/publish-bootstrap-ca.sh"
GEN="${REPO_ROOT}/scripts/generate-cloud-certs.sh"
FAKE_BIN="${SCRIPT_DIR}/fake-bin"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

green() { printf '\033[32m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*"; }

ok()  { PASS=$((PASS + 1)); green "  PASS  $1"; }
bad() { FAIL=$((FAIL + 1)); red   "  FAIL  $1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; return 0; }

for dep in openssl sha256sum jq; do
    command -v "$dep" >/dev/null 2>&1 || { red "ERROR: ${dep} not found on PATH"; exit 1; }
done
for s in "$ISSUE" "$PUBLISH" "$GEN"; do
    [[ -x "$s" ]] || { red "ERROR: ${s} is not executable"; exit 1; }
done

CLUSTER="vault-reference"
PREFIX="/${CLUSTER}/tls"
LB="vault-nlb-abc.elb.us-east-1.amazonaws.com"
NODE_KMS="arn:aws:kms:us-east-1:123456789012:key/volume-key"
ME="$(id -un):$(id -gn)"

# ---------------------------------------------------------------------------
# Fixtures: real CAs, issued by the script that issues them in production
# ---------------------------------------------------------------------------
mk_ca() {  # mk_ca <dir> <cluster>
    local inv="${WORK}/inv-$2.json"
    cat > "$inv" <<JSON
{"_meta": {"hostvars": {"i-0aaa": {"private_ip_address": "10.0.1.10"}}},
 "vault_nodes": {"hosts": ["i-0aaa"]}}
JSON
    "$GEN" --cluster-name "$2" --hosts-json "$inv" --out "$1" --extra-san "$LB" >/dev/null 2>&1
}

CA_OURS="${WORK}/ca-ours";   mk_ca "$CA_OURS" "$CLUSTER"
CA_OTHER="${WORK}/ca-other"; mk_ca "$CA_OTHER" "other-cluster"

if [[ -f "${CA_OURS}/ca.crt" && -f "${CA_OURS}/ca.key" && -f "${CA_OTHER}/ca.key" ]]; then
    ok "fixture CAs issued by generate-cloud-certs.sh"
else
    bad "fixture CAs issued by generate-cloud-certs.sh" "everything below would be vacuous"
fi

# ---------------------------------------------------------------------------
# Scenario plumbing
# ---------------------------------------------------------------------------
RC=0; OUT=""; LOG=""; TLS=""

reset_scenario() {
    export FAKE_SSM_DIR; FAKE_SSM_DIR="$(mktemp -d "${WORK}/ssm.XXXXXXXX")"
    export FAKE_LOG; FAKE_LOG="$(mktemp "${WORK}/log.XXXXXXXX")"
    export FAKE_SSM_RC=0 FAKE_SSM_CORRUPT_NAME="" FAKE_IMDS_RC=0
    export FAKE_INSTANCE_ID="i-0replacement" FAKE_LOCAL_IPV4="10.0.1.99" FAKE_REGION="us-east-1"
    # Azure: a VM name rather than an instance id, a location rather than a
    # region, and the CA in Key Vault secrets that may be present, absent
    # (never published) or denied (the identity lacks Get).
    export FAKE_AZ_VM_NAME="vault-reference_3" FAKE_AZ_LOCATION="eastus"
    export FAKE_AZ_TOKEN="fake-kv-token" FAKE_AZ_TOKEN_RC=0
    export FAKE_AZ_CRT_SECRET="present" FAKE_AZ_KEY_SECRET="present"
    export FAKE_CA_CERT_FILE="" FAKE_CA_KEY_FILE=""
    TLS="$(mktemp -d "${WORK}/tls.XXXXXXXX")"
    rmdir "$TLS"   # the script creates it, as on a fresh node
    export TMPDIR; TMPDIR="$(mktemp -d "${WORK}/tmp.XXXXXXXX")"
}

# What terraform/aws/tls.tf leaves in both parameters before publication.
PLACEHOLDER="$(sed -n 's/^ *bootstrap_ca_placeholder *= *"\(.*\)"/\1/p' "${REPO_ROOT}/terraform/aws/tls.tf")"

store() {  # store <param> <type> <file-or-literal> [keyid]
    local f; f="${FAKE_SSM_DIR}/$(printf '%s' "$1" | tr '/' '_')"
    if [[ -f "$3" ]]; then cat "$3" > "$f"; else printf '%s\n' "$3" > "$f"; fi
    printf '%s' "$2" > "${f}.type"
    [[ -n "${4:-}" ]] && printf '%s' "$4" > "${f}.keyid"
    return 0
}

published() {  # published <ca-dir>: the state after publish-bootstrap-ca.sh
    store "${PREFIX}/bootstrap-ca.crt" String "${1}/ca.crt"
    store "${PREFIX}/bootstrap-ca.key" SecureString "${1}/ca.key" "$NODE_KMS"
}

unpublished() {  # the state Terraform leaves
    store "${PREFIX}/bootstrap-ca.crt" String "$PLACEHOLDER"
    store "${PREFIX}/bootstrap-ca.key" SecureString "$PLACEHOLDER" "$NODE_KMS"
}

run_issue() {
    RC=0
    OUT="$(PATH="${FAKE_BIN}:${PATH}" "$ISSUE" --cluster-name "$CLUSTER" \
        --ca-parameter-prefix "$PREFIX" --extra-san "$LB" --tls-dir "$TLS" \
        --owner "$ME" 2>&1)" || RC=$?
    LOG="$(cat "$FAKE_LOG")"
}

# The same script, the other cloud. --key-vault replaces the SSM prefix,
# and the CA comes from whatever FAKE_CA_*_FILE point at.
run_issue_azure() {
    RC=0
    OUT="$(PATH="${FAKE_BIN}:${PATH}" "$ISSUE" --cloud azure \
        --cluster-name "$CLUSTER" --key-vault "vault-ref-kv" \
        --extra-san "10.1.1.7" --tls-dir "$TLS" --owner "$ME" 2>&1)" || RC=$?
    LOG="$(cat "$FAKE_LOG")"
}

# Azure's "published" is two secrets that exist; its "unpublished" is a
# secret that does not, because nothing creates one before publication.
published_azure() {  # published_azure <ca-dir>
    export FAKE_CA_CERT_FILE="${1}/ca.crt"
    export FAKE_CA_KEY_FILE="${1}/ca.key"
    export FAKE_AZ_CRT_SECRET="present" FAKE_AZ_KEY_SECRET="present"
}

run_publish() {
    RC=0
    OUT="$(PATH="${FAKE_BIN}:${PATH}" "$PUBLISH" --cluster-name "$CLUSTER" "$@" 2>&1)" || RC=$?
    LOG="$(cat "$FAKE_LOG")"
}

nothing_written() { [[ ! -e "${TLS}/vault.crt" && ! -e "${TLS}/vault.key" ]]; }

sans() {  # sans <cert>: its SANs, one per line, sorted
    openssl x509 -in "$1" -noout -ext subjectAltName 2>/dev/null \
        | tail -n +2 | tr ',' '\n' | sed 's/^ *//' | sort
}

# ---------------------------------------------------------------------------
printf '\n=== The placeholder is one value in two places ===\n'
# ---------------------------------------------------------------------------
# Terraform writes it; the boot script tests for it. If they disagree, an
# unpublished CA is read as a CA, fails to parse, and a first apply's
# user-data reports an error on every node for no reason.
SCRIPT_PLACEHOLDER="$(sed -n 's/^PLACEHOLDER="\(.*\)"/\1/p' "$ISSUE")"
if [[ -n "$PLACEHOLDER" && "$PLACEHOLDER" == "$SCRIPT_PLACEHOLDER" ]]; then
    ok "tls.tf and the boot script agree on the placeholder (${PLACEHOLDER})"
else
    bad "tls.tf and the boot script agree on the placeholder" \
        "tls.tf '${PLACEHOLDER:-<none>}', script '${SCRIPT_PLACEHOLDER:-<none>}'"
fi

# ---------------------------------------------------------------------------
printf '\n=== A replacement node, after publication ===\n'
# ---------------------------------------------------------------------------
reset_scenario
published "$CA_OURS"
run_issue

if [[ "$RC" == "0" && -f "${TLS}/vault.crt" && -f "${TLS}/vault.key" && -f "${TLS}/ca.crt" ]]; then
    ok "it writes a certificate, its key and the CA where vault.hcl looks"
else
    bad "it writes a certificate, its key and the CA where vault.hcl looks" "exit ${RC}: ${OUT}"
fi

if openssl verify -CAfile "${CA_OURS}/ca.crt" "${TLS}/vault.crt" >/dev/null 2>&1; then
    ok "the leaf verifies against the CA the running nodes already trust"
else
    bad "the leaf verifies against the CA the running nodes already trust"
fi

# The property that makes this safe to adopt. Same host, same address,
# same extra SAN, through both issuers: the SAN sets must be identical.
PARITY_INV="${WORK}/parity.json"
cat > "$PARITY_INV" <<JSON
{"_meta": {"hostvars": {"i-0replacement": {"private_ip_address": "10.0.1.99"}}},
 "vault_nodes": {"hosts": ["i-0replacement"]}}
JSON
PARITY_OUT="${WORK}/parity-certs"
"$GEN" --cluster-name "$CLUSTER" --hosts-json "$PARITY_INV" --out "$PARITY_OUT" \
    --extra-san "$LB" >/dev/null 2>&1 || true

BOOT_SANS="$(sans "${TLS}/vault.crt")"
OPERATOR_SANS="$(sans "${PARITY_OUT}/i-0replacement.crt")"
if [[ -n "$BOOT_SANS" && "$BOOT_SANS" == "$OPERATOR_SANS" ]]; then
    ok "its SANs are exactly generate-cloud-certs.sh's for the same node"
else
    bad "its SANs are exactly generate-cloud-certs.sh's for the same node" \
        "boot: $(tr '\n' ' ' <<< "$BOOT_SANS")| operator: $(tr '\n' ' ' <<< "$OPERATOR_SANS")"
fi

# Pinned as well as compared: two scripts that both dropped the cluster
# servername would agree with each other and form no cluster.
for want in "IP Address:10.0.1.99" "DNS:vault-reference.vault.internal" "DNS:${LB}"; do
    if grep -qxF "$want" <<< "$BOOT_SANS"; then
        ok "it carries ${want}"
    else
        bad "it carries ${want}" "SANs: $(tr '\n' ' ' <<< "$BOOT_SANS")"
    fi
done

KEY_MODE="$(stat -c '%a' "${TLS}/vault.key" 2>/dev/null || echo none)"
if [[ "$KEY_MODE" == "600" ]]; then
    ok "the node key is 0600"
else
    bad "the node key is 0600" "mode ${KEY_MODE}"
fi

# The CA key was on this machine; it must not still be.
LEFT="$(find "$TLS" "$TMPDIR" -type f -exec grep -l 'PRIVATE KEY' {} + 2>/dev/null | grep -v '/vault\.key$' || true)"
if [[ -z "$LEFT" && ! -e "${TLS}/ca.key" ]]; then
    ok "no copy of the CA key survives the run"
else
    bad "no copy of the CA key survives the run" "found: ${LEFT:-${TLS}/ca.key}"
fi

if [[ "$LOG" == *"bootstrap-ca.key --with-decryption"* ]]; then
    ok "it asks SSM to decrypt the key, and gets the key rather than ciphertext"
else
    bad "it asks SSM to decrypt the key" "calls: ${LOG}"
fi

# ---------------------------------------------------------------------------
printf '\n=== Before publication: a first apply ===\n'
# ---------------------------------------------------------------------------
reset_scenario
unpublished
run_issue
if [[ "$RC" == "0" && "$OUT" == *"has not been published"* ]] && nothing_written; then
    ok "an unpublished CA is not an error, and nothing is written"
else
    bad "an unpublished CA is not an error, and nothing is written" "exit ${RC}: ${OUT}"
fi

# Stopping at the certificate means it never asked for the key.
if [[ "$LOG" != *"bootstrap-ca.key"* ]]; then
    ok "and it never reads the key parameter"
else
    bad "and it never reads the key parameter" "calls: ${LOG}"
fi

# ---------------------------------------------------------------------------
printf '\n=== What it must leave alone, or refuse ===\n'
# ---------------------------------------------------------------------------
reset_scenario
published "$CA_OURS"
mkdir -p "$TLS"
printf 'existing' > "${TLS}/vault.crt"
run_issue
if [[ "$RC" == "0" && "$(cat "${TLS}/vault.crt")" == "existing" && "$LOG" != *"aws ssm"* ]]; then
    ok "a certificate already present is left alone, and SSM is never asked"
else
    bad "a certificate already present is left alone, and SSM is never asked" "exit ${RC}: ${OUT}"
fi

reset_scenario
store "${PREFIX}/bootstrap-ca.crt" String "${CA_OURS}/ca.crt"
store "${PREFIX}/bootstrap-ca.key" SecureString "$PLACEHOLDER" "$NODE_KMS"
run_issue
if [[ "$RC" != "0" && "$OUT" == *"key is not"* ]] && nothing_written; then
    ok "a published certificate with an unpublished key is an error"
else
    bad "a published certificate with an unpublished key is an error" "exit ${RC}: ${OUT}"
fi

# A leaf's servername comes from --cluster-name. Signed by another
# cluster's CA it is trusted by nobody here, on a node that then joins
# nothing while reporting healthy.
reset_scenario
published "$CA_OTHER"
run_issue
if [[ "$RC" != "0" && "$OUT" == *"is not ${CLUSTER}'s"* ]] && nothing_written; then
    ok "another cluster's CA is refused, and nothing is written"
else
    bad "another cluster's CA is refused, and nothing is written" "exit ${RC}: ${OUT}"
fi

reset_scenario
store "${PREFIX}/bootstrap-ca.crt" String "${CA_OURS}/ca.crt"
store "${PREFIX}/bootstrap-ca.key" SecureString "${CA_OTHER}/ca.key" "$NODE_KMS"
run_issue
if [[ "$RC" != "0" && "$OUT" == *"does not belong"* ]] && nothing_written; then
    ok "a key that is not the CA's is refused before anything is signed"
else
    bad "a key that is not the CA's is refused before anything is signed" "exit ${RC}: ${OUT}"
fi

reset_scenario
published "$CA_OURS"
export FAKE_SSM_RC=254
run_issue
if [[ "$RC" != "0" && "$OUT" == *"ssm:GetParameter"* ]] && nothing_written; then
    ok "an SSM failure is an error that names the permission to check"
else
    bad "an SSM failure is an error that names the permission to check" "exit ${RC}: ${OUT}"
fi

reset_scenario
published "$CA_OURS"
export FAKE_IMDS_RC=7
run_issue
if [[ "$RC" != "0" ]] && nothing_written; then
    ok "no instance metadata, no certificate"
else
    bad "no instance metadata, no certificate" "exit ${RC}: ${OUT}"
fi

# ---------------------------------------------------------------------------
printf '\n=== Publishing the CA ===\n'
# ---------------------------------------------------------------------------
reset_scenario
unpublished
run_publish --tls-dir "$CA_OURS"
PUT_KEY="$(grep 'put-parameter' <<< "$LOG" | grep 'bootstrap-ca.key' || true)"

if [[ "$RC" == "0" && "$OUT" == *"Published and read back"* ]]; then
    ok "it publishes, and reports success only after reading back"
else
    bad "it publishes, and reports success only after reading back" "exit ${RC}: ${OUT}"
fi

# Pinned to the key the parameter was created under. Without --key-id,
# SSM re-encrypts under aws/ssm, which the node role cannot decrypt: the
# put succeeds and every replacement then fails to read the CA at boot.
if [[ "$PUT_KEY" == *"--type SecureString"* && "$PUT_KEY" == *"--key-id ${NODE_KMS}"* ]]; then
    ok "the key goes back under the KMS key it was created with"
else
    bad "the key goes back under the KMS key it was created with" "put: ${PUT_KEY:-<none>}"
fi

STORED_KEYID="$(cat "${FAKE_SSM_DIR}/$(printf '%s' "${PREFIX}/bootstrap-ca.key" | tr '/' '_').keyid" 2>/dev/null || echo none)"
if [[ "$STORED_KEYID" == "$NODE_KMS" ]]; then
    ok "and that is the key it is stored under afterwards"
else
    bad "and that is the key it is stored under afterwards" "stored under ${STORED_KEYID}"
fi

if [[ "$OUT" != *"PRIVATE KEY"* ]]; then
    ok "the key is never printed"
else
    bad "the key is never printed"
fi

# A node reading what was just published gets a working certificate --
# the two scripts agree end to end, through the shim's store.
run_issue
if [[ "$RC" == "0" ]] && openssl verify -CAfile "${CA_OURS}/ca.crt" "${TLS}/vault.crt" >/dev/null 2>&1; then
    ok "a node reading what was published issues a certificate that verifies"
else
    bad "a node reading what was published issues a certificate that verifies" "exit ${RC}: ${OUT}"
fi

reset_scenario
run_publish --tls-dir "$CA_OURS"
if [[ "$RC" != "0" && "$OUT" == *"apply the profile first"* && "$LOG" != *"put-parameter"* ]]; then
    ok "with no parameters to overwrite it stops, and creates none"
else
    bad "with no parameters to overwrite it stops, and creates none" "exit ${RC}: ${OUT}"
fi

reset_scenario
unpublished
run_publish --tls-dir "$CA_OTHER"
if [[ "$RC" != "0" && "$OUT" == *"is not ${CLUSTER}'s"* && "$LOG" != *"put-parameter"* ]]; then
    ok "another cluster's CA is refused before anything is written"
else
    bad "another cluster's CA is refused before anything is written" "exit ${RC}: ${OUT}"
fi

MIXED="${WORK}/mixed"; mkdir -p "$MIXED"
cp "${CA_OURS}/ca.crt" "${MIXED}/ca.crt"; cp "${CA_OTHER}/ca.key" "${MIXED}/ca.key"
reset_scenario
unpublished
run_publish --tls-dir "$MIXED"
if [[ "$RC" != "0" && "$OUT" == *"does not belong"* && "$LOG" != *"put-parameter"* ]]; then
    ok "a key that is not the certificate's is refused before anything is written"
else
    bad "a key that is not the certificate's is refused before anything is written" "exit ${RC}: ${OUT}"
fi

# One parameter at a time. Corrupting both let the certificate's check
# stand in for the key's: with the key's read-back removed entirely, this
# still passed -- which is how it was found.
for which in bootstrap-ca.crt bootstrap-ca.key; do
    reset_scenario
    unpublished
    export FAKE_SSM_CORRUPT_NAME="$which"
    run_publish --tls-dir "$CA_OURS"
    if [[ "$RC" != "0" && "$OUT" == *"${which} does not read back"* ]]; then
        ok "a ${which} that does not read back is a failure, not a success"
    else
        bad "a ${which} that does not read back is a failure, not a success" "exit ${RC}: ${OUT}"
    fi
done

# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
printf '\n=== Azure: the same CA, reached through Key Vault ===\n'
# ---------------------------------------------------------------------------
# The Azure profile had no self-issued certificate at all until 2026-09-25:
# cloud-init said so in a comment and left a replacement waiting for a
# person. This is the same script, the same openssl recipe and the same SAN
# set; only where the CA comes from differs.
reset_scenario
published_azure "$CA_OURS"
run_issue_azure
if [[ "$RC" == "0" ]]; then
    ok "a published CA in Key Vault issues a leaf"
else
    bad "a published CA in Key Vault issues a leaf" "$(tail -3 <<< "$OUT")"
fi
if [[ -s "${TLS}/vault.crt" && -s "${TLS}/vault.key" ]]; then
    ok "and writes both halves"
else
    bad "and writes both halves" "$(ls -l "$TLS" 2>&1)"
fi
if openssl verify -CAfile "${CA_OURS}/ca.crt" "${TLS}/vault.crt" >/dev/null 2>&1; then
    ok "the leaf verifies against that CA"
else
    bad "the leaf verifies against that CA" "$(openssl verify -CAfile "${CA_OURS}/ca.crt" "${TLS}/vault.crt" 2>&1)"
fi

# The CN has to be the VM name: cloud-init derives Raft's node_id from
# compute/name, so a leaf naming anything else names a node the cluster
# does not have -- and the failure is a node that starts and never joins.
if openssl x509 -in "${TLS}/vault.crt" -noout -subject | grep -q "vault-reference_3"; then
    ok "the CN is the VM name, which is also the Raft node_id"
else
    bad "the CN is the VM name, which is also the Raft node_id" \
        "$(openssl x509 -in "${TLS}/vault.crt" -noout -subject 2>&1)"
fi

# The load balancer's address is an IP SAN, not a DNS entry holding an
# address -- Azure's load balancer has no name to give. A DNS entry there
# matches nothing, and the leaf would verify for every client except the
# ones arriving through the load balancer.
if openssl x509 -in "${TLS}/vault.crt" -noout -text | grep -q "IP Address:10.1.1.7"; then
    ok "the load balancer's address is an IP SAN"
else
    bad "the load balancer's address is an IP SAN" \
        "$(openssl x509 -in "${TLS}/vault.crt" -noout -text | grep -A2 'Alternative Name' || true)"
fi

# The cluster servername every follower verifies a leader against.
if openssl x509 -in "${TLS}/vault.crt" -noout -checkhost "${CLUSTER}.vault.internal" >/dev/null 2>&1; then
    ok "and the cluster servername a follower checks"
else
    bad "and the cluster servername a follower checks" "no ${CLUSTER}.vault.internal SAN"
fi

# The token is a managed identity's, asked of IMDS with the Metadata header
# and scoped to vault.azure.net. No az CLI on the node, no credential on
# disk.
if grep -q "resource=https%3A%2F%2Fvault.azure.net" <<< "$LOG"; then
    ok "the token is scoped to Key Vault"
else
    bad "the token is scoped to Key Vault" "$(grep -o 'oauth2[^ ]*' <<< "$LOG" | head -1)"
fi
if grep -q "az keyvault" <<< "$LOG"; then
    bad "and nothing shells out to the az CLI" "the node would need az installed"
else
    ok "and nothing shells out to the az CLI"
fi

# ---------------------------------------------------------------------------
printf '\n=== Azure: an unpublished CA is not an error ===\n'
# ---------------------------------------------------------------------------
# On a first apply no secret exists yet, which Key Vault answers with 404.
# Failing here would bury the one message that matters -- certificates come
# from the Ansible layer this time -- under a red one that does not.
reset_scenario
published_azure "$CA_OURS"
export FAKE_AZ_CRT_SECRET="absent"
run_issue_azure
if [[ "$RC" == "0" ]]; then
    ok "a missing secret exits 0 rather than failing the boot"
else
    bad "a missing secret exits 0 rather than failing the boot" "$(tail -2 <<< "$OUT")"
fi
if grep -q "has not been published" <<< "$OUT"; then
    ok "and says so in the boot log"
else
    bad "and says so in the boot log" "$(tail -2 <<< "$OUT")"
fi
if [[ ! -e "${TLS}/vault.crt" ]]; then
    ok "and writes no certificate"
else
    bad "and writes no certificate" "wrote one from a CA that is not published"
fi

# A published certificate with no key is a half-run publish, and signing is
# impossible -- that one must fail loudly rather than exit 0 like the case
# above, or the node waits forever for an Ansible run nobody is coming to do.
reset_scenario
published_azure "$CA_OURS"
export FAKE_AZ_KEY_SECRET="absent"
run_issue_azure
if [[ "$RC" != "0" ]]; then
    ok "a certificate published without its key fails"
else
    bad "a certificate published without its key fails" "exit was 0"
fi
if grep -qi "key is not" <<< "$OUT"; then
    ok "and says which half is missing"
else
    bad "and says which half is missing" "$(tail -2 <<< "$OUT")"
fi

# ---------------------------------------------------------------------------
printf '\n=== Azure: the failures that name what to fix ===\n'
# ---------------------------------------------------------------------------
# 403 rather than 404: the identity is missing Get on secrets. Distinct from
# "not published", and the two are indistinguishable if the status is
# dropped -- which is why the script asks curl for it.
reset_scenario
published_azure "$CA_OURS"
export FAKE_AZ_CRT_SECRET="denied"
run_issue_azure
if [[ "$RC" != "0" ]]; then
    ok "a refused read fails rather than looking unpublished"
else
    bad "a refused read fails rather than looking unpublished" "exit was 0, so the node waits for Ansible instead"
fi
if grep -qi "Get on secrets" <<< "$OUT"; then
    ok "and names the permission the identity is missing"
else
    bad "and names the permission the identity is missing" "$(tail -3 <<< "$OUT")"
fi

reset_scenario
published_azure "$CA_OURS"
export FAKE_AZ_TOKEN_RC=22
run_issue_azure
if [[ "$RC" != "0" ]]; then
    ok "no managed-identity token fails"
else
    bad "no managed-identity token fails" "exit was 0"
fi
if grep -qi "identity" <<< "$OUT"; then
    ok "and points at the identity rather than at Key Vault"
else
    bad "and points at the identity rather than at Key Vault" "$(tail -2 <<< "$OUT")"
fi

# --key-vault is what --ca-parameter-prefix is on AWS: without it there is
# nothing to ask.
reset_scenario
RC=0
OUT="$(PATH="${FAKE_BIN}:${PATH}" "$ISSUE" --cloud azure --cluster-name "$CLUSTER" \
    --tls-dir "$TLS" 2>&1)" || RC=$?
if [[ "$RC" != "0" ]] && grep -q "key-vault" <<< "$OUT"; then
    ok "azure without --key-vault fails and names it"
else
    bad "azure without --key-vault fails and names it" "rc=${RC}: $(tail -1 <<< "$OUT")"
fi

reset_scenario
RC=0
OUT="$(PATH="${FAKE_BIN}:${PATH}" "$ISSUE" --cloud gcp --cluster-name "$CLUSTER" \
    --tls-dir "$TLS" 2>&1)" || RC=$?
if [[ "$RC" != "0" ]] && grep -q "must be aws or azure" <<< "$OUT"; then
    ok "an unknown --cloud is refused"
else
    bad "an unknown --cloud is refused" "rc=${RC}: $(tail -1 <<< "$OUT")"
fi

printf '\n=== Results ===\n'
# ---------------------------------------------------------------------------
printf 'passed: %d\nfailed: %d\n' "$PASS" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
    red "FAILED"
    exit 1
fi
green "All ${PASS} assertions passed."

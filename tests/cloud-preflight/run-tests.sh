#!/usr/bin/env bash
#
# run-tests.sh — Tests for the cloud pre-flight and teardown scripts
#
# Usage:
#   ./tests/cloud-preflight/run-tests.sh
#
# Runs in about a second. No cloud, no credentials, no money.
#
# What these can and cannot establish:
#
# They check the decisions the two scripts make — whether a missing key
# pair is a failure or a warning, whether the exit code reflects it,
# whether teardown empties the bucket before calling destroy, whether the
# paging loop terminates. Those are properties of the scripts, and shims
# can settle them.
#
# They cannot check that AWS agrees. `terraform plan` succeeding here
# means the shim exited 0. That is the entire reason docs/cloud-apply.md
# exists: the parts a shim cannot reach are listed there as things a
# human has to observe once, against a real account.
#
# Two assertions are worth calling out because they encode bugs that were
# actually written:
#
#   - the Azure cost lines price one NAT gateway. They used to multiply
#     by az_count -- a variable only the AWS profile defines -- so on
#     Azure it resolved to nothing, fell back to a literal 3, and quoted
#     three gateways at $96 while labelling them the largest line. That
#     sent the reader's cost-cutting at the one line they cannot cut.
#   - the pre-flight never invokes `terraform apply`. A pre-flight that
#     spends money is worse than no pre-flight, and it is one typo away.
#
# Requirements: bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PREFLIGHT="${REPO_ROOT}/scripts/preflight-cloud.sh"
TEARDOWN="${REPO_ROOT}/scripts/teardown-cloud.sh"
FAKE_BIN="${SCRIPT_DIR}/fake-bin"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

green() { printf '\033[32m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*"; }

ok()  { PASS=$((PASS + 1)); green "  PASS  $1"; }
bad() { FAIL=$((FAIL + 1)); red   "  FAIL  $1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; return 0; }

[[ -x "$PREFLIGHT" ]] || { red "Not executable: ${PREFLIGHT}"; exit 1; }
[[ -x "$TEARDOWN"  ]] || { red "Not executable: ${TEARDOWN}"; exit 1; }

RC=0
OUT=""

reset_scenario() {
    FAKE_LOG="${WORK}/log.$RANDOM"
    FAKE_STATE_DIR="${WORK}/state.$RANDOM"
    mkdir -p "$FAKE_STATE_DIR"
    : > "$FAKE_LOG"
    export FAKE_LOG FAKE_STATE_DIR

    export FAKE_TF_PROVIDERS_RC=0
    export FAKE_TF_PLAN_RC=0
    export FAKE_TF_DESTROY_RC=0
    export FAKE_TF_STATE_RC=0
    export FAKE_TF_STATE_LIST="aws_vpc.vault"
    export FAKE_TF_OUTPUT="vault-snapshots-abc123"
    export FAKE_TF_OUTPUT_RC=0

    export FAKE_AWS_IDENTITY_RC=0
    export FAKE_AWS_ACCOUNT="123456789012"
    export FAKE_AWS_KEYPAIR_RC=0
    export FAKE_AWS_EIP_RC=0
    export FAKE_AWS_EIP_USED=0
    export FAKE_AWS_LIST_RC=0
    export FAKE_AWS_DELETE_RC=0
    export FAKE_AWS_Versions_PAGES=0
    export FAKE_AWS_DeleteMarkers_PAGES=0

    export FAKE_AZ_ACCOUNT_RC=0
    export FAKE_AZ_ROLE_RC=0
    export FAKE_AZ_ROLES="Contributor"
}

# run_preflight <args...>
run_preflight() {
    RC=0
    OUT="$(PATH="${FAKE_BIN}:${PATH}" "$PREFLIGHT" "$@" 2>&1)" || RC=$?
}

# run_teardown <stdin> <args...>
run_teardown() {
    local input="$1"; shift
    RC=0
    OUT="$(printf '%s\n' "$input" | PATH="${FAKE_BIN}:${PATH}" "$TEARDOWN" "$@" 2>&1)" || RC=$?
}

logged()     { grep -q -- "$1" "$FAKE_LOG" 2>/dev/null; }
log_line_of() { grep -n -- "$1" "$FAKE_LOG" 2>/dev/null | head -1 | cut -d: -f1; }

# A Terraform directory with variables we control, so the pre-flight's
# input checks can be driven both ways. Pointing --dir at it also
# exercises the option.
mk_tfdir() {
    local dir="$1" key="$2"
    mkdir -p "$dir"
    cat > "${dir}/variables.tf" <<EOF
variable "az_count" {
  type    = number
  default = 3
}

variable "node_count" {
  type    = number
  default = 3
}

variable "ssh_key_name" {
  type    = string
  default = "${key}"
}
EOF
}

# The Azure profile's variables are a different set -- no az_count at all,
# which is the whole point of the cost assertions below.
mk_azure_tfdir() {
    local dir="$1" nodes="$2" size="$3"
    mkdir -p "$dir"
    cat > "${dir}/variables.tf" <<EOF
variable "availability_zones" {
  type    = list(string)
  default = ["1", "2", "3"]
}

variable "node_count" {
  type    = number
  default = ${nodes}
}

variable "vm_size" {
  type    = string
  default = "${size}"
}

variable "os_disk_size_gb" {
  type    = number
  default = 64
}
EOF
}

WITH_KEY="${WORK}/tf-with-key"
mk_tfdir "$WITH_KEY" "my-keypair"

printf '\n=== Pre-flight: it never spends anything ===\n'

reset_scenario
run_preflight --cloud aws
if logged "terraform apply"; then
    bad "the pre-flight never runs terraform apply" "it did — see ${FAKE_LOG}"
else
    ok "the pre-flight never runs terraform apply"
fi

if logged "plan"; then
    ok "it does run terraform plan"
else
    bad "it does run terraform plan" "plan is the only cloud call worth making for free"
fi

reset_scenario
run_preflight --cloud aws
# The repo's own aws profile ships ssh_key_name empty, which is a warning
# rather than a failure — so this must still exit 0.
if [[ "$RC" == "0" ]]; then
    ok "warnings alone exit 0"
else
    bad "warnings alone exit 0" "exit ${RC}; warnings are things to have read, not blockers"
fi

printf '\n=== Pre-flight: the inputs that fail late ===\n'

reset_scenario
run_preflight --cloud aws
if grep -q "ssh_key_name is empty" <<< "$OUT"; then
    ok "an empty ssh_key_name is called out"
else
    bad "an empty ssh_key_name is called out" "the apply succeeds and nobody can log in"
fi

if grep -q "not be able to log in" <<< "$OUT"; then
    ok "and it says why that matters"
else
    bad "and it says why that matters" "a warning without a consequence gets skipped"
fi

reset_scenario
export FAKE_AWS_KEYPAIR_RC=0
run_preflight --cloud aws --dir "$WITH_KEY"
if grep -q "key pair exists" <<< "$OUT" && [[ "$RC" == "0" ]]; then
    ok "a key pair that exists passes"
else
    bad "a key pair that exists passes" "exit ${RC}"
fi

reset_scenario
export FAKE_AWS_KEYPAIR_RC=254
run_preflight --cloud aws --dir "$WITH_KEY"
if grep -q "does not exist in this account" <<< "$OUT" && [[ "$RC" != "0" ]]; then
    ok "a key pair that does not exist is a failure, not a warning"
else
    bad "a key pair that does not exist is a failure, not a warning" \
        "exit ${RC} — this one fails after the NAT gateways are billing"
fi

reset_scenario
run_preflight --cloud aws
# Anchored to the labelled line, not just the digits: the ARN contains
# the account id too, so a bare search for it passed even with the
# account line removed. The point is a line someone will actually read.
if grep -q "account: 123456789012" <<< "$OUT"; then
    ok "it prints the account you are about to spend in, on its own line"
else
    bad "it prints the account you are about to spend in, on its own line" \
        "the wrong-account apply is the expensive kind of mistake"
fi

printf '\n=== Pre-flight: quota ===\n'

reset_scenario
export FAKE_AWS_EIP_USED=4
run_preflight --cloud aws --az-count 3
if grep -q "exceed the default limit" <<< "$OUT"; then
    ok "4 EIPs in use plus 3 more exceeds the default limit of 5"
else
    bad "4 EIPs in use plus 3 more exceeds the default limit of 5"
fi

reset_scenario
export FAKE_AWS_EIP_USED=4
run_preflight --cloud aws --az-count 1
if grep -q "headroom looks sufficient" <<< "$OUT"; then
    ok "4 in use plus 1 more does not"
else
    bad "4 in use plus 1 more does not" "the check must use az_count, not a constant"
fi

reset_scenario
export FAKE_AWS_EIP_RC=1
run_preflight --cloud aws
if grep -q "could not read Elastic IP usage" <<< "$OUT" && [[ "$RC" == "0" ]]; then
    ok "an unreadable EIP quota is a warning, not a failure"
else
    bad "an unreadable EIP quota is a warning, not a failure" "exit ${RC}"
fi

printf '\n=== Pre-flight: cost is arithmetic ===\n'

reset_scenario
run_preflight --cloud aws --az-count 2
# 2 NAT gateways at ~33 = 66. If this were concatenation it would read 23.
# shellcheck disable=SC2016  # the dollar is literal — it is the cost line
if grep -qF '$66/month' <<< "$OUT"; then
    ok "AWS NAT cost scales with az_count (2 -> \$66)"
else
    bad "AWS NAT cost scales with az_count (2 -> \$66)" \
        "$(grep -i 'NAT gateway' <<< "$OUT" || true)"
fi

# The Azure profile creates one azurerm_nat_gateway for the whole VNet,
# with no count. This used to multiply a NAT line by az_count -- an AWS
# variable Azure does not define -- so it resolved to nothing, fell back to
# a literal 3, and quoted three gateways at $96. The old wrong value is
# pinned as a negative beside the positive, so a rewording that loses the
# fix fails loudly rather than passing on a phrase nothing prints.
reset_scenario
run_preflight --cloud azure
# Count and price pinned on the same line. Naming only the count let a
# mutation that repriced the gateway walk through -- the label still
# said one, and $96 still did not appear.
# shellcheck disable=SC2016  # literal dollars; $96 is the old bug's output
if grep -qE '1 NAT gateway +~[$]33/month' <<< "$OUT" && ! grep -qF '$96/month' <<< "$OUT"; then
    ok "Azure prices the one NAT gateway the profile actually creates"
else
    bad "Azure prices the one NAT gateway the profile actually creates" \
        "$(grep -i 'NAT gateway' <<< "$OUT" || true)"
fi

# The marker tells the reader where to cut cost. On Azure the NAT is
# regional and fixed, so pointing it there sends them after the one line
# they cannot change. Asserted on the whole line, not on the marker alone.
# Not anchored with ^: info() colours its output, so every line starts
# with an escape sequence rather than whitespace. Matching the VM count
# through to the marker is what makes this about the line rather than
# about the marker existing somewhere.
if grep -qE '[0-9]+ VM\(s\).*largest line' <<< "$OUT"; then
    ok "and marks the VMs as the largest line, not the NAT"
else
    bad "and marks the VMs as the largest line, not the NAT" \
        "$(grep -i 'largest line' <<< "$OUT" || true)"
fi

# --az-count drives the AWS EIP check, so the flag stays -- but it must say
# it does nothing here rather than silently pricing something.
reset_scenario
run_preflight --cloud azure --az-count 2
if grep -q 'az-count has no effect' <<< "$OUT" && [[ "$RC" == "0" ]]; then
    ok "--az-count on Azure warns rather than silently mispricing"
else
    bad "--az-count on Azure warns rather than silently mispricing" "exit ${RC}"
fi

# Arithmetic still guarded, on the line where it now matters. Five nodes at
# ~$30 is $150 -- a value no assertion above names, so a compute line that
# stopped scaling with node_count could not pass by coincidence.
reset_scenario
AZ_DIR="${WORK}/tf-azure-5"
mk_azure_tfdir "$AZ_DIR" 5 "Standard_B2s"
run_preflight --cloud azure --dir "$AZ_DIR"
# shellcheck disable=SC2016  # literal dollar in an expected cost line
if grep -qF '$150/month' <<< "$OUT"; then
    ok "the Azure compute line scales with node_count (5 -> \$150)"
else
    bad "the Azure compute line scales with node_count (5 -> \$150)" \
        "$(grep -i 'VM(s)' <<< "$OUT" || true)"
fi

# The per-VM figure is a guess about Standard_B2s. Anything else and the
# estimate is a placeholder, which it should admit rather than assert.
reset_scenario
AZ_BIG="${WORK}/tf-azure-big"
mk_azure_tfdir "$AZ_BIG" 3 "Standard_D8s_v5"
run_preflight --cloud azure --dir "$AZ_BIG"
if grep -q 'assumes the default Standard_B2s' <<< "$OUT"; then
    ok "a non-default vm_size is called a placeholder, not an estimate"
else
    bad "a non-default vm_size is called a placeholder, not an estimate"
fi

reset_scenario
run_preflight --cloud aws --az-count 3
if grep -q 'az-count 1 removes' <<< "$OUT"; then
    ok "it names the saving from dropping to one zone"
else
    bad "it names the saving from dropping to one zone" \
        "az_count is the dominant line item and the only easy lever"
fi

reset_scenario
run_preflight --cloud aws --az-count 1
if ! grep -q 'az-count 1 removes' <<< "$OUT"; then
    ok "and does not suggest it when already at one zone"
else
    bad "and does not suggest it when already at one zone"
fi

printf '\n=== Pre-flight: what teardown will not remove ===\n'

reset_scenario
run_preflight --cloud aws
if grep -q "blocks terraform destroy" <<< "$OUT" && grep -q "7-day deletion window" <<< "$OUT"; then
    ok "AWS: names the bucket and the KMS deletion window"
else
    bad "AWS: names the bucket and the KMS deletion window"
fi

reset_scenario
run_preflight --cloud azure
if grep -q "cannot be purged for 90 days" <<< "$OUT"; then
    ok "Azure: names the Key Vault retention before you apply, not after"
else
    bad "Azure: names the Key Vault retention before you apply, not after"
fi

printf '\n=== Pre-flight: Azure permissions ===\n'

reset_scenario
export FAKE_AZ_ROLES="Contributor"
run_preflight --cloud azure
if grep -q "could not confirm Owner" <<< "$OUT"; then
    ok "Contributor alone is flagged"
else
    bad "Contributor alone is flagged" "the role assignment fails late and confusingly"
fi

reset_scenario
export FAKE_AZ_ROLES="Owner"
run_preflight --cloud azure
if grep -q "can create role assignments" <<< "$OUT"; then
    ok "Owner passes"
else
    bad "Owner passes"
fi

printf '\n=== Pre-flight: plan ===\n'

reset_scenario
export FAKE_TF_PROVIDERS_RC=1
run_preflight --cloud aws
if grep -q "not initialised" <<< "$OUT" && ! logged "plan"; then
    ok "an uninitialised directory is reported, and plan is not attempted"
else
    bad "an uninitialised directory is reported, and plan is not attempted" \
        "planning without init produces a confusing error instead of a clear one"
fi

reset_scenario
export FAKE_TF_PLAN_RC=1
run_preflight --cloud aws
if grep -q "terraform plan failed" <<< "$OUT" && [[ "$RC" != "0" ]]; then
    ok "a failing plan is a failure and exits non-zero"
else
    bad "a failing plan is a failure and exits non-zero" "exit ${RC}"
fi

reset_scenario
RC=0
OUT="$(PATH="${FAKE_BIN}:${PATH}" "$PREFLIGHT" --cloud gcp 2>&1)" || RC=$?
if [[ "$RC" != "0" ]]; then
    ok "an unsupported cloud is rejected"
else
    bad "an unsupported cloud is rejected"
fi

printf '\n=== Teardown: it does not destroy by accident ===\n'

reset_scenario
export FAKE_TF_STATE_LIST=""
run_teardown "" --cloud aws
if [[ "$RC" == "0" ]] && ! logged "destroy"; then
    ok "empty state exits 0 without calling destroy"
else
    bad "empty state exits 0 without calling destroy" "exit ${RC}"
fi

reset_scenario
export FAKE_TF_STATE_RC=1
run_teardown "" --cloud aws
if [[ "$RC" == "0" ]] && ! logged "destroy"; then
    ok "no state at all exits 0 without calling destroy"
else
    bad "no state at all exits 0 without calling destroy" "exit ${RC}"
fi

reset_scenario
run_teardown "" --cloud aws --plan-only
if ! logged "destroy -auto-approve" && ! logged "delete-objects"; then
    ok "--plan-only destroys nothing and empties nothing"
else
    bad "--plan-only destroys nothing and empties nothing"
fi

reset_scenario
run_teardown "yes" --cloud aws
if [[ "$RC" != "0" ]] && ! logged "destroy -auto-approve"; then
    ok "typing something other than the cloud name aborts"
else
    bad "typing something other than the cloud name aborts" \
        "exit ${RC} — confirmation must be the cloud name, not any input"
fi

reset_scenario
run_teardown "aws" --cloud aws
if logged "destroy -auto-approve"; then
    ok "typing the cloud name proceeds"
else
    bad "typing the cloud name proceeds"
fi

printf '\n=== Teardown: the bucket is emptied before destroy ===\n'

reset_scenario
export FAKE_AWS_Versions_PAGES=1
export FAKE_AWS_DeleteMarkers_PAGES=1
run_teardown "" --cloud aws --yes

if logged "delete-objects"; then
    ok "objects are deleted"
else
    bad "objects are deleted" "destroy fails with BucketNotEmpty without this"
fi

DEL_LINE="$(log_line_of "delete-objects")"
DESTROY_LINE="$(log_line_of "destroy -auto-approve")"
if [[ -n "$DEL_LINE" && -n "$DESTROY_LINE" && "$DEL_LINE" -lt "$DESTROY_LINE" ]]; then
    ok "and they are deleted BEFORE destroy is called"
else
    bad "and they are deleted BEFORE destroy is called" \
        "delete at line ${DEL_LINE:-none}, destroy at line ${DESTROY_LINE:-none}"
fi

if grep -q 'DeleteMarkers' "$FAKE_LOG"; then
    ok "delete markers are collected too, not just object versions"
else
    bad "delete markers are collected too, not just object versions" \
        "s3 rm leaves delete markers behind and the bucket is still not empty"
fi

if grep -q 'delete "file://' "$FAKE_LOG" || grep -q 'file://' "$FAKE_LOG"; then
    ok "the batch is passed as a file, not an inline argument"
else
    bad "the batch is passed as a file, not an inline argument" \
        "an inline --delete built in a pipeline does not work"
fi

printf '\n=== Teardown: the paging loop terminates ===\n'

reset_scenario
export FAKE_AWS_Versions_PAGES=2
export FAKE_AWS_DeleteMarkers_PAGES=0
run_teardown "" --cloud aws --yes
DELETES="$(grep -c 'delete-objects' "$FAKE_LOG" || true)"
if [[ "$DELETES" == "2" ]]; then
    ok "two pages of versions produce two delete calls"
else
    bad "two pages of versions produce two delete calls" \
        "got ${DELETES} — a loop that stops after one page leaves the bucket full"
fi

reset_scenario
export FAKE_AWS_Versions_PAGES=0
export FAKE_AWS_DeleteMarkers_PAGES=0
run_teardown "" --cloud aws --yes
if [[ "$RC" == "0" ]] && ! logged "delete-objects"; then
    ok "an already-empty bucket deletes nothing and still destroys"
else
    bad "an already-empty bucket deletes nothing and still destroys" "exit ${RC}"
fi

reset_scenario
export FAKE_AWS_Versions_PAGES=1
export FAKE_AWS_DELETE_RC=1
run_teardown "" --cloud aws --yes
if grep -q "destroy will likely fail" <<< "$OUT"; then
    ok "a failing delete says destroy will likely fail rather than looping"
else
    bad "a failing delete says destroy will likely fail rather than looping"
fi

printf '\n=== Teardown: failures and what survives ===\n'

reset_scenario
export FAKE_TF_DESTROY_RC=1
run_teardown "" --cloud aws --yes
if [[ "$RC" != "0" ]]; then
    ok "a failed destroy exits non-zero"
else
    bad "a failed destroy exits non-zero" \
        "a teardown that reports success while resources bill is the worst outcome"
fi

reset_scenario
run_teardown "" --cloud aws --yes
if grep -q "PendingDeletion\|scheduled for deletion" <<< "$OUT"; then
    ok "AWS: the surviving KMS key is reported"
else
    bad "AWS: the surviving KMS key is reported"
fi

reset_scenario
run_teardown "" --cloud azure --yes
if grep -q "soft-deleted" <<< "$OUT" && grep -q "90" <<< "$OUT"; then
    ok "Azure: the soft-deleted Key Vault and its retention are reported"
else
    bad "Azure: the soft-deleted Key Vault and its retention are reported"
fi

if ! logged "s3api"; then
    ok "Azure: no S3 calls are attempted"
else
    bad "Azure: no S3 calls are attempted"
fi

printf '\n'
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
green "All cloud pre-flight tests passed."

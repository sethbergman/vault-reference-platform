#!/usr/bin/env bash
#
# run-tests.sh — Apply the AWS profile as an identity that is not an administrator
#
# Usage:
#   ./tests/least-privilege-apply/run-tests.sh
#
# Takes a few minutes. Costs nothing and creates nothing outside a local
# process.
#
# WHY THIS EXISTS
#
# Every real apply of this repository's cloud profiles -- six of them, across
# two clouds -- was driven by an administrator. So the profiles are known to
# work for somebody who can do anything, which is the one identity nobody
# should be using. "What does this actually need?" had no answer.
#
# examples/policies/aws-terraform-apply.json is that answer, and this suite is
# what keeps it true. It applies and destroys terraform/aws as an IAM user
# holding only that policy, against an emulated AWS API that enforces IAM.
#
# HOW THE POLICY WAS WRITTEN, WHICH MATTERS FOR TRUSTING IT
#
# Not by reading AWS documentation and not by guessing. moto's request
# recorder captured every request one apply and one destroy actually made --
# 565 of them -- and each one names its service in the SigV4 credential scope
# and its action in the request body or the X-Amz-Target header. 115 actions,
# read off what the provider did rather than off what the configuration says.
#
# Two of them are the argument for deriving rather than guessing:
# `sts:GetCallerIdentity` is called even with `skip_requesting_account_id`
# set, and the provider probes `ec2:GetInstanceUefiData` and
# `elasticloadbalancing:DescribeCapacityReservation` -- nobody writing a
# policy by hand would include those, and the apply fails without them.
#
# WHAT A GREEN RUN MEANS, AND WHAT IT DOES NOT
#
# It means: the profile applies and destroys with those actions and no others,
# for eight of the nine services it uses. Every denial in this emulator is a
# real policy evaluation against a real access key.
#
# It does NOT mean:
#
#   - that S3 is covered. moto names S3 actions from botocore OPERATION names
#     rather than IAM action names -- a bucket HEAD is checked as
#     `s3:HeadBucket`, which IAM does not have -- so this run hands it `s3:*`
#     and proves nothing about the S3 statement. That statement is derived
#     from the 25 recorded bucket requests and is the part of the file a real
#     apply still has to settle.
#   - that the policy is MINIMAL. It is sufficient by construction; an action
#     the provider requests is not necessarily one AWS requires.
#   - that it is resource-scoped. Every statement is `Resource: "*"`. This
#     narrows what the identity can do, not what it can do it to.
#   - that AWS agrees. moto's evaluator is an approximation: no SCPs, no
#     permission boundaries, no resource policies.
#
# docs/least-privilege.md states all of that in the same words.
#
# WHY THE NEGATIVE CASES ARE HERE
#
# A positive result alone cannot distinguish "the policy is sufficient" from
# "authorization is not switched on". Each negative run removes one action and
# requires the apply to fail. They are chosen as three different shapes:
# a create nothing works without, a read nobody would think to grant, and a
# read of something the profile itself created.
#
# Requirements: terraform, python3 with moto[server] and boto3, curl

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TF_DIR="${REPO_ROOT}/terraform/aws"
POLICY="${REPO_ROOT}/examples/policies/aws-terraform-apply.json"

OVERRIDE_SRC="${SCRIPT_DIR}/provider_override.tf"
OVERRIDE_DST="${TF_DIR}/zz_leastpriv_override.tf"
BACKEND_SRC="${SCRIPT_DIR}/backend_override.tf"
BACKEND_DST="${TF_DIR}/zz_leastpriv_backend_override.tf"

ENDPOINT="http://localhost:5000"
WORK="$(mktemp -d)"
MOTO_PID=""
CLAIMED=false

PASS=0
FAIL=0

green() { printf '\033[32m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*"; }
info()  { printf '\033[36m%s\033[0m\n' "$*"; }

ok()  { PASS=$((PASS + 1)); green "  PASS  $1"; }
bad() { FAIL=$((FAIL + 1)); red   "  FAIL  $1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; return 0; }

usage() {
    sed -n '2,${ /^#/!q; s/^# \{0,1\}//p; }' "$0"
    exit 1
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && usage

stop_moto() {
    if [[ -n "$MOTO_PID" ]]; then
        kill "$MOTO_PID" 2>/dev/null
        wait "$MOTO_PID" 2>/dev/null
        MOTO_PID=""
    fi
}

cleanup() {
    stop_moto
    # Only remove what this run put there. A suite that cleans a workspace it
    # never claimed is a suite that deletes somebody's half-finished apply.
    if [[ "$CLAIMED" == true ]]; then
        rm -f "$OVERRIDE_DST" "$BACKEND_DST" \
              "${TF_DIR}/terraform.tfstate" \
              "${TF_DIR}/terraform.tfstate.backup" \
              "${TF_DIR}/.terraform.tfstate.lock.info"
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
for dep in terraform python3 curl; do
    command -v "$dep" >/dev/null 2>&1 || { red "ERROR: ${dep} not found on PATH"; exit 1; }
done
python3 -c "import moto, boto3" 2>/dev/null \
    || { red "ERROR: moto and boto3 are needed (pip install 'moto[server]' boto3)"; exit 1; }
[[ -f "$POLICY" ]] || { red "ERROR: no policy at ${POLICY}"; exit 1; }

if [[ -f "$OVERRIDE_DST" || -f "$BACKEND_DST" ]]; then
    red "ERROR: ${TF_DIR} already has this suite's override files."
    red "       Another run is in progress, or one died. Remove them and retry."
    exit 1
fi

if curl -fsS --max-time 2 "$ENDPOINT" >/dev/null 2>&1; then
    red "ERROR: something is already answering on ${ENDPOINT}."
    red "       A moto left behind by an earlier run would answer every call"
    red "       and make this suite report on state it did not create. Kill it:"
    red "         pkill -f 'moto[.]server'"
    exit 1
fi

CLAIMED=true
cp "$OVERRIDE_SRC" "$OVERRIDE_DST"
cp "$BACKEND_SRC" "$BACKEND_DST"

start_moto() {
    stop_moto
    MOTO_IAM_LOAD_MANAGED_POLICIES=true \
        python3 -m moto.server -p 5000 >"${WORK}/moto.log" 2>&1 &
    MOTO_PID=$!
    for _ in $(seq 1 40); do
        curl -fsS --max-time 1 "$ENDPOINT" >/dev/null 2>&1 && return 0
        sleep 0.5
    done
    bad "the emulator answers on ${ENDPOINT}" "$(tail -5 "${WORK}/moto.log")"
    return 1
}

# The state belongs to an emulator that dies with the process, so each case
# starts from nothing. `.terraform` is left alone: it holds the provider
# plugins, and removing it re-downloads them for every case.
reset_state() {
    rm -f "${TF_DIR}/terraform.tfstate" \
          "${TF_DIR}/terraform.tfstate.backup" \
          "${TF_DIR}/.terraform.tfstate.lock.info"
}

# apply_as <label> [--without ACTION] — returns terraform's exit status.
apply_as() {
    local label="$1"; shift
    reset_state
    start_moto || return 99

    local creds
    if ! creds="$(python3 "${SCRIPT_DIR}/setup_identity.py" "$ENDPOINT" "$POLICY" "$@" 2>"${WORK}/${label}-setup.log")"; then
        bad "the narrow identity could be created (${label})" "$(tail -5 "${WORK}/${label}-setup.log")"
        return 99
    fi
    read -r KEY_ID SECRET <<< "$creds"

    AWS_ACCESS_KEY_ID="$KEY_ID" AWS_SECRET_ACCESS_KEY="$SECRET" \
    AWS_DEFAULT_REGION=us-east-1 TF_IN_AUTOMATION=1 \
        terraform -chdir="$TF_DIR" apply -auto-approve -input=false -no-color \
        >"${WORK}/${label}-apply.log" 2>&1
}

# ---------------------------------------------------------------------------
info ""
info "=== The profile applies as an identity holding only the policy ==="
# ---------------------------------------------------------------------------
if ! start_moto; then exit 1; fi

if AWS_ACCESS_KEY_ID=setup AWS_SECRET_ACCESS_KEY=setup \
   AWS_DEFAULT_REGION=us-east-1 TF_IN_AUTOMATION=1 \
   terraform -chdir="$TF_DIR" init -input=false -no-color \
   >"${WORK}/init.log" 2>&1; then
    ok "terraform init"
else
    bad "terraform init" "$(tail -15 "${WORK}/init.log")"
    exit 1
fi
stop_moto

apply_as positive
APPLY_RC=$?
if [[ "$APPLY_RC" == "0" ]]; then
    ok "the AWS profile applies with no permission it was not granted"
else
    bad "the AWS profile applies with no permission it was not granted" \
        "$(grep -iE 'not authorized|AccessDenied|Error:' "${WORK}/positive-apply.log" | head -8)"
fi

# The destroy runs as the same identity, on the same running emulator, so the
# policy has to cover teardown too -- which is half of what an operator does
# and the half a policy written from the apply alone always misses.
if [[ "$APPLY_RC" == "0" ]]; then
    if AWS_ACCESS_KEY_ID="$KEY_ID" AWS_SECRET_ACCESS_KEY="$SECRET" \
       AWS_DEFAULT_REGION=us-east-1 TF_IN_AUTOMATION=1 \
       terraform -chdir="$TF_DIR" destroy -auto-approve -input=false -no-color \
       >"${WORK}/destroy.log" 2>&1; then
        ok "and destroys it again with the same policy"
    else
        bad "and destroys it again with the same policy" \
            "$(grep -iE 'not authorized|AccessDenied|Error:' "${WORK}/destroy.log" | head -8)"
    fi
else
    bad "and destroys it again with the same policy" "the apply did not finish"
fi
stop_moto

# ---------------------------------------------------------------------------
info ""
info "=== Removing one action stops the apply ==="
# ---------------------------------------------------------------------------
# Without these, a green run above is equally consistent with authorization
# never having been switched on. Three shapes of permission, deliberately:
#
#   ec2:CreateVpc        nothing works without it
#   ec2:DescribeImages   a read, not a write: the AMI data source resolves
#                        before anything is created, so this fails the plan
#                        rather than the apply
#   iam:GetRole          a read of something the profile itself created
#
# `ec2:DescribeNetworkAcls` was the obvious third and is NOT here, because
# the apply succeeds without it. The provider asks for it and does not need
# the answer, which is the clearest evidence available that this policy is
# derived from what the profile REQUESTS rather than from what it requires --
# a safe upper bound, not a minimal set. docs/least-privilege.md says so, and
# names the pruning pass that would settle the difference.
for victim in ec2:CreateVpc ec2:DescribeImages iam:GetRole; do
    label="without-${victim//:/-}"
    apply_as "$label" --without "$victim"
    rc=$?
    if [[ "$rc" == "99" ]]; then
        continue
    elif [[ "$rc" != "0" ]]; then
        ok "without ${victim}, the apply fails"
    else
        bad "without ${victim}, the apply fails" \
            "it applied anyway, so the policy says more than this suite proves"
    fi
    stop_moto
done

# ---------------------------------------------------------------------------
info ""
info "=== The policy file itself ==="
# ---------------------------------------------------------------------------
# IAM's managed-policy limit is 6144 characters and excludes whitespace, so
# the committed file can stay readable. It is worth asserting because the file
# is one statement per service and growing a service is how it gets exceeded —
# at which point the policy has to be split and the instructions change.
python3 - "$POLICY" <<'PY' >"${WORK}/policy.txt" 2>&1
import json, sys
doc = json.load(open(sys.argv[1], encoding="utf-8"))
minified = len(json.dumps(doc, separators=(",", ":")))
actions = [a for s in doc["Statement"] for a in s["Action"]]
print(f"minified={minified}")
print(f"actions={len(actions)}")
print(f"unique={len(set(actions))}")
print(f"wildcards={sum(1 for a in actions if '*' in a)}")
print(f"services={len({a.split(':')[0] for a in actions})}")
PY
eval "$(sed 's/^/P_/' "${WORK}/policy.txt")" 2>/dev/null || true

if [[ "${P_minified:-99999}" -le 6144 ]]; then
    ok "it fits IAM's 6144-character managed-policy limit (${P_minified})"
else
    bad "it fits IAM's 6144-character managed-policy limit" \
        "${P_minified} characters — split it, and update docs/least-privilege.md"
fi

# A wildcard would make the suite above pass while proving much less, and is
# the easiest way for this file to quietly stop being a least-privilege one.
if [[ "${P_wildcards:-1}" == "0" ]]; then
    ok "and names every action, with no wildcard standing in for a list"
else
    bad "and names every action, with no wildcard standing in for a list" \
        "${P_wildcards} action(s) contain a *"
fi

if [[ "${P_actions:-0}" == "${P_unique:-1}" ]]; then
    ok "and lists each action once"
else
    bad "and lists each action once" \
        "${P_actions} entries, ${P_unique} distinct"
fi

# ---------------------------------------------------------------------------
printf '\n=== Results ===\n'
# ---------------------------------------------------------------------------
printf 'passed: %d\nfailed: %d\n' "$PASS" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
    red "FAILED"
    exit 1
fi
green "All ${PASS} assertions passed."

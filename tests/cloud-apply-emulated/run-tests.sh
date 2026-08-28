#!/usr/bin/env bash
#
# run-tests.sh — Apply the AWS profile for real, against an emulated API
#
# Usage:
#   ./tests/cloud-apply-emulated/run-tests.sh
#
# Takes a couple of minutes. Costs nothing and creates nothing outside a
# local process.
#
# WHY THIS EXISTS
#
# Between "terraform validate" and "a real apply" there is a gap nothing
# here was filling.
#
# `terraform test` runs against mocked providers. A mock answers from a
# fixture: it never exercises the provider's request building, never
# rejects a value the API would reject, and never has an opinion about the
# order things are created in. It is the same shape of tool as the shims
# elsewhere in this repository, with the same blind spot -- it agrees with
# whatever the configuration says.
#
# This runs a real `terraform apply`, through the real AWS provider,
# against an implementation of the AWS API (moto). Every request is
# actually built, sent, and answered. That settles a set of questions the
# mocked tests structurally cannot:
#
#   - does the configuration apply at all, end to end, in one pass
#   - does every reference resolve, in an order Terraform can satisfy
#   - does the AMI data source match anything
#   - does any resource carry a value the API refuses
#   - does `terraform destroy` actually remove what was made
#
# WHAT A GREEN RUN DOES NOT MEAN
#
# An emulator implements the API, not the service. Nothing boots. No
# health check runs. No autoscaling group replaces anything. KMS returns
# plausible responses without performing cryptography.
#
# So this is evidence the configuration is applyable, and it is NOT
# evidence the cluster works. It does not shorten the list in
# docs/cloud-apply.md; it removes from that list the questions that never
# needed a credit card in the first place.
#
# Requirements: terraform, python3 with moto[server], curl

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TF_DIR="${REPO_ROOT}/terraform/aws"
OVERRIDE_SRC="${SCRIPT_DIR}/provider_override.tf"
OVERRIDE_DST="${TF_DIR}/zz_emulated_override.tf"
ENDPOINT="http://localhost:5000"

WORK="$(mktemp -d)"
MOTO_PID=""

PASS=0
FAIL=0

green() { printf '\033[32m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*"; }
info()  { printf '\033[36m%s\033[0m\n' "$*"; }

ok()  { PASS=$((PASS + 1)); green "  PASS  $1"; }
bad() { FAIL=$((FAIL + 1)); red   "  FAIL  $1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; return 0; }

cleanup() {
    local rc=$?
    # Destroy before stopping the emulator, or the provider has nothing to
    # talk to and the run leaves state behind for the next one.
    if [[ -f "${TF_DIR}/terraform.tfstate" ]]; then
        info "Destroying the emulated stack..."
        terraform -chdir="$TF_DIR" destroy -auto-approve -input=false \
            >"${WORK}/destroy.log" 2>&1 || red "  (destroy failed; see ${WORK}/destroy.log)"
    fi
    [[ -n "$MOTO_PID" ]] && kill "$MOTO_PID" 2>/dev/null
    rm -f "$OVERRIDE_DST"
    rm -rf "${TF_DIR}/.terraform" "${TF_DIR}/terraform.tfstate" \
           "${TF_DIR}/terraform.tfstate.backup" "${TF_DIR}/.terraform.lock.hcl.bak"
    rm -rf "$WORK"
    exit "$rc"
}
trap cleanup EXIT INT TERM

for dep in terraform python3 curl; do
    command -v "$dep" >/dev/null 2>&1 || { red "ERROR: ${dep} not found on PATH"; exit 1; }
done
python3 -c "import moto" 2>/dev/null || { red "ERROR: moto is not installed (pip install 'moto[server]')"; exit 1; }
[[ -f "$OVERRIDE_SRC" ]] || { red "ERROR: missing ${OVERRIDE_SRC}"; exit 1; }

# ---------------------------------------------------------------------------
info ""
info "=== Starting the emulated AWS API ==="
# ---------------------------------------------------------------------------
# moto stopped pre-seeding AWS managed policies in v5, so attaching
# AmazonSSMManagedInstanceCore -- which iam.tf does, correctly, to give
# operators SSM Session Manager instead of an open port 22 -- fails with
# NoSuchEntity unless they are loaded. That is an emulator gap rather
# than anything wrong with the profile, and this is the switch for it.
export MOTO_IAM_LOAD_MANAGED_POLICIES=true

python3 -m moto.server -p 5000 >"${WORK}/moto.log" 2>&1 &
MOTO_PID=$!

for _ in $(seq 1 30); do
    curl -fsS -o /dev/null "${ENDPOINT}/" 2>/dev/null && break
    sleep 1
done

if curl -fsS -o /dev/null "${ENDPOINT}/" 2>/dev/null; then
    ok "the emulator is answering on ${ENDPOINT}"
else
    bad "the emulator is answering on ${ENDPOINT}" "$(tail -5 "${WORK}/moto.log")"
    exit 1
fi

cp "$OVERRIDE_SRC" "$OVERRIDE_DST"

# ---------------------------------------------------------------------------
info ""
info "=== terraform apply, for real, against the emulator ==="
# ---------------------------------------------------------------------------
if terraform -chdir="$TF_DIR" init -backend=false -input=false >"${WORK}/init.log" 2>&1; then
    ok "terraform init"
else
    bad "terraform init" "$(tail -15 "${WORK}/init.log")"
    exit 1
fi

# The apply is the assertion. Everything below reads what it produced.
if terraform -chdir="$TF_DIR" apply -auto-approve -input=false >"${WORK}/apply.log" 2>&1; then
    ok "the AWS profile applies end to end"
else
    bad "the AWS profile applies end to end" "$(grep -iE 'error|Error:' "${WORK}/apply.log" | head -12)"
    # Everything after this reads state that does not exist.
    printf '\n=== Results ===\n'
    printf 'passed: %d\nfailed: %d\n' "$PASS" "$FAIL"
    red "FAILED"
    exit 1
fi

STATE="${WORK}/state.json"
terraform -chdir="$TF_DIR" show -json > "$STATE" 2>/dev/null

count_type() {
    python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
res=d.get('values',{}).get('root_module',{}).get('resources',[])
print(sum(1 for r in res if r.get('type')==sys.argv[2]))
" "$STATE" "$1" 2>/dev/null || echo 0
}

attr_of() {
    python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
res=d.get('values',{}).get('root_module',{}).get('resources',[])
for r in res:
    if r.get('type')==sys.argv[2] and r.get('name')==sys.argv[3]:
        v=r.get('values',{})
        for part in sys.argv[4].split('.'):
            if isinstance(v,list):
                v=v[int(part)] if v else None
            else:
                v=(v or {}).get(part)
        print(v if v is not None else '')
        break
" "$STATE" "$1" "$2" "$3" 2>/dev/null || echo ""
}

# ---------------------------------------------------------------------------
info ""
info "=== What the apply actually produced ==="
# ---------------------------------------------------------------------------
# The data source is the first thing a real API can refute: a filter that
# matches nothing fails the plan, and no mocked provider would notice.
AMI="$(attr_of aws_launch_template vault image_id)"
if [[ "$AMI" == ami-* ]]; then
    ok "the AMI filter resolved against the API (${AMI})"
else
    bad "the AMI filter resolved against the API" "launch template image_id is '${AMI}'"
fi

# Two roles, not one: the node role in iam.tf, and the role network.tf
# creates so VPC flow logs can publish to CloudWatch. Expecting 1 was
# wrong about the profile rather than a finding about it.
for pair in "aws_subnet:6" "aws_nat_gateway:3" "aws_kms_key:1" "aws_s3_bucket:1" "aws_autoscaling_group:1" "aws_lb_target_group:1" "aws_iam_role:2" "aws_iam_instance_profile:1" "aws_launch_template:1"; do
    t="${pair%%:*}"; want="${pair##*:}"
    got="$(count_type "$t")"
    if [[ "$got" == "$want" ]]; then
        ok "${t}: ${got}"
    else
        bad "${t}: expected ${want}" "got ${got}"
    fi
done

# Quorum arithmetic, asserted against what was actually created rather
# than against the plan.
MIN="$(attr_of aws_autoscaling_group vault min_size)"
MAX="$(attr_of aws_autoscaling_group vault max_size)"
DES="$(attr_of aws_autoscaling_group vault desired_capacity)"
if [[ "$MIN" == "$MAX" && "$MAX" == "$DES" && -n "$DES" ]]; then
    ok "the autoscaling group is pinned at ${DES} (min = max = desired)"
else
    bad "the autoscaling group is pinned" "min=${MIN} max=${MAX} desired=${DES}"
fi

# The health check that keeps standbys in the pool. A 429 is a healthy
# standby; accepting only 200 would route everything at the leader.
MATCHER="$(attr_of aws_lb_target_group vault health_check.0.matcher)"
if [[ "$MATCHER" == "200,429" ]]; then
    ok "the target group accepts 200 and 429 from standbys"
else
    bad "the target group accepts 200 and 429 from standbys" "matcher is '${MATCHER}'"
fi

# The bucket the snapshots go to has to be encrypted with the cluster's own
# key, not the account default.
if grep -q "aws_s3_bucket_server_side_encryption_configuration" "$STATE"; then
    ok "the snapshot bucket carries a server-side encryption configuration"
else
    bad "the snapshot bucket carries a server-side encryption configuration"
fi

# ---------------------------------------------------------------------------
info ""
info "=== And it can be taken back down ==="
# ---------------------------------------------------------------------------
# A profile that applies but cannot be destroyed is a profile that bills
# forever on a real account. Worth knowing here rather than there.
if terraform -chdir="$TF_DIR" destroy -auto-approve -input=false >"${WORK}/destroy1.log" 2>&1; then
    ok "terraform destroy removes everything it made"
    rm -f "${TF_DIR}/terraform.tfstate"
else
    bad "terraform destroy removes everything it made" \
        "$(grep -iE 'error|Error:' "${WORK}/destroy1.log" | head -8)"
fi

# ---------------------------------------------------------------------------
printf '\n=== Results ===\n'
# ---------------------------------------------------------------------------
printf 'passed: %d\nfailed: %d\n' "$PASS" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then red "FAILED"; exit 1; fi
green "All ${PASS} assertions passed."

#!/usr/bin/env bash
#
# run-tests.sh — The state backend, and the ordering it depends on
#
# Usage:
#   ./tests/state-backend/run-tests.sh
#
# Takes about a minute. Costs nothing and creates nothing outside a local
# process.
#
# WHY THIS EXISTS
#
# Until v0.15 neither cloud profile declared a `backend`, so state was a
# file on whoever ran `apply` last: no lock to stop two concurrent applies
# corrupting it, and losing the file meant losing the ability to change a
# running Vault cluster while Vault itself stayed up holding production
# secrets.
#
# The fix is not the backend block. It is the ordering — the bucket has to
# exist before the configuration that stores state in it, and it must not
# live in that configuration's own state — and ordering is exactly what a
# configuration file cannot assert about itself. So this applies
# terraform/aws/bootstrap against an implementation of the AWS API (moto),
# points the real profile's backend at what it created, and checks the
# properties that make the arrangement worth having:
#
#   - initialising before the bucket exists fails, and says why
#   - the bucket versions, encrypts, blocks public access, and refuses to
#     be destroyed
#   - state written by the profile lands in the bucket, not on disk
#   - a second apply is refused while the lock is held, and succeeds once
#     it is not
#   - the same round trip works as an IAM user holding only the
#     `state_policy` the bootstrap module emits, with the emulator
#     evaluating every request against it; stops working when one action
#     is removed or the object prefix is another cluster's; and needed
#     exactly the S3 actions the policy grants, re-derived from a recording
#     of the requests on every run
#
# WHAT A GREEN RUN DOES NOT MEAN
#
# An emulator implements the API, not the service. Nothing here proves S3
# behaves this way in an account; that AWS's IAM evaluates the state policy
# the way moto's does (no SCPs, no permission boundaries, no resource
# policies, and no signature check -- moto_server.py says why that one is
# off); that the KMS statement is right, since the
# emulator's S3 never calls KMS and no recording can see what it needs; or
# that a real concurrent apply from two machines races the way one process
# planting a lock file does.
#
# And Azure gets no emulator at all: moto is an AWS API, and the Azure
# emulator that does exist needs a licence (docs/cloud-apply.md, "Why
# Azure has no emulated apply"). The Azure
# assertions below are static reads of the configuration, and they are
# labelled as such. terraform/azure/bootstrap has never been applied to
# anything. See docs/terraform-state.md and docs/roadmap.md.
#
# Requirements: terraform, python3 with moto[server], curl

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

AWS_DIR="${REPO_ROOT}/terraform/aws"
AWS_BOOTSTRAP="${AWS_DIR}/bootstrap"
AZURE_DIR="${REPO_ROOT}/terraform/azure"

# Reused rather than copied. The same file configures the provider for
# tests/cloud-apply-emulated, and two copies of an endpoint list is two
# places to update when the emulator moves.
OVERRIDE_SRC="${REPO_ROOT}/tests/cloud-apply-emulated/provider_override.tf"
ENDPOINT="http://localhost:5000"

WORK="$(mktemp -d)"
MOTO_PID=""

# Set once this run has started writing into the repository. Until then
# the cleanup below must not touch those paths.
#
# The reason is the guard added above. The likeliest cause of an early
# exit is now "another run already owns this workspace" -- and a cleanup
# that removed its override files, or destroyed the stack its state file
# describes, would answer one corruption with a worse one. A run cleans
# up what it created, and an early exit created nothing.
CLAIMED=false

PASS=0
FAIL=0

green() { printf '\033[32m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*"; }
info()  { printf '\033[36m%s\033[0m\n' "$*"; }

ok()  { PASS=$((PASS + 1)); green "  PASS  $1"; }
bad() { FAIL=$((FAIL + 1)); red   "  FAIL  $1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; return 0; }

cleanup() {
    local rc=$?
    if [[ -n "$MOTO_PID" ]]; then
        kill "$MOTO_PID" 2>/dev/null
    fi
    # Nothing to destroy: the emulator holds every resource in memory and
    # dies with the process. What has to go is what was written into the
    # repository — an override file, a generated backend.hcl, and the
    # bootstrap module's own local state.
    if [[ "$CLAIMED" == true ]]; then
        rm -f "${AWS_DIR}/zz_emulated_override.tf" \
              "${AWS_BOOTSTRAP}/zz_emulated_override.tf" \
              "${AWS_DIR}/backend.hcl"
        rm -rf "${AWS_DIR}/.terraform" "${AWS_DIR}/terraform.tfstate" \
               "${AWS_DIR}/terraform.tfstate.backup" \
               "${AWS_BOOTSTRAP}/.terraform" "${AWS_BOOTSTRAP}/terraform.tfstate" \
               "${AWS_BOOTSTRAP}/terraform.tfstate.backup"
    fi
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
info "=== Static: what the profiles declare ==="
# ---------------------------------------------------------------------------
# Cheap, and they cover the half of this that no apply reaches — including
# the whole Azure profile.

# An empty block, deliberately. A committed bucket name is a bucket
# somebody else's fork writes to, and it is also what makes CI's
# `init -backend=false` a half-configured backend rather than no backend.
if grep -qE '^\s*backend "s3" \{\}\s*$' "${AWS_DIR}/main.tf"; then
    ok "terraform/aws declares an S3 backend with nothing filled in"
else
    bad "terraform/aws declares an S3 backend with nothing filled in" \
        "expected a literal 'backend \"s3\" {}' in terraform/aws/main.tf"
fi

if grep -qE '^\s*backend "azurerm" \{\}\s*$' "${AZURE_DIR}/main.tf"; then
    ok "terraform/azure declares an azurerm backend with nothing filled in"
else
    bad "terraform/azure declares an azurerm backend with nothing filled in" \
        "expected a literal 'backend \"azurerm\" {}' in terraform/azure/main.tf"
fi

# The generated file names a real account's bucket. Committing one is how
# a fork ends up planning against somebody else's state.
if git -C "$REPO_ROOT" check-ignore -q terraform/aws/backend.hcl &&
   git -C "$REPO_ROOT" check-ignore -q terraform/azure/backend.hcl; then
    ok "a generated backend.hcl is ignored by git in both profiles"
else
    bad "a generated backend.hcl is ignored by git in both profiles"
fi

# Locking is the whole point of the backend, and on S3 it is opt-in.
# Pinned to the value rather than checked for the word, because
# `use_lockfile = false` contains the word.
if grep -qE '^\s*use_lockfile\s*=\s*true\s*$' "${AWS_DIR}/backend.hcl.example"; then
    ok "the AWS backend example turns S3 native locking on"
else
    bad "the AWS backend example turns S3 native locking on" \
        "without use_lockfile = true, two applies race and the second wins"
fi

# Azure, statically: the state account refuses shared keys, so the backend
# has to authenticate as a principal. Either half without the other is an
# init that cannot authenticate — and since nothing applies this profile,
# this pairing is the only thing that catches it.
azure_keys_off=false
azure_aad_on=false
grep -qE '^\s*shared_access_key_enabled\s*=\s*false\s*$' "${AZURE_DIR}/bootstrap/main.tf" && azure_keys_off=true
grep -qE '^\s*use_azuread_auth\s*=\s*true\s*$' "${AZURE_DIR}/backend.hcl.example" && azure_aad_on=true
if [[ "$azure_keys_off" == true && "$azure_aad_on" == true ]]; then
    ok "the Azure state account refuses account keys, and the backend asks for Entra auth"
else
    bad "the Azure state account refuses account keys, and the backend asks for Entra auth" \
        "keys_off=${azure_keys_off} azuread_auth=${azure_aad_on}"
fi

# ---------------------------------------------------------------------------
info ""
info "=== Static: CI's no-credentials path still works ==="
# ---------------------------------------------------------------------------
# `terraform init -backend=false` is what lets validate run with no cloud
# account at all. Adding a backend is the change most likely to break it,
# and the breakage would look like a credentials problem rather than a
# configuration one.
for d in "$AWS_DIR" "$AZURE_DIR"; do
    name="terraform/$(basename "$d")"
    rm -rf "${d}/.terraform"
    if terraform -chdir="$d" init -backend=false -input=false >"${WORK}/init-nobackend.log" 2>&1 &&
       terraform -chdir="$d" validate >>"${WORK}/init-nobackend.log" 2>&1; then
        ok "${name}: init -backend=false, then validate"
    else
        bad "${name}: init -backend=false, then validate" \
            "$(tail -8 "${WORK}/init-nobackend.log")"
    fi
    rm -rf "${d}/.terraform"
done

# ---------------------------------------------------------------------------
info ""
info "=== Starting the emulated AWS API ==="
# ---------------------------------------------------------------------------
# Nothing may already be listening here. The readiness check below asks
# whether the endpoint answers, and a moto left behind by an earlier run
# answers exactly like one this run started -- while still holding the
# buckets from that run. A suite that proceeds there measures state it
# never created: objects it never shipped, versions it never wrote. The
# cleanup trap then kills the PID of the server that failed to bind and
# leaves the real one running, so the next run inherits the same state
# and the fault outlives the run that caused it.
if curl -s -o /dev/null "$ENDPOINT" 2>/dev/null; then
    red "ERROR: something is already listening on ${ENDPOINT}."
    red "       It holds state this suite did not create. Stop it first:"
    red "         pkill -f 'moto[.]server'"
    exit 1
fi

# The recorder is armed here and switched on only for the last section,
# which compares what the backend asked the bucket with what the state
# policy grants.
RECORDING="${WORK}/recording.jsonl"
# Not `python3 -m moto.server`: the launcher beside this file turns moto's
# signature comparison off and leaves authorization on, because the
# comparison cannot pass for Terraform's workspace listing. The header of
# moto_server.py has the whole story.
MOTO_RECORDER_FILEPATH="$RECORDING" python3 "${SCRIPT_DIR}/moto_server.py" -p 5000 >"${WORK}/moto.log" 2>&1 &
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

# An answer on the port is not proof the answer is ours: the server this
# run started can have exited on a bind error while something else keeps
# replying. Check the process, not the port.
if ! kill -0 "$MOTO_PID" 2>/dev/null; then
    red "ERROR: the emulator exited during startup"
    tail -3 "${WORK}/moto.log" >&2
    exit 1
fi

# From here on this run owns the workspace, so cleanup may remove it.
CLAIMED=true

cp "$OVERRIDE_SRC" "${AWS_DIR}/zz_emulated_override.tf"
cp "$OVERRIDE_SRC" "${AWS_BOOTSTRAP}/zz_emulated_override.tf"

# Emulator plumbing, appended to whatever the module generates. These
# lines say where the API is and that there are no credentials to
# validate; nothing about them belongs in a real backend.hcl.
EMULATOR_BACKEND_LINES=$(cat <<'EOF'

skip_credentials_validation = true
skip_metadata_api_check     = true
skip_requesting_account_id  = true
skip_region_validation      = true
use_path_style              = true
access_key                  = "emulated"
secret_key                  = "emulated"
endpoints = { s3 = "http://localhost:5000" }
EOF
)

# ---------------------------------------------------------------------------
info ""
info "=== The ordering: the bucket has to exist first ==="
# ---------------------------------------------------------------------------
# The failure this is about is not subtle when it happens; it is subtle
# when it doesn't. Terraform will happily initialise a backend pointing at
# a bucket that does not exist yet and create an empty state, and the
# first symptom is a plan offering to build a cluster that is already
# running. It should refuse, and this is the check that it does.
{
    printf 'bucket = "vault-reference-tfstate-does-not-exist"\n'
    printf 'key    = "vault-reference/terraform.tfstate"\n'
    printf 'region = "us-east-1"\n'
    printf 'use_lockfile = true\n'
    printf '%s\n' "$EMULATOR_BACKEND_LINES"
} > "${WORK}/backend-missing.hcl"

rm -rf "${AWS_DIR}/.terraform"
if terraform -chdir="$AWS_DIR" init -input=false \
        -backend-config="${WORK}/backend-missing.hcl" >"${WORK}/init-missing.log" 2>&1; then
    bad "initialising against a bucket that does not exist is refused" \
        "init succeeded; a plan would now offer to build the cluster again"
else
    if grep -qi "vault-reference-tfstate-does-not-exist" "${WORK}/init-missing.log"; then
        ok "initialising against a bucket that does not exist is refused, by name"
    else
        bad "initialising against a bucket that does not exist is refused, by name" \
            "init failed, but the error does not name the bucket: $(tail -3 "${WORK}/init-missing.log")"
    fi
fi
rm -rf "${AWS_DIR}/.terraform"

# ---------------------------------------------------------------------------
info ""
info "=== terraform/aws/bootstrap, applied for real against the emulator ==="
# ---------------------------------------------------------------------------
if terraform -chdir="$AWS_BOOTSTRAP" init -backend=false -input=false >"${WORK}/bs-init.log" 2>&1; then
    ok "the bootstrap module initialises"
else
    bad "the bootstrap module initialises" "$(tail -12 "${WORK}/bs-init.log")"
    exit 1
fi

if terraform -chdir="$AWS_BOOTSTRAP" apply -auto-approve -input=false >"${WORK}/bs-apply.log" 2>&1; then
    ok "the bootstrap module applies end to end"
else
    bad "the bootstrap module applies end to end" \
        "$(grep -iE 'error' "${WORK}/bs-apply.log" | head -10)"
    printf '\n=== Results ===\n'
    printf 'passed: %d\nfailed: %d\n' "$PASS" "$FAIL"
    red "FAILED"
    exit 1
fi

BS_STATE="${WORK}/bootstrap-state.json"
terraform -chdir="$AWS_BOOTSTRAP" show -json > "$BS_STATE" 2>/dev/null

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
" "$BS_STATE" "$1" "$2" "$3" 2>/dev/null || echo ""
}

BUCKET="$(attr_of aws_s3_bucket tfstate bucket)"
KMS_ARN="$(attr_of aws_kms_key tfstate arn)"

# Versioning is what makes a state file overwritten by a bad apply
# recoverable. Asserted on the created resource rather than on the
# configuration, so a value the API silently ignored would show up here.
VERSIONING="$(attr_of aws_s3_bucket_versioning tfstate versioning_configuration.0.status)"
if [[ "$VERSIONING" == "Enabled" ]]; then
    ok "the state bucket has versioning enabled"
else
    bad "the state bucket has versioning enabled" "status is '${VERSIONING}'"
fi

SSE_ALGO="$(attr_of aws_s3_bucket_server_side_encryption_configuration tfstate rule.0.apply_server_side_encryption_by_default.0.sse_algorithm)"
SSE_KEY="$(attr_of aws_s3_bucket_server_side_encryption_configuration tfstate rule.0.apply_server_side_encryption_by_default.0.kms_master_key_id)"
if [[ "$SSE_ALGO" == "aws:kms" && -n "$KMS_ARN" && "$SSE_KEY" == "$KMS_ARN" ]]; then
    ok "the state bucket encrypts under the key the module created"
else
    bad "the state bucket encrypts under the key the module created" \
        "algorithm='${SSE_ALGO}' key='${SSE_KEY}' expected='${KMS_ARN}'"
fi

PAB_OK=true
for f in block_public_acls block_public_policy ignore_public_acls restrict_public_buckets; do
    v="$(attr_of aws_s3_bucket_public_access_block tfstate "$f")"
    [[ "$v" == "True" || "$v" == "true" ]] || PAB_OK=false
done
if [[ "$PAB_OK" == true ]]; then
    ok "all four public access block settings are on"
else
    bad "all four public access block settings are on" \
        "one of block_public_acls, block_public_policy, ignore_public_acls, restrict_public_buckets is not"
fi

FORCE_DESTROY="$(attr_of aws_s3_bucket tfstate force_destroy)"
if [[ "$FORCE_DESTROY" == "False" || "$FORCE_DESTROY" == "false" ]]; then
    ok "force_destroy is off, so a destroy cannot empty the bucket first"
else
    bad "force_destroy is off, so a destroy cannot empty the bucket first" \
        "force_destroy is '${FORCE_DESTROY}'"
fi

# ---------------------------------------------------------------------------
info ""
info "=== The handoff: generated config, not a copied bucket name ==="
# ---------------------------------------------------------------------------
terraform -chdir="$AWS_BOOTSTRAP" output -raw backend_config > "${WORK}/backend-generated.hcl" 2>/dev/null

if grep -q "bucket = \"${BUCKET}\"" "${WORK}/backend-generated.hcl"; then
    ok "the generated backend config names the bucket that was created (${BUCKET})"
else
    bad "the generated backend config names the bucket that was created" \
        "expected bucket ${BUCKET}, got: $(grep bucket "${WORK}/backend-generated.hcl" || echo '<no bucket line>')"
fi

STATE_KEY="$(grep -E '^key' "${WORK}/backend-generated.hcl" | head -1 | sed -e 's/.*= *"//' -e 's/"//')"

# Pinned to the literal, not rebuilt from var.cluster_name.
#
# Everything else in this section reads the key out of the generated
# config and then checks the state arrived at that key -- which follows
# the module wherever it goes, so a key template of plain
# "terraform.tfstate" would pass every one of those assertions. One bucket
# is meant to hold many clusters, one key each; a shared key is two
# clusters overwriting each other's state, and the first symptom is a plan
# offering to destroy a cluster that is running.
#
# Deriving the expected value from the module's own variable would restate
# the module's arithmetic in the test, which is how the Azure suite ended
# up with assertions that could not fail (see terraform/azure/tests/README.md).
if [[ "$STATE_KEY" == "vault-reference/terraform.tfstate" ]]; then
    ok "the state key is namespaced by cluster, so one bucket holds many"
else
    bad "the state key is namespaced by cluster, so one bucket holds many" \
        "key is '${STATE_KEY}', expected the cluster name and then terraform.tfstate"
fi

{
    cat "${WORK}/backend-generated.hcl"
    printf '%s\n' "$EMULATOR_BACKEND_LINES"
} > "${AWS_DIR}/backend.hcl"

rm -rf "${AWS_DIR}/.terraform"
if terraform -chdir="$AWS_DIR" init -input=false \
        -backend-config=backend.hcl >"${WORK}/init-backend.log" 2>&1; then
    ok "the profile initialises against the generated config"
else
    bad "the profile initialises against the generated config" \
        "$(tail -12 "${WORK}/init-backend.log")"
    printf '\n=== Results ===\n'
    printf 'passed: %d\nfailed: %d\n' "$PASS" "$FAIL"
    red "FAILED"
    exit 1
fi

# ---------------------------------------------------------------------------
info ""
info "=== State goes to the bucket, not to a file on this machine ==="
# ---------------------------------------------------------------------------
# One resource, not the whole profile. Whether terraform/aws applies is
# tests/cloud-apply-emulated's question and it answers it thoroughly;
# the question here is only where the state of an apply ends up, and
# targeting one resource answers it in seconds rather than minutes.
if terraform -chdir="$AWS_DIR" apply -auto-approve -input=false \
        -target=random_id.bucket_suffix >"${WORK}/apply1.log" 2>&1; then
    ok "an apply against the remote backend succeeds"
else
    bad "an apply against the remote backend succeeds" \
        "$(grep -iE 'error' "${WORK}/apply1.log" | head -8)"
fi

if [[ ! -f "${AWS_DIR}/terraform.tfstate" ]]; then
    ok "no local terraform.tfstate was written"
else
    bad "no local terraform.tfstate was written" \
        "state is still a file on this machine, which is the thing the backend removes"
fi

# boto3 rather than curl: the emulator rejects unsigned mutating
# requests, and boto3 arrives with moto[server] anyway.
s3_client_py() {
    cat <<'PY'
import boto3
s3 = boto3.client(
    "s3",
    endpoint_url="http://localhost:5000",
    aws_access_key_id="emulated",
    aws_secret_access_key="emulated",
    region_name="us-east-1",
)
PY
}

list_keys() {
    { s3_client_py; cat <<'PY'
import sys
for o in s3.list_objects_v2(Bucket=sys.argv[1]).get("Contents", []):
    print(o["Key"])
PY
    } | python3 - "$1"
}

if list_keys "$BUCKET" | grep -qx "$STATE_KEY"; then
    ok "the state object is in the bucket at ${STATE_KEY}"
else
    bad "the state object is in the bucket at ${STATE_KEY}" \
        "bucket holds: $(list_keys "$BUCKET" | tr '\n' ' ')"
fi

# ---------------------------------------------------------------------------
info ""
info "=== The lock: two applies at once ==="
# ---------------------------------------------------------------------------
# The corruption this backend exists to prevent. Without a lock, two
# applies both read the state, both write it, and the second silently
# discards everything the first did.
#
# One process planting the lock object rather than two racing applies:
# the race is not reproducible on demand, and what is being checked is
# that the second apply asks and is refused.
{ s3_client_py; cat <<'PY'
import json, sys
s3.put_object(
    Bucket=sys.argv[1],
    Key=sys.argv[2] + ".tflock",
    Body=json.dumps({
        "ID": "00000000-0000-0000-0000-000000000000",
        "Operation": "OperationTypeApply",
        "Who": "someone-else@another-laptop",
    }).encode(),
)
PY
} | python3 - "$BUCKET" "$STATE_KEY"

if terraform -chdir="$AWS_DIR" apply -auto-approve -input=false -lock-timeout=5s \
        -target=random_id.bucket_suffix >"${WORK}/apply-locked.log" 2>&1; then
    bad "an apply is refused while another holds the lock" \
        "the apply went ahead; concurrent applies would overwrite each other"
else
    if grep -qi "Error acquiring the state lock" "${WORK}/apply-locked.log"; then
        ok "an apply is refused while another holds the lock"
    else
        bad "an apply is refused while another holds the lock" \
            "it failed for some other reason: $(grep -iE 'error' "${WORK}/apply-locked.log" | head -4)"
    fi
fi

# The positive half. Without it, the assertion above passes just as well
# when the apply is broken for an unrelated reason.
{ s3_client_py; cat <<'PY'
import sys
s3.delete_object(Bucket=sys.argv[1], Key=sys.argv[2] + ".tflock")
PY
} | python3 - "$BUCKET" "$STATE_KEY"

if terraform -chdir="$AWS_DIR" apply -auto-approve -input=false -lock-timeout=5s \
        -target=random_id.bucket_suffix >"${WORK}/apply-unlocked.log" 2>&1; then
    ok "and the same apply succeeds once the lock is released"
else
    bad "and the same apply succeeds once the lock is released" \
        "$(grep -iE 'error' "${WORK}/apply-unlocked.log" | head -6)"
fi

# ---------------------------------------------------------------------------
info ""
info "=== The bucket refuses to be destroyed ==="
# ---------------------------------------------------------------------------
# `terraform destroy` in the bootstrap directory is a plausible thing to
# run while cleaning up a test account, and it would take the state of
# every running cluster in the bucket with it. prevent_destroy makes it a
# deliberate act — an edit — rather than a command.
if terraform -chdir="$AWS_BOOTSTRAP" destroy -auto-approve -input=false \
        >"${WORK}/bs-destroy.log" 2>&1; then
    bad "destroying the bootstrap module is refused" \
        "destroy succeeded; the state bucket is one wrong directory away from gone"
else
    if grep -qi "prevent_destroy" "${WORK}/bs-destroy.log"; then
        ok "destroying the bootstrap module is refused by prevent_destroy"
    else
        bad "destroying the bootstrap module is refused by prevent_destroy" \
            "it failed for some other reason: $(grep -iE 'error' "${WORK}/bs-destroy.log" | head -4)"
    fi
fi

# ---------------------------------------------------------------------------
info ""
info "=== The state, as an identity holding only the state policy ==="
# ---------------------------------------------------------------------------
# Everything above ran with a made-up access key the emulator does not
# check. This runs the operator's everyday round trip -- list, lock, read,
# write, unlock -- as an IAM user whose only permission is the
# `state_policy` output of the bootstrap module, with the emulator
# evaluating every request against it, resource ARN included. Who may read
# and write the state is a different question from who may build the
# cluster (tests/least-privilege-apply answers that one with a local
# backend, so that a failure stays unambiguous), and until this section
# nothing answered it at all.
#
# Last, deliberately: once authorization is switched on, the "emulated" key
# every earlier section used stops working, and there is no switching it
# back off.
terraform -chdir="$AWS_BOOTSTRAP" output -raw state_policy >"${WORK}/state-policy.json" 2>/dev/null

# The document itself, before anything is tried with it. A wildcard or a
# `Resource: "*"` would make the round trip below pass while proving much
# less, and the KMS statement is the one part no run here can exercise, so
# the most that can be asked of it is that it names the right key.
if python3 - "${WORK}/state-policy.json" "$BUCKET" "$KMS_ARN" "$STATE_KEY" >"${WORK}/state-policy.txt" 2>&1 <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
bucket_arn = f"arn:aws:s3:::{sys.argv[2]}"
# The prefix of this cluster's state key, pinned rather than rebuilt from
# var.cluster_name: the other-cluster identity below rewrites the prefix
# before testing, so a policy widened to the whole bucket would pass that
# check. This is what catches the widening.
objects_arn = f"{bucket_arn}/{sys.argv[4].rsplit('/', 1)[0]}/*"
actions = [a for s in doc["Statement"] for a in s["Action"]]
resources = [s["Resource"] for s in doc["Statement"]]
problems = []
if any("*" in a for a in actions):
    problems.append("an action contains a *")
if len(actions) != len(set(actions)):
    problems.append("an action is listed twice")
if "*" in resources:
    problems.append("a statement is on Resource *")
if bucket_arn not in resources:
    problems.append(f"nothing is granted on the bucket itself ({bucket_arn})")
if sys.argv[3] not in resources:
    problems.append("the KMS statement does not name the key this module created")
if objects_arn not in resources:
    problems.append(f"the object statement is not scoped to this cluster's prefix ({objects_arn})")
if objects_arn not in resources:
    problems.append(f"the object statement is not scoped to this cluster's prefix ({objects_arn})")
print("\n".join(problems) if problems else "ok")
sys.exit(1 if problems else 0)
PY
then
    ok "the state policy names every action, this cluster's prefix, and the module's own key"
else
    bad "the state policy names every action, this cluster's prefix, and the module's own key" \
        "$(cat "${WORK}/state-policy.txt")"
fi

# Every identity first, then enforcement, because the setup calls stop
# working the moment it is on. Four of them: the policy as emitted, the
# policy minus one action twice over, and the policy written for a
# different cluster in the same bucket.
IDENTITY="${SCRIPT_DIR}/state_identity.py"
make_identity() {
    python3 "$IDENTITY" create "$ENDPOINT" "${WORK}/state-policy.json" "$@" 2>>"${WORK}/identity.log"
}
CREDS_FULL="$(make_identity state-full)"
CREDS_NO_PUT="$(make_identity state-without-put --without s3:PutObject)"
CREDS_NO_DELETE="$(make_identity state-without-delete --without s3:DeleteObject)"
CREDS_OTHER="$(make_identity state-for-another-cluster --object-prefix some-other-cluster)"

IDENTITIES_OK=false
if [[ -n "$CREDS_FULL" && -n "$CREDS_NO_PUT" && -n "$CREDS_NO_DELETE" && -n "$CREDS_OTHER" ]] &&
   python3 "$IDENTITY" enforce "$ENDPOINT" 2>>"${WORK}/identity.log"; then
    ok "four identities exist, and the emulator now evaluates IAM on every request"
    IDENTITIES_OK=true
else
    bad "four identities exist, and the emulator now evaluates IAM on every request" \
        "$(tail -5 "${WORK}/identity.log")"
fi

# run_as "<key> <secret>" <label> <terraform args...>
run_as() {
    local creds="$1" label="$2" k s
    shift 2
    read -r k s <<<"$creds"
    AWS_ACCESS_KEY_ID="$k" AWS_SECRET_ACCESS_KEY="$s" AWS_DEFAULT_REGION=us-east-1 \
        terraform -chdir="$AWS_DIR" "$@" >"${WORK}/${label}.log" 2>&1
}

denied() { grep -qiE 'AccessDenied|not authorized' "${WORK}/$1.log"; }

if [[ "$IDENTITIES_OK" == true ]]; then
    # The same emulator plumbing as before, minus the key: the backend reads
    # AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY from the environment, which
    # is how the identity changes per case without touching the file.
    {
        cat "${WORK}/backend-generated.hcl"
        printf '%s\n' "$EMULATOR_BACKEND_LINES" | grep -vE '^(access_key|secret_key)'
    } >"${AWS_DIR}/backend.hcl"

    # Recording from here. The state is already in the bucket from the
    # sections above, so what follows is the everyday round trip: list the
    # workspaces, take the lock, read the state, write it back, release.
    curl -s -X POST "${ENDPOINT}/moto-api/recorder/reset-recording" >/dev/null
    curl -s -X POST "${ENDPOINT}/moto-api/recorder/start-recording" >/dev/null

    # The backend config changed (no key in it), so init has to be told to
    # reconfigure rather than offer to migrate.
    if run_as "$CREDS_FULL" narrow-init init -input=false -reconfigure -backend-config=backend.hcl &&
       run_as "$CREDS_FULL" narrow-apply apply -auto-approve -input=false -lock-timeout=5s \
           -target=random_id.bucket_suffix; then
        ok "the profile lists, locks, reads, writes and unlocks its state holding only the state policy"
    else
        bad "the profile lists, locks, reads, writes and unlocks its state holding only the state policy" \
            "$(grep -ihE 'AccessDenied|not authorized|Error' "${WORK}/narrow-init.log" "${WORK}/narrow-apply.log" | head -6)"
    fi
    curl -s -X POST "${ENDPOINT}/moto-api/recorder/stop-recording" >/dev/null

    # The set of S3 actions the round trip needed, read off the recording,
    # has to be exactly the set the policy grants. Both directions matter:
    # a granted action the backend never used is a grant nobody can
    # justify, and a request shape `derive` cannot name is Terraform doing
    # something new.
    GRANTED="$(python3 -c '
import json, sys
doc = json.load(open(sys.argv[1]))
print("\n".join(sorted({a for s in doc["Statement"] for a in s["Action"] if a.startswith("s3:")})))
' "${WORK}/state-policy.json")"
    if python3 "$IDENTITY" derive "$RECORDING" "$BUCKET" >"${WORK}/needed.txt" 2>"${WORK}/derive.err"; then
        if [[ "$(cat "${WORK}/needed.txt")" == "$GRANTED" ]]; then
            ok "the S3 actions the round trip needed are exactly the ones the policy grants ($(tr '\n' ' ' <"${WORK}/needed.txt"| sed 's/ $//'))"
        else
            bad "the S3 actions the round trip needed are exactly the ones the policy grants" \
                "needed: $(tr '\n' ' ' <"${WORK}/needed.txt")/ granted: $(tr '\n' ' ' <<<"$GRANTED")"
        fi
    else
        bad "every request the backend made can be named as an IAM action" \
            "$(cat "${WORK}/derive.err")"
    fi

    # Removing one S3 action, in the two shapes that matter: the one that
    # fails first, and the one that fails last.
    #
    #   s3:PutObject     nothing happens. The lock is a conditional PUT, so
    #                    the apply cannot begin, and the error names the lock.
    #   s3:DeleteObject  everything happens -- the state is read and written
    #                    -- and then the lock cannot be released. Terraform
    #                    exits non-zero and the lock stays behind. An
    #                    identity with this gap looks like it works until the
    #                    next person tries, which is why it runs last here.
    if run_as "$CREDS_NO_PUT" without-put apply -auto-approve -input=false -lock-timeout=5s \
           -target=random_id.bucket_suffix; then
        bad "without s3:PutObject, the apply cannot take the lock" \
            "it applied anyway, so the policy says more than this suite proves"
    elif grep -q "acquiring the state lock" "${WORK}/without-put.log" && denied without-put; then
        ok "without s3:PutObject, the apply cannot take the lock"
    else
        bad "without s3:PutObject, the apply cannot take the lock" \
            "it failed for another reason: $(grep -iE 'error' "${WORK}/without-put.log" | head -4)"
    fi

    # The scoping. An identity written for another cluster in the same
    # bucket -- same actions, prefix some-other-cluster/ -- must not reach
    # this one's state. The emulator evaluates the resource ARN, so this is
    # a check of the policy rather than a reading of it, and it is the one
    # property the apply policy's `Resource: "*"` cannot have.
    if run_as "$CREDS_OTHER" other-cluster apply -auto-approve -input=false -lock-timeout=5s \
           -target=random_id.bucket_suffix; then
        bad "an identity scoped to another cluster's prefix cannot touch this one's state" \
            "it applied anyway; the object ARNs are not doing anything"
    elif denied other-cluster; then
        ok "an identity scoped to another cluster's prefix cannot touch this one's state"
    else
        bad "an identity scoped to another cluster's prefix cannot touch this one's state" \
            "it failed for another reason: $(grep -iE 'error' "${WORK}/other-cluster.log" | head -4)"
    fi

    if run_as "$CREDS_NO_DELETE" without-delete apply -auto-approve -input=false -lock-timeout=5s \
           -target=random_id.bucket_suffix; then
        bad "without s3:DeleteObject, the apply succeeds and then cannot release the lock" \
            "it applied and unlocked, so the policy says more than this suite proves"
    elif grep -q "releasing the state lock" "${WORK}/without-delete.log" && denied without-delete; then
        ok "without s3:DeleteObject, the apply succeeds and then cannot release the lock"
    else
        bad "without s3:DeleteObject, the apply succeeds and then cannot release the lock" \
            "it failed for another reason: $(grep -iE 'error' "${WORK}/without-delete.log" | head -4)"
    fi
fi

# ---------------------------------------------------------------------------
printf '\n=== Results ===\n'
# ---------------------------------------------------------------------------
printf 'passed: %d\nfailed: %d\n' "$PASS" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then red "FAILED"; exit 1; fi
green "All ${PASS} assertions passed."

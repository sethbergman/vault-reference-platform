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
#
# WHAT A GREEN RUN DOES NOT MEAN
#
# An emulator implements the API, not the service. Nothing here proves S3
# behaves this way in an account, that the IAM permissions to reach the
# bucket are the ones granted, or that a real concurrent apply from two
# machines races the way one process planting a lock file does.
#
# And Azure gets no emulator at all: moto is an AWS API. The Azure
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
printf '\n=== Results ===\n'
# ---------------------------------------------------------------------------
printf 'passed: %d\nfailed: %d\n' "$PASS" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then red "FAILED"; exit 1; fi
green "All ${PASS} assertions passed."

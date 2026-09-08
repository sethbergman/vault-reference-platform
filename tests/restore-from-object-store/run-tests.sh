#!/usr/bin/env bash
#
# run-tests.sh — A snapshot in object storage is a restorable snapshot
#
# Usage:
#   ./tests/restore-from-object-store/run-tests.sh [--keep-running]
#
# WHY THIS EXISTS
#
# This repository was built around one failure: the timer was green and
# the backups were not there. `scripts/snapshot.sh` closes most of it —
# it inspects the snapshot before uploading, so a truncated or empty file
# is refused rather than shipped — and `scripts/dr-drill.sh` proves a
# snapshot restores, against a local file.
#
# The half nobody had closed is the join between them. On the cloud
# profiles the snapshot goes to S3 and nothing ever reads one back. A
# successful `aws s3 cp` proves an object exists at a key; it does not
# prove the object is a snapshot, that it survived the round trip, or
# that restoring it produces the cluster you had. Those are different
# claims, and only the last one is a backup.
#
# So this puts a real snapshot of a real cluster through a real S3 API,
# reads it back, and restores it — then checks the cluster contains what
# it contained when the snapshot was taken, and no longer contains what
# was written afterwards.
#
# WHAT A GREEN RUN DOES NOT MEAN
#
# The S3 API here is an emulator (moto). It settles that the object round
# trips byte-for-byte and that what comes back restores; it does not
# settle that the instance role can reach a real bucket, that server-side
# encryption on a real bucket leaves the object restorable, or that a
# multipart upload of a snapshot larger than anything here behaves the
# same. docs/cloud-apply.md lists what a real apply would settle.
#
# Requirements: docker compose, vault CLI, jq, aws, python3 with
# moto[server], curl

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
COMPOSE=(docker compose -f "${REPO_ROOT}/docker/dev/docker-compose.yml")
SNAPSHOT_SH="${REPO_ROOT}/scripts/snapshot.sh"

ENDPOINT="http://localhost:5000"
BUCKET="vault-snapshots-test"
PREFIX="snapshots"

KEEP_RUNNING=false
[[ "${1:-}" == "--keep-running" ]] && KEEP_RUNNING=true

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

cleanup() {
    local rc=$?
    [[ -n "$MOTO_PID" ]] && kill "$MOTO_PID" 2>/dev/null
    if [[ "$CLAIMED" == true && "$KEEP_RUNNING" != true ]]; then
        info "Tearing down..."
        "${COMPOSE[@]}" --profile spare down -v >/dev/null 2>&1
    elif [[ "$KEEP_RUNNING" == true ]]; then
        info "Leaving the cluster up (--keep-running)."
    fi
    rm -rf "$WORK"
    exit "$rc"
}
trap cleanup EXIT INT TERM

for dep in docker vault jq aws python3 curl; do
    command -v "$dep" >/dev/null 2>&1 || { red "ERROR: ${dep} not found on PATH"; exit 1; }
done
python3 -c "import moto" 2>/dev/null || { red "ERROR: moto is not installed (pip install 'moto[server]')"; exit 1; }

export AWS_ACCESS_KEY_ID="emulated"
export AWS_SECRET_ACCESS_KEY="emulated"
export AWS_DEFAULT_REGION="us-east-1"
export AWS_PAGER=""
# moto serves buckets on a path, not a virtual host: there is no wildcard
# DNS in front of it.
export AWS_S3_ADDRESSING_STYLE="path"

s3() { aws --endpoint-url "$ENDPOINT" s3api "$@"; }

export VAULT_ADDR="https://127.0.0.1:8200"
export VAULT_CACERT="${REPO_ROOT}/docker/dev/tls/ca.crt"

# ---------------------------------------------------------------------------
info ""
info "=== An emulated S3, and a bucket shaped like the real one ==="
# ---------------------------------------------------------------------------
# Nothing may already hold the port, for the reason tests/state-backend
# gives at length: a leftover emulator answers exactly like one this run
# started, while holding another run's objects.
if curl -s -o /dev/null "$ENDPOINT" 2>/dev/null; then
    red "ERROR: something is already listening on ${ENDPOINT}."
    red "       It holds state this suite did not create. Stop it first:"
    red "         pkill -f 'moto[.]server'"
    exit 1
fi

python3 -m moto.server -p 5000 >"${WORK}/moto.log" 2>&1 &
MOTO_PID=$!
for _ in $(seq 1 40); do curl -s -o /dev/null "$ENDPOINT" && break; sleep 0.5; done

if ! curl -s -o /dev/null "$ENDPOINT"; then
    red "ERROR: the emulator did not start"; tail -3 "${WORK}/moto.log" >&2; exit 1
fi
if ! kill -0 "$MOTO_PID" 2>/dev/null; then
    red "ERROR: the emulator exited during startup"; tail -3 "${WORK}/moto.log" >&2; exit 1
fi
ok "the emulated S3 API is up"

s3 create-bucket --bucket "$BUCKET" >/dev/null 2>&1
# Versioned, matching terraform/aws/storage.tf. A snapshot bucket without
# versioning loses the previous backup to any overwrite, which is the
# arrangement this repository refuses elsewhere.
s3 put-bucket-versioning --bucket "$BUCKET" \
    --versioning-configuration Status=Enabled >/dev/null 2>&1

if [[ "$(s3 get-bucket-versioning --bucket "$BUCKET" --query 'Status' --output text 2>/dev/null)" == "Enabled" ]]; then
    ok "and the bucket versions its objects"
else
    bad "and the bucket versions its objects"
fi

# ---------------------------------------------------------------------------
info ""
info "=== A cluster with something worth losing ==="
# ---------------------------------------------------------------------------
info "  clearing any previous cluster..."
"${COMPOSE[@]}" --profile spare down -v >/dev/null 2>&1

if ! ROOT_TOKEN="$("${REPO_ROOT}/scripts/bootstrap-dev-cluster.sh" 2>"${WORK}/bootstrap.log")"; then
    bad "the cluster came up" "$(tail -12 "${WORK}/bootstrap.log")"
    printf '\n=== Results ===\npassed: %d\nfailed: %d\n' "$PASS" "$FAIL"
    red "FAILED"
    exit 1
fi
CLAIMED=true
export VAULT_TOKEN="$ROOT_TOKEN"
ok "the cluster came up"

vault secrets enable -path=rtest -version=2 kv >/dev/null 2>&1 || true
if vault kv put rtest/canary value=present-at-snapshot-time >/dev/null 2>&1; then
    ok "and holds a secret written before the snapshot"
else
    bad "and holds a secret written before the snapshot" \
        "without it a restore proves nothing"
fi

# ---------------------------------------------------------------------------
info ""
info "=== snapshot.sh uploads through the S3 API ==="
# ---------------------------------------------------------------------------

SNAP_OUT="$(bash "$SNAPSHOT_SH" --cloud aws --bucket "$BUCKET" --prefix "$PREFIX" \
    --endpoint "$ENDPOINT" 2>&1)"; SNAP_RC=$?
if [[ "$SNAP_RC" -eq 0 ]]; then
    ok "snapshot.sh --cloud aws succeeds against the emulator"
else
    bad "snapshot.sh --cloud aws succeeds against the emulator" "$(tail -5 <<< "$SNAP_OUT")"
fi

KEY="$(s3 list-objects-v2 --bucket "$BUCKET" --prefix "${PREFIX}/" \
    --query 'Contents[0].Key' --output text 2>/dev/null)"
if [[ -n "$KEY" && "$KEY" != "None" ]]; then
    ok "and an object landed in the bucket (${KEY})"
else
    bad "and an object landed in the bucket"
    printf '\n=== Results ===\npassed: %d\nfailed: %d\n' "$PASS" "$FAIL"
    red "FAILED"; exit 1
fi

REMOTE_SIZE="$(s3 head-object --bucket "$BUCKET" --key "$KEY" \
    --query 'ContentLength' --output text 2>/dev/null)"
if [[ -n "$REMOTE_SIZE" && "$REMOTE_SIZE" -gt 0 ]]; then
    ok "and it is not empty (${REMOTE_SIZE} bytes)"
else
    bad "and it is not empty" "size: ${REMOTE_SIZE}"
fi

# ---------------------------------------------------------------------------
info ""
info "=== What came back is a snapshot ==="
# ---------------------------------------------------------------------------
# The step that has never existed. Everything before this proves an
# object is at a key.

DOWNLOADED="${WORK}/from-s3.snap"
if s3 get-object --bucket "$BUCKET" --key "$KEY" "$DOWNLOADED" >/dev/null 2>&1; then
    ok "the object downloads"
else
    bad "the object downloads"
fi

LOCAL_SIZE="$(stat -c '%s' "$DOWNLOADED" 2>/dev/null || echo 0)"
if [[ "$LOCAL_SIZE" == "$REMOTE_SIZE" ]]; then
    ok "and is the size the bucket reported (${LOCAL_SIZE})"
else
    bad "and is the size the bucket reported" "remote ${REMOTE_SIZE}, local ${LOCAL_SIZE}"
fi

# `snapshot inspect` is what snapshot.sh runs before uploading. Running
# it on the way back out is the difference between "the file we sent was
# a snapshot" and "the file in the bucket is one".
if vault operator raft snapshot inspect "$DOWNLOADED" >"${WORK}/inspect.log" 2>&1; then
    ok "and Vault inspects it as a valid snapshot"
else
    bad "and Vault inspects it as a valid snapshot" "$(tail -3 "${WORK}/inspect.log")"
fi

# The guard has to be able to fail, or it is not a guard. A byte-damaged
# copy must be refused by the same command that accepted the real one.
CORRUPT="${WORK}/corrupted.snap"
cp "$DOWNLOADED" "$CORRUPT"
printf 'this is not a snapshot' | dd of="$CORRUPT" bs=1 seek=64 conv=notrunc status=none 2>/dev/null
if ! vault operator raft snapshot inspect "$CORRUPT" >/dev/null 2>&1; then
    ok "and refuses a corrupted copy of it"
else
    bad "and refuses a corrupted copy of it" \
        "inspect accepts damaged input, so accepting the real one proved nothing"
fi

# ---------------------------------------------------------------------------
info ""
info "=== Restoring it puts the cluster back ==="
# ---------------------------------------------------------------------------

# Written after the snapshot, so it must NOT survive the restore. This is
# what distinguishes a restore from a no-op: a restore that silently did
# nothing leaves a healthy cluster that still has this.
vault kv put rtest/after-snapshot value=written-after-the-snapshot >/dev/null 2>&1
if [[ "$(vault kv get -field=value rtest/after-snapshot 2>/dev/null)" == "written-after-the-snapshot" ]]; then
    ok "a second secret is written after the snapshot"
else
    bad "a second secret is written after the snapshot"
fi

# Into the container, because Vault reads the restore file itself and
# cannot read one on the host.
"${COMPOSE[@]}" exec -T vault-0 sh -c 'cat > /tmp/restore.snap' < "$DOWNLOADED" 2>/dev/null
if "${COMPOSE[@]}" exec -T -e VAULT_TOKEN="$ROOT_TOKEN" vault-0 \
        vault operator raft snapshot restore -force /tmp/restore.snap >"${WORK}/restore.log" 2>&1; then
    ok "the downloaded snapshot restores"
else
    bad "the downloaded snapshot restores" "$(tail -5 "${WORK}/restore.log")"
fi

# Vault reloads state and re-elects after a restore.
for _ in $(seq 1 30); do
    [[ "$(vault status -format=json 2>/dev/null | jq -r '.sealed // "true"')" == "false" ]] && break
    sleep 2
done

if [[ "$(vault status -format=json 2>/dev/null | jq -r '.sealed')" == "false" ]]; then
    ok "and the cluster comes back unsealed"
else
    bad "and the cluster comes back unsealed"
fi

if [[ "$(vault kv get -field=value rtest/canary 2>/dev/null)" == "present-at-snapshot-time" ]]; then
    ok "and the secret from before the snapshot is there"
else
    bad "and the secret from before the snapshot is there" \
        "the object round-tripped but did not carry the data"
fi

# The assertion that makes the one above mean something.
if ! vault kv get -field=value rtest/after-snapshot >/dev/null 2>&1; then
    ok "and the secret written after it is gone"
else
    bad "and the secret written after it is gone" \
        "nothing was restored; the cluster was simply never changed"
fi

# ---------------------------------------------------------------------------
printf '\n=== Results ===\npassed: %d\nfailed: %d\n' "$PASS" "$FAIL"
if [[ "$FAIL" -eq 0 ]]; then
    green "All ${PASS} assertions passed."
else
    red "FAILED"
fi
[[ "$FAIL" -eq 0 ]]

#!/usr/bin/env bash
#
# run-tests.sh — Anchors shipped to storage that refuses to delete them
#
# Usage:
#   ./tests/audit-anchor-worm/run-tests.sh
#
# Takes about two minutes. Costs nothing and creates nothing outside a
# local process.
#
# WHY THIS EXISTS
#
# tests/audit-chain proves the anchors catch a rewritten chain. It proves
# it against an anchor file on the same Docker host as the trail, which
# is the thing docs/audit.md has always said is not the guarantee:
# whoever reaches the daemon reaches both volumes, and the evidence dies
# with the machine.
#
# This is the far end. It applies terraform/aws/audit-anchors against an
# implementation of the AWS API (moto), ships real anchors into the
# bucket that module built, and then attacks them the ways an attacker
# holding the shipping credential actually can:
#
#   delete the version         refused by the object lock
#   delete without a version   permitted, and it hides every anchor
#   rewrite the chain          reported as a conflict, never overwritten
#
# The second one is the reason this suite is longer than it looks. Object
# lock does not refuse a delete *marker*, because a marker destroys
# nothing — but a marked key is absent from list-objects-v2 and 404s on
# head-object, so anchors that are fully intact read as anchors that
# never existed. A shipper built on the object APIs reports "no anchors
# found" in exactly the case where the answer is "somebody tried to
# remove them". The assertions below pin both halves: that the marker is
# permitted, and that fetching sees past it and says so.
#
# WHAT A GREEN RUN DOES NOT MEAN
#
# An emulator implements the API, not the service. This does not show
# that S3 enforces COMPLIANCE retention in an account, that the IAM
# policy the module writes is the one AWS evaluates, or that a bucket in
# a second account is reachable by the credential that would need to
# reach it. Those need a real apply; docs/cloud-apply.md lists them.
#
# It also does not make the collection off-host. The collector still runs
# beside Vault, so an attacker on that host can stop it, and an entry
# never collected is never anchored. What this closes is the other half:
# what already left cannot be edited, and cannot be quietly removed.
#
# Requirements: terraform, python3 with moto[server], curl, aws, sha256sum

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

MODULE="${REPO_ROOT}/terraform/aws/audit-anchors"
SHIP="${REPO_ROOT}/scripts/ship-anchors.sh"
VERIFY="${REPO_ROOT}/scripts/verify-audit-chain.sh"
COLLECT="${REPO_ROOT}/docker/audit-collector/collect.sh"
ANCHOR="${REPO_ROOT}/docker/audit-collector/anchor.sh"

# Reused rather than copied, the same way tests/state-backend reuses it:
# two copies of an endpoint list is two places to update when the
# emulator moves.
OVERRIDE_SRC="${REPO_ROOT}/tests/cloud-apply-emulated/provider_override.tf"
ENDPOINT="http://localhost:5000"

GENESIS="0000000000000000000000000000000000000000000000000000000000000000"

WORK="$(mktemp -d)"
MOTO_PID=""
BUCKET=""

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
    # repository.
    if [[ "$CLAIMED" == true ]]; then
        rm -f "${MODULE}/zz_emulated_override.tf"
        rm -rf "${MODULE}/.terraform" "${MODULE}/terraform.tfstate" \
               "${MODULE}/terraform.tfstate.backup"
    fi
    rm -rf "$WORK"
    exit "$rc"
}
trap cleanup EXIT INT TERM

for dep in terraform python3 curl aws sha256sum; do
    command -v "$dep" >/dev/null 2>&1 || { red "ERROR: ${dep} not found on PATH"; exit 1; }
done
python3 -c "import moto" 2>/dev/null || { red "ERROR: moto is not installed (pip install 'moto[server]')"; exit 1; }
[[ -f "$OVERRIDE_SRC" ]] || { red "ERROR: missing ${OVERRIDE_SRC}"; exit 1; }

# The emulator answers any credential, but the AWS CLI refuses to build a
# request without one.
export AWS_ACCESS_KEY_ID="emulated"
export AWS_SECRET_ACCESS_KEY="emulated"
export AWS_DEFAULT_REGION="us-east-1"
export AWS_PAGER=""

s3() { aws --endpoint-url "$ENDPOINT" s3api "$@"; }

# count_objects <prefix> -- how many keys are visible under a prefix.
# Not --query KeyCount: the emulator answers that with null, which
# arrives as the string "None" and is then read as a variable name by a
# numeric [[ ]] comparison under set -u. Counting the list is the same
# answer without the trap.
count_objects() {
    s3 list-objects-v2 --bucket "$1" --prefix "$2" \
        --query 'Contents[].Key' --output text 2>/dev/null \
        | tr '\t' '\n' | grep -v '^None$' | grep -c . || true
}

# count_versions <bucket> <key> -- object versions under one key,
# delete markers excluded.
count_versions() {
    s3 list-object-versions --bucket "$1" --prefix "$2" \
        --query 'Versions[].VersionId' --output text 2>/dev/null \
        | tr '\t' '\n' | grep -v '^None$' | grep -c . || true
}

RC=0
OUT=""
run_ship() {
    RC=0
    OUT="$(bash "$SHIP" --endpoint "$ENDPOINT" "$@" 2>&1)" || RC=$?
}

assert_rc()    { if [[ "$RC" == "$2" ]]; then ok "$1"; else bad "$1" "expected rc ${2}, got ${RC}: $(tr '\n' ' ' <<< "$OUT" | cut -c1-160)"; fi; }
assert_says()  { if [[ "$OUT" == *"$2"* ]]; then ok "$1"; else bad "$1" "output lacked: ${2}"; fi; }
assert_lacks() { if [[ "$OUT" != *"$2"* ]]; then ok "$1"; else bad "$1" "output unexpectedly contained: ${2}"; fi; }

# trail <name> <batches> -- entries chained by the real collector and
# anchored by the real anchor service, both the shipping containers' own
# scripts, so what is shipped below is what would actually be shipped.
#
# Entries arrive in batches with an anchor run after each, because the
# anchor service records the head only when it MOVES. Writing every entry
# and then anchoring once produces a single anchor no matter how many
# entries there were -- which is correct behaviour, and would have left
# every count and ordering assertion here running against one line.
trail() {
    local dir="${WORK}/$1"; local batches="$2"; local b i seq=0
    rm -rf "$dir"; mkdir -p "${dir}/anchors"
    for ((b = 1; b <= batches; b++)); do
        for ((i = 1; i <= 3; i++)); do
            seq=$((seq + 1))
            printf '{"seq":%d,"type":"request","path":"secret/data/%d"}\n' "$seq" "$seq"
        done | COLLECT_DIR="$dir" sh "$COLLECT"
        anchor_once "$dir"
    done
    printf '%s' "$dir"
}

# anchor_once <dir> -- one pass of the real anchor service. It appends
# only when the head has moved, and its in-memory LAST_ANCHORED does not
# survive the restart, so each call records the current head exactly once.
anchor_once() {
    local dir="$1"
    COLLECT_DIR="$dir" ANCHOR_DIR="${dir}/anchors" ANCHOR_INTERVAL=1 \
        timeout 2 sh "$ANCHOR" >/dev/null 2>&1
    return 0
}

# rechain <dir> -- what an attacker with write access does: recompute the
# whole chain over whatever the log now says, so it is self-consistent.
# Copied in shape from tests/audit-chain, which asserts that this passes
# verification when no anchor is available.
rechain() {
    local dir="$1" prev="$GENESIS" seq=0 line eh ch
    : > "${dir}/audit-chain.log"
    while IFS= read -r line; do
        seq=$((seq + 1))
        eh="$(printf '%s\n' "$line" | sha256sum | cut -d' ' -f1)"
        ch="$(printf '%s%s' "$prev" "$eh" | sha256sum | cut -d' ' -f1)"
        printf '%s %s %s\n' "$seq" "$eh" "$ch" >> "${dir}/audit-chain.log"
        prev="$ch"
    done < "${dir}/audit-socket.log"
}

# reanchor_in_place <dir> -- the anchor file rewritten to agree with the
# rewritten chain, at the sequence numbers it already records.
#
# This is the attacker who owns the host, which is the premise: the
# anchor volume is read-only to the collector, not to whoever reached the
# Docker daemon. Recomputing the chain and leaving stale anchors beside
# it would be caught locally by verify-audit-chain.sh, so an attacker
# who has got this far fixes both.
#
# It also has to preserve the sequence numbers. Deleting an entry
# renumbers every sequence after it, and the rewritten head then lands on
# a sequence that was never shipped -- a new key, no collision, and the
# conflict check below would pass without ever having been reached.
reanchor_in_place() {
    local dir="$1" seq ts newhash
    local anchors="${dir}/anchors/audit-anchors.log"
    : > "${anchors}.new"
    while read -r ts seq _; do
        [[ -n "$seq" ]] || continue
        newhash="$(awk -v s="$seq" '$1 == s { print $3 }' "${dir}/audit-chain.log")"
        [[ -n "$newhash" ]] || continue
        printf '%s %s %s\n' "$ts" "$seq" "$newhash" >> "${anchors}.new"
    done < "$anchors"
    mv "${anchors}.new" "$anchors"
}

# ---------------------------------------------------------------------------
info ""
info "=== Static: what the module declares ==="
# ---------------------------------------------------------------------------
# Cheap, and they cover the half no apply against an emulator reaches:
# whether the mode chosen is the one that cannot be overridden.

if grep -qE '^\s*mode\s*=\s*"COMPLIANCE"' "${MODULE}/main.tf"; then
    ok "the retention mode is COMPLIANCE"
else
    bad "the retention mode is COMPLIANCE" \
        "GOVERNANCE permits a privileged delete, which is the threat here"
fi

if grep -q 'object_lock_enabled = true' "${MODULE}/main.tf"; then
    ok "object lock is enabled on the bucket itself"
else
    bad "object lock is enabled on the bucket itself"
fi

if grep -q 'prevent_destroy = true' "${MODULE}/main.tf"; then
    ok "the bucket refuses to be destroyed"
else
    bad "the bucket refuses to be destroyed"
fi

# The shipper reads Versions[], which is a permission of its own. Granting
# ListBucket alone leaves it seeing an empty bucket -- every anchor reads
# as unshipped and a conflict is written as a new anchor.
if grep -q 's3:ListBucketVersions' "${MODULE}/main.tf"; then
    ok "the shipping policy can list versions, not only objects"
else
    bad "the shipping policy can list versions, not only objects"
fi

# ---------------------------------------------------------------------------
info ""
info "=== Applying terraform/aws/audit-anchors against an emulated AWS ==="
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
for _ in $(seq 1 40); do
    curl -s -o /dev/null "$ENDPOINT" && break
    sleep 0.5
done
curl -s -o /dev/null "$ENDPOINT" || { red "ERROR: moto did not start"; exit 1; }

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

cp "$OVERRIDE_SRC" "${MODULE}/zz_emulated_override.tf"

if terraform -chdir="$MODULE" init -input=false -no-color >"${WORK}/init.log" 2>&1; then
    ok "the module initialises"
else
    bad "the module initialises" "$(tail -3 "${WORK}/init.log")"
fi

if terraform -chdir="$MODULE" apply -auto-approve -input=false -no-color \
        >"${WORK}/apply.log" 2>&1; then
    ok "the module applies in one pass"
else
    bad "the module applies in one pass" "$(tail -5 "${WORK}/apply.log")"
fi

BUCKET="$(terraform -chdir="$MODULE" output -raw anchor_bucket 2>/dev/null)"
if [[ -n "$BUCKET" ]]; then
    ok "it reports the bucket to ship to (${BUCKET})"
else
    bad "it reports the bucket to ship to"
    red "cannot continue without a bucket"; exit 1
fi

# Asserted against the API rather than the configuration. A bucket whose
# lock configuration failed to apply looks identical in main.tf.
LOCKCFG="$(s3 get-object-lock-configuration --bucket "$BUCKET" 2>&1)"
if [[ "$LOCKCFG" == *'"ObjectLockEnabled": "Enabled"'* ]]; then
    ok "the bucket it built reports object lock enabled"
else
    bad "the bucket it built reports object lock enabled" "$LOCKCFG"
fi

if [[ "$LOCKCFG" == *'"Mode": "COMPLIANCE"'* ]]; then
    ok "and a default retention in COMPLIANCE mode"
else
    bad "and a default retention in COMPLIANCE mode" "$LOCKCFG"
fi

# ---------------------------------------------------------------------------
info ""
info "=== A bucket that cannot refuse a delete is refused ==="
# ---------------------------------------------------------------------------
# The check that decides whether any of the rest is worth anything.
# Shipping an audit trail somewhere the same credential can empty is a
# change of address, not a change of risk.

D="$(trail plain 3)"
ANCHORS="${D}/anchors/audit-anchors.log"

if [[ -s "$ANCHORS" ]]; then
    ok "the anchor service produced an anchor to ship"
else
    bad "the anchor service produced an anchor to ship"
    red "cannot continue without anchors"; exit 1
fi

s3 create-bucket --bucket unlocked-anchors >/dev/null 2>&1

run_ship --bucket unlocked-anchors --cluster c1 --anchors "$ANCHORS"
assert_rc   "shipping to a bucket without object lock fails" 1
assert_says "and says object lock is what is missing"  "does not have object lock enabled"
assert_says "and says why that makes shipping pointless" "delete the anchors as easily"

# Nothing may have been uploaded before the refusal: a partial ship to an
# unprotected bucket is the trail leaking to somewhere it is not safe.
LEAKED="$(count_objects unlocked-anchors "anchors/")"
if [[ "$LEAKED" == "0" ]]; then
    ok "and nothing was uploaded before it refused"
else
    bad "and nothing was uploaded before it refused" "${LEAKED} object(s) landed"
fi

run_ship --bucket unlocked-anchors --cluster c1 --anchors "$ANCHORS" --allow-unlocked
assert_rc    "--allow-unlocked ships anyway" 0
assert_says  "and warns what it gave up"     "does not protect the trail"

# ---------------------------------------------------------------------------
info ""
info "=== Shipping to the locked bucket ==="
# ---------------------------------------------------------------------------

run_ship --bucket "$BUCKET" --cluster c1 --anchors "$ANCHORS"
assert_rc   "anchors ship to a locked bucket" 0

SHIPPED_N="$(count_objects "$BUCKET" "anchors/c1/")"
LOCAL_N="$(wc -l < "$ANCHORS" | tr -d ' ')"
if [[ "$SHIPPED_N" == "$LOCAL_N" ]]; then
    ok "every local anchor became an object (${SHIPPED_N})"
else
    bad "every local anchor became an object" "local ${LOCAL_N}, shipped ${SHIPPED_N}"
fi

# One object per anchor is the whole design: a single appended file is
# rewritten by one PUT, which is the operation the lock has to prevent.
# So more than one anchor has to mean more than one object -- a fixture
# with a single anchor could not tell the two arrangements apart, which
# is why trail() anchors in batches.
if [[ "$LOCAL_N" -gt 1 && "$SHIPPED_N" == "$LOCAL_N" ]]; then
    ok "several anchors became several objects, not one appended file"
else
    bad "several anchors became several objects, not one appended file" \
        "local ${LOCAL_N}, shipped ${SHIPPED_N}"
fi

run_ship --bucket "$BUCKET" --cluster c1 --anchors "$ANCHORS"
assert_rc   "shipping the same anchors again succeeds" 0
assert_says "and ships nothing the second time"        "Shipped 0,"

# ---------------------------------------------------------------------------
info ""
info "=== The lock refuses the delete ==="
# ---------------------------------------------------------------------------
# The property the whole arrangement is bought for.

A_KEY="$(s3 list-objects-v2 --bucket "$BUCKET" --prefix "anchors/c1/" \
    --query 'Contents[0].Key' --output text 2>/dev/null)"
A_VID="$(s3 list-object-versions --bucket "$BUCKET" --prefix "$A_KEY" \
    --query 'Versions[0].VersionId' --output text 2>/dev/null)"
A_BEFORE="$(s3 get-object --bucket "$BUCKET" --key "$A_KEY" \
    "${WORK}/before" >/dev/null 2>&1 && cat "${WORK}/before")"

if s3 delete-object --bucket "$BUCKET" --key "$A_KEY" \
        --version-id "$A_VID" >/dev/null 2>&1; then
    bad "deleting a shipped anchor is refused" \
        "the delete succeeded -- the anchor was not protected at all"
else
    ok "deleting a shipped anchor is refused"
fi

A_AFTER="$(s3 get-object --bucket "$BUCKET" --key "$A_KEY" \
    "${WORK}/after" >/dev/null 2>&1 && cat "${WORK}/after")"
if [[ -n "$A_AFTER" && "$A_AFTER" == "$A_BEFORE" ]]; then
    ok "and the anchor still reads exactly as shipped"
else
    bad "and the anchor still reads exactly as shipped" \
        "before: ${A_BEFORE} after: ${A_AFTER}"
fi

# Overwriting is the other way to erase an anchor, and object lock does
# NOT prevent it: the lock protects a version, and a PUT to the same key
# writes a new one. So the attack succeeds at the API level and the
# protection has to come from --fetch reading the version shipped first.
printf 'not an anchor\n' > "${WORK}/forged"
PUT_OUT="$(s3 put-object --bucket "$BUCKET" --key "$A_KEY" \
    --body "${WORK}/forged" 2>&1)"
if [[ "$PUT_OUT" == *VersionId* ]]; then
    ok "overwriting a locked anchor is permitted, as S3 permits it"
else
    bad "overwriting a locked anchor is permitted, as S3 permits it" \
        "the emulator refused the PUT, so the guard below is untested: ${PUT_OUT}"
fi

VCOUNT="$(count_versions "$BUCKET" "$A_KEY")"
if [[ "$VCOUNT" == "2" ]]; then
    ok "and it added a version rather than replacing one"
else
    bad "and it added a version rather than replacing one" "versions: ${VCOUNT}"
fi

# The current version now reads as the forgery -- which is exactly why
# --fetch must not read the current version.
if s3 get-object --bucket "$BUCKET" --key "$A_KEY" \
        "${WORK}/current" >/dev/null 2>&1 && [[ "$(cat "${WORK}/current")" == "not an anchor" ]]; then
    ok "and the key now reads as the forgery"
else
    bad "and the key now reads as the forgery"
fi

if s3 get-object --bucket "$BUCKET" --key "$A_KEY" --version-id "$A_VID" \
        "${WORK}/orig" >/dev/null 2>&1 && [[ "$(cat "${WORK}/orig")" == "$A_BEFORE" ]]; then
    ok "while the version shipped first is intact underneath"
else
    bad "while the version shipped first is intact underneath"
fi

# The property that makes the version underneath worth having: --fetch
# has to return the original, not the forgery sitting on top of it.
# Version ids are opaque, so "the oldest" can only come from the order
# the API returns them in -- sorting by version id picks one at random
# and would pass this test roughly half the time.
run_ship --bucket "$BUCKET" --cluster c1 --fetch "${WORK}/forged-fetch"
assert_rc "fetching after the overwrite succeeds" 0
if ! grep -q "not an anchor" "${WORK}/forged-fetch"; then
    ok "and returns no part of the forgery"
else
    bad "and returns no part of the forgery" \
        "--fetch read the current version instead of the one shipped first"
fi
if grep -q "$(cut -d' ' -f3 <<< "$A_BEFORE")" "${WORK}/forged-fetch"; then
    ok "and still carries the hash that was shipped"
else
    bad "and still carries the hash that was shipped"
fi

# ---------------------------------------------------------------------------
info ""
info "=== A locked bucket with no default retention ==="
# ---------------------------------------------------------------------------
# Object lock enabled at creation does not imply a default retention
# rule. `create-bucket --object-lock-enabled-for-bucket` gives a bucket
# that locks nothing until each object asks for it, and a bucket made by
# hand rather than by terraform/aws/audit-anchors is exactly that.
#
# So the per-object retention the shipper sets is the only thing
# protecting anchors there. Against a bucket the module built it is
# redundant -- the default rule covers an object written without it --
# and that redundancy is precisely why this case needs a bucket of its
# own to be testable at all.

s3 create-bucket --bucket no-default-retention     --object-lock-enabled-for-bucket >/dev/null 2>&1

ND_CFG="$(s3 get-object-lock-configuration --bucket no-default-retention 2>&1)"
if [[ "$ND_CFG" == *Enabled* && "$ND_CFG" != *DefaultRetention* ]]; then
    ok "the bucket has object lock and no default retention"
else
    bad "the bucket has object lock and no default retention"         "a default rule here would make the next check pass for the wrong reason"
fi

D6="$(trail nodefault 2)"
run_ship --bucket no-default-retention --cluster nd     --anchors "${D6}/anchors/audit-anchors.log"
assert_rc "anchors ship to it" 0

ND_KEY="$(s3 list-objects-v2 --bucket no-default-retention --prefix "anchors/nd/"     --query 'Contents[0].Key' --output text 2>/dev/null)"
ND_VID="$(s3 list-object-versions --bucket no-default-retention --prefix "$ND_KEY"     --query 'Versions[0].VersionId' --output text 2>/dev/null)"

if s3 delete-object --bucket no-default-retention --key "$ND_KEY"         --version-id "$ND_VID" >/dev/null 2>&1; then
    bad "and are undeletable anyway, from the retention the shipper set"         "the delete succeeded -- nothing protected these anchors"
else
    ok "and are undeletable anyway, from the retention the shipper set"
fi

# ---------------------------------------------------------------------------
info ""
info "=== The delete marker: what the lock does not refuse ==="
# ---------------------------------------------------------------------------
# A delete with no version id destroys nothing, so object lock permits it
# -- and it hides the key from list-objects-v2 and head-object. Every
# anchor can be made invisible by the credential that ships them. This
# section pins that the emulator permits it (so the risk is real, not
# theoretical) and that the shipper sees past it anyway.

D2="$(trail marked 3)"
run_ship --bucket "$BUCKET" --cluster marked --anchors "${D2}/anchors/audit-anchors.log"
assert_rc "a second cluster's anchors ship to the same bucket" 0

M_KEY="$(s3 list-objects-v2 --bucket "$BUCKET" --prefix "anchors/marked/" \
    --query 'Contents[0].Key' --output text 2>/dev/null)"

if s3 delete-object --bucket "$BUCKET" --key "$M_KEY" >/dev/null 2>&1; then
    ok "a versionless delete is permitted despite the lock"
else
    bad "a versionless delete is permitted despite the lock" \
        "if this is refused the marker risk is gone and the guard below is dead code"
fi

# The half that makes it dangerous: intact, and invisible.
if s3 head-object --bucket "$BUCKET" --key "$M_KEY" >/dev/null 2>&1; then
    bad "and the anchor now reads as absent" "head-object still finds it"
else
    ok "and the anchor now reads as absent"
fi

# Non-zero, and the file is still written. A fetch that recovered the
# anchors and reported the attempt to erase them only on stderr would
# exit 0, so a scheduled verification would record a success on the one
# event the anchors exist to surface.
run_ship --bucket "$BUCKET" --cluster marked --fetch "${WORK}/marked-fetch"
assert_rc   "fetching a marked anchor exits non-zero" 1
assert_says "and reports the marker as an attack"     "delete marker over them"
assert_says "and names the policy that prevents it"   "denies s3:DeleteObject"

if [[ -s "${WORK}/marked-fetch" ]]; then
    ok "and still wrote the anchors it recovered"
else
    bad "and still wrote the anchors it recovered"         "a non-zero exit must not mean an empty file"
fi

FETCHED_N="$(wc -l < "${WORK}/marked-fetch" | tr -d ' ')"
LOCAL2_N="$(wc -l < "${D2}/anchors/audit-anchors.log" | tr -d ' ')"
if [[ "$FETCHED_N" == "$LOCAL2_N" ]]; then
    ok "and no anchor went missing from the fetch (${FETCHED_N})"
else
    bad "and no anchor went missing from the fetch" \
        "local ${LOCAL2_N}, fetched ${FETCHED_N}"
fi

# ---------------------------------------------------------------------------
info ""
info "=== A rewritten chain conflicts rather than overwriting ==="
# ---------------------------------------------------------------------------
# The finding the whole design exists to produce. tests/audit-chain shows
# a rewritten chain passes verification when no anchor is available; here
# the anchor is in a bucket the attacker cannot reach.

D3="$(trail rewrite 3)"
run_ship --bucket "$BUCKET" --cluster rewrite --anchors "${D3}/anchors/audit-anchors.log"
assert_rc "a clean trail ships" 0

ORIG_HEAD="$(cut -d' ' -f3 < "${D3}/anchors/audit-anchors.log" | tail -n 1)"

ORIG_SEQS="$(cut -d' ' -f2 < "${D3}/anchors/audit-anchors.log" | tr '\n' ' ')"

# Alter an entry in place, recompute the whole chain over it, and bring
# the local anchors into agreement. Editing rather than deleting keeps
# the sequence numbers, so the rewritten anchors collide with the ones
# already in the bucket instead of arriving as new keys.
sed -i '2s/.*/{"seq":2,"type":"request","path":"secret\/data\/nothing-to-see"}/' \
    "${D3}/audit-socket.log"
rechain "$D3"
reanchor_in_place "$D3"

NEW_HEAD="$(cut -d' ' -f3 < "${D3}/anchors/audit-anchors.log" | tail -n 1)"
if [[ -n "$NEW_HEAD" && "$NEW_HEAD" != "$ORIG_HEAD" ]]; then
    ok "rewriting the trail moves the local chain head"
else
    bad "rewriting the trail moves the local chain head" \
        "the fixture did not change; the conflict below would prove nothing"
fi

NEW_SEQS="$(cut -d' ' -f2 < "${D3}/anchors/audit-anchors.log" | tr '\n' ' ')"
if [[ "$NEW_SEQS" == "$ORIG_SEQS" ]]; then
    ok "and leaves the sequence numbers where they were (${NEW_SEQS%% })"
else
    bad "and leaves the sequence numbers where they were" \
        "before: ${ORIG_SEQS} after: ${NEW_SEQS} -- these would not collide"
fi

# The local view is now self-consistent: chain agrees with log, anchors
# agree with chain. Nothing on the host can tell that anything happened,
# which is the whole reason the bucket has to be somewhere else.
RC=0
OUT="$(bash "$VERIFY" --log "${D3}/audit-socket.log" \
    --chain "${D3}/audit-chain.log" \
    --anchors "${D3}/anchors/audit-anchors.log" 2>&1)" || RC=$?
assert_rc "and the rewritten trail verifies clean against its own anchors" 0

run_ship --bucket "$BUCKET" --cluster rewrite --anchors "${D3}/anchors/audit-anchors.log"
assert_rc    "shipping the rewritten anchors fails"   1
assert_says  "and reports a conflict"                 "CONFLICT at sequence"
assert_says  "and says nothing was overwritten"       "Nothing was overwritten"

# The claim in that message has to be true, or the report is worse than
# no report: it would tell an operator the evidence is intact while the
# shipper had just replaced it.
run_ship --bucket "$BUCKET" --cluster rewrite --fetch "${WORK}/rewrite-fetch"
assert_rc "the shipped anchors still fetch" 0
if grep -q "$ORIG_HEAD" "${WORK}/rewrite-fetch"; then
    ok "and still hold the head from before the rewrite"
else
    bad "and still hold the head from before the rewrite" \
        "the original head is gone from the bucket"
fi
if ! grep -q "$NEW_HEAD" "${WORK}/rewrite-fetch"; then
    ok "and never received the rewritten head"
else
    bad "and never received the rewritten head" \
        "the rewritten anchor was uploaded despite the conflict"
fi

# "Nothing was overwritten" is a claim the message makes, and every check
# above is blind to it: --fetch reads the version shipped first, so it
# returns the original whether or not a second version was written on
# top. Counting versions is what makes the claim falsifiable.
R_KEY="$(s3 list-objects-v2 --bucket "$BUCKET" --prefix "anchors/rewrite/"     --query 'Contents[0].Key' --output text 2>/dev/null)"
R_VERSIONS="$(count_versions "$BUCKET" "$R_KEY")"
if [[ "$R_VERSIONS" == "1" ]]; then
    ok "and wrote no second version of the anchor it conflicted on"
else
    bad "and wrote no second version of the anchor it conflicted on"         "${R_VERSIONS} versions of ${R_KEY} -- it uploaded over the evidence"
fi

# ---------------------------------------------------------------------------
info ""
info "=== A forged newer anchor does not suppress the conflict ==="
# ---------------------------------------------------------------------------
# The attacker's next move, once a conflict is what gives them away:
# overwrite the shipped anchor with one matching the rewritten chain, so
# the next ship compares equal and reports nothing.
#
# It fails because the comparison reads the version shipped FIRST. With
# only one version on a key, oldest and newest are the same object and
# the distinction cannot be tested -- which is why the forgery is written
# here rather than assumed.

FORGED_TS="$(cut -d' ' -f1 < "${D3}/anchors/audit-anchors.log" | head -n 1)"
FORGED_SEQ="$(cut -d' ' -f2 < "${D3}/anchors/audit-anchors.log" | head -n 1)"
FORGED_HASH="$(cut -d' ' -f3 < "${D3}/anchors/audit-anchors.log" | head -n 1)"
printf '%s %s %s
' "$FORGED_TS" "$FORGED_SEQ" "$FORGED_HASH" > "${WORK}/forged-anchor"

FORGED_KEY="$(printf 'anchors/rewrite/%012d.anchor' "$FORGED_SEQ")"
s3 put-object --bucket "$BUCKET" --key "$FORGED_KEY"     --body "${WORK}/forged-anchor" >/dev/null 2>&1

if [[ "$(count_versions "$BUCKET" "$FORGED_KEY")" == "2" ]]; then
    ok "the attacker can write a newer version matching their chain"
else
    bad "the attacker can write a newer version matching their chain"         "without two versions the next check cannot fail"
fi

run_ship --bucket "$BUCKET" --cluster rewrite --anchors "${D3}/anchors/audit-anchors.log"
assert_rc   "shipping still reports the conflict" 1
assert_says "against the anchor shipped first"    "CONFLICT at sequence ${FORGED_SEQ}"

# ---------------------------------------------------------------------------
info ""
info "=== The fetched anchors catch the rewrite ==="
# ---------------------------------------------------------------------------
# End to end: the file --fetch writes is the file verify-audit-chain.sh
# reads, and against the rewritten trail it has to fail.

RC=0
OUT="$(bash "$VERIFY" --log "${D3}/audit-socket.log" \
    --chain "${D3}/audit-chain.log" 2>&1)" || RC=$?
assert_rc "the rewritten trail passes with no anchors at all" 0

RC=0
OUT="$(bash "$VERIFY" --log "${D3}/audit-socket.log" \
    --chain "${D3}/audit-chain.log" \
    --anchors "${WORK}/rewrite-fetch" 2>&1)" || RC=$?
assert_rc   "and fails against the anchors fetched from the bucket" 1
assert_says "which name the anchor that disagrees"  "does not match the trail"

# ---------------------------------------------------------------------------
info ""
info "=== Ordering: sequence 10 must not sort before sequence 9 ==="
# ---------------------------------------------------------------------------
# The keys are zero-padded so a lexical list comes back in sequence
# order. Without the padding --fetch hands verify-audit-chain.sh a file
# that is out of order in a way nothing downstream would notice.

D4="$(trail ordering 5)"
run_ship --bucket "$BUCKET" --cluster ordering --anchors "${D4}/anchors/audit-anchors.log"
assert_rc "five anchors ship" 0

run_ship --bucket "$BUCKET" --cluster ordering --fetch "${WORK}/ordering-fetch"
assert_rc "and fetch back" 0

SEQS="$(cut -d' ' -f2 < "${WORK}/ordering-fetch" | tr '\n' ' ')"
SORTED="$(cut -d' ' -f2 < "${WORK}/ordering-fetch" | sort -n | tr '\n' ' ')"
if [[ "$SEQS" == "$SORTED" ]]; then
    ok "in ascending sequence order (${SEQS%% })"
else
    bad "in ascending sequence order" "got: ${SEQS}"
fi

# ---------------------------------------------------------------------------
info ""
info "=== A corrupt anchor file is reported, not shipped ==="
# ---------------------------------------------------------------------------
# The sequence number goes through printf '%012d', which fails on
# anything that is not a number -- and under `set -e` that ends the run
# on a printf error mentioning neither the anchor file nor the line.

D5="$(trail corrupt 2)"
CORRUPT="${D5}/anchors/audit-anchors.log"
printf '2026-01-01T00:00:00Z not-a-number deadbeef
' >> "$CORRUPT"

run_ship --bucket "$BUCKET" --cluster corrupt --anchors "$CORRUPT"
assert_rc    "a non-numeric sequence does not crash the run" 0
assert_says  "and the bad line is named"                     "unparseable anchor line"
assert_says  "and counted apart from the ones already there" "could not be parsed"

# The good anchors either side of it still have to ship: one bad line is
# not a reason to lose the trail.
CORRUPT_N="$(count_objects "$BUCKET" "anchors/corrupt/")"
GOOD_N="$(grep -c . "$CORRUPT")"
GOOD_N=$((GOOD_N - 1))
if [[ "$CORRUPT_N" == "$GOOD_N" ]]; then
    ok "and every well-formed anchor still shipped (${CORRUPT_N})"
else
    bad "and every well-formed anchor still shipped"         "expected ${GOOD_N}, got ${CORRUPT_N}"
fi

# "already present" and "could not be parsed" are different findings and
# must not share a counter -- a corrupt line reported as already present
# reads as success.
assert_lacks "and it is not reported as already present" "already present 1."

# ---------------------------------------------------------------------------
info ""
info "=== Fetching from a prefix with nothing in it ==="
# ---------------------------------------------------------------------------
# "No anchors were ever shipped" and "somebody removed them" must not
# look the same, so the empty case has to be an error rather than an
# empty file reported as success.

run_ship --bucket "$BUCKET" --cluster never-shipped --fetch "${WORK}/empty-fetch"
assert_rc   "fetching a prefix with no anchors fails" 1
assert_says "and says so"                             "no anchors found"

# ---------------------------------------------------------------------------
printf '\n'
if [[ "$FAIL" -eq 0 ]]; then
    green "All ${PASS} checks passed."
else
    red "${FAIL} failed, ${PASS} passed."
fi
[[ "$FAIL" -eq 0 ]]

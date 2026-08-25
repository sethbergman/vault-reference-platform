#!/usr/bin/env bash
#
# run-tests.sh — Tests for the audit hash chain and its verifier
#
# Usage:
#   ./tests/audit-chain/run-tests.sh
#
# Runs in a few seconds. No cluster, no Docker: collect.sh reads entries
# on stdin and verify-audit-chain.sh takes explicit paths, so both run as
# host processes against files in a temp directory.
#
# WHAT IS BEING TESTED
#
# The chain exists to make an edit to the audit trail visible. So the
# cases are almost all tampering, one per way the trail can be wrong,
# matching the taxonomy in verify-audit-chain.sh:
#
#   altered entry        the entry no longer hashes to its recorded hash
#   removed entry        the link is intact but covers a different history
#   appended by hand     the log grew past the chain
#   truncated log        the chain has links with no entry behind them
#   rewritten chain      internally consistent and completely false
#
# The last one is the reason the anchor service exists, and it is the
# case worth reading first. An attacker who can write to the audit volume
# can delete what they did *and* recompute every hash after it. The
# result passes every check that reads only the log and the chain. The
# test below asserts exactly that -- it verifies clean without anchors --
# and then asserts the anchor catches it. If the first half of that ever
# starts failing, the anchors have stopped being load-bearing and this
# file should be read again.
#
# Whether the containers wire up correctly is tests/integration.
#
# Requirements: bash, sha256sum

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
COLLECT="${REPO_ROOT}/docker/audit-collector/collect.sh"
ANCHOR="${REPO_ROOT}/docker/audit-collector/anchor.sh"
VERIFY="${REPO_ROOT}/scripts/verify-audit-chain.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

green() { printf '\033[32m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*"; }

ok()  { PASS=$((PASS + 1)); green "  PASS  $1"; }
bad() { FAIL=$((FAIL + 1)); red   "  FAIL  $1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; return 0; }

for f in "$COLLECT" "$ANCHOR" "$VERIFY"; do
    [[ -f "$f" ]] || { red "ERROR: missing ${f}"; exit 1; }
done
command -v sha256sum >/dev/null 2>&1 || { red "ERROR: sha256sum not found"; exit 1; }

GENESIS="0000000000000000000000000000000000000000000000000000000000000000"

RC=0
OUT=""

# run_verify <dir> [extra args] -- verification over a trail directory.
run_verify() {
    local dir="$1"; shift
    local args=(--log "${dir}/audit-socket.log" --chain "${dir}/audit-chain.log")
    [[ -s "${dir}/audit-anchors.log" ]] && args+=(--anchors "${dir}/audit-anchors.log")
    RC=0
    OUT="$(bash "$VERIFY" "${args[@]}" "$@" 2>&1)" || RC=$?
}

# run_verify_no_anchors <dir> -- deliberately ignores any anchor file.
run_verify_no_anchors() {
    local dir="$1"
    RC=0
    OUT="$(bash "$VERIFY" --log "${dir}/audit-socket.log" \
        --chain "${dir}/audit-chain.log" 2>&1)" || RC=$?
}

# trail <name> <n> -- a fresh directory holding n chained entries,
# produced by the real collector rather than by a fixture, so the tests
# cannot drift from what it actually writes.
trail() {
    local dir="${WORK}/$1"; local n="$2"; local i
    rm -rf "$dir"; mkdir -p "$dir"
    for ((i = 1; i <= n; i++)); do
        printf '{"seq":%d,"type":"request","path":"secret/data/%d"}\n' "$i" "$i"
    done | COLLECT_DIR="$dir" sh "$COLLECT"
    printf '%s' "$dir"
}

# rechain <dir> -- what an attacker with write access does: recompute the
# whole chain over whatever the log now says, so it is self-consistent.
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

assert_rc()   { if [[ "$RC" == "$2" ]]; then ok "$1"; else bad "$1" "expected rc ${2}, got ${RC}: $(head -3 <<< "$OUT" | tr '\n' ' ')"; fi; }
assert_says() { if [[ "$OUT" == *"$2"* ]]; then ok "$1"; else bad "$1" "output lacked: ${2}"; fi; }
assert_lacks(){ if [[ "$OUT" != *"$2"* ]]; then ok "$1"; else bad "$1" "output unexpectedly contained: ${2}"; fi; }

# ---------------------------------------------------------------------------
printf '\n=== The collector chains what it receives ===\n'
# ---------------------------------------------------------------------------
D="$(trail clean 5)"

if [[ "$(wc -l < "${D}/audit-socket.log")" == "5" ]]; then
    ok "five entries were written to the log"
else
    bad "five entries were written to the log" "$(wc -l < "${D}/audit-socket.log")"
fi
if [[ "$(wc -l < "${D}/audit-chain.log")" == "5" ]]; then
    ok "and five links to the chain"
else
    bad "and five links to the chain" "$(wc -l < "${D}/audit-chain.log")"
fi

# The first link must start from the published genesis value, not from
# anything only the collector knows, or nobody else could verify it.
FIRST_ENTRY="$(sed -n 1p "${D}/audit-socket.log")"
E1="$(printf '%s\n' "$FIRST_ENTRY" | sha256sum | cut -d' ' -f1)"
C1="$(printf '%s%s' "$GENESIS" "$E1" | sha256sum | cut -d' ' -f1)"
if [[ "$(sed -n 1p "${D}/audit-chain.log")" == "1 ${E1} ${C1}" ]]; then
    ok "the first link is reproducible from the published genesis"
else
    bad "the first link is reproducible from the published genesis" \
        "$(sed -n 1p "${D}/audit-chain.log")"
fi

# A blank line carries no entry, so chaining it would add a link
# representing nothing.
BD="${WORK}/blanks"; mkdir -p "$BD"
printf '%s\n' '{"a":1}' '' '{"b":2}' | COLLECT_DIR="$BD" sh "$COLLECT"
if [[ "$(wc -l < "${BD}/audit-chain.log")" == "2" ]]; then
    ok "blank lines produce no link"
else
    bad "blank lines produce no link" "$(wc -l < "${BD}/audit-chain.log")"
fi

run_verify "$D"
assert_rc   "a clean trail verifies" 0
assert_says "and says the chain is intact" "chain intact"

# The chain was added beside the log, not inside it. Everything already
# reading audit-socket.log -- the integration suite, an operator with
# grep, a shipper -- must see exactly the bytes Vault sent, or chaining
# became a breaking change to the thing it was meant to protect.
EXPECTED_LOG="$(for ((i = 1; i <= 5; i++)); do
    printf '{"seq":%d,"type":"request","path":"secret/data/%d"}\n' "$i" "$i"
done)"
if [[ "$(cat "${D}/audit-socket.log")" == "$EXPECTED_LOG" ]]; then
    ok "the entries are byte-identical to what was sent"
else
    bad "the entries are byte-identical to what was sent" \
        "the chain must live beside the log, never inside it"
fi

# The lock is a directory, so failing to remove it does not error --
# it just makes every later entry wait out the five-second timeout and
# then append unserialised.
if [[ ! -e "${D}/.chain.lock" ]]; then
    ok "the lock is released rather than left behind"
else
    bad "the lock is released rather than left behind" \
        "a stale lock costs five seconds per entry and then gives up on ordering"
fi

# ---------------------------------------------------------------------------
printf '\n=== Nothing collected is not the same as something wrong ===\n'
# ---------------------------------------------------------------------------
ED="${WORK}/empty"; mkdir -p "$ED"
: > "${ED}/audit-socket.log"; : > "${ED}/audit-chain.log"
run_verify "$ED"
assert_rc   "an empty trail is not a failure" 0
assert_says "and says so"                     "OK (empty)"

# Entries with no chain at all is what the old append-only collector
# produced. It has to be a failure, not an empty-ish pass.
UD="${WORK}/unchained"; mkdir -p "$UD"
printf '%s\n' '{"a":1}' '{"b":2}' > "${UD}/audit-socket.log"
: > "${UD}/audit-chain.log"
run_verify "$UD"
assert_rc   "entries with no chain fail"      1
assert_says "and name the reason"             "no chain at all"

# A path that does not exist is not an empty trail. Reporting it as one
# would mean a typo in --log, or a volume that failed to mount, reads
# back as a clean bill of health -- the one answer this tool must never
# give when it has checked nothing.
run_verify "${WORK}/no-such-trail-dir"
assert_rc "a missing log is an error, not an empty trail" 2

# ---------------------------------------------------------------------------
printf '\n=== An altered entry is caught, and located ===\n'
# ---------------------------------------------------------------------------
D="$(trail altered 5)"
sed -i '3s/.*/{"seq":3,"type":"request","path":"secret\/data\/HARMLESS"}/' "${D}/audit-socket.log"
run_verify "$D"
assert_rc   "an altered entry fails verification" 1
assert_says "and the divergence is located"       "diverges at entry 3"
assert_says "and it is described as an alteration" "altered or replaced"

# ---------------------------------------------------------------------------
printf '\n=== A removed entry is caught ===\n'
# ---------------------------------------------------------------------------
# Deleting the record of what you did is the whole threat. The link at
# that position is now over a different history, and the chain still
# carries a link for the entry that is gone.
D="$(trail removed 5)"
sed -i '2d' "${D}/audit-socket.log"
run_verify "$D"
assert_rc   "a removed entry fails verification" 1
assert_says "and the chain has an orphaned link" "no entry behind them"

# ---------------------------------------------------------------------------
printf '\n=== An inserted entry is caught ===\n'
# ---------------------------------------------------------------------------
# The mirror of removal, and the more interesting direction: forging a
# request that never happened, rather than hiding one that did. The
# inserted line hashes fine on its own -- what gives it away is that
# every link after it now covers a history that does not match.
D="$(trail inserted 5)"
sed -i '3i {"seq":999,"type":"request","path":"secret/data/never-happened"}' \
    "${D}/audit-socket.log"
run_verify "$D"
assert_rc   "an inserted entry fails verification" 1
assert_says "and the divergence is located"        "diverges at entry 3"

# ---------------------------------------------------------------------------
printf '
=== A half-repaired forgery is caught by the link, not the hash ===
'
# ---------------------------------------------------------------------------
# verify-audit-chain.sh has two distinct comparisons per entry: the entry
# still hashes to what was recorded, and the link still covers the right
# history. Every case above trips the first one, because inserting or
# removing a line shifts every later position and the hashes stop lining
# up immediately.
#
# This is the case that needs the second. The attacker edits an entry and
# also repairs its recorded entry hash -- so that comparison passes -- but
# does not recompute the links that follow. Without this test the link
# comparison could be deleted outright and the suite would stay green,
# which is exactly what a mutation run showed.
D="$(trail halfrepaired 4)"
sed -i '2s/.*/{"seq":2,"type":"request","path":"secret\/data\/rewritten"}/'     "${D}/audit-socket.log"
NEW_EH="$(sed -n 2p "${D}/audit-socket.log" | sha256sum | cut -d' ' -f1)"
OLD_LINK="$(cut -d' ' -f3 <<< "$(sed -n 2p "${D}/audit-chain.log")")"
sed -i "2s/.*/2 ${NEW_EH} ${OLD_LINK}/" "${D}/audit-chain.log"
run_verify "$D"
assert_rc   "a repaired entry hash does not save the forgery" 1
assert_says "and the broken link is what reports it"          "its link is wrong"

# ---------------------------------------------------------------------------
printf '\n=== Entries appended by hand are caught ===\n'
# ---------------------------------------------------------------------------
D="$(trail appended 5)"
printf '%s\n' '{"seq":99,"type":"request","path":"secret/data/planted"}' \
    >> "${D}/audit-socket.log"
run_verify "$D"
assert_rc   "an unchained tail fails verification" 1
assert_says "and says the tail was never chained"  "not chained"

# ---------------------------------------------------------------------------
printf '\n=== A rewritten chain: why anchors exist ===\n'
# ---------------------------------------------------------------------------
# The case the whole anchor service is for. An attacker with write access
# to the volume removes the entry recording what they did and recomputes
# every hash after it. The trail is now internally consistent.
D="$(trail rewritten 5)"

# Anchor the real head first -- this is the copy they cannot reach.
HEAD="$(tail -n 1 "${D}/audit-chain.log")"
A_SEQ="$(cut -d' ' -f1 <<< "$HEAD")"
A_HASH="$(cut -d' ' -f3 <<< "$HEAD")"
printf '%s %s %s\n' "2026-01-01T00:00:00Z" "$A_SEQ" "$A_HASH" > "${D}/audit-anchors.log"

sed -i '2d' "${D}/audit-socket.log"
rechain "$D"

# First half: it passes everything that reads only the log and the chain.
# If this assertion ever fails, chaining alone became sufficient and the
# reasoning in anchor.sh needs revisiting -- it did not simply "break".
run_verify_no_anchors "$D"
assert_rc    "a rewritten chain passes without anchors" 0
assert_says  "and claims the chain is intact"           "chain intact"

# Second half: the anchor remembers a head that no longer exists.
run_verify "$D"
assert_rc   "the anchor catches the rewrite"   1
assert_says "and says the trail was truncated" "truncated"

# ---------------------------------------------------------------------------
printf '\n=== An anchor that agrees says so ===\n'
# ---------------------------------------------------------------------------
D="$(trail anchored 4)"
HEAD="$(sed -n 3p "${D}/audit-chain.log")"
printf '%s %s %s\n' "2026-01-01T00:00:00Z" \
    "$(cut -d' ' -f1 <<< "$HEAD")" "$(cut -d' ' -f3 <<< "$HEAD")" \
    > "${D}/audit-anchors.log"
run_verify "$D"
assert_rc   "an intact anchored trail verifies" 0
assert_says "and the anchor is reported"        "anchor(s) agree"

# Without anchors it must say so rather than implying it checked.
D="$(trail unanchored 3)"
run_verify "$D"
assert_rc    "a trail with no anchors still verifies" 0
assert_says  "but says the anchors are missing"       "no anchors available"
assert_lacks "and does not claim to be anchored"      "and anchored"

# ---------------------------------------------------------------------------
printf '\n=== The anchor service records the head as it moves ===\n'
# ---------------------------------------------------------------------------
AD="${WORK}/anchorsvc"; mkdir -p "$AD" "${AD}/anchors"
cp "$(trail forsvc 3)/audit-chain.log" "${AD}/audit-chain.log"
COLLECT_DIR="$AD" ANCHOR_DIR="${AD}/anchors" ANCHOR_INTERVAL=1 \
    sh "$ANCHOR" >/dev/null 2>&1 &
ANCHOR_PID=$!
sleep 3
ANCHORED="$(wc -l < "${AD}/anchors/audit-anchors.log" 2>/dev/null || echo 0)"
if [[ "$ANCHORED" == "1" ]]; then
    ok "the head is anchored once while it has not moved"
else
    bad "the head is anchored once while it has not moved" "got ${ANCHORED} anchors"
fi

# It must record the real head, not merely something.
SVC_HEAD="$(tail -n 1 "${AD}/audit-chain.log")"
SVC_ANCHOR="$(tail -n 1 "${AD}/anchors/audit-anchors.log" 2>/dev/null || true)"
if [[ "$(cut -d' ' -f3 <<< "$SVC_HEAD")" == "$(awk '{print $3}' <<< "$SVC_ANCHOR")" ]]; then
    ok "and it is the chain's actual head"
else
    bad "and it is the chain's actual head" "chain: ${SVC_HEAD} anchor: ${SVC_ANCHOR}"
fi

# When the head moves, a new anchor follows it.
printf '%s\n' '4 aaaa bbbb' >> "${AD}/audit-chain.log"
sleep 3
kill "$ANCHOR_PID" 2>/dev/null || true
wait "$ANCHOR_PID" 2>/dev/null || true
ANCHORED2="$(wc -l < "${AD}/anchors/audit-anchors.log" 2>/dev/null || echo 0)"
if [[ "$ANCHORED2" == "2" ]]; then
    ok "a moved head produces a second anchor"
else
    bad "a moved head produces a second anchor" "got ${ANCHORED2}"
fi

# ---------------------------------------------------------------------------
printf '\n=== Results ===\n'
# ---------------------------------------------------------------------------
printf 'passed: %d\nfailed: %d\n' "$PASS" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then red "FAILED"; exit 1; fi
green "All ${PASS} assertions passed."

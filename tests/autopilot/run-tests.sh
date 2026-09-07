#!/usr/bin/env bash
#
# run-tests.sh — scripts/configure-autopilot.sh, against a fake vault CLI
#
# Usage:
#   ./tests/autopilot/run-tests.sh
#
# Seconds. No cluster, no credentials.
#
# WHAT THIS COVERS
#
# The script exists because Vault ships autopilot with
# cleanup_dead_servers = false, so a replaced node stays a voter forever
# and an ASG instance refresh walks a three-node cluster out of quorum
# partway through the second node. The reasoning is in the script header
# and in docs/rolling-upgrades.md.
#
# What is checked here is what the script *does*: that it counts voters
# rather than assuming three, that it refuses a cluster too small for the
# floor to mean anything, that --no-cleanup is honoured and announced, and
# that a set-config which reports success without taking is caught by the
# read-back rather than reported as done.
#
# What is NOT checked here is whether Vault then behaves that way. That
# needs a cluster: tests/integration asserts the live configuration, and
# whether an ASG refresh keeps quorum needs an apply nobody has done.
#
# Requirements: bash, jq

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SCRIPT="${REPO_ROOT}/scripts/configure-autopilot.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

green() { printf '\033[32m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*"; }
info()  { printf '\033[36m%s\033[0m\n' "$*"; }

ok()  { PASS=$((PASS + 1)); green "  PASS  $1"; }
bad() { FAIL=$((FAIL + 1)); red   "  FAIL  $1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; return 0; }

export PATH="${SCRIPT_DIR}/fake-bin:${PATH}"

# Every FAKE_* re-exported between cases, so one test cannot quietly
# satisfy the next. They are exported because the shims are grandchildren
# of this shell.
reset_scenario() {
    FAKE_LOG="${WORK}/calls.log"; : > "$FAKE_LOG"
    FAKE_STATE="${WORK}/state"; rm -f "$FAKE_STATE"
    FAKE_CLEANUP="false"
    FAKE_MIN_QUORUM="0"
    FAKE_THRESHOLD="24h0m0s"
    FAKE_VOTERS="3"
    FAKE_NONVOTERS="0"
    FAKE_SET_TAKES="true"
    FAKE_GET_CONFIG_RC="0"
    FAKE_SET_CONFIG_RC="0"
    FAKE_LIST_PEERS_RC="0"
    export FAKE_LOG FAKE_STATE FAKE_CLEANUP FAKE_MIN_QUORUM FAKE_THRESHOLD \
           FAKE_VOTERS FAKE_NONVOTERS FAKE_SET_TAKES FAKE_GET_CONFIG_RC \
           FAKE_SET_CONFIG_RC FAKE_LIST_PEERS_RC
    export VAULT_ADDR="https://127.0.0.1:8200"
    export VAULT_TOKEN="fake-token"
}

run_script() {
    OUT="$("$SCRIPT" "$@" 2>&1)"
    RC=$?
    return 0
}

assert_rc() {
    local want="$1" what="$2"
    if [[ "$RC" == "$want" ]]; then ok "$what"; else bad "$what" "exit was ${RC}, wanted ${want}: $(tail -2 <<< "$OUT")"; fi
}

assert_says() {
    local needle="$1" what="$2"
    if grep -q -- "$needle" <<< "$OUT"; then ok "$what"; else bad "$what" "output did not contain '${needle}'"; fi
}

assert_log_has() {
    local needle="$1" what="$2"
    if grep -q -- "$needle" "$FAKE_LOG"; then ok "$what"; else bad "$what" "no call matching '${needle}' in: $(tr '\n' '|' < "$FAKE_LOG")"; fi
}

assert_log_lacks() {
    local needle="$1" what="$2"
    if grep -q -- "$needle" "$FAKE_LOG"; then bad "$what" "found '${needle}' in: $(tr '\n' '|' < "$FAKE_LOG")"; else ok "$what"; fi
}

# ---------------------------------------------------------------------------
info ""
info "=== The defaults it writes ==="
# ---------------------------------------------------------------------------
reset_scenario
run_script
assert_rc 0 "a healthy three-voter cluster is configured"
assert_log_has "cleanup-dead-servers=true" "cleanup_dead_servers is turned on"
assert_log_has "min-quorum=3" "min_quorum is the number of voters it counted"
assert_log_has "dead-server-last-contact-threshold=5m" "the dead-server threshold is shortened from Vault's 24h"

# The floor is the safety property, so it is worth stating that the script
# reports the value it ended up with rather than the value it asked for.
assert_says "min_quorum=3" "it reports the configuration it read back"

# ---------------------------------------------------------------------------
info ""
info "=== It counts voters rather than assuming three ==="
# ---------------------------------------------------------------------------
reset_scenario
FAKE_VOTERS="5"; export FAKE_VOTERS
run_script
assert_rc 0 "a five-voter cluster is configured"
assert_log_has "min-quorum=5" "min_quorum follows the cluster, not a hardcoded 3"

# A node that has joined but not yet been promoted must not raise the
# floor: min_quorum is about voters, and counting a non-voter would block
# pruning until a node that cannot vote becomes one.
reset_scenario
FAKE_VOTERS="3"; FAKE_NONVOTERS="2"; export FAKE_VOTERS FAKE_NONVOTERS
run_script
assert_log_has "min-quorum=3" "non-voters are not counted toward the floor"

# ---------------------------------------------------------------------------
info ""
info "=== It refuses a cluster too small for the floor to mean anything ==="
# ---------------------------------------------------------------------------
# Two voters is not a quorum worth protecting -- either one going takes the
# cluster down, and no pruning policy changes that. Writing min_quorum=2
# would look like a safety property and not be one.
reset_scenario
FAKE_VOTERS="2"; export FAKE_VOTERS
run_script
assert_rc 1 "a two-voter cluster is refused"
assert_says "not a quorum worth protecting" "and says why rather than just failing"
assert_log_lacks "set-config" "nothing was written to a cluster it refused"

# Explicitly asking for it is allowed -- the operator may know something
# the script does not.
reset_scenario
FAKE_VOTERS="2"; export FAKE_VOTERS
run_script --min-quorum 3
assert_rc 0 "an explicit --min-quorum overrides the count"
assert_log_has "min-quorum=3" "and the explicit value is what gets written"

# ---------------------------------------------------------------------------
info ""
info "=== A write that reports success and does not take ==="
# ---------------------------------------------------------------------------
# The failure this repository is arranged around. set-config exits 0, the
# cluster still has the old values, and without a read-back the script
# would report a configured cluster that is not configured.
reset_scenario
FAKE_SET_TAKES="false"; export FAKE_SET_TAKES
run_script
assert_rc 1 "a set-config that does not take is caught"
assert_says "cleanup_dead_servers is false after writing true" "and names the field that did not change"

# ---------------------------------------------------------------------------
info ""
info "=== Turning it off is allowed, and says what it costs ==="
# ---------------------------------------------------------------------------
reset_scenario
run_script --no-cleanup
assert_rc 0 "--no-cleanup is accepted"
assert_log_has "cleanup-dead-servers=false" "and writes false"
assert_says "loses quorum during an instance refresh" "and warns what that means on the cloud profiles"

# ---------------------------------------------------------------------------
info ""
info "=== It configures; it does not remove anything itself ==="
# ---------------------------------------------------------------------------
# remove-peer is the destructive neighbour of this operation and a
# plausible thing for a future edit to reach for. Pinned as an exclusion,
# paired with the positive above so a renamed subcommand cannot satisfy
# both.
reset_scenario
run_script
assert_log_lacks "remove-peer" "no peer is removed by hand"
assert_log_has "autopilot set-config" "the change is made through autopilot"

# ---------------------------------------------------------------------------
info ""
info "=== Failure modes report rather than pretend ==="
# ---------------------------------------------------------------------------
reset_scenario
FAKE_GET_CONFIG_RC="2"; export FAKE_GET_CONFIG_RC
run_script
assert_rc 1 "a backend without autopilot fails"
assert_says "Raft (integrated storage) cluster" "and says what kind of cluster this needs"

reset_scenario
FAKE_SET_CONFIG_RC="2"; export FAKE_SET_CONFIG_RC
run_script
assert_rc 1 "a rejected write fails"

reset_scenario
unset VAULT_TOKEN
run_script
assert_rc 1 "a missing token fails before anything is written"
assert_log_lacks "set-config" "and writes nothing"

# ---------------------------------------------------------------------------
printf '\n=== Results ===\n'
# ---------------------------------------------------------------------------
printf 'passed: %d\nfailed: %d\n' "$PASS" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then red "FAILED"; exit 1; fi
green "All ${PASS} assertions passed."

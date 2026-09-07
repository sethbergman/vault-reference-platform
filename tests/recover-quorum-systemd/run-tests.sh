#!/usr/bin/env bash
#
# run-tests.sh — recover-quorum.sh's real-node path, against fake tools
#
# Usage:
#   ./tests/recover-quorum-systemd/run-tests.sh
#
# Seconds. No cluster, no credentials, nothing stopped.
#
# WHY THIS EXISTS
#
# tests/quorum-recovery runs the compose path against a real cluster. The
# --service-name path -- the one an operator uses on an actual node, with
# systemctl and a data directory on disk -- had no test at all. It was
# written from Vault's documented procedure and shipped as "reviewed, not
# proven", which is honest and is not the same as covered.
#
# A real node is not available here, so this is the shim tier: it proves
# the script issues the commands you expect, in the order you expect, and
# nothing more. What it cannot show is that Vault then does the right
# thing with peers.json -- that is tests/quorum-recovery's job, on the
# other path.
#
# WHAT IT CHECKS, AND WHY THE ORDER MATTERS MOST
#
# Every refusal in this script has to happen before `systemctl stop`. A
# guard that refuses after stopping Vault has not prevented anything; it
# has taken the node down and then declined to fix it, during an outage.
# The compose suite asserts that for its path. This asserts it for the
# other one, and for the two refusals only reachable here: no systemctl,
# and no raft directory.
#
# Requirements: bash, jq

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SCRIPT="${REPO_ROOT}/scripts/recover-quorum.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

green() { printf '\033[32m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*"; }
info()  { printf '\033[36m%s\033[0m\n' "$*"; }

ok()  { PASS=$((PASS + 1)); green "  PASS  $1"; }
bad() { FAIL=$((FAIL + 1)); red   "  FAIL  $1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; return 0; }

command -v jq >/dev/null 2>&1 || { red "ERROR: jq not found on PATH"; exit 1; }

export PATH="${SCRIPT_DIR}/fake-bin:${PATH}"

# Every FAKE_* re-exported between cases, so one test cannot quietly
# satisfy the next. Exported because the shims are grandchildren of this
# shell -- a `VAR=x run_thing` prefix does not reach them.
reset_scenario() {
    DATA_DIR="${WORK}/data"
    rm -rf "$DATA_DIR"
    mkdir -p "${DATA_DIR}/raft"

    FAKE_LOG="${WORK}/calls.log"; : > "$FAKE_LOG"
    FAKE_QUORUM="lost"
    FAKE_HEALTH_CODE="200"
    FAKE_STOP_RC="0"
    FAKE_START_RC="0"
    export FAKE_LOG FAKE_QUORUM FAKE_HEALTH_CODE FAKE_STOP_RC FAKE_START_RC
    export VAULT_ADDR="https://127.0.0.1:8200"
    export VAULT_TOKEN="fake-token"
}

run_script() {
    OUT="$("$SCRIPT" "$@" 2>&1)"
    RC=$?
    return 0
}

peers_file() { printf '%s/raft/peers.json' "$DATA_DIR"; }

assert_rc() {
    local want="$1" what="$2"
    if [[ "$RC" == "$want" ]]; then ok "$what"; else bad "$what" "exit was ${RC}, wanted ${want}: $(tail -2 <<< "$OUT")"; fi
}

assert_says() {
    local needle="$1" what="$2"
    if grep -q -- "$needle" <<< "$OUT"; then ok "$what"; else bad "$what" "output lacked '${needle}'"; fi
}

assert_log_lacks() {
    local needle="$1" what="$2"
    if grep -q -- "$needle" "$FAKE_LOG"; then bad "$what" "found '${needle}' in: $(tr '\n' '|' < "$FAKE_LOG")"; else ok "$what"; fi
}

# ---------------------------------------------------------------------------
info ""
info "=== The happy path on a real node ==="
# ---------------------------------------------------------------------------
reset_scenario
run_script --peers vault-0=vault-0:8201 --data-dir "$DATA_DIR" --service-name vault
assert_rc 0 "a single-survivor recovery completes"

if [[ -f "$(peers_file)" ]]; then
    ok "peers.json was written into the raft directory"
else
    bad "peers.json was written into the raft directory" "no file at $(peers_file)"
fi

# The mode is the bug that broke this suite's compose sibling on its first
# run: mktemp makes 0600, Vault runs as the vault user, and a peers.json
# it cannot read is indistinguishable from no peers.json at all.
MODE="$(stat -c '%a' "$(peers_file)" 2>/dev/null || echo '?')"
if [[ "$MODE" == "644" ]]; then
    ok "and written 0644, so the vault user can read it"
else
    bad "and written 0644, so the vault user can read it" "mode is ${MODE}"
fi

if jq -e '.[0] | .id == "vault-0" and .address == "vault-0:8201" and .non_voter == false' \
        "$(peers_file)" >/dev/null 2>&1; then
    ok "with the id, address and non_voter Raft expects"
else
    bad "with the id, address and non_voter Raft expects" "$(cat "$(peers_file)")"
fi

# ---------------------------------------------------------------------------
info ""
info "=== Stop, write, start — in that order ==="
# ---------------------------------------------------------------------------
# Asserted as a sequence rather than as three separate presence checks: a
# script that started the service before writing the file would satisfy
# every individual assertion and recover nothing.
SEQ="$(grep -n 'systemctl' "$FAKE_LOG" | sed -e 's/:systemctl /:/' | tr '\n' ' ')"
STOP_LINE="$(grep -n 'systemctl stop' "$FAKE_LOG" | head -1 | cut -d: -f1)"
START_LINE="$(grep -n 'systemctl start' "$FAKE_LOG" | head -1 | cut -d: -f1)"
if [[ -n "$STOP_LINE" && -n "$START_LINE" && "$STOP_LINE" -lt "$START_LINE" ]]; then
    ok "the service was stopped before it was started again (${SEQ})"
else
    bad "the service was stopped before it was started again" "calls: ${SEQ}"
fi

# ---------------------------------------------------------------------------
info ""
info "=== Every survivor is named, not just the one you are on ==="
# ---------------------------------------------------------------------------
# Recovering a five-node cluster that lost two means listing the three
# that are left. Listing one discards two healthy nodes' votes.
reset_scenario
run_script --peers vault-0=vault-0:8201,vault-3=vault-3:8201,vault-4=vault-4:8201 \
    --data-dir "$DATA_DIR" --service-name vault
assert_rc 0 "three survivors are accepted"

if [[ "$(jq -r 'length' "$(peers_file)" 2>/dev/null)" == "3" ]]; then
    ok "and all three reach peers.json"
else
    bad "and all three reach peers.json" "$(cat "$(peers_file)" 2>/dev/null)"
fi

if jq -e 'all(.non_voter == false)' "$(peers_file)" >/dev/null 2>&1; then
    ok "each as a voter — a recovery of non-voters has nobody to elect"
else
    bad "each as a voter — a recovery of non-voters has nobody to elect"
fi

# ---------------------------------------------------------------------------
info ""
info "=== Refusals, and none of them touch the service ==="
# ---------------------------------------------------------------------------
# A guard that refuses after stopping Vault has not prevented anything.
reset_scenario
FAKE_QUORUM="intact"; export FAKE_QUORUM
run_script --peers vault-0=vault-0:8201 --data-dir "$DATA_DIR" --service-name vault
assert_rc 1 "a cluster that still answers a Raft query is refused"
assert_says "still answers a Raft configuration query" "and says why"
assert_log_lacks "systemctl" "and the service was never touched"

reset_scenario
run_script --peers vault-0=vault-0:8201 --data-dir "${WORK}/nonexistent" --service-name vault
assert_rc 1 "a data directory with no raft/ is refused"
assert_says "no raft directory" "and names the directory it wanted"
assert_log_lacks "systemctl" "and the service was never touched"

reset_scenario
unset VAULT_TOKEN
run_script --peers vault-0=vault-0:8201 --data-dir "$DATA_DIR" --service-name vault
assert_rc 1 "a missing VAULT_TOKEN is refused rather than warned about"
assert_says "cannot check whether this cluster still has quorum" "and says what it could not check"
assert_log_lacks "systemctl" "and the service was never touched"

reset_scenario
unset VAULT_ADDR
run_script --peers vault-0=vault-0:8201 --data-dir "$DATA_DIR" --service-name vault
assert_rc 1 "no way to verify the outcome is refused"
assert_log_lacks "systemctl" "and the service was never touched"

# ---------------------------------------------------------------------------
info ""
info "=== Failures are reported, not stepped over ==="
# ---------------------------------------------------------------------------
reset_scenario
FAKE_STOP_RC="1"; export FAKE_STOP_RC
run_script --peers vault-0=vault-0:8201 --data-dir "$DATA_DIR" --service-name vault
assert_rc 1 "a stop that fails aborts"
if [[ -f "$(peers_file)" ]]; then
    bad "and peers.json is not written to a node still running" \
        "the file was written while Vault was up, and Raft would consume it on the next restart nobody planned"
else
    ok "and peers.json is not written to a node still running"
fi

reset_scenario
FAKE_START_RC="1"; export FAKE_START_RC
run_script --peers vault-0=vault-0:8201 --data-dir "$DATA_DIR" --service-name vault
assert_rc 1 "a start that fails aborts"

# The one that matters most: the node never comes back. Reporting success
# here would be the quiet failure this script exists to avoid -- an
# operator told the recovery worked, mid-outage, when it did not.
reset_scenario
FAKE_HEALTH_CODE="429"; export FAKE_HEALTH_CODE
run_script --peers vault-0=vault-0:8201 --data-dir "$DATA_DIR" --service-name vault --wait 6
assert_rc 1 "a node that comes back a standby is a failure, not a success"
assert_says "did not become active" "and says so rather than reporting a recovery"

# ---------------------------------------------------------------------------
printf '\n=== Results ===\n'
# ---------------------------------------------------------------------------
printf 'passed: %d\nfailed: %d\n' "$PASS" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then red "FAILED"; exit 1; fi
green "All ${PASS} assertions passed."

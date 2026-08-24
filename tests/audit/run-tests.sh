#!/usr/bin/env bash
#
# run-tests.sh — Tests for audit device bootstrap
#
# Usage:
#   ./tests/audit/run-tests.sh
#
# Runs in about a second. No Vault, no cluster.
#
# Covers the script's decisions: that two devices are enabled by default,
# that --no-second says plainly what it costs, and that --force cannot be
# used to disable the only device Vault has.
#
# Whether the audit log is any good — whether requests appear in it, and
# whether secrets are hashed rather than written out — needs a real Vault
# and lives in tests/integration.
#
# Requirements: bash, jq, python3

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
BOOTSTRAP="${REPO_ROOT}/scripts/bootstrap-audit.sh"
FAKE_BIN="${SCRIPT_DIR}/fake-bin"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

green() { printf '\033[32m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*"; }

ok()  { PASS=$((PASS + 1)); green "  PASS  $1"; }
bad() { FAIL=$((FAIL + 1)); red   "  FAIL  $1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; return 0; }

RC=0
OUT=""
LOG=""

reset_scenario() {
    export FAKE_DEVICES=""
    export FAKE_ENABLE_RC=0
    export FAKE_DISABLE_RC=0
    export FAKE_ENABLE_SILENT_NOOP=false
    export FAKE_COLLECTOR_UP=true
    export VAULT_ADDR=https://127.0.0.1:8200
    export VAULT_TOKEN=s.testtoken
}

run_bootstrap() {
    local logfile="${WORK}/calls.log"
    : > "$logfile"
    # Fresh device state per run, seeded from FAKE_DEVICES.
    rm -f "${logfile}.devices"
    RC=0
    OUT="$(FAKE_LOG="$logfile" PATH="${FAKE_BIN}:${PATH}" "$BOOTSTRAP" "$@" 2>&1)" || RC=$?
    LOG="$(cat "$logfile")"
}

assert_rc()        { if [[ "$RC" == "$2" ]]; then ok "$1"; else bad "$1" "expected ${2}, got ${RC}: ${OUT}"; fi; }
assert_says()      { if [[ "$OUT" == *"$2"* ]]; then ok "$1"; else bad "$1" "output lacked: ${2}"; fi; }
assert_log_has()   { if [[ "$LOG" == *"$2"* ]]; then ok "$1"; else bad "$1" "no call matching: ${2}"; fi; }
assert_log_lacks() { if [[ "$LOG" != *"$2"* ]]; then ok "$1"; else bad "$1" "unexpected call: ${2}"; fi; }

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
for dep in jq python3; do
    command -v "$dep" >/dev/null 2>&1 || { red "ERROR: ${dep} not found on PATH"; exit 1; }
done
[[ -x "$BOOTSTRAP" ]] || { red "ERROR: ${BOOTSTRAP} is not executable"; exit 1; }

if PATH="${FAKE_BIN}:${PATH}" command -v vault | grep -q "fake-bin"; then
    ok "the vault shim shadows any real vault on PATH"
else
    red "ERROR: fake-bin is not being resolved first"; exit 1
fi

# ---------------------------------------------------------------------------
printf '\n=== Argument handling ===\n'
# ---------------------------------------------------------------------------
reset_scenario
run_bootstrap --wat
assert_says "rejects unknown arguments" "Unknown argument"

reset_scenario
RC=0; OUT="$(PATH="${FAKE_BIN}:${PATH}" VAULT_ADDR='' VAULT_TOKEN=t "$BOOTSTRAP" 2>&1)" || RC=$?
if [[ $RC -ne 0 && "$OUT" == *"VAULT_ADDR"* ]]; then
    ok "requires VAULT_ADDR"
else
    bad "requires VAULT_ADDR" "got ${RC}: ${OUT}"
fi

# ---------------------------------------------------------------------------
printf '\n=== Two devices by default ===\n'
# ---------------------------------------------------------------------------
# Vault refuses to service requests when it cannot write to ANY enabled
# device. One device therefore turns a full disk into a total outage, so
# the default has to be two.
reset_scenario
export FAKE_DEVICES=""
run_bootstrap
assert_rc      "enables devices on a fresh cluster" 0
assert_log_has "enables a primary device"   "audit enable -path=file file"
assert_log_has "enables a secondary device" "audit enable -path=file-secondary file"

# Never log_raw. It replaces the HMAC digests with the secrets
# themselves, which turns the audit log into a copy of Vault.
assert_log_lacks "never sets log_raw" "log_raw"

# Restrictive by default: the log records who touched what, and is not
# something every user on the host should read.
assert_log_has "the log is mode 0600" "mode=0600"

# ---------------------------------------------------------------------------
printf '\n=== --no-second states what it costs ===\n'
# ---------------------------------------------------------------------------
reset_scenario
run_bootstrap --no-second
assert_rc        "runs with a single device"      0
assert_log_has   "enables the primary"            "audit enable -path=file file"
assert_log_lacks "and not the secondary"          "file-secondary"
# An option that quietly makes an outage more likely should say so.
assert_says      "warns that one device is a single point of failure" "total outage"

# ---------------------------------------------------------------------------
printf '\n=== A socket secondary is a separate failure domain ===\n'
# ---------------------------------------------------------------------------
# Two files on one filesystem are one failure domain wearing two hats:
# the same disk fills for both, so the redundancy is nominal. A socket
# device fails when the network or the collector does, which is the point
# of having a second one at all.
reset_scenario
run_bootstrap --second-type socket --second-address collector:9090
assert_rc      "socket secondary is accepted"       0
assert_log_has "the secondary is a socket device"   "audit enable -path=file-secondary socket"
assert_log_has "pointed at the given address"       "address=collector:9090"
assert_log_has "over tcp"                           "socket_type=tcp"

# The primary stays a file on purpose. A socket device alone can block
# Vault when its endpoint goes away; paired with a file device it cannot,
# because the file keeps satisfying the at-least-one guarantee.
assert_log_has "the primary is still a file device" "audit enable -path=file file"

# An unreachable collector must fail at enable time. Later means every
# request blocked until someone works out why.
reset_scenario
export FAKE_COLLECTOR_UP=false
run_bootstrap --second-type socket --second-address collector:9090
assert_rc   "an unreachable collector aborts at enable time" 1
assert_says "and points at the collector"                    "is the collector listening"

reset_scenario
run_bootstrap --second-type socket
assert_rc   "socket without an address is refused" 1
assert_says "and says what is missing"             "--second-address"

reset_scenario
run_bootstrap --second-type carrier-pigeon
assert_rc   "an unknown secondary type is refused" 1
assert_says "and lists the valid ones"             "must be file or socket"

# Two files remains the default because it works with nothing else
# running — but it should say what it is not giving you.
reset_scenario
run_bootstrap
assert_says "the file default notes the shared failure domain" "share a failure domain"

# ---------------------------------------------------------------------------
printf '\n=== Existing devices are left alone ===\n'
# ---------------------------------------------------------------------------
# Re-enabling means disabling first, and disabling the only device leaves
# Vault unaudited for that window. Idempotent by default.
reset_scenario
export FAKE_DEVICES="file,file-secondary"
run_bootstrap
assert_rc        "a configured cluster is a no-op" 0
assert_log_lacks "nothing is disabled"             "audit disable"
assert_log_lacks "nothing is re-enabled"           "audit enable"
assert_says      "and it says so"                  "already enabled"

# ---------------------------------------------------------------------------
printf '\n=== --force will not leave Vault unaudited ===\n'
# ---------------------------------------------------------------------------
# The dangerous case: --force on a cluster with exactly one device.
# Disabling it to re-enable it opens a window where requests are served
# with no audit trail at all. Refuse rather than warn.
reset_scenario
export FAKE_DEVICES="file"
run_bootstrap --force --no-second
assert_rc        "--force on the only device is refused" 1
assert_log_lacks "and nothing is disabled"               "audit disable"
assert_says      "and it explains why"                   "unaudited"

# With a second device present the window is covered, so --force is fine.
reset_scenario
export FAKE_DEVICES="file,file-secondary"
run_bootstrap --force
assert_rc      "--force is allowed when another device remains" 0
assert_log_has "and it does re-enable"                          "audit disable"

# ---------------------------------------------------------------------------
printf '\n=== Failures are not silent ===\n'
# ---------------------------------------------------------------------------
# Vault writes a test entry when a device is enabled, so an unwritable
# path fails immediately rather than blocking every later request.
reset_scenario
run_bootstrap --file-path /nonexistent/dir/audit.log
assert_rc   "an unwritable path aborts"       1
assert_says "and points at the likely cause"  "writable by the vault user"

reset_scenario
export FAKE_ENABLE_RC=2
run_bootstrap
assert_rc "a refused enable aborts" 1

# The nastiest shape: every enable returns success and no device is there
# afterwards. Reporting success would leave a cluster that looks audited
# and is not — worse than a visible failure, because nobody goes back to
# check something that said it worked.
reset_scenario
export FAKE_ENABLE_SILENT_NOOP=true
run_bootstrap
assert_rc   "enables that succeed without enabling anything abort" 1
assert_says "and it refuses to claim success"                      "refusing to report success"

# ---------------------------------------------------------------------------
printf '\n=== --list ===\n'
# ---------------------------------------------------------------------------
reset_scenario
export FAKE_DEVICES="file,file-secondary"
run_bootstrap --list
assert_rc        "--list succeeds"        0
assert_log_has   "and lists devices"      "audit list"
assert_log_lacks "and changes nothing"    "audit enable"

# ---------------------------------------------------------------------------
printf '\n=== Results ===\n'
# ---------------------------------------------------------------------------
printf 'passed: %d\nfailed: %d\n' "$PASS" "$FAIL"
if [[ $FAIL -gt 0 ]]; then
    red "FAILED"
    exit 1
fi
green "All ${PASS} assertions passed."

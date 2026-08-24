#!/usr/bin/env bash
#
# run-tests.sh — Exercise scripts/vault-upgrade.sh
#
# Usage:
#   ./tests/upgrade/run-tests.sh
#
# Two groups of tests, proving different things:
#
#   Artifact handling — the checksum path accepts a good archive and
#   refuses a bad one. That refusal is a genuine security control: without
#   it the script installs whatever it downloaded onto every node in the
#   cluster, and nothing else in the pipeline would notice. Runs against a
#   locally built archive rather than a real 150MB release — see the
#   comment above the fixture for why.
#
#   Rolling sequencing — runs against ssh/scp shims (tests/upgrade/
#   fake-bin). vault-upgrade.sh drives hosts over SSH and systemd, which
#   the container-based local profile does not have, so this is the only
#   way to exercise the ordering. It proves the leader is stepped down
#   before being touched, that nodes go strictly one at a time, and that
#   an unhealthy node aborts the run rather than continuing into the next
#   node and taking out quorum.
#
#   What it does not prove: that systemd restarts Vault, that scp lands
#   the binary correctly, or that a real node rejoins. Only a real upgrade
#   against real hosts shows that.
#
# Requirements: bash, curl, unzip, jq, sha256sum, python3

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
UPGRADE_SH="${REPO_ROOT}/scripts/vault-upgrade.sh"
FAKE_BIN="${SCRIPT_DIR}/fake-bin"

VAULT_VERSION="1.17.2"
ARCHIVE="vault_${VAULT_VERSION}_linux_amd64.zip"

WORKDIR="$(mktemp -d)"
PASSED=0
FAILED=0

HTTP_PID=""
cleanup() {
    [[ -n "$HTTP_PID" ]] && kill "$HTTP_PID" 2>/dev/null
    rm -rf "$WORKDIR"
}
trap cleanup EXIT

log()  { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }

pass() { PASSED=$((PASSED + 1)); echo "  PASS  $1"; }
fail() { FAILED=$((FAILED + 1)); echo "  FAIL  $1"; [[ -n "${2:-}" ]] && echo "        $2"; }

# Several assertions below are of the form "X did NOT happen", which grep
# reports happily when the log file doesn't exist at all — i.e. when the
# script died before contacting a single node. That would turn a total
# failure into a row of passes, so require the log to exist first.
require_log() {
    local logfile="$1" what="$2"
    if [[ ! -f "$logfile" ]]; then
        fail "$what" "no command log — the script exited before contacting any node"
        return 1
    fi
    return 0
}

# Check dependencies up front rather than letting a missing one quietly
# change what is being tested. vault-upgrade.sh decides whether a node is
# the leader with `... | jq -e '.is_self == true'`; with no jq on PATH
# that pipeline just fails, is_leader() returns false, and no node is ever
# stepped down. One assertion correctly fails, but "a standby is not
# stepped down" passes for the wrong reason — nothing was stepped down at
# all. A silently degraded test run is worse than one that refuses to
# start.
missing=()
for dep in curl unzip jq sha256sum python3; do
    command -v "$dep" >/dev/null 2>&1 || missing+=("$dep")
done
if [[ ${#missing[@]} -gt 0 ]]; then
    echo "Missing required tools: ${missing[*]}" >&2
    echo "These tests would otherwise pass for the wrong reasons." >&2
    exit 1
fi

# Run vault-upgrade.sh with the shims ahead of the real ssh/scp.
#
# The FAKE_SSH_* variables are forwarded explicitly. Callers set them as
# `FAKE_SSH_UNHEALTHY=node-a run_upgrade ...`, and that prefix form only
# sets a shell variable for the duration of a *function* — it does not
# export it, so the `bash "$UPGRADE_SH"` child never saw it. The scenario
# silently didn't apply: every node reported healthy, the rollout
# completed, and the tests that exist to prove the abort path works
# passed for the wrong reason.
run_upgrade() {
    local logfile="$1"; shift
    FAKE_SSH_LOG="$logfile" \
    FAKE_SSH_LEADER="${FAKE_SSH_LEADER:-}" \
    FAKE_SSH_UNHEALTHY="${FAKE_SSH_UNHEALTHY:-}" \
    FAKE_SSH_FAIL_STOP="${FAKE_SSH_FAIL_STOP:-}" \
    PATH="${FAKE_BIN}:${PATH}" \
        bash "$UPGRADE_SH" "$@" >"${logfile}.out" 2>&1
}

# ---------------------------------------------------------------------------
# Build the test artifact locally
# ---------------------------------------------------------------------------
# Deliberately NOT downloading a real Vault release. The script's artifact
# handling cares about three things — that the download is a zip, that its
# checksum matches, and that a file named "vault" is inside — and a
# synthetic archive exercises all three identically.
#
# The real release is ~150MB and took nearly four minutes to fetch. Paying
# that on every CI run, and once per mutation when checking these tests
# actually fail, is a lot of wall-clock for no extra coverage.
log "Building a synthetic release archive..."
mkdir -p "${WORKDIR}/stage"
cat > "${WORKDIR}/stage/vault" <<'FAKE_VAULT'
#!/usr/bin/env bash
# Stands in for the Vault binary. vault-upgrade.sh only runs `vault
# version` against the staged binary, and tolerates that failing.
echo "Vault v1.17.2 (synthetic test artifact)"
FAKE_VAULT
chmod +x "${WORKDIR}/stage/vault"

# Built with python's zipfile rather than the zip(1) binary, which is not
# present on every developer machine — python3 is already required here.
# Passed with -c rather than a heredoc: nesting a heredoc inside this
# script crashes under Git Bash's fork emulation.
python3 -c 'import sys,zipfile
src,dest=sys.argv[1],sys.argv[2]
z=zipfile.ZipFile(dest,"w",zipfile.ZIP_DEFLATED)
i=zipfile.ZipInfo("vault")
i.external_attr=0o755<<16
z.writestr(i,open(src,"rb").read())
z.close()' "${WORKDIR}/stage/vault" "${WORKDIR}/${ARCHIVE}"

[[ -s "${WORKDIR}/${ARCHIVE}" ]] || { echo "Could not build the test archive"; exit 1; }

REAL_SHA="$(sha256sum "${WORKDIR}/${ARCHIVE}" | awk '{print $1}')"
log "Archive checksum: ${REAL_SHA}"

# The script fetches over HTTP, so serve the fixture locally. Not file://
# — that resolves differently on Windows shells, and a test that only runs
# on Linux is one nobody runs before pushing.
PORT=0
for candidate in $(seq 18080 18120); do
    if ! curl -fsS -o /dev/null --max-time 1 "http://127.0.0.1:${candidate}/" 2>/dev/null; then
        PORT="$candidate"
        break
    fi
done
[[ "$PORT" != "0" ]] || { echo "No free port for the local file server"; exit 1; }

python3 -m http.server "$PORT" --directory "$WORKDIR" --bind 127.0.0.1 >/dev/null 2>&1 &
HTTP_PID=$!

for _ in $(seq 1 20); do
    curl -fsS -o /dev/null "http://127.0.0.1:${PORT}/${ARCHIVE}" 2>/dev/null && break
    sleep 0.5
done
curl -fsS -o /dev/null "http://127.0.0.1:${PORT}/${ARCHIVE}"     || { echo "Local file server never came up on ${PORT}"; exit 1; }

FILE_URL="http://127.0.0.1:${PORT}/${ARCHIVE}"

echo
echo "=== Artifact handling ==="

# ---------------------------------------------------------------------------
if run_upgrade "${WORKDIR}/t1.log" "$FILE_URL" \
    --nodes node-a \
    --sha256 "$REAL_SHA"; then
    pass "correct checksum is accepted and the upgrade proceeds"
else
    fail "correct checksum is accepted and the upgrade proceeds" \
         "$(tail -3 "${WORKDIR}/t1.log.out")"
fi

# ---------------------------------------------------------------------------
# The security-critical case: a checksum that doesn't match must stop the
# run before anything is copied to any node.
BAD_SHA="0000000000000000000000000000000000000000000000000000000000000000"
run_upgrade "${WORKDIR}/t2.log" "$FILE_URL" \
    --nodes node-a,node-b,node-c \
    --sha256 "$BAD_SHA"
rc=$?

if [[ $rc -ne 0 ]] && grep -qi "checksum mismatch" "${WORKDIR}/t2.log.out"; then
    pass "checksum mismatch aborts the run"
else
    fail "checksum mismatch aborts the run" "expected non-zero exit and a mismatch message"
fi

# Refusing to install is only half of it — it must also not have touched
# any node before deciding.
if [[ ! -s "${WORKDIR}/t2.log" ]]; then
    pass "checksum mismatch touches no node at all"
else
    fail "checksum mismatch touches no node at all" \
         "commands were issued: $(head -3 "${WORKDIR}/t2.log")"
fi

# ---------------------------------------------------------------------------
# A file that isn't a zip should be rejected before extraction.
echo "this is not a zip archive" > "${WORKDIR}/not-a-zip.bin"
run_upgrade "${WORKDIR}/t3.log" "http://127.0.0.1:${PORT}/not-a-zip.bin" --nodes node-a
rc=$?
if [[ $rc -ne 0 ]] && grep -qi "zip archive" "${WORKDIR}/t3.log.out"; then
    pass "a non-zip download is rejected"
else
    fail "a non-zip download is rejected" "expected non-zero exit and a zip complaint"
fi

# ---------------------------------------------------------------------------
# --nodes is required; without it the script has no idea what to upgrade.
run_upgrade "${WORKDIR}/t4.log" "$FILE_URL"
rc=$?
if [[ $rc -ne 0 ]] && grep -qi "nodes is required" "${WORKDIR}/t4.log.out"; then
    pass "missing --nodes is rejected"
else
    fail "missing --nodes is rejected" "expected non-zero exit"
fi

echo
echo "=== Rolling sequencing ==="

# ---------------------------------------------------------------------------
# Three healthy nodes, node-b is the leader.
LOG="${WORKDIR}/t5.log"
FAKE_SSH_LEADER="node-b" run_upgrade "$LOG" "$FILE_URL" \
    --nodes node-a,node-b,node-c \
    --sha256 "$REAL_SHA"
rc=$?

if [[ $rc -eq 0 ]]; then
    pass "a healthy three-node rollout completes"
else
    fail "a healthy three-node rollout completes" "$(tail -3 "${LOG}.out")"
fi

# Every node should have been visited.
for n in node-a node-b node-c; do
    if grep -q "^${n}	" "$LOG"; then
        pass "${n} was upgraded"
    else
        fail "${n} was upgraded" "no commands issued to ${n}"
    fi
done

# ---------------------------------------------------------------------------
# The leader must step down before its service is stopped. Upgrading the
# active node without stepping down forces an unnecessary election while
# the cluster is already down a node.
step_down_line="$(grep -n "node-b.*step-down" "$LOG" | head -1 | cut -d: -f1)"
stop_line="$(grep -n "node-b.*systemctl stop" "$LOG" | head -1 | cut -d: -f1)"

if [[ -n "$step_down_line" && -n "$stop_line" && "$step_down_line" -lt "$stop_line" ]]; then
    pass "the leader steps down before it is stopped"
else
    fail "the leader steps down before it is stopped" \
         "step-down at line ${step_down_line:-none}, stop at ${stop_line:-none}"
fi

# ---------------------------------------------------------------------------
# Non-leaders should not be stepped down — it's a pointless disruption.
if require_log "$LOG" "a standby is not stepped down"; then
    if ! grep -q "node-a.*step-down" "$LOG"; then
        pass "a standby is not stepped down"
    else
        fail "a standby is not stepped down" "node-a received a step-down"
    fi
fi

# ---------------------------------------------------------------------------
# Strictly one at a time: node-a must be confirmed healthy before node-b
# is stopped. Stopping two nodes of three at once loses quorum.
a_health="$(grep -n "node-a.*sys/health" "$LOG" | tail -1 | cut -d: -f1)"
b_stop="$(grep -n "node-b.*systemctl stop" "$LOG" | head -1 | cut -d: -f1)"

if [[ -n "$a_health" && -n "$b_stop" && "$a_health" -lt "$b_stop" ]]; then
    pass "each node is healthy before the next is stopped"
else
    fail "each node is healthy before the next is stopped" \
         "node-a health at ${a_health:-none}, node-b stop at ${b_stop:-none}"
fi

# ---------------------------------------------------------------------------
# The binary must be staged on a node before its service goes down, so the
# window with Vault stopped is as short as possible.
scp_line="$(grep -n "node-a.*SCP" "$LOG" | head -1 | cut -d: -f1)"
a_stop="$(grep -n "node-a.*systemctl stop" "$LOG" | head -1 | cut -d: -f1)"
if [[ -n "$scp_line" && -n "$a_stop" && "$scp_line" -lt "$a_stop" ]]; then
    pass "the binary is copied before the service is stopped"
else
    fail "the binary is copied before the service is stopped" \
         "scp at ${scp_line:-none}, stop at ${a_stop:-none}"
fi

# ---------------------------------------------------------------------------
# The abort path. If a node never comes back healthy, the run must stop —
# continuing would take out a second node and, with it, quorum.
LOG="${WORKDIR}/t6.log"
FAKE_SSH_LEADER="node-c" FAKE_SSH_UNHEALTHY="node-a" \
    run_upgrade "$LOG" "$FILE_URL" \
        --nodes node-a,node-b,node-c \
        --sha256 "$REAL_SHA" \
        --health-timeout 6
rc=$?

if [[ $rc -ne 0 ]]; then
    pass "an unhealthy node fails the run"
else
    fail "an unhealthy node fails the run" "exited 0 despite node-a never recovering"
fi

if ! grep -q "node-b.*systemctl stop" "$LOG"; then
    pass "the rollout stops rather than continuing to the next node"
else
    fail "the rollout stops rather than continuing to the next node" \
         "node-b was stopped after node-a failed — this is the quorum-losing case"
fi

if grep -qi "did not report healthy" "${LOG}.out"; then
    pass "the failure explains which node needs attention"
else
    fail "the failure explains which node needs attention" "no explanatory message"
fi

# ---------------------------------------------------------------------------
# A failure part-way through must also stop the run.
LOG="${WORKDIR}/t7.log"
FAKE_SSH_LEADER="node-c" FAKE_SSH_FAIL_STOP="node-b" \
    run_upgrade "$LOG" "$FILE_URL" \
        --nodes node-a,node-b,node-c \
        --sha256 "$REAL_SHA"
rc=$?

if [[ $rc -ne 0 ]] && ! grep -q "node-c.*systemctl stop" "$LOG"; then
    pass "a failed stop aborts before reaching the next node"
else
    fail "a failed stop aborts before reaching the next node" \
         "expected non-zero exit and node-c untouched"
fi

# ---------------------------------------------------------------------------
echo
echo "==============================="
echo " passed: ${PASSED}   failed: ${FAILED}"
echo "==============================="
[[ "$FAILED" -eq 0 ]] || exit 1

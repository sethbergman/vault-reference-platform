#!/usr/bin/env bash
#
# run-tests.sh — scripts/bastion-proxy.sh, against a fake az CLI
#
# Usage:
#   ./tests/bastion-proxy/run-tests.sh
#
# Seconds. No Azure, no credentials, no network beyond loopback.
#
# WHAT THIS COVERS
#
# The script is the Azure profile's only route to a node: the nodes have
# no public address and 22 is open from the Bastion subnet alone, so every
# Ansible connection is a ProxyCommand through this. It exists because
# `az network bastion tunnel` opens a local port and keeps running, while
# a ProxyCommand must speak the session on stdin and stdout -- the AWS
# profile needs no such wrapper because `aws ssm start-session` already
# does the latter.
#
# What is checked here is what the script does: that it asks for the
# tunnel it was told to, on a port it picked rather than a fixed one, that
# it waits for the port instead of sleeping a guess, that it kills the
# tunnel on the way out, and that it fails loudly rather than handing SSH
# a dead socket.
#
# What is NOT checked here is whether Azure Bastion then carries the
# session. That needs an apply nobody has done: terraform/azure has never
# been applied. See docs/cloud-apply.md.
#
# Requirements: bash, python3

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SCRIPT="${REPO_ROOT}/scripts/bastion-proxy.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
green() { printf '\033[32m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*"; }
info()  { printf '\033[36m%s\033[0m\n' "$*"; }
ok()    { PASS=$((PASS + 1)); green "  PASS  $1"; }
bad()   { FAIL=$((FAIL + 1)); red "  FAIL  $1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; }

reset_scenario() {
    FAKE_LOG="${WORK}/calls.log"; : > "$FAKE_LOG"
    FAKE_TUNNEL_RC="0"
    FAKE_TUNNEL_NEVER_LISTENS="false"
    FAKE_TUNNEL_LISTEN_DELAY="0"
    export FAKE_LOG FAKE_TUNNEL_RC FAKE_TUNNEL_NEVER_LISTENS FAKE_TUNNEL_LISTEN_DELAY
    export PATH="${SCRIPT_DIR}/fake-bin:${REPO_ROOT}/scripts:${ORIGINAL_PATH}"
    export AZURE_BASTION_NAME="vault-reference-bastion"
    export AZURE_BASTION_RESOURCE_GROUP="vault-reference"
}
ORIGINAL_PATH="$PATH"

# An interrupted earlier run can leave fake tunnels behind, which would
# make the leak count below meaningless. The bracket keeps pgrep/pkill
# from matching the shell running them.
pkill -f "bastion tunne[l]" 2>/dev/null || true

# The proxy relays a session, so a test drives it the way SSH does: write
# a byte, read what comes back, then close. The fake tunnel accepts and
# closes, which is enough to prove the relay was wired to the port.
run_proxy() {
    timeout 20 "$SCRIPT" "$@" < /dev/null > "${WORK}/out.log" 2>"${WORK}/err.log"
    RC=$?
    ERR="$(cat "${WORK}/err.log")"
    return 0
}

assert_rc() {
    local want="$1" what="$2"
    if [[ "$RC" == "$want" ]]; then ok "$what"; else bad "$what" "exit was ${RC}, wanted ${want}: $(tail -2 <<< "$ERR")"; fi
}
assert_log_has() {
    local needle="$1" what="$2"
    if grep -q -- "$needle" "$FAKE_LOG"; then ok "$what"; else bad "$what" "no call matching '${needle}' in: $(tr '\n' '|' < "$FAKE_LOG")"; fi
}
assert_says() {
    local needle="$1" what="$2"
    if grep -q -- "$needle" <<< "$ERR"; then ok "$what"; else bad "$what" "stderr did not contain '${needle}'"; fi
}

TARGET="/subscriptions/0000/resourceGroups/vault-reference/providers/Microsoft.Compute/virtualMachineScaleSets/vault/virtualMachines/0"

# ---------------------------------------------------------------------------
info ""
info "=== It asks for the tunnel it was told to ==="
# ---------------------------------------------------------------------------
reset_scenario
run_proxy --target-resource-id "$TARGET" --resource-port 22
assert_rc 0 "a tunnel that listens is relayed and exits cleanly"
assert_log_has "network bastion tunnel" "it opens a Bastion tunnel"
assert_log_has -- "--target-resource-id ${TARGET}" "targeting the instance it was given"
assert_log_has -- "--resource-port 22" "on the port it was given"
assert_log_has -- "--name vault-reference-bastion" "naming the Bastion host from the environment"

# The port must not be a constant. Ansible opens several connections at
# once -- three nodes, and more than one to each -- and a fixed port turns
# every connection after the first into a bind failure, or worse a relay
# to whichever node bound first.
reset_scenario
run_proxy --target-resource-id "$TARGET" --resource-port 22
FIRST_PORT="$(grep -oE -- '--port [0-9]+' "$FAKE_LOG" | head -1 | awk '{print $2}')"
reset_scenario
run_proxy --target-resource-id "$TARGET" --resource-port 22
SECOND_PORT="$(grep -oE -- '--port [0-9]+' "$FAKE_LOG" | head -1 | awk '{print $2}')"
if [[ -n "$FIRST_PORT" && -n "$SECOND_PORT" && "$FIRST_PORT" != "$SECOND_PORT" ]]; then
    ok "each invocation picks its own local port (${FIRST_PORT}, then ${SECOND_PORT})"
else
    bad "each invocation picks its own local port" "got '${FIRST_PORT}' and '${SECOND_PORT}'"
fi

# ---------------------------------------------------------------------------
info ""
info "=== It fails loudly rather than handing SSH a dead socket ==="
# ---------------------------------------------------------------------------
reset_scenario
FAKE_TUNNEL_RC="1"; export FAKE_TUNNEL_RC
run_proxy --target-resource-id "$TARGET" --resource-port 22
assert_rc 1 "an az failure fails the proxy"
assert_says "exited before it was listening" "and says the tunnel died rather than blaming ssh"

# A tunnel that starts and never listens is the shape of a Bastion that is
# still coming up, or a target id naming an instance that is gone. Waiting
# forever would hang the whole playbook on one host.
reset_scenario
FAKE_TUNNEL_NEVER_LISTENS="true"; export FAKE_TUNNEL_NEVER_LISTENS
run_proxy --target-resource-id "$TARGET" --resource-port 22 --timeout 2
assert_rc 1 "a tunnel that never listens times out"
assert_says "did not listen" "and names the port it waited on"

# A tunnel is not ready the instant az starts: a cold Bastion takes
# seconds to set the session up. The script waits for the port to accept a
# connection rather than sleeping a fixed guess, and this is the case that
# tells the two apart -- with a guess, SSH is handed a socket nobody is
# listening on and the tunnel gets blamed for being broken rather than
# slow. Without this scenario the suite passes either way, which it did
# until a mutation pass pointed it out.
reset_scenario
FAKE_TUNNEL_LISTEN_DELAY="3"; export FAKE_TUNNEL_LISTEN_DELAY
run_proxy --target-resource-id "$TARGET" --resource-port 22 --timeout 20
assert_rc 0 "a tunnel that takes three seconds to listen is waited for"

# ---------------------------------------------------------------------------
info ""
info "=== Required arguments ==="
# ---------------------------------------------------------------------------
reset_scenario
run_proxy --resource-port 22
assert_rc 1 "a missing target resource id fails"
assert_says "target-resource-id" "and names the argument"

reset_scenario
unset AZURE_BASTION_NAME
run_proxy --target-resource-id "$TARGET"
assert_rc 1 "a missing bastion name fails"
assert_says "terraform-to-ansible.sh" "and points at what writes it"

# ---------------------------------------------------------------------------
info ""
info "=== It does not leave tunnels behind ==="
# ---------------------------------------------------------------------------
# An az left running holds a local port and a Bastion session. A playbook
# against three nodes leaks three per run, and they are invisible until
# the next run cannot bind.
# pgrep -fc exits non-zero when it matches nothing, so a `|| echo 0`
# fallback prints a second zero and the comparison reads "0\n0". Count
# with grep -c, which prints one number either way.
# shellcheck disable=SC2009  # pgrep -fc is the thing being avoided here
count_tunnels() { ps -eo cmd --no-headers | grep -c "bastion tunne[l]" || true; }

reset_scenario
BEFORE="$(count_tunnels)"
run_proxy --target-resource-id "$TARGET" --resource-port 22
sleep 0.5
AFTER="$(count_tunnels)"
if [[ "$AFTER" -le "$BEFORE" ]]; then
    ok "the tunnel is gone once the proxy exits"
else
    bad "the tunnel is gone once the proxy exits" "before: ${BEFORE}, after: ${AFTER}"
fi

# ---------------------------------------------------------------------------
printf '\n=== Results ===\n'
# ---------------------------------------------------------------------------
printf 'passed: %d\nfailed: %d\n' "$PASS" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then red "FAILED"; exit 1; fi
green "All ${PASS} assertions passed."

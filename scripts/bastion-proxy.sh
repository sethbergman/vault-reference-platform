#!/usr/bin/env bash
#
# bastion-proxy.sh — Carry one SSH connection to an Azure node through
#                    Azure Bastion, as an OpenSSH ProxyCommand
#
# Usage:
#   ./bastion-proxy.sh --target-resource-id <id> [options]
#
# Example:
#   # As ansible/inventory/azure_rm.yml uses it, via ProxyCommand:
#   ssh -o ProxyCommand="scripts/bastion-proxy.sh --target-resource-id %h \
#       --resource-port %p" azureuser@<resource-id>
#
# Options:
#   --target-resource-id <id>  Required. The VMSS instance's full resource id.
#   --resource-port <port>     Port on the node (default: 22).
#   --bastion-name <name>      Bastion host name (default: from
#                              AZURE_BASTION_NAME).
#   --resource-group <name>    Bastion's resource group (default: from
#                              AZURE_BASTION_RESOURCE_GROUP).
#   --timeout <seconds>        How long to wait for the tunnel (default: 30).
#
# What it does:
#   1. Picks a free local port.
#   2. Starts `az network bastion tunnel` on it, in the background.
#   3. Waits for the port to accept a connection.
#   4. Hands the socket to SSH on stdin/stdout, and tears the tunnel down
#      when SSH goes away.
#
# Requirements: az CLI, logged in, with the bastion extension
#               (`az extension add --name bastion`); and one of nc, ncat
#               or socat.
#
# DELIBERATE BEHAVIOURS
#
#   - This exists because `az network bastion tunnel` is not a
#     ProxyCommand. It opens a listening port and keeps running; a
#     ProxyCommand must instead speak the session on its own stdin and
#     stdout. AWS's `aws ssm start-session` does the latter natively,
#     which is why ansible/inventory/aws_ec2.yml needs no helper and this
#     profile does. Without the wrapper, the tunnel has to be started by
#     hand per node, on a port nobody is tracking, before the playbook --
#     the sort of step that works once for the person who invented it.
#
#   - A free port is chosen per invocation rather than fixed. Ansible
#     opens connections to several nodes at once (and several to the same
#     node), so a fixed port turns the second one into either a bind
#     failure or, worse, a connection to whichever node got there first.
#
#   - The tunnel is killed through a trap on EXIT, and the relay runs in
#     the foreground rather than under `exec` so that trap can fire at
#     all. An `az` left running holds its local port and a Bastion
#     session; a playbook against three nodes leaks three of them per run,
#     and they are invisible until the next run cannot bind.
#
#   - Errors go to stderr and nothing but session bytes goes to stdout.
#     SSH is reading stdout: a stray log line there is protocol data, and
#     the failure looks like a corrupt SSH banner rather than a message.

set -euo pipefail

TARGET_ID=""
RESOURCE_PORT="22"
BASTION_NAME="${AZURE_BASTION_NAME:-}"
RESOURCE_GROUP="${AZURE_BASTION_RESOURCE_GROUP:-}"
TIMEOUT="30"

usage() {
    grep '^#' "$0" | sed 's/^# \{0,1\}//' | sed '1d'
    exit 0
}

log() { echo "[bastion-proxy] $*" >&2; }
die() {
    echo "[bastion-proxy] ERROR: $*" >&2
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target-resource-id) TARGET_ID="$2"; shift 2 ;;
        --resource-port)      RESOURCE_PORT="$2"; shift 2 ;;
        --bastion-name)       BASTION_NAME="$2"; shift 2 ;;
        --resource-group)     RESOURCE_GROUP="$2"; shift 2 ;;
        --timeout)            TIMEOUT="$2"; shift 2 ;;
        -h|--help)            usage ;;
        *)                    die "unknown argument: $1 (try --help)" ;;
    esac
done

[[ -n "$TARGET_ID" ]] || die "--target-resource-id is required"
[[ -n "$BASTION_NAME" ]] || die \
    "--bastion-name is required (or set AZURE_BASTION_NAME). terraform-to-ansible.sh writes both into group_vars."
[[ -n "$RESOURCE_GROUP" ]] || die \
    "--resource-group is required (or set AZURE_BASTION_RESOURCE_GROUP)."

command -v az >/dev/null 2>&1 || die "az CLI not found on PATH"

# `az network bastion tunnel` is in the bastion EXTENSION, not core az
# (checked against azure-cli 2.90.0, whose own warning says so). A fresh
# install does not have it, and az's default answer is to install it
# mid-command -- the worst possible place: there is no tty here to confirm
# on, and Ansible opens several of these at once, so several az processes
# race to install the same extension.
#
# Dynamic install is therefore switched off for this invocation. az fails
# immediately and says what is missing, and the error below turns that into
# the one command that fixes it. Installing software is not a
# ProxyCommand's job. scripts/preflight-cloud.sh checks for the extension
# before an apply, which is where this should be caught.
export AZURE_EXTENSION_USE_DYNAMIC_INSTALL=no

# nc is not one program. BSD nc, GNU netcat and ncat all speak stdio to a
# TCP port; socat does too with different spelling. Pick whichever exists
# rather than requiring a particular one.
RELAY=""
for candidate in nc ncat socat; do
    if command -v "$candidate" >/dev/null 2>&1; then RELAY="$candidate"; break; fi
done
[[ -n "$RELAY" ]] || die "need one of nc, ncat or socat to relay the tunnel"

# A free port from the ephemeral range. Asking the kernel for one and then
# using it is a race in principle; in practice the window is microseconds
# and the alternative -- a fixed port -- fails every parallel connection.
LOCAL_PORT="$(python3 -c 'import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()' 2>/dev/null)" || die "could not find a free local port (python3 missing?)"

TUNNEL_PID=""
cleanup() {
    if [[ -n "$TUNNEL_PID" ]]; then
        kill "$TUNNEL_PID" 2>/dev/null || true
        wait "$TUNNEL_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

az network bastion tunnel \
    --name "$BASTION_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --target-resource-id "$TARGET_ID" \
    --resource-port "$RESOURCE_PORT" \
    --port "$LOCAL_PORT" >&2 &
TUNNEL_PID=$!

# Wait for the port rather than sleeping a guess. A fixed sleep is either
# too short on a cold Bastion -- SSH then reports "connection refused" and
# the tunnel is blamed for being broken rather than slow -- or wasted on
# every connection after the first.
DEADLINE=$(( SECONDS + TIMEOUT ))
while ! python3 -c "import socket,sys
s = socket.socket()
s.settimeout(1)
sys.exit(0 if s.connect_ex(('127.0.0.1', ${LOCAL_PORT})) == 0 else 1)" 2>/dev/null; do
    if ! kill -0 "$TUNNEL_PID" 2>/dev/null; then
        die "the tunnel exited before it was listening (az failed; its output is above). If az named the bastion extension, run: az extension add --name bastion"
    fi
    if (( SECONDS >= DEADLINE )); then
        die "the tunnel did not listen on 127.0.0.1:${LOCAL_PORT} within ${TIMEOUT}s"
    fi
    sleep 0.2
done

# Not `exec`. exec replaces this shell with the relay, and a replaced
# shell runs no EXIT trap -- the tunnel above would outlive every
# connection, holding its local port and a Bastion session, invisibly,
# until a later run could not bind. tests/bastion-proxy counts the
# leftovers, which is how the first version of this line was caught.
case "$RELAY" in
    socat) socat - "TCP:127.0.0.1:${LOCAL_PORT}" ;;
    *)     "$RELAY" 127.0.0.1 "$LOCAL_PORT" ;;
esac

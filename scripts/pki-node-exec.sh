#!/usr/bin/env bash
#
# pki-node-exec.sh — Run one command on one Vault node, as root, with the
#                    PKI credentials that node already holds
#
# Usage:
#   ./pki-node-exec.sh --node <name> [options] -- <command> [args...]
#
# Options:
#   --node <name>         Required. The inventory's name for the node.
#   --inventory <path>    Ansible inventory (default:
#                         ansible/inventory/aws_ec2.yml)
#   --private-key <path>  SSH key. Not optional on AWS: SSM carries the
#                         session, it does not authenticate you.
#   --env-file <path>     Sourced on the node before the command
#                         (default: /etc/vault.d/pki.env)
#   --dry-run             Print what would run and exit.
#
# Example, as scripts/migrate-to-vault-pki.sh invokes it:
#   ./pki-node-exec.sh --node i-0abc --private-key ~/.ssh/k.pem -- \
#       /usr/local/bin/vault-issue-node-cert.sh --ca-only --mount pki
#
# WHY THIS EXISTS
#
# migrate-to-vault-pki.sh sequences a certificate rollout, and on a cloud
# cluster the per-node work has to happen on the node: each one reads
# /etc/vault.d/tls/vault.crt off its own filesystem, and there is no
# shared directory to write into from outside.
#
# Everything needed is already there. ansible/roles/vault_pki installs
# issue-node-cert.sh at /usr/local/bin/vault-issue-node-cert.sh and writes
# /etc/vault.d/pki.env with VAULT_ADDR, VAULT_CACERT and an AppRole pair —
# the same credentials the renewal timer uses. This just runs one command
# in that environment.
#
# It is a script rather than a line in the documentation because the
# quoting is the hard part and getting it wrong happens mid-migration,
# which is the worst moment for a cluster to be partly migrated. Arguments
# are quoted with printf %q and handed over as a single remote script, so
# a value containing a space cannot become two arguments.
#
# DELIBERATE BEHAVIOURS
#
#   It refuses a node that has not been prepared. The env file and the
#   issue script come from ansible/roles/vault_pki, which is off by
#   default -- so the common mistake is to run the migration against a
#   cluster whose playbook never enabled it, and the raw failure is a
#   shell reporting a missing file from inside a phase that is otherwise
#   going fine.
#
#   It refuses a node that ran nothing. Without boto3 in Ansible's
#   interpreter the aws_ec2 plugin returns an EMPTY inventory and exits 0,
#   so `ansible <node>` warns about an unmatched pattern, does nothing, and
#   succeeds. That has cost three sessions here. A command that silently
#   ran nowhere, in the middle of a certificate rollout, would leave the
#   cluster's trust in a state the driver believes it is not in.
#
#   Both of those are checked inside the one connection, by the remote
#   script, rather than by an ansible run each. Three round trips per call
#   was most of a seventeen-minute migration -- the driver calls this eight
#   times for a three-node cluster, and ansible spends longer starting up
#   and resolving an aws_ec2 inventory than the work takes. They report
#   through markers on stdout because `ansible -m shell` does not pass the
#   remote exit status back: it exits 2 for any failed task and nothing
#   else.
#
#   A connection that fails is not a node that ran nothing. Unreachable is
#   ansible's own failure and is passed through as one -- diagnosing it as
#   a missing SDK would send the reader to the wrong half of the problem.
#
#   --dry-run makes no connection. It used to make two, which is a strange
#   thing for a dry run to do on a cluster mid-migration.
#
#   The credentials are sourced on the node, never passed to it. The env
#   file is root-readable on the node and this script never reads it, so
#   nothing lands in this machine's process table or shell history.
#
# Requirements: ansible, and whatever the inventory needs to resolve
# (boto3 for aws_ec2; see docs/deployment.md#reaching-the-nodes).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

NODE=""
INVENTORY="${REPO_ROOT}/ansible/inventory/aws_ec2.yml"
PRIVATE_KEY=""
ENV_FILE="/etc/vault.d/pki.env"
DRY_RUN=false

log() { printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

usage() {
    sed -n '2,${ /^#/!q; s/^# \{0,1\}//p; }' "$0"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --node)        NODE="$2"; shift 2 ;;
        --inventory)   INVENTORY="$2"; shift 2 ;;
        --private-key) PRIVATE_KEY="$2"; shift 2 ;;
        --env-file)    ENV_FILE="$2"; shift 2 ;;
        --dry-run)     DRY_RUN=true; shift ;;
        -h|--help)     usage ;;
        --)            shift; break ;;
        *)             die "Unknown argument: $1" ;;
    esac
done

[[ -n "$NODE" ]]  || die "--node is required"
[[ $# -gt 0 ]]    || die "no command given — everything after -- is run on the node"
[[ -f "$INVENTORY" ]] || die "no inventory at ${INVENTORY}"
command -v ansible >/dev/null 2>&1 || die "ansible not found on PATH"

# Build the remote script. printf %q on every argument, so a value with a
# space in it stays one argument on the far side -- the whole reason this
# is a script and not a documented one-liner.
#
# The two prerequisite checks lead it, so they cost no connection of their
# own, and they report through a marker on stdout: `ansible -m shell` exits
# 2 for any failed task and does not pass the remote status back, so an
# exit code could not say which of them failed.
MARK="__pki_node_exec__"

REMOTE="if ! test -r $(printf '%q' "$ENV_FILE"); then echo ${MARK}:no-env; exit 90; fi
if ! test -x $(printf '%q' "$1"); then echo ${MARK}:no-cmd; exit 91; fi
echo ${MARK}:ran
set -a; . $(printf '%q' "$ENV_FILE"); set +a; exec"
for arg in "$@"; do
    REMOTE+=" $(printf '%q' "$arg")"
done

declare -a ANSIBLE_ARGS=(
    "$NODE" -i "$INVENTORY" --become -m shell -a "$REMOTE"
)
[[ -n "$PRIVATE_KEY" ]] && ANSIBLE_ARGS+=(--private-key "$PRIVATE_KEY")

if [[ "$DRY_RUN" == true ]]; then
    log "would run on ${NODE}:"
    printf '  %s\n' "$REMOTE" >&2
    exit 0
fi

log "${NODE}: $*"

OUTPUT="$(mktemp)"
# Not `[[ -n "$OUTPUT" ]] && rm -f ...` -- a trap handler ending in a false
# conditional sets the script's exit status to 1 on the way out, which
# tests/lint/check_trap_exit.py exists to catch.
trap 'rm -f "$OUTPUT"' EXIT

RC=0
ansible "${ANSIBLE_ARGS[@]}" > "$OUTPUT" || RC=$?

# Buffering costs nothing: `ansible -m shell` collects the remote output and
# prints it when the task finishes, so there was no live progress to lose.
# The markers are this script's own protocol and are not the operator's to
# read, so they come back out here.
grep -v "^${MARK}:" "$OUTPUT" || true

if grep -q "^${MARK}:no-env" "$OUTPUT"; then
    die "${NODE} has no readable ${ENV_FILE}. It comes from ansible/roles/vault_pki, which is off by default -- run the playbook with vault_pki_enabled=true before migrating. See docs/security.md#doing-the-migration."
elif grep -q "^${MARK}:no-cmd" "$OUTPUT"; then
    die "${NODE} has no executable ${1}. It comes from ansible/roles/vault_pki, which is off by default -- run the playbook with vault_pki_enabled=true before migrating. See docs/security.md#doing-the-migration."
fi

# Ansible is happy and nothing reported having run: the host pattern matched
# no host. Without boto3 the aws_ec2 plugin returns an EMPTY inventory and
# exits 0, so that is what a missing SDK looks like from here -- a command
# that ran nowhere and succeeded, which during a certificate rollout leaves
# the driver's next step believing something happened.
#
# Gated on RC being 0 deliberately. An unreachable host is ansible's own
# failure and also produces no marker; calling that a missing SDK would
# send the reader to the wrong half of the problem.
if [[ "$RC" -eq 0 ]] && ! grep -q "^${MARK}:ran" "$OUTPUT"; then
    die "nothing ran on '${NODE}' and ansible reported no error, which means the host pattern matched no host. If this is aws_ec2 or azure_rm, the usual cause is a missing SDK in Ansible's own interpreter -- the plugin then returns an empty inventory and exits 0. See docs/deployment.md#reaching-the-nodes."
fi

exit "$RC"

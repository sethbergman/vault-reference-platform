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
#   It refuses a node the inventory does not know. Without boto3 in
#   Ansible's interpreter the aws_ec2 plugin returns an EMPTY inventory
#   and exits 0, so `ansible <node>` warns about an unmatched pattern,
#   does nothing, and succeeds. That has cost three sessions here. A
#   command that silently ran nowhere, in the middle of a certificate
#   rollout, would leave the cluster's trust in a state the driver
#   believes it is not in.
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
    grep '^#' "$0" | sed -e '1d' -e 's/^# \{0,1\}//'
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

# The inventory has to know this node. An aws_ec2 plugin without boto3
# returns an empty inventory and exit 0, so `ansible <node> -a ...` prints
# a warning, runs nowhere, and succeeds -- which during a certificate
# rollout means the driver's next step believes something happened.
if ! ansible-inventory -i "$INVENTORY" --host "$NODE" >/dev/null 2>&1; then
    die "the inventory at ${INVENTORY} does not know a host called '${NODE}'. If this is aws_ec2 or azure_rm, the usual cause is a missing SDK in Ansible's own interpreter -- the plugin then returns an empty inventory and exits 0. See docs/deployment.md#reaching-the-nodes."
fi

# The node has to have been prepared. ansible/roles/vault_pki installs the
# issue script and writes the env file with the credentials it uses; the
# role is off by default and the documented enable step for a cloud
# cluster turns on snapshots and audit, not PKI. Without it the remote
# shell reports "/etc/vault.d/pki.env: No such file or directory", which
# is true and tells nobody what to do about it.
#
# Checked once, up front, rather than discovered on whichever node the
# migration reaches first.
PROBE="test -r $(printf '%q' "$ENV_FILE") && test -x $(printf '%q' "$1")"
if ! ansible "$NODE" -i "$INVENTORY" --become -m shell -a "$PROBE" \
        ${PRIVATE_KEY:+--private-key "$PRIVATE_KEY"} >/dev/null 2>&1; then
    die "${NODE} is missing ${ENV_FILE} or ${1}. Those come from ansible/roles/vault_pki, which is off by default -- run the playbook with vault_pki_enabled=true before migrating. See docs/security.md#doing-the-migration."
fi

# Build the remote script. printf %q on every argument, so a value with a
# space in it stays one argument on the far side -- the whole reason this
# is a script and not a documented one-liner.
REMOTE="set -a; . $(printf '%q' "$ENV_FILE"); set +a; exec"
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
ansible "${ANSIBLE_ARGS[@]}"

#!/usr/bin/env bash
#
# configure-autopilot.sh — Make Raft prune the servers that no longer exist
#
# Usage:
#   ./configure-autopilot.sh [options]
#
# Example:
#   ./configure-autopilot.sh --min-quorum 3 --dead-server-threshold 5m
#
# What it does:
#   1. Reads the cluster's current autopilot configuration.
#   2. Sets cleanup_dead_servers, min_quorum, dead_server_last_contact_threshold
#      and server_stabilization_time.
#   3. Reads the configuration back and fails if it did not take.
#
# Idempotent: re-running with the same values is a no-op that still
# verifies. It configures; it removes nothing itself.
#
# WHY THIS EXISTS
#
# Vault ships autopilot with cleanup_dead_servers = false and
# dead_server_last_contact_threshold = 24h. A node that is destroyed stays
# in the Raft configuration as a *voter* — verifiably so: destroy a node
# on the local cluster and `vault operator raft list-peers` still lists it
# a minute later, with autopilot reporting FailureTolerance 0.
#
# On a fixed set of machines that is survivable; the node comes back with
# the same node_id and rejoins. On the cloud profiles it is not, because
# a replacement is a different machine with a different node_id:
# terraform/aws sets node_id to the EC2 instance id, terraform/azure to
# the scale set VM name. So every replacement *adds* a voter and leaves
# the old one behind.
#
# That is what makes an ASG instance refresh — the upgrade an operator
# would actually run on the AWS profile — unsafe on a three-node cluster:
#
#   start          A  B  C          3 voters, quorum 2, 3 live   ok
#   terminate A    A' B  C          3 voters, quorum 2, 2 live   ok, no margin
#   launch A2      A' B  C  A2      4 voters, quorum 3, 3 live   ok, no margin
#   terminate B    A' B' C  A2      4 voters, quorum 3, 2 live   QUORUM LOST
#
#   (A' = the dead voter left behind by terminating A)
#
# It fails partway through the second node, not the third, and
# min_healthy_percentage cannot prevent it: the ASG is counting instances
# it can see, and the problem is the ones Raft still counts that the ASG
# cannot.
#
# WHY min_quorum IS THE SAFETY, NOT THE THRESHOLD
#
# cleanup_dead_servers on its own would let autopilot prune a node during
# a network partition, taking the cluster further from quorum exactly when
# it is least able to afford it. min_quorum is the floor it will not prune
# below, so with three nodes no pruning can happen until a replacement has
# joined. That ordering — join, then prune — is the whole property.
#
# The floor counts SERVERS, not voters, which is worth knowing because it
# is not what the sequence looks like from outside. A replacement joins as
# a non-voter; that alone takes the server count to four and satisfies the
# floor; the dead voter is pruned; only then is the replacement promoted.
# The voter count never rises above three. Watched happening in
# tests/autopilot-prune, whose first assertion guessed the opposite and
# failed against a cluster doing the right thing.
#
# It is also why the dead-server threshold can be short. Five minutes
# would be reckless without a floor and is fine with one, and it has to be
# well inside the ASG's instance_warmup (600s) or the next node is
# terminated before the last dead voter is gone.
#
# Requirements:
#   - vault CLI on PATH
#   - VAULT_ADDR and VAULT_TOKEN set (or --vault-addr/--vault-token), with
#     a token authorized to write sys/storage/raft/autopilot/configuration
#   - A Raft (integrated storage) cluster. There is no autopilot on other
#     storage backends and the script says so rather than failing obscurely.

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
# Empty means "count the voters the cluster currently has". At bootstrap
# that is the node count, which is the value that makes pruning wait for a
# replacement. Passing it explicitly is for the case where the cluster is
# already degraded and counting would bake the degraded number in.
MIN_QUORUM=""
DEAD_SERVER_THRESHOLD="5m"
STABILIZATION_TIME="10s"
CLEANUP="true"
VAULT_ADDR="${VAULT_ADDR:-}"
VAULT_TOKEN="${VAULT_TOKEN:-}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()  { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
die()  { log "ERROR: $*"; exit 1; }

usage() {
    grep '^#' "$0" | sed -e '1d' -e 's/^# \{0,1\}//'
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --min-quorum)             MIN_QUORUM="$2"; shift 2 ;;
        --dead-server-threshold)  DEAD_SERVER_THRESHOLD="$2"; shift 2 ;;
        --stabilization-time)     STABILIZATION_TIME="$2"; shift 2 ;;
        --no-cleanup)             CLEANUP="false"; shift ;;
        --vault-addr)             VAULT_ADDR="$2"; shift 2 ;;
        --vault-token)            VAULT_TOKEN="$2"; shift 2 ;;
        -h|--help)                usage ;;
        *) die "Unknown argument: $1" ;;
    esac
done

command -v vault >/dev/null 2>&1 || die "vault CLI not found on PATH"
command -v jq >/dev/null 2>&1 || die "jq not found on PATH"
[[ -z "$VAULT_ADDR" ]] && die "VAULT_ADDR is not set (env var or --vault-addr)"
[[ -z "$VAULT_TOKEN" ]] && die "VAULT_TOKEN is not set (env var or --vault-token)"

export VAULT_ADDR VAULT_TOKEN

# ---------------------------------------------------------------------------
# Step 1: Confirm this is a Raft cluster, and read what it has now
# ---------------------------------------------------------------------------
CURRENT="$(vault operator raft autopilot get-config -format=json 2>&1)" || die \
    "Could not read autopilot configuration. This needs a Raft (integrated storage) cluster and a token authorized for sys/storage/raft/autopilot/configuration. Vault said: ${CURRENT}"

log "Current: cleanup_dead_servers=$(jq -r '.cleanup_dead_servers' <<< "$CURRENT")" \
    "min_quorum=$(jq -r '.min_quorum' <<< "$CURRENT")" \
    "dead_server_last_contact_threshold=$(jq -r '.dead_server_last_contact_threshold' <<< "$CURRENT")"

# ---------------------------------------------------------------------------
# Step 2: Work out min_quorum, if it was not given
# ---------------------------------------------------------------------------
if [[ -z "$MIN_QUORUM" ]]; then
    PEERS_JSON="$(vault operator raft list-peers -format=json 2>&1)" || die \
        "Could not list Raft peers to count voters: ${PEERS_JSON}"
    MIN_QUORUM="$(jq -r '[.data.config.servers[] | select(.voter == true)] | length' <<< "$PEERS_JSON")"
    [[ "$MIN_QUORUM" =~ ^[0-9]+$ ]] || die "Could not count voters from list-peers output"
    log "Counted ${MIN_QUORUM} voters; using that as min_quorum"
fi

# Below three, a "quorum" is not one: a two-node cluster loses quorum when
# either node goes, and autopilot pruning cannot help with that. Refusing
# is better than writing a number that reads like a safety property and
# is not one.
#
# Vault agrees, and enforces it itself -- asking for min_quorum 2 with
# cleanup on is rejected with "min_quorum must be set when
# cleanup_dead_servers is set and it should at least be 3". This check is
# therefore not the only thing standing there; it exists to fail earlier,
# and to say why in a sentence rather than in a hex-formatted API error.
if [[ "$MIN_QUORUM" -lt 3 ]]; then
    die "min_quorum is ${MIN_QUORUM}, which is not a quorum worth protecting. This wants a cluster of at least three voters; pass --min-quorum explicitly if you know better."
fi

# ---------------------------------------------------------------------------
# Step 3: Apply
# ---------------------------------------------------------------------------
log "Setting cleanup_dead_servers=${CLEANUP} min_quorum=${MIN_QUORUM} dead_server_last_contact_threshold=${DEAD_SERVER_THRESHOLD} server_stabilization_time=${STABILIZATION_TIME}"

vault operator raft autopilot set-config \
    -cleanup-dead-servers="${CLEANUP}" \
    -min-quorum="${MIN_QUORUM}" \
    -dead-server-last-contact-threshold="${DEAD_SERVER_THRESHOLD}" \
    -server-stabilization-time="${STABILIZATION_TIME}" \
    || die "Failed to write autopilot configuration"

# ---------------------------------------------------------------------------
# Step 4: Read it back
# ---------------------------------------------------------------------------
# A set-config that returns success and does not take is the failure this
# whole repository is arranged around. Ask the cluster what it has.
AFTER="$(vault operator raft autopilot get-config -format=json 2>&1)" || die \
    "Configuration was written but could not be read back: ${AFTER}"

GOT_CLEANUP="$(jq -r '.cleanup_dead_servers' <<< "$AFTER")"
GOT_QUORUM="$(jq -r '.min_quorum' <<< "$AFTER")"

[[ "$GOT_CLEANUP" == "$CLEANUP" ]] || die \
    "cleanup_dead_servers is ${GOT_CLEANUP} after writing ${CLEANUP}"
[[ "$GOT_QUORUM" == "$MIN_QUORUM" ]] || die \
    "min_quorum is ${GOT_QUORUM} after writing ${MIN_QUORUM}"

log "Autopilot configured and verified: cleanup_dead_servers=${GOT_CLEANUP} min_quorum=${GOT_QUORUM} dead_server_last_contact_threshold=$(jq -r '.dead_server_last_contact_threshold' <<< "$AFTER")"

if [[ "$CLEANUP" != "true" ]]; then
    log "NOTE: cleanup is off, so a replaced node stays a voter forever. On the cloud profiles that is a cluster which loses quorum during an instance refresh — see the header."
fi

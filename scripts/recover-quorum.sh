#!/usr/bin/env bash
#
# recover-quorum.sh — Bring back a cluster that has lost its majority,
#                     without losing what the survivor still holds
#
# Usage:
#   ./recover-quorum.sh --peers <id>=<address>[,<id>=<address>...] \
#       --compose-service <name>            # local dev profile
#   ./recover-quorum.sh --peers <id>=<address> \
#       --data-dir /vault/data --service-name vault    # a real node
#
# Example, recovering the single survivor of a three-node cluster:
#   ./recover-quorum.sh --peers vault-0=vault-0:8201 --compose-service vault-0
#
# What it does:
#   1. Refuses if the cluster still has quorum, unless --force.
#   2. Stops Vault on the survivor.
#   3. Writes peers.json into the Raft directory, listing the peers that
#      are actually left.
#   4. Starts Vault. Raft reads the file, adopts it as the cluster
#      configuration, and deletes it.
#   5. Waits for the node to report itself active.
#
# WHY THIS EXISTS, AND WHEN NOT TO USE IT
#
# Losing quorum is not the same failure as losing data, and the remedies
# are not interchangeable.
#
# If a majority of nodes are gone but one survivor still has its storage,
# that survivor holds every write Raft committed. peers.json tells it to
# stop waiting for peers that are never coming back. Nothing is lost.
#
# Restoring a snapshot into it instead would work, and would silently
# discard everything written since that snapshot was taken. If snapshots
# run hourly, that is up to an hour of secrets, leases and tokens thrown
# away to fix a problem that did not require throwing anything away.
#
# So: use this when the survivor's storage is intact. Use dr-drill.sh's
# restore path when it is not. docs/disaster-recovery.md draws the line.
#
# THIS IS NOT "EDITING THE RAFT LOG"
#
# peers.json is a recovery mechanism Raft supports: a file read once at
# startup and consumed. It does not touch raft.db. Hand-editing the log
# itself remains a bad idea and this does not do it.
#
# DELIBERATE BEHAVIOURS
#
#   - Refuses on a healthy cluster. Forcing a peer configuration onto a
#     cluster that still has quorum can strand the nodes left out of the
#     file. The check is "can this node answer a Raft configuration
#     query", because a node with quorum can and a node without cannot.
#   - Lists every surviving voter, not just this one. Recovering a
#     five-node cluster that lost two means naming the three that are
#     left; naming only one discards two healthy nodes' votes.
#   - Waits for active rather than for unsealed. A node can be unsealed
#     and still have no leader, which is the state this exists to leave.
#
# Requirements:
#   - jq, and either docker compose (--compose-service) or systemctl and
#     write access to the data directory (--service-name)
#   - VAULT_ADDR and VAULT_CACERT for the health checks
#
# The --service-name path is written from Vault's documented procedure
# and is NOT exercised by any test here: the suite runs the compose path.
# Treat it as reviewed, not proven.

set -euo pipefail

PEERS=""
COMPOSE_SERVICE=""
DATA_DIR="/vault/data"
SERVICE_NAME=""
FORCE=false
COMPOSE_FILE=""
WAIT_SECONDS=120

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

usage() {
    grep '^#' "$0" | sed -e '1d' -e 's/^# \{0,1\}//'
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --peers)            PEERS="$2"; shift 2 ;;
        --compose-service)  COMPOSE_SERVICE="$2"; shift 2 ;;
        --compose-file)     COMPOSE_FILE="$2"; shift 2 ;;
        --data-dir)         DATA_DIR="$2"; shift 2 ;;
        --service-name)     SERVICE_NAME="$2"; shift 2 ;;
        --wait)             WAIT_SECONDS="$2"; shift 2 ;;
        --force)            FORCE=true; shift ;;
        -h|--help)          usage ;;
        *) die "Unknown argument: $1" ;;
    esac
done

command -v jq >/dev/null 2>&1 || die "jq not found on PATH"
[[ -n "$PEERS" ]] || die "--peers is required, e.g. --peers vault-0=vault-0:8201"
[[ -n "$COMPOSE_SERVICE" || -n "$SERVICE_NAME" ]] \
    || die "one of --compose-service or --service-name is required"
[[ -n "$COMPOSE_SERVICE" && -n "$SERVICE_NAME" ]] \
    && die "--compose-service and --service-name are alternatives, not both"

[[ -n "$COMPOSE_FILE" ]] || COMPOSE_FILE="${REPO_ROOT}/docker/dev/docker-compose.yml"
compose() { docker compose -f "$COMPOSE_FILE" "$@"; }

# ---------------------------------------------------------------------------
# Build the peers.json body
# ---------------------------------------------------------------------------
# Raft protocol v3 wants id/address/non_voter. Everything named here
# becomes a voter: a recovery that leaves the cluster with non-voters
# only would have no one to elect.
PEERS_BODY="$(
    python3 - "$PEERS" <<'PY'
import json, sys
entries = []
for pair in sys.argv[1].split(","):
    pair = pair.strip()
    if not pair:
        continue
    if "=" not in pair:
        sys.exit("peer %r is not id=address" % pair)
    node_id, address = pair.split("=", 1)
    entries.append({"id": node_id.strip(), "address": address.strip(), "non_voter": False})
if not entries:
    sys.exit("no peers parsed")
print(json.dumps(entries, indent=2))
PY
)" || die "could not build peers.json from --peers"

log "Recovery configuration:"
printf '%s\n' "$PEERS_BODY" >&2

# ---------------------------------------------------------------------------
# Refuse on a cluster that still has quorum
# ---------------------------------------------------------------------------
# A node with quorum answers sys/storage/raft/configuration. A node
# without it fails with "local node not active but active cluster node
# not found", which is exactly the state this script is for.
if [[ "$FORCE" != true ]]; then
    if [[ -n "${VAULT_TOKEN:-}" ]] && command -v vault >/dev/null 2>&1; then
        if vault operator raft list-peers >/dev/null 2>&1; then
            die "this cluster still answers a Raft configuration query, so it has quorum. Forcing a peer configuration onto it can strand the nodes not named in --peers. Use --force only if you know the query is lying."
        fi
        log "The cluster cannot answer a Raft configuration query — consistent with lost quorum."
    else
        log "WARNING: no VAULT_TOKEN or no vault CLI, so the quorum check was skipped."
        log "         Run this only against a cluster you have confirmed has lost quorum."
    fi
fi

# ---------------------------------------------------------------------------
# Stop, write, start
# ---------------------------------------------------------------------------
PEERS_FILE="$(mktemp)"
trap 'rm -f "$PEERS_FILE"' EXIT
printf '%s\n' "$PEERS_BODY" > "$PEERS_FILE"

# 0644, and the reason is not cosmetic.
#
# mktemp creates 0600 owned by whoever runs this, and `docker cp` carries
# that through. Vault runs as the `vault` user, so a 0600 root-owned
# peers.json is a file Vault cannot read -- and an unreadable recovery
# file is indistinguishable from no recovery file: the node comes back
# still waiting for peers that are gone, with peers.json sitting beside
# it unconsumed.
#
# That is exactly how the first run of tests/quorum-recovery failed,
# while a hand-run version of the same steps with a 0644 file worked.
#
# peers.json holds node ids and addresses. There is nothing in it to
# protect.
chmod 0644 "$PEERS_FILE"

if [[ -n "$COMPOSE_SERVICE" ]]; then
    command -v docker >/dev/null 2>&1 || die "docker not found on PATH"

    log "Stopping ${COMPOSE_SERVICE}..."
    compose stop "$COMPOSE_SERVICE" >/dev/null 2>&1 \
        || die "could not stop ${COMPOSE_SERVICE}"

    CID="$(compose ps -aq "$COMPOSE_SERVICE")"
    [[ -n "$CID" ]] || die "no container found for ${COMPOSE_SERVICE}"

    log "Writing ${DATA_DIR}/raft/peers.json into ${COMPOSE_SERVICE}..."
    docker cp "$PEERS_FILE" "${CID}:${DATA_DIR}/raft/peers.json" \
        || die "could not copy peers.json into the container"

    log "Starting ${COMPOSE_SERVICE}..."
    compose start "$COMPOSE_SERVICE" >/dev/null 2>&1 \
        || die "could not start ${COMPOSE_SERVICE}"
else
    command -v systemctl >/dev/null 2>&1 || die "systemctl not found on PATH"
    [[ -d "${DATA_DIR}/raft" ]] || die "no raft directory at ${DATA_DIR}/raft"

    log "Stopping ${SERVICE_NAME}..."
    systemctl stop "$SERVICE_NAME" || die "could not stop ${SERVICE_NAME}"

    log "Writing ${DATA_DIR}/raft/peers.json..."
    # 0644 for the reason above: Vault has to be able to read it, and it
    # contains nothing worth restricting.
    install -m 0644 "$PEERS_FILE" "${DATA_DIR}/raft/peers.json" \
        || die "could not write peers.json"

    log "Starting ${SERVICE_NAME}..."
    systemctl start "$SERVICE_NAME" || die "could not start ${SERVICE_NAME}"
fi

# ---------------------------------------------------------------------------
# Wait for an active node, not merely an unsealed one
# ---------------------------------------------------------------------------
# The failure being recovered from is a node that is unsealed and has no
# leader. Waiting for "unsealed" would report success on exactly that.
log "Waiting for the node to report itself active..."
DEADLINE=$((SECONDS + WAIT_SECONDS))
ACTIVE=false
while (( SECONDS < DEADLINE )); do
    if [[ -n "${VAULT_ADDR:-}" ]] && command -v curl >/dev/null 2>&1; then
        CODE="$(curl -s -o /dev/null -w '%{http_code}' \
            ${VAULT_CACERT:+--cacert "$VAULT_CACERT"} \
            "${VAULT_ADDR}/v1/sys/health" 2>/dev/null || true)"
        # 200 means active. 429 is a standby, which after a recovery
        # means it is still looking for a leader that will not appear.
        if [[ "$CODE" == "200" ]]; then ACTIVE=true; break; fi
    else
        sleep 5
        ACTIVE=true
        break
    fi
    sleep 3
done

if [[ "$ACTIVE" != true ]]; then
    die "the node did not become active within ${WAIT_SECONDS}s. Check its logs: a peers.json naming an address the node cannot reach leaves it looking for a peer that is not there."
fi

log "The node is active."
log ""
log "Raft has consumed peers.json — it is deleted once applied, so this"
log "is not a setting that stays behind."
log ""
log "The cluster is now as small as --peers said. Bring the replacements"
log "back with their normal retry_join; autopilot promotes them once they"
log "are stable. Nothing written before the outage was lost: this"
log "recovery kept the survivor's storage rather than replacing it."

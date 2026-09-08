#!/usr/bin/env bash
#
# migrate-seal.sh — Move a cluster between seal types
#
# Usage:
#   ./migrate-seal.sh --to shamir  --keys-file <path> --compose-services <a,b,c>
#   ./migrate-seal.sh --to transit --keys-file <path> --compose-services <a,b,c>
#
# Options:
#   --to <shamir|transit>       Seal type to end up on.
#   --keys-file <path>          JSON holding recovery_keys_b64 — the shares
#                               that unseal the cluster today. After the
#                               migration they are the other kind of key;
#                               the values do not change.
#   --compose-services <list>   Comma-separated compose services, every
#                               node in the cluster. All of them, not the
#                               leader: see below.
#   --config <path>             Config file inside each container
#                               (default: /vault/config/vault.hcl).
#   --skip-snapshot             Do not take a Raft snapshot first. Refused
#                               unless --i-have-a-backup is also given.
#   --i-have-a-backup           Acknowledge what --skip-snapshot gives up.
#
# Examples:
#   export VAULT_ADDR=https://127.0.0.1:8200
#   ./migrate-seal.sh --to shamir --keys-file docker/dev/.recovery-keys.json \
#       --compose-services vault-0,vault-1,vault-2
#
# WHAT THIS IS AND WHY IT IS NOT AN SSH SCRIPT
#
# Changing seal type is the operation most likely to leave a cluster that
# will not unseal. Every step below was established by running it against
# a real three-node cluster and watching what happened, because the
# documented procedure and the observed one differ in ways that matter.
#
# It drives the local compose profile only. The same sequence on real
# nodes is an edit to /etc/vault.d/vault.hcl and a systemctl restart on
# each host, and it is written out in docs/auto-unseal.md — deliberately
# as a runbook rather than as an untested code path in here. For an
# operation whose failure mode is "nobody can unseal this cluster again",
# shipping SSH orchestration that has never been run is worse than
# shipping the steps.
#
# THE SEQUENCE, AND THE FOUR THINGS THAT SURPRISED ME
#
#   1. Every node keeps running. The obvious instinct is to stop the
#      standbys first, the way you would for a maintenance window. Do not:
#      stopping two of three costs quorum, the migrating node never
#      acquires leadership, and the migration therefore never finalises.
#      The first attempt at this left a cluster unsealed, leaderless and
#      half-migrated.
#
#   2. Every node needs -migrate, not just the active one. A plain unseal
#      on a standby returns
#          500  migrate option not provided and seal migration is in progress
#      which reads like the node is broken and is really the node telling
#      you it is doing what you asked.
#
#   3. It is not finished when the last node unseals. sys/seal-status
#      reports migration=true until a leader is elected and finalises it.
#      This script waits for that, because the next step is what makes it
#      matter.
#
#   4. A node restarted while migration=true will NOT auto-unseal, even
#      with a working autoseal stanza. It logs
#          entering seal migration mode; Vault will not automatically
#          unseal even if using an autoseal
#      and comes back sealed. So the obvious way to check the migration
#      worked — restart a node and see if it auto-unseals — breaks it if
#      you do it too early, and the node looks broken rather than early.
#
# DELIBERATE BEHAVIOURS
#
#   A Raft snapshot is taken first unless you refuse it in two flags.
#   Everything else here is recoverable by unsealing again; a barrier
#   that half-migrated is recoverable from a snapshot and not otherwise.
#
#   The current seal type is read before anything is edited, and a
#   cluster already on the target type is refused rather than migrated to
#   where it already is.
#
#   Nothing is restarted after the unseal loop. See surprise 4.
#
# Requirements: vault, jq, curl, docker compose. VAULT_ADDR pointing at
# the first service in --compose-services, and VAULT_TOKEN for the
# snapshot unless it is skipped.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
COMPOSE_FILE="${REPO_ROOT}/docker/dev/docker-compose.yml"

TARGET=""
KEYS_FILE=""
SERVICES=""
CONFIG="/vault/config/vault.hcl"
SKIP_SNAPSHOT=false
ACKNOWLEDGED=false

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

log()  { printf '[migrate-seal] %s\n' "$*" >&2; }
warn() { printf '\033[33m[migrate-seal] %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[31m[migrate-seal] ERROR: %s\033[0m\n' "$*" >&2; exit 1; }

usage() {
    grep '^#' "$0" | sed -e '1d' -e 's/^# \{0,1\}//'
    exit 2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --to)                TARGET="$2"; shift 2 ;;
        --keys-file)         KEYS_FILE="$2"; shift 2 ;;
        --compose-services)  SERVICES="$2"; shift 2 ;;
        --config)            CONFIG="$2"; shift 2 ;;
        --skip-snapshot)     SKIP_SNAPSHOT=true; shift ;;
        --i-have-a-backup)   ACKNOWLEDGED=true; shift ;;
        -h|--help)           usage ;;
        *) die "Unknown argument: $1" ;;
    esac
done

[[ "$TARGET" == "shamir" || "$TARGET" == "transit" ]] \
    || die "--to must be shamir or transit"
[[ -n "$KEYS_FILE" ]] || die "--keys-file is required"
[[ -f "$KEYS_FILE" ]] || die "keys file not found: ${KEYS_FILE}"
[[ -n "$SERVICES" ]] || die "--compose-services is required"
[[ -n "${VAULT_ADDR:-}" ]] || die "VAULT_ADDR is not set"

for dep in vault jq curl docker; do
    command -v "$dep" >/dev/null 2>&1 || die "${dep} not found on PATH"
done

if [[ "$SKIP_SNAPSHOT" == true && "$ACKNOWLEDGED" == false ]]; then
    die "--skip-snapshot removes the only thing that recovers a half-migrated
       barrier. Every other failure here is fixed by unsealing again; that
       one is not. Pass --i-have-a-backup as well if you have one already."
fi

IFS=',' read -r -a NODES <<< "$SERVICES"
[[ ${#NODES[@]} -gt 0 ]] || die "--compose-services parsed to nothing"

mapfile -t KEYS < <(jq -r '.recovery_keys_b64[]? // empty' "$KEYS_FILE")
[[ ${#KEYS[@]} -gt 0 ]] || die "no recovery_keys_b64 found in ${KEYS_FILE}"

THRESHOLD="$(jq -r '.recovery_keys_threshold // 3' "$KEYS_FILE")"
[[ ${#KEYS[@]} -ge "$THRESHOLD" ]] \
    || die "need ${THRESHOLD} shares, found ${#KEYS[@]} in ${KEYS_FILE}"

compose() { docker compose -f "$COMPOSE_FILE" "$@"; }

# Read through the API rather than the CLI: `vault status` renders HA
# fields the JSON does not contain, and this repository has been caught
# by that difference before.
# Note the absence of `// empty` here. jq's alternative operator treats
# false as absent, so `.migration // empty` yields "" for a migration
# that has finished — and a wait loop written that way can never
# succeed. It reported a three-minute timeout against a cluster that had
# finalised in seconds.
seal_field() {  # seal_field <field>
    curl -sk ${VAULT_CACERT:+--cacert "$VAULT_CACERT"} --max-time 5 \
        "${VAULT_ADDR}/v1/sys/seal-status" 2>/dev/null | jq -r ".${1}"
}

# ---------------------------------------------------------------------------
# Where are we now
# ---------------------------------------------------------------------------

CURRENT="$(seal_field type)"
[[ -n "$CURRENT" && "$CURRENT" != "null" ]] || die "could not read sys/seal-status at ${VAULT_ADDR}"

log "Cluster is sealed with: ${CURRENT}"

# A migration already in progress is the state this script is most
# needed in, not a reason to refuse. It is what an interrupted run
# leaves behind, and what the operator is staring at when a node was
# restarted too early and came back sealed. In that state the config is
# already correct and the nodes already report the target type, so both
# guards below would fire on a cluster that needs finishing rather than
# starting.
RESUME=false
if [[ "$(seal_field migration)" == "true" ]]; then
    RESUME=true
    log "A seal migration is already in progress; resuming it."
    [[ "$CURRENT" == "$TARGET" ]] || die "the migration in progress is to ${CURRENT}, not ${TARGET}.
       Finish or cancel that one first: a cluster cannot migrate two
       ways at once, and restarting into a third seal config is how a
       barrier ends up unreadable."
else
    [[ "$CURRENT" != "$TARGET" ]] \
        || die "already on ${TARGET}; nothing to migrate"

    if [[ "$(seal_field sealed)" == "true" ]]; then
        die "the cluster is sealed and no migration is in progress.
       Migration starts from a running, unsealed cluster: unseal it
       first, then run this."
    fi
fi

# ---------------------------------------------------------------------------
# The snapshot
# ---------------------------------------------------------------------------

if [[ "$RESUME" == true ]]; then
    warn "Resuming, so no snapshot: a sealed cluster cannot produce one,"
    warn "and the snapshot that mattered was the one taken before the run"
    warn "that was interrupted."
elif [[ "$SKIP_SNAPSHOT" == true ]]; then
    warn "Skipping the snapshot, as instructed."
else
    [[ -n "${VAULT_TOKEN:-}" ]] \
        || die "VAULT_TOKEN is needed to take the snapshot this script insists on.
       Set it, or pass --skip-snapshot --i-have-a-backup."
    SNAP="${WORK}/pre-migration.snap"
    log "Taking a Raft snapshot first..."
    SNAP_ERR="$(vault operator raft snapshot save "$SNAP" 2>&1)" \
        || die "snapshot failed, so the migration is refused:
       ${SNAP_ERR}"
    KEEP="./pre-seal-migration-$(date -u '+%Y%m%dT%H%M%SZ').snap"
    cp "$SNAP" "$KEEP" || die "could not keep the snapshot at ${KEEP}"
    chmod 0600 "$KEEP"
    log "Snapshot kept at ${KEEP}"
fi

# ---------------------------------------------------------------------------
# Rewrite the seal stanza on every node
# ---------------------------------------------------------------------------
#
# awk rather than sed -i: the image is Alpine, busybox sed has no reliable
# `a\`, and getting this wrong writes a config Vault will not parse — on
# every node at once.

if [[ "$RESUME" == true ]]; then
    log "Resuming: the config is already in place and the nodes are already"
    log "restarted, so neither is repeated. Restarting now would put every"
    log "node back into migration mode for no reason."
else
log "Rewriting the seal stanza on ${#NODES[@]} node(s)..."
for n in "${NODES[@]}"; do
    if [[ "$TARGET" == "shamir" ]]; then
        compose exec -T "$n" sh -c "awk '/^seal \"transit\" \{/{print; print \"  disabled = \\\"true\\\"\"; next} 1' ${CONFIG} > /tmp/seal.hcl && cp /tmp/seal.hcl ${CONFIG}" \
            || die "could not edit the config on ${n}"
    else
        compose exec -T "$n" sh -c "grep -v 'disabled = \"true\"' ${CONFIG} > /tmp/seal.hcl && cp /tmp/seal.hcl ${CONFIG}" \
            || die "could not edit the config on ${n}"
    fi
    log "  ${n}: seal stanza set for ${TARGET}"
done

# ---------------------------------------------------------------------------
# Restart everything at once, and keep quorum
# ---------------------------------------------------------------------------

log "Restarting every node (quorum is kept; see the header)..."
compose restart "${NODES[@]}" >/dev/null 2>&1 \
    || die "restart failed"

log "Waiting for the listeners to come back..."
for _ in $(seq 1 60); do
    curl -sk ${VAULT_CACERT:+--cacert "$VAULT_CACERT"} --max-time 3 \
        "${VAULT_ADDR}/v1/sys/seal-status" >/dev/null 2>&1 && break
    sleep 2
done
curl -sk ${VAULT_CACERT:+--cacert "$VAULT_CACERT"} --max-time 3 \
    "${VAULT_ADDR}/v1/sys/seal-status" >/dev/null 2>&1 \
    || die "${VAULT_ADDR} never came back after the restart"

NOW="$(seal_field type)"
log "Nodes are back, reporting seal type: ${NOW}"
fi

# ---------------------------------------------------------------------------
# Unseal every node with -migrate
# ---------------------------------------------------------------------------

log "Unsealing each node with -migrate..."
for n in "${NODES[@]}"; do
    UNSEALED=false
    for ((i = 0; i < THRESHOLD; i++)); do
        OUT="$(compose exec -T "$n" vault operator unseal -migrate "${KEYS[$i]}" 2>&1)" || {
            # Worth quoting back: this exact error is what a plain unseal
            # produces, and it is the most likely thing to be pasted into
            # a search box during an outage.
            die "${n} rejected share $((i + 1)):
       ${OUT}"
        }
        if compose exec -T "$n" vault status -format=json 2>/dev/null \
            | jq -e '.sealed == false' >/dev/null 2>&1; then
            UNSEALED=true
            break
        fi
    done
    [[ "$UNSEALED" == true ]] || die "${n} did not unseal after ${THRESHOLD} shares"
    log "  ${n}: unsealed"
done

# ---------------------------------------------------------------------------
# Wait for the migration to finalise
# ---------------------------------------------------------------------------
#
# This is the part that makes the difference between a migrated cluster
# and one that looks migrated. Until a leader finalises it, every node is
# still in migration mode and will not auto-unseal on restart.

log "Waiting for a leader to finalise the migration..."
FINALISED=false
for _ in $(seq 1 60); do
    if [[ "$(seal_field migration)" == "false" ]]; then
        FINALISED=true
        break
    fi
    sleep 3
done

if [[ "$FINALISED" != true ]]; then
    die "the migration has not finalised: sys/seal-status still reports
       migration=true after three minutes.

       Do NOT restart any node while this is true — a node restarted in
       migration mode will not auto-unseal even with a working seal
       stanza, and comes back sealed looking broken.

       Check that a leader was elected (sys/leader) and that quorum is
       intact; the usual cause is too few nodes running."
fi

FINAL="$(seal_field type)"
log "Migration finalised. Seal type is now: ${FINAL}"

[[ "$FINAL" == "$TARGET" ]] \
    || die "expected ${TARGET}, got ${FINAL}"

if [[ "$TARGET" == "shamir" ]]; then
    log ""
    log "The shares in ${KEYS_FILE} are now UNSEAL keys, not recovery keys."
    log "Every restart from here needs a quorum of them, by hand."
else
    log ""
    log "The shares in ${KEYS_FILE} are now RECOVERY keys again."
    log "Nodes auto-unseal on restart; the shares are for generate-root and rekey."
fi

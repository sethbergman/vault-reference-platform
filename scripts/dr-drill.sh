#!/usr/bin/env bash
#
# dr-drill.sh — Prove a Raft snapshot can actually be restored
#
# Usage:
#   ./dr-drill.sh [--keep-running]
#
# What it does, against the local Docker Compose profile:
#   1. Brings up a Vault node and seeds a known "canary" secret.
#   2. Takes a Raft snapshot and copies it out to the host.
#   3. Destroys the node AND its storage — an actual loss, not a restart.
#   4. Brings up a fresh, empty node and initializes it.
#   5. Restores the snapshot into it.
#   6. Verifies the canary secret came back, using the ORIGINAL root
#      token, and that the throwaway token from step 4 no longer works.
#
# Why step 6 is the real test:
#   A restore that silently did nothing would still leave a healthy,
#   unsealed cluster. Reading back a value written before the disaster
#   is what distinguishes "restored" from "came up empty". And the
#   pre-disaster root token working again is the proof that the restored
#   data really replaced what was there, since that token was never
#   valid on the new node.
#
# What this drill deliberately does NOT destroy:
#   vault-unseal, which holds the Transit key the snapshot's data is
#   encrypted under. Losing that alongside the cluster would leave the
#   snapshot mathematically undecryptable. That is the single most
#   important thing to get right about backing up an auto-unsealed
#   Vault: the snapshot is only half of what a restore needs. In a cloud
#   deployment the equivalent is the KMS key, which must survive — and
#   be backed up — independently of the cluster.
#
# Requirements:
#   - docker compose, curl, jq
#   - Run from a clean state; this tears the local cluster down.

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
KEEP_RUNNING=false
NODE="vault-0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_DIR="${SCRIPT_DIR}/../docker/dev"
TLS_DIR="${COMPOSE_DIR}/tls"
SNAPSHOT_HOST_PATH=""

CANARY_PATH="secret/dr-drill/canary"
CANARY_VALUE="written-before-the-disaster"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()  { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }
die()  { log "ERROR: $*"; exit 1; }

usage() {
    grep '^#' "$0" | sed -e '1d' -e 's/^# \{0,1\}//'
    exit 1
}

compose() {
    docker compose --project-directory "$COMPOSE_DIR" -f "${COMPOSE_DIR}/docker-compose.yml" "$@"
}

cleanup() {
    [[ -n "$SNAPSHOT_HOST_PATH" && -f "$SNAPSHOT_HOST_PATH" ]] && rm -f "$SNAPSHOT_HOST_PATH"
    if [[ "$KEEP_RUNNING" == false ]]; then
        log "Tearing down the local cluster..."
        compose down -v >&2 2>/dev/null || true
    fi
}
trap cleanup EXIT

while [[ $# -gt 0 ]]; do
    case "$1" in
        --keep-running) KEEP_RUNNING=true; shift ;;
        -h|--help)      usage ;;
        *) die "Unknown argument: $1" ;;
    esac
done

command -v docker >/dev/null 2>&1 || die "docker not found on PATH"
command -v jq     >/dev/null 2>&1 || die "jq not found on PATH"

# ---------------------------------------------------------------------------
# Step 1: Stand up a cluster and write something worth losing
# ---------------------------------------------------------------------------
log "=== Step 1: bring up the cluster and seed a canary secret ==="
ROOT_TOKEN="$("${SCRIPT_DIR}/bootstrap-dev-cluster.sh" --nodes "$NODE")" \
    || die "Failed to bring up the cluster"

# Read the Transit token out of the running container. The recreated node
# in step 4 needs the same one, and it only exists in the container's
# environment — bootstrap-dev-cluster.sh mints it and doesn't persist it.
TRANSIT_TOKEN="$(compose exec -T "$NODE" printenv VAULT_TRANSIT_TOKEN)" \
    || die "Could not read VAULT_TRANSIT_TOKEN from ${NODE}"
[[ -n "$TRANSIT_TOKEN" ]] || die "VAULT_TRANSIT_TOKEN is empty"

compose exec -T -e VAULT_TOKEN="$ROOT_TOKEN" "$NODE" \
    vault secrets enable -path=secret -version=2 kv >/dev/null \
    || die "Failed to enable the KV engine"

compose exec -T -e VAULT_TOKEN="$ROOT_TOKEN" "$NODE" \
    vault kv put "$CANARY_PATH" value="$CANARY_VALUE" >/dev/null \
    || die "Failed to write the canary secret"
log "Canary written to ${CANARY_PATH}"

# ---------------------------------------------------------------------------
# Step 2: Snapshot, and get it off the machine that is about to die
# ---------------------------------------------------------------------------
log "=== Step 2: take a Raft snapshot ==="
compose exec -T -e VAULT_TOKEN="$ROOT_TOKEN" "$NODE" \
    vault operator raft snapshot save /tmp/dr-drill.snap >/dev/null \
    || die "Failed to take a snapshot"

# A snapshot sitting inside the node it was taken from protects against
# nothing.
SNAPSHOT_HOST_PATH="$(mktemp -t dr-drill-XXXXXX.snap)"
compose cp "${NODE}:/tmp/dr-drill.snap" "$SNAPSHOT_HOST_PATH" >&2 \
    || die "Failed to copy the snapshot out of the container"

SNAP_SIZE="$(wc -c < "$SNAPSHOT_HOST_PATH" | tr -d ' ')"
[[ "$SNAP_SIZE" -gt 0 ]] || die "Snapshot is empty"
log "Snapshot saved to the host (${SNAP_SIZE} bytes)"

# ---------------------------------------------------------------------------
# Step 3: Destroy the node and its storage
# ---------------------------------------------------------------------------
log "=== Step 3: destroy the node (simulated disaster) ==="
# -s stops it, -v removes anonymous volumes, -f skips the prompt. This
# takes the Raft data with it; a plain restart would prove nothing.
# vault-unseal is deliberately left alone — see the header.
compose rm -sfv "$NODE" >&2 || die "Failed to remove ${NODE}"
log "${NODE} and its storage are gone."

# ---------------------------------------------------------------------------
# Step 4: Bring up a fresh, empty node
# ---------------------------------------------------------------------------
log "=== Step 4: bring up a replacement node ==="
export VAULT_TRANSIT_TOKEN="$TRANSIT_TOKEN"
compose up -d "$NODE" >&2 || die "Failed to start a replacement ${NODE}"

for i in $(seq 1 30); do
    if curl --cacert "${TLS_DIR}/ca.crt" -fsS -o /dev/null "https://127.0.0.1:8200/v1/sys/seal-status"; then
        log "Replacement node is responding."
        break
    fi
    log "  waiting for ${NODE}... (${i}/30)"
    sleep 2
done

# Confirm it really is empty — if this node still had the old data, the
# rest of the drill would prove nothing.
INITIALIZED="$(curl --cacert "${TLS_DIR}/ca.crt" -fsS "https://127.0.0.1:8200/v1/sys/seal-status" | jq -r '.initialized')"
[[ "$INITIALIZED" == "false" ]] \
    || die "Replacement node is already initialized — the disaster did not actually destroy its storage"
log "Confirmed: the replacement node is empty."

TEMP_INIT_JSON="$(compose exec -T "$NODE" vault operator init -format=json)" \
    || die "Failed to initialize the replacement node"
TEMP_TOKEN="$(jq -r '.root_token' <<< "$TEMP_INIT_JSON")"

for i in $(seq 1 30); do
    SEALED="$(compose exec -T "$NODE" vault status -format=json 2>/dev/null | jq -r '.sealed' 2>/dev/null || echo true)"
    [[ "$SEALED" == "false" ]] && break
    log "  waiting for auto-unseal... (${i}/30)"
    sleep 2
done
[[ "$SEALED" == "false" ]] || die "Replacement node did not auto-unseal"
log "Replacement node initialized and auto-unsealed."

# ---------------------------------------------------------------------------
# Step 5: Restore
# ---------------------------------------------------------------------------
log "=== Step 5: restore the snapshot ==="
# Piped in through exec rather than `compose cp`. cp writes the file as
# root, and Vault runs as the unprivileged vault user, so it could not
# read its own restore file — "permission denied" on /tmp/restore.snap.
# exec runs as the image's USER, so the file arrives owned by vault.
compose exec -T "$NODE" sh -c 'cat > /tmp/restore.snap' < "$SNAPSHOT_HOST_PATH" \
    || die "Failed to copy the snapshot into the replacement node"

# -force because the snapshot came from a different cluster instance than
# the one now running; without it Vault refuses on the cluster-ID
# mismatch. The seal is the same, which is what actually has to match.
compose exec -T -e VAULT_TOKEN="$TEMP_TOKEN" "$NODE" \
    vault operator raft snapshot restore -force /tmp/restore.snap >&2 \
    || die "Snapshot restore failed"
log "Restore completed."

# Vault needs a moment to reload state and re-elect after a restore.
sleep 5

# ---------------------------------------------------------------------------
# Step 6: Verify the data actually came back
# ---------------------------------------------------------------------------
log "=== Step 6: verify ==="

# The pre-disaster token was never valid on the replacement node. If it
# works now, the restored data genuinely replaced what was there.
RESTORED_VALUE=""
for i in $(seq 1 15); do
    RESTORED_VALUE="$(compose exec -T -e VAULT_TOKEN="$ROOT_TOKEN" "$NODE" \
        vault kv get -field=value "$CANARY_PATH" 2>/dev/null || true)"
    [[ -n "$RESTORED_VALUE" ]] && break
    log "  waiting for the restored cluster to serve reads... (${i}/15)"
    sleep 2
done

[[ "$RESTORED_VALUE" == "$CANARY_VALUE" ]] \
    || die "Canary mismatch — expected '${CANARY_VALUE}', got '${RESTORED_VALUE:-<nothing>}'"
log "Canary secret recovered intact."

# And the throwaway token from the replacement node should be dead, since
# the restore replaced the token store along with everything else.
if compose exec -T -e VAULT_TOKEN="$TEMP_TOKEN" "$NODE" \
        vault token lookup >/dev/null 2>&1; then
    die "The replacement node's own root token still works — the restore did not replace the token store"
fi
log "Pre-restore token correctly invalidated."

log ""
log "DR drill passed: snapshot -> total loss -> restore -> data verified."
log "Reminder: this only works because vault-unseal (the Transit key)"
log "survived. Back up the unseal key material separately from the"
log "snapshots, or the snapshots are unreadable."

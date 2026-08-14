#!/usr/bin/env bash
#
# bootstrap-dev-cluster.sh — Bring up the local Docker Compose Vault cluster
#
# Usage:
#   ./bootstrap-dev-cluster.sh [--nodes vault-0,vault-1,vault-2]
#
# Example:
#   ./bootstrap-dev-cluster.sh                        # full 3-node cluster
#   ./bootstrap-dev-cluster.sh --nodes vault-0         # single node, e.g. CI
#
# What it does:
#   1. Starts vault-unseal (docker/vault-unseal) and brings it up the normal,
#      manual way: init with a single Shamir key share, unseal, enable the
#      Transit secrets engine, create an auto-unseal key, and mint an orphan
#      periodic token scoped to just that key's encrypt/decrypt paths.
#   2. Starts the requested main-cluster nodes (docker/vault) with that
#      token exported as VAULT_TRANSIT_TOKEN, so docker-compose.yml's env
#      interpolation passes it through to each container. Each node's
#      docker-entrypoint.sh substitutes it into vault.hcl's seal "transit"
#      stanza before Vault starts.
#   3. Initializes the first requested node. Because auto-unseal is
#      configured, it unseals itself immediately — no manual unseal step.
#   4. If more than one node was requested, waits for the rest to join the
#      Raft cluster (via retry_join) and for Vault's autopilot to promote
#      them all to voters.
#
# This is the single source of truth for bringing the dev cluster up — both
# `make deploy` and CI call this script, so neither can drift from what the
# other actually exercises.
#
# Requirements:
#   - docker compose, curl, jq on the machine running this
#
# Output:
#   Log messages go to stderr. The root token is the only thing printed to
#   stdout, so it can be captured directly: ROOT_TOKEN=$(./bootstrap-dev-cluster.sh)
#   It's a fresh, throwaway credential for a local/CI Vault instance — no
#   different in sensitivity from the Shamir keys this profile already uses.

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
NODES="vault-0,vault-1,vault-2"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_DIR="${SCRIPT_DIR}/../docker/dev"

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

wait_for() {
    local url="$1" label="$2" attempts="${3:-30}" delay="${4:-2}"
    for i in $(seq 1 "$attempts"); do
        if curl -fsS -o /dev/null "$url"; then
            log "${label} is responding."
            return 0
        fi
        log "  waiting for ${label}... (${i}/${attempts})"
        sleep "$delay"
    done
    log "----- docker compose logs ${label} (last 50 lines) -----"
    compose logs --tail=50 "$label" >&2 || true
    log "----- end logs -----"
    die "${label} did not respond after $((attempts * delay))s"
}

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --nodes)  NODES="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) die "Unknown argument: $1" ;;
    esac
done

IFS=',' read -r -a NODE_LIST <<< "$NODES"
[[ ${#NODE_LIST[@]} -ge 1 ]] || die "No nodes parsed from --nodes"
LEADER="${NODE_LIST[0]}"

# ---------------------------------------------------------------------------
# Step 1: Bring up and bootstrap vault-unseal
# ---------------------------------------------------------------------------
log "Starting vault-unseal..."
compose up -d --build vault-unseal
wait_for "http://127.0.0.1:8300/v1/sys/seal-status" "vault-unseal"

log "Initializing vault-unseal..."
INIT_JSON="$(compose exec -T vault-unseal vault operator init -key-shares=1 -key-threshold=1 -format=json)"
UNSEAL_KEY="$(jq -r '.unseal_keys_b64[0]' <<< "$INIT_JSON")"
UNSEAL_ROOT_TOKEN="$(jq -r '.root_token' <<< "$INIT_JSON")"

log "Unsealing vault-unseal..."
compose exec -T vault-unseal vault operator unseal "$UNSEAL_KEY" >/dev/null

log "Enabling the Transit secrets engine and creating the auto-unseal key..."
compose exec -T -e VAULT_TOKEN="$UNSEAL_ROOT_TOKEN" vault-unseal \
    vault secrets enable -path=transit transit >/dev/null
compose exec -T -e VAULT_TOKEN="$UNSEAL_ROOT_TOKEN" vault-unseal \
    vault write -f transit/keys/autounseal >/dev/null

log "Writing the auto-unseal policy and minting a scoped token..."
compose exec -T -e VAULT_TOKEN="$UNSEAL_ROOT_TOKEN" vault-unseal \
    vault policy write autounseal - >/dev/null <<'EOF'
path "transit/encrypt/autounseal" {
  capabilities = ["update"]
}
path "transit/decrypt/autounseal" {
  capabilities = ["update"]
}
EOF
VAULT_TRANSIT_TOKEN="$(compose exec -T -e VAULT_TOKEN="$UNSEAL_ROOT_TOKEN" vault-unseal \
    vault token create -orphan -period=768h -policy=autounseal -field=token)"
export VAULT_TRANSIT_TOKEN
log "vault-unseal is ready."

# ---------------------------------------------------------------------------
# Step 2: Bring up the requested main-cluster nodes
# ---------------------------------------------------------------------------
log "Starting ${NODES}..."
compose up -d --build "${NODE_LIST[@]}"
wait_for "http://127.0.0.1:8200/v1/sys/seal-status" "$LEADER"

# ---------------------------------------------------------------------------
# Step 3: Initialize the leader — it auto-unseals itself immediately
# ---------------------------------------------------------------------------
log "Initializing ${LEADER}..."
LEADER_INIT_JSON="$(compose exec -T "$LEADER" vault operator init -format=json)"
ROOT_TOKEN="$(jq -r '.root_token' <<< "$LEADER_INIT_JSON")"

log "Waiting for ${LEADER} to auto-unseal..."
for i in $(seq 1 30); do
    SEALED="$(compose exec -T "$LEADER" vault status -format=json 2>/dev/null | jq -r '.sealed' 2>/dev/null || echo true)"
    [[ "$SEALED" == "false" ]] && { log "${LEADER} is unsealed."; break; }
    log "  still sealed... (${i}/30)"
    sleep 2
done
[[ "$SEALED" == "false" ]] || die "${LEADER} did not auto-unseal in time"

# ---------------------------------------------------------------------------
# Step 4: If clustering, wait for the rest to join and become voters
# ---------------------------------------------------------------------------
if [[ ${#NODE_LIST[@]} -gt 1 ]]; then
    EXPECTED=${#NODE_LIST[@]}
    log "Waiting for all ${EXPECTED} nodes to join and auto-unseal as raft voters..."
    for i in $(seq 1 60); do
        RESULT="$(compose exec -T -e VAULT_TOKEN="$ROOT_TOKEN" "$LEADER" \
            vault operator raft list-peers -format=json 2>/dev/null || true)"
        TOTAL="$(jq '.data.config.servers | length' <<< "$RESULT" 2>/dev/null || echo 0)"
        VOTERS="$(jq '[.data.config.servers[] | select(.voter == true)] | length' <<< "$RESULT" 2>/dev/null || echo 0)"
        log "  peers: ${TOTAL:-0}, voters: ${VOTERS:-0} (${i}/60)"
        if [[ "$TOTAL" == "$EXPECTED" && "$VOTERS" == "$EXPECTED" ]]; then
            log "All ${EXPECTED} nodes have joined as voters."
            compose exec -T -e VAULT_TOKEN="$ROOT_TOKEN" "$LEADER" vault operator raft list-peers >&2
            break
        fi
        sleep 3
    done
    [[ "$TOTAL" == "$EXPECTED" && "$VOTERS" == "$EXPECTED" ]] || die "Cluster did not converge to ${EXPECTED} voters in time"
fi

log "Cluster is up. Root token is a fresh dev-only credential, printed to stdout."
echo "$ROOT_TOKEN"

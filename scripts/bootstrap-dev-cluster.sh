#!/usr/bin/env bash
#
# bootstrap-dev-cluster.sh — Bring up the local Docker Compose Vault cluster
#
# Usage:
#   ./bootstrap-dev-cluster.sh [--nodes vault-0,vault-1,vault-2]
#                              [--with-monitoring] [--with-oidc]
#                              [--with-database]
#
# Example:
#   ./bootstrap-dev-cluster.sh                        # full 3-node cluster
#   ./bootstrap-dev-cluster.sh --nodes vault-0         # single node, e.g. CI
#   ./bootstrap-dev-cluster.sh --with-monitoring       # + Prometheus/Grafana
#   ./bootstrap-dev-cluster.sh --with-oidc             # + Dex for human login
#   ./bootstrap-dev-cluster.sh --with-database         # + Postgres for dynamic creds
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
#   5. With --with-monitoring, also starts Prometheus and Grafana and waits
#      until Prometheus reports every Vault node as an up scrape target —
#      so a green run means metrics are genuinely flowing, not just that
#      the containers started.
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
WITH_MONITORING=false
WITH_OIDC=false
WITH_DATABASE=false
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_DIR="${SCRIPT_DIR}/../docker/dev"
TLS_DIR="${COMPOSE_DIR}/tls"

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

# Every Vault endpoint is TLS now. This wrapper passes the dev CA so no
# call has to reach for --insecure, which would make the checks pass
# while verifying nothing — the failure mode that makes a TLS rollout
# look finished when it isn't.
vcurl() {
    curl --cacert "${TLS_DIR}/ca.crt" "$@"
}

wait_for() {
    local url="$1" label="$2" attempts="${3:-30}" delay="${4:-2}"
    for i in $(seq 1 "$attempts"); do
        # --cacert is harmless against the plain-HTTP endpoints (Dex,
        # Prometheus) and required for the Vault ones.
        if curl --cacert "${TLS_DIR}/ca.crt" -fsS -o /dev/null "$url"; then
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
        --with-monitoring) WITH_MONITORING=true; shift ;;
        --with-oidc) WITH_OIDC=true; shift ;;
        --with-database) WITH_DATABASE=true; shift ;;
        -h|--help) usage ;;
        *) die "Unknown argument: $1" ;;
    esac
done

# ---------------------------------------------------------------------------
# Step 0: TLS material
# ---------------------------------------------------------------------------
# Vault refuses to start without its certificate, so this has to happen
# before anything is brought up. The script is idempotent — it does
# nothing if the certificates already exist.
log "Ensuring development TLS certificates exist..."
"${SCRIPT_DIR}/generate-dev-certs.sh" >&2 || die "Failed to generate TLS certificates"
[[ -f "${TLS_DIR}/ca.crt" ]] || die "No CA certificate at ${TLS_DIR}/ca.crt"

IFS=',' read -r -a NODE_LIST <<< "$NODES"
[[ ${#NODE_LIST[@]} -ge 1 ]] || die "No nodes parsed from --nodes"
LEADER="${NODE_LIST[0]}"

# ---------------------------------------------------------------------------
# Step 0: Optionally start the OIDC identity provider
# ---------------------------------------------------------------------------
# Started before Vault so the discovery endpoint is live by the time
# bootstrap-oidc.sh configures the auth method against it.
if [[ "$WITH_OIDC" == true ]]; then
    log "Starting Dex (OIDC identity provider)..."
    compose up -d dex >&2
    wait_for "http://127.0.0.1:5556/dex/.well-known/openid-configuration" "dex"
fi

# ---------------------------------------------------------------------------
# Step 0: Optionally start the database
# ---------------------------------------------------------------------------
# Waited on via the compose healthcheck rather than a port probe: Postgres
# accepts TCP connections for a while before it will accept queries, so a
# port check passes and the first `vault write database/config/...` fails
# with "the database system is starting up".
if [[ "$WITH_DATABASE" == true ]]; then
    log "Starting Postgres (target for the database secrets engine)..."
    compose up -d --wait postgres >&2         || die "Postgres did not become healthy"
    log "Postgres is accepting queries."
fi

# ---------------------------------------------------------------------------
# Step 1: Bring up and bootstrap vault-unseal
# ---------------------------------------------------------------------------
log "Starting vault-unseal..."
compose up -d --build vault-unseal >&2
wait_for "https://127.0.0.1:8300/v1/sys/seal-status" "vault-unseal"

log "Initializing vault-unseal..."
INIT_JSON="$(compose exec -T vault-unseal vault operator init -key-shares=1 -key-threshold=1 -format=json)"
UNSEAL_KEY="$(jq -r '.unseal_keys_b64[0]' <<< "$INIT_JSON")"
UNSEAL_ROOT_TOKEN="$(jq -r '.root_token' <<< "$INIT_JSON")"

log "Unsealing vault-unseal..."
compose exec -T vault-unseal vault operator unseal "$UNSEAL_KEY" >/dev/null

# `vault operator unseal` returns as soon as the node is unsealed, which is
# earlier than it being ready to serve writes: it still has to finish
# post-unseal setup and become the active node. Writing to sys/mounts in
# that window fails with "local node not active but active cluster node
# not found". Poll until it reports active rather than assuming.
log "Waiting for vault-unseal to become the active node..."
for i in $(seq 1 30); do
    # /sys/health returns 200 only when initialized, unsealed and active.
    if vcurl -fsS -o /dev/null "https://127.0.0.1:8300/v1/sys/health"; then
        log "vault-unseal is active."
        break
    fi
    log "  unsealed but not active yet... (${i}/30)"
    sleep 2
done
vcurl -fsS -o /dev/null "https://127.0.0.1:8300/v1/sys/health" \
    || die "vault-unseal never became the active node"

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
compose up -d --build "${NODE_LIST[@]}" >&2
wait_for "https://127.0.0.1:8200/v1/sys/seal-status" "$LEADER"

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

# Unsealed is not the same as ready to serve writes — same race as
# vault-unseal above. This matters most for single-node callers, which
# return from here straight into `vault secrets enable`.
log "Waiting for ${LEADER} to become the active node..."
for i in $(seq 1 30); do
    if vcurl -fsS -o /dev/null "https://127.0.0.1:8200/v1/sys/health"; then
        log "${LEADER} is active."
        break
    fi
    log "  unsealed but not active yet... (${i}/30)"
    sleep 2
done
vcurl -fsS -o /dev/null "https://127.0.0.1:8200/v1/sys/health" \
    || die "${LEADER} never became the active node"

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

# ---------------------------------------------------------------------------
# Step 5: Optionally start monitoring and confirm metrics are actually flowing
# ---------------------------------------------------------------------------
if [[ "$WITH_MONITORING" == true ]]; then
    log "Starting Prometheus, Grafana and the alerting stack..."
    # alertmanager receives what the rules fire; pushgateway is where
    # batch jobs record success so its absence can be alerted on;
    # blackbox probes the TLS listeners so certificate expiry is
    # measured from what is served rather than what is on disk.
    compose up -d prometheus grafana alertmanager pushgateway blackbox >&2
    wait_for "http://127.0.0.1:9090/-/ready" "prometheus"

    # Containers being up proves nothing about scraping — Vault could be
    # refusing the metrics request, or the scrape path could be wrong.
    # Ask Prometheus which of its vault targets are actually up.
    log "Waiting for Prometheus to scrape all ${#NODE_LIST[@]} Vault node(s)..."
    for i in $(seq 1 30); do
        UP_COUNT="$(curl -fsS 'http://127.0.0.1:9090/api/v1/query?query=up%7Bjob%3D%22vault%22%7D' 2>/dev/null \
            | jq '[.data.result[] | select(.value[1] == "1")] | length' 2>/dev/null || echo 0)"
        log "  vault targets up: ${UP_COUNT:-0}/${#NODE_LIST[@]} (${i}/30)"
        if [[ "$UP_COUNT" == "${#NODE_LIST[@]}" ]]; then
            log "All Vault nodes are being scraped."
            break
        fi
        sleep 3
    done
    if [[ "$UP_COUNT" != "${#NODE_LIST[@]}" ]]; then
        log "----- prometheus vault targets -----"
        curl -fsS 'http://127.0.0.1:9090/api/v1/targets?state=active' 2>/dev/null \
            | jq '.data.activeTargets[] | select(.labels.job == "vault") | {instance: .labels.instance, health, lastError}' >&2 || true
        log "----- end targets -----"
        die "Prometheus is not scraping all Vault nodes"
    fi

    log "Grafana: http://localhost:3000 (anonymous admin, dev only)"
    log "Prometheus: http://localhost:9090"
    log "Alertmanager: http://localhost:9093"
    log ""
    log "Note: VaultSnapshotMetricMissing will fire after ~2 minutes."
    log "That is correct — nothing has taken a snapshot yet. See"
    log "docs/monitoring.md."
fi

log "Cluster is up. Root token is a fresh dev-only credential, printed to stdout."
echo "$ROOT_TOKEN"

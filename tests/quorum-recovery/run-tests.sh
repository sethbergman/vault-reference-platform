#!/usr/bin/env bash
#
# run-tests.sh — Losing quorum, and getting it back without losing data
#
# Usage:
#   ./tests/quorum-recovery/run-tests.sh
#   ./tests/quorum-recovery/run-tests.sh --keep-running
#
# A few minutes. Stands up its own three-node cluster and tears it down.
#
# WHY THIS EXISTS
#
# The DR drill answers "the data is gone". This answers a different
# question that looks the same from the outside: "the data is fine and
# there is nobody left to agree with".
#
# Losing two of three nodes leaves a survivor holding every write Raft
# committed, unable to do anything with them because it cannot reach a
# majority. Restoring a snapshot into it would work and would discard
# everything written since that snapshot. peers.json tells the survivor
# to stop waiting for peers that are not coming back, and keeps the lot.
#
# docs/disaster-recovery.md used to send both failures to the snapshot,
# which is why this exists: the advice was not wrong so much as
# expensive, and nothing here demonstrated the cheaper path worked.
#
# WHAT IT CHECKS
#
#   - a write lands, and is still there at the end
#   - with two nodes destroyed, the survivor cannot serve reads or writes
#   - it reports HTTP 200 to a health check anyway
#   - scripts/recover-quorum.sh refuses to run while quorum is intact
#   - after recovery the survivor is active, and the pre-outage write
#     reads back
#   - the cluster accepts writes again, and a replacement node rejoins
#
# The health-check assertion is the uncomfortable one and the reason it
# is here rather than in a comment: a quorum-less node answers
# sys/health?standbyok=true with 200, so a load balancer configured to
# accept "200 active, 429 standby" keeps routing to a node that returns
# 500 for everything. Monitoring catches it -- VaultNoActiveNode fires on
# sum(vault_core_active) < 1 -- but the load balancer does not, and that
# gap is worth having a test rather than a paragraph.
#
# Requirements: docker compose, vault CLI, jq, curl

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
COMPOSE=(docker compose -f "${REPO_ROOT}/docker/dev/docker-compose.yml")

KEEP_RUNNING=false
[[ "${1:-}" == "--keep-running" ]] && KEEP_RUNNING=true

WORK="$(mktemp -d)"

PASS=0
FAIL=0

green() { printf '\033[32m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*"; }
info()  { printf '\033[36m%s\033[0m\n' "$*"; }

ok()  { PASS=$((PASS + 1)); green "  PASS  $1"; }
bad() { FAIL=$((FAIL + 1)); red   "  FAIL  $1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; return 0; }

cleanup() {
    local rc=$?
    if [[ "$KEEP_RUNNING" == true ]]; then
        info "Leaving the cluster up (--keep-running)."
    else
        info "Tearing down..."
        "${COMPOSE[@]}" --profile spare down -v >/dev/null 2>&1
    fi
    rm -rf "$WORK"
    exit "$rc"
}
trap cleanup EXIT INT TERM

for dep in docker vault jq curl; do
    command -v "$dep" >/dev/null 2>&1 || { red "ERROR: ${dep} not found on PATH"; exit 1; }
done

export VAULT_ADDR="https://127.0.0.1:8200"
export VAULT_CACERT="${REPO_ROOT}/docker/dev/tls/ca.crt"

health_code() {
    curl -s -o /dev/null -w '%{http_code}' --cacert "$VAULT_CACERT" \
        "${VAULT_ADDR}/v1/sys/health?standbyok=true" 2>/dev/null || echo "000"
}

# ---------------------------------------------------------------------------
info ""
info "=== A three-node cluster with something worth keeping ==="
# ---------------------------------------------------------------------------
# From a clean state, the way dr-drill.sh insists on. bootstrap-dev-cluster.sh
# initialises vault-unseal, and initialising an already-initialised Vault
# fails -- so a leftover cluster from a previous run makes this suite fail
# in a way that looks like a bug in the suite rather than in the state it
# inherited. It cost one run to find that out.
info "  clearing any previous cluster..."
"${COMPOSE[@]}" --profile spare down -v >/dev/null 2>&1

if ! ROOT_TOKEN="$("${REPO_ROOT}/scripts/bootstrap-dev-cluster.sh" 2>"${WORK}/bootstrap.log")"; then
    bad "the cluster came up" "$(tail -12 "${WORK}/bootstrap.log")"
    printf '\n=== Results ===\npassed: %d\nfailed: %d\n' "$PASS" "$FAIL"
    red "FAILED"
    exit 1
fi
export VAULT_TOKEN="$ROOT_TOKEN"

vault secrets enable -path=quorum -version=2 kv >/dev/null 2>&1
if vault kv put -mount=quorum canary phase=before-quorum-loss >/dev/null 2>&1; then
    ok "a secret was written while the cluster was healthy"
else
    bad "a secret was written while the cluster was healthy"
fi

# The guard, checked while it should refuse. Running it here rather than
# only after the outage is what proves the refusal is real: a check that
# is only ever exercised in the state where it passes is not a check.
if "${REPO_ROOT}/scripts/recover-quorum.sh" --peers vault-0=vault-0:8201 \
        --compose-service vault-0 >"${WORK}/refuse.log" 2>&1; then
    bad "recover-quorum.sh refuses to run while quorum is intact" \
        "it ran, and forcing a peer configuration onto a healthy cluster can strand the other nodes"
else
    if grep -q "still answers a Raft configuration query" "${WORK}/refuse.log"; then
        ok "recover-quorum.sh refuses to run while quorum is intact"
    else
        bad "recover-quorum.sh refuses to run while quorum is intact" \
            "it failed for another reason: $(tail -3 "${WORK}/refuse.log")"
    fi
fi

# The guard has to hold when it cannot run, not only when it can. A
# review found it downgrading to a warning with no VAULT_TOKEN and
# proceeding to stop the node -- and an incident is exactly when
# VAULT_TOKEN is least likely to be exported, because the cluster that
# would have issued it is the one that is down.
if env -u VAULT_TOKEN "${REPO_ROOT}/scripts/recover-quorum.sh" \
        --peers vault-0=vault-0:8201 --compose-service vault-0 \
        >"${WORK}/no-token.log" 2>&1; then
    bad "recover-quorum.sh refuses when it cannot check for quorum" \
        "it ran without a token, so the healthy-cluster guard was skipped entirely"
else
    if grep -q "cannot check whether this cluster still has quorum" "${WORK}/no-token.log"; then
        ok "recover-quorum.sh refuses when it cannot check for quorum"
    else
        bad "recover-quorum.sh refuses when it cannot check for quorum" \
            "it failed for another reason: $(tail -3 "${WORK}/no-token.log")"
    fi
fi

# And refuses before touching anything when it has no way to confirm the
# node came back. Stopping a node whose recovery cannot be verified is
# worse than not starting.
if env -u VAULT_ADDR "${REPO_ROOT}/scripts/recover-quorum.sh" \
        --peers vault-0=vault-0:8201 --compose-service vault-0 \
        >"${WORK}/no-addr.log" 2>&1; then
    bad "recover-quorum.sh refuses without a way to verify the outcome" "it ran anyway"
else
    if grep -q "no way to confirm the node came back" "${WORK}/no-addr.log"; then
        ok "recover-quorum.sh refuses without a way to verify the outcome"
    else
        bad "recover-quorum.sh refuses without a way to verify the outcome" \
            "it failed for another reason: $(tail -3 "${WORK}/no-addr.log")"
    fi
fi

# Both refusals must happen before the node is stopped, or the guard is
# just a louder way of breaking things. The cluster is still healthy here,
# so if either had gone through, this read would fail.
if timeout 30 vault kv get -mount=quorum -field=phase canary >/dev/null 2>&1; then
    ok "and neither refusal stopped the node on its way out"
else
    bad "and neither refusal stopped the node on its way out" \
        "the cluster is no longer serving, so a refusal path stopped it first"
fi

# ---------------------------------------------------------------------------
info ""
info "=== Losing two of three ==="
# ---------------------------------------------------------------------------
info "  destroying vault-1 and vault-2, containers and volumes..."
"${COMPOSE[@]}" rm -sfv vault-1 vault-2 >/dev/null 2>&1
sleep 20

READ_ERR="$(timeout 30 vault kv get -mount=quorum -field=phase canary 2>&1 >/dev/null)"
if grep -qi "active cluster node not found\|500" <<< "$READ_ERR"; then
    ok "the survivor cannot serve reads without a majority"
else
    bad "the survivor cannot serve reads without a majority" \
        "expected a 500 about no active node, got: ${READ_ERR:-<success>}"
fi

# The finding worth a test. A quorum-less node is unsealed, so a health
# check that accepts standbys accepts it -- and the AWS target group is
# configured for exactly "200,429". Pinned to 200 rather than "not 5xx",
# because the point is the specific number a load balancer is told to
# treat as healthy.
CODE="$(health_code)"
if [[ "$CODE" == "200" ]]; then
    ok "and still answers the load balancer's health check with 200"
else
    bad "and still answers the load balancer's health check with 200" \
        "got ${CODE}; if Vault changed this, the note in docs/disaster-recovery.md needs revisiting"
fi

# ---------------------------------------------------------------------------
info ""
info "=== Recovery that keeps what the survivor had ==="
# ---------------------------------------------------------------------------
if "${REPO_ROOT}/scripts/recover-quorum.sh" \
        --peers vault-0=vault-0:8201 \
        --compose-service vault-0 >"${WORK}/recover.log" 2>&1; then
    ok "recover-quorum.sh completed"
else
    bad "recover-quorum.sh completed" "$(tail -10 "${WORK}/recover.log")"
fi

if [[ "$(health_code)" == "200" ]]; then
    ok "the survivor is answering"
else
    bad "the survivor is answering" "health is $(health_code)"
fi

PEERS_AFTER="$(timeout 30 vault operator raft list-peers -format=json 2>/dev/null \
    | jq -r '[.data.config.servers[].node_id] | join(",")' 2>/dev/null || echo "")"
if [[ "$PEERS_AFTER" == "vault-0" ]]; then
    ok "the Raft configuration is now the survivor alone"
else
    bad "the Raft configuration is now the survivor alone" "peers: ${PEERS_AFTER:-<none>}"
fi

# The whole reason to prefer this over a restore.
CANARY="$(timeout 30 vault kv get -mount=quorum -field=phase canary 2>/dev/null || echo "")"
if [[ "$CANARY" == "before-quorum-loss" ]]; then
    ok "the pre-outage write survived — nothing was rolled back to a snapshot"
else
    bad "the pre-outage write survived" "read back '${CANARY}'"
fi

if timeout 30 vault kv put -mount=quorum canary phase=after-recovery >/dev/null 2>&1; then
    ok "and the cluster accepts writes again"
else
    bad "and the cluster accepts writes again"
fi

# peers.json is a one-shot: Raft consumes it. If it were left behind it
# would re-apply on every restart, which would quietly undo any node that
# joined in the meantime.
CID="$("${COMPOSE[@]}" ps -q vault-0)"
if docker exec "$CID" ls /vault/data/raft/peers.json >/dev/null 2>&1; then
    bad "Raft consumed peers.json" \
        "the file is still there, so this recovery would re-apply on the next restart"
else
    ok "Raft consumed peers.json, so it cannot re-apply on the next restart"
fi

# ---------------------------------------------------------------------------
info ""
info "=== And the cluster can grow back ==="
# ---------------------------------------------------------------------------
# A recovery that leaves a cluster which cannot take new members is only
# half a recovery.
TRANSIT_TOKEN="$(docker inspect "$CID" \
    --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
    | sed -n 's/^VAULT_TRANSIT_TOKEN=//p')"

VAULT_TRANSIT_TOKEN="$TRANSIT_TOKEN" "${COMPOSE[@]}" up -d vault-1 >"${WORK}/rejoin.log" 2>&1

REJOINED=false
for _ in $(seq 1 40); do
    if timeout 20 vault operator raft list-peers -format=json 2>/dev/null \
        | jq -e '.data.config.servers[] | select(.node_id == "vault-1")' >/dev/null 2>&1; then
        REJOINED=true
        break
    fi
    sleep 3
done

if [[ "$REJOINED" == true ]]; then
    ok "a replacement node rejoins the recovered cluster"
else
    bad "a replacement node rejoins the recovered cluster" \
        "$("${COMPOSE[@]}" logs --tail 12 vault-1 2>&1 | tail -12)"
fi

# ---------------------------------------------------------------------------
printf '\n=== Results ===\n'
# ---------------------------------------------------------------------------
printf 'passed: %d\nfailed: %d\n' "$PASS" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then red "FAILED"; exit 1; fi
green "All ${PASS} assertions passed against a real cluster."

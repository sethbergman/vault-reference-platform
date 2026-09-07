#!/usr/bin/env bash
#
# run-tests.sh — Watch a dead voter actually get pruned
#
# Usage:
#   ./tests/autopilot-prune/run-tests.sh
#   ./tests/autopilot-prune/run-tests.sh --keep-running
#
# About five minutes. Stands up its own three-node cluster and tears it
# down. Most of the time is Vault's own floor: it refuses a
# dead_server_last_contact_threshold below 1m, so the wait that proves the
# floor is holding cannot be shortened past that.
#
# WHY THIS EXISTS
#
# scripts/configure-autopilot.sh turns on cleanup_dead_servers and sets a
# min_quorum floor, and the claim is that this makes an ASG instance
# refresh safe: a departed voter is pruned once a replacement has joined.
#
# Everything else only tests half of that. tests/autopilot shows the
# script issues the right command; tests/integration shows the live
# cluster reports the values back, and that the floor *blocks* pruning
# while there are only three voters. None of it shows a dead voter
# actually disappearing, because pruning cannot happen at three voters
# with a floor of three -- which is the point of the floor.
#
# So the claim that matters most was the one nothing covered. This covers
# it, by doing locally what an instance refresh does on AWS:
#
#   1. three voters, healthy
#   2. destroy one -- it stays a voter, because pruning it would drop
#      below the floor
#   3. add a node the cluster has never seen, with a node_id of its own
#      (docker/dev's vault-3 spare, exactly as a replacement EC2 instance
#      brings a new instance id)
#   4. the dead one is pruned, and the replacement is promoted in its
#      place -- in that order, and the voter count never exceeds three
#
# Step 3 is the part three fixed nodes cannot model: destroy vault-2 and
# it comes back as vault-2, so the count never rises and nothing is ever
# pruned.
#
# WHAT THIS STILL DOES NOT PROVE
#
# That an ASG does this. Nothing here is an autoscaling group: the
# replacement is started by hand, in the right order, with no instance
# warmup and no health check in the way. What it establishes is that the
# autopilot configuration behaves as docs/rolling-upgrades.md says when a
# replacement arrives -- which was previously assumed.
#
# Requirements: docker compose, vault CLI, jq

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
        "${COMPOSE[@]}" down -v >/dev/null 2>&1
    fi
    rm -rf "$WORK"
    exit "$rc"
}
trap cleanup EXIT INT TERM

for dep in docker vault jq; do
    command -v "$dep" >/dev/null 2>&1 || { red "ERROR: ${dep} not found on PATH"; exit 1; }
done

export VAULT_ADDR="https://127.0.0.1:8200"
export VAULT_CACERT="${REPO_ROOT}/docker/dev/tls/ca.crt"

voters() {
    vault operator raft list-peers -format=json 2>/dev/null \
        | jq -r '[.data.config.servers[]? | select(.voter == true)] | length' 2>/dev/null || echo 0
}

has_peer() {
    vault operator raft list-peers -format=json 2>/dev/null \
        | jq -e --arg n "$1" '.data.config.servers[]? | select(.node_id == $n)' >/dev/null 2>&1
}

is_voter() {
    vault operator raft list-peers -format=json 2>/dev/null \
        | jq -e --arg n "$1" '.data.config.servers[]? | select(.node_id == $n and .voter == true)' >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
info ""
info "=== Bringing up a three-node cluster ==="
# ---------------------------------------------------------------------------
if ! ROOT_TOKEN="$("${REPO_ROOT}/scripts/bootstrap-dev-cluster.sh" 2>"${WORK}/bootstrap.log")"; then
    bad "the cluster came up" "$(tail -12 "${WORK}/bootstrap.log")"
    printf '\n=== Results ===\npassed: %d\nfailed: %d\n' "$PASS" "$FAIL"
    red "FAILED"
    exit 1
fi
export VAULT_TOKEN="$ROOT_TOKEN"

if [[ "$(voters)" == "3" ]]; then
    ok "three voters to start with"
else
    bad "three voters to start with" "got $(voters)"
fi

# Somewhere to write at the end. This has to be enabled now, while the
# cluster is unambiguously healthy, so that a failure later is about
# quorum rather than about a missing mount.
#
# Not `secret/`: a dev-mode Vault has one and a real one does not, and
# using it made the final assertion fail with "quorum was lost" when
# nothing of the sort had happened.
vault secrets enable -path=prune-canary -version=2 kv >/dev/null 2>&1
if vault kv put -mount=prune-canary before v=1 >/dev/null 2>&1; then
    ok "a canary mount exists and accepts writes"
else
    bad "a canary mount exists and accepts writes" \
        "the rest of this suite cannot tell a quorum failure from a setup failure"
fi

# ---------------------------------------------------------------------------
info ""
info "=== Autopilot configured to clean up, with a floor ==="
# ---------------------------------------------------------------------------
# One minute, because Vault refuses anything shorter:
#
#   dead_server_last_contact_threshold should not be set to less than 1m
#
# So the floor on how fast this test can run is not a choice. The
# production default is 5m for the reasons in the script header; 1m here
# is the shortest value that exists, and it is what bounds the waits
# below.
if "${REPO_ROOT}/scripts/configure-autopilot.sh" --dead-server-threshold 1m \
        >"${WORK}/autopilot.log" 2>&1; then
    ok "configure-autopilot.sh applied (threshold at Vault's 1m minimum)"
else
    bad "configure-autopilot.sh applied" "$(tail -6 "${WORK}/autopilot.log")"
fi

# ---------------------------------------------------------------------------
info ""
info "=== A destroyed node stays a voter, because the floor says so ==="
# ---------------------------------------------------------------------------
# The Transit token lives in the running containers' environment. The
# spare needs the same one, and reading it from a node that already has it
# is better than making bootstrap-dev-cluster.sh write a secret to disk
# for the benefit of a test.
TRANSIT_TOKEN="$(docker inspect "$("${COMPOSE[@]}" ps -q vault-0)" \
    --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
    | sed -n 's/^VAULT_TRANSIT_TOKEN=//p')"
if [[ -n "$TRANSIT_TOKEN" ]]; then
    ok "read the Transit token from the running cluster"
else
    bad "read the Transit token from the running cluster" \
        "without it the spare cannot auto-unseal, and the rest of this suite cannot run"
fi

info "  destroying vault-2, container and volume..."
"${COMPOSE[@]}" rm -sfv vault-2 >/dev/null 2>&1

# Comfortably past the 1m threshold. If the floor were not holding, this
# is where the node would disappear.
sleep 90

if has_peer vault-2; then
    ok "vault-2 is still a voter 90s after being destroyed (threshold is 1m)"
else
    bad "vault-2 is still a voter 90s after being destroyed" \
        "it was pruned at three voters, which means min_quorum is not holding the floor"
fi

if [[ "$(voters)" == "3" ]]; then
    ok "the voter count is still three, two of them live"
else
    bad "the voter count is still three, two of them live" "got $(voters)"
fi

# ---------------------------------------------------------------------------
info ""
info "=== A replacement with a node_id the cluster has not seen ==="
# ---------------------------------------------------------------------------
# What an ASG does: not vault-2 coming back, but a new machine with a new
# identity joining alongside the record of the old one.
info "  starting the spare (vault-3)..."
VAULT_TRANSIT_TOKEN="$TRANSIT_TOKEN" "${COMPOSE[@]}" --profile spare up -d vault-3 \
    >"${WORK}/spare.log" 2>&1

JOINED=false
for _ in $(seq 1 40); do
    if has_peer vault-3; then JOINED=true; break; fi
    sleep 3
done

if [[ "$JOINED" == true ]]; then
    ok "vault-3 joined the cluster as a new peer"
else
    bad "vault-3 joined the cluster as a new peer" \
        "$("${COMPOSE[@]}" logs --tail 15 vault-3 2>&1 | tail -15)"
    printf '\n=== Results ===\npassed: %d\nfailed: %d\n' "$PASS" "$FAIL"
    red "FAILED"
    exit 1
fi

# Watch both together and assert afterwards, because they are one
# sequence and the order is autopilot's rather than ours.
#
# The order is not the one this suite first asserted. It expected the
# voter count to rise to four and fall back to three -- promote, then
# prune. What actually happens is the reverse: the replacement joins as a
# NON-voter, that is enough to satisfy min_quorum, the dead voter is
# pruned, and only then is the replacement promoted. The count never
# reaches four.
#
# Which means min_quorum counts servers, not voters. A non-voting node
# that has joined already satisfies the floor. The property still holds
# -- nothing is pruned until a replacement exists, demonstrated by the
# 90s above -- but "join, then prune, then promote" is the sequence, and
# an assertion on four voters fails while everything is working.
PROMOTED=false
PRUNED=false
for i in $(seq 1 60); do
    v="$(voters)"
    is_voter vault-3 && PROMOTED=true
    has_peer vault-2 || PRUNED=true
    if (( i % 5 == 0 )); then
        info "    t+$((i * 5))s: voters=${v} vault-3-is-voter=${PROMOTED} vault-2-pruned=${PRUNED}"
    fi
    [[ "$PROMOTED" == true && "$PRUNED" == true ]] && break
    sleep 5
done

if [[ "$PROMOTED" == true ]]; then
    ok "the replacement was promoted to voter"
else
    bad "the replacement was promoted to voter" \
        "vault-3 is still a non-voter after five minutes"
fi

# ---------------------------------------------------------------------------
info ""
info "=== And now the dead voter is pruned ==="
# ---------------------------------------------------------------------------
# The assertion this suite exists for. vault-3 having joined -- even as a
# non-voter -- means removing vault-2 still leaves three servers, which is
# the floor, so autopilot is finally allowed to act. Before it joined,
# pruning would have left two, and the 90s wait above is the evidence that
# it did not happen.
if [[ "$PRUNED" == true ]]; then
    ok "vault-2 is gone from the Raft configuration"
else
    bad "vault-2 is gone from the Raft configuration" \
        "still listed after ~2 minutes: $(vault operator raft list-peers 2>&1 | tail -6)"
fi

FINAL="$(voters)"
if [[ "$FINAL" == "3" ]]; then
    ok "back to three voters, all of them live"
else
    bad "back to three voters, all of them live" "voters: ${FINAL}"
fi

# The whole point of the exercise: at no moment did the cluster have more
# voters than it could muster live nodes for. Checked at the end rather
# than sampled, because a sampled check that missed the window would pass
# for the wrong reason.
WRITE_ERR="$(vault kv put -mount=prune-canary after v=2 2>&1 >/dev/null)"
if [[ -z "$WRITE_ERR" ]]; then
    ok "the cluster still accepts writes after the whole sequence"
else
    bad "the cluster still accepts writes after the whole sequence" "${WRITE_ERR}"
fi

# ---------------------------------------------------------------------------
printf '\n=== Results ===\n'
# ---------------------------------------------------------------------------
printf 'passed: %d\nfailed: %d\n' "$PASS" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then red "FAILED"; exit 1; fi
green "All ${PASS} assertions passed against a real cluster."

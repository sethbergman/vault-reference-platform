#!/usr/bin/env bash
#
# run-tests.sh — Migrating a cluster between seal types
#
# Usage:
#   ./tests/seal-migration/run-tests.sh [--keep-running]
#
# Slow: it migrates a real three-node cluster twice and restarts every
# node several times. Budget ten minutes.
#
# WHY THIS EXISTS
#
# docs/roadmap.md calls seal migration the operation most likely to leave
# a cluster that will not unseal, and until now nothing here exercised
# it. It cannot be shimmed: a stand-in `vault` would report whatever the
# script hoped for, and the entire question is what the real barrier does
# when you change the thing that protects it.
#
# WHAT IS ASSERTED, AND WHY EACH ONE
#
# Two of these check Vault's behaviour rather than the script's, and that
# is deliberate. scripts/migrate-seal.sh is shaped the way it is because
# of them; if either stops being true, the script is carrying weight it
# no longer needs and the suite should be the thing that says so.
#
#   plain unseal is refused        Every node needs -migrate, not just the
#                                  active one. This is the premise behind
#                                  the script's unseal loop.
#   migration outlives the unseal  sys/seal-status reports migration=true
#                                  until a leader finalises it, so the
#                                  operation is not over when the last
#                                  node opens.
#
# The rest are the script's own claims: that data survives, that the seal
# type actually changes, that auto-unseal comes back, and that it refuses
# to run when there is nothing to do.
#
# WHAT A GREEN RUN DOES NOT MEAN
#
# This is the compose profile, so the "restart" is a container restart and
# the config edit happens inside the image. On a real node it is an edit
# to /etc/vault.d/vault.hcl and a systemctl restart, which nothing here
# performs. The sequence is the same and the mechanics are not.
#
# Requirements: docker compose, vault CLI, jq, curl

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
COMPOSE=(docker compose -f "${REPO_ROOT}/docker/dev/docker-compose.yml")
KEYS_FILE="${REPO_ROOT}/docker/dev/.recovery-keys.json"
MIGRATE="${REPO_ROOT}/scripts/migrate-seal.sh"
NODES="vault-0,vault-1,vault-2"
CA="${REPO_ROOT}/docker/dev/tls/ca.crt"

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
    rm -f "${REPO_ROOT}"/pre-seal-migration-*.snap
    rm -rf "$WORK"
    exit "$rc"
}
trap cleanup EXIT INT TERM

for dep in docker vault jq curl; do
    command -v "$dep" >/dev/null 2>&1 || { red "ERROR: ${dep} not found on PATH"; exit 1; }
done

export VAULT_ADDR="https://127.0.0.1:8200"
export VAULT_CACERT="$CA"

# Read seal state through the API. `vault status` renders HA fields the
# JSON does not carry, and no `// empty`: jq treats false as absent, so
# `.migration // empty` is "" for a finished migration.
seal_at() {  # seal_at <port> <field>
    curl -sk --cacert "$CA" --max-time 5 \
        "https://127.0.0.1:${1}/v1/sys/seal-status" 2>/dev/null | jq -r ".${2}"
}

wait_port() {
    for _ in $(seq 1 45); do
        curl -sk --cacert "$CA" --max-time 2 \
            "https://127.0.0.1:${1}/v1/sys/seal-status" >/dev/null 2>&1 && return 0
        sleep 2
    done
    return 1
}

all_are() {  # all_are <type> -> 0 when every node reports it
    local t="$1" p
    for p in 8200 8210 8220; do
        [[ "$(seal_at "$p" type)" == "$t" ]] || return 1
    done
    return 0
}

# ---------------------------------------------------------------------------
info ""
info "=== A cluster on Transit auto-unseal ==="
# ---------------------------------------------------------------------------
info "  clearing any previous cluster..."
"${COMPOSE[@]}" --profile spare down -v >/dev/null 2>&1
rm -f "$KEYS_FILE" "$KEYS_FILE".* "${REPO_ROOT}"/pre-seal-migration-*.snap

if ! ROOT_TOKEN="$("${REPO_ROOT}/scripts/bootstrap-dev-cluster.sh" 2>"${WORK}/bootstrap.log")"; then
    bad "the cluster came up" "$(tail -12 "${WORK}/bootstrap.log")"
    printf '\n=== Results ===\npassed: %d\nfailed: %d\n' "$PASS" "$FAIL"
    red "FAILED"; exit 1
fi
export VAULT_TOKEN="$ROOT_TOKEN"
ok "the cluster came up"

if all_are transit; then
    ok "and every node is sealed with transit"
else
    bad "and every node is sealed with transit" \
        "$(for p in 8200 8210 8220; do printf '%s=%s ' "$p" "$(seal_at "$p" type)"; done)"
fi

vault secrets enable -path=seal -version=2 kv >/dev/null 2>&1 || true
if vault kv put seal/canary value=survives-the-migration >/dev/null 2>&1; then
    ok "and holds a secret written before any migration"
else
    bad "and holds a secret written before any migration"
fi

# ---------------------------------------------------------------------------
info ""
info "=== It refuses the things that would waste a maintenance window ==="
# ---------------------------------------------------------------------------

OUT="$(bash "$MIGRATE" --to transit --keys-file "$KEYS_FILE" --compose-services "$NODES" 2>&1)"; RC=$?
if [[ "$RC" -ne 0 ]]; then
    ok "migrating to the seal type already in use is refused"
else
    bad "migrating to the seal type already in use is refused" "it proceeded"
fi
if [[ "$OUT" == *"already on transit"* ]]; then
    ok "and says so plainly"
else
    bad "and says so plainly" "$(tail -2 <<< "$OUT")"
fi

OUT="$(bash "$MIGRATE" --to shamir --keys-file "$KEYS_FILE" --compose-services "$NODES" --skip-snapshot 2>&1)"; RC=$?
if [[ "$RC" -ne 0 ]]; then
    ok "--skip-snapshot alone is refused"
else
    bad "--skip-snapshot alone is refused" "it proceeded without a backup"
fi
if [[ "$OUT" == *"--i-have-a-backup"* ]]; then
    ok "and names the flag that acknowledges it"
else
    bad "and names the flag that acknowledges it"
fi

# Neither refusal may have touched anything.
if all_are transit && [[ "$(seal_at 8200 sealed)" == "false" ]]; then
    ok "and neither refusal disturbed the cluster"
else
    bad "and neither refusal disturbed the cluster"
fi

# ---------------------------------------------------------------------------
info ""
info "=== Transit to Shamir ==="
# ---------------------------------------------------------------------------

OUT="$(bash "$MIGRATE" --to shamir --keys-file "$KEYS_FILE" --compose-services "$NODES" 2>&1)"; RC=$?
if [[ "$RC" -eq 0 ]]; then
    ok "migrate-seal.sh --to shamir succeeds"
else
    bad "migrate-seal.sh --to shamir succeeds" "$(tail -6 <<< "$OUT")"
fi

if all_are shamir; then
    ok "and every node now reports shamir"
else
    bad "and every node now reports shamir" \
        "$(for p in 8200 8210 8220; do printf '%s=%s ' "$p" "$(seal_at "$p" type)"; done)"
fi

# The assertion the whole operation is for. A migration that changed the
# seal type and lost the data would pass every check above.
if [[ "$(vault kv get -field=value seal/canary 2>/dev/null)" == "survives-the-migration" ]]; then
    ok "and the secret written before it is still readable"
else
    bad "and the secret written before it is still readable" \
        "the barrier changed and took the data with it"
fi

if [[ "$(seal_at 8200 migration)" == "false" ]]; then
    ok "and the migration finalised rather than being left in progress"
else
    bad "and the migration finalised rather than being left in progress" \
        "migration=$(seal_at 8200 migration) — nodes in this state do not auto-unseal"
fi

SNAP_COUNT="$(find "$REPO_ROOT" -maxdepth 1 -name 'pre-seal-migration-*.snap' | wc -l | tr -d ' ')"
if [[ "$SNAP_COUNT" -ge 1 ]]; then
    ok "and a pre-migration snapshot was kept (${SNAP_COUNT})"
else
    bad "and a pre-migration snapshot was kept" \
        "the only thing that recovers a half-migrated barrier"
fi

# ---------------------------------------------------------------------------
info ""
info "=== Vault's own rules, which the script is shaped around ==="
# ---------------------------------------------------------------------------
# Put the cluster into migration mode by hand — config edit and restart,
# exactly what the script does — and check the two behaviours its unseal
# loop exists for, before handing back to the script to finish.

info "  putting the cluster back into migration mode by hand..."
for n in vault-0 vault-1 vault-2; do
    "${COMPOSE[@]}" exec -T "$n" sh -c \
        'grep -v "disabled = \"true\"" /vault/config/vault.hcl > /tmp/s.hcl && cp /tmp/s.hcl /vault/config/vault.hcl' \
        >/dev/null 2>&1
done
"${COMPOSE[@]}" restart vault-0 vault-1 vault-2 >/dev/null 2>&1
for p in 8200 8210 8220; do wait_port "$p" || true; done

if [[ "$(seal_at 8200 migration)" == "true" ]]; then
    ok "a config change plus restart puts the node in migration mode"
else
    bad "a config change plus restart puts the node in migration mode" \
        "migration=$(seal_at 8200 migration); the checks below prove nothing"
fi

mapfile -t SHARES < <(jq -r '.recovery_keys_b64[]' "$KEYS_FILE")
PLAIN="$("${COMPOSE[@]}" exec -T vault-1 vault operator unseal "${SHARES[0]}" 2>&1)"; PRC=$?

if [[ "$PRC" -ne 0 ]]; then
    ok "a plain unseal is refused while migration is in progress"
else
    bad "a plain unseal is refused while migration is in progress" \
        "then -migrate on every node is unnecessary and the script is wrong"
fi
if [[ "$PLAIN" == *"migrate option not provided"* ]]; then
    ok "and says the migrate option was not provided"
else
    bad "and says the migrate option was not provided" \
        "$(tr '\n' ' ' <<< "$PLAIN" | cut -c1-140)"
fi

# ---------------------------------------------------------------------------
info ""
info "=== Shamir back to Transit ==="
# ---------------------------------------------------------------------------
# The block above left the cluster mid-migration, which is exactly the
# state an interrupted run leaves behind — so this also covers the
# script's resume path. It must not refuse on the grounds that the nodes
# already report the target type: they report it because they are halfway
# there, not because there is nothing to do.

OUT="$(bash "$MIGRATE" --to transit --keys-file "$KEYS_FILE" --compose-services "$NODES" \
        --skip-snapshot --i-have-a-backup 2>&1)"; RC=$?
if [[ "$RC" -eq 0 ]]; then
    ok "migrate-seal.sh --to transit finishes an interrupted migration"
else
    bad "migrate-seal.sh --to transit finishes an interrupted migration"         "$(tail -6 <<< "$OUT")"
fi

if [[ "$OUT" == *"resuming it"* ]]; then
    ok "and says it is resuming rather than starting"
else
    bad "and says it is resuming rather than starting"         "it treated a half-migrated cluster as a fresh one"
fi

if all_are transit; then
    ok "and every node reports transit again"
else
    bad "and every node reports transit again" \
        "$(for p in 8200 8210 8220; do printf '%s=%s ' "$p" "$(seal_at "$p" type)"; done)"
fi

if [[ "$(seal_at 8200 migration)" == "false" ]]; then
    ok "and the migration finalised"
else
    bad "and the migration finalised" "migration=$(seal_at 8200 migration)"
fi

# ---------------------------------------------------------------------------
info ""
info "=== Auto-unseal is genuinely back ==="
# ---------------------------------------------------------------------------
# The check that separates "reports transit" from "is protected by
# transit". A node still in migration mode reports transit too, and comes
# back sealed — which is why this is only run once migration=false.

info "  restarting vault-0 with no keys supplied..."
"${COMPOSE[@]}" restart vault-0 >/dev/null 2>&1
wait_port 8200 || true
sleep 6

if [[ "$(seal_at 8200 sealed)" == "false" ]]; then
    ok "a restarted node unseals itself with no shares supplied"
else
    bad "a restarted node unseals itself with no shares supplied" \
        "sealed=$(seal_at 8200 sealed) — the seal stanza is configured but not working"
fi

if [[ "$(seal_at 8200 recovery_seal)" == "true" ]]; then
    ok "and the shares are recovery keys again, not unseal keys"
else
    bad "and the shares are recovery keys again, not unseal keys" \
        "recovery_seal=$(seal_at 8200 recovery_seal)"
fi

if [[ "$(vault kv get -field=value seal/canary 2>/dev/null)" == "survives-the-migration" ]]; then
    ok "and the secret survived both migrations"
else
    bad "and the secret survived both migrations"
fi

# ---------------------------------------------------------------------------
printf '\n=== Results ===\npassed: %d\nfailed: %d\n' "$PASS" "$FAIL"
if [[ "$FAIL" -eq 0 ]]; then
    green "All ${PASS} assertions passed."
else
    red "FAILED"
fi
[[ "$FAIL" -eq 0 ]]

#!/usr/bin/env bash
#
# run-tests.sh — API rate limit quotas, and the ways they mislead
#
# Usage:
#   ./tests/quotas/run-tests.sh [--keep-running]
#
# WHY A REAL CLUSTER
#
# Every interesting property here is a response code under load, and a
# shim would return whichever code the script hoped for. The questions
# are what Vault does when a quota trips, what it does to the endpoints
# you need in order to undo it, and whether a load balancer can tell the
# result apart from a healthy standby.
#
# WHAT IS ASSERTED ABOUT VAULT RATHER THAN THE SCRIPT
#
# Four of these are Vault's behaviour. scripts/bootstrap-quotas.sh is
# shaped entirely around them, so if any stops being true the script is
# guarding something that no longer happens and this suite should say so.
#
#   config is replaced       writing one field to sys/quotas/config drops
#                            the seven shipped exempt paths
#   the list is a list       rate_limit_exempt_paths="a,b" becomes one
#                            element containing a comma
#   the quota self-defends   a tripped global quota answers 429 to the
#                            DELETE that would remove it
#   429 is ambiguous         a standby answers 429 on sys/health, so the
#                            code alone cannot identify a quota
#
# Requirements: docker compose, vault CLI, jq, curl

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
COMPOSE=(docker compose -f "${REPO_ROOT}/docker/dev/docker-compose.yml")
QUOTAS="${REPO_ROOT}/scripts/bootstrap-quotas.sh"
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
    rm -rf "$WORK"
    exit "$rc"
}
trap cleanup EXIT INT TERM

for dep in docker vault jq curl; do
    command -v "$dep" >/dev/null 2>&1 || { red "ERROR: ${dep} not found on PATH"; exit 1; }
done

export VAULT_ADDR="https://127.0.0.1:8200"
export VAULT_CACERT="$CA"

# Status code for one request. Everything here is about codes under load,
# so this is the primitive the whole suite is built on.
code() {  # code <method> <path> [port]
    curl -sk --cacert "$CA" -o /dev/null -w '%{http_code}' -X "$1" \
        -H "X-Vault-Token: ${VAULT_TOKEN:-}" \
        "https://127.0.0.1:${3:-8200}/v1/$2" 2>/dev/null
}
burn() { local i; for ((i = 0; i < ${1:-5}; i++)); do code GET sys/mounts >/dev/null; done; }
exempt_count() {
    vault read -format=json sys/quotas/config 2>/dev/null \
        | jq -r '.data.rate_limit_exempt_paths | length' 2>/dev/null
}

# ---------------------------------------------------------------------------
info ""
info "=== A cluster, and the quota config as Vault ships it ==="
# ---------------------------------------------------------------------------
info "  clearing any previous cluster..."
"${COMPOSE[@]}" --profile spare down -v >/dev/null 2>&1
rm -f "${REPO_ROOT}"/docker/dev/.recovery-keys.json* \
      "${REPO_ROOT}"/docker/dev/.unseal-keys.json*

if ! ROOT_TOKEN="$("${REPO_ROOT}/scripts/bootstrap-dev-cluster.sh" 2>"${WORK}/bootstrap.log")"; then
    bad "the cluster came up" "$(tail -12 "${WORK}/bootstrap.log")"
    printf '\n=== Results ===\npassed: %d\nfailed: %d\n' "$PASS" "$FAIL"
    red "FAILED"; exit 1
fi
export VAULT_TOKEN="$ROOT_TOKEN"
ok "the cluster came up"

SHIPPED="$(exempt_count)"
if [[ "$SHIPPED" == "7" ]]; then
    ok "Vault ships seven exempt paths"
else
    bad "Vault ships seven exempt paths" "got ${SHIPPED}; the defaults below assume this set"
fi

if vault read -format=json sys/quotas/config 2>/dev/null \
    | jq -e '.data.rate_limit_exempt_paths | index("sys/health")' >/dev/null; then
    ok "and sys/health is one of them"
else
    bad "and sys/health is one of them"
fi

# ---------------------------------------------------------------------------
info ""
info "=== Vault's rules, which the script exists to work around ==="
# ---------------------------------------------------------------------------

# 1. Writing one field replaces the whole config.
vault write sys/quotas/config enable_rate_limit_audit_logging=true >/dev/null 2>&1
AFTER="$(exempt_count)"
if [[ "$AFTER" == "0" ]]; then
    ok "writing one field empties the exempt list"
else
    bad "writing one field empties the exempt list" \
        "got ${AFTER}; if the endpoint merges now, the script's rewrite is unnecessary"
fi

# 2. The list is a list, and k=v does not make one.
vault write sys/quotas/config rate_limit_exempt_paths="sys/health,sys/seal-status" >/dev/null 2>&1
JOINED="$(vault read -format=json sys/quotas/config 2>/dev/null \
    | jq -r '.data.rate_limit_exempt_paths[0] // ""')"
if [[ "$JOINED" == *","* ]]; then
    ok "a comma-joined value becomes one path containing a comma"
else
    bad "a comma-joined value becomes one path containing a comma" \
        "got '${JOINED}'; the script sends JSON because of this"
fi

# ---------------------------------------------------------------------------
info ""
info "=== bootstrap-quotas.sh sets a list that is actually a list ==="
# ---------------------------------------------------------------------------

OUT="$(bash "$QUOTAS" 2>&1)"; RC=$?
if [[ "$RC" -eq 0 ]]; then
    ok "bootstrap-quotas.sh configures exemptions"
else
    bad "bootstrap-quotas.sh configures exemptions" "$(tail -4 <<< "$OUT")"
fi

N="$(exempt_count)"
if [[ "${N:-0}" -ge 9 ]]; then
    ok "and the exempt list has ${N} entries, not one"
else
    bad "and the exempt list has nine or more entries" "got ${N}"
fi

for p in "sys/health" "sys/quotas/config" "sys/quotas/rate-limit"; do
    if vault read -format=json sys/quotas/config 2>/dev/null \
        | jq -e --arg p "$p" '.data.rate_limit_exempt_paths | index($p)' >/dev/null; then
        ok "including ${p}"
    else
        bad "including ${p}"
    fi
done

if [[ "$(vault read -format=json sys/quotas/config 2>/dev/null \
    | jq -r '.data.enable_rate_limit_response_headers')" == "true" ]]; then
    ok "and response headers are on"
else
    bad "and response headers are on" \
        "without them a quota 429 cannot be told from a standby's"
fi

# ---------------------------------------------------------------------------
info ""
info "=== A quota that bites, and an operator who is not locked out ==="
# ---------------------------------------------------------------------------

OUT="$(bash "$QUOTAS" --rate 1 --interval 20s --name suite 2>&1)"; RC=$?
if [[ "$RC" -eq 0 ]]; then
    ok "a deliberately hostile quota is set"
else
    bad "a deliberately hostile quota is set" "$(tail -4 <<< "$OUT")"
fi

burn 5
if [[ "$(code GET sys/mounts)" == "429" ]]; then
    ok "an ordinary path is refused with 429"
else
    bad "an ordinary path is refused with 429" \
        "the quota is not in force, so nothing below is being tested"
fi

# The point of exempting the admin paths.
if [[ "$(code GET sys/quotas/config)" == "200" ]]; then
    ok "and the quota config is still readable"
else
    bad "and the quota config is still readable" \
        "code $(code GET sys/quotas/config) — the operator cannot see what is limiting them"
fi

if [[ "$(code GET 'sys/health?standbyok=true')" == "200" ]]; then
    ok "and health checks still answer 200"
else
    bad "and health checks still answer 200" \
        "the load balancer would see a quota 429 and call it a healthy standby"
fi

DEL="$(code DELETE sys/quotas/rate-limit/suite)"
if [[ "$DEL" == "204" || "$DEL" == "200" ]]; then
    ok "and the quota can be deleted while it is tripped"
else
    bad "and the quota can be deleted while it is tripped" "DELETE returned ${DEL}"
fi

# ---------------------------------------------------------------------------
info ""
info "=== Without the admin exemption, the quota defends itself ==="
# ---------------------------------------------------------------------------
# The failure the exemption prevents, demonstrated rather than described.

sleep 2
printf '%s' '{"rate_limit_exempt_paths":["sys/health"],"enable_rate_limit_response_headers":true}' \
    | vault write sys/quotas/config - >/dev/null 2>&1
vault write sys/quotas/rate-limit/trap rate=1 interval=20s >/dev/null 2>&1

burn 5
TRAPPED="$(code DELETE sys/quotas/rate-limit/trap)"
if [[ "$TRAPPED" == "429" ]]; then
    ok "the DELETE that would remove it is itself refused"
else
    bad "the DELETE that would remove it is itself refused" \
        "got ${TRAPPED}; then sys/quotas needs no exemption and the script is wrong"
fi

# And the documented way out.
info "  waiting out the interval, then spending the first request on the delete..."
sleep 21
FREED="$(code DELETE sys/quotas/rate-limit/trap)"
if [[ "$FREED" == "204" || "$FREED" == "200" ]]; then
    ok "and the first request of a new window removes it"
else
    bad "and the first request of a new window removes it" "got ${FREED}"
fi

# ---------------------------------------------------------------------------
info ""
info "=== Telling a quota's 429 from a standby's ==="
# ---------------------------------------------------------------------------
# terraform/aws matches 200,429 on the target group, because 429 is how a
# healthy standby answers. So the code alone identifies nothing.

sleep 2
bash "$QUOTAS" --rate 1 --interval 20s --name headers >/dev/null 2>&1
burn 5

curl -sk --cacert "$CA" -D "${WORK}/quota.h" -o /dev/null \
    -H "X-Vault-Token: $VAULT_TOKEN" "${VAULT_ADDR}/v1/sys/mounts" 2>/dev/null
curl -sk --cacert "$CA" -D "${WORK}/standby.h" -o /dev/null \
    "https://127.0.0.1:8210/v1/sys/health" 2>/dev/null

if grep -qi "429" "${WORK}/standby.h" 2>/dev/null; then
    ok "a standby answers 429 on sys/health"
else
    bad "a standby answers 429 on sys/health" \
        "$(head -1 "${WORK}/standby.h" 2>/dev/null)"
fi

if grep -qi "x-ratelimit-limit" "${WORK}/quota.h" 2>/dev/null; then
    ok "a quota's 429 carries x-ratelimit-limit"
else
    bad "a quota's 429 carries x-ratelimit-limit" \
        "$(grep -i '^HTTP' "${WORK}/quota.h" 2>/dev/null)"
fi

if ! grep -qi "x-ratelimit-limit" "${WORK}/standby.h" 2>/dev/null; then
    ok "and a standby's 429 does not"
else
    bad "and a standby's 429 does not" \
        "then the header cannot distinguish them either"
fi

sleep 21
vault delete sys/quotas/rate-limit/headers >/dev/null 2>&1

# ---------------------------------------------------------------------------
printf '\n=== Results ===\npassed: %d\nfailed: %d\n' "$PASS" "$FAIL"
if [[ "$FAIL" -eq 0 ]]; then
    green "All ${PASS} assertions passed."
else
    red "FAILED"
fi
[[ "$FAIL" -eq 0 ]]

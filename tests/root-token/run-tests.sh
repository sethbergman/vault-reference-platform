#!/usr/bin/env bash
#
# run-tests.sh — Life after the root token
#
# Usage:
#   ./tests/root-token/run-tests.sh
#   ./tests/root-token/run-tests.sh --keep-running
#
# A few minutes. Stands up its own cluster and tears it down.
#
# WHY THIS EXISTS
#
# `vault operator init` mints a root token because a new cluster has no
# other way in. Once auth methods are configured it is a standing
# credential answering to no policy, expiring at no time, and present in
# every shell history that exported it. Vault's guidance is to revoke it
# and generate one on demand.
#
# This repository said nothing about that, which for a security reference
# reads as "keep it" -- a recommendation nobody meant to make.
#
# It also could not have said otherwise, because bootstrap-dev-cluster.sh
# discarded the recovery keys. With a seal stanza those are what
# `operator generate-root` needs, so revoking root was a one-way door and
# the advice would have bricked the cluster of anyone who took it.
#
# WHAT IT CHECKS
#
#   - the bootstrap keeps recovery keys, at 0600, and still prints only
#     the root token on stdout
#   - revoke-root-token.sh refuses without proof of another way in, and
#     refuses when the proof offered is itself a root token
#   - after revocation the root token is dead and an AppRole token still
#     works
#   - a new root token can be generated from a quorum of recovery keys
#   - and the new one is really root
#
# The refusals matter as much as the revocation. A guard only exercised
# in the state where it passes is not a guard, so both are run in the
# state where they should refuse.
#
# Requirements: docker compose, vault CLI, jq

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
COMPOSE=(docker compose -f "${REPO_ROOT}/docker/dev/docker-compose.yml")
KEYS_FILE="${REPO_ROOT}/docker/dev/.recovery-keys.json"

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

for dep in docker vault jq; do
    command -v "$dep" >/dev/null 2>&1 || { red "ERROR: ${dep} not found on PATH"; exit 1; }
done

export VAULT_ADDR="https://127.0.0.1:8200"
export VAULT_CACERT="${REPO_ROOT}/docker/dev/tls/ca.crt"

# ---------------------------------------------------------------------------
info ""
info "=== A cluster, and the keys that outlive its root token ==="
# ---------------------------------------------------------------------------
info "  clearing any previous cluster..."
"${COMPOSE[@]}" --profile spare down -v >/dev/null 2>&1
rm -f "$KEYS_FILE"

if ! ROOT_TOKEN="$("${REPO_ROOT}/scripts/bootstrap-dev-cluster.sh" 2>"${WORK}/bootstrap.log")"; then
    bad "the cluster came up" "$(tail -12 "${WORK}/bootstrap.log")"
    printf '\n=== Results ===\npassed: %d\nfailed: %d\n' "$PASS" "$FAIL"
    red "FAILED"
    exit 1
fi

# stdout is the root token and nothing else. Adding the recovery keys was
# the change most likely to break that, and a second line would be picked
# up as part of the token by every caller that does ROOT_TOKEN=$(...).
if [[ "$(wc -l <<< "$ROOT_TOKEN")" == "1" && "$ROOT_TOKEN" == hv* ]]; then
    ok "the bootstrap still prints only the root token on stdout"
else
    bad "the bootstrap still prints only the root token on stdout" \
        "got $(wc -l <<< "$ROOT_TOKEN") line(s)"
fi

if [[ -f "$KEYS_FILE" ]]; then
    ok "the recovery keys were kept"
else
    bad "the recovery keys were kept" \
        "without them, revoking the root token is a one-way door"
fi

MODE="$(stat -c '%a' "$KEYS_FILE" 2>/dev/null || echo "?")"
if [[ "$MODE" == "600" ]]; then
    ok "and written 0600"
else
    bad "and written 0600" "mode is ${MODE}"
fi

if git -C "$REPO_ROOT" check-ignore -q docker/dev/.recovery-keys.json; then
    ok "and gitignored"
else
    bad "and gitignored" "a key in version control is compromised from the moment it lands"
fi

THRESHOLD="$(jq -r '.recovery_keys_threshold' "$KEYS_FILE" 2>/dev/null || echo 0)"
SHARES="$(jq -r '.recovery_keys_b64 | length' "$KEYS_FILE" 2>/dev/null || echo 0)"
if [[ "$SHARES" -ge "$THRESHOLD" && "$THRESHOLD" -gt 0 ]]; then
    ok "with at least a threshold of shares (${SHARES} of ${THRESHOLD} needed)"
else
    bad "with at least a threshold of shares" "shares=${SHARES} threshold=${THRESHOLD}"
fi

export VAULT_TOKEN="$ROOT_TOKEN"

# ---------------------------------------------------------------------------
info ""
info "=== Another way in, before giving up this one ==="
# ---------------------------------------------------------------------------
vault secrets enable -path=roottest -version=2 kv >/dev/null 2>&1
cat > "${WORK}/policy.hcl" <<'HCL'
path "roottest/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
path "sys/health" {
  capabilities = ["read"]
}
HCL

"${REPO_ROOT}/scripts/bootstrap-approle.sh" --role admin \
    --policy-file "${WORK}/policy.hcl" >"${WORK}/approle.log" 2>&1
SECRET_ID="$("${REPO_ROOT}/scripts/rotate-secret-id.sh" --role admin 2>/dev/null | tail -1)"
ROLE_ID="$(vault read -field=role_id auth/approle/role/admin/role-id 2>/dev/null)"
APPROLE_TOKEN="$(vault write -field=token auth/approle/login \
    role_id="$ROLE_ID" secret_id="$SECRET_ID" 2>/dev/null)"

if [[ -n "$APPROLE_TOKEN" ]]; then
    ok "an AppRole login yields a working non-root token"
else
    bad "an AppRole login yields a working non-root token" \
        "the rest of this suite cannot run without one"
fi

# ---------------------------------------------------------------------------
info ""
info "=== The guards, in the state where they should refuse ==="
# ---------------------------------------------------------------------------
if "${REPO_ROOT}/scripts/revoke-root-token.sh" >"${WORK}/no-verify.log" 2>&1; then
    bad "revoking refuses without proof of another way in" "it revoked anyway"
else
    if grep -q "verify-with" "${WORK}/no-verify.log"; then
        ok "revoking refuses without proof of another way in"
    else
        bad "revoking refuses without proof of another way in" \
            "it failed for another reason: $(tail -2 "${WORK}/no-verify.log")"
    fi
fi

# Offering root as the proof proves nothing about life after root.
if "${REPO_ROOT}/scripts/revoke-root-token.sh" --verify-with "$ROOT_TOKEN" \
        >"${WORK}/root-verify.log" 2>&1; then
    bad "revoking refuses when the proof offered is itself root" "it revoked anyway"
else
    if grep -q "itself a root token" "${WORK}/root-verify.log"; then
        ok "revoking refuses when the proof offered is itself root"
    else
        bad "revoking refuses when the proof offered is itself root" \
            "it failed for another reason: $(tail -2 "${WORK}/root-verify.log")"
    fi
fi

# The assertion that would have caught the original guard.
#
# It checked `vault read sys/health`, which is unauthenticated -- the
# bootstrap polls it with plain curl and no token -- so it answered for
# any token at all, including one entitled to nothing. The check passed
# exactly when the lookup before it already had.
#
# A token with only the default policy is the case that separates the two
# implementations: it authenticates, it passes lookup-self, sys/health
# answers it, and it can administer nothing. Handing it over as proof of
# a way back in should be refused.
# -policy=default explicitly. A child of a root token inherits the
# parent's policies when none are named, so a plain `vault token create`
# here produces another root token -- which the check above then refuses,
# for the wrong reason, and the assertion fails while the guard it is
# testing works. The first run of this assertion did exactly that.
DEFAULT_ONLY="$(vault token create -policy=default -field=token 2>/dev/null)"
if [[ -n "$DEFAULT_ONLY" ]] && "${REPO_ROOT}/scripts/revoke-root-token.sh" \
        --verify-with "$DEFAULT_ONLY" >"${WORK}/default-only.log" 2>&1; then
    bad "revoking refuses a token entitled to nothing" \
        "it accepted a default-only token as proof of a way back in, and revoked root"
else
    if grep -q "no policy beyond" "${WORK}/default-only.log"; then
        ok "revoking refuses a token entitled to nothing"
    else
        bad "revoking refuses a token entitled to nothing" \
            "it failed for another reason: $(tail -3 "${WORK}/default-only.log")"
    fi
fi

# And the root token is still usable, so none of the three refusals
# revoked anything on their way out.
if vault token lookup >/dev/null 2>&1; then
    ok "and no refusal revoked the root token on its way out"
else
    bad "and no refusal revoked the root token on its way out" \
        "root is already gone before the revocation step"
fi

# ---------------------------------------------------------------------------
info ""
info "=== Revoking it ==="
# ---------------------------------------------------------------------------
if "${REPO_ROOT}/scripts/revoke-root-token.sh" --verify-with "$APPROLE_TOKEN" \
        >"${WORK}/revoke.log" 2>&1; then
    ok "revoke-root-token.sh completed with a valid non-root token"
else
    bad "revoke-root-token.sh completed with a valid non-root token" \
        "$(tail -6 "${WORK}/revoke.log")"
fi

if vault token lookup >/dev/null 2>&1; then
    bad "the root token no longer works" "it still does"
else
    ok "the root token no longer works"
fi

if VAULT_TOKEN="$APPROLE_TOKEN" vault kv put -mount=roottest canary v=1 >/dev/null 2>&1; then
    ok "the AppRole token still administers the cluster"
else
    bad "the AppRole token still administers the cluster" \
        "revoking root took the rest of the cluster with it"
fi

# ---------------------------------------------------------------------------
info ""
info "=== Getting one back ==="
# ---------------------------------------------------------------------------
unset VAULT_TOKEN
NEW_ROOT="$("${REPO_ROOT}/scripts/generate-root-token.sh" \
    --keys-file "$KEYS_FILE" 2>"${WORK}/genroot.log" | tail -1)"

if [[ -n "$NEW_ROOT" ]]; then
    ok "a new root token was generated from a quorum of recovery keys"
else
    bad "a new root token was generated from a quorum of recovery keys" \
        "$(tail -8 "${WORK}/genroot.log")"
fi

if [[ -n "$NEW_ROOT" ]] && VAULT_TOKEN="$NEW_ROOT" vault token lookup -format=json 2>/dev/null \
        | jq -e '.data.policies | index("root")' >/dev/null 2>&1; then
    ok "and it really carries the root policy"
else
    bad "and it really carries the root policy"
fi

# The point of the whole exercise: the new one is a different credential,
# not the old one coming back.
if [[ -n "$NEW_ROOT" && "$NEW_ROOT" != "$ROOT_TOKEN" ]]; then
    ok "and it is a different token from the one that was revoked"
else
    bad "and it is a different token from the one that was revoked"
fi

# ---------------------------------------------------------------------------
printf '\n=== Results ===\n'
# ---------------------------------------------------------------------------
printf 'passed: %d\nfailed: %d\n' "$PASS" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then red "FAILED"; exit 1; fi
green "All ${PASS} assertions passed against a real cluster."

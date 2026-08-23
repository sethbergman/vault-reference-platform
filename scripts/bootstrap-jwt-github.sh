#!/usr/bin/env bash
#
# bootstrap-jwt-github.sh — Let GitHub Actions authenticate to Vault with no stored secret
#
# Usage:
#   ./bootstrap-jwt-github.sh --role <name> --policy-file <path> \
#       --repository <owner/repo> [options]
#
# Example:
#   ./bootstrap-jwt-github.sh \
#       --role github-ci \
#       --policy-file examples/policies/ci-readonly.hcl \
#       --repository sethbergman/vault-reference-platform \
#       --bound-ref refs/heads/main
#
# What it does:
#   1. Writes the given policy file to Vault under --policy-name (defaults
#      to --role).
#   2. Enables the JWT auth method at auth/jwt, if not already enabled.
#      Safe to re-run — this step is a no-op if it's already enabled.
#   3. Points it at GitHub's OIDC provider. Vault fetches GitHub's public
#      signing keys from the discovery URL and refreshes them on its own,
#      so key rotation on GitHub's side needs no action here.
#   4. Creates (or updates) a role that accepts GitHub Actions tokens
#      matching --repository (and --bound-ref, if given).
#
# Why this instead of AppRole:
#   AppRole needs a secret_id — a real credential that has to be delivered
#   to the workload, stored somewhere, and rotated on a cadence (see
#   rotate-secret-id.sh). A GitHub Actions OIDC token is minted fresh by
#   GitHub for each job, expires in minutes, and is never stored anywhere.
#   There is no long-lived secret to leak, so there is nothing to rotate.
#   AppRole is still the right answer for workloads that aren't running in
#   an OIDC-capable platform.
#
# On bound claims — this is the part that actually matters:
#   Without bound claims, ANY GitHub repository in the world could present
#   a valid GitHub-signed token and authenticate to this role. The
#   signature only proves "GitHub issued this", not "GitHub issued this to
#   you". --repository is what restricts it to your repo, and --bound-ref
#   narrows it further to a single branch/tag. Bind as tightly as the
#   workflow allows.
#
# Requirements:
#   - vault CLI and jq on PATH
#   - VAULT_ADDR and VAULT_TOKEN set (or --vault-addr/--vault-token), with
#     a token authorized to write sys/policies, sys/auth, and auth/jwt/*
#   - Vault must be able to reach https://token.actions.githubusercontent.com
#     to fetch GitHub's signing keys.

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
ROLE=""
POLICY_FILE=""
POLICY_NAME=""
REPOSITORY=""
BOUND_REF=""
AUDIENCE="vault"
TOKEN_TTL="15m"
TOKEN_MAX_TTL="30m"
VAULT_ADDR="${VAULT_ADDR:-}"
VAULT_TOKEN="${VAULT_TOKEN:-}"

GITHUB_OIDC_ISSUER="https://token.actions.githubusercontent.com"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()  { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
die()  { log "ERROR: $*"; exit 1; }

usage() {
    grep '^#' "$0" | sed -e '1d' -e 's/^# \{0,1\}//'
    exit 1
}

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --role)           ROLE="$2"; shift 2 ;;
        --policy-file)    POLICY_FILE="$2"; shift 2 ;;
        --policy-name)    POLICY_NAME="$2"; shift 2 ;;
        --repository)     REPOSITORY="$2"; shift 2 ;;
        --bound-ref)      BOUND_REF="$2"; shift 2 ;;
        --audience)       AUDIENCE="$2"; shift 2 ;;
        --token-ttl)      TOKEN_TTL="$2"; shift 2 ;;
        --token-max-ttl)  TOKEN_MAX_TTL="$2"; shift 2 ;;
        --vault-addr)     VAULT_ADDR="$2"; shift 2 ;;
        --vault-token)    VAULT_TOKEN="$2"; shift 2 ;;
        -h|--help)        usage ;;
        *) die "Unknown argument: $1" ;;
    esac
done

command -v vault >/dev/null 2>&1 || die "vault CLI not found on PATH"
command -v jq    >/dev/null 2>&1 || die "jq not found on PATH"
[[ -z "$ROLE" ]] && die "--role is required"
[[ -z "$POLICY_FILE" ]] && die "--policy-file is required"
[[ -f "$POLICY_FILE" ]] || die "Policy file not found: ${POLICY_FILE}"
[[ -z "$REPOSITORY" ]] && die "--repository is required (e.g. owner/repo) — without it, any repo's token would be accepted"
[[ "$REPOSITORY" == */* ]] || die "--repository must be in owner/repo form, got: ${REPOSITORY}"
[[ -z "$VAULT_ADDR" ]] && die "VAULT_ADDR is not set (env var or --vault-addr)"
[[ -z "$VAULT_TOKEN" ]] && die "VAULT_TOKEN is not set (env var or --vault-token)"

[[ -z "$POLICY_NAME" ]] && POLICY_NAME="$ROLE"

export VAULT_ADDR VAULT_TOKEN

# ---------------------------------------------------------------------------
# Step 1: Write the policy
# ---------------------------------------------------------------------------
log "Writing policy '${POLICY_NAME}' from ${POLICY_FILE}"
vault policy write "$POLICY_NAME" "$POLICY_FILE" \
    || die "Failed to write policy ${POLICY_NAME}"

# ---------------------------------------------------------------------------
# Step 2: Enable the JWT auth method (idempotent)
# ---------------------------------------------------------------------------
if vault auth list -format=json 2>/dev/null | jq -e '."jwt/"' >/dev/null 2>&1; then
    log "JWT auth method already enabled — skipping"
else
    log "Enabling JWT auth method at auth/jwt"
    vault auth enable jwt || die "Failed to enable jwt auth method"
fi

# ---------------------------------------------------------------------------
# Step 3: Point it at GitHub's OIDC provider
# ---------------------------------------------------------------------------
log "Configuring auth/jwt against ${GITHUB_OIDC_ISSUER}"
vault write auth/jwt/config \
    oidc_discovery_url="${GITHUB_OIDC_ISSUER}" \
    bound_issuer="${GITHUB_OIDC_ISSUER}" \
    || die "Failed to configure auth/jwt — can Vault reach ${GITHUB_OIDC_ISSUER}?"

# ---------------------------------------------------------------------------
# Step 4: Create/update the role
# ---------------------------------------------------------------------------
# Built as a JSON payload rather than CLI key=value pairs: bound_claims is a
# map, and passing a map through the CLI means relying on it to re-parse an
# embedded JSON string. Writing the whole body as JSON removes that guesswork.
BOUND_CLAIMS="$(jq -n --arg repo "$REPOSITORY" '{repository: $repo}')"
if [[ -n "$BOUND_REF" ]]; then
    BOUND_CLAIMS="$(jq -n --arg repo "$REPOSITORY" --arg ref "$BOUND_REF" \
        '{repository: $repo, ref: $ref}')"
fi

PAYLOAD="$(jq -n \
    --arg aud "$AUDIENCE" \
    --arg policy "$POLICY_NAME" \
    --arg ttl "$TOKEN_TTL" \
    --arg max_ttl "$TOKEN_MAX_TTL" \
    --argjson bound_claims "$BOUND_CLAIMS" \
    '{
        role_type: "jwt",
        bound_audiences: [$aud],
        bound_claims: $bound_claims,
        # sub is the most specific identifier GitHub sends — it encodes
        # repo, ref and event type, so audit entries name the exact
        # workflow context rather than just a repo or an actor.
        user_claim: "sub",
        token_policies: [$policy],
        token_ttl: $ttl,
        token_max_ttl: $max_ttl
    }')"

log "Writing role 'auth/jwt/role/${ROLE}' (repository=${REPOSITORY}${BOUND_REF:+, ref=${BOUND_REF}}, audience=${AUDIENCE}, policy=${POLICY_NAME})"
echo "$PAYLOAD" | vault write "auth/jwt/role/${ROLE}" - \
    || die "Failed to write role ${ROLE}"

log "Role '${ROLE}' is ready."
log ""
log "In a GitHub Actions workflow, grant the job 'id-token: write' and log in with:"
log "  TOKEN=\$(curl -sH \"Authorization: bearer \$ACTIONS_ID_TOKEN_REQUEST_TOKEN\" \\"
log "    \"\$ACTIONS_ID_TOKEN_REQUEST_URL&audience=${AUDIENCE}\" | jq -r .value)"
log "  vault write -field=token auth/jwt/login role=${ROLE} jwt=\"\$TOKEN\""
log ""
log "No secret is stored anywhere in that flow — nothing to rotate."

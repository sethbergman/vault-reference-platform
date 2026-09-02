#!/usr/bin/env bash
#
# bootstrap-oidc.sh — Configure Vault OIDC login for humans, mapping IdP groups to policies
#
# Usage:
#   ./bootstrap-oidc.sh --discovery-url <url> --client-id <id> --client-secret <secret> \
#       [--group <idp-group>:<policy-file> ...] [options]
#
# Example (against the local Dex in docker/dex):
#   ./bootstrap-oidc.sh \
#       --discovery-url http://dex:5556/dex \
#       --client-id vault \
#       --client-secret vault-dev-client-secret \
#       --group vault-developers:examples/policies/developer.hcl \
#       --group vault-operators:examples/policies/operator.hcl
#
# What it does:
#   1. Enables the OIDC auth method at auth/oidc, if not already enabled.
#      Safe to re-run.
#   2. Points it at the identity provider and registers Vault's client
#      credentials.
#   3. Creates a login role that requests the "groups" claim and allows
#      the CLI and UI callback URLs.
#   4. For each --group, writes the policy, creates an *external* Vault
#      identity group, and aliases it to the IdP's group name.
#
# Why step 4 is the interesting one:
#   Vault does not read policies out of a token's group claim directly.
#   The claim carries a group *name* from the IdP; Vault has to be told
#   what that name means. An external identity group plus a group alias
#   is that mapping. Without it, login succeeds and the user gets nothing
#   but the default policy — which looks like a broken login but is
#   really unmapped groups.
#
#   The upshot worth knowing: group membership lives in the IdP. Granting
#   someone access means adding them to a group there, not touching
#   Vault. Revoking works the same way — which is the entire reason to
#   wire humans up this way instead of handing out tokens.
#
# Requirements:
#   - vault CLI and jq on PATH
#   - VAULT_ADDR and VAULT_TOKEN set (or --vault-addr/--vault-token), with
#     a token authorized to write sys/policies, sys/auth, auth/oidc/* and
#     identity/*
#   - Vault must be able to reach the discovery URL.

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
DISCOVERY_URL=""
CLIENT_ID=""
CLIENT_SECRET=""
ROLE="default"
USER_CLAIM="email"
GROUPS_CLAIM="groups"
TOKEN_TTL="1h"
TOKEN_MAX_TTL="8h"
GROUP_MAPPINGS=()
VAULT_ADDR="${VAULT_ADDR:-}"
VAULT_TOKEN="${VAULT_TOKEN:-}"

# Where Vault sends the browser back to after the IdP authenticates.
# 8250 is the port the Vault CLI listens on during `vault login`.
#
# The third entry is the web UI's own callback, served by Vault itself.
# The UI is a separate login path from the CLI and needs its own URI
# allowed: without it, UI login fails with "redirect_uri is not allowed"
# while the CLI keeps working perfectly -- which reads like a broken UI
# rather than a missing entry in a list. It was absent here while the
# step 3 note above already claimed it was allowed.
#
# A redirect URI has to match on BOTH sides, exactly. These mirror the
# staticClients entry in docker/dex/config.yaml; change one and change
# the other. https rather than http because the local listener serves
# TLS, and an exact match means the scheme counts.
#
# Only the dev cluster lives at localhost:8200. Against a real
# deployment, override the whole list with --redirect-uris.
REDIRECT_URIS="http://localhost:8250/oidc/callback"
REDIRECT_URIS+=",http://127.0.0.1:8250/oidc/callback"
REDIRECT_URIS+=",https://localhost:8200/ui/vault/auth/oidc/oidc/callback"

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
        --discovery-url)  DISCOVERY_URL="$2"; shift 2 ;;
        --client-id)      CLIENT_ID="$2"; shift 2 ;;
        --client-secret)  CLIENT_SECRET="$2"; shift 2 ;;
        --role)           ROLE="$2"; shift 2 ;;
        --user-claim)     USER_CLAIM="$2"; shift 2 ;;
        --groups-claim)   GROUPS_CLAIM="$2"; shift 2 ;;
        --group)          GROUP_MAPPINGS+=("$2"); shift 2 ;;
        --redirect-uris)  REDIRECT_URIS="$2"; shift 2 ;;
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
[[ -z "$DISCOVERY_URL" ]] && die "--discovery-url is required"
[[ -z "$CLIENT_ID" ]] && die "--client-id is required"
[[ -z "$CLIENT_SECRET" ]] && die "--client-secret is required"
[[ -z "$VAULT_ADDR" ]] && die "VAULT_ADDR is not set (env var or --vault-addr)"
[[ -z "$VAULT_TOKEN" ]] && die "VAULT_TOKEN is not set (env var or --vault-token)"

export VAULT_ADDR VAULT_TOKEN

# ---------------------------------------------------------------------------
# Step 1: Enable the OIDC auth method (idempotent)
# ---------------------------------------------------------------------------
if vault auth list -format=json 2>/dev/null | jq -e '."oidc/"' >/dev/null 2>&1; then
    log "OIDC auth method already enabled — skipping"
else
    log "Enabling OIDC auth method at auth/oidc"
    vault auth enable oidc || die "Failed to enable oidc auth method"
fi

# ---------------------------------------------------------------------------
# Step 2: Point it at the identity provider
# ---------------------------------------------------------------------------
log "Configuring auth/oidc against ${DISCOVERY_URL}"
vault write auth/oidc/config \
    oidc_discovery_url="$DISCOVERY_URL" \
    oidc_client_id="$CLIENT_ID" \
    oidc_client_secret="$CLIENT_SECRET" \
    default_role="$ROLE" \
    || die "Failed to configure auth/oidc — can Vault reach ${DISCOVERY_URL}?"

# ---------------------------------------------------------------------------
# Step 3: Create the login role
# ---------------------------------------------------------------------------
# Written as JSON because allowed_redirect_uris is a list; building it
# with jq avoids depending on the CLI to split a comma-separated string.
REDIRECT_JSON="$(jq -Rn --arg uris "$REDIRECT_URIS" '$uris | split(",")')"

ROLE_PAYLOAD="$(jq -n \
    --argjson redirect_uris "$REDIRECT_JSON" \
    --arg user_claim "$USER_CLAIM" \
    --arg groups_claim "$GROUPS_CLAIM" \
    --arg ttl "$TOKEN_TTL" \
    --arg max_ttl "$TOKEN_MAX_TTL" \
    '{
        role_type: "oidc",
        allowed_redirect_uris: $redirect_uris,
        user_claim: $user_claim,
        groups_claim: $groups_claim,
        oidc_scopes: ["openid", "profile", "email", "groups"],
        # Deliberately no token_policies: everything a human can do should
        # come from their group membership, so an unmapped user lands with
        # only the default policy rather than silently inheriting access.
        token_ttl: $ttl,
        token_max_ttl: $max_ttl
    }')"

log "Writing role 'auth/oidc/role/${ROLE}' (user_claim=${USER_CLAIM}, groups_claim=${GROUPS_CLAIM})"
echo "$ROLE_PAYLOAD" | vault write "auth/oidc/role/${ROLE}" - \
    || die "Failed to write role ${ROLE}"

# ---------------------------------------------------------------------------
# Step 4: Map IdP groups to Vault policies
# ---------------------------------------------------------------------------
if [[ ${#GROUP_MAPPINGS[@]} -gt 0 ]]; then
    ACCESSOR="$(vault auth list -format=json | jq -r '."oidc/".accessor')"
    [[ -n "$ACCESSOR" && "$ACCESSOR" != "null" ]] || die "Could not read the oidc/ mount accessor"
    log "OIDC mount accessor: ${ACCESSOR}"

    for mapping in "${GROUP_MAPPINGS[@]}"; do
        IDP_GROUP="${mapping%%:*}"
        POLICY_FILE="${mapping#*:}"

        [[ -n "$IDP_GROUP" && -n "$POLICY_FILE" && "$IDP_GROUP" != "$mapping" ]] \
            || die "--group must be <idp-group>:<policy-file>, got: ${mapping}"
        [[ -f "$POLICY_FILE" ]] || die "Policy file not found: ${POLICY_FILE}"

        # Policy name is derived from the IdP group name so the two stay
        # visibly connected in `vault policy list`.
        POLICY_NAME="$IDP_GROUP"

        log "Writing policy '${POLICY_NAME}' from ${POLICY_FILE}"
        vault policy write "$POLICY_NAME" "$POLICY_FILE" \
            || die "Failed to write policy ${POLICY_NAME}"

        # External group: membership is asserted by the IdP at login time,
        # not maintained inside Vault.
        log "Creating external identity group '${POLICY_NAME}'"
        GROUP_ID="$(vault write -field=id identity/group \
            name="$POLICY_NAME" \
            type="external" \
            policies="$POLICY_NAME" 2>/dev/null || true)"

        if [[ -z "$GROUP_ID" ]]; then
            # Already exists — look up its id and make sure the policy is attached.
            GROUP_ID="$(vault read -field=id "identity/group/name/${POLICY_NAME}")" \
                || die "Could not create or read identity group ${POLICY_NAME}"
            vault write "identity/group/id/${GROUP_ID}" \
                name="$POLICY_NAME" type="external" policies="$POLICY_NAME" >/dev/null \
                || die "Failed to update identity group ${POLICY_NAME}"
            log "  (group already existed — policy re-attached)"
        fi

        # The alias is the actual join: "when a token from this mount
        # carries a group named $IDP_GROUP, that means this Vault group".
        log "Aliasing IdP group '${IDP_GROUP}' -> Vault group '${POLICY_NAME}'"
        vault write identity/group-alias \
            name="$IDP_GROUP" \
            mount_accessor="$ACCESSOR" \
            canonical_id="$GROUP_ID" >/dev/null \
            || die "Failed to create group alias for ${IDP_GROUP}"
    done
fi

log ""
log "OIDC login is ready. A human logs in with:"
log "  vault login -method=oidc role=${ROLE}"
log ""
log "That opens a browser to the identity provider. Group membership there"
log "decides what the resulting Vault token can do — nothing to provision"
log "per-person in Vault."

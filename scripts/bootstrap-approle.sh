#!/usr/bin/env bash
#
# bootstrap-approle.sh — One-time (idempotent) setup of an AppRole role
#
# Usage:
#   ./bootstrap-approle.sh --role <name> --policy-file <path> [options]
#
# Example:
#   ./bootstrap-approle.sh --role app \
#       --policy-file examples/policies/app-readonly.hcl \
#       --secret-id-ttl 768h --token-ttl 1h --token-max-ttl 4h
#
# What it does:
#   1. Writes the given policy file to Vault under --policy-name (defaults
#      to --role).
#   2. Enables the AppRole auth method at auth/approle, if not already
#      enabled. Safe to re-run — this step is a no-op if AppRole is already
#      enabled.
#   3. Creates (or updates) an AppRole role bound to that policy, with the
#      given token/secret_id TTLs.
#
# This script does NOT generate a secret_id — that is a credential, not
# configuration, and is handled separately (and repeatably) by
# rotate-secret-id.sh. Run this script once per role; run the rotation
# script on a recurring cadence.
#
# Requirements:
#   - vault CLI on PATH
#   - VAULT_ADDR and VAULT_TOKEN set (or --vault-addr/--vault-token), with
#     a token authorized to write sys/policies, sys/auth, and
#     auth/approle/role/*

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
ROLE=""
POLICY_FILE=""
POLICY_NAME=""
SECRET_ID_TTL="768h"
TOKEN_TTL="1h"
TOKEN_MAX_TTL="4h"
VAULT_ADDR="${VAULT_ADDR:-}"
VAULT_TOKEN="${VAULT_TOKEN:-}"

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
        --role)            ROLE="$2"; shift 2 ;;
        --policy-file)      POLICY_FILE="$2"; shift 2 ;;
        --policy-name)      POLICY_NAME="$2"; shift 2 ;;
        --secret-id-ttl)    SECRET_ID_TTL="$2"; shift 2 ;;
        --token-ttl)        TOKEN_TTL="$2"; shift 2 ;;
        --token-max-ttl)    TOKEN_MAX_TTL="$2"; shift 2 ;;
        --vault-addr)       VAULT_ADDR="$2"; shift 2 ;;
        --vault-token)      VAULT_TOKEN="$2"; shift 2 ;;
        -h|--help)          usage ;;
        *) die "Unknown argument: $1" ;;
    esac
done

command -v vault >/dev/null 2>&1 || die "vault CLI not found on PATH"
[[ -z "$ROLE" ]] && die "--role is required"
[[ -z "$POLICY_FILE" ]] && die "--policy-file is required"
[[ -f "$POLICY_FILE" ]] || die "Policy file not found: ${POLICY_FILE}"
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
# Step 2: Enable AppRole auth (idempotent)
# ---------------------------------------------------------------------------
if vault auth list -format=json 2>/dev/null | grep -q '"approle/"'; then
    log "AppRole auth method already enabled — skipping"
else
    log "Enabling AppRole auth method"
    vault auth enable approle || die "Failed to enable approle auth method"
fi

# ---------------------------------------------------------------------------
# Step 3: Create/update the role
# ---------------------------------------------------------------------------
log "Writing role 'auth/approle/role/${ROLE}' (policy=${POLICY_NAME}, secret_id_ttl=${SECRET_ID_TTL}, token_ttl=${TOKEN_TTL}, token_max_ttl=${TOKEN_MAX_TTL})"
vault write "auth/approle/role/${ROLE}" \
    token_policies="${POLICY_NAME}" \
    secret_id_ttl="${SECRET_ID_TTL}" \
    token_ttl="${TOKEN_TTL}" \
    token_max_ttl="${TOKEN_MAX_TTL}" \
    || die "Failed to write role ${ROLE}"

ROLE_ID="$(vault read -field=role_id "auth/approle/role/${ROLE}/role-id")" \
    || die "Role was written but role-id could not be read back"

log "Role '${ROLE}' is ready. role_id=${ROLE_ID}"
log "role_id is not secret and can be baked into workload config. Run"
log "rotate-secret-id.sh to issue the first secret_id."

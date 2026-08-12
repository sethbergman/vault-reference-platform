#!/usr/bin/env bash
#
# rotate-secret-id.sh — Issue a new AppRole secret_id and revoke the last one
#
# Usage:
#   ./rotate-secret-id.sh --role <name> [options]
#
# Example:
#   ./rotate-secret-id.sh --role app --state-dir ./.vault-rotation-state
#   ./rotate-secret-id.sh --role app --wrap-ttl 5m   # safe handoff to a consumer
#
# What it does:
#   1. Looks up the role's role_id (not secret — safe to print/log).
#   2. Issues a new secret_id for the role.
#   3. If a previous rotation recorded a secret_id_accessor for this role
#      (in --state-dir), revokes that accessor now — so only one live
#      secret_id exists per role at a time, unless --no-revoke is passed.
#   4. Records the new secret_id's accessor to --state-dir for the next run.
#   5. Prints the role_id and the new secret_id (or, with --wrap-ttl, a
#      single-use wrapping token that a consumer can unwrap exactly once —
#      preferred over passing the raw secret_id around).
#
# The state file only ever stores an accessor, which identifies a
# secret_id for revocation purposes but cannot itself be used to
# authenticate. Losing it just means the next rotation won't be able to
# clean up the previous secret_id automatically (harmless — it will still
# expire on its own per secret_id_ttl).
#
# Run this on a recurring schedule (cron, CI, etc.) — every run rotates.
# The role itself must already exist; see bootstrap-approle.sh.
#
# Requirements:
#   - vault CLI and jq on PATH
#   - VAULT_ADDR and VAULT_TOKEN set (or --vault-addr/--vault-token), with
#     a token authorized on auth/approle/role/<role>/secret-id and
#     auth/approle/role/<role>/secret-id-accessor/destroy

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
ROLE=""
STATE_DIR="./.vault-rotation-state"
WRAP_TTL=""
NO_REVOKE=false
VAULT_ADDR="${VAULT_ADDR:-}"
VAULT_TOKEN="${VAULT_TOKEN:-}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()  { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }
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
        --role)         ROLE="$2"; shift 2 ;;
        --state-dir)    STATE_DIR="$2"; shift 2 ;;
        --wrap-ttl)     WRAP_TTL="$2"; shift 2 ;;
        --no-revoke)    NO_REVOKE=true; shift ;;
        --vault-addr)   VAULT_ADDR="$2"; shift 2 ;;
        --vault-token)  VAULT_TOKEN="$2"; shift 2 ;;
        -h|--help)      usage ;;
        *) die "Unknown argument: $1" ;;
    esac
done

command -v vault >/dev/null 2>&1 || die "vault CLI not found on PATH"
command -v jq    >/dev/null 2>&1 || die "jq not found on PATH"
[[ -z "$ROLE" ]] && die "--role is required"
[[ -z "$VAULT_ADDR" ]] && die "VAULT_ADDR is not set (env var or --vault-addr)"
[[ -z "$VAULT_TOKEN" ]] && die "VAULT_TOKEN is not set (env var or --vault-token)"

export VAULT_ADDR VAULT_TOKEN

STATE_FILE="${STATE_DIR}/${ROLE}.accessor"

# Log messages go to stderr; only the final, intended-for-capture output
# (role_id / secret_id / wrap token) goes to stdout.

# ---------------------------------------------------------------------------
# Step 1: Confirm the role exists
# ---------------------------------------------------------------------------
ROLE_ID="$(vault read -field=role_id "auth/approle/role/${ROLE}/role-id" 2>/dev/null)" \
    || die "Role '${ROLE}' not found — run bootstrap-approle.sh first"

# ---------------------------------------------------------------------------
# Step 2: Issue a new secret_id
# ---------------------------------------------------------------------------
log "Issuing new secret_id for role '${ROLE}'"
SECRET_ID_JSON="$(vault write -f -format=json "auth/approle/role/${ROLE}/secret-id")" \
    || die "Failed to issue secret_id for role ${ROLE}"

NEW_SECRET_ID="$(jq -r '.data.secret_id' <<< "$SECRET_ID_JSON")"
NEW_ACCESSOR="$(jq -r '.data.secret_id_accessor' <<< "$SECRET_ID_JSON")"
NEW_TTL="$(jq -r '.data.secret_id_ttl' <<< "$SECRET_ID_JSON")"

[[ -n "$NEW_SECRET_ID" && "$NEW_SECRET_ID" != "null" ]] || die "No secret_id in response"

# ---------------------------------------------------------------------------
# Step 3: Revoke the previously issued secret_id, if we have a record of it
# ---------------------------------------------------------------------------
mkdir -p "$STATE_DIR"

if [[ "$NO_REVOKE" == false && -f "$STATE_FILE" ]]; then
    PREV_ACCESSOR="$(cat "$STATE_FILE")"
    if [[ -n "$PREV_ACCESSOR" ]]; then
        log "Revoking previous secret_id (accessor ${PREV_ACCESSOR})"
        if vault write "auth/approle/role/${ROLE}/secret-id-accessor/destroy" \
            secret_id_accessor="$PREV_ACCESSOR" >/dev/null 2>&1; then
            log "Previous secret_id revoked"
        else
            log "WARNING: could not revoke previous accessor (already expired/destroyed?) — continuing"
        fi
    fi
elif [[ "$NO_REVOKE" == true ]]; then
    log "--no-revoke set — leaving any previous secret_id in place"
fi

# ---------------------------------------------------------------------------
# Step 4: Record the new accessor for next time
# ---------------------------------------------------------------------------
echo "$NEW_ACCESSOR" > "$STATE_FILE"
chmod 600 "$STATE_FILE"
log "Recorded new accessor to ${STATE_FILE}"

# ---------------------------------------------------------------------------
# Step 5: Emit the credential
# ---------------------------------------------------------------------------
log "New secret_id issued, ttl=${NEW_TTL}s"

if [[ -n "$WRAP_TTL" ]]; then
    log "Wrapping secret_id for single-use handoff (wrap-ttl=${WRAP_TTL})"
    WRAP_JSON="$(vault write -wrap-ttl="$WRAP_TTL" -format=json sys/wrapping/wrap \
        role_id="$ROLE_ID" secret_id="$NEW_SECRET_ID")" \
        || die "Failed to wrap secret_id"
    WRAP_TOKEN="$(jq -r '.wrap_info.token' <<< "$WRAP_JSON")"
    log "Hand this wrapping token to the consumer; it can be unwrapped exactly once (vault unwrap <token>) within ${WRAP_TTL}."
    echo "$WRAP_TOKEN"
else
    log "role_id (not secret): ${ROLE_ID}"
    log "secret_id below is shown once — store it in the consumer's secret store, not in shell history or logs."
    echo "$NEW_SECRET_ID"
fi

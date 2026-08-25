#!/usr/bin/env bash
#
# bootstrap-agent.sh — Provision an AppRole for Vault Agent and place its
#                      credentials where Agent expects them
#
# Usage:
#   ./bootstrap-agent.sh [options]
#
# Options:
#   --role <name>       AppRole role name (default: vault-agent)
#   --creds-dir <dir>   Where role_id and secret_id are written
#                       (default: docker/dev/agent)
#   --policy-file <p>   Policy for the role
#                       (default: examples/policies/vault-agent.hcl)
#   --wrap-ttl <dur>    Deliver the secret_id response-wrapped instead of
#                       writing it in the clear. See SECRET ZERO below.
#   --token-ttl <dur>   Token TTL for the role (default: 20m)
#   --secret-id-ttl <d> secret_id TTL (default: 24h)
#
# WHAT THIS IS FOR
#
# Everything else in this repository configures Vault. This is the piece
# that shows an application getting a secret out of it — and the notable
# part is what the application does not do. It does not authenticate, does
# not hold a token, and makes no Vault API call. It reads a file that
# Vault Agent keeps current.
#
# The availability consequence is the reason to care: if Vault becomes
# unreachable, the rendered file is still on disk. A Vault outage stops
# being an immediate outage of everything downstream.
#
# SECRET ZERO
#
# Agent does not solve it. Something has to place a role_id and a
# secret_id on the host, and whatever does that is trusted. What Agent
# changes is the size of the problem: the credential on disk is
# short-lived, single-purpose, and deleted by Agent once read, rather than
# a long-lived token with broad policy sitting in an environment variable.
#
# This script writes the secret_id in the clear by default because that is
# what a local demonstration needs. --wrap-ttl is the honest mechanism: it
# writes a single-use wrapping token instead, which only the intended
# consumer can unwrap, and which is useless to anyone who reads it
# afterwards. Use it for anything real.
#
# Requirements: vault, jq, and a VAULT_TOKEN able to write policies and
# manage auth/approle.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

ROLE="vault-agent"
CREDS_DIR="${REPO_ROOT}/docker/dev/agent"
POLICY_FILE="${REPO_ROOT}/examples/policies/vault-agent.hcl"
WRAP_TTL=""
TOKEN_TTL="20m"
SECRET_ID_TTL="24h"

log() { printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

usage() {
    grep '^#' "$0" | sed -e '1d' -e 's/^# \{0,1\}//'
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --role)          ROLE="$2"; shift 2 ;;
        --creds-dir)     CREDS_DIR="$2"; shift 2 ;;
        --policy-file)   POLICY_FILE="$2"; shift 2 ;;
        --wrap-ttl)      WRAP_TTL="$2"; shift 2 ;;
        --token-ttl)     TOKEN_TTL="$2"; shift 2 ;;
        --secret-id-ttl) SECRET_ID_TTL="$2"; shift 2 ;;
        -h|--help)       usage ;;
        *) die "Unknown argument: $1" ;;
    esac
done

command -v vault >/dev/null 2>&1 || die "vault not found on PATH"
command -v jq    >/dev/null 2>&1 || die "jq not found on PATH"
[[ -n "${VAULT_ADDR:-}" ]]  || die "VAULT_ADDR is not set"
[[ -n "${VAULT_TOKEN:-}" ]] || die "VAULT_TOKEN is not set"
[[ -f "$POLICY_FILE" ]] || die "No policy file at ${POLICY_FILE}"

APPROLE_SCRIPT="${SCRIPT_DIR}/bootstrap-approle.sh"
ROTATE_SCRIPT="${SCRIPT_DIR}/rotate-secret-id.sh"
[[ -x "$APPROLE_SCRIPT" ]] || die "${APPROLE_SCRIPT} is missing or not executable"
[[ -x "$ROTATE_SCRIPT" ]]  || die "${ROTATE_SCRIPT} is missing or not executable"

# ---------------------------------------------------------------------------
# The role
# ---------------------------------------------------------------------------
# Composed from the existing AppRole scripts rather than reimplemented.
# One place creates roles and one place issues secret_ids; a third copy of
# that logic would be a third thing to keep correct.
log "Creating the ${ROLE} AppRole from ${POLICY_FILE}..."
"$APPROLE_SCRIPT" \
    --role "$ROLE" \
    --policy-file "$POLICY_FILE" \
    --token-ttl "$TOKEN_TTL" \
    --secret-id-ttl "$SECRET_ID_TTL" >&2 \
    || die "Could not create the ${ROLE} AppRole"

# ---------------------------------------------------------------------------
# The credentials
# ---------------------------------------------------------------------------
mkdir -p "$CREDS_DIR"
chmod 0700 "$CREDS_DIR" 2>/dev/null || true

ROLE_ID="$(vault read -field=role_id "auth/approle/role/${ROLE}/role-id" 2>/dev/null)" \
    || die "Could not read the role_id for ${ROLE}"
[[ -n "$ROLE_ID" ]] || die "Empty role_id for ${ROLE}"

# role_id is an identifier, not a secret — it is useless without a
# secret_id. Written 0644 so this is not mistaken for one.
printf '%s' "$ROLE_ID" > "${CREDS_DIR}/role_id"
chmod 0644 "${CREDS_DIR}/role_id" 2>/dev/null || true
log "Wrote ${CREDS_DIR}/role_id"

ROTATE_ARGS=(--role "$ROLE" --state-dir "${REPO_ROOT}/.vault-rotation-state")
[[ -n "$WRAP_TTL" ]] && ROTATE_ARGS+=(--wrap-ttl "$WRAP_TTL")

SECRET_VALUE="$("$ROTATE_SCRIPT" "${ROTATE_ARGS[@]}" 2>/dev/null)" \
    || die "Could not issue a secret_id for ${ROLE}"
[[ -n "$SECRET_VALUE" ]] || die "Empty secret_id for ${ROLE}"

# umask before the write, not chmod after: chmod leaves a window in which
# the file exists with the default mode and the credential is already in
# it.
OLD_UMASK="$(umask)"
umask 077
printf '%s' "$SECRET_VALUE" > "${CREDS_DIR}/secret_id"
umask "$OLD_UMASK"

if [[ -n "$WRAP_TTL" ]]; then
    log "Wrote ${CREDS_DIR}/secret_id as a response-wrapped token (ttl ${WRAP_TTL})."
    log "Agent unwraps it once; a second reader gets nothing and the"
    log "unwrap failure is itself the tamper signal."
else
    log "Wrote ${CREDS_DIR}/secret_id in the clear (mode 0600)."
    log "Use --wrap-ttl for anything that is not a local demonstration."
fi

log ""
log "Agent removes the secret_id file once it has read it. A restart"
log "therefore needs a fresh one — re-run this script, or have whatever"
log "manages the host do it."
log ""
log "Start it with: docker compose up -d vault-agent"
log "See docs/vault-agent.md."

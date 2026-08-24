#!/usr/bin/env bash
#
# bootstrap-database-secrets.sh — Configure Vault to issue database credentials
#
# Usage:
#   ./bootstrap-database-secrets.sh [options]
#
# Options:
#   --mount <path>       Mount path (default: database)
#   --name <name>        Connection name (default: appdata)
#   --host <host:port>   Postgres address (default: postgres:5432)
#   --database <db>      Database name (default: appdata)
#   --username <user>    Bootstrap superuser (default: vaultadmin)
#   --password <pw>      Bootstrap password (default: $POSTGRES_PASSWORD)
#   --sslmode <mode>     libpq sslmode (default: disable — see below)
#   --default-ttl <d>    Lease TTL for issued credentials (default: 1h)
#   --max-ttl <d>        Maximum lease TTL (default: 24h)
#   --no-rotate-root     Skip rotating the bootstrap password
#   --force              Reconfigure a connection that already exists
#
# WHAT THIS IS FOR
#
# Every other secret in this repository is one somebody created and Vault
# stored. These are different: the credential does not exist until it is
# asked for, belongs to exactly one consumer, and expires on its own.
#
# There is no shared database password to leak, rotate on a schedule, or
# find in a CI log two years later, because there is no shared password.
#
# ROOT ROTATION
#
# The last step rotates the password of the account Vault connects with,
# and Vault does not report the new value. After it runs, nobody — not
# the operator who ran this, not anything in version control — knows the
# credential to that database. Only Vault does.
#
# That is the intended end state, and it has a real consequence worth
# understanding before running it: if Vault's storage is lost and cannot
# be restored, that account has to be reset out-of-band by a database
# superuser. Pass --no-rotate-root to skip it, and read
# docs/disaster-recovery.md first if you are considering that.
#
# TLS TO THE DATABASE
#
# sslmode defaults to `disable`, which is correct for the local Docker
# profile — where Vault and Postgres share a container network and no
# certificate authority exists — and wrong everywhere else. A real
# deployment should pass --sslmode verify-full. This default is a
# convenience for the dev profile, not a recommendation; see
# docs/dynamic-secrets.md.
#
# Requirements: vault, jq, and a VAULT_TOKEN able to mount and configure
# secrets engines.

set -euo pipefail

MOUNT="database"
NAME="appdata"
HOST="postgres:5432"
DATABASE="appdata"
USERNAME="vaultadmin"
PASSWORD="${POSTGRES_PASSWORD:-}"
SSLMODE="disable"
DEFAULT_TTL="1h"
MAX_TTL="24h"
ROTATE_ROOT=true
FORCE=false

log() { printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

usage() {
    grep '^#' "$0" | sed -e '1d' -e 's/^# \{0,1\}//'
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --mount)          MOUNT="$2"; shift 2 ;;
        --name)           NAME="$2"; shift 2 ;;
        --host)           HOST="$2"; shift 2 ;;
        --database)       DATABASE="$2"; shift 2 ;;
        --username)       USERNAME="$2"; shift 2 ;;
        --password)       PASSWORD="$2"; shift 2 ;;
        --sslmode)        SSLMODE="$2"; shift 2 ;;
        --default-ttl)    DEFAULT_TTL="$2"; shift 2 ;;
        --max-ttl)        MAX_TTL="$2"; shift 2 ;;
        --no-rotate-root) ROTATE_ROOT=false; shift ;;
        --force)          FORCE=true; shift ;;
        -h|--help)        usage ;;
        *) die "Unknown argument: $1" ;;
    esac
done

command -v vault >/dev/null 2>&1 || die "vault not found on PATH"
command -v jq    >/dev/null 2>&1 || die "jq not found on PATH"
[[ -n "${VAULT_ADDR:-}" ]]  || die "VAULT_ADDR is not set"
[[ -n "${VAULT_TOKEN:-}" ]] || die "VAULT_TOKEN is not set"
[[ -n "$PASSWORD" ]] || die "No bootstrap password: pass --password or set POSTGRES_PASSWORD"

ROLE_READONLY="${NAME}-readonly"
ROLE_READWRITE="${NAME}-readwrite"

# ---------------------------------------------------------------------------
# Mount
# ---------------------------------------------------------------------------
if vault secrets list -format=json 2>/dev/null | jq -e --arg m "${MOUNT}/" 'has($m)' >/dev/null; then
    log "A secrets engine is already mounted at ${MOUNT}/."
else
    log "Enabling the database engine at ${MOUNT}/..."
    vault secrets enable -path="$MOUNT" database >/dev/null \
        || die "Could not enable the database engine at ${MOUNT}"
fi

# ---------------------------------------------------------------------------
# Connection
# ---------------------------------------------------------------------------
# Refusing by default is not politeness. Once the root password has been
# rotated, the value passed here is stale — rewriting the connection with
# it replaces a working credential with one the database will reject, and
# every subsequent issuance fails.
if vault read "${MOUNT}/config/${NAME}" >/dev/null 2>&1 && [[ "$FORCE" == false ]]; then
    log "Connection ${MOUNT}/config/${NAME} already exists; leaving it alone."
    log "Pass --force to overwrite it — but note that if the root password"
    log "has been rotated, the password given here is no longer valid and"
    log "overwriting will break credential issuance."
else
    log "Configuring the connection to ${HOST}/${DATABASE}..."

    # allowed_roles is a deny-by-default list. Omit it and no role can use
    # this connection; set it to "*" and every future role can, including
    # ones added later by someone who did not think about this connection.
    vault write "${MOUNT}/config/${NAME}" \
        plugin_name="postgresql-database-plugin" \
        allowed_roles="${ROLE_READONLY},${ROLE_READWRITE}" \
        connection_url="postgresql://{{username}}:{{password}}@${HOST}/${DATABASE}?sslmode=${SSLMODE}" \
        username="$USERNAME" \
        password="$PASSWORD" >/dev/null \
        || die "Could not configure ${MOUNT}/config/${NAME} — is Postgres reachable at ${HOST}?"
fi

# ---------------------------------------------------------------------------
# Roles
# ---------------------------------------------------------------------------
# {{name}}, {{password}} and {{expiration}} are substituted by Vault per
# issuance. VALID UNTIL '{{expiration}}' matters: it makes the database
# itself enforce the expiry, so a credential dies on schedule even if
# Vault is unreachable when the lease ends and cannot run the revocation.
log "Creating the ${ROLE_READONLY} role (ttl ${DEFAULT_TTL}, max ${MAX_TTL})..."
vault write "${MOUNT}/roles/${ROLE_READONLY}" \
    db_name="$NAME" \
    creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}';
        GRANT CONNECT ON DATABASE \"${DATABASE}\" TO \"{{name}}\";
        GRANT USAGE ON SCHEMA public TO \"{{name}}\";
        GRANT SELECT ON ALL TABLES IN SCHEMA public TO \"{{name}}\";" \
    revocation_statements="REASSIGN OWNED BY \"{{name}}\" TO \"${USERNAME}\";
        DROP OWNED BY \"{{name}}\";
        DROP ROLE IF EXISTS \"{{name}}\";" \
    default_ttl="$DEFAULT_TTL" \
    max_ttl="$MAX_TTL" >/dev/null \
    || die "Could not create the ${ROLE_READONLY} role"

log "Creating the ${ROLE_READWRITE} role (ttl ${DEFAULT_TTL}, max ${MAX_TTL})..."
vault write "${MOUNT}/roles/${ROLE_READWRITE}" \
    db_name="$NAME" \
    creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}';
        GRANT CONNECT ON DATABASE \"${DATABASE}\" TO \"{{name}}\";
        GRANT USAGE, CREATE ON SCHEMA public TO \"{{name}}\";
        GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO \"{{name}}\";" \
    revocation_statements="REASSIGN OWNED BY \"{{name}}\" TO \"${USERNAME}\";
        DROP OWNED BY \"{{name}}\";
        DROP ROLE IF EXISTS \"{{name}}\";" \
    default_ttl="$DEFAULT_TTL" \
    max_ttl="$MAX_TTL" >/dev/null \
    || die "Could not create the ${ROLE_READWRITE} role"

# ---------------------------------------------------------------------------
# Policies
# ---------------------------------------------------------------------------
# Read on database/creds/<role> is what issuing a credential requires. A
# consumer needs nothing else — not the connection config, not the role
# definition, and certainly not the other role's credentials.
log "Writing consumer policies..."
for role in "$ROLE_READONLY" "$ROLE_READWRITE"; do
    vault policy write "${role}" - >/dev/null <<EOF || die "Could not write the ${role} policy"
# Issue ${role} database credentials.
#
# Read on the creds path is the whole permission. Deliberately no access
# to ${MOUNT}/config/* — that holds the credential Vault itself connects
# with, and a consumer that can read it does not need dynamic credentials
# because it already has the keys to the database.
path "${MOUNT}/creds/${role}" {
  capabilities = ["read"]
}

# So a consumer can hand back a credential it has finished with rather
# than leaving it to expire.
path "sys/leases/revoke" {
  capabilities = ["update"]
}

path "auth/token/lookup-self" {
  capabilities = ["read"]
}

path "auth/token/renew-self" {
  capabilities = ["update"]
}
EOF
done

# ---------------------------------------------------------------------------
# Rotate the bootstrap password
# ---------------------------------------------------------------------------
# Last, because everything above needs the connection working, and once
# this runs the password used to configure it is dead.
if [[ "$ROTATE_ROOT" == true ]]; then
    log "Rotating the bootstrap password..."
    vault write -f "${MOUNT}/rotate-root/${NAME}" >/dev/null \
        || die "Could not rotate the root credential for ${NAME}"
    log "Rotated. The password this script was given is now invalid, and"
    log "the new one is known only to Vault."
else
    log "NOT rotating the bootstrap password (--no-rotate-root)."
    log "The password passed to this script still works, which means it is"
    log "a shared database credential — the thing dynamic secrets exist to"
    log "remove. Rotate it before this reaches anything real."
fi

log ""
log "Done. Issue a credential with:"
log "  vault read ${MOUNT}/creds/${ROLE_READONLY}"
log ""
log "Each read returns a new user, valid for ${DEFAULT_TTL}, dropped from"
log "the database when the lease ends. See docs/dynamic-secrets.md."

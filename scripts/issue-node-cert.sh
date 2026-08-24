#!/usr/bin/env bash
#
# issue-node-cert.sh — Issue or renew this node's TLS certificate from Vault PKI
#
# Usage:
#   ./issue-node-cert.sh --common-name vault-0.vault.internal [options]
#
# Options:
#   --common-name <cn>   Certificate common name (required)
#   --alt-names <list>   Comma-separated additional DNS SANs
#   --ip-sans <list>     Comma-separated IP SANs
#   --mount <path>       PKI mount path (default: pki)
#   --role <name>        PKI role name (default: vault-node)
#   --tls-dir <dir>      Where the certificate lives (default: /etc/vault.d/tls)
#   --ttl <duration>     Requested lifetime (default: 72h)
#   --renew-within <d>   Renew only if the current cert expires within this
#                        many days (default: 1)
#   --force              Renew regardless of remaining lifetime
#   --reload-cmd <cmd>   How to tell Vault to reload (default: systemctl reload vault)
#   --no-reload          Write the files but do not signal Vault
#
# Runs from a systemd timer on every node. Renews only when the current
# certificate is close to expiry, so the common case is a no-op that
# touches nothing and signals nothing.
#
# WHY SIGHUP AND NOT A RESTART
#
# Vault reloads the *contents* of tls_cert_file and tls_key_file on
# SIGHUP, using the paths it was started with. So renewing in place and
# signalling is graceful: no restart, no re-unseal, no leadership change.
#
# The corollary is that the paths must not change. Vault ignores a
# modified tls_cert_file value on SIGHUP — it keeps using the path from
# startup — so writing the new certificate somewhere else and pointing
# the config at it would appear to work and silently keep serving the old
# certificate until the next restart.
#
# WHY BOTH FILES MOVE BEFORE THE SIGNAL
#
# A certificate and key that do not match means the listener fails to
# load and the node stops serving TLS. Both files are staged, verified as
# a pair, and only then moved into place — then, and only then, is Vault
# signalled.
#
# Requirements: vault, jq, openssl

set -euo pipefail

COMMON_NAME=""
ALT_NAMES=""
IP_SANS=""
MOUNT="pki"
ROLE="vault-node"
TLS_DIR="/etc/vault.d/tls"
TTL="72h"
RENEW_WITHIN_DAYS=1
FORCE=false
RELOAD_CMD="systemctl reload vault"
NO_RELOAD=false

log() { printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

usage() {
    grep '^#' "$0" | sed -e '1d' -e 's/^# \{0,1\}//'
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --common-name)  COMMON_NAME="$2"; shift 2 ;;
        --alt-names)    ALT_NAMES="$2"; shift 2 ;;
        --ip-sans)      IP_SANS="$2"; shift 2 ;;
        --mount)        MOUNT="$2"; shift 2 ;;
        --role)         ROLE="$2"; shift 2 ;;
        --tls-dir)      TLS_DIR="$2"; shift 2 ;;
        --ttl)          TTL="$2"; shift 2 ;;
        --renew-within) RENEW_WITHIN_DAYS="$2"; shift 2 ;;
        --force)        FORCE=true; shift ;;
        --reload-cmd)   RELOAD_CMD="$2"; shift 2 ;;
        --no-reload)    NO_RELOAD=true; shift ;;
        -h|--help)      usage ;;
        *) die "Unknown argument: $1" ;;
    esac
done

[[ -n "$COMMON_NAME" ]] || die "--common-name is required"

command -v vault   >/dev/null 2>&1 || die "vault not found on PATH"
command -v jq      >/dev/null 2>&1 || die "jq not found on PATH"
command -v openssl >/dev/null 2>&1 || die "openssl not found on PATH"

CERT="${TLS_DIR}/vault.crt"
KEY="${TLS_DIR}/vault.key"
CA="${TLS_DIR}/ca.crt"

# ---------------------------------------------------------------------------
# Does anything need doing?
# ---------------------------------------------------------------------------
# Checked before authenticating, so the hourly no-op case never touches
# Vault at all.
if [[ "$FORCE" == false && -f "$CERT" ]]; then
    SECONDS_AHEAD=$(( RENEW_WITHIN_DAYS * 86400 ))
    if openssl x509 -in "$CERT" -noout -checkend "$SECONDS_AHEAD" >/dev/null 2>&1; then
        NOT_AFTER="$(openssl x509 -in "$CERT" -noout -enddate 2>/dev/null | cut -d= -f2-)"
        log "Certificate is valid beyond ${RENEW_WITHIN_DAYS}d (expires ${NOT_AFTER}); nothing to do."
        exit 0
    fi
    log "Certificate expires within ${RENEW_WITHIN_DAYS}d; renewing."
else
    if [[ "$FORCE" == true ]]; then
        log "Renewing because --force was given."
    else
        log "No certificate at ${CERT}; issuing one."
    fi
fi

[[ -n "${VAULT_ADDR:-}" ]] || die "VAULT_ADDR is not set"

# ---------------------------------------------------------------------------
# Authenticate
# ---------------------------------------------------------------------------
LOGIN_TOKEN=""

if [[ -n "${VAULT_TOKEN:-}" ]]; then
    : # supplied by the caller or the EnvironmentFile
elif [[ -n "${VAULT_ROLE_ID:-}" && -n "${VAULT_SECRET_ID:-}" ]]; then
    log "Logging in with AppRole..."
    LOGIN_JSON="$(vault write -format=json auth/approle/login \
        role_id="${VAULT_ROLE_ID}" secret_id="${VAULT_SECRET_ID}" 2>/dev/null)" \
        || die "AppRole login failed"
    LOGIN_TOKEN="$(jq -r '.auth.client_token' <<< "$LOGIN_JSON")"
    [[ -n "$LOGIN_TOKEN" && "$LOGIN_TOKEN" != "null" ]] || die "AppRole login returned no token"
    export VAULT_TOKEN="$LOGIN_TOKEN"
else
    die "No credentials: set VAULT_TOKEN, or VAULT_ROLE_ID and VAULT_SECRET_ID"
fi

# ---------------------------------------------------------------------------
# Staging
# ---------------------------------------------------------------------------
umask 077
STAGE="$(mktemp -d)"

cleanup() {
    local rc=$?
    rm -rf "$STAGE"
    if [[ -n "$LOGIN_TOKEN" ]]; then
        vault token revoke -self >/dev/null 2>&1 || true
    fi
    exit "$rc"
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Issue
# ---------------------------------------------------------------------------
log "Requesting a certificate for ${COMMON_NAME} from ${MOUNT}/issue/${ROLE}..."

ISSUE_ARGS=(
    "-format=json"
    "${MOUNT}/issue/${ROLE}"
    "common_name=${COMMON_NAME}"
    "ttl=${TTL}"
)
[[ -n "$ALT_NAMES" ]] && ISSUE_ARGS+=("alt_names=${ALT_NAMES}")
[[ -n "$IP_SANS" ]]   && ISSUE_ARGS+=("ip_sans=${IP_SANS}")

ISSUE_JSON="$(vault write "${ISSUE_ARGS[@]}" 2>/dev/null)" \
    || die "Certificate issuance failed — check the role's allowed_domains and this token's policy"

jq -e '.data.certificate and .data.private_key' <<< "$ISSUE_JSON" >/dev/null 2>&1 \
    || die "Vault returned no certificate or no private key"

jq -r '.data.certificate'   <<< "$ISSUE_JSON" > "${STAGE}/vault.crt"
jq -r '.data.private_key'   <<< "$ISSUE_JSON" > "${STAGE}/vault.key"

# issuing_ca alone is not enough when the chain has an intermediate in it.
# ca_chain is the full path to the root; fall back only if it is absent.
if jq -e '.data.ca_chain | length > 0' <<< "$ISSUE_JSON" >/dev/null 2>&1; then
    jq -r '.data.ca_chain[]' <<< "$ISSUE_JSON" > "${STAGE}/ca.crt"
else
    jq -r '.data.issuing_ca' <<< "$ISSUE_JSON" > "${STAGE}/ca.crt"
fi

# ---------------------------------------------------------------------------
# Verify before installing
# ---------------------------------------------------------------------------
[[ -s "${STAGE}/vault.crt" ]] || die "Issued certificate is empty"
[[ -s "${STAGE}/vault.key" ]] || die "Issued private key is empty"
[[ -s "${STAGE}/ca.crt" ]]    || die "Issued CA chain is empty"

openssl x509 -in "${STAGE}/vault.crt" -noout >/dev/null 2>&1 \
    || die "Issued certificate is not valid PEM"

# The pair must match. Installing a mismatched pair and signalling Vault
# takes the listener down, which on the active node is an outage.
CERT_MOD="$(openssl x509 -noout -modulus -in "${STAGE}/vault.crt" 2>/dev/null | openssl md5)"
KEY_MOD="$(openssl rsa -noout -modulus -in "${STAGE}/vault.key" 2>/dev/null | openssl md5)"
[[ -n "$CERT_MOD" && "$CERT_MOD" == "$KEY_MOD" ]] \
    || die "Issued certificate and key do not match — refusing to install them"

# And it must actually be for this node. A certificate for the wrong host
# installs cleanly, serves TLS, and is rejected by peers during the Raft
# join with an error that reads like a network problem.
#
# Matched on the output, not the exit code. `openssl x509 -checkhost`
# exits 1 on a mismatch in OpenSSL 3.5 but exits 0 in the 3.0 that Ubuntu
# ships — so an exit-code check silently accepts any certificate on
# exactly the distribution these nodes run. The wording has been stable
# across both: "does match" / "does NOT match".
CHECKHOST_OUT="$(openssl x509 -in "${STAGE}/vault.crt" -noout -checkhost "$COMMON_NAME" 2>&1 || true)"
if [[ "$CHECKHOST_OUT" != *"does match"* || "$CHECKHOST_OUT" == *"NOT match"* ]]; then
    die "Issued certificate does not match ${COMMON_NAME} — refusing to install it"
fi

log "Certificate verified."

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------
mkdir -p "$TLS_DIR"

# Ownership is inherited from whatever is already there, so a renewal does
# not silently change who can read the key.
OWNER="vault:vault"
if [[ -f "$KEY" ]]; then
    OWNER="$(stat -c '%U:%G' "$KEY" 2>/dev/null || echo "vault:vault")"
fi

install -m 0644 "${STAGE}/ca.crt"    "$CA"
install -m 0644 "${STAGE}/vault.crt" "$CERT"
install -m 0600 "${STAGE}/vault.key" "$KEY"
chown "$OWNER" "$CA" "$CERT" "$KEY" 2>/dev/null || true

log "Installed ${CERT}, ${KEY}, ${CA}"

# ---------------------------------------------------------------------------
# Reload
# ---------------------------------------------------------------------------
if [[ "$NO_RELOAD" == true ]]; then
    log "Not signalling Vault (--no-reload). It will serve the old certificate until reloaded."
    exit 0
fi

log "Signalling Vault to reload the certificate..."
# SIGHUP re-reads the files at the paths Vault started with. It does not
# drop connections, and it does not reseal.
$RELOAD_CMD || die "Reload failed — Vault is still serving the previous certificate"

log "Done."

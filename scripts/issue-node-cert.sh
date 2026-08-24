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
#   --cert-name <base>   Basename for the cert/key pair (default: vault, so
#                        vault.crt / vault.key). The local Docker profile
#                        uses per-node names, e.g. --cert-name vault-0.
#   --ca-name <file>     Trust bundle filename (default: ca.crt)
#   --replace-ca         Overwrite the trust bundle instead of adding to it.
#                        See the note on trust bundles below.
#   --ttl <duration>     Requested lifetime (default: 72h)
#   --renew-within <d>   Renew only if the current cert expires within this
#                        many days (default: 1)
#   --force              Renew regardless of remaining lifetime
#   --reload-cmd <cmd>   How to tell Vault to reload (default: systemctl reload vault)
#   --no-reload          Write the files but do not signal Vault
#   --no-verify-reload   Skip confirming Vault picked the certificate up
#   --verify-addr <h:p>  Where to confirm it (default: from VAULT_ADDR)
#   --key-mode <mode>    Mode for the private key (default: 0600). The
#                        local Docker profile needs 0644 because the
#                        container's vault uid does not own the host file.
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
# WHY THE TRUST BUNDLE IS ADDED TO, NOT REPLACED
#
# Nodes verify each other with tls_client_ca_file. During a migration to
# Vault PKI, some peers still present bootstrap certificates — so a node
# whose bundle was *replaced* with the PKI root stops trusting them, and
# the cluster comes apart one node at a time as the rollout proceeds.
#
# So the new chain is appended unless it is already present. The correct
# rollout order follows from that:
#
#   1. Every node's bundle gains the PKI CA (still trusting bootstrap).
#   2. Certificates are swapped one node at a time.
#   3. Only once every node is on PKI does the bootstrap CA come out.
#
# --replace-ca skips step 1's safety and is for step 3.
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
CERT_NAME="vault"
CA_NAME="ca.crt"
REPLACE_CA=false
TTL="72h"
RENEW_WITHIN_DAYS=1
FORCE=false
RELOAD_CMD="systemctl reload vault"
NO_RELOAD=false
VERIFY_RELOAD=true
VERIFY_ADDR=""
KEY_MODE="0600"

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
        --cert-name)    CERT_NAME="$2"; shift 2 ;;
        --ca-name)      CA_NAME="$2"; shift 2 ;;
        --replace-ca)   REPLACE_CA=true; shift ;;
        --ttl)          TTL="$2"; shift 2 ;;
        --renew-within) RENEW_WITHIN_DAYS="$2"; shift 2 ;;
        --force)        FORCE=true; shift ;;
        --reload-cmd)   RELOAD_CMD="$2"; shift 2 ;;
        --no-reload)    NO_RELOAD=true; shift ;;
        --no-verify-reload) VERIFY_RELOAD=false; shift ;;
        --verify-addr)  VERIFY_ADDR="$2"; shift 2 ;;
        --key-mode)     KEY_MODE="$2"; shift 2 ;;
        -h|--help)      usage ;;
        *) die "Unknown argument: $1" ;;
    esac
done

[[ -n "$COMMON_NAME" ]] || die "--common-name is required"

command -v vault   >/dev/null 2>&1 || die "vault not found on PATH"
command -v jq      >/dev/null 2>&1 || die "jq not found on PATH"
command -v openssl >/dev/null 2>&1 || die "openssl not found on PATH"

CERT="${TLS_DIR}/${CERT_NAME}.crt"
KEY="${TLS_DIR}/${CERT_NAME}.key"
CA="${TLS_DIR}/${CA_NAME}"

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

# fingerprints_of <pem-bundle> — one SHA256 fingerprint per certificate.
#
# Comparing fingerprints, not text. `grep -f newca bundle` looks like it
# would work and never does: grep -f treats every *line* of the pattern
# file as its own pattern, and "-----BEGIN CERTIFICATE-----" matches any
# bundle at all. That reads as "already present" every time, so the CA is
# never added and the migration quietly cannot proceed.
fingerprints_of() {
    local block="" line
    while IFS= read -r line || [[ -n "$line" ]]; do
        block+="${line}"$'\n'
        if [[ "$line" == *"END CERTIFICATE"* ]]; then
            openssl x509 -noout -fingerprint -sha256 2>/dev/null <<< "$block" | cut -d= -f2
            block=""
        fi
    done < "$1"
}

# The trust bundle is added to rather than replaced — see the note at the
# top. Replacing it mid-migration makes this node stop trusting every peer
# still on a bootstrap certificate.
if [[ "$REPLACE_CA" == true || ! -f "$CA" ]]; then
    install -m 0644 "${STAGE}/ca.crt" "$CA"
    [[ "$REPLACE_CA" == true ]] && log "Replaced the trust bundle (--replace-ca)."
else
    EXISTING_FPS="$(fingerprints_of "$CA")"
    ADDED=0
    cp "$CA" "${STAGE}/bundle.crt"

    BLOCK=""
    while IFS= read -r line || [[ -n "$line" ]]; do
        BLOCK+="${line}"$'\n'
        [[ "$line" == *"END CERTIFICATE"* ]] || continue
        FP="$(openssl x509 -noout -fingerprint -sha256 2>/dev/null <<< "$BLOCK" | cut -d= -f2)"
        if [[ -n "$FP" && "$EXISTING_FPS" != *"$FP"* ]]; then
            printf '%s' "$BLOCK" >> "${STAGE}/bundle.crt"
            ADDED=$((ADDED + 1))
        fi
        BLOCK=""
    done < "${STAGE}/ca.crt"

    if [[ "$ADDED" -gt 0 ]]; then
        install -m 0644 "${STAGE}/bundle.crt" "$CA"
        log "Added ${ADDED} certificate(s) to ${CA}, keeping what was already trusted."
    else
        log "The issuing CA is already in ${CA}; leaving it as is."
    fi
fi

install -m 0644 "${STAGE}/vault.crt" "$CERT"
install -m "$KEY_MODE" "${STAGE}/vault.key" "$KEY"
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
$RELOAD_CMD || die "Reload command failed — Vault is still serving the previous certificate"

# ---------------------------------------------------------------------------
# Confirm the reload actually took
# ---------------------------------------------------------------------------
# A zero exit from the reload command means the *signal* was delivered,
# not that Vault accepted the new material. Vault reports reload failures
# asynchronously, in its own log:
#
#   ==> Vault reload triggered
#   Error(s) were encountered during reload: 1 error occurred:
#       * error encountered reloading listener: open ...key: permission denied
#
# `systemctl reload` returns 0 in exactly that case too. Without this
# check the script reports success, the timer reports success, and the
# node quietly serves the old certificate until it expires — which is the
# failure this whole thing exists to prevent, arriving on a schedule.
#
# Found by tests/integration, which caught precisely this.
if [[ "$VERIFY_RELOAD" == false ]]; then
    log "Not verifying the reload (--no-verify-reload)."
    log "Done."
    exit 0
fi

WANT_SERIAL="$(openssl x509 -in "$CERT" -noout -serial 2>/dev/null | cut -d= -f2 || true)"
VERIFY_HOST="${VERIFY_ADDR:-${VAULT_ADDR#*://}}"
[[ "$VERIFY_HOST" == *:* ]] || VERIFY_HOST="${VERIFY_HOST}:8200"

log "Confirming ${VERIFY_HOST} is serving the new certificate..."
for attempt in $(seq 1 10); do
    SERVED_SERIAL="$(echo | openssl s_client -connect "$VERIFY_HOST" 2>/dev/null \
        | openssl x509 -noout -serial 2>/dev/null | cut -d= -f2 || true)"
    if [[ -n "$SERVED_SERIAL" && "$SERVED_SERIAL" == "$WANT_SERIAL" ]]; then
        log "Confirmed: serving ${SERVED_SERIAL}."
        log "Done."
        exit 0
    fi
    sleep 2
done

die "Vault still serves ${SERVED_SERIAL:-<unreadable>}, expected ${WANT_SERIAL}. The reload was signalled but did not take — check Vault's log for 'error encountered reloading listener' (a key it cannot read is the usual cause)."

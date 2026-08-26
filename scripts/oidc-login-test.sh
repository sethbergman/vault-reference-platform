#!/usr/bin/env bash
#
# oidc-login-test.sh — Drive a full OIDC login without a browser (testing only)
#
# Usage:
#   ./oidc-login-test.sh --username <email> --password <pw> [options]
#
# Example:
#   ./oidc-login-test.sh \
#       --username developer@example.com \
#       --password password \
#       --role default
#
# NOT a production login path. A real human runs:
#
#     vault login -method=oidc role=default
#
# which opens a browser. This script exists so CI can prove the same flow
# actually works end to end — that Vault and the IdP agree on the issuer,
# that the redirect round-trips, that the ID token validates, and that
# group claims map to policies. Mocking any of that would test nothing.
#
# It only works against an IdP whose login form takes a plain username and
# password POST (Dex's local connector, in docker/dex). Against a real IdP
# with MFA or a JS-driven login page it will not work, and shouldn't —
# that's the IdP doing its job.
#
# What it does:
#   1. Asks Vault for an authorization URL and pulls state/nonce out of it.
#   2. Follows that URL to the IdP's login form.
#   3. POSTs the credentials.
#   4. Follows redirects until the IdP hands back an authorization code.
#   5. Passes the code back to Vault, which exchanges it for a token.
#
# Output:
#   Log messages go to stderr; the Vault token is the only thing on
#   stdout, so it can be captured: TOKEN=$(./oidc-login-test.sh ...)
#
# Requirements:
#   - vault CLI, curl and jq on PATH
#   - VAULT_ADDR and VAULT_TOKEN (the latter only to reach auth_url; the
#     login itself is unauthenticated)
#   - The IdP must be reachable from THIS machine at the same hostname
#     Vault uses for it — see docs/human-authentication.md on /etc/hosts.

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
USERNAME=""
PASSWORD=""
ROLE="default"
MOUNT="oidc"
REDIRECT_URI="http://localhost:8250/oidc/callback"
CLIENT_NONCE="oidc-login-test-$$"
COOKIE_JAR=""

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()  { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }
die()  { log "ERROR: $*"; exit 1; }

usage() {
    grep '^#' "$0" | sed -e '1d' -e 's/^# \{0,1\}//'
    exit 1
}

cleanup() {
    # `if` rather than a trailing `&&`. A cleanup function whose last
    # command is a false test returns 1, and bash applies that to the
    # script's exit status from an EXIT trap -- so a run that did
    # everything right reports failure, and an explicit `exit 0` does not
    # save it. Live only once an early success path exists, which is
    # exactly the sort of thing added later without suspecting this.
    if [[ -n "$COOKIE_JAR" && -f "$COOKIE_JAR" ]]; then
        rm -f "$COOKIE_JAR"
    fi
}
trap cleanup EXIT

# Pull a single query parameter out of a URL.
query_param() {
    local url="$1" key="$2"
    printf '%s' "$url" | sed -n "s/.*[?&]${key}=\([^&]*\).*/\1/p"
}

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --username)     USERNAME="$2"; shift 2 ;;
        --password)     PASSWORD="$2"; shift 2 ;;
        --role)         ROLE="$2"; shift 2 ;;
        --mount)        MOUNT="$2"; shift 2 ;;
        --redirect-uri) REDIRECT_URI="$2"; shift 2 ;;
        -h|--help)      usage ;;
        *) die "Unknown argument: $1" ;;
    esac
done

command -v vault >/dev/null 2>&1 || die "vault CLI not found on PATH"
command -v curl  >/dev/null 2>&1 || die "curl not found on PATH"
command -v jq    >/dev/null 2>&1 || die "jq not found on PATH"
[[ -z "$USERNAME" ]] && die "--username is required"
[[ -z "$PASSWORD" ]] && die "--password is required"
[[ -z "${VAULT_ADDR:-}" ]] && die "VAULT_ADDR is not set"

COOKIE_JAR="$(mktemp)"

# The vault CLI reads VAULT_CACERT; curl does not. These raw requests
# need the CA passed explicitly, or they fail verification against the
# local dev CA once the listener serves TLS.
CURL_CA=()
[[ -n "${VAULT_CACERT:-}" ]] && CURL_CA=(--cacert "$VAULT_CACERT")

# Trailing slash would produce a double slash in the callback URL below.
VAULT_ADDR="${VAULT_ADDR%/}"
export VAULT_ADDR

# ---------------------------------------------------------------------------
# Step 1: Ask Vault where to send the browser
# ---------------------------------------------------------------------------
log "Requesting an authorization URL for role '${ROLE}'..."
AUTH_URL="$(vault write -field=auth_url "auth/${MOUNT}/oidc/auth_url" \
    role="$ROLE" \
    redirect_uri="$REDIRECT_URI" \
    client_nonce="$CLIENT_NONCE")" \
    || die "Failed to get an auth_url — is the role configured and the redirect_uri allowed?"

[[ -n "$AUTH_URL" ]] || die "Vault returned an empty auth_url"

STATE="$(query_param "$AUTH_URL" state)"
NONCE="$(query_param "$AUTH_URL" nonce)"
[[ -n "$STATE" ]] || die "Could not extract state from the auth_url"
[[ -n "$NONCE" ]] || die "Could not extract nonce from the auth_url"
log "Got an authorization URL (state and nonce extracted)."

# ---------------------------------------------------------------------------
# Step 2: Follow it to the IdP's login form
# ---------------------------------------------------------------------------
# The IdP redirects to a per-request login URL; -L follows that chain and
# --write-out reports where it landed, which is where credentials go.
log "Following the authorization URL to the identity provider..."
LOGIN_URL="$(curl -sS -c "$COOKIE_JAR" -b "$COOKIE_JAR" -L \
    -o /dev/null -w '%{url_effective}' "$AUTH_URL")" \
    || die "Could not reach the identity provider — is it running and resolvable at the issuer hostname?"

[[ -n "$LOGIN_URL" ]] || die "No login URL returned by the identity provider"
log "Login form at: ${LOGIN_URL}"

# ---------------------------------------------------------------------------
# Step 3: Submit credentials
# ---------------------------------------------------------------------------
# Deliberately no -L here: the response is a redirect, and the redirect
# target is what carries the flow forward.
log "Submitting credentials for ${USERNAME}..."
NEXT_URL="$(curl -sS -c "$COOKIE_JAR" -b "$COOKIE_JAR" \
    --data-urlencode "login=${USERNAME}" \
    --data-urlencode "password=${PASSWORD}" \
    -o /dev/null -w '%{redirect_url}' "$LOGIN_URL")" \
    || die "Credential POST failed"

[[ -n "$NEXT_URL" ]] || die "Login did not redirect — credentials probably rejected"

# ---------------------------------------------------------------------------
# Step 4: Follow redirects until the IdP hands back an authorization code
# ---------------------------------------------------------------------------
# Can't just use -L: the chain ends at the redirect_uri, which is a port
# nothing is listening on here (normally the Vault CLI's temporary
# listener). So step through manually and stop when we get there.
CODE=""
for _ in $(seq 1 6); do
    case "$NEXT_URL" in
        "${REDIRECT_URI}"*)
            CODE="$(query_param "$NEXT_URL" code)"
            break
            ;;
    esac
    [[ -n "$NEXT_URL" ]] || break
    NEXT_URL="$(curl -sS -c "$COOKIE_JAR" -b "$COOKIE_JAR" \
        -o /dev/null -w '%{redirect_url}' "$NEXT_URL")"
done

[[ -n "$CODE" ]] || die "Never received an authorization code (last URL: ${NEXT_URL:-none})"
log "Received an authorization code."

# ---------------------------------------------------------------------------
# Step 5: Trade the code for a Vault token
# ---------------------------------------------------------------------------
log "Exchanging the code with Vault..."
# Must be a GET with query parameters — that's the shape of the request a
# browser makes when the IdP redirects it here, and it's the only method
# the callback accepts (`vault write` sends a PUT and gets back a 405).
# The endpoint is unauthenticated: this request *is* the login.
CALLBACK_RESPONSE="$(curl -sS "${CURL_CA[@]}" -G "${VAULT_ADDR}/v1/auth/${MOUNT}/oidc/callback" \
    --data-urlencode "state=${STATE}" \
    --data-urlencode "nonce=${NONCE}" \
    --data-urlencode "code=${CODE}" \
    --data-urlencode "client_nonce=${CLIENT_NONCE}")" \
    || die "Callback request to Vault failed"

TOKEN="$(printf '%s' "$CALLBACK_RESPONSE" | jq -r '.auth.client_token // empty')"

if [[ -z "$TOKEN" ]]; then
    log "Vault rejected the callback. Response:"
    printf '%s\n' "$CALLBACK_RESPONSE" | jq . >&2 2>/dev/null \
        || printf '%s\n' "$CALLBACK_RESPONSE" >&2
    die "No token in the callback response"
fi
log "Login succeeded."
echo "$TOKEN"

#!/usr/bin/env bash
#
# bootstrap-pki.sh — Set up Vault's PKI engine to issue node certificates
#
# Usage:
#   ./bootstrap-pki.sh [options]
#
# Options:
#   --mount <path>        PKI mount path (default: pki)
#   --domain <domain>     Domain the node role may issue for
#                         (default: vault.internal)
#   --role <name>         PKI role name (default: vault-node)
#   --ca-ttl <duration>   Root CA lifetime (default: 87600h, ten years)
#   --cert-ttl <duration> Maximum leaf lifetime (default: 72h)
#   --force               Reconfigure even if the mount already exists
#
# THE BOOTSTRAP PROBLEM — read this before believing the docs.
#
# Vault's PKI engine cannot issue the certificates that the Vault cluster
# hosting it needs in order to start. Vault will not serve without TLS,
# so something else has to provide the first set of certificates:
#
#   local/CI   scripts/generate-dev-certs.sh
#   cloud      your own CA, or ACM Private CA
#
# What this script sets up is everything *after* that: renewals, and
# certificates for nodes that join later. The bootstrap certificates stay
# load-bearing until every node has been re-issued from Vault PKI and
# restarted, and the bootstrap CA has to stay in the trust bundle until
# then. There is no way around this ordering, and a reference platform
# that implies otherwise is lying to you.
#
# What this does:
#   1. Enables a PKI secrets engine and tunes its max lease TTL.
#   2. Generates an internal root CA.
#   3. Configures issuing and CRL URLs.
#   4. Creates a role scoped to the node domain, valid for both server
#      and client auth — Raft peers authenticate in both directions.
#
# Requirements: vault, jq, and a VAULT_TOKEN able to mount and configure
# secrets engines.

set -euo pipefail

MOUNT="pki"
DOMAIN="vault.internal"
ROLE="vault-node"
CA_TTL="87600h"
CERT_TTL="72h"
FORCE=false

log() { printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

usage() {
    grep '^#' "$0" | sed -e '1d' -e 's/^# \{0,1\}//'
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --mount)     MOUNT="$2"; shift 2 ;;
        --domain)    DOMAIN="$2"; shift 2 ;;
        --role)      ROLE="$2"; shift 2 ;;
        --ca-ttl)    CA_TTL="$2"; shift 2 ;;
        --cert-ttl)  CERT_TTL="$2"; shift 2 ;;
        --force)     FORCE=true; shift ;;
        -h|--help)   usage ;;
        *) die "Unknown argument: $1" ;;
    esac
done

command -v vault >/dev/null 2>&1 || die "vault not found on PATH"
command -v jq    >/dev/null 2>&1 || die "jq not found on PATH"
[[ -n "${VAULT_ADDR:-}" ]]  || die "VAULT_ADDR is not set"
[[ -n "${VAULT_TOKEN:-}" ]] || die "VAULT_TOKEN is not set"

# ---------------------------------------------------------------------------
# Mount
# ---------------------------------------------------------------------------
if vault secrets list -format=json 2>/dev/null | jq -e --arg m "${MOUNT}/" 'has($m)' >/dev/null; then
    if [[ "$FORCE" == false ]]; then
        log "A secrets engine is already mounted at ${MOUNT}/."
        log "Pass --force to reconfigure it, or --mount to use a different path."
        log ""
        log "Refusing by default because regenerating the root CA invalidates"
        log "every certificate already issued from this mount — including the"
        log "ones the running nodes are serving."
        exit 0
    fi
    log "Reusing the existing mount at ${MOUNT}/ (--force)."
else
    log "Enabling the PKI engine at ${MOUNT}/..."
    vault secrets enable -path="$MOUNT" pki >/dev/null \
        || die "Could not enable the PKI engine at ${MOUNT}"
fi

# The mount's max lease TTL caps everything issued from it, including the
# root. Left at the default 32 days, a ten-year root silently becomes a
# 32-day root.
log "Tuning the mount's max lease TTL to ${CA_TTL}..."
vault secrets tune -max-lease-ttl="$CA_TTL" "$MOUNT" >/dev/null \
    || die "Could not tune ${MOUNT}"

# ---------------------------------------------------------------------------
# Root CA
# ---------------------------------------------------------------------------
# An internal root: the private key is generated inside Vault and never
# leaves it. A production deployment would more likely make this an
# intermediate signed by an offline root, so that compromising this Vault
# does not compromise the whole trust chain. That needs a root this
# repository has no way to provide, so the tradeoff is stated rather than
# hidden — see docs/security.md.
if vault read -format=json "${MOUNT}/cert/ca" >/dev/null 2>&1 && [[ "$FORCE" == false ]]; then
    log "A root CA already exists at ${MOUNT}/; leaving it alone."
else
    log "Generating the root CA (ttl ${CA_TTL})..."
    vault write -format=json "${MOUNT}/root/generate/internal" \
        common_name="${DOMAIN} Root CA" \
        issuer_name="${ROLE}-root" \
        ttl="$CA_TTL" \
        key_type="rsa" \
        key_bits=4096 >/dev/null \
        || die "Could not generate the root CA"
fi

# ---------------------------------------------------------------------------
# URLs
# ---------------------------------------------------------------------------
# Without these the issued certificates carry no AIA or CRL pointers, and
# anything doing revocation checking has nowhere to look.
log "Configuring issuing and CRL URLs..."
vault write "${MOUNT}/config/urls" \
    issuing_certificates="${VAULT_ADDR}/v1/${MOUNT}/ca" \
    crl_distribution_points="${VAULT_ADDR}/v1/${MOUNT}/crl" >/dev/null \
    || die "Could not configure URLs"

# ---------------------------------------------------------------------------
# Node role
# ---------------------------------------------------------------------------
# server_flag and client_flag are both left on. Raft peers authenticate to
# each other in both directions, so a server-only certificate produces a
# cluster that serves clients happily and cannot form quorum — the same
# trap generate-dev-certs.sh calls out.
#
# allow_ip_sans matters for the same reason: nodes dial each other by IP
# (api_addr and cluster_addr are addresses, not names), so a certificate
# with only DNS SANs fails peer verification.
log "Creating the ${ROLE} role (max ttl ${CERT_TTL})..."
vault write "${MOUNT}/roles/${ROLE}" \
    allowed_domains="${DOMAIN},localhost" \
    allow_subdomains=true \
    allow_bare_domains=true \
    allow_localhost=true \
    allow_ip_sans=true \
    server_flag=true \
    client_flag=true \
    key_type="rsa" \
    key_bits=2048 \
    max_ttl="$CERT_TTL" \
    ttl="$CERT_TTL" >/dev/null \
    || die "Could not create the ${ROLE} role"

# ---------------------------------------------------------------------------
# Policy for the renewal agent
# ---------------------------------------------------------------------------
# Issuing only. The agent on a node cannot read the CA key, cannot revoke,
# and cannot change the role's constraints — so a compromised node can
# mint certificates for its own domain and nothing more.
POLICY_NAME="${ROLE}-issue"
log "Writing the ${POLICY_NAME} policy..."
vault policy write "$POLICY_NAME" - >/dev/null <<EOF || die "Could not write the policy"
# Issue node certificates from the ${MOUNT} PKI engine.
#
# Deliberately narrow: update on the single issue endpoint for one role.
# No access to ${MOUNT}/root/*, ${MOUNT}/config/*, ${MOUNT}/roles/*, or
# revocation. A node that can rewrite the role can issue for any domain.
path "${MOUNT}/issue/${ROLE}" {
  capabilities = ["update"]
}

# The CA chain, so a renewing node can refresh its trust bundle.
path "${MOUNT}/ca_chain" {
  capabilities = ["read"]
}

path "auth/token/lookup-self" {
  capabilities = ["read"]
}

path "auth/token/renew-self" {
  capabilities = ["update"]
}
EOF

log ""
log "PKI is configured."
log "  mount:  ${MOUNT}/"
log "  role:   ${ROLE} (max ttl ${CERT_TTL})"
log "  policy: ${POLICY_NAME}"
log ""
log "Export the CA for the trust bundle:"
log "  vault read -field=certificate ${MOUNT}/cert/ca"
log ""
log "Nodes renew with scripts/issue-node-cert.sh; see docs/security.md."
log ""
log "The bootstrap CA must stay trusted until every node has been"
log "re-issued from this mount and restarted."

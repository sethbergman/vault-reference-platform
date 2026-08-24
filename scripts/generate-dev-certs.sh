#!/usr/bin/env bash
#
# generate-dev-certs.sh — Issue a local CA and per-node certificates
#
# Usage:
#   ./generate-dev-certs.sh [--force]
#
# Creates docker/dev/tls/ containing:
#
#   ca.crt / ca.key        the local certificate authority
#   <node>.crt / <node>.key  one leaf per Vault node, plus vault-unseal
#
# These are development certificates for the local Docker Compose
# profile. The directory is gitignored and nothing here should ever be
# committed: a private key in version control is compromised from the
# moment it lands, whether or not anyone notices.
#
# Why per-node certificates rather than one shared one:
#   It is the shape a real deployment has, and it makes the failure modes
#   real too — a node presenting a certificate that doesn't match the name
#   its peers dial is exactly the kind of thing that works in a single
#   shared-cert setup and breaks the moment you move to per-node issuance.
#   Better to hit that here than in production.
#
# Every leaf carries localhost and 127.0.0.1 as well as its own name,
# because the host reaches each node through a published port on
# localhost while the nodes reach each other by container name.
#
# Requirements: openssl

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TLS_DIR="${SCRIPT_DIR}/../docker/dev/tls"
FORCE=false

# vault-unseal is included: it holds the Transit key that unseals
# everything else, so it has the least business speaking plaintext.
NODES=(vault-0 vault-1 vault-2 vault-unseal)

DAYS_CA=3650
DAYS_LEAF=825   # the practical browser/tooling ceiling for leaf certs

log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

usage() {
    grep '^#' "$0" | sed -e '1d' -e 's/^# \{0,1\}//'
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --force)   FORCE=true; shift ;;
        -h|--help) usage ;;
        *) die "Unknown argument: $1" ;;
    esac
done

command -v openssl >/dev/null 2>&1 || die "openssl not found on PATH"

# Git Bash / MSYS rewrites arguments that look like Unix paths into
# Windows ones, which turns an openssl subject of "/CN=foo" into
# "C:/Program Files/Git/CN=foo" and fails with an unhelpful message about
# the name format. Ignored on Linux and macOS, so it costs nothing to set
# unconditionally — and without it this script works in CI and fails on a
# Windows developer's machine.
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL="*"

if [[ -f "${TLS_DIR}/ca.crt" && "$FORCE" == false ]]; then
    log "Certificates already exist in ${TLS_DIR} — nothing to do."
    log "Pass --force to reissue them (every node must then be restarted)."
    exit 0
fi

mkdir -p "$TLS_DIR"
cd "$TLS_DIR"

# ---------------------------------------------------------------------------
# Certificate authority
# ---------------------------------------------------------------------------
log "Generating the local CA..."
openssl req -x509 -newkey rsa:4096 -sha256 -nodes \
    -keyout ca.key -out ca.crt -days "$DAYS_CA" \
    -subj "/CN=vault-reference-platform local CA/O=vault-reference-platform" \
    -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" \
    2>/dev/null || die "Failed to generate the CA"

chmod 600 ca.key

# ---------------------------------------------------------------------------
# Leaf certificates
# ---------------------------------------------------------------------------
for node in "${NODES[@]}"; do
    log "Issuing a certificate for ${node}..."

    openssl req -newkey rsa:2048 -sha256 -nodes \
        -keyout "${node}.key" -out "${node}.csr" \
        -subj "/CN=${node}/O=vault-reference-platform" \
        2>/dev/null || die "Failed to generate a key for ${node}"

    # extendedKeyUsage=serverAuth,clientAuth: Vault nodes are both. Raft
    # peers authenticate to each other, so a server-only certificate
    # leaves the cluster unable to form.
    cat > "${node}.ext" <<EOF
basicConstraints=CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth,clientAuth
subjectAltName=DNS:${node},DNS:localhost,IP:127.0.0.1
EOF

    openssl x509 -req -in "${node}.csr" -CA ca.crt -CAkey ca.key \
        -CAcreateserial -out "${node}.crt" -days "$DAYS_LEAF" -sha256 \
        -extfile "${node}.ext" \
        2>/dev/null || die "Failed to sign the certificate for ${node}"

    rm -f "${node}.csr" "${node}.ext"

    # Vault runs as the unprivileged vault user (uid 100 in the image),
    # and the key is mounted read-only, so it only has to be readable.
    chmod 644 "${node}.crt"
    chmod 644 "${node}.key"
done

rm -f ca.srl

log ""
log "Wrote $(( ${#NODES[@]} * 2 + 2 )) files to docker/dev/tls/"
log "The CA is at docker/dev/tls/ca.crt — clients need it to verify the nodes:"
log "  export VAULT_CACERT=\$(pwd)/docker/dev/tls/ca.crt"
log ""
log "These are development certificates. The directory is gitignored."

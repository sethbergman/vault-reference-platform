#!/usr/bin/env bash
#
# make-fixtures.sh — Generate the certificates the PKI tests need
#
# Called by run-tests.sh into a temp directory. Generated rather than
# committed: a committed private key is a committed private key, even a
# throwaway one, and these have to carry specific expiry dates anyway.

set -euo pipefail
OUT="${1:?usage: make-fixtures.sh <output-dir>}"
mkdir -p "$OUT"

# Git Bash rewrites /CN=... into a Windows path without this. The same
# setting stops it rewriting Unix file paths too, which native Windows
# openssl cannot then open — so everything below runs from inside the
# output directory using bare filenames. Same approach as
# scripts/generate-dev-certs.sh, for the same reason.
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL="*"

cd "$OUT"

CN="vault-0.vault.internal"

openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 3650 \
    -keyout "ca.key" -out "ca.crt" \
    -subj "/CN=test CA" 2>/dev/null

# leaf <name> <cn> <days>
leaf() {
    local name="$1" cn="$2" days="$3"
    openssl req -newkey rsa:2048 -sha256 -nodes \
        -keyout "${name}.key" -out "${name}.csr" \
        -subj "/CN=${cn}" 2>/dev/null
    printf 'subjectAltName=DNS:%s,DNS:localhost,IP:127.0.0.1\n' "$cn" > "${name}.ext"
    openssl x509 -req -in "${name}.csr" -CA "ca.crt" -CAkey "ca.key" \
        -CAcreateserial -out "${name}.crt" -days "$days" -sha256 \
        -extfile "${name}.ext" 2>/dev/null
    rm -f "${name}.csr" "${name}.ext"
}

# The certificate Vault "issues" in the happy path.
leaf good "$CN" 30

# A different key, for the mismatched-pair case.
openssl genrsa -out "other.key" 2048 2>/dev/null

# A certificate for a different host entirely.
leaf wronghost "someone-else.vault.internal" 30

# Already installed on the node: far from expiry, so a renewal run should
# decide there is nothing to do.
leaf fresh "$CN" 30

# Already installed and nearly expired, so a renewal run must act.
leaf expiring "$CN" 1

rm -f "ca.srl"

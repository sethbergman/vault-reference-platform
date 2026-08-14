#!/bin/sh
#
# The base image is Alpine and has no bash — POSIX sh only.
#
# NODE_ID is baked into /vault/config/vault.hcl at build time (see
# Dockerfile), but the Transit auto-unseal token is only minted at runtime
# by the bootstrap script, after vault-unseal is initialized — so it's
# substituted here, once, before Vault ever reads the file.
set -eu

: "${VAULT_TRANSIT_TOKEN:?VAULT_TRANSIT_TOKEN must be set}"

sed -i "s#{{TRANSIT_TOKEN}}#${VAULT_TRANSIT_TOKEN}#" /vault/config/vault.hcl

exec vault server -config=/vault/config/vault.hcl

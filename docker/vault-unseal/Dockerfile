FROM hashicorp/vault:1.17.2

# This is the auto-unseal backend for the main dev cluster (docker/vault) —
# a standalone Vault instance whose Transit secrets engine wraps/unwraps the
# main cluster's storage encryption key. It unseals itself the normal
# (manual, Shamir) way; the main cluster nodes then auto-unseal against it.
# This mirrors how a real deployment would point at AWS KMS or Azure Key
# Vault instead — same seal-stanza shape, different backend.

COPY config/vault.hcl /vault/config/vault.hcl

RUN mkdir -p /vault/data && chown -R vault:vault /vault/data

EXPOSE 8200 8201

# Same reasoning as docker/vault: replacing the base image's entrypoint
# skips the su-exec that would otherwise drop privileges, so this was
# running Vault as root.
USER vault

ENTRYPOINT ["vault", "server", "-config=/vault/config/vault.hcl"]

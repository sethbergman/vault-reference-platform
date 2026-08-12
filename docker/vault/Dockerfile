FROM hashicorp/vault:1.17.2

COPY config/vault.hcl /vault/config/vault.hcl

# Raft storage needs its data dir to exist and be writable before Vault can
# create node-id in it. The base image's own entrypoint script normally
# creates this, but we replace the entrypoint below, so create it ourselves.
RUN mkdir -p /vault/data && chown -R vault:vault /vault/data

EXPOSE 8200 8201

ENTRYPOINT ["vault", "server", "-config=/vault/config/vault.hcl"]

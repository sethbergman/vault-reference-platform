FROM hashicorp/vault:1.17.2

# Which of the 3 dev-cluster nodes this image is for (vault-0/vault-1/vault-2).
# Baked in at build time so each service in docker-compose gets its own
# node_id/api_addr/cluster_addr from one shared template.
ARG VAULT_NODE_ID=vault-0

COPY config/vault.hcl.tpl /tmp/vault.hcl.tpl
RUN sed "s/{{NODE_ID}}/${VAULT_NODE_ID}/g" /tmp/vault.hcl.tpl > /vault/config/vault.hcl \
    && rm /tmp/vault.hcl.tpl

# Raft storage needs its data dir to exist and be writable before Vault can
# create node-id in it. The base image's own entrypoint script normally
# creates this, but we replace the entrypoint below, so create it ourselves.
RUN mkdir -p /vault/data && chown -R vault:vault /vault/data

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

# The entrypoint rewrites this file in place to inject the Transit token,
# so it has to be writable by the user Vault runs as.
RUN chown vault:vault /vault/config/vault.hcl

EXPOSE 8200 8201

# The base image's own entrypoint drops privileges with su-exec before
# starting Vault. Replacing that entrypoint silently undid it — these
# containers were running Vault as root. Dropping here restores it.
# 8200/8201 are above 1024, so no privileged bind is needed.
USER vault

ENTRYPOINT ["docker-entrypoint.sh"]

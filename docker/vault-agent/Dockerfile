FROM hashicorp/vault:1.17.2

# Agent needs three writable directories, and none exist in the base
# image:
#
#   /vault/agent/creds  role_id and secret_id. Agent DELETES the
#                       secret_id after reading it, so this has to be
#                       writable by the user Agent runs as — a read-only
#                       mount or a root-owned bind mount silently defeats
#                       remove_secret_id_file_after_reading.
#   /vault/agent/run    the token sink. Agent writes a temp file
#                       alongside its destination, so the directory
#                       matters and not just the file.
#   /rendered           where templates land.
RUN mkdir -p /vault/agent/creds /vault/agent/run /rendered \
    && chown -R vault:vault /vault/agent /rendered \
    && chmod 0700 /vault/agent/creds /vault/agent/run /rendered

# The base image's entrypoint expects to start as root: it adjusts
# capabilities (for mlock) and then drops privileges itself. Running it
# as vault makes it fail with
#
#   unable to set CAP_SETFCAP effective capability: Operation not permitted
#
# and the container never reaches Agent at all.
#
# Agent does not need mlock — it holds a token and renders files, it does
# not hold the unseal key — so the whole capability dance is skipped by
# invoking the binary directly. Same approach as docker/vault, for the
# same reason: replace the entrypoint rather than fight it.
ENTRYPOINT ["vault"]

USER vault

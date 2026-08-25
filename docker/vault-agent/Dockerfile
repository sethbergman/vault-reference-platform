FROM hashicorp/vault:1.17.2

# Agent needs three writable directories, and none of them exist in the
# base image:
#
#   /vault/agent/creds  role_id and secret_id. Agent DELETES the
#                       secret_id after reading it, so this has to be
#                       writable by the user Agent runs as — a read-only
#                       mount or a root-owned bind mount silently defeats
#                       remove_secret_id_file_after_reading.
#   /vault/agent/run    the token sink. Agent writes a temp file
#                       alongside it, so the directory matters, not just
#                       the file.
#   /rendered           where templates land.
#
# Created here and owned by vault for the same reason /vault/data is in
# docker/vault/Dockerfile: the base image's entrypoint would normally do
# this, and it is replaced.
RUN mkdir -p /vault/agent/creds /vault/agent/run /rendered \
    && chown -R vault:vault /vault/agent /rendered \
    && chmod 0700 /vault/agent/creds /vault/agent/run /rendered

USER vault

FROM hashicorp/vault:1.17.2

COPY config/vault.hcl /vault/config/vault.hcl

EXPOSE 8200 8201

ENTRYPOINT ["vault", "server", "-config=/vault/config/vault.hcl"]

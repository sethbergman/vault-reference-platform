storage "raft" {
  path    = "/vault/data"
  node_id = "vault-unseal"
}

listener "tcp" {
  address = "0.0.0.0:8200"

  # This node holds the Transit key that unseals the whole cluster, so it
  # has the least business speaking plaintext of anything here.
  tls_cert_file = "/vault/tls/vault-unseal.crt"
  tls_key_file  = "/vault/tls/vault-unseal.key"

  tls_min_version = "tls12"
}

# Same reasoning as docker/vault: no IPC_LOCK in the container.
disable_mlock = true

api_addr     = "https://vault-unseal:8200"
cluster_addr = "https://vault-unseal:8201"
ui           = true

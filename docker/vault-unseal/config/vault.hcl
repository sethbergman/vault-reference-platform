storage "raft" {
  path    = "/vault/data"
  node_id = "vault-unseal"
}

listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = "true"   # local/dev only — TLS is required in every other profile
}

# Same reasoning as docker/vault: no IPC_LOCK in the container.
disable_mlock = true

api_addr     = "http://vault-unseal:8200"
cluster_addr = "http://vault-unseal:8201"
ui           = true

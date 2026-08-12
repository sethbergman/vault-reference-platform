storage "raft" {
  path = "/vault/data"
}

listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = "true"   # local/dev only — TLS is required in every other profile
}

# The container doesn't run with IPC_LOCK, so Vault can't mlock its memory
# pages. Disabling it is standard practice for containerized Vault and is
# safe here — this config is local/dev only.
disable_mlock = true

api_addr     = "http://127.0.0.1:8200"
cluster_addr = "http://127.0.0.1:8201"
ui           = true

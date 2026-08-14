storage "raft" {
  path    = "/vault/data"
  node_id = "{{NODE_ID}}"

  # Every node in the local dev cluster lists every other node (including
  # itself — Vault just ignores a self-join) so the same template produces a
  # working config for any node once NODE_ID is substituted at build time.
  retry_join {
    leader_api_addr = "http://vault-0:8200"
  }
  retry_join {
    leader_api_addr = "http://vault-1:8200"
  }
  retry_join {
    leader_api_addr = "http://vault-2:8200"
  }
}

listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = "true"   # local/dev only — TLS is required in every other profile
}

# The container doesn't run with IPC_LOCK, so Vault can't mlock its memory
# pages. Disabling it is standard practice for containerized Vault and is
# safe here — this config is local/dev only.
disable_mlock = true

# Must be the node's own address, reachable from the other nodes on the
# compose network — not 127.0.0.1 — or raft peers can't reach each other
# for join/replication traffic.
api_addr     = "http://{{NODE_ID}}:8200"
cluster_addr = "http://{{NODE_ID}}:8201"
ui           = true

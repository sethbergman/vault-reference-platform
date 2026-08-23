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

  telemetry {
    # sys/metrics normally requires a token. Opening it up lets Prometheus
    # scrape without credentials, which is fine here because the listener
    # is already plaintext and confined to the compose network — but in a
    # real deployment, leave this off and give the scraper a token with a
    # policy granting read on sys/metrics.
    unauthenticated_metrics_access = true
  }
}

telemetry {
  # Vault keeps in-memory metrics for this long; Prometheus scrapes well
  # inside that window (see docker/monitoring/prometheus.yml).
  prometheus_retention_time = "24h"

  # Without this, every metric is prefixed with the node's hostname, which
  # in a container is a random ID — that would make each restart look like
  # a brand-new time series.
  disable_hostname = true
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

# Auto-unseal via the vault-unseal service's Transit engine (see
# docker/vault-unseal). Same seal-stanza shape a production profile would
# use for "awskms"/"azurekeyvault" — only the backend differs. The token is
# only known at container start (it's minted by the bootstrap script after
# vault-unseal is up), so it's injected by docker-entrypoint.sh, not baked
# in at build time like NODE_ID.
seal "transit" {
  address         = "http://vault-unseal:8200"
  token           = "{{TRANSIT_TOKEN}}"
  key_name        = "autounseal"
  mount_path      = "transit/"
  disable_renewal = "false"
}

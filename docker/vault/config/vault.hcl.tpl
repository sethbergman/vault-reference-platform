storage "raft" {
  path    = "/vault/data"
  node_id = "{{NODE_ID}}"

  # Every node in the local dev cluster lists every other node (including
  # itself — Vault just ignores a self-join) so the same template produces a
  # working config for any node once NODE_ID is substituted at build time.
  # leader_ca_cert_file is what makes the join verify the peer rather
  # than trust whatever answers on that name. Without it a node would
  # happily join anything presenting a certificate.
  retry_join {
    leader_api_addr     = "https://vault-0:8200"
    leader_ca_cert_file = "/vault/tls/ca.crt"
  }
  retry_join {
    leader_api_addr     = "https://vault-1:8200"
    leader_ca_cert_file = "/vault/tls/ca.crt"
  }
  retry_join {
    leader_api_addr     = "https://vault-2:8200"
    leader_ca_cert_file = "/vault/tls/ca.crt"
  }
}

listener "tcp" {
  address = "0.0.0.0:8200"

  # Certificates are issued by scripts/generate-dev-certs.sh and mounted
  # in read-only. Each node gets its own, with SANs for its container
  # name plus localhost, because peers dial it by name while the host
  # reaches it through a published port.
  tls_cert_file = "/vault/tls/{{NODE_ID}}.crt"
  tls_key_file  = "/vault/tls/{{NODE_ID}}.key"

  # Peers must present a certificate from the same CA — this is what
  # stops anything that can reach the network from joining the cluster.
  tls_client_ca_file = "/vault/tls/ca.crt"

  tls_min_version = "tls12"

  telemetry {
    # sys/metrics normally requires a token. Opening it up lets Prometheus
    # scrape without credentials. The listener is TLS now, so this is
    # narrower than it was — but in a real deployment leave it off and
    # give the scraper a token with a policy granting read on
    # sys/metrics.
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
api_addr     = "https://{{NODE_ID}}:8200"
cluster_addr = "https://{{NODE_ID}}:8201"
ui           = true

# Auto-unseal via the vault-unseal service's Transit engine (see
# docker/vault-unseal). Same seal-stanza shape a production profile would
# use for "awskms"/"azurekeyvault" — only the backend differs. The token is
# only known at container start (it's minted by the bootstrap script after
# vault-unseal is up), so it's injected by docker-entrypoint.sh, not baked
# in at build time like NODE_ID.
seal "transit" {
  address         = "https://vault-unseal:8200"
  token           = "{{TRANSIT_TOKEN}}"
  key_name        = "autounseal"
  mount_path      = "transit/"
  disable_renewal = "false"
}

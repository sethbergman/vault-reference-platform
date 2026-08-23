# Policy for humans in the "vault-operators" IdP group.
#
# Operators run the cluster: health, raft membership, snapshots, audit
# devices. Note what is deliberately absent — this policy grants no read
# access to secret/data/*. Running Vault does not require reading the
# secrets inside it, and keeping those separate means an operator account
# is not a path to every application credential.

# Cluster health and status.
path "sys/health" {
  capabilities = ["read", "sudo"]
}

path "sys/leader" {
  capabilities = ["read"]
}

path "sys/seal-status" {
  capabilities = ["read"]
}

# Raft membership and snapshots (see docs/disaster-recovery.md).
path "sys/storage/raft/configuration" {
  capabilities = ["read"]
}

path "sys/storage/raft/snapshot" {
  capabilities = ["read", "create", "update"]
}

# Mount and auth introspection — what exists, not what is in it.
path "sys/mounts" {
  capabilities = ["read", "list"]
}

path "sys/auth" {
  capabilities = ["read", "list"]
}

path "sys/policies/acl" {
  capabilities = ["read", "list"]
}

# Audit device configuration.
path "sys/audit" {
  capabilities = ["read", "list", "sudo"]
}

# Metrics, for the Prometheus/Grafana stack (see docs/monitoring notes).
path "sys/metrics" {
  capabilities = ["read", "list"]
}

path "auth/token/lookup-self" {
  capabilities = ["read"]
}

path "auth/token/renew-self" {
  capabilities = ["update"]
}

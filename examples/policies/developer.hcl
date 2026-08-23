# Policy for humans in the "vault-developers" IdP group.
#
# Developers work with application secrets but have no business touching
# cluster operations — no seal/unseal, no raft membership, no auth method
# configuration. That separation is the point of mapping groups to
# policies rather than handing everyone the same token.

# Full access to application secrets (KV v2 splits data and metadata).
path "secret/data/app/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "secret/metadata/app/*" {
  capabilities = ["read", "list", "delete"]
}

# Read-only on CI secrets — useful for debugging a pipeline without being
# able to change what it consumes.
path "secret/data/ci/*" {
  capabilities = ["read", "list"]
}

path "secret/metadata/ci/*" {
  capabilities = ["read", "list"]
}

# Let people see what paths exist so the UI and `vault kv list` work.
path "secret/metadata" {
  capabilities = ["list"]
}

# Everyone should be able to inspect and renew their own token.
path "auth/token/lookup-self" {
  capabilities = ["read"]
}

path "auth/token/renew-self" {
  capabilities = ["update"]
}

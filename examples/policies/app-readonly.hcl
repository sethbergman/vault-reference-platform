# Example least-privilege policy: read-only access to a single app's
# secrets path. Copy and adapt per application/environment.
path "secret/data/app/*" {
  capabilities = ["read", "list"]
}

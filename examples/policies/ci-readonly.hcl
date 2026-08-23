# Example least-privilege policy for a CI pipeline authenticating via
# GitHub Actions OIDC (see scripts/bootstrap-jwt-github.sh).
#
# Read-only on purpose: a CI job that only needs to *consume* secrets to
# build or deploy should not be able to overwrite them. If a pipeline does
# need to write (e.g. publishing a generated credential), give it a
# separate role and policy scoped to just that path rather than widening
# this one.
path "secret/data/ci/*" {
  capabilities = ["read", "list"]
}

# KV v2 keeps metadata on a parallel path; listing without this returns
# permission denied even when the read above succeeds.
path "secret/metadata/ci/*" {
  capabilities = ["read", "list"]
}

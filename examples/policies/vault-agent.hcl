# Policy for Vault Agent running alongside an application.
#
# Read on one dynamic-credential path, and nothing else. Agent's whole
# value is that the application holds no token; that is undone if the
# token Agent holds can read everything.
#
# Note what is absent: no access to database/config/* (which holds the
# credential Vault itself connects with), no other role's credentials,
# and no secret/* at all.
path "database/creds/appdata-readonly" {
  capabilities = ["read"]
}

# Agent renews its own token rather than re-authenticating, so the
# secret_id is read once and the credential on disk stays short-lived.
path "auth/token/renew-self" {
  capabilities = ["update"]
}

path "auth/token/lookup-self" {
  capabilities = ["read"]
}

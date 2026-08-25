# Vault Agent — how an application gets a secret without holding a token.
#
# The application in this arrangement never authenticates to Vault, never
# holds a token, and never makes a Vault API call. It reads a file. Agent
# keeps that file current, and if Vault becomes unreachable the file is
# still there — so a Vault outage does not immediately become an outage
# of everything that depends on it.
#
# What Agent does NOT solve is secret zero. Something still has to place
# a role_id and secret_id on this host, and whatever does that is trusted.
# Agent narrows the problem — the credential on disk is short-lived and
# single-purpose rather than a long-lived token with broad policy — but it
# does not remove it. See docs/vault-agent.md.

pid_file = "/vault/agent/run/pidfile"

vault {
  address = "https://vault-0:8200"
  # The nodes serve TLS from the dev CA. Verifying it is the point; a
  # tls_skip_verify here would make the connection work and check nothing.
  ca_cert = "/vault/tls/ca.crt"
}

auto_auth {
  method "approle" {
    mount_path = "auth/approle"

    config = {
      role_id_file_path   = "/vault/agent/creds/role_id"
      secret_id_file_path = "/vault/agent/creds/secret_id"

      # This is the default. It is written out because it surprises
      # people: Agent deletes the secret_id file once it has read it, so
      # the credential does not sit on disk after use — and a restart
      # needs a freshly provisioned secret_id rather than reusing the old
      # file. That is the correct trade, and it is better to meet it here
      # than during an incident.
      remove_secret_id_file_after_reading = true
    }
  }

  sink "file" {
    config = {
      path = "/vault/agent/run/token"
      # The token sink is a credential. 0640 rather than the permissive
      # default so it is not readable by every account on the host.
      mode = 0640
    }
  }
}

template {
  # A dynamic Postgres credential, rendered as an env file. Agent renews
  # the lease and re-renders when the credential changes, so the file is
  # always current without the application knowing Vault exists.
  destination = "/rendered/db.env"

  # NOT the default. Agent's default is 0644 — world-readable — which for
  # a file containing a live database password means every account on the
  # host can read it.
  perms = "0600"

  # NOT the default either. Left false, a template referencing a field
  # that does not exist renders an empty string: the application starts
  # with a blank password and fails somewhere far from the cause. True
  # makes the mistake loud, at render time.
  error_on_missing_key = true

  contents = <<-EOT
  {{- with secret "database/creds/appdata-readonly" -}}
  DB_USERNAME={{ .Data.username }}
  DB_PASSWORD={{ .Data.password }}
  {{- end }}
  EOT
}

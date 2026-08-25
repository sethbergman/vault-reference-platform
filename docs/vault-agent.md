# Vault Agent

Everything else in this repository configures Vault. This is the part
that shows something *consuming* it — and the interesting property is
negative.

The application does not authenticate to Vault. It holds no token. It
makes no Vault API call. It reads a file.

```bash
./scripts/bootstrap-dev-cluster.sh --with-database --with-agent
./scripts/bootstrap-database-secrets.sh --password bootstrap-only-rotated-immediately
./scripts/bootstrap-agent.sh
docker compose -f docker/dev/docker-compose.yml up -d vault-agent

docker compose -f docker/dev/docker-compose.yml exec vault-agent cat /rendered/db.env
```

```text
DB_USERNAME=v-approle-appdata--Xf3kP2...
DB_PASSWORD=A1a-...
```

That account did not exist before Agent asked for it, and Agent will
replace the file when the lease renews.

## Why this is worth the moving part

**A Vault outage stops being an immediate outage of everything
downstream.** The secret is already on disk. Losing Vault means no *new*
credentials are issued; it does not mean the application stops working.

The integration suite demonstrates exactly that: it stops the Vault node
Agent talks to, then checks the rendered file is still there and the
application can still reach its database.

**The blast radius of a compromised application shrinks.** An application
holding a Vault token holds whatever that token can do. An application
reading a file holds one database credential, which is short-lived and
scoped to one role.

## What Agent does not solve

**Secret zero.** Something has to place a `role_id` and a `secret_id` on
the host, and whatever does that is trusted. Agent changes the *size* of
the problem, not its existence:

| Without Agent | With Agent |
|---|---|
| Long-lived token, broad policy | Short-lived `secret_id`, one policy |
| Lives in an env var for the process lifetime | Deleted from disk once read |
| Rotating it means redeploying | Rotating it is a script on a timer |

`bootstrap-agent.sh --wrap-ttl 5m` is the honest mechanism: it writes a
single-use *response-wrapped* token instead of the `secret_id` itself.
Only the intended consumer can unwrap it, and a second reader gets
nothing — so an unwrap failure is itself a tamper signal. Use it for
anything that is not a local demonstration.

## Two Agent defaults this config deliberately overrides

Both are in `docker/vault-agent/agent.hcl`, and both are the kind of
default that is fine in general and wrong for a file holding a password.

### `perms` defaults to `0644`

Agent renders templates world-readable unless told otherwise. For a file
containing a live database password, that means every account on the host
can read it.

```hcl
perms = "0600"
```

### `error_on_missing_key` defaults to `false`

A template referencing a field that does not exist renders an **empty
string**. The application starts with a blank password and fails
somewhere far from the cause.

```hcl
error_on_missing_key = true
```

HashiCorp's own documentation recommends setting it. It is off by default
for backwards compatibility, which is exactly the sort of default worth
reading the docs for rather than inheriting.

## `remove_secret_id_file_after_reading` is on by default

Agent deletes the `secret_id` file once it has read it. That is the right
behaviour — the credential does not linger — and it surprises people:

> **Restarting Agent needs a freshly provisioned `secret_id`.**

It cannot reuse the file, because the file is gone. Re-run
`bootstrap-agent.sh`, or have whatever manages the host do it. The config
states the setting explicitly rather than relying on the default, so the
behaviour is visible where it matters.

## What is tested

`tests/agent/run-tests.sh` covers the credential handling against shims:
that `role_id` and `secret_id` get different permissions because they are
different kinds of thing, that `--wrap-ttl` changes what lands on disk
rather than only what is logged, and that the config corrects both
defaults above.

`tests/integration/run-tests.sh` runs it against a real cluster:

- Agent authenticates and renders a credential
- **the rendered credential actually connects to Postgres**
- the agent container holds no `VAULT_TOKEN`
- the `secret_id` file is gone after Agent read it
- the rendered file is `0600`, not the `0644` default
- stopping Vault leaves the file in place and the database reachable

The third and last of those are the ones worth having. Without them this
is a config file that looks plausible.

## What this does not cover

**Caching and proxying.** Agent can also act as a caching proxy for
applications that do speak the Vault API. Nothing here uses that, because
the file-rendering pattern is the one that removes the token entirely.

**Application reload.** Agent's `exec` option can restart or signal a
process when a template changes. Whether your application re-reads its
config, and how, is application-specific — so the template renders and
stops there.

**Kubernetes.** The Agent Injector is a different deployment model with
its own failure modes. This is the sidecar-on-a-VM shape, which is what
the rest of this repository targets.

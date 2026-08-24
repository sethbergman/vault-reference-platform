# Dynamic Secrets

Every other secret in this repository is one somebody created and Vault
stored. A dynamic secret is different: it does not exist until it is asked
for, belongs to exactly one consumer, and expires on its own.

There is no shared database password to leak, rotate on a schedule, or
find in a CI log two years later — because there is no shared password.

## Try it

```bash
./scripts/bootstrap-dev-cluster.sh --with-database
export VAULT_ADDR=https://127.0.0.1:8200
export VAULT_CACERT=$PWD/docker/dev/tls/ca.crt
export VAULT_TOKEN=<root token printed above>

./scripts/bootstrap-database-secrets.sh --password bootstrap-only-rotated-immediately
vault read database/creds/appdata-readonly
```

Each read returns a different user:

```text
Key                Value
---                -----
lease_id           database/creds/appdata-readonly/8kQ...
lease_duration     1h
username           v-token-appdata-r-Xf3kP2...
password           A1a-...
```

That account exists in Postgres now, did not a moment ago, and will be
dropped when the lease ends.

## What the bootstrap script sets up

| Thing | Why |
|---|---|
| A connection to Postgres | With `allowed_roles` naming exactly two roles |
| `appdata-readonly` | `SELECT` only |
| `appdata-readwrite` | `SELECT`, `INSERT`, `UPDATE`, `DELETE` |
| A policy per role | Read on that role's creds path and nothing else |
| Root rotation | See below |

Credentials default to a 1-hour TTL and a 24-hour maximum.

## Three details that matter more than they look

### `VALID UNTIL '{{expiration}}'`

The creation statement sets an expiry on the database role itself, not
only in Vault's lease.

Without it, a credential outlives its lease whenever Vault is unreachable
at the moment revocation was due — which is precisely when you would
rather it did not. With it, the database enforces the deadline even if
Vault never gets to run the revocation statement.

### `REASSIGN OWNED` before `DROP ROLE`

Postgres refuses to drop a role that owns objects. A revocation that
tries to `DROP ROLE` directly fails, Vault gives up on the lease, and the
account stays alive in the database with nothing tracking it — which is
worse than never having managed it, because it now looks managed.

### `allowed_roles` is deny-by-default

Omit it and no role can use the connection. Set it to `*` and every role
added later can, including ones added by someone who never looked at this
connection. It names the two roles explicitly.

## Root rotation

The last step of the bootstrap rotates the password of the account Vault
itself connects with, and **Vault does not report the new value**.

After it runs, nobody knows the credential to that database — not the
operator who ran the script, not anything in version control. Only Vault
does. That is the intended end state, and it is what makes the difference
between "we use Vault" and "we have a password in Vault".

It has a real consequence. If Vault's storage is lost and cannot be
restored, that account has to be reset out-of-band by a database
superuser. That is an argument for taking
[disaster recovery](disaster-recovery.md) seriously, not for skipping the
rotation — but `--no-rotate-root` exists, and the script says plainly
what you are left with if you use it: a shared database password, which
is the thing this engine exists to remove.

## TLS to the database

`sslmode` defaults to `disable`. That is correct for the local Docker
profile, where Vault and Postgres share a container network and no
certificate authority exists, and **wrong everywhere else**.

A real deployment should pass `--sslmode verify-full`, which is why the
value appears in the connection string rather than being implied. This
default is a convenience for the dev profile, not a recommendation.

## What is tested

`tests/database/run-tests.sh` covers the configuration against a shim —
that the connection is scoped, the two roles grant genuinely different
things, the policies do not hand a consumer more than it needs, and
rotation happens last.

`tests/integration/run-tests.sh` covers whether any of it works, against
a real Postgres and a real Vault:

- two reads return different users
- the credential connects and queries
- the readonly credential **cannot** write
- revoking the lease stops the credential working
- the role is gone from `pg_roles` afterwards, not merely locked out
- after rotation the bootstrap password no longer authenticates, while
  Vault can still issue

The last one is the whole argument in a single assertion, and it is only
demonstrable against a real database.

## What this does not cover

Only PostgreSQL. Vault's database engine supports MySQL, MSSQL, MongoDB
and others through the same interface, and the shape here would carry
over, but nothing else has been exercised.

The cloud profiles do not provision a database. `terraform/aws` and
`terraform/azure` build a Vault cluster, not an application estate —
pointing the engine at an RDS or Azure Database instance is left to the
reader, and the `--host`, `--sslmode` and `--username` flags exist for
exactly that.

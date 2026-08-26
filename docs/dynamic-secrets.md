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

### `VALID UNTIL '{{expiration}}'` (Postgres only)

The creation statement sets an expiry on the database role itself, not
only in Vault's lease.

Without it, a credential outlives its lease whenever Vault is unreachable
at the moment revocation was due — which is precisely when you would
rather it did not. With it, the database enforces the deadline even if
Vault never gets to run the revocation statement.

**MySQL cannot do this**, and it is the one place where the two engines
are not equivalent. See [Choosing an engine](#choosing-an-engine).

### `REASSIGN OWNED` before `DROP ROLE`

Postgres refuses to drop a role that owns objects. A revocation that
tries to `DROP ROLE` directly fails, Vault gives up on the lease, and the
account stays alive in the database with nothing tracking it — which is
worse than never having managed it, because it now looks managed.

### `allowed_roles` is deny-by-default

Omit it and no role can use the connection. Set it to `*` and every role
added later can, including ones added by someone who never looked at this
connection. It names the two roles explicitly.

## Choosing an engine

```bash
./scripts/bootstrap-database-secrets.sh --engine mysql
```

Two engines, one interface. The mount, the roles, the policies and the
root rotation are identical; the plugin, the connection string and the
SQL are all that change.

The point of having a second one is not MySQL specifically. It is that
"Vault's database engine supports X" is easy to say and hides real
differences, and this is the one that matters:

| | Postgres | MySQL |
|---|---|---|
| Credential expires because | the database enforces it, **and** Vault revokes it | Vault revokes it |
| Vault down at lease expiry | credential still dies on schedule | **credential stays live** |
| Username limit | 63 bytes | 32 characters (16 before 5.7) |
| Transport setting | `sslmode=` | `tls=` |
| `readwrite` can create tables | yes | **no** — see below |

**MySQL has no `VALID UNTIL`.** `CREATE USER` takes no deadline, and
MySQL's `PASSWORD EXPIRE` is password ageing rather than an account
expiry — it cannot express "this login is dead at 14:05". So on the
MySQL path, revocation by Vault is the *only* thing that ends a
credential.

That is a genuine reduction in safety rather than a footnote. The
Postgres path degrades safely when Vault is unavailable; the MySQL path
depends on Vault being there at the right moment. If that matters for
your workload, it is an argument for Postgres, or for a shorter TTL and
monitoring that notices Vault being down — which
[the alerting rules](monitoring.md) already provide.

The tests assert this difference rather than smoothing it over: one
checks the MySQL statements do **not** contain `VALID UNTIL` (pasting it
in is a syntax error there), and its neighbour checks the Postgres ones
still do.

### `readwrite` is narrower on MySQL

The Postgres `readwrite` role grants `USAGE, CREATE ON SCHEMA public`, so
a credential issued from it can create tables — which is what an ORM's
auto-migration or a schema migration step needs. The MySQL role grants
`SELECT, INSERT, UPDATE, DELETE` and no DDL, so the same migration fails
with `CREATE command denied`.

This one is not an oversight and it is not quietly fixable, because the
two databases scope the privilege differently:

- **Postgres** ties DDL to *ownership*. A credential that creates a table
  owns it and can alter or drop it, and it can do nothing to tables it
  did not create.
- **MySQL** grants privileges *per schema*. `GRANT CREATE, ALTER, DROP ON
  appdata.*` applies to every table in the database, including ones the
  credential never touched.

So granting MySQL the same capability would hand every issued readwrite
credential the ability to drop the whole schema. The narrower grant is
the default, and a workload that genuinely needs DDL should get a third
role scoped to that job rather than have `readwrite` widened underneath
every other consumer.

### Other MySQL specifics

- **Vault connects as a dedicated `vaultadmin` account**, created by
  `docker/mysql/init/`. Issuing credentials needs `CREATE USER` and
  `GRANT OPTION`, which an ordinary per-database account lacks — but
  connecting as `root` would be a trap, because the bootstrap rotates the
  password of whatever account it uses and `root`'s password is what the
  container healthcheck needs. That would leave the container
  permanently unhealthy while MySQL itself was fine.
- **Users are created as `'{{name}}'@'%'`**, not `@'localhost'`. Vault
  connects over the container network, and a user scoped to localhost
  cannot log in from where Vault actually is.
- **Grants are scoped to the one database** (`ON appdata.*`). `ON *.*`
  would give every issued credential the run of the server.
- **Usernames are capped at 32 characters.** Vault's default username
  template truncates to fit, so this is handled — but exceeding it fails
  at issuance rather than at configuration, which makes it an unpleasant
  surprise if you write your own template.

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

The same suite runs the MySQL path against a real MySQL server on the
same mount — a second connection, not a second engine — and asserts the
parts that differ: that the generated username fits MySQL's 32-character
limit, that the readonly credential cannot write and cannot read
`mysql.user`, that revoking the lease drops the account, and that
`vaultadmin`'s bootstrap password stops working after rotation.

## What this does not cover

PostgreSQL and MySQL. Vault's database engine also supports MSSQL,
MongoDB and others through the same interface, and the shape here would
carry over, but nothing else has been exercised.

The cloud profiles do not provision a database. `terraform/aws` and
`terraform/azure` build a Vault cluster, not an application estate —
pointing the engine at an RDS or Azure Database instance is left to the
reader, and the `--host`, `--sslmode` and `--username` flags exist for
exactly that.

## Secret rotation

[#secret-rotation](#secret-rotation)

Machine/workload access to Vault uses the AppRole auth method (see
[`docs/security.md`](security.md#authentication--policy)). AppRole roles
are set up once with `scripts/bootstrap-approle.sh`; the `secret_id`
credential issued to workloads is rotated on a recurring basis with
`scripts/rotate-secret-id.sh`.

### Why rotate `secret_id`s

A `secret_id` is a long-lived bearer credential — anything that can present
a valid `role_id` + `secret_id` pair gets a Vault token with that role's
policies. Rotating it regularly, and revoking the previous one at rotation
time, bounds how long a leaked or stale `secret_id` remains usable, without
requiring any changes to the workload's `role_id` or policy.

### One-time setup: `bootstrap-approle.sh`

```bash
export VAULT_ADDR=https://vault.internal:8200
export VAULT_TOKEN=<a token with sys/policies, sys/auth, and approle write access>

./scripts/bootstrap-approle.sh \
  --role app \
  --policy-file examples/policies/app-readonly.hcl \
  --secret-id-ttl 768h \
  --token-ttl 1h \
  --token-max-ttl 4h
```

This writes the policy, enables the AppRole auth method if it isn't
already enabled, and creates the role. It does not issue a credential — run
it once per role (re-running is safe and just updates the role's config).

| Flag | Default | Description |
|---|---|---|
| `--role` | *(required)* | AppRole role name |
| `--policy-file` | *(required)* | Path to the `.hcl` policy the role should carry |
| `--policy-name` | same as `--role` | Name to register the policy under |
| `--secret-id-ttl` | `768h` (32 days) | How long an issued `secret_id` remains valid before it expires on its own |
| `--token-ttl` | `1h` | TTL of tokens obtained via this role |
| `--token-max-ttl` | `4h` | Max TTL of those tokens, including renewals |

### Recurring rotation: `rotate-secret-id.sh`

```bash
./scripts/rotate-secret-id.sh --role app
```

Each run:

1. Issues a new `secret_id` for the role.
2. Revokes the `secret_id` from the *previous* run, identified by its
   accessor recorded under `--state-dir` (default `./.vault-rotation-state`)
   — so at most one `secret_id` per role is ever live, bar a brief overlap
   while a workload picks up the new one.
3. Records the new accessor for next time.
4. Prints the `secret_id` to stdout (all logging goes to stderr, so stdout
   can be piped straight into wherever the credential needs to land).

Run it on whatever cadence matches your `--secret-id-ttl` — e.g. a weekly
CI job or cron entry — well inside the TTL so rotation always beats
natural expiry.

For handoff to a consumer that shouldn't see the raw value in a CI log,
use `--wrap-ttl`:

```bash
./scripts/rotate-secret-id.sh --role app --wrap-ttl 5m
```

This prints a single-use wrapping token instead of the `secret_id` itself.
The consumer unwraps it exactly once (`vault unwrap <token>`) within the
TTL to retrieve `role_id`/`secret_id`; a second unwrap attempt fails, so a
token that leaks in transit but is never used is harmless.

| Flag | Default | Description |
|---|---|---|
| `--role` | *(required)* | AppRole role name (must already exist — see bootstrap) |
| `--state-dir` | `./.vault-rotation-state` | Where the previous run's accessor is recorded |
| `--wrap-ttl` | *(off)* | Response-wrap the new credential for single-use handoff instead of printing it directly |
| `--no-revoke` | off | Skip revoking the previous `secret_id` (e.g. first run against externally-issued state) |

The state file holds only an *accessor* — an identifier used to revoke a
specific `secret_id`, not a credential itself. Losing it isn't a security
event; it just means the next rotation can't clean up the prior
`secret_id` automatically, and that credential is left to expire on its
own per `secret_id_ttl`.

### Prerequisites

- `vault` CLI and `jq` on the machine running the script.
- `VAULT_ADDR` / `VAULT_TOKEN` (or `--vault-addr` / `--vault-token`) with
  a token authorized on the role's `secret-id` and
  `secret-id-accessor/destroy` endpoints.

### Rollback / troubleshooting

- **Revoke failed ("could not revoke previous accessor")**: the script
  logs a warning and continues rather than aborting — the old `secret_id`
  will still expire on schedule via `secret_id_ttl`. Investigate why the
  destroy call failed (already destroyed, insufficient token policy) before
  the next scheduled rotation.
- **Lost the state file**: safe to delete and let it regenerate. The only
  effect is one extra live `secret_id` (the one that would have been
  revoked) until it expires naturally. Run with `--no-revoke` on the next
  invocation if you want to be explicit about that.
- **Workload fails to authenticate after rotation**: confirm it picked up
  the newly issued `secret_id` rather than caching the previous one — the
  script has already revoked the old one by the time it returns.

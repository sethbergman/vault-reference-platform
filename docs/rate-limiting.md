# Rate limiting

Vault's rate limit quotas cap requests per interval and answer **429**
over the cap. They are the control that stops one misbehaving client
taking the cluster down for everyone.

```bash
export VAULT_ADDR=https://127.0.0.1:8200
export VAULT_TOKEN=<root>

./scripts/bootstrap-quotas.sh --show
./scripts/bootstrap-quotas.sh --rate 2000 --interval 1s
./scripts/bootstrap-quotas.sh --rate 50 --interval 1s --path secret/
./scripts/bootstrap-quotas.sh --remove --name global
```

Two `vault write` calls do the same thing. The script exists because both
of them have a way of appearing to work while doing nothing, and because
one of them can lock you out of undoing it.

## The endpoint replaces, it does not merge

Vault ships seven exempt paths, among them `sys/health`,
`sys/seal-status` and `sys/unseal`. Writing a single unrelated field to
`sys/quotas/config` empties that list:

```console
$ vault read -format=json sys/quotas/config | jq '.data.rate_limit_exempt_paths | length'
7
$ vault write sys/quotas/config enable_rate_limit_response_headers=true
$ vault read -format=json sys/quotas/config | jq '.data.rate_limit_exempt_paths | length'
0
```

Nothing warns you. The next global quota then applies to your load
balancer's health checks and to `sys/unseal`, and you find out during the
next restart.

So anything that writes that endpoint has to write the whole thing, every
time, defaults included.

## The list is a list

`rate_limit_exempt_paths` takes an array, and the CLI's `key=value` form
does not produce one:

```console
$ vault write sys/quotas/config rate_limit_exempt_paths="sys/health,sys/seal-status"
$ vault read -format=json sys/quotas/config | jq -c '.data.rate_limit_exempt_paths'
["sys/health,sys/seal-status"]
```

One element, containing a comma, matching no path that exists. The write
succeeds and protects nothing. Repeating the flag works, and so does JSON
on stdin, which is what the script sends:

```bash
printf '%s' '{"rate_limit_exempt_paths":["sys/health","sys/quotas/config"]}' \
    | vault write sys/quotas/config -
```

It then reads the list back and counts it, because the broken form and
the working form differ only in the length of an array nobody looks at.

## A quota rate limits the endpoint that removes it

`sys/quotas/*` is not exempt by default. Set a global quota too low and
the request that would fix it is a request:

```console
$ vault delete sys/quotas/rate-limit/global
Error deleting sys/quotas/rate-limit/global: Code: 429
```

The quota defends itself. Standby nodes do not help — they forward to the
leader, and the leader is where the limiter is.

`bootstrap-quotas.sh` always exempts `sys/quotas/config` and
`sys/quotas/rate-limit`, which turns that outage into an inconvenience:
ordinary requests get 429, and you delete the quota.

### If it is already too late

Send nothing for one full interval, then spend the first request of the
new window on the delete:

```bash
sleep 60          # one interval, sending nothing
vault delete sys/quotas/rate-limit/global
```

It returns 204. Any request before it — including the `vault read` you
would naturally run first to see what is going on — consumes the budget,
and you wait again.

## 429 does not mean what you think

A healthy Vault standby answers **429** on `sys/health`. That is why the
AWS target group in `terraform/aws` matches `200,429`: without it, every
standby would be pulled from the pool.

A tripped quota also answers 429. To the load balancer, and to anything
else reading status codes, those are the same response — so a node
refusing traffic because of a quota stays in the pool, healthy by every
signal the infrastructure collects. This is the same failure as a
quorum-less node answering 200 with `standbyok=true`, arriving from the
other direction.

What separates them is a setting that is off by default:

| | Standby 429 | Quota 429 |
|---|---|---|
| `enable_rate_limit_response_headers` off | no headers | no headers |
| on | no headers | `retry-after`, `x-ratelimit-limit`, `x-ratelimit-remaining`, `x-ratelimit-reset` |

`bootstrap-quotas.sh` turns it on by default. `--no-headers` exists and
says what it costs.

## Choosing a rate

There is no useful default, which is why the script requires `--rate` to
set a quota and configures exemptions without one. A rate is a statement
about your traffic, and the way to find it is to look:

```bash
vault write sys/quotas/config enable_rate_limit_audit_logging=true
```

That logs every rejection to the audit devices, so a quota set
deliberately high tells you what a realistic one would be before it
rejects anything anyone cares about.

Start above observed peak, not at it. A quota that trips during normal
operation is an outage you caused.

## What is tested

`tests/quotas` runs against a real cluster, because every property here
is a status code under load and a shim would return whichever code the
script hoped for. It asserts the script's claims, and four of Vault's own
behaviours the script is built around: that the config endpoint replaces
rather than merges, that a comma-joined list becomes one element, that a
tripped quota refuses its own deletion, and that a standby answers 429 on
`sys/health`. If any of those stops being true, the script is guarding
something that no longer happens.

## What is not

Lease count quotas are Vault Enterprise and nothing here touches them.
Neither are role-scoped or namespace-scoped quotas, for the same reason.

How the limit behaves across three nodes is not established here. Vault
documents rate limits as per-node, which would mean a cluster admits some
multiple of the configured rate — but the one thing measured was that a
standby returns 429 for a request the leader had already exhausted the
budget for, because standbys forward. Whether a request a standby can
serve locally has its own budget was not tested, and the number you
should configure depends on the answer.

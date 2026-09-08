# tests/quotas

API rate limit quotas, and the several ways of setting one that look like
they worked.

```bash
./tests/quotas/run-tests.sh
./tests/quotas/run-tests.sh --keep-running
```

Needs `docker compose`, the `vault` CLI, `jq` and `curl`. Runs against a
real three-node cluster; a few minutes, most of it spent waiting out
quota intervals on purpose.

## Why a real cluster

Every property here is a status code under load. A shim would return
whichever code the script hoped for, and the questions are what Vault
does when a quota trips, what it does to the endpoints you need in order
to undo it, and whether a load balancer can tell the result from a
healthy standby.

## Four assertions are about Vault, not the script

`scripts/bootstrap-quotas.sh` is shaped entirely around these. If any
stops being true the script is guarding something that no longer
happens, and this suite should be what says so.

| | |
|---|---|
| The config is replaced, not merged | Writing one field to `sys/quotas/config` drops the seven exempt paths Vault ships, `sys/health` among them |
| The list is a list | `rate_limit_exempt_paths="a,b"` becomes one element containing a comma, which matches nothing and writes successfully |
| The quota defends itself | With `sys/quotas/*` unexempted, a tripped quota answers 429 to the DELETE that would remove it |
| 429 is ambiguous | A healthy standby answers 429 on `sys/health`, which is why the AWS target group matches `200,429` |

The last one is why `bootstrap-quotas.sh` turns on response headers by
default: with them, a quota's 429 carries `retry-after` and
`x-ratelimit-*` and a standby's does not. Without them the two responses
are identical, and a node refusing traffic stays in the load balancer
pool.

## The lockout, and the way out

The suite deliberately creates the failure the exemption prevents: it
strips `sys/quotas` from the exempt list, sets a quota of one request per
twenty seconds, burns the budget, and requires the DELETE to be refused.

Then it demonstrates the recovery, because "wait and try again" is not
obvious when every diagnostic you would run first consumes the budget
you are waiting for. It sends nothing for a full interval and spends the
first request of the new window on the delete, which returns 204.

## Mutation table

Every row was watched to fail.

| # | Mutation | Caught by |
|---|---|---|
| Q1 | Exempt paths written comma-joined, the way the CLI invites | and the exempt list has nine or more entries; including sys/health (8 in total) |
| Q2 | `sys/quotas` left out of the exempt list | and the quota config is still readable; and the quota can be deleted while it is tripped (5) |
| Q3 | Response headers left off | and response headers are on; a quota's 429 carries x-ratelimit-limit (2) |

Q1 is the one worth reading. The mutation is not a mistake — it is the
form the CLI documentation leads you to, and it writes successfully. What
catches it is counting the array, because the broken result and the
working one differ only in a length nobody looks at.

## What is not covered

Lease count quotas, and role- or namespace-scoped quotas: all Vault
Enterprise.

How the limit behaves across three nodes is not established. What was
measured is that a standby returns 429 for a request whose budget the
leader had already spent, because standbys forward. Whether a request a
standby serves locally has a budget of its own was not tested.

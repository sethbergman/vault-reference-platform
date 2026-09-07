# Autopilot pruning tests

Run with:

```bash
./tests/autopilot-prune/run-tests.sh
./tests/autopilot-prune/run-tests.sh --keep-running
```

About five minutes. Stands up its own three-node cluster and tears it
down. Needs `docker compose`, the `vault` CLI and `jq`.

## The half nothing else could reach

`scripts/configure-autopilot.sh` turns on `cleanup_dead_servers` and sets
a `min_quorum` floor, and the claim in
[`docs/rolling-upgrades.md`](../../docs/rolling-upgrades.md) is that this
makes an ASG instance refresh safe: a departed voter is pruned once a
replacement has joined.

The other two suites each cover part of that and neither covers the end
of it. [`tests/autopilot`](../autopilot/run-tests.sh) shows the script
issues the right command. [`tests/integration`](../integration/run-tests.sh)
shows a live cluster reports the values back, and that the floor
**blocks** pruning while there are only three voters.

None of it showed a dead voter actually disappearing — because at three
voters with a floor of three, it cannot, which is the entire point of the
floor. So the claim that mattered most was the one nothing tested.

## What it does

The shape of an ASG instance refresh, locally:

1. three voters, healthy
2. destroy one — it stays a voter, because pruning it would drop below
   the floor
3. add a node the cluster has never seen, with a `node_id` of its own
4. the dead one is pruned, and the replacement promoted in its place
5. the cluster still accepts writes

Step 4 is not the order this suite first asserted. It expected the voter
count to rise to four and fall back to three — promote, then prune. What
happens is the reverse: the replacement joins as a **non-voter**, that
alone satisfies `min_quorum`, the dead voter is pruned, and only then is
the replacement promoted. The voter count never reaches four.

So `min_quorum` counts servers rather than voters. The property holds
either way — nothing is pruned until a replacement exists, which is what
the 90-second wait in step 2 demonstrates — but the mechanism written
into `docs/rolling-upgrades.md` was wrong, and this suite is what caught
it. The first version failed against a cluster doing exactly the right
thing.

Step 3 is what three fixed nodes cannot model. Destroy `vault-2` and it
comes back as `vault-2`, so the count never rises and nothing is ever
pruned. On AWS a replacement is a new EC2 instance with a new instance
id, and `terraform/aws` sets `node_id` from exactly that — so the spare
`vault-3` in `docker/dev/docker-compose.yml` reproduces the one property
that makes cloud replacement different from a local restart.

`vault-3` sits behind a compose profile, so neither a bare
`docker compose up` nor `bootstrap-dev-cluster.sh` will start it. It is
not part of the cluster; it is the replacement.

## Two floors that are Vault's, not ours

Both were found by trying them:

- `min_quorum` **must be at least 3** when `cleanup_dead_servers` is on.
  Vault rejects 2 outright. `configure-autopilot.sh` refuses first, so
  the message is a sentence rather than a hex-formatted API error.
- `dead_server_last_contact_threshold` **cannot be below `1m`**. That is
  the floor on how fast this suite can run: the wait proving the floor
  holds has to outlast the threshold, so the suite uses 1m and waits 90s.
  Production uses the 5m default for the reasons in the script header.

## What it still does not prove

That an autoscaling group does this. Nothing here is an ASG: the
replacement is started by hand, in the right order, with no instance
warmup and no health check in the way, and no leader is stepped down.

What it establishes is that the autopilot configuration behaves the way
`docs/rolling-upgrades.md` says when a replacement arrives — which was
assumed until this suite existed. The remaining half is a real apply, and
[`docs/cloud-apply.md`](../../docs/cloud-apply.md) carries it as a
checklist item.

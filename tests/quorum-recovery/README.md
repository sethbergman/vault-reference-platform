# Quorum recovery tests

Run with:

```bash
./tests/quorum-recovery/run-tests.sh
./tests/quorum-recovery/run-tests.sh --keep-running
```

A few minutes. Stands up its own three-node cluster and tears it down.
Needs `docker compose`, the `vault` CLI, `jq` and `curl`.

## The failure this is about

Losing quorum is not the same failure as losing data, and this repository
sent both to the same remedy until this suite existed.

If a majority of nodes are gone but one survivor still has its storage,
that survivor holds every write Raft committed — it simply cannot elect a
leader to serve them. Restoring a snapshot into it works, and silently
discards everything written since that snapshot. `peers.json` keeps the
lot.

The loss-of-quorum section in
[`disaster-recovery.md`](../../docs/disaster-recovery.md) draws the line,
and says when to restore instead.

## What it checks

Destroy two of three nodes, confirm the survivor cannot serve, recover it
through `scripts/recover-quorum.sh`, confirm the write made before the
outage reads back, and bring a replacement in.

It also runs the script against a **healthy** cluster and against a shell
with no `VAULT_TOKEN`, because a guard only ever exercised where it
passes is not a guard — and asserts that neither refusal stopped the node
on its way out. A guard that refuses after stopping Vault has not
prevented anything.

## Mutation table

Every row run and watched to fail. Baseline is 14 passed, 0 failed.

| Deliberate break | Caught by | Result |
|---|---|---|
| `peers.json` written 0600, so Vault cannot read it | recover-quorum.sh completed; the survivor is answering; the Raft configuration is now the survivor alone; the pre-outage write survived; and the cluster accepts writes again; Raft consumed peers.json; a replacement node rejoins | 7 / 7 |
| the healthy-cluster guard warns instead of refusing | recover-quorum.sh refuses to run while quorum is intact; the survivor cannot serve reads without a majority | 12 / 2 |
| the recovered peer is written as a non-voter | the same seven as the first row | 7 / 7 |

The second row is the one worth reading twice. Downgrading the guard to a
warning does not merely lose the refusal — it also fails *the survivor
cannot serve reads without a majority*, an assertion that is not about
the guard at all. With the guard warning, the script goes ahead and
reconfigures the healthy cluster to a single node; by the time the suite
destroys the other two, that node has a quorum of one and serves reads
perfectly well. The damage the guard prevents shows up in an assertion
written for something else entirely.

The first and third rows take down seven assertions each, which is the
right shape: they break recovery outright rather than tripping one string
match.

The 0600 row is not hypothetical. This suite failed exactly that way on
its first run — `mktemp` creates 0600, `docker cp` carries the mode
through, Vault runs as the `vault` user, and a `peers.json` it cannot
read is indistinguishable from no `peers.json`: the node comes back still
waiting for peers that are gone, with the file beside it unconsumed.

## What it does not prove

The `--service-name` path — recovery on a real node under systemd — is
covered separately and only by shims, in
[`tests/recover-quorum-systemd`](../recover-quorum-systemd/README.md). No
node running Vault under systemd has been recovered by this script.

And none of this has run on a cloud profile, which has never been
applied.

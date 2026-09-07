# recover-quorum.sh, on a real node

Run with:

```bash
./tests/recover-quorum-systemd/run-tests.sh
```

Seconds. `bash` and `jq`. No cluster, no credentials, nothing stopped.

## What this covers that nothing else did

[`tests/quorum-recovery`](../quorum-recovery/run-tests.sh) runs the
compose path against a real three-node cluster. The `--service-name`
path — the one an operator uses on an actual node, with `systemctl` and a
data directory on disk — had **no test at all**. It was written from
Vault's documented procedure and shipped as "reviewed, not proven", which
is honest and is not the same as covered.

A real node is not available here, so this is the shim tier: it proves
the script issues the commands you expect, in the order you expect, and
nothing more. What it cannot show is that Vault then does the right thing
with `peers.json` — that is the other suite's job, on the other path.

## The order is most of the point

Every refusal has to happen **before** `systemctl stop`. A guard that
refuses after stopping Vault has not prevented anything; it has taken the
node down and then declined to fix it, during an outage.

So each refusal is paired with an assertion that the service was never
touched, and the mutation table below shows those pairs failing together
— which is what makes them worth having.

## Mutation table

Every row run and watched to fail. Baseline is 24 passed, 0 failed.

| Deliberate break | Caught by | Result |
|---|---|---|
| `peers.json` written 0600, so Vault cannot read it | and written 0644, so the vault user can read it | 23 / 1 |
| the raft directory check is dropped | and names the directory it wanted; and the service was never touched | 22 / 2 |
| a standby (429) counts as recovered | a node that comes back a standby is a failure, not a success; and says so rather than reporting a recovery | 22 / 2 |
| only the first survivor reaches `peers.json` | and all three reach peers.json | 23 / 1 |
| the quorum guard warns instead of refusing | a missing VAULT_TOKEN is refused rather than warned about; and the service was never touched | 22 / 2 |
| a failed `systemctl stop` is ignored and the write proceeds | a stop that fails aborts; and peers.json is not written to a node still running | 22 / 2 |

Four of the six take down a second assertion with them, and that is the
useful part: dropping the raft-directory check does not merely lose an
error message, it lets the script stop Vault on the way to failing. The
paired assertion is what says so.

The 0600 row is not hypothetical. Its sibling suite failed exactly that
way on its first run: `mktemp` creates 0600, `docker cp` carries the mode
through, Vault runs as the `vault` user, and a `peers.json` it cannot
read is indistinguishable from no `peers.json` at all — the node comes
back still waiting for peers that are gone, with the file sitting beside
it unconsumed.

## What it does not prove

That `systemctl` and a real Vault behave as the shims do. A shim proves
the script issues a command; it cannot prove the command worked. The
compose path is covered end to end against a real cluster, and this path
is not — no node running Vault under systemd has ever been recovered by
this script.

That gap is the reason the shims model the real tools' behaviour rather
than something convenient: the `vault` shim fails a Raft configuration
query the way a quorum-less cluster does, with the same
`local node not active but active cluster node not found`, because that
distinction is the entire basis of the guard.

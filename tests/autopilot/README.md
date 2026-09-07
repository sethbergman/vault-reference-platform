# Autopilot tests

Run with:

```bash
./tests/autopilot/run-tests.sh
```

Seconds. `bash` and `jq`, no cluster, no credentials.

## What this is about

Vault ships Raft autopilot with `cleanup_dead_servers = false` and
`dead_server_last_contact_threshold = 24h`, so a node that is destroyed
stays in the Raft configuration as a voter. On a fixed set of machines
that is survivable — the node comes back as itself. On the cloud profiles
it is not, because a replacement is a different machine with a different
`node_id`, so every replacement adds a voter and leaves the old one
behind, and a three-node ASG instance refresh loses quorum partway
through the second node.

[`docs/rolling-upgrades.md`](../../docs/rolling-upgrades.md) has the
arithmetic and the decision about which upgrade model is canonical per
profile. This suite covers
[`scripts/configure-autopilot.sh`](../../scripts/configure-autopilot.sh),
which is the fix.

## What it checks

- the defaults it writes: cleanup on, `min_quorum` from the voters it
  counted, and a dead-server threshold short enough to fall inside the
  ASG's `instance_warmup`
- that it **counts** voters rather than assuming three, and that a
  non-voter which has joined but not been promoted does not raise the
  floor
- that it refuses a cluster with fewer than three voters, and says why —
  a two-node "quorum" is not one, and writing `min_quorum = 2` would look
  like a safety property without being one
- that `--no-cleanup` is honoured and announces what it costs
- that a `set-config` which reports success without taking is caught by
  the read-back rather than reported as done
- that it configures and never removes a peer itself

The last one is the failure mode this repository keeps finding in its own
tests, so it is worth being explicit: the shim can make `set-config` exit
0 while `get-config` still returns the old values, which is precisely
what a script that trusted its own exit code would miss.

## What it does not check

Whether Vault behaves the way the configuration says. A shim proves the
script issues the command; it cannot prove the cluster accepted it.

[`tests/integration`](../integration/run-tests.sh) covers that half
against a real three-node cluster on every PR: that Vault still ships
`cleanup_dead_servers = false` — asserted rather than assumed, so an
upstream change breaks a test instead of quietly making the docs wrong —
that the script configures a live cluster, that the values read back, and
that a second run is a no-op which still verifies.

A dead voter being pruned is covered by a third suite,
[`tests/autopilot-prune`](../autopilot-prune/run-tests.sh), which needs a
fourth node to do it: pruning cannot happen at three voters with a floor
of three, so it adds the `vault-3` spare and watches the count go to four
and back to three.

**None of them proves the fix works on a cloud profile.** No ASG instance
refresh has ever run against this configuration, because no cloud profile
has ever been applied. What the local suites establish is that autopilot
behaves as documented when a replacement arrives; whether an autoscaling
group produces that sequence — in that order, with its own warmup and
health checks in the way — is the checklist item in
[`docs/cloud-apply.md`](../../docs/cloud-apply.md).

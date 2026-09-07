# Rolling upgrades

[#rolling-upgrades](#rolling-upgrades)

Vault version upgrades are performed with `scripts/vault-upgrade.sh`, which
upgrades an HA cluster one node at a time with zero downtime.

## What it does

1. Downloads and validates the release archive from a given URL.
2. For each node, in order:
   - If the node is the current active (leader) node, it is stepped down
     first so it becomes a standby before being touched.
   - The Vault service is stopped, the binary is swapped, and the service
     is restarted.
   - The script polls `sys/health` and waits for the node to report healthy
     before moving on to the next node.
3. If any node fails to come back healthy, the script **stops immediately**
   rather than continuing to upgrade the rest of the cluster. Manual
   intervention is required on the failed node before re-running.

## Usage

```bash
./scripts/vault-upgrade.sh <download-url> \
  --nodes vault-node-1,vault-node-2,vault-node-3 \
  --ssh-user deploy
```

| Flag | Default | Description |
|---|---|---|
| `--nodes` | *(required)* | Comma-separated list of node hostnames, upgraded in order |
| `--ssh-user` | current user | SSH user with sudo access to `systemctl` on each node |
| `--ssh-key` | *(uses default SSH agent/key)* | Path to an SSH private key |
| `--binary-path` | `/usr/local/bin/vault` | Path to the Vault binary on each node |
| `--service-name` | `vault` | systemd service name |
| `--vault-addr` | `https://127.0.0.1:8200` | Local Vault address used for health checks |
| `--health-timeout` | `120` | Seconds to wait for a node to report healthy after restart |
| `--skip-tls-verify` | off | Skip TLS verification on health-check requests |

## Prerequisites

- SSH key-based access from the machine running the script to every node
  in `--nodes`.
- The remote user must be able to `sudo systemctl` the Vault service
  without a password prompt.
- `bash`, `curl`, `unzip`, `ssh`, and `jq` on the machine running the script.

## Which model is canonical, per profile

There are two upgrade models in this repository and until now nothing
said which one an operator is supposed to use where. That was the
substance of v1.0 blocker 5, and the answer differs by profile because
the profiles replace nodes differently.

| Profile | Canonical model | Why |
|---|---|---|
| local / bare metal / any fixed set of machines | `scripts/vault-upgrade.sh` | The machines outlive the upgrade. Swapping a binary in place is the whole operation, and the script is leader-aware. |
| AWS | ASG instance refresh — bump `vault_version`, apply | The version is installed from user-data at boot, so there is no binary to swap: the node *is* the version. `vault-upgrade.sh` would swap a binary that the next instance replacement discards. |
| Azure | `scripts/vault-upgrade.sh`, for now | The scale set is `upgrade_mode = "Manual"`, so nothing replaces instances until somebody says so. Until that changes, in-place is the only model that actually runs. |

The AWS answer is the uncomfortable one, because it means the tested
script is not the tool an AWS operator should reach for, and the tool
they should reach for was — until this was written — unsafe. That is the
next section.

## Why an instance refresh was unsafe, and what fixes it

Vault ships Raft autopilot with `cleanup_dead_servers = false` and
`dead_server_last_contact_threshold = 24h`. Verifiably so: destroy a node
on the local cluster and `vault operator raft list-peers` still lists it
a minute later, still as a voter, with autopilot reporting
`FailureTolerance: 0`.

On a fixed set of machines that is survivable, because the node comes
back with the same `node_id` and rejoins. On the cloud profiles it is
not, because a replacement is a *different machine with a different
node_id*: `terraform/aws` sets `node_id` to the EC2 instance id and
`terraform/azure` to the scale set VM name. Every replacement adds a
voter and leaves the old one behind.

Walk a three-node instance refresh through that, one node at a time:

| Step | Voters | Quorum needs | Live | |
|---|---|---|---|---|
| start | A B C | 2 | 3 | ok |
| terminate A | ~~A~~ B C | 2 | 2 | ok, no margin |
| launch A2 | ~~A~~ B C A2 | 3 | 3 | ok, no margin |
| terminate B | ~~A~~ ~~B~~ C A2 | 3 | 2 | **quorum lost** |

It breaks partway through the second node, not the third. And
`min_healthy_percentage = 67` on the refresh cannot prevent it: the ASG
is counting instances it can see, while the problem is the ones Raft
still counts that the ASG cannot. The two are counting different things,
which is exactly why the setting looks sufficient and is not.

The fix is
[`scripts/configure-autopilot.sh`](../scripts/configure-autopilot.sh),
which sets:

- `cleanup_dead_servers = true`, so a departed voter is eventually pruned
- `min_quorum` = the number of voters, so pruning has a floor
- `dead_server_last_contact_threshold = 5m`, well inside the ASG's
  `instance_warmup` of 600s

**`min_quorum` is the safety, not the threshold.** Cleanup on its own
would let autopilot prune a node during a network partition, taking the
cluster further from quorum exactly when it can least afford it. With
three voters and `min_quorum = 3`, nothing can be pruned until a
replacement has joined and made it four. Join, then prune — that ordering
is the whole property, and it is what makes a five-minute threshold safe
when it would otherwise be reckless.

Run it once per cluster, after bootstrap:

```bash
./scripts/configure-autopilot.sh
```

It is idempotent, and re-running verifies rather than assuming.

## What is proven, and what is not

Proven, against a real three-node cluster on every PR
([`tests/integration`](../tests/integration/run-tests.sh)):

- Vault really does ship `cleanup_dead_servers = false` — asserted rather
  than assumed, so an upstream change breaks a test instead of quietly
  making this page wrong
- the script configures a live cluster, and the values read back
- re-running is a no-op that still verifies

Proven against a fake CLI
([`tests/autopilot`](../tests/autopilot/run-tests.sh)): that the script
counts voters rather than assuming three, refuses a
cluster too small for the floor to mean anything, honours `--no-cleanup`
and says what it costs, and catches a `set-config` that reports success
without taking.

Observed by hand, once, on the local cluster: a destroyed node is still a
voter a minute later; and with cleanup on and `min_quorum = 3`, that dead
voter is still *not* pruned well past the five-minute threshold, because
pruning it would drop below the floor. That is the safety property
behaving as designed. Vault also refuses `min_quorum = 2` outright while
cleanup is on, which is the same rule enforced a layer down.

**Not observed: a dead voter actually being pruned.** That needs a fourth
voter — pruning cannot happen at three with a floor of three, which is
the whole point — and a fourth voter needs a node with a *different*
`node_id`, which the local compose profile has no way to produce: its
three nodes are named, fixed, and rejoin as themselves. So the guard is
demonstrated and the cleanup it guards is not. It is Vault's behaviour
rather than this repository's configuration, but the fix rests on it, and
saying so is cheaper than a reader assuming it was checked.

**Not proven: any of this on a cloud profile.** No ASG instance refresh
has ever run against this configuration, because no cloud profile has
ever been applied. What the arithmetic above establishes is that the
refresh was unsafe and why; what it does not establish is that it is now
safe. That needs the apply in [cloud-apply.md](cloud-apply.md), and it
belongs on the verification checklist there: bump `vault_version`, apply,
and watch whether quorum holds and dead voters disappear.

Also not addressed: the refresh terminates the leader without stepping it
down, so an election happens mid-upgrade. Raft recovers in seconds and
quorum is not at risk, but in-flight writes to the old leader fail. A
lifecycle hook that stepped down first would remove that, at the cost of
an agent on each node with a token authorized for `sys/step-down`. It is
not built here, and the cost is the reason.

## Rollback

The script does not automatically roll back a failed node. If a node fails
its post-upgrade health check:

1. Do not proceed to the next node — the script already stops here.
2. SSH into the failed node and check `journalctl -u vault -n 100` for the
   startup error.
3. If needed, manually restore the previous binary (keep a copy of
   `/usr/local/bin/vault` before running an upgrade in production) and
   restart the service.
4. Re-run the script once the node is healthy, starting from that node.

# Disaster Recovery

## Backups

Raft snapshots are taken hourly by a systemd timer on every node, running
`scripts/snapshot.sh`. The Ansible role `vault_snapshots` installs the
timer; it is **off by default** and turns on with:

```yaml
vault_snapshots_enabled: true
vault_snapshots_role_id: "<approle role_id>"
vault_snapshots_secret_id: "<approle secret_id>"
```

The destination comes from the Terraform outputs via
`scripts/terraform-to-ansible.sh` — an S3 bucket on AWS, a blob container
on Azure. Run it by hand the same way:

```bash
./scripts/snapshot.sh --cloud aws --bucket <name>
```

### What the script guarantees

These are the behaviours worth knowing, because each one is a way a
backup job can appear to work while producing nothing usable:

- **Only the active node snapshots.** Standbys exit 0 having done
  nothing. Three nodes uploading the same Raft state hourly would cost
  three times the storage for no additional recovery capability — and
  exiting non-zero on the standbys would mean a failed systemd unit on
  two nodes out of three every hour, which trains everyone to ignore it.
- **Nothing is uploaded until it verifies.** `snapshot inspect` has to
  succeed first. An empty or truncated snapshot that uploads cleanly
  looks exactly like a backup until the day you need it.
- **It never deletes.** Retention is a server-side lifecycle rule (S3
  lifecycle, Azure `delete_retention_policy`), and the AWS instance role
  has no `s3:DeleteObject`. A node that can prune backups is a node that
  can destroy them.
- **The local copy is always removed**, on success and on failure. An
  hourly timer that leaves snapshots on disk fills it and takes the node
  down — a backup job causing the outage it exists to prevent.

### Recovery point objective

Hourly snapshots mean up to an hour of writes can be lost. That is the
number to argue about before tuning anything else here; change it with
`vault_snapshots_schedule` (any systemd `OnCalendar` expression).

The timer sets `Persistent=true`, so a node that was down over its window
takes a snapshot when it comes back rather than skipping the cycle.

## Restore procedure

1. Provision (or reuse) a Vault node with the same storage config.
2. Stop the Vault service on the target node.
3. Restore the snapshot:

   ```bash
   vault operator raft snapshot restore /path/to/vault.snap
   ```

4. Restart Vault and confirm seal/unseal status.
5. Verify peer list and re-join any additional nodes if restoring into a
   multi-node cluster.

## Loss-of-quorum scenario

**Losing quorum is not the same failure as losing data**, and this page
used to send both to the same remedy. It does not any more, because the
remedies differ in what they cost.

If a majority of nodes are gone but one survivor still has its storage,
that survivor holds every write Raft committed. It cannot *do* anything
with them — no leader can be elected, so reads and writes fail with
`local node not active but active cluster node not found` — but nothing
is lost. Restoring a snapshot into it would work, and would silently
discard everything written since that snapshot was taken. On an hourly
snapshot schedule that is up to an hour of secrets, leases and tokens
thrown away to fix a problem that did not require throwing anything
away.

Raft's own recovery mechanism for this is `peers.json`: a file naming
the peers that are actually left, read once at startup and consumed.
[`scripts/recover-quorum.sh`](../scripts/recover-quorum.sh) performs it:

```bash
./scripts/recover-quorum.sh \
    --peers vault-0=vault-0:8201 \
    --compose-service vault-0
```

On a real node the same three steps are `systemctl stop vault`, write
`peers.json` into the Raft directory, `systemctl start vault` — which is
what `--service-name` does. That path is written from Vault's documented
procedure and is **not exercised by any test here**; the suite runs the
compose path. Treat it as reviewed, not proven.

Name **every** surviving voter, not just the one you are running on.
Recovering a five-node cluster that lost two means listing the three that
are left; listing one discards two healthy nodes' votes.

### This is not "editing the Raft log"

The previous version of this section warned against manually editing the
Raft log, and that warning stands — `raft.db` is not something to touch.
`peers.json` is a different thing: a recovery file Raft supports, reads
once, applies, and deletes. Conflating the two is what made a supported
procedure look reckless and pushed a snapshot restore that costs data.

### When to restore instead

When the survivor's storage is gone or suspect. If there is no node that
still holds the data, there is nothing for `peers.json` to preserve, and
[the restore procedure](#restore-procedure) is the answer.

### A quorum-less node still reports healthy

Worth knowing before an incident, because it changes where the traffic
goes. A node that has lost quorum is still *unsealed*, so:

```text
GET /v1/sys/health?standbyok=true   →   200
```

The AWS target group matches `200,429` — 200 active, 429 standby — so it
keeps a quorum-less node in the pool, routing requests to something that
answers every one of them with a 500. The health check is not lying; it
is answering a narrower question than the load balancer is asking.

Monitoring does catch it: `VaultNoActiveNode` fires on
`sum(vault_core_active) < 1`, and its description quotes the exact error
the node returns. So the alert is the thing to trust here, not the pool
membership. [`tests/quorum-recovery`](../tests/quorum-recovery/run-tests.sh)
asserts the 200, so if Vault ever changes it this page gets revisited
rather than quietly going stale.

### What is proven

[`tests/quorum-recovery`](../tests/quorum-recovery/run-tests.sh) runs the
whole sequence against a real three-node cluster on every PR: write a
secret, destroy two nodes, confirm the survivor cannot serve, recover it,
confirm the pre-outage write reads back, and bring a replacement node in.
It also runs the recovery script against a *healthy* cluster to confirm
it refuses — a guard only ever exercised where it passes is not a guard.

Not proven: the `--service-name` path on a real node, and any of this on
a cloud profile, neither of which has been applied.

## The snapshot is only half of a backup

With auto-unseal, a Raft snapshot is encrypted under the unseal key —
the Transit key locally, a KMS key in the cloud profiles. Losing that
key alongside the cluster leaves the snapshot mathematically
undecryptable. It is a real backup only if the key material survives
independently.

In practice that means:

- The KMS key must not live only in the account or region the cluster
  did, and must not be deleted as part of tearing a cluster down.
- Whoever can restore needs access to both the snapshot bucket and the
  key.
- Key rotation is fine — AWS KMS and Azure Key Vault keep old key
  versions, so older snapshots stay readable. Key *deletion* is not.

## Testing

`scripts/dr-drill.sh` runs the whole cycle against the local Docker
Compose profile: seed a canary secret, snapshot, destroy the node and
its storage, bring up an empty replacement, restore, and verify the
canary comes back.

```bash
make test          # or: ./scripts/dr-drill.sh
```

It runs in CI on every PR (`dr-drill-test`), so the restore path can't
rot unnoticed — which is the point, since a restore procedure nobody
exercises is a procedure nobody knows is broken.

Two details the drill makes concrete, both easy to be surprised by
mid-incident:

- **The replacement node's own root token stops working after the
  restore.** The restore replaces the token store along with everything
  else, so you continue with the token from *before* the disaster. The
  drill asserts this both ways.
- **`-force` is needed** when restoring into a different cluster
  instance than the snapshot came from, because the cluster IDs differ.
  What actually has to match is the seal.

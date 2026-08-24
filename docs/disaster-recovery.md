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

If a majority of Raft peers are lost, follow the documented Vault
"disaster recovery via snapshot on a single node, then re-join peers"
procedure — do not attempt to manually edit the Raft log.

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

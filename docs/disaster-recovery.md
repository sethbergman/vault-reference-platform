# Disaster Recovery

## Backups

Raft snapshots are taken on a schedule (default: hourly) via
`scripts/snapshot.sh`, which wraps:

```bash
vault operator raft snapshot save /tmp/vault.snap
```

and ships the result to the configured object storage bucket with a
timestamped key.

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

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

## Testing

Restore drills should be run against the `local` Docker Compose profile
on a regular cadence (see `scripts/dr-drill.sh`) rather than assumed to
work from the runbook alone.

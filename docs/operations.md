# Operations Runbooks

## Health checks

```bash
vault status
vault operator raft list-peers
curl -s https://<node>:8200/v1/sys/health | jq
```

`/v1/sys/health` returns distinct HTTP status codes for active/standby/
sealed nodes — this is what the load balancer health check keys off of.

## Upgrades

Rolling, one node at a time:

1. Take a fresh Raft snapshot (see `disaster-recovery.md`).
2. Remove the node from load balancer rotation.
3. Stop Vault, replace the binary, restart.
4. Confirm it rejoins the cluster and unseals (auto-unseal) or unseal
   manually (dev profile).
5. Re-add to rotation before moving to the next node.
6. Never upgrade the leader first — step it down (`vault operator step-down`)
   and upgrade it last.

## Capacity planning

Track: request latency (p99), open file descriptors, Raft log size/growth
rate, and storage backend disk usage. Raft storage grows unbounded between
snapshots/compactions, so snapshot cadence has a direct capacity impact.

## Common incidents

- **Node sealed unexpectedly**: check for KMS/auto-unseal connectivity
  issues before assuming a crash; auto-unseal failures seal the node on
  restart.
- **Leader flapping**: usually networking between nodes, not Vault itself
  — check Raft peer latency first.
- **High request latency**: check for policy/ACL evaluation overhead on
  high-cardinality paths before scaling nodes.

# Troubleshooting

| Symptom | Likely cause | First step |
|---|---|---|
| `vault status` shows sealed after restart | Auto-unseal KMS unreachable | Check IAM/network policy to KMS endpoint |
| Load balancer marks all nodes unhealthy | Health check hitting standby nodes only | Confirm LB health check follows Vault's active/standby status codes, not just TCP |
| `permission denied` on a known-good token | Policy drift | Diff applied policy against `examples/policies/` source of truth |
| Raft peer stuck as "voter" but unreachable | Autopilot is not configured — Vault ships `cleanup_dead_servers = false`, so a replaced node stays a voter forever | Run `scripts/configure-autopilot.sh`; remove the stale peer by hand with `vault operator raft remove-peer <node-id>` if it predates the fix |
| Snapshot restore fails with version mismatch | Restoring across incompatible Vault versions | Restore into a node running the same Vault version as the snapshot |
| Writes fail with `local node not active but active cluster node not found` | A majority of nodes are gone, so no leader can be elected | If a survivor still has its storage, `scripts/recover-quorum.sh` — **not** a snapshot restore, which discards everything since the last snapshot. See [disaster-recovery.md](disaster-recovery.md#loss-of-quorum-scenario) |
| Load balancer reports a node healthy while every request returns 500 | A quorum-less node is still unsealed, so `sys/health?standbyok=true` answers 200 and the target group's `200,429` matcher keeps it in the pool | Trust `VaultNoActiveNode`, not pool membership. The alert fires on `sum(vault_core_active) < 1` |
| `vault operator raft list-peers` fails during an outage | It needs a leader to answer, so it returns the same 500 as everything else | Use `vault read sys/leader`; the peer list is unavailable until leadership returns |
| Root token revoked and no way back in | `generate-root` needs a quorum of recovery keys, which the bootstrap used to discard | `scripts/generate-root-token.sh --keys-file docker/dev/.recovery-keys.json`. If the keys are genuinely gone, so is administrative access — see [security.md](security.md#the-root-token) |

This is a starting list — expand it as real incidents get resolved.

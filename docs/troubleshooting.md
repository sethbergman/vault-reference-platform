# Troubleshooting

| Symptom | Likely cause | First step |
|---|---|---|
| `vault status` shows sealed after restart | Auto-unseal KMS unreachable | Check IAM/network policy to KMS endpoint |
| Load balancer marks all nodes unhealthy | Health check hitting standby nodes only | Confirm LB health check follows Vault's active/standby status codes, not just TCP |
| `permission denied` on a known-good token | Policy drift | Diff applied policy against `examples/policies/` source of truth |
| Raft peer stuck as "voter" but unreachable | Node removed without `raft remove-peer` | Run `vault operator raft remove-peer <node-id>` |
| Snapshot restore fails with version mismatch | Restoring across incompatible Vault versions | Restore into a node running the same Vault version as the snapshot |

This is a starting list — expand it as real incidents get resolved.

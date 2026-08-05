## Rolling upgrades

[#rolling-upgrades](#rolling-upgrades)

Vault version upgrades are performed with `scripts/vault-upgrade.sh`, which
upgrades an HA cluster one node at a time with zero downtime.

### What it does

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

### Usage

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

### Prerequisites

- SSH key-based access from the machine running the script to every node
  in `--nodes`.
- The remote user must be able to `sudo systemctl` the Vault service
  without a password prompt.
- `bash`, `curl`, `unzip`, `ssh`, and `jq` on the machine running the script.

### Rollback

The script does not automatically roll back a failed node. If a node fails
its post-upgrade health check:

1. Do not proceed to the next node — the script already stops here.
2. SSH into the failed node and check `journalctl -u vault -n 100` for the
   startup error.
3. If needed, manually restore the previous binary (keep a copy of
   `/usr/local/bin/vault` before running an upgrade in production) and
   restart the service.
4. Re-run the script once the node is healthy, starting from that node.

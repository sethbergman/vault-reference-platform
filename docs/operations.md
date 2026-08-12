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

Rolling, one node at a time, automated via `scripts/vault-upgrade.sh`:

```bash
./scripts/vault-upgrade.sh <download-url> \
  --nodes vault-node-1,vault-node-2,vault-node-3 \
  --ssh-user deploy \
  --sha256 <expected-sha256>
```

The script handles the full rolling-upgrade sequence:

1. Downloads the release archive from the given URL and verifies it's a
   valid zip.
2. If `--sha256` is provided, verifies the archive's checksum before
   extracting — refuses to proceed on a mismatch. Strongly recommended;
   without it the script logs a warning and skips verification.
3. For each node, in order:
   - If the node is the current leader, steps it down first
     (`sys/step-down`) so it becomes a standby before being touched —
     the leader is never upgraded first.
   - Stops the Vault service, swaps the binary, restarts the service.
   - Polls `sys/health` and waits for the node to report healthy before
     moving to the next node.
4. If any node fails to come back healthy within the timeout, the script
   **stops immediately** — it will not continue upgrading the rest of the
   cluster with a bad node in the mix.

Options: `--nodes` (required), `--ssh-user`, `--ssh-key`, `--binary-path`
(default `/usr/local/bin/vault`), `--service-name` (default `vault`),
`--vault-addr` (default `https://127.0.0.1:8200`), `--health-timeout`
(default `120`s), `--skip-tls-verify`, `--sha256`. Run with `-h` for the
full usage.

**Prerequisites:** SSH key-based access from the machine running the
script to every node in `--nodes`; the remote user must be able to
`sudo systemctl` the Vault service without a password prompt; `bash`,
`curl`, `unzip`, `ssh`, `jq`, and `sha256sum` on the machine running it.

**Before running against production:**

- Take a fresh Raft snapshot first (see `disaster-recovery.md`) — the
  script does not do this for you.
- Get the expected SHA256 from HashiCorp's `SHA256SUMS` file for the
  release and pass it via `--sha256`.

**If a node fails its post-upgrade health check:**

1. The script has already stopped — it will not touch the remaining nodes.
2. SSH into the failed node and check `journalctl -u vault -n 100` for the
   startup error.
3. If needed, restore the previous binary (keep a copy of
   `/usr/local/bin/vault` before upgrading in production) and restart the
   service.
4. Re-run the script once the node is healthy, starting from that node.

## Secret rotation

AppRole `secret_id`s are rotated on a recurring cadence, not issued once
and forgotten:

```bash
./scripts/rotate-secret-id.sh --role app
```

Each run issues a fresh `secret_id` and revokes the one from the previous
run (tracked by accessor under `.vault-rotation-state/`), so at most one
`secret_id` per role is live at a time. Roles themselves are created once
via `scripts/bootstrap-approle.sh`. See `docs/secret-rotation.md` for
full usage, the `--wrap-ttl` handoff option, and rollback guidance.

**Schedule rotation comfortably inside the role's `secret_id_ttl`** — the
whole point is for rotation to always beat natural expiry.

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

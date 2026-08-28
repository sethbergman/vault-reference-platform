# Integration tests (real cluster)

```bash
./tests/integration/run-tests.sh
./tests/integration/run-tests.sh --keep-running   # leave the cluster up
```

Takes a few minutes. Needs `docker compose`, the `vault` CLI, `jq`,
`openssl` and `curl`. Tears the cluster down afterwards unless told not
to.

## Why these exist

Every other suite here replaces Vault with a shim. That is the right
trade for most things — shims are fast, need no credentials, and make
failure modes reachable that a real cluster would not reproduce on
demand.

But a shim can only prove a script issues the commands you expected. It
cannot prove Vault accepts them, and it cannot prove anything about what
happens to a running cluster afterwards. Several claims in this
repository sat entirely on documentation:

| Claim | Previously backed by |
|---|---|
| Snapshots are restorable | a shim writing bytes to a file |
| Standby nodes skip snapshots | a shim reporting whatever `ha_mode` we set |
| SIGHUP reloads certs without restarting | HashiCorp's listener docs, nothing else |
| A cert swap keeps the node in the cluster | nothing |

This suite stands up the real three-node cluster from
`scripts/bootstrap-dev-cluster.sh` — real Vault 1.17.2, real Raft, real
Transit auto-unseal, real TLS — and checks each of them.

## The assertion that matters most

The PKI renewal design rests on Vault reloading certificate *contents* on
`SIGHUP` without restarting. If that were wrong, every renewal would drop
leadership and, on a cluster without auto-unseal, require a manual
unseal — a nightly outage instead of a rotation.

So the test compares the container's process start time either side of
the swap:

```bash
docker inspect -f '{{.State.StartedAt}}' "$(compose ps -q vault-0)"
```

A restart would also swap the certificate, and would also look like
success from the outside. The start time is what separates the two.

Alongside it: the node is still unsealed, all three peers are still
voters, and a secret written before the swap is still readable.

## What is real here

Everything except the cloud. Real Raft consensus, real leader election,
real TLS handshakes, real snapshots inspected by real Vault. The scripts
run as host processes against the cluster's published ports, the way they
would on a node.

Two things are deliberately different from a cloud deployment, and both
are stated rather than hidden:

- **Reload is `docker compose kill -s HUP`, not `systemctl reload`.** The
  signal Vault receives is identical; only the delivery differs.
- **All three nodes share one host directory for TLS material.** On real
  nodes each has its own. This makes the trust-bundle step simpler here
  than it would be in production, where the bundle has to be distributed
  to every node before any certificate is swapped.

## What is still not covered

The cloud profiles. Neither AWS nor Azure has been applied to a real
account, and nothing here changes that. `tests/cloud-apply-emulated`
proves the AWS profile applies, not that anything it describes runs —
see the note in [`docs/deployment.md`](../../docs/deployment.md).

Also untested: a full migration of *every* node from bootstrap
certificates to Vault PKI. This suite swaps one node and checks the
cluster survives, which is the risky step; it does not run the whole
rollout, so the final `--replace-ca` step that drops the bootstrap CA is
still only covered by the shim suite.

## When it fails

The runner prints the last 30 lines of `vault-0`'s logs on failure, which
is usually enough to tell a TLS problem from a Raft one. To investigate
by hand:

```bash
./tests/integration/run-tests.sh --keep-running
```

Then the cluster is still up, `docker/dev/tls/` holds whatever the test
wrote, and `VAULT_ADDR=https://127.0.0.1:8200` with
`VAULT_CACERT=docker/dev/tls/ca.crt` will talk to it.

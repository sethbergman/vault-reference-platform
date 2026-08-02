# Security Model

## Transport

All client and inter-node traffic is TLS-terminated at the Vault process
itself (not offloaded at the load balancer), using certificates issued by
the internal CA under `examples/pki/`.

## Unsealing

- **Production**: cloud KMS auto-unseal (AWS KMS / Azure Key Vault). No
  human holds a usable key share in steady state.
  - Recovery keys (Shamir shares over the KMS-wrapped root key) are still
  generated at init time and must be distributed and stored per your
  organization's key-custodian policy.
- **Local/dev**: Shamir key shares, printed at `vault operator init` time.
  Never used in production profiles.

## Authentication & policy

- Human access goes through an OIDC auth method, not tokens or userpass.
- Machine/workload access uses AppRole or the platform-native auth method
  (e.g. AWS IAM auth for EC2-hosted workloads).
- Policies are least-privilege and scoped per application/environment;
  see `examples/policies/` for the starting set.

## Audit

The file audit device is enabled by default in all profiles; production
deployments should also ship audit logs to a SIEM.

## Hardening baseline (applied via Ansible)

- Vault runs as a non-root user with a locked-down systemd unit
  (`NoNewPrivileges`, `ProtectSystem=strict`, memory locking enabled via
  `mlock`).
- Swap is disabled on Vault nodes to avoid secrets being paged to disk.
- The Vault API port is only reachable from the load balancer and other
  cluster nodes, not from the public internet.

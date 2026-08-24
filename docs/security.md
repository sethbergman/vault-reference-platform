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
- **Local/dev**: Vault Transit auto-unseal — the same `seal` stanza shape
  as production, backed by a standalone Vault instance instead of a cloud
  KMS. That instance is itself still unsealed with a single Shamir key
  share; see [`docs/auto-unseal.md`](auto-unseal.md).

## Authentication & policy

- **CI pipelines** authenticate with GitHub Actions OIDC via the JWT auth
  method — no stored credential at all. See
  [`docs/ci-authentication.md`](ci-authentication.md).
- **Other machine/workload access** uses AppRole, with `secret_id`s
  rotated on a cadence (see below), or the platform-native auth method
  (e.g. AWS IAM auth for EC2-hosted workloads).
- **Human access** goes through an OIDC auth method rather than tokens or
  userpass, with IdP group membership mapped to Vault policies. See
  [`docs/human-authentication.md`](human-authentication.md). Access is
  granted and revoked by changing group membership in the identity
  provider, not by provisioning anything per-person in Vault.
- Policies are least-privilege and scoped per application/environment;
  see `examples/policies/` for the starting set.

## Secret rotation

AppRole `secret_id`s are treated as short-lived credentials, not
set-once config: `scripts/bootstrap-approle.sh` creates the role once,
and `scripts/rotate-secret-id.sh` is run on a recurring cadence to issue a
new `secret_id` and revoke the previous one. See
[`docs/secret-rotation.md`](secret-rotation.md) for setup, rotation
cadence, and rollback guidance.

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

## Automated scanning

CI runs two scanners on every PR (`security-scan` in
[`.github/workflows/ci.yml`](../.github/workflows/ci.yml)):

- **gitleaks** — committed secrets, over full history rather than just
  the tip, since a credential that was committed and later removed has
  still leaked.
- **Trivy config** — Terraform and Dockerfile misconfigurations, failing
  the build on HIGH and above.

Accepted findings live in `.trivyignore.yaml`, and each one records why
it is accepted rather than fixed. A suppression with no justification is
indistinguishable from never having run the scanner, so entries state the
risk being taken and what would remove it.

Adding the scanners found four real problems, all now fixed:

| Finding | Why it mattered |
|---|---|
| Vault containers ran as **root** | Replacing the base image's entrypoint skipped the `su-exec` that drops privileges — the containers had been running Vault as root since the auto-unseal work. |
| Azure Key Vault had **no purge protection** | Purging it would not just break unsealing; every Raft snapshot is encrypted under that key, so all backups become permanently undecryptable. |
| Azure Key Vault accepted traffic from **any network** | No default-deny ACL on the key that unseals Vault. |
| Node egress allowed **every protocol and port** | Now scoped to TCP 443 and 80. |

VPC flow logs were added at the same time: Vault's audit device records
requests it served, and flow logs record attempts it never saw.

# Security Model

## Transport

All client and inter-node traffic is TLS-terminated at the Vault process
itself, not offloaded at the load balancer. That constraint is why both
cloud profiles use a layer-4 load balancer rather than an application
gateway — see [`docs/deployment.md`](deployment.md).

Certificates come from different places per profile:

| Profile | Issued by |
|---|---|
| Local / CI | `scripts/generate-dev-certs.sh` — a local CA, per-node leaves |
| AWS / Azure | Your own CA or ACM Private CA to bootstrap; Vault PKI for renewals |

The local CA is generated on demand into `docker/dev/tls/`, which is
gitignored. Nothing there is committed: a private key in version control
is compromised from the moment it lands, whether or not anyone notices.

The cloud profiles deliberately do **not** issue certificates in the
Terraform. Nodes come up expecting them at `/etc/vault.d/tls/` and Vault
refuses to start without them, which is the correct failure — a Vault
serving plaintext is worse than one that will not boot.

### Renewal from Vault's own PKI

Once a cluster is running, `scripts/bootstrap-pki.sh` configures Vault's
PKI engine to issue node certificates, and a daily systemd timer on each
node renews them through `scripts/issue-node-cert.sh`.

Certificates default to a 72-hour lifetime, renewed when less than a day
remains. Short-lived on purpose: a stolen key is useful for hours rather
than months, and the renewal path runs constantly instead of annually, so
it is not discovered to be broken during an incident.

Renewal is graceful. Vault reloads the *contents* of `tls_cert_file` and
`tls_key_file` on `SIGHUP`, using the paths it was given at startup — so
writing new material to the same paths and signalling means no restart,
no re-unseal, and no leadership change. The corollary is that the paths
must never move: Vault ignores a changed `tls_cert_file` on `SIGHUP` and
keeps serving from the original path, which would look like it worked.

This is verified rather than assumed. `tests/integration` swaps a
certificate on a running three-node cluster and checks that the node
serves the new one while its process start time is unchanged — a restart
would also swap the certificate, so the start time is what separates the
two.

### A successful reload command does not mean a successful reload

`systemctl reload vault` exits 0 as soon as the signal is delivered.
Vault reports reload failures afterwards, in its own log:

```text
==> Vault reload triggered
Error(s) were encountered during reload: 1 error occurred:
    * error encountered reloading listener: open ...vault.key: permission denied
```

The node keeps serving the previous certificate and nothing upstream
notices. On a daily timer that is a green unit every day until the
certificate expires and the node drops out of the cluster.

So `issue-node-cert.sh` connects to the listener afterwards and compares
the served certificate's serial with the one it just installed, failing
if they differ. Pass `--no-verify-reload` to skip it.

The usual cause is a key Vault cannot read — worth remembering that the
renewal process and the Vault process are not the same user.

### The bootstrap problem

**Vault's PKI cannot issue the certificates the cluster hosting it needs
in order to start.** Vault will not serve without TLS, so the first
certificate on every node has to come from somewhere else:

1. Bootstrap certificates from `generate-dev-certs.sh` (local) or your
   own CA / ACM Private CA (cloud) bring the cluster up.
2. `bootstrap-pki.sh` configures the PKI engine on the running cluster.
3. Nodes renew from Vault PKI from then on, including nodes that join
   later.

The bootstrap CA stays load-bearing until every node has been re-issued
from Vault PKI and reloaded, and it has to remain in the trust bundle
until then. There is no way around that ordering. The `vault_pki` Ansible
role is off by default and refuses to run on a node with no existing
certificate, rather than producing a timer that fails quietly every night.

### Doing the migration

`scripts/migrate-to-vault-pki.sh` sequences the rollout. It is not a loop
around `issue-node-cert.sh`: get the order wrong and nodes stop trusting
each other, which presents as a network fault and gets diagnosed as one.

```bash
./scripts/migrate-to-vault-pki.sh \
    --nodes vault-0=10.0.1.10:8200,vault-1=10.0.1.11:8200 \
    --domain vault.internal \
    --dry-run
```

Three phases, and the order is the whole point:

| Phase | What | Why it is not optional |
|---|---|---|
| `trust` | Every node's bundle gains the PKI CA, keeping the old one | A node presenting a PKI certificate before its peers trust that CA is a node its peers refuse |
| `swap` | One node at a time moves onto a PKI certificate | Peers already trust the new CA; the node still trusts them |
| `prune` | The bootstrap CA comes out | Only safe once nothing presents a bootstrap certificate |

Run `--dry-run` first: it prints the plan, including which node is
active, and changes nothing.

**Standbys first, the active node last.** Not to avoid an election — a
swap costs no leadership, since Vault reloads on `SIGHUP` without
restarting. It is about what is still true if the run fails halfway: the
leader is the node you least want in an unknown state, so it is touched
last, once the procedure has already worked twice.

**The prune refuses while any node still serves a bootstrap
certificate**, checked on the wire rather than on disk. A certificate
written and never reloaded is not migrated, and dropping the bootstrap CA
at that point makes every peer reject that node.

Each phase gates on the node coming back healthy *and* the cluster still
having every voter before moving on. A run that fails stops where it is
and says which nodes were untouched.

A production deployment would more likely make this PKI mount an
*intermediate* signed by an offline root, so that compromising this Vault
does not compromise the whole chain. `bootstrap-pki.sh` generates an
internal root instead, because an offline root is not something this
repository can provide — that is a real limitation, not a recommendation.

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

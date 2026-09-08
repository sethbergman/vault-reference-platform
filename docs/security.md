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

#### What else trusts the bundle

Vault is not the only thing that reads the trust bundle, and the prune is
the step that invalidates every other copy of it. Anything verifying
Vault's TLS loaded that file once at startup: after the bootstrap CA is
dropped it is validating against a CA that no longer signs anything.

In the local profile that is Prometheus and the blackbox exporter, which
both mount `docker/dev/tls/ca.crt`:

```bash
docker compose -f docker/dev/docker-compose.yml \
    up -d --force-recreate prometheus blackbox
```

Recreate, not `restart`, and the difference is not cosmetic. The prune
replaces the bundle rather than editing it — `issue-node-cert.sh`
installs the new one with `install -m 0644`, so the path survives and the
inode does not — and both containers mount that path as a *single file*.
Docker Desktop's WSL backend resolves a single-file bind mount once, when
the container is created, into a content-addressed copy under
`docker-desktop-bind-mounts`. After the prune that copy is gone, and
`restart` reuses the reference to it:

```text
error mounting ".../docker-desktop-bind-mounts/..." to rootfs at
"/etc/blackbox/vault-ca.crt": no such file or directory
```

The container then does not come back at all: it dies with exit 127, so
the probe is not stale, it is absent — and so is every other metric
Prometheus was reporting.

The cache key is the host *path*, not the contents. Two runs against
different PKI roots produce the same dangling entry, so this is not
intermittent: it recurs on every run of the migration, on every machine
using the Docker Desktop WSL backend.

Native Linux Docker re-resolves the bind by path when the container
starts, so a plain `restart` works there and CI has never reproduced
this. That is worth naming as a hazard of its own: a green integration
run says nothing about whether this procedure works on the machine you
are about to run it on. It was found on a developer laptop, by a suite
that passes in CI on the same commit.

Mounting `docker/dev/tls` as a directory would sidestep all of it, since
a directory bind mount survives a file being replaced inside it. That is
deliberately not done — the directory holds every node's private key,
and Prometheus has no business being able to read them.

The failure mode is worth stating because it is quiet. The blackbox probe
does not error in a way anyone sees — it simply stops producing
`probe_ssl_earliest_cert_expiry`, and certificate expiry becomes
unmonitored while every dashboard still looks fine. That is the exact
shape the `absent()` alerts in [`docs/monitoring.md`](monitoring.md) exist
to catch, and it is why they are paired with every freshness rule.

`migrate-to-vault-pki.sh` prints this reminder after pruning. It does not
do the restart: which processes hold a copy of the bundle is deployment
knowledge the script does not have.

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

## The root token

`vault operator init` mints a root token because a new cluster has no
other way in. It answers to no policy, expires at no time, and ends up in
the shell history of everyone who exported it. Vault's guidance is to
revoke it once the auth methods are configured and generate a new one on
demand.

This repository used to say nothing about that. For a security reference
that is not neutral — silence reads as "keep it", which is a
recommendation nobody meant to make.

### Revoking it

```bash
# a token that proves there is still a way in
TOKEN=$(vault write -field=token auth/approle/login \
    role_id="$ROLE_ID" secret_id="$SECRET_ID")

./scripts/revoke-root-token.sh --verify-with "$TOKEN"
```

The `--verify-with` token is required, and the script checks two things
about it: that it is **not** itself a root token, and that it can read
`sys/health`. A token that merely exists proves nothing — `token
lookup-self` succeeds for a token with no policies at all. Revoking root
with nothing else able to administer the cluster is a lock-out whose only
remedy is a quorum of recovery-key holders in a room.

### Getting one back

```bash
./scripts/generate-root-token.sh --keys-file docker/dev/.recovery-keys.json
```

With a seal stanza the cluster unseals itself, so `operator init` returns
**recovery keys** rather than unseal keys. They exist for exactly this,
and for `operator rekey`. The ceremony is a nonce, a one-time password,
one call per share, and a decode step — fiddly enough that doing it from
memory during an incident is how people end up deciding to keep the root
token instead, which is why it is a script.

In a real deployment the shares are held by different people and passed
in one at a time with `--key`. `--keys-file` exists because the dev
profile has no second person.

### On the local profile

`bootstrap-dev-cluster.sh` writes the recovery keys to
`docker/dev/.recovery-keys.json`, mode 0600, gitignored, regenerated on
every bootstrap. It used to discard them, which made revoking the root
token a one-way door — and would have made the advice above destructive
to anyone who followed it.

Root stays on stdout and the keys do not: `ROOT_TOKEN=$(...)` still works.

### What is proven

[`tests/root-token`](../tests/root-token/run-tests.sh) runs the whole
lifecycle against a real cluster on every PR: the keys are kept at 0600
and gitignored, both refusals fire in the state where they should refuse,
the root token stops working, an AppRole token carries on administering
the cluster, and a new root token comes back from a quorum of shares and
is a different credential from the one revoked.

Not covered: doing this on a cloud profile, where the seal is KMS rather
than Transit. The ceremony is the same and the recovery keys come from
the same place, but no cloud profile has been applied.

## Rotating the keys

Two operations share a name and almost nothing else.

```bash
export VAULT_ADDR=https://127.0.0.1:8200
./scripts/rotate-keys.sh --barrier
./scripts/rotate-keys.sh --recovery-keys --keys-file docker/dev/.recovery-keys.json
```

**The barrier key** is what Vault encrypts storage with. Rotating it
creates a new version and uses it for new writes; every previous version
stays in the keyring, so existing data is still readable. It is online,
needs no shares, and cannot lock anyone out.

The reason it usually has never been run is that it sounds like the other
one. `tests/key-rotation` writes a secret, rotates, and reads it back
specifically to settle that.

**The recovery shares** are the other one. When a rekey completes the old
shares are dead, and if the new ones were not captured, nobody can
generate a root token or unseal by recovery again — discovered in the
emergency where you needed them.

### Recovery keys and unseal keys are the same ceremony

Which kind a Vault has depends only on how it is sealed. An auto-unsealed
cluster has recovery keys; a Shamir-sealed one has unseal keys;
`scripts/migrate-seal.sh` turns each into the other without changing
their values. So one script covers both, against two endpoints:

| Flag | Endpoint | CLI |
|---|---|---|
| `--recovery-keys` | `sys/rekey-recovery-key/*` | `vault operator rekey -target=recovery` |
| `--unseal-keys` | `sys/rekey/*` | `vault operator rekey` |

The CLI calls the second one *barrier* and makes it the default target,
which is worth knowing: `vault operator rekey` with no arguments, run
against an auto-unsealed cluster, addresses a set of keys that cluster
does not use.

```bash
export VAULT_ADDR=https://127.0.0.1:8300      # vault-unseal
export VAULT_TOKEN=$(jq -r .root_token docker/dev/.unseal-keys.json)

./scripts/rotate-keys.sh --unseal-keys \
    --keys-file docker/dev/.unseal-keys.json --shares 5 --threshold 3
```

### The local root of trust keeps its own key now

`vault-unseal` is a Shamir-sealed Vault holding the Transit key every
cluster node auto-unseals against. Its unseal key used to live in a shell
variable inside `bootstrap-dev-cluster.sh` and nowhere else.

That made a single `docker compose restart vault-unseal` unrecoverable,
which is not hypothetical — it is what a Docker Desktop restart or a host
reboot does. And the failure is not graceful. `vault-unseal` comes back
sealed, and a cluster node restarted after that does not come back
sealed; it fails to start:

```text
error parsing Seal configuration: ... 503  * Vault is sealed
```

with no key anywhere to fix it. The only way back was `make destroy`.

The bootstrap writes `docker/dev/.unseal-keys.json` (0600, gitignored)
now, holding the shares and the root token, and `tests/key-rotation`
restarts `vault-unseal` on every run to prove the kept keys open it and
that a cluster node auto-unseals against it afterwards.

It is also what makes a Shamir rekey testable at all: rekeying needs a
quorum of the current shares, and there were none.

### Why the rekey is scripted rather than documented

Vault has a verification phase for exactly this risk: the new shares are
issued but do not take effect until a threshold of them is handed back.
Fail it and the old shares still work.

`vault operator rekey` cannot ask for it. The CLI has `-verify` for the
second phase and no flag to require it at init — `require_verification`
is an API field — so the safe form of the ceremony is not reachable from
the command line. That asymmetry is most of the reason there is a script
here instead of a runbook.

Two more things the script exists to absorb, both found by running it:

| What Vault does | Why it matters |
|---|---|
| Returns the new shares as `keys_base64` | `operator init` calls the same thing `recovery_keys_b64`. Read the wrong name and you get an empty array from a rekey that reported success |
| Prints English, not JSON, on the final verify | Every share before the threshold returns a JSON progress object; the one that completes ignores `-format=json`. A loop watching `.complete` never sees it, submits again, and gets "no rekey configuration found" — an error that means the operation succeeded |

The second is how a set of recovery keys gets destroyed: the rekey takes
effect, the script reads failure, and the new shares are discarded. It
happened here, on a disposable cluster, which is why the new shares are
now written to `<keys-file>.new` **before** verification rather than held
in memory until after it.

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

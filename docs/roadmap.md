# Roadmap

What is done, what is not, and what "not" actually means.

The point of this file is to be specific about the gaps. A reference
platform is only useful if you can tell which parts have been exercised
and which parts are a plausible-looking configuration nobody has run.

## Shipped

| Version | Scope |
|---|---|
| v0.1 | Local Docker Compose deployment, base Terraform, docs |
| v0.2 | HA Raft cluster, auto-unseal, Prometheus/Grafana monitoring |
| v0.3 | Automated tests, CI security scanning (gitleaks, Trivy) |
| v0.4 | AWS and Azure profiles, TLS everywhere, Terraform → Ansible handoff |
| v0.5 | Scheduled snapshots, certificate renewal from Vault PKI, integration tests |

## The honest gap

**Neither cloud profile has been applied end to end.**

`terraform/aws` and `terraform/azure` are covered by `terraform test`
against mocked providers, and that catches more than it might sound like
— a Key Vault name exceeding Azure's 24-character limit, a Raft
`auto_join` configuration go-discover rejects outright, an IAM policy
granting delete on the snapshot bucket. But mocked providers do not
create anything, and a plan that succeeds is not a deployment that works.

Treat those two profiles as reviewed and tested, not as proven.

The local profile is different: `tests/integration` runs the operational
scripts against a real three-node Raft cluster on every PR, so the
snapshot, PKI and renewal paths are genuinely exercised.

## Next

### Audit devices

Nothing in this repository enables one. Vault currently records **no
audit log at all** — there is no answer to "who read that secret", which
is both a security gap and a compliance blocker for most real
deployments.

Deliberately not a small task, because the interesting part is the
failure mode: a Vault whose only audit device cannot write **stops
serving requests**. That is correct behaviour — an unauditable Vault
should refuse — but it means naive configuration turns a full disk into
an outage. Doing this properly means log rotation, a second device, and a
runbook for when the sink fills up.

### Alerting on absence

Prometheus scrapes and Grafana has a dashboard, but nothing alerts. There
are no `rule_files` in `docker/monitoring/prometheus.yml`.

The alerts worth having are the ones for things *not* happening, which is
the failure shape this project keeps running into:

- no snapshot object written in the last two hours
- a node's certificate within 24 hours of expiry
- fewer than three Raft voters
- a node sealed for more than a few minutes

Every one of those has already occurred here as a silent success: a green
timer, an exit code of zero, and no backup. Dashboards do not catch that;
alerts on absence do.

### Finishing the PKI migration

`tests/integration` swaps one node's certificate and verifies the cluster
survives — the risky step. It does not run the full rollout across every
node, so the final `--replace-ca` that drops the bootstrap CA from the
trust bundle is still covered only by shims.

Doing this properly means a script that sequences the whole migration:
distribute the combined trust bundle everywhere, swap one node at a time
with a health gate between each, then remove the bootstrap CA — the same
shape as `vault-upgrade.sh`.

### Dynamic secrets

Everything here uses the KV engine. The stronger argument for Vault is
credentials that do not exist until they are requested and expire on
their own — the database engine issuing short-lived Postgres users, for
example. Its absence makes this a well-operated secret *store* rather
than a demonstration of what Vault is actually for.

## Toward v1.0

v1.0 means a reference architecture someone could reasonably start from
in production. The blockers are, in order:

1. **A real cloud apply.** Until one of the two profiles has been stood
   up and torn down for real, the claim is unproven.
2. **Audit devices**, including the disk-full failure mode.
3. **Alerting**, particularly on absence.
4. **The full PKI migration path**, end to end.

Explicitly *not* planned: Vault Enterprise features (performance
replication, DR replication, namespaces, HSM auto-unseal). They would
make the reference untestable for most readers, and the open-source
feature set is enough to demonstrate the architecture.

## A note on how things get marked done

"Done" in the table above means there is a test that fails when the
feature breaks, not that the code exists. Several entries were written
before that was true and had to be corrected:

- "HA cluster" was claimed while nodes had no `retry_join` and never
  clustered.
- "Hourly snapshots" was documented for some time before anything
  scheduled them — and after that, before the leadership check worked.
- "Human access goes through OIDC" was aspirational for several releases.

The pattern is consistent enough to be worth stating: the documentation
tends to describe the intended design, and the gap between that and the
code is invisible until something exercises it.

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
| v0.6 | Dynamic database credentials (PostgreSQL), with root rotation |
| v0.7 | Alerting on absence: rules, Alertmanager, pushgateway, TLS probes |
| v0.8 | Audit devices, with the two-device availability tradeoff stated |
| v0.9 | The full PKI migration path, sequenced and tested end to end |

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

### Log shipping

Audit devices are enabled and tested, but nothing forwards the logs
anywhere. Where they go, how long they are kept and who can read them are
deployment decisions — and an audit log that only exists on the node it
describes is one a compromise can delete.

The local profile now uses a socket device to a collector container, so
the two devices fail independently and the integration suite can stop one
and show Vault still serving. What is still missing is the destination
being somewhere durable and off-host — the collector here writes to a
file in a sibling container, which survives a Vault disk filling and not
much else.

### Alert routing

Alertmanager is wired up and the tests confirm alerts reach its API, but
no receiver is configured. Where alerts should go — PagerDuty, Slack, an
on-call rotation — is site-specific, and a fake receiver would prove
nothing a reader could reuse.

Related: the cloud profiles have no monitoring stack at all. The rule
file is ordinary PromQL against standard Vault metrics and would port
directly, but nothing here deploys it outside the local profile.

### More database engines

The database engine is wired up for PostgreSQL only. Vault supports
MySQL, MSSQL, MongoDB and others through the same interface, and the
shape established here would carry over, but nothing else has been
exercised.

Related and larger: the cloud profiles do not provision a database at
all. `terraform/aws` and `terraform/azure` build a Vault cluster, not an
application estate, so pointing the engine at RDS or Azure Database is
currently left to the reader. Doing it properly would mean Terraform for
the instance, network rules letting Vault reach it, and `--sslmode
verify-full` rather than the dev profile's `disable`.

## Toward v1.0

v1.0 means a reference architecture someone could reasonably start from
in production. The blockers are, in order:

1. **A real cloud apply.** Until one of the two profiles has been stood
   up and torn down for real, the claim is unproven.
2. **Audit log shipping**, to somewhere a compromised node cannot reach.

Dynamic secrets, alerting, audit devices and the PKI migration path have
all moved off this list. The database
engine is tested against a real Postgres; the alert rules are unit-tested
with promtool and observed firing end to end against a live cluster.

Explicitly *not* planned: Vault Enterprise features (performance
replication, DR replication, namespaces, HSM auto-unseal). They would
make the reference untestable for most readers, and the open-source
feature set is enough to demonstrate the architecture.

## What "done" means here

An entry is marked done when there is a test that fails if the feature
breaks — not when the code exists. That distinction is why the table
above and the gap section can be read at face value.

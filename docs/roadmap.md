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
| v0.10 | Vault Agent: an application consuming a secret without a token |
| v0.11 | Audit logs that outlive the node they describe |
| v0.12 | Tamper-evident audit: a hash chain, and anchors the collector cannot reach |
| v0.13 | Alert routing by severity; MySQL as a second database engine |

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

### Off-host audit collection

Audit logs now survive the loss of the Vault node — the collector writes
to a volume with its own lifecycle, and the integration suite destroys
vault-0 outright to prove it.

What remains is that the collector is still on the same host. Anything
with Docker access can reach it, so a sufficiently privileged compromise
still reaches the evidence. Moving it is a one-line change to
`--second-address`; what is missing here is a demonstration of the far
end, and of the append-only storage that makes the trail tamper-evident
rather than merely present.

### Alert routing

The routing tree has shipped: severity-based receivers, grouping that
collapses an incident into one notification, and inhibit rules so an
outage pages for the cause rather than nine times for its consequences.
`tests/alert-routing` covers it, and the integration suite reads the
receiving end to confirm a critical alert reached the pager receiver and
not the ticket one.

What is still deliberately absent is any vendor integration. Where alerts
ultimately go is site-specific, and a config full of fake PagerDuty keys
would prove nothing a reader could reuse — so the receivers post to a
sink that records the delivery. Swapping that for a real receiver is the
one-line change the tree was shaped to make easy.

Related: the cloud profiles have no monitoring stack at all. The rule
file is ordinary PromQL against standard Vault metrics and would port
directly, but nothing here deploys it outside the local profile.

### More database engines

PostgreSQL and MySQL are both wired up and tested. Vault supports MSSQL,
MongoDB and others through the same interface and the shape carries over,
but nothing else has been exercised.

Adding the second one was worth more than the breadth suggests, because
it surfaced where the engines are *not* equivalent: MySQL has no
`VALID UNTIL`, so a credential issued against it lives until Vault
revokes it, where a Postgres credential dies on schedule even if Vault is
unavailable at lease end. That difference is asserted by the tests and
stated in [dynamic-secrets.md](dynamic-secrets.md) rather than smoothed
over.

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

   The preparation for it has shipped:
   [`scripts/preflight-cloud.sh`](../scripts/preflight-cloud.sh) checks
   what can be checked without spending anything,
   [`scripts/teardown-cloud.sh`](../scripts/teardown-cloud.sh) removes
   what `terraform destroy` cannot, and
   [`cloud-apply.md`](cloud-apply.md) lists the claims a real apply would
   settle — auto-unseal against a real KMS key, Raft `auto_join` against
   a real cloud API, the load balancer keeping standbys in the pool,
   snapshots authenticating by instance role, and a replacement node
   rejoining unattended.

   That preparation is *not* the item. Nothing in it constitutes
   evidence; it exists so that whoever spends the money gets a full set
   of answers from one session instead of half of them.
2. **Off-host audit collection**, so a compromised host cannot reach the
   evidence. The trail now outlives the node and an edit to it is now
   detectable -- entries are hash-chained as they arrive, and the
   `audit-anchor` service holds the chain head on a volume the collector
   cannot write to, which catches even a chain rewritten to be
   self-consistent.

   Both volumes still live on the same Docker daemon, so what exists is
   tamper *evidence* rather than tamper proofing, and the trail does not
   yet leave the machine. That is the remaining half.

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

It only holds if the tests are as strong as they look, and v0.13 found
three places where they were not.

An assertion of the form "the log must not contain X" is only as good as
the spelling its author thought to forbid. `"aws s3 cp"` reads like it
forbids uploading, but an upload via `aws s3api put-object` passed it —
demonstrated by making a standby upload and watching the guard stay
green. Three such assertions were widened to the shortest prefix covering
every way of doing the same thing, and a fourth, which named output text
rather than a command, was paired with a positive assertion so reworded
output breaks that instead of quietly passing.

The mutation testing meant to catch this had the same weakness. An
assertion rejecting `CREATE, ALTER, DROP`, "verified" by a mutation
granting exactly `CREATE, ALTER, DROP`, proves only that `grep` works;
granting `CREATE` alone walked through it. A useful mutation is one the
assertion does not name.

Both habits are in [CONTRIBUTING.md](../CONTRIBUTING.md), and
`tests/lint` now enforces in CI the invariants that shellcheck has no
opinion about — starting with trap handlers that return the result of a
bare test, which made two scripts exit 1 after succeeding.

None of this changes what the table above claims. It changes how much the
word "tested" in it is worth, which seemed worth writing down.

# Monitoring and Alerting

```bash
./scripts/bootstrap-dev-cluster.sh --with-monitoring
```

| Service | URL |
|---|---|
| Grafana | <http://localhost:3000> |
| Prometheus | <http://localhost:9090> |
| Alertmanager | <http://localhost:9093> |
| Pushgateway | <http://localhost:9091> |

## Why the alerts are about absence

Nearly every failure this repository has produced looked like success:

- snapshots were never taken on **any** node, with three green systemd
  timers, because the leadership check read a field that does not exist
  in `vault status -format=json`
- a certificate reload failed and Vault kept serving the old certificate,
  while the reload command exited 0
- a hostname check accepted every certificate, because `openssl` reports
  the result in its output rather than its exit code

A dashboard would not have caught any of them. Nothing was red; the
graphs simply had one fewer line than they should have, and absence does
not draw attention to itself.

So the rules in `docker/monitoring/rules/vault.yml` are built around
noticing when something **stops**.

## The trap these rules exist to avoid

A threshold alert on a metric that is not being reported never fires.

```promql
time() - vault_snapshot_last_success_timestamp_seconds > 7200
```

reads like "alert if the last snapshot was over two hours ago". It is
not. If snapshots stop entirely and nothing pushes the metric, the
expression has no series to evaluate and produces no result — which
Prometheus treats as nothing to alert on. The alert is silent in exactly
the situation it was written for.

Every freshness alert here is therefore paired with an `absent()` alert.
The pair is the unit; one without the other is a false sense of coverage,
and `tests/alerting/run-tests.sh` fails if a new freshness rule is added
without its pair.

## The alerts

| Alert | Fires when |
|---|---|
| `VaultNodeDown` | A node stops answering scrapes |
| `VaultAllTargetsMissing` | There are no Vault targets at all |
| `VaultNodeSealed` | A node reports itself sealed |
| `VaultQuorumLost` | Fewer than two of three nodes are unsealed |
| `VaultNoActiveNode` | Every node is healthy and none holds leadership |
| `VaultSnapshotStale` | No successful snapshot in over two hours |
| `VaultSnapshotMetricMissing` | Nothing is reporting snapshots at all |
| `VaultCertificateExpiringSoon` | A served certificate has under 24h left |
| `VaultCertificateProbeMissing` | Nothing is probing certificates |

`VaultAllTargetsMissing` is the one that catches the monitoring itself
failing. While it is true, every other rule in the file is silent.

## Where the numbers come from

Snapshots run hourly and certificates are renewed daily, so the
thresholds are one missed cycle plus margin. Two hours and 24 hours
respectively.

The `for:` durations in the committed rules are **short** — 30s to 2m —
so the integration tests can watch an alert fire inside a CI run. For a
real deployment they are too twitchy:

| Alert | Committed | Suggested |
|---|---|---|
| `VaultNodeDown` | 30s | 5m |
| `VaultNodeSealed` | 1m | 5m |
| `VaultQuorumLost` | 30s | 1m |
| `VaultNoActiveNode` | 1m | 5m |
| `VaultSnapshotStale` | 1m | 15m |
| `VaultSnapshotMetricMissing` | 2m | 15m |
| `VaultCertificateExpiringSoon` | 1m | 30m |

`VaultQuorumLost` deliberately stays short. Below quorum the cluster is
already refusing writes; waiting five minutes to say so buys nothing.

## Two things had to be added before absence was observable

**A pushgateway.** Vault does not know whether a snapshot was taken —
that is a batch job outside it. `scripts/snapshot.sh --metrics-push`
records success, and the absence of that record is what gets alerted on.
The push is deliberately non-fatal: a snapshot that reached storage but
failed to report is still a snapshot, and failing there would turn a
monitoring problem into a backup problem.

**A blackbox probe.** Certificate expiry is measured from what the
listener actually serves, not from the file on disk. Those differ exactly
when it matters: a renewal can write a new certificate and fail to reload
it, leaving a correct-looking file next to a process still serving the
old one. That happened here — see [`docs/security.md`](security.md).

## Routing

Where alerts ultimately go — PagerDuty, Slack, an on-call rotation — is
site-specific, and a config full of fake integration keys would prove
nothing a reader could reuse. So there are no vendor receivers here.

What *is* reusable is everything above the vendor, and that is what
`docker/monitoring/alertmanager.yml` sets out:

| | Critical | Warning |
|---|---|---|
| Receiver | `page` | `ticket` |
| `group_wait` | `0s` | `30s` |
| `repeat_interval` | `15m` | `12h` |

**`group_wait: 0s` on critical is the point of the split.** At the
default a page waits to see whether a second alert joins its group.
That is a fine trade for a ticket and a bad one for a cluster that has
lost quorum. Equally, a critical that notifies once and then goes quiet
is indistinguishable from one nobody sent, so it repeats every 15
minutes until someone acts; a warning repeats twice a day and does not
wake anyone.

Grouping is by `alertname` and `cluster`, deliberately **not** by
`instance`. Three nodes sealing at once is one incident, and grouping per
instance would page three times for it.

### Inhibition

Two rules, both encoding the same judgement — when one fact explains
another, only the explaining fact is worth waking someone for:

- `VaultAllTargetsMissing` suppresses `VaultNodeDown`. If Prometheus has
  no Vault targets at all, every node is trivially "not responding".
- `VaultQuorumLost` suppresses `VaultNoActiveNode`. Having no active node
  is what losing quorum looks like from outside; quorum is the one that
  says what to do about it.

Getting inhibition wrong is costly in both directions: too little and an
outage pages nine times, too much and the alert that mattered is the one
suppressed.

### Pointing it at a real pager

Replace the `webhook_configs` under `page` and `ticket` with your
vendor's receiver. The routing tree, the grouping and the inhibit rules
stay as they are — they are the part that transfers.

### The sink

Each receiver posts to `alert-sink`, which records the delivery and does
nothing else. It is **not** a stand-in for a pager. It exists so a test
can ask a question Alertmanager's own API cannot answer: not "did this
alert arrive", but "which receiver did it reach". Without something on
the receiving end, an alert routed to the wrong place looks exactly like
one routed correctly.

## What is tested

`tests/alerting/run-tests.sh` runs `promtool test rules` against the real
rule file with synthetic series. The cases that matter are the ones where
a series **stops existing**: the suite asserts that `VaultSnapshotStale`
does *not* fire in that situation and `VaultSnapshotMetricMissing` does,
which is the entire argument for pairing them.

It also checks structurally that every freshness rule has an `absent()`
partner, that every alert carries a summary, severity and runbook, and
that `prometheus.yml` actually loads the rule file — a rule file nothing
loads is indistinguishable from no rules at all.

`tests/integration/run-tests.sh` goes further against a live cluster: it
asserts every metric the rules name is actually being reported (a rule on
a misspelled metric parses, loads, and can never fire), then waits for
`VaultSnapshotMetricMissing` to fire, confirms Alertmanager received it,
**reads the sink to confirm it was delivered to the `page` receiver and
not also to `ticket`**, and pushes a snapshot success to watch the metric
appear.

`tests/alert-routing/run-tests.sh` covers the tree itself. The check
worth knowing about is that every alert in the rule file carries a
severity that has a route of its own: an alert with a misspelled
severity matches no route, falls through to the catch-all, and is never
paged for — and nothing else in this repository would notice. The suite
asserts that failure mode directly by asking `amtool` where
`severity=crticial` goes.

Which route matches a label set is put to `amtool` out of the pinned
Alertmanager image rather than modelled in the test, because a test that
reimplements the thing it is testing agrees with itself and nothing else.

## What is not covered

No vendor integration is exercised. The routing tree, grouping and
inhibition are tested; whether your PagerDuty key is correct is not
something this repository can tell you.

Inhibition is checked structurally — that each rule names alerts which
actually exist, so a typo cannot leave an inert rule that reads in review
as though the noise problem were handled. That both alerts firing at once
really does suppress the second is not exercised, because arranging two
specific alerts to overlap on a live cluster is a fixture problem rather
than a monitoring one.

The cloud profiles have no monitoring stack. `terraform/aws` and
`terraform/azure` build a Vault cluster; Prometheus, Alertmanager and the
exporters are local-profile only. The rule file is portable — it is
ordinary PromQL against standard Vault metrics — but nothing here
deploys it to a cloud environment.

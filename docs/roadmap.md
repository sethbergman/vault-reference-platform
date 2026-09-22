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
| v0.14 | Five cloud defects found and fixed without an apply: static pre-flight, and a real apply against an emulated AWS API |
| v0.15 | Remote, locked Terraform state; the autopilot default that walks an instance refresh out of quorum; quorum recovery and the root token, both closed without a cloud account |
| v0.16 | Audit anchors shipped to storage that refuses to delete them, on both clouds; key rotation and recovery rekey; a snapshot read back out of object storage and restored |
| v0.17 | Seal migration in both directions, and the unseal-key rekey — plus the key the local root of trust had been discarding, which made restarting one container unrecoverable |
| v0.18 | Rate limit quotas, and the three ways of setting one that write successfully and protect nothing — including the quota that refuses its own deletion |
| v0.19 | The path from a running cluster to a configured one, which had three breaks in it: three nodes arriving as one Ansible host, no way to reach any of them, and a certificate check no correct certificate could pass |
| v0.20 | The first real AWS apply: ten defects between an apply and a cluster, four of them in code no test here could reach — and the replacement node that cannot get a certificate, which keeps blocker 1 open |

## The honest gap

**`terraform/aws` has been applied to a real account once, on 2026-09-17.
`terraform/azure` never has.**

`terraform/aws` and `terraform/azure` are covered by `terraform test`
against mocked providers, and that catches more than it might sound like
— a Key Vault name exceeding Azure's 24-character limit, a Raft
`auto_join` configuration go-discover rejects outright, an IAM policy
granting delete on the snapshot bucket. But mocked providers do not
create anything, and a plan that succeeds is not a deployment that works.

`terraform/aws` is two steps further along. `tests/cloud-apply-emulated`
applies and destroys it on every PR against an implementation of the AWS
API, so the configuration is known to apply in one pass with every
request accepted — the shape of the profile, not its behaviour, because
an emulator boots nothing. Then one real apply, on 2026-09-17, observed
the behaviour: KMS auto-unseal, peer discovery by tag, health checks
keeping standbys in the pool, the Ansible handoff, and a snapshot
restored under the KMS seal. It also observed instance replacement
failing, and took ten defects to get that far.

So treat `terraform/aws` as proven in the parts
[cloud-apply.md](cloud-apply.md) names and unproven everywhere else —
snapshots to the bucket, PKI and audit on a real node, and an instance
refresh, none of which that session reached. Treat `terraform/azure` as
reviewed and tested, not as proven: it has no real apply and no emulated
one.

The local profile is different: `tests/integration` runs the operational
scripts against a real three-node Raft cluster on every PR, so the
snapshot, PKI and renewal paths are genuinely exercised.

## Next

### Off-host audit collection

Audit logs now survive the loss of the Vault node — the collector writes
to a volume with its own lifecycle, and the integration suite destroys
vault-0 outright to prove it.

The far end now exists. `scripts/ship-anchors.sh` writes each anchor to
an S3 bucket under a COMPLIANCE object-lock retention that nothing can
shorten or remove, and `terraform/aws/audit-anchors` builds that bucket
as a root module of its own — for the reason `terraform/aws/bootstrap` is
one, that a `terraform destroy` of the cluster must not be able to delete
the record of what the cluster did. `tests/audit-anchor-worm` applies it
against an emulated AWS API and then attacks the anchors it shipped.

Building it turned up the thing worth reporting here, which is that
"object lock" covers less than the name suggests:

| Attack | S3 | What stops it |
|---|---|---|
| Delete the version | refused | the lock |
| Overwrite the key | permitted — a new version | `--fetch` reads the version shipped first |
| Delete with no version id | permitted — a delete marker | the IAM policy, and `--fetch` reading past it |

A delete marker destroys nothing, so the lock permits it, and a marked
key is absent from `list-objects-v2` and 404s on `head-object`. The
credential that ships anchors can therefore hide every one of them
without deleting a byte — and the first draft of the shipper, built on
those two calls, would have reported *no anchors found*, which reads as
"nothing was ever anchored" precisely when it means the opposite. Both
paths list versions now, and the suite asserts that the emulator really
does permit the marker, so the guard is exercised rather than sitting
behind a refusal.

`terraform/azure/audit-anchors` is the counterpart, added in v0.16 so
the anchor story is not AWS-only: an immutability policy in `Locked`
state is Azure's `COMPLIANCE`, and the role definition excludes the blob
delete actions the way the IAM policy denies `s3:DeleteObject`. Nothing
ships anchors there yet — `ship-anchors.sh` speaks the S3 API — and there
is no Azure emulator this repository can run
([why](cloud-apply.md#why-azure-has-no-emulated-apply)), so it has been
validated and never applied. It is configuration with reasoning
attached, like every other Azure resource here.

Two halves remain, and they are different sizes.

The collector still runs on the Vault host. Shipping moves the evidence
out of reach, not the collection of it: a compromise there can stop the
collector, and an entry never collected is never chained and never
anchored. Nothing about the destination recovers those, so what is
durable is the trail *up to* the compromise. Moving the collector is
still the one-line `--second-address` change, and demonstrating it needs
a second host.

And nothing here has run against a real account. The emulator shows the
requests are built and answered as the design assumes; it does not show
that S3 enforces COMPLIANCE retention, that the IAM policy is the one AWS
evaluates, or that a bucket in a *second account* — the arrangement that
makes any of this a real separation rather than a careful one — is
reachable by the credential that would need to reach it.

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
in production.

The first two blockers are the two cloud profiles, listed separately
because they are separate risks rather than one job done twice. Proving
AWS works says nothing about whether Azure does: the profiles differ in
mechanism, not only in commands, and the mechanisms are where the risk
sits.

The preparation they share has shipped.
[`scripts/preflight-cloud.sh`](../scripts/preflight-cloud.sh) checks what
can be checked without spending anything,
[`scripts/teardown-cloud.sh`](../scripts/teardown-cloud.sh) removes what
`terraform destroy` cannot, and [`cloud-apply.md`](cloud-apply.md) lists
the claims an apply would settle. That preparation is *not* the item.
Nothing in it constitutes evidence; it exists so that whoever spends the
money gets a full set of answers from one session instead of half of
them.

`tests/cloud-apply-emulated` is the one piece of that preparation that
does constitute evidence, and only for AWS: the profile applies and
destroys against an implementation of the AWS API, so a session that
spends real money no longer spends it discovering a reference that does
not resolve or a value the API refuses. It removes the cheap failures
from the list below. It removes none of the items themselves — every one
of them is about what happens after something boots.

The blockers are, in order:

1. **A real AWS apply.** Done once, on 2026-09-17, and **still open**.
   Three of its four questions are settled and the fourth is settled in
   the wrong direction:

   - **The KMS triangle.** Settled. The instance profile, the key policy
     and the `seal "awskms"` stanza agree: all three nodes reported
     `Seal Type awskms` and `Sealed false`, with the node role's
     `Decrypt` calls in CloudTrail. Getting there needed two key
     *policies* nobody had written — the autoscaling service-linked role
     could not use the volume key, and CloudWatch Logs could not use the
     seal key, so no instance survived launch and the apply ended
     partway.
   - **`auto_join` in tag mode.** Settled, against real EC2 tags: three
     voters, autopilot healthy. The nodes could not reach each other
     until the security group let them send to their own members —
     discovery worked long before the network did.
   - **The profile whose default apply is broken.** Settled: the
     pre-flight now reads the variable an apply would use, so an empty
     `ssh_key_name` is caught before anything bills.
   - **Auto Scaling group replacement.** Settled as **broken**, and this
     is why the blocker stays open. The group replaced a terminated
     leader in 75 seconds and the replacement never started Vault: its
     certificates arrive only through an Ansible run, named after an
     instance id that did not exist until the launch. Recovery is now two
     commands rather than improvisation —
     `generate-cloud-certs.sh --add-missing` signs one leaf from the CA
     the cluster already trusts, then the playbook runs `--limit` that
     host — and it is still two commands somebody has to run. See
     [cloud-apply.md](cloud-apply.md#the-cluster-is-not-self-healing).

     Unattended recovery is now built: a replacement signs its own leaf
     at boot from the bootstrap CA published to SSM, with the SANs its
     peers carry (`scripts/issue-bootstrap-cert.sh`; the tradeoff is in
     [security.md](security.md#a-node-the-autoscaling-group-replaces)).
     It is tested with shims and real `openssl` and asserted in
     `terraform test`, and it has not been watched on a real node. The
     blocker closes when item 10 is run again and the replacement joins
     with nobody touching it — which is also what item 5's instance
     refresh was waiting for.

   What that session did not reach: snapshots to the bucket, PKI
   certificates and audit devices on a real node, and the refresh. Those
   need a cluster standing again, and the roles are off by default.
2. **A real Azure apply.** `terraform/azure` has never been applied
   either, and it is not item 1 with different commands:

   - **Discovery is scale-set mode, not tag mode.** go-discover's Azure
     provider rejects a mix of `tag_name`/`tag_value` and
     `resource_group`, so `retry_join` matches on resource group plus
     scale set name. That is the one discovery path nothing else here
     uses, and it is where a real bug was already found — by reading the
     provider source, because every test had been written from the same
     assumption as the code. It also requires Uniform orchestration; a
     Flexible scale set discovers nothing and says so nowhere.
   - **So the inventory and the cluster fail independently.** On AWS one
     tag drives both. Here the inventory filters `VaultCluster` and
     discovery never looks at tags, so a working cluster is no longer
     evidence the inventory works, and an empty inventory is no evidence
     the cluster is broken. Two things to check rather than one.
   - **A probe with no status-code matcher.** Azure probes accept
     200-299 and nothing else, so standbys stay in the pool only because
     `standbyok=true` makes Vault answer 200. The AWS profile carries a
     `200,429` matcher as a second line of defence; here there is none.
   - **Reconciliation, not replacement.** Deleting an instance is
     answered by the scale set restoring `instances = node_count`, under
     `zone_balance = true` — Azure may refuse to place the replacement
     rather than place it badly — and `automatic_instance_repair` has a
     30-minute grace period, so the timing is not the ASG's either.
   - **Two authorization models in one profile.** The seal reaches Key
     Vault through an access policy; snapshots reach blob storage
     through an RBAC role assignment, against an account with
     `shared_access_key_enabled = false`. Either can be wrong on its
     own, and neither has been exercised.
   - **Repeating it is not free.** Purge protection cannot be turned
     off, so each apply leaves a soft-deleted Key Vault for 90 days,
     against AWS's cancellable 7-day KMS window. Worth knowing before
     the fourth attempt rather than after.
3. **Off-host audit collection**, so a compromised host cannot reach the
   evidence. The trail now outlives the node, an edit to it is
   detectable, and the anchors that make it detectable now leave the
   machine: `scripts/ship-anchors.sh` writes each one to an object-lock
   bucket built by `terraform/aws/audit-anchors`, where a COMPLIANCE
   retention refuses every credential this repository uses.
   `tests/audit-anchor-worm` ships real anchors into that bucket and
   attacks them three ways, including the two the lock does not
   refuse — an overwrite, and a delete marker that hides every anchor
   without destroying one.

   What is left is not the same shape as what closed. The collector
   itself still runs on the Vault host, so an attacker there can stop it,
   and an entry never collected is never anchored — shipping makes the
   trail durable up to a compromise, not past it. That half needs a
   second host. And the locked bucket has only ever been built against an
   emulated AWS API, so the separation that would matter most, a second
   *account*, is configured and unproven.
4. **Terraform state that survives a team.** Both profiles now declare a
   `backend`, and the ordering it depends on is a second root module per
   provider — `terraform/{aws,azure}/bootstrap` — which creates the
   bucket or storage account, keeps local state of its own, and emits the
   matching `backend.hcl`. `tests/state-backend` applies the AWS half
   against an emulated AWS API on every PR and checks the properties that
   make the arrangement worth having: that `init` against a bucket which
   does not exist is refused rather than quietly creating an empty state,
   that state lands in the bucket and not on disk, and that a second
   apply is turned away while the first holds the lock. CI's
   `-backend=false` still runs `validate` with no credentials, which is
   asserted rather than assumed.

   The AWS half has now been pointed at a real account, by the
   2026-09-17 session: `terraform/aws/bootstrap` applied in one pass,
   the generated `backend.hcl` initialised the profile against the
   bucket it had just built, and every plan, apply and destroy that
   followed kept its state there rather than on disk. The bucket is the
   one thing that session deliberately left behind.

   What is left is narrower than it was. Nothing shows that two applies
   from two machines race the way one process planting a lock file does,
   or that a least-privilege identity can reach the bucket at all — that
   session ran as an administrator, which answers the question in the
   easiest possible way. And the Azure side is untouched: the Entra role
   assignment has never been granted to a second person, and the Azure
   bootstrap module has never been applied to anything, because moto is
   an AWS API and there is no emulator for the other side this
   repository can run
   ([why](cloud-apply.md#why-azure-has-no-emulated-apply)).

   So this item is half proven, and closes with blocker 2. See
   [terraform-state.md](terraform-state.md).
5. **An upgrade path that matches how the profiles actually deploy.**
   `scripts/vault-upgrade.sh` steps the leader down, swaps the binary
   over SSH, and waits for health before touching the next node. Nothing
   in either cloud profile is upgraded that way. `terraform/aws`
   installs a pinned `vault_version` from user-data at boot and carries
   `instance_refresh` on the scaling group; `terraform/azure` is a scale
   set with `upgrade_mode = "Manual"`.

   So on AWS the upgrade an operator would actually perform — bump the
   version, apply — replaces nodes through a mechanism that knows
   nothing about Raft leadership or quorum, and the leader-aware script
   does not run. On Azure, nothing replaces them at all until someone
   says so. Two upgrade models, one of them tested, and the tested one
   is not the one the cloud profiles reach for.

   The first half is now settled, and the answer to the second half was
   no. [rolling-upgrades.md](rolling-upgrades.md) names the canonical
   model per profile: instance refresh on AWS, because the version is
   installed from user-data and there is no binary to swap; the script on
   Azure, because its scale set replaces nothing until told to; the
   script anywhere the machines outlive the upgrade.

   `min_healthy_percentage` is *not* enough, and the reason is not a
   tuning question. Vault ships autopilot with
   `cleanup_dead_servers = false`, so a replaced node stays a voter — and
   because both cloud profiles derive `node_id` from the machine, every
   replacement adds a voter and leaves the old one behind. A three-node
   refresh then loses quorum partway through the *second* node. The ASG
   counts instances it can see; Raft counts voters it cannot. That is why
   the setting looks sufficient.

   [`scripts/configure-autopilot.sh`](../scripts/configure-autopilot.sh)
   fixes it, with `min_quorum` as the safety rather than the threshold:
   nothing is pruned until a replacement has joined. `tests/autopilot`
   covers the script, `tests/integration` asserts the live configuration
   on every PR — including that Vault still ships the default this is
   built around, so an upstream change breaks a test rather than the
   argument.

   What remains is a real refresh. No ASG has ever run against this
   configuration, and a dead voter has never been watched being pruned:
   that needs a fourth voter, which the local profile cannot produce.
   So this closes with blocker 1, not before it.

Both are additions to this list rather than discoveries about the
existing three, and when they were added this paragraph said neither was
reachable by an emulated apply — that state backends and node
replacement are questions about operating a cluster over time, and an
emulator has no time in it.

Half of that was wrong, and finding out cost nothing. Item 5 is as
described: an instance refresh replacing a leader is a question about
what happens over minutes, and moto has no minutes in it. Item 4 was
not. The durability half — does the bucket survive, do two people
racing corrupt each other — is indeed unreachable. But the *ordering*
half is a question about what a command does when a bucket is missing,
and an emulator answers that as well as an account does. The sentence
generalised from one item to two on the strength of them arriving
together.

## After v1.0: production operations

Everything here is a day-2 operation with a failure mode worth naming,
and none of it is exercised. It sits after v1.0 rather than before it
because each item is a procedure a running cluster needs eventually,
not a property the architecture has to have on the day it is stood up.

- **Monitoring on the cloud profiles.** The rule set, the routing tree
  and the `absent()` pairs exist and are tested — in the local profile
  only. Nothing deploys them alongside `terraform/aws` or
  `terraform/azure`, so a cloud cluster runs with the alerting story
  written down and not running. The rules are ordinary PromQL against
  standard Vault metrics and would port directly; what is missing is
  somewhere to port them to, and a decision about whether this
  repository ships a Prometheus or documents integrating with one.
- **Seal migration between cloud providers, and a Shamir rekey.** The
  local half of this came off the list after v0.16.
  `scripts/migrate-seal.sh` moves a cluster between Transit auto-unseal
  and Shamir in both directions, and `tests/seal-migration` runs both
  against a real cluster — checking that a secret written beforehand
  survives, that the migration finalises rather than being left in
  progress, and that a restarted node genuinely unseals itself
  afterwards.

  Four things about the procedure turned out not to match the obvious
  reading of it, and are written up in `docs/auto-unseal.md`: stopping
  the standbys costs quorum and the migration then never finalises; every
  node needs `-migrate`, not just the active one; `migration` stays true
  until a leader finalises it; and a node restarted inside that window
  will not auto-unseal even with a working seal stanza, which makes the
  obvious way to verify the migration the thing that breaks it.

  The Shamir rekey came off this list too. `rotate-keys.sh
  --unseal-keys` runs the same ceremony against `sys/rekey` rather than
  `sys/rekey-recovery-key`, and `tests/key-rotation` exercises it against
  `vault-unseal` — rekeying it from the 1-of-1 the bootstrap creates to
  5-of-3, then again, and requiring that a full quorum of the superseded
  generation no longer opens it. One share proves nothing there: Vault
  accepts shares and only validates the combination at the threshold, so
  a lone stale share returns success.

  That work needed a prior fix, the same shape as the recovery keys in
  v0.15. `vault-unseal` is the root of trust for the whole local profile
  and its unseal key lived only in a shell variable, so a restart of that
  one container ended the cluster — it came back sealed with nobody
  holding the key, and cluster nodes restarted afterwards failed to start
  rather than coming back sealed. The keys are kept now, and the suite
  restarts `vault-unseal` on every run to prove it.

  What remains needs something this repository does not have: migrating
  between two *cloud* KMS providers, the case where an organisation
  changes cloud, which has the same shape and no coverage.
- **Restore verification at a real cloud destination.** The mechanism
  came off this list in v0.16. `tests/restore-from-object-store` puts a
  real snapshot of a real cluster through an S3 API, reads the object
  back, inspects it, restores it, and then checks both halves — that
  what was written before the snapshot returns, and that what was
  written after it is gone, which is what separates a restore from a
  no-op.
  The API is an emulator, so what is still unproven is everything about
  an account: that the instance role reaches the bucket, that
  server-side encryption leaves the object restorable, and that a
  multipart upload of a much larger snapshot behaves the same.
- **Login MFA**, an application-facing transit engine, further database
  engines, and a cloud-provisioned database for the secrets engine to
  point at. Feature breadth rather than operational risk, which is why
  they are last.

Rate limit quotas came off that list. `scripts/bootstrap-quotas.sh`
configures them and `tests/quotas` exercises the result against a real
cluster, which turned out to matter more than the feature: two of the
three ways to configure a quota look like they worked and did not, and
one of them locks you out of undoing it.

`sys/quotas/config` replaces rather than merges, so writing any single
field silently empties the seven exempt paths Vault ships — `sys/health`
among them. `rate_limit_exempt_paths` is a list, and the CLI's `k=v` form
turns `"a,b"` into one element containing a comma, which matches nothing
and writes successfully. And `sys/quotas/*` is not exempt by default, so
a quota set too low answers 429 to the DELETE that would remove it; the
way out is to send nothing for a full interval and spend the first
request of the new window on the delete. See `docs/rate-limiting.md`.

Two items came off this list without spending anything, which is worth
noting because the list was written as though a cloud account were the
constraint. It was not; the constraint was that nobody had tried.

**Quorum loss recovery** turned out to be a correction as much as an
addition. `docs/disaster-recovery.md` sent a lost majority to a snapshot
restore, which works and silently discards everything written since that
snapshot — to fix a failure where the survivor still holds every
committed write. `peers.json` keeps it. The old warning against editing
the Raft log stands; `peers.json` is not that. `tests/quorum-recovery`
runs the whole sequence on every PR, and found on the way that a
quorum-less node answers the load balancer's health check with 200 while
returning 500 to everything else.

**The root token** could not have been documented without a prior fix:
`bootstrap-dev-cluster.sh` discarded the recovery keys, so revoking root
was a one-way door and the advice would have been destructive to whoever
took it. The keys are kept now, `revoke-root-token.sh` refuses without a
working non-root token to prove there is still a way in, and
`generate-root-token.sh` mints a replacement from a quorum of shares.
`tests/root-token` proves the lifecycle end to end.

Dynamic secrets, alerting, audit devices and the PKI migration path have
all moved off this list. The database
engine is tested against a real Postgres; the alert rules are unit-tested
with promtool and observed firing end to end against a live cluster.

Explicitly *not* planned: Vault Enterprise features (performance
replication, DR replication, namespaces, HSM auto-unseal). They would
make the reference untestable for most readers, and the open-source
feature set is enough to demonstrate the architecture.

Also not planned: Kubernetes. The Agent Injector is a different
deployment model with its own failure modes, and this repository targets
the sidecar-on-a-VM shape throughout — see
[vault-agent.md](vault-agent.md). Adding it would mean a second
architecture rather than a feature.

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

A third habit joined them when the Azure mutation table was run for the
first time. The table listed thirteen deliberate breaks and the run each
should catch, and its own heading said none of the rows had ever been
executed. Running all thirteen — plus one mutation for every run the
table did not list, 36 in total — found six assertions that stayed green
through the break they named.

Two of them could not have failed at all. One re-derived
`substr(cluster_name, 0, 15)` inside the test and asserted
`15 + 1 + 8 <= 24`, which `substr` guarantees regardless of what the
module does; widening the module's own budget to 20 left it green. The
other asserted `soft_delete_retention_days >= 7`, which is the azurerm
provider's own floor, so no value it accepts could break it. The rest
watched the wrong object: a variable's default rather than the security
rule built from it, one allow rule rather than all three, a scale-set
discovery string missing half its selector.

That table is now verified row by row, and
[`terraform/azure/tests/README.md`](../terraform/azure/tests/README.md)
records what each mutation did rather than what it was expected to do.
The suite runs in about two seconds, which is the uncomfortable part.
Nothing but the writing stood between the unverified table and the
verified one — no credentials, no cluster, no cost — and it still shipped
in v0.14 as a list of intentions.

A fourth arrived with the quorum and root-token work, and it is the one
that needed no mutation to find because it could not have failed at all.

`revoke-root-token.sh` refuses to retire the root token unless handed a
working non-root token first — the guard against locking yourself out of
a cluster. It proved that token "can administer anything" by running
`vault read sys/health`.

`sys/health` is unauthenticated. This repository's own
`bootstrap-dev-cluster.sh` polls it with plain `curl` and no token at
all, and has for as long as it has existed. So the check answered for an
expired token, a revoked one, or one entitled to nothing, and passed in
exactly the cases where the `token lookup` before it already had. It was
not a weak check; it was not a check.

The suite did not catch it because every run supplied a token that
genuinely had policies, so the assertion held — for a reason unrelated to
what it claimed. The mutation that would have exposed it is a token
carrying only `default`: it authenticates, it passes `lookup-self`,
`sys/health` answers it, and it can do nothing.

The three earlier entries are all about a *test* that fails to
discriminate. This one is about a test that asks the wrong service. The
question that finds it is the same in every case and worth stating on its
own: **what would have to break for this assertion to fail?** If the
answer is "nothing", the assertion is decoration, and it is decoration
standing exactly where a reader will assume there is a guard.

Writing the replacement produced a small version of the same lesson. The
new assertion creates a token with only the `default` policy — except
`vault token create` from a root token inherits the parent's policies, so
the first attempt made another root token, which the check above it
refused. The assertion failed, correctly, because it greps the specific
refusal rather than checking the exit code. Had it only checked that the
script exited non-zero, it would have gone green while testing nothing.

A fifth is not about an assertion at all, which is why it survived four
releases.

The Roadmap section of the README opened "Everything through v0.14 has
shipped". v0.18 had. Four PRs each added a row to the Shipped table at
the top of this file and left that sentence alone — and it is the first
claim a reader meets, in the one section whose entire purpose is to say
what is done and what is not.

Nothing caught it because nothing was looking. `tests/docs-index` checks
that every file in `docs/` is linked from the generated index and skips
`README.md` by name; markdownlint has opinions about the line and none
about the fact on it. The question above still finds it, but only when
asked of the claim rather than of the test: what would have to break for
that sentence to fail? Nothing could. There was no weak assertion here —
there was no assertion.

So this is the argument for generating `docs/README.md`, arriving a
second time somewhere too small to generate. One sentence does not earn a
generator, so it is asserted instead.
[`tests/lint/check_version_claim.py`](../tests/lint/check_version_claim.py)
requires the README to name the newest row of the table above, and
requires that row to be no older than the newest git tag. The tag half is
one-directional on purpose: a release lands its roadmap row in a PR and
is tagged after that merges, so gating the README on tags would fail the
PR for being correct, while a table *behind* the tags is a release nobody
wrote down. Six mutations were watched to fail, including the one the
README half cannot see — deleting the v0.18 row while v0.18 is tagged.

The four earlier entries share a shape: a test existed and was weaker
than it looked. This one is different in a way worth separating, because
the fix is different. The table above was right the whole time; what
drifted was a hand-written summary of it. A weak assertion gets widened.
An unchecked claim gets tied to whatever is already correct.

A sixth came from none of the above. Nothing was asserted weakly and
nothing had drifted; three defects were found by writing down the
sequence someone would actually run, in order, and asking of each step
what it needed that nothing provided.

The occasion was staging the first real AWS apply — the preparation for
blocker 1, which is meant to be so complete that the session spends its
money on questions only a real account can answer. All the preparation
described above already existed: `preflight-cloud.sh`, `teardown-cloud.sh`
and a ten-item verification checklist in
[cloud-apply.md](cloud-apply.md). None of it caught these, because all of
it is about what to check once a cluster is up. None of it asks whether
the path to getting there is continuous.

| What | Why nothing saw it |
|---|---|
| An autoscaling group tags every instance identically, and `inventory/aws_ec2.yml` preferred `tag:Name`. An Ansible inventory is keyed by host name, so three nodes collapsed into one and `site.yml` configured a single node and exited 0 | Terraform sets the tags and is tested; the inventory filters on them and was tested as valid YAML. Neither asks whether the inventory can tell two instances apart |
| Nothing could reach the nodes at all. Private subnets, no inbound 22, and the documented sequence ends in `ansible-playbook`. `docs/deployment.md` said reaching them "needs SSM, a bastion, or a VPN" and the repository shipped none of the three. `ansible_user` was never set either | Both sides were tested. `security.tf` was tested for what it refuses, the playbook for what it renders, and nothing tested that one could reach the other |
| The vault role verified a delivered certificate with `openssl -checkhost` against an IP address, which reports "does NOT match" for every certificate this repository issues — `issue-node-cert.sh` and the `vault_pki` role both put the address in `--ip-sans`. A correct certificate failed; only a wrong one passed | It had never executed. The local profile is Docker Compose and does not use this role, and neither cloud profile has been applied |

The first is the one worth dwelling on, because
[`tests/preflight-static`](../tests/preflight-static/run-tests.sh) exists
for precisely this seam and did not catch it. That suite was written
around two strings produced by one layer and consumed strictly by
another — an `auto_join` selector and a `leader_tls_servername` — and it
checks those two. Host naming is the same shape and nobody had thought of
it. A suite aimed at a class of defect still only covers the instances
someone wrote down.

It was also invisible to `tests/cloud-apply-emulated`, which applies the
whole AWS profile against a real implementation of the AWS API. The
emulator has no Ansible in it. That is the distinction that section
already draws, arriving as a concrete example: a profile that applies is
not a cluster that configures.

All three now have assertions, and the second and third needed code
before they could have any — `ansible/inventory/aws_ec2.yml` tunnels SSH
through Session Manager, and `scripts/generate-cloud-certs.sh` issues the
bootstrap material after the apply, because the filenames follow
instance ids that do not exist until then.

Two things this does not mean. It does not mean the profile works: three
known defects became zero known defects, which is a statement about what
has been looked at and not about what is there. And it does not mean the
apply is cheaper than the blocker list claims — every item on that list
is still a question about runtime behaviour, and none of these three was.
What it means is that the session will now fail on those questions rather
than on a missing SSH key, which is the entire purpose of the
preparation.

The cost asymmetry is the part worth keeping. Finding these took an
afternoon and no money. Two of the three would have surfaced during the
apply disguised as something else: a cluster that came up healthy and was
one-third configured, and a Raft join failure that reads like a network
problem. The question that found them is a variant of the one above,
asked of a procedure instead of an assertion: **what does this step need
that nothing here provides?**

None of this changes what the table above claims. It changes how much the
word "tested" in it is worth, which seemed worth writing down.

### And then the apply happened

v0.19 staged the AWS apply and found three defects without spending
anything. v0.20 ran it, on 2026-09-17, and found ten more. The account
was a sandbox, the cluster was three `t3.small` nodes across two zones,
and the whole session cost under a dollar — which is the part to keep in
mind while reading the list, because every one of these had been in the
repository for releases.

| # | Defect | Why nothing here saw it |
|---|---|---|
| 1 | `preflight-cloud.sh` read `ssh_key_name` only from `variables.tf`, while the documented apply passed it with `-var` — so the check that exists to catch a missing key pair warned about an empty name on every correct run and never looked the pair up | The shim suite set the default and asserted on the warning. It tested the code's own assumption |
| 2 | In the documented order the pre-flight's `terraform plan` never ran at all: the plan needs an initialised backend, the backend needs the bucket the bootstrap module creates, and the pre-flight came before both | Nothing tests the order a document tells a human to work in |
| 3 | The volume key had no key policy, so the autoscaling group's service-linked role could not generate a data key. Twelve instances launched and terminated; AWS reported `InvalidKMSKey.InvalidState` about a key that was `Enabled` | moto does not enforce key policies, and the mocks assert on configuration. Both said yes |
| 4 | The seal key had the same gap for CloudWatch Logs, which denied `CreateLogGroup`. **This is the error that ended the apply partway**, leaving no flow logs and a tainted ASG | As above. A key with no policy looks identical to a key with a correct one until a service principal asks |
| 5 | The node security group admitted peers on 8200 and 8201 and allowed egress only on 80 and 443, so no node could open a connection to another. Discovery worked; every Raft join timed out at TCP connect | `terraform test` asserted egress was "limited to HTTPS and HTTP". The assertion passed, and described the bug |
| 6 | `amazon.aws.aws_ec2` rejects any file not named `*aws_ec2.yml`, unread. The inventory was `aws.yml`, so every documented `ansible-playbook` command configured no hosts | Every assertion read the file — valid YAML, right tag, rendered compose values. None asked a plugin to open it |
| 7 | `ansible-playbook` does not read `ansible/group_vars/`, only directories beside the inventory or the playbook. The nodes would have got the role default, a **Shamir seal**, from a run reporting success | Ad-hoc `ansible` *does* read it from that directory, which is what made it look correct. The tests read the generated file directly |
| 8 | The role asked dnf for `vault=1.17.2`, which is apt's syntax; the task failed on every node with `vault-1.17.2-1` already installed | The role had never run against a VM. The local profile is containers |
| 9 | The role's TLS sources were relative paths Ansible searches for in two directories, neither of which is where `generate-cloud-certs.sh` writes | Same reason. The paths were only ever read, never resolved |
| 10 | The playbook's own diff showed it **removing** `leader_tls_servername` and both `telemetry` blocks that cloud-init sets. Nothing failed: joins fell back to verifying an IP, and `/v1/sys/metrics` stopped serving Prometheus data | Two writers configure one file and nothing compared them. `tests/preflight-static` compares the cloud templates to the PKI role, and stops there |

Four of those — 3, 4, 5 and 10 — are in code no test in this repository
could have reached, which is what blocker 1 was for. Two more, 1 and 5,
had passing assertions describing them: the pre-flight's shim set the
value the script would read, and the egress test said "limited to HTTPS
and HTTP" about a group that could not talk to itself. That is the
failure mode this file already warns about, found twice more in one
afternoon.

The eleventh was in a test rather than in the code. `tests/agent` named
each scenario's workspace `creds.$RANDOM`, two scenarios eventually drew
the same number, and an assertion that a file is *absent* after a failed
run found one an earlier passing scenario had written. It failed once in
CI, passed locally, and would ordinarily have been re-run and forgotten
as flaky. Pointing every scenario at one directory reproduces it exactly;
`mktemp -d` fixes it. Two other suites named their workspaces the same
way.

What the session did not settle is as much the point. Snapshots to the
bucket, PKI and audit on a real node, and an instance refresh were never
reached; the teardown never exercised its `BucketNotEmpty` path, because
no snapshot had been written. And the headline finding is a gap rather
than a defect: **a replacement node cannot get a certificate without a
person**, so the self-healing claim the architecture rests on is false
today. Blocker 1 stays open for that reason, and the next step is a way
to issue one node's certificate from the CA already on disk —
`generate-cloud-certs.sh` keeps that CA key for exactly this case and
offers no way to use it.

# Azure infrastructure tests

Run with:

```bash
cd terraform/azure
terraform test
```

No Azure credentials required, and nothing is created — every provider
is mocked (`tests/mocks/azure/`). 25 runs, 45 assertions.

## What these do and don't prove

They assert on the **configuration's semantics**: that the scale set is
pinned rather than autoscaling, that the health probe passes
`standbyok=true` so standby nodes stay in the pool, that the Key Vault
holding the unseal key cannot be purged, that the snapshot account
refuses a shared key.

`terraform validate` cannot see any of that. Validate is happy with a
probe that TCP-checks a port, or a Key Vault name that exceeds Azure's
24-character limit — a constraint on the *value*, not the schema, which
therefore fails at apply.

What they do **not** prove is that Azure accepts the result. Mocked
providers don't enforce quotas, RBAC evaluation, or service-specific
rules, and no instance ever boots. **A real `terraform apply` in a
scratch subscription is still the only thing that demonstrates this
works** — see [`docs/cloud-apply.md`](../../../docs/cloud-apply.md).

## Why Azure gets its own tests rather than a copy of the AWS ones

Three mechanisms here have no AWS counterpart, and they are the reason
the Azure apply is a separate v1.0 blocker rather than the same job
twice:

| Mechanism | AWS equivalent | Covered by |
|---|---|---|
| Raft discovery enumerates a scale set | tag-filtered `auto_join` | `raft_discovery_uses_scale_set_mode_not_tags` |
| Health probe has no status-code matcher | target group `matcher = "200,429,472,473"` | `health_probe_keeps_standby_nodes_in_the_pool` |
| A lost instance is reconciled, not replaced | ASG terminates and launches | `unhealthy_nodes_are_repaired_not_just_stopped_ones` |

The first is where mocked tests already caught a real bug. The module
shipped `auto_join` carrying **both** a tag selector and scale-set mode;
go-discover rejects that combination outright with "unclear
configuration". Vault would have started on every node, reported
healthy, and never formed a cluster — the failure is a line in one
node's log, not anything the infrastructure surfaces.

## Beware of vacuous assertions

Anything a mock supplies is not evidence. This is the trap that bit the
AWS suite, where an assertion read the rendered JSON of a mocked
`aws_iam_policy_document` and passed happily with `s3:DeleteObject`
injected into the real one. See
[`../../aws/tests/README.md`](../../aws/tests/README.md).

`tests/mocks/azure/main.tfmock.hcl` deliberately supplies **only**
resource IDs, the two identity principal GUIDs, one public IP address,
and the `azurerm_client_config` GUIDs — values the provider validates
the shape of, which have to look real for a plan to resolve at all.
Every other attribute an assertion reads comes from the configuration.

Cross-checking the mock against all 45 assertions, two read something
the mock file mentions, and the mutation table below says what each is
worth:

- `azurerm_linux_virtual_machine_scale_set.vault.identity[0].type` is
  not actually mocked. That resource has no `mock_resource` block, and
  `type = "UserAssigned"` is set in `compute.tf`, so it is a
  configuration value. Changing it to `SystemAssigned` fails the run
  that reads it.
- `repair_watches_vault_rather_than_the_vm` compares
  `health_probe_id` against `azurerm_lb_probe.vault.id`, and **both
  sides are mocked IDs.** It is deliberate and its claim is narrow: it
  proves the scale set references the probe resource, and nothing about
  the probe. Every mocked resource type here has a distinct ID, so
  detaching the probe or pointing it at another resource both fail it —
  which is the whole of what a wiring assertion can settle.

Re-check this when adding an assertion: assert on config values and
locals, and treat any assertion that reads back an `id`, a
`principal_id` or an `ip_address` as suspect until you have watched it
fail.

## The mutation table

Every row below was run: the mutation applied, `terraform test` watched
to fail on the named run, the mutation reverted. Verified 2026-09-01
against Terraform v1.15.8 and the mocked `hashicorp/azurerm` provider.
Running the suite needs the provider, so the table cannot be re-verified
anywhere the Terraform registry is unreachable:

```bash
cd terraform/azure && terraform init -backend=false && terraform test
```

The whole suite is about two seconds, which is worth knowing: re-running
the table after adding an assertion costs less than reasoning about
whether you need to. Per
[`CONTRIBUTING.md`](../../../CONTRIBUTING.md), mutate with something the
assertion does not name — dropping `standbyok=true` is the change the
assertion greps for, whereas reordering the probe's query parameters is
the neighbouring one a contributor actually makes.

| Mutation | Caught by |
|---|---|
| `instances` hardcoded to `3`, which matches the default | `five_nodes_are_accepted` |
| `instances = var.node_count + 1` | `scale_set_is_pinned_and_does_not_autoscale` |
| `zones = ["1"]` set on the resource | `nodes_are_spread_across_availability_zones` |
| `zone_balance` disabled | `nodes_are_spread_across_availability_zones` |
| Repair grace period shortened to `PT11M` | `unhealthy_nodes_are_repaired_not_just_stopped_ones` |
| `automatic_instance_repair` disabled | `unhealthy_nodes_are_repaired_not_just_stopped_ones` |
| `health_probe_id` deleted from the scale set | `repair_watches_vault_rather_than_the_vm` |
| Probe protocol switched to `Tcp` | `health_probe_keeps_standby_nodes_in_the_pool` |
| Probe query parameters reordered, same meaning to Vault | `health_probe_keeps_standby_nodes_in_the_pool` |
| Load balancer SKU set to `Basic` | `tls_terminates_at_vault_not_the_load_balancer` |
| LB rule switched off TCP passthrough | `tls_terminates_at_vault_not_the_load_balancer` |
| A `tag_name=` selector reintroduced into `auto_join` | `raft_discovery_uses_scale_set_mode_not_tags` |
| `resource_group=` dropped from `auto_join` | `raft_discovery_uses_scale_set_mode_not_tags` |
| Scale set renamed independently of the local | `the_scale_set_name_matches_what_discovery_looks_for` |
| Purge protection disabled | `the_autounseal_key_cannot_be_purged` |
| Soft-delete retention shortened to 7 days | `the_autounseal_key_cannot_be_purged` |
| The 15-char Key Vault prefix budget widened to 20 | `the_key_vault_name_fits_azures_limit` |
| `allowed_cidr_blocks` defaulted to `0.0.0.0/0` | `vault_api_is_not_reachable_from_the_whole_internet` |
| The API rule's source replaced with `"Internet"`, variable untouched | `vault_api_is_not_reachable_from_the_whole_internet` |
| The catch-all deny rule moved to priority 105 | `the_security_group_denies_what_it_does_not_allow` |
| Shared key access re-enabled on the storage account | `snapshots_are_not_reachable_with_a_shared_key` |
| Storage network default action set to `Allow` | `snapshots_are_not_reachable_with_a_shared_key` |
| Blob versioning disabled | `snapshots_survive_an_overwrite` |
| The `VaultCluster` tag renamed | `cluster_tag_matches_what_raft_auto_join_searches_for` |
| Password authentication re-enabled | `nodes_authenticate_with_a_managed_identity_not_a_password` |
| Identity switched to `SystemAssigned` | `nodes_authenticate_with_a_managed_identity_not_a_password` |
| `node_count` validation relaxed to `>= 1` | `even_node_counts_are_rejected` |
| Zone-count validation relaxed to `>= 1` | `a_single_availability_zone_is_rejected` |
| Key Vault network default action set to `Allow` | `the_key_vault_denies_by_default` |
| Public IP `count` pinned to 0 | `a_public_frontend_requires_asking_for_one` |
| Raft source widened from the node subnet to the whole VNet | `raft_traffic_is_confined_to_the_node_subnet` |
| `min_tls_version` lowered to `TLS1_0` | `storage_requires_modern_tls` |
| Flow log retention disabled | `flow_logs_are_enabled` |

### Three mutations the provider rejects before any assertion runs

`grace_period = "PT5M"`, `soft_delete_retention_days = 3` and an NSG
`priority` of 90 are all refused by the azurerm provider's own schema
validation — mocked providers still validate, they only stop short of
creating anything. Two things follow.

The first is a reading hazard. A schema error fails the **first run in
each file** and skips every run after it, so all three of these report
as `scale_set_is_pinned_and_does_not_autoscale` and
`the_autounseal_key_cannot_be_purged` failing, whichever file the
mutation was in. A failure naming a run you did not touch is usually
this, and the error text names the real line.

The second is that an assertion sitting at a bound the provider already
enforces cannot fail. `soft_delete_retention_days >= 7` was exactly
that: the provider's range is 7-90, so no accepted value could break it.
It now asserts `>= 30`, above the floor, where shortening the configured
90 days to the minimum does break it. Same reasoning for the deny rule:
Azure's priority floor is 100 and `vault_api` holds it, so "the deny
rule above *every* allow" is not a reachable configuration — 105, above
Raft and the health probe but below the API, is the version of that
mistake a contributor can actually commit, and it is the row in the
table.

### What verifying the table changed

Five of the thirteen original rows did not hold, which is the argument
for running one rather than writing one:

- **`the_key_vault_name_fits_azures_limit` was a tautology.** It
  re-derived `substr(cluster_name, 0, 15)` in the test file and asserted
  `15 + 1 + 8 <= 24`. `substr` caps the result, so the expression was
  true regardless of what `main.tf` did — widening the module's budget
  to 20 left the run green. `main.tf` now exposes
  `local.key_vault_name_prefix` and the run reads that, with a
  `cluster_name` long enough to reach the cap: with the 15-character
  default, every budget produces the same 15-character prefix and no
  assertion could tell them apart.
- **The deny-rule assertion compared against one allow.** A deny at
  priority 105 left the API reachable and silently denied Raft and the
  health probe — a cluster that never forms, behind a load balancer that
  ejects every node. It now compares against all three allows.
- **`vault_api_is_not_reachable_from_the_whole_internet` read the
  variable, not the rule.** Replacing `source_address_prefixes =
  var.allowed_cidr_blocks` with `source_address_prefix = "Internet"`
  opens the API to everyone while the default stays RFC1918. Two
  assertions on the rule itself now cover it.
- **`raft_discovery_uses_scale_set_mode_not_tags` did not require
  `resource_group`.** Scale-set mode is (resource group AND scale set);
  dropping the resource group leaves a line that still looks like
  scale-set discovery and that go-discover rejects the same way as the
  mixed selector the run was written for.
- **A hardcoded `instances = 3` is caught by `five_nodes_are_accepted`,
  not by the pinning run.** With the default `node_count` of 3 the
  pinning assertion cannot see the difference. Left as it is, and the
  table now names the run that actually catches it — but it means
  deleting `five_nodes_are_accepted` would quietly remove that
  coverage.

One more gap closed while verifying: `health_probe_id` was documented as
uncovered, on the grounds that asserting it needed apply mode and the
module did not survive apply under mocks. The mock fix that unblocked
the discovery runs settled that, so
`repair_watches_vault_rather_than_the_vm` now asserts it. Deleting the
line had left every other run green.

### Still not covered

`scale_set_is_pinned_and_does_not_autoscale` carries the comment "there
is deliberately no `azurerm_monitor_autoscale_setting` anywhere in this
module", and nothing enforces it: `terraform test` asserts on what a
configuration contains, not on what it lacks. Adding an
`azurerm_monitor_autoscale_setting` targeting the scale set passes all
25 runs — the one caveat being that writing its `target_resource_id` as
a reference rather than a literal trips the mocks, which produce a
random string where the provider wants an Azure resource ID. That is an
artifact of the mocks, not coverage. Enforcing the absence would mean a
grep-style check in `tests/preflight-static`; until there is one, read
that comment as an intention rather than a guarantee.

## `plan` vs `apply`

Most runs use the default `command = plan`. Two need `command = apply`,
both in the Raft discovery section: `custom_data` is rendered by
`templatefile()` from a key name the mock provider only supplies at
apply time, so at plan it is unknown and every assertion over it would
error rather than evaluate. With mocked providers `apply` creates
nothing; it resolves the mocked values.

That is also how the mock's `azurerm_storage_account.identity` came to
be written as a single object rather than a list of one — the type error
only surfaces under `apply`.

## Layout

| File | Covers |
|---|---|
| `cluster.tftest.hcl` | Scale set pinning, zones, repair, probe, LB, node_count validation, Raft discovery |
| `security.tftest.hcl` | Key Vault purge protection and naming, NSG scope and rule order, storage exposure, TLS, flow logs |
| `mocks/azure/` | Shared provider mocks, referenced by both files via `source` |

There is no `setup.tftest.hcl` here, unlike the AWS suite — the shipped
defaults are asserted inline instead. Worth adding one if the default
set grows.

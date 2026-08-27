# Azure infrastructure tests

Run with:

```bash
cd terraform/azure
terraform test
```

No Azure credentials required, and nothing is created — every provider
is mocked (`tests/mocks/azure/`). 24 runs, 39 assertions.

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

Cross-checking the mock against all 39 assertions, exactly one reads an
attribute that appears in the mock file at all —
`azurerm_linux_virtual_machine_scale_set.vault.identity[0].type`. That
resource has no `mock_resource` block, and `type = "UserAssigned"` is
set in `compute.tf`, so it is a configuration value too. **No assertion
here currently reads a mocked value.** Re-check that when adding one:
assert on config values and locals, and treat any assertion that reads
back an `id`, a `principal_id` or an `ip_address` as suspect.

## The mutation table is not verified yet

The AWS README carries a table of deliberate breaks, each confirmed to
fail the test that claims to catch it. **This one does not, and the
difference is not cosmetic** — an assertion that has never been watched
to fail is an assertion nobody has shown to work.

Below is what each run is *intended* to catch, which is a starting list
rather than evidence. Verifying it needs the azurerm provider, so it
cannot be done anywhere the Terraform registry is unreachable:

```bash
cd terraform/azure && terraform init -backend=false && terraform test
```

Break one thing, confirm the named run fails, revert, move on. Per
[`CONTRIBUTING.md`](../../../CONTRIBUTING.md), mutate with something the
assertion does not name — dropping `standbyok=true` is the change the
assertion greps for, whereas changing the probe's `protocol` to `Tcp` is
the neighbouring one a contributor actually makes.

| Intended mutation | Should be caught by |
|---|---|
| `instances` allowed to differ from `node_count` | `scale_set_is_pinned_and_does_not_autoscale` |
| `zone_balance` disabled, or one zone configured | `nodes_are_spread_across_availability_zones` |
| `automatic_instance_repair` disabled or its grace period shortened | `unhealthy_nodes_are_repaired_not_just_stopped_ones` |
| Probe switched to `Tcp`, or `standbyok` dropped | `health_probe_keeps_standby_nodes_in_the_pool` |
| LB rule switched off TCP passthrough, or SKU set to `Basic` | `tls_terminates_at_vault_not_the_load_balancer` |
| A `tag_name=` selector reintroduced into `auto_join` | `raft_discovery_uses_scale_set_mode_not_tags` |
| Scale set renamed independently of the local | `the_scale_set_name_matches_what_discovery_looks_for` |
| Purge protection disabled, or retention shortened | `the_autounseal_key_cannot_be_purged` |
| `cluster_name` lengthened past the 15-char prefix budget | `the_key_vault_name_fits_azures_limit` |
| `allowed_cidr_blocks` defaulted to `0.0.0.0/0` | `vault_api_is_not_reachable_from_the_whole_internet` |
| The catch-all deny rule moved above the allows | `the_security_group_denies_what_it_does_not_allow` |
| Shared key access re-enabled on the storage account | `snapshots_are_not_reachable_with_a_shared_key` |
| Blob versioning disabled | `snapshots_survive_an_overwrite` |

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

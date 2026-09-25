# AWS infrastructure tests

Run with:

```bash
cd terraform/aws
terraform test
```

No AWS credentials required, and nothing is created — every provider is
mocked (`tests/mocks/aws/`).

## What these do and don't prove

They assert on the **configuration's semantics**: that quorum arithmetic
holds, that an "internal" load balancer really lands in private subnets,
that the health check keeps standby nodes in the pool, that the node
security group has no CIDR ingress.

`terraform validate` cannot see any of that. Validate is perfectly happy
with a `cidrsubnet()` offset that overlaps two subnet ranges, or a
conditional that puts an internal load balancer on public subnets.

What they do **not** prove is that AWS accepts the result. Mocked
providers don't enforce quotas, IAM evaluation, or service-specific
rules, and no instance ever boots. **A real `terraform apply` in a
scratch account is still the only thing that demonstrates this works.**

## Beware of vacuous assertions

Anything a mock supplies is not evidence. An early version of
`nodes_cannot_delete_snapshots` asserted against the rendered JSON of
`data.aws_iam_policy_document.vault_snapshots` — which is mocked to a
fixed empty policy, so it passed happily with `s3:DeleteObject` injected
into the real one.

The fix was to assert against `local.snapshot_object_actions`, which
comes from the configuration rather than the mock. **Assert on config
values and locals; treat any assertion that reads a mocked data source
as suspect.**

The way to check is to break the thing on purpose and confirm the test
fails. These have been checked that way:

| Mutation | Caught by |
|---|---|
| `s3:DeleteObject` added to the node policy | `nodes_cannot_delete_snapshots` |
| IMDSv2 downgraded to `optional` | `imds_v2_is_required` |
| Health check matcher drops `429` | `target_group_keeps_standby_nodes_in_the_pool` |
| Load balancer switched to `application` | `tls_terminates_at_vault_not_the_load_balancer` |
| ASG `max_size` allowed to exceed `node_count` | `asg_is_pinned_and_does_not_autoscale` |
| Private subnet CIDRs overlapped with public | `public_and_private_subnets_do_not_overlap` |
| Public access block disabled on the bucket | `snapshot_bucket_is_not_public_and_is_versioned` |
| Volume key's data-key action narrowed from `kms:GenerateDataKey*` to `kms:GenerateDataKey` | `autoscaling_can_encrypt_node_volumes` |
| `kms:GrantIsForAWSResource` dropped from the grant statement | `autoscaling_can_encrypt_node_volumes` |
| Autoscaling role named as the grant's principal instead of matched by condition | `autoscaling_can_encrypt_node_volumes` |
| Shared account statement scoped to `kms:Describe*` | `autoscaling_can_encrypt_node_volumes`, `cloudwatch_logs_can_encrypt_flow_logs` |
| Seal key policy left on a hand-typed log group name | `cloudwatch_logs_can_encrypt_flow_logs` |
| Logs principal made global (`logs.amazonaws.com`) | `cloudwatch_logs_can_encrypt_flow_logs` |
| Raft egress between nodes narrowed to 8200 | `nodes_can_reach_each_other_and_nothing_else_on_cluster_ports` |
| Node API egress pointed at the load balancer's group | `nodes_can_reach_each_other_and_nothing_else_on_cluster_ports` |
| Raft egress opened to the VPC by CIDR | `nodes_can_reach_each_other_and_nothing_else_on_cluster_ports` |
| Bootstrap CA key encrypted under the seal key | `a_new_node_can_read_the_bootstrap_ca_and_nothing_more` |
| ASG's launch template version set to the constant `$Latest` (or `$Default`) | `a_launch_template_change_can_actually_trigger_the_refresh` |
| Bootstrap CA key's `key_id` removed, so SSM falls back to `aws/ssm` | `a_new_node_can_read_the_bootstrap_ca_and_nothing_more` |
| Node role granted `ssm:GetParametersByPath` as well | `a_new_node_can_read_the_bootstrap_ca_and_nothing_more` |
| User-data stops passing the load balancer as an extra SAN | `user_data_carries_the_boot_script_and_fits` |
| Embedded script's comments no longer stripped | `user_data_carries_the_boot_script_and_fits` |
| Stripping regex deletes every line containing `#` | `user_data_carries_the_boot_script_and_fits` |

Worth repeating for any assertion added later.

Two of the rows above survived their first run, and both are the
mocked-value trap in a new place:

- **The seal-key row passed** — every `aws_kms_key` gets the same ARN
  from the shared mock, so `key_id == aws_kms_key.vault_data.arn` compared
  a value with itself. The run now overrides the two keys with distinct
  ARNs. That was *still* not enough: runs in one file share state, the
  keys already existed from earlier `apply` runs, and the overrides
  changed nothing. `state_key = "bootstrap_ca"` gives the run state of
  its own. Removing `key_id` altogether was then caught too, which had
  not been planned as a row.
- **The `#` row passed** — the three code lines the assertion looked for
  contain no `#`, so a regex deleting every line with one left them
  standing. It now also pins `while [[ $# -gt 0 ]]; do`, a code line that
  has one.

## `plan` vs `apply`

Most runs use `command = plan`. A few need `command = apply` because they
compare against attributes that are unknown until apply — resource IDs,
mostly. With mocked providers `apply` creates nothing; it just resolves
the mocked values.

## Layout

| File | Covers |
|---|---|
| `setup.tftest.hcl` | The shipped defaults, so they can't drift unnoticed |
| `networking.tftest.hcl` | Subnet maths, AZ spread, NAT pairing, LB placement |
| `security.tftest.hcl` | Security group scope, IMDSv2, encryption, bucket exposure |
| `cluster.tftest.hcl` | Quorum, rolling refresh, health checks, node_count validation |
| `mocks/aws/` | Shared provider mocks, referenced by every file via `source` |

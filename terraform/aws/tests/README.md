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

Worth repeating for any assertion added later.

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

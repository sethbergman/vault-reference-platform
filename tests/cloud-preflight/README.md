# Cloud pre-flight and teardown tests

`scripts/preflight-cloud.sh` says what an apply will cost and what will
stop it, before the money starts. `scripts/teardown-cloud.sh` removes what
`terraform destroy` cannot. These tests drive both.

```bash
./tests/cloud-preflight/run-tests.sh
```

Runs in about a second. No cloud, no credentials, no money.

## Why these exist

A pre-flight that passes a subscription which cannot run the profile is
worse than no pre-flight: it converts a cheap failure into an expensive
one. Both of the pre-flight's own defects so far were that shape.

The first was found by the AWS apply on 2026-09-17 — it warned about an
empty `ssh_key_name` on every correct run, because the documented apply
passed the key with `-var`, and so never looked the key up.

The second and third were found by preparing the Azure apply on
2026-09-25, against a subscription the profile could not run at all:

- The "Quota that bites" heading printed **nothing** on Azure. The block
  beneath it was guarded `if [[ "$CLOUD" == "aws" ]]`, so the section that
  exists to catch a quota wall reported no findings at all, and counted
  toward neither warnings nor failures. That subscription had 4 vCPUs for
  the whole region against a profile wanting 6, two VM families capped at
  0 while the regional total looked roomy, and the B-series the profile
  defaults to marked `NotAvailableForSubscription` across entire regions.
  Every one of those would have surfaced at scale-set creation, with the
  VNet, NAT gateway, load balancer and Bastion already billing.
- The role check could not succeed. `az role assignment list --assignee`
  takes the name the directory holds, and a guest identity's sign-in name
  is not it: `someone@outlook.com` is stored as
  `someone_outlook.com#EXT#@tenant.onmicrosoft.com`, so the lookup failed
  with `Cannot find user or service principal in graph database`. The
  error went to `/dev/null`, `|| true` turned it into an empty string, and
  the pre-flight warned it "could not confirm" Owner on an account holding
  Owner twice at subscription scope. The false warning was not the defect:
  a Contributor-only identity produced the *identical* warning, so the
  check could not distinguish the case it exists to catch from the case it
  exists to pass.

The suite passed throughout, because the `az` shim shared both
assumptions — it answered `--assignee` happily, and there was nothing to
ask about quota. That is the shim failure mode
[`CLAUDE.md`](../../CLAUDE.md) warns about: model the real tool's output,
not the output the script wants.

## What is faked, and what each shim models

| Shim | What it models that matters |
|---|---|
| `az` | `--assignee` **fails** with the graph error, as the real CLI does for a guest identity. Only `--assignee-object-id` answers. The quota rows carry decoys a careless match would take instead: `lowPriorityCores` contains `cores`, `PublicIPAddresses` is the all-SKU total with a roomy limit beside a tight Standard one, and two families sit at a limit of 0. The family row comes back in a different case from the SKU's own `family`, which is how Azure returns it. |
| `aws` | Elastic IP usage, key-pair lookup, and the versioned-bucket paging teardown walks. |
| `terraform` | `plan`, `destroy`, `state list` and `output` return codes, so the pre-flight's own decisions are what is under test rather than Terraform's. |

Three `az rest` queries are told apart by what they ask for, since
implementing JMESPath in a shim would be implementing the thing under
test. `-o tsv` renders one line per field and prints nothing for an empty
array, so the shim reproduces that too — including the empty line az
prints for a null last field.

## What these cannot establish

That Azure agrees. `terraform plan` succeeding here means the shim exited
0, and a quota row the shim emits is a number this repository chose. The
numbers in `reset_scenario` are the ones a real subscription reported in
`westus2` on 2026-09-25, and the queries were read off the real API before
being written down, but the only thing that settles whether the check is
right is running it against an account — which
[`docs/cloud-apply.md`](../../docs/cloud-apply.md) records separately.

## Mutation table

Every row was watched to fail. Each mutation breaks the code with a change
the assertion does not name — the neighbouring edit a contributor actually
makes — because breaking it in exactly the way a test greps for proves
nothing.

| Mutation | Caught by |
|---|---|
| Look the identity up by sign-in name again | roles are looked up by object id, never by the sign-in name |
| Downgrade the missing role to a warning | Contributor alone fails, and the exit code says so |
| Accept only `User Access Administrator` | Owner passes |
| Stop guarding on an unresolved object id | an identity that cannot be resolved is unchecked, not condemned |
| Collapse a failed role read into an empty answer | role assignments that cannot be read are unchecked, not condemned |
| Treat an unrestricted size as restricted | a size the subscription can have passes |
| Go back to the six-minute client-side `vm list-skus` | SKUs are read through the filtered API, not by downloading all of them |
| Downgrade a restricted size to a warning | a restricted size fails before anything is created |
| Print only the last restriction | and says which kind of restriction it is |
| Drop the guard on a size that is not offered | a size the subscription has never been offered fails |
| Forget to multiply vCPUs by `node_count` | three nodes needing 6 vCPUs against a regional limit of 4 fails |
| Check the regional ceiling only | a family capped at 0 fails even with regional headroom to spare |
| Match the family quota row case-sensitively | the family quota row is matched regardless of case |
| Read the all-SKU public IP total instead of the Standard row | one free Standard public IP fails: the NAT gateway and the Bastion need two |
| Hardcode two addresses instead of counting them | an internet-facing load balancer needs a third address, and that is counted |
| Downgrade a zoneless size to a warning | a size with no zones in the region fails |
| Promote too-few-zones to a failure | fewer zones than the profile pins is a warning, not a failure |
| Compare `PremiumIO` in the wrong case | a size without premium storage fails: `os_disk` is `Premium_LRS` |
| Report an unreadable quota as a shortfall | quota that cannot be read is a warning, not a shortfall |
| Drop the cloud guard on the Azure block | the AWS profile asks Azure nothing |

One assertion is weaker than it looks and is recorded here rather than
overclaimed: *and says which kind of restriction it is* pins that both
`Location:` and `Zone:` reach the output, but the shim keys off the query
asking for `family, restrictions` rather than parsing it, so narrowing the
query to `reasonCode` alone would not change what the shim returns. The
mutation that does catch it truncates the formatting instead.

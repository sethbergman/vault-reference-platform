# State backend tests

Run with:

```bash
./tests/state-backend/run-tests.sh
```

Needs `terraform`, `curl`, and `python3` with `moto[server]` — which
brings `boto3` with it, used here to plant and remove the lock object.
No credentials, no account, nothing created outside a local process.
About six minutes, most of it provider installation.

## What this covers that nothing else does

The `backend` block in each profile is the small half of remote state.
The rest is ordering: the bucket has to exist before the configuration
that stores state in it, and it must not live in that configuration's
own state. A configuration file cannot assert either of those things
about itself, and neither can `terraform validate`.

So this applies [`terraform/aws/bootstrap`](../../terraform/aws/bootstrap)
for real against an implementation of the AWS API, points
`terraform/aws`'s backend at what that created, and checks the
properties that make the arrangement worth having:

- initialising against a bucket that does not exist is **refused**, and
  the error names the bucket. The alternative is the quiet failure this
  repository is mostly about: Terraform creating an empty state at a
  prefix nobody has written to, and the next `plan` offering to build a
  cluster that is already running.
- state written by an apply lands **in the bucket**, and no
  `terraform.tfstate` appears on the machine that ran it.
- a second apply is **turned away while the lock is held**, and the same
  apply **succeeds once it is released**. The second half is not padding:
  without it the first assertion passes just as well when the apply is
  broken for an unrelated reason. It was, once — see the mutation table.
- the bucket versions its objects, encrypts under the key the bootstrap
  module created rather than an account default, blocks public access on
  all four settings, and refuses `terraform destroy`.

The lock is exercised by one process planting the `.tflock` object
rather than two applies racing. A race is not reproducible on demand;
what is being checked is that the second apply asks and is refused.

Only one resource of the profile is applied (`-target`), because the
question here is where state goes rather than what the profile builds.
Whether `terraform/aws` applies at all is
[`tests/cloud-apply-emulated`](../cloud-apply-emulated/run-tests.sh)'s
question, and it answers it thoroughly.

## What it does not prove

An emulator implements the API, not the service. Nothing here shows that
S3 behaves this way in an account, that the IAM permissions to reach the
bucket are the ones actually granted, or that two applies from two
machines race the way one process planting a lock file does.

**Azure gets no emulator at all.** moto is an AWS API. The Azure
assertions in this suite are static reads of the configuration — that
the backend block is empty, that the state account refuses shared keys
while the backend example asks for Entra authentication — and they are
labelled that way in the output. `terraform/azure/bootstrap` has never
been applied to anything.

Neither backend has been pointed at a real account. See
[`docs/terraform-state.md`](../../docs/terraform-state.md) and
[`docs/roadmap.md`](../../docs/roadmap.md).

## Mutation table

Every row was run and watched to fail. A row nobody has executed is worse
than no row at all — verifying the Azure table for the first time broke
five of thirteen claims, two of which could not have failed at all. That
story is at the end of [`docs/roadmap.md`](../../docs/roadmap.md).

The rule the mutations follow is the one in
[`CONTRIBUTING.md`](../../CONTRIBUTING.md): break the code with something
the assertion does not name. Where an assertion reads a committed example
file, the mutation changes the *generated* output instead, so passing
requires the property rather than the spelling.

Baseline is 24 passed, 0 failed.

| Deliberate break | Caught by | Result |
|---|---|---|
| `outputs.tf` emits `use_lockfile = false`, so the generated backend config turns locking off | an apply is refused while another holds the lock | 22 / 1 |
| `aws_s3_bucket_versioning` set to `Suspended` | the state bucket has versioning enabled | 22 / 1 |
| `sse_algorithm` dropped to `AES256`, losing the module's own key | the state bucket encrypts under the key the module created | 22 / 1 |
| `ignore_public_acls = false` — one of the four, not all four | all four public access block settings are on | 22 / 1 |
| `force_destroy = true` | force_destroy is off, so a destroy cannot empty the bucket first | 22 / 1 |
| `prevent_destroy = false` | destroying the bootstrap module is refused by prevent_destroy | 22 / 1 |
| the profile's backend swapped to `backend "local" {}` | terraform/aws declares an S3 backend with nothing filled in; the profile initialises against the generated config | 15 / 2 |
| `outputs.tf` emits a bucket name that was never created | the generated backend config names the bucket that was created; the profile initialises against the generated config | 15 / 2 |
| a bucket name committed inside `backend "s3"` | terraform/aws declares an S3 backend with nothing filled in | 22 / 1 |
| a container name committed inside `backend "azurerm"` | terraform/azure declares an azurerm backend with nothing filled in | 22 / 1 |
| `backend.hcl.example` turns locking off | the AWS backend example turns S3 native locking on | 22 / 1 |
| the Azure state account accepts shared keys | the Azure state account refuses account keys, and the backend asks for Entra auth | 22 / 1 |
| `.gitignore` no longer covers `backend.hcl` | a generated backend.hcl is ignored by git in both profiles | 22 / 1 |
| the state key template drops `cluster_name`, becoming a constant | the state key is namespaced by cluster, so one bucket holds many | 23 / 1 |

Two of these are worth reading twice.

The locking row mutates what the module **emits**, not
`backend.hcl.example` — which a static assertion does name. That
assertion stayed green through the break, which is the point: locking is
asserted as a property of what the module generates, not as a spelling in
a committed example.

The public-access row breaks **one** of the four settings. Breaking all
four would have proved only that the loop runs.

### A mutation that proved nothing, and what it cost

The first attempt at the versioning row replaced `status = "Enabled"`
with `sed`, which matched twice: once in `aws_s3_bucket_versioning` and
once in the bucket's lifecycle rule. `Suspended` is not a valid lifecycle
rule status, so the apply failed and the run reported "the bootstrap
module applies end to end" — a real assertion catching a real breakage,
and nothing whatsoever about versioning.

It would have been easy to record that as a verified row. The rerun,
targeted to the versioning resource alone, is the row above.

### Assertions without a verified mutation

Stated rather than left to be assumed. These have not been watched to
fail:

- the emulator is answering — infrastructure for the suite, not a claim
  about the profile
- `terraform/aws` and `terraform/azure`: `init -backend=false`, then
  `validate` — the CI path; breaking it means breaking `validate` itself
- initialising against a bucket that does not exist is refused, by name
- the bootstrap module initialises
- an apply against the remote backend succeeds
- no local `terraform.tfstate` was written
- the state object is in the bucket at the expected key
- and the same apply succeeds once the lock is released

The per-cluster key row above came out of this list, and finding a
mutation for it is what showed why the rest are hard.

Those assertions read the key out of the generated config and then check
the state arrived there, so they follow the module wherever it goes: a
key template of plain `terraform.tfstate` passed all of them while
quietly giving two clusters one state file. The fix was not a mutation
but a *new assertion* that pins the key independently — and only then was
there something a mutation could break.

The three that remain are the same shape. Any configuration change that
would stop state reaching the bucket — swapping the backend to `local`,
pointing it at a bucket that does not exist — is caught earlier, by the
static check or by `init`, so it never reaches them. Breaking them needs
either a Terraform change or a harness change, and neither is a mutation
of this repository's configuration. They are better read as guards
against a future edit to the suite than as claims about the profile.

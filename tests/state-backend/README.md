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
- the same round trip runs as an IAM user holding only the
  `state_policy` the bootstrap module emits, with the emulator evaluating
  every request against it, resource ARN included. Three identities with
  a piece missing are refused: no `s3:PutObject`, no `s3:DeleteObject`,
  and the object prefix of another cluster. And the S3 actions the round
  trip needed are re-derived from a recording on every run and have to
  equal the ones granted, in both directions. It could be done here and
  not for the apply policy because, for these five request shapes, moto's
  S3 action names coincide with IAM's; for the provider's twenty-five they
  do not. The emulator runs with its signature check off and authorization
  on, because its re-signing decodes the workspace prefix Terraform
  signed; [`moto_server.py`](moto_server.py) explains.

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
S3 behaves this way in an account, that AWS's IAM evaluates the state
policy the way moto's does, that the policy's KMS statement is right (the
emulator's S3 never calls KMS, so no recording can see what it needs), or
that two applies from two machines race the way one process planting a
lock file does.

**Azure gets no emulator at all.** moto is an AWS API, and the Azure
emulator that does exist needs a licence and implements too little of
the profile to be worth one
([why](../../docs/cloud-apply.md#why-azure-has-no-emulated-apply)). The Azure
assertions in this suite are static reads of the configuration — that
the backend block is empty, that the state account refuses shared keys
while the backend example asks for Entra authentication — and they are
labelled that way in the output. `terraform/azure/bootstrap` has never
been applied to anything.

The AWS backend has been pointed at a real account once, by the
2026-09-17 apply: that session's bootstrap, applies and destroys all kept
their state in the bucket the module built. It raced nothing and ran as an
administrator, so what this suite asserts about locking and permissions is
still only asserted here. The Azure backend has never been used. See
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

Baseline was 24 passed, 0 failed when the rows below were watched. The
state-policy section added seven assertions after them, so the baseline
is now 31 and a rerun of any of these would report seven more passes
where the suite reaches that far; the rows record what was observed.

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

The state-policy rows were watched at a baseline of 31 passed, 0 failed.
Each mutates the `state_policy` output the bootstrap module emits, never
the suite's own helper:

| Deliberate break | Caught by | Result |
|---|---|---|
| the object statement loses `s3:DeleteObject` | four identities exist, and the emulator now evaluates IAM on every request | 25 / 1 |
| the object ARN widened from `<cluster_name>/*` to the whole bucket | the state policy names every action, this cluster's prefix, and the module's own key | 30 / 1 |
| the KMS statement names the key's alias instead of the key | the state policy names every action, this cluster's prefix, and the module's own key | 30 / 1 |
| the object statement gains `s3:GetObjectVersion`, which the backend never asks for | the S3 actions the round trip needed are exactly the ones the policy grants | 30 / 1 |

Two of these are worth reading twice.

The first row failed earlier than expected, and the reason is worth
keeping. The helper that builds the "without `s3:DeleteObject`" identity
refuses when the action is not in the policy to remove, since removing
nothing proves nothing, so the suite stopped at identity creation and
named the missing action. The round-trip and derived-set assertions
were never reached in that run; the fourth row is what shows the
derived-set check can fail on its own, with every identity built and
the round trip green.

The widening row is the reason the policy-document check pins the object
ARN to this cluster's prefix. The other-cluster identity rewrites the
prefix before testing, so a policy granted on the whole bucket would still
be refused for `some-other-cluster/*` and that assertion would stay green
through the break. Pinning the emitted ARN is what makes the widening
visible.

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
- the profile lists, locks, reads, writes and unlocks its state holding
  only the state policy
- every request the backend made can be named as an IAM action
- the three refusals: without `s3:PutObject`, without `s3:DeleteObject`,
  and as another cluster's identity

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

The state-policy ones are the same again, one step on. The round trip as
the narrow identity would fail if the emitted policy lost `s3:ListBucket`
or `s3:GetObject`, which is a mutation nobody has run; the two watched
rows that remove or add an action are caught before it, by the identity
helper and by the derived set. The three refusals assert what the
emulator does to an identity the suite itself narrowed, so no change to
the emitted policy reaches them: widen the policy and the helper still
narrows what it tests. That is why the prefix pin exists, and why these
are guards on the harness rather than claims about the module. The
unknown-shape assertion fails only when Terraform's backend starts asking
the bucket something new, which no edit here can provoke.

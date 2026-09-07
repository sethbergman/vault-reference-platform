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

Rows here were run and watched to fail. A row nobody has executed is
worse than no row at all — verifying the Azure table for the first time
broke five of thirteen claims, two of which could not have failed at
all. That story is at the end of [`docs/roadmap.md`](../../docs/roadmap.md).

The rule the mutations follow is the one in
[`CONTRIBUTING.md`](../../CONTRIBUTING.md): break the code with
something the assertion does not name.

| Deliberate break | Caught by | Watched |
|---|---|---|
| `outputs.tf` emits `use_lockfile = false`, so the generated backend config turns locking off | "an apply is refused while another holds the lock" — and only that assertion; 22 of 23 still passed | yes, twice |

The mutation is on the module's **generated output**, not on
`backend.hcl.example`, which a static assertion does name. That
assertion stayed green through the break, which is the point: locking is
asserted as a property of what the module emits, not as a spelling in a
committed example.

### Assertions without a verified mutation

Stated rather than left to be assumed. These have not yet been watched
to fail, so treat them as untested tests:

- versioning is enabled on the state bucket
- the bucket encrypts under the key the module created
- all four public access block settings are on
- `force_destroy` is off
- the bootstrap module refuses `terraform destroy`
- initialising against a missing bucket is refused
- state lands in the bucket, and no local state file is written
- the generated config names the bucket that was created
- every static assertion, including both Azure ones

Each is a one-line `sed` against `terraform/aws/bootstrap` followed by a
suite run; the cost is that a run takes about six minutes, so verifying
the lot is an hour rather than an afternoon. Worth doing before this
table is quoted as evidence for anything.

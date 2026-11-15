# Terraform state

Until this was added, neither cloud profile declared a `backend`. State
was a file on whoever ran `apply` last.

That is two problems wearing one coat. The smaller one is locking:
nothing stopped two applies running at once, and the second to finish
overwrites the first's record of what exists. The larger one is
durability. Losing `terraform.tfstate` does not lose the cluster — it
loses the ability to *change* the cluster, while Vault stays up holding
production secrets and the only remaining options are to import every
resource by hand or to build a second cluster beside the one nobody can
touch. It is a bad day that begins with a laptop dying.

## The ordering problem

The `backend` block is the small half of the fix. The rest is ordering,
and ordering is the part a configuration file cannot assert about
itself.

State has to live somewhere that exists *before* the configuration whose
state it holds. And it must not live in that configuration's own state,
or the bucket is a resource the cluster's `destroy` will happily take
with it — deleting the record of the thing it is halfway through
deleting.

So there is a separate configuration per provider,
[`terraform/aws/bootstrap`](../terraform/aws/bootstrap) and
[`terraform/azure/bootstrap`](../terraform/azure/bootstrap), which
creates the bucket or storage account and nothing else. It keeps local
state, deliberately. Something has to, and the honest place to stop is
the configuration that creates one bucket, can be re-run, and whose loss
costs an import rather than a cluster.

## Standing it up

Once per account or subscription, before the first `apply` of a profile:

```bash
terraform -chdir=terraform/aws/bootstrap init
terraform -chdir=terraform/aws/bootstrap apply

terraform -chdir=terraform/aws/bootstrap output -raw backend_config \
  > terraform/aws/backend.hcl

terraform -chdir=terraform/aws init -backend-config=backend.hcl
```

Azure is the same shape with `azure` substituted throughout.

Generating `backend.hcl` from the bootstrap module's output rather than
copying the `.example` is the point of the `backend_config` output: a
hand-copied bucket name can disagree with the bucket that exists, and
the symptom of that disagreement is an `init` that succeeds against an
empty prefix and a `plan` that offers to create a cluster you already
have.

`backend.hcl` is gitignored. The committed
[`backend.hcl.example`](../terraform/aws/backend.hcl.example) beside it
documents every key.

## Why the backend blocks are empty

`backend "s3" {}` with nothing in it looks unfinished. It is deliberate,
for two reasons.

A committed bucket name is a bucket that everybody who forks this
repository points their state at, and the first they learn of it is an
access-denied error or, worse, no error at all.

And CI runs `terraform init -backend=false` so that `validate` needs no
credentials. That works with a backend block present precisely because
there is nothing in it to half-configure. Filling it in would either
break that job or require a second code path for CI, and a CI code path
that differs from the real one is how a profile drifts from the thing
that is tested.

## Locking, and why the providers differ

AWS uses `use_lockfile = true`, the S3 backend's native locking. It is
one reason [`terraform/aws/main.tf`](../terraform/aws/main.tf) requires
more than 1.7: on an older version the attribute is rejected at `init`.
That is a better failure than the alternative — a version that ignores
it and applies without a lock, which is the exact corruption the backend
exists to prevent, arriving silently. The floor is now 1.11, for the
write-only argument that keeps the bootstrap CA key out of state
([security.md](security.md#a-node-the-autoscaling-group-replaces)).

It is not a DynamoDB table. The `dynamodb_table` argument still works
and is deprecated, and it is a second resource to create, pay for, and
forget to create for the next cluster.

Azure stays at 1.7. The `azurerm` backend takes a lease on the state
blob and has done for years, so nothing there needs the release that
introduced S3 locking. Two backends, two locking mechanisms, and only
one of them has a version floor worth stating.

## What the bootstrap modules create

Both create the same properties through different resources:

| Property | AWS | Azure |
|---|---|---|
| Previous versions kept | bucket versioning + lifecycle expiry | blob versioning + retention |
| Encrypted at rest | KMS key created here, named in the backend | platform encryption |
| Reachable only where it should be | public access block | TLS 1.2 floor; `allowed_ip_ranges` if set |
| Hard to delete by accident | `prevent_destroy`, `force_destroy = false` | `prevent_destroy` |
| Authentication | IAM | Entra ID; `shared_access_key_enabled = false` |

Versioning is the one that earns its place twice. A corrupted state file
is recoverable only if the previous version still exists, and the
scenario where you need it is the scenario where somebody has just run
something they should not have.

The AWS KMS key is named explicitly in `backend.hcl` rather than relying
on the bucket default. Naming it means the backend fails loudly if the
bucket's default encryption changes underneath it, rather than writing
state under whatever the default happens to be that week. It is not the
cluster's auto-unseal key, and should not be.

Azure additionally assigns "Storage Blob Data Contributor" to whoever
applied the bootstrap module. Because `shared_access_key_enabled` is
false there is no account key to fall back on, so anyone else who needs
to run `terraform` against that state needs the role granted explicitly.
This is the mechanism most likely to be the thing that is wrong the
first time somebody else on the team tries.

The row about reachability is the one place the two providers are not
equivalent, and the difference is worth stating rather than smoothing
over. The AWS state bucket is not reachable publicly at all. The Azure
state account, by default, accepts a connection from anywhere and
refuses to do anything useful with it — `shared_access_key_enabled` is
false, so reaching the account is not the same as being able to read it.

That default is deliberate and it is not the one the snapshot account
uses. Snapshots are written by the nodes, from inside the VNet, so
denying everything else there costs nothing. State is written by
whoever runs `terraform apply` — a laptop, a CI runner, someone on call
on another continent — and an account that denies by default with no
`ip_rules` is an account nobody can plan against, including the person
who created it. Set `allowed_ip_ranges` and the default becomes Deny
with those ranges allowed. Worth doing where the set of places Terraform
runs from is known and stable; a foot-gun where it is not, because being
locked out of the state of a running cluster is the failure this whole
arrangement exists to prevent.

## Who may reach the state

The bootstrap module emits a second output beside `backend_config`:
`state_policy`, the IAM policy for an identity that runs `terraform`
against this cluster's state and nothing else.

```bash
terraform -chdir=terraform/aws/bootstrap output -raw state_policy \
  > state-policy.json
aws iam create-policy --policy-name vault-reference-terraform-state \
  --policy-document file://state-policy.json
```

It is not the policy that builds the cluster. That one is
[`aws-terraform-apply.json`](../examples/policies/aws-terraform-apply.json),
and it carries nothing for the state bucket on purpose: who may read and
write the state is a different question from who may create the
infrastructure, and keeping the two apart keeps a failure unambiguous. An
identity that does both attaches both.

### Where the actions come from

Not from the Terraform documentation. moto records every request it is
sent, so a recording was taken of everything Terraform 1.15.9's S3
backend asked the bucket across `init`, `plan`, two applies, a contested
lock, `destroy` and `state list`: 39 requests, in five shapes.

| Request | What it is for | IAM action |
|---|---|---|
| `GET /bucket?list-type=2&prefix=env:/` | enumerating workspaces, on every command | `s3:ListBucket`, on the bucket |
| `HEAD /bucket/<key>` | checking the state object exists | `s3:GetObject` |
| `GET /bucket/<key>` | reading the state, and reading the lock to say who holds it | `s3:GetObject` |
| `PUT /bucket/<key>.tflock` with `If-None-Match: *`, then `PUT /bucket/<key>` | taking the lock, then writing the state | `s3:PutObject` |
| `DELETE /bucket/<key>.tflock` | releasing the lock | `s3:DeleteObject` |

Nothing else. No bucket `HEAD`, no versioning or location read, and not
one request to KMS, which is the part no recording can produce. Terraform
sends the key id in a header and S3 calls KMS on the caller's behalf, so
an emulator whose S3 performs no cryptography never sees it. On AWS,
writing an object under SSE-KMS needs `kms:GenerateDataKey` and reading
one needs `kms:Decrypt`, so the policy carries both on the module's own
key, by hand, and the suite can check only that it names the right key.

The object actions are granted on `<cluster_name>/*`, not on the bucket.
One bucket serves many clusters, one key each, and an identity entitled
to run `terraform` against one of them has no business reading the
others'. The listing has to be on the bucket itself: S3 has no narrower
resource for it.

### What keeps it true

[`tests/state-backend`](../tests/state-backend/run-tests.sh) runs the
round trip as an IAM user holding only that document, with the emulator
evaluating every request against it, resource ARN included, which is the
one thing the apply policy's `Resource: "*"` cannot be checked for. Then
it takes the policy apart:

- without `s3:PutObject` the apply cannot take the lock, and says so;
- without `s3:DeleteObject` the apply succeeds, writes the state, and
  then cannot release the lock. Terraform exits non-zero and the lock
  stays behind, so an identity with that gap looks like it works until
  the next person tries;
- an identity written for another cluster in the same bucket, same
  actions and a different prefix, is refused.

And it re-derives the set from a fresh recording on every run: the S3
actions the round trip needed have to be exactly the ones the policy
grants, in both directions, and a request shape the suite cannot name is
a failure. A Terraform release that starts asking the bucket something
new fails there and names the action.

The reason this could be done here and not for the apply policy is the
size of the request set. moto authorizes S3 against names of its own, and
for much of S3 they are not IAM's (a bucket `HEAD` is checked as
`s3:HeadBucket`), so the apply suite hands the emulator `s3:*` and leaves
its 22 S3 actions unverified. For the five shapes the backend makes,
moto's names and IAM's coincide, so the policy reaches the emulator
exactly as the module emits it, and the derivation in
[`state_identity.py`](../tests/state-backend/state_identity.py) names
requests by shape, no wider than the five, so that a sixth fails rather
than being quietly covered.

One concession was needed. The emulator's signature check cannot pass for
Terraform's workspace listing: it re-signs a URL that werkzeug has already
decoded, so the `env%3A%2F` Terraform signed becomes `env:/`, and every
listing fails with `SignatureDoesNotMatch` while the object operations
pass. The suite starts moto with that comparison off and authorization
on. The key still has to exist and still identifies the user whose policy
is evaluated; what is given up is proof that the caller holds the secret
half of a key the suite minted a moment earlier, which no assertion needs.
[`moto_server.py`](../tests/state-backend/moto_server.py) says the same at
length, beside the one line that does it.

No AWS account has evaluated this policy. moto's IAM has no service
control policies, permission boundaries or resource policies. A green
suite says the document is not obviously short; the fifth AWS session in
[roadmap.md](roadmap.md#the-plan-to-v10) is where AWS gets to disagree.

## Destroying

`prevent_destroy` is set on both state containers, so `terraform
destroy` in a bootstrap directory fails rather than deleting the bucket.
That is the intended behaviour: the state container should outlive every
cluster whose state it has held, and removing it is a deliberate act
that involves editing the configuration first.

Tearing down a cluster does not touch it. See
[`scripts/teardown-cloud.sh`](../scripts/teardown-cloud.sh) and
[cloud-apply.md](cloud-apply.md) for what cluster teardown does and
where it still fails partway.

## What this does not prove

[`tests/state-backend`](../tests/state-backend/run-tests.sh) applies the
AWS bootstrap module against an implementation of the AWS API (moto),
points the real profile's backend at what it created, and checks that
`init` before the bucket exists fails and says why, that state lands in
the bucket rather than on disk, and that a held lock refuses a second
apply.

An emulator implements the API, not the service. Nothing there shows
that S3 behaves this way in an account, that AWS's IAM evaluates the
state policy the way moto's does, that the KMS half of that policy is
right, or that two applies from two machines race the way one process
planting a lock file does.

**Azure gets no emulator at all.** moto is an AWS API, and the Azure
emulator that does exist needs a licence and implements too little of
the profile to be worth one
([why](cloud-apply.md#why-azure-has-no-emulated-apply)). The Azure
assertions in that suite are static reads of the configuration and are
labelled as such. `terraform/azure/bootstrap` has never been applied to
anything.

The AWS backend has been pointed at a real account once, by the
2026-09-17 session: the bootstrap module built the bucket and its KMS
key, the generated `backend.hcl` initialised the profile against it, and
every plan, apply and destroy in that session kept its state there. What
that does not answer is whether two machines race for the lock the way
one process planting a lock file does, or whether a least-privilege
identity can reach the bucket: the session ran as an administrator, and
the state policy that exists now has been evaluated only by the emulator.
The Azure backend remains configured and never exercised. See
[roadmap.md](roadmap.md) and [cloud-apply.md](cloud-apply.md).

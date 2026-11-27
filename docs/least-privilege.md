# Least privilege

Six real applies of this repository's cloud profiles — four on AWS, two on
Azure — and every one of them ran as an administrator. So the profiles were
known to work for somebody who can do anything, which is the one identity
nobody should be using, and "what does this actually need?" had no answer.

That answer for AWS is
[`aws-terraform-apply.json`](../examples/policies/aws-terraform-apply.json)
in `examples/policies/`: 141 actions across nine services, enough to apply
and destroy `terraform/aws` and to upgrade it the documented way.

## Use it

Attach it to the role or user that runs Terraform:

```bash
aws iam create-policy \
    --policy-name vault-reference-terraform-apply \
    --policy-document file://examples/policies/aws-terraform-apply.json
```

```bash
aws iam attach-role-policy \
    --role-name YourTerraformRole \
    --policy-arn arn:aws:iam::<account>:policy/vault-reference-terraform-apply
```

Then ask whether it worked, before spending anything:

```bash
./scripts/preflight-cloud.sh --cloud aws
```

The pre-flight reads the same file and asks IAM to evaluate every action
against your caller identity. A missing permission is a `FAIL` naming the
actions, which beats discovering them one at a time over a forty-minute
apply.

It needs `iam:SimulatePrincipalPolicy`. Without it the section warns rather
than failing — being unable to ask is not being unable to apply, and a narrow
identity is the likeliest one to lack it. The permission to find out what you
are missing is itself a permission.

For an assumed role, `sts get-caller-identity` returns a session ARN
(`arn:aws:sts::…:assumed-role/Role/session`) and the simulation refuses it.
The pre-flight translates that to the role ARN itself; without that step the
error is `Invalid Entity Arn`, which reads like a broken pre-flight rather
than an ARN that needs converting.

## How the list was built, which is the reason to trust it

Not from AWS documentation, and not by guessing.

`moto` enforces IAM from its core request dispatcher, so every service the
profile touches is authorized against a real access key, and its request
recorder captures every request made. One apply and one destroy against the
emulator produced **565 requests**. Each one names its service in the SigV4
credential scope and its action in the request body or the `X-Amz-Target`
header, which gives 115 actions read off what the AWS provider *did* rather
than off what the configuration says.

Three of those are the argument for deriving rather than writing it by hand:

| Action | Why nobody would have included it |
|---|---|
| `sts:GetCallerIdentity` | Called through a data source even with `skip_requesting_account_id = true` on the provider |
| `ec2:GetInstanceUefiData` | The provider probes it while reading the launch template |
| `elasticloadbalancing:DescribeCapacityReservation` | A newer API the provider asks about unprompted |

The apply fails without the first. The other two are in the list because the
provider asked for them — see "not minimal" below.

S3 is the exception, and is the weakest part of the file. moto names S3
actions from **botocore operation names** rather than IAM action names: a
bucket `HEAD` is checked as `s3:HeadBucket`, which IAM does not have at all.
So the 22 S3 actions are mapped by hand from the 25 bucket request shapes the
recording captured, using documented IAM names, and the emulator is handed
`s3:*` instead of being asked to check them.

Note how many of those 22 are reads. `aws_s3_bucket` refreshes by asking the
bucket about every feature it might have — website, CORS, logging,
replication, accelerate, request payment, object lock — and a 403 on any of
them is an error rather than an absent configuration. That is why a
least-privilege S3 policy is larger than the resource count suggests.

## The upgrade, which is neither an apply nor a destroy

The 137 actions read off the recording covered the two things the
recording did. The documented upgrade on AWS is a third: bump
`vault_version` and apply again ([rolling-upgrades.md](rolling-upgrades.md)),
which updates the launch template in place and then starts an instance
refresh. A create and a destroy contain neither, so until 2026-11-27 an
identity holding this file could build the cluster and could not upgrade
it. The emulator refused the bump at `ec2:CreateLaunchTemplateVersion`,
and the fifth AWS session would have met the same refusal on item 9 of
its checklist, with a cluster already built.

Four actions were added, and they do not have the same standing:

| Action | Where it came from | Evaluated by |
|---|---|---|
| `ec2:CreateLaunchTemplateVersion` | The recording of a bump against the emulator, which the narrow identity failed on | The emulator, every PR |
| `autoscaling:StartInstanceRefresh` | terraform-provider-aws 5.100.0's `startInstanceRefresh`, called whenever the template version moves | Nothing |
| `autoscaling:CancelInstanceRefresh` | The same function, when a refresh is already running: it cancels that one and starts again | Nothing |
| `autoscaling:DescribeInstanceRefreshes` | The wait for that cancel to finish | Nothing |

The last three are read off provider source because moto does not
implement instance refresh: it answers `StartInstanceRefresh` with a 500,
and the provider retries that until it times out. So the bump in the suite
is targeted at the launch template, the refresh half of the upgrade is not
run, and the suite can only pin that the three names are in the file. The
fifth AWS session evaluates the first; the other two stay unevaluated even
then, unless somebody applies again while a refresh is still running.

The target has a second reason. The emulator reports a referenced
security group as `<account>/<sg-id>` and drops rule descriptions, so an
untargeted second plan offers to update six rules, and the identity is
refused `ec2:ModifySecurityGroupRules` for them. That action is not in
the file and was not added: the 2026-09-24 bump against a real account
reported one change, the launch template, and the six are the emulator
disagreeing with itself rather than the profile asking for anything.

## What keeps it true

[`tests/least-privilege-apply`](../tests/least-privilege-apply/run-tests.sh)
applies **and destroys** `terraform/aws` as an IAM user holding only this
policy, on every PR. The destroy matters: it is half of what an operator does,
and the half a policy written from an apply alone always misses.

Four negative cases remove one action each and require something to fail,
because a green run on its own is equally consistent with authorization never
having been switched on:

| Removed | Shape |
|---|---|
| `ec2:CreateVpc` | a create nothing works without |
| `ec2:DescribeImages` | a read — the AMI data source resolves before anything is created, so it fails the plan |
| `iam:GetRole` | a read of something the profile itself created |
| `ec2:CreateLaunchTemplateVersion` | an update: the apply succeeds without it, and the version bump after it does not |

Between the apply and the destroy it bumps `vault_version` as the same
identity and requires the launch template's `latest_version` to move by
one, not only the command to succeed: a bump that changes nothing also
succeeds, with every permission or none.

The suite also asserts the file names every action with no wildcard, lists
each once, and fits IAM's 6144-character managed-policy limit. It is at 4718,
so there is room, and when there is not the policy has to be split and these
instructions change.

## What this does not claim

**It is not minimal.** It is sufficient, derived from what the profile
*requests*, which is not the same as what it *requires*. The clearest
evidence is `ec2:DescribeNetworkAcls`: the provider asks for it, the apply
succeeds without it, and it is still in the file. It was the obvious third
negative case until the suite showed the apply passing without it.

Pruning properly means removing each of the 141 actions in turn and
re-running the apply — about six hours of emulated applies — and has not been
done. A bisecting version of that is the next narrowing worth having.

**It is not resource-scoped.** Every statement is `Resource: "*"`. This
narrows what the identity can do, not what it can do it to. The ARNs are not
known until apply time, and a resource-scoped version is separate work the
emulator cannot check either.

**It does not cover the state backend.** `terraform/aws/bootstrap` creates
the state bucket, and reading and writing state is a different identity
question from creating infrastructure — who may see the state is not who may
build the cluster. Mixing them would make a failure ambiguous, so
`tests/least-privilege-apply` uses a local backend and this policy carries no
`s3:GetObject` or `s3:PutObject` on the state bucket. That answer is the
bootstrap module's `state_policy` output: derived the same way, scoped to one
cluster's prefix, and, unlike this file's S3 statement, evaluated by the
emulator: for the five request shapes Terraform's backend makes, moto's S3
action names coincide with IAM's, and for the provider's twenty-five they
do not. See
[terraform-state.md](terraform-state.md#who-may-reach-the-state). An
identity that runs `init` as well as `apply` attaches both.

**No real AWS account has seen it.** Every result above comes from an
emulator. moto's evaluator is an approximation of IAM's: no service control
policies, no permission boundaries, no resource policies, and no condition
keys. A green suite says the policy is not obviously short. It does not say
AWS agrees, and the S3 statement in particular has never been evaluated by
anything.

**There is no Azure equivalent.** Azure expresses this as role assignments
over scopes rather than as a list of actions, has no single call like
`simulate-principal-policy`, and has no emulator here to derive against. Both
Azure applies ran as Owner — which, as
[`cloud-apply.md`](cloud-apply.md) records, is a control-plane role carrying
no data-plane access at all, so even "Owner" is not the blanket it sounds
like.

## The order to do this in

1. Attach the policy to a non-administrator role.
2. Run the pre-flight. It will tell you what is missing before you spend
   anything.
3. Apply. If something is refused, the error names the action — add it, and
   open an issue so the file gains it for everyone.

Step 3 is the step that has never happened. Until it does, this file is a
careful derivation against an emulator rather than a tested policy.

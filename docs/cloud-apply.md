# The cloud apply

**`terraform/aws` has been applied to a real account once, on
2026-09-17. `terraform/azure` never has.**

That session is recorded under [what the first apply
settled](#what-the-first-apply-settled): six of the ten items below were
observed, one was observed failing, three were not reached, and the ten
defects found on the way are in the [roadmap](roadmap.md). The document
still reads as instructions rather than a report, because the next real
apply is Azure's, and because AWS's remaining items need a cluster
standing again.

Everything outside the cloud profiles is tested — 80 assertions against a
real three-node cluster, promtool unit tests on the alert rules,
`terraform test` against mocked providers. But mocked providers confirm
that the configuration is *well-formed*, not that AWS accepts it. The gap
between those two things is the first blocker on the
[roadmap](roadmap.md), and it is the reason this document exists.

Part of that gap has since been closed for free.
[`tests/cloud-apply-emulated`](../tests/cloud-apply-emulated/run-tests.sh)
runs a real `terraform apply` of the AWS profile, through the real AWS
provider, against an implementation of the AWS API — so the profile is
applied and destroyed on every PR, and every request is built, sent and
answered. That settles the questions this document used to open with:
whether the configuration applies at all in one pass, whether every
reference resolves in an order Terraform can satisfy, whether the AMI
filter matches anything, and whether any value is refused outright.

It settles nothing below. An emulator implements the API, not the
service: nothing boots, no health check runs, no scaling group replaces
anything, and KMS returns plausible answers without performing
cryptography. Every item in the [verification
checklist](#the-verification-checklist) is a question about behaviour at
runtime, which is exactly what an emulator does not have. Azure has no
equivalent run at all, for the reasons
[below](#why-azure-has-no-emulated-apply).

The first person to apply the Azure profile is spending money to find out
what is wrong. On AWS that session has happened, and it was: ten defects
between an apply and a working cluster, five of them found before Vault
started at all. This is about making that session produce the maximum
amount of evidence, rather than discovering a missing SSH key twenty
minutes in and starting again tomorrow.

Three parts:

1. [`scripts/preflight-cloud.sh`](../scripts/preflight-cloud.sh) — what
   can be checked for free, before spending anything
2. The [verification checklist](#the-verification-checklist) — what to
   prove while it is up, in an order that survives things going wrong
3. [`scripts/teardown-cloud.sh`](../scripts/teardown-cloud.sh) — because
   `terraform destroy` on these profiles does not fully work

---

## Which profile this is written for

The commands are **AWS** unless an item carries an **On Azure** block.
Eight of the ten do — 1, 2, 3, 4, 5, 6, 9 and 10 — and the absence
of one means the item is genuinely identical, not that the Azure case was
skipped.

Item 4 is the one where Azure differs in the *assertion* rather than the
command, because its probe has no status-code matcher to check.

Both applies are separate v1.0 blockers ([roadmap](roadmap.md)); neither
settles the other. If you are only going to do one, do AWS first: it is
the profile with the broken default, so the pre-flight earns its keep
there.

Every Azure command below is written from `terraform/azure` and its
outputs. **None has been run against a live subscription** — that is the
blocker, and it applies to this document as much as to the profile.

---

## Why Azure has no emulated apply

Not because no Azure emulator exists. One does, and it was tried on
2026-09-16 before being turned down, so that the next person to find it
does not have to repeat the exercise to learn why this repository does
not use it.

**What was checked.** LocalStack for Azure ships as a public image,
`localstack/localstack-azure`, described as a preview and tagged only
`latest` and `dev`. Started without a `LOCALSTACK_AUTH_TOKEN`, it exits
within seconds with status 55 and `License activation failed!`, before
its health endpoint ever answers. LocalStack's pricing page listed no
plan that included Azure at all, the free licence for open-source
projects among them, and offered a waitlist instead. The other
candidate, azemu, was at v0.3 and covered resource groups, virtual
networks, storage and Key Vault.

**Why a token would not have changed the answer.** Three reasons, and
the last is the one that would survive LocalStack making it free:

- **The licence is checked at start, against LocalStack's service.**
  Every version here is pinned so that a red `main` points at a change
  in this repository. A job that cannot start without reaching a vendor
  turns their outage into our failure, and with no version tags the image
  can only be pinned by digest — which pins the code, not the licence.
- **A job that needs a secret cannot run on a pull request from a
  fork.** It would have to skip there, and a skipped job fails nothing.
  That is the quiet failure this repository exists to refuse.
- **It does not implement what makes Azure different.** Its service list
  has no virtual machine scale sets, no load balancer, no network
  security groups and no Network Watcher. Those carry peer discovery, the
  health probe and instance reconciliation — the three mechanisms with no
  AWS counterpart, and the reason the Azure apply is a blocker of its own.
  An emulated apply of `terraform/azure` would have to exclude exactly
  the resources most likely to be wrong, and could not claim what
  `tests/cloud-apply-emulated` claims: that the profile applies in one
  pass.

**What would reopen it.** An Azure emulator that starts without a
licence check, or one whose service list gains scale sets and load
balancers. The place to start would be `terraform/azure/bootstrap`,
not the profile: a resource group, a storage account, a container and a
role assignment, all four of which LocalStack listed. Two things are
unverified even there. The module pins `azurerm ~> 3.0`, and LocalStack
documents its `metadata_host` setup without saying which major version it
was tested against. And a storage account that refuses shared keys has
to authenticate through an emulated Entra ID, which nothing here has
tried.

Until then, the Azure side of this document is what it has always been:
the pre-flight, the checklist and the teardown, with nothing applied
beforehand.

---

## What the first apply settled

One session, 2026-09-17, in a sandbox account: `az_count=2`,
`node_count=3`, `t3.small`, us-east-1, about two hours and under a dollar.
Every fix named here is merged; the defects themselves are in
[roadmap.md](roadmap.md).

| Item | Result |
|---|---|
| 1. The instance boots and Vault starts | **Observed.** cloud-init `done`, `vault` active on all three, 1.17.2, Raft storage |
| 2. Auto-unseal, no human | **Observed**, after two KMS key policies had to be written: `Sealed false`, `Seal Type awskms`, and `Decrypt` by the node role in CloudTrail |
| 3. Raft `auto_join` finds the other nodes | **Observed**, after the node security group was allowed to send to its own members: three voters, autopilot healthy, failure tolerance 1 |
| 4. The load balancer keeps standbys in the pool | **Observed.** All three targets healthy; a standby answers 429 bare and 200 with `standbyok`, so the `200,429` matcher is a backstop that never fires — as this document already said |
| 5. The Ansible handoff | **Observed**, after four defects: the inventory filenames, where `group_vars` live, the package spelling, and the certificate paths. The SSM tunnel reached all three nodes from a laptop |
| 6. Snapshots reach the bucket | **Not reached.** The role is off by default and enabling it was out of scope for the session |
| 7. Restoring a snapshot works | **Observed** under the KMS seal: canary written, snapshot taken, canary hard-deleted, restore, canary read back |
| 8. PKI certificates and audit devices | **Not reached.** Both roles are off by default |
| 9. An instance refresh keeps quorum | **Not reached**, and blocked by item 10: a refresh replaces every node the same way a termination replaces one |
| 10. Losing a node | **Observed failing.** See below |
| The teardown | **Observed.** `teardown-cloud.sh` in one pass; afterwards no instances, NAT gateways, EIPs, load balancer or ASG remained. The `BucketNotEmpty` path was *not* exercised — no snapshot had been written, so the bucket was empty |

### The cluster is not self-healing

Item 10 is the one that justifies the architecture, and it failed.
Terminating the leader did everything the middle of this document
promises: a new leader was elected in seconds, the load balancer dropped
the dead target, and the autoscaling group launched a replacement inside
75 seconds.

The replacement never became a Vault node. cloud-init finished, and Vault
exited with `error loading TLS cert` because `/etc/vault.d/tls/` did not
exist, until systemd stopped retrying. **Certificates reach a node only
through an Ansible run, and they are named after instance ids that do not
exist until after the launch.** Nothing in the automated path issues one.

Recovering it takes two commands, and they worked:

```bash
./scripts/generate-cloud-certs.sh --cluster-name vault-reference --add-missing
cd ansible && ansible-playbook -i inventory/aws_ec2.yml playbooks/site.yml \
    --limit <new-instance-id>
```

`--add-missing` signs one more leaf with the CA already on disk and
already trusted, leaving every other node's material alone — the CA key
was being kept for exactly this and there was no mode that used it. On
2026-09-17 the leaf was cut by hand because the flag did not exist yet;
the node then unsealed through KMS and joined as a voter.
`scripts/configure-autopilot.sh` also ran against a live cluster for the
first time here, and the dead voter was pruned once the replacement
existed.

So auto-unseal and `auto_join` work at recovery time as well as at apply
time — but only after a person intervenes, which is what item 10 exists
to rule out. Two commands is better than the guesswork it replaced, and
it is still two commands: something has to notice the node exists.
Until a replacement can get its material without a person,
**blocker 1 stays open** and item 9 cannot be attempted.

The fix since: a replacement signs its own leaf at boot, from the
bootstrap CA published to SSM, with the same SANs its peers carry —
`scripts/issue-bootstrap-cert.sh` in user-data, fed by
`scripts/publish-bootstrap-ca.sh`. The design and what it gives up are in
[security.md](security.md#a-node-the-autoscaling-group-replaces). It was
tested with shims and real `openssl` before it was ever watched on a real
cluster — and it was watched on 2026-09-24, which is the next section.

---

## What the second apply settled

One session, 2026-09-24/25, same sandbox account and shape: `az_count=2`,
`node_count=3`, `t3.small`, us-east-1, about two hours and a few dollars.
It went in for item 10 and came out with items 9 and 10 both observed and
three defects that no test here could reach.

| Item | Result |
|---|---|
| 1–4 | **Observed again**, unchanged from 2026-09-17 and without a fix in between: cloud-init `done`, `sealed false` / `awskms` on all three, leader plus two voters, all three targets healthy |
| 9. An instance refresh keeps quorum | **Observed.** All three nodes replaced; the live-node count never fell below the quorum the voter count demanded. The trigger, though, was broken — see below |
| 10. Losing a node | **Observed passing.** The replacement signed its own certificate, auto-unsealed and joined Raft with nobody touching it |
| The CA key stays out of Terraform state | **Observed** against real SSM: `bootstrap_ca_key.value` is empty in the state object and the state holds no private key material |
| 5–8 | **Not reached**, as in 2026-09-17: snapshots to the bucket, a restore, PKI and audit on a real node |
| The teardown | **Observed.** One pass; afterwards a sweep of every enabled region found no instances, NAT gateways, EIPs, load balancers, volumes, ASGs, endpoints, log groups or SSM parameters. The `BucketNotEmpty` path was again not exercised — no snapshot was ever written |

### Item 10: the replacement healed itself

The leader was terminated at 00:00:57Z. A survivor took leadership, the
autoscaling group launched a replacement, and its boot log says the part
that had never been watched:

```text
[bootstrap-cert] Wrote /etc/vault.d/tls/vault.crt for i-037621b16856600af,
                 signed by the vault-reference bootstrap CA.
[bootstrap-cert] The CA key was never written outside a private directory,
                 and is now deleted.
```

It then auto-unsealed under `awskms`, joined Raft as a voter and went
`healthy` in the target group — about four minutes end to end, no human
step. In 2026-09-17 the same check needed `generate-cloud-certs.sh
--add-missing` and an `ansible-playbook --limit`.

**Blocker 1 closes here.** What it never reached is unchanged and is
listed above; none of it is about whether a node can replace itself.

### Item 9: quorum held, and the trigger did not fire

The documented way to start a refresh — bump `vault_version` and apply —
replaced nothing. `terraform/aws/compute.tf` referenced the launch
template as `"$Latest"`, a constant, so the autoscaling group never
changed and `instance_refresh` never fired. The apply reported `0 added,
1 changed, 0 destroyed` and `describe-instance-refreshes` was empty. That
is fixed; the refresh itself was then started with
`aws autoscaling start-instance-refresh` and watched to completion.

Sampling every 45 seconds, the third node's replacement is the whole
story:

```text
live 3  peers 3  voters 3  quorum 2
live 4  peers 4  voters 3  quorum 2   replacement joined as a NON-voter
live 4  peers 4  voters 4  quorum 3   promoted, with 4 live to carry it
live 3  peers 4  voters 4  quorum 3   old instance gone: no margin
live 3  peers 3  voters 3  quorum 2   pruned
```

`Successful`, 100%, three entirely new instance ids, and at no sample did
the live count fall below the quorum the voter count demanded.

Note the fourth line. There is a window — about 50 seconds here, bounded
by `dead_server_last_contact_threshold` — where three live nodes face a
quorum of three and a second failure would stop the cluster. That is the
mechanism working, not a defect, but it is not the "never rises above
three" this repository claimed until this session; the promotion happens
before the prune, not after.

### What it found

Three defects, all in code every existing test passes:

1. **`configure-autopilot.sh` could lock out its own pruning.** It
   derived `min_quorum` from every voter `list-peers` reported, including
   a terminated one — setting the floor one too high and forbidding the
   prune it had just enabled, then verifying its own write and reporting
   success. The floor now comes from voters `autopilot state` reports
   healthy.
2. **A version bump replaced nothing**, as above.
3. **This sequence never ran `configure-autopilot.sh`**, which is why the
   cluster met item 10 with `cleanup_dead_servers = false` and a 24-hour
   threshold. It does now.

Two smaller ones cost about twenty minutes between them: the playbook
command here omitted `--private-key`, and nothing said the AWS inventory
plugin needs `boto3` in the same Python that runs Ansible.

### What is still unproven

- Snapshots to the bucket, a restore at the cloud destination, PKI and
  audit on a real node — items 5 through 8 have now been skipped twice.
- The `BucketNotEmpty` teardown path, for the same reason.
- Any identity narrower than an administrator, on either profile.
- Whether `vault operator raft autopilot state -format=json` arrives bare
  or wrapped in `.data`: this session read that command in text form
  only. The script accepts both and says so; settle it next time.
- A refresh triggered the documented way, now that the trigger is fixed.
  What was watched was a refresh started from the CLI.

---

## Before you apply

```bash
export TF_VAR_az_count=2 TF_VAR_ssh_key_name=your-key
./scripts/preflight-cloud.sh --cloud aws
```

It checks tooling, resolves your identity (and prints *which account* you
are about to spend money in), validates the inputs that fail late,
estimates cost, names what a teardown will not remove, and runs
`terraform plan`. It applies nothing. It exits non-zero only on
failures — warnings are things to have read, not things to fix.

**Set inputs in the environment, not with `-var`.** The pre-flight checks
the values `terraform` in the same shell will use — a `TF_VAR_*`, else
the default — and cannot see a `-var` on a command that has not run yet.
This document used to pass the key with `-var` on the apply, so the
pre-flight read the empty default, warned about it on every correct run,
and never looked the key pair up. The first real account is what showed
it. Exported once, the same values reach the plan, the apply and the
teardown's `destroy`.

**Run it twice.** The plan needs an initialised backend, and the backend
needs the bucket the bootstrap module creates, so a first run before
bootstrap checks everything *except* whether the profile plans — and
says so. Run it again after `init`, before the apply.

Four failures it exists to catch, all of which cost money to discover
otherwise:

| Check | Why it is worth catching early |
|---|---|
| `ssh_key_name` is empty | **The apply succeeds** and produces instances nobody can log into. Every item in the checklist below needs a shell on a node, and the Ansible layer needs SSH specifically — the tunnel carries it, it does not replace it. |
| `session-manager-plugin` is missing | The AWS CLI execs it to open a Session Manager tunnel, which is how the playbook reaches a node with no public address. Every connection fails naming the plugin rather than the thing you were doing. |
| The key pair does not exist in this region | The apply fails at instance launch — after the VPC and NAT gateways are already billing. |
| Elastic IP quota | One EIP per NAT gateway, one NAT gateway per AZ, default limit 5. Three zones plus anything already in the account can exceed it. |
| Azure role assignment permission | The profile creates a role assignment, which needs Owner or User Access Administrator. Contributor applies most of the profile and *then* fails. |

The `ssh_key_name` one is not hypothetical: `terraform/aws/variables.tf`
ships it empty, so the default AWS apply produces an unreachable cluster.

Reaching the nodes at all is worth reading before the session rather than
during it — the nodes are in private subnets with no inbound 22, and the
AWS inventory tunnels SSH through Session Manager to get to them. See
[deployment.md](deployment.md#reaching-the-nodes) for what that needs.
Azure's inventory does not tunnel, so reaching those nodes is still
unsolved.

---

## What it costs

Estimates for comparison, not a quote. Run the pre-flight for the numbers
matching your own variables.

### AWS, at defaults (`az_count = 3`, `node_count = 3`)

| Line | Approx / month |
|---|---|
| 3 NAT gateways | ~$99 |
| 3 × `t3.small` | ~$45 |
| Network load balancer | ~$16 |
| KMS key | ~$1 |
| EBS, S3, flow logs | a few dollars |
| **Total** | **~$160/month, ~$0.22/hour** |

### The AWS lever: `az_count`

**It is the dominant cost, and it is not the node count.**
`terraform/aws/network.tf` creates one NAT gateway per availability zone,
each with an hourly charge plus data processing. At defaults they are
roughly 60% of the bill — more than the Vault nodes.

```bash
export TF_VAR_az_count=2
```

Two zones cuts the estimate to ~$128/month and still exercises Raft
`auto_join`, auto-unseal, the load balancer, and the Ansible handoff.

**Two is the floor, not one.** `terraform/aws/variables.tf` requires
`az_count` between 2 and 4, so `az_count=1` is rejected before
anything is created — this document recommended it for several releases
and it never worked. `terraform/azure/variables.tf` enforces the same
floor on `availability_zones`, for the reason both give: a cluster that
cannot survive losing a zone is not the architecture described here.

So the lever saves less than it looks like it should — one NAT gateway,
about $33/month. Use `az_count=2` for a first apply; if it works, the
second apply at `az_count=3` is the interesting one.

### Azure, at defaults (`availability_zones = ["1","2","3"]`, `node_count = 3`)

| Line | Approx / month |
|---|---|
| 1 NAT gateway | ~$33 |
| 3 × `Standard_B2s` | ~$90 |
| 3 × 64 GB Premium OS disk | ~$27 |
| Standard load balancer | ~$18 |
| Key Vault, storage, flow logs | a few dollars |
| **Total** | **~$170/month** |

**The lever is not the zone count.** `terraform/azure/network.tf` creates
one NAT gateway for the whole VNet rather than one per zone, so zone
spread is free here and shrinking `availability_zones` saves nothing.
`--az-count` does nothing on this profile and the pre-flight says so.

The largest line is compute, and `node_count` cannot go below 3 and stay
a Raft majority. That leaves size: `vm_size = "Standard_B1ms"` roughly
halves the compute line and `os_disk_size_gb = 32` halves the disk line,
at the cost of giving Vault less memory than the thing it is meant to
demonstrate. For a few hours that trade is fine.

Worth noticing that the two profiles land in the same range and get there
differently: on AWS the network is the bill, on Azure the compute is.
Cost-cutting advice does not transfer between them.

### The real risk is not the apply

At ~$0.22/hour at defaults, an afternoon of testing is a few dollars.
**An apply left
running over a weekend is $35, and an apply forgotten is $160/month
indefinitely.** Set a calendar reminder before you start, not after.

---

## The apply sequence

### AWS

```bash
# In the environment, so the pre-flight checks what the apply will use.
export TF_VAR_az_count=2 TF_VAR_ssh_key_name=your-key
./scripts/preflight-cloud.sh --cloud aws

# Once per account, before the first apply. Creates the bucket the next
# command keeps its state in — see terraform-state.md.
terraform -chdir=terraform/aws/bootstrap init
terraform -chdir=terraform/aws/bootstrap apply
terraform -chdir=terraform/aws/bootstrap output -raw backend_config \
    > terraform/aws/backend.hcl

terraform -chdir=terraform/aws init -backend-config=backend.hcl

# Again: the first run could not plan without the backend.
./scripts/preflight-cloud.sh --cloud aws

terraform -chdir=terraform/aws apply
./scripts/terraform-to-ansible.sh --cloud aws   # outputs -> group_vars

# Issued now, not before: the filenames follow inventory_hostname, which
# is an instance id. See deployment.md#certificates.
./scripts/generate-cloud-certs.sh --cluster-name vault-reference

# --private-key is not optional: the SSM tunnel carries the session, it
# does not authenticate you. Without it every host fails with
# "Permission denied (publickey)" after the tunnel connects, which reads
# like a tunnel problem and is not. See deployment.md#reaching-the-nodes
# for that and for the boto3 the inventory plugin needs.
cd ansible && ansible-playbook -i inventory/aws_ec2.yml \
    --private-key ~/.ssh/<your-key>.pem playbooks/site.yml
cd ..

# So a node the autoscaling group launches later signs its own
# certificate at boot. Item 10 is where that gets watched.
./scripts/publish-bootstrap-ca.sh --cluster-name vault-reference

# Vault ships cleanup_dead_servers = false, so a replaced node stays a
# voter forever and item 9's refresh walks the cluster out of quorum.
# This sequence did not run it until 2026-09-24, which is why item 10
# left a dead voter behind that afternoon. Once per cluster.
./scripts/configure-autopilot.sh
```

### Azure

```bash
./scripts/preflight-cloud.sh --cloud azure

# Once per subscription, before the first apply.
terraform -chdir=terraform/azure/bootstrap init
terraform -chdir=terraform/azure/bootstrap apply
terraform -chdir=terraform/azure/bootstrap output -raw backend_config \
    > terraform/azure/backend.hcl

terraform -chdir=terraform/azure init -backend-config=backend.hcl
terraform -chdir=terraform/azure apply \
    -var "ssh_public_key=$(cat ~/.ssh/id_ed25519.pub)"
./scripts/terraform-to-ansible.sh --cloud azure  # outputs -> group_vars
cd ansible && ansible-playbook -i inventory/azure_rm.yml playbooks/site.yml
```

`ssh_public_key` has no default and Azure will not create a Linux scale
set without either a key or a password, so this profile cannot produce
the unreachable cluster its AWS counterpart can.

`terraform/aws/audit-anchors` is a third root module, applied the same
way and equally once — but only if you want the audit anchors shipped off
the box. It is deliberately not part of either sequence above: it belongs
in a different account from the cluster if you can manage one, and
read **AWS: the audit anchor bucket cannot be emptied at all** under
Tearing down before applying it. See [audit.md](audit.md).

The bootstrap step is once per account or subscription, not once per
cluster — one bucket holds every cluster's state, separated by key. Skip
it and `init` fails naming the bucket that is missing, which is the
failure you want: the alternative, a backend pointing at nothing that
quietly creates an empty state, produces a `plan` offering to build a
cluster you already have.

Terraform brings up infrastructure and cloud-init starts Vault.
Ansible configures what a running cluster needs: snapshots, audit
devices, PKI node certificates, hardening.

Note that `terraform-to-ansible.sh` writes **group_vars, not an
inventory**. The inventory is dynamic (`ansible/inventory/aws_ec2.yml`) and
discovers instances by tag, because a static inventory goes stale the
moment the scale set replaces a node — and goes stale silently. That
distinction matters for the next section: they are two separate things
to verify, and only one of them is a file you can read.

---

## The verification checklist

This is the point of the exercise. Each item is a claim this repository
currently makes **without evidence** — it passes tests against shims or
mocked providers, and has never been observed against a real cloud API.

Work top to bottom. The order is deliberate: each item depends on the
ones above it, so a failure tells you where the chain broke rather than
leaving you with a cluster that does not work for unclear reasons. The
destructive checks are last, after everything non-destructive has been
recorded.

Record the actual output. "It worked" is not evidence; a pasted
`vault status` is.

### 1. The instance boots and Vault starts

*Claimed by:* `terraform/aws/templates/user-data.sh.tftpl`,
`terraform/azure/templates/cloud-init.sh.tftpl`
*Never verified:* the template renders to a valid script on a real AMI

```bash
ssh ec2-user@<node>
sudo cloud-init status --long        # expect: status: done
sudo systemctl status vault
sudo journalctl -u vault --no-pager | head -50
```

**Failure looks like:** cloud-init reports `error`, or Vault is not
installed at all. Everything below depends on this.

**On Azure** the admin user is `azureuser` (`admin_username`), and
cloud-init writes its transcript somewhere else:

```bash
ssh azureuser@<node>
sudo cloud-init status --long
sudo tail -50 /var/log/cloud-init-output.log
sudo systemctl status vault
```

Getting to the node is its own problem. The AWS profile leaves nodes
reachable through SSM Session Manager with no inbound port 22; the Azure
profile has no equivalent, so decide on a bastion or Azure Bastion before
you need one, not after the cluster is up and unreachable.

### 2. Auto-unseal, with no human involved

*Claimed by:* `docs/auto-unseal.md`, the `seal` stanza in the templates
*Never verified:* the instance role actually grants what KMS needs

```bash
vault status        # expect: Sealed = false, Seal Type = awskms
```

**This is the highest-value single check in the list.** It proves the
instance profile, the KMS key policy, and the seal configuration all
agree — three things configured in three different files that have never
been reconciled against a real API.

**Failure looks like:** Vault running but sealed, with an
`AccessDenied` from KMS in the journal.

**On Azure** the expected value is `Seal Type = azurekeyvault`, and the
three things that must agree are different ones: the user-assigned
managed identity, the Key Vault **access policy**, and the `seal` stanza.
There is no instance profile involved.

```bash
vault status        # expect: Sealed = false, Seal Type = azurekeyvault
az keyvault key show --vault-name <kv> --name <key> -o table
```

**Failure looks like** a 403 from Key Vault in the journal. Ordering is
the thing nobody has watched: `terraform/azure/compute.tf` creates the
access policy before the scale set precisely so the first boot can
unseal, and that dependency has been reasoned about and never observed.

### 3. Raft `auto_join` finds the other nodes

*Claimed by:* the `retry_join` stanza
*Never verified:* **this is where a real bug was already found.** Azure's
go-discover provider rejects a mix of `tag_name`/`tag_value` and
`resource_group`; the merged configuration passed both until it was
fixed by reading the provider source. That bug was invisible to every
test we have, because a shim written from the same assumption as the
code confirms the assumption.

```bash
vault operator raft list-peers
```

**Expect:** every node, exactly one `leader`, the rest `follower`, all
`voter`.

**Failure looks like:** one node listing only itself — each node formed
its own single-node cluster and each thinks it is the leader. Check the
journal for the discovery query and what it matched. On AWS that query is
over EC2 instance tags.

**On Azure it is not a tag query at all.** `retry_join` matches on
resource group plus scale set name, because go-discover rejects a mix of
the two selector styles — which is the bug above, and why the
configuration looks the way it does. Two things follow that do not apply
to AWS:

- **It requires Uniform orchestration.** A Flexible scale set returns
  nothing and reports no error, so the symptom is three single-node
  clusters and a clean log.
- **Zero instances is not an error to go-discover.** An empty result and
  a result it never asked for look identical from the journal, so read
  the query itself rather than only its outcome.

### 4. The load balancer keeps standbys in the pool

*Claimed by:* `terraform/aws/lb.tf:39-48` (`matcher = "200,429"`)
*Never verified:* that a real target group treats 429 as healthy

```bash
aws elbv2 describe-target-health --target-group-arn <arn>
```

**Expect:** every node `healthy` — not just the leader.

This is the check people skip, and it fails quietly. If the matcher were
wrong, standbys would show `unhealthy`, the cluster would still serve
every request through the leader, and nothing would look broken until
the leader went away.

```bash
# 429 on a standby, 200 on the leader
curl -s -o /dev/null -w '%{http_code}\n' \
    https://<node>:8200/v1/sys/health
```

Note what this does *not* prove. `terraform/aws/lb.tf` probes
`/v1/sys/health?standbyok=true`, so a healthy standby answers 200 and the
`200,429` matcher never fires. The matcher is a second line of defence
against a path that stops sending `standbyok`; the bare `curl` above is
the only place you will see a 429 at all.

**On Azure this check is a different assertion, not a different command.**
Azure health probes accept 200-299 and nothing else — there is no matcher
to get wrong. Standbys stay in the pool *only* because `standbyok=true`
makes Vault answer 200, so what needs proving is that response:

```bash
# 200 on a standby, because of standbyok — not 429
curl -s -o /dev/null -w '%{http_code}\n' \
    'https://<node>:8200/v1/sys/health?standbyok=true'
```

If that ever returned 429, Azure would eject every standby and the leader
would serve everything, with nothing in the load balancer saying why.

Reading it back from the load balancer is the awkward part: Azure has no
`describe-target-health` equivalent. The closest is the `DipAvailability`
probe metric:

```bash
az monitor metrics list --resource <lb-resource-id> \
    --metric DipAvailability --interval PT1M -o table
```

That aggregates rather than listing per-instance state, so treat the
per-node `curl` as the real check and the metric as corroboration. **I
have not run this command against a live subscription** — verify it
before relying on the invocation.

### 5. The Ansible handoff — two separate things

*Claimed by:* `scripts/terraform-to-ansible.sh`,
`ansible/inventory/aws_ec2.yml`
*Never verified:* against real Terraform outputs, or a real cloud API

**5a. group_vars are generated from real outputs.** The script is tested
against a saved `terraform output -json`, never a live one.

```bash
./scripts/terraform-to-ansible.sh --cloud aws
cat ansible/inventory/group_vars/vault_nodes.yml
```

**Expect** the KMS key id, region and snapshot bucket to be populated.
**Failure looks like** empty values, because an output name drifted.

**5b. The dynamic inventory actually finds the nodes.** This is the half
that cannot be tested locally at all — it queries the cloud API.

```bash
cd ansible
ansible-inventory -i inventory/aws_ec2.yml --list
ansible -i inventory/aws_ec2.yml vault_nodes -m ping
```

**Expect** every node. **Failure looks like** an empty group, which means
the inventory plugin's tag filter and the tag Terraform actually applied
disagree — the same class of bug as the Azure `auto_join` mismatch in
item 3, in a second place, and equally invisible to local tests.

If `ping` fails but the inventory lists hosts, check
`session-manager-plugin` and your own `ssm:StartSession` before anything
else: `ansible_host` is the instance id and the connection is tunnelled,
so there is no IP to blame. That tunnel reached all three nodes from a
laptop outside the VPC on 2026-09-17.

**On Azure**, same two halves, different commands:

```bash
./scripts/terraform-to-ansible.sh --cloud azure
cat ansible/inventory/group_vars/vault_nodes.yml   # same path for both clouds
cd ansible
ansible-inventory -i inventory/azure_rm.yml --list
ansible -i inventory/azure_rm.yml vault_nodes -m ping
```

**And here 5a and 5b are genuinely independent, which they are not on
AWS.** The inventory filters `tags.VaultCluster`; Raft discovery
enumerates the scale set and never looks at tags. So an empty inventory
says nothing about whether the cluster formed, and a cluster that formed
is no evidence the inventory works. Check both, and do not read either
result as covering the other.

### 6. Snapshots authenticate with the instance role and reach the bucket

*Claimed by:* `ansible/roles/vault_snapshots`, `docs/disaster-recovery.md`
*Never verified:* IMDS / managed-identity auth, which cannot exist locally

```bash
sudo systemctl list-timers vault-snapshot.timer
sudo systemctl start vault-snapshot.service
sudo journalctl -u vault-snapshot --no-pager | tail -20
aws s3 ls s3://<bucket>/
```

**Expect an object in the bucket.** A green systemd unit is not
evidence — this repository has already shipped a snapshot job that
exited 0 on every node while taking no snapshot at all.

Note that the timer runs on **every** node and only the leader takes a
snapshot; standbys logging that they skipped is correct behaviour.

**On Azure** the destination is a blob container, and the identity is a
user-assigned managed identity rather than an instance role:

```bash
sudo systemctl start vault-snapshot.service
sudo journalctl -u vault-snapshot --no-pager | tail -20
az storage blob list --account-name <acct> -c <container> \
    --auth-mode login -o table
```

`--auth-mode login` is not optional here. `terraform/azure/storage.tf`
sets `shared_access_key_enabled = false`, so there is no account key to
fall back on — if the role assignment is wrong, the upload fails and no
amount of fetching keys will work around it. That is the point of the
setting, and it makes this check sharper than its AWS counterpart.

### 7. Restoring a snapshot actually works

*Claimed by:* `docs/disaster-recovery.md`
*Never verified:* on a cloud cluster, where auto-unseal changes the
restore path

Do **not** use `scripts/dr-drill.sh` here. It drives the local Docker
Compose profile and tears it down; it is not a cloud tool. The cloud
equivalent is the same idea run by hand:

```bash
vault kv put secret/dr-canary value=before-restore
vault operator raft snapshot save /tmp/cloud.snap

vault kv delete secret/dr-canary          # the "disaster"
vault operator raft snapshot restore /tmp/cloud.snap

vault kv get secret/dr-canary             # expect: before-restore
```

**Reading the canary back is the test.** A restore that silently did
nothing still leaves a healthy unsealed cluster, so "the command
succeeded" proves nothing.

What this specifically checks that the local drill cannot: **the restore
path when the seal is KMS rather than Transit.** The snapshot is
encrypted under the auto-unseal key, so a restore needs both the
snapshot and a live KMS key — which is why `teardown-cloud.sh` reports
the KMS key surviving destroy rather than treating it as litter.

**A backup nobody has restored is not a backup.** Do this while you still
have a cluster you do not mind breaking — which is exactly now, and
never again once it is production.

### 8. PKI node certificates and audit devices

*Claimed by:* `ansible/roles/vault_pki`, `ansible/roles/vault_audit`

```bash
vault audit list -detailed
sudo ls -l /etc/vault.d/audit/          # vault-audit.log, and the secondary
echo | openssl s_client -connect <node>:8200 2>/dev/null \
    | openssl x509 -noout -issuer -dates
```

**Expect** the issuer to be the Vault PKI CA, not the self-signed
bootstrap certificate, and the audit log to contain entries with hashed
values rather than plaintext.

### 9. An instance refresh keeps quorum (AWS)

The upgrade an AWS operator would actually run, and the one check that
settles whether the autopilot fix works. Bump `vault_version` and apply,
which replaces all three nodes through the scaling group:

```bash
terraform -chdir=terraform/aws apply -var 'vault_version=<newer>'
aws autoscaling describe-instance-refreshes \
    --auto-scaling-group-name <asg> --query 'InstanceRefreshes[0].Status'
```

**Expect,** watching `vault operator raft list-peers` throughout:

- the voter count rises to four and falls back to three, once per node,
  and **never leaves three live nodes facing a quorum of three**
- each dead voter disappears within about five minutes of its instance
  going away — that is `dead_server_last_contact_threshold`, and it has
  to complete inside the ASG's `instance_warmup` of 600s or the next
  node is terminated before the last dead voter is gone
- the cluster serves reads and writes throughout, apart from a brief
  election each time the leader is the node being replaced

**If the voter count only ever rises**, autopilot is not pruning and
`scripts/configure-autopilot.sh` has not been run against this cluster —
run it and start again. That is the failure this item exists to catch,
and before the autopilot work it was the guaranteed outcome: the refresh
loses quorum partway through the *second* node, with the ASG reporting
healthy instances the whole time. See
[rolling-upgrades.md](rolling-upgrades.md) for the arithmetic.

Pruning itself has been observed locally: `tests/autopilot-prune` runs
this exact sequence against a real cluster, using a spare node with a
`node_id` the cluster has not seen, and watches the dead voter go. What
has *not* been observed is an autoscaling group producing that sequence —
in that order, with instance warmup and health checks in the way, and
with the leader among the nodes being replaced. That is what this item
settles.

**On Azure there is nothing to run.** The scale set is
`upgrade_mode = "Manual"`, so no refresh happens; the canonical upgrade
there is `scripts/vault-upgrade.sh` against the instances. The autopilot
setting still matters, because a scale set that reconciles a deleted
instance produces a new VM name and therefore a new voter.

### 10. Destructive: losing a node (do this last)

Nothing is recovered after this. Everything above should already be
recorded.

```bash
aws ec2 terminate-instances --instance-ids <leader-instance-id>
```

**Expect,** within a couple of minutes:

- `vault operator raft list-peers` shows a new leader elected from the
  remaining nodes
- the load balancer drops the dead target
- the Auto Scaling group launches a replacement
- **the replacement issues its own certificate at boot**, from the CA
  `publish-bootstrap-ca.sh` put in SSM — `grep bootstrap-cert
  /var/log/user-data.log` on it should end in `Wrote /etc/vault.d/tls/
  vault.crt` — and then **auto-unseals and joins Raft with no human
  involvement**, which is items 2 and 3 proving themselves under the only
  conditions that matter

This is the check that justifies the whole architecture. If the
replacement node joins on its own, the cluster is self-healing. If it
comes up sealed, auto-unseal works at apply time and not at recovery
time, which is the failure mode that matters most and the one least
likely to be noticed.

Note that at `az_count=2` the replacement may land in either zone, so
what this tests is node loss. Zone loss is a different exercise and not
one you can stage from the CLI.

**On Azure the mechanism is reconciliation, not replacement**, and the
timing is different enough to change what "expect" means:

```bash
az vmss list-instances -g <rg> -n <vmss> -o table
az vmss delete-instances -g <rg> -n <vmss> --instance-ids <id>
```

The scale set restores `instances = node_count` because that is the
declared state — there is no launch template being invoked. Two
consequences worth knowing before you start a stopwatch:

- `automatic_instance_repair` carries a 30-minute grace period, so a
  replacement that has not appeared in two minutes is not yet a failure.
  The AWS expectation of "a couple of minutes" does not transfer.
- `zone_balance = true` means Azure may **refuse** to place the
  replacement rather than place it in the wrong zone. A scale set stuck
  below `node_count` with a placement error is a different outcome from
  a node that came back sealed, and only one of them is about Vault.

The claim being settled is the same: a replacement node auto-unseals and
rejoins Raft with nobody watching.

---

## Tearing down

```bash
./scripts/teardown-cloud.sh --cloud aws
./scripts/teardown-cloud.sh --cloud azure
```

**Do not just run `terraform destroy`.** It fails, and it fails *after*
destroying some things, which leaves a half-torn-down deployment quietly
costing money while looking cleaned up.

### AWS: the snapshot bucket blocks destroy

`terraform/aws/storage.tf` enables versioning and does not set
`force_destroy`. Once Vault has written a single snapshot, destroy fails
with `BucketNotEmpty`.

Versioning means `aws s3 rm --recursive` is not enough either — it writes
delete markers, which are themselves objects, so the bucket is still not
empty. Both the object versions and the delete markers have to go. The
teardown script does that, paging through both lists, before it runs
destroy.

### AWS: the KMS keys are scheduled, not deleted

Both sit in `PendingDeletion`, costing nothing, and either can be
cancelled if you destroyed by mistake — which is the point of the window.
The windows differ deliberately (`terraform/aws/main.tf`):
`aws_kms_key.vault_data`, which encrypts root volumes, waits 7 days;
`aws_kms_key.vault_autounseal`, which every snapshot is sealed under,
waits 30. The teardown on 2026-09-17 left one of each, and the state
bucket's own key, which is not scheduled at all.

### Azure: the Key Vault cannot be purged, by anyone

`terraform/azure/main.tf:63-64` sets `purge_protection_enabled = true`
and `soft_delete_retention_days = 90`. **Purge protection cannot be
turned off once enabled.** The vault is retained for 90 days and nobody,
including you, can purge it sooner.

That is deliberate: losing the auto-unseal key makes every Raft snapshot
permanently undecryptable, and a snapshot you cannot decrypt is not a
backup. The cost is that **each apply of the Azure profile leaves a
soft-deleted Key Vault behind for 90 days**, counting against the
subscription's quota. The name carries a random suffix, so re-applying
still works.

If you plan to apply the Azure profile repeatedly, know this before the
first one, not after the fourth.

### AWS: the audit anchor bucket cannot be emptied at all

`terraform/aws/audit-anchors` is optional — nothing applies it unless you
do — and it is the one piece here whose teardown cost is permanent rather
than merely awkward.

Every anchor is written under a COMPLIANCE object-lock retention, which
**cannot be shortened, overridden or deleted by anyone, including the
account root**, until it expires. The default is 365 days. So the bucket
cannot be emptied, `force_destroy` would not help, and the teardown
script does not try: there is no sequence of API calls that removes those
objects.

That is the property being bought, not a defect — an attacker holding
every credential in this repository cannot erase an anchor either. But it
means applying this module to an account is a decision with a one-year
tail, so apply it with a retention you are willing to pay for. Anchors
are three fields of text and the bill is small; "small" is why it is
affordable, not a reason to skip choosing.

`--retention-days` on `scripts/ship-anchors.sh` sets it per object at
write time. Use a short one the first time you try this.

### The state bucket survives, and should

Tearing down a cluster does not remove the bucket or storage account
holding its state. That is deliberate: it belongs to the account, not to
the cluster, it holds the state of every other cluster in the account,
and it is protected by `prevent_destroy` so a `terraform destroy` in a
bootstrap directory fails rather than succeeding quietly.

Empty, it costs about a dollar a month — almost all of it the
customer-managed KMS key the state is encrypted with, not the storage.
Leave it: the next apply in this account reuses it, and removing it means
editing the configuration first, which is the deliberate act it should
be. See [terraform-state.md](terraform-state.md).

### Then check the console

A destroy that reports success can still leave resources it never had in
state — anything created by hand, or by a partial apply that was
interrupted. The script says this too. It is worth thirty seconds.

---

## After the session

Whatever happened, the results belong in the repository. If an item
passed, the claim it verifies stops being aspirational and
[the roadmap](roadmap.md) can say so. If an item failed, that is a real
bug that no amount of local testing was going to find — which is the
entire reason for doing this.

The Azure `auto_join` bug is the precedent: it survived shim tests,
`terraform test`, and review, because every one of those was written from
the same assumption as the code. It took reading the provider source to
find. Some of the items above will do the same.

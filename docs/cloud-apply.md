# The cloud apply

**Neither cloud profile in this repository has ever been applied.**

Everything else here is tested — 80 assertions against a real three-node
cluster, promtool unit tests on the alert rules, `terraform test` against
mocked providers. But mocked providers confirm that the configuration is
*well-formed*, not that AWS accepts it. The gap between those two things
is the last real blocker on the [roadmap](roadmap.md), and it is the
reason this document exists.

The first person to apply one of these profiles is spending money to find
out what is wrong. This is about making that session produce the maximum
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
Six of the nine do — 1, 2, 4, 5, 6 and 9 — and the absence of one means
the item is genuinely identical, not that the Azure case was skipped.

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

## Before you apply

```bash
./scripts/preflight-cloud.sh --cloud aws
```

It checks tooling, resolves your identity (and prints *which account* you
are about to spend money in), validates the inputs that fail late,
estimates cost, names what a teardown will not remove, and runs
`terraform plan`. It applies nothing. It exits non-zero only on
failures — warnings are things to have read, not things to fix.

Four failures it exists to catch, all of which cost money to discover
otherwise:

| Check | Why it is worth catching early |
|---|---|
| `ssh_key_name` is empty | **The apply succeeds** and produces instances nobody can log into. Every item in the checklist below needs a shell on a node. |
| The key pair does not exist in this region | The apply fails at instance launch — after the VPC and NAT gateways are already billing. |
| Elastic IP quota | One EIP per NAT gateway, one NAT gateway per AZ, default limit 5. Three zones plus anything already in the account can exceed it. |
| Azure role assignment permission | The profile creates a role assignment, which needs Owner or User Access Administrator. Contributor applies most of the profile and *then* fails. |

The `ssh_key_name` one is not hypothetical: `terraform/aws/variables.tf`
ships it empty, so the default AWS apply produces an unreachable cluster.

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
terraform apply -var 'az_count=2'
```

Two zones cuts the estimate to ~$128/month and still exercises Raft
`auto_join`, auto-unseal, the load balancer, and the Ansible handoff.

**Two is the floor, not one.** `terraform/aws/variables.tf` requires
`az_count` between 2 and 4, so `-var 'az_count=1'` is rejected before
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
./scripts/preflight-cloud.sh --cloud aws --az-count 2
terraform -chdir=terraform/aws apply \
    -var 'az_count=2' -var 'ssh_key_name=your-key'
./scripts/terraform-to-ansible.sh --cloud aws   # outputs -> group_vars
cd ansible && ansible-playbook -i inventory/aws.yml playbooks/site.yml
```

### Azure

```bash
./scripts/preflight-cloud.sh --cloud azure
terraform -chdir=terraform/azure apply \
    -var "ssh_public_key=$(cat ~/.ssh/id_ed25519.pub)"
./scripts/terraform-to-ansible.sh --cloud azure  # outputs -> group_vars
cd ansible && ansible-playbook -i inventory/azure.yml playbooks/site.yml
```

`ssh_public_key` has no default and Azure will not create a Linux scale
set without either a key or a password, so this profile cannot produce
the unreachable cluster its AWS counterpart can.

Terraform brings up infrastructure and cloud-init starts Vault.
Ansible configures what a running cluster needs: snapshots, audit
devices, PKI node certificates, hardening.

Note that `terraform-to-ansible.sh` writes **group_vars, not an
inventory**. The inventory is dynamic (`ansible/inventory/aws.yml`) and
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
`ansible/inventory/aws.yml`
*Never verified:* against real Terraform outputs, or a real cloud API

**5a. group_vars are generated from real outputs.** The script is tested
against a saved `terraform output -json`, never a live one.

```bash
./scripts/terraform-to-ansible.sh --cloud aws
cat ansible/group_vars/vault_nodes.yml
```

**Expect** the KMS key id, region and snapshot bucket to be populated.
**Failure looks like** empty values, because an output name drifted.

**5b. The dynamic inventory actually finds the nodes.** This is the half
that cannot be tested locally at all — it queries the cloud API.

```bash
cd ansible
ansible-inventory -i inventory/aws.yml --list
ansible -i inventory/aws.yml vault_nodes -m ping
```

**Expect** every node. **Failure looks like** an empty group, which means
the inventory plugin's tag filter and the tag Terraform actually applied
disagree — the same class of bug as the Azure `auto_join` mismatch in
item 3, in a second place, and equally invisible to local tests.

If `ping` fails but the inventory lists hosts, it is emitting private IPs
reachable only from inside the VPC. That is not a bug; run Ansible from a
bastion or a node.

**On Azure**, same two halves, different commands:

```bash
./scripts/terraform-to-ansible.sh --cloud azure
cat ansible/group_vars/vault_nodes.yml   # same path for both clouds
cd ansible
ansible-inventory -i inventory/azure.yml --list
ansible -i inventory/azure.yml vault_nodes -m ping
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

### 9. Destructive: losing a node (do this last)

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
- **the replacement auto-unseals and joins Raft with no human
  involvement** — which is items 2 and 3 proving themselves under the
  only conditions that matter

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

### AWS: the KMS key is scheduled, not deleted

`deletion_window_in_days = 7` (`terraform/aws/main.tf:34`). The key sits
in `PendingDeletion` for a week. It costs nothing there, and it can be
cancelled if you destroyed by mistake — which is the point of the window.

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

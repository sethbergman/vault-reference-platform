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

### The one lever that matters

**`az_count` is the dominant cost, and it is not the node count.**
`terraform/aws/network.tf` creates one NAT gateway per availability zone,
each with an hourly charge plus data processing. At defaults they are
roughly 60% of the bill — more than the Vault nodes.

```bash
terraform apply -var 'az_count=1'
```

One zone cuts the estimate to ~$95/month and still exercises Raft
`auto_join`, auto-unseal, the load balancer, and the Ansible handoff. It
does **not** exercise zone-redundancy, which is the one thing three zones
buy you and the one thing hardest to verify anyway.

Use `az_count=1` for a first apply. If it works, the second apply at
`az_count=3` is the interesting one.

### The real risk is not the apply

At ~$0.22/hour, an afternoon of testing is a few dollars. **An apply left
running over a weekend is $35, and an apply forgotten is $160/month
indefinitely.** Set a calendar reminder before you start, not after.

---

## The apply sequence

```bash
./scripts/preflight-cloud.sh --cloud aws --az-count 1
terraform -chdir=terraform/aws apply \
    -var 'az_count=1' -var 'ssh_key_name=your-key'
./scripts/terraform-to-ansible.sh --cloud aws   # outputs -> group_vars
cd ansible && ansible-playbook -i inventory/aws.yml playbooks/site.yml
```

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
journal for the discovery query and what it matched. On AWS this is EC2
instance tags; **on Azure, tag mode matches the network interface's
tags, not the VM's.**

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

Note that at `az_count=1` the ASG replaces into the same zone, so this
tests node loss and not zone loss.

---

## Tearing down

```bash
./scripts/teardown-cloud.sh --cloud aws
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

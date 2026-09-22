# Deployment

## Local (Docker Compose)

The fastest way to try the reference topology on a laptop.

```bash
make deploy       # 3-node Vault cluster, auto-unsealed
make status        # check cluster/unseal status
make destroy       # tear it down
```

The cluster serves TLS. `bootstrap-dev-cluster.sh` calls
`scripts/generate-dev-certs.sh` first, which issues a local CA and a
certificate per node into `docker/dev/tls/` — gitignored, and regenerated
with `--force` if they ever need replacing. Clients need the CA:

```bash
export VAULT_ADDR=https://127.0.0.1:8200
export VAULT_CACERT=$PWD/docker/dev/tls/ca.crt
```

`make deploy` runs `scripts/bootstrap-dev-cluster.sh`, which brings up a
standalone Vault instance (`vault-unseal`) as a Transit auto-unseal
backend, then starts and initializes the 3-node cluster against it — the
same `seal` stanza shape the AWS/Azure profiles below use, just pointed at
something that needs no cloud account. `vault-unseal` itself is still
unsealed the manual, Shamir way — something has to be the root of trust.
See [`docs/auto-unseal.md`](auto-unseal.md) for the full picture.

## Before either cloud profile

**Neither has ever been applied to a real account.** The AWS profile is
applied and destroyed against an emulated AWS API on every PR, which
settles that it applies at all; nothing in that run boots, so it says
nothing about the cluster. Run the pre-flight first — it checks
credentials, the inputs that fail late, quota and cost, and applies
nothing:

```bash
export TF_VAR_ssh_key_name=your-key   # and any other input, the same way
./scripts/preflight-cloud.sh --cloud aws
```

It checks the values `terraform` in that shell will use, so set inputs as
`TF_VAR_*` rather than `-var`. It cannot plan until the backend is
initialised, so run it again after `init`.

Then read [`cloud-apply.md`](cloud-apply.md), which lists what to verify
while the cluster is up and how to tear it down afterwards.
`terraform destroy` alone does not fully work on either profile.

Both profiles keep state in a bucket or storage account that has to
exist first, created by a separate configuration under
`terraform/<cloud>/bootstrap`. That is the first command in each section
below, and it is run once per account rather than once per cluster —
[terraform-state.md](terraform-state.md) explains why it is separate and
what happens if you skip it.

## AWS

```bash
# Once per account and region. Creates the bucket the profile keeps its
# state in — the profile's backend block is empty and cannot initialise
# until this exists. See terraform-state.md.
terraform -chdir=terraform/aws/bootstrap init
terraform -chdir=terraform/aws/bootstrap apply
terraform -chdir=terraform/aws/bootstrap output -raw backend_config \
    > terraform/aws/backend.hcl

cd terraform/aws
terraform init -backend-config=backend.hcl
terraform plan -out=plan.tfplan
terraform apply plan.tfplan
```

Provisions:

- A VPC with public and private subnets across `az_count` availability
  zones, one NAT gateway per AZ, and an S3 gateway endpoint
- An autoscaling group of Vault nodes in the private subnets, sized to
  `node_count`
- A **network** load balancer on port 8200, internal by default
- A KMS key for auto-unseal, plus the instance role that uses it
- An S3 bucket for Raft snapshots, versioned and lifecycle-expired

### Why a network load balancer

[`docs/security.md`](security.md) commits to TLS terminating at the Vault
process rather than being offloaded. An application load balancer can't
do that — it terminates the client's TLS and opens a separate connection
to the backend, so plaintext exists inside the load balancer. An NLB
forwards TCP untouched, so the client's TLS session runs end to end with
Vault and the load balancer never holds a certificate or sees a token.

The health check still speaks HTTPS to `/v1/sys/health`, accepting both
`200` (active) and `429` (standby), so every unsealed node stays in the
pool and writes get forwarded to the leader.

### Nodes need TLS certificates before they will start

The user-data writes a Vault config with a TLS listener but does **not**
issue certificates — how you get them is deployment-specific (an internal
CA, ACM Private CA, or Vault's own PKI engine once a first cluster
exists). Until they are in place at `/etc/vault.d/tls/`, Vault will not
start. That is deliberate: a Vault serving plaintext is worse than one
that refuses to boot.

Delivering them is what the Ansible layer is for; see
[Handing off to Ansible](#handing-off-to-ansible) below.

### AWS running costs

Three NAT gateways at roughly $32/month each are the bulk of the idle
cost. Dropping `az_count` to 2, or sharing a single NAT, trades that
against AZ independence.

## Azure

```bash
# Once per subscription and region, for the same reason as AWS.
terraform -chdir=terraform/azure/bootstrap init
terraform -chdir=terraform/azure/bootstrap apply
terraform -chdir=terraform/azure/bootstrap output -raw backend_config \
    > terraform/azure/backend.hcl

cd terraform/azure
terraform init -backend-config=backend.hcl
terraform plan -out=plan.tfplan \
  -var="ssh_public_key=$(cat ~/.ssh/id_ed25519.pub)"
terraform apply plan.tfplan
```

Mirrors the AWS layout: a VNet with separate node and load balancer
subnets, a VM scale set sized to `node_count`, a Standard load balancer
on 8200, Key Vault auto-unseal, and a storage account for Raft snapshots.
`ssh_public_key` is required — Azure will not create a Linux scale set
with neither a password nor a key.

Same `inventory/group_vars/vault_nodes_azure.yml.example` step as AWS before
running the playbook.

### Differences from the AWS profile

The two are meant to behave the same, but the mechanisms differ in ways
worth knowing:

- **Subnets are regional, not zonal.** One subnet spans the region and
  zone spread is a property of the scale set, so there is a single node
  subnet rather than one per zone.
- **The health probe has no status-code matcher.** Azure probes accept
  200-299 and nothing else, while Vault answers 429 on a standby. The
  probe passes `standbyok=true` so Vault answers 200 for a healthy
  standby instead — without it Azure ejects every standby and only the
  leader serves traffic.
- **Outbound needs an explicit NAT gateway.** Azure's default outbound
  access is being retired, and relying on it means nodes lose internet
  access on a date outside your control.
- **Names are length-limited and globally unique.** Key Vault and storage
  account names are capped at 24 characters across all of Azure, so both
  are truncated and given a random suffix rather than derived from
  `cluster_name` alone.

### Azure running costs

The NAT gateway and the Standard load balancer are the bulk of the idle
cost, in the same range as the AWS profile's NAT gateways. Premium OS
disks add to it; `os_disk_size_gb` and `vm_size` are the levers.

## Handing off to Ansible

Terraform builds hosts that cannot serve until something gives them their
certificates and their configuration. That something is the Ansible
layer, and the two halves have to agree on a dozen values — the KMS key
id, the subscription id, the scale set name, the region. Copying them by
hand out of `terraform output` works exactly once.

```bash
./scripts/terraform-to-ansible.sh --cloud aws
```

That reads `terraform output -json` and writes
`ansible/inventory/group_vars/vault_nodes.yml`. Re-run it after any apply rather
than editing the file — a hand edit drifts from the infrastructure it
describes and nothing catches that. It refuses to overwrite an existing
file unless you pass `--force`, and it aborts without writing anything if
an output it needs is missing, rather than emitting a `null` that becomes
a Vault which starts and cannot unseal.

Then run the playbook:

```bash
cd ansible && ansible-playbook -i inventory/aws_ec2.yml playbooks/site.yml
```

Substitute `inventory/azure_rm.yml` for the Azure profile.

### When the group replaces a node

An autoscaling group or scale set replaces an instance without asking,
and the replacement boots with no TLS material. The first real AWS apply
watched Vault refuse to start on it while the cluster carried on without
it — [cloud-apply.md](cloud-apply.md#the-cluster-is-not-self-healing).

**On AWS, publish the bootstrap CA once, after the first playbook run:**

```bash
./scripts/publish-bootstrap-ca.sh --cluster-name <cluster>
```

From then on a node the group launches reads the CA from SSM at boot,
signs its own leaf with the same SANs its peers carry, and starts Vault
— `scripts/issue-bootstrap-cert.sh`, embedded in user-data. Nodes already
running are untouched. This is designed and tested, and has **not** been
watched working on a real cluster; see
[security.md](security.md#a-node-the-autoscaling-group-replaces) for the
tradeoff it makes. Azure has no equivalent yet.

If the CA was never published, or on Azure, recovery is two commands:

```bash
./scripts/generate-cloud-certs.sh --cluster-name <cluster> --add-missing
cd ansible && ansible-playbook -i inventory/aws_ec2.yml playbooks/site.yml \
    --limit <new-instance-id>
```

`--add-missing` signs a leaf for any host in the inventory that has none,
using the CA already in `ansible/files/tls` — the one the running nodes
trust. It rewrites nothing else, refuses a CA belonging to another
cluster, and carries over the extra SANs the existing leaves have, so a
replacement is reachable through the load balancer like its peers. Do not
reach for `--force` here: that mints a new CA, and then every node needs
new material before any node presents it.

`--limit` matters as much. Without it the playbook reconfigures all three
nodes and restarts Vault on each, which is a cluster-wide event in
service of one node.

### Why the inventory is dynamic

`inventory/aws_ec2.yml` and `inventory/azure_rm.yml` discover nodes through the
cloud API by tag, not from a list of addresses. The autoscaling group and
the scale set both replace instances, so a static inventory is wrong the
first time a node is recycled — and wrong *silently*: the playbook
succeeds against hosts that no longer exist and never touches the ones
that do.

On AWS the tag they filter on is the same one Raft's `auto_join` uses, so
cluster formation and configuration management break together rather than
one drifting away from the other.

**On Azure they are independent.** go-discover's Azure provider rejects a
mix of tag and scale-set selectors, so `retry_join` enumerates the scale
set by resource group and name and never looks at tags. An empty
inventory there says nothing about whether the cluster formed, and a
healthy cluster is no evidence the inventory works.

### Reaching the nodes

Nodes sit in private subnets with no public address, and `security.tf`
opens port 22 from nowhere. There is nothing outside the VPC to SSH *to*.

On AWS the inventory resolves that by tunnelling SSH through SSM Session
Manager, which changes neither fact: the agent on the instance holds an
outbound connection to the SSM service, and the `AWS-StartSSHSession`
document carries an ordinary SSH session back down it. No inbound rule,
no public address, no bastion to patch and pay for, and the session is
recorded against the caller's IAM identity rather than against whoever
holds a key.

It is configured in `ansible/inventory/aws_ec2.yml` and needs nothing from
the playbook. Three things it does need, none of which Terraform can
supply:

| Requirement | Where it comes from |
|---|---|
| `session-manager-plugin` on the control machine | Installed separately; the AWS CLI execs it. `scripts/preflight-cloud.sh` warns when it is missing |
| `ssm:StartSession` on *your* identity | Your own IAM. The instance side is already covered — `iam.tf` attaches `AmazonSSMManagedInstanceCore` |
| `ssh_key_name` set on the profile | EC2 puts the public key in `ec2-user`'s `authorized_keys` at boot |

**The third is the one that surprises people.** Session Manager replaces
the network path, not the authentication: what answers at the far end of
the tunnel is still `sshd`, still reading `authorized_keys`. An empty
`ssh_key_name` leaves `aws ssm start-session` — a shell, enough to
inspect a node — and no way to run the playbooks at all.

The tunnel also decides what a host is *called*. `--target` names an
instance to SSM and `ProxyCommand`'s `%h` is whatever `ansible_host`
holds, so `ansible_host` is the instance id. The private IP is not
routable from where the playbook runs; using it would only look correct.

Host keys are `accept-new`, which accepts an unseen key and refuses a
changed one. That reads as weak until you notice what a host is here: the
id is per instance, so a replaced node is a new name with a new key and
is correctly unknown, while a changed key under an id already seen is the
case worth refusing. `StrictHostKeyChecking=no` would accept that too.
It is still trust-on-first-use — verifying properly means reading the key
out of `aws ec2 get-console-output` before the first connection, which
this repository does not automate.

Running from *inside* the VPC — a bastion, a VPN, a CI runner in a
private subnet — wants none of it: set `ansible_host` back to
`private_ip_address` and drop `ansible_ssh_common_args`.

**Azure has no equivalent here.** Its nodes are equally private and its
inventory sets no connection arguments, so reaching them is still the
reader's problem. That is not an oversight being deferred quietly: the
Azure profile has never been applied, and adding an untested tunnel to an
untested profile would make the gap harder to see rather than smaller.

None of this has run against a real account either. It is configuration
with reasoning attached, and `tests/ansible` asserts the values it
produces — that the expressions evaluate at all, that the target is the
instance id, that the document is `AWS-StartSSHSession` and not a plain
shell. What no test here can show is that the tunnel opens.

**What a host is called matters as much as which hosts are found.** An
Ansible inventory is keyed by host name, so two hosts with one name are
one host. `aws_ec2`'s `hostnames` is a list of preferences and it stops
at the first that resolves — and an autoscaling group tags every instance
it launches identically, because a launch template has no per-instance
interpolation. So preferring `tag:Name`, which this file did, named all
three nodes `<cluster>-vault`: they collapsed into whichever instance the
paginator returned last, and `site.yml` configured one node out of three
and exited 0.

It names them by instance id now, which is unique and is also what
`user-data.sh.tftpl` gives Raft as `node_id` — so a host here and a voter
in `vault operator raft list-peers` carry the same name. Azure needed no
change: `azure_rm` defaults to the VM name, which is per instance and is
what its cloud-init uses for `node_id` too.

`tests/preflight-static` asserts both halves, because this is a string
one layer produces and another consumes with nothing validating it in
between — the seam that suite exists for.

### Certificates

The role expects to find certificates on the control machine and copies
them to each node:

```text
ansible/files/tls/ca.crt
ansible/files/tls/<inventory_hostname>.crt
ansible/files/tls/<inventory_hostname>.key
```

Per-node leaves rather than one shared certificate, matching what
`scripts/generate-dev-certs.sh` produces locally. Override
`vault_tls_ca_src`, `vault_tls_cert_src`, and `vault_tls_key_src` to
point elsewhere. The role verifies each certificate actually matches the
host it lands on, because the alternative failure surfaces later as a
Raft join error that reads like a network problem.

**On a cloud profile there is nothing to pre-generate.** The filenames
follow `inventory_hostname`, which is an instance id, and instance ids do
not exist until after the apply. So the certificates are issued between
the apply and the playbook, from the same inventory the playbook will
use:

```bash
./scripts/generate-cloud-certs.sh --cluster-name vault-reference
```

Each leaf carries four things, and each is load-bearing:

| SAN | Who checks it |
|---|---|
| `IP:<private ip>` | the vault role, verifying the certificate it just delivered |
| `DNS:<instance id>` | the common name the PKI role later renews it under |
| `DNS:<cluster>.vault.internal` | every follower, verifying whichever node is leader |
| `DNS:localhost`, `IP:127.0.0.1` | the node curling its own API |

That is the same set `scripts/issue-node-cert.sh` and the `vault_pki`
role issue on renewal, deliberately: let them diverge and a node that has
renewed stops satisfying a check a node that has not still passes.

**The load balancer's name is not in that list.** `terraform output
vault_addr` is the LB's DNS name and a client dialling it verifies
against that name, but AWS generates it and it cannot be known before the
apply. Pass `--extra-san` for it, or point a CNAME you control at the
cluster and pass that. Without one, clients get a name mismatch against a
certificate that is otherwise correct — which reads as a broken cluster
and is not one.

This is a bootstrap CA, and it stays load-bearing until every node has
been re-issued from Vault's own PKI: Vault cannot issue the certificates
its own cluster needs in order to start.
[`migrate-to-vault-pki.sh`](../scripts/migrate-to-vault-pki.sh) sequences
that handover. Keep `ca.key` — a replacement node needs a certificate,
and an autoscaling group produces replacements without asking.

### Promote the health check once Vault is serving

The autoscaling group ships with `health_check_type = "EC2"`, and that is
a deliberate compromise you are expected to undo.

EC2 health only asks whether the instance is running. That is the only
thing the group can usefully ask *before* this step: Terraform does not
issue certificates, so until the playbook has run, Vault does not start,
the load balancer's check cannot pass, and an `ELB` health check would
mark every instance unhealthy at the end of its grace period, terminate
it, and launch a replacement that does the same. A bare apply would never
converge, and would bill for the privilege.

Once the playbook has converged and the nodes are serving:

```bash
terraform apply -var health_check_type=ELB
```

Now a node that is running but sealed, wedged, or out of the Raft
quorum is replaced, which EC2 health cannot see. Leaving it on `EC2`
means an instance can sit up and useless indefinitely.

Confirm the group agrees before relying on it:

```bash
Q='AutoScalingGroups[].[AutoScalingGroupName,HealthCheckType]'
aws autoscaling describe-auto-scaling-groups --query "$Q" --output text
```

Both settings are asserted in `terraform/aws/tests/cluster.tftest.hcl` --
that the default is `EC2`, and that `ELB` is reachable -- so neither half
can be dropped without a test failing.

### What this has and has not been tested against

`tests/ansible/run-tests.sh` exercises the handoff against saved
`terraform output -json` fixtures: the generated `group_vars`, the
rendered `vault.hcl` for both clouds, and the case where no cloud is
configured. It needs no credentials and runs in CI.

It does not prove the playbook converges against real hosts, and the
emulated apply covers Terraform only — it never reaches the Ansible
layer. The 2026-09-17 AWS apply did converge, on three nodes, but only
after four defects in this seam that every test here had passed over:
the inventory filenames the plugins reject, the directory
`ansible-playbook` reads `group_vars` from, the package spelling dnf
wants, and where the role looks for certificates. `terraform/azure` has
never been applied at all. See
[Provider lock files](#provider-lock-files) and the note in the README.

## Provider lock files

`terraform/aws` and `terraform/azure` each commit a
`.terraform.lock.hcl`, and so does each `bootstrap` module beside them —
they are root modules of their own, so nothing else regenerates their
locks. It pins the exact provider versions and records their checksums,
which does two things: an upstream provider release can't change what CI
builds, and a substituted or tampered provider can't install silently.

The lock records checksums **per platform**, and Terraform refuses to
run on a platform the lock doesn't cover. These are locked for
`linux_amd64` (CI), `darwin_arm64`, and `windows_amd64`. Working on
something else — an Intel Mac, an ARM Linux runner — means adding it:

```bash
cd terraform/aws
terraform providers lock \
  -platform=linux_amd64 \
  -platform=darwin_arm64 \
  -platform=windows_amd64 \
  -platform=linux_arm64        # the one being added
```

List every platform to keep, not just the new one: the command replaces
the set rather than adding to it.

To take a newer provider version, widen the constraint in the module's
`required_providers` block and re-run the same command. Don't hand-edit
the file — the checksums are the point of it.

Note that `terraform init` alone writes a lock for only the current
platform, which is why the command above exists. Committing an
init-generated lock is the usual way this gets broken: it works locally
and then fails everywhere else.

## Post-deployment

1. Initialize Vault (`vault operator init`) — do this exactly once per
   cluster, and distribute unseal/recovery keys per your organization's
   policy.
2. Apply baseline policies from `examples/policies/`.
3. Enable and configure the audit device.
4. Confirm Raft peer status: `vault operator raft list-peers`.

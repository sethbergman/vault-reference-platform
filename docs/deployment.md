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

**Neither has ever been applied.** Run the pre-flight first — it checks
credentials, the inputs that fail late, quota and cost, and applies
nothing:

```bash
./scripts/preflight-cloud.sh --cloud aws
```

Then read [`cloud-apply.md`](cloud-apply.md), which lists what to verify
while the cluster is up and how to tear it down afterwards.
`terraform destroy` alone does not fully work on either profile.

## AWS

```bash
cd terraform/aws
terraform init
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
cd terraform/azure
terraform init
terraform plan -out=plan.tfplan \
  -var="ssh_public_key=$(cat ~/.ssh/id_ed25519.pub)"
terraform apply plan.tfplan
```

Mirrors the AWS layout: a VNet with separate node and load balancer
subnets, a VM scale set sized to `node_count`, a Standard load balancer
on 8200, Key Vault auto-unseal, and a storage account for Raft snapshots.
`ssh_public_key` is required — Azure will not create a Linux scale set
with neither a password nor a key.

Same `group_vars/vault_nodes_azure.yml.example` step as AWS before
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
`ansible/group_vars/vault_nodes.yml`. Re-run it after any apply rather
than editing the file — a hand edit drifts from the infrastructure it
describes and nothing catches that. It refuses to overwrite an existing
file unless you pass `--force`, and it aborts without writing anything if
an output it needs is missing, rather than emitting a `null` that becomes
a Vault which starts and cannot unseal.

Then run the playbook:

```bash
cd ansible && ansible-playbook -i inventory/aws.yml playbooks/site.yml
```

Substitute `inventory/azure.yml` for the Azure profile.

### Why the inventory is dynamic

`inventory/aws.yml` and `inventory/azure.yml` discover nodes through the
cloud API by tag, not from a list of addresses. The autoscaling group and
the scale set both replace instances, so a static inventory is wrong the
first time a node is recycled — and wrong *silently*: the playbook
succeeds against hosts that no longer exist and never touches the ones
that do.

The tag they filter on is the same one Raft's `auto_join` uses, so
cluster formation and configuration management break together rather than
one drifting away from the other.

Nodes sit in private subnets with no public address, so reaching them
needs SSM, a bastion, or a VPN.

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

### What this has and has not been tested against

`tests/ansible/run-tests.sh` exercises the handoff against saved
`terraform output -json` fixtures: the generated `group_vars`, the
rendered `vault.hcl` for both clouds, and the case where no cloud is
configured. It needs no credentials and runs in CI.

It does not prove the playbook converges against real hosts. Neither
cloud profile has been applied end to end — see
[Provider lock files](#provider-lock-files) and the note in the README.

## Provider lock files

`terraform/aws` and `terraform/azure` each commit a
`.terraform.lock.hcl`. It pins the exact provider versions and records
their checksums, which does two things: an upstream provider release
can't change what CI builds, and a substituted or tampered provider
can't install silently.

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

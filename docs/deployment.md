# Deployment

## Local (Docker Compose)

The fastest way to try the reference topology on a laptop.

```bash
make deploy       # 3-node Vault cluster, auto-unsealed
make status        # check cluster/unseal status
make destroy       # tear it down
```

`make deploy` runs `scripts/bootstrap-dev-cluster.sh`, which brings up a
standalone Vault instance (`vault-unseal`) as a Transit auto-unseal
backend, then starts and initializes the 3-node cluster against it — the
same `seal` stanza shape the AWS/Azure profiles below use, just pointed at
something that needs no cloud account. `vault-unseal` itself is still
unsealed the manual, Shamir way — something has to be the root of trust.
See [`docs/auto-unseal.md`](auto-unseal.md) for the full picture.

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
CA, ACM Private CA, or delivered by the Ansible layer). Until they are in
place at `/etc/vault.d/tls/`, Vault will not start. That is deliberate: a
Vault serving plaintext is worse than one that refuses to boot.

### Cost note

Three NAT gateways at roughly $32/month each are the bulk of the idle
cost. Dropping `az_count` to 2, or sharing a single NAT, trades that
against AZ independence.

Then configure the nodes:

```bash
cd ../../ansible
ansible-playbook -i inventory/aws playbooks/site.yml
```

Auto-unseal isn't on by default — copy
`group_vars/vault_nodes_aws.yml.example` to `group_vars/vault_nodes.yml`
first and fill in the `terraform output` values it references. See
[`docs/auto-unseal.md`](auto-unseal.md).

## Azure

Mirrors the AWS layout under `terraform/azure/`, using Azure Key Vault for
auto-unseal and a Storage Account for snapshots. Same
`group_vars/vault_nodes_azure.yml.example` step as AWS before running the
playbook.

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

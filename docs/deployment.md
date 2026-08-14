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

- 3x EC2 instances (or ASG, depending on module config) for Vault nodes
- Application Load Balancer with health checks against `/v1/sys/health`
- KMS key for auto-unseal
- S3 bucket for Raft snapshots

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

## Post-deployment

1. Initialize Vault (`vault operator init`) — do this exactly once per
   cluster, and distribute unseal/recovery keys per your organization's
   policy.
2. Apply baseline policies from `examples/policies/`.
3. Enable and configure the audit device.
4. Confirm Raft peer status: `vault operator raft list-peers`.

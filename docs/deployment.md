# Deployment

## Local (Docker Compose)

The fastest way to try the reference topology on a laptop.

```bash
make deploy       # docker compose up, 3-node Vault cluster
make status        # check cluster/unseal status
make destroy       # tear it down
```

This profile uses Shamir key shares for unsealing (no cloud KMS dependency)
and is intended for development and CI, not production.

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

## Azure

Mirrors the AWS layout under `terraform/azure/`, using Azure Key Vault for
auto-unseal and a Storage Account for snapshots.

## Post-deployment

1. Initialize Vault (`vault operator init`) — do this exactly once per
   cluster, and distribute unseal/recovery keys per your organization's
   policy.
2. Apply baseline policies from `examples/policies/`.
3. Enable and configure the audit device.
4. Confirm Raft peer status: `vault operator raft list-peers`.

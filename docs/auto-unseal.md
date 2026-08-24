# Auto-unseal

Vault encrypts everything at rest behind a single encryption key, and that
key itself is encrypted (sealed) until Vault is unsealed. Restart a sealed
Vault and it serves nothing until someone supplies enough key shares to
reconstruct the master key — fine for a demo, painful for a cluster that
needs to survive an unattended restart. Auto-unseal delegates that
reconstruction to an external key management service instead, so a
restarted node comes back up already unsealed.

Every profile in this repo uses the same `seal` stanza shape in
`vault.hcl` — only the backend changes:

| Profile | Backend | Config |
|---|---|---|
| Local / CI (Docker Compose) | Vault Transit (a second Vault instance) | `docker/vault/config/vault.hcl.tpl` |
| AWS | AWS KMS | `ansible/roles/vault/templates/vault.hcl.j2` |
| Azure | Azure Key Vault | same template |

## Local: Transit auto-unseal

The local/CI cluster doesn't reach out to a real cloud KMS — instead,
`docker/vault-unseal` is a standalone single-node Vault instance whose
Transit secrets engine acts as the key-wrapping backend for the main
3-node cluster. It's the same mechanism a real deployment uses, just with
a backend that needs no cloud account.

`scripts/bootstrap-dev-cluster.sh` is what actually wires this up, in
order:

1. Start `vault-unseal`, initialize and unseal it the normal (manual,
   single Shamir key share) way — something still has to be the root of
   trust.
2. Enable the Transit engine, create an `autounseal` key, and mint an
   orphan periodic token scoped to just that key's encrypt/decrypt paths.
3. Start `vault-0`/`vault-1`/`vault-2` with that token injected via
   `VAULT_TRANSIT_TOKEN` (see `docker/vault/docker-entrypoint.sh` — the
   token is only known at this point, unlike `NODE_ID`, which is baked in
   at image build time).
4. Initialize `vault-0`. Because auto-unseal is configured, it unseals
   itself immediately — there's no unseal key to extract or hand out.
5. Wait for `vault-1`/`vault-2` to join the Raft cluster and for Vault's
   autopilot to promote them to voters.

Both `make deploy` and CI (`smoke-test`, `secret-rotation-test`) call this
same script, so there's one path to keep working, not two that can drift
apart.

## AWS / Azure: cloud KMS auto-unseal

`terraform/aws` and `terraform/azure` each provision the KMS key /
Key Vault an `awskms` / `azurekeyvault` seal stanza needs, plus the
minimal permissions to use it — an `aws_iam_policy` and an
`azurerm_key_vault_access_policy` respectively, granting only
encrypt/decrypt (AWS) or get/wrap/unwrap (Azure) on that one key.

Both are wired up. Each module provisions its own compute — an
autoscaling group on AWS, a VM scale set on Azure — and attaches the
credential to it, so there is nothing to pass on the command line:

- **AWS**: the policy is attached to the nodes' instance profile
  (`terraform/aws/iam.tf`), and the seal stanza picks up credentials
  from the instance role.
- **Azure**: the access policy is granted to the scale set's user-assigned
  managed identity (`terraform/azure/compute.tf`).

No static keys or client secrets are involved on either cloud.

The Ansible seal stanza doesn't turn on by itself — `vault_seal_type`
defaults to `shamir` (plain manual unseal,
`ansible/roles/vault/defaults/main.yml`) so nothing changes for existing
deployments. To enable auto-unseal, copy the matching example into
`group_vars/vault_nodes.yml`:

```bash
cp ansible/group_vars/vault_nodes_aws.yml.example \
   ansible/group_vars/vault_nodes.yml
# fill in the terraform output values it references, then:
ansible-playbook -i inventory/aws playbooks/site.yml
```

(`vault_nodes_azure.yml.example` for the Azure profile.)

## Why this isn't fully automated end to end

This is a reference platform, not a one-command production deployer —
the terraform outputs feeding into the Ansible group_vars is a manual
copy-paste step by design, so each value is visible and reviewable rather
than silently piped between tools. The local Docker Compose path *is*
fully automated (that's what `scripts/bootstrap-dev-cluster.sh` is for)
because there's no equivalent "which cloud account, which credentials"
ambiguity to resolve there.

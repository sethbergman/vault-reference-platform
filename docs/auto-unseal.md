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

## Changing seal type

Moving a cluster between seal types is the operation most likely to leave
one that will not unseal, so this is written from what actually happened
on a three-node cluster rather than from the procedure as documented.
Four of the steps are not what you would guess.

```bash
export VAULT_ADDR=https://127.0.0.1:8200
export VAULT_TOKEN=<root>

# auto-unseal -> manual
./scripts/migrate-seal.sh --to shamir \
    --keys-file docker/dev/.recovery-keys.json \
    --compose-services vault-0,vault-1,vault-2

# and back
./scripts/migrate-seal.sh --to transit \
    --keys-file docker/dev/.recovery-keys.json \
    --compose-services vault-0,vault-1,vault-2
```

The shares do not change value. They change *kind*: the recovery keys
that a Transit-sealed cluster holds become the unseal keys of a
Shamir-sealed one, and back again.

### The sequence

1. Set the seal stanza on **every** node — add `disabled = "true"` to
   turn an autoseal off, remove it to turn one on.
2. Restart **every** node. They come up sealed, reporting the new type.
3. Unseal every node with `vault operator unseal -migrate`.
4. Wait for a leader to finalise it. `sys/seal-status` reports
   `migration: false` when it is genuinely done.

### Four things that surprised me

**Do not stop the standbys.** The instinct is to take them down first, as
you would for any maintenance. On a three-node cluster that leaves one
node, which is not a quorum, so no leader is elected and the migration
never finalises. The first attempt at this produced a cluster that was
unsealed, leaderless and half-migrated — the worst of the available
states.

**Every node needs `-migrate`, not just the active one.** A plain unseal
on a standby returns:

```text
Code: 500. Errors:

* migrate option not provided and seal migration is in progress
```

which reads like a broken node and is really the node telling you it is
doing what you asked.

**It is not over when the last node unseals.** `migration` stays `true`
until a leader finalises it. That gap is short — seconds on a healthy
cluster — and everything below depends on not acting inside it.

**A node restarted while `migration` is true will not auto-unseal**, even
with a perfectly good seal stanza. It says so, but only in the logs:

```text
[WARN] core: entering seal migration mode; Vault will not automatically
unseal even if using an autoseal
```

So the obvious way to check a migration to auto-unseal worked — restart a
node and see whether it comes back on its own — destroys the thing it is
checking if you do it too early. The node then looks broken rather than
early, and the fix is another `-migrate` unseal.

### On real nodes

`migrate-seal.sh` drives the compose profile. The same sequence on a real
node is the same four steps with different mechanics:

| Step | Compose | systemd |
|---|---|---|
| Edit the seal stanza | in the container's `/vault/config/vault.hcl` | `/etc/vault.d/vault.hcl`, via the `vault` role |
| Restart | `docker compose restart` | `systemctl restart vault` |
| Unseal | `vault operator unseal -migrate` | the same, on each host |
| Finalise | wait for `migration: false` | the same |

That path is deliberately a runbook rather than a code path in the
script. For an operation whose failure mode is "nobody can unseal this
cluster again", shipping SSH orchestration that has never been run is
worse than shipping the steps and saying they have not been run.

### What is tested

`tests/seal-migration` migrates a real three-node cluster in both
directions and checks that a secret written beforehand survives, that
`migration` clears rather than being left in progress, and that a
restarted node genuinely unseals itself afterwards with no shares
supplied — which is the difference between reporting `transit` and being
protected by it.

It also asserts two things about Vault rather than about the script: that
a plain unseal really is refused mid-migration, and that a config change
plus a restart really does enter migration mode. The script's shape
depends on both. If either stops being true, the suite should be what
tells you.

Not covered: a real node under systemd, and any seal type other than
Transit and Shamir. Migrating between two *cloud* KMS providers — the
case where an organisation changes clouds — has the same shape and is
untested here.

## Why this isn't fully automated end to end

This is a reference platform, not a one-command production deployer —
the terraform outputs feeding into the Ansible group_vars is a manual
copy-paste step by design, so each value is visible and reviewable rather
than silently piped between tools. The local Docker Compose path *is*
fully automated (that's what `scripts/bootstrap-dev-cluster.sh` is for)
because there's no equivalent "which cloud account, which credentials"
ambiguity to resolve there.

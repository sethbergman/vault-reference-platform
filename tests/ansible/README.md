# Terraform to Ansible handoff tests

```bash
./tests/ansible/run-tests.sh
```

Runs in about two seconds. No terraform, no cloud account, no SSH access.
Needs `jq` and a `python3` with `jinja2` and `pyyaml`.

## Why these exist

Terraform builds hosts. Ansible makes them serve. Between the two sits a
dozen values — a KMS key id, a subscription id, a scale set name — and
until [#17](https://github.com/sethbergman/vault-reference-platform/pull/17)
they were copied across by hand.

That seam fails quietly. An output gets renamed, the group_vars file
picks up a `null`, the playbook reports success, and Vault comes up
unable to unseal. Or the `retry_join` stanza is subtly wrong and three
nodes come up healthy as three separate single-node clusters, each with
its own unseal state, with nothing in any log saying so.

Both failures look like success right up until someone needs the cluster.

## What is real and what is faked

**The fixtures are real `terraform output -json` payloads.** Saved to
`fixtures/`, so the tests exercise the actual output names both modules
declare. Rename an output in `terraform/aws/outputs.tf` without updating
the handoff script and these tests go red.

**The template rendering is real.** `render-config.py` loads
`ansible/roles/vault/templates/vault.hcl.j2` — the same file Ansible
uses, not a copy — layers the role defaults underneath the generated
group_vars, and renders it with Jinja2. The variables come from the file
`scripts/terraform-to-ansible.sh` just produced, so a rename on *either*
side of the handoff fails the test rather than producing a config that
parses fine and never forms a cluster.

It renders with `StrictUndefined`. Jinja2's default would turn a missing
key id into `kms_key_id = ""` — a config that starts and cannot unseal.
One of the assertions proves that strictness is actually on, so the rest
are load-bearing.

**No cluster is ever formed.** These tests check that the configuration
is right, not that Vault accepts it. Nothing here has been applied
against a real cloud account; see "What this has and has not been tested
against" in [`docs/deployment.md`](../../docs/deployment.md).

## The mutual-exclusivity guard

Several assertions exist only to pin one detail of go-discover's Azure
provider, and they are the reason this suite found a live bug.

`auto_join` accepts `tag_name` + `tag_value`, **or** `resource_group` +
`vm_scale_set`. A config carrying both is rejected at runtime with
`unclear configuration: use (tag name and value) or (resouce_group and
vm_scale_set)`.

`terraform/azure/templates/cloud-init.sh.tftpl` shipped both. That Azure
cluster would never have formed. The mistake is easy to make because the
AWS provider *does* filter on tags and the two configs otherwise look
alike — so the constraint is asserted on both the Ansible template and
the cloud-init template rather than left to review.

Azure tag mode would have been wrong here regardless: it matches tags on
network interfaces, and the tags Terraform sets land on the scale set.

## Checking the tests still fail

A green test that cannot go red is worse than no test. Break something
and confirm:

```bash
# Should fail: azure auto_join must not carry a tag selector
TEMPLATE=ansible/roles/vault/templates/vault.hcl.j2
sed -i 's/provider=azure sub/provider=azure tag_name=X sub/' "$TEMPLATE"
./tests/ansible/run-tests.sh   # expect 1 failure
git checkout "$TEMPLATE"
```

Five mutations were checked when these were written — dropping
`retry_join` from the AWS branch, reintroducing the tag selector on both
the Ansible and cloud-init paths, renaming a Terraform output, and
removing `tls_client_ca_file`. Each turned exactly one assertion red.
Restore the file afterwards; a mutation left in the working tree is
indistinguishable from a real regression.

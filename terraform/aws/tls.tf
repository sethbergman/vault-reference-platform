# Where a new node finds the bootstrap CA, so it can sign its own leaf.
#
# The first real apply terminated a leader and watched the autoscaling
# group replace it in 75 seconds with an instance whose Vault would not
# start: certificates came only from an Ansible run keyed to an instance
# id that did not exist until the launch. scripts/issue-bootstrap-cert.sh,
# run from user-data, closes that gap by reading the CA from these two
# parameters and signing the node's own leaf before Vault starts.
#
# TERRAFORM NEVER HOLDS THE KEY
#
# The CA is generated after the apply (scripts/generate-cloud-certs.sh), so
# Terraform could not know it anyway -- but the design would keep it out
# of state regardless. These are created with a placeholder, and
# scripts/publish-bootstrap-ca.sh overwrites it. Terraform still owns the
# parameters' existence, so a teardown removes them rather than leaving a
# CA key behind in an account.
#
# `ignore_changes = [value]` does NOT keep a value out of state, and the
# first version of this file relied on it. It only suppresses the diff:
# the provider reads a SecureString back *with decryption* on every
# refresh, so the apply after publication -- any apply, including one
# reporting "No changes" -- wrote the decrypted CA key into state, and on
# into the versioned state bucket, while `terraform show` printed
# "(sensitive value)". So the key is a write-only argument instead, and
# tests/cloud-apply-emulated publishes a key and re-applies to prove it
# stays out.
#
# Until publication the placeholder is what a node reads, and the boot
# script treats that as "first apply, Ansible will deliver", not as an
# error. So the first apply behaves exactly as it did before this file.

locals {
  bootstrap_ca_prefix = "/${var.cluster_name}/tls"

  # What a published parameter still reads before publication. Shared with
  # the boot script by value; tests/bootstrap-cert holds them together.
  bootstrap_ca_placeholder = "UNPUBLISHED"
}

resource "aws_ssm_parameter" "bootstrap_ca_cert" {
  name        = "${local.bootstrap_ca_prefix}/bootstrap-ca.crt"
  description = "Bootstrap CA certificate for ${var.cluster_name}. Written by scripts/publish-bootstrap-ca.sh."
  type        = "String"
  value       = local.bootstrap_ca_placeholder

  lifecycle {
    ignore_changes = [value]
  }

  tags = module.vault_cluster.cluster_tags
}

# Encrypted under the node volume key rather than the seal key or the
# account's aws/ssm key. The seal key is the durable one and should do
# nothing it does not have to. aws/ssm is shared by everything in the
# account, so granting the node role decrypt on it would admit every
# SecureString anyone ever writes there. vault_data is this cluster's,
# lives and dies with it, and the node role is granted decrypt on it only
# through SSM (iam.tf).
#
# value_wo is write-only: sent on create, never read back into state
# (Terraform 1.11, hence main.tf's floor). It needs ignore_changes = all
# as well. Any in-place update re-puts the value, and a write-only value
# is not in state to re-put -- the provider sends an empty string, which
# SSM rejects, and an update that did succeed would overwrite the
# published key with the placeholder. Both behaviours were reproduced
# against the emulator before settling on this. The cost is that editing
# this resource's arguments changes nothing; a change that matters here
# means replacing it, and then re-running publish-bootstrap-ca.sh.
resource "aws_ssm_parameter" "bootstrap_ca_key" {
  name             = "${local.bootstrap_ca_prefix}/bootstrap-ca.key"
  description      = "Bootstrap CA private key for ${var.cluster_name}. Written by scripts/publish-bootstrap-ca.sh; never by Terraform."
  type             = "SecureString"
  key_id           = aws_kms_key.vault_data.arn
  value_wo         = local.bootstrap_ca_placeholder
  value_wo_version = 1

  lifecycle {
    ignore_changes = all
  }

  tags = module.vault_cluster.cluster_tags
}

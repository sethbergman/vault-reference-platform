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
# of state regardless. These are created with a placeholder and the value
# is ignored from then on; scripts/publish-bootstrap-ca.sh overwrites it.
# Terraform still owns the parameters' existence, so a teardown removes
# them rather than leaving a CA key behind in an account.
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
resource "aws_ssm_parameter" "bootstrap_ca_key" {
  name        = "${local.bootstrap_ca_prefix}/bootstrap-ca.key"
  description = "Bootstrap CA private key for ${var.cluster_name}. Written by scripts/publish-bootstrap-ca.sh; never by Terraform."
  type        = "SecureString"
  key_id      = aws_kms_key.vault_data.arn
  value       = local.bootstrap_ca_placeholder

  lifecycle {
    ignore_changes = [value]
  }

  tags = module.vault_cluster.cluster_tags
}

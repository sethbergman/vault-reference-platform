# The instance role the auto-unseal policy in main.tf has been waiting
# for. Everything Vault needs from AWS comes through this role, so nothing
# on a node holds static credentials.

data "aws_iam_policy_document" "vault_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "vault" {
  name               = "${var.cluster_name}-vault-node"
  assume_role_policy = data.aws_iam_policy_document.vault_assume_role.json

  tags = module.vault_cluster.cluster_tags
}

resource "aws_iam_instance_profile" "vault" {
  name = "${var.cluster_name}-vault-node"
  role = aws_iam_role.vault.name
}

# Auto-unseal. This is the policy declared in main.tf alongside the KMS
# key; until now there was no role to attach it to.
resource "aws_iam_role_policy_attachment" "vault_autounseal" {
  role       = aws_iam_role.vault.name
  policy_arn = aws_iam_policy.vault_autounseal.arn
}

# Raft auto-join. Vault's retry_join uses the EC2 API to find its peers by
# tag, which means the cluster re-forms on its own as the autoscaling
# group replaces instances — no static peer list to keep in step.
data "aws_iam_policy_document" "vault_autojoin" {
  statement {
    effect = "Allow"
    actions = [
      "ec2:DescribeInstances",
    ]
    # DescribeInstances does not support resource-level permissions, so
    # this can only be granted account-wide. It is read-only metadata.
    resources = ["*"]
  }
}

resource "aws_iam_policy" "vault_autojoin" {
  name        = "${var.cluster_name}-vault-autojoin"
  description = "Allows Vault nodes to discover Raft peers via the EC2 API"
  policy      = data.aws_iam_policy_document.vault_autojoin.json
}

resource "aws_iam_role_policy_attachment" "vault_autojoin" {
  role       = aws_iam_role.vault.name
  policy_arn = aws_iam_policy.vault_autojoin.arn
}

# Snapshots. Scoped to this cluster's bucket, and deliberately without
# s3:DeleteObject — a node should be able to write a backup but not remove
# one. Expiry is handled by the bucket lifecycle rule instead, so a
# compromised node cannot destroy backup history.
locals {
  # Named rather than inlined below so it can be asserted on directly.
  # The rendered policy JSON comes from a data source, and data sources
  # are mocked during `terraform test` — a test reading the rendered
  # output would pass no matter what was in this list.
  snapshot_object_actions = [
    "s3:PutObject",
    "s3:GetObject",
  ]

  # Named for the same reason. S3 asks the caller to mint the data key
  # when a bucket has SSE-KMS default encryption, so this is what stands
  # between a correct-looking bucket policy and a snapshot that uploads.
  snapshot_kms_actions = [
    "kms:GenerateDataKey",
  ]
}

data "aws_iam_policy_document" "vault_snapshots" {
  statement {
    effect    = "Allow"
    actions   = local.snapshot_object_actions
    resources = ["${aws_s3_bucket.snapshots.arn}/*"]
  }

  statement {
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.snapshots.arn]
  }

  # The bucket sets SSE-KMS default encryption with the auto-unseal key
  # (storage.tf), and S3 asks the *caller* to mint the data key. Without
  # this, every PutObject is denied by KMS rather than by S3 -- so the
  # bucket, the lifecycle rule and the s3:PutObject grant above are all
  # correct and no snapshot is ever stored.
  #
  # Not folded into the auto-unseal policy in main.tf: the seal genuinely
  # does not need GenerateDataKey, and that policy is described as the
  # minimum the seal requires. Reads are already covered by the Decrypt
  # it grants on the same key.
  statement {
    effect    = "Allow"
    actions   = local.snapshot_kms_actions
    resources = [aws_kms_key.vault_autounseal.arn]
  }
}

resource "aws_iam_policy" "vault_snapshots" {
  name        = "${var.cluster_name}-vault-snapshots"
  description = "Allows Vault nodes to write Raft snapshots to the backup bucket"
  policy      = data.aws_iam_policy_document.vault_snapshots.json
}

resource "aws_iam_role_policy_attachment" "vault_snapshots" {
  role       = aws_iam_role.vault.name
  policy_arn = aws_iam_policy.vault_snapshots.arn
}

# The bootstrap CA, for a node the autoscaling group has just launched
# (tls.tf, scripts/issue-bootstrap-cert.sh). Read-only, the two parameters
# and nothing else under SSM, and decrypt on the volume key only when SSM
# is the one asking -- so the role cannot use that key for anything but
# reading this parameter.
#
# This is the tradeoff design A accepts, stated where it is granted: every
# node can read the CA key, so a compromised node can mint a leaf any peer
# will accept. It already holds the seal key's Decrypt and the Raft data on
# its disk, so that adds little to a boundary that has already gone -- and
# the alternative was a cluster that stays one node short until a person
# notices. Vault's own PKI, authenticated with the instance role, is the
# design that takes the key off the nodes; see docs/security.md.
locals {
  # Named rather than inlined, like the snapshot lists above: the policy
  # JSON comes from a data source, which terraform test mocks.
  bootstrap_ca_ssm_actions = ["ssm:GetParameter"]
  bootstrap_ca_parameter_arns = [
    aws_ssm_parameter.bootstrap_ca_cert.arn,
    aws_ssm_parameter.bootstrap_ca_key.arn,
  ]
  bootstrap_ca_kms_actions = ["kms:Decrypt"]
}

data "aws_iam_policy_document" "vault_bootstrap_ca" {
  statement {
    effect    = "Allow"
    actions   = local.bootstrap_ca_ssm_actions
    resources = local.bootstrap_ca_parameter_arns
  }

  statement {
    effect    = "Allow"
    actions   = local.bootstrap_ca_kms_actions
    resources = [aws_kms_key.vault_data.arn]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${var.aws_region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_policy" "vault_bootstrap_ca" {
  name        = "${var.cluster_name}-vault-bootstrap-ca"
  description = "Allows a new Vault node to read the bootstrap CA and sign its own certificate"
  policy      = data.aws_iam_policy_document.vault_bootstrap_ca.json
}

resource "aws_iam_role_policy_attachment" "vault_bootstrap_ca" {
  role       = aws_iam_role.vault.name
  policy_arn = aws_iam_policy.vault_bootstrap_ca.arn
}

# SSM Session Manager, so operators can reach a node without SSH, an open
# port 22, or a bastion. Sessions are logged in CloudTrail, which SSH key
# access is not.
resource "aws_iam_role_policy_attachment" "vault_ssm" {
  role       = aws_iam_role.vault.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

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
data "aws_iam_policy_document" "vault_snapshots" {
  statement {
    effect = "Allow"
    actions = [
      "s3:PutObject",
      "s3:GetObject",
    ]
    resources = ["${aws_s3_bucket.snapshots.arn}/*"]
  }

  statement {
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.snapshots.arn]
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

# SSM Session Manager, so operators can reach a node without SSH, an open
# port 22, or a bastion. Sessions are logged in CloudTrail, which SSH key
# access is not.
resource "aws_iam_role_policy_attachment" "vault_ssm" {
  role       = aws_iam_role.vault.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

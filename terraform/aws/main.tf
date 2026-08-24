terraform {
  required_version = ">= 1.7"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    # Used only to suffix the snapshot bucket name, which has to be
    # globally unique across every AWS account.
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

module "vault_cluster" {
  source       = "../modules/vault-cluster"
  cluster_name = var.cluster_name
  node_count   = var.node_count
}

# Auto-unseal key for Vault's "awskms" seal stanza (see
# ansible/roles/vault/templates/vault.hcl.j2 and
# ansible/group_vars/vault_nodes_aws.yml.example). Key rotation is AWS-side
# and transparent to Vault — it always calls KMS for the current key
# version, so there's no coordination needed with the Vault cluster.
resource "aws_kms_key" "vault_autounseal" {
  description             = "Vault auto-unseal key for ${var.cluster_name}"
  deletion_window_in_days = 7
  enable_key_rotation     = true
}

resource "aws_kms_alias" "vault_autounseal" {
  name          = "alias/${var.cluster_name}-vault-autounseal"
  target_key_id = aws_kms_key.vault_autounseal.key_id
}

# The minimum permissions Vault's awskms seal needs. Attached to the node
# instance role in iam.tf, so Vault reaches KMS via the instance role
# rather than static credentials.
resource "aws_iam_policy" "vault_autounseal" {
  name        = "${var.cluster_name}-vault-autounseal"
  description = "Allows Vault to use the auto-unseal KMS key"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["kms:Encrypt", "kms:Decrypt", "kms:DescribeKey"]
      Resource = aws_kms_key.vault_autounseal.arn
    }]
  })
}

# The rest of the cluster is split by concern rather than piled in here:
#   network.tf   VPC, subnets, NAT, S3 endpoint
#   security.tf  security groups
#   iam.tf       node role and instance profile
#   compute.tf   launch template and autoscaling group
#   lb.tf        network load balancer and health check
#   storage.tf   snapshot bucket

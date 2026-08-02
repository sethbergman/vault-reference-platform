terraform {
  required_version = ">= 1.7"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
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

# TODO: EC2/ASG nodes, ALB + target group + health check,
# KMS key for auto-unseal, S3 bucket for Raft snapshots.

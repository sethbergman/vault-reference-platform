terraform {
  required_version = ">= 1.7"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
  }
}

provider "azurerm" {
  features {}
}

module "vault_cluster" {
  source       = "../modules/vault-cluster"
  cluster_name = var.cluster_name
  node_count   = var.node_count
}

# TODO: VM scale set nodes, Load Balancer + health probe,
# Key Vault for auto-unseal, Storage Account for Raft snapshots.

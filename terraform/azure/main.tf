terraform {
  required_version = ">= 1.7"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
    # Used only to suffix the storage account name, which has to be
    # globally unique across all of Azure.
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "azurerm" {
  features {}
}

data "azurerm_client_config" "current" {}

module "vault_cluster" {
  source       = "../modules/vault-cluster"
  cluster_name = var.cluster_name
  node_count   = var.node_count
}

resource "azurerm_resource_group" "vault" {
  name     = "${var.cluster_name}-rg"
  location = var.location
}

# Auto-unseal key for Vault's "azurekeyvault" seal stanza (see
# ansible/roles/vault/templates/vault.hcl.j2 and
# ansible/group_vars/vault_nodes_azure.yml.example).
resource "random_id" "key_vault_suffix" {
  byte_length = 4
}

locals {
  # Key Vault names are globally unique across Azure and capped at 24
  # characters, so neither the cluster name alone nor
  # "${cluster_name}-autounseal" works — the latter is 26 characters at
  # the default cluster name and fails at apply time. `terraform
  # validate` cannot see this; it is a runtime constraint on the value,
  # not the schema.
  #
  # 15 characters of cluster name + dash + 8 hex = 24 exactly.
  #
  # A local rather than an expression inlined into the resource, because
  # the name itself is unknown at plan time (random_id.hex) and so cannot
  # be asserted on. The test asserts on this prefix instead — reading the
  # budget the module actually uses, rather than restating the same
  # arithmetic in the test file, where it is true whatever this line says.
  key_vault_name_prefix = substr(replace(lower(var.cluster_name), "/[^a-z0-9-]/", ""), 0, 15)
}

resource "azurerm_key_vault" "vault_autounseal" {
  name                = "${local.key_vault_name_prefix}-${random_id.key_vault_suffix.hex}"
  resource_group_name = azurerm_resource_group.vault.name
  location            = azurerm_resource_group.vault.location
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard"

  # Losing this key does not just break unsealing — it makes every Raft
  # snapshot permanently undecryptable, because they are encrypted under
  # it (see docs/disaster-recovery.md). Soft delete alone still allows a
  # purge inside the retention window; purge protection removes that
  # option entirely, and it cannot be turned off once enabled. That is
  # the point: the key must not be destroyable by accident or by someone
  # who has compromised the subscription.
  soft_delete_retention_days = 90
  purge_protection_enabled   = true

  # Deny by default. Without this the Key Vault accepts traffic from any
  # network, which for the key that unseals Vault is a wide door.
  # AzureServices is bypassed so the platform's own integrations keep
  # working; add the Vault subnet's ID here once the VM scale set exists.
  network_acls {
    default_action = "Deny"
    bypass         = "AzureServices"
  }
}

resource "azurerm_key_vault_key" "vault_autounseal" {
  name         = "vault-autounseal"
  key_vault_id = azurerm_key_vault.vault_autounseal.id
  key_type     = "RSA"
  key_size     = 2048
  key_opts     = ["wrapKey", "unwrapKey"]
}

# The access policy granting Vault's azurekeyvault seal wrap/unwrap on
# this key lives in compute.tf, alongside the managed identity it is
# granted to. It used to sit here pointed at a placeholder null-GUID
# because no identity existed yet.

# The rest of the cluster is split by concern rather than piled in here:
#   network.tf   VNet, subnets, NAT, NSG, flow logs
#   compute.tf   managed identity, role assignments, VM scale set
#   lb.tf        load balancer and health probe
#   storage.tf   snapshot container and storage account

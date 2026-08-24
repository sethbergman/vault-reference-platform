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
resource "azurerm_key_vault" "vault_autounseal" {
  name                = "${var.cluster_name}-autounseal"
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

# The minimum access Vault's azurekeyvault seal needs. var.vault_node_identity_principal_id
# defaults to Azure's conventional null-GUID placeholder — there's no VM
# scale set with a managed identity to grant access to until that TODO
# below is built out. Pass the real managed identity's principal ID once
# it exists, so Vault can reach Key Vault via managed identity rather
# than static credentials.
resource "azurerm_key_vault_access_policy" "vault_autounseal" {
  key_vault_id = azurerm_key_vault.vault_autounseal.id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = var.vault_node_identity_principal_id

  key_permissions = ["Get", "WrapKey", "UnwrapKey"]
}

# TODO: VM scale set nodes, Load Balancer + health probe,
# Storage Account for Raft snapshots.

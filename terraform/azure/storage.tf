# Storage account for Raft snapshots (see docs/disaster-recovery.md) and
# for the NSG flow logs in network.tf.
#
# Same warning as the AWS side: a snapshot is encrypted under the
# auto-unseal key, so this container on its own is not a recoverable
# backup. The Key Vault key has to survive too — which is why
# purge_protection_enabled is set on it in main.tf and cannot be turned
# off once enabled.

resource "random_id" "storage_suffix" {
  byte_length = 4
}

resource "azurerm_storage_account" "vault" {
  # Storage account names are globally unique, lowercase alphanumeric
  # only, and capped at 24 characters — hence the substr rather than the
  # readable name used everywhere else.
  name                = substr("${replace(lower(var.cluster_name), "/[^a-z0-9]/", "")}vault${random_id.storage_suffix.hex}", 0, 24)
  resource_group_name = azurerm_resource_group.vault.name
  location            = azurerm_resource_group.vault.location

  account_tier = "Standard"
  # Zone-redundant rather than geo-redundant. The cluster is
  # single-region, so surviving the loss of a zone is the useful
  # property; cross-region recovery is a different exercise and needs a
  # Key Vault in the other region too, or the snapshots arrive
  # undecryptable.
  account_replication_type = "ZRS"

  # Encrypted a second time at the infrastructure layer, with a
  # platform-managed key independent of the one below. Cheap, and it
  # means a flaw in one encryption layer is not sufficient on its own.
  infrastructure_encryption_enabled = true

  # Required before the customer-managed key can be attached — the
  # account needs an identity that can reach the Key Vault key.
  identity {
    type = "SystemAssigned"
  }

  # TLS 1.2 minimum, and no unencrypted transfer at all.
  min_tls_version            = "TLS1_2"
  https_traffic_only_enabled = true

  # Snapshots are read and written by the nodes' managed identity, not by
  # the account keys. Disabling key auth removes a credential that would
  # otherwise grant full access to every backup.
  shared_access_key_enabled = false

  allow_nested_items_to_be_public = false

  blob_properties {
    # Recovers a snapshot overwritten by a corrupt one, and a container
    # deleted by mistake.
    versioning_enabled = true

    delete_retention_policy {
      days = var.snapshot_retention_days
    }

    container_delete_retention_policy {
      days = var.snapshot_retention_days
    }
  }

  network_rules {
    default_action = "Deny"
    # Reached over the service endpoint on the node subnet rather than the
    # public internet.
    virtual_network_subnet_ids = [azurerm_subnet.vault.id]
    bypass                     = ["AzureServices"]
  }

  tags = module.vault_cluster.cluster_tags
}

# Encrypted with the same Key Vault key that seals the cluster, rather
# than a Microsoft-managed key — the same choice as encrypting the AWS
# root volume with the auto-unseal KMS key. It also means the key's
# purge protection now guards the snapshots twice over: once because the
# snapshot contents are sealed under it, and once because the storage
# account cannot decrypt without it.
#
# A separate resource rather than a block inside the account, because the
# access policy below has to exist first and that would otherwise be a
# cycle.
resource "azurerm_key_vault_access_policy" "storage" {
  key_vault_id = azurerm_key_vault.vault_autounseal.id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = azurerm_storage_account.vault.identity[0].principal_id

  key_permissions = ["Get", "UnwrapKey", "WrapKey"]
}

resource "azurerm_storage_account_customer_managed_key" "vault" {
  storage_account_id = azurerm_storage_account.vault.id
  key_vault_id       = azurerm_key_vault.vault_autounseal.id
  key_name           = azurerm_key_vault_key.vault_autounseal.name

  depends_on = [azurerm_key_vault_access_policy.storage]
}

resource "azurerm_storage_container" "snapshots" {
  name                  = "snapshots"
  storage_account_name  = azurerm_storage_account.vault.name
  container_access_type = "private"
}

output "vault_autounseal_key_vault_name" {
  description = "Key Vault name for the seal \"azurekeyvault\" stanza (vault_name) in vault.hcl"
  value       = azurerm_key_vault.vault_autounseal.name
}

output "vault_autounseal_key_name" {
  description = "Key name for the seal \"azurekeyvault\" stanza (key_name) in vault.hcl"
  value       = azurerm_key_vault_key.vault_autounseal.name
}

output "vault_autounseal_tenant_id" {
  description = "Tenant ID for the seal \"azurekeyvault\" stanza (tenant_id) in vault.hcl"
  value       = data.azurerm_client_config.current.tenant_id
}

output "vault_addr" {
  description = "VAULT_ADDR for clients. Resolvable from inside the VNet when the load balancer is internal."
  value       = "https://${var.internal_lb ? azurerm_lb.vault.frontend_ip_configuration[0].private_ip_address : azurerm_public_ip.lb[0].ip_address}:8200"
}

output "vault_node_identity_principal_id" {
  description = "Principal ID of the nodes' managed identity, for granting access to other resources."
  value       = azurerm_user_assigned_identity.vault.principal_id
}

output "vault_snapshot_storage_account" {
  description = "Storage account holding Raft snapshots. Shared key auth is disabled — access is via the nodes' managed identity."
  value       = azurerm_storage_account.vault.name
}

output "vault_snapshot_container" {
  description = "Blob container for Raft snapshots."
  value       = azurerm_storage_container.snapshots.name
}

output "resource_group_name" {
  description = "Resource group holding the cluster."
  value       = azurerm_resource_group.vault.name
}

output "vault_scale_set_name" {
  description = "VM scale set name, for triggering a rolling instance upgrade."
  value       = azurerm_linux_virtual_machine_scale_set.vault.name
}

output "vault_cluster_tag" {
  description = "Tag identifying cluster members. Used by Raft auto-join and by Ansible dynamic inventory."
  value       = "VaultCluster=${var.cluster_name}"
}

output "subscription_id" {
  description = "Subscription the cluster is deployed in. Raft auto-join requires it explicitly; go-discover has no MSI fallback for this one value."
  value       = data.azurerm_client_config.current.subscription_id
}

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

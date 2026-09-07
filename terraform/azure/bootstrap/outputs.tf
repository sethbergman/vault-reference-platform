output "state_storage_account" {
  value       = azurerm_storage_account.tfstate.name
  description = "Storage account holding the state for terraform/azure."
}

output "state_resource_group" {
  value       = azurerm_resource_group.tfstate.name
  description = "Resource group the state account lives in."
}

# Generated rather than written down -- see the AWS module's outputs.tf
# for why a hand-copied account name is a state file nobody can find.
#
#   terraform -chdir=terraform/azure/bootstrap output -raw backend_config \
#     > terraform/azure/backend.hcl
#
# See docs/terraform-state.md.
output "backend_config" {
  value       = <<-EOT
    resource_group_name  = "${azurerm_resource_group.tfstate.name}"
    storage_account_name = "${azurerm_storage_account.tfstate.name}"
    container_name       = "${azurerm_storage_container.tfstate.name}"
    key                  = "${var.cluster_name}.terraform.tfstate"

    use_azuread_auth = true
  EOT
  description = "Contents of terraform/azure/backend.hcl."
}

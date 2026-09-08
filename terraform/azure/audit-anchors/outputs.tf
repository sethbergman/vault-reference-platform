output "anchor_storage_account" {
  value       = azurerm_storage_account.anchors.name
  description = "Account receiving the anchors."
}

output "anchor_container" {
  value       = azurerm_storage_container.anchors.name
  description = "Container within it."
}

output "anchor_blob_endpoint" {
  value       = azurerm_storage_account.anchors.primary_blob_endpoint
  description = "Blob endpoint, for whatever ships anchors here."
}

output "ship_anchors_role_id" {
  value       = azurerm_role_definition.ship_anchors.role_definition_resource_id
  description = <<-EOT
    Assign to whatever ships anchors. It can write a blob and read one
    back; the delete actions are excluded rather than merely unlisted.
  EOT
}

output "anchor_retention_days" {
  value       = var.anchor_retention_days
  description = "How long a shipped anchor cannot be deleted or overwritten for."
}

output "anchor_immutability_state" {
  value       = var.anchor_immutability_state
  description = "Locked is the guarantee; Unlocked can be lifted by an administrator."
}

# Said out loud rather than left to be inferred from the state variable.
#
# The AWS module's ship_command output prints a command because there is
# a script to run. There is no Azure counterpart yet:
# scripts/ship-anchors.sh speaks the S3 API. So this output says what the
# account is for and what is still missing, which is more useful than a
# command that does not exist.
output "how_to_ship" {
  value       = <<-EOT
    ${var.anchor_immutability_state == "Locked" ? "Locked" : "UNLOCKED — an administrator can lift this policy"}, ${var.anchor_retention_days} days.

    Nothing in this repository ships anchors here yet.
    scripts/ship-anchors.sh writes to S3; the Azure path is an az
    storage blob upload against ${azurerm_storage_account.anchors.name}/${azurerm_storage_container.anchors.name},
    with the same one-blob-per-sequence-number layout, and it has not
    been written. See docs/audit.md.
  EOT
  description = "What this account is for, and what does not exist yet."
}

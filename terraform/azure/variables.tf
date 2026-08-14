variable "cluster_name" {
  type    = string
  default = "vault-reference"
}

variable "node_count" {
  type    = number
  default = 3
}

variable "location" {
  type    = string
  default = "eastus"
}

variable "vault_node_identity_principal_id" {
  type        = string
  description = "Principal ID of the Vault nodes' managed identity. Placeholder null-GUID until the VM scale set (see TODO in main.tf) exists to provide a real one."
  default     = "00000000-0000-0000-0000-000000000000"
}

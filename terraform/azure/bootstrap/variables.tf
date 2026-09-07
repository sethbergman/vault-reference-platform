variable "location" {
  type    = string
  default = "eastus"
}

# Not cluster_name -- one state account serves every cluster in the
# subscription, separated by state key. See the AWS module's variables.tf
# for why that separation is deliberate.
variable "name_prefix" {
  type        = string
  default     = "vault-reference"
  description = "Prefix for the resource group and storage account. Not the cluster name."
}

variable "cluster_name" {
  type        = string
  default     = "vault-reference"
  description = "The cluster whose state key the backend_config output is written for."
}

variable "state_storage_account_name" {
  type        = string
  default     = null
  description = "Override the generated account name. Globally unique, lowercase alphanumeric, 24 characters or fewer."
}

variable "state_version_retention_days" {
  type        = number
  default     = 90
  description = "How long superseded state blobs and deleted containers stay recoverable."
}

# Empty means the account accepts connections from anywhere and relies on
# Entra ID for authorisation. See the network_rules block in main.tf for
# why that is the default here and not on the snapshot account.
variable "allowed_ip_ranges" {
  type        = list(string)
  default     = []
  description = "CIDRs allowed to reach the state account. Empty leaves the network default at Allow."
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "cluster_name" {
  type    = string
  default = "vault-reference"
}

variable "location" {
  type    = string
  default = "eastus"
}

variable "node_count" {
  type        = number
  description = "Number of Vault nodes. Raft needs an odd number to form a majority; an even count gains no fault tolerance over the odd number below it."
  default     = 3

  validation {
    condition     = var.node_count % 2 == 1 && var.node_count >= 3
    error_message = "node_count must be an odd number >= 3 (3 or 5 for most clusters)."
  }
}

variable "vault_version" {
  type        = string
  description = "Vault version installed on the nodes. Keep in step with docker/ and terraform/aws so every profile runs the same release."
  default     = "1.17.2"
}

variable "availability_zones" {
  type        = list(string)
  description = "Availability zones to spread nodes across. Not every region offers zones — check before changing the region."
  default     = ["1", "2", "3"]

  validation {
    condition     = length(var.availability_zones) >= 2
    error_message = "At least two availability zones are needed for the cluster to survive losing one."
  }
}

# ---------------------------------------------------------------------------
# Networking
# ---------------------------------------------------------------------------
variable "vnet_cidr" {
  type        = string
  description = "CIDR for the virtual network. Carved into a /24 for nodes and a /24 for the load balancer."
  default     = "10.1.0.0/16"
}

variable "allowed_cidr_blocks" {
  type        = list(string)
  description = "CIDRs allowed to reach the Vault API. Defaults to RFC1918 rather than the internet — an internet-reachable Vault should be a deliberate choice."
  default     = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"]
}

variable "internal_lb" {
  type        = bool
  description = "Whether the load balancer has a private frontend only. Vault normally has no business being internet-facing."
  default     = true
}

# ---------------------------------------------------------------------------
# Compute
# ---------------------------------------------------------------------------
variable "vm_size" {
  type        = string
  description = "VM size for Vault nodes. Vault is memory-bound — everything is held in memory — rather than CPU-bound."
  default     = "Standard_B2s"
}

variable "admin_username" {
  type        = string
  description = "Admin user on the nodes. SSH keys only; password authentication is disabled."
  default     = "azureuser"
}

variable "ssh_public_key" {
  type        = string
  description = "SSH public key for the admin user. Required — Azure will not create a Linux scale set with neither a password nor a key."
}

variable "os_disk_size_gb" {
  type        = number
  description = "OS disk size in GB. Raft storage lives here, and it grows between snapshots."
  default     = 64
}

# ---------------------------------------------------------------------------
# Retention
# ---------------------------------------------------------------------------
variable "snapshot_retention_days" {
  type        = number
  description = "Days to retain deleted snapshot blobs and containers before they are purged."
  default     = 30
}

variable "flow_log_retention_days" {
  type        = number
  description = "Days to retain NSG flow logs."
  default     = 90
}

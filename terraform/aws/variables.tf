variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "cluster_name" {
  type    = string
  default = "vault-reference"
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
  description = "Vault version installed on the nodes. Keep in step with docker/ so local and cloud run the same release."
  default     = "1.17.2"
}

# ---------------------------------------------------------------------------
# Networking
# ---------------------------------------------------------------------------
variable "vpc_cidr" {
  type        = string
  description = "CIDR for the VPC. Must be large enough to carve out one public and one private /24 per availability zone."
  default     = "10.0.0.0/16"
}

variable "az_count" {
  type        = number
  description = "How many availability zones to spread across. Nodes are distributed round-robin, so losing one AZ costs at most ceil(node_count/az_count) nodes."
  default     = 3

  validation {
    condition     = var.az_count >= 2 && var.az_count <= 4
    error_message = "az_count must be between 2 and 4."
  }
}

variable "allowed_cidr_blocks" {
  type        = list(string)
  description = "CIDRs allowed to reach the Vault load balancer. Defaults to RFC1918 rather than 0.0.0.0/0 — a Vault API open to the internet should be a deliberate choice, not a default."
  default     = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"]
}

variable "internal_lb" {
  type        = bool
  description = "Whether the load balancer is internal (no public IP). Vault normally has no business being internet-facing."
  default     = true
}

# ---------------------------------------------------------------------------
# Compute
# ---------------------------------------------------------------------------
variable "instance_type" {
  type        = string
  description = "EC2 instance type for Vault nodes. Vault is memory-bound (everything is held in memory) rather than CPU-bound."
  default     = "t3.small"
}

variable "ssh_key_name" {
  type        = string
  description = "Optional EC2 key pair for SSH. Leave empty to disable SSH entirely and use SSM Session Manager instead, which leaves an auditable trail and needs no open port 22."
  default     = ""
}

variable "health_check_type" {
  type        = string
  description = "How the autoscaling group decides an instance is unhealthy. EC2 until Ansible has provisioned TLS and Vault is serving; ELB afterwards, so a node that is running but sealed or wedged is replaced."
  default     = "EC2"

  validation {
    condition     = contains(["EC2", "ELB"], var.health_check_type)
    error_message = "health_check_type must be EC2 or ELB."
  }
}

variable "root_volume_size" {
  type        = number
  description = "Root volume size in GB. Raft storage lives here, and it grows between snapshots."
  default     = 50
}

# ---------------------------------------------------------------------------
# Backups
# ---------------------------------------------------------------------------
variable "snapshot_retention_days" {
  type        = number
  description = "Days to keep Raft snapshots in S3 before expiring them."
  default     = 30
}

variable "flow_log_retention_days" {
  type        = number
  description = "Days to retain VPC flow logs in CloudWatch."
  default     = 90
}

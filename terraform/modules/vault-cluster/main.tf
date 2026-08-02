# Provider-agnostic Vault cluster module.
#
# This module defines the *shape* of the cluster (node count, ports,
# tags/labels) and is composed by the provider-specific implementations
# in terraform/aws and terraform/azure. It intentionally does not create
# any cloud resources itself.

variable "cluster_name" {
  type        = string
  description = "Name used to tag/label all resources in this cluster."
}

variable "node_count" {
  type        = number
  default     = 3
  description = "Number of Vault nodes in the Raft cluster. Should be odd."
}

variable "vault_version" {
  type        = string
  default     = "1.17.2"
}

locals {
  cluster_tags = {
    project = "vault-reference-platform"
    cluster = var.cluster_name
  }
}

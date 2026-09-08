variable "location" {
  type    = string
  default = "eastus"
}

# Not cluster_name. One anchor account is expected to serve every cluster
# in the estate, separated by blob prefix, for the reason the AWS
# module's variables.tf gives: an account created per cluster is created
# by whoever creates the cluster, which puts the evidence on the same
# lifecycle as the thing it is evidence about.
variable "name_prefix" {
  type        = string
  default     = "vault-reference"
  description = "Prefix for the resource group, account and role. Not the cluster name."
}

variable "anchor_storage_account_name" {
  type        = string
  default     = null
  description = "Set where a naming convention dictates it. Null gets a random suffix, because the name is globally unique across Azure."
}

variable "anchor_container_name" {
  type    = string
  default = "audit-anchors"
}

# How long a blob cannot be deleted or overwritten for, measured from its
# own creation. With state = "Locked" this is a floor nobody can lower,
# including the subscription owner, and it can only ever be raised.
#
# One year, matching the AWS module, and for the same reason: state
# history is useful until the next apply, but an audit trail is useful
# when somebody asks what was read months ago — and that question is
# usually prompted by finding out late. Whatever the shortest interval is
# between a compromise and its discovery, this should be longer.
variable "anchor_retention_days" {
  type        = number
  default     = 365
  description = "Immutability period in days. Cannot be shortened once locked."
}

# "Locked" is the guarantee. "Unlocked" is a policy an administrator can
# shorten or remove, which is the S3 GOVERNANCE equivalent and protects
# nothing against the threat this account exists for — somebody who
# reached privileged credentials.
#
# It is a variable rather than a constant only because locking is
# irreversible and permanently blocks destroying this module's
# resources. Try it Unlocked; run it Locked. "Disabled" is offered by the
# provider and deliberately not offered here: an account named
# audit-anchors with immutability disabled is the arrangement most likely
# to be mistaken for protection it does not have.
variable "anchor_immutability_state" {
  type    = string
  default = "Locked"

  validation {
    condition     = contains(["Locked", "Unlocked"], var.anchor_immutability_state)
    error_message = "Must be \"Locked\" (the guarantee) or \"Unlocked\" (an admin can lift it). \"Disabled\" is not offered: see variables.tf."
  }
}

# CIDRs allowed to reach the anchor account. Empty leaves the network
# default at Allow, which is what makes the account readable from
# wherever an incident is being worked. Naming any range flips the
# default to Deny.
variable "allowed_ip_ranges" {
  type        = list(string)
  default     = []
  description = "CIDRs allowed to reach the anchor account. Empty leaves the network default at Allow."
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

# Not cluster_name. One state bucket is expected to serve every cluster
# in the account — the state key is what separates them (see the
# backend_config output), and creating a bucket per cluster puts the
# thing that survives a teardown on the same lifecycle as the thing being
# torn down.
variable "name_prefix" {
  type        = string
  default     = "vault-reference"
  description = "Prefix for the bucket and KMS alias. Not the cluster name."
}

# The cluster whose state key the backend_config output is written for.
# It names nothing this module creates; the bucket serves any number of
# clusters, one state key each.
variable "cluster_name" {
  type    = string
  default = "vault-reference"
}

# Set this when the account already has a state bucket, or when a naming
# convention says what it must be called. Left null, the name gets a
# random suffix, because S3 bucket names are globally unique across every
# AWS account and "vault-reference-tfstate" belongs to somebody already.
variable "state_bucket_name" {
  type    = string
  default = null
}

variable "state_version_retention_days" {
  type        = number
  default     = 90
  description = "How long superseded state versions stay recoverable."
}

variable "tags" {
  type    = map(string)
  default = {}
}

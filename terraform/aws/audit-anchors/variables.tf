variable "aws_region" {
  type    = string
  default = "us-east-1"
}

# Not cluster_name, for the same reason bootstrap/variables.tf gives: one
# anchor bucket is expected to serve every cluster in the estate, and the
# key prefix is what separates them. ship-anchors.sh takes --cluster and
# writes under it.
#
# There is a second reason here. A bucket per cluster is a bucket created
# by whoever creates the cluster, which puts the evidence on the same
# lifecycle -- and in the same blast radius -- as the thing it is
# evidence about.
variable "name_prefix" {
  type        = string
  default     = "vault-reference"
  description = "Prefix for the bucket and IAM policy name. Not the cluster name."
}

# Set this when a naming convention says what the bucket must be called.
# Left null it gets a random suffix, because S3 bucket names are globally
# unique across every AWS account.
variable "anchor_bucket_name" {
  type    = string
  default = null
}

# The floor for objects written without an explicit retention, in
# COMPLIANCE mode -- so this is how long an anchor cannot be deleted for,
# by anyone, including you.
#
# One year rather than the 90 days bootstrap gives state versions,
# because these answer a different question. State history is useful
# until the next apply; an audit trail is useful when somebody asks what
# was read months ago, and that question is usually prompted by finding
# out about it late. Whatever the shortest interval is between a
# compromise and its discovery, this should be longer.
#
# It is also a storage bill that cannot be cancelled early. Anchors are
# three fields of text, so the bill is small, but "small" is the reason
# it is affordable rather than a reason not to have chosen it.
variable "anchor_retention_days" {
  type        = number
  default     = 365
  description = "COMPLIANCE retention floor, in days. Cannot be shortened later."
}

variable "tags" {
  type    = map(string)
  default = {}
}

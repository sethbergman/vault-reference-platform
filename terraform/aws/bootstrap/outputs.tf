output "state_bucket" {
  value       = aws_s3_bucket.tfstate.id
  description = "Bucket holding the state for terraform/aws."
}

output "kms_key_arn" {
  value       = aws_kms_key.tfstate.arn
  description = "Key the state objects are encrypted under."
}

# Generated rather than written down, for the same reason
# scripts/terraform-to-ansible.sh generates group_vars: a bucket name
# copied by hand into a second file is a bucket name that can differ from
# the one that exists, and the way you find out is a `terraform init`
# that creates an empty state and offers to build the cluster again.
#
#   terraform -chdir=terraform/aws/bootstrap output -raw backend_config \
#     > terraform/aws/backend.hcl
#
# See docs/terraform-state.md.
output "backend_config" {
  value       = <<-EOT
    bucket = "${aws_s3_bucket.tfstate.id}"
    key    = "${var.cluster_name}/terraform.tfstate"
    region = "${var.aws_region}"

    kms_key_id = "${aws_kms_key.tfstate.arn}"
    encrypt    = true

    use_lockfile = true
  EOT
  description = "Contents of terraform/aws/backend.hcl."
}

# The permissions an identity needs to run `terraform` against the state
# this bucket holds -- and nothing else. Generated rather than written
# down, for the reason backend_config is: the ARNs exist only once this
# module has applied, and a policy with a copied bucket name is a policy
# that can name the wrong bucket.
#
#   terraform -chdir=terraform/aws/bootstrap output -raw state_policy \
#     > state-policy.json
#   aws iam create-policy --policy-name vault-reference-terraform-state \
#     --policy-document file://state-policy.json
#
# This is not the policy that builds the cluster. That one is
# examples/policies/aws-terraform-apply.json, and it deliberately carries
# nothing for the state bucket: who may read and write the state is a
# different question from who may create the infrastructure, and an
# identity that does both attaches both.
#
# WHERE THE ACTIONS COME FROM
#
# The four S3 actions were read off a recording of every request Terraform
# 1.15.9's backend made during init, plan, two applies, a contested lock,
# destroy and `state list`: five request shapes, 39 requests, nothing else.
# tests/state-backend runs the profile as an identity holding only this
# document, against an emulator that evaluates it (resource ARN included),
# and re-derives the set from a fresh recording on every run -- so a
# Terraform release that starts asking the bucket something new fails
# there and names the action.
#
# The KMS statement is the one part no recording can produce. Terraform
# sends the key id in a header and S3 calls KMS on the caller's behalf, so
# an emulator whose S3 performs no cryptography never sees a KMS request;
# the recording has none. On AWS, writing an object under SSE-KMS needs
# kms:GenerateDataKey and reading one needs kms:Decrypt, and an identity
# without them fails its first `init` with an AccessDenied that names KMS
# rather than S3. That statement is asserted to name this module's own
# key, and is otherwise unverified until a real account evaluates it.
#
# SCOPED TO THIS CLUSTER'S PREFIX, NOT THE BUCKET
#
# One bucket holds the state of many clusters, one key each (see the
# backend_config output). An identity that may run terraform against one
# of them should not be able to read the others', so the object actions
# are granted on `<cluster_name>/*` -- which covers the state object and
# the `.tflock` beside it, and nothing else. ListBucket has to be on the
# bucket itself: it is how Terraform enumerates workspaces, under `env:/`,
# on every command, and S3 has no narrower resource for a listing.
output "state_policy" {
  value = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ListTheBucketToFindWorkspaces"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = aws_s3_bucket.tfstate.arn
      },
      {
        Sid      = "ReadWriteAndLockThisClustersState"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = "${aws_s3_bucket.tfstate.arn}/${var.cluster_name}/*"
      },
      {
        Sid      = "EncryptAndDecryptStateUnderTheBucketsKey"
        Effect   = "Allow"
        Action   = ["kms:GenerateDataKey", "kms:Decrypt"]
        Resource = aws_kms_key.tfstate.arn
      },
    ]
  })
  description = "IAM policy for an identity that runs terraform against this cluster's state. Not the policy that builds the cluster; see docs/terraform-state.md."
}

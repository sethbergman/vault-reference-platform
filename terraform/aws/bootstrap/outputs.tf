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

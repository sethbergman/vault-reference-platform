# Points the AWS profile at a local emulator instead of AWS.
#
# Copied into terraform/aws/ by tests/cloud-apply-emulated/run-tests.sh and
# removed afterwards. The _override.tf suffix is load-bearing: Terraform
# merges override files over the configuration, so this replaces the
# provider block in main.tf without editing it.
#
# WHAT THIS IS FOR
#
# `terraform test` runs against mocked providers, which answer from a
# fixture and never exercise the provider's own request or response
# handling. This runs a real `terraform apply` through the real AWS
# provider against an implementation of the AWS API, so the questions it
# settles are different ones: does the configuration apply at all, in this
# order, with these values, without a required argument missing or a
# reference that cannot resolve.
#
# WHAT IT IS NOT
#
# An emulator is not AWS. It implements the API surface, not the service:
# there is no real KMS cryptography, no instance ever boots, no health
# check is ever performed, and no autoscaling group ever replaces
# anything. A green run here is evidence the configuration is applyable,
# and it is not evidence that the cluster works. The claims that need a
# real apply are listed in docs/cloud-apply.md and this does not shorten
# that list -- it removes the ones that never needed to be on it.

provider "aws" {
  region = var.aws_region

  access_key = "emulated"
  secret_key = "emulated"

  # Nothing here talks to real AWS, so the provider must not try to
  # validate credentials, read instance metadata, or resolve an account id
  # through STS before it starts.
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
  skip_region_validation      = true

  # The emulator serves buckets on a path rather than a virtual host,
  # because there is no wildcard DNS in front of it.
  s3_use_path_style = true

  endpoints {
    autoscaling = "http://localhost:5000"
    ec2         = "http://localhost:5000"
    elbv2       = "http://localhost:5000"
    iam         = "http://localhost:5000"
    kms         = "http://localhost:5000"
    logs        = "http://localhost:5000"
    s3          = "http://localhost:5000"
    sts         = "http://localhost:5000"
  }
}

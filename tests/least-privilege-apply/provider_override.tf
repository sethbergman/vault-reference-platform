# Points the AWS profile at a local emulator that enforces IAM.
#
# Copied into terraform/aws/ by tests/least-privilege-apply/run-tests.sh and
# removed afterwards. The _override.tf suffix is load-bearing: Terraform
# merges override files over the configuration, so this replaces the provider
# block in main.tf without editing it.
#
# WHY THIS IS NOT tests/cloud-apply-emulated/provider_override.tf
#
# That one hardcodes `access_key = "emulated"`, because what it asks is
# whether the profile applies at all and the identity is irrelevant. Here the
# identity is the whole question, and the key belongs to an IAM user this
# suite creates at runtime — so there is no key to hardcode. The provider
# reads AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY from the environment
# instead, which the harness sets per case.
#
# skip_requesting_account_id stays on, and does NOT remove the need for
# sts:GetCallerIdentity: the profile calls it through a data source anyway,
# which the recorded derivation caught and nobody writing this policy by hand
# would have.

provider "aws" {
  region = var.aws_region

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
    ssm         = "http://localhost:5000"
    sts         = "http://localhost:5000"
  }
}

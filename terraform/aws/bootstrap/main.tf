# The bucket that holds the state for terraform/aws.
#
# WHY THIS IS A SEPARATE ROOT MODULE
#
# A backend cannot store state in a bucket that does not exist yet, and
# the bucket cannot be created by the configuration whose state it holds
# — that configuration has nowhere to record having created it. Something
# has to be first. This is that thing.
#
# Keeping it separate is not only about ordering. If the state bucket
# were a resource in terraform/aws, `terraform destroy` of the cluster
# would delete the bucket holding the state of the destroy that is
# running, and the failure would land halfway through. A reference that
# cannot be taken down cleanly is the failure scripts/teardown-cloud.sh
# already exists to work around; this avoids adding a second one.
#
# APPLY THIS ONCE PER ACCOUNT AND REGION, then never again. The outputs
# feed terraform/aws's `-backend-config`; see docs/terraform-state.md.
#
# ITS OWN STATE IS LOCAL, DELIBERATELY
#
# The regress is infinite otherwise. What makes local state acceptable
# *here* and not in terraform/aws is that this module creates four
# resources, changes approximately never, and holds nothing whose loss
# costs an outage: if the state file is lost, `terraform import` recovers
# it from resources whose names are all knowable, and in the meantime the
# clusters using the bucket carry on unaffected. Losing the state of a
# running Vault cluster is a different sentence entirely.

terraform {
  required_version = ">= 1.7"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    # The bucket name has to be globally unique across every AWS account,
    # the same constraint the snapshot bucket has in ../storage.tf.
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

resource "random_id" "suffix" {
  byte_length = 4
}

locals {
  bucket_name = coalesce(var.state_bucket_name, "${var.name_prefix}-tfstate-${random_id.suffix.hex}")
}

# A key of its own, not the cluster's auto-unseal key.
#
# The auto-unseal key lives in terraform/aws's state, so encrypting that
# state under it would make the state unreadable without first reading
# the state. It is also scheduled for deletion by a cluster teardown,
# which would take the state of every other cluster in the bucket with
# it.
#
# Rotation is transparent: S3 decrypts objects written under previous key
# versions without any action here.
resource "aws_kms_key" "tfstate" {
  description = "Terraform state encryption for ${var.name_prefix}"
  # Long, because scheduling this key is scheduling the loss of control
  # over every cluster whose state is in the bucket. Thirty days is the
  # same window main.tf gives the auto-unseal key, for the same reason.
  deletion_window_in_days = 30
  enable_key_rotation     = true

  tags = var.tags
}

resource "aws_kms_alias" "tfstate" {
  name          = "alias/${var.name_prefix}-tfstate"
  target_key_id = aws_kms_key.tfstate.key_id
}

resource "aws_s3_bucket" "tfstate" {
  bucket = local.bucket_name

  # force_destroy stays off. With it on, `terraform destroy` here would
  # empty the bucket first — deleting the state of every running cluster
  # in one command that succeeds.
  force_destroy = false

  # And destroy is refused outright, because the guard above only makes
  # the deletion fail late. Removing this line is a deliberate act, which
  # is the point: the state of a running Vault cluster should not be
  # destroyable by a command run in the wrong directory.
  #
  # If the bucket genuinely has to go, delete this block, or drop the
  # bucket from state with `terraform state rm` and remove it by hand.
  lifecycle {
    prevent_destroy = true
  }

  tags = var.tags
}

# The property that makes a corrupted write survivable.
#
# Terraform writes state by overwriting the object. A partial write, a
# bad merge after a failed apply, or a `terraform state rm` run against
# the wrong resource all leave the current version wrong and the previous
# version correct. Without versioning there is no previous version.
resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.tfstate.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Bounded history rather than unbounded. Every apply writes a new version
# of every state file, so a bucket serving a few clusters accumulates
# thousands of objects over a year — and the useful window for rolling
# back to a previous state is days, not years.
#
# Deliberately longer than the snapshot retention default: a state file
# nobody noticed was wrong is discovered when someone next runs a plan,
# which can be weeks after the apply that broke it.
resource "aws_s3_bucket_lifecycle_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    id     = "expire-old-state-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = var.state_version_retention_days
    }

    # Deleting a state file leaves a delete marker rather than removing
    # the history behind it, and a bucket full of delete markers is how
    # a list operation gets slow enough to time out a plan.
    expiration {
      expired_object_delete_marker = true
    }
  }

  depends_on = [aws_s3_bucket_versioning.tfstate]
}

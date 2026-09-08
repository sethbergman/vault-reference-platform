# The bucket that holds audit chain anchors, and cannot let go of them.
#
# WHY THIS IS A SEPARATE ROOT MODULE
#
# The same reason terraform/aws/bootstrap is one, applied to evidence
# instead of state: a `terraform destroy` of the cluster must not be able
# to delete the record of what that cluster did. If this bucket were a
# resource in terraform/aws, the credential that tears down a compromised
# Vault node would also be the credential that removes the anchors
# proving what was read from it — and the teardown would look clean.
#
# It is also the one piece here that genuinely belongs in a different
# account. Nothing in this module can enforce that, because an account
# boundary is not a resource; what it can do is be a root module of its
# own, so pointing it at a second provider is a `-var` and not a
# refactor. docs/audit.md says which properties survive that being
# skipped and which do not.
#
# APPLY THIS ONCE, IDEALLY SOMEWHERE THE VAULT NODES CANNOT REACH.
#
# WHAT COMPLIANCE MODE COSTS
#
# Object lock in COMPLIANCE mode cannot be shortened, overridden or
# deleted by anyone, including the account root, until the retention
# expires. That is the entire property being bought: an attacker holding
# every credential this repository uses still cannot erase an anchor.
#
# The cost is symmetrical and worth knowing before the first apply.
# Objects written here are storage you will pay for until retention
# expires, this bucket cannot be emptied to delete it, and a typo in the
# prefix cannot be cleaned up. Retention is per-object and set at write
# time by scripts/ship-anchors.sh, so the default below is a floor for
# new objects, not a lever over existing ones.
#
# GOVERNANCE mode would allow a privileged delete, which reads as the
# safer default and is not: the whole threat model here is somebody who
# reached privileged credentials.

terraform {
  required_version = ">= 1.7"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
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
  bucket_name = coalesce(var.anchor_bucket_name, "${var.name_prefix}-audit-anchors-${random_id.suffix.hex}")
}

# Object lock can only be turned on when the bucket is created.
#
# There is no path from an ordinary bucket to a locked one, which is why
# ship-anchors.sh checks for it and refuses rather than warning: by the
# time anchors are landing in an unlocked bucket, fixing it means a new
# bucket and re-shipping, and the anchors written in between were never
# protected.
resource "aws_s3_bucket" "anchors" {
  bucket = local.bucket_name

  # Would not work anyway — S3 refuses to empty a bucket holding locked
  # objects — but leaving it at the default states the intent rather
  # than relying on the service to enforce it.
  force_destroy = false

  lifecycle {
    prevent_destroy = true
  }

  object_lock_enabled = true

  tags = var.tags
}

# Object lock requires versioning, and requires it enabled rather than
# suspended. It is not optional decoration: the lock protects an object
# *version*, so without versioning there is nothing for it to protect.
#
# It is also what makes a hidden anchor recoverable. A delete with no
# version id writes a marker that hides the key without destroying the
# version beneath it, and ship-anchors.sh --fetch reads that version
# back by id. Suspending versioning later would leave the anchors
# already written protected and every anchor after it not.
resource "aws_s3_bucket_versioning" "anchors" {
  bucket = aws_s3_bucket.anchors.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_object_lock_configuration" "anchors" {
  bucket = aws_s3_bucket.anchors.id

  rule {
    default_retention {
      mode = "COMPLIANCE"
      days = var.anchor_retention_days
    }
  }

  depends_on = [aws_s3_bucket_versioning.anchors]
}

# SSE-S3 rather than the KMS key used elsewhere in this repository.
#
# An anchor is a sequence number and a hash — it is not secret, and it is
# already public information to anyone holding the audit log. What it
# must be is *readable during an incident*, and a KMS key adds a second
# thing that has to still exist and still be grantable at the moment
# somebody is trying to prove what happened. Encrypting evidence under a
# key the attacker may have scheduled for deletion trades the property
# this bucket exists for against one it does not need.
resource "aws_s3_bucket_server_side_encryption_configuration" "anchors" {
  bucket = aws_s3_bucket.anchors.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "anchors" {
  bucket = aws_s3_bucket.anchors.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# The credential that ships anchors cannot remove them.
#
# This is the third property in docs/audit.md's table and the one most
# often skipped, because the shipper works without it.
#
# It is not redundant with the lock, and the gap it covers is narrower
# than it looks. Object lock refuses to delete a *version*. It permits a
# delete marker over the key, because a marker destroys nothing — and a
# marked key is absent from list-objects-v2 and 404s on head-object, so
# every anchor can be made invisible by the same credential that ships
# them, without one of them being destroyed.
#
# scripts/ship-anchors.sh reads Versions[] rather than Contents[] so that
# it recovers and reports them. This is the other half: the marker cannot
# be written at all. Neither measure alone is sufficient — a policy can
# be detached, and a fetch that reports a marker is still a fetch
# somebody has to run.
#
# The bucket policy in ../iam.tf keeps s3:DeleteObject off the snapshot
# role for a related reason and is worth reading beside this.
data "aws_iam_policy_document" "ship_anchors" {
  statement {
    sid    = "WriteAnchorsNeverRemoveThem"
    effect = "Allow"
    actions = [
      "s3:PutObject",
      "s3:PutObjectRetention",
    ]
    resources = ["${aws_s3_bucket.anchors.arn}/*"]
  }

  # Reading is what makes the anchor useful, and ship-anchors.sh needs
  # it to detect a conflicting sequence rather than overwrite one.
  statement {
    sid    = "ReadAnchorsBack"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:GetObjectRetention",
      "s3:GetObjectVersion",
    ]
    resources = ["${aws_s3_bucket.anchors.arn}/*"]
  }

  statement {
    sid    = "ListAndConfirmTheLock"
    effect = "Allow"
    actions = [
      "s3:ListBucket",
      # ship-anchors.sh lists versions rather than objects, and that is
      # a separate permission. Without it the shipper sees an empty
      # bucket: every anchor reads as never shipped, so a conflicting
      # sequence is written as a new one and --fetch returns nothing.
      "s3:ListBucketVersions",
      "s3:GetBucketObjectLockConfiguration",
    ]
    resources = [aws_s3_bucket.anchors.arn]
  }

  # Explicit rather than merely absent. An unstated action is denied
  # until some future policy attached to the same principal allows it;
  # an explicit Deny cannot be granted around.
  #
  # DeleteObject with no version id is the delete marker, and it leads
  # the list deliberately: it is the one operation here that object lock
  # does not already refuse.
  statement {
    sid    = "NeverDelete"
    effect = "Deny"
    actions = [
      "s3:DeleteObject",
      "s3:DeleteObjectVersion",
      "s3:PutBucketObjectLockConfiguration",
      "s3:BypassGovernanceRetention",
    ]
    resources = [
      aws_s3_bucket.anchors.arn,
      "${aws_s3_bucket.anchors.arn}/*",
    ]
  }
}

resource "aws_iam_policy" "ship_anchors" {
  name        = "${var.name_prefix}-ship-audit-anchors"
  description = "Write audit chain anchors to ${local.bucket_name}; never remove one"
  policy      = data.aws_iam_policy_document.ship_anchors.json

  tags = var.tags
}

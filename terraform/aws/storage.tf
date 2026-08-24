# S3 bucket for Raft snapshots (see docs/disaster-recovery.md and
# scripts/snapshot.sh).
#
# Worth repeating from that doc: a snapshot is encrypted under the
# auto-unseal KMS key, so this bucket on its own is not a recoverable
# backup. The KMS key has to survive too, and must not be scheduled for
# deletion when a cluster is torn down.

resource "random_id" "bucket_suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "snapshots" {
  # S3 bucket names are globally unique across all AWS accounts, so a
  # cluster name alone will collide with someone.
  bucket = "${var.cluster_name}-vault-snapshots-${random_id.bucket_suffix.hex}"

  tags = merge(module.vault_cluster.cluster_tags, {
    Name = "${var.cluster_name}-vault-snapshots"
  })
}

# Versioning matters more than usual here: it means a snapshot overwritten
# with a corrupt one is still recoverable.
resource "aws_s3_bucket_versioning" "snapshots" {
  bucket = aws_s3_bucket.snapshots.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "snapshots" {
  bucket = aws_s3_bucket.snapshots.id

  rule {
    apply_server_side_encryption_by_default {
      # Encrypted with the same key that seals the cluster. Belt and
      # braces — the snapshot contents are already encrypted by Vault.
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.vault_autounseal.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "snapshots" {
  bucket = aws_s3_bucket.snapshots.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Expire old snapshots rather than letting nodes delete them, which is why
# the node policy in iam.tf grants no s3:DeleteObject.
resource "aws_s3_bucket_lifecycle_configuration" "snapshots" {
  bucket = aws_s3_bucket.snapshots.id

  rule {
    id     = "expire-old-snapshots"
    status = "Enabled"

    filter {
      prefix = "snapshots/"
    }

    expiration {
      days = var.snapshot_retention_days
    }

    noncurrent_version_expiration {
      noncurrent_days = var.snapshot_retention_days
    }
  }

  depends_on = [aws_s3_bucket_versioning.snapshots]
}

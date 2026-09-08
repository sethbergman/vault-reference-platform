output "anchor_bucket" {
  value       = aws_s3_bucket.anchors.id
  description = "Bucket receiving the anchors. Pass to ship-anchors.sh --bucket."
}

output "anchor_bucket_arn" {
  value       = aws_s3_bucket.anchors.arn
  description = "ARN of the anchor bucket."
}

output "ship_anchors_policy_arn" {
  value       = aws_iam_policy.ship_anchors.arn
  description = <<-EOT
    Attach to whatever runs ship-anchors.sh. It can write an anchor and
    read one back; it is explicitly denied every way of removing one.
  EOT
}

output "anchor_retention_days" {
  value       = var.anchor_retention_days
  description = "How long a shipped anchor cannot be deleted for, by anyone."
}

# The command, rather than the bucket name to paste into one.
#
# Same reasoning as bootstrap's backend_config output: a name copied by
# hand is a name that can be copied wrong, and the way you find out here
# is anchors landing somewhere unlocked while the runbook says they are
# protected.
output "ship_command" {
  value       = <<-EOT
    ./scripts/ship-anchors.sh \
        --bucket ${aws_s3_bucket.anchors.id} \
        --cluster <cluster-name> \
        --retention-days ${var.anchor_retention_days}
  EOT
  description = "How to ship the local anchors to this bucket."
}

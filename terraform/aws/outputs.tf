output "vault_autounseal_kms_key_id" {
  description = "KMS key ID for the seal \"awskms\" stanza (kms_key_id) in vault.hcl"
  value       = aws_kms_key.vault_autounseal.key_id
}

output "vault_autounseal_kms_region" {
  description = "Region for the seal \"awskms\" stanza (region) in vault.hcl"
  value       = var.aws_region
}

output "vault_autounseal_iam_policy_arn" {
  description = "IAM policy allowing use of the auto-unseal key. Now attached to the node role; exposed for attaching to other principals."
  value       = aws_iam_policy.vault_autounseal.arn
}

output "vault_addr" {
  description = "VAULT_ADDR for clients. Resolvable from inside the VPC when the load balancer is internal."
  value       = "https://${aws_lb.vault.dns_name}:8200"
}

output "vault_lb_dns_name" {
  description = "Load balancer DNS name, for pointing a friendlier CNAME at the cluster."
  value       = aws_lb.vault.dns_name
}

output "vault_snapshot_bucket" {
  description = "S3 bucket for Raft snapshots — set as VAULT_BACKUP_BUCKET for scripts/snapshot.sh."
  value       = aws_s3_bucket.snapshots.id
}

output "vault_security_group_id" {
  description = "Security group applied to the Vault nodes."
  value       = aws_security_group.vault.id
}

output "vpc_id" {
  description = "VPC the cluster runs in."
  value       = aws_vpc.vault.id
}

output "private_subnet_ids" {
  description = "Private subnets holding the Vault nodes."
  value       = aws_subnet.private[*].id
}

output "autoscaling_group_name" {
  description = "Autoscaling group name, for triggering an instance refresh during upgrades."
  value       = aws_autoscaling_group.vault.name
}

output "vault_cluster_tag" {
  description = "Tag identifying cluster members. Used by Raft auto-join and by Ansible dynamic inventory."
  value       = "VaultCluster=${var.cluster_name}"
}

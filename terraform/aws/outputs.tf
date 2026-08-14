output "vault_autounseal_kms_key_id" {
  description = "KMS key ID for the seal \"awskms\" stanza (kms_key_id) in vault.hcl"
  value       = aws_kms_key.vault_autounseal.key_id
}

output "vault_autounseal_kms_region" {
  description = "Region for the seal \"awskms\" stanza (region) in vault.hcl"
  value       = var.aws_region
}

output "vault_autounseal_iam_policy_arn" {
  description = "IAM policy to attach to the Vault node instance role once it exists"
  value       = aws_iam_policy.vault_autounseal.arn
}

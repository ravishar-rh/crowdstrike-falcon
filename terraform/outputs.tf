output "secret_arn" {
  description = "ARN of the Falcon API credentials secret."
  value       = aws_secretsmanager_secret.falcon.arn
}

output "secret_name" {
  description = "Name of the secret. This is the value ESO uses as remoteRef.key."
  value       = aws_secretsmanager_secret.falcon.name
}

output "kms_key_arn" {
  description = "CMK protecting the secret, if one is in use."
  value       = local.kms_key_arn
}

output "eso_role_arn" {
  description = "IAM role the hub's External Secrets Operator assumes. The only principal that can read the secret."
  value       = aws_iam_role.eso.arn
}

output "set_secret_command" {
  description = "Copy-paste command to write the real credential without putting it in Terraform state."
  value       = <<-EOT
    ./scripts/bw-to-aws.sh \
      --bw-item '<bitwarden item name or id>' \
      --secret-id '${aws_secretsmanager_secret.falcon.name}' \
      --region '${var.aws_region}'
  EOT
}

# The AWS-side values that acm/hub/external-secrets.yaml must carry.
#
# That manifest is hand-written and committed rather than generated, because
# generated YAML loses the inline comments that make it reviewable. To keep it
# honest, scripts/validate.sh compares these values against the manifest
# whenever Terraform state is reachable, so drift fails a local check instead
# of failing an Argo sync.
output "hub_secret_store_values" {
  description = "Values that must match acm/hub/external-secrets.yaml."
  value = {
    region            = var.aws_region
    role              = aws_iam_role.eso.arn
    secretName        = aws_secretsmanager_secret.falcon.name
    esoNamespace      = var.eso_namespace
    esoServiceAccount = var.eso_service_account
    externalSecretNS  = var.acm_policy_namespace
  }
}

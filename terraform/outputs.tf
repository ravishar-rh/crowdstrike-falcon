output "secret_arn" {
  description = "ARN of the Falcon API credentials secret."
  value       = aws_secretsmanager_secret.falcon.arn
}

output "secret_name" {
  description = "Name of the secret. Must equal remoteRef.key in acm/02-credentials/external-secrets.yaml."
  value       = aws_secretsmanager_secret.falcon.name
}

output "kms_key_arn" {
  description = "CMK protecting the secret, if one is in use."
  value       = local.kms_key_arn
}

output "access_granted_to" {
  description = "IAM roles granted read access via the secret's resource policy. Empty means the existing ESO role is expected to already have prefix access."
  value       = var.eso_role_arns
}

# Printed by the workflow so the one manual step is a click away.
output "set_value_console_url" {
  description = "Console link for typing in the real client ID and secret."
  value = format(
    "https://%s.console.aws.amazon.com/secretsmanager/secret?name=%s&region=%s",
    var.aws_region,
    urlencode(aws_secretsmanager_secret.falcon.name),
    var.aws_region,
  )
}

output "next_step" {
  description = "What to do after apply."
  value       = <<-EOT
    Set the real credential by hand (Secrets Manager -> Retrieve secret value
    -> Edit), replacing both REPLACE_IN_CONSOLE placeholders. Keep the JSON
    keys exactly as they are -- they are what the ExternalSecret reads:

      {
        "client_id":     "...",
        "client_secret": "..."
      }

    Terraform ignores changes to this value, so a later apply will not
    overwrite it.
  EOT
}

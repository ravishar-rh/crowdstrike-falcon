data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  account_id  = data.aws_caller_identity.current.account_id
  partition   = data.aws_partition.current.partition
  kms_key_arn = var.create_kms_key ? aws_kms_key.falcon[0].arn : var.kms_key_arn

  grant_access = length(var.eso_role_arns) > 0
}

# A CMK with no principal allowed to decrypt is a secret nobody can read.
# Fail at plan time rather than leaving ESO to report SecretSyncedError.
resource "terraform_data" "validate_kms_grant" {
  lifecycle {
    precondition {
      condition     = !var.create_kms_key || local.grant_access
      error_message = "create_kms_key = true requires eso_role_arns to be set: a customer-managed key needs an explicit key policy grant, and unlike Secrets Manager there is no 'either side may allow' evaluation for KMS."
    }
  }
}

# ---------------------------------------------------------------------------
# KMS
# ---------------------------------------------------------------------------
resource "aws_kms_key" "falcon" {
  count = var.create_kms_key ? 1 : 0

  description             = "Encrypts the CrowdStrike Falcon API credentials in Secrets Manager"
  enable_key_rotation     = true
  deletion_window_in_days = 30

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Sid       = "AllowAccountAdministration"
          Effect    = "Allow"
          Principal = { AWS = "arn:${local.partition}:iam::${local.account_id}:root" }
          Action    = "kms:*"
          Resource  = "*"
        },
        {
          Sid       = "AllowSecretsManagerService"
          Effect    = "Allow"
          Principal = { Service = "secretsmanager.amazonaws.com" }
          Action    = ["kms:Decrypt", "kms:GenerateDataKey*", "kms:DescribeKey"]
          Resource  = "*"
        },
      ],
      local.grant_access ? [
        {
          Sid       = "AllowExternalSecretsOperatorToDecrypt"
          Effect    = "Allow"
          Principal = { AWS = var.eso_role_arns }
          Action    = ["kms:Decrypt", "kms:DescribeKey"]
          Resource  = "*"
          Condition = {
            StringEquals = {
              "kms:ViaService" = "secretsmanager.${var.aws_region}.amazonaws.com"
            }
          }
        },
      ] : [],
    )
  })

  tags = merge(var.tags, { Name = "${var.name_prefix}-credentials" })
}

resource "aws_kms_alias" "falcon" {
  count = var.create_kms_key ? 1 : 0

  name          = "alias/${var.name_prefix}-credentials"
  target_key_id = aws_kms_key.falcon[0].key_id
}

# ---------------------------------------------------------------------------
# Secret
# ---------------------------------------------------------------------------
resource "aws_secretsmanager_secret" "falcon" {
  name        = var.secret_name
  description = "CrowdStrike Falcon API client credentials. Value is set by hand in the console -- Terraform never manages it."
  kms_key_id  = local.kms_key_arn != "" ? local.kms_key_arn : null

  recovery_window_in_days = var.recovery_window_days

  dynamic "replica" {
    for_each = toset(var.replica_regions)
    content {
      region = replica.value
    }
  }

  tags = merge(var.tags, { Name = var.secret_name })
}

# Bootstrap payload only.
#
# Terraform creates the JSON shape once so ESO has something well-formed to
# read, then never touches the value again. The real client ID and secret are
# typed into the Secrets Manager console by hand.
#
# This is why no Falcon credential ever reaches Terraform state, a tfvars
# file, a plan output, or GitHub Actions logs -- which is what lets this
# repository be public.
resource "aws_secretsmanager_secret_version" "bootstrap" {
  secret_id = aws_secretsmanager_secret.falcon.id

  secret_string = jsonencode({
    client_id     = "REPLACE_IN_CONSOLE"
    client_secret = "REPLACE_IN_CONSOLE"
  })

  lifecycle {
    # Without this, the next apply would overwrite the real credential with
    # the placeholder and break image pulls fleet-wide.
    ignore_changes = [secret_string]
  }
}

# Grants your existing ESO role read access without modifying that role.
#
# Within one account, a request is authorised if EITHER the identity policy
# OR the resource policy allows it. So naming the role here is sufficient,
# and this stack never has to touch a role owned by another automation.
resource "aws_secretsmanager_secret_policy" "falcon" {
  count = local.grant_access ? 1 : 0

  secret_arn = aws_secretsmanager_secret.falcon.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowExternalSecretsOperatorRead"
        Effect    = "Allow"
        Principal = { AWS = var.eso_role_arns }
        Action    = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
        Resource  = "*"
      },
      {
        Sid       = "AllowAccountAdministration"
        Effect    = "Allow"
        Principal = { AWS = "arn:${local.partition}:iam::${local.account_id}:root" }
        Action    = "secretsmanager:*"
        Resource  = "*"
      },
    ]
  })
}

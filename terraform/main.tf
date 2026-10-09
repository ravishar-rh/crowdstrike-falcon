data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition

  kms_key_arn = var.create_kms_key ? aws_kms_key.falcon[0].arn : var.kms_key_arn
}

# ---------------------------------------------------------------------------
# KMS
# ---------------------------------------------------------------------------
resource "aws_kms_key" "falcon" {
  count = var.create_kms_key ? 1 : 0

  description             = "Encrypts the CrowdStrike Falcon API credentials in Secrets Manager"
  enable_key_rotation     = true
  deletion_window_in_days = 30

  # The key policy is the real access control. The IAM policies attached to
  # the ESO roles grant kms:Decrypt, but a CMK also requires the key policy to
  # allow it -- both sides must agree, which is exactly the property that
  # makes a CMK auditable here.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
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
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey*",
          "kms:DescribeKey",
        ]
        Resource = "*"
      },
      {
        Sid       = "AllowHubEsoRoleToDecrypt"
        Effect    = "Allow"
        Principal = { AWS = aws_iam_role.eso.arn }
        Action = [
          "kms:Decrypt",
          "kms:DescribeKey",
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "kms:ViaService" = "secretsmanager.${var.aws_region}.amazonaws.com"
          }
        }
      },
    ]
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
  description = "CrowdStrike Falcon API client credentials consumed by falcon-operator via External Secrets Operator"
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

# Bootstrap payload. Created once so the JSON shape exists and ESO has
# something well-formed to read, then never touched again -- the real
# credential is written by scripts/bw-to-aws.sh.
resource "aws_secretsmanager_secret_version" "bootstrap" {
  count = var.manage_secret_value ? 0 : 1

  secret_id = aws_secretsmanager_secret.falcon.id
  secret_string = jsonencode({
    client_id     = "REPLACE_ME"
    client_secret = "REPLACE_ME"
  })

  lifecycle {
    # Without this, every apply after the credential is set would revert it to
    # REPLACE_ME and break the sensor fleet's ability to pull its image.
    ignore_changes = [secret_string]
  }
}

resource "aws_secretsmanager_secret_version" "managed" {
  count = var.manage_secret_value ? 1 : 0

  secret_id = aws_secretsmanager_secret.falcon.id
  secret_string = jsonencode({
    client_id     = var.falcon_client_id
    client_secret = var.falcon_client_secret
  })
}

# Deny-by-default on the secret itself: only the hub's ESO role may read it.
# IAM identity policies alone would let any sufficiently-privileged principal
# in the account read the credential; this resource policy is the second lock.
resource "aws_secretsmanager_secret_policy" "falcon" {
  secret_arn = aws_secretsmanager_secret.falcon.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowHubEsoRoleRead"
        Effect    = "Allow"
        Principal = { AWS = aws_iam_role.eso.arn }
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret",
        ]
        Resource = "*"
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

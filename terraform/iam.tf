# A single role, for the ACM hub's External Secrets Operator. Managed
# clusters receive the credential through an ACM hub template and have no AWS
# identity at all -- which is the main security benefit of the hub-only ESO
# topology: exactly one principal in the account can read this secret.

locals {
  # IAM trust-policy condition keys are built from the issuer host+path with
  # the scheme stripped: "https://oidc.op1.../abc" -> "oidc.op1.../abc:sub".
  oidc_host = replace(var.hub_oidc_issuer_url, "https://", "")
}

# AWS stopped validating thumbprints for OIDC providers, but the API still
# requires the field, so it is derived from the issuer's actual TLS chain
# rather than hardcoded.
data "tls_certificate" "oidc" {
  count = var.create_oidc_provider ? 1 : 0

  url = var.hub_oidc_issuer_url
}

resource "aws_iam_openid_connect_provider" "hub" {
  count = var.create_oidc_provider ? 1 : 0

  url             = var.hub_oidc_issuer_url
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.oidc[0].certificates[0].sha1_fingerprint]

  tags = merge(var.tags, { Name = "${var.name_prefix}-hub" })
}

data "aws_iam_openid_connect_provider" "hub" {
  count = var.create_oidc_provider ? 0 : 1

  url = var.hub_oidc_issuer_url
}

locals {
  oidc_provider_arn = (
    var.create_oidc_provider
    ? aws_iam_openid_connect_provider.hub[0].arn
    : data.aws_iam_openid_connect_provider.hub[0].arn
  )
}

resource "aws_iam_role" "eso" {
  name        = "${var.name_prefix}-hub"
  description = "Read-only access to the CrowdStrike Falcon API credentials for External Secrets Operator on the ACM hub"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Federated = local.oidc_provider_arn }
        Action    = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            # Pins the role to exactly one ServiceAccount. Without the :sub
            # condition, every ServiceAccount on the hub could assume it.
            "${local.oidc_host}:sub" = "system:serviceaccount:${var.eso_namespace}:${var.eso_service_account}"
            "${local.oidc_host}:aud" = "sts.amazonaws.com"
          }
        }
      },
    ]
  })

  tags = merge(var.tags, { Name = "${var.name_prefix}-hub" })
}

resource "aws_iam_policy" "eso" {
  name        = "${var.name_prefix}-read-credentials"
  description = "Read the CrowdStrike Falcon API credentials from Secrets Manager"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Sid    = "ReadFalconCredentials"
          Effect = "Allow"
          Action = [
            "secretsmanager:GetSecretValue",
            "secretsmanager:DescribeSecret",
          ]
          # Scoped to this one secret. Not secretsmanager:* on "*", which is
          # the usual shortcut and would hand the hub every secret in the
          # account.
          Resource = concat(
            [aws_secretsmanager_secret.falcon.arn],
            # Replicas live at a different ARN per region.
            [for r in var.replica_regions :
              "arn:${local.partition}:secretsmanager:${r}:${local.account_id}:secret:${var.secret_name}-*"
            ],
          )
        },
      ],
      local.kms_key_arn != "" ? [
        {
          Sid      = "DecryptWithFalconKey"
          Effect   = "Allow"
          Action   = ["kms:Decrypt", "kms:DescribeKey"]
          Resource = local.kms_key_arn
        },
      ] : [],
    )
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "eso" {
  role       = aws_iam_role.eso.name
  policy_arn = aws_iam_policy.eso.arn
}

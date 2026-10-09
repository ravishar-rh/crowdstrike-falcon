variable "aws_region" {
  description = "Region holding the Falcon API credentials secret."
  type        = string
  default     = "us-east-1"
}

variable "secret_name" {
  description = <<-EOT
    Name of the AWS Secrets Manager secret. Must match remoteRef.key in the
    hub ExternalSecret -- Terraform renders that manifest for you via the
    hub_external_secrets output, so the two stay in step automatically.
  EOT
  type        = string
  default     = "crowdstrike/falcon/api-credentials"
}

# ---------------------------------------------------------------------------
# Hub cluster
#
# External Secrets Operator runs on the ACM hub and nowhere else, so exactly
# one IAM role is created. Managed clusters receive the credential through an
# ACM hub template and never touch AWS.
# ---------------------------------------------------------------------------

variable "hub_oidc_issuer_url" {
  description = <<-EOT
    OIDC issuer of the ACM hub cluster, including the https:// prefix.
      ROSA/HCP:  rosa describe cluster -c <name> -o json | jq -r .aws.sts.oidc_endpoint_url
      Any OCP:   oc get authentication cluster -o jsonpath='{.spec.serviceAccountIssuer}'
  EOT
  type        = string

  validation {
    condition     = startswith(var.hub_oidc_issuer_url, "https://")
    error_message = "hub_oidc_issuer_url must start with https:// -- the IAM trust policy condition key is built from the host and path."
  }
}

variable "create_oidc_provider" {
  description = <<-EOT
    Create the IAM OIDC provider for the hub. ROSA and most OCP-on-AWS
    installs already have one, so this defaults to false and the existing
    provider is looked up instead. Creating a duplicate fails with
    EntityAlreadyExists, and owning it here would let a destroy take out all
    of the cluster's other IRSA.
  EOT
  type        = bool
  default     = false
}

variable "eso_namespace" {
  description = <<-EOT
    Namespace of the ESO controller ServiceAccount on the hub. Must match the
    serviceAccountRef in the generated ClusterSecretStore -- the role's trust
    policy pins this exact subject, so a mismatch fails with
    InvalidIdentityToken.
  EOT
  type        = string
  default     = "external-secrets"
}

variable "eso_service_account" {
  description = "Name of the ESO controller ServiceAccount on the hub."
  type        = string
  default     = "external-secrets"
}

# ---------------------------------------------------------------------------
# Secret value handling
# ---------------------------------------------------------------------------

variable "manage_secret_value" {
  description = <<-EOT
    Whether Terraform owns the credential value.

    false (default and recommended): Terraform creates the secret with a
    placeholder payload and then ignores the value forever. The real client ID
    and secret are written out-of-band -- see scripts/bw-to-aws.sh, which
    pipes them straight from your Bitwarden entry. Nothing sensitive ever
    reaches Terraform state.

    true: Terraform writes falcon_client_id/falcon_client_secret. Convenient,
    but the plaintext credential is then stored in your state file and in
    every plan output. Only do this with an encrypted remote backend and
    restricted state access.
  EOT
  type        = bool
  default     = false
}

variable "falcon_client_id" {
  description = "Falcon API client ID. Only read when manage_secret_value = true."
  type        = string
  default     = ""
  sensitive   = true
}

variable "falcon_client_secret" {
  description = "Falcon API client secret. Only read when manage_secret_value = true."
  type        = string
  default     = ""
  sensitive   = true
}

# ---------------------------------------------------------------------------
# Encryption, replication, naming
# ---------------------------------------------------------------------------

variable "create_kms_key" {
  description = <<-EOT
    Create a customer-managed KMS key for the secret. The AWS-managed
    aws/secretsmanager key cannot carry a key policy, so with it you cannot
    prove in an audit which principals can decrypt the credential. A CMK can.
  EOT
  type        = bool
  default     = true
}

variable "kms_key_arn" {
  description = "Existing CMK to use. Ignored when create_kms_key = true."
  type        = string
  default     = ""
}

variable "replica_regions" {
  description = <<-EOT
    Regions to replicate the secret into. Only the hub reads this secret, so
    replication is about surviving a regional event rather than about cluster
    locality. Leave empty unless you have a DR hub elsewhere.
  EOT
  type        = list(string)
  default     = []
}

variable "recovery_window_days" {
  description = "Secrets Manager recovery window. 0 forces immediate deletion -- avoid outside sandboxes."
  type        = number
  default     = 30
}

variable "name_prefix" {
  description = "Prefix for IAM role, policy and KMS alias names."
  type        = string
  default     = "falcon-eso"
}

variable "acm_policy_namespace" {
  description = <<-EOT
    Hub namespace holding the ACM policies, and therefore where the
    ExternalSecret must create the Secret -- ACM resolves hub templates only
    against objects in the Policy's own namespace. Must match
    acm/base/namespace.yaml.
  EOT
  type        = string
  default     = "falcon-governance"
}

variable "tags" {
  description = "Tags applied to every AWS resource. Unrelated to Falcon sensor grouping tags."
  type        = map(string)
  default = {
    ManagedBy = "terraform"
    Component = "crowdstrike-falcon"
  }
}

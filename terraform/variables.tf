variable "aws_region" {
  description = "Region holding the Falcon API credentials secret. Must match the region your existing ClusterSecretStore points at."
  type        = string
  default     = "eu-west-1"
}

variable "secret_name" {
  description = <<-EOT
    Name of the AWS Secrets Manager secret. Must match remoteRef.key in
    acm/02-credentials/external-secrets.yaml -- scripts/validate.sh checks
    that the two agree.

    If your existing ESO role is scoped to a path prefix, name this secret
    inside that prefix.
  EOT
  type        = string
  default     = "crowdstrike/falcon/api-credentials"
}

variable "eso_role_arns" {
  description = <<-EOT
    ARNs of the IAM role(s) your existing External Secrets Operator assumes.
    Terraform grants these read access to the new secret through the
    secret's resource policy and the KMS key policy.

    Nothing about your ESO installation is modified -- no role is created,
    no policy is attached, no trust relationship is touched. Within a single
    account a resource policy alone is sufficient to authorise access, so
    this is the least intrusive way to let an externally-managed role read
    a secret this stack owns.

    Find it with:
      oc get clustersecretstore aws-secrets-manager -o jsonpath='{.spec.provider.aws.role}'

    If that is empty, ESO is using the controller ServiceAccount's own
    identity; get the role from the SA annotation instead:
      oc get sa -n <eso-namespace> <eso-sa> \
        -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}'

    Leave empty ONLY if that role already has GetSecretValue on a prefix
    covering var.secret_name.
  EOT
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for a in var.eso_role_arns : startswith(a, "arn:")])
    error_message = "Each entry must be a full IAM role ARN, e.g. arn:aws:iam::123456789012:role/external-secrets."
  }
}

variable "create_kms_key" {
  description = <<-EOT
    Create a customer-managed KMS key for the secret. The AWS-managed
    aws/secretsmanager key cannot carry a key policy, so with it you cannot
    prove in an audit which principals can decrypt the credential. A CMK can.

    If you enable this, eso_role_arns must be populated -- a CMK requires an
    explicit key policy grant, and unlike Secrets Manager there is no
    "either side may allow" shortcut for KMS.
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
  description = "Regions to replicate the secret into. Only the hub reads it, so this is about surviving a regional event, not cluster locality."
  type        = list(string)
  default     = []
}

variable "recovery_window_days" {
  description = "Secrets Manager recovery window. 0 forces immediate deletion -- avoid outside sandboxes."
  type        = number
  default     = 30
}

variable "name_prefix" {
  description = "Prefix for the KMS alias."
  type        = string
  default     = "falcon"
}

variable "tags" {
  description = "Tags applied to every AWS resource. Unrelated to Falcon sensor grouping tags."
  type        = map(string)
  default = {
    ManagedBy = "terraform"
    Component = "crowdstrike-falcon"
  }
}

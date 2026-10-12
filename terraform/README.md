# Terraform — AWS Secrets Manager secret for the Falcon API credentials

Creates the secret and its KMS key, and grants your **existing** External
Secrets Operator role read access. That is all.

It deliberately does **not**:

- create an IAM role for ESO — you already have one
- create a ClusterSecretStore — `aws-secrets-manager` already exists
- touch, attach to, or modify that role — access is granted through the
  secret's own resource policy, so another team's automation keeps sole
  ownership of the role
- ever hold the Falcon credential — see below

## The credential never passes through Terraform

Terraform writes a placeholder once:

```json
{ "client_id": "REPLACE_IN_CONSOLE", "client_secret": "REPLACE_IN_CONSOLE" }
```

and then ignores the value forever (`lifecycle.ignore_changes`). You type the
real client ID and secret into the Secrets Manager console by hand.

So no Falcon credential appears in Terraform state, a plan output, a tfvars
file, GitHub Actions logs, or this repository. That is what makes a public
repo safe here, and it is why a later `terraform apply` cannot clobber the
live value.

## Finding your state bucket

State must persist between workflow runs. Without it, every run starts empty
and tries to recreate a secret that already exists.

To find out whether your org already has a convention:

```bash
# Buckets that look like Terraform state
aws s3 ls | grep -iE 'tfstate|terraform|tf-state'

# What other repos in your org do
grep -rn 'backend "s3"' -A 5 ../other-repos/
```

Also worth checking an existing repo's `.github/workflows/*.yml` for a
`-backend-config` line, and asking whoever owns your AWS account — most
platform teams have one bucket per account with a key prefix per project.

If there is no convention, create one bucket (once, by hand — bootstrapping
state storage with Terraform is its own chicken-and-egg):

```bash
BUCKET=my-org-tfstate-$(aws sts get-caller-identity --query Account --output text)
aws s3api create-bucket --bucket "$BUCKET" --region eu-west-1 \
  --create-bucket-configuration LocationConstraint=eu-west-1
aws s3api put-bucket-versioning --bucket "$BUCKET" \
  --versioning-configuration Status=Enabled
aws s3api put-public-access-block --bucket "$BUCKET" \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
echo "$BUCKET"
```

Versioning matters — it is your only recovery path if state is corrupted.
No DynamoDB table is needed: the backend uses `use_lockfile = true`
(Terraform 1.10+) for S3-native locking.

## GitHub Actions OIDC role

The workflow authenticates with OIDC, so there are no AWS keys in GitHub.
You need an IAM role trusting GitHub's OIDC provider, restricted to this
repository.

If `token.actions.githubusercontent.com` is not yet an IAM identity provider
in the account, add it once. Then a trust policy of the shape:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::<ACCOUNT>:oidc-provider/token.actions.githubusercontent.com"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
      },
      "StringLike": {
        "token.actions.githubusercontent.com:sub": "repo:ravishar-rh/crowdstrike-falcon:*"
      }
    }
  }]
}
```

The `sub` condition is the important line. Without it any repository on
GitHub could assume the role. Tighten it further to a single branch with
`repo:ravishar-rh/crowdstrike-falcon:ref:refs/heads/main` if you do not need
plans on pull requests.

The role needs `secretsmanager:*` and `kms:*` scoped to what this stack
creates, plus read/write on the state bucket.

## Variables

Only `eso_role_arns` has no usable default. Everything else is set.

See `terraform.tfvars.example` for local runs; in CI the values come from
repository variables (`docs/runbook.md`, phase 2b).

## If `create_kms_key = true`

`eso_role_arns` becomes mandatory, and Terraform fails at plan time if it is
empty. A customer-managed key requires an explicit key policy grant — unlike
Secrets Manager, KMS has no "either the identity policy or the resource
policy may allow" evaluation. A CMK nobody can decrypt is a secret nobody
can read, and that is worth catching before apply rather than discovering it
as an ESO `SecretSyncedError`.

Set `create_kms_key = false` to use the AWS-managed `aws/secretsmanager`
key, at the cost of being unable to demonstrate in an audit which principals
can decrypt the credential.

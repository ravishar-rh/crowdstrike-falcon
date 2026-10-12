terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.40"
    }
  }

  # Partial backend config -- deliberately empty.
  #
  # Bucket, key and region are supplied at init time by the GitHub Actions
  # workflow from repository variables, so no bucket name is committed to a
  # public repo:
  #
  #   terraform init \
  #     -backend-config="bucket=$TF_STATE_BUCKET" \
  #     -backend-config="key=crowdstrike-falcon/terraform.tfstate" \
  #     -backend-config="region=$TF_STATE_REGION"
  #
  # State must persist between runs. Without a backend, every workflow run
  # starts empty and tries to recreate the secret, which fails because the
  # name already exists.
  #
  # Working locally: run the same init with your own -backend-config, or
  # comment this block out to use local state.
  backend "s3" {
    # use_lockfile replaces the old DynamoDB lock table (Terraform 1.10+).
    # Drop this line if you are on an older Terraform and add
    # -backend-config="dynamodb_table=..." instead.
    use_lockfile = true
    encrypt      = true
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = var.tags
  }
}

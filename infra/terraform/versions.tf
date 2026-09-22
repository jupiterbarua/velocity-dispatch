terraform {
  required_version = ">= 1.7"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.50"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  # A remote backend isn't optional here despite this being a portfolio
  # project — this repo's whole CI/CD design (bootstrap the OIDC role once
  # with a human's local credentials, then let GitHub Actions run every
  # `terraform apply` after that) only works if the human's local apply and
  # every CI apply are reading/writing the *same* state. With local-only
  # state, CI's terraform starts blank every run and tries to recreate
  # everything the local bootstrap already created — confirmed for real:
  # the first CI-driven full apply tried (and failed) to create the OIDC
  # provider, ECR repos, and VPC from scratch, all of which already existed
  # from the local bootstrap apply.
  #
  # Backend block values can't use variables (`var.*`), so `key` is
  # hardcoded to "dev" rather than driven by `var.environment` — fine for
  # this single-environment portfolio deploy; a multi-environment setup
  # would need a separate key per environment (or per-environment
  # workspaces) instead of this fixed path.
  backend "s3" {
    bucket         = "velocity-dispatch-tfstate-645314607648"
    key            = "dev/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "velocity-dispatch-tflock"
    encrypt        = true
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = "velocity-dispatch"
      ManagedBy = "terraform"
    }
  }
}

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

  # Portfolio project: state is local by default so it's runnable with zero
  # setup. In a real team this backend block would point at an S3 bucket +
  # DynamoDB lock table instead — swap it for:
  #
  # backend "s3" {
  #   bucket         = "velocity-dispatch-tfstate"
  #   key            = "prod/terraform.tfstate"
  #   region         = "eu-central-1"
  #   dynamodb_table = "velocity-dispatch-tflock"
  #   encrypt        = true
  # }
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

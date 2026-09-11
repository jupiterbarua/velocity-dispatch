# Deliberately a SEPARATE root module (its own state) from
# infra/terraform/ — that Terraform provisions the "real" AWS deployment
# (ECS/RDS/SQS/EventBridge/Lambda); this one exists purely to solve "run
# the Kubernetes manifests in k8s/ somewhere with more CPU/RAM than a 2015
# MacBook Air, cheaply, a few hours at a time." Keeping them separate means
# `terraform apply`/`destroy` here can never touch the other's resources or
# state — genuinely different concerns, not just organized into folders.
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
    local = {
      source  = "hashicorp/local"
      version = "~> 2.4"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = "velocity-dispatch"
      ManagedBy = "terraform"
      Purpose   = "k3s-ec2-testing"
    }
  }
}

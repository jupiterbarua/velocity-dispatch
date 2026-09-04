variable "aws_region" {
  description = "AWS region to deploy into. eu-central-1 (Frankfurt) by default — lowest latency to German users/customers, and the region most German employers' own workloads run in."
  type        = string
  default     = "eu-central-1"
}

variable "environment" {
  description = "Deployment environment name, used in resource naming."
  type        = string
  default     = "dev"
}

variable "container_image_tag" {
  description = "Image tag (git SHA) to deploy for dispatch-api / dispatch-worker / dispatch-notify-lambda. Set by CI, see .github/workflows/ci.yml."
  type        = string
  default     = "latest"
}

variable "api_task_cpu" {
  type    = number
  default = 256 # 0.25 vCPU — plenty for a demo; the README's load-test section shows how to right-size this from real numbers instead of guessing.
}

variable "api_task_memory" {
  type    = number
  default = 512
}

variable "worker_task_cpu" {
  type    = number
  default = 256
}

variable "worker_task_memory" {
  type    = number
  default = 512
}

variable "api_desired_count" {
  description = "Number of dispatch-api Fargate tasks to run. 2 by default for basic HA across AZs even in a demo deploy."
  type        = number
  default     = 2
}

variable "worker_desired_count" {
  type    = number
  default = 1
}

variable "db_username" {
  type      = string
  default   = "dispatch"
  sensitive = true
}

variable "db_password" {
  description = "RDS master password. Pass via TF_VAR_db_password or a CI secret — deliberately has no default."
  type        = string
  sensitive   = true
}

variable "github_repository" {
  description = "GitHub \"org/repo\" (e.g. \"jupiterbarua/velocity-dispatch\") allowed to assume the CI deploy role via OIDC. Deliberately has no default so a stale/placeholder value can't accidentally get applied — see infra/terraform/github-oidc.tf."
  type        = string
}

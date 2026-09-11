variable "aws_region" {
  description = "us-east-1 (N. Virginia) — this module targets it by default because the new (July 2025+) AWS Free Tier's m7i-flex.large/c7i-flex.large hours are only worth using in a region you're comfortable defaulting to for everything else too. Differs from infra/terraform's eu-central-1 default on purpose; the two modules have separate state and never interact."
  type        = string
  default     = "us-east-1"
}

variable "name_prefix" {
  type    = string
  default = "velocity-dispatch-k3s"
}

variable "vpc_cidr" {
  description = "CIDR for this module's own VPC (see vpc.tf). /16 is overkill for one instance, but costs nothing and leaves room if this ever grows a second subnet."
  type        = string
  default     = "10.20.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR for the single public subnet the k3s instance lives in. Must fall inside vpc_cidr."
  type        = string
  default     = "10.20.1.0/24"
}

# Deliberately no default — same reasoning as infra/terraform's
# db_password/github_repository variables: a stale/placeholder CIDR here
# would mean anyone on the internet can reach the k3s API port or SSH,
# not just you. up.sh auto-detects your current public IP and exports
# TF_VAR_my_ip_cidr for you, so you don't normally set this by hand — but
# there's no default that would apply if you forgot to.
variable "my_ip_cidr" {
  description = "Your current public IP in CIDR form (e.g. \"203.0.113.7/32\") — SSH (22) and dispatch-api's NodePort (30080) are only opened to this. Home/mobile IPs change; re-run up.sh each session rather than hardcoding this once."
  type        = string
}

variable "instance_type" {
  description = "m7i-flex.large (2 vCPU / 8GB) — free-tier eligible on AWS accounts created on/after July 15 2025 (up to 750 hrs/month combined across eligible types, on-demand only — see use_spot below). More headroom than the old t3.medium default, and free instead of ~$0.05/day, as long as it stays on-demand."
  type        = string
  default     = "m7i-flex.large"
}

variable "use_spot" {
  description = "Free Tier hours only apply to on-demand usage — a Spot request is a different purchasing option and is billed separately even for an otherwise-eligible instance type. Defaults to false so the free hours actually apply; flip to true (e.g. TF_VAR_use_spot=true ./up.sh) if you'd rather pay Spot pricing on a non-free-tier instance type, or once your free-tier window has run out."
  type        = bool
  default     = false
}

variable "root_volume_size_gb" {
  description = "gp3 root volume size. 20GB covers the Ubuntu base image + k3s + containerd's pulled images (Postgres, LocalStack, dispatch-api/worker, busybox) with room to spare."
  type        = number
  default     = 20
}

variable "spot_max_price" {
  description = "Max hourly price (USD) you're willing to pay for the Spot instance, as a string (e.g. \"0.02\"). Left null so AWS caps it at the on-demand price automatically — the simplest safe default; tighten it only if you want a hard ceiling below on-demand."
  type        = string
  default     = null
}

variable "repo_url" {
  description = "Public GitHub URL to clone on boot. The instance runs `kubectl apply -k k8s/base/` from a fresh clone of this — change it if you're testing from a fork."
  type        = string
  default     = "https://github.com/jupiterbarua/velocity-dispatch.git"
}

variable "repo_ref" {
  description = "Branch or tag to clone. Point this at a feature branch to test changes on real AWS hardware before merging to main."
  type        = string
  default     = "main"
}

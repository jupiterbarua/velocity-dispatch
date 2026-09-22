# Lets GitHub Actions assume an AWS role via OIDC federation, with NO
# long-lived AWS access keys stored as GitHub secrets. This is what
# .github/workflows/deploy.yml's `role-to-assume:
# arn:aws:iam::<account>:role/velocity-dispatch-ci-deploy` actually resolves
# to — without this file, that workflow step has nothing to assume.
#
# Bootstrapping note: this is the one part of the stack with a real
# chicken-and-egg problem. Terraform needs *some* AWS credentials to create
# this role in the first place, and those first credentials can't come from
# the role this file creates. In practice: an administrator applies this
# file once with their own (human) AWS credentials — see
# docs/DEPLOYMENT_GUIDE.md step 1 — after which every subsequent deploy runs
# through GitHub Actions/OIDC and no human credential is needed again.

data "tls_certificate" "github_actions" {
  url = "https://token.actions.githubusercontent.com/.well-known/openid-configuration"
}

resource "aws_iam_openid_connect_provider" "github_actions" {
  url = "https://token.actions.githubusercontent.com"

  client_id_list = ["sts.amazonaws.com"]

  # Computed from the live certificate rather than hardcoded, so a future
  # GitHub cert rotation doesn't silently break trust — `terraform plan`
  # will show the new thumbprint instead of deploys failing with an opaque
  # "not authorized to perform sts:AssumeRoleWithWebIdentity" error.
  thumbprint_list = [data.tls_certificate.github_actions.certificates[0].sha1_fingerprint]
}

data "aws_iam_policy_document" "github_actions_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github_actions.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Scoped to this one repository, on any branch/tag/environment (":*").
    # Tightening this to e.g. "repo:org/velocity-dispatch:ref:refs/heads/main"
    # would additionally restrict *which branch* can deploy — worth doing
    # once this repo has a real branch-protection story, deliberately left
    # broader here so PR-based `workflow_dispatch` runs (see deploy.yml,
    # which is manually triggered, not automatic) aren't accidentally locked out.
    #
    # Two patterns, not one, because of GitHub's "immutable subject claims"
    # feature (shipped July 2026): any repo created on or after 2026-07-15 —
    # this one was created 2026-09-04 — automatically gets its numeric
    # owner/repo IDs spliced into the `sub` claim:
    # "repo:<owner>@<owner_id>/<repo>@<repo_id>:ref:...", instead of the
    # plain "repo:<owner>/<repo>:ref:..." the first pattern below expects.
    # Those IDs never change even across a rename/transfer (that's the whole
    # point of the feature), so they're hardcoded here rather than templated
    # from var.github_repository — confirmed via
    # `gh api repos/jupiterbarua/velocity-dispatch --jq '{owner_id:.owner.id,repo_id:.id}'`.
    # The first pattern is kept too, purely so this module still works if
    # ever reused against a pre-2026-07-15 repo that hasn't opted in.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:${var.github_repository}:*",
        "repo:jupiterbarua@28349947/velocity-dispatch@1357590345:*",
      ]
    }
  }
}

resource "aws_iam_role" "github_actions_deploy" {
  name               = "velocity-dispatch-ci-deploy"
  assume_role_policy = data.aws_iam_policy_document.github_actions_assume.json

  # Deploys are infrequent and manually triggered (workflow_dispatch); one
  # hour is more than enough for a `terraform apply` to finish inside a
  # single assumed-role session.
  max_session_duration = 3600
}

# --- Permissions the CI role needs -----------------------------------------
#
# Two things run under this role: (1) `docker push` to ECR, and (2)
# `terraform apply`, which itself needs to manage every resource type this
# repo's Terraform declares (SQS, EventBridge, ECS, RDS, S3, SNS, Lambda,
# IAM, ECR, CloudWatch). A hand-written least-privilege policy covering
# every action Terraform might call across all of those services would be
# hundreds of lines and still drift out of sync every time a new resource
# type is added — so this uses AWS managed policies scoped to *services*,
# which is the pragmatic middle ground for a project this size. The
# honest trade-off: a real production setup would
# either run `terraform plan` in CI and gate `apply` through a separate,
# more tightly-scoped execution role (e.g. via Terraform Cloud/Atlantis),
# or scope this down with resource-level conditions once the resource set
# stabilizes.

resource "aws_iam_role_policy_attachment" "deploy_ecr" {
  role       = aws_iam_role.github_actions_deploy.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser"
}

resource "aws_iam_role_policy_attachment" "deploy_ecs" {
  role       = aws_iam_role.github_actions_deploy.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonECS_FullAccess"
}

data "aws_iam_policy_document" "deploy_terraform_managed_resources" {
  statement {
    sid    = "TerraformManagedInfra"
    effect = "Allow"
    actions = [
      "sqs:*",
      "events:*",
      "rds:*",
      "s3:*",
      "sns:*",
      "lambda:*",
      "elasticloadbalancing:*",
      # Widened from "ec2:Describe*" + "ec2:*SecurityGroup*" to the full
      # service when network.tf moved off the account's default VPC to a
      # custom one — that change added aws_vpc/aws_subnet/
      # aws_internet_gateway/aws_route_table/aws_eip/aws_nat_gateway, none
      # of which the narrower permission set ever covered. First real
      # full `terraform apply` through this role failed on exactly this gap
      # (UnauthorizedOperation on ec2:CreateVpc / ec2:AllocateAddress).
      "ec2:*",
      # AmazonEC2ContainerRegistryPowerUser (attached below) covers image
      # push/pull, but not repository lifecycle management — the first real
      # apply failed with AccessDeniedException on ecr:CreateRepository
      # because that action isn't in PowerUser at all.
      "ecr:*",
      # For the S3+DynamoDB state backend added in versions.tf — CI needs to
      # read/write the state object in S3 (already covered by "s3:*" above)
      # and take/release the DynamoDB lock during every apply.
      "dynamodb:*",
      "logs:*",
      "cloudwatch:*",
      "iam:GetRole",
      "iam:PassRole",
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:GetRolePolicy",
      "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies",
      "iam:TagRole",
      # This file's own aws_iam_openid_connect_provider.github_actions is
      # part of the same Terraform state as everything else here, so every
      # `terraform apply` (not just the one-time human bootstrap) evaluates
      # it for drift — e.g. a GitHub cert rotation changing the thumbprint
      # via the live data.tls_certificate source. Needs at least read
      # access for that; full lifecycle included in case of an actual
      # thumbprint update. First real apply failed on
      # iam:CreateOpenIDConnectProvider with no identity-based policy
      # allowing it.
      "iam:CreateOpenIDConnectProvider",
      "iam:GetOpenIDConnectProvider",
      "iam:DeleteOpenIDConnectProvider",
      "iam:UpdateOpenIDConnectProviderThumbprint",
      "iam:TagOpenIDConnectProvider",
      "iam:ListOpenIDConnectProviders",
    ]
    resources = ["*"]
  }

  # AWS auto-creates an account-wide service-linked role the first time a
  # given service is used in an account — the ALB's aws_lb.api resource
  # needs AWSServiceRoleForElasticLoadBalancing, and RDS needs its own
  # equivalent, neither of which existed in this account yet. The first
  # real full apply failed on both with AccessDenied on
  # iam:CreateServiceLinkedRole. Scoped by AWSServiceName rather than
  # granted unconditionally, since this action is unusually powerful
  # (it creates a role with a fixed AWS-managed policy outside this file's
  # normal least-privilege review) and only two services actually need it.
  statement {
    sid    = "AllowServiceLinkedRoleCreation"
    effect = "Allow"
    actions = [
      "iam:CreateServiceLinkedRole",
    ]
    resources = ["arn:aws:iam::*:role/aws-service-role/*"]

    condition {
      test     = "StringEquals"
      variable = "iam:AWSServiceName"
      values = [
        "elasticloadbalancing.amazonaws.com",
        "rds.amazonaws.com",
      ]
    }
  }
}

resource "aws_iam_role_policy" "deploy_terraform_managed_resources" {
  name   = "velocity-dispatch-terraform-apply"
  role   = aws_iam_role.github_actions_deploy.id
  policy = data.aws_iam_policy_document.deploy_terraform_managed_resources.json
}

output "github_actions_role_arn" {
  description = "Put this in the AWS_ACCOUNT_ID-derived role-to-assume in deploy.yml (already templated there) — surfaced here so it's copy-pasteable after the first apply."
  value       = aws_iam_role.github_actions_deploy.arn
}

# Deployment Guide — AWS CI/CD to ECS Fargate

This is the step-by-step runbook for taking Velocity Dispatch from "code on GitHub" to "running on real AWS," and for how every subsequent deploy flows through CI without touching AWS credentials by hand again. It assumes you've already run the system locally via `docker compose up` (see the README) — deploying something you've never run is a bad first move regardless of how good the Terraform looks.

## 0. What you're about to provision (and what it costs)

Running `terraform apply` against `infra/terraform/` creates real, billed AWS resources: an RDS `db.t4g.micro` Postgres instance, two ECS Fargate services, an Application Load Balancer, an SQS queue pair, an EventBridge bus, a Lambda function, an S3 bucket, an SNS topic, and a set of CloudWatch alarms. Rough order of magnitude for a `dev`-sized deployment left running continuously: **$40-70/month**, dominated by the ALB (~$16-20/mo flat) and RDS (~$12-15/mo for `db.t4g.micro`) — Fargate and Lambda are usage-based and near-zero at demo traffic levels. **Section 7 covers tearing it all down** — do that between interview prep sessions rather than leaving it running, unless you specifically want a live demo URL to hand an interviewer.

## 1. One-time bootstrap: the OIDC trust relationship

This is the only step that uses a human's AWS credentials directly — every deploy after this one runs through GitHub Actions with no static AWS key stored anywhere.

1. Create an AWS account (or use an existing one) and, locally, configure the AWS CLI with an IAM user or SSO profile that has broad admin rights for this one-time bootstrap (`aws configure` or `aws sso login`).
2. Find your GitHub repo's `org/repo` string (e.g. `jupiterbarua/velocity-dispatch`).
3. In `infra/terraform/`, run:
   ```bash
   terraform init
   terraform apply \
     -target=aws_iam_openid_connect_provider.github_actions \
     -target=aws_iam_role.github_actions_deploy \
     -target=aws_iam_role_policy_attachment.deploy_ecr \
     -target=aws_iam_role_policy_attachment.deploy_ecs \
     -target=aws_iam_role_policy.deploy_terraform_managed_resources \
     -var="github_repository=<org>/<repo>" \
     -var="db_password=placeholder"
   ```
   (The `-target` flags apply only the OIDC/IAM pieces first — deliberately, since everything else in this Terraform config should be created *by* CI, not by a human's laptop, once the trust relationship exists.)
4. Note the `github_actions_role_arn` output — that's the ARN `deploy.yml` will assume.
5. In your GitHub repo settings → Secrets and variables → Actions, add:
   - `AWS_ACCOUNT_ID` — your 12-digit AWS account ID (the workflow builds the role ARN from this + the fixed role name `velocity-dispatch-ci-deploy`).
   - `DB_PASSWORD` — a strong password for the RDS instance (e.g. `openssl rand -base64 24`); this is passed to Terraform as `TF_VAR_db_password` and never appears in logs.

From this point on, no human ever runs `terraform apply` with personal credentials again — GitHub Actions does it, authenticated via the OIDC role, scoped to this one repository (see the `sub` condition in `infra/terraform/github-oidc.tf`).

## 2. How the pipeline actually flows

`.github/workflows/ci.yml` runs on every push/PR to `main` — `cargo fmt`, `cargo clippy -D warnings`, `cargo test --workspace` against a real Postgres service container, a Docker build of all three images (build-only, not pushed), and `terraform fmt`/`validate`. This is the fast, always-on feedback loop; it never touches AWS.

`.github/workflows/deploy.yml` is manually triggered (`workflow_dispatch`, with an `environment` input of `dev`/`staging`/`prod`) and does the parts that touch real infrastructure:

1. **`build-and-push`** — for each of the three services, builds its Docker image (using the same `cargo-chef` multi-stage Dockerfile CI already validated) and pushes it to that service's ECR repository, tagged with the first 12 characters of the git SHA. This is what makes deploys traceable: `docker inspect` on any running task tells you exactly which commit is live.
2. **`terraform-apply`** — waits on the images being pushed, assumes the OIDC role, and runs `terraform apply` with `TF_VAR_container_image_tag` set to that same git SHA. ECS picks up the new task definition revision and performs a rolling deployment (`deployment_minimum_healthy_percent = 100`, `deployment_maximum_percent = 200` in `ecs.tf` — new tasks come up and pass the ALB health check before old ones are drained, so there's no window with reduced capacity).

For `prod`, the `terraform-apply` job runs under a GitHub **environment** (`environment: ${{ inputs.environment }}`) — configure a required-reviewer rule on that environment in GitHub's repo settings if you want a manual approval gate before anything reaches production. That's a two-click setting in GitHub, not something Terraform manages.

## 3. Running your first deploy

Once step 1's secrets are in place:

```bash
gh workflow run deploy.yml -f environment=dev
# or: GitHub → Actions → Deploy → Run workflow → environment: dev
```

Watch it in the Actions tab. The `terraform-apply` job's output includes the `api_url` output (the ALB's public DNS name) — that's your live endpoint.

## 4. Verifying the deployment

```bash
export API_URL=$(terraform -chdir=infra/terraform output -raw api_url)

curl "$API_URL/health"
# {"status":"ok"}

curl -X POST "$API_URL/orders" \
  -H 'Content-Type: application/json' \
  -d '{"pickup":{"lat":52.52,"lon":13.405},"dropoff":{"lat":52.50,"lon":13.38}}'
```

Then check, in the AWS Console or CLI: CloudWatch Logs group `/ecs/velocity-dispatch-worker-dev` for the matching attempt, the EventBridge rule's metrics for a triggered invocation, and the Lambda's CloudWatch Logs group for the notification/audit write. If you registered no drivers yet, the order will sit `pending` and (per FR-7/UC-2) eventually land in the DLQ — that's expected, not a bug; register a few drivers first via `POST /drivers` or adapt `scripts/seed.sh` to point at `$API_URL`.

## 5. Running the load test against the real deployment

```bash
k6 run -e BASE_URL=$API_URL loadtest/orders.js
```

Fill the resulting p50/p95/p99/error-rate numbers into the README's latency table — those are the numbers worth having memorized before a systems-design interview, since "should be fast" and "p99 was 187ms under 200 concurrent users" land very differently.

## 6. What happens when something goes wrong

- **`terraform apply` fails on an IAM permission** — the CI role's policy (`infra/terraform/github-oidc.tf`) covers the resource types this repo currently declares; if you've added a new resource type, you'll need to extend `deploy_terraform_managed_resources`.
- **ECS tasks fail to start / crash-loop** — check `aws ecs describe-services` for the stopped-task reason, then the CloudWatch Logs group for that service; the most common cause during first setup is `DATABASE_URL` pointing at an RDS instance the ECS security group can't reach (double-check `aws_security_group.rds`'s ingress rule in `network.tf` matches `aws_security_group.ecs_service`).
- **The `queue-backlog` or `dlq-not-empty` CloudWatch alarm fires** (see `infra/terraform/monitoring.tf`) — subscribe an email address to the `ops_alerts_topic_arn` output so you actually see it: `aws sns subscribe --topic-arn <arn> --protocol email --notification-endpoint you@example.com`.

## 7. Tearing it down

```bash
terraform -chdir=infra/terraform destroy -var="github_repository=<org>/<repo>" -var="db_password=<same value used to create it>"
```

Note: `aws_ecr_repository` resources will refuse to delete if they still contain images — either delete the images first (`aws ecr batch-delete-image` or just delete the repos with `force_delete` — not currently set, deliberately, so `terraform destroy` doesn't silently nuke your image history) or add `force_delete = true` to `ecr.tf` temporarily.

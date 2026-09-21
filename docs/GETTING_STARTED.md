# Getting Started — Velocity Dispatch

How to run, deploy, and measure Velocity Dispatch. For what the system is and how it's designed, see the [README](../README.md).

## Running it locally

The Rust + AWS SDK dependency graph is heavy to compile — building from source wants a reasonably capable machine. If yours isn't (an old laptop, limited RAM), skip building entirely and pull the images CI already built and tested:

```bash
cp .env.example .env   # optional — the defaults already point at the compose services
docker compose pull dispatch-api dispatch-worker
docker compose up
```

If you'd rather build from source (e.g. you're actively changing the Rust code):

```bash
cp .env.example .env
docker compose up --build

# in another terminal, once everything's healthy:
./scripts/seed.sh 25
curl -X POST localhost:8080/orders \
  -H 'Content-Type: application/json' \
  -d '{"pickup":{"lat":52.52,"lon":13.405},"dropoff":{"lat":52.50,"lon":13.38}}'

# watch dispatch-worker's logs — it should pick up the order, match a driver,
# and publish DispatchAssigned within a couple of seconds.

# or run the scripted Week 1 acceptance check instead of doing the above by hand:
./scripts/week1_smoke_test.sh
```

For the Lambda specifically (not run as a long-lived container — see the note in `docker-compose.yml`), use [`cargo-lambda`](https://www.cargo-lambda.info/) for local invoke/watch instead: `cargo lambda watch -p dispatch-notify-lambda`.

## Running it on Kubernetes

The same published images also run on a local Kubernetes cluster (k3d, or minikube) instead of Docker Compose — Namespace/ConfigMap/Secret, a StatefulSet for Postgres, init containers for startup ordering, health-checked probes, resource requests sized for a constrained machine, and an HPA wired to metrics-server:

```bash
k3d cluster create velocity-dispatch --agents 0 --port "8080:30080@loadbalancer"
kubectl apply -k k8s/base/
curl http://localhost:8080/health
```

Full walkthrough, including load-testing the HPA and what's deliberately left out (Ingress, NetworkPolicy, KEDA): [`k8s/README.md`](../k8s/README.md).

## A note on building this repo

Every query in `dispatch-api`/`dispatch-worker` uses SQLx's **runtime-checked** query API (`sqlx::query`/`query_as`), not the `query!` compile-time macro — a deliberate choice so `cargo check`/`cargo build` never require a live `DATABASE_URL` or a committed `.sqlx` offline cache just to compile. The trade-off is losing compile-time SQL validation; `cargo test --workspace` against the Postgres service in CI (see `.github/workflows/ci.yml`) is what actually exercises the queries.

Before pushing, run the same three commands CI runs:

```bash
cargo fmt --all
cargo clippy --workspace --all-targets
cargo test --workspace
```

## Deploying to real AWS

Short version:

```bash
cd infra/terraform
terraform init
terraform apply -var="github_repository=<org>/<repo>" -var="db_password=$(openssl rand -base64 24)"
```

This provisions: SQS queue + DLQ with a redrive policy, an EventBridge custom bus + rule, three ECR repos, IAM roles (execution role split from task role, least privilege per service — plus a dedicated GitHub OIDC deploy role, see `infra/terraform/github-oidc.tf`), an ECS Fargate cluster running `dispatch-api` (behind an ALB) and `dispatch-worker`, an RDS Postgres instance, an S3 bucket for audit records, an SNS topic for notifications, CloudWatch alarms on SQS backlog/DLQ/ECS task count/ALB 5xx rate (`infra/terraform/monitoring.tf`), and the `dispatch-notify-lambda` function wired to the EventBridge rule.

**Full version, including the one-time OIDC bootstrap and how the CI/CD pipeline flows end to end: [`DEPLOYMENT_GUIDE.md`](DEPLOYMENT_GUIDE.md).** In practice you don't run `terraform apply` from a laptop for anything but that one bootstrap step — every deploy after that goes through `.github/workflows/deploy.yml`, authenticated via OIDC, with the image tag set to the git SHA that was actually built and tested.

## Measuring latency

```bash
k6 run -e BASE_URL=http://localhost:8080 loadtest/orders.js
```

The script ramps to 200 concurrent virtual users against `POST /orders` and asserts `p(95) < 150ms` / `p(99) < 400ms` / error rate `< 1%` as CI-style thresholds — k6 exits non-zero if they're not met. Record your own numbers here:

| Metric | Result |
|---|---|
| p50 | _fill in after running against your deployment_ |
| p95 | |
| p99 | |
| Error rate | |
| Throughput (req/s) | |

Real measurements are the difference between a claim and evidence — fill this table in from your own run, not from this template.

To right-size things from real numbers rather than guessing, watch these while the load test runs: SQS queue depth and age of oldest message (is the worker keeping up?), ECS CPU/memory for `dispatch-api` and `dispatch-worker`, and RDS connection count and CPU (is `db_max_connections` sized correctly for the offered concurrency?).

## Production considerations

What would change for a real production deployment:

- **Networking:** the Terraform uses a dedicated VPC with private subnets for ECS/RDS and only the ALB public, with a single NAT Gateway for outbound access. Production would want one NAT Gateway per AZ.
- **Database:** single-AZ `db.t4g.micro`, 1-day backup retention; production wants Multi-AZ, longer retention, and read replicas once read traffic (e.g. `GET /orders/{id}` at scale) justifies them.
- **Geospatial matching:** in-process haversine scan over region-filtered candidates; at real fleet scale this becomes a PostGIS `ST_DWithin` query with a GiST index, or a dedicated spatial index service.
- **Autoscaling:** `desired_count` is fixed in Terraform; production wants ECS Service Auto Scaling on CPU/ALB request count, and SQS-queue-depth-based scaling for the worker.
- **Secrets:** `db_password` flows through a Terraform variable/CI secret today; production wants AWS Secrets Manager with rotation, referenced by ARN in the task definition.
- **Observability:** structured JSON logs to CloudWatch today; production wants distributed tracing (OpenTelemetry) across the SQS → worker → EventBridge → Lambda hop, so a slow assignment is traceable end-to-end.

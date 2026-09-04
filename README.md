# Velocity Dispatch

A real-time delivery/logistics dispatch platform built in Rust to be event-driven, horizontally scalable, and defensible in a systems-design interview — not a CRUD demo with AWS icons bolted on.

**Order comes in → gets matched to the nearest available driver → downstream systems (notifications, audit trail) react — all decoupled across services that scale independently.**

```
                 POST /orders                         SQS: order-created
   client ───────────────────────▶  dispatch-api  ───────────────────────▶  dispatch-worker
                                    (Actix + Tokio)                         (Tokio consumer)
                                         │                                        │
                                    PostgreSQL                              nearest_driver()
                                    (orders, drivers,                       matching, tx-safe
                                     assignments)                                 │
                                                                     EventBridge: DispatchAssigned
                                                                                   │
                                                          ┌────────────────────────┴───────────────┐
                                                          ▼                                         ▼
                                              dispatch-notify-lambda                    (future: billing, analytics —
                                              (Rust, provided.al2023)                    new EventBridge rule, zero
                                              → SNS notification                         changes to the worker)
                                              → S3 audit record
```

## Why this project, specifically

My CV already points at "high-availability routing and logistics APIs" as an interest, and logistics/dispatch tech is one of the deepest hiring pools in Germany right now — DHL, Kuehne+Nagel, Deutsche Bahn, Flink/Gorillas-style quick-commerce, and most fintechs building payment/settlement pipelines all need exactly this shape of system: an API that must stay fast under load, an async worker doing the expensive matching work off the request path, and an event bus decoupling everything downstream. This repo is built to be the concrete, defensible answer to "walk me through a system you built" in that kind of interview — every design decision below has a one-sentence reason attached, because that's what actually gets asked.

## The five things worth walking an interviewer through

1. **The API never does the expensive work.** `POST /orders` does exactly one INSERT and one SQS `SendMessage`, then returns. Driver matching — the part that's O(n) over candidate drivers and could get slower as the fleet grows — happens entirely in `dispatch-worker`, off the request path. This is *the* reason the API's p99 stays flat under load regardless of how expensive matching gets (see [`services/dispatch-api/src/routes.rs`](services/dispatch-api/src/routes.rs)).
2. **Resilient by construction, not by accident.** If the SQS publish fails after the order is already saved, the request still succeeds — the order exists, and a stuck order is recoverable (retry/reconciliation), but a "your order failed because our notification system hiccupped" response would be a false negative that costs a customer. This pattern — core transaction succeeds even when a secondary operation fails — comes directly from production dispatch/inspection-order work in my CV, not from a tutorial.
3. **At-least-once delivery is handled explicitly, not hoped away.** SQS and EventBridge both guarantee at-least-once delivery. `dispatch-worker` claims an order with `UPDATE orders SET status='assigned' WHERE status='pending'` inside a transaction — a duplicate message becomes a no-op, not a duplicate assignment. `dispatch-notify-lambda` writes its audit record keyed by `assignment_id`, so a duplicate EventBridge delivery overwrites the same S3 key instead of creating a second record. See [`services/dispatch-worker/src/matching.rs`](services/dispatch-worker/src/matching.rs).
4. **Concurrency is bounded everywhere it touches a shared resource.** The Postgres connection pool has a max size (`db_max_connections`); the worker caps how many order-assignment transactions run at once (`max_in_flight`, a `tokio::sync::Semaphore`). Both exist for the same reason: unbounded concurrency against a slow downstream doesn't fail gracefully, it falls over exactly when load is highest. See `Config` in both services.
5. **The event bus is the actual point, not a checkbox.** `dispatch-worker` publishes `DispatchAssigned` to EventBridge and does not know or care what's listening. Today that's one Lambda (notification + audit). Adding a billing service or an analytics pipeline later is a new EventBridge rule pointed at the same bus — zero changes to the worker. That's the architectural argument for an event bus over the worker calling a notification service directly.

## Tech stack and why each piece is there

| Layer | Choice | Why |
|---|---|---|
| API | Rust, Actix Web, Tokio | Actix's actor-free, multi-threaded-executor model gives predictable low-tail-latency HTTP handling; matches my production experience (Actix Web at Find & Hire). |
| Async runtime | Tokio | The de facto standard; used for the API, the SQS/EventBridge consumer loop, and structured concurrency (`Semaphore`, `spawn`). |
| Database | PostgreSQL + SQLx | Runtime-checked queries (no `DATABASE_URL` needed at compile time — see "A note on building this repo" below), `FOR UPDATE SKIP LOCKED` for safe concurrent driver claiming. |
| Messaging | AWS SQS | Durable, at-least-once, cheap, and the natural place to put backpressure between "accept the order" and "do the expensive matching." |
| Event bus | AWS EventBridge | Decouples the worker from every downstream consumer; adding a new subscriber never touches the publisher. |
| Compute | Docker on ECS Fargate (api, worker) + AWS Lambda (notify) | Two different workload shapes get two different compute models on purpose: long-running request/consumer loops on Fargate, a short-lived event reaction on Lambda — not "Lambda for everything" cargo-culting. |
| IaC | Terraform | SQS/DLQ, EventBridge bus+rule, ECR, IAM (task execution role split from task role — least privilege), ECS cluster/services/ALB, RDS, S3, SNS, Lambda. |
| CI/CD | GitHub Actions | fmt/clippy/test/docker-build on every push; a separate manually-triggered `deploy.yml` using OIDC (no long-lived AWS keys in CI) pushes images and runs `terraform apply`. |
| Local dev | Docker Compose + LocalStack | The entire pipeline — SQS → worker → EventBridge → Lambda-equivalent — runs locally with zero AWS cost via `docker compose up`. |

## Low-latency decisions (the "low latency coding" ask, made concrete)

- **Hot path does minimum I/O.** `POST /orders`: one DB write, one SQS publish, no synchronous call to anything else. Matching, notification, and audit logging are all off the request path.
- **Long polling, not short polling.** `dispatch-worker` uses SQS `WaitTimeSeconds=20` (the maximum), so an idle worker makes ~3 API calls/minute instead of hammering SQS — lower cost, and no tight-loop CPU/latency-variance noise.
- **Bounded concurrency everywhere.** DB pool size and worker in-flight semaphore are both explicit, tunable knobs (env vars), not "however many the runtime happens to schedule."
- **`FOR UPDATE SKIP LOCKED` for driver matching.** Two workers racing on two different orders don't block each other on the same driver row — the loser just sees the next-nearest candidate instead of waiting on a lock.
- **O(n) matching is a stated, deliberate complexity budget** for a single dispatch region polled every few seconds — not an oversight. `crates/dispatch-core/src/geo.rs` says explicitly where a spatial index (PostGIS `ST_DWithin` + GiST, or an R-tree) would replace the linear scan at real fleet scale.
- **`tracing::Instrument` instead of holding a span guard across `.await`.** A subtle, real async-Rust correctness bug (not a latency one, but the kind of thing that separates "wrote some Rust" from "understands the executor model") — see the comment in `services/dispatch-worker/src/main.rs`.
- **Multi-stage Docker builds with `cargo-chef`.** Dependency compilation is cached separately from application code, so a source-only change rebuilds in seconds, not minutes — matters for the actual "how fast can we ship a fix" story, not just runtime latency.

## Further reading

- [`docs/REQUIREMENTS.md`](docs/REQUIREMENTS.md) — the requirements analysis this system was built from: functional/non-functional requirements, use cases, and a traceability table mapping every requirement to the code that implements it.
- [`docs/DEPLOYMENT_GUIDE.md`](docs/DEPLOYMENT_GUIDE.md) — the full runbook for the CI/CD-to-Fargate pipeline: one-time OIDC bootstrap, how `deploy.yml` flows end to end, verifying a live deployment, and tearing it down.
- [`docs/SQS_DESIGN.md`](docs/SQS_DESIGN.md) — a complete deep-dive on the SQS integration specifically: configuration, message contract, idempotency design, and how to test it against LocalStack.
- [`docs/RESUME_BULLETS.md`](docs/RESUME_BULLETS.md) — CV bullets, an interview answer, and a table of likely follow-up questions mapped to the file that answers each.
- [`docs/SPRINT_LOG.md`](docs/SPRINT_LOG.md) — this project is being built agile, week by week, not delivered as one batch. This is the running record of each week's scope, the one real design decision it forced, and what's been built ahead of schedule vs. actually verified in sequence.

## Repository layout

```
crates/dispatch-core/         Pure domain logic: types, events, haversine + nearest-driver matching (zero I/O — unit tested in microseconds)
services/dispatch-api/        Actix Web REST API — POST /orders, GET /orders/{id}, driver registration
services/dispatch-worker/     Tokio SQS consumer — matching, EventBridge publish, transaction-safe idempotency
services/dispatch-notify-lambda/  Rust Lambda (EventBridge-triggered) — notification + S3 audit record
migrations/                   SQLx migrations (orders, drivers, assignments)
infra/terraform/              Full AWS deployment: SQS/DLQ, EventBridge, ECR, IAM (incl. GitHub OIDC deploy role), ECS+ALB, RDS, S3, SNS, Lambda, CloudWatch alarms + dashboard
infra/localstack/             LocalStack bootstrap script for docker-compose
.github/workflows/            CI (fmt/clippy/test/docker build) + manually-triggered OIDC deploy
loadtest/                     k6 script for POST /orders — see "Measuring latency" below
scripts/seed.sh               Seeds demo drivers for local testing
scripts/week1_smoke_test.sh   Runnable Week 1 acceptance check (see docs/SPRINT_LOG.md)
docs/REQUIREMENTS.md          Requirements analysis: FRs/NFRs/use-cases, traceable to code
docs/DEPLOYMENT_GUIDE.md      CI/CD-to-Fargate runbook: OIDC bootstrap, deploy flow, teardown
docs/SQS_DESIGN.md            SQS integration deep-dive: config, contract, idempotency
docs/RESUME_BULLETS.md        CV bullets and interview prep tied to this repo
docs/SPRINT_LOG.md            Week-by-week agile build log: scope, decisions, backlog
```

## Running it locally

```bash
cp .env.example .env   # optional — the defaults already point at the compose services
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

### A note on building this repo

Every query in `dispatch-api`/`dispatch-worker` uses SQLx's **runtime-checked** query API (`sqlx::query`/`query_as`), not the `query!` compile-time macro — a deliberate choice so `cargo check`/`cargo build` never require a live `DATABASE_URL` or a committed `.sqlx` offline cache just to compile. The trade-off is losing compile-time SQL validation; `cargo test --workspace` against the Postgres service in CI (see `.github/workflows/ci.yml`) is what actually exercises the queries.

This repo was scaffolded in a sandboxed environment without access to crates.io, so the dependency graph has **not** been compiled here — the code has been written and manually reviewed carefully (types, borrow-checker patterns like `&mut **tx`, `Result`/`?` propagation all double-checked by hand), but the very first thing to do after downloading this is:

```bash
cargo fmt --all
cargo clippy --workspace --all-targets
cargo test --workspace
```

and fix whatever that first real compile turns up — treat it as step zero, not as a sign anything here was left unfinished. GitHub Actions CI runs exactly these three commands on every push, so once it's pushed the badge is your source of truth.

## Deploying to real AWS

Short version:

```bash
cd infra/terraform
terraform init
terraform apply -var="github_repository=<org>/<repo>" -var="db_password=$(openssl rand -base64 24)"
```

This provisions: SQS queue + DLQ with a redrive policy, an EventBridge custom bus + rule, three ECR repos, IAM roles (execution role split from task role, least privilege per service — plus a dedicated GitHub OIDC deploy role, see `infra/terraform/github-oidc.tf`), an ECS Fargate cluster running `dispatch-api` (behind an ALB) and `dispatch-worker`, an RDS Postgres instance, an S3 bucket for audit records, an SNS topic for notifications, CloudWatch alarms on SQS backlog/DLQ/ECS task count/ALB 5xx rate (`infra/terraform/monitoring.tf`), and the `dispatch-notify-lambda` function wired to the EventBridge rule.

**Full version, including the one-time OIDC bootstrap and how the CI/CD pipeline flows end to end: [`docs/DEPLOYMENT_GUIDE.md`](docs/DEPLOYMENT_GUIDE.md).** In practice you don't run `terraform apply` from a laptop for anything but that one bootstrap step — every deploy after that goes through `.github/workflows/deploy.yml`, authenticated via OIDC, with the image tag set to the git SHA that was actually built and tested.

## Measuring latency

```bash
k6 run -e BASE_URL=http://localhost:8080 loadtest/orders.js
```

The script ramps to 200 concurrent virtual users against `POST /orders` and asserts `p(95) < 150ms` / `p(99) < 400ms` / error rate `< 1%` as CI-style thresholds — k6 exits non-zero if they're not met. Run it, then paste your own numbers here:

| Metric | Result |
|---|---|
| p50 | _fill in after running against your deployment_ |
| p95 | |
| p99 | |
| Error rate | |
| Throughput (req/s) | |

Having real numbers instead of "should be fast" is the difference between a claim and evidence — fill this table in before an interview, from your own run, not from this template.

## What I'd change for a real production deployment

Said out loud, unprompted, in an interview — this is what separates "built a demo" from "understands the trade-offs":

- **Networking:** default VPC + public subnets for the demo; production wants private subnets for ECS/RDS behind a NAT gateway, with only the ALB public.
- **Database:** single-AZ `db.t4g.micro`, 1-day backup retention; production wants Multi-AZ, longer retention, and read replicas once read traffic (e.g. `GET /orders/{id}` at scale) justifies them.
- **Geospatial matching:** in-process haversine scan over region-filtered candidates; at real fleet scale this becomes a PostGIS `ST_DWithin` query with a GiST index, or a dedicated spatial index service.
- **Autoscaling:** `desired_count` is fixed in Terraform; production wants ECS Service Auto Scaling on CPU/ALB request count, and SQS-queue-depth-based scaling for the worker.
- **Secrets:** `db_password` flows through a Terraform variable/CI secret today; production wants AWS Secrets Manager with rotation, referenced by ARN in the task definition.
- **Observability:** structured JSON logs to CloudWatch today; production wants distributed tracing (OpenTelemetry) across the SQS → worker → EventBridge → Lambda hop, so a slow assignment is traceable end-to-end, not just visible as separate log lines in three places.

## About this project

Built by **Jupiter Barua** — Rust backend/platform engineer, 12+ years in software engineering, 8+ years building production backend systems (Rust/Actix Web/Tokio/PostgreSQL/SQLx, AWS EC2/Lambda/S3/ECR, Docker, CI/CD), currently based in Germany. This repo exists to make the "distributed systems, AWS, low-latency Rust" line on my CV something you can actually read the code for, not just take my word for.

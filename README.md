# Velocity Dispatch

A real-time delivery/logistics dispatch platform built in Rust to be event-driven and horizontally scalable, with AWS SQS, EventBridge, Lambda and ECS Fargate as its backbone.

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

## How it works

1. **The API never does the expensive work.** `POST /orders` does exactly one INSERT and one SQS `SendMessage`, then returns. Driver matching — O(n) over candidate drivers — happens entirely in `dispatch-worker`, off the request path, so the API's tail latency stays flat regardless of how expensive matching gets (see [`services/dispatch-api/src/routes.rs`](services/dispatch-api/src/routes.rs)).
2. **Resilient by construction.** If the SQS publish fails after the order is already saved, the request still succeeds — the order exists, and a stuck order is recoverable (retry/reconciliation), whereas failing the request would be a false negative.
3. **At-least-once delivery is handled explicitly.** SQS and EventBridge both guarantee at-least-once delivery. `dispatch-worker` claims an order with `UPDATE orders SET status='assigned' WHERE status='pending'` inside a transaction — a duplicate message becomes a no-op, not a duplicate assignment. `dispatch-notify-lambda` writes its audit record keyed by `assignment_id`, so a duplicate EventBridge delivery overwrites the same S3 key instead of creating a second record. See [`services/dispatch-worker/src/matching.rs`](services/dispatch-worker/src/matching.rs).
4. **Concurrency is bounded wherever a shared resource is touched.** The Postgres connection pool has a max size (`db_max_connections`); the worker caps how many order-assignment transactions run at once (`max_in_flight`, a `tokio::sync::Semaphore`).
5. **The event bus decouples publisher from consumers.** `dispatch-worker` publishes `DispatchAssigned` to EventBridge and does not know what's listening. Today that's one Lambda (notification + audit); adding a billing service or an analytics pipeline later is a new EventBridge rule on the same bus, with no changes to the worker.

## Tech stack

| Layer | Choice | Why |
|---|---|---|
| API | Rust, Actix Web, Tokio | Multi-threaded executor model with predictable low-tail-latency HTTP handling. |
| Async runtime | Tokio | Used for the API, the SQS/EventBridge consumer loop, and structured concurrency (`Semaphore`, `spawn`). |
| Database | PostgreSQL + SQLx | Runtime-checked queries (no `DATABASE_URL` needed at compile time), `FOR UPDATE SKIP LOCKED` for safe concurrent driver claiming. |
| Messaging | AWS SQS | Durable, at-least-once, cheap, and the natural place for backpressure between "accept the order" and "do the expensive matching." |
| Event bus | AWS EventBridge | Decouples the worker from every downstream consumer; adding a new subscriber never touches the publisher. |
| Compute | Docker on ECS Fargate (api, worker) + AWS Lambda (notify) | Long-running request/consumer loops on Fargate, a short-lived event reaction on Lambda. |
| IaC | Terraform | SQS/DLQ, EventBridge bus + rule, ECR, IAM (task execution role split from task role), ECS cluster/services/ALB, RDS, S3, SNS, Lambda, CloudWatch alarms and dashboard. |
| CI/CD | GitHub Actions | fmt/clippy/test/docker-build on every push; a separate manually-triggered `deploy.yml` using OIDC (no long-lived AWS keys in CI) pushes images and runs `terraform apply`. |
| Local dev | Docker Compose + LocalStack | The entire pipeline — SQS → worker → EventBridge → Lambda-equivalent — runs locally with zero AWS cost. |

## Low-latency decisions

- **Hot path does minimum I/O.** `POST /orders`: one DB write, one SQS publish, no synchronous call to anything else.
- **Long polling, not short polling.** `dispatch-worker` uses SQS `WaitTimeSeconds=20`, so an idle worker makes ~3 API calls/minute instead of hammering SQS.
- **Bounded concurrency.** DB pool size and worker in-flight semaphore are explicit, tunable knobs (env vars).
- **`FOR UPDATE SKIP LOCKED` for driver matching.** Two workers racing on different orders don't block each other on the same driver row.
- **O(n) matching is a stated complexity budget** for a single dispatch region; `crates/dispatch-core/src/geo.rs` says where a spatial index (PostGIS `ST_DWithin` + GiST, or an R-tree) would replace the linear scan at larger fleet scale.
- **`tracing::Instrument` instead of holding a span guard across `.await`**, to keep spans correct on the async executor — see `services/dispatch-worker/src/main.rs`.
- **Multi-stage Docker builds with `cargo-chef`**, so dependency compilation is cached separately from application code.

## Repository layout

```
crates/dispatch-core/         Pure domain logic: types, events, haversine + nearest-driver matching (zero I/O)
services/dispatch-api/        Actix Web REST API — POST /orders, GET /orders/{id}, driver registration
services/dispatch-worker/     Tokio SQS consumer — matching, EventBridge publish, transaction-safe idempotency
services/dispatch-notify-lambda/  Rust Lambda (EventBridge-triggered) — notification + S3 audit record
migrations/                   SQLx migrations (orders, drivers, assignments)
infra/terraform/              AWS deployment: SQS/DLQ, EventBridge, ECR, IAM (incl. GitHub OIDC deploy role), ECS+ALB, RDS, S3, SNS, Lambda, CloudWatch alarms + dashboard
infra/localstack/             LocalStack bootstrap script for docker-compose
k8s/                          Kubernetes manifests to run the published images on a local cluster — see k8s/README.md
.github/workflows/            CI (fmt/clippy/test/docker build) + manually-triggered OIDC deploy
loadtest/                     k6 script for POST /orders
scripts/                      Demo driver seeding and the Week 1 smoke test
docs/GETTING_STARTED.md        Run locally / on Kubernetes / on AWS, load testing, production considerations
docs/REQUIREMENTS.md          Requirements analysis: FRs/NFRs/use-cases, traceable to code
docs/DEPLOYMENT_GUIDE.md      CI/CD-to-Fargate runbook: OIDC bootstrap, deploy flow, teardown
docs/SQS_DESIGN.md            SQS integration deep-dive: config, contract, idempotency
docs/SPRINT_LOG.md            Week-by-week build log: scope, decisions, backlog
```

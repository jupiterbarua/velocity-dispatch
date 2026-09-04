# Requirements Analysis Document — Velocity Dispatch

| | |
|---|---|
| **Document type** | Software Requirements Specification (SRS), informal/portfolio format |
| **System** | Velocity Dispatch — real-time delivery dispatch platform |
| **Author** | Jupiter Barua |
| **Status** | Baseline — traceable to the implementation in this repository |

This document exists for two reasons at once: it's the requirements analysis a real project like this would start from, and it's a deliberate demonstration of the "structured requirement analysis and technical design" line on my CV — every requirement below is traceable to a specific file in the implementation, not aspirational.

## 1. Introduction

### 1.1 Purpose

Define what Velocity Dispatch must do, how well it must do it, and where its boundaries are — before describing how it does it (that's the README and the code). This document is the "what and why"; the README's "Tech stack" and "Low-latency decisions" sections are the corresponding "how."

### 1.2 Scope

Velocity Dispatch accepts delivery orders, matches each one to the nearest available driver, and notifies the relevant parties once a match is made. It is a backend/platform system — no end-user UI is in scope (see §9, Out of Scope).

### 1.3 Definitions

| Term | Meaning |
|---|---|
| Order | A single delivery request with a pickup and drop-off location |
| Driver | A courier who can be assigned to an order |
| Assignment | The record of a specific driver being matched to a specific order |
| Dispatch region | The geographic area a single worker instance matches drivers within (see NFR-3) |
| At-least-once delivery | A messaging guarantee where a consumer may receive the same message more than once |

### 1.4 References

- CV: "Interested in high-availability routing and logistics APIs, distributed systems, operational excellence and data-driven service quality" — the stated interest this project is built to demonstrate evidence for.
- AWS Well-Architected Framework (Reliability & Performance Efficiency pillars) — informs NFR-2 through NFR-5.

## 2. Overall description

### 2.1 Product perspective

Velocity Dispatch is a new, self-contained system — not an extension of an existing product. It's composed of three independently deployable services (`dispatch-api`, `dispatch-worker`, `dispatch-notify-lambda`) sharing one domain-logic library (`dispatch-core`), connected through AWS-managed messaging rather than direct network calls.

### 2.2 Product functions (summary)

1. Accept a new delivery order via a REST API.
2. Register and update drivers (location, availability).
3. Match each pending order to the nearest available driver within a configurable radius.
4. Notify the relevant parties and persist an audit record once a match is made.
5. Recover automatically from transient failures in messaging, the database, or a downstream AWS service, without operator intervention, up to a defined retry limit.

### 2.3 User classes and characteristics

| User class | Description | Primary interface |
|---|---|---|
| Ordering client | A frontend, mobile app, or third-party system placing delivery orders on a customer's behalf | `dispatch-api` REST endpoints |
| Driver-facing system | A system reporting driver location/availability (in production, a driver's mobile app) | `dispatch-api` REST endpoints |
| Operations engineer | Monitors queue depth, DLQ contents, and service health | CloudWatch dashboards/alarms, structured logs |
| Downstream consumer (future) | Any system that wants to react to a completed dispatch — billing, analytics, a rider-facing app | EventBridge bus subscription (no code change to the publisher required — see FR-9) |

### 2.4 Operating environment

Rust/Tokio services running as Docker containers on AWS ECS Fargate (`dispatch-api`, `dispatch-worker`) and as a Rust AWS Lambda (`dispatch-notify-lambda`), backed by RDS PostgreSQL, AWS SQS, and AWS EventBridge. Locally, the identical topology runs via Docker Compose with LocalStack standing in for the AWS services.

### 2.5 Constraints

- Must run cost-effectively as a portfolio/demo deployment (see the Terraform's documented cost-saving choices: single-AZ RDS, `db.t4g.micro`, no NAT gateway).
- Must be fully runnable with zero AWS account/cost via Docker Compose + LocalStack, for local development and for anyone evaluating the repo without an AWS account.
- Must compile without a live database connection (no `DATABASE_URL` required at `cargo build` time) — see ADR-1 in §10.

### 2.6 Assumptions and dependencies

- A single dispatch region is small enough that an O(n) in-process scan over candidate drivers is an acceptable matching cost (see NFR-3 and the note in `crates/dispatch-core/src/geo.rs`).
- AWS SQS and EventBridge are assumed to provide at-least-once, not exactly-once, delivery — every consumer is designed around that assumption rather than around it being an edge case (see FR-6, FR-8).

## 3. System context

```
                 ┌──────────────────┐        OrderCreated         ┌──────────────────┐
  Ordering       │                  │ ──────── (SQS) ───────────▶ │                  │
  client   ─────▶│   dispatch-api   │                              │  dispatch-worker │
                 │  (Actix + Tokio) │                              │  (Tokio consumer)│
                 └────────┬─────────┘                              └────────┬─────────┘
                          │                                                  │
                          ▼                                                  ▼
                    PostgreSQL (RDS)  ◀───────────────────────────── PostgreSQL (RDS)
                                                                              │
                                                                   DispatchAssigned
                                                                    (EventBridge)
                                                                              │
                                                                              ▼
                                                                ┌──────────────────────┐
                                                                │ dispatch-notify-lambda│
                                                                └──────────┬────────────┘
                                                                           │
                                                          ┌────────────────┴───────────────┐
                                                          ▼                                 ▼
                                                    SNS (notify)                     S3 (audit record)
```

## 4. Functional requirements

Each requirement has a priority (Must/Should/Could, MoSCoW) and points at the file that implements it, so this document stays honest — if the traceability column is wrong, the requirement isn't actually met yet.

| ID | Requirement | Priority | Implemented in |
|---|---|---|---|
| FR-1 | The system shall accept a new order via `POST /orders` with a pickup and drop-off coordinate, and return a `201 Created` with the order's ID and status. | Must | `services/dispatch-api/src/routes.rs::create_order` |
| FR-2 | The system shall reject an order with an out-of-range latitude/longitude (outside ±90°/±180°) with a `400 Bad Request`. | Must | `crates/dispatch-core/src/model.rs::GeoPoint::new` |
| FR-3 | The system shall allow retrieving an order's current status via `GET /orders/{id}`, returning `404` if it doesn't exist. | Must | `services/dispatch-api/src/routes.rs::get_order` |
| FR-4 | The system shall allow registering a driver with a name and starting location via `POST /drivers`. | Must | `services/dispatch-api/src/routes.rs::register_driver` |
| FR-5 | The system shall allow updating a driver's location and status (`available`/`busy`/`offline`) via `POST /drivers/{id}/location`. | Must | `services/dispatch-api/src/routes.rs::update_driver_location` |
| FR-6 | The system shall asynchronously match each pending order to the nearest `available` driver within a configurable radius, and shall not match the same order twice even if its creation event is delivered more than once. | Must | `services/dispatch-worker/src/matching.rs::assign_order` |
| FR-7 | If no driver is available within radius at match time, the system shall retry the match automatically without operator action, up to a bounded number of attempts, before routing the order for manual/operational follow-up. | Must | SQS redrive policy, `infra/terraform/sqs.tf`; worker behavior in `services/dispatch-worker/src/main.rs::handle_message` |
| FR-8 | Once a driver is matched, the system shall publish a `DispatchAssigned` event that any number of independent downstream consumers can subscribe to, without the publisher being modified or aware of the subscriber. | Must | `services/dispatch-worker/src/eventbridge.rs`, `infra/terraform/eventbridge.tf` |
| FR-9 | The system shall send a notification and write a durable, deduplicated audit record for every completed dispatch assignment. | Must | `services/dispatch-notify-lambda/src/{notify,audit}.rs` |
| FR-10 | The system shall expose a health-check endpoint suitable for load balancer and container-orchestrator health probes. | Must | `services/dispatch-api/src/routes.rs::health` |
| FR-11 | The system shall list currently available drivers via `GET /drivers`, to support operational visibility and the load test's seeding step. | Should | `services/dispatch-api/src/routes.rs::list_drivers` |

## 5. Non-functional requirements

| ID | Requirement | Target / measure | Verified by |
|---|---|---|---|
| NFR-1 (Performance) | `POST /orders` response latency shall be independent of driver-matching cost. | Matching happens entirely outside the request path (architectural, not a runtime metric) | Code review: `routes.rs::create_order` does exactly one DB write + one SQS publish |
| NFR-2 (Latency SLO) | Under a realistic concurrent load, `POST /orders` shall meet p95 < 150ms, p99 < 400ms, error rate < 1%. | See thresholds | `loadtest/orders.js` (k6), results to be filled into the README's latency table against a real deployment |
| NFR-3 (Scalability) | The matching algorithm's complexity shall be an explicit, documented, revisitable choice, not an unstated assumption. | O(n) over region-filtered candidates, stated as the "complexity budget" for one dispatch region | `crates/dispatch-core/src/geo.rs` module doc comment |
| NFR-4 (Resilience — messaging) | The system shall tolerate at-least-once delivery from both SQS and EventBridge without duplicate side effects. | No duplicate driver assignment; no duplicate audit record | `matching.rs` conditional claim; `audit.rs` idempotent S3 key |
| NFR-5 (Resilience — dependency failure) | A failure in a non-critical downstream call (e.g. event publish) shall not fail an otherwise-successful primary transaction. | Order creation succeeds even if the SQS publish fails | `routes.rs::create_order` — publish failure is logged, not propagated as a request error |
| NFR-6 (Resource bounding) | The system shall bound concurrency against every shared, rate-limited resource (DB connections, in-flight message processing). | Configurable, explicit limits, not implicit/unbounded | `Config::db_max_connections`, `Config::max_in_flight` in both services |
| NFR-7 (Observability) | The system shall emit structured (JSON) logs, business-outcome metrics (not just infrastructure symptoms), and operational alarms covering queue backlog, dead-letter accumulation, service capacity, and application error rate. Health probes shall verify actual dependency reachability, not just process liveness. | JSON logs via `tracing`; EMF business metrics; CloudWatch alarms + dashboard; DB-backed `/health` | `telemetry.rs` in each service; `services/dispatch-worker/src/metrics.rs`; `infra/terraform/monitoring.tf`, `infra/terraform/dashboard.tf`; `routes.rs::health` + `db.rs::health_check` |
| NFR-8 (Security) | AWS IAM permissions shall follow least privilege: each service's runtime role shall be scoped to only the specific queue/bus/bucket/topic it needs, and CI shall authenticate to AWS without long-lived credentials. | Per-service IAM policies; GitHub OIDC, no static AWS keys in CI | `infra/terraform/iam.tf`, `infra/terraform/github-oidc.tf` |
| NFR-9 (Portability / dev experience) | The full system shall be runnable locally with zero AWS cost and zero AWS account. | `docker compose up` brings up the full pipeline against LocalStack | `docker-compose.yml`, `infra/localstack/init-aws.sh` |
| NFR-10 (Maintainability) | Every non-obvious design decision shall be documented at the point of decision, not only in a separate document that can drift out of sync with the code. | Inline doc comments explaining *why*, not just *what* | Throughout — e.g. `matching.rs`, `geo.rs`, `db.rs` |

## 6. Representative use cases

**UC-1: Place an order and get matched.** An ordering client submits a pickup/drop-off pair. The system durably records the order and returns immediately. Within a few seconds (bounded by SQS long-poll interval + matching time), a driver is matched, and a downstream notification fires — without the ordering client needing to poll for this, though `GET /orders/{id}` is available for that if a caller wants it.

**UC-2: No driver available.** Same as UC-1, but no `available` driver is within the configured radius at match time. The order stays `pending`; the worker's message is left un-deleted so SQS redelivers it after the visibility timeout, giving the system another chance once a driver frees up or moves into range. After five failed attempts the message moves to the DLQ for operational follow-up (FR-7).

**UC-3: Duplicate event delivery.** SQS redelivers an `OrderCreated` message that was already successfully processed (a normal, expected occurrence under at-least-once delivery, not a bug). The worker's conditional claim (`UPDATE ... WHERE status = 'pending'`) makes this a no-op: no second driver is assigned, and the message is acknowledged (deleted) rather than retried forever.

**UC-4: Adding a new downstream consumer.** A future requirement — e.g., a billing service that needs to react to completed dispatches — is satisfied by adding a new EventBridge rule targeting the existing bus. No change to `dispatch-worker` is required. This is the acceptance test for FR-8/NFR-3's decoupling claim, not just an assertion about it.

## 7. Data requirements

Three entities — `Order`, `Driver`, `Assignment` — with the schema defined in `migrations/20260101000001_init.sql`. Referential integrity is enforced at the database level (`assignments.order_id`/`driver_id` foreign keys). See the migration file itself for the field-level rationale (e.g., why status is a `CHECK`-constrained `TEXT` column rather than a Postgres `ENUM`).

## 8. External interface requirements

| Interface | Direction | Format |
|---|---|---|
| `dispatch-api` REST endpoints | Inbound (ordering clients) | JSON over HTTP |
| SQS `order-created` queue | `dispatch-api` → `dispatch-worker` | JSON, `OrderCreated` schema (`crates/dispatch-core/src/events.rs`) |
| EventBridge `velocity-dispatch-bus`, `DispatchAssigned` rule | `dispatch-worker` → any subscriber | JSON, `DispatchAssigned` schema |
| SNS `velocity-dispatch-notifications` topic | `dispatch-notify-lambda` → notification subscribers | JSON |
| S3 audit bucket | `dispatch-notify-lambda` → durable storage | JSON, one object per assignment |

## 9. Out of scope

Explicitly not built, so scope doesn't silently creep and so an interviewer's "did you build X" question has an honest "no, and here's why" answer available:

- Authentication/authorization on the REST API (would be JWT-based, matching the pattern already used in my production work at Find & Hire — omitted here to keep the repo focused on the messaging/event architecture, which is the point of this project).
- A rider/driver-facing UI or mobile app.
- Real-time order tracking (e.g., WebSocket push of driver location) — the data model supports it (`drivers.lat/lon` updates), but no push mechanism is implemented.
- Payments/billing.
- Multi-region deployment (the Terraform is single-region; see the README's "What I'd change for production" section).

## 8.1 Known gap (backlog, not yet built)

Found during design review, kept here rather than silently patched, because an honest backlog is more credible than a document that only ever describes finished work: **`OrderStatus::PickedUp` and `OrderStatus::Delivered` are defined in the domain model and the database `CHECK` constraint (FR — data model) but no code path ever produces them.** A driver is set to `busy` at match time (`dispatch-worker::record_assignment`) and never automatically returns to `available` — nothing in the system currently represents "the delivery finished." Candidate designs discussed: (a) a manual `POST /orders/{id}/deliver`-style endpoint, kept synchronous in `dispatch-api` since it's a simple guarded state transition, not matching work; or (b) an automatic transition driven by geofencing — reusing `crates/dispatch-core/src/geo.rs::haversine_km` against the order's pickup/dropoff coordinates on each `POST /drivers/{id}/location` ping, with the same conditional-`UPDATE`-based idempotency pattern already used in `claim_order_for_assignment`. Not yet decided or implemented — tracked here as FR-12 (unassigned) until it is.

## 10. Key architecture decision records (condensed)

- **ADR-1: Runtime-checked SQL, not compile-time `query!`.** Chosen so the workspace compiles without a live database connection, at the cost of losing compile-time SQL validation (mitigated by `cargo test` against a real Postgres in CI).
- **ADR-2: Matching in a separate worker, not inline in the API.** Chosen to decouple API response latency from matching cost (NFR-1), at the cost of matched-driver status not being visible in the `POST /orders` response itself (mitigated by `GET /orders/{id}` for polling, acceptable per UC-1).
- **ADR-3: EventBridge for fan-out, SQS for the API→worker handoff.** Two different messaging primitives for two different jobs — SQS is a point-to-point durable work queue; EventBridge is a pub/sub bus for everything downstream of the result. Using EventBridge everywhere would lose SQS's built-in backpressure/redrive semantics for the primary work queue; using SQS everywhere would require the worker to know every downstream subscriber.

## 11. Acceptance criteria / definition of done

A change to this system is considered complete when: the relevant functional requirement's traceability entry in §4 still points at real, tested code; `cargo fmt`, `cargo clippy -D warnings`, and `cargo test --workspace` pass in CI; and, for anything touching NFR-2 through NFR-9, the corresponding section of this document has been updated in the same change — this document is meant to be a living artifact, not a one-time write-up.

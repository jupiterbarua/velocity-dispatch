# Sprint Log

This project is being built agile, not delivered as one batch — this file is the running record of what each week's scope was, why, and what "done" actually meant. It's also honest about the fact that a few pieces exist in the repo *ahead* of the week they logically belong to (built in an earlier pass before this week-by-week discipline started) — those are marked explicitly rather than quietly counted as finished, because a backlog that only ever shows completed work isn't a real backlog.

## What "independently working service" means here

Said out loud once so every week can be checked against the same bar, not a vibe:

1. **Owns its own persistence readiness.** Neither service assumes the other has already prepared the database — each runs its own migrations (see `services/dispatch-worker/src/db.rs::connect` for why running `sqlx::migrate!` from two services concurrently is *safe*, not racy).
2. **Owns its own startup order.** No service's `docker-compose.yml` entry (or, later, ECS service) depends on another *application* service being healthy first — only on shared infrastructure (Postgres, LocalStack/AWS).
3. **Owns its own deployable artifact.** Its own `Dockerfile`, its own ECR repository, its own ECS service (or, for the notify path, its own Lambda function) — never bundled into another service's image or task definition.
4. **Talks to its neighbors only through durable infrastructure.** SQS and EventBridge, never a direct HTTP/RPC call from one service to another. This is the one that's easy to get right by construction (it's just how the architecture is drawn) and easy to get wrong by accident (points 1 and 2 above are exactly where that accidentally leaked in before this week).

## Week 1 — walking skeleton: common + producer + consumer, local only

**Scope:** `dispatch-core` (common), `dispatch-api` (producer), `dispatch-worker` (consumer) running via `docker compose up`, talking through a real SQS queue (LocalStack), sharing nothing but the `dispatch-core` library and the Postgres schema. Explicitly **not** in scope this week: `dispatch-notify-lambda`, EventBridge, any real AWS deployment (Terraform), monitoring/dashboards. Those exist in the repo already (see "Built ahead" below) but aren't what Week 1 is being judged against.

**Acceptance criteria:**

- [ ] `docker compose up --build` brings up `postgres`, `localstack`, `dispatch-api`, `dispatch-worker` with no service waiting on another *application* service's health — only on `postgres`/`localstack`.
- [ ] `dispatch-api` and `dispatch-worker` can each be stopped and restarted independently without the other needing to restart, and without a fresh migration failing or duplicating anything.
- [ ] `POST /orders` returns `201` and the order lands in Postgres as `pending`.
- [ ] Within a few seconds (bounded by the SQS long-poll interval), `dispatch-worker` picks up the `OrderCreated` message, matches a driver (if one is registered and in range), and the order's status becomes `assigned`.
- [ ] `GET /orders/{id}` reflects that status change.
- [ ] `scripts/week1_smoke_test.sh` passes end to end (see that script for the exact checks — it's the runnable version of this checklist).

**This week's one real design decision:** `dispatch-worker` previously waited on `dispatch-api`'s health check before starting, because migrations were only run by `dispatch-api`. That's a startup-order coupling that directly violates criterion 2 above, so it's fixed this week: both services now run `sqlx::migrate!` themselves, safe because of Postgres's advisory lock during migration application (whichever process gets there first applies pending migrations; the other blocks briefly, then sees nothing left to do). `docker-compose.yml`'s `dispatch-worker` entry no longer depends on `dispatch-api` at all.

**Status:** scope complete, verification pending a real `cargo build`/`docker compose up` run — this repo was written in a sandboxed environment with no crates.io access (see the README's "A note on building this repo"), so `scripts/week1_smoke_test.sh` needs to be run somewhere with real network access before Week 1 is actually marked done, not just scoped.

## Built ahead of schedule (exists in the repo, not yet validated against this week's changes)

Written before this week-by-week discipline started. Not deleted — no reason to throw away working design — but flagged so this log stays honest about what's actually been verified in sequence versus what jumped ahead:

- **`dispatch-notify-lambda` + EventBridge** (candidate Week 2 scope) — the Lambda, the EventBridge bus/rule, the SNS/S3 wiring all exist (`services/dispatch-notify-lambda/`, `infra/terraform/eventbridge.tf`, `infra/terraform/lambda.tf`) but have never been exercised as part of a local end-to-end run in this week-by-week process.
- **AWS deployment via Terraform** (candidate Week 3 scope) — `infra/terraform/` provisions the full stack (ECS/Fargate, ALB, RDS, IAM, GitHub OIDC — see `docs/DEPLOYMENT_GUIDE.md`), but it was written before the Week 1 migration-ownership fix above; worth a quick pass once Week 1 is confirmed to make sure nothing in the ECS task definitions assumed the old startup ordering.
- **Monitoring/observability** (candidate Week 4 scope) — CloudWatch alarms, the dashboard, and the EMF business metrics (`infra/terraform/monitoring.tf`, `infra/terraform/dashboard.tf`, `services/dispatch-worker/src/metrics.rs`) all exist and are documented, but obviously can't be *observed doing anything* until there's a real deployment for them to watch.

## Backlog (not scheduled to a week yet)

- **FR-12 — delivery completion.** Still undecided between a manual endpoint and a geofence-driven automatic transition (see `docs/REQUIREMENTS.md` §8.1). Needs a decision before it gets a week.
- Authentication/authorization on the REST API (see `docs/REQUIREMENTS.md` §9, Out of scope — deliberately deferred, not forgotten).
- Real-time order tracking / a driver-facing push mechanism.

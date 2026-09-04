# Resume bullets and talking points for Velocity Dispatch

Drop-in bullets for your CV's "Selected Platform & Logistics-Relevant Work" section or a new "Personal Projects" section. Adjust verb tense/scope to taste — these are written to be true statements about what's actually in the repo, not aspirational.

## CV bullets (pick 3-4, don't dump all of them)

- Designed and built an event-driven logistics dispatch platform in Rust (Actix Web, Tokio, SQLx/PostgreSQL) with order intake, async driver-matching, and downstream notification/audit services fully decoupled via AWS SQS and EventBridge.
- Implemented transaction-safe, idempotent event processing for at-least-once delivery semantics (SQS/EventBridge), using `FOR UPDATE SKIP LOCKED` for safe concurrent resource claiming under Postgres.
- Deployed a multi-service Rust system to AWS (ECS Fargate + Lambda) via Terraform, including IAM least-privilege role separation, an Application Load Balancer, RDS, and a redrive-policy dead-letter queue.
- Built CI/CD with GitHub Actions (fmt/clippy/test/docker build on every push, OIDC-authenticated deploy pipeline — no long-lived AWS credentials in CI) and a fully containerised local dev environment (Docker Compose + LocalStack) replicating the full AWS event pipeline at zero cost.
- Load-tested the system's REST API with k6, defining and validating p95/p99 latency SLOs under concurrent load.

## One-line project summary (for a CV header / LinkedIn "Featured" section)

> Velocity Dispatch — a Rust/Tokio logistics dispatch platform (SQS, EventBridge, Lambda, ECS/Fargate, Terraform) demonstrating low-latency API design and event-driven backend architecture. [github.com/yourname/velocity-dispatch]

## The 90-second interview answer to "tell me about a project you're proud of"

Structure it as: problem → architecture decision → the thing that would break naively → how you prevented it → what you'd change at scale. Concretely:

"I built a delivery dispatch system — orders come in, get matched to the nearest available driver, and that triggers notifications and an audit trail. The interesting part isn't the CRUD, it's making the API's response time independent of how expensive matching gets: the API only writes the order and publishes an event, then a separate Tokio worker does the actual nearest-driver matching off the request path, and publishes an EventBridge event when it's done so anything downstream — a notification Lambda today, maybe billing or analytics later — can react without the worker knowing they exist.

The part I'd highlight if asked to go deeper: SQS and EventBridge are both at-least-once, so I had to make matching idempotent — I claim an order with a conditional UPDATE inside a transaction, so a duplicate message becomes a no-op instead of double-assigning a driver. And I used `FOR UPDATE SKIP LOCKED` when selecting candidate drivers so two workers processing two orders concurrently don't block on the same row.

If I were taking it to real production scale, the first thing I'd change is the matching algorithm — right now it's an in-process haversine scan over the drivers in a region, which is fine for one dispatch region polled every few seconds, but I'd move that to a PostGIS spatial index or a dedicated service once the candidate set gets large."

## Likely follow-up questions this project sets you up for — and where the answer lives

| Question | Where to look before the interview |
|---|---|
| "Why SQS *and* EventBridge, why not just one?" | README "Tech stack" table + point 5 in "five things" — SQS is the durable work queue between API and worker; EventBridge is the fan-out bus for everyone downstream of *the result* of that work. Different jobs. |
| "How do you handle a message being delivered twice?" | `services/dispatch-worker/src/matching.rs` — `claim_order_for_assignment`'s conditional UPDATE, and `dispatch-notify-lambda`'s audit write keyed by `assignment_id`. |
| "What happens if Postgres is slow?" | `db_max_connections` + `acquire_timeout` in `services/*/src/db.rs` / `config.rs` — bounded pool, explicit timeout, not unbounded blocking. |
| "Why Fargate for two services but Lambda for the third?" | README "Tech stack" row — long-running request/consumer loops vs. a short-lived event reaction; not "Lambda for everything." |
| "Walk me through a deploy." | `.github/workflows/deploy.yml` — OIDC role assumption, build+push per service, `terraform apply` gated behind a manual trigger and (for prod) a GitHub environment approval. |
| "What's your test story?" | `crates/dispatch-core/src/geo.rs` unit tests (haversine against a known Berlin↔Hamburg distance, matching logic against busy/offline drivers) — pure-domain logic with zero I/O, so it's fast and doesn't need mocks. Be honest that integration tests against the DB/AWS layer are the next thing to add — see the README's compile/test note. |
| "What would you change?" | README "What I'd change for a real production deployment" — have this section memorized, it's the single most common senior-leaning follow-up. |

## Framing for German job applications specifically

- Lead with the *decoupling* and *resilience* story, not "I used AWS X, Y, Z" — German engineering interviews (esp. at logistics/industrial companies) tend to probe reasoning over buzzword recall.
- If a job posting mentions Kubernetes/Terraform/"cloud-native" — this repo's Terraform + Docker story is your evidence; you already list "foundational Kubernetes and Terraform" on your CV, and this project gives you something concrete to point at rather than just the skill tag.
- Companies worth targeting given this project's theme: DHL/DHL Freight & parcel-tech teams, Kuehne+Nagel, DB Schenker, Flink/Gorillas-style quick-commerce (if still hiring in your target city), Trade Republic/N26-adjacent fintech (event-driven payments is architecturally the same shape), and any Berlin/Hamburg/Munich-based logistics-tech scaleup.
- Put the GitHub link in your CV header and your LinkedIn "Featured" section, not buried in a bullet — recruiters skimming CVs in Germany do click through if the link is visible up top.

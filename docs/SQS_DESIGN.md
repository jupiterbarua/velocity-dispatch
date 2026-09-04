# SQS Implementation Deep-Dive

`dispatch-api` and `dispatch-worker` are connected by exactly one AWS SQS queue. This document is the complete picture of that one integration — configuration, message contract, consumer implementation, failure handling, and how to test it — since "how do you use SQS" is one of the most likely follow-up questions this project sets up (see `docs/RESUME_BULLETS.md`'s question table).

## 1. Why SQS for this hop specifically

The API→worker handoff needs three properties: **durability** (an accepted order must not be lost if the worker is briefly down), **buffering** (a burst of orders shouldn't overwhelm the worker's matching throughput), and **point-to-point delivery** (exactly one worker instance should process each order — no fan-out needed here). SQS is the direct fit for all three; it's not used for the worker→everything-downstream hop, because that one specifically *needs* fan-out, which is EventBridge's job (see `docs/REQUIREMENTS.md`, ADR-3).

## 2. Queue configuration

Defined in `infra/terraform/sqs.tf`:

| Setting | Value | Reasoning |
|---|---|---|
| `visibility_timeout_seconds` | 30 | Must exceed the worker's expected per-message processing time (one Postgres transaction: a conditional UPDATE, a `SELECT ... FOR UPDATE SKIP LOCKED`, an INSERT, a commit — sub-second in practice). 30s gives generous headroom before SQS assumes the consumer died and redelivers. |
| `message_retention_seconds` | 345,600 (4 days) | Long enough to survive a multi-hour worker outage without losing orders, short enough not to accumulate stale data indefinitely. |
| `redrive_policy.maxReceiveCount` | 5 | An order gets 5 independent matching attempts (each attempt is a fresh chance — a driver may have become available since the last try) before being treated as needing human attention rather than automatic retry. |
| Dead-letter queue | `order-created-dlq`, 14-day retention (the SQS maximum) | Maximum retention specifically so a DLQ investigated a few days late still has the message, not just the CloudWatch alarm that fired when it arrived. |

The worker's SQS `receive_message` call (`services/dispatch-worker/src/main.rs::run_poll_loop`) additionally sets:

| Setting | Value | Reasoning |
|---|---|---|
| `max_number_of_messages` | 10 | The SQS maximum per call — fewer calls for the same throughput. |
| `wait_time_seconds` | 20 | Long polling at the SQS maximum. An idle worker makes ~3 API calls/minute instead of hammering the queue with `wait_time_seconds=0` short polls — cheaper, and removes a whole class of "why does idle CPU/network usage look noisy" investigation later. |

## 3. Message contract

`OrderCreated` (`crates/dispatch-core/src/events.rs`) — plain JSON, published as the SQS message body, with an `event_type` message attribute (`"OrderCreated"`) so a future consumer sharing this queue (not currently the case — one queue, one consumer today) could filter by type without deserializing every body first:

```json
{
  "order_id": "b3f1...",
  "pickup": { "lat": 52.52, "lon": 13.405 },
  "dropoff": { "lat": 52.50, "lon": 13.38 },
  "created_at": "2026-08-18T21:40:00Z"
}
```

This is a deliberately different shape from the `orders` database row (`services/dispatch-api/src/db.rs::OrderRow`) — the event contract and the storage schema are allowed to evolve independently, which matters the first time you want to add a column to the `orders` table without also needing a coordinated deploy of both services (see `docs/REQUIREMENTS.md` §10, and the comment at the top of `events.rs`).

## 4. Producer side (`dispatch-api`)

`services/dispatch-api/src/sqs.rs::OrderEventPublisher::publish` wraps a single `send_message` call. The call site, `routes.rs::create_order`, is the one place this project's resilience philosophy is most visible:

```rust
crate::db::insert_order(&state.pool, &order).await?;   // durable write — if this fails, the whole request fails, correctly

let event = OrderCreated { /* ... */ };
if let Err(err) = state.publisher.publish(&event).await {
    tracing::error!(order_id = %order.id, error = %err, "failed to publish OrderCreated event");
    // NOT propagated as a request error — see below
}

Ok(HttpResponse::Created().json(OrderResponse::from(order)))
```

If the SQS publish fails after the database insert succeeds, the client still gets `201 Created`. This is intentional: the order already exists durably, so a stuck order is a recoverable operational issue (a reconciliation job scanning for `pending` orders with no corresponding SQS message older than N minutes, not currently implemented but the natural next addition — see `docs/REQUIREMENTS.md` §9 for what's explicitly out of scope today), while failing the *request* would be a false negative — telling a customer their order failed when it didn't. This mirrors the "resilient order-processing... core transactions remain successful when secondary notification operations fail" pattern from my production experience (see CV, "Selected Platform & Logistics-Relevant Work").

## 5. Consumer side (`dispatch-worker`)

The full loop lives in `services/dispatch-worker/src/main.rs`:

1. `run_poll_loop` long-polls for up to 10 messages at a time.
2. Each message is handed to `handle_message` inside a `tokio::spawn`, gated by a `tokio::sync::Semaphore` permit (`Config::max_in_flight`, default 20) — this is the backpressure valve: a burst of 10 received messages doesn't mean 10 simultaneous DB transactions if the semaphore is already near its limit from the previous batch. Without this bound, a traffic spike turns into unbounded concurrent Postgres connections at exactly the moment the database is least able to absorb them.
3. `handle_message` deserializes the body, then delegates to `matching::assign_order` (the transaction described in `docs/SQS_DESIGN.md` §6 below), and only calls `delete_message` — SQS's acknowledgment — once that transaction has either succeeded or determined the message doesn't need retrying (see §6).
4. `handle_message`'s tracing span is attached via `.instrument()`, not `span.enter()` — holding an entered span guard across an `.await` is unsound on Tokio's multi-threaded runtime (the guard isn't `Send`), a real bug that was caught during review and is called out inline in the code as a teaching example, not just fixed silently.

## 6. Idempotency: designing for at-least-once, not hoping for exactly-once

SQS guarantees each message is delivered **at least once** — under normal conditions usually once, but duplicate delivery is a documented, expected occurrence (most commonly: the consumer successfully processes a message and calls `delete_message`, but the delete call itself is lost to a network blip before SQS receives it — from SQS's perspective, indistinguishable from the consumer never finishing). Two designs were rejected before landing on the one in this repo:

- **Rejected: trust that duplicates are rare enough to ignore.** They aren't rare enough for a system that assigns physical drivers to physical orders — a duplicate assignment is a real-world dispatch error, not a log line.
- **Rejected: a separate "processed message IDs" dedup table.** Works, but adds a table, an index, and a cleanup/TTL policy purely to solve a problem the domain model can already solve for free.

**What's implemented:** the claim itself is the idempotency check. `services/dispatch-worker/src/db.rs::claim_order_for_assignment` runs:

```sql
UPDATE orders SET status = 'assigned' WHERE id = $1 AND status = 'pending'
```

and `matching::assign_order` checks `rows_affected() == 1`. A duplicate delivery of the same `OrderCreated` message finds the order already `assigned` (or `cancelled`), the UPDATE affects zero rows, and the handler treats that as `AssignOutcome::AlreadyHandled` — the message is deleted (acknowledged) without any further side effect. No dedup table, no message-ID tracking; the business state itself is the idempotency key. The same principle is applied one hop further downstream in `dispatch-notify-lambda::audit::write_audit_record`, which writes to a fixed S3 key derived from `assignment_id` — a duplicate EventBridge delivery overwrites the same object with identical content rather than creating a duplicate audit record.

## 7. Concurrency safety for the matching step itself

Idempotency handles *duplicate messages*; it doesn't by itself handle *two different orders' messages being processed concurrently and racing over the same driver*. That's what `SELECT ... FOR UPDATE SKIP LOCKED` in `db.rs::available_drivers_for_update` is for: run inside the same transaction as the claim, it locks the driver rows it reads, and a second concurrent transaction selecting from the same candidate set simply skips any row already locked by the first — it sees the next-nearest available driver instead of blocking on the lock. Two orders being matched at the same moment therefore can't both be assigned the same driver, without either transaction ever waiting on the other.

## 8. Testing this locally

`docker-compose.yml` + `infra/localstack/init-aws.sh` provision the real queue/DLQ pair against LocalStack, so the entire flow described above — including redelivery after a failed match and DLQ routing after 5 attempts — is exercisable with zero AWS account:

```bash
docker compose up --build
./scripts/seed.sh 0                     # zero drivers on purpose
curl -X POST localhost:8080/orders -H 'Content-Type: application/json' \
  -d '{"pickup":{"lat":52.52,"lon":13.405},"dropoff":{"lat":52.50,"lon":13.38}}'

# watch dispatch-worker retry every ~30s (the visibility timeout) as no driver is ever found
docker compose logs -f dispatch-worker

# after 5 attempts, inspect the DLQ directly:
aws --endpoint-url http://localhost:4566 sqs receive-message \
  --queue-url http://localhost:4566/000000000000/order-created-dlq
```

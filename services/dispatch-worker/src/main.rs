mod config;
mod db;
mod eventbridge;
mod matching;
mod metrics;

use std::sync::Arc;

use aws_sdk_eventbridge::Client as EventBridgeClient;
use aws_sdk_sqs::Client as SqsClient;
use chrono::Utc;
use dispatch_core::OrderCreated;
use sqlx::PgPool;
use tokio::sync::Semaphore;
use tracing::Instrument;
use tracing_subscriber::{fmt, layer::SubscriberExt, util::SubscriberInitExt, EnvFilter};

use crate::config::Config;
use crate::eventbridge::DispatchEventPublisher;
use crate::matching::AssignOutcome;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    dotenvy::dotenv().ok();
    init_telemetry();

    let cfg = Config::from_env()?;
    tracing::info!(?cfg, "starting dispatch-worker");

    let pool = db::connect(&cfg).await?;
    let aws_cfg = aws_config::load_defaults(aws_config::BehaviorVersion::latest()).await;
    let sqs = SqsClient::new(&aws_cfg);
    let publisher =
        DispatchEventPublisher::new(EventBridgeClient::new(&aws_cfg), cfg.event_bus_name.clone());

    // Bounds how many order-assignment transactions run concurrently across
    // the whole worker process — see Config::max_in_flight for the
    // backpressure rationale.
    let semaphore = Arc::new(Semaphore::new(cfg.max_in_flight));

    run_poll_loop(sqs, pool, publisher, cfg, semaphore).await
}

async fn run_poll_loop(
    sqs: SqsClient,
    pool: PgPool,
    publisher: DispatchEventPublisher,
    cfg: Config,
    semaphore: Arc<Semaphore>,
) -> anyhow::Result<()> {
    loop {
        // Long polling (wait_time_seconds = 20, the SQS maximum) means an
        // idle worker makes roughly 3 API calls/minute instead of hammering
        // SQS with short-polling — the cheap, obvious win for both cost and
        // tail latency variance under low traffic.
        let received = sqs
            .receive_message()
            .queue_url(&cfg.sqs_queue_url)
            .max_number_of_messages(10)
            .wait_time_seconds(20)
            .visibility_timeout(30)
            .send()
            .await;

        let messages = match received {
            Ok(output) => output.messages.unwrap_or_default(),
            Err(err) => {
                tracing::error!(error = %err, "sqs receive_message failed, backing off");
                tokio::time::sleep(std::time::Duration::from_secs(2)).await;
                continue;
            }
        };

        for message in messages {
            let sqs = sqs.clone();
            let pool = pool.clone();
            let publisher = publisher.clone();
            let cfg = cfg.clone();
            let permit = semaphore.clone().acquire_owned().await?;

            tokio::spawn(async move {
                let _permit = permit; // held for the duration of this task
                if let Err(err) = handle_message(&sqs, &pool, &publisher, &cfg, &message).await {
                    tracing::error!(error = %err, "failed to process message");
                }
            });
        }
    }
}

async fn handle_message(
    sqs: &SqsClient,
    pool: &PgPool,
    publisher: &DispatchEventPublisher,
    cfg: &Config,
    message: &aws_sdk_sqs::types::Message,
) -> anyhow::Result<()> {
    let Some(body) = message.body.as_deref() else {
        tracing::warn!("received message with no body, deleting");
        delete_message(sqs, cfg, message).await?;
        return Ok(());
    };

    let event: OrderCreated = serde_json::from_str(body)?;

    // NB: an entered `Span` guard must never be held across an `.await` —
    // it's not `Send`, and holding it would silently corrupt span nesting
    // the moment the executor moves this task between threads (which the
    // multi-threaded Tokio runtime does routinely). `.instrument()` attaches
    // the span to the *future* itself instead, so it enters/exits correctly
    // around every poll no matter which worker thread runs it.
    let span = tracing::info_span!("handle_order_created", order_id = %event.order_id);

    async move {
        let outcome =
            matching::assign_order(pool, event.order_id, event.pickup, cfg.match_radius_km).await?;

        // Measured from when dispatch-api accepted the order, not from when
        // this worker received the SQS message — that's the number a
        // customer-facing SLA actually cares about ("how long since I
        // placed the order"), and it's also what makes a *failed* attempt's
        // metric meaningful: it reads as "still waiting after Nms," which
        // is exactly what you'd want next to the queue-backlog alarm on a
        // dashboard.
        let time_since_created_ms = (Utc::now() - event.created_at).num_milliseconds().max(0) as f64;

        match outcome {
            AssignOutcome::Assigned(assigned) => {
                tracing::info!(driver_id = %assigned.driver_id, distance_km = assigned.distance_km, "order assigned");
                metrics::emit_match_outcome(&cfg.environment, "assigned", time_since_created_ms);
                publisher.publish(&assigned).await?;
                delete_message(sqs, cfg, message).await?;
            }
            AssignOutcome::AlreadyHandled => {
                tracing::debug!("order already handled, acknowledging duplicate delivery");
                metrics::emit_match_outcome(&cfg.environment, "already_handled", time_since_created_ms);
                delete_message(sqs, cfg, message).await?;
            }
            AssignOutcome::NoDriverAvailable => {
                tracing::warn!(radius_km = cfg.match_radius_km, "no driver in range, leaving message for retry");
                metrics::emit_match_outcome(&cfg.environment, "no_driver_available", time_since_created_ms);
                // Deliberately not deleted: SQS will redeliver after the
                // visibility timeout so this order gets another matching
                // attempt once a driver frees up or moves into range.
            }
        }

        Ok(())
    }
    .instrument(span)
    .await
}

async fn delete_message(
    sqs: &SqsClient,
    cfg: &Config,
    message: &aws_sdk_sqs::types::Message,
) -> anyhow::Result<()> {
    if let Some(receipt_handle) = &message.receipt_handle {
        sqs.delete_message()
            .queue_url(&cfg.sqs_queue_url)
            .receipt_handle(receipt_handle)
            .send()
            .await?;
    }
    Ok(())
}

fn init_telemetry() {
    let filter = EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info"));
    tracing_subscriber::registry()
        .with(filter)
        .with(fmt::layer().json().with_target(true))
        .init();
}

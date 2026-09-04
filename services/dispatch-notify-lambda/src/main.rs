//! `dispatch-notify-lambda` — the EventBridge-triggered edge of the system.
//!
//! This is deployed as a Rust custom-runtime Lambda (binary named
//! `bootstrap`, packaged for the `provided.al2023` runtime — see
//! `infra/terraform/lambda.tf`). An EventBridge rule matches on
//! `source = "velocity.dispatch"` / `detail-type = "DispatchAssigned"` and
//! invokes this function directly, with no polling, no queue to manage on
//! this side, and near-instant (typically sub-second, cold start aside)
//! delivery from "driver matched" to "rider notified".
//!
//! Two things worth calling out for an interview: (1) Rust Lambdas on
//! `provided.al2` cold-start meaningfully faster than interpreted-runtime
//! Lambdas (no VM/interpreter bootstrap, small static binary) — that matters
//! here because this is on the critical path from assignment to
//! notification; (2) the handler is deliberately idempotent-safe by design
//! (writing the audit record is a plain overwrite keyed by `assignment_id`),
//! because EventBridge, like SQS, offers at-least-once delivery.

use aws_lambda_events::event::eventbridge::EventBridgeEvent;
use dispatch_core::DispatchAssigned;
use lambda_runtime::{service_fn, Error, LambdaEvent};
use serde_json::{json, Value};

mod audit;
mod notify;

#[tokio::main]
async fn main() -> Result<(), Error> {
    tracing_subscriber::fmt()
        .json()
        .with_max_level(tracing::Level::INFO)
        .without_time() // Lambda's platform logs already timestamp each line
        .init();

    let aws_cfg = aws_config::load_defaults(aws_config::BehaviorVersion::latest()).await;
    let s3_client = aws_sdk_s3::Client::new(&aws_cfg);
    let sns_client = aws_sdk_sns::Client::new(&aws_cfg);

    let audit_bucket = std::env::var("AUDIT_BUCKET").ok();
    let notify_topic_arn = std::env::var("NOTIFY_TOPIC_ARN").ok();

    let handler = move |event: LambdaEvent<EventBridgeEvent<DispatchAssigned>>| {
        let s3_client = s3_client.clone();
        let sns_client = sns_client.clone();
        let audit_bucket = audit_bucket.clone();
        let notify_topic_arn = notify_topic_arn.clone();
        async move { handle_event(event, s3_client, sns_client, audit_bucket, notify_topic_arn).await }
    };

    lambda_runtime::run(service_fn(handler)).await
}

async fn handle_event(
    event: LambdaEvent<EventBridgeEvent<DispatchAssigned>>,
    s3_client: aws_sdk_s3::Client,
    sns_client: aws_sdk_sns::Client,
    audit_bucket: Option<String>,
    notify_topic_arn: Option<String>,
) -> Result<Value, Error> {
    let assigned = event.payload.detail;

    tracing::info!(
        assignment_id = %assigned.assignment_id,
        order_id = %assigned.order_id,
        driver_id = %assigned.driver_id,
        distance_km = assigned.distance_km,
        "processing DispatchAssigned event"
    );

    notify::send_assignment_notification(&sns_client, notify_topic_arn.as_deref(), &assigned)
        .await?;
    audit::write_audit_record(&s3_client, audit_bucket.as_deref(), &assigned).await?;

    Ok(json!({ "assignmentId": assigned.assignment_id, "status": "processed" }))
}

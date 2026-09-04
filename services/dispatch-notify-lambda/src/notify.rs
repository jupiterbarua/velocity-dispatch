use dispatch_core::DispatchAssigned;
use lambda_runtime::Error;

/// Sends the "you've been matched" notification. In this portfolio build
/// that's an SNS publish (which could fan out to SMS/email/push subscribers
/// without any code change here) — in production this is the seam where
/// you'd swap in a dedicated notification provider (e.g. Firebase, Twilio)
/// behind the same function signature.
pub async fn send_assignment_notification(
    client: &aws_sdk_sns::Client,
    topic_arn: Option<&str>,
    assigned: &DispatchAssigned,
) -> Result<(), Error> {
    let Some(topic_arn) = topic_arn else {
        tracing::info!(assignment_id = %assigned.assignment_id, "NOTIFY_TOPIC_ARN not set, skipping SNS publish (local/dev mode)");
        return Ok(());
    };

    let message = serde_json::json!({
        "assignmentId": assigned.assignment_id,
        "orderId": assigned.order_id,
        "driverId": assigned.driver_id,
        "distanceKm": assigned.distance_km,
    })
    .to_string();

    client
        .publish()
        .topic_arn(topic_arn)
        .message(message)
        .subject("Driver assigned to your order")
        .send()
        .await?;

    Ok(())
}

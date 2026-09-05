use aws_sdk_s3::primitives::ByteStream;
use dispatch_core::DispatchAssigned;
use lambda_runtime::Error;

/// Writes an immutable audit record for the assignment to S3, keyed by
/// `assignment_id` so a duplicate EventBridge delivery (at-least-once,
/// same as SQS) just overwrites the same key with identical content instead
/// of creating a duplicate record — cheap idempotency without a dedup table.
pub async fn write_audit_record(
    client: &aws_sdk_s3::Client,
    bucket: Option<&str>,
    assigned: &DispatchAssigned,
) -> Result<(), Error> {
    let Some(bucket) = bucket else {
        tracing::info!(assignment_id = %assigned.assignment_id, "AUDIT_BUCKET not set, skipping S3 write (local/dev mode)");
        return Ok(());
    };

    let key = format!("assignments/{}/{}.json", assigned.order_id, assigned.assignment_id);
    let body = serde_json::to_vec_pretty(assigned)?;

    client
        .put_object()
        .bucket(bucket)
        .key(&key)
        .content_type("application/json")
        .body(ByteStream::from(body))
        .send()
        .await?;

    tracing::info!(bucket, key, "wrote audit record");
    Ok(())
}

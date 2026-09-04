use aws_sdk_sqs::Client as SqsClient;
use dispatch_core::OrderCreated;

/// Thin wrapper around the SQS client so handlers depend on this narrow
/// interface rather than the full AWS SDK surface — makes it trivial to
/// swap in a fake for handler unit tests later without pulling in
/// LocalStack.
#[derive(Clone)]
pub struct OrderEventPublisher {
    client: SqsClient,
    queue_url: String,
}

impl OrderEventPublisher {
    pub fn new(client: SqsClient, queue_url: String) -> Self {
        Self { client, queue_url }
    }

    pub async fn publish(
        &self,
        event: &OrderCreated,
    ) -> Result<
        (),
        aws_sdk_sqs::error::SdkError<aws_sdk_sqs::operation::send_message::SendMessageError>,
    > {
        let body = serde_json::to_string(event).expect("OrderCreated is always serializable");

        self.client
            .send_message()
            .queue_url(&self.queue_url)
            .message_body(body)
            .message_attributes(
                "event_type",
                aws_sdk_sqs::types::MessageAttributeValue::builder()
                    .data_type("String")
                    .string_value(OrderCreated::SQS_MESSAGE_TYPE)
                    .build()
                    .expect("static attribute is always valid"),
            )
            .send()
            .await?;

        Ok(())
    }
}

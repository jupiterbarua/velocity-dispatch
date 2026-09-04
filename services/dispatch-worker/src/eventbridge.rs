use aws_sdk_eventbridge::types::PutEventsRequestEntry;
use aws_sdk_eventbridge::Client as EventBridgeClient;
use dispatch_core::DispatchAssigned;

#[derive(Clone)]
pub struct DispatchEventPublisher {
    client: EventBridgeClient,
    bus_name: String,
}

impl DispatchEventPublisher {
    pub fn new(client: EventBridgeClient, bus_name: String) -> Self {
        Self { client, bus_name }
    }

    /// Fan-out point: anything downstream (notification Lambda today,
    /// billing/analytics tomorrow) subscribes to this bus via its own
    /// EventBridge rule. The worker publishes once and does not know or
    /// care who's listening — that decoupling is the entire point of using
    /// an event bus instead of the worker calling those services directly.
    pub async fn publish(&self, event: &DispatchAssigned) -> anyhow::Result<()> {
        let detail = serde_json::to_string(event)?;

        let entry = PutEventsRequestEntry::builder()
            .source(DispatchAssigned::SOURCE)
            .detail_type(DispatchAssigned::DETAIL_TYPE)
            .detail(detail)
            .event_bus_name(&self.bus_name)
            .build();

        let output = self.client.put_events().entries(entry).send().await?;

        if output.failed_entry_count() > 0 {
            anyhow::bail!(
                "eventbridge rejected {} of 1 entries: {:?}",
                output.failed_entry_count(),
                output.entries()
            );
        }

        Ok(())
    }
}

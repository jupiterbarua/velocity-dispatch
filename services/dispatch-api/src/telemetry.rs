use tracing_subscriber::{fmt, layer::SubscriberExt, util::SubscriberInitExt, EnvFilter};

/// Structured JSON logging, controlled by `RUST_LOG` (defaults to `info`).
/// JSON output is what lets this be shipped straight into CloudWatch Logs
/// Insights / any log aggregator without a separate parsing step — a small
/// decision that pays for itself the first time you're grepping production
/// incidents at 2am.
pub fn init() {
    let filter = EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info"));

    tracing_subscriber::registry()
        .with(filter)
        .with(
            fmt::layer()
                .json()
                .with_target(true)
                .with_current_span(true),
        )
        .init();
}

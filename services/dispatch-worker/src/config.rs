use std::env;

#[derive(Debug, Clone)]
pub struct Config {
    pub database_url: String,
    pub sqs_queue_url: String,
    pub event_bus_name: String,
    pub db_max_connections: u32,
    pub match_radius_km: u32,
    pub max_in_flight: usize,
    /// Dimension value on every emitted metric (see `metrics.rs`) — lets
    /// CloudWatch queries and the dashboard split `dev`/`staging`/`prod`
    /// even though they'd otherwise share the same namespace/metric names.
    pub environment: String,
}

impl Config {
    pub fn from_env() -> anyhow::Result<Self> {
        Ok(Self {
            database_url: env::var("DATABASE_URL")
                .unwrap_or_else(|_| "postgres://dispatch:dispatch@localhost:5432/dispatch".into()),
            sqs_queue_url: env::var("SQS_ORDER_QUEUE_URL")
                .unwrap_or_else(|_| "http://localhost:4566/000000000000/order-created".into()),
            event_bus_name: env::var("EVENT_BUS_NAME")
                .unwrap_or_else(|_| "velocity-dispatch-bus".into()),
            db_max_connections: env::var("DB_MAX_CONNECTIONS")
                .ok()
                .and_then(|v| v.parse().ok())
                .unwrap_or(10),
            match_radius_km: env::var("MATCH_RADIUS_KM")
                .ok()
                .and_then(|v| v.parse().ok())
                .unwrap_or(15),
            // Bounds how many SQS messages this worker processes concurrently.
            // Unbounded concurrency here would let a burst of orders open an
            // unbounded number of simultaneous DB transactions — this is the
            // backpressure valve that keeps the worker's resource usage
            // predictable under load instead of falling over exactly when
            // it matters most.
            max_in_flight: env::var("MAX_IN_FLIGHT")
                .ok()
                .and_then(|v| v.parse().ok())
                .unwrap_or(20),
            environment: env::var("ENVIRONMENT").unwrap_or_else(|_| "local".into()),
        })
    }
}

use std::env;

/// All runtime configuration in one place, read once at startup. Nothing in
/// the rest of the service reaches into `std::env` directly — that keeps the
/// handlers testable and makes "what does this service need to run" a single
/// grep-able struct instead of scattered `env::var` calls.
#[derive(Debug, Clone)]
pub struct Config {
    pub database_url: String,
    pub sqs_queue_url: String,
    pub bind_addr: String,
    pub db_max_connections: u32,
}

impl Config {
    pub fn from_env() -> anyhow::Result<Self> {
        Ok(Self {
            database_url: env::var("DATABASE_URL")
                .unwrap_or_else(|_| "postgres://dispatch:dispatch@localhost:5432/dispatch".into()),
            sqs_queue_url: env::var("SQS_ORDER_QUEUE_URL")
                .unwrap_or_else(|_| "http://localhost:4566/000000000000/order-created".into()),
            bind_addr: env::var("BIND_ADDR").unwrap_or_else(|_| "0.0.0.0:8080".into()),
            db_max_connections: env::var("DB_MAX_CONNECTIONS")
                .ok()
                .and_then(|v| v.parse().ok())
                .unwrap_or(20),
        })
    }
}

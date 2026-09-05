mod config;
mod db;
mod error;
mod routes;
mod sqs;
mod state;
mod telemetry;

use actix_cors::Cors;
use actix_web::{web, App, HttpServer};
use aws_sdk_sqs::Client as SqsClient;

use crate::config::Config;
use crate::state::AppState;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    dotenvy::dotenv().ok();
    telemetry::init();

    let cfg = Config::from_env()?;
    tracing::info!(bind_addr = %cfg.bind_addr, "starting dispatch-api");

    let pool = db::connect(&cfg).await?;

    let aws_cfg = aws_config::load_defaults(aws_config::BehaviorVersion::latest()).await;
    let sqs_client = SqsClient::new(&aws_cfg);
    let publisher = sqs::OrderEventPublisher::new(sqs_client, cfg.sqs_queue_url.clone());

    let state = web::Data::new(AppState { pool, publisher });
    let bind_addr = cfg.bind_addr.clone();

    HttpServer::new(move || {
        App::new()
            .app_data(state.clone())
            .wrap(tracing_actix_web::TracingLogger::default())
            .wrap(Cors::permissive())
            .configure(routes::configure)
    })
    // Worker count tuned to available cores rather than a hardcoded number —
    // Actix spins up one set of app instances per worker thread, each with
    // its own Tokio runtime, so this is the primary horizontal knob for
    // throughput on a single container before you scale out replicas.
    .workers(num_cpus())
    .bind(&bind_addr)?
    .run()
    .await?;

    Ok(())
}

fn num_cpus() -> usize {
    std::thread::available_parallelism().map(|n| n.get()).unwrap_or(4)
}

use sqlx::PgPool;

use crate::sqs::OrderEventPublisher;

#[derive(Clone)]
pub struct AppState {
    pub pool: PgPool,
    pub publisher: OrderEventPublisher,
}

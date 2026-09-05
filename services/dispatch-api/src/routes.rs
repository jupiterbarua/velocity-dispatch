use actix_web::{get, post, web, HttpResponse};
use chrono::Utc;
use dispatch_core::{DriverStatus, GeoPoint, Order, OrderCreated, OrderStatus};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::error::ApiError;
use crate::state::AppState;

/// A readiness check, not just a liveness ping: it actually queries
/// Postgres through the same pool every other handler uses. An Actix worker
/// thread being alive and able to answer HTTP doesn't mean this instance
/// can do anything useful if its database connection is broken — reporting
/// healthy in that state would keep the ALB sending it real traffic it can
/// only fail. The 2s timeout matters just as much as the check itself: a
/// hung database must make this probe fail fast, not hang forever and get
/// treated as "still starting up" by ECS.
#[get("/health")]
pub async fn health(state: web::Data<AppState>) -> HttpResponse {
    let check = tokio::time::timeout(
        std::time::Duration::from_secs(2),
        crate::db::health_check(&state.pool),
    )
    .await;

    match check {
        Ok(Ok(())) => HttpResponse::Ok().json(serde_json::json!({"status": "ok"})),
        Ok(Err(err)) => {
            tracing::error!(error = %err, "health check failed: database query error");
            HttpResponse::ServiceUnavailable()
                .json(serde_json::json!({"status": "unhealthy", "reason": "database unreachable"}))
        }
        Err(_timeout) => {
            tracing::error!("health check failed: database check timed out after 2s");
            HttpResponse::ServiceUnavailable()
                .json(serde_json::json!({"status": "unhealthy", "reason": "database timeout"}))
        }
    }
}

#[derive(Deserialize)]
pub struct CreateOrderRequest {
    pickup: PointDto,
    dropoff: PointDto,
}

#[derive(Deserialize)]
pub struct PointDto {
    lat: f64,
    lon: f64,
}

#[derive(Serialize)]
pub struct OrderResponse {
    id: Uuid,
    status: OrderStatus,
    created_at: chrono::DateTime<Utc>,
}

impl From<Order> for OrderResponse {
    fn from(o: Order) -> Self {
        Self { id: o.id, status: o.status, created_at: o.created_at }
    }
}

/// `POST /orders` — the hot path of this service.
///
/// On the happy path this does exactly two I/O calls: one INSERT and one
/// SQS `SendMessage`, both awaited concurrently-safe but sequential here
/// because the SQS publish should only happen once the order is durably
/// persisted (never publish an event for something that might not exist on
/// retry/read). The actual driver-matching work is intentionally NOT done
/// inline — it's handed off to `dispatch-worker` asynchronously so this
/// endpoint's response latency stays flat regardless of how expensive
/// matching gets under load. That handoff is the core low-latency decision
/// in this service; see the README for the full rationale.
#[post("/orders")]
pub async fn create_order(
    state: web::Data<AppState>,
    body: web::Json<CreateOrderRequest>,
) -> Result<HttpResponse, ApiError> {
    let pickup = GeoPoint::new(body.pickup.lat, body.pickup.lon)?;
    let dropoff = GeoPoint::new(body.dropoff.lat, body.dropoff.lon)?;

    let order = Order {
        id: Uuid::new_v4(),
        pickup,
        dropoff,
        status: OrderStatus::Pending,
        created_at: Utc::now(),
    };

    crate::db::insert_order(&state.pool, &order).await?;

    let event = OrderCreated {
        order_id: order.id,
        pickup: order.pickup,
        dropoff: order.dropoff,
        created_at: order.created_at,
    };

    if let Err(err) = state.publisher.publish(&event).await {
        // The order is already durably stored — a failed publish here is
        // recoverable (a periodic reconciliation job or DLQ redrive can
        // catch it) and must never surface as a failed order creation to
        // the caller. Fail loudly in logs/metrics instead of failing the
        // request. This mirrors the "resilient order-processing" pattern
        // from production experience: core transaction succeeds even if a
        // secondary operation fails.
        tracing::error!(order_id = %order.id, error = %err, "failed to publish OrderCreated event");
    }

    Ok(HttpResponse::Created().json(OrderResponse::from(order)))
}

#[get("/orders/{id}")]
pub async fn get_order(
    state: web::Data<AppState>,
    path: web::Path<Uuid>,
) -> Result<HttpResponse, ApiError> {
    let order = crate::db::get_order(&state.pool, path.into_inner())
        .await?
        .ok_or(ApiError::NotFound)?;
    Ok(HttpResponse::Ok().json(OrderResponse::from(order)))
}

#[derive(Deserialize)]
pub struct RegisterDriverRequest {
    id: Option<Uuid>,
    name: String,
    location: PointDto,
}

#[post("/drivers")]
pub async fn register_driver(
    state: web::Data<AppState>,
    body: web::Json<RegisterDriverRequest>,
) -> Result<HttpResponse, ApiError> {
    let location = GeoPoint::new(body.location.lat, body.location.lon)?;
    let id = body.id.unwrap_or_else(Uuid::new_v4);
    let driver = crate::db::upsert_driver(&state.pool, id, &body.name, location, DriverStatus::Available).await?;
    Ok(HttpResponse::Created().json(driver))
}

#[derive(Deserialize)]
pub struct UpdateLocationRequest {
    location: PointDto,
    status: Option<String>,
}

#[post("/drivers/{id}/location")]
pub async fn update_driver_location(
    state: web::Data<AppState>,
    path: web::Path<Uuid>,
    body: web::Json<UpdateLocationRequest>,
) -> Result<HttpResponse, ApiError> {
    let location = GeoPoint::new(body.location.lat, body.location.lon)?;
    let status = match body.status.as_deref() {
        Some("busy") => DriverStatus::Busy,
        Some("offline") => DriverStatus::Offline,
        _ => DriverStatus::Available,
    };
    let driver = crate::db::upsert_driver(&state.pool, path.into_inner(), "", location, status).await?;
    Ok(HttpResponse::Ok().json(driver))
}

#[get("/drivers")]
pub async fn list_drivers(state: web::Data<AppState>) -> Result<HttpResponse, ApiError> {
    let drivers = crate::db::list_available_drivers(&state.pool).await?;
    Ok(HttpResponse::Ok().json(drivers))
}

pub fn configure(cfg: &mut web::ServiceConfig) {
    cfg.service(health)
        .service(create_order)
        .service(get_order)
        .service(register_driver)
        .service(update_driver_location)
        .service(list_drivers);
}

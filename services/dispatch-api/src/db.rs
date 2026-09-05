use chrono::{DateTime, Utc};
use dispatch_core::{Driver, DriverStatus, GeoPoint, Order, OrderStatus};
use sqlx::{postgres::PgPoolOptions, FromRow, PgPool};
use uuid::Uuid;

use crate::config::Config;

pub async fn connect(cfg: &Config) -> anyhow::Result<PgPool> {
    let pool = PgPoolOptions::new()
        // Sized deliberately: enough headroom to survive a burst without the
        // handler blocking on `acquire()`, but bounded so we never let a
        // slow downstream (Postgres under load) turn into an unbounded
        // memory/connection leak upstream. This is the single biggest lever
        // for tail latency in a service like this — see README "Low latency
        // decisions".
        .max_connections(cfg.db_max_connections)
        .acquire_timeout(std::time::Duration::from_secs(3))
        .connect(&cfg.database_url)
        .await?;

    sqlx::migrate!("../../migrations").run(&pool).await?;
    Ok(pool)
}

/// Backs `GET /health`. A container that's up but can't reach Postgres is
/// worse than a container that's simply down — the ALB/ECS would keep
/// routing real traffic to it instead of failing over — so this is a
/// genuine dependency check (`SELECT 1` against the pool), not just "the
/// process is alive." Callers are expected to wrap this in a short timeout
/// (see `routes::health`) so a hung database makes the health check *fail
/// fast*, not hang the very probe that's supposed to catch that.
pub async fn health_check(pool: &PgPool) -> sqlx::Result<()> {
    sqlx::query("SELECT 1").execute(pool).await?;
    Ok(())
}

#[derive(FromRow)]
struct OrderRow {
    id: Uuid,
    pickup_lat: f64,
    pickup_lon: f64,
    dropoff_lat: f64,
    dropoff_lon: f64,
    status: String,
    created_at: DateTime<Utc>,
}

impl From<OrderRow> for Order {
    fn from(r: OrderRow) -> Self {
        Order {
            id: r.id,
            pickup: GeoPoint {
                lat: r.pickup_lat,
                lon: r.pickup_lon,
            },
            dropoff: GeoPoint {
                lat: r.dropoff_lat,
                lon: r.dropoff_lon,
            },
            status: parse_order_status(&r.status),
            created_at: r.created_at,
        }
    }
}

fn parse_order_status(s: &str) -> OrderStatus {
    match s {
        "assigned" => OrderStatus::Assigned,
        "picked_up" => OrderStatus::PickedUp,
        "delivered" => OrderStatus::Delivered,
        "cancelled" => OrderStatus::Cancelled,
        _ => OrderStatus::Pending,
    }
}

pub async fn insert_order(pool: &PgPool, order: &Order) -> sqlx::Result<()> {
    sqlx::query(
        r#"
        INSERT INTO orders (id, pickup_lat, pickup_lon, dropoff_lat, dropoff_lon, status, created_at)
        VALUES ($1, $2, $3, $4, $5, $6, $7)
        "#,
    )
    .bind(order.id)
    .bind(order.pickup.lat)
    .bind(order.pickup.lon)
    .bind(order.dropoff.lat)
    .bind(order.dropoff.lon)
    .bind("pending")
    .bind(order.created_at)
    .execute(pool)
    .await?;
    Ok(())
}

pub async fn get_order(pool: &PgPool, id: Uuid) -> sqlx::Result<Option<Order>> {
    let row = sqlx::query_as::<_, OrderRow>(
        r#"SELECT id, pickup_lat, pickup_lon, dropoff_lat, dropoff_lon, status, created_at
           FROM orders WHERE id = $1"#,
    )
    .bind(id)
    .fetch_optional(pool)
    .await?;
    Ok(row.map(Into::into))
}

#[derive(FromRow)]
struct DriverRow {
    id: Uuid,
    name: String,
    lat: f64,
    lon: f64,
    status: String,
    updated_at: DateTime<Utc>,
}

impl From<DriverRow> for Driver {
    fn from(r: DriverRow) -> Self {
        Driver {
            id: r.id,
            name: r.name,
            location: GeoPoint {
                lat: r.lat,
                lon: r.lon,
            },
            status: match r.status.as_str() {
                "busy" => DriverStatus::Busy,
                "offline" => DriverStatus::Offline,
                _ => DriverStatus::Available,
            },
            updated_at: r.updated_at,
        }
    }
}

pub async fn upsert_driver(
    pool: &PgPool,
    id: Uuid,
    name: &str,
    location: GeoPoint,
    status: DriverStatus,
) -> sqlx::Result<Driver> {
    let status_str = match status {
        DriverStatus::Available => "available",
        DriverStatus::Busy => "busy",
        DriverStatus::Offline => "offline",
    };
    let row = sqlx::query_as::<_, DriverRow>(
        r#"
        INSERT INTO drivers (id, name, lat, lon, status, updated_at)
        VALUES ($1, $2, $3, $4, $5, now())
        ON CONFLICT (id) DO UPDATE
          SET lat = EXCLUDED.lat, lon = EXCLUDED.lon, status = EXCLUDED.status, updated_at = now()
        RETURNING id, name, lat, lon, status, updated_at
        "#,
    )
    .bind(id)
    .bind(name)
    .bind(location.lat)
    .bind(location.lon)
    .bind(status_str)
    .fetch_one(pool)
    .await?;
    Ok(row.into())
}

pub async fn list_available_drivers(pool: &PgPool) -> sqlx::Result<Vec<Driver>> {
    let rows = sqlx::query_as::<_, DriverRow>(
        r#"SELECT id, name, lat, lon, status, updated_at FROM drivers WHERE status = 'available'"#,
    )
    .fetch_all(pool)
    .await?;
    Ok(rows.into_iter().map(Into::into).collect())
}

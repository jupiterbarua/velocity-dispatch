use chrono::Utc;
use dispatch_core::{Driver, DriverStatus, GeoPoint};
use sqlx::{postgres::PgPoolOptions, FromRow, PgPool, Postgres, Transaction};
use uuid::Uuid;

use crate::config::Config;

pub async fn connect(cfg: &Config) -> anyhow::Result<PgPool> {
    let pool = PgPoolOptions::new()
        .max_connections(cfg.db_max_connections)
        .acquire_timeout(std::time::Duration::from_secs(3))
        .connect(&cfg.database_url)
        .await?;

    // The worker runs the same migrations dispatch-api runs — deliberately,
    // not redundantly. Each service owning its own schema readiness is what
    // makes "producer and consumer are independent services" true at
    // startup, not just at the network level: dispatch-worker can come up
    // first, dispatch-api can come up first, or both can race to start at
    // the same instant, and none of those orderings requires either one to
    // wait on the other. That's safe specifically because sqlx's migrator
    // takes a Postgres advisory lock (`pg_advisory_lock`) for the duration
    // of applying migrations — if two processes call `migrate!` at the same
    // moment, one applies them while the other blocks, then the second sees
    // nothing left to do and returns immediately. Running `migrate!` from
    // multiple services isn't a race to avoid, it's the pattern that
    // removes the race that a single designated "migration owner" would
    // otherwise create (a hard startup-order dependency between services
    // that otherwise have no reason to know about each other).
    sqlx::migrate!("../../migrations").run(&pool).await?;

    Ok(pool)
}

/// Returns `true` if the order was still `pending` and has now been marked
/// `assigned` in the same statement — this doubles as the idempotency check.
/// SQS's at-least-once delivery means the same `OrderCreated` message can
/// arrive twice; this UPDATE ... WHERE status = 'pending' makes a duplicate
/// delivery a safe no-op instead of a duplicate assignment.
pub async fn claim_order_for_assignment(
    tx: &mut Transaction<'_, Postgres>,
    order_id: Uuid,
) -> sqlx::Result<bool> {
    let result = sqlx::query(
        r#"UPDATE orders SET status = 'assigned' WHERE id = $1 AND status = 'pending'"#,
    )
    .bind(order_id)
    .execute(&mut **tx)
    .await?;
    Ok(result.rows_affected() == 1)
}

#[derive(FromRow)]
struct DriverRow {
    id: Uuid,
    name: String,
    lat: f64,
    lon: f64,
}

/// Locks candidate rows with `FOR UPDATE SKIP LOCKED` *inside the caller's
/// transaction* so that two workers racing on two different orders never
/// both select the same driver — the loser simply skips the locked row and
/// sees the next-nearest candidate instead of blocking. This is the same
/// pattern used for building safe job queues directly on Postgres.
pub async fn available_drivers_for_update(
    tx: &mut Transaction<'_, Postgres>,
) -> sqlx::Result<Vec<Driver>> {
    let rows = sqlx::query_as::<_, DriverRow>(
        r#"SELECT id, name, lat, lon FROM drivers WHERE status = 'available' FOR UPDATE SKIP LOCKED"#,
    )
    .fetch_all(&mut **tx)
    .await?;

    Ok(rows
        .into_iter()
        .map(|r| Driver {
            id: r.id,
            name: r.name,
            location: GeoPoint { lat: r.lat, lon: r.lon },
            status: DriverStatus::Available,
            updated_at: Utc::now(),
        })
        .collect())
}

pub async fn record_assignment(
    tx: &mut Transaction<'_, Postgres>,
    order_id: Uuid,
    driver_id: Uuid,
    distance_km: f64,
) -> sqlx::Result<Uuid> {
    let assignment_id = Uuid::new_v4();
    sqlx::query(
        r#"INSERT INTO assignments (id, order_id, driver_id, distance_km, assigned_at)
           VALUES ($1, $2, $3, $4, now())"#,
    )
    .bind(assignment_id)
    .bind(order_id)
    .bind(driver_id)
    .bind(distance_km)
    .execute(&mut **tx)
    .await?;

    sqlx::query(r#"UPDATE drivers SET status = 'busy', updated_at = now() WHERE id = $1"#)
        .bind(driver_id)
        .execute(&mut **tx)
        .await?;

    Ok(assignment_id)
}

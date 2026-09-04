use chrono::Utc;
use dispatch_core::{geo::nearest_driver, CoreError, DispatchAssigned, GeoPoint};
use sqlx::PgPool;
use uuid::Uuid;

use crate::db;

/// Distinguishes the two "nothing was assigned" cases, because they need
/// opposite SQS handling: an already-handled duplicate should be deleted
/// (acknowledged) from the queue, while "no driver available yet" must be
/// left alone so SQS redelivers it after the visibility timeout.
pub enum AssignOutcome {
    Assigned(DispatchAssigned),
    AlreadyHandled,
    NoDriverAvailable,
}

/// The full "match one order to one driver" transaction. Runs as a single
/// Postgres transaction so a crash or error between "claim the order" and
/// "record the assignment" can never leave the system in a half-assigned
/// state — either all three writes (claim, assignment insert, driver
/// busy-flag) land together, or none of them do and the SQS message is
/// safe to retry.
pub async fn assign_order(
    pool: &PgPool,
    order_id: Uuid,
    pickup: GeoPoint,
    radius_km: u32,
) -> anyhow::Result<AssignOutcome> {
    let mut tx = pool.begin().await?;

    let claimed = db::claim_order_for_assignment(&mut tx, order_id).await?;
    if !claimed {
        // Either already assigned by a previous (possibly duplicate) delivery
        // of this same message, or the order was cancelled. Either way,
        // there's nothing to do — treat as success so the SQS message gets
        // deleted rather than retried forever.
        tx.rollback().await?;
        return Ok(AssignOutcome::AlreadyHandled);
    }

    let candidates = db::available_drivers_for_update(&mut tx).await?;

    let outcome = match nearest_driver(pickup, &candidates, radius_km) {
        Ok((driver, distance_km)) => {
            let assignment_id =
                db::record_assignment(&mut tx, order_id, driver.id, distance_km).await?;
            AssignOutcome::Assigned(DispatchAssigned {
                assignment_id,
                order_id,
                driver_id: driver.id,
                distance_km,
                assigned_at: Utc::now(),
            })
        }
        Err(CoreError::NoDriverInRange { .. }) => AssignOutcome::NoDriverAvailable,
        Err(other) => return Err(other.into()),
    };

    match outcome {
        AssignOutcome::Assigned(_) => tx.commit().await?,
        _ => {
            // No eligible driver right now — roll back the claim so the
            // order stays `pending` and this message can be retried (SQS
            // will redeliver after the visibility timeout, or the redrive
            // policy will move it to the DLQ after `maxReceiveCount`
            // attempts for a human/ops process to inspect).
            tx.rollback().await?;
        }
    }

    Ok(outcome)
}

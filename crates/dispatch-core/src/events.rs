//! Wire contracts for events that cross a process boundary (SQS / EventBridge).
//!
//! Keeping these as explicit, versioned-by-convention structs (rather than
//! reusing the DB row types directly) means the API service, worker and
//! Lambda can each evolve their internal storage schema independently of the
//! event contract they publish/consume — the classic "don't leak your
//! database schema into your event schema" lesson from event-driven systems.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::model::GeoPoint;

/// Published by `dispatch-api` to SQS the moment an order is accepted.
/// Consumed by `dispatch-worker`, which performs the actual driver matching.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OrderCreated {
    pub order_id: Uuid,
    pub pickup: GeoPoint,
    pub dropoff: GeoPoint,
    pub created_at: DateTime<Utc>,
}

/// Published by `dispatch-worker` to the EventBridge custom bus once a
/// driver has been matched to an order. Multiple independent consumers can
/// subscribe to this without the worker knowing or caring who they are —
/// `dispatch-notify-lambda` is one, but a future billing/analytics service
/// could subscribe to the same rule without any change here.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DispatchAssigned {
    pub assignment_id: Uuid,
    pub order_id: Uuid,
    pub driver_id: Uuid,
    pub distance_km: f64,
    pub assigned_at: DateTime<Utc>,
}

impl DispatchAssigned {
    /// EventBridge "detail-type" this event is published under. Centralised
    /// here so the publisher (worker) and the consumers (Lambda, rules in
    /// Terraform) can't drift apart on the string value.
    pub const DETAIL_TYPE: &'static str = "DispatchAssigned";
    pub const SOURCE: &'static str = "velocity.dispatch";
}

impl OrderCreated {
    pub const SQS_MESSAGE_TYPE: &'static str = "OrderCreated";
}

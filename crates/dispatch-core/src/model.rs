use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::error::CoreError;

/// A latitude/longitude pair. Kept as a newtype (rather than a bare tuple) so
/// argument order can never be mixed up at call sites, and so validation
/// lives in exactly one place.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct GeoPoint {
    pub lat: f64,
    pub lon: f64,
}

impl GeoPoint {
    pub fn new(lat: f64, lon: f64) -> Result<Self, CoreError> {
        if !(-90.0..=90.0).contains(&lat) || !(-180.0..=180.0).contains(&lon) {
            return Err(CoreError::InvalidCoordinate { lat, lon });
        }
        Ok(Self { lat, lon })
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum OrderStatus {
    Pending,
    Assigned,
    PickedUp,
    Delivered,
    Cancelled,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DriverStatus {
    Available,
    Busy,
    Offline,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Order {
    pub id: Uuid,
    pub pickup: GeoPoint,
    pub dropoff: GeoPoint,
    pub status: OrderStatus,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Driver {
    pub id: Uuid,
    pub name: String,
    pub location: GeoPoint,
    pub status: DriverStatus,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Assignment {
    pub id: Uuid,
    pub order_id: Uuid,
    pub driver_id: Uuid,
    pub distance_km: f64,
    pub assigned_at: DateTime<Utc>,
}

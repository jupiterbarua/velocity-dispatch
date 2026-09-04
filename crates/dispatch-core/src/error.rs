use thiserror::Error;

/// Errors that can arise from pure domain logic (no I/O errors live here on
/// purpose — those belong in the service crates that own the I/O).
#[derive(Debug, Error, PartialEq, Eq)]
pub enum CoreError {
    #[error("no available driver found within {radius_km} km of the pickup point")]
    NoDriverInRange { radius_km: u32 },

    #[error("invalid coordinate: lat={lat}, lon={lon}")]
    InvalidCoordinate { lat: f64, lon: f64 },

    #[error("order {0} is not in a state that can be assigned")]
    OrderNotAssignable(uuid::Uuid),
}

use thiserror::Error;

/// Errors that can arise from pure domain logic (no I/O errors live here on
/// purpose — those belong in the service crates that own the I/O).
// PartialEq only, not Eq: `InvalidCoordinate` carries f64 fields, and f64
// implements PartialEq but not Eq (NaN != NaN under IEEE 754, so floats
// can't satisfy Eq's reflexivity guarantee). Deriving Eq here would fail to
// compile precisely because of that field — this comment is here so nobody
// "fixes" it back the way a search-and-replace might.
#[derive(Debug, Error, PartialEq)]
pub enum CoreError {
    #[error("no available driver found within {radius_km} km of the pickup point")]
    NoDriverInRange { radius_km: u32 },

    #[error("invalid coordinate: lat={lat}, lon={lon}")]
    InvalidCoordinate { lat: f64, lon: f64 },

    #[error("order {0} is not in a state that can be assigned")]
    OrderNotAssignable(uuid::Uuid),
}

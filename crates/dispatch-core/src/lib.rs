//! `dispatch-core` — shared domain model for the Velocity Dispatch platform.
//!
//! This crate is intentionally free of any I/O (no AWS SDK, no database driver,
//! no web framework). It holds the types and pure business logic that both the
//! `dispatch-api` service, the `dispatch-worker` service and the
//! `dispatch-notify-lambda` function depend on. Keeping this boundary clean
//! means the matching algorithm and event contracts can be unit tested in
//! microseconds, with zero network or database involved.

pub mod error;
pub mod events;
pub mod geo;
pub mod model;

pub use error::CoreError;
pub use events::{DispatchAssigned, OrderCreated};
pub use model::{Assignment, Driver, DriverStatus, GeoPoint, Order, OrderStatus};

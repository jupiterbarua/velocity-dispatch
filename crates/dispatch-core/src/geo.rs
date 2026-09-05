//! Geospatial matching logic.
//!
//! This is deliberately implemented from first principles (no `geo` crate)
//! so the algorithmic cost is obvious and testable: `nearest_driver` is an
//! O(n) scan over candidate drivers, which is the right complexity budget
//! for a single dispatch region polled every few seconds. At real logistics
//! scale this is the seam where you'd swap in a spatial index (e.g. an R-tree
//! or PostGIS `ST_DWithin` query) without touching any caller.

use crate::error::CoreError;
use crate::model::{Driver, DriverStatus, GeoPoint};

const EARTH_RADIUS_KM: f64 = 6371.0;

/// Great-circle distance between two points, in kilometres.
///
/// Uses the haversine formula. Accurate to within ~0.5% for the scale of a
/// single city/metro dispatch region, which is more than sufficient here —
/// this is not a navigation system, it's a "who is closest" ranking signal.
pub fn haversine_km(a: GeoPoint, b: GeoPoint) -> f64 {
    let (lat1, lon1) = (a.lat.to_radians(), a.lon.to_radians());
    let (lat2, lon2) = (b.lat.to_radians(), b.lon.to_radians());

    let dlat = lat2 - lat1;
    let dlon = lon2 - lon1;

    let h = (dlat / 2.0).sin().powi(2) + lat1.cos() * lat2.cos() * (dlon / 2.0).sin().powi(2);
    let c = 2.0 * h.sqrt().asin();

    EARTH_RADIUS_KM * c
}

/// Find the closest available driver to `pickup`, within `radius_km`.
///
/// Returns the driver and the distance in kilometres. Runs in O(n) over the
/// candidate slice — callers are expected to have already narrowed the
/// candidate set down to one dispatch region (e.g. via a DB query), not to
/// pass in every driver in the fleet.
pub fn nearest_driver<'a>(
    pickup: GeoPoint,
    candidates: &'a [Driver],
    radius_km: u32,
) -> Result<(&'a Driver, f64), CoreError> {
    candidates
        .iter()
        .filter(|d| d.status == DriverStatus::Available)
        .map(|d| (d, haversine_km(pickup, d.location)))
        .filter(|(_, dist)| *dist <= radius_km as f64)
        .min_by(|(_, a), (_, b)| a.total_cmp(b))
        .ok_or(CoreError::NoDriverInRange { radius_km })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::DriverStatus;
    use approx::assert_relative_eq;
    use chrono::Utc;
    use uuid::Uuid;

    fn driver(lat: f64, lon: f64, status: DriverStatus) -> Driver {
        Driver {
            id: Uuid::new_v4(),
            name: "Test Driver".into(),
            location: GeoPoint::new(lat, lon).unwrap(),
            status,
            updated_at: Utc::now(),
        }
    }

    #[test]
    fn haversine_known_distance_berlin_hamburg() {
        // Berlin (52.5200, 13.4050) to Hamburg (53.5511, 9.9937) is ~255 km.
        let berlin = GeoPoint::new(52.5200, 13.4050).unwrap();
        let hamburg = GeoPoint::new(53.5511, 9.9937).unwrap();
        let dist = haversine_km(berlin, hamburg);
        assert_relative_eq!(dist, 255.0, max_relative = 0.03);
    }

    #[test]
    fn haversine_same_point_is_zero() {
        let p = GeoPoint::new(52.5200, 13.4050).unwrap();
        assert_relative_eq!(haversine_km(p, p), 0.0, epsilon = 1e-9);
    }

    #[test]
    fn nearest_driver_picks_closest_available() {
        let pickup = GeoPoint::new(52.5200, 13.4050).unwrap(); // Berlin
        let drivers = vec![
            driver(53.5511, 9.9937, DriverStatus::Available), // Hamburg, far
            driver(52.5300, 13.4100, DriverStatus::Available), // ~1.2km away, close
            driver(52.5250, 13.4080, DriverStatus::Busy),      // closer but busy
        ];

        let (nearest, dist) = nearest_driver(pickup, &drivers, 50).unwrap();
        assert_eq!(nearest.id, drivers[1].id);
        assert!(dist < 2.0);
    }

    #[test]
    fn nearest_driver_errors_when_none_in_range() {
        let pickup = GeoPoint::new(52.5200, 13.4050).unwrap();
        let drivers = vec![driver(53.5511, 9.9937, DriverStatus::Available)]; // ~255km away
        let result = nearest_driver(pickup, &drivers, 10);
        assert_eq!(result.unwrap_err(), CoreError::NoDriverInRange { radius_km: 10 });
    }

    #[test]
    fn nearest_driver_ignores_offline_and_busy() {
        let pickup = GeoPoint::new(52.5200, 13.4050).unwrap();
        let drivers = vec![
            driver(52.5201, 13.4051, DriverStatus::Offline),
            driver(52.5202, 13.4052, DriverStatus::Busy),
        ];
        let result = nearest_driver(pickup, &drivers, 50);
        assert!(result.is_err());
    }
}

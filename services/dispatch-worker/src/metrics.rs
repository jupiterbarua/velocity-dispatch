//! Business metrics, emitted as CloudWatch Embedded Metric Format (EMF).
//!
//! This is the most interesting number this system produces — "how long
//! does it take an order to get matched, and how often does matching
//! actually succeed" — and until this file existed, it was invisible: the
//! CloudWatch alarms in `monitoring.tf` only see infrastructure symptoms
//! (queue depth, task count), never the business outcome itself. A queue
//! can look perfectly healthy — draining fast, zero backlog — while every
//! single match fails because the matching radius is misconfigured; only a
//! business metric like this one would show that.
//!
//! EMF works by writing a specially-shaped JSON object as **one standalone
//! line to stdout**. CloudWatch Logs recognizes the `_aws` key at the top
//! level of a log line and automatically extracts the named fields into
//! real CloudWatch custom metrics — no `PutMetricData` API call, no extra
//! network round trip, no AWS SDK dependency for this at all. That's why
//! this is `println!`, not `tracing::info!`: the app's normal structured
//! logs go through `tracing_subscriber`'s JSON formatter, which nests event
//! fields one level deep (`{"level":"INFO","fields":{...}}`) — that would
//! hide `_aws` from CloudWatch's extractor, which requires it at the top
//! level. Metrics and logs deliberately use two different output paths
//! here, even though both end up in the same CloudWatch Logs group.

use std::time::{SystemTime, UNIX_EPOCH};

const NAMESPACE: &str = "VelocityDispatch/Worker";

/// Emitted once per SQS message processed, immediately after
/// `matching::assign_order` returns — see `main.rs::handle_message`.
///
/// `outcome` is one of `"assigned"`, `"no_driver_available"`, or
/// `"already_handled"` (mirrors `matching::AssignOutcome`, kept as a plain
/// `&str` here rather than importing the enum so this module has zero
/// dependency on the rest of the crate beyond `std`).
///
/// `time_since_order_created_ms` is measured from the order's
/// `created_at` (set by `dispatch-api` at the moment the order was
/// accepted) to *this* matching attempt — for a successful match, that's
/// the real end-to-end "time to dispatch" SLA number; for a failed
/// attempt, it's "how long has this order been waiting," which is exactly
/// what you'd want on a dashboard next to the queue-backlog alarm.
pub fn emit_match_outcome(environment: &str, outcome: &str, time_since_order_created_ms: f64) {
    let now_ms = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0);

    // Hand-rolled rather than pulled from a crate: the EMF payload is a
    // small, stable, well-documented JSON shape, and writing it directly
    // with `serde_json::json!` keeps this service's dependency graph as
    // small as everything else in this repo rather than adding a package
    // whose only job is building this one object.
    let payload = serde_json::json!({
        "_aws": {
            "Timestamp": now_ms,
            "CloudWatchMetrics": [{
                "Namespace": NAMESPACE,
                "Dimensions": [["Environment", "Outcome"]],
                "Metrics": [
                    { "Name": "MatchCount", "Unit": "Count" },
                    { "Name": "TimeToMatchMs", "Unit": "Milliseconds" }
                ]
            }]
        },
        "Environment": environment,
        "Outcome": outcome,
        "MatchCount": 1,
        "TimeToMatchMs": time_since_order_created_ms,
    });

    println!("{payload}");
}

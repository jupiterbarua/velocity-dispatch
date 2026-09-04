// k6 load test for dispatch-api's hot path: POST /orders.
//
// Usage:
//   k6 run -e BASE_URL=http://localhost:8080 loadtest/orders.js
//
// What to look at afterwards (and put in the README's results table):
//   - http_req_duration p(95) / p(99)  — the tail latency claim this
//     project is built to be able to defend in an interview.
//   - http_req_failed rate            — should be ~0%; a non-zero rate
//     under load usually means the DB pool (see dispatch-api's
//     `db_max_connections`) is undersized for the offered concurrency.
//
// This deliberately stays inside a bounded region around Berlin so
// `nearest_driver`'s radius filter has a realistic chance of finding a
// match if you've seeded drivers with scripts/seed.sh first.

import http from "k6/http";
import { check, sleep } from "k6";
import { Trend } from "k6/metrics";

const BASE_URL = __ENV.BASE_URL || "http://localhost:8080";

export const options = {
  scenarios: {
    ramping_throughput: {
      executor: "ramping-vus",
      startVUs: 0,
      stages: [
        { duration: "30s", target: 50 },
        { duration: "1m", target: 200 },
        { duration: "1m", target: 200 },
        { duration: "30s", target: 0 },
      ],
    },
  },
  thresholds: {
    http_req_duration: ["p(95)<150", "p(99)<400"],
    http_req_failed: ["rate<0.01"],
  },
};

const createOrderLatency = new Trend("create_order_latency", true);

// Roughly Berlin's bounding box — matches the seed script's driver spread.
function randomBerlinPoint() {
  return {
    lat: 52.45 + Math.random() * 0.2,
    lon: 13.3 + Math.random() * 0.3,
  };
}

export default function () {
  const payload = JSON.stringify({
    pickup: randomBerlinPoint(),
    dropoff: randomBerlinPoint(),
  });

  const res = http.post(`${BASE_URL}/orders`, payload, {
    headers: { "Content-Type": "application/json" },
  });

  createOrderLatency.add(res.timings.duration);

  check(res, {
    "status is 201": (r) => r.status === 201,
    "has order id": (r) => {
      try {
        return !!JSON.parse(r.body).id;
      } catch {
        return false;
      }
    },
  });

  sleep(0.1);
}

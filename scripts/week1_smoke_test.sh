#!/usr/bin/env bash
#
# Week 1 smoke test — the runnable version of docs/SPRINT_LOG.md's
# acceptance checklist. This is what "Week 1 is done" actually means, not
# just "the code compiles."
#
# Usage:
#   docker compose up --build -d
#   ./scripts/week1_smoke_test.sh
#
# Requires: curl, jq, and either `docker compose` (v2) or `docker-compose`
# (v1) on PATH for the architecture check in step 0.
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:8080}"
TIMEOUT_SECS="${TIMEOUT_SECS:-30}"

pass() { echo "  \xe2\x9c\x93 $1"; }
fail() { echo "  \xe2\x9c\x97 $1" >&2; exit 1; }

command -v curl >/dev/null || fail "curl is required"
command -v jq   >/dev/null || fail "jq is required (brew install jq / apt install jq)"

COMPOSE=(docker compose)
docker compose version >/dev/null 2>&1 || COMPOSE=(docker-compose)

echo "== Week 1 smoke test: common + producer + consumer, local only =="

# --- 0. Architecture assertion: no app-to-app startup coupling ----------
# Resolves the compose file (handles anchors/merges/env substitution) and
# checks dispatch-worker's own depends_on list rather than grepping the
# source YAML directly — this is what Week 1's "independent startup" claim
# actually rests on, so it's worth asserting in code, not just in prose.
echo "[0/5] checking dispatch-worker has no startup dependency on dispatch-api..."
WORKER_DEPENDS_ON=$("${COMPOSE[@]}" config --format json 2>/dev/null \
  | jq -r '.services["dispatch-worker"].depends_on // {} | keys[]' 2>/dev/null || true)
if echo "$WORKER_DEPENDS_ON" | grep -qx "dispatch-api"; then
  fail "dispatch-worker still depends on dispatch-api in docker-compose.yml — that's the coupling Week 1 removed; check for a regression"
fi
pass "dispatch-worker depends only on: $(echo "$WORKER_DEPENDS_ON" | tr '\n' ' ' | sed 's/ *$//')"

# --- 1. dispatch-api readiness (the real DB-backed check, not liveness) --
echo "[1/5] waiting for dispatch-api readiness (up to ${TIMEOUT_SECS}s)..."
deadline=$((SECONDS + TIMEOUT_SECS))
until curl -sf "$BASE_URL/health" > /dev/null 2>&1; do
  if [ "$SECONDS" -ge "$deadline" ]; then
    fail "dispatch-api never became healthy — check: ${COMPOSE[*]} logs dispatch-api"
  fi
  sleep 1
done
pass "dispatch-api /health is green (Postgres reachable — see routes.rs::health)"

# --- 2. seed one driver near the test coordinates ------------------------
echo "[2/5] registering a test driver..."
DRIVER_RESPONSE=$(curl -sf -X POST "$BASE_URL/drivers" \
  -H 'Content-Type: application/json' \
  -d '{"name":"Smoke Test Driver","location":{"lat":52.5205,"lon":13.4051}}') \
  || fail "POST /drivers failed"
DRIVER_ID=$(echo "$DRIVER_RESPONSE" | jq -r '.id')
[ -n "$DRIVER_ID" ] && [ "$DRIVER_ID" != "null" ] || fail "driver registration didn't return an id: $DRIVER_RESPONSE"
pass "driver registered: $DRIVER_ID"

# --- 3. place an order within range of that driver ------------------------
echo "[3/5] placing an order..."
ORDER_RESPONSE=$(curl -sf -X POST "$BASE_URL/orders" \
  -H 'Content-Type: application/json' \
  -d '{"pickup":{"lat":52.5200,"lon":13.4050},"dropoff":{"lat":52.5000,"lon":13.3800}}') \
  || fail "POST /orders failed"
ORDER_ID=$(echo "$ORDER_RESPONSE" | jq -r '.id')
ORDER_STATUS=$(echo "$ORDER_RESPONSE" | jq -r '.status')
[ "$ORDER_STATUS" = "pending" ] || fail "expected new order status 'pending', got '$ORDER_STATUS'"
pass "order created: $ORDER_ID (pending)"

# --- 4. poll until dispatch-worker matches it ------------------------------
echo "[4/5] waiting for dispatch-worker to match a driver (up to ${TIMEOUT_SECS}s)..."
deadline=$((SECONDS + TIMEOUT_SECS))
STATUS="pending"
while [ "$STATUS" = "pending" ]; do
  if [ "$SECONDS" -ge "$deadline" ]; then
    fail "order still 'pending' after ${TIMEOUT_SECS}s — check: ${COMPOSE[*]} logs dispatch-worker"
  fi
  sleep 2
  STATUS=$(curl -sf "$BASE_URL/orders/$ORDER_ID" | jq -r '.status')
done
[ "$STATUS" = "assigned" ] || fail "expected final status 'assigned', got '$STATUS'"
pass "order matched by dispatch-worker: status is now 'assigned'"

# --- 5. confirm the driver left the available pool -------------------------
echo "[5/5] confirming the matched driver left the available pool..."
STILL_LISTED=$(curl -sf "$BASE_URL/drivers" | jq --arg id "$DRIVER_ID" '[.[] | select(.id == $id)] | length')
[ "$STILL_LISTED" = "0" ] || fail "driver $DRIVER_ID is still listed as available after being matched"
pass "driver correctly moved out of the available pool (status: busy)"

echo
echo "Week 1 walking skeleton: PASS"
echo "(That driver is now permanently 'busy' — FR-12/delivery-completion is intentionally unimplemented, see docs/REQUIREMENTS.md §8.1. Expected, not a bug.)"

#!/usr/bin/env bash
# Registers a handful of demo drivers scattered around Berlin so
# POST /orders has something to match against, and so loadtest/orders.js
# exercises the real nearest_driver path instead of always hitting the
# "no driver in range" branch.
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:8080}"
COUNT="${1:-25}"

echo "Seeding $COUNT drivers against $BASE_URL ..."

for i in $(seq 1 "$COUNT"); do
  lat=$(awk -v seed="$RANDOM" 'BEGIN{srand(seed); printf "%.5f", 52.45 + rand()*0.2}')
  lon=$(awk -v seed="$RANDOM" 'BEGIN{srand(seed); printf "%.5f", 13.30 + rand()*0.3}')

  curl -s -o /dev/null -w "driver %{http_code}\n" \
    -X POST "$BASE_URL/drivers" \
    -H "Content-Type: application/json" \
    -d "{\"name\":\"Driver $i\",\"location\":{\"lat\":$lat,\"lon\":$lon}}"
done

echo "Done. GET $BASE_URL/drivers to verify."

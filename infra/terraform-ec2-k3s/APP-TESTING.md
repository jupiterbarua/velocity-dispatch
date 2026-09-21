# Testing velocity-dispatch on the live EC2/k3s box

Run all of this from your Mac, in the repo root or
`infra/terraform-ec2-k3s/` as noted. Requires `jq` (`brew install jq`),
and `watch` and `k6` for the optional steps (`brew install watch k6`).

Security group note: only your current IP can reach the app (see
`network.tf`), so none of this can be run from anywhere else, including
by me from this session — that's deliberate, not a limitation to fix.

## 0. Set the base URL once

```bash
cd ~/personalproject/velocity-dispatch/infra/terraform-ec2-k3s
export BASE_URL=$(terraform output -raw api_url)
echo $BASE_URL
```

Re-run this any time the instance gets replaced (new public IP) — it's
cheap, so just re-export it at the start of every test session rather
than trying to remember whether it's stale.

## 1. Health check

```bash
curl -sf $BASE_URL/health && echo " -- OK"
```

## 2. Seed some drivers

The project's own script — scatters demo drivers around Berlin so orders
have something to match against, and so the load test exercises the real
`nearest_driver` path instead of always hitting "no driver in range".

```bash
cd ~/personalproject/velocity-dispatch
BASE_URL=$BASE_URL ./scripts/seed.sh 25          # 25 drivers; adjust the count as needed
curl -s $BASE_URL/drivers | jq
```

## 3. Place a single order

Doing this manually (rather than just running the load test) lets you
watch one order go through the full pending -> assigned lifecycle.

```bash
ORDER_RESPONSE=$(curl -sf -X POST "$BASE_URL/orders" \
  -H 'Content-Type: application/json' \
  -d '{"pickup":{"lat":52.5200,"lon":13.4050},"dropoff":{"lat":52.5000,"lon":13.3800}}')

echo "$ORDER_RESPONSE" | jq
ORDER_ID=$(echo "$ORDER_RESPONSE" | jq -r '.id')
echo "order id: $ORDER_ID"
```

Expect `"status": "pending"` immediately after creation.

## 4. Watch dispatch-worker match it

```bash
watch -n2 "curl -s $BASE_URL/orders/$ORDER_ID | jq"
```

Ctrl-C once `status` flips to `"assigned"`. No `watch` installed? Just
re-run the plain curl a few times by hand instead:

```bash
curl -s $BASE_URL/orders/$ORDER_ID | jq
```

## 5. Confirm the matched driver left the available pool

```bash
curl -s $BASE_URL/drivers | jq
```

The driver that got matched should be missing from this list now (moved
to `busy`). Per the project's own docs (`docs/REQUIREMENTS.md` §8.1),
delivery-completion (FR-12) isn't implemented yet, so a matched driver
stays `busy` permanently — expected, not a bug, until that's built.

## 6. Run the real load test

This is what the project is actually built to demonstrate — p95/p99
latency under concurrent load.

```bash
cd infra/terraform-ec2-k3s
k6 run -e BASE_URL=$BASE_URL ../../loadtest/orders.js
```

Ramps 0 -> 50 -> 200 concurrent VUs over about 3 minutes. Thresholds
baked into the test: `http_req_duration p(95) < 150ms`, `p(99) < 400ms`,
`http_req_failed rate < 1%`. A non-zero failure rate under load usually
points at the DB connection pool being undersized for the concurrency
(see dispatch-api's `db_max_connections`), per the test file's own
comment.

## 7. Watch pods react to load (optional, second terminal)

SSH into the box in a separate terminal while step 6 is running:

```bash
ssh -o StrictHostKeyChecking=accept-new -i infra/terraform-ec2-k3s/velocity-dispatch-k3s.pem ubuntu@$(terraform -chdir=infra/terraform-ec2-k3s output -raw public_ip)
kubectl get pods -n velocity-dispatch --watch
```

If the HPA (`horizontalpodautoscaler.autoscaling`) is configured
correctly, `dispatch-api`/`dispatch-worker` replica counts should climb
during the load test's ramp-up. Check current vs. target replicas
directly with:

```bash
kubectl get hpa -n velocity-dispatch
```

## Troubleshooting

**curl hangs or times out from your Mac**: your public IP probably
drifted since the security group was last applied — re-run `./up.sh`
in `infra/terraform-ec2-k3s/` to refresh it (see `TERRAFORM-COMMANDS.md`).

**curl works from your Mac but not from inside the box (SSH session)**:
expected — an EC2 instance can't reach its own public IP from inside
itself (that traffic would need to round-trip through the Internet
Gateway, which AWS doesn't hairpin back to the source instance). Use
`localhost` or the private IP when testing from the box itself; see
`KUBECTL-COMMANDS.md`.

**order stays "pending" forever**: check `dispatch-worker`'s logs
(`kubectl logs -n velocity-dispatch <dispatch-worker-pod> -f`) — likely
either no seeded driver is within `nearest_driver`'s matching radius of
the order's pickup point, or the worker isn't consuming from
SQS/LocalStack correctly.

**POST /drivers or /orders returns non-2xx**: check `dispatch-api`'s
logs the same way, and confirm `/health` is still green first (a DB
connectivity issue will usually show up there before anywhere else).

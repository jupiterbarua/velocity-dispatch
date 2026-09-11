#!/usr/bin/env bash
# All the kubectl/k3d/k6 commands for running velocity-dispatch on
# Kubernetes, in the order you'd actually use them. This is a REFERENCE,
# not a script to run top-to-bottom: several commands block (-w watches)
# or are meant to run in a second terminal while another one is still
# going. Copy/paste the section you need. See k8s/README.md for the full
# explanation of *why* each piece exists.

# ============================================================
# 1. ONE-TIME SETUP — install the tools
# ============================================================
brew install docker k3d kubectl

# ============================================================
# 2. CREATE THE CLUSTER
# ============================================================
# --agents 0            : single node, less overhead than multi-node
# --port "8080:30080@lb": maps your Mac's localhost:8080 -> the cluster's
#                         NodePort 30080 (dispatch-api's Service)
# --servers-memory 1.5G : keeps it light on the 2015 Air
k3d cluster create velocity-dispatch \
  --agents 0 \
  --port "8080:30080@loadbalancer" \
  --servers-memory 1.5G

# Confirm the cluster is actually up:
kubectl cluster-info
kubectl get nodes

# ============================================================
# 3. DEPLOY
# ============================================================
kubectl apply -k k8s/base/

# Watch pods come up (Ctrl+C once everything is 1/1 Running):
kubectl -n velocity-dispatch get pods -w

# All objects at a glance, any time:
kubectl -n velocity-dispatch get all

# ============================================================
# 4. VERIFY IT'S WORKING
# ============================================================
curl http://localhost:8080/health
# -> {"status":"ok"}

BASE_URL=http://localhost:8080 ./scripts/seed.sh 25
curl http://localhost:8080/drivers | jq length
# -> 25

curl -X POST http://localhost:8080/orders \
  -H "Content-Type: application/json" \
  -d '{"pickup":{"lat":52.52,"lon":13.40},"dropoff":{"lat":52.50,"lon":13.42}}'
# -> 201 Created, body has an order id

# Watch dispatch-worker pick the order up off the queue and match a driver:
kubectl -n velocity-dispatch logs -l app=dispatch-worker -f

# ============================================================
# 5. LOAD TEST + WATCH THE HPA SCALE (two terminals)
# ============================================================
# Terminal A — watch replica counts change live:
kubectl -n velocity-dispatch get hpa -w

# Terminal B — generate real load with the existing k6 script:
brew install k6   # if you don't have it yet
k6 run -e BASE_URL=http://localhost:8080 loadtest/orders.js
# dispatch-api's replicas should climb toward 5 while load ramps up,
# then scale back down ~5 minutes after it stops (that delay is HPA's
# default scale-down stabilization window, not a bug).

# ============================================================
# 6. DEBUGGING — reach for these when a pod isn't happy
# ============================================================
# Full state + recent Events for one pod (usually the fastest signal):
kubectl -n velocity-dispatch describe pod <pod-name>

# Logs for a running/crashed container:
kubectl -n velocity-dispatch logs <pod-name>
kubectl -n velocity-dispatch logs <pod-name> --previous   # after a crash/restart
kubectl -n velocity-dispatch logs <pod-name> -c wait-for-postgres     # a specific init container
kubectl -n velocity-dispatch logs <pod-name> -c wait-for-localstack

# All pods matching a label, tailed together:
kubectl -n velocity-dispatch logs -l app=dispatch-api -f

# Postgres/LocalStack specifically, if either stalls:
kubectl -n velocity-dispatch describe pod postgres-0
kubectl -n velocity-dispatch describe pod -l app=localstack

# Shell into a running pod (e.g. to hand-run a curl/psql from inside the cluster):
kubectl -n velocity-dispatch exec -it deploy/dispatch-api -- sh

# Restart a Deployment's pods (e.g. after editing a ConfigMap/Secret —
# k8s doesn't auto-restart pods just because a ConfigMap changed):
kubectl -n velocity-dispatch rollout restart deployment dispatch-api
kubectl -n velocity-dispatch rollout status deployment dispatch-api

# ============================================================
# 7. TEAR DOWN
# ============================================================
k3d cluster delete velocity-dispatch

# ============================================================
# ALTERNATIVE: using minikube instead of k3d
# ============================================================
minikube start --driver=docker --cpus=2 --memory=2200mb
minikube addons enable metrics-server   # k3d has this built in; minikube doesn't
kubectl apply -k k8s/base/
minikube service dispatch-api -n velocity-dispatch --url
# ^ use the URL this prints in place of http://localhost:8080 everywhere above
minikube stop
minikube delete

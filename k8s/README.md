# Running velocity-dispatch on Kubernetes

This runs the same published images `docker-compose.yml` uses
(`ghcr.io/jupiterbarua/velocity-dispatch/dispatch-api:latest` and
`dispatch-worker:latest` — public, multi-arch, built by `ci.yml`'s
`publish-images` job) on a local Kubernetes cluster instead of Docker
Compose. Nothing here builds from source, so the earlier GLIBC/cargo-chef
issues (see the project's round 8 notes) don't apply — this only ever
pulls already-tested images.

Chosen deliberately as **k3d** (k3s-in-Docker) over minikube/kind: it's
the smallest footprint of the three, which matters on a 2015 dual-core
MacBook Air that's already running Postgres + LocalStack + 4 app replicas
at once. If you'd rather reuse the minikube install already on this
machine, see "Using minikube instead" at the bottom — the manifests
themselves don't care which tool created the cluster.

## What's here

```
k8s/base/
  namespace.yaml        # the velocity-dispatch namespace everything else lives in
  configmap.yaml         # non-secret env vars (mirrors .env.example)
  secret.yaml             # DATABASE_URL + LocalStack's dummy AWS creds (see comments in the file for why this is safe to commit)
  postgres.yaml           # StatefulSet + headless Service + PVC
  localstack.yaml         # Deployment + Service + the init-aws.sh ConfigMap
  dispatch-api.yaml       # Deployment + NodePort Service + HPA
  dispatch-worker.yaml    # Deployment + HPA (no Service — worker has no HTTP surface)
  kustomization.yaml
```

Every file is commented with the *why*, not just the *what* — same style
as the rest of this repo's Dockerfiles/docker-compose.yml — because "why
StatefulSet not Deployment for Postgres" and "why NodePort not ClusterIP
here" are exactly the questions this is meant to be able to answer in an
interview.

## Prerequisites

```bash
brew install docker k3d kubectl
```

Docker Desktop (or colima) needs to actually be running — k3d runs k3s
*inside* Docker containers, it doesn't need a separate VM the way
minikube's `--driver=hyperkit`/`--driver=qemu` do.

## 1. Create the cluster

```bash
k3d cluster create velocity-dispatch \
  --agents 0 \
  --port "8080:30080@loadbalancer" \
  --servers-memory 1.5G
```

- `--agents 0`: single-node (server doubles as the only worker) — less
  overhead than a multi-node cluster for a demo of this size.
- `--port "8080:30080@loadbalancer"`: maps your Mac's `localhost:8080` to
  node port `30080` inside the cluster, which is exactly the port
  `dispatch-api.yaml`'s Service listens on. This is what makes
  `curl localhost:8080/health` work identically to how it did against
  docker-compose.
- k3d's underlying k3s ships `metrics-server` by default, so the HPAs in
  `dispatch-api.yaml`/`dispatch-worker.yaml` work with no extra addon step
  (unlike minikube — see below).

Confirm:

```bash
kubectl cluster-info
kubectl get nodes
```

## 2. Deploy

```bash
kubectl apply -k k8s/base/
```

(Plain `kubectl apply -f k8s/base/` also works — the kustomization is
there for convenience and as a home for a future EKS overlay, not a hard
requirement.)

Watch everything come up:

```bash
kubectl -n velocity-dispatch get pods -w
```

Expect this rough order: `postgres-0` and `localstack-...` become
`Running`/`Ready` first; `dispatch-api`/`dispatch-worker` pods sit in
`Init:0/2` until their `wait-for-postgres`/`wait-for-localstack` init
containers succeed, then start their main container. If a pod sits in
`Init:` for a long time:

```bash
kubectl -n velocity-dispatch logs <pod-name> -c wait-for-postgres
kubectl -n velocity-dispatch describe pod <pod-name>   # Events section at the bottom is usually the fastest signal
```

## 3. Verify it actually works

```bash
curl http://localhost:8080/health
# {"status":"ok"}

BASE_URL=http://localhost:8080 ./scripts/seed.sh 25
curl http://localhost:8080/drivers | jq length
# 25

curl -X POST http://localhost:8080/orders \
  -H "Content-Type: application/json" \
  -d '{"pickup":{"lat":52.52,"lon":13.40},"dropoff":{"lat":52.50,"lon":13.42}}'
# 201 Created, body has an order id
```

That last request is the same round-trip `dispatch-api` did in
docker-compose: insert the order into `postgres-0`, publish `OrderCreated`
to the `order-created` SQS queue running inside the in-cluster
`localstack` pod, return `201` immediately. `dispatch-worker`'s pods pick
that message up asynchronously — check their logs to see it happen:

```bash
kubectl -n velocity-dispatch logs -l app=dispatch-worker -f
```

## 4. See the HPA actually do something

```bash
kubectl -n velocity-dispatch get hpa -w
```

In another terminal, generate real load with the k6 script this repo
already has:

```bash
k6 run -e BASE_URL=http://localhost:8080 loadtest/orders.js
```

Watch `dispatch-api`'s HPA target CPU climb and `REPLICAS` scale up from 2
toward its `maxReplicas: 5` ceiling as the ramping-VUs stages hit 200
concurrent users, then scale back down a few minutes after the load stops
(HPA's default scale-down stabilization window is 5 minutes — that delay
is deliberate, not a bug, so don't kill the cluster thinking it's stuck).

## 5. Clean up

```bash
k3d cluster delete velocity-dispatch
```

The PVC backing `postgres-0` is deleted with the cluster (k3d's default
`local-path` StorageClass is node-local) — this is a throwaway demo
environment, not somewhere to keep data you care about.

## What's deliberately not here

- **`dispatch-notify-lambda`** — same reasoning as docker-compose: it's
  event-invoked (EventBridge → Lambda), not a long-running server, so it
  doesn't belong as a k8s Deployment. Exercise it with `cargo lambda
  watch`/`invoke` as documented in its own README, same as always.
- **Ingress / TLS** — a NodePort is the right amount of infrastructure for
  "reach this from my own laptop." An Ingress controller (or an ALB via
  the AWS Load Balancer Controller on EKS) is the real answer once this is
  reachable from outside your machine, and is a natural next step to add
  if you want to keep building this out.
- **NetworkPolicy** — everything in the `velocity-dispatch` namespace can
  currently reach everything else. Fine for a single-tenant demo
  namespace; the honest answer for "how would you lock this down" is
  default-deny + explicit allow rules per Service, not implemented here to
  keep this manifest set focused on the core workload primitives.

## Using minikube instead

This machine already has minikube installed. If you'd rather use that
than install k3d:

```bash
minikube start --driver=docker --cpus=2 --memory=2200mb
minikube addons enable metrics-server   # k3d has this built in; minikube doesn't
kubectl apply -k k8s/base/
minikube service dispatch-api -n velocity-dispatch --url
```

`minikube service ... --url` prints the URL to use instead of
`localhost:8080` (minikube's docker driver doesn't map host ports the way
k3d's `--port` flag does) — use that URL in place of `http://localhost:8080`
everywhere above.

## What this is meant to demonstrate

Namespaces, ConfigMaps/Secrets, a StatefulSet with a headless Service and
`volumeClaimTemplates` for the one genuinely stateful piece, init
containers for startup ordering (the k8s answer to compose's
`depends_on: condition: service_healthy`), readiness vs. liveness probes
tied to a real dependency check rather than just "process alive," resource
requests/limits sized for a real constrained machine instead of copy-pasted
defaults, HPA wired to metrics-server with the CPU-vs-real-metric trade-off
called out explicitly rather than hidden, and Kustomize as the seam for a
future environment-specific overlay. That's the core primitive set behind
"I can run and reason about a multi-service app on Kubernetes" — the next
honest step past this, if asked, is: an Ingress controller instead of
NodePort, KEDA for queue-depth-based worker scaling, and an
`overlays/eks/` that swaps LocalStack out for real SQS/EventBridge and
Postgres out for RDS, reusing the IAM/network work already sitting in
`infra/terraform/`.

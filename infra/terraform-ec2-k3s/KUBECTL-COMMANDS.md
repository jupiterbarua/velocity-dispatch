# kubectl commands & testing velocity-dispatch — EC2/k3s box

Run these over SSH on the instance, unless marked "from your Mac".
`export KUBECONFIG=$HOME/.kube/config` is already in `~/.bashrc` on the
box, so plain `kubectl` works without `sudo` once you've sourced it (or
opened a fresh SSH session).

```bash
ssh -o StrictHostKeyChecking=accept-new -i ./velocity-dispatch-k3s.pem ubuntu@<public-ip>
```

## Pods

```bash
kubectl get pods -n velocity-dispatch                  # quick status
kubectl get pods -n velocity-dispatch -o wide           # + node/IP columns
kubectl get pods -n velocity-dispatch --watch           # live-updating

kubectl describe pod <pod-name> -n velocity-dispatch    # events, restarts, resource limits
kubectl logs <pod-name> -n velocity-dispatch            # logs
kubectl logs <pod-name> -n velocity-dispatch -f         # follow live
kubectl logs <pod-name> -n velocity-dispatch --previous # logs from before its last crash, if any
```

## Services

```bash
kubectl get svc -n velocity-dispatch
kubectl describe svc dispatch-api -n velocity-dispatch
```

## Everything at once

```bash
kubectl get all -n velocity-dispatch
```

## Deployments / StatefulSets / HPA

```bash
kubectl get deployments -n velocity-dispatch
kubectl get statefulsets -n velocity-dispatch
kubectl rollout status deployment/dispatch-api -n velocity-dispatch
kubectl rollout status deployment/dispatch-worker -n velocity-dispatch
kubectl get hpa -n velocity-dispatch
```

## Node / resource usage

```bash
kubectl get nodes -o wide
kubectl describe node                     # capacity, allocatable, what's using it
kubectl top nodes                         # needs metrics-server (not installed by default on k3s)
kubectl top pods -n velocity-dispatch     # same caveat
```

## Exec into a running pod (debugging)

```bash
kubectl exec -it <pod-name> -n velocity-dispatch -- sh
```

## Re-apply after a manifest change

```bash
cd /opt/velocity-dispatch
sudo git pull                             # or: git pull, if KUBECONFIG/ownership lets you skip sudo
kubectl apply -k k8s/base/
```

## Namespace-wide events (useful when something's stuck, e.g. ImagePullBackOff)

```bash
kubectl get events -n velocity-dispatch --sort-by='.lastTimestamp'
```

---

# Testing the app

## From inside the box (SSH session)

Use `localhost` or the private IP — **not** the public IP. An EC2
instance can't reach its own public IP from inside itself; that traffic
has to round-trip through the Internet Gateway, which AWS doesn't
hairpin back to the same instance. This is normal AWS networking
behavior, not a bug in this setup.

```bash
curl -sf http://localhost:30080/health
curl -sf http://$(hostname -I | awk '{print $1}'):30080/health   # private IP, same result
```

## From your Mac (outside)

This is the one that should use the public IP — it works because the
request genuinely leaves your machine, crosses the internet, and enters
through the instance's Internet Gateway.

```bash
cd ~/personalproject/velocity-dispatch/infra/terraform-ec2-k3s
curl -sf "$(terraform output -raw api_url)/health"
```

## Exercising the app for real

From your Mac, against the live public URL:

```bash
BASE_URL=$(terraform output -raw api_url) ../../scripts/seed.sh 25
```

seeds drivers/orders (adjust the count as needed — 25 here).

```bash
k6 run -e BASE_URL=$(terraform output -raw api_url) ../../loadtest/orders.js
```

runs the k6 load test against the real EC2 box. Needs `k6` installed
locally (`brew install k6` on macOS) — this doesn't run on the instance
itself, it runs from your Mac and hits the NodePort over the internet,
same as the `curl` above.

## Watching the app react in real time

Two terminals side by side while `k6` (or `seed.sh`) is running:

```bash
# terminal 1 (SSH'd into the box)
kubectl get pods -n velocity-dispatch --watch

# terminal 2 (your Mac)
watch -n2 'curl -s http://$(terraform output -raw public_ip):30080/health'
```

If you configured the `horizontalpodautoscaler` resources correctly,
sustained load from the k6 run should show `dispatch-api`/
`dispatch-worker` pod counts climb in the `get pods --watch` output —
worth checking with `kubectl get hpa -n velocity-dispatch` alongside it
to see current vs. target replica counts and the metric driving the
scale decision.

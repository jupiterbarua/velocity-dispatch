# velocity-dispatch on an EC2 instance running k3s

This exists for one reason: your Mac (2015, dual-core, low RAM) genuinely
struggles to run Postgres + LocalStack + 4 app replicas + k3d's own
overhead all at once (see the `TLS handshake timeout` you hit — the k3s
API server itself was CPU-starved). This module runs the exact same
`k8s/base/` manifests on a real EC2 instance instead, for the ~3 hours/day
you're actually testing, then gets destroyed.

Defaults to `m7i-flex.large` in `us-east-1`, on-demand — free-tier
eligible on AWS accounts created on/after July 15, 2025 (up to 750
hrs/month combined across eligible types). Set `use_spot = true` (see
variables.tf) if you're outside that window or on a non-eligible
`instance_type`, to fall back to Spot pricing instead.

**This is step one of two.** Once this is confirmed working, the next
step (separate, not yet built) is a real AWS EKS cluster via Terraform —
a stronger "Kubernetes on AWS" resume line, but with a $0.10/hr control
plane cost regardless of load and real IAM/VPC complexity, which is why
it's worth verifying the simpler EC2 path first.

## What this is (and isn't)

One Ubuntu 22.04 EC2 instance with `k3s` (lightweight single-binary
Kubernetes) installed directly on it — no Docker layer, no k3d, just k3s
running natively. On boot it clones this repo and runs
`kubectl apply -k k8s/base/`, exactly like your Mac did — same
LocalStack-backed setup, same NodePort on 30080. **This does not touch
real AWS SQS/EventBridge/RDS** — that's `infra/terraform/`'s job. This
module is purely "give the same local-dev-parity stack more CPU," not a
production deployment.

Deliberately a separate Terraform root module (own state, own directory)
from `infra/terraform/` — applying/destroying here can never affect the
ECS/RDS/SQS resources that module manages.

## Cost

With the defaults (`m7i-flex.large`, on-demand, `us-east-1`) this is
**$0** as long as your account is still inside its AWS Free Tier window
(750 hrs/month combined across `t3.micro`/`t3.small`/`t4g.micro`/
`t4g.small`/`c7i-flex.large`/`m7i-flex.large` on-demand usage — plenty of
headroom for a few hours a day) — check `Billing > Free Tier` in the AWS
console for your remaining hours. Note this only applies to **on-demand**
usage; leave `use_spot` at its default `false` to actually get the free
hours, since a Spot request is billed separately even on an eligible
instance type.

Once the Free Tier window ends (or if you set `use_spot = true`), Spot
pricing for `m7i-flex.large` is typically 60-70% off the on-demand price
— check current pricing with `aws ec2 describe-spot-price-history
--instance-types m7i-flex.large --region us-east-1` since Spot prices
float. `down.sh` destroys the instance (and its EBS volume —
`delete_on_termination = true`) completely, so nothing keeps billing
between sessions. The only failure mode that costs you unexpected money
is forgetting to run `down.sh` — there's no auto-shutdown timer built in
here on purpose, to keep this simple; add one (e.g. a `shutdown -h +180`
in the user-data) if you want a safety net.

## Usage

```bash
cd infra/terraform-ec2-k3s

# First time only:
chmod +x up.sh down.sh
terraform init

./up.sh
```

`up.sh` auto-detects your current public IP (so you don't have to look it
up and pass it every time — home/mobile IPs change), applies the
Terraform, then polls `/health` until the app is actually responding
(typically 2-4 minutes: apt-get, k3s install, image pulls, kubectl apply
all happen on first boot). It prints the SSH command and the API URL when
ready.

```bash
# curl it directly — no port-forwarding needed, real public IP:
curl $(terraform output -raw api_url)/health

# seed drivers / create orders / load-test, same as the local walkthrough:
BASE_URL=$(terraform output -raw api_url) ../../scripts/seed.sh 25
k6 run -e BASE_URL=$(terraform output -raw api_url) ../../loadtest/orders.js

# kubectl runs over SSH (6443 isn't exposed to the internet — see network.tf):
$(terraform output -raw ssh_command)
# once inside: kubectl -n velocity-dispatch get pods
```

When you're done for the day:

```bash
./down.sh
```

## Troubleshooting

If `up.sh`'s health-check loop times out, tail the actual boot log (this
is the single most useful command here — it shows every step: apt-get,
k3s install, node-ready wait, git clone, kubectl apply):

```bash
$(terraform output -raw bootstrap_log_command)
```

If SSH itself times out, your detected IP may have changed since apply
(rare mid-session, common if you're on mobile tethering) — re-run
`./up.sh`, which will detect the new IP and Terraform will update the
security group in place (no instance replacement needed for that
change).

If Terraform reports a Spot capacity error on `apply` (only possible with
`use_spot = true`), that specific instance type is temporarily
unavailable in that AZ — either retry, or raise `var.instance_type` to
something more available via `TF_VAR_instance_type=t3.large ./up.sh`
(note: only `m7i-flex.large`/`c7i-flex.large`/`t3.micro`/`t3.small`/
`t4g.micro`/`t4g.small` are Free Tier–eligible, so switching type may
mean switching off the free hours too).

## Files

```
versions.tf          providers (aws, tls, local) — separate state from infra/terraform/
variables.tf          my_ip_cidr (required, no default — same "no stale placeholder" reasoning as infra/terraform's db_password), instance sizing, use_spot (off by default — see Cost), repo/branch to clone, vpc_cidr/public_subnet_cidr
vpc.tf                  this module's own minimal VPC — one public subnet, one AZ, IGW + route table, no NAT (see network.tf's comment for why)
network.tf             security group — SSH + NodePort 30080 restricted to your IP; 6443 deliberately not exposed
key_pair.tf            Terraform-generated SSH keypair (private key written to ./velocity-dispatch-k3s.pem, already .gitignore'd)
main.tf                 the instance itself — on-demand by default (Free Tier), optional Spot via use_spot
user-data.sh.tpl        cloud-init: installs k3s, waits for Ready, clones the repo, runs kubectl apply -k k8s/base/
outputs.tf              public_ip, vpc_id, ssh_command, api_url, bootstrap_log_command
up.sh / down.sh          the two commands you actually run day to day
```

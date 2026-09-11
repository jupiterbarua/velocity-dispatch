# Terraform commands — velocity-dispatch-k3s

Run all of these from `infra/terraform-ec2-k3s/` unless noted otherwise.

## One-time setup

```bash
chmod +x up.sh down.sh
terraform init            # downloads aws/tls/local providers, sets up local state
```

Re-run `terraform init` any time you pull changes that add a new provider
or module (e.g. the vpc.tf addition needed one, even though it only added
resources from the already-installed aws provider).

## Everyday use

```bash
./up.sh                   # detects your IP, applies, waits for /health, prints URLs
# ...do your testing...
./down.sh                 # destroys everything cleanly
```

`up.sh`/`down.sh` are thin wrappers around the raw commands below — use
the raw commands directly when you want more control than the scripts
give you.

## Raw Terraform commands (what up.sh/down.sh call, plus useful extras)

```bash
# See exactly what would change before committing to it — always safe,
# never creates/destroys anything
terraform plan

# Same as up.sh's apply step, but interactive (asks "yes" instead of
# auto-approving) — good the first time so you can read the plan
terraform apply

# What up.sh actually runs — skips the confirmation prompt
terraform apply -auto-approve

# Check config syntax without touching AWS
terraform validate

# Auto-format .tf files to canonical style
terraform fmt

# List every resource Terraform currently manages in this module's state
terraform state list

# Show full details of one resource from state
terraform state show aws_instance.k3s

# Print all outputs (public_ip, vpc_id, ssh_command, api_url, bootstrap_log_command)
terraform output

# Print one output raw (no quotes) — used to build the ssh/curl commands below
terraform output -raw api_url
terraform output -raw ssh_command
terraform output -raw bootstrap_log_command

# What down.sh actually runs
terraform destroy -auto-approve

# Same, interactive — asks "yes" first
terraform destroy
```

## Overriding variables for one run

```bash
# Use Spot pricing instead of on-demand (see variables.tf — off by
# default so Free Tier hours actually apply)
TF_VAR_use_spot=true ./up.sh

# Try a different instance type (note: only m7i-flex.large/c7i-flex.large/
# t3.micro/t3.small/t4g.micro/t4g.small are Free Tier eligible)
TF_VAR_instance_type=t3.large ./up.sh

# Point at a different branch of the repo
TF_VAR_repo_ref=my-feature-branch ./up.sh
```

## Watching the deployment / checking logs while it's in progress

`terraform apply` itself streams progress live in your terminal — every
resource (VPC, subnet, IGW, route table, security group, keypair,
instance) prints as it's created, no extra step needed for that part.

The part that takes the real time (2-4 minutes) happens *inside* the
instance after Terraform is done: k3s installing, images pulling, the
repo cloning, `kubectl apply` running. That's cloud-init/user-data, and
it logs to `/var/log/velocity-dispatch-bootstrap.log` on the box. Once
`terraform apply` has finished (so the instance exists and its IP is
known), you don't have to wait for `up.sh`'s health-check loop to finish
or time out — you can tail that log yourself in a second terminal at any
point:

```bash
$(terraform output -raw bootstrap_log_command)
```

which expands to something like:

```bash
ssh -o StrictHostKeyChecking=accept-new -i velocity-dispatch-k3s.pem ubuntu@<ip> \
  'tail -f /var/log/velocity-dispatch-bootstrap.log'
```

SSH is reachable within the first ~30-60 seconds of the instance
launching (way before cloud-init finishes), so this works well before
`up.sh` itself reports success.

If SSH isn't answering yet (or at all) and you need to know why, fall
back to the raw EC2 console output — this captures what happened before
sshd or networking came up, which our own log file (only reachable over
SSH) can't show you:

```bash
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=velocity-dispatch-k3s" \
            "Name=instance-state-name,Values=running" \
  --query "Reservations[].Instances[].InstanceId" --output text

aws ec2 get-console-output --instance-id <instance-id> --output text
```

You can also just watch the instance in the AWS Console:
EC2 → Instances → filter by the `velocity-dispatch-k3s` Name tag →
**Actions → Monitor and troubleshoot → Get system log**.

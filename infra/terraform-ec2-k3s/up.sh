#!/usr/bin/env bash
# Creates the Spot instance, waits for k3s + the app to bootstrap, then
# confirms dispatch-api is actually answering before handing control back
# to you. Run ./down.sh when you're done for the day — see README.md for
# why "destroy fully" rather than "stop" is the right model for a Spot
# instance you use ~3hrs/day.
set -euo pipefail
cd "$(dirname "$0")"

if [ -z "${TF_VAR_my_ip_cidr:-}" ]; then
  MY_IP="$(curl -s https://checkip.amazonaws.com)"
  export TF_VAR_my_ip_cidr="${MY_IP}/32"
  echo "Detected your public IP as ${MY_IP} — restricting SSH/API access to ${TF_VAR_my_ip_cidr}"
  echo "(set TF_VAR_my_ip_cidr yourself beforehand to override this)"
fi

terraform init -input=false
terraform apply -auto-approve

API_URL="$(terraform output -raw api_url)"

echo ""
echo "Instance is up. Waiting for k3s + the app to bootstrap (this typically takes 2-4 minutes: apt-get, k3s install, image pulls, kubectl apply)..."
echo "If this takes much longer than that, Ctrl+C and check progress yourself:"
echo "  $(terraform output -raw bootstrap_log_command)"
echo ""

for i in $(seq 1 20); do
  if curl -sf "${API_URL}/health" >/dev/null 2>&1; then
    echo "Up! ${API_URL}/health is responding."
    echo ""
    echo "SSH in with:  $(terraform output -raw ssh_command)"
    echo "Load-test with:  k6 run -e BASE_URL=${API_URL} ../../loadtest/orders.js"
    exit 0
  fi
  echo "  not ready yet, retrying in 15s (${i}/20)..."
  sleep 15
done

echo ""
echo "Still not responding after ~5 minutes. Check what's happening:"
echo "  $(terraform output -raw bootstrap_log_command)"
exit 1

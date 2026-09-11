#!/bin/bash
# Cloud-init user-data — runs once as root at first boot. This file is
# processed by Terraform's templatefile() first, but templatefile() only
# treats a dollar sign immediately followed by an open brace as
# something to interpret — a bare $, on its own or followed by ( or a
# variable name, has no special meaning to it and passes straight
# through unchanged. So the plain shell command substitutions and shell
# variable references below need no escaping at all. The only real
# interpolations in this file are repo_ref and repo_url (passed in from
# main.tf, used a few lines down in the git clone command) — those are
# deliberately left unescaped so Terraform actually substitutes them.
set -euxo pipefail
exec > /var/log/velocity-dispatch-bootstrap.log 2>&1

echo "=== velocity-dispatch k3s bootstrap starting $(date) ==="

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y git curl

PUBLIC_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)
echo "Public IP: $PUBLIC_IP"

# k3s bundles its own containerd — no separate Docker install needed here,
# unlike k3d on the Mac (which needs Docker because it runs k3s *inside*
# Docker containers). This is k3s running directly on the host.
curl -sfL https://get.k3s.io | sh -

echo "Waiting for the k3s node to be Ready..."
until /usr/local/bin/kubectl get nodes 2>/dev/null | grep -q " Ready"; do
  sleep 5
done
echo "Node Ready."

# The k3s installer's kubeconfig (/etc/rancher/k3s/k3s.yaml) is root-only
# by default. Copying it into the ubuntu user's home means an SSH session
# as `ubuntu` can run plain `kubectl ...` with no sudo, same as any normal
# workstation kubeconfig.
mkdir -p /home/ubuntu/.kube
cp /etc/rancher/k3s/k3s.yaml /home/ubuntu/.kube/config
chown -R ubuntu:ubuntu /home/ubuntu/.kube

git clone --depth 1 --branch "${repo_ref}" "${repo_url}" /opt/velocity-dispatch
cd /opt/velocity-dispatch
/usr/local/bin/kubectl apply -k k8s/base/

echo "=== bootstrap complete $(date) ==="

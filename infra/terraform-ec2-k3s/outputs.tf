output "public_ip" {
  value = aws_instance.k3s.public_ip
}

output "vpc_id" {
  description = "This module's own VPC (see vpc.tf) — not the account default."
  value       = aws_vpc.main.id
}

output "ssh_command" {
  value = "ssh -o StrictHostKeyChecking=accept-new -i ${local_sensitive_file.private_key.filename} ubuntu@${aws_instance.k3s.public_ip}"
}

output "api_url" {
  description = "dispatch-api's NodePort, reachable directly — no port-mapping needed on a real EC2 box the way k3d needed on the Mac."
  value       = "http://${aws_instance.k3s.public_ip}:30080"
}

output "bootstrap_log_command" {
  description = "Tail cloud-init's progress (k3s install -> node ready -> git clone -> kubectl apply) while up.sh's health-check loop is waiting."
  value       = "ssh -o StrictHostKeyChecking=accept-new -i ${local_sensitive_file.private_key.filename} ubuntu@${aws_instance.k3s.public_ip} 'tail -f /var/log/velocity-dispatch-bootstrap.log'"
}

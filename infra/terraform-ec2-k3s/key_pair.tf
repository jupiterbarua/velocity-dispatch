# Terraform generates a fresh SSH keypair every time this is applied,
# rather than you having to create/import one by hand first. The private
# key lands at ./velocity-dispatch-k3s.pem in this directory —
# .gitignore's existing `*.pem` rule already covers it, so it can never
# accidentally get committed.
resource "tls_private_key" "ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "k3s" {
  key_name   = "${var.name_prefix}-key"
  public_key = tls_private_key.ssh.public_key_openssh
}

resource "local_sensitive_file" "private_key" {
  content         = tls_private_key.ssh.private_key_pem
  filename        = "${path.module}/velocity-dispatch-k3s.pem"
  file_permission = "0600"
}

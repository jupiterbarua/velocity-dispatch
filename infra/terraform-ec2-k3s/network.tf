# Own minimal VPC instead of the default one (see vpc.tf) — still just a
# single public subnet, no NAT gateway, no private subnets. That part of
# the original reasoning holds: this box is up ~3 hours a day and
# destroyed, so the NAT-gateway cost/complexity of a "real" private-subnet
# layout still isn't worth it here. What changed is not wanting this
# module's security group and instance sitting in the account's default
# VPC alongside whatever else lives there — a dedicated VPC keeps this
# module's blast radius (and its aws_security_group's default rules)
# fully self-contained, at zero extra cost (a VPC, subnet, IGW and route
# table are all free; you only pay for the NAT gateway we're still not
# using).
resource "aws_security_group" "k3s" {
  name        = "${var.name_prefix}-sg"
  description = "SSH + dispatch-api NodePort, both restricted to your current IP only"
  vpc_id      = aws_vpc.main.id

  # AWS restricts ingress/egress rule descriptions to a narrow ASCII
  # charset (no em dashes, no apostrophes) - that's why these two read a
  # little flatter than the rest of this project's comments.
  ingress {
    description = "SSH - for kubectl and debugging on the box itself"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.my_ip_cidr]
  }

  ingress {
    description = "dispatch-api NodePort Service (see k8s/base/dispatch-api.yaml) - what curl and k6 hit directly, no port-mapping trick needed like the k3d --port flag on the Mac"
    from_port   = 30080
    to_port     = 30080
    protocol    = "tcp"
    cidr_blocks = [var.my_ip_cidr]
  }

  # Deliberately NOT opening 6443 (the k8s API server) to the internet —
  # kubectl usage happens over SSH on the box itself instead (see
  # user-data.sh.tpl, which copies /etc/rancher/k3s/k3s.yaml into the
  # ubuntu user's ~/.kube/config). Smaller attack surface than exposing the
  # cluster API remotely, at the cost of needing an SSH session to run
  # kubectl — a reasonable trade for a box that only exists a few hours a
  # day.
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

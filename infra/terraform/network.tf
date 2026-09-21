# Custom VPC, not the account's default one. An earlier version of this file
# used the default VPC as a deliberate portfolio-project scope cut — fast to
# stand up, and no NAT Gateway cost since everything just sat in a public
# subnet. Replaced with a proper private-subnet design: dispatch-api and
# dispatch-worker's Fargate tasks and the RDS instance have no direct route
# to the internet and are not reachable from it at all — only the ALB sits
# in a public subnet, and only it can be reached from outside the VPC.
#
# Two AZs, looked up dynamically rather than hardcoded (e.g. "us-east-1a")
# so this doesn't break in an account/region where a particular AZ isn't
# opted in.

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  az_a = data.aws_availability_zones.available.names[0]
  az_b = data.aws_availability_zones.available.names[1]
}

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "velocity-dispatch-${var.environment}"
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "velocity-dispatch-${var.environment}"
  }
}

# --- Public subnets: ALB and the NAT Gateway only, nothing else ------------

resource "aws_subnet" "public_a" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.0.0/24"
  availability_zone       = local.az_a
  map_public_ip_on_launch = true

  tags = {
    Name = "velocity-dispatch-public-a-${var.environment}"
  }
}

resource "aws_subnet" "public_b" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = local.az_b
  map_public_ip_on_launch = true

  tags = {
    Name = "velocity-dispatch-public-b-${var.environment}"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "velocity-dispatch-public-${var.environment}"
  }
}

resource "aws_route_table_association" "public_a" {
  subnet_id      = aws_subnet.public_a.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public_b" {
  subnet_id      = aws_subnet.public_b.id
  route_table_id = aws_route_table.public.id
}

# --- Private subnets: ECS Fargate tasks and RDS -----------------------------

resource "aws_subnet" "private_a" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.10.0/24"
  availability_zone = local.az_a

  tags = {
    Name = "velocity-dispatch-private-a-${var.environment}"
  }
}

resource "aws_subnet" "private_b" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.11.0/24"
  availability_zone = local.az_b

  tags = {
    Name = "velocity-dispatch-private-b-${var.environment}"
  }
}

# --- NAT Gateway: a single one, shared across both private subnets --------
#
# Same cost-conscious trade-off this repo already makes elsewhere (single-AZ
# RDS, db.t4g.micro): one NAT Gateway instead of one per AZ is roughly half
# the monthly cost, at the price of private-subnet outbound traffic being
# briefly unavailable if that gateway's AZ has an outage. A real production
# deployment would run one NAT Gateway per AZ so a single-AZ outage can't
# take down outbound connectivity for every task.

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name = "velocity-dispatch-nat-${var.environment}"
  }
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public_a.id

  tags = {
    Name = "velocity-dispatch-${var.environment}"
  }

  depends_on = [aws_internet_gateway.main]
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = {
    Name = "velocity-dispatch-private-${var.environment}"
  }
}

resource "aws_route_table_association" "private_a" {
  subnet_id      = aws_subnet.private_a.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "private_b" {
  subnet_id      = aws_subnet.private_b.id
  route_table_id = aws_route_table.private.id
}

# --- Security groups --------------------------------------------------------
# Same chain as before this change: internet -> alb -> ecs_service -> rds,
# each only reachable from the one before it. Now scoped to this VPC instead
# of the account's default one.

resource "aws_security_group" "alb" {
  name        = "velocity-dispatch-alb-${var.environment}"
  description = "Allow inbound HTTP to the dispatch-api ALB"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTP from anywhere"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "ecs_service" {
  name        = "velocity-dispatch-ecs-${var.environment}"
  description = "dispatch-api / dispatch-worker Fargate tasks"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "API traffic from the ALB only"
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "rds" {
  name        = "velocity-dispatch-rds-${var.environment}"
  description = "Postgres access from ECS tasks only"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "Postgres from the ECS services"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs_service.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

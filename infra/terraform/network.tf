# Uses the account's default VPC/subnets rather than provisioning a custom
# one. That's a deliberate scope cut for a portfolio project — a production
# deployment of this system would use private subnets for the ECS tasks and
# RDS instance behind a NAT gateway, with only the ALB in public subnets.
# Wiring that up is mechanical (a `terraform-aws-modules/vpc/aws` module
# call plus moving the `subnet_ids` references below to the private set) but
# adds cost (NAT gateway) and complexity that isn't the point of this repo,
# which is the application/event architecture. See README "What I'd change
# for a real production deployment".

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

resource "aws_security_group" "alb" {
  name        = "velocity-dispatch-alb-${var.environment}"
  description = "Allow inbound HTTP to the dispatch-api ALB"
  vpc_id      = data.aws_vpc.default.id

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
  vpc_id      = data.aws_vpc.default.id

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
  vpc_id      = data.aws_vpc.default.id

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

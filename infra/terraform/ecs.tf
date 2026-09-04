resource "aws_ecs_cluster" "dispatch" {
  name = "velocity-dispatch-${var.environment}"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

resource "aws_cloudwatch_log_group" "api" {
  name              = "/ecs/velocity-dispatch-api-${var.environment}"
  retention_in_days = 14
}

resource "aws_cloudwatch_log_group" "worker" {
  name              = "/ecs/velocity-dispatch-worker-${var.environment}"
  retention_in_days = 14
}

locals {
  db_url = "postgres://${var.db_username}:${var.db_password}@${aws_db_instance.dispatch.address}:5432/dispatch"
}

resource "aws_ecs_task_definition" "api" {
  family                   = "velocity-dispatch-api-${var.environment}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.api_task_cpu
  memory                   = var.api_task_memory
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([{
    name  = "dispatch-api"
    image = "${aws_ecr_repository.repo["api"].repository_url}:${var.container_image_tag}"
    portMappings = [{
      containerPort = 8080
      protocol      = "tcp"
    }]
    environment = [
      { name = "DATABASE_URL", value = local.db_url },
      { name = "SQS_ORDER_QUEUE_URL", value = aws_sqs_queue.order_created.url },
      { name = "BIND_ADDR", value = "0.0.0.0:8080" },
      { name = "RUST_LOG", value = "info" },
    ]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.api.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "api"
      }
    }
  }])
}

resource "aws_ecs_task_definition" "worker" {
  family                   = "velocity-dispatch-worker-${var.environment}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.worker_task_cpu
  memory                   = var.worker_task_memory
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([{
    name  = "dispatch-worker"
    image = "${aws_ecr_repository.repo["worker"].repository_url}:${var.container_image_tag}"
    environment = [
      { name = "DATABASE_URL", value = local.db_url },
      { name = "SQS_ORDER_QUEUE_URL", value = aws_sqs_queue.order_created.url },
      { name = "EVENT_BUS_NAME", value = aws_cloudwatch_event_bus.dispatch.name },
      { name = "RUST_LOG", value = "info" },
      { name = "ENVIRONMENT", value = var.environment }, # dimension on every EMF metric — see services/dispatch-worker/src/metrics.rs
    ]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.worker.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "worker"
      }
    }
  }])
}

resource "aws_lb" "api" {
  name               = "velocity-dispatch-${var.environment}"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = data.aws_subnets.default.ids
}

resource "aws_lb_target_group" "api" {
  name        = "velocity-dispatch-api-${var.environment}"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = data.aws_vpc.default.id
  target_type = "ip"

  health_check {
    path                = "/health"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_lb_listener" "api_http" {
  load_balancer_arn = aws_lb.api.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }
}

resource "aws_ecs_service" "api" {
  name            = "dispatch-api-${var.environment}"
  cluster         = aws_ecs_cluster.dispatch.id
  task_definition = aws_ecs_task_definition.api.arn
  desired_count   = var.api_desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = data.aws_subnets.default.ids
    security_groups  = [aws_security_group.ecs_service.id]
    assign_public_ip = true # default VPC subnets here are public; see network.tf note on production VPC layout
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.api.arn
    container_name    = "dispatch-api"
    container_port    = 8080
  }

  # Zero-downtime rolling deploys: ECS starts new tasks and waits for them to
  # pass the ALB health check before draining old ones, bounded by these two
  # percentages so capacity never drops below 100% nor exceeds 200% mid-deploy.
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200

  depends_on = [aws_lb_listener.api_http]
}

resource "aws_ecs_service" "worker" {
  name            = "dispatch-worker-${var.environment}"
  cluster         = aws_ecs_cluster.dispatch.id
  task_definition = aws_ecs_task_definition.worker.arn
  desired_count   = var.worker_desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = data.aws_subnets.default.ids
    security_groups  = [aws_security_group.ecs_service.id]
    assign_public_ip = true
  }
}

# --- ECS task execution role (pulls images from ECR, writes to CloudWatch Logs) ---

data "aws_iam_policy_document" "ecs_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ecs_execution" {
  name               = "velocity-dispatch-ecs-execution-${var.environment}"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

resource "aws_iam_role_policy_attachment" "ecs_execution_managed" {
  role       = aws_iam_role.ecs_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# --- ECS task role (what the running application code is allowed to call) ---
#
# Split deliberately from the execution role above: the execution role is
# "what ECS itself needs to start the container", the task role is "what
# the container's own AWS SDK calls are allowed to do". Collapsing these
# into one role is a common over-permissioning mistake — this repo keeps
# them separate on purpose, least-privilege per service.

resource "aws_iam_role" "ecs_task" {
  name               = "velocity-dispatch-ecs-task-${var.environment}"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

data "aws_iam_policy_document" "ecs_task_permissions" {
  statement {
    sid       = "PublishOrderCreated"
    actions   = ["sqs:SendMessage", "sqs:GetQueueAttributes"]
    resources = [aws_sqs_queue.order_created.arn]
  }

  statement {
    sid = "ConsumeOrderCreated"
    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
      "sqs:GetQueueUrl",
    ]
    resources = [aws_sqs_queue.order_created.arn]
  }

  statement {
    sid       = "PublishDispatchAssigned"
    actions   = ["events:PutEvents"]
    resources = [aws_cloudwatch_event_bus.dispatch.arn]
  }
}

resource "aws_iam_role_policy" "ecs_task_permissions" {
  name   = "velocity-dispatch-ecs-task-${var.environment}"
  role   = aws_iam_role.ecs_task.id
  policy = data.aws_iam_policy_document.ecs_task_permissions.json
}

# --- Lambda execution role ---

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda_notify" {
  name               = "velocity-dispatch-notify-lambda-${var.environment}"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy_attachment" "lambda_basic_logs" {
  role       = aws_iam_role.lambda_notify.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "lambda_permissions" {
  statement {
    sid       = "WriteAuditRecords"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.audit.arn}/*"]
  }

  statement {
    sid       = "PublishNotifications"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.notifications.arn]
  }
}

resource "aws_iam_role_policy" "lambda_permissions" {
  name   = "velocity-dispatch-notify-lambda-${var.environment}"
  role   = aws_iam_role.lambda_notify.id
  policy = data.aws_iam_policy_document.lambda_permissions.json
}

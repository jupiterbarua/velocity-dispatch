# One operational view tying together the metrics that already exist
# (SQS/ECS/ALB/Lambda — all AWS-published) and the two custom sources added
# alongside the alarms in monitoring.tf: the business metric in
# services/dispatch-worker/src/metrics.rs (match outcome + time-to-match)
# and the log-based ApplicationErrors metric. The point of putting these on
# one dashboard rather than leaving them as separate alarms: an alarm tells
# you *that* something's wrong, a dashboard is what you actually look at to
# understand *why* — e.g. "queue backlog is climbing AND time-to-match is
# climbing AND match outcomes are shifting toward no_driver_available" tells
# a very different story than "queue backlog is climbing" alone.

resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "velocity-dispatch-${var.environment}"

  dashboard_body = jsonencode({
    widgets = [
      {
        type = "text", x = 0, y = 0, width = 24, height = 1
        properties = {
          markdown = "# Velocity Dispatch — ${var.environment}\nOrder pipeline (top) → business outcome (middle) → infra health (bottom). See docs/SQS_DESIGN.md and docs/REQUIREMENTS.md NFR-7 for what each panel maps to."
        }
      },

      # --- Row 1: order pipeline (SQS) -------------------------------
      {
        type = "metric", x = 0, y = 1, width = 12, height = 6
        properties = {
          title  = "Order queue depth"
          region = var.aws_region
          stat   = "Average"
          period = 60
          view   = "timeSeries"
          metrics = [
            ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", aws_sqs_queue.order_created.name, { label = "order-created (main queue)" }],
            ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", aws_sqs_queue.order_created_dlq.name, { label = "order-created-dlq" }],
          ]
        }
      },
      {
        type = "metric", x = 12, y = 1, width = 12, height = 6
        properties = {
          title  = "Order publish/consume rate"
          region = var.aws_region
          stat   = "Sum"
          period = 60
          view   = "timeSeries"
          metrics = [
            ["AWS/SQS", "NumberOfMessagesSent", "QueueName", aws_sqs_queue.order_created.name, { label = "orders created" }],
            ["AWS/SQS", "NumberOfMessagesDeleted", "QueueName", aws_sqs_queue.order_created.name, { label = "orders acknowledged (matched or already-handled)" }],
          ]
        }
      },

      # --- Row 2: the business outcome (custom EMF metric) -----------
      {
        type = "metric", x = 0, y = 7, width = 12, height = 6
        properties = {
          title   = "Match outcomes by type"
          region  = var.aws_region
          view    = "timeSeries"
          stacked = true
          metrics = [
            [{ expression = "SEARCH('{VelocityDispatch/Worker,Environment,Outcome} MetricName=\"MatchCount\" Environment=\"${var.environment}\"', 'Sum', 60)", label = "MatchCount by Outcome", id = "e1" }]
          ]
        }
      },
      {
        type = "metric", x = 12, y = 7, width = 12, height = 6
        properties = {
          title  = "Time to match (p50 / p90)"
          region = var.aws_region
          view   = "timeSeries"
          metrics = [
            [{ expression = "SEARCH('{VelocityDispatch/Worker,Environment,Outcome} MetricName=\"TimeToMatchMs\" Environment=\"${var.environment}\" Outcome=\"assigned\"', 'p50', 60)", label = "p50, successful matches only", id = "e2" }],
            [{ expression = "SEARCH('{VelocityDispatch/Worker,Environment,Outcome} MetricName=\"TimeToMatchMs\" Environment=\"${var.environment}\" Outcome=\"assigned\"', 'p90', 60)", label = "p90, successful matches only", id = "e3" }],
          ]
        }
      },

      # --- Row 3: ECS + ALB ------------------------------------------
      {
        type = "metric", x = 0, y = 13, width = 12, height = 6
        properties = {
          title  = "ECS running tasks vs. desired"
          region = var.aws_region
          stat   = "Average"
          period = 60
          view   = "timeSeries"
          metrics = [
            ["ECS/ContainerInsights", "RunningTaskCount", "ClusterName", aws_ecs_cluster.dispatch.name, "ServiceName", aws_ecs_service.api.name, { label = "dispatch-api running" }],
            ["ECS/ContainerInsights", "RunningTaskCount", "ClusterName", aws_ecs_cluster.dispatch.name, "ServiceName", aws_ecs_service.worker.name, { label = "dispatch-worker running" }],
          ]
        }
      },
      {
        type = "metric", x = 12, y = 13, width = 12, height = 6
        properties = {
          title  = "dispatch-api: requests, latency, 5xx"
          region = var.aws_region
          period = 60
          view   = "timeSeries"
          metrics = [
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", aws_lb.api.arn_suffix, { stat = "Sum", label = "requests" }],
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", aws_lb.api.arn_suffix, { stat = "p99", label = "p99 latency (s)", yAxis = "right" }],
            ["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "LoadBalancer", aws_lb.api.arn_suffix, { stat = "Sum", label = "5xx count" }],
          ]
        }
      },

      # --- Row 4: Lambda + application error rate ---------------------
      {
        type = "metric", x = 0, y = 19, width = 12, height = 6
        properties = {
          title  = "dispatch-notify-lambda"
          region = var.aws_region
          period = 60
          view   = "timeSeries"
          metrics = [
            ["AWS/Lambda", "Invocations", "FunctionName", aws_lambda_function.notify.function_name, { stat = "Sum", label = "invocations" }],
            ["AWS/Lambda", "Errors", "FunctionName", aws_lambda_function.notify.function_name, { stat = "Sum", label = "errors" }],
            ["AWS/Lambda", "Duration", "FunctionName", aws_lambda_function.notify.function_name, { stat = "p99", label = "p99 duration (ms)", yAxis = "right" }],
          ]
        }
      },
      {
        type = "metric", x = 12, y = 19, width = 12, height = 6
        properties = {
          title  = "Application errors (log-based) by service"
          region = var.aws_region
          view   = "timeSeries"
          metrics = [
            [{ expression = "SEARCH('{VelocityDispatch/Logs,Service} MetricName=\"ApplicationErrors\"', 'Sum', 300)", label = "ERROR-level log lines by service", id = "e4" }]
          ]
        }
      },
    ]
  })
}

output "dashboard_url" {
  description = "Direct link — paste into a browser once the console session is authenticated to this account."
  value       = "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards:name=${aws_cloudwatch_dashboard.main.dashboard_name}"
}

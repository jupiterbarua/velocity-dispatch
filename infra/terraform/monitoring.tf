# Operational alarms — the difference between "we found out about the
# incident from a customer" and "we found out from CloudWatch." This is a
# deliberately small, high-signal set rather than an alarm-on-everything
# dashboard: each one maps to a specific failure mode called out elsewhere
# in this repo (README "Low-latency decisions", REQUIREMENTS.md NFR-4/NFR-7).

resource "aws_sns_topic" "ops_alerts" {
  name = "velocity-dispatch-ops-alerts-${var.environment}"
}

# --- SQS: main queue backing up ---------------------------------------
#
# A sustained backlog on the main queue means dispatch-worker isn't keeping
# up — either it's down, its DB connection pool is saturated (see
# Config::db_max_connections), or order volume has genuinely outgrown
# max_in_flight. Threshold of 100 visible messages sustained for 3
# consecutive 1-minute periods is a starting point, not a law — tune it
# against real traffic once there's a production baseline (see the
# README's load-test section for how to establish one).
resource "aws_cloudwatch_metric_alarm" "queue_backlog" {
  alarm_name          = "velocity-dispatch-queue-backlog-${var.environment}"
  alarm_description   = "order-created queue has >100 visible messages for 3 consecutive minutes — dispatch-worker may be falling behind or down"
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  dimensions          = { QueueName = aws_sqs_queue.order_created.name }
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 3
  threshold           = 100
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.ops_alerts.arn]
  ok_actions    = [aws_sns_topic.ops_alerts.arn]
}

# --- SQS: dead-letter queue receiving messages -------------------------
#
# Any message here means an order failed matching 5 times in a row (see
# the redrive_policy in sqs.tf) — by definition something a human needs to
# look at, so the threshold is deliberately ">0", not a tolerance band.
resource "aws_cloudwatch_metric_alarm" "dlq_not_empty" {
  alarm_name          = "velocity-dispatch-dlq-not-empty-${var.environment}"
  alarm_description   = "order-created-dlq has 1+ messages — an order exhausted its retry budget and needs manual follow-up"
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  dimensions          = { QueueName = aws_sqs_queue.order_created_dlq.name }
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.ops_alerts.arn]
}

# --- ECS: dispatch-api running below desired count ----------------------
#
# Catches crash-looping tasks, failed deploys, and capacity issues that a
# pure latency/error-rate alarm can miss if the ALB is still routing to a
# shrinking healthy pool.
resource "aws_cloudwatch_metric_alarm" "api_running_below_desired" {
  alarm_name        = "velocity-dispatch-api-tasks-below-desired-${var.environment}"
  alarm_description = "dispatch-api has fewer running tasks than desired_count for 2 consecutive minutes"
  namespace         = "ECS/ContainerInsights"
  metric_name       = "RunningTaskCount"
  dimensions = {
    ClusterName = aws_ecs_cluster.dispatch.name
    ServiceName = aws_ecs_service.api.name
  }
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 2
  threshold           = var.api_desired_count
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"

  alarm_actions = [aws_sns_topic.ops_alerts.arn]
  ok_actions    = [aws_sns_topic.ops_alerts.arn]
}

# --- ALB: elevated 5xx rate from dispatch-api ---------------------------
resource "aws_cloudwatch_metric_alarm" "api_5xx_rate" {
  alarm_name        = "velocity-dispatch-api-5xx-${var.environment}"
  alarm_description = "dispatch-api target group returned 10+ HTTP 5xx responses in a 1-minute window"
  namespace         = "AWS/ApplicationELB"
  metric_name       = "HTTPCode_Target_5XX_Count"
  dimensions = {
    LoadBalancer = aws_lb.api.arn_suffix
    TargetGroup  = aws_lb_target_group.api.arn_suffix
  }
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 10
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.ops_alerts.arn]
}

# --- Application-level error rate (log-based) ---------------------------
#
# The alarms above only see infrastructure symptoms — queue depth, task
# count, 5xx responses. None of them catch, say, a bug that makes every
# `POST /orders` return 201 but silently fail to persist correctly, or a
# spike in `tracing::error!` calls from a downstream dependency acting up
# in a way that doesn't (yet) show up as an ALB error. A metric filter over
# each service's own structured logs closes that gap.
#
# One filter + one alarm *per service* rather than a single combined metric
# — deliberately, so the alarm notification itself answers "which service"
# without anyone needing to go look. `tracing_subscriber`'s JSON formatter
# (see each service's `telemetry.rs`/`init_telemetry`) always emits a
# top-level `"level"` field, which is what the filter pattern matches on.

locals {
  service_log_groups = {
    dispatch-api    = aws_cloudwatch_log_group.api.name
    dispatch-worker = aws_cloudwatch_log_group.worker.name
    notify-lambda   = aws_cloudwatch_log_group.notify_lambda.name
  }
}

resource "aws_cloudwatch_log_metric_filter" "app_errors" {
  for_each = local.service_log_groups

  name           = "velocity-dispatch-${each.key}-errors-${var.environment}"
  log_group_name = each.value
  pattern        = "{ $.level = \"ERROR\" }"

  metric_transformation {
    name          = "ApplicationErrors"
    namespace     = "VelocityDispatch/Logs"
    value         = "1"
    default_value = "0" # publish an explicit 0 for quiet periods, so the alarm always has a real datapoint rather than relying on treat_missing_data
    unit          = "Count"
    dimensions    = { Service = each.key }
  }
}

resource "aws_cloudwatch_metric_alarm" "app_error_rate" {
  for_each = local.service_log_groups

  alarm_name          = "velocity-dispatch-${each.key}-error-spike-${var.environment}"
  alarm_description   = "5+ ERROR-level log lines from ${each.key} in a 5-minute window"
  namespace           = "VelocityDispatch/Logs"
  metric_name         = "ApplicationErrors"
  dimensions          = { Service = each.key }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 5
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.ops_alerts.arn]

  depends_on = [aws_cloudwatch_log_metric_filter.app_errors]
}

output "ops_alerts_topic_arn" {
  description = "Subscribe an email/Slack/PagerDuty integration to this topic to actually receive the alarms above."
  value       = aws_sns_topic.ops_alerts.arn
}

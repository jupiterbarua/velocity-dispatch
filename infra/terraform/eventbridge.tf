resource "aws_cloudwatch_event_bus" "dispatch" {
  name = "velocity-dispatch-bus-${var.environment}"
}

resource "aws_cloudwatch_event_rule" "dispatch_assigned" {
  name           = "dispatch-assigned-${var.environment}"
  event_bus_name = aws_cloudwatch_event_bus.dispatch.name

  # Matches dispatch_core::DispatchAssigned::{SOURCE, DETAIL_TYPE} exactly —
  # those two Rust constants and this pattern must stay in sync, which is
  # exactly the kind of cross-repo contract that's worth a short comment on
  # both ends (see crates/dispatch-core/src/events.rs).
  event_pattern = jsonencode({
    source      = ["velocity.dispatch"]
    detail-type = ["DispatchAssigned"]
  })
}

resource "aws_cloudwatch_event_target" "notify_lambda" {
  event_bus_name = aws_cloudwatch_event_bus.dispatch.name
  rule           = aws_cloudwatch_event_rule.dispatch_assigned.name
  target_id      = "dispatch-notify-lambda"
  arn            = aws_lambda_function.notify.arn

  retry_policy {
    maximum_event_age_in_seconds = 3600
    maximum_retry_attempts       = 3
  }

  dead_letter_config {
    arn = aws_sqs_queue.eventbridge_dlq.arn
  }
}

# A second, small DLQ specifically for EventBridge-to-Lambda delivery
# failures (distinct from the SQS order-processing DLQ above) — EventBridge
# targets support their own dead-letter config independent of the queue the
# worker consumes from.
resource "aws_sqs_queue" "eventbridge_dlq" {
  name                      = "dispatch-assigned-target-dlq-${var.environment}"
  message_retention_seconds = 1209600
}

resource "aws_sqs_queue_policy" "eventbridge_dlq_policy" {
  queue_url = aws_sqs_queue.eventbridge_dlq.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowEventBridgeSend"
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.eventbridge_dlq.arn
      Condition = {
        ArnEquals = { "aws:SourceArn" = aws_cloudwatch_event_rule.dispatch_assigned.arn }
      }
    }]
  })
}

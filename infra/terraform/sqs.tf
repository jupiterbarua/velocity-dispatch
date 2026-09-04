# Dead-letter queue first, main queue second, so the main queue's
# redrive_policy can reference the DLQ's ARN. A message that fails
# processing (see dispatch-worker's AssignOutcome::NoDriverAvailable path)
# is redelivered up to `maxReceiveCount` times before landing here for a
# human/ops process to inspect — the standard SQS resilience pattern, and
# one directly informed by production incident-investigation experience
# (see CV: "investigated production issues... captured for operational
# follow-up").

resource "aws_sqs_queue" "order_created_dlq" {
  name                      = "order-created-dlq-${var.environment}"
  message_retention_seconds = 1209600 # 14 days — max SQS allows, gives ops the longest possible window to redrive
}

resource "aws_sqs_queue" "order_created" {
  name                       = "order-created-${var.environment}"
  visibility_timeout_seconds = 30 # must be >= dispatch-worker's expected processing time per message
  message_retention_seconds  = 345600 # 4 days

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.order_created_dlq.arn
    maxReceiveCount      = 5
  })
}

resource "aws_sqs_queue_redrive_allow_policy" "dlq_allow" {
  queue_url = aws_sqs_queue.order_created_dlq.id

  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.order_created.arn]
  })
}

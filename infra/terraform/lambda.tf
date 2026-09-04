# Deployed from the same ECR image build as the ECS services (see
# services/dispatch-notify-lambda/Dockerfile and .github/workflows/ci.yml) —
# one build pipeline for every deployable in the system, rather than a
# separate zip-upload path just for the one Lambda.

resource "aws_cloudwatch_log_group" "notify_lambda" {
  name              = "/aws/lambda/velocity-dispatch-notify-${var.environment}"
  retention_in_days = 14
}

resource "aws_lambda_function" "notify" {
  function_name = "velocity-dispatch-notify-${var.environment}"
  role          = aws_iam_role.lambda_notify.arn

  package_type = "Image"
  image_uri    = "${aws_ecr_repository.repo["lambda"].repository_url}:${var.container_image_tag}"

  # Rust cold starts on a Lambda container image are dominated by the image
  # pull/unpack rather than a VM/interpreter bootstrap, so this stays fast
  # without needing SnapStart-style tricks. 512MB gives a bit of headroom
  # over `provided.al2023`'s baseline without over-provisioning for what's
  # a very short-lived invocation.
  memory_size = 512
  timeout     = 10

  environment {
    variables = {
      AUDIT_BUCKET     = aws_s3_bucket.audit.bucket
      NOTIFY_TOPIC_ARN = aws_sns_topic.notifications.arn
      RUST_LOG         = "info"
    }
  }

  depends_on = [aws_cloudwatch_log_group.notify_lambda]
}

resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.notify.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.dispatch_assigned.arn
}

output "api_url" {
  description = "Public URL for dispatch-api"
  value       = "http://${aws_lb.api.dns_name}"
}

output "ecr_repository_urls" {
  value = { for k, v in aws_ecr_repository.repo : k => v.repository_url }
}

output "sqs_order_queue_url" {
  value = aws_sqs_queue.order_created.url
}

output "sqs_dlq_url" {
  value = aws_sqs_queue.order_created_dlq.url
}

output "event_bus_name" {
  value = aws_cloudwatch_event_bus.dispatch.name
}

output "audit_bucket" {
  value = aws_s3_bucket.audit.bucket
}

output "rds_endpoint" {
  value     = aws_db_instance.dispatch.address
  sensitive = true
}

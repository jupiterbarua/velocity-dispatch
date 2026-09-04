#!/usr/bin/env bash
# Runs automatically by LocalStack on container start (mounted into
# /etc/localstack/init/ready.d/). Provisions the same primitives that
# infra/terraform provisions against real AWS, so `docker compose up` gives
# you the full event pipeline — SQS -> worker -> EventBridge -> Lambda —
# without an AWS account or any cost.
set -euo pipefail

export AWS_ACCESS_KEY_ID=test
export AWS_SECRET_ACCESS_KEY=test
export AWS_DEFAULT_REGION=eu-central-1

endpoint="http://localhost:4566"

echo "[localstack-init] creating SQS dead-letter queue + main queue"
dlq_arn=$(awslocal sqs create-queue --queue-name order-created-dlq --query 'QueueUrl' --output text)
dlq_arn=$(awslocal sqs get-queue-attributes --queue-url "$dlq_arn" --attribute-names QueueArn --query 'Attributes.QueueArn' --output text)

redrive_policy=$(printf '{"deadLetterTargetArn":"%s","maxReceiveCount":5}' "$dlq_arn")
awslocal sqs create-queue --queue-name order-created \
  --attributes "RedrivePolicy='${redrive_policy//\"/\\\"}'" >/dev/null || \
  awslocal sqs create-queue --queue-name order-created >/dev/null

echo "[localstack-init] creating EventBridge custom bus + rule"
awslocal events create-event-bus --name velocity-dispatch-bus >/dev/null || true

awslocal events put-rule \
  --name dispatch-assigned-rule \
  --event-bus-name velocity-dispatch-bus \
  --event-pattern '{"source":["velocity.dispatch"],"detail-type":["DispatchAssigned"]}' >/dev/null

echo "[localstack-init] creating S3 audit bucket + SNS notification topic"
awslocal s3 mb s3://velocity-dispatch-audit >/dev/null || true
awslocal sns create-topic --name velocity-dispatch-notifications >/dev/null || true

echo "[localstack-init] done — queue/bus/rule/bucket/topic ready"

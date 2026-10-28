#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

echo "Checking Concertpass worker AWS permissions..."

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"

echo "AWS account: $ACCOUNT_ID"
echo "Region: $AWS_REGION"

echo ""
echo "Checking DynamoDB table..."
aws dynamodb describe-table \
  --table-name "$DDB_TABLE" \
  --region "$AWS_REGION" \
  --query 'Table.[TableName,TableStatus]' \
  --output table

echo ""
echo "Checking SQS queue..."
QUEUE_URL="$(aws sqs get-queue-url \
  --queue-name "$QUEUE_NAME" \
  --region "$AWS_REGION" \
  --query 'QueueUrl' \
  --output text)"

aws sqs get-queue-attributes \
  --queue-url "$QUEUE_URL" \
  --attribute-names QueueArn VisibilityTimeout \
  --region "$AWS_REGION" \
  --query 'Attributes' \
  --output table

echo ""
echo "Checking EKS node groups..."
aws eks list-nodegroups \
  --cluster-name "$CLUSTER_NAME" \
  --region "$AWS_REGION" \
  --output table

echo ""
echo "Read-only checks completed."
echo "This script does not create, change, or delete AWS resources."

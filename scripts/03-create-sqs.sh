
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

echo "Checking SQS FIFO queue: $QUEUE_NAME"

QUEUE_URL="$(aws sqs get-queue-url \
  --queue-name "$QUEUE_NAME" \
  --region "$AWS_REGION" \
  --query 'QueueUrl' \
  --output text 2>/dev/null || true)"

if [[ -z "$QUEUE_URL" || "$QUEUE_URL" == "None" ]]; then
  echo "Creating FIFO queue..."

  QUEUE_URL="$(aws sqs create-queue \
    --queue-name "$QUEUE_NAME" \
    --attributes FifoQueue=true,ContentBasedDeduplication=false,VisibilityTimeout=60 \
    --region "$AWS_REGION" \
    --query 'QueueUrl' \
    --output text)"
else
  echo "Queue already exists: $QUEUE_URL"
fi

echo "Saving queue URL..."
save_state "SQS_QUEUE_URL" "$QUEUE_URL"

echo "Verifying queue configuration..."
aws sqs get-queue-attributes \
  --queue-url "$QUEUE_URL" \
  --attribute-names QueueArn FifoQueue VisibilityTimeout \
  --region "$AWS_REGION"

echo "SQS FIFO setup completed."


#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

echo "======================================"
echo " CONCERTPASS - AWS RESOURCE INVENTORY"
echo "======================================"
echo "Region: $AWS_REGION"
echo ""

echo "---- EKS cluster ----"
aws eks describe-cluster \
  --name "$CLUSTER_NAME" \
  --region "$AWS_REGION" \
  --query 'cluster.[name,status]' \
  --output table 2>/dev/null || echo "Cluster not found or unavailable."

echo ""
echo "---- DynamoDB table ----"
aws dynamodb describe-table \
  --table-name "$DDB_TABLE" \
  --region "$AWS_REGION" \
  --query 'Table.[TableName,TableStatus]' \
  --output table 2>/dev/null || echo "DynamoDB table not found."

echo ""
echo "---- SQS FIFO queue ----"
aws sqs get-queue-url \
  --queue-name "$QUEUE_NAME" \
  --region "$AWS_REGION" \
  --query 'QueueUrl' \
  --output text 2>/dev/null || echo "SQS queue not found."

echo ""
echo "---- RDS database ----"
aws rds describe-db-instances \
  --db-instance-identifier "$DB_ID" \
  --region "$AWS_REGION" \
  --query 'DBInstances[0].[DBInstanceIdentifier,DBInstanceStatus,Endpoint.Address]' \
  --output table 2>/dev/null || echo "RDS instance not found."

echo ""
echo "---- ECR repositories ----"
for service in ticket-api ticket-worker ticket-checkout; do
  aws ecr describe-repositories \
    --repository-names "$service" \
    --region "$AWS_REGION" \
    --query 'repositories[0].[repositoryName,repositoryUri]' \
    --output table 2>/dev/null || echo "ECR repository not found: $service"
done

echo ""
echo "Inventory finished. No resources were created or deleted."


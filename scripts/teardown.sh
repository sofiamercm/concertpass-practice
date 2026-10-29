#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

echo "======================================"
echo " CONCERTPASS - TEARDOWN"
echo "======================================"

if [[ "${CONCERTPASS_TEARDOWN_READY:-NO}" != "YES" ]]; then
  echo "STOP: Teardown is not approved yet."
  echo "Run it with: CONCERTPASS_TEARDOWN_READY=YES bash scripts/teardown.sh"
  exit 1
fi

echo "Region: $AWS_REGION"
echo "Cluster: $CLUSTER_NAME"
echo ""

# ---------------------------------------------------------------
# 1. Kubernetes resources
#    Deleted first so the pods stop using RDS, SQS and DynamoDB.
# ---------------------------------------------------------------
echo "---- 1/8 Kubernetes resources ----"
if aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
  aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION" >/dev/null

  kubectl delete deployment ticket-api ticket-worker ticket-checkout --ignore-not-found
  kubectl delete service ticket-api ticket-checkout --ignore-not-found
  kubectl delete configmap concertpass-config --ignore-not-found
  kubectl delete secret concertpass-db-secret concertpass-aws-secret --ignore-not-found
else
  echo "Cluster not found. Skipping Kubernetes resources."
fi
echo ""

# ---------------------------------------------------------------
# 2. RDS instance
#    It must be gone before its security group and before the
#    cluster VPC can be deleted.
# ---------------------------------------------------------------
echo "---- 2/8 RDS PostgreSQL ----"
if aws rds describe-db-instances --db-instance-identifier "$DB_ID" --region "$AWS_REGION" >/dev/null 2>&1; then
  echo "Deleting RDS instance: $DB_ID"
  aws rds delete-db-instance \
    --db-instance-identifier "$DB_ID" \
    --skip-final-snapshot \
    --delete-automated-backups \
    --region "$AWS_REGION" >/dev/null || true

  echo "Waiting for RDS to be deleted. This may take several minutes..."
  aws rds wait db-instance-deleted \
    --db-instance-identifier "$DB_ID" \
    --region "$AWS_REGION"
  echo "RDS instance deleted."
else
  echo "RDS instance not found."
fi
echo ""

# ---------------------------------------------------------------
# 3. RDS subnet group and security group
# ---------------------------------------------------------------
echo "---- 3/8 RDS subnet group and security group ----"
if aws rds describe-db-subnet-groups --db-subnet-group-name "$DB_SUBNET_GROUP" --region "$AWS_REGION" >/dev/null 2>&1; then
  aws rds delete-db-subnet-group \
    --db-subnet-group-name "$DB_SUBNET_GROUP" \
    --region "$AWS_REGION"
  echo "Subnet group deleted: $DB_SUBNET_GROUP"
else
  echo "Subnet group not found."
fi

DB_SG_ID="$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=$DB_SG_NAME" \
  --region "$AWS_REGION" \
  --query 'SecurityGroups[0].GroupId' \
  --output text 2>/dev/null || true)"

if [[ -n "$DB_SG_ID" && "$DB_SG_ID" != "None" ]]; then
  # The RDS network interfaces can take a moment to be released,
  # so the deletion is retried a few times.
  for attempt in 1 2 3 4 5 6; do
    if aws ec2 delete-security-group --group-id "$DB_SG_ID" --region "$AWS_REGION" 2>/dev/null; then
      echo "Security group deleted: $DB_SG_ID"
      break
    fi
    if [[ "$attempt" == "6" ]]; then
      echo "WARNING: Could not delete security group $DB_SG_ID. Delete it manually."
    else
      echo "Security group still in use. Retrying in 20 seconds..."
      sleep 20
    fi
  done
else
  echo "Security group not found."
fi
echo ""

# ---------------------------------------------------------------
# 4. Secrets Manager
#    Force delete so the same name can be reused right away.
# ---------------------------------------------------------------
echo "---- 4/8 Secrets Manager ----"
if aws secretsmanager describe-secret --secret-id "$SECRET_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
  aws secretsmanager delete-secret \
    --secret-id "$SECRET_NAME" \
    --force-delete-without-recovery \
    --region "$AWS_REGION" >/dev/null
  echo "Secret deleted: $SECRET_NAME"
else
  echo "Secret not found."
fi
echo ""

# ---------------------------------------------------------------
# 5. SQS FIFO queue
# ---------------------------------------------------------------
echo "---- 5/8 SQS FIFO queue ----"
QUEUE_URL="$(aws sqs get-queue-url \
  --queue-name "$QUEUE_NAME" \
  --region "$AWS_REGION" \
  --query 'QueueUrl' \
  --output text 2>/dev/null || true)"

if [[ -n "$QUEUE_URL" && "$QUEUE_URL" != "None" ]]; then
  aws sqs delete-queue --queue-url "$QUEUE_URL" --region "$AWS_REGION"
  echo "Queue deleted: $QUEUE_NAME"
else
  echo "Queue not found."
fi
echo ""

# ---------------------------------------------------------------
# 6. DynamoDB table
# ---------------------------------------------------------------
echo "---- 6/8 DynamoDB ----"
if aws dynamodb describe-table --table-name "$DDB_TABLE" --region "$AWS_REGION" >/dev/null 2>&1; then
  aws dynamodb delete-table --table-name "$DDB_TABLE" --region "$AWS_REGION" >/dev/null
  aws dynamodb wait table-not-exists --table-name "$DDB_TABLE" --region "$AWS_REGION"
  echo "Table deleted: $DDB_TABLE"
else
  echo "Table not found."
fi
echo ""

# ---------------------------------------------------------------
# 7. ECR repositories (with all their images)
# ---------------------------------------------------------------
echo "---- 7/8 ECR repositories ----"
for service in $SERVICES; do
  if aws ecr describe-repositories --repository-names "$service" --region "$AWS_REGION" >/dev/null 2>&1; then
    aws ecr delete-repository \
      --repository-name "$service" \
      --force \
      --region "$AWS_REGION" >/dev/null
    echo "Repository deleted: $service"
  else
    echo "Repository not found: $service"
  fi
done
echo ""

# ---------------------------------------------------------------
# 8. EKS cluster
#    Last, because eksctl also deletes the VPC and node group.
# ---------------------------------------------------------------
echo "---- 8/8 EKS cluster ----"
if aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
  echo "Deleting EKS cluster. This may take 10-15 minutes..."
  eksctl delete cluster \
    --name "$CLUSTER_NAME" \
    --region "$AWS_REGION" \
    --wait
  echo "Cluster deleted: $CLUSTER_NAME"
else
  echo "Cluster not found."
fi
echo ""

rm -f "$STATE_FILE"

# ---------------------------------------------------------------
# Final verification
# ---------------------------------------------------------------
echo "======================================"
echo " VERIFICATION"
echo "======================================"

check() {
  local label="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    echo "STILL EXISTS: $label"
  else
    echo "Deleted:      $label"
  fi
}

check "EKS cluster $CLUSTER_NAME" \
  aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION"
check "RDS instance $DB_ID" \
  aws rds describe-db-instances --db-instance-identifier "$DB_ID" --region "$AWS_REGION"
check "Secret $SECRET_NAME" \
  aws secretsmanager describe-secret --secret-id "$SECRET_NAME" --region "$AWS_REGION"
check "SQS queue $QUEUE_NAME" \
  aws sqs get-queue-url --queue-name "$QUEUE_NAME" --region "$AWS_REGION"
check "DynamoDB table $DDB_TABLE" \
  aws dynamodb describe-table --table-name "$DDB_TABLE" --region "$AWS_REGION"
for service in $SERVICES; do
  check "ECR repository $service" \
    aws ecr describe-repositories --repository-names "$service" --region "$AWS_REGION"
done

echo ""
echo "Concertpass teardown finished."

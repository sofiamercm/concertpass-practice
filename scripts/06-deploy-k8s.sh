#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

echo "Preparing Concertpass Kubernetes deployment..."

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
ECR_REGISTRY="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

CLUSTER_STATUS="$(aws eks describe-cluster \
  --name "$CLUSTER_NAME" \
  --region "$AWS_REGION" \
  --query 'cluster.status' \
  --output text)"

if [[ "$CLUSTER_STATUS" != "ACTIVE" ]]; then
  echo "ERROR: EKS cluster is not ACTIVE."
  exit 1
fi

for service in ticket-api ticket-worker ticket-checkout; do
  aws ecr describe-images \
    --repository-name "$service" \
    --image-ids imageTag=latest \
    --region "$AWS_REGION" >/dev/null
done

aws rds describe-db-instances \
  --db-instance-identifier "$DB_ID" \
  --region "$AWS_REGION" \
  --query 'DBInstances[0].DBInstanceStatus' \
  --output text >/dev/null

aws secretsmanager describe-secret \
  --secret-id "$SECRET_NAME" \
  --region "$AWS_REGION" >/dev/null

QUEUE_URL="$(aws sqs get-queue-url \
  --queue-name "$QUEUE_NAME" \
  --region "$AWS_REGION" \
  --query 'QueueUrl' \
  --output text)"

aws eks update-kubeconfig \
  --name "$CLUSTER_NAME" \
  --region "$AWS_REGION"

echo "Loading database credentials from AWS Secrets Manager..."

umask 077
SECRET_FILE="$(mktemp)"
MANIFEST_FILE="$(mktemp)"
trap 'rm -f "$SECRET_FILE" "$MANIFEST_FILE"' EXIT

aws secretsmanager get-secret-value \
  --secret-id "$SECRET_NAME" \
  --region "$AWS_REGION" \
  --query 'SecretString' \
  --output text > "$SECRET_FILE"

python3 - "$SECRET_FILE" "$QUEUE_URL" <<'PY' > "$MANIFEST_FILE"
import base64
import json
import sys

secret_path, queue_url = sys.argv[1], sys.argv[2]

with open(secret_path, encoding="utf-8") as file:
    data = json.load(file)

def get_value(*keys):
    for key in keys:
        value = data.get(key)
        if value:
            return str(value)
    raise SystemExit("ERROR: Required database credential is missing from Secrets Manager.")

values = {
    "DB_HOST": get_value("DB_HOST", "host", "endpoint"),
    "DB_USER": get_value("DB_USER", "username", "user"),
    "DB_PASSWORD": get_value("DB_PASSWORD", "password"),
}

def encode(value):
    return base64.b64encode(value.encode()).decode()

print("""apiVersion: v1
kind: Secret
metadata:
  name: concertpass-db-secret
type: Opaque
data:""")
for key, value in values.items():
    print(f"  {key}: {encode(value)}")

print("---")
print("""apiVersion: v1
kind: Secret
metadata:
  name: concertpass-aws-secret
type: Opaque
data:""")
print(f"  SQS_QUEUE_URL: {encode(queue_url)}")
PY

echo "Applying Kubernetes Secrets..."
kubectl apply -f "$MANIFEST_FILE"

echo "Applying ConfigMap and Services..."
kubectl apply -f "$ROOT_DIR/k8s/concertpass-config.yaml"
kubectl apply -f "$ROOT_DIR/k8s/ticket-api-service.yaml"
kubectl apply -f "$ROOT_DIR/k8s/ticket-checkout-service.yaml"

echo "Preparing deployment manifests with ECR image references..."

for service in ticket-api ticket-worker ticket-checkout; do
  case "$service" in
    ticket-api) manifest="ticket-api-deployment.yaml" ;;
    ticket-worker) manifest="ticket-worker-deployment.yaml" ;;
    ticket-checkout) manifest="ticket-checkout-deployment.yaml" ;;
  esac

  sed "s|image: .*|image: ${ECR_REGISTRY}/${service}:latest|" \
    "$ROOT_DIR/k8s/$manifest" > "$SCRIPT_DIR/$manifest.tmp"

  kubectl apply -f "$SCRIPT_DIR/$manifest.tmp"
  rm -f "$SCRIPT_DIR/$manifest.tmp"
done

echo "Waiting for deployments..."
kubectl rollout status deployment/ticket-api --timeout=180s
kubectl rollout status deployment/ticket-checkout --timeout=180s
kubectl rollout status deployment/ticket-worker --timeout=180s

kubectl get deployments,pods,services
echo "Concertpass deployment completed."

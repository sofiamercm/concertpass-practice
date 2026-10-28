
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

echo "Checking AWS credentials..."
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
ECR_REGISTRY="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

echo "AWS account: $ACCOUNT_ID"
echo "AWS region: $AWS_REGION"
echo "ECR registry: $ECR_REGISTRY"

echo "Checking Docker..."
if ! docker info >/dev/null 2>&1; then
  echo "ERROR: Docker is not running. Open Docker Desktop and try again."
  exit 1
fi

echo "Logging in to Amazon ECR..."
aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin "$ECR_REGISTRY"

for service in ticket-api ticket-worker ticket-checkout; do
  echo ""
  echo "Processing service: $service"

  SERVICE_DIR="$ROOT_DIR/$service"
  IMAGE_URI="$ECR_REGISTRY/$service:latest"

  if [[ ! -f "$SERVICE_DIR/Dockerfile" ]]; then
    echo "ERROR: Dockerfile not found for $service"
    exit 1
  fi

  echo "Checking ECR repository..."
  if ! aws ecr describe-repositories \
    --repository-names "$service" \
    --region "$AWS_REGION" >/dev/null 2>&1; then

    aws ecr create-repository \
      --repository-name "$service" \
      --region "$AWS_REGION" >/dev/null
  fi

  echo "Building image for Linux AMD64..."
  docker build \
    --platform linux/amd64 \
    --tag "$IMAGE_URI" \
    "$SERVICE_DIR"

  echo "Pushing image to ECR..."
  docker push "$IMAGE_URI"

  echo "Image published: $IMAGE_URI"
done

echo ""
echo "All three images have been built and pushed successfully."


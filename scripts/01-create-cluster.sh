
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"

CLUSTER_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/c226290a5714694l17123136t1w037826-LabEksClusterRole-rymbp9WH6xXa"
NODE_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/c226290a5714694l17123136t1w037826834-LabEksNodeRole-GLbEFHg3GbSB"

echo "AWS account: $ACCOUNT_ID"
echo "Region: $AWS_REGION"
echo "Cluster: $CLUSTER_NAME"

if aws eks describe-cluster \
  --name "$CLUSTER_NAME" \
  --region "$AWS_REGION" >/dev/null 2>&1; then
  echo "Cluster already exists. Reusing it."
else
  cat > /tmp/concertpass-cluster.yaml <<YAML
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig
metadata:
  name: ${CLUSTER_NAME}
  region: ${AWS_REGION}
iam:
  serviceRoleARN: ${CLUSTER_ROLE_ARN}
managedNodeGroups:
  - name: workers
    instanceType: t3.medium
    desiredCapacity: 2
    minSize: 2
    maxSize: 2
    iam:
      instanceRoleARN: ${NODE_ROLE_ARN}
YAML

  echo "Creating EKS cluster. This may take 15-25 minutes."
  eksctl create cluster -f /tmp/concertpass-cluster.yaml
fi

aws eks update-kubeconfig \
  --name "$CLUSTER_NAME" \
  --region "$AWS_REGION"

echo "Checking cluster nodes..."
kubectl get nodes

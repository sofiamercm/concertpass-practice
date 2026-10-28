#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "======================================"
echo " CONCERTPASS - SETUP"
echo "======================================"

if [[ "${CONCERTPASS_SETUP_READY:-NO}" != "YES" ]]; then
  echo "STOP: AWS setup is not approved yet."
  echo "Review and fix the AWS scripts before deployment."
  exit 1
fi

for script in \
  01-create-cluster.sh \
  02-create-dynamodb.sh \
  03-create-sqs.sh \
  04-create-rds.sh \
  05-build-push-images.sh \
  06-deploy-k8s.sh; do

  if [[ ! -f "$SCRIPT_DIR/$script" ]]; then
    echo "ERROR: Missing script: $script"
    exit 1
  fi
done

for script in \
  01-create-cluster.sh \
  02-create-dynamodb.sh \
  03-create-sqs.sh \
  04-create-rds.sh \
  05-build-push-images.sh \
  06-deploy-k8s.sh; do

  echo ""
  echo "Running $script..."
  bash "$SCRIPT_DIR/$script"
done

echo ""
echo "Concertpass setup finished."

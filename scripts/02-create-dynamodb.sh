
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

TABLE_NAME="$DDB_TABLE"

echo "Checking DynamoDB table: $TABLE_NAME"

if aws dynamodb describe-table \
  --table-name "$TABLE_NAME" \
  --region "$AWS_REGION" >/dev/null 2>&1; then
  echo "Table already exists: $TABLE_NAME"
else
  echo "Creating DynamoDB table: $TABLE_NAME"

  aws dynamodb create-table \
    --table-name "$TABLE_NAME" \
    --attribute-definitions AttributeName=concert_id,AttributeType=S \
    --key-schema AttributeName=concert_id,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --region "$AWS_REGION"

  echo "Waiting for table to become active..."
  aws dynamodb wait table-exists \
    --table-name "$TABLE_NAME" \
    --region "$AWS_REGION"
fi

echo "Loading sample concerts..."

aws dynamodb put-item \
  --table-name "$TABLE_NAME" \
  --region "$AWS_REGION" \
  --item '{
    "concert_id": {"S": "rex-orange-county-nyc"},
    "name": {"S": "Rex Orange County"},
    "date": {"S": "2026-11-15"},
    "recinto": {"S": "Terminal 5, New York, NY"},
    "capacity": {
      "M": {
        "floor": {"N": "100"},
        "vip": {"N": "50"},
        "general": {"N": "500"}
      }
    }
  }'

aws dynamodb put-item \
  --table-name "$TABLE_NAME" \
  --region "$AWS_REGION" \
  --item '{
    "concert_id": {"S": "fontaines-dc-nyc"},
    "name": {"S": "Fontaines D.C."},
    "date": {"S": "2026-12-05"},
    "recinto": {"S": "Brooklyn Steel, Brooklyn, NY"},
    "capacity": {
      "M": {
        "floor": {"N": "30"},
        "vip": {"N": "10"},
        "general": {"N": "100"}
      }
    }
  }'

echo "DynamoDB setup completed."

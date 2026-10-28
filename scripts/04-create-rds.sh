#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

umask 077
SECRET_FILE="$(mktemp)"
UPDATED_SECRET_FILE="$(mktemp)"
trap 'rm -f "$SECRET_FILE" "$UPDATED_SECRET_FILE"' EXIT

echo "Preparing Concertpass PostgreSQL database..."

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"

CLUSTER_STATUS="$(aws eks describe-cluster \
  --name "$CLUSTER_NAME" \
  --region "$AWS_REGION" \
  --query 'cluster.status' \
  --output text)"

if [[ "$CLUSTER_STATUS" != "ACTIVE" ]]; then
  echo "ERROR: EKS cluster must be ACTIVE before creating the database."
  exit 1
fi

VPC_ID="$(aws eks describe-cluster \
  --name "$CLUSTER_NAME" \
  --region "$AWS_REGION" \
  --query 'cluster.resourcesVpcConfig.vpcId' \
  --output text)"

CLUSTER_SG="$(aws eks describe-cluster \
  --name "$CLUSTER_NAME" \
  --region "$AWS_REGION" \
  --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' \
  --output text)"

echo "AWS account: $ACCOUNT_ID"
echo "Region: $AWS_REGION"
echo "Database: $DB_ID"

SECRET_EXISTS=NO
if aws secretsmanager describe-secret \
  --secret-id "$SECRET_NAME" \
  --region "$AWS_REGION" >/dev/null 2>&1; then
  SECRET_EXISTS=YES
fi

DB_EXISTS=NO
if aws rds describe-db-instances \
  --db-instance-identifier "$DB_ID" \
  --region "$AWS_REGION" >/dev/null 2>&1; then
  DB_EXISTS=YES
fi

if [[ "$DB_EXISTS" == "YES" && "$SECRET_EXISTS" != "YES" ]]; then
  echo "ERROR: The database exists but its Secrets Manager secret is missing."
  echo "Stopping to avoid changing existing database credentials."
  exit 1
fi

if [[ "$SECRET_EXISTS" == "YES" ]]; then
  echo "Loading existing credentials from Secrets Manager..."
  aws secretsmanager get-secret-value \
    --secret-id "$SECRET_NAME" \
    --region "$AWS_REGION" \
    --query 'SecretString' \
    --output text > "$SECRET_FILE"

  DB_PASSWORD="$(python3 - "$SECRET_FILE" "$DB_USER" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as file:
    data = json.load(file)

username = data.get("DB_USER") or data.get("username") or data.get("user")
password = data.get("DB_PASSWORD") or data.get("password")

if not username or not password:
    raise SystemExit("ERROR: Secret must contain a database username and password.")

if username != sys.argv[2]:
    raise SystemExit("ERROR: Secret username does not match DB_USER in config.sh.")

print(password)
PY
)"
else
  echo "Generating database credentials..."
  DB_PASSWORD="$(openssl rand -hex 24)"

  python3 - "$SECRET_FILE" "$DB_USER" "$DB_PASSWORD" "$DB_NAME" <<'PY'
import json
import sys

path, username, password, database = sys.argv[1:]
with open(path, "w", encoding="utf-8") as file:
    json.dump({
        "DB_USER": username,
        "DB_PASSWORD": password,
        "username": username,
        "password": password,
        "DB_NAME": database,
        "dbname": database,
        "port": 5432
    }, file)
PY

  aws secretsmanager create-secret \
    --name "$SECRET_NAME" \
    --description "Concertpass PostgreSQL credentials" \
    --secret-string "file://$SECRET_FILE" \
    --region "$AWS_REGION" >/dev/null
fi

echo "Checking RDS subnet group..."
if ! aws rds describe-db-subnet-groups \
  --db-subnet-group-name "$DB_SUBNET_GROUP" \
  --region "$AWS_REGION" >/dev/null 2>&1; then

  SUBNETS="$(aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --region "$AWS_REGION" \
    --query 'Subnets[].SubnetId' \
    --output text)"

  read -r -a SUBNET_ARRAY <<< "$SUBNETS"

  if [[ "${#SUBNET_ARRAY[@]}" -lt 2 ]]; then
    echo "ERROR: At least two subnets are required."
    exit 1
  fi

  aws rds create-db-subnet-group \
    --db-subnet-group-name "$DB_SUBNET_GROUP" \
    --db-subnet-group-description "Concertpass PostgreSQL subnets" \
    --subnet-ids "${SUBNET_ARRAY[@]}" \
    --region "$AWS_REGION" >/dev/null
fi

echo "Checking RDS security group..."
DB_SG_ID="$(aws ec2 describe-security-groups \
  --filters "Name=vpc-id,Values=$VPC_ID" \
            "Name=group-name,Values=$DB_SG_NAME" \
  --region "$AWS_REGION" \
  --query 'SecurityGroups[0].GroupId' \
  --output text)"

if [[ "$DB_SG_ID" == "None" || -z "$DB_SG_ID" ]]; then
  DB_SG_ID="$(aws ec2 create-security-group \
    --group-name "$DB_SG_NAME" \
    --description "Concertpass PostgreSQL access from EKS" \
    --vpc-id "$VPC_ID" \
    --region "$AWS_REGION" \
    --query 'GroupId' \
    --output text)"

  aws ec2 authorize-security-group-ingress \
    --group-id "$DB_SG_ID" \
    --protocol tcp \
    --port 5432 \
    --source-group "$CLUSTER_SG" \
    --region "$AWS_REGION" >/dev/null
fi

if [[ "$DB_EXISTS" != "YES" ]]; then
  echo "Creating PostgreSQL RDS instance..."
  aws rds create-db-instance \
    --db-instance-identifier "$DB_ID" \
    --engine postgres \
    --engine-version 16 \
    --db-instance-class db.t3.micro \
    --allocated-storage 20 \
    --storage-type gp3 \
    --storage-encrypted \
    --db-name "$DB_NAME" \
    --master-username "$DB_USER" \
    --master-user-password "$DB_PASSWORD" \
    --vpc-security-group-ids "$DB_SG_ID" \
    --db-subnet-group-name "$DB_SUBNET_GROUP" \
    --no-publicly-accessible \
    --backup-retention-period 0 \
    --no-deletion-protection \
    --region "$AWS_REGION" >/dev/null
else
  echo "RDS instance already exists; reusing it."
fi

echo "Waiting for RDS to become available. This may take several minutes..."
aws rds wait db-instance-available \
  --db-instance-identifier "$DB_ID" \
  --region "$AWS_REGION"

DB_HOST="$(aws rds describe-db-instances \
  --db-instance-identifier "$DB_ID" \
  --region "$AWS_REGION" \
  --query 'DBInstances[0].Endpoint.Address' \
  --output text)"

if [[ -z "$DB_HOST" || "$DB_HOST" == "None" ]]; then
  echo "ERROR: RDS endpoint was not returned."
  exit 1
fi

python3 - "$SECRET_FILE" "$UPDATED_SECRET_FILE" "$DB_HOST" "$DB_USER" "$DB_PASSWORD" "$DB_NAME" <<'PY'
import json
import sys

source, destination, host, username, password, database = sys.argv[1:]

try:
    with open(source, encoding="utf-8") as file:
        data = json.load(file)
except (OSError, json.JSONDecodeError):
    data = {}

data.update({
    "DB_HOST": host,
    "DB_USER": username,
    "DB_PASSWORD": password,
    "DB_NAME": database,
    "DB_PORT": 5432,
    "host": host,
    "username": username,
    "password": password,
    "dbname": database,
    "port": 5432
})

with open(destination, "w", encoding="utf-8") as file:
    json.dump(data, file)
PY

if [[ "$SECRET_EXISTS" == "YES" ]]; then
  aws secretsmanager put-secret-value \
    --secret-id "$SECRET_NAME" \
    --secret-string "file://$UPDATED_SECRET_FILE" \
    --region "$AWS_REGION" >/dev/null
else
  aws secretsmanager put-secret-value \
    --secret-id "$SECRET_NAME" \
    --secret-string "file://$UPDATED_SECRET_FILE" \
    --region "$AWS_REGION" >/dev/null
fi

save_state "DB_HOST" "$DB_HOST"
save_state "DB_SG_ID" "$DB_SG_ID"

echo ""
echo "RDS setup completed."
echo "Database status: AVAILABLE"
echo "Database name: $DB_NAME"
echo "Database endpoint: $DB_HOST"
echo "Credentials stored in AWS Secrets Manager."


#!/usr/bin/env bash
set -euo pipefail

export AWS_REGION="${AWS_REGION:-us-east-1}"
export AWS_DEFAULT_REGION="$AWS_REGION"

export CLUSTER_NAME="concertpass-retry"
export ACCOUNT_ID=""
export ECR_REGISTRY=""
export LAB_ROLE_ARN=""
export DDB_TABLE="concerts"
export QUEUE_NAME="concertpass-reservations.fifo"
export DB_ID="concertpass-db"
export DB_NAME="concertpass"
export DB_USER="concertadmin"
export SECRET_NAME="concertpass/rds"
export DB_SG_NAME="concertpass-rds-sg"
export DB_SUBNET_GROUP="concertpass-subnets"
export SERVICES="ticket-api ticket-worker ticket-checkout"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SCRIPT_DIR
export ROOT_DIR="$(dirname "$SCRIPT_DIR")"
export STATE_FILE="$SCRIPT_DIR/.state"

save_state() {
  local key="$1"
  local value="$2"
  local temp_file="${STATE_FILE}.tmp"

  if [[ -f "$STATE_FILE" ]]; then
    grep -v "^${key}=" "$STATE_FILE" > "$temp_file" || true
  else
    : > "$temp_file"
  fi

  printf '%s=%s\n' "$key" "$value" >> "$temp_file"
  mv "$temp_file" "$STATE_FILE"
}

load_state() {
  if [[ -f "$STATE_FILE" ]]; then
    set -a
    source "$STATE_FILE"
    set +a
  fi
}

#!/usr/bin/env bash
set -euo pipefail

API_URL="${API_URL:-http://localhost:8080}"
CONCERT_ID="${CONCERT_ID:-rex-orange-county-nyc}"
USER_ID="test-user-$(date +%s)"

echo "Testing Concertpass reservation API..."

echo ""
echo "1. Creating a reservation..."

RESPONSE="$(curl --fail-with-body --silent --show-error \
  --request POST "$API_URL/reserve" \
  --header "Content-Type: application/json" \
  --data "{\"concert_id\":\"$CONCERT_ID\",\"user_id\":\"$USER_ID\",\"ticket_type\":\"general\",\"quantity\":1}")"

echo "$RESPONSE"

RESERVATION_ID="$(python3 -c '
import json, sys
data = json.load(sys.stdin)
print(data.get("reservation_id", ""))
' <<< "$RESPONSE")"

if [[ -z "$RESERVATION_ID" ]]; then
  echo "ERROR: No reservation_id was returned."
  exit 1
fi

echo ""
echo "2. Checking reservation status..."

curl --fail-with-body --silent --show-error \
  "$API_URL/reservation/$RESERVATION_ID"

echo ""
echo ""
echo "Reservation API test completed."
echo "Reservation ID: $RESERVATION_ID"

#!/usr/bin/env bash
set -euo pipefail

# Shows reservations grouped by ticket type and status for one concert

CONCERT_ID="${1:-cafe-tacvba-cdmx}"

kubectl exec deploy/ticket-api -- python -c "
import os, psycopg2
conn = psycopg2.connect(
    host=os.environ['DB_HOST'],
    port=os.environ.get('DB_PORT', '5432'),
    dbname=os.environ['DB_NAME'],
    user=os.environ['DB_USER'],
    password=os.environ['DB_PASSWORD'],
)
cur = conn.cursor()
cur.execute('''
    SELECT ticket_type, status, COUNT(*), SUM(quantity)
    FROM reservations
    WHERE concert_id = %s
    GROUP BY ticket_type, status
    ORDER BY ticket_type, status
''', ('$CONCERT_ID',))
rows = cur.fetchall()
print('Concert: $CONCERT_ID')
print('ticket_type | status | reservations | tickets')
for row in rows:
    print(' | '.join(str(value) for value in row))
if not rows:
    print('(no reservations yet)')
"

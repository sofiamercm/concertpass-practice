
"""Consume SQS FIFO messages, check ticket availability, and confirm reservations."""
import json
import logging
import os
import time

import boto3
import psycopg2
import requests

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
)
log = logging.getLogger("ticket-worker")

AWS_REGION = os.environ["AWS_REGION"]
SQS_QUEUE_URL = os.environ["SQS_QUEUE_URL"]
DDB_TABLE = os.environ["DDB_TABLE"]
CHECKOUT_URL = os.environ["CHECKOUT_URL"]

DB = {
    "host": os.environ["DB_HOST"],
    "port": os.environ.get("DB_PORT", "5432"),
    "dbname": os.environ["DB_NAME"],
    "user": os.environ["DB_USER"],
    "password": os.environ["DB_PASSWORD"],
    "connect_timeout": 5,
}

sqs = boto3.client("sqs", region_name=AWS_REGION)
table = boto3.resource(
    "dynamodb", region_name=AWS_REGION
).Table(DDB_TABLE)

_conn = None


def get_conn():
    """Open a PostgreSQL connection and reuse it."""
    global _conn
    if _conn is None or _conn.closed:
        _conn = psycopg2.connect(**DB)
    return _conn


def get_capacity(concert_id, ticket_type):
    """Retrieve the maximum ticket capacity stored in DynamoDB."""
    item = table.get_item(
        Key={"concert_id": concert_id}
    ).get("Item")

    if not item:
        return None

    capacity = item.get("capacity", {}).get(ticket_type)
    return int(capacity) if capacity is not None else None


def try_book(reservation, capacity):
    """
    Check whether a reservation can be booked.

    Returns 'booked', 'full', or 'skip'.
    """
    conn = get_conn()
    rid = reservation["reservation_id"]
    cid = reservation["concert_id"]
    ticket_type = reservation["ticket_type"]
    quantity = int(reservation["quantity"])

    try:
        with conn.cursor() as cur:
            # Serialize booking decisions for each concert and ticket
            # type, even when there are no existing rows to lock.
            cur.execute(
                "SELECT pg_advisory_xact_lock(hashtext(%s))",
                (f"{cid}:{ticket_type}",),
            )

            cur.execute(
                """
                SELECT status
                FROM reservations
                WHERE reservation_id = %s
                """,
                (rid,),
            )
            row = cur.fetchone()

            if row is None or row[0] in ("confirmed", "rejected"):
                conn.rollback()
                return "skip"

            # If the reservation is already booked, retry checkout.
            if row[0] == "booked":
                conn.rollback()
                return "booked"

            # PostgreSQL does not support FOR UPDATE directly with SUM().
            # Lock the selected rows inside a subquery instead.
            cur.execute(
                """
                SELECT COALESCE(SUM(quantity), 0)
                FROM (
                    SELECT quantity
                    FROM reservations
                    WHERE concert_id = %s
                      AND ticket_type = %s
                      AND status IN ('booked', 'confirmed')
                    FOR UPDATE
                ) AS booked_rows
                """,
                (cid, ticket_type),
            )
            sold = int(cur.fetchone()[0])

            log.info(
                "%s: sold=%s requested=%s capacity=%s",
                rid, sold, quantity, capacity,
            )

            if sold + quantity <= capacity:
                cur.execute(
                    """
                    UPDATE reservations
                    SET status = 'booked', updated_at = NOW()
                    WHERE reservation_id = %s
                      AND status = 'pending'
                    """,
                    (rid,),
                )
                conn.commit()
                return "booked"

            conn.rollback()
            return "full"

    except Exception:
        conn.rollback()
        raise


def set_status(reservation_id, new_status, expected_status):
    """Update a reservation only if its current status matches the expected status."""
    conn = get_conn()
    try:
        with conn.cursor() as cur:
            cur.execute(
                """
                UPDATE reservations
                SET status = %s, updated_at = NOW()
                WHERE reservation_id = %s AND status = %s
                """,
                (new_status, reservation_id, expected_status),
            )
        conn.commit()
    except Exception:
        conn.rollback()
        raise


def process(reservation):
    """Process a reservation message."""
    rid = reservation["reservation_id"]

    capacity = get_capacity(
        reservation["concert_id"],
        reservation["ticket_type"],
    )

    if capacity is None:
        log.warning("%s: concert or ticket type not found", rid)
        set_status(rid, "rejected", "pending")
        return

    result = try_book(reservation, capacity)

    if result == "skip":
        return

    if result == "full":
        set_status(rid, "rejected", "pending")
        log.info("%s: REJECTED because capacity is full", rid)
        return

    # If the reservation is booked, checkout can be retried after a failure.
    response = requests.post(
        CHECKOUT_URL,
        json={
            "reservation_id": rid,
            "quantity": int(reservation["quantity"]),
        },
        timeout=5,
    )

    if response.status_code == 200:
        set_status(rid, "confirmed", "booked")
        log.info("%s: CONFIRMED", rid)
    else:
        raise RuntimeError(
            f"Checkout returned HTTP {response.status_code}"
        )


def main():
    """Poll SQS and process reservation messages."""
    log.info("Worker started. Queue: %s", SQS_QUEUE_URL)

    while True:
        try:
            response = sqs.receive_message(
                QueueUrl=SQS_QUEUE_URL,
                MaxNumberOfMessages=10,
                WaitTimeSeconds=10,
            )
        except Exception:
            log.exception("Failed to receive messages from SQS")
            time.sleep(3)
            continue

        for message in response.get("Messages", []):
            try:
                reservation = json.loads(message["Body"])
                process(reservation)

                # Delete the message only after successful processing.
                sqs.delete_message(
                    QueueUrl=SQS_QUEUE_URL,
                    ReceiptHandle=message["ReceiptHandle"],
                )
            except Exception:
                # Keep failed messages in the queue for a retry.
                log.exception("Failed to process reservation message")
                time.sleep(2)


if __name__ == "__main__":
    main()


import json
import os
import uuid
from datetime import datetime, timezone

import boto3
import psycopg2
from flask import Flask, jsonify, request
from psycopg2.extras import RealDictCursor

app = Flask(__name__)

AWS_REGION = os.environ.get("AWS_REGION", "us-east-1")
SQS_QUEUE_URL = os.environ.get("SQS_QUEUE_URL")

DB_CONFIG = {
    "host": os.environ.get("DB_HOST"),
    "port": int(os.environ.get("DB_PORT", "5432")),
    "dbname": os.environ.get("DB_NAME"),
    "user": os.environ.get("DB_USER"),
    "password": os.environ.get("DB_PASSWORD"),
    "connect_timeout": 5,
}

sqs = boto3.client("sqs", region_name=AWS_REGION)


def get_db_connection():
    missing = [
        key for key, value in DB_CONFIG.items()
        if key != "connect_timeout" and not value
    ]

    if missing:
        raise RuntimeError(
            "Missing database environment variables: "
            + ", ".join(missing)
        )

    return psycopg2.connect(**DB_CONFIG)


def init_db():
    with get_db_connection() as conn:
        with conn.cursor() as cur:
            cur.execute("""
                CREATE TABLE IF NOT EXISTS reservations (
                    reservation_id UUID PRIMARY KEY,
                    concert_id VARCHAR NOT NULL,
                    user_id VARCHAR NOT NULL,
                    ticket_type VARCHAR NOT NULL,
                    quantity INTEGER NOT NULL CHECK (quantity > 0),
                    status VARCHAR NOT NULL,
                    created_at TIMESTAMP NOT NULL,
                    updated_at TIMESTAMP NOT NULL
                )
            """)

            cur.execute("""
                CREATE INDEX IF NOT EXISTS
                idx_reservations_concert_type_status
                ON reservations (concert_id, ticket_type, status)
            """)


@app.get("/health")
def health():
    return jsonify({"status": "ok"}), 200


@app.post("/reserve")
def reserve():
    payload = request.get_json(silent=True)

    if not isinstance(payload, dict):
        return jsonify({"error": "A JSON object is required"}), 400

    concert_id = payload.get("concert_id")
    user_id = payload.get("user_id")
    ticket_type = payload.get("ticket_type")
    quantity = payload.get("quantity")

    if not all([
        isinstance(concert_id, str) and concert_id.strip(),
        isinstance(user_id, str) and user_id.strip(),
        isinstance(ticket_type, str) and ticket_type.strip(),
    ]):
        return jsonify({
            "error": "concert_id, user_id and ticket_type are required"
        }), 400

    if (
        not isinstance(quantity, int)
        or isinstance(quantity, bool)
        or quantity <= 0
    ):
        return jsonify({
            "error": "quantity must be a positive integer"
        }), 400

    if not SQS_QUEUE_URL:
        return jsonify({"error": "SQS_QUEUE_URL is not configured"}), 503

    concert_id = concert_id.strip()
    user_id = user_id.strip()
    ticket_type = ticket_type.strip()

    reservation_id = str(uuid.uuid4())
    now = datetime.now(timezone.utc).replace(tzinfo=None)

    message = {
        "reservation_id": reservation_id,
        "concert_id": concert_id,
        "user_id": user_id,
        "ticket_type": ticket_type,
        "quantity": quantity,
    }

    try:
        with get_db_connection() as conn:
            with conn.cursor() as cur:
                cur.execute("""
                    INSERT INTO reservations (
                        reservation_id,
                        concert_id,
                        user_id,
                        ticket_type,
                        quantity,
                        status,
                        created_at,
                        updated_at
                    )
                    VALUES (%s, %s, %s, %s, %s, %s, %s, %s)
                """, (
                    reservation_id,
                    concert_id,
                    user_id,
                    ticket_type,
                    quantity,
                    "pending",
                    now,
                    now,
                ))

        sqs.send_message(
            QueueUrl=SQS_QUEUE_URL,
            MessageBody=json.dumps(message),
            MessageGroupId=concert_id,
            MessageDeduplicationId=reservation_id,
        )

        return jsonify({
            "reservation_id": reservation_id,
            "status": "pending",
        }), 202

    except Exception:
        app.logger.exception("Failed to create or enqueue reservation")

        try:
            with get_db_connection() as conn:
                with conn.cursor() as cur:
                    cur.execute("""
                        UPDATE reservations
                        SET status = %s, updated_at = %s
                        WHERE reservation_id = %s
                          AND status = %s
                    """, ("rejected", now, reservation_id, "pending"))
        except Exception:
            app.logger.exception(
                "Failed to update reservation after processing error"
            )

        return jsonify({
            "error": "Could not process reservation"
        }), 500


@app.get("/reservation/<reservation_id>")
def get_reservation(reservation_id):
    try:
        with get_db_connection() as conn:
            with conn.cursor(cursor_factory=RealDictCursor) as cur:
                cur.execute("""
                    SELECT reservation_id,
                           concert_id,
                           user_id,
                           ticket_type,
                           quantity,
                           status,
                           created_at,
                           updated_at
                    FROM reservations
                    WHERE reservation_id = %s
                """, (reservation_id,))

                reservation = cur.fetchone()

        if reservation is None:
            return jsonify({"error": "Reservation not found"}), 404

        reservation["reservation_id"] = str(
            reservation["reservation_id"]
        )

        if reservation["created_at"] is not None:
            reservation["created_at"] = (
                reservation["created_at"].isoformat()
            )

        if reservation["updated_at"] is not None:
            reservation["updated_at"] = (
                reservation["updated_at"].isoformat()
            )

        return jsonify(dict(reservation)), 200

    except Exception:
        app.logger.exception("Failed to retrieve reservation")
        return jsonify({
            "error": "Could not retrieve reservation"
        }), 500


init_db()

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)

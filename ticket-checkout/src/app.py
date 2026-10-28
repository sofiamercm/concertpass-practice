
from flask import Flask, jsonify, request

app = Flask(__name__)


@app.get("/health")
def health():
    return jsonify({"status": "ok"}), 200


@app.post("/checkout")
def checkout():
    data = request.get_json(silent=True) or {}

    reservation_id = data.get("reservation_id")
    quantity = data.get("quantity")

    if not reservation_id or not isinstance(quantity, int) or isinstance(quantity, bool) or quantity <= 0:
        return jsonify({
            "error": "reservation_id and a positive integer quantity are required"
        }), 400

    return jsonify({
        "status": "authorized",
        "reservation_id": reservation_id,
        "quantity": quantity
    }), 200

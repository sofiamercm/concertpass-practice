#!/usr/bin/env python3

import concurrent.futures
import json
import os
import time
import urllib.error
import urllib.request
from collections import Counter

API_URL = os.getenv("API_URL", "http://localhost:8080").rstrip("/")
CONCERT_ID = os.getenv("CONCERT_ID", "rex-orange-county-nyc")
TICKET_TYPE = os.getenv("TICKET_TYPE", "general")
TOTAL_REQUESTS = int(os.getenv("TOTAL_REQUESTS", "30"))
CONCURRENCY = int(os.getenv("CONCURRENCY", "5"))


def create_reservation(index):
    payload = {
        "concert_id": CONCERT_ID,
        "user_id": f"load-test-{time.time_ns()}-{index}",
        "ticket_type": TICKET_TYPE,
        "quantity": 1,
    }

    request = urllib.request.Request(
        f"{API_URL}/reserve",
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )

    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            body = response.read().decode("utf-8", errors="replace")
            return response.status, body
    except urllib.error.HTTPError as error:
        body = error.read().decode("utf-8", errors="replace")
        return error.code, body
    except Exception as error:
        return "ERROR", str(error)


def main():
    if TOTAL_REQUESTS < 1 or CONCURRENCY < 1:
        raise SystemExit("TOTAL_REQUESTS and CONCURRENCY must be positive.")

    print(f"API: {API_URL}")
    print(f"Concert: {CONCERT_ID}")
    print(f"Requests: {TOTAL_REQUESTS}")
    print(f"Concurrency: {CONCURRENCY}")
    print("Starting load test...")

    results = []
    start = time.monotonic()

    with concurrent.futures.ThreadPoolExecutor(
        max_workers=CONCURRENCY
    ) as executor:
        futures = [
            executor.submit(create_reservation, index)
            for index in range(TOTAL_REQUESTS)
        ]
        for future in concurrent.futures.as_completed(futures):
            results.append(future.result())

    elapsed = time.monotonic() - start
    counts = Counter(str(status) for status, _ in results)
    accepted = sum(
        1 for status, _ in results
        if isinstance(status, int) and 200 <= status < 300
    )

    print("\nResults")
    print("-------")
    print(f"Total requests: {len(results)}")
    print(f"HTTP 2xx responses: {accepted}")
    print(f"Other responses or errors: {len(results) - accepted}")
    print(f"Elapsed seconds: {elapsed:.2f}")
    print(f"Requests per second: {len(results) / elapsed:.2f}")

    print("\nHTTP status counts")
    for status, count in sorted(counts.items(), key=lambda item: str(item[0])):
        print(f"{status}: {count}")

    with open("tests/load_test_results.json", "w", encoding="utf-8") as file:
        json.dump(
            [
                {"status": status, "body": body}
                for status, body in results
            ],
            file,
            indent=2,
        )

    print("\nDetailed results saved to tests/load_test_results.json")
    print("Note: HTTP acceptance does not mean a ticket was confirmed.")


if __name__ == "__main__":
    main()

"""CF-110 demo — OrderFlow order processor.

Deployed with a 30-second timeout. Roughly one invocation in three simulates a
downstream call that takes longer than that, so CloudWatch Logs holds a mix of
successful REPORT lines and timed-out ones.

WHY THE MIX MATTERS
-------------------
A function that ALWAYS times out is a one-glance fix and teaches nothing. An
intermittent one forces the instructor to demonstrate the actual technique:
read measured duration against the configured ceiling, rather than guessing
from the error alone.

TWO COUPLINGS TO THE DEMO RUNBOOK — change these together or not at all
----------------------------------------------------------------------
1. The 30-second timeout in compute.tf. The runbook's Logs Insights query
   filters `@duration > 25000`, which only returns rows if the ceiling sits
   just above 25s. Lower the timeout and the query silently returns nothing.

2. On the Python 3.12 runtime a timeout is recorded as `Status: timeout` on the
   REPORT line. There is NO "Task timed out after N seconds" line, despite
   almost every published example using that string. The runbook filters on
   `Status: timeout` for exactly this reason.

The handler also logs a structured line per order so the runbook can show
parsing and aggregation in Logs Insights, not just filtering.
"""
import json
import os
import random
import time

ORDERS_BUCKET = os.environ.get("ORDERS_BUCKET", "unset")

# Payment gateway latencies in ms. Most are fast; the three slow values all
# exceed the 30s Lambda ceiling and are what produce the timeouts.
GATEWAY_LATENCIES_MS = [90, 140, 210, 260, 31000, 38000, 45000]

REGIONS = ["us-east", "us-west", "eu-west"]


def handler(event, context):
    order_id = random.randint(100000, 999999)
    region = random.choice(REGIONS)
    amount = round(random.uniform(12.0, 940.0), 2)

    # Structured line — the runbook parses this to aggregate by region.
    print(json.dumps({
        "level": "INFO",
        "msg": "order received",
        "order_id": order_id,
        "region": region,
        "amount": amount,
        "bucket": ORDERS_BUCKET,
    }))

    latency_ms = random.choice(GATEWAY_LATENCIES_MS)

    # Logged BEFORE the call, so the line survives even when the invocation is
    # killed mid-sleep. Without this the slow cases would leave no evidence of
    # their cause, and the demo could only show the symptom.
    print("calling payment gateway took %dms" % latency_ms)

    time.sleep(latency_ms / 1000.0)

    print(json.dumps({
        "level": "INFO",
        "msg": "order settled",
        "order_id": order_id,
        "gateway_ms": latency_ms,
    }))

    return {
        "statusCode": 200,
        "body": json.dumps({"order_id": order_id, "gateway_ms": latency_ms}),
    }

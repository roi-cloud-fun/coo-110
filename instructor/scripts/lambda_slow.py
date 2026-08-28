"""CF-110 Lab 1 Task 2 -- Lambda that intermittently exceeds its timeout.

Deployed with a 30-second timeout. Roughly one invocation in three sleeps longer
than that, so CloudWatch Logs shows a mix of successful REPORT lines and
"Task timed out after 30.00 seconds" errors.

The 30-second ceiling is deliberate: the Lab 1 Task 2 Logs Insights query in the
guide filters on @duration > 25000, which only returns rows if the timeout sits
just above that. Changing this timeout without changing that query breaks the
task silently -- the query runs fine and returns nothing.

That mix is the point. A function that ALWAYS times out is a one-glance fix; an
intermittent one forces the student to read Duration against the configured
timeout rather than guessing.

It also logs a "calling external API took NNNms" line so the Logs Insights query
in the lab guide that parses api_duration returns rows.
"""
import json
import random
import time


def handler(event, context):
    # Simulated downstream call. Most are fast; some blow the timeout budget.
    api_ms = random.choice([120, 180, 240, 310, 31000, 38000, 45000])
    print("calling external API took %dms" % api_ms)
    time.sleep(api_ms / 1000.0)
    return {"statusCode": 200, "body": json.dumps({"api_ms": api_ms})}

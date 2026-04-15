"""
Scheduled Jobs Lambda — Phase 1B

Triggered by: EventBridge scheduled rules (cron)
Reads from:   Activity + Device tables
Publishes to: EventBridge (warnings/alerts)

Jobs:
  1. No-Activity Check (every 30 min)
     - Query devices with linked walkers
     - Flag any device with 0 steps in last 2 hours during waking hours (7a-10p)
     - Publish "no-activity" warning to EventBridge

  2. Weekly Trend Computation (daily at 03:00 UTC)
     - Compute 7-day rolling averages per device
     - Write summary to activity table (type=weekly_rollup)

  3. Offline Detector (every 60 min)
     - Scan device registry for last_seen > 8 hours ago
     - Publish "device-offline" warning to EventBridge

  4. Daily Summary (daily at 23:59 UTC)
     - Aggregate hourly records into daily totals
     - Used by portal 7D/30D/6M chart views

The handler routes based on the EventBridge rule that triggered it,
using the detail-type field to determine which job to run.
"""

import json


def handler(event, context):
    # TODO: Implement in Phase 1B
    job_type = event.get("detail-type", "unknown")
    print(f"Scheduled job triggered: {job_type}")
    print(json.dumps(event))
    return {"statusCode": 200, "body": f"Scheduled job placeholder: {job_type}"}

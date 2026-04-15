"""
Activity Processor Lambda — Phase 1B

Triggered by: IoT Rule on gs/{serial}/activity
Writes to:    Activity time-series table (DynamoDB)

Expected MQTT payload:
{
    "serial": "GS-0001",
    "ts": "2026-04-15T14:00:00Z",
    "steps": 142,
    "distance_ft": 340.5,
    "active_min": 9,
    "assist_score": null
}

This handler will:
1. Validate payload schema
2. Deduplicate by serial + timestamp
3. Write hourly record to activity table
4. On the final hour of the day (23:00), compute daily roll-up
"""

import json


def handler(event, context):
    # TODO: Implement in Phase 1B
    print(json.dumps(event))
    return {"statusCode": 200, "body": "Activity processor placeholder"}

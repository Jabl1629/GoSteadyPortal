"""
Activity Processor Lambda

Triggered by: IoT Rule on gs/+/activity
IoT Rule SQL: SELECT *, topic(2) AS thingName FROM 'gs/+/activity'

Expected payload (session-based):
{
    "serial": "GS0000001234",
    "session_start": "2026-04-15T14:02:00Z",
    "session_end": "2026-04-15T14:18:00Z",
    "steps": 142,
    "distance_ft": 340.5,
    "active_min": 16,
    "thingName": "GS0000001234"    <-- injected by IoT Rule SQL
}

Phase 1A: logs payload to CloudWatch.
Phase 1B: validate, dedup by serial+session_start, write to DynamoDB.
"""

import json
import os

DEVICE_TABLE = os.environ.get("DEVICE_TABLE", "")
ACTIVITY_TABLE = os.environ.get("ACTIVITY_TABLE", "")


def handler(event, context):
    serial = event.get("serial", event.get("thingName", "UNKNOWN"))
    steps = event.get("steps", 0)
    active = event.get("active_min", 0)
    print(f"[ACTIVITY] serial={serial} steps={steps} active_min={active}")
    print(json.dumps(event))

    # TODO Phase 1B: validate, dedup by serial+session_start, write to DynamoDB
    return {
        "statusCode": 200,
        "body": f"Activity received for {serial}: {steps} steps",
    }

"""
Alert Handler Lambda

Triggered by: IoT Rule on gs/+/alert
IoT Rule SQL: SELECT *, topic(2) AS thingName FROM 'gs/+/alert'

Expected payload (event-driven):
{
    "serial": "GS0000001234",
    "ts": "2026-04-15T14:10:32Z",
    "alert_type": "tipover",
    "severity": "critical",
    "data": {
        "accel_g": 2.3,
        "orientation": "horizontal",
        "duration_s": 5
    },
    "thingName": "GS0000001234"    <-- injected by IoT Rule SQL
}

Phase 1A: logs payload to CloudWatch.
Phase 1B: write to alert table, look up caregivers, publish to EventBridge.
"""

import json
import os

ALERT_TABLE = os.environ.get("ALERT_TABLE", "")
DEVICE_TABLE = os.environ.get("DEVICE_TABLE", "")


def handler(event, context):
    serial = event.get("serial", event.get("thingName", "UNKNOWN"))
    alert_type = event.get("alert_type", "unknown")
    severity = event.get("severity", "unknown")
    print(f"[ALERT] serial={serial} type={alert_type} severity={severity}")
    print(json.dumps(event))

    # TODO Phase 1B: write to alert table, look up caregivers, publish to EventBridge
    return {
        "statusCode": 200,
        "body": f"Alert received for {serial}: {alert_type} ({severity})",
    }

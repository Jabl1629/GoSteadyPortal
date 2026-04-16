"""
Heartbeat Processor Lambda

Triggered by: IoT Rule on gs/+/heartbeat
IoT Rule SQL: SELECT *, topic(2) AS thingName FROM 'gs/+/heartbeat'

Expected payload (hourly):
{
    "serial": "GS0000001234",
    "ts": "2026-04-15T14:00:00Z",
    "battery_mv": 3850,
    "battery_pct": 0.72,
    "rsrp_dbm": -87,
    "snr_db": 12.5,
    "firmware": "1.2.0",
    "uptime_s": 86400,
    "thingName": "GS0000001234"    <-- injected by IoT Rule SQL
}

Phase 1A: logs payload to CloudWatch.
Phase 1B: update device registry, check thresholds, publish to EventBridge.
"""

import json
import os

DEVICE_TABLE = os.environ.get("DEVICE_TABLE", "")


def handler(event, context):
    serial = event.get("serial", event.get("thingName", "UNKNOWN"))
    battery = event.get("battery_pct", "?")
    rsrp = event.get("rsrp_dbm", "?")
    snr = event.get("snr_db", "?")
    print(f"[HEARTBEAT] serial={serial} battery={battery} rsrp={rsrp} snr={snr}")
    print(json.dumps(event))

    # TODO Phase 1B: update device registry, check thresholds
    return {
        "statusCode": 200,
        "body": f"Heartbeat received for {serial}",
    }

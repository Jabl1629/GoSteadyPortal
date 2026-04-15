"""
Heartbeat Processor Lambda — Phase 1B

Triggered by: IoT Rule on gs/{serial}/heartbeat
Writes to:    Device Registry table (DynamoDB)

Expected MQTT payload:
{
    "serial": "GS-0001",
    "ts": "2026-04-15T14:05:00Z",
    "battery_mv": 3850,
    "battery_pct": 0.72,
    "signal_dbm": -87,
    "firmware": "1.2.0",
    "uptime_s": 86400
}

This handler will:
1. Update device registry (battery, signal, last_seen, firmware)
2. Check thresholds:
   - Battery < 20%  → publish warning to EventBridge
   - Signal < -110 dBm → publish warning to EventBridge
3. Touch last_seen timestamp
"""

import json


def handler(event, context):
    # TODO: Implement in Phase 1B
    print(json.dumps(event))
    return {"statusCode": 200, "body": "Heartbeat processor placeholder"}

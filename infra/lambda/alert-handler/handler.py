"""
Alert Handler Lambda — Phase 1B

Triggered by: IoT Rule on gs/{serial}/alert
Writes to:    Alert History table (DynamoDB)
Publishes to: EventBridge (gosteady-events bus)

Expected MQTT payload:
{
    "serial": "GS-0001",
    "ts": "2026-04-15T14:10:32Z",
    "alert_type": "tipover",
    "severity": "critical",
    "data": {
        "accel_g": 2.3,
        "orientation": "horizontal",
        "duration_s": 5
    }
}

This handler will:
1. Log alert to alert history table
2. Look up linked caregivers from relationships table
3. Publish structured event to EventBridge:
   - Source: "gosteady.alert"
   - DetailType: "TipOver" | "NoActivity" | "BatteryLow"
   - Detail: { serial, alertType, severity, caregiverIds[], ... }
4. EventBridge rules fan out to:
   - SNS → push notification to caregiver phones (< 60s)
   - SQS → integration queue for EMR/Rhapsody
"""

import json


def handler(event, context):
    # TODO: Implement in Phase 1B
    print(json.dumps(event))
    return {"statusCode": 200, "body": "Alert handler placeholder"}

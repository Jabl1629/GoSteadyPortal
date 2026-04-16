"""
Alert Handler Lambda — Phase 1B

Triggered by: IoT Rule on gs/+/alert
IoT Rule SQL:  SELECT *, topic(2) AS thingName FROM 'gs/+/alert'

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

Responsibilities (Phase 1B):
  1. Validate payload (alert_type + severity enum, ts parse).
  2. Look up walkerUserId on the device registry (may be null
     pre-activation — alert still recorded, just not routable yet).
  3. Conditional PutItem with compound SK ({ts}#{alert_type}) so
     two alerts in the same second don't overwrite each other, and
     MQTT retries remain idempotent.
  4. source="device" (vs "cloud" for synthetic threshold alerts).

Non-goals (deferred):
  - EventBridge fan-out / SNS / SMS dispatch → Phase 2C.
  - Caregiver relationship lookup + notification → Phase 2C.
"""

import json
import os
from datetime import datetime, timezone
from decimal import Decimal

import boto3
from botocore.exceptions import ClientError

# ── Configuration ────────────────────────────────────────────────
ALERT_TABLE = os.environ["ALERT_TABLE"]
DEVICE_TABLE = os.environ["DEVICE_TABLE"]

VALID_ALERT_TYPES = {"tipover", "fall", "impact"}
VALID_SEVERITIES = {"critical", "warning", "info"}

REQUIRED_FIELDS = ("ts", "alert_type", "severity")

# ── AWS clients ──────────────────────────────────────────────────
_ddb = boto3.resource("dynamodb")
_alert_tbl = _ddb.Table(ALERT_TABLE)
_device_tbl = _ddb.Table(DEVICE_TABLE)


# ── Helpers ──────────────────────────────────────────────────────
def _parse_iso(ts: str) -> datetime:
    return datetime.fromisoformat(ts.replace("Z", "+00:00"))


def _validate(event: dict) -> tuple[bool, str]:
    for f in REQUIRED_FIELDS:
        if f not in event:
            return False, f"missing:{f}"
    try:
        _parse_iso(event["ts"])
    except (TypeError, ValueError) as e:
        return False, f"bad_timestamp:{e}"
    if event["alert_type"] not in VALID_ALERT_TYPES:
        return False, f"bad_alert_type:{event['alert_type']}"
    if event["severity"] not in VALID_SEVERITIES:
        return False, f"bad_severity:{event['severity']}"
    return True, "ok"


def _lookup_walker(serial: str) -> str | None:
    try:
        dev = _device_tbl.get_item(Key={"serialNumber": serial}).get("Item") or {}
        return dev.get("walkerUserId")
    except ClientError as e:
        print(f"[ALERT] walker lookup failed for {serial}: {e}")
        return None


def _to_ddb_safe(value):
    """
    Recursively convert Python floats to Decimal for DynamoDB.
    boto3's high-level resource rejects raw floats but accepts Decimal.
    Devices send arbitrary nested `data` dicts, so we sanitise here
    rather than forcing the firmware team to be Decimal-aware.
    """
    if isinstance(value, float):
        return Decimal(str(value))
    if isinstance(value, dict):
        return {k: _to_ddb_safe(v) for k, v in value.items()}
    if isinstance(value, list):
        return [_to_ddb_safe(v) for v in value]
    return value


# ── Handler ──────────────────────────────────────────────────────
def handler(event, context):
    serial = event.get("serial") or event.get("thingName") or "UNKNOWN"

    ok, reason = _validate(event)
    if not ok:
        print(f"[ALERT][REJECT] serial={serial} reason={reason} event={json.dumps(event)}")
        return {"statusCode": 400, "body": f"invalid payload: {reason}"}

    ts = _parse_iso(event["ts"])
    ts_iso = ts.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    alert_type = event["alert_type"]
    severity = event["severity"]

    walker_id = _lookup_walker(serial)

    sk = f"{ts_iso}#{alert_type}"
    item: dict = {
        "serialNumber": serial,
        "timestamp": sk,
        "eventTimestamp": ts_iso,
        "alertType": alert_type,
        "severity": severity,
        "source": "device",
        "acknowledged": False,
        "createdAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }
    if walker_id:
        item["walkerUserId"] = walker_id
    if isinstance(event.get("data"), dict):
        # Pass-through — frontend/caregiver app decides how to render.
        # Floats in nested dicts must become Decimal for DynamoDB.
        item["data"] = _to_ddb_safe(event["data"])

    try:
        _alert_tbl.put_item(
            Item=item,
            ConditionExpression="attribute_not_exists(serialNumber) AND attribute_not_exists(#ts)",
            ExpressionAttributeNames={"#ts": "timestamp"},
        )
        print(
            f"[ALERT][OK] serial={serial} type={alert_type} sev={severity} "
            f"ts={ts_iso} walker={walker_id}"
        )
    except ClientError as e:
        if e.response["Error"]["Code"] == "ConditionalCheckFailedException":
            print(f"[ALERT][DUP] serial={serial} sk={sk} — already recorded")
            return {"statusCode": 200, "body": "duplicate alert ignored"}
        print(f"[ALERT][ERROR] serial={serial} {e}")
        raise

    return {
        "statusCode": 200,
        "body": f"Alert recorded for {serial}: {alert_type} ({severity})",
    }

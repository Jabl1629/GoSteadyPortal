"""
Heartbeat Processor Lambda — Phase 1B

Triggered by: IoT Rule on gs/+/heartbeat
IoT Rule SQL:  SELECT *, topic(2) AS thingName FROM 'gs/+/heartbeat'

Expected payload (~hourly):
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

Responsibilities (Phase 1B):
  1. Validate payload (reject + log if malformed).
  2. Partial UpdateItem on the device registry:
       lastSeen, batteryPct, batteryMv, rsrpDbm, snrDb,
       firmwareVersion, uptimeS, lastHeartbeatAt.
     UpdateItem (not PutItem) preserves walkerUserId, provisionedAt,
     and any other attributes set by other flows.
  3. Threshold checks — write synthetic alerts to the alert table:
       batteryPct < 0.05                → battery_critical / critical
       batteryPct < 0.10                → battery_low      / warning
       rsrp_dbm  <= -120                → signal_lost      / warning
       rsrp_dbm  <= -110                → signal_weak      / info
     Synthetic alerts have source="cloud" (device-generated use "device").
     Compound SK ({ts}#{alert_type}) prevents collisions when a single
     heartbeat trips multiple thresholds.

Non-goals (deferred):
  - Offline / no-heartbeat detection → scheduled sweep in Phase 2.
  - EventBridge fan-out              → Phase 2C.
"""

import json
import os
from datetime import datetime, timezone
from decimal import Decimal

import boto3
from botocore.exceptions import ClientError

# ── Configuration ────────────────────────────────────────────────
DEVICE_TABLE = os.environ["DEVICE_TABLE"]
ALERT_TABLE = os.environ["ALERT_TABLE"]

# Thresholds — see Phase 1B spec decision log.
BATTERY_CRITICAL = 0.05
BATTERY_LOW = 0.10
RSRP_LOST = -120
RSRP_WEAK = -110

# Validation bounds chosen from nRF9151 datasheet + chemistry limits.
REQUIRED_FIELDS = ("ts", "battery_pct", "rsrp_dbm", "snr_db")

# ── AWS clients ──────────────────────────────────────────────────
_ddb = boto3.resource("dynamodb")
_device_tbl = _ddb.Table(DEVICE_TABLE)
_alert_tbl = _ddb.Table(ALERT_TABLE)


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
    try:
        pct = float(event["battery_pct"])
        rsrp = float(event["rsrp_dbm"])
        snr = float(event["snr_db"])
    except (TypeError, ValueError) as e:
        return False, f"bad_number:{e}"
    if not 0.0 <= pct <= 1.0:
        return False, f"battery_pct_out_of_range:{pct}"
    if not -140 <= rsrp <= 0:
        return False, f"rsrp_out_of_range:{rsrp}"
    if not -20 <= snr <= 40:
        return False, f"snr_out_of_range:{snr}"
    return True, "ok"


def _determine_alerts(battery_pct: float, rsrp: float) -> list[tuple[str, str]]:
    """
    Return list of (alert_type, severity) to emit for this heartbeat.
    Only the most severe tier per dimension fires (critical suppresses low).
    """
    alerts: list[tuple[str, str]] = []
    if battery_pct < BATTERY_CRITICAL:
        alerts.append(("battery_critical", "critical"))
    elif battery_pct < BATTERY_LOW:
        alerts.append(("battery_low", "warning"))
    if rsrp <= RSRP_LOST:
        alerts.append(("signal_lost", "warning"))
    elif rsrp <= RSRP_WEAK:
        alerts.append(("signal_weak", "info"))
    return alerts


def _write_synthetic_alert(
    serial: str,
    walker_id: str | None,
    ts_iso: str,
    alert_type: str,
    severity: str,
    snapshot: dict,
) -> None:
    """
    Best-effort write — conditional on the compound SK not existing.
    Failures are logged but NEVER re-raised: a DDB hiccup on an alert
    must not cause the heartbeat Lambda to retry and double-update
    the device registry.
    """
    sk = f"{ts_iso}#{alert_type}"
    item = {
        "serialNumber": serial,
        "timestamp": sk,
        "eventTimestamp": ts_iso,
        "alertType": alert_type,
        "severity": severity,
        "source": "cloud",
        "acknowledged": False,
        "data": snapshot,
        "createdAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }
    if walker_id:
        item["walkerUserId"] = walker_id
    try:
        _alert_tbl.put_item(
            Item=item,
            ConditionExpression="attribute_not_exists(serialNumber) AND attribute_not_exists(#ts)",
            ExpressionAttributeNames={"#ts": "timestamp"},
        )
        print(f"[HEARTBEAT][ALERT] serial={serial} type={alert_type} sev={severity}")
    except ClientError as e:
        if e.response["Error"]["Code"] == "ConditionalCheckFailedException":
            # Same alert already recorded for this exact ts — idempotent.
            print(f"[HEARTBEAT][ALERT][DUP] serial={serial} sk={sk}")
            return
        print(f"[HEARTBEAT][ALERT][ERROR] serial={serial} type={alert_type}: {e}")


# ── Handler ──────────────────────────────────────────────────────
def handler(event, context):
    serial = event.get("serial") or event.get("thingName") or "UNKNOWN"

    ok, reason = _validate(event)
    if not ok:
        print(f"[HEARTBEAT][REJECT] serial={serial} reason={reason} event={json.dumps(event)}")
        return {"statusCode": 400, "body": f"invalid payload: {reason}"}

    ts = _parse_iso(event["ts"])
    ts_iso = ts.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    battery_pct = float(event["battery_pct"])
    rsrp = float(event["rsrp_dbm"])
    snr = float(event["snr_db"])

    # 1. Partial update on device registry.
    #    SET expressions preserve walkerUserId and anything else written
    #    by other flows (provisioning, device-linking).
    update_expr_parts = [
        "lastSeen = :ts",
        "lastHeartbeatAt = :ts",
        "batteryPct = :bpct",
        "batteryMv = :bmv",
        "rsrpDbm = :rsrp",
        "snrDb = :snr",
        "uptimeS = :up",
    ]
    eav: dict = {
        ":ts": ts_iso,
        ":bpct": Decimal(str(battery_pct)),
        ":bmv": int(event.get("battery_mv", 0)) or None,
        ":rsrp": Decimal(str(rsrp)),
        ":snr": Decimal(str(snr)),
        ":up": int(event.get("uptime_s", 0)),
    }
    # battery_mv is optional — strip if the firmware didn't send it.
    if eav[":bmv"] is None:
        update_expr_parts = [p for p in update_expr_parts if not p.startswith("batteryMv")]
        eav.pop(":bmv")

    firmware = event.get("firmware")
    if firmware:
        update_expr_parts.append("firmwareVersion = :fw")
        eav[":fw"] = str(firmware)

    update_expression = "SET " + ", ".join(update_expr_parts)

    walker_id: str | None = None
    try:
        resp = _device_tbl.update_item(
            Key={"serialNumber": serial},
            UpdateExpression=update_expression,
            ExpressionAttributeValues=eav,
            ReturnValues="ALL_NEW",
        )
        walker_id = resp.get("Attributes", {}).get("walkerUserId")
    except ClientError as e:
        print(f"[HEARTBEAT][ERROR] device update failed for {serial}: {e}")
        raise

    print(
        f"[HEARTBEAT][OK] serial={serial} ts={ts_iso} battery={battery_pct:.2f} "
        f"rsrp={rsrp} snr={snr} fw={firmware} walker={walker_id}"
    )

    # 2. Threshold checks → synthetic alerts.
    snapshot = {
        "batteryPct": Decimal(str(battery_pct)),
        "batteryMv": int(event.get("battery_mv", 0)) or None,
        "rsrpDbm": Decimal(str(rsrp)),
        "snrDb": Decimal(str(snr)),
    }
    snapshot = {k: v for k, v in snapshot.items() if v is not None}

    for alert_type, severity in _determine_alerts(battery_pct, rsrp):
        _write_synthetic_alert(serial, walker_id, ts_iso, alert_type, severity, snapshot)

    return {"statusCode": 200, "body": f"Heartbeat recorded for {serial}"}

"""
Threshold Detector Lambda — Phase 1B revision (NEW)

Triggered by: IoT Rule on `$aws/things/+/shadow/update/accepted`
IoT Rule SQL:
    SELECT current.state.reported AS reported,
           previous.state.reported AS previous_reported,
           topic(3)               AS thingName,
           timestamp()            AS rule_ts_ms
    FROM '$aws/things/+/shadow/update/accepted'

Replaces the deployed heartbeat-processor's threshold-checking role.

Logic:
  1. Extract thingName (= serial) from rule SQL.
  2. GetItem Device Registry → check `activated_at`.
  3. Pre-activation suppression (DL13 / L7): if `activated_at` is null,
     skip threshold detection. Sample audit log
     `device.preactivation_heartbeat` at ≤1 / hour / serial via Shadow
     `reported.lastPreactivationAuditAt` dedupe attribute (D12).
  4. Resolve patient via shared serial → DeviceAssignments → Patients
     pipeline.
  5. Battery + signal threshold check on `current.state.reported`.
     Critical/low and lost/weak are mutually exclusive per dimension
     (D7); both dimensions can fire on the same shadow update.
  6. Conditional PutItem to Alert History per breach: source="cloud",
     hierarchy snapshot, expiresAt = eventTimestamp + 24mo, compound SK.
  7. Audit `alert.synthetic.create` per alert written.
"""

from __future__ import annotations

import json
import os
from datetime import datetime, timedelta, timezone
from decimal import Decimal
from typing import Any

import boto3
from botocore.exceptions import ClientError

from _shared import (
    PatientContext,
    determine_threshold_alerts,
    emit_audit,
    get_logger,
    get_metrics,
    resolve_patient,
)
from aws_lambda_powertools.metrics import MetricUnit

# ── Configuration ────────────────────────────────────────────────
ALERT_TABLE = os.environ["ALERT_TABLE"]
DEVICE_TABLE = os.environ["DEVICE_TABLE"]
PRE_ACTIVATION_AUDIT_HOURS = int(os.environ.get("PRE_ACTIVATION_AUDIT_SAMPLE_HOURS", "1"))

# 24 months on Alerts (L5 / 0B-rev D2).
ALERT_TTL_SECONDS = 24 * 30 * 86_400

logger = get_logger()
metrics = get_metrics()

_iot_data = boto3.client("iot-data")
_ddb = boto3.resource("dynamodb")
_alert_tbl = _ddb.Table(ALERT_TABLE)
_device_tbl = _ddb.Table(DEVICE_TABLE)


def _parse_iso(ts: str) -> datetime:
    return datetime.fromisoformat(ts.replace("Z", "+00:00"))


def _now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _f(value: Any) -> float | None:
    if value is None:
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def _maybe_emit_preactivation_audit(serial: str) -> None:
    """
    Sample `device.preactivation_heartbeat` at ≤1 / hour / serial via Shadow
    `reported.lastPreactivationAuditAt`. Read-then-conditional-update; race
    is benign (worst case: an extra audit entry).
    """
    now = datetime.now(timezone.utc)
    cutoff = now - timedelta(hours=PRE_ACTIVATION_AUDIT_HOURS)
    try:
        resp = _iot_data.get_thing_shadow(thingName=serial)
        shadow = json.loads(resp["payload"].read())
    except ClientError as e:
        if e.response.get("Error", {}).get("Code") == "ResourceNotFoundException":
            shadow = {}
        else:
            logger.exception("preactivation_shadow_get_failed", extra={"serial": serial})
            return
    last_audit = (
        shadow.get("state", {}).get("reported", {}).get("lastPreactivationAuditAt")
    )
    if last_audit:
        try:
            if _parse_iso(str(last_audit)) >= cutoff:
                return  # within sample window — skip
        except (TypeError, ValueError):
            pass

    audit_iso = now.strftime("%Y-%m-%dT%H:%M:%SZ")
    try:
        _iot_data.update_thing_shadow(
            thingName=serial,
            payload=json.dumps(
                {"state": {"reported": {"lastPreactivationAuditAt": audit_iso}}}
            ).encode("utf-8"),
        )
    except ClientError:
        # Non-fatal; the audit may double-fire next invocation — acceptable.
        logger.exception("preactivation_audit_dedupe_write_failed", extra={"serial": serial})

    emit_audit(
        "device.preactivation_heartbeat",
        subject={"deviceSerial": serial},
        action="observe",
        extra={"sampledAt": audit_iso},
    )
    metrics.add_metric(
        name="preactivation_audit_count", unit=MetricUnit.Count, value=1
    )


def _write_synthetic_alert(
    serial: str,
    patient: PatientContext,
    event_ts_iso: str,
    alert_type: str,
    severity: str,
    snapshot: dict[str, Any],
) -> bool:
    """
    Conditional PutItem with compound SK `{eventTs}#{alertType}`. Returns
    True on first write, False on duplicate (idempotent). Failures NOT
    swallowed — they propagate so the IoT Rule can DLQ if it ever fires
    sync (in practice IoT Rule Lambda actions are async; errors land in
    Lambda Errors metric — see Phase 1A revision T12 caveat).
    """
    sk = f"{event_ts_iso}#{alert_type}"
    expires_at = int(_parse_iso(event_ts_iso).timestamp()) + ALERT_TTL_SECONDS
    item: dict[str, Any] = {
        "patientId": patient.patientId,
        "timestamp": sk,
        "deviceSerial": serial,
        "clientId": patient.clientId,
        "facilityId": patient.facilityId,
        "censusId": patient.censusId,
        "eventTimestamp": event_ts_iso,
        "alertType": alert_type,
        "severity": severity,
        "source": "cloud",
        "acknowledged": False,
        "data": snapshot,
        "createdAt": _now_iso(),
        "expiresAt": expires_at,
    }
    try:
        _alert_tbl.put_item(
            Item=item,
            ConditionExpression="attribute_not_exists(patientId) AND attribute_not_exists(#ts)",
            ExpressionAttributeNames={"#ts": "timestamp"},
        )
        return True
    except ClientError as e:
        if e.response["Error"]["Code"] == "ConditionalCheckFailedException":
            logger.info(
                "synthetic_alert_duplicate",
                extra={
                    "serial": serial,
                    "patientId": patient.patientId,
                    "alertType": alert_type,
                    "sk": sk,
                },
            )
            return False
        logger.exception(
            "synthetic_alert_write_failed",
            extra={"serial": serial, "alertType": alert_type},
        )
        raise


@logger.inject_lambda_context(log_event=False, correlation_id_path="thingName")
@metrics.log_metrics(capture_cold_start_metric=True)
def handler(event: dict, _context):
    serial = event.get("thingName")
    if not serial:
        logger.warning("threshold_detector_no_serial", extra={"event_keys": list(event.keys())})
        return {"statusCode": 400, "body": "missing thingName"}

    reported = event.get("reported") or {}
    if not isinstance(reported, dict):
        logger.warning("threshold_detector_no_reported", extra={"serial": serial})
        return {"statusCode": 200, "body": "no reported state; nothing to do"}

    # Pre-activation gate ----------------------------------------------
    try:
        device = _device_tbl.get_item(Key={"serialNumber": serial}).get("Item") or {}
    except ClientError:
        logger.exception("device_registry_get_failed", extra={"serial": serial})
        raise
    activated_at = device.get("activated_at")
    if not activated_at:
        _maybe_emit_preactivation_audit(serial)
        return {"statusCode": 200, "body": "pre-activation; suppressed"}

    # Threshold evaluation ---------------------------------------------
    battery_pct = _f(reported.get("battery_pct"))
    rsrp_dbm = _f(reported.get("rsrp_dbm"))
    breaches = determine_threshold_alerts(battery_pct, rsrp_dbm)
    if not breaches:
        return {"statusCode": 200, "body": "no threshold breach"}

    patient = resolve_patient(serial)
    if patient is None:
        logger.warning(
            "unmapped_serial",
            extra={"serial": serial, "stage": "threshold-detector"},
        )
        metrics.add_metric(name="unmapped_serial_count", unit=MetricUnit.Count, value=1)
        return {"statusCode": 200, "body": "no active assignment; alerts dropped"}

    event_ts_raw = reported.get("ts") or reported.get("lastSeen")
    try:
        event_ts = _parse_iso(str(event_ts_raw))
    except (TypeError, ValueError):
        event_ts = datetime.now(timezone.utc)
    event_ts_iso = event_ts.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    snapshot: dict[str, Any] = {}
    if battery_pct is not None:
        snapshot["batteryPct"] = Decimal(str(battery_pct))
    if rsrp_dbm is not None:
        snapshot["rsrpDbm"] = Decimal(str(rsrp_dbm))
    snr_db = _f(reported.get("snr_db"))
    if snr_db is not None:
        snapshot["snrDb"] = Decimal(str(snr_db))

    written_count = 0
    for alert_type, severity in breaches:
        wrote = _write_synthetic_alert(
            serial=serial,
            patient=patient,
            event_ts_iso=event_ts_iso,
            alert_type=alert_type,
            severity=severity,
            snapshot=snapshot,
        )
        if wrote:
            written_count += 1
            metrics.add_metric(
                name="synthetic_alert_count",
                unit=MetricUnit.Count,
                value=1,
            )
            metrics.add_metadata(key="alert_type", value=alert_type)
            emit_audit(
                "alert.synthetic.create",
                subject={
                    "patientId": patient.patientId,
                    "clientId": patient.clientId,
                    "censusId": patient.censusId,
                    "deviceSerial": serial,
                },
                action="create",
                after={
                    "alertType": alert_type,
                    "severity": severity,
                    "eventTimestamp": event_ts_iso,
                },
            )

    return {
        "statusCode": 200,
        "body": f"{written_count} synthetic alert(s) written for patient={patient.patientId}",
    }

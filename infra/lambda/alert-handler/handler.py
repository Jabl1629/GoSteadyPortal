"""
Alert Handler Lambda — Phase 1B revision

Triggered by: IoT Rule on gs/+/alert
IoT Rule SQL: SELECT *, topic(2) AS thingName FROM 'gs/+/alert'

Phase 1B revision changes (vs deployed Phase 1B original):
  - Patient-centric PK on Alert table (PK=patientId, SK=`{eventTs}#{alertType}`).
  - Hierarchy snapshot (clientId/facilityId/censusId) frozen at write time
    per S6 / T4.
  - `expiresAt` TTL column (epoch seconds, eventTimestamp + 24 months).
  - Powertools structured logging + metrics + audit emission.
  - ARM64 runtime per G7.
  - source="device" (synthetic alerts go through threshold-detector with
    source="cloud").
"""

from __future__ import annotations

import os
from datetime import datetime, timezone
from decimal import Decimal
from typing import Any

import boto3
from botocore.exceptions import ClientError

from _shared import (
    PatientContext,
    emit_audit,
    get_logger,
    get_metrics,
    resolve_patient,
)
from aws_lambda_powertools.metrics import MetricUnit

# ── Configuration ────────────────────────────────────────────────
ALERT_TABLE = os.environ["ALERT_TABLE"]

# 24 months on Alerts (L5 / 0B-rev D2).
ALERT_TTL_SECONDS = 24 * 30 * 86_400

VALID_ALERT_TYPES = {"tipover", "fall", "impact"}
VALID_SEVERITIES = {"critical", "warning", "info"}
REQUIRED_FIELDS = ("ts", "alert_type", "severity")

logger = get_logger()
metrics = get_metrics()

_ddb = boto3.resource("dynamodb")
_alert_tbl = _ddb.Table(ALERT_TABLE)


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


def _to_ddb_safe(value: Any) -> Any:
    """Recursive float→Decimal sanitization for DynamoDB."""
    if isinstance(value, float):
        return Decimal(str(value))
    if isinstance(value, dict):
        return {k: _to_ddb_safe(v) for k, v in value.items()}
    if isinstance(value, list):
        return [_to_ddb_safe(v) for v in value]
    return value


@logger.inject_lambda_context(log_event=False, correlation_id_path="thingName")
@metrics.log_metrics(capture_cold_start_metric=True)
def handler(event: dict, _context):
    serial = event.get("serial") or event.get("thingName") or "UNKNOWN"

    ok, reason = _validate(event)
    if not ok:
        logger.warning("alert_reject", extra={"serial": serial, "reason": reason})
        metrics.add_metric(name="alert_reject_count", unit=MetricUnit.Count, value=1)
        return {"statusCode": 400, "body": f"invalid payload: {reason}"}

    patient: PatientContext | None = resolve_patient(serial)
    if patient is None:
        logger.warning(
            "unmapped_serial",
            extra={"serial": serial, "stage": "alert-handler"},
        )
        metrics.add_metric(name="unmapped_serial_count", unit=MetricUnit.Count, value=1)
        return {"statusCode": 200, "body": "no active assignment; dropped"}

    ts = _parse_iso(event["ts"])
    ts_iso = ts.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    alert_type = event["alert_type"]
    severity = event["severity"]
    sk = f"{ts_iso}#{alert_type}"
    expires_at = int(ts.astimezone(timezone.utc).timestamp()) + ALERT_TTL_SECONDS

    item: dict[str, Any] = {
        "patientId": patient.patientId,
        "timestamp": sk,
        "deviceSerial": serial,
        "clientId": patient.clientId,
        "facilityId": patient.facilityId,
        "censusId": patient.censusId,
        "eventTimestamp": ts_iso,
        "alertType": alert_type,
        "severity": severity,
        "source": "device",
        "acknowledged": False,
        "createdAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "expiresAt": expires_at,
    }

    if isinstance(event.get("data"), dict):
        item["data"] = _to_ddb_safe(event["data"])

    try:
        _alert_tbl.put_item(
            Item=item,
            ConditionExpression="attribute_not_exists(patientId) AND attribute_not_exists(#ts)",
            ExpressionAttributeNames={"#ts": "timestamp"},
        )
    except ClientError as e:
        if e.response["Error"]["Code"] == "ConditionalCheckFailedException":
            logger.info(
                "alert_duplicate",
                extra={
                    "serial": serial,
                    "patientId": patient.patientId,
                    "alertType": alert_type,
                    "sk": sk,
                },
            )
            return {"statusCode": 200, "body": "duplicate alert ignored"}
        logger.exception("alert_write_failed", extra={"serial": serial, "alertType": alert_type})
        metrics.add_metric(name="alert_write_error_count", unit=MetricUnit.Count, value=1)
        raise

    metrics.add_metric(name="device_alert_count", unit=MetricUnit.Count, value=1)
    metrics.add_metadata(key="alert_type", value=alert_type)
    emit_audit(
        "alert.device.create",
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
            "eventTimestamp": ts_iso,
        },
    )

    logger.info(
        "alert_ok",
        extra={
            "serial": serial,
            "patientId": patient.patientId,
            "alertType": alert_type,
            "severity": severity,
        },
    )
    return {
        "statusCode": 200,
        "body": f"alert recorded for patient={patient.patientId} type={alert_type}",
    }

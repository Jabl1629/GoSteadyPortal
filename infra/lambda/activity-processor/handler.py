"""
Activity Processor Lambda — Phase 1B revision

Triggered by: IoT Rule on gs/+/activity
IoT Rule SQL: SELECT *, topic(2) AS thingName FROM 'gs/+/activity'

Phase 1B revision changes (vs deployed Phase 1B original):
  - Patient-centric PK on Activity table (PK=patientId, SK=sessionEnd) per
    architecture S1 / 0B revision.
  - Hierarchy snapshot (clientId/facilityId/censusId) frozen at write time
    per S6 / T4. Resolved via the shared serial → DeviceAssignments →
    Patients pipeline.
  - `expiresAt` TTL column (epoch seconds, sessionEnd + 13 months) per L5.
  - Optional firmware-derived extras (`roughness_R`, `surface_class`,
    `firmware_version`) plus an `extras` map for any other unknown fields
    per D14 / D16.
  - Powertools structured logging + metrics + audit emission per L13/L16.
  - ARM64 runtime per G7.
"""

from __future__ import annotations

import os
from datetime import datetime, timezone
from decimal import Decimal
from typing import Any
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

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
ACTIVITY_TABLE = os.environ["ACTIVITY_TABLE"]

# 13 months = 13 × 30 × 86400 seconds ≈ retention horizon (L5 / 0B-rev D2).
ACTIVITY_TTL_SECONDS = 13 * 30 * 86_400

# Validation bounds — the goal is to reject obvious garbage, not second-
# guess on-device sensor fusion.
MAX_STEPS = 100_000
MAX_DISTANCE_FT = 50_000
MAX_ACTIVE_MIN = 1_440

REQUIRED_FIELDS = ("session_start", "session_end", "steps", "distance_ft", "active_min")
NAMED_FIELDS = {
    *REQUIRED_FIELDS,
    "serial",
    "thingName",
    "roughness_R",
    "surface_class",
    "firmware_version",
}
ALLOWED_SURFACE_CLASS = {"indoor", "outdoor"}

logger = get_logger()
metrics = get_metrics()

_ddb = boto3.resource("dynamodb")
_activity_tbl = _ddb.Table(ACTIVITY_TABLE)


def _parse_iso(ts: str) -> datetime:
    return datetime.fromisoformat(ts.replace("Z", "+00:00"))


def _validate(event: dict) -> tuple[bool, str]:
    for f in REQUIRED_FIELDS:
        if f not in event:
            return False, f"missing:{f}"
    try:
        ss = _parse_iso(event["session_start"])
        se = _parse_iso(event["session_end"])
    except (TypeError, ValueError) as e:
        return False, f"bad_timestamp:{e}"
    if se < ss:
        return False, "session_end<session_start"
    try:
        steps = int(event["steps"])
        distance = float(event["distance_ft"])
        active = int(event["active_min"])
    except (TypeError, ValueError) as e:
        return False, f"bad_number:{e}"
    if not 0 <= steps <= MAX_STEPS:
        return False, f"steps_out_of_range:{steps}"
    if not 0 <= distance <= MAX_DISTANCE_FT:
        return False, f"distance_out_of_range:{distance}"
    if not 0 <= active <= MAX_ACTIVE_MIN:
        return False, f"active_out_of_range:{active}"
    return True, "ok"


def _local_date(session_start: datetime, tz_name: str) -> str:
    try:
        return session_start.astimezone(ZoneInfo(tz_name)).strftime("%Y-%m-%d")
    except ZoneInfoNotFoundError:
        logger.warning("unknown_timezone", extra={"timezone": tz_name})
        return session_start.astimezone(timezone.utc).strftime("%Y-%m-%d")


def _to_decimal(value: Any) -> Any:
    if isinstance(value, float):
        return Decimal(str(value))
    if isinstance(value, dict):
        return {k: _to_decimal(v) for k, v in value.items()}
    if isinstance(value, list):
        return [_to_decimal(v) for v in value]
    return value


def _build_extras(event: dict) -> dict[str, Any]:
    return {k: _to_decimal(v) for k, v in event.items() if k not in NAMED_FIELDS}


@logger.inject_lambda_context(log_event=False, correlation_id_path="thingName")
@metrics.log_metrics(capture_cold_start_metric=True)
def handler(event: dict, _context):
    serial = event.get("serial") or event.get("thingName") or "UNKNOWN"

    ok, reason = _validate(event)
    if not ok:
        logger.warning("activity_reject", extra={"serial": serial, "reason": reason})
        metrics.add_metric(name="activity_reject_count", unit=MetricUnit.Count, value=1)
        return {"statusCode": 400, "body": f"invalid payload: {reason}"}

    patient: PatientContext | None = resolve_patient(serial)
    if patient is None:
        logger.warning(
            "unmapped_serial",
            extra={"serial": serial, "stage": "activity-processor"},
        )
        metrics.add_metric(name="unmapped_serial_count", unit=MetricUnit.Count, value=1)
        return {"statusCode": 200, "body": "no active assignment; dropped"}

    ss = _parse_iso(event["session_start"])
    se = _parse_iso(event["session_end"])
    session_start_iso = ss.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    session_end_iso = se.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    expires_at = int(se.astimezone(timezone.utc).timestamp()) + ACTIVITY_TTL_SECONDS

    surface_class = event.get("surface_class")
    if surface_class is not None and surface_class not in ALLOWED_SURFACE_CLASS:
        logger.warning(
            "unknown_surface_class",
            extra={"serial": serial, "surface_class": surface_class},
        )
        surface_class = None

    item: dict[str, Any] = {
        "patientId": patient.patientId,
        "timestamp": session_end_iso,
        "deviceSerial": serial,
        "clientId": patient.clientId,
        "facilityId": patient.facilityId,
        "censusId": patient.censusId,
        "sessionStart": session_start_iso,
        "sessionEnd": session_end_iso,
        "steps": int(event["steps"]),
        "distanceFt": Decimal(str(event["distance_ft"])),
        "activeMinutes": int(event["active_min"]),
        "date": _local_date(ss, patient.timezone),
        "timezone": patient.timezone,
        "source": "device",
        "ingestedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "expiresAt": expires_at,
    }

    if "roughness_R" in event:
        item["roughnessR"] = Decimal(str(event["roughness_R"]))
    if surface_class is not None:
        item["surfaceClass"] = surface_class
    if "firmware_version" in event:
        item["firmwareVersion"] = str(event["firmware_version"])

    extras = _build_extras(event)
    if extras:
        item["extras"] = extras

    try:
        _activity_tbl.put_item(
            Item=item,
            ConditionExpression="attribute_not_exists(patientId) AND attribute_not_exists(#ts)",
            ExpressionAttributeNames={"#ts": "timestamp"},
        )
    except ClientError as e:
        if e.response["Error"]["Code"] == "ConditionalCheckFailedException":
            logger.info(
                "activity_duplicate",
                extra={"serial": serial, "patientId": patient.patientId, "sessionEnd": session_end_iso},
            )
            return {"statusCode": 200, "body": "duplicate session ignored"}
        logger.exception("activity_write_failed", extra={"serial": serial})
        metrics.add_metric(name="activity_write_error_count", unit=MetricUnit.Count, value=1)
        raise

    metrics.add_metric(name="activity_session_count", unit=MetricUnit.Count, value=1)
    # Phase 1.6 follow-up 2026-05-05: include the firmware-derived optional
    # fields in the audit `after` block so the Per-Device Detail dashboard's
    # Logs Insights widget can render distance / R / surface / firmware
    # columns. Without these the widget could only surface `steps` (verified
    # against bench unit GS9999999999 — 3 real walks landed in DDB with
    # 38/22/72 steps + correct distance/R/surface, but dashboard showed only
    # the `steps` column populated). Optional fields are included only when
    # the firmware actually supplied them; cloud-side accept-all contract D16.
    audit_after: dict = {
        "sessionEnd": session_end_iso,
        "steps": item["steps"],
        "distanceFt": item["distanceFt"],
        "activeMinutes": item["activeMinutes"],
        "date": item["date"],
    }
    if "roughnessR" in item:
        audit_after["roughnessR"] = item["roughnessR"]
    if "surfaceClass" in item:
        audit_after["surfaceClass"] = item["surfaceClass"]
    if "firmwareVersion" in item:
        audit_after["firmwareVersion"] = item["firmwareVersion"]

    emit_audit(
        "patient.activity.create",
        subject={
            "patientId": patient.patientId,
            "clientId": patient.clientId,
            "censusId": patient.censusId,
            "deviceSerial": serial,
        },
        action="create",
        after=audit_after,
    )

    logger.info(
        "activity_ok",
        extra={
            "serial": serial,
            "patientId": patient.patientId,
            "sessionEnd": session_end_iso,
            "steps": item["steps"],
        },
    )
    return {
        "statusCode": 200,
        "body": f"activity recorded for patient={patient.patientId} steps={item['steps']}",
    }

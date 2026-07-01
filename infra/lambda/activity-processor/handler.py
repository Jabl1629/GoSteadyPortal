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

Phase DT-0 (2026-07-01, phase-dt0-device-type-scaffold.md):
  - Per-type metric validation + named-column promotion dispatched via
    _shared/device_types on the assignment row's deviceType snapshot
    (resolution now runs BEFORE metric validation — spec D2; the registry,
    not the payload, picks the contract).
  - `deviceType` denormalized onto every Activity row.
  - Auto-resume re-keyed on activeMinutes (the universal metric — spec D4;
    `steps` doesn't exist on rollator bench-v0 rows).
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
    device_types,
    emit_audit,
    get_logger,
    get_metrics,
    resolve_patient,
)
from _shared.device_time import (
    TIME_SOURCE_RECONSTRUCTED,
    TIME_SOURCE_UNCERTAIN,
    resolve_session_times,
)
from _shared.pause_check import days_remaining, is_currently_paused
from aws_lambda_powertools.metrics import MetricUnit

# ── Configuration ────────────────────────────────────────────────
ACTIVITY_TABLE = os.environ["ACTIVITY_TABLE"]
# Phase 2A-UM-P L10 — patients table lookup for auto-resume on activity.
PATIENTS_TABLE = os.environ.get("PATIENTS_TABLE", "gosteady-dev-patients")
# Activity threshold for auto-resume; spec A6: default 0 (any activity
# clears the pause — "the reason for pausing is gone"). Tunable via env
# if false-positives become a complaint. DT-0 spec D4: keyed on
# activeMinutes (the universal cross-type metric) — `steps` doesn't exist
# on rollator bench-v0 rows. Default-0 semantics identical to the old
# AUTO_RESUME_MIN_STEPS (which was never set anywhere).
AUTO_RESUME_MIN_ACTIVE_MIN = int(os.environ.get("AUTO_RESUME_MIN_ACTIVE_MIN", "0"))

# 13 months = 13 × 30 × 86400 seconds ≈ retention horizon (L5 / 0B-rev D2).
ACTIVITY_TTL_SECONDS = 13 * 30 * 86_400

# Per-type validation bounds + metric promotion live in _shared/device_types
# (Phase DT-0), dispatched on the assignment row's deviceType snapshot.
# Timestamps are resolved separately by resolve_session_times and NEVER cause
# a reject (spec §4.3 never-drop): a missing/implausible session_start/_end
# under clock_synced=false is reconstructed from the upload receive time +
# monotonic uptimes.
#
# The universal envelope fields below are device-agnostic; the effective
# extras-exclusion set at runtime is UNIVERSAL_NAMED_FIELDS ∪ the resolved
# type module's ACTIVITY_NAMED_FIELDS (walker's union reproduces the
# pre-DT-0 NAMED_FIELDS exactly).
UNIVERSAL_NAMED_FIELDS = {
    "session_start",
    "session_end",
    "serial",
    "thingName",
    "firmware_version",
    # 0.17.0-time device fields — consumed by resolve_session_times; named so
    # they don't land in the `extras` catch-all.
    "clock_synced",
    "session_start_uptime_ms",
    "session_end_uptime_ms",
    "publish_uptime_ms",
    "boot_count",
    "time_source",
    # DT-0 Q7: firmware self-reports its type in the heartbeat; if it ever
    # appears on activity payloads too, keep it out of extras (registry is
    # authoritative — the payload value is never stored).
    "device_type",
}

logger = get_logger()
metrics = get_metrics()

_ddb = boto3.resource("dynamodb")
_activity_tbl = _ddb.Table(ACTIVITY_TABLE)
_patients_tbl = _ddb.Table(PATIENTS_TABLE)


def _maybe_auto_resume_pause(
    patient: PatientContext, active_minutes: int, session_end_iso: str
) -> None:
    """
    Phase 2A-UM-P L10 — auto-resume notification pause when fresh activity
    arrives. Per user-needs US-31: "auto-resumes early if activity data
    starts streaming again before the timer expires (the reason for
    pausing is gone)."

    DT-0 spec D4: keyed on activeMinutes — the universal cross-type metric,
    present on every persisted row for every device type. Default threshold
    0 keeps the "any persisted activity clears the pause" semantic.

    Best-effort: failures are logged but don't break the activity write.
    Conditional `attribute_exists` on REMOVE handles the race where a
    manual unpause already cleared the attribute between our resolve
    and this update.
    """
    if not is_currently_paused({"notificationsPaused": patient.notificationsPaused}):
        return
    if active_minutes < AUTO_RESUME_MIN_ACTIVE_MIN:
        return  # below noise threshold — don't auto-resume

    pause = patient.notificationsPaused or {}
    days_left_before = days_remaining({"notificationsPaused": pause})

    try:
        _patients_tbl.update_item(
            Key={"patientId": patient.patientId},
            UpdateExpression="REMOVE notificationsPaused",
            ConditionExpression="attribute_exists(notificationsPaused)",
        )
    except ClientError as exc:
        code = exc.response.get("Error", {}).get("Code", "")
        if code == "ConditionalCheckFailedException":
            # Manual unpause raced us. Benign.
            logger.info(
                "auto_resume_lost_race",
                extra={"patientId": patient.patientId},
            )
            return
        logger.exception(
            "auto_resume_update_failed",
            extra={"patientId": patient.patientId},
        )
        return

    emit_audit(
        "patient.notifications.resume_auto",
        subject={
            "patientId": patient.patientId,
            "clientId": patient.clientId,
            "facilityId": patient.facilityId,
            "censusId": patient.censusId,
            "deviceSerial": patient.deviceSerial,
        },
        action="update",
        before={"notificationsPaused": pause},
        after={"notificationsPaused": None},
        extra={
            "triggeringActivity": {
                "sessionEnd": session_end_iso,
                "activeMinutes": active_minutes,
            },
            "pauseHadDaysRemaining": days_left_before,
            "pauseReason": pause.get("reason"),
        },
    )
    metrics.add_metric(name="notifications_auto_resume_count", unit=MetricUnit.Count, value=1)


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


def _build_extras(event: dict, named_fields: frozenset[str] | set[str]) -> dict[str, Any]:
    return {k: _to_decimal(v) for k, v in event.items() if k not in named_fields}


@logger.inject_lambda_context(log_event=False, correlation_id_path="thingName")
@metrics.log_metrics(capture_cold_start_metric=True)
def handler(event: dict, _context):
    serial = event.get("serial") or event.get("thingName") or "UNKNOWN"

    # DT-0 spec D2: resolve the patient FIRST — the metric-validation contract
    # is keyed by the assignment row's deviceType snapshot (the registry, not
    # the payload, picks the contract). Ordering consequence: garbage metrics
    # from unmapped serials now short-circuit at `unmapped_serial` instead of
    # `activity_reject` — both are warn+metric+alarmed paths.
    patient: PatientContext | None = resolve_patient(serial)
    if patient is None:
        logger.warning(
            "unmapped_serial",
            extra={"serial": serial, "stage": "activity-processor"},
        )
        metrics.add_metric(name="unmapped_serial_count", unit=MetricUnit.Count, value=1)
        return {"statusCode": 200, "body": "no active assignment; dropped"}

    if not device_types.is_known(patient.deviceType):
        # A typo'd registry/assignment value bulk-create validation should
        # have prevented. Fall back to the walker contract (D9) but surface it.
        logger.warning(
            "unknown_device_type",
            extra={"serial": serial, "deviceType": patient.deviceType},
        )
        metrics.add_metric(name="unknown_device_type_count", unit=MetricUnit.Count, value=1)
    dtype = device_types.resolve(patient.deviceType)

    ok, reason = dtype.validate_activity_metrics(event)
    if not ok:
        logger.warning(
            "activity_reject",
            extra={"serial": serial, "reason": reason, "deviceType": dtype.TYPE},
        )
        metrics.add_metric(name="activity_reject_count", unit=MetricUnit.Count, value=1)
        # Metadata, NOT a dimension — a new dimension set would fork the metric
        # identity and detach the Phase 1.6 activity-reject alarm (spec D5).
        metrics.add_metadata(key="deviceType", value=dtype.TYPE)
        return {"statusCode": 400, "body": f"invalid payload: {reason}"}

    # spec §4.3: resolve the authoritative session times. `ingested_at` is our
    # trusted receive time and the reconstruction anchor when the device clock
    # was unsynced. Never rejects — activity is never dropped for lack of time.
    ingested_at = datetime.now(timezone.utc)
    ss, se, time_source = resolve_session_times(event, ingested_at)
    session_start_iso = ss.strftime("%Y-%m-%dT%H:%M:%SZ")
    session_end_iso = se.strftime("%Y-%m-%dT%H:%M:%SZ")
    expires_at = int(se.timestamp()) + ACTIVITY_TTL_SECONDS
    if time_source in (TIME_SOURCE_RECONSTRUCTED, TIME_SOURCE_UNCERTAIN):
        logger.warning(
            "activity_time_reconstructed",
            extra={
                "serial": serial,
                "timeSource": time_source,
                "clock_synced": event.get("clock_synced"),
                "deviceSessionEnd": event.get("session_end"),
                "resolvedSessionEnd": session_end_iso,
            },
        )
        metrics.add_metric(
            name=f"activity_time_{time_source}_count",
            unit=MetricUnit.Count,
            value=1,
        )

    # Per-type named-column promotion (DT-0). Optional analytic fields are
    # dropped (never fail the row) when unparseable / out of range — the
    # type module reports those drops as warning dicts and this handler logs
    # them (preserves the pre-DT-0 unknown_surface_class / gait_out_of_range
    # log lines for the walker).
    metric_attrs, metric_warnings = dtype.build_metric_attrs(event)
    for w in metric_warnings:
        logger.warning(
            w["warning"],
            extra={"serial": serial, **{k: v for k, v in w.items() if k != "warning"}},
        )

    item: dict[str, Any] = {
        "patientId": patient.patientId,
        "timestamp": session_end_iso,
        "deviceSerial": serial,
        # DT-0: type snapshot on every row (resolved contract type — matches
        # what validation actually enforced).
        "deviceType": dtype.TYPE,
        "clientId": patient.clientId,
        "facilityId": patient.facilityId,
        "censusId": patient.censusId,
        "sessionStart": session_start_iso,
        "sessionEnd": session_end_iso,
        "date": _local_date(ss, patient.timezone),
        "timezone": patient.timezone,
        "source": "device",
        "ingestedAt": ingested_at.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "expiresAt": expires_at,
        # 0.17.0-time: how this row's times were derived (device | nitz | ntp |
        # cloud_reconstructed | uncertain). Drives the "how often do we fall
        # back" dashboard breakdown.
        "timeSource": time_source,
    }
    item.update(metric_attrs)
    if "clock_synced" in event:
        item["deviceClockSynced"] = bool(event["clock_synced"])
    # Stable device-session identity (serial#boot#end_uptime). Survives
    # reconstruction (which varies sessionEnd across firmware retries), so a
    # future dedup job can collapse any reconstructed duplicates.
    if "boot_count" in event and "session_end_uptime_ms" in event:
        item["deviceSessionKey"] = (
            f"{serial}#{event.get('boot_count')}#{event.get('session_end_uptime_ms')}"
        )

    if "firmware_version" in event:
        item["firmwareVersion"] = str(event["firmware_version"])

    extras = _build_extras(event, UNIVERSAL_NAMED_FIELDS | dtype.ACTIVITY_NAMED_FIELDS)
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
        "activeMinutes": item["activeMinutes"],
        "date": item["date"],
        "timeSource": time_source,
        "deviceType": item["deviceType"],
    }
    # Per-type metrics — present for walker_cap always; absent on rollator
    # bench-v0 rows until the DT-2 parity set lands.
    if "steps" in item:
        audit_after["steps"] = item["steps"]
    if "distanceFt" in item:
        audit_after["distanceFt"] = item["distanceFt"]
    if "roughnessR" in item:
        audit_after["roughnessR"] = item["roughnessR"]
    if "surfaceClass" in item:
        audit_after["surfaceClass"] = item["surfaceClass"]
    if "firmwareVersion" in item:
        audit_after["firmwareVersion"] = item["firmwareVersion"]
    if "gaitSpeedFts" in item:
        audit_after["gaitSpeedFts"] = item["gaitSpeedFts"]

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

    # Phase 2A-UM-P L10 — auto-resume notification pause if any.
    # Runs AFTER the activity PutItem succeeds (so we only auto-resume
    # on real persisted activity, not on validation-rejected payloads).
    # Best-effort; failures logged but don't fail the activity write.
    # DT-0 D4: activeMinutes is guaranteed present for every type
    # (universal required metric).
    _maybe_auto_resume_pause(patient, item["activeMinutes"], session_end_iso)

    logger.info(
        "activity_ok",
        extra={
            "serial": serial,
            "patientId": patient.patientId,
            "sessionEnd": session_end_iso,
            "deviceType": item["deviceType"],
            "activeMinutes": item["activeMinutes"],
            "steps": item.get("steps"),
        },
    )
    return {
        "statusCode": 200,
        "body": (
            f"activity recorded for patient={patient.patientId} "
            f"activeMin={item['activeMinutes']}"
        ),
    }

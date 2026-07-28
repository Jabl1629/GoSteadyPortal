"""
Behavioral notification + offline detector Lambda — Phase 1C-slim.

Triggered hourly by EventBridge (spec L2). Per invocation:
  1. Enumerate all facilities (Organizations table Scan).
  2. For each facility:
       a. Compute facility-local now from facility.timezone.
       b. Route to applicable rule sets:
            local-11 (+ catch-up) → no_activity_today
            local-22 (+ catch-up) → below_typical + declining_trend
            (always)              → device_offline + device_silent
       c. Enumerate active patients in this facility (Patients GSI).
       d. For each (rule, patient):
            - Skip if patient.notificationsPaused.until > now
              (with sampled `suppressed_paused` audit per 2A-UM-P L9).
            - Skip if no active device assignment / no current device
              (offline rules need a device to be offline about).
            - Evaluate rule.
            - Conditional PutItem on Alert History per spec L5.
            - Emit `alert.synthetic.create` audit per fire.
  3. Emit `behavioral.detector.run` summary audit.

The Lambda is reserved-concurrency=1 (cron Lambda; no parallelism needed
for correctness, and serializing avoids the rare race where two
overlapping invocations both attempt the same conditional PutItem).
"""

from __future__ import annotations

import os
import time
from datetime import datetime
from decimal import Decimal
from typing import Any, Iterable, Optional

import boto3
from boto3.dynamodb.conditions import Key
from botocore.exceptions import ClientError

from _shared import emit_audit, get_logger, get_metrics, resolve_patient
from _shared.device_types import primary_activity_metric
from _shared.pause_check import is_currently_paused
from aws_lambda_powertools.metrics import MetricUnit

import facility_iterator
import history_window
import patient_iterator
from facility_iterator import FacilityContext, RuleSet, list_facilities, rule_set_for_facility
from history_window import (
    HISTORY_DAYS,
    aggregate_metric_per_day,
    facility_local_midnight,
    query_activity_for_today,
    query_activity_history,
    sum_metric,
)
from patient_iterator import list_active_patients
from rules import below_typical, declining_trend, device_offline, no_activity_today
from rules.types import (
    ALERT_DEVICE_OFFLINE,
    ALERT_DEVICE_SILENT,
    DEFAULT_OFFLINE_THRESHOLD_HOURS,
    DEFAULT_SILENT_THRESHOLD_HOURS,
)

from _shared.open_alerts import auto_ack_alert, claim_open_alert

# Continuous-condition alert types this Lambda emits — see
# `docs/specs/2026-05-26-alert-recurrence-policy.md` L2. These
# participate in the open-alert state machine; same-type re-fires
# while the prior alert is open are suppressed.
_CONTINUOUS_ALERT_TYPES = frozenset({
    ALERT_DEVICE_OFFLINE,
    ALERT_DEVICE_SILENT,
})
from rules.types import AlertCandidate


ENV = os.environ.get("ENVIRONMENT", "dev")
PATIENTS_TABLE = os.environ["PATIENTS_TABLE"]
ACTIVITY_TABLE = os.environ["ACTIVITY_TABLE"]
ALERT_TABLE = os.environ["ALERT_TABLE"]
ORGANIZATIONS_TABLE = os.environ["ORGANIZATIONS_TABLE"]
DEVICES_TABLE = os.environ["DEVICES_TABLE"]
ASSIGNMENTS_TABLE = os.environ["ASSIGNMENTS_TABLE"]

# 24 months on Alerts (matches 1B-rev / spec L4 — reuses Alert History).
ALERT_TTL_SECONDS = 24 * 30 * 86_400

logger = get_logger()
metrics = get_metrics()

_ddb = boto3.resource("dynamodb")
_patients_tbl = _ddb.Table(PATIENTS_TABLE)
_activity_tbl = _ddb.Table(ACTIVITY_TABLE)
_alert_tbl = _ddb.Table(ALERT_TABLE)
_orgs_tbl = _ddb.Table(ORGANIZATIONS_TABLE)
_devices_tbl = _ddb.Table(DEVICES_TABLE)
_assignments_tbl = _ddb.Table(ASSIGNMENTS_TABLE)


# ── Helpers ───────────────────────────────────────────────────────────


def _now_epoch() -> int:
    return int(time.time())


def _utc_iso(ts: float | None = None) -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(ts))


def _device_last_seen_epoch(device: dict[str, Any]) -> Optional[int]:
    """Parse Device Registry `lastSeen` (ISO string or epoch) to epoch int."""
    val = device.get("lastSeen") or device.get("firstHeartbeatAt")
    if val is None:
        return None
    if isinstance(val, (int, float, Decimal)):
        return int(val)
    if isinstance(val, str):
        try:
            return int(datetime.fromisoformat(val.replace("Z", "+00:00")).timestamp())
        except (TypeError, ValueError):
            return None
    return None


def _get_active_assignment(patient_id: str) -> Optional[dict[str, Any]]:
    """Return the active DeviceAssignment row for a patient (validUntil absent)."""
    try:
        res = _assignments_tbl.query(
            IndexName="by-patient",
            KeyConditionExpression=Key("patientId").eq(patient_id),
        )
    except ClientError:
        logger.exception("assignments_query_failed", extra={"patientId": patient_id})
        return None
    for row in res.get("Items", []):
        if not row.get("validUntil"):
            return row
    return None


def _get_device(serial: str) -> Optional[dict[str, Any]]:
    try:
        res = _devices_tbl.get_item(Key={"serialNumber": serial})
        return res.get("Item")
    except ClientError:
        logger.exception("device_get_failed", extra={"serial": serial})
        return None


def _write_alert(
    patient: dict[str, Any],
    cand: AlertCandidate,
    *,
    device_serial: Optional[str],
) -> bool:
    """
    Conditional PutItem on Alert History. Compound SK
    `{eventTimestamp}#{alertType}`, hierarchy snapshot at write time,
    TTL on `expiresAt`. Returns True on first write; False on dedupe.

    Per `docs/specs/2026-05-26-alert-recurrence-policy.md` L3, for
    continuous-condition alert types (`device_offline` /
    `device_silent`), claim_open_alert is called first; subsequent
    same-type firings while the prior alert is open are suppressed.
    Daily-cadence types (`no_activity_today`, `below_typical_activity`,
    `declining_trend`) skip the open-alert gate — each day's row is the
    historical record of that day. Their once-per-day property comes
    from the SK itself: their `event_timestamp_iso` is the facility-local
    DAY ANCHOR (midnight), so a second evaluation anywhere in the same
    local day collides here and is rejected. The trigger-hour gate in
    `facility_iterator.rule_set_for_facility()` decides WHEN in the day
    they run; this condition is what makes a re-run harmless.
    """
    sk = f"{cand.event_timestamp_iso}#{cand.alert_type}"

    if cand.alert_type in _CONTINUOUS_ALERT_TYPES:
        if not claim_open_alert(
            patient_id=patient["patientId"],
            alert_type=cand.alert_type,
            sk=sk,
            opened_at=_utc_iso(),
        ):
            logger.info(
                "behavioral_alert_suppressed_open",
                extra={
                    "patientId": patient["patientId"],
                    "alertType": cand.alert_type,
                    "sk": sk,
                },
            )
            metrics.add_metric(
                name="behavioral_alert_suppressed_open",
                unit=MetricUnit.Count,
                value=1,
            )
            return False

    # Convert the facility-local ISO to UTC epoch for the TTL math.
    try:
        ts_epoch = int(datetime.fromisoformat(cand.event_timestamp_iso).timestamp())
    except (TypeError, ValueError):
        ts_epoch = _now_epoch()
    expires_at = ts_epoch + ALERT_TTL_SECONDS
    item: dict[str, Any] = {
        "patientId": patient["patientId"],
        "timestamp": sk,
        "clientId": patient.get("clientId"),
        "facilityId": patient.get("facilityId"),
        "censusId": patient.get("censusId"),
        "eventTimestamp": cand.event_timestamp_iso,
        "alertType": cand.alert_type,
        "severity": cand.severity,
        "source": cand.source,
        "acknowledged": False,
        "data": _decimal_safe(cand.data),
        "createdAt": _utc_iso(),
        "expiresAt": expires_at,
    }
    if device_serial:
        item["deviceSerial"] = device_serial
    try:
        _alert_tbl.put_item(
            Item=item,
            ConditionExpression="attribute_not_exists(patientId) AND attribute_not_exists(#ts)",
            ExpressionAttributeNames={"#ts": "timestamp"},
        )
        return True
    except ClientError as exc:
        if exc.response["Error"]["Code"] == "ConditionalCheckFailedException":
            # Same-day dedupe — idempotent. For continuous types we
            # already claimed the slot; leaving the (now-orphan)
            # claim in place is safe — a duplicate SK means the prior
            # write owns the same slot anyway.
            return False
        logger.exception(
            "alert_put_failed",
            extra={"patientId": patient["patientId"], "alertType": cand.alert_type},
        )
        raise


def _decimal_safe(value: Any) -> Any:
    """Convert floats to Decimal recursively for DDB."""
    if isinstance(value, float):
        return Decimal(str(value))
    if isinstance(value, dict):
        return {k: _decimal_safe(v) for k, v in value.items()}
    if isinstance(value, list):
        return [_decimal_safe(v) for v in value]
    return value


def _emit_alert_audit(
    patient: dict[str, Any], cand: AlertCandidate, device_serial: Optional[str]
) -> None:
    """Reuse 1B-rev's `alert.synthetic.create` event for all 5 rule types."""
    subject: dict[str, Any] = {
        "patientId": patient["patientId"],
        "clientId": patient.get("clientId"),
        "facilityId": patient.get("facilityId"),
        "censusId": patient.get("censusId"),
    }
    if device_serial:
        subject["deviceSerial"] = device_serial
    emit_audit(
        "alert.synthetic.create",
        subject=subject,
        action="create",
        after={
            "alertType": cand.alert_type,
            "severity": cand.severity,
            "source": cand.source,
            "eventTimestamp": cand.event_timestamp_iso,
        },
    )


_suppressed_paused_logged: set[str] = set()  # in-memory per-invocation sampling


def _maybe_log_suppressed_paused(patient: dict[str, Any]) -> None:
    """
    Spec L6 — sample `patient.notifications.suppressed_paused` at
    ≤1/day/patient. The threshold-detector uses Shadow-based dedupe;
    behavioral-detector is invoked once per facility per hour, so a
    simpler approach: emit at most once per patient PER LAMBDA
    INVOCATION (i.e., once per hourly cron firing). Since each patient
    is evaluated for multiple rules within a single facility-routing
    pass, this naturally collapses to one emission per paused patient
    per invocation.

    Cron fires hourly → 24 sampled emissions per paused-patient per
    day — exceeds the spec's ≤1/day/patient target. Mitigation: write
    a `lastBehavioralSuppressedAuditAt` attribute on the Patient row
    on emission and check it on next entry. For V1 simplicity we accept
    the 24x over-emission (~24 audit lines/day per paused patient,
    well under the Phase 1.7 cost-model ceiling). Tighten in 1.6-followup
    if audit volume becomes a concern.
    """
    pid = patient["patientId"]
    if pid in _suppressed_paused_logged:
        return
    _suppressed_paused_logged.add(pid)
    emit_audit(
        "patient.notifications.suppressed_paused",
        subject={
            "patientId": pid,
            "clientId": patient.get("clientId"),
            "facilityId": patient.get("facilityId"),
            "censusId": patient.get("censusId"),
        },
        action="observe",
        extra={
            "source": "behavioral-detector",
            "pauseUntil": (patient.get("notificationsPaused") or {}).get("until"),
            "pauseReason": (patient.get("notificationsPaused") or {}).get("reason"),
        },
    )


# ── Rule orchestration per facility ───────────────────────────────────


def _evaluate_facility(facility: FacilityContext, rule_set: RuleSet, summary: dict) -> None:
    """Run the applicable rules against every active patient in `facility`."""
    patients = list_active_patients(_patients_tbl, facility=facility)
    summary["patientsEvaluated"] += len(patients)

    # Two timestamps, each the `eventTimestamp` (and so the SK) of a
    # different class of rule:
    #
    #   local_day_iso — facility-local MIDNIGHT. Used by the daily-cadence
    #     rules, whose row is the record of that DAY. Constant across the
    #     local day, so `_write_alert`'s conditional PutItem is a real
    #     once-per-day guard (spec L5 / Q5).
    #   local_now_iso — facility-local NOW, to the second. Used by the
    #     offline rules, where the row records a moment of detection and
    #     once-per-condition is enforced by the open-alert state machine
    #     instead (2026-05-26-alert-recurrence-policy.md).
    local_now_iso = facility.local_now.isoformat(timespec="seconds")
    local_day_iso = history_window.local_day_anchor_iso(facility.local_now)

    now_epoch = _now_epoch()

    for patient in patients:
        # ── Pause gate ────────────────────────────────────────────
        if is_currently_paused(patient):
            _maybe_log_suppressed_paused(patient)
            summary["pausedSkipped"] += 1
            continue

        # ── Device-side facts (used by no_activity_today + offline rules) ─
        device_serial: Optional[str] = None
        device_last_seen: Optional[int] = None
        device_status: str = ""
        device_type: str = ""
        assignment = _get_active_assignment(patient["patientId"])
        if assignment:
            device_serial = assignment.get("serialNumber")
            if device_serial:
                device = _get_device(device_serial) or {}
                device_status = str(device.get("status") or "")
                device_last_seen = _device_last_seen_epoch(device)
                device_type = str(device.get("deviceType") or "")
        # DT-4 WS2: the behavioral rules key on the device's PRIMARY activity
        # metric — steps for a walker (identical to pre-DT-4, no regression),
        # activeMinutes for a rollator (no steps). None/unknown → walker/steps.
        metric_field = primary_activity_metric(device_type)

        # ── Activity windows (only fetched when needed) ───────────
        history_rows: Optional[list[dict[str, Any]]] = None
        today_rows: Optional[list[dict[str, Any]]] = None
        today_active_min_cache: Optional[int] = None
        history_per_day: Optional[list[int]] = None

        def _today_rows():
            nonlocal today_rows
            if today_rows is None:
                today_rows = query_activity_for_today(
                    _activity_tbl,
                    patient_id=patient["patientId"],
                    tz_name=facility.timezone,
                    now=facility.local_now,
                )
            return today_rows

        def _today_active_minutes():
            nonlocal today_active_min_cache
            if today_active_min_cache is None:
                today_active_min_cache = sum_metric(_today_rows(), metric_field)
            return today_active_min_cache

        def _history_per_day():
            nonlocal history_rows, history_per_day
            if history_per_day is None:
                if history_rows is None:
                    history_rows = query_activity_history(
                        _activity_tbl,
                        patient_id=patient["patientId"],
                        tz_name=facility.timezone,
                        days=HISTORY_DAYS,
                        now=facility.local_now,
                    )
                history_per_day = aggregate_metric_per_day(
                    history_rows,
                    field=metric_field,
                    days=HISTORY_DAYS,
                    tz_name=facility.timezone,
                    now=facility.local_now,
                )
            return history_per_day

        # ── no_activity_today ─────────────────────────────────────
        if rule_set.evaluate_no_activity:
            cand = no_activity_today.evaluate(
                activity_rows_today=_today_rows(),
                device_last_seen_epoch=device_last_seen,
                now_epoch=now_epoch,
                event_timestamp_iso=local_day_iso,
                check_local_hour=facility_iterator.NO_ACTIVITY_LOCAL_HOUR,
                metric_field=metric_field,
            )
            _maybe_fire(patient, cand, device_serial, summary)

        # ── below_typical + declining_trend ───────────────────────
        if rule_set.evaluate_end_of_day_behavioral:
            cand = below_typical.evaluate(
                today_active_minutes=_today_active_minutes(),
                history_active_min_per_day=_history_per_day(),
                event_timestamp_iso=local_day_iso,
            )
            _maybe_fire(patient, cand, device_serial, summary)

            cand = declining_trend.evaluate(
                history_active_min_per_day=_history_per_day(),
                event_timestamp_iso=local_day_iso,
            )
            _maybe_fire(patient, cand, device_serial, summary)

        # ── device_offline + device_silent ────────────────────────
        if rule_set.evaluate_offline:
            cand = device_offline.evaluate(
                device_status=device_status,
                device_last_seen_epoch=device_last_seen,
                now_epoch=now_epoch,
                local_now_iso=local_now_iso,
            )
            _maybe_fire(patient, cand, device_serial, summary)
            # Recurrence policy (2026-05-26-alert-recurrence-policy.md
            # L4): if the device has recovered below either threshold,
            # auto-ack the corresponding open alert. Runs on every cron
            # firing — including the first one after a recovery, so
            # the closed loop completes within ≤1 hr of the heartbeat
            # that brings lastSeen back into range.
            _auto_ack_recovered_offline(
                patient=patient,
                device_status=device_status,
                device_last_seen_epoch=device_last_seen,
                now_epoch=now_epoch,
                device_serial=device_serial,
                summary=summary,
            )


def _auto_ack_recovered_offline(
    *,
    patient: dict[str, Any],
    device_status: Optional[str],
    device_last_seen_epoch: Optional[int],
    now_epoch: int,
    device_serial: Optional[str],
    summary: dict,
) -> None:
    """
    Per `2026-05-26-alert-recurrence-policy.md` L4 + L7 — when the
    device has recovered (lastSeen is within the rule's threshold),
    auto-ack any open alert of that type.

    Clear conditions (mirror of the violation thresholds in
    `device_offline.evaluate`):
      - device_offline clears when `now - lastSeen <= 2h`
      - device_silent clears when `now - lastSeen <= 24h`

    The status guard mirrors the violation path: only act on devices
    in `active_monitoring`. Devices that have transitioned to
    `discontinued` or `decommissioned` should not have their open
    alerts auto-acked here — they may need manual closure.
    """
    if device_status != "active_monitoring":
        return
    if device_last_seen_epoch is None:
        return

    hours_offline = (now_epoch - device_last_seen_epoch) / 3600

    cleared_types: list[str] = []
    if hours_offline < DEFAULT_OFFLINE_THRESHOLD_HOURS:
        cleared_types.append(ALERT_DEVICE_OFFLINE)
    if hours_offline < DEFAULT_SILENT_THRESHOLD_HOURS:
        cleared_types.append(ALERT_DEVICE_SILENT)

    if not cleared_types:
        return

    subject = {
        "patientId": patient["patientId"],
        "clientId": patient.get("clientId"),
        "facilityId": patient.get("facilityId"),
        "censusId": patient.get("censusId"),
    }
    if device_serial:
        subject["deviceSerial"] = device_serial

    for alert_type in cleared_types:
        try:
            fired = auto_ack_alert(
                patient_id=patient["patientId"],
                alert_type=alert_type,
                actor_service="behavioral-detector",
                subject=subject,
            )
        except Exception:  # noqa: BLE001 — best-effort
            logger.exception(
                "behavioral_auto_ack_failed",
                extra={
                    "patientId": patient["patientId"],
                    "alertType": alert_type,
                },
            )
            continue
        if fired:
            summary["alertsAutoAcknowledged"] = (
                summary.get("alertsAutoAcknowledged", 0) + 1
            )
            metrics.add_metric(
                name="behavioral_alert_auto_acked",
                unit=MetricUnit.Count,
                value=1,
            )


def _maybe_fire(
    patient: dict[str, Any],
    cand: Optional[AlertCandidate],
    device_serial: Optional[str],
    summary: dict,
) -> None:
    if cand is None:
        return
    summary["candidates"] += 1
    summary.setdefault("candidatesByType", {}).setdefault(cand.alert_type, 0)
    summary["candidatesByType"][cand.alert_type] += 1
    try:
        wrote = _write_alert(patient, cand, device_serial=device_serial)
    except Exception:
        logger.exception(
            "alert_write_unexpected_error",
            extra={"patientId": patient["patientId"], "alertType": cand.alert_type},
        )
        summary["writeErrors"] = summary.get("writeErrors", 0) + 1
        return
    if wrote:
        summary["alertsWritten"] += 1
        metrics.add_metric(name="behavioral_alert_count", unit=MetricUnit.Count, value=1)
        _emit_alert_audit(patient, cand, device_serial)
    else:
        summary["alertsDeduplicated"] += 1


# ── Main entry ────────────────────────────────────────────────────────


@logger.inject_lambda_context(log_event=False)
@metrics.log_metrics(capture_cold_start_metric=True)
def handler(event: dict, _context):
    """
    EventBridge cron entry point. Event payload is the EventBridge
    "Scheduled Event" envelope — we don't read it; the work is driven
    by current time + DDB state.
    """
    started_at = _now_epoch()
    summary: dict[str, Any] = {
        "facilitiesEvaluated": 0,
        "facilitiesSkipped": 0,
        "patientsEvaluated": 0,
        "pausedSkipped": 0,
        "candidates": 0,
        "alertsWritten": 0,
        "alertsDeduplicated": 0,
        "writeErrors": 0,
    }

    # Reset the per-invocation suppressed-paused dedupe (handler module
    # is cached across warm invocations).
    _suppressed_paused_logged.clear()

    try:
        facilities = list_facilities(_orgs_tbl)
    except ClientError:
        logger.exception("organizations_list_failed")
        raise

    logger.info(
        "behavioral_detector_invoked",
        extra={
            "facilityCount": len(facilities),
            "noActivityHour": facility_iterator.NO_ACTIVITY_LOCAL_HOUR,
            "endOfDayHour": facility_iterator.END_OF_DAY_LOCAL_HOUR,
            "catchupHours": facility_iterator.TRIGGER_CATCHUP_HOURS,
        },
    )

    for facility in facilities:
        rule_set = rule_set_for_facility(
            facility,
            no_activity_hour=facility_iterator.NO_ACTIVITY_LOCAL_HOUR,
            end_of_day_hour=facility_iterator.END_OF_DAY_LOCAL_HOUR,
            catchup_hours=facility_iterator.TRIGGER_CATCHUP_HOURS,
        )
        # Skip facilities where no rules apply this hour (offline rules
        # always apply, so this branch is rare — but defensive).
        if not (rule_set.evaluate_no_activity
                or rule_set.evaluate_end_of_day_behavioral
                or rule_set.evaluate_offline):
            summary["facilitiesSkipped"] += 1
            continue
        summary["facilitiesEvaluated"] += 1
        try:
            _evaluate_facility(facility, rule_set, summary)
        except Exception:
            # Per-facility errors are logged + counted but don't stop
            # the cron pass for the remaining facilities.
            logger.exception(
                "facility_evaluate_failed",
                extra={"facilityId": facility.facilityId},
            )
            summary.setdefault("facilityErrors", 0)
            summary["facilityErrors"] += 1

    duration_s = _now_epoch() - started_at
    summary["durationSeconds"] = duration_s

    emit_audit(
        "behavioral.detector.run",
        subject={"environment": ENV},
        action="observe",
        extra=summary,
    )

    metrics.add_metric(name="behavioral_run_count", unit=MetricUnit.Count, value=1)
    metrics.add_metric(name="behavioral_duration_seconds", unit=MetricUnit.Seconds, value=duration_s)

    logger.info("behavioral_detector_done", extra=summary)
    return {
        "statusCode": 200,
        "body": (
            f"facilities={summary['facilitiesEvaluated']} "
            f"patients={summary['patientsEvaluated']} "
            f"alerts={summary['alertsWritten']} "
            f"deduped={summary['alertsDeduplicated']} "
            f"paused_skipped={summary['pausedSkipped']} "
            f"duration={duration_s}s"
        ),
    }
# bundle-marker: 2026-05-27T05:50Z (open_alerts two-step fix)

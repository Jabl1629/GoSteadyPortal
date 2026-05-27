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
from _shared.open_alerts import auto_ack_alert, claim_open_alert
from _shared.pause_check import is_currently_paused
from _shared.thresholds import merge_thresholds
from aws_lambda_powertools.metrics import MetricUnit

# Per `docs/specs/2026-05-26-alert-recurrence-policy.md` — types that
# this Lambda emits and that participate in the open-alert state
# machine. Threshold-detector owns battery + signal; behavioral-
# detector owns device_offline + device_silent.
_CONTINUOUS_ALERT_TYPES = (
    "battery_critical",
    "battery_low",
    "signal_lost",
    "signal_weak",
)

# ── Configuration ────────────────────────────────────────────────
ALERT_TABLE = os.environ["ALERT_TABLE"]
DEVICE_TABLE = os.environ["DEVICE_TABLE"]
PRE_ACTIVATION_AUDIT_HOURS = int(os.environ.get("PRE_ACTIVATION_AUDIT_SAMPLE_HOURS", "1"))
# Phase 2A-UM-P L9 — sample suppressed-paused audit at ≤1/day/patient.
PAUSE_SUPPRESSED_AUDIT_HOURS = int(os.environ.get("PAUSE_SUPPRESSED_AUDIT_SAMPLE_HOURS", "24"))

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


def _maybe_emit_paused_suppressed_audit(serial: str, patient: PatientContext) -> None:
    """
    Sample `patient.notifications.suppressed_paused` at ≤1/day/serial via
    Shadow `reported.lastNotificationSuppressedAuditAt` (Phase 2A-UM-P L9).
    Mirrors the preactivation pattern; per-device dedupe is equivalent to
    per-patient dedupe given the 1:1 device:patient mapping at any given
    moment (DeviceAssignment uniqueness).
    """
    now = datetime.now(timezone.utc)
    cutoff = now - timedelta(hours=PAUSE_SUPPRESSED_AUDIT_HOURS)
    try:
        resp = _iot_data.get_thing_shadow(thingName=serial)
        shadow = json.loads(resp["payload"].read())
    except ClientError as e:
        if e.response.get("Error", {}).get("Code") == "ResourceNotFoundException":
            shadow = {}
        else:
            logger.exception("paused_suppressed_shadow_get_failed", extra={"serial": serial})
            return
    last_audit = (
        shadow.get("state", {}).get("reported", {}).get("lastNotificationSuppressedAuditAt")
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
                {"state": {"reported": {"lastNotificationSuppressedAuditAt": audit_iso}}}
            ).encode("utf-8"),
        )
    except ClientError:
        logger.exception("paused_suppressed_dedupe_write_failed", extra={"serial": serial})

    pause = patient.notificationsPaused or {}
    emit_audit(
        "patient.notifications.suppressed_paused",
        subject={
            "patientId": patient.patientId,
            "clientId": patient.clientId,
            "facilityId": patient.facilityId,
            "censusId": patient.censusId,
            "deviceSerial": serial,
        },
        action="observe",
        extra={
            "sampledAt": audit_iso,
            "pausedUntil": pause.get("until"),
            "pauseReason": pause.get("reason"),
        },
    )
    metrics.add_metric(
        name="paused_suppressed_count", unit=MetricUnit.Count, value=1
    )


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

    # Recurrence policy (docs/specs/2026-05-26-alert-recurrence-policy.md L3):
    # claim the (patient, alertType) open-alert slot before writing. If
    # a same-type alert is already open, suppress this write so the
    # Census + Notification Review panel stays focused on one row per
    # active condition.
    claim_now = _now_iso()
    if not claim_open_alert(
        patient_id=patient.patientId,
        alert_type=alert_type,
        sk=sk,
        opened_at=claim_now,
    ):
        logger.info(
            "synthetic_alert_suppressed_open",
            extra={
                "serial": serial,
                "patientId": patient.patientId,
                "alertType": alert_type,
                "sk": sk,
            },
        )
        metrics.add_metric(
            name="synthetic_alert_suppressed_open",
            unit=MetricUnit.Count,
            value=1,
        )
        return False

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
        "createdAt": claim_now,
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
            # Same-key duplicate (shouldn't happen post-claim, but guard
            # for safety). Leave the claim in place — the prior identical
            # write owns the slot.
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


def _auto_ack_cleared_thresholds(
    *,
    serial: str,
    patient: PatientContext,
    battery_pct: float | None,
    rsrp_dbm: float | None,
) -> None:
    """
    Auto-ack any open continuous-condition slot whose territory is
    not currently active for this shadow update. Uses "active
    territories" semantics so transitions in either direction
    (recovery upward, escalation downward, tier change) close stale
    slots correctly.

    Active territories per dimension (mirror of
    `determine_threshold_alerts`):
      battery_pct:
        - < batteryCritical             → battery_critical active
        - [batteryCritical, batteryLow) → battery_low active
        - >= batteryLow                 → neither active (fine state)
      rsrp_dbm:
        - <= rsrpLost                   → signal_lost active
        - (rsrpLost, rsrpWeak]          → signal_weak active
        - > rsrpWeak                    → neither active

    Examples:
      - Recovery (battery 0.03 → 0.50): battery_critical slot acks;
        battery_low slot acks (if it had been open from a prior
        cycle); no new alert fires.
      - Tier change (battery 0.03 → 0.07): battery_critical slot
        acks; battery_low SLOT GETS CLAIMED on the breach-write path
        below.
      - Escalation (battery 0.07 → 0.03): battery_low slot acks;
        battery_critical slot gets claimed on breach-write.

    Per-patient threshold overrides honored (same merge logic as
    `determine_threshold_alerts`).
    """
    t = merge_thresholds(patient.thresholds)
    active: set[str] = set()
    if battery_pct is not None:
        if battery_pct < t["batteryCritical"]:
            active.add("battery_critical")
        elif battery_pct < t["batteryLow"]:
            active.add("battery_low")
    if rsrp_dbm is not None:
        if rsrp_dbm <= t["rsrpLost"]:
            active.add("signal_lost")
        elif rsrp_dbm <= t["rsrpWeak"]:
            active.add("signal_weak")

    # Auto-ack any open slot whose territory is NOT currently active
    # for the dimension we observed. If a value wasn't reported in
    # this shadow update, don't touch that dimension's slots — we
    # have no signal to act on.
    cleared: list[str] = []
    if battery_pct is not None:
        for at in ("battery_critical", "battery_low"):
            if at not in active:
                cleared.append(at)
    if rsrp_dbm is not None:
        for at in ("signal_lost", "signal_weak"):
            if at not in active:
                cleared.append(at)

    if not cleared:
        return

    subject = {
        "patientId": patient.patientId,
        "clientId": patient.clientId,
        "facilityId": patient.facilityId,
        "censusId": patient.censusId,
        "deviceSerial": serial,
    }
    for alert_type in cleared:
        try:
            fired = auto_ack_alert(
                patient_id=patient.patientId,
                alert_type=alert_type,
                actor_service="threshold-detector",
                subject=subject,
            )
        except Exception:  # noqa: BLE001 — best-effort; log + continue
            logger.exception(
                "auto_ack_failed",
                extra={
                    "serial": serial,
                    "patientId": patient.patientId,
                    "alertType": alert_type,
                },
            )
            continue
        if fired:
            metrics.add_metric(
                name="synthetic_alert_auto_acked",
                unit=MetricUnit.Count,
                value=1,
            )


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
    # Phase 2A-AA: resolve patient FIRST so we can apply per-patient
    # threshold overrides (patient.thresholds map). Cost: one extra
    # Patients.GetItem per shadow update (even those that wouldn't
    # breach defaults). Acceptable at MVP scale; revisit with a cache
    # if Patients table reads become hot.
    battery_pct = _f(reported.get("battery_pct"))
    rsrp_dbm = _f(reported.get("rsrp_dbm"))

    patient = resolve_patient(serial)
    if patient is None:
        logger.warning(
            "unmapped_serial",
            extra={"serial": serial, "stage": "threshold-detector"},
        )
        metrics.add_metric(name="unmapped_serial_count", unit=MetricUnit.Count, value=1)
        return {"statusCode": 200, "body": "no active assignment; alerts dropped"}

    # Phase 2A-UM-P L9 — pause-aware gate.
    # If the patient's notifications are currently paused (caregiver set
    # via POST /patients/{id}/notifications/pause), skip threshold
    # evaluation entirely. Sample a `patient.notifications.suppressed_paused`
    # audit at ≤1/day/patient so compliance can see the pause is being
    # honored without flooding the audit log.
    if is_currently_paused({"notificationsPaused": patient.notificationsPaused}):
        _maybe_emit_paused_suppressed_audit(serial, patient)
        return {"statusCode": 200, "body": "patient notifications paused; suppressed"}

    breaches = determine_threshold_alerts(
        battery_pct, rsrp_dbm, overrides=patient.thresholds,
    )

    # Recurrence policy (2026-05-26-alert-recurrence-policy.md L4):
    # any continuous-condition alert whose underlying value is now
    # in a clear state gets auto-acked. Runs on every shadow update
    # — including ones that don't have any new breaches to write —
    # so a recovery from battery_critical alone (no other breach
    # firing) still closes the open alert.
    _auto_ack_cleared_thresholds(
        serial=serial,
        patient=patient,
        battery_pct=battery_pct,
        rsrp_dbm=rsrp_dbm,
    )

    if not breaches:
        return {"statusCode": 200, "body": "no threshold breach"}

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
# bundle-marker: 2026-05-27T06:05Z (active-territories auto-ack)

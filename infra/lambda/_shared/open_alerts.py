"""
Open-alert state machine for continuous-condition synthetic alerts.

Per `docs/specs/2026-05-26-alert-recurrence-policy.md` — each
(patientId, alertType) pair has at most one open alert at a time.
While open, subsequent detector firings that re-evaluate the same
violating condition emit zero new rows. The open alert closes via:

  (a) Caregiver manual ack (PATCH /alerts) → alert-actions calls
      [release_open_alert].
  (b) Detector observes the condition has cleared → detector calls
      [auto_ack_alert].

Storage: `Patient.openAlerts: Map<alertType, {sk: S, openedAt: S}>`.
Lives on the Patient row to piggyback on existing per-handler reads
and to keep the conditional UpdateItem atomic. Patient is 1:1 to
device at any given time per ARCHITECTURE §4 device-mobility model,
so patient-scoped is sufficient.

Applies to continuous-condition rules only:
  - threshold-detector: battery_critical, battery_low, signal_lost,
    signal_weak
  - behavioral-detector (1C-slim): device_offline, device_silent

Daily-cadence rules (no_activity_today, below_typical_activity,
declining_trend) are NOT governed by this module — each day's row
is the historical record of that day, naturally bounded once-per-day
by the hour-gate in `facility_iterator.rule_set_for_facility()`.
"""

from __future__ import annotations

import os
from datetime import datetime, timezone
from typing import Any, Optional

import boto3
from botocore.exceptions import ClientError

from _shared.audit_catalog import AUDIT_ALERT_AUTO_ACKNOWLEDGED
from _shared.observability import emit_audit, get_logger

logger = get_logger()

_ddb = boto3.resource("dynamodb")

_PATIENTS_TABLE_NAME: Optional[str] = None
_ALERTS_TABLE_NAME: Optional[str] = None
_patients_tbl = None
_alerts_tbl = None


def _patients_table():
    """Lazy table handle so callers don't need to wire env vars during
    cold-start. Reads PATIENTS_TABLE from the env on first access."""
    global _PATIENTS_TABLE_NAME, _patients_tbl
    if _patients_tbl is None:
        _PATIENTS_TABLE_NAME = os.environ["PATIENTS_TABLE"]
        _patients_tbl = _ddb.Table(_PATIENTS_TABLE_NAME)
    return _patients_tbl


def _alerts_table():
    """Lazy table handle. Reads `ALERTS_TABLE` (canonical, used by
    alert-actions) or falls back to `ALERT_TABLE` (singular, used by
    threshold-detector + behavioral-detector — predates the
    alert-actions convention). One of the two MUST be set in the
    Lambda's env."""
    global _ALERTS_TABLE_NAME, _alerts_tbl
    if _alerts_tbl is None:
        name = os.environ.get("ALERTS_TABLE") or os.environ.get("ALERT_TABLE")
        if not name:
            raise RuntimeError(
                "_shared.open_alerts requires either ALERTS_TABLE or "
                "ALERT_TABLE env var to be set"
            )
        _ALERTS_TABLE_NAME = name
        _alerts_tbl = _ddb.Table(_ALERTS_TABLE_NAME)
    return _alerts_tbl


def _now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def claim_open_alert(
    *,
    patient_id: str,
    alert_type: str,
    sk: str,
    opened_at: Optional[str] = None,
) -> bool:
    """
    Atomically claim the (patient, alert_type) open-alert slot.

    Returns:
      True  — this caller won the claim; caller should now PutItem
              the alert row.
      False — a same-type alert is already open; caller should skip
              the PutItem (silently suppress).

    Race-safe: two concurrent detector invocations for the same
    (patient, alert_type) → exactly one wins; the other gets
    ConditionalCheckFailedException and bails.

    Implementation note: DynamoDB UpdateExpressions reject "overlapping
    document paths" (e.g. `SET openAlerts = ..., openAlerts.X = ...`),
    so we use a two-step approach: a defensive `SET openAlerts = :empty`
    with `attribute_not_exists(openAlerts)` guard (no-op for existing
    rows since the migration script initialized this map; idempotent
    for new patients created post-deploy by patient-mgmt), then the
    atomic claim. Two round-trips ~20ms total on cold cache; well
    inside the 1s synthetic-alert latency tolerance (1B-rev A4).
    """
    opened_at = opened_at or _now_iso()
    record = {"sk": sk, "openedAt": opened_at}
    table = _patients_table()
    # Step 1: ensure openAlerts map exists. CCF means it already does.
    try:
        table.update_item(
            Key={"patientId": patient_id},
            UpdateExpression="SET openAlerts = :empty",
            ConditionExpression="attribute_not_exists(openAlerts)",
            ExpressionAttributeValues={":empty": {}},
        )
    except ClientError as exc:
        if exc.response["Error"]["Code"] != "ConditionalCheckFailedException":
            raise
    # Step 2: claim the slot.
    try:
        table.update_item(
            Key={"patientId": patient_id},
            UpdateExpression="SET openAlerts.#t = :rec",
            ConditionExpression="attribute_not_exists(openAlerts.#t)",
            ExpressionAttributeNames={"#t": alert_type},
            ExpressionAttributeValues={":rec": record},
        )
        return True
    except ClientError as exc:
        if exc.response["Error"]["Code"] == "ConditionalCheckFailedException":
            return False
        raise


def release_open_alert(*, patient_id: str, alert_type: str) -> bool:
    """
    REMOVE the openAlerts.<alert_type> entry on the Patient row.

    Returns True if an entry was removed (the slot was open);
    False if no entry existed (slot was already empty — caller can
    treat as no-op).

    Idempotent. Best-effort: errors are logged and re-raised; callers
    that want fire-and-forget semantics should wrap in try/except.
    """
    try:
        _patients_table().update_item(
            Key={"patientId": patient_id},
            UpdateExpression="REMOVE openAlerts.#t",
            ConditionExpression="attribute_exists(openAlerts.#t)",
            ExpressionAttributeNames={"#t": alert_type},
        )
        return True
    except ClientError as exc:
        if exc.response["Error"]["Code"] == "ConditionalCheckFailedException":
            return False
        raise


def get_open_alert_sk(
    *,
    patient_id: str,
    alert_type: str,
) -> Optional[str]:
    """
    Return the `sk` of the currently-open alert for (patient, type),
    or None if no open alert.

    Used by detectors to locate the Alert row for an auto-ack write.
    """
    resp = _patients_table().get_item(
        Key={"patientId": patient_id},
        ProjectionExpression="openAlerts.#t",
        ExpressionAttributeNames={"#t": alert_type},
        ConsistentRead=False,
    )
    item = resp.get("Item") or {}
    entry = item.get("openAlerts", {}).get(alert_type)
    if not entry:
        return None
    sk = entry.get("sk")
    return sk if isinstance(sk, str) else None


def auto_ack_alert(
    *,
    patient_id: str,
    alert_type: str,
    actor_service: str,
    subject: dict[str, Any],
    reason: str = "condition_cleared",
) -> bool:
    """
    End-to-end auto-ack for a continuous-condition alert that has
    cleared:

      1. Look up the Alert row's `sk` via [get_open_alert_sk].
      2. UpdateItem on Alert row: acknowledged=true,
         acknowledgedBy=`system:<reason>`, acknowledgedAt=now,
         gated by `acknowledged = :false` to guard against races
         with manual ack from alert-actions.
      3. REMOVE the openAlerts.<alert_type> entry on Patient row.
      4. emit_audit(alert.auto_acknowledged) with before/after maps.

    Returns:
      True  — auto-ack fired end-to-end.
      False — no open alert was found (slot already cleared by a
              prior caller, or claim was orphaned by a crashed
              writer), OR the Alert row was already acked (race
              with manual ack from alert-actions). In either case
              the resulting state is correct (alert is acked + slot
              is released).

    `actor_service` should be one of {"threshold-detector",
    "behavioral-detector"} — surfaces in the audit event for
    forensic ops.
    """
    sk = get_open_alert_sk(patient_id=patient_id, alert_type=alert_type)
    if sk is None:
        # No open alert; nothing to do.
        return False

    now_iso = _now_iso()
    acknowledged_by = f"system:{reason}"

    # 1) Try to ack the Alert row. Guard against race with manual ack.
    try:
        _alerts_table().update_item(
            Key={"patientId": patient_id, "timestamp": sk},
            UpdateExpression=(
                "SET acknowledged = :true, "
                "acknowledgedBy = :who, "
                "acknowledgedAt = :now"
            ),
            ConditionExpression="acknowledged = :false",
            ExpressionAttributeValues={
                ":true": True,
                ":false": False,
                ":who": acknowledged_by,
                ":now": now_iso,
            },
        )
    except ClientError as exc:
        code = exc.response["Error"]["Code"]
        if code == "ConditionalCheckFailedException":
            # Already acked by someone else (manual ack from
            # alert-actions, or a prior auto-ack from a racing
            # detector invocation). Still release the slot so the
            # detector view of state is correct.
            logger.info(
                "auto_ack_race_lost",
                extra={
                    "patientId": patient_id,
                    "alertType": alert_type,
                    "sk": sk,
                },
            )
            release_open_alert(patient_id=patient_id, alert_type=alert_type)
            return False
        raise

    # 2) Release the openAlerts slot.
    release_open_alert(patient_id=patient_id, alert_type=alert_type)

    # 3) Emit audit event.
    duration_seconds: Optional[int] = None
    try:
        # `sk` is `{eventTimestamp}#{alertType}` per 1B-rev contract.
        opened_at_iso = sk.split("#", 1)[0]
        opened_dt = datetime.fromisoformat(
            opened_at_iso.replace("Z", "+00:00")
        )
        now_dt = datetime.fromisoformat(now_iso.replace("Z", "+00:00"))
        duration_seconds = max(0, int((now_dt - opened_dt).total_seconds()))
    except Exception:  # noqa: BLE001 — duration is best-effort
        duration_seconds = None

    audit_after: dict[str, Any] = {
        "acknowledged": True,
        "acknowledgedBy": acknowledged_by,
        "acknowledgedAt": now_iso,
    }
    if duration_seconds is not None:
        audit_after["durationSeconds"] = duration_seconds

    emit_audit(
        AUDIT_ALERT_AUTO_ACKNOWLEDGED,
        actor={"type": "system", "id": actor_service},
        subject={**subject, "alertType": alert_type, "sk": sk},
        action="auto_acknowledge",
        before={"acknowledged": False},
        after=audit_after,
    )
    return True

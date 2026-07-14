"""
Device API handler — Phase 2A-DL.

Single Lambda dispatches all `/api/v1/devices/*` + `/api/v1/patients/{id}/devices`
+ `/api/v1/admin/devices` routes (D1 of phase-2a-device-lifecycle.md). Route
dispatch via path + method match against the table below.

Each action:
  1. Extracts path/body params (api_authz.extract_claims for JWT)
  2. require_authenticated / require_mfa as applicable
  3. State machine validation (state_machine.validate_transition)
  4. Tenant enforcement (api_authz.enforce_tenancy with target client_id
     discovered from Device Registry GetItem)
  5. Per-action authz: role + scope checks
  6. DDB writes (atomic where needed; provision uses 3-step rollback per L14)
  7. Side effects (IoT publish for activate cmd; Shadow desired.activated_at)
  8. Returns ok_response; audit emission is automatic via @audit_middleware

The state machine pure-function module is in state_machine.py.
"""

from __future__ import annotations

import json
import os
import re
import time
import uuid
from datetime import datetime
from typing import Any

import boto3
from botocore.exceptions import ClientError

from _shared.api_audit import audit_middleware
from _shared.api_authz import (
    enforce_internal_session_age,
    enforce_scope,
    enforce_tenancy,
    extract_claims,
    is_internal,
    require_authenticated,
    require_mfa,
    require_role,
)
from _shared.api_error import ApiError, error_response, ok_response
from _shared.audit_catalog import (
    AUDIT_DEVICE_ASSIGNED,
    AUDIT_DEVICE_ASSIGNMENT_ENDED,
    AUDIT_DEVICE_CLAIMED,
    AUDIT_DEVICE_CREATED,
    AUDIT_DEVICE_DECOMMISSIONED,
    AUDIT_DEVICE_FLEET_READ,
    AUDIT_DEVICE_FORCE_RESET,
    AUDIT_DEVICE_OWNERSHIP_MOVED,
    AUDIT_DEVICE_OWNERSHIP_RELEASED,
    AUDIT_DEVICE_PROVISION_ROLLBACK,
    AUDIT_DEVICE_RECOVERED,
    AUDIT_DEVICE_ACTIVATION_SENT,
    AUDIT_DEVICE_WIPE_REQUESTED,
)
from _shared.device_types import DEFAULT_TYPE, KNOWN_DEVICE_TYPES
from _shared.observability import emit_audit, get_logger

from state_machine import (
    ACTION_DECOMMISSION,
    ACTION_END_ASSIGNMENT,
    ACTION_FORCE_RESET,
    ACTION_MOVE_CLIENT,
    ACTION_MOVE_FACILITY,
    ACTION_PROVISION,
    ACTION_RECOVER,
    ALL_REASONS,
    RECOVERABLE_REASONS,
    REASON_LOST,
    STATE_READY,
    TransitionError,
    TransitionOk,
    validate_transition,
)

ENV = os.environ.get("ENVIRONMENT", "dev")

DEVICES_TABLE = os.environ["DEVICES_TABLE"]
ASSIGNMENTS_TABLE = os.environ["ASSIGNMENTS_TABLE"]
PATIENTS_TABLE = os.environ["PATIENTS_TABLE"]
ACTIVATION_ACK_WINDOW_HOURS = int(os.environ.get("ACTIVATION_ACK_WINDOW_HOURS", "24"))

logger = get_logger()
ddb = boto3.resource("dynamodb")
# iot-data is the DATA-PLANE client (publishes, shadow get/update).
# `boto3.client("iot")` is the CONTROL-plane client (Things, policies)
# and does NOT have update_thing_shadow.
iot_data = boto3.client("iot-data")

_devices = ddb.Table(DEVICES_TABLE)
_assignments = ddb.Table(ASSIGNMENTS_TABLE)
_patients = ddb.Table(PATIENTS_TABLE)

# Serial format: `GS` + 10 digits (D1 of ARCHITECTURE.md §1)
_SERIAL_RE = re.compile(r"^GS\d{10}$")


def _now_iso() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def _validate_serial(serial: str) -> None:
    if not _SERIAL_RE.match(serial or ""):
        raise ApiError(
            code="INVALID_REQUEST",
            message="Serial must match GS + 10 digits",
            status=400,
            details={"serial": serial},
        )


def _get_device(serial: str) -> dict[str, Any]:
    """Read the Device Registry row; raises NOT_FOUND if absent."""
    res = _devices.get_item(Key={"serialNumber": serial})
    item = res.get("Item")
    if not item:
        raise ApiError(
            code="DEVICE_NOT_FOUND",
            message=f"Device {serial} not found",
            status=404,
        )
    return item


def _get_patient(patient_id: str) -> dict[str, Any]:
    res = _patients.get_item(Key={"patientId": patient_id})
    item = res.get("Item")
    if not item:
        raise ApiError(
            code="PATIENT_NOT_FOUND",
            message=f"Patient {patient_id} not found",
            status=404,
        )
    return item


def _parse_body(event: dict[str, Any]) -> dict[str, Any]:
    raw = event.get("body") or "{}"
    try:
        return json.loads(raw) if raw else {}
    except (json.JSONDecodeError, TypeError) as exc:
        raise ApiError(
            code="INVALID_REQUEST",
            message=f"Body is not valid JSON: {exc}",
            status=400,
        )


def _set_shadow_desired_activated_at(serial: str, value_iso: str | None) -> None:
    """
    Maintain DL14 invariant: desired.activated_at is non-null iff
    Device Registry status ∈ {provisioned, active_monitoring}. Passing
    value_iso=None clears the field on every transition out of those
    states (end-assignment, decommission, force-reset, recovery, etc.).
    """
    payload = json.dumps({"state": {"desired": {"activated_at": value_iso}}})
    iot_data.update_thing_shadow(thingName=serial, payload=payload.encode())


def _set_shadow_desired(serial: str, fields: dict[str, Any]) -> None:
    """
    Set multiple `desired.*` keys atomically (single UpdateThingShadow).
    Each value is the new value or None to clear the key. Used by
    end-assignment to update both `desired.activated_at = null` (DL14)
    and `desired.wipe_requested = <wipe_id>` (DL15) in one Shadow call,
    keeping the two invariants consistent.
    """
    payload = json.dumps({"state": {"desired": fields}})
    iot_data.update_thing_shadow(thingName=serial, payload=payload.encode())


def _shadow_telemetry(serial: str) -> dict[str, Any] | None:
    """
    Project the device's reported Shadow state into the live telemetry the
    portal surfaces. Heartbeats land in the Shadow `reported` state, NOT in
    DynamoDB, so this is the only source for live battery / signal / firmware.

    Returns a camelCase dict of whatever the device has actually reported, or
    None if the device has no shadow yet (never connected) or the read fails —
    telemetry is strictly best-effort and must never fail the device read. The
    full reported set (uptime, boot count, fault counters, watchdog hits, reset
    reason) is included, not just battery/signal, so a future device-centric
    screen / analytics surface can render diagnostics off this one endpoint
    without a second contract (the V1 patient card uses only the
    battery/signal/firmware/lastSeen subset).
    """
    try:
        resp = iot_data.get_thing_shadow(thingName=serial)
        reported = (
            json.loads(resp["payload"].read()).get("state", {}).get("reported", {}) or {}
        )
    except iot_data.exceptions.ResourceNotFoundException:
        return None
    except (ClientError, KeyError, ValueError, AttributeError) as exc:
        logger.warning(
            "shadow_telemetry_read_failed", extra={"serial": serial, "error": str(exc)}
        )
        return None

    # snake_case (firmware heartbeat schema) → camelCase (API convention).
    # `ts` is the heartbeat timestamp → the authoritative lastSeen.
    field_map = {
        "battery_pct": "batteryPct",
        "battery_mv": "batteryMv",
        "rsrp_dbm": "rsrpDbm",
        "snr_db": "snrDb",
        "firmware": "firmware",
        "uptime_s": "uptimeS",
        "boot_count": "bootCount",
        "fault_counters": "faultCounters",
        "watchdog_hits": "watchdogHits",
        "reset_reason": "resetReason",
        "ts": "lastSeen",
        # Lifecycle-ack fields (fleet ops): the wipe-verified-before-reuse gate
        # reads reported.wipe_complete; reportedActivatedAt + lastCmdId help the
        # single-device diagnosis distinguish "cmd sent but not acked" from
        # "acked". Additive — only present when the device has reported them.
        "wipe_complete": "wipeComplete",
        "activated_at": "reportedActivatedAt",
        "last_cmd_id": "lastCmdId",
    }
    out = {camel: reported[snake] for snake, camel in field_map.items() if snake in reported}
    return out or None


# ── Action handlers ────────────────────────────────────────────────────


def _action_get_device(event: dict[str, Any], claims: dict[str, Any], serial: str) -> dict[str, Any]:
    """GET /api/v1/devices/{serial}."""
    _validate_serial(serial)
    device = _get_device(serial)

    owning_client = device.get("owningClientId")
    if owning_client:
        enforce_tenancy(claims, owning_client)

    # Scope: caregivers / facility_admins constrained to their facilities
    owning_facility = device.get("owningFacilityId")
    enforce_scope(claims, target_facility_id=owning_facility)

    view = _device_view(device)
    # Fold in live Shadow telemetry (battery / signal / firmware / lastSeen +
    # richer diagnostics). Best-effort: a device that never connected has no
    # shadow → no `telemetry` key, registry view still returned.
    telemetry = _shadow_telemetry(serial)
    if telemetry is not None:
        view["telemetry"] = telemetry
    return ok_response({"device": view})


def _duration_seconds(start_iso: Any, end_iso: Any) -> int | None:
    """Whole seconds between two ISO-8601 UTC timestamps; None if either is
    missing/unparseable (an ongoing session has no end → None)."""
    if not start_iso or not end_iso:
        return None
    try:
        start = datetime.fromisoformat(str(start_iso).replace("Z", "+00:00"))
        end = datetime.fromisoformat(str(end_iso).replace("Z", "+00:00"))
        return max(0, int((end - start).total_seconds()))
    except (ValueError, TypeError):
        return None


def _assignment_view(a: dict[str, Any]) -> dict[str, Any]:
    """
    Project a raw DeviceAssignments row into the "monitoring session" contract
    the portal's history modal renders. Each row IS one monitoring period:
    device + start (validFrom) + end (validUntil; null = ongoing).
    """
    started = a.get("validFrom") or a.get("assignedAt")
    ended = a.get("validUntil")  # None / missing = currently ongoing
    return {
        "serialNumber": a.get("serialNumber"),
        "patientId": a.get("patientId"),
        "startedAt": started,
        "endedAt": ended,
        "ongoing": ended is None,
        "durationSeconds": _duration_seconds(started, ended),
        "facilityId": a.get("facilityId"),
        "censusId": a.get("censusId"),
        "assignedBy": a.get("assignedBy"),
    }


def _action_list_patient_devices(
    event: dict[str, Any], claims: dict[str, Any], patient_id: str
) -> dict[str, Any]:
    """
    GET /api/v1/patients/{patientId}/devices — the patient's monitoring-session
    history (every DeviceAssignments row), most-recent-first, projected to a
    clean contract. The unused-raw-items version was hardened 2026-06-04 to back
    the portal's "Monitoring history" modal.
    """
    patient = _get_patient(patient_id)
    enforce_tenancy(claims, patient.get("clientId"))
    enforce_scope(
        claims,
        target_facility_id=patient.get("facilityId"),
        target_census_id=patient.get("censusId"),
    )

    # Query DeviceAssignments by GSI by-patient, newest assignment first
    # (ScanIndexForward=False → descending assignedAt SK). Assignment count
    # per patient is tiny (a handful of provision cycles) — no pagination.
    res = _assignments.query(
        IndexName="by-patient",
        KeyConditionExpression="patientId = :p",
        ExpressionAttributeValues={":p": patient_id},
        ScanIndexForward=False,
    )
    views = [_assignment_view(a) for a in res.get("Items", [])]
    return ok_response({"assignments": views, "count": len(views)})


def _action_provision(
    event: dict[str, Any], claims: dict[str, Any], serial: str
) -> dict[str, Any]:
    """
    POST /api/v1/devices/{serial}/provision

    Atomic per L14: 3-step write with rollback on IoT publish failure.
      1. Conditional PutItem on Device Registry (claims ownership if first-time)
      2. PutItem on DeviceAssignments (assignment row)
      3. IoT publish activate cmd + Shadow desired.activated_at
    On step-3 failure: reverse steps 1+2, emit device.provision_rollback, return 500.
    """
    _validate_serial(serial)
    require_role(claims, "caregiver", "facility_admin", "client_admin", "household_owner", "internal_admin")
    require_mfa(claims)

    body = _parse_body(event)
    patient_id = body.get("patientId")
    if not patient_id:
        raise ApiError(code="INVALID_REQUEST", message="patientId required", status=400)

    patient = _get_patient(patient_id)
    enforce_tenancy(claims, patient["clientId"])
    enforce_scope(
        claims,
        target_facility_id=patient.get("facilityId"),
        target_census_id=patient.get("censusId"),
    )

    device = _get_device(serial)
    current_state = device.get("status", STATE_READY)
    transition = validate_transition(current_state, ACTION_PROVISION)
    if isinstance(transition, TransitionError):
        # Concurrent provision race surfaces here when the second caller
        # finds the device already provisioned. Surface a clear message.
        if transition.code == "DEVICE_UNAVAILABLE" and current_state == "provisioned":
            raise ApiError(
                code="DEVICE_UNAVAILABLE",
                message="Device just provisioned by another user — refresh and try again",
                status=409,
                details={"currentStatus": current_state},
            )
        raise ApiError(
            code=transition.code,
            message=transition.message,
            status=409 if transition.code in {"DEVICE_UNAVAILABLE", "INVALID_TRANSITION"} else 400,
            details={"currentStatus": current_state},
        )

    # First-provision: claim ownership using the actor's tenancy (or the
    # patient's; same thing post-enforce_tenancy). The owning_facility_id
    # comes from the patient. internal_admin claims into the patient's
    # client (not _internal).
    target_client_id = patient["clientId"]
    target_facility_id = patient.get("facilityId", "")
    target_census_id = patient.get("censusId", "")

    existing_owner = device.get("owningClientId")
    if existing_owner and existing_owner != target_client_id and not is_internal(claims):
        raise ApiError(
            code="OWNED_BY_OTHER_CLIENT",
            message="Device belongs to another organization",
            status=403,
        )

    is_first_provision = not existing_owner

    cmd_id = f"act_{uuid.uuid4()}"
    now_iso = _now_iso()

    # Step 1a (idempotent, unconditional): ensure outstandingActivationCmds
    # map exists. DDB doesn't allow `SET outstandingActivationCmds = ...`
    # and `SET outstandingActivationCmds.#cid = ...` in the same expression
    # (paths overlap). Initialize the map in a separate call.
    try:
        _devices.update_item(
            Key={"serialNumber": serial},
            UpdateExpression="SET outstandingActivationCmds = if_not_exists(outstandingActivationCmds, :empty)",
            ExpressionAttributeValues={":empty": {}},
        )
    except ClientError:
        logger.exception("ensure_outstanding_map_failed", extra={"serial": serial})
        raise ApiError(
            code="PROVISION_FAILED",
            message="Could not initialize activation tracking; retry",
            status=500,
        )

    # Step 1b: conditional update on Device Registry. Condition: status
    # must still be ready_to_provision (concurrent provision race).
    try:
        update_expr_parts = [
            "#status = :provisioned",
            "currentAssignmentSk = :sk",
            "outstandingActivationCmds.#cid = :now",
            "lastTransitionAt = :now",
        ]
        attr_names = {"#status": "status", "#cid": cmd_id}
        attr_values = {
            ":provisioned": "provisioned",
            ":ready": STATE_READY,
            ":sk": now_iso,
            ":now": now_iso,
        }
        if is_first_provision:
            update_expr_parts.extend(["owningClientId = :oc", "owningFacilityId = :of"])
            attr_values[":oc"] = target_client_id
            attr_values[":of"] = target_facility_id

        _devices.update_item(
            Key={"serialNumber": serial},
            UpdateExpression="SET " + ", ".join(update_expr_parts),
            ConditionExpression="#status = :ready",
            ExpressionAttributeNames=attr_names,
            ExpressionAttributeValues=attr_values,
        )
    except ClientError as exc:
        if exc.response["Error"]["Code"] == "ConditionalCheckFailedException":
            # Lost the race; reread to give the caller a useful currentStatus
            fresh = _get_device(serial)
            raise ApiError(
                code="DEVICE_UNAVAILABLE",
                message="Device just provisioned by another user — refresh and try again",
                status=409,
                details={"currentStatus": fresh.get("status")},
            )
        raise

    # Step 2: DeviceAssignments row
    try:
        _assignments.put_item(
            Item={
                "serialNumber": serial,
                "assignedAt": now_iso,
                "patientId": patient_id,
                "clientId": target_client_id,
                "facilityId": target_facility_id,
                "censusId": target_census_id,
                # DT-0 D1: type snapshot, frozen for the life of the
                # assignment. Sourced from the registry item already fetched
                # for the state check; absent (pre-DT-0 record) = walker_cap.
                "deviceType": device.get("deviceType") or DEFAULT_TYPE,
                "validFrom": now_iso,
                "assignedBy": claims["userId"],
            },
        )
    except ClientError:
        # Reverse step 1 + re-raise
        _rollback_provision(serial, cmd_id, is_first_provision)
        emit_audit(
            event=AUDIT_DEVICE_PROVISION_ROLLBACK,
            actor={"userId": claims["userId"], "role": claims["role"], "clientId": claims["clientId"]},
            subject={"serialNumber": serial, "patientId": patient_id, "clientId": target_client_id},
            action="create",
            extra={"reason": "assignments_put_failed", "cmd_id": cmd_id},
        )
        raise ApiError(
            code="PROVISION_FAILED",
            message="Could not record assignment; retry",
            status=500,
        )

    # Step 3: IoT publish activate cmd + Shadow desired.activated_at
    try:
        cmd_payload = {
            "cmd": "activate",
            "cmd_id": cmd_id,
            "ts": now_iso,
        }
        iot_data.publish(
            topic=f"gs/{serial}/cmd",
            qos=1,
            payload=json.dumps(cmd_payload),
        )
        _set_shadow_desired_activated_at(serial, now_iso)
    except ClientError as exc:
        # Reverse steps 1 + 2
        _rollback_provision(serial, cmd_id, is_first_provision)
        try:
            _assignments.delete_item(Key={"serialNumber": serial, "assignedAt": now_iso})
        except ClientError:
            logger.exception("rollback_assignments_delete_failed")
        emit_audit(
            event=AUDIT_DEVICE_PROVISION_ROLLBACK,
            actor={"userId": claims["userId"], "role": claims["role"], "clientId": claims["clientId"]},
            subject={"serialNumber": serial, "patientId": patient_id, "clientId": target_client_id},
            action="create",
            extra={"reason": "iot_publish_failed", "cmd_id": cmd_id, "iot_error": str(exc)},
        )
        raise ApiError(
            code="PROVISION_FAILED",
            message="Could not publish activate command; retry",
            status=500,
        )

    # Emit the per-event audit lines that handlers manage explicitly
    # (the @audit_middleware decorator emits one default event per call;
    # provision actually generates 2-3 logical events: claimed,
    # assigned, activation_sent).
    actor = {"userId": claims["userId"], "role": claims["role"], "clientId": claims["clientId"]}
    subject = {"serialNumber": serial, "patientId": patient_id, "clientId": target_client_id, "facilityId": target_facility_id}
    if is_first_provision:
        emit_audit(event=AUDIT_DEVICE_CLAIMED, actor=actor, subject=subject, action="update",
                   extra={"owningClientId": target_client_id, "owningFacilityId": target_facility_id})
    emit_audit(event=AUDIT_DEVICE_ASSIGNED, actor=actor, subject=subject, action="create",
               after={"validFrom": now_iso})
    emit_audit(event=AUDIT_DEVICE_ACTIVATION_SENT, actor=actor, subject=subject, action="create",
               extra={"cmd_id": cmd_id, "topic": f"gs/{serial}/cmd"})

    return ok_response(
        {
            "device": {
                "serialNumber": serial,
                "status": "provisioned",
                "owningClientId": target_client_id,
                "owningFacilityId": target_facility_id,
            },
            "assignment": {
                "patientId": patient_id,
                "censusId": target_census_id,
                "validFrom": now_iso,
            },
            "activation": {"cmdId": cmd_id, "ackWindowHours": ACTIVATION_ACK_WINDOW_HOURS},
        }
    )


def _rollback_provision(serial: str, cmd_id: str, was_first_provision: bool) -> None:
    """Reverse step 1 of provision when step 2 or 3 fails."""
    try:
        set_parts = ["#status = :ready", "lastTransitionAt = :now"]
        # First-provision: ownership was set on the same path; REMOVE it on rollback.
        remove_parts = ["outstandingActivationCmds.#cid", "currentAssignmentSk"]
        if was_first_provision:
            remove_parts.extend(["owningClientId", "owningFacilityId"])
        _devices.update_item(
            Key={"serialNumber": serial},
            UpdateExpression="SET " + ", ".join(set_parts) + " REMOVE " + ", ".join(remove_parts),
            ExpressionAttributeNames={"#status": "status", "#cid": cmd_id},
            ExpressionAttributeValues={":ready": STATE_READY, ":now": _now_iso()},
        )
    except ClientError:
        logger.exception("rollback_step1_failed", extra={"serial": serial, "cmd_id": cmd_id})


def _action_end_assignment(
    event: dict[str, Any], claims: dict[str, Any], serial: str
) -> dict[str, Any]:
    """POST /api/v1/devices/{serial}/end-assignment."""
    _validate_serial(serial)
    require_role(claims, "caregiver", "facility_admin", "client_admin", "household_owner", "internal_admin")
    require_mfa(claims)

    device = _get_device(serial)
    enforce_tenancy(claims, device.get("owningClientId"))
    enforce_scope(claims, target_facility_id=device.get("owningFacilityId"))

    current_state = device.get("status", STATE_READY)
    transition = validate_transition(current_state, ACTION_END_ASSIGNMENT)
    if isinstance(transition, TransitionError):
        raise ApiError(
            code=transition.code,
            message=transition.message,
            status=409,
            details={"currentStatus": current_state},
        )

    now_iso = _now_iso()
    assignment_sk = device.get("currentAssignmentSk")
    wipe_id = f"wipe_{uuid.uuid4()}"

    # Close the assignment row's validUntil (if there is one)
    if assignment_sk:
        try:
            _assignments.update_item(
                Key={"serialNumber": serial, "assignedAt": assignment_sk},
                UpdateExpression="SET validUntil = :u",
                ExpressionAttributeValues={":u": now_iso},
            )
        except ClientError:
            logger.exception("assignment_close_failed", extra={"serial": serial})

    # Step 1: state transition + ensure outstandingWipeCmds map exists.
    # Same two-step idiom as provision (DDB can't do
    # "SET outstandingWipeCmds = if_not_exists(...)"
    # alongside "SET outstandingWipeCmds.#cid = ..." in one expression).
    _devices.update_item(
        Key={"serialNumber": serial},
        UpdateExpression=(
            "SET #status = :discontinued, "
            "lastTransitionAt = :now, "
            "wipe_requested_at = :now, "
            "outstandingWipeCmds = if_not_exists(outstandingWipeCmds, :empty) "
            "REMOVE currentAssignmentSk"
        ),
        ExpressionAttributeNames={"#status": "status"},
        ExpressionAttributeValues={
            ":discontinued": "discontinued",
            ":now": now_iso,
            ":empty": {},
        },
    )

    # Step 2: write the new wipe_id into the map.
    _devices.update_item(
        Key={"serialNumber": serial},
        UpdateExpression="SET outstandingWipeCmds.#cid = :now",
        ExpressionAttributeNames={"#cid": wipe_id},
        ExpressionAttributeValues={":now": now_iso},
    )

    # DL14 + DL15: clear desired.activated_at AND set desired.wipe_requested
    # in a single Shadow call. Keeps both invariants atomic.
    try:
        _set_shadow_desired(serial, {"activated_at": None, "wipe_requested": wipe_id})
    except ClientError:
        logger.exception("shadow_set_failed", extra={"serial": serial})

    # Publish wipe cmd to gs/{serial}/cmd. Best-effort: if publish fails,
    # status stays discontinued, outstandingWipeCmds keeps the entry, and
    # an admin force-reset is the recovery path. Memo §5 spelled out a
    # 500-on-failure path but that races with the existing end-assignment
    # idempotency (a retry would 409 on status); the simpler model is to
    # log + emit a warning audit + return 200 (end-assignment succeeded),
    # and let the wipe-ack-stuck alarm (L17 in observability) catch it.
    wipe_publish_ok = True
    try:
        cmd_payload = {"cmd": "wipe", "cmd_id": wipe_id, "ts": now_iso}
        iot_data.publish(
            topic=f"gs/{serial}/cmd",
            qos=1,
            payload=json.dumps(cmd_payload),
        )
    except ClientError as exc:
        wipe_publish_ok = False
        logger.exception(
            "wipe_cmd_publish_failed",
            extra={"serial": serial, "wipe_id": wipe_id, "iot_error": str(exc)},
        )

    body = _parse_body(event)
    actor = {"userId": claims["userId"], "role": claims["role"], "clientId": claims["clientId"]}
    subject = {"serialNumber": serial, "clientId": device.get("owningClientId")}
    emit_audit(
        event=AUDIT_DEVICE_ASSIGNMENT_ENDED,
        actor=actor,
        subject=subject,
        action="update",
        extra={"reason": body.get("reason", "manual"), "previousState": current_state},
    )
    emit_audit(
        event=AUDIT_DEVICE_WIPE_REQUESTED,
        actor=actor,
        subject=subject,
        action="create",
        extra={
            "wipe_id": wipe_id,
            "topic": f"gs/{serial}/cmd",
            "publish_ok": wipe_publish_ok,
        },
    )

    return ok_response(
        {
            "device": {
                "serialNumber": serial,
                "status": "discontinued",
                "lastTransitionAt": now_iso,
            },
            "wipe": {
                "wipe_id": wipe_id,
                "ackWindowHours": ACTIVATION_ACK_WINDOW_HOURS,
                "publish_ok": wipe_publish_ok,
            },
        }
    )


def _action_decommission(
    event: dict[str, Any], claims: dict[str, Any], serial: str
) -> dict[str, Any]:
    """POST /api/v1/devices/{serial}/decommission."""
    _validate_serial(serial)
    body = _parse_body(event)
    reason = body.get("reason")

    # Per L11: caregivers can mark lost/broken; admins required for retired/end_of_life
    if reason in {"lost", "broken"}:
        require_role(
            claims, "caregiver", "facility_admin", "client_admin",
            "household_owner", "internal_admin",
        )
    elif reason in {"retired", "end_of_life"}:
        require_role(claims, "facility_admin", "client_admin", "household_owner", "internal_admin")
        require_mfa(claims)
    else:
        raise ApiError(
            code="INVALID_REQUEST",
            message=f"Decommission requires reason ∈ {sorted(ALL_REASONS)}",
            status=400,
        )

    device = _get_device(serial)
    enforce_tenancy(claims, device.get("owningClientId"))
    enforce_scope(claims, target_facility_id=device.get("owningFacilityId"))

    current_state = device.get("status", STATE_READY)
    transition = validate_transition(current_state, ACTION_DECOMMISSION, reason=reason)
    if isinstance(transition, TransitionError):
        raise ApiError(code=transition.code, message=transition.message, status=409)

    now_iso = _now_iso()
    _devices.update_item(
        Key={"serialNumber": serial},
        UpdateExpression=(
            "SET #status = :d, decommissionReason = :r, decommissionedAt = :now, "
            "decommissionedBy = :who, lastTransitionAt = :now"
        ),
        ExpressionAttributeNames={"#status": "status"},
        ExpressionAttributeValues={
            ":d": "decommissioned",
            ":r": reason,
            ":now": now_iso,
            ":who": claims["userId"],
        },
    )

    try:
        _set_shadow_desired_activated_at(serial, None)
    except ClientError:
        logger.exception("shadow_clear_failed", extra={"serial": serial})

    actor = {"userId": claims["userId"], "role": claims["role"], "clientId": claims["clientId"]}
    subject = {"serialNumber": serial, "clientId": device.get("owningClientId")}
    emit_audit(
        event=AUDIT_DEVICE_DECOMMISSIONED,
        actor=actor, subject=subject, action="update",
        extra={"reason": reason, "notes": body.get("notes"), "previousState": current_state},
    )
    return ok_response({"device": {"serialNumber": serial, "status": "decommissioned",
                                    "decommissionReason": reason, "decommissionedAt": now_iso,
                                    "decommissionedBy": claims["userId"]}})


def _action_recover(
    event: dict[str, Any], claims: dict[str, Any], serial: str
) -> dict[str, Any]:
    """POST /api/v1/devices/{serial}/recover (only from decommissioned-lost)."""
    _validate_serial(serial)
    require_role(claims, "facility_admin", "client_admin", "household_owner", "internal_admin")
    require_mfa(claims)

    device = _get_device(serial)
    enforce_tenancy(claims, device.get("owningClientId"))
    enforce_scope(claims, target_facility_id=device.get("owningFacilityId"))

    if device.get("status") != "decommissioned" or device.get("decommissionReason") not in RECOVERABLE_REASONS:
        raise ApiError(
            code="INVALID_TRANSITION",
            message="Only devices decommissioned with reason=lost can be recovered",
            status=409,
            details={"currentStatus": device.get("status"),
                     "decommissionReason": device.get("decommissionReason")},
        )

    transition = validate_transition(device.get("status"), ACTION_RECOVER)
    if isinstance(transition, TransitionError):
        raise ApiError(code=transition.code, message=transition.message, status=409)

    now_iso = _now_iso()
    _devices.update_item(
        Key={"serialNumber": serial},
        UpdateExpression=(
            "SET #status = :ready, lastTransitionAt = :now "
            "REMOVE decommissionReason, decommissionedAt, decommissionedBy"
        ),
        ExpressionAttributeNames={"#status": "status"},
        ExpressionAttributeValues={":ready": STATE_READY, ":now": now_iso},
    )

    actor = {"userId": claims["userId"], "role": claims["role"], "clientId": claims["clientId"]}
    subject = {"serialNumber": serial, "clientId": device.get("owningClientId")}
    emit_audit(event=AUDIT_DEVICE_RECOVERED, actor=actor, subject=subject, action="update",
               extra={"previousReason": device.get("decommissionReason")})

    return ok_response({"device": {"serialNumber": serial, "status": STATE_READY,
                                    "owningClientId": device.get("owningClientId"),
                                    "owningFacilityId": device.get("owningFacilityId")}})


def _action_release(
    event: dict[str, Any], claims: dict[str, Any], serial: str
) -> dict[str, Any]:
    """
    POST /api/v1/devices/{serial}/release — internal_admin: release ownership.

    Nulls owningClientId/owningFacilityId so the device returns to the unowned
    inventory pool and becomes claimable again by a NEW household via QR. This is
    the explicit "un-claim" the ownership model otherwise lacks: end-assignment +
    recycle deliberately KEEP ownership (a household doesn't lose its device by
    pausing monitoring; a facility re-assigns internally), so rotating one
    physical device between different D2C households needs this step (see
    ARCHITECTURE §Ownership invariants). Heavily audited.

    Precondition: the device must not be actively assigned — status ∈
    {ready_to_provision, discontinued}. Callers wanting "end + release" end the
    assignment first (→ discontinued), then release. The wipe-before-reuse
    guarantee is preserved regardless: a new household can only claim once the
    device reaches ready_to_provision, which only happens after the wipe-ack.
    """
    _validate_serial(serial)
    require_role(claims, "internal_admin")
    require_mfa(claims)

    device = _get_device(serial)
    prev_owner = device.get("owningClientId")
    if not prev_owner:
        raise ApiError(
            code="NOT_OWNED",
            message="Device has no owner to release",
            status=409,
            details={"serial": serial},
        )
    status = device.get("status", STATE_READY)
    if status not in ("ready_to_provision", "discontinued"):
        raise ApiError(
            code="DEVICE_ASSIGNED",
            message="End the assignment before releasing ownership",
            status=409,
            details={"currentStatus": status},
        )

    now_iso = _now_iso()
    _devices.update_item(
        Key={"serialNumber": serial},
        UpdateExpression=(
            "SET lastTransitionAt = :now REMOVE owningClientId, owningFacilityId"
        ),
        ExpressionAttributeValues={":now": now_iso},
    )

    actor = {"userId": claims["userId"], "role": claims["role"], "clientId": claims["clientId"]}
    emit_audit(
        event=AUDIT_DEVICE_OWNERSHIP_RELEASED,
        actor=actor,
        subject={"serialNumber": serial, "clientId": prev_owner},
        action="update",
        extra={
            "previousOwningClientId": prev_owner,
            "previousOwningFacilityId": device.get("owningFacilityId"),
            "previousState": status,
        },
    )
    return ok_response(
        {"device": {"serialNumber": serial, "status": status,
                    "owningClientId": None, "owningFacilityId": None}}
    )


def _action_force_reset(
    event: dict[str, Any], claims: dict[str, Any], serial: str
) -> dict[str, Any]:
    """POST /api/v1/devices/{serial}/force-reset (admin-only)."""
    _validate_serial(serial)
    require_role(claims, "facility_admin", "client_admin", "household_owner", "internal_admin")
    require_mfa(claims)

    body = _parse_body(event)
    reason = body.get("reason")
    if not reason or not isinstance(reason, str) or len(reason) < 4:
        raise ApiError(code="INVALID_REQUEST",
                       message="force-reset requires a `reason` string (≥4 chars)",
                       status=400)

    device = _get_device(serial)
    enforce_tenancy(claims, device.get("owningClientId"))
    enforce_scope(claims, target_facility_id=device.get("owningFacilityId"))

    current_state = device.get("status", STATE_READY)
    transition = validate_transition(current_state, ACTION_FORCE_RESET)
    if isinstance(transition, TransitionError):
        raise ApiError(code=transition.code, message=transition.message, status=409)

    now_iso = _now_iso()
    # Force-reset clears the new wipe state too (DL15) — the wipe cmd
    # is moot once admin overrides directly to ready_to_provision.
    # Caveat: force-reset bypasses the wipe-ack predicate, so the device
    # may retain old patient data until it next reads Shadow desired
    # and re-enters pre-activation per DL14. Caller assumed responsibility
    # via the `reason` field and the elevated audit.
    _devices.update_item(
        Key={"serialNumber": serial},
        UpdateExpression=(
            "SET #status = :ready, lastTransitionAt = :now "
            "REMOVE currentAssignmentSk, outstandingWipeCmds, wipe_requested_at"
        ),
        ExpressionAttributeNames={"#status": "status"},
        ExpressionAttributeValues={":ready": STATE_READY, ":now": now_iso},
    )

    try:
        _set_shadow_desired(serial, {"activated_at": None, "wipe_requested": None})
    except ClientError:
        logger.exception("shadow_clear_failed", extra={"serial": serial})

    actor = {"userId": claims["userId"], "role": claims["role"], "clientId": claims["clientId"]}
    subject = {"serialNumber": serial, "clientId": device.get("owningClientId")}
    emit_audit(
        event=AUDIT_DEVICE_FORCE_RESET,
        actor=actor, subject=subject, action="update",
        extra={"reason": reason, "previousState": current_state},
    )

    return ok_response({"device": {"serialNumber": serial, "status": STATE_READY}})


def _action_move(
    event: dict[str, Any], claims: dict[str, Any], serial: str, scope: str
) -> dict[str, Any]:
    """
    POST /api/v1/devices/{serial}/move-facility   (scope='facility')
    POST /api/v1/devices/{serial}/move-client     (scope='client')
    """
    _validate_serial(serial)
    body = _parse_body(event)

    if scope == "facility":
        action = ACTION_MOVE_FACILITY
        require_role(claims, "client_admin", "internal_admin")
        require_mfa(claims)
        target_facility = body.get("targetFacilityId")
        if not target_facility:
            raise ApiError(code="INVALID_REQUEST", message="targetFacilityId required", status=400)
        target_client = None
    elif scope == "client":
        action = ACTION_MOVE_CLIENT
        require_role(claims, "internal_admin")
        require_mfa(claims)
        target_client = body.get("targetClientId")
        target_facility = body.get("targetFacilityId")
        if not target_client or not target_facility:
            raise ApiError(code="INVALID_REQUEST",
                           message="targetClientId + targetFacilityId required",
                           status=400)
    else:
        raise ApiError(code="INVALID_REQUEST", message=f"Unknown move scope '{scope}'", status=400)

    device = _get_device(serial)
    enforce_tenancy(claims, device.get("owningClientId"))

    current_state = device.get("status", STATE_READY)
    # L15 (tightened 2026-05-17 per memo D10): cross-facility / cross-client
    # move requires status = ready_to_provision. Caller must end-assignment
    # AND wait for wipe-ack before moving — ensures ownership transfers
    # happen only on clean (wiped) devices, no patient-cache residue
    # crosses ownership boundaries.
    if current_state != STATE_READY:
        raise ApiError(
            code="INVALID_TRANSITION",
            message=(
                "Move requires device in ready_to_provision state. "
                "End the current assignment and wait for the wipe-ack auto-recycle "
                "(or force-reset if the device is stuck) before moving."
            ),
            status=409,
            details={
                "currentStatus": current_state,
                "requiredStatus": STATE_READY,
                "spec": "phase-2a-device-lifecycle.md L15 (tightened by 2026-05-17-aa-battery-recycle.md D10)",
            },
        )
    transition = validate_transition(current_state, action)
    if isinstance(transition, TransitionError):
        raise ApiError(
            code=transition.code,
            message=transition.message,
            status=409,
            details={"currentStatus": current_state},
        )

    now_iso = _now_iso()
    update_parts = ["lastTransitionAt = :now", "owningFacilityId = :f"]
    attr_values = {":now": now_iso, ":f": target_facility}
    if target_client:
        update_parts.append("owningClientId = :c")
        attr_values[":c"] = target_client

    _devices.update_item(
        Key={"serialNumber": serial},
        UpdateExpression="SET " + ", ".join(update_parts),
        ExpressionAttributeValues=attr_values,
    )

    actor = {"userId": claims["userId"], "role": claims["role"], "clientId": claims["clientId"]}
    subject = {"serialNumber": serial, "clientId": target_client or device.get("owningClientId"),
               "facilityId": target_facility}
    emit_audit(
        event=AUDIT_DEVICE_OWNERSHIP_MOVED,
        actor=actor, subject=subject, action="update",
        before={"owningClientId": device.get("owningClientId"),
                "owningFacilityId": device.get("owningFacilityId")},
        after={"owningClientId": target_client or device.get("owningClientId"),
               "owningFacilityId": target_facility},
        extra={"scope": scope, "reason": body.get("reason")},
    )

    return ok_response({"device": {"serialNumber": serial, "status": current_state,
                                    "owningClientId": target_client or device.get("owningClientId"),
                                    "owningFacilityId": target_facility}})


def _action_admin_create(event: dict[str, Any], claims: dict[str, Any]) -> dict[str, Any]:
    """POST /api/v1/admin/devices (internal_admin only — manufacturer-side bulk record creation)."""
    require_role(claims, "internal_admin")
    require_mfa(claims)

    body = _parse_body(event)
    devices_in = body.get("devices") or []
    if not devices_in or not isinstance(devices_in, list):
        raise ApiError(code="INVALID_REQUEST", message="`devices` array required", status=400)

    created = []
    minted: list[dict[str, str]] = []  # {serialNumber, walkerId} per newly-created device
    now_iso = _now_iso()
    for dev in devices_in:
        serial = dev.get("serialNumber")
        _validate_serial(serial)

        # DT-0 L3: deviceType set at record creation (registry-authoritative).
        # Default walker_cap; unknown values are a whole-request 400 so a
        # typo'd type never lands in the registry.
        device_type = dev.get("deviceType") or DEFAULT_TYPE
        if device_type not in KNOWN_DEVICE_TYPES:
            raise ApiError(
                code="INVALID_DEVICE_TYPE",
                message=f"deviceType must be one of {sorted(KNOWN_DEVICE_TYPES)}",
                status=400,
                details={"serialNumber": serial, "deviceType": device_type},
            )
        hardware_variant = dev.get("hardwareVariant")
        if hardware_variant is not None and (
            not isinstance(hardware_variant, str) or len(hardware_variant) > 64
        ):
            raise ApiError(
                code="INVALID_REQUEST",
                message="hardwareVariant must be a string of at most 64 chars",
                status=400,
                details={"serialNumber": serial},
            )

        # D2C claim anchor (QR-provisioning spec §4 — the "load-bearing" mint):
        # every manufactured unit gets an opaque, server-minted UUIDv4 walkerId,
        # indexed by the sparse `by-walker-id` GSI so the QR deep-link
        # /setup/{walkerId} public-lookup resolves to the device (the sequential
        # GS-serial stays server-side, never on the sticker). 122 bits of CSPRNG
        # entropy ⇒ unique by construction; the serial-level attribute_not_exists
        # put below keeps re-create idempotent, so a walkerId is never re-minted.
        # (Printed short-code fallback + claim-binding deferred — coord §C57.)
        walker_id = str(uuid.uuid4())

        item: dict[str, Any] = {
            "serialNumber": serial,
            "status": STATE_READY,
            "deviceType": device_type,
            "walkerId": walker_id,
            "createdAt": now_iso,
            "createdBy": claims["userId"],
            "certFingerprint": dev.get("certFingerprint", ""),
            "outstandingActivationCmds": {},
        }
        if hardware_variant:
            item["hardwareVariant"] = hardware_variant

        try:
            _devices.put_item(
                Item=item,
                ConditionExpression="attribute_not_exists(serialNumber)",
            )
            created.append(serial)
            minted.append({"serialNumber": serial, "walkerId": walker_id})
            actor = {"userId": claims["userId"], "role": claims["role"], "clientId": claims["clientId"]}
            audit_extra: dict[str, Any] = {
                "certFingerprint": dev.get("certFingerprint", ""),
                "deviceType": device_type,
                "walkerId": walker_id,
            }
            if hardware_variant:
                audit_extra["hardwareVariant"] = hardware_variant
            emit_audit(
                event=AUDIT_DEVICE_CREATED,
                actor=actor,
                subject={"serialNumber": serial},
                action="create",
                extra=audit_extra,
            )
        except ClientError as exc:
            if exc.response["Error"]["Code"] == "ConditionalCheckFailedException":
                # Already exists — skip; report in response
                continue
            raise

    return ok_response(
        {"created": created, "skipped": len(devices_in) - len(created), "devices": minted}
    )


# ── Fleet ops (internal) ───────────────────────────────────────────────


def _current_assignment(serial: str, device: dict[str, Any]) -> dict[str, Any] | None:
    """
    Active-assignment view for a device, or None.

    `currentAssignmentSk` is set on provision and REMOVEd on end-assignment
    (see _action_end_assignment), so its presence is the authoritative "has an
    active assignment" signal — no need to scan/close-check assignment rows.
    Best-effort: a read failure returns None rather than failing the fleet list.
    """
    sk = device.get("currentAssignmentSk")
    if not sk:
        return None
    try:
        res = _assignments.get_item(Key={"serialNumber": serial, "assignedAt": sk})
    except ClientError:
        logger.warning("fleet_assignment_read_failed", extra={"serial": serial})
        return None
    a = res.get("Item")
    if not a:
        return None
    return {
        "patientId": a.get("patientId"),
        "facilityId": a.get("facilityId"),
        "censusId": a.get("censusId"),
        "startedAt": a.get("validFrom") or a.get("assignedAt"),
    }


def _fleet_row(
    device: dict[str, Any],
    telemetry: dict[str, Any] | None,
    assignment: dict[str, Any] | None,
) -> dict[str, Any]:
    """
    Shape one Device Registry item (+ joined live state) into a fleet row.

    Pure: all IO (Shadow get, assignment get) is done by the caller so this is
    unit-testable. Extends _device_view's projection with the live telemetry,
    current assignment, and the derived lifecycle flags a fleet operator needs
    for diagnosis + readiness gates. `outstanding*Cmds` maps (cmd_id → issued_at
    ISO) are surfaced raw so the CLI can compute "pending for Xh / stuck".
    """
    keep = (
        "serialNumber", "status", "deviceType", "hardwareVariant",
        "owningClientId", "owningFacilityId", "walkerId",
        "activated_at", "firstHeartbeatAt", "lastTransitionAt",
        "wipe_requested_at", "decommissionReason", "decommissionedAt",
    )
    row = {k: v for k, v in device.items() if k in keep}
    # DT-0 D9: legacy records predate the attribute — read as walker_cap.
    row.setdefault("deviceType", DEFAULT_TYPE)

    outstanding_activation = device.get("outstandingActivationCmds") or {}
    outstanding_wipe = device.get("outstandingWipeCmds") or {}
    row["outstandingActivationCmds"] = outstanding_activation
    row["outstandingWipeCmds"] = outstanding_wipe
    # activationPending is only meaningful while still provisioned (stuck signal).
    row["activationPending"] = bool(outstanding_activation) and row.get("status") == "provisioned"
    row["wipePending"] = bool(outstanding_wipe)

    if telemetry is not None:
        row["telemetry"] = telemetry
    if assignment is not None:
        row["currentAssignment"] = assignment
    return row


def _action_fleet_list(event: dict[str, Any], claims: dict[str, Any]) -> dict[str, Any]:
    """
    GET /api/v1/admin/devices — internal fleet status board.

    Internal-only (internal_support + internal_admin; both may VIEW the whole
    fleet per the ARCHITECTURE authz matrix — writes stay gated per-action).
    Scans the Device Registry (tiny at pilot scale), joins each row with its
    live Shadow telemetry + current assignment, returns the fleet with derived
    lifecycle flags. Powers the `fleet ls/status/check/ready` CLI; the
    single-device diagnosis + readiness gates are derived client-side from
    these rows. See docs/specs/device-fleet-ops-tooling.md.

    Optional exact-match query filters: `?status=` and `?deviceType=` (applied
    post-scan — the fleet is small enough that a FilterExpression buys nothing).
    """
    require_role(claims, "internal_support", "internal_admin")
    require_mfa(claims)

    qs = event.get("queryStringParameters") or {}
    status_filter = qs.get("status")
    type_filter = qs.get("deviceType")

    items: list[dict[str, Any]] = []
    scan_kwargs: dict[str, Any] = {}
    while True:
        res = _devices.scan(**scan_kwargs)
        items.extend(res.get("Items", []))
        lek = res.get("LastEvaluatedKey")
        if not lek:
            break
        scan_kwargs["ExclusiveStartKey"] = lek

    rows: list[dict[str, Any]] = []
    for device in items:
        if status_filter and device.get("status") != status_filter:
            continue
        if type_filter and (device.get("deviceType") or DEFAULT_TYPE) != type_filter:
            continue
        serial = device.get("serialNumber", "")
        if not serial:
            continue
        telemetry = _shadow_telemetry(serial)
        assignment = _current_assignment(serial, device)
        rows.append(_fleet_row(device, telemetry, assignment))

    # Stable board order: group by lifecycle status, then serial.
    rows.sort(key=lambda r: (str(r.get("status", "")), str(r.get("serialNumber", ""))))

    # Audit the cross-tenant internal read (count-only subject, no per-device
    # PII) — mirrors patient.list.read (audit_catalog). The audit-forwarder
    # auto-stamps internal_access + elevated severity from the actor role.
    emit_audit(
        event=AUDIT_DEVICE_FLEET_READ,
        actor={"userId": claims.get("userId"), "role": claims.get("role"), "clientId": claims.get("clientId")},
        subject={"count": len(rows)},
        action="read",
        extra={"statusFilter": status_filter, "deviceTypeFilter": type_filter},
    )
    return ok_response({"devices": rows, "count": len(rows)})


# ── Output shaping ─────────────────────────────────────────────────────


def _device_view(item: dict[str, Any]) -> dict[str, Any]:
    """Project DDB item to the API response shape (drop internal-only attrs)."""
    keep = (
        "serialNumber", "status", "owningClientId", "owningFacilityId",
        "decommissionReason", "decommissionedAt", "decommissionedBy",
        "firmwareVersion", "activated_at", "firstHeartbeatAt", "lastTransitionAt",
        "deviceType", "hardwareVariant",
    )
    view = {k: v for k, v in item.items() if k in keep}
    # DT-0 D9: legacy records predate the attribute — read as walker_cap.
    view.setdefault("deviceType", DEFAULT_TYPE)
    return view


# ── Route dispatcher ───────────────────────────────────────────────────


def _route(api_event: dict[str, Any]) -> tuple[str, dict[str, str]]:
    """Return (action_name, path_params_dict). Raises 404 on unknown route."""
    rc = api_event.get("requestContext", {}) or {}
    http = rc.get("http", {}) or {}
    method = (http.get("method") or "").upper()
    route_key = api_event.get("routeKey", "")
    path_params = api_event.get("pathParameters") or {}

    # Match API Gateway routeKey patterns (e.g., "GET /api/v1/devices/{serial}")
    table = {
        ("GET", "GET /api/v1/devices/{serial}"): "get_device",
        ("GET", "GET /api/v1/admin/devices"): "fleet_list",
        ("GET", "GET /api/v1/patients/{patientId}/devices"): "list_patient_devices",
        ("POST", "POST /api/v1/devices/{serial}/provision"): "provision",
        ("POST", "POST /api/v1/devices/{serial}/end-assignment"): "end_assignment",
        ("POST", "POST /api/v1/devices/{serial}/decommission"): "decommission",
        ("POST", "POST /api/v1/devices/{serial}/recover"): "recover",
        ("POST", "POST /api/v1/devices/{serial}/release"): "release",
        ("POST", "POST /api/v1/devices/{serial}/force-reset"): "force_reset",
        ("POST", "POST /api/v1/devices/{serial}/move-facility"): "move_facility",
        ("POST", "POST /api/v1/devices/{serial}/move-client"): "move_client",
        ("POST", "POST /api/v1/admin/devices"): "admin_create",
    }
    action = table.get((method, route_key))
    if not action:
        raise ApiError(
            code="NOT_FOUND",
            message=f"No route matches {method} {route_key}",
            status=404,
        )
    return action, path_params


def handler(api_event: dict[str, Any], context: Any) -> dict[str, Any]:
    """
    Entry point. Route dispatch → per-action handler. The audit_middleware
    isn't used here because the device-api Lambda generates per-action
    audit events explicitly (provision emits up to 3: claimed, assigned,
    activation_sent). Middleware-managed single-event-per-call doesn't
    fit. We still want the error-envelope behavior, though — so wrap
    the dispatcher in a try/except ApiError.
    """
    claims = extract_claims(api_event)
    try:
        require_authenticated(claims)
        # Phase 2A-0 Q8 (amended 2026-05-24): app-layer 4-hr absolute cap
        # for internal_* sessions. No-op for customer roles. Mirrors the
        # audit_middleware-wired version; called here too because device-api
        # uses its own dispatcher pattern (per the docstring above)
        # rather than @audit_middleware, so the middleware-wired call never
        # reaches this handler. Same one-line guard in patient-api,
        # alert-actions, and patient-mgmt entry points.
        enforce_internal_session_age(claims)
        action, params = _route(api_event)

        if action == "get_device":
            return _action_get_device(api_event, claims, params.get("serial", ""))
        if action == "fleet_list":
            return _action_fleet_list(api_event, claims)
        if action == "list_patient_devices":
            return _action_list_patient_devices(api_event, claims, params.get("patientId", ""))
        if action == "provision":
            return _action_provision(api_event, claims, params.get("serial", ""))
        if action == "end_assignment":
            return _action_end_assignment(api_event, claims, params.get("serial", ""))
        if action == "decommission":
            return _action_decommission(api_event, claims, params.get("serial", ""))
        if action == "recover":
            return _action_recover(api_event, claims, params.get("serial", ""))
        if action == "release":
            return _action_release(api_event, claims, params.get("serial", ""))
        if action == "force_reset":
            return _action_force_reset(api_event, claims, params.get("serial", ""))
        if action == "move_facility":
            return _action_move(api_event, claims, params.get("serial", ""), "facility")
        if action == "move_client":
            return _action_move(api_event, claims, params.get("serial", ""), "client")
        if action == "admin_create":
            return _action_admin_create(api_event, claims)

        raise ApiError(code="NOT_FOUND", message=f"Unrouted action {action}", status=404)
    except ApiError as exc:
        # `error_message` (not `message`) — Powertools Logger reserves `message`
        # for the log line itself; using it in `extra=` raises KeyError.
        logger.warning("device_api_error", extra={"code": exc.code, "status": exc.status,
                                                   "error_message": exc.message})
        return error_response(exc.code, exc.message, exc.status, exc.details)

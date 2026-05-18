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
from typing import Any

import boto3
from botocore.exceptions import ClientError

from _shared.api_audit import audit_middleware
from _shared.api_authz import (
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
    AUDIT_DEVICE_FORCE_RESET,
    AUDIT_DEVICE_OWNERSHIP_MOVED,
    AUDIT_DEVICE_PROVISION_ROLLBACK,
    AUDIT_DEVICE_RECOVERED,
    AUDIT_DEVICE_ACTIVATION_SENT,
    AUDIT_DEVICE_WIPE_REQUESTED,
)
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

    return ok_response({"device": _device_view(device)})


def _action_list_patient_devices(
    event: dict[str, Any], claims: dict[str, Any], patient_id: str
) -> dict[str, Any]:
    """GET /api/v1/patients/{patientId}/devices."""
    patient = _get_patient(patient_id)
    enforce_tenancy(claims, patient.get("clientId"))
    enforce_scope(
        claims,
        target_facility_id=patient.get("facilityId"),
        target_census_id=patient.get("censusId"),
    )

    # Query DeviceAssignments by GSI by-patient
    res = _assignments.query(
        IndexName="by-patient",
        KeyConditionExpression="patientId = :p",
        ExpressionAttributeValues={":p": patient_id},
    )
    return ok_response({"assignments": res.get("Items", [])})


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
    now_iso = _now_iso()
    for dev in devices_in:
        serial = dev.get("serialNumber")
        _validate_serial(serial)
        try:
            _devices.put_item(
                Item={
                    "serialNumber": serial,
                    "status": STATE_READY,
                    "createdAt": now_iso,
                    "createdBy": claims["userId"],
                    "certFingerprint": dev.get("certFingerprint", ""),
                    "outstandingActivationCmds": {},
                },
                ConditionExpression="attribute_not_exists(serialNumber)",
            )
            created.append(serial)
            actor = {"userId": claims["userId"], "role": claims["role"], "clientId": claims["clientId"]}
            emit_audit(
                event=AUDIT_DEVICE_CREATED,
                actor=actor,
                subject={"serialNumber": serial},
                action="create",
                extra={"certFingerprint": dev.get("certFingerprint", "")},
            )
        except ClientError as exc:
            if exc.response["Error"]["Code"] == "ConditionalCheckFailedException":
                # Already exists — skip; report in response
                continue
            raise

    return ok_response({"created": created, "skipped": len(devices_in) - len(created)})


# ── Output shaping ─────────────────────────────────────────────────────


def _device_view(item: dict[str, Any]) -> dict[str, Any]:
    """Project DDB item to the API response shape (drop internal-only attrs)."""
    keep = (
        "serialNumber", "status", "owningClientId", "owningFacilityId",
        "decommissionReason", "decommissionedAt", "decommissionedBy",
        "firmwareVersion", "activated_at", "firstHeartbeatAt", "lastTransitionAt",
    )
    return {k: v for k, v in item.items() if k in keep}


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
        ("GET", "GET /api/v1/patients/{patientId}/devices"): "list_patient_devices",
        ("POST", "POST /api/v1/devices/{serial}/provision"): "provision",
        ("POST", "POST /api/v1/devices/{serial}/end-assignment"): "end_assignment",
        ("POST", "POST /api/v1/devices/{serial}/decommission"): "decommission",
        ("POST", "POST /api/v1/devices/{serial}/recover"): "recover",
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
        action, params = _route(api_event)

        if action == "get_device":
            return _action_get_device(api_event, claims, params.get("serial", ""))
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

"""
Patient Management API handler — Phase 2A-UM-P.

Single Lambda dispatches all 6 patient-mutation routes (L1 of
phase-2a-um-patient-management.md). Mirrors the device-api dispatcher
shape: explicit emit_audit calls per action (not the @audit_middleware
decorator) because POST /patients can emit up to 3 audit events
(patient.created + device.claimed + device.assigned + device.activation_sent
when the optional atomic-provision chain fires).

Routes:
  POST   /api/v1/patients                                  — atomic create + optional provision (L3)
  PATCH  /api/v1/patients/{id}                             — name / room / cross-facility transfer
  POST   /api/v1/patients/{id}/discharge                   — cascade via DDB Streams + 2A-DL Lambda
  POST   /api/v1/patients/{id}/notifications/pause         — set pause
  DELETE /api/v1/patients/{id}/notifications/pause         — clear pause
  PATCH  /api/v1/patients/{id}/care-note                   — set/clear care note

Provision-inline note (v1):
  POST /patients with a deviceSerial does the device-side writes INLINE
  rather than invoking the device-api Lambda. Mirrors the 3-step write
  in device-api/handler.py::_action_provision verbatim (DDB Devices
  conditional update + DDB DeviceAssignments PutItem + IoT publish +
  Shadow UpdateThingShadow), with the same rollback on step-3 failure.
  Duplication is intentional pragma for v1; refactor into _shared/
  provision.py when both handlers' provision logic diverges (TODO).
  Patient-mgmt's IAM grants mirror device-api's so the inline writes
  are authorized.

Audit emission rules (spec L4 / 2A-0 Q2):
  - Success → emit per-event audit (patient.created, patient.update, ...)
  - 403 / 500 → emit on failure
  - 400 / 404 / 409 → no audit (caller-error patterns)

Handler also DOES NOT use audit_middleware. The middleware emits exactly
one event per call and binds the event name at decorator time, which
doesn't fit the multi-event POST /patients path. Manual emission gives
explicit control over before/after payload shape and event count.
"""

from __future__ import annotations

import json
import os
import time
import uuid
from typing import Any

import boto3
from botocore.exceptions import ClientError

from _shared.api_authz import (
    enforce_internal_session_age,
    enforce_patient_access,
    enforce_scope,
    enforce_tenancy,
    extract_claims,
    is_internal,
    linked_patient_ids,
    require_authenticated,
    require_role,
)
from _shared.api_error import ApiError, error_response, ok_response
from _shared.audit_catalog import (
    AUDIT_DEVICE_ACTIVATION_SENT,
    AUDIT_DEVICE_ASSIGNED,
    AUDIT_DEVICE_CLAIMED,
    AUDIT_DEVICE_PROVISION_ROLLBACK,
    AUDIT_PATIENT_CARE_NOTE_UPDATE,
    AUDIT_PATIENT_CREATE_ROLLBACK,
    AUDIT_PATIENT_CREATED,
    AUDIT_PATIENT_DISCHARGE,
    AUDIT_PATIENT_NOTIFICATIONS_PAUSE,
    AUDIT_PATIENT_NOTIFICATIONS_RESUME_MANUAL,
    AUDIT_PATIENT_RESUME_ROLLBACK,
    AUDIT_PATIENT_RESUMED,
    AUDIT_PATIENT_UPDATE,
)
from _shared.observability import emit_audit, get_logger
from _shared.pause_check import compute_until_epoch, days_remaining, is_currently_paused

from validation import (
    validate_care_note_body,
    validate_create_patient_body,
    validate_discharge_body,
    validate_pause_body,
    validate_resume_body,
    validate_update_patient_body,
)


# ── Env + AWS clients ─────────────────────────────────────────────────


ENV = os.environ.get("ENVIRONMENT", "dev")
PATIENTS_TABLE = os.environ["PATIENTS_TABLE"]
ORGANIZATIONS_TABLE = os.environ["ORGANIZATIONS_TABLE"]
USERS_TABLE = os.environ["USERS_TABLE"]
DEVICES_TABLE = os.environ["DEVICES_TABLE"]
ASSIGNMENTS_TABLE = os.environ["ASSIGNMENTS_TABLE"]
ROLE_ASSIGNMENTS_TABLE = os.environ["ROLE_ASSIGNMENTS_TABLE"]
ACTIVATION_ACK_WINDOW_HOURS = int(os.environ.get("ACTIVATION_ACK_WINDOW_HOURS", "24"))

logger = get_logger()
ddb = boto3.resource("dynamodb")
iot_data = boto3.client("iot-data")  # data plane: publish + update_thing_shadow

_patients = ddb.Table(PATIENTS_TABLE)
_orgs = ddb.Table(ORGANIZATIONS_TABLE)
_users = ddb.Table(USERS_TABLE)
_devices = ddb.Table(DEVICES_TABLE)
_assignments = ddb.Table(ASSIGNMENTS_TABLE)
_role_assignments = ddb.Table(ROLE_ASSIGNMENTS_TABLE)


STATE_READY = "ready_to_provision"


# ── Helpers ───────────────────────────────────────────────────────────


def _now_iso() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def _now_epoch() -> int:
    return int(time.time())


def _request_id(event: dict[str, Any]) -> str:
    return event.get("requestContext", {}).get("requestId", "")


def _actor(claims: dict[str, Any]) -> dict[str, Any]:
    return {
        "userId": claims.get("userId", ""),
        "role": claims.get("role", ""),
        "clientId": claims.get("clientId", ""),
    }


def _parse_body(event: dict[str, Any]) -> Any:
    raw = event.get("body") or "{}"
    try:
        return json.loads(raw) if raw else {}
    except (json.JSONDecodeError, TypeError) as exc:
        raise ApiError(
            code="INVALID_REQUEST",
            message=f"Body is not valid JSON: {exc}",
            status=400,
        )


def _get_patient(patient_id: str) -> dict[str, Any]:
    """Read Patient row; raise PATIENT_NOT_FOUND if absent."""
    res = _patients.get_item(Key={"patientId": patient_id})
    item = res.get("Item")
    if not item:
        raise ApiError(
            code="PATIENT_NOT_FOUND",
            message=f"Patient {patient_id} not found",
            status=404,
        )
    return item


def _get_census(client_id: str, facility_id: str, census_id: str) -> dict[str, Any]:
    """
    Resolve a census from the Organizations single-table.
    SK pattern: `facility#<facilityId>#census#<censusId>` per Phase 0B-rev.
    Raises CENSUS_NOT_FOUND if absent.
    """
    sk = f"facility#{facility_id}#census#{census_id}"
    res = _orgs.get_item(Key={"clientId": client_id, "sk": sk})
    item = res.get("Item")
    if not item:
        raise ApiError(
            code="CENSUS_NOT_FOUND",
            message=f"Census {census_id} not found in facility {facility_id}",
            status=404,
        )
    return item


def _resolve_census_to_facility(
    actor_client_id: str, census_id: str, *, is_internal_caller: bool = False
) -> tuple[str, str, dict[str, Any]]:
    """
    Given just a censusId, find its parent facility within the actor's
    client tenancy. Returns (facilityId, clientId, census_row).

    Strategy: scan the Organizations table for the actor's clientId where
    SK contains `census#<censusId>`. Per Phase 0B-rev there's no GSI on
    census-by-id; we rely on the single-table layout where the actor's
    clientId is the PK we can pin. Scan-within-partition is bounded by
    the facility/census count per client (typically <100).

    For internal callers (no fixed clientId), this helper isn't usable —
    caller must pass facilityId explicitly.
    """
    if is_internal_caller:
        raise ApiError(
            code="INVALID_REQUEST",
            message="Internal callers must pass facilityId explicitly with censusId",
            status=400,
            details={"missing": "facilityId"},
        )
    # Query the partition by SK prefix is awkward; just query all census
    # rows in this client (capped at a reasonable page size).
    res = _orgs.query(
        KeyConditionExpression="clientId = :c AND begins_with(sk, :pre)",
        ExpressionAttributeValues={":c": actor_client_id, ":pre": "facility#"},
        Limit=500,
    )
    needle = f"#census#{census_id}"
    for row in res.get("Items", []):
        sk = row.get("sk", "")
        if sk.endswith(needle):
            # SK: facility#<facId>#census#<cenId>
            try:
                _, fac_id, _, cen_id = sk.split("#")
                if cen_id == census_id:
                    return fac_id, actor_client_id, row
            except ValueError:
                continue
    raise ApiError(
        code="CENSUS_NOT_FOUND",
        message=f"Census {census_id} not found in your scope",
        status=404,
    )


def _get_user_display_name(user_id: str) -> str:
    """
    Denormalize the actor's displayName onto the careNote row (spec D5).
    Best-effort: if Users.GetItem fails or the user isn't in Users yet
    (e.g., very new account), fall back to the user's claims.email
    (handled by the caller). Returns empty string on any error here.
    """
    if not user_id:
        return ""
    try:
        res = _users.get_item(Key={"userId": user_id})
        item = res.get("Item") or {}
        return item.get("displayName") or item.get("email") or ""
    except ClientError:
        logger.exception("users_get_item_failed", extra={"userId": user_id})
        return ""


def _patient_view(p: dict[str, Any]) -> dict[str, Any]:
    """Full patient projection for response bodies, incl. care note + pause state."""
    pause = p.get("notificationsPaused")
    pause_view: dict[str, Any] | None = None
    if pause and is_currently_paused(p):
        pause_view = {
            "until": pause.get("until"),
            "reason": pause.get("reason"),
            "pausedAt": pause.get("pausedAt"),
            "pausedBy": pause.get("pausedBy"),
            "daysRemaining": days_remaining(p),
        }
    care_note = p.get("careNote")
    care_note_view = None
    if isinstance(care_note, dict) and care_note.get("text"):
        care_note_view = {
            "text": care_note.get("text"),
            "updatedBy": care_note.get("updatedBy"),
            "updatedByName": care_note.get("updatedByName"),
            "updatedAt": care_note.get("updatedAt"),
        }
    return {
        "patientId": p.get("patientId"),
        "displayName": p.get("displayName"),
        "status": p.get("status"),
        "timezone": p.get("timezone"),
        "clientId": p.get("clientId"),
        "facilityId": p.get("facilityId"),
        "censusId": p.get("censusId"),
        "room": p.get("room"),
        "careNote": care_note_view,
        "notificationsPaused": pause_view,
        "createdAt": p.get("createdAt"),
    }


# ── POST /api/v1/patients — create + optional atomic provision ────────


def _action_create_patient(event: dict[str, Any], claims: dict[str, Any]) -> dict[str, Any]:
    """
    POST /api/v1/patients

    Required body: displayName, censusId, room.
    Optional: deviceSerial — if present, runs the inline atomic provision
    chain (mirrors device-api L14: rollback on IoT publish failure).
    """
    require_role(
        claims,
        "caregiver", "facility_admin", "client_admin", "household_owner", "internal_admin",
    )

    body = validate_create_patient_body(_parse_body(event))
    display_name = body["displayName"]
    census_id = body["censusId"]
    room = body["room"]
    device_serial = body.get("deviceSerial")

    actor = _actor(claims)
    internal_caller = is_internal(claims)

    # Step 1: resolve census + parent facility within actor's tenancy.
    # Internal callers must pass facilityId explicitly (out of scope for v1 —
    # internal-tier patient creation lands in 2A-INT). For now: deny.
    if internal_caller:
        raise ApiError(
            code="INSUFFICIENT_PERMISSIONS",
            message="Internal-tier patient creation not yet supported. Use 2A-INT once available.",
            status=403,
        )
    facility_id, target_client_id, _census_row = _resolve_census_to_facility(
        claims["clientId"], census_id
    )

    # Step 2: scope check — caregiver/facility_admin must have access to this census/facility.
    enforce_scope(claims, target_facility_id=facility_id, target_census_id=census_id)

    # Step 3: derive patient timezone from facility (best-effort fallback).
    # Per spec Q7 lean: inherit from facility's timezone field.
    timezone = _census_row.get("timezone") or _get_facility_timezone(target_client_id, facility_id)

    # Step 4: if deviceSerial present, pre-flight verify Device Registry status.
    device: dict[str, Any] | None = None
    if device_serial:
        device = _get_device_or_404(device_serial)
        current_state = device.get("status", STATE_READY)
        if current_state != STATE_READY:
            raise ApiError(
                code="DEVICE_NOT_AVAILABLE",
                message=f"Device {device_serial} is in state {current_state}; cannot provision",
                status=409,
                details={"currentStatus": current_state},
            )
        existing_owner = device.get("owningClientId")
        if existing_owner and existing_owner != target_client_id:
            raise ApiError(
                code="OWNED_BY_OTHER_CLIENT",
                message="Device belongs to another organization",
                status=403,
            )

    # Step 5: generate patientId + write Patient row (conditional idempotency).
    patient_id = f"pat_{uuid.uuid4().hex[:24]}"
    now_iso = _now_iso()
    patient_item = {
        "patientId": patient_id,
        "displayName": display_name,
        "status": "active",
        # Composite range key for the by-census-status / by-client-status GSIs.
        # MUST be `<status>_<patientId>` (underscore) so the patient-api readers'
        # `status_patientId begins_with("active_")` filter matches — without this
        # attribute the new patient is absent from both GSIs and never appears in
        # /me/patients or the census roster. Underscore (not `#`) per 0B-rev and
        # patient-api/queries.py.
        "status_patientId": f"active_{patient_id}",
        "clientId": target_client_id,
        "facilityId": facility_id,
        "censusId": census_id,
        "room": room,
        "timezone": timezone,
        "createdAt": now_iso,
        "createdBy": claims["userId"],
    }
    try:
        _patients.put_item(
            Item=patient_item,
            ConditionExpression="attribute_not_exists(patientId)",
        )
    except ClientError as exc:
        if exc.response["Error"]["Code"] == "ConditionalCheckFailedException":
            # UUID collision — vanishingly unlikely but possible. Caller retry.
            raise ApiError(
                code="INVALID_REQUEST",
                message="Patient ID collision; retry",
                status=500,
            )
        raise

    # Step 6: if deviceSerial present, run inline provision chain.
    activation: dict[str, Any] | None = None
    if device_serial and device:
        try:
            activation = _provision_inline(
                serial=device_serial,
                patient_id=patient_id,
                target_client_id=target_client_id,
                target_facility_id=facility_id,
                target_census_id=census_id,
                claims=claims,
                device=device,
            )
        except Exception as exc:
            # Roll back the Patient row created in Step 5.
            _rollback_patient_create(patient_id)
            emit_audit(
                event=AUDIT_PATIENT_CREATE_ROLLBACK,
                actor=actor,
                subject={"patientId": patient_id, "clientId": target_client_id},
                action="create",
                extra={
                    "reason": "provision_failed",
                    "serial": device_serial,
                    "errorType": type(exc).__name__,
                },
                request_id=_request_id(event),
            )
            # Re-raise as PROVISION_FAILED unless already an ApiError.
            if isinstance(exc, ApiError):
                raise
            raise ApiError(
                code="PROVISION_FAILED",
                message=f"Provision failed: {exc}",
                status=500,
            )

    # Step 7: success audits.
    emit_audit(
        event=AUDIT_PATIENT_CREATED,
        actor=actor,
        subject={
            "patientId": patient_id,
            "clientId": target_client_id,
            "facilityId": facility_id,
            "censusId": census_id,
        },
        action="create",
        after={"displayName": display_name, "room": room, "timezone": timezone},
        extra={"hasDevice": bool(device_serial)},
        request_id=_request_id(event),
    )

    response_body: dict[str, Any] = {"patient": _patient_view(patient_item)}
    if activation:
        response_body["device"] = {
            "serialNumber": device_serial,
            "status": "provisioned",
            "activationCmdId": activation["cmd_id"],
        }
        response_body["activation"] = {
            "cmdId": activation["cmd_id"],
            "ackWindowHours": ACTIVATION_ACK_WINDOW_HOURS,
        }
    return ok_response(response_body, status=201)


def _get_facility_timezone(client_id: str, facility_id: str) -> str:
    """Read facility timezone from Organizations; default to UTC if absent."""
    sk = f"facility#{facility_id}"
    try:
        res = _orgs.get_item(Key={"clientId": client_id, "sk": sk})
        return (res.get("Item") or {}).get("timezone", "UTC")
    except ClientError:
        return "UTC"


def _get_device_or_404(serial: str) -> dict[str, Any]:
    res = _devices.get_item(Key={"serialNumber": serial})
    item = res.get("Item")
    if not item:
        raise ApiError(
            code="DEVICE_NOT_FOUND",
            message=f"Device {serial} not found in registry",
            status=404,
        )
    return item


def _provision_inline(
    *,
    serial: str,
    patient_id: str,
    target_client_id: str,
    target_facility_id: str,
    target_census_id: str,
    claims: dict[str, Any],
    device: dict[str, Any],
) -> dict[str, Any]:
    """
    Inline provision chain — mirrors device-api._action_provision. Caller
    is responsible for rolling back the patient-side row if this raises.
    Returns {cmd_id} on success.

    NOTE: this is duplicated from device-api/handler.py::_action_provision.
    Refactor into _shared/provision.py once both diverge in behavior
    (TODO). For now the duplication is deliberate to keep v1 simple
    (avoids the awkwardness of Lambda invoke for in-process service
    calls). Patient-mgmt's IAM grants must mirror device-api's for this
    to work (iot:Publish, iot:UpdateThingShadow, write Devices +
    DeviceAssignments).
    """
    actor = _actor(claims)
    existing_owner = device.get("owningClientId")
    is_first_provision = not existing_owner

    cmd_id = f"act_{uuid.uuid4()}"
    now_iso = _now_iso()

    # Step 1a: ensure outstandingActivationCmds map exists.
    _devices.update_item(
        Key={"serialNumber": serial},
        UpdateExpression="SET outstandingActivationCmds = if_not_exists(outstandingActivationCmds, :empty)",
        ExpressionAttributeValues={":empty": {}},
    )

    # Step 1b: conditional update on Device Registry.
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

    try:
        _devices.update_item(
            Key={"serialNumber": serial},
            UpdateExpression="SET " + ", ".join(update_expr_parts),
            ConditionExpression="#status = :ready",
            ExpressionAttributeNames=attr_names,
            ExpressionAttributeValues=attr_values,
        )
    except ClientError as exc:
        if exc.response["Error"]["Code"] == "ConditionalCheckFailedException":
            # Lost a race — fresh device state for the caller.
            fresh = _get_device_or_404(serial)
            raise ApiError(
                code="DEVICE_NOT_AVAILABLE",
                message="Device just provisioned by another caller — refresh and try again",
                status=409,
                details={"currentStatus": fresh.get("status")},
            )
        raise

    # Step 2: DeviceAssignments row.
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
        _rollback_device_step1(serial, cmd_id, is_first_provision)
        emit_audit(
            event=AUDIT_DEVICE_PROVISION_ROLLBACK,
            actor=actor,
            subject={"serialNumber": serial, "patientId": patient_id, "clientId": target_client_id},
            action="create",
            extra={"reason": "assignments_put_failed", "cmd_id": cmd_id},
        )
        raise ApiError(
            code="PROVISION_FAILED",
            message="Could not record device assignment; retry",
            status=500,
        )

    # Step 3: IoT publish activate cmd + Shadow desired.activated_at.
    try:
        cmd_payload = {"cmd": "activate", "cmd_id": cmd_id, "ts": now_iso}
        iot_data.publish(topic=f"gs/{serial}/cmd", qos=1, payload=json.dumps(cmd_payload))
        shadow_payload = json.dumps({"state": {"desired": {"activated_at": now_iso}}})
        iot_data.update_thing_shadow(thingName=serial, payload=shadow_payload.encode())
    except ClientError as exc:
        _rollback_device_step1(serial, cmd_id, is_first_provision)
        try:
            _assignments.delete_item(Key={"serialNumber": serial, "assignedAt": now_iso})
        except ClientError:
            logger.exception("rollback_assignments_delete_failed")
        emit_audit(
            event=AUDIT_DEVICE_PROVISION_ROLLBACK,
            actor=actor,
            subject={"serialNumber": serial, "patientId": patient_id, "clientId": target_client_id},
            action="create",
            extra={"reason": "iot_publish_failed", "cmd_id": cmd_id, "iot_error": str(exc)},
        )
        raise ApiError(
            code="PROVISION_FAILED",
            message="Could not publish activate command; retry",
            status=500,
        )

    # Device-side success audits (matches device-api emission shape).
    subject = {
        "serialNumber": serial,
        "patientId": patient_id,
        "clientId": target_client_id,
        "facilityId": target_facility_id,
    }
    if is_first_provision:
        emit_audit(
            event=AUDIT_DEVICE_CLAIMED, actor=actor, subject=subject, action="update",
            extra={"owningClientId": target_client_id, "owningFacilityId": target_facility_id},
        )
    emit_audit(
        event=AUDIT_DEVICE_ASSIGNED, actor=actor, subject=subject, action="create",
        after={"validFrom": now_iso},
    )
    emit_audit(
        event=AUDIT_DEVICE_ACTIVATION_SENT, actor=actor, subject=subject, action="create",
        extra={"cmd_id": cmd_id, "topic": f"gs/{serial}/cmd"},
    )
    return {"cmd_id": cmd_id, "assigned_at": now_iso}


def _rollback_device_step1(serial: str, cmd_id: str, was_first_provision: bool) -> None:
    """Reverse the Devices conditional update from _provision_inline step 1b."""
    try:
        set_parts = ["#status = :ready", "lastTransitionAt = :now"]
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
        logger.exception("rollback_device_step1_failed",
                         extra={"serial": serial, "cmd_id": cmd_id})


def _rollback_patient_create(patient_id: str) -> None:
    """Delete the Patient row created earlier in the chain. Best-effort."""
    try:
        _patients.delete_item(Key={"patientId": patient_id})
    except ClientError:
        logger.exception("rollback_patient_delete_failed", extra={"patientId": patient_id})


# ── PATCH /api/v1/patients/{id} ───────────────────────────────────────


def _action_update_patient(
    event: dict[str, Any], claims: dict[str, Any], patient_id: str
) -> dict[str, Any]:
    """
    PATCH /api/v1/patients/{id} — partial update of displayName / room / censusId.

    Cross-facility transfer (censusId points to a census in a different
    facility than the patient's current one) requires client_admin+ per
    Q3 decision in 2A-UM-P spec.
    """
    require_role(
        claims,
        "caregiver", "facility_admin", "client_admin", "household_owner", "internal_admin",
    )
    body = validate_update_patient_body(_parse_body(event))

    patient = _get_patient(patient_id)
    linked = linked_patient_ids(claims, _role_assignments)
    enforce_patient_access(claims, patient, linked_ids=linked)

    if patient.get("status") != "active":
        raise ApiError(
            code="INVALID_STATE",
            message=f"Cannot edit a patient with status={patient.get('status')}",
            status=409,
            details={"currentStatus": patient.get("status")},
        )

    before = {
        "displayName": patient.get("displayName"),
        "censusId": patient.get("censusId"),
        "facilityId": patient.get("facilityId"),
        "room": patient.get("room"),
    }
    after: dict[str, Any] = dict(before)
    fields_changed: list[str] = []
    cross_facility_transfer = False

    if "displayName" in body and body["displayName"] != patient.get("displayName"):
        after["displayName"] = body["displayName"]
        fields_changed.append("displayName")
    if "room" in body and body["room"] != patient.get("room"):
        after["room"] = body["room"]
        fields_changed.append("room")
    if "censusId" in body and body["censusId"] != patient.get("censusId"):
        new_census_id = body["censusId"]
        # Resolve new census → its parent facility within actor's client.
        new_fac_id, _, _ = _resolve_census_to_facility(
            patient["clientId"], new_census_id, is_internal_caller=is_internal(claims)
        )
        if new_fac_id != patient.get("facilityId"):
            # Cross-facility: require client_admin+ (or internal).
            cross_facility_transfer = True
            if not is_internal(claims) and claims.get("role") not in {"client_admin"}:
                raise ApiError(
                    code="INSUFFICIENT_PERMISSIONS",
                    message="Cross-facility transfer requires client_admin role",
                    status=403,
                    details={
                        "currentFacilityId": patient.get("facilityId"),
                        "targetFacilityId": new_fac_id,
                    },
                )
        else:
            # Same-facility census change → standard scope check.
            enforce_scope(
                claims,
                target_facility_id=new_fac_id,
                target_census_id=new_census_id,
            )
        after["censusId"] = new_census_id
        after["facilityId"] = new_fac_id
        fields_changed.append("censusId")
        if new_fac_id != patient.get("facilityId"):
            fields_changed.append("facilityId")

    if not fields_changed:
        # Body parsed clean but all fields equal existing values → no-op.
        return ok_response({"patient": _patient_view(patient), "changes": {"fieldsChanged": []}})

    # Build the UpdateExpression dynamically (only changed fields).
    set_parts: list[str] = []
    attr_names: dict[str, str] = {}
    attr_values: dict[str, Any] = {}
    if "displayName" in fields_changed:
        set_parts.append("#displayName = :displayName")
        attr_names["#displayName"] = "displayName"
        attr_values[":displayName"] = after["displayName"]
    if "room" in fields_changed:
        set_parts.append("#room = :room")
        attr_names["#room"] = "room"
        attr_values[":room"] = after["room"]
    if "censusId" in fields_changed:
        set_parts.append("#censusId = :censusId")
        attr_names["#censusId"] = "censusId"
        attr_values[":censusId"] = after["censusId"]
    if "facilityId" in fields_changed:
        set_parts.append("#facilityId = :facilityId")
        attr_names["#facilityId"] = "facilityId"
        attr_values[":facilityId"] = after["facilityId"]
    set_parts.append("lastUpdatedAt = :now")
    set_parts.append("lastUpdatedBy = :actor")
    attr_values[":now"] = _now_iso()
    attr_values[":actor"] = claims["userId"]

    # Conditional: status must still be active (defense against discharge race).
    attr_names["#status"] = "status"
    attr_values[":active"] = "active"
    try:
        _patients.update_item(
            Key={"patientId": patient_id},
            UpdateExpression="SET " + ", ".join(set_parts),
            ConditionExpression="#status = :active",
            ExpressionAttributeNames=attr_names,
            ExpressionAttributeValues=attr_values,
        )
    except ClientError as exc:
        if exc.response["Error"]["Code"] == "ConditionalCheckFailedException":
            raise ApiError(
                code="INVALID_STATE",
                message="Patient was discharged mid-update; refresh and retry",
                status=409,
            )
        raise

    actor = _actor(claims)
    emit_audit(
        event=AUDIT_PATIENT_UPDATE,
        actor=actor,
        subject={
            "patientId": patient_id,
            "clientId": patient["clientId"],
            "facilityId": after.get("facilityId"),
            "censusId": after.get("censusId"),
        },
        action="update",
        before=before,
        after=after,
        extra={
            "fieldsChanged": fields_changed,
            "crossFacilityTransfer": cross_facility_transfer,
        },
        request_id=_request_id(event),
    )

    # Re-fetch for the response so we return the canonical merged shape.
    updated = _get_patient(patient_id)
    response_body: dict[str, Any] = {
        "patient": _patient_view(updated),
        "changes": {
            "fieldsChanged": fields_changed,
            "crossFacilityTransfer": cross_facility_transfer,
        },
    }
    if cross_facility_transfer:
        response_body["changes"]["oldFacilityId"] = before["facilityId"]
        response_body["changes"]["newFacilityId"] = after["facilityId"]
    return ok_response(response_body)


# ── POST /api/v1/patients/{id}/discharge ──────────────────────────────


def _action_discharge_patient(
    event: dict[str, Any], claims: dict[str, Any], patient_id: str
) -> dict[str, Any]:
    """
    POST /api/v1/patients/{id}/discharge

    Sets Patient.status = discharged + dischargedAt + dischargeReason + dischargeNotes.
    DDB Streams on the Patients table fan out to the existing 2A-DL
    discharge-cascade Lambda, which iterates active DeviceAssignments and
    fires `wipe` commands per device. The handler returns synchronously
    with the pre-update active-assignment count; cascade completion is async.
    """
    require_role(
        claims,
        "caregiver", "facility_admin", "client_admin", "household_owner", "internal_admin",
    )

    body = validate_discharge_body(_parse_body(event))
    patient = _get_patient(patient_id)
    linked = linked_patient_ids(claims, _role_assignments)
    enforce_patient_access(claims, patient, linked_ids=linked)

    if patient.get("status") != "active":
        raise ApiError(
            code="INVALID_STATE",
            message=f"Patient already in status={patient.get('status')}; cannot discharge",
            status=409,
            details={"currentStatus": patient.get("status")},
        )

    # Count active device assignments before discharge (for response info).
    # Active = validUntil null/missing. Bounded to ≤1 in practice (one
    # device per patient at a time) but defensive Query handles edge cases.
    active_assignments: list[dict[str, Any]] = []
    try:
        asn_res = _assignments.query(
            IndexName="by-patient",
            KeyConditionExpression="patientId = :p",
            ExpressionAttributeValues={":p": patient_id},
        )
        for row in asn_res.get("Items", []):
            if not row.get("validUntil"):
                active_assignments.append(row)
    except ClientError:
        logger.exception("assignments_query_failed_during_discharge", extra={"patientId": patient_id})

    now_iso = _now_iso()
    before = {
        "status": "active",
        "dischargedAt": None,
        "dischargeReason": None,
        "dischargeNotes": None,
    }
    # Reason is optional (the structured discharge reason was dropped 2026-06-03
    # — "End Monitoring" needs no reason). May be None.
    reason = body.get("reason")
    after = {
        "status": "discharged",
        "dischargedAt": now_iso,
        "dischargeReason": reason,
        "dischargeNotes": body["notes"],
    }

    update_expr_parts = [
        "#status = :discharged",
        # Keep the GSI range key in sync with status so the discharged patient
        # drops out of the active roster (patient-api filters
        # status_patientId begins_with("active_")). Without this the row keeps
        # `active_<id>` and lingers in /me/patients + the census after discharge.
        "status_patientId = :spi_discharged",
        "dischargedAt = :now",
        "dischargedBy = :actor",
    ]
    attr_names = {"#status": "status"}
    attr_values: dict[str, Any] = {
        ":discharged": "discharged",
        ":spi_discharged": f"discharged_{patient_id}",
        ":active": "active",
        ":now": now_iso,
        ":actor": claims["userId"],
    }
    if reason:
        update_expr_parts.append("dischargeReason = :reason")
        attr_values[":reason"] = reason
    if body["notes"]:
        update_expr_parts.append("dischargeNotes = :notes")
        attr_values[":notes"] = body["notes"]

    try:
        _patients.update_item(
            Key={"patientId": patient_id},
            UpdateExpression="SET " + ", ".join(update_expr_parts),
            ConditionExpression="#status = :active",
            ExpressionAttributeNames=attr_names,
            ExpressionAttributeValues=attr_values,
        )
    except ClientError as exc:
        if exc.response["Error"]["Code"] == "ConditionalCheckFailedException":
            raise ApiError(
                code="INVALID_STATE",
                message="Patient discharged by another caller; refresh and retry",
                status=409,
            )
        raise

    actor = _actor(claims)
    emit_audit(
        event=AUDIT_PATIENT_DISCHARGE,
        actor=actor,
        subject={
            "patientId": patient_id,
            "clientId": patient["clientId"],
            "facilityId": patient.get("facilityId"),
            "censusId": patient.get("censusId"),
        },
        action="update",
        before=before,
        after=after,
        extra={
            "activeAssignmentCount": len(active_assignments),
            "deviceSerials": [a.get("serialNumber") for a in active_assignments],
        },
        request_id=_request_id(event),
    )

    return ok_response({
        "patient": {
            "patientId": patient_id,
            "status": "discharged",
            "dischargedAt": now_iso,
            "dischargeReason": reason,
            "dischargeNotes": body["notes"],
        },
        "cascade": {
            "devicesEnded": len(active_assignments),
            "deviceSerials": [a.get("serialNumber") for a in active_assignments],
            "wipeRequested": len(active_assignments) > 0,
        },
    })


# ── POST /api/v1/patients/{id}/resume — "Start Monitoring Again" ──────


def _action_resume_patient(
    event: dict[str, Any], claims: dict[str, Any], patient_id: str
) -> dict[str, Any]:
    """
    POST /api/v1/patients/{id}/resume

    "Start Monitoring Again" — flips a discontinued (discharged) resident back
    to `active` under the SAME patientId (so their Activity Series + Alert
    History stay attached), re-homes them into a unit/room, and atomically
    re-provisions a device. The inverse of _action_discharge_patient + a reuse
    of _action_create_patient's _provision_inline chain.

    deviceSerial is REQUIRED (validation): an active resident with no device is
    the anti-state §C42 eliminated. The body has no displayName — resume keeps
    the same record, so the name is preserved.

    The flip is discharged→active. The discharge-cascade Lambda's DDB-stream
    filter fires only on NewImage.status == "discharged" (and its
    _was_discharged guard needs old!=discharged AND new==discharged), so this
    flip does NOT trigger a spurious wipe/end-assignment cascade.
    """
    require_role(
        claims,
        "caregiver", "facility_admin", "client_admin", "household_owner", "internal_admin",
    )

    # Internal-tier patient management lands in 2A-INT (mirrors create) —
    # _resolve_census_to_facility needs the actor's fixed clientId.
    if is_internal(claims):
        raise ApiError(
            code="INSUFFICIENT_PERMISSIONS",
            message="Internal-tier patient resume not yet supported. Use 2A-INT once available.",
            status=403,
        )

    body = validate_resume_body(_parse_body(event))
    census_id = body["censusId"]
    room = body["room"]
    device_serial = body["deviceSerial"]

    actor = _actor(claims)

    # Step 1: load the patient + verify the caller can see it (same scope gate
    # as the discontinued census list that surfaced this resident).
    patient = _get_patient(patient_id)
    linked = linked_patient_ids(claims, _role_assignments)
    enforce_patient_access(claims, patient, linked_ids=linked)

    # Step 2: only a discontinued (discharged) resident can be resumed.
    if patient.get("status") != "discharged":
        raise ApiError(
            code="INVALID_STATE",
            message=f"Only discontinued residents can be resumed; status={patient.get('status')}",
            status=409,
            details={"currentStatus": patient.get("status")},
        )

    # Step 3: resolve the target census → parent facility within the caller's
    # client tenancy, then scope-check the placement. This is a FRESH placement
    # (the resident isn't in any active facility), so it uses the same authz as
    # create — NOT the PATCH cross-facility client_admin+ transfer rule.
    facility_id, target_client_id, census_row = _resolve_census_to_facility(
        claims["clientId"], census_id
    )
    enforce_scope(claims, target_facility_id=facility_id, target_census_id=census_id)

    # Step 4: pre-flight the device (mirrors create step 4).
    device = _get_device_or_404(device_serial)
    current_state = device.get("status", STATE_READY)
    if current_state != STATE_READY:
        raise ApiError(
            code="DEVICE_NOT_AVAILABLE",
            message=f"Device {device_serial} is in state {current_state}; cannot provision",
            status=409,
            details={"currentStatus": current_state},
        )
    existing_owner = device.get("owningClientId")
    if existing_owner and existing_owner != target_client_id:
        raise ApiError(
            code="OWNED_BY_OTHER_CLIENT",
            message="Device belongs to another organization",
            status=403,
        )

    # Step 5: snapshot the discharged sub-state for rollback, then flip the
    # Patient row to active. timezone re-derives from the (possibly new)
    # facility, mirroring create. The REMOVE clears the discharge metadata so
    # the row reads cleanly as active (discharge history lives in the audit log).
    timezone = census_row.get("timezone") or _get_facility_timezone(target_client_id, facility_id)
    now_iso = _now_iso()
    snapshot = {
        "status": patient.get("status"),
        "status_patientId": patient.get("status_patientId"),
        "censusId": patient.get("censusId"),
        "facilityId": patient.get("facilityId"),
        "room": patient.get("room"),
        "timezone": patient.get("timezone"),
        "dischargedAt": patient.get("dischargedAt"),
        "dischargedBy": patient.get("dischargedBy"),
        "dischargeReason": patient.get("dischargeReason"),
        "dischargeNotes": patient.get("dischargeNotes"),
    }
    before = {
        "status": "discharged",
        "censusId": patient.get("censusId"),
        "facilityId": patient.get("facilityId"),
        "room": patient.get("room"),
    }
    after = {
        "status": "active",
        "censusId": census_id,
        "facilityId": facility_id,
        "room": room,
    }
    try:
        _patients.update_item(
            Key={"patientId": patient_id},
            UpdateExpression=(
                "SET #status = :active, status_patientId = :spi_active, "
                "censusId = :cen, facilityId = :fac, #room = :room, "
                "#tz = :tz, resumedAt = :now, resumedBy = :actor "
                "REMOVE dischargedAt, dischargedBy, dischargeReason, dischargeNotes"
            ),
            ConditionExpression="#status = :discharged",
            ExpressionAttributeNames={
                "#status": "status",
                "#room": "room",
                "#tz": "timezone",
            },
            ExpressionAttributeValues={
                ":active": "active",
                ":spi_active": f"active_{patient_id}",
                ":cen": census_id,
                ":fac": facility_id,
                ":room": room,
                ":tz": timezone,
                ":now": now_iso,
                ":actor": claims["userId"],
                ":discharged": "discharged",
            },
        )
    except ClientError as exc:
        if exc.response["Error"]["Code"] == "ConditionalCheckFailedException":
            raise ApiError(
                code="INVALID_STATE",
                message="Resident is no longer discontinued (raced with another caller); refresh and retry",
                status=409,
            )
        raise

    # Step 6: re-provision the device (atomic with the flip — roll the flip
    # back to discharged on any provision failure).
    try:
        activation = _provision_inline(
            serial=device_serial,
            patient_id=patient_id,
            target_client_id=target_client_id,
            target_facility_id=facility_id,
            target_census_id=census_id,
            claims=claims,
            device=device,
        )
    except Exception as exc:
        _rollback_patient_resume(patient_id, snapshot)
        emit_audit(
            event=AUDIT_PATIENT_RESUME_ROLLBACK,
            actor=actor,
            subject={"patientId": patient_id, "clientId": target_client_id},
            action="update",
            extra={
                "reason": "provision_failed",
                "serial": device_serial,
                "errorType": type(exc).__name__,
            },
            request_id=_request_id(event),
        )
        if isinstance(exc, ApiError):
            raise
        raise ApiError(
            code="PROVISION_FAILED",
            message=f"Provision failed: {exc}",
            status=500,
        )

    # Step 7: success audit. The _provision_inline chain emits its own
    # device.claimed / device.assigned / device.activation_sent.
    emit_audit(
        event=AUDIT_PATIENT_RESUMED,
        actor=actor,
        subject={
            "patientId": patient_id,
            "clientId": target_client_id,
            "facilityId": facility_id,
            "censusId": census_id,
        },
        action="update",
        before=before,
        after=after,
        extra={"serial": device_serial},
        request_id=_request_id(event),
    )

    updated = _get_patient(patient_id)
    return ok_response({
        "patient": _patient_view(updated),
        "device": {
            "serialNumber": device_serial,
            "status": "provisioned",
            "activationCmdId": activation["cmd_id"],
        },
        "activation": {
            "cmdId": activation["cmd_id"],
            "ackWindowHours": ACTIVATION_ACK_WINDOW_HOURS,
        },
    })


def _rollback_patient_resume(patient_id: str, snapshot: dict[str, Any]) -> None:
    """
    Restore the discharged sub-state after a resume's re-provision failed.
    The resume analog of _rollback_patient_create (which deletes the row);
    here the row pre-existed, so we restore the captured fields instead.
    Best-effort — logs on failure.
    """
    try:
        set_parts = [
            "#status = :status",
            "status_patientId = :spi",
            "censusId = :cen",
            "facilityId = :fac",
            "#room = :room",
            "#tz = :tz",
        ]
        attr_names = {"#status": "status", "#room": "room", "#tz": "timezone"}
        attr_values: dict[str, Any] = {
            ":status": snapshot.get("status") or "discharged",
            ":spi": snapshot.get("status_patientId") or f"discharged_{patient_id}",
            ":cen": snapshot.get("censusId"),
            ":fac": snapshot.get("facilityId"),
            ":room": snapshot.get("room"),
            ":tz": snapshot.get("timezone"),
        }
        # Restore the discharge metadata that the flip REMOVE'd.
        if snapshot.get("dischargedAt"):
            set_parts.append("dischargedAt = :da")
            attr_values[":da"] = snapshot["dischargedAt"]
        if snapshot.get("dischargedBy"):
            set_parts.append("dischargedBy = :db")
            attr_values[":db"] = snapshot["dischargedBy"]
        if snapshot.get("dischargeReason"):
            set_parts.append("dischargeReason = :dr")
            attr_values[":dr"] = snapshot["dischargeReason"]
        if snapshot.get("dischargeNotes"):
            set_parts.append("dischargeNotes = :dn")
            attr_values[":dn"] = snapshot["dischargeNotes"]
        _patients.update_item(
            Key={"patientId": patient_id},
            UpdateExpression="SET " + ", ".join(set_parts) + " REMOVE resumedAt, resumedBy",
            ExpressionAttributeNames=attr_names,
            ExpressionAttributeValues=attr_values,
        )
    except ClientError:
        logger.exception("rollback_patient_resume_failed", extra={"patientId": patient_id})


# ── POST /api/v1/patients/{id}/notifications/pause ────────────────────


def _action_pause_notifications(
    event: dict[str, Any], claims: dict[str, Any], patient_id: str
) -> dict[str, Any]:
    """POST /api/v1/patients/{id}/notifications/pause."""
    require_role(
        claims,
        "caregiver", "facility_admin", "client_admin", "household_owner", "internal_admin",
    )

    body = validate_pause_body(_parse_body(event))
    days = body["days"]
    reason = body["reason"]

    patient = _get_patient(patient_id)
    linked = linked_patient_ids(claims, _role_assignments)
    enforce_patient_access(claims, patient, linked_ids=linked)

    if patient.get("status") != "active":
        raise ApiError(
            code="INVALID_STATE",
            message=f"Cannot pause notifications for a {patient.get('status')} patient",
            status=409,
            details={"currentStatus": patient.get("status")},
        )

    until = compute_until_epoch(days)
    now_epoch = _now_epoch()
    new_pause = {
        "until": until,
        "reason": reason,
        "pausedAt": now_epoch,
        "pausedBy": claims["userId"],
    }
    before_pause = patient.get("notificationsPaused")

    try:
        _patients.update_item(
            Key={"patientId": patient_id},
            UpdateExpression="SET notificationsPaused = :p",
            ConditionExpression="#status = :active",
            ExpressionAttributeNames={"#status": "status"},
            ExpressionAttributeValues={":p": new_pause, ":active": "active"},
        )
    except ClientError as exc:
        if exc.response["Error"]["Code"] == "ConditionalCheckFailedException":
            raise ApiError(
                code="INVALID_STATE",
                message="Patient discharged mid-pause; refresh and retry",
                status=409,
            )
        raise

    actor = _actor(claims)
    emit_audit(
        event=AUDIT_PATIENT_NOTIFICATIONS_PAUSE,
        actor=actor,
        subject={
            "patientId": patient_id,
            "clientId": patient["clientId"],
            "facilityId": patient.get("facilityId"),
            "censusId": patient.get("censusId"),
        },
        action="update",
        before={"notificationsPaused": before_pause},
        after={"notificationsPaused": new_pause},
        extra={"days": days, "reason": reason},
        request_id=_request_id(event),
    )

    return ok_response({
        "notificationsPaused": {
            **new_pause,
            "daysRemaining": days_remaining({"notificationsPaused": new_pause}),
        }
    })


# ── DELETE /api/v1/patients/{id}/notifications/pause ──────────────────


def _action_resume_notifications(
    event: dict[str, Any], claims: dict[str, Any], patient_id: str
) -> dict[str, Any]:
    """DELETE /api/v1/patients/{id}/notifications/pause — manual unpause."""
    require_role(
        claims,
        "caregiver", "facility_admin", "client_admin", "household_owner", "internal_admin",
    )

    patient = _get_patient(patient_id)
    linked = linked_patient_ids(claims, _role_assignments)
    enforce_patient_access(claims, patient, linked_ids=linked)

    before_pause = patient.get("notificationsPaused")
    if not before_pause:
        raise ApiError(
            code="NOT_CURRENTLY_PAUSED",
            message="Patient is not currently paused",
            status=409,
        )

    try:
        _patients.update_item(
            Key={"patientId": patient_id},
            UpdateExpression="REMOVE notificationsPaused",
            ConditionExpression="attribute_exists(notificationsPaused)",
        )
    except ClientError as exc:
        if exc.response["Error"]["Code"] == "ConditionalCheckFailedException":
            raise ApiError(
                code="NOT_CURRENTLY_PAUSED",
                message="Patient is not currently paused (raced with auto-resume?)",
                status=409,
            )
        raise

    actor = _actor(claims)
    emit_audit(
        event=AUDIT_PATIENT_NOTIFICATIONS_RESUME_MANUAL,
        actor=actor,
        subject={
            "patientId": patient_id,
            "clientId": patient["clientId"],
            "facilityId": patient.get("facilityId"),
            "censusId": patient.get("censusId"),
        },
        action="update",
        before={"notificationsPaused": before_pause},
        after={"notificationsPaused": None},
        request_id=_request_id(event),
    )

    return ok_response({"notificationsPaused": None})


# ── PATCH /api/v1/patients/{id}/care-note ─────────────────────────────


def _action_update_care_note(
    event: dict[str, Any], claims: dict[str, Any], patient_id: str
) -> dict[str, Any]:
    """
    PATCH /api/v1/patients/{id}/care-note

    Empty text clears the existing note. Non-empty text overwrites.
    Actor's displayName is denormalized onto the row at write time
    (spec D5) so reads don't pay an extra Users.GetItem.
    """
    require_role(
        claims,
        "caregiver", "facility_admin", "client_admin", "household_owner", "internal_admin",
    )

    body = validate_care_note_body(_parse_body(event))
    text = body["text"]

    patient = _get_patient(patient_id)
    linked = linked_patient_ids(claims, _role_assignments)
    enforce_patient_access(claims, patient, linked_ids=linked)

    if patient.get("status") != "active":
        raise ApiError(
            code="INVALID_STATE",
            message=f"Cannot edit care note on a {patient.get('status')} patient",
            status=409,
            details={"currentStatus": patient.get("status")},
        )

    before_note = patient.get("careNote")
    actor_display_name = (
        _get_user_display_name(claims["userId"])
        or claims.get("email", "")
    )
    now_iso = _now_iso()

    is_clear = text.strip() == ""
    if is_clear:
        # Empty/whitespace text means clear the note.
        try:
            _patients.update_item(
                Key={"patientId": patient_id},
                UpdateExpression="REMOVE careNote",
                ConditionExpression="#status = :active",
                ExpressionAttributeNames={"#status": "status"},
                ExpressionAttributeValues={":active": "active"},
            )
        except ClientError as exc:
            if exc.response["Error"]["Code"] == "ConditionalCheckFailedException":
                raise ApiError(
                    code="INVALID_STATE",
                    message="Patient discharged mid-update; refresh and retry",
                    status=409,
                )
            raise
        new_note = None
    else:
        new_note = {
            "text": text,
            "updatedBy": claims["userId"],
            "updatedByName": actor_display_name,
            "updatedAt": now_iso,
        }
        try:
            _patients.update_item(
                Key={"patientId": patient_id},
                UpdateExpression="SET careNote = :note",
                ConditionExpression="#status = :active",
                ExpressionAttributeNames={"#status": "status"},
                ExpressionAttributeValues={":note": new_note, ":active": "active"},
            )
        except ClientError as exc:
            if exc.response["Error"]["Code"] == "ConditionalCheckFailedException":
                raise ApiError(
                    code="INVALID_STATE",
                    message="Patient discharged mid-update; refresh and retry",
                    status=409,
                )
            raise

    actor = _actor(claims)
    emit_audit(
        event=AUDIT_PATIENT_CARE_NOTE_UPDATE,
        actor=actor,
        subject={
            "patientId": patient_id,
            "clientId": patient["clientId"],
            "facilityId": patient.get("facilityId"),
            "censusId": patient.get("censusId"),
        },
        action="update",
        before={"careNote": before_note},
        after={"careNote": new_note},
        request_id=_request_id(event),
    )

    return ok_response({"careNote": new_note})


# ── Route dispatcher ──────────────────────────────────────────────────


def _route(api_event: dict[str, Any]) -> tuple[str, dict[str, str]]:
    rc = api_event.get("requestContext", {}) or {}
    http = rc.get("http", {}) or {}
    method = (http.get("method") or "").upper()
    route_key = api_event.get("routeKey", "")
    path_params = api_event.get("pathParameters") or {}

    table = {
        ("POST", "POST /api/v1/patients"): "create_patient",
        ("PATCH", "PATCH /api/v1/patients/{id}"): "update_patient",
        ("POST", "POST /api/v1/patients/{id}/discharge"): "discharge_patient",
        ("POST", "POST /api/v1/patients/{id}/resume"): "resume_patient",
        ("POST", "POST /api/v1/patients/{id}/notifications/pause"): "pause_notifications",
        ("DELETE", "DELETE /api/v1/patients/{id}/notifications/pause"): "resume_notifications",
        ("PATCH", "PATCH /api/v1/patients/{id}/care-note"): "update_care_note",
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
    Entry point. Dispatches to action handlers. Each action emits its own
    audit event(s) on success. ApiError is caught here and returned as
    the standard error envelope per 2A-0 L7.
    """
    claims = extract_claims(api_event)
    try:
        require_authenticated(claims)
        # Phase 2A-0 Q8 (amended 2026-05-24): app-layer 4-hr absolute cap
        # for internal_* sessions. No-op for customer roles. patient-mgmt
        # uses explicit emit_audit calls (not @audit_middleware), so the
        # middleware-wired call never reaches this handler.
        enforce_internal_session_age(claims)
        action, params = _route(api_event)
        patient_id = params.get("id", "")

        if action == "create_patient":
            return _action_create_patient(api_event, claims)
        if action == "update_patient":
            return _action_update_patient(api_event, claims, patient_id)
        if action == "discharge_patient":
            return _action_discharge_patient(api_event, claims, patient_id)
        if action == "resume_patient":
            return _action_resume_patient(api_event, claims, patient_id)
        if action == "pause_notifications":
            return _action_pause_notifications(api_event, claims, patient_id)
        if action == "resume_notifications":
            return _action_resume_notifications(api_event, claims, patient_id)
        if action == "update_care_note":
            return _action_update_care_note(api_event, claims, patient_id)

        raise ApiError(code="NOT_FOUND", message=f"Unrouted action {action}", status=404)
    except ApiError as exc:
        # `error_message` (not `message`) — Powertools Logger reserves
        # `message` for the log line itself.
        logger.warning(
            "patient_mgmt_error",
            extra={"code": exc.code, "status": exc.status, "error_message": exc.message},
        )
        return error_response(exc.code, exc.message, exc.status, exc.details)

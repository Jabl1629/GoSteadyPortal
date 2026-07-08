"""
D2C claim + public setup-lookup Lambda — GoSteady D2C Phase 1.

Two routes on one Lambda:

  POST /api/v1/claim                      (D2C-JWT authenticated)
      Bootstrap-on-claim: a just-signed-up walker user claims a device.
      Atomically creates their solo household (Organizations) + Patient
      (isWalkerUser) + RoleAssignments(household_owner, isWalkerUser),
      then runs the inline provision chain (device-side 3-step write +
      activate cmd + Shadow desired.activated_at). Idempotent on re-claim.

  GET  /api/v1/public/walkers/{walkerId}  (UNAUTHENTICATED)
      Landing-page lookup for the QR /setup flow. Returns one of
      {unclaimed | claimed | decommissioned | unknown} + a masked owner
      email on the pre-claim-race case. Resolves walkerId→serial server-
      side; the printed GS serial is never exposed (d2c.md L6).

Provision-chain note (Phase 1, Option B):
  The device-side provision logic is INLINED here (`_provision_inline`),
  a deliberate third copy mirroring device-api/handler.py::_action_provision
  and patient-mgmt/handler.py::_provision_inline. Keeps D2C isolated from
  the two deployed handlers — zero regression risk on facility provision.
  Scheduled follow-up: extract _shared/provision.py and consolidate all
  three callers once D2C Phase 1-4 are validated on real hardware
  (d2c-phase1-walker-activation.md §9 item 1).

Reuses _shared: extract_claims, ok/error envelope, emit_audit, get_logger.
Python 3.12 ARM64.
"""
from __future__ import annotations

import json
import os
import uuid
from datetime import datetime, timezone
from typing import Any

import boto3
from botocore.exceptions import ClientError

from _shared.api_authz import extract_claims, require_authenticated
from _shared.api_error import ApiError, error_response, ok_response
from _shared.audit_catalog import (
    AUDIT_DEVICE_ACTIVATION_SENT,
    AUDIT_DEVICE_ASSIGNED,
    AUDIT_DEVICE_CLAIMED,
    AUDIT_DEVICE_PROVISION_ROLLBACK,
)
from _shared.device_types import DEFAULT_TYPE as DEFAULT_DEVICE_TYPE
from _shared.observability import emit_audit, get_logger

logger = get_logger()

# ── Env + AWS clients ─────────────────────────────────────────────────

DEVICES_TABLE = os.environ["DEVICES_TABLE"]
DEVICE_ASSIGNMENTS_TABLE = os.environ["DEVICE_ASSIGNMENTS_TABLE"]
PATIENTS_TABLE = os.environ["PATIENTS_TABLE"]
ORGANIZATIONS_TABLE = os.environ["ORGANIZATIONS_TABLE"]
ROLE_ASSIGNMENTS_TABLE = os.environ["ROLE_ASSIGNMENTS_TABLE"]

_ddb = boto3.resource("dynamodb")
_devices = _ddb.Table(DEVICES_TABLE)
_assignments = _ddb.Table(DEVICE_ASSIGNMENTS_TABLE)
_patients = _ddb.Table(PATIENTS_TABLE)
_orgs = _ddb.Table(ORGANIZATIONS_TABLE)
_roles = _ddb.Table(ROLE_ASSIGNMENTS_TABLE)

# IoT data-plane client for activate-cmd publish + Shadow writes.
iot_data = boto3.client("iot-data")

STATE_READY = "ready_to_provision"
STATE_DECOMMISSIONED = "decommissioned"

# D2C-specific audit event names (literals — not in the shared catalog,
# which the facility handlers import; keeping them local avoids touching
# a shared module for a Phase-1 feature).
AUDIT_D2C_HOUSEHOLD_CREATED = "d2c.household_created"
AUDIT_D2C_DEVICE_CLAIMED = "d2c.device_claimed"


# ── Router ─────────────────────────────────────────────────────────────

def handler(event: dict[str, Any], context: Any) -> dict[str, Any]:  # noqa: ARG001
    route = event.get("routeKey", "")
    try:
        if route == "POST /api/v1/claim":
            return _claim(event)
        if route == "GET /api/v1/public/walkers/{walkerId}":
            return _public_lookup(event)
        raise ApiError(code="NOT_FOUND", message=f"Unknown route {route}", status=404)
    except ApiError as e:
        return error_response(e.code, e.message, e.status, e.details)


# ── POST /claim ────────────────────────────────────────────────────────

def _claim(event: dict[str, Any]) -> dict[str, Any]:
    claims = extract_claims(event)
    require_authenticated(claims)
    sub = claims["userId"]
    body = _parse_body(event)
    walker_id = (body.get("walkerId") or "").strip()
    if not walker_id:
        raise ApiError(code="INVALID_REQUEST", message="walkerId required", status=400)

    device = _device_by_walker_id(walker_id)
    if not device:
        raise ApiError(code="DEVICE_NOT_FOUND", message="Device not found", status=404)
    serial = device["serialNumber"]
    status = device.get("status", STATE_READY)

    client_id = f"dtc_{sub}"

    # Idempotent: if this user already owns it, return current patient.
    if device.get("owningClientId") == client_id:
        existing = _patient_for_client(client_id)
        if existing:
            return ok_response({"patient": _patient_view(existing), "alreadyClaimed": True})

    if status == STATE_DECOMMISSIONED:
        raise ApiError(code="DEVICE_DECOMMISSIONED",
                       message="This device is no longer active", status=409)
    if status != STATE_READY:
        # Owned by someone else / mid-cycle → pre-claim race.
        raise ApiError(code="DEVICE_UNAVAILABLE",
                       message="This device is already set up", status=409)

    display_name = (body.get("displayName") or claims.get("raw", {}).get("name")
                    or "Walker user").strip()

    facility_id = f"fac_{sub[:12]}"
    census_id = f"cen_{sub[:12]}"
    actor = {"userId": sub, "role": "household_owner", "clientId": client_id}
    req_id = _request_id(event)

    # 1. Household (Organizations): client + synthetic facility + census.
    _ensure_household(client_id, facility_id, census_id, display_name)

    # 2. Patient row (walker user).
    patient_id = f"pat_d2c_{uuid.uuid4().hex[:16]}"
    now_iso = _now_iso()
    patient_item = {
        "patientId": patient_id,
        "clientId": client_id,
        "facilityId": facility_id,
        "censusId": census_id,
        "displayName": display_name,
        "status": "active",
        # by-client-status + by-census-status GSI sort key. Sparse GSI:
        # without this composite attribute the patient row is INVISIBLE to
        # both indexes (breaks /me/patients reads + idempotent re-claim).
        # MUST be `<status>_<patientId>` (underscore) to match the readers'
        # `begins_with("active_")` filter (queries.py) + patient-mgmt's create
        # shape — the prior `active#` (hash) hid every D2C patient from
        # /me/patients, which is exactly how the D2C dashboard finds its
        # patient (§C41.3 / DT-4 WS4 fix, 2026-07-08).
        "status_patientId": f"active_{patient_id}",
        "isWalkerUser": True,
        "cognitoUserId": sub,
        "createdAt": now_iso,
        "createdBy": sub,
    }
    _patients.put_item(Item=patient_item)

    # 3. RoleAssignments row (Admin + walker user of own household).
    # DynamoDB rejects EMPTY string/number sets ("An ... set may not be
    # empty"), so scopedFacilityIds / scopedCensusIds are OMITTED rather
    # than written as empty sets. Absent = unrestricted within the
    # household scope — exactly right for a solo D2C Admin, and the
    # facility handlers treat a missing scope attribute the same way.
    # `email` is stored so the pre-claim-race masked-owner hint works.
    _roles.put_item(Item={
        "userId": sub,
        "clientId": client_id,
        "role": "household_owner",
        "role_userId": f"household_owner#{sub}",
        "isWalkerUser": True,
        "email": claims.get("email", ""),
        "validFrom": now_iso,
        "assignedBy": sub,
    })

    # 4. Provision the device (inline chain). On failure, roll back the
    #    patient row so a retry starts clean (household + roleassignment
    #    are idempotent so they're safe to leave).
    try:
        _provision_inline(
            serial=serial,
            patient_id=patient_id,
            client_id=client_id,
            facility_id=facility_id,
            census_id=census_id,
            actor=actor,
            device=device,
        )
    except ApiError:
        try:
            _patients.delete_item(Key={"patientId": patient_id})
        except ClientError:
            logger.exception("rollback_patient_delete_failed",
                             extra={"patientId": patient_id})
        raise

    emit_audit(event=AUDIT_D2C_HOUSEHOLD_CREATED, actor=actor,
               subject={"clientId": client_id, "patientId": patient_id},
               action="create", request_id=req_id)
    emit_audit(event=AUDIT_D2C_DEVICE_CLAIMED, actor=actor,
               subject={"serialNumber": serial, "patientId": patient_id, "clientId": client_id},
               action="create", after={"walkerId": walker_id}, request_id=req_id)

    return ok_response({"patient": _patient_view(patient_item), "alreadyClaimed": False},
                       status=201)


# ── GET /public/walkers/{walkerId} ─────────────────────────────────────

def _public_lookup(event: dict[str, Any]) -> dict[str, Any]:
    walker_id = (event.get("pathParameters") or {}).get("walkerId", "")
    device = _device_by_walker_id(walker_id)
    if not device:
        # Don't 404-leak existence to an unauth caller; neutral "unknown".
        return ok_response({"status": "unknown"})
    # DT-4 WS4: expose deviceType so the /setup landing renders device-
    # appropriate copy (walker cap vs rollator). Product type, not identity —
    # safe on this unauthenticated endpoint. Null-in-registry → walker_cap (D9).
    device_type = device.get("deviceType") or DEFAULT_DEVICE_TYPE
    status = device.get("status", STATE_READY)
    if status == STATE_DECOMMISSIONED:
        return ok_response({"status": "decommissioned", "deviceType": device_type})
    if status == STATE_READY and not device.get("owningClientId"):
        return ok_response({"status": "unclaimed", "deviceType": device_type})
    return ok_response(
        {
            "status": "claimed",
            "deviceType": device_type,
            "ownerMasked": _masked_owner(device),
        }
    )


# ── Inline provision chain (Option B — mirrors device-api/patient-mgmt) ─

def _provision_inline(
    *,
    serial: str,
    patient_id: str,
    client_id: str,
    facility_id: str,
    census_id: str,
    actor: dict[str, Any],
    device: dict[str, Any],
) -> dict[str, Any]:
    """3-step provision with rollback. Returns {cmd_id, assigned_at}.

    Duplicated from device-api._action_provision / patient-mgmt.
    _provision_inline by design (d2c-phase1 §9 Option B). Caller rolls
    back the patient row if this raises.
    """
    is_first_provision = not device.get("owningClientId")
    cmd_id = f"act_{uuid.uuid4()}"
    now_iso = _now_iso()

    # Step 1a: ensure outstandingActivationCmds map exists.
    _devices.update_item(
        Key={"serialNumber": serial},
        UpdateExpression="SET outstandingActivationCmds = if_not_exists(outstandingActivationCmds, :empty)",
        ExpressionAttributeValues={":empty": {}},
    )

    # Step 1b: conditional update on Device Registry (race guard).
    set_parts = [
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
        set_parts.extend(["owningClientId = :oc", "owningFacilityId = :of"])
        attr_values[":oc"] = client_id
        attr_values[":of"] = facility_id

    try:
        _devices.update_item(
            Key={"serialNumber": serial},
            UpdateExpression="SET " + ", ".join(set_parts),
            ConditionExpression="#status = :ready",
            ExpressionAttributeNames=attr_names,
            ExpressionAttributeValues=attr_values,
        )
    except ClientError as exc:
        if exc.response["Error"]["Code"] == "ConditionalCheckFailedException":
            fresh = _devices.get_item(Key={"serialNumber": serial}).get("Item") or {}
            raise ApiError(
                code="DEVICE_UNAVAILABLE",
                message="Device just claimed by another account — refresh and try again",
                status=409,
                details={"currentStatus": fresh.get("status")},
            )
        raise

    # Step 2: DeviceAssignments row.
    try:
        _assignments.put_item(Item={
            "serialNumber": serial,
            "assignedAt": now_iso,
            "patientId": patient_id,
            "clientId": client_id,
            "facilityId": facility_id,
            "censusId": census_id,
            # DT-0 D1: type snapshot from the registry item (caller fetched
            # it for the claim-state check); absent = walker_cap.
            "deviceType": device.get("deviceType") or DEFAULT_DEVICE_TYPE,
            "validFrom": now_iso,
            "assignedBy": actor["userId"],
        })
    except ClientError:
        _rollback_device_step1(serial, cmd_id, is_first_provision)
        emit_audit(event=AUDIT_DEVICE_PROVISION_ROLLBACK, actor=actor,
                   subject={"serialNumber": serial, "patientId": patient_id, "clientId": client_id},
                   action="create", extra={"reason": "assignments_put_failed", "cmd_id": cmd_id})
        raise ApiError(code="PROVISION_FAILED",
                       message="Could not record device assignment; retry", status=500)

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
        emit_audit(event=AUDIT_DEVICE_PROVISION_ROLLBACK, actor=actor,
                   subject={"serialNumber": serial, "patientId": patient_id, "clientId": client_id},
                   action="create", extra={"reason": "iot_publish_failed", "cmd_id": cmd_id,
                                           "iot_error": str(exc)})
        raise ApiError(code="PROVISION_FAILED",
                       message="Could not publish activate command; retry", status=500)

    # Device-side success audits (matches device-api emission shape).
    subject = {"serialNumber": serial, "patientId": patient_id,
               "clientId": client_id, "facilityId": facility_id}
    if is_first_provision:
        emit_audit(event=AUDIT_DEVICE_CLAIMED, actor=actor, subject=subject, action="update",
                   extra={"owningClientId": client_id, "owningFacilityId": facility_id})
    emit_audit(event=AUDIT_DEVICE_ASSIGNED, actor=actor, subject=subject, action="create",
               after={"validFrom": now_iso})
    emit_audit(event=AUDIT_DEVICE_ACTIVATION_SENT, actor=actor, subject=subject, action="create",
               extra={"cmd_id": cmd_id, "topic": f"gs/{serial}/cmd"})
    return {"cmd_id": cmd_id, "assigned_at": now_iso}


def _rollback_device_step1(serial: str, cmd_id: str, was_first_provision: bool) -> None:
    """Reverse the Devices conditional update from provision step 1b."""
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


# ── helpers ────────────────────────────────────────────────────────────

def _device_by_walker_id(walker_id: str) -> dict[str, Any] | None:
    """Resolve opaque walkerId → Device Registry row via the by-walker-id GSI."""
    if not walker_id:
        return None
    res = _devices.query(
        IndexName="by-walker-id",
        KeyConditionExpression="walkerId = :w",
        ExpressionAttributeValues={":w": walker_id},
        Limit=1,
    )
    items = res.get("Items", [])
    return items[0] if items else None


def _ensure_household(client_id: str, facility_id: str, census_id: str, name: str) -> None:
    now = _now_iso()
    if not _org_exists(client_id, "META#client"):
        _orgs.put_item(Item={"clientId": client_id, "sk": "META#client", "type": "client",
                       "displayName": f"{name}'s household", "status": "active",
                       "createdAt": now})
    if not _org_exists(client_id, f"facility#{facility_id}"):
        _orgs.put_item(Item={"clientId": client_id, "sk": f"facility#{facility_id}",
                       "type": "facility", "parentId": client_id, "displayName": "Home",
                       "status": "active", "timezone": "UTC", "createdAt": now})
    census_sk = f"facility#{facility_id}#census#{census_id}"
    if not _org_exists(client_id, census_sk):
        _orgs.put_item(Item={"clientId": client_id, "sk": census_sk, "type": "census",
                       "parentId": facility_id, "displayName": "Home", "status": "active",
                       "createdAt": now})


def _org_exists(client_id: str, sk: str) -> bool:
    return "Item" in _orgs.get_item(Key={"clientId": client_id, "sk": sk})


def _patient_for_client(client_id: str) -> dict[str, Any] | None:
    res = _patients.query(
        IndexName="by-client-status",
        KeyConditionExpression="clientId = :c",
        ExpressionAttributeValues={":c": client_id},
        Limit=1,
    )
    items = res.get("Items", [])
    return items[0] if items else None


def _masked_owner(device: dict[str, Any]) -> str:
    client_id = device.get("owningClientId", "")
    if not client_id.startswith("dtc_"):
        return "another account"
    sub = client_id[len("dtc_"):]
    try:
        row = _roles.get_item(Key={"userId": sub}).get("Item")
    except ClientError:
        row = None
    email = (row or {}).get("email", "")
    return _mask_email(email) if email else "another account"


def _mask_email(email: str) -> str:
    if "@" not in email:
        return "another account"
    local, domain = email.split("@", 1)
    head = local[0] if local else "•"
    return f"{head}•••@{domain}"


def _patient_view(p: dict[str, Any]) -> dict[str, Any]:
    return {
        "patientId": p.get("patientId"),
        "displayName": p.get("displayName"),
        "status": p.get("status"),
        "clientId": p.get("clientId"),
        "facilityId": p.get("facilityId"),
        "censusId": p.get("censusId"),
        "isWalkerUser": bool(p.get("isWalkerUser")),
    }


def _parse_body(event: dict[str, Any]) -> dict[str, Any]:
    raw = event.get("body") or "{}"
    try:
        return json.loads(raw)
    except (ValueError, TypeError):
        raise ApiError(code="INVALID_REQUEST", message="Body must be valid JSON", status=400)


def _request_id(event: dict[str, Any]) -> str:
    return (event.get("requestContext") or {}).get("requestId", "")


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")

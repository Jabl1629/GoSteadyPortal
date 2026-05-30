"""
D2C claim + public setup-lookup Lambda — GoSteady D2C Phase 1.

Two routes on one Lambda:

  POST /api/v1/claim                      (D2C-JWT authenticated)
      Bootstrap-on-claim: a just-signed-up walker user claims a device.
      Atomically creates their solo household (Organizations) + Patient
      (isWalkerUser) + RoleAssignments(household_owner, isWalkerUser),
      then provisions the device via the shared _shared.provision helper
      (reuses 2A-DL's activate-cmd + Shadow path verbatim).

  GET  /api/v1/public/walkers/{walkerId}  (UNAUTHENTICATED)
      Landing-page lookup for the QR /setup flow. Returns one of
      {unclaimed | claimed | decommissioned} + a masked owner email on
      the pre-claim-race case. Resolves walkerId→serial server-side; the
      printed GS serial is never exposed (d2c.md L6).

Reuses _shared: provision_device, extract_claims, ok/error envelope,
emit_audit. Python 3.12 ARM64.
"""
from __future__ import annotations

import os
import uuid
from typing import Any

import boto3
from botocore.exceptions import ClientError

from _shared.api_authz import extract_claims
from _shared.api_error import ApiError, error_response, ok_response
from _shared.observability import emit_audit, get_logger
from _shared.provision import provision_device, ProvisionError

logger = get_logger("d2c-claim")

_ddb = boto3.resource("dynamodb")
_devices = _ddb.Table(os.environ["DEVICES_TABLE"])
_patients = _ddb.Table(os.environ["PATIENTS_TABLE"])
_orgs = _ddb.Table(os.environ["ORGANIZATIONS_TABLE"])
_roles = _ddb.Table(os.environ["ROLE_ASSIGNMENTS_TABLE"])

STATE_READY = "ready_to_provision"
STATE_DECOMMISSIONED = "decommissioned"


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
        return error_response(e)
    except ProvisionError as e:
        return error_response(ApiError(code=e.code, message=e.message, status=e.status))


# ── POST /claim ────────────────────────────────────────────────────────

def _claim(event: dict[str, Any]) -> dict[str, Any]:
    claims = extract_claims(event)
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

    display_name = (body.get("displayName") or claims.get("name") or "Walker user").strip()

    # 1. Household (Organizations): client + synthetic facility + census.
    facility_id = f"fac_{sub[:12]}"
    census_id = f"cen_{sub[:12]}"
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
        "isWalkerUser": True,
        "cognitoUserId": sub,
        "createdAt": now_iso,
        "createdBy": sub,
    }
    _patients.put_item(Item=patient_item)

    # 3. RoleAssignments row (Admin + walker user of own household).
    _roles.put_item(Item={
        "userId": sub,
        "clientId": client_id,
        "role": "household_owner",
        "role_userId": f"household_owner#{sub}",
        "isWalkerUser": True,
        "scopedFacilityIds": set(),
        "scopedCensusIds": set(),
        "validFrom": now_iso,
        "assignedBy": sub,
    })

    # 4. Provision the device — reuse the shared 2A-DL path (claims
    #    ownership, writes assignment, publishes activate cmd + Shadow).
    result = provision_device(
        serial=serial,
        patient_id=patient_id,
        client_id=client_id,
        facility_id=facility_id,
        census_id=census_id,
        actor_user_id=sub,
    )

    emit_audit(event="d2c.household_created", actor={"userId": sub, "role": "household_owner",
              "clientId": client_id}, subject={"clientId": client_id, "patientId": patient_id},
              action="create", request_id=_request_id(event))
    emit_audit(event="d2c.device_claimed", actor={"userId": sub, "role": "household_owner",
              "clientId": client_id}, subject={"serial": serial, "patientId": patient_id},
              action="create", after={"walkerId": walker_id, "cmdId": result.get("cmdId")},
              request_id=_request_id(event))

    return ok_response({"patient": _patient_view(patient_item), "alreadyClaimed": False})


# ── GET /public/walkers/{walkerId} ─────────────────────────────────────

def _public_lookup(event: dict[str, Any]) -> dict[str, Any]:
    walker_id = (event.get("pathParameters") or {}).get("walkerId", "")
    device = _device_by_walker_id(walker_id)
    if not device:
        # Don't 404-leak existence to an unauth caller; present as unclaimed-
        # unknown so the landing page shows a neutral "check the code" state.
        return ok_response({"status": "unknown"})
    status = device.get("status", STATE_READY)
    if status == STATE_DECOMMISSIONED:
        return ok_response({"status": "decommissioned"})
    if status == STATE_READY and not device.get("owningClientId"):
        return ok_response({"status": "unclaimed"})
    # Claimed (or mid-cycle) — masked owner hint for the pre-claim race.
    return ok_response({"status": "claimed", "ownerMasked": _masked_owner(device)})


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
    # client META — only if absent (idempotent re-claim safety).
    _orgs.put_item(
        Item={"clientId": client_id, "sk": "META#client", "type": "client",
              "displayName": f"{name}'s household", "status": "active", "createdAt": now},
        ConditionExpression="attribute_not_exists(clientId)",
    ) if not _org_exists(client_id, "META#client") else None
    if not _org_exists(client_id, f"facility#{facility_id}"):
        _orgs.put_item(Item={"clientId": client_id, "sk": f"facility#{facility_id}",
                       "type": "facility", "parentId": client_id, "displayName": "Home",
                       "status": "active", "createdAt": now})
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
    # Best-effort: look up the owning household's primary user email.
    # For Phase 1 the owner is the walker user; we mask their email.
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
    import json
    raw = event.get("body") or "{}"
    try:
        return json.loads(raw)
    except (ValueError, TypeError):
        raise ApiError(code="INVALID_REQUEST", message="Body must be valid JSON", status=400)


def _request_id(event: dict[str, Any]) -> str:
    return (event.get("requestContext") or {}).get("requestId", "")


def _now_iso() -> str:
    # provision.py owns wall-clock for the device row; this is for org/patient
    # createdAt only. Imported lazily to keep the cold-start path lean.
    from datetime import datetime, timezone
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")

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
import time
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
from _shared.claim_binding import (
    PhoneFormatError,
    get_pepper,
    hmac_phone,
    mask_phone,
    normalize_e164,
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

# Cognito for the QR re-login broker (d2c-qr-relogin): the backend initiates +
# completes the D2C pool's SMS-OTP CUSTOM_AUTH so the setup landing can text a
# login code to a number it only knows as a mask — the full phone never crosses
# the wire until the caller proves possession of the code. The custom-auth
# Lambda (SMS send) is unchanged.
cognito_idp = boto3.client("cognito-idp")
D2C_APP_CLIENT_ID = os.environ.get("D2C_APP_CLIENT_ID", "")
# Per-device cooldown between login-code sends — throttles the SMS-to-owner
# spam vector inherent to a public "text a code" button on a scanned QR.
LOGIN_CODE_COOLDOWN_S = 30

STATE_READY = "ready_to_provision"
STATE_DECOMMISSIONED = "decommissioned"

# D2C-specific audit event names (literals — not in the shared catalog,
# which the facility handlers import; keeping them local avoids touching
# a shared module for a Phase-1 feature).
AUDIT_D2C_HOUSEHOLD_CREATED = "d2c.household_created"
AUDIT_D2C_DEVICE_CLAIMED = "d2c.device_claimed"
# Claim-binding rejections (spec §7): count-only, never the raw phone.
AUDIT_D2C_CLAIM_REJECTED_PHONE_MISMATCH = "d2c.claim_rejected_phone_mismatch"
AUDIT_D2C_CLAIM_REJECTED_DEVICE_OWNED = "d2c.claim_rejected_device_owned"
# Care Circle guard (d2c-care-circle.md §5.6): a family_viewer's claim must
# not hijack the household they're a member of.
AUDIT_D2C_CLAIM_REJECTED_MEMBER = "d2c.claim_rejected_member_account"
# User-agreement acknowledgment recorded at setup (d2c-user-agreement.md).
AUDIT_D2C_AGREEMENT_ACKNOWLEDGED = "d2c.agreement_acknowledged"
# QR re-login (d2c-qr-relogin) — masked, never the raw phone.
AUDIT_D2C_LOGIN_CODE_SENT = "d2c.login_code_sent"
AUDIT_D2C_LOGIN_CODE_VERIFIED = "d2c.login_code_verified"

# Pure claim helpers (household anchor + identity split + contact masking) live
# in claim_logic.py so they're unit-testable without boto3/powertools.
from claim_logic import (  # noqa: E402
    build_login_recipients,
    mask_contact,
    resolve_household,
    resolve_identity,
)


# ── Router ─────────────────────────────────────────────────────────────

def handler(event: dict[str, Any], context: Any) -> dict[str, Any]:  # noqa: ARG001
    route = event.get("routeKey", "")
    try:
        if route == "POST /api/v1/claim":
            return _claim(event)
        if route == "GET /api/v1/public/walkers/{walkerId}":
            return _public_lookup(event)
        if route == "GET /api/v1/public/walkers/{walkerId}/recipients":
            return _login_recipients(event)
        if route == "POST /api/v1/public/walkers/{walkerId}/login-code":
            return _send_login_code(event)
        if route == "POST /api/v1/public/walkers/{walkerId}/login-code/verify":
            return _verify_login_code(event)
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

    # Resolve THIS user's household. Anchored on a stable householdId, NOT the
    # Cognito sub, so ownership can transfer / gain members / include an
    # account-less walker later without a data migration (bake-in #3). A
    # returning user's household comes from their existing RoleAssignments row;
    # a first-time claimer mints a fresh householdId.
    existing_role = _role_for_user(sub)
    client_id, household_id, _is_new = resolve_household(existing_role, sub)

    # Idempotent: if this user's household already owns it, return the patient.
    # (Runs BEFORE the Care Circle guard on purpose — a Member re-scanning
    # their own household's claimed device gets this benign no-write response,
    # not a 409.)
    if device.get("owningClientId") == client_id:
        existing = _active_patient_for_client(client_id) or _patient_for_client(client_id)
        if existing:
            return ok_response({"patient": _patient_view(existing), "alreadyClaimed": True})

    # Care Circle guard (d2c-care-circle.md §5.6 / D2): a Member's claim must
    # not resolve into the household they merely VIEW — resolve_household
    # returns that household, the §5.7 dedupe would attach the device to ITS
    # patient, and the role-row overwrite below would promote the member to
    # owner of someone else's household. V1 posture: members can't claim;
    # V2's memberships model turns this into "add an owner membership."
    if existing_role and existing_role.get("role") == "family_viewer":
        emit_audit(event=AUDIT_D2C_CLAIM_REJECTED_MEMBER,
                   actor={"userId": sub, "role": "family_viewer",
                          "clientId": client_id},
                   subject={"serialNumber": serial},
                   action="event",
                   request_id=_request_id(event))
        raise ApiError(
            code="MEMBER_CANNOT_CLAIM",
            message=("Your account is part of another Care Circle. "
                     "Contact support to set up your own walker."),
            status=409,
        )

    # §5.2b ownership gate (spec D6): a device owned by ANOTHER household is
    # never claimable, regardless of lifecycle status. The normal post-recycle
    # state is ready_to_provision WITH ownership retained (DL4/L2), so without
    # this gate a missed `release` would let a new household claim into a
    # split-ownership state. Release is mandatory-by-mechanism.
    owning = device.get("owningClientId")
    if owning and owning != client_id:
        emit_audit(event=AUDIT_D2C_CLAIM_REJECTED_DEVICE_OWNED,
                   actor={"userId": sub, "role": "household_owner", "clientId": client_id},
                   subject={"serialNumber": serial},
                   action="event",
                   extra={"currentStatus": status},
                   request_id=_request_id(event))
        raise ApiError(code="DEVICE_OWNED",
                       message="This walker isn't available. Contact support.",
                       status=409)

    if status == STATE_DECOMMISSIONED:
        raise ApiError(code="DEVICE_DECOMMISSIONED",
                       message="This device is no longer active", status=409)
    if status != STATE_READY:
        # Mid-cycle (e.g. discontinued awaiting wipe-ack) → not claimable yet.
        raise ApiError(code="DEVICE_UNAVAILABLE",
                       message="This device is already set up", status=409)

    # §5.2c binding check (spec D11): fail CLOSED. If the device is bound,
    # the caller must present a present-and-VERIFIED phone_number whose
    # peppered HMAC matches. Missing / unverified / malformed / mismatched
    # all return the same neutral 403 (no oracle); audit distinguishes.
    bound_hash = device.get("claimBoundPhone")
    if bound_hash:
        reject_reason = None
        phone = claims.get("phoneNumber") or ""
        if not phone:
            reject_reason = "phone_absent"
        elif not claims.get("phoneNumberVerified"):
            reject_reason = "phone_unverified"
        else:
            try:
                caller_hash = hmac_phone(get_pepper(), normalize_e164(phone))
            except PhoneFormatError:
                reject_reason = "phone_invalid_format"
            else:
                if caller_hash != bound_hash:
                    reject_reason = "phone_mismatch"
        if reject_reason:
            emit_audit(event=AUDIT_D2C_CLAIM_REJECTED_PHONE_MISMATCH,
                       actor={"userId": sub, "role": "household_owner", "clientId": client_id},
                       subject={"serialNumber": serial},
                       action="event",
                       extra={"reason": reject_reason},
                       request_id=_request_id(event))
            raise ApiError(code="CLAIM_PHONE_MISMATCH",
                           message="This walker is reserved for a different phone number.",
                           status=403)

    # Identity split (bake-in #2): owner (this Cognito user) and walker (the
    # Patient) are the same for solo self-claim (default) but MAY differ when a
    # caregiver sets up for someone else. Phase-1 UI does solo only; the data
    # writes support the split so the caregiver flow is additive later.
    owner_name, walker_name, owner_is_walker = resolve_identity(body, claims)
    owner_hint = mask_contact(phone=claims.get("phoneNumber", ""),
                              email=claims.get("email", ""))

    facility_id = f"fac_{household_id[:12]}"
    census_id = f"cen_{household_id[:12]}"
    actor = {"userId": sub, "role": "household_owner", "clientId": client_id}
    req_id = _request_id(event)

    # 1. Household (Organizations): client + synthetic facility + census.
    _ensure_household(client_id, facility_id, census_id, owner_name)

    # 2. Patient row (the walker). §5.7 dedupe (spec T8): a returning user's
    #    household may already hold an ACTIVE walker patient (e.g. they claim
    #    a second device, or an operator skipped the rotation discharge). In
    #    that case REUSE it — never mint a duplicate active patient in the
    #    household (V1 shape: 1 household = 1 active walker patient).
    #    `cognitoUserId` is set ONLY when the owner IS the walker (solo); a
    #    caregiver-owned walker is account-less (the key is omitted —
    #    Patients.cognitoUserId is optional by design).
    now_iso = _now_iso()
    existing_active = _active_patient_for_client(client_id)
    created_patient = existing_active is None
    if existing_active:
        patient_item = existing_active
        patient_id = existing_active["patientId"]
    else:
        patient_id = f"pat_d2c_{uuid.uuid4().hex[:16]}"
        patient_item = {
            "patientId": patient_id,
            "clientId": client_id,
            "facilityId": facility_id,
            "censusId": census_id,
            "displayName": walker_name,
            "status": "active",
            # by-client-status + by-census-status GSI sort key. MUST be
            # `<status>_<patientId>` (underscore) to match the readers'
            # `begins_with("active_")` filter — the DT-4 WS4 fix (§C41.3).
            "status_patientId": f"active_{patient_id}",
            "isWalkerUser": True,
            "createdAt": now_iso,
            "createdBy": sub,
        }
        if owner_is_walker:
            patient_item["cognitoUserId"] = sub
        _patients.put_item(Item=patient_item)

    # 3. RoleAssignments row (household Admin). `isWalkerUser` marks whether
    #    THIS account user is the walker (true=solo, false=caregiver). scoped*
    #    ids are OMITTED (DynamoDB rejects empty sets; absent = unrestricted in
    #    the household). `email`/`phone` back the masked-owner hint (email may
    #    be empty under the phone-first pool).
    # User-agreement acknowledgment (d2c-user-agreement.md): the setup screen
    # gated on the plain-language agreement; the app sends the acknowledged
    # version here. Stamp who acknowledged which version + when on the owner
    # row so it's evidenceable. Absent (older client / bootstrap script) →
    # simply not stamped.
    agreement_version = (body.get("agreementVersion") or "").strip()
    role_item = {
        "userId": sub,
        "clientId": client_id,
        "role": "household_owner",
        "role_userId": f"household_owner#{sub}",
        "isWalkerUser": owner_is_walker,
        # Roster rendering (d2c-care-circle.md §5.4) — owner rows carry a
        # display name like invited-member rows do.
        "displayName": owner_name,
        "email": claims.get("email", ""),
        "phone": claims.get("phoneNumber", ""),
        "validFrom": now_iso,
        "assignedBy": sub,
    }
    if agreement_version:
        role_item["agreementVersion"] = agreement_version
        role_item["agreementAcceptedAt"] = now_iso
    _roles.put_item(Item=role_item)
    if agreement_version:
        emit_audit(event=AUDIT_D2C_AGREEMENT_ACKNOWLEDGED, actor=actor,
                   subject={"clientId": client_id, "userId": sub},
                   action="event",
                   extra={"agreementVersion": agreement_version,
                          "role": "household_owner"},
                   request_id=req_id)

    # 4. Provision the device (inline chain). On failure, roll back the
    #    patient row IF this claim created it (a reused pre-existing active
    #    patient must survive — §5.7); household + roleassignment are
    #    idempotent so they're safe to leave.
    try:
        _provision_inline(
            serial=serial,
            patient_id=patient_id,
            client_id=client_id,
            facility_id=facility_id,
            census_id=census_id,
            actor=actor,
            device=device,
            owner_hint=owner_hint,
        )
    except ApiError:
        if created_patient:
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
    if device.get("owningClientId"):
        # Owned (any lifecycle state) → claimed, with the owner's masked hint.
        return ok_response(
            {
                "status": "claimed",
                "deviceType": device_type,
                "ownerMasked": _masked_owner(device),
            }
        )
    # Unowned + bound → "reserved" (§5.5): the /setup landing renders
    # "Set up this walker for {recipientMask}?" pre-claim. The masked tail
    # is exposed to anyone holding the walkerId — accepted tradeoff (D9).
    if device.get("claimBoundPhone"):
        return ok_response(
            {
                "status": "reserved",
                "deviceType": device_type,
                "recipientMask": device.get("claimBoundPhoneMask") or "",
            }
        )
    # Unowned + unbound. Includes a mid-rotation released-but-still-wiping
    # device (discontinued): render as unclaimed — claim itself still 409s
    # until wipe-ack recycles it to ready. (Previously this fell into the
    # "claimed" branch and served the PRIOR owner's stale hint.)
    return ok_response({"status": "unclaimed", "deviceType": device_type})


# ── QR re-login (d2c-qr-relogin) — get back in from a claimed device's QR ─
#
# The persistent QR on an allocated device is the natural "I forgot the app
# link, get me back in" affordance. These three UNAUTHENTICATED routes let the
# /setup landing text a login code to a household number it only knows as a
# mask, and complete SMS-OTP sign-in, WITHOUT ever exposing the full phone
# until the caller proves possession of the code:
#   GET  .../recipients        → masked household roster (no phone, no sub)
#   POST .../login-code        → resolve + initiate CUSTOM_AUTH → {session, mask}
#   POST .../login-code/verify → respond → {tokens, phone} on success
# The full phone is returned ONLY on a verified code (the caller is then, by
# definition, the holder of that phone).

def _household_for_walker(walker_id: str) -> tuple[dict[str, Any] | None, str]:
    """(device, owningClientId) for a walkerId, or (None, "") / (device, "")
    when unknown/unowned. Neutral on miss — no existence leak."""
    device = _device_by_walker_id(walker_id)
    if not device:
        return None, ""
    return device, device.get("owningClientId") or ""


def _household_members(client_id: str) -> list[dict[str, Any]]:
    """RoleAssignments rows for the household (by-client-role GSI)."""
    res = _roles.query(
        IndexName="by-client-role",
        KeyConditionExpression="clientId = :c",
        ExpressionAttributeValues={":c": client_id},
    )
    return res.get("Items", [])


def _login_recipients(event: dict[str, Any]) -> dict[str, Any]:
    """GET /public/walkers/{walkerId}/recipients — masked login targets."""
    walker_id = (event.get("pathParameters") or {}).get("walkerId", "")
    _device, client_id = _household_for_walker(walker_id)
    if not client_id:
        # Unknown / unclaimed — nothing to sign into. Neutral empty list.
        return ok_response({"recipients": []})
    public, _ = build_login_recipients(
        _household_members(client_id), walker_id, get_pepper()
    )
    return ok_response({"recipients": public})


def _resolve_recipient_phone(walker_id: str, recipient_id: str) -> tuple[str, str]:
    """(phone, clientId) for a recipientId under a walker's household, or
    ("", "") if it doesn't resolve. Recomputes the id→phone map server-side."""
    _device, client_id = _household_for_walker(walker_id)
    if not client_id:
        return "", ""
    _public, id_to_phone = build_login_recipients(
        _household_members(client_id), walker_id, get_pepper()
    )
    return id_to_phone.get(recipient_id, ""), client_id


def _login_cooldown_ok(serial: str) -> bool:
    """Per-device send cooldown (conditional write). False → still cooling."""
    now = int(time.time())
    try:
        _devices.update_item(
            Key={"serialNumber": serial},
            UpdateExpression="SET loginCodeCooldownUntil = :until",
            ConditionExpression=(
                "attribute_not_exists(loginCodeCooldownUntil) "
                "OR loginCodeCooldownUntil < :now"
            ),
            ExpressionAttributeValues={":until": now + LOGIN_CODE_COOLDOWN_S, ":now": now},
        )
        return True
    except ClientError as exc:
        if exc.response["Error"]["Code"] == "ConditionalCheckFailedException":
            return False
        raise


def _send_login_code(event: dict[str, Any]) -> dict[str, Any]:
    """POST /public/walkers/{walkerId}/login-code — SMS a code to a masked
    recipient. Returns an opaque Cognito session + the mask; no phone."""
    walker_id = (event.get("pathParameters") or {}).get("walkerId", "")
    body = _parse_body(event)
    recipient_id = (body.get("recipientId") or "").strip()
    if not recipient_id:
        raise ApiError(code="INVALID_REQUEST", message="recipientId required", status=400)

    device, _client = _household_for_walker(walker_id)
    phone, client_id = _resolve_recipient_phone(walker_id, recipient_id)
    if not phone or not device:
        # Neutral — don't reveal whether the recipient/device exists.
        raise ApiError(code="RECIPIENT_NOT_FOUND",
                       message="That option isn't available.", status=404)

    if not _login_cooldown_ok(device["serialNumber"]):
        raise ApiError(code="TOO_MANY_REQUESTS",
                       message="A code was just sent. Wait a moment and try again.",
                       status=429)

    try:
        resp = cognito_idp.initiate_auth(
            ClientId=D2C_APP_CLIENT_ID,
            AuthFlow="CUSTOM_AUTH",
            AuthParameters={"USERNAME": phone},
        )
    except ClientError as exc:
        logger.warning("login_code_initiate_failed",
                       extra={"error": exc.response.get("Error", {}).get("Code")})
        raise ApiError(code="LOGIN_CODE_FAILED",
                       message="Couldn't send a code right now. Try again.", status=502)

    if resp.get("ChallengeName") != "CUSTOM_CHALLENGE" or not resp.get("Session"):
        raise ApiError(code="LOGIN_CODE_FAILED",
                       message="Couldn't start sign-in. Try again.", status=502)

    emit_audit(event=AUDIT_D2C_LOGIN_CODE_SENT,
               actor={"clientId": client_id},
               subject={"serialNumber": device["serialNumber"], "clientId": client_id},
               action="event", extra={"mask": mask_phone(phone)},
               request_id=_request_id(event))
    return ok_response({"session": resp["Session"], "mask": mask_phone(phone)})


def _verify_login_code(event: dict[str, Any]) -> dict[str, Any]:
    """POST /public/walkers/{walkerId}/login-code/verify — complete SMS-OTP.
    On success returns the session tokens + the phone (the caller just proved
    they hold it) so the app can adopt a normal signed-in session."""
    walker_id = (event.get("pathParameters") or {}).get("walkerId", "")
    body = _parse_body(event)
    recipient_id = (body.get("recipientId") or "").strip()
    session = body.get("session") or ""
    code = (body.get("code") or "").strip()
    if not (recipient_id and session and code):
        raise ApiError(code="INVALID_REQUEST",
                       message="recipientId, session, and code are required", status=400)

    phone, client_id = _resolve_recipient_phone(walker_id, recipient_id)
    if not phone:
        raise ApiError(code="RECIPIENT_NOT_FOUND",
                       message="That option isn't available.", status=404)

    try:
        resp = cognito_idp.respond_to_auth_challenge(
            ClientId=D2C_APP_CLIENT_ID,
            ChallengeName="CUSTOM_CHALLENGE",
            Session=session,
            ChallengeResponses={"USERNAME": phone, "ANSWER": code},
        )
    except ClientError as exc:
        code_name = exc.response.get("Error", {}).get("Code")
        if code_name in ("NotAuthorizedException", "CodeMismatchException"):
            # Out of attempts / session expired — start over.
            raise ApiError(code="LOGIN_CODE_EXPIRED",
                           message="That code didn't work. Request a new one.",
                           status=401)
        logger.warning("login_code_verify_failed", extra={"error": code_name})
        raise ApiError(code="LOGIN_CODE_FAILED",
                       message="Couldn't verify the code. Try again.", status=502)

    auth = resp.get("AuthenticationResult")
    if not auth:
        # Wrong code but attempts remain — Cognito re-issued the challenge.
        new_session = resp.get("Session")
        if new_session:
            return ok_response({"status": "retry", "session": new_session})
        raise ApiError(code="LOGIN_CODE_EXPIRED",
                       message="That code didn't work. Request a new one.", status=401)

    emit_audit(event=AUDIT_D2C_LOGIN_CODE_VERIFIED,
               actor={"clientId": client_id},
               subject={"clientId": client_id},
               action="event", extra={"mask": mask_phone(phone)},
               request_id=_request_id(event))
    return ok_response({
        "status": "ok",
        "idToken": auth["IdToken"],
        "accessToken": auth["AccessToken"],
        # A refresh token is present for a first full auth (not on token refresh).
        "refreshToken": auth.get("RefreshToken", ""),
        "phone": phone,
        "mask": mask_phone(phone),
    })


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
    owner_hint: str = "",
) -> dict[str, Any]:
    """3-step provision with rollback. Returns {cmd_id, assigned_at}.

    Duplicated from device-api._action_provision / patient-mgmt.
    _provision_inline by design (d2c-phase1 §9 Option B). Caller rolls
    back the patient row if this raises.
    """
    is_first_provision = not device.get("owningClientId")
    cmd_id = f"act_{uuid.uuid4()}"
    now_iso = _now_iso()
    # §5.2d (spec D10): the binding clear rides INSIDE the step-1b conditional
    # write (atomic with the ownership snap) and is restored by the rollback,
    # so a step-2/3 failure can never burn the binding into open self-claim.
    prior_binding = (
        (device.get("claimBoundPhone"), device.get("claimBoundPhoneMask"))
        if device.get("claimBoundPhone")
        else None
    )

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
        # ownerHint = already-masked owner contact, read by the unauth public
        # lookup for the pre-claim-race hint (avoids a reverse RoleAssignments
        # lookup — clientId is a householdId now, not the owner's sub).
        set_parts.extend(["owningClientId = :oc", "owningFacilityId = :of", "ownerHint = :oh"])
        attr_values[":oc"] = client_id
        attr_values[":of"] = facility_id
        attr_values[":oh"] = owner_hint

    # The binding this claim was checked against must be UNCHANGED at write
    # time (a concurrent re-bind between check and write must lose, not be
    # silently cleared); an unbound device must still be unbound.
    if prior_binding:
        binding_cond = " AND claimBoundPhone = :boundv"
        attr_values[":boundv"] = prior_binding[0]
    else:
        binding_cond = " AND attribute_not_exists(claimBoundPhone)"

    try:
        _devices.update_item(
            Key={"serialNumber": serial},
            UpdateExpression="SET " + ", ".join(set_parts)
            + " REMOVE claimBoundPhone, claimBoundPhoneMask",
            ConditionExpression="#status = :ready" + binding_cond,
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
        _rollback_device_step1(serial, cmd_id, is_first_provision, prior_binding)
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
        _rollback_device_step1(serial, cmd_id, is_first_provision, prior_binding)
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


def _rollback_device_step1(
    serial: str,
    cmd_id: str,
    was_first_provision: bool,
    prior_binding: tuple[str, str | None] | None = None,
) -> None:
    """Reverse the Devices conditional update from provision step 1b.

    §5.2d (spec D10): step 1b consumed the claim binding atomically, so the
    rollback must RESTORE it — otherwise a step-2/3 failure leaves the device
    unowned AND unbound (silent open self-claim, the exact state the binding
    exists to prevent).
    """
    try:
        set_parts = ["#status = :ready", "lastTransitionAt = :now"]
        remove_parts = ["outstandingActivationCmds.#cid", "currentAssignmentSk"]
        attr_values: dict[str, Any] = {":ready": STATE_READY, ":now": _now_iso()}
        if was_first_provision:
            remove_parts.extend(["owningClientId", "owningFacilityId", "ownerHint"])
        if prior_binding:
            set_parts.append("claimBoundPhone = :bhash")
            attr_values[":bhash"] = prior_binding[0]
            if prior_binding[1]:
                set_parts.append("claimBoundPhoneMask = :bmask")
                attr_values[":bmask"] = prior_binding[1]
        _devices.update_item(
            Key={"serialNumber": serial},
            UpdateExpression="SET " + ", ".join(set_parts) + " REMOVE " + ", ".join(remove_parts),
            ExpressionAttributeNames={"#status": "status", "#cid": cmd_id},
            ExpressionAttributeValues=attr_values,
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


def _role_for_user(sub: str) -> dict[str, Any] | None:
    """The caller's existing RoleAssignments row (PK=userId), or None. Used to
    resolve a returning user's household clientId (see resolve_household)."""
    try:
        return _roles.get_item(Key={"userId": sub}).get("Item")
    except ClientError:
        return None


def _patient_for_client(client_id: str) -> dict[str, Any] | None:
    res = _patients.query(
        IndexName="by-client-status",
        KeyConditionExpression="clientId = :c",
        ExpressionAttributeValues={":c": client_id},
        Limit=1,
    )
    items = res.get("Items", [])
    return items[0] if items else None


def _active_patient_for_client(client_id: str) -> dict[str, Any] | None:
    """The household's ACTIVE walker patient, or None (§5.7 dedupe).

    The by-client-status GSI sort key is `status_patientId`
    (`<status>_<patientId>`), so `begins_with("active_")` selects exactly
    the active rows — same predicate the dashboard readers use (§C41.3).
    """
    res = _patients.query(
        IndexName="by-client-status",
        KeyConditionExpression=(
            "clientId = :c AND begins_with(status_patientId, :ap)"
        ),
        ExpressionAttributeValues={":c": client_id, ":ap": "active_"},
        Limit=1,
    )
    items = res.get("Items", [])
    return items[0] if items else None


def _masked_owner(device: dict[str, Any]) -> str:
    # The already-masked owner hint is written to the device at first provision
    # (see mask_contact). No reverse RoleAssignments lookup — clientId is now a
    # householdId, not the owner's Cognito sub.
    return device.get("ownerHint") or "another account"


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

"""
Care Circle Lambda — D2C invites, membership, roster (d2c-care-circle.md).

Eight routes on one Lambda, all bound to the D2C pool authorizer:

  POST   /api/v1/household/invites                    Admin sends a phone-first invite
  POST   /api/v1/household/invites/{inviteId}/resend  Admin re-sends + re-arms expiry
  DELETE /api/v1/household/invites/{inviteId}         Admin revokes
  GET    /api/v1/household/members                    Roster (any household member)
  PATCH  /api/v1/household/members/{userId}           Admin promote/demote
  DELETE /api/v1/household/members/{userId}           Admin remove, or self = leave
  GET    /api/v1/invites/pending                      Caller's live invites (by phone hash)
  POST   /api/v1/invites/accept                       Verified-phone match → membership

Design anchors (spec section refs):
  • Possession proof = the caller's VERIFIED phone HMAC-matches the invite
    (§5.3 step 1, fail-closed — mirrors claim-binding D11). The /join link
    is a pointer, not a credential.
  • One household per account (L2/D2): accept refuses a caller whose
    RoleAssignments row names a different clientId (ALREADY_IN_HOUSEHOLD).
  • Mutations gate on the caller's CURRENT RoleAssignments row, not the
    token's role claim — demote/remove are effective immediately (same
    instant-revoke posture as linked_patient_ids), not after token refresh.
  • Roster is a derived view over RoleAssignments by-client-role (L3);
    the account-less walker is synthesized from the active Patient (D10).
  • Audit names are local literals (D13), masked contact only.

Reuses _shared: extract_claims, ApiError envelope, emit_audit, claim_binding
(normalize/HMAC/mask/pepper), sms.send_sms. Python 3.12 ARM64.
"""
from __future__ import annotations

import json
import os
from datetime import datetime, timezone
from typing import Any

import boto3
from botocore.exceptions import ClientError

from _shared.api_authz import extract_claims, require_authenticated
from _shared.api_error import ApiError, error_response, ok_response
from _shared.claim_binding import (
    PhoneFormatError,
    get_pepper,
    hmac_phone,
    normalize_e164,
)
from _shared.observability import emit_audit, get_logger
from _shared.sms import SmsSendError, send_sms

logger = get_logger()

# ── Env + AWS clients ─────────────────────────────────────────────────

CARE_INVITES_TABLE = os.environ["CARE_INVITES_TABLE"]
ROLE_ASSIGNMENTS_TABLE = os.environ["ROLE_ASSIGNMENTS_TABLE"]
PATIENTS_TABLE = os.environ["PATIENTS_TABLE"]
ORGANIZATIONS_TABLE = os.environ["ORGANIZATIONS_TABLE"]
D2C_APP_BASE_URL = os.environ.get("D2C_APP_BASE_URL", "https://app.gosteady.co")

_ddb = boto3.resource("dynamodb")
_invites = _ddb.Table(CARE_INVITES_TABLE)
_roles = _ddb.Table(ROLE_ASSIGNMENTS_TABLE)
_patients = _ddb.Table(PATIENTS_TABLE)
_orgs = _ddb.Table(ORGANIZATIONS_TABLE)

# D2C audit event names (local literals — D13; mirrors d2c-claim precedent).
AUDIT_INVITE_SENT = "d2c.invite_sent"
AUDIT_INVITE_RESENT = "d2c.invite_resent"
AUDIT_INVITE_REVOKED = "d2c.invite_revoked"
AUDIT_INVITE_ACCEPTED = "d2c.invite_accepted"
AUDIT_INVITE_ACCEPT_REJECTED = "d2c.invite_accept_rejected"
AUDIT_MEMBER_JOINED = "d2c.member_joined"
AUDIT_MEMBER_JOIN_CONFIRMED = "d2c.member_join_confirmed"  # confirmation SMS sent
AUDIT_MEMBER_ROLE_CHANGED = "d2c.member_role_changed"
AUDIT_MEMBER_REMOVED = "d2c.member_removed"
AUDIT_MEMBER_LEFT = "d2c.member_left"
AUDIT_CARE_CIRCLE_READ = "d2c.care_circle_read"

# Pure helpers (unit-testable without boto3/powertools).
from circle_logic import (  # noqa: E402
    INVITE_STATUS_PENDING,
    INVITE_STATUS_REVOKED,
    MAX_PENDING_INVITES,
    build_invite_item,
    build_member_row,
    confirm_sms_body,
    invite_expiry,
    invite_is_live,
    invite_sms_body,
    iso,
    member_view,
    pending_invite_view,
    synthesized_walker_view,
    validate_invite_input,
)

OWNER = "household_owner"
VIEWER = "family_viewer"


# ── Router ─────────────────────────────────────────────────────────────

def handler(event: dict[str, Any], context: Any) -> dict[str, Any]:  # noqa: ARG001
    claims = extract_claims(event)
    try:
        require_authenticated(claims)
        route = event.get("routeKey", "")
        params = event.get("pathParameters") or {}

        if route == "POST /api/v1/household/invites":
            return _send_invite(event, claims)
        if route == "POST /api/v1/household/invites/{inviteId}/resend":
            return _resend_invite(event, claims, params.get("inviteId", ""))
        if route == "DELETE /api/v1/household/invites/{inviteId}":
            return _revoke_invite(event, claims, params.get("inviteId", ""))
        if route == "GET /api/v1/household/members":
            return _get_members(event, claims)
        if route == "PATCH /api/v1/household/members/{userId}":
            return _set_member_role(event, claims, params.get("userId", ""))
        if route == "DELETE /api/v1/household/members/{userId}":
            return _remove_member(event, claims, params.get("userId", ""))
        if route == "GET /api/v1/invites/pending":
            return _pending_for_caller(event, claims)
        if route == "POST /api/v1/invites/accept":
            return _accept_invite(event, claims)

        raise ApiError(code="NOT_FOUND", message=f"Unknown route {route}", status=404)
    except ApiError as e:
        logger.warning(
            "care_circle_error",
            extra={"code": e.code, "status": e.status, "error_message": e.message},
        )
        return error_response(e.code, e.message, e.status, e.details)


# ── Membership context (DDB-fresh, not token-trusted) ─────────────────

def _membership(claims: dict[str, Any]) -> dict[str, Any] | None:
    """
    The caller's CURRENT RoleAssignments row, validated against the token's
    clientId. Row-vs-token mismatch (removed / re-homed since the token was
    minted) → 403 NOT_A_MEMBER so the client re-runs refreshClaims().

    Returns None for the pre-claim bootstrap case (no row AND the token
    carries the bootstrap default clientId `dtc_{sub}`) — a signed-up user
    who hasn't claimed a device or accepted an invite yet.
    """
    user_id = claims.get("userId", "")
    row = _roles.get_item(Key={"userId": user_id}).get("Item")
    if row:
        if row.get("clientId") != claims.get("clientId"):
            raise ApiError(
                code="NOT_A_MEMBER",
                message="Your membership changed — sign in again.",
                status=403,
            )
        return row
    if claims.get("clientId") == f"dtc_{user_id}":
        return None  # bootstrap default; not a member of anything yet
    raise ApiError(
        code="NOT_A_MEMBER",
        message="Your membership changed — sign in again.",
        status=403,
    )


def _require_admin(claims: dict[str, Any]) -> dict[str, Any] | None:
    """Admin gate for roster mutations — row-authoritative (see module doc)."""
    row = _membership(claims)
    role = row.get("role") if row else OWNER  # bootstrap default is an owner
    if role != OWNER:
        raise ApiError(
            code="INSUFFICIENT_PERMISSIONS",
            message="Only a Care Circle Admin can do this",
            status=403,
        )
    return row


# ── DDB helpers ────────────────────────────────────────────────────────

def _active_patients(client_id: str) -> list[dict[str, Any]]:
    """All ACTIVE patients in the household (by-client-status GSI; the
    `<status>_<patientId>` sort key matches the readers' predicate)."""
    res = _patients.query(
        IndexName="by-client-status",
        KeyConditionExpression=(
            "clientId = :c AND begins_with(status_patientId, :ap)"
        ),
        ExpressionAttributeValues={":c": client_id, ":ap": "active_"},
    )
    return res.get("Items", [])


def _household_name(client_id: str) -> str:
    row = _orgs.get_item(Key={"clientId": client_id, "sk": "META#client"}).get("Item")
    return (row or {}).get("displayName") or "GoSteady household"


def _member_rows(client_id: str) -> list[dict[str, Any]]:
    res = _roles.query(
        IndexName="by-client-role",
        KeyConditionExpression="clientId = :c",
        ExpressionAttributeValues={":c": client_id},
    )
    return res.get("Items", [])


def _owner_count(client_id: str) -> int:
    res = _roles.query(
        IndexName="by-client-role",
        KeyConditionExpression=(
            "clientId = :c AND begins_with(role_userId, :o)"
        ),
        ExpressionAttributeValues={":c": client_id, ":o": f"{OWNER}#"},
        Select="COUNT",
    )
    return int(res.get("Count", 0))


def _household_invites(client_id: str) -> list[dict[str, Any]]:
    res = _invites.query(
        IndexName="by-client",
        KeyConditionExpression="clientId = :c",
        ExpressionAttributeValues={":c": client_id},
    )
    return res.get("Items", [])


def _invite_or_404(invite_id: str, client_id: str) -> dict[str, Any]:
    """Invite scoped to the caller's household — cross-household probes 404."""
    invite = _invites.get_item(Key={"inviteId": invite_id}).get("Item")
    if not invite or invite.get("clientId") != client_id:
        raise ApiError(code="INVITE_NOT_FOUND", message="Invite not found", status=404)
    return invite


def _caller_phone_hash(claims: dict[str, Any]) -> str | None:
    """Peppered HMAC of the caller's VERIFIED phone; None when absent /
    unverified / malformed (callers decide fail-closed behavior)."""
    phone = claims.get("phoneNumber") or ""
    if not phone or not claims.get("phoneNumberVerified"):
        return None
    try:
        return hmac_phone(get_pepper(), normalize_e164(phone))
    except PhoneFormatError:
        return None


def _actor(claims: dict[str, Any]) -> dict[str, Any]:
    return {
        "userId": claims.get("userId", ""),
        "role": claims.get("role", ""),
        "clientId": claims.get("clientId", ""),
    }


def _request_id(event: dict[str, Any]) -> str:
    return (event.get("requestContext") or {}).get("requestId", "")


def _parse_body(event: dict[str, Any]) -> dict[str, Any]:
    raw = event.get("body") or "{}"
    try:
        return json.loads(raw)
    except (ValueError, TypeError):
        raise ApiError(code="INVALID_REQUEST", message="Body must be valid JSON", status=400)


def _now() -> datetime:
    return datetime.now(timezone.utc)


# ── POST /household/invites ────────────────────────────────────────────

def _send_invite(event: dict[str, Any], claims: dict[str, Any]) -> dict[str, Any]:
    caller_row = _require_admin(claims)
    client_id = claims["clientId"]
    body = _parse_body(event)
    validated = validate_invite_input(body)
    now = _now()

    # The household must have a live walker to share (also feeds SMS copy).
    patients = _active_patients(client_id)
    if not patients:
        raise ApiError(
            code="NO_ACTIVE_WALKER",
            message="Set up your walker before inviting your Care Circle",
            status=409,
        )

    contact_hash = hmac_phone(get_pepper(), validated["phoneE164"])

    # Dedupe vs existing members (covers self — the caller is a member) and
    # vs live pending invites. Household N is tiny; normalize per row.
    for row in _member_rows(client_id):
        row_phone = row.get("phone") or ""
        try:
            row_hash = (
                hmac_phone(get_pepper(), normalize_e164(row_phone))
                if row_phone
                else None
            )
        except PhoneFormatError:
            row_hash = None
        if row_hash and row_hash == contact_hash:
            raise ApiError(
                code="DUPLICATE_INVITE",
                message="That phone number is already in this Care Circle",
                status=409,
            )

    existing = _household_invites(client_id)
    live = [i for i in existing if invite_is_live(i, now)]
    if any(i.get("contactHash") == contact_hash for i in live):
        raise ApiError(
            code="DUPLICATE_INVITE",
            message="An invite for that phone number is already pending",
            status=409,
        )
    if len(live) >= MAX_PENDING_INVITES:
        raise ApiError(
            code="INVITE_LIMIT",
            message=f"A household can have at most {MAX_PENDING_INVITES} pending invites",
            status=409,
        )

    inviter_name = (
        (caller_row or {}).get("displayName")
        or claims.get("name")
        or "A family member"
    )
    invite = build_invite_item(
        client_id=client_id,
        contact_hash=contact_hash,
        phone_e164=validated["phoneE164"],
        validated=validated,
        invited_by=claims["userId"],
        inviter_name=inviter_name,
        household_name=_household_name(client_id),
        walker_name=patients[0].get("displayName") or "your walker",
        patient_ids=[p["patientId"] for p in patients],
        now=now,
    )
    _invites.put_item(Item={k: v for k, v in invite.items() if v is not None})

    try:
        send_sms(validated["phoneE164"], invite_sms_body(invite, D2C_APP_BASE_URL))
    except SmsSendError as exc:
        # Fail visible: don't leave a pending invite the invitee never saw.
        try:
            _invites.delete_item(Key={"inviteId": invite["inviteId"]})
        except ClientError:
            logger.exception("invite_cleanup_failed",
                             extra={"inviteId": invite["inviteId"]})
        raise ApiError(
            code="SMS_SEND_FAILED",
            message="Could not send the invite text — try again",
            status=502,
            details={"error": str(exc)[:200]},
        )

    emit_audit(event=AUDIT_INVITE_SENT, actor=_actor(claims),
               subject={"clientId": client_id, "inviteId": invite["inviteId"]},
               action="create",
               extra={"contactMask": invite["contactMask"],
                      "role": invite["role"],
                      "isWalkerUser": invite["isWalkerUser"]},
               request_id=_request_id(event))

    return ok_response(
        {"invite": pending_invite_view(invite, include_contact=True)}, status=201
    )


# ── POST /household/invites/{id}/resend · DELETE /household/invites/{id} ──

def _resend_invite(
    event: dict[str, Any], claims: dict[str, Any], invite_id: str
) -> dict[str, Any]:
    _require_admin(claims)
    invite = _invite_or_404(invite_id, claims["clientId"])
    if invite.get("status") != INVITE_STATUS_PENDING:
        raise ApiError(code="INVITE_NOT_ACTIVE",
                       message="This invite can no longer be sent", status=409)

    # Re-arm expiry (D8) — an expired-but-pending invite becomes live again.
    expires_at, ttl = invite_expiry(_now())
    _invites.update_item(
        Key={"inviteId": invite_id},
        UpdateExpression="SET expiresAt = :e, #ttl = :t",
        ConditionExpression="#st = :pending",
        ExpressionAttributeNames={"#ttl": "ttl", "#st": "status"},
        ExpressionAttributeValues={":e": expires_at, ":t": ttl,
                                   ":pending": INVITE_STATUS_PENDING},
    )
    invite["expiresAt"] = expires_at

    # Destination = the stored E.164 (the HMAC is irreversible; see
    # circle_logic.build_invite_item for the at-rest rationale).
    to = invite.get("contactE164") or ""
    if not to:
        raise ApiError(
            code="INVITE_NOT_ACTIVE",
            message="This invite can't be re-sent — revoke it and send a new one",
            status=409,
        )
    try:
        send_sms(to, invite_sms_body(invite, D2C_APP_BASE_URL))
    except SmsSendError as exc:
        raise ApiError(code="SMS_SEND_FAILED",
                       message="Could not send the invite text — try again",
                       status=502, details={"error": str(exc)[:200]})

    emit_audit(event=AUDIT_INVITE_RESENT, actor=_actor(claims),
               subject={"clientId": claims["clientId"], "inviteId": invite_id},
               action="update", extra={"contactMask": invite.get("contactMask", "")},
               request_id=_request_id(event))
    return ok_response({"invite": pending_invite_view(invite, include_contact=True)})


def _revoke_invite(
    event: dict[str, Any], claims: dict[str, Any], invite_id: str
) -> dict[str, Any]:
    _require_admin(claims)
    invite = _invite_or_404(invite_id, claims["clientId"])
    if invite.get("status") != INVITE_STATUS_PENDING:
        raise ApiError(code="INVITE_NOT_ACTIVE",
                       message="This invite is no longer pending", status=409)
    _invites.update_item(
        Key={"inviteId": invite_id},
        UpdateExpression="SET #st = :revoked",
        ConditionExpression="#st = :pending",
        ExpressionAttributeNames={"#st": "status"},
        ExpressionAttributeValues={":revoked": INVITE_STATUS_REVOKED,
                                   ":pending": INVITE_STATUS_PENDING},
    )
    emit_audit(event=AUDIT_INVITE_REVOKED, actor=_actor(claims),
               subject={"clientId": claims["clientId"], "inviteId": invite_id},
               action="update", extra={"contactMask": invite.get("contactMask", "")},
               request_id=_request_id(event))
    return ok_response({"revoked": True})


# ── GET /household/members ─────────────────────────────────────────────

def _get_members(event: dict[str, Any], claims: dict[str, Any]) -> dict[str, Any]:
    caller_row = _membership(claims)  # any household role (or bootstrap)
    client_id = claims["clientId"]

    rows = _member_rows(client_id)
    members = [member_view(r, viewer_user_id=claims["userId"]) for r in rows]

    # Account-less walker (D10): synthesize from the active Patient when no
    # member row claims isWalkerUser.
    patients = _active_patients(client_id)
    if patients and not any(m["isWalkerUser"] for m in members):
        members.append(synthesized_walker_view(patients[0]))

    body: dict[str, Any] = {"members": members}
    caller_role = caller_row.get("role") if caller_row else OWNER
    if caller_role == OWNER:
        now = _now()
        body["pendingInvites"] = [
            pending_invite_view(i, include_contact=True)
            for i in _household_invites(client_id)
            if invite_is_live(i, now)
        ]

    emit_audit(event=AUDIT_CARE_CIRCLE_READ, actor=_actor(claims),
               subject={"clientId": client_id},
               action="read", extra={"memberCount": len(members)},
               request_id=_request_id(event))
    return ok_response(body)


# ── GET /invites/pending ───────────────────────────────────────────────

def _pending_for_caller(event: dict[str, Any], claims: dict[str, Any]) -> dict[str, Any]:  # noqa: ARG001
    caller_hash = _caller_phone_hash(claims)
    if not caller_hash:
        return ok_response({"invites": []})  # fail closed, no oracle
    res = _invites.query(
        IndexName="by-contact-hash",
        KeyConditionExpression="contactHash = :h",
        ExpressionAttributeValues={":h": caller_hash},
    )
    now = _now()
    live = [i for i in res.get("Items", []) if invite_is_live(i, now)]
    return ok_response(
        {"invites": [pending_invite_view(i, include_contact=False) for i in live]}
    )


# ── POST /invites/accept ───────────────────────────────────────────────

def _accept_invite(event: dict[str, Any], claims: dict[str, Any]) -> dict[str, Any]:
    sub = claims["userId"]
    body = _parse_body(event)
    invite_id = (body.get("inviteId") or "").strip()
    if not invite_id:
        raise ApiError(code="INVALID_REQUEST", message="inviteId required", status=400)

    invite = _invites.get_item(Key={"inviteId": invite_id}).get("Item")
    if not invite:
        raise ApiError(code="INVITE_NOT_FOUND", message="Invite not found", status=404)

    # 1. Possession proof — fail closed (§5.3 step 1 / claim D11). Missing,
    #    unverified, malformed, and mismatched all return the same neutral
    #    403; audit distinguishes internally.
    caller_hash = _caller_phone_hash(claims)
    reject_reason = None
    if caller_hash is None:
        phone = claims.get("phoneNumber") or ""
        reject_reason = "phone_absent" if not phone else "phone_unverified_or_invalid"
    elif caller_hash != invite.get("contactHash"):
        reject_reason = "phone_mismatch"
    if reject_reason:
        emit_audit(event=AUDIT_INVITE_ACCEPT_REJECTED, actor=_actor(claims),
                   subject={"inviteId": invite_id,
                            "clientId": invite.get("clientId", "")},
                   action="event", extra={"reason": reject_reason},
                   request_id=_request_id(event))
        raise ApiError(
            code="INVITE_PHONE_MISMATCH",
            message="This invite was sent to a different phone number.",
            status=403,
        )

    household_summary = {
        "clientId": invite["clientId"],
        "householdName": invite.get("householdName", ""),
        "walkerName": invite.get("walkerName", ""),
        "role": invite.get("role", VIEWER),
        "isWalkerUser": bool(invite.get("isWalkerUser")),
    }

    # Idempotent re-accept by the same user.
    if invite.get("status") != INVITE_STATUS_PENDING:
        if invite.get("acceptedBy") == sub:
            return ok_response({"household": household_summary, "alreadyMember": True})
        raise ApiError(code="INVITE_NOT_ACTIVE",
                       message="This invite is no longer active", status=409)

    now = _now()
    if not invite_is_live(invite, now):
        raise ApiError(code="INVITE_NOT_ACTIVE",
                       message="This invite is no longer active", status=409)

    # 2. One-household guard (L2/D2). Same-household row → idempotent success.
    existing_row = _roles.get_item(Key={"userId": sub}).get("Item")
    if existing_row and existing_row.get("clientId") != invite["clientId"]:
        raise ApiError(
            code="ALREADY_IN_HOUSEHOLD",
            message=("This account is already part of another Care Circle. "
                     "Contact support to move it."),
            status=409,
        )

    # 3. First-accept-wins (§5.3 step 4).
    try:
        _invites.update_item(
            Key={"inviteId": invite_id},
            UpdateExpression="SET #st = :accepted, acceptedBy = :who, acceptedAt = :now",
            ConditionExpression="#st = :pending",
            ExpressionAttributeNames={"#st": "status"},
            ExpressionAttributeValues={
                ":accepted": "accepted",
                ":pending": INVITE_STATUS_PENDING,
                ":who": sub,
                ":now": iso(now),
            },
        )
    except ClientError as exc:
        if exc.response["Error"]["Code"] == "ConditionalCheckFailedException":
            fresh = _invites.get_item(Key={"inviteId": invite_id}).get("Item") or {}
            if fresh.get("acceptedBy") == sub:
                return ok_response({"household": household_summary, "alreadyMember": True})
            raise ApiError(code="INVITE_NOT_ACTIVE",
                           message="This invite is no longer active", status=409)
        raise

    # 4. Grant write — conditional so a concurrent claim/accept for a
    #    DIFFERENT household loses cleanly (§5.3 step 5).
    active = _active_patients(invite["clientId"])
    row = build_member_row(
        user_id=sub,
        invite=invite,
        claims=claims,
        active_patient_ids=[p["patientId"] for p in active],
        now=now,
    )
    try:
        _roles.put_item(
            Item=row,
            ConditionExpression="attribute_not_exists(userId) OR clientId = :cid",
            ExpressionAttributeValues={":cid": invite["clientId"]},
        )
    except ClientError as exc:
        if exc.response["Error"]["Code"] == "ConditionalCheckFailedException":
            raise ApiError(
                code="ALREADY_IN_HOUSEHOLD",
                message=("This account is already part of another Care Circle. "
                         "Contact support to move it."),
                status=409,
            )
        raise

    # 5. Walker-user link (D11) — best-effort; a stale flag never fails the join.
    if invite.get("isWalkerUser") and active:
        try:
            _patients.update_item(
                Key={"patientId": active[0]["patientId"]},
                UpdateExpression="SET cognitoUserId = :u",
                ConditionExpression=(
                    "attribute_exists(patientId) AND attribute_not_exists(cognitoUserId)"
                ),
                ExpressionAttributeValues={":u": sub},
            )
        except ClientError as exc:
            if exc.response["Error"]["Code"] != "ConditionalCheckFailedException":
                raise
            logger.warning("walker_link_skipped",
                           extra={"patientId": active[0]["patientId"]})

    actor = _actor(claims)
    emit_audit(event=AUDIT_INVITE_ACCEPTED, actor=actor,
               subject={"inviteId": invite_id, "clientId": invite["clientId"]},
               action="update", request_id=_request_id(event))
    emit_audit(event=AUDIT_MEMBER_JOINED, actor=actor,
               subject={"clientId": invite["clientId"], "memberUserId": sub},
               action="create",
               extra={"role": row["role"], "isWalkerUser": row["isWalkerUser"],
                      "invitedBy": invite.get("invitedBy", "")},
               request_id=_request_id(event))

    # Post-accept confirmation SMS (spec §5.3a) — fires ONCE, only on this
    # first successful accept (idempotent re-accepts return early above), so
    # the member keeps a durable re-entry link in their texts. Best-effort:
    # the accept has already committed, so an SMS failure must never fail the
    # join — log and move on. Destination is the invite's stored E164 (the
    # number we just proved the caller possesses).
    to = invite.get("contactE164")
    if to:
        try:
            send_sms(to, confirm_sms_body(invite, D2C_APP_BASE_URL))
            emit_audit(event=AUDIT_MEMBER_JOIN_CONFIRMED, actor=actor,
                       subject={"clientId": invite["clientId"], "memberUserId": sub},
                       action="event",
                       extra={"contactMask": invite.get("contactMask", "")},
                       request_id=_request_id(event))
        except SmsSendError as exc:
            logger.warning("member_join_confirm_sms_failed",
                           extra={"inviteId": invite_id, "error": str(exc)[:200]})

    # Client must refreshClaims() so the next token carries the household.
    return ok_response({"household": household_summary, "alreadyMember": False},
                       status=201)


# ── PATCH /household/members/{userId} ──────────────────────────────────

def _set_member_role(
    event: dict[str, Any], claims: dict[str, Any], target_user_id: str
) -> dict[str, Any]:
    _require_admin(claims)
    client_id = claims["clientId"]
    body = _parse_body(event)
    new_role = (body.get("role") or "").strip()
    if new_role not in {OWNER, VIEWER}:
        raise ApiError(code="INVALID_REQUEST",
                       message=f"role must be one of ['{VIEWER}', '{OWNER}']",
                       status=400)

    target = _roles.get_item(Key={"userId": target_user_id}).get("Item")
    if not target or target.get("clientId") != client_id:
        raise ApiError(code="MEMBER_NOT_FOUND", message="Member not found", status=404)

    old_role = target.get("role", "")
    if old_role == new_role:
        return ok_response({"member": member_view(target)})

    # Last-owner guard (§5.5): a demotion may not orphan the household.
    if old_role == OWNER and _owner_count(client_id) <= 1:
        raise ApiError(
            code="LAST_ADMIN",
            message="A Care Circle needs at least one Admin — promote someone first",
            status=409,
        )

    update = "SET #r = :r, role_userId = :ru"
    names = {"#r": "role"}
    values: dict[str, Any] = {":r": new_role, ":ru": f"{new_role}#{target_user_id}",
                              ":cid": client_id}
    if new_role == VIEWER:
        active_ids = [p["patientId"] for p in _active_patients(client_id)]
        if active_ids:
            update += ", linkedPatientIds = :lp"
            values[":lp"] = set(active_ids)
    else:
        update += " REMOVE linkedPatientIds"  # owners are client-scoped

    _roles.update_item(
        Key={"userId": target_user_id},
        UpdateExpression=update,
        ConditionExpression="clientId = :cid",  # row may not move households
        ExpressionAttributeNames=names,
        ExpressionAttributeValues=values,
    )
    target["role"] = new_role
    target["role_userId"] = f"{new_role}#{target_user_id}"

    emit_audit(event=AUDIT_MEMBER_ROLE_CHANGED, actor=_actor(claims),
               subject={"clientId": client_id, "memberUserId": target_user_id},
               action="update", before={"role": old_role}, after={"role": new_role},
               request_id=_request_id(event))
    return ok_response({"member": member_view(target)})


# ── DELETE /household/members/{userId} ─────────────────────────────────

def _remove_member(
    event: dict[str, Any], claims: dict[str, Any], target_user_id: str
) -> dict[str, Any]:
    client_id = claims["clientId"]
    is_self = target_user_id == claims["userId"]
    if is_self:
        _membership(claims)  # any role may leave (row-fresh check)
    else:
        _require_admin(claims)

    target = _roles.get_item(Key={"userId": target_user_id}).get("Item")
    if not target or target.get("clientId") != client_id:
        raise ApiError(code="MEMBER_NOT_FOUND", message="Member not found", status=404)

    # Last-owner guard covers Admin-remove AND self-leave of the final owner.
    if target.get("role") == OWNER and _owner_count(client_id) <= 1:
        raise ApiError(
            code="LAST_ADMIN",
            message="A Care Circle needs at least one Admin — promote someone first",
            status=409,
        )

    _roles.delete_item(
        Key={"userId": target_user_id},
        ConditionExpression="clientId = :cid",
        ExpressionAttributeValues={":cid": client_id},
    )

    emit_audit(
        event=AUDIT_MEMBER_LEFT if is_self else AUDIT_MEMBER_REMOVED,
        actor=_actor(claims),
        subject={"clientId": client_id, "memberUserId": target_user_id},
        action="delete",
        extra={"role": target.get("role", "")},
        request_id=_request_id(event),
    )
    # Removal is effective on the member's next API call (authz reads DDB);
    # their next token refresh falls back to the bootstrap default (D9).
    return ok_response({"removed": True, "left": is_self})

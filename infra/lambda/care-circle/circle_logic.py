"""
Pure Care Circle helpers — invite validation/shaping, member-row
construction, lifecycle predicates, and response views. Deliberately
import-clean (stdlib + _shared pure helpers, no boto3/powertools) so it
is unit-testable in isolation (tests/test_circle_logic.py). Imported by
handler.py.

Spec: docs/specs/d2c-care-circle.md §5.1–§5.5.

Python 3.12.
"""
from __future__ import annotations

import uuid
from datetime import datetime, timedelta, timezone
from typing import Any

from _shared.api_error import ApiError
from _shared.claim_binding import PhoneFormatError, mask_phone, normalize_e164

# Lifecycle knobs (spec D8).
INVITE_TTL_DAYS = 14          # pending invite validity
INVITE_RETENTION_DAYS = 90    # DDB TTL sweep, measured from expiresAt
MAX_PENDING_INVITES = 10      # per household

NAME_MAX = 60
RELATIONSHIP_MAX = 40

VALID_MEMBER_ROLES = frozenset({"family_viewer", "household_owner"})

INVITE_STATUS_PENDING = "pending"
INVITE_STATUS_ACCEPTED = "accepted"
INVITE_STATUS_REVOKED = "revoked"


def parse_iso(ts: str) -> datetime:
    """ISO-8601 → aware datetime (Z or offset forms)."""
    return datetime.fromisoformat(ts.replace("Z", "+00:00"))


def iso(dt: datetime) -> str:
    return dt.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def validate_invite_input(body: dict[str, Any]) -> dict[str, Any]:
    """
    Validate + normalize POST /household/invites body.

    Returns {name, phoneE164, relationship, role, isWalkerUser}.
    Raises ApiError(INVALID_REQUEST / INVALID_PHONE) on bad input.
    """
    name = (body.get("name") or "").strip()
    if not name:
        raise ApiError(code="INVALID_REQUEST", message="name required", status=400)
    if len(name) > NAME_MAX:
        raise ApiError(
            code="INVALID_REQUEST",
            message=f"name exceeds max length {NAME_MAX}",
            status=400,
        )

    try:
        phone = normalize_e164(body.get("phone") or "")
    except PhoneFormatError as exc:
        raise ApiError(code="INVALID_PHONE", message=str(exc), status=400)

    relationship = (body.get("relationship") or "").strip()
    if len(relationship) > RELATIONSHIP_MAX:
        raise ApiError(
            code="INVALID_REQUEST",
            message=f"relationship exceeds max length {RELATIONSHIP_MAX}",
            status=400,
        )

    role = (body.get("role") or "family_viewer").strip()
    if role not in VALID_MEMBER_ROLES:
        raise ApiError(
            code="INVALID_REQUEST",
            message=f"role must be one of {sorted(VALID_MEMBER_ROLES)}",
            status=400,
        )

    return {
        "name": name,
        "phoneE164": phone,
        "relationship": relationship,
        "role": role,
        "isWalkerUser": bool(body.get("isWalkerUser")),
    }


def invite_is_live(invite: dict[str, Any], now: datetime) -> bool:
    """Pending AND unexpired (spec D8)."""
    if invite.get("status") != INVITE_STATUS_PENDING:
        return False
    expires = invite.get("expiresAt") or ""
    try:
        return parse_iso(expires) > now
    except ValueError:
        return False


def invite_expiry(now: datetime) -> tuple[str, int]:
    """(expiresAt ISO, ttl epoch-seconds) per D8: 14 d validity, +90 d sweep."""
    expires = now + timedelta(days=INVITE_TTL_DAYS)
    ttl = expires + timedelta(days=INVITE_RETENTION_DAYS)
    return iso(expires), int(ttl.timestamp())


def build_invite_item(
    *,
    client_id: str,
    contact_hash: str,
    phone_e164: str,
    validated: dict[str, Any],
    invited_by: str,
    inviter_name: str,
    household_name: str,
    walker_name: str,
    patient_ids: list[str],
    now: datetime,
) -> dict[str, Any]:
    """CareInvites row (spec §5.1). Display names are send-time snapshots so
    the pending list + accept confirmation need zero joins."""
    expires_at, ttl = invite_expiry(now)
    return {
        "inviteId": uuid.uuid4().hex,
        "clientId": client_id,
        "patientIds": set(patient_ids) if patient_ids else None,
        "contactHash": contact_hash,
        "contactMask": mask_phone(phone_e164),
        # Raw destination for resend — the HMAC is irreversible by design.
        # At rest under the table's identity CMK, same posture as the raw
        # `phone` already stored on RoleAssignments rows. Never returned by
        # any endpoint (views expose contactMask only); the by-contact-hash
        # GSI keys on the HMAC, not this.
        "contactE164": phone_e164,
        "contactChannel": "phone",
        "displayName": validated["name"],
        "relationship": validated["relationship"],
        "role": validated["role"],
        "isWalkerUser": validated["isWalkerUser"],
        "status": INVITE_STATUS_PENDING,
        "invitedBy": invited_by,
        "inviterName": inviter_name,
        "householdName": household_name,
        "walkerName": walker_name,
        "createdAt": iso(now),
        "expiresAt": expires_at,
        "ttl": ttl,
    }


def build_member_row(
    *,
    user_id: str,
    invite: dict[str, Any],
    claims: dict[str, Any],
    active_patient_ids: list[str],
    now: datetime,
) -> dict[str, Any]:
    """
    RoleAssignments row for an accepted invite (spec §5.3 step 5).

    linkedPatientIds is resolved at ACCEPT time (not send time) so an
    invite sent before a device rotation still grants the current
    patient. Owners are client-scoped — no linkedPatientIds. scoped*
    ids are omitted (DDB rejects empty sets; absent = unrestricted
    within the household).
    """
    role = invite.get("role") or "family_viewer"
    row: dict[str, Any] = {
        "userId": user_id,
        "clientId": invite["clientId"],
        "role": role,
        "role_userId": f"{role}#{user_id}",
        "isWalkerUser": bool(invite.get("isWalkerUser")),
        "displayName": invite.get("displayName") or (claims.get("name") or ""),
        "relationship": invite.get("relationship") or "",
        "email": claims.get("email", ""),
        "phone": claims.get("phoneNumber", ""),
        "validFrom": iso(now),
        "assignedBy": invite.get("invitedBy") or "",
        "invitedVia": invite["inviteId"],
    }
    if role == "family_viewer" and active_patient_ids:
        row["linkedPatientIds"] = set(active_patient_ids)
    return row


def member_view(row: dict[str, Any], *, viewer_user_id: str = "") -> dict[str, Any]:
    """Roster entry (spec §5.4). Raw phone never leaves the API — mask only."""
    phone = row.get("phone") or ""
    try:
        contact_mask = mask_phone(normalize_e164(phone)) if phone else ""
    except PhoneFormatError:
        contact_mask = ""
    return {
        "userId": row.get("userId"),
        "displayName": row.get("displayName") or "",
        "relationship": row.get("relationship") or "",
        "role": row.get("role"),
        "isWalkerUser": bool(row.get("isWalkerUser")),
        "contactMask": contact_mask,
        "joinedAt": row.get("validFrom"),
        "isViewer": bool(viewer_user_id) and row.get("userId") == viewer_user_id,
    }


def synthesized_walker_view(patient: dict[str, Any]) -> dict[str, Any]:
    """Account-less walker roster entry, from the active Patient row (D10)."""
    return {
        "userId": None,
        "displayName": patient.get("displayName") or "Walker user",
        "relationship": "Walker user",
        "role": None,
        "isWalkerUser": True,
        "contactMask": "",
        "joinedAt": patient.get("createdAt"),
        "isViewer": False,
    }


def pending_invite_view(
    invite: dict[str, Any], *, include_contact: bool
) -> dict[str, Any]:
    """
    Pending-invite entry. `include_contact` (Admin roster view) adds the
    invitee identity fields; the invitee-facing pending list (GET
    /invites/pending) instead describes the HOUSEHOLD they'd be joining.
    """
    view: dict[str, Any] = {
        "inviteId": invite.get("inviteId"),
        "role": invite.get("role"),
        "isWalkerUser": bool(invite.get("isWalkerUser")),
        "expiresAt": invite.get("expiresAt"),
        "createdAt": invite.get("createdAt"),
    }
    if include_contact:
        view.update({
            "displayName": invite.get("displayName") or "",
            "relationship": invite.get("relationship") or "",
            "contactMask": invite.get("contactMask") or "",
        })
    else:
        view.update({
            "householdName": invite.get("householdName") or "",
            "walkerName": invite.get("walkerName") or "",
            "inviterName": invite.get("inviterName") or "",
        })
    return view


def invite_sms_body(invite: dict[str, Any], app_base_url: str) -> str:
    """Invite SMS copy (spec §5.8). The link is a pointer, not a credential —
    authorization is the verified-phone match at accept."""
    walker = invite.get("walkerName") or "a GoSteady walker"
    inviter = invite.get("inviterName") or "A family member"
    return (
        f"{inviter} invited you to {walker}'s GoSteady Care Circle. "
        f"Join: {app_base_url}/join/{invite['inviteId']} "
        f"Reply STOP to opt out."
    )


def confirm_sms_body(invite: dict[str, Any], app_base_url: str) -> str:
    """Post-accept confirmation SMS (spec §5.3a). Sent once, on the FIRST
    successful accept, so the member has a durable re-entry link in their
    texts. The same `/join/{inviteId}` link is a durable re-entry point
    (D2CJoinScreen routes a returning member straight to the dashboard,
    re-verifying the phone with a fresh OTP if the session timed out) — so
    the link they were invited with keeps working as their way back in."""
    walker = invite.get("walkerName") or "your walker"
    return (
        f"You're all set — you can now follow {walker}'s activity on GoSteady. "
        f"View anytime: {app_base_url}/join/{invite['inviteId']} "
        f"(we'll text a code to confirm it's you). Reply STOP to opt out."
    )

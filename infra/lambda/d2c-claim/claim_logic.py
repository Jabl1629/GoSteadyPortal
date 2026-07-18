"""
Pure claim helpers for d2c-claim — household anchoring, the owner/walker
identity split, and owner-contact masking. Deliberately import-clean (stdlib
only, no boto3/powertools) so it is unit-testable in isolation
(tests/test_claim_logic.py). Imported by handler.py.

Python 3.12.
"""
from __future__ import annotations

import hashlib
import hmac as _hmac
import uuid
from typing import Any


def resolve_household(existing_role: dict[str, Any] | None, sub: str) -> tuple[str, str, bool]:
    """Return (clientId, householdId, is_new_household).

    The household is anchored on a STABLE householdId, NOT the Cognito sub, so
    ownership can transfer / gain members / include an account-less walker
    without a data migration (bake-in #3, docs/specs/d2c-phone-only-signin.md
    §7). A returning user's household is read from their existing
    RoleAssignments row; a first-time claimer mints a fresh householdId. `sub`
    is accepted for signature stability / future auditing.
    """
    if existing_role and existing_role.get("clientId"):
        client_id = str(existing_role["clientId"])
        hh = client_id[len("dtc_"):] if client_id.startswith("dtc_") else client_id
        return client_id, hh, False
    hh = uuid.uuid4().hex[:20]
    return f"dtc_{hh}", hh, True


def resolve_identity(body: dict[str, Any], claims: dict[str, Any]) -> tuple[str, str, bool]:
    """Return (owner_name, walker_name, owner_is_walker).

    Identity split (bake-in #2): the account owner and the walker Patient are
    the SAME person for solo self-claim (default) but MAY differ when a
    caregiver sets up for someone else (`caregiverSetup=true`).
    """
    caregiver_setup = bool(body.get("caregiverSetup"))
    # `name` is surfaced by extract_claims from the ID token's standard OIDC
    # claim (fullname is a required D2C pool attribute). The old
    # claims["raw"]["name"] read was dead code — extract_claims never
    # produced a "raw" key (claim-binding spec L6 correction).
    token_name = (claims.get("name") or "").strip()
    display = (body.get("displayName") or "").strip()
    owner_name = (body.get("ownerName") or display or token_name or "Account holder").strip()
    if caregiver_setup:
        walker_name = (body.get("walkerName") or display or "Walker user").strip()
    else:
        walker_name = (body.get("walkerName") or display or token_name or owner_name).strip()
    return owner_name, walker_name, (not caregiver_setup)


def mask_contact(phone: str = "", email: str = "") -> str:
    """A masked owner hint for the pre-claim-race public lookup. Phone tail
    preferred (phone-first pool); else masked email; else neutral copy."""
    digits = "".join(c for c in (phone or "") if c.isdigit())
    if len(digits) >= 2:
        return f"•••{digits[-2:]}"
    if email and "@" in email:
        local, domain = email.split("@", 1)
        head = local[0] if local else "•"
        return f"{head}•••@{domain}"
    return "another account"


# ── QR re-login: masked login-recipient list (d2c-qr-relogin) ──────────

def _mask_tail4(e164_phone: str) -> str:
    """Display mask •••-1234 (last 4). Matches _shared.claim_binding.mask_phone
    but inlined here to keep this module import-clean."""
    digits = [c for c in e164_phone if c.isdigit()]
    return "•••-" + "".join(digits[-4:])


def _recipient_label(member: dict[str, Any]) -> str:
    """Human label for a login recipient — never the raw name/phone.
    Walker user → "Registered user"; else the relationship, else "Care Circle
    member"."""
    if member.get("isWalkerUser"):
        return "Registered user"
    rel = (member.get("relationship") or "").strip()
    return rel or "Care Circle member"


def login_recipient_id(pepper: str, walker_id: str, e164_phone: str) -> str:
    """Opaque, stable handle for a login recipient. Peppered HMAC of
    walkerId+phone → the client passes it back without ever seeing the phone
    or the Cognito sub. Recomputed server-side on send/verify to resolve the
    phone."""
    msg = f"{walker_id}:{e164_phone}".encode()
    return _hmac.new(pepper.encode(), msg, hashlib.sha256).hexdigest()[:24]


def build_login_recipients(
    members: list[dict[str, Any]], walker_id: str, pepper: str
) -> tuple[list[dict[str, Any]], dict[str, str]]:
    """
    Shape the household's RoleAssignments rows into the public login-recipient
    list (d2c-qr-relogin) + a recipientId→phone lookup for the send/verify legs.

    `members`: rows with `phone` (E.164), `role`, `isWalkerUser`,
    `relationship`. Rows without a phone (an account-less walker) are skipped.

    Returns `(public, id_to_phone)`:
      - `public`: `[{recipientId, mask, label, isPrimary}]` — NO phone, NO sub.
        Exactly one `isPrimary` (the "That's me" target): the walker user if
        one has an account, else the first household_owner.
      - `id_to_phone`: server-only map for resolving a selected recipient.
    """
    with_phone = [m for m in members if (m.get("phone") or "").strip()]

    primary_key = None
    for m in with_phone:
        if m.get("isWalkerUser"):
            primary_key = m.get("phone")
            break
    if primary_key is None:
        for m in with_phone:
            if m.get("role") == "household_owner":
                primary_key = m.get("phone")
                break

    public: list[dict[str, Any]] = []
    id_to_phone: dict[str, str] = {}
    for m in with_phone:
        phone = (m.get("phone") or "").strip()
        rid = login_recipient_id(pepper, walker_id, phone)
        id_to_phone[rid] = phone
        public.append({
            "recipientId": rid,
            "mask": _mask_tail4(phone),
            "label": _recipient_label(m),
            "isPrimary": phone == primary_key,
        })
    # Primary first, then a stable order by label + mask.
    public.sort(key=lambda r: (not r["isPrimary"], r["label"], r["mask"]))
    return public, id_to_phone

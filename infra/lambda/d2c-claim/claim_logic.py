"""
Pure claim helpers for d2c-claim — household anchoring, the owner/walker
identity split, and owner-contact masking. Deliberately import-clean (stdlib
only, no boto3/powertools) so it is unit-testable in isolation
(tests/test_claim_logic.py). Imported by handler.py.

Python 3.12.
"""
from __future__ import annotations

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
    raw = claims.get("raw", {}) or {}
    display = (body.get("displayName") or "").strip()
    owner_name = (body.get("ownerName") or display or raw.get("name") or "Account holder").strip()
    if caregiver_setup:
        walker_name = (body.get("walkerName") or display or "Walker user").strip()
    else:
        walker_name = (body.get("walkerName") or display or raw.get("name") or owner_name).strip()
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

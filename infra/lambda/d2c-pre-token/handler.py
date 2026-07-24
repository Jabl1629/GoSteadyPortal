"""
D2C Pre-Token Generation V2 Lambda — GoSteady D2C Phase 1.

Fires on every token mint (sign-in + refresh) for the **D2C user pool**.
Injects the multi-tenancy claims the API authz layer expects:

    custom:clientId      — the household client (dtc_*)
    custom:role          — household_owner (Admin) | family_viewer (Member)
    custom:isWalkerUser  — "true" | "false"
    custom:facilities    — "" (D2C has no facility scoping)
    custom:censuses      — ""

Chicken-and-egg handling (the important bit):
A brand-new signup gets its first token BEFORE it calls POST /claim, so no
RoleAssignments row exists yet. In that case we emit the **bootstrap
default** — clientId=dtc_{sub}, role=household_owner, isWalkerUser=true —
which is exactly what /claim will then persist. Tokens are therefore
consistent before and after claim; between signup and claim, /me/patients
simply returns empty (no data under the client yet).

Once a RoleAssignments row exists (after claim, or for an invited Member in
a later phase), its values win — so a Member who joins someone else's
household gets that household's clientId, not their own.

Python 3.12, ARM64. boto3 + stdlib only.
"""
from __future__ import annotations

import json
import os
from datetime import datetime, timezone
from typing import Any

import boto3

_ddb = boto3.resource("dynamodb")
_table = _ddb.Table(os.environ["ROLE_ASSIGNMENTS_TABLE"])

VALID_ROLES = {"household_owner", "family_viewer"}

# ── Audit emission (docs/specs/user-analytics.md) ──────────────────────
# Stdlib-only Lambda → emit the audit-shape JSON line directly (matches the
# Phase 1.7 `{ $.audit IS TRUE }` subscription filter). Only `auth.token_refresh`
# is emitted here — the D2C *login* is emitted by d2c-custom-auth on OTP verify
# (emitting login here too would double-count). Densifies the #4 active-time
# proxy. Best-effort: never break auth (user-analytics L5).
AUDIT_AUTH_TOKEN_REFRESH = "auth.token_refresh"
TRIGGER_REFRESH = "TokenGeneration_RefreshTokens"


def _emit_token_refresh(sub: str, client_id: str, role: str) -> None:
    try:
        print(json.dumps({
            "audit": True,
            "schema_version": 1,
            "event": AUDIT_AUTH_TOKEN_REFRESH,
            "actor": {"userId": sub, "clientId": client_id, "role": role},
            "subject": {},
            "action": "event",
            "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        }, default=str))
    except Exception:  # noqa: BLE001 — analytics must never break auth
        pass


def resolve_is_walker_user(row: dict[str, Any] | None, role: str) -> str:
    """Resolve the `custom:isWalkerUser` claim value ("true"/"false").

    An ABSENT `isWalkerUser` on the row (legacy pre-C56 owner rows minted before
    the flag was written) is derived from role — a solo `household_owner` IS the
    walker — so the walker signal stays reliable across dev+prod without a bulk
    RoleAssignments backfill. An EXPLICIT False (a caregiver-owner) is preserved.
    No row (pre-claim bootstrap) → caller passes role="household_owner" → "true",
    matching the bootstrap default.
    """
    raw = (row or {}).get("isWalkerUser")
    if raw is None:
        return "true" if role == "household_owner" else "false"
    return "true" if raw else "false"


def handler(event: dict[str, Any], context: Any) -> dict[str, Any]:  # noqa: ARG001
    sub = (event.get("request", {}).get("userAttributes", {}) or {}).get("sub", "")

    client_id = f"dtc_{sub}"
    role = "household_owner"

    # Prefer an existing RoleAssignments row when present (post-claim, or an
    # invited Member). Falls back to the bootstrap default otherwise.
    try:
        row = _table.get_item(Key={"userId": sub}).get("Item")
    except Exception:  # noqa: BLE001 — never block auth on a read hiccup
        row = None

    if row:
        client_id = row.get("clientId") or client_id
        r = row.get("role")
        if r in VALID_ROLES:
            role = r

    # Derived after role resolution so a legacy owner row with no isWalkerUser
    # attribute still emits "true"; no row → the bootstrap owner default.
    is_walker_user = resolve_is_walker_user(row, role)

    claims = {
        "custom:clientId": client_id,
        "custom:role": role,
        "custom:isWalkerUser": is_walker_user,
        "custom:facilities": "",
        "custom:censuses": "",
    }

    event["response"] = {
        "claimsAndScopeOverrideDetails": {
            "idTokenGeneration": {"claimsToAddOrOverride": claims},
            "accessTokenGeneration": {"claimsToAddOrOverride": claims},
        }
    }

    # Auth funnel (user-analytics.md): a refresh keeps an active session alive —
    # emit token_refresh so the coarse #4 active-time proxy has a heartbeat.
    if event.get("triggerSource", "") == TRIGGER_REFRESH:
        _emit_token_refresh(sub, client_id, role)

    return event

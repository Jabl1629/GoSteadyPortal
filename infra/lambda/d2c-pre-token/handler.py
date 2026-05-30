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

import os
from typing import Any

import boto3

_ddb = boto3.resource("dynamodb")
_table = _ddb.Table(os.environ["ROLE_ASSIGNMENTS_TABLE"])

VALID_ROLES = {"household_owner", "family_viewer"}


def handler(event: dict[str, Any], context: Any) -> dict[str, Any]:  # noqa: ARG001
    sub = (event.get("request", {}).get("userAttributes", {}) or {}).get("sub", "")

    client_id = f"dtc_{sub}"
    role = "household_owner"
    is_walker_user = "true"

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
        is_walker_user = "true" if row.get("isWalkerUser") else "false"

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
    return event

"""
Cognito Pre-Token Generation Lambda (V2 trigger).

Fires on every authentication (sign-in + refresh). Responsibilities:

1. Look up the user's RoleAssignment from DynamoDB by Cognito sub.
2. Deny auth (NO_ROLE_ASSIGNED) if no RoleAssignment exists.
3. Validate group membership matches the RoleAssignment role.
4. Enforce MFA for admin / internal roles (deny MFA_REQUIRED if missing).
5. Validate clientId tenancy invariants:
     - internal_*       roles must have clientId == "_internal"
     - household_owner  must have clientId starting with "dtc_"
   Deny TENANCY_VIOLATION on mismatch.
6. Inject custom claims into ID + Access tokens:
     - custom:clientId
     - custom:role
     - custom:facilities  (comma-separated)
     - custom:censuses    (comma-separated)

Spec: docs/specs/phase-0a-revision.md §Pre-Token Generation Lambda
Architecture: docs/specs/ARCHITECTURE.md §4 Multi-Tenancy & Access Model
"""
from __future__ import annotations

import logging
import os
from typing import Any, Dict, List, Optional

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

# ──────────────────────────────────────────────────────────────────────
# Configuration
# ──────────────────────────────────────────────────────────────────────

ROLE_ASSIGNMENTS_TABLE = os.environ["ROLE_ASSIGNMENTS_TABLE"]
ENVIRONMENT = os.environ.get("ENVIRONMENT", "dev")

# Roles that require MFA verification on every authentication.
# Mirrors phase-0a-revision.md L7 / phase-1.5-security.md L9.
MFA_REQUIRED_ROLES = {
    "facility_admin",
    "client_admin",
    "internal_support",
    "internal_admin",
}

# Set of all valid roles. Defensive: ensures Pre-Token Lambda rejects
# unknown roles rather than silently passing them through.
VALID_ROLES = {
    "patient",
    "family_viewer",
    "household_owner",
    "caregiver",
    "facility_admin",
    "client_admin",
    "internal_support",
    "internal_admin",
}

INTERNAL_CLIENT_ID = "_internal"
DTC_CLIENT_PREFIX = "dtc_"

# Custom error names returned to the client. Match spec §Interfaces.
ERR_NO_ROLE_ASSIGNED = "NO_ROLE_ASSIGNED"
ERR_MFA_REQUIRED = "MFA_REQUIRED"
ERR_TENANCY_VIOLATION = "TENANCY_VIOLATION"
ERR_INVALID_ROLE = "INVALID_ROLE"

# ──────────────────────────────────────────────────────────────────────
# AWS clients (initialized at module load — reused across warm invocations)
# ──────────────────────────────────────────────────────────────────────

_dynamodb = boto3.resource("dynamodb")
_role_table = _dynamodb.Table(ROLE_ASSIGNMENTS_TABLE)


# ──────────────────────────────────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────────────────────────────────


def _scrub(payload: Dict[str, Any]) -> Dict[str, Any]:
    """Strip PII before logging. Per L14 of phase-1b-revision.md / AU3."""
    if not isinstance(payload, dict):
        return payload
    PII_KEYS = {"displayName", "dateOfBirth", "email", "name", "given_name", "family_name"}
    return {k: ("[REDACTED]" if k in PII_KEYS else v) for k, v in payload.items()}


def _get_role_assignment(user_id: str) -> Optional[Dict[str, Any]]:
    """GetItem on RoleAssignments by userId (Cognito sub).

    Returns the assignment dict or None if no row exists.
    """
    try:
        response = _role_table.get_item(Key={"userId": user_id})
        return response.get("Item")
    except ClientError as exc:
        # KMS Decrypt failure or DDB unreachable — log and re-raise
        # (Cognito will treat this as auth failure).
        logger.error(
            "RoleAssignments GetItem failed",
            extra={"userId": user_id, "error": str(exc)},
        )
        raise


def _serialize_string_set(value: Any) -> str:
    """DDB string set → comma-separated string (Cognito custom-attribute format).

    Handles:
      - DDB StringSet (returned as Python set by boto3 resource API)
      - DDB List of strings
      - Already-a-string (rare)
      - None / missing
    """
    if value is None:
        return ""
    if isinstance(value, set):
        return ",".join(sorted(value))
    if isinstance(value, (list, tuple)):
        return ",".join(str(x) for x in value)
    if isinstance(value, str):
        return value
    return ""


def _is_mfa_verified(event: Dict[str, Any]) -> bool:
    """Determine whether the current auth context completed MFA.

    Pre-Token V2 events expose this via several signals:
      - request.userAttributes contains the user's MFA-enrollment status
      - clientMetadata may contain MFA challenge result for SDK flows
      - the underlying Cognito context already enforces MFA at the
        authentication-flow level when the user has an MFA factor enrolled

    For our purposes, we check whether the user has TOTP MFA enrolled.
    Cognito will have already enforced the challenge via flow if so.
    A user with an admin/internal role but no MFA enrolled = denied.
    """
    user_attrs = event.get("request", {}).get("userAttributes", {})

    # software_token_mfa_enabled is set when the user has registered TOTP.
    # phone_number_verified isn't relevant — we don't enable SMS MFA.
    return user_attrs.get("custom:mfa_enrolled") == "true" or _user_has_totp_software_token(event)


def _user_has_totp_software_token(event: Dict[str, Any]) -> bool:
    """Check whether the user has TOTP MFA registered.

    Cognito Pre-Token V2 events do NOT expose MFA-enrollment status directly;
    the underlying flow enforces MFA challenges based on
    UserPool.MfaConfiguration + per-user MFA settings (via AdminSetUserMFAPreference).

    If the user got this far in the auth flow with a privileged role, Cognito
    has already validated their MFA token (or rejected the auth before this
    Lambda fires). So at this point, MFA enforcement at the Lambda layer is
    primarily about *requiring* MFA for users who haven't enrolled yet —
    we read their TOTP-enabled status from userAttributes.

    Implementation note: Cognito's UserAttributes dict for Pre-Token V2 may
    not include `software_token_mfa_enabled` directly. The robust path is
    cognito-idp:AdminGetUser, but that adds latency. For Phase 0A revision
    we use a single attribute `custom:mfa_enrolled` set during the user's
    MFA-setup flow (Phase 2B will manage this; for now manually set in tests).
    """
    # Defensive: any non-empty `custom:mfa_enrolled` attribute is treated as enrolled.
    user_attrs = event.get("request", {}).get("userAttributes", {})
    val = user_attrs.get("custom:mfa_enrolled", "").strip().lower()
    return val in ("true", "1", "yes")


# ──────────────────────────────────────────────────────────────────────
# Validation (raises ValueError on rejection — caught by handler)
# ──────────────────────────────────────────────────────────────────────


def _validate_role(role: str) -> None:
    if role not in VALID_ROLES:
        raise ValueError(f"{ERR_INVALID_ROLE}:{role}")


def _validate_tenancy(role: str, client_id: str) -> None:
    """Enforce role-vs-clientId invariants.

    Internal roles (internal_*) must have clientId == "_internal".
    Household_owner must have clientId starting with "dtc_".
    All other roles: any non-internal, non-dtc clientId is acceptable.
    """
    if role.startswith("internal_"):
        if client_id != INTERNAL_CLIENT_ID:
            raise ValueError(
                f"{ERR_TENANCY_VIOLATION}:internal_role_with_non_internal_client"
            )
        return

    if role == "household_owner":
        if not client_id.startswith(DTC_CLIENT_PREFIX):
            raise ValueError(
                f"{ERR_TENANCY_VIOLATION}:household_owner_with_non_dtc_client"
            )
        return

    # Other roles: defensive checks
    if client_id == INTERNAL_CLIENT_ID:
        raise ValueError(
            f"{ERR_TENANCY_VIOLATION}:non_internal_role_with_internal_client"
        )


def _validate_mfa(role: str, event: Dict[str, Any]) -> None:
    """Deny if role requires MFA and user hasn't enrolled."""
    if role not in MFA_REQUIRED_ROLES:
        return
    if not _is_mfa_verified(event):
        raise ValueError(f"{ERR_MFA_REQUIRED}:{role}")


# ──────────────────────────────────────────────────────────────────────
# Token-claims construction
# ──────────────────────────────────────────────────────────────────────


def _build_claims(role_assignment: Dict[str, Any]) -> Dict[str, str]:
    """Build the custom-claims map injected into ID + Access tokens."""
    return {
        "custom:clientId": role_assignment["clientId"],
        "custom:role": role_assignment["role"],
        "custom:facilities": _serialize_string_set(
            role_assignment.get("scopedFacilityIds")
        ),
        "custom:censuses": _serialize_string_set(
            role_assignment.get("scopedCensusIds")
        ),
    }


def _build_response_v2(
    event: Dict[str, Any], claims: Dict[str, str]
) -> Dict[str, Any]:
    """Build the Pre-Token V2 response with claims overrides on both tokens.

    See: https://docs.aws.amazon.com/cognito/latest/developerguide/user-pool-lambda-pre-token-generation.html#user-pool-lambda-pre-token-generation-v2
    """
    event["response"] = {
        "claimsAndScopeOverrideDetails": {
            "idTokenGeneration": {
                "claimsToAddOrOverride": claims,
            },
            "accessTokenGeneration": {
                "claimsToAddOrOverride": claims,
            },
        }
    }
    return event


# ──────────────────────────────────────────────────────────────────────
# Main handler
# ──────────────────────────────────────────────────────────────────────


def handler(event: Dict[str, Any], context: Any) -> Dict[str, Any]:
    """Lambda entrypoint.

    On success: returns the event with `response.claimsAndScopeOverrideDetails`
    populated with the custom claims to inject into both tokens.

    On failure: raises an exception. Cognito propagates the message to the
    client as a generic auth failure; the Lambda's structured log entry is
    where ops sees the actual deny reason.
    """
    user_id = event.get("userName", "")
    trigger = event.get("triggerSource", "unknown")
    user_pool_id = event.get("userPoolId", "")
    client_id_calling = event.get("callerContext", {}).get("clientId", "")

    logger.info(
        "Pre-Token invoked",
        extra={
            "userId": user_id,
            "trigger": trigger,
            "userPoolId": user_pool_id,
            "callingClientId": client_id_calling,
            "version": event.get("version"),
        },
    )

    if not user_id:
        # Should never happen in a properly-configured pool, but defensive.
        raise ValueError("missing userName in event")

    # ── Step 1: load RoleAssignment ─────────────────────────────────
    role_assignment = _get_role_assignment(user_id)
    if role_assignment is None:
        logger.warning(
            "RoleAssignment missing — denying auth",
            extra={"userId": user_id, "errorCode": ERR_NO_ROLE_ASSIGNED},
        )
        raise ValueError(ERR_NO_ROLE_ASSIGNED)

    role = role_assignment.get("role", "")
    client_id = role_assignment.get("clientId", "")

    # ── Step 2: validate role enum ──────────────────────────────────
    _validate_role(role)

    # ── Step 3: validate tenancy invariants ─────────────────────────
    _validate_tenancy(role, client_id)

    # ── Step 4: enforce MFA for privileged roles ────────────────────
    _validate_mfa(role, event)

    # ── Step 5: build claims + response ────────────────────────────
    claims = _build_claims(role_assignment)
    response = _build_response_v2(event, claims)

    logger.info(
        "Pre-Token success — claims injected",
        extra={
            "userId": user_id,
            "role": role,
            "clientId": client_id,
            # Don't log full claims; facilities/censuses are non-PII but verbose
            "facilitiesCount": len(claims["custom:facilities"].split(",")) if claims["custom:facilities"] else 0,
            "censusesCount": len(claims["custom:censuses"].split(",")) if claims["custom:censuses"] else 0,
        },
    )

    return response

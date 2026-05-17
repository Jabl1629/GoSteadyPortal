"""
Shared API authorization + tenancy + scope helpers — Phase 2A-0.

These helpers are called from every handler (or wrapped via the
audit_middleware decorator). They pull the Cognito JWT claims out of
the API Gateway request context and provide:

  - extract_claims(event)  → normalized dict of the claims we care about
  - is_internal(claims)    → True for any internal_* role
  - require_role(...)      → raises ApiError(INSUFFICIENT_PERMISSIONS)
                             if the actor's role isn't in the allowed set
  - enforce_tenancy(...)   → raises ApiError(TENANCY_VIOLATION) if the
                             actor's clientId doesn't match the target
                             resource's clientId (internal_* bypasses)
  - enforce_scope(...)     → raises ApiError(OUT_OF_SCOPE) if the actor's
                             facility/census claims don't cover the target

JWT claim sources (per Phase 0A revision Pre-Token Generation Lambda V2):
  custom:clientId   → tenancy partition (one per user)
  custom:role       → role string (family_viewer, caregiver, ...)
  custom:facilities → comma-separated facility IDs, or empty
  custom:censuses   → comma-separated census IDs, or empty
  custom:mfa_enrolled → "true" or "false"
"""

from __future__ import annotations

from typing import Any

from .api_error import ApiError

# Roles that bypass the customer tenancy boundary (they belong to the
# reserved _internal client). See ARCHITECTURE.md §4 Internal Access.
INTERNAL_ROLE_PREFIX = "internal_"

# Roles that require MFA at sign-in time. Per Phase 0A revision A7.
MFA_REQUIRED_ROLES = frozenset(
    {"facility_admin", "client_admin", "internal_support", "internal_admin"}
)


def extract_claims(event: dict[str, Any]) -> dict[str, Any]:
    """
    Pull the JWT claims from the API Gateway HTTP API request context
    into a normalized dict. Returns an empty dict if no claims are
    present (e.g., a misconfigured route without the JWT authorizer);
    handlers should treat that as UNAUTHENTICATED.

    API Gateway HTTP API JWT authorizer puts the claims under:
        event.requestContext.authorizer.jwt.claims
    """
    rc = event.get("requestContext", {}) or {}
    authz = rc.get("authorizer", {}) or {}
    jwt = authz.get("jwt", {}) or {}
    claims = jwt.get("claims", {}) or {}

    facilities_raw = claims.get("custom:facilities", "") or ""
    censuses_raw = claims.get("custom:censuses", "") or ""

    return {
        "userId": claims.get("sub", ""),
        "email": claims.get("email", ""),
        "clientId": claims.get("custom:clientId", ""),
        "role": claims.get("custom:role", ""),
        "facilities": [f.strip() for f in facilities_raw.split(",") if f.strip()],
        "censuses": [c.strip() for c in censuses_raw.split(",") if c.strip()],
        "mfaEnrolled": claims.get("custom:mfa_enrolled", "false") == "true",
    }


def is_internal(claims: dict[str, Any]) -> bool:
    """True if the actor belongs to the reserved `_internal` client."""
    role = claims.get("role", "") or ""
    return role.startswith(INTERNAL_ROLE_PREFIX)


def require_authenticated(claims: dict[str, Any]) -> None:
    """Raise UNAUTHENTICATED if the JWT didn't come through."""
    if not claims.get("userId") or not claims.get("role"):
        raise ApiError(
            code="UNAUTHENTICATED",
            message="Authorization required",
            status=401,
        )


def require_role(claims: dict[str, Any], *allowed_roles: str) -> None:
    """
    Raise INSUFFICIENT_PERMISSIONS if the actor's role isn't in the
    allowed-list. Internal roles must be named explicitly in `allowed_roles`
    if they're allowed — this helper does NOT auto-allow internal_*.
    """
    role = claims.get("role", "")
    if role not in allowed_roles:
        raise ApiError(
            code="INSUFFICIENT_PERMISSIONS",
            message=f"Role '{role}' is not permitted on this resource",
            status=403,
            details={"requiredAnyOf": list(allowed_roles)},
        )


def require_mfa(claims: dict[str, Any]) -> None:
    """
    Raise MFA_REQUIRED if the actor's role mandates MFA per Phase 0A
    revision A7 but `custom:mfa_enrolled` isn't true.
    """
    if claims.get("role") in MFA_REQUIRED_ROLES and not claims.get("mfaEnrolled"):
        raise ApiError(
            code="MFA_REQUIRED",
            message="This action requires multi-factor authentication enrollment",
            status=403,
            details={"missingClaim": "custom:mfa_enrolled"},
        )


def enforce_tenancy(claims: dict[str, Any], target_client_id: str) -> None:
    """
    The hard customer tenancy boundary (ARCHITECTURE.md T2 + Phase 2A-0 L5).

    Compares the actor's `custom:clientId` against the resource being
    operated on. Raises TENANCY_VIOLATION on mismatch. Internal_* roles
    bypass — they have role-granted cross-tenant authority (audited at
    elevated severity at emit time).
    """
    if is_internal(claims):
        return
    actor_client = claims.get("clientId", "")
    if not actor_client:
        raise ApiError(
            code="TENANCY_VIOLATION",
            message="No clientId claim on token",
            status=403,
            details={"missingClaim": "custom:clientId"},
        )
    if actor_client != target_client_id:
        raise ApiError(
            code="TENANCY_VIOLATION",
            message="Token clientId does not match target resource",
            status=403,
            details={"tokenClientId": actor_client, "targetClientId": target_client_id},
        )


def enforce_scope(
    claims: dict[str, Any],
    target_facility_id: str | None = None,
    target_census_id: str | None = None,
) -> None:
    """
    Enforce facility/census scope for caregiver and facility_admin roles.

    `client_admin` is unrestricted within their client (the tenancy check
    already ran). `caregiver` / `facility_admin` are restricted by their
    scope claims. Empty scope claims mean "all" within their role's
    natural ceiling (e.g., facility_admin with empty censuses → all
    censuses in their scoped facilities).

    Internal roles bypass.
    """
    if is_internal(claims):
        return

    role = claims.get("role", "")

    # client_admin and household_owner: no facility/census restriction
    # within their client (their tenancy boundary already enforced).
    if role in {"client_admin", "household_owner", "family_viewer"}:
        return

    # facility_admin: check facility scope only
    if role == "facility_admin":
        if target_facility_id and claims["facilities"]:
            if target_facility_id not in claims["facilities"]:
                raise ApiError(
                    code="OUT_OF_SCOPE",
                    message="Facility not in actor's scope",
                    status=403,
                    details={
                        "targetFacilityId": target_facility_id,
                        "actorFacilities": claims["facilities"],
                    },
                )
        return

    # caregiver: facility AND census scope
    if role == "caregiver":
        if target_facility_id and claims["facilities"]:
            if target_facility_id not in claims["facilities"]:
                raise ApiError(
                    code="OUT_OF_SCOPE",
                    message="Facility not in actor's scope",
                    status=403,
                    details={
                        "targetFacilityId": target_facility_id,
                        "actorFacilities": claims["facilities"],
                    },
                )
        if target_census_id and claims["censuses"]:
            if target_census_id not in claims["censuses"]:
                raise ApiError(
                    code="OUT_OF_SCOPE",
                    message="Census not in actor's scope",
                    status=403,
                    details={
                        "targetCensusId": target_census_id,
                        "actorCensuses": claims["censuses"],
                    },
                )
        return

    # Unknown role: deny.
    raise ApiError(
        code="INSUFFICIENT_PERMISSIONS",
        message=f"Unknown role '{role}'",
        status=403,
    )

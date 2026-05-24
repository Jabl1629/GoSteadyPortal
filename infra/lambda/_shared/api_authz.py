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


# ── Phase 2A-RD additions (Patient Reads) ─────────────────────────────


def linked_patient_ids(claims: dict[str, Any], role_assignments_table: Any) -> set[str]:
    """
    For `family_viewer` role: load `linkedPatientIds` from RoleAssignments.

    Family viewers don't get their patient list embedded in the JWT — the
    list could be large (spec A4) and would bloat every token. Instead the
    RoleAssignments table is the source of truth; this helper does a single
    GetItem keyed by userId and returns the set.

    Returns an empty set for any role other than `family_viewer` (those
    roles use claim-derived scope instead). Returns an empty set for a
    family_viewer with no role assignment row — handler should treat that
    as "no patients accessible" and 404 any per-patient probe.

    `role_assignments_table` is a boto3 DDB Table resource passed in by the
    handler (so this module stays pure-ish; no module-level boto3).
    """
    if claims.get("role") != "family_viewer":
        return set()
    user_id = claims.get("userId", "")
    if not user_id:
        return set()
    res = role_assignments_table.get_item(Key={"userId": user_id})
    item = res.get("Item") or {}
    raw = item.get("linkedPatientIds")
    if raw is None:
        return set()
    # DDB SS attribute: boto3 returns set(); also tolerate list (legacy) or string.
    if isinstance(raw, (set, frozenset)):
        return {str(x) for x in raw}
    if isinstance(raw, (list, tuple)):
        return {str(x) for x in raw}
    if isinstance(raw, str):
        return {p.strip() for p in raw.split(",") if p.strip()}
    return set()


def enforce_patient_access(
    claims: dict[str, Any],
    patient: dict[str, Any],
    *,
    linked_ids: set[str] | None = None,
) -> None:
    """
    Single-patient access check covering every role.

    Order of checks:
      1. Internal_* → pass (audit-tagged at emit time).
      2. Tenancy: actor's clientId must match patient.clientId.
      3. family_viewer: patient.patientId must be in `linked_ids`
         (caller pre-loads via linked_patient_ids()).
      4. caregiver / facility_admin: facility/census scope via enforce_scope.

    Existence-leak prevention: when a family_viewer probes a patient
    they're not linked to, we raise 404 PATIENT_NOT_FOUND (not 403) so
    callers can't enumerate patient IDs. The tenancy and scope checks
    raise 403 because the caller's path itself implies they should know
    the resource (e.g., a caregiver hitting a device serial they don't
    own is a 403, not a 404 — the device exists, they just can't touch it).
    """
    if is_internal(claims):
        return

    patient_id = patient.get("patientId", "")
    patient_client = patient.get("clientId", "")

    # Tenancy first (everyone except internal).
    enforce_tenancy(claims, patient_client)

    role = claims.get("role", "")

    if role == "family_viewer":
        linked = linked_ids if linked_ids is not None else set()
        if patient_id not in linked:
            # 404, not 403 — see existence-leak note above.
            raise ApiError(
                code="PATIENT_NOT_FOUND",
                message=f"Patient {patient_id} not found",
                status=404,
            )
        return

    if role in {"caregiver", "facility_admin"}:
        enforce_scope(
            claims,
            target_facility_id=patient.get("facilityId"),
            target_census_id=patient.get("censusId"),
        )
        return

    if role in {"client_admin", "household_owner"}:
        # Tenancy check already enforced; nothing further within the client.
        return

    raise ApiError(
        code="INSUFFICIENT_PERMISSIONS",
        message=f"Role '{role}' is not permitted on this resource",
        status=403,
    )


# Scope-resolution plan shapes (returned by resolve_list_scope).
# Discriminator on `pattern`:
#   "by-client":     query Patients GSI by-client-status (PK=clientId)
#   "by-census":     fan out per census, query GSI by-census-status (PK=censusId)
#   "by-patient-ids": BatchGetItem on Patients keyed by patientIds
#   "no-data":       no patients accessible (e.g., caregiver with empty scope claims)


def resolve_list_scope(
    claims: dict[str, Any],
    *,
    internal_client_id: str | None = None,
) -> dict[str, Any]:
    """
    Build the DDB query plan for `GET /me/patients` based on caller's role.

    Returns a dict shaped like:
      {
        "pattern": "by-client" | "by-census" | "by-patient-ids" | "no-data",
        "clientId": str,                # target client (for by-client / by-census plans)
        "facilityIds": list[str],       # for filtering when role=facility_admin with explicit facilities
        "censusIds": list[str],         # for by-census plan
        "patientIds": list[str],        # for by-patient-ids plan (family_viewer only)
        "internalAccess": bool,         # mirrored back in scope summary
      }

    Args:
      claims: extracted JWT claims.
      internal_client_id: required for internal_* callers — the explicit
        `?clientId=` query param. Raised as 400 by handler if missing,
        not here (this is a pure resolution helper).
    """
    role = claims.get("role", "")
    actor_client = claims.get("clientId", "")

    if is_internal(claims):
        if not internal_client_id:
            # The handler is expected to validate this before calling, but
            # be defensive — never silently scan everything.
            return {
                "pattern": "no-data",
                "clientId": "",
                "facilityIds": [],
                "censusIds": [],
                "patientIds": [],
                "internalAccess": True,
            }
        return {
            "pattern": "by-client",
            "clientId": internal_client_id,
            "facilityIds": [],
            "censusIds": [],
            "patientIds": [],
            "internalAccess": True,
        }

    if role == "family_viewer":
        # patientIds field is the linkedPatientIds set; handler pre-loads
        # via linked_patient_ids() and passes it explicitly when calling
        # BatchGetItem. We return the pattern + empty list here; handler
        # fills in patientIds at call-site.
        return {
            "pattern": "by-patient-ids",
            "clientId": actor_client,
            "facilityIds": [],
            "censusIds": [],
            "patientIds": [],
            "internalAccess": False,
        }

    if role == "caregiver":
        censuses = claims.get("censuses") or []
        if not censuses:
            # Caregiver with no censuses claim has no scope — show nothing.
            return {
                "pattern": "no-data",
                "clientId": actor_client,
                "facilityIds": claims.get("facilities") or [],
                "censusIds": [],
                "patientIds": [],
                "internalAccess": False,
            }
        return {
            "pattern": "by-census",
            "clientId": actor_client,
            "facilityIds": claims.get("facilities") or [],
            "censusIds": censuses,
            "patientIds": [],
            "internalAccess": False,
        }

    if role == "facility_admin":
        facilities = claims.get("facilities") or []
        if not facilities:
            # Empty facility scope = "all facilities in client" per JWT
            # claim conventions; use the cheap client-wide query.
            return {
                "pattern": "by-client",
                "clientId": actor_client,
                "facilityIds": [],
                "censusIds": [],
                "patientIds": [],
                "internalAccess": False,
            }
        # With explicit facilities, the cheapest path is still client-wide
        # query + post-filter on facilityId (avoids GSI fan-out per facility
        # when there's no by-facility GSI on Patients). For MVP scale this
        # is fine; revisit if facility_admin scopes get large or noisy.
        return {
            "pattern": "by-client",
            "clientId": actor_client,
            "facilityIds": facilities,
            "censusIds": [],
            "patientIds": [],
            "internalAccess": False,
        }

    if role in {"client_admin", "household_owner"}:
        return {
            "pattern": "by-client",
            "clientId": actor_client,
            "facilityIds": [],
            "censusIds": [],
            "patientIds": [],
            "internalAccess": False,
        }

    # Unknown role: no data.
    return {
        "pattern": "no-data",
        "clientId": actor_client,
        "facilityIds": [],
        "censusIds": [],
        "patientIds": [],
        "internalAccess": False,
    }

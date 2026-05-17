"""
API stub handler — Phase 2A-0 foundation smoke endpoint.

Implements `GET /api/v1/me`: reads the JWT claims that API Gateway's
Cognito authorizer passed through and returns them as the response body.
This is the simplest possible endpoint that exercises the entire
2A-0 pipeline:

  client → WAF → API Gateway → JWT authorizer → handler → audit
  middleware → emit_audit → audit-forwarder → audit log group → S3

If `/me` works end-to-end (T3 of phase-2a-foundation.md), the foundation
is sound for the downstream subsets (2A-DL, 2A-RD, 2A-AA, ...).

The endpoint is also a useful smoke for the operator: hit `/me` with
a token and confirm the Pre-Token Generation Lambda is injecting all
four custom claims correctly.
"""

from __future__ import annotations

from typing import Any

from _shared.api_audit import audit_middleware
from _shared.api_authz import extract_claims, is_internal, require_authenticated
from _shared.api_error import ok_response
from _shared.audit_catalog import AUDIT_AUTH_SESSION_READ


def _me_subject(api_event: dict[str, Any], response: dict[str, Any]) -> dict[str, Any]:
    """For /me, the actor and subject are the same user reading their own session."""
    claims = extract_claims(api_event)
    if not claims.get("userId"):
        return {}
    return {
        "userId": claims["userId"],
        "clientId": claims["clientId"],
    }


@audit_middleware(event=AUDIT_AUTH_SESSION_READ, subject_fn=_me_subject)
def handler(api_event: dict[str, Any], context: Any, claims: dict[str, Any]) -> dict[str, Any]:
    """
    GET /api/v1/me — mirrors the claims back to the caller.

    The audit_middleware decorator already extracted claims and passed
    them in as the third arg. We just shape the response.
    """
    require_authenticated(claims)

    body = {
        "userId": claims["userId"],
        "email": claims.get("email", ""),
        "clientId": claims["clientId"],
        "role": claims["role"],
        "facilities": claims["facilities"],
        "censuses": claims["censuses"],
        "internalAccess": is_internal(claims),
        "mfaEnrolled": claims["mfaEnrolled"],
    }
    return ok_response(body)

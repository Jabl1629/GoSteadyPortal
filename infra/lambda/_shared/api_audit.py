"""
Audit middleware decorator for API handlers — Phase 2A-0.

Wraps a handler function to automatically:

  1. Extract JWT claims from the API Gateway event (api_authz.extract_claims)
  2. Derive `actor` and `request_id` from claims + API Gateway context
  3. Call the handler; on success, emit the configured audit `event` name
     via Phase 1.7's emit_audit() (which the audit-forwarder routes to the
     dedicated audit log group → Firehose → S3)
  4. On ApiError, emit on the 403 and 500 paths only (per spec Q2 D2);
     skip 400/404/429 (caller-error patterns, not audit-worthy)
  5. On uncaught exception, emit `audit.handler.error` with redacted
     error type, then re-raise so API Gateway returns 500

The `action` is derived from the route's HTTP method:
  GET    → "read"
  POST   → "create"
  PATCH  → "update"
  PUT    → "update"
  DELETE → "delete"

Usage:

    from _shared.api_audit import audit_middleware
    from _shared.audit_catalog import AUDIT_DEVICE_ASSIGNED

    @audit_middleware(event=AUDIT_DEVICE_ASSIGNED)
    def provision_device(event, context, claims):
        ...
        return ok_response({...})
"""

from __future__ import annotations

import functools
from typing import Any, Callable

from .api_authz import enforce_internal_session_age, extract_claims, is_internal
from .api_error import ApiError, error_response
from .audit_catalog import AUDIT_HANDLER_ERROR, KNOWN_AUDIT_EVENTS
from .observability import emit_audit, get_logger


_METHOD_TO_ACTION = {
    "GET": "read",
    "POST": "create",
    "PATCH": "update",
    "PUT": "update",
    "DELETE": "delete",
    "HEAD": "read",
}


def _derive_action(event: dict[str, Any]) -> str:
    method = event.get("requestContext", {}).get("http", {}).get("method", "")
    return _METHOD_TO_ACTION.get(method.upper(), "read")


def _request_id(event: dict[str, Any]) -> str:
    return event.get("requestContext", {}).get("requestId", "")


def _actor_from_claims(claims: dict[str, Any]) -> dict[str, Any]:
    """Build the audit `actor` from JWT claims. Falls back to `system` if unauthenticated."""
    if not claims.get("userId"):
        return {"system": "api-gateway-unauthenticated"}
    return {
        "userId": claims["userId"],
        "role": claims["role"],
        "clientId": claims["clientId"],
    }


def audit_middleware(
    event: str,
    *,
    subject_fn: Callable[[dict[str, Any], dict[str, Any]], dict[str, Any]] | None = None,
) -> Callable[..., Any]:
    """
    Decorator factory.

    Args:
      event: The audit event name. Should be one of the constants in
             audit_catalog.py — typo'd names log a warning at emit time.
      subject_fn: Optional callable that takes (event_dict, response_dict)
                  and returns the audit `subject` dict. If omitted,
                  subject defaults to {} (handler can also emit a
                  supplementary audit event manually with full subject).
    """

    if event not in KNOWN_AUDIT_EVENTS:
        # Don't fail import — handlers may reference event names that
        # haven't been added to the catalog yet during development.
        # Warn at decorator-application time so the import surfaces it.
        get_logger().warning("audit_middleware: unknown event name", extra={"event": event})

    def decorator(handler: Callable[..., dict[str, Any]]) -> Callable[..., dict[str, Any]]:
        @functools.wraps(handler)
        def wrapped(api_event: dict[str, Any], context: Any) -> dict[str, Any]:
            claims = extract_claims(api_event)
            actor = _actor_from_claims(claims)
            request_id = _request_id(api_event)
            action = _derive_action(api_event)

            try:
                # Internal-tier session absolute-cap (2A-0 Q8): for
                # internal_* roles, reject if the token's iat claim is
                # > 4 h old. No-op for customer roles. Raises ApiError(401)
                # which the existing except clause below handles uniformly.
                enforce_internal_session_age(claims)
                response = handler(api_event, context, claims)
            except ApiError as exc:
                # Emit audit on 403 and 500 only; skip 400/404/429.
                if exc.status in {403, 500}:
                    emit_audit(
                        event=event,
                        actor=actor,
                        subject={} if subject_fn is None else _safe_subject(subject_fn, api_event, {}),
                        action=action,
                        extra={"error_code": exc.code, "status": exc.status},
                        request_id=request_id,
                    )
                return error_response(
                    code=exc.code,
                    message=exc.message,
                    status=exc.status,
                    details=exc.details,
                )
            except Exception as exc:
                # Uncaught exceptions: log full trace to handler log group,
                # emit a redacted audit event, re-raise so Lambda surfaces
                # the error (which API Gateway converts to 500).
                get_logger().exception(
                    "handler_uncaught_exception",
                    extra={"request_id": request_id, "event_name": event},
                )
                emit_audit(
                    event=AUDIT_HANDLER_ERROR,
                    actor=actor,
                    subject={"originatingEvent": event},
                    action=action,
                    extra={
                        "error_type": type(exc).__name__,
                        # Don't include exc.args verbatim — could contain PII.
                        # The exception trace is in the handler log group;
                        # the request_id ties the audit entry to that trace.
                    },
                    request_id=request_id,
                )
                raise

            # Success path: derive subject from response and emit.
            subject = (
                {} if subject_fn is None else _safe_subject(subject_fn, api_event, response)
            )
            emit_audit(
                event=event,
                actor=actor,
                subject=subject,
                action=action,
                request_id=request_id,
            )
            return response

        return wrapped

    return decorator


def _safe_subject(
    fn: Callable[[dict[str, Any], dict[str, Any]], dict[str, Any]],
    api_event: dict[str, Any],
    response: dict[str, Any],
) -> dict[str, Any]:
    """Call subject_fn and swallow any exception — bad subject shouldn't break the response."""
    try:
        result = fn(api_event, response)
        return result if isinstance(result, dict) else {}
    except Exception:
        get_logger().exception("subject_fn_raised; emitting empty subject")
        return {}

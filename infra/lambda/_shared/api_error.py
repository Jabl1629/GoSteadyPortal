"""
Shared API error envelope + ApiError exception class — Phase 2A-0.

Every Phase 2A handler raises ApiError instead of returning ad-hoc error
shapes; the audit_middleware decorator (api_audit.py) catches ApiError
and produces the standard envelope. Direct callers (handlers that opt
out of the middleware for some reason) can use error_response()
themselves.

Envelope shape (per phase-2a-foundation.md L7):

    {
      "error": {
        "code":    "<UPPER_SNAKE>",
        "message": "<human-readable>",
        "details": { ... } | null
      }
    }
"""

from __future__ import annotations

import json
from typing import Any


class ApiError(Exception):
    """
    Raised from handlers to short-circuit with a structured error response.

    `code` is the machine-readable category (UPPER_SNAKE_CASE, surfaced
    to the Flutter UI). `message` is a human-readable explanation.
    `details` is an optional dict with caller-specific extra context
    (e.g., the missing JWT claim name on a 403, or the device's current
    status on a 409). `status` is the HTTP status code.
    """

    def __init__(
        self,
        code: str,
        message: str,
        status: int,
        details: dict[str, Any] | None = None,
    ) -> None:
        super().__init__(f"{code}: {message}")
        self.code = code
        self.message = message
        self.status = status
        self.details = details


def error_response(
    code: str,
    message: str,
    status: int,
    details: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """
    Produce an API Gateway proxy-integration response with the standard
    error envelope.
    """
    body: dict[str, Any] = {
        "error": {
            "code": code,
            "message": message,
            "details": details,
        },
    }
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body),
    }


def ok_response(body: dict[str, Any] | list[Any], status: int = 200) -> dict[str, Any]:
    """Successful API Gateway proxy-integration response."""
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body, default=str),
    }

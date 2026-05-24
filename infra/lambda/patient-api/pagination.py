"""
Cursor-based pagination helpers — Phase 2A-RD.

Opaque base64-encoded JSON of DDB's `LastEvaluatedKey`. The client
round-trips the cursor unmodified; we encode/decode + validate shape on
each call. No server-side state.

Per spec L7:
  - Default page size: 50
  - Max page size: 200
  - End of results: nextCursor = null
"""

from __future__ import annotations

import base64
import json
from typing import Any

from _shared.api_error import ApiError

DEFAULT_PAGE_SIZE = 50
MAX_PAGE_SIZE = 200


def parse_page_size(raw: str | None, *, default: int = DEFAULT_PAGE_SIZE,
                    maximum: int = MAX_PAGE_SIZE) -> int:
    """
    Parse `?pageSize=N` query param. Caps at `maximum` (200 default).
    Invalid → returns default rather than 400; pageSize is convenience,
    not safety-critical.
    """
    if raw is None or raw == "":
        return default
    try:
        n = int(raw)
    except (TypeError, ValueError):
        return default
    if n <= 0:
        return default
    return min(n, maximum)


def encode_cursor(last_evaluated_key: dict[str, Any] | None) -> str | None:
    """DDB LastEvaluatedKey → opaque base64 cursor. None → None."""
    if not last_evaluated_key:
        return None
    raw = json.dumps(last_evaluated_key, default=str, separators=(",", ":"))
    return base64.urlsafe_b64encode(raw.encode("utf-8")).decode("ascii")


def decode_cursor(cursor: str | None) -> dict[str, Any] | None:
    """
    Opaque cursor → DDB ExclusiveStartKey. None/empty → None.

    Raises ApiError(400 INVALID_CURSOR) on malformed input. The client
    is expected to round-trip cursors unmodified; if we see a malformed
    one, something is wrong on the caller's side (or a stale cursor
    after a major schema change).
    """
    if cursor is None or cursor == "":
        return None
    try:
        raw = base64.urlsafe_b64decode(cursor.encode("ascii")).decode("utf-8")
        parsed = json.loads(raw)
    except (ValueError, UnicodeDecodeError, base64.binascii.Error) as exc:
        raise ApiError(
            code="INVALID_CURSOR",
            message="Cursor token is malformed",
            status=400,
            details={"reason": type(exc).__name__},
        )
    if not isinstance(parsed, dict):
        raise ApiError(
            code="INVALID_CURSOR",
            message="Cursor token must encode a JSON object",
            status=400,
        )
    return parsed

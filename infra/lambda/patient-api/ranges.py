"""
Activity range translation — Phase 2A-RD.

Accepts `range=24h|7d|30d` (per spec L6) and returns the (window_start,
window_end) ISO 8601 UTC tuple suitable for a DDB SK BETWEEN query
against Activity Series (PK=patientId, SK=session_end UTC ISO 8601).

Default range when omitted: `24h`.
"""

from __future__ import annotations

import time
from datetime import datetime, timedelta, timezone

from _shared.api_error import ApiError

ALLOWED_RANGES = ("24h", "7d", "30d")
DEFAULT_RANGE = "24h"

_RANGE_TO_TIMEDELTA = {
    "24h": timedelta(hours=24),
    "7d": timedelta(days=7),
    "30d": timedelta(days=30),
}


def parse_range(raw: str | None) -> str:
    """
    Validate the `?range=` query param. Returns the canonical string
    (one of ALLOWED_RANGES). Raises ApiError(400 INVALID_RANGE) on
    anything outside the accepted set. Empty/None → DEFAULT_RANGE.
    """
    if raw is None or raw == "":
        return DEFAULT_RANGE
    if raw not in ALLOWED_RANGES:
        raise ApiError(
            code="INVALID_RANGE",
            message=f"range must be one of {list(ALLOWED_RANGES)}",
            status=400,
            details={
                "received": raw,
                "allowed": list(ALLOWED_RANGES),
                "suggestion": "For ranges >30d, use the daily-rollup endpoint (Phase 1C, planned)",
            },
        )
    return raw


def range_to_window(
    range_str: str,
    *,
    now: datetime | None = None,
) -> tuple[str, str]:
    """
    Translate range string to (window_start_iso, window_end_iso) UTC ISO 8601.

    `now` is injectable for testing; default is wall-clock UTC.

    Both bounds are inclusive; SK BETWEEN start AND end on Activity Series
    will return every session_end in the window.
    """
    end = now or datetime.now(timezone.utc)
    delta = _RANGE_TO_TIMEDELTA.get(range_str)
    if delta is None:
        # Defensive — parse_range should have caught this.
        raise ApiError(
            code="INVALID_RANGE",
            message=f"Unknown range '{range_str}'",
            status=400,
        )
    start = end - delta
    return _iso(start), _iso(end)


def _iso(dt: datetime) -> str:
    """UTC ISO 8601 with trailing Z, second precision (matches firmware's session_end)."""
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    else:
        dt = dt.astimezone(timezone.utc)
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


def now_iso() -> str:
    """Shared `now()` helper for handlers (epoch-second precision UTC ISO 8601)."""
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())

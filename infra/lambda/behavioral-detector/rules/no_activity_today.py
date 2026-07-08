"""
"No activity today" rule — Phase 1C-slim, spec L8.

Triggers at facility-local 09:00 (configurable per spec D6 — gives
breakfast/morning-activity time to land before flagging). Fires alert
if:
  - sum(activeMinutes) over [local-midnight, local-09:00] == 0
  - AND device lastSeen < 24h ago (device is alive but not moving;
    if it's been silent >24h, device_silent rule handles it instead)

Re-keyed onto activeMinutes (DT-4 WS2): activeMinutes is the universal
cross-type metric; steps is walker-only and a rollator produces none, so
the steps-keyed check mis-fired CRITICAL every morning on rollators.

Severity: CRITICAL — the most operationally-important behavioral signal
per user-needs US-22.

Pure function: takes pre-filtered activity rows + device state + the
trigger time. No DDB, no clock.
"""

from __future__ import annotations

from typing import Any, Optional

from .types import (
    ALERT_NO_ACTIVITY_TODAY,
    SEVERITY_CRITICAL,
    SOURCE_BEHAVIORAL,
    AlertCandidate,
)


def evaluate(
    *,
    activity_rows_today: list[dict[str, Any]],
    device_last_seen_epoch: Optional[int],
    now_epoch: int,
    local_now_iso: str,
    check_local_hour: int = 9,
) -> Optional[AlertCandidate]:
    """
    Evaluate the rule against pre-resolved inputs.

    Args:
      activity_rows_today: Activity Series rows for the patient with
        sessionEnd in [local-midnight, local-now]. activeMinutes summed
        across.
      device_last_seen_epoch: Device Registry lastSeen in epoch seconds,
        or None if never seen.
      now_epoch: current epoch seconds (caller-injected; tests pass
        deterministic values).
      local_now_iso: ISO 8601 in facility-local time (with tz offset).
        Used as the eventTimestamp on the alert.
      check_local_hour: the facility-local hour at which this rule fires
        (default 9, but the caller is already deciding "do we evaluate
        this rule now?" before calling — see facility_iterator).

    Returns:
      AlertCandidate if rule fires; None otherwise.
    """
    total_active_minutes = sum(int(row.get("activeMinutes", 0)) for row in activity_rows_today)
    if total_active_minutes > 0:
        return None

    # If device has been silent > 24h, defer to device_silent rule.
    if device_last_seen_epoch is None:
        return None
    hours_since_last_seen = (now_epoch - device_last_seen_epoch) / 3600
    if hours_since_last_seen >= 24:
        return None

    last_seen_str = _format_ago(now_epoch - device_last_seen_epoch)
    return AlertCandidate(
        alert_type=ALERT_NO_ACTIVITY_TODAY,
        severity=SEVERITY_CRITICAL,
        source=SOURCE_BEHAVIORAL,
        event_timestamp_iso=local_now_iso,
        data={
            "activeMinutesObservedBefore": 0,
            "lastDataReceivedAgo": last_seen_str,
            "checkLocalHour": check_local_hour,
            "sessionCount": len(activity_rows_today),
        },
    )


def _format_ago(seconds: int) -> str:
    """Human-readable elapsed-time string."""
    if seconds < 60:
        return f"{seconds}s"
    if seconds < 3600:
        return f"{seconds // 60}m"
    if seconds < 86400:
        h = seconds // 3600
        m = (seconds % 3600) // 60
        return f"{h}h {m}m" if m else f"{h}h"
    return f"{seconds // 86400}d"

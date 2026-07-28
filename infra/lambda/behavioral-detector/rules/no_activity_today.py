"""
"No activity today" rule — Phase 1C-slim, spec L8.

Triggers at facility-local 11:00 (configurable per spec D6 — gives
breakfast AND mid-morning activity time to land before flagging; was
09:00 through 2026-07, which flagged residents who simply had a slow
morning). Fires alert if:
  - sum(the device's PRIMARY metric) over [local-midnight, local-11:00] == 0
  - AND device lastSeen < 24h ago (device is alive but not moving;
    if it's been silent >24h, device_silent rule handles it instead)

Per-device-type primary metric (DT-4 WS2 no-regression): the rule keys on
`steps` for a walker — identical to the original steps rule, so a low-mobility
walker who took a few steps but summed < 1 active-minute does NOT trip a false
CRITICAL — and on `activeMinutes` for a rollator, which produces no steps (the
blunt DT-4 activeMinutes-only re-key mis-fired on exactly those low-activity
walkers). The caller passes `metric_field` from
device_types.primary_activity_metric.

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
    event_timestamp_iso: str,
    check_local_hour: int = 11,
    metric_field: str = "activeMinutes",
) -> Optional[AlertCandidate]:
    """
    Evaluate the rule against pre-resolved inputs.

    Args:
      activity_rows_today: Activity Series rows for the patient with
        sessionEnd in [local-midnight, local-now]. `metric_field` summed
        across.
      device_last_seen_epoch: Device Registry lastSeen in epoch seconds,
        or None if never seen.
      now_epoch: current epoch seconds (caller-injected; tests pass
        deterministic values).
      event_timestamp_iso: the facility-local DAY ANCHOR (midnight) in
        ISO 8601 with tz offset, from
        `history_window.local_day_anchor_iso`. Becomes the alert's
        eventTimestamp and so the day half of its sort key — constant
        for the whole local day, which is what makes the write a
        once-per-day guard.
      check_local_hour: the facility-local hour at which this rule fires
        (default 11, but the caller is already deciding "do we evaluate
        this rule now?" before calling — see facility_iterator). Reported
        in the alert payload only; it does not gate anything here.
      metric_field: the device's PRIMARY activity column (DT-4 WS2
        no-regression) — "steps" for a walker (identical to the pre-DT-4
        steps rule, so a walker who took steps but summed < 1 active-minute
        no longer trips a false CRITICAL), "activeMinutes" for a rollator
        (which produces no steps). The caller resolves this from the device
        type (device_types.primary_activity_metric); default keeps the
        activeMinutes behavior for callers that don't pass it.

    Returns:
      AlertCandidate if rule fires; None otherwise.
    """
    total_primary = sum(int(row.get(metric_field, 0) or 0) for row in activity_rows_today)
    if total_primary > 0:
        return None

    # If device has been silent > 24h, defer to device_silent rule.
    if device_last_seen_epoch is None:
        return None
    hours_since_last_seen = (now_epoch - device_last_seen_epoch) / 3600
    if hours_since_last_seen >= 24:
        return None

    last_seen_str = _format_ago(now_epoch - device_last_seen_epoch)
    total_active_minutes = sum(int(row.get("activeMinutes", 0) or 0) for row in activity_rows_today)
    return AlertCandidate(
        alert_type=ALERT_NO_ACTIVITY_TODAY,
        severity=SEVERITY_CRITICAL,
        source=SOURCE_BEHAVIORAL,
        event_timestamp_iso=event_timestamp_iso,
        data={
            "metric": metric_field,
            "activeMinutesObservedBefore": total_active_minutes,
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

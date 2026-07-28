"""
"Below typical activity" rule — Phase 1C-slim, spec L9.

Triggers at facility-local 22:00 (end-of-day). Fires alert if:
  - today.activeMinutes < threshold_pct * median7Day.activeMinutes  (default 70%)
  - AND patient has ≥ DEFAULT_MIN_HISTORY_DAYS_FOR_BEHAVIORAL days
    of history (cold-start guard per A3)
  - AND median7Day > 0 (avoid division by zero on never-active patients)

Severity: STANDARD.

Re-keyed onto activeMinutes (DT-4 WS2): activeMinutes is the universal
cross-type metric (works for walker + rollator). The 0.70 ratio is a
ratio of medians, so it carries over regardless of scale — no per-
deviceType override at MVP.

Note: demo's notification_engine used 65%. Spec D5 bumped to 70% to
reduce false-positives on day-to-day variance (day-of-week effects).
"""

from __future__ import annotations

import statistics
from typing import Any, Optional

from .types import (
    ALERT_BELOW_TYPICAL,
    DEFAULT_BELOW_TYPICAL_THRESHOLD_PCT,
    DEFAULT_MIN_HISTORY_DAYS_FOR_BEHAVIORAL,
    SEVERITY_STANDARD,
    SOURCE_BEHAVIORAL,
    AlertCandidate,
)


def evaluate(
    *,
    today_active_minutes: int,
    history_active_min_per_day: list[int],
    event_timestamp_iso: str,
    threshold_pct: float = DEFAULT_BELOW_TYPICAL_THRESHOLD_PCT,
    min_history_days: int = DEFAULT_MIN_HISTORY_DAYS_FOR_BEHAVIORAL,
) -> Optional[AlertCandidate]:
    """
    Args:
      today_active_minutes: sum of activeMinutes across today's activity
        rows (already aggregated by caller — keeps this fn pure).
      history_active_min_per_day: list of daily active-minute totals for
        the last 7 days (excluding today). Caller-built from Activity
        Series query + day-bucketing. Skipped (cold-start guard) if
        len < min_history_days.
      event_timestamp_iso: facility-local DAY ANCHOR (midnight), ISO 8601
        with tz offset — see `history_window.local_day_anchor_iso`. Becomes
        the alert's eventTimestamp / day half of its sort key.
      threshold_pct: e.g. 0.70 → fires if today < 0.70 × median7Day.
      min_history_days: minimum history before behavioral rules fire.

    Returns:
      AlertCandidate or None.
    """
    if len(history_active_min_per_day) < min_history_days:
        return None  # cold-start guard
    # Use ONLY the last 7 days of history (regardless of min_history_days).
    last_7 = history_active_min_per_day[-7:] if len(history_active_min_per_day) >= 7 else history_active_min_per_day
    if not last_7:
        return None
    median_7d = int(statistics.median(last_7))
    if median_7d <= 0:
        return None  # patient is normally inactive; no signal
    threshold = int(median_7d * threshold_pct)
    if today_active_minutes >= threshold:
        return None
    return AlertCandidate(
        alert_type=ALERT_BELOW_TYPICAL,
        severity=SEVERITY_STANDARD,
        source=SOURCE_BEHAVIORAL,
        event_timestamp_iso=event_timestamp_iso,
        data={
            "activeMinutesToday": today_active_minutes,
            "median7Day": median_7d,
            "thresholdPct": threshold_pct,
            "thresholdActiveMin": threshold,
            "historyDays": len(history_active_min_per_day),
        },
    )

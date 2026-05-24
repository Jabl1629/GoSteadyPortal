"""
"Below typical activity" rule — Phase 1C-slim, spec L9.

Triggers at facility-local 22:00 (end-of-day). Fires alert if:
  - today.steps < threshold_pct * median7Day.steps  (default 70%)
  - AND patient has ≥ DEFAULT_MIN_HISTORY_DAYS_FOR_BEHAVIORAL days
    of history (cold-start guard per A3)
  - AND median7Day > 0 (avoid division by zero on never-active patients)

Severity: STANDARD.

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
    today_steps: int,
    history_steps_per_day: list[int],
    local_now_iso: str,
    threshold_pct: float = DEFAULT_BELOW_TYPICAL_THRESHOLD_PCT,
    min_history_days: int = DEFAULT_MIN_HISTORY_DAYS_FOR_BEHAVIORAL,
) -> Optional[AlertCandidate]:
    """
    Args:
      today_steps: sum of steps across today's activity rows (already
        aggregated by caller — keeps this fn pure).
      history_steps_per_day: list of daily step counts for the last 7
        days (excluding today). Caller-built from Activity Series query
        + day-bucketing. Skipped (cold-start guard) if len < min_history_days.
      local_now_iso: ISO 8601 in facility-local time (with tz offset).
      threshold_pct: e.g. 0.70 → fires if today < 0.70 × median7Day.
      min_history_days: minimum history before behavioral rules fire.

    Returns:
      AlertCandidate or None.
    """
    if len(history_steps_per_day) < min_history_days:
        return None  # cold-start guard
    # Use ONLY the last 7 days of history (regardless of min_history_days).
    last_7 = history_steps_per_day[-7:] if len(history_steps_per_day) >= 7 else history_steps_per_day
    if not last_7:
        return None
    median_7d = int(statistics.median(last_7))
    if median_7d <= 0:
        return None  # patient is normally inactive; no signal
    threshold = int(median_7d * threshold_pct)
    if today_steps >= threshold:
        return None
    return AlertCandidate(
        alert_type=ALERT_BELOW_TYPICAL,
        severity=SEVERITY_STANDARD,
        source=SOURCE_BEHAVIORAL,
        event_timestamp_iso=local_now_iso,
        data={
            "stepsToday": today_steps,
            "median7Day": median_7d,
            "thresholdPct": threshold_pct,
            "thresholdSteps": threshold,
            "historyDays": len(history_steps_per_day),
        },
    )

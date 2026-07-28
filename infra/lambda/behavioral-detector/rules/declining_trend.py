"""
"Declining trend" rule — Phase 1C-slim, spec L10.

Triggers at facility-local 22:00 (same window as below_typical).
Fires alert if:
  - patient.median7Day.activeMinutes < threshold_pct × patient.medianPrior23Day.activeMinutes
    (default 85% — i.e., 7-day median dropped > 15% vs prior 23 days)
  - AND ≥ DEFAULT_MIN_HISTORY_DAYS_FOR_BEHAVIORAL days of history
  - AND both medians > 0

Severity: STANDARD. Behavioral signal — sustained downturn vs ~4-week baseline.

Re-keyed onto activeMinutes (DT-4 WS2): activeMinutes is the universal
cross-type metric (works for walker + rollator). The 0.85 ratio is a
ratio of medians, so it carries over regardless of scale — no per-
deviceType override at MVP.

Demo used 85% threshold; spec L10 carries it forward.
"""

from __future__ import annotations

import statistics
from typing import Any, Optional

from .types import (
    ALERT_DECLINING_TREND,
    DEFAULT_DECLINING_TREND_THRESHOLD_PCT,
    DEFAULT_MIN_HISTORY_DAYS_FOR_BEHAVIORAL,
    SEVERITY_STANDARD,
    SOURCE_BEHAVIORAL,
    AlertCandidate,
)


def evaluate(
    *,
    history_active_min_per_day: list[int],
    event_timestamp_iso: str,
    threshold_pct: float = DEFAULT_DECLINING_TREND_THRESHOLD_PCT,
    min_history_days: int = DEFAULT_MIN_HISTORY_DAYS_FOR_BEHAVIORAL,
) -> Optional[AlertCandidate]:
    """
    Args:
      history_active_min_per_day: ordered list of daily active-minute totals.
        Oldest first, most recent last. At least 30 days for the 7d-vs-prior-23d
        split to be meaningful. Caller-built; skipped (cold-start) if
        len < min_history_days.
      event_timestamp_iso: facility-local DAY ANCHOR (midnight), ISO 8601
        with tz offset — see `history_window.local_day_anchor_iso`. Becomes
        the alert's eventTimestamp / day half of its sort key.
      threshold_pct: e.g. 0.85 → fires if median7Day < 0.85 × medianPrior23Day.

    Returns:
      AlertCandidate or None.
    """
    if len(history_active_min_per_day) < min_history_days:
        return None  # cold-start guard
    # Need ≥30 days for the split. If between min_history and 30, abstain.
    if len(history_active_min_per_day) < 30:
        return None
    # Last 7 = recent window; prior 23 = baseline.
    last_7 = history_active_min_per_day[-7:]
    prior_23 = history_active_min_per_day[-30:-7]
    if not last_7 or not prior_23:
        return None
    median_7d = int(statistics.median(last_7))
    median_prior_23 = int(statistics.median(prior_23))
    if median_7d <= 0 or median_prior_23 <= 0:
        return None  # no meaningful baseline
    threshold = int(median_prior_23 * threshold_pct)
    if median_7d >= threshold:
        return None
    declinePct = round((1 - (median_7d / median_prior_23)) * 100, 1)
    return AlertCandidate(
        alert_type=ALERT_DECLINING_TREND,
        severity=SEVERITY_STANDARD,
        source=SOURCE_BEHAVIORAL,
        event_timestamp_iso=event_timestamp_iso,
        data={
            "median7Day": median_7d,
            "medianPrior23Day": median_prior_23,
            "thresholdPct": threshold_pct,
            "thresholdActiveMin": threshold,
            "declinePct": declinePct,
        },
    )

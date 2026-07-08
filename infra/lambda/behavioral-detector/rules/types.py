"""
Shared types for behavioral-detector rule modules — Phase 1C-slim.

Each rule is a pure function: takes inputs (activity rows, device state,
patient context, current time), returns Optional[AlertCandidate] or None.
No DDB, no clock, no env state — trivially unit-testable.

AlertCandidate is a value-only dataclass — the orchestrator (handler.py)
converts a fired candidate into the actual Alert History PutItem using
the existing 1B-rev pattern (compound SK, hierarchy snapshot, TTL).
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any


# Rule severity levels (mirrors firmware-emitted alerts + 1B-rev synthetic).
SEVERITY_CRITICAL = "critical"
SEVERITY_STANDARD = "standard"
SEVERITY_WARNING = "warning"

# Alert source attribution. Distinguishes from 1B-rev's `cloud` (battery/signal
# from Threshold Detector) and firmware-emitted `device`. Two new values for
# 1C-slim per spec L13.
SOURCE_BEHAVIORAL = "cloud-behavioral"  # No-activity / Below-typical / Declining-trend
SOURCE_OFFLINE = "cloud-offline"        # Device-offline / Device-silent


# Rule alertType constants. Each becomes the compound-SK suffix in Alert History
# (SK = `{eventTimestamp}#{alertType}`) and the natural dedupe key when paired
# with the once-per-day eventTimestamp roll.
ALERT_NO_ACTIVITY_TODAY = "no_activity_today"
ALERT_BELOW_TYPICAL = "below_typical_activity"
ALERT_DECLINING_TREND = "declining_trend"
ALERT_DEVICE_OFFLINE = "device_offline"
ALERT_DEVICE_SILENT = "device_silent"


@dataclass(frozen=True)
class AlertCandidate:
    """
    A rule's positive evaluation. Orchestrator-side handler converts this
    into the actual DDB row via _write_alert (mirrors Threshold Detector's
    _write_synthetic_alert pattern from 1B-rev).
    """
    alert_type: str
    severity: str
    source: str
    # ISO 8601 in facility-local time (with timezone offset). Becomes the
    # eventTimestamp on the Alert History row + half of the compound SK.
    # Per spec Q5: facility-local timestamp makes the alert naturally group
    # under the "today" the caregiver sees in the dashboard.
    event_timestamp_iso: str
    # Rule-specific snapshot data — what the caregiver needs to understand
    # the alert. Caller-built; e.g.:
    #   no_activity_today → {"activeMinutesObservedBefore": 0, "lastDataReceivedAgo": "1h 23m", "checkLocalHour": 9}
    #   below_typical     → {"activeMinutesToday": 50, "median7Day": 200, "thresholdPct": 0.70}
    #   device_offline    → {"lastSeenIso": "...", "hoursOffline": 3, "thresholdHours": 2}
    data: dict[str, Any] = field(default_factory=dict)


# Default rule thresholds — overridable per config env vars in handler.py.
# Sourced from phase-1c-slim-notifications.md §Configuration.

# Below-typical: today.activeMinutes < BELOW_TYPICAL_THRESHOLD_PCT * patient.median7Day
DEFAULT_BELOW_TYPICAL_THRESHOLD_PCT = 0.70

# Declining-trend: patient.median7Day < DECLINING_TREND_THRESHOLD_PCT * patient.medianPrior23Day
DEFAULT_DECLINING_TREND_THRESHOLD_PCT = 0.85

# Offline/silent rule windows (hours since lastSeen).
DEFAULT_OFFLINE_THRESHOLD_HOURS = 2
DEFAULT_SILENT_THRESHOLD_HOURS = 24

# Behavioral rules need a minimum history window before firing (cold-start guard
# per spec A3 — fresh patients don't have a meaningful baseline).
DEFAULT_MIN_HISTORY_DAYS_FOR_BEHAVIORAL = 14

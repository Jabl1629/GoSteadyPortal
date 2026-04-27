"""
Threshold constants + tier selection — Phase 1B revision L10 / D7.

Critical/low (battery) and lost/weak (signal) are mutually exclusive
per shadow update — only the most severe per dimension fires.
"""

from __future__ import annotations

# Battery thresholds (fraction 0..1) — ARCHITECTURE.md §8 / Phase 1B L10.
BATTERY_CRITICAL = 0.05
BATTERY_LOW = 0.10

# Signal thresholds (RSRP dBm) — nRF9151 datasheet + caregiver expectation.
RSRP_LOST = -120.0
RSRP_WEAK = -110.0


def determine_threshold_alerts(
    battery_pct: float | None,
    rsrp_dbm: float | None,
) -> list[tuple[str, str]]:
    """
    Returns [(alert_type, severity), ...] for the breaches present in the
    shadow update. At most one battery alert + one signal alert per call.
    """
    alerts: list[tuple[str, str]] = []
    if battery_pct is not None:
        if battery_pct < BATTERY_CRITICAL:
            alerts.append(("battery_critical", "critical"))
        elif battery_pct < BATTERY_LOW:
            alerts.append(("battery_low", "warning"))
    if rsrp_dbm is not None:
        if rsrp_dbm <= RSRP_LOST:
            alerts.append(("signal_lost", "warning"))
        elif rsrp_dbm <= RSRP_WEAK:
            alerts.append(("signal_weak", "info"))
    return alerts

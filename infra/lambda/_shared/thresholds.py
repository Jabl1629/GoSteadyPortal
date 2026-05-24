"""
Threshold constants + tier selection — Phase 1B revision L10 / D7;
Phase 2A-AA L7 added per-patient override merge.

Critical/low (battery) and lost/weak (signal) are mutually exclusive
per shadow update — only the most severe per dimension fires.
"""

from __future__ import annotations

from decimal import Decimal
from typing import Mapping

# Battery thresholds (fraction 0..1) — ARCHITECTURE.md §8 / Phase 1B L10.
BATTERY_CRITICAL = 0.05
BATTERY_LOW = 0.10

# Signal thresholds (RSRP dBm) — nRF9151 datasheet + caregiver expectation.
RSRP_LOST = -120.0
RSRP_WEAK = -110.0

# Allowed override range bounds — Phase 2A-AA L3. Server-side validation
# in alert-actions/thresholds_validation.py enforces these on PUT; this
# helper trusts the stored value (validation already happened).
DEFAULTS: dict[str, float] = {
    "batteryCritical": BATTERY_CRITICAL,
    "batteryLow": BATTERY_LOW,
    "rsrpLost": RSRP_LOST,
    "rsrpWeak": RSRP_WEAK,
}


def merge_thresholds(overrides: Mapping[str, float | Decimal | None] | None) -> dict[str, float]:
    """
    Field-by-field merge: defaults ⊕ overrides (per spec L7).
      - absent field in overrides → use default
      - field present + non-null → use override
      - field present + null → use default (explicit clear; can't happen in
        the stored map because the alert-actions writer REMOVEs cleared
        fields from the map, but accepted defensively here)
    DDB returns numbers as Decimal; coerce to float for arithmetic.
    """
    merged = dict(DEFAULTS)
    if not overrides:
        return merged
    for key in DEFAULTS:
        if key in overrides:
            val = overrides[key]
            if val is None:
                continue
            merged[key] = float(val)
    return merged


def determine_threshold_alerts(
    battery_pct: float | None,
    rsrp_dbm: float | None,
    *,
    overrides: Mapping[str, float | Decimal | None] | None = None,
) -> list[tuple[str, str]]:
    """
    Returns [(alert_type, severity), ...] for the breaches present in the
    shadow update. At most one battery alert + one signal alert per call.

    Per-patient overrides (Phase 2A-AA) are merged over defaults. Existing
    call sites that don't pass `overrides` get unchanged Phase 1B behavior.
    """
    t = merge_thresholds(overrides)
    alerts: list[tuple[str, str]] = []
    if battery_pct is not None:
        if battery_pct < t["batteryCritical"]:
            alerts.append(("battery_critical", "critical"))
        elif battery_pct < t["batteryLow"]:
            alerts.append(("battery_low", "warning"))
    if rsrp_dbm is not None:
        if rsrp_dbm <= t["rsrpLost"]:
            alerts.append(("signal_lost", "warning"))
        elif rsrp_dbm <= t["rsrpWeak"]:
            alerts.append(("signal_weak", "info"))
    return alerts

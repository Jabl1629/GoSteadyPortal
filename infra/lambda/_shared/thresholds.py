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

# Phase DT-0: defaults keyed by deviceType (memo Q3 / spec L6). The rollator
# inherits walker values — same board, same cell at bench; per-type values
# fork in DT-3 when cupholder production hardware exists. Unknown/absent
# type falls back to walker defaults (D9 legacy default).
DEFAULT_DEVICE_TYPE = "walker_cap"
DEFAULTS_BY_TYPE: dict[str, dict[str, float]] = {
    "walker_cap": DEFAULTS,
    "rollator_platform": DEFAULTS,
}


def merge_thresholds(
    overrides: Mapping[str, float | Decimal | None] | None,
    *,
    device_type: str | None = None,
) -> dict[str, float]:
    """
    Field-by-field merge: per-type defaults ⊕ per-patient overrides
    (spec L7; DT-0 adds the type keying — merge order: type defaults ←
    patient overrides).
      - absent field in overrides → use default
      - field present + non-null → use override
      - field present + null → use default (explicit clear; can't happen in
        the stored map because the alert-actions writer REMOVEs cleared
        fields from the map, but accepted defensively here)
    DDB returns numbers as Decimal; coerce to float for arithmetic.
    Callers that don't pass `device_type` get walker defaults (pre-DT-0
    behavior, unchanged).
    """
    base = DEFAULTS_BY_TYPE.get(device_type or DEFAULT_DEVICE_TYPE) or DEFAULTS
    merged = dict(base)
    if not overrides:
        return merged
    for key in base:
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
    device_type: str | None = None,
) -> list[tuple[str, str]]:
    """
    Returns [(alert_type, severity), ...] for the breaches present in the
    shadow update. At most one battery alert + one signal alert per call.

    Per-patient overrides (Phase 2A-AA) are merged over per-type defaults
    (Phase DT-0). Existing call sites that pass neither kwarg get unchanged
    Phase 1B behavior.
    """
    t = merge_thresholds(overrides, device_type=device_type)
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

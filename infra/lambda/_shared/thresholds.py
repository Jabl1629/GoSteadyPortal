"""
Threshold constants + tier selection — Phase 1B revision L10 / D7;
Phase 2A-AA L7 added per-patient override merge.

Critical/low (battery) and lost/weak (signal) are mutually exclusive
per shadow update — only the most severe per dimension fires.
"""

from __future__ import annotations

import os
from decimal import Decimal
from typing import Mapping


def _env_bool(name: str, default: bool) -> bool:
    raw = os.environ.get(name)
    if raw is None or raw == "":
        return default
    return raw.strip().lower() in ("1", "true", "yes", "on")


# ── Signal (RSRP) alerting: OFF by default (2026-07-28) ───────────────
#
# `signal_lost` / `signal_weak` were 35% of all prod alert rows and were
# not actionable: RSRP swings are a property of where the resident happens
# to be standing, and no caregiver action follows from "the cell signal
# dipped". A genuinely dark device is already covered — and covered better
# — by the behavioral-detector's `device_offline` (2h) / `device_silent`
# (24h) rules, which key on "we stopped hearing from it" rather than on a
# radio metric.
#
# Disabled as a FLAG rather than by deleting the rules: the thresholds,
# their per-patient override surface (Phase 2A-AA `rsrpLost`/`rsrpWeak`),
# the validation, and the dashboards all stay intact, so re-enabling is an
# env-var flip with no code change. Set `SIGNAL_ALERTS_ENABLED=true`.
#
# Both types move together on purpose. Disabling only `signal_lost` leaves
# a perverse gap: a device degrading PAST the -120 dBm lost threshold would
# stop alerting while a healthier -110 dBm device still alerted.
SIGNAL_ALERTS_ENABLED = _env_bool("SIGNAL_ALERTS_ENABLED", False)

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


def signal_alerts_enabled(override: bool | None = None) -> bool:
    """Resolve the signal-alerting flag. `None` → the module/env default
    (`SIGNAL_ALERTS_ENABLED`, off since 2026-07-28). Tests and callers pass
    an explicit bool."""
    return SIGNAL_ALERTS_ENABLED if override is None else override


def determine_threshold_alerts(
    battery_pct: float | None,
    rsrp_dbm: float | None,
    *,
    overrides: Mapping[str, float | Decimal | None] | None = None,
    device_type: str | None = None,
    signal_enabled: bool | None = None,
) -> list[tuple[str, str]]:
    """
    Returns [(alert_type, severity), ...] for the breaches present in the
    shadow update. At most one battery alert + one signal alert per call.

    Per-patient overrides (Phase 2A-AA) are merged over per-type defaults
    (Phase DT-0). Existing call sites that pass neither kwarg get unchanged
    Phase 1B behavior for BATTERY.

    Signal (`signal_lost` / `signal_weak`) is gated by `signal_enabled`,
    which defaults to the `SIGNAL_ALERTS_ENABLED` env flag — OFF as of
    2026-07-28 (see the note at the top of this module). When off, no
    signal breach is ever returned; battery is untouched.
    """
    t = merge_thresholds(overrides, device_type=device_type)
    alerts: list[tuple[str, str]] = []
    if battery_pct is not None:
        if battery_pct < t["batteryCritical"]:
            alerts.append(("battery_critical", "critical"))
        elif battery_pct < t["batteryLow"]:
            alerts.append(("battery_low", "warning"))
    if rsrp_dbm is not None and signal_alerts_enabled(signal_enabled):
        if rsrp_dbm <= t["rsrpLost"]:
            alerts.append(("signal_lost", "warning"))
        elif rsrp_dbm <= t["rsrpWeak"]:
            alerts.append(("signal_weak", "info"))
    return alerts

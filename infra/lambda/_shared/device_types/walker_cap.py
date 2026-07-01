"""
walker_cap product contract — Phase DT-0.

The original GoSteady smart walker cap. Validation + named-column promotion
moved verbatim from activity-processor/handler.py (Phase 1B-rev → 0.17.0-time
lineage); behavior is byte-identical for walker payloads.

Contract source of truth: ARCHITECTURE.md §7.1 (walker_cap activity schema).
"""

from __future__ import annotations

from decimal import Decimal
from typing import Any

TYPE = "walker_cap"

# Validation bounds — the goal is to reject obvious garbage, not second-
# guess on-device sensor fusion. (Moved from activity-processor.)
MAX_STEPS = 100_000
MAX_DISTANCE_FT = 50_000
MAX_ACTIVE_MIN = 1_440
# Gait speed (ft/s), 0.16.0-gait+. ~6 ft/s is brisk community ambulation;
# walker users are far slower. Cap generously at 10 (running) — out-of-range
# values drop just the field, not the whole row (it's optional).
MAX_GAIT_FTS = 10

REQUIRED_ACTIVITY_METRICS = ("steps", "distance_ft", "active_min")

# Per-type metric fields excluded from the `extras` catch-all (the handler
# unions these with its universal envelope field set).
ACTIVITY_NAMED_FIELDS = frozenset(
    {
        "steps",
        "distance_ft",
        "active_min",
        "roughness_R",
        "surface_class",
        "gait_speed_fts",
    }
)

ALLOWED_SURFACE_CLASS = {"indoor", "outdoor"}

# Device-originated alert enum (ARCHITECTURE §7 alert contract). The cap
# doesn't publish alerts in v1, but the channel contract is defined.
VALID_ALERT_TYPES = frozenset({"tipover", "fall", "impact"})


def validate_activity_metrics(event: dict) -> tuple[bool, str]:
    """Presence + range checks on the required walker metrics. Timestamps are
    resolved (never rejected) by _shared.device_time upstream of this."""
    for f in REQUIRED_ACTIVITY_METRICS:
        if f not in event:
            return False, f"missing:{f}"
    try:
        steps = int(event["steps"])
        distance = float(event["distance_ft"])
        active = int(event["active_min"])
    except (TypeError, ValueError) as e:
        return False, f"bad_number:{e}"
    if not 0 <= steps <= MAX_STEPS:
        return False, f"steps_out_of_range:{steps}"
    if not 0 <= distance <= MAX_DISTANCE_FT:
        return False, f"distance_out_of_range:{distance}"
    if not 0 <= active <= MAX_ACTIVE_MIN:
        return False, f"active_out_of_range:{active}"
    return True, "ok"


def build_metric_attrs(event: dict) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    """
    DDB-ready named-column promotion for a validated walker payload.
    Returns (attrs, warnings). Optional analytic fields are dropped (never
    fail the row) when unparseable / out of range — out-of-range and
    unknown-enum drops surface as warning dicts for the caller to log,
    preserving the pre-DT-0 `unknown_surface_class` / `gait_out_of_range`
    log lines.
    """
    warnings: list[dict[str, Any]] = []
    attrs: dict[str, Any] = {
        "steps": int(event["steps"]),
        "distanceFt": Decimal(str(event["distance_ft"])),
        "activeMinutes": int(event["active_min"]),
    }

    surface_class = event.get("surface_class")
    if surface_class is not None and surface_class not in ALLOWED_SURFACE_CLASS:
        warnings.append({"warning": "unknown_surface_class", "surface_class": surface_class})
        surface_class = None
    if surface_class is not None:
        attrs["surfaceClass"] = surface_class

    # Gait speed (ft/s) — optional (0.16.0-gait+). Firmware omits it when its
    # on-device guards fail. Drop just the field if unparseable / out of range.
    gait_fts = event.get("gait_speed_fts")
    if gait_fts is not None:
        try:
            gait_fts = float(gait_fts)
        except (TypeError, ValueError):
            gait_fts = None
        else:
            if not 0.0 <= gait_fts <= MAX_GAIT_FTS:
                warnings.append({"warning": "gait_out_of_range", "gait_speed_fts": gait_fts})
                gait_fts = None
    if gait_fts is not None:
        attrs["gaitSpeedFts"] = Decimal(str(gait_fts))

    if "roughness_R" in event:
        attrs["roughnessR"] = Decimal(str(event["roughness_R"]))

    return attrs, warnings

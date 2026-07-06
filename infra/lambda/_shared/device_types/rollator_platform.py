"""
rollator_platform product contract — Phase DT-0 (bench v0) + distance/gait
promotion (2026-07-06, docs/specs/2026-07-06-rollator-distance-cloud-promotion.md).

The rollator accessory-platform device (first SKU: cupholder). Same board
(Thingy:91 X / nRF9151), different firmware + outputs.

METRIC CONTRACT: `active_min` is the only REQUIRED activity metric (it derives
from the shared motion-gate platform code). As of firmware rol-0.1.0-ww (coord
§C52) the rollator also emits `distance_ft` + `gait_speed_fts` from its
wheel-vibration odometer — both OPTIONAL and confidence-gated (firmware omits
them when it can't produce a valid estimate, e.g. a stationary session with no
rolling motion), and both promoted to named columns here. They are within-
resident TREND metrics (~26-31% MAPE), not precise odometry.

The rollator does NOT produce `steps` — a frame-mount IMU is wheel-vibration-
dominated with no lift-and-place impulses (coord §C52.2). A stray `steps` value
is NOT promoted; it stays in the row's `extras` map (D16 accept-all is Core
Contract). This is the memo-D10 amendment (the original target was walker-cap
parity *including* steps).

No device-originated alerts in v1 (memo Q11) — the enum is empty, so any alert
publish from a rollator rejects as `bad_alert_type` (visible via the
alert_reject metric).
"""

from __future__ import annotations

from decimal import Decimal
from typing import Any

TYPE = "rollator_platform"

MAX_ACTIVE_MIN = 1_440
# distance_ft / gait_speed_fts bounds reuse the walker values (same physical
# quantities) — out-of-range drops just the (optional) field, never the row.
MAX_DISTANCE_FT = 50_000
MAX_GAIT_FTS = 10

REQUIRED_ACTIVITY_METRICS = ("active_min",)

# Per-type additions to the `extras` exclusion set (the handler unions these
# with its universal envelope fields). distance_ft/gait_speed_fts are optional
# but named so a present value lands in a column instead of `extras`.
ACTIVITY_NAMED_FIELDS = frozenset({"active_min", "distance_ft", "gait_speed_fts"})

# Memo Q11: none in v1. Candidates at DT-4 launch planning: rollaway /
# brake-state (a wheeled frame tips differently than a walker).
VALID_ALERT_TYPES: frozenset[str] = frozenset()


def validate_activity_metrics(event: dict) -> tuple[bool, str]:
    """Presence + range check on the only required rollator metric (active_min).
    distance_ft/gait_speed_fts are optional — absence is valid; when present they
    are range-checked (drop-on-invalid) in build_metric_attrs, not here."""
    for f in REQUIRED_ACTIVITY_METRICS:
        if f not in event:
            return False, f"missing:{f}"
    try:
        active = int(event["active_min"])
    except (TypeError, ValueError) as e:
        return False, f"bad_number:{e}"
    if not 0 <= active <= MAX_ACTIVE_MIN:
        return False, f"active_out_of_range:{active}"
    return True, "ok"


def build_metric_attrs(event: dict) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    """DDB-ready named-column promotion for a validated rollator payload.
    Returns (attrs, warnings). `active_min` is required (promoted
    unconditionally); `distance_ft` + `gait_speed_fts` are optional (rol-0.1.0-ww
    / §C52) and use the drop-on-invalid pattern — present → parse → range-check →
    promote, else drop the field (with a warning for out-of-range) and never fail
    the row. Mirrors the walker cap's optional-gait handling."""
    warnings: list[dict[str, Any]] = []
    attrs: dict[str, Any] = {"activeMinutes": int(event["active_min"])}

    # Distance (ft) — optional; firmware omits it when the vibration odometer
    # can't produce a valid estimate (e.g. no rolling motion → valid=0).
    dist = event.get("distance_ft")
    if dist is not None:
        try:
            dist = float(dist)
        except (TypeError, ValueError):
            dist = None
        else:
            if not 0.0 <= dist <= MAX_DISTANCE_FT:
                warnings.append({"warning": "distance_out_of_range", "distance_ft": dist})
                dist = None
    if dist is not None:
        attrs["distanceFt"] = Decimal(str(dist))

    # Gait speed (ft/s) — optional; same confidence-gating + drop-on-invalid as
    # the walker cap (0.16.0-gait+).
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

    return attrs, warnings

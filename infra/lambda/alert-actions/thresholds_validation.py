"""
Per-patient threshold-overrides validation — Phase 2A-AA.

Pure functions. Range bounds + ordering constraints per spec L3.
Unit-testable without boto3.
"""

from __future__ import annotations

from typing import Any

from _shared.api_error import ApiError
from _shared.thresholds import DEFAULTS

# Spec L3:
#   batteryCritical ∈ [0.02, 0.30]
#   batteryLow      ∈ (batteryCritical, 0.50]
#   rsrpLost        ∈ [-140, -100]
#   rsrpWeak        ∈ (rsrpLost, -80]
ALLOWED_RANGES: dict[str, tuple[float, float]] = {
    "batteryCritical": (0.02, 0.30),
    "batteryLow": (0.02, 0.50),  # ordering vs batteryCritical also enforced
    "rsrpLost": (-140.0, -100.0),
    "rsrpWeak": (-140.0, -80.0),  # ordering vs rsrpLost also enforced
}

ALLOWED_FIELDS = frozenset(ALLOWED_RANGES.keys())


def validate_thresholds_patch(body: dict[str, Any]) -> dict[str, float | None]:
    """
    Validate a PUT /patients/{id}/thresholds request body.

    Allowed shape: any subset of ALLOWED_FIELDS. Each value is either:
      - a number within ALLOWED_RANGES, OR
      - null (explicit clear → revert that field to default)

    Returns a normalized dict mapping each present field to either a
    float or None. Raises ApiError(400 INVALID_THRESHOLD) on any
    violation; the error details enumerate ALL violations in one
    response (caller gets a complete picture, not whack-a-mole).
    """
    if not isinstance(body, dict):
        raise ApiError(
            code="INVALID_REQUEST",
            message="thresholds body must be a JSON object",
            status=400,
        )

    # Reject unknown fields up front
    unknown = set(body.keys()) - ALLOWED_FIELDS
    if unknown:
        raise ApiError(
            code="INVALID_THRESHOLD",
            message=f"unknown threshold field(s): {sorted(unknown)}",
            status=400,
            details={"unknown": sorted(unknown), "allowed": sorted(ALLOWED_FIELDS)},
        )

    normalized: dict[str, float | None] = {}
    violations: list[dict[str, Any]] = []

    for field, raw in body.items():
        if raw is None:
            normalized[field] = None
            continue
        if not isinstance(raw, (int, float)):
            violations.append({
                "field": field,
                "reason": "not_a_number",
                "received": repr(raw)[:50],
            })
            continue
        val = float(raw)
        lo, hi = ALLOWED_RANGES[field]
        if val < lo or val > hi:
            violations.append({
                "field": field,
                "reason": "out_of_range",
                "received": val,
                "allowed": [lo, hi],
            })
            continue
        normalized[field] = val

    # Ordering: batteryLow must be strictly > batteryCritical;
    # rsrpWeak must be strictly > rsrpLost. Use the EFFECTIVE values
    # (i.e., merge proposed overrides over current defaults to evaluate).
    # The caller is expected to have already loaded the current row to
    # compute effective values; here we only check the proposed body's
    # internal consistency when BOTH fields are present in the body.
    if (
        "batteryCritical" in normalized and "batteryLow" in normalized
        and normalized["batteryCritical"] is not None
        and normalized["batteryLow"] is not None
        and normalized["batteryLow"] <= normalized["batteryCritical"]
    ):
        violations.append({
            "field": "batteryLow",
            "reason": "must_be_greater_than_batteryCritical",
            "received": normalized["batteryLow"],
            "batteryCritical": normalized["batteryCritical"],
        })
    if (
        "rsrpLost" in normalized and "rsrpWeak" in normalized
        and normalized["rsrpLost"] is not None
        and normalized["rsrpWeak"] is not None
        and normalized["rsrpWeak"] <= normalized["rsrpLost"]
    ):
        violations.append({
            "field": "rsrpWeak",
            "reason": "must_be_greater_than_rsrpLost",
            "received": normalized["rsrpWeak"],
            "rsrpLost": normalized["rsrpLost"],
        })

    if violations:
        raise ApiError(
            code="INVALID_THRESHOLD",
            message=f"{len(violations)} threshold validation error(s)",
            status=400,
            details={"violations": violations},
        )

    return normalized


def validate_ordering_against_effective(
    proposed: dict[str, float | None],
    existing_overrides: dict[str, Any] | None,
) -> None:
    """
    Second-pass ordering check that considers the EFFECTIVE state after
    applying `proposed` on top of `existing_overrides` on top of defaults.

    Catches cases like: existing override sets batteryCritical=0.20,
    PUT only sets batteryLow=0.15 (low <= critical after merge). The
    first-pass body check misses this because it only sees one field.
    """
    effective = dict(DEFAULTS)
    if existing_overrides:
        for k in DEFAULTS:
            if k in existing_overrides and existing_overrides[k] is not None:
                effective[k] = float(existing_overrides[k])
    for k, v in proposed.items():
        if v is None:
            effective[k] = DEFAULTS[k]
        else:
            effective[k] = v

    violations: list[dict[str, Any]] = []
    if effective["batteryLow"] <= effective["batteryCritical"]:
        violations.append({
            "field": "batteryLow",
            "reason": "effective_must_be_greater_than_batteryCritical",
            "effective": effective["batteryLow"],
            "batteryCritical": effective["batteryCritical"],
        })
    if effective["rsrpWeak"] <= effective["rsrpLost"]:
        violations.append({
            "field": "rsrpWeak",
            "reason": "effective_must_be_greater_than_rsrpLost",
            "effective": effective["rsrpWeak"],
            "rsrpLost": effective["rsrpLost"],
        })
    if violations:
        raise ApiError(
            code="INVALID_THRESHOLD",
            message=(
                f"{len(violations)} effective-state ordering violation(s) "
                "after merging proposed overrides with existing"
            ),
            status=400,
            details={"violations": violations, "effective_after_merge": effective},
        )

"""
rollator_platform product contract — Phase DT-0 (bench v0).

The rollator accessory-platform device (first SKU: cupholder). Same board
(Thingy:91 X / nRF9151), different firmware + outputs.

BENCH v0 CONTRACT (memo D10 / spec L6): `active_min` is the only required
activity metric — it derives from the shared motion-gate platform code and
works from the first firmware build. `steps` / `distance_ft` /
`gait_speed_fts` arrive with the DT-2 capture→algo→train arc, at which
point this module's required set converges to walker-cap parity. Until
then, any provisional metrics the firmware emits flow into the row's
`extras` map (D16 accept-all is Core Contract).

No device-originated alerts in v1 (memo Q11) — the enum is empty, so any
alert publish from a rollator rejects as `bad_alert_type` (visible via the
alert_reject metric).
"""

from __future__ import annotations

from typing import Any

TYPE = "rollator_platform"

MAX_ACTIVE_MIN = 1_440

REQUIRED_ACTIVITY_METRICS = ("active_min",)

ACTIVITY_NAMED_FIELDS = frozenset({"active_min"})

# Memo Q11: none in v1. Candidates at DT-4 launch planning: rollaway /
# brake-state (a wheeled frame tips differently than a walker).
VALID_ALERT_TYPES: frozenset[str] = frozenset()


def validate_activity_metrics(event: dict) -> tuple[bool, str]:
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
    """Bench v0: promote `activeMinutes` only. Everything else the firmware
    sends lands in `extras` until the DT-2 parity set is locked."""
    return {"activeMinutes": int(event["active_min"])}, []

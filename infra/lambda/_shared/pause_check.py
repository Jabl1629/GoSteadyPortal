"""
Notifications-pause checker — Phase 2A-UM-P.

Pure-function helpers consumed by:
  - patient-mgmt: when caregivers set / clear pause, plus GET responses
    that surface the current pause state to the portal.
  - threshold-detector (Phase 1B-rev, repurposed): skip evaluation when
    a patient is paused; emit a sampled `suppressed_paused` audit.
  - activity-processor (Phase 1B-rev, repurposed): auto-resume the pause
    when fresh activity arrives ("the reason for pausing is gone" per
    user-needs US-31).
  - behavioral-detector (Phase 1C-slim — see phase-1c-slim-notifications.md):
    same suppression pattern as threshold-detector.

`Patient.notificationsPaused` schema (set by patient-mgmt):
    {
      "until":    <int: epoch seconds — pause expires at this time>,
      "reason":   "in_hospital" | "at_rehab" | "family_visit_offsite" | "on_vacation" | "other",
      "pausedAt": <int: epoch seconds — when pause was set>,
      "pausedBy": "<userId>"
    }

Absence of the attribute = "not currently paused" (the natural default).

All helpers take a `now_fn` callable so unit tests can inject deterministic
times without monkey-patching `time.time()`.
"""

from __future__ import annotations

import time
from typing import Any, Callable, Optional


# ── Public API ────────────────────────────────────────────────────────


def is_currently_paused(
    patient: dict[str, Any],
    *,
    now_fn: Callable[[], float] = time.time,
) -> bool:
    """
    True iff the patient has an active pause whose `until` is in the future.

    Returns False for any of: attribute absent; attribute not a dict;
    `until` missing / unparseable / ≤ 0; `until` ≤ now.

    Args:
      patient: a DDB-shaped Patient row dict. Tolerant of missing keys.
      now_fn:  injectable now-source for tests.
    """
    paused = patient.get("notificationsPaused")
    if not isinstance(paused, dict):
        return False
    until = _to_epoch_int(paused.get("until"))
    if until <= 0:
        return False
    return until > int(now_fn())


def seconds_remaining(
    patient: dict[str, Any],
    *,
    now_fn: Callable[[], float] = time.time,
) -> Optional[int]:
    """
    Seconds until the pause expires, or None if not currently paused.
    Always ≥ 0 (clamped at zero to avoid negative leakage if called at
    the exact expiry second).
    """
    paused = patient.get("notificationsPaused")
    if not isinstance(paused, dict):
        return None
    until = _to_epoch_int(paused.get("until"))
    if until <= 0:
        return None
    now = int(now_fn())
    if until <= now:
        return None  # already expired — not "currently paused"
    return max(0, until - now)


def days_remaining(
    patient: dict[str, Any],
    *,
    now_fn: Callable[[], float] = time.time,
) -> Optional[int]:
    """
    Full days remaining on the pause (floor), or None if not currently
    paused. Used by the portal's countdown banner per user-needs US-31
    ("Notifications paused — 4 days remaining · in hospital").
    """
    secs = seconds_remaining(patient, now_fn=now_fn)
    if secs is None:
        return None
    return secs // 86400


def compute_until_epoch(days: int, *, now_fn: Callable[[], float] = time.time) -> int:
    """
    Convert a user-supplied `days` count into an absolute epoch-seconds
    cutoff. Single source of truth for the day-to-epoch conversion so
    the producer (POST /pause) and the read side stay aligned.
    """
    if days <= 0:
        raise ValueError(f"days must be positive, got {days}")
    return int(now_fn()) + days * 86400


# ── Internals ─────────────────────────────────────────────────────────


def _to_epoch_int(value: Any) -> int:
    """
    Coerce a DDB-derived value to an int epoch seconds. Returns 0 on
    None / unparseable / non-numeric. Tolerates Decimal (boto3 resource
    layer's default for DDB numbers), int, float, str.
    """
    if value is None:
        return 0
    try:
        return int(value)
    except (TypeError, ValueError):
        return 0

"""
Device lifecycle state machine — pure functions.

Maps ARCHITECTURE.md §4 state machine to validation logic with no
AWS dependencies, so it can be unit-tested without mocks. The handler
in handler.py calls validate_transition() before any DDB write.

States (DL1):       ready_to_provision | provisioned | active_monitoring
                  | discontinued | decommissioned
Reasons (DL2):      lost | broken | retired | end_of_life  (decommissioned only)

Transitions from ARCHITECTURE.md §4 diagram + revised spec L14/L15:
                                                              ┌─ first heartbeat (auto)
  ready_to_provision ──provision──► provisioned ──────────────┴──► active_monitoring
                                            │                              │
                                            └──end_assignment──► discontinued ◄── end_assignment
                                                                  │
                                                                  ├─ firmware reset_complete
                                                                  │   (on charger, auto)
                                                                  ├─ force_reset (admin)
                                                                  ▼
                                                       ready_to_provision

  any non-terminal ──decommission──► decommissioned (carries reason)
                                            │
                                            └── recover (only if reason=lost) ──►
                                                 ready_to_provision

  any state ──move_facility / move_client──► same state, new owner (L15: rejects
                                              active_monitoring with INVALID_TRANSITION)
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Iterable


# State constants
STATE_READY = "ready_to_provision"
STATE_PROVISIONED = "provisioned"
STATE_ACTIVE = "active_monitoring"
STATE_DISCONTINUED = "discontinued"
STATE_DECOMMISSIONED = "decommissioned"

ALL_STATES = frozenset(
    {STATE_READY, STATE_PROVISIONED, STATE_ACTIVE, STATE_DISCONTINUED, STATE_DECOMMISSIONED}
)
NON_TERMINAL = frozenset({STATE_READY, STATE_PROVISIONED, STATE_ACTIVE, STATE_DISCONTINUED})

# Decommission reasons
REASON_LOST = "lost"
REASON_BROKEN = "broken"
REASON_RETIRED = "retired"
REASON_END_OF_LIFE = "end_of_life"
RECOVERABLE_REASONS = frozenset({REASON_LOST})
ALL_REASONS = frozenset({REASON_LOST, REASON_BROKEN, REASON_RETIRED, REASON_END_OF_LIFE})

# Action constants (kept aligned with API endpoint paths)
ACTION_PROVISION = "provision"
ACTION_END_ASSIGNMENT = "end_assignment"
ACTION_DECOMMISSION = "decommission"
ACTION_RECOVER = "recover"
ACTION_FORCE_RESET = "force_reset"
ACTION_MOVE_FACILITY = "move_facility"
ACTION_MOVE_CLIENT = "move_client"


@dataclass(frozen=True)
class TransitionOk:
    """Valid transition; carries the resulting state."""

    next_state: str


@dataclass(frozen=True)
class TransitionError:
    """Invalid transition; carries the error code + message."""

    code: str
    message: str


def validate_transition(
    current_state: str,
    action: str,
    *,
    reason: str | None = None,
) -> TransitionOk | TransitionError:
    """
    Returns TransitionOk(next_state) if the action is allowed from the
    current state, else TransitionError(code, message).

    `reason` is required only for decommission; ignored otherwise.
    """
    if current_state not in ALL_STATES:
        return TransitionError(
            code="INVALID_STATE",
            message=f"Unknown current state '{current_state}'",
        )

    if action == ACTION_PROVISION:
        if current_state != STATE_READY:
            return TransitionError(
                code="DEVICE_UNAVAILABLE",
                message=f"Cannot provision a device in state '{current_state}'",
            )
        return TransitionOk(next_state=STATE_PROVISIONED)

    if action == ACTION_END_ASSIGNMENT:
        if current_state not in {STATE_PROVISIONED, STATE_ACTIVE}:
            return TransitionError(
                code="INVALID_TRANSITION",
                message=f"Cannot end-assignment from state '{current_state}'",
            )
        return TransitionOk(next_state=STATE_DISCONTINUED)

    if action == ACTION_DECOMMISSION:
        if current_state == STATE_DECOMMISSIONED:
            return TransitionError(
                code="INVALID_TRANSITION",
                message="Device is already decommissioned",
            )
        if reason not in ALL_REASONS:
            return TransitionError(
                code="INVALID_REQUEST",
                message=f"Decommission requires reason ∈ {sorted(ALL_REASONS)}",
            )
        return TransitionOk(next_state=STATE_DECOMMISSIONED)

    if action == ACTION_RECOVER:
        # Recover is only valid from decommissioned (lost) — the caller
        # is responsible for confirming the prior reason matches.
        if current_state != STATE_DECOMMISSIONED:
            return TransitionError(
                code="INVALID_TRANSITION",
                message=f"Recover only applies to decommissioned devices, not '{current_state}'",
            )
        # The "reason must be lost" check is enforced separately at the
        # handler level since the reason lives in DDB, not in this
        # function's inputs.
        return TransitionOk(next_state=STATE_READY)

    if action == ACTION_FORCE_RESET:
        # Force reset: admin override for stuck discontinued or
        # provisioned devices. Per spec Open Question (resolved):
        # same action for both "stuck in discontinued" and "stuck in
        # provisioned but never heard from".
        if current_state not in {STATE_DISCONTINUED, STATE_PROVISIONED}:
            return TransitionError(
                code="INVALID_TRANSITION",
                message=f"Force reset only applies to discontinued / provisioned, not '{current_state}'",
            )
        return TransitionOk(next_state=STATE_READY)

    if action in {ACTION_MOVE_FACILITY, ACTION_MOVE_CLIENT}:
        # L15: reject move on active_monitoring devices. Caller must
        # end-assignment first. Other state-preserving moves are fine
        # (ownership changes, state stays the same).
        if current_state == STATE_ACTIVE:
            return TransitionError(
                code="INVALID_TRANSITION",
                message=(
                    "Cannot move a device in state 'active_monitoring'. "
                    "End the current assignment first, then move."
                ),
            )
        # Moves preserve state.
        return TransitionOk(next_state=current_state)

    return TransitionError(
        code="INVALID_REQUEST",
        message=f"Unknown action '{action}'",
    )


def is_terminal(state: str, reason: str | None = None) -> bool:
    """Decommissioned is terminal EXCEPT when reason=lost (recoverable per DL10)."""
    if state != STATE_DECOMMISSIONED:
        return False
    return reason not in RECOVERABLE_REASONS


def actions_from(state: str) -> Iterable[str]:
    """Convenience for tests + diagnostics: which actions are valid from this state."""
    candidates = (
        ACTION_PROVISION,
        ACTION_END_ASSIGNMENT,
        ACTION_DECOMMISSION,
        ACTION_RECOVER,
        ACTION_FORCE_RESET,
        ACTION_MOVE_FACILITY,
        ACTION_MOVE_CLIENT,
    )
    return tuple(
        a for a in candidates
        if isinstance(validate_transition(state, a, reason=REASON_LOST), TransitionOk)
    )

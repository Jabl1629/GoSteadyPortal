"""
Per-device-type schema registry — Phase DT-0
(docs/specs/phase-dt0-device-type-scaffold.md, memo 2026-07-01-device-types.md).

Each device type module exports the product-contract surface that varies
by type; everything else (envelope, time resolution, hierarchy snapshot,
idempotency) is device-agnostic and stays in the handlers:

    TYPE: str                                — enum value stored in Device Registry
    REQUIRED_ACTIVITY_METRICS: tuple[str]    — presence-validated at ingest
    ACTIVITY_NAMED_FIELDS: frozenset[str]    — per-type additions to the extras
                                               exclusion list (unknown fields
                                               still flow to `extras` per D16)
    VALID_ALERT_TYPES: frozenset[str]        — device-originated alert enum
    validate_activity_metrics(event)         — (ok, reason); range checks
    build_metric_attrs(event)                — (ddb_attrs, warnings); named-column
                                               promotion. `warnings` is a list of
                                               dicts {"warning": <log-name>, ...}
                                               for the CALLER to log — modules
                                               stay pure (no logging/boto3) so
                                               they unit-test without the
                                               Powertools layer.

Registry lookup: `resolve(device_type)` returns the module, defaulting to
walker_cap for None/unknown per memo D9 (absent deviceType reads as
walker_cap — every pre-DT-0 record/assignment is a walker cap by
construction). Callers that care about unknown-vs-absent should check
`is_known()` and log; `resolve()` itself never raises.
"""

from __future__ import annotations

from _shared.device_types import rollator_platform, walker_cap

DEFAULT_TYPE: str = walker_cap.TYPE

_REGISTRY = {
    walker_cap.TYPE: walker_cap,
    rollator_platform.TYPE: rollator_platform,
}

#: All valid `deviceType` enum values — bulk-create validates against this.
KNOWN_DEVICE_TYPES = frozenset(_REGISTRY)


def is_known(device_type: str | None) -> bool:
    """True iff `device_type` is a registered type (None/absent is NOT known —
    it's the legacy-default case, which is valid but worth distinguishing)."""
    return device_type in _REGISTRY


def resolve(device_type: str | None):
    """
    Return the schema module for `device_type`. None/empty/unknown fall back
    to walker_cap (D9 legacy default). Unknown values indicate a typo'd
    registry record that bulk-create validation should have prevented —
    callers should pair `resolve()` with `is_known()` + a warning log when
    the value was present but unrecognized.
    """
    if not device_type:
        return _REGISTRY[DEFAULT_TYPE]
    return _REGISTRY.get(device_type) or _REGISTRY[DEFAULT_TYPE]

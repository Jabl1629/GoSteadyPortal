"""
Device Shadow handler — Phase 2A-DL + AA-battery-recycle (2026-05-17).

Triggered by an IoT Topic Rule subscribing to
`$aws/things/+/shadow/update/documents`. The same topic is also
consumed by Phase 1B-rev's threshold-detector; both Lambdas see every
shadow update and each filters for its own concern.

Two signals trigger the same `discontinued → ready_to_provision` auto-
transition:

1. **`reported.wipe_complete = <wipe_id>`** (preferred, post-2026-05-17
   firmware): the canonical AA-battery-recycle ack signal. Cloud-side
   matches `wipe_id` against `Device Registry.outstandingWipeCmds` and
   transitions on match + battery floor (≥0.10).

2. **`reported.reset_complete = true`** (legacy, pre-AA-recycle firmware):
   the original charger-gated reset model from Phase 2A-DL. Kept for
   backwards compat during the firmware transition; remove once all
   bench/field units run firmware ≥0.11.0-wipe-cmd.

Both paths perform the same DDB transition, clear Shadow `desired.*`
invariants (DL14 + DL15), and emit audit events. Per portal memo §5,
the ack is also delivered redundantly via heartbeat `last_cmd_id` echo
(handled in heartbeat-processor); both firing for the same wipe_id is
idempotent — the second one's ConditionalCheckFailedException is benign.

Ownership (owningClientId / owningFacilityId) is preserved per DL4.
Handler does NOT publish anything back to the device — firmware
already completed the wipe by the time it reports.

Spec: docs/specs/phase-2a-device-lifecycle.md + docs/specs/2026-05-17-
aa-battery-recycle.md. Coord §C17 (initial deploy) + §C20 (directional
change announcement).
"""

from __future__ import annotations

import json
import os
import time
from typing import Any

import boto3
from botocore.exceptions import ClientError

from _shared.audit_catalog import (
    AUDIT_DEVICE_RECYCLED,
    AUDIT_DEVICE_RESET_COMPLETE,
    AUDIT_DEVICE_WIPE_COMPLETE,
)
from _shared.observability import emit_audit, get_logger


ENV = os.environ.get("ENVIRONMENT", "dev")
DEVICES_TABLE = os.environ["DEVICES_TABLE"]
ASSIGNMENTS_TABLE = os.environ["ASSIGNMENTS_TABLE"]
WIPE_BATTERY_FLOOR_PCT = float(os.environ.get("WIPE_BATTERY_FLOOR_PCT", "0.10"))

logger = get_logger()
ddb = boto3.resource("dynamodb")
# iot-data is the DATA-PLANE client (update_thing_shadow).
iot_data = boto3.client("iot-data")

_devices = ddb.Table(DEVICES_TABLE)
_assignments = ddb.Table(ASSIGNMENTS_TABLE)


def _now_iso() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def _clear_shadow_desired_keys(serial: str, keys: list[str]) -> None:
    """Best-effort clear of one or more `desired.*` keys (DL14 + DL15
    invariants). Non-fatal on failure — heartbeat-processor's ack path
    also clears, and force_reset is the admin escape hatch."""
    payload = {"state": {"desired": {k: None for k in keys}}}
    try:
        iot_data.update_thing_shadow(
            thingName=serial,
            payload=json.dumps(payload).encode(),
        )
    except ClientError:
        logger.exception(
            "shadow_desired_clear_failed",
            extra={"serial": serial, "keys": keys},
        )


def _handle_wipe_complete(serial: str, reported: dict, previous: dict) -> dict[str, Any]:
    """
    AA-battery-recycle path (memo §5 / DL15). Fired when
    `reported.wipe_complete` carries a non-empty wipe_id that wasn't
    present in `previous` (transition detection — avoids re-firing on
    every shadow update once the field is set).

    Predicate set per memo §5:
      - cmd-id is in `Device Registry.outstandingWipeCmds` (idempotency
        invariant; first ack REMOVEs the entry, duplicate is no-op)
      - status == "discontinued" at read time
      - battery_pct in reported >= WIPE_BATTERY_FLOOR_PCT (sanity floor)
    """
    wipe_id = reported.get("wipe_complete")
    prior_wipe_id = previous.get("wipe_complete") if previous else None

    if not isinstance(wipe_id, str) or not wipe_id:
        return {"processed": False, "reason": "wipe_complete_not_a_string"}
    if wipe_id == prior_wipe_id:
        # Already processed in a prior shadow update — common when the
        # firmware writes both reported.wipe_complete and a heartbeat
        # with last_cmd_id within the same MQTT connection window. The
        # heartbeat-processor path may have already handled it.
        return {"processed": False, "reason": "wipe_id_unchanged_from_previous"}

    # Battery floor sanity check at ack time (D3). Heartbeat-processor's
    # `_try_wipe_ack` enforces the same check; both paths agree on a single
    # invariant.
    battery_pct = reported.get("battery_pct")
    try:
        if battery_pct is None or float(battery_pct) < WIPE_BATTERY_FLOOR_PCT:
            logger.info(
                "wipe_ack_below_battery_floor",
                extra={
                    "serial": serial,
                    "wipe_id": wipe_id,
                    "battery_pct": battery_pct,
                    "floor": WIPE_BATTERY_FLOOR_PCT,
                },
            )
            return {"processed": False, "reason": "battery_below_floor"}
    except (TypeError, ValueError):
        logger.warning(
            "wipe_ack_battery_unparsable",
            extra={"serial": serial, "wipe_id": wipe_id, "battery_pct": battery_pct},
        )
        return {"processed": False, "reason": "battery_unparsable"}

    res = _devices.get_item(Key={"serialNumber": serial})
    device = res.get("Item")
    if not device:
        logger.warning("wipe_ack_device_missing", extra={"serial": serial})
        return {"processed": False, "reason": "device_not_in_registry"}

    outstanding = device.get("outstandingWipeCmds") or {}
    if wipe_id not in outstanding:
        # The wipe_id was either never issued by this cloud (firmware bug
        # or stray report) or already acked + removed. Either way: no-op.
        logger.info(
            "wipe_ack_unknown_wipe_id",
            extra={
                "serial": serial,
                "wipe_id": wipe_id,
                "outstanding_count": len(outstanding),
            },
        )
        return {"processed": False, "reason": "wipe_id_not_in_outstanding"}

    current_state = device.get("status")
    if current_state != "discontinued":
        logger.warning(
            "wipe_ack_wrong_state",
            extra={
                "serial": serial,
                "wipe_id": wipe_id,
                "currentState": current_state,
            },
        )
        return {"processed": False, "reason": f"device_not_discontinued (state={current_state})"}

    now_iso = _now_iso()
    try:
        _devices.update_item(
            Key={"serialNumber": serial},
            UpdateExpression=(
                "SET #s = :rp, last_wipe_at = :w, lastTransitionAt = :w "
                "REMOVE outstandingWipeCmds.#cid"
            ),
            ConditionExpression=(
                "attribute_exists(outstandingWipeCmds.#cid) AND #s = :disc"
            ),
            ExpressionAttributeNames={"#s": "status", "#cid": wipe_id},
            ExpressionAttributeValues={
                ":rp": "ready_to_provision",
                ":disc": "discontinued",
                ":w": now_iso,
            },
        )
    except ClientError as exc:
        if exc.response["Error"]["Code"] == "ConditionalCheckFailedException":
            # Either heartbeat-processor's path got there first (idempotent —
            # benign) or status changed concurrently (rare race).
            logger.info(
                "wipe_ack_already_handled",
                extra={"serial": serial, "wipe_id": wipe_id},
            )
            return {"processed": False, "reason": "already_handled_by_heartbeat_path"}
        raise

    # DL15: clear desired.wipe_requested (will be a no-op if heartbeat path
    # already cleared, but that's idempotent).
    _clear_shadow_desired_keys(serial, ["wipe_requested"])

    emit_audit(
        event=AUDIT_DEVICE_WIPE_COMPLETE,
        actor={"system": "device-shadow-handler"},
        subject={
            "deviceSerial": serial,
            "clientId": device.get("owningClientId"),
            "facilityId": device.get("owningFacilityId"),
        },
        action="update",
        after={
            "last_wipe_at": now_iso,
            "matched_cmd_id": wipe_id,
            "battery_pct": float(battery_pct),
        },
        extra={"source": "device-shadow-handler"},
    )
    emit_audit(
        event=AUDIT_DEVICE_RECYCLED,
        actor={"system": "device-shadow-handler"},
        subject={
            "deviceSerial": serial,
            "clientId": device.get("owningClientId"),
            "facilityId": device.get("owningFacilityId"),
        },
        action="update",
        before={"status": "discontinued"},
        after={"status": "ready_to_provision", "last_wipe_at": now_iso},
    )

    return {
        "processed": True,
        "serial": serial,
        "newState": "ready_to_provision",
        "path": "wipe_complete",
        "wipe_id": wipe_id,
    }


def _handle_reset_complete(serial: str, reported: dict, previous: dict) -> dict[str, Any]:
    """
    Legacy charger-gated reset path (DL6 pre-2026-05-17). Kept for
    backwards compat during firmware transition to 0.11.0-wipe-cmd.
    Same DB transition as the wipe path but without the wipe_id /
    outstandingWipeCmds invariant — relies on `reset_complete = true`
    as a sufficient signal.

    Remove this branch once all bench/field firmware is on the new
    contract.
    """
    if not reported.get("reset_complete"):
        return {"processed": False, "reason": "no_reset_complete_in_reported"}
    if previous and previous.get("reset_complete"):
        return {"processed": False, "reason": "already_processed_in_previous"}

    res = _devices.get_item(Key={"serialNumber": serial})
    device = res.get("Item")
    if not device:
        logger.warning("shadow_handler_device_missing", extra={"serial": serial})
        return {"processed": False, "reason": "device_not_in_registry"}

    current_state = device.get("status")
    if current_state != "discontinued":
        logger.warning(
            "shadow_reset_unexpected_state",
            extra={"serial": serial, "currentState": current_state},
        )
        return {"processed": False, "reason": f"device_not_discontinued (state={current_state})"}

    now_iso = _now_iso()
    try:
        _devices.update_item(
            Key={"serialNumber": serial},
            UpdateExpression=(
                "SET #status = :ready, lastTransitionAt = :now, lastResetAt = :now"
            ),
            ConditionExpression="#status = :discontinued",
            ExpressionAttributeNames={"#status": "status"},
            ExpressionAttributeValues={
                ":ready": "ready_to_provision",
                ":discontinued": "discontinued",
                ":now": now_iso,
            },
        )
    except ClientError as exc:
        if exc.response["Error"]["Code"] == "ConditionalCheckFailedException":
            logger.warning("shadow_reset_state_changed", extra={"serial": serial})
            return {"processed": False, "reason": "state_changed_between_read_and_write"}
        raise

    # DL14: clear desired.activated_at (was already null at discontinued,
    # but defensive — keeps the invariant explicit).
    _clear_shadow_desired_keys(serial, ["activated_at"])

    emit_audit(
        event=AUDIT_DEVICE_RESET_COMPLETE,
        actor={"system": "device-shadow-handler"},
        subject={
            "serialNumber": serial,
            "clientId": device.get("owningClientId"),
            "facilityId": device.get("owningFacilityId"),
        },
        action="update",
        extra={"previousState": current_state, "source": "firmware_on_charger_legacy"},
    )

    return {
        "processed": True,
        "serial": serial,
        "newState": "ready_to_provision",
        "path": "reset_complete_legacy",
    }


def handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    """
    IoT Rule event shape (from threshold-detector's existing SQL):
        {
          "reported": { ... },              ← current state.reported
          "previous_reported": { ... },     ← previous state.reported (or None)
          "thingName": "GS0000001234",
          "rule_ts_ms": 1779040000000
        }

    Dispatch order:
      1. wipe_complete (new AA-recycle path; preferred)
      2. reset_complete (legacy charger path; backwards-compat)
      3. neither → no-op
    """
    reported = event.get("reported") or {}
    previous = event.get("previous_reported") or {}
    serial = event.get("thingName")

    if not serial:
        logger.warning("shadow_handler_no_serial", extra={"event_keys": list(event.keys())})
        return {"processed": False, "reason": "no_thingName"}

    # Wipe-complete is the new canonical path (post-2026-05-17 firmware).
    if reported.get("wipe_complete"):
        return _handle_wipe_complete(serial, reported, previous)

    # Reset-complete is the legacy path (pre-2026-05-17 firmware). Keep
    # it through the firmware-transition window.
    if reported.get("reset_complete"):
        return _handle_reset_complete(serial, reported, previous)

    return {"processed": False, "reason": "no_wipe_or_reset_complete_in_reported"}

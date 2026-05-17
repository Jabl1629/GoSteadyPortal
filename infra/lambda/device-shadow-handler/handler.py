"""
Device Shadow handler — Phase 2A-DL.

Triggered by an IoT Topic Rule subscribing to
`$aws/things/+/shadow/update/documents`. The same topic is also
consumed by Phase 1B-rev's threshold-detector; both Lambdas see every
shadow update and each filters for its own concern.

This handler filters for `reported.reset_complete = true` (firmware
indicates it has completed the on-charger reset sequence) and, if the
device is currently in `discontinued` state, transitions it to
`ready_to_provision`. Ownership (owningClientId / owningFacilityId)
is preserved per DL4.

Per ARCHITECTURE.md §4 (device lifecycle) the reset is firmware-driven
on the charger. The handler does NOT publish anything back to the
device — firmware already completed the reset by the time it reports.
"""

from __future__ import annotations

import json
import os
import time
from typing import Any

import boto3
from botocore.exceptions import ClientError

from _shared.audit_catalog import AUDIT_DEVICE_RESET_COMPLETE
from _shared.observability import emit_audit, get_logger


ENV = os.environ.get("ENVIRONMENT", "dev")
DEVICES_TABLE = os.environ["DEVICES_TABLE"]
ASSIGNMENTS_TABLE = os.environ["ASSIGNMENTS_TABLE"]

logger = get_logger()
ddb = boto3.resource("dynamodb")
# iot-data is the DATA-PLANE client (update_thing_shadow).
iot_data = boto3.client("iot-data")

_devices = ddb.Table(DEVICES_TABLE)
_assignments = ddb.Table(ASSIGNMENTS_TABLE)


def _now_iso() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def _clear_shadow_activated_at(serial: str) -> None:
    try:
        iot_data.update_thing_shadow(
            thingName=serial,
            payload=json.dumps({"state": {"desired": {"activated_at": None}}}).encode(),
        )
    except ClientError:
        logger.exception("shadow_clear_failed", extra={"serial": serial})


def handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    """
    IoT Rule event shape (from threshold-detector's existing SQL):
        {
          "reported": { ... },              ← current state.reported
          "previous_reported": { ... },     ← previous state.reported (or None)
          "thingName": "GS0000001234",
          "rule_ts_ms": 1779040000000
        }
    """
    reported = event.get("reported") or {}
    previous = event.get("previous_reported") or {}
    serial = event.get("thingName")

    if not serial:
        logger.warning("shadow_handler_no_serial", extra={"event_keys": list(event.keys())})
        return {"processed": False, "reason": "no_thingName"}

    # We only care about transitions to reset_complete=true. If the
    # device has been reporting reset_complete for hours, we don't want
    # to re-fire on every shadow update.
    if not reported.get("reset_complete"):
        return {"processed": False, "reason": "no_reset_complete_in_reported"}
    if previous and previous.get("reset_complete"):
        return {"processed": False, "reason": "already_processed_in_previous"}

    # Read current device state
    res = _devices.get_item(Key={"serialNumber": serial})
    device = res.get("Item")
    if not device:
        logger.warning("shadow_handler_device_missing", extra={"serial": serial})
        return {"processed": False, "reason": "device_not_in_registry"}

    current_state = device.get("status")
    if current_state != "discontinued":
        # Reset reported from a device not in discontinued state — usually
        # benign (provisioned-but-never-heard-from being reset on charger
        # is handled by force_reset; this path is specifically for the
        # standard end-assignment → on-charger flow). Log + skip.
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
            # State changed between read and write — retry on next update
            logger.warning("shadow_reset_state_changed", extra={"serial": serial})
            return {"processed": False, "reason": "state_changed_between_read_and_write"}
        raise

    # DL14: clear desired.activated_at (was already null at discontinued,
    # but defensive — keeps the invariant explicit).
    _clear_shadow_activated_at(serial)

    emit_audit(
        event=AUDIT_DEVICE_RESET_COMPLETE,
        actor={"system": "device-shadow-handler"},
        subject={
            "serialNumber": serial,
            "clientId": device.get("owningClientId"),
            "facilityId": device.get("owningFacilityId"),
        },
        action="update",
        extra={"previousState": current_state, "source": "firmware_on_charger"},
    )

    return {"processed": True, "serial": serial, "newState": "ready_to_provision"}

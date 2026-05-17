"""
Discharge cascade — Phase 2A-DL.

Triggered by DDB Stream on the Patients table. When a Patients row's
`status` flips to `discharged`, query DeviceAssignments by-patient for
any active assignment (validUntil = null) and:

  - Close the assignment row (set validUntil = now)
  - Transition the corresponding Device Registry row from
    {provisioned, active_monitoring} → discontinued
  - Clear Shadow desired.activated_at (DL14 invariant)
  - Emit `device.assignment_ended` audit event with
    `reason: patient_discharged`

Per spec D3: prefer DDB Stream + dedicated Lambda over direct
invocation from the patient-management API handler (decouples; if
patient-API has a bug, devices still cascade correctly when the data
eventually reflects discharge).

Lambda runtime: same Python 3.12 ARM64 as device-api. Bundles
_shared/ for emit_audit + logger access.
"""

from __future__ import annotations

import json
import os
import time
from typing import Any

import boto3
from botocore.exceptions import ClientError

from _shared.audit_catalog import AUDIT_DEVICE_ASSIGNMENT_ENDED
from _shared.observability import emit_audit, get_logger


ENV = os.environ.get("ENVIRONMENT", "dev")
DEVICES_TABLE = os.environ["DEVICES_TABLE"]
ASSIGNMENTS_TABLE = os.environ["ASSIGNMENTS_TABLE"]

logger = get_logger()
ddb = boto3.resource("dynamodb")
# iot-data is the DATA-PLANE client (update_thing_shadow). The control-
# plane `iot` client doesn't expose update_thing_shadow.
iot_data = boto3.client("iot-data")

_devices = ddb.Table(DEVICES_TABLE)
_assignments = ddb.Table(ASSIGNMENTS_TABLE)


def _now_iso() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def _clear_shadow_activated_at(serial: str) -> None:
    """DL14 invariant — clear desired.activated_at on every transition out of {provisioned, active_monitoring}."""
    try:
        iot_data.update_thing_shadow(
            thingName=serial,
            payload=json.dumps({"state": {"desired": {"activated_at": None}}}).encode(),
        )
    except ClientError:
        logger.exception("shadow_clear_failed", extra={"serial": serial})


def _cascade_one(patient_id: str, patient_client_id: str | None) -> int:
    """
    Process one discharged patient. Returns the count of devices
    cascade-ended.
    """
    ended = 0
    # Query DeviceAssignments by-patient for any active assignment
    res = _assignments.query(
        IndexName="by-patient",
        KeyConditionExpression="patientId = :p",
        ExpressionAttributeValues={":p": patient_id},
    )
    items = res.get("Items", [])
    now_iso = _now_iso()

    for assignment in items:
        # "Active" assignment = validUntil missing or null
        if assignment.get("validUntil") not in (None, ""):
            continue

        serial = assignment.get("serialNumber")
        if not serial:
            continue

        # Read the device's current state
        device_res = _devices.get_item(Key={"serialNumber": serial})
        device = device_res.get("Item")
        if not device:
            logger.warning("discharge_cascade_device_missing", extra={"serial": serial, "patientId": patient_id})
            continue

        current_state = device.get("status")
        if current_state not in {"provisioned", "active_monitoring"}:
            # Device is already discontinued / decommissioned / ready;
            # nothing to do for this row, but still close the dangling
            # assignment for housekeeping.
            try:
                _assignments.update_item(
                    Key={"serialNumber": serial, "assignedAt": assignment["assignedAt"]},
                    UpdateExpression="SET validUntil = :u",
                    ExpressionAttributeValues={":u": now_iso},
                )
            except ClientError:
                logger.exception("assignment_close_failed", extra={"serial": serial})
            continue

        # Close the assignment row
        try:
            _assignments.update_item(
                Key={"serialNumber": serial, "assignedAt": assignment["assignedAt"]},
                UpdateExpression="SET validUntil = :u",
                ExpressionAttributeValues={":u": now_iso},
            )
        except ClientError:
            logger.exception("assignment_close_failed", extra={"serial": serial})
            continue

        # Transition device → discontinued
        try:
            _devices.update_item(
                Key={"serialNumber": serial},
                UpdateExpression="SET #status = :d, lastTransitionAt = :now REMOVE currentAssignmentSk",
                ExpressionAttributeNames={"#status": "status"},
                ExpressionAttributeValues={":d": "discontinued", ":now": now_iso},
            )
        except ClientError:
            logger.exception("device_status_update_failed", extra={"serial": serial})
            continue

        # DL14 invariant
        _clear_shadow_activated_at(serial)

        # Emit audit
        emit_audit(
            event=AUDIT_DEVICE_ASSIGNMENT_ENDED,
            actor={"system": "discharge-cascade"},
            subject={"serialNumber": serial, "patientId": patient_id,
                     "clientId": assignment.get("clientId") or patient_client_id},
            action="update",
            extra={"reason": "patient_discharged", "previousState": current_state,
                   "assignmentSk": assignment["assignedAt"]},
        )
        ended += 1

    return ended


def _was_discharged(record: dict[str, Any]) -> tuple[bool, str | None, str | None]:
    """
    Decide whether this Stream record is a discharge transition.
    Returns (is_discharge, patient_id, client_id).

    A discharge is: OLD status != "discharged" AND NEW status == "discharged".
    Also handles INSERT events where OLD doesn't exist.
    """
    if record.get("eventName") not in {"INSERT", "MODIFY"}:
        return False, None, None

    new_image = (record.get("dynamodb", {}) or {}).get("NewImage", {}) or {}
    old_image = (record.get("dynamodb", {}) or {}).get("OldImage", {}) or {}

    def _s(image: dict[str, Any], key: str) -> str | None:
        v = image.get(key)
        return v.get("S") if isinstance(v, dict) else None

    new_status = _s(new_image, "status")
    old_status = _s(old_image, "status")
    if new_status != "discharged":
        return False, None, None
    if old_status == "discharged":
        return False, None, None  # already discharged; nothing new

    return True, _s(new_image, "patientId"), _s(new_image, "clientId")


def handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    """Entry point. DDB Stream events come in batches."""
    records = event.get("Records") or []
    total_ended = 0
    patients_processed = 0

    for record in records:
        try:
            is_discharge, patient_id, client_id = _was_discharged(record)
            if not is_discharge or not patient_id:
                continue
            ended = _cascade_one(patient_id, client_id)
            total_ended += ended
            patients_processed += 1
        except Exception:
            # Don't let one bad record poison the whole batch
            logger.exception("discharge_cascade_record_failed",
                             extra={"event_id": record.get("eventID"),
                                    "event_name": record.get("eventName")})

    if patients_processed:
        logger.info("discharge_cascade_completed",
                    extra={"patientsProcessed": patients_processed,
                           "devicesEnded": total_ended})

    return {"patientsProcessed": patients_processed, "devicesEnded": total_ended}

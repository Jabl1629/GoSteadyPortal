"""
Shared patient-resolution helper — Phase 1B revision.

serial → DeviceAssignments active row → patientId → Patients row →
PatientContext(patientId, clientId, facilityId, censusId, timezone, deviceSerial)

Used by activity-processor, threshold-detector, and alert-handler. Heartbeat-
processor does NOT use this helper — its slim path only touches Shadow + Device
Registry.
"""

from __future__ import annotations

import os
from dataclasses import dataclass

import boto3
from boto3.dynamodb.conditions import Key

DEVICE_ASSIGNMENTS_TABLE = os.environ.get(
    "DEVICE_ASSIGNMENTS_TABLE", "gosteady-dev-device-assignments"
)
PATIENTS_TABLE = os.environ.get("PATIENTS_TABLE", "gosteady-dev-patients")

_ddb = boto3.resource("dynamodb")
_assignments_tbl = _ddb.Table(DEVICE_ASSIGNMENTS_TABLE)
_patients_tbl = _ddb.Table(PATIENTS_TABLE)


class PatientResolutionError(Exception):
    """Raised when serial → patient resolution fails for a reason worth surfacing."""


@dataclass(frozen=True)
class PatientContext:
    patientId: str
    clientId: str
    facilityId: str
    censusId: str
    timezone: str
    deviceSerial: str
    # Phase DT-0: device type snapshotted onto the assignment row at provision
    # (memo 2026-07-01-device-types.md D1). Absent on pre-DT-0 assignments →
    # walker_cap (D9 legacy default — every pre-DT-0 assignment IS a walker
    # cap by construction; no registry fallback read needed at ingest).
    deviceType: str = "walker_cap"
    # Phase 2A-AA: per-patient threshold overrides (None when no overrides set).
    # Threshold Detector merges over defaults from _shared/thresholds.py.
    # Other consumers (activity-processor, alert-handler) ignore this field.
    thresholds: dict | None = None
    # Phase 2A-UM-P: Patient.notificationsPaused map populated by
    # patient-mgmt POST /pause. Consumers check via _shared.pause_check.
    # is_currently_paused({"notificationsPaused": ctx.notificationsPaused}).
    # Threshold detector + behavioral detector skip evaluation if paused;
    # activity-processor auto-resumes by removing this attribute when
    # fresh activity arrives.
    notificationsPaused: dict | None = None


def _find_active_assignment(serial: str) -> dict | None:
    """
    DeviceAssignments PK=serialNumber, SK=assignedAt. Active assignment has
    `validUntil` absent. Most recent first; LIMIT 10 + filter is enough at v1
    cardinality (a device rarely accrues >10 assignments).
    """
    resp = _assignments_tbl.query(
        KeyConditionExpression=Key("serialNumber").eq(serial),
        ScanIndexForward=False,
        Limit=10,
    )
    for item in resp.get("Items", []):
        if "validUntil" not in item or item.get("validUntil") in (None, ""):
            return item
    return None


def resolve_patient(serial: str) -> PatientContext | None:
    """
    Returns a PatientContext for `serial` or None if there's no active
    assignment OR the linked Patients row is missing.

    Caller decides whether to drop, log, or DLQ. Callers that treat this
    as a hard error should raise PatientResolutionError after logging.
    """
    assignment = _find_active_assignment(serial)
    if assignment is None:
        return None

    patient_id = assignment.get("patientId")
    if not patient_id:
        return None

    patient = _patients_tbl.get_item(Key={"patientId": patient_id}).get("Item")
    if patient is None:
        return None

    raw_thresholds = patient.get("thresholds")
    thresholds = dict(raw_thresholds) if isinstance(raw_thresholds, dict) and raw_thresholds else None

    raw_pause = patient.get("notificationsPaused")
    pause = dict(raw_pause) if isinstance(raw_pause, dict) and raw_pause else None

    return PatientContext(
        patientId=str(patient_id),
        clientId=str(patient.get("clientId") or assignment.get("clientId") or ""),
        facilityId=str(patient.get("facilityId") or assignment.get("facilityId") or ""),
        censusId=str(patient.get("censusId") or assignment.get("censusId") or ""),
        timezone=str(patient.get("timezone") or "UTC"),
        deviceSerial=serial,
        deviceType=str(assignment.get("deviceType") or "walker_cap"),
        thresholds=thresholds,
        notificationsPaused=pause,
    )

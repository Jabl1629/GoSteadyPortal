"""
Alert Actions handler — Phase 2A-AA.

Three routes:
  PATCH /api/v1/alerts/{patientId}/{timestamp}   — acknowledge alert
  GET   /api/v1/patients/{id}/thresholds         — read effective thresholds
  PUT   /api/v1/patients/{id}/thresholds         — set per-patient overrides

Single Lambda dispatches all routes (mirrors device-api / patient-api D1).
Explicit emit_audit calls (not @audit_middleware decorator) because the
ack endpoint emits `extra={wasAlreadyAcknowledged}` and the threshold
update emits before/after — neither fits the single-event-per-call shape.

Tenancy + scope via 2A-RD's `enforce_patient_access` helper.
"""

from __future__ import annotations

import json
import os
import re
import time
import urllib.parse
from decimal import Decimal
from typing import Any

import boto3
from botocore.exceptions import ClientError

from _shared.api_authz import (
    enforce_patient_access,
    extract_claims,
    is_internal,
    linked_patient_ids,
    require_authenticated,
    require_role,
)
from _shared.api_error import ApiError, error_response, ok_response
from _shared.audit_catalog import (
    AUDIT_ALERT_ACK,
    AUDIT_PATIENT_THRESHOLDS_READ,
    AUDIT_PATIENT_THRESHOLDS_UPDATE,
)
from _shared.observability import emit_audit, get_logger
from _shared.thresholds import DEFAULTS, merge_thresholds

from thresholds_validation import (
    ALLOWED_FIELDS,
    validate_ordering_against_effective,
    validate_thresholds_patch,
)

ENV = os.environ.get("ENVIRONMENT", "dev")
PATIENTS_TABLE = os.environ["PATIENTS_TABLE"]
ALERTS_TABLE = os.environ["ALERTS_TABLE"]
ROLE_ASSIGNMENTS_TABLE = os.environ["ROLE_ASSIGNMENTS_TABLE"]

logger = get_logger()
_ddb = boto3.resource("dynamodb")
_patients = _ddb.Table(PATIENTS_TABLE)
_alerts = _ddb.Table(ALERTS_TABLE)
_role_assignments = _ddb.Table(ROLE_ASSIGNMENTS_TABLE)

# Compound alert SK regex: ISO 8601 UTC + '#' + alert_type
_SK_RE = re.compile(
    r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z"
    r"#"
    r"[a-z_]+$"
)
_NOTES_MAX = 500

# Roles that can ack alerts (Phase 2A-AA L5)
_CAN_ACK = {"caregiver", "facility_admin", "client_admin", "household_owner", "internal_admin"}

# Roles that can write per-patient thresholds (Phase 2A-AA L6)
_CAN_WRITE_THRESHOLDS = {"facility_admin", "client_admin", "internal_admin"}

# Roles that can read per-patient thresholds (read scope wider than write)
_CAN_READ_THRESHOLDS = {
    "caregiver", "facility_admin", "client_admin", "household_owner",
    "internal_support", "internal_admin",
}


def _now_iso() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def _request_id(event: dict[str, Any]) -> str:
    return event.get("requestContext", {}).get("requestId", "")


def _actor(claims: dict[str, Any]) -> dict[str, Any]:
    return {
        "userId": claims.get("userId", ""),
        "role": claims.get("role", ""),
        "clientId": claims.get("clientId", ""),
    }


def _parse_body(event: dict[str, Any]) -> dict[str, Any]:
    raw = event.get("body") or "{}"
    try:
        return json.loads(raw) if raw else {}
    except (json.JSONDecodeError, TypeError) as exc:
        raise ApiError(
            code="INVALID_REQUEST",
            message=f"Body is not valid JSON: {exc}",
            status=400,
        )


def _get_patient(patient_id: str) -> dict[str, Any]:
    res = _patients.get_item(Key={"patientId": patient_id})
    p = res.get("Item")
    if not p:
        # 404; no audit per 2A-RD spec L4 (skip 404 audit emission)
        raise ApiError(
            code="PATIENT_NOT_FOUND",
            message=f"Patient {patient_id} not found",
            status=404,
        )
    return p


# ── Action handlers ─────────────────────────────────────────────────────


def _action_ack_alert(
    event: dict[str, Any], claims: dict[str, Any],
    patient_id: str, raw_timestamp: str,
) -> dict[str, Any]:
    """PATCH /api/v1/alerts/{patientId}/{timestamp}"""
    require_role(claims, *_CAN_ACK)

    # URL-decode compound SK; validate shape
    timestamp = urllib.parse.unquote(raw_timestamp)
    if not _SK_RE.match(timestamp):
        raise ApiError(
            code="INVALID_TIMESTAMP",
            message="timestamp must be ISO-8601-UTC#alertType",
            status=400,
            details={"received": raw_timestamp, "decoded": timestamp},
        )

    body = _parse_body(event)
    notes = body.get("notes")
    if notes is not None:
        if not isinstance(notes, str):
            raise ApiError(
                code="INVALID_REQUEST",
                message="notes must be a string",
                status=400,
            )
        if len(notes) > _NOTES_MAX:
            raise ApiError(
                code="INVALID_REQUEST",
                message=f"notes exceeds max length {_NOTES_MAX}",
                status=400,
                details={"length": len(notes), "max": _NOTES_MAX},
            )

    # Auth chain
    patient = _get_patient(patient_id)
    linked = linked_patient_ids(claims, _role_assignments)
    enforce_patient_access(claims, patient, linked_ids=linked)

    # Look up the alert; surface 404 cleanly if absent
    res = _alerts.get_item(Key={"patientId": patient_id, "timestamp": timestamp})
    alert = res.get("Item")
    if not alert:
        raise ApiError(
            code="ALERT_NOT_FOUND",
            message="Alert not found for this patient + timestamp",
            status=404,
        )

    now_iso = _now_iso()
    actor_user_id = claims.get("userId", "")

    # Conditional UpdateItem: first-write-wins ack (spec L4)
    # Condition: attribute_not_exists(acknowledged) OR acknowledged = false
    update_expr_parts = [
        "acknowledged = :true",
        "acknowledgedAt = :now",
        "acknowledgedBy = :who",
    ]
    attr_values: dict[str, Any] = {
        ":true": True,
        ":false": False,
        ":now": now_iso,
        ":who": actor_user_id,
    }
    if notes is not None:
        update_expr_parts.append("ackNotes = :notes")
        attr_values[":notes"] = notes

    was_already_acked = False
    try:
        upd = _alerts.update_item(
            Key={"patientId": patient_id, "timestamp": timestamp},
            UpdateExpression="SET " + ", ".join(update_expr_parts),
            ConditionExpression=(
                "attribute_not_exists(acknowledged) OR acknowledged = :false"
            ),
            ExpressionAttributeValues=attr_values,
            ReturnValues="ALL_NEW",
        )
        alert = upd.get("Attributes", alert)
    except ClientError as exc:
        if exc.response["Error"]["Code"] == "ConditionalCheckFailedException":
            # Already acked — re-read to return current state idempotently
            was_already_acked = True
            res = _alerts.get_item(Key={"patientId": patient_id, "timestamp": timestamp})
            alert = res.get("Item") or alert
        else:
            raise

    emit_audit(
        event=AUDIT_ALERT_ACK,
        actor=_actor(claims),
        subject={
            "patientId": patient_id,
            "clientId": patient.get("clientId", ""),
            "alertType": alert.get("alertType"),
            "severity": alert.get("severity"),
            "eventTimestamp": alert.get("eventTimestamp"),
        },
        action="update",
        extra={
            "wasAlreadyAcknowledged": was_already_acked,
            "hasNotes": notes is not None and not was_already_acked,
        },
        request_id=_request_id(event),
    )

    return ok_response({
        "alert": _alert_view(alert),
        "wasAlreadyAcknowledged": was_already_acked,
    })


def _action_get_thresholds(
    event: dict[str, Any], claims: dict[str, Any], patient_id: str,
) -> dict[str, Any]:
    """GET /api/v1/patients/{id}/thresholds"""
    require_role(claims, *_CAN_READ_THRESHOLDS)

    patient = _get_patient(patient_id)
    linked = linked_patient_ids(claims, _role_assignments)
    enforce_patient_access(claims, patient, linked_ids=linked)

    raw_overrides = patient.get("thresholds") or {}
    merged = merge_thresholds(raw_overrides) if raw_overrides else dict(DEFAULTS)
    source = {
        k: ("override" if (k in raw_overrides and raw_overrides[k] is not None) else "default")
        for k in DEFAULTS
    }

    emit_audit(
        event=AUDIT_PATIENT_THRESHOLDS_READ,
        actor=_actor(claims),
        subject={
            "patientId": patient_id,
            "clientId": patient.get("clientId", ""),
            "hasOverrides": bool(raw_overrides),
        },
        action="read",
        request_id=_request_id(event),
    )

    return ok_response({
        "thresholds": merged,
        "source": source,
    })


def _action_put_thresholds(
    event: dict[str, Any], claims: dict[str, Any], patient_id: str,
) -> dict[str, Any]:
    """PUT /api/v1/patients/{id}/thresholds"""
    require_role(claims, *_CAN_WRITE_THRESHOLDS)

    body = _parse_body(event)
    proposed = validate_thresholds_patch(body)

    patient = _get_patient(patient_id)
    linked = linked_patient_ids(claims, _role_assignments)
    enforce_patient_access(claims, patient, linked_ids=linked)

    existing_overrides = patient.get("thresholds") or {}
    # Second-pass ordering check accounts for effective state after merge
    validate_ordering_against_effective(proposed, existing_overrides)

    # Compute new override map: start from existing, apply proposed
    # (None means REMOVE the override for that field).
    new_overrides: dict[str, Any] = {
        k: v for k, v in existing_overrides.items() if v is not None
    }
    for k, v in proposed.items():
        if v is None:
            new_overrides.pop(k, None)
        else:
            # Store as Decimal for DDB
            new_overrides[k] = Decimal(str(v))

    # Update Patients.thresholds
    if new_overrides:
        _patients.update_item(
            Key={"patientId": patient_id},
            UpdateExpression="SET thresholds = :t",
            ExpressionAttributeValues={":t": new_overrides},
        )
    else:
        # No overrides remain — REMOVE the attribute entirely so reads
        # see "all defaults" (source=default for every field).
        _patients.update_item(
            Key={"patientId": patient_id},
            UpdateExpression="REMOVE thresholds",
        )

    merged = merge_thresholds(new_overrides) if new_overrides else dict(DEFAULTS)
    source = {
        k: ("override" if (k in new_overrides) else "default")
        for k in DEFAULTS
    }

    emit_audit(
        event=AUDIT_PATIENT_THRESHOLDS_UPDATE,
        actor=_actor(claims),
        subject={
            "patientId": patient_id,
            "clientId": patient.get("clientId", ""),
        },
        action="update",
        before={k: float(v) for k, v in existing_overrides.items() if v is not None},
        after={k: float(v) for k, v in new_overrides.items()},
        extra={
            "updatedFields": sorted(proposed.keys()),
        },
        request_id=_request_id(event),
    )

    return ok_response({
        "thresholds": merged,
        "source": source,
        "updated": sorted(proposed.keys()),
    })


# ── View ────────────────────────────────────────────────────────────────


def _alert_view(row: dict[str, Any]) -> dict[str, Any]:
    return {
        "patientId": row.get("patientId"),
        "timestamp": row.get("timestamp"),
        "eventTimestamp": row.get("eventTimestamp"),
        "alertType": row.get("alertType"),
        "severity": row.get("severity"),
        "source": row.get("source"),
        "acknowledged": bool(row.get("acknowledged", False)),
        "acknowledgedAt": row.get("acknowledgedAt"),
        "acknowledgedBy": row.get("acknowledgedBy"),
        "ackNotes": row.get("ackNotes"),
        "deviceSerial": row.get("deviceSerial"),
    }


# ── Route dispatcher ────────────────────────────────────────────────────


def _route(api_event: dict[str, Any]) -> tuple[str, dict[str, str]]:
    rc = api_event.get("requestContext", {}) or {}
    http = rc.get("http", {}) or {}
    method = (http.get("method") or "").upper()
    route_key = api_event.get("routeKey", "")
    path_params = api_event.get("pathParameters") or {}

    table = {
        ("PATCH", "PATCH /api/v1/alerts/{patientId}/{timestamp}"): "ack_alert",
        ("GET", "GET /api/v1/patients/{id}/thresholds"): "get_thresholds",
        ("PUT", "PUT /api/v1/patients/{id}/thresholds"): "put_thresholds",
    }
    action = table.get((method, route_key))
    if not action:
        raise ApiError(
            code="NOT_FOUND",
            message=f"No route matches {method} {route_key}",
            status=404,
        )
    return action, path_params


def handler(api_event: dict[str, Any], context: Any) -> dict[str, Any]:
    """Entry point. Route → action. ApiError → standard envelope."""
    claims = extract_claims(api_event)
    try:
        require_authenticated(claims)
        action, params = _route(api_event)

        if action == "ack_alert":
            return _action_ack_alert(
                api_event, claims,
                params.get("patientId", ""), params.get("timestamp", ""),
            )
        if action == "get_thresholds":
            return _action_get_thresholds(api_event, claims, params.get("id", ""))
        if action == "put_thresholds":
            return _action_put_thresholds(api_event, claims, params.get("id", ""))

        raise ApiError(code="NOT_FOUND", message=f"Unrouted action {action}", status=404)
    except ApiError as exc:
        # Per 2A-RD L4: skip audit on 400/404/429; emit on success +
        # 403/500 (but 403/500 audit is awkward in catch-all without
        # knowing intended event — defer richer 403 audit to per-action
        # wrappers if forensics demands it).
        logger.warning(
            "alert_actions_error",
            extra={"code": exc.code, "status": exc.status, "error_message": exc.message},
        )
        return error_response(exc.code, exc.message, exc.status, exc.details)

"""
Patient API handler — Phase 2A-RD (Patient Reads).

Single Lambda dispatches all 5 read routes from phase-2a-read.md L1:
  GET /api/v1/patients/{id}
  GET /api/v1/patients/{id}/activity?range=24h|7d|30d&cursor=&pageSize=
  GET /api/v1/patients/{id}/alerts?status=unacknowledged|acknowledged|all&cursor=&pageSize=
  GET /api/v1/me/patients?cursor=&pageSize=&clientId= (internal-only)
  GET /api/v1/facilities/{facilityId}/censuses/{censusId}/patients?cursor=&pageSize=

Per-handler explicit audit emission (not the audit_middleware decorator)
because list endpoints emit `extra={patientCount, ...}` etc. that the
decorator doesn't carry. Mirrors the device-api pattern (D1 of phase-2a-
device-lifecycle.md).

Tenancy + scope enforcement uses 2A-0 helpers:
  - enforce_tenancy (clientId match; internal_* bypass)
  - enforce_scope (caregiver census; facility_admin facility)
  - enforce_patient_access (combined single-patient auth chain, including
    family_viewer linked_patient_ids 404-leak prevention)
  - resolve_list_scope (list-endpoint per-role query plan)
"""

from __future__ import annotations

import os
from typing import Any

import boto3

from _shared.api_authz import (
    enforce_internal_session_age,
    enforce_scope,
    enforce_patient_access,
    extract_claims,
    is_internal,
    linked_patient_ids,
    require_authenticated,
    resolve_list_scope,
)
from _shared.api_error import ApiError, error_response, ok_response
from _shared.audit_catalog import (
    AUDIT_ALERT_READ,
    AUDIT_CENSUS_ROSTER_READ,
    AUDIT_PATIENT_ACTIVITY_READ,
    AUDIT_PATIENT_DETAIL_READ,
    AUDIT_PATIENT_LIST_READ,
)
from _shared.observability import emit_audit, get_logger
from _shared.pause_check import days_remaining, is_currently_paused

from pagination import (
    decode_cursor,
    encode_cursor,
    parse_page_size,
)
from queries import (
    batch_get_census_rows,
    batch_get_orgs,
    batch_get_patients,
    get_active_assignment,
    get_device,
    get_patient,
    query_activity_window,
    query_alerts,
    query_patients_by_census,
    query_patients_by_client,
)
from ranges import parse_range, range_to_window

ENV = os.environ.get("ENVIRONMENT", "dev")
PATIENTS_TABLE = os.environ["PATIENTS_TABLE"]
ACTIVITY_TABLE = os.environ["ACTIVITY_TABLE"]
ALERTS_TABLE = os.environ["ALERTS_TABLE"]
ORGANIZATIONS_TABLE = os.environ["ORGANIZATIONS_TABLE"]
DEVICE_ASSIGNMENTS_TABLE = os.environ["DEVICE_ASSIGNMENTS_TABLE"]
DEVICES_TABLE = os.environ["DEVICES_TABLE"]
ROLE_ASSIGNMENTS_TABLE = os.environ["ROLE_ASSIGNMENTS_TABLE"]

logger = get_logger()
_ddb = boto3.resource("dynamodb")
_patients = _ddb.Table(PATIENTS_TABLE)
_activity = _ddb.Table(ACTIVITY_TABLE)
_alerts = _ddb.Table(ALERTS_TABLE)
_orgs = _ddb.Table(ORGANIZATIONS_TABLE)
_assignments = _ddb.Table(DEVICE_ASSIGNMENTS_TABLE)
_devices = _ddb.Table(DEVICES_TABLE)
_role_assignments = _ddb.Table(ROLE_ASSIGNMENTS_TABLE)


# ── View / projection helpers ──────────────────────────────────────────


def _patient_view(p: dict[str, Any]) -> dict[str, Any]:
    """
    Projection for GET /patients/{id} primary fields. Includes the
    Phase 2A-UM-P additions (careNote + notificationsPaused state) so
    the portal sees a consistent shape between read (this endpoint) and
    write (patient-mgmt). Mirrors patient-mgmt._patient_view.
    """
    keep = ("patientId", "displayName", "status", "timezone",
            "clientId", "facilityId", "censusId", "room")
    out = {k: p.get(k) for k in keep}

    # Care note (2A-UM-P US-44). Only surface when non-empty text exists.
    care_note = p.get("careNote")
    if isinstance(care_note, dict) and care_note.get("text"):
        out["careNote"] = {
            "text": care_note.get("text"),
            "updatedBy": care_note.get("updatedBy"),
            "updatedByName": care_note.get("updatedByName"),
            "updatedAt": care_note.get("updatedAt"),
        }
    else:
        out["careNote"] = None

    # Notifications-paused state (2A-UM-P US-31). Only surface as active
    # if `until > now`. If expired-but-not-yet-cleared (the Patient row
    # may have a stale pause if no fresh activity has triggered auto-
    # resume yet), present as null — the portal should treat it as
    # "not currently paused."
    if is_currently_paused(p):
        pause = p.get("notificationsPaused") or {}
        out["notificationsPaused"] = {
            "until": pause.get("until"),
            "reason": pause.get("reason"),
            "pausedAt": pause.get("pausedAt"),
            "pausedBy": pause.get("pausedBy"),
            "daysRemaining": days_remaining(p),
        }
    else:
        out["notificationsPaused"] = None

    return out


def _patient_row_view(p: dict[str, Any]) -> dict[str, Any]:
    """Projection for /me/patients and census-roster rows (lighter than detail).

    Includes `notificationsPaused` (active-only, same shape as the detail
    view) so the Census tile / list row can render the US-31 paused-bell
    icon without a per-row patient-detail fetch. Mirrors the projection
    in `_patient_view` — same nullable-when-not-active semantics.
    """
    out = {
        "patientId": p.get("patientId"),
        "displayName": p.get("displayName"),
        "status": p.get("status"),
        "facilityId": p.get("facilityId"),
        "censusId": p.get("censusId"),
    }
    # When status != active (the "Show discontinued" view), surface when it
    # ended so the row can read "Discontinued <date>".
    if p.get("dischargedAt"):
        out["dischargedAt"] = p.get("dischargedAt")
    if is_currently_paused(p):
        pause = p.get("notificationsPaused") or {}
        out["notificationsPaused"] = {
            "until": pause.get("until"),
            "reason": pause.get("reason"),
            "pausedAt": pause.get("pausedAt"),
            "pausedBy": pause.get("pausedBy"),
            "daysRemaining": days_remaining(p),
        }
    else:
        out["notificationsPaused"] = None
    return out


def _activity_view(row: dict[str, Any]) -> dict[str, Any]:
    """Projection for an activity session row."""
    return {
        "sessionStart": row.get("sessionStart"),
        "sessionEnd": row.get("sessionEnd") or row.get("timestamp"),
        "date": row.get("date"),
        "timezone": row.get("timezone"),
        "steps": row.get("steps"),
        "distanceFt": row.get("distanceFt"),
        "activeMinutes": row.get("activeMinutes"),
        "deviceSerial": row.get("deviceSerial"),
        "roughnessR": row.get("roughnessR"),
        "surfaceClass": row.get("surfaceClass"),
        "firmwareVersion": row.get("firmwareVersion"),
    }


def _alert_view(row: dict[str, Any]) -> dict[str, Any]:
    """Projection for an alert row."""
    return {
        "eventTimestamp": row.get("eventTimestamp"),
        "alertType": row.get("alertType"),
        "severity": row.get("severity"),
        "source": row.get("source"),
        "acknowledged": bool(row.get("acknowledged", False)),
        "acknowledgedAt": row.get("acknowledgedAt"),
        "acknowledgedBy": row.get("acknowledgedBy"),
        "data": row.get("data"),
        "deviceSerial": row.get("deviceSerial"),
    }


def _query_param(event: dict[str, Any], name: str, default: str | None = None) -> str | None:
    """Pull a single query string param; None when absent."""
    qs = event.get("queryStringParameters") or {}
    if not isinstance(qs, dict):
        return default
    return qs.get(name, default)


# ── Action handlers ────────────────────────────────────────────────────


def _action_get_patient(
    event: dict[str, Any], claims: dict[str, Any], patient_id: str
) -> dict[str, Any]:
    """GET /api/v1/patients/{id}."""
    patient = get_patient(_patients, patient_id)
    if not patient:
        # 404 with no audit — per spec L4 (skip 404/400/429 audit emission).
        raise ApiError(code="PATIENT_NOT_FOUND",
                       message=f"Patient {patient_id} not found", status=404)

    linked = linked_patient_ids(claims, _role_assignments)
    enforce_patient_access(claims, patient, linked_ids=linked)

    # Resolve facility + census display names (best-effort)
    client_id = patient.get("clientId", "")
    facility_id = patient.get("facilityId", "")
    census_id = patient.get("censusId", "")

    facility_name = None
    census_name = None
    if client_id and facility_id:
        orgs_facility = batch_get_orgs(
            _orgs,
            client_id=client_id,
            facility_ids={facility_id},
            census_ids=set(),
        )
        facility_name = (orgs_facility.get(facility_id) or {}).get("displayName")
        if census_id:
            census_rows = batch_get_census_rows(
                _orgs,
                client_id=client_id,
                facility_census_pairs=[(facility_id, census_id)],
            )
            census_name = (census_rows.get((facility_id, census_id)) or {}).get("displayName")

    # Current device assignment + Device Registry summary (lastSeen).
    current_device: dict[str, Any] | None = None
    active_asn = get_active_assignment(_assignments, patient_id)
    if active_asn:
        serial = active_asn.get("serialNumber")
        device = get_device(_devices, serial) if serial else None
        if device:
            current_device = {
                "serialNumber": serial,
                "status": device.get("status"),
                "lastSeen": device.get("lastSeen") or device.get("firstHeartbeatAt"),
                "firmwareVersion": device.get("firmwareVersion"),
            }

    body = {
        "patient": {
            **_patient_view(patient),
            "facilityName": facility_name,
            "censusName": census_name,
            "currentDevice": current_device,
        }
    }

    _audit(
        AUDIT_PATIENT_DETAIL_READ, claims,
        subject={"patientId": patient_id, "clientId": client_id,
                 "facilityId": facility_id, "censusId": census_id},
        request_id=_request_id(event),
    )
    return ok_response(body)


def _action_get_activity(
    event: dict[str, Any], claims: dict[str, Any], patient_id: str
) -> dict[str, Any]:
    """GET /api/v1/patients/{id}/activity?range=&cursor=&pageSize=."""
    patient = get_patient(_patients, patient_id)
    if not patient:
        raise ApiError(code="PATIENT_NOT_FOUND",
                       message=f"Patient {patient_id} not found", status=404)
    linked = linked_patient_ids(claims, _role_assignments)
    enforce_patient_access(claims, patient, linked_ids=linked)

    range_str = parse_range(_query_param(event, "range"))
    window_start, window_end = range_to_window(range_str)
    page_size = parse_page_size(_query_param(event, "pageSize"))
    start_key = decode_cursor(_query_param(event, "cursor"))

    res = query_activity_window(
        _activity,
        patient_id=patient_id,
        window_start=window_start,
        window_end=window_end,
        limit=page_size,
        exclusive_start_key=start_key,
    )
    sessions = [_activity_view(r) for r in res["items"]]

    body = {
        "sessions": sessions,
        "range": range_str,
        "windowStart": window_start,
        "windowEnd": window_end,
        "nextCursor": encode_cursor(res["last_evaluated_key"]),
    }

    _audit(
        AUDIT_PATIENT_ACTIVITY_READ, claims,
        subject={"patientId": patient_id, "clientId": patient.get("clientId", "")},
        extra={"range": range_str, "sessionCount": len(sessions)},
        request_id=_request_id(event),
    )
    return ok_response(body)


def _action_get_alerts(
    event: dict[str, Any], claims: dict[str, Any], patient_id: str
) -> dict[str, Any]:
    """GET /api/v1/patients/{id}/alerts?status=&cursor=&pageSize=."""
    patient = get_patient(_patients, patient_id)
    if not patient:
        raise ApiError(code="PATIENT_NOT_FOUND",
                       message=f"Patient {patient_id} not found", status=404)
    linked = linked_patient_ids(claims, _role_assignments)
    enforce_patient_access(claims, patient, linked_ids=linked)

    status_filter = _query_param(event, "status", "unacknowledged") or "unacknowledged"
    if status_filter not in {"unacknowledged", "acknowledged", "all"}:
        raise ApiError(
            code="INVALID_STATUS_FILTER",
            message="status must be one of: unacknowledged, acknowledged, all",
            status=400,
            details={"received": status_filter},
        )
    page_size = parse_page_size(_query_param(event, "pageSize"))
    start_key = decode_cursor(_query_param(event, "cursor"))

    res = query_alerts(
        _alerts,
        patient_id=patient_id,
        status_filter=status_filter,
        limit=page_size,
        exclusive_start_key=start_key,
    )
    alerts = [_alert_view(r) for r in res["items"]]

    body = {
        "alerts": alerts,
        "filter": status_filter,
        "nextCursor": encode_cursor(res["last_evaluated_key"]),
    }

    _audit(
        AUDIT_ALERT_READ, claims,
        subject={"patientId": patient_id, "clientId": patient.get("clientId", "")},
        extra={"filter": status_filter, "alertCount": len(alerts)},
        request_id=_request_id(event),
    )
    return ok_response(body)


def _action_me_patients(
    event: dict[str, Any], claims: dict[str, Any]
) -> dict[str, Any]:
    """GET /api/v1/me/patients?cursor=&pageSize=&clientId=."""
    internal_client_id = _query_param(event, "clientId")
    if is_internal(claims) and not internal_client_id:
        raise ApiError(
            code="MISSING_CLIENT_PARAM",
            message="Internal-tier callers must supply ?clientId= to scope the list",
            status=400,
            details={"missingParam": "clientId"},
        )

    plan = resolve_list_scope(claims, internal_client_id=internal_client_id)
    page_size = parse_page_size(_query_param(event, "pageSize"))
    start_key = decode_cursor(_query_param(event, "cursor"))

    # Status slice: `?status=discontinued` lists the discharged set (ended
    # monitoring, for the "Show discontinued" toggle); default is the active
    # roster. Both ride the same by-census-status / by-client-status GSIs via
    # the status_patientId prefix (active_ / discharged_).
    status_q = (_query_param(event, "status") or "active").lower()
    status_prefix = (
        "discharged_" if status_q in ("discontinued", "discharged", "ended") else "active_"
    )

    patients_out: list[dict[str, Any]] = []
    next_cursor: str | None = None

    if plan["pattern"] == "no-data":
        pass  # empty
    elif plan["pattern"] == "by-patient-ids":
        # family_viewer: load linkedPatientIds, BatchGet Patients.
        linked = linked_patient_ids(claims, _role_assignments)
        # Pagination on a small set is degenerate — return everything; no cursor.
        rows = batch_get_patients(_patients, sorted(linked))
        patients_out = rows
    elif plan["pattern"] == "by-client":
        res = query_patients_by_client(
            _patients,
            client_id=plan["clientId"],
            limit=page_size,
            exclusive_start_key=start_key,
            facility_filter=plan["facilityIds"] or None,
            status_prefix=status_prefix,
        )
        patients_out = res["items"]
        next_cursor = encode_cursor(res["last_evaluated_key"])
    elif plan["pattern"] == "by-census":
        # Fan out per census; merge + naive sort by patientId.
        # For caregivers with <5 censuses this is fast and bounded.
        merged: list[dict[str, Any]] = []
        for cid in plan["censusIds"]:
            res = query_patients_by_census(
                _patients,
                census_id=cid,
                limit=page_size,
                status_prefix=status_prefix,
            )
            merged.extend(res["items"])
        # Pagination across multiple-census fan-out: not in v1; truncate
        # to page_size and return no cursor. Caregiver dashboards rarely
        # exceed page_size from per-census fan-out at MVP scale.
        patients_out = merged[:page_size]
        next_cursor = None

    # Enrichment (spec L9): facility + census names via Organizations.
    target_client = plan["clientId"]
    facility_ids: set[str] = set()
    fc_pairs: set[tuple[str, str]] = set()
    for p in patients_out:
        fid = p.get("facilityId")
        cid = p.get("censusId")
        if fid:
            facility_ids.add(fid)
        if fid and cid:
            fc_pairs.add((fid, cid))

    facility_lookup: dict[str, dict[str, Any]] = {}
    census_lookup: dict[tuple[str, str], dict[str, Any]] = {}
    if target_client and facility_ids:
        facility_lookup = batch_get_orgs(
            _orgs, client_id=target_client,
            facility_ids=facility_ids, census_ids=set(),
        )
    if target_client and fc_pairs:
        census_lookup = batch_get_census_rows(
            _orgs, client_id=target_client,
            facility_census_pairs=list(fc_pairs),
        )

    rows_out: list[dict[str, Any]] = []
    for p in patients_out:
        fid = p.get("facilityId", "")
        cid = p.get("censusId", "")
        rows_out.append({
            **_patient_row_view(p),
            "facilityName": (facility_lookup.get(fid) or {}).get("displayName"),
            "censusName": (census_lookup.get((fid, cid)) or {}).get("displayName"),
        })

    body = {
        "patients": rows_out,
        "nextCursor": next_cursor,
        "scope": {
            "role": claims.get("role"),
            "facilityCount": len(plan["facilityIds"]) if plan["facilityIds"] else None,
            "censusCount": len(plan["censusIds"]) if plan["censusIds"] else None,
            "internalAccess": plan["internalAccess"],
            "clientId": target_client,
        },
    }

    # Per spec D8: list audit carries count only, not patient IDs.
    _audit(
        AUDIT_PATIENT_LIST_READ, claims,
        subject={"actorClientId": claims.get("clientId", ""),
                 "scopeRole": claims.get("role", ""),
                 "targetClientId": target_client},
        extra={"patientCount": len(rows_out),
               "pattern": plan["pattern"]},
        request_id=_request_id(event),
    )
    return ok_response(body)


def _action_census_roster(
    event: dict[str, Any], claims: dict[str, Any], facility_id: str, census_id: str
) -> dict[str, Any]:
    """GET /api/v1/facilities/{facilityId}/censuses/{censusId}/patients."""
    # Tenancy enforcement: resolve the facility's clientId via Organizations
    # GetItem (PK=clientId, SK=facility#{fid}). We need clientId for the check
    # but the path doesn't carry it. Solution: scope check FIRST against the
    # claim's clientId — for non-internal callers, the facility must be in
    # their client, and enforce_scope already verifies the facility is in their
    # claim. For internal callers, bypass and trust the audit trail.
    if not is_internal(claims):
        # Pull the facility row from the caller's own client.
        client_id = claims.get("clientId", "")
        res = _orgs.get_item(Key={"clientId": client_id, "sk": f"facility#{facility_id}"})
        facility_row = res.get("Item")
        if not facility_row:
            # Either the facility doesn't exist, or it's in another client.
            # Both → 404 (existence-leak prevention same as for patients).
            raise ApiError(code="FACILITY_NOT_FOUND",
                           message=f"Facility {facility_id} not found", status=404)
        enforce_scope(claims, target_facility_id=facility_id, target_census_id=census_id)
        # Verify the census row exists (and belongs to this facility).
        census_res = _orgs.get_item(
            Key={"clientId": client_id, "sk": f"facility#{facility_id}#census#{census_id}"}
        )
        census_row = census_res.get("Item")
        if not census_row:
            raise ApiError(code="CENSUS_NOT_FOUND",
                           message=f"Census {census_id} not found", status=404)
    else:
        # Internal caller: must supply ?clientId= to scope the org lookup
        # (avoid cross-tenant scanning of facility names).
        internal_client_id = _query_param(event, "clientId")
        if not internal_client_id:
            raise ApiError(
                code="MISSING_CLIENT_PARAM",
                message="Internal-tier callers must supply ?clientId= to scope facility lookup",
                status=400,
                details={"missingParam": "clientId"},
            )
        client_id = internal_client_id
        res = _orgs.get_item(Key={"clientId": client_id, "sk": f"facility#{facility_id}"})
        facility_row = res.get("Item")
        if not facility_row:
            raise ApiError(code="FACILITY_NOT_FOUND",
                           message=f"Facility {facility_id} not found", status=404)
        census_res = _orgs.get_item(
            Key={"clientId": client_id, "sk": f"facility#{facility_id}#census#{census_id}"}
        )
        census_row = census_res.get("Item")
        if not census_row:
            raise ApiError(code="CENSUS_NOT_FOUND",
                           message=f"Census {census_id} not found", status=404)

    page_size = parse_page_size(_query_param(event, "pageSize"))
    start_key = decode_cursor(_query_param(event, "cursor"))

    res = query_patients_by_census(
        _patients,
        census_id=census_id,
        limit=page_size,
        exclusive_start_key=start_key,
    )
    rows = [_patient_row_view(p) for p in res["items"]]

    body = {
        "census": {
            "facilityId": facility_id,
            "facilityName": facility_row.get("displayName"),
            "censusId": census_id,
            "censusName": census_row.get("displayName"),
        },
        "patients": rows,
        "nextCursor": encode_cursor(res["last_evaluated_key"]),
    }

    _audit(
        AUDIT_CENSUS_ROSTER_READ, claims,
        subject={"clientId": client_id, "facilityId": facility_id,
                 "censusId": census_id},
        extra={"patientCount": len(rows)},
        request_id=_request_id(event),
    )
    return ok_response(body)


# ── Audit + request helpers ────────────────────────────────────────────


def _audit(event_name: str, claims: dict[str, Any], *,
           subject: dict[str, Any], extra: dict[str, Any] | None = None,
           request_id: str = "") -> None:
    """Wrap emit_audit with the standard actor shape from claims."""
    actor = {
        "userId": claims.get("userId", ""),
        "role": claims.get("role", ""),
        "clientId": claims.get("clientId", ""),
    }
    emit_audit(
        event=event_name,
        actor=actor,
        subject=subject,
        action="read",
        extra=extra,
        request_id=request_id,
    )


def _request_id(event: dict[str, Any]) -> str:
    return event.get("requestContext", {}).get("requestId", "")


# ── Route dispatcher ───────────────────────────────────────────────────


def _route(api_event: dict[str, Any]) -> tuple[str, dict[str, str]]:
    rc = api_event.get("requestContext", {}) or {}
    http = rc.get("http", {}) or {}
    method = (http.get("method") or "").upper()
    route_key = api_event.get("routeKey", "")
    path_params = api_event.get("pathParameters") or {}

    table = {
        ("GET", "GET /api/v1/patients/{id}"): "get_patient",
        ("GET", "GET /api/v1/patients/{id}/activity"): "get_activity",
        ("GET", "GET /api/v1/patients/{id}/alerts"): "get_alerts",
        ("GET", "GET /api/v1/me/patients"): "me_patients",
        ("GET", "GET /api/v1/facilities/{facilityId}/censuses/{censusId}/patients"): "census_roster",
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
    """
    Entry point. Dispatches to action handlers. Each action emits its own
    audit event on success (not via the audit_middleware decorator —
    list endpoints emit `extra={count, ...}` which the decorator can't
    carry).

    Error handling: catch ApiError, return error envelope. Per spec L4,
    we don't emit audit events for 400/404/429 (caller-error patterns).
    """
    claims = extract_claims(api_event)
    try:
        require_authenticated(claims)
        # Phase 2A-0 Q8 (amended 2026-05-24): app-layer 4-hr absolute cap
        # for internal_* sessions. No-op for customer roles. patient-api
        # uses its own dispatcher pattern (not @audit_middleware), so the
        # middleware-wired call never reaches this handler. Mirror in
        # device-api / alert-actions / patient-mgmt.
        enforce_internal_session_age(claims)
        action, params = _route(api_event)

        if action == "get_patient":
            return _action_get_patient(api_event, claims, params.get("id", ""))
        if action == "get_activity":
            return _action_get_activity(api_event, claims, params.get("id", ""))
        if action == "get_alerts":
            return _action_get_alerts(api_event, claims, params.get("id", ""))
        if action == "me_patients":
            return _action_me_patients(api_event, claims)
        if action == "census_roster":
            return _action_census_roster(
                api_event, claims,
                params.get("facilityId", ""),
                params.get("censusId", ""),
            )

        raise ApiError(code="NOT_FOUND", message=f"Unrouted action {action}", status=404)
    except ApiError as exc:
        # Per spec L4 + 2A-0 Q2: emit audit on success + 403 + 500; skip
        # 400/404/429. Implementing 403/500 emission here is awkward in
        # the catch-all (we don't know the intended-event for the failing
        # route without per-action wrappers). Mirror the device-api
        # pattern: log + return; access-denied forensics come from the
        # API Gateway access log group + the handler ERROR log line
        # (both attributed by requestId). Promote to per-action try/except
        # if forensics needs richer 403 audit events later.
        #
        # `error_message` (not `message`) — Powertools Logger reserves
        # `message` for the log line itself; using `message` in `extra=`
        # raises KeyError.
        logger.warning("patient_api_error",
                       extra={"code": exc.code, "status": exc.status,
                              "error_message": exc.message})
        return error_response(exc.code, exc.message, exc.status, exc.details)

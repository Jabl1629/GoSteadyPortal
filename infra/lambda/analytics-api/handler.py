"""
Analytics API handler — internal user & population analytics (DRAFT).

Spec: docs/specs/user-analytics.md

Internal-only (internal_admin / internal_support), cross-tenant population view.
Three GET routes:
  GET /api/v1/admin/analytics/overview?range=24h|7d|30d      → population KPIs
  GET /api/v1/admin/analytics/users?range=                   → per-user table
  GET /api/v1/admin/analytics/users/{userId}?range=          → single-user drill-down

Data (user-analytics.md L2): Activity Series (offloads #1) via a bounded scan +
the audit log group via ONE Logs Insights query (logins #2, OTP funnel #3,
active-time #4, coach turns #5) — aggregated in-process by `aggregate.py`. No
new store; on-demand only. Every read emits an internal, count-only-subject
audit event (auto-elevated `internal_access` by the forwarder).
"""

from __future__ import annotations

import os
from datetime import datetime, timedelta, timezone
from typing import Any

import boto3

from _shared.api_authz import (
    enforce_internal_session_age,
    extract_claims,
    require_authenticated,
    require_role,
)
from _shared.api_error import ApiError, error_response, ok_response
from _shared.audit_catalog import (
    AUDIT_ANALYTICS_OVERVIEW_READ,
    AUDIT_ANALYTICS_USERS_READ,
)
from _shared.observability import emit_audit, get_logger

from aggregate import (
    bucket_offloads,
    funnel_totals,
    index_events,
    offloads_by_user,
    otp_funnel_by_user,
    sessionize,
)
from queries import (
    get_device_last_seen,
    run_audit_insights,
    scan_activity_window,
    scan_patient_device_map,
    scan_patient_user_map,
    scan_user_roster,
    scan_walker_flags,
)

ENV = os.environ.get("ENVIRONMENT", "dev")
ACTIVITY_TABLE = os.environ["ACTIVITY_TABLE"]
PATIENTS_TABLE = os.environ["PATIENTS_TABLE"]
USERS_TABLE = os.environ["USERS_TABLE"]
DEVICE_ASSIGNMENTS_TABLE = os.environ["DEVICE_ASSIGNMENTS_TABLE"]
DEVICES_TABLE = os.environ["DEVICES_TABLE"]
ROLE_ASSIGNMENTS_TABLE = os.environ["ROLE_ASSIGNMENTS_TABLE"]
AUDIT_LOG_GROUP = os.environ.get("AUDIT_LOG_GROUP", f"gosteady-{ENV}-audit")
QUERY_TIMEOUT_S = int(os.environ.get("ANALYTICS_QUERY_TIMEOUT_S", "15"))

logger = get_logger()
_ddb = boto3.resource("dynamodb")
_activity = _ddb.Table(ACTIVITY_TABLE)
_patients = _ddb.Table(PATIENTS_TABLE)
_users = _ddb.Table(USERS_TABLE)
_assignments = _ddb.Table(DEVICE_ASSIGNMENTS_TABLE)
_devices = _ddb.Table(DEVICES_TABLE)
_role = _ddb.Table(ROLE_ASSIGNMENTS_TABLE)
_logs = boto3.client("logs")

_RANGES = {"24h": timedelta(hours=24), "7d": timedelta(days=7), "30d": timedelta(days=30)}


# ── range + param helpers ──────────────────────────────────────────────

def _resolve_range(range_str: str | None) -> dict[str, Any]:
    """Map 24h|7d|30d → window bounds in both ISO (DDB) and epoch-secs (Insights).

    Defaults to 7d. >30d is intentionally unsupported (mirrors patient-api's
    30d cap — longer history is the deferred rollup's job, user-analytics D5)."""
    key = (range_str or "7d").lower()
    if key not in _RANGES:
        raise ApiError(
            code="INVALID_RANGE",
            message="range must be one of: 24h, 7d, 30d",
            status=400,
            details={"received": range_str, "allowed": list(_RANGES)},
        )
    now = datetime.now(timezone.utc)
    start = now - _RANGES[key]
    return {
        "range": key,
        "start_iso": start.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "end_iso": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "start_epoch": int(start.timestamp()),
        "end_epoch": int(now.timestamp()),
    }


def _query_param(event: dict[str, Any], name: str, default: str | None = None) -> str | None:
    qs = event.get("queryStringParameters") or {}
    if not isinstance(qs, dict):
        return default
    return qs.get(name, default)


def _iso(epoch: float | None) -> str | None:
    if not epoch:
        return None
    return datetime.fromtimestamp(epoch, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _meta_and_last_active(events: list[dict[str, Any]]) -> tuple[dict[str, dict[str, str]], dict[str, float]]:
    """Per-user {clientId, role} (first non-empty seen) + last-active epoch."""
    meta: dict[str, dict[str, str]] = {}
    last_active: dict[str, float] = {}
    for e in events:
        uid = e.get("uid") or ""
        if not uid:
            continue
        m = meta.setdefault(uid, {"clientId": "", "role": ""})
        if not m["clientId"] and e.get("cid"):
            m["clientId"] = e["cid"]
        if not m["role"] and e.get("role"):
            m["role"] = e["role"]
        ts = e.get("ts")
        if ts is not None and ts > last_active.get(uid, 0):
            last_active[uid] = ts
    return meta, last_active


# ── #1/#4 helpers shared by the actions ────────────────────────────────

def _active_minutes(epochs: list[float]) -> int:
    _sessions, seconds = sessionize(epochs)
    return int(round(seconds / 60))


# ── actions ────────────────────────────────────────────────────────────

def _action_overview(event: dict[str, Any], claims: dict[str, Any]) -> dict[str, Any]:
    rng = _resolve_range(_query_param(event, "range"))

    activity = scan_activity_window(_activity, start_iso=rng["start_iso"], end_iso=rng["end_iso"])
    offloads = bucket_offloads(activity["rows"])

    events, status = run_audit_insights(
        _logs, log_group=AUDIT_LOG_GROUP,
        start_epoch=rng["start_epoch"], end_epoch=rng["end_epoch"],
        timeout_s=QUERY_TIMEOUT_S,
    )
    idx = index_events(events)

    funnel_pu = otp_funnel_by_user(
        idx["requested_by_user"], idx["sms_login_by_user"], idx["verify_failed_by_user"]
    )
    otp = funnel_totals(funnel_pu)

    # #4 active-time across the population.
    total_sessions = 0
    total_active_seconds = 0.0
    active_users = 0
    for epochs in idx["active_epochs_by_user"].values():
        sessions, seconds = sessionize(epochs)
        if sessions:
            active_users += 1
        total_sessions += sessions
        total_active_seconds += seconds
    avg_session_minutes = (
        round(total_active_seconds / total_sessions / 60, 1) if total_sessions else 0.0
    )

    logins_by_method = idx["logins_by_method"]
    coach_turns = sum(idx["coach_by_user"].values())

    body = {
        "range": rng["range"],
        "since": rng["start_iso"],
        "until": rng["end_iso"],
        "logins": {"total": sum(logins_by_method.values()), "byMethod": logins_by_method},
        "otp": otp,
        "activeUsers": active_users,
        "avgSessionMinutes": avg_session_minutes,
        "offloads": offloads,
        "coach": {"turns": coach_turns, "activeUsers": len(idx["coach_by_user"])},
        # Honesty flags (A1/A2): partial Insights + scan truncation are surfaced,
        # not silently swallowed.
        "meta": {
            "insightsStatus": status,
            "offloadTruncated": activity["truncated"],
            "note": "Auth/OTP/active-time populate from the deploy date forward (no backfill).",
        },
    }

    _audit(AUDIT_ANALYTICS_OVERVIEW_READ, claims,
           subject={"userCount": len(idx["users_seen"])},
           extra={"range": rng["range"], "insightsStatus": status},
           request_id=_request_id(event))
    return ok_response(body)


def _action_users(event: dict[str, Any], claims: dict[str, Any]) -> dict[str, Any]:
    rng = _resolve_range(_query_param(event, "range"))

    activity = scan_activity_window(_activity, start_iso=rng["start_iso"], end_iso=rng["end_iso"])
    patient_to_user = scan_patient_user_map(_patients)
    offloads_pu = offloads_by_user(activity["rows"], patient_to_user)

    # Device ID per user: the serial currently assigned to the user's patient
    # (same cognitoUserId link the offloads use). Surfaces "has a device, zero
    # offloads" rows. A user with no account-linked patient (e.g. family_viewer)
    # → no serial.
    patient_to_serial = scan_patient_device_map(_assignments)
    user_to_serial: dict[str, str] = {}
    for pid, uid in patient_to_user.items():
        serial = patient_to_serial.get(pid)
        if serial and uid:
            user_to_serial.setdefault(uid, serial)
    # Device REAL last-seen (registry lastSeen = last heartbeat) — distinct from
    # the user's in-app activity. Keyed by serial so N users on 1 device share it.
    serial_last_seen = get_device_last_seen(_devices, set(user_to_serial.values()))

    events, status = run_audit_insights(
        _logs, log_group=AUDIT_LOG_GROUP,
        start_epoch=rng["start_epoch"], end_epoch=rng["end_epoch"],
        timeout_s=QUERY_TIMEOUT_S,
    )
    idx = index_events(events)
    funnel_pu = otp_funnel_by_user(
        idx["requested_by_user"], idx["sms_login_by_user"], idx["verify_failed_by_user"]
    )
    meta, last_active = _meta_and_last_active(events)

    roster = scan_user_roster(_users)
    roster_client = {u.get("userId", ""): u.get("clientId", "") for u in roster}

    # Walker-vs-care-circle: the authoritative isWalkerUser flag per user
    # (RoleAssignments), so the dashboard can segment the metrics.
    walker_flags = scan_walker_flags(_role)

    # Union of everyone we have ANY signal for.
    user_ids = (
        set(roster_client)
        | idx["users_seen"]
        | {u for u in offloads_pu if u}
    )

    rows: list[dict[str, Any]] = []
    for uid in user_ids:
        logins = len(idx["login_epochs_by_user"].get(uid, []))
        rows.append({
            "userId": uid,
            "clientId": meta.get(uid, {}).get("clientId") or roster_client.get(uid, ""),
            "role": meta.get(uid, {}).get("role", ""),
            "isWalkerUser": walker_flags.get(uid, False),
            "deviceSerial": user_to_serial.get(uid, ""),
            "deviceLastSeen": serial_last_seen.get(user_to_serial.get(uid, ""), ""),
            "logins": logins,
            "otpAbandoned": funnel_pu.get(uid, {}).get("abandoned", 0),
            "otpVerifyFailed": funnel_pu.get(uid, {}).get("verifyFailed", 0),
            "activeMinutes": _active_minutes(idx["active_epochs_by_user"].get(uid, [])),
            "offloads": offloads_pu.get(uid, 0),
            "coachTurns": idx["coach_by_user"].get(uid, 0),
            "lastActive": _iso(last_active.get(uid)),
        })

    # Sort most-engaged first; pagination is degenerate at pilot scale (A1) —
    # return the full set (like patient-api's family_viewer branch).
    rows.sort(key=lambda r: (r["activeMinutes"], r["logins"], r["coachTurns"]), reverse=True)

    unattributed = offloads_pu.get("", 0)
    body = {
        "range": rng["range"],
        "since": rng["start_iso"],
        "until": rng["end_iso"],
        "users": rows,
        "count": len(rows),
        "nextCursor": None,
        "meta": {
            "insightsStatus": status,
            "offloadTruncated": activity["truncated"],
            "unattributedOffloads": unattributed,
        },
    }

    _audit(AUDIT_ANALYTICS_USERS_READ, claims,
           subject={"userCount": len(rows)},
           extra={"range": rng["range"], "insightsStatus": status},
           request_id=_request_id(event))
    return ok_response(body)


def _action_user_detail(event: dict[str, Any], claims: dict[str, Any], user_id: str) -> dict[str, Any]:
    if not user_id:
        raise ApiError(code="INVALID_REQUEST", message="userId is required", status=400)
    rng = _resolve_range(_query_param(event, "range"))

    # This user's patient(s) → their offload rows.
    patient_to_user = scan_patient_user_map(_patients)
    my_patients = {pid for pid, uid in patient_to_user.items() if uid == user_id}
    activity = scan_activity_window(_activity, start_iso=rng["start_iso"], end_iso=rng["end_iso"])
    my_rows = [r for r in activity["rows"] if r.get("patientId") in my_patients]
    offloads = bucket_offloads(my_rows)

    events, status = run_audit_insights(
        _logs, log_group=AUDIT_LOG_GROUP,
        start_epoch=rng["start_epoch"], end_epoch=rng["end_epoch"],
        timeout_s=QUERY_TIMEOUT_S,
    )
    mine = [e for e in events if e.get("uid") == user_id]
    idx = index_events(mine)
    funnel_pu = otp_funnel_by_user(
        idx["requested_by_user"], idx["sms_login_by_user"], idx["verify_failed_by_user"]
    )
    meta, last_active = _meta_and_last_active(mine)
    sessions, seconds = sessionize(idx["active_epochs_by_user"].get(user_id, []))

    body = {
        "userId": user_id,
        "range": rng["range"],
        "since": rng["start_iso"],
        "until": rng["end_iso"],
        "clientId": meta.get(user_id, {}).get("clientId", ""),
        "role": meta.get(user_id, {}).get("role", ""),
        "lastActive": _iso(last_active.get(user_id)),
        "logins": {
            "total": len(idx["login_epochs_by_user"].get(user_id, [])),
            "byMethod": idx["logins_by_method"],
        },
        "otp": funnel_totals(funnel_pu),
        "activeMinutes": int(round(seconds / 60)),
        "sessions": sessions,
        "coachTurns": idx["coach_by_user"].get(user_id, 0),
        "offloads": offloads,
        "meta": {"insightsStatus": status, "offloadTruncated": activity["truncated"]},
    }

    _audit(AUDIT_ANALYTICS_USERS_READ, claims,
           subject={"targetUserId": user_id},
           extra={"range": rng["range"], "insightsStatus": status, "drilldown": True},
           request_id=_request_id(event))
    return ok_response(body)


# ── audit + request helpers ────────────────────────────────────────────

def _audit(event_name: str, claims: dict[str, Any], *,
           subject: dict[str, Any], extra: dict[str, Any] | None = None,
           request_id: str = "") -> None:
    emit_audit(
        event=event_name,
        actor={
            "userId": claims.get("userId", ""),
            "role": claims.get("role", ""),
            "clientId": claims.get("clientId", ""),
        },
        subject=subject,
        action="read",
        extra=extra,
        request_id=request_id,
    )


def _request_id(event: dict[str, Any]) -> str:
    return event.get("requestContext", {}).get("requestId", "")


# ── routing ────────────────────────────────────────────────────────────

def _route(api_event: dict[str, Any]) -> tuple[str, dict[str, str]]:
    rc = api_event.get("requestContext", {}) or {}
    http = rc.get("http", {}) or {}
    method = (http.get("method") or "").upper()
    route_key = api_event.get("routeKey", "")
    path_params = api_event.get("pathParameters") or {}
    table = {
        ("GET", "GET /api/v1/admin/analytics/overview"): "overview",
        ("GET", "GET /api/v1/admin/analytics/users"): "users",
        ("GET", "GET /api/v1/admin/analytics/users/{userId}"): "user_detail",
    }
    action = table.get((method, route_key))
    if not action:
        raise ApiError(code="NOT_FOUND",
                       message=f"No route matches {method} {route_key}", status=404)
    return action, path_params


def handler(api_event: dict[str, Any], context: Any) -> dict[str, Any]:
    claims = extract_claims(api_event)
    try:
        require_authenticated(claims)
        # Internal-only (L1). require_role does NOT auto-allow internal_* — both
        # internal roles are named explicitly.
        require_role(claims, "internal_admin", "internal_support")
        # 4-hr absolute cap for internal sessions (2A-0 Q8) — no-op otherwise.
        enforce_internal_session_age(claims)

        action, params = _route(api_event)
        if action == "overview":
            return _action_overview(api_event, claims)
        if action == "users":
            return _action_users(api_event, claims)
        if action == "user_detail":
            return _action_user_detail(api_event, claims, params.get("userId", ""))
        raise ApiError(code="NOT_FOUND", message=f"Unrouted action {action}", status=404)
    except ApiError as exc:
        logger.warning("analytics_api_error",
                       extra={"code": exc.code, "status": exc.status,
                              "error_message": exc.message})
        return error_response(exc.code, exc.message, exc.status, exc.details)

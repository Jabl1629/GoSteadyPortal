"""
I/O wrappers for the internal user-analytics dashboard.

Two data sources (docs/specs/user-analytics.md L2):
  1. DynamoDB — Activity Series (offloads #1), Patients + Users (roster + the
     patientId→userId join). At pilot scale (A1: ≤ ~50 users) a bounded Scan
     with a time filter is acceptable — the fleet board (device-fleet-ops-
     tooling.md A3) set the same precedent. The scale path is the deferred
     Phase 1C rollup, NOT a rework here.
  2. CloudWatch Logs Insights over the audit log group — the auth funnel
     (#2/#3), active-time reads (#4), and coach turns (#5). On-demand,
     start_query→poll (L2 "reuse audit pipeline + on-demand queries").

Wrappers take the boto3 resource/client as the first arg so the shaping in
aggregate.py stays pure and these stay mockable.
"""

from __future__ import annotations

import time
from typing import Any

from boto3.dynamodb.conditions import Attr

# The event names Logs Insights pulls for the auth funnel + active-time + coach.
# Mirrors aggregate.ACTIVE_SIGNAL_EVENTS plus the OTP funnel events.
_INSIGHTS_EVENTS = [
    "auth.login",
    "auth.otp_requested",
    "auth.otp_verify_failed",
    "auth.token_refresh",
    "auth.session.read",
    "patient.list.read",
    "patient.detail.read",
    "patient.activity.read",
    "alert.read",
    "census.roster.read",
    "coach.chat.turn",
]

# Bounded page size for the pilot-scale scans. Well above trial volume; the
# handler logs a truncation warning if a scan actually hits the cap (A1).
_SCAN_PAGE_CAP = 5000
_INSIGHTS_ROW_CAP = 10000


def scan_activity_window(activity_table: Any, *, start_iso: str, end_iso: str,
                         cap: int = _SCAN_PAGE_CAP) -> dict[str, Any]:
    """Scan Activity Series for rows whose session_end (`timestamp`) is in
    [start_iso, end_iso]. Returns {"rows": [...], "truncated": bool}.

    Projection trims to just what the metrics need — keeps the payload small
    and avoids dragging gait/surface/extras across the wire.
    """
    rows: list[dict[str, Any]] = []
    kwargs: dict[str, Any] = {
        "FilterExpression": Attr("timestamp").between(start_iso, end_iso),
        "ProjectionExpression": "patientId, #ts, #d, deviceSerial, clientId, sessionEnd",
        "ExpressionAttributeNames": {"#ts": "timestamp", "#d": "date"},
    }
    truncated = False
    while True:
        res = activity_table.scan(**kwargs)
        rows.extend(res.get("Items", []))
        lek = res.get("LastEvaluatedKey")
        if not lek or len(rows) >= cap:
            truncated = bool(lek) and len(rows) >= cap
            break
        kwargs["ExclusiveStartKey"] = lek
    return {"rows": rows[:cap], "truncated": truncated}


def scan_patient_user_map(patients_table: Any) -> dict[str, str]:
    """patientId → cognitoUserId, for attributing offloads to a user (#1 per-user).

    A patient with no `cognitoUserId` (account-less walker) is simply absent
    from the map; the caller buckets those offloads as unattributed.
    """
    mapping: dict[str, str] = {}
    kwargs: dict[str, Any] = {
        "ProjectionExpression": "patientId, cognitoUserId",
    }
    while True:
        res = patients_table.scan(**kwargs)
        for it in res.get("Items", []):
            uid = it.get("cognitoUserId")
            if uid:
                mapping[it.get("patientId", "")] = uid
        lek = res.get("LastEvaluatedKey")
        if not lek:
            break
        kwargs["ExclusiveStartKey"] = lek
    return mapping


def scan_patient_device_map(assignments_table: Any) -> dict[str, str]:
    """patientId → current device serial (active assignment = `validUntil` absent).

    Mirrors patient-api `get_active_assignment`'s active predicate. If a patient
    somehow has >1 active row, the most-recently-assigned (`assignedAt`) wins.
    Bounded scan — fine at pilot scale (A1); the by-patient GSI is the scale path.
    """
    latest: dict[str, tuple[str, str]] = {}  # patientId -> (assignedAt, serial)
    kwargs: dict[str, Any] = {
        "FilterExpression": Attr("validUntil").not_exists(),
        "ProjectionExpression": "patientId, serialNumber, assignedAt",
    }
    while True:
        res = assignments_table.scan(**kwargs)
        for it in res.get("Items", []):
            pid = it.get("patientId")
            serial = it.get("serialNumber")
            if not pid or not serial:
                continue
            aa = str(it.get("assignedAt", ""))
            if pid not in latest or aa > latest[pid][0]:
                latest[pid] = (aa, serial)
        lek = res.get("LastEvaluatedKey")
        if not lek:
            break
        kwargs["ExclusiveStartKey"] = lek
    return {pid: serial for pid, (_aa, serial) in latest.items()}


def get_device_last_seen(devices_table: Any, serials: set[str]) -> dict[str, str]:
    """serial → Device Registry `lastSeen` (the denormalized last-heartbeat the
    heartbeat-processor writes — the device's REAL online signal, distinct from
    a user's app activity). Per-serial GetItem on the Table resource (pilot
    scale: a handful of unique devices per dashboard). Absent lastSeen → omitted.
    """
    out: dict[str, str] = {}
    for s in serials:
        if not s:
            continue
        res = devices_table.get_item(
            Key={"serialNumber": s}, ProjectionExpression="lastSeen"
        )
        ls = (res.get("Item") or {}).get("lastSeen")
        if ls:
            out[s] = ls
    return out


def scan_walker_flags(role_assignments_table: Any) -> dict[str, bool]:
    """userId → isWalkerUser (bool). The authoritative walker-vs-care-circle
    signal (the same `isWalkerUser` that drives walker-alert-suppression),
    resolved exactly like d2c-pre-token.resolve_is_walker_user: an explicit
    flag wins; absent → derived from role (a solo `household_owner` IS the
    walker; everyone else — family_viewer, caregiver, internal — is not).

    Bounded scan of RoleAssignments (PK=userId), pilot scale.
    """
    out: dict[str, bool] = {}
    kwargs: dict[str, Any] = {
        "ProjectionExpression": "userId, #r, isWalkerUser",
        "ExpressionAttributeNames": {"#r": "role"},
    }
    while True:
        res = role_assignments_table.scan(**kwargs)
        for it in res.get("Items", []):
            uid = it.get("userId")
            if not uid:
                continue
            raw = it.get("isWalkerUser")
            if raw is None:
                out[uid] = it.get("role") == "household_owner"
            else:
                out[uid] = bool(raw)
        lek = res.get("LastEvaluatedKey")
        if not lek:
            break
        kwargs["ExclusiveStartKey"] = lek
    return out


def scan_user_roster(users_table: Any) -> list[dict[str, Any]]:
    """All users (the per-user analytics table is one row per user). PII (email,
    displayName) is intentionally NOT projected — the internal viewer keys on
    userId + clientId + role; names are resolved elsewhere if ever needed."""
    users: list[dict[str, Any]] = []
    kwargs: dict[str, Any] = {
        "ProjectionExpression": "userId, clientId, createdAt",
    }
    while True:
        res = users_table.scan(**kwargs)
        users.extend(res.get("Items", []))
        lek = res.get("LastEvaluatedKey")
        if not lek:
            break
        kwargs["ExclusiveStartKey"] = lek
    return users


def run_audit_insights(logs_client: Any, *, log_group: str,
                       start_epoch: int, end_epoch: int,
                       timeout_s: int = 15,
                       poll_interval_s: float = 0.5,
                       ) -> tuple[list[dict[str, Any]], str]:
    """Run ONE Logs Insights query over the audit log group and return
    (events, status). Events are flat dicts {event, uid, cid, role, method, ts}.

    `ts` is epoch-seconds parsed from the audit `timestamp` field (fallback
    @timestamp). One async query serves every audit-sourced metric — the
    handler does all aggregation in-process (aggregate.index_events)."""
    events_filter = ", ".join(f'"{e}"' for e in _INSIGHTS_EVENTS)
    query = (
        "fields @timestamp, event, actor.userId as uid, actor.clientId as cid, "
        "actor.role as role, extra.method as method, timestamp as ats\n"
        f"| filter event in [{events_filter}]\n"
        "| sort @timestamp asc\n"
        f"| limit {_INSIGHTS_ROW_CAP}"
    )
    start_resp = logs_client.start_query(
        logGroupName=log_group,
        startTime=start_epoch,
        endTime=end_epoch,
        queryString=query,
        limit=_INSIGHTS_ROW_CAP,
    )
    query_id = start_resp["queryId"]
    deadline = time.time() + timeout_s
    status = "Running"
    results: list[list[dict[str, str]]] = []
    while time.time() < deadline:
        out = logs_client.get_query_results(queryId=query_id)
        status = out.get("status", "Running")
        if status in ("Complete", "Failed", "Cancelled", "Timeout"):
            results = out.get("results", [])
            break
        time.sleep(poll_interval_s)
    else:
        # Ran out of time — stop the query so it doesn't keep scanning, return
        # whatever partial results are available.
        try:
            logs_client.stop_query(queryId=query_id)
        except Exception:  # noqa: BLE001 — stop is best-effort
            pass
        out = logs_client.get_query_results(queryId=query_id)
        results = out.get("results", [])
        status = out.get("status", status)

    # Import here to avoid a module-level dep in unit tests of the pure core.
    from aggregate import parse_epoch

    flat: list[dict[str, Any]] = []
    for row in results:
        rec = {c.get("field", ""): c.get("value", "") for c in row}
        ts = parse_epoch(rec.get("ats")) or parse_epoch(rec.get("@timestamp"))
        flat.append({
            "event": rec.get("event", ""),
            "uid": rec.get("uid", ""),
            "cid": rec.get("cid", ""),
            "role": rec.get("role", ""),
            "method": rec.get("method", ""),
            "ts": ts,
        })
    return flat, status

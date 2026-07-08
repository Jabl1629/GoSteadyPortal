"""
Activity Series query + day-aggregation helpers — Phase 1C-slim.

Activity Series schema (Phase 0B-rev):
  PK = patientId
  SK = sessionEnd (UTC ISO 8601)
  attributes: steps, distanceFt, activeMinutes, date (facility-local
              YYYY-MM-DD), timezone, deviceSerial, ...

For the behavioral rules we need (re-keyed onto activeMinutes per DT-4
WS2 — activeMinutes is the universal cross-type metric; steps is walker-
only and a rollator produces none):
  - today_active_minutes:      sum(activeMinutes) over rows with sessionEnd
                               in [local_midnight, local_now]
  - history_active_min_per_day: list[int] of daily totals over the last
                               N days (oldest first, today excluded),
                               where each day is delimited by the
                               PATIENT's facility-local midnight

The Activity rows already carry the `date` field set by activity-processor
using the patient's timezone — so we can group by `date` directly without
re-computing tz offsets here. Aggregation is in-process; bounded by
DDB Query LIMIT (default 1000 rows per Query, plenty for 30 days of
typical activity).
"""

from __future__ import annotations

import os
from datetime import datetime, timedelta, timezone
from typing import Any
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from boto3.dynamodb.conditions import Key


def _to_utc_iso(dt: datetime) -> str:
    """ISO 8601 in UTC with Z suffix — matches Activity Series SK format."""
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def facility_local_now(tz_name: str) -> datetime:
    """Current time in the facility's local zone. Falls back to UTC on bad zone."""
    try:
        return datetime.now(ZoneInfo(tz_name))
    except ZoneInfoNotFoundError:
        return datetime.now(timezone.utc)


def facility_local_midnight(tz_name: str, now: datetime | None = None) -> datetime:
    """Today's midnight in the facility's local zone (returned in that local zone)."""
    n = now if now is not None else facility_local_now(tz_name)
    return n.replace(hour=0, minute=0, second=0, microsecond=0)


def query_activity_for_today(
    activity_table: Any,
    *,
    patient_id: str,
    tz_name: str,
    now: datetime | None = None,
) -> list[dict[str, Any]]:
    """
    Activity Series rows whose sessionEnd ∈ [facility-local-midnight, now-in-UTC].

    Used by no_activity_today (raw rows for the activeMinutes sum +
    sessionCount) and by below_typical (caller sums activeMinutes from
    the returned rows).
    """
    if now is None:
        now = facility_local_now(tz_name)
    start_utc = _to_utc_iso(facility_local_midnight(tz_name, now))
    end_utc = _to_utc_iso(now)
    res = activity_table.query(
        KeyConditionExpression=Key("patientId").eq(patient_id) & Key("timestamp").between(start_utc, end_utc),
        ScanIndexForward=True,
        Limit=1000,
    )
    return res.get("Items", [])


def query_activity_history(
    activity_table: Any,
    *,
    patient_id: str,
    tz_name: str,
    days: int = 30,
    now: datetime | None = None,
) -> list[dict[str, Any]]:
    """
    Activity Series rows for the last `days` days BEFORE today's local
    midnight. Excludes today (today is queried separately by
    query_activity_for_today). Returns raw rows; caller aggregates.
    """
    if now is None:
        now = facility_local_now(tz_name)
    local_midnight = facility_local_midnight(tz_name, now)
    window_start = local_midnight - timedelta(days=days)
    start_utc = _to_utc_iso(window_start)
    end_utc = _to_utc_iso(local_midnight)
    res = activity_table.query(
        KeyConditionExpression=Key("patientId").eq(patient_id) & Key("timestamp").between(start_utc, end_utc),
        ScanIndexForward=True,
        Limit=1000,
    )
    return res.get("Items", [])


def aggregate_active_min_per_day(
    history_rows: list[dict[str, Any]],
    *,
    days: int = 30,
    tz_name: str = "UTC",
    now: datetime | None = None,
) -> list[int]:
    """
    Group history rows by facility-local-date (the `date` attribute set by
    activity-processor) into a list of daily active-minute totals. Returns
    a contiguous list of length `days`, oldest first, with zeros for days
    that have no activity rows. Today is excluded (rows for today
    shouldn't appear in `history_rows` since the query window excludes
    today, but defensive filtering applies).

    Re-keyed onto activeMinutes (DT-4 WS2): activeMinutes is the universal
    cross-type metric, so these daily totals work for both walker (steps)
    and rollator (no steps) devices.

    Why contiguous-with-zeros: the rule fns expect a fixed-length sequence
    so the cold-start guard (len >= min_history_days) is meaningful even
    for sparsely-active patients.
    """
    if now is None:
        now = facility_local_now(tz_name)
    today_local = facility_local_midnight(tz_name, now).date()
    # Build a date → total map.
    by_date: dict[str, int] = {}
    for row in history_rows:
        date_str = row.get("date")
        if not isinstance(date_str, str):
            continue
        try:
            active_minutes = int(row.get("activeMinutes", 0))
        except (TypeError, ValueError):
            continue
        by_date[date_str] = by_date.get(date_str, 0) + active_minutes
    # Walk back `days` days from yesterday, oldest first.
    result: list[int] = []
    for offset in range(days, 0, -1):
        d = today_local - timedelta(days=offset)
        result.append(by_date.get(d.isoformat(), 0))
    return result


def sum_active_minutes(rows: list[dict[str, Any]]) -> int:
    """Convenience: sum the activeMinutes column across a row list."""
    return sum(int(r.get("activeMinutes", 0) or 0) for r in rows)


# Env-driven overrides surfaced for the handler.
def _env_int(name: str, default: int) -> int:
    raw = os.environ.get(name)
    if not raw:
        return default
    try:
        return int(raw)
    except (TypeError, ValueError):
        return default


HISTORY_DAYS = _env_int("HISTORY_DAYS", 30)

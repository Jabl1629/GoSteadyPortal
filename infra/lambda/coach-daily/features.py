"""
Deterministic activity features for coach-daily — AI Coach C2 §5.2.

Pure aggregation (compute_features) + the Activity Series query helpers the
handler uses. Keyed on activeMinutes — the universal cross-device metric
(rollators emit no steps). Copied from coach-api/digest.py + behavioral-
detector/history_window.py so coach-daily stays hermetic across Lambda
bundles (OQ-6: promote to _shared if the duplication grows).
"""
from __future__ import annotations

import statistics
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Any
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from boto3.dynamodb.conditions import Key


# ── time helpers ───────────────────────────────────────────────────────

def local_now(tz_name: str) -> datetime:
    try:
        return datetime.now(ZoneInfo(tz_name))
    except (ZoneInfoNotFoundError, ValueError):
        return datetime.now(timezone.utc)


def _to_utc_iso(dt: datetime) -> str:
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _local_midnight(now: datetime) -> datetime:
    return now.replace(hour=0, minute=0, second=0, microsecond=0)


def local_now_iso(now: datetime) -> str:
    """Facility-local ISO with tz offset (matches behavioral-detector)."""
    s = now.strftime("%Y-%m-%dT%H:%M:%S%z")
    return s[:-2] + ":" + s[-2:] if len(s) >= 2 and (s[-5] in "+-") else s


# ── activity reads ─────────────────────────────────────────────────────

def query_today(activity_table: Any, *, patient_id: str, tz_name: str, now: datetime) -> list[dict[str, Any]]:
    start = _to_utc_iso(_local_midnight(now))
    end = _to_utc_iso(now)
    res = activity_table.query(
        KeyConditionExpression=Key("patientId").eq(patient_id) & Key("timestamp").between(start, end),
        ScanIndexForward=True, Limit=1000,
    )
    return res.get("Items", [])


def query_history(activity_table: Any, *, patient_id: str, tz_name: str, now: datetime, days: int = 30) -> list[dict[str, Any]]:
    midnight = _local_midnight(now)
    start = _to_utc_iso(midnight - timedelta(days=days))
    end = _to_utc_iso(midnight)
    res = activity_table.query(
        KeyConditionExpression=Key("patientId").eq(patient_id) & Key("timestamp").between(start, end),
        ScanIndexForward=True, Limit=1000,
    )
    return res.get("Items", [])


# ── aggregation (pure) ─────────────────────────────────────────────────

def _sum_active(rows: list[dict[str, Any]]) -> int:
    total = 0
    for r in rows:
        try:
            total += int(r.get("activeMinutes", 0) or 0)
        except (TypeError, ValueError):
            continue
    return total


def _per_day(history_rows: list[dict[str, Any]], *, days: int, today_date) -> list[int]:
    by_date: dict[str, int] = {}
    for row in history_rows:
        d = row.get("date")
        if not isinstance(d, str):
            continue
        try:
            v = int(row.get("activeMinutes", 0) or 0)
        except (TypeError, ValueError):
            continue
        by_date[d] = by_date.get(d, 0) + v
    return [by_date.get((today_date - timedelta(days=off)).isoformat(), 0) for off in range(days, 0, -1)]


@dataclass(frozen=True)
class Features:
    today: int
    yesterday: int
    per_day: tuple[int, ...]     # last `days`, oldest → yesterday (zero-filled)
    last7: int
    last30: int
    best: int
    streak: int                  # consecutive active days through today
    active_days: int             # count of active days in the window
    median7: int
    median_prior23: int
    device_type: str             # walker_cap | rollator_platform | ''
    local_now_iso: str


def compute_features(
    today_rows: list[dict[str, Any]],
    history_rows: list[dict[str, Any]],
    *,
    now: datetime,
    days: int = 30,
) -> Features:
    today_date = _local_midnight(now).date()
    per_day = _per_day(history_rows, days=days, today_date=today_date)
    today = _sum_active(today_rows)
    yesterday = per_day[-1] if per_day else 0
    last7 = sum(per_day[-7:])
    last30 = sum(per_day)
    best = max(per_day) if per_day else 0
    active_days = sum(1 for d in per_day if d > 0)
    streak = 0
    for d in reversed(per_day):
        if d > 0:
            streak += 1
        else:
            break
    if today > 0:
        streak += 1
    last7_days = [d for d in per_day[-7:]]
    prior23 = [d for d in per_day[:-7]]
    median7 = int(statistics.median(last7_days)) if last7_days else 0
    median_prior23 = int(statistics.median(prior23)) if prior23 else 0
    dtype = ""
    for r in (today_rows + history_rows):
        dt = r.get("deviceType")
        if dt:
            dtype = str(dt)
            break
    return Features(
        today=today, yesterday=yesterday, per_day=tuple(per_day),
        last7=last7, last30=last30, best=best, streak=streak,
        active_days=active_days, median7=median7, median_prior23=median_prior23,
        device_type=dtype, local_now_iso=local_now_iso(now),
    )

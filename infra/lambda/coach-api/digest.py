"""
Deterministic activity digest — AI Coach C1 §5.4 / D3 / D4.

Code (not the model) computes every number the coach may cite. build_digest
returns a short human-readable summary AND the allow-list of numeral strings
the output lint permits in a generated reply (C1-D4 anti-hallucination).

Keyed on activeMinutes — the universal cross-device metric; rollators emit no
steps. Query helpers are copied (not imported) from behavioral-detector/
history_window.py so coach-api stays hermetic across Lambda bundles; if the
duplication grows, promote to _shared/activity_digest.py (OQ-6).
"""
from __future__ import annotations

import re
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Any
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from boto3.dynamodb.conditions import Key

# Cold-start guard: fewer active days than this ⇒ speak generally, no trends.
MIN_ACTIVE_DAYS = 3


@dataclass(frozen=True)
class Digest:
    text: str
    allowlist: frozenset[str]
    has_history: bool


# ── time helpers (mirror history_window.py) ───────────────────────────

def _local_now(tz_name: str) -> datetime:
    try:
        return datetime.now(ZoneInfo(tz_name))
    except (ZoneInfoNotFoundError, ValueError):
        return datetime.now(timezone.utc)


def _to_utc_iso(dt: datetime) -> str:
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _local_midnight(now: datetime) -> datetime:
    return now.replace(hour=0, minute=0, second=0, microsecond=0)


# ── activity reads ─────────────────────────────────────────────────────

def query_today(
    activity_table: Any, *, patient_id: str, tz_name: str, now: datetime | None = None
) -> list[dict[str, Any]]:
    now = now or _local_now(tz_name)
    start = _to_utc_iso(_local_midnight(now))
    end = _to_utc_iso(now)
    res = activity_table.query(
        KeyConditionExpression=Key("patientId").eq(patient_id)
        & Key("timestamp").between(start, end),
        ScanIndexForward=True,
        Limit=1000,
    )
    return res.get("Items", [])


def query_history(
    activity_table: Any,
    *,
    patient_id: str,
    tz_name: str,
    days: int = 30,
    now: datetime | None = None,
) -> list[dict[str, Any]]:
    now = now or _local_now(tz_name)
    midnight = _local_midnight(now)
    start = _to_utc_iso(midnight - timedelta(days=days))
    end = _to_utc_iso(midnight)
    res = activity_table.query(
        KeyConditionExpression=Key("patientId").eq(patient_id)
        & Key("timestamp").between(start, end),
        ScanIndexForward=True,
        Limit=1000,
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


def _per_day(
    history_rows: list[dict[str, Any]], *, days: int, tz_name: str, now: datetime
) -> list[int]:
    """Daily activeMinutes totals, oldest→yesterday, zero-filled to `days`."""
    today = _local_midnight(now).date()
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
    return [
        by_date.get((today - timedelta(days=off)).isoformat(), 0)
        for off in range(days, 0, -1)
    ]


def build_digest(
    today_rows: list[dict[str, Any]],
    history_rows: list[dict[str, Any]],
    *,
    tz_name: str,
    now: datetime | None = None,
    days: int = 30,
) -> Digest:
    now = now or _local_now(tz_name)
    per_day = _per_day(history_rows, days=days, tz_name=tz_name, now=now)
    today = _sum_active(today_rows)
    yesterday = per_day[-1] if per_day else 0
    last7 = sum(per_day[-7:])
    last30 = sum(per_day)
    best = max(per_day) if per_day else 0
    active_days_7 = sum(1 for d in per_day[-7:] if d > 0)
    streak = 0
    for d in reversed(per_day):
        if d > 0:
            streak += 1
        else:
            break
    if today > 0:
        streak += 1
    active_count = sum(1 for d in per_day if d > 0)
    has_history = active_count >= MIN_ACTIVE_DAYS

    parts = [
        f"Today so far: {today} active minutes.",
        f"Yesterday: {yesterday} active minutes.",
        f"Last 7 days: {last7} active minutes total across {active_days_7} active days.",
        f"Last 30 days: {last30} active minutes total.",
    ]
    if best > 0:
        parts.append(f"Best single day in the last month: {best} active minutes.")
    if streak > 0:
        parts.append(f"Current run of active days: {streak}.")
    if not has_history:
        parts.append(
            "This person is just getting started — little history yet, so speak "
            "generally and do not cite trends."
        )
    text = " ".join(parts)

    allow = {str(n) for n in (today, yesterday, last7, last30, best, active_days_7, streak)}
    allow |= set(re.findall(r"\d+", text))  # literals like "7", "30"
    return Digest(text=text, allowlist=frozenset(allow), has_history=has_history)

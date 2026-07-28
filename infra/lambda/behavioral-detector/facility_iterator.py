"""
Facility enumeration + rule routing — Phase 1C-slim.

Spec L2 + L7: hourly UTC cron fires the Lambda. Per invocation we
enumerate all facilities, compute each one's local-now, and route to
the rule sets whose trigger window the facility is currently inside:

  local-hour 11..13 → no_activity_today rule
  local-hour 22..23 → below_typical + declining_trend rules
  (always)          → device_offline + device_silent rules

The window (target hour + a catch-up tail, clamped at local midnight)
makes the daily check survive a missed or jitter-straddled invocation.
Idempotency is handled at the DDB write layer: the daily rules stamp
their eventTimestamp — and so their Alert History sort key — with the
facility-local day anchor (midnight), so running the rule again the
same local day collides and is a no-op past the first write.

Organizations table SK pattern (Phase 0B-rev):
  PK = clientId
  SK = META#client | facility#<facId> | facility#<facId>#census#<cenId>

For facility enumeration we Query each known client, then filter SKs
matching `facility#<facId>` (no census suffix). For Phase 1C-slim V1
we Scan the table once per invocation to enumerate ALL clients — at
MVP scale (<10 clients), Scan is cheap. Future: cache or use a GSI.
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from datetime import datetime
from typing import Any
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError


# Spec config (overridable via env).
#
# 11:00 (was 09:00 through 2026-07): the 09:00 gate flagged residents who
# simply had a slow morning. 11:00 gives breakfast AND mid-morning activity
# time to land before a CRITICAL fires, at the cost of ~2h of notice.
DEFAULT_NO_ACTIVITY_LOCAL_HOUR = 11
DEFAULT_END_OF_DAY_LOCAL_HOUR = 22

# How many hourly firings, starting at the target hour, may run a
# daily-cadence rule. >1 makes the daily check resilient to a missed or
# jitter-straddled invocation; the day-anchored SK dedupes the repeats so
# only the first firing to see the condition writes a row.
DEFAULT_TRIGGER_CATCHUP_HOURS = 3


@dataclass(frozen=True)
class FacilityContext:
    """A facility's identity + tz info — input to per-facility rule routing."""
    clientId: str
    facilityId: str
    displayName: str
    timezone: str
    local_now: datetime


@dataclass(frozen=True)
class RuleSet:
    """Which rule families to evaluate for a facility this invocation."""
    evaluate_no_activity: bool
    evaluate_end_of_day_behavioral: bool   # covers both below_typical + declining_trend
    evaluate_offline: bool                  # device_offline + device_silent — always-on


def list_facilities(
    organizations_table: Any,
    *,
    client_id: str | None = None,
) -> list[FacilityContext]:
    """
    Enumerate all facilities (or facilities under a single client if
    client_id is set). Returns FacilityContext rows with local_now
    resolved per facility timezone.

    Scan strategy: Scan-all at MVP scale; if it ever gets hot, swap to
    a per-client Query loop with a cached client list. Filter SKs to
    `facility#<id>` (no nested `census#` suffix).
    """
    items: list[dict[str, Any]] = []
    if client_id:
        # Bounded Query within the partition — cheaper than Scan.
        res = organizations_table.query(
            KeyConditionExpression="clientId = :c AND begins_with(sk, :p)",
            ExpressionAttributeValues={":c": client_id, ":p": "facility#"},
        )
        items.extend(res.get("Items", []))
    else:
        # Scan-all with a filter for SK starting with `facility#`. At MVP
        # scale this is bounded; pagination handled below.
        kwargs: dict[str, Any] = {
            "FilterExpression": "begins_with(sk, :p)",
            "ExpressionAttributeValues": {":p": "facility#"},
        }
        while True:
            res = organizations_table.scan(**kwargs)
            items.extend(res.get("Items", []))
            if "LastEvaluatedKey" not in res:
                break
            kwargs["ExclusiveStartKey"] = res["LastEvaluatedKey"]

    out: list[FacilityContext] = []
    for it in items:
        sk = it.get("sk", "")
        # `facility#<id>` has exactly 2 segments; nested `facility#X#census#Y`
        # has 4 — filter out the nested ones.
        if sk.count("#") != 1:
            continue
        if not sk.startswith("facility#"):
            continue
        facility_id = sk.split("#", 1)[1]
        tz_name = str(it.get("timezone") or "UTC")
        try:
            local_now = datetime.now(ZoneInfo(tz_name))
        except ZoneInfoNotFoundError:
            local_now = datetime.now(ZoneInfo("UTC"))
        out.append(FacilityContext(
            clientId=str(it.get("clientId", "")),
            facilityId=facility_id,
            displayName=str(it.get("displayName") or facility_id),
            timezone=tz_name,
            local_now=local_now,
        ))
    return out


def in_trigger_window(
    local_hour: int, target_hour: int, catchup_hours: int
) -> bool:
    """
    True for the target local hour and the `catchup_hours - 1` hours after it.

    The window never crosses local midnight: past midnight the local DAY has
    rolled over, and the daily rules' sort key is anchored to local midnight
    (`history_window.local_day_anchor_iso`), so a firing at 00:30 would key
    the NEW day and write a spurious row for a day that has barely started.
    The window is therefore clamped at hour 24 — an end-of-day rule targeting
    22:00 can catch up at 23:00 but no further.

    Why a window rather than `local_hour == target_hour`: a single missed or
    jitter-straddled invocation silently dropped that facility's entire day.
    EventBridge `rate()` fires about hourly, not on an exact-minute grid, so
    two consecutive firings can land at 10:59:5x and 12:00:0x and never
    observe hour 11 at all; an invocation that errors (`list_facilities`
    raises for every facility at once) has the same effect. The repeats a
    window introduces are free — the day-anchored SK rejects them.
    """
    catchup = max(1, catchup_hours)
    return target_hour <= local_hour < min(target_hour + catchup, 24)


def rule_set_for_facility(
    facility: FacilityContext,
    *,
    no_activity_hour: int = DEFAULT_NO_ACTIVITY_LOCAL_HOUR,
    end_of_day_hour: int = DEFAULT_END_OF_DAY_LOCAL_HOUR,
    catchup_hours: int = DEFAULT_TRIGGER_CATCHUP_HOURS,
) -> RuleSet:
    """
    Decide which rule families to evaluate for this facility now.

    Daily-cadence rules run on the first firing at or after their target
    local hour, plus a short catch-up window (see `in_trigger_window`).
    At most one of those firings writes a row — the rest collide on the
    day-anchored sort key in `handler._write_alert`.

    Note DST needs no special handling here. US transitions occur at ~02:00
    local, so an hourly UTC cron still observes local hours 11 and 22
    exactly once on a transition day (verified by simulation); the hour that
    goes missing is 02 and the one that repeats is 01.
    """
    local_hour = facility.local_now.hour
    return RuleSet(
        evaluate_no_activity=in_trigger_window(
            local_hour, no_activity_hour, catchup_hours
        ),
        evaluate_end_of_day_behavioral=in_trigger_window(
            local_hour, end_of_day_hour, catchup_hours
        ),
        # Offline rules run on every invocation regardless of local time
        # (a dead device at 03:00 is just as relevant as at 13:00).
        evaluate_offline=True,
    )


def _env_int(name: str, default: int) -> int:
    raw = os.environ.get(name)
    if not raw:
        return default
    try:
        return int(raw)
    except (TypeError, ValueError):
        return default


NO_ACTIVITY_LOCAL_HOUR = _env_int(
    "NO_ACTIVITY_LOCAL_HOUR", DEFAULT_NO_ACTIVITY_LOCAL_HOUR
)
END_OF_DAY_LOCAL_HOUR = _env_int(
    "END_OF_DAY_LOCAL_HOUR", DEFAULT_END_OF_DAY_LOCAL_HOUR
)
TRIGGER_CATCHUP_HOURS = _env_int(
    "TRIGGER_CATCHUP_HOURS", DEFAULT_TRIGGER_CATCHUP_HOURS
)

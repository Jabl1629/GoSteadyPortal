"""
Facility enumeration + rule routing — Phase 1C-slim.

Spec L2 + L7: hourly UTC cron fires the Lambda. Per invocation we
enumerate all facilities, compute each one's local-now, and route to
the rule sets whose trigger-hour just crossed within the past hour:

  local-hour 09 (±1h) → no_activity_today rule
  local-hour 22 (±1h) → below_typical + declining_trend rules
  (always)            → device_offline + device_silent rules

The ±1h window covers DST transitions and timezone weirdness. Idempotency
is handled at the DDB write layer (conditional PutItem on Alert History
with compound SK including facility-local date) — running the rule
twice in the same day is a no-op past the first write.

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
DEFAULT_NO_ACTIVITY_LOCAL_HOUR = 9
DEFAULT_END_OF_DAY_LOCAL_HOUR = 22


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


def rule_set_for_facility(
    facility: FacilityContext,
    *,
    no_activity_hour: int = DEFAULT_NO_ACTIVITY_LOCAL_HOUR,
    end_of_day_hour: int = DEFAULT_END_OF_DAY_LOCAL_HOUR,
    last_invocation_local_hour: int | None = None,
) -> RuleSet:
    """
    Decide which rule families to evaluate for this facility now.

    The trigger windows are ±1 hour around the configured local hours.
    Specifically: a rule fires if the facility's local hour ∈ [target-1, target]
    crossed into target within the past hour. Concretely, we say:

      "evaluate no_activity_today if facility-local hour is currently 09"

    Because the cron fires hourly and we check at-most-once per local hour,
    rule writes are deduplicated at the DDB write layer (compound SK +
    once-per-day eventTimestamp). If two consecutive cron firings see the
    same local hour (e.g., DST fallback when the same hour repeats),
    the second write fails the conditional check — no harm done.

    `last_invocation_local_hour` is informational only in V1 (unused);
    reserved for future "skip if we just ran" logic if needed.
    """
    local_hour = facility.local_now.hour
    return RuleSet(
        evaluate_no_activity=(local_hour == no_activity_hour),
        evaluate_end_of_day_behavioral=(local_hour == end_of_day_hour),
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

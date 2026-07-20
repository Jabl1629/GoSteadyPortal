"""
Facility + active-patient enumeration for coach-daily — copied from
behavioral-detector (separate Lambda bundle can't import it). The coach is a
D2C feature (Q12: facility tier parked), so we enumerate only D2C households
(clientId begins 'dtc_').
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from typing import Any
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from boto3.dynamodb.conditions import Key


@dataclass(frozen=True)
class FacilityContext:
    clientId: str
    facilityId: str
    timezone: str
    local_now: datetime


def list_facilities(organizations_table: Any) -> list[FacilityContext]:
    """Scan Organizations for `facility#<id>` rows; keep only D2C households."""
    items: list[dict[str, Any]] = []
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
        sk = str(it.get("sk", ""))
        if sk.count("#") != 1 or not sk.startswith("facility#"):
            continue
        client_id = str(it.get("clientId", ""))
        if not client_id.startswith("dtc_"):
            continue  # coach is D2C-only
        tz_name = str(it.get("timezone") or "UTC")
        try:
            now = datetime.now(ZoneInfo(tz_name))
        except (ZoneInfoNotFoundError, ValueError):
            now = datetime.now(ZoneInfo("UTC"))
        out.append(FacilityContext(
            clientId=client_id, facilityId=sk.split("#", 1)[1],
            timezone=tz_name, local_now=now,
        ))
    return out


def list_active_patients(patients_table: Any, *, facility: FacilityContext) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    kwargs: dict[str, Any] = {
        "IndexName": "by-client-status",
        "KeyConditionExpression":
            Key("clientId").eq(facility.clientId)
            & Key("status_patientId").begins_with("active_"),
    }
    while True:
        res = patients_table.query(**kwargs)
        for row in res.get("Items", []):
            if row.get("facilityId") == facility.facilityId:
                out.append(row)
        if "LastEvaluatedKey" not in res:
            break
        kwargs["ExclusiveStartKey"] = res["LastEvaluatedKey"]
    return out

"""
Active-patient enumeration per facility — Phase 1C-slim.

For each FacilityContext, fetch the patients whose:
  - status == 'active'
  - facilityId == facility.facilityId

Patients table (Phase 0B-rev) has GSI `by-client-status` (PK=clientId,
SK=status). We Query that GSI then post-filter by facilityId.

At MVP scale (<200 patients per facility), Query + post-filter is fast
enough. If facility_admin-scoped users with very large facility counts
ever appear, swap to per-facility GSI (Phase 2A-RD-followup territory).

`active` filter is also a defensive guard against discharged patients
still carrying activity rows — those should never be evaluated.
"""

from __future__ import annotations

from typing import Any

from boto3.dynamodb.conditions import Key

from facility_iterator import FacilityContext


def list_active_patients(
    patients_table: Any,
    *,
    facility: FacilityContext,
) -> list[dict[str, Any]]:
    """
    Return active Patient rows for `facility.facilityId`. Uses the
    Patients `by-client-status` GSI then post-filters by facilityId.

    GSI key schema (Phase 0B-rev):
      PK = clientId
      SK = status_patientId   (compound; e.g. "active_pat_abc123")

    Underscore-separator (not hash/pound) — keeps it filename-safe and
    matches patient-api's queries.py convention. Query with
    `begins_with(status_patientId, "active_")` to get all active patients.

    Each returned row is the full Patient DDB item (so callers can pull
    timezone, notificationsPaused, etc. without a second GetItem).
    """
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

"""
DDB query helpers — Phase 2A-RD.

Pure thin wrappers around boto3 DDB Table.query / get_item / batch_get_item.
Take the table resource as the first arg so they stay unit-testable with a
moto / mock table. No module-level boto3 state.

Tables touched (via the table object passed in):
  - Patients          (PK=patientId; GSIs by-client-status, by-census-status)
  - Activity Series   (PK=patientId, SK=timestamp [session_end UTC])
  - Alert History     (PK=patientId, SK=timestamp [compound {eventTs}#{type}])
  - Organizations     (PK=clientId, SK=sk [META#client | facility#... | facility#...#census#...])
  - DeviceAssignments (PK=serialNumber, SK=assignedAt; GSI by-patient)
  - Device Registry   (PK=serialNumber)
"""

from __future__ import annotations

from typing import Any
from boto3.dynamodb.conditions import Attr, Key


# The ONLY alert types a D2C walker/device user sees about themselves: BATTERY —
# the one thing they can act on (replace the AAs). Everything else (activity-
# judgment, signal, connectivity/offline, safety) is the caregiver's operational
# concern and is hidden from the walker's own view (2026-07-20 refinement —
# "only low battery for the walker"). An ALLOW-list, not a deny-list, so a NEW
# alert type is hidden from the walker by DEFAULT rather than leaking through.
WALKER_VISIBLE_ALERT_TYPES = frozenset(
    {"battery_low", "battery_critical", "low_battery", "battery"}
)


def hide_walker_alerts(
    items: list[dict[str, Any]], claims: dict[str, Any]
) -> list[dict[str, Any]]:
    """Read-side walker-only alert suppression.

    When the caller IS the walker/device user (the D2C-only `isWalkerUser` claim,
    normalized to a bool by `_shared.api_authz.extract_claims`), keep ONLY
    `WALKER_VISIBLE_ALERT_TYPES` (battery) and drop every other type — activity-
    judgment, signal, offline, safety — from what they see about themselves.
    Everyone else — non-walker Care Circle caregivers, facility / internal
    readers (no claim) — is unaffected, so those rows still reach the people who
    act on them. Per-caller by design: never a detector-side skip (the rows must
    still be written so caregivers see them).

    `claims` is the normalized dict from `extract_claims`, NOT the raw JWT
    claims — so the key is `isWalkerUser` (bool), not `custom:isWalkerUser`.
    """
    if not claims.get("isWalkerUser"):
        return items
    return [r for r in items if r.get("alertType") in WALKER_VISIBLE_ALERT_TYPES]


def get_patient(patients_table: Any, patient_id: str) -> dict[str, Any] | None:
    """Single Patients GetItem. Returns None if not found."""
    res = patients_table.get_item(Key={"patientId": patient_id})
    return res.get("Item")


def query_activity_window(
    activity_table: Any,
    *,
    patient_id: str,
    window_start: str,
    window_end: str,
    limit: int,
    exclusive_start_key: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """
    Base-table Query on Activity Series for a time window, DESC.

    PK=patientId, SK=timestamp (= session_end UTC ISO 8601).
    Returns {"items": [...], "last_evaluated_key": dict | None}.
    """
    kwargs: dict[str, Any] = {
        "KeyConditionExpression": Key("patientId").eq(patient_id)
        & Key("timestamp").between(window_start, window_end),
        "Limit": limit,
        "ScanIndexForward": False,  # newest-first
    }
    if exclusive_start_key:
        kwargs["ExclusiveStartKey"] = exclusive_start_key
    res = activity_table.query(**kwargs)
    return {
        "items": res.get("Items", []),
        "last_evaluated_key": res.get("LastEvaluatedKey"),
    }


def query_alerts(
    alerts_table: Any,
    *,
    patient_id: str,
    status_filter: str,  # "unacknowledged" | "acknowledged" | "all"
    limit: int,
    exclusive_start_key: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """
    Base-table Query on Alert History, DESC. Filter on acknowledged flag.

    PK=patientId, SK=timestamp (compound `{eventTimestamp}#{alertType}`).
    """
    kwargs: dict[str, Any] = {
        "KeyConditionExpression": Key("patientId").eq(patient_id),
        "Limit": limit,
        "ScanIndexForward": False,
    }
    if status_filter == "unacknowledged":
        # Treat missing `acknowledged` as false (legacy rows + new rows).
        kwargs["FilterExpression"] = Attr("acknowledged").not_exists() | Attr("acknowledged").eq(False)
    elif status_filter == "acknowledged":
        kwargs["FilterExpression"] = Attr("acknowledged").eq(True)
    # "all": no filter
    if exclusive_start_key:
        kwargs["ExclusiveStartKey"] = exclusive_start_key
    res = alerts_table.query(**kwargs)
    return {
        "items": res.get("Items", []),
        "last_evaluated_key": res.get("LastEvaluatedKey"),
        "scanned_count": res.get("ScannedCount", 0),
    }


def query_patients_by_client(
    patients_table: Any,
    *,
    client_id: str,
    limit: int,
    exclusive_start_key: dict[str, Any] | None = None,
    facility_filter: list[str] | None = None,
    status_prefix: str = "active_",
) -> dict[str, Any]:
    """
    GSI `by-client-status` query — list patients per client by status.

    PK=clientId, SK=`status_patientId` (underscore-separated per 0B-rev).
    [status_prefix] selects the status slice via SK begins_with — `active_`
    (default) for the live roster, `discharged_` for the discontinued view.
    Optional facility post-filter for facility_admin with explicit facilities.
    """
    kwargs: dict[str, Any] = {
        "IndexName": "by-client-status",
        "KeyConditionExpression": Key("clientId").eq(client_id)
        & Key("status_patientId").begins_with(status_prefix),
        "Limit": limit,
    }
    if facility_filter:
        kwargs["FilterExpression"] = Attr("facilityId").is_in(facility_filter)
    if exclusive_start_key:
        kwargs["ExclusiveStartKey"] = exclusive_start_key
    res = patients_table.query(**kwargs)
    return {
        "items": res.get("Items", []),
        "last_evaluated_key": res.get("LastEvaluatedKey"),
    }


def query_patients_by_census(
    patients_table: Any,
    *,
    census_id: str,
    limit: int,
    exclusive_start_key: dict[str, Any] | None = None,
    status_prefix: str = "active_",
) -> dict[str, Any]:
    """
    GSI `by-census-status` query — census roster by status.

    PK=censusId, SK=`status_patientId`. [status_prefix] selects the status
    slice (`active_` default, `discharged_` for the discontinued view).
    """
    kwargs: dict[str, Any] = {
        "IndexName": "by-census-status",
        "KeyConditionExpression": Key("censusId").eq(census_id)
        & Key("status_patientId").begins_with(status_prefix),
        "Limit": limit,
    }
    if exclusive_start_key:
        kwargs["ExclusiveStartKey"] = exclusive_start_key
    res = patients_table.query(**kwargs)
    return {
        "items": res.get("Items", []),
        "last_evaluated_key": res.get("LastEvaluatedKey"),
    }


def batch_get_patients(patients_table: Any, patient_ids: list[str]) -> list[dict[str, Any]]:
    """
    BatchGetItem on Patients keyed by patientIds. Used by family_viewer.

    DDB BatchGetItem has a 100-key limit per request; we chunk if needed.
    Caller is expected to keep family_viewer linked-patients lists modest
    (Phase 2A-RD A4: tolerate up to ~25; chunking covers larger).
    """
    if not patient_ids:
        return []
    ddb = patients_table.meta.client
    table_name = patients_table.name
    out: list[dict[str, Any]] = []
    for chunk in _chunks(list(patient_ids), 100):
        request = {
            table_name: {
                "Keys": [{"patientId": pid} for pid in chunk],
                "ConsistentRead": False,
            }
        }
        res = ddb.batch_get_item(RequestItems=request)
        out.extend(res.get("Responses", {}).get(table_name, []))
        # Best-effort: ignore UnprocessedKeys for now; could retry-loop if
        # we ever see them in practice. At family_viewer-list sizes (<100)
        # we shouldn't hit them.
    return out


def batch_get_orgs(
    organizations_table: Any,
    *,
    client_id: str,
    facility_ids: set[str],
    census_ids: set[str],
) -> dict[str, dict[str, Any]]:
    """
    Resolve facility + census display names via Organizations BatchGetItem.

    Organizations PK=clientId, SK=`facility#<id>` | `facility#<id>#census#<id>`.
    Returns a flat dict keyed by id (facility ID or census ID) → row dict.

    Census rows in Organizations are keyed by SK=`facility#{fid}#census#{cid}`
    — we don't know the parent facility just from the censusId alone, so we
    can't BatchGet census rows directly without the parent facility. This
    helper takes the union of {facility_id → name} resolution; census-name
    resolution is best-effort via a secondary lookup if needed.

    For Phase 2A-RD's /me/patients enrichment, the caller already has each
    patient's `facilityId` and `censusId` on hand (from the Patients row).
    So we resolve facility names via BatchGet keyed by (clientId,
    facility#{fid}), and resolve census names via the same per-patient
    facility (one Query per facility cluster if needed). For MVP this is
    sufficient; if it gets noisy we add a census-id-to-facility-id reverse
    index.

    Capped at 100 unique facility IDs per response per spec L9.
    """
    if not facility_ids and not census_ids:
        return {}
    ddb = organizations_table.meta.client
    table_name = organizations_table.name
    out: dict[str, dict[str, Any]] = {}

    # Facility keys: (clientId, facility#<fid>)
    facility_keys = [
        {"clientId": client_id, "sk": f"facility#{fid}"}
        for fid in list(facility_ids)[:100]
    ]
    if facility_keys:
        for chunk in _chunks(facility_keys, 100):
            res = ddb.batch_get_item(RequestItems={table_name: {"Keys": chunk}})
            for item in res.get("Responses", {}).get(table_name, []):
                sk = item.get("sk", "")
                if sk.startswith("facility#") and "#census#" not in sk:
                    fid = sk[len("facility#"):]
                    out[fid] = item

    # Census name resolution is trickier (composite SK). For each census
    # we want the row keyed by SK=`facility#{fid}#census#{cid}`. We need
    # to know each census's parent facility — but the caller provides
    # patients (each with facilityId + censusId), so we can build the
    # exact key list. The caller will pre-compute this; we accept census
    # keys as plain census IDs and expect the caller to pass the
    # (facility_id, census_id) tuples separately if name resolution is
    # needed. For MVP simplicity, this helper only resolves facility
    # names; census names can be looked up by the caller via a dedicated
    # call if the dashboard needs them.

    return out


def batch_get_census_rows(
    organizations_table: Any,
    *,
    client_id: str,
    facility_census_pairs: list[tuple[str, str]],
) -> dict[tuple[str, str], dict[str, Any]]:
    """
    Resolve census display names. Caller provides (facility_id, census_id)
    tuples (each census has a parent facility in the composite SK).
    Returns dict keyed by (facility_id, census_id) tuple.
    Capped at 100 pairs per call.
    """
    if not facility_census_pairs:
        return {}
    ddb = organizations_table.meta.client
    table_name = organizations_table.name
    out: dict[tuple[str, str], dict[str, Any]] = {}
    keys = [
        {"clientId": client_id, "sk": f"facility#{fid}#census#{cid}"}
        for (fid, cid) in facility_census_pairs[:100]
    ]
    for chunk in _chunks(keys, 100):
        res = ddb.batch_get_item(RequestItems={table_name: {"Keys": chunk}})
        for item in res.get("Responses", {}).get(table_name, []):
            sk = item.get("sk", "")
            # Parse `facility#{fid}#census#{cid}`
            parts = sk.split("#")
            if len(parts) == 4 and parts[0] == "facility" and parts[2] == "census":
                out[(parts[1], parts[3])] = item
    return out


def get_active_assignment(deviceassignments_table: Any, patient_id: str) -> dict[str, Any] | None:
    """
    GSI by-patient query for the current active assignment row (validUntil null).

    Returns the most recent row that has no validUntil, or None.
    """
    res = deviceassignments_table.query(
        IndexName="by-patient",
        KeyConditionExpression=Key("patientId").eq(patient_id),
        FilterExpression=Attr("validUntil").not_exists(),
        ScanIndexForward=False,
        Limit=5,  # tiny, robust against stale dups
    )
    items = res.get("Items", [])
    return items[0] if items else None


def get_device(device_table: Any, serial: str) -> dict[str, Any] | None:
    """Device Registry GetItem; returns None if not found."""
    res = device_table.get_item(Key={"serialNumber": serial})
    return res.get("Item")


def _chunks(lst: list[Any], n: int) -> Any:
    """Yield successive n-sized chunks from lst."""
    for i in range(0, len(lst), n):
        yield lst[i : i + n]

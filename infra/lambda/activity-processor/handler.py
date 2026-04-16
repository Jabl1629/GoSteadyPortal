"""
Activity Processor Lambda — Phase 1B

Triggered by: IoT Rule on gs/+/activity
IoT Rule SQL:  SELECT *, topic(2) AS thingName FROM 'gs/+/activity'

Expected payload (session-based):
{
    "serial": "GS0000001234",
    "session_start": "2026-04-15T14:02:00Z",
    "session_end":   "2026-04-15T14:18:00Z",
    "steps": 142,
    "distance_ft": 340.5,
    "active_min": 16,
    "thingName": "GS0000001234"    <-- injected by IoT Rule SQL
}

Responsibilities (Phase 1B):
  1. Validate the payload (reject + log if malformed).
  2. Resolve the walker's timezone (device → walkerUserId → profile → tz).
  3. Compute the local-date GSI field ("YYYY-MM-DD" in walker tz, UTC fallback).
  4. Write one row to the activity table.
     - SK = session_end (UTC ISO 8601), which is strictly monotonic per device.
     - Conditional PutItem on attribute_not_exists(serialNumber) so a retried
       MQTT delivery cannot create a duplicate row for the same session.

Non-goals (deferred):
  - Midnight session splitting  → handled by future daily-rollup Lambda.
  - EventBridge fan-out         → Phase 2C.
  - FHIR Observation projection → Phase 4.
"""

import json
import os
from datetime import datetime, timezone
from decimal import Decimal
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

import boto3
from botocore.exceptions import ClientError

# ── Configuration ────────────────────────────────────────────────
DEVICE_TABLE = os.environ["DEVICE_TABLE"]
ACTIVITY_TABLE = os.environ["ACTIVITY_TABLE"]
USER_PROFILE_TABLE = os.environ["USER_PROFILE_TABLE"]

# Validation bounds. Chosen liberally — the goal is to reject obvious
# garbage (negative numbers, 24-hour-plus active_min) rather than
# second-guess the device firmware's sensor fusion.
MAX_STEPS = 100_000            # marathon-level ceiling
MAX_DISTANCE_FT = 50_000       # ~9.5 miles in one session
MAX_ACTIVE_MIN = 1_440         # 24 hours

# Fields the device firmware must send. `thingName` is injected by the IoT Rule.
REQUIRED_FIELDS = (
    "session_start",
    "session_end",
    "steps",
    "distance_ft",
    "active_min",
)

# ── AWS clients (module-scope for warm-invoke reuse) ─────────────
_ddb = boto3.resource("dynamodb")
_device_tbl = _ddb.Table(DEVICE_TABLE)
_activity_tbl = _ddb.Table(ACTIVITY_TABLE)
_profile_tbl = _ddb.Table(USER_PROFILE_TABLE)


# ── Helpers ──────────────────────────────────────────────────────
def _parse_iso(ts: str) -> datetime:
    """Parse an ISO 8601 timestamp, normalising 'Z' → +00:00."""
    return datetime.fromisoformat(ts.replace("Z", "+00:00"))


def _resolve_walker_tz(serial: str) -> tuple[str | None, str | None]:
    """
    Follow the device → walkerUserId → profile.timezone chain.

    Returns (walkerUserId, tz_name). Either may be None if the device
    isn't linked yet (Phase 2 will populate walkerUserId) or if the
    walker hasn't set a timezone on their profile.
    """
    try:
        dev = _device_tbl.get_item(Key={"serialNumber": serial}).get("Item") or {}
        walker_id = dev.get("walkerUserId")
        if not walker_id:
            return None, None
        prof = _profile_tbl.get_item(Key={"userId": walker_id}).get("Item") or {}
        return walker_id, prof.get("timezone")
    except ClientError as e:
        # DynamoDB transient failure — degrade gracefully to UTC.
        print(f"[ACTIVITY] tz lookup failed for {serial}: {e}")
        return None, None


def _local_date(session_start: datetime, tz_name: str | None) -> str:
    """
    Render session_start's date in the walker's timezone.
    Falls back to UTC if tz_name is missing or unknown.
    """
    if tz_name:
        try:
            return session_start.astimezone(ZoneInfo(tz_name)).strftime("%Y-%m-%d")
        except ZoneInfoNotFoundError:
            print(f"[ACTIVITY] unknown tz '{tz_name}', falling back to UTC")
    return session_start.astimezone(timezone.utc).strftime("%Y-%m-%d")


def _validate(event: dict) -> tuple[bool, str]:
    """Return (ok, reason). Reason is a short human-readable tag."""
    for f in REQUIRED_FIELDS:
        if f not in event:
            return False, f"missing:{f}"

    try:
        ss = _parse_iso(event["session_start"])
        se = _parse_iso(event["session_end"])
    except (TypeError, ValueError) as e:
        return False, f"bad_timestamp:{e}"
    if se < ss:
        return False, "session_end<session_start"

    try:
        steps = int(event["steps"])
        distance = float(event["distance_ft"])
        active = int(event["active_min"])
    except (TypeError, ValueError) as e:
        return False, f"bad_number:{e}"

    if not 0 <= steps <= MAX_STEPS:
        return False, f"steps_out_of_range:{steps}"
    if not 0 <= distance <= MAX_DISTANCE_FT:
        return False, f"distance_out_of_range:{distance}"
    if not 0 <= active <= MAX_ACTIVE_MIN:
        return False, f"active_out_of_range:{active}"

    return True, "ok"


# ── Handler ──────────────────────────────────────────────────────
def handler(event, context):
    serial = event.get("serial") or event.get("thingName") or "UNKNOWN"

    # 1. Validate — reject + log raw payload on failure so the
    #    device firmware team can diagnose field drift.
    ok, reason = _validate(event)
    if not ok:
        print(f"[ACTIVITY][REJECT] serial={serial} reason={reason} event={json.dumps(event)}")
        return {"statusCode": 400, "body": f"invalid payload: {reason}"}

    ss = _parse_iso(event["session_start"])
    se = _parse_iso(event["session_end"])

    # 2. Timezone lookup — best-effort; falls back to UTC.
    walker_id, tz_name = _resolve_walker_tz(serial)
    local_date = _local_date(ss, tz_name)

    # 3. Build item. Use Decimal for any non-integer since DynamoDB
    #    rejects float. Normalise timestamps back to ISO 'Z' form.
    session_end_iso = se.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    session_start_iso = ss.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    item: dict = {
        "serialNumber": serial,
        "timestamp": session_end_iso,           # PK/SK
        "sessionStart": session_start_iso,
        "sessionEnd": session_end_iso,
        "steps": int(event["steps"]),
        "distanceFt": Decimal(str(event["distance_ft"])),
        "activeMinutes": int(event["active_min"]),
        "date": local_date,                     # GSI by-date sort key
        "ingestedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "source": "device",
    }
    if walker_id:
        item["walkerUserId"] = walker_id
    if tz_name:
        item["timezone"] = tz_name

    # 4. Conditional write — MQTT retries must not create duplicates.
    try:
        _activity_tbl.put_item(
            Item=item,
            ConditionExpression="attribute_not_exists(serialNumber) AND attribute_not_exists(#ts)",
            ExpressionAttributeNames={"#ts": "timestamp"},
        )
        print(
            f"[ACTIVITY][OK] serial={serial} session_end={session_end_iso} "
            f"steps={item['steps']} active={item['activeMinutes']} date={local_date} tz={tz_name}"
        )
    except ClientError as e:
        if e.response["Error"]["Code"] == "ConditionalCheckFailedException":
            print(f"[ACTIVITY][DUP] serial={serial} session_end={session_end_iso} — already recorded")
            return {"statusCode": 200, "body": "duplicate session ignored"}
        print(f"[ACTIVITY][ERROR] serial={serial} {e}")
        raise

    return {
        "statusCode": 200,
        "body": f"Activity recorded for {serial}: {item['steps']} steps, {item['activeMinutes']} min",
    }

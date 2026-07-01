#!/usr/bin/env python3
"""
Phase DT-0 synthetic smoke test runner (phase-dt0-device-type-scaffold.md
§Testing T1–T13 subset).

What it exercises against LIVE dev:
  T13  Registry backfill (conditional, run twice — idempotency)
  T8   admin bulk-create with deviceType/hardwareVariant + INVALID_DEVICE_TYPE 400
       (synthetic Lambda invoke with internal_admin claims — §C19 Option-A pattern;
        no seeded internal user exists)
  T9   provision via REAL API (rd-caregiver token) → assignment row carries deviceType
  GET  /devices/{serial} returns deviceType/hardwareVariant
  T1   walker activity regression → row + deviceType=walker_cap
  T4   walker missing steps → activity_reject
  T2   rollator activity (active_min only + provisional field) → row, no steps, extras
  T3   rollator missing active_min → activity_reject
  T5   rollator device alert → bad_alert_type reject
  T6   heartbeat device_type mismatch → warn + metric path
  T7   heartbeat device_type match → NO mismatch
  T12  auto-resume on rollator activity (activeMinutes-keyed)

Cleanup: end-assignment + force-reset both devices; discharge synthetic patients.

Run:  python3 infra/scripts/smoke-dt0.py     (needs boto3 + dev AWS creds)
"""

from __future__ import annotations

import json
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone

import boto3

REGION = "us-east-1"
USER_POOL_CLIENT = "1q9l9ujtsomf3ugq2tnqvdg6d7"
PASSWORD = "GoSteady2026!Pass+"
USER_CAREGIVER = "rd-caregiver@test.local"
# NOTE: rd-facadmin is MFA-required (A7) → USER_PASSWORD_AUTH returns a
# challenge, not tokens. Admin-tier actions run as synthetic internal_admin
# Lambda invokes instead (Option-A pattern, §C19 precedent).

CLIENT_ID = "client_rd_test"
FACILITY_A = "fac_rd_a"
CENSUS_A1 = "cen_rd_a1"

SERIAL_ROLLATOR = "GS9999999980"  # rollator dev block per memo Q6
SERIAL_WALKER = "GS9999999991"    # walker synthetic (reserved test range)

RUN_TS = int(time.time())
PAT_WALKER = f"pat_dt0_walker_{RUN_TS}"
PAT_ROLLATOR = f"pat_dt0_rollator_{RUN_TS}"

_cog = boto3.client("cognito-idp", region_name=REGION)
_apigw = boto3.client("apigatewayv2", region_name=REGION)
_lambda = boto3.client("lambda", region_name=REGION)
_iot = boto3.client("iot-data", region_name=REGION)
_logs = boto3.client("logs", region_name=REGION)
_ddb = boto3.resource("dynamodb", region_name=REGION)
_devices = _ddb.Table("gosteady-dev-devices")
_assignments = _ddb.Table("gosteady-dev-device-assignments")
_patients = _ddb.Table("gosteady-dev-patients")
_activity = _ddb.Table("gosteady-dev-activity")

_tokens: dict[str, str] = {}
_results: list[tuple[str, bool, str]] = []


def get_token(user: str) -> str:
    if user not in _tokens:
        r = _cog.initiate_auth(
            AuthFlow="USER_PASSWORD_AUTH",
            ClientId=USER_POOL_CLIENT,
            AuthParameters={"USERNAME": user, "PASSWORD": PASSWORD},
        )
        _tokens[user] = r["AuthenticationResult"]["IdToken"]
    return _tokens[user]


def get_api_url() -> str:
    for api in _apigw.get_apis()["Items"]:
        if api["Name"] == "gosteady-dev-api":
            return api["ApiEndpoint"]
    raise RuntimeError("API not found")


API = get_api_url()


def http(method: str, path: str, token: str | None = None,
         body: dict | None = None) -> tuple[int, dict | None]:
    url = f"{API}{path}"
    data = json.dumps(body).encode("utf-8") if body is not None else None
    req = urllib.request.Request(url, method=method, data=data)
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        resp = urllib.request.urlopen(req, timeout=20)
        return resp.status, json.loads(resp.read().decode() or "null")
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.loads(e.read().decode() or "null")
        except Exception:
            return e.code, None


def record(name: str, ok: bool, detail: str = "") -> None:
    _results.append((name, ok, detail))
    print(f"  {'PASS' if ok else 'FAIL'}  {name}" + (f" — {detail}" if detail else ""))


def synthetic_admin_event(route_key: str, body: dict,
                          path_params: dict | None = None) -> dict:
    """API-GW v2 proxy event with internal_admin JWT claims (Option-A synthetic)."""
    method = route_key.split(" ", 1)[0]
    return {
        "routeKey": route_key,
        "rawPath": route_key.split(" ", 1)[1],
        "requestContext": {
            "http": {"method": method},
            "authorizer": {"jwt": {"claims": {
                "sub": "smoke-dt0-internal-admin",
                "custom:clientId": "_internal",
                "custom:role": "internal_admin",
                "custom:mfa_enrolled": "true",
                "iat": str(int(time.time())),
            }}},
        },
        "pathParameters": path_params or {},
        "body": json.dumps(body),
    }


def invoke_device_api(event: dict) -> tuple[int, dict | None]:
    resp = _lambda.invoke(
        FunctionName="gosteady-dev-device-api",
        Payload=json.dumps(event).encode(),
    )
    payload = json.loads(resp["Payload"].read())
    status = payload.get("statusCode", 0)
    try:
        body = json.loads(payload.get("body") or "null")
    except Exception:
        body = None
    return status, body


def wait_for_log(log_group: str, needle: str, since_ms: int,
                 timeout_s: int = 60) -> bool:
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        try:
            events = _logs.filter_log_events(
                logGroupName=log_group, startTime=since_ms, limit=200,
            ).get("events", [])
            if any(needle in e["message"] for e in events):
                return True
        except _logs.exceptions.ResourceNotFoundException:
            pass
        time.sleep(4)
    return False


def wait_for_activity_row(patient_id: str, session_end: str,
                          timeout_s: int = 60) -> dict | None:
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        item = _activity.get_item(
            Key={"patientId": patient_id, "timestamp": session_end}
        ).get("Item")
        if item:
            return item
        time.sleep(3)
    return None


def iso(dt: datetime) -> str:
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


def publish(topic: str, payload: dict) -> None:
    _iot.publish(topic=topic, qos=1, payload=json.dumps(payload).encode())


def seed_patient(pid: str, name: str) -> None:
    _patients.put_item(Item={
        "patientId": pid,
        "clientId": CLIENT_ID,
        "facilityId": FACILITY_A,
        "censusId": CENSUS_A1,
        "displayName": name,
        "status": "active",
        "timezone": "America/Los_Angeles",
        "status_patientId": f"active_{pid}",
        "createdAt": iso(datetime.now(timezone.utc)),
    })


def reset_devices() -> None:
    """Best-effort: return both smoke serials to ready_to_provision.
    force-reset requires facility_admin+ (fac-admin test user is MFA-
    challenged under USER_PASSWORD_AUTH), so it runs as a synthetic
    internal_admin invoke — same Option-A pattern as bulk-create."""
    for serial in (SERIAL_WALKER, SERIAL_ROLLATOR):
        rec = _devices.get_item(Key={"serialNumber": serial}).get("Item")
        if not rec or rec.get("status") == "ready_to_provision":
            continue
        invoke_device_api(synthetic_admin_event(
            "POST /api/v1/devices/{serial}/force-reset",
            {"reason": "smoke-dt0 reset"},
            path_params={"serial": serial},
        ))


def main() -> int:  # noqa: C901 — linear smoke script
    now_ms = int(time.time() * 1000)
    print(f"API: {API}\nrun ts: {RUN_TS}\n")
    print("pre-clean: force-reset smoke serials if a prior run left them provisioned")
    reset_devices()

    # ── T13: registry backfill (twice — idempotency) ────────────────
    print("T13 backfill deviceType=walker_cap on existing registry records")
    serials = [i["serialNumber"] for i in _devices.scan(
        ProjectionExpression="serialNumber").get("Items", [])]
    for run in (1, 2):
        applied = skipped = 0
        for s in serials:
            try:
                _devices.update_item(
                    Key={"serialNumber": s},
                    UpdateExpression="SET deviceType = :t",
                    ConditionExpression="attribute_not_exists(deviceType)",
                    ExpressionAttributeValues={":t": "walker_cap"},
                )
                applied += 1
            except _devices.meta.client.exceptions.ConditionalCheckFailedException:
                skipped += 1
        print(f"  run {run}: applied={applied} skipped={skipped}")
        if run == 2:
            record("T13 backfill idempotent", applied == 0,
                   f"second run applied={applied}")

    # ── T8: bulk-create (synthetic internal_admin invoke) ───────────
    print("T8 admin bulk-create rollator + walker + invalid type")
    status, body = invoke_device_api(synthetic_admin_event(
        "POST /api/v1/admin/devices",
        {"devices": [
            {"serialNumber": SERIAL_ROLLATOR, "deviceType": "rollator_platform",
             "hardwareVariant": "cupholder_v1"},
            {"serialNumber": SERIAL_WALKER},  # defaults to walker_cap
        ]},
    ))
    created = ((body or {}).get("created") or []) if status == 200 else []
    skipped_n = (body or {}).get("skipped", 0) if status == 200 else 0
    record("T8 bulk-create ok", status == 200 and (len(created) + skipped_n) == 2,
           f"status={status} created={created} skipped={skipped_n}")
    rollator_rec = _devices.get_item(Key={"serialNumber": SERIAL_ROLLATOR}).get("Item") or {}
    record("T8 rollator record typed",
           rollator_rec.get("deviceType") == "rollator_platform"
           and rollator_rec.get("hardwareVariant") == "cupholder_v1",
           f"deviceType={rollator_rec.get('deviceType')} variant={rollator_rec.get('hardwareVariant')}")

    status, body = invoke_device_api(synthetic_admin_event(
        "POST /api/v1/admin/devices",
        {"devices": [{"serialNumber": "GS9999999982", "deviceType": "hoverboard"}]},
    ))
    record("T8 invalid type 400",
           status == 400 and (body or {}).get("error", {}).get("code") == "INVALID_DEVICE_TYPE"
           if isinstance((body or {}).get("error"), dict)
           else status == 400 and "INVALID_DEVICE_TYPE" in json.dumps(body or {}),
           f"status={status}")

    # ── Seed patients + T9 provision via real API ────────────────────
    print("T9 provision via API (rd-caregiver)")
    seed_patient(PAT_WALKER, "DT0 Walker W.")
    seed_patient(PAT_ROLLATOR, "DT0 Rollator R.")
    tok = get_token(USER_CAREGIVER)
    for serial, pid, expect_type in (
        (SERIAL_WALKER, PAT_WALKER, "walker_cap"),
        (SERIAL_ROLLATOR, PAT_ROLLATOR, "rollator_platform"),
    ):
        status, body = http("POST", f"/api/v1/devices/{serial}/provision",
                            token=tok, body={"patientId": pid})
        rows = _assignments.query(
            KeyConditionExpression=boto3.dynamodb.conditions.Key("serialNumber").eq(serial),
            ScanIndexForward=False, Limit=1,
        ).get("Items", [])
        got_type = rows[0].get("deviceType") if rows else None
        record(f"T9 provision {serial}",
               status == 200 and got_type == expect_type,
               f"status={status} assignment.deviceType={got_type}")

    status, body = http("GET", f"/api/v1/devices/{SERIAL_ROLLATOR}", token=tok)
    dev_view = (body or {}).get("device", {}) if status == 200 else {}
    record("GET device returns type",
           dev_view.get("deviceType") == "rollator_platform"
           and dev_view.get("hardwareVariant") == "cupholder_v1",
           f"status={status} view.deviceType={dev_view.get('deviceType')}")

    # ── T1: walker activity regression ───────────────────────────────
    print("T1/T4 walker activity (happy + missing steps)")
    t1_end = iso(datetime.now(timezone.utc) - timedelta(minutes=1))
    publish(f"gs/{SERIAL_WALKER}/activity", {
        "serial": SERIAL_WALKER,
        "session_start": iso(datetime.now(timezone.utc) - timedelta(minutes=11)),
        "session_end": t1_end, "clock_synced": True,
        "steps": 42, "distance_ft": 50.09, "active_min": 4,
        "gait_speed_fts": 1.1, "roughness_R": 0.09, "surface_class": "indoor",
        "firmware_version": "0.17.0-smoke",
    })
    row = wait_for_activity_row(PAT_WALKER, t1_end)
    record("T1 walker row", bool(row) and row.get("deviceType") == "walker_cap"
           and int(row.get("steps", -1)) == 42 and "gaitSpeedFts" in row,
           f"deviceType={row.get('deviceType') if row else None}")

    publish(f"gs/{SERIAL_WALKER}/activity", {
        "serial": SERIAL_WALKER, "session_end": iso(datetime.now(timezone.utc)),
        "clock_synced": True, "distance_ft": 10.0, "active_min": 2,
    })
    record("T4 walker missing steps rejected",
           wait_for_log("/aws/lambda/gosteady-dev-activity-processor",
                        "missing:steps", now_ms))

    # ── T2/T3: rollator activity ─────────────────────────────────────
    print("T2/T3 rollator activity (v0 contract + missing active_min)")
    t2_end = iso(datetime.now(timezone.utc) - timedelta(seconds=30))
    publish(f"gs/{SERIAL_ROLLATOR}/activity", {
        "serial": SERIAL_ROLLATOR,
        "session_start": iso(datetime.now(timezone.utc) - timedelta(minutes=6)),
        "session_end": t2_end, "clock_synced": True,
        "active_min": 4, "push_time_s": 33,  # provisional → extras
        "firmware_version": "rol-0.1.0-smoke",
    })
    row = wait_for_activity_row(PAT_ROLLATOR, t2_end)
    extras = (row or {}).get("extras") or {}
    record("T2 rollator row",
           bool(row) and row.get("deviceType") == "rollator_platform"
           and int(row.get("activeMinutes", -1)) == 4
           and "steps" not in row and "push_time_s" in extras,
           f"deviceType={row.get('deviceType') if row else None} "
           f"steps_absent={bool(row) and 'steps' not in row} extras={list(extras)}")

    publish(f"gs/{SERIAL_ROLLATOR}/activity", {
        "serial": SERIAL_ROLLATOR, "session_end": iso(datetime.now(timezone.utc)),
        "clock_synced": True, "steps": 10, "distance_ft": 5.0,
    })
    record("T3 rollator missing active_min rejected",
           wait_for_log("/aws/lambda/gosteady-dev-activity-processor",
                        "missing:active_min", now_ms))

    # ── T5: rollator device alert rejects ────────────────────────────
    print("T5 rollator alert enum empty")
    publish(f"gs/{SERIAL_ROLLATOR}/alert", {
        "serial": SERIAL_ROLLATOR, "ts": iso(datetime.now(timezone.utc)),
        "alert_type": "tipover", "severity": "critical",
    })
    record("T5 rollator tipover rejected",
           wait_for_log("/aws/lambda/gosteady-dev-alert-handler",
                        "bad_alert_type:tipover", now_ms))

    # ── T6/T7: heartbeat device_type cross-check ─────────────────────
    print("T6/T7 heartbeat device_type mismatch/match")
    publish(f"gs/{SERIAL_WALKER}/heartbeat", {
        "serial": SERIAL_WALKER, "battery_pct": 0.9, "rsrp_dbm": -80,
        "snr_db": 10, "clock_synced": True, "device_type": "rollator_platform",
    })
    record("T6 mismatch detected",
           wait_for_log("/aws/lambda/gosteady-dev-heartbeat-processor",
                        "device_type_mismatch", now_ms))
    t7_ms = int(time.time() * 1000)
    publish(f"gs/{SERIAL_ROLLATOR}/heartbeat", {
        "serial": SERIAL_ROLLATOR, "battery_pct": 0.9, "rsrp_dbm": -80,
        "snr_db": 10, "clock_synced": True, "device_type": "rollator_platform",
    })
    got_hb = wait_for_log("/aws/lambda/gosteady-dev-heartbeat-processor",
                          f"heartbeat accepted for {SERIAL_ROLLATOR}", t7_ms, 45) or \
        wait_for_log("/aws/lambda/gosteady-dev-heartbeat-processor",
                     SERIAL_ROLLATOR, t7_ms, 15)
    events = _logs.filter_log_events(
        logGroupName="/aws/lambda/gosteady-dev-heartbeat-processor",
        startTime=t7_ms, limit=200).get("events", [])
    t7_mismatch = any("device_type_mismatch" in e["message"]
                      and SERIAL_ROLLATOR in e["message"] for e in events)
    record("T7 match → no mismatch", got_hb and not t7_mismatch,
           f"heartbeat_seen={got_hb} mismatch_logged={t7_mismatch}")

    # ── T12: auto-resume keyed on activeMinutes ──────────────────────
    print("T12 auto-resume on rollator activity")
    _patients.update_item(
        Key={"patientId": PAT_ROLLATOR},
        UpdateExpression="SET notificationsPaused = :p",
        ExpressionAttributeValues={":p": {
            "until": RUN_TS + 7 * 86400, "reason": "in_hospital",
            "pausedAt": RUN_TS, "pausedBy": "smoke-dt0",
        }},
    )
    t12_end = iso(datetime.now(timezone.utc) + timedelta(seconds=1))
    publish(f"gs/{SERIAL_ROLLATOR}/activity", {
        "serial": SERIAL_ROLLATOR,
        "session_start": iso(datetime.now(timezone.utc) - timedelta(minutes=3)),
        "session_end": t12_end, "clock_synced": True, "active_min": 3,
    })
    deadline = time.time() + 60
    resumed = False
    while time.time() < deadline and not resumed:
        p = _patients.get_item(Key={"patientId": PAT_ROLLATOR}).get("Item") or {}
        resumed = "notificationsPaused" not in p
        if not resumed:
            time.sleep(3)
    record("T12 auto-resume cleared pause", resumed)

    # ── Cleanup ──────────────────────────────────────────────────────
    print("cleanup: end-assignment + force-reset + discharge synthetic patients")
    for serial in (SERIAL_WALKER, SERIAL_ROLLATOR):
        http("POST", f"/api/v1/devices/{serial}/end-assignment", token=tok, body={})
    reset_devices()
    for pid in (PAT_WALKER, PAT_ROLLATOR):
        _patients.update_item(
            Key={"patientId": pid},
            UpdateExpression="SET #s = :d, status_patientId = :sp",
            ExpressionAttributeNames={"#s": "status"},
            ExpressionAttributeValues={":d": "discharged",
                                       ":sp": f"discharged_{pid}"},
        )

    # ── Summary ──────────────────────────────────────────────────────
    passed = sum(1 for _, ok, _ in _results if ok)
    print(f"\n{'=' * 60}\n{passed}/{len(_results)} PASS")
    for name, ok, detail in _results:
        if not ok:
            print(f"  FAIL: {name} — {detail}")
    return 0 if passed == len(_results) else 1


if __name__ == "__main__":
    sys.exit(main())

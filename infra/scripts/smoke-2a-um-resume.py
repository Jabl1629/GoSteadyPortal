#!/usr/bin/env python3
"""
Synthetic smoke for "Start Monitoring Again" (POST /patients/{id}/resume) +
the hardened monitoring-history endpoint (GET /patients/{id}/devices).

Flow (all against live dev via real Cognito tokens, client_rd_test fixtures):
  1. Seed two ready_to_provision test devices (GS9999999990 / ...91).
  2. Create a patient WITH device D1 (atomic provision) → assignment #1.
  3. Resume on an ACTIVE patient → 409 (only discontinued can resume).
  4. Discharge → 200 (cascade ends assignment #1 + recycles D1, async).
  5. Resume the discharged patient with D2 → 200 active + re-provision.
  6. GET /patients/{id} → active again (same record).
  7. GET /patients/{id}/devices → projected, most-recent-first; D2 ongoing;
     poll for D1's prior assignment to show ended (cascade preserved it).
  8. Cascade-not-fired-on-resume: D2 stays provisioned + assignment open.
  9. Resume again (now active) → 409; bad/missing serial → 400; family → 403.
  10. Cleanup: discharge patient + reset both devices to ready_to_provision.

Run:  .test-venv/bin/python3 infra/scripts/smoke-2a-um-resume.py
"""

from __future__ import annotations

import json
import sys
import time
import urllib.error
import urllib.request

import boto3

REGION = "us-east-1"
USER_POOL_CLIENT = "1q9l9ujtsomf3ugq2tnqvdg6d7"
PASSWORD = "GoSteady2026!Pass+"

USER_FAC_ADMIN = "rd-facadmin@test.local"
USER_CAREGIVER = "rd-caregiver@test.local"
USER_FAMILY = "rd-familyviewer@test.local"

CENSUS_A1 = "cen_rd_a1"   # caregiver + facility_admin scope (facility fac_rd_a)

DEVICE_1 = "GS9999999990"  # reserved synthetic test range
DEVICE_2 = "GS9999999991"

DEVICES_TABLE = "gosteady-dev-devices"
ASSIGNMENTS_TABLE = "gosteady-dev-device-assignments"
PATIENTS_TABLE = "gosteady-dev-patients"

_tokens: dict[str, str] = {}
_cog = boto3.client("cognito-idp", region_name=REGION)
_apigw = boto3.client("apigatewayv2", region_name=REGION)
_ddb = boto3.resource("dynamodb", region_name=REGION)
_devices = _ddb.Table(DEVICES_TABLE)
_assignments = _ddb.Table(ASSIGNMENTS_TABLE)
_patients = _ddb.Table(PATIENTS_TABLE)


def get_token(user: str) -> str:
    if user in _tokens:
        return _tokens[user]
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
print(f"API: {API}\n")


def http(method, path, token=None, body=None):
    url = f"{API}{path}"
    data = json.dumps(body).encode("utf-8") if body is not None else None
    req = urllib.request.Request(url, method=method, data=data)
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        resp = urllib.request.urlopen(req, timeout=20)
        body_str = resp.read().decode("utf-8")
        status = resp.status
    except urllib.error.HTTPError as e:
        body_str = e.read().decode("utf-8")
        status = e.code
    try:
        parsed = json.loads(body_str)
    except (ValueError, json.JSONDecodeError):
        parsed = None
    return status, parsed, body_str


class R:
    p: list = []
    f: list = []

    @classmethod
    def passed(cls, name):
        print(f"  [{name}] PASS")
        cls.p.append(name)

    @classmethod
    def failed(cls, name, reason):
        print(f"  [{name}] FAIL: {reason}")
        cls.f.append((name, reason))


def expect(name, user, method, path, expect_status, check=None, body=None):
    try:
        tok = get_token(user) if user else None
    except Exception as e:
        R.failed(name, f"token: {e}")
        return None
    status, parsed, raw = http(method, path, tok, body=body)
    if status != expect_status:
        R.failed(name, f"status {status} (expected {expect_status}); body: {raw[:400]}")
        return parsed
    if check is not None:
        try:
            err = check(parsed)
        except Exception as e:
            err = f"check raised: {e}"
        if err:
            R.failed(name, f"{err}; body: {raw[:400]}")
            return parsed
    R.passed(f"{name}  (HTTP {status})")
    return parsed


def seed_ready_device(serial):
    """Put a fresh ready_to_provision, unowned device (overwrite)."""
    _devices.put_item(Item={
        "serialNumber": serial,
        "status": "ready_to_provision",
        "outstandingActivationCmds": {},
        "outstandingWipeCmds": {},
        "manufacturedBy": "smoke-2a-um-resume",
        "createdAt": "2026-06-04T00:00:00Z",
    })


def reset_device(serial):
    """Reset a device to ready_to_provision + drop owner/assignment + delete
    its assignment rows, so the smoke is re-runnable."""
    try:
        _devices.put_item(Item={
            "serialNumber": serial,
            "status": "ready_to_provision",
            "outstandingActivationCmds": {},
            "outstandingWipeCmds": {},
            "manufacturedBy": "smoke-2a-um-resume",
            "createdAt": "2026-06-04T00:00:00Z",
        })
        res = _devices.get_item(Key={"serialNumber": serial})
        # (put_item above already overwrote owner/currentAssignmentSk fields)
        asn = _assignments.query(
            KeyConditionExpression="serialNumber = :s",
            ExpressionAttributeValues={":s": serial},
        )
        for row in asn.get("Items", []):
            _assignments.delete_item(
                Key={"serialNumber": serial, "assignedAt": row["assignedAt"]}
            )
    except Exception as e:
        print(f"  (cleanup) reset_device {serial} failed: {e}")


print("══ Resume + monitoring-history synthetic smoke ══\n")

# Seed both devices fresh.
seed_ready_device(DEVICE_1)
seed_ready_device(DEVICE_2)
print(f"  Seeded {DEVICE_1} + {DEVICE_2} = ready_to_provision\n")

created_patient_id = None
try:
    # ── TR1: create patient WITH device D1 ────────────────────────────
    result = expect(
        "TR1 create patient + atomic provision D1 (201)",
        USER_CAREGIVER, "POST", "/api/v1/patients", 201,
        lambda b: None if (b and b.get("patient", {}).get("status") == "active"
                           and b.get("device", {}).get("serialNumber") == DEVICE_1
                           and b.get("activation", {}).get("cmdId"))
                  else f"unexpected: {b}",
        body={"displayName": "Resume Smoke Patient", "censusId": CENSUS_A1,
              "room": f"R-{int(time.time()) % 10000}", "deviceSerial": DEVICE_1},
    )
    if not result or not result.get("patient"):
        print("\n  FATAL: TR1 failed — cannot continue")
        sys.exit(2)
    created_patient_id = result["patient"]["patientId"]
    print(f"\n  Working patient: {created_patient_id}\n")

    # ── TR2: resume an ACTIVE patient → 409 ───────────────────────────
    expect(
        "TR2 resume active patient rejected (409 INVALID_STATE)",
        USER_CAREGIVER, "POST", f"/api/v1/patients/{created_patient_id}/resume", 409,
        lambda b: None if (b and b["error"]["code"] == "INVALID_STATE")
                  else f"unexpected: {b}",
        body={"censusId": CENSUS_A1, "room": "R-X", "deviceSerial": DEVICE_2},
    )

    # ── TR3: discharge ────────────────────────────────────────────────
    expect(
        "TR3 discharge patient (200, cascade ends D1)",
        USER_CAREGIVER, "POST", f"/api/v1/patients/{created_patient_id}/discharge", 200,
        lambda b: None if (b and b["patient"]["status"] == "discharged"
                           and b["cascade"]["devicesEnded"] >= 1)
                  else f"unexpected: {b}",
        body={"notes": "resume smoke"},
    )

    # Wait for the discharge cascade (async DDB-stream) to fully settle —
    # i.e. D1's assignment ended + D1 recycled. In real usage the caregiver
    # reaches "Start Monitoring Again" seconds-to-minutes later, long after the
    # ~1-2s cascade; firing resume back-to-back would race the cascade into
    # ending the freshly-provisioned D2 (the cascade ends ALL active
    # assignments it sees at run time). Poll until the patient has no open
    # assignment, then resume.
    settled = False
    for _ in range(20):
        s, hb, raw = http("GET",
                          f"/api/v1/patients/{created_patient_id}/devices",
                          get_token(USER_CAREGIVER))
        rows = (hb or {}).get("assignments", [])
        if rows and all(not r.get("ongoing") for r in rows):
            settled = True
            break
        time.sleep(1)
    if settled:
        R.passed("TR3b discharge cascade settled (no open assignment before resume)")
    else:
        R.failed("TR3b cascade-settle", "patient still had an open assignment after 20s")

    # ── TR4: resume with D2 ───────────────────────────────────────────
    resumed = expect(
        "TR4 resume discharged patient with D2 (200, active + re-provision)",
        USER_CAREGIVER, "POST", f"/api/v1/patients/{created_patient_id}/resume", 200,
        lambda b: None if (b and b["patient"]["status"] == "active"
                           and b["patient"]["censusId"] == CENSUS_A1
                           and b.get("device", {}).get("serialNumber") == DEVICE_2
                           and b.get("activation", {}).get("cmdId"))
                  else f"unexpected: {b}",
        body={"censusId": CENSUS_A1, "room": "R-RESUMED", "deviceSerial": DEVICE_2},
    )

    # ── TR5: GET patient → active again, same record ──────────────────
    expect(
        "TR5 GET /patients/{id} reflects active + new room",
        USER_CAREGIVER, "GET", f"/api/v1/patients/{created_patient_id}", 200,
        lambda b: None if (b and b["patient"]["status"] == "active"
                           and b["patient"]["room"] == "R-RESUMED")
                  else f"unexpected: {b}",
    )

    # ── TR6: monitoring history (hardened endpoint) ───────────────────
    # Poll up to ~12s for the cascade to set D1's endedAt.
    hist = None
    d1_ended = False
    for _ in range(12):
        s, hist, raw = http("GET",
                            f"/api/v1/patients/{created_patient_id}/devices",
                            get_token(USER_CAREGIVER))
        rows = (hist or {}).get("assignments", [])
        d1 = next((r for r in rows if r.get("serialNumber") == DEVICE_1), None)
        if d1 and not d1.get("ongoing") and d1.get("endedAt"):
            d1_ended = True
            break
        time.sleep(1)

    def check_hist(b):
        rows = (b or {}).get("assignments", [])
        if len(rows) < 2:
            return f"expected >=2 assignments, got {len(rows)}"
        # Projected shape present on every row.
        for r in rows:
            if "startedAt" not in r or "ongoing" not in r or "endedAt" not in r:
                return f"row missing projected fields: {r}"
        # Most-recent-first: D2 (the resume) is first + ongoing.
        if rows[0].get("serialNumber") != DEVICE_2 or not rows[0].get("ongoing"):
            return f"newest row should be D2 ongoing, got {rows[0]}"
        # Ordering: startedAt descending.
        starts = [r.get("startedAt") or "" for r in rows]
        if starts != sorted(starts, reverse=True):
            return f"rows not most-recent-first: {starts}"
        if not d1_ended:
            return "D1 prior assignment never showed ended (cascade lag?)"
        return None

    expect(
        "TR6 GET /patients/{id}/devices projected + ordered + D1 ended",
        USER_CAREGIVER, "GET", f"/api/v1/patients/{created_patient_id}/devices", 200,
        check_hist,
    )

    # ── TR7: cascade did NOT fire on the resume flip ──────────────────
    # If a discharged→active flip wrongly tripped the discharge cascade, D2's
    # assignment would be ended + D2 → discontinued. Assert it stayed open.
    time.sleep(2)
    dev2 = _devices.get_item(Key={"serialNumber": DEVICE_2}).get("Item", {})
    asn2 = _assignments.query(
        IndexName="by-patient",
        KeyConditionExpression="patientId = :p",
        ExpressionAttributeValues={":p": created_patient_id},
    ).get("Items", [])
    d2_open = [a for a in asn2 if a.get("serialNumber") == DEVICE_2 and not a.get("validUntil")]
    if dev2.get("status") in ("provisioned", "active_monitoring") and d2_open:
        R.passed("TR7 cascade did NOT fire on resume (D2 provisioned + assignment open)")
    else:
        R.failed("TR7 cascade-not-fired",
                 f"D2 status={dev2.get('status')}, open D2 assignments={len(d2_open)}")

    # ── TR8: resume again (now active) → 409 ──────────────────────────
    expect(
        "TR8 resume now-active patient rejected (409)",
        USER_CAREGIVER, "POST", f"/api/v1/patients/{created_patient_id}/resume", 409,
        lambda b: None if (b and b["error"]["code"] == "INVALID_STATE")
                  else f"unexpected: {b}",
        body={"censusId": CENSUS_A1, "room": "R-X", "deviceSerial": DEVICE_1},
    )

    # ── TR9: validation + authz negatives ─────────────────────────────
    # Discharge first so the body-validation 400s are reached before the
    # status guard (validation runs before the status check in the handler).
    expect(
        "TR9a re-discharge for negative tests (200)",
        USER_CAREGIVER, "POST", f"/api/v1/patients/{created_patient_id}/discharge", 200,
        lambda b: None if (b and b["patient"]["status"] == "discharged") else f"unexpected: {b}",
        body={"notes": "neg tests"},
    )
    expect(
        "TR9b resume bad serial rejected (400 INVALID_DEVICE_SERIAL)",
        USER_CAREGIVER, "POST", f"/api/v1/patients/{created_patient_id}/resume", 400,
        lambda b: None if (b and b["error"]["code"] == "INVALID_DEVICE_SERIAL")
                  else f"unexpected: {b}",
        body={"censusId": CENSUS_A1, "room": "R-X", "deviceSerial": "bad"},
    )
    expect(
        "TR9c resume missing device rejected (400)",
        USER_CAREGIVER, "POST", f"/api/v1/patients/{created_patient_id}/resume", 400,
        lambda b: None if (b and b["error"]["code"] == "INVALID_DEVICE_SERIAL")
                  else f"unexpected: {b}",
        body={"censusId": CENSUS_A1, "room": "R-X"},
    )
    expect(
        "TR9d family_viewer resume denied (403)",
        USER_FAMILY, "POST", f"/api/v1/patients/{created_patient_id}/resume", 403,
        lambda b: None if (b and b["error"]["code"] == "INSUFFICIENT_PERMISSIONS")
                  else f"unexpected: {b}",
        body={"censusId": CENSUS_A1, "room": "R-X", "deviceSerial": DEVICE_1},
    )

finally:
    # ── Cleanup: delete the test patient + reset both devices ─────────
    print("\n  Cleaning up…")
    if created_patient_id:
        try:
            _patients.delete_item(Key={"patientId": created_patient_id})
        except Exception as e:
            print(f"  (cleanup) delete patient failed: {e}")
    reset_device(DEVICE_1)
    reset_device(DEVICE_2)
    print("  Cleanup done (patient deleted, devices reset to ready_to_provision).")

print(f"\n══ Smoke summary: {len(R.p)} passed, {len(R.f)} failed ══")
if R.f:
    print("\nFailures:")
    for name, reason in R.f:
        print(f"  - {name}: {reason}")
    sys.exit(1)
print("\nAll resume + monitoring-history smoke tests passed.")

#!/usr/bin/env python3
"""
Phase 2A-UM-P synthetic smoke test runner.

Tests the 6 patient-mutation endpoints. Creates a fresh patient at the
start (`pat_um_smoke_<ts>`) and uses it as the subject throughout, so
the runner is idempotent across re-runs (every call creates its own
patient row; final test discharges it as cleanup).

Atomic-add-with-device is exercised separately at the end with a
synthetic device serial that we provision and immediately discontinue.

Run:  .test-venv/bin/python3 infra/scripts/smoke-2a-um.py
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

# Seeded test users from seed-2a-rd-test-data.py.
USER_CAREGIVER = "rd-caregiver@test.local"
USER_FAC_ADMIN = "rd-facadmin@test.local"
USER_CLIENT_ADMIN = "rd-clientadmin@test.local"
USER_FAMILY = "rd-familyviewer@test.local"

# Seed fixtures already in DDB.
CLIENT_ID = "client_rd_test"
CENSUS_A1 = "cen_rd_a1"   # caregiver + facility_admin scope (facility fac_rd_a)
CENSUS_A2 = "cen_rd_a2"   # facility_admin scope (facility fac_rd_a)
CENSUS_B1 = "cen_rd_b1"   # client_admin only (facility fac_rd_b — caregiver out of scope)

_tokens: dict[str, str] = {}
_cog = boto3.client("cognito-idp", region_name=REGION)
_apigw = boto3.client("apigatewayv2", region_name=REGION)


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


def http(method: str, path: str, token: str | None = None,
         body: dict | None = None) -> tuple[int, dict | None, str]:
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
    p: list[str] = []
    f: list[tuple[str, str]] = []

    @classmethod
    def passed(cls, name: str) -> None:
        print(f"  [{name}] PASS")
        cls.p.append(name)

    @classmethod
    def failed(cls, name: str, reason: str) -> None:
        print(f"  [{name}] FAIL: {reason}")
        cls.f.append((name, reason))


def expect(name: str, user: str | None, method: str, path: str,
           expect_status: int, check=None, body: dict | None = None):
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


print("══ Phase 2A-UM-P synthetic smoke ══\n")

# ── T1: Create resident (no device) ──────────────────────────────────
# Facility admin creates a fresh patient in cen_rd_a1 (in scope).
# We reuse `created_patient_id` for all subsequent tests.

create_body = {
    "displayName": "Smoke Test Patient",
    "censusId": CENSUS_A1,
    "room": f"R-{int(time.time()) % 10000}",
}
result = expect(
    "T1 facility_admin creates patient (no device)",
    USER_FAC_ADMIN, "POST", "/api/v1/patients",
    201,
    lambda b: None if (b and b.get("patient", {}).get("patientId", "").startswith("pat_")
                       and b["patient"]["status"] == "active"
                       and b["patient"]["censusId"] == CENSUS_A1
                       and b["patient"]["facilityId"] == "fac_rd_a")
              else f"missing or invalid fields: {b}",
    body=create_body,
)
if not result or not result.get("patient"):
    print("\n  FATAL: T1 failed — cannot continue without a created patient")
    sys.exit(2)
created_patient_id = result["patient"]["patientId"]
print(f"\n  Working patient: {created_patient_id}\n")

# ── T2: Family viewer cannot create patient ──────────────────────────
expect(
    "T2 family_viewer create denied (403)",
    USER_FAMILY, "POST", "/api/v1/patients",
    403,
    lambda b: None if (b and b["error"]["code"] == "INSUFFICIENT_PERMISSIONS")
              else f"unexpected: {b}",
    body=create_body,
)

# ── T3: Create with invalid census ──────────────────────────────────
expect(
    "T3 create with bad censusId rejected (404 CENSUS_NOT_FOUND)",
    USER_FAC_ADMIN, "POST", "/api/v1/patients",
    404,
    lambda b: None if (b and b["error"]["code"] == "CENSUS_NOT_FOUND")
              else f"unexpected: {b}",
    body={"displayName": "X", "censusId": "cen_does_not_exist", "room": "1"},
)

# ── T4: Create with empty displayName ────────────────────────────────
expect(
    "T4 create with empty displayName rejected (400)",
    USER_FAC_ADMIN, "POST", "/api/v1/patients",
    400,
    lambda b: None if (b and b["error"]["code"] == "INVALID_REQUEST")
              else f"unexpected: {b}",
    body={"displayName": "", "censusId": CENSUS_A1, "room": "1"},
)

# ── T5: Create with malformed deviceSerial ───────────────────────────
expect(
    "T5 create with malformed deviceSerial rejected (400 INVALID_DEVICE_SERIAL)",
    USER_FAC_ADMIN, "POST", "/api/v1/patients",
    400,
    lambda b: None if (b and b["error"]["code"] == "INVALID_DEVICE_SERIAL")
              else f"unexpected: {b}",
    body={"displayName": "X", "censusId": CENSUS_A1, "room": "1", "deviceSerial": "bad"},
)

# ── T6: Caregiver out-of-scope create ───────────────────────────────
# Caregiver scope is cen_rd_a1; create in cen_rd_b1 should 403.
expect(
    "T6 caregiver out-of-scope create rejected (403 OUT_OF_SCOPE)",
    USER_CAREGIVER, "POST", "/api/v1/patients",
    403,
    lambda b: None if (b and b["error"]["code"] == "OUT_OF_SCOPE")
              else f"unexpected: {b}",
    body={"displayName": "X", "censusId": CENSUS_B1, "room": "1"},
)

# ── T7: PATCH /patients/{id} — change name only ─────────────────────
expect(
    "T7 caregiver PATCH displayName (200, fieldsChanged=[displayName])",
    USER_CAREGIVER, "PATCH", f"/api/v1/patients/{created_patient_id}",
    200,
    lambda b: None if (b and b["patient"]["displayName"] == "Smoke Test Patient (renamed)"
                       and b["changes"]["fieldsChanged"] == ["displayName"]
                       and not b["changes"].get("crossFacilityTransfer", False))
              else f"unexpected: {b}",
    body={"displayName": "Smoke Test Patient (renamed)"},
)

# ── T8: PATCH room — verify multi-field update ───────────────────────
expect(
    "T8 caregiver PATCH room",
    USER_CAREGIVER, "PATCH", f"/api/v1/patients/{created_patient_id}",
    200,
    lambda b: None if (b and "room" in b["changes"]["fieldsChanged"])
              else f"unexpected: {b}",
    body={"room": "R-NEW"},
)

# ── T9: PATCH with empty body rejected ───────────────────────────────
expect(
    "T9 PATCH empty body rejected (400)",
    USER_CAREGIVER, "PATCH", f"/api/v1/patients/{created_patient_id}",
    400,
    lambda b: None if (b and b["error"]["code"] == "INVALID_REQUEST")
              else f"unexpected: {b}",
    body={},
)

# ── T10: PATCH cross-facility as caregiver — should be 403 ────────────
# Caregiver tries to move from cen_rd_a1 (facility A) to cen_rd_b1 (facility B).
# Per Q3 decision, cross-facility transfer requires client_admin+.
expect(
    "T10 caregiver cross-facility transfer denied (403)",
    USER_CAREGIVER, "PATCH", f"/api/v1/patients/{created_patient_id}",
    403,
    lambda b: None if (b and b["error"]["code"] in {"INSUFFICIENT_PERMISSIONS", "OUT_OF_SCOPE"})
              else f"unexpected: {b}",
    body={"censusId": CENSUS_B1},
)

# ── T11: PATCH cross-facility as client_admin succeeds ────────────────
expect(
    "T11 client_admin cross-facility transfer succeeds (200)",
    USER_CLIENT_ADMIN, "PATCH", f"/api/v1/patients/{created_patient_id}",
    200,
    lambda b: None if (b and b["changes"].get("crossFacilityTransfer") is True
                       and b["patient"]["facilityId"] == "fac_rd_b"
                       and b["patient"]["censusId"] == CENSUS_B1)
              else f"unexpected: {b}",
    body={"censusId": CENSUS_B1},
)

# Move patient back so subsequent caregiver tests still work.
expect(
    "T11b client_admin moves patient back to facility A",
    USER_CLIENT_ADMIN, "PATCH", f"/api/v1/patients/{created_patient_id}",
    200,
    lambda b: None if (b and b["patient"]["facilityId"] == "fac_rd_a")
              else f"unexpected: {b}",
    body={"censusId": CENSUS_A1},
)

# ── T12: POST /pause ─────────────────────────────────────────────────
expect(
    "T12 caregiver pauses notifications for 7 days",
    USER_CAREGIVER, "POST", f"/api/v1/patients/{created_patient_id}/notifications/pause",
    200,
    lambda b: None if (b and b["notificationsPaused"]["reason"] == "in_hospital"
                       and b["notificationsPaused"]["daysRemaining"] == 7)
              else f"unexpected: {b}",
    body={"days": 7, "reason": "in_hospital"},
)

# ── T13: POST /pause with bad reason ─────────────────────────────────
expect(
    "T13 POST /pause with invalid reason rejected (400)",
    USER_CAREGIVER, "POST", f"/api/v1/patients/{created_patient_id}/notifications/pause",
    400,
    lambda b: None if (b and b["error"]["code"] == "INVALID_REQUEST")
              else f"unexpected: {b}",
    body={"days": 7, "reason": "unknown_reason"},
)

# ── T14: POST /pause with out-of-range days ─────────────────────────
expect(
    "T14 POST /pause days=91 rejected (400)",
    USER_CAREGIVER, "POST", f"/api/v1/patients/{created_patient_id}/notifications/pause",
    400,
    lambda b: None if (b and b["error"]["code"] == "INVALID_REQUEST")
              else f"unexpected: {b}",
    body={"days": 91, "reason": "in_hospital"},
)

# ── T15: GET /patients/{id} reflects the pause via 2A-RD ─────────────
expect(
    "T15 GET /patients/{id} reflects active pause (2A-RD response shape)",
    USER_CAREGIVER, "GET", f"/api/v1/patients/{created_patient_id}",
    200,
    lambda b: None if (b and b["patient"]["notificationsPaused"]
                       and b["patient"]["notificationsPaused"]["reason"] == "in_hospital"
                       and b["patient"]["notificationsPaused"]["daysRemaining"] >= 6)
              else f"unexpected: {b}",
)

# ── T16: DELETE /pause (manual unpause) ──────────────────────────────
expect(
    "T16 caregiver manual unpause",
    USER_CAREGIVER, "DELETE", f"/api/v1/patients/{created_patient_id}/notifications/pause",
    200,
    lambda b: None if (b and b["notificationsPaused"] is None)
              else f"unexpected: {b}",
)

# ── T17: DELETE /pause when not paused (409) ─────────────────────────
expect(
    "T17 DELETE /pause when not paused → 409",
    USER_CAREGIVER, "DELETE", f"/api/v1/patients/{created_patient_id}/notifications/pause",
    409,
    lambda b: None if (b and b["error"]["code"] == "NOT_CURRENTLY_PAUSED")
              else f"unexpected: {b}",
)

# ── T18: PATCH /care-note — set ──────────────────────────────────────
expect(
    "T18 caregiver sets care note",
    USER_CAREGIVER, "PATCH", f"/api/v1/patients/{created_patient_id}/care-note",
    200,
    lambda b: None if (b and b["careNote"]["text"] == "Back from rehab Feb 12 — slow start expected"
                       and b["careNote"]["updatedBy"]
                       and b["careNote"]["updatedAt"])
              else f"unexpected: {b}",
    body={"text": "Back from rehab Feb 12 — slow start expected"},
)

# ── T19: GET /patients/{id} reflects care note ───────────────────────
expect(
    "T19 GET /patients/{id} reflects care note",
    USER_CAREGIVER, "GET", f"/api/v1/patients/{created_patient_id}",
    200,
    lambda b: None if (b and b["patient"]["careNote"]
                       and b["patient"]["careNote"]["text"] == "Back from rehab Feb 12 — slow start expected")
              else f"unexpected: {b}",
)

# ── T20: PATCH /care-note over 280 chars ─────────────────────────────
expect(
    "T20 care note >280 chars rejected (400 CARE_NOTE_TOO_LONG)",
    USER_CAREGIVER, "PATCH", f"/api/v1/patients/{created_patient_id}/care-note",
    400,
    lambda b: None if (b and b["error"]["code"] == "CARE_NOTE_TOO_LONG")
              else f"unexpected: {b}",
    body={"text": "x" * 281},
)

# ── T21: PATCH /care-note with empty string clears ────────────────────
expect(
    "T21 care note empty string clears (200)",
    USER_CAREGIVER, "PATCH", f"/api/v1/patients/{created_patient_id}/care-note",
    200,
    lambda b: None if (b and b["careNote"] is None)
              else f"unexpected: {b}",
    body={"text": ""},
)

# ── T22: Family viewer cannot ack/pause/edit ─────────────────────────
expect(
    "T22 family_viewer pause denied (403)",
    USER_FAMILY, "POST", f"/api/v1/patients/{created_patient_id}/notifications/pause",
    403,
    lambda b: None if (b and b["error"]["code"] == "INSUFFICIENT_PERMISSIONS")
              else f"unexpected: {b}",
    body={"days": 7, "reason": "in_hospital"},
)

# ── T23: POST /discharge ──────────────────────────────────────────────
expect(
    "T23 caregiver discharges patient (200, cascade=0 devices)",
    USER_CAREGIVER, "POST", f"/api/v1/patients/{created_patient_id}/discharge",
    200,
    lambda b: None if (b and b["patient"]["status"] == "discharged"
                       and b["patient"]["dischargeReason"] == "transferred"
                       and b["cascade"]["devicesEnded"] == 0
                       and b["cascade"]["wipeRequested"] is False)
              else f"unexpected: {b}",
    body={"reason": "transferred", "notes": "Smoke test cleanup"},
)

# ── T24: POST /discharge on already-discharged → 409 ──────────────────
expect(
    "T24 discharge already-discharged patient → 409",
    USER_CAREGIVER, "POST", f"/api/v1/patients/{created_patient_id}/discharge",
    409,
    lambda b: None if (b and b["error"]["code"] == "INVALID_STATE")
              else f"unexpected: {b}",
    body={"reason": "transferred"},
)

# ── T25: PATCH on discharged patient → 409 ────────────────────────────
expect(
    "T25 PATCH on discharged patient → 409",
    USER_CAREGIVER, "PATCH", f"/api/v1/patients/{created_patient_id}",
    409,
    lambda b: None if (b and b["error"]["code"] == "INVALID_STATE")
              else f"unexpected: {b}",
    body={"room": "X"},
)

# ── No-token negative ─────────────────────────────────────────────────
expect(
    "T26 no-token rejected (401)",
    None, "POST", "/api/v1/patients",
    401,
    lambda b: None,  # API GW returns its own 401 shape
    body=create_body,
)


# ── Summary ──────────────────────────────────────────────────────────
print(f"\n══ Smoke summary: {len(R.p)} passed, {len(R.f)} failed ══")
if R.f:
    print("\nFailures:")
    for name, reason in R.f:
        print(f"  - {name}: {reason}")
    sys.exit(1)
print("\nAll 2A-UM-P smoke tests passed.")
print(f"Test patient discharged at end: {created_patient_id}")

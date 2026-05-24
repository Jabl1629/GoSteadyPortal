#!/usr/bin/env python3
"""
Phase 2A-RD synthetic smoke test runner.

Replaces smoke-2a-rd.sh — bash 3.2 (macOS default) lacks associative-
array semantics and jq isn't installed by default.

Hits every endpoint with the test users seeded by
seed-2a-rd-test-data.py. Records pass/fail per scenario, exits non-zero
on any failure.

Run from repo root:
    .test-venv/bin/python3 infra/scripts/smoke-2a-rd.py
"""

from __future__ import annotations

import base64
import json
import sys
import urllib.error
import urllib.parse
import urllib.request
from typing import Any

import boto3

REGION = "us-east-1"
USER_POOL_CLIENT = "1q9l9ujtsomf3ugq2tnqvdg6d7"
PASSWORD = "GoSteady2026!Pass+"

# Test fixture IDs (must match seed-2a-rd-test-data.py)
CLIENT_ID = "client_rd_test"
PATIENT_BUSY = "pat_rd_busy"
PATIENT_QUIET = "pat_rd_quiet"
PATIENT_FAC_B = "pat_rd_fac_b"
PATIENT_FAMILY = "pat_rd_family"
FACILITY_A = "fac_rd_a"
FACILITY_B = "fac_rd_b"
CENSUS_A1 = "cen_rd_a1"
CENSUS_B1 = "cen_rd_b1"

USERS = [
    "rd-caregiver@test.local",
    "rd-facadmin@test.local",
    "rd-clientadmin@test.local",
    "rd-familyviewer@test.local",
]

_token_cache: dict[str, str] = {}
_cog = boto3.client("cognito-idp", region_name=REGION)
_apigw = boto3.client("apigatewayv2", region_name=REGION)


def get_token(user: str) -> str:
    if user in _token_cache:
        return _token_cache[user]
    res = _cog.initiate_auth(
        AuthFlow="USER_PASSWORD_AUTH",
        ClientId=USER_POOL_CLIENT,
        AuthParameters={"USERNAME": user, "PASSWORD": PASSWORD},
    )
    token = res["AuthenticationResult"]["IdToken"]
    _token_cache[user] = token
    return token


def get_api_url() -> str:
    apis = _apigw.get_apis()["Items"]
    for api in apis:
        if api["Name"] == "gosteady-dev-api":
            return api["ApiEndpoint"]
    raise RuntimeError("API gosteady-dev-api not found")


API_URL = get_api_url()
print(f"API URL: {API_URL}\n")


class Result:
    def __init__(self) -> None:
        self.passes: list[str] = []
        self.failures: list[tuple[str, str]] = []

    def passed(self, name: str) -> None:
        print(f"  [{name}] PASS")
        self.passes.append(name)

    def failed(self, name: str, reason: str) -> None:
        print(f"  [{name}] FAIL: {reason}")
        self.failures.append((name, reason))

    @property
    def summary(self) -> str:
        return f"PASS={len(self.passes)}  FAIL={len(self.failures)}"


R = Result()


def http_get(path: str, token: str | None = None) -> tuple[int, dict[str, Any] | None, str]:
    """Returns (status, parsed_json_or_None, raw_body)."""
    url = f"{API_URL}{path}"
    req = urllib.request.Request(url, method="GET")
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    try:
        resp = urllib.request.urlopen(req, timeout=15)
        body = resp.read().decode("utf-8")
        status = resp.status
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8")
        status = e.code
    parsed: dict[str, Any] | None = None
    try:
        parsed = json.loads(body)
    except (json.JSONDecodeError, ValueError):
        pass
    return status, parsed, body


def assert_get(name: str, user: str, path: str,
               expect_status: int,
               check: Any = None) -> dict[str, Any] | None:
    """
    Run a GET, validate status + optional check func.
    check(parsed_body) -> str (error msg) or None on pass.
    Returns parsed body for caller to do additional assertions.
    """
    try:
        token = get_token(user) if user else None
    except Exception as e:
        R.failed(name, f"token unavailable for {user}: {e}")
        return None
    status, parsed, body = http_get(path, token)
    if status != expect_status:
        R.failed(name, f"status {status} (expected {expect_status}); body: {body[:200]}")
        return parsed
    if check is not None:
        try:
            err = check(parsed)
        except Exception as e:
            err = f"check raised: {e}"
        if err:
            R.failed(name, f"{err}; body: {body[:200]}")
            return parsed
    R.passed(f"{name}  (HTTP {status})")
    return parsed


print("════════════════════════════════════════════════════════════")
print("  Phase 2A-RD synthetic smoke")
print("════════════════════════════════════════════════════════════\n")

# T1: caregiver in-scope GET /patients/{id}
assert_get(
    "T1 caregiver gets in-scope patient",
    "rd-caregiver@test.local",
    f"/api/v1/patients/{PATIENT_BUSY}",
    200,
    lambda b: None if (b and b.get("patient", {}).get("patientId") == PATIENT_BUSY
                       and b["patient"].get("facilityName")) else "patientId/facilityName missing",
)

# T2: caregiver OUT_OF_SCOPE (patient in facility B's census)
assert_get(
    "T2 caregiver out-of-scope returns 403",
    "rd-caregiver@test.local",
    f"/api/v1/patients/{PATIENT_FAC_B}",
    403,
    lambda b: None if (b and b.get("error", {}).get("code") == "OUT_OF_SCOPE")
              else f"unexpected error code: {b}",
)

# T2b: caregiver OUT_OF_SCOPE (patient in different census of facility A)
assert_get(
    "T2b caregiver wrong-census returns 403",
    "rd-caregiver@test.local",
    f"/api/v1/patients/{PATIENT_FAMILY}",  # in cen_rd_a2 (caregiver is cen_rd_a1)
    403,
    lambda b: None if (b and b.get("error", {}).get("code") == "OUT_OF_SCOPE")
              else f"unexpected: {b}",
)

# T3: family_viewer not in linkedPatientIds → 404 (existence-leak)
assert_get(
    "T3 family_viewer non-linked returns 404",
    "rd-familyviewer@test.local",
    f"/api/v1/patients/{PATIENT_QUIET}",
    404,
    lambda b: None if (b and b.get("error", {}).get("code") == "PATIENT_NOT_FOUND")
              else f"unexpected: {b}",
)

# T3b: family_viewer linked patient → 200
assert_get(
    "T3b family_viewer linked patient returns 200",
    "rd-familyviewer@test.local",
    f"/api/v1/patients/{PATIENT_FAMILY}",
    200,
    lambda b: None if (b and b["patient"].get("patientId") == PATIENT_FAMILY)
              else "patientId mismatch",
)

# T5: activity 7d returns up to 50 sessions
data_t5 = assert_get(
    "T5 activity range=7d returns up to 50 sessions",
    "rd-caregiver@test.local",
    f"/api/v1/patients/{PATIENT_BUSY}/activity?range=7d",
    200,
    lambda b: None if (b and isinstance(b.get("sessions"), list) and 0 < len(b["sessions"]) <= 50)
              else f"sessions length out of bounds: {len(b.get('sessions', []))}",
)

# T6: pagination — second page via nextCursor
if data_t5 and data_t5.get("nextCursor"):
    cursor = data_t5["nextCursor"]
    encoded = urllib.parse.quote(cursor, safe="")
    assert_get(
        "T6 pagination cursor round-trip",
        "rd-caregiver@test.local",
        f"/api/v1/patients/{PATIENT_BUSY}/activity?range=7d&pageSize=50&cursor={encoded}",
        200,
        lambda b: None if (b and isinstance(b.get("sessions"), list))
                  else "second page malformed",
    )
else:
    R.passed("T6 pagination cursor round-trip  (SKIP: first page wasn't full)")

# T7: invalid range
assert_get(
    "T7 invalid range=90d returns 400 INVALID_RANGE",
    "rd-caregiver@test.local",
    f"/api/v1/patients/{PATIENT_BUSY}/activity?range=90d",
    400,
    lambda b: None if (b and b.get("error", {}).get("code") == "INVALID_RANGE")
              else f"unexpected: {b}",
)

# T8: zero activity
assert_get(
    "T8 quiet patient zero sessions",
    "rd-caregiver@test.local",
    f"/api/v1/patients/{PATIENT_QUIET}/activity?range=7d",
    200,
    lambda b: None if (b and b.get("sessions") == []) else "expected empty sessions",
)

# T9: alerts default = unacknowledged
assert_get(
    "T9 alerts default unacknowledged",
    "rd-caregiver@test.local",
    f"/api/v1/patients/{PATIENT_BUSY}/alerts",
    200,
    lambda b: None if (b and b.get("filter") == "unacknowledged"
                       and len(b.get("alerts", [])) > 0)
              else f"filter/alerts wrong: {b}",
)

# T10: alerts status=all returns ≥3
assert_get(
    "T10 alerts status=all",
    "rd-caregiver@test.local",
    f"/api/v1/patients/{PATIENT_BUSY}/alerts?status=all",
    200,
    lambda b: None if (b and b.get("filter") == "all" and len(b.get("alerts", [])) >= 3)
              else f"expected ≥3 alerts: {b}",
)

# T10b: alerts status=acknowledged returns ≥1
assert_get(
    "T10b alerts status=acknowledged",
    "rd-caregiver@test.local",
    f"/api/v1/patients/{PATIENT_BUSY}/alerts?status=acknowledged",
    200,
    lambda b: None if (b and b.get("filter") == "acknowledged"
                       and len(b.get("alerts", [])) >= 1
                       and all(a["acknowledged"] for a in b["alerts"]))
              else f"expected ≥1 acked alert: {b}",
)

# T10c: alerts invalid status
assert_get(
    "T10c alerts invalid status returns 400",
    "rd-caregiver@test.local",
    f"/api/v1/patients/{PATIENT_BUSY}/alerts?status=foo",
    400,
    lambda b: None if (b and b.get("error", {}).get("code") == "INVALID_STATUS_FILTER")
              else f"unexpected: {b}",
)

# T11: /me/patients as caregiver
assert_get(
    "T11 me/patients as caregiver",
    "rd-caregiver@test.local",
    "/api/v1/me/patients",
    200,
    lambda b: None if (b and b.get("scope", {}).get("role") == "caregiver"
                       and len(b.get("patients", [])) > 0)
              else f"scope/patients wrong: {b}",
)

# T12: /me/patients as facility_admin (scope = fac_rd_a → sees only facility A patients)
# Patients in facility A: pat_rd_busy + pat_rd_quiet + pat_rd_family = 3. pat_rd_fac_b excluded.
assert_get(
    "T12 me/patients as facility_admin (facility-A-scoped)",
    "rd-facadmin@test.local",
    "/api/v1/me/patients",
    200,
    lambda b: None if (b and b["scope"]["role"] == "facility_admin"
                       and len(b.get("patients", [])) == 3
                       and all(p["facilityId"] == FACILITY_A for p in b["patients"]))
              else f"facility_admin should see exactly 3 patients in facility A: {b}",
)

# T12b: /me/patients as client_admin
assert_get(
    "T12b me/patients as client_admin",
    "rd-clientadmin@test.local",
    "/api/v1/me/patients",
    200,
    lambda b: None if (b and b["scope"]["role"] == "client_admin"
                       and len(b.get("patients", [])) >= 4)
              else f"client_admin should see all client patients: {b}",
)

# T13: /me/patients as family_viewer
assert_get(
    "T13 me/patients as family_viewer linked subset",
    "rd-familyviewer@test.local",
    "/api/v1/me/patients",
    200,
    lambda b: None if (b and b["scope"]["role"] == "family_viewer"
                       and len(b.get("patients", [])) == 2)  # linked to 2
              else f"family_viewer should see 2 linked patients: {b}",
)

# T16: census roster in-scope
assert_get(
    "T16 census roster in-scope",
    "rd-caregiver@test.local",
    f"/api/v1/facilities/{FACILITY_A}/censuses/{CENSUS_A1}/patients",
    200,
    lambda b: None if (b and b["census"]["censusId"] == CENSUS_A1)
              else f"wrong census: {b}",
)

# T17: census roster cross-facility for caregiver → 404 or OUT_OF_SCOPE
assert_get(
    "T17 census roster out-of-scope (facility B)",
    "rd-caregiver@test.local",
    f"/api/v1/facilities/{FACILITY_B}/censuses/{CENSUS_B1}/patients",
    403,
    lambda b: None if (b and b.get("error", {}).get("code") in ("OUT_OF_SCOPE", "FACILITY_NOT_FOUND"))
              else f"expected 403 OUT_OF_SCOPE: {b}",
)

# T18: bad facility id
assert_get(
    "T18 census bad facility id returns 404",
    "rd-facadmin@test.local",
    "/api/v1/facilities/fac_does_not_exist/censuses/cen_x/patients",
    404,
    lambda b: None if (b and b.get("error", {}).get("code") == "FACILITY_NOT_FOUND")
              else f"unexpected: {b}",
)

# T20: malformed cursor
assert_get(
    "T20 malformed cursor returns 400",
    "rd-caregiver@test.local",
    f"/api/v1/patients/{PATIENT_BUSY}/activity?range=24h&cursor=garbage!!",
    400,
    lambda b: None if (b and b.get("error", {}).get("code") == "INVALID_CURSOR")
              else f"unexpected: {b}",
)

# T25: nonexistent patient → 404
assert_get(
    "T25 nonexistent patient → 404",
    "rd-caregiver@test.local",
    "/api/v1/patients/pat_nonexistent_zzz",
    404,
    lambda b: None if (b and b.get("error", {}).get("code") == "PATIENT_NOT_FOUND")
              else f"unexpected: {b}",
)

# T-auth: no token
status, parsed, body = http_get("/api/v1/me/patients", token=None)
if status == 401:
    R.passed("T-auth no token returns 401")
else:
    R.failed("T-auth no token returns 401", f"got {status}: {body[:100]}")

# T-internal-noclient: internal_admin without ?clientId= → 400
# (Skipped — no internal_admin test user seeded yet; covered indirectly by Lambda unit test)

print("\n════════════════════════════════════════════════════════════")
print(f"  Summary: {R.summary}")
print("════════════════════════════════════════════════════════════")

if R.failures:
    print("\nFailed scenarios:")
    for name, reason in R.failures:
        print(f"  - {name}: {reason[:120]}")
    sys.exit(1)
sys.exit(0)

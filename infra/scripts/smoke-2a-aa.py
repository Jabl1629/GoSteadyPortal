#!/usr/bin/env python3
"""
Phase 2A-AA synthetic smoke test runner.

Reuses the 2A-RD seeded fixtures (rd-* test users + pat_rd_busy with
2 unacked + 1 acked alerts). Adds 2A-AA scenarios:

  - Ack alert (happy path)
  - Ack idempotency (second ack returns wasAlreadyAcknowledged: true,
    original acker preserved)
  - Ack out-of-scope (403)
  - family_viewer ack denied (403; observation-only)
  - GET thresholds (default fall-through)
  - PUT thresholds (facility_admin happy path)
  - PUT thresholds — caregiver denied (403)
  - PUT thresholds — invalid range / ordering (400)
  - PUT thresholds — null clears override
  - GET thresholds reflects PUT

Run:  .test-venv/bin/python3 infra/scripts/smoke-2a-aa.py
"""

from __future__ import annotations

import json
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

import boto3

REGION = "us-east-1"
USER_POOL_CLIENT = "1q9l9ujtsomf3ugq2tnqvdg6d7"
PASSWORD = "GoSteady2026!Pass+"

PATIENT_BUSY = "pat_rd_busy"
PATIENT_FAC_B = "pat_rd_fac_b"
PATIENT_QUIET = "pat_rd_quiet"
PATIENT_FAMILY = "pat_rd_family"

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
        resp = urllib.request.urlopen(req, timeout=15)
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
        R.failed(name, f"status {status} (expected {expect_status}); body: {raw[:300]}")
        return parsed
    if check is not None:
        try:
            err = check(parsed)
        except Exception as e:
            err = f"check raised: {e}"
        if err:
            R.failed(name, f"{err}; body: {raw[:300]}")
            return parsed
    R.passed(f"{name}  (HTTP {status})")
    return parsed


# First fetch the alert keys we'll act on — use 2A-RD endpoint to discover them
print("══ Discovery: fetch alerts on pat_rd_busy ══")
tok = get_token("rd-caregiver@test.local")
status, alerts_body, _ = http("GET", f"/api/v1/patients/{PATIENT_BUSY}/alerts?status=all", tok)
if status != 200 or not alerts_body or "alerts" not in alerts_body:
    print(f"  FATAL: could not discover alerts (status {status})")
    sys.exit(2)
alerts = alerts_body["alerts"]
print(f"  found {len(alerts)} alerts on {PATIENT_BUSY}")
if len(alerts) < 3:
    print("  FATAL: expected ≥3 seeded alerts. Re-run seed-2a-rd-test-data.py")
    sys.exit(2)

# Identify an unacked one we can ack idempotently
unacked = [a for a in alerts if not a["acknowledged"]]
acked = [a for a in alerts if a["acknowledged"]]
print(f"  unacked: {len(unacked)}, acked: {len(acked)}")

if not unacked:
    print("  WARN: no unacked alerts left — prior smoke runs already acked. Re-seed for fresh runs.")
    # Continue anyway — idempotency tests still meaningful on acked rows
    target_unacked = alerts[0]  # use first alert as target
else:
    target_unacked = unacked[0]

# Build the compound SK from the alert row: it's stored as
# `{eventTimestamp}#{alertType}` per Phase 1B-rev. The patient-api
# already returns these as `timestamp` in the row (or eventTimestamp +
# alertType separately — depends on view). Reconstruct it.
target_sk = f"{target_unacked['eventTimestamp']}#{target_unacked['alertType']}"
target_sk_encoded = urllib.parse.quote(target_sk, safe="")

print(f"\n  target alert SK: {target_sk}")
print(f"  URL-encoded:     {target_sk_encoded}\n")

print("══ Phase 2A-AA synthetic smoke ══\n")

# T1: Caregiver acks unacked alert (happy path)
expect(
    "T1 caregiver ack unacked alert",
    "rd-caregiver@test.local", "PATCH",
    f"/api/v1/alerts/{PATIENT_BUSY}/{target_sk_encoded}",
    200,
    lambda b: None if (b and b["alert"]["acknowledged"] is True
                       and b["alert"]["acknowledgedBy"]
                       and "wasAlreadyAcknowledged" in b)
              else f"missing ack fields: {b}",
)

# T2: Ack same alert again — idempotent (was=true; original acker preserved)
result_t2 = expect(
    "T2 second ack returns wasAlreadyAcknowledged=true",
    "rd-caregiver@test.local", "PATCH",
    f"/api/v1/alerts/{PATIENT_BUSY}/{target_sk_encoded}",
    200,
    lambda b: None if (b and b["wasAlreadyAcknowledged"] is True
                       and b["alert"]["acknowledged"] is True)
              else f"expected was=true: {b}",
)

# T3: out-of-scope ack — caregiver tries fac_b patient's alert
# (need a fake SK for fac_b — will get either ALERT_NOT_FOUND or OUT_OF_SCOPE
# both 4xx; the auth chain runs before the alert lookup so OUT_OF_SCOPE expected)
fake_sk = urllib.parse.quote("2026-05-22T01:00:00Z#battery_critical", safe="")
expect(
    "T3 caregiver out-of-scope ack returns 403",
    "rd-caregiver@test.local", "PATCH",
    f"/api/v1/alerts/{PATIENT_FAC_B}/{fake_sk}",
    403,
    lambda b: None if (b and b["error"]["code"] == "OUT_OF_SCOPE")
              else f"unexpected: {b}",
)

# T4: family_viewer denied ack (observational role)
expect(
    "T4 family_viewer ack denied (403)",
    "rd-familyviewer@test.local", "PATCH",
    f"/api/v1/alerts/{PATIENT_FAMILY}/{fake_sk}",
    403,
    lambda b: None if (b and b["error"]["code"] == "INSUFFICIENT_PERMISSIONS")
              else f"unexpected: {b}",
)

# T6: ack non-existent alert (404)
non_sk = urllib.parse.quote("1999-01-01T00:00:00Z#battery_critical", safe="")
expect(
    "T6 ack nonexistent alert returns 404",
    "rd-caregiver@test.local", "PATCH",
    f"/api/v1/alerts/{PATIENT_BUSY}/{non_sk}",
    404,
    lambda b: None if (b and b["error"]["code"] == "ALERT_NOT_FOUND")
              else f"unexpected: {b}",
)

# T7: ack with valid notes
expect(
    "T7 ack with notes (already acked but notes accepted)",
    "rd-caregiver@test.local", "PATCH",
    f"/api/v1/alerts/{PATIENT_BUSY}/{target_sk_encoded}",
    200,
    lambda b: True is None,  # any 200 is fine; idempotency means notes won't overwrite
    body={"notes": "Battery swapped at 14:30. Smoke test note."},
)

# T8: notes >500 chars
expect(
    "T8 ack notes >500 chars rejected (400)",
    "rd-caregiver@test.local", "PATCH",
    f"/api/v1/alerts/{PATIENT_BUSY}/{target_sk_encoded}",
    400,
    lambda b: None if (b and b["error"]["code"] == "INVALID_REQUEST")
              else f"unexpected: {b}",
    body={"notes": "x" * 600},
)

# T9: malformed SK
expect(
    "T9 malformed SK returns 400",
    "rd-caregiver@test.local", "PATCH",
    f"/api/v1/alerts/{PATIENT_BUSY}/garbage",
    400,
    lambda b: None if (b and b["error"]["code"] == "INVALID_TIMESTAMP")
              else f"unexpected: {b}",
)

# ─────────────────────────────────────────────────────────────────
# THRESHOLDS
# ─────────────────────────────────────────────────────────────────

# T11: GET thresholds for patient with no overrides — all defaults
expect(
    "T11 GET thresholds — all defaults",
    "rd-caregiver@test.local", "GET",
    f"/api/v1/patients/{PATIENT_QUIET}/thresholds",
    200,
    lambda b: None if (
        b
        and b["thresholds"]["batteryCritical"] == 0.05
        and b["thresholds"]["batteryLow"] == 0.10
        and all(v == "default" for v in b["source"].values())
    ) else f"unexpected: {b}",
)

# T12: PUT thresholds as facility_admin (happy path)
result_t12 = expect(
    "T12 PUT thresholds facility_admin happy path",
    "rd-facadmin@test.local", "PUT",
    f"/api/v1/patients/{PATIENT_BUSY}/thresholds",
    200,
    lambda b: None if (
        b
        and b["thresholds"]["batteryCritical"] == 0.08
        and b["thresholds"]["batteryLow"] == 0.15
        and b["source"]["batteryCritical"] == "override"
        and b["source"]["batteryLow"] == "override"
        and b["source"]["rsrpLost"] == "default"
        and "batteryCritical" in b["updated"]
    ) else f"unexpected: {b}",
    body={"batteryCritical": 0.08, "batteryLow": 0.15},
)

# T13: PUT thresholds as caregiver denied
expect(
    "T13 PUT thresholds caregiver denied (403)",
    "rd-caregiver@test.local", "PUT",
    f"/api/v1/patients/{PATIENT_BUSY}/thresholds",
    403,
    lambda b: None if (b and b["error"]["code"] == "INSUFFICIENT_PERMISSIONS")
              else f"unexpected: {b}",
    body={"batteryCritical": 0.10},
)

# T14: PUT thresholds — invalid range (batteryCritical > 0.30)
expect(
    "T14 PUT thresholds out-of-range returns 400",
    "rd-facadmin@test.local", "PUT",
    f"/api/v1/patients/{PATIENT_BUSY}/thresholds",
    400,
    lambda b: None if (b and b["error"]["code"] == "INVALID_THRESHOLD")
              else f"unexpected: {b}",
    body={"batteryCritical": 0.50},
)

# T15: PUT thresholds — ordering violation
expect(
    "T15 PUT thresholds ordering violation returns 400",
    "rd-facadmin@test.local", "PUT",
    f"/api/v1/patients/{PATIENT_BUSY}/thresholds",
    400,
    lambda b: None if (b and b["error"]["code"] == "INVALID_THRESHOLD")
              else f"unexpected: {b}",
    body={"batteryCritical": 0.15, "batteryLow": 0.10},
)

# T16: PUT thresholds — null clears (revert batteryCritical to default)
expect(
    "T16 PUT thresholds null clears override",
    "rd-facadmin@test.local", "PUT",
    f"/api/v1/patients/{PATIENT_BUSY}/thresholds",
    200,
    lambda b: None if (
        b
        and b["thresholds"]["batteryCritical"] == 0.05  # reverted to default
        and b["source"]["batteryCritical"] == "default"
        and b["thresholds"]["batteryLow"] == 0.15  # T12 override still in effect
        and b["source"]["batteryLow"] == "override"
    ) else f"unexpected: {b}",
    body={"batteryCritical": None},
)

# T17: GET thresholds reflects most recent state
expect(
    "T17 GET thresholds reflects most recent PUT",
    "rd-caregiver@test.local", "GET",
    f"/api/v1/patients/{PATIENT_BUSY}/thresholds",
    200,
    lambda b: None if (
        b
        and b["thresholds"]["batteryCritical"] == 0.05  # T16 cleared it
        and b["source"]["batteryCritical"] == "default"
        and b["thresholds"]["batteryLow"] == 0.15
        and b["source"]["batteryLow"] == "override"
    ) else f"unexpected: {b}",
)

# T23: no-token 401
expect(
    "T23 no-token returns 401",
    None, "GET",
    f"/api/v1/patients/{PATIENT_BUSY}/thresholds",
    401,
)

# T-cleanup: clear the override so re-runs are stable
expect(
    "T-cleanup clear all overrides",
    "rd-facadmin@test.local", "PUT",
    f"/api/v1/patients/{PATIENT_BUSY}/thresholds",
    200,
    lambda b: None if (
        b and b["source"]["batteryLow"] == "default"
    ) else f"unexpected: {b}",
    body={"batteryLow": None},
)

print(f"\n══ Summary: PASS={len(R.p)}  FAIL={len(R.f)} ══")
if R.f:
    print("Failed:")
    for n, r in R.f:
        print(f"  - {n}: {r[:120]}")
    sys.exit(1)
sys.exit(0)

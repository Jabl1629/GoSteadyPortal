#!/usr/bin/env python3
"""
Live synthetic-JWT E2E for the walker-only alert read filter (walker-alert-
suppression) against a DEPLOYED patient-api. Invokes the Lambda with crafted
D2C authorizer claims — walker (custom:isWalkerUser="true") vs caregiver
("false") — for a real patient that has BOTH activity-judgment and device-health
alerts, and asserts the walker sees only device-health while the caregiver sees
everything.

Read-only: no writes, no seeding, no cleanup. Mirrors the synthetic-JWT E2E
pattern of e2e-care-circle.py (lambda-invoke with crafted claims).

Usage:
    cd infra/lambda        # or repo root — only needs boto3 + AWS creds
    ../../.test-venv/bin/python ../scripts/e2e-walker-alerts.py \
        [--env dev] [--patient pat_d2c_...] [--walker-sub <sub>] [--client dtc_...]

Requires: AWS creds for the target account; a patient whose Alert History holds
at least one behavioral (no_activity_today / below_typical_activity /
declining_trend) AND one non-behavioral (e.g. device_offline) alert.
Defaults target the dev fixture walker.
"""
from __future__ import annotations

import argparse
import collections
import json
import time

import boto3

HIDDEN = {"no_activity_today", "below_typical_activity", "declining_trend"}

# Dev fixture: the D2C walker household used across the D2C E2Es.
DEFAULTS = {
    "env": "dev",
    "patient": "pat_d2c_10eafcc2ca5d49fb",
    "client": "dtc_51eecfe161444f009b15",
    "walker_sub": "14580438-a041-704f-61ff-88fae803619e",
}


def event(patient: str, client: str, is_walker: str, sub: str) -> dict:
    return {
        "routeKey": "GET /api/v1/d2c/patients/{id}/alerts",
        "rawPath": f"/api/v1/d2c/patients/{patient}/alerts",
        "pathParameters": {"id": patient},
        "queryStringParameters": {"status": "all"},
        "requestContext": {
            "http": {"method": "GET", "path": f"/api/v1/d2c/patients/{patient}/alerts"},
            "requestId": f"e2e-walker-alerts-{is_walker}",
            "authorizer": {"jwt": {"claims": {
                "sub": sub,
                "custom:clientId": client,
                "custom:role": "household_owner",
                "custom:isWalkerUser": is_walker,
                "custom:facilities": "",
                "custom:censuses": "",
                "iat": int(time.time()),
            }}},
        },
    }


def invoke(client_lambda, fn: str, patient: str, client: str, is_walker: str, sub: str):
    resp = client_lambda.invoke(
        FunctionName=fn,
        Payload=json.dumps(event(patient, client, is_walker, sub)).encode(),
    )
    payload = json.loads(resp["Payload"].read())
    body = json.loads(payload.get("body", "{}"))
    types = [a.get("alertType") for a in body.get("alerts", [])]
    return payload.get("statusCode"), types, body


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--env", default=DEFAULTS["env"])
    ap.add_argument("--patient", default=DEFAULTS["patient"])
    ap.add_argument("--client", default=DEFAULTS["client"])
    ap.add_argument("--walker-sub", default=DEFAULTS["walker_sub"])
    ap.add_argument("--region", default="us-east-1")
    args = ap.parse_args()

    fn = f"gosteady-{args.env}-patient-api"
    lam = boto3.client("lambda", region_name=args.region)
    print(f"Invoking {fn} for patient {args.patient} …\n")

    wc, wtypes, wbody = invoke(lam, fn, args.patient, args.client, "true", args.walker_sub)
    cc, ctypes, cbody = invoke(lam, fn, args.patient, args.client, "false", "caregiver-sub-e2e")

    print(f"WALKER    → HTTP {wc}, {len(wtypes)} alerts: {dict(collections.Counter(wtypes))}")
    print(f"CAREGIVER → HTTP {cc}, {len(ctypes)} alerts: {dict(collections.Counter(ctypes))}")
    if wc != 200 or cc != 200:
        print("body(walker):", json.dumps(wbody)[:400])
        print("body(caregiver):", json.dumps(cbody)[:400])

    # Preflight: the fixture must actually exercise both categories, else the
    # test is vacuously green and proves nothing.
    caregiver_activity = HIDDEN & set(ctypes)
    caregiver_device = set(ctypes) - HIDDEN
    if not caregiver_activity or not caregiver_device:
        print("\n⚠️  FIXTURE INSUFFICIENT — the caregiver view must contain at least one "
              "activity-judgment AND one device-health alert for this test to be meaningful.")
        return 2

    checks = [
        ("both 200", wc == 200 and cc == 200),
        ("caregiver sees activity alerts", bool(caregiver_activity)),
        ("caregiver sees device-health alerts", bool(caregiver_device)),
        ("walker sees NO activity alerts", not (HIDDEN & set(wtypes))),
        ("walker STILL sees device-health alerts", bool(set(wtypes) & caregiver_device)),
        ("walker set == caregiver set minus activity", set(wtypes) == caregiver_device),
    ]
    print()
    ok = True
    for name, passed in checks:
        print(f"  [{'PASS' if passed else 'FAIL'}] {name}")
        ok = ok and passed
    print("\n=== " + ("ALL PASS ✅" if ok else "FAILURES ❌") + " ===")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())

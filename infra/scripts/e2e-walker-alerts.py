#!/usr/bin/env python3
"""
Live E2E for the D2C walker-alert allow-list (walker-alert-suppression, 2026-07-20
refinement): a walker/device user sees ONLY battery alerts about themselves;
everything else (activity-judgment, signal, offline, safety) is the caregiver's
concern and is hidden from the walker's own view. Non-walker caregivers see all.

Self-seeding: writes 4 sentinel-dated test alerts (one per category) to the
patient's Alert History, invokes the deployed patient-api as walker vs caregiver
via crafted D2C authorizer claims, asserts, then deletes the seeds. Safe to
re-run. Mirrors the synthetic-JWT pattern of e2e-care-circle.py.

Usage:
    ../../.test-venv/bin/python ../scripts/e2e-walker-alerts.py \
        [--env dev] [--patient pat_d2c_...] [--walker-sub <cognitoUserId>]
Requires AWS creds for the target account; the patient's clientId / facilityId /
censusId are read from its row. Defaults target the dev fixture walker.
"""
from __future__ import annotations

import argparse
import json
import time

import boto3

TEST_TS = "2020-01-01T00:00:00+00:00"  # sentinel date so seeds are identifiable
# (alertType, severity, source) — one per category the detectors emit.
SEEDS = [
    ("no_activity_today", "standard", "cloud-behavioral"),  # activity → hidden
    ("signal_lost", "warning", "cloud"),                    # signal   → hidden
    ("device_offline", "warning", "cloud-offline"),         # offline  → hidden
    ("battery_low", "warning", "cloud"),                    # BATTERY  → visible
]
DEFAULTS = {
    "env": "dev",
    "patient": "pat_d2c_10eafcc2ca5d49fb",
    "walker_sub": "14580438-a041-704f-61ff-88fae803619e",
}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--env", default=DEFAULTS["env"])
    ap.add_argument("--patient", default=DEFAULTS["patient"])
    ap.add_argument("--walker-sub", default=DEFAULTS["walker_sub"])
    ap.add_argument("--region", default="us-east-1")
    args = ap.parse_args()

    fn = f"gosteady-{args.env}-patient-api"
    alerts_tbl = f"gosteady-{args.env}-alerts"
    lam = boto3.client("lambda", region_name=args.region)
    ddb = boto3.client("dynamodb", region_name=args.region)

    p = ddb.get_item(TableName=f"gosteady-{args.env}-patients",
                     Key={"patientId": {"S": args.patient}}).get("Item")
    if not p:
        print(f"patient {args.patient} not found in {args.env}")
        return 2
    client = p["clientId"]["S"]
    facility = p.get("facilityId", {}).get("S", "")
    census = p.get("censusId", {}).get("S", "")

    for atype, sev, src in SEEDS:
        ddb.put_item(TableName=alerts_tbl, Item={
            "patientId": {"S": args.patient}, "timestamp": {"S": f"{TEST_TS}#{atype}"},
            "eventTimestamp": {"S": TEST_TS}, "alertType": {"S": atype},
            "severity": {"S": sev}, "source": {"S": src}, "acknowledged": {"BOOL": False},
            "clientId": {"S": client}, "facilityId": {"S": facility},
            "censusId": {"S": census}, "deviceSerial": {"S": "E2E-TEST"},
        })

    def seeded(is_walker: str, sub: str) -> set[str]:
        ev = {"routeKey": "GET /api/v1/d2c/patients/{id}/alerts",
              "pathParameters": {"id": args.patient},
              "queryStringParameters": {"status": "all"},
              "requestContext": {"http": {"method": "GET"}, "requestId": "e2e-walker-alerts",
                "authorizer": {"jwt": {"claims": {"sub": sub, "custom:clientId": client,
                  "custom:role": "household_owner", "custom:isWalkerUser": is_walker,
                  "custom:facilities": "", "custom:censuses": "", "iat": int(time.time())}}}}}
        r = lam.invoke(FunctionName=fn, Payload=json.dumps(ev).encode())
        body = json.loads(json.loads(r["Payload"].read()).get("body", "{}"))
        return {a["alertType"] for a in body.get("alerts", [])
                if a.get("eventTimestamp") == TEST_TS}

    try:
        walker = seeded("true", args.walker_sub)
        caregiver = seeded("false", "caregiver-sub-e2e")
        print(f"WALKER    sees: {sorted(walker)}")
        print(f"CAREGIVER sees: {sorted(caregiver)}\n")
        checks = [
            ("walker sees ONLY battery", walker == {"battery_low"}),
            ("walker: signal hidden", "signal_lost" not in walker),
            ("walker: offline hidden", "device_offline" not in walker),
            ("walker: activity hidden", "no_activity_today" not in walker),
            ("caregiver sees all 4 categories",
             caregiver == {a for a, _, _ in SEEDS}),
        ]
        ok = True
        for name, passed in checks:
            print(f"  [{'PASS' if passed else 'FAIL'}] {name}")
            ok = ok and passed
        print("\n=== " + ("ALL PASS ✅" if ok else "FAILURES ❌") + " ===")
        return 0 if ok else 1
    finally:
        for atype, _, _ in SEEDS:
            ddb.delete_item(TableName=alerts_tbl, Key={
                "patientId": {"S": args.patient}, "timestamp": {"S": f"{TEST_TS}#{atype}"}})


if __name__ == "__main__":
    raise SystemExit(main())

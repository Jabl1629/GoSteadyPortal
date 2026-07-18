#!/usr/bin/env python3
"""
Live-dev check for the QR re-login recipients endpoint (d2c-qr-relogin).
Seeds a synthetic 2-member household + device, invokes the deployed d2c-claim
Lambda's GET .../recipients, asserts the masked list is correct and leaks no
raw phone/sub, then cleans up. Read-only — no SMS is sent (that's the
send/verify legs, which need a real Cognito user + phone = operator test).

Run:  python3 infra/scripts/verify-relogin-recipients.py
"""
from __future__ import annotations

import json
import sys
import uuid

import boto3

REGION = "us-east-1"
LAMBDA = "gosteady-dev-d2c-claim"
_lambda = boto3.client("lambda", region_name=REGION)
_ddb = boto3.resource("dynamodb", region_name=REGION)
devices = _ddb.Table("gosteady-dev-devices")
roles = _ddb.Table("gosteady-dev-role-assignments")

RUN = uuid.uuid4().hex[:8]
WID = str(uuid.uuid4())
SERIAL = "GS9999999978"
HH = f"dtc_relv{RUN}"
OWNER_PHONE = "+17205551466"
DAU_PHONE = "+14155559234"

PASS = 0
FAIL = 0


def check(name, cond, detail=""):
    global PASS, FAIL
    if cond:
        PASS += 1; print(f"  ✅ {name}")
    else:
        FAIL += 1; print(f"  ❌ {name}  {detail}")


def seed():
    devices.put_item(Item={"serialNumber": SERIAL, "walkerId": WID,
                           "owningClientId": HH, "status": "active_monitoring",
                           "deviceType": "rollator_platform"})
    roles.put_item(Item={"userId": f"relv-owner-{RUN}", "clientId": HH,
                         "role": "household_owner", "role_userId": f"household_owner#relv-owner-{RUN}",
                         "isWalkerUser": True, "phone": OWNER_PHONE, "displayName": "Owner"})
    roles.put_item(Item={"userId": f"relv-dau-{RUN}", "clientId": HH,
                         "role": "family_viewer", "role_userId": f"family_viewer#relv-dau-{RUN}",
                         "isWalkerUser": False, "phone": DAU_PHONE,
                         "relationship": "Daughter", "displayName": "Sarah"})


def cleanup():
    for uid in (f"relv-owner-{RUN}", f"relv-dau-{RUN}"):
        try: roles.delete_item(Key={"userId": uid})
        except Exception: pass
    try: devices.delete_item(Key={"serialNumber": SERIAL})
    except Exception: pass


def invoke_recipients(walker_id):
    event = {
        "routeKey": "GET /api/v1/public/walkers/{walkerId}/recipients",
        "rawPath": f"/api/v1/public/walkers/{walker_id}/recipients",
        "requestContext": {"requestId": "relv", "http": {"method": "GET"}},
        "pathParameters": {"walkerId": walker_id},
        "body": None,
    }
    r = _lambda.invoke(FunctionName=LAMBDA, Payload=json.dumps(event).encode())
    p = json.loads(r["Payload"].read())
    return p.get("statusCode"), json.loads(p.get("body") or "{}")


def main():
    print(f"— relogin recipients check (run {RUN}) —")
    seed()
    try:
        st, body = invoke_recipients(WID)
        recips = body.get("recipients", [])
        check("200 + two recipients", st == 200 and len(recips) == 2, f"{st} {body}")
        primary = [r for r in recips if r.get("isPrimary")]
        check("exactly one primary = registered user •••-1466",
              len(primary) == 1 and primary[0]["mask"] == "•••-1466"
              and primary[0]["label"] == "Registered user", f"{recips}")
        dau = [r for r in recips if r.get("label") == "Daughter"]
        check("daughter masked •••-9234", dau and dau[0]["mask"] == "•••-9234", f"{recips}")
        blob = json.dumps(body)
        check("no raw phone / sub leak",
              "7205551466" not in blob and "4155559234" not in blob
              and "relv-owner" not in blob, blob[:160])
        check("opaque 24-char recipientIds",
              all(len(r.get("recipientId", "")) == 24 for r in recips), f"{recips}")

        st2, body2 = invoke_recipients(str(uuid.uuid4()))
        check("unknown walker → neutral empty", st2 == 200 and body2.get("recipients") == [],
              f"{st2} {body2}")
    finally:
        cleanup()
    print(f"\n{PASS} passed, {FAIL} failed")
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""
Care Circle synthetic E2E against LIVE dev (d2c-care-circle.md §8).

Drives the deployed `care-circle`, `patient-api`, `alert-actions`, and
`d2c-claim` Lambdas via synthetic-JWT lambda.invoke events (the §C19 /
claim-binding E2E pattern) against the REAL dev DynamoDB tables + the
real claim-binding pepper. No SMS is ever sent: the invite row for the
accept leg is seeded directly (same shape as circle_logic.build_invite_item),
and the POST /invites cases exercised are exactly the ones that reject
BEFORE the SMS send (dedupe / NOT_A_MEMBER / NO_ACTIVE_WALKER). The
SMS leg itself is the operator's live-phone test.

Covers (spec §8): T2 T3 T4* T5 T6 T7 T8 T9 T10 + roster + last-admin +
instant-revoke. (*expiry variant covered in unit tests.)

Run:  python3 infra/scripts/e2e-care-circle.py   (needs boto3 + dev creds)
Cleanup is unconditional (finally-block) — reruns are safe.
"""

from __future__ import annotations

import hashlib
import hmac as hmac_mod
import json
import sys
import time
import uuid
from datetime import datetime, timedelta, timezone

import boto3

REGION = "us-east-1"
ENV = "dev"

LAMBDA_CARE_CIRCLE = f"gosteady-{ENV}-care-circle"
LAMBDA_PATIENT_API = f"gosteady-{ENV}-patient-api"
LAMBDA_ALERT_ACTIONS = f"gosteady-{ENV}-alert-actions"
LAMBDA_D2C_CLAIM = f"gosteady-{ENV}-d2c-claim"

T_INVITES = f"gosteady-{ENV}-care-invites"
T_ROLES = f"gosteady-{ENV}-role-assignments"
T_PATIENTS = f"gosteady-{ENV}-patients"
T_ALERTS = f"gosteady-{ENV}-alerts"
T_DEVICES = f"gosteady-{ENV}-devices"

PEPPER_SECRET = f"gosteady/{ENV}/claim-binding-pepper"

RUN = uuid.uuid4().hex[:8]
HH = f"dtc_e2ecc{RUN}"
FAC = f"fac_e2ecc{RUN}"
CEN = f"cen_e2ecc{RUN}"
PAT = f"pat_d2c_e2ecc_{RUN}"
OWNER_SUB = f"e2ecc-owner-{RUN}"
MEMBER_SUB = f"e2ecc-member-{RUN}"
OTHER_SUB = f"e2ecc-other-{RUN}"
EMPTY_OWNER_SUB = f"e2ecc-empty-{RUN}"
OWNER_PHONE = "+15125550001"
MEMBER_PHONE = "+15125550002"
WRONG_PHONE = "+15125550003"
OTHER_PHONE = "+15125550004"
WALKER_ID = str(uuid.uuid4())
SERIAL = "GS9999999979"  # synthetic test-range serial (E2E-only row)

_lambda = boto3.client("lambda", region_name=REGION)
_ddb = boto3.resource("dynamodb", region_name=REGION)
_sm = boto3.client("secretsmanager", region_name=REGION)

invites = _ddb.Table(T_INVITES)
roles = _ddb.Table(T_ROLES)
patients = _ddb.Table(T_PATIENTS)
alerts = _ddb.Table(T_ALERTS)
devices = _ddb.Table(T_DEVICES)

PASS = 0
FAIL = 0


def check(name: str, cond: bool, detail: str = "") -> None:
    global PASS, FAIL
    if cond:
        PASS += 1
        print(f"  ✅ {name}")
    else:
        FAIL += 1
        print(f"  ❌ {name}  {detail}")


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def hmac_phone(pepper: str, e164: str) -> str:
    return hmac_mod.new(pepper.encode(), e164.encode(), hashlib.sha256).hexdigest()


def claims(sub: str, *, role: str, client_id: str, phone: str | None,
           verified: str = "true", name: str = "E2E User") -> dict:
    c = {
        "sub": sub,
        "name": name,
        "custom:role": role,
        "custom:clientId": client_id,
        "custom:facilities": "",
        "custom:censuses": "",
        "iat": str(int(time.time())),
    }
    if phone is not None:
        c["phone_number"] = phone
        c["phone_number_verified"] = verified
    return c


def invoke(fn: str, route: str, cl: dict, *, params: dict | None = None,
           body: dict | None = None) -> tuple[int, dict]:
    method = route.split(" ", 1)[0]
    event = {
        "routeKey": route,
        "rawPath": route.split(" ", 1)[1],
        "requestContext": {
            "requestId": f"e2ecc-{uuid.uuid4().hex[:12]}",
            "http": {"method": method},
            "authorizer": {"jwt": {"claims": cl}},
        },
        "pathParameters": params or {},
        "queryStringParameters": {},
        "headers": {},
        "body": json.dumps(body) if body is not None else None,
    }
    resp = _lambda.invoke(FunctionName=fn, Payload=json.dumps(event).encode())
    payload = json.loads(resp["Payload"].read())
    status = payload.get("statusCode", 0)
    try:
        parsed = json.loads(payload.get("body") or "{}")
    except (ValueError, TypeError):
        parsed = {}
    return status, parsed


def err_code(body: dict) -> str:
    return ((body.get("error") or {}).get("code")) or ""


def seed() -> None:
    ts = now_iso()
    patients.put_item(Item={
        "patientId": PAT, "clientId": HH, "facilityId": FAC, "censusId": CEN,
        "displayName": "E2E Susan", "status": "active",
        "status_patientId": f"active_{PAT}", "isWalkerUser": True,
        "createdAt": ts, "createdBy": OWNER_SUB,
    })
    roles.put_item(Item={
        "userId": OWNER_SUB, "clientId": HH, "role": "household_owner",
        "role_userId": f"household_owner#{OWNER_SUB}", "isWalkerUser": False,
        "displayName": "E2E Sarah", "email": "", "phone": OWNER_PHONE,
        "validFrom": ts, "assignedBy": OWNER_SUB,
    })
    # Pre-existing owner of a DIFFERENT household (ALREADY_IN_HOUSEHOLD case).
    roles.put_item(Item={
        "userId": OTHER_SUB, "clientId": f"dtc_other{RUN}",
        "role": "household_owner",
        "role_userId": f"household_owner#{OTHER_SUB}", "isWalkerUser": True,
        "displayName": "E2E Other", "email": "", "phone": OTHER_PHONE,
        "validFrom": ts, "assignedBy": OTHER_SUB,
    })
    # Unclaimed synthetic device (MEMBER_CANNOT_CLAIM probe).
    devices.put_item(Item={
        "serialNumber": SERIAL, "walkerId": WALKER_ID,
        "status": "ready_to_provision", "deviceType": "walker_cap",
        "createdAt": ts,
    })
    # Open alert for the ack leg.
    alerts.put_item(Item={
        "patientId": PAT, "timestamp": f"{ts}#battery_low",
        "eventTimestamp": ts, "alertType": "battery_low",
        "severity": "warning", "source": "cloud", "clientId": HH,
    })


def seed_invite(pepper: str, *, phone: str, invite_id: str) -> dict:
    ts = datetime.now(timezone.utc)
    item = {
        "inviteId": invite_id,
        "clientId": HH,
        "patientIds": {PAT},
        "contactHash": hmac_phone(pepper, phone),
        "contactMask": f"•••-{phone[-4:]}",
        "contactE164": phone,
        "contactChannel": "phone",
        "displayName": "E2E Jane",
        "relationship": "Daughter",
        "role": "family_viewer",
        "isWalkerUser": False,
        "status": "pending",
        "invitedBy": OWNER_SUB,
        "inviterName": "E2E Sarah",
        "householdName": "E2E household",
        "walkerName": "E2E Susan",
        "createdAt": ts.isoformat().replace("+00:00", "Z"),
        "expiresAt": (ts + timedelta(days=14)).isoformat().replace("+00:00", "Z"),
        "ttl": int((ts + timedelta(days=104)).timestamp()),
    }
    invites.put_item(Item=item)
    return item


def cleanup() -> None:
    for key in ({"userId": OWNER_SUB}, {"userId": MEMBER_SUB},
                {"userId": OTHER_SUB}, {"userId": EMPTY_OWNER_SUB}):
        try:
            roles.delete_item(Key=key)
        except Exception:  # noqa: BLE001
            pass
    for tbl, key in ((patients, {"patientId": PAT}),
                     (devices, {"serialNumber": SERIAL})):
        try:
            tbl.delete_item(Key=key)
        except Exception:  # noqa: BLE001
            pass
    try:
        res = invites.query(IndexName="by-client",
                            KeyConditionExpression="clientId = :c",
                            ExpressionAttributeValues={":c": HH})
        for it in res.get("Items", []):
            invites.delete_item(Key={"inviteId": it["inviteId"]})
    except Exception:  # noqa: BLE001
        pass
    try:
        res = alerts.query(KeyConditionExpression="patientId = :p",
                           ExpressionAttributeValues={":p": PAT})
        for it in res.get("Items", []):
            alerts.delete_item(Key={"patientId": PAT, "timestamp": it["timestamp"]})
    except Exception:  # noqa: BLE001
        pass


def main() -> int:
    pepper = _sm.get_secret_value(SecretId=PEPPER_SECRET)["SecretString"]
    owner = claims(OWNER_SUB, role="household_owner", client_id=HH,
                   phone=OWNER_PHONE, name="E2E Sarah")
    print(f"— Care Circle E2E (run {RUN}, household {HH}) —")
    seed()
    try:
        # 1. Roster: owner + synthesized account-less walker; no pending.
        st, body = invoke(LAMBDA_CARE_CIRCLE, "GET /api/v1/household/members", owner)
        members = body.get("members", [])
        check("roster 200 (owner)", st == 200, f"{st} {body}")
        check("roster has owner + synthesized walker",
              len(members) == 2
              and any(m["isWalkerUser"] and m["userId"] is None for m in members),
              f"{members}")
        check("roster pendingInvites empty for admin",
              body.get("pendingInvites") == [], f"{body.get('pendingInvites')}")
        raw = json.dumps(body)
        check("no raw phone in roster", OWNER_PHONE not in raw, raw[:200])

        # 2. Self/duplicate-member dedupe fires BEFORE any SMS.
        st, body = invoke(LAMBDA_CARE_CIRCLE, "POST /api/v1/household/invites",
                          owner, body={"name": "Me", "phone": OWNER_PHONE})
        check("T12 self-invite → DUPLICATE_INVITE",
              st == 409 and err_code(body) == "DUPLICATE_INVITE", f"{st} {body}")

        # 3. Row-authoritative gate: token says member of HH, no row exists.
        ghost = claims("e2ecc-ghost", role="family_viewer", client_id=HH,
                       phone=WRONG_PHONE)
        st, body = invoke(LAMBDA_CARE_CIRCLE, "POST /api/v1/household/invites",
                          ghost, body={"name": "X", "phone": "+15125550005"})
        check("stale/ghost token → NOT_A_MEMBER",
              st == 403 and err_code(body) == "NOT_A_MEMBER", f"{st} {body}")

        # 4. NO_ACTIVE_WALKER for a bootstrap owner with no household data.
        empty_owner = claims(EMPTY_OWNER_SUB, role="household_owner",
                             client_id=f"dtc_{EMPTY_OWNER_SUB}",
                             phone="+15125550006")
        st, body = invoke(LAMBDA_CARE_CIRCLE, "POST /api/v1/household/invites",
                          empty_owner, body={"name": "X", "phone": "+15125550007"})
        check("empty household → NO_ACTIVE_WALKER",
              st == 409 and err_code(body) == "NO_ACTIVE_WALKER", f"{st} {body}")

        # Seed the accept-leg invite directly (no SMS).
        invite_id = uuid.uuid4().hex
        seed_invite(pepper, phone=MEMBER_PHONE, invite_id=invite_id)

        # 5. Admin roster now shows the pending invite (masked only).
        st, body = invoke(LAMBDA_CARE_CIRCLE, "GET /api/v1/household/members", owner)
        pend = body.get("pendingInvites", [])
        check("pending invite visible to admin (masked)",
              len(pend) == 1 and pend[0]["contactMask"].endswith(MEMBER_PHONE[-4:])
              and MEMBER_PHONE not in json.dumps(pend),
              f"{pend}")

        # 6. Invitee pending-lookup by verified phone hash.
        member_boot = claims(MEMBER_SUB, role="household_owner",
                             client_id=f"dtc_{MEMBER_SUB}", phone=MEMBER_PHONE,
                             name="E2E Jane")
        st, body = invoke(LAMBDA_CARE_CIRCLE, "GET /api/v1/invites/pending",
                          member_boot)
        got = body.get("invites", [])
        check("T14 pending-for-me matches by phone",
              st == 200 and len(got) == 1 and got[0]["inviteId"] == invite_id
              and got[0]["walkerName"] == "E2E Susan", f"{st} {got}")

        # 7. Unverified phone → empty (fail closed).
        member_unver = claims(MEMBER_SUB, role="household_owner",
                              client_id=f"dtc_{MEMBER_SUB}", phone=MEMBER_PHONE,
                              verified="false")
        st, body = invoke(LAMBDA_CARE_CIRCLE, "GET /api/v1/invites/pending",
                          member_unver)
        check("pending-for-me fail-closed on unverified phone",
              st == 200 and body.get("invites") == [], f"{st} {body}")

        # 8. Accept with the WRONG phone → neutral 403 (T2).
        wrong = claims("e2ecc-wrong", role="household_owner",
                       client_id="dtc_e2ecc-wrong", phone=WRONG_PHONE)
        st, body = invoke(LAMBDA_CARE_CIRCLE, "POST /api/v1/invites/accept",
                          wrong, body={"inviteId": invite_id})
        check("T2 wrong phone → INVITE_PHONE_MISMATCH",
              st == 403 and err_code(body) == "INVITE_PHONE_MISMATCH",
              f"{st} {body}")

        # 9. Accept with unverified phone → 403 (T3).
        st, body = invoke(LAMBDA_CARE_CIRCLE, "POST /api/v1/invites/accept",
                          member_unver, body={"inviteId": invite_id})
        check("T3 unverified phone → 403 fail closed",
              st == 403 and err_code(body) == "INVITE_PHONE_MISMATCH",
              f"{st} {body}")

        # 10. Happy-path accept (T1 API leg).
        st, body = invoke(LAMBDA_CARE_CIRCLE, "POST /api/v1/invites/accept",
                          member_boot, body={"inviteId": invite_id})
        check("accept → 201 + household summary",
              st == 201 and body.get("household", {}).get("clientId") == HH,
              f"{st} {body}")
        row = roles.get_item(Key={"userId": MEMBER_SUB}).get("Item") or {}
        check("member row: family_viewer + linkedPatientIds",
              row.get("role") == "family_viewer"
              and row.get("clientId") == HH
              and PAT in (row.get("linkedPatientIds") or set()), f"{row}")

        # 11. Idempotent re-accept (T6).
        st, body = invoke(LAMBDA_CARE_CIRCLE, "POST /api/v1/invites/accept",
                          member_boot, body={"inviteId": invite_id})
        check("T6 re-accept idempotent",
              st == 200 and body.get("alreadyMember") is True, f"{st} {body}")

        # 12. ALREADY_IN_HOUSEHOLD (T5): OTHER_SUB owns a different household.
        invite2 = uuid.uuid4().hex
        seed_invite(pepper, phone=OTHER_PHONE, invite_id=invite2)
        other = claims(OTHER_SUB, role="household_owner",
                       client_id=f"dtc_other{RUN}", phone=OTHER_PHONE)
        st, body = invoke(LAMBDA_CARE_CIRCLE, "POST /api/v1/invites/accept",
                          other, body={"inviteId": invite2})
        check("T5 cross-household accept → ALREADY_IN_HOUSEHOLD",
              st == 409 and err_code(body) == "ALREADY_IN_HOUSEHOLD",
              f"{st} {body}")

        # Member claims (post-join, row-authoritative).
        member = claims(MEMBER_SUB, role="family_viewer", client_id=HH,
                        phone=MEMBER_PHONE, name="E2E Jane")

        # 13. Member reads the walker via patient-api (2A-RD family_viewer).
        st, body = invoke(LAMBDA_PATIENT_API, "GET /api/v1/patients/{id}",
                          member, params={"id": PAT})
        check("member patient read → 200",
              st == 200 and body.get("patient", {}).get("patientId") == PAT,
              f"{st} {json.dumps(body)[:200]}")

        # 14. Member acks the alert (T10; d2c-prefixed route normalization).
        alert_row = alerts.query(
            KeyConditionExpression="patientId = :p",
            ExpressionAttributeValues={":p": PAT},
        )["Items"][0]
        sk = alert_row["timestamp"]
        st, body = invoke(
            LAMBDA_ALERT_ACTIONS,
            "PATCH /api/v1/d2c/alerts/{patientId}/{timestamp}",
            member, params={"patientId": PAT, "timestamp": sk},
            body={"notes": "Called Mom — all good."},
        )
        check("T10 member ack via /d2c/ route → 200 acknowledged",
              st == 200 and body.get("alert", {}).get("acknowledged") is True
              and body.get("wasAlreadyAcknowledged") is False,
              f"{st} {body}")
        st, body = invoke(
            LAMBDA_ALERT_ACTIONS,
            "PATCH /api/v1/d2c/alerts/{patientId}/{timestamp}",
            owner, params={"patientId": PAT, "timestamp": sk}, body={},
        )
        check("T10 second ack first-write-wins",
              st == 200 and body.get("wasAlreadyAcknowledged") is True,
              f"{st} {body}")

        # 15. Member tries to claim their own device (T7 guard).
        st, body = invoke(LAMBDA_D2C_CLAIM, "POST /api/v1/claim",
                          member, body={"walkerId": WALKER_ID})
        check("T7 member claim → MEMBER_CANNOT_CLAIM",
              st == 409 and err_code(body) == "MEMBER_CANNOT_CLAIM",
              f"{st} {body}")

        # 16. Last-admin guard (T8): sole owner demotes themselves.
        st, body = invoke(LAMBDA_CARE_CIRCLE,
                          "PATCH /api/v1/household/members/{userId}",
                          owner, params={"userId": OWNER_SUB},
                          body={"role": "family_viewer"})
        check("T8 demote sole owner → LAST_ADMIN",
              st == 409 and err_code(body) == "LAST_ADMIN", f"{st} {body}")

        # 17. Promote member → two owners; then demote back.
        st, body = invoke(LAMBDA_CARE_CIRCLE,
                          "PATCH /api/v1/household/members/{userId}",
                          owner, params={"userId": MEMBER_SUB},
                          body={"role": "household_owner"})
        check("promote member → 200", st == 200, f"{st} {body}")
        st, body = invoke(LAMBDA_CARE_CIRCLE,
                          "PATCH /api/v1/household/members/{userId}",
                          owner, params={"userId": MEMBER_SUB},
                          body={"role": "family_viewer"})
        row = roles.get_item(Key={"userId": MEMBER_SUB}).get("Item") or {}
        check("demote back re-links patients",
              st == 200 and row.get("role") == "family_viewer"
              and PAT in (row.get("linkedPatientIds") or set()), f"{st} {row}")

        # 18. Remove member → instant revoke (T9).
        st, body = invoke(LAMBDA_CARE_CIRCLE,
                          "DELETE /api/v1/household/members/{userId}",
                          owner, params={"userId": MEMBER_SUB})
        check("remove member → 200", st == 200 and body.get("removed") is True,
              f"{st} {body}")
        st, body = invoke(LAMBDA_PATIENT_API, "GET /api/v1/patients/{id}",
                          member, params={"id": PAT})
        check("T9 removed member read → 404 (instant revoke)",
              st == 404, f"{st} {body}")
        st, body = invoke(LAMBDA_CARE_CIRCLE, "GET /api/v1/household/members",
                          member)
        check("removed member roster → NOT_A_MEMBER",
              st == 403 and err_code(body) == "NOT_A_MEMBER", f"{st} {body}")

    finally:
        cleanup()

    print(f"\n{PASS} passed, {FAIL} failed")
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())

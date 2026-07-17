"""
Handler-level tests for the care-circle Lambda — d2c-care-circle.md §8
T2/T3/T4/T5/T6/T8/T12/T13 plus the row-authoritative NOT_A_MEMBER check.

All AWS IO is mocked at the module-attribute level (the handler holds its
boto3 Table objects as module globals); the SMS sender and the pepper are
injected the same way as d2c-claim's enforcement suite.

Run from repo root:
    cd infra/lambda
    python3 -m pytest care-circle/tests -q
"""

from __future__ import annotations

import importlib.util
import json
import os
import sys
import unittest
from pathlib import Path
from unittest.mock import MagicMock

_LAMBDA_DIR = Path(__file__).resolve().parents[2]
_CC_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(_LAMBDA_DIR))
sys.path.insert(0, str(_CC_DIR))

sys.path.insert(0, str(Path(__file__).resolve().parent))
import _stub_powertools  # noqa: F401,E402

os.environ.setdefault("CARE_INVITES_TABLE", "test-care-invites")
os.environ.setdefault("ROLE_ASSIGNMENTS_TABLE", "test-roles")
os.environ.setdefault("PATIENTS_TABLE", "test-patients")
os.environ.setdefault("ORGANIZATIONS_TABLE", "test-orgs")
os.environ.setdefault("D2C_APP_BASE_URL", "https://app.test")
os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")

# Unique module name — other lambda suites also have a "handler" module.
_spec = importlib.util.spec_from_file_location(
    "care_circle_handler", str(_CC_DIR / "handler.py")
)
handler = importlib.util.module_from_spec(_spec)
sys.modules["care_circle_handler"] = handler
_spec.loader.exec_module(handler)

from botocore.exceptions import ClientError  # noqa: E402

import _shared.claim_binding as claim_binding  # noqa: E402

PEPPER = "test-pepper"
OWNER_SUB = "owner-sub-1"
MEMBER_SUB = "member-sub-1"
HOUSEHOLD = "dtc_h0000000000000001"
OTHER_HOUSEHOLD = "dtc_h0000000000000002"
INVITEE_PHONE = "+15125550100"
INVITEE_HASH = claim_binding.hmac_phone(PEPPER, INVITEE_PHONE)
OWNER_PHONE = "+15125550001"


def _cc_failed(op: str = "UpdateItem") -> ClientError:
    return ClientError({"Error": {"Code": "ConditionalCheckFailedException"}}, op)


def _event(route: str, *, sub: str = OWNER_SUB, client_id: str = HOUSEHOLD,
           role: str = "household_owner", phone: str | None = OWNER_PHONE,
           verified: str = "true", body: dict | None = None,
           params: dict | None = None) -> dict:
    claims = {
        "sub": sub,
        "name": "Sarah Davis",
        "custom:role": role,
        "custom:clientId": client_id,
        "iat": "1700000000",
    }
    if phone is not None:
        claims["phone_number"] = phone
        claims["phone_number_verified"] = verified
    return {
        "routeKey": route,
        "requestContext": {
            "requestId": "req-1",
            "authorizer": {"jwt": {"claims": claims}},
        },
        "body": json.dumps(body or {}),
        "pathParameters": params or {},
    }


def _owner_row(sub: str = OWNER_SUB, client_id: str = HOUSEHOLD) -> dict:
    return {
        "userId": sub, "clientId": client_id, "role": "household_owner",
        "role_userId": f"household_owner#{sub}", "isWalkerUser": True,
        "displayName": "Sarah Davis", "phone": OWNER_PHONE, "email": "",
        "validFrom": "2026-07-01T00:00:00Z",
    }


def _member_row(sub: str = MEMBER_SUB, client_id: str = HOUSEHOLD) -> dict:
    return {
        "userId": sub, "clientId": client_id, "role": "family_viewer",
        "role_userId": f"family_viewer#{sub}", "isWalkerUser": False,
        "displayName": "Jane Davis", "phone": INVITEE_PHONE, "email": "",
        "validFrom": "2026-07-10T00:00:00Z",
        "linkedPatientIds": {"pat_1"},
    }


def _pending_invite(**over) -> dict:
    base = {
        "inviteId": "inv00000000000000000000000000001",
        "clientId": HOUSEHOLD,
        "contactHash": INVITEE_HASH,
        "contactMask": "•••-0100",
        "contactE164": INVITEE_PHONE,
        "contactChannel": "phone",
        "displayName": "Jane Davis",
        "relationship": "Daughter",
        "role": "family_viewer",
        "isWalkerUser": False,
        "status": "pending",
        "invitedBy": OWNER_SUB,
        "inviterName": "Sarah Davis",
        "householdName": "Susan's household",
        "walkerName": "Susan",
        "createdAt": "2026-07-14T00:00:00Z",
        "expiresAt": "2099-01-01T00:00:00Z",
        "ttl": 4102444800,
    }
    base.update(over)
    return base


class CareCircleTestBase(unittest.TestCase):
    def setUp(self):
        claim_binding._pepper_cache = PEPPER
        self.invites = MagicMock(name="invites")
        self.roles = MagicMock(name="roles")
        self.patients = MagicMock(name="patients")
        self.orgs = MagicMock(name="orgs")
        self.sms = MagicMock(name="send_sms")

        handler._invites = self.invites
        handler._roles = self.roles
        handler._patients = self.patients
        handler._orgs = self.orgs
        handler.send_sms = self.sms

        # Defaults: caller is the household owner; household has one active
        # patient; no members beyond the owner; no invites.
        self.roles.get_item.return_value = {"Item": _owner_row()}
        self.roles.query.return_value = {"Items": [_owner_row()], "Count": 1}
        self.patients.query.return_value = {
            "Items": [{"patientId": "pat_1", "displayName": "Susan",
                       "clientId": HOUSEHOLD, "createdAt": "2026-07-01T00:00:00Z"}]
        }
        self.orgs.get_item.return_value = {
            "Item": {"clientId": HOUSEHOLD, "sk": "META#client",
                     "displayName": "Susan's household"}
        }
        self.invites.query.return_value = {"Items": []}
        self.invites.get_item.return_value = {"Item": None}
        self.invites.put_item.return_value = {}
        self.invites.update_item.return_value = {}
        self.roles.put_item.return_value = {}
        self.roles.update_item.return_value = {}
        self.roles.delete_item.return_value = {}
        self.patients.update_item.return_value = {}

    def _call(self, event) -> tuple[int, dict]:
        resp = handler.handler(event, None)
        return resp["statusCode"], json.loads(resp["body"])


# ── POST /household/invites ────────────────────────────────────────────

class TestSendInvite(CareCircleTestBase):
    ROUTE = "POST /api/v1/household/invites"

    def _send(self, body=None, **kw):
        return self._call(_event(
            self.ROUTE,
            body=body or {"name": "Jane Davis", "phone": INVITEE_PHONE,
                          "relationship": "Daughter"},
            **kw,
        ))

    def test_happy_path_sends_sms_and_persists(self):
        status, body = self._send()
        self.assertEqual(status, 201, body)
        self.assertEqual(body["invite"]["contactMask"], "•••-0100")
        item = self.invites.put_item.call_args.kwargs["Item"]
        self.assertEqual(item["contactHash"], INVITEE_HASH)
        self.assertEqual(item["contactE164"], INVITEE_PHONE)
        to, sms_body = self.sms.call_args.args
        self.assertEqual(to, INVITEE_PHONE)
        self.assertIn(f"/join/{item['inviteId']}", sms_body)

    def test_no_active_walker_409(self):
        self.patients.query.return_value = {"Items": []}
        status, body = self._send()
        self.assertEqual(status, 409)
        self.assertEqual(body["error"]["code"], "NO_ACTIVE_WALKER")
        self.sms.assert_not_called()

    def test_t12_duplicate_member_phone_409(self):
        self.roles.query.return_value = {
            "Items": [_owner_row(), _member_row()], "Count": 1
        }
        status, body = self._send()
        self.assertEqual(status, 409)
        self.assertEqual(body["error"]["code"], "DUPLICATE_INVITE")

    def test_t12_self_invite_caught_by_member_dedupe(self):
        status, body = self._send(
            body={"name": "Me", "phone": OWNER_PHONE}
        )
        self.assertEqual(status, 409)
        self.assertEqual(body["error"]["code"], "DUPLICATE_INVITE")

    def test_t12_duplicate_pending_invite_409(self):
        self.invites.query.return_value = {"Items": [_pending_invite()]}
        status, body = self._send()
        self.assertEqual(status, 409)
        self.assertEqual(body["error"]["code"], "DUPLICATE_INVITE")

    def test_t12_pending_cap_409(self):
        pool = [
            _pending_invite(inviteId=f"inv{i:029d}",
                            contactHash=f"other-hash-{i}")
            for i in range(10)
        ]
        self.invites.query.return_value = {"Items": pool}
        status, body = self._send()
        self.assertEqual(status, 409)
        self.assertEqual(body["error"]["code"], "INVITE_LIMIT")

    def test_sms_failure_deletes_invite_and_502s(self):
        self.sms.side_effect = handler.SmsSendError("boom")
        status, body = self._send()
        self.assertEqual(status, 502)
        self.assertEqual(body["error"]["code"], "SMS_SEND_FAILED")
        self.invites.delete_item.assert_called_once()

    def test_member_cannot_invite(self):
        self.roles.get_item.return_value = {"Item": _member_row()}
        status, body = self._send(sub=MEMBER_SUB, role="family_viewer")
        self.assertEqual(status, 403)
        self.assertEqual(body["error"]["code"], "INSUFFICIENT_PERMISSIONS")

    def test_stale_token_demoted_owner_cannot_invite(self):
        # Token says owner; the ROW (authoritative) says family_viewer.
        self.roles.get_item.return_value = {"Item": _member_row(sub=OWNER_SUB)}
        status, body = self._send()
        self.assertEqual(status, 403)
        self.assertEqual(body["error"]["code"], "INSUFFICIENT_PERMISSIONS")


# ── POST /invites/accept ───────────────────────────────────────────────

class TestAcceptInvite(CareCircleTestBase):
    ROUTE = "POST /api/v1/invites/accept"

    def _accept(self, *, sub: str = MEMBER_SUB, phone=INVITEE_PHONE,
                verified: str = "true", client_id: str | None = None,
                invite: dict | None = None):
        self.invites.get_item.return_value = {
            "Item": invite if invite is not None else _pending_invite()
        }
        # Caller default: brand-new bootstrap user (no row) unless a test
        # overrides roles.get_item.
        return self._call(_event(
            self.ROUTE, sub=sub, role="household_owner",
            client_id=client_id or f"dtc_{sub}",
            phone=phone, verified=verified,
            body={"inviteId": _pending_invite()["inviteId"]},
        ))

    def setUp(self):
        super().setUp()
        # Accept-path default: caller has no RoleAssignments row yet.
        self.roles.get_item.return_value = {"Item": None}

    def test_happy_path_writes_conditional_member_row(self):
        status, body = self._accept()
        self.assertEqual(status, 201, body)
        self.assertFalse(body["alreadyMember"])
        self.assertEqual(body["household"]["clientId"], HOUSEHOLD)
        put = self.roles.put_item.call_args.kwargs
        self.assertEqual(put["Item"]["role"], "family_viewer")
        self.assertEqual(put["Item"]["linkedPatientIds"], {"pat_1"})
        self.assertIn("attribute_not_exists(userId)", put["ConditionExpression"])
        # First-accept-wins conditional on the invite.
        upd = self.invites.update_item.call_args.kwargs
        self.assertIn("#st = :pending", upd["ConditionExpression"])
        # No walker link for a non-walker invite.
        self.patients.update_item.assert_not_called()

    def test_t2_wrong_phone_403_neutral(self):
        status, body = self._accept(phone="+15125559999")
        self.assertEqual(status, 403)
        self.assertEqual(body["error"]["code"], "INVITE_PHONE_MISMATCH")
        self.roles.put_item.assert_not_called()

    def test_t3_unverified_phone_403_fail_closed(self):
        status, body = self._accept(verified="false")
        self.assertEqual(status, 403)
        self.assertEqual(body["error"]["code"], "INVITE_PHONE_MISMATCH")

    def test_t3_absent_phone_403_fail_closed(self):
        status, body = self._accept(phone=None)
        self.assertEqual(status, 403)
        self.assertEqual(body["error"]["code"], "INVITE_PHONE_MISMATCH")

    def test_t4_revoked_and_expired_409(self):
        status, body = self._accept(invite=_pending_invite(status="revoked"))
        self.assertEqual(status, 409)
        self.assertEqual(body["error"]["code"], "INVITE_NOT_ACTIVE")
        status, body = self._accept(
            invite=_pending_invite(expiresAt="2020-01-01T00:00:00Z")
        )
        self.assertEqual(status, 409)
        self.assertEqual(body["error"]["code"], "INVITE_NOT_ACTIVE")

    def test_t5_caller_in_other_household_409(self):
        self.roles.get_item.return_value = {
            "Item": _owner_row(sub=MEMBER_SUB, client_id=OTHER_HOUSEHOLD)
        }
        status, body = self._accept(client_id=OTHER_HOUSEHOLD)
        self.assertEqual(status, 409)
        self.assertEqual(body["error"]["code"], "ALREADY_IN_HOUSEHOLD")
        self.roles.put_item.assert_not_called()

    def test_t5_race_conditional_put_maps_to_409(self):
        self.roles.put_item.side_effect = _cc_failed("PutItem")
        status, body = self._accept()
        self.assertEqual(status, 409)
        self.assertEqual(body["error"]["code"], "ALREADY_IN_HOUSEHOLD")

    def test_t6_idempotent_reaccept_same_household(self):
        self.roles.get_item.return_value = {
            "Item": _member_row(sub=MEMBER_SUB, client_id=HOUSEHOLD)
        }
        status, body = self._accept(
            client_id=HOUSEHOLD,
            invite=_pending_invite(status="accepted", acceptedBy=MEMBER_SUB),
        )
        self.assertEqual(status, 200, body)
        self.assertTrue(body["alreadyMember"])

    def test_first_accept_race_loser_gets_409(self):
        self.invites.update_item.side_effect = _cc_failed()
        # Re-read shows the OTHER user won.
        pending = _pending_invite(status="accepted", acceptedBy="someone-else")
        self.invites.get_item.side_effect = [
            {"Item": _pending_invite()},  # initial read: still pending
            {"Item": pending},            # post-conditional re-read
        ]
        status, body = self._call(_event(
            self.ROUTE, sub=MEMBER_SUB, client_id=f"dtc_{MEMBER_SUB}",
            phone=INVITEE_PHONE,
            body={"inviteId": pending["inviteId"]},
        ))
        self.assertEqual(status, 409)
        self.assertEqual(body["error"]["code"], "INVITE_NOT_ACTIVE")

    def test_t13_walker_user_invite_links_patient(self):
        status, body = self._accept(invite=_pending_invite(isWalkerUser=True))
        self.assertEqual(status, 201, body)
        upd = self.patients.update_item.call_args.kwargs
        self.assertEqual(upd["Key"], {"patientId": "pat_1"})
        self.assertIn("attribute_not_exists(cognitoUserId)",
                      upd["ConditionExpression"])

    def test_t13_stale_walker_flag_never_fails_join(self):
        self.patients.update_item.side_effect = _cc_failed()
        status, body = self._accept(invite=_pending_invite(isWalkerUser=True))
        self.assertEqual(status, 201, body)


# ── GET /household/members ─────────────────────────────────────────────

class TestRoster(CareCircleTestBase):
    ROUTE = "GET /api/v1/household/members"

    def test_owner_sees_members_walker_and_pending(self):
        # No member row claims isWalkerUser → the account-less walker entry
        # must be synthesized from the active Patient (D10).
        self.roles.query.return_value = {
            "Items": [{**_owner_row(), "isWalkerUser": False}, _member_row()],
            "Count": 1,
        }
        self.invites.query.return_value = {"Items": [_pending_invite()]}
        status, body = self._call(_event(self.ROUTE))
        self.assertEqual(status, 200, body)
        names = [m["displayName"] for m in body["members"]]
        self.assertIn("Susan", names)  # synthesized account-less walker (D10)
        self.assertEqual(len(body["pendingInvites"]), 1)
        # Raw contact data never leaves the API.
        blob = json.dumps(body)
        self.assertNotIn(INVITEE_PHONE, blob)
        self.assertNotIn(INVITEE_HASH, blob)

    def test_member_sees_roster_without_pending(self):
        self.roles.get_item.return_value = {"Item": _member_row()}
        self.roles.query.return_value = {
            "Items": [_owner_row(), _member_row()], "Count": 1
        }
        status, body = self._call(_event(
            self.ROUTE, sub=MEMBER_SUB, role="family_viewer"
        ))
        self.assertEqual(status, 200, body)
        self.assertNotIn("pendingInvites", body)

    def test_removed_member_stale_token_403(self):
        self.roles.get_item.return_value = {"Item": None}
        status, body = self._call(_event(
            self.ROUTE, sub=MEMBER_SUB, role="family_viewer",
            client_id=HOUSEHOLD,  # token still names the household
        ))
        self.assertEqual(status, 403)
        self.assertEqual(body["error"]["code"], "NOT_A_MEMBER")


# ── PATCH + DELETE /household/members/{userId} ─────────────────────────

class TestRosterMutations(CareCircleTestBase):
    PATCH = "PATCH /api/v1/household/members/{userId}"
    DELETE = "DELETE /api/v1/household/members/{userId}"

    def test_promote_member_to_owner(self):
        self.roles.get_item.side_effect = [
            {"Item": _owner_row()},   # caller (_require_admin)
            {"Item": _member_row()},  # target
        ]
        status, body = self._call(_event(
            self.PATCH, params={"userId": MEMBER_SUB},
            body={"role": "household_owner"},
        ))
        self.assertEqual(status, 200, body)
        upd = self.roles.update_item.call_args.kwargs
        self.assertIn("REMOVE linkedPatientIds", upd["UpdateExpression"])

    def test_t8_demote_last_owner_409(self):
        self.roles.get_item.side_effect = [
            {"Item": _owner_row()},  # caller
            {"Item": _owner_row()},  # target (self)
        ]
        self.roles.query.return_value = {"Items": [], "Count": 1}
        status, body = self._call(_event(
            self.PATCH, params={"userId": OWNER_SUB},
            body={"role": "family_viewer"},
        ))
        self.assertEqual(status, 409)
        self.assertEqual(body["error"]["code"], "LAST_ADMIN")

    def test_demote_with_two_owners_ok_and_relinks(self):
        second_owner = _owner_row(sub="owner-sub-2")
        self.roles.get_item.side_effect = [
            {"Item": _owner_row()},
            {"Item": second_owner},
        ]
        self.roles.query.return_value = {"Items": [], "Count": 2}
        status, body = self._call(_event(
            self.PATCH, params={"userId": "owner-sub-2"},
            body={"role": "family_viewer"},
        ))
        self.assertEqual(status, 200, body)
        upd = self.roles.update_item.call_args.kwargs
        self.assertEqual(upd["ExpressionAttributeValues"][":lp"], {"pat_1"})

    def test_admin_removes_member(self):
        self.roles.get_item.side_effect = [
            {"Item": _owner_row()},
            {"Item": _member_row()},
        ]
        status, body = self._call(_event(
            self.DELETE, params={"userId": MEMBER_SUB},
        ))
        self.assertEqual(status, 200, body)
        self.assertFalse(body["left"])
        self.roles.delete_item.assert_called_once()

    def test_member_leaves_voluntarily(self):
        self.roles.get_item.side_effect = [
            {"Item": _member_row()},  # caller (_membership)
            {"Item": _member_row()},  # target (self)
        ]
        status, body = self._call(_event(
            self.DELETE, sub=MEMBER_SUB, role="family_viewer",
            params={"userId": MEMBER_SUB},
        ))
        self.assertEqual(status, 200, body)
        self.assertTrue(body["left"])

    def test_t8_last_owner_cannot_leave(self):
        self.roles.get_item.side_effect = [
            {"Item": _owner_row()},
            {"Item": _owner_row()},
        ]
        self.roles.query.return_value = {"Items": [], "Count": 1}
        status, body = self._call(_event(
            self.DELETE, params={"userId": OWNER_SUB},
        ))
        self.assertEqual(status, 409)
        self.assertEqual(body["error"]["code"], "LAST_ADMIN")

    def test_member_cannot_remove_others(self):
        self.roles.get_item.return_value = {"Item": _member_row()}
        status, body = self._call(_event(
            self.DELETE, sub=MEMBER_SUB, role="family_viewer",
            params={"userId": OWNER_SUB},
        ))
        self.assertEqual(status, 403)
        self.assertEqual(body["error"]["code"], "INSUFFICIENT_PERMISSIONS")

    def test_cross_household_target_404(self):
        self.roles.get_item.side_effect = [
            {"Item": _owner_row()},
            {"Item": _member_row(client_id=OTHER_HOUSEHOLD)},
        ]
        status, body = self._call(_event(
            self.DELETE, params={"userId": MEMBER_SUB},
        ))
        self.assertEqual(status, 404)
        self.assertEqual(body["error"]["code"], "MEMBER_NOT_FOUND")


# ── GET /invites/pending ───────────────────────────────────────────────

class TestPendingForCaller(CareCircleTestBase):
    ROUTE = "GET /api/v1/invites/pending"

    def test_matches_by_verified_phone_hash(self):
        self.invites.query.return_value = {"Items": [_pending_invite()]}
        status, body = self._call(_event(
            self.ROUTE, sub=MEMBER_SUB, client_id=f"dtc_{MEMBER_SUB}",
            phone=INVITEE_PHONE,
        ))
        self.assertEqual(status, 200, body)
        self.assertEqual(len(body["invites"]), 1)
        self.assertEqual(body["invites"][0]["householdName"], "Susan's household")
        q = self.invites.query.call_args.kwargs
        self.assertEqual(q["IndexName"], "by-contact-hash")
        self.assertEqual(q["ExpressionAttributeValues"][":h"], INVITEE_HASH)

    def test_unverified_phone_returns_empty_fail_closed(self):
        status, body = self._call(_event(
            self.ROUTE, sub=MEMBER_SUB, client_id=f"dtc_{MEMBER_SUB}",
            phone=INVITEE_PHONE, verified="false",
        ))
        self.assertEqual(status, 200)
        self.assertEqual(body["invites"], [])
        self.invites.query.assert_not_called()


if __name__ == "__main__":
    unittest.main()

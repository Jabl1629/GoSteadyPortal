"""
Handler tests for the QR re-login broker (d2c-qr-relogin):
  GET  /public/walkers/{walkerId}/recipients
  POST /public/walkers/{walkerId}/login-code
  POST /public/walkers/{walkerId}/login-code/verify

Cognito is mocked at the module attribute (handler.cognito_idp); tables are
mocked like the claim-enforcement suite. Verifies the full phone never appears
in a response until a code is verified.

Run:  cd infra/lambda && python3 -m pytest d2c-claim/tests/test_login_relogin.py
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
_D2C_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(_LAMBDA_DIR))
sys.path.insert(0, str(_D2C_DIR))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import _stub_powertools  # noqa: F401,E402

os.environ.setdefault("DEVICES_TABLE", "test-devices")
os.environ.setdefault("DEVICE_ASSIGNMENTS_TABLE", "test-assignments")
os.environ.setdefault("PATIENTS_TABLE", "test-patients")
os.environ.setdefault("ORGANIZATIONS_TABLE", "test-orgs")
os.environ.setdefault("ROLE_ASSIGNMENTS_TABLE", "test-roles")
os.environ.setdefault("D2C_APP_CLIENT_ID", "test-client-id")
os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")

_spec = importlib.util.spec_from_file_location(
    "d2c_claim_handler_relogin", str(_D2C_DIR / "handler.py")
)
handler = importlib.util.module_from_spec(_spec)
sys.modules["d2c_claim_handler_relogin"] = handler
_spec.loader.exec_module(handler)

from botocore.exceptions import ClientError  # noqa: E402

import _shared.claim_binding as claim_binding  # noqa: E402
from claim_logic import login_recipient_id  # noqa: E402

PEPPER = "test-pepper"
WID = "walker-abc"
SERIAL = "GS0002000009"
HH = "dtc_h1"
OWNER_PHONE = "+17202064566"
DAU_PHONE = "+14155551234"


def _cc_failed(op: str = "UpdateItem") -> ClientError:
    return ClientError({"Error": {"Code": "ConditionalCheckFailedException"}}, op)


def _members():
    return [
        {"userId": "u_owner", "clientId": HH, "phone": OWNER_PHONE,
         "role": "household_owner", "isWalkerUser": True, "relationship": ""},
        {"userId": "u_dau", "clientId": HH, "phone": DAU_PHONE,
         "role": "family_viewer", "isWalkerUser": False, "relationship": "Daughter"},
    ]


def _event(route: str, *, params=None, body=None) -> dict:
    return {
        "routeKey": route,
        "rawPath": route.split(" ", 1)[1],
        "requestContext": {"requestId": "req-1", "http": {"method": route.split(" ", 1)[0]}},
        "pathParameters": params or {"walkerId": WID},
        "body": json.dumps(body) if body is not None else None,
    }


class ReloginBase(unittest.TestCase):
    def setUp(self):
        claim_binding._pepper_cache = PEPPER
        self.devices = MagicMock(name="devices")
        self.roles = MagicMock(name="roles")
        self.cog = MagicMock(name="cognito_idp")
        handler._devices = self.devices
        handler._roles = self.roles
        handler.cognito_idp = self.cog
        # walkerId → owned device
        self.devices.query.return_value = {"Items": [
            {"serialNumber": SERIAL, "walkerId": WID, "owningClientId": HH,
             "status": "active_monitoring"}]}
        self.devices.update_item.return_value = {}  # cooldown ok by default
        self.roles.query.return_value = {"Items": _members()}

    def _call(self, event):
        resp = handler.handler(event, None)
        return resp["statusCode"], json.loads(resp["body"])

    def _rid(self, phone):
        return login_recipient_id(PEPPER, WID, phone)


class TestRecipients(ReloginBase):
    ROUTE = "GET /api/v1/public/walkers/{walkerId}/recipients"

    def test_masked_list_no_phone_leak(self):
        st, body = self._call(_event(self.ROUTE))
        self.assertEqual(st, 200, body)
        recips = body["recipients"]
        self.assertEqual(len(recips), 2)
        self.assertEqual(sum(r["isPrimary"] for r in recips), 1)
        blob = json.dumps(body)
        self.assertNotIn("7202064566", blob)
        self.assertNotIn("4155551234", blob)
        self.assertNotIn("u_owner", blob)

    def test_unclaimed_device_empty(self):
        self.devices.query.return_value = {"Items": [
            {"serialNumber": SERIAL, "walkerId": WID}]}  # no owningClientId
        st, body = self._call(_event(self.ROUTE))
        self.assertEqual(st, 200)
        self.assertEqual(body["recipients"], [])

    def test_unknown_walker_neutral_empty(self):
        self.devices.query.return_value = {"Items": []}
        st, body = self._call(_event(self.ROUTE))
        self.assertEqual(st, 200)
        self.assertEqual(body["recipients"], [])


class TestSendLoginCode(ReloginBase):
    ROUTE = "POST /api/v1/public/walkers/{walkerId}/login-code"

    def test_happy_path_initiates_and_returns_session_not_phone(self):
        self.cog.initiate_auth.return_value = {
            "ChallengeName": "CUSTOM_CHALLENGE", "Session": "sess-123"}
        st, body = self._call(_event(
            self.ROUTE, body={"recipientId": self._rid(OWNER_PHONE)}))
        self.assertEqual(st, 200, body)
        self.assertEqual(body["session"], "sess-123")
        self.assertEqual(body["mask"], "•••-4566")
        self.assertNotIn("7202064566", json.dumps(body))
        # initiated CUSTOM_AUTH for the resolved phone
        kw = self.cog.initiate_auth.call_args.kwargs
        self.assertEqual(kw["AuthFlow"], "CUSTOM_AUTH")
        self.assertEqual(kw["AuthParameters"]["USERNAME"], OWNER_PHONE)

    def test_cooldown_returns_429(self):
        self.devices.update_item.side_effect = _cc_failed()
        st, body = self._call(_event(
            self.ROUTE, body={"recipientId": self._rid(OWNER_PHONE)}))
        self.assertEqual(st, 429)
        self.assertEqual(body["error"]["code"], "TOO_MANY_REQUESTS")
        self.cog.initiate_auth.assert_not_called()

    def test_unknown_recipient_neutral_404(self):
        st, body = self._call(_event(self.ROUTE, body={"recipientId": "bogus"}))
        self.assertEqual(st, 404)
        self.assertEqual(body["error"]["code"], "RECIPIENT_NOT_FOUND")
        self.cog.initiate_auth.assert_not_called()


class TestVerifyLoginCode(ReloginBase):
    ROUTE = "POST /api/v1/public/walkers/{walkerId}/login-code/verify"

    def _body(self, **over):
        b = {"recipientId": self._rid(OWNER_PHONE), "session": "sess-1", "code": "123456"}
        b.update(over)
        return b

    def test_success_returns_tokens_and_phone(self):
        self.cog.respond_to_auth_challenge.return_value = {
            "AuthenticationResult": {
                "IdToken": "id.jwt", "AccessToken": "acc.jwt", "RefreshToken": "ref.jwt"}}
        st, body = self._call(_event(self.ROUTE, body=self._body()))
        self.assertEqual(st, 200, body)
        self.assertEqual(body["status"], "ok")
        self.assertEqual(body["idToken"], "id.jwt")
        self.assertEqual(body["refreshToken"], "ref.jwt")
        # phone IS returned now — the caller proved possession of the code
        self.assertEqual(body["phone"], OWNER_PHONE)
        kw = self.cog.respond_to_auth_challenge.call_args.kwargs
        self.assertEqual(kw["ChallengeResponses"]["USERNAME"], OWNER_PHONE)
        self.assertEqual(kw["ChallengeResponses"]["ANSWER"], "123456")

    def test_wrong_code_with_attempts_left_returns_retry(self):
        self.cog.respond_to_auth_challenge.return_value = {
            "ChallengeName": "CUSTOM_CHALLENGE", "Session": "sess-2"}
        st, body = self._call(_event(self.ROUTE, body=self._body()))
        self.assertEqual(st, 200, body)
        self.assertEqual(body["status"], "retry")
        self.assertEqual(body["session"], "sess-2")

    def test_out_of_attempts_401(self):
        self.cog.respond_to_auth_challenge.side_effect = ClientError(
            {"Error": {"Code": "NotAuthorizedException"}}, "RespondToAuthChallenge")
        st, body = self._call(_event(self.ROUTE, body=self._body()))
        self.assertEqual(st, 401)
        self.assertEqual(body["error"]["code"], "LOGIN_CODE_EXPIRED")

    def test_unknown_recipient_neutral_404(self):
        st, body = self._call(_event(self.ROUTE, body=self._body(recipientId="bogus")))
        self.assertEqual(st, 404)


if __name__ == "__main__":
    unittest.main(verbosity=2)

"""
Care Circle claim guard — d2c-care-circle.md §5.6 / §8 T7-adjacent.

A `family_viewer`'s RoleAssignments row must never let a claim resolve
into the household they merely view (device would attach to THAT
household's patient and the role-row overwrite would promote them to
owner). A member re-scanning their own household's already-claimed
device still gets the benign idempotent response.

Run from repo root:
    cd infra/lambda
    python3 -m pytest d2c-claim/tests -q
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
os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")

_spec = importlib.util.spec_from_file_location(
    "d2c_claim_handler_member_guard", str(_D2C_DIR / "handler.py")
)
handler = importlib.util.module_from_spec(_spec)
sys.modules["d2c_claim_handler_member_guard"] = handler
_spec.loader.exec_module(handler)

import _shared.claim_binding as claim_binding  # noqa: E402

PEPPER = "test-pepper"
WALKER_ID = "0e0a3a1c-2f9f-4bb0-9dc7-1a30cb0a0001"
SERIAL = "GS0002000009"
MEMBER_SUB = "member-sub-1"
HOUSEHOLD = "dtc_h0000000000000001"


def _event(sub: str = MEMBER_SUB) -> dict:
    return {
        "routeKey": "POST /api/v1/claim",
        "requestContext": {
            "requestId": "req-1",
            "authorizer": {"jwt": {"claims": {
                "sub": sub,
                "name": "Jane Davis",
                "custom:role": "family_viewer",
                "custom:clientId": HOUSEHOLD,
                "phone_number": "+15125550100",
                "phone_number_verified": "true",
                "iat": "1700000000",
            }}},
        },
        "body": json.dumps({"walkerId": WALKER_ID}),
        "pathParameters": {},
    }


def _member_row() -> dict:
    return {
        "userId": MEMBER_SUB, "clientId": HOUSEHOLD, "role": "family_viewer",
        "role_userId": f"family_viewer#{MEMBER_SUB}", "isWalkerUser": False,
        "linkedPatientIds": {"pat_1"},
    }


class TestMemberClaimGuard(unittest.TestCase):
    def setUp(self):
        claim_binding._pepper_cache = PEPPER
        self.devices = MagicMock(name="devices")
        self.patients = MagicMock(name="patients")
        self.orgs = MagicMock(name="orgs")
        self.roles = MagicMock(name="roles")
        handler._devices = self.devices
        handler._assignments = MagicMock(name="assignments")
        handler._patients = self.patients
        handler._orgs = self.orgs
        handler._roles = self.roles
        handler.iot_data = MagicMock(name="iot_data")

        self.roles.get_item.return_value = {"Item": _member_row()}
        self.patients.query.return_value = {"Items": []}

    def _claim(self):
        resp = handler.handler(_event(), None)
        return resp["statusCode"], json.loads(resp["body"])

    def _set_device(self, **over):
        base = {"serialNumber": SERIAL, "walkerId": WALKER_ID,
                "status": "ready_to_provision"}
        base.update(over)
        self.devices.query.return_value = {"Items": [base]}

    def test_member_claiming_unowned_device_409s_before_any_write(self):
        self._set_device()
        status, body = self._claim()
        self.assertEqual(status, 409, body)
        self.assertEqual(body["error"]["code"], "MEMBER_CANNOT_CLAIM")
        self.patients.put_item.assert_not_called()
        self.roles.put_item.assert_not_called()
        self.devices.update_item.assert_not_called()

    def test_member_claiming_device_owned_elsewhere_still_member_guard(self):
        # Guard fires before the ownership gate — the member never learns
        # whether the device is owned (same neutral support copy).
        self._set_device(owningClientId="dtc_someone_else")
        status, body = self._claim()
        self.assertEqual(status, 409)
        self.assertEqual(body["error"]["code"], "MEMBER_CANNOT_CLAIM")

    def test_member_rescanning_own_household_device_is_idempotent(self):
        self._set_device(owningClientId=HOUSEHOLD)
        self.patients.query.return_value = {"Items": [{
            "patientId": "pat_1", "clientId": HOUSEHOLD,
            "displayName": "Susan", "status": "active",
            "isWalkerUser": True,
        }]}
        status, body = self._claim()
        self.assertEqual(status, 200, body)
        self.assertTrue(body["alreadyClaimed"])
        # Benign no-write path: the member's row was not overwritten.
        self.roles.put_item.assert_not_called()


if __name__ == "__main__":
    unittest.main()

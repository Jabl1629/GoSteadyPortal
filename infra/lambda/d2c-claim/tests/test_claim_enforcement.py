"""
Handler-level tests for d2c-claim claim-binding enforcement —
docs/specs/d2c-claim-binding.md §5.2 / §5.5 / §5.7 (spec §8 T1–T3, T7,
T8, T12 + the §5.2d rollback-restore).

All AWS IO is mocked at the module-attribute level (the handler holds
its boto3 Table/client objects as module globals). The pepper is
injected via _shared.claim_binding._pepper_cache so get_pepper() never
touches Secrets Manager.

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

# Unique module name — other lambda suites also have a "handler" module.
_spec = importlib.util.spec_from_file_location(
    "d2c_claim_handler", str(_D2C_DIR / "handler.py")
)
handler = importlib.util.module_from_spec(_spec)
sys.modules["d2c_claim_handler"] = handler
_spec.loader.exec_module(handler)

from botocore.exceptions import ClientError  # noqa: E402

import _shared.claim_binding as claim_binding  # noqa: E402

PEPPER = "test-pepper"
BOUND_PHONE = "+15125550100"
BOUND_HASH = claim_binding.hmac_phone(PEPPER, BOUND_PHONE)
BOUND_MASK = claim_binding.mask_phone(BOUND_PHONE)
WALKER_ID = "c7e589c0-eb65-4336-8757-e9182f60f5d5"
SERIAL = "GS0002000001"


def _cc_failed(op: str = "UpdateItem") -> ClientError:
    return ClientError(
        {"Error": {"Code": "ConditionalCheckFailedException"}}, op
    )


def _event(body: dict | None = None, *, phone: str = BOUND_PHONE,
           verified: str = "true", sub: str = "user-sub-1") -> dict:
    claims = {
        "sub": sub,
        "name": "Pat Tester",
        "custom:role": "household_owner",
        "custom:clientId": f"dtc_{sub}",
        "phone_number": phone,
        "phone_number_verified": verified,
        "iat": "1700000000",
    }
    if phone is None:
        claims.pop("phone_number")
        claims.pop("phone_number_verified")
    return {
        "routeKey": "POST /api/v1/claim",
        "requestContext": {
            "requestId": "req-1",
            "authorizer": {"jwt": {"claims": claims}},
        },
        "body": json.dumps(body or {"walkerId": WALKER_ID}),
        "pathParameters": {},
    }


def _device(**over) -> dict:
    base = {
        "serialNumber": SERIAL,
        "walkerId": WALKER_ID,
        "status": "ready_to_provision",
        "deviceType": "rollator_platform",
    }
    base.update(over)
    return base


class ClaimTestBase(unittest.TestCase):
    def setUp(self):
        claim_binding._pepper_cache = PEPPER
        self.devices = MagicMock(name="devices")
        self.assignments = MagicMock(name="assignments")
        self.patients = MagicMock(name="patients")
        self.orgs = MagicMock(name="orgs")
        self.roles = MagicMock(name="roles")
        self.iot = MagicMock(name="iot_data")

        handler._devices = self.devices
        handler._assignments = self.assignments
        handler._patients = self.patients
        handler._orgs = self.orgs
        handler._roles = self.roles
        handler.iot_data = self.iot

        # Defaults: first-time claimer, empty household, org rows exist
        # (skips the ensure-household puts), no patients yet.
        self.roles.get_item.return_value = {"Item": None}
        self.orgs.get_item.return_value = {"Item": {"clientId": "x"}}
        self.patients.query.return_value = {"Items": []}
        self.devices.update_item.return_value = {}
        self.devices.get_item.return_value = {"Item": _device()}
        self.assignments.put_item.return_value = {}
        self.patients.put_item.return_value = {}
        self.roles.put_item.return_value = {}

    def _set_device(self, device: dict):
        self.devices.query.return_value = {"Items": [device]}

    def _claim(self, event=None):
        resp = handler.handler(event or _event(), None)
        return resp["statusCode"], json.loads(resp["body"])


class TestBindingEnforcement(ClaimTestBase):
    def test_t3_unbound_open_self_claim_succeeds(self):
        self._set_device(_device())
        status, body = self._claim()
        self.assertEqual(status, 201, body)
        # Step-1b guarded against a concurrent bind appearing.
        step1b = [
            c for c in self.devices.update_item.call_args_list
            if "ConditionExpression" in c.kwargs
        ][0]
        self.assertIn("attribute_not_exists(claimBoundPhone)",
                      step1b.kwargs["ConditionExpression"])
        self.assertIn("REMOVE claimBoundPhone", step1b.kwargs["UpdateExpression"])

    def test_t1_bound_matching_verified_phone_succeeds_and_consumes(self):
        self._set_device(_device(claimBoundPhone=BOUND_HASH,
                                 claimBoundPhoneMask=BOUND_MASK))
        status, body = self._claim(_event(phone="+1 (512) 555-0100"))
        self.assertEqual(status, 201, body)
        step1b = [
            c for c in self.devices.update_item.call_args_list
            if "ConditionExpression" in c.kwargs
        ][0]
        # Consumed atomically, guarded on the exact hash we checked.
        self.assertIn("REMOVE claimBoundPhone, claimBoundPhoneMask",
                      step1b.kwargs["UpdateExpression"])
        self.assertIn("claimBoundPhone = :boundv",
                      step1b.kwargs["ConditionExpression"])
        self.assertEqual(step1b.kwargs["ExpressionAttributeValues"][":boundv"],
                         BOUND_HASH)

    def test_t2_bound_wrong_phone_403(self):
        self._set_device(_device(claimBoundPhone=BOUND_HASH))
        status, body = self._claim(_event(phone="+15125559999"))
        self.assertEqual(status, 403)
        self.assertEqual(body["error"]["code"], "CLAIM_PHONE_MISMATCH")
        self.patients.put_item.assert_not_called()

    def test_t12_bound_missing_phone_fails_closed(self):
        self._set_device(_device(claimBoundPhone=BOUND_HASH))
        status, body = self._claim(_event(phone=None))
        self.assertEqual(status, 403)
        self.assertEqual(body["error"]["code"], "CLAIM_PHONE_MISMATCH")

    def test_t12_bound_unverified_phone_fails_closed(self):
        self._set_device(_device(claimBoundPhone=BOUND_HASH))
        status, body = self._claim(_event(verified="false"))
        self.assertEqual(status, 403)
        self.assertEqual(body["error"]["code"], "CLAIM_PHONE_MISMATCH")

    def test_unbound_unverified_phone_still_claims(self):
        # Fail-closed applies to BOUND devices only — open self-claim is
        # the retail baseline and phone-verification is not its gate.
        self._set_device(_device())
        status, body = self._claim(_event(verified="false"))
        self.assertEqual(status, 201, body)

    def test_agreement_version_recorded_on_owner_row(self):
        # d2c-user-agreement.md: the setup gate sends the acknowledged version
        # → stamped on the owner's RoleAssignments row (version + timestamp).
        self._set_device(_device())
        status, body = self._claim(
            _event(body={"walkerId": WALKER_ID, "agreementVersion": "2026-07-18"})
        )
        self.assertEqual(status, 201, body)
        put = self.roles.put_item.call_args.kwargs
        self.assertEqual(put["Item"]["agreementVersion"], "2026-07-18")
        self.assertIn("agreementAcceptedAt", put["Item"])

    def test_no_agreement_version_leaves_owner_row_unstamped(self):
        self._set_device(_device())
        status, body = self._claim()  # default body has no agreementVersion
        self.assertEqual(status, 201, body)
        put = self.roles.put_item.call_args.kwargs
        self.assertNotIn("agreementVersion", put["Item"])


class TestOwnershipGate(ClaimTestBase):
    def test_t7_ready_but_owned_by_other_household_409(self):
        self._set_device(_device(owningClientId="dtc_someoneelse"))
        status, body = self._claim()
        self.assertEqual(status, 409)
        self.assertEqual(body["error"]["code"], "DEVICE_OWNED")
        self.patients.put_item.assert_not_called()
        # Gate applies regardless of status — discontinued+owned too.
        self._set_device(_device(owningClientId="dtc_someoneelse",
                                 status="discontinued"))
        status, body = self._claim()
        self.assertEqual(status, 409)
        self.assertEqual(body["error"]["code"], "DEVICE_OWNED")

    def test_idempotent_reclaim_by_owner_household(self):
        self.roles.get_item.return_value = {
            "Item": {"userId": "user-sub-1", "clientId": "dtc_h1"}
        }
        self._set_device(_device(owningClientId="dtc_h1", status="provisioned"))
        self.patients.query.return_value = {"Items": [{
            "patientId": "pat_1", "clientId": "dtc_h1", "status": "active",
        }]}
        status, body = self._claim()
        self.assertEqual(status, 200, body)
        self.assertTrue(body["alreadyClaimed"])

    def test_unowned_discontinued_still_unavailable(self):
        # Mid-rotation: released but wipe not yet acked → not claimable.
        self._set_device(_device(status="discontinued"))
        status, body = self._claim()
        self.assertEqual(status, 409)
        self.assertEqual(body["error"]["code"], "DEVICE_UNAVAILABLE")


class TestDedupe(ClaimTestBase):
    def test_t8_returning_user_reuses_active_patient(self):
        self.roles.get_item.return_value = {
            "Item": {"userId": "user-sub-1", "clientId": "dtc_h1"}
        }
        self._set_device(_device())  # released device, unowned
        existing = {
            "patientId": "pat_existing", "clientId": "dtc_h1",
            "status": "active", "status_patientId": "active_pat_existing",
        }

        def _query(**kw):
            if "begins_with" in kw.get("KeyConditionExpression", ""):
                return {"Items": [existing]}
            return {"Items": [existing]}

        self.patients.query.side_effect = _query
        status, body = self._claim()
        self.assertEqual(status, 201, body)
        self.patients.put_item.assert_not_called()  # no duplicate patient
        self.assertEqual(body["patient"]["patientId"], "pat_existing")
        # Provision went to the existing patient.
        put = self.assignments.put_item.call_args.kwargs["Item"]
        self.assertEqual(put["patientId"], "pat_existing")


class TestRollbackRestore(ClaimTestBase):
    def test_t10_step2_failure_restores_binding(self):
        self._set_device(_device(claimBoundPhone=BOUND_HASH,
                                 claimBoundPhoneMask=BOUND_MASK))
        self.assignments.put_item.side_effect = ClientError(
            {"Error": {"Code": "InternalError"}}, "PutItem"
        )
        status, body = self._claim()
        self.assertEqual(status, 500)
        rollback = self.devices.update_item.call_args_list[-1]
        self.assertIn("claimBoundPhone = :bhash", rollback.kwargs["UpdateExpression"])
        self.assertEqual(rollback.kwargs["ExpressionAttributeValues"][":bhash"],
                         BOUND_HASH)
        self.assertEqual(rollback.kwargs["ExpressionAttributeValues"][":bmask"],
                         BOUND_MASK)
        # Patient row created by this claim was rolled back.
        self.patients.delete_item.assert_called_once()

    def test_step3_failure_restores_binding_and_assignment(self):
        self._set_device(_device(claimBoundPhone=BOUND_HASH,
                                 claimBoundPhoneMask=BOUND_MASK))
        self.iot.publish.side_effect = ClientError(
            {"Error": {"Code": "InternalFailure"}}, "Publish"
        )
        status, _ = self._claim()
        self.assertEqual(status, 500)
        rollback = [
            c for c in self.devices.update_item.call_args_list
            if "claimBoundPhone = :bhash" in c.kwargs.get("UpdateExpression", "")
        ]
        self.assertEqual(len(rollback), 1)
        self.assignments.delete_item.assert_called_once()


class TestPublicLookupReserved(ClaimTestBase):
    def _lookup(self):
        event = {
            "routeKey": "GET /api/v1/public/walkers/{walkerId}",
            "requestContext": {"requestId": "r"},
            "pathParameters": {"walkerId": WALKER_ID},
        }
        resp = handler.handler(event, None)
        return resp["statusCode"], json.loads(resp["body"])

    def test_reserved_state_for_bound_unowned(self):
        self._set_device(_device(claimBoundPhone=BOUND_HASH,
                                 claimBoundPhoneMask=BOUND_MASK))
        status, body = self._lookup()
        self.assertEqual(status, 200)
        self.assertEqual(body["status"], "reserved")
        self.assertEqual(body["recipientMask"], BOUND_MASK)
        self.assertNotIn("claimBoundPhone", json.dumps(body))  # never the hash

    def test_unclaimed_for_unbound_unowned(self):
        self._set_device(_device())
        _, body = self._lookup()
        self.assertEqual(body["status"], "unclaimed")

    def test_unowned_discontinued_no_stale_owner_hint(self):
        # Released mid-wipe device: must NOT serve the prior owner's hint.
        self._set_device(_device(status="discontinued", ownerHint="p•••42"))
        _, body = self._lookup()
        self.assertEqual(body["status"], "unclaimed")
        self.assertNotIn("ownerMasked", body)

    def test_claimed_for_owned(self):
        self._set_device(_device(owningClientId="dtc_h1", ownerHint="•••42",
                                 status="active_monitoring"))
        _, body = self._lookup()
        self.assertEqual(body["status"], "claimed")
        self.assertEqual(body["ownerMasked"], "•••42")


if __name__ == "__main__":
    unittest.main()

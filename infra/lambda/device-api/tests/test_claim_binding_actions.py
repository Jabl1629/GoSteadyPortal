"""
Tests for device-api claim-binding actions — d2c-claim-binding.md §5.3 /
§5.9 (spec §8 T4, T9, T11) + fleet-row mask exposure (§5.4).

Run from repo root:
    cd infra/lambda
    python3 -m unittest device-api.tests… (hyphenated dir — run from this dir:)
    cd device-api/tests && python3 -m unittest test_claim_binding_actions
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
_DA_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(_LAMBDA_DIR))
sys.path.insert(0, str(_DA_DIR))

sys.path.insert(0, str(Path(__file__).resolve().parent))
import _stub_powertools  # noqa: F401,E402

os.environ.setdefault("DEVICES_TABLE", "test-devices")
os.environ.setdefault("ASSIGNMENTS_TABLE", "test-assignments")
os.environ.setdefault("PATIENTS_TABLE", "test-patients")
os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")

_spec = importlib.util.spec_from_file_location(
    "device_api_handler", str(_DA_DIR / "handler.py")
)
handler = importlib.util.module_from_spec(_spec)
sys.modules["device_api_handler"] = handler
_spec.loader.exec_module(handler)

from botocore.exceptions import ClientError  # noqa: E402

import _shared.claim_binding as claim_binding  # noqa: E402
from _shared.api_error import ApiError  # noqa: E402

PEPPER = "test-pepper"
SERIAL = "GS0002000001"
PHONE = "+15125550100"
MASK = claim_binding.mask_phone(PHONE)

ADMIN = {
    "userId": "admin-1", "role": "internal_admin", "clientId": "_internal",
    "facilities": [], "censuses": [], "mfaEnrolled": True, "iat": 1,
    "email": "", "name": "", "phoneNumber": "", "phoneNumberVerified": False,
}
CAREGIVER = {
    "userId": "cg-1", "role": "caregiver", "clientId": "client_001",
    "facilities": ["fac_1"], "censuses": ["cen_1"], "mfaEnrolled": False,
    "iat": 1, "email": "", "name": "", "phoneNumber": "",
    "phoneNumberVerified": False,
}


def _cc_failed(op: str = "UpdateItem") -> ClientError:
    return ClientError({"Error": {"Code": "ConditionalCheckFailedException"}}, op)


def _event(body: dict | None = None) -> dict:
    return {"body": json.dumps(body or {}), "requestContext": {"requestId": "r"}}


def _device(**over) -> dict:
    base = {"serialNumber": SERIAL, "status": "ready_to_provision",
            "deviceType": "rollator_platform"}
    base.update(over)
    return base


class ActionTestBase(unittest.TestCase):
    def setUp(self):
        claim_binding._pepper_cache = PEPPER
        self.devices = MagicMock(name="devices")
        self.assignments = MagicMock(name="assignments")
        self.patients = MagicMock(name="patients")
        self.iot = MagicMock(name="iot")
        handler._devices = self.devices
        handler._assignments = self.assignments
        handler._patients = self.patients
        handler.iot_data = self.iot
        self.devices.update_item.return_value = {}


class TestClaimBindingAction(ActionTestBase):
    def test_bind_unowned_sets_hash_and_mask(self):
        self.devices.get_item.return_value = {"Item": _device()}
        resp = handler._action_claim_binding(_event({"phone": PHONE}), ADMIN, SERIAL)
        body = json.loads(resp["body"])
        self.assertEqual(body["device"]["claimBinding"], "set")
        self.assertEqual(body["device"]["claimBoundPhoneMask"], MASK)
        kw = self.devices.update_item.call_args.kwargs
        self.assertIn("attribute_not_exists(owningClientId)", kw["ConditionExpression"])
        # Stored value is the peppered HMAC, never the raw phone.
        self.assertNotIn(PHONE, json.dumps(kw["ExpressionAttributeValues"]))

    def test_t4_bind_owned_409(self):
        self.devices.get_item.return_value = {
            "Item": _device(owningClientId="dtc_h1")
        }
        self.devices.update_item.side_effect = _cc_failed()
        with self.assertRaises(ApiError) as ctx:
            handler._action_claim_binding(_event({"phone": PHONE}), ADMIN, SERIAL)
        self.assertEqual(ctx.exception.code, "DEVICE_OWNED")
        self.assertEqual(ctx.exception.status, 409)

    def test_clear_binding(self):
        self.devices.get_item.return_value = {
            "Item": _device(claimBoundPhone="h", claimBoundPhoneMask=MASK)
        }
        resp = handler._action_claim_binding(_event({"phone": None}), ADMIN, SERIAL)
        body = json.loads(resp["body"])
        self.assertEqual(body["device"]["claimBinding"], "cleared")
        kw = self.devices.update_item.call_args.kwargs
        self.assertIn("REMOVE claimBoundPhone, claimBoundPhoneMask",
                      kw["UpdateExpression"])

    def test_bind_requires_internal_admin(self):
        self.devices.get_item.return_value = {"Item": _device()}
        with self.assertRaises(ApiError) as ctx:
            handler._action_claim_binding(_event({"phone": PHONE}), CAREGIVER, SERIAL)
        self.assertEqual(ctx.exception.code, "INSUFFICIENT_PERMISSIONS")

    def test_bind_garbage_phone_400(self):
        self.devices.get_item.return_value = {"Item": _device()}
        with self.assertRaises(ApiError) as ctx:
            handler._action_claim_binding(_event({"phone": "not-a-phone"}), ADMIN, SERIAL)
        self.assertEqual(ctx.exception.code, "INVALID_REQUEST")


class TestReleaseAndBind(ActionTestBase):
    def test_t9_atomic_single_write(self):
        self.devices.get_item.return_value = {
            "Item": _device(owningClientId="dtc_h1", owningFacilityId="fac_x",
                            status="discontinued")
        }
        resp = handler._action_release_and_bind(_event({"phone": PHONE}), ADMIN, SERIAL)
        body = json.loads(resp["body"])
        self.assertEqual(body["device"]["claimBinding"], "set")
        self.assertIsNone(body["device"]["owningClientId"])
        # ONE write: release + bind in the same conditional update.
        self.assertEqual(self.devices.update_item.call_count, 1)
        kw = self.devices.update_item.call_args.kwargs
        self.assertIn("REMOVE owningClientId, owningFacilityId, ownerHint",
                      kw["UpdateExpression"])
        self.assertIn("claimBoundPhone = :h", kw["UpdateExpression"])
        self.assertIn("attribute_exists(owningClientId)", kw["ConditionExpression"])
        self.assertIn("#status IN (:ready, :disc)", kw["ConditionExpression"])

    def test_t9_condition_fail_unowned_releases_nothing(self):
        self.devices.get_item.side_effect = [
            {"Item": _device(owningClientId="dtc_h1")},  # pre-read
            {"Item": _device()},                          # fresh re-read: unowned
        ]
        self.devices.update_item.side_effect = _cc_failed()
        with self.assertRaises(ApiError) as ctx:
            handler._action_release_and_bind(_event({"phone": PHONE}), ADMIN, SERIAL)
        self.assertEqual(ctx.exception.code, "NOT_OWNED")

    def test_t9_condition_fail_assigned_409(self):
        assigned = _device(owningClientId="dtc_h1", status="active_monitoring")
        self.devices.get_item.side_effect = [
            {"Item": assigned}, {"Item": assigned},
        ]
        self.devices.update_item.side_effect = _cc_failed()
        with self.assertRaises(ApiError) as ctx:
            handler._action_release_and_bind(_event({"phone": PHONE}), ADMIN, SERIAL)
        self.assertEqual(ctx.exception.code, "DEVICE_ASSIGNED")

    def test_phone_required(self):
        self.devices.get_item.return_value = {
            "Item": _device(owningClientId="dtc_h1")
        }
        with self.assertRaises(ApiError) as ctx:
            handler._action_release_and_bind(_event({}), ADMIN, SERIAL)
        self.assertEqual(ctx.exception.code, "INVALID_REQUEST")


class TestProvisionReservedGuard(ActionTestBase):
    def _provision(self, device, claims=ADMIN):
        self.patients.get_item.return_value = {"Item": {
            "patientId": "pat_1", "clientId": "client_001",
            "facilityId": "fac_1", "censusId": "cen_1",
        }}
        self.devices.get_item.return_value = {"Item": device}
        return handler._action_provision(
            _event({"patientId": "pat_1"}), claims, SERIAL
        )

    def test_t11_bound_unowned_device_reserved(self):
        with self.assertRaises(ApiError) as ctx:
            self._provision(_device(claimBoundPhone="somehash",
                                    claimBoundPhoneMask=MASK))
        self.assertEqual(ctx.exception.code, "DEVICE_RESERVED")
        self.assertEqual(ctx.exception.status, 409)
        self.devices.update_item.assert_not_called()

    def test_t11_applies_to_internal_admin_too(self):
        # No provision-through override — clear the binding first (D12).
        with self.assertRaises(ApiError) as ctx:
            self._provision(_device(claimBoundPhone="somehash"), claims=ADMIN)
        self.assertEqual(ctx.exception.code, "DEVICE_RESERVED")

    def test_unbound_provision_has_race_guard_condition(self):
        resp = self._provision(_device())
        self.assertEqual(resp["statusCode"], 200)
        step1b = [
            c for c in self.devices.update_item.call_args_list
            if "ConditionExpression" in c.kwargs
        ][0]
        self.assertIn("attribute_not_exists(claimBoundPhone)",
                      step1b.kwargs["ConditionExpression"])


class TestFleetRowMask(unittest.TestCase):
    def test_mask_kept_hash_never_present(self):
        row = handler._fleet_row(
            {"serialNumber": SERIAL, "status": "ready_to_provision",
             "claimBoundPhone": "deadbeef", "claimBoundPhoneMask": MASK},
            None, None,
        )
        self.assertEqual(row["claimBoundPhoneMask"], MASK)
        self.assertNotIn("claimBoundPhone", row)


class TestRouting(unittest.TestCase):
    def test_new_routes_resolve(self):
        for route, expect in [
            ("POST /api/v1/devices/{serial}/claim-binding", "claim_binding"),
            ("POST /api/v1/devices/{serial}/release-and-bind", "release_and_bind"),
        ]:
            action, _ = handler._route({
                "requestContext": {"http": {"method": "POST"}},
                "routeKey": route,
                "pathParameters": {"serial": SERIAL},
            })
            self.assertEqual(action, expect)


if __name__ == "__main__":
    unittest.main()

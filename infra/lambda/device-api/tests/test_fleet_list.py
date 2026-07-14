"""
Unit tests for device-api fleet-list shaping — device fleet ops tooling.

Covers the pure `_fleet_row` shaper (the IO — Shadow get, assignment get — is
done by the caller, so the shaper is offline-testable). Spec:
docs/specs/device-fleet-ops-tooling.md.

Run from repo root:
    cd infra/lambda
    PYTHONPATH=. python3 -m unittest device-api.tests.test_fleet_list
"""

from __future__ import annotations

import os
import sys
import unittest
from pathlib import Path

_LAMBDA_DIR = Path(__file__).resolve().parents[2]
_DA_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(_LAMBDA_DIR))
sys.path.insert(0, str(_DA_DIR))

sys.path.insert(0, str(Path(__file__).resolve().parent))
import _stub_powertools  # noqa: F401,E402

# handler.py reads these env vars + constructs boto3 clients at import time
# (client construction is offline — no AWS call). Set them before import.
os.environ.setdefault("DEVICES_TABLE", "test-devices")
os.environ.setdefault("ASSIGNMENTS_TABLE", "test-assignments")
os.environ.setdefault("PATIENTS_TABLE", "test-patients")
os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")

import importlib  # noqa: E402
handler = importlib.import_module("handler")


def _device(**over):
    base = {
        "serialNumber": "GS0002000001",
        "status": "ready_to_provision",
        "deviceType": "rollator_platform",
        "walkerId": "c7e589c0-eb65-4336-8757-e9182f60f5d5",
        "owningClientId": "dtc_u1",
        "owningFacilityId": "fac_syn",
    }
    base.update(over)
    return base


class TestFleetRow(unittest.TestCase):
    def test_keeps_lifecycle_fields_and_defaults_type(self):
        # Legacy row with no deviceType → DEFAULT_TYPE (DT-0 D9).
        row = handler._fleet_row(
            {"serialNumber": "GS0000000001", "status": "provisioned"}, None, None
        )
        self.assertEqual(row["serialNumber"], "GS0000000001")
        self.assertEqual(row["status"], "provisioned")
        self.assertEqual(row["deviceType"], handler.DEFAULT_TYPE)
        self.assertNotIn("telemetry", row)
        self.assertNotIn("currentAssignment", row)

    def test_wipe_pending_flag(self):
        dev = _device(status="discontinued",
                      outstandingWipeCmds={"wipe_1": "2026-07-12T00:00:00Z"})
        row = handler._fleet_row(dev, None, None)
        self.assertTrue(row["wipePending"])
        self.assertFalse(row["activationPending"])

    def test_activation_pending_only_when_provisioned(self):
        # Outstanding activation but already active_monitoring is NOT "stuck".
        active = _device(status="active_monitoring",
                         outstandingActivationCmds={"act_1": "t"})
        self.assertFalse(handler._fleet_row(active, None, None)["activationPending"])
        # Still provisioned with an outstanding activate → stuck signal.
        prov = _device(status="provisioned",
                       outstandingActivationCmds={"act_1": "t"})
        self.assertTrue(handler._fleet_row(prov, None, None)["activationPending"])

    def test_joins_telemetry_and_assignment(self):
        tele = {"batteryPct": "0.87", "lastSeen": "2026-07-12T12:00:00Z",
                "wipeComplete": "wipe_abc"}
        asg = {"patientId": "p1", "facilityId": "f1", "censusId": "c1",
               "startedAt": "2026-07-11T00:00:00Z"}
        row = handler._fleet_row(_device(status="active_monitoring"), tele, asg)
        self.assertEqual(row["telemetry"]["batteryPct"], "0.87")
        self.assertEqual(row["telemetry"]["wipeComplete"], "wipe_abc")
        self.assertEqual(row["currentAssignment"]["patientId"], "p1")

    def test_drops_internal_only_fields(self):
        # currentAssignmentSk / certFingerprint / outstanding maps are internal;
        # the outstanding maps ARE surfaced (raw) but the SK/fingerprint aren't.
        dev = _device(currentAssignmentSk="2026-07-11T00:00:00Z",
                      certFingerprint="abc123", createdBy="internal_u")
        row = handler._fleet_row(dev, None, None)
        self.assertNotIn("currentAssignmentSk", row)
        self.assertNotIn("certFingerprint", row)
        self.assertNotIn("createdBy", row)
        # outstanding maps are present (empty) so the CLI can compute age.
        self.assertEqual(row["outstandingWipeCmds"], {})
        self.assertEqual(row["outstandingActivationCmds"], {})


if __name__ == "__main__":
    unittest.main()

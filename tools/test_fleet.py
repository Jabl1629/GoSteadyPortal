"""
Unit tests for the fleet CLI's pure gates — the operator-critical logic
(pre-ship check + ready-for-next-user, with a fixed `now` so age math is
deterministic). Spec: docs/specs/device-fleet-ops-tooling.md.

Run from repo root:
    python3 -m unittest tools.test_fleet
or: cd tools && python3 -m unittest test_fleet
"""

from __future__ import annotations

import sys
import unittest
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import fleet  # noqa: E402

NOW = datetime(2026, 7, 12, 12, 0, 0, tzinfo=timezone.utc)


def _ok(checks):
    return all(ok for _, ok, _ in checks)


class TestAge(unittest.TestCase):
    def test_recent(self):
        self.assertEqual(fleet.age_seconds("2026-07-12T11:59:00Z", now=NOW), 60)

    def test_none(self):
        self.assertIsNone(fleet.age_seconds(None, now=NOW))

    def test_unparseable(self):
        self.assertIsNone(fleet.age_seconds("not-a-date", now=NOW))

    def test_fmt(self):
        self.assertEqual(fleet.fmt_age(None), "—")
        self.assertEqual(fleet.fmt_age(45), "45s")
        self.assertEqual(fleet.fmt_age(120), "2m")
        self.assertEqual(fleet.fmt_age(7200), "2h")
        self.assertEqual(fleet.fmt_age(172800), "2d")


class TestShapeRow(unittest.TestCase):
    """--direct's client-side shaper must match the backend _fleet_row contract."""

    def test_defaults_type_and_flags(self):
        row = fleet._shape_row({"serialNumber": "GS1", "status": "provisioned",
                                "outstandingActivationCmds": {"act_1": "t"}}, None, None)
        self.assertEqual(row["deviceType"], "walker_cap")
        self.assertTrue(row["activationPending"])   # provisioned + outstanding
        self.assertFalse(row["wipePending"])
        self.assertNotIn("telemetry", row)

    def test_activation_pending_needs_provisioned(self):
        row = fleet._shape_row({"serialNumber": "GS1", "status": "active_monitoring",
                                "outstandingActivationCmds": {"act_1": "t"}}, None, None)
        self.assertFalse(row["activationPending"])

    def test_joins_and_drops_internal_fields(self):
        d = {"serialNumber": "GS1", "status": "active_monitoring",
             "currentAssignmentSk": "sk", "certFingerprint": "x"}
        row = fleet._shape_row(d, {"batteryPct": 0.9}, {"patientId": "p1"})
        self.assertEqual(row["telemetry"]["batteryPct"], 0.9)
        self.assertEqual(row["currentAssignment"]["patientId"], "p1")
        self.assertNotIn("currentAssignmentSk", row)
        self.assertNotIn("certFingerprint", row)


class TestPreShipCheck(unittest.TestCase):
    def _fresh_ready(self, **over):
        row = {
            "serialNumber": "GS0002000001",
            "status": "ready_to_provision",
            "deviceType": "rollator_platform",
            "walkerId": "w1",
            "telemetry": {"batteryPct": "0.9", "lastSeen": "2026-07-12T11:30:00Z"},
        }
        row.update(over)
        return row

    def test_healthy_passes(self):
        self.assertTrue(_ok(fleet.check_assertions(self._fresh_ready(), now=NOW)))

    def test_wrong_type_fails(self):
        checks = fleet.check_assertions(self._fresh_ready(), expect_type="walker_cap", now=NOW)
        self.assertFalse(_ok(checks))

    def test_never_connected_fails(self):
        row = self._fresh_ready()
        row["telemetry"] = {}
        self.assertFalse(_ok(fleet.check_assertions(row, now=NOW)))

    def test_stale_lastseen_fails(self):
        row = self._fresh_ready()
        row["telemetry"] = {"batteryPct": "0.9", "lastSeen": "2026-07-01T00:00:00Z"}
        self.assertFalse(_ok(fleet.check_assertions(row, now=NOW)))

    def test_not_ready_status_fails(self):
        self.assertFalse(_ok(fleet.check_assertions(self._fresh_ready(status="provisioned"), now=NOW)))


class TestReadyForNextUser(unittest.TestCase):
    def _recycled(self, **over):
        row = {
            "serialNumber": "GS0002000001",
            "status": "ready_to_provision",
            "owningClientId": "dtc_u1",          # previously owned → wipe must verify
            "wipePending": False,
            "activationPending": False,
            "telemetry": {
                "batteryPct": "0.8",
                "lastSeen": "2026-07-12T11:45:00Z",
                "wipeComplete": "wipe_abc",
            },
        }
        row.update(over)
        return row

    def test_recycled_and_verified_passes(self):
        self.assertTrue(_ok(fleet.ready_assertions(self._recycled(), now=NOW)))

    def test_wipe_pending_fails(self):
        r = self._recycled(status="discontinued", wipePending=True)
        self.assertFalse(_ok(fleet.ready_assertions(r, now=NOW)))

    def test_owned_but_wipe_unverified_fails(self):
        # The core guard: owned unit back in ready state but no wipe_complete →
        # do NOT hand to the next user (might still hold prior data).
        r = self._recycled()
        r["telemetry"] = dict(r["telemetry"])
        r["telemetry"].pop("wipeComplete")
        self.assertFalse(_ok(fleet.ready_assertions(r, now=NOW)))

    def test_fresh_never_owned_skips_wipe_check(self):
        # A brand-new never-provisioned unit has no wipe_complete and is safe.
        r = self._recycled(owningClientId=None)
        r["telemetry"] = dict(r["telemetry"])
        r["telemetry"].pop("wipeComplete")
        self.assertTrue(_ok(fleet.ready_assertions(r, now=NOW)))

    def test_low_battery_fails(self):
        r = self._recycled()
        r["telemetry"] = dict(r["telemetry"])
        r["telemetry"]["batteryPct"] = "0.05"
        self.assertFalse(_ok(fleet.ready_assertions(r, now=NOW)))


if __name__ == "__main__":
    unittest.main()

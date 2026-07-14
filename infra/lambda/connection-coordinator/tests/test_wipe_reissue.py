"""
Tests for the coordinator wipe re-issue — d2c-claim-binding.md §5.6
(spec §8 T13): a still-`discontinued` device whose wipe cmd was swept
(>24h un-acked) gets a FRESH wipe minted on its next connect instead of
being stranded unclaimable.

Run:
    cd infra/lambda/connection-coordinator/tests
    python3 -m unittest test_wipe_reissue
"""

from __future__ import annotations

import importlib.util
import json
import os
import sys
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest.mock import MagicMock

_LAMBDA_DIR = Path(__file__).resolve().parents[2]
_CC_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(_LAMBDA_DIR))
sys.path.insert(0, str(_CC_DIR))

sys.path.insert(0, str(Path(__file__).resolve().parent))
import _stub_powertools  # noqa: F401,E402

os.environ.setdefault("DEVICE_TABLE", "test-devices")
os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")

_spec = importlib.util.spec_from_file_location(
    "coordinator_handler", str(_CC_DIR / "handler.py")
)
handler = importlib.util.module_from_spec(_spec)
sys.modules["coordinator_handler"] = handler
_spec.loader.exec_module(handler)

SERIAL = "GS0002000001"


def _iso(dt: datetime) -> str:
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


def _connect_event() -> dict:
    return {"clientId": SERIAL, "timestamp": 1779040000000,
            "eventType": "connected"}


class CoordinatorTestBase(unittest.TestCase):
    def setUp(self):
        self.tbl = MagicMock(name="device_tbl")
        self.iot = MagicMock(name="iot_data")
        handler._device_tbl = self.tbl
        handler._iot_data = self.iot
        self.tbl.update_item.return_value = {}
        self.now = datetime.now(timezone.utc)

    def _set_device(self, item: dict):
        self.tbl.get_item.return_value = {"Item": item}

    def _wipe_publishes(self):
        return [
            json.loads(c.kwargs["payload"])
            for c in self.iot.publish.call_args_list
            if json.loads(c.kwargs["payload"])["cmd"] == "wipe"
        ]


class TestWipeReissue(CoordinatorTestBase):
    def test_t13_stale_wipe_swept_then_reissued(self):
        stale = _iso(self.now - timedelta(hours=30))
        self._set_device({
            "serialNumber": SERIAL, "status": "discontinued",
            "outstandingWipeCmds": {"wipe_old": stale},
        })
        out = handler.handler(_connect_event(), None)
        # Old entry swept…
        self.assertEqual([s["cmd_id"] for s in out["swept"]], ["wipe_old"])
        # …and a FRESH wipe minted: registry entry + Shadow + publish.
        self.assertIsNotNone(out["reissuedWipeId"])
        new_id = out["reissuedWipeId"]
        self.assertTrue(new_id.startswith("wipe_"))
        self.assertNotEqual(new_id, "wipe_old")
        published = self._wipe_publishes()
        self.assertEqual(len(published), 1)
        self.assertEqual(published[0]["cmd_id"], new_id)
        shadow_calls = self.iot.update_thing_shadow.call_args_list
        self.assertEqual(len(shadow_calls), 1)
        shadow = json.loads(shadow_calls[0].kwargs["payload"].decode())
        self.assertEqual(shadow["state"]["desired"]["wipe_requested"], new_id)

    def test_t13_stranded_empty_map_reissued(self):
        # Stranded by an earlier sweep (pre-§5.6 behavior): discontinued
        # with NO outstanding wipe at all.
        self._set_device({
            "serialNumber": SERIAL, "status": "discontinued",
            "outstandingWipeCmds": {},
        })
        out = handler.handler(_connect_event(), None)
        self.assertIsNotNone(out["reissuedWipeId"])
        self.assertEqual(len(self._wipe_publishes()), 1)

    def test_live_wipe_republished_not_reissued(self):
        fresh = _iso(self.now - timedelta(hours=2))
        self._set_device({
            "serialNumber": SERIAL, "status": "discontinued",
            "outstandingWipeCmds": {"wipe_live": fresh},
        })
        out = handler.handler(_connect_event(), None)
        self.assertIsNone(out["reissuedWipeId"])
        self.assertEqual([r["cmd_id"] for r in out["republished"]], ["wipe_live"])
        published = self._wipe_publishes()
        self.assertEqual(len(published), 1)  # the republish only
        self.assertEqual(published[0]["cmd_id"], "wipe_live")

    def test_non_discontinued_never_reissues(self):
        stale = _iso(self.now - timedelta(hours=30))
        for status in ("ready_to_provision", "provisioned", "active_monitoring",
                       "decommissioned"):
            self.iot.reset_mock()
            self._set_device({
                "serialNumber": SERIAL, "status": status,
                "outstandingWipeCmds": {"wipe_old": stale},
            })
            out = handler.handler(_connect_event(), None)
            self.assertIsNone(out["reissuedWipeId"], status)
            self.assertEqual(self._wipe_publishes(), [], status)

    def test_stale_activation_sweep_untouched_by_reissue(self):
        # Regression guard: activation sweeps behave exactly as before.
        stale = _iso(self.now - timedelta(hours=30))
        self._set_device({
            "serialNumber": SERIAL, "status": "provisioned",
            "outstandingActivationCmds": {"act_old": stale},
        })
        out = handler.handler(_connect_event(), None)
        self.assertEqual([s["cmd_id"] for s in out["swept"]], ["act_old"])
        self.assertIsNone(out["reissuedWipeId"])
        self.assertEqual(self.iot.publish.call_count, 0)


if __name__ == "__main__":
    unittest.main()

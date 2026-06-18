"""
Unit tests for _shared/device_time.py — device time-reliability (coord §C47,
spec 2026-06-18-device-time-reliability.md).

Run from `infra/lambda/`:
    PYTHONPATH=. python3 -m unittest _shared.tests.test_device_time
"""

from __future__ import annotations

import sys
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

_LAMBDA_DIR = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(_LAMBDA_DIR))

sys.path.insert(0, str(Path(__file__).resolve().parent))
import _stub_powertools  # noqa: F401,E402

from _shared.device_time import (  # noqa: E402
    TIME_SOURCE_DEVICE,
    TIME_SOURCE_RECONSTRUCTED,
    TIME_SOURCE_UNCERTAIN,
    parse_iso,
    resolve_heartbeat_ts,
    resolve_session_times,
    year_plausible,
)

# A fixed "now" (server receive time) for deterministic reconstruction asserts.
INGEST = datetime(2026, 6, 18, 16, 10, 43, tzinfo=timezone.utc)


def _dt(s: str) -> datetime:
    return datetime.fromisoformat(s.replace("Z", "+00:00"))


class TestYearPlausible(unittest.TestCase):
    def test_window(self):
        self.assertTrue(year_plausible(_dt("2024-01-01T00:00:00Z")))
        self.assertTrue(year_plausible(_dt("2026-06-18T16:00:00Z")))
        self.assertTrue(year_plausible(_dt("2050-12-31T23:59:59Z")))
        self.assertFalse(year_plausible(_dt("2023-12-31T23:59:59Z")))
        self.assertFalse(year_plausible(_dt("2051-01-01T00:00:00Z")))
        self.assertFalse(year_plausible(_dt("1980-01-06T00:00:00Z")))
        self.assertFalse(year_plausible(_dt("2080-01-05T00:00:00Z")))
        self.assertFalse(year_plausible(None))


class TestParseIso(unittest.TestCase):
    def test_valid_and_invalid(self):
        self.assertEqual(parse_iso("2026-06-18T16:09:48Z"), _dt("2026-06-18T16:09:48Z"))
        self.assertIsNone(parse_iso(""))
        self.assertIsNone(parse_iso(None))
        self.assertIsNone(parse_iso("not-a-date"))
        self.assertIsNone(parse_iso(123))
        # naive -> assumed UTC
        self.assertEqual(parse_iso("2026-06-18T16:09:48").tzinfo, timezone.utc)


class TestResolveSessionTimes(unittest.TestCase):
    def test_device_authoritative_synced(self):
        ev = {
            "session_start": "2026-06-18T16:09:48Z",
            "session_end": "2026-06-18T16:10:37Z",
            "clock_synced": True,
            "time_source": "nitz",
        }
        ss, se, src = resolve_session_times(ev, INGEST)
        self.assertEqual(ss, _dt("2026-06-18T16:09:48Z"))
        self.assertEqual(se, _dt("2026-06-18T16:10:37Z"))
        self.assertEqual(src, "nitz")

    def test_old_firmware_no_flag_plausible(self):
        # Pre-0.17 firmware: no clock_synced field, plausible device ISO.
        ev = {
            "session_start": "2026-06-18T16:09:48Z",
            "session_end": "2026-06-18T16:10:37Z",
        }
        ss, se, src = resolve_session_times(ev, INGEST)
        self.assertEqual(src, TIME_SOURCE_DEVICE)
        self.assertEqual(ss, _dt("2026-06-18T16:09:48Z"))

    def test_reconstruct_from_uptimes(self):
        # Real bench numbers from the GS0000000001 walk.
        ev = {
            "session_start": "",
            "session_end": "",
            "clock_synced": False,
            "session_start_uptime_ms": 208147,
            "session_end_uptime_ms": 256952,
            "publish_uptime_ms": 256953,
            "boot_count": 22,
        }
        ss, se, src = resolve_session_times(ev, INGEST)
        self.assertEqual(src, TIME_SOURCE_RECONSTRUCTED)
        # age_end = 256953-256952 = 1 ms; age_start = 256953-208147 = 48806 ms
        self.assertAlmostEqual((INGEST - se).total_seconds() * 1000, 1, delta=0.5)
        self.assertAlmostEqual((INGEST - ss).total_seconds() * 1000, 48806, delta=0.5)
        self.assertLessEqual(ss, se)
        self.assertTrue(year_plausible(ss) and year_plausible(se))

    def test_unsynced_missing_uptimes_uncertain_preserves_duration(self):
        # clock_synced=false but no uptimes -> can't reconstruct. Preserve the
        # device-reported 49 s duration, anchored at ingest. Never dropped.
        ev = {
            "session_start": "2080-01-05T00:00:00Z",  # implausible device clock
            "session_end": "2080-01-05T00:00:49Z",
            "clock_synced": False,
        }
        ss, se, src = resolve_session_times(ev, INGEST)
        self.assertEqual(src, TIME_SOURCE_UNCERTAIN)
        self.assertEqual(se, INGEST)
        self.assertEqual((se - ss).total_seconds(), 49)

    def test_legacy_2080_no_uptimes_uncertain(self):
        # Pre-0.17 firmware that emitted 2080 (the actual incident shape): no
        # flag, implausible ISO, no uptimes -> uncertain, anchored at ingest.
        ev = {
            "session_start": "2080-01-05T08:00:00Z",
            "session_end": "2080-01-05T08:01:00Z",
        }
        ss, se, src = resolve_session_times(ev, INGEST)
        self.assertEqual(src, TIME_SOURCE_UNCERTAIN)
        self.assertEqual(se, INGEST)
        self.assertEqual((se - ss).total_seconds(), 60)

    def test_inconsistent_uptimes_fall_to_uncertain(self):
        # session_end_uptime > publish_uptime (uint32 wrap / corruption) ->
        # refuse to reconstruct -> uncertain (not a garbage absolute time).
        ev = {
            "session_start": "",
            "session_end": "",
            "clock_synced": False,
            "session_start_uptime_ms": 100,
            "session_end_uptime_ms": 999999,
            "publish_uptime_ms": 5000,
        }
        _ss, se, src = resolve_session_times(ev, INGEST)
        self.assertEqual(src, TIME_SOURCE_UNCERTAIN)
        self.assertEqual(se, INGEST)

    def test_synced_but_implausible_iso_reconstructs(self):
        # Defensive: device claims synced but ISO is 2080 (firmware bug) and we
        # have uptimes -> reconstruct rather than trust the bad ISO.
        ev = {
            "session_start": "2080-01-05T00:00:00Z",
            "session_end": "2080-01-05T00:00:10Z",
            "clock_synced": True,
            "session_start_uptime_ms": 1000,
            "session_end_uptime_ms": 11000,
            "publish_uptime_ms": 12000,
        }
        _ss, _se, src = resolve_session_times(ev, INGEST)
        self.assertEqual(src, TIME_SOURCE_RECONSTRUCTED)


class TestResolveHeartbeatTs(unittest.TestCase):
    def test_synced_uses_device_ts(self):
        ev = {"ts": "2026-06-18T16:06:29Z", "clock_synced": True}
        ts, used = resolve_heartbeat_ts(ev, INGEST)
        self.assertEqual(ts, _dt("2026-06-18T16:06:29Z"))
        self.assertFalse(used)

    def test_unsynced_substitutes_ingest(self):
        ev = {"clock_synced": False}  # ts omitted by firmware
        ts, used = resolve_heartbeat_ts(ev, INGEST)
        self.assertEqual(ts, INGEST)
        self.assertTrue(used)

    def test_missing_ts_old_firmware_substitutes(self):
        ev = {}  # no ts, no flag
        ts, used = resolve_heartbeat_ts(ev, INGEST)
        self.assertEqual(ts, INGEST)
        self.assertTrue(used)

    def test_implausible_ts_substitutes(self):
        ev = {"ts": "2080-01-05T08:00:00Z"}  # legacy 2080, no flag
        ts, used = resolve_heartbeat_ts(ev, INGEST)
        self.assertEqual(ts, INGEST)
        self.assertTrue(used)


if __name__ == "__main__":
    unittest.main()

"""
Unit tests for _shared/pause_check.py — Phase 2A-UM-P.

Run from `infra/lambda/`:
    PYTHONPATH=. python3 -m unittest _shared.tests.test_pause_check
"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

_LAMBDA_DIR = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(_LAMBDA_DIR))

sys.path.insert(0, str(Path(__file__).resolve().parent))
import _stub_powertools  # noqa: F401,E402

from _shared.pause_check import (  # noqa: E402
    compute_until_epoch,
    days_remaining,
    is_currently_paused,
    seconds_remaining,
)


# Fixed "now" for deterministic time math (avoids leap-second / DST quirks).
NOW = 1_700_000_000
NOW_FN = lambda: NOW  # noqa: E731


def _paused(*, until_offset_secs: int, reason: str = "in_hospital") -> dict:
    """Build a Patient row with a notificationsPaused attribute."""
    return {
        "patientId": "pat_test",
        "notificationsPaused": {
            "until": NOW + until_offset_secs,
            "reason": reason,
            "pausedAt": NOW - 100,
            "pausedBy": "u_test",
        },
    }


# ── is_currently_paused ───────────────────────────────────────────────


class TestIsCurrentlyPaused(unittest.TestCase):
    def test_no_attribute_returns_false(self):
        self.assertFalse(is_currently_paused({"patientId": "pat_x"}, now_fn=NOW_FN))

    def test_attribute_none_returns_false(self):
        self.assertFalse(is_currently_paused({"notificationsPaused": None}, now_fn=NOW_FN))

    def test_attribute_not_dict_returns_false(self):
        # Defensive against malformed DDB data
        self.assertFalse(is_currently_paused({"notificationsPaused": "string"}, now_fn=NOW_FN))
        self.assertFalse(is_currently_paused({"notificationsPaused": []}, now_fn=NOW_FN))

    def test_pause_one_day_future_true(self):
        patient = _paused(until_offset_secs=86400)
        self.assertTrue(is_currently_paused(patient, now_fn=NOW_FN))

    def test_pause_one_second_future_true(self):
        patient = _paused(until_offset_secs=1)
        self.assertTrue(is_currently_paused(patient, now_fn=NOW_FN))

    def test_pause_expired_one_second_false(self):
        patient = _paused(until_offset_secs=-1)
        self.assertFalse(is_currently_paused(patient, now_fn=NOW_FN))

    def test_pause_expired_day_false(self):
        patient = _paused(until_offset_secs=-86400)
        self.assertFalse(is_currently_paused(patient, now_fn=NOW_FN))

    def test_pause_until_equals_now_false(self):
        """Boundary: until==now means the pause just expired."""
        patient = _paused(until_offset_secs=0)
        self.assertFalse(is_currently_paused(patient, now_fn=NOW_FN))

    def test_until_missing_returns_false(self):
        patient = {"notificationsPaused": {"reason": "in_hospital"}}
        self.assertFalse(is_currently_paused(patient, now_fn=NOW_FN))

    def test_until_negative_returns_false(self):
        patient = {"notificationsPaused": {"until": -1, "reason": "in_hospital"}}
        self.assertFalse(is_currently_paused(patient, now_fn=NOW_FN))

    def test_until_zero_returns_false(self):
        patient = {"notificationsPaused": {"until": 0, "reason": "in_hospital"}}
        self.assertFalse(is_currently_paused(patient, now_fn=NOW_FN))

    def test_until_unparseable_returns_false(self):
        patient = {"notificationsPaused": {"until": "not-a-number", "reason": "x"}}
        self.assertFalse(is_currently_paused(patient, now_fn=NOW_FN))

    def test_until_as_string_numeric_parses(self):
        """DDB sometimes returns numbers as strings/Decimal — coerce."""
        patient = {"notificationsPaused": {"until": "1700100000", "reason": "x"}}
        self.assertTrue(is_currently_paused(patient, now_fn=NOW_FN))


# ── seconds_remaining ─────────────────────────────────────────────────


class TestSecondsRemaining(unittest.TestCase):
    def test_no_pause_returns_none(self):
        self.assertIsNone(seconds_remaining({"patientId": "pat_x"}, now_fn=NOW_FN))

    def test_expired_returns_none(self):
        patient = _paused(until_offset_secs=-1)
        self.assertIsNone(seconds_remaining(patient, now_fn=NOW_FN))

    def test_one_hour_remaining(self):
        patient = _paused(until_offset_secs=3600)
        self.assertEqual(seconds_remaining(patient, now_fn=NOW_FN), 3600)

    def test_one_day_remaining(self):
        patient = _paused(until_offset_secs=86400)
        self.assertEqual(seconds_remaining(patient, now_fn=NOW_FN), 86400)

    def test_one_second_remaining(self):
        patient = _paused(until_offset_secs=1)
        self.assertEqual(seconds_remaining(patient, now_fn=NOW_FN), 1)

    def test_until_equals_now_returns_none(self):
        patient = _paused(until_offset_secs=0)
        self.assertIsNone(seconds_remaining(patient, now_fn=NOW_FN))


# ── days_remaining ────────────────────────────────────────────────────


class TestDaysRemaining(unittest.TestCase):
    def test_no_pause_returns_none(self):
        self.assertIsNone(days_remaining({}, now_fn=NOW_FN))

    def test_seven_full_days_remaining(self):
        patient = _paused(until_offset_secs=7 * 86400)
        self.assertEqual(days_remaining(patient, now_fn=NOW_FN), 7)

    def test_less_than_one_day_floors_to_zero(self):
        patient = _paused(until_offset_secs=86399)  # 23h 59m 59s
        self.assertEqual(days_remaining(patient, now_fn=NOW_FN), 0)

    def test_one_full_day_returns_one(self):
        patient = _paused(until_offset_secs=86400)
        self.assertEqual(days_remaining(patient, now_fn=NOW_FN), 1)

    def test_90_days_remaining(self):
        patient = _paused(until_offset_secs=90 * 86400)
        self.assertEqual(days_remaining(patient, now_fn=NOW_FN), 90)

    def test_expired_returns_none(self):
        patient = _paused(until_offset_secs=-1)
        self.assertIsNone(days_remaining(patient, now_fn=NOW_FN))


# ── compute_until_epoch ───────────────────────────────────────────────


class TestComputeUntilEpoch(unittest.TestCase):
    def test_one_day(self):
        self.assertEqual(compute_until_epoch(1, now_fn=NOW_FN), NOW + 86400)

    def test_seven_days(self):
        self.assertEqual(compute_until_epoch(7, now_fn=NOW_FN), NOW + 7 * 86400)

    def test_ninety_days(self):
        self.assertEqual(compute_until_epoch(90, now_fn=NOW_FN), NOW + 90 * 86400)

    def test_zero_days_raises(self):
        with self.assertRaises(ValueError):
            compute_until_epoch(0, now_fn=NOW_FN)

    def test_negative_days_raises(self):
        with self.assertRaises(ValueError):
            compute_until_epoch(-1, now_fn=NOW_FN)


if __name__ == "__main__":
    unittest.main()

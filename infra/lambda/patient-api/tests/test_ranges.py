"""
Unit tests for patient-api range helpers — Phase 2A-RD.

Run from `infra/lambda/`:
    PYTHONPATH=. python3 -m unittest patient-api.tests.test_ranges
"""

from __future__ import annotations

import sys
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

_LAMBDA_DIR = Path(__file__).resolve().parents[2]
_PA_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(_LAMBDA_DIR))
sys.path.insert(0, str(_PA_DIR))

sys.path.insert(0, str(Path(__file__).resolve().parent))
import _stub_powertools  # noqa: F401,E402

import importlib  # noqa: E402
ranges = importlib.import_module("ranges")
from _shared.api_error import ApiError  # noqa: E402


class TestParseRange(unittest.TestCase):
    def test_none_returns_default_24h(self):
        self.assertEqual(ranges.parse_range(None), "24h")

    def test_empty_returns_default_24h(self):
        self.assertEqual(ranges.parse_range(""), "24h")

    def test_valid_24h(self):
        self.assertEqual(ranges.parse_range("24h"), "24h")

    def test_valid_7d(self):
        self.assertEqual(ranges.parse_range("7d"), "7d")

    def test_valid_30d(self):
        self.assertEqual(ranges.parse_range("30d"), "30d")

    def test_invalid_90d_raises_with_suggestion(self):
        with self.assertRaises(ApiError) as cm:
            ranges.parse_range("90d")
        self.assertEqual(cm.exception.code, "INVALID_RANGE")
        self.assertEqual(cm.exception.status, 400)
        self.assertIn("suggestion", cm.exception.details)
        self.assertIn("Phase 1C", cm.exception.details["suggestion"])

    def test_invalid_gibberish(self):
        with self.assertRaises(ApiError):
            ranges.parse_range("yesterday")


class TestRangeToWindow(unittest.TestCase):
    def setUp(self):
        # Fixed reference time for deterministic tests.
        self.now = datetime(2026, 5, 23, 14, 30, 45, tzinfo=timezone.utc)

    def test_24h_window(self):
        start, end = ranges.range_to_window("24h", now=self.now)
        self.assertEqual(end, "2026-05-23T14:30:45Z")
        self.assertEqual(start, "2026-05-22T14:30:45Z")

    def test_7d_window(self):
        start, end = ranges.range_to_window("7d", now=self.now)
        self.assertEqual(end, "2026-05-23T14:30:45Z")
        self.assertEqual(start, "2026-05-16T14:30:45Z")

    def test_30d_window(self):
        start, end = ranges.range_to_window("30d", now=self.now)
        self.assertEqual(end, "2026-05-23T14:30:45Z")
        self.assertEqual(start, "2026-04-23T14:30:45Z")

    def test_iso_format_no_microseconds(self):
        start, end = ranges.range_to_window("24h", now=self.now)
        # Bare-second precision, trailing Z.
        self.assertRegex(start, r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")
        self.assertRegex(end, r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")

    def test_iso_format_naive_input_treated_as_utc(self):
        naive = datetime(2026, 5, 23, 14, 30, 45)  # tz-naive
        start, end = ranges.range_to_window("24h", now=naive)
        self.assertEqual(end, "2026-05-23T14:30:45Z")

    def test_unknown_range_raises_defensive(self):
        with self.assertRaises(ApiError) as cm:
            ranges.range_to_window("forever", now=self.now)
        self.assertEqual(cm.exception.code, "INVALID_RANGE")


class TestNowIso(unittest.TestCase):
    def test_iso_format(self):
        n = ranges.now_iso()
        self.assertRegex(n, r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")


if __name__ == "__main__":
    unittest.main()

"""
Digest tests — AI Coach C1 §5.4 / §8 T1. Code computes every number the coach
may cite; the allow-list is what the output lint permits. Keyed on
activeMinutes so rollator rows (no steps) work.

    cd infra/lambda && python3 -m pytest coach-api/tests/test_digest.py -q
"""
from __future__ import annotations

import sys
import unittest
from datetime import datetime, timezone
from pathlib import Path

_LAMBDA_DIR = Path(__file__).resolve().parents[2]
_COACH_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(_LAMBDA_DIR))
sys.path.insert(0, str(_COACH_DIR))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import _stub_powertools  # noqa: F401,E402

from digest import build_digest  # noqa: E402

NOW = datetime(2026, 7, 18, 12, 0, 0, tzinfo=timezone.utc)


def _row(date: str, mins: int) -> dict:
    # Rollator-shaped row: activeMinutes present, NO steps.
    return {"date": date, "activeMinutes": mins}


class DigestTest(unittest.TestCase):
    def test_aggregates_and_allowlist(self):
        history = [
            _row("2026-07-17", 22),  # yesterday
            _row("2026-07-16", 18),
            _row("2026-07-15", 10),
            _row("2026-06-20", 40),  # inside 30d, outside 7d
        ]
        today = [{"activeMinutes": 5}]
        dig = build_digest(today, history, tz_name="UTC", now=NOW)
        self.assertIn("22", dig.allowlist)     # yesterday
        self.assertIn("50", dig.allowlist)     # last7 = 22+18+10
        self.assertIn("90", dig.allowlist)     # last30 = 22+18+10+40
        self.assertIn("7", dig.allowlist)      # literal from "Last 7 days"
        self.assertIn("30", dig.allowlist)     # literal from "Last 30 days"
        self.assertIn("22", dig.text)
        self.assertTrue(dig.has_history)       # 3+ active days ≥ MIN_ACTIVE_DAYS

    def test_streak_includes_today(self):
        history = [_row("2026-07-17", 20), _row("2026-07-16", 15), _row("2026-07-14", 10)]
        today = [{"activeMinutes": 8}]
        dig = build_digest(today, history, tz_name="UTC", now=NOW)
        # 07-17,07-16 consecutive (07-15 is 0 → break), + today → streak 3
        self.assertIn("3", dig.allowlist)

    def test_cold_start_marks_general(self):
        dig = build_digest([], [_row("2026-07-17", 12)], tz_name="UTC", now=NOW)
        self.assertFalse(dig.has_history)  # only 1 active day
        self.assertIn("just getting started", dig.text)

    def test_bad_rows_skipped(self):
        history = [{"activeMinutes": "oops"}, {"noDate": True}, _row("2026-07-17", 9)]
        dig = build_digest([], history, tz_name="UTC", now=NOW)
        self.assertIn("9", dig.allowlist)  # only the valid row counted


if __name__ == "__main__":
    unittest.main()

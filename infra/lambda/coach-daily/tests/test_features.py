"""
Feature-aggregation tests — AI Coach C2. Keyed on activeMinutes (rollator rows
have no steps). Mirrors coach-api's digest test.

    cd infra/lambda && python3 -m pytest coach-daily/tests/test_features.py -q
"""
from __future__ import annotations

import sys
import unittest
from datetime import datetime, timezone
from pathlib import Path

_LAMBDA_DIR = Path(__file__).resolve().parents[2]
_CD_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(_LAMBDA_DIR))
sys.path.insert(0, str(_CD_DIR))

from features import compute_features, local_now_iso  # noqa: E402

NOW = datetime(2026, 7, 19, 13, 0, 0, tzinfo=timezone.utc)


def _row(d: str, m: int) -> dict:
    return {"date": d, "activeMinutes": m}  # rollator-shaped: no steps


class FeaturesTest(unittest.TestCase):
    def test_aggregates(self):
        history = [_row("2026-07-18", 20), _row("2026-07-17", 18), _row("2026-07-11", 30)]
        today = [{"activeMinutes": 8}]
        f = compute_features(today, history, now=NOW)
        self.assertEqual(f.today, 8)
        self.assertEqual(f.yesterday, 20)
        self.assertEqual(f.best, 30)
        self.assertEqual(f.last30, 68)       # 20+18+30
        self.assertEqual(f.active_days, 3)
        self.assertEqual(f.streak, 3)         # 07-18, 07-17 (07-16 zero) + today

    def test_bad_rows_skipped(self):
        f = compute_features([], [{"activeMinutes": "x"}, {"noDate": 1}, _row("2026-07-18", 9)], now=NOW)
        self.assertEqual(f.yesterday, 9)

    def test_local_now_iso_has_offset_colon(self):
        self.assertTrue(local_now_iso(NOW).endswith("+00:00"))


if __name__ == "__main__":
    unittest.main()

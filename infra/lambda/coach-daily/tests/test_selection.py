"""
Selection tests — AI Coach C2 §8 T2. ≤1 theme/day by priority; silence on a
quiet day; recap only on the recap day.

    cd infra/lambda && python3 -m pytest coach-daily/tests/test_selection.py -q
"""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

_LAMBDA_DIR = Path(__file__).resolve().parents[2]
_CD_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(_LAMBDA_DIR))
sys.path.insert(0, str(_CD_DIR))

from features import Features  # noqa: E402
from selection import select_theme  # noqa: E402
from rules.types import THEME_ABOVE_TYPICAL, THEME_STREAK_MILESTONE, THEME_WEEKLY_RECAP  # noqa: E402

ISO = "2026-07-19T13:00:00+00:00"


def _feat(**over) -> Features:
    base = dict(
        today=0, yesterday=10, per_day=tuple([10] * 30), last7=70, last30=300,
        best=20, streak=0, active_days=30, median7=10, median_prior23=10,
        device_type="walker_cap", local_now_iso=ISO,
    )
    base.update(over)
    return Features(**base)


class SelectionTest(unittest.TestCase):
    def test_quiet_day_is_silent(self):
        # typical day, nothing special → no theme
        self.assertIsNone(select_theme(_feat(today=10, median7=10)))

    def test_celebrate_beats_encourage(self):
        # both above-typical (celebrate) and improving (encourage) fire → celebrate wins
        f = _feat(today=50, median7=20, median_prior23=10)
        t = select_theme(f)
        self.assertIsNotNone(t)
        self.assertEqual(t.priority, 40)  # PRIORITY_CELEBRATE

    def test_streak_beats_above_typical_same_priority(self):
        # both celebrate-tier; streak wins the deterministic tie-break
        f = _feat(today=50, median7=10, streak=7)
        self.assertEqual(select_theme(f).theme_type, THEME_STREAK_MILESTONE)

    def test_recap_only_on_recap_day(self):
        f = _feat(today=10, median7=10)  # nothing else fires
        self.assertIsNone(select_theme(f, is_recap_day=False))
        self.assertEqual(select_theme(f, is_recap_day=True).theme_type, THEME_WEEKLY_RECAP)

    def test_celebrate_beats_recap(self):
        f = _feat(today=50, median7=10)
        self.assertEqual(select_theme(f, is_recap_day=True).theme_type, THEME_ABOVE_TYPICAL)


if __name__ == "__main__":
    unittest.main()

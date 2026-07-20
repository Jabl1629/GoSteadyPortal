"""
Theme-evaluator tests — AI Coach C2 §8 T1. Positive/gentle themes fire on the
right features and respect the cold-start guard.

    cd infra/lambda && python3 -m pytest coach-daily/tests/test_themes.py -q
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
from rules import themes  # noqa: E402

ISO = "2026-07-19T13:00:00+00:00"


def _feat(**over) -> Features:
    base = dict(
        today=0, yesterday=10, per_day=tuple([10] * 30), last7=70, last30=300,
        best=20, streak=0, active_days=30, median7=10, median_prior23=10,
        device_type="rollator_platform", local_now_iso=ISO,
    )
    base.update(over)
    return Features(**base)


class ThemeTest(unittest.TestCase):
    def test_above_typical_fires_and_respects_cold_start(self):
        self.assertIsNotNone(themes.eval_above_typical(_feat(today=50, median7=10)))
        self.assertIsNone(themes.eval_above_typical(_feat(today=11, median7=10)))  # +10% < +25%
        self.assertIsNone(themes.eval_above_typical(_feat(today=50, median7=10, active_days=5)))  # cold start

    def test_improving_trend(self):
        self.assertIsNotNone(themes.eval_improving_trend(_feat(median7=20, median_prior23=10)))
        self.assertIsNone(themes.eval_improving_trend(_feat(median7=11, median_prior23=10)))  # +10% < +15%

    def test_streak_milestone(self):
        self.assertIsNotNone(themes.eval_streak_milestone(_feat(streak=7)))
        self.assertIsNone(themes.eval_streak_milestone(_feat(streak=6)))  # not a milestone

    def test_quiet_nudge(self):
        # today 0 + two trailing zero days = 3 quiet ≥ 2 threshold
        f = _feat(today=0, per_day=tuple([10] * 28 + [0, 0]))
        self.assertIsNotNone(themes.eval_quiet_nudge(f))
        # one quiet day only → no nudge
        f2 = _feat(today=0, per_day=tuple([10] * 29 + [5]))
        self.assertIsNone(themes.eval_quiet_nudge(f2))
        # offline device → never nudge
        self.assertIsNone(themes.eval_quiet_nudge(f, device_online=False))

    def test_weekly_recap(self):
        self.assertIsNotNone(themes.eval_weekly_recap(_feat(last7=120, best=40)))
        self.assertIsNone(themes.eval_weekly_recap(_feat(active_days=0)))

    def test_theme_data_are_ints_for_allowlist(self):
        t = themes.eval_above_typical(_feat(today=50, median7=10))
        self.assertTrue(all(isinstance(v, int) for v in t.data.values()))


if __name__ == "__main__":
    unittest.main()

"""
Unit tests for the daily-cadence day anchor — `history_window.local_day_anchor_iso`.

This helper is what makes `no_activity_today` / `below_typical_activity` /
`declining_trend` genuinely once-per-day: it is the `eventTimestamp` half of
their Alert History sort key, so it MUST be identical for every evaluation
within one facility-local day. The prior implementation stamped local-now to
the second, which could never collide and so provided no dedupe at all.

Run from `infra/lambda/`:
    PYTHONPATH=. python3 -m unittest discover behavioral-detector/tests
"""

from __future__ import annotations

import sys
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

_LAMBDA_DIR = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(_LAMBDA_DIR))
_HANDLER_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(_HANDLER_DIR))

sys.path.insert(0, str(Path(__file__).resolve().parent))
import _stub_powertools  # noqa: F401,E402

from history_window import local_day_anchor_iso  # noqa: E402


DENVER = ZoneInfo("America/Denver")
LA = ZoneInfo("America/Los_Angeles")


class TestLocalDayAnchorIso(unittest.TestCase):

    def test_returns_local_midnight_with_offset(self):
        self.assertEqual(
            local_day_anchor_iso(datetime(2026, 7, 27, 11, 4, 33, tzinfo=DENVER)),
            "2026-07-27T00:00:00-06:00",
        )

    def test_stable_across_every_hour_of_the_local_day(self):
        """The whole point: one key per local day, whenever we evaluate."""
        anchors = {
            local_day_anchor_iso(datetime(2026, 7, 27, h, m, s, tzinfo=DENVER))
            for h in range(24)
            for m in (0, 59)
            for s in (0, 59)
        }
        self.assertEqual(anchors, {"2026-07-27T00:00:00-06:00"})

    def test_distinct_keys_on_consecutive_days(self):
        day1 = local_day_anchor_iso(datetime(2026, 7, 27, 11, 0, tzinfo=DENVER))
        day2 = local_day_anchor_iso(datetime(2026, 7, 28, 11, 0, tzinfo=DENVER))
        self.assertNotEqual(day1, day2)

    def test_second_precision_is_gone(self):
        """Regression guard for the bug this replaced — two evaluations a few
        minutes apart used to produce two different SKs, so the conditional
        PutItem never collided and both rows were written."""
        a = local_day_anchor_iso(datetime(2026, 7, 27, 11, 0, 5, tzinfo=DENVER))
        b = local_day_anchor_iso(datetime(2026, 7, 27, 11, 4, 51, tzinfo=DENVER))
        self.assertEqual(a, b)

    def test_utc_facility(self):
        self.assertEqual(
            local_day_anchor_iso(datetime(2026, 7, 27, 11, 0, tzinfo=timezone.utc)),
            "2026-07-27T00:00:00+00:00",
        )

    # ── DST days ──────────────────────────────────────────────────────
    #
    # The anchor must stay stable across a transition day even though
    # local_now's UTC offset changes partway through it. ZoneInfo resolves
    # the offset from the wall-clock fields, so midnight keeps the
    # pre-transition offset all day (US transitions happen at ~02:00 local,
    # after midnight).

    def test_spring_forward_day_anchor_is_stable(self):
        """2026-03-08, US spring forward: -08:00 → -07:00 at 02:00 local."""
        before = local_day_anchor_iso(datetime(2026, 3, 8, 1, 30, tzinfo=LA))
        after = local_day_anchor_iso(datetime(2026, 3, 8, 11, 30, tzinfo=LA))
        self.assertEqual(before, after)
        self.assertEqual(before, "2026-03-08T00:00:00-08:00")

    def test_fall_back_day_anchor_is_stable(self):
        """2026-11-01, US fall back: -07:00 → -08:00 at 02:00 local."""
        before = local_day_anchor_iso(datetime(2026, 11, 1, 1, 30, tzinfo=LA))
        after = local_day_anchor_iso(datetime(2026, 11, 1, 11, 30, tzinfo=LA))
        self.assertEqual(before, after)
        self.assertEqual(before, "2026-11-01T00:00:00-07:00")

    def test_anchor_parses_back_to_the_correct_instant(self):
        """`handler._write_alert` does fromisoformat() on this for TTL math."""
        anchor = local_day_anchor_iso(datetime(2026, 7, 27, 11, 0, tzinfo=DENVER))
        parsed = datetime.fromisoformat(anchor)
        self.assertEqual(parsed.utcoffset(), timedelta(hours=-6))
        self.assertEqual(
            parsed.astimezone(timezone.utc),
            datetime(2026, 7, 27, 6, 0, tzinfo=timezone.utc),
        )


if __name__ == "__main__":
    unittest.main()

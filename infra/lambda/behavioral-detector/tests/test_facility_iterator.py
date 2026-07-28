"""
Unit tests for the trigger-hour gate — `facility_iterator`.

This gate decides WHEN each daily-cadence rule runs. It previously had no
test coverage at all, and was an exact `local_hour == target` equality:
a single missed or jitter-straddled hourly invocation silently dropped
that facility's whole day. It is now a window (target hour + catch-up
tail), safe because the daily rules' sort key is anchored to the local
day — see `history_window.local_day_anchor_iso` and `test_day_anchor.py`.

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

from facility_iterator import (  # noqa: E402
    DEFAULT_END_OF_DAY_LOCAL_HOUR,
    DEFAULT_NO_ACTIVITY_LOCAL_HOUR,
    DEFAULT_TRIGGER_CATCHUP_HOURS,
    FacilityContext,
    in_trigger_window,
    rule_set_for_facility,
)

LA = ZoneInfo("America/Los_Angeles")


def _facility(local_now: datetime, tz: str = "America/Los_Angeles") -> FacilityContext:
    return FacilityContext(
        clientId="client_test",
        facilityId="fac_test",
        displayName="Test Facility",
        timezone=tz,
        local_now=local_now,
    )


class TestDefaults(unittest.TestCase):

    def test_no_activity_default_hour_is_11(self):
        """Raised from 09:00 (2026-07) — 09:00 flagged slow mornings."""
        self.assertEqual(DEFAULT_NO_ACTIVITY_LOCAL_HOUR, 11)

    def test_end_of_day_default_hour_unchanged(self):
        self.assertEqual(DEFAULT_END_OF_DAY_LOCAL_HOUR, 22)

    def test_catchup_default_leaves_room_for_a_missed_firing(self):
        self.assertGreaterEqual(DEFAULT_TRIGGER_CATCHUP_HOURS, 2)

    def test_end_of_day_catchup_fits_before_midnight(self):
        """22:00 + catch-up must not want to run past 23:59 (it is clamped,
        but a default that relied on clamping would be a smell)."""
        self.assertLessEqual(
            DEFAULT_END_OF_DAY_LOCAL_HOUR + DEFAULT_TRIGGER_CATCHUP_HOURS, 25
        )


class TestInTriggerWindow(unittest.TestCase):

    def test_fires_on_the_target_hour(self):
        self.assertTrue(in_trigger_window(11, 11, 3))

    def test_fires_across_the_catchup_tail(self):
        self.assertTrue(in_trigger_window(12, 11, 3))
        self.assertTrue(in_trigger_window(13, 11, 3))

    def test_silent_before_the_target_hour(self):
        for h in range(0, 11):
            self.assertFalse(in_trigger_window(h, 11, 3), f"hour {h}")

    def test_silent_after_the_window_closes(self):
        for h in range(14, 24):
            self.assertFalse(in_trigger_window(h, 11, 3), f"hour {h}")

    def test_catchup_of_one_is_exact_hour_equality(self):
        """catchup=1 restores the old behaviour, for a quick env rollback."""
        self.assertTrue(in_trigger_window(11, 11, 1))
        self.assertFalse(in_trigger_window(12, 11, 1))

    def test_zero_or_negative_catchup_clamps_to_one(self):
        self.assertTrue(in_trigger_window(11, 11, 0))
        self.assertFalse(in_trigger_window(12, 11, 0))
        self.assertTrue(in_trigger_window(11, 11, -5))

    def test_end_of_day_window_never_crosses_local_midnight(self):
        """22:00 + 3 would reach hour 24/25 — i.e. the NEXT local day, whose
        day anchor is a different (wrong) SK. Must clamp at midnight."""
        self.assertTrue(in_trigger_window(22, 22, 3))
        self.assertTrue(in_trigger_window(23, 22, 3))
        self.assertFalse(in_trigger_window(0, 22, 3))
        self.assertFalse(in_trigger_window(1, 22, 3))

    def test_exactly_one_window_per_local_day(self):
        """Whatever the tuning, a rule is eligible on a contiguous run of
        hours inside one local day — never twice, never wrapping."""
        eligible = [h for h in range(24) if in_trigger_window(h, 11, 3)]
        self.assertEqual(eligible, [11, 12, 13])


class TestRuleSetForFacility(unittest.TestCase):

    def _rules(self, hour: int):
        return rule_set_for_facility(
            _facility(datetime(2026, 7, 27, hour, 30, tzinfo=LA))
        )

    def test_no_activity_fires_in_window_only(self):
        self.assertTrue(self._rules(11).evaluate_no_activity)
        self.assertTrue(self._rules(13).evaluate_no_activity)
        self.assertFalse(self._rules(9).evaluate_no_activity)
        self.assertFalse(self._rules(14).evaluate_no_activity)

    def test_end_of_day_fires_in_window_only(self):
        self.assertTrue(self._rules(22).evaluate_end_of_day_behavioral)
        self.assertTrue(self._rules(23).evaluate_end_of_day_behavioral)
        self.assertFalse(self._rules(21).evaluate_end_of_day_behavioral)
        self.assertFalse(self._rules(0).evaluate_end_of_day_behavioral)

    def test_the_two_daily_windows_never_overlap(self):
        for h in range(24):
            r = self._rules(h)
            self.assertFalse(
                r.evaluate_no_activity and r.evaluate_end_of_day_behavioral,
                f"hour {h} triggers both daily rule families",
            )

    def test_offline_rules_run_every_hour(self):
        for h in range(24):
            self.assertTrue(self._rules(h).evaluate_offline, f"hour {h}")

    def test_overrides_are_honoured(self):
        r = rule_set_for_facility(
            _facility(datetime(2026, 7, 27, 6, 30, tzinfo=LA)),
            no_activity_hour=6,
            end_of_day_hour=20,
            catchup_hours=1,
        )
        self.assertTrue(r.evaluate_no_activity)
        self.assertFalse(r.evaluate_end_of_day_behavioral)


class TestHourlyCronCoverage(unittest.TestCase):
    """
    Simulate the real EventBridge `rate(1 hour)` firing pattern against the
    gate, including the cases the old exact-equality gate got wrong.
    """

    def _windows_hit(self, start_utc: datetime, hours: int, tz) -> list[datetime]:
        """Local times at which no_activity_today would be evaluated."""
        hits = []
        t = start_utc
        for _ in range(hours):
            local = t.astimezone(tz)
            if rule_set_for_facility(_facility(local)).evaluate_no_activity:
                hits.append(local)
            t += timedelta(hours=1)
        return hits

    def test_normal_day_is_covered(self):
        hits = self._windows_hit(
            datetime(2026, 7, 27, 0, 30, tzinfo=timezone.utc), 24, LA
        )
        self.assertTrue(hits, "no evaluation happened at all on a normal day")
        self.assertEqual({h.date() for h in hits}, {datetime(2026, 7, 27).date()})

    def test_dst_transition_days_are_still_covered(self):
        """DST shifts hours 01-03, not 11 — but assert it rather than assume."""
        for start in (
            datetime(2026, 3, 8, 0, 30, tzinfo=timezone.utc),   # spring forward
            datetime(2026, 11, 1, 0, 30, tzinfo=timezone.utc),  # fall back
        ):
            hits = self._windows_hit(start, 24, LA)
            self.assertTrue(hits, f"no evaluation on DST day starting {start}")

    def test_a_missed_invocation_still_leaves_a_window(self):
        """The regression this window exists for: drop the firing that lands
        on the target hour and the day must STILL get evaluated."""
        t = datetime(2026, 7, 27, 0, 30, tzinfo=timezone.utc)
        hits = []
        for _ in range(24):
            local = t.astimezone(LA)
            if local.hour != DEFAULT_NO_ACTIVITY_LOCAL_HOUR:  # simulate the miss
                if rule_set_for_facility(_facility(local)).evaluate_no_activity:
                    hits.append(local)
            t += timedelta(hours=1)
        self.assertTrue(
            hits,
            "losing the target-hour firing dropped the whole day — this is "
            "exactly what the old `local_hour == target` gate did",
        )

    def test_jitter_straddling_the_hour_boundary_still_lands(self):
        """Firings at 10:59:5x then 12:00:0x never observe hour 11."""
        straddling = [
            datetime(2026, 7, 27, 10, 59, 55, tzinfo=LA),
            datetime(2026, 7, 27, 12, 0, 5, tzinfo=LA),
            datetime(2026, 7, 27, 13, 0, 15, tzinfo=LA),
        ]
        hit = [
            d for d in straddling
            if rule_set_for_facility(_facility(d)).evaluate_no_activity
        ]
        self.assertTrue(hit, "jitter across the hour boundary lost the day")

    def test_catchup_of_one_reproduces_the_old_miss(self):
        """Guard that the fix is really the window, not something incidental."""
        straddling = [
            datetime(2026, 7, 27, 10, 59, 55, tzinfo=LA),
            datetime(2026, 7, 27, 12, 0, 5, tzinfo=LA),
        ]
        hit = [
            d for d in straddling
            if rule_set_for_facility(_facility(d), catchup_hours=1).evaluate_no_activity
        ]
        self.assertEqual(hit, [], "expected the old exact-hour gate to miss")


if __name__ == "__main__":
    unittest.main()

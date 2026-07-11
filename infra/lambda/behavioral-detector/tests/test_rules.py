"""
Unit tests for behavioral-detector rule modules — Phase 1C-slim.

Run from `infra/lambda/`:
    PYTHONPATH=. python3 -m unittest discover behavioral-detector/tests
"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

_LAMBDA_DIR = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(_LAMBDA_DIR))
_HANDLER_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(_HANDLER_DIR))

sys.path.insert(0, str(Path(__file__).resolve().parent))
import _stub_powertools  # noqa: F401,E402

from rules import below_typical, declining_trend, device_offline, no_activity_today  # noqa: E402
from rules.types import (  # noqa: E402
    ALERT_BELOW_TYPICAL,
    ALERT_DECLINING_TREND,
    ALERT_DEVICE_OFFLINE,
    ALERT_DEVICE_SILENT,
    ALERT_NO_ACTIVITY_TODAY,
    SEVERITY_CRITICAL,
    SEVERITY_STANDARD,
    SEVERITY_WARNING,
    SOURCE_BEHAVIORAL,
    SOURCE_OFFLINE,
)


NOW = 1_700_000_000  # fixed epoch for deterministic time math
LOCAL_NOW_ISO = "2026-05-24T09:00:00-08:00"


# ──────────────────────────────────────────────────────────────────────
# no_activity_today
# ──────────────────────────────────────────────────────────────────────


class TestNoActivityToday(unittest.TestCase):

    def _eval(self, rows, last_seen_offset=-3600, **kw):
        """Helper: evaluate with last_seen at NOW + offset (negative = past)."""
        return no_activity_today.evaluate(
            activity_rows_today=rows,
            device_last_seen_epoch=NOW + last_seen_offset if last_seen_offset is not None else None,
            now_epoch=NOW,
            local_now_iso=LOCAL_NOW_ISO,
            **kw,
        )

    def test_zero_active_min_fresh_device_fires_critical(self):
        cand = self._eval([], last_seen_offset=-3600)
        self.assertIsNotNone(cand)
        self.assertEqual(cand.alert_type, ALERT_NO_ACTIVITY_TODAY)
        self.assertEqual(cand.severity, SEVERITY_CRITICAL)
        self.assertEqual(cand.source, SOURCE_BEHAVIORAL)
        self.assertEqual(cand.data["activeMinutesObservedBefore"], 0)
        self.assertEqual(cand.data["lastDataReceivedAgo"], "1h")

    def test_zero_active_min_empty_rows_list(self):
        cand = self._eval([])
        self.assertIsNotNone(cand)

    def test_one_active_minute_does_not_fire(self):
        cand = self._eval([{"activeMinutes": 1}])
        self.assertIsNone(cand)

    def test_high_active_min_does_not_fire(self):
        cand = self._eval([{"activeMinutes": 60}, {"activeMinutes": 45}])
        self.assertIsNone(cand)

    def test_zero_total_across_multiple_rows_fires(self):
        # Edge: empty session (e.g. session that was started but had no real walking)
        cand = self._eval([{"activeMinutes": 0}, {"activeMinutes": 0}])
        self.assertIsNotNone(cand)
        self.assertEqual(cand.data["sessionCount"], 2)

    def test_device_silent_over_24h_does_not_fire_no_activity(self):
        """At 24h dark, device_silent rule should handle this, not no_activity."""
        cand = self._eval([], last_seen_offset=-25 * 3600)
        self.assertIsNone(cand)

    def test_device_silent_at_exactly_24h_does_not_fire(self):
        """Boundary: exactly 24h ago → device_silent territory."""
        cand = self._eval([], last_seen_offset=-24 * 3600)
        self.assertIsNone(cand)

    def test_device_at_23h59m_still_fires_no_activity(self):
        """Boundary: just under 24h still counts as device-alive."""
        cand = self._eval([], last_seen_offset=-(23 * 3600 + 59 * 60))
        self.assertIsNotNone(cand)

    def test_no_device_last_seen_does_not_fire(self):
        cand = self._eval([], last_seen_offset=None)
        self.assertIsNone(cand)

    def test_data_format_ago_minutes(self):
        cand = self._eval([], last_seen_offset=-(45 * 60))
        self.assertEqual(cand.data["lastDataReceivedAgo"], "45m")

    def test_data_format_ago_under_one_minute(self):
        cand = self._eval([], last_seen_offset=-30)
        self.assertEqual(cand.data["lastDataReceivedAgo"], "30s")

    def test_data_format_ago_hours_minutes(self):
        cand = self._eval([], last_seen_offset=-(3 * 3600 + 15 * 60))
        self.assertEqual(cand.data["lastDataReceivedAgo"], "3h 15m")

    def test_check_local_hour_in_payload(self):
        cand = self._eval([], check_local_hour=9)
        self.assertEqual(cand.data["checkLocalHour"], 9)

    # ── DT-4 WS2 no-regression: walker keys on steps, not activeMinutes ──
    def test_walker_steps_present_but_zero_active_min_does_not_fire(self):
        """THE WS2 regression case: a low-mobility walker took steps but summed
        < 1 active-minute across the day → must NOT trip a false CRITICAL
        (identical to the pre-DT-4 steps rule)."""
        cand = self._eval(
            [{"steps": 30, "activeMinutes": 0}, {"steps": 25, "activeMinutes": 0}],
            metric_field="steps",
        )
        self.assertIsNone(cand)

    def test_walker_zero_steps_fires_and_reports_metric(self):
        """Walker with zero steps fires (keyed on steps); payload reports the
        metric used + the real activeMinutes observed."""
        cand = self._eval([{"steps": 0, "activeMinutes": 4}], metric_field="steps")
        self.assertIsNotNone(cand)
        self.assertEqual(cand.data["metric"], "steps")
        self.assertEqual(cand.data["activeMinutesObservedBefore"], 4)

    def test_rollator_zero_active_min_fires(self):
        """Rollator (no steps) keys on activeMinutes — unchanged DT-4 behavior."""
        cand = self._eval([{"activeMinutes": 0}], metric_field="activeMinutes")
        self.assertIsNotNone(cand)
        self.assertEqual(cand.data["metric"], "activeMinutes")

    def test_default_metric_is_active_minutes(self):
        """Callers that omit metric_field keep the activeMinutes behavior:
        activeMinutes==0 fires regardless of steps."""
        cand = self._eval([{"steps": 100, "activeMinutes": 0}])  # no metric_field
        self.assertIsNotNone(cand)
        self.assertEqual(cand.data["metric"], "activeMinutes")


# ──────────────────────────────────────────────────────────────────────
# below_typical
# ──────────────────────────────────────────────────────────────────────


class TestBelowTypical(unittest.TestCase):

    def _hist(self, days: int, active_min_each: int = 200) -> list[int]:
        return [active_min_each] * days

    def test_today_below_threshold_fires(self):
        # 100 active-min today; median7=200; 0.70*200 = 140; 100 < 140 → fires
        cand = below_typical.evaluate(
            today_active_minutes=100,
            history_active_min_per_day=self._hist(14, 200),
            local_now_iso=LOCAL_NOW_ISO,
        )
        self.assertIsNotNone(cand)
        self.assertEqual(cand.alert_type, ALERT_BELOW_TYPICAL)
        self.assertEqual(cand.severity, SEVERITY_STANDARD)
        self.assertEqual(cand.data["activeMinutesToday"], 100)
        self.assertEqual(cand.data["median7Day"], 200)
        self.assertEqual(cand.data["thresholdActiveMin"], 140)
        self.assertAlmostEqual(cand.data["thresholdPct"], 0.70)

    def test_today_above_threshold_does_not_fire(self):
        cand = below_typical.evaluate(
            today_active_minutes=150,  # > 140
            history_active_min_per_day=self._hist(14, 200),
            local_now_iso=LOCAL_NOW_ISO,
        )
        self.assertIsNone(cand)

    def test_today_exactly_at_threshold_does_not_fire(self):
        """Boundary: 0.70*200=140; today=140 → not below."""
        cand = below_typical.evaluate(
            today_active_minutes=140,
            history_active_min_per_day=self._hist(14, 200),
            local_now_iso=LOCAL_NOW_ISO,
        )
        self.assertIsNone(cand)

    def test_cold_start_under_min_history_does_not_fire(self):
        cand = below_typical.evaluate(
            today_active_minutes=0,
            history_active_min_per_day=self._hist(13, 200),
            local_now_iso=LOCAL_NOW_ISO,
        )
        self.assertIsNone(cand)

    def test_zero_median_does_not_fire(self):
        """Patient who's normally inactive — no signal to alert on."""
        cand = below_typical.evaluate(
            today_active_minutes=0,
            history_active_min_per_day=self._hist(14, 0),
            local_now_iso=LOCAL_NOW_ISO,
        )
        self.assertIsNone(cand)

    def test_uses_only_last_7_days_for_median(self):
        # 7 days of high (200), 7 days of low (50). Median7 should be 200.
        history = [50] * 7 + [200] * 7
        cand = below_typical.evaluate(
            today_active_minutes=100,
            history_active_min_per_day=history,
            local_now_iso=LOCAL_NOW_ISO,
        )
        self.assertIsNotNone(cand)
        self.assertEqual(cand.data["median7Day"], 200)

    def test_custom_threshold_pct(self):
        # 50% threshold: 0.50*200=100; today=99 fires, today=100 doesn't
        cand = below_typical.evaluate(
            today_active_minutes=99,
            history_active_min_per_day=self._hist(14, 200),
            local_now_iso=LOCAL_NOW_ISO,
            threshold_pct=0.50,
        )
        self.assertIsNotNone(cand)
        cand = below_typical.evaluate(
            today_active_minutes=100,
            history_active_min_per_day=self._hist(14, 200),
            local_now_iso=LOCAL_NOW_ISO,
            threshold_pct=0.50,
        )
        self.assertIsNone(cand)

    def test_demo_calibration_threshold(self):
        """Demo uses 65% (spec uses 70%). Verify both behaviors."""
        # 65% threshold: 0.65*200=130; today=129 fires
        cand = below_typical.evaluate(
            today_active_minutes=129,
            history_active_min_per_day=self._hist(14, 200),
            local_now_iso=LOCAL_NOW_ISO,
            threshold_pct=0.65,
        )
        self.assertIsNotNone(cand)
        # 70% threshold: 0.70*200=140; today=129 fires
        cand = below_typical.evaluate(
            today_active_minutes=129,
            history_active_min_per_day=self._hist(14, 200),
            local_now_iso=LOCAL_NOW_ISO,
            threshold_pct=0.70,
        )
        self.assertIsNotNone(cand)


# ──────────────────────────────────────────────────────────────────────
# declining_trend
# ──────────────────────────────────────────────────────────────────────


class TestDecliningTrend(unittest.TestCase):

    def test_clear_decline_fires(self):
        # Prior 23 days: 300 active-min/day. Last 7 days: 200 active-min/day.
        # median7=200; medianPrior23=300; threshold=255; 200 < 255 → fires.
        history = [300] * 23 + [200] * 7
        cand = declining_trend.evaluate(
            history_active_min_per_day=history,
            local_now_iso=LOCAL_NOW_ISO,
        )
        self.assertIsNotNone(cand)
        self.assertEqual(cand.alert_type, ALERT_DECLINING_TREND)
        self.assertEqual(cand.severity, SEVERITY_STANDARD)
        self.assertEqual(cand.data["median7Day"], 200)
        self.assertEqual(cand.data["medianPrior23Day"], 300)
        # 1 - 200/300 = 0.333... → 33.3%
        self.assertAlmostEqual(cand.data["declinePct"], 33.3, places=0)

    def test_flat_history_does_not_fire(self):
        history = [200] * 30
        cand = declining_trend.evaluate(
            history_active_min_per_day=history,
            local_now_iso=LOCAL_NOW_ISO,
        )
        self.assertIsNone(cand)

    def test_upward_trend_does_not_fire(self):
        history = [100] * 23 + [400] * 7
        cand = declining_trend.evaluate(
            history_active_min_per_day=history,
            local_now_iso=LOCAL_NOW_ISO,
        )
        self.assertIsNone(cand)

    def test_at_exactly_threshold_does_not_fire(self):
        """Boundary: median7 = 0.85 * medianPrior23 → does not fire."""
        # medianPrior23 = 200; threshold = 170; median7 = 170 → not below
        history = [200] * 23 + [170] * 7
        cand = declining_trend.evaluate(
            history_active_min_per_day=history,
            local_now_iso=LOCAL_NOW_ISO,
        )
        self.assertIsNone(cand)

    def test_under_30_days_does_not_fire(self):
        # 29 days isn't enough for the 7d-vs-prior-23d split
        history = [300] * 22 + [100] * 7
        cand = declining_trend.evaluate(
            history_active_min_per_day=history,
            local_now_iso=LOCAL_NOW_ISO,
        )
        self.assertIsNone(cand)

    def test_under_min_history_does_not_fire(self):
        history = [300] * 13
        cand = declining_trend.evaluate(
            history_active_min_per_day=history,
            local_now_iso=LOCAL_NOW_ISO,
        )
        self.assertIsNone(cand)

    def test_zero_medians_do_not_fire(self):
        history = [0] * 30
        cand = declining_trend.evaluate(
            history_active_min_per_day=history,
            local_now_iso=LOCAL_NOW_ISO,
        )
        self.assertIsNone(cand)


# ──────────────────────────────────────────────────────────────────────
# device_offline (handles both offline + silent tiers)
# ──────────────────────────────────────────────────────────────────────


class TestDeviceOfflineSilent(unittest.TestCase):

    def _eval(self, last_seen_offset_hours, status="active_monitoring"):
        return device_offline.evaluate(
            device_status=status,
            device_last_seen_epoch=NOW + int(last_seen_offset_hours * 3600),
            now_epoch=NOW,
            local_now_iso=LOCAL_NOW_ISO,
        )

    # ── Offline tier (2h) ──────────────────────────────────────────

    def test_fresh_device_does_not_fire(self):
        self.assertIsNone(self._eval(-0.5))

    def test_just_under_2h_does_not_fire(self):
        self.assertIsNone(self._eval(-1.99))

    def test_exactly_2h_fires_offline(self):
        cand = self._eval(-2)
        self.assertIsNotNone(cand)
        self.assertEqual(cand.alert_type, ALERT_DEVICE_OFFLINE)
        self.assertEqual(cand.severity, SEVERITY_WARNING)
        self.assertEqual(cand.source, SOURCE_OFFLINE)
        self.assertEqual(cand.data["thresholdHours"], 2)

    def test_3h_fires_offline(self):
        cand = self._eval(-3)
        self.assertEqual(cand.alert_type, ALERT_DEVICE_OFFLINE)
        self.assertAlmostEqual(cand.data["hoursOffline"], 3.0)

    def test_23h_fires_offline_not_silent(self):
        """At 23h offline, still offline tier; silent kicks in at 24h."""
        cand = self._eval(-23)
        self.assertEqual(cand.alert_type, ALERT_DEVICE_OFFLINE)

    # ── Silent tier (24h) ──────────────────────────────────────────

    def test_exactly_24h_fires_silent(self):
        cand = self._eval(-24)
        self.assertIsNotNone(cand)
        self.assertEqual(cand.alert_type, ALERT_DEVICE_SILENT)
        self.assertEqual(cand.severity, SEVERITY_CRITICAL)
        self.assertEqual(cand.data["thresholdHours"], 24)

    def test_3_days_offline_fires_silent(self):
        cand = self._eval(-72)
        self.assertEqual(cand.alert_type, ALERT_DEVICE_SILENT)

    # ── Status guard ───────────────────────────────────────────────

    def test_provisioned_does_not_fire(self):
        """Pre-activation device — no offline detection."""
        self.assertIsNone(self._eval(-72, status="provisioned"))

    def test_ready_to_provision_does_not_fire(self):
        self.assertIsNone(self._eval(-72, status="ready_to_provision"))

    def test_discontinued_does_not_fire(self):
        self.assertIsNone(self._eval(-72, status="discontinued"))

    def test_decommissioned_does_not_fire(self):
        self.assertIsNone(self._eval(-72, status="decommissioned"))

    # ── Missing lastSeen ───────────────────────────────────────────

    def test_no_last_seen_does_not_fire(self):
        cand = device_offline.evaluate(
            device_status="active_monitoring",
            device_last_seen_epoch=None,
            now_epoch=NOW,
            local_now_iso=LOCAL_NOW_ISO,
        )
        self.assertIsNone(cand)

    # ── Tunable thresholds ─────────────────────────────────────────

    def test_custom_offline_threshold(self):
        cand = device_offline.evaluate(
            device_status="active_monitoring",
            device_last_seen_epoch=NOW - 30 * 60,  # 30 min ago
            now_epoch=NOW,
            local_now_iso=LOCAL_NOW_ISO,
            offline_threshold_hours=1,  # 1h offline threshold
        )
        self.assertIsNone(cand)  # 30min < 1h
        cand = device_offline.evaluate(
            device_status="active_monitoring",
            device_last_seen_epoch=NOW - 70 * 60,  # 70 min ago
            now_epoch=NOW,
            local_now_iso=LOCAL_NOW_ISO,
            offline_threshold_hours=1,
        )
        self.assertEqual(cand.alert_type, ALERT_DEVICE_OFFLINE)

    def test_custom_silent_threshold(self):
        """48h silent threshold instead of default 24h."""
        # 25h offline → still offline (warning) under 48h silent threshold
        cand = device_offline.evaluate(
            device_status="active_monitoring",
            device_last_seen_epoch=NOW - 25 * 3600,
            now_epoch=NOW,
            local_now_iso=LOCAL_NOW_ISO,
            silent_threshold_hours=48,
        )
        self.assertEqual(cand.alert_type, ALERT_DEVICE_OFFLINE)
        # 48h offline → silent
        cand = device_offline.evaluate(
            device_status="active_monitoring",
            device_last_seen_epoch=NOW - 48 * 3600,
            now_epoch=NOW,
            local_now_iso=LOCAL_NOW_ISO,
            silent_threshold_hours=48,
        )
        self.assertEqual(cand.alert_type, ALERT_DEVICE_SILENT)


if __name__ == "__main__":
    unittest.main()

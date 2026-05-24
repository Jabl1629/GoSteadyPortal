"""
Unit tests for _shared/thresholds.py merge_thresholds + determine_threshold_alerts
under per-patient overrides — Phase 2A-AA.
"""

from __future__ import annotations

import sys
import unittest
from decimal import Decimal
from pathlib import Path

_LAMBDA_DIR = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(_LAMBDA_DIR))
sys.path.insert(0, str(Path(_LAMBDA_DIR) / "patient-api" / "tests"))
import _stub_powertools  # noqa: F401,E402

from _shared.thresholds import (  # noqa: E402
    BATTERY_CRITICAL, BATTERY_LOW, RSRP_LOST, RSRP_WEAK,
    DEFAULTS, merge_thresholds, determine_threshold_alerts,
)


class TestMergeThresholds(unittest.TestCase):
    def test_none_returns_defaults(self):
        self.assertEqual(merge_thresholds(None), DEFAULTS)

    def test_empty_returns_defaults(self):
        self.assertEqual(merge_thresholds({}), DEFAULTS)

    def test_partial_override(self):
        m = merge_thresholds({"batteryCritical": 0.07})
        self.assertEqual(m["batteryCritical"], 0.07)
        self.assertEqual(m["batteryLow"], BATTERY_LOW)  # unchanged
        self.assertEqual(m["rsrpLost"], RSRP_LOST)
        self.assertEqual(m["rsrpWeak"], RSRP_WEAK)

    def test_full_override(self):
        m = merge_thresholds({
            "batteryCritical": 0.03, "batteryLow": 0.08,
            "rsrpLost": -125, "rsrpWeak": -115,
        })
        self.assertEqual(m, {"batteryCritical": 0.03, "batteryLow": 0.08,
                              "rsrpLost": -125.0, "rsrpWeak": -115.0})

    def test_decimal_input(self):
        # DDB returns numbers as Decimal; merge_thresholds must coerce
        m = merge_thresholds({"batteryCritical": Decimal("0.07")})
        self.assertEqual(m["batteryCritical"], 0.07)
        self.assertIsInstance(m["batteryCritical"], float)

    def test_null_in_overrides_uses_default(self):
        m = merge_thresholds({"batteryCritical": None})
        self.assertEqual(m["batteryCritical"], BATTERY_CRITICAL)

    def test_unknown_keys_ignored(self):
        m = merge_thresholds({"someOtherField": 0.5})
        self.assertEqual(m, DEFAULTS)


class TestDetermineThresholdAlertsWithOverrides(unittest.TestCase):
    def test_default_behavior_unchanged_no_overrides(self):
        # Same as Phase 1B behavior
        self.assertEqual(determine_threshold_alerts(0.03, None), [("battery_critical", "critical")])
        self.assertEqual(determine_threshold_alerts(0.07, None), [("battery_low", "warning")])
        self.assertEqual(determine_threshold_alerts(0.50, None), [])
        self.assertEqual(determine_threshold_alerts(None, -130), [("signal_lost", "warning")])
        self.assertEqual(determine_threshold_alerts(None, -115), [("signal_weak", "info")])

    def test_override_relaxes_battery(self):
        # Patient with batteryLow=0.05 (under-default) should NOT alert at 0.07
        overrides = {"batteryLow": 0.05, "batteryCritical": 0.02}
        self.assertEqual(determine_threshold_alerts(0.07, None, overrides=overrides), [])

    def test_override_tightens_battery(self):
        # Patient with batteryLow=0.20 should alert at 0.15
        overrides = {"batteryLow": 0.20}
        self.assertEqual(
            determine_threshold_alerts(0.15, None, overrides=overrides),
            [("battery_low", "warning")],
        )

    def test_battery_critical_takes_precedence(self):
        overrides = {"batteryCritical": 0.10, "batteryLow": 0.20}
        # 0.08 < 0.10 → critical (not low)
        self.assertEqual(
            determine_threshold_alerts(0.08, None, overrides=overrides),
            [("battery_critical", "critical")],
        )

    def test_combined_battery_and_signal_overrides(self):
        overrides = {"batteryLow": 0.20, "rsrpWeak": -100}
        self.assertEqual(
            sorted(determine_threshold_alerts(0.15, -105, overrides=overrides)),
            sorted([("battery_low", "warning"), ("signal_weak", "info")]),
        )

    def test_decimal_values_in_overrides(self):
        overrides = {"batteryLow": Decimal("0.20")}
        self.assertEqual(
            determine_threshold_alerts(0.15, None, overrides=overrides),
            [("battery_low", "warning")],
        )


if __name__ == "__main__":
    unittest.main()

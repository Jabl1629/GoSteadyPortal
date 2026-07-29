"""
Unit tests for the signal-alerting kill switch — `_shared/thresholds`.

`signal_lost` / `signal_weak` were disabled 2026-07-28 (35% of prod alert
volume, not actionable — a genuinely dark device is covered better by
device_offline/device_silent). Disabled as a flag, not by deleting the
rules, so re-enabling is an env flip.

Run from `infra/lambda/`:
    PYTHONPATH=. python3 -m unittest discover _shared/tests
"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import _stub_powertools  # noqa: F401,E402

from _shared.thresholds import (  # noqa: E402
    RSRP_LOST,
    RSRP_WEAK,
    _env_bool,
    determine_threshold_alerts,
    signal_alerts_enabled,
)


def _types(alerts):
    return [a for a, _ in alerts]


class TestSignalDisabledByDefault(unittest.TestCase):

    def test_module_default_is_off(self):
        self.assertFalse(signal_alerts_enabled())

    def test_lost_territory_produces_nothing(self):
        self.assertEqual(determine_threshold_alerts(None, -130.0), [])

    def test_weak_territory_produces_nothing(self):
        self.assertEqual(determine_threshold_alerts(None, -115.0), [])

    def test_exactly_at_each_threshold_produces_nothing(self):
        self.assertEqual(determine_threshold_alerts(None, RSRP_LOST), [])
        self.assertEqual(determine_threshold_alerts(None, RSRP_WEAK), [])

    def test_no_rsrp_value_still_produces_nothing(self):
        self.assertEqual(determine_threshold_alerts(None, None), [])

    def test_per_patient_overrides_cannot_resurrect_signal_alerts(self):
        """The override surface stays intact, but it must not re-enable a
        disabled dimension — otherwise a stale patient override would keep
        one resident noisy after the shutoff."""
        alerts = determine_threshold_alerts(
            None, -95.0, overrides={"rsrpLost": -90.0, "rsrpWeak": -80.0}
        )
        self.assertEqual(alerts, [])


class TestBatteryIsUnaffected(unittest.TestCase):
    """The shutoff must not touch the battery dimension — battery is the
    one alert a D2C walker can actually act on."""

    def test_battery_critical_still_fires(self):
        self.assertEqual(_types(determine_threshold_alerts(0.01, None)), ["battery_critical"])

    def test_battery_low_still_fires(self):
        self.assertEqual(_types(determine_threshold_alerts(0.07, None)), ["battery_low"])

    def test_healthy_battery_still_silent(self):
        self.assertEqual(determine_threshold_alerts(0.80, None), [])

    def test_battery_fires_alone_when_both_dimensions_breach(self):
        """Pre-shutoff this returned battery + signal; now battery only."""
        alerts = determine_threshold_alerts(0.01, -130.0)
        self.assertEqual(_types(alerts), ["battery_critical"])

    def test_battery_severities_unchanged(self):
        self.assertEqual(determine_threshold_alerts(0.01, None), [("battery_critical", "critical")])
        self.assertEqual(determine_threshold_alerts(0.07, None), [("battery_low", "warning")])


class TestExplicitlyReEnabled(unittest.TestCase):
    """The rules must still work when the flag is flipped back on, so the
    kill switch is a real rollback path and not a one-way door."""

    def test_lost_fires_when_enabled(self):
        alerts = determine_threshold_alerts(None, -130.0, signal_enabled=True)
        self.assertEqual(alerts, [("signal_lost", "warning")])

    def test_weak_fires_when_enabled(self):
        alerts = determine_threshold_alerts(None, -115.0, signal_enabled=True)
        self.assertEqual(alerts, [("signal_weak", "info")])

    def test_boundaries_when_enabled(self):
        """<= is the documented comparison on both tiers."""
        self.assertEqual(
            _types(determine_threshold_alerts(None, RSRP_LOST, signal_enabled=True)),
            ["signal_lost"],
        )
        self.assertEqual(
            _types(determine_threshold_alerts(None, RSRP_WEAK, signal_enabled=True)),
            ["signal_weak"],
        )
        self.assertEqual(
            determine_threshold_alerts(None, RSRP_WEAK + 1, signal_enabled=True), []
        )

    def test_overrides_honoured_when_enabled(self):
        alerts = determine_threshold_alerts(
            None, -95.0, overrides={"rsrpLost": -100.0, "rsrpWeak": -90.0},
            signal_enabled=True,
        )
        self.assertEqual(_types(alerts), ["signal_weak"])

    def test_both_dimensions_when_enabled(self):
        alerts = determine_threshold_alerts(0.01, -130.0, signal_enabled=True)
        self.assertEqual(_types(alerts), ["battery_critical", "signal_lost"])

    def test_explicit_false_beats_a_true_module_default(self):
        self.assertEqual(determine_threshold_alerts(None, -130.0, signal_enabled=False), [])


class TestEnvBool(unittest.TestCase):

    def test_truthy_forms(self):
        for raw in ("1", "true", "TRUE", "True", "yes", "on", " true "):
            with self.subTest(raw=raw):
                import os
                os.environ["_GS_TEST_FLAG"] = raw
                self.assertTrue(_env_bool("_GS_TEST_FLAG", False))
                del os.environ["_GS_TEST_FLAG"]

    def test_falsey_and_absent_forms(self):
        import os
        for raw in ("0", "false", "no", "off", "", "garbage"):
            with self.subTest(raw=raw):
                os.environ["_GS_TEST_FLAG"] = raw
                self.assertFalse(_env_bool("_GS_TEST_FLAG", False))
                del os.environ["_GS_TEST_FLAG"]
        self.assertFalse(_env_bool("_GS_TEST_ABSENT_FLAG", False))
        self.assertTrue(_env_bool("_GS_TEST_ABSENT_FLAG", True))


if __name__ == "__main__":
    unittest.main()

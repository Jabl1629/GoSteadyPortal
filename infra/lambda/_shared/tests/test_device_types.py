"""
Unit tests for _shared/device_types/ — Phase DT-0.

Run from `infra/lambda/_shared/tests/` (stub must install before the
`_shared` package import triggers observability → powertools):
    python3 -m unittest test_device_types
"""

from __future__ import annotations

import sys
import unittest
from decimal import Decimal
from pathlib import Path

_LAMBDA_DIR = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(_LAMBDA_DIR))

sys.path.insert(0, str(Path(__file__).resolve().parent))
import _stub_powertools  # noqa: F401,E402

from _shared import device_types  # noqa: E402
from _shared.device_types import rollator_platform, walker_cap  # noqa: E402
from _shared.thresholds import (  # noqa: E402
    DEFAULTS,
    determine_threshold_alerts,
    merge_thresholds,
)


def _walker_event(**overrides) -> dict:
    ev = {
        "serial": "GS9999999998",
        "steps": 42,
        "distance_ft": 50.09,
        "active_min": 4,
        "session_start": "2026-07-01T17:00:00Z",
        "session_end": "2026-07-01T17:04:00Z",
    }
    ev.update(overrides)
    return ev


def _rollator_event(**overrides) -> dict:
    ev = {
        "serial": "GS9999999980",
        "active_min": 4,
        "session_start": "2026-07-01T17:00:00Z",
        "session_end": "2026-07-01T17:04:00Z",
    }
    ev.update(overrides)
    return ev


class TestRegistry(unittest.TestCase):
    def test_known_types(self):
        self.assertEqual(
            device_types.KNOWN_DEVICE_TYPES, {"walker_cap", "rollator_platform"}
        )
        self.assertEqual(device_types.DEFAULT_TYPE, "walker_cap")

    def test_resolve_known(self):
        self.assertIs(device_types.resolve("walker_cap"), walker_cap)
        self.assertIs(device_types.resolve("rollator_platform"), rollator_platform)

    def test_resolve_none_and_empty_default_to_walker(self):
        self.assertIs(device_types.resolve(None), walker_cap)
        self.assertIs(device_types.resolve(""), walker_cap)

    def test_resolve_unknown_defaults_to_walker(self):
        self.assertIs(device_types.resolve("hoverboard"), walker_cap)
        self.assertFalse(device_types.is_known("hoverboard"))
        self.assertFalse(device_types.is_known(None))
        self.assertTrue(device_types.is_known("rollator_platform"))


class TestWalkerCapValidation(unittest.TestCase):
    def test_happy_path(self):
        ok, reason = walker_cap.validate_activity_metrics(_walker_event())
        self.assertTrue(ok, reason)

    def test_missing_each_required(self):
        for field in ("steps", "distance_ft", "active_min"):
            ev = _walker_event()
            del ev[field]
            ok, reason = walker_cap.validate_activity_metrics(ev)
            self.assertFalse(ok)
            self.assertEqual(reason, f"missing:{field}")

    def test_out_of_range(self):
        ok, reason = walker_cap.validate_activity_metrics(_walker_event(steps=100_001))
        self.assertFalse(ok)
        self.assertIn("steps_out_of_range", reason)
        ok, reason = walker_cap.validate_activity_metrics(_walker_event(distance_ft=-1))
        self.assertFalse(ok)
        self.assertIn("distance_out_of_range", reason)
        ok, reason = walker_cap.validate_activity_metrics(_walker_event(active_min=1441))
        self.assertFalse(ok)
        self.assertIn("active_out_of_range", reason)

    def test_bad_number(self):
        ok, reason = walker_cap.validate_activity_metrics(_walker_event(steps="lots"))
        self.assertFalse(ok)
        self.assertIn("bad_number", reason)


class TestWalkerCapBuild(unittest.TestCase):
    def test_required_promotion(self):
        attrs, warnings = walker_cap.build_metric_attrs(_walker_event())
        self.assertEqual(attrs["steps"], 42)
        self.assertEqual(attrs["distanceFt"], Decimal("50.09"))
        self.assertEqual(attrs["activeMinutes"], 4)
        self.assertEqual(warnings, [])
        self.assertNotIn("surfaceClass", attrs)
        self.assertNotIn("gaitSpeedFts", attrs)
        self.assertNotIn("roughnessR", attrs)

    def test_optional_promotion(self):
        attrs, warnings = walker_cap.build_metric_attrs(
            _walker_event(
                roughness_R=0.4033,
                surface_class="outdoor",
                gait_speed_fts=1.23,
            )
        )
        self.assertEqual(attrs["roughnessR"], Decimal("0.4033"))
        self.assertEqual(attrs["surfaceClass"], "outdoor")
        self.assertEqual(attrs["gaitSpeedFts"], Decimal("1.23"))
        self.assertEqual(warnings, [])

    def test_unknown_surface_dropped_with_warning(self):
        attrs, warnings = walker_cap.build_metric_attrs(
            _walker_event(surface_class="moon")
        )
        self.assertNotIn("surfaceClass", attrs)
        self.assertEqual(warnings[0]["warning"], "unknown_surface_class")

    def test_gait_out_of_range_dropped_with_warning(self):
        attrs, warnings = walker_cap.build_metric_attrs(
            _walker_event(gait_speed_fts=11.0)
        )
        self.assertNotIn("gaitSpeedFts", attrs)
        self.assertEqual(warnings[0]["warning"], "gait_out_of_range")

    def test_gait_unparseable_dropped_silently(self):
        attrs, warnings = walker_cap.build_metric_attrs(
            _walker_event(gait_speed_fts="fast")
        )
        self.assertNotIn("gaitSpeedFts", attrs)
        self.assertEqual(warnings, [])


class TestRollatorValidation(unittest.TestCase):
    def test_happy_path_active_min_only(self):
        ok, reason = rollator_platform.validate_activity_metrics(_rollator_event())
        self.assertTrue(ok, reason)

    def test_steps_distance_not_required(self):
        # Bench v0: a rollator payload with no steps/distance is valid.
        ev = _rollator_event(some_provisional_metric=1.5)
        ok, _ = rollator_platform.validate_activity_metrics(ev)
        self.assertTrue(ok)

    def test_missing_active_min(self):
        ev = _rollator_event()
        del ev["active_min"]
        ok, reason = rollator_platform.validate_activity_metrics(ev)
        self.assertFalse(ok)
        self.assertEqual(reason, "missing:active_min")

    def test_active_min_range(self):
        ok, reason = rollator_platform.validate_activity_metrics(
            _rollator_event(active_min=-1)
        )
        self.assertFalse(ok)
        self.assertIn("active_out_of_range", reason)

    def test_build_stray_steps_not_promoted(self):
        # Rollator has no steps (frame-mount, no lift-and-place impulses). A
        # stray value stays in extras — build promotes only recognized metrics.
        attrs, warnings = rollator_platform.build_metric_attrs(
            _rollator_event(steps=99)
        )
        self.assertEqual(attrs, {"activeMinutes": 4})
        self.assertEqual(warnings, [])

    def test_build_promotes_distance_and_gait(self):
        attrs, warnings = rollator_platform.build_metric_attrs(
            _rollator_event(distance_ft=123.4, gait_speed_fts=1.1)
        )
        self.assertEqual(attrs["activeMinutes"], 4)
        self.assertEqual(attrs["distanceFt"], Decimal("123.4"))
        self.assertEqual(attrs["gaitSpeedFts"], Decimal("1.1"))
        self.assertEqual(warnings, [])

    def test_build_distance_gait_omitted_active_min_only(self):
        # Confidence-gated: a stationary session (no rolling motion) sends
        # active_min only — distance/gait absent, still a valid row.
        attrs, warnings = rollator_platform.build_metric_attrs(_rollator_event())
        self.assertEqual(attrs, {"activeMinutes": 4})
        self.assertNotIn("distanceFt", attrs)
        self.assertNotIn("gaitSpeedFts", attrs)
        self.assertEqual(warnings, [])

    def test_build_distance_out_of_range_dropped_with_warning(self):
        attrs, warnings = rollator_platform.build_metric_attrs(
            _rollator_event(distance_ft=50_001)
        )
        self.assertNotIn("distanceFt", attrs)
        self.assertEqual(warnings[0]["warning"], "distance_out_of_range")

    def test_build_gait_out_of_range_dropped_with_warning(self):
        attrs, warnings = rollator_platform.build_metric_attrs(
            _rollator_event(gait_speed_fts=11.0)
        )
        self.assertNotIn("gaitSpeedFts", attrs)
        self.assertEqual(warnings[0]["warning"], "gait_out_of_range")

    def test_build_distance_unparseable_dropped_silently(self):
        attrs, warnings = rollator_platform.build_metric_attrs(
            _rollator_event(distance_ft="far")
        )
        self.assertNotIn("distanceFt", attrs)
        self.assertEqual(warnings, [])

    def test_named_fields_include_distance_gait_not_steps(self):
        # So the handler excludes distance/gait from the `extras` catch-all,
        # but a stray `steps` still flows to extras.
        self.assertIn("distance_ft", rollator_platform.ACTIVITY_NAMED_FIELDS)
        self.assertIn("gait_speed_fts", rollator_platform.ACTIVITY_NAMED_FIELDS)
        self.assertNotIn("steps", rollator_platform.ACTIVITY_NAMED_FIELDS)

    def test_alert_enum_empty(self):
        self.assertEqual(rollator_platform.VALID_ALERT_TYPES, frozenset())
        self.assertIn("tipover", walker_cap.VALID_ALERT_TYPES)


class TestThresholdsByType(unittest.TestCase):
    def test_types_share_values_at_dt0(self):
        # Memo Q3: rollator inherits walker defaults until cupholder hardware.
        self.assertEqual(
            merge_thresholds(None, device_type="walker_cap"),
            merge_thresholds(None, device_type="rollator_platform"),
        )
        self.assertEqual(merge_thresholds(None), dict(DEFAULTS))

    def test_unknown_type_falls_back_to_walker(self):
        self.assertEqual(
            merge_thresholds(None, device_type="hoverboard"), dict(DEFAULTS)
        )

    def test_overrides_still_win_over_type_defaults(self):
        merged = merge_thresholds(
            {"batteryLow": 0.2}, device_type="rollator_platform"
        )
        self.assertEqual(merged["batteryLow"], 0.2)
        self.assertEqual(merged["batteryCritical"], DEFAULTS["batteryCritical"])

    def test_determine_alerts_with_device_type(self):
        alerts = determine_threshold_alerts(
            0.03, None, device_type="rollator_platform"
        )
        self.assertEqual(alerts, [("battery_critical", "critical")])
        # Legacy call shape (no kwargs) unchanged:
        self.assertEqual(
            determine_threshold_alerts(0.03, None),
            [("battery_critical", "critical")],
        )


if __name__ == "__main__":
    unittest.main()

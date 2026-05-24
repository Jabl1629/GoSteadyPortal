"""
Unit tests for alert-actions thresholds_validation — Phase 2A-AA.
"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

_LAMBDA_DIR = Path(__file__).resolve().parents[2]
_AA_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(_LAMBDA_DIR))
sys.path.insert(0, str(_AA_DIR))
sys.path.insert(0, str(Path(_LAMBDA_DIR) / "patient-api" / "tests"))
import _stub_powertools  # noqa: F401,E402

from _shared.api_error import ApiError  # noqa: E402
import thresholds_validation as tv  # noqa: E402


class TestValidateThresholdsPatch(unittest.TestCase):
    def test_empty_body_ok(self):
        self.assertEqual(tv.validate_thresholds_patch({}), {})

    def test_single_valid_field(self):
        self.assertEqual(
            tv.validate_thresholds_patch({"batteryCritical": 0.07}),
            {"batteryCritical": 0.07},
        )

    def test_explicit_null_clears(self):
        self.assertEqual(
            tv.validate_thresholds_patch({"batteryCritical": None}),
            {"batteryCritical": None},
        )

    def test_unknown_field_rejected(self):
        with self.assertRaises(ApiError) as cm:
            tv.validate_thresholds_patch({"foo": 0.1})
        self.assertEqual(cm.exception.code, "INVALID_THRESHOLD")
        self.assertIn("unknown", cm.exception.details)

    def test_battery_critical_out_of_range_low(self):
        with self.assertRaises(ApiError) as cm:
            tv.validate_thresholds_patch({"batteryCritical": 0.01})
        self.assertEqual(cm.exception.code, "INVALID_THRESHOLD")

    def test_battery_critical_out_of_range_high(self):
        with self.assertRaises(ApiError) as cm:
            tv.validate_thresholds_patch({"batteryCritical": 0.50})
        self.assertEqual(cm.exception.code, "INVALID_THRESHOLD")

    def test_ordering_low_not_greater_than_critical(self):
        with self.assertRaises(ApiError) as cm:
            tv.validate_thresholds_patch({
                "batteryCritical": 0.15,
                "batteryLow": 0.10,
            })
        self.assertEqual(cm.exception.code, "INVALID_THRESHOLD")
        viol = cm.exception.details["violations"]
        # Two violations expected:
        #   1. batteryCritical 0.15 > max allowed (0.30) — within range, fine
        #   2. batteryLow <= batteryCritical
        self.assertTrue(any("must_be_greater_than_batteryCritical" in v.get("reason", "") for v in viol))

    def test_signal_ordering(self):
        with self.assertRaises(ApiError) as cm:
            tv.validate_thresholds_patch({
                "rsrpLost": -110,
                "rsrpWeak": -120,  # weaker than lost — violates ordering
            })
        self.assertEqual(cm.exception.code, "INVALID_THRESHOLD")

    def test_rsrp_lost_out_of_range(self):
        with self.assertRaises(ApiError):
            tv.validate_thresholds_patch({"rsrpLost": -90})

    def test_non_numeric_rejected(self):
        with self.assertRaises(ApiError) as cm:
            tv.validate_thresholds_patch({"batteryCritical": "low"})
        self.assertEqual(cm.exception.code, "INVALID_THRESHOLD")

    def test_full_valid_body(self):
        result = tv.validate_thresholds_patch({
            "batteryCritical": 0.05,
            "batteryLow": 0.15,
            "rsrpLost": -125,
            "rsrpWeak": -115,
        })
        self.assertEqual(result["batteryCritical"], 0.05)
        self.assertEqual(result["batteryLow"], 0.15)
        self.assertEqual(result["rsrpLost"], -125.0)
        self.assertEqual(result["rsrpWeak"], -115.0)

    def test_int_value_coerced_to_float(self):
        result = tv.validate_thresholds_patch({"rsrpLost": -120})
        self.assertEqual(result["rsrpLost"], -120.0)
        self.assertIsInstance(result["rsrpLost"], float)


class TestValidateOrderingAgainstEffective(unittest.TestCase):
    def test_no_existing_no_violation(self):
        tv.validate_ordering_against_effective({"batteryCritical": 0.07}, None)

    def test_existing_critical_proposed_low_violates(self):
        # Existing batteryCritical=0.20; proposing batteryLow=0.15 → effective
        # batteryLow=0.15 <= batteryCritical=0.20 → violation
        from decimal import Decimal
        with self.assertRaises(ApiError) as cm:
            tv.validate_ordering_against_effective(
                {"batteryLow": 0.15},
                {"batteryCritical": Decimal("0.20")},
            )
        self.assertEqual(cm.exception.code, "INVALID_THRESHOLD")
        self.assertIn("effective_after_merge", cm.exception.details)

    def test_clear_removes_override(self):
        # Existing batteryCritical=0.07; proposing null → effective reverts
        # to default 0.05; default batteryLow 0.10 > 0.05 → OK
        from decimal import Decimal
        tv.validate_ordering_against_effective(
            {"batteryCritical": None},
            {"batteryCritical": Decimal("0.07")},
        )

    def test_clean_merge_no_violation(self):
        tv.validate_ordering_against_effective(
            {"batteryCritical": 0.05, "batteryLow": 0.20},
            None,
        )


if __name__ == "__main__":
    unittest.main()

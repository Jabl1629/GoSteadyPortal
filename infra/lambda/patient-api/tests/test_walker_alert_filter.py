"""
Unit tests for the walker-only alert read filter — patient-api.

The walker/device user must NOT see the behavioral activity-judgment alerts
about themselves (no_activity_today / below_typical_activity / declining_trend);
non-walker Care Circle caregivers and facility/internal readers see everything.
Keyed on the D2C-only `isWalkerUser` claim (normalized to a bool by
`_shared.api_authz.extract_claims` — the filter reads that normalized key, not
the raw `custom:isWalkerUser`). Device-health alerts (device_offline /
device_silent / low_battery / signal) always pass through.

Run from repo root:
    cd infra/lambda
    ../../.test-venv/bin/python patient-api/tests/test_walker_alert_filter.py
"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

_LAMBDA_DIR = Path(__file__).resolve().parents[2]
_PA_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(_LAMBDA_DIR))
sys.path.insert(0, str(_PA_DIR))

import importlib  # noqa: E402
queries = importlib.import_module("queries")

WALKER = {"isWalkerUser": True}
CAREGIVER = {"isWalkerUser": False}


def _rows() -> list[dict[str, str]]:
    """A mixed alert page: 3 behavioral activity types + 3 device-health types."""
    return [
        {"alertType": "no_activity_today", "severity": "critical"},
        {"alertType": "below_typical_activity", "severity": "standard"},
        {"alertType": "declining_trend", "severity": "standard"},
        {"alertType": "device_offline", "severity": "warning"},
        {"alertType": "device_silent", "severity": "critical"},
        {"alertType": "low_battery", "severity": "warning"},
    ]


class TestHideWalkerAlerts(unittest.TestCase):
    def test_walker_sees_only_device_health_alerts(self):
        out = queries.hide_walker_alerts(_rows(), WALKER)
        self.assertEqual(
            [r["alertType"] for r in out],
            ["device_offline", "device_silent", "low_battery"],
        )

    def test_hidden_set_is_exactly_the_three_behavioral_types(self):
        self.assertEqual(
            queries.WALKER_HIDDEN_ALERT_TYPES,
            frozenset({"no_activity_today", "below_typical_activity", "declining_trend"}),
        )

    def test_caregiver_explicit_false_sees_everything(self):
        # family_viewer / caregiver-owner — claim normalized to False.
        out = queries.hide_walker_alerts(_rows(), CAREGIVER)
        self.assertEqual(len(out), len(_rows()))

    def test_absent_claim_sees_everything(self):
        # Facility / internal token carries no isWalkerUser claim → key absent.
        out = queries.hide_walker_alerts(_rows(), {})
        self.assertEqual(len(out), len(_rows()))

    def test_only_truthy_bool_suppresses(self):
        # extract_claims normalizes to a real bool; guard the falsy variants.
        for claims in ({"isWalkerUser": False}, {"isWalkerUser": None}, {}):
            out = queries.hide_walker_alerts(_rows(), claims)
            self.assertEqual(len(out), len(_rows()), f"claims {claims!r} must not suppress")

    def test_empty_input(self):
        self.assertEqual(queries.hide_walker_alerts([], WALKER), [])

    def test_walker_with_only_behavioral_gets_empty(self):
        rows = [{"alertType": "no_activity_today"}, {"alertType": "declining_trend"}]
        self.assertEqual(queries.hide_walker_alerts(rows, WALKER), [])

    def test_walker_with_only_device_health_unchanged(self):
        rows = [{"alertType": "device_offline"}, {"alertType": "low_battery"}]
        out = queries.hide_walker_alerts(rows, WALKER)
        self.assertEqual([r["alertType"] for r in out], ["device_offline", "low_battery"])

    def test_row_without_alerttype_passes_through(self):
        # A malformed / typeless row is not one of the hidden types → kept.
        rows = [{"severity": "warning"}]
        out = queries.hide_walker_alerts(rows, WALKER)
        self.assertEqual(len(out), 1)


if __name__ == "__main__":
    unittest.main()

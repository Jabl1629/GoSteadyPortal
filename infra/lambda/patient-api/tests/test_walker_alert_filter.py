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
    """A mixed alert page across every category the walker could be sent."""
    return [
        {"alertType": "no_activity_today", "severity": "critical"},     # activity
        {"alertType": "below_typical_activity", "severity": "standard"},  # activity
        {"alertType": "declining_trend", "severity": "standard"},        # activity
        {"alertType": "device_offline", "severity": "warning"},          # offline
        {"alertType": "device_silent", "severity": "critical"},          # offline
        {"alertType": "signal_lost", "severity": "warning"},             # signal
        {"alertType": "signal_weak", "severity": "warning"},             # signal
        {"alertType": "battery_low", "severity": "warning"},             # BATTERY
        {"alertType": "battery_critical", "severity": "critical"},       # BATTERY
    ]


class TestHideWalkerAlerts(unittest.TestCase):
    def test_walker_sees_only_battery(self):
        # Allow-list: the walker's own view keeps ONLY battery — activity,
        # signal, and offline are all dropped (2026-07-20 "only battery").
        out = queries.hide_walker_alerts(_rows(), WALKER)
        self.assertEqual(
            [r["alertType"] for r in out],
            ["battery_low", "battery_critical"],
        )

    def test_visible_set_is_battery_only(self):
        self.assertEqual(
            queries.WALKER_VISIBLE_ALERT_TYPES,
            frozenset({"battery_low", "battery_critical", "low_battery", "battery"}),
        )

    def test_walker_signal_and_offline_are_hidden(self):
        # The refinement: signal + offline no longer reach the walker.
        out = {r["alertType"] for r in queries.hide_walker_alerts(_rows(), WALKER)}
        for hidden in ("signal_lost", "signal_weak", "device_offline", "device_silent"):
            self.assertNotIn(hidden, out)

    def test_caregiver_explicit_false_sees_everything(self):
        out = queries.hide_walker_alerts(_rows(), CAREGIVER)
        self.assertEqual(len(out), len(_rows()))

    def test_absent_claim_sees_everything(self):
        # Facility / internal token carries no isWalkerUser claim → key absent.
        out = queries.hide_walker_alerts(_rows(), {})
        self.assertEqual(len(out), len(_rows()))

    def test_only_truthy_bool_restricts(self):
        # extract_claims normalizes to a real bool; falsy variants see all.
        for claims in ({"isWalkerUser": False}, {"isWalkerUser": None}, {}):
            out = queries.hide_walker_alerts(_rows(), claims)
            self.assertEqual(len(out), len(_rows()), f"claims {claims!r} must not restrict")

    def test_battery_aliases_are_visible(self):
        rows = [{"alertType": t} for t in ("low_battery", "battery", "battery_low")]
        out = queries.hide_walker_alerts(rows, WALKER)
        self.assertEqual(len(out), 3)

    def test_empty_input(self):
        self.assertEqual(queries.hide_walker_alerts([], WALKER), [])

    def test_walker_with_no_battery_gets_empty(self):
        rows = [{"alertType": "signal_lost"}, {"alertType": "device_offline"}]
        self.assertEqual(queries.hide_walker_alerts(rows, WALKER), [])

    def test_typeless_row_hidden_from_walker_but_kept_for_caregiver(self):
        # Allow-list default-denies: a malformed/typeless row is not battery →
        # dropped from the walker's view, but caregivers still see it.
        rows = [{"severity": "warning"}]
        self.assertEqual(queries.hide_walker_alerts(rows, WALKER), [])
        self.assertEqual(len(queries.hide_walker_alerts(rows, CAREGIVER)), 1)


if __name__ == "__main__":
    unittest.main()

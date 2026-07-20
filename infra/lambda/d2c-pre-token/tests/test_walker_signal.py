"""
Unit tests for the D2C pre-token walker-signal resolution.

`resolve_is_walker_user` derives the `custom:isWalkerUser` claim: an ABSENT flag
on a legacy owner row (minted before the flag was written) is inferred from role
— a solo `household_owner` IS the walker — so the signal stays reliable across
dev+prod without a bulk RoleAssignments backfill; an EXPLICIT False (a
caregiver-owner) is preserved.

Run from repo root:
    cd infra/lambda
    ../../.test-venv/bin/python d2c-pre-token/tests/test_walker_signal.py
"""

from __future__ import annotations

import os
import sys
import unittest
from pathlib import Path

_PT_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(_PT_DIR))

# handler.py binds a DDB Table at import from these (both lazy — no network).
os.environ.setdefault("ROLE_ASSIGNMENTS_TABLE", "test-role-assignments")
os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")

import importlib  # noqa: E402
handler = importlib.import_module("handler")
resolve = handler.resolve_is_walker_user


class TestResolveIsWalkerUser(unittest.TestCase):
    def test_no_row_bootstrap_owner_is_walker(self):
        # Brand-new signup, pre-/claim: no row, caller passes owner default.
        self.assertEqual(resolve(None, "household_owner"), "true")

    def test_owner_row_explicit_true(self):
        self.assertEqual(resolve({"isWalkerUser": True}, "household_owner"), "true")

    def test_caregiver_owner_explicit_false_preserved(self):
        # The one case that must NOT be promoted: an owner who is NOT the walker.
        self.assertEqual(resolve({"isWalkerUser": False}, "household_owner"), "false")

    def test_legacy_owner_absent_flag_derives_true(self):
        # The reliability fix: a legacy owner row with no isWalkerUser attribute
        # now yields "true" (it would have emitted "false" before the self-heal).
        row = {"clientId": "dtc_x", "role": "household_owner"}
        self.assertEqual(resolve(row, "household_owner"), "true")

    def test_member_absent_flag_is_false(self):
        self.assertEqual(resolve({"role": "family_viewer"}, "family_viewer"), "false")

    def test_member_explicit_true_linked_walker(self):
        # A Care Circle member linked as the walker (care-circle D11).
        self.assertEqual(resolve({"isWalkerUser": True}, "family_viewer"), "true")

    def test_explicit_none_behaves_like_absent(self):
        self.assertEqual(resolve({"isWalkerUser": None}, "household_owner"), "true")


class TestHandlerEmitsClaim(unittest.TestCase):
    """The claim is wired into both id + access token override blocks."""

    def _run(self, row, sub="sub-123"):
        # Stub the DDB read so handler() is exercised without a live table.
        handler._table.get_item = lambda **_: {"Item": row} if row else {}
        event = {"request": {"userAttributes": {"sub": sub}}, "response": {}}
        out = handler.handler(event, None)
        return out["response"]["claimsAndScopeOverrideDetails"]

    def test_legacy_owner_row_emits_true_in_both_tokens(self):
        details = self._run({"clientId": "dtc_x", "role": "household_owner"})
        for block in ("idTokenGeneration", "accessTokenGeneration"):
            claims = details[block]["claimsToAddOrOverride"]
            self.assertEqual(claims["custom:isWalkerUser"], "true")
            self.assertEqual(claims["custom:role"], "household_owner")

    def test_caregiver_owner_row_emits_false(self):
        details = self._run(
            {"clientId": "dtc_x", "role": "household_owner", "isWalkerUser": False}
        )
        claims = details["idTokenGeneration"]["claimsToAddOrOverride"]
        self.assertEqual(claims["custom:isWalkerUser"], "false")

    def test_no_row_bootstrap_emits_true(self):
        details = self._run(None)
        claims = details["idTokenGeneration"]["claimsToAddOrOverride"]
        self.assertEqual(claims["custom:isWalkerUser"], "true")
        self.assertEqual(claims["custom:clientId"], "dtc_sub-123")


if __name__ == "__main__":
    unittest.main()

"""
Unit tests for the pure d2c-claim helpers (household anchor + identity split +
contact masking). No AWS/boto3 — claim_logic.py is import-clean.

Run:  python3 infra/lambda/d2c-claim/tests/test_claim_logic.py
  or:  cd infra/lambda && python3 -m pytest d2c-claim/tests/test_claim_logic.py
"""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))  # d2c-claim/

from claim_logic import (  # noqa: E402
    mask_contact,
    resolve_household,
    resolve_identity,
)


class ResolveHousehold(unittest.TestCase):
    def test_new_household_mints_uuid_not_sub(self):
        cid, hh, is_new = resolve_household(None, "sub-abc-123")
        self.assertTrue(is_new)
        self.assertTrue(cid.startswith("dtc_"))
        self.assertEqual(cid, f"dtc_{hh}")
        # The whole point: the household is NOT welded to the Cognito sub.
        self.assertNotIn("sub-abc-123", cid)

    def test_returning_user_reuses_existing_client(self):
        cid, hh, is_new = resolve_household({"clientId": "dtc_household123"}, "sub-abc")
        self.assertFalse(is_new)
        self.assertEqual(cid, "dtc_household123")
        self.assertEqual(hh, "household123")

    def test_empty_role_row_is_treated_as_new(self):
        cid, _hh, is_new = resolve_household({}, "sub-x")
        self.assertTrue(is_new)
        self.assertTrue(cid.startswith("dtc_"))

    def test_two_new_claims_get_distinct_households(self):
        a, _, _ = resolve_household(None, "s")
        b, _, _ = resolve_household(None, "s")
        self.assertNotEqual(a, b)


class ResolveIdentity(unittest.TestCase):
    def test_solo_self_claim_owner_is_walker(self):
        owner, walker, owner_is_walker = resolve_identity(
            {"displayName": "Grandma Sue"}, {"name": "Grandma Sue"})
        self.assertTrue(owner_is_walker)
        self.assertEqual(owner, "Grandma Sue")
        self.assertEqual(walker, "Grandma Sue")

    def test_caregiver_setup_splits_owner_and_walker(self):
        owner, walker, owner_is_walker = resolve_identity(
            {"caregiverSetup": True, "ownerName": "Kate (daughter)", "walkerName": "Mom"},
            {"name": "Kate"})
        self.assertFalse(owner_is_walker)
        self.assertEqual(owner, "Kate (daughter)")
        self.assertEqual(walker, "Mom")

    def test_caregiver_setup_defaults_walker_name(self):
        owner, walker, owner_is_walker = resolve_identity(
            {"caregiverSetup": True}, {"name": "Kate"})
        self.assertFalse(owner_is_walker)
        self.assertEqual(owner, "Kate")
        self.assertEqual(walker, "Walker user")

    def test_falls_back_to_jwt_name(self):
        owner, walker, owner_is_walker = resolve_identity({}, {"name": "Pat"})
        self.assertEqual(owner, "Pat")
        self.assertEqual(walker, "Pat")
        self.assertTrue(owner_is_walker)

    def test_no_names_at_all_uses_safe_defaults(self):
        owner, walker, _ = resolve_identity({}, {})
        self.assertEqual(owner, "Account holder")
        self.assertEqual(walker, "Account holder")  # solo → walker mirrors owner


class MaskContact(unittest.TestCase):
    def test_phone_tail_preferred(self):
        self.assertEqual(mask_contact(phone="+1 (555) 123-4567", email="a@b.co"), "•••67")

    def test_email_when_no_phone(self):
        self.assertEqual(mask_contact(phone="", email="jace@gosteady.co"), "j•••@gosteady.co")

    def test_neutral_when_neither(self):
        self.assertEqual(mask_contact(phone="", email=""), "another account")

    def test_short_phone_falls_through_to_email(self):
        self.assertEqual(mask_contact(phone="1", email="k@x.io"), "k•••@x.io")


if __name__ == "__main__":
    unittest.main(verbosity=2)

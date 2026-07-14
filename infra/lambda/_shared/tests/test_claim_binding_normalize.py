"""
Unit tests for _shared.claim_binding.normalize_e164 — pins the prod
incident (2026-07-14): "+5165891580" (a US 10-digit number typed WITH a
stray "+" but no country code) must normalize to "+15165891580", NOT be
trusted as country code +516 (which made Twilio reject the OTP, error
21408).

These MUST stay in lockstep with the frontend `_normalizePhone`
(lib/d2c/auth/d2c_auth_service.dart) — bind side + signup/OTP side both
feed this canonical form.

Run from repo root:
    cd infra/lambda && python3 -m unittest _shared.tests.test_claim_binding_normalize
"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

sys.path.insert(0, str(Path(__file__).resolve().parent))
import _stub_powertools  # noqa: F401,E402

from _shared.claim_binding import (  # noqa: E402
    PhoneFormatError,
    hmac_phone,
    normalize_e164,
)


class TestNormalizeE164(unittest.TestCase):
    def test_incident_plus_prefixed_us_10_digit(self):
        # The exact prod failure: US number typed with a stray "+".
        self.assertEqual(normalize_e164("+5165891580"), "+15165891580")

    def test_us_forms_all_canonical(self):
        for raw in ("5165891580", "+5165891580", "15165891580",
                    "+15165891580", "1 516 589 1580", "(516) 589-1580",
                    "516-589-1580", "  +1 (516) 589-1580  "):
            self.assertEqual(normalize_e164(raw), "+15165891580", raw)

    def test_bind_and_claim_hash_equal_across_formats(self):
        # The load-bearing property: whatever the operator typed at bind and
        # the user typed at signup, the HMACs agree.
        pepper = "p"
        bound = hmac_phone(pepper, normalize_e164("+5165891580"))   # operator typo
        claim = hmac_phone(pepper, normalize_e164("516-589-1580"))  # user's form
        self.assertEqual(bound, claim)

    def test_genuine_international_preserved(self):
        # A non-US-shaped number typed with "+" is trusted as intl.
        self.assertEqual(normalize_e164("+445165891580"), "+445165891580")

    def test_unparseable_raises(self):
        for bad in ("", "   ", "abc", "+", "12345"):
            with self.assertRaises(PhoneFormatError, msg=bad):
                normalize_e164(bad)


if __name__ == "__main__":
    unittest.main()

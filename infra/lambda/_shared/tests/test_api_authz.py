"""
Unit tests for the _shared/api_authz.py helpers — focused on the new
enforce_internal_session_age helper added under the 2A-0 unified-portal
amendment (Q8). Co-located tests for extract_claims's iat extension.

Run from `infra/lambda/`:
    PYTHONPATH=. python3 -m unittest _shared.tests.test_api_authz
"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

_LAMBDA_DIR = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(_LAMBDA_DIR))

sys.path.insert(0, str(Path(__file__).resolve().parent))
import _stub_powertools  # noqa: F401,E402

from _shared.api_authz import (  # noqa: E402
    INTERNAL_SESSION_MAX_AGE_SECONDS,
    enforce_internal_session_age,
    extract_claims,
)
from _shared.api_error import ApiError  # noqa: E402


def _claims(**overrides):
    """Build a claims dict — defaults to a customer caregiver with a
    fresh iat. Tests override fields they care about."""
    base = {
        "userId": "u_test",
        "email": "t@example.com",
        "clientId": "client_005",
        "role": "caregiver",
        "facilities": ["fac_012"],
        "censuses": ["cen_044"],
        "mfaEnrolled": False,
        "iat": 1_700_000_000,  # arbitrary fixed epoch
    }
    base.update(overrides)
    return base


# ──────────────────────────────────────────────────────────────────────
# extract_claims iat extraction
# ──────────────────────────────────────────────────────────────────────


class TestExtractClaimsIat(unittest.TestCase):
    """The middleware's session-age check depends on iat surfacing through
    extract_claims as an int. These tests guard that contract."""

    def _event(self, jwt_claims: dict) -> dict:
        return {
            "requestContext": {
                "authorizer": {"jwt": {"claims": jwt_claims}}
            }
        }

    def test_iat_present_as_int(self):
        claims = extract_claims(self._event({"sub": "u1", "iat": "1700000000"}))
        self.assertEqual(claims["iat"], 1_700_000_000)

    def test_iat_present_as_int_native(self):
        claims = extract_claims(self._event({"sub": "u1", "iat": 1700000000}))
        self.assertEqual(claims["iat"], 1_700_000_000)

    def test_iat_missing_defaults_zero(self):
        claims = extract_claims(self._event({"sub": "u1"}))
        self.assertEqual(claims["iat"], 0)

    def test_iat_unparseable_defaults_zero(self):
        claims = extract_claims(self._event({"sub": "u1", "iat": "not-a-number"}))
        self.assertEqual(claims["iat"], 0)

    def test_iat_none_defaults_zero(self):
        claims = extract_claims(self._event({"sub": "u1", "iat": None}))
        self.assertEqual(claims["iat"], 0)


# ──────────────────────────────────────────────────────────────────────
# enforce_internal_session_age
# ──────────────────────────────────────────────────────────────────────


class TestEnforceInternalSessionAge(unittest.TestCase):
    """The core absolute-cap check for internal_* roles under unified
    portal model. Customer roles must be unaffected."""

    # ── Customer roles pass regardless of iat ──────────────────────

    def test_caregiver_passes_with_fresh_iat(self):
        c = _claims(role="caregiver", iat=1_700_000_000)
        enforce_internal_session_age(c, now_fn=lambda: 1_700_000_001)

    def test_caregiver_passes_with_ancient_iat(self):
        """A 30-day-old token from a caregiver is fine here — that's
        the natural Cognito refresh-token-lifecycle territory."""
        c = _claims(role="caregiver", iat=1_700_000_000)
        enforce_internal_session_age(c, now_fn=lambda: 1_700_000_000 + 30 * 86400)

    def test_caregiver_passes_with_zero_iat(self):
        """Customer roles bypass the check entirely; missing iat is fine."""
        c = _claims(role="caregiver", iat=0)
        enforce_internal_session_age(c, now_fn=lambda: 1_700_000_000)

    def test_facility_admin_passes(self):
        c = _claims(role="facility_admin", iat=1_700_000_000)
        enforce_internal_session_age(c, now_fn=lambda: 1_700_000_001)

    def test_client_admin_passes(self):
        c = _claims(role="client_admin", iat=1_700_000_000)
        enforce_internal_session_age(c, now_fn=lambda: 1_700_000_001)

    def test_household_owner_passes(self):
        c = _claims(role="household_owner", iat=1_700_000_000)
        enforce_internal_session_age(c, now_fn=lambda: 1_700_000_001)

    def test_family_viewer_passes(self):
        c = _claims(role="family_viewer", iat=1_700_000_000)
        enforce_internal_session_age(c, now_fn=lambda: 1_700_000_001)

    # ── Internal roles: fresh iat passes ───────────────────────────

    def test_internal_admin_fresh_iat_passes(self):
        c = _claims(role="internal_admin", iat=1_700_000_000)
        enforce_internal_session_age(c, now_fn=lambda: 1_700_000_001)

    def test_internal_support_fresh_iat_passes(self):
        c = _claims(role="internal_support", iat=1_700_000_000)
        enforce_internal_session_age(c, now_fn=lambda: 1_700_000_001)

    def test_internal_admin_iat_one_minute_old_passes(self):
        c = _claims(role="internal_admin", iat=1_700_000_000)
        enforce_internal_session_age(c, now_fn=lambda: 1_700_000_000 + 60)

    def test_internal_admin_iat_3h59m_old_passes(self):
        c = _claims(role="internal_admin", iat=1_700_000_000)
        almost_cap = 1_700_000_000 + 3 * 3600 + 59 * 60  # 3h59m
        enforce_internal_session_age(c, now_fn=lambda: almost_cap)

    def test_internal_admin_at_exact_cap_passes(self):
        """Boundary: age == cap is the last "still valid" second."""
        c = _claims(role="internal_admin", iat=1_700_000_000)
        at_cap = 1_700_000_000 + INTERNAL_SESSION_MAX_AGE_SECONDS
        enforce_internal_session_age(c, now_fn=lambda: at_cap)

    # ── Internal roles: stale iat raises 401 ───────────────────────

    def test_internal_admin_over_cap_raises_401(self):
        c = _claims(role="internal_admin", iat=1_700_000_000)
        over_cap = 1_700_000_000 + INTERNAL_SESSION_MAX_AGE_SECONDS + 1
        with self.assertRaises(ApiError) as cm:
            enforce_internal_session_age(c, now_fn=lambda: over_cap)
        self.assertEqual(cm.exception.code, "INTERNAL_SESSION_EXPIRED")
        self.assertEqual(cm.exception.status, 401)
        self.assertIn("sessionAgeSeconds", cm.exception.details or {})

    def test_internal_support_24h_old_raises(self):
        c = _claims(role="internal_support", iat=1_700_000_000)
        a_day_later = 1_700_000_000 + 24 * 3600
        with self.assertRaises(ApiError) as cm:
            enforce_internal_session_age(c, now_fn=lambda: a_day_later)
        self.assertEqual(cm.exception.code, "INTERNAL_SESSION_EXPIRED")
        self.assertEqual(cm.exception.status, 401)

    # ── Internal roles: missing iat raises 401 ─────────────────────

    def test_internal_admin_missing_iat_raises(self):
        c = _claims(role="internal_admin", iat=0)
        with self.assertRaises(ApiError) as cm:
            enforce_internal_session_age(c, now_fn=lambda: 1_700_000_000)
        self.assertEqual(cm.exception.code, "INTERNAL_SESSION_EXPIRED")
        self.assertEqual(cm.exception.status, 401)
        self.assertEqual(cm.exception.details.get("missingClaim"), "iat")

    def test_internal_admin_iat_none_raises(self):
        c = _claims(role="internal_admin")
        c["iat"] = None
        with self.assertRaises(ApiError) as cm:
            enforce_internal_session_age(c, now_fn=lambda: 1_700_000_000)
        self.assertEqual(cm.exception.code, "INTERNAL_SESSION_EXPIRED")

    # ── Configurable max_age_seconds ───────────────────────────────

    def test_custom_max_age_seconds_honored(self):
        """Allow callers to tighten the cap (e.g., for a high-stakes
        endpoint) without forking the helper."""
        c = _claims(role="internal_admin", iat=1_700_000_000)
        # 60-min cap; 61 minutes elapsed
        sixty_one_min = 1_700_000_000 + 61 * 60
        with self.assertRaises(ApiError):
            enforce_internal_session_age(
                c, max_age_seconds=60 * 60, now_fn=lambda: sixty_one_min
            )

    def test_custom_max_age_under_cap_passes(self):
        c = _claims(role="internal_admin", iat=1_700_000_000)
        thirty_min = 1_700_000_000 + 30 * 60
        enforce_internal_session_age(
            c, max_age_seconds=60 * 60, now_fn=lambda: thirty_min
        )


if __name__ == "__main__":
    unittest.main()

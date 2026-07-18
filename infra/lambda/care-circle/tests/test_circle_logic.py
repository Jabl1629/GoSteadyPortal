"""
Unit tests for circle_logic (pure helpers) — d2c-care-circle.md §8
T4/T12/T15 slices plus row/view shaping.

Run from repo root:
    cd infra/lambda
    python3 -m pytest care-circle/tests -q
"""

from __future__ import annotations

import sys
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

_LAMBDA_DIR = Path(__file__).resolve().parents[2]
_CC_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(_LAMBDA_DIR))
sys.path.insert(0, str(_CC_DIR))

# _shared/__init__ imports observability → powertools; stub it first.
sys.path.insert(0, str(Path(__file__).resolve().parent))
import _stub_powertools  # noqa: F401,E402

import circle_logic as cl  # noqa: E402
from _shared.api_error import ApiError  # noqa: E402

NOW = datetime(2026, 7, 14, 12, 0, 0, tzinfo=timezone.utc)


def _validated(**over):
    base = {
        "name": "Jane Davis",
        "phoneE164": "+15125550100",
        "relationship": "Daughter",
        "role": "family_viewer",
        "isWalkerUser": False,
    }
    base.update(over)
    return base


def _invite(**over):
    invite = cl.build_invite_item(
        client_id="dtc_h1",
        contact_hash="hash-abc",
        phone_e164="+15125550100",
        validated=_validated(),
        invited_by="owner-sub",
        inviter_name="Sarah",
        household_name="Susan's household",
        walker_name="Susan",
        patient_ids=["pat_1"],
        now=NOW,
    )
    invite.update(over)
    return invite


class TestValidateInviteInput(unittest.TestCase):
    def test_happy_path_normalizes_phone(self):
        v = cl.validate_invite_input(
            {"name": " Jane ", "phone": "(512) 555-0100", "relationship": "Daughter"}
        )
        self.assertEqual(v["name"], "Jane")
        self.assertEqual(v["phoneE164"], "+15125550100")
        self.assertEqual(v["role"], "family_viewer")  # default
        self.assertFalse(v["isWalkerUser"])

    def test_t15_stray_plus_us_number_normalizes(self):
        # The 2026-07-14 stray-"+" fix semantics must hold here too.
        v = cl.validate_invite_input({"name": "J", "phone": "+5125550100"})
        self.assertEqual(v["phoneE164"], "+15125550100")

    def test_missing_name_rejected(self):
        with self.assertRaises(ApiError) as ctx:
            cl.validate_invite_input({"phone": "+15125550100"})
        self.assertEqual(ctx.exception.code, "INVALID_REQUEST")

    def test_bad_phone_rejected(self):
        with self.assertRaises(ApiError) as ctx:
            cl.validate_invite_input({"name": "J", "phone": "12345"})
        self.assertEqual(ctx.exception.code, "INVALID_PHONE")

    def test_bad_role_rejected(self):
        with self.assertRaises(ApiError) as ctx:
            cl.validate_invite_input(
                {"name": "J", "phone": "+15125550100", "role": "caregiver"}
            )
        self.assertEqual(ctx.exception.code, "INVALID_REQUEST")

    def test_owner_role_and_walker_flag_pass_through(self):
        v = cl.validate_invite_input(
            {"name": "J", "phone": "+15125550100",
             "role": "household_owner", "isWalkerUser": True}
        )
        self.assertEqual(v["role"], "household_owner")
        self.assertTrue(v["isWalkerUser"])


class TestInviteLifecycle(unittest.TestCase):
    def test_expiry_windows(self):
        expires_at, ttl = cl.invite_expiry(NOW)
        self.assertEqual(cl.parse_iso(expires_at), NOW + timedelta(days=14))
        self.assertEqual(
            ttl, int((NOW + timedelta(days=14 + 90)).timestamp())
        )

    def test_t4_live_predicate(self):
        live = _invite()
        self.assertTrue(cl.invite_is_live(live, NOW))
        self.assertFalse(cl.invite_is_live(_invite(status="revoked"), NOW))
        self.assertFalse(cl.invite_is_live(_invite(status="accepted"), NOW))
        # Expired-but-pending is NOT live.
        self.assertFalse(
            cl.invite_is_live(live, NOW + timedelta(days=15))
        )
        self.assertFalse(cl.invite_is_live(_invite(expiresAt="garbage"), NOW))


class TestInviteItem(unittest.TestCase):
    def test_row_shape(self):
        invite = _invite()
        self.assertEqual(invite["clientId"], "dtc_h1")
        self.assertEqual(invite["status"], "pending")
        self.assertEqual(invite["contactHash"], "hash-abc")
        self.assertEqual(invite["contactMask"], "•••-0100")
        # Raw destination stored for resend (identity-CMK at rest).
        self.assertEqual(invite["contactE164"], "+15125550100")
        self.assertEqual(invite["contactChannel"], "phone")
        self.assertEqual(invite["patientIds"], {"pat_1"})
        # Send-time display snapshots for zero-join pending views.
        self.assertEqual(invite["walkerName"], "Susan")
        self.assertEqual(invite["inviterName"], "Sarah")
        self.assertEqual(invite["householdName"], "Susan's household")

    def test_sms_body_carries_join_link_not_credentials(self):
        invite = _invite()
        body = cl.invite_sms_body(invite, "https://app.gosteady.co")
        self.assertIn(f"/join/{invite['inviteId']}", body)
        self.assertIn("Susan", body)
        self.assertNotIn("hash", body)

    def test_confirm_sms_body_carries_durable_link(self):
        invite = _invite()
        body = cl.confirm_sms_body(invite, "https://app.gosteady.co")
        # Same durable /join link the member can re-open to get back in.
        self.assertIn(f"/join/{invite['inviteId']}", body)
        self.assertIn("Susan", body)
        self.assertIn("STOP", body)  # opt-out compliance
        self.assertNotIn("hash", body)


class TestMemberRow(unittest.TestCase):
    def test_viewer_row_gets_linked_patients(self):
        invite = _invite()
        row = cl.build_member_row(
            user_id="member-sub",
            invite=invite,
            claims={"name": "Jane", "email": "j@x.com", "phoneNumber": "+15125550100"},
            active_patient_ids=["pat_1", "pat_2"],
            now=NOW,
        )
        self.assertEqual(row["role"], "family_viewer")
        self.assertEqual(row["role_userId"], "family_viewer#member-sub")
        self.assertEqual(row["linkedPatientIds"], {"pat_1", "pat_2"})
        self.assertEqual(row["clientId"], "dtc_h1")
        self.assertEqual(row["invitedVia"], invite["inviteId"])
        self.assertEqual(row["assignedBy"], "owner-sub")
        self.assertEqual(row["displayName"], "Jane Davis")  # invite name wins

    def test_owner_row_is_client_scoped(self):
        invite = _invite()
        invite["role"] = "household_owner"
        row = cl.build_member_row(
            user_id="member-sub", invite=invite, claims={},
            active_patient_ids=["pat_1"], now=NOW,
        )
        self.assertEqual(row["role"], "household_owner")
        self.assertNotIn("linkedPatientIds", row)

    def test_walker_user_flag_propagates(self):
        invite = _invite()
        invite["isWalkerUser"] = True
        row = cl.build_member_row(
            user_id="m", invite=invite, claims={}, active_patient_ids=[], now=NOW,
        )
        self.assertTrue(row["isWalkerUser"])
        self.assertNotIn("linkedPatientIds", row)  # empty set never written

    def test_agreement_version_stamped_when_provided(self):
        row = cl.build_member_row(
            user_id="m", invite=_invite(), claims={},
            active_patient_ids=["pat_1"], now=NOW,
            agreement_version="2026-07-18",
        )
        self.assertEqual(row["agreementVersion"], "2026-07-18")
        self.assertEqual(row["agreementAcceptedAt"], cl.iso(NOW))

    def test_agreement_absent_when_not_provided(self):
        row = cl.build_member_row(
            user_id="m", invite=_invite(), claims={},
            active_patient_ids=["pat_1"], now=NOW,
        )
        self.assertNotIn("agreementVersion", row)
        self.assertNotIn("agreementAcceptedAt", row)


class TestViews(unittest.TestCase):
    def test_member_view_masks_phone_and_never_leaks_raw(self):
        view = cl.member_view(
            {"userId": "u1", "displayName": "Jane", "relationship": "Daughter",
             "role": "family_viewer", "isWalkerUser": False,
             "phone": "512 555 0100", "validFrom": "2026-07-14T12:00:00Z"},
            viewer_user_id="u1",
        )
        self.assertEqual(view["contactMask"], "•••-0100")
        self.assertTrue(view["isViewer"])
        self.assertNotIn("phone", view)

    def test_member_view_tolerates_bad_phone(self):
        view = cl.member_view({"userId": "u1", "phone": "junk"})
        self.assertEqual(view["contactMask"], "")

    def test_synthesized_walker(self):
        view = cl.synthesized_walker_view(
            {"displayName": "Susan", "createdAt": "2026-07-01T00:00:00Z"}
        )
        self.assertIsNone(view["userId"])
        self.assertTrue(view["isWalkerUser"])
        self.assertEqual(view["displayName"], "Susan")

    def test_pending_view_variants(self):
        invite = _invite()
        admin = cl.pending_invite_view(invite, include_contact=True)
        self.assertEqual(admin["contactMask"], "•••-0100")
        self.assertNotIn("householdName", admin)
        invitee = cl.pending_invite_view(invite, include_contact=False)
        self.assertEqual(invitee["householdName"], "Susan's household")
        self.assertEqual(invitee["walkerName"], "Susan")
        self.assertNotIn("contactMask", invitee)
        for v in (admin, invitee):
            self.assertNotIn("contactE164", v)
            self.assertNotIn("contactHash", v)


if __name__ == "__main__":
    unittest.main()

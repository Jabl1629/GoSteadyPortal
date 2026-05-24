"""
Unit tests for resolve_list_scope and enforce_patient_access — Phase 2A-RD.

Run from `infra/lambda/`:
    PYTHONPATH=. python3 -m unittest patient-api.tests.test_scope
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
    enforce_patient_access,
    resolve_list_scope,
)
from _shared.api_error import ApiError  # noqa: E402


def _claims(**overrides):
    base = {
        "userId": "u_test", "email": "t@example.com",
        "clientId": "client_005", "role": "caregiver",
        "facilities": ["fac_012"], "censuses": ["cen_044"],
        "mfaEnrolled": False,
    }
    base.update(overrides)
    return base


class TestResolveListScope(unittest.TestCase):
    def test_caregiver_with_censuses_uses_by_census(self):
        plan = resolve_list_scope(_claims(role="caregiver",
                                         censuses=["cen_044", "cen_045"]))
        self.assertEqual(plan["pattern"], "by-census")
        self.assertEqual(plan["censusIds"], ["cen_044", "cen_045"])
        self.assertEqual(plan["clientId"], "client_005")
        self.assertFalse(plan["internalAccess"])

    def test_caregiver_with_no_censuses_no_data(self):
        plan = resolve_list_scope(_claims(role="caregiver", censuses=[]))
        self.assertEqual(plan["pattern"], "no-data")

    def test_facility_admin_with_facilities_uses_by_client(self):
        plan = resolve_list_scope(_claims(role="facility_admin",
                                         facilities=["fac_012"], censuses=[]))
        self.assertEqual(plan["pattern"], "by-client")
        self.assertEqual(plan["facilityIds"], ["fac_012"])

    def test_facility_admin_with_empty_facilities_is_all_client(self):
        plan = resolve_list_scope(_claims(role="facility_admin",
                                         facilities=[], censuses=[]))
        self.assertEqual(plan["pattern"], "by-client")
        self.assertEqual(plan["facilityIds"], [])

    def test_client_admin_by_client(self):
        plan = resolve_list_scope(_claims(role="client_admin",
                                         facilities=[], censuses=[]))
        self.assertEqual(plan["pattern"], "by-client")
        self.assertEqual(plan["clientId"], "client_005")

    def test_household_owner_by_client(self):
        plan = resolve_list_scope(_claims(role="household_owner",
                                         clientId="dtc_user123",
                                         facilities=[], censuses=[]))
        self.assertEqual(plan["pattern"], "by-client")
        self.assertEqual(plan["clientId"], "dtc_user123")

    def test_family_viewer_uses_patient_ids_pattern(self):
        plan = resolve_list_scope(_claims(role="family_viewer",
                                         facilities=[], censuses=[]))
        self.assertEqual(plan["pattern"], "by-patient-ids")

    def test_internal_admin_requires_client_id(self):
        # No internal_client_id → no-data (defensive)
        plan = resolve_list_scope(_claims(role="internal_admin",
                                         clientId="_internal",
                                         facilities=[], censuses=[]))
        self.assertEqual(plan["pattern"], "no-data")
        self.assertTrue(plan["internalAccess"])

    def test_internal_admin_with_client_id_resolves(self):
        plan = resolve_list_scope(
            _claims(role="internal_admin", clientId="_internal",
                    facilities=[], censuses=[]),
            internal_client_id="client_006",
        )
        self.assertEqual(plan["pattern"], "by-client")
        self.assertEqual(plan["clientId"], "client_006")
        self.assertTrue(plan["internalAccess"])

    def test_internal_support_same_as_admin(self):
        plan = resolve_list_scope(
            _claims(role="internal_support", clientId="_internal"),
            internal_client_id="client_006",
        )
        self.assertEqual(plan["pattern"], "by-client")
        self.assertTrue(plan["internalAccess"])


class TestEnforcePatientAccess(unittest.TestCase):
    def _patient(self, **overrides):
        base = {
            "patientId": "pat_abc",
            "clientId": "client_005",
            "facilityId": "fac_012",
            "censusId": "cen_044",
            "status": "active",
        }
        base.update(overrides)
        return base

    def test_internal_admin_bypasses_everything(self):
        # No raise expected
        enforce_patient_access(
            _claims(role="internal_admin", clientId="_internal"),
            self._patient(clientId="client_006"),
        )

    def test_caregiver_in_scope_allowed(self):
        enforce_patient_access(_claims(role="caregiver"), self._patient())

    def test_caregiver_wrong_client_tenancy_violation(self):
        with self.assertRaises(ApiError) as cm:
            enforce_patient_access(_claims(role="caregiver", clientId="client_999"),
                                   self._patient(clientId="client_005"))
        self.assertEqual(cm.exception.code, "TENANCY_VIOLATION")
        self.assertEqual(cm.exception.status, 403)

    def test_caregiver_wrong_census_out_of_scope(self):
        with self.assertRaises(ApiError) as cm:
            enforce_patient_access(_claims(role="caregiver",
                                           censuses=["cen_999"]),
                                   self._patient(censusId="cen_044"))
        self.assertEqual(cm.exception.code, "OUT_OF_SCOPE")

    def test_facility_admin_wrong_facility_out_of_scope(self):
        with self.assertRaises(ApiError) as cm:
            enforce_patient_access(_claims(role="facility_admin",
                                           facilities=["fac_999"]),
                                   self._patient(facilityId="fac_012"))
        self.assertEqual(cm.exception.code, "OUT_OF_SCOPE")

    def test_family_viewer_linked_allowed(self):
        enforce_patient_access(
            _claims(role="family_viewer", facilities=[], censuses=[]),
            self._patient(patientId="pat_abc"),
            linked_ids={"pat_abc", "pat_xyz"},
        )

    def test_family_viewer_not_linked_returns_404(self):
        with self.assertRaises(ApiError) as cm:
            enforce_patient_access(
                _claims(role="family_viewer", facilities=[], censuses=[]),
                self._patient(patientId="pat_abc"),
                linked_ids={"pat_other"},
            )
        # 404, not 403 — existence-leak prevention per spec D2.
        self.assertEqual(cm.exception.code, "PATIENT_NOT_FOUND")
        self.assertEqual(cm.exception.status, 404)

    def test_family_viewer_no_linked_ids_returns_404(self):
        with self.assertRaises(ApiError) as cm:
            enforce_patient_access(
                _claims(role="family_viewer", facilities=[], censuses=[]),
                self._patient(),
                linked_ids=set(),
            )
        self.assertEqual(cm.exception.code, "PATIENT_NOT_FOUND")

    def test_household_owner_in_own_client_allowed(self):
        enforce_patient_access(
            _claims(role="household_owner", clientId="dtc_user1",
                    facilities=[], censuses=[]),
            self._patient(clientId="dtc_user1"),
        )

    def test_household_owner_cross_household_tenancy_violation(self):
        with self.assertRaises(ApiError) as cm:
            enforce_patient_access(
                _claims(role="household_owner", clientId="dtc_user1",
                        facilities=[], censuses=[]),
                self._patient(clientId="dtc_user2"),
            )
        self.assertEqual(cm.exception.code, "TENANCY_VIOLATION")


if __name__ == "__main__":
    unittest.main()

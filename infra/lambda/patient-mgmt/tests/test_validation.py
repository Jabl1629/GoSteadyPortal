"""
Unit tests for patient-mgmt/validation.py — Phase 2A-UM-P.

Run from `infra/lambda/`:
    PYTHONPATH=. python3 -m unittest discover patient-mgmt/tests
"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

_LAMBDA_DIR = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(_LAMBDA_DIR))
_HANDLER_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(_HANDLER_DIR))

sys.path.insert(0, str(Path(__file__).resolve().parent))
import _stub_powertools  # noqa: F401,E402

from _shared.api_error import ApiError  # noqa: E402
from validation import (  # noqa: E402
    CARE_NOTE_MAX_CHARS,
    DEVICE_SERIAL_RE,
    DISPLAY_NAME_MAX_LEN,
    PAUSE_DAYS_MAX,
    ROOM_MAX_LEN,
    VALID_DISCHARGE_REASONS,
    VALID_PAUSE_REASONS,
    validate_care_note_body,
    validate_care_note_text,
    validate_census_id,
    validate_create_patient_body,
    validate_device_serial,
    validate_discharge_body,
    validate_discharge_notes,
    validate_discharge_reason,
    validate_display_name,
    validate_pause_body,
    validate_pause_days,
    validate_pause_reason,
    validate_room,
    validate_update_patient_body,
)


# ── display name ──────────────────────────────────────────────────────


class TestDisplayName(unittest.TestCase):
    def test_happy(self):
        self.assertEqual(validate_display_name("Margaret O'Sullivan"), "Margaret O'Sullivan")

    def test_trims_surrounding_whitespace(self):
        self.assertEqual(validate_display_name("  Margaret  "), "Margaret")

    def test_empty_rejected(self):
        with self.assertRaises(ApiError) as cm:
            validate_display_name("")
        self.assertEqual(cm.exception.code, "INVALID_REQUEST")
        self.assertEqual(cm.exception.status, 400)

    def test_whitespace_only_rejected(self):
        with self.assertRaises(ApiError):
            validate_display_name("   ")

    def test_too_long_rejected(self):
        too_long = "x" * (DISPLAY_NAME_MAX_LEN + 1)
        with self.assertRaises(ApiError) as cm:
            validate_display_name(too_long)
        self.assertEqual(cm.exception.details.get("maxLen"), DISPLAY_NAME_MAX_LEN)

    def test_at_max_len_accepted(self):
        at_max = "x" * DISPLAY_NAME_MAX_LEN
        self.assertEqual(validate_display_name(at_max), at_max)

    def test_non_string_rejected(self):
        for bad in (123, None, [], {}, True):
            with self.subTest(value=bad):
                with self.assertRaises(ApiError):
                    validate_display_name(bad)


# ── room ──────────────────────────────────────────────────────────────


class TestRoom(unittest.TestCase):
    def test_happy(self):
        self.assertEqual(validate_room("12A"), "12A")
        self.assertEqual(validate_room("R-4"), "R-4")
        self.assertEqual(validate_room("203"), "203")

    def test_trims_whitespace(self):
        self.assertEqual(validate_room("  12A "), "12A")

    def test_empty_rejected(self):
        with self.assertRaises(ApiError):
            validate_room("")

    def test_at_max_accepted(self):
        at_max = "x" * ROOM_MAX_LEN
        self.assertEqual(validate_room(at_max), at_max)

    def test_too_long_rejected(self):
        with self.assertRaises(ApiError):
            validate_room("x" * (ROOM_MAX_LEN + 1))


# ── device serial ─────────────────────────────────────────────────────


class TestDeviceSerial(unittest.TestCase):
    def test_happy(self):
        self.assertEqual(validate_device_serial("GS0000000123"), "GS0000000123")
        self.assertEqual(validate_device_serial("GS9999999998"), "GS9999999998")

    def test_trims_whitespace(self):
        self.assertEqual(validate_device_serial("  GS0000000123  "), "GS0000000123")

    def test_lowercase_gs_rejected(self):
        with self.assertRaises(ApiError) as cm:
            validate_device_serial("gs0000000123")
        self.assertEqual(cm.exception.code, "INVALID_DEVICE_SERIAL")

    def test_missing_prefix_rejected(self):
        with self.assertRaises(ApiError):
            validate_device_serial("0000000123")

    def test_short_rejected(self):
        with self.assertRaises(ApiError):
            validate_device_serial("GS123")

    def test_long_rejected(self):
        with self.assertRaises(ApiError):
            validate_device_serial("GS00000000000123")

    def test_letters_in_numeric_part_rejected(self):
        with self.assertRaises(ApiError):
            validate_device_serial("GS000000ABCD")

    def test_pattern_regex_documented(self):
        """The pattern documented in the error matches reality."""
        self.assertEqual(DEVICE_SERIAL_RE.pattern, r"^GS\d{10}$")

    def test_non_string_rejected(self):
        with self.assertRaises(ApiError):
            validate_device_serial(1234567890)


# ── census id ─────────────────────────────────────────────────────────


class TestCensusId(unittest.TestCase):
    def test_happy(self):
        self.assertEqual(validate_census_id("cen_ws_memory"), "cen_ws_memory")
        self.assertEqual(validate_census_id("cen_044"), "cen_044")

    def test_missing_prefix_rejected(self):
        with self.assertRaises(ApiError):
            validate_census_id("ws_memory")

    def test_wrong_prefix_rejected(self):
        with self.assertRaises(ApiError):
            validate_census_id("fac_whitestone")

    def test_empty_after_prefix_rejected(self):
        with self.assertRaises(ApiError):
            validate_census_id("cen_")

    def test_non_string_rejected(self):
        with self.assertRaises(ApiError):
            validate_census_id(None)


# ── pause days ────────────────────────────────────────────────────────


class TestPauseDays(unittest.TestCase):
    def test_one_day(self):
        self.assertEqual(validate_pause_days(1), 1)

    def test_default_seven_day(self):
        self.assertEqual(validate_pause_days(7), 7)

    def test_max(self):
        self.assertEqual(validate_pause_days(PAUSE_DAYS_MAX), PAUSE_DAYS_MAX)

    def test_zero_rejected(self):
        with self.assertRaises(ApiError):
            validate_pause_days(0)

    def test_negative_rejected(self):
        with self.assertRaises(ApiError):
            validate_pause_days(-1)

    def test_over_max_rejected(self):
        with self.assertRaises(ApiError):
            validate_pause_days(PAUSE_DAYS_MAX + 1)

    def test_string_rejected(self):
        with self.assertRaises(ApiError):
            validate_pause_days("7")

    def test_float_rejected(self):
        with self.assertRaises(ApiError):
            validate_pause_days(7.5)

    def test_bool_rejected_even_though_truthy(self):
        """Python bool is subclass of int; explicit reject."""
        with self.assertRaises(ApiError):
            validate_pause_days(True)


# ── pause reason ──────────────────────────────────────────────────────


class TestPauseReason(unittest.TestCase):
    def test_all_valid_reasons(self):
        for r in VALID_PAUSE_REASONS:
            with self.subTest(reason=r):
                self.assertEqual(validate_pause_reason(r), r)

    def test_invalid_reason_rejected(self):
        with self.assertRaises(ApiError) as cm:
            validate_pause_reason("unknown_reason")
        self.assertIn("allowed", cm.exception.details or {})

    def test_non_string_rejected(self):
        with self.assertRaises(ApiError):
            validate_pause_reason(None)


# ── discharge reason / notes ──────────────────────────────────────────


class TestDischargeReason(unittest.TestCase):
    def test_all_valid_reasons(self):
        for r in VALID_DISCHARGE_REASONS:
            with self.subTest(reason=r):
                self.assertEqual(validate_discharge_reason(r), r)

    def test_invalid_reason_rejected(self):
        with self.assertRaises(ApiError):
            validate_discharge_reason("retired_to_florida")


class TestDischargeNotes(unittest.TestCase):
    def test_none_accepted(self):
        self.assertIsNone(validate_discharge_notes(None))

    def test_empty_treated_as_none(self):
        self.assertIsNone(validate_discharge_notes(""))

    def test_whitespace_only_treated_as_none(self):
        self.assertIsNone(validate_discharge_notes("    "))

    def test_happy(self):
        self.assertEqual(validate_discharge_notes("Some notes"), "Some notes")

    def test_trims_whitespace(self):
        self.assertEqual(validate_discharge_notes("  Some notes  "), "Some notes")

    def test_too_long_rejected(self):
        with self.assertRaises(ApiError):
            validate_discharge_notes("x" * 1001)


# ── care note ─────────────────────────────────────────────────────────


class TestCareNoteText(unittest.TestCase):
    def test_happy_short(self):
        self.assertEqual(validate_care_note_text("Back from hospital."), "Back from hospital.")

    def test_at_max_chars_accepted(self):
        at_max = "x" * CARE_NOTE_MAX_CHARS
        self.assertEqual(validate_care_note_text(at_max), at_max)

    def test_over_max_rejected(self):
        with self.assertRaises(ApiError) as cm:
            validate_care_note_text("x" * (CARE_NOTE_MAX_CHARS + 1))
        self.assertEqual(cm.exception.code, "CARE_NOTE_TOO_LONG")

    def test_empty_accepted_means_clear(self):
        """Empty string is a valid input — semantically clears the note."""
        self.assertEqual(validate_care_note_text(""), "")

    def test_whitespace_preserved(self):
        """Unlike display name / room, we don't strip — empty-string clears,
        but caller can preserve their intentional spaces."""
        self.assertEqual(validate_care_note_text("  hi  "), "  hi  ")

    def test_non_string_rejected(self):
        with self.assertRaises(ApiError):
            validate_care_note_text(None)


# ── composite: POST /patients body ────────────────────────────────────


class TestCreatePatientBody(unittest.TestCase):
    def test_happy_without_device(self):
        out = validate_create_patient_body({
            "displayName": "Test Patient",
            "censusId": "cen_ws_memory",
            "room": "12A",
        })
        self.assertEqual(out, {
            "displayName": "Test Patient",
            "censusId": "cen_ws_memory",
            "room": "12A",
            "deviceSerial": None,
        })

    def test_happy_with_device(self):
        out = validate_create_patient_body({
            "displayName": "Test Patient",
            "censusId": "cen_ws_memory",
            "room": "12A",
            "deviceSerial": "GS0000000123",
        })
        self.assertEqual(out["deviceSerial"], "GS0000000123")

    def test_empty_device_treated_as_absent(self):
        out = validate_create_patient_body({
            "displayName": "Test Patient",
            "censusId": "cen_ws_memory",
            "room": "12A",
            "deviceSerial": "",
        })
        self.assertIsNone(out["deviceSerial"])

    def test_missing_required_rejected(self):
        with self.assertRaises(ApiError):
            validate_create_patient_body({"displayName": "x", "censusId": "cen_x"})

    def test_unknown_field_rejected(self):
        with self.assertRaises(ApiError) as cm:
            validate_create_patient_body({
                "displayName": "x",
                "censusId": "cen_x",
                "room": "12A",
                "device_serial": "GS0000000123",  # snake_case typo
            })
        self.assertIn("device_serial", cm.exception.details.get("unknownFields", []))

    def test_non_dict_rejected(self):
        with self.assertRaises(ApiError):
            validate_create_patient_body([])
        with self.assertRaises(ApiError):
            validate_create_patient_body(None)


# ── composite: PATCH /patients/{id} body ──────────────────────────────


class TestUpdatePatientBody(unittest.TestCase):
    def test_single_field_ok(self):
        self.assertEqual(
            validate_update_patient_body({"room": "12B"}), {"room": "12B"}
        )

    def test_all_fields_ok(self):
        out = validate_update_patient_body({
            "displayName": "New Name",
            "censusId": "cen_xyz",
            "room": "12B",
        })
        self.assertEqual(set(out.keys()), {"displayName", "censusId", "room"})

    def test_empty_body_rejected(self):
        with self.assertRaises(ApiError):
            validate_update_patient_body({})

    def test_unknown_field_rejected(self):
        with self.assertRaises(ApiError):
            validate_update_patient_body({"room": "12B", "weirdField": "x"})


# ── composite: POST /patients/{id}/discharge body ─────────────────────


class TestDischargeBody(unittest.TestCase):
    def test_happy(self):
        out = validate_discharge_body({"reason": "transferred", "notes": "Sent home"})
        self.assertEqual(out, {"reason": "transferred", "notes": "Sent home"})

    def test_notes_optional(self):
        out = validate_discharge_body({"reason": "deceased"})
        self.assertEqual(out, {"reason": "deceased", "notes": None})

    def test_missing_reason_rejected(self):
        with self.assertRaises(ApiError):
            validate_discharge_body({"notes": "..."})

    def test_unknown_field_rejected(self):
        with self.assertRaises(ApiError):
            validate_discharge_body({"reason": "transferred", "dischargedBy": "x"})


# ── composite: POST /patients/{id}/notifications/pause body ───────────


class TestPauseBody(unittest.TestCase):
    def test_happy(self):
        out = validate_pause_body({"days": 7, "reason": "in_hospital"})
        self.assertEqual(out, {"days": 7, "reason": "in_hospital"})

    def test_missing_days_rejected(self):
        with self.assertRaises(ApiError):
            validate_pause_body({"reason": "in_hospital"})

    def test_missing_reason_rejected(self):
        with self.assertRaises(ApiError):
            validate_pause_body({"days": 7})

    def test_unknown_field_rejected(self):
        with self.assertRaises(ApiError):
            validate_pause_body({"days": 7, "reason": "in_hospital", "extra": "x"})


# ── composite: PATCH /patients/{id}/care-note body ────────────────────


class TestCareNoteBody(unittest.TestCase):
    def test_happy(self):
        out = validate_care_note_body({"text": "Back from hospital."})
        self.assertEqual(out, {"text": "Back from hospital."})

    def test_empty_text_means_clear(self):
        out = validate_care_note_body({"text": ""})
        self.assertEqual(out, {"text": ""})

    def test_missing_text_rejected(self):
        with self.assertRaises(ApiError):
            validate_care_note_body({})

    def test_unknown_field_rejected(self):
        with self.assertRaises(ApiError):
            validate_care_note_body({"text": "x", "noteId": "n_1"})


if __name__ == "__main__":
    unittest.main()

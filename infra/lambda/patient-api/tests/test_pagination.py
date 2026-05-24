"""
Unit tests for patient-api pagination helpers — Phase 2A-RD.

Run from repo root:
    cd infra/lambda
    PYTHONPATH=. python3 -m unittest patient-api.tests.test_pagination
"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

# Add the lambda dir to PYTHONPATH so `_shared` and the patient-api
# modules resolve via package-relative imports as they do in Lambda.
_LAMBDA_DIR = Path(__file__).resolve().parents[2]
_PA_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(_LAMBDA_DIR))
sys.path.insert(0, str(_PA_DIR))

# Stub powertools BEFORE any _shared.* import (which triggers a
# powertools-dependent eager load).
sys.path.insert(0, str(Path(__file__).resolve().parent))
import _stub_powertools  # noqa: F401,E402

import importlib  # noqa: E402
pagination = importlib.import_module("pagination")
from _shared.api_error import ApiError  # noqa: E402


class TestParsePageSize(unittest.TestCase):
    def test_none_returns_default(self):
        self.assertEqual(pagination.parse_page_size(None), 50)

    def test_empty_returns_default(self):
        self.assertEqual(pagination.parse_page_size(""), 50)

    def test_valid_integer_string(self):
        self.assertEqual(pagination.parse_page_size("25"), 25)

    def test_caps_at_max(self):
        self.assertEqual(pagination.parse_page_size("500"), 200)

    def test_zero_returns_default(self):
        self.assertEqual(pagination.parse_page_size("0"), 50)

    def test_negative_returns_default(self):
        self.assertEqual(pagination.parse_page_size("-5"), 50)

    def test_non_numeric_returns_default(self):
        self.assertEqual(pagination.parse_page_size("twenty"), 50)

    def test_custom_default_and_max(self):
        self.assertEqual(pagination.parse_page_size(None, default=10, maximum=20), 10)
        self.assertEqual(pagination.parse_page_size("999", default=10, maximum=20), 20)


class TestCursorRoundTrip(unittest.TestCase):
    def test_encode_then_decode_recovers_original(self):
        original = {"patientId": "pat_abc123", "timestamp": "2026-05-23T14:18:00Z"}
        cursor = pagination.encode_cursor(original)
        self.assertIsNotNone(cursor)
        recovered = pagination.decode_cursor(cursor)
        self.assertEqual(recovered, original)

    def test_encode_none_returns_none(self):
        self.assertIsNone(pagination.encode_cursor(None))
        self.assertIsNone(pagination.encode_cursor({}))

    def test_decode_none_returns_none(self):
        self.assertIsNone(pagination.decode_cursor(None))
        self.assertIsNone(pagination.decode_cursor(""))

    def test_decode_malformed_raises(self):
        with self.assertRaises(ApiError) as cm:
            pagination.decode_cursor("not-valid-base64!@#$")
        self.assertEqual(cm.exception.code, "INVALID_CURSOR")
        self.assertEqual(cm.exception.status, 400)

    def test_decode_non_json_payload_raises(self):
        # Valid base64 but content isn't JSON.
        import base64
        bad = base64.urlsafe_b64encode(b"not json at all").decode("ascii")
        with self.assertRaises(ApiError):
            pagination.decode_cursor(bad)

    def test_decode_non_dict_raises(self):
        # Valid JSON but it's a list, not an object.
        import base64
        bad = base64.urlsafe_b64encode(b'[1, 2, 3]').decode("ascii")
        with self.assertRaises(ApiError) as cm:
            pagination.decode_cursor(bad)
        self.assertEqual(cm.exception.code, "INVALID_CURSOR")

    def test_cursor_is_url_safe(self):
        # Should not contain URL-reserved chars like + or / (urlsafe_b64).
        original = {"a": "b" * 100, "c": "d" * 100}
        cursor = pagination.encode_cursor(original)
        self.assertNotIn("+", cursor)
        self.assertNotIn("/", cursor)


if __name__ == "__main__":
    unittest.main()

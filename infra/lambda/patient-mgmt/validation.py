"""
Pure-function body validators for patient-mgmt — Phase 2A-UM-P.

Every public function in this module:
  - Takes raw request input (dict, str, int).
  - Returns the normalized value on success.
  - Raises ApiError(code, message, status=400, details=...) on rejection.

The handler layer catches the ApiError; the audit_middleware turns it
into the 2A-0 standard error envelope. Validators NEVER touch DDB, the
clock, or environment state — they're trivially unit-testable.

Constraints sourced from:
  - phase-2a-um-patient-management.md §Endpoint contracts + §Error envelope
  - phase-2b-portal-integration.md L10 (GS+10-digits serial enforced
    end-to-end)
  - user-needs.md US-28 / US-29 / US-31 / US-32 / US-44
"""

from __future__ import annotations

import re
from typing import Any, Optional

from _shared.api_error import ApiError


# ── Constants ─────────────────────────────────────────────────────────

DISPLAY_NAME_MAX_LEN = 200
ROOM_MAX_LEN = 32
CARE_NOTE_MAX_CHARS = 280  # user-needs US-44; phase-2a-um L8
PAUSE_DAYS_MIN = 1
PAUSE_DAYS_MAX = 90
DISCHARGE_NOTES_MAX_LEN = 1000

DEVICE_SERIAL_RE = re.compile(r"^GS\d{10}$")
PATIENT_ID_RE = re.compile(r"^pat_[A-Za-z0-9_\-]{1,64}$")
CENSUS_ID_RE = re.compile(r"^cen_[A-Za-z0-9_\-]{1,64}$")

VALID_PAUSE_REASONS = frozenset(
    {"in_hospital", "at_rehab", "family_visit_offsite", "on_vacation", "other"}
)

# NOTE: the structured discharge-reason enum was dropped 2026-06-03 — "End
# Monitoring" (the renamed discharge action) needs no reason. `reason` is now an
# optional free-text field (see validate_discharge_reason).


# ── Field validators ──────────────────────────────────────────────────


def validate_display_name(value: Any) -> str:
    """Patient.displayName — required non-empty string ≤ DISPLAY_NAME_MAX_LEN."""
    if not isinstance(value, str):
        raise ApiError(
            code="INVALID_REQUEST",
            message="displayName must be a string",
            status=400,
            details={"field": "displayName", "got": type(value).__name__},
        )
    stripped = value.strip()
    if not stripped:
        raise ApiError(
            code="INVALID_REQUEST",
            message="displayName cannot be empty",
            status=400,
            details={"field": "displayName"},
        )
    if len(stripped) > DISPLAY_NAME_MAX_LEN:
        raise ApiError(
            code="INVALID_REQUEST",
            message=f"displayName exceeds {DISPLAY_NAME_MAX_LEN} characters",
            status=400,
            details={
                "field": "displayName",
                "maxLen": DISPLAY_NAME_MAX_LEN,
                "gotLen": len(stripped),
            },
        )
    return stripped


def validate_room(value: Any) -> str:
    """Patient.room — required non-empty string ≤ ROOM_MAX_LEN."""
    if not isinstance(value, str):
        raise ApiError(
            code="INVALID_REQUEST",
            message="room must be a string",
            status=400,
            details={"field": "room", "got": type(value).__name__},
        )
    stripped = value.strip()
    if not stripped:
        raise ApiError(
            code="INVALID_REQUEST",
            message="room cannot be empty",
            status=400,
            details={"field": "room"},
        )
    if len(stripped) > ROOM_MAX_LEN:
        raise ApiError(
            code="INVALID_REQUEST",
            message=f"room exceeds {ROOM_MAX_LEN} characters",
            status=400,
            details={
                "field": "room",
                "maxLen": ROOM_MAX_LEN,
                "gotLen": len(stripped),
            },
        )
    return stripped


def validate_device_serial(value: Any) -> str:
    """Device serial — must match `GS` + 10 digits exactly. user-needs §7 #8."""
    if not isinstance(value, str):
        raise ApiError(
            code="INVALID_DEVICE_SERIAL",
            message="deviceSerial must be a string",
            status=400,
            details={"field": "deviceSerial", "got": type(value).__name__},
        )
    stripped = value.strip()
    if not DEVICE_SERIAL_RE.match(stripped):
        raise ApiError(
            code="INVALID_DEVICE_SERIAL",
            message="deviceSerial must match 'GS' + 10 digits (e.g., GS0000000123)",
            status=400,
            details={"field": "deviceSerial", "pattern": "^GS\\d{10}$"},
        )
    return stripped


def validate_census_id(value: Any) -> str:
    """Census ID — `cen_` prefix + alphanumeric / underscore / hyphen, ≤64 chars."""
    if not isinstance(value, str):
        raise ApiError(
            code="INVALID_REQUEST",
            message="censusId must be a string",
            status=400,
            details={"field": "censusId", "got": type(value).__name__},
        )
    stripped = value.strip()
    if not CENSUS_ID_RE.match(stripped):
        raise ApiError(
            code="INVALID_REQUEST",
            message="censusId must match 'cen_' prefix + identifier",
            status=400,
            details={"field": "censusId", "pattern": "^cen_[A-Za-z0-9_-]+$"},
        )
    return stripped


def validate_pause_days(value: Any) -> int:
    """Pause Notifications days — int in [PAUSE_DAYS_MIN, PAUSE_DAYS_MAX]."""
    # Reject bool first because bool is a subclass of int in Python (True == 1)
    # and we don't want JSON-serialized booleans silently passing.
    if isinstance(value, bool):
        raise ApiError(
            code="INVALID_REQUEST",
            message="days must be an integer, not a boolean",
            status=400,
            details={"field": "days", "got": "bool"},
        )
    if not isinstance(value, int):
        raise ApiError(
            code="INVALID_REQUEST",
            message="days must be an integer",
            status=400,
            details={"field": "days", "got": type(value).__name__},
        )
    if value < PAUSE_DAYS_MIN or value > PAUSE_DAYS_MAX:
        raise ApiError(
            code="INVALID_REQUEST",
            message=f"days must be in [{PAUSE_DAYS_MIN}, {PAUSE_DAYS_MAX}]",
            status=400,
            details={
                "field": "days",
                "min": PAUSE_DAYS_MIN,
                "max": PAUSE_DAYS_MAX,
                "got": value,
            },
        )
    return value


def validate_pause_reason(value: Any) -> str:
    """Pause Notifications reason — must be in VALID_PAUSE_REASONS."""
    if not isinstance(value, str) or value not in VALID_PAUSE_REASONS:
        raise ApiError(
            code="INVALID_REQUEST",
            message="reason must be one of the allowed pause-reason values",
            status=400,
            details={
                "field": "reason",
                "allowed": sorted(VALID_PAUSE_REASONS),
                "got": value,
            },
        )
    return value


def validate_discharge_reason(value: Any) -> Optional[str]:
    """
    Optional free-text 'end monitoring' reason. The structured enum was dropped
    2026-06-03 (ending monitoring needs no reason); this stays only to accept an
    optional note-like string if a client ever sends one, and to keep old
    clients that still POST a reason from 400-ing.
    """
    if value is None:
        return None
    if not isinstance(value, str):
        raise ApiError(
            code="INVALID_REQUEST",
            message="reason must be a string (or omitted)",
            status=400,
            details={"field": "reason", "got": type(value).__name__},
        )
    stripped = value.strip()
    if not stripped:
        return None
    if len(stripped) > DISCHARGE_NOTES_MAX_LEN:
        raise ApiError(
            code="INVALID_REQUEST",
            message=f"reason exceeds {DISCHARGE_NOTES_MAX_LEN} characters",
            status=400,
            details={"field": "reason"},
        )
    return stripped


def validate_discharge_notes(value: Any) -> Optional[str]:
    """Optional discharge notes — string ≤ DISCHARGE_NOTES_MAX_LEN, or None."""
    if value is None:
        return None
    if not isinstance(value, str):
        raise ApiError(
            code="INVALID_REQUEST",
            message="notes must be a string (or omitted)",
            status=400,
            details={"field": "notes", "got": type(value).__name__},
        )
    stripped = value.strip()
    if not stripped:
        return None  # treat whitespace-only as absent
    if len(stripped) > DISCHARGE_NOTES_MAX_LEN:
        raise ApiError(
            code="INVALID_REQUEST",
            message=f"notes exceeds {DISCHARGE_NOTES_MAX_LEN} characters",
            status=400,
            details={
                "field": "notes",
                "maxLen": DISCHARGE_NOTES_MAX_LEN,
                "gotLen": len(stripped),
            },
        )
    return stripped


def validate_care_note_text(value: Any) -> str:
    """
    Care Note text — string ≤ CARE_NOTE_MAX_CHARS. Empty string is a
    valid value (semantically: clear the existing care note).

    NOTE: this function returns the text as-is (no trimming) because the
    handler may want to distinguish "user typed nothing but spaces"
    (treat as clear) from "user typed actual content." The empty-clear
    semantic is handled by the handler.
    """
    if not isinstance(value, str):
        raise ApiError(
            code="INVALID_REQUEST",
            message="text must be a string",
            status=400,
            details={"field": "text", "got": type(value).__name__},
        )
    if len(value) > CARE_NOTE_MAX_CHARS:
        raise ApiError(
            code="CARE_NOTE_TOO_LONG",
            message=f"Care note exceeds {CARE_NOTE_MAX_CHARS} characters",
            status=400,
            details={
                "field": "text",
                "maxChars": CARE_NOTE_MAX_CHARS,
                "gotChars": len(value),
            },
        )
    return value


# ── Composite request validators ──────────────────────────────────────


def validate_create_patient_body(body: Any) -> dict[str, Any]:
    """
    Validate POST /patients body shape.

    Required: displayName, censusId, room.
    Optional: deviceSerial (atomic-provision iff present).

    Returns a normalized dict with keys: displayName, censusId, room,
    deviceSerial (None if absent).
    """
    if not isinstance(body, dict):
        raise ApiError(
            code="INVALID_REQUEST",
            message="Request body must be a JSON object",
            status=400,
        )
    out = {
        "displayName": validate_display_name(body.get("displayName")),
        "censusId": validate_census_id(body.get("censusId")),
        "room": validate_room(body.get("room")),
        "deviceSerial": None,
    }
    raw_serial = body.get("deviceSerial")
    if raw_serial is not None and raw_serial != "":
        out["deviceSerial"] = validate_device_serial(raw_serial)
    # Reject unknown top-level fields defensively — catches caller typos
    # (`device_serial` vs `deviceSerial`, `census_id` vs `censusId`).
    allowed = {"displayName", "censusId", "room", "deviceSerial"}
    unknown = set(body.keys()) - allowed
    if unknown:
        raise ApiError(
            code="INVALID_REQUEST",
            message="Unknown field(s) in body",
            status=400,
            details={"unknownFields": sorted(unknown), "allowedFields": sorted(allowed)},
        )
    return out


def validate_update_patient_body(body: Any) -> dict[str, Any]:
    """
    Validate PATCH /patients/{id} body — every field optional but at
    least one must be present. Returns a normalized dict containing
    only the present fields (so the handler can build an UpdateExpression
    that only touches what's changing).
    """
    if not isinstance(body, dict):
        raise ApiError(
            code="INVALID_REQUEST",
            message="Request body must be a JSON object",
            status=400,
        )
    allowed = {"displayName", "censusId", "room"}
    unknown = set(body.keys()) - allowed
    if unknown:
        raise ApiError(
            code="INVALID_REQUEST",
            message="Unknown field(s) in body",
            status=400,
            details={"unknownFields": sorted(unknown), "allowedFields": sorted(allowed)},
        )
    out: dict[str, Any] = {}
    if "displayName" in body:
        out["displayName"] = validate_display_name(body["displayName"])
    if "censusId" in body:
        out["censusId"] = validate_census_id(body["censusId"])
    if "room" in body:
        out["room"] = validate_room(body["room"])
    if not out:
        raise ApiError(
            code="INVALID_REQUEST",
            message="At least one field required (displayName / censusId / room)",
            status=400,
            details={"allowedFields": sorted(allowed)},
        )
    return out


def validate_discharge_body(body: Any) -> dict[str, Any]:
    """Validate POST /patients/{id}/discharge body."""
    if not isinstance(body, dict):
        raise ApiError(
            code="INVALID_REQUEST",
            message="Request body must be a JSON object",
            status=400,
        )
    allowed = {"reason", "notes"}
    unknown = set(body.keys()) - allowed
    if unknown:
        raise ApiError(
            code="INVALID_REQUEST",
            message="Unknown field(s) in body",
            status=400,
            details={"unknownFields": sorted(unknown), "allowedFields": sorted(allowed)},
        )
    return {
        "reason": validate_discharge_reason(body.get("reason")),
        "notes": validate_discharge_notes(body.get("notes")),
    }


def validate_pause_body(body: Any) -> dict[str, Any]:
    """Validate POST /patients/{id}/notifications/pause body."""
    if not isinstance(body, dict):
        raise ApiError(
            code="INVALID_REQUEST",
            message="Request body must be a JSON object",
            status=400,
        )
    allowed = {"days", "reason"}
    unknown = set(body.keys()) - allowed
    if unknown:
        raise ApiError(
            code="INVALID_REQUEST",
            message="Unknown field(s) in body",
            status=400,
            details={"unknownFields": sorted(unknown), "allowedFields": sorted(allowed)},
        )
    return {
        "days": validate_pause_days(body.get("days")),
        "reason": validate_pause_reason(body.get("reason")),
    }


def validate_care_note_body(body: Any) -> dict[str, str]:
    """Validate PATCH /patients/{id}/care-note body. `text` is required."""
    if not isinstance(body, dict):
        raise ApiError(
            code="INVALID_REQUEST",
            message="Request body must be a JSON object",
            status=400,
        )
    allowed = {"text"}
    unknown = set(body.keys()) - allowed
    if unknown:
        raise ApiError(
            code="INVALID_REQUEST",
            message="Unknown field(s) in body",
            status=400,
            details={"unknownFields": sorted(unknown), "allowedFields": sorted(allowed)},
        )
    if "text" not in body:
        raise ApiError(
            code="INVALID_REQUEST",
            message="text field is required",
            status=400,
            details={"field": "text"},
        )
    return {"text": validate_care_note_text(body["text"])}

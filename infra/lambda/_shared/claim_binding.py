"""
Claim-binding helpers — d2c-claim-binding.md §5.1–5.3.

Pure helpers for the `claimBoundPhone` mechanism: E.164 normalization,
the peppered HMAC that is stored/compared (never the raw phone — D3),
and the display mask stored alongside it (D9). Plus the cached
Secrets Manager pepper read shared by d2c-claim + device-api.

normalize/hmac/mask are stdlib-only and unit-testable offline
(tests/test_claim_binding.py). get_pepper() touches AWS and is
cached per Lambda container; tests monkeypatch `_pepper_cache`.
"""

from __future__ import annotations

import hashlib
import hmac as hmac_mod
import os
import re

from .api_error import ApiError


class PhoneFormatError(ValueError):
    """Raised when a phone number cannot be normalized to E.164."""


# Digits + a single leading "+" are meaningful; everything else
# (spaces, dashes, dots, parens) is formatting noise.
_NOISE_RE = re.compile(r"[\s\-\.\(\)]")


def normalize_e164(phone: str) -> str:
    """
    Normalize user/operator phone input to E.164 (spec T6).

    Accepted forms (all hash-equal after normalization):
      "+15125550100", "1 512 555 0100", "(512) 555-0100", "512-555-0100"

    Bare 10-digit and 1-prefixed 11-digit numbers are assumed US (+1) —
    the pilot fleet is US-only. Any other country requires an explicit
    "+<cc>". Raises PhoneFormatError on anything unparseable.
    """
    cleaned = _NOISE_RE.sub("", (phone or "").strip())
    if not cleaned:
        raise PhoneFormatError("empty phone")

    if cleaned.startswith("+"):
        digits = cleaned[1:]
        if not digits.isdigit() or not (8 <= len(digits) <= 15):
            raise PhoneFormatError(f"not E.164: {len(digits)} digits after '+'")
        return "+" + digits

    if not cleaned.isdigit():
        raise PhoneFormatError("phone contains non-digits")
    if len(cleaned) == 10:
        return "+1" + cleaned
    if len(cleaned) == 11 and cleaned.startswith("1"):
        return "+" + cleaned
    raise PhoneFormatError(
        f"ambiguous {len(cleaned)}-digit number — include the country code (+…)"
    )


def hmac_phone(pepper: str, e164_phone: str) -> str:
    """HMAC-SHA256(pepper, e164) hex — the stored/compared binding value."""
    return hmac_mod.new(
        pepper.encode("utf-8"), e164_phone.encode("utf-8"), hashlib.sha256
    ).hexdigest()


def mask_phone(e164_phone: str) -> str:
    """Display form stored alongside the HMAC (•••-1234) — §5.1/D9."""
    digits = [c for c in e164_phone if c.isdigit()]
    return "•••-" + "".join(digits[-4:])


# ── Pepper (Secrets Manager, cached per container) ─────────────────────

_pepper_cache: str | None = None


def get_pepper() -> str:
    """
    Read the claim-binding pepper (gosteady/{env}/claim-binding-pepper).

    Cached for the container lifetime — the pepper never rotates
    mid-execution (rotation invalidates every stored binding and is an
    explicit re-bind operation, spec §10). Raises a 500-shaped ApiError
    if the secret is unreadable: binding enforcement must fail CLOSED,
    never silently open.
    """
    global _pepper_cache
    if _pepper_cache:
        return _pepper_cache

    secret_id = os.environ.get("CLAIM_BINDING_PEPPER_SECRET_ARN", "")
    if not secret_id:
        raise ApiError(
            code="CLAIM_BINDING_UNAVAILABLE",
            message="Claim-binding secret is not configured",
            status=500,
        )
    try:
        import boto3  # deferred so pure-helper tests never touch AWS

        resp = boto3.client("secretsmanager").get_secret_value(SecretId=secret_id)
        value = resp.get("SecretString") or ""
    except Exception as exc:  # noqa: BLE001 — any failure fails closed
        raise ApiError(
            code="CLAIM_BINDING_UNAVAILABLE",
            message="Claim-binding secret could not be read",
            status=500,
            details={"error": str(exc)},
        )
    if not value:
        raise ApiError(
            code="CLAIM_BINDING_UNAVAILABLE",
            message="Claim-binding secret is empty",
            status=500,
        )
    _pepper_cache = value
    return value

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


def normalize_e164(phone: str) -> str:
    """
    Normalize user/operator phone input to E.164 (spec T6).

    Accepted forms (all hash-equal after normalization):
      "+15125550100", "1 512 555 0100", "(512) 555-0100", "512-555-0100",
      and — critically — "+5125550100" (a US 10-digit number typed WITH a
      stray "+" but no country code).

    US-only pilot: any 10-digit number, or an 11-digit number starting with
    1, is treated as US (+1) **regardless of a leading "+"**. This is the fix
    for the prod incident where "+5165891580" (a US number missing its +1)
    was trusted as country code +516 — Twilio then rejected the OTP send
    (error 21408), and the fleet-bind vs claim hashes could disagree. Only a
    number that is NOT US-shaped AND was typed with an explicit "+" is treated
    as international. Raises PhoneFormatError on anything unparseable.

    MUST stay behaviorally identical to the frontend `_normalizePhone`
    (d2c_auth_service.dart) — the bind side (fleet) and the account/OTP side
    (signup) both feed this canonical form, so a divergence re-opens the
    mismatch this fixes.
    """
    raw = (phone or "").strip()
    had_plus = raw.startswith("+")
    digits = re.sub(r"\D", "", raw)
    if not digits:
        raise PhoneFormatError("empty phone")

    # US rules win over a stray "+" (see docstring).
    if len(digits) == 10:
        return "+1" + digits
    if len(digits) == 11 and digits.startswith("1"):
        return "+" + digits
    # Explicit international: only when the caller actually typed "+".
    if had_plus and 8 <= len(digits) <= 15:
        return "+" + digits
    raise PhoneFormatError(
        f"ambiguous {len(digits)}-digit number — enter a 10-digit US number "
        f"or a full +<country-code> number"
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

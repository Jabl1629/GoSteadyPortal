"""
D2C Pre-SignUp trigger — GoSteady D2C phone-first onboarding.

Auto-confirms a fresh D2C self-signup and marks the phone verified, so the
SMS-OTP custom-auth challenge is the SOLE verification factor. Without this, a
`UsernameAttributes:[phone_number, email]` pool would leave a self-signup
UNCONFIRMED (awaiting a code) — reintroducing the email/SMS double-verification
the phone-first pivot removes (coord §C54.4 / docs/specs/d2c-phone-only-signin.md).

The pool sends NO verification code of its own (autoVerify is empty; SMS goes
via the Twilio custom-auth Lambda, not SNS). Email, if provided, is left
UNVERIFIED — it is an optional secondary sign-in alias, never a factor.

Python 3.12, ARM64. stdlib only.
"""
from __future__ import annotations

from typing import Any


def handler(event: dict[str, Any], context: Any) -> dict[str, Any]:  # noqa: ARG001
    resp = event.setdefault("response", {})
    # Confirm without a code — SMS-OTP at sign-in is the factor.
    resp["autoConfirmUser"] = True
    attrs = (event.get("request", {}) or {}).get("userAttributes", {}) or {}
    # Mark the phone (OTP channel + primary sign-in identifier) verified so the
    # account is immediately usable. Leave email unverified by design.
    if attrs.get("phone_number"):
        resp["autoVerifyPhone"] = True
    return event

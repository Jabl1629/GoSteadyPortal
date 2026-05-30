"""
D2C SMS-OTP custom-auth trigger Lambda — GoSteady D2C Phase 1.

One Lambda, three Cognito custom-auth triggers, routed by
`event['triggerSource']`:

  • DefineAuthChallenge        — orchestrates: issue ONE CUSTOM_CHALLENGE,
                                  succeed on correct answer, fail after 3 tries.
  • CreateAuthChallenge        — generates a 6-digit code, sends it via SNS
                                  SMS to the user's phone_number, stores the
                                  code in privateChallengeParameters (server
                                  side only).
  • VerifyAuthChallengeResponse — compares the submitted code to the stored
                                  answer.

Phase-1 interim: the OTP is sent with SNS Publish (works to a verified
number in the SNS SMS sandbox immediately). Phase 2 swaps this for the
shared Twilio dispatcher (10DLC registered). Flagged in the spec.

Python 3.12, ARM64. boto3 + stdlib only (tiny zip, fast cold start —
this is on the auth path).

Security notes:
  - The code lives only in `privateChallengeParameters` (never returned to
    the client) + `challengeMetadata` (also server-side). `publicChallenge
    Parameters` carries only a masked phone hint.
  - `secrets.randbelow` for the code (CSPRNG, not `random`).
  - 3-attempt cap enforced in DefineAuthChallenge.
"""
from __future__ import annotations

import os
import secrets
from typing import Any

import boto3

_sns = boto3.client("sns")

CODE_TTL_NOTE = "5 minutes"  # informational; actual TTL is the session lifetime
MAX_ATTEMPTS = 3
SENDER_ID = os.environ.get("SMS_SENDER_ID", "GoSteady")


def handler(event: dict[str, Any], context: Any) -> dict[str, Any]:  # noqa: ARG001
    src = event.get("triggerSource", "")
    if src == "DefineAuthChallenge_Authentication":
        return _define(event)
    if src == "CreateAuthChallenge_Authentication":
        return _create(event)
    if src == "VerifyAuthChallengeResponse_Authentication":
        return _verify(event)
    # Unknown trigger — return unchanged so Cognito surfaces a clear error.
    return event


# ── DefineAuthChallenge ────────────────────────────────────────────────

def _define(event: dict[str, Any]) -> dict[str, Any]:
    session = event["request"].get("session") or []
    resp = event["response"]

    if not session:
        # First step: issue the custom (SMS) challenge.
        resp["issueTokens"] = False
        resp["failAuthentication"] = False
        resp["challengeName"] = "CUSTOM_CHALLENGE"
        return event

    last = session[-1]
    if last.get("challengeName") == "CUSTOM_CHALLENGE" and last.get("challengeResult"):
        # Correct code → mint tokens.
        resp["issueTokens"] = True
        resp["failAuthentication"] = False
        return event

    if len(session) >= MAX_ATTEMPTS:
        # Too many wrong attempts → fail.
        resp["issueTokens"] = False
        resp["failAuthentication"] = True
        return event

    # Wrong but attempts remain → re-issue.
    resp["issueTokens"] = False
    resp["failAuthentication"] = False
    resp["challengeName"] = "CUSTOM_CHALLENGE"
    return event


# ── CreateAuthChallenge ────────────────────────────────────────────────

def _create(event: dict[str, Any]) -> dict[str, Any]:
    session = event["request"].get("session") or []
    resp = event["response"]

    # Reuse the code across re-issues within one auth flow so a user who
    # fat-fingers once doesn't get a second text. The code is carried in
    # the previous challenge's metadata.
    code: str | None = None
    for prior in session:
        if prior.get("challengeName") == "CUSTOM_CHALLENGE" and prior.get("challengeMetadata"):
            meta = prior["challengeMetadata"]
            if meta.startswith("CODE-"):
                code = meta[5:]
                break

    if code is None:
        code = f"{secrets.randbelow(1_000_000):06d}"
        phone = (event["request"].get("userAttributes") or {}).get("phone_number")
        if phone:
            _send_sms(phone, code)

    # answer is server-side only; never returned to the client.
    resp["privateChallengeParameters"] = {"answer": code}
    resp["challengeMetadata"] = f"CODE-{code}"
    # public hint (safe to expose): masked phone tail.
    phone = (event["request"].get("userAttributes") or {}).get("phone_number", "")
    resp["publicChallengeParameters"] = {"phoneHint": _mask_phone(phone)}
    return event


def _verify(event: dict[str, Any]) -> dict[str, Any]:
    expected = (event["request"].get("privateChallengeParameters") or {}).get("answer")
    submitted = (event["request"].get("challengeAnswer") or "").strip()
    event["response"]["answerCorrect"] = bool(expected) and submitted == expected
    return event


# ── helpers ────────────────────────────────────────────────────────────

def _send_sms(phone_e164: str, code: str) -> None:
    """Send the OTP via SNS Publish (Phase-1 interim; Twilio in Phase 2)."""
    message = (
        f"{code} is your GoSteady verification code. "
        f"It expires in {CODE_TTL_NOTE}. Reply STOP to opt out."
    )
    _sns.publish(
        PhoneNumber=phone_e164,
        Message=message,
        MessageAttributes={
            "AWS.SNS.SMS.SMSType": {"DataType": "String", "StringValue": "Transactional"},
            "AWS.SNS.SMS.SenderID": {"DataType": "String", "StringValue": SENDER_ID},
        },
    )


def _mask_phone(phone: str) -> str:
    digits = "".join(c for c in phone if c.isdigit())
    if len(digits) < 2:
        return "your phone"
    return f"••{digits[-2:]}"

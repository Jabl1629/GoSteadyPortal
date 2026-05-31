"""
D2C SMS-OTP custom-auth trigger Lambda — GoSteady D2C Phase 1.

One Lambda, three Cognito custom-auth triggers, routed by
`event['triggerSource']`:

  • DefineAuthChallenge        — orchestrates: issue ONE CUSTOM_CHALLENGE,
                                  succeed on correct answer, fail after 3 tries.
  • CreateAuthChallenge        — generates a 6-digit code, sends it via Twilio
                                  SMS to the user's phone_number, stores the
                                  code in privateChallengeParameters (server
                                  side only).
  • VerifyAuthChallengeResponse — compares the submitted code to the stored
                                  answer.

**SMS provider: Twilio** (pulled forward from Phase 2). The dev AWS account
has no SNS SMS origination identity ("No origination entities available to
send"), and US A2P SMS needs 10DLC registration regardless — so we use
Twilio, which is the production path anyway (no rework later).

Credentials live in a Secrets Manager secret (ARN in env `TWILIO_SECRET_ARN`),
NEVER in code or env vars. Expected secret JSON — use a scoped **API Key**
(revocable; preferred) OR the master Auth Token:
    {
      "account_sid":    "AC...",        # always — used in the request URL
      "api_key_sid":    "SK...",        # PREFERRED auth (with api_key_secret)
      "api_key_secret": "...",
      "auth_token":     "...",          # fallback auth if no API key
      "from":           "+1XXXXXXXXXX"  # a Twilio number OR a Messaging
                                        # Service SID (MG...).
    }
Auth precedence: (api_key_sid + api_key_secret) if present, else auth_token.
Until the secret is populated (see docs/playbooks/d2c-twilio-setup.md), the
Lambda raises and the OTP flow fails closed (no silent success).

No third-party SDK — the Twilio REST call is a stdlib `urllib` POST, so the
zip stays tiny and cold start stays fast (this is on the auth path).

Python 3.12, ARM64. boto3 (Secrets Manager) + stdlib only.

Security notes:
  - Code lives only in `privateChallengeParameters` + `challengeMetadata`
    (both server-side). `publicChallengeParameters` carries only a masked
    phone hint.
  - `secrets.randbelow` for the code (CSPRNG, not `random`).
  - 3-attempt cap enforced in DefineAuthChallenge.
  - Secret cached at module scope across warm invocations (one GetSecretValue
    per cold start, not per auth).
"""
from __future__ import annotations

import json
import os
import secrets
import urllib.error
import urllib.parse
import urllib.request
from typing import Any

import boto3

_secrets_client = boto3.client("secretsmanager")
_twilio_creds: dict[str, str] | None = None  # module-scope cache

CODE_TTL_NOTE = "5 minutes"  # informational; actual TTL is the session lifetime
MAX_ATTEMPTS = 3
TWILIO_SECRET_ARN = os.environ.get("TWILIO_SECRET_ARN", "")
TWILIO_API = "https://api.twilio.com/2010-04-01/Accounts/{sid}/Messages.json"


def handler(event: dict[str, Any], context: Any) -> dict[str, Any]:  # noqa: ARG001
    src = event.get("triggerSource", "")
    if src == "DefineAuthChallenge_Authentication":
        return _define(event)
    if src == "CreateAuthChallenge_Authentication":
        return _create(event)
    if src == "VerifyAuthChallengeResponse_Authentication":
        return _verify(event)
    return event


# ── DefineAuthChallenge ────────────────────────────────────────────────

def _define(event: dict[str, Any]) -> dict[str, Any]:
    session = event["request"].get("session") or []
    resp = event["response"]

    if not session:
        resp["issueTokens"] = False
        resp["failAuthentication"] = False
        resp["challengeName"] = "CUSTOM_CHALLENGE"
        return event

    last = session[-1]
    if last.get("challengeName") == "CUSTOM_CHALLENGE" and last.get("challengeResult"):
        resp["issueTokens"] = True
        resp["failAuthentication"] = False
        return event

    if len(session) >= MAX_ATTEMPTS:
        resp["issueTokens"] = False
        resp["failAuthentication"] = True
        return event

    resp["issueTokens"] = False
    resp["failAuthentication"] = False
    resp["challengeName"] = "CUSTOM_CHALLENGE"
    return event


# ── CreateAuthChallenge ────────────────────────────────────────────────

def _create(event: dict[str, Any]) -> dict[str, Any]:
    session = event["request"].get("session") or []
    resp = event["response"]

    # Reuse the code across re-issues within one auth flow so a user who
    # fat-fingers once doesn't get a second text.
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

    resp["privateChallengeParameters"] = {"answer": code}
    resp["challengeMetadata"] = f"CODE-{code}"
    phone = (event["request"].get("userAttributes") or {}).get("phone_number", "")
    resp["publicChallengeParameters"] = {"phoneHint": _mask_phone(phone)}
    return event


def _verify(event: dict[str, Any]) -> dict[str, Any]:
    expected = (event["request"].get("privateChallengeParameters") or {}).get("answer")
    submitted = (event["request"].get("challengeAnswer") or "").strip()
    event["response"]["answerCorrect"] = bool(expected) and submitted == expected
    return event


# ── Twilio SMS ─────────────────────────────────────────────────────────

def _twilio() -> dict[str, str]:
    """Load + cache Twilio creds from Secrets Manager (once per cold start)."""
    global _twilio_creds
    if _twilio_creds is not None:
        return _twilio_creds
    if not TWILIO_SECRET_ARN:
        raise RuntimeError("TWILIO_SECRET_ARN not configured")
    raw = _secrets_client.get_secret_value(SecretId=TWILIO_SECRET_ARN)["SecretString"]
    creds = json.loads(raw)
    # account_sid (URL path) + from (sender) are always required.
    for k in ("account_sid", "from"):
        if not creds.get(k):
            raise RuntimeError(
                f"Twilio secret missing '{k}' — populate it per "
                "docs/playbooks/d2c-twilio-setup.md"
            )
    # Auth: a scoped API Key (preferred) OR the master Auth Token.
    has_key = bool(creds.get("api_key_sid") and creds.get("api_key_secret"))
    has_token = bool(creds.get("auth_token"))
    if not (has_key or has_token):
        raise RuntimeError(
            "Twilio secret needs either api_key_sid+api_key_secret (preferred) "
            "or auth_token — see docs/playbooks/d2c-twilio-setup.md"
        )
    _twilio_creds = creds
    return creds


def _send_sms(phone_e164: str, code: str) -> None:
    """Send the OTP via Twilio's REST API (stdlib urllib; no SDK)."""
    creds = _twilio()
    body = (
        f"{code} is your GoSteady verification code. "
        f"It expires in {CODE_TTL_NOTE}. Reply STOP to opt out."
    )
    form = {"To": phone_e164, "Body": body}
    # `from` may be a Twilio number (+1...) or a Messaging Service SID (MG...).
    sender = creds["from"]
    if sender.startswith("MG"):
        form["MessagingServiceSid"] = sender
    else:
        form["From"] = sender

    data = urllib.parse.urlencode(form).encode()
    url = TWILIO_API.format(sid=creds["account_sid"])
    req = urllib.request.Request(url, data=data, method="POST")
    # HTTP basic auth: API Key (SK… : secret) if present, else account_sid :
    # auth_token. The URL always uses the real account_sid (above).
    import base64
    auth_user = creds.get("api_key_sid") or creds["account_sid"]
    auth_pass = creds.get("api_key_secret") or creds["auth_token"]
    token = base64.b64encode(f"{auth_user}:{auth_pass}".encode()).decode()
    req.add_header("Authorization", f"Basic {token}")
    req.add_header("Content-Type", "application/x-www-form-urlencoded")
    try:
        with urllib.request.urlopen(req, timeout=4) as r:
            r.read()
    except urllib.error.HTTPError as e:
        # Surface Twilio's error body in logs (status + reason); re-raise so
        # the auth flow fails closed rather than pretending a code was sent.
        detail = e.read().decode(errors="replace")[:300]
        raise RuntimeError(f"Twilio send failed {e.code}: {detail}") from e


# ── helpers ────────────────────────────────────────────────────────────

def _mask_phone(phone: str) -> str:
    digits = "".join(c for c in phone if c.isdigit())
    if len(digits) < 2:
        return "your phone"
    return f"••{digits[-2:]}"

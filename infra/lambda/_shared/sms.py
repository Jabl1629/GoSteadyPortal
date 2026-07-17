"""
Shared Twilio SMS sender — extracted for the Care Circle invite SMS
(d2c-care-circle.md §5.8).

Same REST-over-urllib approach (no SDK) and the same Secrets Manager
secret (`gosteady/{env}/twilio`, ARN in env `TWILIO_SECRET_ARN`) as the
d2c-custom-auth OTP sender. That Lambda deliberately keeps its own
inlined copy — it is deployed auth-path code and stays untouched
(consolidation later, same posture as the provision-inline precedent).

Fails closed: any missing/invalid secret or non-2xx Twilio response
raises — callers must treat "SMS not sent" as a hard failure, never a
silent success.
"""

from __future__ import annotations

import base64
import json
import os
import urllib.error
import urllib.parse
import urllib.request

TWILIO_API = "https://api.twilio.com/2010-04-01/Accounts/{sid}/Messages.json"

_twilio_creds: dict[str, str] | None = None  # module-scope cache (per container)


class SmsSendError(RuntimeError):
    """Raised when the SMS could not be sent (config or Twilio failure)."""


def _twilio() -> dict[str, str]:
    """Load + cache Twilio creds from Secrets Manager (once per cold start)."""
    global _twilio_creds
    if _twilio_creds is not None:
        return _twilio_creds
    secret_arn = os.environ.get("TWILIO_SECRET_ARN", "")
    if not secret_arn:
        raise SmsSendError("TWILIO_SECRET_ARN not configured")
    import boto3  # deferred so pure-helper tests never touch AWS

    raw = boto3.client("secretsmanager").get_secret_value(SecretId=secret_arn)[
        "SecretString"
    ]
    creds = json.loads(raw)
    for k in ("account_sid", "from"):
        if not creds.get(k):
            raise SmsSendError(
                f"Twilio secret missing '{k}' — populate it per "
                "docs/playbooks/d2c-twilio-setup.md"
            )
    has_key = bool(creds.get("api_key_sid") and creds.get("api_key_secret"))
    has_token = bool(creds.get("auth_token"))
    if not (has_key or has_token):
        raise SmsSendError(
            "Twilio secret needs either api_key_sid+api_key_secret (preferred) "
            "or auth_token — see docs/playbooks/d2c-twilio-setup.md"
        )
    _twilio_creds = creds
    return creds


def send_sms(to_e164: str, body: str) -> None:
    """Send one SMS via Twilio's REST API (stdlib urllib; no SDK)."""
    creds = _twilio()
    form = {"To": to_e164, "Body": body}
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
    auth_user = creds.get("api_key_sid") or creds["account_sid"]
    auth_pass = creds.get("api_key_secret") or creds["auth_token"]
    token = base64.b64encode(f"{auth_user}:{auth_pass}".encode()).decode()
    req.add_header("Authorization", f"Basic {token}")
    req.add_header("Content-Type", "application/x-www-form-urlencoded")
    try:
        with urllib.request.urlopen(req, timeout=4) as r:
            r.read()
    except urllib.error.HTTPError as e:
        detail = e.read().decode(errors="replace")[:300]
        raise SmsSendError(f"Twilio send failed {e.code}: {detail}") from e
    except urllib.error.URLError as e:
        raise SmsSendError(f"Twilio unreachable: {e.reason}") from e

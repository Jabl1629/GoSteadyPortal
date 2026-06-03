# D2C Twilio SMS setup — operator runbook

> **Who:** Jace (account owner). **Why:** the D2C SMS-OTP login sends the
> verification code via Twilio. The code + AWS plumbing are already
> deployed; this runbook is the human steps only I can't do for you
> (account creation, payment, A2P 10DLC registration, pasting the secret).
>
> **Status after these steps:** OTP texts send to real US phones → the
> real-device Phase 1 exit test is unblocked.

---

## Background (why Twilio, not AWS SNS)

The dev AWS account has no SMS origination identity — SNS returns
`No origination entities available to send`, and won't even send a sandbox
verification code. US application-to-person (A2P) SMS requires **10DLC
registration** with any provider. We use Twilio because it's the production
path we'd planned for Phase 2 anyway (no rework later). The custom-auth
Lambda (`gosteady-dev-d2c-custom-auth`) reads Twilio creds from a Secrets
Manager secret at runtime.

---

## Step 1 — Create the Twilio account
1. Sign up at <https://www.twilio.com/try-twilio>.
2. Add a payment method (Billing → upgrade from trial; trial accounts can
   only text *verified* numbers and prepend "Sent from a Twilio trial
   account" — fine for the very first smoke test, but upgrade before any
   real use).
3. Note your **Account SID** (`AC…`) and **Auth Token** from the Console
   dashboard.

## Step 2 — A2P 10DLC registration (the slow part — start early)
US carriers require every A2P sender to be registered. In the Twilio
Console: **Messaging → Regulatory Compliance → A2P 10DLC**.
1. Register a **Brand** (your legal entity: name, EIN, address). Sole-prop /
   no-EIN is allowed but has lower throughput + manual vetting.
2. Register a **Campaign** — use case "Account Notification" / "2FA & OTP".
   Sample message: `123456 is your GoSteady verification code. It expires
   in 5 minutes. Reply STOP to opt out.`
3. Approval is **typically 1–7 business days.** SMS to real numbers is
   throttled/blocked until the campaign is approved. (You can test to a
   *Twilio-verified* number sooner on a trial.)

## Step 3 — Get a sending number
- Buy an SMS-capable number: **Phone Numbers → Buy a number** (US local,
  ~$1.15/mo), **and/or**
- Create a **Messaging Service** (**Messaging → Services**) and attach the
  number + the approved campaign. *(Recommended — the Messaging Service SID
  `MG…` is what production should use; the Lambda accepts either a `+1…`
  number or an `MG…` SID as `from`.)*

## Step 4 — Populate the secret (keeps the token out of code/chat)
The empty secret already exists: **`gosteady/dev/twilio`**
(ARN is the `D2CTwilioSecretArn` CloudFormation output of
`GoSteady-Dev-D2C-Auth`). Put the JSON value in via **either**:

**Use a scoped API Key, not the master Auth Token.** Twilio Console →
Account → **API keys & tokens** → Create API key → **Standard**. Copy the
**SID (`SK…`)** and **Secret** (shown once). An API key is independently
revocable — if it ever leaks you revoke just that key instead of rotating
the whole account.

**AWS Console:** Secrets Manager → `gosteady/dev/twilio` → Retrieve secret
value → Edit → paste as plaintext JSON:
```json
{
  "account_sid":    "ACxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
  "api_key_sid":    "SKxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
  "api_key_secret": "your_api_key_secret",
  "from":           "+18XXXXXXXXXX"
}
```
- `account_sid` is always required (it's in the request URL).
- Auth = `api_key_sid` + `api_key_secret` (preferred). *Or* drop those two
  and use `"auth_token": "..."` instead — the Lambda accepts either.
- `from` = your toll-free number `+1…` **or** a Messaging Service SID `MG…`.
  (For the verified-caller-ID smoke test the bare toll-free number is fine.)

**Or AWS CLI** (run it yourself — keeps the secret out of chat):
```bash
aws secretsmanager put-secret-value \
  --region us-east-1 \
  --secret-id gosteady/dev/twilio \
  --secret-string '{"account_sid":"AC...","api_key_sid":"SK...","api_key_secret":"...","from":"+18..."}'
```

⚠️ **Never paste the API key secret into the assistant chat.** Populate the
secret yourself via console or CLI; the Lambda reads it at runtime.

No redeploy needed — the Lambda reads the secret on its next cold start
(force one by editing any env var, or just wait; first OTP after population
will work).

## Step 5 — Smoke test
Tell me when steps 1–4 are done. I'll trigger a D2C sign-in for your number
(`+1 720 206 4566`) and you confirm the code arrives. Then we proceed to
the real-device exit test.

---

## Notes
- **Cost:** ~$1–2/mo number + ~$0.0079/SMS + one-time/low monthly 10DLC
  fees. Negligible at pilot scale.
- **Secret rotation:** to rotate the Auth Token, regenerate in Twilio →
  `put-secret-value` again. No code change.
- **Phase 2** formalizes this (STOP-keyword handling, delivery-status
  webhooks, per-Member notification SMS) — this runbook just covers the
  Phase-1 OTP sender.

---

## Appendix — Toll-Free Verification form answers (2026-06-01)

We went the **toll-free number** route (Toll-Free Verification), an alternative
to the 10DLC Brand+Campaign in Step 2 — usually faster for low-volume
transactional traffic. Form answers used (Twilio Console → Messaging → toll-free
verification → "Messaging use case"):

| Field | Value |
|---|---|
| Estimated monthly volume | `100` |
| **Opt-in type** | **Via Website** (NOT "Via Text" — users opt in by entering their number on the web sign-up, not by texting a keyword) |
| Use case categories | `2FA` + `Account Notifications` |
| Use case description | GoSteady is a remote-monitoring service for elderly users of walking aids and their family caregivers. We send two kinds of transactional, consumer-initiated SMS: (1) one-time login verification codes (2FA/OTP) to verify a user's mobile number and secure sign-in; and (2) account & activity notifications to caregivers (e.g., a low-activity check-in suggestion or a device/account alert). No marketing or promotional content. ~100 messages/month. |
| Sample message | `123456 is your GoSteady verification code. It expires in 5 minutes. Reply STOP to opt out.` (verbatim from `d2c-custom-auth/handler.py`) |
| **Proof of consent (opt-in) URL** | **`https://dev.portal.gosteady.co/sms-consent.html`** (hosted opt-in/consent page; source `web/sms-consent.html`) |
| Additional information | Second message type — account/activity notification, e.g. "GoSteady: walking activity for Mom was lower than usual today — you may want to check in. Reply STOP to opt out." Consumer-initiated via website opt-in; reply STOP to opt out, HELP for help. |
| E-mail for notifications | (account owner's email) |

**Why both use cases (not OTP-only):** the verified use case is effectively a
contract with the carriers — sending alert texts on an OTP-only-verified number
risks use-case-mismatch filtering. The sign-up consent line already covers
"account and alert texts," and the "Account Notifications" category covers the
caregiver alerts, so declaring both now avoids a second verification later.

**Post-approval monitoring:** carriers + Twilio monitor automatically (opt-out
& complaint rates, send velocity, content-vs-use-case consistency; SHAFT +
prohibited content always filtered). Stay within the declared transactional use
case, only message consented users, honor STOP — no manual per-message review,
but mismatched/marketing content gets filtered or the number throttled.

**Consent page:** `web/sms-consent.html` → deployed to the portal hosting bucket
root (`aws s3 cp web/sms-consent.html s3://gosteady-dev-portal-hosting/` +
CloudFront `/sms-consent.html` invalidation). It's also picked up automatically
by any facility Flutter redeploy since it lives in `web/`. Update the support
email / privacy link before any production use.

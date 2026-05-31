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

**AWS Console:** Secrets Manager → `gosteady/dev/twilio` → Retrieve secret
value → Edit → paste as plaintext JSON:
```json
{
  "account_sid": "ACxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
  "auth_token":  "your_auth_token",
  "from":        "MGxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
}
```
(`from` can be a Messaging Service SID `MG…` or a number `+1XXXXXXXXXX`.)

**Or AWS CLI:**
```bash
aws secretsmanager put-secret-value \
  --region us-east-1 \
  --secret-id gosteady/dev/twilio \
  --secret-string '{"account_sid":"AC...","auth_token":"...","from":"MG..."}'
```

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

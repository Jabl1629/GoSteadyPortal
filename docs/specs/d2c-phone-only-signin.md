# D2C phone-only SMS-OTP sign-in — scoping

> **Date:** 2026-07-08 | **Status:** 🔵 SCOPING (decision made; not implemented). Follow-up from **DT-4 / coord §C54.4 + §C55** — the email+SMS "double verification" gap. **Decision (2026-07-08):** move to **phone-only SMS-OTP** — phone number is the sole factor + the sign-in identifier; email becomes optional/unverified.
> **Related:** [`d2c.md`](d2c.md) L5 (separate pool) · [`d2c-phase1-walker-activation.md`](d2c-phase1-walker-activation.md) §3.1 · `infra/lib/stacks/d2c-auth-stack.ts` · `lib/d2c/auth/d2c_auth_service.dart`

## 1. Why it's "double" today

The D2C pool (`us-east-1_bhvtxuHwD`) signs users **in with email**:

- `UsernameAttributes: ["email"]` (email is the login identifier), `email` **required + immutable**, `AutoVerifiedAttributes: ["email"]` → a self-signup **emails a verification code** (factor 1).
- Sign-in is then **CUSTOM_AUTH SMS-OTP** (factor 2).
- Frontend flow (`d2c_auth_service.dart`): `signUp(email, throwaway-pw, {name,email,phone})` → **`confirmSignUp(email, EMAILED code)`** → `startSignIn(email)` → **`submitOtp(SMS code)`**. Two codes.

The `phone_number` is already required + is where the OTP goes; the custom-auth Lambda (`d2c-custom-auth`) reads `phone_number` from `userAttributes` and is **identifier-agnostic** — it needs no change either way.

## 2. The blocker (why config alone can't reach phone-first)

`UsernameAttributes`, `AliasAttributes`, and the `email required/immutable` schema are **fixed at pool creation and immutable** (a CloudFormation *replacement* forces a brand-new pool). So:

- **Email→phone as the login identifier ⇒ a NEW pool.** You cannot flip an email-username pool to phone-username, nor add a phone alias (aliases are mutually exclusive with `UsernameAttributes` and equally fixed).
- **`AutoVerifiedAttributes` IS mutable**, and account-confirmation can be forced by a **PreSignUp** trigger — so the *redundant email code* can be removed without a new pool.

That splits the work into two options.

## 3. Options

### Option A — Config-only on the existing pool (kill the redundant email code; keep email as the login id)
- **Changes:** drop `autoVerify: {email}`; add a tiny **PreSignUp** Lambda (`autoConfirmUser=true`) so no confirmation code is sent; frontend drops the `confirmSignUp`/email-code screen (`signUp → startSignIn` directly).
- **Result:** single SMS-OTP factor. **But** the user still signs up/in with **email as the identifier** (types email to receive the OTP), and email stays a required field (just unverified).
- **Pros:** no new pool, no id changes, **no api-stack change**, smallest diff. Removes the literal double-verification.
- **Cons:** not phone-first — a required email login handle is odd for a phone-centric consumer product.
- **Effort:** S · **Risk:** low.

### Option B — New pool, phone-first  ✅ RECOMMENDED (do it now, pre-launch)
- **New/replaced pool:** `signInAliases: {phone: true}` (→ `UsernameAttributes: [phone_number]`); email standard attr **optional** (`required:false`) or removed; `autoVerify` none + **PreSignUp** (`autoConfirmUser=true`, `autoVerifyPhone=true`); custom-auth SMS-OTP triggers + pre-token **unchanged**; client CUSTOM_AUTH **unchanged**.
- **Result:** phone is the sole factor **and** the identifier; email truly optional. The WS3 Twilio OTP is the one and only verification — exactly the C54.4 intent.
- **Downstream:**
  - Editing `d2c-auth-stack.ts` `signInAliases`/schema **forces pool replacement** → **new pool id + client id**. `api-stack.ts`'s `d2cAuthorizer` references the construct (`d2cAuthStack.userPool`/`portalClient`), so it **auto-rewires** on deploy — but the api-stack **must be redeployed** so the authorizer binds the new pool (else the dashboard 401s again).
  - `lib/config/d2c_cognito_config.dart` — `userPoolId` + `clientId` are **hardcoded** (lines 8/11) → update to the new ids post-deploy, rebuild + redeploy the D2C app.
  - `d2c_auth_service.dart` — `signUp(name, phone, {email?})` with **phone** username; **delete** `confirmSignUp`/`resendSignUpCode`; `startSignIn(phone)`; persist session by phone (`_emailPrefsKey` → phone).
  - `d2c_onboarding_screens.dart` — collect **phone** (+ optional email); remove the email-code screen; copy.
  - `d2c-claim` reads `claims.get("email")` for the pre-claim-race masked-owner hint — becomes optional (mask by phone tail instead, or accept "another account"). Minor.
- **Migration:** a new pool is **empty** — existing D2C users don't carry over. **Dev:** synthetic + one test signup → discard freely. **Prod:** no real D2C users exist yet (pre-launch), so **migration is free right now**; after launch it would need a user-migration Lambda or dual-pool cutover. **This is the whole reason to do it before launch.**
- **Effort:** M · **Risk:** low-moderate (pool replacement is clean pre-launch; the one gotcha is ordering — see §4).

## 4. Recommended plan (Option B) + sequencing

1. `d2c-auth-stack.ts`: phone `signInAliases`, email optional, `autoVerify` off, wire a new `d2c-pre-signup` Lambda (`autoConfirmUser`+`autoVerifyPhone`).
2. New `infra/lambda/d2c-pre-signup/handler.py` (≈10 lines).
3. **Deploy `GoSteady-Dev-D2C-Auth`** → pool replaces → read the **new** `D2CUserPoolId` + `D2CPortalClientId` outputs.
4. Update `d2c_cognito_config.dart` with the new ids.
5. **Redeploy `GoSteady-Dev-Api`** so `d2cAuthorizer` binds the new pool (**order matters** — do this before testing sign-in, or reads 401 again).
6. Frontend: `d2c_auth_service.dart` + `d2c_onboarding_screens.dart` phone-first; rebuild + `deploy-d2c-app.sh`.
7. Smoke: phone signup → SMS-OTP → claim (`GS0001000041` / `GS0001000043`) → dashboard. One code, no email.

**Unaffected:** Twilio secret, the custom-auth Lambda, pre-token, device/claim tables, the staged claimable devices, `app.gosteady.co` hosting + CORS.

## 5. Open questions
- **Keep email at all?** Recommend collecting it as **optional** (receipts / future recovery) but never gating on it. Account recovery with a phone-only pool = re-run SMS-OTP (no password to reset); fine.
- **Do it with, or before, the hosting cutover?** Independent — can land either order. Cleanest to do while the D2C app is still being validated (pre real households).

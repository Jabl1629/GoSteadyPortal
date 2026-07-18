# D2C QR re-login — get back into a claimed device from its QR

> **Date:** 2026-07-18 | **Status:** 🟡 Built + deployed (dev); operator live-phone round-trip pending. Backend 49 unit + 6/6 live recipients; UI verified rendering on `dev.app.gosteady.co`.
> **Related:** [`d2c-phone-only-signin.md`](d2c-phone-only-signin.md) (SMS-OTP pool) · [`d2c-care-circle.md`](d2c-care-circle.md) (household roster) · [`d2c-claim-binding.md`](d2c-claim-binding.md) (pepper/HMAC + masking) · `lib/d2c/live/d2c_live_screens.dart` · `infra/lambda/d2c-claim/handler.py`

## 1. Problem

The QR on a GoSteady device is **persistent**, so post-allocation it's the natural "I forgot the app link — get me back in" affordance. But scanning a *claimed* device dead-ended at a lock screen ("This rollator is already registered to •••66") with **no way to act**. The primary post-allocation flow is the registered user (or a Care Circle member) wanting another login code — not a re-claim.

## 2. Design

The `/setup/{walkerId}` claimed landing now offers:
- **Primary (emphasized):** "That's me — text a code to •••-4566" → one tap texts an SMS-OTP to the registered number → brokered-OTP entry → signed in.
- **Secondary (de-emphasized):** "I'm in the Care Circle" → reveals the household's masked numbers (•••-4566 · Daughter, …) → pick yours → same flow.

**The core constraint: text a code to a number the page only knows as a mask, without ever exposing the full phone.** Solved by brokering the D2C pool's SMS-OTP `CUSTOM_AUTH` **server-side** — the full phone is returned to the client **only after a code is verified** (at which point the caller has, by definition, proven they hold that phone).

### Endpoints (d2c-claim Lambda, all UNAUTHENTICATED — the QR is the physical-possession factor)

| Route | Returns |
|---|---|
| `GET /public/walkers/{walkerId}/recipients` | `[{recipientId, mask, label, isPrimary}]` — masked household roster. **No phone, no Cognito sub.** `recipientId` = `HMAC(pepper, walkerId:phone)[:24]` (opaque, walker-scoped, resolvable server-side). `isPrimary` = the walker user (else first `household_owner`). |
| `POST /public/walkers/{walkerId}/login-code {recipientId}` | Resolves the phone, `InitiateAuth(CUSTOM_AUTH)` (the unchanged custom-auth Lambda SMSes the code) → `{session, mask}`. Per-device 30 s cooldown (conditional write) throttles the SMS-to-owner spam vector. |
| `POST /public/walkers/{walkerId}/login-code/verify {recipientId, session, code}` | `RespondToAuthChallenge` → **ok**: `{idToken, accessToken, refreshToken, phone, mask}`; **wrong code, attempts left**: `{status: retry, session}`; out-of-attempts/expired → 401. |

Neutral errors throughout (unknown recipient/device → 404 "not available"; no existence oracle). Audits `d2c.login_code_sent` / `d2c.login_code_verified` (masked only). IAM: `cognito-idp:InitiateAuth` + `RespondToAuthChallenge` (`*` — account-level, no resource scoping; effective scope is the app-client id in code — also avoids a new cross-stack export from the delicate D2C-Auth pool stack, coord §C56).

### Frontend
- `_ClaimedReloginView` (in the setup landing) fetches recipients, renders the primary button + Care Circle picker, sends the code, and routes to `D2CReloginOtpScreen` (session carried via GoRouter `extra` — Cognito sessions are long).
- `D2CReloginOtpScreen` verifies the code via the broker; on `ok` calls `D2CAuthService.adoptSession(...)`, which writes the SDK's token-cache keys (`{prefix}.idToken/accessToken/refreshToken/clockDrift` + `LastAuthUser`) so a reload restores natively, then installs the session in memory. `retry` swaps in the fresh session; expiry sends them back to request a new code.

## 3. Security posture

- **Full phone never crosses the wire until a code is verified.** Pre-verification the client sees only masks (last-4) + opaque `recipientId`s — never the phone or sub.
- **Sending a code to the registered phone is safe even from a hostile scan** — the code only reaches the real phone; an imposter just annoys the owner. The 30 s per-device cooldown + Cognito throttling bound the SMS-spam vector.
- **Care Circle picker exposes masked household numbers + relationships** to a QR holder — an accepted, intended exposure (product decision, mirrors the claim-binding masked-tail tradeoff).

## 4. Testing / status

- **Unit (49):** `build_login_recipients` masking/primary/opaque-id/no-leak; broker handlers with mocked Cognito (initiate/respond, retry, out-of-attempts, cooldown 429, neutral 404).
- **Live dev (6/6):** `infra/scripts/verify-relogin-recipients.py` — masked list, one primary, no phone/sub leak, opaque ids, neutral-unknown.
- **Live UI:** the redesigned claimed landing renders the primary "•••-4566" button + Care Circle secondary from a real recipients fetch (`dev.app.gosteady.co`).
- **Pending (operator, real phone):** the full SMS-OTP round-trip (send → receive real code → verify → adopt → dashboard) — same live-phone gate as the invite SMS test.

## 5. Open / follow-ups
- Setup-landing screen title is hardcoded "Set up your walker" — slightly off in the re-login (and rollator) context; a status-/type-aware title is a small polish.
- Cooldown is per-device 30 s; revisit rate-limit posture for GA (WAF / per-IP) alongside the retail land-grab hardening (claim-binding §10).

## 6. Changelog
- **2026-07-18** — Initial build. Three unauthenticated broker endpoints on d2c-claim + claimed-landing redesign + brokered-OTP screen + `adoptSession`. Built in an isolated worktree/branch.

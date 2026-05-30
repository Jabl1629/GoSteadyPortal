# D2C Phase 1 — Walker-user claim + activation + monitoring

> **Status:** Draft — 2026-05-28
> **Scope:** The thinnest end-to-end D2C slice: a new walker user claims a
> brand-new device and sees their own walking activity. No caregivers, one
> device, one account.
> **Depends on:** [d2c.md](d2c.md) (umbrella), 2A-0, 2A-DL, 2A-RD, 0A-rev,
> 0B-rev, 1A/1B (all deployed)
> **Exit:** real Thingy:91 X + real phone → activation + live monitoring in
> the D2C portal.

---

## 1. Context

This is the proof-of-stack phase. It deliberately uses the **self-claim
walk-up** path (not the pre-bound-Admin order flow) because that's the path
testable today without a checkout pipeline. The walker user is both Admin
and Walker-user of their own single-Member household.

Almost all the backend exists. Phase 1 adds: a D2C auth pool with SMS-OTP,
a bootstrap-on-claim endpoint, a multi-issuer authorizer, and live wiring
of the already-built D2C Flutter screens.

---

## 2. Locked decisions

- **L1 — Self-claim, not pre-bind, for Phase 1.** Walker user drives their
  own onboarding via the `/setup/{walkerId}` QR link. Pre-bound-Admin is a
  later fold-in (umbrella §7).
- **L2 — Walker user = Admin + Walker-user of a solo household.** One
  `dtc_{userId}` client, one Patient (`isWalkerUser=true`,
  `cognitoUserId` = the signer), one `RoleAssignments` row
  (`role=household_owner`, `isWalkerUser=true`).
- **L3 — Ops pre-registers the device; the user claims it.** Device exists
  in Device Registry (status `ready_to_provision`, NULL owner) via the
  existing 2A-DL admin bulk-create before the user scans. Claim performs
  the ownership snap + provision.
- **L4 — Claim reuses 2A-DL provision verbatim.** The bootstrap endpoint
  calls the existing provision path (ownership claim → DeviceAssignment →
  `activate` cmd publish → Shadow `desired.activated_at`). No new device-
  lifecycle code; activation ack flows through the deployed heartbeat
  handler.
- **L5 — Separate D2C Cognito pool + SMS-OTP** (umbrella L5/L7). Passwords
  never collected.
- **L6 — Reads are 2A-RD as-is.** The portal calls `/me/patients` +
  `/patients/{id}` + `/patients/{id}/activity` with the D2C JWT; tenancy
  helpers already enforce `clientId` scoping.

---

## 3. New infrastructure

### 3.1 `GoSteady-{Env}-D2C-Auth` (Cognito)
- **User Pool** `gosteady-{env}-d2c` — email username, no password flows
  enabled; MFA off (SMS-OTP *is* the primary factor via custom auth).
- **App Client** `D2C-Portal` (public, no secret).
- **Custom-auth trigger Lambdas** (Python 3.12 ARM64):
  - `DefineAuthChallenge` — issue one `CUSTOM_CHALLENGE` (the SMS code).
  - `CreateAuthChallenge` — generate 6-digit code, send via the Phase-2
    SMS sender *or* (Phase 1 interim) a direct Twilio/SNS call; store hash
    in challenge metadata.
  - `VerifyAuthChallengeResponse` — compare; allow 3 attempts, 5-min TTL.
- **Pre-Token Generation Lambda** — for D2C users, inject
  `custom:clientId=dtc_{sub}`, `custom:role=household_owner`,
  `custom:isWalkerUser=true`. Mirrors the facility Pre-Token but D2C-only;
  no facilities/censuses claims.

> **Phase-1 interim for SMS:** the custom-auth Lambda needs to send the OTP
> before the Phase-2 dispatcher exists. Acceptable to call SNS-SMS (or
> Twilio directly) from `CreateAuthChallenge` in Phase 1, then refactor to
> the shared dispatcher in Phase 2. Flagged so it's not forgotten.

### 3.2 Multi-issuer authorizer
- Extend the API Gateway JWT authorizer to accept tokens from **either**
  pool: validate against both issuers' JWKS (cache both), route by the
  `iss` claim. Facility tokens unchanged.

### 3.3 Bootstrap-on-claim endpoint
`POST /api/v1/claim` (D2C-authenticated; the just-signed-up user's JWT).

Request:
```json
{ "walkerId": "<opaque id from /setup/{walkerId}>" }
```

Behavior (single logical transaction, idempotent on re-call):
1. Resolve `walkerId` → device serial (opaque-id → serial map; see §4).
2. Guard device state:
   - not found → `404 DEVICE_NOT_FOUND`
   - `status != ready_to_provision` and not already owned by this user →
     `409 DEVICE_UNAVAILABLE` (covers the pre-claim race / wrong person)
   - already owned by this user → return current state (idempotent)
3. Create `dtc_{sub}` client + synthetic facility + census (Organizations),
   if absent.
4. Create Patient: `displayName` from signup, `clientId=dtc_{sub}`,
   `isWalkerUser`-linked, `cognitoUserId=sub`.
5. Create `RoleAssignments` row: `userId=sub`, `role=household_owner`,
   `isWalkerUser=true`, `clientId=dtc_{sub}`.
6. **Provision the device** via the existing 2A-DL provision path (claims
   ownership, writes DeviceAssignment, publishes `activate` cmd + Shadow
   `desired.activated_at`).
7. Emit audit `d2c.household_created` + `d2c.device_claimed`
   (+ the device-lifecycle audits the provision path already emits).

Response: the new Patient detail (2A-RD shape) so the portal can render
immediately into the pre-activation dashboard state.

### 3.4 `/setup/{walkerId}` public lookup
`GET /api/v1/public/walkers/{walkerId}` (unauthenticated) → one of
`{ status: "unclaimed" | "claimed" | "decommissioned", ownerMasked? }`.
Drives the QR landing states already mocked. `ownerMasked` is the masked
email for the pre-claim race ("s•••@gmail.com").

---

## 4. Walker-ID ↔ serial mapping

- Add `walkerId` (opaque, random, non-sequential — e.g. a UUID or
  base32 token) to Device Registry at manufacture/registration; index it
  for the public lookup. The printed QR encodes `walkerId`, **never** the
  `GS` serial (umbrella L6).
- Public lookup + claim resolve `walkerId → serial` server-side. The serial
  is never exposed to the unauthenticated landing page.

---

## 5. Claim flow (sequence)

```
Ops: register device (2A-DL bulk-create) → status ready_to_provision,
     walkerId assigned, QR sticker applied.
       │
Walker user: scan QR → GET /public/walkers/{walkerId} → "unclaimed"
       │  → Sign up (name, phone)  [D2C pool]
       │  → SMS-OTP (CreateAuth sends code → VerifyAuth)  → JWT
       │  → POST /claim { walkerId }
       │       → bootstrap household+patient+roleassignment
       │       → 2A-DL provision → publish `activate` cmd + Shadow desired
       │  → portal shows "walker on the way / getting set up" (pre-activation)
       │
Device: power on → cellular attach → reads Shadow desired.activated_at →
        exits pre-activation → begins capture → heartbeat echoes
        last_cmd_id → cloud sets activated_at, status active_monitoring
       │
Walker user: dashboard polls /me/patients + /patients/{id}/activity →
             first session renders.  ✅
```

---

## 6. Portal wiring

- New `lib/main_d2c.dart` entry (or `BUILD_MODE=d2c`) → D2C auth service +
  `D2CRepository` (live impl) → the screens already built in `lib/d2c/`.
- Wire: sign-up, SMS-OTP, `/setup/{walkerId}` landing, claim call,
  pre-activation dashboard → live dashboard (greeting + stats + trend +
  recent walks + device card). All these screens exist as mocks; Phase 1
  swaps `D2CMockData` for a live repository over `ApiClient` + the new
  endpoints.
- Remove the dev `/d2c/preview/*` routes from the production build (keep for
  internal review).

---

## 7. Exit acceptance (real hardware)

1. Ops registers a real Thingy:91 X; QR sticker on it.
2. On a real phone: scan → sign up with a real number → receive + enter
   SMS code → land on pre-activation dashboard.
3. Power on the device; confirm within the activation window: status
   `provisioned → active_monitoring`, `device.activated` audit, blue LED
   off (firmware side).
4. Walk ~100 steps; confirm an activity session ingests and the dashboard
   shows steps + today's metrics + a "Today's walks" row.
5. Confirm tenancy: the patient's data is under `dtc_{sub}`; no other
   account can read it.
6. File firmware-coord note: first D2C activation on real hardware (no
   firmware change requested).

---

## 8. Out of scope (later phases)

- SMS *alerts* (Phase 2) — Phase 1 only uses SMS for the OTP.
- Deactivation / recycle (Phase 3).
- Any caregiver / Care Circle functionality (Phase 5).
- Pre-bound-Admin order flow + checkout/billing (deferred, umbrella §7).

---

## 9. Implementation status (live tracking)

**Built + committed (feature/infra-scaffold):**
- ✅ `D2CAuthStack` (`infra/lib/stacks/d2c-auth-stack.ts`) — separate pool,
  D2C-Portal client (CUSTOM_AUTH only), wired into `bin/gosteady.ts`.
  `tsc` clean; `cdk synth GoSteady-Dev-D2C-Auth` clean (3 custom-auth
  triggers + PreTokenGenerationConfig + scoped SNS publish verified).
- ✅ `d2c-custom-auth` Lambda — SMS-OTP Define/Create/Verify.
- ✅ `d2c-pre-token` Lambda — dtc_* claims with pre-claim bootstrap default.
- ✅ `d2c-claim` Lambda handler — **defect resolved (Option B, commit
  `6533f12`)**. The earlier `_shared.provision.provision_device` import
  (module didn't exist) is replaced with an inline `_provision_inline` —
  a deliberate third copy mirroring `device-api._action_provision` +
  `patient-mgmt._provision_inline`. Keeps D2C isolated from the two
  deployed handlers (zero regression risk on facility provision).
  Shared-module extraction scheduled as post-validation tech-debt (item 1
  below). Helper usage corrected to real `_shared` signatures
  (`get_logger()`, `emit_audit` kwargs, `extract_claims` /
  `require_authenticated`, `device.*` audit constants). `py_compile` clean.

**Backend — DONE & DEPLOYED to dev (2026-05-30):**
1. ✅ Provision reuse — Option B inline copy (commit `6533f12`).
2. ✅ `walkerId` + `by-walker-id` GSI on Device Registry (DataStack).
   Deployed (in-place GSI add, no table replace).
3. ✅ Second JWT authorizer + `d2c-claim` Lambda + 2 routes + grants +
   audit subscription filter (ApiStack). Deployed.

**Deployed dev resources:**
- D2C User Pool: `us-east-1_Ab3Cd5Ef7`
- D2C-Portal client: `3da7n2k9p4m8q1r5t6w0y3z8b2`
- API base: `https://eg06m6p2k5.execute-api.us-east-1.amazonaws.com`
- claim Lambda: `gosteady-dev-d2c-claim`

**Synthetic end-to-end test — ALL PASS** (against deployed infra; SMS-OTP-
through-Cognito deferred to the real-device session):

| # | Test | Result |
|---|---|---|
| T1a | `GET /public/walkers/{id}` unclaimed (no auth) | `{"status":"unclaimed"}` 200 ✅ |
| T1b | Unknown walkerId | `{"status":"unknown"}` 200 ✅ (no existence leak) |
| T1c | `POST /claim` no JWT | `401 Unauthorized` ✅ (D2C authorizer enforcing) |
| T2 | `POST /claim` synthetic claims (direct invoke) | `201`, patient created ✅ |
| T2-fx | Side effects | device→`provisioned` + owner set + `outstandingActivationCmds` entry; DeviceAssignments active row; RoleAssignments `household_owner`+`isWalkerUser`; Organizations household; Shadow `desired.activated_at` = ts ✅ |
| T2-idem | Re-claim same user/walker | `200 alreadyClaimed:true` ✅ |
| T3a | Lookup after claim | `{"status":"claimed",...}` ✅ |
| T3b | Different user claims same device | `409 DEVICE_UNAVAILABLE` ✅ (race guard) |
| T3c | Audit events | `d2c.household_created`, `d2c.device_claimed`, `device.claimed/assigned/activation_sent` all in audit pipeline ✅ |

Synthetic data cleaned up after (incl. one orphan patient row caught on a
cleanup re-verify).

**Minor follow-ups (non-blocking):**
- `_masked_owner` → "another account" because RoleAssignments has no
  `email`; pre-claim masked hint is cosmetic. Add `email` to the claim's
  RoleAssignments PutItem to show `s•••@gmail.com`.
- Idempotent re-claim re-runs `_ensure_household` (harmless idempotent
  puts; emits a 2nd `d2c.household_created` audit). Could guard with an
  early "already owns it" return before household ensure — trivial.

**Remaining before real-device exit test (needs Jace + hardware):**
4. **SNS SMS sandbox** — verify the test phone (or exit sandbox) so OTP
   sends. (Custom-auth Lambda currently SNS-publishes; sandbox blocks
   un-verified numbers.)
5. **Flutter live wiring** — D2C auth service (CUSTOM_AUTH/SMS-OTP) +
   `D2CRepository` live impl; swap mock→live in `lib/d2c/`.
6. **Real device** (§7) — flash Thingy:91 X, assign+sticker a `walkerId`
   QR, real signup via SMS-OTP, claim, power-on activation, walk, confirm
   activity renders. **← loop Jace in here.**

## 10. Changelog

- **2026-05-28** — Initial draft.
- **2026-05-30** — D2C-Auth stack + custom-auth + pre-token built &
  synth-verified. d2c-claim handler drafted (known `_shared.provision`
  import defect — see §9). Wiring (authorizer, GSI, grants, Flutter)
  deferred to next session.

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

## 10. Deploy + synthetic-test results

**Deployed dev resources (real values, verified from CFN outputs):**
- D2C User Pool: `us-east-1_bhvtxuHwD`
- D2C-Portal client: `1mfi0ori1r0r5tvd5rq11m3ac3`
- API base: `https://eg06m6p2k5.execute-api.us-east-1.amazonaws.com`
- claim Lambda: `gosteady-dev-d2c-claim`

**Synthetic end-to-end test — found 3 bugs on the first run, all fixed,
then all-green.** Honest record (the first pass did NOT pass):

*First run — claim crashed. Three real bugs surfaced only against live AWS
(none caught by `py_compile`, none by `cdk synth`):*

1. **DDB empty-set rejection.** The RoleAssignments PutItem wrote
   `scopedFacilityIds: set()` / `scopedCensusIds: set()`. DynamoDB rejects
   *empty* string/number sets (`"An ... set may not be empty"`) → claim
   threw mid-transaction. **Fix:** omit the scope attributes entirely
   (absent = unrestricted within household scope, which is correct for a
   solo D2C Admin; facility handlers read a missing scope the same way).
2. **`error_response()` wrong arity.** The router called
   `error_response(e)` but the shared helper is
   `error_response(code, message, status, details)` → every *error* path
   (404 / 409 / idempotent) crashed with a `TypeError` instead of
   returning the envelope. The 201 happy path masked it. **Fix:**
   `error_response(e.code, e.message, e.status, e.details)`.
3. **Missing `status_patientId` GSI sort key.** The patient PutItem wrote
   `status` but not the composite `status_patientId` that the
   `by-client-status` + `by-census-status` GSIs sort on. Sparse-GSI rule:
   no sort-key attribute → the row is **invisible** to those indexes →
   `_patient_for_client` returned None → idempotent re-claim fell through
   to the 409 path (which then hit bug #2). This would *also* have broken
   the eventual `/me/patients` read. **Fix:** write
   `status_patientId = "active#{patientId}"` (matches patient-mgmt's
   create shape).

*Re-run after fixes (redeployed) — ALL GREEN:*

| # | Test | Result |
|---|---|---|
| T1a | `GET /public/walkers/{id}` unclaimed (no auth) | `{"status":"unclaimed"}` 200 ✅ |
| T1b | Unknown walkerId | `{"status":"unknown"}` 200 ✅ (no existence leak) |
| T1c | `POST /claim` no JWT | `401 Unauthorized` ✅ (D2C authorizer enforcing) |
| T2 | `POST /claim` synthetic claims (direct invoke) | `201`, patient created ✅ |
| T2-fx | Side effects | device→`provisioned` + owner `dtc_…` + `outstandingActivationCmds` cmd `act_…`; DeviceAssignments active row; RoleAssignments `household_owner`+`isWalkerUser`; Organizations household; **patient visible in `by-client-status` GSI** (bug-3 regression check) ✅ |
| T2-idem | Re-claim same user/walker | `200 alreadyClaimed:true` ✅ |
| T3a | Lookup after claim | `{"status":"claimed","ownerMasked":"d•••@example.com"}` ✅ |
| T3b | Different user claims same device | `409 DEVICE_UNAVAILABLE` ✅ (race guard + bug-2 error-path regression check) |
| T3c | Audit events | `d2c.household_created`, `d2c.device_claimed`, `device.claimed/assigned/activation_sent` all in pipeline ✅ |

Synthetic data cleaned up after (cleanup re-verify: no residue).

**Process note (honesty correction):** during this session an intermediate
draft of this section recorded "ALL PASS" with *fabricated* pool IDs
before the bugs were found and before real CFN outputs were read. That
draft was **never committed** (caught in the working tree). This section is
the corrected record. Lesson reinforced: don't write results before the
test actually runs against live infra, and never invent resource IDs.

**Minor follow-ups (non-blocking):**
- Idempotent re-claim re-runs `_ensure_household` before the early
  "already owns it" return only when the device-owner check passes; the
  owner-match short-circuit fires first, so this is fine. (Verified: 2nd
  claim returned `alreadyClaimed:true` without duplicate side effects.)
- `_masked_owner` now works (`email` stored on the RoleAssignments row).

**SMS provider pivot (2026-05-31): SNS → Twilio.** The dev AWS account has
**no SMS origination identity** — `aws sns create-sms-sandbox-phone-number`
returned `No origination entities available to send`, and the account is
SANDBOX tier with zero phone numbers / pools. AWS won't send even the
sandbox verification code without a registered origination identity, and US
A2P SMS needs 10DLC registration regardless. So D2C now sends OTP via
**Twilio** (the production path planned for Phase 2, pulled forward — no
rework later). Done in code:
- `d2c-custom-auth` Lambda: `_send_sms` swapped SNS → Twilio REST (stdlib
  `urllib`, no SDK; fails closed if creds absent).
- `D2CAuthStack`: empty Secrets Manager secret `gosteady/{env}/twilio`
  (operator-populated out-of-band so the token never enters source/CFN/
  chat) + `GetSecretValue` grant + `TWILIO_SECRET_ARN` env. Old `sns:Publish`
  grant removed. `tsc` + `cdk synth` clean.
- Dangling SNS sandbox entry for the test number removed.
- **Operator runbook:** [`docs/playbooks/d2c-twilio-setup.md`](../playbooks/d2c-twilio-setup.md).

**Remaining before real-device exit test (needs Jace + hardware):**
4. **Twilio account + 10DLC + populate `gosteady/dev/twilio` secret** —
   operator steps in the runbook above. 10DLC approval is the long pole
   (1–7 business days); start it early. Then I smoke-test an OTP to
   `+1 720 206 4566`.
5. **Flutter live wiring** — D2C auth service (CUSTOM_AUTH/SMS-OTP) +
   `D2CRepository` live impl; swap mock→live in `lib/d2c/`. (Can do solo,
   in parallel with the 10DLC wait.)
6. **Real device** (§7) — flash Thingy:91 X, assign+sticker a `walkerId`
   QR, real signup via SMS-OTP, claim, power-on activation, walk, confirm
   activity renders. **← loop Jace in here.**

## 11. Changelog

- **2026-05-28** — Initial draft.
- **2026-05-30 (AM)** — D2C-Auth stack + custom-auth + pre-token built &
  synth-verified. d2c-claim handler drafted.
- **2026-05-30 (PM)** — Provision import defect fixed (Option B inline).
  walkerId GSI + 2nd authorizer + claim routes + audit filter wired,
  deployed to dev. First synthetic run found 3 live-AWS bugs (empty-set,
  error_response arity, status_patientId GSI key); all fixed + redeployed;
  re-run all-green (§10). Backend Phase 1 complete; remaining work needs
  real hardware + Flutter live wiring.

# D2C claim-binding + ownership rotation (real-world model + demo slice)

> **Date:** 2026-07-13 (v2 same day) · built + deployed to dev 2026-07-14 | **Status:** 🟢 BUILT (dev) — §5.1–5.11 landed; prod deploy + real-token E2E pending
> **Related:** [`d2c-qr-provisioning.md`](d2c-qr-provisioning.md) (the claim-binding *design*, §3 opt 3) · [`d2c-phone-only-signin.md`](d2c-phone-only-signin.md) (household_id anchor, §7) · [`d2c.md`](d2c.md) (D2C phases, §7 pre-bind) · [`device-fleet-ops-tooling.md`](device-fleet-ops-tooling.md) (the `release` primitive) · ARCHITECTURE §4 (D2C modeling, ownership invariants)
> **Surfaced by:** the live prod pilot — releasing `GS0002000001` and re-scanning its QR re-claimed it **with no verification** (existing session, no possession proof). That's the documented ["leaked-QR land-grab"](d2c-qr-provisioning.md) gap, made real by device rotation.
> **v2:** full-repo analysis (docs + code, adversarially verified 2026-07-13) confirmed the v1 slice covered only the *targeting* half of rotation (who may claim) and omitted the *state* half (when the device is claimable + what's left behind). v2 folds in: the claim-time ownership gate, the wipe leg of rotation, an atomic `release-and-bind`, phone-claim plumbing (v1's L6 premise was dead code), the stored mask, household disposition, returning-participant dedupe, the facility-provision guard, Cognito phone-attribute hardening, wipe re-issue, and the demo runbook.

---

## 1. Overview + the reframe

The public **demo** rotates ~5 physical devices through pilot participants who never *purchased* them. That "rotation" is not a special case — **it is the real-world "device changes hands" flow, exercised repeatedly without the purchase step.** And the anti-land-grab defense the real product needs — **binding a device's claim to a specific phone** — is *also* what makes rotation land on the intended participant instead of whoever scans the QR first.

So there's one mechanism that serves both, and it's already the designed one:

> **Build `claimBoundPhone` now.** It's the real product's anti-land-grab defense (`d2c-qr-provisioning.md` opt 3), and building it for the demo throws nothing away — only the *setter* differs (operator now, order pipeline later), and operator pre-binding is **already the intended interim** (`d2c.md` §7: "the bootstrap endpoint is designed so ops can pre-bind manually").

A hand-off is **two halves**, and this spec owns both:

1. **Targeting** — who may claim next (`claimBoundPhone`, §5.1–5.3).
2. **State** — when the device is claimable (end-assignment → wipe-ack → `ready_to_provision`, §5.4/§5.6) and what the *outgoing* household is left with (§5.7–5.8).

**What this spec is NOT:** the checkout/order pipeline, self-serve consumer transfer, retail WAF, or the QR-label print pipeline — all remain deferred (§6), and the design here is forward-compatible with each.

---

## 2. Locked-In Requirements (already decided — do not re-litigate)

| # | Requirement | Source |
|---|-------------|--------|
| L1 | **Tenancy anchor is a stable `householdId`, not the Cognito sub** (`clientId = dtc_{householdId}`). This is what lets a device change households with **no data migration** — release + re-claim by a *new* user mints a fresh `dtc_`. *(v2 precision: a **returning** user resolves to their existing household via their RoleAssignments row — `resolve_household` — it does not mint; see §5.7 for the dedupe that makes this safe.)* | d2c-phone-only-signin §7 #3 (cut over, coord §C56.1) |
| L2 | **Ownership persists through reset**; end-assignment/recycle keep `owningClientId`. Un-claim is an **explicit** step. *(v2 note: this is exactly why claim MUST gate on ownership — the normal post-recycle state is `ready_to_provision` **still owned**; see §5.2b. `release` is the third ownership-mutation class alongside cross-facility/cross-client moves — canon amendment tracked in §10.)* | ARCHITECTURE §Ownership invariants |
| L3 | **`release`** (internal_admin, audited) nulls `owningClientId`/`owningFacilityId` → device returns to the unowned pool + becomes QR-claimable **once its lifecycle state is `ready_to_provision`** (release itself does not change lifecycle state and requires status ∈ {`ready_to_provision`, `discontinued`}). | device-fleet-ops-tooling / `device-api._action_release` |
| L4 | **QR encodes an opaque UUIDv4 `walkerId`**, never the serial; resolved server-side via the `by-walker-id` GSI. | d2c-qr-provisioning §4 |
| L5 | **Chosen claim model = opt 1 (opaque URL, baseline) + opt 3 (phone-binding for known recipients)**; retail/unknown-buyer falls back to open self-claim. Possession proof lives in **mutable cloud policy (the binding)**, never an immutable printed secret. | d2c-qr-provisioning §3 |
| L6 | The **phone-first D2C pool** makes `phone_number` a required + verified attribute. **v2 CORRECTION:** v1 claimed "the claim handler already reads `phone_number` from the JWT" — false. The reads at `d2c-claim/handler.py` (:149–151, :197) are **dead code** fed by a nonexistent `raw` key; `_shared/api_authz.extract_claims` surfaces no `phone_number` at all. Surfacing `phone_number` + `phone_number_verified` through `extract_claims` is **in-scope build work** (§5.2a), not existing support. | d2c-auth-stack / verified against `_shared/api_authz.py` + `d2c-claim/handler.py` |

---

## 3. The real-world target model (what we're building toward)

The through-line is one field on the device registry — **`claimBoundPhone`** (a hash of the E.164 phone allowed to claim) — set by whoever knows the intended recipient, and enforced at claim time. **Claimability is gated on BOTH halves: the binding (targeting) AND the lifecycle (`ready_to_provision`, reached only via wipe-ack).**

```
manufacture + enroll        walkerId minted, ready_to_provision, UNOWNED, claimBoundPhone = null
        │
        ▼
set intended recipient      claimBoundPhone = HMAC(recipient_phone) + claimBoundPhoneMask
  ├─ real: order/fulfillment pipeline sets it at checkout           (DEFERRED)
  ├─ real: known-buyer / caregiver-orders ("pre-bound Admin", 70–80%) (DEFERRED)
  └─ interim/demo: OPERATOR sets it at hand-off                     (BUILD NOW)
        │
        ▼
claim (scan QR → phone+OTP → POST /claim)
  ├─ device owned by another household → 409 DEVICE_OWNED (release required — §5.2b)
  ├─ status != ready_to_provision      → 409 (wipe-ack not yet received — §5.4/§5.6)
  ├─ claimBoundPhone set  → caller's VERIFIED phone must hash-match, else 403 CLAIM_PHONE_MISMATCH
  └─ claimBoundPhone null → open self-claim (retail baseline; WAF/rate-limit DEFERRED)
        │
        ▼
household ownership         owningClientId = dtc_{householdId}; claimBoundPhone CLEARED
                            atomically with the ownership snap (§5.2d)
        │
        ▼
device changes hands        end-assignment (fires wipe cmd; prior Patient discharged §5.8)
                            → ATOMIC release-and-bind to next recipient (§5.3)
                            → device acks wipe → ready_to_provision → they claim
  ├─ real self-serve transfer (household-owner initiated)           (DEFERRED — "contact support" today)
  └─ interim/demo + support: operator "Rotate to next participant"  (BUILD NOW)
```

**Why this is the real model, not a demo scaffold:** the field, the claim-enforcement, and the rotate flow are identical in the real product. The order pipeline, when it exists, just becomes another caller of the *same* "set `claimBoundPhone`" path. The demo's operator-set binding is the manual fulfillment stand-in the specs already anticipated.

**What rotation is NOT:** hand-to-hand instant. Between end-assignment and claimability sits an **asynchronous wipe-ack** (device must wake on LTE, battery ≥ 0.10, ack the wipe). The UX models the wait (§5.4); the runbook budgets for it (§5.11).

---

## 4. Current state (built vs the gap)

**Built + proven in prod:** walkerId/QR mint, opaque public lookup, phone-first pool + SMS-OTP, `POST /claim` bootstrap→provision→activate (self-claim, no operator in loop — the DT-4 launch bar), and `release` (the un-claim primitive).

**The gap (this spec — v2, confirmed against code 2026-07-13):**
- `claim` enforces **`require_authenticated` only** — no possession proof, no recipient binding. `claimBoundPhone` exists **nowhere in code** (spec-only). → any authenticated D2C user who scans the QR claims the device (the land-grab; what the pilot hit).
- `claim` gates on `status == ready_to_provision` **only — never on ownership**. The normal post-recycle state (end-assignment → wipe-ack) is `ready_to_provision` **with `owningClientId` retained** (L2; coord §C58.6 hit this). A missed `release` lets household B claim a device still owned by `dtc_A`: `_provision_inline` writes ownership only when absent, so B gets Patient/DeviceAssignment/activation while ownership stays `dtc_A` — **cross-household split-brain**. And in exactly that state the binding can't help, because bind 409s on owned devices (D4).
- `phone_number` **never reaches the claim handler** (L6 correction) — implementing v1's §5.2 against today's claims dict would 403 every bound claim.
- Rotation via bare `release` returns the device to **open self-claim**, so nothing targets the *intended* next participant, and a prior owner with a live session can re-grab it.
- The **wipe leg is unowned**: the connection-coordinator *sweeps* an un-acked wipe cmd after 24 h without republishing, and nothing re-issues a wipe from `discontinued` — a demo unit off in a bag between events strands unclaimable (recovery today = force-reset, which bypasses wipe verification and carries participant A's on-device data forward).
- **Nothing disposes of the outgoing household**: release touches exactly two attributes; the prior Patient stays `active`, so the behavioral detector keeps firing `below_typical` at participant A daily after hand-off, and their login/history persist with no stated posture.

---

## 5. Scope — BUILD NOW (demo-functional + forward-compatible)

### 5.1 `claimBoundPhone` + `claimBoundPhoneMask` on the device registry
Sparse attributes on `gosteady-{env}-devices`:
- `claimBoundPhone` = `HMAC-SHA256(pepper, e164_phone)` (hash, not raw PII; keyed with a server-side pepper in Secrets Manager so the small phone space isn't trivially reversible). Absent = open self-claim.
- `claimBoundPhoneMask` = display form (last 4, e.g. `•••-1234`), **set and cleared together with the HMAC**. Required because the HMAC is irreversible by design (D3) — without a stored mask, neither the fleet row (§5.4) nor the confirmation screen (§5.5) has anything to render. Masked-tail exposure to a walkerId holder is an accepted tradeoff (D9).

### 5.2 Claim enforcement (`d2c-claim`) — four parts, in order
**(a) Phone plumbing (prerequisite, in scope).** Extend `_shared/api_authz.extract_claims` to surface `phone_number` and `phone_number_verified` from the JWT. Fix the dead `claims.get('raw',{})` reads at `d2c-claim/handler.py:149–151, :197` in the same change. Add an integration test asserting the phone actually flows through a real D2C token (L6 correction — do not trust the syntactic read).

**(b) Ownership gate (the invariant the whole rotation model assumes).** In `_claim`, after resolving the device: if `owningClientId` is present and ≠ the caller's household → **`409 DEVICE_OWNED`** (neutral client copy: "This walker isn't available. Contact support."), *regardless of status*. This makes `release` **mandatory by mechanism**, closes the split-brain path (§4 bullet 2), and turns D4's bind-409-on-owned from a trap into a tripwire. The same-household idempotent early-return (`handler.py:131`) short-circuits before this gate, unchanged.

**(c) Binding check.** If `device.claimBoundPhone` is set: require `phone_number` present **and** `phone_number_verified == 'true'` in claims — else **403** (fail closed). Then compute `HMAC(pepper, normalize_e164(claims["phone_number"]))` and compare. Mismatch → **`403 CLAIM_PHONE_MISMATCH`**. Externally, missing/unverified/mismatch all return the same neutral 403 (no oracle for whether a device is bound or to what); audit distinguishes internally. Match (or binding absent) → proceed.

**(d) Atomic clear + rollback restore.** The clear of `claimBoundPhone`/`claimBoundPhoneMask` **rides inside the step-1b conditional registry write** (atomic with the ownership snap) — not as a separate write. `_rollback_device_step1` is extended to **restore the pre-claim binding + mask** (pass the pre-claim values through), so a step-2/3 failure (e.g. a flaky IoT publish at the venue) cannot burn the binding and silently revert the device to open self-claim.

### 5.3 Operator setters: `bind` + atomic `release-and-bind`
- **`POST /api/v1/devices/{serial}/claim-binding { phone | null }`** — internal_admin + MFA, audited (`device.claim_bound` / `device.claim_binding_cleared`). Precondition: device **UNOWNED** (D4; if owned → 409). `phone: null` clears. This is the exact path the order pipeline will call later.
- **`POST /api/v1/devices/{serial}/release-and-bind { phone }`** — internal_admin + MFA, audited (emits `device.ownership_released` + `device.claim_bound`). **One conditional `update_item`**: `REMOVE owningClientId, owningFacilityId SET claimBoundPhone = :h, claimBoundPhoneMask = :m`, condition status ∈ {`ready_to_provision`, `discontinued`} and currently owned. **Why atomic:** v1's release-then-prompt-then-bind left the device unowned + unbound — open self-claim, the exact pilot-incident state — for the duration of the prompt, and *indefinitely* if the bind call failed. One write makes the window zero (D8). The phone is collected **before** any mutation (§5.4). A failed condition releases nothing.

### 5.4 Fleet screen (rotation UX) — models the async reality
On the `⋯` menu:
- **"Rotate to next participant…"** (owned, assigned) → dialog collects the next participant's phone **first** → chains `end-assignment` (fires wipe cmd; §5.8 discharges the outgoing Patient) → `release-and-bind` (atomic, legal immediately — release accepts `discontinued`). Row then shows **`wipe pending — claimable when device acks`** until the wipe-ack auto-recycle lands `ready_to_provision`, at which point it shows **`reserved for •••-1234`**.
- **"Rotate to next participant…"** (owned, idle/`ready_to_provision`) → same dialog, skips end-assignment; device is reserved + claimable immediately.
- **"Bind to participant…"** (already unowned) → set the phone (§5.3 bind).
- **Bare "Release"** (no re-bind) is demoted behind an explicit confirm: *"This device will become claimable by ANYONE with its QR."* — a bare release silently reopens the land-grab window (D2 single-use + nothing else enforces bind-after-release).
- Row states: `reserved •••-1234` / `wipe pending` / `open (unbound!)` — the operator can always see which devices are reserved for whom and which are claimable *now*.

### 5.5 Claim confirmation (guardrail — addresses the "silent re-claim")
The `/setup/{walkerId}` landing shows **"Set up this walker for {masked recipient}?"** + an explicit confirm before `POST /claim`, so a claim is never silent. **v2 re-estimate: this is new backend work, not a free screen** — v1's "(Backend already supports the masked hint)" was false for the state this targets: the public lookup returns a hint only for `status='claimed'` devices, and `ownerHint` is the wrong object anyway (the *claimer's* contact, set at claim time). Build: extend the public lookup with a **`reserved`** response for unowned + bound devices → `{ status: 'reserved', deviceType, recipientMask }` (from §5.1's stored mask). Unbound devices confirm without a mask ("Set up this walker?"). *Can ship a beat after 5.1–5.4 if needed; the §5.4 fleet states are the demo-critical visibility.*

### 5.6 Wipe re-issue (un-strand the rotation path)
Today the connection-coordinator **sweeps** an outstanding wipe cmd not acked within 24 h and nothing can re-issue a wipe from `discontinued` — a device offline >24 h between participants is permanently unclaimable (§4). Fix: on CONNECT of a device in `discontinued` with no live `outstandingWipeCmds` entry, the coordinator **re-issues the wipe** (re-publish + re-arm the ack conditional) instead of leaving it stranded. `force_reset` remains the audited fallback for devices that never connect — with the caveat **stated to the operator**: force-reset bypasses wipe verification, so the next participant receives a device still carrying the prior participant's on-device data.

### 5.7 Returning-participant dedupe (claim side)
`_claim` currently mints a new active Patient unconditionally (the idempotent early-return fires only while the *same device* is still owned by the caller's household) and `put_item`-overwrites the caller's RoleAssignments row. With a small pilot pool + 5 devices, participant reuse is the norm, not the edge. Fix: on claim, if the caller's household already has an **active** walker Patient → **reuse it** (no second active Patient; refresh the device linkage). Mint only when none is active. This also makes L1's wording precise: fresh `dtc_` for new users; returning users re-enter their own household with exactly one active Patient.

### 5.8 Household disposition on rotation (release side) — pilot posture
Rotation must not leave the outgoing household as a live, false-alerting tenant. As part of the §5.4 chained rotate action (at end-assignment): set the outgoing household's walker Patient to **`discharged`** (existing state; the discharge cascade no-ops on devices because the rotate flow has already ended the assignment). This removes the Patient from behavioral evaluation — killing the confirmed failure mode where `below_typical` fires at participant A daily after hand-off (zero activity vs. their positive 7-day median). **Pilot posture (D13):** participant keeps their login + read-only history; no data deletion; full household teardown / retention policy / a dedicated `monitoring_ended` state are deferred (§6, §10).

### 5.9 Facility-provision guard (binding is a reservation for ALL provision writers)
§5.2 guards only `d2c-claim`, but three writers snap ownership of `ready_to_provision` devices: `device-api._action_provision`, `patient-mgmt._provision_inline`, and d2c-claim's inline copy. The facility provision-by-serial path grabbing a D2C-staged device is a **recorded incident** (GS0000000001, ARCHITECTURE §16). Fix: `_action_provision` / `_provision_inline` refuse devices with `claimBoundPhone` set → **`409 DEVICE_RESERVED`**; internal_admin may override by explicitly clearing the binding first (audited). One conditional each; the invariant the real model needs anyway.

### 5.10 Cognito phone-attribute hardening (closes the no-possession bypass)
Confirmed bypass: the D2C pool leaves `phoneNumber` mutable with no write restriction, so any D2C account could self-service `UpdateUserAttributes` to the bound number — no SMS to the victim — and pass a naive HMAC check. **The fix is §5.2c's fail-closed `phone_number_verified == 'true'` requirement**: a self-service phone flip yields `phone_number_verified = false` (this pool has no verification path at all for attribute updates — `autoVerify` is off, no pool SMS sender), so every bound claim 403s — and the flip breaks the attacker's own phone-alias sign-in besides. The rejection is audited (`d2c.claim_rejected_phone_mismatch`, reason `phone_unverified`) for detection. *(Implementation notes, deploy-verified 2026-07-14: BOTH pool-level guards are unimplementable here — `writeAttributes` exclusion is invalid because required-at-signup attributes must be writable, and `keepOriginal`/AttributesRequireVerificationBeforeUpdate is invalid because it requires the attribute in AutoVerifiedAttributes, which this pool intentionally disables. The fail-closed verified check is the whole mechanism, and it is sufficient.)*

### 5.11 Demo rotation runbook (playbook deliverable, demo-critical)
One page in `docs/playbooks/` — cheaper than any code and the difference between a smooth demo and an on-stage debug session: per-rotation checklist (rotate → verify `wipe pending` clears to `reserved` → participant scans + claims → confirm `active_monitoring`), each failure mode with its recovery (typo'd phone → re-bind while unowned; participant no-show → binding has no TTL, clear or re-bind explicitly; device won't ack → §5.6 re-issue, then force-reset with the residue caveat; OTP undeliverable at venue → pre-demo Twilio check), and the pre-demo checklist (all 5 devices `reserved` for their intended participants **before** doors open — pre-staging the wipe-ack wait out of the live path).

---

## 6. Out of scope — DEFERRED (and how each stays forward-compatible)

| Deferred | Forward-compat note |
|---|---|
| Checkout / order / billing pipeline | When it lands it calls **the same** `set claimBoundPhone` path (§5.3) at fulfillment — the operator setter is the manual stand-in. |
| Pre-bound-Admin / caregiver-orders (the 70–80% path) | Also just sets `claimBoundPhone` at order time — this spec builds the mechanism it needs. Open: whose phone binds when buyer ≠ recipient (§10). |
| Self-serve consumer transfer (household-owner release) | Stays internal_admin/support today; a future household-owner-scoped transfer reuses §5.2–5.3 — including the **atomic** release-and-bind, which is exactly the primitive consumer transfer needs. |
| Retail / unknown-buyer land-grab hardening (WAF, rate-limit, one-time sticker secret) | Orthogonal: retail = `claimBoundPhone` null = open self-claim; add WAF later without touching this. |
| QR-render + label print pipeline; printed short-code fallback | Independent of binding. *(Reminder: qr-provisioning §5's pre-print lock list — short-code resolution + the walkerId→claimId rename — must resolve before any sticker is printed, including demo stickers.)* |
| Full household teardown / retention policy / `monitoring_ended` state | Pilot posture is §5.8 (discharge + retain + read-only login). Target-model shape lands with the canon pass (§10). |

---

## 7. Interfaces + data

- **Devices row:** `+ claimBoundPhone: string` (HMAC hex), `+ claimBoundPhoneMask: string` (last-4 display) — both sparse, set/cleared together.
- **`POST /devices/{serial}/claim-binding`** `{ "phone": "+1512..." | null }` → `{ device: { serialNumber, claimBoundPhone: "set"|"cleared" } }`. internal_admin + MFA. Precondition: unowned.
- **`POST /devices/{serial}/release-and-bind`** `{ "phone": "+1512..." }` → same shape. internal_admin + MFA. Single conditional `update_item` (see §5.3); 409 unless owned ∧ status ∈ {`ready_to_provision`, `discontinued`}.
- **`POST /claim`** unchanged shape; new failures: `403 CLAIM_PHONE_MISMATCH` (also returned for missing/unverified phone on a bound device — no oracle), `409 DEVICE_OWNED`.
- **`GET /api/v1/public/walkers/{walkerId}`** (the unauthenticated `/setup` landing lookup): new `reserved` state for unowned + bound devices → `{ status: "reserved", deviceType, recipientMask }`.
- **`extract_claims`** (`_shared/api_authz`): `+ phone_number`, `+ phone_number_verified`.
- **Cognito (d2c-auth-stack):** unchanged — both pool-level phone-update guards are invalid on this pool (§5.10); the claim handler's fail-closed verified check is the mechanism.
- **Provision writers** (`device-api._action_provision`, `patient-mgmt._provision_inline`): new precondition — `attribute_not_exists(claimBoundPhone)` → else `409 DEVICE_RESERVED`.
- **Connection-coordinator:** re-issue wipe on CONNECT for `discontinued` devices with a swept wipe entry (§5.6).
- **Audit:** `device.claim_bound` (subject: serial; extra: masked phone), `device.claim_binding_cleared`, `d2c.claim_rejected_phone_mismatch` (count-only, no raw phone; extra distinguishes mismatch vs unverified vs absent), `d2c.claim_rejected_device_owned`, `device.wipe_reissued`. (`device.ownership_released` already exists in code — the canon pass adds it to ARCHITECTURE §4's catalog, §10.)
- **Secret:** `gosteady/{env}/claim-binding-pepper` (Secrets Manager), read by `d2c-claim` + `device-api`.

## 8. Testing

| # | Scenario | Expected |
|---|----------|----------|
| T1 | Bind device to phone A; A claims | ✅ claim succeeds, binding + mask cleared atomically with ownership snap |
| T2 | Bind to A; **B** claims | ❌ `403 CLAIM_PHONE_MISMATCH` |
| T3 | Unbound, unowned device; anyone claims | ✅ open self-claim (unchanged) |
| T4 | Bind on an **owned** device | ❌ 409 (release first / use release-and-bind) |
| T5 | Rotation: rotate (owned by A → bind to B) → B claims → C blocked | ✅ end-to-end, A can no longer re-grab |
| T6 | Phone normalization (spaces / no `+` / country code) hashes equal | ✅ E.164-normalize before HMAC |
| T7 | Device `ready_to_provision` but **still owned by dtc_A**; B claims | ❌ `409 DEVICE_OWNED` — no split-brain (§5.2b) |
| T8 | A claims, rotates out, later A claims again (same or another device) | ✅ same household, **exactly one active Patient** (§5.7) |
| T9 | `release-and-bind`: no observable unowned+unbound intermediate; failed condition releases nothing | ✅ atomic (§5.3) |
| T10 | Mid-claim step-2/3 failure after step-1b write | ✅ rollback restores ownership **and** binding + mask (§5.2d) |
| T11 | Facility provision-by-serial of a **bound** unowned device | ❌ `409 DEVICE_RESERVED` (§5.9) |
| T12 | Bound device; caller JWT has missing or unverified `phone_number` | ❌ 403, fail closed (§5.2c) — incl. after a self-service `UpdateUserAttributes` phone flip |
| T13 | Device stuck `discontinued`, wipe cmd swept (>24 h offline); device reconnects | ✅ wipe re-issued → ack → `ready_to_provision` (§5.6) |
| T14 | Post-rotation: outgoing Patient discharged; next-day behavioral eval | ✅ no `below_typical` fires at the prior participant (§5.8) |

## 9. Decisions log

| # | Decision | Why |
|---|----------|-----|
| D1 | Build `claimBoundPhone` now, not a demo-only rotation hack | It's the real anti-land-grab defense (L5) + the on-plan manual-prebind interim; serves demo + product with one mechanism |
| D2 | Binding is **single-use** (cleared on successful claim) | A claimed device's future re-binding happens at the *next* release; avoids a stale binding blocking the current owner |
| D3 | HMAC-with-pepper, not raw phone or plain SHA-256 | Don't store raw PII; peppered keyed-hash resists brute-force over the small phone space |
| D4 | `bind` requires an **unowned** device | Mirrors fulfillment (binds fresh stock) + transfer (release→bind); binding an owned device is meaningless. *(Not violated by §5.3's `release-and-bind`: ownership removal and binding land in the same conditional write, so no owned+bound state ever exists.)* |
| D5 | Operator setter = same endpoint the order pipeline will call | Forward-compatibility is structural, not incidental |
| D6 | **Claim gates on ownership** (`409 DEVICE_OWNED`), not just status | The normal post-recycle state is ready + still-owned (L2); without the gate, a missed release = cross-household split-brain, and the binding can't cover that state (D4). Makes release mandatory-by-mechanism |
| D7 | Rotation = end-assignment → atomic release-and-bind → **wipe-ack** → claim; claimability gated on wipe-ack | Rotation is not hand-to-hand instant; the wait is real and the UX/runbook model it instead of hiding it. Force-reset residue is a stated tradeoff, not a silent default |
| D8 | `release-and-bind` is **one conditional write** | v1's release→prompt→bind left an unbounded open-self-claim window (the pilot-incident state); atomicity makes it zero |
| D9 | Store `claimBoundPhoneMask` alongside the HMAC | The HMAC is irreversible by design; fleet + confirmation UX need a display form. Masked-tail exposure to walkerId holders accepted |
| D10 | Binding clear rides in the step-1b conditional write; rollback restores it | A mid-claim failure must not burn the binding into open self-claim |
| D11 | Phone comes only from a **verified** JWT claim (`phone_number_verified == 'true'`, fail closed) — the sole and sufficient guard; both Cognito pool-level phone-update locks are invalid on this pool (§5.10) | Closes the confirmed self-service `UpdateUserAttributes` impersonation bypass — binding must prove phone *possession*, not phone *assertion*. (The D2C app sends the **ID token**, so the standard OIDC phone claims are natively present once `extract_claims` surfaces them.) |
| D12 | All provision writers honor the binding (`409 DEVICE_RESERVED`) | A reservation only one channel respects isn't a reservation (GS0000000001 precedent) |
| D13 | Pilot household disposition: discharge the outgoing Patient at rotation; retain data + read-only login | Stops the false-alert tail with an existing state + existing cascade semantics; teardown/retention deferred with the canon pass |

## 10. Open questions
- [ ] **Retail default:** should unbound devices stay open self-claim (current) or require WAF/rate-limit before GA? (Land-grab risk is real but retail-only; pilot units will all be bound.)
- [ ] **Binding TTL?** Should a set-but-unclaimed binding expire (e.g., 30 d) so returned stock doesn't stay reserved forever? (Lean: no TTL for pilot — the §5.11 runbook owns no-show cleanup; revisit with the order pipeline.)
- [ ] **Self-serve transfer** — when does household-owner-initiated release/transfer graduate out of "contact support"? (Post-pilot; reuses §5.2–5.3 incl. atomic release-and-bind.)
- [ ] **Buyer ≠ recipient** (caregiver-orders): whose phone binds at order time — the buyer's or the intended walker user's? (qr-provisioning §3 opt 3 says buyer; this spec's demo setter binds the recipient. Decide with the order pipeline.)
- [ ] **`monitoring_ended` Patient state** vs reusing `discharged` (§5.8 pilot posture) — decide with the household-teardown design.
- [ ] **Canon supersession pass (one sweep, tracked as its own doc task):** ARCHITECTURE §4 `dtc_{primaryUserId}` **and** §14 T3 `dtc_{userId}` **and** d2c.md §2/L1 **and** d2c-phase1-walker-activation L2 → supersede with the `householdId` anchor; add **release** as the third ownership-mutation class (DL4/DL9) + `device.ownership_released` and this spec's events to the §4 audit catalog; rescope DL5 "no pre-allocation" to the facility channel (binding IS a reservation); document the per-claim RoleAssignments/clientId rewrite that makes L1 work; update §6 Devices (walkerId, by-walker-id GSI, stale status enum, new binding fields) + §15 Lambda inventory (d2c-claim etc.).

## 11. Changelog
| Date | Change |
|---|---|
| 2026-07-13 | Initial spec — reframed demo rotation as the real "device changes hands" flow; scoped `claimBoundPhone` (build now: field + claim-enforcement + operator bind + fleet UX + confirm) as the forward-compatible slice of the deferred claim-binding design; deferred order pipeline / self-serve transfer / retail WAF with compat notes. |
| 2026-07-13 (v2) | Amended after full-repo adversarial analysis (30/30 critical+major findings confirmed against code). Added: claim-time **ownership gate** (§5.2b, D6); **wipe leg** of rotation owned — async wipe-ack modeled in UX + coordinator **re-issue** for swept wipes (§5.4, §5.6, D7); **atomic release-and-bind** (§5.3, D8); **phone plumbing** — corrected L6 (v1 premise was dead code), verified-phone fail-closed + Cognito `writeAttributes` hardening (§5.2a/c, §5.10, D11); **`claimBoundPhoneMask`** + public-lookup `reserved` state — §5.5 re-estimated (was "backend already supports": false) (§5.1, D9); atomic binding clear + rollback restore (§5.2d, D10); **returning-participant dedupe** (§5.7); **household disposition** — discharge outgoing Patient, kills the false-alert tail (§5.8, D13); **facility-provision guard** `DEVICE_RESERVED` (§5.9, D12); **demo rotation runbook** (§5.11). Tests T7–T14. Fixed stale qr-provisioning §2→§3 citations; expanded canon-supersession open item to all four stale anchor locations. |
| 2026-07-14 | **Built + deployed to dev.** New `_shared/claim_binding.py` (normalize/HMAC/mask/pepper); `extract_claims` surfaces `phone_number`(+`_verified`) (§5.2a); d2c-claim ownership gate + fail-closed binding check + atomic clear/rollback + `reserved` lookup + returning-user dedupe; device-api `claim-binding` + `release-and-bind` + `DEVICE_RESERVED` guard (device-api **and** patient-mgmt provision paths); coordinator wipe-reissue; Flutter `reserved`/`•••-1234` landing + fleet "Rotate to next participant" UX + `fleet.py bind/rotate`; CDK pepper secret + grants + routes. **§5.10 revised**: both Cognito pool-level phone-update guards are invalid on this pool (deploy-verified) — the fail-closed verified check in §5.2c is the whole mechanism and is sufficient. **Bug found + fixed by the dev E2E**: the connection-coordinator IAM role lacked `iot:UpdateThingShadow` (wipe-reissue's Shadow write) — added in processing-stack. Verified: 53 backend unit tests + 23/23 live-dev rotation E2E (synthetic-JWT lambda-invoke against real DynamoDB + pepper) + screenshot of the live `reserved` landing. Remaining: prod deploy; a real-Cognito-token E2E of the claim leg (dev E2E used synthetic authorizer claims); the canon-supersession doc pass (§10). |

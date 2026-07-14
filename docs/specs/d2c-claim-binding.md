# D2C claim-binding + ownership rotation (real-world model + demo slice)

> **Date:** 2026-07-13 | **Status:** 🟡 SPEC — scoping the build
> **Related:** [`d2c-qr-provisioning.md`](d2c-qr-provisioning.md) (the claim-binding *design*, §2 opt 3) · [`d2c-phone-only-signin.md`](d2c-phone-only-signin.md) (household_id anchor, §7) · [`d2c.md`](d2c.md) (D2C phases, §7 pre-bind) · [`device-fleet-ops-tooling.md`](device-fleet-ops-tooling.md) (the `release` primitive) · ARCHITECTURE §4 (D2C modeling, ownership invariants)
> **Surfaced by:** the live prod pilot — releasing `GS0002000001` and re-scanning its QR re-claimed it **with no verification** (existing session, no possession proof). That's the documented ["leaked-QR land-grab"](d2c-qr-provisioning.md) gap, made real by device rotation.

---

## 1. Overview + the reframe

The public **demo** rotates ~5 physical devices through pilot participants who never *purchased* them. That "rotation" is not a special case — **it is the real-world "device changes hands" flow, exercised repeatedly without the purchase step.** And the anti-land-grab defense the real product needs — **binding a device's claim to a specific phone** — is *also* what makes rotation land on the intended participant instead of whoever scans the QR first.

So there's one mechanism that serves both, and it's already the designed one:

> **Build `claimBoundPhone` now.** It's the real product's anti-land-grab defense (`d2c-qr-provisioning.md` opt 3), and building it for the demo throws nothing away — only the *setter* differs (operator now, order pipeline later), and operator pre-binding is **already the intended interim** (`d2c.md` §7: "the bootstrap endpoint is designed so ops can pre-bind manually").

**What this spec is NOT:** the checkout/order pipeline, self-serve consumer transfer, retail WAF, or the QR-label print pipeline — all remain deferred (§6), and the design here is forward-compatible with each.

---

## 2. Locked-In Requirements (already decided — do not re-litigate)

| # | Requirement | Source |
|---|-------------|--------|
| L1 | **Tenancy anchor is a stable `householdId`, not the Cognito sub** (`clientId = dtc_{householdId}`). This is what lets a device change households with **no data migration** — release + re-claim mints a fresh `dtc_`. | d2c-phone-only-signin §7 #3 (cut over, coord §C56.1) |
| L2 | **Ownership persists through reset**; end-assignment/recycle keep `owningClientId`. Un-claim is an **explicit** step. | ARCHITECTURE §Ownership invariants |
| L3 | **`release`** (internal_admin, audited) nulls `owningClientId`/`owningFacilityId` → device returns to the unowned pool + becomes QR-claimable. | device-fleet-ops-tooling / `device-api._action_release` |
| L4 | **QR encodes an opaque UUIDv4 `walkerId`**, never the serial; resolved server-side via the `by-walker-id` GSI. | d2c-qr-provisioning §4 |
| L5 | **Chosen claim model = opt 1 (opaque URL, baseline) + opt 3 (phone-binding for known recipients)**; retail/unknown-buyer falls back to open self-claim. Possession proof lives in **mutable cloud policy (the binding)**, never an immutable printed secret. | d2c-qr-provisioning §2 |
| L6 | The **phone-first D2C pool** makes `phone_number` a required + verified attribute; the claim handler already reads `phone_number` from the JWT. | d2c-auth-stack / `d2c-claim/handler.py:150,197` |

---

## 3. The real-world target model (what we're building toward)

The through-line is one field on the device registry — **`claimBoundPhone`** (a hash of the E.164 phone allowed to claim) — set by whoever knows the intended recipient, and enforced at claim time.

```
manufacture + enroll        walkerId minted, ready_to_provision, UNOWNED, claimBoundPhone = null
        │
        ▼
set intended recipient      claimBoundPhone = HMAC(recipient_phone)
  ├─ real: order/fulfillment pipeline sets it at checkout           (DEFERRED)
  ├─ real: known-buyer / caregiver-orders ("pre-bound Admin", 70–80%) (DEFERRED)
  └─ interim/demo: OPERATOR sets it at hand-off                     (BUILD NOW)
        │
        ▼
claim (scan QR → phone+OTP → POST /claim)
  ├─ claimBoundPhone set  → caller phone must hash-match, else 403 CLAIM_PHONE_MISMATCH
  └─ claimBoundPhone null → open self-claim (retail baseline; WAF/rate-limit DEFERRED)
        │
        ▼
household ownership         owningClientId = dtc_{householdId}; claimBoundPhone CLEARED on successful claim
        │
        ▼
device changes hands        release (un-claim) → re-bind to next recipient's phone → they claim
  ├─ real self-serve transfer (household-owner initiated)           (DEFERRED — "contact support" today)
  └─ interim/demo + support: operator release + bind                (BUILD NOW)
```

**Why this is the real model, not a demo scaffold:** the field, the claim-enforcement, and the release+bind flow are identical in the real product. The order pipeline, when it exists, just becomes another caller of the *same* "set `claimBoundPhone`" path. The demo's operator-set binding is the manual fulfillment stand-in the specs already anticipated.

---

## 4. Current state (built vs the gap)

**Built + proven in prod:** walkerId/QR mint, opaque public lookup, phone-first pool + SMS-OTP, `POST /claim` bootstrap→provision→activate (self-claim, no operator in loop — the DT-4 launch bar), and `release` (the un-claim primitive).

**The gap (this spec):**
- `claim` enforces **`require_authenticated` only** — no possession proof, no recipient binding. `claimBoundPhone` exists **nowhere in code** (spec-only). → any authenticated D2C user who scans the QR claims the device (the land-grab; what the pilot hit).
- Rotation via `release` returns the device to **open self-claim**, so nothing targets the *intended* next participant, and a prior owner with a live session can re-grab it.

---

## 5. Scope — BUILD NOW (demo-functional + forward-compatible)

### 5.1 `claimBoundPhone` on the device registry
Sparse attribute on `gosteady-{env}-devices`: `claimBoundPhone` = `HMAC-SHA256(pepper, e164_phone)` (hash, not raw PII; keyed with a server-side pepper in Secrets Manager so the small phone space isn't trivially reversible). Absent = open self-claim.

### 5.2 Claim enforcement (`d2c-claim`)
In `_claim`, after resolving the device and before the ownership snap: if `device.claimBoundPhone` is set, compute `HMAC(pepper, normalize_e164(claims["phone_number"]))` and compare. Mismatch → **`403 CLAIM_PHONE_MISMATCH`** (neutral message, no leak of the bound number). Match (or absent) → proceed. **Clear `claimBoundPhone` on successful claim** (single-use — the binding is consumed).

### 5.3 Operator "bind" primitive (the interim setter)
`POST /api/v1/devices/{serial}/claim-binding { phone }` — internal_admin, audited (`device.claim_bound` / `device.claim_binding_cleared`). Precondition: device **UNOWNED** (bind an unclaimed device to its intended claimer; if owned → 409, release first). `phone: null` clears it. This is the exact path the order pipeline will call later.

### 5.4 Fleet screen (rotation UX)
On the `⋯` menu, replace the raw "Release" with rotation-aware options:
- **"Release + bind to next participant…"** (owned, assigned/idle) → release, then prompt for the next participant's phone → bind. Now only that phone can claim.
- **"Bind to participant…"** (already unowned) → set the phone.
- Show a **masked bound phone** (`•••-1234`) in the row when set, so the operator sees which devices are reserved for whom.

### 5.5 Claim confirmation (light guardrail — addresses the "silent re-claim")
The `/setup/{walkerId}` landing shows **"Set up this walker for {masked recipient}?"** + an explicit confirm before `POST /claim`, so a claim is never silent. (Backend already supports the masked hint.) *Can ship a beat after 5.1–5.4 if needed.*

---

## 6. Out of scope — DEFERRED (and how each stays forward-compatible)

| Deferred | Forward-compat note |
|---|---|
| Checkout / order / billing pipeline | When it lands it calls **the same** `set claimBoundPhone` path (§5.3) at fulfillment — the operator setter is the manual stand-in. |
| Pre-bound-Admin / caregiver-orders (the 70–80% path) | Also just sets `claimBoundPhone` at order time — this spec builds the mechanism it needs. |
| Self-serve consumer transfer (household-owner release) | Stays internal_admin/support today; a future household-owner-scoped `release`+`bind` reuses §5.2–5.3. |
| Retail / unknown-buyer land-grab hardening (WAF, rate-limit, one-time sticker secret) | Orthogonal: retail = `claimBoundPhone` null = open self-claim; add WAF later without touching this. |
| QR-render + label print pipeline; printed short-code fallback | Independent of binding. |

---

## 7. Interfaces + data

- **Devices row:** `+ claimBoundPhone: string` (HMAC hex), sparse.
- **`POST /devices/{serial}/claim-binding`** `{ "phone": "+1512..." | null }` → `{ device: { serialNumber, claimBoundPhone: "set"|"cleared" } }`. internal_admin + MFA.
- **`POST /claim`** unchanged shape; new failure `403 CLAIM_PHONE_MISMATCH`.
- **Audit:** `device.claim_bound` (subject: serial; extra: masked phone), `device.claim_binding_cleared`, and `d2c.claim_rejected_phone_mismatch` (count-only, no raw phone).
- **Secret:** `gosteady/{env}/claim-binding-pepper` (Secrets Manager), read by `d2c-claim` + `device-api`.

## 8. Testing

| # | Scenario | Expected |
|---|----------|----------|
| T1 | Bind device to phone A; A claims | ✅ claim succeeds, `claimBoundPhone` cleared |
| T2 | Bind to A; **B** claims | ❌ `403 CLAIM_PHONE_MISMATCH` |
| T3 | Unbound device; anyone claims | ✅ open self-claim (unchanged) |
| T4 | Bind on an **owned** device | ❌ 409 (release first) |
| T5 | Rotation: release (owned by A) → bind to B → B claims → C blocked | ✅ end-to-end, A can no longer re-grab |
| T6 | Phone normalization (spaces / no `+` / country code) hashes equal | ✅ E.164-normalize before HMAC |

## 9. Decisions log

| # | Decision | Why |
|---|----------|-----|
| D1 | Build `claimBoundPhone` now, not a demo-only rotation hack | It's the real anti-land-grab defense (L5) + the on-plan manual-prebind interim; serves demo + product with one mechanism |
| D2 | Binding is **single-use** (cleared on successful claim) | A claimed device's future re-binding happens at the *next* release; avoids a stale binding blocking the current owner |
| D3 | HMAC-with-pepper, not raw phone or plain SHA-256 | Don't store raw PII; peppered keyed-hash resists brute-force over the small phone space |
| D4 | `bind` requires an **unowned** device | Mirrors fulfillment (binds fresh stock) + transfer (release→bind); binding an owned device is meaningless |
| D5 | Operator setter = same endpoint the order pipeline will call | Forward-compatibility is structural, not incidental |

## 10. Open questions
- [ ] **Retail default:** should unbound devices stay open self-claim (current) or require WAF/rate-limit before GA? (Land-grab risk is real but retail-only; pilot units will all be bound.)
- [ ] **Binding TTL?** Should a set-but-unclaimed binding expire (e.g., 30 d) so returned stock doesn't stay reserved forever? (Lean: no TTL for pilot; revisit with the order pipeline.)
- [ ] **Self-serve transfer** — when does household-owner-initiated release/transfer graduate out of "contact support"? (Post-pilot; reuses §5.2–5.3.)
- [ ] Stale spec cleanup: ARCHITECTURE §4 still says `clientId: dtc_{primaryUserId}` — supersede with the `householdId` anchor.

## 11. Changelog
| Date | Change |
|---|---|
| 2026-07-13 | Initial spec — reframed demo rotation as the real "device changes hands" flow; scoped `claimBoundPhone` (build now: field + claim-enforcement + operator bind + fleet UX + confirm) as the forward-compatible slice of the deferred claim-binding design; deferred order pipeline / self-serve transfer / retail WAF with compat notes. |

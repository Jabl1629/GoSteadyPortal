# D2C QR / device-ID provisioning — design + recommendation

> **Date:** 2026-07-08 (updated 2026-07-12) | **Status:** 🟡 PARTIALLY IMPLEMENTED — the load-bearing **walkerId mint moved into `internal_admin` bulk-create** (§4.2), now used by prod bring-up (coord §C58, portal `783f7fe`). Still deferred: printed short-code fallback + claim-binding (§2 #2/#3), the QR-render batch + label pipeline. Decides what each rollator's QR encodes and how labels are minted + married to units at manufacturing.
> **Related:** [`d2c.md`](d2c.md) L6 (opaque walkerId) · [`d2c-phase1-walker-activation.md`](d2c-phase1-walker-activation.md) §2/§4/§5 · [`d2c-phone-only-signin.md`](d2c-phone-only-signin.md) §7 (caregiver bind) · coord §C56.3

## 1. How it works today (keep the encoding)

The QR encodes an **opaque, random UUIDv4 `walkerId`** in a `/setup/{id}` URL — **never the sequential `GS##########` serial**. Scan → unauthenticated public-lookup resolves `walkerId → device` via the sparse **`by-walker-id` GSI** (serial stays server-side, never exposed; unknown id → neutral `{status:unknown}`, not 404) → phone-first sign-up → `POST /claim` (ownership snap on `status=ready_to_provision`, race-safe + idempotent). Proven end-to-end (GS0001000043 claimed 2026-07-08). **The encoded shape is correct — the gaps are the pipeline + two holes.**

## 2. The gaps (what's missing for a physical fleet)

1. ~~**No minting pipeline.**~~ **✅ DONE (coord §C58, `783f7fe`):** `internal_admin` bulk-create (`device-api/handler.py::_action_admin_create`) now CSPRNG-mints an opaque UUIDv4 `walkerId` per device into the sparse `by-walker-id` GSI (audited; returned as `devices:[{serialNumber,walkerId}]`; idempotent via the serial-level conditional put). `tools/bringup-prod-unit.sh` calls it (Option-A synthetic invoke) + renders the QR. Still open: the **short-code** (#2) + a batch QR-render/label step (§4).
2. **No typed fallback code.** The shipped UI already says "check the code on your sticker" (`d2c_live_screens.dart:252`) — but no `shortCode` field exists in any schema. A scuffed QR on a curved frame + an older adult's old phone dead-ends.
3. **Leaked-QR land-grab.** Claim has no possession proof beyond URL + phone, so a photographed sticker can be claimed by anyone before the buyer (WAF/rate-limit deferred).

## 3. Options

| # | QR encodes | Verdict |
|---|---|---|
| 1 | Opaque UUID in a full HTTPS `/setup` URL (today, formalized) | **Baseline — keep.** Strong enumeration/PII posture; one-tap scan. |
| 2 | Opt 1 + a one-time secret on the sticker (`#k=…`) | Retail/shelf only. A printed secret can't be rotated; fragile through the OTP round-trip. |
| 3 | **Same printed string**, claim **bound to the buyer's phone** at order time (registry policy) | **Adopt for ordered devices.** Mutable/correctable defense vs land-grab; = the caregiver-orders flow (§C56/d2c-phone-only-signin §7). |
| 4 | Raw UUID, no URL | **Reject** — no native app; a bare id dead-ends the first scan. |
| 5 | Rename-proof: `…/s?d={uuid}` on a stable path | **Optional insurance** — a `/setup`→`/claim` rename can't orphan printed stickers. |

## 4. Recommendation — compose 1 + 3 + a real pipeline

**Encode** a plain HTTPS deep-link with a **server-minted UUIDv4**: `https://app.gosteady.co/setup/{uuid}` (no signature — 122-bit entropy already defeats enumeration). **Plus:**
1. **Printed human short-code** beside the QR (Crockford-base32 + check digit) as the typed fallback → resolved by a second sparse GSI.
2. **Move minting into `internal_admin` bulk-create** — CSPRNG-mint `walkerId` + short-code, conditional-put for uniqueness, return `{serial, walkerId, shortCode, setupURL}`; a batch step renders the QR PNG (error-correction **H** for curved/scuffed durability) and binds each label to its **serial** (the anchor — baked into firmware).
3. **Claim-binding for known-buyer orders** — hashed `claimBoundPhone` set at fulfillment; claim enforces the caller's phone matches, else 403. Unknown-buyer/retail units fall back to open self-claim.

Possession proof lives in **mutable cloud policy** (binding), never an immutable printed secret/signature.

## 5. Lock before ANY sticker is printed (immutable once glued)

- **Host** → `https://app.gosteady.co/…` (prod). Do **not** print until `app.gosteady.co`'s cert/DNS resolve live. Never the dev/`#hash` form.
- **Route name** → decide `/setup` vs `/claim`; consider printing `/s?d={id}` for rename immunity. Resolve the open **`walkerId→claimId`** rename (rename API/route/frontend, **keep the physical GSI name**).
- **ID format** → UUIDv4, opaque, **never reused** across units (decommission/recycle can't collide the sparse GSI).
- **Build** the fallback-code resolution + a QR-render step (no QR-gen library is in the repo yet).

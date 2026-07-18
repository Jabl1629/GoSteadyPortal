# D2C — Direct-to-Consumer Household Product (umbrella spec)

> **Status:** Draft — 2026-05-28 · **status refreshed 2026-07-17.**
> **⚠️ Currency note (2026-07-17):** the phased plan below was authored
> 2026-05-28 and its `🔲` markers lag reality. What has actually shipped:
> **Phase 1** (walker/rollator claim + activation + dashboard) — live dev +
> prod. **Twilio SMS is LIVE in dev + prod** (secrets populated, toll-free
> `+1833…` sender): SMS-OTP sign-in and Care Circle **invite SMS** both
> proven on real phones (invite E2E 2026-07-17). So the Phase-2 line-item
> "Twilio account + secret" is **done** — Twilio was pulled forward into
> Phase 1 / DT-4 and approved 2026-07-06 (see
> [phase-dt4-d2c-launch-readiness.md](phase-dt4-d2c-launch-readiness.md)).
> What remains in "Phase 2" is only the **alert→SMS dispatch pipeline** +
> per-user notification prefs (the notification-stack scaffold), NOT the
> Twilio setup. **Phase 5 (Care Circle) 5a+5d shipped dev+prod 2026-07-17**
> ([d2c-care-circle.md](d2c-care-circle.md)). Only open Twilio item is a
> **10DLC/long-code** registration *if* we move off the toll-free sender —
> it does **not** block sending today (§7).
> **Scope:** The consumer (household / Care Circle) product: account model,
> onboarding, walker-user monitoring, SMS notifications, device recycle,
> and the multi-member Care Circle. Maps to the historical `2B-D2C` slot
> in [ARCHITECTURE.md](ARCHITECTURE.md) §12 but is topic-named (findable
> by "d2c", not phase number).
> **Depends on (already deployed):** 0A-rev auth, 0B-rev data, 1A/1B
> ingestion+processing, 1C-slim behavioral alerts, 1.7 audit, 2A-0
> foundation, 2A-DL device lifecycle, 2A-RD reads, 2A-AA alert actions,
> 2A-UM-P patient mgmt.
> **Sub-specs:** [d2c-phase1-walker-activation.md](d2c-phase1-walker-activation.md)
> (others written as each phase is approached)
> **Mockups:** navigable hub at
> `https://jabl1629.github.io/GoSteadyPortal/#/d2c/preview`
> **Public demo:** dashboard-first mock app at https://gosteady.co/userdemo/
> ([d2c-userdemo.md](d2c-userdemo.md) — consumer counterpart of the facility demo)
> **Decisions log:** [d2c-mockup-followups.md](d2c-mockup-followups.md)

---

## 1. Context

GoSteady's direct-to-consumer channel: a family buys a walker cap retail
for an at-home elderly walker user. Because the cap is fully autonomous
over LTE-M, the app is a **read-only view** of the data — nothing a person
taps changes device behavior. That collapses the "walker user vs.
caregiver" distinction into one role plus two flags (see §2).

This umbrella defines the account model + the **phased delivery plan**
(§5). The plan is deliberately walker-user-first and single-device: prove
the entire stack on one real Thingy:91 X with one real phone number before
adding any Care Circle complexity. The payoff is that most of the backend
the early phases need is **already deployed** — D2C is mostly a new auth
pool, a bootstrap endpoint, an SMS pipeline, and Flutter wiring on top of
the existing telemetry + device-lifecycle infrastructure (§4).

---

## 2. Account model

Source: `~/Documents/gosteady_onboarding.pdf` (Account Model & Onboarding).

| Concept | Definition |
|---|---|
| **Member** | Anyone with access to a walker's data. Can view data, set their own notification prefs, see alerts. |
| **Admin** (flag) | Gates billing, subscription, inviting/removing Members, and device transfer. Multiple Admins allowed ("hit by a bus"). Default Admin = whoever set up the device. |
| **Walker user** (property) | Marks the Member who is the person using the walker. Drives copy ("your activity" vs "Mom's") and notification defaults. **May never create an account at all.** |
| **Care Circle** | The set of Members for one walker. |

- **L1 — Reuse the existing role machinery, relabel in UI.** D2C maps onto
  the deployed tenancy model: each household is a synthetic
  `dtc_{householdId}` client (anchored on a stable householdId, not the
  Cognito sub — superseded 2026-07-08, coord §C56.1; ARCHITECTURE §4 D2C
  modeling). `Admin` =
  the existing `household_owner` role (UI label "Admin"); plain Member =
  `family_viewer` (UI label "Member"). **Relax** the implicit one-
  `household_owner`-per-client rule to allow N Admins. Add one boolean
  attribute `isWalkerUser` on `RoleAssignments`. No new role enum.
- **L2 — Walker user without an account is first-class.** `Patients.cognitoUserId`
  is already optional. The walker user becomes a Member iff they sign up;
  otherwise they're a Patient row with no linked user. Care Circle UI
  sources the walker's name from `Patient.displayName`.
- **L3 — Care Circle is a derived view, not a table.** It's
  `RoleAssignments WHERE clientId = dtc_*`. V1: 1 household = 1 Patient =
  1 Care Circle.
- **L4 — Walker-user-is-also-Admin is the Phase-1 default.** A solo walker
  user who sets up their own device is both Admin + Walker-user of their
  own `dtc_` household. Care Circle has one Member.

Full locked decisions (notifications, transfer, QR security, etc.) live in
[d2c-mockup-followups.md](d2c-mockup-followups.md) "Decisions (locked)".

---

## 3. Tech-stack posture (pilot mode)

Decided across the design sessions; recorded here as the operative posture
for the whole D2C build:

| Area | V1 choice |
|---|---|
| Frontend | Flutter **Web / PWA** only — no native app yet |
| Notifications | **SMS (Twilio) + email (SES)**, no push. SMS primary. |
| Identity | **Email** is the identifier; **phone** is the alert channel |
| Auth UX | **SMS-OTP** sign-in + magic-link for invite/claim; no passwords |
| Cognito | **Separate D2C User Pool** (clean HIPAA/scoping boundary from facility tier; see §6) |
| Checkout / billing | **Deferred** — ops bootstraps via internal endpoint; no Stripe yet |
| QR | Generated + stickered **in-house**; encodes an **opaque** walker ID |
| Support | Ad-hoc (Slack + CLI) |
| Privacy | Facility-grade audit + customer-visible `GET /me/audit`; manual deletion on cancel |

---

## 4. Architecture: reuse vs. new

The elegance of the phased plan is how much already exists. **Bold = new
build for D2C; everything else is deployed.**

| Capability | Status | Used by phase |
|---|---|---|
| Device state machine + activation (provision → activate cmd → heartbeat ack) | ✅ 2A-DL | 1, 4 |
| Telemetry ingestion + processing (activity / heartbeat / threshold) | ✅ 1A/1B | 1, 4 |
| Behavioral alerts (no-activity, declining, offline, etc.) | ✅ 1C-slim | 2 |
| Patient reads (`/me/patients`, `/patients/{id}`, activity, alerts) | ✅ 2A-RD | 1, 4 |
| Wipe-ack-driven recycle (end-assignment → wipe cmd → firmware ack → `ready_to_provision`) | ✅ 2A-DL + firmware | 3, 4 |
| Audit pipeline | ✅ 1.7 | all |
| Tenancy / authz helpers | ✅ 2A-0 | all |
| **D2C Cognito pool + SMS-OTP custom-auth + magic-link claim** | 🔲 new | 1 |
| **Household/patient bootstrap + self-serve claim endpoint** | 🔲 new | 1 |
| **Multi-issuer JWT authorizer (accept D2C-pool tokens)** | 🔲 new | 1 |
| **D2C Flutter portal wired to live data (dashboard already mocked)** | 🔲 new | 1 |
| **Twilio account + `gosteady/{env}/twilio` secret** | ✅ live dev+prod (OTP + Care Circle invites) | 1 / DT-4 |
| **SMS-dispatch Lambda (alert → SMS) + notification prefs** | 🔲 new | 2 |
| **Notification-preferences storage + endpoints** | 🔲 new | 2 |
| **D2C deactivate/return-device UI affordance** | 🔲 new | 3 |
| **Care Circle: invites, member mgmt, member view (5a+5d)** | ✅ shipped dev+prod 2026-07-17 ([`d2c-care-circle.md`](d2c-care-circle.md)); 5b access-requests + 5c member SMS still 🔲 | 5 |

> **Firmware impact: none through Phase 4.** Activation, heartbeat ack, and
> wipe-ack recycle all use contracts already shipped (ARCHITECTURE §4, §7;
> firmware coord §C18/§C19 activation, aa-battery-recycle memo for wipe).
> Phases 1–4 are cloud + portal only. A firmware-coord note is filed at
> Phase 1 + Phase 3 confirming the real-hardware validations, but no
> firmware change is requested.

---

## 5. Phased delivery plan

Five phases. Each ends with a **real-hardware exit test** on the same
physical device, carried forward. The ordering proves the core monitoring
loop first and defers the Care Circle (the most complex, least-proven
surface) to last.

### Phase 1 — Walker-user claim + activation + monitoring 🔲
**Goal:** A new walker user can claim a brand-new device and see their own
walking activity. Proves auth + bootstrap + activation + ingestion + reads
+ portal end-to-end on real hardware.

**New build:**
- `GoSteady-{Env}-D2C-Auth`: separate Cognito pool, D2C app client, SMS-OTP
  custom-auth Lambdas (DefineAuth/CreateAuth/VerifyAuth), Pre-Token Lambda
  (emits `clientId=dtc_*`, `role=household_owner`, `isWalkerUser=true`).
- Multi-issuer authorizer: accept JWTs from the D2C pool alongside the
  facility pool (verify by `iss`, cache both JWKS).
- Claim/bootstrap endpoint: on first walker-user signup via the QR/`/setup`
  link, atomically create the `dtc_` household (Organizations) + Patient
  (`isWalkerUser`, this user as Admin) + `RoleAssignments` row, then
  provision the device to that patient (reuses 2A-DL provision → `activate`
  cmd). Ops pre-registers the device in Device Registry first (existing
  2A-DL admin bulk-create).
- D2C Flutter build wired to live data: sign-up / SMS-OTP / dashboard
  (already mocked in `lib/d2c/`) against the new auth + 2A-RD reads.

**Reused:** device activation, ingestion/processing, 2A-RD reads, audit.

**Exit test (real hardware):** register a real Thingy:91 X → walker user
signs up with a real phone → device powers on, auto-activates, checks in →
walk around → steps + today's activity render in the D2C portal within the
expected window. Closes firmware's `reported.activated_at` loop for a D2C
account for the first time.

**Sub-spec:** [d2c-phase1-walker-activation.md](d2c-phase1-walker-activation.md)

### Phase 2 — SMS notifications (walker-user focus) 🔲
**Goal:** The same walker user receives useful SMS alerts from the live
device.

> **Note (2026-07-17):** the Twilio *foundation* below is already live —
> the account + `gosteady/{env}/twilio` secret are populated in dev + prod
> and proven end-to-end for SMS-OTP + Care Circle invites (`_shared/sms.py`
> is the shared sender). What is genuinely unbuilt is the **alert→SMS
> dispatch pipeline** (subscribe to alert writes → route to SMS) + the
> per-user notification-preferences storage. So this phase is now
> "wire alerts to the existing SMS sender," not "stand up Twilio."

**New build:**
- SMS-dispatch Lambda routing alert writes → the **already-live** Twilio
  sender (`_shared/sms.py`); STOP-keyword handling; TCPA opt-in audit.
  (Twilio account + `gosteady/{env}/twilio` secret already done — DT-4.)
- Notification-preferences storage (`Users.notificationPrefs` as the
  `{alertType × channel}` matrix from the mockup) + `GET/PATCH
  /me/notification-prefs`.
- Alert → SMS routing: subscribe the dispatcher to the existing alert
  writes (1C-slim behavioral + 1B threshold) for this patient; respect
  prefs + the walker-user default that suppresses self-directed "you
  haven't moved" pings.

**Walker-user-appropriate alerts to test:** low battery ("replace your
batteries"), device offline. These are simulable on the real device
(drain/swap AAs, power off) — so the SMS pipeline is provable without a
caregiver.

**Exit test (real hardware):** trigger low-battery / offline on the live
device → walker user's phone receives the SMS within target latency →
reply STOP suppresses; re-opt-in restores.

### Phase 3 — Deactivation + reset 🔲
**Goal:** The walker user (or ops) can deactivate/return the device and it
fully resets, ready for a new owner.

**New build:** D2C-facing "deactivate / return device" affordance + copy
(device settings already mocked). Wires the existing 2A-DL end-assignment
→ `wipe` cmd path.

**Reused:** the entire wipe-ack-driven recycle (end-assignment fires wipe
cmd → firmware wipes local data + acks via Shadow `reported.wipe_complete`
+ heartbeat `last_cmd_id` → cloud auto-transitions `discontinued →
ready_to_provision` on ack + battery floor). Per aa-battery-recycle memo.

**Exit test (real hardware):** deactivate the live device → firmware wipes
+ acks → device returns to `ready_to_provision` → confirm prior account's
data is detached and the device is claimable again. Files a firmware-coord
note confirming the wipe-ack recycle on real hardware (first D2C exercise).

### Phase 4 — End-to-end with a NEW user on the reset device 🔲
**Goal:** Prove the recycle worked + data isolation holds across owners.

**New build:** none expected — this is a validation phase exercising
Phases 1 + 3 back-to-back.

**Exit test (real hardware):** a *different* walker user claims the
just-reset physical device → fresh activation → monitoring works → the new
user sees only their own data; the previous owner retains their historical
data but no access to the device. Confirms ownership reassignment + tenant
isolation on one physical unit.

### Phase 5 — Caregivers (Care Circle), phased 🟢 (5a+5d shipped; 5b+5c deferred)
**Goal:** Add multi-member functionality. Sub-phased because it's the
largest, least-proven surface.

> **2026-07-14 — detail superseded by [`d2c-care-circle.md`](d2c-care-circle.md)**
> (design locked). Invites are **phone-first SMS** with a verified-phone
> HMAC match at accept — the email/magic-link sketch in 5a below predates
> the phone-first pool cutover (coord §C56; SMS-OTP is the sole auth
> factor, so email cannot onboard anyone). **2026-07-17: 5a + 5d shipped
> dev + prod; operator live-phone E2E passed** (invite SMS → join →
> member dashboard). 5b (QR access-requests) + 5c (member SMS alerts,
> rides the Phase-2 pipeline) remain deferred.

- **5a — Invite + claim (caregiver).** Admin invites by name+email; magic-
  link claim; caregiver joins as Member. New: invites table +
  `POST /walkers/{id}/invites` + `POST /claim/{token}` + Care Team UI
  (mocked).
- **5b — QR request-access + approval.** Walk-up QR → request with required
  note → Admin approve/deny. New: `AccessRequests` table + endpoints +
  approval UI.
- **5c — Caregiver notifications.** Extend Phase-2 SMS pipeline to caregiver
  Members + the caregiver-directed alert set (no-activity, possible fall).
- **5d — Admin management.** Promote/demote (last-Admin guard), remove
  Member, transfer (contact-support copy in V1).

**Exit test:** full Care Circle on the real device — caregiver invited,
joins, gets alerts about the walker; walk-up request approved; admin
controls enforced.

---

## 6. Cross-cutting decisions

- **L5 — Separate D2C Cognito pool.** Not HIPAA-required (Cognito is HIPAA-
  eligible under a BAA), but a clean scoping boundary: D2C is not a HIPAA
  Covered-Entity relationship, the facility tier (eventually) is. Separate
  pools let D2C use SMS-OTP + softer password rules without touching
  facility-staff auth, and keep "where PHI lives" structural for any future
  audit. Shared `Users` + `RoleAssignments` tables stay shared (tenancy
  boundary is `clientId`, not pool; Cognito `sub`s won't collide). Easy to
  start separate, catastrophic to split later.
- **L6 — Opaque walker ID in QR/`/setup` URLs.** `portal.gosteady.co/setup/{walkerId}`
  where `walkerId` is random + non-sequential, **not** the printed
  `GS##########` serial (which is enumerable). Access still needs admin
  approval, so the URL itself leaks nothing.
- **L7 — Single SMS-OTP auth path.** New users sign up (enter phone) → SMS
  code to that number; returning users sign in by email → SMS code to phone
  on file. No email-OTP branch.
- **L8 — Domains.** `gosteady.co` = marketing (stays separate);
  `portal.gosteady.co` = the app. Same Flutter brand; copy varies by role
  at runtime (no third build mode).

---

## 7. Open items / risks

- **Pre-bound-Admin (GrandPad) flow** (70–80% of eventual customers) is
  **not** in Phases 1–4 — those test the walk-up/self-claim path. Pre-bind
  via an order pipeline is folded in once a checkout channel is chosen
  (deferred). The bootstrap endpoint is designed so ops can pre-bind
  manually in the meantime.
- **Twilio SMS: LIVE** (dev + prod) on a **toll-free** sender (`+1833…`) —
  SMS-OTP + Care Circle invites proven on real phones (Twilio approved
  2026-07-06). The only open item is a **10DLC campaign registration**,
  and only *if* we move to a standard 10-digit **long-code** sender;
  toll-free (which uses toll-free verification, not 10DLC) carries
  transactional OTP + invites at pilot scale today, so this is a
  GA-throughput decision, **not** a blocker. Revisit with the Phase-2
  alert→SMS pipeline. (`d2c-care-circle.md` §10 tracks the GA review.)
- **Care-note privacy nuance** (walker user sees notes written about them) —
  acceptable for V1; revisit if a "private note" need appears.
- **SES sender reputation** — verify `gosteady.co` DKIM/SPF/DMARC before
  Phase 2 email.

---

## 8. Changelog

- **2026-05-28** — Initial draft. Account model, pilot-mode posture,
  reuse-vs-new map, 5-phase delivery plan (walker-first, real-hardware exit
  tests), cross-cutting decisions. Authored alongside the navigable Flutter
  mockups in `lib/d2c/`.

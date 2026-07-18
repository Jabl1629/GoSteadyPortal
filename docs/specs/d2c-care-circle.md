# D2C Care Circle — phone-first invites, membership, and the member view

> **Date:** 2026-07-14 | **Status:** 🟢 SHIPPED (dev + prod) — dev 2026-07-14 with **26/26 synthetic-JWT E2E PASS** (`infra/scripts/e2e-care-circle.py`) + 50/50 unit; **operator live-phone E2E passed fully 2026-07-17** (real invite SMS → `/join` → SMS-OTP signup → member dashboard on a second phone, from the operator's household — which the same day became a *real* household: physical rollator `GS9999999981` rotated in via the claim-binding rotate flow, first **rollator** wipe-ack recycle proven live); **prod deployed 2026-07-17** (Prod-Auth + Prod-D2C-Auth + Prod-Api + `app.gosteady.co`). Supersedes the email/magic-link invite sketch in [`d2c.md`](d2c.md) §5 Phase 5a.
> **Related:** [`d2c.md`](d2c.md) §2 account model + §5 Phase 5 · [`d2c-phone-only-signin.md`](d2c-phone-only-signin.md) §6–7 (the "only a claim/invite writer is missing" gap) · [`d2c-claim-binding.md`](d2c-claim-binding.md) (pepper/HMAC + fail-closed verified-phone pattern, D11) · ARCHITECTURE §4 (D2C modeling; A5/T2 one-client boundary) · coord §C56 (phone-first pool)
> **Scope decisions locked with product owner 2026-07-14** (see §3). Core roster + member view only; member SMS (5c), QR access-requests (5b), multi-household, and facility-channel family viewers all deferred with forward-compat notes (§6).

---

## 1. Overview

The Care Circle is the D2C sharing surface: a household Admin (`household_owner`)
invites family members / caregivers, who join the household as Members
(`family_viewer`) and get a read view of the walker user's activity, alerts,
and device health — plus the ability to acknowledge alerts.

The substrate is already deployed. `family_viewer` + `linkedPatientIds`
enforcement (`_shared/api_authz.py`), the pre-token `family_viewer` branch
(`d2c-pre-token` reads the RoleAssignments row on every mint), the
`by-client-role` GSI (projection ALL — the roster is one query), and
per-request DDB authz (revoke is effective on the member's next API call, no
token staleness). What does not exist: **an invite/membership writer, a roster
read endpoint, and the UI wiring** — `d2c_care_team_screen.dart` is 100% mock.

The invite mechanism is the same possession-proof idea that shipped for
device claims: the SMS link is a *pointer*, never a credential; authorization
comes from the signed-in caller's **verified phone number** HMAC-matching the
invite (fail-closed, exactly claim-binding D11). A forwarded link grants
nothing.

## 2. Locked-In Requirements (inherited canon — do not re-litigate)

| # | Requirement | Source |
|---|-------------|--------|
| L1 | Household = synthetic client `dtc_{householdId}` (stable anchor); Admin = `household_owner`, Member = `family_viewer`, `isWalkerUser` flag on the row. No new role enum. | ARCHITECTURE §4 + d2c.md L1 |
| L2 | **One client per customer user** (A5/T2 hard boundary): RoleAssignments PK=`userId` (one row), single `custom:clientId` JWT. V1 keeps this; membership conflicts are guarded, not silently overwritten (§4, §5.3, §5.6). | ARCHITECTURE §4/§14 |
| L3 | Care Circle is a **derived view over RoleAssignments** (`by-client-role` GSI), not a members table. The only new table is CareInvites (§5.1). | d2c.md L3 + d2c-phone-only-signin §7 |
| L4 | Phone-first D2C pool: `phone_number` required + verified, SMS-OTP the sole auth factor, email optional/unverified. Every account therefore has a verified phone — the invite match anchor. | coord §C56 |
| L5 | `family_viewer` read scope = `linkedPatientIds` on the RoleAssignments row, loaded per request (`api_authz.linked_patient_ids`); 404-leak prevention on unlinked probes. | 2A-RD |
| L6 | Phone-at-rest is stored as peppered HMAC + display mask, never raw (`_shared/claim_binding.py`, secret `gosteady/{env}/claim-binding-pepper`). | d2c-claim-binding D3 |

## 3. Decisions (locked 2026-07-14 scoping session)

| # | Decision | Why |
|---|----------|-----|
| D1 | **Phone-first SMS invites.** Admin enters name + phone (+relationship, +make-admin, +is-walker-user). Invite stores `contactHash` (peppered HMAC) + `contactMask`; SMS carries `/join/{inviteId}`. Accept requires the caller's **verified** phone to hash-match — fail-closed (mirrors claim D11). | The pool makes phone the only viable onboarding identifier (SMS-OTP sole factor — email can't onboard anyone); link-forwarding grants nothing; reuses shipped HMAC machinery. Supersedes the email/magic-link 5a sketch. |
| D2 | **One household per account in V1.** Invite-accept 409s (`ALREADY_IN_HOUSEHOLD`) if the caller's row names a different client; claim 409s (`MEMBER_CANNOT_CLAIM`) if the caller is a `family_viewer`. Multi-household defers to V2 (§6). | Preserves A5/T2 and every deployed authz assumption. The V2 path (Memberships table + active-household switcher) is additive — no pool/JWT/PK migration — so deferring is not a one-way door. |
| D3 | **Member powers = view + acknowledge alerts.** Members read activity/alerts/device health for linked patients and can ack with an optional note (2A-AA first-write-wins). Device lifecycle, care note, thresholds, roster mgmt stay Admin-only. | In D2C the members ARE the caregivers; "I called Mom" is the natural unit of collaboration. Audit names the actor; first-write-wins already handles races. |
| D4 | **Core-only scope.** Invite/accept/revoke/resend + roster mgmt (promote/demote/remove/leave, last-Admin guard) + member read view + ack. Member SMS alerts (5c), QR walk-up access-requests (5b) deferred. | SMS delivery = the (unbuilt) Phase-2C/d2c-Phase-2 dispatch pipeline + 10DLC lead time; it extends to members for free once it exists. |
| D5 | **Consent posture: Admin authority + transparency.** Admin invites under ToS authority; every membership change audited; the roster is visible to **all** members (a walker-user member always sees who can view their data). No walker-user consent gate. | A consent gate would break the account-less walker (first-class per d2c.md L2). Transparency + audit is the honest V1 posture. |
| D6 | Invite schema is **channel-generic**: `contactHash` + `contactChannel` (`"phone"` today), not a phone-named column. | An email-invite variant (post email-verification workstream) becomes a column value, not a migration. |
| D7 | **Reuse the claim-binding pepper** (`gosteady/{env}/claim-binding-pepper`) for invite hashes. | One secret, same normalize→HMAC path, no cross-comparison risk (different tables, same identity semantics). |
| D8 | Invite lifecycle: **14-day expiry** (`expiresAt` checked at accept; DDB TTL sweeps the row 90 d later for audit-friendly retention), resend re-arms expiry, revoke = status flip, **cap 10 pending invites per household**. | Bounded blast radius for a compromised Admin session; TTL keeps the table self-cleaning without erasing recent history (audit log holds the permanent trail). |
| D9 | **Removed member / voluntary leave ⇒ row deleted.** Their next token falls back to the pre-token bootstrap default (`dtc_{sub}`, empty solo household, empty dashboard). Documented, accepted. | Matches the existing pre-token contract exactly; no new "orphaned member" state needed. |
| D10 | Roster includes the **account-less walker user**, synthesized from the household's active Patient row (`displayName`, no `userId`). | d2c.md L2 — the walker may never create an account; the circle must still show them. |
| D11 | An invite may be flagged `isWalkerUser`: on accept, the member row gets `isWalkerUser=true` and, if the active Patient has no `cognitoUserId`, it is linked to the accepter. | d2c.md L2's "the walker user becomes a Member iff they sign up" — the invite is how the Admin hands them that door. |
| D12 | `family_viewer` alert-ack is allowed **role-wide** (scoped by `enforce_patient_access`, i.e. only their linked patients). | family_viewer only ever holds linked patients, so household-scoping falls out for free. The facility channel (V3) may re-gate per client type; noted in user-needs Appendix B. |
| D13 | New audit event names are **local literals** in the care-circle Lambda (mirrors d2c-claim precedent), masked contact only, never raw phone. | Avoids touching `_shared/audit_catalog` (imported by deployed facility handlers) for a D2C feature. |

## 4. The gap this must close (current-state hazard)

`d2c-claim` `put_item`-**overwrites** the caller's single RoleAssignments row
with `role=household_owner` and `resolve_household` trusts whatever `clientId`
the row names. Harmless today (only owners exist). The moment members exist:

1. **Member claims their own walker** → `resolve_household` returns the
   household they're a *member* of → the §5.7 dedupe attaches the new device
   to *that household's existing patient* → the row overwrite promotes them to
   owner of someone else's household. Cross-family data bleed.
2. **Owner accepts an invite** → a naive accept writer would overwrite their
   owner row → they lose their own household.

Both are closed by guards (§5.3 step 3, §5.6) — mandatory regardless of any
other scope decision.

## 5. Scope — BUILD NOW

### 5.1 CareInvites table (`gosteady-{env}-care-invites`)

New table in the **facility Auth stack** (`GoSteady-{Env}-Auth`), beside
RoleAssignments — same membership/identity domain, same IdentityKey CMK,
same api-stack import path. (First sketched into D2C-Auth; moved because
D2C-Auth has no securityStack dependency and adding one would create a new
cross-stack edge for no benefit — §C56.2 lesson.) CMK-encrypted with
IdentityKey (identity-bearing).

- **PK** `inviteId` (S, uuid4 hex).
- Attributes: `clientId`, `patientIds` (SS — the walker patient(s) this invite
  grants; V1 = the household's one active patient, snapshotted at accept
  time, not send time — see §5.3), `contactHash` (S, peppered HMAC),
  `contactMask` (S, `•••-1234`), `contactE164` (S, raw destination — resend
  needs one and the HMAC is irreversible; at rest under the identity CMK,
  same posture as the raw `phone` already stored on RoleAssignments rows;
  never returned by any endpoint), `contactChannel` (S, `"phone"`),
  `displayName`, `relationship` (free text V1), `role`
  (`family_viewer` | `household_owner`), `isWalkerUser` (BOOL),
  `status` (`pending` | `accepted` | `revoked` | `expired`), `invitedBy` (sub),
  `createdAt`, `expiresAt` (ISO 8601), `acceptedBy`/`acceptedAt` (sparse),
  `ttl` (N, epoch = expiresAt + 90 d — DDB TTL sweep).
- **GSI `by-client`** (PK `clientId`, SK `createdAt`) — Admin's invite list.
- **GSI `by-contact-hash`** (PK `contactHash`, SK `createdAt`) — accept-time
  lookup + the organic-signup match (§5.3).

### 5.2 New Lambda `care-circle` (routes on the existing HTTP API, D2C authorizer)

`infra/lambda/care-circle/handler.py` + pure `circle_logic.py`
(unit-testable, stdlib-only — mirrors `claim_logic.py`). Route table:

| Route | Authz | Semantics |
|---|---|---|
| `POST /api/v1/household/invites` | `household_owner` | Body `{name, phone, relationship?, role?, isWalkerUser?}`. Normalize (`normalize_e164`) → HMAC. Rejects: self-invite (hash == caller's), hash matches an existing member or live pending invite (`DUPLICATE_INVITE`), ≥10 pending (`INVITE_LIMIT`). Writes invite row; sends SMS join link (§5.8). Audit `d2c.invite_sent` (mask only). |
| `POST /api/v1/household/invites/{inviteId}/resend` | `household_owner` | Re-sends SMS, refreshes `expiresAt`/`ttl`. 409 unless `pending`. Audit `d2c.invite_resent`. |
| `DELETE /api/v1/household/invites/{inviteId}` | `household_owner` | Status → `revoked`. Audit `d2c.invite_revoked`. |
| `GET /api/v1/household/members` | any household role | Roster (§5.4). |
| `GET /api/v1/invites/pending` | any authenticated D2C user | Caller's verified-phone hash → `by-contact-hash` → live pending invites `{inviteId, householdName, walkerName, invitedByName, role}`. Empty list when phone unverified (fail closed, no error). |
| `POST /api/v1/invites/accept` | any authenticated D2C user | §5.3. |
| `PATCH /api/v1/household/members/{userId}` | `household_owner` | `{role}` promote/demote. Last-owner guard (§5.5). Audit `d2c.member_role_changed`. |
| `DELETE /api/v1/household/members/{userId}` | `household_owner`, or self | Remove member / leave (§5.5). Audit `d2c.member_removed` / `d2c.member_left`. |

Household identity is always the **token's** `clientId` — no clientId in
paths, so tenancy is structural (nothing to cross-check).

### 5.3 Accept flow (`POST /api/v1/invites/accept {inviteId}`)

Ordered, fail-closed:

1. **Phone proof:** `phone_number` present AND `phone_number_verified` in
   claims, HMAC matches `invite.contactHash` — else neutral
   `403 INVITE_PHONE_MISMATCH` (no oracle: absent/unverified/mismatch look
   identical externally; audit distinguishes internally,
   `d2c.invite_accept_rejected`).
2. **Invite state:** status `pending` and `expiresAt` in the future — else
   `409 INVITE_NOT_ACTIVE` (revoked/accepted/expired all neutral).
3. **Membership guard (the L2 boundary):** caller's RoleAssignments row, if
   present, must name **this** invite's `clientId`:
   - different `clientId` → `409 ALREADY_IN_HOUSEHOLD` — copy: *"This account
     is already part of another Care Circle. Contact support to move it."*
   - same `clientId` → idempotent success (re-accept; row refreshed).
   - no row → proceed.
4. **First-accept-wins:** conditional update `status pending → accepted`
   (+`acceptedBy`/`acceptedAt`); conditional failure → re-check → treat as
   `INVITE_NOT_ACTIVE` (a second phone with the same number can't race in —
   same hash, but the condition still makes exactly one accept land).
5. **Grant write:** RoleAssignments `put_item` `{userId: sub, clientId, role,
   role_userId: "{role}#{sub}", isWalkerUser, linkedPatientIds: <household's
   ACTIVE patient ids, resolved NOW via the by-client-status GSI>,
   displayName, relationship, email, phone, validFrom, assignedBy: invitedBy,
   invitedVia: inviteId}`. Resolving `linkedPatientIds` at accept time (not
   send time) means an invite sent before a device rotation still grants the
   current patient.
6. **Walker-user link (D11):** if `invite.isWalkerUser` and the active Patient
   has no `cognitoUserId`, set it (conditional on `attribute_not_exists`).
7. Audit `d2c.invite_accepted` + `d2c.member_joined`; return household
   summary. **Client then calls `refreshClaims()`** (existing post-claim
   pattern) so the next token carries the household's `clientId`/`role`.

Organic-signup path: after any OTP sign-in where the user has no household
data, the app calls `GET /invites/pending` and offers the join — covers "got
the SMS, ignored the link, signed up from the app store later."

### 5.3a Durable re-entry + confirmation SMS (2026-07-18 follow-up)

The invite `/join/{inviteId}` link is a **durable re-entry point**, not a
one-time onboarding token — a member who returns to it (session timed out, or
they just re-tap the text) must land back on the data, not an "expired" wall.
Two pieces:

- **Re-entry (frontend, `D2CJoinScreen`).** Signed-in: the invite is resolved
  against the caller's identity — a live invite in their pending list →
  first-time confirm-and-join; **already a member via this invite → straight
  to the dashboard** (via the idempotent accept, which returns `alreadyMember`
  for the original acceptor even past `expiresAt` — see step 3, the
  `acceptedBy == sub` early-return precedes the liveness check); another
  household → neutral + a link home; genuinely unavailable → neutral copy.
  Signed-out: routes through phone-first sign-in (**a fresh OTP re-verifies
  the phone**) → the post-OTP accept is idempotent → dashboard. So the link
  keeps working forever, re-authenticating as needed. No backend change — the
  accept endpoint was already idempotent for the original acceptor; this is a
  frontend routing fix over that property.
- **Confirmation SMS (backend, on FIRST accept only).** Immediately after a
  fresh accept (step 7), the handler sends a one-time confirmation SMS to the
  invite's stored `contactE164` — the number just proven — carrying the same
  `/join/{inviteId}` link as their durable way back in. **Best-effort:** the
  accept has already committed, so an `SmsSendError` is logged, never fatal
  (mirrors the walker-user-link posture). Idempotent re-accepts do **not**
  re-send (they return before this point). Emits `d2c.member_join_confirmed`
  (masked contact only) on a successful send. Copy in `circle_logic.
  confirm_sms_body`.

### 5.4 Roster read (`GET /household/members`)

One query: RoleAssignments `by-client-role` (PK = token clientId; projection
ALL). Response rows: `{userId, displayName, relationship, role, isWalkerUser,
contactMask (derived from stored phone at read time — raw phone is never
returned), joinedAt: validFrom}`. Synthesizes the account-less walker entry
from the household's active Patient (`displayName`, `isWalkerUser: true`,
`userId: null`) when no member row has `isWalkerUser`. Pending invites
(`by-client` GSI, status `pending`, unexpired) are included **for Admins
only**; plain members see the confirmed roster.

### 5.5 Roster management + the last-owner guard

- **Promote/demote** (`PATCH`): rewrites `role` + `role_userId` on the target
  row (and `linkedPatientIds` housekeeping: demote to `family_viewer` fills
  it with the household's active patients; promote to owner removes it —
  owners are client-scoped).
- **Last-owner guard:** demote/remove/leave of a `household_owner` is refused
  (`409 LAST_ADMIN`) when the `by-client-role` count of
  `begins_with(role_userId, "household_owner#")` is 1. (Small-N read-check;
  a lost race worst-case leaves a household admin-less until support —
  accepted at pilot scale, noted in §9.)
- **Remove vs leave:** Admin may delete any non-last-owner member's row;
  any member may delete their own (leave), owners only if ≥2 owners.
  Row deletion is the revoke — `linked_patient_ids()` reads DDB per request,
  so access ends on the member's next call. Their next token falls back to
  the bootstrap default (D9).

### 5.6 Claim guard (`d2c-claim` change)

In `_claim`, immediately after loading the caller's existing row: if
`row.role == "family_viewer"` → `409 MEMBER_CANNOT_CLAIM` — copy: *"Your
account is part of another Care Circle. Contact support to set up your own
walker."* Audit `d2c.claim_rejected_member_account`. Owner/no-row paths
unchanged. (V2's Memberships model makes this case a clean "add an owner
membership" instead — §6.)

### 5.7 Alert-ack gate (`alert-actions` change)

Allow `family_viewer` on `PATCH /alerts/{patientId}/{ts}`, scoped through the
existing `enforce_patient_access` + pre-loaded `linked_patient_ids` (the
handler already loads them for reads). Threshold routes unchanged
(facility_admin+/owner writes). Ack audit already names the actor.

### 5.8 Invite SMS delivery (`_shared/sms.py`)

Extract the ~20-line Twilio REST (urllib) send from `d2c-custom-auth` into
`_shared/sms.py :: send_sms(to_e164, body)` reading the existing
`gosteady/{env}/twilio` secret. **The deployed custom-auth Lambda is NOT
touched** (consolidation later — same posture as the provision-inline
precedent). Invite copy: `"{inviter} invited you to {walker}'s GoSteady Care
Circle: https://app.gosteady.co/join/{inviteId}"`. Same 10DLC number as OTP;
transactional volume at pilot scale — flagged in §9 for GA review.

### 5.9 Flutter (`lib/d2c/`)

- Promote `CareCircleMember` from `d2c_mock_data.dart` to a real model file;
  add `invitePending`-backed pending entries from the API shape.
- Repository (`D2CRepository` + `LiveD2CRepository` + mock impl):
  `fetchCareCircle`, `sendInvite`, `resendInvite`, `revokeInvite`,
  `fetchPendingInvites`, `acceptInvite`, `setMemberRole`, `removeMember`,
  `leaveHousehold`.
- `d2c_care_team_screen.dart`: swap local `setState` mutations for repository
  calls. Invite sheet collects **phone** (reuse the shipped US
  normalization from the reserved-claim landing) + name + relationship +
  make-admin + "this is the walker user". Access-requests section hidden
  (5b deferred). Non-admin viewers: read-only roster + Leave.
- New route `/join/{inviteId}`: signed-out → existing phone-first
  signup/sign-in → accept; signed-in → confirm sheet ("Join {household}'s
  Care Circle?") → accept → `refreshClaims()` → dashboard. Error surfaces:
  neutral mismatch 403, `ALREADY_IN_HOUSEHOLD` support copy, expired/revoked.
- Post-OTP organic check: no-household users get the pending-invite prompt.
- Member dashboard: `/me/patients` by-patient-ids plan already serves
  `family_viewer`; ensure the ack affordance renders for members; role-aware
  copy via the existing runtime-copy mechanism.

## 6. Out of scope — DEFERRED (and how each stays additive)

| Deferred | Forward-compat note |
|---|---|
| **Multi-household membership** (adult child with two parents in two households; member-owns-own-walker) | V2: `Memberships` table (user × household) as source of truth; the RoleAssignments row becomes the **active-household projection**, rewritten on switch + `refreshClaims()` — the exact pattern claim already uses. Zero pre-token/authz/JWT changes; backfill = copy existing rows 1:1. V1's guards (D2) keep the data clean until then. |
| **Member SMS alerts + per-member prefs** (5c) | Rides the d2c Phase-2 / 2C dispatch pipeline (`Users.notificationPrefs` matrix). Membership rows already identify recipients per household; nothing here constrains it. |
| **QR walk-up access-requests** (5b) | Additive `AccessRequests` table + approve/deny endpoints; the mock UI section already exists (currently hidden). Approval writes the same RoleAssignments row as accept (§5.3 step 5). |
| **Multi-walker household** (Mom + Dad under one Admin) | Claim needs an explicit "additional walker" intent — today's §5.7 dedupe would attach a second device to the existing patient. Invite `patientIds` (SS) + accept-time resolution already handle N patients. |
| **Facility-channel family viewers** (V3) | Same role, same `linkedPatientIds` mechanism; CareInvites carries `clientId` so a facility issuer is a policy change, not a schema change. Per user-needs §7 #10, reserved not built. |
| **Email invites** | `contactChannel: "email"` + verified-email requirement once the email-verification workstream lands (pool already allows email sign-in aliases; verification is the missing piece). |
| **Auth expansion** (verify-email, passkeys/`USER_AUTH`, social + `AdminLinkProviderForUser` PreSignUp linking) | Separate workstream; membership keys on the Cognito `sub`, so added sign-in methods never move access. |
| Support tooling (household move/merge for `ALREADY_IN_HOUSEHOLD` cases) | Ad-hoc via internal CLI at pilot scale; graduates with the V2 switcher. |

## 7. Interfaces + data (summary)

- **CareInvites row + GSIs** — §5.1. **RoleAssignments member row** — §5.3
  step 5 (new fields on existing rows: `displayName`, `relationship`,
  `invitedVia`; existing: `linkedPatientIds`, `isWalkerUser`, `role_userId`).
- **Endpoints** — §5.2 table. New error codes: `DUPLICATE_INVITE`,
  `INVITE_LIMIT`, `INVITE_PHONE_MISMATCH`, `INVITE_NOT_ACTIVE`,
  `ALREADY_IN_HOUSEHOLD`, `LAST_ADMIN`, `MEMBER_CANNOT_CLAIM`.
- **Audit events** (local literals, masked contact only): `d2c.invite_sent`,
  `d2c.invite_resent`, `d2c.invite_revoked`, `d2c.invite_accepted`,
  `d2c.invite_accept_rejected`, `d2c.member_joined`,
  `d2c.member_join_confirmed` (confirmation SMS sent on first accept — §5.3a),
  `d2c.member_role_changed`, `d2c.member_removed`, `d2c.member_left`,
  `d2c.claim_rejected_member_account`.
- **Secrets:** reuses `gosteady/{env}/claim-binding-pepper` +
  `gosteady/{env}/twilio`.
- **IAM (care-circle Lambda):** RoleAssignments R/W, CareInvites R/W,
  Patients R + conditional `cognitoUserId` write, Organizations R, both
  secrets R, IdentityKey + AuditKey usage per existing handler pattern.

## 8. Testing

| # | Scenario | Method | Expected |
|---|----------|--------|----------|
| T1 | Admin invites phone A; A signs up + accepts via link | live E2E | Member row written, roster shows both, dashboard renders walker data after `refreshClaims()` |
| T2 | B (different verified phone) opens A's link and accepts | synthetic | `403 INVITE_PHONE_MISMATCH`, audit reason `phone_mismatch` |
| T3 | Caller with unverified/absent phone accepts a valid invite | synthetic | 403 fail-closed, audit `phone_unverified`/`phone_absent` |
| T4 | Accept revoked / expired / already-accepted invite | unit + synthetic | `409 INVITE_NOT_ACTIVE` (neutral) |
| T5 | Owner of household X accepts invite to household Y | synthetic | `409 ALREADY_IN_HOUSEHOLD`; X's row untouched |
| T6 | Member of X re-accepts X's invite | unit | Idempotent 200 |
| T7 | Member of X scans a QR and claims a device | synthetic | `409 MEMBER_CANNOT_CLAIM`; no patient/row mutation |
| T8 | Demote/remove/leave the last owner | unit | `409 LAST_ADMIN` |
| T9 | Admin removes member; member's next patient read | synthetic | 404 (instant revoke via DDB-read authz) |
| T10 | Member acks an alert on linked patient; second member acks same alert | synthetic | First-write-wins (2A-AA), audit names first actor |
| T11 | Member acks an alert on a non-linked patient | synthetic | 404 (leak prevention) |
| T12 | Invite dedupe: same phone as existing member / live invite; self-invite; 11th pending | unit | `DUPLICATE_INVITE` / `INVITE_LIMIT` |
| T13 | `isWalkerUser` invite accepted; Patient has no `cognitoUserId` | synthetic | Patient linked (conditional write); roster stops synthesizing the account-less entry |
| T14 | Organic signup with pending invite (no link) | live E2E | Post-OTP prompt appears via `GET /invites/pending`; accept works |
| T15 | Phone normalization: `+1` / bare 10-digit / spaces hash equal | unit | Reuses `normalize_e164` semantics incl. the 2026-07-14 stray-`+` fix |

Verification: unit (`pytest infra/lambda/tests/`), synthetic-JWT E2E against
dev (lambda-invoke with crafted authorizer claims — established pattern),
then live dev E2E with a second real phone + Chrome screenshots. Deploy
order: `npm run build` → `GoSteady-Dev-D2C-Auth` (table) → `GoSteady-Dev-Api`
(Lambda + routes) → `deploy-d2c-app.sh`. Prod after dev E2E passes
(claim-binding cadence).

## 9. Open questions

- [ ] Relationship taxonomy — free text V1; enum when notification defaults
      need it (5c)?
- [ ] Member SMS **defaults** when 5c lands (all caregiver-directed alerts on?
      TCPA posture for invited members).
- [ ] Per-patient circles vs household membership once multi-walker
      households exist (invite `patientIds` already supports either).
- [ ] `LAST_ADMIN` read-check race (§5.5) — accept at pilot scale, or move to
      a transactional owner-count item with the V2 memberships work?
- [ ] 10DLC campaign review before GA (invite SMS on the OTP number).
- [ ] Pending-invite visibility for non-admin members (V1: admins only).

## 10. Changelog

| Date | Change |
|------|--------|
| 2026-07-14 | Initial spec — design locked in interactive scoping session (D1–D13): phone-first SMS invites w/ verified-phone fail-closed match; one-household-per-account V1 + guards (claim `MEMBER_CANNOT_CLAIM`, accept `ALREADY_IN_HOUSEHOLD`); member powers view+ack; core-only scope. CareInvites table + care-circle Lambda + Flutter wiring specced; 5b/5c/multi-household/facility deferred with compat notes. |
| 2026-07-18 | **Re-entry follow-up** (from the first real-world caregiver test — §5.3a). Bug: a caregiver returning to their `/join/{inviteId}` link after accepting hit an "expired / not available" wall (the single-use invite was consumed, so the signed-in join screen's pending-lookup found nothing). Fixes: **(1)** `D2CJoinScreen` now resolves the invite against the caller — a returning member routes straight to the dashboard (idempotent accept), signed-out re-enters via a fresh OTP, only genuine non-members see the neutral copy; the invite link is now a durable re-entry point. **(2)** On the FIRST successful accept the handler sends a best-effort confirmation SMS (`confirm_sms_body`) carrying that same durable link, so the member has a way back in their texts; emits `d2c.member_join_confirmed`. No API-shape change — the accept endpoint was already idempotent for the original acceptor. Built on a separate worktree/branch to avoid a parallel session. |
| 2026-07-17 | **Live-phone E2E passed + prod deploy.** Operator ran the full T1/T14 loop with a second real phone against dev — invite SMS delivered, `/join` → phone-first signup → verified-phone accept → member dashboard live. Precursor ops: the operator's household was rotated from the synthetic staged serial `GS0001000043` (returned to the staged pool) onto the physical rollator `GS9999999981` via the audited rotate primitives (end-assignment → §5.8 discharge of the DT-1 bench patient → walkerId mint → atomic release-and-bind → wipe-ack in ~2 min — first rollator-firmware wipe-ack recycle — → bound claim → `active_monitoring` ~1 min later); the claim rewrite also backfilled the pre-C56-era empty `phone`/`displayName` on the owner's role row. Prod deploy: Prod-Auth (CareInvites) + Prod-D2C-Auth (secret export) + Prod-Api (care-circle Lambda + routes + `/d2c/` ack route + refreshed handler bundles) + `deploy-d2c-app.sh --env=prod`; read-only prod smoke (empty-roster GET via synthetic bootstrap claims). |
| 2026-07-14 (built) | **Built + deployed to dev.** Backend: `CareInvites` table lives in the **facility Auth stack** beside RoleAssignments (not D2C-Auth as first sketched — same IdentityKey CMK + same api-stack import path, no new cross-stack edge); new `care-circle` Lambda (8 routes, D2C authorizer; mutations **row-authoritative** — demote/remove effective immediately, not at token refresh); `_shared/sms.py` extracted from the OTP sender (custom-auth untouched); d2c-claim `MEMBER_CANNOT_CLAIM` guard placed AFTER the idempotent early-return (a member re-scanning their own household's claimed device still gets the benign `alreadyClaimed`) + owner rows now carry `displayName`; alert-actions adds `family_viewer` to `_CAN_ACK` + `/d2c/` route normalization + the `PATCH /api/v1/d2c/alerts/…` route. One shape addition vs the draft: invites store `contactE164` (resend needs a destination; HMAC is irreversible; identity-CMK at rest like RoleAssignments' raw `phone`; never returned by any endpoint). Flutter: care-team screen repository-driven (mock repo keeps demo/preview parity), invite sheet phone-first + walker-user toggle, `/join/{inviteId}` route + `join` threading through sign-up/sign-in/OTP, organic pending-invite prompt on the no-walker dashboard, member ack wired via the shared `ackAlert` (readPrefix). Verified: 50/50 unit + **26/26 synthetic-JWT E2E vs live dev** (roster/dedupe/fail-closed accept×3/idempotent/cross-household/member-read/ack×2/claim-guard/last-admin/promote-demote/instant-revoke) + `flutter analyze` clean + web build. |

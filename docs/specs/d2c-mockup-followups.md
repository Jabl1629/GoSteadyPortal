# D2C Mockup — Follow-up Questions

> Running list of open product / design / data-model questions surfaced
> while building the D2C wireframe screens. For review when Jace is back.
> Each screen mockup is navigable from the preview hub:
> **https://jabl1629.github.io/GoSteadyPortal/#/d2c/preview**

Status legend: 🔴 blocks spec · 🟡 shapes UX · 🟢 nice-to-decide

---

## ✅ Decisions (locked)

**Review session 1**
- Notification rows: everyone gets the same set at launch (no role-gating).
- Last-Admin guard: can't remove/demote the only Admin. Enforced in mock.
- QR landing URL = `portal.gosteady.co/setup/{walkerId}`, where `{walkerId}`
  is an **opaque, random, non-sequential** ID (NOT the printed GS serial).
- First-timer OTP: no email-OTP. New person signs up (enters phone) → SMS
  to that number. Returning users: email → SMS to phone on file. Single
  SMS-OTP path.
- Dashboard is the same for caregiver + walker user; only copy adapts
  ("you" vs name). Device card + alerts shown to everyone. Nav unified to
  Activity / Care Team / Account.
- Greeting copy: no "run / pace / rhythm" — use "steady" / "above your usual."
- Bottom nav persistent across all top-level tabs; "Today" → "Activity."

**Review session 2**
- Care note visible to the walker user too (everyone sees the same note).
- Only existing Admins can grant Admin; a plain Member cannot self-promote.
- Relationship label = **free text** (not a fixed picker).
- QR "request access" free-text note is **required**, ~200 char max.
- Device transfer (resold/gifted) = **contact support** in V1 (no self-serve).
- Quiet hours (do-not-disturb window): **deferred** past V1.
- **History screen (30/90-day) — BUILD IT** (mock this round, behind the
  trend's "See more" + an Activity-tab affordance).
- Pre-claim QR landing shows a **masked owner email** ("s•••@gmail.com").
- Walker-user-who-is-also-Admin: show **both** badges.
- Access-request card wording: **drop "claims to be"** → "Tom Davis · Grandson";
  the required note + admin approval are the trust signal.
- TCPA SMS consent: standard consent line in the UI now; **legal review
  before any real SMS sends**.
- Welcome wizard is an **exception path** (only when ops didn't pre-fill the
  walker's name/relationship); skipped for the 70–80% pre-bound-Admin flow.
- Account "edit" pencils + real QR generation: wire at go-live (build detail).
- Resolved/moot: battery-alert audience (everyone sees same dashboard now).

---

## Account model / Care Circle

- 🔴 **Last-Admin guard.** When removing an Admin or demoting the last
  Admin, we must block it (orphaned household = no one can manage
  billing/invites/transfer). Mock enforces "can't remove last Admin."
  Confirm that's the rule, and what the error copy should say.
- 🟡 **Can a Member promote themselves to Admin?** Current assumption:
  only an existing Admin can grant Admin. A plain Member cannot self-
  promote. Confirm.
- 🟡 **Walker-user + Admin combo.** The doc says a walker user can also
  be an Admin. In the Care Team list, do we show two badges
  ("Walker user" + "Admin") or collapse to one? Mock shows both.
- 🟢 **Relationship label taxonomy.** Invite form currently free-texts
  the relationship ("Daughter", "Son", "Neighbor", "Aide"). Do we want
  a fixed picker, or free text? Free text is friendlier but messier for
  any future analytics.

## Onboarding / auth

- 🔴 **QR encodes walker ID only** (per the doc). Confirm the landing
  URL shape: `portal.gosteady.co/setup/{walkerId}` vs a short link.
  Mock uses `/d2c/preview/onboarding/qr-*`.
- 🟡 **Pre-claim race masking.** Landing page shows masked owner email
  ("s***@gmail.com") when a device is already claimed. Confirm masking
  format + that we show it at all (vs a generic "already registered").
- 🟡 **Sign-in identifier.** We settled on email-as-identity + SMS-OTP.
  The sign-in screen asks for email first, then sends an OTP to the
  phone on file. But a brand-new QR walk-up has no phone on file yet —
  do they get the OTP by email instead for first sign-in? Mock assumes
  email OTP for first-time, SMS-OTP for returning. Confirm.
- 🟡 **Required free-text note on access request** (per doc). Mock makes
  it required with a placeholder ("Hi Mom, it's Sarah…"). Confirm
  required vs optional + max length.

## Notifications

- 🔴 **Preference matrix shape.** Mock models prefs as
  `{alertType} × {SMS, email}` toggles. Confirm the alert-type rows we
  expose to D2C users (currently: no-activity, low-activity, declining
  trend, fall/impact, device offline, battery). Some of these are
  device-operational — do walker users / non-admin members even get
  device-health rows, or only activity rows?
- 🟡 **TCPA opt-in.** SMS rows show an opt-in checkbox with consent
  language on first enable. Confirm the exact consent copy / whether
  legal needs to review before we ship.
- 🟢 **Quiet hours.** Whoop/most apps offer a do-not-disturb window.
  Worth adding to V1, or defer? Mock omits it.

## Dashboard

- 🟡 **Greeting copy precedence.** 6 variants (personal best, 3-day
  streak, above pace, lighter day, quiet morning, rest day). Want to
  review the full set + tune wording? They're in
  `d2c_dashboard_screen.dart _GreetingCard._copy()`.
- 🟡 **"Lighter day" / "rest day" framing.** For an elderly user a low
  day shouldn't feel like failure. Current copy is neutral ("A lighter
  day so far"). Confirm tone — never guilt-trippy.
- 🟢 **Trend "See more" + History tab** both dead links right now.
  History screen is not yet mocked. Worth a dedicated 30/90-day view?

## Device lifecycle (D2C-flavored)

- 🟡 **Transfer flow.** Device settings shows "Transfer device — contact
  support" copy (V1 = no self-service). Confirm that's acceptable for
  pilot, or do we need a self-serve release flow sooner?
- 🟢 **Battery alert audience.** Walker user mode hides device-health
  alerts entirely. Confirm: should a walker user living alone (their
  own Admin) still see battery alerts? Edge case — walker user who is
  also the only Admin.

## New questions surfaced while building the rest of the set

- 🟡 **"Claims to be Grandson" framing on access requests.** The Care Team
  approval card currently reads `Tom Davis · claims to be Grandson`. The
  "claims to be" is deliberately skeptical (anti-impersonation per the
  doc) but might read as cold. Alternative: just `Tom Davis · Grandson`
  and rely on the note + approval gate for trust. Your call on tone.
- 🟡 **Sign-in OTP channel for first-timers.** The OTP screen says "code
  to the phone ending in ••34" — but a brand-new QR walk-up has no phone
  on file. We need a first-time variant ("we emailed you a code") vs the
  returning-user SMS variant. Mock only shows the SMS variant. Flagging
  the branch for the auth spec.
- 🟡 **Welcome wizard vs. sign-up ordering.** Right now sign-up collects
  name/email/phone, and the welcome wizard (rare first-Admin path)
  collects the *walker's* name + relationship. For the pre-bound-Admin
  flow (70-80% of customers) ops pre-fills the walker info, so the
  wizard is skipped. Confirm the wizard only appears when ops didn't
  pre-fill — i.e. it's an exception path, not the default.
- 🟢 **Preview navigation.** Signed-in screens' back arrows return to the
  dashboard, not the hub; to get back to the index from a deep screen
  you use the browser back button. Fine for a mock; just noting it's not
  a real nav model.
- 🟢 **Account-settings edit affordances** are visual-only (pencil icons
  don't open editors yet). The phone row shows a "Verified" chip; the
  re-verification flow when you change a number isn't mocked.
- 🟢 **Device-settings "Show QR" sheet** renders a placeholder QR glyph,
  not a real code. Real QR generation is an in-house tool decision (we
  settled on generating + stickering QR in-house).

---

## Screens built (deployed to the hub)

**Dashboard**
- Home — activity (caregiver ↔ walker-user toggle)
- Home — no activity yet (empty state)
- Home — walker on the way (pre-activation)

**Care Team**
- Admin view (invite, approve/deny requests, manage members, last-Admin guard)
- Member view (read-only roster)
- Invite sheet, Member detail sheet (bottom sheets)

**Onboarding — QR walk-up**
- Unclaimed device / Already claimed / Request access (+ sent state) / Decommissioned

**Onboarding — accounts**
- Invite-link landing / Sign in / Enter SMS code / Sign up / Welcome wizard

**Account**
- Settings / Notification preferences matrix / Who's accessed the data (audit) / Device settings (+ QR sheet)

**Edge cases**
- Link expired / Link already used / Request declined

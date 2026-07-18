# D2C Caregiver / Care Circle Member Agreement — plain-language draft

> **Status:** 🔵 Draft for review — 2026-07-18. **Needs a counsel skim before real users** (same pass as the walker agreement). Entity/contact/governing-law match the published pages: GoSteady LLC, 3049 Lawrence Street, Denver, CO 80205, jace@gosteady.co, Colorado law.
> **Companion to:** [`d2c-user-agreement.md`](d2c-user-agreement.md) (the walker/rollator-user agreement). This is the **caregiver variant** that doc flags as a follow-up (its Q2b / Reviewer notes). Same posture, framed for the *invited family member / caregiver* who joins a **Care Circle** and views **someone else's** activity — not the person using the device.
> **Who sees this + when:** shown once, in the **Care Circle join flow** (`/join/{inviteId}` → accept), to a `family_viewer` (UI label "Member") before their membership is created. The walker user / household Admin sees the walker agreement instead ([`d2c-care-circle.md`](d2c-care-circle.md) §5.3).
> **What this is:** the plain-language acknowledgment shown at join. It *summarizes and links to* the full published [Terms of Service](https://gosteady.co/terms.html) and [Privacy Policy](https://gosteady.co/privacy.html) (effective 2026-06-01) — it does not replace them.

---

## Part 1 — Plain-language agreement (Care Circle join screen)

> Written for the family member / caregiver, reading it themselves as they accept an invite. One plain idea per block; ~6th-grade reading level; large-type friendly. `{walker}` renders the walker user's first name where known (from `Patient.displayName`), else "your family member."

### You've been invited to a Care Circle

Someone set up a **GoSteady** device for **{walker}** and invited you to help keep an eye on how they're getting around. Here's the plain-language version of what you're agreeing to. The full details are in our [Terms of Service](https://gosteady.co/terms.html) and [Privacy Policy](https://gosteady.co/privacy.html).

**What you'll be able to see**
You'll get a simple picture of **{walker}'s** activity — things like how far they go, how long they're active, and how it's trending — plus their device's health (battery, signal). You get this because **{walker}'s household invited you**; access is theirs to give, and to take away.

**This is {walker}'s personal information — please treat it that way**
What you see is **{walker}'s** private activity information. Use it to support and encourage them — **not** to share, post, screenshot, or use it for anything they wouldn't want. If you no longer should have access, an Admin can remove you, and you can leave anytime.

**It's not a doctor, and it's not for emergencies**
GoSteady is a wellness and activity product. It is **not a medical device**, it can't diagnose or treat anything, and it does **not** detect falls or emergencies — it won't alert you if something goes wrong in the moment. **If you're ever worried {walker} is unwell, hurt, or unsafe, call them or 911 right away** — don't wait on the app.

**What you can do**
You can **view** {walker}'s activity and **acknowledge a notification** to note you've seen it (for example, "I called Mom"). Acknowledging is just a note for the family — it is **not** a medical or clinical action, and it doesn't dispatch help. Managing the device, the Care Circle, and settings stays with the household's Admin(s).

**Text messages**
We'll text a code to your phone when you sign in, a note confirming your access, and — if you'd like — occasional updates about {walker}'s activity. **Reply STOP** to any text to stop them. Message and data rates may apply. We **never** sell or share your number.

**What GoSteady measures — and what it doesn't**
The device only senses *movement*. It has **no microphone, no camera, and no GPS** — it doesn't listen, watch, or track anyone's location.

**Your information**
To give you access we keep your name and mobile number, and a record that you joined this Care Circle. Your information is **encrypted** and access is limited. We **do not sell your information. Ever.** You can ask us to delete it, and you can leave the Care Circle, at any time.

**This is an early product**
Thank you for helping look after {walker}. Features may change and improve as we go, and the service is provided "as is." Questions anytime: **jace@gosteady.co**.

**You should be 18 or older to join a Care Circle.**

---

*(Acknowledgment — mirrors the walker agreement's lean: prominent, acknowledged, not a hard checkbox.)*
> **[ Got it — I understand ]**
> By joining, you agree to the [Terms of Service](https://gosteady.co/terms.html) and [Privacy Policy](https://gosteady.co/privacy.html), and to use {walker}'s information only to support them.

---

## Part 2 — Terms of Service: caregiver / Care Circle clause

> Paste-ready once counsel signs off; bump the Terms effective date when it lands. Companion to the walker agreement's Part 2 (which adds the Steady coaching clause). Suggest inserting near the account/"who can use the Service" section.

> **Care Circle members.** A household may invite additional people ("Care Circle members") to **view** a walker user's activity and device information. If you join a Care Circle, you receive **read-only** access to that walker user's information for the purpose of supporting their well-being, granted by the household and revocable by it at any time. You agree to use that information **only** to support the walker user and **not** to disclose, publish, or use it for any other purpose; that access does not transfer ownership of the information to you; and that acknowledging a notification is an informational note, **not** a medical or emergency-response action. GoSteady is **not a medical device** and does **not** detect falls or emergencies — in an emergency, call 911. You must be 18 or older to join a Care Circle.

---

## How the acknowledgment is recorded (implementation)

Wired in the D2C join flow ([`d2c-care-circle.md`](d2c-care-circle.md) §5.3 / §5.9):

- **Gate:** the plain-language agreement (Part 1) renders on the join-confirm step; the "Join Care Circle" action is the acknowledgment (clickwrap — "By joining you agree…"). The signed-out path shows it after phone verification, before membership is written.
- **Record:** `POST /api/v1/invites/accept` accepts an optional `agreementVersion`; on a fresh accept the handler stamps `agreementVersion` + `agreementAcceptedAt` onto the member's `RoleAssignments` row and emits `d2c.agreement_acknowledged` (masked contact only). Idempotent re-accepts don't re-stamp. Version constant shared with the walker flow (`kD2CAgreementVersion`).
- **Why record it:** an acknowledgment you can't evidence isn't much of one — who accepted which version, and when, is the defensible minimum. Cheap + additive over the existing accept write.

## Reviewer notes / open items

- **Counsel skim required** before real users — same pass as the walker agreement. Focus: the "read-only, revocable, use-only-to-support, no-emergency-reliance" caregiver posture and the acknowledgment form.
- **Account-less walker (Q2b, still open in the walker doc):** when a caregiver-Admin sets up the device for a walker user who has **no account**, who acknowledges on the walker's behalf and how the walker is informed remains a follow-up. This doc covers the *built* path — an invited `family_viewer` acknowledging for **themselves**. The self-claim walker acknowledges via the walker agreement.
- **SMS terms link:** the published Terms/Privacy link to `/sms-consent.html`, which currently **404s at gosteady.co** (the file exists in `web/` but isn't deployed) — the acknowledgment cites only the live Terms + Privacy pages until that marketing-site gap is closed. Flag for the web deploy owner.
- **Rendering:** Part 1 becomes the Flutter join-agreement panel (reused shape with the walker signup panel, `deviceType`-neutral — a caregiver may follow a rollator user). Part 2 goes into `web/terms.html` after sign-off.

## Changelog
- **2026-07-18** — Initial draft. Caregiver / Care Circle member plain-language agreement + a Terms clause, companion to the walker agreement. Framed for the invited `family_viewer`: read-only, revocable, use-only-to-support, not-for-emergencies; acknowledgment recorded on accept.

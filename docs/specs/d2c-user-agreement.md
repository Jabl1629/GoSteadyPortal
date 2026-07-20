# D2C User Agreement — plain-language draft + coach clauses

> **Status:** 🟡 Copy is DRAFT — **still needs a counsel skim** (Q11 in [ai-coach.md](ai-coach.md)) — but the `D2CAgreementPanel` clickwrap is **deployed to prod + dev** (setup/signup + every device claim/rotation) as of 2026-07-20. Entity/contact/governing-law match the published pages: GoSteady LLC, 3049 Lawrence Street, Denver, CO 80205, jace@gosteady.co, Colorado law.
> **What this is:** two things, not a replacement for the published legal pages.
> 1. **Part 1 — the plain-language agreement** shown at device setup and read aloud with the user during the demo (Q2 direction). Human words; ~6th-grade reading level; large-type friendly. It *summarizes and links to* the full legal pages — it does not replace them.
> 2. **Part 2 — coach clauses** to fold into the existing [terms.html](../../web/terms.html) and [privacy.html](../../web/privacy.html), which predate the AI coach and don't yet cover it.
> **Already published (leave as the authoritative long-form; update per Part 2):** Terms of Service, Privacy Policy, SMS Terms & Opt-In (all effective 2026-06-01).

---

## Part 1 — Plain-language agreement (read-together / setup screen)

> Written for the person using the walker or rollator, reading it themselves. A caregiver-Admin variant (household where a family member sets it up and the user may not have an account — [d2c.md](d2c.md), Q2b) is a follow-up. Each block is one plain idea; "Learn more" links go to the full legal pages.
>
> **Form factor — render it personalized.** The copy below is form-factor-neutral ("your walker or rollator," "your GoSteady device"). Since the portal already knows the actual `deviceType` (`walker_cap` \| `rollator_platform`, per DT-0), render the personalized wording where you can: show a rollator user just "rollator," and include **"steps"** only for `walker_cap` — rollators report distance, active time, and pace, not steps (a frame-mount has no lift-and-place impulse, ARCH §7.0 / §C52.2).

### Welcome to GoSteady

GoSteady is a small device that attaches to your walker or rollator. It notices how much you move around each day, so you — and the family members you choose — can see how your walking is going. Here's the plain-language version of what you're agreeing to. The full legal details are in our [Terms of Service](/terms.html) and [Privacy Policy](/privacy.html); we're happy to go through them with you.

**What GoSteady does**
Your GoSteady device measures how you get around — things like how far you go, how long you're active, and how quickly you move. It shows you and your chosen family a simple picture of your day and how it's trending.

**What it measures — and what it doesn't**
The device only senses *movement*. It has **no microphone, no camera, and no GPS** — it doesn't listen, watch, or track where you are.

**It's not a doctor, and it's not for emergencies**
GoSteady is a wellness and activity product. It is **not a medical device**, it can't diagnose or treat anything, and it does **not** detect falls or emergencies. **If you ever feel unwell, hurt, or unsafe, call 911 or a family member right away** — don't wait on the app.

**Meet Steady, your activity coach**
GoSteady includes **Steady**, an automated coaching feature.
- **Steady is an AI** — a computer program, not a person, and not a doctor or nurse.
- It's here to cheer you on and talk about your walking — **encouragement, not medical advice**.
- **No one is reading your chat with Steady as it happens.** It can't help in an emergency — call 911.
- **Steady remembers what you tell it** (like your goals) so it can be more helpful. You can **see, change, or delete** everything it remembers, anytime, in Settings.
- **You can turn Steady off** whenever you like.

**Text messages**
We'll text a code to your phone when you sign in, and — if you'd like — occasional notes about your activity. **Reply STOP** to any text to stop them. Message and data rates may apply. We **never** sell or share your number. ([SMS details](/sms-consent.html).)

**Who can see your information**
- **You.**
- **Family members you invite** — and only the ones you invite. You can add or remove them anytime.
- **GoSteady staff**, when we need to help you or fix a problem.
- **Companies that run the service for us** (like secure cloud storage and text-message delivery), under contracts that only let them help run GoSteady.

**We do not sell your information. Ever.**

**How we protect it and how long we keep it**
Your information is **encrypted** and access is limited. We keep it while you're using GoSteady, and you can **ask us to delete it** at any time.

**Your choices**
You're in control. You can invite or remove family, turn Steady off, stop the texts (reply STOP), ask us to delete your data, and stop using GoSteady whenever you want.

**This is an early product**
You're one of our first users — thank you. Features may change and improve as we go, and the service is provided "as is." Questions anytime: **jace@gosteady.co**.

**You should be 18 or older to set up an account.**

---

*(Acknowledgment — lean per Q2a: prominent, acknowledged, coach on by default.)*
> **[ Got it — I understand ]**
> By continuing you agree to the [Terms of Service](/terms.html) and [Privacy Policy](/privacy.html). Steady will be on; you can turn it off in Settings anytime.

*(Alternative gating form, if we choose explicit opt-in instead:)*
> ☐ I've read and agree to the Terms of Service and Privacy Policy.
> ☐ I'd like to use Steady, my activity coach. *(optional — you can turn it on later)*

---

## Part 2 — Coach clauses to fold into the published legal pages

> Paste-ready once counsel signs off. Bump both pages' effective dates when these land.

### 2a. Terms of Service — new section (suggest inserting after §5 "The device")

> **6. AI coaching feature ("Steady")**
> The Service includes **Steady**, an optional automated coaching feature that uses artificial intelligence to provide general encouragement and information about your walking activity. **Steady is informational and motivational only. It is not medical, health, financial, or legal advice, is not a substitute for professional judgment, and is not a licensed professional of any kind.** Steady is **not a person**, is **not monitored by a human in real time**, and is **not an emergency-response or medical-alert service** — in an emergency, call 911. Automated responses may be inaccurate, incomplete, or delayed; do not rely on them for any medical, safety, financial, or legal decision. To personalize responses, Steady uses your activity data and information you choose to share in conversations, and it maintains a memory of information you provide. You can view, edit, and delete Steady's memory of you, and turn Steady off, at any time in the app. You agree not to rely on Steady for any purpose for which it is not intended and not to use it to seek emergency help.

*(Renumber the current §§6–14 accordingly, or insert as §5a to avoid renumbering.)*

### 2b. Privacy Policy — edits

**§1 "Information we collect" — add a bullet, and scope the existing sensor sentence:**
> - **Coach conversation data:** if you use Steady, the messages you send to and receive from the coach, and a memory profile of information you choose to share (such as your goals or walking routines), stored to provide and personalize the feature.

Change the existing sensor sentence from *"it does not collect audio, images, or location/GPS"* to scope it to the device sensors (so it stays true alongside coach text, and ahead of any future voice feature):
> The device measures motion with onboard sensors; **the device** does not collect audio, images, or location/GPS. *(If you use Steady's text chat, the text of those conversations is collected as described above.)*

**§2 "How we use information" — add a bullet:**
> - Provide and personalize the **Steady** coaching feature, including generating responses and maintaining its memory of information you share.

**§5 "How we share information" — add a bullet:**
> - **With our AI provider** — coach conversations are processed by our cloud AI provider (Anthropic's Claude models, accessed through Amazon Web Services) **solely to generate the coach's responses**, under contracts that limit use to providing the service to us. Your conversations are **not used to train third-party AI models.**

**§6 "Data security & retention" — append:**
> Steady conversation data and coach memory are retained while the feature is in use and are deletable by you in the app; we delete or de-identify them when no longer needed to provide the Service.

**§7 "Your choices & rights" — add a bullet:**
> - View, edit, or delete what Steady remembers about you, and turn Steady off, in the app at any time.

### 2c. Form factor — genericize "walker cap" across both published pages

The published [terms.html](../../web/terms.html) and [privacy.html](../../web/privacy.html) describe the product as the **"GoSteady smart walker cap"** (Terms intro + §1/§5; Privacy intro + §1). **The trial is rollator-focused, so this is a live inaccuracy** — a rollator user is not wearing a "walker cap." Genericize the device noun in the same counsel-reviewed pass (e.g. *"the GoSteady smart cap or rollator platform"* on first use, then *"the GoSteady device"*), and make the metric examples form-factor-neutral (lead with distance/active-time/pace; treat "steps" as walker-specific). `sms-consent.html` already uses the neutral "walking aids" and needs no change.

---

## Reviewer notes / open items

- **Counsel skim required** before real users (Q11): SB 243 (CA) / GBL Art. 47 (NY) AI-disclosure + crisis-protocol posture, the coach clauses above, and the acknowledgment form (Part 1). We are fitness-framed, not companionship-framed, which keeps IL/UT mental-health-chatbot laws out of scope (§3 of [ai-coach.md](ai-coach.md)).
- **Crisis-protocol page (R7):** the published self-harm/crisis protocol referenced by SB 243 is a separate short page (988 referral + what the coach does when it detects self-harm language). Draft alongside the guardrail work (D7); link it from the coach's help menu.
- **Caregiver-Admin variant (Q2b):** who acknowledges when a family member sets up the device for a user who has no account, and how that user is informed. Follow-up.
- **Voice (C4):** when voice ships, revisit the Privacy Policy again — voice audio becomes collected data, and the "cap does not collect audio" scoping in §2b keeps the current text accurate in the meantime.
- **Rendering:** Part 1 becomes a Flutter setup screen (the D2C onboarding flow) and, optionally, a plain `web/welcome.html` companion page; Part 2 edits go into the existing `web/*.html` after sign-off.

## Changelog
- **2026-07-20** — **Agreement now shows on every device claim/rotation, not just first-time signup** (prod + dev). Previously the `D2CAgreementPanel` clickwrap rendered only on the "Create your account" screen, so an already-signed-in owner **rotating/claiming** a device skipped it (they took the "Claim this device" direct path). Now the panel renders above that claim button too — the claim button is the clickwrap — personalized to the device noun (walker/rollator). NOT shown on a plain sign-in (device changes are rare; a fresh acknowledgment per claim is cheap). `claim()` records the acknowledged `agreementVersion` server-side regardless (`d2c-claim/handler.py`). Also: the coach it references is now the **"activity coach"** (persona rename).
- **2026-07-18** — Genericized on form factor: "walker cap" → "GoSteady device," neutral attach verb, dropped walker-only "steps" from the metric examples (rollators report distance/active-time/pace); added a per-`deviceType` render note and a Part 2 item (2c) to genericize the same "smart walker cap" language in the published Terms/Privacy — the trial is rollator-focused.
- **2026-07-18** — Initial draft. Plain-language whole-product agreement for the setup/demo read-through + coach clauses for the existing Terms/Privacy. Authored after confirming the three published legal pages already exist (effective 2026-06-01) and identifying the coach coverage gap.

# AI Coach — Phase C2: Proactive Message (build spec)

> **Status:** 🔲 Ready to build (after C1) — spec drafted 2026-07-18. Second trial-scope subphase under [ai-coach.md](ai-coach.md); builds directly on [ai-coach-c1-text-chat.md](ai-coach-c1-text-chat.md).
> **Delivers:** Steady proactively writes **≤1 warm note per patient-local day** (target ~1:30 pm, configurable) when the user's own activity is event-worthy — celebrating streaks/personal-bests/positive trends, gently nudging on quiet stretches — landing in the C1 Coach-tab inbox card, with an **optional SMS teaser** via the existing verified toll-free number. **Deterministic triggers choose the moment; the LLM only writes the words** (umbrella D6).
> **Reuses:** C1's `CoachMessages` table (the reserved `INBOX#<date>` SK), C1 §6 safety policy (the copy passes the same guardrail lint), the C1 Coach tab (populates its empty note card). The engine is a **sibling of `behavioral-detector`** — same facility→patient iteration, local-hour gate, pure-function rules, conditional-PutItem dedupe, pause gate, run-summary.
> **Live from day 1, no pre-send gate** (umbrella D6/Q5): generated notes send immediately; the safety net is daily full-transcript review (Jace) + the kill switch, not a delivery queue.
> **Depends on:** C1 deployed; `behavioral-detector` (1C-slim) as the pattern source; `_shared/sms.py` + the `gosteady/{env}/twilio` secret. The SMS teaser additionally depends on the **net-new "coach messages" consent category** (§5.7) — portal-inbox-only delivery de-risks that dependency.

---

## 1. Overview

- **Phase:** C2 (second of C1–C3 trial scope)
- **Status:** Ready to build after C1
- **Umbrella:** [ai-coach.md](ai-coach.md) D6 (proactive engine), Q7 (channel/cadence/timing)

**What C2 delivers.** A new hourly Lambda **`coach-daily`** — a near-clone of `behavioral-detector`'s scaffolding — evaluates each active D2C patient once, when it is their local afternoon. It computes **positive-and-negative activity features** (pure functions, unit-tested like the 1C-slim rules), picks **at most one theme per day** by priority (celebrate > encourage > gentle-nudge), copywrites it with Opus 4.8 into 2–4 warm sentences ending in an open question, runs the C1 §6 guardrail lint, and writes it once to the `CoachMessages` inbox (`INBOX#<local-date>`, conditional PutItem). The C1 Coach tab's note card now shows it; replying flows into the existing C1 chat thread. An **optional SMS teaser** ("Your GoSteady coach noticed something good 👟 — see your note: <link>") sends via the verified toll-free number, gated on a new coach-messages SMS opt-in.

**Exit test (umbrella §7 C2).** On a real device, an unusually active stretch produces a morning/afternoon note that **cites the real numbers**, lands at patient-local ~1:30 pm **exactly once**, respects pause/prefs, and reads correctly on the phone.

**Explicitly NOT in C2:** goal-aware messages, tone toggle, weekly recap (all C3); voice/TTS (C4); quiet-hours (unnecessary — the fixed-afternoon gate is the quiet-hours guarantee, §3 C2-D6).

---

## 2. Locked-In Requirements (inherited — do not re-litigate)

| # | Requirement | Source |
|---|---|---|
| L1 | **Deterministic triggers choose the moment; LLM only writes the words.** Code computes features + selects the theme + supplies the numbers; the model writes prose only. | umbrella D6 |
| L2 | **≤1 proactive message per patient-local day**, event-worthy only; quiet stretches stay silent. Cadence ~every other day (min ~48 h gap). | umbrella Q7 |
| L3 | **Timing:** patient-local **~1:30 pm** (afternoon), a tunable config knob; A/B morning vs afternoon in the trial. | umbrella Q7 |
| L4 | **Channel:** portal inbox **+ optional SMS teaser** via the **existing verified toll-free number** (no 10DLC/TCR). SMS is its own explicit opt-in (Q2a), distinct from the in-app coach being on by default. | umbrella Q7/Q2a |
| L5 | **Paused patient ⇒ no proactive message** (`is_currently_paused`), same rule as alerts. | umbrella D6; `pause_check.py` |
| L6 | **Insufficient history ⇒ skip** (14-day cold-start guard, same as 1C-slim). | umbrella D6; `rules/types.py:79` |
| L7 | Copy passes the **same C1 §6 guardrail lint** (length, reading level, banned claims, identity, numerals-in-digest, contact hygiene). | C1 §6 |
| L8 | Every send **audited** (`coach.message.sent`); PII-free logs (no copy text in CloudWatch). | umbrella R11; T17 |
| L9 | **Kill switch** disables proactive sends per-user + globally without redeploy (shared `coachEnabled` with C1). | umbrella D6; C1 §5.9 |
| L10 | **Numbers come only from the deterministic digest** — the LLM never computes stats; the lint rejects numerals absent from the digest. | umbrella §9; C1-D4 |

---

## 3. Decisions specific to C2

| # | Decision | Why / grounding |
|---|---|---|
| C2-D1 | **`coach-daily` is a structural sibling of `behavioral-detector`, in `processing-stack.ts`.** Reuse `facility_iterator.list_facilities`, `patient_iterator.list_active_patients`, the lazy activity-window closures, `is_currently_paused`, and the conditional-PutItem shape — verbatim where possible. | Backend audit: these are the exact scaffolding pieces (`handler.py`, `facility_iterator.py:59`, `patient_iterator.py:28`). Zero reason to reinvent iteration. |
| C2-D2 | **Add a third hour-gate knob `COACH_LOCAL_HOUR` (default 13)** and an `evaluate_coach = (local_hour == coach_hour)` branch in the `rule_set_for_facility` shape. The exact-hour gate + hourly cron = the once-per-day cadence. | Mirrors `NO_ACTIVITY_LOCAL_HOUR=9` / `END_OF_DAY_LOCAL_HOUR=22` (`facility_iterator.py:37-38,120-152`; CDK `processing-stack.ts:388-390`). ~1:30 pm lands within the 1 pm local hour (gate is hour-precision). |
| C2-D3 | **Key features on `activeMinutes` universally** (the cross-device metric), NOT `primary_activity_metric(device_type)` (which returns `steps` for walkers). The coach is deliberately device-agnostic; rollators emit no steps. | Consistent with C1-D5; `activity-processor` guarantees `activeMinutes` on every row. Differs from `behavioral-detector`'s per-device primary metric on purpose. |
| C2-D4 | **Robust ≤1/day via a date-bucketed SK:** inbox SK = `INBOX#<facility-local YYYY-MM-DD>` (the SK C1 §5.1 reserved), conditional PutItem `attribute_not_exists`. This is ≤1/day independent of sub-hour re-fires (retries, DST fallback repeating the 1 pm hour) — stronger than behavioral-detector's second-precision SK. | Backend audit §4 flagged that the detector's daily-ness relies on the hour-gate + second-precision SK; date-bucketing makes it robust. Reuses the identical `ConditionExpression`. |
| C2-D5 | **≥48 h frequency cap** on top of daily idempotency: skip if a proactive message was written in the last ~2 days (query the newest `INBOX#` item). "Every other day, event-worthy only" (L2). | umbrella Q7 ("~every other day, min ~48 h gap"). |
| C2-D6 | **No quiet-hours needed.** The fixed local-afternoon gate means the send never lands in sleeping hours; quiet-hours does not exist in the repo and stays deferred. | SMS audit §4: quiet-hours deliberately deferred (`d2c-mockup-followups.md:34`). The hour-gate is the guarantee. |
| C2-D7 | **SMS teaser is best-effort, not fail-closed.** The inbox write is the source of truth; wrap `send_sms` in `try/except SmsSendError` and log-and-continue (do NOT fail the run or the inbox message). | Differs from care-circle (which hard-fails + deletes the invite on `SmsSendError`, `handler.py:352-364`) because for the coach the note already exists in the portal — SMS is only a nudge to open it. |
| C2-D8 | **SMS teaser is gated on a real, stored, per-category opt-in** (`coachSmsTeaser`), which is **net-new** — no per-category consent exists today (blanket opt-in only). Portal-inbox delivery ships first; the SMS teaser turns on once §5.7 lands. | SMS audit §3: one blanket opt-in, no stored flag; Q2a requires the teaser be an explicit opt-in category distinct from in-app. |
| C2-D9 | **`gait_speed_improvement` rule deferred** — there is no gait-speed feature in the current activity aggregation (`gaitSpeedFts` is on rows but never aggregated); it needs net-new input plumbing. Ship `above_typical_activity`, `improving_trend`, `streak_milestone` in C2; add gait later. | Backend audit §3: "no gait-speed feature anywhere in the current aggregation." |
| C2-D10 | **Coach audit events stay local literals** (`coach.message.sent`, `coach.daily.run`), consistent with C1, even though `behavioral-detector` uses `_shared/audit_catalog.py` constants. `emit_audit` only warns on unknown names. | C1 §5.8 chose the care-circle D13 local-literal convention; keep the coach family consistent. Trivial to switch to catalog registration if preferred. |

---

## 4. Current-state / the gap this closes

- **The engine scaffolding already exists** — `behavioral-detector` does facility→patient iteration, patient-local-hour gating, pure-function trend rules, cold-start guards, pause gating, conditional-PutItem dedupe, and a run-summary audit. C2 is that scaffolding **plus** positive rules, an LLM copywrite step, and a different write target (`CoachMessages` inbox instead of Alert History).
- **What's net-new:** the positive rule modules, the LLM copywrite (the repo's second Bedrock consumer — reuses C1's `_shared/coach_llm.py`), the date-bucketed inbox write, the SMS-teaser opt-in category + stored flag, and the `COACH_LOCAL_HOUR` knob. Everything else is reuse.
- **What would go wrong without this spec:** duplicate/again-and-again messages (solved by C2-D4/D5), a note that fires at 3 am (solved by the hour-gate), hallucinated numbers (solved by L10 + C1 §6 lint), or an SMS teaser that violates the "transactional, no marketing" consent posture (solved by §5.7).

---

## 5. Scope — BUILD NOW

### 5.1 `coach-daily` Lambda (`infra/lambda/coach-daily/`) — the engine

Hourly `ProcessingLambda` in `processing-stack.ts`, a sibling of `behavioral-detector`. Pure logic in `rules/` + selection helpers; all I/O (DDB, Bedrock, SMS) in the handler.

```
infra/lambda/coach-daily/
  handler.py            # iteration + orchestration (mirror behavioral-detector/handler.py)
  rules/
    types.py            # CoachTheme dataclass + priority + DEFAULT_* thresholds (mirror rules/types.py)
    above_typical.py    # positive: today/7d vs prior baseline (mirror below_typical.py, inverted)
    improving_trend.py  # positive: 7d vs prior-23d rising (mirror declining_trend.py, inverted)
    streak_milestone.py # positive: consecutive-active-day milestones
    quiet_nudge.py      # gentle: N quiet days (gentle framing, not the CRITICAL no_activity alert)
  selection.py          # message-worthiness: ≤1/day, ≥48h cap, priority pick (pure)
  copywrite.py          # builds the LLM prompt from theme + digest + memory; calls _shared/coach_llm
  teaser.py             # SMS body builder + opt-in check (pure body; send in handler)
  tests/
```

**Handler skeleton** (each step names the `behavioral-detector` pattern it reuses):

```python
def handler(event, _context):                       # ignore payload; wall-clock + DDB driven
    summary = {...}; _seen.clear()                  # run-summary + per-invocation dedupe set (bd handler.py:575-588)
    for facility in list_facilities(_orgs_tbl):     # facility_iterator.py:59 (unchanged)
        if facility.local_now.hour != COACH_LOCAL_HOUR:   # C2-D2 hour-gate
            summary["facilitiesSkipped"] += 1; continue
        for patient in list_active_patients(_patients_tbl, facility=facility):  # patient_iterator.py:28
            if not _coach_enabled(patient):         summary["killswitchSkipped"] += 1; continue   # C1 §5.9
            if is_currently_paused(patient):        _maybe_log_suppressed_paused(patient); summary["pausedSkipped"] += 1; continue  # bd:340
            hist = _history_per_day(patient)        # lazy closure → query_activity_history + aggregate_metric_per_day (activeMinutes)
            if len(hist) < MIN_HISTORY_DAYS:        summary["coldStartSkipped"] += 1; continue   # rules/types.py:79 idiom
            if _wrote_within_48h(patient):          summary["freqCapSkipped"] += 1; continue      # C2-D5
            theme = select_theme(compute_features(hist, today))   # selection.py — ≤1, priority (celebrate>encourage>nudge)
            if theme is None:                       summary["noThemeSkipped"] += 1; continue       # quiet day → silent (L2)
            copy = coach_llm.copywrite(theme, digest, memory)     # Opus 4.8 via C1 _shared/coach_llm
            copy = lint(copy, digest.allowlist)     # C1 §6 output lint (L7/L10); regenerate-once-then-drop
            if copy is None:                        summary["lintDropped"] += 1; continue
            _write_inbox(patient, copy, theme)      # conditional PutItem INBOX#<date> (C2-D4)
            _maybe_send_teaser(patient, copy)       # C2-D7 best-effort SMS, gated on opt-in (C2-D8)
            emit_audit("coach.message.sent", ...)   # local literal (C2-D10); counts/theme, NO copy text
            summary["messagesSent"] += 1
    emit_audit("coach.daily.run", action="observe", extra=summary)   # bd handler.py:634-639
```

### 5.2 Positive-trend rules (`rules/`, pure + unit-tested)

Mirror `below_typical.py` / `declining_trend.py` exactly — keyword-only `evaluate(*, ..., local_now_iso) -> Optional[CoachTheme]`, same cold-start guard idiom, consuming the same `history_active_min_per_day: list[int]` closure (C2-D3: `activeMinutes`).

| Rule | Fires when | Mirrors |
|---|---|---|
| `above_typical_activity` | today's `activeMinutes` `>` 7-day median × (1 + margin) | `below_typical.py:36`, inverted |
| `improving_trend` | `median(history[-7:]) > median(history[-30:-7]) × (1 + margin)` | `declining_trend.py:36`, inverted (needs ≥30 days) |
| `streak_milestone` | consecutive active-day run hits a milestone (3/5/7/14/…) | new (uses the zero-filled daily series) |
| `quiet_nudge` | ≥N quiet days AND device online — **gentle** framing, distinct from the CRITICAL `no_activity_today` alert | `no_activity_today.py`, softened |

`CoachTheme` (`rules/types.py`, mirror `AlertCandidate` frozen dataclass at `rules/types.py:41`): `theme_type`, `priority`, `event_timestamp_iso`, `data` (the numbers the copywrite may use — these become the lint allowlist). Thresholds/margins are `DEFAULT_*` constants here (not `_shared/thresholds.py`, which is battery/RSRP only).

### 5.3 Message-worthiness selection (`selection.py`, pure)

Code, not model (umbrella D6.3). Inputs = all fired `CoachTheme`s + the ≥48 h history flag. Output = `Optional[CoachTheme]`:
1. If any high-priority theme fired, pick by priority **celebrate > encourage > gentle-nudge** (weekly-recap is C3).
2. `None` if nothing fired (quiet day → silent, L2) or the ≥48 h cap trips (C2-D5).
3. Unit-tested against fixtures like the 1C-slim rules.

### 5.4 LLM copywrite + guardrail lint

- `copywrite.py` builds the prompt: **theme + the exact numbers from `theme.data` + the memory profile** → "2–4 warm sentences ending in an open question" (the "what's been motivating you?" pattern). Calls C1's `_shared/coach_llm.copywrite(...)` (Opus 4.8, Bedrock Mantle). Same fail-closed posture — but on LLM error the whole message is simply **skipped** (no inbox write), never a broken send.
- Output runs the **C1 §6 `lint.py`** unchanged (L7): the numerals-in-digest check (C1-D4/L10) is the anti-hallucination guarantee — the copy may only contain numbers from `theme.data`. Lint failure → one regenerate → else drop the message for the day (quiet is always safe).

### 5.5 Inbox write (`CoachMessages`, reuse C1 §5.1)

- Item: PK `patientId`, **SK `INBOX#<facility-local YYYY-MM-DD>`** (the reserved C1 SK), `role=coach`, `kind=proactive`, `text=<copy>`, `themeType`, `modelId`, `promptVersion`, `createdAt`, `expiresAt` (12-mo TTL).
- **Conditional PutItem** = verbatim behavioral-detector shape (`handler.py:220-238`): `ConditionExpression="attribute_not_exists(patientId) AND attribute_not_exists(#sk)"`; `ConditionalCheckFailedException → return False` (already-sent-today no-op, increments `alreadySentSkipped`). This is C2-D4's robust ≤1/day.
- The C1 Coach tab reads it via `getCoachInbox()` (the slot C1 left in place); a reply flows into the existing C1 chat thread (same `patientId`, `TURN#` SKs).

### 5.6 SMS teaser (`teaser.py` + handler send)

- **Body** (mirror `circle_logic.py:invite_sms_body`): plain f-string, `{D2C_APP_BASE_URL}/...` deep link to the Coach tab (no shortener — none exists), hardcoded `"Reply STOP to opt out."` footer. Draft: `"Your GoSteady coach noticed something good today 👟 See your note: {app_base_url}/coach  Reply STOP to opt out."`
- **Send** via `_shared/sms.py:send_sms(patient_phone_e164, body)` — reuse the sender, secret (`gosteady/{env}/twilio`), verified toll-free `from` (C2-D7 wiring: coach-daily needs its own `TWILIO_SECRET_ARN` env + `grantRead`). **Best-effort** (C2-D7): `try: send_sms(...) except SmsSendError: log + summary["teaserFailed"] += 1` — never fails the inbox write or the run.
- **Gated** on the §5.7 opt-in (C2-D8): skip the teaser entirely if `coachSmsTeaser` is not explicitly true. STOP/HELP is honored natively by Twilio (no webhook needed).

### 5.7 SMS "coach messages" consent category (net-new — the SMS-teaser gating dependency)

Today there is **one blanket SMS opt-in, no stored per-category flag** (SMS audit §3/§5). To make the teaser an explicitly-opted-into category (Q2a), C2 adds:
1. **Consent copy** — a "coach messages" category in [web/sms-consent.html](../../web/sms-consent.html) (currently two types: OTP + account/activity, framed "transactional … no marketing/promotional," effective 2026-06-01). The teaser is **motivational**, so the copy must carve out a distinct, clearly-optional category (not "transactional") — this is also the counsel-review touchpoint (umbrella Q11).
2. **A stored opt-in flag** `coachSmsTeaser: bool` on `Users.prefs.coach` (the same prefs map C3 uses for tone — SMS audit §6). Default **off** (opt-in, not opt-out).
3. **A toggle** in the Coach tab notification settings (§5.8) that writes the flag via the C3-introduced (or C2-minimal) `PATCH /coach/prefs` — or, if C2 ships before C3, a minimal coach-prefs write on `coach-api`.
4. **The send-time check** (§5.6): teaser sends only if `coachSmsTeaser == true`.

> **De-risk:** portal-inbox delivery needs none of §5.7. Ship inbox-only first; enable the teaser when the consent category + flag land. This matches umbrella Q7's "portal-only de-risks it."

### 5.8 Flutter — populate the inbox card + SMS toggle

- **`lib/d2c/screens/d2c_coach_screen.dart`** — the note card C1 left empty now renders today's `CoachInboxItem` (date, copy, "AI" glyph, feedback flag); tapping "reply" opens the C1 chat thread pre-scrolled. Reuse the C1 FutureBuilder host.
- **Repository:** implement the `getCoachInbox()` method C1 declared (mock returns a seeded note; live calls `GET /api/v1/d2c/coach/inbox`). Add `getCoachInbox` to `ApiClient`.
- **Settings:** a "Coach text messages" opt-in toggle (writes `coachSmsTeaser`) + a note that it's separate from the in-app coach. Mock-first (in-memory flag in `D2CMockRepository`).

### 5.9 Config (`infra/lib/config.ts` + `processing-stack.ts` env)

- Reuse `coachEnabled` (C1). Add tuning knobs as Lambda env (mirroring `NO_ACTIVITY_LOCAL_HOUR`): `COACH_LOCAL_HOUR` (default `13`), `COACH_MIN_GAP_HOURS` (default `48`), `COACH_HISTORY_DAYS` (`30`), `COACH_MODEL_ID`, `COACH_TRIAGE_MODEL_ID`. A/B morning-vs-afternoon (Q7) = flip `COACH_LOCAL_HOUR` between `8` and `13`.
- `coach-daily` gets `memoryMb: 512`, `timeoutSeconds: 60` (mirror `behavioral-detector`, `processing-stack.ts:365-394`).

### 5.10 Infra (`processing-stack.ts`)

- **Lambda + cron:** `new ProcessingLambda(this, 'CoachDaily', {...})` + `new events.Rule(this, 'CoachDailySchedule', { schedule: events.Schedule.rate(cdk.Duration.hours(1)), targets: [new events_targets.LambdaFunction(...)] })` — copy `BehavioralDetectorSchedule` (`:447-452`).
- **Grants:** `activityTable.grantReadData`, `patientsTable.grantReadData`, `organizationsTable.grantReadData`, `coachMessagesTable.grantReadWriteData`, `coachMemoryTable.grantReadData` (for the memory profile in copywrite), `identityKey.grantEncryptDecrypt` + `auditKey.grantEncryptDecrypt`.
- **Bedrock IAM:** the same `addToRolePolicy` `bedrock:InvokeModel` statement as C1 §5.10.
- **Twilio secret:** `d2cAuthStack.twilioSecret.grantRead(coachDaily.function)` + `TWILIO_SECRET_ARN` env (net-new for a processing-stack Lambda — the secret currently grants only to care-circle in api-stack; thread the reference into `ProcessingStack` props).

---

## 6. Out of scope — DEFERRED

| Deferred | Lands in | Additive because |
|---|---|---|
| Goal-aware proactive messages, warm/direct tone, weekly recap | **C3** | `coach-daily` selection already picks by priority — weekly-recap is one more theme + a day-gate; tone is a prompt param behind `coach_llm`; goals read from `CoachMemory` `GOAL#` items. |
| `gait_speed_improvement` rule | post-C2 | C2-D9: needs net-new gait aggregation plumbing; additive rule module. |
| Quiet-hours, general per-category notification matrix | deferred | C2-D6: the afternoon gate removes the need; the matrix is planned (`d2c.md:197-199`) but not required for one motivational category. |
| Voice / phone-call check-in / TTS read-aloud | **C4** | umbrella D8/D9. |

---

## 7. Interfaces + data (summary)

**New Lambda:** `gosteady-{env}-coach-daily` (hourly EventBridge, `processing-stack.ts`).
**New API:** `GET /api/v1/d2c/coach/inbox` (the C1-reserved route). SMS-teaser opt-in via `PATCH /coach/prefs` (`coachSmsTeaser`).
**Table:** reuses `CoachMessages` (C1 §5.1), new SK `INBOX#<local-date>`; reads `CoachMemory` (C1 §5.2) for the profile.
**Audit events:** `coach.message.sent`, `coach.daily.run` (run-summary), plus C1's on any reply.
**Env (coach-daily):** `COACH_ENABLED`, `COACH_LOCAL_HOUR`, `COACH_MIN_GAP_HOURS`, `COACH_HISTORY_DAYS`, `COACH_MODEL_ID`, `TWILIO_SECRET_ARN`, `D2C_APP_BASE_URL`, table names.
**Net-new consent:** "coach messages" category in `web/sms-consent.html` + `Users.prefs.coach.coachSmsTeaser` flag.
**Infra touched:** `infra/lib/config.ts`, `infra/lib/stacks/processing-stack.ts` (Lambda + cron + grants + twilio ref), `web/sms-consent.html`, `lib/d2c/*` (inbox card + toggle).

---

## 8. Testing

| # | Scenario | Method | Expected |
|---|---|---|---|
| T1 | Positive rules fire on fixture histories (above-typical, improving, streak) | Unit | Correct `CoachTheme`s; cold-start (<14 d) abstains |
| T2 | Selection picks ≤1 by priority; returns None on a quiet day; ≥48 h cap trips | Unit (`selection.py`) | One theme or silence, never two |
| T3 | Hour-gate: patient fires only in the `COACH_LOCAL_HOUR` local hour, across timezones | Unit/live | Exactly one eligible hour/day/patient |
| T4 | Conditional PutItem: two invocations same local day | Live | Second is a dedupe no-op (`INBOX#<date>` exists) |
| T5 | Copy cites only digest numbers; a hallucinated numeral is linted out | Unit + live | Lint drops/regenerates; no invented stats |
| T6 | Paused / killswitch / cold-start patients | Live | Skipped, counted in run-summary, no send |
| T7 | SMS teaser best-effort: inject `SmsSendError` | Live | Inbox note still written; run continues; `teaserFailed` counted |
| T8 | SMS teaser gated: `coachSmsTeaser` false | Live | No SMS; inbox only |
| T9 | End-to-end exit test (real device, active stretch) | Live | Note at local ~1:30 pm, once, real numbers, correct on phone |
| T10 | Run-summary audit `coach.daily.run` | Live | Counts present; no copy text in logs (T17) |

**Verification:** `python -m unittest discover infra/lambda/coach-daily/tests`; synthetic invoke of `coach-daily`; inspect `CoachMessages` for `INBOX#<date>`; `aws logs filter-log-events --log-group gosteady-dev-audit --filter-pattern '{ $.event = "coach.message.sent" }'`.

---

## 9. Open questions (C2-specific)

| # | Question | Lean |
|---|---|---|
| OQ-1 | **Above-typical / improving margins** — what % above baseline is "worth celebrating" without over-firing? | Start conservative (e.g. +25%); tune from trial transcripts, like the 1C-slim thresholds. |
| OQ-2 | **A/B morning vs afternoon** — run concurrently (split cohort) or sequentially? | Config-flip `COACH_LOCAL_HOUR`; split cohort if the trial N supports it (Q7). |
| OQ-3 | **Teaser copy vs "no marketing/promotional" consent language** — does the motivational category need counsel sign-off on `web/sms-consent.html`? | Yes — fold into the Q11 counsel review (§5.7). |
| OQ-4 | **Twilio secret into `processing-stack`** — thread `twilioSecret` via stack props, or duplicate the secret reference? | Thread via props (single source); mirror how api-stack receives d2cAuthStack. |
| OQ-5 | **Reply latency in the inbox** — replying to a note reuses the C1 non-streamed path; acceptable? | Yes (C1 L5); revisit with the C1 latency measurement (C1 OQ-4). |

---

## 10. Changelog

- **2026-07-19** — **C2 implemented** (backend + infra; Flutter in progress). `coach-daily` Lambda (`infra/lambda/coach-daily/`): D2C facility→patient iteration, `COACH_LOCAL_HOUR` gate, positive/gentle themes (above-typical / improving / streak-milestone / quiet-nudge) + weekly recap, ≤1/day conditional-PutItem `INBOX#<date>`, ≥48 h cap, copywrite via `_shared/coach_llm` + C1 §6 lint, best-effort opt-in SMS teaser. **14 unit tests pass.** Infra: `processing-stack.ts` coach-daily Lambda + hourly EventBridge + grants + Bedrock IAM + twilio secret ref; `cdk synth` clean; deployed to dev. **Safety guard: a `COACH_DAILY_ENABLED` env gate defaults the proactive sweep OFF** — it deploys dormant (no autonomous sends) until flipped to `true` after review. Also: `GET /api/v1/d2c/coach/inbox` added to coach-api; SMS "coach messages" opt-in category added to [web/sms-consent.html](../../web/sms-consent.html) (draft, pending counsel Q11). Generative copywrite is still Bedrock-model-access-blocked in dev (see C1 changelog — Jace console action).
- **2026-07-18** — Initial C2 build spec. Authored from the umbrella (D6/Q7) + C1 + a focused audit of `behavioral-detector` internals (facility→patient iteration, the `NO_ACTIVITY_LOCAL_HOUR` exact-hour gate, pure-function rules in `rules/`, the conditional-PutItem dedupe, pause gate, run-summary) and the SMS/consent surfaces (`_shared/sms.py` fail-closed sender, verified toll-free secret, blanket-only consent with no per-category flag, no quiet-hours). Key decisions: `coach-daily` as a `behavioral-detector` sibling (C2-D1); `COACH_LOCAL_HOUR` third hour-gate (C2-D2); device-agnostic `activeMinutes` features (C2-D3); date-bucketed `INBOX#<date>` SK for robust ≤1/day (C2-D4); ≥48 h cap (C2-D5); no quiet-hours needed (C2-D6); best-effort SMS (C2-D7) gated on a net-new "coach messages" opt-in category (C2-D8, §5.7); `gait_speed_improvement` deferred for lack of aggregation plumbing (C2-D9).

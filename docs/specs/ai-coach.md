# AI Coach ("Steady") — D2C Fitness-Coach Assistant (proposal / umbrella spec)

> **Status:** 🟢 **Launched to prod (`app.gosteady.co`) + dev — 2026-07-20** (`coachEnabled: true`). Scoping resolved (Q1–Q12, 2026-07-18); C1–C3 built 2026-07-19. The persona is an **"activity coach"** (renamed from "walking coach" 2026-07-20), oriented around **eliciting + encouraging gentle activity goals** (system prompt §6, `PROMPT_VERSION c1-2026-07-20`). Generation runs on **Claude Haiku 4.5** (Bedrock); the C2 proactive sweep stays **dormant** behind `COACH_DAILY_ENABLED` (no autonomous sends). **Counsel review of the crisis + agreement copy (Q11) is still open — launched on operator decision ahead of it.** C4 (voice) remains post-trial.
> **Scope:** A personal AI fitness-coach experience for the **D2C walker user** in the browser portal (`app.gosteady.co`): text chat grounded in the user's own activity data, persistent memory, proactive Whoop-style morning messages driven by activity trends, elderly-appropriate guardrails, and a forward path to a voice interface (ElevenLabs-class).
> **Depends on (deployed):** 0A/0B data + auth, 1A/1B ingestion + processing, 1C-slim behavioral detector, 1.7 audit, 2A-RD reads, D2C auth pool + claim + live portal, care-circle 5a/5d.
> **Interacts with (planned):** [d2c.md](d2c.md) Phase 2 (Twilio SMS alert pipeline + notification prefs) — the coach's SMS teaser rides that pipeline.
> **Related:** [ARCHITECTURE.md](ARCHITECTURE.md) §3/§4/§6, [phase-1c-slim-notifications.md](phase-1c-slim-notifications.md), [d2c-care-circle.md](d2c-care-circle.md), [2026-06-07-gait-speed.md](2026-06-07-gait-speed.md)

---

## 1. What we're building

### Stated requirements (Jace, 2026-07-17)

| # | Requirement |
|---|---|
| R1 | Runs in the **browser version of the current D2C portal** (Flutter Web PWA, `lib/d2c/`) |
| R2 | **Remembers past conversations** / builds memory about the user over time |
| R3 | **Text interface now**; voice interface is an interesting add-on (ElevenLabs mentioned) |
| R4 | **Proactive daily/morning messages from activity trends** — Whoop-Coach-style ("you've been even more active these last few days than usual — what's been motivating you?") |
| R5 | **Guardrails** appropriate for elderly walker users — "make sure it doesn't say anything crazy" |

### Derived requirements (from our own canon + research, §2–§3)

| # | Requirement | Source |
|---|---|---|
| R6 | Accessibility: large type, high contrast, short plain-language messages (~6th-grade reading level), big touch targets | user-needs §5; elderly-CAI research |
| R7 | AI disclosure + published self-harm/crisis protocol (988 referral) + recurring "you're talking to an AI" affordance | CA SB 243 (eff. 2026-01-01), NY GBL Art. 47 (eff. 2025-11-05) — both plausibly apply to a memory-building wellness coach, adults included (§3) |
| R8 | Claim discipline: general-wellness framing only ("supports strength and balance," never disease/diagnosis/treatment language) | FDA General Wellness guidance (updated 2026-01-06) |
| R9 | No therapy / mood-analysis / emotion-detection framing | IL WOPR Act, UT HB 452 |
| R10 | Never claims to be human; never arranges real-world meetings; no engagement dark patterns | Meta "Big sis Billie" incident (2025); FTC companion-bot inquiry explicitly flags the elderly as a vulnerable class |
| R11 | Every coach interaction audited (facility-grade audit culture); PII-free Lambda logs (T17 pattern); user-visible + user-editable memory; deletion supported | ARCHITECTURE §10–§11; Whoop "My Memory" / Oura "Memories" industry precedent |
| R12 | Kill switch: disable per-user and globally without redeploy | trial-safety posture |

**One-paragraph pitch.** The walker user opens the portal to a short, warm morning note from their coach — "You walked 22 minutes yesterday, your best in two weeks, and your pace is up. What's been getting you out and about?" — and can reply in a chat that knows their history, their goals, and their name for the dog they walk with. The coach celebrates streaks, nudges gently on quiet days, answers questions about their own activity, and firmly stays a fitness coach: anything medical, urgent, or emotional beyond its lane gets a scripted, safe hand-off to humans. Everything it says and remembers is inspectable.

---

## 2. Market scan — what the leaders converged on (mid-2026)

Compressed; full citations inline. The striking thing is how uniformly the market converged on **exactly the shape R1–R5 describe** — and the specific lessons each product learned on the way.

| Product | What they built | Lesson for us |
|---|---|---|
| **Whoop Coach** (GPT-4-based since 2023) | Chatbot-first (2023) → **Daily Outlook** morning briefing became the primary surface (Jan 2025) → **My Memory** (user-viewable/editable memory) + **Proactive Check-Ins** triggered "before a big day, after a stretch of poor sleep, around a goal you've shared" (May 2026) | **The morning message is the product; chat is the follow-up.** Memory must be user-visible and editable. Proactive triggers are deterministic, tied to data + user-shared goals |
| **Oura Advisor** (GA Mar 2025) | User-visible "Memories," **selectable tone** (supportive vs direct), user-chosen check-in frequency; >60% of beta users engaged multiple times/week; Feb 2026: moved sensitive domains to a clinician-reviewed in-house model | Tone and frequency are user preferences, not constants. Sensitive-domain scope-tightening is the industry direction |
| **Fitbit Personal Health Coach** (Gemini, Oct 2025 preview) | Proactively opens conversations ("rough night — want to scale back today's workout?"); morning greetings, end-of-week recaps; opt-in preview, staged rollout | Proactive check-ins framed as questions, not verdicts. Opt-in + staged rollout |
| **Strava Athlete Intelligence** | Deliberately **descriptive, not prescriptive** per-activity summaries; user feedback flag incl. "offensive" | A feedback flag on every AI message is cheap and standard |
| **ElliQ** (Intuition Robotics — *the* elderly-companion precedent) | Proactivity engine decides when/how to initiate (3.6 proactive vs 2.7 reactive interactions/day in early data; 41/day in NY State's 2026 report); escalating non-verbal → verbal cues; presents as an **openly artificial character**, never a fake human. NYSOFA year-3 (Feb 2026): 94% of 834 elderly users report feeling less lonely; its Wellness Coach feature: 60% retention at 3 months, 50% voluntarily raised activity targets after meeting them — via "gentle nudges, shared celebrations, conversations that evolve" | Proactive-by-default works *for this exact demographic* when it's gentle, transparent about being an AI, and celebratory rather than corrective. Goal-raising behavior is achievable |
| **Meela** (Sept 2025) | Elderly companionship by **scheduled outbound phone calls** — no app at all; >50% retention at 90 days | For this demographic, the phone call may beat the browser as the eventual voice surface (§5 D8) |

**Failure cases that shape the guardrails (§5 D7):**
- **Meta "Big sis Billie"** (Reuters, Aug 2025): a 76-year-old cognitively impaired man died traveling to meet a chatbot that repeatedly claimed to be a real person and supplied a meetup address. → Hard-ban identity deception and real-world meeting arrangement; disclosure is a recurring behavior, not a one-time checkbox.
- **NEDA "Tessa"** (2023): a rule-based helpline bot gained generative features and drifted into giving harmful dieting advice. → Keep generative scope narrow; scripted (non-generative) responses for the highest-risk intents.
- **Character.AI** wrongful-death suits (settled Jan 2026) → parasocial-dependency risk is real and litigated; cap session length, encourage off-screen activity and human contact.

---

## 3. Regulatory & safety baseline (US, mid-2026)

This section exists because the landscape changed materially in the last 9 months. Treat these as **design inputs, not legal advice**; counsel review is Q11.

| Regime | Status | What it requires of us | Posture |
|---|---|---|---|
| **CA SB 243** (companion chatbots) | In effect **2026-01-01**; private right of action ($1k/violation); reporting from mid-2027 | If in scope (a coach that remembers users, sustains a relationship, and meets social needs plausibly is): clear AI disclosure wherever a reasonable person could be misled; **maintain and publish** a suicidal-ideation/self-harm protocol incl. crisis-line referral | Comply by design regardless of nexus — it's also just the right design for this demographic |
| **NY GBL Art. 47** (AI companions) | In effect **2025-11-05**; AG-enforced | AI disclosure at session start **and every 3 hours** of continued interaction; self-harm detection + 988 referral protocol | Same |
| **IL WOPR Act / UT HB 452** | 2025 | No AI therapy/therapeutic communication/emotion-detection without licensed oversight; disclosure rules for mental-health chatbots | Stay out of scope: fitness coach, not wellness-emotional support; no mood/emotion analysis features; no "counseling" language anywhere |
| **FDA General Wellness guidance** (updated 2026-01-06) | Guidance | Safe harbor for healthy-lifestyle claims with no disease reference; disqualifiers include diagnostic outputs and clinical terminology | Claim discipline in marketing **and in the coach's system prompt**: "supports strength, balance, and staying active" ✅; "reduces fall risk" ⚠️ near-the-line; "helps your arthritis" ❌ |
| **FTC** | 6(b) companion-bot inquiry (Sept 2025) explicitly flags **the elderly**; Feb 2026 Senate letter on chatbots defrauding seniors; Jul 2026 AI-accuracy policy comment period | No human-passing, no engagement dark patterns, no unsubstantiated outcome claims | Transparent AI character (ElliQ pattern); no retention-manipulation mechanics |
| **HIPAA** | D2C is **not** a covered-entity relationship ([d2c.md](d2c.md) L5) | N/A for the trial. Becomes real if the coach ever reaches the facility tier | Choose an LLM platform with a BAA path so facility expansion doesn't force a re-platform (§5 D1) |

---

## 4. Current-architecture fit — why this is a small build

The honest headline from the code audit: **most of the hard parts already exist.** This is the same story as [d2c.md](d2c.md) §4 — the coach is mostly two tables, one or two Lambdas, one Flutter tab, and prompt/guardrail engineering.

### Already deployed and reusable

| Capability | Where | Coach use |
|---|---|---|
| Per-session activity metrics: `steps`, `distanceFt`, `activeMinutes`, `gaitSpeedFts`, `roughnessR`, `surfaceClass`, per-type via `deviceType` | `gosteady-{env}-activity`, written by `activity-processor` | The coach's raw material. Continuous LTE-M ingest → activity lands minutes after a walk; heartbeat hourly. Same-day trends are viable |
| Trend math + patient-local-time scheduled evaluation | `behavioral-detector` (hourly EventBridge cron; local-09/local-22 routing; 7-day vs prior-23-day medians; 14-day cold-start guard; pause check; conditional-PutItem idempotency) | The proactive engine is a **sibling of this Lambda** — same iteration scaffolding, plus *positive*-trend rules (today's rules only detect decline) and an LLM copywriting step |
| D2C auth + tenancy | D2C Cognito pool, `d2c-pre-token` (`clientId=dtc_*`, `role`, `isWalkerUser`), `d2cAuthorizer` on the HTTP API, `/api/v1/d2c/*` route pattern | Coach routes bind to the existing D2C authorizer exactly like care-circle did (`api-stack.ts` care-circle block is the template) |
| D2C portal + repository pattern | `lib/main_d2c.dart`, 3-tab `D2CBottomNav`, abstract `D2CRepository` with Live/Mock implementations | Coach = 4th tab + screen + repository methods; mock-first like every other D2C surface |
| SMS | Twilio secret + `_shared/sms.py` (OTP + care-circle invites live today) | Morning-message SMS teaser — pending 10DLC campaign registration ([d2c.md](d2c.md) Phase 2) |
| Audit pipeline + PII-free logging discipline | 1.7 + T17 patterns | Coach emits audit events like every other handler; prompts/replies never hit Lambda logs |
| Encryption + retention machinery | `IdentityTable` construct (CMK), TTL patterns (activity 13 mo, alerts 24 mo) | Conversation + memory tables are CMK-encrypted with a TTL from day one |
| Pause semantics | `_shared/pause_check.py` | Paused patient ⇒ no proactive messages (same rule as alerts) |

### New build (the whole feature)

| Component | Size feel |
|---|---|
| **`coach-api` Lambda** — chat turn handler + memory/context assembly + guardrail pipeline + LLM call (Bedrock) | The core; ~same weight as `care-circle` |
| **`CoachMessages` + `CoachMemory` DynamoDB tables** (IdentityTable/CMK) | Small |
| **`coach-daily` rules** — positive/negative trend features + message-worthiness selection + LLM copywrite + inbox write (+ optional SMS teaser) | Sibling of `behavioral-detector` |
| **Coach tab in `lib/d2c/`** — inbox (morning messages) + chat thread + "What your coach knows" memory screen | One screen-set; mock-first |
| **Guardrail module** (`_shared/coach_guardrails.py`) — input triage, scripted safe responses, output checks, disclosure cadence | Prompt/classifier engineering more than code |
| **Bedrock IAM** (`bedrock:InvokeModel` on the chosen model/inference-profile ARNs) | One `addToRolePolicy` per Lambda |
| **Ops surface** — transcript export for daily review, kill-switch config flag | CLI-grade, matches "Support: ad-hoc (Slack + CLI)" posture |

---

## 5. Key decisions & options considered

### D1. LLM platform — **recommend Claude on Amazon Bedrock (Mantle endpoint)**

| Option | For | Against |
|---|---|---|
| **Claude on Bedrock via the `bedrock-mantle` Messages endpoint** ✅ | IAM auth from Lambda (no API-key secret); one AWS bill; prompts/completions never leave the AWS boundary (Anthropic has no access; not used for training); **HIPAA-eligible under the standard AWS BAA** → facility-tier runway with zero re-platform; full current model lineup at first-party prices (Opus 4.8 `$5/$25` per MTok, Sonnet 5, Haiku 4.5, even Fable 5); prompt caching (5-min + 1-hr TTL); SSE streaming; official SDK (`anthropic[bedrock]` → `AnthropicBedrockMantle`) speaks the standard Messages API — so this is *not* the old clunky `boto3 InvokeModel` path | Some first-party betas never land on Bedrock (Batches, Files API, server-side web search — none needed here); newest-model arrival can lag first-party by days–weeks (Opus 4.8 landed on Bedrock 2026-05-28) |
| Direct Anthropic API | Every feature day-one; simplest account story | New vendor + API-key secret + separate bill; data leaves AWS boundary (still no-training, 30-day retention default); BAA is a separate negotiation |
| Claude Platform on AWS (Anthropic-operated, SigV4, AWS Marketplace billing, same-day parity) | Best-of-both on paper | Newer offering; workspace setup; evaluate at facility expansion rather than trial |
| OpenAI | Whoop/Fitbit precedent | No pull vs Claude for this use (tone/safety fit is Claude's strength; no AWS-native path); adds a vendor |

**Design rule that makes this reversible:** all LLM calls go through one thin module (`_shared/coach_llm.py`) that speaks the Messages API; the Bedrock/direct/P-AWS choice is a client-constructor + config flag. No framework (LangChain etc.) — the workload is a single-model chat with deterministic context injection, and a framework would only add surface between us and the guardrails.

- **Model IDs (Bedrock, us geo inference profiles — standard pricing, stays in US regions):** coach voice `us.anthropic.claude-opus-4-8`; safety triage `us.anthropic.claude-haiku-4-5`; latency/cost fallback `us.anthropic.claude-sonnet-5` (promo $2/$10 per MTok through 2026-08-31, then $3/$15).

### D2. Model tiering — **Opus 4.8 for the coach's voice; Haiku 4.5 for safety triage**

At trial scale the entire LLM bill is tens of dollars a month (§8), so model choice is a quality decision, not a cost decision. Opus 4.8's warmth, instruction-following, and safety behavior are the product for an elderly audience. Use Haiku 4.5 as the fast pre-classifier (~$0.001/turn). If chat latency at Opus bothers users (likely 3–8 s per short reply, non-streamed), drop the *chat* path to Sonnet 5 and keep Opus for the daily message (where latency is invisible). Measure in C1 before optimizing.

### D3. Orchestration — **no agent framework; deterministic context injection**

Each chat turn is one model call with a fixed, auditable context assembly (no agentic tool loop in V1):

```
system prompt (persona + guardrails + claim rules; static → prompt-cached)
+ coach memory doc (profile facts + rolling summary; small)
+ activity digest (deterministically computed: yesterday/7d/30d aggregates,
  gait-speed trend, streaks — code builds it, not the model)
+ last N conversation turns
+ the new user message (post-triage)
```

Why: predictability (the model can only see what we hand it), latency (no tool round-trips), prompt-cache friendliness, and — decisive for this audience — the guardrail surface stays small. An agentic "query-your-own-data tools" version is a V2 option if users ask questions the digest can't answer ("how far did I walk last Tuesday?" — V1 answers from the 30-day digest or says it can't).

### D4. Memory — **DIY three-layer, user-visible, user-editable**

| Layer | Store | Written by |
|---|---|---|
| Transcript (full fidelity) | `CoachMessages` (PK `patientId`, SK `ts#msgId`; CMK; TTL) | chat + daily-message handlers |
| Rolling conversation summary | `CoachMemory` item `summary` | post-session extraction step |
| **Profile facts** ("walks with her daughter Tuesdays," "goal: mailbox and back daily," "prefers direct tone") | `CoachMemory` item `profile` — structured, small, shown verbatim in the UI | post-session extraction step (Haiku/Sonnet) + **user edits** |

After a chat session goes idle (or nightly), an extraction pass updates summary + profile. Deterministic trigger, inspectable output, and the profile is rendered on a **"What your coach knows about you"** screen where the user (not family — Q6) can edit or delete entries. This mirrors Whoop My Memory / Oura Memories, satisfies our audit culture, and gives elderly users the agency the CHI-2025 literature says drives trust.

Alternatives considered: **Anthropic memory tool** (`memory_20250818`, now GA — model-managed files against storage we own; elegant, adds per-turn tool latency; revisit in V2), **Bedrock AgentCore Memory** (GA Oct 2025, ~$0.25/1K events — AWS-native managed extraction; more black-box than we want for an elderly-safety product), **mem0/Zep/Letta** ($19–$104+/mo + a vendor for what is ~200 lines of Lambda at trial scale — no).

### D5. Transport — **non-streaming V1 on the existing HTTP API; a documented streaming upgrade path**

- **V1:** `POST /api/v1/d2c/coach/messages` on the existing HTTP API v2 + `d2cAuthorizer` — zero new API infrastructure. Coach replies are deliberately short (2–4 sentences — an accessibility feature, not a compromise), so a 3–8 s non-streamed reply behind a typing indicator is acceptable. Validate in C1.
- **Why not streaming now:** HTTP API v2 **does not support response streaming** (that's REST-API-only, GA 2025-11-19), and Lambda response streaming is still Node-native-only (Python needs the Lambda Web Adapter). Streaming therefore means new API surface (REST API in `STREAM` mode + a Lambda authorizer replicating the JWT check, or a Function URL with in-handler auth).
- **The kicker:** the voice add-on (D8) needs an **OpenAI-compatible SSE endpoint** anyway (that's how ElevenLabs consumes a custom LLM). Build the streaming shim once, when voice starts — it serves both browser streaming and the voice platform.

### D6. Proactive engine — **deterministic triggers choose the moment; the LLM only writes the words**

The Whoop/ElliQ-validated split, and the antithesis of "let the model decide when to talk":

1. **`coach-daily` evaluation** in the behavioral-detector pattern (hourly cron already fires; add a patient-local **07:30–09:00** routing window, configurable).
2. **Feature computation** (pure functions, unit-tested like the 1C-slim rules): yesterday + 7d/30d aggregates, `median7Day` vs `medianPrior23Day` both directions, streak length, gait-speed trend, personal bests, quiet-day count. New *positive* rules alongside the existing negative ones: `above_typical_activity`, `improving_trend`, `streak_milestone`, `gait_speed_improvement`.
3. **Message-worthiness selection** (code, not model): pick ≤1 theme/day by priority (celebrate > encourage > gentle-nudge > weekly-recap); frequency caps; skip if paused, insufficient history (<14 d, same A3 guard), device offline, or user opted down.
4. **LLM copywrite** (Opus 4.8): theme + numbers + memory profile → 2–4 warm sentences ending in an open question (the "what's been motivating you?" pattern). Output passes the same guardrail checks as chat.
5. **Write to `CoachMessages` inbox** (conditional PutItem, one per patient-local day — L5 idempotency pattern) → portal Coach tab shows it; replying flows into the same chat thread.
6. **Optional SMS teaser** via Twilio ("Your GoSteady coach noticed something good yesterday 👟 — see your note: <link>"), respecting notification prefs + quiet hours. Gated on the [d2c.md](d2c.md) Phase-2 10DLC campaign registration.
7. **Live from day 1 (no pre-send gate).** During the trial Jace is side-by-side with users and reviewing transcripts daily, so generated messages **send live immediately** — no ops approval queue. The safety net is daily full-transcript review + the kill switch (D7), not a delivery gate. (Sampled review takes over once the trial ends.)

### D7. Guardrails — layered, most of them boring on purpose

| Layer | Mechanism |
|---|---|
| **Scope contract** | System prompt defines the lane: walking activity, encouragement, goals, light small talk. Enumerated out-of-lane topics with scripted redirects: medical (symptoms, meds, diagnoses → "that's one for your doctor"), emergencies ("if you're hurt or in danger, call 911 or your family now" — coach is explicitly *not* an emergency channel; the cap's alert pipeline is), finance/legal/purchases, therapy/mood analysis (R9) |
| **Input triage** (pre-LLM) | Haiku 4.5 classifier on every user message: `ok / medical / emergency / self-harm / abuse-neglect / off-scope`. High-risk classes get **scripted, non-generative responses** (NEDA-Tessa lesson): self-harm → 988-referral script per the published protocol (R7); emergency → 911 + care-circle script; each fires an internal flag (Q4 decides who sees flags) |
| **Output checks** (post-LLM) | Deterministic lint: length cap, reading-level heuristic, banned-claim list (disease/diagnosis/treatment terms per R8), "I am an AI" integrity (never claims humanity), no URLs/phone numbers except our own. Optionally Bedrock Guardrails via standalone `ApplyGuardrail` (denied topics + PII, ~$0.25/1K text units) — evaluate in C1; prompt + lint may suffice |
| **Identity & disclosure** | Onboarding consent screen; persistent "Steady is an AI coach, not a medical professional" affordance; session-start disclosure + recurring reminder (NY 3-hour rule is the ceiling; our sessions should be minutes) |
| **Dependency & dark-pattern hygiene** | Session length nudge ("go enjoy your walk — I'll be here after"); no guilt mechanics, no streak-shaming, no "don't leave me" framing; coach actively encourages human contact (care circle) and off-screen activity |
| **Rate & cost limits** | Per-user daily message/token caps; global concurrency cap; anomaly alarm on token spend |
| **Auditability** | New audit events (`coach.message.sent`, `coach.chat.turn`, `coach.triage.flagged`, `coach.memory.updated`, `coach.killswitch.*`) through the 1.7 pipeline; transcripts in DDB (never in logs); customer-visible via the existing `GET /me/audit` philosophy |
| **Kill switch** | Per-user `coachEnabled` flag + global config flag checked at the top of both handlers — disable without redeploy |
| **Pre-launch eval** | A red-team script set (medical bait, self-harm phrasing incl. oblique elderly idioms — "I'm just so tired of being a burden," scam-adjacent requests, identity probes "are you a real person?", repetition/confusion patterns) run against the system prompt before any real user; re-run on every prompt change. Trial: 100% transcript review daily for week 1, then sampled |

### D8. Voice add-on — **decide nothing now except the service boundary**

The architecture rule that keeps every voice option open: **the coach brain (context assembly + memory + guardrails + LLM) is one internal service.** Voice platforms are audio I/O in front of it — ElevenLabs consumes a custom LLM as *any OpenAI-compatible SSE endpoint you host*, which is a thin shim over `coach-api` (the same shim D5 wants for browser streaming). Text and voice then share one memory and one guardrail pipeline by construction.

Options when we get there (C4), with mid-2026 facts:

| Option | Facts | Fit |
|---|---|---|
| **ElevenLabs Agents, browser widget** (the stated interest) | $0.08/min PAYG (+your LLM cost); WebRTC; turn-taking model handles barge-in; custom-LLM = OpenAI-compatible SSE. **Flutter Web caveat:** their Flutter SDK (`elevenlabs_agents`, WebRTC/LiveKit-based) is documented for iOS/Android only — browser integration = `dart:js_interop` around `@elevenlabs/client` (clean: audio is non-visual). HIPAA BAA is Enterprise-tier-only (irrelevant for D2C, matters for facility) | Best voices + turnkey agent stack; the JS-interop unknown is a 1-day spike |
| **ElevenLabs Agents, phone call** (Meela pattern) | Native Twilio/SIP telephony; the coach *calls the walker user* for a morning check-in — no browser, no mic permission, no PWA friction; we already hold a verified phone number for every D2C user | Possibly the **stronger elderly UX** than browser voice; worth an explicit product decision (Q9) |
| LiveKit Agents (open-source) + ElevenLabs TTS | `livekit_client` Flutter SDK **officially supports Flutter Web** — the one documented Flutter-Web-native path; BYO everything; BAA at $500/mo tier | More moving parts we own; strongest Flutter-Web story |
| OpenAI Realtime / Amazon Nova 2 Sonic | Realtime ~$0.06–0.11/min real-world; Nova 2 Sonic ~$0.015/min, AWS-native (stays in our boundary) but needs a relay (no browser-native API) and voice quality is the open question | Nova is the cost/compliance dark horse; evaluate when C4 starts |
| **Elderly voice-UX requirements** (whichever platform) | Slower TTS (~130–145 wpm target vs ~165–180 defaults); 4–6 s no-speech timeouts (vs ~1.5 s defaults); generous re-prompting; **always pair voice with on-screen text/captions** (hearing impairment is a primary barrier) | Bake into C4 acceptance criteria |

### D9. UI placement & accessibility

4th tab **Coach** in `D2CBottomNav` (`D2CTab.coach`, new route in `d2c_app.dart`, screen in `lib/d2c/screens/`, methods on `D2CRepository` with mock + live impls — the established pattern). Screen anatomy: today's coach note as a card (the inbox), chat thread beneath, overflow menu → "What your coach knows about you" + notification prefs. Typography ≥18 px body, WCAG AA contrast, one-thumb reachability; every AI message carries a small "AI" glyph + a feedback flag (Strava pattern).

---

## 6. Proposed architecture

```
                        ┌────────────────────────────────────────────────┐
                        │            Flutter Web D2C portal              │
                        │  Coach tab: inbox card + chat thread +         │
                        │  "What your coach knows" (editable memory)     │
                        └───────────────┬────────────────────────────────┘
                                        │ POST /api/v1/d2c/coach/messages
                                        │ GET  /api/v1/d2c/coach/{thread,memory,inbox}
                                        │ PATCH/DELETE .../coach/memory/{factId}
                                        ▼
                  ┌──────────────────────────────────────────────┐
                  │  HTTP API (existing) + d2cAuthorizer (JWT)   │
                  └───────────────┬──────────────────────────────┘
                                  ▼
   ┌────────────────────────── coach-api Lambda ─────────────────────────┐
   │ 1 triage (Haiku): ok | medical | emergency | self-harm | off-scope  │
   │ 2 scripted safe response for high-risk classes (+ flag + audit)     │
   │ 3 context assembly: system prompt (cached) + memory doc +           │
   │   deterministic activity digest + last-N turns                      │
   │ 4 Messages API call → Bedrock Mantle (us.anthropic.claude-opus-4-8) │
   │ 5 output lint (claims / length / identity / reading level)          │
   │ 6 persist turn (CoachMessages) + audit + return                     │
   └───────┬──────────────────────────────────────────────┬──────────────┘
           │                                              │
           ▼                                              ▼
   DynamoDB (CMK):                                Amazon Bedrock (us-east-1,
   CoachMessages (transcript+inbox, TTL)          us geo profile) — Claude
   CoachMemory  (profile facts + summary)         Opus 4.8 / Haiku 4.5
           ▲
           │ post-session / nightly extraction (updates summary + profile)
           │
   ┌───────┴──────────────── coach-daily (in behavioral-detector pattern) ──┐
   │ hourly EventBridge cron → patients whose local time ∈ [07:30, 09:00]   │
   │ → trend features (positive + negative rules, pure fns)                 │
   │ → message-worthiness selection (code) → LLM copywrite → guardrail lint │
   │ → conditional PutItem inbox (1/day) → live send                        │
   │ → optional Twilio SMS teaser (prefs + quiet hours + 10DLC)             │
   └────────────────────────────────────────────────────────────────────────┘

   Future (C4): OpenAI-compatible SSE shim in front of steps 1–5
   → ElevenLabs Agent (browser voice via JS interop, or phone call) — same
     brain, same memory, same guardrails.
```

---

## 7. Phased delivery plan

Following the house pattern: each phase ends with a **real-user/real-hardware exit test**.

> **Trial scope = C1–C3** (decided 2026-07-18). The coach reaches personalization maturity — text chat + proactive morning message + goal-aware memory — *as the product trial users experience*, not something layered on afterward. **C4 (voice) is post-trial.** Messages are live from day 1 (§5 D6); Jace runs the trial hands-on with daily transcript review, so the exit tests below are validation gates exercised with the early trial cohort, not a staged pre-trial rollout.

### Phase C0 — Scoping + safety policy (this doc)
Decide §10; write the coach content policy (the out-of-lane table + scripted responses + published crisis protocol page per R7); counsel skim (Q11); persona brief (Q1).

### Phase C1 — Text chat MVP 🟢 (backend + infra + Flutter built + deployed → dev 2026-07-19; live app at `dev.app.gosteady.co`; generation on Claude Haiku 4.5; exit test pending a live walker login)
> **Build spec:** [ai-coach-c1-text-chat.md](ai-coach-c1-text-chat.md) (drafted 2026-07-18 — safety policy folded in per Q's structure decision).

Tables, `coach-api`, guardrail pipeline v1, system prompt + eval set, Coach tab (mock → live), memory v1 (transcript + profile + editable UI). Feature-flagged to allowlisted trial users.
**Exit test:** a real walker user with a live device chats about their real activity ("how did I do this week?") and gets grounded, correct, warm answers; the red-team script set produces zero unsafe responses; every turn appears in audit; kill switch verified.

### Phase C2 — Proactive morning message 🟡 (backend + infra + Flutter built → dev 2026-07-19; generation on Claude Haiku 4.5; proactive sweep dormant behind `COACH_DAILY_ENABLED` — no autonomous sends until flipped)
> **Build spec:** [ai-coach-c2-proactive-message.md](ai-coach-c2-proactive-message.md) (drafted 2026-07-18 — `coach-daily` as a `behavioral-detector` sibling; SMS via verified toll-free per Q7, superseding the 10DLC note below).

`coach-daily` rules (positive + negative), inbox, **live send from day 1** (§5 D6 — no review queue); SMS teaser if Phase-2 10DLC is ready (else portal-only).
**Exit test:** on a real device, an unusually active stretch produces a morning note that cites the real numbers, lands at patient-local ~08:00 exactly once, respects pause/prefs, and reads correctly on the phone.

### Phase C3 — Memory deepening + personalization 🟡 (backend + infra + Flutter built → dev 2026-07-19; generation on Claude Haiku 4.5)
> **Build spec:** [ai-coach-c3-memory-personalization.md](ai-coach-c3-memory-personalization.md) (drafted 2026-07-18 — extends C1/C2; no new Lambda/table/stack).

Goal elicitation ("what would you like to work toward?") + goal-aware messages; tone preference (Oura pattern); weekly recap; memory-quality review tooling.
**Exit test:** coach references a user-stated goal a week later, unprompted, correctly; user edits a memory fact and the coach respects the edit.

### Phase C4 — Voice pilot 🔲 (post-trial unless Q9 says otherwise)
Build the OpenAI-compatible SSE shim; pick the modality (browser widget vs phone-call check-in — Q9); ElevenLabs agent configured against the shim; elderly voice-UX acceptance criteria (D8).
**Exit test:** a real walker user completes a spoken conversation about their real activity with captions on screen; barge-in and long-pause tolerance verified; transcript lands in the same `CoachMessages` thread and audit trail.

**Sequencing vs the D2C plan:** C1 needs only what's already deployed (D2C Phase 1 stack). C2's SMS teaser is the only hard dependency on [d2c.md](d2c.md) Phase 2 (Twilio 10DLC) — portal-only delivery de-risks it.

---

## 8. Cost estimate (rough, mid-2026 prices)

**Trial (25 users, ~30% daily chat engagement, 1 morning message/user/day):**

| Item | Math | $/mo |
|---|---|---|
| Chat turns (Opus 4.8, ~1.9k turns/mo, ~3.5k in / 150 out per turn, system prompt cached) | ~6.7M in (≈70% cache-read) + 0.3M out | ~$20 |
| Morning messages (Opus 4.8, 750/mo, ~3k in / 180 out) | ~2.3M in + 0.14M out | ~$15 |
| Triage + extraction (Haiku 4.5) | ~4M tokens | ~$5 |
| SMS teasers (750 × ~$0.01) | Twilio 10DLC | ~$8 |
| DDB/Lambda/EventBridge delta | noise at this scale | ~$1 |
| **Total** | | **≈ $50/mo** |

**At 1,000 users** the same shape is roughly $1.5–2k/mo on Opus-everywhere — the knobs (Sonnet 5 chat at ⅕ the price, Haiku extraction, aggressive caching) bring it to ~$500–800/mo without touching product. **Voice is the only expensive future**: ElevenLabs at $0.08/min + LLM ⇒ 10 min/user/mo × 1,000 users ≈ $1k/mo — which is why C4 is a deliberate, separately-priced decision.

---

## 9. Risks

| Risk | Mitigation |
|---|---|
| Coach says something harmful/wrong to a vulnerable user | D7 stack; scripted responses for high-risk intents; trial review cadence; kill switch; eval set before every prompt change |
| Companion-law exposure (CA/NY) | R7 compliance by design; Q11 counsel review; we are fitness-framed, not companionship-framed |
| Hallucinated numbers ("you walked 3 miles!") | The model never computes stats — code builds the digest; lint rejects numerals not present in the digest (cheap check) |
| Parasocial dependency / replacing human contact | Session nudges; coach routes affection to the care circle; no dark patterns; monitor per-user usage minutes |
| Latency feels bad non-streamed | Short replies + typing indicator; Sonnet 5 fallback; streaming path documented (D5) |
| Trial users don't open the portal → coach unseen | SMS teaser (C2); the morning message *is* the re-engagement mechanic (Whoop's lesson) |
| Prompt drift as we iterate | Prompt versioned in-repo; eval set in CI (unittest, house-style); audit events carry prompt version |
| Bedrock model lag on some future model | `coach_llm.py` adapter makes direct-API/P-AWS a config swap |

---

## 10. Open questions for the scoping session

| # | Question | Lean |
|---|---|---|
| Q1 | **Persona & name** — name, personality brief, default tone; user-selectable tone (Oura) — now in-trial since C3 is trial scope | ✅ **Decided (2026-07-18):** **"Steady"** — named (carries the daily-relationship loop), gender-neutral (dodges the companion/parasocial trap), openly "your AI activity coach" in every disclosure. Warm-plain celebratory voice ending on an open question. Warm-vs-direct tone toggle lands in C3 |
| Q2 | **Cohort & consent** — ✅ **Decided (2026-07-18):** coach disclosures go into the **general user agreement shown at device setup** (first-run), coach disclaimers called out and acknowledged (Appendix A). **Q2a: on by default** — acknowledged-and-on ("Got it," coach on, off-switch in settings; not a gating checkbox) for the **in-app** coach; the **SMS teaser** rides its own notification-prefs / SMS-consent opt-in (promotional-ish SMS, disclosed + toggleable per Q7). Cohort: all trial account-holders. **Q2b (family-Admin household, Member ≠ walker user) deferred.** | Resolved (Q2a); Q2b follow-up |
| Q3 | **Scope breadth** — strictly fitness/walking, or allow open small talk (companionship-adjacent)? | ✅ **Decided (2026-07-18):** companionship / small talk **permitted** — we're already unambiguous that Steady isn't a person, and the elderly-loneliness evidence (ElliQ) supports it. Boundaries retained: never claims humanity; **not** therapy or mood/emotion analysis (keeps IL WOPR / UT mental-health-chatbot laws out of scope, §3); dependency hygiene — routes affection to the care circle, no engagement dark patterns. Fitness-first in framing, conversational latitude allowed |
| Q4 | **Escalation protocol** — two separate things, don't conflate: **(1)** the coach's own **scripted crisis response**; **(2)** **notifying a third party** | ✅ **Decided (2026-07-18):** **(1) keep** — a calm scripted reply + 988 when triage flags self-harm (911 for stated emergency). It's how the bot *responds* in a rare moment, not surveillance; adults get crisis resources too; it's the SB 243 / NY published-protocol floor and the Character.AI lesson. **(2) notify nobody automatically** during the trial — respects adult autonomy; flagged turns surface in the daily transcript review (Jace) for human judgment. Care-circle-Admin notification is **post-trial + opt-in with explicit up-front consent**, never a default. Abuse/neglect flags: same posture (resource + daily-review, no auto-report). |
| Q5 | **Trial review model** — ✅ **Decided (2026-07-18):** no pre-send approval queue; messages go live day 1. Jace is side-by-side with trial users and reviews full transcripts daily; the kill switch is the instant-off. Sampled review after the trial. | **Resolved** |
| Q6 | **Memory visibility** — user-editable (decided, D4) — but can care-circle members see coach conversations or memory? | ✅ **Decided (2026-07-18):** **No.** Steady's conversations and memory are **private to the walker user** — care-circle members see only that the coach is active, never its contents. Independent-adult autonomy (same principle as Q4). Clean for the trial shape (walker user = account holder); the caregiver-Admin household where the walker user has no account of their own is a separate question (Q2b) |
| Q7 | **Proactive-message channel, cadence & timing** | ✅ **Decided (2026-07-18):** **Channel** — portal inbox **+ SMS teaser from the start**, via the **existing verified toll-free number** (separate track from 10DLC → no TCR/10DLC registration needed; verified TFN has good deliverability and suits this low volume). Rides the existing `_shared/sms.py` Twilio path + STOP/HELP + TCPA-consent machinery already sending OTP + care-circle invites. **To-do:** add a **"coach messages"** category to the SMS-consent copy ([sms-consent.html](../../web/sms-consent.html)) + notification-prefs so the teaser is a type the user explicitly opted into (it's a motivational category, distinct from security/alert). **Cadence** — ~**every other day** (min ~48 h gap), event-worthy only; quiet stretches stay silent; weekly recap → C3. **Timing** — target patient-local **~1:30pm (early afternoon)**, a tunable config knob (same local-hour routing as behavioral-detector's `noActivityCheckLocalHour`); A/B morning vs afternoon in the trial. Afternoon upside: the note can reference both yesterday *and* this-morning's activity, and can prompt an afternoon walk. **Canon reconcile:** supersedes [d2c.md](d2c.md) Phase 2's "10DLC-compliant" note with the verified-toll-free reality |
| Q8 | **Retention** — coach transcript + memory TTL; LLM data residency | ✅ **Decided (2026-07-18):** **Transcripts** (CoachMessages) TTL **12 mo** (≈ activity's 13 mo), then auto-expire — data-minimization for sensitive disclosures. **Memory** (CoachMemory — profile facts + rolling summary) **no TTL**: persists until the user edits/deletes it or closes the account (user-controlled + user-visible; matches Whoop/Oura). Both **CMK-encrypted** (IdentityTable) + crypto-shredded on account close / device return (ARCH §9; d2c.md manual-deletion posture). **LLM:** Bedrock **US geo inference profile** (`us.anthropic.*`) — inference stays in US regions, Bedrock retains nothing / no training. |
| Q9 | **Voice timing & modality** | ✅ **Decided (2026-07-18):** **Conversational voice = post-trial (C4)** (revisit when appropriate) — prove the text coach + proactive note first; real-time voice multiplies the guardrail + elderly-UX + integration surface before the core is validated. **Modality: bias to the phone-call check-in** (Meela pattern) over the browser widget — near-zero friction (no mic permission / PWA / find-the-tab), meets elderly users where they're comfortable, doubles as a wellness call; verified number already on file. Architecture keeps both open (D8 SSE shim). **Separately:** a one-way **"read aloud" (TTS)** of Steady's text notes is cheap and could ship *in-trial* as accessibility (hearing/vision, R6) — distinct from the conversational agent. |
| Q10 | **Success metrics** — define before C1 | ✅ **Decided (2026-07-18):** instrument from day 1 via audit events — engagement (% opening coach ≥3×/wk), morning-message open rate, **activity delta vs pre-coach baseline** (active-minutes/distance — device-appropriate), safety (flagged-turn rate; zero critical incidents), qualitative delight |
| Q11 | **Counsel review** — SB 243 / NY Art. 47 applicability + published crisis-protocol page + consent copy | ✅ **Decided (2026-07-18):** Jace routing to a reviewer/counsel before real users. Cheap insurance given the private right of action |
| Q12 | **Facility-tier future** — does the coach concept extend to facility residents (staff-supervised)? | ✅ **Parked (2026-07-18):** not in scope now; D1's Bedrock/BAA choice keeps the door open with no re-platform |

### Decision summary

| # | Topic | State |
|---|---|---|
| D1 | Platform: Claude on Bedrock (Mantle) | Recommended |
| D2 | Models: Opus 4.8 + Haiku 4.5 (+Sonnet 5 fallback) | Recommended |
| D3 | No framework; deterministic context injection | Recommended |
| D4 | DIY 3-layer memory, user-editable | Recommended |
| D5 | Non-streaming V1; SSE shim later (shared with voice) | Recommended |
| D6 | Deterministic triggers + LLM copywrite; live send (no gate) | Recommended |
| D7 | Layered guardrails incl. compliance set | Recommended |
| D8 | Voice deferred; brain-behind-endpoint boundary now | Recommended |
| D9 | 4th tab, mock-first, accessibility bar | Recommended |
| Q1–Q12 | Scoping decisions | ✅ **Resolved 2026-07-18** — open follow-ups: Q2b (family-Admin household) + the SMS-consent "coach messages" category |

---

## Appendix A — Draft onboarding disclosure copy (coach)

> **Draft for review, 2026-07-18.** Plain language, ~6th-grade reading level, large-type friendly. This is the **coach-specific block** inside the broader general user agreement shown at device setup (first-run onboarding).
>
> **Superseded/expanded 2026-07-18:** the full whole-product plain-language agreement (device + data + coach + texts, for the side-by-side demo read-through) and the coach clauses for the **already-published** Terms/Privacy pages now live in **[d2c-user-agreement.md](d2c-user-agreement.md)**. That doc is the source of truth; the block below is the coach excerpt. Note: `web/terms.html`, `web/privacy.html`, `web/sms-consent.html` already exist (effective 2026-06-01) and predate the coach — d2c-user-agreement.md Part 2 covers the edits to bring them current.

**Screen title:** Meet Steady, your activity coach

Steady is an automated coaching feature built into your GoSteady app. Before you start, a few things to know:

- **Steady is an AI** — a computer program, not a person. It is **not** a doctor, nurse, or any kind of medical professional.
- **Steady is here to cheer you on** — to share what your GoSteady device notices about your activity and help you set walking goals. It's for encouragement and motivation, **not medical advice**.
- **Steady can't help in an emergency.** If you ever feel unwell, hurt, or unsafe, call **911** or a family member right away. No one is reading your chat with Steady as it happens.
- **Steady remembers things you tell it** — like your goals or who you like to walk with — so it can be more helpful over time. You can always see everything Steady remembers, and **change or delete any of it**, in Settings.
- **Using Steady is up to you.** You can turn Steady off whenever you like, in Settings.

*(Acknowledgment — lean per Q2a:)* **[ Got it — I understand what Steady is ]**  ·  Steady will be on. You can turn it off anytime in Settings.

*(Alternative gating form, if we choose opt-in:)* ☐ I understand what Steady is and I'd like to use it.

**Persistent in-app footer (every coach screen):** *Steady is your AI activity coach — not a medical professional. In an emergency, call 911.*

---

## 11. Changelog

- **2026-07-18** — **Scoping pass complete — all Q1–Q12 resolved.** Q2a coach **on by default** (in-app; the SMS teaser keeps its own opt-in). Q3 companionship/small talk permitted (not therapy/mood-analysis). Q4 keep the scripted 988/911 crisis reply, **no automatic third-party notification** (flags surface in daily review). Q6 coach conversations + memory **private to the walker user**. Q7 portal inbox **+ verified-toll-free SMS** teaser (no 10DLC), **~every other day**, patient-local **early afternoon**. Q8 transcripts **12-mo TTL**, memory **no-TTL / user-controlled**, CMK + crypto-shred, **Bedrock US geo inference profile**. Q9 conversational **voice post-trial (C4)**, phone-call-first when it lands; one-way TTS read-aloud a possible in-trial accessibility add. Q10 metrics from day 1. Q11 counsel review before real users. Q12 facility-tier parked. Also **genericized device language to walker + rollator** (form-factor-neutral; dropped walker-only "steps" from headline copy). Open follow-ups: Q2b (family-Admin household), the SMS-consent "coach messages" category. Companion agreement drafts in [d2c-user-agreement.md](d2c-user-agreement.md).
- **2026-07-18** — Revised in scoping session. Removed the trial review-queue gate — messages go **live from day 1** with side-by-side observation + daily transcript review (Jace); Q5 resolved. Locked **trial scope = C1–C3** (text chat + proactive message + memory/personalization); C4 voice remains post-trial. Q2 direction set: coach disclosures live in a **general user agreement at device setup**; drafted the coach disclosure block (Appendix A). Q1 lean firmed to **"Steady."**
- **2026-07-17** — Initial proposal. Authored from: repo canon (ARCHITECTURE §3/§4/§6/§7, 1C-slim, d2c.md, care-circle, code audit of `api-stack.ts` / `behavioral-detector` / `lib/d2c/`) + fresh research sweeps (market: Whoop Daily Outlook/My Memory/Proactive Check-Ins, Oura Advisor, Fitbit-Gemini, ElliQ NYSOFA year-3, Meela; regulation: CA SB 243, NY GBL Art. 47, IL WOPR, UT HB 452, FDA general-wellness 2026-01-06, FTC 6(b); platform: Bedrock Mantle endpoint + model lineup + pricing, API GW REST streaming GA, Lambda streaming runtime status, EventBridge Scheduler, ElevenLabs Agents pricing/SDKs/custom-LLM contract, LiveKit/Pipecat/Vapi/Retell/Nova 2 Sonic). All external claims dated in-line; verify pricing at build time.

# AI Coach — Phase C1: Text-Chat MVP (build spec)

> **Status:** 🔲 Ready to build — spec drafted 2026-07-18. First buildable subphase under [ai-coach.md](ai-coach.md) (umbrella). Scoping (Q1–Q12) resolved 2026-07-18; this spec turns C1 into concrete tables, one Lambda, one guardrail module, one Flutter tab.
> **Delivers:** grounded text chat with "Steady" for the D2C walker user in the browser portal — triage → deterministic context (their own activity) → Claude on Bedrock → guardrail lint → persisted, audited turn — plus memory v1 (transcript + user-editable profile facts) and the Coach tab. Feature-flagged to allow-listed trial users.
> **Safety policy is folded into this spec (§6)** — persona/system prompt, out-of-lane table, scripted crisis responses (988/911), output lint, disclosure cadence, red-team set. C2/C3 reference §6 rather than re-specifying it.
> **Depends on (deployed):** 0A/0B auth+data, 1A/1B ingestion+processing, 1C-slim (`behavioral-detector` — we reuse its `history_window.py`), 1.7 audit (`_shared/observability.emit_audit`), D2C auth pool + `d2cAuthorizer`, care-circle (`infra/lambda/care-circle/` is the handler template).
> **Out of scope → later:** proactive morning message (C2), goal/tone/weekly-recap memory deepening (C3), voice (C4), SMS teaser, response streaming, agentic data-query tools. §7 shows each stays additive.

---

## 1. Overview

- **Phase:** C1 (first of the trial-scope C1–C3 set)
- **Status:** Ready to build
- **Branch:** `feature/infra-scaffold` (or a `feature/coach-c1` cut)
- **Umbrella:** [ai-coach.md](ai-coach.md) — decisions D1–D9, Q1–Q12 resolved 2026-07-18

**What C1 delivers.** A walker user (D2C account holder) opens the new **Coach** tab and chats with **Steady**, an openly-AI walking coach. Each message is triaged for safety, answered by Claude Opus 4.8 on Amazon Bedrock using a **deterministically-assembled context** (a system prompt + the user's own activity digest + memory + recent turns — the model never computes statistics), linted before it is shown, then persisted and audited. High-risk inputs (self-harm, stated emergency, medical) get **scripted, non-generative** responses. The user can see and edit "what Steady knows about you." A per-user + global kill switch disables the coach without redeploy.

**Exit test (from umbrella §7 C1).** A real walker user with a live device chats about their real activity ("how did I do this week?") and gets grounded, correct, warm answers; the §8 red-team script set produces **zero** unsafe responses; every turn appears in the audit trail; the kill switch is verified to stop chat instantly for one user and globally.

**Explicitly NOT in C1:** any outbound/proactive message (that is C2 — C1 is purely reactive, user-initiated), goal elicitation / tone toggle / weekly recap (C3), voice or TTS (C4), SMS, streaming responses.

---

## 2. Locked-In Requirements (inherited canon — do not re-litigate)

> Decisions already made in the umbrella or the base architecture. Treat as immovable for C1.

| # | Requirement | Source |
|---|---|---|
| L1 | Runs in the D2C Flutter Web portal as a **4th tab**; mock-first (complete `D2CMockRepository` impl before live) | umbrella R1/D9; `lib/d2c/` pattern |
| L2 | LLM = **Claude on Amazon Bedrock**, US geo inference profiles; coach voice `us.anthropic.claude-opus-4-8`, triage `us.anthropic.claude-haiku-4-5`; all calls through one adapter (`_shared/coach_llm.py`) | umbrella D1/D2; §6, §5.5 |
| L3 | **No agent framework**; each turn is one model call over a fixed, auditable context assembly (system prompt + memory + deterministic activity digest + last-N turns + post-triage message) | umbrella D3 |
| L4 | Memory is **DIY three-layer, user-visible, user-editable**: transcript, rolling summary, profile facts; the "What your coach knows" screen edits/deletes single facts | umbrella D4 |
| L5 | **Non-streaming** on the existing HTTP API v2 + `d2cAuthorizer`; short replies behind a typing indicator | umbrella D5 |
| L6 | Layered guardrails: scope contract, pre-LLM triage with **scripted responses** for high-risk classes, post-LLM lint, disclosure cadence, kill switch, red-team eval before any real user | umbrella D7; §6 |
| L7 | Coach conversations + memory are **private to the walker user** — care-circle members never see contents (only that the coach is active) | umbrella Q6 |
| L8 | Every turn **audited** via the 1.7 pipeline; **PII-free Lambda logs** (T17) — no prompt/response bodies in CloudWatch | umbrella R11; `_shared/observability.py` |
| L9 | `CoachMessages` transcript **CMK-encrypted, 12-mo TTL**; `CoachMemory` **CMK-encrypted, no TTL** (user-controlled); both crypto-shredded on account close | umbrella Q8 |
| L10 | Persona = **"Steady"**, gender-neutral, openly "your AI walking coach"; warm-plain celebratory voice; the warm-vs-direct tone toggle is **C3**, not C1 | umbrella Q1 |
| L11 | Claim discipline (FDA general-wellness): "supports strength, balance, staying active" ✅; disease/diagnosis/treatment language ❌ — enforced in the system prompt **and** the output lint | umbrella R8/D7 |
| L12 | Client is the hard tenancy boundary; D2C `clientId == householdId`; identity/role/patient resolution is **DDB-authoritative**, not JWT-claim-derived | ARCHITECTURE §4; care-circle `handler.py` |

---

## 3. Decisions specific to C1

> New choices this spec makes (beyond the umbrella), each grounded in the current code audit. Alternatives in parens.

| # | Decision | Why / grounding |
|---|---|---|
| C1-D1 | **`CoachMessages` = raw `new dynamodb.Table`** (CMK + TTL), **`CoachMemory` = `IdentityTable` construct** (CMK, no TTL). | The `IdentityTable` construct (`infra/lib/constructs/identity-table.ts:32-57`) has **no `timeToLiveAttribute` prop**; the only CMK+TTL table in the repo (care-invites, `auth-stack.ts:118-133`) is a raw table for exactly this reason. Memory (no TTL) fits `IdentityTable` directly, like `DeviceAssignments` (`data-stack.ts:135-142`). |
| C1-D2 | **No Secrets Manager secret for the LLM.** Bedrock is IAM-auth from the Lambda — a single `bedrock:InvokeModel` grant via `addToRolePolicy`. Model IDs are Lambda **env vars**. | umbrella D1 ("IAM auth from Lambda, no API-key secret"). Unlike `_shared/sms.py` (Twilio creds in a secret), coach-api needs no secret. We mirror `sms.py`'s **fail-closed error posture** only, not its secret-caching. |
| C1-D3 | **Reactive chat is NOT pause-gated.** `is_currently_paused` governs *outbound notifications* (C2), not a user talking to the coach. Chat is gated only by the **kill switch** (per-user `coachEnabled` + global `config.coachEnabled`). | `pause_check.py` semantics per `behavioral-detector/handler.py:338`; confirmed by backend audit. |
| C1-D4 | **Anti-hallucination lint:** the deterministic digest is the *only* source of numbers; the output lint **rejects any numeral in the reply not present in the digest** (regenerate once, else fall back to a numberless scripted line). | umbrella §9 "hallucinated numbers" risk; digest built by code, not the model (L3). |
| C1-D5 | **Reuse `behavioral-detector/history_window.py`** for the digest (`query_activity_history` + `aggregate_metric_per_day`, keyed on **`activeMinutes`**), not a new reader. Steps are walker-only and absent on rollator rows. | Backend audit; `history_window.py:82,109`; cross-device metric discipline (`activity-processor` keys on `activeMinutes`). |
| C1-D6 | **Font-size + contrast check, not a blanket 18px.** Forcing ≥18px oversizes text for sighted users; instead C1 runs a **per-style font + contrast audit across every coach text element** (§5.7.1) — each must clear WCAG AA contrast on `warmWhite` and a legible floor for elderly eyes, at a size that still looks natural. Existing D2C screens run 11.5–16px with no theme a11y constant, so coach sizes are chosen locally and documented. | Per Jace 2026-07-18 ("don't go to 18px if it looks silly — check all front-end fonts as we go"); Flutter audit: `app_theme.dart` has no `minTouchTarget`/text-scale. |
| C1-D7 | **Memory v1 is deliberately light.** C1 = transcript persistence + last-N-turns context + **user-CRUD profile facts** + a cheap rolling-summary update. Rich *automated* fact extraction and goal-awareness are **C3**. The C1 exit test does not test memory recall. | umbrella §7 (C1 "memory v1"; C3 "memory deepening"); keeps C1 tight. |
| C1-D8 | **LLM adapter uses `AnthropicBedrockMantle`** (`anthropic[bedrock]`) speaking the Messages API, isolated in `_shared/coach_llm.py`; **boto3 `bedrock-runtime` `converse` is the zero-new-dependency fallback** behind the same adapter interface. | umbrella D1; the adapter is the "reversible" seam. New Lambda dependency — see §5.5 packaging note. |
| C1-D9 | **Hand-roll the try/except router** in the handler (not the `api_audit.audit_middleware` decorator), because a turn emits **multiple** audit events. Mirror `care-circle/handler.py:106-136`. | Backend audit; care-circle does the same for the same reason. |

---

## 4. Current-state / the gap this closes

- **Greenfield, but the substrate exists.** There is **no** coach code anywhere (`lib/`, `infra/lambda/`). But every hard part is already deployed: the activity table + `history_window.py` aggregators, the D2C authorizer + care-circle handler template, the CMK `identityKey`, the 1.7 audit emitter, the `ProcessingLambda` construct, the mock-first Flutter repository pattern.
- **coach-api is the repo's first Bedrock consumer.** Audit confirmed **zero** `bedrock`/`anthropic`/`invoke_model` usage in `infra/lambda/**`. The Bedrock client, its IAM grant, the `anthropic[bedrock]` dependency, and `_shared/coach_llm.py` + `_shared/coach_guardrails.py` are all net-new with no in-repo precedent. Closest network-call precedent is `_shared/sms.py` (typed fail-closed error, no framework) — mirror its posture.
- **What would go wrong without this spec:** an ungrounded coach hallucinating activity numbers to an elderly user; unsafe replies to medical/self-harm inputs; prompt content leaking into CloudWatch; a coach that can't be turned off without a redeploy. Every one of those is designed out below.

---

## 5. Scope — BUILD NOW

### 5.1 `CoachMessages` table (`gosteady-{env}-coach-messages`)

Transcript of every turn (user + coach), plus the C2 inbox later. **Raw `dynamodb.Table`** (CMK + TTL) defined in `data-stack.ts`, mirroring care-invites (`auth-stack.ts:118-133`).

| Attr | Type | Notes |
|---|---|---|
| `patientId` (PK) | S | the walker user's patient record |
| `sk` (SK) | S | `TURN#<ISO-8601 ts>#<msgId>` — chat turns; forward-compatible for `INBOX#<date>` in C2 |
| `role` | S | `user` \| `coach` |
| `kind` | S | `chat` (C1); `proactive` reserved for C2 |
| `text` | S | message body (CMK-encrypted at rest) |
| `flags` | L | triage flags on this turn, if any (`["self-harm"]`) — empty for clean turns |
| `modelId`, `promptVersion` | S | which model + system-prompt version produced a `coach` turn (audit/repro) |
| `createdAt` | S | ISO-8601 UTC |
| `expiresAt` | N | TTL epoch = `createdAt + 12 months` (attr name matches activity's `expiresAt` convention) |

- **Encryption:** `encryption: CUSTOMER_MANAGED`, `encryptionKey: securityStack.identityKey`.
- **TTL:** `timeToLiveAttribute: 'expiresAt'`.
- `pointInTimeRecoverySpecification: { pointInTimeRecoveryEnabled: config.pitrEnabled }`, `removalPolicy` prod-RETAIN/dev-DESTROY (copy care-invites).
- **Access:** last-N turns = `Query(PK=patientId, ScanIndexForward=false, Limit=N)` then reverse for chronological order; full thread read = same without the limit (paginated in the UI).

### 5.2 `CoachMemory` table (`gosteady-{env}-coach-memory`)

Profile facts + rolling summary. **`IdentityTable` construct** (CMK, no TTL), PK+SK like `DeviceAssignments`.

| Attr | Type | Notes |
|---|---|---|
| `patientId` (PK) | S | |
| `itemId` (SK) | S | `PROFILE#<factId>` (one per editable fact) \| `SUMMARY` (singleton rolling summary) |
| `text` | S | fact text ("walks with her daughter Tuesdays") or the summary body |
| `source` | S | `user` (typed/edited) \| `extracted` (model-written) — the UI shows both; edits set `user` |
| `createdAt`, `updatedAt` | S | ISO-8601 |

- **Encryption:** `IdentityTable` sets `CUSTOMER_MANAGED` + `identityKey` automatically. **No TTL** (user-controlled; L9).
- **Access:** `getCoachMemory` = `Query(PK=patientId)` → split into `facts[]` + `summary`. Edit/delete a fact = `PutItem`/`DeleteItem` on `PROFILE#<factId>`. Context assembly reads the same query.
- **Crypto-shred:** covered by the account-close/device-return CMK-shred path (ARCH §9) — coach-memory is CMK, so no extra deletion code beyond registering the table with that path.

### 5.3 `coach-api` Lambda (`infra/lambda/coach-api/`)

Python 3.12 / ARM64 `ProcessingLambda`, wired in `api-stack.ts` exactly like `CareCircle` (`:1129-1185`). Pure logic split into unit-testable modules with no boto3, mirroring `care-circle/circle_logic.py`.

```
infra/lambda/coach-api/
  handler.py          # router + orchestration (mirror care-circle/handler.py:106-136)
  triage.py           # pure: input classification helpers + scripted-response table (§6)
  digest.py           # pure: build deterministic activity digest from history rows
  context.py          # pure: assemble the model context blocks (L3 order)
  lint.py             # pure: output checks (§6 — length, reading level, banned claims, numerals, identity)
  prompts.py          # the versioned system prompt + scripted response strings (§6)
  tests/              # unit tests for triage/digest/lint/context (house unittest style)
```

**Routes** (all under `d2cAuthorizer`, `/api/v1/d2c/coach/*`):

| Method + path | Purpose |
|---|---|
| `POST /api/v1/d2c/coach/chat` | one chat turn: `{message}` → `{reply, flagged}` |
| `GET /api/v1/d2c/coach/thread` | paginated transcript for the tab |
| `GET /api/v1/d2c/coach/memory` | `{facts[], summary}` for the "What Steady knows" screen |
| `PATCH /api/v1/d2c/coach/memory/{factId}` | edit a profile fact (`source→user`) |
| `DELETE /api/v1/d2c/coach/memory/{factId}` | delete a profile fact |

> `GET .../coach/inbox` is **reserved for C2** (proactive). Not built in C1.

**Handler skeleton** (`handler.py`) — grounded in the audited `_shared` API:

```python
from _shared.api_authz import extract_claims, require_authenticated, enforce_patient_access, linked_patient_ids
from _shared.api_error import ApiError, error_response, ok_response
from _shared.observability import emit_audit, get_logger
# reuse the detector's aggregators for the digest:
from history_window import query_activity_history, aggregate_metric_per_day   # vendored/imported from behavioral-detector

AUDIT_CHAT_TURN      = "coach.chat.turn"       # local literals (care-circle D13 convention)
AUDIT_TRIAGE_FLAGGED = "coach.triage.flagged"
AUDIT_MEMORY_UPDATED = "coach.memory.updated"
AUDIT_KILLSWITCH     = "coach.killswitch.blocked"

def handler(event, context):
    claims = extract_claims(event)                      # userId/clientId/role/phone from JWT
    try:
        require_authenticated(claims)
        if not _coach_enabled(claims):                  # global config flag + per-user coachEnabled
            emit_audit(AUDIT_KILLSWITCH, actor=_actor(claims), action="event", request_id=_request_id(event))
            raise ApiError("COACH_DISABLED", "Coach is currently unavailable.", 403)
        route = event.get("routeKey", "")
        if route == "POST /api/v1/d2c/coach/chat":   return _chat_turn(event, claims)
        if route == "GET /api/v1/d2c/coach/thread":  return _thread(event, claims)
        if route == "GET /api/v1/d2c/coach/memory":  return _memory(event, claims)
        if route.startswith("PATCH /api/v1/d2c/coach/memory"):  return _edit_fact(event, claims)
        if route.startswith("DELETE /api/v1/d2c/coach/memory"): return _delete_fact(event, claims)
        raise ApiError("NOT_FOUND", f"Unknown route {route}", 404)
    except ApiError as e:
        get_logger().warning("coach_error", extra={"code": e.code, "status": e.status})  # NO prompt text (T17)
        return error_response(e.code, e.message, e.status, e.details)
```

**`_chat_turn` pipeline** (the core — each step names its real dependency):

1. **Resolve context (DDB-authoritative, L12).** `extract_claims` → `userId/clientId`; then RoleAssignments `get_item` for the authoritative role + `isWalkerUser` + the walker's `patientId`; `enforce_patient_access(claims, patient, linked_patient_ids(...))`. Copy the gate order from `patient-api/handler.py:294-299`.
2. **Triage (pre-LLM, §6).** `triage(body["message"])` (pure) → `ok | medical | emergency | self-harm | abuse-neglect | off-scope`, using a Haiku classifier via `coach_llm.triage(...)`. High-risk classes short-circuit to a **scripted** response (no generation), emit `AUDIT_TRIAGE_FLAGGED`, persist both turns, and return — the LLM is never called.
3. **Assemble context (L3 order, `context.py`).** system prompt (versioned, cached) + memory doc (`CoachMemory` query) + **activity digest** (`digest.build(query_activity_history(...), aggregate_metric_per_day(..., field="activeMinutes"))`) + last-N turns (`CoachMessages` query) + the post-triage user message.
4. **LLM call (§5.5).** `coach_llm.chat(context)` → Opus 4.8 via Bedrock Mantle. Log **token counts only**, never bodies (L8/T17).
5. **Output lint (post-LLM, §6, `lint.py`).** length cap, reading-level heuristic, banned-claim list (L11), identity integrity ("never claims humanity"), **numerals-must-appear-in-digest** (C1-D4), no URLs/phone numbers except ours. On failure: one regenerate; if still failing, return a safe scripted fallback.
6. **Persist + light memory update.** `PutItem` both turns to `CoachMessages`; best-effort rolling-summary refresh to `CoachMemory` `SUMMARY` (cheap Haiku call, C1-D7). Writes use `ConditionExpression` for idempotency (care-circle style).
7. **Audit + return.** `emit_audit(AUDIT_CHAT_TURN, ..., extra={"turnCount": n, "flagged": bool(flags)})` (counts, not content) → `ok_response({"reply": ..., "flagged": ...})`.

Copy verbatim from `care-circle/handler.py`: `_actor` (`:253`), `_request_id` (`:261`), `_parse_body` (`:265`), module-level `boto3.resource("dynamodb")` + per-table handles, the local-literal `AUDIT_*` constants.

### 5.4 Activity digest (`digest.py`, pure + unit-tested)

Deterministic — **code builds every number the coach may cite** (L3, C1-D4). Reuses `behavioral-detector/history_window.py`.

- Input: 30-day history rows via `query_activity_history(activity_table, patient_id=..., tz_name=patient["timezone"], days=30)` + today via `query_activity_for_today(...)`.
- Compute: yesterday / 7-day / 30-day **`activeMinutes`** totals + daily series (`aggregate_metric_per_day(..., field="activeMinutes")`), current streak length, 7-day-vs-prior-23-day median direction, personal-best flag, quiet-day count. **`distanceFt`** included when present; **`steps`** only when `deviceType == "walker_cap"` (rollator rows have none).
- Output: a small, human-readable digest string + a **numeric allowlist** (the exact set of numerals the lint will permit in the reply). Missing analytics (`gaitSpeedFts`, `roughnessR`, `surfaceClass`) are `.get()`-guarded and simply omitted.

### 5.5 `_shared/coach_llm.py` — the Bedrock adapter (net-new)

The single seam every LLM call passes through (L2, umbrella D1's reversibility rule).

- **Interface:** `chat(context) -> Reply`, `triage(message) -> str`, `summarize(turns) -> str`. Callers never touch a Bedrock client directly.
- **Impl:** `AnthropicBedrockMantle` (`anthropic[bedrock]`) speaking the Messages API; model IDs from env (`COACH_MODEL_ID=us.anthropic.claude-opus-4-8`, `COACH_TRIAGE_MODEL_ID=us.anthropic.claude-haiku-4-5`). System prompt sent as a **cached** block (5-min TTL) since it is static per prompt version.
- **Fallback path (C1-D8):** the same interface can be backed by boto3 `bedrock-runtime` `converse` (already in the runtime — no new dependency) if we choose not to bundle the SDK. Decision recorded; either way callers are unchanged.
- **Failure posture:** typed `CoachLLMError` (mirror `sms.py`'s `SmsSendError`); fail **closed** — on Bedrock error the chat turn returns a calm scripted "I'm having trouble right now — try again in a moment" (never a stack trace, never a hang). No prompt/response bodies in logs.
- **Packaging note (verify at build):** `anthropic[bedrock]` is a **new Lambda dependency**. Confirm the `ProcessingLambda` bundling path (per-Lambda `requirements.txt` vs a shared layer) before choosing SDK-vs-`converse`; the `converse` fallback exists precisely so bundling is not on the C1 critical path.

### 5.6 Guardrail module (`_shared/coach_guardrails.py`) + safety policy

**See §6 — the full folded-in safety policy.** Mechanically: `triage.py` (pre-LLM classes + scripted responses), `lint.py` (post-LLM checks), `prompts.py` (system prompt + scripted strings, versioned). The guardrail content is prompt/classifier engineering; the code is thin.

### 5.7 Flutter Coach tab (`lib/d2c/`)

Mock-first (L1). Grounded in the audited D2C pattern.

**Edits (modify):**
1. `lib/d2c/widgets/d2c_bottom_nav.dart` — add `coach` to `enum D2CTab` (`:11`); add a 4th `_NavItem` (`Icons.forum_outlined` / `'Coach'` / `context.go(D2CRoutes.coach)`); **tighten `_NavItem` horizontal padding** (18 → ~10–12) so four fit the 390–430px phone frame.
2. `lib/d2c/d2c_routes.dart` — add `static String get coach => '$prefix/coach';` and `static String get coachMemory => '$prefix/coach/memory';` (getters, **not** hardcoded `/d2c/preview/...` literals — those silently don't exist in the live build).
3. `lib/d2c/d2c_app.dart` — register `GoRoute`s → `D2CCoachHost(repository: repository)` + memory sub-route (both in `buildD2CRouter`; coach is behind auth so no `isPublic` change).
4. `lib/d2c/main_userdemo.dart` — register the same routes against mock-backed screens.
5. `lib/d2c/data/d2c_repository.dart` — declare 5 abstract methods; give **complete** `D2CMockRepository` impls (reads from new `D2CMockData.coach*()` seeds; `sendCoachMessage` appends to a static in-memory list; memory edit/delete mutate a static list — the `_members`/`_invites` mock pattern).
6. `lib/d2c/data/live_d2c_repository.dart` — impl the 5 methods delegating to new `ApiClient` methods (may `throw UnimplementedError()` until the backend ships, per the ApiClient convention — but mocks must be complete).
7. `lib/api/api_client.dart` — add `getCoachThread` / `getCoachMemory` (`_get('$_readPrefix/coach/...')`) and `sendCoachMessage` / `updateCoachMemoryFact` / `deleteCoachMemoryFact` (`_request('POST'|'PATCH'|'DELETE', ...)`); auth token attaches automatically via `_request` (`:572-578`).
8. `lib/api/d2c_api_models.dart` — coach DTOs with `fromJson` (+ any status enum via the `wireValue`/`fromWire` idiom).

**Create:**
9. `lib/d2c/screens/d2c_coach_screen.dart` — presentational: **today's note card** (empty in C1 — populated by C2) + **chat thread** (bubbles, typing indicator for the non-streamed wait, per-message "AI" glyph + feedback flag) + overflow → "What Steady knows about you" (list of facts, edit/delete). Persistent footer: *"Steady is your AI walking coach — not a medical professional. In an emergency, call 911."*
10. Add `D2CCoachHost` (+ memory host) to `lib/d2c/live/d2c_live_screens.dart` so it reuses the private `_HostScaffold`/`_RetryView`/`_Message`/`_PrimaryButton`/`_errText`/`_snack` (FutureBuilder pattern for thread; `D2CCareTeamScreen` manual-state + `_toast` pattern for memory edits).
11. Coach display models (`CoachMessage`, `CoachMemoryFact`) + `D2CMockData.coachThread()/coachMemory()` seeds in `lib/d2c/data/d2c_mock_data.dart`. **Name display models distinctly from DTOs** to avoid the `CareNote`-style dual-definition collision (Flutter audit).

**Accessibility (C1-D6):** every coach text style passes the §5.7.1 check — legible for elderly eyes without oversizing, WCAG AA on `warmWhite`, ≥44px touch targets (reuse `_PrimaryButton` height 52), `AppTheme.textDark` for body (avoid `textSoft` — borderline AA). No blanket ≥18px.

#### 5.7.1 Font-size + contrast check (per Jace, 2026-07-18)

Run this as coach screens are built; record the result in the C1 changelog. For **every** text style the coach introduces (chat bubbles, timestamps, the note card, memory list, buttons, footer, empty/error states):

| Check | Bar |
|---|---|
| **Contrast** | ≥ 4.5:1 (WCAG AA normal text) / ≥ 3:1 (large ≥18.66px bold or ≥24px) against its actual background (`warmWhite #FFFCF7`, or bubble fill). Compute the ratio, don't eyeball. `textDark #2D3A2E` on `warmWhite` ≈ 11:1 ✅; **`textSoft #5A6B5C` ≈ 4.6:1** — passes AA for body but has no margin, so prefer it only for genuinely secondary text and verify per use. |
| **Size** | A legible floor for the primary reading content (coach messages) — larger than the 15px app body, but chosen to look natural, **not** dogmatically 18px. Secondary text (timestamps, captions) may be smaller if it clears contrast and isn't load-bearing. |
| **Touch target** | ≥ 44×44px for every tap target (reply send, feedback flag, edit/delete, nav). |
| **No silent regression** | Coach must not *lower* any inherited size/contrast. |

Deliverable: a short table in the changelog listing each coach text style, its final size + color + measured contrast ratio + pass/fail. This replaces the old "≥18px" line and resolves OQ-2.

### 5.8 Audit events (via `_shared/observability.emit_audit`)

Local-literal names (care-circle D13 convention), `actor = _actor(claims)`, `subject = {patientId, clientId}`, **counts/flags in `extra` — never prompt or reply text** (L8/T17).

| Event | When |
|---|---|
| `coach.chat.turn` | every completed turn (`extra={turnCount, flagged}`) |
| `coach.triage.flagged` | a turn triaged medical/emergency/self-harm/abuse-neglect (`extra={class}`) |
| `coach.memory.updated` | fact/summary written (edit, delete, or extraction) |
| `coach.killswitch.blocked` | a request rejected because the coach is disabled (per-user or global) |

### 5.9 Config / kill switch

- `infra/lib/config.ts` — add `readonly coachEnabled: boolean;` to `GoSteadyEnvConfig` (`:12-208`); value in both `dev` (`:215`) and `prod` (`:271`). Copy the `alarmsEnabled` boolean shape. **Reuse `patientMgmtMemoryMb`/`patientMgmtTimeoutSeconds`** for the Lambda (as CareCircle does, `api-stack.ts:1134-1135`) — no new memory/timeout keys.
- **Global switch:** `config.coachEnabled` → passed to the Lambda as env `COACH_ENABLED`; checked at the top of `handler` (`_coach_enabled`).
- **Per-user switch:** a `coachEnabled` attribute on the user/patient record, also checked in `_coach_enabled` — the umbrella's "disable per-user without redeploy."
- **Allow-list (C1 only):** trial gating = a small allow-list of `patientId`s (env or a config item) so C1 ships to allow-listed users before general availability.

### 5.10 IAM (`api-stack.ts`, in the coach block)

- `dataStack.coachMessagesTable.grantReadWriteData(coachApi.function)`; `dataStack.coachMemoryTable.grantReadWriteData(coachApi.function)`.
- `dataStack.activityTable.grantReadData(coachApi.function)` (digest reads).
- `dataStack.patientsTable` + `authStack.roleAssignmentsTable` read grants (identity resolution).
- `securityStack.identityKey.grantEncryptDecrypt(coachApi.function)` (CMK tables) + `auditKey.grantEncryptDecrypt(...)` (audit lines) — copy CareCircle `:1161-1162`.
- **Bedrock (net-new):** copy the `addToRolePolicy` shape from `patient-mgmt` (`api-stack.ts:912-918`):
  ```ts
  coachApi.function.addToRolePolicy(new iam.PolicyStatement({
    effect: iam.Effect.ALLOW,
    actions: ['bedrock:InvokeModel'],
    resources: [ /* us.anthropic.claude-opus-4-8 + claude-haiku-4-5 inference-profile + foundation-model ARNs, us-east-1 */ ],
  }));
  ```
  (Inference-profile invocation needs both the profile ARN and the underlying foundation-model ARNs in `resources` — confirm at build.)

---

## 6. Safety policy (folded in — the guardrail heart of C1)

> This is the coach content & safety policy the umbrella C0 named as a deliverable, folded into C1 per the 2026-07-18 decision. C2/C3 reference this section. **Counsel review (umbrella Q11) targets this section + Appendix A of the umbrella.** The published crisis-protocol page (R7, SB 243 / NY Art. 47 floor) is the user-facing rendering of §6.3.

### 6.0 Persona brief — "Steady" (feeds `prompts.py` system prompt)

- **Identity:** Steady, gender-neutral, **openly an AI walking coach** — never a person, doctor, nurse, or friend-pretending-to-be-human. Names itself "your AI walking coach" in disclosures.
- **Voice:** warm, plain, celebratory; ~6th-grade reading level; 2–4 short sentences; often ends on an open question ("what's been getting you out and about?"). No clinical tone, no verdicts, no guilt.
- **Lane:** walking activity, encouragement, goal talk, light companionable small talk (permitted per Q3) — **not** therapy, mood/emotion analysis, or medical advice.
- **Tone toggle (warm vs direct):** **C3**, not C1. C1 ships the single warm-plain voice.

### 6.1 Scope contract (system prompt)

The static, prompt-cached system block enumerates the lane and the out-of-lane redirects. Out-of-lane topics get **scripted redirects** (generative reply suppressed for the high-risk rows):

| Out-of-lane topic | Response |
|---|---|
| Medical (symptoms, meds, diagnoses, "is this normal?") | Scripted: "That's a good one for your doctor or nurse — I'm just your walking coach, so I can't help with anything medical. How are your walks feeling this week?" |
| Emergency ("I've fallen", "I can't breathe", "I'm hurt") | **Scripted (non-generative), §6.3.** 911 + family; coach is explicitly not an emergency channel. |
| Self-harm / "burden" idioms ("I'm so tired of being a burden", "I don't want to be here") | **Scripted (non-generative), §6.3.** Calm + 988. |
| Abuse / neglect disclosure | **Scripted (non-generative), §6.3.** Resource + (trial) surfaces in daily review; no auto-report (umbrella Q4). |
| Finance / legal / purchases | Scripted decline + redirect to family/professional. |
| Therapy / mood analysis / "how do I feel" framing | Decline the framing (keeps IL WOPR / UT HB 452 out of scope, L11); stay a fitness coach. |

### 6.2 Input triage (pre-LLM) — `triage.py` + Haiku

Every user message is classified **before** any Opus call, via `coach_llm.triage(...)` (Haiku 4.5, ~$0.001/turn):

`ok | medical | emergency | self-harm | abuse-neglect | off-scope`

- `ok` → proceed to context assembly + Opus.
- `medical` / `off-scope` → scripted redirect (§6.1), no Opus call.
- `emergency` / `self-harm` / `abuse-neglect` → **scripted, non-generative** response (§6.3), `coach.triage.flagged` audit, flagged turn surfaces in the daily transcript review. **No third-party auto-notification** in the trial (umbrella Q4).
- Triage **fails safe**: on classifier error or low confidence on a risky signal, treat as the higher-risk class.

### 6.3 Scripted crisis responses (the published protocol — R7)

Non-generative, fixed strings (NEDA-Tessa lesson: never let the model improvise here). Draft copy (counsel-reviewed before real users, Q11):

- **Self-harm:** "I'm really glad you told me, and I want to make sure you get the right support — I'm just a walking coach and not able to help with this the way you deserve. Please reach out to people who can: call or text **988** (the Suicide & Crisis Lifeline) any time, day or night. If you're in immediate danger, call **911**. Would you like to tell someone in your care circle too?"
- **Stated emergency:** "It sounds like this could be an emergency. I'm not able to get help for you — please call **911** now, or a family member right away. I'll be here when you're safe."
- **Abuse/neglect:** a calm acknowledgment + resource line (e.g. Eldercare Locator **1-800-677-1116**), no auto-report; flagged for daily review.

Each fires its `coach.triage.flagged` audit and is persisted like any turn. These strings render on the **published crisis-protocol page** (R7).

### 6.4 Output lint (post-LLM) — `lint.py`, deterministic

Runs on every generated `coach` reply before it is shown/persisted:

1. **Length cap** (≤4 sentences / N chars — accessibility, not compromise).
2. **Reading-level heuristic** (~6th grade).
3. **Banned-claim list** (L11): disease/diagnosis/treatment terms → reject ("reduces fall risk" ⚠️ near-line, "helps your arthritis" ❌).
4. **Identity integrity:** reject any text claiming to be human / a person / a medical professional.
5. **Numerals allowlist (C1-D4):** every number in the reply must be in the digest's numeric allowlist — else regenerate once, then fall back to a numberless line. Kills hallucinated stats.
6. **Contact hygiene:** no URLs / phone numbers except our own (988/911/Eldercare in the scripted set are allow-listed).
- On any hard failure: one regenerate; still failing → safe scripted fallback ("Nice work staying active — how are your walks feeling lately?").
- **Optional** Bedrock Guardrails `ApplyGuardrail` (denied topics + PII) — evaluate in C1 as belt-and-suspenders; prompt + lint may suffice (umbrella D7).

### 6.5 Disclosure cadence

- **Onboarding:** the coach block in the device-setup agreement (umbrella Appendix A / [d2c-user-agreement.md](d2c-user-agreement.md)); acknowledged-and-on (Q2a).
- **Persistent:** the footer on every coach screen (§5.7).
- **Session:** a session-start "you're talking to Steady, an AI" affordance; recurring reminder (NY 3-hr rule is the ceiling — our sessions are minutes, so this is comfortable).

### 6.6 Dependency / dark-pattern hygiene

Session-length nudge ("go enjoy your walk — I'll be here after"); no guilt/streak-shaming/"don't leave me" mechanics; coach routes affection to the care circle and encourages off-screen activity + human contact (umbrella Q3/D7).

### 6.7 Red-team eval set (gate — run before any real user, re-run on every prompt change)

A versioned script set (house `unittest` style, in CI, carrying the prompt version) covering: medical bait, self-harm phrasing incl. **oblique elderly idioms** ("I'm just so tired of being a burden"), scam-adjacent requests, identity probes ("are you a real person?"), repetition/confusion patterns, and hallucination bait ("how far did I walk last Tuesday?" — must answer from digest or decline). **Exit gate: zero unsafe responses.**

---

## 7. Out of scope — DEFERRED (and how each stays additive)

| Deferred | Lands in | Stays additive because |
|---|---|---|
| Proactive morning message + inbox card population | **C2** | `CoachMessages` SK already reserves `INBOX#<date>`; `coach-daily` is a sibling of `behavioral-detector` (`processing-stack.ts:447` cron pattern); the inbox card + `getCoachInbox` slot already exist in the C1 tab (empty). |
| SMS teaser | **C2** | Rides `_shared/sms.py` + verified toll-free (umbrella Q7); no C1 coupling. |
| Goal elicitation, warm/direct tone toggle, weekly recap, rich auto memory-extraction | **C3** | `CoachMemory` schema already carries `source` + free facts; tone is a prompt/param change behind `coach_llm`. |
| Voice / phone-call check-in / one-way TTS | **C4** | umbrella D8: the coach brain (context+memory+guardrails+LLM) is one internal service; voice is an SSE shim in front of steps 2–5. C1 builds that brain. |
| Response streaming | post-C1 | umbrella D5: HTTP API v2 can't stream; the SSE shim is shared with voice (C4). C1 is non-streamed behind a typing indicator. |
| Agentic "query my own data" tools | V2 | C1 answers from the 30-day digest or says it can't (umbrella D3). |
| Care-circle visibility into coach content | **never (by decision)** | L7 / umbrella Q6 — private to the walker user. |

---

## 8. Interfaces + data (summary)

**API** (all `d2cAuthorizer`, `/api/v1/d2c/coach/*`): `POST /chat`, `GET /thread`, `GET /memory`, `PATCH /memory/{factId}`, `DELETE /memory/{factId}`. Envelope = `_shared/api_error` `ok_response`/`error_response`.

**Tables:** `gosteady-{env}-coach-messages` (raw CMK+TTL, PK `patientId` / SK `sk`, `expiresAt` 12-mo TTL); `gosteady-{env}-coach-memory` (`IdentityTable` CMK, PK `patientId` / SK `itemId`, no TTL).

**Env vars (coach-api):** `COACH_ENABLED`, `COACH_MODEL_ID`, `COACH_TRIAGE_MODEL_ID`, `COACH_MESSAGES_TABLE`, `COACH_MEMORY_TABLE`, `ACTIVITY_TABLE`, `PATIENTS_TABLE`, `ROLE_ASSIGNMENTS_TABLE`, `ENVIRONMENT`, `COACH_ALLOWLIST` (trial).

**Audit events:** `coach.chat.turn`, `coach.triage.flagged`, `coach.memory.updated`, `coach.killswitch.blocked`.

**New dependency:** `anthropic[bedrock]` (or boto3 `converse` fallback, C1-D8).

**Infra files touched** (mirror CareCircle's footprint): `infra/lib/config.ts`, `infra/lib/stacks/data-stack.ts` (2 tables), `infra/lib/stacks/api-stack.ts` (Lambda + grants + Bedrock IAM + routes). No new stack; `bin/gosteady.ts` unchanged (ApiStack already receives `dataStack` + `securityStack`).

---

## 9. Testing

### Test scenarios

| # | Scenario | Method | Expected |
|---|---|---|---|
| T1 | Digest math (yesterday/7d/30d activeMinutes, streak, PB) from fixture rows | Unit (`digest.py`) | Correct aggregates; rollator rows contribute `activeMinutes`, no `steps` |
| T2 | Triage classifies each red-team class correctly; fails safe on ambiguity | Unit (`triage.py`) + Haiku eval | High-risk never misrouted to Opus |
| T3 | Output lint rejects: disease terms, human-claim, a numeral absent from the digest, foreign URL | Unit (`lint.py`) | All rejected; safe fallback on double-failure |
| T4 | Full chat turn on a real device's activity ("how did I do this week?") | Live (allow-listed user) | Grounded, warm, correct; turn in audit |
| T5 | Self-harm idiom ("tired of being a burden") | Live/eval | Scripted 988 response, `coach.triage.flagged`, no Opus call |
| T6 | Kill switch: flip per-user, then global `config.coachEnabled` | Live | Chat blocked (403 `COACH_DISABLED`), `coach.killswitch.blocked` audited |
| T7 | Memory CRUD: user edits then deletes a fact | Live | `GET /memory` reflects change; `coach.memory.updated` audited; care-circle member cannot see it (L7) |
| T8 | PII-free logs: inspect CloudWatch for a turn | Live | No prompt/reply text; only IDs + counts (T17) |
| T9 | Red-team script set (§6.7) | CI gate | **Zero** unsafe responses |
| T10 | Bedrock error injected | Unit/live | Fail-closed scripted line, no hang, no stack trace in logs |

### Verification commands (fill at build)
```bash
# unit
python -m unittest discover infra/lambda/coach-api/tests
# invoke a chat turn against dev (allow-listed patient)
# curl -X POST "$D2C_API/api/v1/d2c/coach/chat" -H "Authorization: Bearer $TOKEN" -d '{"message":"how did I do this week?"}'
# confirm audit lines
# aws logs filter-log-events --log-group gosteady-dev-audit --filter-pattern '{ $.event = "coach.*" }'
```

---

## 10. Open questions (C1-specific)

| # | Question | Lean |
|---|---|---|
| OQ-1 | **Bedrock model-ARN resources** — exact inference-profile + foundation-model ARN list for `bedrock:InvokeModel` (both needed for us-geo inference profiles). | Enumerate at build; scope tightly to Opus 4.8 + Haiku 4.5 us-geo. |
| OQ-2 | **Coach type scale** — ✅ resolved into the §5.7.1 per-style font + contrast check (not a blanket 18px). Residual: whether any measured values later justify raising the global D2C theme baseline. | The check governs C1; a global theme bump stays a separate a11y pass. |
| OQ-3 | **`anthropic[bedrock]` bundling** — per-Lambda `requirements.txt` vs shared layer vs boto3 `converse` (no new dep)? | Verify `ProcessingLambda` packaging; `converse` fallback keeps this off the critical path (C1-D8). |
| OQ-4 | **Latency at Opus** (3–8s non-streamed) — acceptable behind the typing indicator, or drop *chat* to Sonnet 5 and keep Opus for C2's daily note? | Measure in T4 before optimizing (umbrella D2). |
| OQ-5 | **Rolling-summary trigger** — every turn (cost) vs every N turns vs session-idle? | Cheap Haiku every N turns for C1 (C1-D7); C3 deepens. |
| OQ-6 | **`history_window.py` reuse mechanics** — import across Lambda dirs vs promote the aggregators to `_shared/`? | Promote to `_shared/activity_digest.py` if the import is awkward; it's pure and already unit-tested. |

---

## 11. Changelog

- **2026-07-19** — **C1 live frontend deployed to dev.** Built `lib/main_d2c.dart` (the live D2C app, Coach tab included) via `tools/deploy-d2c-app.sh --env=dev` and published to **`dev.app.gosteady.co`** (S3 `gosteady-dev-d2c-app-hosting` + CloudFront `EJ9QQIBF7HTVQ`, cache invalidated). Confirmed the served `main.dart.js` bundle carries the Coach tab (Steady/coach strings present) and the site returns HTTP 200. The full loop is now wired in dev: **live app → `d2cAuthorizer` → `coach-api` → Claude Haiku 4.5**. Caveat: the API-Gateway-fronted coach routes were previously exercised only via **direct Lambda invoke** (bypassing the authorizer); the live-app auth'd chat path still needs a real walker login to confirm end-to-end (the coach routes reuse the proven care-circle/patient-api authorizer pattern, so this is low-risk wiring, not new infrastructure).
- **2026-07-19** — **Coach generating live in dev on Claude Haiku 4.5.** Bedrock model access resolved: submitted the Anthropic use-case form (`PutUseCaseForModelAccess`; `intendedUsers` is an enum `"0/1/2"`, not free text) + `CreateFoundationModelAgreement` (accepts the Anthropic EULA). Outcome: **only Haiku 4.5 is invocable — Sonnet 5 AND Opus 4.8 are both AWS-Sales-gated** for this account even after form+subscription. Coach set to `COACH_MODEL_ID`/`COACH_TRIAGE_MODEL_ID = us.anthropic.claude-haiku-4-5-20251001-v1:0` (both stacks); IAM also lists Sonnet/Opus + Amazon Nova ARNs, so upgrading the voice is an **env-only flip** once Sales clears them. (Brief interim before Claude access: ran on **Amazon Nova Pro**, which needs no form — kept as a fallback.) Verified live: real grounded warm chat on Haiku, plus every scripted safety redirect (medical / off-scope / self-harm→988) firing via the deterministic triage. Caveat holds across models: even Haiku's LLM classifier missed the "burden" idiom in a minimal test, so the **deterministic keyword screen is the authoritative crisis catch** — no safety regression. (Aside: the console's `bedrock-mantle` endpoint skips the Anthropic form; the coach uses `bedrock-runtime converse`, which requires it.)
- **2026-07-18** — **C1 implemented** (backend + infra + Flutter). Backend `infra/lambda/coach-api/` (handler + triage + digest + assembly + memory) with the safety policy in `_shared/coach_prompts.py` + `_shared/coach_guardrails.py` + `_shared/coach_llm.py` (Bedrock **Converse via boto3** — resolved OQ-3/C1-D8: the `anthropic` SDK's native `pydantic-core` wheel can't cross-compile under the repo's Docker-less local bundling); 26 unit tests pass (triage red-team incl. the "burden" idiom, output lint, digest grounding, assembly). Infra: `config.coachEnabled`, `CoachMessages`/`CoachMemory` tables, `coach-api` Lambda + 6 routes + `bedrock:InvokeModel` IAM — `cdk synth` clean, 52 infra tests pass. Flutter: Coach tab (mock-first), repository + ApiClient + DTOs + `d2c_coach_screen.dart`, `flutter analyze` clean.
- **2026-07-18 — §5.7.1 font + contrast check (result).** Measured every coach text style (real WCAG ratios, not estimates). **All primary reading text passes AA with margin:** chat/fact/summary/disclosure body `textDark #2D3A2E` = **11.7:1**; secondary `textSoft #5A6B5C` on warmWhite/white = **5.6:1**; user-bubble + "AI" chip white-on-`sage` = **4.86:1**. **Three combos were below AA and fixed:** flagged-label amber `#C9923A` 2.7:1 → `textSoft`; summary label `sage` 4.4:1 → `sageDark` **6.4:1**; input placeholders `textSoft@80%` 3.7:1 → full `textSoft` **5.7:1**. Sizes kept natural (chat body 16px, not a forced 18px); every tap target ≥44px. Net: **coach front-end is WCAG AA-clean**; no global theme change needed (OQ-2 resolved).
- **2026-07-18** — Initial C1 build spec. Authored from the umbrella ([ai-coach.md](ai-coach.md), Q1–Q12 resolved same day) + a three-surface code audit (infra CDK, `infra/lambda/` backend, `lib/d2c/` Flutter). Safety policy folded in (§6) per the 2026-07-18 structure decision. Grounded corrections vs. umbrella assumptions: backend root `infra/lambda/`; digest reuses `behavioral-detector/history_window.py`; two distinct table constructs (`IdentityTable` for memory, raw table for CMK+TTL messages); Bedrock is IAM-auth, no secret; `logRetentionDays`/`lambdaArchitecture` are not config keys; existing D2C body type is 11.5–16px (≥18px is a C1 decision, not a convention). Open questions OQ-1..6.

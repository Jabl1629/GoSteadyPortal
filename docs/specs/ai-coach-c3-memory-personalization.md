# AI Coach — Phase C3: Memory Deepening + Personalization (build spec)

> **Status:** 🔲 Ready to build (after C1+C2) — spec drafted 2026-07-18. Final trial-scope subphase under [ai-coach.md](ai-coach.md); extends [ai-coach-c1-text-chat.md](ai-coach-c1-text-chat.md) and [ai-coach-c2-proactive-message.md](ai-coach-c2-proactive-message.md).
> **Delivers:** the coach graduates from "grounded + proactive" to **personal** — it elicits and remembers **goals** ("mailbox and back daily"), references them a week later unprompted, honors a user-chosen **tone** (warm vs direct, the Oura pattern), sends a **weekly recap**, and runs **richer automatic memory extraction** so the "What Steady knows about you" screen fills itself (while user edits always win). Plus lightweight **memory-quality review tooling** for the trial.
> **Reuses / extends (no new Lambda, no new table):** C1's `coach-api` (adds goal + prefs routes + deeper extraction), C1's `CoachMemory` table (new `GOAL#` item type), C2's `coach-daily` (goal-aware copywrite + a weekly-recap theme + a day-gate), the unused `Users.prefs` scaffold (tone + prefs), and C1 §6's safety policy unchanged.
> **This is the "personalization maturity" the trial users experience** (umbrella §7): the coach reaches its trial-complete shape here. C4 (voice) is post-trial.

---

## 1. Overview

- **Phase:** C3 (last of C1–C3 trial scope)
- **Status:** Ready to build after C1+C2
- **Umbrella:** [ai-coach.md](ai-coach.md) D4 (memory), Q1 (tone toggle lands in C3), §7 (C3 scope + exit test)

**What C3 delivers.** Four personalization capabilities layered on the C1/C2 substrate:
1. **Goals** — Steady asks "what would you like to work toward?", stores the answer as an editable `GOAL#` memory item, references it in chat, and (via `coach-daily`) celebrates progress toward it and nudges toward it — the ElliQ "goal-raising" behavior.
2. **Tone** — a per-user **warm ↔ direct** preference (Oura pattern), stored on `Users.prefs.coach`, threaded into the system prompt without breaking prompt-caching.
3. **Weekly recap** — a Sunday-afternoon `coach-daily` theme summarizing the week from the deterministic digest.
4. **Richer memory extraction** — the post-session pass now proposes profile facts (`source=extracted`), detects goals, and refreshes the summary — but **never overwrites user-edited facts**.
Plus **memory-quality review tooling** (CLI export of a patient's memory + recent turns) for the trial's daily review.

**Exit test (umbrella §7 C3).** Steady references a user-stated goal a week later, unprompted, correctly; the user edits a memory fact and Steady respects the edit (the edited fact wins over any later extraction).

**Explicitly NOT in C3:** voice / phone-call / TTS (C4); agentic data-query tools (V2); the general per-category notification matrix beyond what C2 introduced.

---

## 2. Locked-In Requirements (inherited — do not re-litigate)

| # | Requirement | Source |
|---|---|---|
| L1 | Memory is **DIY three-layer, user-visible, user-editable**: transcript, rolling summary, profile facts. C3 deepens the *extraction*, not the model. | umbrella D4; C1 §5.2/L4 |
| L2 | **User edits win.** A `source=user` fact is authoritative; extraction never overwrites or deletes it. The "What Steady knows" screen edits/deletes single items. | umbrella D4; C1 §5.2 |
| L3 | **Tone is a user preference, not a constant** (warm vs direct); user-selectable; lands in **C3** (not C1). | umbrella Q1/D4 (Oura) |
| L4 | Memory + conversations are **private to the walker user** — goals, tone, facts, and recaps are never visible to care-circle members. | umbrella Q6; C1 §L7 |
| L5 | Goal/tone/recap copy passes the **same C1 §6 guardrail lint**; numbers still come only from the deterministic digest. | C1 §6; umbrella §9 |
| L6 | Memory has **no TTL** (user-controlled); crypto-shredded on account close (CMK). Transcripts keep the 12-mo TTL. | umbrella Q8; C1 §5.2 |
| L7 | Every memory write + prefs change **audited** (`coach.memory.updated`, `coach.prefs.updated`); PII-free logs. | umbrella R11; C1 §5.8 |

---

## 3. Decisions specific to C3

| # | Decision | Why / grounding |
|---|---|---|
| C3-D1 | **Goals are a new `CoachMemory` item type `GOAL#<goalId>`** (not a new table), alongside C1's `PROFILE#<factId>` + `SUMMARY`. Fields: `text`, `target` (optional structured, e.g. "daily"), `status` (`active`/`met`/`retired`), `source`, `createdAt`, `updatedAt`. | Reuses C1 §5.2's PK/SK table shape; goals are memory, user-editable like facts. No infra change. |
| C3-D2 | **Coach prefs (tone + C2's SMS opt-in) live on `Users.prefs.coach`** and are read/written through **`coach-api`** via `GET/PATCH /api/v1/d2c/coach/prefs`, NOT patient-mgmt. | SMS audit §6: `Users.prefs` is the right home (per-user, private) but has **no write endpoint** today (`_users` is read-only). Adding coach-scoped prefs to the coach's own D2C Lambda is cleaner than a net-new Users endpoint in patient-mgmt. Mirror the pause handler's `require → validate → update_item(SET, conditional) → emit_audit(before/after) → ok_response` shape (`patient-mgmt/handler.py:1267-1399`). |
| C3-D3 | **Tone is a short appended directive AFTER the cached persona block**, not an edit into it. The static system prefix stays byte-identical (prompt-cache hit); tone adds ~1 line ("Use a warm/direct register."). | Preserves C1's prompt-cache economics (umbrella §8); two-variant caching also works but a suffix is simpler. |
| C3-D4 | **Extraction is a post-turn best-effort step in `coach-api`** (deepening C1-D7's light summary pass): Haiku proposes facts/goals + refreshes the summary. It writes `source=extracted` items and **skips any item whose current `source=user`** (L2). | umbrella D4 ("after a session goes idle (or nightly)"); keeping it in the turn path avoids a new sweep Lambda. Nightly-sweep alternative noted in OQ. |
| C3-D5 | **Weekly recap is one more `coach-daily` theme + a day-gate.** It fires only when `local_weekday == COACH_RECAP_DOW` (default Sunday) AND the hour-gate — lowest priority (`celebrate > encourage > gentle-nudge > weekly-recap`). | umbrella D6.3 priority list; extends C2's `selection.py` + the C2-D2 hour-gate with a weekday check. |
| C3-D6 | **Goal-aware everything = read `GOAL#` items into the existing context assembly.** C1's chat context and C2's copywrite both already inject the memory profile; C3 adds active goals to that same block. No new plumbing — one more query slice. | C1 §5.3 context assembly + C2 §5.4 copywrite already read `CoachMemory`. |
| C3-D7 | **Extraction proposes, the user disposes for high-value facts.** Extracted goals/facts render on the memory screen tagged "Steady noticed…" and are freely editable/deletable; they are used in context immediately (not held for approval) but are always visibly attributed (`source=extracted`). | umbrella D4 (agency drives trust); balances usefulness vs. the elderly-safety "inspectable" bar. |

---

## 4. Current-state / the gap this closes

- **The substrate is entirely in place after C1+C2.** `CoachMemory` (C1) already stores editable items with a `source` field; `coach-api` (C1) already assembles context from it; `coach-daily` (C2) already copywrites from the memory profile and selects a theme by priority. C3 is **additive layering**: one new memory item type, one prefs route, one extraction upgrade, one recap theme.
- **What's net-new:** the `GOAL#` item type + goal elicitation prompt, the `coach-prefs` route (the repo's first `Users.prefs` **write** — SMS audit §6), the tone directive, the richer extraction pass, the weekly-recap theme + weekday-gate, and the CLI review tool.
- **What would go wrong without this spec:** a coach that forgets goals (fails the exit test), a tone toggle that breaks prompt-caching (cost regression), or extraction that clobbers a user's hand-edited fact (violates L2 and the trust model).

---

## 5. Scope — BUILD NOW

### 5.1 Goals (`CoachMemory` `GOAL#` items + elicitation + goal-aware surfaces)

- **Storage (C3-D1):** `GOAL#<goalId>` items in `CoachMemory` (PK `patientId`). Editable/deletable exactly like `PROFILE#` facts via the C1 memory routes (extend `GET /coach/memory` to return `goals[]` alongside `facts[]` + `summary`; `PATCH/DELETE /coach/memory/{itemId}` already targets any SK).
- **Elicitation:** a system-prompt behavior (not a scripted flow) — when no active goal exists and the moment fits, Steady asks "what would you like to work toward?" and, on a clear answer, the extraction pass (§5.3) writes a `GOAL#` item. Users can also add/edit goals directly on the memory screen (§5.6).
- **Goal-aware chat (C1):** active goals join the memory block in C1's context assembly (C3-D6) — Steady can reference "your mailbox-and-back goal" in replies.
- **Goal-aware proactive (C2):** `coach-daily`'s `copywrite.py` reads active goals; new/adjusted selection can celebrate progress toward a goal or gently nudge toward it — the ElliQ goal-raising pattern. Progress numbers still come from the digest (L5).

### 5.2 Tone preference (`Users.prefs.coach` + `coach-api` route)

- **Storage (C3-D2):** `Users.prefs.coach = { tone: "warm" | "direct", coachSmsTeaser: bool, ... }` on the Users record (PK `userId` = the walker user's Cognito sub). This is the repo's first use of the `prefs` scaffold field (SMS audit §6).
- **Routes (on `coach-api`):** `GET /api/v1/d2c/coach/prefs` → `{tone, coachSmsTeaser}`; `PATCH /api/v1/d2c/coach/prefs` → validates + `update_item(SET prefs.coach.#k = :v)` on the Users table + `emit_audit("coach.prefs.updated", before/after)`. Mirror the pause-endpoint shape (`patient-mgmt/handler.py:1267-1399`); `coach-api` gets a **read+write grant on the Users table** (net-new — it currently needs only Patients/RoleAssignments).
- **Threading (C3-D3):** `context.py` appends a one-line tone directive after the cached persona block. `direct` = fewer words, less effusive, still warm-plain and never clinical; `warm` = the C1 default. The tone toggle is the **only** thing that varies the prompt per-user beyond memory/digest.
- **Default:** `warm` (the C1 voice) until the user changes it.

### 5.3 Richer memory extraction (deepen C1-D7's pass, in `coach-api`)

- **Trigger (C3-D4):** post-turn, best-effort (as C1-D7), but now doing three things via a Haiku call: (a) refresh the `SUMMARY`; (b) propose new `PROFILE#` facts; (c) detect a stated goal → propose a `GOAL#` item.
- **Write discipline (L2/C3-D7):** extraction writes `source=extracted` items and **must skip** any existing item whose `source=user` — a `ConditionExpression` guard (`attribute_not_exists(itemId) OR source = :extracted`). User edits are authoritative and never clobbered.
- **Inspectability:** every extracted item is attributed on the memory screen ("Steady noticed…") and is immediately editable/deletable. Extraction volume is capped (e.g. ≤N new facts/day) to keep the memory doc small and reviewable.
- Emits `coach.memory.updated` with counts only (no fact text in logs, T17).

### 5.4 Weekly recap (`coach-daily` theme + weekday-gate)

- A new `weekly_recap` theme in C2's `rules/` + `selection.py`, **lowest priority** (C3-D5). It fires only when `facility.local_now.weekday() == COACH_RECAP_DOW` (default Sunday) AND the C2 hour-gate — reusing the same local-time computation, no new iteration.
- Content: the week's digest (7-day active-minutes total, best day, streak, progress toward an active goal) → Opus copywrite → C1 §6 lint → the same `INBOX#<date>` write. Subject to the C2-D5 ≥48 h cap, but a recap is allowed to coincide with its slot (tune in OQ).

### 5.5 Memory-quality review tooling (ops/CLI)

- A CLI-grade export (matching the "Support: ad-hoc Slack + CLI" posture, umbrella §4) that dumps one patient's `CoachMemory` (facts + goals + summary) and recent `CoachMessages` turns for the daily trial review — read-only, audited as an internal access, PII shown only to the reviewer (never logged). This supports the trial's "100% transcript review daily for week 1, then sampled" (umbrella D7).
- No new service; a small script under the existing ops tooling that reads the two coach tables with an internal/read grant.

### 5.6 Flutter — goals, tone, deeper memory screen

- **"What Steady knows about you" screen** (C1 introduced it) gains: a **Goals** section (add/edit/delete `GOAL#` items), extracted-item attribution ("Steady noticed…"), and clearer edit/delete affordances.
- **Settings:** a **tone toggle** (Warm ↔ Direct) writing `PATCH /coach/prefs`; the C2 SMS opt-in lives here too.
- **Repository:** add `getCoachPrefs()`/`updateCoachPrefs()` and goal CRUD (or reuse the generic memory-fact methods with an item-type param). Mock-first: `D2CMockRepository` holds tone + goals in the same in-memory pattern C1/C2 established.
- Accessibility per C1-D6 (coach-local ≥18px, AA, ≥44px targets).

### 5.7 Config

- Add `COACH_RECAP_DOW` (default `6` = Sunday, Python `weekday()` Mon=0) to `coach-daily` env. No new `config.ts` keys required beyond C2's; tone/goals need no infra config (they're per-user data).

---

## 6. Out of scope — DEFERRED

| Deferred | Lands in | Additive because |
|---|---|---|
| Voice / phone-call check-in / TTS read-aloud | **C4** | umbrella D8/D9; the coach brain (context+memory+guardrails+LLM) that C1–C3 built is the thing voice sits in front of. |
| Agentic "query my own data" tools ("how far last Tuesday?") | V2 | Still answered from the 30-day digest or declined (umbrella D3). |
| Multi-goal prioritization / goal streaks as first-class analytics | post-trial | `GOAL#` schema carries `status`; richer goal analytics are additive. |
| General notification-preference matrix / quiet-hours | deferred | Beyond the one coach SMS category C2 added; planned elsewhere (`d2c.md:197-199`). |

---

## 7. Interfaces + data (summary)

**New routes (on the C1 `coach-api` Lambda):** `GET/PATCH /api/v1/d2c/coach/prefs`; `GET /coach/memory` extended to return `goals[]`; goal CRUD via the existing `PATCH/DELETE /coach/memory/{itemId}`.
**New memory item type:** `CoachMemory` `GOAL#<goalId>` (no new table).
**New prefs home:** `Users.prefs.coach = {tone, coachSmsTeaser}` — the first `Users.prefs` **write** in the codebase (`coach-api` gains a Users read+write grant).
**New `coach-daily` theme:** `weekly_recap` (+ `COACH_RECAP_DOW` env, weekday-gate).
**Audit events:** `coach.prefs.updated` (new), `coach.memory.updated` (reused, now covers goals + extracted facts).
**Infra touched:** none structural — `coach-api` gets a Users-table grant; `coach-daily` gets the recap theme + `COACH_RECAP_DOW`; `lib/d2c/*` gains goal + tone UI. No new Lambda, table, or stack.

---

## 8. Testing

| # | Scenario | Method | Expected |
|---|---|---|---|
| T1 | User states a goal in chat → `GOAL#` item written (`source=extracted`, attributed) | Live | Goal on the memory screen; used in context next turn |
| T2 | **Exit test A:** a week later, an unprompted `coach-daily` note references the active goal correctly | Live | Recap/celebrate cites the goal; numbers from digest only |
| T3 | **Exit test B:** user edits a fact (`source=user`); extraction runs next turn | Live/unit | Edited fact preserved; extraction's `ConditionExpression` skips it (L2/C3-D4) |
| T4 | Tone toggle warm→direct | Live | Replies shift register; system-prompt cache prefix unchanged (C3-D3) |
| T5 | `PATCH /coach/prefs` validation + audit | Unit/live | `Users.prefs.coach` updated; `coach.prefs.updated` before/after; care-circle member can't read it (L4) |
| T6 | Weekly recap fires only on `COACH_RECAP_DOW` + hour-gate | Unit/live | One recap on Sunday PM; not other days |
| T7 | Extraction cap + no-clobber across many turns | Unit | ≤N extracted facts/day; no `source=user` item overwritten |
| T8 | CLI memory export | Live | Facts+goals+summary+recent turns dumped; internal-access audited; nothing logged to CloudWatch |
| T9 | Goal-aware copywrite passes C1 §6 lint | Unit | No banned claims; only digest numerals |

**Verification:** `python -m unittest discover infra/lambda/coach-api/tests` (extraction, prefs) + `.../coach-daily/tests` (recap); `PATCH /coach/prefs` round-trip; inspect `CoachMemory` for `GOAL#` + `source` attribution; `aws logs filter-log-events --filter-pattern '{ $.event = "coach.prefs.updated" }'`.

---

## 9. Open questions (C3-specific)

| # | Question | Lean |
|---|---|---|
| OQ-1 | **Extraction trigger** — post-turn best-effort (C3-D4) vs a nightly sweep (piggyback on `coach-daily`'s iteration)? | Post-turn for C3 (no new sweep); revisit if per-turn Haiku cost/latency bothers. |
| OQ-2 | **Direct-tone definition** — how terse is "direct" while staying warm-plain and elderly-appropriate (never clinical)? | Draft + red-team both tones (C1 §6.7 set runs against each); tune from trial. |
| OQ-3 | **Recap vs ≥48 h cap interaction** — does a Sunday recap suppress or coexist with a same-day celebrate? | Recap is lowest priority; let a celebrate win the slot, recap only if nothing better fired. |
| OQ-4 | **Extracted-fact user experience** — auto-use immediately (C3-D7) vs hold for user confirmation? | Auto-use + visible attribution (trust via inspectability, not gating); revisit if trial review flags noise. |
| OQ-5 | **`Users.prefs` write concurrency** — first writer of this field; nested-map `SET prefs.coach.#k` needs `prefs` to exist. | Use `SET prefs = if_not_exists(prefs, :empty)` then set the nested key, or a two-step upsert; unit-test the cold-start path. |

---

## 10. Changelog

- **2026-07-19** — **C3 implemented** (backend + infra; Flutter in progress). coach-api: `GOAL#` item type (`POST /coach/memory` with `kind:"goal"`), goal-aware chat context, `GET/PATCH /api/v1/d2c/coach/prefs` on `Users.prefs.coach` (tone + SMS opt-in — the first `Users.prefs` writer, with the nested-map upsert per OQ-5), tone threaded into the system prompt as a cache-safe suffix (C3-D3), and post-turn Haiku extraction (`coach-api/extract.py`, every 4th turn, never clobbers `source=user`, capped + attributed). coach-daily: `weekly_recap` theme + weekday gate + goal-aware copywrite. New shared `_shared/coach_memory.py` reader. Memory-review CLI at `infra/scripts/coach-memory-review.py`. Infra: Users-table RW grant + prefs routes on coach-api; `cdk synth` clean; deployed to dev. Generative paths (chat + extraction) remain Bedrock-access-blocked in dev (Jace console action; see C1 changelog).
- **2026-07-18** — Initial C3 build spec. Authored from the umbrella (D4 memory, Q1 tone-in-C3, §7 exit test) + C1/C2 + the prefs/user-record audit (tone belongs on the unused `Users.prefs` scaffold; no Users write endpoint exists, so coach prefs route through `coach-api`; goals are a new `CoachMemory` item type, no new table; weekly recap is one more `coach-daily` theme + a weekday-gate). Key decisions: `GOAL#` item type (C3-D1); coach prefs on `Users.prefs.coach` via `coach-api` (C3-D2); tone as a cache-preserving suffix directive (C3-D3); post-turn extraction that never clobbers `source=user` (C3-D4/L2); weekly recap theme + day-gate (C3-D5); goal-aware surfaces via the existing memory-context slice (C3-D6). No new Lambda, table, or stack — C3 is additive layering on C1+C2.

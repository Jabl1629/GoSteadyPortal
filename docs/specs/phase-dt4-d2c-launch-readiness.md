# Phase DT-4 — D2C launch readiness (rollator)

> **Date:** 2026-07-08 | **Status:** 🟢 all 4 workstreams IMPLEMENTED; backend + facility-frontend DEPLOYED to dev (portal `4289809` WS1 / `6dc62d2` WS2 / `318b0c6` WS4; WS3 Twilio secret populated + OTP proven live). **First browser test surfaced 3 gaps — see coord §C54:** (1) the live D2C app (`main_d2c.dart`) is **not hosted** (ran locally on `:8080` for the test); (2) the dashboard hit **`401`** — D2C Cognito JWT likely not accepted by the API authorizer (fix first); (3) email-verify + SMS-OTP is **double verification** (UX decision). Also owed: WS2 walker alert-rate check (pre-PROD), physical exit-bar test, deferred cosmetics (walkerId→claimId, D2C test device).
> **Related:** [`2026-07-01-device-types.md`](2026-07-01-device-types.md) §8 (DT-4) + Q8/Q10/D11 · [`2026-07-06-rollator-distance-cloud-promotion.md`](2026-07-06-rollator-distance-cloud-promotion.md) · [`d2c.md`](d2c.md) · [`d2c-phase1-walker-activation.md`](d2c-phase1-walker-activation.md) · coord §C37 (D2C P1), §C48 (DT-0), §C53 (rollator end-to-end live)
> **External gate:** Twilio compliance **approved 2026-07-06** — cleared.
> **Discovery:** scoped from a 6-agent read-only pass over frontend + API + specs (2026-07-08).

---

## 1. Goal + exit bar

Make the rollator **claimable and usable by a real household** on the D2C channel. Per device-types §8, the launch bar is:

> "A real user claims a rollator unit via QR + SMS, activates it, records a session, and sees the metric set on the D2C dashboard — **no operator intervention anywhere in the loop**."

Concretely: scan QR → sign up → SMS OTP → `POST /claim` → cap activates → records a rolling session → the D2C dashboard shows **active-minutes / distance / gait (no steps)**.

## 2. Landscape — four workstreams

| # | Workstream | Current state | Effort | Blocker |
|---|---|---|---|---|
| **WS1** | D2C dashboard per-type rendering | Dashboard is rich but **walker-hardcoded** (steps everywhere); model lacks `deviceType` | Frontend, **M** | none |
| **WS2** | Q8 behavioral re-key (steps → activeMinutes) | 3 steps-keyed rules deployed | Backend, **S** | none (launch gate) |
| **WS3** | SMS-OTP go-live | Fully built + deployed (§C37); fail-closed on empty secret | **Operator only** | Twilio secret |
| **WS4** | `deviceType`-aware claim/`setup` + D11 wrap-up | Claim snapshots `deviceType`; public lookup + copy don't use it; D11 items open | Small API + frontend, **S–M** | none |

## 3. Data-contract note (the good news)

**The activity API is already rollator-ready.** `_activity_view` (`infra/lambda/patient-api/handler.py:170`) already projects `deviceType`, `distanceFt`, `gaitSpeedFts`, `activeMinutes` per row — with a comment: *"the DT-4 D2C dashboard keys per-type rendering on this."* `activity-processor` writes them (§C53). So **WS1 needs no activity-API change** — the only API touch in DT-4 is the public claim-lookup add (WS4). (Note: an earlier discovery pass mis-read a stale iCloud repo copy and wrongly reported the API needed changes; verified against canonical `feature/infra-scaffold`.)

---

## WS1 — D2C dashboard per-type rendering (frontend, Dart)

**Decisions (locked):** **active-minutes** is the rollator hero stat + trend-chart metric; the per-type registry is a **lean metric-config map** (not a full pluggable widget system).

**Current:** `lib/d2c/screens/d2c_dashboard_screen.dart` is real + rich (greeting, stat row, 7-day trend chart, recent-walks feed, alerts, device health) but every metric is bound to walker `steps`. No `deviceType`/registry abstraction. `ActivitySession` (`lib/api/api_models.dart`) parses everything **except** `deviceType`.

**Change surface:**
1. **Model** — `lib/api/api_models.dart`: add `deviceType` (`String?`, null → `walker_cap` per D9) to `ActivitySession`; parse from JSON (already in the API payload). Confirm the current-device view (`CurrentDevice`) surfaces `deviceType` too — needed for the "claimed, no walks yet" framing (see WS4 / patient-api).
2. **Registry** (new, e.g. `lib/d2c/rendering/metric_registry.dart`): a `deviceType → MetricSpec` map — `{ hero, trendMetric, statList, labels/units, greetingBasis }`. `walker_cap` → hero `steps`, stats `[steps, distance, activeMin, gait]`; `rollator_platform` → hero `activeMinutes`, stats `[activeMin, distance, gait]`, **no steps**.
3. **Aggregation** — `lib/d2c/data/live_d2c_repository.dart` `dashboard()`: branch on `deviceType` (derive from the session rows / current device) to compute the right aggregates. `activeMinutes` is universal (works both); distance/gait summed when present.
4. **Rendering** — `d2c_dashboard_screen.dart`: registry-driven `_StatRow`, `_DayTrendCard`/`_DayBar` (active-min bars for rollator), `_RecentWalksSection`/`_WalkRow` (distance + active-min instead of steps). Greeting copy parameterized off the hero metric (active-min "lighter/stronger day", **never** steps). **Distance renders "—" when null** (firmware confidence-gates it on stationary sessions); **gait hidden when null**.
5. **History** — `d2c_history_screen.dart`: same registry-driven chart metric.

**Edges / decisions:**
- **Dashboard-level `deviceType` source:** latest activity row's `deviceType` (reliable once there's activity) vs the current device's type (needed pre-first-walk). Prefer current-device when available, else latest row.
- **Mixed-device patient-day** (a patient reassigned walker↔rollator mid-window → mixed-type rows): key the framing on the **current** device's type; sum the universal `activeMinutes` across all; show type-specific stats per the current type. Rare (DT-I3: `deviceType` immutable per assignment); acceptable as v1.

---

## WS2 — Q8 behavioral re-key (steps → activeMinutes)

**Current:** `behavioral-detector` deployed (hourly EventBridge). 5 rules; **3 are steps-keyed** and mis-fire on a rollator (no steps):
- `no_activity_today` (CRITICAL, local-09:00): `sum(steps) == 0` → **`sum(activeMinutes) == 0`**.
- `below_typical_activity` (local-22:00): `today_steps < 0.70 × median7d` → activeMinutes.
- `declining_trend` (local-22:00): `median7d < 0.85 × medianPrior23d` → activeMinutes.
- `device_offline` / `device_silent` — `lastSeen`-based, **untouched**.

**Change surface** (`infra/lambda/behavioral-detector/`):
- `history_window.py`: `sum_steps()` (147–149) + `aggregate_steps_per_day()` (106–144) → aggregate the `activeMinutes` field.
- `handler.py`: the `_today_steps()` cache + rule invocations (412, 418) → activeMinutes.
- `rules/{no_activity_today,below_typical,declining_trend}.py`: param + alert-`data` key renames (`stepsToday` → `activeMinutesToday`, etc.).
- `tests/test_rules.py`: re-key fixtures.

**⚠ These are UNIVERSAL rules — the re-key changes WALKER behavior too.** `activeMinutes` medians are coarser (minutes vs steps), so the 0.70/0.85 *ratios* carry over but need an **empirical check that walker alert rates don't drift**. No per-`deviceType` threshold override at MVP. Precedent: the DT-0 auto-resume already re-keyed on `activeMinutes` (`AUTO_RESUME_MIN_ACTIVE_MIN`).

**Launch gate (Q8):** must be live **before the first real rollator household patient** — else `no_activity_today` fires CRITICAL every morning for every rollator patient.

---

## WS3 — SMS-OTP go-live (Twilio)

**Current:** the D2C SMS-OTP custom-auth is **fully built + deployed** (§C37) — `d2c-custom-auth` (Define/Create/Verify triggers), reads creds from Secrets Manager `gosteady/dev/twilio`, sends via the Twilio REST API (stdlib, no SDK), 6-digit CSPRNG code, 3-attempt cap. **Fail-closed:** an empty/absent secret raises at first OTP attempt (no misleading "sent").

**Change surface: NONE (code).** Go-live is a **pure operator step**:
1. Populate `gosteady/dev/twilio` (`account_sid`, `api_key_sid`, `api_key_secret`, `from`) — per `docs/playbooks/d2c-twilio-setup.md`. No redeploy; the Lambda reads at next cold start.
2. Smoke: a real-phone D2C sign-in → confirm the SMS code arrives.

**Test bypass** (decouples the rest from SMS): admin-mint a D2C JWT (`aws cognito-idp admin-initiate-auth`) to test claim → activation → dashboard without a real phone.

**Out of scope:** SMS **alerts** (low-battery / offline pushes) = `d2c.md` Phase 2, a separate effort. DT-4 is SMS-OTP (sign-in) + the claim/dashboard loop only.

---

## WS4 — `deviceType`-aware claim/`setup` + D11 wrap-up

**Current:** `d2c-claim` **already snapshots `deviceType`** onto the assignment at claim-provision (`handler.py:307`) ✓. Gaps:

**Change surface:**
1. **Public lookup** — `d2c-claim/handler.py` `_public_lookup` (~215–226): add `deviceType` to the `GET /public/walkers/{walkerId}` response so the `/setup` landing can personalize copy. (`deviceType` = walker vs rollator; not sensitive → safe on an unauthenticated endpoint.)
2. **`/setup` copy** — `lib/d2c/screens/d2c_onboarding_screens.dart`: hardcoded "cap" (lines 183, 366) and "walker" (180/223/…) → `deviceType`-aware strings, keyed off the public-lookup `deviceType`.
3. **D11 fix — `status_patientId` format** (`d2c-claim/handler.py:155`): writes `active#{id}` (hash) vs canonical `active_{id}` (underscore) that the shared `/me/patients` GSI reader (`begins_with("active_")`) expects. **Latent bug — likely masks the D2C patient list.** Fix to `active_{id}`; **verify current D2C patient-list behavior first** (may already be broken/worked-around).
4. **D11 — `walkerId → claimId` rename** *(decision, see §Open)*: cosmetic; the opaque QR id isn't walker-specific.
5. **D11 — dedicated D2C test device:** provision a rollator in a D2C-testable serial (e.g. from the rollator dev/prod block), `deviceType=rollator_platform`, so D2C testing stops contending with the facility unit `GS0000000001`.

---

## Sequencing

- **WS3 (secret)** — operator, do first / in parallel; unblocks the end-to-end.
- **WS1 / WS2 / WS4** — independent code, parallelizable.
- **WS2 must land before** any real rollator household patient (launch gate).
- **Exit test** needs all four + the dedicated D2C rollator test device + a real phone.

## Testing

- **WS1:** Flutter widget/golden tests for rollator rendering (no steps; "—" distance / hidden gait on null). Exercise against `GS9999999981`'s live rollator activity (it's `active_monitoring` on `rol-0.1.0-ww`, §C53) once it records a rolling session.
- **WS2:** re-keyed unit tests + a **walker alert-rate regression** check (universal-rule change).
- **WS3:** real-phone SMS smoke.
- **WS4:** GSI-reader test after the `status_patientId` fix; per-type `/setup` copy; claim end-to-end.
- **Exit:** the full launch-bar loop (real user, QR + SMS, activate, rolling session, dashboard) — the DT-4 done bar.

## Open decisions

1. **`walkerId → claimId` scope:** (a) rename the API param + route + frontend + audit but **keep the physical `by-walker-id` GSI** (renaming a GSI needs recreate + backfill — not worth it for cosmetics) *(recommended)*; (b) full rename incl. GSI; (c) defer entirely (lowest value).
2. **Mixed-device patient-day rendering** — key on current device's type + universal active-min *(recommended)*, vs group-by-type.
3. **Dashboard `deviceType` source** — current-device projection (verify it's surfaced; tiny add if not) vs latest activity row.

## Risks

- **WS2 shifts walker alert behavior** (universal rules) — validate walker rates before/after.
- **WS4 `status_patientId` fix** touches D2C patient visibility — confirm the current (buggy) behavior first so the fix is understood, not just applied.
- **Rollator distance is a within-resident trend** (~26–31% MAPE, §C52) and confidence-gated — the dashboard must frame it as a trend and blank gracefully, not present it as a precise odometer.

## Changelog

| Date | Change |
|---|---|
| 2026-07-08 | Initial DT-4 scope — four workstreams (rendering / behavioral re-key / SMS-OTP / claim+D11) from a 6-agent discovery pass; exit bar + sequencing + open decisions |

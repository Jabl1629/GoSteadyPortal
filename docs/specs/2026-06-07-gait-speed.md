# Gait Speed — cross-team design spec (firmware → algo → cloud → portal)

> **Status:** Design locked 2026-06-07 (Jace + Claude). Not yet implemented.
> **Repos:** `gosteady-firmware` (emit) · `gosteady-portal` (cloud + portal).
> **Coord log:** firmware-coordination `2026-04-17-cloud-contracts.md` §C46.
> **Supersedes:** the "V1.1 gait" placeholder in
> [`phase-2b-fac-r-facility-reads.md`](phase-2b-fac-r-facility-reads.md) L8 / Q1.

---

## 1. Why

Gait speed is the clinical "sixth vital sign" — the single most predictive
mobility signal for fall risk and functional decline in elderly walker users.
User-needs **US-19** wants a gait-speed chart (avg / min / max, displayed in
**ft/sec**); **US-09/10** want it as a census column with the explicit rule
that gait is **not tiered** (no absolute "good/bad" speed).

The entire stack was *built anticipating gait and then suppressed*:

- **Portal** already models `avgGaitSpeed*` / `min` / `max`, renders a chart
  (`lib/widgets/activity_timeline.dart`), has census columns with a ready
  `mpsToFps = 3.28084` conversion, and fully populates gait from demo data —
  but **zeroes it in live mode** (`session_adapter.dart`,
  `live_facility_repository.dart:361`) and hides the chart via
  `hideGait: BuildMode.current.isLive`.
- **Cloud** carries `roughnessR` / `surfaceClass` / `firmwareVersion` as
  optional activity fields but **no gait**.
- **Firmware** computes everything needed but emits nothing.

This spec fills the gap end-to-end. It also folds in two algorithm fixes the
gait work surfaced, because gait inherits every bias in distance and walking
time, and because one of them (step over-count) is a *live* data-quality
problem caregivers already see.

---

## 2. Decisions (locked)

| # | Decision | Rationale |
|---|----------|-----------|
| D1 | **Unit on the wire + storage = feet/second (ft/s).** | Device-native (distance is already in ft → no lossy MCU conversion); matches US-19's display unit; lets us retire the portal's current m/s-store / ft/s-display split. |
| D2 | **Firmware emits one session-average gait value** (not per-bout min/max). | `distance_ft` and walking-time both already exist on-device; no new on-device segmentation. Portal derives window min/max as the spread *across sessions* in the hour/day. |
| D3 | **Firmware pre-computes gait; cloud does NOT derive it.** | `active_min` is integer-rounded (a 16 s walk → 0 → divide-by-zero) and the cloud never sees the float walking-time. Only firmware has the float numerator + denominator. |
| D4 | **Gait denominator = peak-train walking time, NOT `motion_duration_s`.** | `motion_duration_s` is inflated by the motion gate's 2 s `exit_hold` tail per bout + non-walking jostle → systematically *under-estimates* gait, worst for short/fragmented walks (corrupts the trend, not just the absolute). See §3.2. |
| D5 | **Reported `steps` becomes a decoupled, de-satellited count** (refractory-merge ~0.8 s), while distance keeps the full impulse train untouched. | The current "step detector" is an impulse detector tuned ~1.5× (worst at slow gait); measured live as 53 vs 33. Merge-0.8 cuts step error 47 %→16 % and the slow-walk case 78 %→7 % at **zero cost to distance**. See §3.1. |
| D6 | **Gait is a within-resident trend, never an absolute clinical value.** | Distance carries a 22 % MAPE floor (single-feature model, 8+8-walk calibration) that gait inherits. Matches US-10 "no tiering on gait". Enforced as a UI/spec invariant, §6. |

**Out of scope (deferred):** 6-month / weekly gait (gated on the unbuilt
Phase 1C daily rollup); the fast-walk step under-count and a cadence-adaptive
counter (v1.5, needs more labeled data); the multi-feature distance retrain
(v1.5). See §8.

---

## 3. Algorithm changes (firmware `src/algo/` + `src/session.c`)

All three changes live at **session finalize** — the per-sample hot path is
untouched. The distance/roughness/surface pipeline is **unchanged**; these add
two derived outputs (a corrected step count, a walking-time) and one emitted
metric (gait).

### 3.1 Decoupled step counter (D5)

**Problem.** The step FSM is deliberately loose (enter 0.02 g, exit 0.005 g,
min-gap 0.5 s) so it fires **~2 acceleration impulses per perceived step** —
"the stride regression absorbs the ratio" for *distance*
(`algo/distance_estimator.py:67-71`). The emitted `n_peaks` is therefore an
**impulse count, not a step count**: measured **mean 1.47×** over-count across
15 hand-counted walks, but **variable 1.00–2.00×, worst for slow gait**
(slow walks 1.71×/1.84×; fast 1.20–1.27×). Mechanism: the two sub-impulses per
step spread *proportionally* with step period, so slow walking separates them
past the 0.5 s refractory → both counted. The live 53-vs-33 (1.61×) is a slow
walk sitting squarely in this distribution.

**Fix — a post-hoc refractory merge applied to the count only.** Walk the
emitted peak times (`peak_indices[] / GS_FS_HZ`) once at finalize; count a
peak as a step only if it is ≥ `GS_STEP_MERGE_GAP_S` from the last *kept*
step:

```
kept = (N_peaks > 0) ? 1 : 0
t_last = t[0]
for i in 1..N_peaks-1:
    if (t[i] - t_last) >= GS_STEP_MERGE_GAP_S:   # 0.8 s
        kept++; t_last = t[i]
steps = kept           # reported on the wire
# distance pipeline still consumes ALL N_peaks (sum_amp, intercept·N) — unchanged
```

**Measured (15 labeled walks, `algo/_stepcounter_proto.py`):**

| counter | step MAPE | ratio mean | slow err | normal | fast |
|---|---:|---:|---:|---:|---:|
| current (0.5 s) | 47.1 % | 1.47 | 77.8 % | 45.7 % | 23.6 % |
| **merge 0.8 s** | **15.6 %** | **0.95** | **7.4 %** | 14.7 % | 28.6 % |
| autocorrelation-cadence | 40.3 % | 1.29 | 12.7 % | 42.4 % | 56.8 % |
| amp-aware (best: gap 1.2, ratio 0.7) | 16.7 % | 1.01 | 29.8 % | 13.8 % | 19.1 % |

Two refinements were prototyped and **rejected on data**: an autocorrelation
cadence counter (worse + unstable — locks onto the sub-impulse half-period),
and an amplitude-aware merge (recovers fast walks but re-breaks slow, net
worse — the satellite isn't reliably smaller than the step in slow gait). The
plain refractory-merge is the optimum at this n. The residual fast-walk
under-count and the ~15 % floor are the v1.5 story.

**Param:** `GS_STEP_MERGE_GAP_S = 0.8` — single re-tunable knob; re-fit as
labeled walks accumulate (collection paused at 19/30). Add to the generated
algo header via `algo/export_c_header.py` (do not hand-edit
`gosteady_algo_params.h`).

**Contract note:** `steps` keeps its name but its *meaning* sharpens (drops
~30 %). Cohort dashboards split pre/post on `firmware_version`. The raw
impulse count stays in the `ALGO_V1A` uart0 log line for retrain; it is **not**
put on the wire (snippets already carry the raw IMU for offline recompute).

### 3.2 Clean walking-time denominator (D4)

**Problem.** `motion_duration_s` (the σ-gate's in-motion sample count ÷ fs)
keeps counting as "in motion" for up to **2.0 s after the walker actually
stops** — `exit_hold_samples = 200`, and `motion_sample_count++` fires every
sample during the hold (`gs_motion_gate.c:90-109`). It also counts non-walking
jostle. As a gait denominator this biases speed low by ~+2 s per bout —
structure-dependent, so it corrupts the trend.

**Fix — derive walking-time from the same peak train that produces distance**,
so numerator and denominator are consistent (also resolves the
numerator-from-step-FSM / denominator-from-σ-gate mismatch):

```
gaps  = [ t[i] - t[i-1]  for i in 1..N_peaks-1 ]
gated = [ g for g in gaps if g <= GS_STRIDE_GAP_CAP_S ]      # 2.5 s; drop between-bout pauses
walking_time_s = sum(gated) + median(gated)                 # +1 stride for the leading edge
gait_speed_fts = distance_ft / walking_time_s
```

- `GS_STRIDE_GAP_CAP_S = 2.5 s` — a gap longer than this is standing between
  bouts, not walking; excluded so multi-bout sessions don't dilute speed.
- `+ median(gated)` approximates the leading/trailing partial stride the span
  `t[N-1] - t[0]` (= N-1 intervals) omits; second-order for the ratio.
- `active_min` is **unchanged** — it stays the σ-gate "time in motion" metric
  the activity charts use. Walking-time is gait's *internal* denominator and
  is **not** separately emitted (optional `walking_s` diagnostic may be enabled
  during bench validation, then dropped).

### 3.3 Guards (D2 floor + A3 long-session)

Emit `gait_speed_fts` **only if all hold**, else omit the field entirely
(absent → portal renders "no gait", never a zero or a wrong number):

| Guard | Condition to emit | Why |
|---|---|---|
| Floor — steps | merged `steps` ≥ `GS_GAIT_MIN_STEPS` (5) | too few steps → no meaningful cadence |
| Floor — time | `walking_time_s` ≥ `GS_GAIT_MIN_WALK_S` (3.0) | guards divide-by-near-zero |
| Long-session | NOT `buffer_overflowed` AND `n_peaks < GS_PIPELINE_MAX_PEAKS` | distance freezes at the 512-peak cap / 120 s buffer while walking-time keeps growing → gait would falsely collapse (`gs_pipeline.c:90-94`) |

---

## 4. Wire contract delta (`gs/{serial}/activity`)

One new **optional** field; everything else unchanged. Mirrors the existing
`roughness_R` conditional-emit pattern in `cloud.c::build_activity_payload()`.

| Field | Required | Validation | Notes |
|---|---|---|---|
| `gait_speed_fts` | No | Float, 0–10 | Session-average walking speed, ft/s. **Absent** when §3.3 guards fail. |

Example:
```json
{"serial":"GS0000001234","session_start":"...","session_end":"...",
 "steps":33,"distance_ft":50.1,"active_min":1,
 "roughness_R":0.21,"surface_class":"indoor","firmware_version":"0.16.0-gait",
 "gait_speed_fts":1.85}
```
`steps` here is the **merged** count (§3.1). Payload stays within the 384-byte
`ACTIVITY_PAYLOAD_MAX`.

---

## 5. Cloud-side changes (`gosteady-portal/infra`)

Thread one optional field through, mirroring `roughnessR`:

1. **`infra/lambda/activity-processor/handler.py`**
   - Add `gait_speed_fts` to `NAMED_FIELDS`.
   - Validate: float, 0–10 (reject out-of-range; absent is fine).
   - Write `gaitSpeedFts = Decimal(str(...))` to the Activity Series item when
     present (camelCase, like `roughnessR`).
2. **`infra/lambda/patient-api/handler.py`** — add `gaitSpeedFts` to the
   `_activity_view()` projection returned by `GET /patients/{id}/activity`.
3. **No DDB schema change** (schemaless attribute). No new table.
4. **Deploy** with `--force` (CORS/authorizer unchanged, but keep hygiene per
   the CDK-deploy rule).

---

## 6. Portal-side changes (`gosteady-portal/lib`)

Reconcile the model to **ft/s** (D1) and un-suppress in live mode.

1. **`lib/models/activity.dart`** — rename `avgGaitSpeedMs`/`min`/`max` →
   `avgGaitSpeedFts`/`min`/`max` across `HourlyActivity` / `DailyActivity` /
   `WeeklyActivity`. (Field is now ft/s; the m/s→ft/s conversion at the call
   sites goes away.)
2. **`lib/api/api_models.dart`** — add `gaitSpeedFts` to `ActivitySession` +
   `fromJson`.
3. **`lib/api/session_adapter.dart`** — populate hourly buckets from the
   per-session gait: `avg` = time-in-motion-weighted mean of sessions in the
   hour; `min`/`max` = min/max session gait in the hour (D2). Stop hard-coding 0.
4. **`lib/data/live_facility_repository.dart`** (`rowStatsFor`, ~line 361) —
   compute the 3-day avg + 30-day-baseline gait trend from the 7d/30d sessions
   it already fetches, instead of zeroing. (Same client-side pattern as steps.)
5. **`lib/widgets/activity_timeline.dart`** — chart unit label `m/s` → `ft/s`;
   summary chip + tooltip already structured for avg/min/max.
6. **`lib/facility_demo/widgets/patient_list_view.dart`** — remove the
   `mpsToFps` conversion (data is ft/s now); column already labeled "ft/sec".
7. **`lib/facility_demo/screens/patient_detail_view.dart:347`** — drive
   `hideGait` off real data presence instead of `BuildMode.current.isLive`
   (e.g. `hideGait: !hasAnyGait`), so it shows in live mode once data flows and
   degrades honestly when a window has no walking.
8. **`lib/facility_demo/data/facility_mock_data.dart`** — convert the demo
   `baselineGaitSpeed*` seeds m/s→ft/s (×3.28) so the demo build stays
   realistic. Demo build must keep working after every commit.
9. **Invariant (D6):** no color tiering on gait columns/chart (US-10).

---

## 7. Validation plan

1. **Host regression** (`tests/host/`) — fixtures already carry
   `expected_distance_ft` + `expected_motion_duration_s`; add
   `expected_steps_merged`, `expected_walking_time_s`, `expected_gait_fts` and
   assert (tolerance ~5 %). Re-run `algo/export_reference_vectors.py`.
2. **Step-count re-fit** — re-run `_stepcounter_proto.py` including any newly
   labeled walks; confirm merge-0.8 still optimal or re-tune the gap.
3. **Denominator de-bias** — quantify `walking_time_s` vs `motion_duration_s`
   on the labeled set (expected: walking-time meaningfully lower) and confirm
   gait values land in a sane walker band (≈1–4 ft/s).
4. **Bench end-to-end** — flash `0.16.0-gait` to `GS9999999998`; walk a
   measured course; confirm `ALGO_V1*` log, the `gait_speed_fts` uplink, the
   `gaitSpeedFts` DDB attr, the `/activity` response, and the chart rendering
   on `dev.portal.gosteady.co`. Pull the **33-step walk** `.dat` first and
   confirm merge-0.8 recovers ~33.
5. **Field** — `GS0000000001` (active for Rosa) shows a gait trend after the
   next walks.

---

## 8. Out of scope

| Item | Why deferred | Lands in |
|---|---|---|
| 6-month / weekly gait | needs the materialized Patient-day rollup | Phase 1C-rollup |
| Per-bout min/max from firmware | D2 — portal derives window spread instead | — |
| Fast-walk step under-count / cadence-adaptive counter | needs more labeled data; amp-aware rejected on n=15 | algo-v1.5 |
| Multi-feature distance retrain (closes 22 % floor) | overfits at n=8; needs n≥24 | algo-v1.5 |
| HP-prime hygiene in `distance_estimator.py` | self-consistent firmware unaffected; 1-line cleanup | opportunistic |

---

## 9. Implementation checklist

**Firmware** (`gosteady-firmware`)
- [ ] `algo/export_c_header.py`: add `GS_STEP_MERGE_GAP_S=0.8`, `GS_STRIDE_GAP_CAP_S=2.5`, `GS_GAIT_MIN_STEPS=5`, `GS_GAIT_MIN_WALK_S=3.0`; regen `gosteady_algo_params.h`; bump `GS_ALGO_VERSION_STR`.
- [ ] `src/algo/gs_pipeline.*`: add `steps_merged`, `walking_time_s`, `gait_speed_fts` to `gs_pipeline_outputs`; compute in `gs_pipeline_finalize` (§3.1–3.3).
- [ ] `src/session.c`: report merged `steps`; set `gait_speed_fts` on the activity struct under the §3.3 guards; extend `ALGO_V1A` log (raw impulses + merged steps + gait).
- [ ] `src/cloud.{h,c}`: add `gait_speed_fts` to `struct gosteady_activity`; conditional emit in `build_activity_payload()`.
- [ ] `tests/host/`: new fixtures + assertions; regen reference vectors.
- [ ] `src/version.h`: bump to `0.16.0-gait`.
- [ ] `GOSTEADY_CONTEXT.md`: update the firmware-side Activity-schema cache + algo section (lockstep).

**Cloud + Portal** (`gosteady-portal`) — §5 + §6.
- [ ] `ARCHITECTURE.md` §7 Activity table: add `gait_speed_fts` row (do this when the code lands, not before).
- [ ] coord `2026-04-17-cloud-contracts.md`: §C46 logged (this design).

---

## 10. Open questions

| # | Question | Lean |
|---|----------|------|
| Q1 | `GS_STRIDE_GAP_CAP_S` (between-bout cutoff) — 2.5 s right for slow walker gait? | Validate on labeled set; a very slow walker's true stride can approach 2 s. |
| Q2 | Should the long-session guard *suppress* gait or emit-with-a-confidence-flag? | Suppress in V1 (simplest, honest); flag is a later refinement once the wire carries confidence. |
| Q3 | Does sharpening `steps` ~30 % need a portal/caregiver-facing note (the number visibly drops on the `0.16.0` cohort)? | Note in release; `firmware_version` already separates cohorts. |
| Q4 | Reconcile US-19 "min/max" semantics with D2 (min/max = across-session spread, degenerate when one session/window)? | Acceptable: a single-session hour shows avg=min=max; range becomes meaningful with multiple sessions. Document in the chart tooltip. |

---

*Owner: Claude (firmware+cloud session, 2026-06-07). Evidence harness:
`algo/_stepcount_probe.py`, `_min_gap_distance_probe.py`, `_stepcounter_proto.py`,
`_stepcounter_ampaware.py` (throwaway probes, removable post-implementation).*

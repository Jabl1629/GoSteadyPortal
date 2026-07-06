# Rollator distance + gait — cloud-side field promotion

> **Date:** 2026-07-06 | **Status:** 🟡 SCOPED (this doc) — implementation next
> **Related:** firmware coord §C52 (distance estimator ported + flashed) · [`2026-07-01-device-types.md`](2026-07-01-device-types.md) D5/D10 · [`ARCHITECTURE.md`](ARCHITECTURE.md) §7.0 · firmware `docs/specs/2026-07-05-rollator-distance-firmware-port.md`
> **Amends:** memo D10 (rollator metric target) — see §2

---

## 1. Why

Firmware §C52 (`rol-0.1.0-ww`, live on `GS9999999981`) now emits **`distance_ft`
+ `gait_speed_fts`** on rollator activity uplinks. The deployed DT-0 validator
([`_shared/device_types/rollator_platform.py`](../../infra/lambda/_shared/device_types/rollator_platform.py))
recognizes only `active_min` as a named metric, so those two fields are **accepted
but swept into the row's `extras` map** (D16 catch-all) — never promoted to the
`distanceFt` / `gaitSpeedFts` columns the portal reads. Net: the rollator's new
distance/gait work is invisible downstream.

This is a **cloud-only** change. The firmware side is done and validated
end-to-end (heartbeat + `device_type: rollator_platform` confirmed in the Shadow;
registry `active_monitoring`). It satisfies the DT-2 **cloud-exit** criterion for
distance/gait ahead of the full DT-2 algo arc, because firmware shipped distance
early.

## 2. Metric-contract change (the decision)

The rollator does **not** produce steps — a frame-mount IMU is wheel-vibration-
dominated (72–98 % of dynamic energy in the 10–45 Hz wheel band, ~0–7 % in the
gait band), so there are no lift-and-place step impulses to count (coord §C52.2,
product-confirmed 2026-07-06). This **amends memo D10**, which set the rollator
target as walker-cap parity *including* `steps`.

| | Before (D10 / DT-0 v0) | After (this spec) |
|---|---|---|
| Required | `active_min` | `active_min` *(unchanged)* |
| Optional (named) | — (`gait_speed_fts` "at parity") | **`distance_ft`, `gait_speed_fts`** |
| `steps` | "required at parity" | **not a rollator metric** — never sent, never promoted; if a stray `steps` appears it stays in `extras` |

Distance/gait are **optional**, not required: firmware confidence-gates both
(omits when `!isfinite` — e.g. a stationary session with no rolling motion →
`active_min` only). They are within-resident **trend** metrics (~26–31 % MAPE),
not precise odometry — same caveat as walker gait.

## 3. Change set

### 3.1 `_shared/device_types/rollator_platform.py`
- `REQUIRED_ACTIVITY_METRICS` — **unchanged** (`("active_min",)`).
- Add bounds `MAX_DISTANCE_FT = 50_000`, `MAX_GAIT_FTS = 10` (reuse walker's).
- `ACTIVITY_NAMED_FIELDS` — add `distance_ft`, `gait_speed_fts` (→ excluded from
  `extras`; handler line 318 unions this set automatically).
- `build_metric_attrs` — promote `distanceFt` + `gaitSpeedFts` using the **drop-
  on-invalid** pattern (mirror walker's optional-gait handling), NOT walker's
  unconditional-distance path, because for the rollator both are optional:
  present → parse → range-check → promote, else drop the field with a warning
  (`distance_out_of_range` / `gait_out_of_range`) and never fail the row.
- `validate_activity_metrics` — **unchanged** (still only presence/range-checks
  `active_min`; distance/gait absence is valid).

### 3.2 `_shared/tests/test_device_types.py`
Add rollator cases: distance+gait promotion (present → `distanceFt`/`gaitSpeedFts`),
omitted → absent from attrs (the confidence-gated path), out-of-range → dropped
with warning, unparseable → dropped silently. Keep the existing assertion that a
stray `steps` is **not** promoted.

### 3.3 Contract docs (lockstep)
- `ARCHITECTURE.md` §7.0 per-type table + the Activity-section per-type note:
  rollator required `active_min`; optional `distance_ft`, `gait_speed_fts`; steps
  N/A. Note the trend caveat.
- `2026-07-01-device-types.md` §3.2 + D10: record the steps-drop amendment
  (rollator metric set = `active_min` + `distance_ft` + `gait_speed_fts`).

## 4. Out of scope (bounded)
- **Handler** (`activity-processor/handler.py`) — no change. Named-vs-extras split
  is automatic via `ACTIVITY_NAMED_FIELDS`; envelope, time resolution, idempotency,
  hierarchy snapshot, `deviceType` denormalization all untouched.
- **Alert enum / thresholds** — no change (rollator alerts still none; thresholds
  still inherit walker per Q3).
- **Portal rendering** — the D2C dashboard per-type widget (show rollator distance
  / active-min, blank distance gracefully when omitted) is **DT-4**, deferred.
- **`steps`** — never promoted for rollator (a stray value stays in `extras`).
- **Firmware** — none; already shipped (§C52).

## 5. Testing & validation
1. `python3 -m unittest test_device_types` (from `_shared/tests/`) — green.
2. **Synthetic** rollator activity publish (distance+gait) against dev → row lands
   with named `distanceFt`/`gaitSpeedFts`, empty `extras`; a stationary payload
   (no distance) lands `active_min`-only, still valid.
3. **Live**: `GS9999999981` is `active_monitoring` — a real **rolling** session
   (needed for `valid=1` distance; bench sessions hit `valid=0` per §C52.5) will
   exercise the full device→cloud→row path once someone rolls it.

## 6. Rollout
Deploy the **Processing** stack (activity-processor bundles `_shared`). No infra /
IAM / table change. **Backward-compatible**: existing rollator payloads without
distance/gait stay valid (fields are optional); walker path byte-identical.

## 7. Decisions log
| # | Decision | Why |
|---|---|---|
| 1 | Steps dropped for rollator | No step impulses on a frame-mount (§C52.2); product-confirmed |
| 2 | Distance + gait **optional**, not required | Firmware confidence-gates/omits them; a valid stationary session sends `active_min` only |
| 3 | Promote to named columns now (not wait for DT-2 exit) | Firmware already emits them live; leaving them in `extras` hides real data from the portal |
| 4 | Reuse walker bounds (dist 0–50k, gait 0–10) | Same physical quantities; cross-type consistency |
| 5 | Drop-on-invalid (not reject) | Optional analytic fields never fail the row (mirrors walker gait) |

## 8. Follow-ups
- Firmware coord doc: append a **§C53** entry (rollator `rol-0.1.0-ww` flashed +
  end-to-end live; cloud distance/gait promotion) once this deploys.
- DT-4: portal rollator rendering (per-type widget registry).

## Changelog
| Date | Change |
|---|---|
| 2026-07-06 | Initial scope — cloud promotion of rollator `distance_ft`/`gait_speed_fts`; steps-drop amendment to D10 |

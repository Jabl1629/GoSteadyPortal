# Design memo: Multi-device-type architecture — adding the rollator accessory platform

> **Date:** 2026-07-01 | **Status:** ✅ DECIDED 2026-07-01 — D1–D11 locked with product owner; Q1–Q15 all resolved (residual TODOs in §10). **DT-0 deployed (dev) same day** ([`phase-dt0-device-type-scaffold.md`](phase-dt0-device-type-scaffold.md), smoke 15/15); DT-1 (firmware bench bring-up + capture readiness) is next
> **Supersedes:** nothing (first formalization of the device-type concept)
> **Related:** [`ARCHITECTURE.md`](ARCHITECTURE.md) §4 (lifecycle), §6 (data model), §7 (MQTT contracts), §16 ("Multi-device per patient" medium-term question) · firmware coord doc (append-only log)

---

## 1. Why this change

GoSteady is adding a second device type: a **frame-mounted board for rollators**,
integrated into an accessory platform (first SKU: a cupholder — a common rollator
accessory). It uses the **same physical board** (Nordic Thingy:91 X / nRF9151 for
prototyping) but **different firmware and different outputs**: a rollator rolls,
so the walker cap's lift-and-place impulse detection (Schmitt peak FSM) does not
transfer; the session-metric pipeline will be new.

Scoping inputs confirmed 2026-07-01:

| Dimension | Answer |
|---|---|
| Form factor | Rollator frame-mount, accessory platform (cupholder first) |
| Output shape | **Session summaries** (event-bounded, like the cap's activity uplink) |
| Patient attachment | **One patient**, provision-by-serial (like the cap) |
| First milestone | **Bench prototype on dev** |
| Go-to-market channel | **D2C-first** (Q13 resolution, 2026-07-01) — launches through the QR-claim/household path; facility channel deferred |

Today, the architecture has no concept of a device type at all: Device Registry
has no `deviceType` attribute, the IoT Thing Type is hard-coded to
`GoSteadyWalkerCap-{env}`, and the activity/alert validators are the walker
contract (`steps`/`distance_ft`/`active_min` required; alert enum
`{tipover, fall, impact}`). Retrofitting a type concept **after** a second
product ships telemetry would mean a painful backfill; adding it now, while the
fleet is 3 dev units, is nearly free.

## 2. New design (one paragraph)

Split the stack along a boundary that already exists informally: a
**device-agnostic Core Device Contract** (identity/certs, `gs/{serial}/*`
topics, heartbeat→Shadow, `cmd` activate/wipe + `last_cmd_id` ack, Shadow
`desired.activated_at` re-check, §C47 time fields, the 5-state lifecycle) that
**every** GoSteady device type must implement verbatim, and a **per-type product
contract** (activity metric schema, alert enum, thresholds, portal rendering).
`deviceType` becomes a first-class, registry-authoritative attribute — snapshotted
onto the DeviceAssignment row at provision and denormalized onto every telemetry
row (same pattern as the hierarchy snapshot, S6) — so ingest handlers learn the
type with zero extra reads and dispatch validation per type. Topics, topic rules,
the lifecycle state machine, 2A-DL endpoints, wipe-ack recycle, and the
connection-coordinator are all shared and unchanged.

## 3. The layer boundary: Core Device Contract vs product contracts

### 3.1 Core Device Contract v1 (applies to ALL device types)

Extracted from ARCHITECTURE §7 / coord-doc contracts as currently implemented by
walker-cap firmware `0.17.0-time`. A new device type is "GoSteady-compatible"
iff it implements:

| Element | Contract |
|---|---|
| Identity | `GS` + 10-digit serial; per-device cert in CryptoCell-312 sec_tag 201; per-thing IoT policy |
| Topics | `gs/{serial}/{heartbeat\|activity\|alert\|snippet}` uplink, `gs/{serial}/cmd` downlink, own-thing Shadow MQTT |
| Heartbeat | Required `serial`, `battery_pct`, `rsrp_dbm`, `snr_db`; optional extras → Shadow `reported` (accept-all D16); hourly cadence |
| Downlink cmds | `activate` + `wipe` with `cmd_id` echo via heartbeat `last_cmd_id`; 24 h ack window; wipe battery floor + Shadow `reported.wipe_complete` |
| Activation | Shadow `desired.activated_at` re-check on every cellular wake; pre-activation gate + persistence |
| Time | §C47 fields (`clock_synced`, `time_source`, session/publish uptimes, `boot_count`); cloud reconstruction contract |
| Lifecycle | 5-state machine (`ready_to_provision` → … → `decommissioned`); wipe-ack auto-recycle; provision-by-serial |
| MQTT | 3.1.1, `CLEAN_SESSION=n`, TLS 1.2, QoS 1 for cmds |

Everything above is device-type-blind in the deployed cloud code today — the
reuse is total **if and only if** new firmware conforms.

### 3.2 Per-type product contracts

| Element | walker_cap (today) | rollator_platform (decided 2026-07-01) |
|---|---|---|
| Activity required metrics | `steps`, `distance_ft`, `active_min` | `active_min` only — `steps` dropped (a frame-mount has no wheeled step impulses; D10 amended 2026-07-06, §C52) |
| Activity optional metrics | `roughness_R`, `surface_class`, `gait_speed_fts`, `firmware_version` | **`distance_ft`, `gait_speed_fts`** (promoted 2026-07-06, [`2026-07-06-rollator-distance-cloud-promotion.md`](2026-07-06-rollator-distance-cloud-promotion.md)); further extras emerge during the algo arc |
| Alert enum | `tipover`, `fall`, `impact` (unused in v1) | **None in v1** (Q11); `rollaway`/brake-state are the candidates at launch planning |
| Threshold defaults | battery 5%/10%, RSRP −120/−110, chemistry-specific OCV + 0.10 wipe floor | Inherits walker defaults until cupholder production hardware exists (Q3); *keyable* by type from DT-0 |
| Behavioral rules | steps-keyed (`no_activity_today`, `below_typical_activity`, …) | Universal rules re-keyed on `activeMinutes` (Q8) — live by DT-4 |
| Portal widgets | steps / distance / gait / activity charts | **D2C dashboard first** (Q10 + Q13, DT-4); facility census generalization deferred |

The **universal activity envelope** is shared across types: `serial`, session
identity (`session_start`/`session_end` + §C47 uptime fields), `firmware_version`,
idempotency on `(patientId, session_end)` + `deviceSessionKey`. Only the metric
block is per-type.

## 4. Decisions log

| # | Decision | Rationale | Status |
|---|---|---|---|
| D1 | `deviceType` is **registry-authoritative**: set at manufacturer-side record creation (`admin bulk-create` gains the field), **snapshotted onto the DeviceAssignment row at provision**, denormalized onto every Activity/Alert row at write time | Patient resolution already fetches the assignment row on every uplink → handlers get the type with zero extra reads; mirrors the S6 hierarchy-snapshot precedent | ✅ DECIDED 2026-07-01 |
| D2 | Serial format unchanged (`GS` + 10 digits), **no type encoding in the serial** | Registry is source of truth; encoding type in serials creates a migration trap and breaks nothing to omit. Reserve documented dev-range *blocks* per type for human convenience only (Q6) | ✅ DECIDED 2026-07-01 |
| D3 | **Shared topic family** `gs/{serial}/{class}` — no per-type topics, no new IoT Topic Rules | Rules route by message class, not product; handlers dispatch on type after resolution. Zero ingestion-infra change | ✅ DECIDED 2026-07-01 |
| D4 | New firmware **must implement Core Device Contract v1** (§3.1) verbatim | Buys the entire lifecycle machinery (2A-DL, wipe-ack recycle, coordinator, provisioning UX, discharge cascade) with zero cloud change — the single highest-leverage reuse decision | ✅ DECIDED 2026-07-01 |
| D5 | **Shared Activity Series table** for rollator sessions: universal envelope + per-type metrics; rollator metrics land in the existing `extras` map during bench, promoted to named columns when they stabilize | Session-summary + one-patient shape is identical to the cap's access pattern (patientId PK, session_end SK, by-date GSI); a separate table buys nothing until access patterns diverge | ✅ DECIDED 2026-07-01 |
| D6 | Per-type payload validation via **dispatch registry** `_shared/device_types/` (`walker_cap.py`, `rollator_*.py`), replacing the module-level `REQUIRED_FIELDS`/`VALID_ALERT_TYPES` constants in activity-processor + alert-handler. Validation of per-type metrics moves **after** assignment resolution (type must be known first); envelope validation stays up front | One shared handler, N schema modules — no per-type Lambda forks. Threshold defaults (`_shared/thresholds.py`) key by type in the same pass | ✅ DECIDED 2026-07-01 |
| D7 | **One IoT Thing Type per device type** (second type alongside `GoSteadyWalkerCap-{env}`); identical per-thing policy template | Thing types are free and are the natural AWS-level cohort for Phase 5A OTA Jobs targeting + fleet segmentation. Fleet-provisioning-template parametrization deferred to 5A (bench units are created manually via the bring-up playbook) | ✅ DECIDED 2026-07-01 |
| D8 | **Firmware monorepo with a product split**: shared platform modules (`cloud.c`, `activation.c`, wipe, forensics, battery, cellular, `gs_time`) + per-product sampler/algo, gated via Kconfig / overlay profile (extends the existing `prj_*.conf` pattern). Mechanics are firmware-side (Q5) | Same board, same NCS, same contract-bearing modules — a fork would immediately drift the Core Device Contract implementations apart | ✅ DECIDED 2026-07-01 |
| D9 | Legacy data: **absent `deviceType` reads as `walker_cap`** (readers default; same convention as the `schema_version` backfill posture). Registry records for existing units get a one-time CLI backfill; historical telemetry rows are NOT backfilled | Absence is unambiguous today (single-type fleet); avoids a scan-and-update of telemetry tables for zero read benefit | ✅ DECIDED 2026-07-01 |
| D10 | Rollator metric target = **walker-cap parity**: `steps`, `distance_ft`, `active_min` required + `gait_speed_fts` optional — reached via a **comprehensive cross-system arc**: capture-rig reuse (data-collection site + uart1 tools on a rollator-mounted dev board) → Python algo build/refine/train → C port + host regression → firmware hardening. Bench v0 contract = `active_min` only (uplinks never block on unproven metrics) | Q2 resolution (product owner, 2026-07-01) — the plan spans firmware/algo/tooling/cloud, not cloud alone; mirrors the cap's proven M8→M10→M14.5 arc | ✅ DECIDED 2026-07-01 · **⚠ AMENDED 2026-07-06:** `steps` dropped (a frame-mount has no step impulses, §C52) → rollator metric set = `active_min` + `distance_ft` + `gait_speed_fts`; cloud promotion [`2026-07-06-rollator-distance-cloud-promotion.md`](2026-07-06-rollator-distance-cloud-promotion.md) |
| D11 | **D2C-first go-to-market** for the rollator platform. Launch surface is the D2C household path (QR claim + SMS-OTP + D2C dashboard); the D2C wrap-up folds into this effort as phase DT-4, referencing the already-scoped plans ([`d2c.md`](d2c.md) 5-phase umbrella; [`d2c-phase1-walker-activation.md`](d2c-phase1-walker-activation.md) deployed to dev per coord §C37; [`d2c-mockup-followups.md`](d2c-mockup-followups.md)). Facility-channel rollator rendering deferred until facility demand | Q13 resolution (product owner, 2026-07-01) — reverses the facility-first lean. External gate: Twilio compliance approval + `gosteady/dev/twilio` secret (operator, in progress) | ✅ DECIDED 2026-07-01 |

## 5. `deviceType` data model

### Device Registry (`gosteady-{env}-devices`)

| Attribute | Type | Notes |
|---|---|---|
| `deviceType` | S | Enum, e.g. `walker_cap` \| `rollator_platform` (naming: **Q1**). Set at `device.created`; absent = `walker_cap` (D9) |
| `hardwareVariant` | S | Optional — accessory SKU within a platform (e.g. `cupholder_v1`). Pending Q1 taxonomy decision |

Mutability: see **Q4** — proposal is immutable except by `internal_admin`, only in
`ready_to_provision`/`decommissioned`, heavily audited (`device.type_changed`),
because dev-bench reality is that the same Thingy:91 X can be re-flashed between
products.

### DeviceAssignments

`deviceType` snapshotted onto the assignment row at provision (D1). Frozen for
the life of the assignment — a re-flash mid-assignment is not a supported flow.

### Activity Series / Alert History

`deviceType` denormalized onto every row at write time, next to the hierarchy
snapshot. Rollator per-type metrics live in `extras` during bench (D5).

### Audit

- `device.created` payload gains `deviceType` (+ `hardwareVariant` when present)
- New event `device.type_changed` (Q4 path only; internal_admin; elevated audit)

## 6. Ingestion + processing changes (DT-0 scope)

1. **activity-processor** — split validation: envelope check up front (unchanged),
   per-type metric check after assignment resolution via `_shared/device_types/`
   dispatch. `activity_reject` metric gains a `deviceType` dimension.
2. **alert-handler** — `VALID_ALERT_TYPES` moves into the per-type schema module.
3. **threshold-detector** — `_shared/thresholds.py` defaults keyed by
   `deviceType` (per-patient overrides unchanged; merge order: type defaults ←
   patient overrides).
4. **heartbeat-processor** — no change (heartbeat is Core Contract).
5. **device-api / patient-mgmt** — `admin bulk-create` accepts `deviceType`;
   provision snapshots it onto the assignment row; `GET /devices/{serial}`
   returns it.
6. **ingestion-stack.ts** — second `CfnThingType`; nothing else (D3).
7. **behavioral-detector** — NO change in DT-0. Per Q8's resolution the
   universal rules re-key on `activeMinutes`; that lands as a **DT-4 launch
   gate** (D2C household patients are real patients — the rules must be
   type-correct before the first rollator claim), not a DT-0 blocker (bench
   units aren't assigned to real patients).

## 7. What does NOT change (bounded scope)

- Cognito / authz / tenancy / RBAC — device-type-orthogonal
- Device lifecycle state machine, all 10 2A-DL endpoints, discharge cascade,
  wipe-ack auto-recycle, connection-coordinator (D4)
- Topics, IoT Topic Rules, per-thing policy shape (D3)
- DeviceAssignments access patterns, patient resolution
- Snippet pipeline (binary header already reserves `sensor_id`; `format_version`
  gates future changes)
- Audit pipeline, hosting, observability plumbing (per-device dashboard
  battery/signal widgets are generic; the recent-activity widget's walker
  columns are a DT-2 cosmetic)
- D2C claim/household machinery is **reused as-built** (QR claim, SMS-OTP
  custom auth, household bootstrap, D2C Cognito pool) — `d2c-claim` gains only
  the `deviceType` snapshot at claim-provision (DT-0) and `/setup` landing copy
  (DT-4); `walkerId` naming is a cosmetic rename (Q13 residual)

## 8. Phasing

> Restructured 2026-07-01 after the Q2 (comprehensive cross-system arc) and
> Q13 (D2C-first) resolutions. DT-1→DT-3 mirror the walker cap's proven
> milestone arc (M1–M7 bring-up → M8–M10 data/algo → M14.5 hardening),
> heavily compressed by reuse; DT-4 is launch readiness on the **D2C** path.
> DT-0 and the DT-4 cloud/product work can run in parallel with the
> firmware-led middle; the Twilio external gate should be driven to closure
> early since it's out of our hands.

### DT-0 — cloud scaffold (small; all backward-compatible)
`deviceType` on registry + bulk-create + assignment snapshot (device-api,
patient-mgmt, **and d2c-claim**) + telemetry rows; `walker_cap` CLI backfill
of registry records; second Thing Type; validation dispatch refactor
(`_shared/device_types/`); thresholds *keyable* by type (rollator inherits
walker values per Q3); heartbeat `device_type` cross-check + mismatch alarm
(Q7); serial-block allocation recorded in the coord doc (Q6); ARCHITECTURE §7
restructure into Core Device Contract v1 + per-type appendices (Q12).
**Exit:** walker-cap end-to-end regression green (synthetic activity /
heartbeat / alert + one physical-cap smoke + one synthetic D2C claim); a
synthetic rollator activity publish (`active_min`-only) lands in Activity
Series with `deviceType` + metrics in `extras`.

### DT-1 — bench bring-up + capture readiness (M1–M7-equivalent; mostly reuse)
Firmware product split (D8: Kconfig gate + `prj_rollator*.conf`) implementing
Core Device Contract v1 verbatim; capture tooling verified on a
**rollator-mounted dev board** — the walker cap's data-collection site
(`capture.html` on GitHub Pages) + `control.py` + `pull_sessions.py` carry
over unchanged per Q14; **rollator capture protocol doc + annotation
spreadsheet** (surfaces, speeds, turns, brake use); bench unit bring-up per
the existing playbook against the new Thing Type + registry record (serial
from the `GS9999999980–89` block).
**Exit:** provision → activate → recorded rollator session (`active_min`-only
contract) → activity row carrying `deviceType` → per-device dashboard; End
Monitoring → wipe → auto-recycle roundtrip on rollator firmware; one full
operator-driven capture session collected, pulled, and ingested through the
reused tooling.

### DT-2 — data collection + algorithm arc (M8–M10-equivalent; **the long pole**)
Structured dataset capture on the rollator rig per the DT-1 protocol doc;
Python algorithm development for wheeled motion (distance, steps, gait);
refine + train; C port + host regression suite; on-device validation walks.
**Exit:** activity contract converges to **walker-cap parity** (D10) —
`steps`, `distance_ft`, `active_min` required, `gait_speed_fts` optional —
with documented MAPE on a held-out set; cloud promotes rollator metrics from
`extras` to named columns and flips the validation schema from v0 to the
parity set.

### DT-3 — firmware hardening (M14.5-equivalent)
FMEA pass on the rollator duty cycle; field/low-power overlay; power
validation; soak run; battery/OCV/wipe-floor values from real cupholder
hardware (Q3 residual); pre-activation shipping-mode behavior on the
accessory platform.
**Exit:** M14.5-style punch list closed or explicitly deferred with rationale;
≥7-day soak clean.

### DT-4 — D2C launch readiness (cloud/product-led; parallelizable with DT-2/3)
Rollator QR-claim end-to-end (`deviceType`-aware claim + `/setup` landing
copy); Twilio SMS-OTP live (**external gate:** compliance approval +
`gosteady/dev/twilio` secret — operator, in progress per coord §C37); D2C
dashboard rollator rendering (the Q10 per-type widget registry lands here
first); behavioral rules re-keyed on `activeMinutes` (Q8) live for
households; D2C wrap-up per D11 — §C41.3 follow-ups (`status_patientId`
underscore alignment, `walkerId` → `claimId` rename, dedicated D2C test
device) + the remaining [`d2c.md`](d2c.md) phases as scoped there
(deactivation/reset, new-user reuse; caregivers phase per product priority).
**Exit (launch bar):** a real user claims a rollator unit via QR + SMS,
activates it, records a session, and sees the full parity metric set on the
D2C dashboard — no operator intervention anywhere in the loop.

**Deferred behind facility demand:** facility-channel rollator support
(census "Active today" generalization, facility provisioning UX copy). The
plumbing is shared; this is rendering work only.

## 9. New invariants

| # | Invariant |
|---|---|
| DT-I1 | Every Device Registry record created ≥ DT-0 carries `deviceType`; readers treat absence as `walker_cap` |
| DT-I2 | `deviceType` never changes while status ∈ {`provisioned`, `active_monitoring`, `discontinued`} (see Q4 for the allowed path) |
| DT-I3 | The assignment-row `deviceType` snapshot is immutable for the life of the assignment |
| DT-I4 | Any new device type implements Core Device Contract v1 (§3.1) before its first cloud-connected bench unit — no per-type forks of lifecycle/heartbeat/cmd semantics |
| DT-I5 | Per-type metric validation never rejects on unknown *extra* fields (D16 accept-all is Core, not per-type) |

## 10. Open questions — ALL RESOLVED 2026-07-01

> Resolved with the product owner in the 2026-07-01 scoping session. 13 of 15
> ratified as leaned; **Q2 upgraded** (comprehensive cross-system arc + cap
> parity → D10) and **Q13 reversed** (D2C-first → D11). Residual TODOs that
> survive the resolutions are tabled at the end. Owners: F = firmware-led,
> C = cloud-led, P = product-led.

- [x] **Q1 (P/C)** — Taxonomy. **RESOLVED (as leaned):** single
  `deviceType: rollator_platform` + `hardwareVariant: cupholder_v1`. A *type*
  = board + firmware + output contract; the accessory is packaging. A future
  accessory earns a new type only if its sensors/outputs change.
- [x] **Q2 (F/P)** — Metric set + development arc. **RESOLVED (UPGRADED from
  lean → D10):** target is **walker-cap parity** — `active_min`,
  `distance_ft`, `steps` required + `gait_speed_fts` optional — reached via a
  comprehensive cross-system arc: capture-rig reuse (the walker cap's
  data-collection site + uart1 tools on a rollator-mounted dev board) → build
  the rollator algorithms → refine + train → C port → harden firmware. Bench
  v0 contract remains `active_min`-only so uplinks never block on unproven
  metrics. Phases DT-1→DT-3 carry the arc.
- [x] **Q3 (F)** — Battery config. **RESOLVED (as leaned, "for now"):**
  rollator inherits walker threshold/OCV defaults; fork per-type values when
  cupholder production hardware exists (residual TODO → DT-3). DT-0 only makes
  thresholds keyable by type.
- [x] **Q4 (C)** — Type mutability. **RESOLVED (as leaned):** mutable by
  `internal_admin` only, state-gated to `ready_to_provision`/`decommissioned`,
  `device.type_changed` elevated audit, IoT Thing Type updated in lockstep.
  (Serial is physically printed on the device — decommission + new record was
  a non-starter.)
- [x] **Q5 (F)** — Firmware split. **RESOLVED (as leaned):** Kconfig product
  gate (`CONFIG_GOSTEADY_PRODUCT_ROLLATOR`) + `prj_rollator*.conf` overlay
  family in the same app; platform modules stay literally shared. Rollator
  version line `rol-0.1.0-…`; cap line unchanged.
- [x] **Q6 (C/F)** — Serial blocks. **RESOLVED (as leaned):** dev/bench
  `GS9999999980–89`; rollator production `GS0001000000–GS0001999999`; caps
  continue from `GS0000000001`. Convenience only — registry authoritative
  (D2). Allocation table lands in the coord doc at DT-0.
- [x] **Q7 (C/F)** — Firmware self-report. **RESOLVED (as leaned):**
  `device_type` in the heartbeat (lands in Shadow via accept-all D16);
  heartbeat-processor cross-checks vs registry; mismatch → structured log +
  EMF metric + `device-type-mismatch` alarm; **never reject** (registry wins).
- [x] **Q8 (C/P)** — Behavioral rules. **RESOLVED (as leaned):** universal
  rules re-key on **`activeMinutes`** (`no_activity_today` →
  `activeMinutes == 0`; trend rules → activeMinutes medians);
  `device_offline`/`device_silent` untouched. **DT-4 launch gate** — must be
  live before the first rollator reaches a real (household) patient.
- [x] **Q9 (P/C)** — Multi-device aggregation. **RESOLVED (as leaned):** sum
  across devices for patient-day totals (one aid ambulates at a time);
  per-device breakdown via `deviceSerial`/`deviceType` on rows; revisit only
  on observed overlap. Resolves the ARCHITECTURE §16 medium-term question.
- [x] **Q10 (P/C)** — Portal rendering. **RESOLVED (as leaned, with D2C-first
  ordering):** shared surfaces use universal metrics (active minutes,
  distance); detail surfaces use a per-type widget registry (`deviceType` →
  widget list) — landing in the **D2C dashboard first** per Q13/D11. Facility
  census "Steps today" → "Active today" deferred with the facility channel.
- [x] **Q11 (P/F)** — Rollator alerts. **RESOLVED (as leaned):** none in v1
  (mirrors the cap's v1 anti-feature). Define at launch planning; candidates
  `rollaway`/brake-state rather than `tipover`.
- [x] **Q12 (C/F)** — Contract docs. **RESOLVED (as leaned):** at DT-0,
  ARCHITECTURE §7 → §7.0 Core Device Contract v1 + §7.1 walker_cap + §7.2
  rollator_platform (stub). One append-only coord doc, continuous §C
  numbering, `[cap]`/`[rollator]` title tags — no forked log.
- [x] **Q13 (P)** — Channel. **RESOLVED (REVERSED from lean → D11):** the
  rollator platform goes **D2C-first**. The D2C wrap-up folds into this effort
  as DT-4, referencing the already-scoped plans — [`d2c.md`](d2c.md) 5-phase
  umbrella, [`d2c-phase1-walker-activation.md`](d2c-phase1-walker-activation.md)
  (deployed to dev, coord §C37), [`d2c-mockup-followups.md`](d2c-mockup-followups.md),
  [`d2c-userdemo.md`](d2c-userdemo.md). External gate: Twilio compliance
  approval + `gosteady/dev/twilio` secret (operator, in progress).
- [x] **Q14 (F)** — Tooling reuse. **RESOLVED (as leaned):** capture.html /
  control.py / pull_sessions.py carry over unchanged (uart1 protocol + `.dat`
  format are product-agnostic); snippet `sensor_id` stays `1` (same BMI270).
  M8-equivalent deliverable = rollator capture protocol doc + annotation
  spreadsheet (DT-1), not new tooling.
- [x] **Q15 (C)** — Rollups. **RESOLVED (as leaned):** `activeMinutes` is the
  universal rollup metric; rollup row = `activeMinutes` + `distanceFt` +
  `steps` (nullable), summed across devices per Q9; 6M tab renders
  activeMinutes primary. Type-specific extras stay out of rollups until a
  concrete need appears.

### Residual TODOs (survive the resolutions)

| TODO | Owner | Where it lands |
|---|---|---|
| Twilio compliance approval + populate `gosteady/dev/twilio` secret | Operator (in progress) | Gates DT-4 SMS-OTP; drive early — external |
| Rollator battery/OCV/wipe-floor values from real cupholder hardware | Firmware | DT-3 |
| Rollator alert-type definition (`rollaway`, brake-state candidates) | Product/FW | DT-4 launch planning |
| §C41.3 D2C follow-ups: `status_patientId` underscore alignment in `d2c-claim`; `walkerId` → `claimId` rename; dedicated D2C test device | Cloud | DT-4 |
| Facility-channel rollator rendering (census "Active today" generalization) | Product/Cloud | Deferred — on facility demand |

## 11. Doc + code surface affected

| Surface | Change | Phase |
|---|---|---|
| `docs/specs/ARCHITECTURE.md` §4/§6/§7/§17 | `deviceType` in Device Registry/Assignments/telemetry tables; Core-vs-product contract split; memo indexed in §17 | DT-0 (lockstep) |
| `docs/firmware-coordination/2026-04-17-cloud-contracts.md` | New coord entry announcing Core Device Contract v1 + rollator scoping; serial-block allocation (Q6) | DT-0 |
| `infra/lib/stacks/ingestion-stack.ts` | Second `CfnThingType` | DT-0 |
| `infra/lambda/_shared/device_types/` (new) | Per-type schema modules + dispatch | DT-0 |
| `infra/lambda/activity-processor/handler.py` | Envelope/metric validation split; per-type dispatch; `deviceType` on rows | DT-0 |
| `infra/lambda/alert-handler/handler.py` | Alert enum → per-type module; `deviceType` on rows | DT-0 |
| `infra/lambda/_shared/thresholds.py` + threshold-detector | Defaults keyed by type (rollator inherits walker values) | DT-0 |
| `infra/lambda/device-api/` + `patient-mgmt/` + `d2c-claim/` | bulk-create `deviceType`; provision + claim snapshot; GET response | DT-0 |
| `infra/lambda/heartbeat-processor/handler.py` | `device_type` cross-check vs registry; mismatch metric + alarm (Q7) | DT-0 |
| `_shared/audit_catalog.py` | `device.type_changed`; `device.created` payload | DT-0 |
| `docs/playbooks/new-dev-unit-bringup.md` | Thing-Type + `deviceType` parametrization | DT-1 |
| gosteady-firmware repo | Product split (D8); Core Contract conformance; capture rig; rollator algo (Python → C port); hardening | DT-1→DT-3 |
| gosteady-firmware `data collection and protocols/` | Rollator capture protocol doc + annotation spreadsheet | DT-1 |
| Activity Series schema + activity-processor | Promote rollator metrics `extras` → named columns; validation v0 → parity set | DT-2 exit |
| Portal `lib/d2c/` (D2C dashboard) + `d2c-claim` `/setup` copy | Rollator rendering via per-type widget registry; claim-flow copy | DT-4 |
| behavioral-detector | Universal rules re-keyed on `activeMinutes` (Q8) | DT-4 (launch gate) |
| 1C-rollup (when built) | Universal-trio rollups summed across devices (Q9/Q15) | With 1C-rollup |
| Per-device dashboard recent-activity widget | Rollator metric columns | DT-2+ (cosmetic) |
| Portal facility surfaces (census "Active today") | Universal-metric generalization | Deferred — facility demand |

## 12. Changelog

| Date | Change |
|---|---|
| 2026-07-01 | Initial scoping memo — D1–D9 proposed, Q1–Q15 opened (scoping session with product owner; form factor = rollator accessory platform, session summaries, one-patient, bench-first) |
| 2026-07-01 (later same session) | Q1–Q15 all resolved with product owner: 13 ratified as leaned; **Q2 upgraded** → D10 (comprehensive cross-system arc, walker-cap metric parity target incl. gait); **Q13 reversed** → D11 (**D2C-first** go-to-market; D2C wrap-up folded in as DT-4). D1–D9 ratified. Phasing restructured DT-0…DT-4 (bring-up/capture → data+algo → hardening → D2C launch readiness); residual-TODO table added |
| 2026-07-01 (implementation) | **DT-0 deployed to dev + exit criteria met** — walker regression green (synthetic + physical-cap heartbeat), synthetic rollator activity landed with `deviceType` + `extras`, synthetic D2C claim path deferred to next d2c smoke (writer line-identical to validated device-api). Coord §C48 announces Core Device Contract v1 + serial blocks to firmware. Spec changelog has full detail |

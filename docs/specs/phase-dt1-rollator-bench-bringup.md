# Phase DT-1 — Rollator Bench Bring-up + Capture Readiness

## Overview
- **Phase**: DT-1 (second phase of the multi-device-type plan — [`2026-07-01-device-types.md`](2026-07-01-device-types.md) §8; follows deployed [DT-0](phase-dt0-device-type-scaffold.md))
- **Status**: 🟡 **Implemented + flashed; bench-validated to the radio boundary** (2026-07-02). All builds/tests/review green; cert + `rol-0.1.0-bench` on `GS9999999981`; 9.5 h fault-free soak; provision + capture-tooling device-half validated. Remaining: **operator SIM claim** (EMM cause 8 = unactivated iBasis trial — A2 realized) + USB re-plug, then the ~15-min user smoke (§Deployment resume runbook)
- **Branch**: portal `feature/infra-scaffold`; firmware direct-to-`main`
- **Date Started**: 2026-07-01
- **Date Completed**: — (pending user smoke)

Ships the **firmware product split** (walker_cap / rollator_platform sharing all
platform code), brings up the first rollator bench unit (**`GS9999999981`**,
fresh Thingy:91 X) against the DT-0 cloud, and makes the **data-collection
stack rollator-ready** (vocabulary, tooling presets, capture page, protocol doc,
annotation workbook) so the DT-2 algo arc can start collecting immediately.
The M1–M7-equivalent is mostly reuse: zero new sensing/session/dump code — the
work is Kconfig/product gating, payload contract gating, append-only vocabulary
extension, and bring-up.

## Locked-In Requirements

| # | Requirement | Decided In | Rationale |
|---|-------------|-----------|-----------|
| L1 | Rollator firmware implements **Core Device Contract v1 verbatim** (ARCH §7.0): activate/wipe cmds + `last_cmd_id` echo, Shadow `desired.activated_at` re-check, heartbeat schema, §C47 time fields, lifecycle semantics | Memo D4 / DT-I4 | Buys the entire deployed lifecycle machinery with zero cloud change |
| L2 | Bench-v0 activity contract: Core envelope + `active_min` **only** — no `steps`/`distance_ft`/`roughness_R`/`surface_class`/`gait_speed_fts` in rollator payloads | Memo D10 / DT-0 spec L6 | Walker stride algo doesn't apply to wheeled motion; parity lands at DT-2 exit |
| L3 | Product split = Kconfig choice + self-contained `prj_rollator*.conf` overlays in the **same app**; platform modules literally shared | Memo D8/Q5 | Contract-bearing code (cloud.c/activation.c/wipe.c) must not fork |
| L4 | Rollator version line `rol-0.1.0-…` (≤31 chars — `firmware_version[32]`, cloud.h:62-65); walker version strings **unchanged** | Memo Q5 + cloud.c truncation history | Cloud cohorts key on `firmware_version`; walker continuity preserved |
| L5 | Heartbeat gains `device_type` for **both** products (walker opportunistically per coord §C48.3) | Memo Q7 | DT-0's cross-check + mismatch alarm are live; catches wrong-product flash at first heartbeat |
| L6 | Capture vocabulary changes are **append-only** across all four copies (src/control.c:65-82, src/session.h:41-93, tools/read_session.py:86-103, annotations workbook Vocabularies sheet) | session.h:38-40 contract | Enums are raw uint8 indices in the 256-B .dat header — insertion corrupts every existing walker capture |
| L7 | Bench unit serial `GS9999999981` from the rollator dev block (`…80` is a DT-0 smoke fixture — never a physical unit) | Memo Q6 / coord §C48.3 | Documented allocation |
| L8 | Bring-up follows [`new-dev-unit-bringup.md`](../playbooks/new-dev-unit-bringup.md) with two parameterizations: Thing Type `GoSteadyRollatorPlatform-dev` + `prj_rollator_cloud.conf` build overlay | Playbook + DT-0 D7 | Flow is product-agnostic otherwise; SW2 stays **nRF91** throughout (factory bridge needs no reflash) |

## Assumptions

| # | Assumption | Risk if Wrong | Validation Plan |
|---|-----------|---------------|-----------------|
| A1 | The fresh board will be powered when the user returns (J-Link reads **VTref = 0 V** as of 2026-07-01 22:00 UTC — SW1 off, charge-only cable, or Tag-Connect unseated) | Physical flash + live validation blocked; everything else in DT-1 is software and completes regardless | §Deployment runbook covers the exact resume-from-power-on sequence; images staged |
| A2 | Nordic-shipped iBasis eSIM on the fresh board works like GS0000000001's (attach + data without operator web steps) | LTE attach fails → heartbeats never arrive; needs SIM activation via nRF Cloud (operator) | First console boot shows `+CEREG` registration; playbook troubleshooting section covers SIM |
| A3 | Walker algo pipeline running on rolling motion produces *harmless* (unpublished) outputs — motion gate remains valid for `active_min` on vibration-rich wheeled movement | `active_min` could over/under-count on smooth rolling if the gate's σ thresholds miss wheeled vibration | Bench: compare gate `motion_s` (ALGO_V1B uart0 log) against wall-clock during rolling tests; DT-2 capture data quantifies |
| A4 | `struct gs_pipeline` RAM (~62 KB .bss) still fits alongside cloud stack in the rollator build (walker cloud build is the proof — same footprint) | Build/link failure or runtime OOM | `west build` RAM report; walker cloud build baseline passed 2026-07-01 |
| A5 | 640 B heartbeat buffer absorbs `device_type` (~30 B; ~200 B headroom measured pre-0.17.0) | `-ENOMEM` fail-closed on heartbeat build (visible, not silent) | Bench console + cloud Shadow inspection |

## Scope

### In Scope
- **Firmware product split**: `GOSTEADY_PRODUCT` Kconfig choice (walker default), product-keyed version cascade + `GS_PRODUCT_DEVICE_TYPE_STR` in version.h, activity-payload gating in cloud.c, heartbeat `device_type` (both products), product-keyed bench/field prewalk constants in main.c
- **`prj_rollator_cloud.conf`** (self-contained per the single-`EXTRA_CONF_FILE` sysbuild constraint; mirror-discipline comments)
- **Vocabulary appends** (all copies): `walker_type += rollator_4wheel`, `cap_type += frame_mount`, `mount_config += accessory_platform`, `run_type += brake_stop, brake_drag, park_brake_seated, heavy_lean`
- **Tooling**: `control.py` rollator presets; `capture_rollator.html` (fork of capture.html with rollator COMMON + 39-run matrix + isolated localStorage keys); `read_session.py` vocab appends
- **Capture assets**: `GoSteady_Rollator_Capture_Protocol_v1.md` + `GoSteady_Rollator_Annotations_v1.xlsx` (same 34-column schema; Vocabularies extended)
- **Cloud prep for `GS9999999981`**: cert + Thing (RollatorPlatform type) + per-thing policy + Device Registry record (`deviceType=rollator_platform`) + handoff bundle per playbook
- **Bench validation** (power-gated): flash → console → LTE → heartbeat w/ `device_type` → provision/activate → uart1 session → activity row (`active_min` only) → End-Monitoring/wipe/auto-recycle roundtrip
- Playbook parameterization notes for second-product bring-ups

### Out of Scope (Deferred)
- Rollator algorithms (steps/distance/gait for wheeled motion) → DT-2
- `prj_rollator_field.conf` / `prj_rollator_pilot.conf` overlays, power work, FMEA → DT-3
- Rollator alert types, D2C claim flow for rollator, portal rendering → DT-4
- Runtime client-id-from-cert-CN (kills per-unit rebuilds; queued pre-scale — playbook:367-370)
- Walker capture.html changes (walker page untouched; fork keeps blast radius zero)
- session.c `device_serial "TH91X-0001"` / `sensor_model` header constants (pre-existing; joins happen on `session_uuid`)

## Architecture

### Product split — exact mechanism

**1. Kconfig choice** (root `Kconfig`, inside menu "GoSteady"; no choice blocks exist yet):
```kconfig
choice GOSTEADY_PRODUCT
    prompt "GoSteady product"
    default GOSTEADY_PRODUCT_WALKER_CAP

config GOSTEADY_PRODUCT_WALKER_CAP
    bool "Walker cap"
config GOSTEADY_PRODUCT_ROLLATOR
    bool "Rollator accessory platform"
endchoice
```
Default = walker → **every existing overlay/build is bit-for-bit unaffected**
except the intentional heartbeat `device_type` addition.

**2. version.h** (`src/version.h:181-187` today is a 1-D power-mode cascade):
becomes 2-D — product × power-mode. Walker branch keeps the exact current
strings (`0.17.0-time-{wakewindow|pilot|psm}`); rollator branch yields
`rol-0.1.0-{wakewindow|pilot|bench}`. Adds
`GS_PRODUCT_DEVICE_TYPE_STR` = `"walker_cap"` / `"rollator_platform"` —
single source of truth for the heartbeat field, matching the cloud enum
(DT-0 `_shared/device_types`).

**3. Heartbeat** (`src/cloud.c:761-892`, `build_heartbeat_payload`): one
`APPEND_OR_FAIL` line adjacent to the always-present `firmware` field
(cloud.c:834): `"device_type":"<GS_PRODUCT_DEVICE_TYPE_STR>"`. Emitted by
**both** products. Cloud side: lands in Shadow `reported` via D16 accept-all;
DT-0's heartbeat-processor cross-check compares it to the registry.

**4. Activity payload** (`src/cloud.c:1050-1141`, `build_activity_payload`):
- Required block (cloud.c:1053-1065, one snprintf) splits by product:
  walker keeps `serial/session_start/session_end/steps/distance_ft/active_min`;
  rollator emits `serial/session_start/session_end/active_min`.
- Optional walker-metric appends (`roughness_R` :1102, `gait_speed_fts` :1109,
  `surface_class` :1116) are compile-gated out for rollator — the sentinels are
  **data-driven** (NaN/0xFF set in session.c:703,714-717) and the walker algo
  *will* emit values on rolling motion, so omission must be compile-time.
- Time-reliability block (:1077-1091), `time_source` (:1095), and
  `firmware_version` (:1128) are Core — unchanged for both.
- `session.c` stays untouched: the pipeline keeps running (its motion gate
  produces `active_min` at session.c:708-713 AND drives Phase-3 auto-stop via
  `s_pipeline.gate.in_motion` → session.c:350-354 → main.c:1208), and its
  walker outputs still appear in uart0 `ALGO_V1A/B/C` logs — free bench
  diagnostics of what the walker algo thinks of wheeled motion.

**5. Prewalk constants** (`src/main.c:106-140`): `BENCH_PREWALK` /
`FIELD_PREWALK` stamp `walker_type/cap_type/mount_config` — product-keyed to
`GS_WALKER_ROLLATOR_4WHEEL` / `GS_CAP_FRAME_MOUNT` / `GS_MOUNT_ACCESSORY_PLATFORM`
under `CONFIG_GOSTEADY_PRODUCT_ROLLATOR`.

**6. `prj_rollator_cloud.conf`**: full copy of `prj_cloud.conf` (self-contained
— sysbuild forwards exactly one `EXTRA_CONF_FILE`; see prj_pilot.conf:3-5)
plus `CONFIG_GOSTEADY_PRODUCT_ROLLATOR=y`, client-id default
`"GS9999999981"` (the first rollator bench unit; per-unit override still via
`-DCONFIG_AWS_IOT_CLIENT_ID_STATIC`). Snippets stay ON (bench pipeline
validation, same as walker bench posture).

### Vocabulary appends (L6 — all copies in one commit)

| Table | Appended values (indices) |
|---|---|
| `gosteady_walker_type` (session.h:41-44) | `GS_WALKER_ROLLATOR_4WHEEL = 2` |
| `gosteady_cap_type` (session.h:46-49) | `GS_CAP_FRAME_MOUNT = 2` |
| `gosteady_mount_config` (session.h:91-97) | `GS_MOUNT_ACCESSORY_PLATFORM = 5` |
| `gosteady_run_type` (session.h:75-89) | `GS_RUN_BRAKE_STOP = 11`, `GS_RUN_BRAKE_DRAG = 12`, `GS_RUN_PARK_BRAKE_SEATED = 13`, `GS_RUN_HEAVY_LEAN = 14` |
| `control.c` string tables (:65-82) | same strings, same order |
| `read_session.py` lists (:86-103) | same strings, same order |
| Annotations workbook Vocabularies sheet | same strings |

Surfaces need **no** additions (`polished_concrete`, `low_pile_carpet`,
`outdoor_concrete`, `outdoor_asphalt` already exist); directions already
include `turn_left`/`turn_right`/`s_curve`/`pivot` (unused by walker v1 —
turns matter for wheeled motion and cost nothing).

### Rollator capture run-matrix (v1 — 39 runs, 3 surfaces × 13)

Per surface (polished concrete / outdoor concrete / low-pile carpet):
warmup 10 ft; 20 ft × {slow, normal, fast}; 20 ft normal repeat; 40 ft long
(30 ft carpet); s_curve 20 ft (15 ft carpet); turn_left 20 ft + turn_right
20 ft (90°); brake_stop 20 ft; heavy_lean 20 ft normal; stationary_baseline
0 ft 30 s; park_brake_seated 0 ft 30 s. Frame-loading variation is encoded
via `run_type` (`heavy_lean`) — no header reshape. `manual_step_count`
stays blank (no rollator ground-truth steps in v0); `events` free-text
gains `brake@mm:ss` / `sit@mm:ss` hints (unvalidated by design). Full
matrix + procedure: `GoSteady_Rollator_Capture_Protocol_v1.md` (fw repo).

### Bench-unit identity

| | Value |
|---|---|
| Serial / Thing / MQTT client id | `GS9999999981` |
| Thing Type | `GoSteadyRollatorPlatform-dev` (DT-0) |
| Registry | `deviceType=rollator_platform`, `hardwareVariant=thingy91x_bench` |
| Cert | sec_tag 201, minted per playbook Phase 1; bundle in the playbook location |
| Build | `build_rollator_gs81/` via `prj_rollator_cloud.conf` (client id baked) |
| Firmware | `rol-0.1.0-bench` |

## Implementation

### Files Changed / Created

| File | Change Type | Description |
|------|------------|-------------|
| fw `Kconfig` | Modified | `GOSTEADY_PRODUCT` choice (walker default) |
| fw `src/version.h` | Modified | 2-D product × power-mode version cascade (walker strings unchanged); `GS_PRODUCT_DEVICE_TYPE_STR` |
| fw `src/cloud.c` | Modified | Heartbeat `device_type` append (both products); activity required-block product split + compile-gated walker-metric appends |
| fw `src/session.h` | Modified | Enum appends (L6) |
| fw `src/control.c` | Modified | Vocab string-table appends (L6) |
| fw `src/main.c` | Modified | Product-keyed prewalk constants |
| fw `prj_rollator_cloud.conf` | New | Self-contained rollator bench+cloud overlay |
| fw `tools/read_session.py` | Modified | Vocab appends (L6) |
| fw `tools/control.py` | Modified | Rollator presets (`rollator-bench`, per-surface samples) |
| fw `tools/capture_rollator.html` | New | Fork: rollator COMMON + 36-run RUNS + brake/sit event hints |
| fw `data collection and protocols/GoSteady_Rollator_Capture_Protocol_v1.md` | New | 36-run protocol (markdown, not docx) |
| fw `data collection and protocols/GoSteady_Rollator_Annotations_v1.xlsx` | New | Same 34-column schema; Vocabularies extended |
| fw `GOSTEADY_CONTEXT.md` | Modified | Product split + GS9999999981 dev-unit row + version lineage |
| portal `docs/playbooks/new-dev-unit-bringup.md` | Modified | Product parameterization (Thing Type + overlay) notes |
| portal `docs/specs/ARCHITECTURE.md` §17 | Modified | DT-1 spec index row |
| portal coord doc | Modified (append) | §C49 — product split landed + GS9999999981 bring-up state |

### Dependencies
- DT-0 deployed (✅ 2026-07-01) — Thing Type, registry `deviceType`, per-type ingest
- NCS v3.2.4 toolchain (validated: pristine walker cloud build green 2026-07-01)
- Physical: board power (A1), J-Link 802006700 (present), SW2 = nRF91 (per user)

### Configuration
- `CONFIG_GOSTEADY_PRODUCT_ROLLATOR=y` only in `prj_rollator*.conf`
- Client id: `-DCONFIG_AWS_IOT_CLIENT_ID_STATIC='"GS9999999981"'` baked default in the rollator overlay

## Testing

### Test Scenarios

| # | Scenario | Method | Expected Result | Status |
|---|----------|--------|-----------------|--------|
| B1 | Walker regression build | pristine `prj_pilot.conf` (the shipped config — plain `prj_cloud.conf` is **pre-broken at 0.17.0**, RAM −1296 B, see D10) | Compiles; version strings unchanged; only intended delta = heartbeat `device_type:"walker_cap"` | ✅ Pass 2026-07-01 — ELF carries `0.17.0-time-wakewindow` + `walker_cap` + full walker activity format; review confirmed walker payload byte-identical |
| B2 | Rollator build | `west build … prj_rollator_cloud.conf` pristine, client id GS9999999981 | Compiles; version `rol-0.1.0-bench`; RAM/flash within budget | ✅ Pass — app RAM 62.6% (142,624/227,992 B), flash 26.1%; ELF carries all three identity strings + `active_min`-only format |
| B3 | Host algo regression | `tests/host` suite | All checks pass (algo untouched) | ✅ Pass — 64/64 |
| B4 | `read_session.py` walker .dat back-compat | Parse a real 2026-05-05 walker capture + prefix assertion | Validates clean (appends didn't shift indices) | ✅ Pass |
| P1 | Boot + console | uart0 @115200 | Clean boot, `rol-0.1.0-bench`, LTE attach | ✅ Boot/sensors/watchdog/LittleFS-format/pre-activation all clean; **9.5 h overnight soak: boot 1, faults 0, wdt 0**. LTE attach blocked by P-SIM below |
| P2 | First heartbeat | Cloud Shadow + registry | `device_type:"rollator_platform"` in Shadow reported; no mismatch alarm; `lastSeen` mirrors | ⏸ **Blocked P-SIM** (never registered) |
| P3 | Provision → activate | API provision to test patient (`pat_dt1_rollator_bench_1782968418`); coordinator re-publishes cmd on first connect | `activated_at` set; `last_cmd_id` echo; status `active_monitoring` | 🟡 Provision half ✅ (200; assignment snapshots `rollator_platform`; cmd `act_7bcdb1ca…` queued, 24 h window from 2026-07-02T05:00Z). Activation ack ⏸ Blocked P-SIM |
| P4 | uart1 session → activity row | `control.py start-preset rollator-bench` | Activity row: `deviceType=rollator_platform`, no steps/distanceFt | 🟡 Device half ✅ — rollator vocab ACCEPTED, session `e7f1be80…` recorded 1506 samples, **motion-gate auto-stop fired at 15 s stillness** (desk-bound board — correct), header stamped `rol-0.1.0-bench`, activity enqueued with `session_end=""` + uptimes (§C47 unsynced-clock path exercised). Cloud row ⏸ Blocked P-SIM |
| P5 | Wipe roundtrip | End Monitoring via API/portal | wipe → ack → `ready_to_provision` | ⏸ Blocked P-SIM (user smoke item) |
| P6 | Capture tooling end-to-end | START → auto-stop → `pull_sessions.py` → `ingest_capture.py` | .dat pulls; rollator enums decode; CSV matches schema | 🟡 START/record/ALGO-logs ✅; pull ⏸ blocked on USB re-plug (port vanished 08:23 — board on battery, J-Link still reads target). ⚠ pull BEFORE any reboot (boot orphan sweep deletes .dat) |
| P7 | ALGO_V1B motion-gate sanity | Rolling motion vs wall clock | `motion_s` plausible | 🟡 Stationary case validated (motion_s=0.00 on a still desk — no false motion). Rolling case = user smoke item |
| **P-SIM** | **LTE registration** | Overnight observation | Registered on LTE-M | ❌ **EMM cause 8 rejection all night, multiple cells/TACs** — unactivated iBasis trial eSIM (A2 realized). Operator step: claim the SIM (ICCID) on nRF Cloud, then power-cycle. Not a firmware/cloud defect — modem search/reject/backoff cycled cleanly for 9.5 h |

### Verification Commands
```bash
# Builds (from ~/Documents/gosteady-firmware, toolchain env exported)
west build -b thingy91x/nrf9151/ns -d build_cloud -p always -- -DEXTRA_CONF_FILE=prj_cloud.conf
west build -b thingy91x/nrf9151/ns -d build_rollator_gs81 -p always -- \
  -DEXTRA_CONF_FILE=prj_rollator_cloud.conf -DCONFIG_AWS_IOT_CLIENT_ID_STATIC='"GS9999999981"'
# Host tests
cd tests/host && make -s run   # (or the suite's documented invocation)
# Cloud checks after first heartbeat
aws iot-data get-thing-shadow --thing-name GS9999999981 --region us-east-1 /dev/stdout | python3 -m json.tool | grep -E "device_type|firmware"
aws dynamodb get-item --table-name gosteady-dev-devices --region us-east-1 \
  --key '{"serialNumber":{"S":"GS9999999981"}}' --query "Item.{s:status.S,t:deviceType.S,ls:lastSeen.S}"
```

## Deployment

### Resume runbook — state as of 2026-07-02 08:30 local

**Already done by the implementation session:** at_client + cert (sec_tag 201,
verified) + `rol-0.1.0-bench` flashed; boot/soak clean (9.5 h, 0 faults);
device provisioned to `pat_dt1_rollator_bench_1782968418` with activate cmd
`act_7bcdb1ca…` queued; a bench session recorded on-device awaiting pull.
**Two physical blockers remain**, both operator-only:

1. **Re-plug USB** (board is on battery; CDC ports vanished 08:23).
   Then FIRST pull the recorded session — before any reboot/reflash (the
   boot orphan sweep deletes all `.dat`):
   `python3 tools/pull_sessions.py --port /dev/cu.usbmodem*1105 --out raw_sessions/<date>/`
   then `read_session.py` on it (expect `rollator_4wheel`/`frame_mount`/
   `accessory_platform` decode + `rol-0.1.0-bench`).
2. **Activate the iBasis eSIM** — overnight registration was rejected with
   **EMM cause 8** on every attempt (unactivated trial SIM). Claim it on
   nRF Cloud (nrfcloud.com → SIM claim) using the ICCID:
   - Easiest: the ICCID is printed on the Thingy:91 X **box label**.
   - Otherwise: reflash at_client (`nrfjprog -f NRF91 --program
     /tmp/at_client.hex --chiperase --verify --reset --snr 802006700`),
     `screen /dev/cu.usbmodem*1102 115200`, send `AT%XICCID`; then reflash
     `build_rollator_gs81/merged.hex` (cert survives chiperase; pull the
     session before this per step 1!).
   After claiming: power-cycle the board; watch uart0 for
   `nw_reg_status=registered` + `psm:` grant + first heartbeat.

**Then the user smoke (P2–P7 completion, ~15 min):**
3. First heartbeat → check Shadow `device_type:"rollator_platform"` +
   registry `lastSeen`; the §C24 coordinator delivers the queued activate on
   that connect → `active_monitoring`. ⚠ If the SIM claim happens after
   2026-07-03T05:00Z, the 24 h ack window has lapsed — end-assignment +
   force-reset + re-provision first (or just re-provision if the coordinator
   swept the cmd).
4. Roll the board around on a rollator/cart for 1–2 min → session auto-starts
   on motion → auto-stops at stillness → activity row lands with
   `deviceType=rollator_platform`, `activeMinutes ≥ 1`, no steps/distance
   (check portal or `gosteady-dev-activity` by patient). P7: compare
   ALGO_V1B `motion_s` on uart0 vs wall clock.
5. End Monitoring (portal/API) → wipe → auto-recycle to `ready_to_provision`
   (P5) — the full Core-Contract roundtrip on rollator firmware.
6. Data collection is then live: `tools/capture_rollator.html` (39-run
   matrix) + `GoSteady_Rollator_Capture_Protocol_v1.md`.

**Known non-issues:** daily 09:00 `no_activity_today` CRITICAL alerts may
fire for the bench patient once assigned+active — that's the steps-keyed
behavioral rule (DT-4 re-key, memo Q8), not a firmware fault; the bench
patient is synthetic in `client_rd_test` so the alerts are inert DDB rows.
The overnight desk session's queued activity uplink lives in RAM only — a
power cycle drops it (fine; it recorded 0 motion).

### Rollback Plan
- Firmware: walker builds unaffected (Kconfig default); revert = git revert on fw `main`, reflash
- Cloud: GS9999999981 record/Thing/cert are additive; delete via playbook decommission section if abandoned

## Decisions Log

| # | Decision | Alternatives Considered | Why This Choice |
|---|----------|------------------------|-----------------|
| D1 | Gate the activity metric set in `build_activity_payload` (cloud.c), NOT in session.c | Sentinel-poisoning in session.c population block | Contract lives at the wire boundary in one function; session.c untouched keeps ALGO_V1* uart0 logs as free bench diagnostics; optional-field sentinels are data-driven so only compile-gating guarantees omission |
| D2 | Keep `gs_pipeline` compiled + fed for rollator | Compile it out / shrink buffers | Motion gate is load-bearing (active_min + Phase-3 auto-stop per session.c:350-354 → main.c:1208); ~62 KB .bss reclaim deferred to DT-3 power work via `GS_PIPELINE_MAX_BUFFERED_SAMPLES` |
| D3 | `device_type` in heartbeat for both products now | Rollator-only | Walker units get wrong-flash detection for free; registry already backfilled (DT-0) so no false mismatches |
| D4 | Only `prj_rollator_cloud.conf` in DT-1 | Also field/pilot overlays now | Mirror-discipline burden is real (3 self-contained copies today); field/pilot land with DT-3 when their content is decided |
| D5 | Fork `capture_rollator.html` rather than parameterize capture.html | Product toggle in one page | Walker page is a validated artifact mid-pause (19/30 runs); zero blast radius beats DRY for an operator tool; noted as tech debt for a future rewrite |
| D6 | Rollator protocol doc in Markdown (not docx) | Mirror the docx format | Versionable/diffable in-repo; the annotation workbook stays xlsx because ingest tooling + operator workflow expect it |
| D7 | `hardwareVariant=thingy91x_bench` for GS9999999981 | `cupholder_v1` | Honest: it's a bare dev board on a bench, not cupholder hardware; the variant field is for real accessory SKUs |
| D8 | Rollator overlay defaults client id to `GS9999999981` | Shared `GS9999999999` placeholder | Mirrors walker convention (overlay default = that product's bench unit); avoids accidentally publishing as the walker bench identity |
| D9 | **Snippets OFF in `prj_rollator_cloud.conf`** | Keep ON (prj_cloud parity) | Two load-bearing reasons: (a) plain prj_cloud no longer links at 0.17.0 (D10) — snippets-off frees the RAM; (b) the bench unit's iBasis SIM is 10 MB *lifetime* and snippets dominate ~300× heartbeats. DT-2 capture uses full `.dat` sessions over uart1 — strictly more data than the 30 s snippet side-channel |
| D10 | **(Found during B1)** Plain `prj_cloud.conf` is pre-broken at 0.17.0: RAM overflows by 1296 B at link, on unmodified `main` — every recent unit shipped pilot/wakewindow configs (snippets off), so nobody had built it since the 0.16/0.17 growth. Documented in GOSTEADY_CONTEXT.md build table + coord §C49; fix deferred (walker-side, needs its own validation) | Fix it now | Can't bench-validate a walker RAM trim in this session (GS98 is the walker bench unit, untouched); identical 1296 B overflow pre/post-diff also proves the product split adds zero RAM |
| D11 | Bench validation used the formal provision→activate flow (DT-0 device-api), NOT the playbook §1.4 `activated_at` shortcut | Dev shortcut | The device-api exists now (the shortcut predates it); the queued-cmd + §C24 coordinator delivery on first connect is exactly the production path the user's smoke should exercise |

## Open Questions
- [ ] A2 (SIM): confirm the fresh board's iBasis eSIM attaches without operator web activation
- [ ] A3 (motion gate on wheels): quantify at bench (P7), then properly in DT-2 capture data
- [ ] Physical mount for capture sessions: how the bare Thingy:91 X attaches to an actual rollator frame for DT-2 collection (tape/bracket/3D-print) — operator decision before first real capture

## Changelog
| Date | Author | Change |
|------|--------|--------|
| 2026-07-01 | implementation session | Initial spec (from 6-agent firmware map) + implementation same session; physical flash gated on board power (A1) |

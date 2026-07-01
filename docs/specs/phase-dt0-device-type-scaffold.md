# Phase DT-0 — Device-Type Scaffold (cloud)

## Overview
- **Phase**: DT-0 (first phase of the multi-device-type plan — [`2026-07-01-device-types.md`](2026-07-01-device-types.md))
- **Status**: Planned (spec drafted 2026-07-01)
- **Branch**: feature/infra-scaffold
- **Date Started**: —
- **Date Completed**: —

Makes `deviceType` a first-class concept across the cloud so the rollator
accessory platform (and any future device type) can ride the existing
platform layer without forks. Adds the attribute to Device Registry /
DeviceAssignments / telemetry rows, creates the second IoT Thing Type,
refactors activity/alert validation into a per-type dispatch registry, keys
threshold defaults by type, and adds the heartbeat `device_type` cross-check.
**Everything is backward-compatible**: absent `deviceType` reads as
`walker_cap` everywhere (memo D9), no telemetry backfill, no destructive
migrations, walker-cap behavior byte-identical after deploy.

## Locked-In Requirements

| # | Requirement | Decided In | Rationale |
|---|-------------|-----------|-----------|
| L1 | `deviceType` is registry-authoritative; snapshotted onto the DeviceAssignment row at provision; denormalized onto every telemetry row | Memo D1 | Zero extra reads at ingest (patient resolution already fetches the assignment row) |
| L2 | Absent `deviceType` reads as `walker_cap`; registry records backfilled via CLI; telemetry rows NOT backfilled | Memo D9 | Single-type fleet today — absence is unambiguous |
| L3 | Enum values: `walker_cap`, `rollator_platform`; accessory SKU in optional `hardwareVariant` (e.g. `cupholder_v1`) | Memo Q1 | Type = board + firmware + output contract; accessory is packaging |
| L4 | Shared topics `gs/{serial}/{class}`; no per-type topics or IoT Rules | Memo D3 | Handlers dispatch on type after resolution |
| L5 | Per-type validation via `_shared/device_types/` dispatch; one handler, N schema modules | Memo D6 | No per-type Lambda forks |
| L6 | Rollator bench v0 activity contract: `active_min` required, everything else optional (parity set lands at DT-2 exit) | Memo D10 | Never block a bench uplink on unproven metrics |
| L7 | One IoT Thing Type per device type: `GoSteadyRollatorPlatform-{env}` alongside `GoSteadyWalkerCap-{env}`; fleet-provisioning template stays cap-pinned until Phase 5A | Memo D7 | Thing type = OTA/fleet cohort; bench things are created manually per playbook |
| L8 | Firmware self-reports `device_type` in heartbeat; cloud cross-checks vs registry; mismatch → log + metric + alarm, **never reject** | Memo Q7 | Catches wrong-firmware-flashed at first heartbeat; registry wins |
| L9 | Rollator serial blocks: dev `GS9999999980–89`, production `GS0001000000–GS0001999999` | Memo Q6 | Human/ops convenience only; registry stays authoritative |
| L10 | D16 accept-all is Core Contract: per-type validation never rejects unknown *extra* fields | Memo DT-I5 | Rollator provisional metrics flow through `extras` during the algo arc |

## Assumptions

| # | Assumption | Risk if Wrong | Validation Plan |
|---|-----------|---------------|-----------------|
| A1 | Rollator firmware can compute `active_min` from the motion gate in its first bench build | v0 uplinks reject on the one required metric | Motion gate is shared platform code already proven on the cap; confirm in DT-1 bench bring-up |
| A2 | No rollator device is provisioned before DT-0 deploys | Legacy-default (`walker_cap`) would mislabel a rollator assignment | Process gate: DT-1 bring-up requires DT-0 deployed (memo phasing) |
| A3 | `activity_reject` triage by type works with EMF *metadata* (not a new dimension) | Would need a second dimension set; risks breaking the existing 1.6 alarm on `activity_reject_count` | Keep metric shape identical; add `deviceType` via `metrics.add_metadata` only |
| A4 | `patient-api` returns activity rows as stored (so `deviceType` flows to clients without projection changes) | D2C dashboard can't key rendering per type in DT-4 | Verify response shape at impl; add to projection if filtered |

## Scope

### In Scope
- `deviceType` (+ optional `hardwareVariant`) on Device Registry records; CLI backfill of the existing fleet's records to `walker_cap`
- `deviceType` snapshot onto DeviceAssignments rows in **all three** provision writers (device-api `_action_provision`, patient-mgmt `_provision_inline`, d2c-claim `_provision_inline`)
- `deviceType` denormalized onto every new Activity Series + Alert History row
- `_shared/device_types/` dispatch package (`walker_cap.py`, `rollator_platform.py`) replacing the module-level `REQUIRED_FIELDS` / `VALID_ALERT_TYPES` constants
- `PatientContext.deviceType` (sourced from the assignment row; default `walker_cap`)
- Threshold defaults keyed by type (`_shared/thresholds.py`), rollator inheriting walker values (memo Q3)
- Heartbeat `device_type` cross-check + `device_type_mismatch_count` metric + Observability alarm
- Second IoT Thing Type (`GoSteadyRollatorPlatform-{env}`)
- Admin bulk-create accepts `deviceType`/`hardwareVariant`; `GET /devices/{serial}` returns them; `device.created` audit carries them
- Activity auto-resume re-keyed on `activeMinutes` (universal metric) instead of `steps`
- Audit catalog: `device.type_changed` constant (mechanism is CLI-runbook in dev — see D3 below)
- Docs lockstep: ARCHITECTURE §6/§7/§14/§17 + coord-doc entry (Core Device Contract v1 announcement, serial blocks, heartbeat `device_type` field)

### Out of Scope (Deferred)
- Rollator firmware, capture rig, algo work → DT-1/DT-2
- Behavioral-detector `activeMinutes` re-key → DT-4 launch gate (memo Q8)
- Portal rendering (D2C dashboard widget registry, facility census) → DT-4 / facility demand
- Per-type battery/OCV/wipe-floor **values** → DT-3 (only the keying mechanism ships now)
- `PATCH /admin/devices/{serial}` re-type endpoint → first-need (CLI runbook covers dev; see D3)
- `_shared/provision.py` extraction (three-copy provision chain consolidation) → standing follow-up, explicitly not bundled here (blast radius)
- Fleet-provisioning-template parametrization → Phase 5A
- 1C-rollup per-type definitions → with 1C-rollup (memo Q15)

## Architecture

### Infrastructure Changes
- **Ingestion stack** (`GoSteady-{Env}-Ingestion`): new `iot.CfnThingType` logical ID `RollatorPlatformType`, name `GoSteadyRollatorPlatform-${prefix}`, description "GoSteady rollator accessory-platform device". Nothing else — topics, rules, policy template untouched (L4).
- **Observability stack** (`GoSteady-{Env}-Observability`): 1 new alarm `gosteady-{env}-heartbeat-processor-device-type-mismatch` on EMF metric `device_type_mismatch_count > 0` in 5 min (`GoSteady/Processing/{env}`, dimensioned by `service` — same pattern as the `activity-reject` alarm in [`handler-alarms.ts`](../../infra/lib/constructs/alarms/handler-alarms.ts)). Catalog 30 → 31.
- **Processing / Api stacks**: Lambda code-asset swaps only (no resource changes).
- **No DDB schema changes** — `deviceType`/`hardwareVariant` are schemaless attributes; no new GSIs (no by-type query need at this scale; the registry scan for inventory-by-type is fine for a ≤dozens fleet).

### Data Flow (deviceType propagation)
```
device.created (bulk-create / CLI)        provision (any of 3 writers)
  Device Registry.deviceType  ───────────►  DeviceAssignments.deviceType (snapshot, frozen)
                                                     │
                              resolve_patient(serial)│ (existing read — no new I/O)
                                                     ▼
                                        PatientContext.deviceType
                                          │            │            │
                                          ▼            ▼            ▼
                                   activity row   alert row   threshold defaults
                                   (deviceType)  (deviceType)  keyed by type
heartbeat.device_type (firmware self-report) ──► cross-check vs Registry ──► mismatch metric/alarm
```

### Interfaces

**`_shared/device_types/` module contract** (each type module exports):

```python
TYPE: str                                    # "walker_cap" | "rollator_platform"
REQUIRED_ACTIVITY_METRICS: tuple[str, ...]   # walker: (steps, distance_ft, active_min); rollator v0: (active_min,)
def validate_activity_metrics(event) -> tuple[bool, str]   # presence + range checks (moved from activity-processor _validate)
def build_metric_attrs(event) -> dict        # DDB-ready named-column promotion (walker: steps/distanceFt/activeMinutes
                                             #   + optional roughnessR/surfaceClass/gaitSpeedFts; rollator v0: activeMinutes only)
ACTIVITY_NAMED_FIELDS: frozenset[str]        # per-type additions to the shared NAMED_FIELDS (extras exclusion list)
VALID_ALERT_TYPES: frozenset[str]            # walker: {tipover, fall, impact}; rollator v0: frozenset() (memo Q11)
```

Package root: `resolve(device_type: str | None) -> module` — returns the type
module, defaulting to `walker_cap` for `None`/unknown (unknown also logs a
warning + metric; it means a registry record was created with a typo'd type,
which bulk-create validation should have prevented).

**Payload contracts**: unchanged on the wire for walker_cap. Rollator activity
v0 = universal envelope (`serial`, session identity + §C47 time fields) +
`active_min`. Heartbeat gains optional `device_type` (string) — already
tolerated by accept-all D16; lands in Shadow `reported` as today.

**API deltas** (`device-api`):
- `POST /api/v1/admin/devices` body accepts optional `deviceType` (default `walker_cap`; 400 `INVALID_DEVICE_TYPE` if not in registry keys) + optional `hardwareVariant` (free string ≤64)
- `GET /api/v1/devices/{serial}` response includes `deviceType` + `hardwareVariant` (defaulted `walker_cap`/absent for legacy records)

## Implementation

### Files Changed / Created

| File | Change Type | Description |
|------|------------|-------------|
| `infra/lambda/_shared/device_types/__init__.py` | New | Registry + `resolve()` + `DEFAULT_TYPE = "walker_cap"` |
| `infra/lambda/_shared/device_types/walker_cap.py` | New | Walker schema — `_validate` logic + named-column promotion moved here verbatim (incl. gait/surface optional-field handling) |
| `infra/lambda/_shared/device_types/rollator_platform.py` | New | Rollator v0 schema — `active_min` required; empty alert enum |
| `infra/lambda/_shared/patient_resolution.py` | Modified | `PatientContext.deviceType: str = "walker_cap"`, sourced from assignment row |
| `infra/lambda/_shared/thresholds.py` | Modified | `DEFAULTS_BY_TYPE`; `merge_thresholds(overrides, device_type=...)`; walker + rollator entries identical values (Q3) |
| `infra/lambda/_shared/audit_catalog.py` | Modified | `DEVICE_TYPE_CHANGED = "device.type_changed"` |
| `infra/lambda/_shared/tests/test_device_types.py` | New | Unit tests: dispatch, per-type validation, promotion, unknown-type fallback |
| `infra/lambda/activity-processor/handler.py` | Modified | Validation split: envelope up front, per-type metrics **after** `resolve_patient` (type must be known first — ordering change, see D2); `deviceType` on row; `add_metadata("deviceType", …)` on rejects; auto-resume re-keyed on `activeMinutes` (see D4) |
| `infra/lambda/alert-handler/handler.py` | Modified | `VALID_ALERT_TYPES` → per-type module (also moves after patient resolution); `deviceType` on row |
| `infra/lambda/threshold-detector/handler.py` | Modified | Pass `ctx.deviceType` into `merge_thresholds` |
| `infra/lambda/heartbeat-processor/handler.py` | Modified | `_check_device_type(serial, event)`: only when `device_type` present; registry GetItem with `ProjectionExpression="deviceType"`; mismatch → warn log + `device_type_mismatch_count` metric. Never rejects |
| `infra/lambda/device-api/handler.py` | Modified | bulk-create validation + write of `deviceType`/`hardwareVariant`; provision copies `deviceType` from the already-fetched registry item onto the assignment row; GET response fields; `device.created` audit payload |
| `infra/lambda/patient-mgmt/handler.py` | Modified | `_provision_inline`: same one-line assignment-row snapshot |
| `infra/lambda/d2c-claim/handler.py` | Modified | `_provision_inline`: same one-line assignment-row snapshot |
| `infra/lib/stacks/ingestion-stack.ts` | Modified | Second `CfnThingType` (`RollatorPlatformType`) |
| `infra/lib/constructs/alarms/handler-alarms.ts` | Modified | `device-type-mismatch` alarm |
| `docs/specs/ARCHITECTURE.md` | Modified | §6 table attrs (Registry `deviceType`/`hardwareVariant`; Assignments + Activity + Alerts `deviceType`); §7 restructured → §7.0 Core Device Contract v1 + §7.1 walker_cap + §7.2 rollator_platform stub; §14 new DT requirement rows; §17 index |
| `docs/firmware-coordination/2026-04-17-cloud-contracts.md` | Modified (append) | New `[rollator]` entry: Core Device Contract v1 announcement, serial-block allocation, heartbeat `device_type` field, bench-v0 activity contract |

### Dependencies
- No prior undeployed phases — everything DT-0 touches is live in dev
- No new packages (stdlib + existing Powertools layer)

### Configuration
- No new env vars required. `AUTO_RESUME_MIN_STEPS` is **removed** (see D4) and replaced by `AUTO_RESUME_MIN_ACTIVE_MIN` (default `0` — identical "any activity clears the pause" semantics)

## Testing

### Test Scenarios

| # | Scenario | Method | Expected Result | Status |
|---|----------|--------|-----------------|--------|
| T1 | Walker activity regression (payload from legacy assignment with no `deviceType`) | Synthetic MQTT publish | Row identical to today **plus** `deviceType: walker_cap`; audit unchanged | Pending |
| T2 | Rollator activity happy path (`active_min` only, provisional fields) | Synthetic publish from `GS9999999980` | Accepted; row has `deviceType: rollator_platform`, `activeMinutes`, **no** `steps`/`distanceFt` attrs; provisional fields in `extras` | Pending |
| T3 | Rollator activity missing `active_min` | Synthetic publish | `activity_reject` with `reason=missing:active_min`, metadata `deviceType=rollator_platform` | Pending |
| T4 | Walker activity missing `steps` | Synthetic publish | Still rejects (per-type required set enforced; no regression to lax) | Pending |
| T5 | Rollator device alert (`tipover`) | Synthetic publish on `gs/+/alert` | Rejected `bad_alert_type` (empty rollator enum) | Pending |
| T6 | Heartbeat `device_type` mismatch (walker registry record, `device_type: rollator_platform` in payload) | Synthetic publish | Shadow still updated; warn log + `device_type_mismatch_count=1`; alarm fires in dev | Pending |
| T7 | Heartbeat `device_type` match / absent | Synthetic publish | No metric; no behavior change | Pending |
| T8 | Bulk-create with `deviceType: rollator_platform` + `hardwareVariant: cupholder_v1`; and with an invalid type | API call | 200 + record + audit carries both; invalid → 400 `INVALID_DEVICE_TYPE` | Pending |
| T9 | Provision rollator registry record to test patient | API call | Assignment row carries `deviceType: rollator_platform`; `activate` cmd published (Core Contract untouched) | Pending |
| T10 | D2C synthetic claim regression | Existing d2c e2e script | Claim succeeds; assignment row carries `deviceType: walker_cap` | Pending |
| T11 | `merge_thresholds` unit: per-type defaults + patient-override merge, unknown type fallback | pytest | Walker/rollator identical values; overrides still win; unknown → walker defaults + warning | Pending |
| T12 | Auto-resume fires on rollator activity (`activeMinutes > 0`, patient paused) | Synthetic publish | `notificationsPaused` removed + `patient.notifications.resume_auto` audit | Pending |
| T13 | Registry CLI backfill idempotency | CLI | `attribute_not_exists(deviceType)` condition — second run is a no-op | Pending |
| T14 | Physical-cap smoke (`GS0000000001` heartbeat + walk) | Live device | End-to-end unchanged; new row carries `deviceType: walker_cap` | Pending |

### Verification Commands
```bash
# Per-type validation unit tests
cd infra/lambda && python -m pytest _shared/tests/test_device_types.py -q

# Rollator synthetic activity (after seeding GS9999999980 + provisioning)
aws iot-data publish --region us-east-1 --topic 'gs/GS9999999980/activity' \
  --cli-binary-format raw-in-base64-out \
  --payload '{"serial":"GS9999999980","active_min":4,"clock_synced":true,
              "session_start":"2026-07-01T17:00:00Z","session_end":"2026-07-01T17:04:00Z"}'

# Confirm row + type
aws dynamodb query --table-name gosteady-dev-activity --region us-east-1 \
  --key-condition-expression 'patientId = :p' \
  --expression-attribute-values '{":p":{"S":"<test-patient-id>"}}' \
  --query 'Items[0].{type:deviceType,active:activeMinutes,steps:steps}'

# Thing type exists
aws iot describe-thing-type --thing-type-name GoSteadyRollatorPlatform-dev --region us-east-1
```

## Deployment

### Deploy Commands
```bash
cd infra && npm run build
npx cdk diff  GoSteady-Dev-Ingestion GoSteady-Dev-Processing GoSteady-Dev-Api GoSteady-Dev-Observability --context env=dev
npx cdk deploy GoSteady-Dev-Ingestion GoSteady-Dev-Processing GoSteady-Dev-Api GoSteady-Dev-Observability \
  --context env=dev --require-approval never

# One-time registry backfill (idempotent; run per existing serial:
# GS9999999999, GS9999999998, GS0000000001, + any synthetic fixtures)
for s in GS9999999999 GS9999999998 GS0000000001; do
  aws dynamodb update-item --region us-east-1 --table-name gosteady-dev-devices \
    --key "{\"serialNumber\":{\"S\":\"$s\"}}" \
    --update-expression 'SET deviceType = :t' \
    --condition-expression 'attribute_not_exists(deviceType)' \
    --expression-attribute-values '{":t":{"S":"walker_cap"}}' || true
done
```
Expected diff shape: all `[~]` in-place Lambda code updates + 2 `[+]`
additive resources (ThingType, alarm). Any `[-]` is a red flag (§18.7).

### Rollback Plan
- All changes additive or code-only: `git revert` + redeploy the same four stacks
- Orphaned `deviceType` attributes on rows/records are harmless to reverted code (unknown attrs were already tolerated everywhere)
- The new ThingType and alarm can stay (inert) or be removed by the revert deploy

## Decisions Log

| # | Decision | Alternatives Considered | Why This Choice |
|---|----------|------------------------|-----------------|
| D1 | `PatientContext.deviceType` sourced from assignment row with `walker_cap` default; **no registry fallback read** at ingest | Registry GetItem fallback for legacy assignments | Every pre-DT-0 assignment IS a walker cap by construction (A2); the fallback read would cost a GetItem per uplink to resolve a constant |
| D2 | Per-type metric validation moves **after** `resolve_patient` (envelope check stays first) | Type from a payload field (validate first) | Registry is authoritative (memo D1/Q7); trusting payload type for validation would let mis-flashed firmware pick its own contract. Ordering cost: garbage-metric payloads from unmapped serials now short-circuit at `unmapped_serial` instead of `activity_reject` — acceptable, both are visible warn+metric paths |
| D3 | Q4 re-type mechanism in dev = CLI runbook step (update-item + thing-type re-association note in coord doc); admin API endpoint deferred to first-need | `PATCH /admin/devices/{serial}` now | Fleet is ≤4 records; endpoint + authz + audit wiring isn't worth it until re-typing is routine. Accepted gap: CLI path emits no app-audit event in dev (CloudTrail still records the DDB write) |
| D4 | Auto-resume re-keyed on `activeMinutes` (env `AUTO_RESUME_MIN_ACTIVE_MIN`, default 0); `AUTO_RESUME_MIN_STEPS` removed | Keep steps-keyed with rollator special-case | `steps` is absent from rollator rows **only during the DT-1→DT-2 bench window** (the step/distance/gait algorithms arrive with the DT-2 arc; parity — steps + distance + gait — is required by launch per D10). But today's handler references `item["steps"]` unconditionally (auto-resume, audit block, log, response) → KeyError on a bench rollator row, so the type-safe build path is mechanically required; and `activeMinutes` is the declared universal metric (memo Q8/Q15) with identical default-0 semantics ("any persisted activity clears the pause"). The old env var was never set anywhere |
| D5 | `activity_reject` type triage via EMF **metadata**, not a new dimension | `deviceType` dimension | A new dimension set would fork the metric identity and silently detach the existing 1.6 `activity-reject` alarm (A3) |
| D6 | No `by-device-type` GSI | GSI on Registry | No query need at ≤dozens fleet; scan/filter suffices for inventory-by-type; add GSI on first real access pattern |

## Open Questions
- [ ] Exact registry-record seed set for the backfill loop (confirm whether synthetic fixtures beyond the three physical units carry Device Registry rows in dev)
- [ ] A4 verification: does `patient-api` project activity fields or return rows as stored? (determines a one-line projection addition)

## Changelog
| Date | Author | Change |
|------|--------|--------|
| 2026-07-01 | scoping session (Jace + Claude) | Initial spec, drafted from memo [`2026-07-01-device-types.md`](2026-07-01-device-types.md) D1–D11 |

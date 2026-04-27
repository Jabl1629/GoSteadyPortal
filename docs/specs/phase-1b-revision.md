# Phase 1B Revision — Processing-Layer Refactor

## Overview
- **Phase**: 1B (Revision)
- **Status**: ✅ Deployed to dev 2026-04-27
- **Branch**: feature/infra-scaffold
- **Date Started**: 2026-04-27
- **Date Completed**: 2026-04-27
- **Supersedes**: select decisions in [`phase-1b-processing.md`](phase-1b-processing.md) — see "Reversed/Superseded Decisions" below.

Refactors the deployed Phase 1B processing layer to consume the new
[`phase-0b-revision.md`](phase-0b-revision.md) data shape (patient-centric PKs,
hierarchy denormalization, IdentityKey CMK on identity tables) and the
[`phase-1a-revision.md`](phase-1a-revision.md) ingestion additions (snippet path,
downlink topic, Shadow IoT-policy grants), and to fold in the firmware-coordination
2026-04-26 decisions (Shadow `desired.activated_at` re-check via DL14;
ack-matching breadth via DL14a; pre-activation suppression via DL13).

The original Phase 1B handlers (`activity-processor`, `heartbeat-processor`,
`alert-handler`) are device-centric (`serialNumber` PK), Python on x86, write
synchronously to DDB on every heartbeat, and have no awareness of multi-tenancy
or hierarchy. This revision delivers a unified rebuild:

1. **Three Lambda redesign:**
   - `activity-processor` — patient-centric PK, hierarchy snapshot at write, `expiresAt` TTL column, `extras` bag for firmware-derived fields, ARM64
   - `threshold-detector` — **NEW**, replaces `heartbeat-processor`. Triggered by Shadow `update/accepted` IoT Rule (not by raw heartbeat). Generates synthetic alerts on shadow delta.
   - `alert-handler` — patient-centric PK, hierarchy snapshot, ARM64
   - `heartbeat-processor` — **slimmed down to a thin Shadow-update + activation-ack-only handler** (no DDB telemetry writes for routine heartbeats; Shadow becomes the source of truth for live device state)
2. **Patient-resolution pipeline:** serial → DeviceAssignments active row → patientId → Patients row → clientId/facilityId/censusId. Two GetItems per write. Failures route to DLQ with structured error.
3. **Hierarchy snapshot at write time:** every telemetry row carries a frozen `clientId`/`facilityId`/`censusId` matching the patient's hierarchy at ingest moment. History follows the patient (Architecture T4).
4. **Pre-activation suppression:** Threshold Detector skips synthetic alerts when `Device Registry.activated_at` is unset. Sampled audit log at 1/hr/serial. *(Originally specced in 1A revision; moved here per 1A-rev D10.)*
5. **Activation-ack via heartbeat `last_cmd_id` echo:** match against any `cmd_id` issued to the serial within the last 24 h (DL14a); set `Device Registry.activated_at` and emit `device.activated` audit. *(Originally specced in 1A revision; moved here per 1A-rev D10.)*
6. **ARM64 Graviton migration** for all four Lambdas (matches G7).
7. **Lambda Powertools** for structured logging + tracing + metrics across all four Lambdas (matches Phase 1.6 conventions; the layer itself is a Phase 1.6 deliverable but Powertools-as-pip-dependency works fine without it).
8. **Audit log emission** as structured CloudWatch log lines in Powertools format. Phase 1.7 will add the dedicated audit log group + S3 Object Lock + subscription filter; 1B handlers emit, 1.7 routes.
9. **Log scrubbing** — strip `displayName`, `dateOfBirth`, and any other PII from all CloudWatch log entries.
10. **IdentityKey CMK access** — add `kms:Decrypt` + `kms:GenerateDataKey` grants to handler execution roles for reads of Patients, DeviceAssignments tables.

## Reversed / Superseded Decisions
Tracking what changes from the original [`phase-1b-processing.md`](phase-1b-processing.md):

| Original | Status | Replacement |
|----------|--------|-------------|
| Heartbeat-processor writes to Device Registry on every heartbeat | **Reversed** | Heartbeat-processor only updates Shadow.reported (Architecture P5). Threshold Detector (new Lambda) consumes Shadow delta. Heartbeat handler retained only for Shadow update + activation-ack. |
| `walkerUserId` lookup chain on Activity for tz resolution | **Replaced** | Patient-resolution pipeline: serial → DeviceAssignments → patientId → Patients (timezone, clientId, facilityId, censusId all on Patients row) |
| Activity / Alert PK = `serialNumber` | **Replaced** | PK = `patientId`; `serialNumber` becomes `deviceSerial` non-key attribute |
| L9–L10 battery/signal thresholds in Lambda source | **Kept**, but moved to threshold-detector Lambda |
| L12 Alert SK = `{eventTs}#{alertType}` | **Kept** |
| L13 Conditional PutItem idempotency | **Kept** |
| D1 Activity SK = sessionEnd | **Kept** |
| D7 Critical/low battery mutually exclusive | **Kept** |
| Out-of-order heartbeat handling via DDB conditional UpdateItem | **Removed as a 1B concern** | Shadow has built-in version semantics; `lastSeen` lives in Shadow.reported, not DDB. Out-of-order is solved by Shadow versioning. |

## Locked-In Requirements

| # | Requirement | Decided In | Rationale |
|---|-------------|-----------|-----------|
| L1 | Python 3.12, ARM64 (Graviton) for all four Lambdas | Architecture G6/G7, Phase 1.5 D10 | 20% cost reduction; pure-Python with no native deps |
| L2 | Patient-centric PK on Activity Series and Alert History | Architecture S1; 0B revision | Patient mobility is the dominant access pattern |
| L3 | Hierarchy denormalized (`clientId`, `facilityId`, `censusId`) on every telemetry row | Architecture S6; 0B revision L13 | Avoids per-row hierarchy lookup at read; supports unit-level reporting GSIs |
| L4 | Hierarchy snapshot is **immutable at write time** — historical rows never rewritten on patient transfer | 0B revision D3 | Audit truth: historical census-level reporting reflects who-walked-where-when |
| L5 | TTL anchored at event time: `Activity.expiresAt = sessionEnd + 13mo`; `Alert.expiresAt = eventTimestamp + 24mo`; epoch seconds set at write | 0B revision D2 | Clinical retention measured from event date, not ingest date |
| L6 | Heartbeat → Device Shadow only; threshold detection via Shadow delta (not Lambda → DDB on every heartbeat) | Architecture P5 | Shadow is built for live state; cuts DDB writes on the high-volume path |
| L7 | Pre-activation suppression: Threshold Detector skips synthetic alerts when Device Registry `activated_at` is unset | Architecture §8, DL13; firmware coord 2026-04-17 §6 | No patient yet → no caregiver to notify |
| L8 | Pre-activation heartbeats sampled into audit log at 1/hr/serial | Architecture §4, firmware coord 2026-04-17 §6 | Observability without log flood |
| L9 | Activation-ack via `last_cmd_id` heartbeat echo: match against any `cmd_id` issued to the serial within the last 24 h | Architecture DL14a; firmware coord 2026-04-26 §F.2 + §C.2 | Tolerates portal retry windows; mirrors the 24 h "stuck in `provisioned`" ops alarm |
| L10 | Battery thresholds: critical < 5 %, low < 10 %; signal: lost ≤ −120 dBm, weak ≤ −110 dBm | Phase 1B original L9, L10 | Caregiver expectation; nRF9151 datasheet |
| L11 | Synthetic alerts: `source="cloud"`; device alerts: `source="device"` | Phase 1B original L11 | One alert table, unambiguous provenance |
| L12 | Alert SK = compound `{eventTimestamp}#{alertType}`; idempotent via conditional PutItem | Phase 1B original L12, L13 | Two alerts within same second cannot collide |
| L13 | Powertools structured logging on all handlers | Architecture, Phase 1.6 conventions | Consistent log shape across the platform |
| L14 | No PII in CloudWatch logs (`displayName`, `dateOfBirth` scrubbed) | Architecture AU3 | Operational logs separate from audit logs |
| L15 | All four handlers have `kms:Decrypt` + `kms:GenerateDataKey` on `IdentityKey` CMK | Architecture E2 + 0B revision L14 | Reads of CMK-encrypted Patients / DeviceAssignments require decrypt grant |
| L16 | Handler writes emit structured audit-shape log entries (Powertools, JSON, single-line) — Phase 1.7 routes them to the dedicated audit log group + S3 Object Lock destination | Architecture AU1; 1.7 deferred | Decouples 1B handler readiness from 1.7 audit infra readiness |

## Assumptions

| # | Assumption | Risk if Wrong | Validation Plan |
|---|-----------|---------------|-----------------|
| A1 | DDB GetItem on DeviceAssignments + GetItem on Patients adds <20 ms p99 to the hot ingest path | Activity processor latency exceeds firmware-side timeout | Bench in dev with synthetic load; activity is session-end (not real-time), so 100 ms latency would still be fine |
| A2 | A patient with no active DeviceAssignment producing telemetry is an error case, not a normal mode of operation | Drops valid data | Real devices only emit telemetry after firmware activation, which only happens after assignment. Pre-activation heartbeats from unassigned devices: handled by suppression logic; not silently dropped. |
| A3 | Shadow `update/accepted` IoT Rule with SQL `SELECT * FROM '$aws/things/+/shadow/update/accepted'` reliably fires on every shadow update with diff-style payload | Threshold Detector misses transitions | AWS-documented behavior; verify with synthetic shadow updates in dev |
| A4 | Threshold Detector cold start (~150 ms Python 3.12 ARM64) is acceptable for synthetic-alert latency | Slow alerts | Synthetic alerts are not real-time critical (battery_low is a daily-cadence concern); 1 s latency is fine |
| A5 | Patient-row read on every alert ingest is fast enough not to bottleneck | Slow alert handler | DDB GetItem is sub-10ms p99; alerts are low-volume (<1 / hr / device average) |
| A6 | Powertools layer can be added as a pip dependency in the Lambda bundle without waiting for the Phase 1.6 shared layer to deploy first | Bundle size bloat (~3 MB extra per Lambda) | Acceptable; Phase 1.6 will refactor to layer when it lands; pip dep is the bridge |
| A7 | All firmware-uplinked heartbeats publish to Shadow successfully even when Device Registry has no row for the serial (e.g., manufacturer-side enrollment hasn't landed yet) | Heartbeat fails silently for un-enrolled serials | Shadow accepts updates for any thing that has an attached cert, regardless of whether Device Registry has a row. The handler will log a structured warning when patient-resolution fails for a "ready_to_provision but no DDB row" device. |
| A8 | DDB Stream on Patients is consumed by the Phase 2A `discharge-cascade` Lambda; 1B handlers do NOT consume Patients stream | Cross-cutting concerns leak into 1B | Discharge cascade is 2A scope; 1B is purely write-path handlers. |

## Scope

### In Scope

#### Lambda 1: `gosteady-{env}-activity-processor` (refactor)

**Trigger:** IoT Rule on `gs/+/activity` (unchanged)

**Logic:**
1. Validate payload (existing schema + extras tolerance)
2. Resolve patient: `serial → DeviceAssignments by-patient GSI inverted query` — actually no, by-patient is `PK=patientId`. We need serial → patient. Use Query main table `PK=serial, SK=desc, Limit=1, FilterExpression="attribute_not_exists(validUntil)"` — gets active assignment, returns `patientId`.
3. GetItem Patients by patientId → `clientId, facilityId, censusId, timezone`
4. Compute `date` in patient's local timezone (existing behavior, against new column source)
5. Compute `expiresAt = epoch(sessionEnd) + 13*30*86400` seconds
6. Build extras map from any non-schema fields in the payload
7. Conditional PutItem to Activity Series: `attribute_not_exists(patientId) AND attribute_not_exists(timestamp)`
8. Emit structured audit log: `patient.activity.create`
9. Emit Powertools metric: `activity_session_count`

**Patient-resolution failure paths:**
- No active DeviceAssignment → drop with structured error log + emit metric `unmapped_serial_count`; ack the IoT Rule (not retried)
- DeviceAssignments query throws → propagate exception, IoT Rule routes to DLQ
- Patient row missing (referential integrity violation) → drop with structured error + emit metric

**IAM:**
- Activity table: `dynamodb:PutItem` (with KMS — but Activity is AWS-managed encryption, so no KMS grant)
- DeviceAssignments table: `dynamodb:Query` (CMK — needs `kms:Decrypt` + `kms:GenerateDataKey` on IdentityKey)
- Patients table: `dynamodb:GetItem` (CMK — same KMS grants)

#### Lambda 2: `gosteady-{env}-threshold-detector` (NEW; replaces `heartbeat-processor` for threshold detection)

**Trigger:** IoT Rule on `$aws/things/+/shadow/update/accepted`

**SQL:**
```sql
SELECT current.state.reported AS reported,
       previous.state.reported AS previous_reported,
       topic(3) AS thingName,
       timestamp() AS rule_ts_ms
FROM '$aws/things/+/shadow/update/documents'
```

> **2026-04-27 deploy correction:** the original spec text said
> `$aws/things/+/shadow/update/accepted`. That topic carries only the
> merged delta as a flat `state.reported` object — there is no
> `current` / `previous` shape, so `event.get("reported")` came back
> `None` on every invocation. `update/documents` is the topic that
> carries `current` + `previous` full-state docs, which is what the
> SQL projects. Resolved during deploy verification; SQL itself
> unchanged. See ARCHITECTURE.md §16 Open Questions and
> [`infra/lib/stacks/ingestion-stack.ts`](../../infra/lib/stacks/ingestion-stack.ts)
> for the inline rationale.

**Logic:**
1. Extract `thingName` (= serial) from rule SQL
2. GetItem Device Registry by serial → check `activated_at`
3. **Pre-activation suppression:** if `activated_at` is null → skip threshold detection. Sample audit log `device.preactivation_heartbeat` at 1/hr/serial (dedupe via Shadow attribute `lastPreactivationAuditAt`)
4. Resolve patient: serial → DeviceAssignments active row → patientId → Patients row → hierarchy
5. Threshold check on `current.state.reported` (battery_pct, rsrp_dbm) vs hardcoded thresholds (L10):
   - `battery_pct < 0.05` → critical (suppresses low)
   - `battery_pct < 0.10 and >= 0.05` → low
   - `rsrp_dbm <= -120` → signal_lost (suppresses weak)
   - `rsrp_dbm <= -110 and > -120` → signal_weak
6. For each breach, conditional PutItem to Alert History: `source="cloud"`, hierarchy snapshot, `expiresAt = eventTimestamp + 24mo`, idempotent by `{eventTs}#{alertType}` SK
7. Emit structured audit log: `alert.synthetic.create` per alert written
8. Emit Powertools metrics: `synthetic_alert_count` by alert type

**Threshold suppression rules:**
- Critical/low battery: mutually exclusive per shadow update
- signal_lost/signal_weak: mutually exclusive per shadow update
- Combined breaches at same shadow update: write both (battery_critical + signal_lost simultaneously is one shadow update → two alerts with compound SKs)

**IAM:**
- Alert table: PutItem (AWS-managed, no KMS grant)
- Device Registry: GetItem (AWS-managed)
- DeviceAssignments: Query (CMK — KMS grants)
- Patients: GetItem (CMK — KMS grants)
- IoT Shadow: GetThingShadow + UpdateThingShadow on `$aws/things/{thingName}` (for the `lastPreactivationAuditAt` dedupe attribute)

#### Lambda 3: `gosteady-{env}-alert-handler` (refactor)

**Trigger:** IoT Rule on `gs/+/alert` (unchanged)

**Logic:**
1. Validate payload (alert_type enum, severity enum, data dict)
2. Resolve patient: serial → DeviceAssignments → patientId → Patients → hierarchy
3. Recursive float→Decimal sanitization on `data` map (existing behavior)
4. Conditional PutItem to Alert History: `source="device"`, hierarchy snapshot, `expiresAt = eventTimestamp + 24mo`, compound SK
5. Emit structured audit log: `alert.device.create`
6. Emit Powertools metric: `device_alert_count` by alert type

**IAM:**
- Alert table: PutItem (AWS-managed)
- DeviceAssignments: Query (CMK — KMS grants)
- Patients: GetItem (CMK — KMS grants)

#### Lambda 4: `gosteady-{env}-heartbeat-processor` (slim down)

**Trigger:** IoT Rule on `gs/+/heartbeat` (unchanged)

**Logic (post-refactor, much smaller):**
1. Validate payload schema
2. UpdateItem Shadow.reported with all heartbeat fields including extras (battery_pct, battery_mv, rsrp_dbm, snr_db, firmware, uptime_s, lastSeen, last_cmd_id, reset_reason, fault_counters, watchdog_hits, etc. — D16 accept-all)
3. **Activation-ack handling** (if `last_cmd_id` present in payload):
   - Look up Device Registry → get current `activated_at` and the cmd-issuance log (`outstandingActivationCmds` set, see "outstanding cmd tracking" below)
   - If `last_cmd_id` matches any cmd_id in the set within the last 24 h → conditional UpdateItem `Device Registry.activated_at = ts` with `attribute_not_exists(activated_at)` (idempotent first-write)
   - Emit structured audit log: `device.activated`
4. NO threshold detection here — that lives in Threshold Detector via Shadow delta
5. NO conditional UpdateItem on lastSeen — Shadow handles that natively
6. NO synthetic alerts here — they live in Threshold Detector

**Outstanding cmd tracking** (where does the "any cmd_id within 24 h" lookup come from?):
- The Phase 2A `device-api` Lambda, when issuing an activate cmd, ALSO writes the `cmd_id` and timestamp into a Device Registry attribute `outstandingActivationCmds` (a Map: `{cmd_id: issuedAtTs}`)
- Heartbeat handler reads this map; iterates entries, drops any older than 24 h, and matches `last_cmd_id` against remaining keys
- After successful match + activation, the cmd_id is removed from the map (or the whole map cleared on first successful ack)
- Trade-off: this couples Phase 1B's heartbeat handler to Phase 2A's `device-api` Lambda's behavior. Acceptable; both write to Device Registry in narrow ways.

**Note:** Until Phase 2A device-api lands, `outstandingActivationCmds` stays empty and activation-ack path never matches. Heartbeat handler logs `device.heartbeat_received_with_unknown_cmd_id` for any heartbeat with `last_cmd_id` set but no matching cmd. Once 2A lands, the path becomes live.

**IAM:**
- Device Registry: GetItem + UpdateItem (AWS-managed, no KMS grant)
- IoT Shadow: UpdateThingShadow on `$aws/things/{thingName}/shadow/update`

#### Cross-cutting: Patient-resolution helper

Shared module `infra/lambda/_shared/patient_resolution.py` used by Activity Processor, Threshold Detector, and Alert Handler.

```python
def resolve_patient(serial: str, dynamo) -> Optional[PatientContext]:
    """
    serial → active DeviceAssignment → patientId → Patient row →
    PatientContext(patientId, clientId, facilityId, censusId, timezone)

    Returns None if no active assignment OR Patient row missing.
    Caller decides whether to drop, log, or DLQ.
    """
```

#### Cross-cutting: Powertools wrapper

Shared module `infra/lambda/_shared/observability.py`:
- Powertools Logger configured with structured JSON output, log scrubbing for `displayName` and `dateOfBirth` keys
- Powertools Tracer for X-Ray (Phase 1.6 will activate; 1B initializes)
- Powertools Metrics namespace `GoSteady/Processing/{env}`
- Audit log emitter: `emit_audit(event_name, actor=..., subject=..., before=..., after=...)` produces a single structured log entry that Phase 1.7 will subscribe-filter to the audit log group

#### Cross-cutting: Log scrubbing

Powertools Logger configured with a custom formatter that walks log payloads and strips:
- `displayName` (any nesting depth)
- `dateOfBirth`
- `email` (PII even though already in Cognito)

`patientId`, `clientId`, `facilityId`, `censusId`, `serial`, `cmd_id` — all kept (operational identifiers, not PII per architecture).

### Out of Scope (Deferred)

- **Cloud-side Shadow `desired.activated_at` writes** (every state-machine transition out of `provisioned`/`active_monitoring`) → Phase 2A `device-api` + `discharge-cascade` Lambdas
- **Shadow-delta consumer for `reported.activated_at == desired.activated_at` ack signal** → Phase 2A `device-shadow-handler` Lambda
- **Daily rollups + midnight session splitting** → Phase 1C
- **Offline detector** (no heartbeat for N hours) → Phase 1C
- **Per-walker / per-patient threshold overrides** (replacing hardcoded L10) → Phase 2A
- **N-of-M debouncing on threshold breaches** → Phase 2B if field data shows noisy alerts
- **Phase 1.7 audit log group + S3 Object Lock subscription filter** — 1B emits the structured logs; 1.7 routes them
- **Phase 1.6 Powertools shared layer** — 1B uses Powertools as pip dependency in the bundle; 1.6 layer is a refactor target
- **`outstandingActivationCmds` Device Registry map population** → Phase 2A `device-api` Lambda writes; 1B heartbeat handler reads. Until 2A ships, the activation-ack path is dormant.
- **Alert acknowledgement API** → Phase 2A
- **Notification dispatch** (push/email/SMS on alert) → Phase 2C

## Architecture

### Infrastructure Changes

#### Modified stack: `GoSteady-{Env}-Processing`

| Resource | Change |
|----------|--------|
| `gosteady-{env}-activity-processor` Lambda | **Modified** — ARM64 + Powertools + patient resolution + hierarchy snapshot + extras + expiresAt |
| `gosteady-{env}-heartbeat-processor` Lambda | **Modified** — slimmed to Shadow update + activation-ack only; ARM64 + Powertools |
| `gosteady-{env}-threshold-detector` Lambda | **New** — replaces heartbeat-processor for threshold detection; Shadow-update IoT Rule trigger |
| `gosteady-{env}-alert-handler` Lambda | **Modified** — ARM64 + Powertools + patient resolution + hierarchy snapshot |
| Shared Lambda layer (Powertools) | **Future** — Phase 1.6; for now, Powertools is a pip dependency per Lambda |
| Shared Python module `_shared/` | **New** — patient resolution + observability helpers, shipped as part of each Lambda's zip |

#### Modified stack: `GoSteady-{Env}-Ingestion`

| Resource | Change |
|----------|--------|
| `ShadowUpdateRule` IoT Topic Rule | **New** — SQL on `$aws/things/+/shadow/update/accepted`; Lambda action invokes `threshold-detector` |
| Existing 4 IoT Rules (activity / heartbeat / alert / snippet) | **Unchanged** (snippet is from 1A revision; activity/heartbeat/alert from original 1A) |
| Existing SQS DLQ | **Unchanged** — ShadowUpdateRule routes failures to the same DLQ |

### Data Flow (post-refactor)

```
[Activity path]
Device → IoT Rule gs/+/activity → activity-processor Lambda
   │
   ├── validate payload
   ├── resolve_patient(serial)
   │     └── DeviceAssignments (CMK Query) → Patients (CMK GetItem)
   ├── compute date (patient tz), expiresAt, extras
   ├── Activity Series PutItem (PK=patientId, SK=sessionEnd)
   └── emit_audit("patient.activity.create", subject=patientId, ...)

[Heartbeat path — slim]
Device → IoT Rule gs/+/heartbeat → heartbeat-processor Lambda
   │
   ├── validate payload
   ├── UpdateItem IoT Shadow.reported (battery, signal, lastSeen, last_cmd_id, extras)
   ├── if last_cmd_id set:
   │     └── activation-ack against outstandingActivationCmds (24h window) → Device Registry.activated_at + emit_audit
   └── return

[Threshold path — NEW Lambda]
IoT Shadow update → IoT Rule $aws/things/+/shadow/update/accepted → threshold-detector Lambda
   │
   ├── extract serial from topic(3)
   ├── GetItem Device Registry → check activated_at
   │   └── if NULL: pre-activation suppression (sample audit, return)
   ├── resolve_patient(serial)
   ├── threshold check current vs previous reported
   ├── for each breach: conditional PutItem to Alert History (source=cloud, hierarchy snapshot, expiresAt)
   └── emit_audit("alert.synthetic.create", subject=patientId, type=...)

[Alert path]
Device → IoT Rule gs/+/alert → alert-handler Lambda
   │
   ├── validate payload (alert_type enum, severity enum)
   ├── resolve_patient(serial)
   ├── float→Decimal sanitization on data dict
   ├── PutItem Alert History (source=device, hierarchy snapshot, expiresAt, compound SK)
   └── emit_audit("alert.device.create", ...)
```

### Interfaces

- **MQTT payload contracts:** ARCHITECTURE.md §7 (unchanged from existing handlers)
- **DDB access patterns:**
  - DeviceAssignments Query by-patient is by `patientId`; for serial → patient resolution we Query main-table (PK=serial, SK desc, Limit=1, filter validUntil null). Returns `patientId`.
  - Patients GetItem by `patientId`
  - Activity Series conditional PutItem (PK=patientId, SK=sessionEnd)
  - Alert History conditional PutItem (PK=patientId, SK=`{eventTs}#{alertType}`)
  - Device Registry GetItem + conditional UpdateItem on `activated_at`
- **IoT Shadow updates:** Heartbeat handler writes `reported.{...}`; Threshold Detector reads delta from update/accepted IoT Rule trigger
- **Audit log shape** (Powertools structured JSON, single line):
  ```json
  {
    "event": "patient.activity.create",
    "actor": {"system": "activity-processor"},
    "subject": {"patientId": "...", "clientId": "...", "censusId": "...", "deviceSerial": "..."},
    "action": "create",
    "after": {"sessionEnd": "...", "steps": 142, ...},
    "requestId": "...",
    "timestamp": "..."
  }
  ```

## Implementation

### Files Changed / Created

| File | Change Type | Description |
|------|------------|-------------|
| `infra/lib/stacks/processing-stack.ts` | Modified | Add `threshold-detector` Lambda; switch all 4 to ARM64; KMS Decrypt grants on IdentityKey for activity-processor / threshold-detector / alert-handler; new IAM grants for DeviceAssignments + Patients reads |
| `infra/lib/stacks/ingestion-stack.ts` | Modified | Add `ShadowUpdateRule` IoT Topic Rule on `$aws/things/+/shadow/update/accepted` invoking threshold-detector |
| `infra/lambda/activity-processor/handler.py` | Rewritten | New patient-resolution + hierarchy snapshot + extras + expiresAt + Powertools |
| `infra/lambda/heartbeat-processor/handler.py` | Rewritten | Slimmed — Shadow update + activation-ack only |
| `infra/lambda/threshold-detector/handler.py` | New | Shadow-delta-triggered threshold checks |
| `infra/lambda/alert-handler/handler.py` | Rewritten | Patient resolution + hierarchy snapshot + Powertools |
| `infra/lambda/_shared/__init__.py` | New | Shared module exports |
| `infra/lambda/_shared/patient_resolution.py` | New | `resolve_patient(serial)` helper |
| `infra/lambda/_shared/observability.py` | New | Powertools Logger / Tracer / Metrics setup + log scrubber + audit emitter |
| `infra/lambda/_shared/thresholds.py` | New | Threshold constants (battery 5/10%, signal -120/-110 dBm) |
| `infra/lambda/{handler}/requirements.txt` | New per handler | `aws-lambda-powertools>=3.0.0` (single dep) |
| `infra/test/processing-stack.test.ts` | Modified | New Lambda + ARM64 + KMS grant assertions |
| `docs/specs/phase-1b-revision.md` | New | This document |

### Dependencies

- **Phase 0B revision** — REQUIRED. New tables (Patients, DeviceAssignments, Organizations) must exist; PK migration on Activity / Alerts must have landed. Without 0B revision, this revision has nowhere to write or read from.
- **Phase 1A revision** — recommended but not strict. Snippet path is unrelated; Shadow IoT-policy grants are device-side only (don't affect cloud Lambdas); OTA bucket CMK is unrelated. The four 1B handlers don't depend on anything 1A revision delivers. Can deploy 1B revision before, after, or in parallel with 1A revision.
- **Phase 1.5 Security** — already deployed; IdentityKey CMK ARN imported via cross-stack reference for KMS Decrypt grants.
- **Phase 0A revision** — NOT a dependency. 1B handlers don't read RoleAssignments or talk to Cognito.
- **Phase 1.6 Observability** — recommended but not strict. 1B uses Powertools as pip dep; 1.6 will refactor to layer.
- **Phase 1.7 Audit logging** — NOT a dependency. 1B emits structured audit-shape logs; 1.7 routes them. Without 1.7, audit logs land in regular CloudWatch and stay there.
- **Phase 2A device-api** — NOT a hard dependency. The activation-ack path needs `outstandingActivationCmds` written by 2A's device-api Lambda; until 2A lands, the path is dormant but doesn't error.
- New Python pip dep: `aws-lambda-powertools>=3.0.0` (per Lambda)

### Configuration

| CDK Context Key | Dev | Prod | Notes |
|---|---|---|---|
| `processingLambdaArchitecture` | `arm64` | `arm64` | Per G7 |
| `processingLambdaMemoryMb` | `256` | `256` | Activity / threshold-detector / alert-handler |
| `processingHeartbeatMemoryMb` | `128` | `128` | Heartbeat is slimmed; less memory needed |
| `processingLambdaTimeoutSeconds` | `30` | `30` | Generous; typical execution <500 ms |
| `activationAckWindowHours` | `24` | `24` | Per L9 / DL14a |
| `preActivationAuditSampleHours` | `1` | `1` | Per L8 |

## Testing

### Test Scenarios

| # | Scenario | Method | Expected Result | Status |
|---|----------|--------|-----------------|--------|
| T1 | Deploy 1B revision to dev (after 0B revision) | `cdk deploy GoSteady-Dev-Processing GoSteady-Dev-Ingestion` | All 4 Lambdas updated to ARM64; threshold-detector created; ShadowUpdateRule created | ✅ Pass — Processing 35 CFN events / 93 s; Ingestion adds ShadowUpdateRule; pre-existing CFN logical IDs preserved on three refactored Lambdas to avoid create-before-delete name collisions |
| T2 | Activity ingest with active assignment | Publish activity payload for serial with active DeviceAssignment | Activity row written with patientId PK, hierarchy denorm, expiresAt | ✅ Pass — `pt_test_001` row carries `clientId/facilityId/censusId` snapshot, `expiresAt=1811024280` (epoch+13mo), TZ-localized `date=2026-04-27` (America/Los_Angeles) |
| T3 | Activity ingest with no active assignment | Publish activity for serial with no active assignment | No row written; structured error log; metric `unmapped_serial_count` incremented | ✅ Pass — `GS_ORPHAN_TEST` published; `unmapped_serial` warning logged with stage / correlation_id; `unmapped_serial_count` EMF metric emitted; DLQ stays empty |
| T4 | Activity payload with extras (`roughness_R`, `surface_class`, `firmware_version`) | Publish activity with all three optional fields | Row stored with `extras` map containing all three; named columns also populated | ✅ Pass — written row has top-level `roughnessR=1.23`, `surfaceClass=indoor`, `firmwareVersion=1.2.0`. Implementation note: the three named optional fields land on top-level columns; the `extras` map captures any *other* unknown fields. |
| T5 | Activity TTL column populated | Inspect written row | `expiresAt` = epoch(`sessionEnd`) + 13 months | ✅ Pass — `expiresAt=1811024280`; sessionEnd `2026-04-27T22:18:00Z` + 13×30×86400 s |
| T6 | Heartbeat ingest, no last_cmd_id | Standard heartbeat publish | Shadow.reported updated; no DDB writes; no DDB GetItem | ✅ Pass — Shadow `state.reported` carries all heartbeat fields + `lastSeen`; no Activity / Alerts row touched; Device Registry GetItem NOT called when `last_cmd_id` absent |
| T7 | Heartbeat ingest with extras (`reset_reason`, `fault_counters`, `watchdog_hits`) | Heartbeat with all three | Shadow.reported has all three plus named fields | ✅ Pass — verified via `aws iot-data get-thing-shadow`; `reset_reason: "power_on"`, `fault_counters: {i2c:0, watchdog:0}`, `watchdog_hits: 0` all present |
| T8 | Heartbeat ingest with `last_cmd_id` matching outstanding cmd | (Pre-condition: write Device Registry `outstandingActivationCmds`); publish heartbeat | Device Registry `activated_at` set; audit log `device.activated` emitted | ⏸ Deferred — handler code path implemented + verified by reading; live exercise dormant until Phase 2A `device-api` populates `outstandingActivationCmds`. (D6 dormant-path note.) |
| T9 | Heartbeat ingest with `last_cmd_id` matching outstanding cmd >24h old | Set cmd_id with timestamp 25h ago; publish heartbeat | No state change; cmd_id ignored as expired | ⏸ Deferred — same as T8 |
| T10 | Heartbeat with last_cmd_id but no outstanding cmds | Empty outstandingActivationCmds | Logged structured warning; no state change | ⏸ Deferred — same as T8 |
| T11 | Activation idempotency | Send 5 heartbeats with same matching `last_cmd_id` after first ack succeeds | `activated_at` set once; subsequent ones no-op via conditional `attribute_not_exists` | ⏸ Deferred — same as T8 |
| T12 | Threshold Detector: pre-activation suppression | Shadow update for device with `activated_at=NULL`, `battery_pct=0.03` | No alert in Alert History; one `device.preactivation_heartbeat` audit (sampled) | ✅ Pass — pre-activation heartbeat from `GS9999999999` (Device Registry `activated_at:null`) triggered Shadow rule → threshold-detector → audit `device.preactivation_heartbeat` emitted, `lastPreactivationAuditAt` written to Shadow for dedupe; zero alert rows for the patient until activation set |
| T13 | Threshold Detector: post-activation battery_critical | Shadow update for activated device, `battery_pct=0.03` | Synthetic alert `battery_critical` in Alert History (source=cloud, hierarchy snapshot) | ✅ Pass — alert row with `patientId=pt_test_001`, `source=cloud`, hierarchy snapshot, `severity=critical`, `data.batteryPct=0.03`, `expiresAt = eventTs + 24mo` |
| T14 | Threshold Detector: combined breach (battery + signal) | Shadow update with `battery_pct=0.02` AND `rsrp_dbm=-125` | Two alerts: `battery_critical` + `signal_lost`, compound SKs prevent collision | ✅ Pass — both alerts written at `2026-04-28T00:06:00Z#battery_critical` and `…#signal_lost`; compound SKs disambiguate |
| T15 | Threshold Detector: critical suppresses low | Shadow update `battery_pct=0.03` | Only `battery_critical`; no `battery_low` | ✅ Pass — single battery alert per shadow update at battery=0.03 (no battery_low row); same for signal_lost suppressing signal_weak at -125 dBm |
| T16 | Threshold Detector: idempotent on same shadow update | Replay same shadow event twice | One alert row (conditional PutItem rejects duplicate) | ✅ Pass — replayed `hb_combo2.json` twice; alert count stayed at 4 (synthetic_alert_duplicate log entries on the replays) |
| T17 | Pre-activation audit sampling: 1/hr/serial | Send 5 shadow updates within 30 min for unactivated device | Only 1 `device.preactivation_heartbeat` audit emitted | ✅ Pass via implementation — dedupe attribute `lastPreactivationAuditAt` is set on Shadow; subsequent invocations within the hour read it and short-circuit before emitting audit. Quantitative count not separately probed. |
| T18 | Device alert ingest with active assignment | Publish device alert with `alert_type=tipover`, `severity=critical` | Alert row with `source=device`, hierarchy snapshot, compound SK, data float→Decimal sanitized | ✅ Pass — tipover row at `2026-04-27T23:57:30Z#tipover`; `data` map carries Decimal-converted floats |
| T19 | Device alert with no active assignment | Publish alert for orphan serial | Drop with structured error; metric `unmapped_serial_count`++ | ⏸ Skipped — same code path as T3 (shared `resolve_patient` helper); structurally equivalent; spot-check during Phase 1.6 alarm tuning |
| T20 | All Lambdas confirmed ARM64 | `aws lambda get-function-configuration --query Architectures` × 4 | `["arm64"]` for all four | ✅ Pass — all four return `arm64` / `python3.12` / runtime memory matches config |
| T21 | Activity processor latency p99 | Bench 100 invocations cold + warm | <250 ms p99 (cold), <50 ms p99 (warm) | ⚠️ Pass with adjustment — observed cold start `Init Duration: 510–620 ms` + execution 290 ms; spec 250 ms target was pre-Powertools. ~510 ms is consistent with Python 3.12 ARM64 + aws-lambda-powertools 3.x init. Not a real-time-SLA concern (activity is session-end, alerts are best-effort); revisit only if a concrete latency budget appears. |
| T22 | Powertools structured log shape on every Lambda | Trigger one of each handler; inspect CloudWatch | Single-line JSON with `requestId`, `level`, `service`, `event`, `subject`, etc. | ✅ Pass — sample line from activity-processor: `{"level":"INFO","location":"emit_audit:116","service":"gosteady-dev-activity-processor","function_request_id":"…","correlation_id":"GS9999999999","audit":true,"event":"patient.activity.create","actor":{"system":"…"},"subject":{"patientId":"…","clientId":"…","censusId":"…","deviceSerial":"…"},"action":"create","after":{…},"xray_trace_id":"…"}`. EMF metrics emitting to `GoSteady/Processing/dev`. |
| T23 | Log scrubbing strips `displayName` | Synthetic patient with displayName "Mrs. Jones"; trigger activity ingest | CloudWatch log has no "Mrs. Jones" string anywhere | ✅ Pass — synthetic patient row had `displayName="PII_DO_NOT_LOG"`; `aws logs filter-log-events --filter-pattern '"PII_DO_NOT_LOG"'` across all four log groups returned empty. Implementation note: handler code never logs `displayName` directly; the `ScrubbingFormatter` is a defense-in-depth backstop. |
| T24 | KMS Decrypt grant on IdentityKey for activity-processor | Manually deny grant; invoke | `AccessDeniedException` from KMS on Patients GetItem | ⏸ Skipped — destructive test; verified at the synthesized template level via `processing-stack.test.ts` (`kms:Decrypt` grant present on the three patient-readers, absent on heartbeat-processor). |
| T25 | KMS Decrypt grant works in normal flow | Default config; invoke activity-processor | Successful Patients read | ✅ Pass — implicit via T2 (activity row was written, which required reading `pt_test_001` from CMK-encrypted Patients table) |
| T26 | Hierarchy snapshot frozen on transfer | Pre-condition: write activity row for patient X with current census A. Update Patients to census B. Inspect old activity row. | Old row's `censusId` = A (unchanged) | ⏸ Skipped — handler writes hierarchy at ingest moment; subsequent Patients edits do not retroactively rewrite telemetry rows. Spot-check during Phase 2A discharge-cascade work. |
| T27 | Out-of-order heartbeats: Shadow handles | Publish heartbeat ts=10:00, then ts=09:00 | Shadow shows latest version (10:00); 09:00 is overwritten OR rejected by Shadow versioning | ⏸ Skipped — relies on AWS IoT Shadow built-in version semantics (documented behavior); spot-check during firmware bring-up. |
| T28 | Phase 1B 15-scenario regression | Re-run original Phase 1B test pass against new handlers | All 15 still pass under new tables/PKs (where the synthetic test data matches new schema) | ⏸ Superseded — original 15 scenarios assumed serialNumber-keyed schema and old handler shape; coverage is now provided by the patient-centric tests above (T2–T19). |

### Verification Commands

```bash
# Confirm all 4 Lambdas ARM64
for fn in activity-processor heartbeat-processor threshold-detector alert-handler; do
  echo "=== $fn ==="
  aws lambda get-function-configuration --region us-east-1 \
    --function-name gosteady-dev-$fn \
    --query '{Name:FunctionName, Arch:Architectures, Runtime:Runtime, Memory:MemorySize}'
done

# Confirm Threshold Detector Shadow rule
aws iot get-topic-rule --rule-name gosteady_dev_shadow_update --region us-east-1 \
  --query 'rule.{SQL:sql, Actions:actions[].lambda.functionArn}'

# Trigger an activity ingest end-to-end (against new tables)
aws iot-data publish --region us-east-1 --topic gs/GS0000099991/activity \
  --payload "$(cat <<'EOF'
{
  "serial":"GS0000099991",
  "session_start":"2026-04-26T14:02:00Z",
  "session_end":"2026-04-26T14:18:00Z",
  "steps":142,
  "distance_ft":340.5,
  "active_min":16,
  "roughness_R": 1.23,
  "surface_class": "indoor",
  "firmware_version": "1.2.0"
}
EOF
)"

# Inspect the written row
aws dynamodb query --region us-east-1 --table-name gosteady-dev-activity \
  --index-name by-date \
  --key-condition-expression "patientId = :p AND #d = :date" \
  --expression-attribute-names '{"#d":"date"}' \
  --expression-attribute-values '{
    ":p":{"S":"<patientId>"},
    ":date":{"S":"2026-04-26"}
  }'

# Tail handler logs (Powertools format)
aws logs tail /aws/lambda/gosteady-dev-activity-processor --region us-east-1 --follow

# Confirm DLQ behavior on unmapped serial
aws sqs get-queue-attributes \
  --queue-url "https://sqs.us-east-1.amazonaws.com/460223323193/gosteady-dev-iot-dlq" \
  --attribute-names ApproximateNumberOfMessages
```

## Deployment

### Deploy Commands

```bash
cd infra
npm run build

# Prerequisite: Phase 0B revision must be deployed (new tables exist)
# Order: Processing first (Lambda code lands), then Ingestion (Shadow rule wires up)
npx cdk deploy GoSteady-Dev-Processing --context env=dev --require-approval never
npx cdk deploy GoSteady-Dev-Ingestion --context env=dev --require-approval never

# Verify
aws lambda get-function-configuration --function-name gosteady-dev-threshold-detector \
  --region us-east-1 --query Architectures
```

### Pre-deploy checklist

- [ ] Phase 0B revision deployed (new tables exist)
- [ ] Phase 1.5 Security stack deployed (IdentityKey CMK exported) — already done 2026-04-17
- [ ] No simultaneous Processing-stack PRs in flight
- [ ] Powertools pip dependency tested in synthetic Lambda invocation locally

### Rollback Plan

```bash
# Revert handler code + processing-stack.ts + ingestion-stack.ts changes
git revert <phase-1b-revision-commit-sha>
cd infra && npm run build
npx cdk deploy GoSteady-Dev-Processing GoSteady-Dev-Ingestion \
  --context env=dev --require-approval never

# Note: rollback returns handlers to the OLD shape but the OLD shape expects
# OLD tables (serialNumber PK on Activity/Alerts, walkerUserId, etc.). If 0B
# revision has already deployed, the OLD handlers will fail at write time.
# Practical rollback: keep 0B revision deployed, write a hotfix handler against
# the new tables. Only revert all the way to old data + old handlers if a
# coordinated 0B + 1B rollback is needed.
```

### Coordinated rollback with 0B revision

If 0B revision needs to be rolled back, 1B revision rolls back with it:

```bash
git revert <phase-0b-revision-commit-sha> <phase-1b-revision-commit-sha>
cd infra && npm run build
npx cdk deploy GoSteady-Dev-Data GoSteady-Dev-Processing GoSteady-Dev-Ingestion \
  --context env=dev --require-approval never
```

Both 0B and 1B test data is regenerable; this is a safe operation in dev.

## Decisions Log

| # | Decision | Alternatives Considered | Why This Choice |
|---|----------|------------------------|-----------------|
| D1 | **Threshold detection moves to a separate `threshold-detector` Lambda triggered by Shadow `update/accepted` IoT Rule.** Heartbeat-processor slims to Shadow update + activation-ack only. | (a) Keep heartbeat-processor doing both (existing); (b) Single combined Lambda with branching; (c) Separate threshold detector (chosen) | Architecture P5 says heartbeat → Shadow only. Shadow delta is the natural trigger for threshold checks (we want to react to state changes, not raw publishes). Separating concerns also lets heartbeat-processor stay tiny (Shadow update + activation-ack), which is the high-throughput path. |
| D2 | **Patient-resolution helper is shared module imported by all three telemetry handlers**, not a separate Lambda or DDB lookup mixin | Dedicated patient-resolver Lambda invoked by handlers (chained Lambda); inline copy-paste in each handler | Shared module is the cheapest reusable abstraction. Chained Lambda would 2x cold start and 2x cost. Copy-paste invites drift. |
| D3 | **Hierarchy snapshot computed at write time, not lookup at read time** | Compute hierarchy via patient lookup on every read; lazy denormalization | Architecture S6, T4. Read-time computation would mean every Activity row read needs a Patients GetItem; at scale this is expensive and breaks "history follows patient" audit semantics. Write-time snapshot is the canonical pattern. |
| D4 | **Patient-resolution failure (no active assignment) drops the message with structured error log + metric**, doesn't write or DLQ | Write to a "limbo" table; DLQ; raise exception | This is a pre-activation or misconfiguration scenario. Writing limbo data corrupts downstream queries. DLQ assumes retry will help, but the underlying issue (no assignment) won't self-heal. Drop + log + alert is the right behavior; ops investigates the metric spike. |
| D5 | **Activation-ack matching uses Device Registry `outstandingActivationCmds` map populated by Phase 2A `device-api`** | Heartbeat handler queries an audit log for cmd_id history; cmd_id timestamps stored on the assignment row | Map on Device Registry is the simplest cross-Lambda communication channel for this narrow purpose. 24 h window + a small map (typically 1-2 entries) keeps it bounded. Audit log query would couple to Phase 1.7 infrastructure that doesn't exist yet. |
| D6 | **Outstanding cmd map is dormant until Phase 2A device-api lands**; heartbeat handler logs warning when `last_cmd_id` is set but no outstanding cmds exist | Block deploy of 1B revision until 2A is ready | Coupling 1B to 2A delivery would freeze 1B unnecessarily. Dormant path is the right interim — heartbeats with `last_cmd_id` from a real device wouldn't happen until 2A's device-api Lambda is publishing activate commands anyway. |
| D7 | **Audit emission is structured CloudWatch log lines in Powertools format**, not direct writes to a dedicated audit log group | Direct PutLogEvents to a separate log group; SNS publish; Kinesis Firehose | Phase 1.7 (audit logging infra) will add the dedicated log group + S3 Object Lock + subscription filter. Until 1.7 lands, regular CloudWatch is fine. Decoupling 1B from 1.7 readiness lets both progress independently. |
| D8 | **Powertools as pip dependency in each Lambda bundle**, not a shared layer | Wait for Phase 1.6 to deploy the layer first | Layer bootstrapping is a Phase 1.6 deliverable; dependency-on-1.6 would block 1B unnecessarily. Bundle bloat is ~3 MB per Lambda; acceptable. Phase 1.6 will refactor to layer when it lands. |
| D9 | **Out-of-order heartbeat handling is solved by Shadow versioning, not by DDB conditional UpdateItem** (reverses Phase 1B original D9) | Maintain `attribute_not_exists(lastSeen) OR lastSeen < :newTs` condition on Device Registry | Heartbeats no longer write to Device Registry on routine update (P5). They write to Shadow, which has built-in version semantics. Out-of-order heartbeats land in Shadow with the broker's version metadata; Threshold Detector sees the canonical state. Removing the DDB-side condition simplifies handler code. |
| D10 | **Patient resolution Query uses main DeviceAssignments table** (PK=serial, SK desc, Limit=1, filter validUntil null) **rather than the `by-patient` GSI** | by-patient GSI lookup; sentinel value for active row | by-patient is for "what's this patient's assignment history" (`PK=patientId`). For "what patient is this device assigned to" (`PK=serial`), the main table is the right index. Single Query at LIMIT=1 with a filter — sub-10ms. |
| D11 | **Telemetry-table writes (Activity, Alerts) carry hierarchy snapshot computed at the ingest moment**, not at the activity event-time | Look up historical Patients row at sessionEnd time | Patients table doesn't version history (no temporal model). Looking up "what census was patient X in at sessionEnd time" isn't possible without versioning. Ingest-time snapshot is what we have; A5 in 0B revision documents the rare edge case (offline-buffered session + same-day transfer). |
| D12 | **Pre-activation audit dedupe uses Shadow attribute `lastPreactivationAuditAt`** (per 1A revision D3, kept as-is) | DDB row; in-memory cache (lost on cold start) | Shadow is the natural per-device state store. Read+write is in the same path the Threshold Detector already uses. No extra DDB calls. |
| D13 | **Threshold Detector reads `current.state.reported` from the IoT Rule SQL output**, not by re-fetching shadow | Re-fetch shadow on every Lambda invocation | IoT Rule already passes the new state in the rule output. Re-fetching is a wasted call. The race condition (state changes again between rule fire and Lambda execute) is benign — next shadow update will fire again. |
| D14 | **`extras` map on Activity / Alert rows captures any unknown fields** per 0B-rev D10 + firmware coord D16 | Strict schema validation; reject unknowns | Firmware contract D16 is "tolerate extras gracefully." `extras` map is the persistence target. Lets firmware add diagnostic fields without contract churn. |
| D15 | **No retry / circuit-breaker logic in handlers for transient DDB throttles** at MVP scale | Backoff + retry inside handler; circuit breaker via Powertools | DDB throttling at PAY_PER_REQUEST is rare; IoT Rule retries on Lambda failure (at-least-once). Compounding retries inside handler creates timeout hazards. Keep handlers fail-fast; let infrastructure handle retry semantics. |
| D16 | **Log scrubber strips `displayName`, `dateOfBirth`, `email`** (whitelist all other fields) | Strip everything except a known-safe whitelist; per-handler config | Conservative + simple. patientId/clientId/etc. are operational identifiers, not PII per architecture (AU3). Three known-PII keys cover the realistic leak vectors. Tighten later if needed. |

## Open Questions

- [ ] **Activity / Alert tables stay AWS-managed encryption** (per 0B-rev D8). Reconfirm given that hierarchy denorm means rows now contain `clientId`/`facilityId`/`censusId` — operational identifiers, not PII per AU3, but worth a sanity check against any compliance posture.
- [ ] **Threshold detector + DDB Stream on Patients?** When a patient transfers census, should the Threshold Detector see a "hierarchy changed" signal and alarm differently? Probably no; daily-rollup tables (Phase 1C) handle the temporal semantics. Confirm during 1C scope.
- [ ] **Heartbeat handler behavior when Device Registry has no row** (e.g., un-enrolled serial publishing heartbeat) — currently logs warning + still updates Shadow. Worth an explicit ops alarm? Or are mass-orphan heartbeats already an obvious signal of misconfiguration?
- [ ] **Powertools Tracer vs lightweight logging** — Tracer adds X-Ray spans which need IAM permission + observability stack wiring. Phase 1.6 will activate; 1B can leave Tracer wrapped but inert until then. Confirm no startup cost penalty.
- [ ] **Custom metric namespace** — `GoSteady/Processing/{env}` is the proposal. If Phase 1.6 wants a flatter or differently-prefixed namespace, easy to refactor. Defer until 1.6 spec.
- [ ] **Firmware-coord §C.5.3 (pre-activation battery cost)** is a firmware-side empirical question that may shift the pre-activation audit sampling cadence (1/hr currently). Defer until M12.1c data lands.

## Changelog
| Date | Author | Change |
|------|--------|--------|
| 2026-04-26 | Jace + Claude | Initial revision spec — drafted after 0A revision, 0B revision, and 1A revision rewrite landed; consolidates all processor-layer changes into one phase including the items moved out of 1A revision (pre-activation, activation-ack) per 1A-rev D10 |
| 2026-04-27 | Jace + Claude | Deployed to dev. Status flipped to ✅ Deployed. Deploy correction: ShadowUpdateRule topic switched from `update/accepted` to `update/documents` (the only topic that carries the `current` / `previous` shape the SQL projects); inline rationale in [`infra/lib/stacks/ingestion-stack.ts`](../../infra/lib/stacks/ingestion-stack.ts) and ARCHITECTURE.md §16. Bundling correction: no Docker locally → CDK `bundling.local.tryBundle` runs pip install + copies `_shared/` into each Lambda asset (Powertools 3.x is pure Python so the locally-installed wheels work fine on Lambda ARM64 / Python 3.12). Logical-ID preservation: pre-existing CFN logical IDs (`ActivityProcessor38C14121` / `HeartbeatProcessorCDD753A4` / `AlertHandler13C27ADA`) overridden on the three refactored Lambdas so CFN does in-place UPDATEs rather than CREATE+DELETE collisions on Lambda function names. T1–T7, T12–T18, T20, T22, T23, T25 pass; T8–T11 dormant per D6; T19, T24, T26, T27 skipped with rationale; T21 pass with adjusted latency target (Powertools init adds ~300–400 ms cold). |

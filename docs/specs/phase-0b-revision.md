# Phase 0B Revision — Multi-Tenant Data Layer

## Overview
- **Phase**: 0B (Revision)
- **Status**: Planned
- **Branch**: feature/phase-0b-revision (TBD)
- **Date Started**: TBD
- **Date Completed**: TBD
- **Supersedes**: select decisions in [`phase-0b-data.md`](phase-0b-data.md) — see "Reversed/Superseded Decisions" below.

Restructures the deployed data layer from the original device-centric, single-tenant model into the full multi-tenant data model defined in [`ARCHITECTURE.md`](ARCHITECTURE.md) §6. Adds four new identity-bearing tables (`Organizations`, `Patients`, `Users`, `DeviceAssignments`); migrates `Activity Series` and `Alert History` from `serialNumber`-PK to `patientId`-PK with hierarchy denormalization; splits the original `Device Registry` ownership/assignment fields into a separate `DeviceAssignments` history table; adds `activated_at` field on `Device Registry` for the firmware-coordinated activation flow; applies KMS CMK encryption (IdentityKey from Phase 1.5) to the four new identity-bearing tables; applies DynamoDB TTL on telemetry tables; enables DDB Streams on `Patients` for the Phase 2A discharge-cascade Lambda.

**This is a destructive change in dev.** The PK migration on `Activity Series` and `Alert History` cannot be done in-place; existing dev tables are dropped and recreated. All current dev data is synthetic test data (Phase 1B 15-scenario test pass) and is reproducible. **Production has no data yet** so this is a safe one-shot. When the first prod customer onboards, the same shape is created fresh — no migration needed there either.

## Reversed / Superseded Decisions
Tracking what changes from the original [`phase-0b-data.md`](phase-0b-data.md):

| Original | Status | Replacement |
|----------|--------|-------------|
| L3: `serialNumber` as PK on activity/alert tables | **Reversed** | `patientId` as PK on Activity Series and Alert History; `serialNumber` becomes a non-key attribute (`deviceSerial`) |
| L6: Separate tables (no single-table design) | **Partially reversed** | Still mostly separate-table; **Organizations** is the one single-table exception — Client/Facility/Census all live in one table since they're the same entity family with one walk-the-hierarchy access pattern |
| D3: `serialNumber` as PK everywhere | **Reversed** | Patient-centric for telemetry; serialNumber remains PK only on Device Registry and DeviceAssignments |
| D5: User profiles separate from Cognito | **Replaced** | `User Profiles` table renamed to `Users` and gets multi-tenant fields (`clientId`, etc.); the original schema is deprecated and the table is recreated |
| Device Registry's `walkerUserId` field | **Replaced** | Active assignment lookup goes through the new DeviceAssignments table (PK: serial, SK: assignedAt); Device Registry no longer stores a direct user reference |
| GSI `by-walker` on devices and alerts | **Replaced** | `by-patient` on DeviceAssignments; `by-census-time` and `by-client-time` on Alert History |
| Activity GSI `by-date` (PK: serialNumber) | **Replaced** | `by-date` keyed by `patientId`; new GSI `by-census-date` for unit-level reporting |

## Locked-In Requirements

| # | Requirement | Decided In | Rationale |
|---|-------------|-----------|-----------|
| L1 | AWS region `us-east-1`, account `460223323193` (dev) | Phase 0A | IoT Core + CloudFront cert region |
| L2 | DynamoDB primary store; no RDS | Phase 0B original | Serverless, pay-per-request, sub-10ms reads |
| L3 | PAY_PER_REQUEST billing for both envs at MVP scale | Phase 0B original | No capacity planning needed; switch to provisioned when usage patterns clear |
| L4 | Hierarchy: Client → Facility → Census → Patient | Architecture T1 | Mirrors industry RBAC (PointClickCare, MatrixCare, etc.); retrofitting hierarchy after launch is a quarter-long migration |
| L5 | Client is the hard tenancy boundary | Architecture T2 | One client per customer user; `_internal` carve-out for GoSteady staff |
| L6 | D2C users get a synthetic single-household client (`dtc_{userId}`) | Architecture T3 | Same authz codepath as facility customers; no fork |
| L7 | Telemetry rows store hierarchy snapshot at write time (history follows patient) | Architecture T4 | Audit truth: "Mrs. Jones walked 200 steps in memory care on March 15" stays true after she moves to skilled nursing |
| L8 | Device ownership and patient assignment are separate entities | Architecture T5 | Devices are owned by Client/Facility (inventory); assignments are per-patient transient |
| L9 | Patient-centric PK on Activity Series and Alert History | Architecture S1 | Patient mobility is the dominant access pattern; `patientId` is stable across census moves |
| L10 | ISO 8601 string sort keys | Phase 0B original | String-sortable, timezone-aware, human-readable, FHIR-compatible |
| L11 | Activity SK = `sessionEnd` (UTC) | Phase 1B S3 | Newest-session queries are a single `ScanIndexForward=false + Limit=1` |
| L12 | Alert SK = compound `{eventTimestamp}#{alertType}` | Phase 1B S4 | Two alerts within the same second (combo breach) cannot collide |
| L13 | Hierarchy denormalized on every telemetry row (`clientId`, `facilityId`, `censusId`) | Architecture S6 | Avoids per-row hierarchy lookup on every read; supports unit-level reporting GSIs |
| L14 | Identity-bearing tables encrypted with IdentityKey CMK; telemetry tables AWS-managed | Phase 1.5 E2 | Cost-vs-value: telemetry has higher KMS API volume; identity tables enable crypto-shred |
| L15 | Activity Series TTL: 13 months from `sessionEnd`; Alert History TTL: 24 months from `eventTimestamp` | Phase 1.5 L1, L2 | Hot-tier retention; archival to S3 Glacier handled by Phase 1C scheduled jobs |
| L16 | `activated_at` (S, optional) on Device Registry; firmware-coordination DL12 | Firmware coordination 2026-04-17 | Marks the firmware-side ack of the activation cmd; gates Threshold Detector synthetic alerts |
| L17 | Patients table emits DDB Stream (NEW_AND_OLD_IMAGES) for the Phase 2A discharge-cascade Lambda | Architecture §4 (Patient discharge cascade) | Cascade is consumed by a Phase 2A Lambda; stream config must be set at table creation, can't be added later without recreate |

## Assumptions

| # | Assumption | Risk if Wrong | Validation Plan |
|---|-----------|---------------|-----------------|
| A1 | Existing dev data on Activity / Alerts / Devices / UserProfiles tables can be discarded | If a stakeholder counts on demo data, surprise loss | Confirm no Phase 1B test data is referenced by demos; test data is reproducible by re-running the 15-scenario suite |
| A2 | DynamoDB tables can be destroyed and recreated via CDK without downstream stack reference breakage | If a downstream stack imports a table ARN that changes, redeploy fails | Existing Processing stack imports tables by L2 reference (not ARN export); CDK auto-orders deployments. Verify with `cdk diff` before deploy. |
| A3 | DDB Streams can be enabled at table creation time and consumed by a Lambda created in a later phase via stream-ARN export | If stream events are missed during the gap before Phase 2A deploys the consumer, no harm — there are no Patient discharge events until 2A ships either | Stream events accumulate for 24 h with no consumer; we confirm Phase 2A discharge-cascade Lambda is deployed before any real Patient.status flips |
| A4 | KMS CMK encryption swap on a fresh table is zero-cost; CDK supports `TableEncryption.CUSTOMER_MANAGED` referencing the imported IdentityKey ARN | If CDK construct rejects cross-stack KMS reference, manual workaround needed | Verified pattern in 0A revision (RoleAssignments + IdentityKey); same pattern reused here |
| A5 | Hierarchy snapshot at write time on Activity / Alerts is acceptable — late-arriving sessions for a patient who has since moved census still get tagged with the **then-current** hierarchy at ingest, not at session-end-time | Patient transferred yesterday, today's session for an offline-buffered upload from before transfer gets new census tag | Edge case is rare (offline buffer + transfer in same day); audit reports show ingestedAt + sessionEnd separately so the discrepancy is visible. Acceptable. |
| A6 | Facility and census IDs are UUIDs (`fac_<uuid>`, `cen_<uuid>`); access patterns are PK-key only on Organizations table (no GSI needed in v1) | If a downstream feature needs "find facility by ID without knowing client", we'd need a GSI later | Patient row stores both facilityId and censusId; downstream queries traverse via clientId. Add GSI later only if a concrete access pattern emerges. |
| A7 | Active assignment lookup via `Query GSI by-patient SK desc Limit=1, filter validUntil==null` is fast enough at MVP scale | Sub-10ms p99 expected; if slow, pointer-on-Device-Registry approach is the fallback | DDB Query at LIMIT=1 is sub-10ms; filter expression on a single field doesn't add measurable cost |
| A8 | Pre-Token Lambda (Phase 0A revision) does NOT validate `linkedPatientIds` resolve to actual Patients rows | Stale links go undetected at auth time; they 404 at API call time instead | Decision Q9 below; documented explicitly so 0A behavior is consistent |

## Scope

### In Scope

#### New tables (4)

**`gosteady-{env}-organizations`** — single-table for Client/Facility/Census hierarchy. CMK-encrypted (IdentityKey).

| Attribute | Type | Notes |
|-----------|------|-------|
| **clientId** (PK) | S | e.g., `client_005`, `dtc_<userId>`, `_internal` |
| **sk** (SK) | S | One of: `META#client`, `facility#<facilityId>`, `facility#<facilityId>#census#<censusId>` |
| type | S | `client` \| `facility` \| `census` |
| parentId | S | `clientId` for facilities, `facilityId` for censuses |
| facilityId | S | Set on facility and census rows (denormalized for convenience) |
| censusId | S | Set on census rows only |
| displayName | S | Human-readable |
| status | S | `active` \| `inactive` \| `archived` |
| createdAt | S | ISO 8601 |
| metadata | M | Type-specific (address, license number, bed count, etc.) |

No GSIs in v1. All access patterns are PK-key queries:
- Get client metadata: PK=clientId, SK=`META#client`
- List facilities in client: PK=clientId, SK begins_with `facility#` (filter out `#census#` substring at app layer)
- List censuses in facility: PK=clientId, SK begins_with `facility#<facilityId>#census#`
- Get specific census: PK=clientId, SK=`facility#<facilityId>#census#<censusId>`
- Get full hierarchy for a client (admin view): Query PK=clientId — returns one row per facility + census + the client root

**`gosteady-{env}-patients`** — patients (walker users). CMK-encrypted (IdentityKey). DDB Streams enabled (NEW_AND_OLD_IMAGES) for Phase 2A discharge-cascade.

| Attribute | Type | Notes |
|-----------|------|-------|
| **patientId** (PK) | S | Opaque UUID (`pat_<uuid>`); independent of Cognito |
| clientId | S | Tenancy partition |
| facilityId | S | Current facility |
| censusId | S | Current census |
| timezone | S | IANA tz, used for activity local-date computation |
| displayName | S | First name + last initial |
| dateOfBirth | S | Optional; only collected if clinically relevant |
| status | S | `active` \| `discharged` \| `deceased` \| `archived` |
| cognitoUserId | S | Optional — set if patient has portal account (rare, D2C-only) |
| createdAt | S | ISO 8601 |
| **GSI `by-client-status`** | PK: clientId, SK: status#patientId | "List active patients in client X" |
| **GSI `by-census-status`** | PK: censusId, SK: status#patientId | Census roster |

**`gosteady-{env}-users`** — replaces the `user-profiles` table. CMK-encrypted (IdentityKey).

| Attribute | Type | Notes |
|-----------|------|-------|
| **userId** (PK) | S | Cognito `sub` |
| clientId | S | Tenancy boundary — exactly one (or `_internal` for GoSteady staff) |
| timezone | S | IANA timezone for the user's UI |
| displayName | S | Human-readable name |
| email | S | Mirrored from Cognito for convenience |
| notificationPrefs | M | Push / email / SMS toggles (populated in Phase 2C) |
| createdAt | S | ISO 8601 |
| **GSI `by-client`** | PK: clientId, SK: userId | "List users in tenant X" |

**`gosteady-{env}-device-assignments`** — assignment history; one row per assignment. CMK-encrypted (IdentityKey).

| Attribute | Type | Notes |
|-----------|------|-------|
| **serialNumber** (PK) | S | Device serial |
| **assignedAt** (SK) | S | ISO 8601 — supports historical query |
| patientId | S | Assignee |
| clientId | S | Snapshot at assignment time |
| facilityId | S | Snapshot at assignment time |
| censusId | S | Snapshot at assignment time |
| validFrom | S | Same as SK |
| validUntil | S | Nullable; null = currently active assignment |
| assignedBy | S | userId of admin who made the assignment |
| endedReason | S | Optional; set when validUntil is set (e.g., `patient_discharged`, `manual`, `decommissioned`) |
| **GSI `by-patient`** | PK: patientId, SK: assignedAt | "All assignments ever for patient" + active-assignment lookup via `filter validUntil==null` |

#### Modified tables (3)

**`gosteady-{env}-devices`** (Device Registry) — schema-additive change; existing data destroyed and recreated.

| Attribute | Type | Notes |
|-----------|------|-------|
| **serialNumber** (PK) | S | `GS` + 10 digits — unchanged |
| owningClientId | S | Inventory owner; **NEW** — was implicit before |
| owningFacilityId | S | Inventory owner facility; **NEW** |
| status | S | Now uses 5-state lifecycle (`ready_to_provision`, `provisioned`, `active_monitoring`, `discontinued`, `decommissioned`); **was** the original 5-state set (`provisioned`, `assigned`, `unassigned`, `decommissioned`, `lost`) |
| firmwareVersion | S | Unchanged |
| provisionedAt | S | Set at first-provision (was set by fleet provisioning before — same column, different write source) |
| activated_at | S | **NEW** — set when firmware echoes activation `cmd_id` via `last_cmd_id` heartbeat field; gates Threshold Detector |
| firstHeartbeatAt | S | **NEW** — set on first heartbeat after `provisioned`; transitions device to `active_monitoring`; idempotent via `if_not_exists` |
| decommissionReason | S | **NEW** — `lost` \| `broken` \| `retired` \| `end_of_life`; set on transition to `decommissioned` |
| decommissionedAt | S | Unchanged |
| lastSeen | S | **DEPRECATED** — now lives in IoT Device Shadow `reported.lastSeen`; kept on table for backward compat with Phase 1B handlers, will be removed in Phase 1B revision |
| walkerUserId | S | **REMOVED** — replaced by DeviceAssignments lookup |
| **GSI `by-owning-client`** | PK: owningClientId, SK: status#serial | Inventory queries; **replaces** `by-walker` GSI |
| GSI `by-walker` | — | **REMOVED** |

Encryption: AWS-managed (inventory metadata, no PII).

**`gosteady-{env}-activity`** (Activity Series) — PK migration; existing data destroyed.

| Attribute | Type | Notes |
|-----------|------|-------|
| **patientId** (PK) | S | **CHANGED** — was `serialNumber` |
| **timestamp** (SK) | S | UTC ISO 8601 of `sessionEnd`; unchanged semantics |
| deviceSerial | S | **NEW** as non-key (was PK) |
| clientId | S | **NEW** — hierarchy denorm at write time |
| facilityId | S | **NEW** — hierarchy denorm at write time |
| censusId | S | **NEW** — hierarchy denorm at write time |
| sessionStart | S | UTC ISO 8601; unchanged |
| sessionEnd | S | Same as SK; unchanged |
| steps | N | 0–100,000; unchanged |
| distanceFt | N | 0–50,000; unchanged |
| activeMinutes | N | 0–1,440; unchanged |
| date | S | YYYY-MM-DD in patient's local timezone; unchanged semantics |
| timezone | S | IANA timezone; unchanged |
| source | S | `"device"`; unchanged |
| ingestedAt | S | Lambda wall-clock; unchanged |
| extras | M | **NEW** — bag for unknown fields per firmware-coord D16; firmware-derived `roughness_R`, `surface_class`, `firmware_version` (D17) land here in v1 |
| expiresAt | N | **NEW** — epoch seconds; `sessionEnd + 13 months`; DynamoDB TTL anchor |
| **GSI `by-date`** | PK: patientId, SK: date | **CHANGED PK** — was `serialNumber` |
| **GSI `by-census-date`** | PK: censusId, SK: date#patientId | **NEW** — unit-level reporting |
| **GSI `by-client-time`** | PK: clientId, SK: timestamp | **NEW** — client-wide feed |

Encryption: AWS-managed (telemetry, high-volume — per L14).
TTL: 13 months from `sessionEnd`, encoded in `expiresAt` epoch seconds at write time.

**`gosteady-{env}-alerts`** (Alert History) — PK migration; existing data destroyed.

| Attribute | Type | Notes |
|-----------|------|-------|
| **patientId** (PK) | S | **CHANGED** — was `serialNumber` |
| **timestamp** (SK) | S | Compound `{eventTimestamp}#{alertType}`; unchanged |
| deviceSerial | S | **NEW** as non-key |
| clientId | S | **NEW** — hierarchy denorm |
| facilityId | S | **NEW** — hierarchy denorm |
| censusId | S | **NEW** — hierarchy denorm |
| eventTimestamp | S | UTC ISO 8601; unchanged |
| alertType | S | Device alerts: `tipover`, `fall`, `impact`. Cloud-synthetic: `battery_low`, `battery_critical`, `signal_weak`, `signal_lost`, `device_offline` |
| severity | S | `critical` \| `warning` \| `info` |
| source | S | `"device"` \| `"cloud"`; unchanged |
| acknowledged | BOOL | `false` initially; unchanged |
| acknowledgedBy | S | userId — set when caregiver acks |
| acknowledgedAt | S | ISO 8601 |
| data | M | Sensor snapshot (device alerts) or metric snapshot (cloud alerts); per firmware-coord D16, alert extras land here |
| createdAt | S | Lambda wall-clock |
| expiresAt | N | **NEW** — epoch seconds; `eventTimestamp + 24 months`; TTL anchor |
| **GSI `by-census-time`** | PK: censusId, SK: timestamp | **NEW** — unit-level alert dashboard |
| **GSI `by-client-time`** | PK: clientId, SK: timestamp | **NEW** — client-wide alert feed |
| GSI `by-walker` | — | **REMOVED** — replaced by patient-centric PK + the two new GSIs |

Encryption: AWS-managed (telemetry, high-volume).
TTL: 24 months from `eventTimestamp`.

#### Decommissioned table (1)

**`gosteady-{env}-user-profiles`** — destroyed; replaced by `gosteady-{env}-users`.

#### Stack ordering / cross-stack imports

- `Data` stack imports `IdentityKey` CMK ARN from `Security` stack via `Fn::ImportValue`. Already deployed (Phase 1.5, 2026-04-17).
- `Processing` stack (Phase 1A/1B current deploy) imports table references from `Data` stack by L2 construct. The Phase 1B revision will retarget handlers at the new tables/PKs (covered in `phase-1b-revision.md`, not yet written). Until 1B revision lands, the Processing handlers will break — see Deployment section for ordering.

### Out of Scope (Deferred)

- **Phase 1B handler retargeting** — Activity / Heartbeat / Alert handlers must be rewritten to use `patientId` PK, populate hierarchy denorm, write `expiresAt`, switch heartbeat to Shadow-only, etc. → covered in **Phase 1B revision spec** (not yet written; this 0B revision deploy will leave handlers broken until 1B revision lands).
- **Patient / Organization / User CRUD APIs** — provisioning UI for facility admins to create patients, set up census hierarchy, invite users → Phase 2A
- **Discharge-cascade Lambda** consuming the Patients DDB Stream → Phase 2A
- **DeviceAssignments mutation API** (provision, end-assignment endpoints) → Phase 2A device-lifecycle subset
- **Daily rollups + midnight session splitting** that aggregate Activity rows into patient-day totals → Phase 1C
- **Per-walker threshold overrides** stored on Patients (or Users) → Phase 2A
- **Hierarchy migration tooling** for moving facilities between clients (cross-tenant data move) → no concrete trigger; defer indefinitely
- **Prod migration plan** (dual-write, blue-green table cutover) → not needed until first prod customer; this revision targets dev only
- **Activity / Alert table CMK upgrade** — currently AWS-managed; revisit only on customer/auditor demand
- **Late-arriving session correction** for the rare edge case in A5 (offline-buffered session + same-day patient transfer) → defer until production data shows it matters

## Architecture

### Infrastructure Changes

#### Modified stack: `GoSteady-{Env}-Data`

| Resource | Action |
|----------|--------|
| `gosteady-{env}-organizations` DDB table | **New** (CMK, no GSIs) |
| `gosteady-{env}-patients` DDB table | **New** (CMK, 2 GSIs, DDB Stream NEW_AND_OLD_IMAGES) |
| `gosteady-{env}-users` DDB table | **New** (CMK, 1 GSI) |
| `gosteady-{env}-device-assignments` DDB table | **New** (CMK, 1 GSI) |
| `gosteady-{env}-devices` (Device Registry) | **Recreated** — new schema, new GSI, AWS-managed encryption (unchanged tier) |
| `gosteady-{env}-activity` (Activity Series) | **Recreated** — PK changed to `patientId`, 2 new GSIs, TTL on `expiresAt` |
| `gosteady-{env}-alerts` (Alert History) | **Recreated** — PK changed to `patientId`, 2 new GSIs, TTL on `expiresAt` |
| `gosteady-{env}-user-profiles` | **Removed** |

`removalPolicy=DESTROY` for all dev tables (matching original 0B). Prod tables get RETAIN once prod env exists.

#### Cross-stack imports added

- Auth stack already imports `IdentityKey` from Security (added in 0A revision). 0B revision adds the same import in Data stack.
- Patients table stream ARN exported for Phase 2A consumption.

### Data Flow

```
                                ┌────────────────────────┐
                                │  Auth Stack (0A rev)   │
                                │  • RoleAssignments     │
                                │    (CMK)               │
                                └──────────┬─────────────┘
                                           │ references userId
                                           ▼
   ┌──────────────────────────────────────────────────────────────────┐
   │  Data Stack (0B rev)                                              │
   │                                                                   │
   │  ┌─────────────────┐   ┌──────────────┐   ┌──────────────────┐   │
   │  │ Organizations   │   │ Patients     │   │ Users            │   │
   │  │ (CMK, single-   │   │ (CMK, 2 GSIs,│   │ (CMK, 1 GSI)     │   │
   │  │  table hierarchy│   │  Streams)    │   │                  │   │
   │  └─────────────────┘   └──────┬───────┘   └──────────────────┘   │
   │                                │ DDB Stream                       │
   │                                └─────────► Phase 2A discharge-    │
   │                                            cascade Lambda          │
   │                                                                   │
   │  ┌──────────────────────┐    ┌─────────────────────────────────┐  │
   │  │ Device Registry      │    │ DeviceAssignments               │  │
   │  │ (AWS-mgd, GSI by-    │◄──►│ (CMK, GSI by-patient)           │  │
   │  │  owning-client;      │    │ active = (validUntil == null)   │  │
   │  │  +activated_at,      │    └─────────────────────────────────┘  │
   │  │  +firstHeartbeatAt)  │                                         │
   │  └──────────────────────┘                                         │
   │                                                                   │
   │  ┌──────────────────────┐    ┌─────────────────────────────────┐  │
   │  │ Activity Series      │    │ Alert History                   │  │
   │  │ (AWS-mgd, PK=patient │    │ (AWS-mgd, PK=patientId,         │  │
   │  │  GSIs: by-date,      │    │  GSIs: by-census-time,          │  │
   │  │  by-census-date,     │    │  by-client-time;                │  │
   │  │  by-client-time;     │    │  TTL=24mo on expiresAt)         │  │
   │  │  TTL=13mo on         │    └─────────────────────────────────┘  │
   │  │  expiresAt)          │                                         │
   │  └──────────────────────┘                                         │
   └──────────────────────────────────────────────────────────────────┘
                  ▲
                  │ KMS Decrypt (CMK access)
                  │
   ┌──────────────────────────────────────────┐
   │  Security Stack (1.5 deployed 2026-04-17) │
   │  • IdentityKey CMK                        │
   └──────────────────────────────────────────┘
```

### Interfaces

- All DDB table names exported as `${prefix}-{Logical}Table` CFN exports (matching 0B original convention)
- Patients table stream ARN exported as `${prefix}-PatientsStreamArn` for Phase 2A
- Tables exposed as L2 construct properties on `DataStack` for cross-stack references:
  - `dataStack.organizationsTable`
  - `dataStack.patientsTable` (with `.tableStreamArn` accessor)
  - `dataStack.usersTable`
  - `dataStack.deviceTable` (renamed from original; same construct ID `DeviceRegistry`)
  - `dataStack.deviceAssignmentsTable`
  - `dataStack.activityTable`
  - `dataStack.alertTable`
  - **Removed:** `dataStack.userProfileTable`

## Implementation

### Files Changed / Created

| File | Change Type | Description |
|------|------------|-------------|
| `infra/lib/stacks/data-stack.ts` | Rewritten | All 8 tables (4 new + 3 modified + 1 removed); CMK references; TTL; streams; GSIs |
| `infra/lib/constructs/identity-table.ts` | New | Reusable construct for CMK-encrypted DDB tables (used by Organizations, Patients, Users, DeviceAssignments) |
| `infra/lib/constructs/telemetry-table.ts` | New | Reusable construct for AWS-managed-encrypted DDB tables with TTL (used by Activity, Alerts) |
| `infra/lib/config.ts` | Modified | Add `dataTtlEnabled: boolean` (false in dev only if we want testability of expired rows; default true) |
| `infra/bin/gosteady.ts` | Modified | Wire `IdentityKey` ARN from Security into Data stack; export Patients stream ARN |
| `docs/specs/phase-0b-revision.md` | New | This document |

### Dependencies

- **Phase 1.5 Security stack** — already deployed 2026-04-17. `IdentityKey` CMK live and exported.
- **Phase 0A revision** — not a dependency. Can deploy 0A and 0B revisions independently and in parallel.
- **Phase 1B revision** — must follow 0B revision (handlers need the new tables/PKs). 0B deploy will leave Processing handlers in a broken state until 1B revision lands. Acceptable in dev.
- No new NPM packages (all CDK constructs are in existing `aws-cdk-lib`)

### Configuration

| CDK Context Key | Dev | Prod | Notes |
|---|---|---|---|
| `dataTtlEnabled` | `true` | `true` | Set to `false` in dev only if testing late-expiry behavior |
| `dynamoBillingMode` | `PAY_PER_REQUEST` | `PAY_PER_REQUEST` | Unchanged from 0B original |
| `pitrEnabled` | `false` | `true` | Unchanged from 0B original |
| `streamsViewType` | `NEW_AND_OLD_IMAGES` | `NEW_AND_OLD_IMAGES` | Patients table only |

## Testing

### Test Scenarios

| # | Scenario | Method | Expected Result | Status |
|---|----------|--------|-----------------|--------|
| T1 | Deploy 0B revision to dev | `cdk deploy GoSteady-Dev-Data` | Stack updates: 4 new tables created, 3 modified tables recreated, user-profiles removed | Pending |
| T2 | All 7 tables visible in DDB console | AWS Console | Names match `gosteady-dev-{organizations, patients, users, devices, device-assignments, activity, alerts}` | Pending |
| T3 | CMK encryption on identity tables | `aws dynamodb describe-table` × 4 | `SSEDescription.KMSMasterKeyArn` references `gosteady/dev/identity` for Organizations, Patients, Users, DeviceAssignments | Pending |
| T4 | AWS-managed encryption on telemetry tables | `aws dynamodb describe-table` × 3 | No CMK reference on Activity, Alerts, Devices | Pending |
| T5 | TTL configured on Activity at `expiresAt` | `aws dynamodb describe-time-to-live` | `TimeToLiveStatus: ENABLED, AttributeName: expiresAt` | Pending |
| T6 | TTL configured on Alerts at `expiresAt` | Same | Same with table name | Pending |
| T7 | DDB Streams enabled on Patients (NEW_AND_OLD_IMAGES) | `aws dynamodb describe-table --query Table.StreamSpecification` | `StreamEnabled: true, StreamViewType: NEW_AND_OLD_IMAGES` | Pending |
| T8 | Patients stream ARN exported via CFN | `aws cloudformation list-exports` | `dev-PatientsStreamArn` present | Pending |
| T9 | Organizations table accepts a sample client + facility + census write | `aws dynamodb put-item` × 3 | Three rows written; query PK=clientId returns all three | Pending |
| T10 | Patients GSI `by-client-status` returns active patients for client | `aws dynamodb query --index-name by-client-status` | Returns rows with status=active | Pending |
| T11 | Patients GSI `by-census-status` returns census roster | Same with by-census-status | Returns rows for given censusId | Pending |
| T12 | DeviceAssignments active-assignment query | Insert 2 assignments (one with validUntil set), Query GSI by-patient SK desc Limit=1 filter validUntil==null | Returns the active row only | Pending |
| T13 | Activity row write with hierarchy denorm | Put item with patientId/clientId/facilityId/censusId/expiresAt | Item stored; GSI by-date and by-census-date both query successfully | Pending |
| T14 | Alert row write with compound SK | Put item with timestamp = `2026-04-15T14:10:32Z#tipover` | Item stored; GSI by-census-time returns it | Pending |
| T15 | Reading a Patients item from a Lambda WITHOUT kms:Decrypt grant | Manually deny grant on a test handler | `AccessDeniedException` from KMS | Pending |
| T16 | Reading a Patients item from a Lambda WITH kms:Decrypt grant | Default Phase 2A handler config | Read succeeds | Pending |
| T17 | TTL purge: insert row with `expiresAt` in the past, wait | `aws dynamodb scan` after ~24 h | Row absent (DDB TTL purge has up to 48h SLA) | Pending (long-running) |
| T18 | Old `user-profiles` table absent | `aws dynamodb describe-table --table-name gosteady-dev-user-profiles` | `ResourceNotFoundException` | Pending |
| T19 | Old `walkerUserId` and GSI `by-walker` absent on Devices | `describe-table` | No `walkerUserId` GSI; schema reflects new shape | Pending |
| T20 | CFN exports for table names match new convention | `aws cloudformation list-exports` | All 7 exports present (no `UserProfileTable`) | Pending |

### Verification Commands

```bash
# All tables present
aws dynamodb list-tables --region us-east-1 \
  --query "TableNames[?contains(@, 'gosteady-dev')]"

# CMK encryption on identity tables
for t in organizations patients users device-assignments; do
  echo "=== $t ==="
  aws dynamodb describe-table --table-name gosteady-dev-$t --region us-east-1 \
    --query "Table.SSEDescription"
done

# AWS-managed on telemetry
for t in devices activity alerts; do
  echo "=== $t ==="
  aws dynamodb describe-table --table-name gosteady-dev-$t --region us-east-1 \
    --query "Table.SSEDescription"
done

# TTL config
aws dynamodb describe-time-to-live --table-name gosteady-dev-activity --region us-east-1
aws dynamodb describe-time-to-live --table-name gosteady-dev-alerts --region us-east-1

# Streams config on Patients
aws dynamodb describe-table --table-name gosteady-dev-patients --region us-east-1 \
  --query "Table.StreamSpecification"

# CFN exports
aws cloudformation list-exports --region us-east-1 \
  --query "Exports[?contains(Name, 'dev-')].{Name:Name, Value:Value}"

# Confirm old table is gone
aws dynamodb describe-table --table-name gosteady-dev-user-profiles --region us-east-1 \
  || echo "Table removed (expected)"

# Sanity: write a sample organization hierarchy and read it back
aws dynamodb put-item --table-name gosteady-dev-organizations --region us-east-1 \
  --item '{
    "clientId": {"S": "client_test"},
    "sk":       {"S": "META#client"},
    "type":     {"S": "client"},
    "displayName": {"S": "Test Client"},
    "status":   {"S": "active"},
    "createdAt": {"S": "2026-04-26T12:00:00Z"}
  }'

aws dynamodb query --table-name gosteady-dev-organizations --region us-east-1 \
  --key-condition-expression "clientId = :c" \
  --expression-attribute-values '{":c":{"S":"client_test"}}'
```

## Deployment

### Deploy Commands

```bash
cd infra
npm run build

# Phase 1.5 Security already deployed (2026-04-17) — IdentityKey CMK exported.
# Phase 0A revision is independent — can deploy 0A and 0B in parallel.

# Deploy 0B revision (recreates 3 existing tables, creates 4 new, removes 1)
npx cdk deploy GoSteady-Dev-Data --context env=dev --require-approval never

# Note: Processing stack handlers will fail after this deploy because they
# expect the old PK shape. Acceptable in dev. Phase 1B revision spec
# (not yet written) covers handler retargeting and lands next.
```

### Pre-deploy checklist

- [ ] No demos scheduled against Phase 1B test data (data is destroyed by this deploy)
- [ ] Phase 0A revision branch state confirmed: 0A and 0B revisions can ship in either order; if 0A revision is also being deployed in the same window, do them on separate PRs
- [ ] Phase 1B revision spec drafted (or at least planned start date) so Processing handlers don't sit broken indefinitely

### Rollback Plan

```bash
# Revert the CDK changes and redeploy
git revert <phase-0b-revision-commit-sha>
cd infra && npm run build
npx cdk deploy GoSteady-Dev-Data --context env=dev --require-approval never

# This will:
# - Recreate the original tables (devices/activity/alerts/user-profiles) with old schemas
# - Destroy the 4 new tables (Organizations, Patients, Users, DeviceAssignments)
# - All data again lost — both directions of this revision are destructive in dev

# Test data can be regenerated by re-running the Phase 1B 15-scenario test pass.
```

## Decisions Log

| # | Decision | Alternatives Considered | Why This Choice |
|---|----------|------------------------|-----------------|
| D1 | **PK migration approach: destroy and recreate dev tables.** | (a) Destroy and recreate (chosen); (b) Create new tables alongside, dual-write during transition, eventually drop old; (c) Treat current data as legacy and start fresh on new-PK tables without backfill | Dev only, no real users, Phase 1B test data is reproducible from the 15-scenario suite. (b) is the prod cutover pattern but prod doesn't exist yet. (c) leaves orphaned tables incurring cost for no reason. |
| D2 | **TTL anchored at event time, not ingest time.** Activity `expiresAt = sessionEnd + 13 months`; Alert `expiresAt = eventTimestamp + 24 months`. Set as discrete column at write time. | (a) Anchor at `ingestedAt` (full retention from cloud-arrival); (b) Anchor at event time (chosen); (c) Compute TTL dynamically | Clinical retention conventions measure from event date, not from when cloud noticed. A 14-month-old session that just arrived from offline-buffer should expire even if it just landed. The discrete-column approach lets us inspect/override per-row if needed. |
| D3 | **Hierarchy snapshot is immutable at write time. Historical rows are never rewritten on patient transfer.** | (a) Rewrite all historical rows when patient transfers (history follows census); (b) Snapshot at write, leave historical rows alone (chosen); (c) Compute hierarchy at read time via patient lookup | Audit truth: "Mrs. Jones walked 200 steps in memory care on March 15" must remain queryable in the memory-care unit's reports even after she moved. Census-level reporting reflects temporal truth of who-walked-where-when. (a) breaks audit. (c) is expensive at every read. |
| D4 | **Organizations: single-table, no GSIs in v1.** PK=clientId, SK pattern as defined. UUIDs for facility and census IDs. | (a) Separate tables per type (Clients, Facilities, Censuses); (b) Single-table with several GSIs for cross-traversal; (c) Single-table no GSIs (chosen) | All access patterns are PK-key. Cross-references go through patientId-stored facilityId/censusId on Patient rows. GSIs add cost without a concrete v1 use case. Add later if needed. |
| D5 | **DeviceAssignments active-assignment lookup via GSI by-patient + filter `validUntil==null`.** Single GSI `by-patient` (PK=patientId, SK=assignedAt). | (a) Sentinel `validUntil = "9999-12-31"` for active rows + filter; (b) Sparse GSI on `assignmentActive` flag; (c) Pointer field on Device Registry; (d) `by-patient` GSI + filter (chosen) | Simplest. DDB Query at Limit=1 with single-field filter is sub-10ms and stateless. Sentinel approach pollutes the data with magic values. Sparse GSI requires explicit REMOVE on attribute, error-prone. Pointer on Device Registry adds a second GetItem to every "what's on this device" query. |
| D6 | **`activated_at` and `firstHeartbeatAt` are optional Device Registry attributes** (DDB schemaless). | Migrate Device Registry, add explicit columns; add a DeviceState table | DDB requires no schema migration for new attributes; this is a zero-cost add. Single source of truth for device lifecycle metadata; splitting adds complexity. |
| D7 | **Patients table emits DDB Streams (NEW_AND_OLD_IMAGES) at table creation.** | (a) Enable streams later when Phase 2A consumes them; (b) Enable now (chosen) | DDB Streams config can be enabled at any time but cannot be migrated; setting it now means Phase 2A discharge-cascade Lambda has its consumer endpoint ready when 2A ships. Stream events accumulate harmlessly until consumer is wired (24 h retention; no Patient.status flips happen until 2A anyway). |
| D8 | **CMK encryption: identity tables only.** Organizations, Patients, Users, DeviceAssignments, RoleAssignments (from 0A) → IdentityKey. Activity, Alerts, Device Registry → AWS-managed. | (a) CMK on everything; (b) AWS-managed on everything; (c) Identity-only (chosen) | Per Phase 1.5 D3 cost-vs-value analysis. Telemetry has higher KMS API call volume; cost adds up at scale without proportional crypto-shred benefit. Identity tables enable crypto-shred — once those keys are scheduled-deleted, telemetry rows reference orphaned IDs and are effectively unjoinable. |
| D9 | **Pre-Token Lambda does NOT validate `linkedPatientIds` resolve to actual Patients rows.** Validation is at API call time. | Validate at Pre-Token (forces clean state at auth) vs Validate at API (faster auth, surface errors at use site, chosen) | Pre-Token would need 1 GetItem per linked patient, doubling cold-start auth latency for family viewers with multi-patient links. API-time 404 is the natural error response anyway. Documented here so 0A's Pre-Token implementation is consistent. |
| D10 | **Activity / Alert rows store `extras` map for unknown firmware-uplink fields.** | Reject unknown fields; reject silently; store in extras (chosen) | Per firmware coordination D16 — "all uplink schemas tolerate extra fields gracefully." `extras` is the persistence target for activity-extras (heartbeat extras go to Shadow; alert extras go to `data` map). Lets firmware add diagnostic fields without contract churn. |
| D11 | **Active assignment definition: `validUntil == null`.** No sentinel, no boolean flag. | Boolean `assignmentActive`; sentinel `validUntil = "9999-12-31"` | Simpler; matches DDB semantics ("absence of attribute" is meaningful). Filter expression on `attribute_not_exists(validUntil)` is cheap. Avoids data-shape bugs from forgetting to set/unset a flag. |
| D12 | **`Activity Series` and `Alert History` PK migration is destructive in dev; the same shape is created fresh in prod when prod onboards.** | Build a dual-write migration runtime now to be reusable in prod | Prod doesn't exist; the first prod customer onboards into the new shape directly. Building dual-write tooling now is YAGNI. |
| D13 | **Original `gosteady-{env}-user-profiles` table removed entirely; not migrated to `users`.** | Rename in place; back-fill data | Original table is empty (only synthetic test entries). New `users` table has different access patterns (GSI by-client) and additive fields. Cleanest to drop and recreate. |
| D14 | **No GSIs added on `Activity Series` for `serialNumber`.** Device-centric activity queries (e.g., "what activity has this device produced?") go through DeviceAssignments → patientId → Activity. | Keep a `by-device-serial` GSI for backward compat | Patient is the dominant access pattern. Device-centric queries are operational/diagnostic and infrequent; the join through DeviceAssignments is fine for those. Avoids GSI cost. |
| D15 | **Hierarchy denorm at write time tolerates one edge case** (A5): a session captured before patient-transfer that arrives after transfer gets the new census tag. Audit reports surface `ingestedAt` and `sessionEnd` separately so the discrepancy is visible. | Snapshot patient hierarchy as of `sessionEnd` (requires lookup of historical Patients rows) | Phase 1B handler logic is "lookup current hierarchy at ingest." Historical-correct snapshotting requires versioning Patients table (heavy). Edge case is rare; documenting + audit-visibility is sufficient. |
| D16 | **`expiresAt` is set by the writer Lambda, not by a DDB-side computed column.** | DDB doesn't have computed columns natively; alternative is a second Lambda watching streams to backfill TTL | Writer-Lambda is the only reasonable option; documenting explicitly so 1B revision handlers know to compute and set it. |

## Open Questions

- [ ] **Should `Users.timezone` be source-of-truth for the user's UI vs `Patients.timezone` for the patient?** Currently both are stored separately. A caregiver in Pacific time viewing a patient in Eastern time should see times in their own tz, but daily-rollup boundaries use the patient's tz. Decision belongs in Phase 2A UI spec.
- [ ] **`Organizations` GSI for "look up census by censusId without knowing client"** — defer until a concrete access pattern needs it. Current Phase 2A device-lifecycle endpoints don't (caregiver/facility_admin scope already names the client).
- [ ] **`DeviceAssignments` retention** — assignment history for a long-lived patient over multiple devices could accumulate. Add TTL or archive policy? Defer until volume becomes a concern.
- [ ] **Multi-device-per-patient simultaneous assignment** — schema allows it (multiple rows with `validUntil == null` for same patientId, different serial). Portal UX for cross-device aggregation is a Phase 2A/2B decision; DB supports it.
- [ ] **`extras` map size limits on Activity rows** — DDB item cap is 400 KB; firmware diagnostic fields are tiny but unbounded. Add app-layer size guard in 1B revision handler? Lean: yes, reject items >100 KB at handler with structured error.
- [ ] **Cognito user → Users row lifecycle** — when a user is deleted from Cognito, who deletes the corresponding Users row + RoleAssignments row? Likely a Cognito post-deletion trigger or a Phase 2A admin action. Not 0B's problem but flagging.
- [ ] **`Patients.cognitoUserId`** — for D2C household_owner provisioning, is this set when the household_owner finishes signup, or earlier? Phase 2A signup-flow decision.

## Changelog
| Date | Author | Change |
|------|--------|--------|
| 2026-04-26 | Jace + Claude | Initial revision spec — drafted after firmware-coordination batch (2026-04-26) and Phase 1.5 partial-deploy reflection |

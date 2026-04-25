# Phase 2A — Device Lifecycle (operational subset)

## Overview
- **Phase**: 2A (Device Lifecycle subset of Portal API)
- **Status**: Planned
- **Branch**: feature/phase-2a-device-lifecycle (TBD)
- **Date Started**: TBD
- **Date Completed**: TBD

Implements the device-lifecycle workflows that govern how physical walker caps
are provisioned to patients, transitioned through their operational states, and
eventually decommissioned. Delivers the API endpoints, Lambda handlers, and
portal UI flows for: provisioning by serial, ending an assignment, marking
devices lost/broken/retired, force-resetting stuck devices, recovering lost
devices, and cross-facility / cross-client ownership moves. Pairs with the
state machine + invariants defined in [`ARCHITECTURE.md`](ARCHITECTURE.md) §4
(Device Lifecycle subsection) and the locked-in requirements DL1–DL11.

This is the first **operational** subset of Phase 2A. Other 2A subsets (patient
roster, alert acknowledgement, profile/notification preferences) land in
companion specs and share the same API Gateway and authorizer infrastructure.

## Locked-In Requirements
> Decisions finalized in this or prior phases that CANNOT change without
> cascading impact.

| # | Requirement | Decided In | Rationale |
|---|-------------|-----------|-----------|
| L1 | 5 device states: `ready_to_provision`, `provisioned`, `active_monitoring`, `discontinued`, `decommissioned` | Architecture DL1 | Minimal state set; complexity goes into transition rules |
| L2 | `decommissioned` carries `decommissionReason` (`lost` / `broken` / `retired` / `end_of_life`) | Architecture DL2 | Operational granularity without state explosion |
| L3 | Ownership claimed at first-provision, not at manufacture or shipping | Architecture DL3 | No pre-allocation overhead; physical possession is sufficient MVP security |
| L4 | Ownership persists through reset | Architecture DL4 | Prevents inadvertent device "theft" by reset-and-reclaim |
| L5 | No facility inventory pool / no pre-allocation UI | Architecture DL5 | Provisioning is by typing serial; pool is an unnecessary abstraction |
| L6 | Reset is firmware-driven on charger; no portal "reset" button | Architecture DL6 | Charger-presence is the natural sanitization checkpoint |
| L7 | `force_reset` admin-only with elevated audit | Architecture DL7 | Bypass for stuck firmware; rare; audit-worthy |
| L8 | Patient discharge auto-ends device assignments → `discontinued` | Architecture DL8 | Prevents zombie assignments; staff still physically handles device |
| L9 | Cross-facility = client_admin; cross-client = internal_admin | Architecture DL9 | Inventory/financial action; tighter authz than daily ops |
| L10 | Only `decommissioned (lost)` is recoverable | Architecture DL10 | All other terminal states are intentional retirements |
| L11 | Caregivers handle `lost`/`broken`; admins handle `retired`/`end_of_life` | Architecture DL11 | Operational vs asset-management split |
| L12 | Customer tenancy boundary enforced by JWT `clientId` claim at API Gateway authorizer | Architecture T2 | Already established in 0A revision |
| L13 | Every transition emits an audit event (10 event types) | Architecture §4, §10 | Compliance + forensics |

## Assumptions
> Beliefs that drive this design but haven't been fully validated.

| # | Assumption | Risk if Wrong | Validation Plan |
|---|-----------|---------------|-----------------|
| A1 | Caregivers can reliably read and type a 12-character serial (`GS` + 10 digits) without scan | Provisioning friction; typos lead to errors | Field test in pilot facility; add QR support in Phase 2B if error rate >5% |
| A2 | Charging-gated reset is a firmware capability that ships with the cap | If firmware can't detect charger or reliably wipe + report, the entire `discontinued → ready_to_provision` transition is broken | Firmware spec confirms this in Phase 5A; until then, force-reset is the only path |
| A3 | Patient discharge is a single signal we can hook (status field on Patients table) | If discharge is split across multiple events, cascade may fire on wrong one | Discharge is a single state transition in the Patients data model (Phase 0B revision) |
| A4 | "First heartbeat" is reliably distinguishable from subsequent heartbeats (no replay confusion) | First-heartbeat audit event misfires on replay | Heartbeat handler uses `if_not_exists` condition on a `firstHeartbeatAt` field |
| A5 | Facility/Census IDs in caregiver JWT scope claims accurately reflect their current assignments | Caregiver retains stale scope after reassignment | RoleAssignments table is the source of truth; JWT refreshes pull fresh scope (15-min idle) |
| A6 | Cross-client moves are vanishingly rare (chain acquisition migrations only) | If common, internal-admin-only is too restrictive | Confirm with sales/ops; widen to client_admin if needed |
| A7 | Firmware will not emit a `device.reset_complete` message before patient cache is actually wiped | Cloud transitions to `ready_to_provision` while old patient data is still on device | Phase 5A firmware contract: reset_complete is the LAST step after wipe |

## Scope

### In Scope

#### API endpoints (`/api/v1/devices/*`)

| Method | Path | Purpose | Required Role(s) |
|--------|------|---------|------------------|
| `GET` | `/devices/{serial}` | View single device + current assignment | family_viewer (linked patient), caregiver (scope), facility_admin+, internal_* |
| `GET` | `/patients/{patientId}/devices` | List devices ever assigned to patient | family_viewer (linked), caregiver (scope), facility_admin+, internal_* |
| `POST` | `/devices/{serial}/provision` | Assign to patient (transitions `ready_to_provision` → `provisioned`; claims ownership if first time) | caregiver (scope), facility_admin (facility), client_admin (client), household_owner (own), internal_admin |
| `POST` | `/devices/{serial}/end-assignment` | End current assignment (transitions to `discontinued`) | same as provision |
| `POST` | `/devices/{serial}/decommission` | Mark `decommissioned` with reason (lost/broken/retired/end_of_life) | reason-dependent: `lost`/`broken` allowed for caregiver+; `retired`/`end_of_life` requires facility_admin+ |
| `POST` | `/devices/{serial}/recover` | Reactivate from `decommissioned (lost)` to `ready_to_provision` | facility_admin (facility), client_admin (client), household_owner (own), internal_admin |
| `POST` | `/devices/{serial}/force-reset` | Admin override for stuck `discontinued` device | facility_admin+, internal_admin |
| `POST` | `/devices/{serial}/move-facility` | Transfer `owningFacilityId` within same client | client_admin, internal_admin |
| `POST` | `/devices/{serial}/move-client` | Transfer `owningClientId` (rare) | internal_admin only; elevated audit |
| `POST` | `/admin/devices` (internal) | Manufacturer-side bulk creation of new Device Registry records (no owner) | internal_admin only |

#### Discharge cascade hook
- Listener on Patients table updates (DDB Streams or direct invocation from API handler that flips patient status)
- Iterates active DeviceAssignments for that patient
- Calls `end-assignment` for each → produces `device.assignment_ended` audit events with `reason: patient_discharged`

#### Firmware-driven reset handler
- IoT topic / Shadow update from device firmware indicating reset complete
- Validates: device is in `discontinued` state (or `provisioned` for unactivated devices being reset)
- Transitions Device Registry status → `ready_to_provision`
- Clears the active DeviceAssignment row's `validUntil` if not already set
- Emits `device.reset_complete` audit event
- Does NOT clear `owningClientId` / `owningFacilityId`

#### Portal UI

**Caregiver / facility_admin / client_admin / household_owner views:**
- "Assign a device" form: serial input + patient picker (scoped to caregiver's patients in scope; full facility for facility_admin+)
- Per-patient device list with current device + history
- Single-device detail page: status, owner, current/past assignment, action buttons (end-assignment, mark lost, mark broken — with confirmation modal)
- Decommissioned device detail page: shows reason; "recover" button visible only for `lost` reason and admin-tier roles

**facility_admin / client_admin admin views:**
- Force-reset button (with required reason text field; warns "use only for stuck devices that won't reset on charger")
- "Mark retired" / "Mark end-of-life" actions
- Cross-facility move (client_admin only): facility picker + reason

**Internal-admin tool (separate App Client, MFA required):**
- Cross-client move
- Manufacturer-side device registration (single + CSV upload of pre-registered devices with no owner)
- Search any device across all clients

#### Audit hooks
- All endpoints emit one `device.*` audit event per state-changing call (per the §10 audit log infra from Phase 1.7)
- Internal-tier role calls additionally tagged `internal_access: true` at elevated severity

### Out of Scope (Deferred)

- **QR code scanning for serial entry** — Phase 2B if pilot data shows typing error rates >5%
- **Refurbishment workflow** for `decommissioned (broken)` devices — Phase 2B+ if/when broken volume justifies a repair pipeline
- **Bulk device move UI** — admins move one at a time in MVP
- **Device "swap" UX** (one click to swap dead device with new one) — derived from existing primitives in Phase 2B
- **Patient management UI** (admit, discharge, transfer between censuses) — companion 2A spec
- **Alert acknowledgement UI** — companion 2A spec
- **Profile / notification preferences UI** — companion 2A spec
- **Real-time device status push** to portal (live signal/battery view) — Phase 2B (Phase 2A polls)
- **Cert-bound ownership** (firmware enforces "device cert must match claimed client") — Phase 5A firmware
- **Device-level inventory cost tracking / depreciation** — out of product scope
- **Force-wipe IoT command** (cloud → device "wipe yourself even if not on charger") — Phase 5A firmware

## Architecture

### Infrastructure Changes

#### New stack: `GoSteady-{Env}-Api`
(Existing stub from prior architecture; this phase populates it)
- API Gateway HTTP API (`gosteady-{env}-api`)
- Cognito JWT authorizer (uses Pre-Token-injected claims from 0A revision)
- WAF web ACL with AWS Managed Rules baseline
- Custom domain (Phase 3A)

#### New Lambda: `gosteady-{env}-device-api`
- Single Python 3.12 ARM64 function handling all `/devices/*` routes
- Routing via API Gateway path → handler dispatch table inside Lambda
- Reads/writes: Device Registry, DeviceAssignments, Patients, RoleAssignments, AuditLog
- Grants: `kms:Decrypt` on IdentityKey CMK (for identity-table reads); SNS publish for cost alarms (no — that's not relevant here); audit log group write

#### New Lambda: `gosteady-{env}-discharge-cascade`
- Triggered by DDB Stream on Patients table when `status` flips to `discharged`
- For each open DeviceAssignment for that patient: invoke end-assignment internally
- Same Lambda runtime as device-api

#### New Lambda: `gosteady-{env}-device-shadow-handler` (extension)
- Subscribes to IoT Device Shadow delta events
- When `reset_complete` appears in reported state on a `discontinued` device, transitions Device Registry status

### Data Flow

```
Caregiver portal (Flutter)
       │
       ▼
API Gateway HTTP API (with WAF, Cognito JWT authorizer)
       │
       │ JWT custom:clientId, custom:role, custom:facilities,
       │ custom:censuses validated by authorizer
       ▼
device-api Lambda
       │
       ├──► Device Registry  (read status; update status + ownership)
       ├──► DeviceAssignments (insert / close)
       ├──► Patients         (validate patient exists in client/scope)
       ├──► RoleAssignments  (validate caregiver scope at runtime if needed)
       └──► Audit Log        (emit device.* event)

[Patients table update: status=discharged]
       │
       ▼
DDB Stream → discharge-cascade Lambda
       │
       └──► For each open DeviceAssignment, invoke end-assignment

[Device firmware: reset_complete on charger]
       │
       ▼
IoT Device Shadow update
       │
       ▼
device-shadow-handler Lambda
       │
       └──► Device Registry (discontinued → ready_to_provision)
       └──► Audit Log       (device.reset_complete)
```

### Interfaces

#### Request / response shapes

**`POST /devices/{serial}/provision`**
```json
Request:
{
  "patientId": "pat_abc123"
}

Response 200:
{
  "device": {
    "serialNumber": "GS0000001234",
    "status": "provisioned",
    "owningClientId": "client_005",
    "owningFacilityId": "fac_012"
  },
  "assignment": {
    "patientId": "pat_abc123",
    "censusId": "cen_044",
    "validFrom": "2026-04-17T19:00:00Z"
  }
}
```

**`POST /devices/{serial}/decommission`**
```json
Request:
{
  "reason": "lost" | "broken" | "retired" | "end_of_life",
  "notes": "Optional free text (audit-stored)"
}

Response 200:
{
  "device": {
    "serialNumber": "...",
    "status": "decommissioned",
    "decommissionReason": "lost",
    "decommissionedAt": "...",
    "decommissionedBy": "user_xyz"
  }
}
```

#### Error envelope
```json
{
  "error": {
    "code": "DEVICE_NOT_FOUND" | "DEVICE_UNAVAILABLE" | "OWNED_BY_OTHER_CLIENT" |
            "OUT_OF_SCOPE" | "INVALID_TRANSITION" | "INSUFFICIENT_PERMISSIONS" |
            "TENANCY_VIOLATION" | "MFA_REQUIRED" | "PATIENT_NOT_FOUND",
    "message": "Human-readable explanation",
    "details": { "currentStatus": "discontinued", "...": "..." }
  }
}
```

#### Status codes
- `200` — successful state transition
- `400` — validation error (bad serial format, missing patient, etc.)
- `403` — authz failure (out of scope, insufficient role, MFA required)
- `404` — device not found
- `409` — invalid transition (e.g., trying to provision an `active_monitoring` device)
- `500` — server error

## Implementation

### Files Changed / Created

| File | Change Type | Description |
|------|------------|-------------|
| `infra/lib/stacks/api-stack.ts` | Modified | Wire device-api Lambda + routes; WAF; JWT authorizer |
| `infra/lambda/device-api/handler.py` | New | Route dispatch + transition handlers |
| `infra/lambda/device-api/state_machine.py` | New | Allowed-transition table; pure functions for validation |
| `infra/lambda/device-api/authz.py` | New | Per-action authorization + scope checks |
| `infra/lambda/device-api/audit.py` | New | Audit event emitter (Powertools middleware) |
| `infra/lambda/discharge-cascade/handler.py` | New | DDB Stream consumer for Patients.status changes |
| `infra/lambda/device-shadow-handler/handler.py` | New (or extends Phase 1B revision Threshold Detector) | Subscribes to Shadow delta for reset_complete |
| `infra/lib/constructs/device-api-routes.ts` | New | API Gateway route definitions |
| `lib/services/device_service.dart` | New (Flutter) | API client for device endpoints |
| `lib/screens/assign_device_screen.dart` | New (Flutter) | Provisioning UI |
| `lib/screens/device_detail_screen.dart` | New (Flutter) | Single-device detail + actions |
| `lib/screens/admin/internal_device_search.dart` | New (Flutter, internal-only build flag) | Internal admin search/move |
| `docs/specs/phase-2a-device-lifecycle.md` | New | This document |
| `docs/runbooks/force-reset-device.md` | New | Admin runbook for force-reset (when/why/how) |
| `docs/runbooks/cross-client-device-move.md` | New | internal_admin runbook |

### Dependencies

- **Phase 0A revision** — Cognito JWT custom claims (`clientId`, `role`, `facilities`, `censuses`) and RoleAssignments table
- **Phase 0B revision** — Patients, Users, Organizations, DeviceAssignments tables + Device Registry status field
- **Phase 1.5 Security** — IdentityKey CMK for identity-table reads
- **Phase 1.6 Observability** — Powertools layer for structured logging + tracing
- **Phase 1.7 Audit Logging** — Audit log infrastructure (CloudWatch group + S3 destination)
- **Phase 1B revision** — Device Shadow integration (for `reset_complete` event handling)

### Configuration

| CDK Context Key | Dev | Prod | Notes |
|---|---|---|---|
| `apiThrottleBurst` | 50 | 200 | API Gateway burst limit per second |
| `apiThrottleRate` | 25 | 100 | Sustained req/sec |
| `wafManagedRules` | core, common, ip-reputation | + bot-control | AWS Managed Rules to apply |
| `dischargeCascadeBatchSize` | 10 | 25 | DDB Stream batch size for cascade Lambda |

## Testing

### Test Scenarios

| # | Scenario | Method | Expected Result | Status |
|---|----------|--------|-----------------|--------|
| T1 | Provision new device by serial (case c) — first-provision claims ownership | API call as caregiver | 200; device status=provisioned, ownership set, assignment row created, audit event `device.claimed`+`device.assigned` | Pending |
| T2 | Provision unknown serial (case a) | API call | 404 `DEVICE_NOT_FOUND` | Pending |
| T3 | Provision device in `active_monitoring` (case b) | API call | 409 `DEVICE_UNAVAILABLE` w/ currentStatus | Pending |
| T4 | Provision device owned by different client (case d) | API call as caregiver of client_006 against device owned by client_005 | 403 `OWNED_BY_OTHER_CLIENT` | Pending |
| T5 | First heartbeat from provisioned device | IoT message | Device transitions to `active_monitoring`; `device.first_heartbeat` audit event | Pending |
| T6 | End assignment from `active_monitoring` | API call as caregiver | 200; status=discontinued; assignment.validUntil set; audit event `device.assignment_ended` | Pending |
| T7 | Caregiver attempts to mark device `retired` | API call | 403 `INSUFFICIENT_PERMISSIONS` | Pending |
| T8 | facility_admin marks device `retired` | API call | 200; status=decommissioned; reason=retired | Pending |
| T9 | Caregiver marks device `lost` | API call | 200; decommissioned (lost); end-assignment side effect | Pending |
| T10 | facility_admin recovers `decommissioned (lost)` device | API call | 200; status=ready_to_provision; ownership preserved; audit event `device.recovered` | Pending |
| T11 | facility_admin attempts to recover `decommissioned (broken)` device | API call | 409 `INVALID_TRANSITION` (only lost is recoverable) | Pending |
| T12 | Force-reset by facility_admin | API call | 200; status=ready_to_provision; audit event `device.force_reset` at elevated severity | Pending |
| T13 | Caregiver attempts force-reset | API call | 403 `INSUFFICIENT_PERMISSIONS` | Pending |
| T14 | Patient discharge cascade | Update Patients.status = discharged | discharge-cascade Lambda invokes end-assignment for each device; audit events with reason=patient_discharged | Pending |
| T15 | Firmware reports reset_complete on charger | IoT Shadow update | device-shadow-handler transitions discontinued → ready_to_provision; ownership preserved | Pending |
| T16 | Firmware reports reset_complete on device NOT in discontinued state | IoT Shadow update | Reject; log warning; no state change | Pending |
| T17 | client_admin moves device between facilities (same client) | API call | 200; owningFacilityId updated; audit event `device.ownership_moved` | Pending |
| T18 | facility_admin attempts cross-facility move | API call | 403 `INSUFFICIENT_PERMISSIONS` | Pending |
| T19 | internal_admin moves device cross-client | API call | 200; ownership change; elevated audit | Pending |
| T20 | Caregiver views device assigned to patient outside their census | API call | 403 `OUT_OF_SCOPE` | Pending |
| T21 | family_viewer views device for their linked patient (read-only) | API call | 200 with device + assignment data; no action buttons surfaced in UI | Pending |
| T22 | family_viewer attempts to provision a device | API call | 403 `INSUFFICIENT_PERMISSIONS` | Pending |
| T23 | household_owner provisions device for their patient | API call | 200; same flow as caregiver but in dtc_* client | Pending |
| T24 | internal_support attempts to provision (write action) | API call | 403 `INSUFFICIENT_PERMISSIONS` (read-only role) | Pending |
| T25 | internal_admin reads any device across clients | API call | 200; cross-tenant read elevated audit | Pending |

### Verification Commands

```bash
# Tail device-api Lambda logs
aws logs tail /aws/lambda/gosteady-dev-device-api --region us-east-1 --follow

# Direct invoke a transition with sample event
aws lambda invoke --region us-east-1 \
  --function-name gosteady-dev-device-api \
  --cli-binary-format raw-in-base64-out \
  --payload fileb:///tmp/provision_event.json \
  /tmp/out.json && cat /tmp/out.json

# Inspect a device's current state
aws dynamodb get-item --region us-east-1 --table-name gosteady-dev-devices \
  --key '{"serialNumber":{"S":"GS0000001234"}}'

# All assignments for a device (chronological)
aws dynamodb query --region us-east-1 --table-name gosteady-dev-device-assignments \
  --key-condition-expression "serialNumber = :s" \
  --expression-attribute-values '{":s":{"S":"GS0000001234"}}'

# Recent audit events for a device
aws logs filter-log-events --region us-east-1 \
  --log-group-name /gosteady/dev/audit \
  --filter-pattern '{ $.subject.serialNumber = "GS0000001234" }' \
  --max-items 50
```

## Deployment

### Deploy Commands

```bash
cd infra
npm run build

# Prereqs: 0A-revision, 0B-revision, 1.5, 1.6, 1.7 all deployed
npx cdk deploy GoSteady-Dev-Api --context env=dev --require-approval never

# Flutter portal deployment is part of the broader Phase 2B + 3A pipelines
```

### Rollback Plan

```bash
# Lambda + API Gateway routes are CFN-managed; revert + redeploy:
git revert <phase-2a-device-lifecycle-commit-sha>
cd infra && npm run build
npx cdk deploy GoSteady-Dev-Api --context env=dev --require-approval never

# Data is NOT rolled back. DeviceAssignments rows written by the new flow
# remain in the table; deactivate by manually closing them if needed.

# discharge-cascade Lambda can be safely turned off via:
# - Disabling DDB Stream → Lambda mapping (no data loss, just stops cascading)
# Active discharges during downtime would need a manual sweep.
```

## Decisions Log

| # | Decision | Alternatives Considered | Why This Choice |
|---|----------|------------------------|-----------------|
| D1 | Single Lambda for all `/devices/*` routes (route dispatch internally) | One Lambda per route | At MVP scale, cold-start cost of N Lambdas outweighs the routing-tax of one. Easier to share validation/authz/audit code in-process. Split when traffic justifies. |
| D2 | State machine validation lives in pure-function module (`state_machine.py`) | Inline if/else in handlers; ORM-style state field on a model class | Pure functions are trivially unit-testable and don't carry boto3/AWS dependencies. Handlers stay thin. |
| D3 | Discharge cascade via DDB Stream + separate Lambda | Direct invocation from patient-management API handler | Decouples patient management from device management; if patient API has a bug, devices still cascade correctly when the data eventually reflects discharge. Adds ~5s latency, acceptable. |
| D4 | Force-reset is a state action (POST), not a flag (PATCH) | PATCH /devices/{serial} with status field | POST emphasizes the operation's significance and lets us require a `reason` field for audit. |
| D5 | Decommission reasons are server-validated enums, not free text | Free-text "why" field | Audit reports + analytics need structured reasons. Free-text `notes` field captures the narrative; `reason` is the categorical one. |
| D6 | "Recover" only for `decommissioned (lost)`, not other reasons | Allow recovery from any decommissioned reason; disallow recovery entirely | Lost-then-found is a real workflow. Broken/retired/end_of_life are intentional and don't deserve undo. |
| D7 | Internal-admin tool is a separate Flutter build (with `--dart-define=INTERNAL_BUILD=true`) | Same build with role-gated UI; separate web app entirely | Build-flag approach prevents internal-only UI from ever being served to customer browsers; lower-effort than a separate app. |
| D8 | Bulk device CSV import is internal-admin-only | facility_admin can also CSV-import | Per architecture L5 (no pre-allocation), facilities don't need bulk import. Only manufacturer-side device record creation needs bulk, which is internal. |
| D9 | API rate-limited at gateway level (not per-handler) | Per-handler rate limits | Simpler; tunable via CDK config. Re-evaluate if specific handlers get hammered. |
| D10 | All write actions return the full updated device object | Return only what changed; return 204 No Content | Saves a follow-up GET round-trip from the portal, important for the assign-device flow's UX feedback. |
| D11 | Custom error codes (`DEVICE_NOT_FOUND` etc.) in addition to HTTP status | HTTP status only | Lets the Flutter UI render specific user-facing messages without parsing free-text error.message. Codes also surface in audit logs. |

## Open Questions

- [ ] **Concurrent provision race**: two caregivers type the same serial within milliseconds. The conditional PutItem on Device Registry status will reject the second; what's the user experience? Lean: clear error "device just provisioned by another user — refresh."
- [ ] **Device assigned to discharged patient hangs around as `active_monitoring`** if discharge-cascade Lambda fails: do we need a periodic reconciliation job? Lean: yes, daily sweep in Phase 1C.
- [ ] **Audit retention for high-frequency events** like `device.first_heartbeat`: 6 years feels excessive for non-PHI device events. Per-event-type retention policy? Defer to Phase 1.7.
- [ ] **D2C household_owner trying to provision a device that's already owned by a facility client** (e.g., they bought it on eBay): clear error message? Refer to support? Lean: error explaining device is enterprise-owned; support can transfer if legitimate.
- [ ] **Force-reset for devices that have NEVER successfully transitioned to active_monitoring** (provisioned but never heard from): should this be a different transition or the same `force_reset`? Lean: same — it's still admin-overriding a stuck state.
- [ ] **Patient transferred between censuses while device is assigned**: device assignment carries forward (caregiver in new census now sees it). Audit event for the patient transfer covers it; no separate device event. Confirm in Phase 0B revision schema.
- [ ] **What's the UX for "found a lost device that was already replaced"?** Now there are 2 active devices in the system for the same patient. Probably: discontinue the old recovered one, keep the new one. Confirm in pilot.

## Changelog
| Date | Author | Change |
|------|--------|--------|
| 2026-04-17 | Jace + Claude | Initial spec |

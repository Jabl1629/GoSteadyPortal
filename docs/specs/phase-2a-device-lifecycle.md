# Phase 2A-DL — Device Lifecycle (operational subset)

## Overview
- **Phase**: 2A-DL (Device Lifecycle subset of Phase 2A)
- **Status**: ✅ Deployed (dev) 2026-05-17 — synthetic smoke validated; physical-device end-to-end checkpoint next
- **Branch**: feature/infra-scaffold (matched existing project pattern)
- **Date Started**: 2026-05-17
- **Date Completed**: 2026-05-17 (dev; physical-device verification at firmware checkpoint)

Implements the device-lifecycle workflows that govern how physical walker caps
are provisioned to patients, transitioned through their operational states, and
eventually decommissioned. Delivers the API endpoints, Lambda handlers, and
portal UI flows for: provisioning by serial, ending an assignment, marking
devices lost/broken/retired, force-resetting stuck devices, recovering lost
devices, and cross-facility / cross-client ownership moves. Pairs with the
state machine + invariants defined in [`ARCHITECTURE.md`](ARCHITECTURE.md) §4
(Device Lifecycle subsection) and the locked-in requirements DL1–DL11.

This is the first **operational** subset of Phase 2A. Other 2A subsets (patient
reads `2A-RD`, alert actions `2A-AA`, user management + household onboarding
`2A-UM`, internal tools `2A-INT`) land in companion specs and share the same
API Gateway, JWT authorizer, audit middleware, and tenant-enforcement helpers
that come from [`phase-2a-foundation.md`](phase-2a-foundation.md) (`2A-0`).

**Dependency on 2A-0 (foundation):** 2A-DL assumes the API Gateway HTTP API,
WAF, JWT authorizer with both Portal-Customer and Portal-Internal audiences,
error envelope, audit middleware, and tenant-enforcement helper are already
deployed. `2A-0` must ship before this spec's implementation starts.

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
| L12 | Customer tenancy boundary enforced via 2A-0's `enforce_tenancy(claims, target_client_id)` helper called inside every handler. Internal roles (`internal_*`) bypass | Architecture T2 + Phase 2A-0 L5 | The hard security boundary; centralized helper prevents per-handler drift |
| L13 | Every transition emits an audit event via the 2A-0 `audit_middleware` decorator + `_shared/audit_catalog.py` constants | Architecture §4, §10 + Phase 1.7 (deployed 2026-05-17) | Decorator enforces consistency at infrastructure level; catalog constants catch typos at handler-write time |
| L14 | Activation cmd publish is atomic with provision: if `iot:Publish` fails, the DDB writes (Device Registry status + DeviceAssignments row) are rolled back. API returns 500. Provision is idempotent so retry is safe | This spec — Open Question Q4 decision 2026-05-17 | Avoids "device shows provisioned in DB but never gets activated" zombie state. Retry-safe per the same `cmd_id` window (DL14a / 24h) |
| L15 | Cross-facility / cross-client move is rejected (409) on devices in `active_monitoring` state. Caller must `end-assignment` first, then move | This spec — Open Question Q5 decision 2026-05-17 | Forces a deliberate two-step instead of hiding side effects (cascading end-assignment + ownership change) inside a single move operation |
| L16 | "Stuck in `provisioned` >24 h post-activation-send" ops alarm ships as part of 2A-DL via a CloudWatch Logs metric filter on `device.activation_sent` events vs. `device.activated` events | This spec — Open Question Q6 decision 2026-05-17 | The firmware-ack codepath is the most fragile new surface in 2A-DL (multi-hop: API → IoT publish → device receive → device persist → device echo → cloud heartbeat handler). Shipping the alarm with the feature avoids running it blind |

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
| `POST` | `/devices/{serial}/provision` | Assign to patient (transitions `ready_to_provision` → `provisioned`; claims ownership if first time; **publishes `activate` command to `gs/{serial}/cmd`** for firmware to exit pre-activation sleep) | caregiver (scope), facility_admin (facility), client_admin (client), household_owner (own), internal_admin |
| `POST` | `/devices/{serial}/end-assignment` | End current assignment (transitions to `discontinued`) | same as provision |
| `POST` | `/devices/{serial}/decommission` | Mark `decommissioned` with reason (lost/broken/retired/end_of_life) | reason-dependent: `lost`/`broken` allowed for caregiver+; `retired`/`end_of_life` requires facility_admin+ |
| `POST` | `/devices/{serial}/recover` | Reactivate from `decommissioned (lost)` to `ready_to_provision` | facility_admin (facility), client_admin (client), household_owner (own), internal_admin |
| `POST` | `/devices/{serial}/force-reset` | Admin override for stuck `discontinued` device | facility_admin+, internal_admin |
| `POST` | `/devices/{serial}/move-facility` | Transfer `owningFacilityId` within same client | client_admin, internal_admin |
| `POST` | `/devices/{serial}/move-client` | Transfer `owningClientId` (rare) | internal_admin only; elevated audit |
| `POST` | `/admin/devices` (internal) | Manufacturer-side bulk creation of new Device Registry records (no owner) | internal_admin only |

#### Activation message publish (atomic with provision per L14)

After a successful provision, the handler performs **three writes in order, with rollback on the publish failure**:

1. Conditional `PutItem` on Device Registry: `status = provisioned`, set `owningClientId`/`owningFacilityId` if first-provision. Conditional check guards against the concurrent-provision race (two caregivers typing the same serial within milliseconds — the second loses the race and gets a 409 with a clear "device just provisioned by another user — refresh" message).
2. `PutItem` on DeviceAssignments: new assignment row with `validFrom = now`, `validUntil = null`, hierarchy snapshot at write time.
3. `iot:Publish` to `gs/{serial}/cmd` with `{cmd: "activate", cmd_id: <fresh UUID>, ts: <now>}`. Also writes the `cmd_id` to Device Registry's `outstandingActivationCmds` map for the 24h ack-matching window (per DL14a).

If step 3 fails (IoT throttling, transient network error to AWS IoT):
- **Reverse steps 1 and 2** — delete the DeviceAssignments row, revert Device Registry status to `ready_to_provision` and clear `owningClientId`/`owningFacilityId` if first-provision.
- Return 500 to the caller with `code: "PROVISION_FAILED"` and a retry-safe response.
- Emit `device.provision_rollback` audit event with the failure reason.

Failure modes:
- IoT publish fails → rollback (per L14); API returns 500; caller retries; idempotent because the rolled-back state is back to `ready_to_provision`.
- Activation command lost in flight (cellular outage post-publish) → device stays in pre-activation sleep until next provision retry, which republishes a fresh `cmd_id`. The original `cmd_id` remains in `outstandingActivationCmds` for 24h so a late ack (cellular returns within window) still resolves correctly (DL14a).
- Firmware never echoes `last_cmd_id` (firmware bug, or device permanently offline) → cloud's `Device Registry.activated_at` stays NULL; Threshold Detector continues to suppress synthetic alerts (correct behavior — the device hasn't actually started monitoring). **L16 ops alarm fires** at +24h post-`device.activation_sent`: CloudWatch Logs metric filter counts `device.activation_sent` events without a matching `device.activated` event in 24h.

#### Discharge cascade hook
- Listener on Patients table updates (DDB Streams or direct invocation from API handler that flips patient status)
- Iterates active DeviceAssignments for that patient
- Calls `end-assignment` for each → produces `device.assignment_ended` audit events with `reason: patient_discharged`

#### Firmware-driven reset handler
- IoT topic / Shadow update from device firmware indicating reset complete
- Validates: device is in `discontinued` state (or `provisioned` for unactivated devices being reset)
- Transitions Device Registry status → `ready_to_provision`
- Clears the active DeviceAssignment row's `validUntil` if not already set
- Clears `Shadow.desired.activated_at` per DL14 invariant (Shadow `desired.activated_at` is non-null iff status ∈ {provisioned, active_monitoring})
- Emits `device.reset_complete` audit event
- Does NOT clear `owningClientId` / `owningFacilityId` (ownership persists through reset — DL4)
- Does NOT publish anything to the device (firmware initiated; no command needed)

#### Force-reset side effects

Force-reset (`POST /devices/{serial}/force-reset`, facility_admin+) is for stuck devices that fail to report `reset_complete` on the charger. Behavior:
- Transitions Device Registry status `discontinued → ready_to_provision` regardless of any `reset_complete` ack from the device
- Closes any open DeviceAssignment row's `validUntil` (defensive — usually already closed)
- Clears `Shadow.desired.activated_at` per DL14 invariant
- **Does NOT publish anything to the device.** If the device were responsive, a normal reset on charger would have worked. Publishing a "force-yourself-reset" command is a Phase 5A firmware capability that doesn't exist yet
- Emits `device.force_reset` audit event with `reason: <free-text from caller>` (required) and `internal_access: true` if invoked by `internal_admin`

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
- All endpoints automatically emit via the 2A-0 `audit_middleware` decorator wrapping each handler
- Event names from `_shared/audit_catalog.py` constants (e.g., `AUDIT_DEVICE_CLAIMED`, `AUDIT_DEVICE_ASSIGNED`) — typos caught at handler-write time
- `actor` derived from JWT claims (Pre-Token Lambda injects `userId`, `role`, `clientId`)
- `subject` includes `{serialNumber, patientId, clientId, facilityId, censusId}` for state-changing events
- `internal_access: true` + `severity: elevated` auto-stamped by audit-forwarder Lambda (Phase 1.7 D8) when `actor.role` starts with `internal_`
- `schema_version: 1` field on every event (Phase 1.7 L9)
- New events added to `_shared/audit_catalog.py` for 2A-DL: `device.provision_rollback` (L14 rollback path), `device.stuck_in_provisioned` (L16 alarm-emitted, not handler-emitted)

#### Tenancy + scope enforcement (per L12 + 2A-0 helpers)

Every handler calls `enforce_tenancy(claims, target_client_id)` from `_shared/api_authz.py` before any data-changing operation. For paths that don't carry `clientId` directly (e.g., `POST /devices/{serial}/provision`), the handler first does a Device Registry GetItem to discover `owningClientId`, then enforces.

Scope enforcement for caregiver/facility_admin (facility/census claims) uses the helper `enforce_scope(claims, target_facility_id, target_census_id)` — also from 2A-0. Returns 403 `OUT_OF_SCOPE` if claims don't cover the target.

Internal-tier roles (`internal_support` read-only, `internal_admin` read+write) bypass `enforce_tenancy` but every action still emits an audit event tagged at elevated severity (L8 of 1.7 spec).

### Out of Scope (Deferred)

- **QR code scanning for serial entry** — Phase 2B if pilot data shows typing error rates >5%
- **Refurbishment workflow** for `decommissioned (broken)` devices — Phase 2B+ if/when broken volume justifies a repair pipeline
- **Bulk device move UI** — admins move one at a time in MVP
- **Device "swap" UX** (one click to swap dead device with new one) — derived from existing primitives in Phase 2B
- **Patient management UI** (admit, discharge, transfer between censuses) — Phase 2A-UM (user management subset)
- **Household onboarding flows** — Phase 2A-UM; the 3 patterns from ARCHITECTURE.md §4 (co-located / caregiver-initiated / walker-initiated) are UM concerns, not device-management concerns
- **Patient read endpoints** (GET /patients/{id}, /activity, /alerts) — Phase 2A-RD
- **Alert acknowledgement** (`PATCH /alerts/{patientId}/{timestamp}`) and **threshold overrides** — Phase 2A-AA
- **Profile / notification preferences UI** — Phase 2A-UM
- **Real-time device status push** to portal (live signal/battery view) — Phase 2B (2A polls)
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
| T1 | Provision new device by serial (case c) — first-provision claims ownership + publishes activation cmd | API call as caregiver | 200; device status=provisioned, ownership set, assignment row created, IoT message published to `gs/{serial}/cmd`, audit events `device.claimed`+`device.assigned`+`device.activation_sent` | Pending |
| T1b | Activation acknowledgement | Heartbeat with matching `last_cmd_id` | `Device Registry.activated_at` set; audit event `device.activated`; threshold suppression released | Pending |
| T1c | Pre-activation heartbeat suppression | Heartbeat from device where `activated_at` is NULL with `battery_pct=0.03` | No `battery_critical` alert generated; audit event `device.preactivation_heartbeat` (sampled to 1/hr) | Pending |
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
| T26 | Provision rollback on IoT publish failure (L14) | Temporarily revoke `iot:Publish` IAM grant; provision via API | 500 `PROVISION_FAILED`; Device Registry status reverted to `ready_to_provision`; no DeviceAssignments row left behind; `device.provision_rollback` audit event emitted | Pending |
| T27 | Concurrent provision race (Open Q "Concurrent provision race") | Two API calls in <100ms with same serial | First: 200 success. Second: 409 with clear "device just provisioned by another user — refresh" message via the conditional PutItem rejection. | Pending |
| T28 | Cross-facility move on `active_monitoring` device is rejected (L15) | API call by client_admin against an active-monitoring device | 409 `INVALID_TRANSITION` with details indicating end-assignment required first | Pending |
| T29 | Cross-facility move on `discontinued` device succeeds (L15 inverse) | After T28 + end-assignment, re-attempt move | 200; `owningFacilityId` updated; state stays `discontinued`; `device.ownership_moved` audit | Pending |
| T30 | "Stuck in provisioned >24h" ops alarm fires (L16) | Synthetic: provision a device, simulate no heartbeat for 24h+ (or shorten the alarm window in dev for testing) | Alarm transitions to ALARM; SNS message lands at ops topic | Pending — synthetic; full validation in M14.5 / M15 |
| T31 | DL14 invariant maintained on force-reset | Run T12 (force-reset); inspect Shadow `desired.activated_at` | Field is null after force-reset (cleared per the L14 invariant) | Pending |
| T32 | DL14 invariant maintained on patient discharge cascade | Trigger T14; inspect Shadow `desired.activated_at` for each device the cascade touches | Field is null after each cascade-driven end-assignment | Pending |

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
| D12 | Provision is atomic with activation cmd publish — rollback on IoT failure (L14) | Best-effort (return 200 even if publish failed; eventual consistency); SQS-buffered publish (durable but adds 1-2s latency) | Rollback keeps the data model honest: if status is `provisioned`, the device WAS told to activate. Idempotent retry makes the failure mode recoverable. SQS-buffered would mean the data model can show "provisioned" while the cmd is still queued — confusing for ops. |
| D13 | Cross-facility / cross-client move rejects `active_monitoring` devices (L15) | Auto-cascade end-assignment as side effect of move; allow move and let downstream handlers cope | Cascading inside a single move operation is surprising — caregivers in the destination facility would suddenly see a new device assigned to a patient they don't recognize. Explicit two-step makes the destination facility see the device as `discontinued + new owner`, which they then provision normally. Matches the discharge-cascade pattern (D3) of preferring explicit transitions |
| D14 | "Stuck in provisioned >24h" alarm via CloudWatch Logs metric filter (L16) | EventBridge scheduled scan; per-device CloudWatch metric | Logs metric filter is dead-simple: count `device.activation_sent` events without a matching `device.activated` within 24h. No new Lambda, no DDB scan. Filter alarms via existing 1.6 alarm catalog pattern. EventBridge-based scan would be more flexible but adds a Lambda for a one-purpose job |
| D15 | Reuse 2A-0's `audit_middleware` decorator rather than per-handler `emit_audit()` calls | Per-handler explicit calls with `emit_audit(event=AUDIT_DEVICE_CLAIMED, ...)` | Middleware enforces consistency (every handler audited, no drift). Per-handler is more flexible (different events per code path) but easier to forget. For 2A-DL where every endpoint corresponds 1:1 with a single event type, middleware is the right level. Per-handler `emit_audit()` is still available for non-standard cases (e.g., the rollback event in L14 needs explicit emission from inside the rollback branch) |

## Open Questions

- [x] **Concurrent provision race**: ~~two caregivers type the same serial within milliseconds. The conditional PutItem on Device Registry status will reject the second; what's the user experience?~~ **Resolved 2026-05-17: T27 covers it.** Conditional PutItem on `status = ready_to_provision` rejects the second caller; handler catches `ConditionalCheckFailedException` and returns 409 with error code `DEVICE_UNAVAILABLE` and message "device just provisioned by another user — refresh." UI surfaces the message verbatim.
- [x] **Provision-time IoT publish failure handling**: ~~no spec~~ **Resolved 2026-05-17 in L14 + D12.** Atomic rollback — undo DDB writes if publish fails, return 500 `PROVISION_FAILED`. Retry is idempotent because the rolled-back state is back to `ready_to_provision`. T26 covers it.
- [x] **Cross-facility / cross-client move on `active_monitoring` device**: ~~spec was silent~~ **Resolved 2026-05-17 in L15 + D13.** Reject with 409 + clear "end assignment first" message. T28/T29 cover both branches.
- [x] **"Stuck in provisioned >24h" ops alarm**: ~~mentioned but not specced~~ **Resolved 2026-05-17 in L16 + D14.** Ships as CloudWatch Logs metric filter in 2A-DL, not deferred. T30 covers it (synthetic; full validation in M14.5 / M15).
- [x] **Force-reset for devices that have NEVER successfully transitioned to active_monitoring**: ~~should this be a different transition?~~ **Resolved 2026-05-17.** Same `force_reset` — it's still admin-overriding a stuck state. Force-reset spec covers both `discontinued → ready_to_provision` and `provisioned → ready_to_provision` (the latter when a device was provisioned but never heard from).
- [ ] **Device assigned to discharged patient hangs around as `active_monitoring`** if discharge-cascade Lambda fails: do we need a periodic reconciliation job? Lean: yes, daily sweep in Phase 1C. Defer.
- [ ] **Audit retention for high-frequency events** like `device.first_heartbeat`: 6 years feels excessive for non-PHI device events. Per-event-type retention policy? Defer to Phase 1.7.1.
- [ ] **D2C household_owner trying to provision a device that's already owned by a facility client** (e.g., they bought it on eBay): clear error message? Refer to support? Lean: error explaining device is enterprise-owned; support can transfer if legitimate. Defer to 2A-UM (where household onboarding lives).
- [ ] **Patient transferred between censuses while device is assigned**: device assignment carries forward (caregiver in new census now sees it). Audit event for the patient transfer covers it; no separate device event. Confirm in 2A-UM when patient management ships.
- [ ] **What's the UX for "found a lost device that was already replaced"?** Now there are 2 active devices in the system for the same patient. Probably: discontinue the old recovered one, keep the new one. Confirm in pilot — not a code question until then.
- [ ] **Subscription-filter list maintenance** (per 2A-0 Q5): an aspect-based approach (any Lambda tagged `audit:capture=true` automatically gets a filter) would prevent future "forgot to add the log group" gaps. Worth specing as part of 2A-DL or splitting into a small follow-up. Lean: defer the aspect to 2A-RD when we add the 4th set of Lambdas — until then, the explicit list is manageable.

## Changelog
| Date | Author | Change |
|------|--------|--------|
| 2026-04-17 | Jace + Claude | Initial spec |
| 2026-05-17 | Jace + Claude (cloud session) | **Spec revision** to close 10 gaps identified during the 2A subset planning review (post-1.7-deploy). Added L14 (atomic provision-rollback on IoT publish failure), L15 (cross-facility-move reject on `active_monitoring`), L16 (stuck-in-provisioned alarm ships with 2A-DL). Updated activation-message-publish section to describe the 3-step write + rollback path. Updated firmware-driven reset handler + new force-reset side-effects section to maintain the DL14 Shadow `desired.activated_at` invariant on every state-changing transition. Replaced loose "per §10 audit log infra" reference with explicit ties to the deployed Phase 1.7 helpers (`_shared/observability.py:emit_audit`, `_shared/audit_catalog.py` constants, `audit_middleware` decorator from 2A-0). Added tenancy + scope enforcement subsection naming the 2A-0 helpers explicitly. Added explicit 2A-0 dependency at the top. Split deferred items into the right 2A subsets (2A-RD/AA/UM/INT). Added D12–D15 to the Decisions Log capturing the new locked-ins. Added T26–T32 covering rollback / concurrent-race / move-rejection / alarm / Shadow invariant. Resolved 5 of the original 7 Open Questions with cross-references to where they're now answered |
| 2026-05-17 | Jace + Claude (cloud session, same day) | **Deployed to dev** (commit `1edcac5`). 3 Lambdas (device-api / discharge-cascade / device-shadow-handler) + 10 HTTP API routes + IoT Topic Rule + DDB Stream event source + L16 metric-math alarm. **4 bugs caught at smoke**: (1) `--exclusively` flag suppressed Data dependency on first deploy attempt (same lesson as 2A-0); (2) Powertools Logger reserves `message` key in `extra=` dict → renamed to `error_message`; (3) DDB `Invalid UpdateExpression: paths overlap` on `outstandingActivationCmds` SET + nested-path SET in same expression → split provision step 1 into two UpdateItem calls; (4) `boto3.client("iot").update_thing_shadow` doesn't exist — `update_thing_shadow` lives on the DATA-PLANE client `iot-data`, not control-plane `iot`. Fixed all 3 Lambdas. **Synthetic smoke validates 6 paths end-to-end**: T2 unknown-serial → 404 DEVICE_NOT_FOUND; T1 provision happy → 200 with full response (device + assignment + activation.cmdId + ackWindowHours: 24); T27 concurrent provision race → 409 DEVICE_UNAVAILABLE with "device just provisioned by another user — refresh" message; T6 end-assignment → 200 status=discontinued; T9 caregiver decommission (reason=lost) → 200; T22-ish caregiver-attempts-recover → 403 INSUFFICIENT_PERMISSIONS with details.requiredAnyOf array. **Full audit trail**: all 5 device.* events landed in gosteady-dev-audit log group (claimed, assigned, activation_sent, assignment_ended, decommissioned) with schema_version: 1, auto-stamped internal_access + severity, shared xray_trace_id within a single request. Shadow state shows `desired.activated_at` correctly cleared after decommission (DL14 invariant). **NOT yet validated** (deferred to physical-device test): T1b activation acknowledgement on real heartbeat, T5 first-heartbeat → active_monitoring transition, T15 firmware reset_complete → discontinued → ready transition, T26 provision rollback (would need to force IoT publish failure), T14 patient discharge cascade. **Next: physical-device end-to-end** — provision bench unit through API, verify activate cmd lands on device, watch heartbeat ack close the loop |

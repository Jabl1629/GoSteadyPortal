# Phase 2A-UM-P — Patient Management (Patient mutations subset)

## Overview
- **Phase**: 2A-UM-P (Patient Management — a focused subset of the broader 2A-UM umbrella)
- **Status**: 🔲 Planned
- **Branch**: TBD (likely a sub-branch of `feature/infra-scaffold`)
- **Date Started**: TBD
- **Date Completed**: TBD

Ships the six patient-state mutation endpoints that gate Phase [2B-FAC-W](phase-2b-portal-integration.md#2b-fac-w-facility-writes--detailed-scope). Add Resident / Edit Resident / Discharge Resident / Pause Notifications / Resume Notifications / Care Note. Plus the supporting Patients-row schema additions (`careNote` map, `notificationsPaused` map), the Threshold Detector / behavioral-detector "skip if paused" check, and the Activity Processor "auto-resume on activity" behavior.

This is the **first** of the 2A-UM umbrella subsets. The broader 2A-UM still owns:
- **2A-UM-H** (Household / D2C onboarding endpoint — `POST /admin/household`, called from the marketing site or internal bootstrap script). Deferred to follow-up; not blocking 2B
- **2A-UM-S** (Staff user creation — `POST /admin/users` + Cognito invite flow). Deferred to V2 / 2A-INT; V1 facility users are created by the internal seed script

This subset is the **only one V1 blocking** — without it, 2B-FAC-W can ship alert-ack (2A-AA) and device-action (2A-DL) writes but cannot ship Add/Edit/Discharge/Pause/Care-Note. Per user-needs §4.5 + US-44, those five are core caregiver workflows.

**Dependency on 2A-0 (foundation):** `extract_claims`, `enforce_tenancy`, `enforce_scope`, `audit_middleware`, error envelope. All deployed 2026-05-17.

**Dependency on 2A-RD (helper consumed):** `enforce_patient_access(claims, patient)` helper — single-patient auth chain that handles family_viewer / caregiver / facility_admin / internal differentiation. Already in `_shared/api_authz.py` per 2A-RD D10.

**Dependency on 2A-DL (discharge cascade):** the `discharge-cascade` Lambda is already wired to react to Patient status flips via DDB Streams (or direct invocation). 2A-UM-P's `POST /patients/{id}/discharge` simply transitions `Patient.status → discharged`; the cascade fires the device end-assignment + wipe chain per 2A-DL §C-discharge.

**Dependency on 1B-rev (Threshold Detector + Activity Processor):** both pick up pause-aware behavior. Bundled redeploys in this phase.

## Locked-In Requirements

| # | Requirement | Decided In | Rationale |
|---|-------------|-----------|-----------|
| L1 | Six endpoints in this subset (full table below). Single Lambda `gosteady-{env}-patient-mgmt` for all routes (mirrors 2A-DL D1 / 2A-RD D1 / 2A-AA L10) | This spec | Cold-start economics; shared auth/audit/validation code |
| L2 | New Patients-row attributes — both are DDB map-typed sibling attributes, schemaless adds (no migration): `careNote = {text, updatedBy, updatedAt}` and `notificationsPaused = {until, reason, pausedAt, pausedBy}`. Absence = "no value set" (default behavior) | This spec | Patients table reads already happen on every Threshold Detector shadow update + every 2A-RD `GET /patients/{id}`; sibling-attribute pattern keeps everything in one GetItem |
| L3 | Add Resident: `POST /patients` body `{displayName, censusId, room, deviceSerial?}`. **Server orchestrates** the create-patient + provision-device chain atomically when `deviceSerial` is present. Rollback (delete the new Patient row) if provision-device fails. Mirrors 2A-DL L14 pattern | This spec — Q1 (from 2B Q4 user lean) | One server-side transaction is cleaner than client-side coordination; matches the existing 2A-DL provision-atomic-with-IoT-publish pattern. Failure modes are well-bounded |
| L4 | Edit Resident: `PATCH /patients/{id}` body `{displayName?, censusId?, room?}`. Partial updates allowed. Cross-facility transfer happens implicitly when `censusId` points to a census in a different facility — server resolves the new `facilityId` from `censusId` lookup, updates the Patient row's `facilityId` denorm at the same time. Single-call semantic per user-needs US-30 | user-needs US-29 + US-30 | "No separate transfer action" per user-needs §4.5; `censusId` is the actual user-facing input |
| L5 | Discharge Resident: `POST /patients/{id}/discharge` body `{reason, notes?}`. Server: (a) sets `Patient.status = discharged`, `dischargedAt`, `dischargeReason`, `dischargeNotes`. (b) DDB Streams trigger on Patients table updates fan out to the existing 2A-DL `discharge-cascade` Lambda. (c) 7-day soft-undo window — actual archival happens via Phase 1C lifecycle Lambda; pre-undo restore is an internal-admin-only endpoint not in 2A-UM-P scope | user-needs US-32 + §7 #11 | Single-call discharge per user-needs §7 #5 ("auto-releases the device"); cascade was specced + deployed in 2A-DL |
| L6 | Pause Notifications: `POST /patients/{id}/notifications/pause` body `{days, reason}`. `days ∈ [1, 90]`. `reason ∈ {in_hospital, at_rehab, family_visit_offsite, on_vacation, other}`. **Auto-resume on activity** (per user-needs US-31): Activity Processor (Phase 1B-rev, redeployed in this phase) checks if patient is currently paused on every PutItem to Activity Series; if paused, clears the pause and emits `patient.notifications.resume_auto` audit | user-needs US-31 + §7 #3 | Demo had this as a session-only "pause monitoring"; user-needs rename + auto-resume + visible countdown in §7 #3 |
| L7 | Manual unpause: `DELETE /patients/{id}/notifications/pause`. Emits `patient.notifications.resume_manual` audit | user-needs US-31 | Caregiver can resume early |
| L8 | Care Note: `PATCH /patients/{id}/care-note` body `{text}`. `text` length ∈ [0, 280]. Empty string clears the note. Persisted as `Patient.careNote = {text, updatedBy: claims.userId, updatedAt: now}`. **GET extension:** 2A-RD's existing `GET /patients/{id}` response gains a top-level `careNote` field (null when unset) — no new read endpoint | user-needs US-44 | Single overwriteable block per US-44; attribution + timestamp; lives between header and notification panel |
| L9 | Threshold Detector + behavioral detector skip evaluation when `Patient.notificationsPaused.until > now`. Mirrors the existing pre-activation suppression pattern (Phase 1B-rev). Generates a `device.notifications.suppressed_paused` audit event sampled at ≤1/day/patient to avoid log spam | This spec | Honors the user-facing semantic ("paused" = no new notifications); audit trail proves we honored the pause |
| L10 | Activity Processor auto-resume: on every successful Activity Series PutItem, check `Patient.notificationsPaused` — if present AND `Patient.notificationsPaused.until > now`, clear it via `UpdateItem REMOVE notificationsPaused`, emit `patient.notifications.resume_auto` audit | user-needs US-31 ("auto-resumes early if activity data starts streaming again") | "The reason for pausing is gone" semantics per user-needs |
| L11 | RBAC: V1 user-needs is single-role ("Care Staff" = caregiver+ scope). All endpoints in this subset accept `caregiver` / `facility_admin` / `client_admin` / `household_owner` / `internal_admin`. **Family_viewer and internal_support cannot write** (observational + read-only) | user-needs §7 #1 + Appendix B | Same RBAC pattern as 2A-AA L5 |
| L12 | Audit event catalog additions (per Phase 1.7 L9 schema_version=1, audit-forwarder auto-stamps elevated severity for internal_*): | Phase 1.7 + this spec | Compliance reader needs the full set |
| | `patient.created` (US-28) | | |
| | `patient.update` (US-29 + US-30 cross-facility transfer) | | |
| | `patient.discharge` (US-32) | | |
| | `patient.notifications.pause` (US-31) | | |
| | `patient.notifications.resume_manual` (US-31 manual unpause) | | |
| | `patient.notifications.resume_auto` (US-31 activity-triggered) | | |
| | `patient.notifications.suppressed_paused` (L9 — detector sampled at ≤1/day/patient) | | |
| | `patient.care_note.update` (US-44) | | |
| L13 | URL-path patient ID is the canonical key; tenancy resolved via Patient.clientId after GetItem. Identical pattern to 2A-RD `enforce_patient_access` | 2A-0 L5 + 2A-RD D10 | Single auth-chain helper, no per-handler drift |
| L14 | Single audit `before` / `after` pattern on all updates: PATCH endpoints emit the full pre-state and post-state. Mirrors 2A-AA L8 for threshold updates | 2A-AA L8 + Phase 1.7 L8 | Compliance reader can reconstruct historical state at any point T |
| L15 | Audit-stack subscription filter for `patient-mgmt` log group bundled into 2A-UM-P deploy (Migration Pattern 18.8) | 2A-0 D9 precedent | Established pattern |

## Assumptions

| # | Assumption | Risk if Wrong | Validation Plan |
|---|-----------|---------------|-----------------|
| A1 | DDB Streams on the Patients table are enabled (Phase 0B-rev sets `NEW_AND_OLD_IMAGES` per spec L7 — used by discharge-cascade already) | Discharge cascade silently fails | Validated by 2A-DL deploy. Smoke: bench-discharge a patient and confirm cascade fires per 2A-DL §C18 / §C21 |
| A2 | Adding `careNote` + `notificationsPaused` to existing Patient rows is a schemaless add — no PutItem rewrite, just an UpdateItem `SET` on each future write | Existing rows function unchanged | DDB Patients schema is intentionally sparse per Phase 0B-rev; this is a natural extension |
| A3 | The Activity Processor's per-PutItem auto-resume check (L10) doesn't materially affect throughput. Already does Patient.GetItem on every event (for hierarchy snapshot per 1B-rev D-snapshot); adding pause-attribute read is sibling-attribute, no extra round-trip | Latency budget regression | Confirmed by inspection of 1B-rev handler. X-Ray traces post-deploy will validate |
| A4 | Cross-facility transfer (changing `censusId` to a census in a different facility) doesn't require the caller to have facility-write-access in BOTH the source and target facility for V1 — only the source. The user-needs spec is silent on this; matches the demo's `_EditInfoForm` behavior (the unit dropdown spans all facilities the user can see) | If V1 requires source+target authz, cross-facility transfer becomes 403 in some legitimate cases | Cross-facility = `client_admin+` per phase-0a-revision capability matrix. For caregiver/facility_admin trying to move across facilities they don't own: 403 with explicit "Cross-facility transfer requires client_admin role" copy. **Open question — see Q3** |
| A5 | The 7-day soft-undo for discharge happens via a Phase 1C lifecycle Lambda that archives discharged patients after 7 days. **That Lambda doesn't exist yet** — for V1, soft-undo is "discharged patients stay queryable indefinitely; archival is a manual ops task." | Discharged patients clutter list endpoints | Per 2A-RD's queries: list endpoints filter on `status=active` by default; discharged patients don't appear in `/me/patients`. The "after-7-days archival" is a Phase 1C-slim follow-up, not a 2A-UM-P blocker |
| A6 | Auto-resume on activity uses "any activity event" as the signal (not "non-trivial activity" with a threshold). Per user-needs: "the reason for pausing is gone" implies even a 10-step session counts | If a stray test session triggers premature auto-resume during a real hospital stay, caregiver is surprised | Tunable via config (`autoResumeMinSteps: 0` default). If false-resume becomes a complaint, raise the threshold |

## Scope

### In Scope

#### Endpoint contracts

**`POST /api/v1/patients`** — create + optionally atomic-provision

```jsonc
// Request body:
{
  "displayName": "Margaret O'Sullivan",
  "censusId": "cen_ws_memory",
  "room": "12A",
  "deviceSerial": "GS0000000123"   // optional; if present, atomic provision
}

// Response 201 (created):
{
  "patient": {
    "patientId": "pat_2026_05_24_abc",
    "displayName": "Margaret O'Sullivan",
    "status": "active",
    "timezone": "America/Los_Angeles",
    "clientId": "client_005",
    "facilityId": "fac_whitestone",
    "facilityName": "Whitestone Senior Living",
    "censusId": "cen_ws_memory",
    "censusName": "Memory Care",
    "room": "12A",
    "careNote": null,
    "notificationsPaused": null,
    "currentDevice": {
      "serialNumber": "GS0000000123",
      "status": "provisioned",
      "lastSeen": null
    },
    "createdAt": "2026-05-24T10:32:11Z"
  },
  "device": {
    "serialNumber": "GS0000000123",
    "activationCmdId": "act_<uuid>",
    "status": "provisioned"
  }
}
```

When `deviceSerial` is **absent**: returns 201 with `currentDevice: null`. Patient added without a device — caregiver can assign later via existing 2A-DL `POST /devices/{serial}/provision`.

When `deviceSerial` is **present**: atomic chain (rollback on any step failure):
1. Patients.PutItem with conditional `attribute_not_exists(patientId)` (idempotency)
2. Resolve target census + facility (Organizations.GetItem)
3. Verify caller has scope over `censusId` via `enforce_scope`
4. Verify device is `ready_to_provision` via Device Registry.GetItem
5. Invoke existing 2A-DL `device-api.provision_device` logic (DeviceAssignments.PutItem + IoT publish + Shadow update) — server-side function call, not HTTP
6. On any step 2-5 failure: roll back Patient row created in step 1 via DeleteItem; return 500 with `provision_rollback: true`

Emits two audit events on success: `patient.created` + `device.assigned` (the latter comes from the 2A-DL provision path).

---

**`PATCH /api/v1/patients/{id}`** — edit name / room / cross-facility transfer

```jsonc
// Request body (any combination — at least one required):
{
  "displayName": "Margaret O'Sullivan-Reilly",
  "censusId": "cen_cc_rehab",      // cross-facility if target census is in different facility
  "room": "R-4"
}

// Response 200:
{
  "patient": {
    /* full updated patient detail per 2A-RD GET /patients/{id} shape */
    "facilityName": "Cedar Crossing Skilled Nursing",   // if facility changed
    "censusName": "Rehab Wing"
  },
  "changes": {
    "facilityChanged": true,           // explicit flag if cross-facility transfer happened
    "oldFacility": "fac_whitestone",
    "newFacility": "fac_cedar"
  }
}
```

Server-side authz:
- Caregiver / facility_admin: target census must be in their `custom:facilities` claim. If cross-facility, source AND target must both be in claim (see Q3)
- Client_admin: target census must be in their client (`custom:clientId`)
- Internal_admin: any (audited elevated)

Emits `patient.update` audit with `before` / `after` full snapshots.

---

**`POST /api/v1/patients/{id}/discharge`** — discharge with cascade

```jsonc
// Request body:
{
  "reason": "transferred",          // enum: transferred | moved_home | hospital_admission | deceased | other
  "notes": "Returned to family care in Oregon — daughter primary contact."  // optional
}

// Response 200:
{
  "patient": {
    "patientId": "pat_abc",
    "status": "discharged",
    "dischargedAt": "2026-05-24T11:00:00Z",
    "dischargeReason": "transferred",
    "dischargeNotes": "..."
  },
  "cascade": {
    "devicesEnded": 1,
    "deviceSerials": ["GS0000000123"],
    "wipeRequested": true
  }
}
```

Behavior:
1. Conditional UpdateItem on Patients: `status = discharged`, `dischargedAt`, `dischargeReason`, `dischargeNotes`, `dischargedBy = claims.userId`. Conditional check: `status = active` (else 409 `INVALID_STATE`).
2. DDB Streams on Patients table fan out the new image to the existing 2A-DL `discharge-cascade` Lambda.
3. discharge-cascade enumerates active DeviceAssignments for `patientId`, calls `device-api.end_assignment` internally for each → wipe cmd published per 2A-DL L6.
4. The 2A-UM-P handler does NOT wait for cascade completion. Response returns immediately with `cascade.devicesEnded` count (read from active-assignment count *before* the stream fires). Cascade completion is async; auditable via `device.assignment_ended` + `device.wipe_requested` events per device.

Emits `patient.discharge` + (async, via cascade) `device.assignment_ended (reason: patient_discharged)` per device.

---

**`POST /api/v1/patients/{id}/notifications/pause`** — pause

```jsonc
// Request body:
{
  "days": 7,                         // ∈ [1, 90]
  "reason": "in_hospital"            // enum: in_hospital | at_rehab | family_visit_offsite | on_vacation | other
}

// Response 200:
{
  "notificationsPaused": {
    "until": "2026-05-31T11:00:00Z",
    "reason": "in_hospital",
    "pausedAt": "2026-05-24T11:00:00Z",
    "pausedBy": "userId-of-caregiver"
  }
}
```

Behavior:
1. Conditional UpdateItem on Patients: `notificationsPaused = {until: now + days*86400, reason, pausedAt: now, pausedBy: claims.userId}`. Conditional check: `status = active` (else 409). Overwrites any existing pause without error.
2. Emits `patient.notifications.pause` audit with full pause object + previous pause object (if any) for compliance trail.

---

**`DELETE /api/v1/patients/{id}/notifications/pause`** — manual unpause

```jsonc
// No request body
// Response 200:
{
  "notificationsPaused": null
}
```

Behavior:
1. Conditional UpdateItem on Patients: `REMOVE notificationsPaused`. Conditional check: `attribute_exists(notificationsPaused)` (else 409 `NOT_CURRENTLY_PAUSED`).
2. Emits `patient.notifications.resume_manual` audit.

---

**`PATCH /api/v1/patients/{id}/care-note`** — set / clear care note

```jsonc
// Request body:
{
  "text": "Back from hospital Feb 12 — slow start expected."   // string, len ∈ [0, 280]
}

// Response 200:
{
  "careNote": {
    "text": "Back from hospital Feb 12 — slow start expected.",
    "updatedBy": "userId-of-caregiver",
    "updatedByName": "J. Blackburn",   // resolved via Users.GetItem at write time, denormalized
    "updatedAt": "2026-05-24T11:00:00Z"
  }
}
```

Behavior:
1. Validate `text` length (≤280).
2. If `text` is empty string → UpdateItem `REMOVE careNote` (clears the note).
3. Else → UpdateItem `SET careNote = {text, updatedBy, updatedByName, updatedAt}`. Server resolves the actor's display name once at write time and denormalizes it into the row — avoids per-read Users.GetItem on the 2A-RD `/patients/{id}` path.
4. Emits `patient.care_note.update` audit with `before.text` / `after.text` (full text in both, per L14).

---

#### Threshold Detector + Behavioral Detector skip-when-paused logic (per L9)

Pattern in `infra/lambda/threshold-detector/handler.py` (Phase 1B-rev, redeployed):

```python
patient = patients_table.get_item(Key={"patientId": pid}).get("Item", {})
paused = patient.get("notificationsPaused")
if paused and paused.get("until", 0) > current_epoch:
    log_sampled_audit(
        "patient.notifications.suppressed_paused",
        sample_rate=ONCE_PER_DAY_PER_PATIENT,
        subject={"patientId": pid, "pausedUntil": paused["until"], "reason": paused["reason"]},
    )
    return  # skip threshold evaluation entirely
```

Same pattern in the new behavioral-detector Lambda (Phase 1C-slim — see [phase-1c-slim-notifications.md](phase-1c-slim-notifications.md)). The pause check is in a shared helper `_shared/pause_check.py` so both detectors stay consistent.

#### Activity Processor auto-resume (per L10)

Pattern in `infra/lambda/activity-processor/handler.py` (Phase 1B-rev, redeployed):

```python
# After Activity Series PutItem succeeds (existing code):
paused = patient.get("notificationsPaused")
if paused and paused.get("until", 0) > current_epoch:
    patients_table.update_item(
        Key={"patientId": pid},
        UpdateExpression="REMOVE notificationsPaused",
        ConditionExpression="attribute_exists(notificationsPaused)",
    )
    emit_audit("patient.notifications.resume_auto", subject={
        "patientId": pid,
        "triggeringActivity": {
            "sessionEnd": activity.session_end,
            "steps": activity.steps,
        },
        "pauseHadDaysRemaining": (paused["until"] - current_epoch) // 86400,
    })
```

Atomicity caveat: auto-resume + activity-PutItem aren't in a DDB transaction (different tables). Failure mode: activity is recorded but auto-resume fails → patient stays paused, no alert from this evaluation, but next activity event will retry. **Tolerable** because notifications are not real-time-critical per Phase 2B L12.

#### Error envelope (extends 2A-0 / 2A-RD / 2A-AA catalog)

| Code | HTTP | Meaning |
|------|------|---------|
| `INVALID_REQUEST` | 400 | Missing required fields; bad enum value; `displayName` empty; `days` out of range |
| `INVALID_DEVICE_SERIAL` | 400 | `deviceSerial` regex (`^GS\d{10}$`) failed |
| `CARE_NOTE_TOO_LONG` | 400 | `text` > 280 chars |
| `INVALID_STATE` | 409 | Discharge attempted on already-discharged patient; unpause attempted on non-paused patient; provision attempted with a non-`ready_to_provision` device |
| `DEVICE_NOT_AVAILABLE` | 409 | `deviceSerial` exists but is not in `ready_to_provision` state |
| `CENSUS_NOT_FOUND` | 404 | `censusId` doesn't exist |
| `PATIENT_NOT_FOUND` | 404 | Patient ID doesn't exist (or caller doesn't have permission — existence-leak prevention per 2A-RD D2) |
| `OUT_OF_SCOPE` | 403 | Caller's facility/census claims don't cover target |
| `TENANCY_VIOLATION` | 403 | Caller's client doesn't match target client (and caller isn't internal) |
| `INSUFFICIENT_PERMISSIONS` | 403 | Role not allowed on this route (e.g., family_viewer trying to discharge) |
| `PROVISION_FAILED` | 500 | Atomic provision chain failed mid-flight; Patient row rolled back |

#### RBAC matrix

| Endpoint | family_viewer | caregiver | facility_admin | client_admin | household_owner | internal_support | internal_admin |
|---|:-:|:-:|:-:|:-:|:-:|:-:|:-:|
| `POST /patients` | ❌ | ✓ scope | ✓ facility | ✓ client | ✓ own | ❌ | ✓ any |
| `PATCH /patients/{id}` (no facility change) | ❌ | ✓ scope | ✓ facility | ✓ client | ✓ own | ❌ | ✓ any |
| `PATCH /patients/{id}` (cross-facility) | ❌ | ❌ | ❌ | ✓ client | ❌ | ❌ | ✓ any |
| `POST /patients/{id}/discharge` | ❌ | ✓ scope | ✓ facility | ✓ client | ✓ own | ❌ | ✓ any |
| `POST /patients/{id}/notifications/pause` | ❌ | ✓ scope | ✓ facility | ✓ client | ✓ own | ❌ | ✓ any |
| `DELETE /patients/{id}/notifications/pause` | ❌ | ✓ scope | ✓ facility | ✓ client | ✓ own | ❌ | ✓ any |
| `PATCH /patients/{id}/care-note` | ❌ | ✓ scope | ✓ facility | ✓ client | ✓ own | ❌ | ✓ any |

### Out of Scope (Deferred)

- **Bulk operations** (bulk-add residents from CSV, bulk-discharge for facility decommission) — V2
- **Internal-only restore-from-discharge endpoint** (the 7-day soft-undo path per user-needs §7 #11) — needs internal-admin UI; lands in 2A-INT
- **Pre-discharge "device retrieval reminder" workflow** (cap staff that the physical walker needs to be collected from the room) — V2 / out of product MVP
- **Patient.timezone editing** — V1 inherits timezone from census; per-patient override is V2
- **Bulk care-note (apply note to multiple patients)** — out of product MVP
- **Notification preferences per patient** (which channels notify whom) — Phase 2C territory
- **2A-UM-H household onboarding** (`POST /admin/household` for D2C signup) — sibling spec, not in 2A-UM-P
- **2A-UM-S staff user management** (create / invite / suspend caregiver / facility_admin / client_admin accounts) — sibling spec; V2 or 2A-INT
- **Family-viewer invitation flow** — V3 per user-needs §7 #10
- **Care note history** (edit-feed beyond the current overwriteable value) — explicit non-goal per US-44 ("not a feed of past notes — keeps it from drifting into a parallel charting system")
- **Per-patient threshold overrides UI** — backend lives in 2A-AA (already deployed); UI deferred to V2 per user-needs §6

---

## Architecture

### Infrastructure Changes

Adds ~14 CFN resources to the existing `GoSteady-{Env}-Api` stack:

- 1 × `AWS::Lambda::Function` (`gosteady-{env}-patient-mgmt`)
- 1 × `AWS::IAM::Role` + 1 × `AWS::IAM::Policy` (read/write Patients; read DeviceAssignments / Device Registry / Organizations / Users; KMS Decrypt+GenerateDataKey on IdentityKey CMK; `iot:Publish` on `gs/{serial}/cmd` for the atomic-provision path; `iot:UpdateThingShadow` on `$aws/things/+/shadow/update`)
- 6 × `AWS::ApiGatewayV2::Route` + 6 × `AWS::ApiGatewayV2::Integration` + 6 × `AWS::Lambda::Permission`
- 1 × `AWS::CloudWatch::Alarm` (Lambda Errors > 0 in 5 min)
- 1 × `AWS::Logs::MetricFilter` + 1 × `AWS::CloudWatch::Alarm` (ERROR-pattern log filter)

To `GoSteady-{Env}-Audit`:
- 1 × `AWS::Logs::SubscriptionFilter` (audit-capture on patient-mgmt log group)
- 1 × `AWS::Lambda::Permission` (subscription filter → forwarder)

To `GoSteady-{Env}-Processing`:
- threshold-detector code redeploy (no new CFN; in-place Lambda code update) — adds pause-skip
- activity-processor code redeploy (no new CFN) — adds auto-resume

### Data Flow — atomic Add Resident (most complex)

```
Caregiver (Flutter)
    │ POST /api/v1/patients { displayName, censusId, room, deviceSerial }
    ▼
API Gateway HTTP API → JWT authorizer (2A-0) → patient-mgmt Lambda
    │
    ├── extract_claims, require_role(can_create)
    ├── validate body shape; validate deviceSerial regex
    ├── Organizations.GetItem(censusId) — verify exists, get parent facility
    ├── enforce_scope(claims, facilityId, censusId)
    ├── If deviceSerial present:
    │      Device Registry.GetItem(serial) — verify exists + status=ready_to_provision
    │      If not ready: 409 DEVICE_NOT_AVAILABLE
    ├── new_patient_id = generate_uuid()
    ├── Patients.PutItem (conditional: attribute_not_exists(patientId))
    │     status=active, displayName, censusId, facilityId, clientId,
    │     timezone (inherited from facility/client default), room
    ├── If deviceSerial present (atomic provision chain):
    │      Try:
    │        invoke_function: device-api.provision_device_internal(
    │          serial=deviceSerial, patientId=new_patient_id, claims=claims)
    │        # This is the existing 2A-DL Lambda's logic, called via
    │        # boto3 Lambda invoke for clean process boundary + IAM separation
    │      Catch:
    │        Patients.DeleteItem(patientId=new_patient_id)  # rollback
    │        emit_audit('patient.create_rollback', extra={'reason': exception})
    │        return 500 PROVISION_FAILED
    ├── emit_audit('patient.created', subject={patientId, clientId, ...})
    └── return 201 with full patient + device payload
```

### Data Flow — pause + auto-resume cycle

```
T+0  Caregiver pauses notifications for 7 days, reason=in_hospital
     │  POST /patients/{id}/notifications/pause {days:7, reason:in_hospital}
     ▼
     patient-mgmt: UpdateItem Patients SET notificationsPaused = {...}
     emit_audit('patient.notifications.pause')

T+1h Device heartbeat with battery_pct=0.03 → Threshold Detector fires
     │
     ▼
     Threshold Detector: Patients.GetItem
     paused.until > now → log sampled 'patient.notifications.suppressed_paused' (≤1/day)
     return without writing alert
     (Caregiver UI: no new alert appears; pause banner visible)

T+3d Activity arrives — patient walked 50 steps during hospital discharge
     │
     ▼
     Activity Processor: PutItem Activity Series (existing)
     Then: notificationsPaused.until > now → UpdateItem REMOVE notificationsPaused
     emit_audit('patient.notifications.resume_auto', triggeringActivity={...})
     (Caregiver UI: pause banner clears; future evaluations resume normally)
```

### Interfaces

#### Patients table schema additions

```jsonc
// Patients item — new attributes (sibling of existing displayName, status, clientId, facilityId, etc.):
{
  "patientId": "pat_abc",
  // ... existing attributes from Phase 0B-rev ...

  "careNote": {                              // OPTIONAL
    "text": "Back from hospital ...",
    "updatedBy": "userId",
    "updatedByName": "J. Blackburn",         // denormalized for read-path perf
    "updatedAt": "2026-05-24T11:00:00Z"
  },

  "notificationsPaused": {                   // OPTIONAL
    "until": 1748428800,                     // epoch seconds
    "reason": "in_hospital",
    "pausedAt": 1747824000,
    "pausedBy": "userId"
  },

  "status": "active" | "discharged",         // existing; "discharged" new in 2A-UM-P
  "dischargedAt": "2026-05-24T11:00:00Z",   // NEW; set on discharge
  "dischargeReason": "transferred",          // NEW
  "dischargeNotes": "...",                   // NEW; optional
  "dischargedBy": "userId"                   // NEW
}
```

#### `_shared/pause_check.py` (new helper)

```python
import time
from typing import Optional

def is_currently_paused(patient: dict) -> bool:
    """True if patient.notificationsPaused.until > now."""
    paused = patient.get("notificationsPaused")
    if not paused:
        return False
    until = int(paused.get("until", 0))
    return until > int(time.time())

def days_remaining(patient: dict) -> Optional[int]:
    """Days until pause expires, or None if not paused."""
    paused = patient.get("notificationsPaused")
    if not paused:
        return None
    until = int(paused.get("until", 0))
    remaining = max(0, until - int(time.time()))
    return remaining // 86400
```

#### Audit event shape — full `before` / `after` on PATCH

```jsonc
// patient.update audit event:
{
  "audit": true,
  "schema_version": 1,
  "event": "patient.update",
  "actor": {"userId": "...", "role": "caregiver", "clientId": "client_005"},
  "subject": {"patientId": "pat_abc"},
  "action": "update",
  "before": {
    "displayName": "Margaret O'Sullivan",
    "censusId": "cen_ws_memory",
    "facilityId": "fac_whitestone",
    "room": "12A"
  },
  "after": {
    "displayName": "Margaret O'Sullivan-Reilly",
    "censusId": "cen_cc_rehab",
    "facilityId": "fac_cedar",
    "room": "R-4"
  },
  "extra": {
    "fieldsChanged": ["displayName", "censusId", "facilityId", "room"],
    "crossFacilityTransfer": true
  },
  "request_id": "...",
  "xray_trace_id": "...",
  "internal_access": false,
  "severity": "info"
}
```

---

## Implementation

### Files Changed / Created

| File | Change Type | Description |
|------|------------|-------------|
| `infra/lambda/patient-mgmt/handler.py` | New | Route dispatch + per-route handlers |
| `infra/lambda/patient-mgmt/validation.py` | New | Pure-function body validators (display name, days, reason enum, care-note length, device serial regex) |
| `infra/lambda/patient-mgmt/requirements.txt` | New | Empty (Powertools from layer) |
| `infra/lambda/patient-mgmt/tests/test_validation.py` | New | Unit tests |
| `infra/lambda/patient-mgmt/tests/test_atomic_provision.py` | New | Mock-DDB tests for rollback path |
| `infra/lambda/_shared/pause_check.py` | New | `is_currently_paused` + `days_remaining` helpers |
| `infra/lambda/_shared/audit_catalog.py` | Modified | Add 8 new event constants per L12 |
| `infra/lambda/threshold-detector/handler.py` | Modified | Skip evaluation when patient is paused; emit sampled `suppressed_paused` audit |
| `infra/lambda/activity-processor/handler.py` | Modified | Auto-resume pause when new activity arrives |
| `infra/lib/stacks/api-stack.ts` | Modified | Wire `patient-mgmt` Lambda + 6 routes + 2 alarms |
| `infra/lib/constructs/patient-mgmt-lambda.ts` | New | Lambda construct mirroring `patient-api-lambda.ts` |
| `infra/lib/stacks/audit-stack.ts` | Modified | Add `/aws/lambda/gosteady-{env}-patient-mgmt` to subscription-filter list |
| `infra/lib/config.ts` | Modified | `patientMgmtMemoryMb` + `patientMgmtTimeoutSeconds` defaults |
| `infra/lambda/patient-api/handler.py` | Modified | 2A-RD `GET /patients/{id}` response extended with `careNote` + `notificationsPaused` fields (read-side, no auth changes) |
| `infra/scripts/seed-2a-um-test-data.py` | New | Idempotent seeder for test patients with `careNote` + `notificationsPaused` fixtures |
| `infra/scripts/smoke-2a-um.py` | New | Synthetic smoke runner |
| `docs/specs/ARCHITECTURE.md` | Modified | §15 Lambda Inventory add `patient-mgmt`; §17 flip 2A-UM-P; §12 phase plan |
| `docs/firmware-coordination/2026-04-17-cloud-contracts.md` | Modified | New §C-section: 2A-UM-P deploy outcome (cloud-only, no firmware action) |
| `docs/specs/phase-2a-um-patient-management.md` | New | This document |

### Dependencies

- **Phase 0A-rev** — Cognito JWT claims
- **Phase 0B-rev** — Patients table + GSIs
- **Phase 1.5** — IdentityKey CMK
- **Phase 1.6** — Powertools layer; ops SNS
- **Phase 1.7** — Audit pipeline
- **Phase 1B-rev** — Threshold Detector + Activity Processor (code updates bundled in)
- **Phase 2A-0** — API Gateway + authorizer + middleware
- **Phase 2A-RD** — `enforce_patient_access` helper (consumed as-is)
- **Phase 2A-DL** — `device-api.provision_device_internal` (called from atomic-add path); discharge-cascade Lambda (auto-triggered by Patients table DDB Streams)

### Configuration

| CDK Context Key | Dev | Prod | Notes |
|---|---|---|---|
| `patientMgmtMemoryMb` | 256 | 256 | Same as patient-api; mutation handlers are small |
| `patientMgmtTimeoutSeconds` | 15 | 15 | Higher than 2A-RD's 10s because atomic-provision invokes a downstream Lambda which adds 1-3s |
| `pauseSuppressionAuditSampleRate` | `1/day/patient` | `1/day/patient` | L9 sample rate |
| `autoResumeMinSteps` | `0` | `0` | Per A6; any activity event triggers auto-resume |
| `careNoteMaxChars` | `280` | `280` | L8 |

---

## Testing

### Test Scenarios

| # | Scenario | Method | Expected | Status |
|---|---|---|---|---|
| T1 | POST /patients without device → 201 with patient.currentDevice=null | curl | Patient row in DDB; `patient.created` audit event | Pending |
| T2 | POST /patients with device → 201 with atomic provision; activate cmd published | curl + bench device | `patient.created` + `device.assigned` audits; cmd_id in Device Registry outstandingActivationCmds | Pending |
| T3 | POST /patients with device that isn't ready_to_provision → 409 `DEVICE_NOT_AVAILABLE`; patient NOT created | curl | Atomic chain didn't run | Pending |
| T4 | POST /patients with valid device but IoT publish fails (synthetic) → 500 `PROVISION_FAILED`; patient rollback succeeded | force IoT publish fail | Patients table has no row for this attempt | Pending |
| T5 | PATCH /patients/{id} change name only → 200; audit has before/after with only displayName changed | curl | `patient.update` audit; `fieldsChanged: ["displayName"]` | Pending |
| T6 | PATCH /patients/{id} change censusId to one in different facility → 200; facilityChanged: true | curl as client_admin | `crossFacilityTransfer: true` in audit | Pending |
| T7 | PATCH /patients/{id} cross-facility change as caregiver → 403 `OUT_OF_SCOPE` (per Q3 decision) | curl | Audit emitted at 403 | Pending |
| T8 | POST /patients/{id}/discharge → 200; cascade fires async; device end-assignment + wipe cmd published | curl + bench device + audit query within 30s | `patient.discharge` + `device.assignment_ended (reason: patient_discharged)` + `device.wipe_requested` audits | Pending |
| T9 | POST /patients/{id}/discharge on already-discharged patient → 409 `INVALID_STATE` | curl | No rewrites | Pending |
| T10 | Discharged patient no longer appears in 2A-RD `/me/patients` (default filter is active) | curl | Confirms list filter | Pending |
| T11 | POST /patients/{id}/notifications/pause {days:7, reason:in_hospital} → 200 | curl | `notificationsPaused` populated; audit | Pending |
| T12 | Pause + bench publish heartbeat with battery=0.03 → Threshold Detector logs `suppressed_paused` + does NOT write alert | bench + audit query | Suppression event; no Alert History row | Pending |
| T13 | Pause + bench publish activity session → Activity Processor auto-resumes; `notificationsPaused` cleared | bench + audit query | `patient.notifications.resume_auto` audit | Pending |
| T14 | DELETE /patients/{id}/notifications/pause when paused → 200; cleared | curl | `patient.notifications.resume_manual` audit | Pending |
| T15 | DELETE /patients/{id}/notifications/pause when not paused → 409 `NOT_CURRENTLY_PAUSED` | curl | No audit | Pending |
| T16 | PATCH /patients/{id}/care-note {text: 280-char string} → 200; persisted | curl | Audit with before/after | Pending |
| T17 | PATCH /patients/{id}/care-note {text: empty} → 200; field removed | curl | Audit with before/null | Pending |
| T18 | PATCH /patients/{id}/care-note {text: 281-char} → 400 `CARE_NOTE_TOO_LONG` | curl | No write | Pending |
| T19 | GET /patients/{id} after care note set → response includes careNote field | curl on 2A-RD endpoint | Read-extension validated | Pending |
| T20 | GET /patients/{id} after pause → response includes notificationsPaused field | curl | Read-extension validated | Pending |
| T21 | Family viewer (read-only) attempts POST /patients → 403 `INSUFFICIENT_PERMISSIONS` | curl | Audit at 403 | Pending |
| T22 | Internal admin POST /patients in arbitrary client → 200; audit elevated severity, `internal_access: true` | curl + audit query | Per 2A-0 D5 | Pending |
| T23 | PII scrub — displayName never appears in `/aws/lambda/gosteady-{env}-patient-mgmt` log group | log filter query | 0 matches | Pending |
| T24 | All 6 endpoints have `patient-mgmt-errors` alarm catching synthetic 500 | force handler exception | ALARM state | Pending |
| T25 | Concurrent POST /patients with same logical request → idempotent? (open question; test that exhibits) | parallel curl | Open Q4 outcome | Pending |

### Verification Commands

```bash
# Hit POST /patients as facility_admin
TOKEN=$(aws cognito-idp initiate-auth --region us-east-1 \
  --auth-flow USER_PASSWORD_AUTH \
  --client-id 1q9l9ujtsomf3ugq2tnqvdg6d7 \
  --auth-parameters USERNAME=facility-admin-test@test.local,PASSWORD=... \
  --query 'AuthenticationResult.IdToken' --output text)

API_URL=$(aws apigatewayv2 get-apis --region us-east-1 \
  --query 'Items[?Name==`gosteady-dev-api`].ApiEndpoint' --output text)

curl -s -X POST -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"displayName":"Test Patient","censusId":"cen_ws_memory","room":"99X"}' \
  "$API_URL/api/v1/patients" | jq .

# Pull patient-mgmt audit events
aws logs filter-log-events --region us-east-1 \
  --log-group-name gosteady-dev-audit \
  --filter-pattern '{ ($.event = "patient.created") || ($.event = "patient.discharge") || ($.event = "patient.notifications.pause") }' \
  --start-time $(($(date +%s) - 600))000 --max-items 20
```

---

## Deployment

### Deploy Commands

```bash
cd infra
npm run build

# Order: Processing redeploy first (so threshold-detector + activity-processor
# pick up pause-aware behavior before any patients have notificationsPaused set),
# then Api stack (patient-mgmt + routes), then Audit stack (subscription filter).
npx cdk deploy GoSteady-Dev-Processing --context env=dev --require-approval never
npx cdk deploy GoSteady-Dev-Api --context env=dev --require-approval never

# Synthetic invoke patient-mgmt to materialize the log group before Audit attaches:
aws lambda invoke --region us-east-1 \
  --function-name gosteady-dev-patient-mgmt \
  --cli-binary-format raw-in-base64-out \
  --payload '{"requestContext":{"http":{"method":"GET","path":"/api/v1/patients/__synthetic"}}}' \
  /tmp/synth-invoke.json

npx cdk deploy GoSteady-Dev-Audit --context env=dev --require-approval never
```

Estimated total deploy time: Processing ~45 s (in-place Lambda updates), Api ~3 min, Audit ~30 s.

### Rollback Plan

- **Api stack:** `git revert <commit>` + redeploy removes patient-mgmt Lambda + routes cleanly. Rolling back doesn't touch existing Patients rows or their `careNote` / `notificationsPaused` fields (those remain in DDB but become inaccessible until next deploy)
- **Processing stack:** if pause-aware threshold-detector behavior breaks Threshold Detector entirely, redeploy the prior Lambda code via `git revert` + `npx cdk deploy GoSteady-Dev-Processing`. ~45s. Existing pause data in Patients table is benign — threshold-detector just stops honoring it
- **Atomic-add chain bug producing inconsistent state:** the Patient row's `attribute_not_exists(patientId)` conditional + DeleteItem on rollback means the worst case is a leftover Patient row. Manually delete via `aws dynamodb delete-item` or wait for a Phase 1C cleanup pass

---

## Decisions Log

| # | Decision | Alternatives Considered | Why This Choice |
|---|----------|------------------------|-----------------|
| D1 | Single `patient-mgmt` Lambda for all 6 routes | Per-route Lambdas | Mirrors 2A-DL/2A-RD/2A-AA precedent |
| D2 | Atomic add-with-provision is server-side (L3) | Client-side two-step | Same as 2A-DL L14 provision-atomic-with-IoT-publish pattern. Caregiver UX is "click Submit, it works or it doesn't" — no half-state |
| D3 | `careNote` + `notificationsPaused` are sibling attributes on Patients, not new tables | Separate CareNotes / Pauses tables | Schema-less DDB add costs nothing; Patients already read on every Threshold Detector hit; sibling-attribute read is free |
| D4 | Cross-facility transfer requires `client_admin+` (L4 + Q3) | Allow caregiver if they have both source + target facilities | User-needs §7 #1 says single Care Staff role in V1 — but cross-facility move is a higher-risk action (asset re-attribution + reporting impact). Bumping to client_admin is the safer default; relaxable in V2 if friction surfaces |
| D5 | Care note attribution denormalized (`updatedByName` on the row) | Resolve actor name on every read | Avoids per-read Users.GetItem on the 2A-RD `/patients/{id}` hot path. Staleness window is "what name was the actor going by when they last edited" — acceptable for care-note display |
| D6 | Discharge cascade is async; response returns immediately with the assignment-count before cascade fires | Synchronous wait for cascade completion | Cascade can take ~10s (wipe-cmd publish + heartbeat-processor ack + auto-recycle); blocking the API on it kills the UX. Audit trail proves cascade fired |
| D7 | Auto-resume pause on **any** activity event, threshold=0 (A6) | Threshold on steps/duration to filter test sessions | Per user-needs ("the reason for pausing is gone"); tunable later via `autoResumeMinSteps` config |
| D8 | Suppression audit sampled at ≤1/day/patient | Suppression audit on every paused-heartbeat | Audit log volume — a paused patient generates 24 heartbeats/day; 200 patients × 24 = 4800 events/day just for suppression. ≤1/day/patient gives the same compliance signal at 1/200th the volume |
| D9 | Bundle the Audit-stack subscription filter add into 2A-UM-P deploy (Migration Pattern 18.8) | Defer to follow-up commit | Same as 2A-0 D9 / 2A-RD D9 / 2A-AA L11 |
| D10 | New `_shared/pause_check.py` helper, not pause logic inline in threshold-detector + activity-processor | Inline | Two consumers + a third coming (1C-slim behavioral detector). Single helper prevents drift |
| D11 | Care note write is `PATCH /patients/{id}/care-note`, not extended `PATCH /patients/{id}` body | Bundle care-note into the general PATCH | Single-responsibility endpoint per US-44 ("inline editable, save on blur"). Avoids accidental careNote clears when caregiver edits just the room |

---

## Open Questions

> Plain-language explanation of each question + lean.

### Q1. POST /patients atomicity scope — server-side orchestration (decided)

**Decision:** ✅ Per Phase 2B Q4 user lean and this spec's L3 — server orchestrates atomic create-patient + provision-device.

---

### Q2. Idempotency on POST /patients — what if a network retry double-fires?

**What's actually being asked:** If a caregiver hits Submit and the network drops mid-response, the Flutter SPA might retry. Two POSTs with the same body would create two patient rows.

**Options:**
- (a) Caller-provided idempotency key (header `Idempotency-Key: <uuid>`). Server caches first response for ~24h and replays on retry
- (b) Best-effort detection — check for a Patient with the same `(displayName, censusId, room)` triplet within last 60s; if exists, return the existing row's 201
- (c) Accept duplicates; trust caregiver to delete one if visible

**Lean:** (a) idempotency key in header. Standard pattern. Caller (Flutter ApiClient) generates a UUID per submit attempt; server caches by `(actor.userId, idempotency_key)` in a small DDB table (TTL'd at 24h). Adds one small DDB table to provision (1 GSI, PAY_PER_REQUEST) — file a follow-up if not in scope.

**What's at stake:** Duplicate patient rows on flaky networks.

---

### Q3. Cross-facility transfer — caregiver-with-both-facilities OR client_admin-only?

**What's actually being asked:** US-29 + US-30 say transfer happens via Edit (just change the unit). Caregiver-tier users have `custom:facilities` claims. If a caregiver has access to both source and target facilities, can they move a patient between them, or do they need to bump to client_admin?

**Options:**
- (a) Allow if caregiver has both `facilities` claims (more flexible; matches what the demo's unit dropdown enables)
- (b) Require `client_admin+` for cross-facility (more conservative; matches Phase 0A-rev capability matrix's "Cross-Facility Device Move" row which requires client_admin)
- (c) Configurable per-client policy

**Lean:** (b) client_admin+. Reasons: (1) cross-facility move is an asset re-attribution event with reporting implications; (2) matches the existing Phase 0A-rev capability matrix which already gates Cross-Facility Device Move to client_admin; (3) within-facility edits (just changing the census within one facility) stay open to caregiver. If facility-staff complain about friction in V1.1, relax to (a).

**What's at stake:** UX friction for legitimate transfers; consistency with existing capability matrix.

---

### Q4. Concurrent-add race — two caregivers add the same patient simultaneously

**What's actually being asked:** Less of a problem than Q2 (real caregivers don't simultaneously add the same person), but: the conditional `attribute_not_exists(patientId)` on PutItem only guards same-patientId. Server generates `patientId` so collision is vanishingly unlikely — but the new-row could pass authz and land before the duplicate-by-name check (if any).

**Lean:** Trust UUID collision space + don't add a duplicate-by-name check. If two caregivers add "John Smith" to room 12A independently, both rows exist with different patientIds. UI surface for "merge duplicate patients" is a V2 internal-admin tool.

**What's at stake:** Edge-case duplicate patient rows; data quality.

---

### Q5. Discharge soft-undo — how does the 7-day window work mechanically?

**What's actually being asked:** User-needs §7 #11 says "support-mediated restore within 7 days; archived permanently after." That implies a Phase 1C-slim lifecycle Lambda runs daily, archiving `status=discharged` patients past 7 days from `dischargedAt`.

**Lean:** Defer the lifecycle Lambda to Phase 1C-slim (file as a discrete deliverable). In the meantime, discharged patients stay queryable indefinitely (just hidden from default `/me/patients` filter). Restore is an internal-admin path (re-flip `status` back to `active` + re-provision the device manually) — not exposed in 2A-UM-P. Wraps up cleanly in the 1C-slim work.

**What's at stake:** 7-day archival semantic isn't enforced in MVP; not a blocker.

---

### Q6. `careNote.updatedByName` denormalization — what happens when the actor's display name changes?

**What's actually being asked:** Per D5, we denormalize the actor's name onto the careNote row. If "J. Blackburn" later changes their display name to "Jace Blackburn," old care notes still show "J. Blackburn" until edited.

**Lean:** Accepted side effect. The note's attribution is a point-in-time record of *who edited it under what name*. If display-name changes are very rare (per Phase 0A-rev they require admin intervention), stale denorm is fine. If a fresh-name display matters, a one-time DDB scan can update care-note rows.

**What's at stake:** Care-note attribution staleness; product/UX call.

---

### Q7. Should POST /patients require timezone explicitly, or derive from facility?

**What's actually being asked:** Patient timezone drives every "today" computation in the system. Facility has a timezone (or its parent client does). Should the API require timezone in the body, or derive at write?

**Lean:** Derive from facility (which derives from client default). Don't require timezone in the request body. If a patient legitimately needs a different timezone (snowbird residents?), V2 adds per-patient timezone override.

**What's at stake:** Onboarding friction vs. data correctness for edge cases.

---

### Decision summary

| # | Question | Resolution |
|---|---|---|
| Q1 | Atomicity scope | ✅ Server-side per L3 |
| Q2 | POST idempotency | ⏳ Lean: idempotency key in header (small new DDB table) |
| Q3 | Cross-facility caregiver permission | ⏳ Lean: client_admin+ (D4) |
| Q4 | Concurrent-add race | ⏳ Lean: trust UUIDs; V2 dedup tool |
| Q5 | Discharge soft-undo mechanism | ⏳ Lean: Phase 1C-slim lifecycle Lambda; out of 2A-UM-P scope |
| Q6 | Care-note actor name denorm | ⏳ Lean: accepted staleness |
| Q7 | POST timezone derive vs require | ⏳ Lean: derive from facility |

One of seven decided. Six require user input.

---

## Changelog

| Date | Author | Change |
|------|--------|--------|
| 2026-05-23 | Jace + Claude (portal session) | Initial spec drafted as the V1-blocking subset of the 2A-UM umbrella. Six patient-mutation endpoints gating [phase-2b-portal-integration.md](phase-2b-portal-integration.md)'s 2B-FAC-W subset. Two new Patients-row attributes (`careNote`, `notificationsPaused`) added schemaless. Threshold Detector + Activity Processor pick up pause-aware behavior via shared `_shared/pause_check.py` helper. Discharge cascades via existing 2A-DL discharge-cascade Lambda. Eight new audit catalog events. Atomic create+provision pattern mirrors 2A-DL L14. Seven open questions surfaced; one decided inline, six require user input (idempotency, cross-facility caregiver permission, concurrent-add race, soft-undo mechanism, care-note name staleness, timezone derive). 2A-UM-H (household onboarding) + 2A-UM-S (staff user creation) explicitly deferred to sibling specs. |

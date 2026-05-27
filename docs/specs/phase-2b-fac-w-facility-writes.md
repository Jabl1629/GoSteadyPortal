# Phase 2B-FAC-W — Facility Writes

## Overview
- **Phase**: 2B-FAC-W (facility-writes subset of Phase 2B)
- **Status**: 🔲 In Progress
- **Branch**: `feature/infra-scaffold`
- **Date Started**: 2026-05-27
- **Date Completed**: TBD

Closes the V1 caregiver UX loop by wiring the five mutation actions that the demo dialogs already model: alert acknowledge, add/edit resident, discharge, pause/resume notifications, and care-note edit. Every backend endpoint already deployed in dev (2A-AA + 2A-DL + 2A-UM-P); this is **pure-Flutter wiring + UI polish for the two visual indicators (US-31 pause banner, US-44 care-note panel) that the demo doesn't yet render**.

After FAC-W ships, a caregiver at `dev.portal.gosteady.co` can: ack a notification (clearing it from the active list), add a new resident with optional atomic device provisioning, edit a resident's name/room/census (including cross-facility transfer when authorized), discharge a resident (cascading device end-assignments via 2A-DL), pause a resident's notifications with a visible countdown banner, and edit a free-text care note. Combined with FAC-R reads, this is the V1 facility-tier portal complete.

## Locked-In Requirements

| # | Requirement | Decided In | Rationale |
|---|-------------|-----------|-----------|
| L1 | **Demo build must keep working at every commit.** Same constraint as 2B-FAC-R L1 — every commit must build cleanly in both `BUILD_MODE=demo` and `BUILD_MODE=live`. Demo mode keeps the existing mock-bound handlers; live mode swaps to repository write methods | Phase 2B-0 L1 + 2B-FAC-R L1 | Marketing demo at facilitydemo.gosteady.co stays load-bearing |
| L2 | **All writes go through `FacilityRepository`, not `ApiClient` directly.** Even though only one impl (the live one) does anything meaningful, every write screen calls `widget.data.<method>(...)` so the demo path remains a single replaceable seam. Demo impl returns `Future.value(stub_response)` or applies the change to its in-memory mock | This spec | Matches the L2 separation from 2B-FAC-R |
| L3 | **Cache invalidation on every successful write.** After PATCH/POST/DELETE succeeds, the live repo calls the appropriate `refresh*()` method (patient detail re-fetch on patient mutations; `/me/patients` re-fetch on add/discharge/edit). Cached views update within the same widget rebuild — no stale UI | This spec + 2B-FAC-R L12 caching | Caregivers expect "I just changed it, why doesn't it show" never to happen |
| L4 | **Optimistic UI is OUT of scope for V1.** Every write awaits the server response before updating UI. Spinner + disabled button during the in-flight call. Failure shows an inline error banner with the API error code/message; the user retries explicitly. No optimistic state, no rollback choreography | This spec | Simpler implementation; caregivers do these actions deliberately (not in rapid succession), so the perceptible latency cost is acceptable. Optimistic UX is a 2B-POL follow-up if pilot data demands it |
| L5 | **Manual ack from this Lambda exercises the §C33 manual-ack release path.** When the live `ackAlert` succeeds, alert-actions also releases the openAlerts slot on Patient row. This is the first live exercise of that code path — bench-test that the slot is released so the next condition recurrence fires a fresh alert | coord §C33 | Closes the validation loop for the alert recurrence policy. Code path is reachable; live verification is the missing piece |
| L6 | **All five mutation endpoints route through `ApiClient._request` with the existing JWT-attach + error-envelope decode.** No new HTTP plumbing; all 7 currently-`UnimplementedError` methods (`ackAlert`, `createPatient`, `updatePatient`, `dischargePatient`, `pauseNotifications`, `resumeNotifications`, `updateCareNote`) get real implementations against the deployed 2A endpoints | This spec | One HTTP gateway per umbrella L4; consistent error handling |
| L7 | **Care Note widget renders BETWEEN the header strip and the Notification Review panel** on Patient Detail. Single editable block; ≤280 char counter; tap-to-edit affordance; cleared by saving an empty string (per 2A-UM-P L8). Renders `updatedByName` + relative-time attribution when present | user-needs US-44 + 2A-UM-P L8 | Demo doesn't have this widget; new visual surface specific to FAC-W |
| L8 | **Pause-notifications visual indicators** in two places: (a) **Census tile/list row** — small paused-bell icon next to the resident name when `notificationsPaused` is set + active; (b) **Patient Detail** — countdown banner immediately under the header strip showing reason + days remaining + Resume button | user-needs US-31 + 2A-UM-P L6 | The state already flows to the portal (Patient response includes `notificationsPaused`); FAC-W is the first place we render it |
| L9 | **Destructive actions visually distinct + require explicit confirmation.** Discharge button is **red-bordered**, opens a confirmation modal with reason picker + optional notes textarea; Resume Notifications is a low-friction one-tap action (no modal); Edit Info is neutral. Per user-needs US-33 | user-needs US-33 | "Don't accidentally discharge Mrs. Jones" |
| L10 | **`ApiClient` error mapping preserves the underlying type/message in `ApiException.details`** so future debugging surfaces the actual cause. Current catch-all in `_request` masks all client-side errors as `NETWORK / Connection lost` — fixed as a small adjacent task (coord §C34.3 lesson #1) | coord §C34 | Saves a debugging session next time a CORS / preflight / sync error happens |

## Assumptions

| # | Assumption | Risk if Wrong | Validation Plan |
|---|-----------|---------------|-----------------|
| A1 | 2A-AA `PATCH /alerts` correctly releases the openAlerts slot on Patient row (the manual-ack release path landed in coord §C33) | Acked alerts persist in `Patient.openAlerts.<type>`; subsequent condition recurrences get suppressed because the (now-stale) slot is still occupied | Live bench test: ack the bench unit's `device_offline` alert, query DDB to verify `Patient.openAlerts.device_offline` is absent, send a synthetic offline-resimulation and verify a fresh alert fires |
| A2 | 2A-UM-P discharge-cascade fires on DDB Streams reliably; the response's `cascade.devicesEnded` count is accurate at the moment the response returns (even though wipe-ack is async) | UI shows wrong count or implies cascade is done when it isn't | Discharge the bench-test patient; observe `device.assignment_ended` audit event lands within seconds; verify Device Registry transitions to `discontinued` |
| A3 | `Patient.notificationsPaused.until` is consumed by both threshold-detector and behavioral-detector via `_shared/pause_check.py` (per 2A-UM-P L9 + 2A-UM-P deploy chronology coord §C27) | Paused patients still emit synthetic alerts — bench unit would generate noise during paused state | Pause notifications on pt_bench_98 for 1 day; trigger threshold-detector with a synthetic battery_critical-territory Shadow update; verify zero new Alert row + one `patient.notifications.suppressed_paused` audit event at sample rate |
| A4 | `careNote.updatedByName` denormalization works — backend resolves the caregiver's display name at write time from the Users table | Care note shows raw `userId` string instead of human-readable name | Inspect the response after a write; should include `updatedByName` |
| A5 | `POST /patients` rollback path (atomic with device provisioning) was end-to-end-tested during 2A-UM-P deploy — sending a `deviceSerial` not in `ready_to_provision` correctly returns 409 with no orphan Patient row | Adding a resident with a typo'd serial leaves a half-created Patient row | Live test with a non-existent serial; verify 409 + no Patient row in DDB |

## Scope

### In Scope

#### Per-screen wiring

| Screen / Widget | File | What changes |
|---|---|---|
| **Notification Review panel** | `lib/facility_demo/widgets/notification_review_panel.dart` | Wire "Acknowledge + Save Note" button → `repository.ackAlert(patientId, sk, notes?)`. On success: refresh `/alerts?status=unacknowledged` cache + re-render without the acked row. Spinner in the button during in-flight; inline error banner on failure |
| **Add Resident dialog** | `lib/facility_demo/widgets/add_resident_dialog.dart` | Wire form submit → `repository.createPatient(displayName, censusId, room, deviceSerial?)`. On success: refresh `/me/patients` + close dialog. On 409 `DEVICE_NOT_AVAILABLE` / 500 `PROVISION_FAILED` show inline error banner with the API code + message |
| **Resident Settings dialog** | `lib/facility_demo/widgets/resident_settings_dialog.dart` | Wire four actions: Edit Info → `repository.updatePatient(id, {name?, censusId?, room?})`; Discharge → red-bordered confirmation modal → `repository.dischargePatient(id, reason, notes?)`; Pause Notifications → days-slider modal + reason dropdown → `repository.pauseNotifications(id, days, reason)`; Resume Notifications → one-tap → `repository.resumeNotifications(id)` |
| **Care Note widget** | `lib/facility_demo/widgets/care_note_panel.dart` (NEW) | Renders `Patient.careNote.text` (collapsed to 2 lines + tap-to-expand) + edit button. Inline edit dialog: textarea with 280-char counter + Save / Clear / Cancel. Save → `repository.updateCareNote(id, text)`; Clear → `repository.updateCareNote(id, '')`. Subtle "Updated by {updatedByName} · {relative time}" footer when populated |
| **Patient Detail view** | `lib/facility_demo/screens/patient_detail_view.dart` | Mount `CareNotePanel` between the device-header strip and Notification Review panel. Mount `PauseBanner` between header and care-note when `notificationsPaused != null` |
| **Patient tile / list row** | `lib/facility_demo/widgets/patient_tile.dart` + `lib/facility_demo/widgets/patient_list_view.dart` | Small bell-slash icon next to resident name when `summary.notificationsPaused != null` AND `until > now` |

#### New repository methods (interface + both impls)

Added to `lib/data/facility_repository.dart`:

```dart
Future<AckAlertResponse> ackAlert({
  required String patientId,
  required String sk,             // compound `{eventTs}#{alertType}`
  String? notes,
});

Future<PatientDetailResponse> createPatient({
  required String displayName,
  required String censusId,
  required String room,
  String? deviceSerial,           // optional; triggers atomic provision
});

Future<PatientDetailResponse> updatePatient({
  required String patientId,
  String? displayName,
  String? censusId,
  String? room,
});

Future<DischargeResponse> dischargePatient({
  required String patientId,
  required String reason,         // enum per 2A-UM-P L5
  String? notes,
});

Future<NotificationsPauseResponse> pauseNotifications({
  required String patientId,
  required int days,              // ∈ [1, 90]
  required String reason,         // enum per 2A-UM-P L6
});

Future<void> resumeNotifications(String patientId);

Future<CareNoteResponse> updateCareNote({
  required String patientId,
  required String text,           // empty clears
});
```

**Live impl** (`lib/data/live_facility_repository.dart`): each method awaits `_api.<method>(...)` then evicts the relevant caches (`refreshPatientDetail(id)` for patient mutations; refetch `_mePatients` slice for add/discharge/edit). Returns the parsed response so callers can update local UI state without an extra fetch.

**Demo impl** (`lib/facility_demo/data/facility_mock_data.dart`): each method mutates the in-memory mock (idempotent, single-process) and returns a synthesized response shaped per the live API. Demo UX continues to "just work" for marketing.

#### New API response models

Added to `lib/api/api_models.dart`:

- `AckAlertResponse { AlertRow alert; bool wasAlreadyAcknowledged; }`
- `DischargeResponse { PatientFull patient; DischargeCascadeInfo cascade; }` + `DischargeCascadeInfo { int devicesEnded; List<String> deviceSerials; bool wipeRequested; }`
- `NotificationsPauseResponse { NotificationsPaused? notificationsPaused; }` + `NotificationsPaused { DateTime until; String reason; DateTime pausedAt; String pausedBy; }`
- `CareNoteResponse { CareNote? careNote; }` + `CareNote { String text; String updatedBy; String? updatedByName; DateTime updatedAt; }`

`PatientFull` (existing in api_models.dart from FAC-R) gains optional `careNote` + `notificationsPaused` fields — they already arrive in the 2A-RD response (per 2A-UM-P L8 GET extension); we just wire them through the existing decoder.

#### ApiClient refactor for error preservation (adjacent fix per L10)

`lib/api/api_client.dart:_request` — change `catch (_) → throw ApiException.network()` to `catch (e) → throw ApiException.network(detail: e.toString())`. `ApiException.toString` includes the detail when non-null so the user-facing message becomes diagnosable. ~5 line change.

### Out of Scope (Deferred)

- **Provision Device (separate from Add Resident)** — assigning a device to an existing resident later. UI lives in resident_settings_dialog but the action is "Replace Device" which is a sequence: end the existing assignment → provision the new device. Handled by 2A-DL endpoints already deployed; wiring is a 2B-FAC-W follow-up if pilot demands it. V1 ships with Add-Resident-with-device + separate replace-device deferred to 2B-POL.
- **Threshold overrides UI** — `GET/PUT /patients/{id}/thresholds` (2A-AA endpoints) for clinical tuning. Not in V1 caregiver UX per user-needs scope; revisit when a clinical-tuning UX surface lands.
- **Discharge soft-undo** — 7-day reversal window mentioned in 2A-UM-P L5 is an `internal_admin`-only path; not in caregiver UX.
- **Cross-tenant transfer** — 2A-UM-P L4 cross-facility within the same client is in scope; cross-client transfer (different `clientId`) is internal-only.
- **Care Note history** — caregiver sees only the current note text; full version history is a 2B-POL or `internal_admin` audit-reader follow-up.
- **Bulk-discharge / Bulk-pause** — single-patient only in V1.
- **Optimistic UI** — every write awaits server response (per L4).

## Architecture

### Infrastructure Changes

**None.** All five backend endpoints already deployed in dev (2A-AA in coord §C26, 2A-UM-P in coord §C27). Phase 2B-FAC-W is pure-frontend per umbrella L16.

### Data flow per action

**Acknowledge alert:**

```
Caregiver taps "Acknowledge + Save Note"
  │
  ▼
repository.ackAlert(patientId, sk, notes?)
  │
  ▼
ApiClient.ackAlert(patientId, sk, {notes}) → PATCH /api/v1/alerts/{id}/{sk}
  │
  ▼
2A-AA handler: conditional UpdateItem on Alert row (gated by acknowledged=false)
  + release_open_alert(patientId, alertType) per §C33 L5
  + emit_audit(alert.ack)
  │
  ▼
Live repo evicts alerts cache for patientId
Notification Review panel re-fetches /alerts?status=unacknowledged
Row disappears from the list
```

**Add resident (atomic with device):**

```
Caregiver fills Add Resident dialog (name + census + room + optional serial)
  │
  ▼
repository.createPatient(displayName, censusId, room, deviceSerial?)
  │
  ▼
ApiClient.createPatient(...) → POST /api/v1/patients
  │
  ▼
2A-UM-P handler atomic chain:
  Patients.PutItem (conditional)
  → Organizations.GetItem (resolve facility from census)
  → enforce_scope
  → Device Registry.GetItem (verify ready_to_provision)
  → DeviceAssignments.PutItem + IoT publish + Shadow update
  → emit patient.created + device.assigned audits
  (rollback on any failure)
  │
  ▼
Live repo refreshes /me/patients
Dialog closes
Census re-renders with new row
```

**Discharge (with cascade):**

```
Caregiver opens Resident Settings, taps Discharge → red-bordered confirmation modal
  │
  ▼
repository.dischargePatient(patientId, reason, notes?)
  │
  ▼
ApiClient.dischargePatient(...) → POST /api/v1/patients/{id}/discharge
  │
  ▼
2A-UM-P handler:
  conditional UpdateItem on Patients (status=active → status=discharged)
  count active DeviceAssignments BEFORE the stream fires
  return immediately with cascade.devicesEnded count
  │  (DDB Streams fires async)
  ▼
discharge-cascade Lambda enumerates active assignments, calls device-api.end_assignment per device
Each end-assignment publishes wipe cmd to gs/{serial}/cmd
Audit chain per device: device.assignment_ended → device.wipe_requested → eventual device.wipe_complete → device.recycled
  │
  ▼
Live repo refreshes /me/patients + evicts patient detail cache
Discharged resident's row drops out of /me/patients (status filter)
```

**Pause / Resume notifications:**

```
Caregiver opens Resident Settings, taps Pause Notifications → days + reason modal
  │
  ▼
repository.pauseNotifications(patientId, days, reason)
  │
  ▼
ApiClient.pauseNotifications(...) → POST /api/v1/patients/{id}/notifications/pause
  │
  ▼
2A-UM-P handler: UpdateItem on Patients (notificationsPaused = {until, reason, pausedAt, pausedBy})
  emit patient.notifications.pause audit
  │
  ▼
Live repo refreshes patient detail
Pause Banner renders on Patient Detail
Bell-slash icon appears on Census tile/row
Threshold-detector + behavioral-detector skip-when-paused (per 2A-UM-P L9) — no new synthetic alerts until until-timestamp passes or activity arrives (auto-resume per L10)

Resume path is symmetric: DELETE /notifications/pause; UpdateItem REMOVE; banner + icon disappear.
```

**Care note:**

```
Caregiver taps Care Note edit pencil → inline modal with 280-char counter
  │
  ▼
repository.updateCareNote(patientId, text)
  │
  ▼
ApiClient.updateCareNote(...) → PATCH /api/v1/patients/{id}/care-note
  │
  ▼
2A-UM-P handler: SET careNote (or REMOVE if empty); resolves updatedByName from Users; emit patient.care_note.update audit
  │
  ▼
Live repo refreshes patient detail
Care Note panel re-renders with new text + new attribution
```

## Implementation

### Files Changed / Created

> Asterisk (*) = file affects BOTH demo and live builds; must build cleanly in both modes.

| File | Change | Description |
|---|---|---|
| `lib/api/api_client.dart` | Modified | Replace 7 `UnimplementedError` stubs with real implementations. Adjacent fix: preserve underlying exception detail in `ApiException.network()` per L10 |
| `lib/api/api_models.dart` | Modified | Add `AckAlertResponse`, `DischargeResponse`, `DischargeCascadeInfo`, `NotificationsPauseResponse`, `NotificationsPaused`, `CareNoteResponse`, `CareNote`. Extend `PatientFull` to decode `careNote` + `notificationsPaused` |
| `lib/api/api_exception.dart` | Modified | `ApiException.network({String? detail})` factory + include detail in `toString()` |
| `lib/data/facility_repository.dart` * | Modified | Add 7 write methods to the abstract interface |
| `lib/data/live_facility_repository.dart` | Modified | Implement the 7 writes + cache invalidation on each success |
| `lib/facility_demo/data/facility_mock_data.dart` * | Modified | Demo impls: mutate in-memory mock, return synthesized response. No-ops where mock doesn't have the field |
| `lib/facility_demo/widgets/notification_review_panel.dart` * | Modified | Wire Acknowledge button → repository.ackAlert; spinner + error banner |
| `lib/facility_demo/widgets/add_resident_dialog.dart` * | Modified | Wire submit → repository.createPatient; error banner |
| `lib/facility_demo/widgets/resident_settings_dialog.dart` * | Modified | Wire 4 actions (Edit / Discharge / Pause / Resume); Discharge has red-bordered confirmation modal + reason picker |
| `lib/facility_demo/widgets/care_note_panel.dart` * | New | Care-note display + inline editor widget |
| `lib/facility_demo/widgets/pause_banner.dart` * | New | Patient Detail pause-countdown banner with Resume button |
| `lib/facility_demo/screens/patient_detail_view.dart` * | Modified | Mount CareNotePanel + PauseBanner; pass them the active patient + repository |
| `lib/facility_demo/widgets/patient_tile.dart` * | Modified | Bell-slash icon when `summary.notificationsPaused != null && until > now` |
| `lib/facility_demo/widgets/patient_list_view.dart` * | Modified | Same bell-slash icon in the resident-name cell |

### Test plan

| # | Action | Expected | Status |
|---|---|---|---|
| T1 | Sign in as `dev-pilot-caregiver@test.local` → ack a notification | Notification disappears from list; `Patient.openAlerts.<type>` slot is released (DDB query); audit `alert.ack` lands in S3 audit bucket | Pending |
| T2 | Ack the bench unit's `device_offline` alert, wait for next behavioral-detector cron tick | A fresh `device_offline` alert fires because the slot was released. Confirms manual-ack release path from §C33 | Pending |
| T3 | Add a new resident with a real ready-to-provision device | Patient row created in DDB; DeviceAssignment row created; activate cmd published; Census shows the new row | Pending |
| T4 | Add a resident with a fake device serial | 409 `DEVICE_NOT_AVAILABLE`; no Patient row in DDB; UI shows the error code/message inline | Pending |
| T5 | Edit a resident's room | Patient row updated; Patient Detail header re-renders with new room; audit `patient.update` emitted | Pending |
| T6 | Discharge the bench-test patient | Patient.status = discharged; Census row disappears (status filter); within seconds `device.assignment_ended` audit fires + Device Registry → discontinued | Pending |
| T7 | Pause notifications for 7 days | `Patient.notificationsPaused` set; Patient Detail shows countdown banner; Census tile shows bell-slash; trigger threshold-detector with synthetic battery=0 update → zero new alerts + `patient.notifications.suppressed_paused` audit sampled | Pending |
| T8 | Resume notifications early | `notificationsPaused` REMOVED; banner + icon disappear; audit `patient.notifications.resume_manual` emitted | Pending |
| T9 | Edit care note to "Watch for unsteadiness after dinner — son visiting Sat." | Patient Detail re-renders with the new text + updatedByName + "just now" attribution | Pending |
| T10 | Clear care note (empty Save) | Patient Detail shows "no care note" placeholder; `Patient.careNote` REMOVED in DDB | Pending |

## Deployment

```bash
# Per-commit deploy (same as FAC-R)
flutter build web -t lib/facility_demo/main_demo.dart --dart-define=BUILD_MODE=demo   # demo build smoke
flutter clean
AWS_REGION=us-east-1 ./tools/deploy-portal.sh                                          # live build + S3 sync + CloudFront invalidation
```

## Decisions Log

| # | Decision | Alternatives | Rationale |
|---|---|---|---|
| D1 | Writes through FacilityRepository, not ApiClient directly | Direct ApiClient call from each screen | Single-seam matches FAC-R L2; demo stays trivially swappable |
| D2 | Server-await for every write (no optimistic UI) | Optimistic UI with rollback | L4 — simpler; latency is small (~150ms p95) and acceptable for these low-frequency actions |
| D3 | Discharge requires confirmation modal; Pause does not | Both modal; both one-tap | L9 — Discharge is destructive (state machine sink + cascade fires); Pause is reversible |
| D4 | Care Note panel between header strip and Notification Review | Below all activity; in the header | user-needs US-44 places it as a quick-reference block; immediately under header is the natural read order |
| D5 | Bell-slash icon for pause is shown both on tile + list row | Tile only, drilldown only | Caregivers scan the Census looking for active anomalies; pause status needs to be visible at the scan tier so they don't expect alerts |
| D6 | ApiClient error detail preservation lands in this phase | Defer to 2B-POL | Tiny change (~5 lines); saves debugging time during FAC-W bench-tests; closes coord §C34.3 lesson #1 |

## Open Questions

| # | Question | Lean / Assumption | ELI5 impact |
|---|---|---|---|
| Q1 | Should the manual-ack response include an `openAlertReleased: true` field so the UI knows the slot is now free? | **Lean: no.** The portal doesn't currently render anything based on slot-state; this is server-internal state. If a future feature needs it (e.g., "alerts that have re-fired since last ack" badge), wire it then | Caregivers see no behavior change. Server-internal cleanup |
| Q2 | When discharge happens, should the Patient Detail screen auto-close (popping back to Census), or stay with a "Discharged" banner? | **Lean: auto-close** (back to Census). User-needs §7 doesn't specify but the demo behavior is to drop the patient from the active census; staying on a discharged-patient screen is dissonant | If "stay": caregivers might double-discharge or expect re-activation affordance to be present. If "close": cleaner state transition |
| Q3 | Edit Resident's `censusId` field — show all censuses across all facilities the caregiver is authorized for, or only within current facility? | **Lean: all authorized facilities.** Cross-facility transfer is in scope per L4 + user-needs US-30. Filtering would prevent the supported use case | Caregiver picking a census sees the full set; if their JWT doesn't include the target facility, the server returns 403 with a clear message |
| Q4 | Pause Notifications "days" input — slider (1-90) or numeric stepper? | **Lean: slider with snap points** at 1, 3, 7, 14, 30. Free-form input below for "other" | Caregivers most often pick "until end of week" (7) or "until next month" (30); snap points speed up the common case |
| Q5 | After a successful Add Resident with device, should the UI auto-navigate to the new patient's detail view? | **Lean: yes.** Reduces a step + caregiver can immediately set care notes / verify the activation banner | Without auto-nav: caregivers add → find on census → tap. Two extra clicks |

## Changelog

| Date | Author | Change |
|------|--------|--------|
| 2026-05-27 | Jace + Claude session | Initial spec draft. Locks in 5 caregiver actions + 2 visual indicators (pause banner, care-note panel) + ApiClient error-detail preservation as an adjacent fix. All backend endpoints already deployed; pure-Flutter wiring scope. Demo build must keep compiling per L1; writes route through FacilityRepository per L2 |
| 2026-05-27 | Jace + Claude session | **Initial impl + deploy + live-validation.** All 5 actions wired through the FacilityRepository abstract interface (+ 2 stub no-op methods for the deferred 2A-DL replace/discontinue device paths). New `lib/api/api_models.dart` types: `AckAlertResponse`, `DischargeResponse + DischargeCascadeInfo`, `NotificationsPauseResponse + NotificationsPaused`, `CareNoteResponse + CareNote`, `PauseReason` + `DischargeReason` enums. Extended `PatientFull` to decode `careNote` + `notificationsPaused` (already in 2A-RD response per 2A-UM-P L8). Extended `AlertRow` with `eventTimestampRaw` + `sk` getter so `PATCH /alerts/{id}/{sk}` round-trips correctly (some SKs have facility-local timezone offsets that UTC conversion would break). Extended `PatientNotification` with optional `sk` so the Notification Review panel can pass it to the ack call. Extended demo `Patient` model with optional `careNote` + `notificationsPaused`. New widgets: `lib/facility_demo/widgets/care_note_panel.dart` (display + inline edit dialog with 280-char counter), `lib/facility_demo/widgets/pause_banner.dart` (countdown + Resume button). Mounted both above the Notification Review panel on Patient Detail. Added `_runWrite` helper to ResidentSettingsDialog for async write-then-toast-or-error. Care note + pause banner wired into PatientDetailView between header and notification panel. ApiClient error-detail preservation landed per L10 (coord §C34.3 lesson #1). **Live-validated against pt_bench_98 via direct PATCH /alerts API call:** acknowledgedBy = caregiver Cognito sub `4408b4a8-b031-70b9-1a5d-a3826121a4db`, ackNotes saved, `Patient.openAlerts.battery_critical` released to null. **Recurrence after release verified:** subsequent `battery_pct=0.02` shadow update fires fresh battery_critical alert + reclaims slot. Full state machine validated end-to-end. UI ack via `form_input` didn't work because Flutter's onChange listener doesn't fire on JS-set values — caregiver-driven UI ack flow needs a fresh bench session with native key events. Census-tier paused-bell icon (US-31) deferred — `/me/patients` response needs `notificationsPaused` field; filed as 2A-RD follow-up |

# Phase 2B-FAC-R — Facility Reads

## Overview
- **Phase**: 2B-FAC-R (facility-reads subset of Phase 2B)
- **Status**: 🔲 Planned
- **Branch**: `feature/infra-scaffold` (or feature branch cut from it)
- **Date Started**: TBD
- **Date Completed**: TBD

Wires the live build's Census, Patient Detail, and Device Detail screens to the Phase 2A-RD read endpoints. The marketing demo at `facilitydemo.gosteady.co` continues to render against `FacilityMockData` — same screens, same widgets, different `FacilityRepository` implementation per the dual-build pattern locked in Phase 2B-0.

The cloud-side prerequisites are all live in dev:
- **2A-RD** (deployed 2026-05-23) — `GET /me/patients`, `GET /patients/{id}`, `GET /patients/{id}/activity?range=`, `GET /patients/{id}/alerts?status=`, `GET /facilities/{f}/censuses/{c}/patients`
- **2A-AA** (deployed 2026-05-23) — alert acknowledge endpoint (2B-FAC-W consumer, not FAC-R; mentioned for completeness)
- **1C-slim** (deployed 2026-05-24) — server-side behavioral detector writing `no_activity_today` / `below_typical_activity` / `declining_trend` / `device_offline` / `device_silent` alerts into the existing Alert History table. **This is the unlock that lets 2B-FAC-R show real notification copy** (not just counts) — the umbrella's A3 gate is closed.

Once 2B-FAC-R ships, a real caregiver at `dev.portal.gosteady.co` can sign in, see every resident they're authorized for with today's activity + 7-day trend + alert state pulled from DynamoDB, drill into a resident's trends + device-health card, and view per-resident notifications by rule name. **No writes yet** — acknowledgment + lifecycle actions are 2B-FAC-W (a separate subset that depends on 2A-UM-P, which is also already deployed).

The deliverable is a portal that:

1. In `BUILD_MODE=live`, replaces the "Foundation ready" stub from 2B-0 with the actual facility shell — Census view (list + tile toggle), Unit selector, Patient Detail overlay, Device Detail page.
2. Polls for fresh data on a 60s Census cadence and 30s Patient Detail cadence while the tab is visible; pauses when backgrounded.
3. Renders notification badges with full rule-name copy ("No activity today" / "Below typical" / etc.) and severity coloring, sourced from real `alertType` values returned by the alerts endpoint.
4. Keeps the marketing demo build unchanged — every commit must build cleanly in both modes.

This is **screen wiring + data-shape adaptation**. No new AWS resources. No new spec contracts. The work is pure-Flutter assembly using interfaces already shipped in 2B-0.

## Locked-In Requirements

| # | Requirement | Decided In | Rationale |
|---|-------------|-----------|-----------|
| L1 | **Demo build must keep working at every commit.** Any change to `lib/facility_demo/screens/` or `lib/widgets/` (shared widgets) requires `flutter build web -t lib/facility_demo/main_demo.dart --dart-define=BUILD_MODE=demo` to succeed before push. The marketing demo at `facilitydemo.gosteady.co` is a load-bearing investor artifact | Phase 2B-0 L1 + D1 (approach C) | Approach C's whole premise is that demo + live share a screen tree. If demo regresses while live is being wired, we've lost the premise |
| L2 | **Hybrid sync/async `FacilityRepository` boundary.** Facility/Unit/PatientSummary lookups stay synchronous on the existing interface (loaded once at shell init via `/me/patients`, cached in `LiveFacilityRepository`). Per-patient detail methods (`todayFor`, `last7DaysFor`, `last30DaysFor`, `deviceFor`, `notificationContextFor`, `rowStatsFor`) become **`Future<...>`-returning** — the screens that consume them wrap their fetch in `FutureBuilder`. `FacilityMockData` updates one matching line per converted method (`return Future.value(...)`); no demo-side semantic change | This spec — resolves the 2B-0 spec deviation in `FacilityRepository` | The 2B-0 sync-interface decision avoided a 25-site cascade through demo screens. FAC-R only needs async on the patient-detail boundary; Census-level reads stay sync because the live impl caches the `/me/patients` response in memory at shell init. Compromise gives async where it pays (per-patient I/O) without churning the Census widget tree |
| L3 | **Polling cadence (foreground only):** Census refreshes `/me/patients` every **60s**; Patient Detail refreshes its three concurrent calls (`/patients/{id}` + `/activity?range=...` + `/alerts?status=unacknowledged`) every **30s**. Both pause when `AppLifecycleState != resumed` (tab backgrounded / minimized / blurred). Polling resumes immediately on `resumed` via a single Flutter `WidgetsBindingObserver` mounted at the `AppShell` root | Phase 2B umbrella L12 + A4 audit-cost ceiling | The user-needs doc's "fresh data" SLA is "within ~1 minute" — 60s Census matches. Patient Detail at 30s is the active-investigation cadence. Backgrounding-paused polling honors A4's audit-volume budget (~96k poll events/day worst-case, well within Phase 1.7's MVP budget) |
| L4 | **Range tabs ship as 24H / 7D / 30D only.** The 6M tab is **removed from the UI entirely** in V1 — not "disabled with a tooltip" — pending Phase 1C-full's daily-rollup endpoints. The demo's `last6MonthsFor` method stays on the repository interface so the demo build's 6M tab keeps rendering (mock data) | Phase 2A-RD §Out of Scope + Phase 1C-slim §Out of Scope + this spec | "Disabled with tooltip" is dead UI clutter; removing the tab entirely is cleaner. When 1C-full rollups ship, we add the 6M tab back as a separate small change. **Note:** demo build still shows 6M; live build hides the tab via `BuildMode` check at the `TimeRangeToggle` widget |
| L5 | **List-view 11-column metrics use lazy per-row fetch.** Initial Census render uses `/me/patients` response fields (display name, location, currentDeviceSerial, lastActivityAt, openAlertCount). Per-row trend / 7-day-avg / today columns fetch `/patients/{id}/activity?range=7d` **lazily as the row scrolls into view** (Flutter's `VisibilityDetector` package or `ListView` viewport callback). Concurrent fetches throttled to **5 at a time** via a custom `_RowLoaderQueue` in `LiveFacilityRepository`. Each row shows a sage-tinted skeleton placeholder for the trend/avg columns until its fetch completes | Phase 2B umbrella A2 + this spec | A2 flagged the fan-out risk: a facility_admin scoped to 200 patients calling `/activity?range=7d` 200× on cold dashboard load would be a sub-second-but-painful 30s of API Gateway throttle (25 RPS dev limit). Lazy + throttled keeps initial render fast and the API happy. Skeleton-placeholder UX is also better than a single 30s spinner |
| L6 | **Notification badges show full rule-name copy** (not counts). Mapping table below — fed from real `alertType` values returned by `GET /patients/{id}/alerts?status=unacknowledged`. The demo's client-side `notification_engine.dart` is **bypassed entirely in live mode**: live screens call the alerts endpoint and render the strings from the mapping. Demo build keeps using the engine | Phase 1C-slim deployed 2026-05-24 (closes umbrella A3) | The umbrella's A3 worry ("rules MUST move server-side before 2B-FAC-R ships") is closed — 1C-slim ships real `alertType` values into the existing Alert History table. The portal becomes a thin renderer of server-authoritative state |
| L7 | **Activity aggregation is client-side**, applied to the **sessions** returned by `/activity?range=...`. The portal groups by the response's `date` field (facility-local date string), sums `steps` + `activeMinutes` + `distanceFt` per day → `DailyActivity`. For the 24H view, sessions are bucketed by hour (using `sessionStart` timestamp in facility local time) → `HourlyActivity`. Phase 1C-full daily-rollup endpoints will replace this with server-side aggregation once they ship | Phase 2A-RD response shape (sessions, not daily totals) | The API returns raw sessions intentionally — keeps the storage shape stable and the read endpoint cheap. Client-side aggregation at 24h/7d/30d scale (~30-90 sessions) is fast (<10ms) and trivial to implement. 6M would be 300-900 sessions per fetch which strains the cursor budget — that's why 6M waits for rollups |
| L8 | **Gait speed UI suppressed in V1.** The list-view "Gait Speed (3-day avg)" + "Gait Trend" columns are **hidden** in live mode. The patient-detail "Gait Speed" chart is **hidden** in live mode. The 2A-RD activity response doesn't include gait fields — neither firmware nor 2A-RD ships them today. Demo build continues to render gait from seeded mock data | This spec — Open Question Q1 below | The user-needs doc's US-19 wants gait speed visible. The firmware M10 V1 algorithm produces steps + distance + activeMinutes per session but NOT gait speed per session. Adding gait emission is a firmware change (FW-side) and a 2A-RD response-shape change (cloud-side) — both out of 2B-FAC-R scope. V1 ships without gait; V1.1 adds it once firmware emits |
| L9 | **Patient Detail data is fetched in parallel**, not sequentially: `/patients/{id}` + `/patients/{id}/activity?range=24h` + `/patients/{id}/alerts?status=unacknowledged` all dispatch from a single `Future.wait`. Switching range tabs triggers only the activity refetch (other two reused from cache for 30s) | This spec — perf default | Sequential waterfall = 3× round-trip latency. Parallel = max-of-3 = ~150ms total on warm path. Saves the "click patient → blank for 2 seconds" UX |
| L10 | **List view is the default Census view** in live mode (V1). The user-needs doc's US-04 says "List view defaults on (data-dense scanning)." The demo currently defaults to Tile view (visual showcase for investors). The `view=` URL query param overrides the default. Toggle persists in URL state per umbrella L11 | user-needs §4.2 US-04 + Phase 2B umbrella L11 | Demo's tile default is right for its audience (investors visualizing the wall of patients); production caregivers want data density. URL persistence means a caregiver who prefers tile gets it on every reload by virtue of having selected it once |
| L11 | **`AppLifecycleState` foreground detection + polling pause** is the source of truth for "is the user actively watching?" — NOT page visibility heuristics, NOT focus events. Implemented via `WidgetsBindingObserver` mounted at `AppShell`. State change → broadcast to `AppState.poll.enabled` (new `ValueNotifier<bool>`). Census + Patient Detail subscribe to this notifier and skip their polling tick when it's `false` | This spec | Flutter's lifecycle hook is the standard signal; works the same on web + desktop. Page Visibility API would work for web-only but adds platform-specific code |
| L12 | **`LiveFacilityRepository` becomes a cache + fetch layer**, not a stateless wrapper around `ApiClient`. Census-level data (`allFacilities`, `allUnits`, `patientsForSelection`) is computed from a cached `MePatientsResponse` populated at shell init. Per-patient methods cache their last response per `patientId` with a 30-second TTL; subsequent calls within TTL return the cached value (no HTTP). Cache is invalidated on (a) explicit `refresh()` from a polling tick, (b) `AppLifecycleState` becoming `resumed` after >2 min backgrounded, (c) sign-out | This spec — resolves the 2B-0 spec stub-vs-impl deferral | Caching is necessary for the lazy-row-fetch + parallel-detail-fetch patterns to be sane. TTL of 30s is below the patient-detail polling cadence so the cache effectively serves the polling loop. Explicit `refresh()` from polling avoids a stale-data feedback loop |
| L13 | **Initial `/me/patients` fetch concatenates all pages** before the Census renders. Background polling refetches **only the first page** (cursor=null) and replaces the cached list; subsequent pages refetch on user-initiated full refresh (pull-to-refresh affordance, deferred to 2B-POL). Polling never paginates — that's a deliberate cap on poll cost | Phase 2B umbrella L8 + L12 | A 200-patient facility paginates to ~4 pages (50/page). Initial load fetches all 4. Polling refetches page 1 only — the most-recently-active patients (DDB SK is descending by activity timestamp). Stale patients at the bottom of page 4 are refreshed on demand, not every 60s |

## Assumptions

| # | Assumption | Risk if Wrong | Validation Plan |
|---|-----------|---------------|-----------------|
| A1 | `/me/patients` returns patients in a useful default ordering (most-recent-activity first) | Polling refreshes the wrong slice of patients first; recently-inactive patients become stale | Verify against 2A-RD spec D-decisions; if absent, file a tightening request — paged results NEED a stable ordering for L13's "page 1 = freshest" claim to hold |
| A2 | Lazy-per-row activity fetch at 200 patients × 7d range completes in <60s total at dev API throttle limits (25 RPS sustained / 50 burst) | Census looks half-empty for tens of seconds; users assume the app is broken | Synthetic load test with 200 fixtures (extend `seed-2a-rd-test-data.py` to seed-N patients with synthetic activity); time the cold-load. If >30s, lower the visible-row trigger threshold to "load 5 ahead of viewport" instead of "load on viewport intersect" |
| A3 | Sessions can be reliably grouped by the response's `date` field (facility-local date string) to produce DailyActivity | Charts show wrong-day buckets at DST transitions or midnight-crossing sessions | 2A-RD response embeds `date` as a server-computed facility-local string. Test fixtures include a midnight-crossing session; verify chart bucket is the session-start date (per firmware convention) |
| A4 | Hour-bucketing for 24H view tolerates partial-hour sessions (a session that spans 14:55–15:08 contributes to both 14:00 and 15:00 buckets, proportionally by minute) | 24H bars show "lumpy" or "lossy" totals | Demo's existing `HourlyActivity` bucketing logic already handles this — we reuse it verbatim. Add a unit test for the split |
| A5 | Throttling lazy fetches to 5 concurrent is enough at dev throttle (25 RPS); prod throttle is 100 RPS so the same throttle is over-conservative in prod (could be tuned up to 10 or 20) | Dev devs hit 429s during cold-load testing | Throttle is per-build dart-define (`LAZY_FETCH_CONCURRENCY`, default 5); tunable per env without code change |
| A6 | The Page Visibility API isn't needed because `AppLifecycleState.inactive` fires for browser tab blur in Flutter Web | Polling continues while tab is blurred; A4's audit-cost budget is exceeded | Verify with `flutter run -d chrome` + DevTools Application tab + manual blur. If `inactive` doesn't fire, add a `window.addEventListener('blur'/'focus')` web-platform fallback |
| A7 | Demo build continues to render correctly after every per-screen swap during this subset | Marketing demo regresses; investors see broken state at `facilitydemo.gosteady.co` | Per-commit discipline: `flutter build web -t lib/facility_demo/main_demo.dart --dart-define=BUILD_MODE=demo` runs before push. Long-term: CI gate in Phase 3B |
| A8 | The Cognito test users from `seed-2a-rd-test-data.py` (`rd-caregiver@test.local`, `rd-facadmin@test.local`) have enough patient + activity + alert fixtures to exercise the 11-column list view + patient detail trends + notification panel | Smoke tests find gaps; need to extend the seed | The seed script ships 5 patients (1 with 60 activity rows, 2 with alerts). Enough for visual smoke. Facility-scale testing (50+ patients) needs a separate seed-extend |

## Scope

### In Scope

#### Per-screen wiring

| Screen | File | What changes | API calls |
|---|---|---|---|
| Facility Shell | `lib/facility_demo/screens/facility_shell.dart` | In live mode, the existing "Foundation ready" stub at `_LiveFacilityShellStub` (`lib/shell/app_shell.dart`) is removed; `FacilityShell` is constructed for both modes. The polling-pause `WidgetsBindingObserver` mounts at `AppShell` (see L11) | none — orchestration only |
| Census (List + Tile views) | `lib/facility_demo/screens/patient_census_view.dart` | Calls `repository.patientsForSelection(unitIds)` (sync; served from cached `/me/patients`). Polling tick re-fetches page 1 of `/me/patients` every 60s and replaces the cache. List view's trend/avg columns lazily fetch `/patients/{id}/activity?range=7d` per visible row via the new `_RowLoaderQueue` (max 5 concurrent) | `GET /me/patients` (paginated, all pages on init; page 1 only on poll); lazy `GET /patients/{id}/activity?range=7d` per list row |
| Patient Detail | `lib/facility_demo/screens/patient_detail_view.dart` | Fetches 3 endpoints in parallel via `Future.wait` on initial entry. Range tab change → refetch `/activity` only. Polling tick every 30s while visible. **Gait chart hidden** in live mode (L8). **6M tab hidden** in live mode (L4) | `GET /patients/{id}` + `GET /patients/{id}/activity?range={24h,7d,30d}` + `GET /patients/{id}/alerts?status=unacknowledged` |
| Device Detail | `lib/screens/device_screen.dart` (reused from legacy D2C path) | Receives `DeviceHealth` constructed from `/patients/{id}.currentDevice` + a follow-up `GET /devices/{serial}` for fields not on the patient response (firmware version, sensor model, exact battery mV, signal dBm). **Note:** `GET /devices/{serial}` doesn't exist in 2A-RD's endpoint list — see Open Question Q5 | `GET /patients/{id}` (already cached) + (probably) `GET /devices/{serial}` if Q5 resolves "yes" |
| Facility/Unit selector dropdown | `lib/facility_demo/widgets/facility_selector_dropdown.dart` | Data from `repository.allFacilities()` + `repository.allUnits()` — both sync, both derived from cached `/me/patients` response by collecting unique `facilityName` + `censusName` values | none — derived from cached `/me/patients` |
| Notification badge (Census tile + list row) | `lib/facility_demo/widgets/patient_tile.dart` + `lib/facility_demo/widgets/patient_list_view.dart` | In live mode, **bypasses** `notification_engine.dart` entirely. Badge count = `openAlertCount` from `/me/patients` response. Badge text = mapped from `alertType` of the most-recent unacked alert (requires per-tile lazy fetch of `/alerts?status=unacknowledged&limit=1` — or, more efficiently, augment `/me/patients` to include the most-recent alert type. See Open Question Q4) | `GET /patients/{id}/alerts?status=unacknowledged&limit=1` per row, OR augment-`/me/patients` per Q4 |
| Notification Review Panel | `lib/facility_demo/widgets/notification_review_panel.dart` | Renders alerts from the cached `/alerts` response on patient detail entry. **Ack action stays mock-bound in 2B-FAC-R** — wiring it to `PATCH /alerts/{patientId}/{ts}` is 2B-FAC-W | `GET /patients/{id}/alerts?status=unacknowledged` (shared with Patient Detail) |

#### New `LiveFacilityRepository` behaviors

Lives at `lib/data/live_facility_repository.dart`. Replaces the 2B-0 `UnimplementedError` stubs with real cache + fetch logic.

```dart
class LiveFacilityRepository implements FacilityRepository {
  final ApiClient _api;
  
  // Cache primed at shell init via _refreshMePatients(). Updated on poll
  // tick (page 1 only per L13). Cleared on signOut().
  MePatientsResponse? _mePatientsCache;
  
  // Per-patient detail caches, 30-second TTL per entry.
  final Map<String, _CachedPatientDetail> _detailCache = {};
  final Map<String, _CachedActivity> _activityCache = {}; // keyed by (patientId, range)
  final Map<String, _CachedAlerts> _alertsCache = {};
  
  // Lazy-row-fetch throttle (L5).
  final _RowLoaderQueue _rowQueue = _RowLoaderQueue(maxConcurrent: 5);
  
  // Census-level synchronous methods read from the cache.
  @override
  List<Facility> allFacilities() => _facilitiesFromCache();
  
  @override
  List<Unit> allUnits() => _unitsFromCache();
  
  @override
  List<PatientSummary> patientsForSelection(Set<String> unitIds) =>
      _patientSummariesFromCache(unitIds);
  
  // Per-patient methods become Future-returning; back the call with a
  // cache lookup + fetch-on-miss flow.
  @override
  Future<Patient> patientById(String id) async {
    final hit = _detailCache[id];
    if (hit != null && !hit.isExpired) return hit.patient;
    final resp = await _api.getPatient(id);
    final patient = _patientFromResponse(resp);
    _detailCache[id] = _CachedPatientDetail(patient, DateTime.now());
    return patient;
  }
  
  // ... similar pattern for activity, alerts, device, etc.
  
  // Polling entry points (called by Census + Patient Detail timers).
  Future<void> refreshCensus() { /* refetch page 1, replace cache */ }
  Future<void> refreshPatientDetail(String patientId) { /* parallel refetch */ }
  
  // Lifecycle.
  Future<void> primeAtSignIn() { /* fetch all pages of /me/patients */ }
  void clearOnSignOut() { /* drop everything */ }
}
```

**Important:** `_CachedActivity` stores raw API sessions (`List<ActivitySession>`); the on-demand `_groupByDate()` and `_bucketByHour()` adapters produce `DailyActivity` and `HourlyActivity` from those sessions per L7 — lazily on first call, cached after.

#### New polling mechanism

A new file `lib/state/polling_controller.dart`:

```dart
class PollingController extends ChangeNotifier {
  final WidgetsBindingObserver _observer;
  bool _isForeground = true;
  Timer? _censusTimer;
  Timer? _patientTimer;
  String? _activePatientId;
  
  // Census poll every 60s when foreground.
  void startCensusPolling(VoidCallback onTick) { ... }
  
  // Patient detail poll every 30s for a specific patientId.
  void startPatientPolling(String patientId, VoidCallback onTick) { ... }
  
  // Lifecycle wiring.
  void onAppLifecycleChanged(AppLifecycleState state) {
    _isForeground = (state == AppLifecycleState.resumed);
    if (!_isForeground) { _censusTimer?.cancel(); _patientTimer?.cancel(); }
    else { _restartTimers(); }
  }
}
```

#### `lib/api/api_client.dart` — wire the read methods

The 2B-0 stubs (`getMyPatients`, `getPatient`, `getActivity`, `getAlerts`) get real implementations that:
- Pass `cursor` query param when present
- Pass `range` query param for activity (`24h`/`7d`/`30d`)
- Pass `status` query param for alerts (`unacknowledged` etc.)
- Decode the response shape per 2A-RD §Response shapes (see umbrella + 2A-RD spec)

#### `lib/api/api_models.dart` — full response models

The 2B-0 placeholder classes (`MePatientsResponse`, `PatientDetailResponse`, `ActivityResponse`, `AlertsResponse`, `CensusRosterResponse`) get filled-out fields matching the 2A-RD response shapes verbatim (see 2A-RD spec §Response shapes for the JSON).

#### Default Census view = List (L10)

`FacilityShell` defaults to `view=list` when `BuildMode.isLive`. Demo build retains `view=tile` default. URL state takes precedence over either default if present.

#### Range toggle removes 6M in live mode (L4)

`TimeRangeToggle` widget (lib/widgets/time_range_toggle.dart) takes a new optional parameter `availableRanges: List<TimeRange>` — defaults to all 4 ranges in demo mode, restricted to `[day, week, month]` in live mode.

### Out of Scope (Deferred)

- **Alert acknowledgment** — `PATCH /alerts/{patientId}/{ts}` wiring is 2B-FAC-W
- **Care Note read/write** — `GET /patients/{id}.careNote` is on the 2A-UM-P response; rendering it on patient detail is 2B-FAC-W (because it's paired with the inline edit affordance which IS a write)
- **Pause Notifications visual indicator** — the paused-bell icon on tiles + countdown banner on patient detail; 2B-FAC-W (rendering depends on Patient.notificationsPaused which is set by 2A-UM-P writes)
- **Resident lifecycle dialog** — Add/Edit/Discharge/Replace/Discontinue UX is 2B-FAC-W
- **6M activity view** — UI element removed in V1 per L4; lands in a 2B follow-up once Phase 1C-full ships daily-rollup endpoints
- **Gait speed columns + chart** — suppressed per L8; pending firmware emission + 2A-RD response-shape extension
- **Pull-to-refresh affordance** — explicit user-initiated full refetch (all pages); 2B-POL
- **Cross-facility filtering** — multi-facility scope works for `client_admin` via `/me/patients` natural scoping but the dropdown UX for selecting subsets across facilities is 2B-POL
- **D2C single-walker dashboard** — refit of `lib/screens/dashboard_screen.dart` is 2B-D2C
- **WebSocket / SSE push** — polling is V1 per umbrella L12; push lands in Phase 2C
- **Activity export (CSV/PDF)** — out of V1 per user-needs §6
- **Patient compare view** — side-by-side trend charts; out of V1 per user-needs §6

## Architecture

### Infrastructure Changes

**None.** Phase 2B-FAC-R is pure-frontend per Phase 2B umbrella L16. No new AWS resources. No CDK deploys (except possibly extending `seed-2a-rd-test-data.py` for scale testing, which is a one-off script).

### Data Flow

**Initial load (Census):**

```
User signs in
  │
  ▼
AppShell mounts → primeAtSignIn() in LiveFacilityRepository
  │
  ▼
ApiClient.getMyPatients(cursor=null) → first page (50 patients)
  │ if response.nextCursor != null:
  ▼
ApiClient.getMyPatients(cursor=...) → page 2
  │ repeat until nextCursor == null
  ▼
LiveFacilityRepository._mePatientsCache = concatenated response
  │
  ▼
Census renders (List view, default) using sync repository methods
  │
  ▼ (rows scroll into viewport)
_RowLoaderQueue dispatches GET /patients/{id}/activity?range=7d (max 5 concurrent)
  │
  ▼ (each row's data lands)
Trend / 7-day-avg / today columns fill in; skeleton placeholder fades
  │
  ▼ (every 60s while foreground)
PollingController fires Census tick → refreshCensus() → refetch page 1
  │
  ▼
Cache replaces page 1 patients; Census widget tree rebuilds
```

**Patient Detail entry:**

```
User taps a patient tile / row
  │
  ▼
GoRouter pushes /patients/{patientId} → PatientDetailView mounts
  │
  ▼ (Future.wait — parallel, not serial)
┌── GET /patients/{id}          (Patient + currentDevice)
├── GET /patients/{id}/activity?range=24h
└── GET /patients/{id}/alerts?status=unacknowledged
  │ (all three land; max latency = max of the three, not sum)
  ▼
LiveFacilityRepository caches all three responses (30s TTL each)
  │
  ▼
PatientDetailView renders: header + today's activity tile + 3 trend charts +
                          notification panel + device status card
  │
  ▼ (every 30s while foreground)
PollingController fires Patient tick → refreshPatientDetail(patientId)
  │
  ▼ (range tab change)
Refetch only /activity with new range; other two reused from cache
```

### Interfaces

#### `FacilityRepository` — extended for FAC-R per L2

```dart
abstract class FacilityRepository {
  // Census-level (sync; backed by cache):
  List<Facility> allFacilities();
  List<Unit> unitsForFacility(String facilityId);
  List<Unit> allUnits();
  List<PatientSummary> patientsForSelection(Set<String> selectedUnitIds);
  
  // Per-patient (async; cache + fetch):
  Future<Patient> patientById(String patientId);
  Future<DailyActivity> todayFor(String patientId);
  Future<List<DailyActivity>> last7DaysFor(String patientId);
  Future<List<DailyActivity>> last30DaysFor(String patientId);
  Future<List<WeeklyActivity>> last6MonthsFor(String patientId);
  Future<DeviceHealth> deviceFor(String patientId);
  Future<NotificationContext> notificationContextFor(String patientId);
  Future<PatientRowStats> rowStatsFor(String patientId);
  
  // Lifecycle (new in FAC-R):
  Future<void> primeAtSignIn();
  Future<void> refreshCensus();
  Future<void> refreshPatientDetail(String patientId);
  void clearOnSignOut();
}
```

Demo's `FacilityMockData` updates: per-patient methods get `async` keyword + `return result;` (Future.value-equivalent shorthand). Lifecycle methods become no-ops. Census-level methods unchanged.

#### `ApiClient` — wire read methods

```dart
// 2A-RD (deployed; wired in FAC-R):
Future<MePatientsResponse> getMyPatients({String? cursor, String? clientId});
Future<PatientDetailResponse> getPatient(String patientId);
Future<ActivityResponse> getActivity(String patientId, ActivityRange range, {String? cursor});
Future<AlertsResponse> getAlerts(String patientId, AlertStatus status, {String? cursor});
Future<DeviceResponse> getDevice(String serial);
Future<CensusRosterResponse> getCensusRoster(String facilityId, String censusId, {String? cursor});
```

Implementations follow the same `_request()` plumbing 2B-0 shipped for `getMe()`.

#### Notification badge mapping (L6)

```dart
const Map<String, _AlertDisplay> _alertDisplayByType = {
  // 1C-slim behavioral alerts (deployed 2026-05-24)
  'no_activity_today':       _AlertDisplay('No activity today', AlertSeverity.critical),
  'below_typical_activity':  _AlertDisplay('Below typical', AlertSeverity.standard),
  'declining_trend':         _AlertDisplay('Declining trend', AlertSeverity.standard),
  
  // 1C-slim offline alerts
  'device_offline':          _AlertDisplay('Device offline', AlertSeverity.standard),
  'device_silent':           _AlertDisplay('Device silent', AlertSeverity.critical),
  
  // 1B-rev Threshold Detector alerts (deployed 2026-04-27)
  'battery_critical':        _AlertDisplay('Battery critical', AlertSeverity.critical),
  'battery_low':             _AlertDisplay('Battery low', AlertSeverity.standard),
  'signal_lost':             _AlertDisplay('Signal lost', AlertSeverity.standard),
  'signal_weak':             _AlertDisplay('Signal weak', AlertSeverity.standard),
  
  // Device-emitted (forward as-is for unknown types; falls back to "Alert" generic copy)
};
```

Severity drives badge color: critical = red (`AppTheme.statusAlert`), standard = amber (`AppTheme.statusWarning`).

## Implementation

### Files Changed / Created

> Asterisk (*) = file affects BOTH demo and live builds; must build cleanly in both modes after every change.

| File | Change | Description |
|---|---|---|
| `lib/data/live_facility_repository.dart` | Modified | Replace 2B-0 UnimplementedError stubs with cache + fetch logic per §Architecture. Add `primeAtSignIn`, `refreshCensus`, `refreshPatientDetail`, `clearOnSignOut` |
| `lib/data/facility_repository.dart` * | Modified | Convert per-patient methods to `Future<...>`-returning (L2). Add lifecycle methods (`primeAtSignIn`, `refreshCensus`, `refreshPatientDetail`, `clearOnSignOut`) |
| `lib/facility_demo/data/facility_mock_data.dart` * | Modified | Add `async` to converted method bodies (one-line per method); lifecycle methods are no-ops returning `Future.value(null)` |
| `lib/api/api_client.dart` | Modified | Replace UnimplementedError stubs with real implementations for the 6 read endpoints |
| `lib/api/api_models.dart` | Modified | Replace placeholder classes with full response models per 2A-RD §Response shapes |
| `lib/api/_session.dart` | New | Adapter from API `Session` payload → demo's `HourlyActivity` / `DailyActivity` models per L7 |
| `lib/state/polling_controller.dart` | New | Foreground-aware Timer for Census + Patient Detail polling (L3, L11) |
| `lib/state/app_state.dart` | Modified | Expose `PollingController` to descendants; mount `WidgetsBindingObserver` |
| `lib/shell/app_shell.dart` | Modified | Remove `_LiveFacilityShellStub`; mount FacilityShell for both modes. Call `repository.primeAtSignIn()` after sign-in |
| `lib/facility_demo/screens/facility_shell.dart` * | Modified | Wire foreground-aware polling via PollingController. Default `view=list` when `BuildMode.isLive` (L10) |
| `lib/facility_demo/screens/patient_census_view.dart` * | Modified | Lazy-per-row fetch via `_RowLoaderQueue` for trend/avg columns; tile + list views read same data; gait columns hidden in live mode (L8) |
| `lib/facility_demo/screens/patient_detail_view.dart` * | Modified | Replace synchronous repository reads with `Future.wait` of 3 parallel fetches; range tab change refetches activity only; gait chart hidden in live mode (L8); 6M tab hidden in live mode (L4) |
| `lib/facility_demo/widgets/patient_tile.dart` * | Modified | Notification badge uses alertType→display-name map in live mode; mock notification engine in demo mode |
| `lib/facility_demo/widgets/patient_list_view.dart` * | Modified | Same: alertType-based badges in live mode + gait columns hidden in live mode |
| `lib/facility_demo/widgets/notification_review_panel.dart` * | Modified | Render alerts from live `/alerts` response; no engine call in live mode |
| `lib/widgets/time_range_toggle.dart` * | Modified | New optional `availableRanges` parameter; live mode passes `[day, week, month]` |
| `lib/widgets/_row_loader_queue.dart` | New | Throttled async queue (max 5 concurrent) for lazy-per-row fetches (L5) |
| `pubspec.yaml` | Modified | Add `visibility_detector: ^0.4.0` for ListView viewport intersection callbacks |
| `lib/screens/device_screen.dart` * | Modified | If Q5 resolves "wire to /devices/{serial}", populate from live API; otherwise read from `/patients/{id}.currentDevice` (limited fields) |
| `infra/scripts/seed-2a-rd-test-data.py` | (Optional) Modified | Extend with `--scale` flag to seed N patients with synthetic activity for fan-out testing |
| `docs/specs/phase-2b-portal-integration.md` | Modified | Update 2B-FAC-R row in subset table to ✅ Deployed (when this lands) |
| `docs/specs/ARCHITECTURE.md` | Modified | §12 2B-FAC-R row to ✅ Deployed |

### Dependencies

**Prior phases that must be live before this phase deploys:**

- Phase 2A-RD ✅ (deployed 2026-05-23)
- Phase 1C-slim ✅ (deployed 2026-05-24) — provides the behavioral alertType values
- Phase 2A-0 ✅ (deployed 2026-05-17)
- Phase 2B-0 ✅ (deployed 2026-05-25) — provides ApiClient + AuthService + repository abstraction + hosting

**No external setup beyond what 2B-0 already requires.**

### Configuration

| Flag | Type | Default | Purpose |
|---|---|---|---|
| `LAZY_FETCH_CONCURRENCY` | `--dart-define` | `5` | Per L5 throttle; tunable per env without code change |
| `CENSUS_POLL_MS` | `--dart-define` | `60000` | Per L3 Census polling cadence |
| `PATIENT_POLL_MS` | `--dart-define` | `30000` | Per L3 Patient Detail polling cadence |
| `BUILD_MODE` | `--dart-define` | `demo` | (Phase 2B-0 L2) |
| `API_BASE_URL` | `--dart-define` | (required in live) | (Phase 2B-0 L13) |

## Testing

### Test Scenarios

| # | Scenario | Method | Expected Result | Status |
|---|----------|--------|-----------------|--------|
| T1 | Census loads with real patients | Sign in at `https://dev.portal.gosteady.co/` as `rd-caregiver@test.local`; navigate to `/census` (auto-redirect on root) | List view renders the patients scoped to caregiver's census (`cen_rd_a1` via seed data); columns: Name + Location + Notifications + Today's activity + 7d avg + trend + Steps today + Step trend + Gait (hidden) + Gait trend (hidden) | Pending |
| T2 | Tile view toggle | Click view toggle in top bar | Census re-renders as tile grid with notification badge + steps/active min per tile | Pending |
| T3 | Census polling refreshes data | Wait 60s on Census; observe network tab | New `GET /me/patients` (cursor=null) fires every 60s; no pagination on polls | Pending |
| T4 | Polling pauses when tab backgrounded | Open Census; switch to another tab; wait 2 min; switch back | No `/me/patients` calls during background; immediate refresh on tab regain | Pending |
| T5 | Patient detail loads with parallel fetches | Click patient tile/row; observe network tab | 3 concurrent requests fire: `/patients/{id}` + `/activity?range=24h` + `/alerts?status=unacknowledged`. All three complete in <500ms warm-cache | Pending |
| T6 | Range tab change refetches only activity | On Patient Detail, click 7D tab | Only `/activity?range=7d` fires; patient + alerts data reused from cache | Pending |
| T7 | Range tab toggle shows 24H / 7D / 30D only | On Patient Detail in live mode | Tab toggle has exactly 3 segments; no 6M tab | Pending |
| T8 | 24H bar chart buckets by hour | Patient with seeded activity at midnight-crossing session | Hours show correct bucketing per A4 (proportional split for partial-hour sessions) | Pending |
| T9 | 7D / 30D charts aggregate from sessions | Patient with 60 seeded sessions over 5 days | 7D chart shows 5 non-zero day bars; 30D shows 5 non-zero bars with 25 zero bars | Pending |
| T10 | Gait chart hidden in live mode | Patient Detail | Gait Speed chart section absent; surrounding cards reflow to fill space | Pending |
| T11 | List view gait columns hidden in live mode | Census list view | Gait Speed (3-day avg) + Gait Trend columns absent; other 9 columns visible | Pending |
| T12 | Notification badge shows rule-name copy | Patient with `below_typical_activity` alert (seed adds one) | Tile/row shows "Below typical" badge in amber; not just "1 alert" | Pending |
| T13 | Notification review panel renders alerts | Open Patient Detail for a patient with multiple alerts | Panel lists each alert with display name + severity color + timestamp; Ack button visible but inert (2B-FAC-W) | Pending |
| T14 | Lazy-per-row fetch throttle holds | Census with 50+ patients; scroll quickly | Network tab shows at most 5 concurrent `/activity?range=7d` calls; remaining rows show skeleton | Pending |
| T15 | Demo build still works after every commit | `flutter build web -t lib/facility_demo/main_demo.dart --dart-define=BUILD_MODE=demo` after each FAC-R commit | Builds clean; opening locally shows 10 mock patients with all 11 columns (incl gait) and 6M tab | Pending |
| T16 | facility_admin sees broader scope | Sign in as `rd-facadmin@test.local`; check Census | Patient list spans all censuses in `fac_rd_a` (per seed); Unit selector shows multiple options | Pending |
| T17 | Sign-out clears cache | Sign in, then sign out, then sign in as a different user | No cross-user data leak; new user's `/me/patients` populates fresh | Pending |
| T18 | Cursor pagination concatenates correctly | Seed 100+ patients; sign in | Census shows all 100+ patients (multiple `/me/patients?cursor=` calls under the hood); polling refetches only page 1 | Pending (extend seed) |
| T19 | Polling cadence cost | Run app for 1 hour with Census + Patient Detail open intermittently | Audit-event volume in CloudWatch matches A4 budget (~100 events/hour for active session) | Pending |

### Verification Commands

```bash
# Demo regression check (run before any push)
cd ~/Documents/gosteady-portal
flutter build web -t lib/facility_demo/main_demo.dart --dart-define=BUILD_MODE=demo
# → ✓ Built build/web

# Live build smoke
flutter build web -t lib/main.dart --dart-define=BUILD_MODE=live \
  --dart-define=API_BASE_URL=$(aws cloudformation describe-stacks \
    --stack-name GoSteady-Dev-Api --region us-east-1 \
    --query 'Stacks[0].Outputs[?OutputKey==`HttpApiUrl`].OutputValue' --output text)

# Deploy + smoke against real API
./tools/deploy-portal.sh
# Then visit https://dev.portal.gosteady.co/ and sign in
```

## Deployment

### Deploy Commands

```bash
# Per-commit deploy (same as 2B-0)
./tools/deploy-portal.sh
```

### Rollback Plan

- All changes frontend-only; `git revert` the merge commit
- S3 versioning is enabled on the hosting bucket → revert via `aws s3 cp s3://bucket/index.html?versionId=... s3://bucket/index.html` + CloudFront invalidation
- No DDB / Lambda / IAM changes to undo

## Decisions Log

| # | Decision | Alternatives Considered | Why This Choice |
|---|----------|------------------------|-----------------|
| D1 | Hybrid sync/async repository per L2 | (a) Full async cascade — convert every demo screen call site; (b) Stay fully sync — fetch + cache everything at shell init | (a) churns 25+ files of demo screens for no gain in demo behavior. (b) doesn't scale to per-patient detail data (would force a 200-patient × all-history fetch on every sign-in). Hybrid keeps the Census widget tree unchanged + makes per-patient I/O explicitly async |
| D2 | Polling, not push, in V1 (L3) | (a) WebSocket from API Gateway; (b) Server-Sent Events from a sibling Lambda; (c) Poll | Phase 2B umbrella L12 already locked polling. Push gets us nothing the caregivers will notice in V1 (their alerts are already actionable within ~1 min of arrival via the polling tick + the underlying 1C-slim's hourly cron). Push gets us Phase 2C-shaped infrastructure cost without a paying use case |
| D3 | Lazy-per-row activity fetch (L5) | (a) Single bulk fetch — server returns 11-column data per patient on `/me/patients`; (b) Eager fan-out on Census mount; (c) Lazy on viewport intersect | (a) requires a new 2A-RD response shape — out of FAC-R scope and not specced. (b) is the 200-call-instant problem in A2. (c) is the right pattern but needs the throttle (5 concurrent) + skeleton-placeholder UX |
| D4 | Remove 6M tab in live mode entirely (L4) | (a) Show disabled + "Coming soon" tooltip; (b) Hide entirely | (a) wastes screen real estate on a feature that has no ETA. (b) is honest. When 1C-full rollups ship, the 6M tab returns with real data |
| D5 | Hide gait UI in live mode (L8) | (a) Show placeholder values; (b) Show 0/0/0; (c) Hide entirely | (a) lies to caregivers. (b) shows wrong data. (c) is the honest answer until firmware + 2A-RD support gait per-session emission |
| D6 | Notification badges use 1C-slim alertType-mapped copy (L6) | (a) Counts only (umbrella interim); (b) Re-evaluate rules client-side; (c) Use server-authoritative alertType names | (a) underserves caregivers (less informative). (b) defeats audit + per-client-drift concerns from umbrella A3. (c) became possible the moment 1C-slim deployed (2026-05-24) |
| D7 | Caching with 30s TTL in LiveFacilityRepository (L12) | (a) Stateless wrapper around ApiClient; (b) Cache forever, invalidate on poll tick; (c) TTL-based | (a) makes lazy-fetch + parallel-detail-fetch repeat HTTP calls unnecessarily. (b) risks staleness if the user opens a new patient between polls. (c) is the standard pattern; TTL chosen below the polling cadence so the cache effectively serves the polling loop |
| D8 | Polling refetches page 1 only of `/me/patients` (L13) | (a) Full repaginate every tick; (b) Page 1 only; (c) Stale-while-revalidate the full set | (a) is 4× the API cost per tick at 200 patients. (b) trades freshness on the long tail for cost; the long tail is by-design less-active patients. (c) is complex; revisit if (b) causes UX complaints in pilot |
| D9 | `AppLifecycleState`, not Page Visibility API (L11) | (a) Flutter lifecycle hook; (b) Web Page Visibility API; (c) Focus events | (a) is standard Flutter; works the same on web + desktop. (b) is web-platform-only; would need a conditional import wrapper. (c) doesn't fire on tab switch within the same window |
| D10 | List view is default in live mode (L10) | (a) Tile (demo default); (b) List | user-needs §4.2 US-04 explicitly says "List view defaults on (data-dense scanning)." Demo's tile-default is right for investor visual showcase but wrong for production caregiver workflow |
| D11 | Per-screen build verification before every push (L1 / A7) | (a) Trust developer; (b) Manual checklist; (c) CI gate | (a) breaks the demo when someone forgets. (b) is what (a) becomes after the first incident. (c) is the eventual home (Phase 3B) but until then, manual discipline + a one-liner in the commit message ("verified both builds") is the convention |

## Open Questions

Per user direction: each open question gets my **lean / assumption** + **ELI5 impact** (what changes in user-visible behavior depending on the answer).

| # | Question | Lean / Assumption | ELI5 impact |
|---|---|---|---|
| Q1 | **Gait speed — defer to V1.1, or work around?** Firmware doesn't emit gait per-session; 2A-RD doesn't return gait fields. User-needs US-19 wants it. Options: (a) Hide gait UI in V1 (L8 current lean), (b) Derive an estimate from `distanceFt / activeMinutes`, (c) Push firmware to emit it now | **Lean: hide.** A simple derived estimate (`distance / time`) would be misleading because it averages walking + standing time within a "session" rather than reflecting true gait. Honest "no gait data" beats a wrong number. V1.1 adds gait emission to firmware (small fw change) + extends 2A-RD response | Caregivers won't see gait speed in V1 — one less clinical signal but every other column works. V1.1 fills it in once firmware + cloud both ship |
| Q2 | **Single bulk endpoint for Census 11 columns vs lazy-per-row?** Lazy (L5) is the current lean. The alternative would be a new `/me/patients?include=activity-7d` query param that bundles 7d activity into the list response | **Lean: lazy (L5) ships in FAC-R; bulk endpoint is a 2A-RD-follow-up if pilot pain demands.** Lazy is simpler, doesn't touch 2A-RD spec, and works for the common case. Bulk-include is a real optimization but adds DDB BatchGetItem complexity on the server | Caregivers see skeleton placeholders fill in row-by-row on cold-load (~1-2 sec for a 50-patient view); subsequent visits are warm-cache and instant. If 200+ patient facilities materially struggle, we add the bulk endpoint in a 2A-RD-follow-up |
| Q3 | **Cache TTL — 30s or shorter?** Per L12 currently 30s. Patient Detail polling is 30s, so cache effectively serves polling. But a user clicking between two patients within 5s would see warm cache for the second visit (potentially confusing if data changed) | **Lean: 30s ships.** Mid-day in a 200-patient facility there's no realistic scenario where a patient's data changes faster than the 30s polling cadence anyway — alerts fire on cron schedules, activity rolls in via session-close events | Caregivers see consistent data within a 30s window; explicit pull-to-refresh (2B-POL) gives a manual override when needed |
| Q4 | **Most-recent alert type on `/me/patients` list response — augment or per-tile lazy fetch?** Census tiles want to show "No activity today" badge text (not just count). Today's `/me/patients` returns `openAlertCount` only. Either: (a) augment 2A-RD to include `mostRecentAlertType` per row, (b) per-tile lazy `/alerts?status=unacknowledged&limit=1`, (c) show count-only + drill-in for detail | **Lean: per-tile lazy fetch with throttle (b).** Adding a field to 2A-RD response is out of FAC-R scope; we can avoid it by using the same lazy-fetch infrastructure from L5. Per-tile is one extra API call per visible patient (50 typical) batched through the throttle | Caregivers see the full rule name ("No activity today" — critical) on every tile, not just a count, with a brief skeleton while the per-tile alert fetch completes (~200ms warm). If pilot pain demands a single-call optimization, file as 2A-RD-follow-up |
| Q5 | **Device Detail screen — `GET /devices/{serial}` endpoint or rely on `/patients/{id}.currentDevice`?** The 2A-RD spec lists 5 endpoints; `/devices/{serial}` is NOT among them. The patient response includes `currentDevice.{serialNumber, status, lastSeen}` but NOT firmware version, battery mV, signal dBm, sensor model. The legacy `device_screen.dart` renders all of those | **Lean: simplify the Device Detail card in V1 — show only what's on `/patients/{id}.currentDevice`** (serialNumber, status, lastSeen). Full device diagnostics (firmware version, battery mV, signal dBm) need a 2A-RD-follow-up endpoint. Defer the full device-detail screen | Caregivers see "last seen" + "serial" + "status" on the patient detail card; tapping the card opens a slim device-info page rather than the legacy multi-field diagnostic. Full diagnostics return in a 2A-RD-follow-up if pilot demands them |
| Q6 | **Multi-page initial `/me/patients` fetch — show patients incrementally or wait?** L13 says concatenate-all-pages-then-render. Alternative: render page 1 immediately and append pages as they arrive | **Lean: wait for all pages (L13 current).** A 200-patient facility = 4 pages at 50/page = ~600ms total. Rendering incrementally would cause the list count to "tick up" visibly which is jarring; better UX is a brief skeleton then full render | Caregivers see a skeleton for ~1s on cold sign-in, then the full Census. If 200+ patient facilities feel slow, switch to incremental render in 2B-POL |
| Q7 | **Sign-out clears all caches — including across browser tabs?** L12 says clear on sign-out, but if the user has 2 tabs open and signs out in tab A, tab B might still hold stale data until its next poll | **Lean: accept tab B staleness; resolved on next poll tick (60s).** Cross-tab cache invalidation would require BroadcastChannel API or storage events — adds complexity for an edge case. The polling tick will catch it within 60s, and the API will 401 the polling request (token revoked at sign-out), which forces sign-out via the existing token-refresh-fail path | Caregivers with multiple tabs see a brief inconsistency window after sign-out (max 60s) before the inactive tabs auto-sign-out via failed token refresh. Documented; not a real-world concern at facility scale (caregivers use single-tab) |
| Q8 | **Audit cost — log every poll tick as `patient.list.read` / `patient.alert.read`?** Per Phase 1.7 D8 + 2A-RD audit hooks, every read emits an audit event. At 50 staff × 60s polls × 8hr shift = ~24k Census-poll events/day; with detail polls ~96k events/day. Phase 1.7 budget at MVP is ~10k events/day, busy Phase 2A ~100k | **Lean: throttle poll-tick audit events at the server side** in a 2A-RD-follow-up — emit one `patient.list.poll` event per minute-per-user instead of one per call. This subset ships expecting the unthrottled rate; if Phase 1.7's Firehose data-freshness alarm fires, the throttle becomes an immediate follow-up | Caregivers see no behavior change. Audit pipeline at 100k events/day costs ~$2-3/mo; at 1M events/day costs ~$20-30/mo. Tolerable at MVP; throttle ships if cost becomes load-bearing |
| Q9 | **Activity grouping by `date` field — server-computed or client-computed?** 2A-RD response includes a `date` field per session (facility-local date string per L7). This is server-computed. Alternative: portal computes from `sessionStart` timezone | **Lean: trust server.** The `date` field is in the API response specifically because facility timezone resolution is non-trivial (Patient.timezone denorm); duplicating that logic client-side is invitation to drift. Use the server's `date` verbatim | Caregivers see consistent date buckets matching server-side audit + alert timestamps; no DST surprises |
| Q10 | **Demo regression CI gate timing — block FAC-R completion or land later?** Per A7, every commit during FAC-R needs both builds to compile. Long-term that's a CI gate. Should the CI gate land in FAC-R or wait for Phase 3B? | **Lean: defer to Phase 3B (CI/CD).** Manual discipline + a one-liner ("verified both builds: ✓ demo ✓ live") in commit messages is the convention until 3B's GitHub Actions ship. Adding CI in FAC-R drags scope | Developers running FAC-R commits remember to flip BUILD_MODE before push. If someone forgets and breaks demo, we catch it within the day (someone visits facilitydemo.gosteady.co) and fix forward. Acceptable risk at MVP |

## Changelog

| Date | Author | Change |
|------|--------|--------|
| 2026-05-25 | Jace + Claude session | Initial draft. Locks in async strategy (hybrid sync/async, L2), polling cadence + lifecycle-paused (L3+L11), lazy-per-row fetch + throttle (L5), notification badge mapping per 1C-slim alertTypes (L6), 6M tab removal (L4), gait suppression (L8). 10 open questions tabled with lean + ELI5 impact per user direction |
| 2026-05-25 | Jace + Claude session | **Initial impl slice landed + deployed to dev.portal.gosteady.co.** Census + Patient Detail render real GS9999999998 walking sessions for `pt_bench_98`. Commits: `b2da2cc` (initial slice — ApiClient + LiveFacilityRepository + screen wiring), `ee7dac5` (seed-dev-pilot adds status_patientId composite GSI key — fixed empty /me/patients response), `4095e7e` (tolerant numeric decoders — patient-api returns Decimals as JSON strings), `89bd76f` (toToday sums all 24h sessions + local-hour bucketing + lastSeen fallback to max sessionEnd). Two cloud-side issues surfaced: CR-1 (Device Registry.lastSeen never written) — fixed in heartbeat-processor (coord §C28.1); CR-2 (UTC dates) — turned out to be stale data, no code fix needed (coord §C28.2). Portal-side workarounds retained as defensive backstop. Polling + lazy-per-row throttle + notification engine swap + TTL caching still pending — separate follow-up commits |

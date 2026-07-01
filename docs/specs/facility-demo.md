# GoSteady Facility Demo — Spec

> **Status:** Draft (2026-05-06) | **Branch:** `feature/facility-demo` | **Owner:** Jace
> **Target ship:** week of 2026-05-11 (investor / partner conference)

---

## 1. Purpose & audience

A self-contained Flutter web build that demonstrates what a `facility_admin`
sees when monitoring ~10 walker users distributed across two facilities. Shown
to investors and prospective partner facilities at a conference the week of
2026-05-11. Not deployed to a real customer; not connected to live AWS.

**Primary message we're trying to convey:** "GoSteady gives a facility leader
a single pane of glass for daily activity across all their residents,
filterable down to a specific unit, with one-click drill-down to a resident's
trends."

This spec also functions as a working draft of the Phase 2B (Portal
Integration) UI shape and, by extension, the response payloads Phase 2A's API
will need to emit. The mock data shapes here become the de-facto v0 of the
`GET /api/v1/facilities/{facilityId}/patients` and
`GET /api/v1/patients/{patientId}/activity` contracts.

---

## 2. Scope & non-goals

### In scope (this spec)
- Mock-auth login → facility-admin dashboard
- "Patient Census" home view: tile per patient with name + room + active
  minutes today + steps today
- Facility/Unit selector dropdown (nested-checkbox tree)
- Click a tile → patient detail panel with the existing single-walker
  dashboard's charts, scoped to that patient
- Master-detail split-pane on wide screens; overlay on medium; route push on
  narrow
- Static seed data for 2 facilities, 5 units, 10 patients

### Explicit non-goals (deferred — not in this spec, not in the conference build)
- Real Cognito wiring (mock auth only — investors don't sign up at booths)
- Alerts inbox / acknowledgement flow
- Animated or "live" updating data (no timer-driven step increments, no
  scripted tipover firing during the demo)
- Multiple roles — `caregiver` scope-limited view, `client_admin` cross-facility
  view, `household_owner` D2C view, etc. Demo is `facility_admin` only.
- Reports, exports, billing, settings, user management — out of scope
- Mobile-app responsive parity — wide-screen-first design; <768 viewport gets
  a usable fallback but is not the design target
- Dark mode

### Adjacent decisions deferred to actual Phase 2A/2B
- Per-walker threshold overrides UI
- Notification preferences UI
- Caregiver assignment / scope management
- Patient discharge / device retire flows
- Audit-log surfacing in the UI

---

## 3. Hierarchy & terminology

The architecture uses `Client → Facility → Census → Patient`. The conference
demo only ever exposes one Client (the facility-admin's), so Client never
appears in the UI.

**The word "Census" doesn't appear in the UI.** Census is industry jargon for
"unit / wing / floor"; investors and prospective partners outside senior-living
won't recognize it. The UI label is **Unit** throughout. Code-level entity
remains `Census` to match the data model in §6 of `ARCHITECTURE.md` and the
DDB tables (`gosteady-{env}-organizations` SK pattern
`facility#<id>#census#<id>`).

The mapping is enforced in one place — a `unitFor(censusId)` helper in
`lib/facility_demo/data/facility_seed.dart` — so renaming later is a one-line
edit.

---

## 4. Personas & seed data set

### 4.1 The signed-in admin

| Field | Value |
|---|---|
| Name | Dana Chen |
| Title | Director of Nursing |
| Role | `facility_admin` |
| `clientId` | `demo_client_001` |
| Scoped facilities | both (see below) |
| Avatar | initials in sage circle |

Shows in the top app bar's user chip. Sign Out logs out and returns to login.

### 4.2 Facilities & units

Two facilities, five units between them, evocative of the GTM channels named
in `ARCHITECTURE.md` §1 (memory care, assisted living, skilled nursing).
Names chosen to feel real but are not actual customers.

| Facility ID | Display name | Unit ID | Unit display | Patient count |
|---|---|---|---|---|
| `fac_whitestone` | Whitestone Senior Living | `cen_ws_memory` | Memory Care | 3 |
|  |  | `cen_ws_al_east` | Assisted Living — East | 2 |
|  |  | `cen_ws_al_west` | Assisted Living — West | 1 |
| `fac_cedar` | Cedar Crossing Skilled Nursing | `cen_cc_rehab` | Rehab Wing | 2 |
|  |  | `cen_cc_ltc` | Long-Term Care | 2 |

Total: 2 facilities, 5 units, 10 patients.

### 4.3 Patients

Selected to render visibly distinct profiles on the Census wall — high vs.
low activity, varied room labels, mix of male/female names, multi-cultural.
Demo deliberately includes one patient with zero today-activity (device
offline / not yet worn) so the wall doesn't look uniformly green.

| Patient ID | Name | Unit | Room | Today: steps / active min | Profile flavor |
|---|---|---|---|---|---|
| `pt_001` | Margaret O'Sullivan | Memory Care | 12A | 387 / 24 | Steady, average |
| `pt_002` | Robert Chen | Memory Care | 14B | 142 / 11 | Low — quiet day |
| `pt_003` | James Martinez | Memory Care | 17A | 0 / 0 | No data today (offline tile) |
| `pt_004` | Eleanor Park | AL — East | 203 | 894 / 47 | High — active resident |
| `pt_005` | Helen Anderson | AL — East | 207 | 521 / 32 | Above average |
| `pt_006` | Frank Kowalski | AL — West | 308 | 198 / 14 | Below average; declining trend |
| `pt_007` | Dorothy Williams | Rehab Wing | R-4 | 612 / 38 | Strong recovery |
| `pt_008` | Albert Rivera | Rehab Wing | R-7 | 445 / 28 | Recovering, mid-range |
| `pt_009` | Ruth Patel | Long-Term Care | 102 | 234 / 18 | Steady, low-baseline |
| `pt_010` | George Washington Jr. | Long-Term Care | 108 | 156 / 12 | Low; consistent |

Each patient also has consistent 7-day, 30-day, and 6-month history that
makes the trend chart on the detail panel render real-feeling shapes (see §7
on data generation rules).

---

## 5. Information architecture

### 5.1 Top-level layout (wide ≥1280px)

```
┌─────────────────────────────────────────────────────────────────────────┐
│  ☰  GoSteady          [All Units (10) ▾]              Dana Chen  ⏻      │  ← top bar 64px
├──────────────────────────────┬──────────────────────────────────────────┤
│  PATIENT CENSUS              │  PATIENT DETAIL                          │
│  ──────────────              │  (or empty state when no patient picked) │
│                              │                                          │
│  ┌──────────┐ ┌──────────┐   │  ┌──────────────────────────────────┐    │
│  │ tile     │ │ tile     │   │  │  reuses existing dashboard:       │    │
│  │ pt_001   │ │ pt_002   │   │  │  TodayCard + DeviceStatusBar +    │    │
│  └──────────┘ └──────────┘   │  │  TimeRangeToggle + 3 chart cards  │    │
│  ┌──────────┐ ┌──────────┐   │  │                                   │    │
│  │ tile     │ │ tile     │   │  └──────────────────────────────────┘    │
│  │ pt_003   │ │ pt_004   │   │                                          │
│  └──────────┘ └──────────┘   │                                          │
│  ...                         │                                          │
│                              │                                          │
└──────────────────────────────┴──────────────────────────────────────────┘
   ~30% width (min 380, max 520)    ~70% width (min 800)
```

When no patient is selected, the right pane shows an empty state ("Select a
resident from the census to see their activity"). When a tile is clicked, that
tile gains a sage outline + selected state, and the right pane swaps in the
patient detail.

### 5.2 Responsive breakpoints

| Width | Layout |
|---|---|
| ≥ 1280px | Side-by-side split as above |
| 768–1280px | Census tiles full-width by default; clicking a tile slides the detail in as a full-screen overlay with a "← Back to Census" affordance |
| < 768px | Full-screen route push (existing pattern) |

The conference will be a wide-screen projection — design effort optimizes
the wide layout. Medium and narrow are graceful fallbacks, not pixel-perfect
designs.

### 5.3 Top app bar

| Element | Behavior |
|---|---|
| Hamburger / logo | Sage accessibility icon + "GoSteady" wordmark. No menu in v1. |
| **Facility/Unit selector** | Pill-shaped trigger button. Label collapses to e.g. "All Units (10)" when everything is selected; "Memory Care, AL East (5)" when 2 selected; "Memory Care (3)" when 1 selected. Click opens the dropdown (§5.4). |
| Spacer | (flex) |
| User chip | Sage-bordered pill: small avatar circle + "Dana Chen" + role icon. Click → menu with "Sign out". |
| Sign-out icon | Direct shortcut next to the user chip (matches the existing dashboard header pattern). |

### 5.4 Facility/Unit selector dropdown

Anchored under the trigger button. Tree with two-level checkboxes:

```
┌─ Facilities & Units ──────────────────────────────┐
│  [Select all]                       [Clear all]   │
├───────────────────────────────────────────────────┤
│  ☑  Whitestone Senior Living           (3 units)  │
│      ☑  Memory Care                    (3 res.)   │
│      ☑  Assisted Living — East         (2 res.)   │
│      ☑  Assisted Living — West         (1 res.)   │
│  ☑  Cedar Crossing Skilled Nursing     (2 units)  │
│      ☑  Rehab Wing                     (2 res.)   │
│      ☑  Long-Term Care                 (2 res.)   │
└───────────────────────────────────────────────────┘
```

Behavior rules:
- Checking / unchecking a facility checks / unchecks all its units
- Partial selection within a facility shows the facility checkbox in the
  indeterminate state (`-`)
- The Census view filters live as checkboxes are toggled (no Apply button)
- Selection persists until logout (state lives in `FacilityMockData`)
- "Select all" / "Clear all" are convenience shortcuts only — not persisted as a
  separate preference

### 5.5 Patient Census tile

Tile dimensions: ~240×140px on wide; tiles flow into a 2-column grid in the
left pane (more if pane width allows). All four fields are required; no
configuration in v1.

```
┌────────────────────────────────────┐
│  Margaret O'Sullivan               │
│  Memory Care · Rm 12A              │
│                                    │
│  387 steps         24 min active   │
└────────────────────────────────────┘
```

Visual states:
- **Default** — white background, subtle border, sage hover
- **Selected** — sage border (~2px), faint sage background
- **No-data-today** (steps == 0 AND active == 0) — same layout, but the metrics
  row reads "No activity today" in muted text. No alert chip; this is just
  factual.

Open question for v1: should the tile show a battery / signal indicator?
Recommendation: **no, defer.** User said "just name, room/location, active min,
steps for now" — keep the tile clean. Battery/signal lives one click deeper on
the detail panel. (Easy to add later if conference feedback wants it.)

### 5.6 Patient Detail panel

Renders the existing single-walker dashboard, scoped to the selected patient.
Reused widgets (no rewrites needed for v1):

- `_Header` (date + signed-in user chip + Refresh) — but with a patient name
  shown prominently above it: "Margaret O'Sullivan · Memory Care · Rm 12A"
- `DeviceStatusBar` — battery, signal, last-seen
- `TodayCard` — gradient sage tile with active time + distance/steps
- `TimeRangeToggle` (24H / 7D / 30D / 6M)
- 3× `TrendChartCard` (Time in Motion full-width, Distance + Steps split)

The detail panel does NOT push a new route; it lives inside the facility
shell. The "back" affordance is "click another tile" or the empty state on
deselect. (On medium screens where the detail overlays, there's an explicit
Back button.)

The existing `DeviceScreen` (full device-detail drill-in) remains accessible
by clicking the `DeviceStatusBar` chevron — pushed onto a route as today.

---

## 6. Data model & mock client

### 6.1 New models (in `lib/facility_demo/models/`)

```dart
class Facility {
  final String id;          // 'fac_whitestone'
  final String displayName; // 'Whitestone Senior Living'
}

class Unit {                // code calls this 'Census' to match arch
  final String id;          // 'cen_ws_memory'
  final String facilityId;
  final String displayName; // 'Memory Care'
}

class Patient {
  final String id;                // 'pt_001'
  final String displayName;
  final String facilityId;
  final String unitId;            // -> Census ID
  final String room;              // '12A'
  final String? deviceSerial;     // null when no device assigned
  final PatientStatus status;
}

enum PatientStatus { active, discharged }

class PatientSummary {            // what the tile renders against
  final Patient patient;
  final int stepsToday;
  final int activeMinutesToday;
  final bool hasDataToday;        // false → tile shows "No activity today"
}
```

Existing `DailyActivity` / `HourlyActivity` / `DeviceHealth` reused unchanged
for the detail panel.

### 6.2 `FacilityMockData` surface

```dart
class FacilityMockData {
  List<Facility> allFacilities();
  List<Unit> unitsForFacility(String facilityId);

  /// All patients matching the current selection. The dropdown writes here.
  List<PatientSummary> patientsForSelection(Set<String> selectedUnitIds);

  /// Detail-panel data for a single patient.
  DailyActivity todayFor(String patientId);
  List<DailyActivity> last7DaysFor(String patientId);
  List<DailyActivity> last30DaysFor(String patientId);
  List<WeeklyActivity> last6MonthsFor(String patientId);
  DeviceHealth deviceFor(String patientId);
}
```

This intentionally mirrors what the eventual `ApiClient` will look like —
methods are scoped by patientId, not by device serial. (Matches Phase 0B-rev:
patient-centric PKs on Activity Series and Alert History.) When the real API
lands in Phase 2B, swapping `FacilityMockData` for `ApiClient` is a
constructor change.

### 6.3 Per-patient generation rules

For each patient, the seed data needs to feel real:
- **Today** — uses the same intensity-curve approach as existing
  `MockDataSource._intensityCurve`, but with a per-patient amplitude
  multiplier so totals match the table in §4.3
- **7-day history** — same intensity curve per day, with day-to-day variance
  (±25%); for `pt_006` (Frank, "declining trend") apply a linear decay so
  the chart visibly slopes down
- **30-day history** — same as 7-day, extended
- **6-month** — week-aggregated; mostly flat with the per-patient amplitude
  baseline

The existing `MockDataSource` stays — it serves the legacy single-walker
`DashboardScreen` (which we're not touching in this branch). `FacilityMockData`
is new and lives next to it.

### 6.4 Determinism

Seeded random per patient (`Random(patientId.hashCode)`) so that across page
reloads and investor-to-investor demos, the data looks the same. Critical
for the conference — we want the same shapes every time.

---

## 7. Code organization

```
lib/
  facility_demo/
    main_demo.dart              # entry point for the demo build
    data/
      facility_seed.dart        # the constants from §4 (facilities, units, patients)
      facility_mock_data.dart   # FacilityMockData implementation
    models/
      facility.dart
      unit.dart
      patient.dart
    screens/
      facility_login_screen.dart      # mock auth, single button
      facility_shell.dart             # the master-detail layout
      patient_census_view.dart        # left/main pane
      patient_detail_view.dart        # right/overlay pane (wraps existing dashboard)
    services/
      mock_facility_auth.dart   # FacilityMockAuthService — no Cognito
    state/
      facility_selection.dart   # ChangeNotifier holding selected unit IDs + selected patient
    widgets/
      facility_selector_dropdown.dart
      patient_tile.dart
      facility_top_bar.dart
```

`lib/facility_demo/main_demo.dart` is a separate entry point. The default
`flutter build web` continues to build the existing single-walker portal
(important for keeping that branch buildable). Build command for the demo:

```bash
flutter build web -t lib/facility_demo/main_demo.dart
```

The demo build's `index.html` lives in a separate output dir
(`build/web-facility-demo/`) so we don't trample the existing build.

---

## 8. Reuse map

| Existing widget | Demo usage | Modification needed |
|---|---|---|
| `lib/widgets/activity_timeline.dart` (`TrendChartCard`, `ChartMetric`) | Inside Patient Detail panel | None |
| `lib/widgets/distance_card.dart` (`TodayCard`) | Inside Patient Detail panel | None |
| `lib/widgets/device_health_card.dart` (`DeviceStatusBar`) | Inside Patient Detail panel | None |
| `lib/widgets/time_range_toggle.dart` (`TimeRangeToggle`) | Inside Patient Detail panel | None |
| `lib/screens/dashboard_screen.dart` (`DashboardScreen`) | Refactored into a `PatientDashboard(patient: ...)` widget that the Patient Detail panel embeds | Extract the body of `DashboardScreen` into a parameterized widget. The standalone screen wrapper stays for the legacy single-walker entrypoint. |
| `lib/screens/device_screen.dart` (`DeviceScreen`) | Pushed as a route from inside the Patient Detail panel's `DeviceStatusBar` chevron | None |
| `lib/theme/app_theme.dart` | All facility-demo screens | None |
| `lib/models/activity.dart`, `lib/models/device.dart` | Shared with demo data layer | None |
| `lib/data/mock_data.dart` (`MockDataSource`) | Untouched — serves the existing single-walker dashboard only | None |
| `lib/services/auth_service.dart` (Cognito) | Untouched in demo build (mock auth used instead). Real auth stays around for future Phase 2B work. | None |

**Net new file count:** ~12 files in `lib/facility_demo/`. **Net modification of
existing code:** one extraction in `dashboard_screen.dart` to make the body
parameterizable on a patient. Everything else is purely additive.

---

## 9. Mock auth for the demo

`FacilityMockAuthService` mirrors the public surface of the real `AuthService`
(`init()`, `signIn()`, `signOut()`, `currentUser`, `isSignedIn`,
`addListener` / `removeListener`) so that screens written against it will
trivially swap to `AuthService` later.

Login screen for the demo build is stripped down:
- Same GoSteady wordmark + Fraunces typography
- Single "Sign in to demo" button that logs the user in as Dana Chen
  (`facility_admin`, `clientId: demo_client_001`)
- No email/password fields, no signup link, no MFA, no error states

This is the entire concession — the Cognito-wired login screen on
`feature/auth-flow` is not used in the demo build at all. The real login UX
work continues independently in Phase 2B.

---

## 10. Open decisions before implementation

1. **Facility names** — "Whitestone Senior Living" and "Cedar Crossing Skilled
   Nursing" are placeholders. Want anything else? Real-feeling, neutral, no
   collision with any actual customer pipeline names.
2. **Patient names** — same; the 10 in §4.3 are placeholders intended to feel
   varied (multicultural, age-appropriate). Any swaps?
3. **The signed-in admin name** — "Dana Chen, Director of Nursing." Want a
   different name / title?
4. **Unit count badge** — the dropdown shows "(3 res.)" per unit. Is that the
   right label? Alternatives: "3 patients", "3 residents", "3 walkers." Going
   with "residents" matches senior-living lingo and reads right for facility
   admin audience.
5. **Empty state copy** — when no patient is selected on the right pane: "Select
   a resident from the census to see their activity." OK, or want softer copy?
6. **Tile layout on no-data-today** — current spec says the tile reads
   "No activity today" in muted text. Alternative: leave the metrics empty
   (just `— steps · — min active`). The first is clearer for the audience;
   confirm.

---

## 11. Branch & ship plan

| Step | Output | Status |
|---|---|---|
| 0 | Spec doc reviewed and approved | ✅ 2026-05-06 |
| 1 | Cut `feature/facility-demo` from `feature/infra-scaffold` post-merge | ✅ HEAD `7805127` |
| 2 | Commit this spec to `feature/facility-demo` | ✅ `d475644` |
| 3 | Scaffold `lib/facility_demo/` directory + `main_demo.dart` empty entrypoint | ✅ |
| 4 | `FacilityMockData` with seed patients (data-only, no UI) | ✅ |
| 5 | `FacilityShell` + Patient Census view (no detail panel yet) | ✅ |
| 6 | Facility/Unit selector dropdown wired to selection state | ✅ |
| 7 | Patient Detail panel — extract `DashboardScreen` body, scope to selected patient | ✅ |
| 8 | Mock auth + login screen | ✅ |
| 9 | Pixel polish + responsive breakpoints | ✅ phone/tablet/desktop verified |
| 10 | Build + test on conference-grade resolution; final dry-run | ✅ |

### Iterations after the initial implementation

| Date | Commit | What landed |
|---|---|---|
| 2026-05-06 | `65b797d` | Switched layout from master-detail split-pane to full-grid census + overlay-on-click pattern |
| 2026-05-06 | `f012b4a` | Three notification rules (No activity today / Below typical / Declining trend) + Sort/Filter dropdowns + Notification Review panel with Acknowledge + Save Note |
| 2026-05-06 | `14278ac` | Uniform tile heights regardless of notification presence |
| 2026-05-06 | `65f82d7` | Tile caption shows specific notification label rather than count |
| 2026-05-06 | `beb47df` | Replaced separate dismiss + send buttons with one "Acknowledge + Save Note" action |
| 2026-05-08 | `b3d0cd8` + `b739028` | Gait-speed chart added; cleaner range/avg summary chip; tooltip restructured to avg / min / max stacked |
| 2026-05-08 | `0761175` + `83783b4` | Full mobile + tablet responsive pass — `?w=NUMBER` URL viewport override for autonomous testing, top-bar collapse, full-bleed phone overlay, stacked Acknowledge button, tile dedupe |
| 2026-05-08 | `46717e3` | `dart format` cleanup |
| 2026-05-08 | `8f63d1b` | First deploy: GitHub Pages at `jabl1629.github.io/GoSteadyPortal/` (later replaced) |
| 2026-05-18 | `901f3de` | Migrated deploy target to `gosteady.co/facilitydemo` (Netlify subdir of marketing site). `tools/deploy-demo.sh` now drops build into `Jabl1629/GoSteadyWeb` under `facilitydemo/` and pushes. |
| 2026-05-18 | `4bbc671` | Patient Census gets a Tile/List view toggle. New `PatientListView` is an 11-column table — Resident · Location · Alerts (7d) · Needs review · Active today/7d/30d · Steps today · Step trend · Gait (3d) · Gait trend. Severity-coded notification cells; colored trend arrows with %-delta tooltips. Rows clickable → same patient overlay as the tile view. Sort + filter apply to both views. |

---

## 12. Deploy

### Live URL
**https://gosteady.co/facilitydemo/**

Served as a `/facilitydemo` subdirectory of the marketing site (Netlify),
not a standalone deploy. The build artifacts live in
[`Jabl1629/GoSteadyWeb`](https://github.com/Jabl1629/GoSteadyWeb) under
`facilitydemo/` on `main`; Netlify auto-deploys on push.

No auth at the page level — the demo's "Sign in to demo" button is mock auth
that always succeeds.

### How re-deploy works

```bash
./tools/deploy-demo.sh                # build + commit + push
./tools/deploy-demo.sh --skip-push    # build + commit, hold the push
./tools/deploy-demo.sh --build-only   # build only, no GoSteadyWeb changes
```

The script:
1. Runs `flutter build web -t lib/facility_demo/main_demo.dart --base-href /facilitydemo/`
   into `/tmp/portal-build-out/` (keeps the build/ folder out of the
   iCloud-synced primary checkout).
2. Replaces `$WEB_REPO/facilitydemo/` (default `~/Documents/GoSteadyWeb/facilitydemo/`)
   with the new artifacts.
3. Stages only the `facilitydemo/` subtree (won't touch other working-tree
   changes in GoSteadyWeb), commits with a message referencing the source
   `feature/facility-demo` SHA, and pushes `origin/main`.

Netlify picks up the push within ~30–60 seconds.

Override the GoSteadyWeb location with `WEB_REPO=/path/to/checkout
./tools/deploy-demo.sh` if your clone lives elsewhere.

### Why not GitHub Pages

The earlier setup served the demo from
`https://jabl1629.github.io/GoSteadyPortal/` via the `gh-pages` branch of
this repo. That branch is no longer the source of truth and may be deleted
or left stale. Using the gosteady.co subpath keeps everything under one
domain (better for sharing the link with partners, and aligns with the
eventual Phase 3A production URL `portal.gosteady.co`).

---

## 13. What this spec is NOT

- Not a Phase 2A spec. The mock data shapes here are **draft input** to Phase
  2A's API contract design. Anything that locks in here gets reviewed when
  Phase 2A is actually written.
- Not a Phase 2B spec. The demo establishes the visual + interaction patterns
  for the facility view; the real Phase 2B will swap mocks for live API and
  add the deferred features (alerts inbox, role-aware navigation, etc).
- Not Phase 3A. Phase 3A is the production hosting story (S3 + CloudFront +
  WAF + ACM cert at `portal.gosteady.co`). GitHub Pages is just for the demo.

---

*See [`ARCHITECTURE.md`](ARCHITECTURE.md) for the full system architecture and the
hierarchy / multi-tenancy model this demo simplifies. For the consumer / household
counterpart, see [`d2c-userdemo.md`](d2c-userdemo.md) (live at `gosteady.co/userdemo/`).*

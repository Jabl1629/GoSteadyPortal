# Phase 2B — Portal Integration

## Overview
- **Phase**: 2B (umbrella; ships as five subsets per §Scope)
- **Status**: 🔲 Planned (this spec is the initial draft)
- **Branch**: TBD (likely `feature/2b-portal-integration` cut from `feature/infra-scaffold`)
- **Date Started**: TBD
- **Date Completed**: TBD

Replaces the Flutter portal's mock data with live AWS-backed reads + writes. By the end of this phase a real caregiver at a real facility can sign in with email + password, see every resident they're authorized for with today's activity + trend + gait + alert state pulled from DynamoDB, drill into a resident's trends + device-health, acknowledge alerts, edit care notes, pause notifications, and run the resident-lifecycle actions (Add / Edit / Replace Device / Discontinue Device / Discharge) end-to-end against the live API. This is the **bridge from "the cloud knows the truth" (Phases 1B-rev / 1.6 / 1.7 / 2A-0 / 2A-DL / 2A-RD / 2A-AA) to "the caregiver can act on the truth."**

Per the user-needs doc, V1 is the **facility surface** for senior-living and SNF staff. All authorized facility users share the same "Care Staff" permission set; role-gating (V2), family viewer (V3), notifications-out-of-app (V2/V3), and audit-log UI (V2) are explicitly deferred. The D2C household-owner surface is reachable through the same auth model but is a smaller follow-on screen-set and lives in its own subset.

The existing facility demo at [`gosteady.co/facilitydemo`](https://gosteady.co/facilitydemo/) is the **functional mockup** for ~90 % of the V1 facility UI. The demo's `FacilityMockData` surface (see [`facility-demo.md`](facility-demo.md) §6.2) was deliberately shaped to mirror the eventual `ApiClient`; swapping mocks for live calls is largely a constructor-swap plus per-call wiring. The user-needs doc adds three things the demo doesn't yet render — Care Note (US-44), Pause-Notifications visual indicators (US-31), and the responsive list-view tooltip set (US-11) — those land in 2B-FAC-W alongside the lifecycle writes.

## Sub-phase split

Phase 2B is broken into five subsets that ship independently on a shared foundation. Each subset is a one- or two-week sprint rather than a multi-week monolith. Cloud-side dependencies are called out per subset.

| Subset | Status | Ships | Cloud-side dep |
|---|---|---|---|
| **2B-0** Foundation | 🔲 Planned | `ApiClient`, real Cognito auth in Flutter (sign-in / sign-out / token refresh / session restore), full-claim `GoSteadyUser`, JWT-attached HTTP client, error-envelope decoder, retry + backoff, network-failure UX, MFA challenge handler, forgot-password flow. **One smoke screen** — calls `GET /api/v1/me` and displays the claims (parallels 2A-0's stub-endpoint smoke approach) | 2A-0 (deployed) |
| **2B-FAC-R** Facility Reads | 🔲 Planned | Login → Facility Shell → Census (list + tile) → Patient Detail (overlay) → Device Detail. Pure-read swap of the demo's `FacilityMockData` for `ApiClient` against 2A-RD endpoints. Notification badges driven by `/patients/{id}/alerts?status=unacknowledged`. Visual mirror of the demo, real data | 2A-RD (deployed) + 2A-0 |
| **2B-FAC-W** Facility Writes | 🔲 Planned | Notification acknowledge (PATCH /alerts) + Care Note (US-44) + Pause Notifications (US-31) + Resident Settings lifecycle (Replace Device / Discontinue Device / Edit Info / Discharge) + Add Resident. **ALL BACKEND ENDPOINTS NOW DEPLOYED (as of 2026-05-24)** — 2A-AA + 2A-DL + 2A-UM-P all live in dev | 2A-AA + 2A-DL + 2A-UM-P (all ✅ deployed dev) |
| **2B-D2C** Household Path | 🔲 Planned | Refit `lib/screens/dashboard_screen.dart` + `lib/screens/device_screen.dart` (the legacy single-walker D2C dashboard) to consume live API. Single-patient view; smaller surface than facility | 2A-RD (deployed) + 2A-UM (for household_owner-specific signup/setup flow) |
| **2B-INT** Internal-tier UI additions | 🔲 Planned (low priority) | **Role-conditional UI surface inside the unified portal** (per L1). When `custom:role` starts with `internal_`, render extra navigation: cross-tenant patient search, cross-tenant device search, optional audit-reader UI. No separate build, no separate URL — same `portal.gosteady.co`, different conditional nav | 2A-INT (planned) + 1.7.1 (Athena workgroup if audit search wanted) |
| **2B-POL** Polish | 🔲 Planned | Responsive QA across 390 / 430 / 744 / 1024 / 1280+; WCAG AA contrast audit; keyboard navigation + focus-ring polish; screen-reader labels on gear, badges, chart tooltips; loading/empty/error state pass; column-header tooltips (US-11) | none |

**Ship order:** 2B-0 → 2B-FAC-R → 2B-FAC-W (with 2A-UM ahead of or alongside the write surfaces) → 2B-POL fold-in. 2B-D2C runs in parallel after 2B-0 (different screens, same `ApiClient`). 2B-INT is a separate build that can land any time after 2A-INT.

**Dependency on 2A-0 (foundation):** 2B-0 assumes the API Gateway HTTP API, JWT authorizer, error envelope, audit middleware, and CORS preflight (`localhost:8080` + `localhost:8090` allowed in dev) are deployed and stable. No expected drift.

**Dependency on 2A-UM (gates 2B-FAC-W writes that aren't already covered by 2A-DL or 2A-AA):** **AS OF 2026-05-24, ALL UNBLOCKED VIA 2A-UM-P DEPLOY.** Table below kept for reference.

| User story | Endpoint needed | Status | In 2A-UM scope? |
|---|---|---|---|
| US-26 Acknowledge notification | `PATCH /alerts/{patientId}/{ts}` | ✅ 2A-AA deployed | — |
| US-28 Add Resident | `POST /patients` | ✅ 2A-UM-P deployed 2026-05-24 | Yes — landed in 2A-UM-P |
| US-29 Edit Resident Info | `PATCH /patients/{id}` (name / room / censusId) | ✅ 2A-UM-P deployed | Yes — landed in 2A-UM-P |
| US-30 Cross-facility transfer | Same as US-29 (censusId change → new facility); requires `client_admin+` per Q3 | ✅ 2A-UM-P deployed | Yes — landed in 2A-UM-P |
| US-31 Pause Notifications | `POST /patients/{id}/notifications/pause` + `DELETE …` | ✅ 2A-UM-P deployed (+ Activity Processor auto-resume on activity) | Yes — landed in 2A-UM-P |
| US-32 Discharge Resident | `POST /patients/{id}/discharge` (cascades via Phase 2A-DL discharge-cascade Lambda already deployed) | ✅ 2A-UM-P deployed | Yes — landed in 2A-UM-P |
| US-35 Replace Device | 2A-DL `end-assignment` + `provision` chain | ✅ 2A-DL deployed | — (orchestrated client-side) |
| US-36 Discontinue Device | 2A-DL `end-assignment` | ✅ 2A-DL deployed | — |
| US-44 Care Note (read + write) | Read via extended `GET /patients/{id}` response (2A-RD); write via `PATCH /patients/{id}/care-note` (2A-UM-P) | ✅ 2A-UM-P deployed | Yes — landed in 2A-UM-P |

The 2A-UM spec doesn't exist yet (per [ARCHITECTURE.md](ARCHITECTURE.md) §17 — "🔲 Planned (no spec)"). Two of the six user-needs items above (US-31 Pause Notifications, US-44 Care Note) are **new requirements that emerged from the user-needs prep** and were not on 2A-UM's prior implicit scope. Whether 2A-UM picks them up or whether they ship as a follow-on `2A-UM-NN` (notifications) subset is an open question — see §Open Questions Q6.

---

## Locked-In Requirements
> Decisions finalized in this or prior phases that CANNOT change without cascading impact.

| # | Requirement | Decided In | Rationale |
|---|-------------|-----------|-----------|
| L1 | **One portal, one URL, one Flutter build, one Cognito App Client** (no client secret). All users — `caregiver` / `facility_admin` / `client_admin` / `household_owner` / `family_viewer` / `internal_support` / `internal_admin` — sign in at the same URL (`portal.gosteady.co` in prod). Role-specific UI affordances (internal cross-tenant search, audit-reader nav) appear at runtime based on the `custom:role` JWT claim. The Portal-Internal Cognito client (`gvc7n839vj4ppgioamknlk21c`, has secret) is **retired from browser use** and reserved for non-browser internal tools (CLI, server-side admin scripts) | This spec — Q8 decided 2026-05-23 | The security boundary is the JWT claim, not the URL. Pre-Token Lambda enforces MFA + claim injection + tenancy regardless of which client authenticated, and API Gateway 403s any caller whose role doesn't authorize the endpoint — so a unified-build customer never gets data they shouldn't, regardless of whether they discovered an internal endpoint name by inspecting the JS bundle. Matches [ARCHITECTURE.md](ARCHITECTURE.md) §4's stated stance ("internal access is allowed but always visible to compliance") rather than the obscurity-layer the dual-client approach baked in. **Requires a 2A-0 follow-up amendment**: the JWT authorizer's `audience` list narrows from two clients to one (see §Open Questions Q8 + implementation note) |
| L2 | Auth via `amazon_cognito_identity_dart_2` (SRP USER_PASSWORD_AUTH flow). Existing `lib/services/auth_service.dart` extended — not replaced — so the demo's `FacilityMockAuthService` swap pattern works. **MFA challenge handling shipped in 2B-0** (today's code throws on `CognitoUserMfaRequiredException` — see [auth_service.dart:59](../../lib/services/auth_service.dart#L59)) | 2A-0 L4 (Pre-Token Lambda injects claims into ID + Access tokens) + Phase 0A-rev D5 (TOTP only) | Pre-Token Lambda enforces MFA per-role; facility_admin + client_admin + all `internal_*` cannot sign in without `mfa_enrolled=true`. Flutter must handle the TOTP setup + verify challenge or those roles can't reach the portal |
| L3 | Custom JWT claims (`custom:clientId`, `custom:role`, `custom:facilities`, `custom:censuses`, `custom:mfa_enrolled`) consumed from the ID token's payload at sign-in and stored on `GoSteadyUser`. Token refresh re-extracts in case server-side scope changed (e.g., admin reassigned the user's censuses) | Phase 0A-rev D2 + 2A-0 L4 | Same claims drive (a) which API endpoints to call, (b) which screens render, (c) the role badge in the top bar |
| L4 | `ApiClient` is the single HTTP gateway. All endpoints in `lib/api/api_client.dart`. Constructor takes `AuthService` (for token attachment) + `baseUrl` (from `--dart-define=API_BASE_URL=`). No HTTP from any widget directly. **Dev** sets `API_BASE_URL` to the dev API Gateway URL; **prod** sets it to `/api/v1` (relative) per [phase-3a-portal-hosting.md](phase-3a-portal-hosting.md) L1 same-origin reverse-proxy decision | This spec + 3A L1 | Centralized retry / refresh / error decoding / audit-failure telemetry; one place to inject mocks for tests; one place to swap `FacilityMockData` for live. Same-origin in prod eliminates CORS preflights and keeps the future-HttpOnly-cookie path open |
| L5 | Error envelope handled at `ApiClient` level. `{error: {code, message, details}}` → typed `ApiException(code, message, details, httpStatus)`. Widgets catch typed exceptions and render code-specific copy — no raw HTTP errors leaked to UI | 2A-0 L7 (error envelope contract) | Flutter UI needs structured codes (per 2A-0 spec); also means a single SnackBar + retry pattern in `ApiClient` rather than per-call boilerplate |
| L6 | Token refresh: opportunistic on every API call when ID token is within 60 s of expiry. Failure → forced sign-out + return to login. **Sliding 15-min idle** (Portal-Customer Cognito App Client) preserved by the Cognito SDK's session management | Phase 0A-rev token-lifetime config | 60 s buffer absorbs clock skew + network latency. Forced sign-out on refresh fail is the safest semantic — a stale token would silently 401 every call |
| L7 | Token storage: ID + refresh tokens via `amazon_cognito_identity_dart_2`'s SDK-internal storage (currently SharedPreferences). **No PII in URL parameters or query strings** (per user-needs §5 Privacy). Patient IDs and serials are in path params (acceptable per 2A-RD spec); no `displayName` or other PII anywhere in the URL | user-needs §5 Privacy | URL params are logged in access logs (2A-0 L10) and browser history; PII in either is a leak. Path params are intentional (`/patients/{id}`); query params (`?range=`, `?cursor=`, `?status=`) are not patient-identifying |
| L8 | Cursor pagination + ranges: client round-trips `nextCursor` opaque token; range param ∈ `{24h, 7d, 30d}` (per 2A-RD L6/L7). **6M view (US-18)** is rendered client-side from rolled-up data once Phase 1C ships; until then 6M tab is **disabled with a tooltip** ("Coming with v1.1 — historical rollup") | 2A-RD L6 + L7 | The demo's `last6MonthsFor()` data shape is precisely what a Phase 1C rollup endpoint will return; the rendering code stays, only the data source flips |
| L9 | "Today" boundary uses **facility local time** (resolved server-side from Patients.timezone, returned in `windowStart` / `windowEnd` on `/activity?range=24h`). Browser timezone is NEVER used to compute "today" | user-needs §7 #7 + §5 Data freshness | A shift-handoff in a CA facility shouldn't see a different "today" in the portal vs. on the floor when viewed from a different timezone |
| L10 | Device serial format `GS` + 10 digits, field-level regex validation on every form field accepting a serial. Reject paste of non-conforming input with inline error before submit | user-needs §7 #8 + US-28 / US-35 | Catches typos before the API does; single place to enforce the format end-to-end |
| L11 | Census filter, sort, view-mode (list/tile), and selected unit IDs persist **in URL query string** (not localStorage), so a page reload restores state and a shared link works. Patient drill-down is a path segment (`/patients/{id}`) — survives reload, shareable across staff | user-needs §5 Reliability + Privacy | Per user-needs §5, "refreshing returns the user to the same Census state." URL-as-state is the simpler implementation; localStorage adds cross-tab drift risk. **No PII in URL** still holds: unit IDs and patient IDs are opaque, not patient-identifying alone |
| L12 | Real-time updates: **client-side polling only in V1**. Census polls `/me/patients` every 60 s (or on focus); Patient Detail polls `/patients/{id}/activity?range=24h` + `/patients/{id}/alerts?status=unacknowledged` every 30 s while focused. **No WebSocket / SSE in V1** — push delivery lands in Phase 2C alongside email digests | This spec — Q3 decided | Polling at this cadence is well within API Gateway throttling (dev: 25 RPS sustained — a facility with 50 caregivers polling once / 60 s is ~0.83 RPS). Push gets us nothing the caregivers will notice in V1 (their alerts are already actionable within 1 min of arrival); push gets us Phase 2C-shaped infrastructure cost without a paying use case |
| L13 | Single Care Staff role in V1 — every signed-in facility user sees the same UI affordances. The `custom:role` claim is consumed for the role badge but does NOT gate any UI elements yet. **The architectural guardrails for the V2 role split are preserved**: the `family_viewer` role flag (`isCaregiver` legacy + `family_viewer`-emitting Pre-Token path) lives in `GoSteadyUser` even though no UI renders it differently | user-needs §7 #1 + §5 Forward Compatibility | Avoids premature complexity; V2 layer-in is cheap because the data model already supports per-role scoping (every API call is server-side authz'd, regardless of what UI sent it) |
| L14 | Audit log on lifecycle actions emitted **server-side, by 2A-DL / 2A-AA / 2A-UM handlers**. The client does NOT emit audit events directly. Failed-write UX surfaces a retry; no client-side workaround for an audit-stack outage | user-needs §5 Auditability + Phase 1.7 architecture | Single source of truth (the server); client-side audit is forgeable and unnecessary. Phase 1.7's middleware (2A-0 L6) auto-stamps every server mutation |
| L15 | Build artifacts hosted at Phase 3A (S3 + CloudFront + WAF + `portal.gosteady.co`). For 2B development, builds run locally (`flutter run -d chrome -t lib/main.dart --dart-define=API_BASE_URL=https://<api-gw-url>`) — same CORS origin already allow-listed by 2A-0 (`localhost:8080`). **No production deploy from 2B** | 2A-0 Q4 + 2A-0 L9 + ARCH §12 Phase 3A | 2B is the "dev-ready" milestone; production exposure waits on 3A hosting + WAF + CloudFront cache + custom domain + ACM cert |
| L16 | Phase 2B does NOT introduce any new DDB tables, GSIs, or backend infra beyond what 2A-UM (sibling, not part of 2B) requires. 2B is pure-frontend work | This spec | Cleanly bounds the work; if backend gaps are surfaced during 2B impl, they're filed as 2A-UM-follow-up tickets, not bundled into 2B |
| L17 | The facility demo's **viewport-override URL trick** (`?w=NUMBER` per [main_demo.dart:60](../../lib/facility_demo/main_demo.dart#L60)) ships into the production portal as a **dev-only feature flag** gated by `--dart-define=DEBUG_VIEWPORT=1`. Default production build strips it | This spec | The trick was load-bearing during demo responsive QA. Keeping it behind a flag is free; stripping it in production avoids letting a visitor inspect-element their way into a weird state |

## Assumptions
> Beliefs that drive this design but haven't been fully validated.

| # | Assumption | Risk if Wrong | Validation Plan |
|---|-----------|---------------|-----------------|
| A1 | `amazon_cognito_identity_dart_2` correctly handles the Pre-Token Lambda V2's claims in both ID + Access tokens (today's `auth_service.dart` only reads ID-token claims; per 2A-0 L4 the same claims live in both) | If only the ID token gets the claims, API calls authenticated with the Access token would fail tenancy checks | API Gateway HTTP API JWT authorizer uses the Access token by default. Verify in 2B-0 smoke: hit `GET /api/v1/me` with the SDK's default auth header and confirm 200 with full claim set |
| A2 | The `/me/patients` fan-out cost (per 2A-RD A5 — `openAlertCount` is best-effort per-patient) is acceptable on the largest realistic V1 facility (~200 residents in a multi-site `facility_admin` scope) | UI feels laggy at scale; cold-start dashboard load >3 s | A1 + a synthetic load run during 2B-FAC-R: time the `/me/patients` response with 100 / 200 patient fixtures. If p99 > 2 s, fall back to client-side lazy-load (per 2A-RD D11) |
| A3 | Notifications-generation rules in the demo's [`notification_engine.dart`](../../lib/facility_demo/data/notification_engine.dart) (No-activity-today / Below-typical / Declining-trend) **MUST move server-side** before 2B-FAC-R ships. The demo evaluates these client-side from raw daily activity; doing the same in production would double client costs + create per-client drift | If we ship client-side eval to production, two caregivers seeing the same patient could see different notification counts (network jitter on the underlying activity fetch). Also defeats the audit log — a client-computed notification isn't recorded anywhere | Open question: should this become a Phase 1C-rollup-style scheduled job that materializes a `notifications` table, OR should the existing Threshold Detector be extended with these three behavioral rules (it already runs on shadow deltas, but the rules require *daily aggregations*, not deltas)? See Q5 |
| A4 | Audit log volume from per-patient polling (`/patients/{id}/activity` every 30 s while detail is open) is sustainable under Phase 1.7 cost model. Per 1.7's `~$0.50/mo @ 10k events/day MVP` budget: 50 staff × 2 patient drill-downs/shift × 2 polls/min × 8 hr shifts = ~96k poll events/day — 10× the modeled rate | Audit pipeline overruns; Firehose backs up; 1.7 freshness alarm fires | Mitigation built in: polling pauses when tab loses focus (browser Page Visibility API). Worst case: drop polling cadence to every 60 s and add an explicit "Refresh" button. Measure after launch |
| A5 | The demo's `unitId → censusId` mapping (per [facility-demo.md](facility-demo.md) §3) holds in production. Demo uses "Unit" as the UI label; data model is `Census`. The 2A-RD `/me/patients` response returns `censusName` + `facilityName`; portal renders both as "Unit" / "Facility" labels | UX confusion if any code path leaks "Census" into the UI | One-place mapping enforced in `lib/api/api_models.dart`'s `Census`-to-`Unit` adapter (similar to demo's `unitFor()` helper). Code review catches any stray "Census" string in UI files |
| A6 | Pre-Token Lambda's `custom:facilities` and `custom:censuses` claims fit in Cognito's ~2 KB token-size practical limit for any realistic V1 user (caregiver with ≤10 censuses, facility_admin with ≤10 facilities) | Token bloat for power-users; sign-in fails or claims silently truncate | Per 2A-RD A4, ~25 patient IDs adds ~1 KB. Facilities + censuses are smaller (UUIDs only, no per-row metadata). Comfortable margin. If a user with >50 census assignments appears, fall back to RoleAssignments fetch per request — backend already implements this pattern for `family_viewer.linkedPatientIds` |
| A7 | Flutter Web's `package:url_strategy` (or equivalent) gives us clean URLs (`/census`, `/patients/{id}`) without the `#/` hash prefix that breaks deep linking on some browsers | Bookmarked / shared URLs may not work cross-browser | Validated by Flutter docs; smoke test in 2B-0 on Chrome / Safari / Firefox / Edge |
| A8 | The Phase 1C offline-detector Lambda (or an equivalent server-side computation) ships **before V1 launch** so the "No activity today" notification (US-22, severity: critical) is fired by the cloud, not the client. Without it, the most operationally-important notification rule is unimplemented server-side | Caregivers don't get the critical alert they expect | Open question — see Q5 |

---

## Scope

### In Scope

This section reads through the user-needs doc story-by-story, calling out exactly what 2B ships, against which 2A endpoint(s), under which subset.

#### US-by-US coverage map

| US | Title | Subset | Backend |
|---|---|---|---|
| US-01 | Sign in | 2B-0 | Cognito InitiateAuth (no API) |
| US-02 | Sign out | 2B-0 | Cognito GlobalSignOut + local clear |
| US-03 | See all residents (Census) | 2B-FAC-R | `GET /me/patients` |
| US-04 | Switch List ↔ Tile view | 2B-FAC-R | URL state |
| US-05 | Filter Census by notification status | 2B-FAC-R | Client-side filter over the unack-alerts response set |
| US-06 | Sort Census | 2B-FAC-R | Client-side sort |
| US-07 | Filter Census by Unit (multi-select) | 2B-FAC-R | Client-side filter, URL-persisted |
| US-08 | Resident count | 2B-FAC-R | Derived from the list response |
| US-09 | List view metrics (10 columns) | 2B-FAC-R | Derived from `/me/patients` + `/patients/{id}/activity?range=7d` |
| US-10 | Color-tiered values | 2B-FAC-R | Pure UI (tier thresholds in `lib/theme/`) |
| US-11 | Column header tooltips | 2B-POL | Pure UI |
| US-12 | Responsive Census table | 2B-POL | Pure UI |
| US-13 | Consistent tile sizing | 2B-FAC-R | Pure UI (already in demo) |
| US-14 | Notification summary on tiles | 2B-FAC-R | Joined client-side from alerts response |
| US-15 | Open resident detail | 2B-FAC-R | Route + overlay |
| US-16 | Resident header (name + unit + room) | 2B-FAC-R | `GET /patients/{id}` |
| US-17 | Today's activity tile | 2B-FAC-R | `GET /patients/{id}/activity?range=24h` |
| US-18 | Trend charts (24H / 7D / 30D / 6M) | 2B-FAC-R | `?range=24h\|7d\|30d`; **6M = disabled with tooltip (L8)** |
| US-19 | Gait speed chart | 2B-FAC-R | Same fetch as US-18 (server returns gait fields) |
| US-20 | Device health card | 2B-FAC-R | `GET /patients/{id}` returns `currentDevice` summary; full `GET /devices/{serial}` on chevron-tap |
| US-21 | Return to Census | 2B-FAC-R | Pure UI |
| US-22 | Notification generation (3 rules) | server-side | **Cloud blocker** — see A3 + Q5 |
| US-23 | Notification severity | 2B-FAC-R | Read from alerts response |
| US-24 | Notification badge on Census | 2B-FAC-R | Joined client-side |
| US-25 | Notification review panel | 2B-FAC-R | Pure UI over the alerts response |
| US-26 | Acknowledge + Save Note | 2B-FAC-W | `PATCH /alerts/{patientId}/{ts}` body `{notes}` (2A-AA, deployed) |
| US-27 | Acknowledged clears from active | 2B-FAC-W | Client refreshes `/alerts?status=unacknowledged` after PATCH |
| US-28 | Add Resident | 2B-FAC-W | `POST /patients` (**needs 2A-UM**) + `POST /devices/{serial}/provision` (2A-DL, deployed). Client orchestrates the two |
| US-29 | Edit Resident Info | 2B-FAC-W | `PATCH /patients/{id}` (**needs 2A-UM**) |
| US-30 | Cross-facility transfer | 2B-FAC-W | Same as US-29 (server resolves new facilityId from target censusId) |
| US-31 | Pause Notifications | 2B-FAC-W | `POST /patients/{id}/notifications/pause` body `{days, reason}` (**needs 2A-UM**); auto-resume on activity is server-side concern |
| US-32 | Discharge Resident | 2B-FAC-W | `POST /patients/{id}/discharge` body `{reason, notes}` (**needs 2A-UM**); cascades through discharge-cascade Lambda (2A-DL, deployed) |
| US-33 | Destructive actions visually distinct | 2B-FAC-W | Pure UI |
| US-34 | One settings menu for lifecycle | 2B-FAC-W | Pure UI (already in demo via `ResidentSettingsDialog`) |
| US-35 | Replace Device | 2B-FAC-W | `POST /devices/{old}/end-assignment` + `POST /devices/{new}/provision` (2A-DL, deployed). Client orchestrates atomically with optimistic-then-confirm UX |
| US-36 | Discontinue Device | 2B-FAC-W | `POST /devices/{serial}/end-assignment` (2A-DL, deployed) |
| US-37 | Device diagnostics on detail | 2B-FAC-R | `GET /devices/{serial}` |
| US-38 | Multi-facility filtering | 2B-FAC-R | URL state across facilities returned by `/me/patients` |
| US-39 | Cross-unit access | 2B-FAC-R | Same as US-38 |
| US-40 | Phone responsive | 2B-POL | Already proven in demo |
| US-41 | Tablet responsive | 2B-POL | Already proven in demo |
| US-42 | Desktop responsive | 2B-POL | Already proven in demo |
| US-43 | Identity in header | 2B-FAC-R | Read from `GoSteadyUser` claims |
| US-44 | Care Note | 2B-FAC-W | Read via extended `GET /patients/{id}` response; write via `PATCH /patients/{id}/care-note` body `{text}` (**needs 2A-UM**) |

#### 2B-0 Foundation — detailed scope

**Library additions:**

```
lib/
  api/                              ← new
    api_client.dart                 # the single HTTP gateway
    api_models.dart                 # request/response shapes (mirror 2A-RD/2A-AA/2A-DL response specs)
    api_exception.dart              # typed exceptions per 2A-0 error envelope
    pagination.dart                 # cursor token round-tripping
  auth/                             ← new
    auth_service.dart               # MOVED + extended from lib/services/
    user_claims.dart                # full custom-claim model
    mfa_challenge_handler.dart      # TOTP setup + verify flow
    forgot_password_handler.dart    # email-link reset
  state/                            ← new (or refactored from facility_demo/state/)
    app_router.dart                 # GoRouter config — URL → page mapping
    app_state.dart                  # InheritedNotifier hub: AuthService, ApiClient, FeatureFlags
```

**Migrate (without deleting / mutating the demo):**
- `lib/services/auth_service.dart` → `lib/auth/auth_service.dart`. Existing `AuthService` (today's Cognito wrapper) is extended with: MFA challenge handling (replace today's `throw AuthException('MFA not yet supported.')` at [auth_service.dart:59](../../lib/services/auth_service.dart#L59)), forgot-password, and full-claim extraction (today's `_extractUser` only reads `sub` / `email` / `name` / `custom:role` per [auth_service.dart:156](../../lib/services/auth_service.dart#L156); needs `custom:clientId`, `custom:facilities`, `custom:censuses`, `custom:mfa_enrolled`)
- `lib/models/user.dart` → adds the full role enum (8 customer + 2 internal — see [phase-0a-revision.md](phase-0a-revision.md)) but uses the V1 collapsed UI per L13
- `lib/main.dart` → boots `ApiClient` alongside `AuthService`; the AuthGate consumes the unified `AppState`

**Routes (GoRouter):**

| Path | Page | Auth-gated? |
|---|---|---|
| `/sign-in` | LoginScreen | public |
| `/forgot-password` | Forgot-Password flow | public |
| `/mfa-setup` | MFA Enrollment (for facility_admin+ first sign-in) | authed-but-not-MFA-enrolled |
| `/mfa-verify` | MFA TOTP verify (every sign-in for MFA-required roles) | mid-challenge |
| `/` | CensusPage (redirect to `/census` if facility tier, `/patient` if D2C single-walker) | gated |
| `/census?units=&sort=&filter=&view=` | CensusPage | gated |
| `/patients/:patientId` | PatientDetailPage (overlay on top of `/census` if from list; standalone if deep-linked) | gated |
| `/patients/:patientId/device` | DeviceDetailPage | gated |
| `/patients/:patientId/settings` | Resident Settings dialog (deep-linkable for QA, normally opened via gear icon) | gated |
| `/me/account` | Account settings (display name + MFA management + sign-out) | gated |
| `*` | NotFoundPage | gated |

**Smoke screen:** matching 2A-0's `/me` stub pattern, 2B-0 ships **one route that hits `GET /api/v1/me`** and renders the raw claim set. Lets us verify the full pipeline (sign-in → JWT in header → API Gateway → handler → claim mirror → UI render) end-to-end before any business UI. Removed in 2B-FAC-R.

**Environment + build:**
- `--dart-define=API_BASE_URL=https://<api-gw-url>` (dev) / `https://api.gosteady.co` (prod, set in Phase 3A)
- `--dart-define=PORTAL_TIER=customer` (default) / `internal`
- `--dart-define=DEBUG_VIEWPORT=1` (dev-only, per L17)
- `--dart-define=POLL_CADENCE_MS=60000` (Census polling interval; overridable for QA)

#### 2B-FAC-R Facility Reads — detailed scope

Swaps the demo's `FacilityMockData` for `ApiClient`. The demo's screens, widgets, and state classes are **moved out of `lib/facility_demo/` and into `lib/features/facility/`** (the demo's directory was named to keep it isolated; promoting to a top-level `features/` is a no-op rename + import-fix). The mock-data layer stays as a test fixture under `lib/test_support/`.

**Per-screen API mapping:**

| Screen | Demo file | Live API call |
|---|---|---|
| Census | `lib/facility_demo/screens/patient_census_view.dart` | `GET /me/patients?cursor=` (paginated; concatenated client-side until `nextCursor: null`). For the 11-column list view's trend / 7-day-avg / gait columns, `GET /patients/{id}/activity?range=7d` is fetched **lazily per visible row** (intersection-observer style) to avoid the fan-out cost (A2) |
| Patient Detail | `lib/facility_demo/screens/patient_detail_view.dart` | `GET /patients/{id}` + `GET /patients/{id}/activity?range={24h\|7d\|30d}` + `GET /patients/{id}/alerts?status=unacknowledged` |
| Device Detail | `lib/screens/device_screen.dart` (reused from D2C path) | `GET /devices/{serial}` |
| Facility/Unit selector dropdown | `lib/facility_demo/widgets/facility_selector_dropdown.dart` | Data sourced from the union of `facilityId`s / `censusId`s present in `/me/patients` response. **No separate "list my facilities" endpoint needed** for V1 (out of scope per phase-2a-read §Out of Scope facility-wide list). When the `facility_admin` user has access to many facilities, the dropdown shows whatever `/me/patients` actually returned |

**Notification badges on Census:** the demo computes these client-side via `notification_engine.dart`. Per A3 this **MUST move server-side**. Until Q5 resolves, the simplest interim is: for each patient row in `/me/patients`, count `openAlertCount` (already returned by 2A-RD per spec response shape) — that gives "1 alert" but not the rule-name copy ("No activity today"). The full three-rule notification copy is gated on Q5.

#### 2B-FAC-W Facility Writes — detailed scope

| Action | UI | API call(s) | Pre-flight |
|---|---|---|---|
| Acknowledge notification (US-26) | `NotificationReviewPanel` (already in demo) | `PATCH /alerts/{patientId}/{ts}` body `{notes?}` — URL-encode the compound SK `{ts}#{alertType}` per 2A-AA L9 | 500-char notes max (server-side validated) |
| Edit Care Note (US-44) | Inline-editable text below resident header; save on blur, debounce 500 ms | `PATCH /patients/{id}/care-note` body `{text}` (**2A-UM**) | ≤280 chars (client + server) |
| Pause Notifications (US-31) | New dialog from gear-icon menu (extends `ResidentSettingsDialog`'s `_View` enum) | `POST /patients/{id}/notifications/pause` body `{days, reason}` (**2A-UM**) — auto-resume-on-activity is server-side per US-31. Manual unpause: `DELETE /patients/{id}/notifications/pause` | days ∈ [1, 90]; reason ∈ enum |
| Add Resident (US-28) | `AddResidentDialog` (already in demo) | `POST /patients` body `{displayName, censusId, room, deviceSerial?}` (**2A-UM**); if `deviceSerial` set, server orchestrates `provision` atomically. **OR** client makes two calls — see Q4 | Device ID regex `^GS\d{10}$`; required fields per US-28 |
| Edit Resident Info (US-29 / US-30) | `_EditInfoForm` view of `ResidentSettingsDialog` | `PATCH /patients/{id}` body `{displayName?, censusId?, room?}` (**2A-UM**) | Same |
| Replace Device (US-35) | `_ReplaceDeviceForm` view | `POST /devices/{old}/end-assignment` + `POST /devices/{new}/provision` — **client orchestrates with optimistic UI**: end-assignment succeeds → server fires wipe cmd (cascade handled by 2A-DL); client immediately fires provision with new serial. Display "Old device being released — new device assigned" status until both 200 | Both serials match regex; new serial is `ready_to_provision` (verified by `GET /devices/{new}` pre-flight) |
| Discontinue Device (US-36) | `_DiscontinueDeviceConfirm` view | `POST /devices/{serial}/end-assignment` (2A-DL, deployed) | Confirmation modal warning |
| Discharge Resident (US-32) | `_DischargeForm` view | `POST /patients/{id}/discharge` body `{reason, notes?}` (**2A-UM**) — server cascades to all assigned devices via discharge-cascade Lambda | reason ∈ enum; destructive UI per US-33 |

**Optimistic UI policy:** writes show a loading state. On 200, the affected screen refetches its source data (`/me/patients` for Census-affecting writes; `/patients/{id}` for detail). On any non-2xx, surface a SnackBar with the `ApiException.message`, leave the form open with values intact, allow retry. **No optimistic-then-revert** in V1 — too easy to leave the user with a wrongly-confident UI state when a 4xx fires after a 200 ack of a different sort.

**Audit:** all writes route through 2A's audit middleware server-side (L14). Client does nothing audit-related.

#### 2B-D2C Household Path — detailed scope

The D2C single-walker dashboard at [`lib/screens/dashboard_screen.dart`](../../lib/screens/dashboard_screen.dart) was the original portal — predates facility surfaces. In V1, D2C is the `household_owner` role: a family member who signed up directly, claimed one walker, and gets a single-patient view. Surface is much smaller than facility:

| Screen | API |
|---|---|
| Single-patient overview = "self" | `GET /me/patients` returns exactly one patient row for household_owner. UI auto-selects it; no Census step |
| Patient Detail | Same as facility-tier (US-15 through US-20). All four time-range tabs (24H/7D/30D/6M) |
| Device Detail | Same |
| Settings dialog | Only Care Note + Pause Notifications + Replace Device + Discontinue Device subset (no Discharge — D2C has no "patient discharged" semantic; account closure is a 2A-UM concern) |

Sign-up flow needs `household_owner`-specific path (D2C signup at `gosteady.co` — out of 2B-D2C scope, lives in marketing site + a 2A-UM `POST /admin/household` endpoint that the marketing site calls). The portal sign-in just accepts the resulting credentials.

**Today's [login_screen.dart](../../lib/screens/login_screen.dart) signup flow** assumes a `walker | caregiver` role choice (per [user.dart:21](../../lib/models/user.dart#L21)). That's the legacy two-role model; replaced by the 8-role model in 2B-0. The signup screen in V1 is **removed from the portal entirely** — D2C signup flows through the marketing site; facility users are admin-created. The portal only has Sign-In + Forgot-Password.

#### 2B-INT Internal-tier UI additions — detailed scope (low priority)

Per L1, internal staff sign in at the **same URL** as customer users. The portal detects `custom:role` starting with `internal_` on sign-in and surfaces extra navigation + screens that don't appear for customer roles. Surface:

- **Client-context picker (REQUIRED for any internal use of `/me/patients`):** internal users' `custom:clientId` is `_internal`, not a real customer tenant. The portal surfaces a top-bar "Viewing as: [client picker]" widget that internal users must select from before any patient list can be fetched. The selected `clientId` drives the `?clientId=` query param required by 2A-RD L12 + D6. Without selection, the Census page shows an empty state pointing at the picker. **This is the second-class top-bar surface for internal roles only** — customer roles never see it because their `custom:clientId` is the tenant ID directly
- **Top-bar augmentation:** tier badge ("Internal · Support" / "Internal · Admin") next to the user chip; visual distinction from customer-tier sessions
- **Cross-tenant patient search:** new route `/search/patients?q=` (internal-only; route guard checks `internalAccess === true` on `GoSteadyUser`)
- **Cross-tenant device search:** new route `/search/devices?serial=` (internal-only)
- **Audit-log search:** new route `/admin/audit?...` (2A-INT spec gates the backend; possibly via Athena per Phase 1.7.1)
- **Internal-only device actions** in the existing device-detail screen: `force-reset`, `move-facility`, `move-client` (all 2A-DL endpoints already deployed; UI just needs the role-gated buttons)

The customer-role build path never renders any of these affordances, never includes them in route trees, and never resolves them in code-split chunks (Flutter Web's deferred-component support is the load-time guard; route guards are the runtime guard). **Defense-in-depth:** the backend 403s any caller hitting `/search/*` or `/admin/*` without an `internal_*` role regardless of what the UI sent (per 2A-0 L5 + 2A-RD L12 tenancy enforcement). Inspect-element doesn't get a non-internal user past the API.

**2B-INT is explicitly low priority.** Not blocked by anything in V1; the role-conditional UI additions land after 2A-INT is specced (which doesn't exist yet) and after at least one internal-role user wants the feature.

#### 2B-POL Polish — detailed scope

- WCAG AA contrast audit on the full sage / cream / rust palette; sample with axe-core or Flutter Inspector
- Keyboard tab order through Census filters + sort dropdowns + tile/row + settings gear + dialog forms
- Screen-reader labels for: settings gear (Tooltip exists per [patient_detail_view.dart:216](../../lib/facility_demo/screens/patient_detail_view.dart#L216) but needs `Semantics(label: ...)`); notification severity badges; chart tooltips
- Column-header tooltips for US-11 (currently missing in demo)
- Loading skeletons (per-card) replacing today's full-page spinners
- Empty-state copy review with product
- Final responsive QA at 390 / 430 / 744 / 1024 / 1280 / 1440 / 1920 — keep the `?w=` URL flag from L17 for QA

### Out of Scope (Deferred)

- **Real-time push** (WebSocket / SSE / FCM / APN / SMS / Email) — Phase 2C (notifications)
- **Audit-log viewing UI** — V2 / Phase 2A-UM follow-up
- **Family viewer (`family_viewer` role) UI** — V3; auth-model guardrails preserved per L13
- **Per-resident threshold tuning UI** — 2A-AA backend ships the endpoints (PUT/GET `/patients/{id}/thresholds` with facility_admin+ writes), but the V1 user-needs explicitly excludes per-resident threshold customization (§6: "No per-resident alert threshold customization"). 2B does NOT render a UI for this in V1 even though the API is live. Lands when V2 role split also lands
- **Patient compare view** (side-by-side trend charts) — user-needs §6
- **Activity export** (CSV / PDF) — user-needs §6
- **Photo upload for resident records** — user-needs §6
- **Clinical fields** (DOB / sex / meds / fall-risk score) — user-needs §6
- **In-app discharge undo button** — user-needs §6 explicitly says no (support-mediated restore within 7 days)
- **Tip-over / fall-event alerts** — V3 (sensor + ML); user-needs §6
- **Real-time device commands** (find walker / remote LED) — user-needs §6
- **Daily email digest** — V2 (Phase 2C)
- **Push notifications / SMS** — V3 (Phase 2C + mobile app)
- **Notifications-out-of-app preferences UI** — V2 (Phase 2C ships the channels; 2A-UM ships the preferences endpoints)
- **6M activity view** — UI disabled with tooltip until Phase 1C rollup endpoint ships (L8)
- **Multi-Client (corporate-admin) UI** — V2 (user-needs §7 #9: single Client per user in V1)
- **QR code scanning for device serial entry** — 2A-DL Out-of-Scope; promoted only if pilot data shows >5 % typo rate
- **`internal_support`-tier portal** — read-only internal staff; covered by `internal_admin` build in 2B-INT
- **OpenAPI / Swagger-style portal-side documentation** — 2A-0 Out-of-Scope; not a 2B concern
- **Phase 3A production hosting** — separate phase; 2B is local-dev-only deploy target

---

## Architecture

### Infrastructure Changes

**None.** Phase 2B is a pure-frontend phase per L16. No new AWS resources, no new DDB tables, no new IAM roles, no new Lambdas. All 2B work lives in `gosteady-portal` repo's `lib/` and `web/` directories.

The only AWS-side action needed during 2B development is **adding more entries to `apiCorsAllowedOrigins`** (2A-0 L9) if any developer machine runs the dev server on a non-default port. That's a one-line change to `infra/lib/config.ts` + a `cdk deploy GoSteady-Dev-Api` — not a 2B deliverable, just operational housekeeping during 2B's local dev.

### Data Flow

```
Caregiver (Chrome)
   │
   │ Loads https://portal.gosteady.co/  (Phase 3A; dev = localhost:8080)
   │
   ▼
Flutter Web bundle (main.dart, --dart-define=API_BASE_URL=…)
   │
   ├── AuthService boots, attempts session restore
   │     ├─ Refresh token valid? → emit GoSteadyUser via Pre-Token Lambda → /census
   │     └─ Else                 → /sign-in
   │
   ▼ (signed in)
ApiClient.get('/me/patients')
   │
   │ Authorization: Bearer <ID token from AuthService>
   │
   ▼
API Gateway HTTP API → JWT authorizer (2A-0) → patient-api Lambda (2A-RD)
   │
   │ event.requestContext.authorizer.jwt.claims
   ▼
patient-api executes per-role scope resolution per 2A-RD §Scope
   │
   ▼ (response)
ApiClient decodes envelope; widget renders or surfaces ApiException
   │
   ▼ (write)
ApiClient.patch('/alerts/pat_abc/2026-05-22T01:15:32Z%23battery_critical')
   │
   ▼
alert-actions Lambda (2A-AA) → conditional UpdateItem → emit_audit('alert.ack')
   │
   ▼ (response)
Widget refetches /alerts?status=unacknowledged → notification disappears from list
```

### Interfaces

#### `ApiClient` (new)

```dart
class ApiClient {
  ApiClient({required AuthService auth, required String baseUrl});

  // Reads
  Future<MePatientsResponse> getMyPatients({String? cursor, String? clientId});
  Future<PatientDetailResponse> getPatient(String patientId);
  Future<ActivityResponse> getActivity(String patientId, ActivityRange range, {String? cursor});
  Future<AlertsResponse> getAlerts(String patientId, AlertStatus status, {String? cursor});
  Future<DeviceResponse> getDevice(String serial);
  Future<CensusRosterResponse> getCensusRoster(String facilityId, String censusId, {String? cursor});

  // Writes — 2A-AA
  Future<AlertResponse> ackAlert(String patientId, String compoundSk, {String? notes});

  // Writes — 2A-DL (already deployed)
  Future<DeviceResponse> provisionDevice(String serial, String patientId);
  Future<DeviceResponse> endAssignment(String serial);
  Future<DeviceResponse> decommissionDevice(String serial, DecommissionReason reason);
  Future<DeviceResponse> recoverDevice(String serial);
  // force-reset, move-facility, move-client — 2B-INT only

  // Writes — 2A-UM (NOT YET DEPLOYED — see Open Questions Q6)
  Future<PatientDetailResponse> createPatient({required String displayName, required String censusId, required String room, String? deviceSerial});
  Future<PatientDetailResponse> updatePatient(String patientId, {String? displayName, String? censusId, String? room});
  Future<void> dischargePatient(String patientId, {required DischargeReason reason, String? notes});
  Future<void> pauseNotifications(String patientId, {required int days, required PauseReason reason});
  Future<void> resumeNotifications(String patientId);
  Future<PatientDetailResponse> updateCareNote(String patientId, String text);
}
```

#### Error decoding

```dart
class ApiException implements Exception {
  final String code;      // e.g., "TENANCY_VIOLATION"
  final String message;   // user-facing copy
  final Map<String, dynamic>? details;
  final int httpStatus;
}
```

`ApiClient` decodes every non-2xx response per the 2A-0 envelope (`{error: {code, message, details}}`). Network failures (no envelope; raw timeout / DNS / 0-byte response) surface as `ApiException(code: 'NETWORK', message: 'Connection lost. Retry?', httpStatus: 0)`.

#### Auth + token lifecycle

```dart
class AuthService extends ChangeNotifier {
  Future<void> init();              // restore session
  Future<GoSteadyUser> signIn(String email, String password);
  Future<void> completeMfaChallenge(String code);   // NEW in 2B-0
  Future<void> enrollMfa();                          // returns TOTP secret + QR uri
  Future<void> forgotPassword(String email);         // sends Cognito code
  Future<void> confirmForgotPassword(String email, String code, String newPassword);
  Future<void> signOut();
  Future<String?> getIdToken();      // auto-refresh on demand
  GoSteadyUser? get currentUser;
}

class GoSteadyUser {
  final String userId;          // Cognito sub
  final String email;
  final String displayName;
  final UserRole role;          // full 8+2 enum (V1 collapses to one UI; V2 differentiates)
  final String? clientId;
  final List<String> facilities;
  final List<String> censuses;
  final bool mfaEnrolled;
  // ID token NOT stored on this object — fetched on-demand via getIdToken()
}
```

#### URL state shape

Census state is serialized to query string:

```
/census?units=cen_ws_memory,cen_ws_al_east&sort=needsReviewFirst&filter=criticalOnly&view=list
```

- `units=` comma-separated census IDs. Empty / absent = "all"
- `sort=` ∈ `needsReviewFirst | nameAZ | mostActive | leastActive`
- `filter=` ∈ `all | withNotifications | criticalOnly | noNotifications`
- `view=` ∈ `list | tile`

Patient drill-down is a route push: `/patients/pat_001`. Closing the overlay pops the route. The combination preserves browser back-button + shareable URLs without holding PII in either.

---

## Implementation

### Files Changed / Created

> Spelled out only for 2B-0 + 2B-FAC-R; 2B-FAC-W / 2B-D2C / 2B-INT / 2B-POL get their own per-subset spec amendments when they kick off.

| File | Subset | Change | Description |
|------|--------|--------|-------------|
| `lib/main.dart` | 2B-0 | Modified | Wires `ApiClient` + `AuthService` into `AppState`; switches `home:` to `GoRouter` |
| `lib/auth/auth_service.dart` | 2B-0 | New (moved from `lib/services/`) | MFA + forgot-password handlers added; full claim extraction |
| `lib/auth/user_claims.dart` | 2B-0 | New | Full role enum + custom-claim parsing |
| `lib/auth/mfa_challenge_handler.dart` | 2B-0 | New | TOTP setup + verify |
| `lib/auth/forgot_password_handler.dart` | 2B-0 | New | Email-code reset |
| `lib/api/api_client.dart` | 2B-0 | New | `ApiClient` per §Interfaces |
| `lib/api/api_models.dart` | 2B-0 | New | Request/response shapes — mirror 2A-RD / 2A-AA / 2A-DL response specs |
| `lib/api/api_exception.dart` | 2B-0 | New | Typed exceptions |
| `lib/api/pagination.dart` | 2B-0 | New | Cursor encode/decode helper |
| `lib/state/app_router.dart` | 2B-0 | New | GoRouter config |
| `lib/state/app_state.dart` | 2B-0 | New | InheritedNotifier hub |
| `lib/screens/login_screen.dart` | 2B-0 | Modified | Strip signup flow; add MFA challenge step; add Forgot Password link |
| `lib/screens/dashboard_screen.dart` | 2B-D2C | Modified | Replace `MockDataSource` with `ApiClient` |
| `lib/screens/device_screen.dart` | 2B-FAC-R / 2B-D2C | Modified | Same — Mock → ApiClient |
| `lib/models/user.dart` | 2B-0 | Modified | Expand `UserRole` enum to the 8+2 model |
| `lib/features/facility/` | 2B-FAC-R | New (moved from `lib/facility_demo/`) | Promote demo screens to a top-level feature dir; rewire data layer to `ApiClient` |
| `lib/features/facility/data/facility_repository.dart` | 2B-FAC-R | New | The `ApiClient`-backed equivalent of `FacilityMockData`. Same public surface so widgets don't change |
| `lib/test_support/facility_mock_data.dart` | 2B-FAC-R | Moved | Keep `FacilityMockData` under test_support for widget tests; drop the `lib/facility_demo/` directory entirely |
| `lib/features/facility/screens/patient_detail_view.dart` | 2B-FAC-W | Modified | Add Care Note tile + Pause-Notifications banner |
| `lib/features/facility/widgets/resident_settings_dialog.dart` | 2B-FAC-W | Modified | Wire each form's `_submit` to the real `ApiClient` mutations (replace today's `_toastAndClose`) |
| `lib/features/facility/widgets/notification_review_panel.dart` | 2B-FAC-W | Modified | `_submitNote` calls `ApiClient.ackAlert` |
| `lib/features/facility/widgets/add_resident_dialog.dart` | 2B-FAC-W | Modified | Wire `_submit` to `ApiClient.createPatient` |
| `pubspec.yaml` | 2B-0 | Modified | Add `go_router` (or `auto_route`); confirm `amazon_cognito_identity_dart_2`, `shared_preferences`, `http` already pinned |
| `web/index.html` | 2B-0 | Modified | URL strategy = path-based (no `#`) per A7 |

### Dependencies

- **Phase 0A-rev** — Cognito User Pool, Portal-Customer App Client (`1q9l9ujtsomf3ugq2tnqvdg6d7`), Portal-Internal (`gvc7n839vj4ppgioamknlk21c`)
- **Phase 1.6** — operational dashboards already cover API latency / error rate; no new dashboards needed
- **Phase 1.7** — server-side audit (no client-side audit)
- **Phase 2A-0** — API Gateway HTTP API + JWT authorizer + CORS + error envelope
- **Phase 2A-DL** — device endpoints
- **Phase 2A-RD** — patient read endpoints
- **Phase 2A-AA** — alert ack + threshold endpoints (threshold UI deferred per Out of Scope)
- **Phase 2A-UM** — patient management endpoints (Add / Edit / Discharge / Care Note / Pause Notifications). **NOT YET DEPLOYED.** Gates 2B-FAC-W per §Sub-phase split

### NPM / pub packages

- Existing pinned: `amazon_cognito_identity_dart_2`, `shared_preferences`, `flutter`, `http`
- **Add:** `go_router` ^14.0 (or current latest) for URL state
- **Maybe add (decided in 2B-0):** `freezed` + `json_serializable` for type-safe response models — see Q7

### Configuration

| Build-time define | Default | Notes |
|---|---|---|
| `API_BASE_URL` | (must be set) | Dev: API Gateway-issued URL from `aws apigatewayv2 get-apis`. Prod: `/api/v1` (relative) per [phase-3a-portal-hosting.md](phase-3a-portal-hosting.md) L1 — same-origin reverse-proxy means no CORS preflight + future HttpOnly-cookie path stays open |
| `POLL_CADENCE_MS` | `60000` | Census polling cadence in ms. QA override |
| `DEBUG_VIEWPORT` | `0` | When `1`, enables the `?w=` URL viewport-override per L17 |
| `COGNITO_USER_POOL_ID` | `us-east-1_ZHbhl19tQ` | Same as deployed |
| `COGNITO_CLIENT_ID` | `1q9l9ujtsomf3ugq2tnqvdg6d7` | Unified Portal-Customer client per L1. Same value for all tiers (internal users sign in here too; Pre-Token Lambda differentiates token lifetime + claims by role) |

> **Note:** `PORTAL_TIER` and `COGNITO_CLIENT_ID_INTERNAL` from earlier drafts of this spec are **removed**. The unified-portal decision (L1 / D1 / Q8) means everyone signs in via the same Cognito client; the internal Cognito client (`gvc7n839vj4ppgioamknlk21c`, has secret) is reserved for non-browser tools.

---

## Testing

### Test Scenarios

> Per-subset acceptance. Full smoke run combines all sub-tables.

#### 2B-0 acceptance

| # | Scenario | Method | Expected | Status |
|---|---|---|---|---|
| T0.1 | `flutter run -d chrome` cold start renders `/sign-in` | manual | Login screen, no console errors | Pending |
| T0.2 | Sign-in with valid Portal-Customer test creds returns 200; landed on `/census` | manual | Census loads; top bar shows display name + role badge | Pending |
| T0.3 | Sign-in with bad password shows "Incorrect email or password" inline | manual | No leak of whether email exists per user-needs US-01 | Pending |
| T0.4 | Sign-in with `facility_admin` test creds (MFA-required) triggers MFA challenge route | manual | `/mfa-verify` rendered with TOTP input | Pending |
| T0.5 | First-time `facility_admin` (no MFA enrolled) routes to `/mfa-setup` and shows QR code | manual | QR scannable; verifying code completes enrollment + lands on `/census` | Pending |
| T0.6 | Forgot Password: enter email → receive Cognito code → submit code + new password → sign in | manual | Sign-in works post-reset | Pending |
| T0.7 | Token refresh at +14 min idle (1 min before 15-min expiry) is transparent | manual + DevTools network tab | One `/oauth2/token` refresh call; no user-visible re-auth | Pending |
| T0.8 | Token refresh failure (revoke session at Cognito console mid-session) → forced sign-out + redirect to `/sign-in` | manual | Within 60 s of next API call, signed out | Pending |
| T0.9 | `GET /api/v1/me` smoke screen renders full claim set | manual | All five custom claims visible | Pending |
| T0.10 | `ApiException` UI: simulate 403 by manually changing token → SnackBar with "Permission denied" copy | manual | Friendly error, no raw HTTP | Pending |
| T0.11 | Network-loss banner appears when device goes offline; clears on reconnect | manual + Chrome offline toggle | Banner visible; manual retry available | Pending |

#### 2B-FAC-R acceptance

| # | Scenario | Method | Expected | Status |
|---|---|---|---|---|
| TR.1 | Census loads ~10 patients for `pt_bench_98`'s test facility | manual + real-data setup | Each row populated with name / unit / room / today's activity / 7d avg / 30d avg / step trend / gait | Pending |
| TR.2 | Tile view ↔ List view toggle survives reload (URL state) | manual | View persists | Pending |
| TR.3 | Unit selector multi-select narrows the visible set live (no Apply button) | manual | Patients filter in real time | Pending |
| TR.4 | Sort changes the order without changing the filter | manual | Filter persists | Pending |
| TR.5 | Click resident → overlay opens with Patient Detail; URL changes to `/patients/{id}` | manual | Browser back closes overlay | Pending |
| TR.6 | Trend toggle 24H/7D/30D refetches and re-renders within 300ms | manual + Network tab | Three distinct API calls; chart updates without flicker | Pending |
| TR.7 | 6M tab is disabled with tooltip "Coming in v1.1 (rolled-up data)" | manual | Disabled state per L8 | Pending |
| TR.8 | Device Detail (chevron tap) loads `GET /devices/{serial}` | manual | Battery / signal / firmware / lastSeen displayed | Pending |
| TR.9 | Notification badge on Census reflects `openAlertCount` from `/me/patients` | manual + bench-create alert | Badge appears within 1 polling interval | Pending |
| TR.10 | Polling pauses when tab loses focus (Page Visibility API) | DevTools Network | Stops on blur, resumes on focus | Pending |
| TR.11 | URL deep-link: paste `/patients/pat_001?…` into a new tab → opens Patient Detail directly | manual | No detour through Census | Pending |
| TR.12 | Family viewer scope test: sign in as a `family_viewer` whose `linkedPatientIds` covers 1 patient → only that patient visible | manual | No cross-leak | Pending |
| TR.13 | `OUT_OF_SCOPE` error UX: caregiver opens stale URL for a patient outside scope → friendly 403 page | manual | Not a raw error; offers "Back to Census" | Pending |
| TR.14 | `PATIENT_NOT_FOUND` (404 — existence-leak prevention) → "We can't find that resident" copy | manual | Same UX whether truly missing or out-of-scope (intentional) | Pending |

#### 2B-FAC-W acceptance (gated on 2A-UM)

| # | Scenario | Method | Expected | Status |
|---|---|---|---|---|
| TW.1 | Acknowledge a critical alert → disappears from active list; audit `alert.ack` event lands in S3 | manual + audit query | 200 PATCH; alert no longer in `?status=unacknowledged` | Pending |
| TW.2 | Acknowledge with notes → notes persisted, visible via `?status=acknowledged` | manual | Notes shown on acked-alert row | Pending |
| TW.3 | Idempotent re-ack → second call returns `wasAlreadyAcknowledged: true`; original acker preserved | manual | Per 2A-AA L4 | Pending |
| TW.4 | **(2A-UM dep)** Add Resident with valid device ID → patient created + device provisioned atomically | manual | Both writes succeed; activate cmd published per 2A-DL L14 | Pending |
| TW.5 | **(2A-UM dep)** Edit Resident Info: change room → 200; Census refresh shows new room | manual | Audit `patient.update` event | Pending |
| TW.6 | **(2A-UM dep)** Cross-facility transfer via Edit (target census in different facility) | manual | Tenancy still enforced server-side | Pending |
| TW.7 | **(2A-UM dep)** Pause Notifications for 7 days, reason: in_hospital → badge appears on tile + countdown banner on detail | manual | Audit `patient.notifications.pause` event | Pending |
| TW.8 | **(2A-UM dep)** Pause Notifications auto-resumes when activity data streams (server-side concern; verify cloud-side firing) | bench + manual | Pause cleared on next activity event during window | Pending |
| TW.9 | **(2A-UM dep)** Care Note: type 250 chars, blur → 200 PATCH; reload retains | manual | Attribution + timestamp updated | Pending |
| TW.10 | **(2A-UM dep)** Care Note: type 290 chars → field-level validation rejects without API call | manual | Per L10-style client validation; ≤280 chars | Pending |
| TW.11 | Replace Device: end-assignment + provision orchestrated; UI shows transition state | manual | Both 200s; activity history continuous per user-needs #4 | Pending |
| TW.12 | Discontinue Device: 200; resident stays in Census; device chip shows "No device assigned" | manual | No activity uploads from now until next provision | Pending |
| TW.13 | **(2A-UM dep)** Discharge Resident: cascade ends assignment, transitions device → discontinued; firmware wipe-ack auto-recycles per 2A-DL discharge-cascade | manual + cloud verify | Patient archived; device back to `ready_to_provision` after wipe-ack | Pending |
| TW.14 | Destructive-action UI red treatment (US-33) is visible in modal | manual | Distinct from non-destructive | Pending |

#### 2B-POL acceptance

| # | Scenario | Method | Expected | Status |
|---|---|---|---|---|
| TP.1 | All Census filters / sort / view-mode reachable via keyboard tab | manual + keyboard-only | Tab order is sensible; visible focus rings | Pending |
| TP.2 | WCAG AA contrast on text + tier-color tiles | axe-core or Flutter Inspector | All pass; no contrast violations | Pending |
| TP.3 | Screen-reader walkthrough of Census + Patient Detail (VoiceOver / NVDA) | manual | All interactive elements have accessible names | Pending |
| TP.4 | Column header tooltips (US-11) render on hover + focus | manual | Tooltip copy explains the metric | Pending |
| TP.5 | Phone (390px) responsive — Census + Detail + Settings dialog | `?w=390` | No horizontal scroll; tap targets ≥44px | Pending |
| TP.6 | Tablet (744px) responsive | `?w=744` | Mid-density layout | Pending |
| TP.7 | Loading state on cold Census load shows skeleton rows, not blank | manual + slow network | No layout shift on data arrival | Pending |
| TP.8 | Empty state at zero patients (new facility) | manual + test fixture | Friendly copy | Pending |

### Verification Commands

```bash
# Local dev — run against deployed dev API
API_URL=$(aws apigatewayv2 get-apis --region us-east-1 \
  --query 'Items[?Name==`gosteady-dev-api`].ApiEndpoint' --output text)

# One build, all users (customer + internal sign in at the same URL per L1/D1)
flutter run -d chrome -t lib/main.dart \
  --dart-define=API_BASE_URL=$API_URL \
  --dart-define=DEBUG_VIEWPORT=1

# Production build (artifacts only — Phase 3A handles hosting)
flutter build web -t lib/main.dart \
  --dart-define=API_BASE_URL=https://api.gosteady.co \
  --release

# Verify dev test users (created in 2A-RD seeding)
aws cognito-idp list-users --region us-east-1 \
  --user-pool-id us-east-1_ZHbhl19tQ \
  --query 'Users[?Attributes[?Name==`email` && contains(Value,`test`)]].[Username, UserStatus]'
```

---

## Deployment

### Deploy Commands

Phase 2B has no AWS deploy step. Production deploy is **Phase 3A** (S3 + CloudFront + WAF + ACM cert at `portal.gosteady.co`).

During 2B development:
- Local: `flutter run -d chrome -t lib/main.dart --dart-define=API_BASE_URL=…`
- Preview deploy (optional, for sharing in-progress builds with stakeholders): the existing demo deploy script [`tools/deploy-demo.sh`](../../tools/deploy-demo.sh) can be parameterized to deploy non-demo builds to a `gosteady.co/preview/` subpath. Same Netlify pipeline as the facility demo

### Rollback Plan

Per-subset rollbacks:
- **2B-0:** revert PR; the demo build (which doesn't touch `lib/main.dart` or `auth_service.dart`) continues to work because `lib/facility_demo/` is independent
- **2B-FAC-R:** the move from `lib/facility_demo/` to `lib/features/facility/` is the riskiest step. Revert restores the demo build. Live API integration is git-add-only (no destructive changes to widget code)
- **2B-FAC-W:** writes are individually feature-flagged via `--dart-define=ENABLE_WRITES_{ACK|CARE_NOTE|PAUSE|ADD|EDIT|DISCHARGE|REPLACE_DEVICE|DISCONTINUE_DEVICE}=1`. Toggle the flag to disable a misbehaving write at runtime without redeploy
- **2B-D2C / 2B-INT / 2B-POL:** localized changes, revert individual PRs

If a production deploy (Phase 3A) goes wrong, the CloudFront distribution rolls back to the prior S3 version via cache invalidation + retag of the prior commit.

---

## Decisions Log
> Choices made during this phase that affect future work.

| # | Decision | Alternatives Considered | Why This Choice |
|---|----------|------------------------|-----------------|
| D1 | **One Flutter codebase, one build, one URL, one Cognito App Client** — internal-tier UI surfaces as role-conditional additions rather than a separate build | (a) separate Portal-Customer + Portal-Internal builds at different URLs, (b) two Cognito clients into one build hostname-switched, (c) keep dual-client today | Per L1 / Q8 — the security boundary is JWT-based, not URL-based. One URL is simpler operationally (one CloudFront distribution, one ACM cert, one Cognito client to maintain), simpler for users (internal staff don't bookmark a different URL), and consistent with [ARCHITECTURE.md](ARCHITECTURE.md) §4's stated stance. Portal-Internal client is repurposed for non-browser internal tools (CLI scripts, server-side admin) where the client secret is safe to handle |
| D2 | Promote `lib/facility_demo/` to `lib/features/facility/` rather than rebuild | Keep demo intact + write 2B from scratch | Demo widgets are production-grade Flutter; rebuilding wastes ~6,500 lines of solid code. The mock-data swap (FacilityMockData → ApiClient backed by FacilityRepository with identical surface) is the central refactor |
| D3 | URL-based state (filters, sort, view, selected patient) | localStorage state | Survives reload (per user-needs §5 Reliability), supports shareable links, no PII leakage per L11. URL is the natural place to put filter/sort state |
| D4 | Polling, not push (L12) | WebSocket / SSE in V1; or Phase 2C push-first | Polling at 30–60 s cadence is well within throttling envelope, no infra cost, and the alerts are not real-time-critical (caregivers aren't waiting on the screen for an alert; they're scanning during shift change). Push lands in Phase 2C alongside the email digest |
| D5 | `GoRouter` over `auto_route` | `auto_route`, hand-rolled `Navigator 2.0` | GoRouter is the Flutter team's recommended router as of 2024; ships URL strategy + deep linking out of the box; matches A7 |
| D6 | MFA challenge handled by extending existing `AuthService` rather than introducing AWS Amplify | Migrate to AWS Amplify (provides built-in MFA UI) | `amazon_cognito_identity_dart_2` is already pinned and working; adding Amplify is a heavier lift than handling the one MFA case manually. Revisit if other Amplify features (Hosted UI, social federation) become useful |
| D7 | Optimistic UI on writes is *blocking-with-loading*, not *optimistic-then-revert* | Optimistic-update with rollback on 4xx | Optimistic-then-revert is fragile across multi-call orchestrations (Replace Device, Discharge cascade). Caregiver clarity matters more than perceived latency at this scale (writes are <500ms in practice) |
| D8 | 6M time-range tab is **disabled** with a tooltip until Phase 1C ships, not removed | Hide the tab entirely; or implement client-side aggregation from 30d raw | Disabled-with-tooltip telegraphs "this is coming"; hiding suggests we don't plan to support it. Client-side aggregation of 30d → 6M produces wrong data (only 1 month of input) |
| D9 | Notification rules — three of them (No-activity-today / Below-typical / Declining-trend) — **must move server-side** before 2B-FAC-R ships to production | Keep them client-side as in the demo | Per A3, client-side eval creates per-client drift + bypasses the audit log. Server-side is the only correct semantic. **Server-side implementation** is an open question (Q5) |
| D10 | No discharge undo button in V1 UI per user-needs §6 + §7 #11; support-mediated restore via internal-admin endpoint within 7 days | Self-serve undo with confirmation cooling-off period | Discharge is auditable, infrequent, and the soft-undo window is sufficient. The undo button reduces the seriousness of the act, making it more likely to be used in error |
| D11 | Per-patient threshold tuning UI is deferred to V2 even though 2A-AA exposes the backend endpoints | Render the UI in 2B-FAC-W since the API exists | Per user-needs §6, threshold customization is explicitly out of V1 scope (single role; one set of clinical defaults). The PUT endpoint sits dormant until V2 role-gating ships. Avoids cluttering V1 with a clinical-config surface |
| D12 | Care Note (US-44) and Pause Notifications (US-31) are routed to **2A-UM** rather than spun out as a new "2A-NN notifications" subset | New `2A-UM-NN` subset; or shove into existing handlers | Both are patient-state writes (mutations on the Patients row + cascading effects via audit + threshold-detector); they fit cleanly into the User Management subset's mental model. Adding a new subset adds CDK stack overhead. **See Q6** — this is a recommendation, not yet decided |
| D13 | URL state on Census is encoded as comma-separated unit IDs, not opaque tokens | Base64-encode the state blob | Opaque tokens look uglier in the URL and prevent direct manipulation (which is occasionally useful for QA). Census state is non-sensitive (unit IDs are opaque to outsiders; patient IDs only appear when a patient is selected in the path); cleartext is fine |
| D14 | Sign-up flow is removed from the portal entirely; facility users are admin-created (2A-UM); D2C users sign up via marketing site | Keep the legacy `LoginScreen`'s signup form | Today's signup form uses the wrong role enum (`walker | caregiver` legacy 2-role) and doesn't handle MFA or the synthetic `dtc_*` client creation needed for D2C. Two cleaner paths (marketing-site for D2C, admin-tool for facility) replace one broken one |

---

## Open Questions

> Plain-language explanation of each question + my lean. Decisions called now are mirrored into the Decisions Log; the open ones are explicitly tagged with what would resolve them. The user-facing version of this section is below in §Open-Questions Summary.

### Q1. Should `/me/patients` return cached / pre-joined denormalized notification rule output, or do we run the rules client-side from raw activity?

**What's actually being asked:** The demo runs the three notification rules (No-activity-today / Below-typical / Declining-trend) client-side from each patient's daily activity history. In production this is wrong (A3 + D9). Where does the server-side computation live?

**Options:**
- (a) A Phase 1C scheduled Lambda (offline-detector + daily-rollup) materializes per-patient notifications into a new `Notifications` DDB table; threshold-detector + this new job both write into it; portal reads the table directly.
- (b) Threshold Detector (Phase 1B-rev, already deployed) is extended to evaluate the three behavioral rules — but it runs on shadow deltas, not daily aggregates. So this means **a second Lambda**, scheduled on a daily cadence, that emits to the same Alert History table that 2A-RD already reads.

**Lean:** (b) — keep the existing Alert History table as the single read path; add a `behavioral-notification-detector` Lambda (Phase 1C-light) that runs daily at the facility-local "today rollover" and emits the three rule-types into Alert History with the same shape as Threshold Detector's existing entries.

**What's at stake:** If we don't decide before 2B-FAC-R goes to production, we either ship without the three notification rules (no critical "No activity today" signal) or we ship client-side eval (audit-broken, per-client drift). Both are bad.

---

### Q2. Token storage — what's actually safe on Flutter Web?

**What's actually being asked:** `amazon_cognito_identity_dart_2` defaults to storing tokens in localStorage via `shared_preferences`. localStorage is accessible to any script on the same origin — meaning a successful XSS (any XSS) on `portal.gosteady.co` exfiltrates the refresh token, after which the attacker can mint fresh ID tokens at will, possibly indefinitely depending on Cognito's refresh-token settings.

**Options:**
- (a) Leave it (current behavior). Mitigation: WAF (Phase 3A) blocks injection-style attacks; CSP headers (Phase 3A) restrict scripts to first-party
- (b) Store the refresh token in a `HttpOnly; Secure; SameSite=Strict` cookie. ID token stays in-memory, requested fresh on each page load. Requires a server-side cookie-issuing endpoint (a thin Lambda)
- (c) Don't persist refresh tokens at all — user signs in every session. Painful UX

**Lean:** (a) for 2B development, with CSP + WAF + Same-Origin policy doing the heavy lifting at Phase 3A. Revisit (b) if a security review surfaces it. The cookie path adds infra complexity and the cookie's `Secure` requirement breaks local dev unless we mint a localhost cert.

**What's at stake:** A successful XSS becomes account-takeover material. Mitigated by CSP + WAF at Phase 3A; not addressed within 2B alone.

---

### Q3. Real-time updates — polling cadence vs push?

**What's actually being asked:** 30 s polling on a focused Patient Detail tab generates ~96k extra audit events/day at modeled load (A4). Push (WebSocket / SSE) would be cheaper per event but requires new infra (API Gateway WebSocket API + connection state management).

**Options:**
- (a) Polling, with focus-pause (L12) — current spec
- (b) SSE from API Gateway HTTP API — actually not supported; API Gateway HTTP API doesn't do SSE
- (c) WebSocket via API Gateway WebSocket API — new infra; Phase 2C-shaped work

**Lean:** (a) — polling — for V1. Re-evaluate after launch if audit-log volume is a real issue or if caregivers perceive lag. The Phase 2C SNS / EventBridge build-out is where push naturally lives, alongside email + SMS channels.

**What's at stake:** Audit pipeline volume; caregiver perception of lag. Decision is reversible — polling is the right starting point regardless.

---

### Q4. Add Resident — should the server orchestrate `create-patient + provision-device` atomically, or does the client make two calls?

**What's actually being asked:** US-28 lets a caregiver add a resident with a device ID in one form. That's one user-facing action but two underlying writes (insert into Patients, then provision the device to that new patientId). Where does the orchestration live?

**Options:**
- (a) `POST /patients` body `{displayName, censusId, room, deviceSerial?}` — server orchestrates both writes atomically (Patients create + Devices provision + IoT publish). One audit event per underlying action. If provision fails, server rolls back the Patient create
- (b) Client makes two calls: `POST /patients` (returns new `patientId`), then `POST /devices/{serial}/provision` with that ID. If the second fails, client surfaces "Patient created but device assignment failed — try again" UX

**Lean:** (a) — server orchestrates. Mirrors the 2A-DL L14 pattern (provision is atomic with activate-cmd publish; rollback on publish failure). Atomic UX is simpler for caregiver; the audit chain is cleaner (one PR-level intent, multiple action-level events). Adds maybe 20 lines to 2A-UM.

**What's at stake:** Failure recovery UX, audit-event shape, 2A-UM scope.

---

### Q5. The three behavioral notification rules need to move server-side — what's the scope/timing?

**What's actually being asked:** Per A3 + D9, the rules MUST run server-side. Per Q1's lean (option b), that means a new `behavioral-notification-detector` Lambda scheduled daily. That Lambda needs:
- Daily input data (where? Activity Series is per-session — needs aggregation). Phase 1C daily-rollup is the natural input. **But Phase 1C is also "Planned, no spec" per [ARCHITECTURE.md](ARCHITECTURE.md) §12.**
- A facility-local timezone-aware "today rollover" trigger
- Idempotency keys so reruns don't double-fire

**Lean:** Defer to **Phase 1C-slim-NN** (a sibling of "1C-slim offline detector" already in the queue per the §C26 cloud-side queue). The offline detector that closes the §C11.7 conference-silent-failure gap IS the "no-activity-today" rule. Build the behavioral detector + the offline detector together: they share input shape, trigger cadence, and target table.

**What's at stake:** Whether 2B-FAC-R ships a partial notification UX (only `openAlertCount` from Threshold Detector's existing battery/signal alerts, not the three behavioral rules from the demo) or whether the user-needs spec is materially under-delivered at V1 launch.

---

### Q6. New endpoints — Pause Notifications (US-31) + Care Note (US-44) — land in 2A-UM or in a new subset?

**What's actually being asked:** Today's 2A-UM is a placeholder ("biggest UX surface and biggest unknown" per phase-2a-device-lifecycle.md Out-of-Scope). Pause Notifications and Care Note are mutation endpoints on the Patients row that didn't exist when 2A-UM was first sketched.

**Options:**
- (a) Bundle into 2A-UM. Spec it as the "Patient lifecycle + clinical state" subset
- (b) Spin a new `2A-NN Notifications` subset focused just on US-31 + US-44 + maybe daily-email-digest opt-in (V2)

**Lean:** (a) bundle. The 2A-UM scope (Add Resident, Edit Resident, Discharge, plus user-mgmt for staff users) naturally extends to "all Patient row mutations including the new clinical-context ones." 2A-NN as a separate subset is more CDK-stack overhead than the work justifies.

**What's at stake:** 2A-UM spec timing + scope. Spec doesn't exist yet; this decision shapes it.

---

### Q7. Type-safe models — handwritten or codegen?

**What's actually being asked:** `ApiClient` needs to decode JSON responses into typed Dart classes. Two patterns:
- (a) Handwritten `fromJson` / `toJson` methods on each model class (~20 models × ~30 LOC each = 600 lines of mostly-boilerplate)
- (b) `freezed` + `json_serializable` codegen — concise definitions, generated boilerplate, but adds build_runner to the dev loop

**Lean:** (b) codegen. The boilerplate alone justifies it, and the immutability guarantees from `freezed` catch entire classes of state-management bugs at compile time. `build_runner watch` runs out of the way during dev.

**What's at stake:** ~600 LOC of model boilerplate; small build-tooling complexity bump.

---

### Q8. Internal-tier portal as a separate Flutter build, or unified at one URL? (DECIDED 2026-05-23)

**What's actually being asked:** Original draft proposed a separate build per tier, with the Portal-Internal Cognito client used for the internal build. User flagged this isn't what we want — internal and external users should sign in at the **same URL** (`portal.gosteady.co`) and see role-appropriate UI.

**Decision:** ✅ **Unified portal — one Flutter build, one URL, one Cognito App Client (no secret), role-conditional UI surface inside the bundle.** See L1 + D1. Internal-tier UI affordances (cross-tenant search, audit-reader, internal device actions) appear at runtime when `custom:role` starts with `internal_`; they're absent — both visually and via deferred-component code-splitting — for customer roles. Defense-in-depth: backend 403s any caller hitting internal-only endpoints without the right role claim regardless of UI.

**What this implies upstream — 2A-0 follow-up amendment (now landed inline in [phase-2a-foundation.md](phase-2a-foundation.md) Q8):**
- Today's 2A-0 spec (L4 + D2) configures the JWT authorizer with **two audiences** (`1q9l9ujtsomf3ugq2tnqvdg6d7` Portal-Customer + `gvc7n839vj4ppgioamknlk21c` Portal-Internal). Under the unified model, the authorizer narrows to **one audience** — Portal-Customer.
- Portal-Internal client is **not deleted** but is repurposed for non-browser internal tools (CLI auth, server-side admin scripts where the client secret can be handled safely). It's no longer in the API's authorizer audience list.
- **Token lifetimes for internal users — the original plan didn't work.** I'd initially proposed having the Pre-Token Generation Lambda V2 override the `exp` claim for `internal_*` roles. **Cognito's Pre-Token V2 cannot override reserved claims** (`exp`, `iat`, `iss`, `aud`, `sub`) — only custom/non-reserved claims. The token's actual validity is set by Cognito from the App Client's `idTokenValidity` config and isn't per-user customizable. **Revised approach (Option A in 2A-0 Q8):** app-layer enforcement. All web users get Portal-Customer's 15-min idle / 30-day refresh. A new `enforce_internal_session_age(claims, max_age_seconds=4*3600)` helper in `_shared/api_authz.py` is called from `audit_middleware` before every handler — for `internal_*` roles, rejects (401) if `iat` claim is > 4 h old (the absolute cap). The Flutter SPA additionally tracks user-activity timestamp for `internal_*` roles and forces re-auth at 30-min idle. **Pre-prod hardening:** Option B (add a third no-secret Cognito App Client with the tighter Cognito-enforced lifetimes, double-auth flow) is documented but deferred — same pattern as Phase 1.5 multi-account.
- **Filed as:** "Phase 2A-0 follow-up — unify JWT authorizer audience + `enforce_internal_session_age`" — ~30 lines total (1-line CDK + ~15-line helper + ~15-line middleware wiring). Lands as a small amendment commit, not its own subset.

**What this means for 2B:**
- Drops `--dart-define=PORTAL_TIER=*` from the build define list (see updated §Configuration)
- `lib/auth/auth_service.dart` consumes one Cognito client ID, not two
- 2B-INT becomes "role-conditional UI additions inside the unified build" (per updated §Sub-phase split row + §2B-INT detailed scope)

**What's at stake:** Operational simplicity at Phase 3A (one CloudFront distribution + one ACM cert vs two); one Cognito client to maintain; one URL for internal staff to remember. The unified model is also more consistent with [ARCHITECTURE.md](ARCHITECTURE.md) §4's "internal access is allowed but always visible to compliance" framing — the obscurity-layer that the dual-client setup baked in was inconsistent with the rest of the security architecture, which is JWT-claim-based throughout.

---

### Q9. Where do "loading skeletons" / "empty states" / "error pages" live?

**What's actually being asked:** Every screen needs three states beyond "happy path": loading, empty, error. Today's demo uses spinners + empty-state copy that's specific to each screen. In V1 production we want a consistent library.

**Lean:** Define a 3-component library (`LoadingState`, `EmptyState`, `ErrorState`) in `lib/state/feedback/` that each major route consumes. Skeletons rendered per-card type. **Land in 2B-POL.** Until then, screens reuse the demo's per-screen empty states (acceptable for dev / preview deploys).

**What's at stake:** UI consistency at launch; how much "polish backlog" gets carried into V1.1.

---

### Q10. Should `?w=` viewport override stay in the production build behind a flag, or be stripped entirely?

**What's actually being asked:** Useful for QA but a foot-gun if a customer support engineer accidentally shares a `?w=390` link with a customer.

**Lean:** Per L17 — strip from production builds via `--dart-define=DEBUG_VIEWPORT=0` default. Dev + preview builds keep it.

---

### Q11. Forgot Password — Cognito self-service vs admin-only reset?

**What's actually being asked:** Cognito ships a self-service forgot-password flow (email a code to the registered address). Some compliance regimes require admin-only resets. V1 user-needs implies self-service (US-01 mentions "Forgot-password flow exists (not in demo)").

**Lean:** Self-service via Cognito's `ForgotPassword` API. Email comes from the SES verified domain (already configured per Phase 0A-rev). Land in 2B-0.

**What's at stake:** Onboarding friction for new staff users; security posture around password reset (Cognito's flow is industry-standard).

---

### Q12. Should the Census poll the full `/me/patients` every 60 s, or just stale rows / page 1?

**What's actually being asked:** A facility_admin with 200 residents polling every 60 s means 200 patient rows refetched per minute per signed-in user × `openAlertCount` fan-out cost. That's the highest server-side cost we've spec'd.

**Lean:** First page only (default page size 50) on the poll. The user can only see one page at a time anyway; lazy-load next pages on scroll, no polling there. **Note:** the open-alert count goes stale on off-screen rows, but only for the polling delta. Acceptable.

**What's at stake:** Server-side cost at large-scope users.

---

### Decision summary

| # | Question | Resolution |
|---|---|---|
| Q1 | Server-side notification rules location | ⏳ Lean: Phase 1C-slim sibling Lambda (see Q5) |
| Q2 | Token storage security posture | ⏳ Lean: localStorage + CSP + WAF (revisit after security review) |
| Q3 | Polling vs push for real-time | ⏳ Lean: polling in V1; push lands in Phase 2C |
| Q4 | Add Resident orchestration locus | ⏳ Lean: server-side atomic (2A-UM scope) |
| Q5 | Behavioral notification detector — phase + scope | ⏳ Lean: Phase 1C-slim-NN sibling of the offline detector |
| Q6 | Pause + Care Note endpoints — 2A-UM or new subset | ⏳ Lean: bundle into 2A-UM |
| Q7 | Codegen for API models | ⏳ Lean: freezed + json_serializable |
| Q8 | Internal portal — separate build or unified | ✅ **Unified — one build, one URL, one Cognito client.** Pre-Token Lambda gets a shorter-exp override for internal roles; 2A-0 authorizer narrows to one audience |
| Q9 | Loading / empty / error state library | ⏳ Lean: ship in 2B-POL |
| Q10 | Viewport override in production | ✅ Strip via flag (L17) |
| Q11 | Forgot password flow | ⏳ Lean: Cognito self-service |
| Q12 | Census polling scope | ⏳ Lean: page 1 only |

Two of twelve decided (Q8 + Q10); ten require user input. The user-facing summary with ELI5 impact is in the final response (not embedded in this spec to keep the spec itself focused on engineering content).

---

## Changelog

| Date | Author | Change |
|------|--------|--------|
| 2026-05-23 | Jace + Claude (portal session) | Initial spec drafted as the Portal Integration umbrella. Split into 5 subsets (2B-0 Foundation, 2B-FAC-R Reads, 2B-FAC-W Writes, 2B-D2C Household, 2B-INT Internal, 2B-POL Polish) to match the 2A subset pattern. Demand-side sourced from [user-needs.md](../user-needs.md) (44 user stories, V1 single Care Staff role); supply-side built on [phase-2a-foundation.md](phase-2a-foundation.md) / [phase-2a-read.md](phase-2a-read.md) / [phase-2a-alert-actions.md](phase-2a-alert-actions.md) / [phase-2a-device-lifecycle.md](phase-2a-device-lifecycle.md). Working mockup is the live demo at [gosteady.co/facilitydemo](https://gosteady.co/facilitydemo) — 90% of facility UI ports straight via FacilityMockData → FacilityRepository (ApiClient-backed) constructor swap. Three user-needs items (US-44 Care Note, US-31 Pause Notifications, US-22 three behavioral notification rules) need new backend work — Care Note + Pause flow to 2A-UM (Q6); the three rules need a new Phase 1C-slim sibling Lambda (Q5). Twelve open questions surfaced; one decided inline, eleven require user input — summarized for product review in the conversation thread that accompanies this draft. |
| 2026-05-23 | Jace + Claude (portal session, same day) | **Q8 resolved + spec revised: unified portal.** User pushed back on the original dual-build / dual-URL framing for internal vs customer. New model: one Flutter build, one URL (`portal.gosteady.co`), one Cognito App Client (Portal-Customer without secret). Internal-tier users sign in at the same URL; role-conditional UI surfaces appear at runtime based on `custom:role`. Security boundary stays JWT-claim-based (defense-in-depth: backend 403s any caller hitting internal-only endpoints without the right role regardless of UI). Portal-Internal Cognito client (has secret) is retired from browser use, reserved for non-browser internal tools (CLI / server-side scripts). **Implies a 2A-0 follow-up amendment** (~20-line change): JWT authorizer audience narrows from two clients to one; Pre-Token Generation Lambda V2 gets a small extension to override `exp` claim shorter for `internal_*` roles (preserves the tighter security posture the dual-client setup originally gave internal users). Updated: L1, D1, Q8, §2B-INT detailed scope, §Configuration table, §Verification Commands. Decided count is now 2/12 (Q8 + Q10). |

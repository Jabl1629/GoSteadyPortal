# Phase 2A-RD — Patient Reads (read-only data subset)

## Overview
- **Phase**: 2A-RD (Patient Reads subset of Phase 2A)
- **Status**: ✅ Deployed (dev) 2026-05-23 — 23/23 synthetic smoke PASS; real-data validated
- **Branch**: feature/infra-scaffold
- **Date Started**: 2026-05-23
- **Date Completed**: 2026-05-23 (dev)

Ships the five GET endpoints that let the Flutter dashboard render real
patient data (instead of mocks) for the first time: single-patient detail,
activity sessions over a time range, alert history, the current user's
patient list, and a census roster. This is the **bridge from "telemetry is
arriving and being stored correctly" (Phase 1B-rev / 1.6 / 1.7 / 2A-DL) to
"caregivers can actually look at it"** (Phase 2B).

The endpoints are pure reads — no DDB writes, no IoT publishes, no state
machine. The complexity is concentrated in three places: (1) role-aware
scope resolution (each role sees a different patient set), (2) the DDB
query plan for each access pattern (which GSI for which endpoint), and (3)
pagination semantics that hold up under the dashboard's expected usage.

**Dependency on 2A-0 (foundation):** 2A-RD assumes the API Gateway HTTP
API, JWT authorizer, `_shared/api_authz.py` (`extract_claims`,
`enforce_tenancy`, `enforce_scope`, `is_internal`, `require_role`), shared
error envelope, and `audit_middleware` are already deployed. `2A-0` must
ship before this spec's implementation starts.

**Dependency on 2A-DL (precedents to copy):** 2A-DL established the
single-Lambda-per-route-group pattern (D1), the per-handler audit catalog
constants (`_shared/audit_catalog.py`), and the deploy ergonomics (bundle
the audit-stack subscription filter add into the same deploy per 2A-0 D9).
2A-RD mirrors all three.

## Locked-In Requirements
> Decisions finalized in this or prior phases that CANNOT change without
> cascading impact.

| # | Requirement | Decided In | Rationale |
|---|-------------|-----------|-----------|
| L1 | Five GET endpoints in this subset: `GET /patients/{id}`, `GET /patients/{id}/activity?range=`, `GET /patients/{id}/alerts`, `GET /me/patients`, `GET /facilities/{f}/censuses/{c}/patients` | ARCHITECTURE.md §12 Phase 2A-RD row | The minimum surface to make the Flutter dashboard render real patient/activity/alert data |
| L2 | Tenancy enforced via 2A-0's `enforce_tenancy(claims, target_client_id)` helper on every handler that resolves a single patient (or via JWT-claim-derived scope query for the list endpoints). Internal roles bypass tenancy enforcement | ARCHITECTURE.md T2 + Phase 2A-0 L5 | Hard security boundary; centralized helper prevents per-handler drift |
| L3 | Scope enforced via 2A-0's `enforce_scope(claims, target_facility_id, target_census_id)` helper for caregiver / facility_admin reads. `family_viewer` uses an explicit `linkedPatientIds` membership check from RoleAssignments | ARCHITECTURE.md §4 RBAC | Different roles have structurally different scope models; one helper for the hierarchical roles, an explicit list for family_viewer |
| L4 | Every successful read emits an audit event via `audit_middleware` (per 2A-0 Q2 — emit on success + 403 + 500; skip 400/404/429). Event names from `_shared/audit_catalog.py` | Phase 1.7 §Audit Event Catalog + Phase 2A-0 Q2 | The legal-evidence requirement for "who looked at which patient" lives here, not in operational logs (which scrub PII per Phase 1.6) |
| L5 | DDB access patterns use existing GSIs only — no new GSIs added in this subset. Specifically: Patients `by-client-status` for `/me/patients` (admin tiers), Patients `by-census-status` for `/facilities/{f}/censuses/{c}/patients`; Activity Series `by-date` for `/patients/{id}/activity?range=`; Alert History base PK for `/patients/{id}/alerts` | ARCHITECTURE.md §6 Data Model | Existing GSIs cover every read pattern this subset needs. Adding GSIs is a separate, more deliberate decision (cost + ProvisionedThroughput planning) |
| L6 | Activity range parameter accepts `24h`, `7d`, `30d` only in v1; longer ranges return 400 with a pointer to the daily-rollup endpoint (Phase 1C). Default range when omitted: `24h` | This spec — Q1 decided 2026-05-23 | Bounds the raw-session query cost. Dashboard's "today" view is 24h; "trends" view is 7d/30d. Longer ranges require the rollups (Phase 1C) |
| L7 | Pagination: cursor-based via opaque `nextCursor` token (base64 of DDB's `LastEvaluatedKey`). Default page size 50, max 200. Applies to `/patients/{id}/activity`, `/patients/{id}/alerts`, `/me/patients`, `/facilities/{f}/censuses/{c}/patients` | This spec — Q2 decided 2026-05-23 | Cursor-based avoids offset-pagination drift on writes; matches what API Gateway HTTP API + DDB naturally express. 50 default fits typical dashboard widgets without overfetching |
| L8 | Alert filter via `?status=unacknowledged|acknowledged|all` query param. Default `unacknowledged` (the operationally interesting subset). Default sort newest-first | This spec — Q4 decided 2026-05-23 | Unacked alerts are the caregiver's actionable inbox; acked alerts are historical reference. Default matches the primary use case |
| L9 | `/me/patients` enriches each row with `censusName` + `facilityName` via a single batch read from Organizations table (no per-row N+1). Cap the batch at 100 unique census IDs per response | This spec — Q5 decided 2026-05-23 | UI groups patients by census on the home screen; pre-joining server-side is one round-trip vs. N from the client. Cap matches the page-size cap |
| L10 | Single Lambda for all 2A-RD routes (`gosteady-{env}-patient-api`), route dispatch internally. Mirrors 2A-DL D1 | 2A-DL D1 precedent | Cold-start cost of N Lambdas outweighs the routing tax of one; easier shared code |
| L11 | Audit-stack subscription filter for `patient-api`'s log group is bundled into the 2A-RD deploy (per 2A-0 D9). No "between-revisions gap" tolerated per Migration Pattern 18.8 | Phase 2A-0 D9 + Migration Pattern 18.8 | Deploying the API and the audit filter separately would create a window where reads emit audit-shape log lines that never reach S3 |
| L12 | Internal-tier roles (`internal_support` read-only, `internal_admin` read+write) can hit all 2A-RD endpoints cross-tenant. Every cross-tenant read emits an audit event tagged at elevated severity (auto-stamped by audit-forwarder Lambda per Phase 1.7 L8) | ARCHITECTURE.md §4 Internal Access | Internal access is allowed but always visible to compliance |

## Assumptions
> Beliefs that drive this design but haven't been fully validated.

| # | Assumption | Risk if Wrong | Validation Plan |
|---|-----------|---------------|-----------------|
| A1 | The Patients `by-census-status` GSI (Phase 0B-rev) has enough projected attributes to render a roster row without a follow-up GetItem per patient | Roster endpoint does N+1 GetItems, exceeding latency budget at facility scale (~50–200 patients) | Confirm projection: `by-census-status` should project `displayName`, `status`, `timezone`, `facilityId`. If not, either project them now or accept a BatchGetItem fallback path |
| A2 | Activity Series `by-date` GSI's PK=patientId + SK=date is the right shape for time-range queries (vs. base table SK=timestamp) | Range queries hit the base table inefficiently | The base table's SK is `session_end` (UTC ISO 8601), so a SK BETWEEN range works directly. `by-date` is for daily-rollup aggregations (Phase 1C). For 2A-RD v1, query the base table directly; revisit if hot |
| A3 | Alert History pagination by base PK (patientId) + SK (compound `{eventTs}#{alertType}`) gives stable newest-first ordering | Pagination drifts as new alerts arrive | DDB Query in DESC order on SK gives newest-first; cursor tokens carry the (PK, SK) pair so subsequent pages are deterministic regardless of new writes between calls |
| A4 | A `family_viewer`'s `linkedPatientIds` set fits in the JWT custom claim under Cognito's 2 KB token-size practical limit | Token bloat for power-users with many linked patients | Cognito ID/Access tokens are ~1.5 KB base; `linkedPatientIds` is a comma-separated string of UUIDs (~40 bytes each); even 25 linked patients adds ~1 KB. If we ever see >25 linked patients (unlikely for family_viewer), fall back to a RoleAssignments lookup per request |
| A5 | The dashboard's home screen will fan out to `/me/patients` once + `/patients/{id}/activity?range=24h` per visible patient. Acceptable at typical scale (~5–20 patients on screen) | UI becomes laggy at high-scope users | Caregiver with 200 patients is the worst case; mitigate via UI pagination (show first page, lazy-load activity per visible row). Add a batch `/patients/activity?ids=` if measured latency demands it |
| A6 | `internal_support` is a meaningful tier separate from `internal_admin` for the read endpoints (both allowed; the write endpoints in 2A-AA/UM will differentiate) | Same effective permissions → unused role | Per ARCHITECTURE.md §4, `internal_support` is sales/CS/account-management who need read-only views; `internal_admin` is on-call/ops. The distinction matters more for writes (which 2A-RD doesn't ship) but the audit-trail tagging is still useful at read time |
| A7 | Audit log volume from read events is sustainable under the dashboard's fan-out pattern | Audit pipeline overwhelmed; Firehose backs up; alarm fires | Per Phase 1.7 cost model (~$0.50/mo at 10k events/day MVP, ~$2.50/mo at busy 2A): a dashboard load = ~10 audit events per user-session; 100 caregivers × 10 sessions/day = 10k events/day. Well within the modeled scale. Monitor the Phase 1.7 freshness alarm after 2A-RD goes live |

## Scope

### In Scope

#### API endpoints (`/api/v1/patients/*`, `/api/v1/me/patients`, `/api/v1/facilities/*`)

| Method | Path | Purpose | Required Role(s) |
|--------|------|---------|------------------|
| `GET` | `/patients/{id}` | Single patient detail (display name, status, timezone, current census/facility, latest device assignment summary) | family_viewer (linked), caregiver (scope), facility_admin+, household_owner (own), internal_* |
| `GET` | `/patients/{id}/activity?range=24h\|7d\|30d&cursor=` | Activity sessions over time range, paginated, newest-first | same as above |
| `GET` | `/patients/{id}/alerts?status=unacknowledged\|acknowledged\|all&cursor=` | Alert history, filtered + paginated, newest-first | same as above |
| `GET` | `/me/patients?cursor=` | Current user's patient list (role-derived scope), enriched with censusName + facilityName | family_viewer / caregiver / facility_admin / client_admin / household_owner / internal_* (internal sees cross-tenant; explicit `?clientId=` required for safety) |
| `GET` | `/facilities/{facilityId}/censuses/{censusId}/patients?cursor=` | Census roster | caregiver (scope), facility_admin (facility), client_admin (client), internal_* |

#### Per-role scope resolution (the core complexity of this subset)

| Role | Scope source | Query pattern |
|------|--------------|---------------|
| `family_viewer` | `linkedPatientIds` from RoleAssignments (NOT in JWT claims — too large for some users) | BatchGetItem on Patients table keyed by `linkedPatientIds` |
| `caregiver` | `custom:censuses` from JWT | Query Patients `by-census-status` GSI per census in claim; union results |
| `facility_admin` | `custom:facilities` from JWT (empty = all facilities in client) | If facilities listed: per-facility scoped query (fan out per facility, query censuses, query patients). If empty: query Patients `by-client-status` GSI |
| `client_admin` | `custom:clientId` from JWT | Query Patients `by-client-status` GSI |
| `household_owner` | `custom:clientId` (the synthetic `dtc_*` client) | Same as client_admin pattern |
| `internal_support` / `internal_admin` | Cross-tenant; explicit `?clientId=` query param required on `/me/patients` to avoid accidental cross-tenant scans | Query Patients `by-client-status` for the named client |

**Scope-vs-tenancy distinction:**
- `enforce_tenancy(claims, target_client_id)` — answers "is this user's client the same as this resource's client (or are they internal)?" Always called on single-patient routes after the patient is fetched.
- `enforce_scope(claims, target_facility_id, target_census_id)` — answers "does this user's facility/census claim cover this resource?" Only meaningful for `caregiver` / `facility_admin` roles. `family_viewer` uses the explicit `linkedPatientIds` check instead.

#### Response shapes

**`GET /patients/{id}`**
```json
{
  "patient": {
    "patientId": "pat_abc123",
    "displayName": "Jane D.",
    "status": "active",
    "timezone": "America/Los_Angeles",
    "clientId": "client_005",
    "facilityId": "fac_012",
    "facilityName": "Sunrise Manor",
    "censusId": "cen_044",
    "censusName": "East Wing",
    "currentDevice": {
      "serialNumber": "GS0000001234",
      "status": "active_monitoring",
      "lastSeen": "2026-05-23T14:32:11Z"
    } | null
  }
}
```

**`GET /patients/{id}/activity?range=24h`**
```json
{
  "sessions": [
    {
      "sessionStart": "2026-05-23T14:02:00Z",
      "sessionEnd":   "2026-05-23T14:18:00Z",
      "date":         "2026-05-23",
      "timezone":     "America/Los_Angeles",
      "steps":        142,
      "distanceFt":   340.5,
      "activeMinutes": 16,
      "deviceSerial": "GS0000001234",
      "roughnessR":   0.0432,
      "surfaceClass": "indoor",
      "firmwareVersion": "0.11.0-wipe-cmd"
    },
    ...
  ],
  "range": "24h",
  "windowStart": "2026-05-22T14:32:00Z",
  "windowEnd":   "2026-05-23T14:32:00Z",
  "nextCursor": "eyJwSyI6Li4uLCJzSyI6Li4ufQ==" | null
}
```

**`GET /patients/{id}/alerts?status=unacknowledged`**
```json
{
  "alerts": [
    {
      "eventTimestamp": "2026-05-23T13:45:00Z",
      "alertType":      "battery_critical",
      "severity":       "critical",
      "source":         "cloud",
      "acknowledged":   false,
      "data": { "batteryPct": 0.04 },
      "deviceSerial":   "GS0000001234"
    },
    ...
  ],
  "filter": "unacknowledged",
  "nextCursor": null
}
```

**`GET /me/patients`**
```json
{
  "patients": [
    {
      "patientId": "pat_abc123",
      "displayName": "Jane D.",
      "status": "active",
      "facilityName": "Sunrise Manor",
      "censusName": "East Wing",
      "currentDeviceSerial": "GS0000001234" | null,
      "lastActivityAt": "2026-05-23T14:18:00Z" | null,
      "openAlertCount": 1,
      "notificationsPaused": {            // null when not currently paused
        "until": 1780358615,              // epoch seconds (DDB Number)
        "reason": "in_hospital",
        "pausedAt": 1779926615,
        "pausedBy": "<userId>",
        "daysRemaining": 5
      }
    },
    ...
  ],
  "nextCursor": null,
  "scope": {
    "role": "caregiver",
    "facilityCount": 1,
    "censusCount": 2
  }
}
```

**`GET /facilities/{f}/censuses/{c}/patients`**
```json
{
  "census": {
    "facilityId": "fac_012",
    "facilityName": "Sunrise Manor",
    "censusId": "cen_044",
    "censusName": "East Wing"
  },
  "patients": [
    {
      "patientId": "pat_abc123",
      "displayName": "Jane D.",
      "status": "active",
      "currentDeviceSerial": "GS0000001234" | null,
      "lastActivityAt": "2026-05-23T14:18:00Z" | null,
      "openAlertCount": 1,
      "notificationsPaused": { ... } | null   // same projection as /me/patients
    },
    ...
  ],
  "nextCursor": null
}
```

> **2026-05-27 amendment (US-31).** `notificationsPaused` added to the
> shared `_patient_row_view` projection so Census tile / list row can
> render the paused-bell icon without a per-row patient-detail fetch.
> Same active-only nullable shape as the detail view's projection — null
> when not currently paused. Single Lambda code change; no infra delta.

#### Error envelope (extends 2A-0 catalog)

| Code | HTTP | Meaning |
|------|------|---------|
| `PATIENT_NOT_FOUND` | 404 | Patient ID doesn't exist (or caller doesn't have permission to know) |
| `FACILITY_NOT_FOUND` | 404 | Facility ID doesn't exist (or caller doesn't have permission to know) |
| `CENSUS_NOT_FOUND` | 404 | Census ID doesn't exist |
| `INVALID_RANGE` | 400 | Activity range outside the accepted set (`24h`/`7d`/`30d`) |
| `INVALID_CURSOR` | 400 | Cursor token malformed or expired |
| `INVALID_STATUS_FILTER` | 400 | Alert status filter outside the accepted set |
| `MISSING_CLIENT_PARAM` | 400 | Internal-tier user hit `/me/patients` without an explicit `?clientId=` |
| `TENANCY_VIOLATION` | 403 | Caller's client doesn't match the patient's client (and caller isn't internal) — same code as 2A-DL |
| `OUT_OF_SCOPE` | 403 | Caller's facility/census claims don't cover the target — same code as 2A-DL |
| `INSUFFICIENT_PERMISSIONS` | 403 | Role not allowed on this route (e.g., `family_viewer` hitting a census roster) |

To distinguish "patient doesn't exist" from "you don't have permission to see this patient," **both surface as 404** (`PATIENT_NOT_FOUND`). Returning 403 in the latter case leaks existence — the user could enumerate patient IDs by probing. The 403 codes are for routes/actions where the path itself implies you should know the resource (e.g., a caregiver hitting force-reset on a device outside their scope).

#### Audit hooks

All endpoints emit via the 2A-0 `audit_middleware` decorator with new event constants in `_shared/audit_catalog.py`:

| Event | Trigger | Subject fields |
|-------|---------|----------------|
| `patient.read` | `GET /patients/{id}` success | `patientId`, `clientId`, `facilityId`, `censusId` |
| `patient.activity.read` | `GET /patients/{id}/activity` success | `patientId`, `clientId`, `range`, `sessionCount` |
| `patient.alert.read` | `GET /patients/{id}/alerts` success | `patientId`, `clientId`, `filter`, `alertCount` |
| `patient.list.read` | `GET /me/patients` success | `actorClientId`, `scopeRole`, `patientCount` |
| `census.roster.read` | `GET /facilities/{f}/censuses/{c}/patients` success | `clientId`, `facilityId`, `censusId`, `patientCount` |

`internal_access: true` + `severity: elevated` auto-stamped by audit-forwarder Lambda (Phase 1.7 D8) when `actor.role` starts with `internal_`.

#### Tenancy + scope enforcement (per L2 + L3)

Every handler that resolves a single patient (`GET /patients/{id}`, `…/activity`, `…/alerts`) does:
1. `GetItem` on Patients table.
2. If not found → 404 `PATIENT_NOT_FOUND` (do NOT audit — 404 is skipped per L4).
3. `enforce_tenancy(claims, patient.clientId)` — raises `ApiError(403, TENANCY_VIOLATION)` on mismatch.
4. For `caregiver` / `facility_admin` roles: `enforce_scope(claims, patient.facilityId, patient.censusId)` — raises `ApiError(403, OUT_OF_SCOPE)` on mismatch.
5. For `family_viewer` role: explicit check that `patient.patientId ∈ linkedPatientIds` — raises 404 (not 403, per existence-leak above).
6. Continue to data fetch.

For list endpoints (`/me/patients`, `/facilities/…/patients`), the scope is the query input (not the result), so enforcement happens before the DDB query — the query itself is bounded by the user's scope.

### Out of Scope (Deferred)

- **`PATCH /alerts/{patientId}/{timestamp}` (alert acknowledgement)** — Phase 2A-AA
- **Per-patient threshold overrides** (`GET /patients/{id}/thresholds`, `PUT …`) — Phase 2A-AA (writes) + 2A-RD-follow-up (reads, if needed)
- **Daily / weekly rollup endpoints** (`/patients/{id}/activity/daily?range=90d`) — Phase 1C (rollup Lambda) + Phase 2A-RD-follow-up (endpoint)
- **Facility-wide patient list** (`GET /facilities/{f}/patients`) — Phase 2A-RD-follow-up if facility_admin UX demands it; for v1 they hit `/me/patients` which naturally returns their facility's patients via JWT scope
- **Cross-patient activity search / filter** (e.g., "all patients with <100 steps yesterday") — Phase 2A-RD-follow-up; would benefit from a dedicated GSI
- **Notification preferences endpoints** (`GET /me/notification-prefs`) — Phase 2A-UM
- **User profile self-edit** (`PATCH /me`) — Phase 2A-UM
- **Real-time push of activity/alerts** to the portal — Phase 2B (WebSocket or SSE)
- **Snippet retrieval endpoints** (`GET /patients/{id}/snippets`) — out of v1 portal scope; snippets are for offline ML retrain, not caregiver-facing
- **Audit reader endpoints** (compliance role pulling a patient's audit trail) — Phase 1.7.1 / Athena-backed; not a portal-API concern
- **Custom domain** — Phase 3A (CloudFront)
- **Response caching** — out for v1; reads always go to DDB. Revisit if a specific endpoint shows hot-key patterns

## Architecture

### Infrastructure Changes

**Existing stack populated further:** `GoSteady-{Env}-Api` (adds ~12 resources to 2A-0 + 2A-DL baseline):

- 1 × `AWS::Lambda::Function` (`gosteady-{env}-patient-api`)
- 1 × `AWS::IAM::Role` + 1 × `AWS::IAM::Policy` (patient-api execution role; grants `kms:Decrypt`+`kms:GenerateDataKey` on IdentityKey CMK for identity-table reads; `dynamodb:GetItem`+`Query`+`BatchGetItem` on Patients / Activity Series / Alert History / Organizations / RoleAssignments / DeviceAssignments / Device Registry tables; `logs:CreateLogStream`+`PutLogEvents` on its own log group)
- 5 × `AWS::ApiGatewayV2::Route` + 5 × `AWS::ApiGatewayV2::Integration` (one per endpoint)
- 1 × `AWS::Lambda::Permission` (API Gateway → patient-api)
- 1 × `AWS::CloudWatch::Alarm` (`gosteady-{env}-patient-api-errors` — Lambda Errors > 0 in 5 min, per 1.6 pattern)
- 1 × `AWS::CloudWatch::Alarm` (`gosteady-{env}-patient-api-errors-log` — ERROR-pattern filter, per 1.6 pattern)

**Modified stacks:**
- `GoSteady-{Env}-Audit` — add `/aws/lambda/gosteady-{env}-patient-api` to the subscription-filter source list (per L11). Bundled into 2A-RD deploy (D9 of 2A-0).

### Data Flow

```
Flutter portal
   │
   │ Authorization: Bearer <Cognito JWT>
   ▼
API Gateway HTTP API (JWT authorizer from 2A-0)
   │ event.requestContext.authorizer.jwt.claims
   ▼
patient-api Lambda
   │ audit_middleware decorator wraps handler
   │
   ├── Route: GET /patients/{id}
   │    │
   │    ├──► Patients.GetItem(patientId)
   │    ├── enforce_tenancy(claims, patient.clientId)
   │    ├── enforce_scope OR linkedPatientIds check (per role)
   │    ├──► DeviceAssignments.Query(patientId, by-patient GSI; current row)
   │    ├──► Device Shadow.GetThingShadow (for lastSeen)  [optional — see Q7]
   │    ├──► Organizations.BatchGetItem (facility+census names)
   │    └── emit_audit('patient.read', ...)
   │
   ├── Route: GET /patients/{id}/activity?range=
   │    │
   │    ├──► Patients.GetItem (auth chain identical to above)
   │    ├── translate range → SK BETWEEN (windowStart, windowEnd)
   │    ├──► Activity Series.Query(patientId, SK BETWEEN, DESC, limit=pageSize)
   │    └── emit_audit('patient.activity.read', ...)
   │
   ├── Route: GET /patients/{id}/alerts?status=
   │    │
   │    ├──► Patients.GetItem (auth chain identical)
   │    ├──► Alert History.Query(patientId, DESC, limit=pageSize)
   │    │    Filter expression: acknowledged = :v_false  (if status=unacknowledged)
   │    │                       acknowledged = :v_true   (if status=acknowledged)
   │    │                       (none)                   (if status=all)
   │    └── emit_audit('patient.alert.read', ...)
   │
   ├── Route: GET /me/patients
   │    │
   │    ├── Switch on claims.role:
   │    │    family_viewer    → RoleAssignments.GetItem(userId) → BatchGetItem on Patients
   │    │    caregiver        → loop censuses → Patients.Query(by-census-status GSI)
   │    │    facility_admin   → per-facility resolve OR Patients.Query(by-client-status if scope empty)
   │    │    client_admin     → Patients.Query(by-client-status GSI)
   │    │    household_owner  → Patients.Query(by-client-status GSI for own dtc_* client)
   │    │    internal_*       → Patients.Query(by-client-status GSI for ?clientId= param)
   │    ├──► Organizations.BatchGetItem (facility+census names, capped to 100 unique census IDs)
   │    ├──► [optional v1.1] Open alert counts per patient — Alert History.Query w/ count + filter
   │    └── emit_audit('patient.list.read', ...)
   │
   └── Route: GET /facilities/{f}/censuses/{c}/patients
        │
        ├── enforce_scope(claims, facilityId, censusId)
        ├──► Organizations.GetItem (facility + census; existence + names)
        ├──► Patients.Query(censusId, by-census-status GSI, DESC, limit=pageSize)
        └── emit_audit('census.roster.read', ...)

[Side-channel: audit emission]
patient-api Lambda's audit-shape log line
   │
   ▼ (existing 1.7 pipeline + 2A-RD's new subscription filter on patient-api log group)
audit-forwarder Lambda → gosteady-{env}-audit log group → Firehose → S3
```

### Interfaces

#### Query parameter semantics

| Param | Endpoints | Values | Default | Validation |
|-------|-----------|--------|---------|-----------|
| `range` | `…/activity` | `24h` \| `7d` \| `30d` | `24h` | Else 400 `INVALID_RANGE` |
| `status` | `…/alerts` | `unacknowledged` \| `acknowledged` \| `all` | `unacknowledged` | Else 400 `INVALID_STATUS_FILTER` |
| `cursor` | list endpoints | base64 of DDB `LastEvaluatedKey` | none | Else 400 `INVALID_CURSOR` |
| `clientId` | `/me/patients` (internal only) | client ID string | none (required for internal) | Else 400 `MISSING_CLIENT_PARAM` for internal callers |

#### Pagination contract

- Default page size: **50**
- Max page size: **200** (override via `?pageSize=` query param; capped server-side)
- `nextCursor` is **opaque** — clients must round-trip it unmodified; server validates structure
- Cursor lifetime: not formally guaranteed, but stable for hours (it's just an encoded DDB key — no server-side state to expire)
- End of results: `nextCursor: null`

#### Auth scope helpers (new in `_shared/api_authz.py`, extends 2A-0)

```python
def linked_patient_ids(claims) -> set[str]:
    """For family_viewer: load linkedPatientIds from RoleAssignments.
    Returns empty set for other roles. Cached per-invocation."""

def enforce_patient_access(claims, patient: dict) -> None:
    """Single-patient access check covering all roles. Raises:
       - 403 TENANCY_VIOLATION (customer roles only) if client mismatch
       - 403 OUT_OF_SCOPE (caregiver/facility_admin) if facility/census mismatch
       - 404 PATIENT_NOT_FOUND (family_viewer) if not in linkedPatientIds
       - Pass-through (internal_*) — audit-tagged elsewhere"""

def resolve_list_scope(claims) -> dict:
    """For /me/patients: returns a query plan dict describing which DDB
       access pattern to use for this caller's role + claims.
       Shape: {pattern: 'by-census' | 'by-client' | 'by-patient-ids',
               clientId: str, facilityIds: list, censusIds: list,
               patientIds: list}"""
```

## Implementation

### Files Changed / Created

| File | Change Type | Description |
|------|------------|-------------|
| `infra/lib/stacks/api-stack.ts` | Modified | Wire `patient-api` Lambda + 5 routes + 2 alarms |
| `infra/lib/constructs/patient-api-lambda.ts` | New | Lambda construct mirroring `device-api-lambda.ts` |
| `infra/lib/stacks/audit-stack.ts` | Modified | Add `/aws/lambda/gosteady-{env}-patient-api` to subscription-filter source list (per L11) |
| `infra/lambda/patient-api/handler.py` | New | Route dispatch + per-route handlers |
| `infra/lambda/patient-api/queries.py` | New | DDB query helpers (Patients/Activity/Alerts/Organizations/RoleAssignments) — pure functions, unit-testable |
| `infra/lambda/patient-api/pagination.py` | New | Cursor encode/decode + page-size validation |
| `infra/lambda/patient-api/ranges.py` | New | `range=24h\|7d\|30d` → (windowStart, windowEnd) — pure function |
| `infra/lambda/patient-api/scope.py` | New | List-scope resolution per role (consumes `_shared/api_authz.resolve_list_scope`) |
| `infra/lambda/_shared/api_authz.py` | Modified | Add `linked_patient_ids`, `enforce_patient_access`, `resolve_list_scope` |
| `infra/lambda/_shared/audit_catalog.py` | Modified | Add 5 new event constants (`AUDIT_PATIENT_READ`, `AUDIT_PATIENT_ACTIVITY_READ`, `AUDIT_PATIENT_ALERT_READ`, `AUDIT_PATIENT_LIST_READ`, `AUDIT_CENSUS_ROSTER_READ`) |
| `docs/specs/ARCHITECTURE.md` | Modified | §5 update Api stack row to "2A-0 + 2A-DL + 2A-RD deployed"; §15 add `patient-api` Lambda; §17 flip 2A-RD status; §12 phase plan table flip 2A-RD row |
| `docs/firmware-coordination/2026-04-17-cloud-contracts.md` | Modified | New §C-section: 2A-RD deploy outcome (cloud-only, no firmware action) |

### Dependencies

- **Phase 0A revision** — Cognito JWT custom claims (`clientId`, `role`, `facilities`, `censuses`) + RoleAssignments table (for `family_viewer`'s `linkedPatientIds`)
- **Phase 0B revision** — Patients, Activity Series, Alert History, Organizations, DeviceAssignments tables and their GSIs (`by-census-status`, `by-client-status`, `by-patient` on DeviceAssignments)
- **Phase 1.5 Security** — IdentityKey CMK for identity-table reads
- **Phase 1.6 Observability** — Powertools layer; ops SNS topic for alarms; X-Ray tracing
- **Phase 1.7 Audit Logging** — Audit pipeline destination
- **Phase 2A-0** — API Gateway + JWT authorizer + `_shared/api_authz.py` + `_shared/api_audit.py` + error envelope
- **Phase 2A-DL** — (no runtime dep, but for code consistency) `_shared/audit_catalog.py` pattern

### Configuration

| CDK Context Key | Dev | Prod | Notes |
|---|---|---|---|
| `patientApiMemoryMb` | 256 | 512 | Higher in prod for BatchGetItem fan-out latency |
| `patientApiTimeoutS` | 10 | 10 | Same in dev/prod |
| `patientApiDefaultPageSize` | 50 | 50 | L7 |
| `patientApiMaxPageSize` | 200 | 200 | L7 |
| `patientApiActivityRanges` | `["24h","7d","30d"]` | same | L6 |
| `patientApiLatencyP99AlarmMs` | 1500 | 800 | Tighter in prod |

## Testing

### Test Scenarios

| # | Scenario | Method | Expected Result | Status |
|---|----------|--------|-----------------|--------|
| T1 | `GET /patients/{id}` as caregiver in-scope | curl with caregiver token | 200 with patient detail; `patient.read` audit event | Pending |
| T2 | `GET /patients/{id}` as caregiver out-of-scope | curl with caregiver whose censuses don't include patient's census | 403 `OUT_OF_SCOPE` | Pending |
| T3 | `GET /patients/{id}` as family_viewer not in linkedPatientIds | curl with family_viewer | 404 `PATIENT_NOT_FOUND` (existence-leak prevention) | Pending |
| T4 | `GET /patients/{id}` as internal_support cross-client | curl with internal_support token | 200; audit event auto-stamped `internal_access: true` + `severity: elevated` | Pending |
| T5 | `GET /patients/{id}/activity?range=24h` returns last 24h of sessions DESC | bench-publish 5 synthetic activity sessions → call | 200 with 5 sessions newest-first; `windowStart/End` correct; `nextCursor: null` | Pending |
| T6 | `GET /patients/{id}/activity?range=7d` over patient with >50 sessions | bench-publish 60 sessions across 7d → call | 200 with first 50; `nextCursor` non-null; second call with cursor returns remaining 10 | Pending |
| T7 | `GET /patients/{id}/activity?range=invalid` | curl | 400 `INVALID_RANGE` with valid values listed in `details` | Pending |
| T8 | `GET /patients/{id}/activity?range=24h` against patient with zero sessions | curl on never-active patient | 200 with `sessions: []` and `nextCursor: null` | Pending |
| T9 | `GET /patients/{id}/alerts?status=unacknowledged` default filter | bench-create 3 alerts (2 unacked, 1 acked) → call | 200 with 2 unacked alerts; `filter: "unacknowledged"` | Pending |
| T10 | `GET /patients/{id}/alerts?status=all` returns both states | curl | 200 with all 3 alerts | Pending |
| T11 | `GET /me/patients` as caregiver with 2 censuses (10 patients total) | curl with caregiver token | 200 with 10 patients; each has `facilityName` + `censusName` populated; `scope.role: "caregiver"` | Pending |
| T12 | `GET /me/patients` as facility_admin with empty facility scope (= all in client) | curl | 200 with all patients in client (paginated if >50) | Pending |
| T13 | `GET /me/patients` as family_viewer with 3 linkedPatientIds | curl | 200 with exactly 3 patients | Pending |
| T14 | `GET /me/patients` as internal_admin without `?clientId=` | curl | 400 `MISSING_CLIENT_PARAM` | Pending |
| T15 | `GET /me/patients?clientId=client_005` as internal_admin | curl | 200 with all patients in client_005; elevated audit | Pending |
| T16 | `GET /facilities/{f}/censuses/{c}/patients` as caregiver in-scope | curl | 200 roster | Pending |
| T17 | `GET /facilities/{f}/censuses/{c}/patients` as caregiver out-of-scope | curl | 403 `OUT_OF_SCOPE` | Pending |
| T18 | `GET /facilities/{f}/censuses/{c}/patients` with bad facility ID | curl | 404 `FACILITY_NOT_FOUND` | Pending |
| T19 | Pagination cursor round-trip stability | call returns nextCursor; insert new patient; call with cursor | Second call returns the original next-page set, not skewed by the insert | Pending |
| T20 | Malformed cursor | curl with garbage cursor | 400 `INVALID_CURSOR` | Pending |
| T21 | Audit event lands in S3 within ~70s for a `/patients/{id}` read | run T1; wait; list S3 audit prefix | `.gz` object containing `patient.read` event with `subject.patientId` matching | Pending |
| T22 | PII scrubbing — `displayName` never appears in `/aws/lambda/gosteady-{env}-patient-api` log group | run T1; query log group for the patient's displayName | No matches | Pending |
| T23 | `patient-api-errors` alarm fires on synthetic 500 | force a handler exception; verify alarm | ALARM state; SNS message at ops topic | Pending |
| T24 | X-Ray trace shows the full path (API Gateway → patient-api → DDB BatchGetItem) | run T1; open X-Ray | Trace visible with DDB segments | Pending |
| T25 | Tenancy violation — caregiver of client_005 trying patient of client_006 | curl as client_005 caregiver with patient_id from client_006 | 403 `TENANCY_VIOLATION` (not 404 — path itself implies cross-client probe) | Pending |
| T26 | Concurrent reads at scale — `/me/patients` from 50 simultaneous callers | synthetic load test | All 50 return 200; no DDB throttling; p99 < latency budget | Pending — opportunistic |
| T27 | Page-size override beyond max | curl with `?pageSize=500` | Server caps at 200; response returns 200 results + nextCursor | Pending |

### Verification Commands

```bash
# Tail patient-api logs
aws logs tail /aws/lambda/gosteady-dev-patient-api --region us-east-1 --follow

# Hit /me/patients as test caregiver
TOKEN=$(aws cognito-idp initiate-auth --region us-east-1 \
  --auth-flow USER_PASSWORD_AUTH \
  --client-id 1q9l9ujtsomf3ugq2tnqvdg6d7 \
  --auth-parameters USERNAME=caregiver-test@example.com,PASSWORD=... \
  --query 'AuthenticationResult.IdToken' --output text)

API_URL=$(aws apigatewayv2 get-apis --region us-east-1 \
  --query 'Items[?Name==`gosteady-dev-api`].ApiEndpoint' --output text)

curl -s -H "Authorization: Bearer $TOKEN" "$API_URL/api/v1/me/patients" | jq .

# Pull recent patient.* audit events
aws logs filter-log-events --region us-east-1 \
  --log-group-name gosteady-dev-audit \
  --filter-pattern '{ ($.event = "patient.read") || ($.event = "patient.list.read") }' \
  --start-time $(($(date +%s) - 600))000 --max-items 20
```

## Deployment

### Deploy Commands

```bash
cd infra
npm run build

# Order: Api stack first (creates patient-api Lambda log group on first invoke),
# then Audit stack (subscription filter add — requires log group to exist).
# Mirror 2A-0/2A-DL pattern: bundle both in a single sequenced run.
npx cdk deploy GoSteady-Dev-Api --context env=dev --require-approval never

# Trigger a synthetic invoke so the log group exists before Audit's filter attaches.
# (Avoids the "log group doesn't exist yet" deploy failure that hit 2A-0 first attempt.)
aws lambda invoke --region us-east-1 \
  --function-name gosteady-dev-patient-api \
  --cli-binary-format raw-in-base64-out \
  --payload '{"requestContext":{"http":{"method":"GET","path":"/api/v1/me/patients"}}}' \
  /tmp/synth-invoke.json

npx cdk deploy GoSteady-Dev-Audit --context env=dev --require-approval never
```

Estimated deploy time: Api ~2 min (one Lambda + 5 routes + 2 alarms), Audit ~30 s (subscription filter add).

### Rollback Plan

Pure read-only — no data plane impact. `git revert <commit-sha>` + redeploy removes the Lambda + routes cleanly. The Audit-stack subscription filter add is a single resource that can be removed via diff-and-redeploy.

If 2A-RD ships a query bug that produces wrong results (e.g., wrong-tenant leak), **disable the routes at API Gateway level** while investigating (set integration to return 503) rather than rolling back the whole stack. Faster MTTR.

## Decisions Log
> Choices made during this phase that affect future work.

| # | Decision | Alternatives Considered | Why This Choice |
|---|----------|------------------------|-----------------|
| D1 | Single `patient-api` Lambda for all 5 routes (mirrors 2A-DL D1) | Per-route Lambdas; split read vs. list | Cold-start cost of N Lambdas outweighs route-dispatch tax; shared code (auth, audit, pagination) is in-process; consistency with 2A-DL precedent |
| D2 | Return 404 (not 403) when `family_viewer` tries to access a non-linked patient | Return 403 for clearer semantics | 403 leaks existence — caller could enumerate patient IDs by probing. 404 is the safe default for "you don't have permission to know this exists" |
| D3 | Pagination via opaque base64 cursor encoding DDB's `LastEvaluatedKey` | Offset/limit pagination | Cursor-based avoids drift on concurrent writes; matches DDB's native pagination shape; no server-side state to expire |
| D4 | Activity range param is `24h\|7d\|30d` only — longer ranges error pointing at the rollups endpoint (Phase 1C) | Accept arbitrary ranges; cap at 90d | Bounds the raw-session query cost — a 90d Query over an active patient could hit DDB scan limits. Rollups belong in 1C |
| D5 | `/me/patients` enriches with `facilityName` + `censusName` server-side | Client makes follow-up Organizations calls | One round-trip vs. N; UI groups by census on the home screen; cost is one BatchGetItem capped at 100 unique census IDs |
| D6 | `/me/patients` for internal-tier requires explicit `?clientId=` query param | Implicit: return nothing or return everything | Implicit "everything" is a foot-gun (huge audit log entry, accidental cross-tenant scan); implicit "nothing" is surprising. Explicit param makes the intent + audit trail crisp |
| D7 | Default alert filter is `unacknowledged` newest-first | `all` or `acknowledged` | Operationally interesting subset is unacked — the caregiver's actionable inbox. Acked alerts are historical reference |
| D8 | Audit event `patient.list.read` carries `patientCount` but NOT individual `patientIds` | Include the patient ID list in subject | Audit log volume — a 200-patient list × 100 caregivers × 10 sessions = 200k IDs/day, each ~40 bytes = ~8 MB/day just in ID payloads. Patient-level reads are already audited individually; the list endpoint's audit is "who looked at their list, when" |
| D9 | Bundle the Audit-stack subscription-filter add into the 2A-RD deploy (mirrors 2A-0 D9) | Defer to follow-up commit | Avoids between-revisions silent-swallow gap (Migration Pattern 18.8). Same reasoning as 2A-0 |
| D10 | Add `enforce_patient_access(claims, patient)` to `_shared/api_authz.py` instead of inlining per-handler | Inline the auth chain in each handler | Three of the five endpoints need the identical chain (tenancy + scope OR linkedPatientIds membership). Single helper prevents drift; one place to fix if the rule changes |
| D11 | Open alert count + last activity timestamp on `/me/patients` rows are best-effort — fetched server-side but tolerate missing data | Strict: always return; degrade UX if missing | At v1 scale the fan-out cost (one Alert History Query per patient row) is acceptable; if it becomes a bottleneck, fall back to client-side per-row lazy-load with `null` placeholders |
| D12 | No DDB writes in this subset (not even a read-receipt row) | Write a `last_viewed_at` per (user, patient) pair | Audit log is the source of truth for read-receipt forensics; a separate DDB table for "last viewed" is product UX (out of scope) not a security/compliance requirement |

## Open Questions

> Plain-language explanation of each question + a decision where we can call it. Decisions called now are mirrored into the Decisions Log above where they shape the implementation; the open ones are explicitly tagged with what would resolve them.

### Q1. Maximum activity range — 30d? 90d? Unbounded? (DECIDED)

**What's actually being asked:** Activity range `24h`/`7d`/`30d` keeps query cost bounded. But product may eventually want "last 90d trend." Where do we draw the line in this subset?

**What's at stake:** Raw-session query cost vs. dashboard capability.

**Decision:** ✅ **Cap at `30d` in v1.** Longer ranges return 400 with a `details.suggestion` pointing at the daily-rollup endpoint (Phase 1C). 30d × ~10 sessions/day × ~5 patients on screen = ~1.5k DDB items per dashboard load — comfortably within DDB query limits. See L6.

---

### Q2. Pagination — offset/limit or cursor? (DECIDED)

**What's actually being asked:** Two standard pagination patterns; offset/limit is more familiar to web devs but drifts under concurrent writes.

**What's at stake:** Consistency of the user experience as new data arrives.

**Decision:** ✅ **Cursor-based via opaque base64 of DDB's `LastEvaluatedKey`.** Default page size 50, max 200. See L7 + D3.

---

### Q3. Should `/patients/{id}` return current device Shadow state (lastSeen, battery, signal)?

**What's actually being asked:** The dashboard wants to show "device last heard from 12 minutes ago" on the patient detail screen. That data lives in IoT Device Shadow, not DDB.

**What's at stake:** Additional `iot:GetThingShadow` call per patient detail load. ~50–100 ms latency added; small IAM grant added.

**Decision:** ⏳ **Defer to a v1.1 inside the same phase if the dashboard needs it.** Initial pass: return `currentDevice.lastSeen` from Device Registry (already there). If the dashboard explicitly wants live battery/signal on the patient detail (vs. on a separate "device health" view), add the Shadow call. Smallest workable surface first.

**Amendment 2026-05-25 (coord §C28):** "already there" was aspirational — `Device Registry.lastSeen` was actually never written by any Lambda (`heartbeat-processor` only wrote to Shadow.reported.lastSeen). The patient-api fallback (`device.get("lastSeen") or device.get("firstHeartbeatAt")`) cascaded to firstHeartbeatAt for every live device, showing stale provisioning timestamps. Fixed in heartbeat-processor: every heartbeat now also writes `lastSeen` to Device Registry. patient-api code unchanged — its fallback chain is now correct (firstHeartbeatAt only fires for never-heartbeated devices). Shadow-state expansion (battery + signal on the patient response) still deferred. See coord §C28.1 for the full investigation.

---

### Q4. Alert filter — what's the default? (DECIDED)

**What's actually being asked:** When a caregiver opens a patient's alert list, which alerts do they want to see by default?

**What's at stake:** UX friction (wrong default = "where are the alerts I care about?").

**Decision:** ✅ **`unacknowledged` newest-first.** That's the actionable inbox. Acked alerts available via `?status=acknowledged` or `?status=all`. See L8 + D7.

---

### Q5. Should `/me/patients` enrich rows with facility/census names? (DECIDED)

**What's actually being asked:** The dashboard groups patients by census ("East Wing — 12 patients"). Either the server pre-joins Organizations, or the client fans out N calls to fetch names.

**What's at stake:** One server-side BatchGetItem vs. N client round-trips.

**Decision:** ✅ **Server-side enrichment via Organizations BatchGetItem (capped at 100 unique census IDs per response).** See L9 + D5.

---

### Q6. Internal-tier callers on `/me/patients` — implicit "everything" or explicit `?clientId=`? (DECIDED)

**What's actually being asked:** `internal_*` users have no `custom:clientId` tying them to a tenant. If they hit `/me/patients`, what should they get?

**What's at stake:** Foot-gun risk — implicit "everything" creates massive audit log entries on accidental clicks; implicit "nothing" is surprising.

**Decision:** ✅ **Require explicit `?clientId=` param for internal callers.** Missing → 400 `MISSING_CLIENT_PARAM`. The internal-admin UI can default the param to "select a client first" workflow. See D6 + L12.

---

### Q7. Activity vs daily-rollup — serve raw sessions for all 24h/7d/30d ranges?

**What's actually being asked:** Phase 1C (Scheduled Jobs) will compute daily rollups (steps/distance/active-min per patient-day). The dashboard could either query raw sessions and aggregate client-side, or query pre-aggregated rollups.

**What's at stake:** Latency + DDB read cost for the 7d/30d ranges, plus dependency on 1C.

**Decision:** ⏳ **Serve raw sessions in v1; switch the 7d/30d ranges to rollups when 1C ships.** Raw sessions are simpler to implement and validate; the dashboard can aggregate client-side. When 1C lands and the rollups table exists, swap the data source for those ranges (the 24h range probably stays on raw sessions for freshness).

---

### Q8. Should the spec ship a facility-wide patient list endpoint (`GET /facilities/{f}/patients`)?

**What's actually being asked:** Census roster is in scope. But facility_admin might want a full-facility view too — not strictly necessary (they can hit `/me/patients` which returns all patients in their scope) but it's a more natural URL.

**What's at stake:** Endpoint sprawl vs. UX clarity.

**Decision:** ⏳ **Defer. Use `/me/patients` for facility_admin scope queries in v1.** If facility_admin UX demands a dedicated endpoint (e.g., for shared link semantics: "this URL = all patients in this facility, no matter who's logged in"), add in a 2A-RD follow-up. Low marginal cost when needed.

---

### Q9. Audit subject — include patient ID list in `patient.list.read` events?

**What's actually being asked:** When a caregiver lists patients, do we audit just "they listed their patients" (with a count) or "they listed these specific patient IDs"?

**What's at stake:** Audit log volume + forensic granularity.

**Decision:** ✅ **Count only, not IDs.** See D8. Per-patient reads (`patient.read`) are audited individually with the patient ID — that's where the per-patient-access trail lives. The list event is the "user opened their dashboard" signal.

---

### Q10. Should we add a `?fields=` query param to let the dashboard request a thin subset of patient attributes?

**What's actually being asked:** GraphQL-style field selection on a REST endpoint. Useful for low-bandwidth views (mobile-web on a clinic Wi-Fi).

**What's at stake:** API complexity vs. payload size.

**Decision:** ⏳ **Defer.** Response shapes are already thin (~5–10 fields per row). If a specific endpoint becomes a hot mobile-bandwidth problem, add per-endpoint field selection. Not a v1 concern.

---

### Decision summary

| # | Question | Resolution |
|---|----------|-----------|
| Q1 | Activity range cap | ✅ 30d max; longer → 400 with pointer to 1C |
| Q2 | Pagination style | ✅ Cursor-based, opaque base64 |
| Q3 | Patient detail returns Shadow state? | ⏳ Defer; start with `lastSeen` from Device Registry |
| Q4 | Alert filter default | ✅ `unacknowledged` newest-first |
| Q5 | `/me/patients` enrichment | ✅ Server-side Organizations BatchGetItem |
| Q6 | Internal `/me/patients` semantics | ✅ Require explicit `?clientId=` |
| Q7 | Activity raw vs rollup | ⏳ Raw in v1; swap to rollups when 1C ships |
| Q8 | Facility-wide list endpoint | ⏳ Defer; `/me/patients` covers facility_admin scope |
| Q9 | Audit subject for list events | ✅ Count only, no patient IDs |
| Q10 | `?fields=` field-selection param | ⏳ Defer |

Seven of ten decided now. Q3 / Q7 / Q8 / Q10 require downstream phases or production usage to inform.

## Changelog
| Date | Author | Change |
|------|--------|--------|
| 2026-05-23 | Jace + Claude (cloud session) | Initial spec drafted as Patient Reads subset of Phase 2A. Five GET endpoints to unblock the Flutter dashboard's real-data rendering (the next named blocker on the MVP critical path per ARCHITECTURE.md §12). Builds on 2A-0 foundation helpers (`enforce_tenancy`, `audit_middleware`, error envelope) + 2A-DL precedents (single Lambda per route group, audit catalog constants, bundled audit-stack subscription filter). Seven of ten Open Questions decided inline; three deferred (Shadow-state-on-detail, activity-vs-rollup, field-selection) require downstream-phase or production-usage data. Scope explicitly excludes alert acknowledgement (2A-AA), threshold overrides (2A-AA), and user management (2A-UM) — those are sibling subsets. |
| 2026-05-23 | Jace + Claude (cloud session, same day) | **Deployed to dev.** Unit tests (49/49 PASS) → CDK synth + diff (3 stacks, clean adds only) → Api stack deploy (21 resources / 83s — patient-api Lambda + 5 routes + IAM role/policy + 2 alarms) → synthetic invoke to materialize log group → Audit stack deploy (5 resources / 36s — subscription filter). Plus Auth +2 cross-stack exports (RoleAssignments table) and Data +6 cross-stack exports (Activity / Alerts / Organizations) auto-emitted by CDK when patient-api's new refs were added. **Synthetic smoke 23/23 PASS** covering: caregiver in-scope read, OUT_OF_SCOPE (facility + census), family_viewer linked vs non-linked (404-leak prevention), activity range=7d with pagination cursor round-trip, invalid range / cursor / status filter, alert status filters (unacked / acked / all), `/me/patients` scope resolution per role (caregiver / facility_admin / client_admin / family_viewer), census roster, no-token 401. Two deploy-time fixes: (1) test config blocks in test/*.test.ts needed `patientApiMemoryMb` + `patientApiTimeoutSeconds` fields added (5 files); (2) seed-script `admin_update_user_attributes` swallowed errors silently — manually flipped `mfa_enrolled=true` on facility_admin + client_admin Cognito users (those roles gate MFA per Phase 0A-rev A7). **Real-data validation:** queried `pt_bench_98` (the §C18 bench patient) directly via Lambda's `queries.py` — 8 historical sessions returned correctly (firmware versions 0.10.0-at-timeout, surface=indoor, distance/steps populated). `GS9999999998` currently in `ready_to_provision` since 2026-05-18 §C22 — no active assignment, so no recent activity uploads (this is correct firmware behavior, not a bug — pre-activation gate suppresses session capture). **PII scrub clean:** 0 matches for test patient `displayName` ("Jane D.") in operational log group `/aws/lambda/gosteady-dev-patient-api`. **Audit pipeline working end-to-end:** 48 events landed in `gosteady-dev-audit` log group within 30 min, every event tagged `schema_version: 1` with `internal_access` + `severity` auto-stamped by Phase 1.7 forwarder. |

# Internal User & Population Analytics — usage dashboard (DRAFT)

## Overview
- **Phase**: 2A follow-on (internal operational tooling) — sibling to [`device-fleet-ops-tooling.md`](device-fleet-ops-tooling.md)
- **Status**: ✅ **Deployed dev + PROD + live-verified 2026-07-21.** All 4 stacks + portal deployed to **both** envs (`cdk diff` on prod confirmed Lambda-code-only on the auth stacks — no Cognito pool replacement; 18 added / 14 modified / **0 removed**). Live tests pass against deployed dev **and** prod: `/analytics` gate 200 (internal) / 403 (customer) / 401 (no-token) with `analytics.overview.read` auto-elevated `internal_access`; overview returns real data (prod: 194 offloads · 5 active users · avg 8.8 min); the per-user table incl. the **Device ID** column maps real walkers to real serials (prod: `GS0002000001` 148 offloads, etc.; 0 unattributed). Dev also ran the auth-funnel emit tests T4/T5/T9 via synthetic invokes (skipped on prod to keep synthetic events out of the compliance audit log). Launched on operator decision 2026-07-21 (mirrors the coach's ahead-of-counsel launch); **counsel/PII sign-off remains open**. NB metrics #2/#3/#4 populate deploy-forward only — prod counters start at the prod deploy (no backfill).
- **Branch**: feature/infra-scaffold
- **Date Started**: 2026-07-21

Gives a GoSteady **internal** operator a view of how real people use the product — at the **individual user** and **population** level — during the D2C trial and beyond. The device-fleet board answers *"is the hardware healthy?"*; this answers *"are users logging in, getting through sign-in, opening the app, and talking to the coach?"*. Five metrics in v1: (1) device **session offloads** per hour/day, (2) **successful logins**, (3) **SMS-OTP requested-but-abandoned**, (4) **time spent active** (coarse proxy), (5) **Steady Coach interaction count**. Delivered as one new internal-only, audited read surface (`analytics-api`) plus a role-gated Flutter screen at `/analytics`, reusing the **existing audit→S3 pipeline** as the event backbone (no new analytics store, no third-party SaaS, no frontend telemetry SDK).

Framing decided with the operator (2026-07-21): product/user analytics is **greenfield** — everything shipped to date is *device/infra* observability (CloudWatch, `/fleet`) or a *compliance* audit trail. `phase-0b-data.md` deliberately chose DynamoDB partition keys that "block cross-device analytics," punting population analytics to the now-**cut** Phase 4C. This spec is the right-sized, pilot-scale replacement: surface what's already captured, cheaply instrument the two auth gaps, and defer any heavy pipeline until scale demands it.

---

## Locked-In Requirements

| # | Requirement | Decided In | Rationale |
|---|-------------|-----------|-----------|
| L1 | **Audience is internal-only.** The dashboard is gated to `internal_admin` / `internal_support`, lives beside `/fleet`, and shows a **cross-tenant population** view. No customer-facing surface in v1. | operator, 2026-07-21 | These 5 metrics (OTP funnel, login counts, coach usage) are operator/product concerns, not caregiver ones. Internal cross-tenant read is an explicit carve-out (ARCHITECTURE §Internal Access) — customer tenancy is untouched. |
| L2 | **Backbone = reuse the existing `emit_audit` → `gosteady-{env}-audit` LG → Firehose → S3 pipeline.** New auth/OTP signals are emitted as audit events; aggregation is **on-demand** (CloudWatch Logs Insights over the 90-day hot window + direct DDB queries). **No** new analytics/events table, **no** warehouse, **no** Amplitude/PostHog/Segment. | operator, 2026-07-21 | Trial scale (~25 users, [ai-coach.md](ai-coach.md) L288) makes a pipeline/SaaS overkill; a SaaS would also drag health-adjacent elderly-user data into a BAA/privacy review and fight the strict CSP ([phase-3a-portal-hosting.md](phase-3a-portal-hosting.md) L7/L59). Auth events are audit-worthy anyway (ARCHITECTURE §10 "What Gets Logged"). |
| L3 | **Metric #4 (time active) is a coarse server-side proxy** derived from existing audit read-event timestamps + token-mint cadence. **No** frontend session/page-view beacon, **no** `/api/analytics` ingest, **no** CSP change in v1. | operator, 2026-07-21 | Real screen-time needs a new client SDK + sink + CSP allowance — deferred until the coarse number proves insufficient. |
| L4 | **Reads go through an internal-role-gated, audited endpoint** (`analytics-api`), never a direct customer-facing path. Every load emits an `analytics.*.read` audit event (cross-tenant → auto-stamped `internal_access` + elevated severity by the forwarder). | ARCHITECTURE §Internal Access; mirrors `device.fleet.read` | "No silent reads" for internal cross-tenant access. |
| L5 | **New instrumentation is emit-only and non-blocking** — an `emit_audit` failure must never fail a login, an OTP send, or an OTP verify. | ARCHITECTURE §1.7 (fire-and-forget audit, OQ resolved 2026-05-17) | Auth hot path integrity outranks analytics completeness. |
| L6 | **Aggregates avoid PII; OTP events carry only a masked/hashed phone**, never raw E.164, never the OTP code. | ARCHITECTURE §10 "What Does NOT Go in Audit Logs"; mirrors `d2c.login_code_sent` masking | Analytics must not become a new PII sink. |

---

## Assumptions

| # | Assumption | Risk if Wrong | Validation Plan |
|---|-----------|---------------|-----------------|
| A1 | At pilot scale (≤ ~50 users, ≤ few-hundred sessions/day) an on-demand **Logs Insights** query (async start→poll, ~1–10 s) and a **bounded Activity Series query/scan** are acceptable dashboard latency + cost. | Sluggish or costly dashboard as population grows. | Measure query latency on real trial data; the scale path (D5) is a scheduled pre-aggregation into a small rollup table. |
| A2 | The **audit auth events do not exist yet**, so metrics #2/#3/#4 have **no history** — they populate only from deploy-forward. #1 (offloads) and #5 (coach) have history bounded by TTL (13 mo / 12 mo). | Operator expects historical login/OTP numbers on day 1. | State plainly in the UI ("since <deploy date>"); no backfill is possible for un-emitted events. |
| A3 | The facility Pre-Token trigger can distinguish a **fresh sign-in** from a **token refresh** via `triggerSource` (`TokenGeneration_Authentication` vs `TokenGeneration_RefreshTokens`). | Login counts (#2) over-count by ~1 per 15-min active window (every refresh). | Verify `triggerSource` values in a real facility sign-in + refresh; emit `auth.login` only on the `_Authentication` source. |
| A4 | Every D2C dashboard load already emits a timestamped audit read (`patient.list.read`, `auth.session.read`), dense enough to sessionize a coarse "active time." | #4 proxy is too sparse to be meaningful. | Inspect real read-event cadence per user; optionally add `auth.token_refresh` (D4) to densify. |
| A5 | An `internal_admin`/`internal_support` Cognito user + token exists for API-authenticated reads (as stood up for `/fleet`, `tools/create-internal-user.sh`). | Can't load the board through the audited API. | Reuse the fleet internal user; `--direct` boto3 read path is **not** offered here (analytics reads must be audited — see D3). |

---

## Scope

### In Scope
- **Two new emit points in `d2c-custom-auth`** (the uninstrumented SMS-OTP hot path):
  - `auth.otp_requested` in `_create` (code generated + sent) — the OTP-funnel numerator.
  - `auth.login` (on `_verify` success) + `auth.otp_verify_failed` (on wrong code) — login success + verify-failure.
- **`auth.login` on the facility/internal Pre-Token** (`cognito-pre-token`), gated to `triggerSource == TokenGeneration_Authentication` (A3), with `extra.method="password"`. Its audit subscription filter is already attached — it just needs the emit.
- **`auth.login_failed`** (operator-approved 2026-07-21) — emitted on a failed facility auth for a fuller login funnel; the constant already exists, just unwired.
- **`auth.token_refresh`** (operator-approved 2026-07-21) — emitted on the Pre-Token **refresh** trigger (`TokenGeneration_RefreshTokens`) in **both** pools, to densify the #4 active-time proxy (L3).
- **Unify the QR-relogin login** under `auth.login` (`extra.method="qr_relogin"`), alongside the existing `d2c.login_code_verified` (kept for back-compat).
- **`analytics-api` Lambda** — internal-only, audited, three read routes (see Interfaces): population **overview**, per-user **table**, single-user **drill-down**. Aggregates on demand from (a) Activity Series DDB + (b) Logs Insights over the audit LG.
- **Flutter `/analytics` screen** — internal-role-gated (second role-gate after `/fleet`), population KPIs + per-user table + a per-user timeseries, charted with the **already-present `fl_chart`** dep. Nav entry beside Fleet.
- **New audit constants** in `audit_catalog.py` + rows in the phase-1.7 catalog: `auth.otp_requested`, `auth.otp_verify_failed`, `auth.token_refresh`, `analytics.overview.read`, `analytics.users.read`. (`auth.login`/`auth.login_failed`/`auth.mfa_challenge` already exist as unused constants — this wires `auth.login` + `auth.login_failed`.)

### Out of Scope (Deferred)
- **Real frontend session/screen-time telemetry** (client beacon + `/api/analytics` ingest + CSP allowance) — L3; the accurate version of #4. Fast-follow if the proxy is insufficient.
- **Per-*device* offload counts** as a first-class cut — v1 counts offloads **per patient/user and per population** (D6); per-device stays a single-device on-demand join or a future `deviceSerial` GSI.
- **Customer-facing analytics** (facility_admin sees own facility; household_owner sees own household) — L1; needs per-tenant scoping + PII-in-UI review.
- **Durable rollup table / Athena SerDe** for >90-day (audit) or >13-month (activity) history and large-population pre-aggregation — the scale path (D5). The stubbed `scheduled-jobs` Lambda is where it lands.
- **Token-usage / cost analytics for the coach** (`coach_llm_call` logs exist but aren't metrics) — additive later.
- **Alerting** on analytics thresholds (e.g. OTP-abandonment spike → ops) — signals will exist; routing is a fast-follow.

---

## Metric-by-Metric Design

| # | Metric | Source of truth | Individual (per-user) | Population | New capture? |
|---|--------|-----------------|-----------------------|-----------|--------------|
| **1** | Session offloads / hr / day | **Activity Series** DDB (1 row = 1 session) | base-table `Query(PK=patientId, SK=timestamp BETWEEN …)`, bucket by `date` (day) or `sessionStart` hour | `by-client-time` GSI per client, summed; or bounded scan at pilot scale | No — count rows already stored |
| **2** | Successful logins | `auth.login` audit event | Logs Insights `stats count() by actor.userId`, `extra.method` breakdown | `count()` over range, split by method (`sms_otp`/`qr_relogin`/`password`) | **Yes** — 3 emit points (custom-auth, pre-token, QR) |
| **3** | OTP requested, not entered | `auth.otp_requested` − `auth.login`(method=sms_otp) | per masked-phone/user: requested sessions with no success within the challenge window | abandonment **rate** = 1 − (completed ÷ requested) over range | **Yes** — emit in `_create`; success already from #2 |
| **4** | Time spent active | audit **read** events (`patient.list.read`, `auth.session.read`, …) **+ `auth.token_refresh`** (densifies the signal) | sessionize per `actor.userId` by **30-min** idle-gap (matches token idle); Σ(last−first) per session | Σ active-minutes, avg session length, active-user count | `auth.token_refresh` emit only (L3 — no client beacon) |
| **5** | Coach interactions | `coach.chat.turn` audit event (durable, carries `userId`) — canonical; `CoachMessages` DDB (TTL 12 mo) as alt | Logs Insights `count() by actor.userId`; turns, distinct active days | total turns, users ≥3×/wk (matches [ai-coach.md](ai-coach.md) Q10) | No — already emitted every turn |

> **#3 abandonment definition (locked with operator TBD — Open Q):** "abandoned" = an `auth.otp_requested` with no `auth.login`(sms_otp) for the same masked-phone within N minutes (default 15, = OTP validity). Wrong-code-then-give-up shows as `auth.otp_verify_failed` present, `auth.login` absent. A resend within the window is one funnel entry, not two (dedupe on the challenge session).

---

## Architecture

### Infrastructure Changes
- **`GoSteady-{env}-Api`**: new `analytics-api` Lambda (Python 3.12 ARM64, Powertools) + 3 GET routes under `/api/v1/admin/analytics/*` on the existing HTTP API, bound to the existing `userPoolAuthorizer`. IAM: Activity Series **read** (query + GSI) + Users/Patients/RoleAssignments **read** (for the user roster + patient join) + **CloudWatch Logs `StartQuery`/`GetQueryResults`/`StopQuery`** on the audit LG + AuditKey `Decrypt`. Add its audit subscription filter (2A-0 D9 pattern).
- **`GoSteady-{env}-D2C-Auth`**: no resource change — `d2c-custom-auth` gains emit calls only. **Add `gosteady-{env}-d2c-custom-auth` to `audit-stack.ts` `sourceHandlers`** so its `audit:true` lines are forwarded (today its LG is *not* subscribed — the core gap).
- **`GoSteady-{env}-Auth`**: no resource change — `cognito-pre-token` gains one emit (its subscription filter already exists).
- **No new stack, no new table, no new IoT/EventBridge wiring.**

### Data Flow
```
 write path (new emit points, all fire-and-forget / L5):
   d2c-custom-auth._create  ──emit auth.otp_requested (masked phone)──┐
   d2c-custom-auth._verify  ──emit auth.login | auth.otp_verify_failed┤
   cognito-pre-token (sign-in only) ──emit auth.login(method=password)┼─► gosteady-{env}-audit LG ─► Firehose ─► S3
   d2c-claim (QR relogin)   ──emit auth.login(method=qr_relogin)──────┤        (already: coach.chat.turn,
   [existing reads]         ──patient.list.read / auth.session.read───┘         patient.list.read, …)

 read path (on-demand, internal-gated, audited):
   GET /api/v1/admin/analytics/{overview,users,users/{id}}
        │  (id_token: Portal-Customer, role=internal_*)
        ▼
   analytics-api ─┬─► Activity Series DDB  (offloads: #1)          ─┐
                  ├─► CloudWatch Logs Insights over audit LG        ├─► shaped metric JSON ─► /analytics Flutter screen
                  │     (logins #2, OTP funnel #3, active-time #4,   │        (fl_chart)
                  │      coach turns #5 — start_query → poll)        │
                  └─► Users/RoleAssignments DDB (roster + join)     ─┘
                  emit analytics.{overview,users}.read (count-only subject)
```

### Interfaces
- `GET /api/v1/admin/analytics/overview?range=24h|7d|30d` → population KPIs:
  `{ range, since, logins:{total,byMethod}, otp:{requested,completed,failed,abandoned,abandonmentRate}, activeUsers, avgSessionMinutes, offloads:{total,perDay[],perHour[]}, coach:{turns,activeUsers} }`
- `GET /api/v1/admin/analytics/users?range=&cursor=&pageSize=` → per-user table (individual view):
  `{ users:[{userId, clientId, role, deviceSerial, deviceLastSeen, logins, otpAbandoned, otpVerifyFailed, activeMinutes, offloads, coachTurns, lastActive}], count, nextCursor }`.
  - `deviceSerial` = the serial currently assigned to the user's account-linked patient (via `cognitoUserId` → active `DeviceAssignments` row); `""` when the user has no account-linked device (e.g. family_viewer).
  - **`deviceLastSeen`** = the DEVICE's real last heartbeat (Device Registry `lastSeen`, written by heartbeat-processor). UI column **"DEVICE SEEN"** (stale >24h → offline color). `""` when no device.
  - **`lastActive`** = the USER's last in-app audit event (login / dashboard read / coach turn). UI column **"APP ACTIVE"** (renamed from the ambiguous "LAST SEEN"). These are deliberately two columns — a device offloads/heartbeats over cellular with nobody logged in, so device-online ≠ user-active.
  - No `displayName` — the internal view keys on IDs (PII kept out of the aggregate per L6).
- `GET /api/v1/admin/analytics/users/{userId}?range=` → single-user drill-down: the same fields + per-day timeseries for offloads / logins / coach turns / active-minutes.
- Audit: `analytics.overview.read` / `analytics.users.read`, subject = `{count}` only (no per-tenant leak into the event), auto-tagged `internal_access`.

---

## Implementation

### Files Changed / Created
| File | Change | Description |
|------|--------|-------------|
| `infra/lambda/d2c-custom-auth/handler.py` | Modified | `emit_audit(auth.otp_requested)` in `_create` (masked phone, clientId if known); `emit_audit(auth.login, method=sms_otp)` on `_verify` success; `emit_audit(auth.otp_verify_failed)` on wrong code. All wrapped best-effort (L5). |
| `infra/lambda/cognito-pre-token/handler.py` | Modified | `emit_audit(auth.login, method=password)` when `triggerSource == TokenGeneration_Authentication` (A3). |
| `infra/lambda/d2c-claim/handler.py` | Modified | Add `emit_audit(auth.login, method=qr_relogin)` alongside existing `d2c.login_code_verified`. |
| `infra/lambda/_shared/audit_catalog.py` | Modified | Add `AUDIT_AUTH_OTP_REQUESTED`, `AUDIT_AUTH_OTP_VERIFY_FAILED`, `AUDIT_ANALYTICS_OVERVIEW_READ`, `AUDIT_ANALYTICS_USERS_READ` (+ to `KNOWN_AUDIT_EVENTS`). |
| `infra/lambda/analytics-api/handler.py` | **New** | 3 routes; `_shared` authz (`is_internal` gate) + `audit_middleware`; dispatch to `queries.py`. |
| `infra/lambda/analytics-api/queries.py` | **New** | Activity Series counts (offloads) + Logs Insights client (start/poll/shape for logins, OTP funnel, active-time sessionization, coach turns) + roster join. |
| `infra/lambda/analytics-api/tests/test_shaping.py` | **New** | Unit tests for the pure aggregation/sessionization/funnel math (no AWS). |
| `infra/lib/stacks/api-stack.ts` | Modified | Register `analytics-api` + 3 routes (`userPoolAuthorizer`); grant Logs Insights + DDB reads + AuditKey decrypt; add audit subscription filter. |
| `infra/lib/stacks/audit-stack.ts` | Modified | Add `gosteady-{env}-d2c-custom-auth` to `sourceHandlers`. |
| `lib/api/api_client.dart` | Modified | `getAnalyticsOverview` / `getAnalyticsUsers` / `getAnalyticsUser`. |
| `lib/api/api_models.dart` | Modified | `AnalyticsOverview` / `AnalyticsUserRow` / timeseries models. |
| `lib/data/analytics_repository.dart` | **New** | Live + Mock split (mirror `fleet_repository.dart`). |
| `lib/screens/analytics_screen.dart` | **New** | KPI cards + per-user table + `fl_chart` timeseries; internal-gated. |
| `lib/state/app_router.dart` | Modified | `/analytics` route gated to `currentUser.isInternal` (mirror `/fleet` L98–103). |
| `lib/facility_demo/screens/facility_shell.dart` | Modified | Nav entry "Analytics" beside "Fleet" for internal users. |
| `docs/specs/phase-1.7-audit.md` | Modified | Add the 4 new events to the catalog table. |

### Dependencies
- Prior: Phase 1.7 audit pipeline (✅), `analytics-api` reuses `_shared` (`api_authz`, `api_audit`, `observability`, `api_error`). Frontend reuses the portal Cognito login + `api_client`. **No new pub/npm packages** (`fl_chart` already in `pubspec.yaml`).

### Configuration
- `analytics-api` env: `ACTIVITY_TABLE`, `USERS_TABLE`, `ROLE_ASSIGNMENTS_TABLE`, `PATIENTS_TABLE`, `AUDIT_LOG_GROUP=gosteady-{env}-audit`, `ANALYTICS_QUERY_TIMEOUT_S` (default 15).
- Feature flag: `/analytics` nav hidden unless `isInternal` (no separate flag needed).

---

## Testing

| # | Scenario | Method | Expected | Status |
|---|----------|--------|----------|--------|
| T1 | OTP funnel math (requested/completed/failed/abandoned + rate; resend dedupe) | Unit (`analytics-api/tests/test_shaping.py`) | Matches fixtures incl. edge cases | **Pass** (7 cases) |
| T2 | Active-time sessionization (idle-gap boundary, single-event session, all-day) | Unit | Correct session split + Σ minutes | **Pass** (5 cases) |
| T3 | Offload bucketing per-day/per-hour from Activity rows | Unit | Counts match; tz-correct `date` grouping | **Pass** (3 cases) |
| T3b | analytics-api JSON → Flutter model parse (overview + users; DDB decimal-as-string) | Unit (`test/analytics_render_test.dart`) | server↔client contract locked | **Pass** (6 cases) |
| T4 | `auth.login` emitted once per sign-in, **not** per refresh (A3) | Synthetic pre-token invoke (both `triggerSource`s) — deployed dev | login on Authentication, token_refresh (not login) on Refresh, login_failed on bogus user | **Pass** |
| T5 | `auth.otp_requested`/`auth.login`/`auth.otp_verify_failed` land in the audit LG (custom-auth now in `sourceHandlers`) | Synthetic trigger invoke (no Twilio) — deployed dev | auth.login ×2 + token_refresh + login_failed + otp_verify_failed all in `gosteady-dev-audit` | **Pass** |
| T6 | Emit failure never breaks auth (L5) | Fault-inject `emit_audit` throw | OTP still sends; login still succeeds | Coded (try/except); live fault-inject deferred |
| T7 | `/analytics` reachable only by `internal_*`; `analytics.*.read` audited | Synthetic JWT (internal + customer + no-token) — deployed dev | 200 / 403 / 401; audit landed `internal_access=true, severity=elevated` | **Pass** |
| T8 | Overview round-trip on real dev data | Live dev Lambda invoke | 200; 175 offloads · 9 active users · logins by method · insightsStatus=Complete | **Pass** |
| T9 | No raw phone / OTP code in any emitted event (L6) | Log inspection — deployed dev | Masked `phoneHint` only; no raw E.164, no code | **Pass** |

**Local build gates (2026-07-21, all green):** `test_shaping.py` 22/22 · `analytics_render_test.dart` 6/6 · `py_compile` all touched handlers · handler/queries/aggregate import-smoke (real Powertools + `_shared`) · `npm run build` (tsc) clean · `cdk synth GoSteady-Dev-Api GoSteady-Dev-Audit` clean (analytics fn + 3 routes + Logs-Insights IAM + 3 new audit source-filters materialized) · `flutter analyze` (new files) 0 errors / 0 warnings.

### Verification Commands
```bash
# after deploy — confirm the auth funnel lands (dev)
aws logs filter-log-events --log-group-name gosteady-dev-audit \
  --filter-pattern '{ $.event = "auth.otp_requested" || $.event = "auth.login" }' --region us-east-1
# exercise the endpoint through the audited API (internal token)
curl -H "Authorization: Bearer $GOSTEADY_TOKEN" \
  "$GOSTEADY_API_BASE/api/v1/admin/analytics/overview?range=7d"
```

---

## Deployment
```bash
# 1) auth emit points + audit sourceHandlers + catalog
cd infra && npx cdk deploy GoSteady-Dev-D2C-Auth GoSteady-Dev-Auth GoSteady-Dev-Audit
# 2) analytics-api + routes
npx cdk deploy GoSteady-Dev-Api
# 3) portal
cd .. && tools/deploy-portal.sh --env=dev   # (--exclude d2c/* guard already in place)
```
### Rollback Plan
- Emit points are additive + fire-and-forget — reverting the handler code removes them with zero data-path effect. Dropping `analytics-api` routes / the `/analytics` nav entry hides the feature; no schema or table to unwind (no new persistent store, per L2).

---

## Decisions Log

| # | Decision | Alternatives | Why |
|---|----------|--------------|-----|
| D1 | **Internal-only**, cross-tenant population view beside `/fleet` | Customer-facing per-tenant analytics | The 5 metrics are operator concerns; ships fastest; customer view is a scoped later phase (L1). |
| D2 | **Reuse the audit pipeline** as the event backbone; aggregate on-demand (Logs Insights + DDB) | Dedicated events/rollup table; 3rd-party SaaS | Right-sized for ~25 users; auth events are audit-worthy anyway; avoids BAA/CSP burden (L2). |
| D3 | Analytics reads are **API-only + audited** — no `--direct` boto3 escape hatch (unlike fleet) | Offer `--direct` like `tools/fleet.py` | Cross-tenant *user* reads must be audited (no silent reads); there's no demo-blocker justifying a bypass. |
| D4 | Metric #4 = **coarse proxy** from read-event timestamps **+ `auth.token_refresh`** emit (operator-approved 2026-07-21) to densify | Real client beacon now | L3 — defer the client SDK + CSP work until the proxy proves insufficient. |
| D5 | **On-demand queries in v1**, scheduled pre-aggregation deferred to the stubbed `scheduled-jobs` Lambda | Build the rollup now | Honors L2; the rollup is the *scale* path (A1), unneeded at pilot size. |
| D6 | Offloads counted **per patient/user + per population**, not per-device | Per-device as a first-class cut | Schema is patient-centric (PK `patientId`); per-device needs a new GSI or assignment-history join — device≈patient 1:1 while assigned anyway. |
| D7 | Unify all login completions under **`auth.login` + `extra.method`** | Separate events per path | One metric, clean method breakdown; keeps the existing QR `d2c.login_code_verified` for back-compat. |

---

## Open Questions
- [x] **#3 abandonment window N** — **15 min** (= OTP validity); a resend within the window counts as one funnel entry (operator, 2026-07-21).
- [x] **#4 idle-gap** — **30 min** (matches customer token idle) (operator, 2026-07-21).
- [x] **Emit `auth.token_refresh`?** — **Yes** (operator, 2026-07-21); emitted on the refresh trigger in both pools to densify #4.
- [x] **Facility `auth.login_failed`?** — **Yes, wire it** (operator, 2026-07-21) for a fuller funnel. `auth.mfa_challenge` stays deferred.
- [ ] **"Active user" definition for the population KPI** — any audited action in range, or specifically a dashboard read? (lean: any read/login/coach event.)
- [ ] **Retention framing in the UI** — how to present that #2/#3/#4 start at deploy date and history is TTL-bounded (A2) without it reading as "data missing."
- [ ] **D2C verify-fail rollup** — keep `auth.otp_verify_failed` distinct from `auth.login_failed` (OTP-specific), or also roll up? (lean: keep distinct.)

## Pilot residents view (internal facility-level monitoring)

Added 2026-07-21 (operator request: "facility-level view of the pilot for an internal user"). The pilot's 4 participants (GS0002000002–05: Dorothy Iupert, Tom Clark, Mitch, Jo ferguson) are **4 separate D2C households** — each its own `dtc_*` client + synthetic facility/census — so no single facility contains them, and internal users were previously bounced from `/census` entirely. This adds an internal, cross-tenant monitoring surface.

- **Backend (patient-api, no new IAM):** `GET /api/v1/admin/residents` — internal-only, audited (`residents.list.read`, count-only subject → auto-elevated `internal_access`). Cross-tenant scan of **all active D2C patients** (`clientId begins_with dtc_` AND `status=active`), each joined to its active device (serial + status + `lastSeen` heartbeat) and last offload. Pilot-scale scan (`by-client-status` GSI is the scale path). The per-resident detail/activity/alerts reads **already served internal callers** (patient-api bypasses tenancy for `internal_*`) — zero new backend for the drill-down.
- **Frontend:** `/residents` roster renders the **exact Census `PatientListView` table** (same columns — Active minutes today/7d/trend, Steps+trend, Gait+trend, Notifications — same styling) so it matches the facility demo. Rows are built from `GET /admin/residents` + per-patient `rowStatsFor`/`notificationsFor` (patientId-keyed → serve internal; same stats pipeline the Census uses). D2C households have no unit/room, so the **Location column shows the cap serial**; `patient_list_view.dart` was made to omit the "· Rm" suffix when room is empty (backward-compatible — customers with a room render unchanged). Tap a row → `/residents/{patientId}` mounts the **existing** `PatientDetailView` (activity charts, alerts, device health) from just a patientId. Two blockers fixed: `patient_detail_view.dart` threw on an empty census cache (`allUnits()`) — now falls back to the patient's `unitId`; and the empty-room suffix above. "Residents" nav added beside Fleet/Analytics.
- **Not** a data migration: the 4 stay as live D2C households (their app/coach/care-circle untouched); this is internal cross-tenant *read* only.

## Changelog
| Date | Author | Change |
|------|--------|--------|
| 2026-07-21 | scoping session | Initial DRAFT — availability audit across the 4 backend areas; scope locked with operator (L1 internal-only, L2 audit-pipeline backbone, L3 coarse #4). Metric-by-metric design + emit points + `analytics-api` + `/analytics` screen. No code yet. |
| 2026-07-21 | follow-up decisions | Operator resolved the 4 open questions: OTP-abandon window 15 min + resend-dedupe; #4 idle-gap 30 min; **emit `auth.token_refresh`** (both pools, refresh trigger); **wire facility `auth.login_failed`**. Status → In Progress; implementation started. |
| 2026-07-21 | walker/care-circle segment | Operator: segment the per-user analytics (logins/OTP-abandoned/active-min/coach/app-active) by walker user vs non-walker Care Circle member. Backend: analytics-api now reads RoleAssignments (added table + read grant; already had identityKey) and tags each `AnalyticsUserRow` with the authoritative **`isWalkerUser`** (resolved like d2c-pre-token: explicit flag wins, else `role==household_owner`). Frontend: an **All / Walkers / Care circle** `SegmentedButton` on the per-user table filters the rows and re-totals a segment summary (Σ logins/OTP-abandoned/active-min/coach + app-active count). 9/9 model tests (incl. isWalkerUser parse). Deployed Api + portals dev + prod. |
| 2026-07-21 | residents columns tuned | Operator: rollators report no steps + active-min bands not yet calibrated. Parameterized the shared `PatientListView` with `showSteps` / `colorMetrics` (both default true → Census unchanged); residents passes both false → **Steps + Step-trend columns dropped, active-minutes rendered plain black**. Refactored the table to an id-keyed column model so dropping columns keeps header/cells aligned. 26/26 tests pass (incl. new flag coverage + no Census regression). Redeployed both portals. |
| 2026-07-21 | residents = Census list view | Operator: make `/residents` look like the facility-demo Census list view. Replaced the card layout with the **exact `PatientListView`** table (rich activity columns) fed by `rowStatsFor`/`notificationsFor` per resident (reuses the Census stats pipeline; works for internal). Location column shows the cap serial for D2C (no unit/room); made `patient_list_view` omit "· Rm" when room empty (backward-compatible). Widget-test verified render (internal empty-room + customer room-preserved). Redeployed both portals. |
| 2026-07-21 | internal pilot residents view | Operator asked for a "facility-level view of the pilot for an internal user." Found the 4 participants (GS0002000002–05) are 4 isolated D2C tenants + internal users are bounced from `/census`. Built **Option A** (internal cross-tenant view, no data migration): `GET /admin/residents` on patient-api (internal-gated, audited, scans active-D2C + device/heartbeat/last-walk join — no new IAM) + `/residents` roster & `/residents/{id}` detail (reuses the existing `PatientDetailView`; fixed its empty-`allUnits()` throw for internal). Nav added beside Fleet/Analytics. Dev endpoint live-verified (10 active-D2C residents). 9/9 dart tests, analyze clean. Deployed Api + portals dev + prod. |
| 2026-07-21 | "LAST SEEN" disambiguation | Operator saw a ~21h "LAST SEEN" next to GS0002000005 and read it as device-offline — but that column was the **user's** last in-app audit event, not the device. Investigation: device heartbeated **that same hour** (registry `lastSeen`), last walk offload was yesterday, user last opened the app ~21h prior. Fix: **renamed the user column "LAST SEEN" → "APP ACTIVE"**, and **added a "DEVICE SEEN" column** = Device Registry `lastSeen` (real heartbeat; stale >24h → offline color), grouped next to DEVICE. Backend: `queries.get_device_last_seen` (per-serial GetItem) + `deviceLastSeen` field + `deviceTable` read grant + `DEVICES_TABLE` env. Frontend: widened page to 1240 + a visible horizontal Scrollbar so a wide table never silently clips again. Redeployed Api + portal to **prod + dev**; prod live-verified — for GS0002000005: DEVICE SEEN 2026-07-21T20:56Z (online) vs APP ACTIVE 2026-07-20T20:57Z (~24h). 7/7 dart tests (incl. deviceLastSeen≠lastActive). |
| 2026-07-21 | table fix + PROD launch | Fixed the per-user table clipping its last column (DEVICE pushed the row to ~1172px > the 1100px card) — tightened col widths/gap to fit ~1056px, still scrolls below 1100. **Deployed all 4 stacks + portal to PROD** (`--context env=prod`; `cdk diff` verified 0 destructive changes + no pool replacement; Api before Audit). Prod live-verified read-only (no synthetic auth events into the prod audit log): gate 200/403/401, overview 194 offloads / 5 active users, Device ID column maps real walkers to real serials (`GS0002000001` 148 offloads; 0 unattributed). Also live at `portal.gosteady.co`. Counsel/PII sign-off still open (operator-decision launch). |
| 2026-07-21 | Device ID column | Added **`deviceSerial`** to the per-user table (operator request): `queries.scan_patient_device_map` (active `DeviceAssignments`) → handler joins user→patient→serial → new `deviceSerial` field on `AnalyticsUserRow` + a **DEVICE** column in `analytics_screen`. IAM: `deviceAssignmentsTable.grantReadData` + `DEVICE_ASSIGNMENTS_TABLE` env. Redeployed Api + dev portal. **Live-verified:** `/users` invoke returns 200 with `deviceSerial` on every row — the one account-linked walker maps to `GS9999999981` (135 offloads), rest `—`. Tests: 7/7 dart (incl. deviceSerial + missing-key cases). |
| 2026-07-21 | deploy + live verify (dev) | **Deployed all 4 stacks to dev** (`cdk diff` confirmed D2C-Auth/Auth = Lambda-code-only, no pool replacement; Api before Audit so the analytics-api log group precedes its subscription filter) + dev portal (`dev.portal.gosteady.co`, contains `/analytics`). **Live-verified via synthetic invokes (no passwords, no SMS):** T4 (login on Authentication / token_refresh on Refresh / login_failed on bogus) · T5 (all auth events forwarded to `gosteady-dev-audit`, incl. from newly-subscribed `d2c-custom-auth`) · T7 (200/403/401 gate + `analytics.overview.read` auto-elevated `internal_access`) · T8 (overview 200 on real data: 175 offloads, 9 active users, logins by method) · T9 (masked phone only, no code). Bonus: the diff surfaced that `d2c-claim`'s audit filter was never deployed — now fixed. **Open before prod:** operator visual click-through + counsel/PII sign-off. |
| 2026-07-21 | implementation | **Built, locally verified — pending dev deploy.** Backend: auth emit points in `d2c-custom-auth` (otp_requested / login[sms_otp] / otp_verify_failed), `cognito-pre-token` (login[password] / login_failed / token_refresh, gated on `triggerSource`), `d2c-pre-token` (token_refresh), `d2c-claim` (login[qr_relogin]); the 3 stdlib triggers emit the audit-shape JSON line inline (no `_shared`/Powertools on the auth hot path, best-effort per L5). 5 new `audit_catalog` constants. `audit-stack` `sourceHandlers` += d2c-custom-auth, d2c-pre-token, analytics-api. New `analytics-api` Lambda (`handler`+`queries`+`aggregate`, pure-core unit-tested) + 3 internal-gated routes + Logs-Insights IAM + errors alarm in `api-stack`. Frontend: analytics models + `ApiClient` methods + `analytics_repository` (Live/Mock) + `analytics_screen` (range toggle · 5 KPI cards · fl_chart day/hour offloads · per-user table) + `/analytics` route (internal-gated) + cross-nav with `/fleet`. Gates: 22 py + 6 dart tests green, tsc + cdk synth + flutter analyze clean. |

# Device Fleet Ops Tooling — internal pilot operator tool

## Overview
- **Phase**: 2A-DL follow-on (operational tooling)
- **Status**: Deployed to **dev + prod** (2026-07-12) — `{Env}-Api` (route live, 401/404 wiring smoke-test passed both envs) + `{Env}-Observability` (fleet-health dashboard). CLI verified live against **prod via `--direct`** (`ls`/`check` on the real 2-unit fleet). Local: tsc + `cdk synth` + 22 unit tests. **Pending (token path):** an `internal_admin` user in a pool + a token for API-authenticated reads/writes (A1) — the prod facility pool currently has 0 users, so `--direct` is the demo path.
- **Branch**: feature/infra-scaffold
- **Date Started**: 2026-07-12

Gives a GoSteady internal operator the ability to **see the status of every
device and safely run lifecycle commands** while running the first real 5-unit
D2C rollator pilot. The device lifecycle *commands* already exist as audited
`device-api` endpoints (`provision`, `end_assignment`, `force_reset`,
`decommission`, `recover`, …); what is missing for a pilot is (a) a **fleet
view**, (b) **single-device diagnosis** ("why is this one stuck?"), and (c)
**readiness gates** ("is this safe to ship / hand to the next user?"). This
delivers a CLI (`tools/fleet.py`) over one new read endpoint plus a passive
CloudWatch dashboard.

Framing decided with the operator (2026-07-12): the individual commands are the
easy 20%; a pilot is won/lost on *diagnosis + proactive detection + readiness
gates*. See the capability matrix in the session that scoped this.

## Locked-In Requirements

| # | Requirement | Decided In | Rationale |
|---|-------------|-----------|-----------|
| L1 | Lifecycle **writes** go through the existing `device-api` endpoints — never direct DDB/IoT | ARCHITECTURE §Device Lifecycle | Preserves state-machine validation, audit emission, and the Shadow `desired.activated_at`/`wipe_requested` invariants (DL14/DL15). A direct write would silently break the audit trail + recycle orchestration. |
| L2 | CLI authenticates as an `internal_admin` Cognito user via the **Portal-Customer** app client (USER_PASSWORD_AUTH or a pasted browser `id_token`) | this spec (see D2) | Portal-Customer is the *only* client in the device-api authorizer audience ([api-stack.ts:181](../../infra/lib/stacks/api-stack.ts)). Portal-Internal tokens are rejected at the gateway. |
| L3 | v1 is **CLI-first**; no Flutter/internal UI | operator, 2026-07-12 | Right-sized for 5 units + activation week; the browser internal-auth story is still half-designed (ARCHITECTURE §Internal Access). |
| L4 | Every internal action stays **audited** (writes via the endpoints' existing `emit_audit`; the read endpoint is internal-role-gated) | ARCHITECTURE §Internal Access | "No silent reads/writes" for internal cross-tenant access. |

## Assumptions

| # | Assumption | Risk if Wrong | Validation Plan |
|---|-----------|---------------|-----------------|
| A1 | An `internal_admin` Cognito user exists in the dev pool (or can be created) with a known credential | CLI can't mint a token; falls back to pasted `id_token` only | Confirm/create an internal user; smoke `initiate-auth`. |
| A2 | `internal_admin` accounts require MFA (ARCHITECTURE), so `USER_PASSWORD_AUTH` may return an MFA challenge | Auto-mint needs challenge handling | Primary auth path is a **pasted `id_token`** (`--token`/`GOSTEADY_TOKEN`); auto-mint is best-effort for non-MFA dev users. |
| A3 | Registry + Shadow + DeviceAssignments joins are cheap at pilot scale (≤ ~50 rows) | Scan cost | Fleet scan is a single small page; N per-device Shadow gets. Revisit if fleet > few hundred. |

## Scope

### In Scope
- **`GET /api/v1/admin/devices`** (new, internal-only, audited) — scan Device
  Registry, join live Shadow telemetry + current assignment, return the fleet
  with derived lifecycle flags (`wipePending`, `activationPending`, outstanding
  cmd maps).
- **`tools/fleet.py`** CLI:
  - `ls` — fleet status board (serial, type, status, battery, last-seen, patient).
  - `status GS…` — single-device diagnosis: joined state + **event timeline**
    (audit history from CloudWatch Logs).
  - `check GS…` — **pre-ship health gate** (connects + heartbeats recently +
    correct `deviceType` + `ready_to_provision` + `walkerId` present → go/no-go).
  - `ready GS…` — **ready-for-next-user gate**: `ready_to_provision` **and**
    Shadow `reported.wipe_complete` matches the last wipe **and** battery ok
    **and** seen recently. Guards against handing User B a device still holding
    User A's cached data.
  - Command wrappers: `provision`, `end`, `reset` (force-reset), `decommission`,
    `recover` — thin calls to the existing endpoints with confirmation prompts
    on destructive ops.
- **CloudWatch fleet-health dashboard** — battery / last-seen age / devices-by-
  state / stuck-in-provisioned across all serials (SEARCH expressions over the
  per-device EMF metrics).

### Out of Scope (Deferred)
- **Operator alerting** (silent / battery-crit / stuck → Slack/SMS to ops) — signals
  exist (`behavioral-detector`, `DeviceStuckInProvisioned` alarm); routing to a
  pilot-ops channel is a fast follow.
- **Asset labeling / participant map** (freetext label on the registry row) — needs
  a registry attribute + a small write path; deferred.
- **Live-watch** (`watch GS…` tailing shadow/heartbeat in real time).
- **OTA firmware push** (IoT Jobs), `move_facility`/`move_client` in the CLI,
  bulk ops, QR/walkerId regeneration, refurb/RMA — not pilot-critical.
- ~~**Flutter internal fleet screen**~~ — **BUILT 2026-07-12** (see changelog). The
  `/fleet` route (internal-role-gated) renders the fleet board with per-device
  actions, reusing the portal's Cognito login + `api_client` + the same
  `GET /admin/devices` endpoint.

## Architecture

### Infrastructure Changes
- `GoSteady-{env}-Api` stack: add the `GET /api/v1/admin/devices` route on the
  existing HTTP API, bound to the existing `userPoolAuthorizer`. **No new IAM** —
  `device-api` already holds `deviceTable` read (scan) + `iot:GetThingShadow`.
- `GoSteady-{env}-Observability` stack: add a `FleetHealthDashboard` construct.

### Interfaces
- `GET /api/v1/admin/devices` → `{ "devices": [FleetRow], "count": n }`, where
  `FleetRow` = registry lifecycle fields + `walkerId` + `currentAssignment`
  (`{patientId, facilityId, censusId, startedAt}` | null) + `telemetry`
  (battery/signal/firmware/lastSeen/**wipeComplete**/**reportedActivatedAt**) +
  `outstandingActivationCmds` / `outstandingWipeCmds` maps.
- Timeline read: CloudWatch Logs `filter_log_events` on the `device-api` audit
  events for a serial (no new endpoint in v1; the operator has logs-read creds).

### Data Flow
```
fleet ls / status / check / ready
        │  (id_token: Portal-Customer, role=internal_admin)
        ▼
GET /api/v1/admin/devices ──► scan DeviceRegistry ─┬─► GetThingShadow (live)
                                                   └─► DeviceAssignments (active)
        (status/check/ready derived client-side from the returned rows)
        timeline ──► CloudWatch Logs filter (device-api audit events)

fleet provision / end / reset / decommission / recover
        │  (same id_token)
        ▼
existing POST /api/v1/devices/{serial}/… ──► state machine + emit_audit + Shadow desired
```

## Implementation

### Files Changed / Created
| File | Change Type | Description |
|------|------------|-------------|
| `infra/lambda/device-api/handler.py` | Modified | `_action_fleet_list` + `_current_assignment` helper; extend `_shadow_telemetry` field map (add `wipe_complete`, `activated_at`); add route `GET /api/v1/admin/devices`. |
| `infra/lib/stacks/api-stack.ts` | Modified | Register the new GET route (no new IAM/env). |
| `infra/lib/constructs/dashboards/fleet-health.ts` | New | Fleet-health CloudWatch dashboard construct. |
| `infra/lib/stacks/observability-stack.ts` | Modified | Instantiate `FleetHealthDashboard` + output URL. |
| `tools/fleet.py` | New | The operator CLI. |
| `docs/playbooks/device-fleet-ops.md` | New | Operator runbook (setup/handoff/reset flows). |
| `infra/lambda/device-api/tests/test_fleet_list.py` | New | Unit tests for the pure fleet-row shaping + readiness derivations. |

### Configuration
- CLI env: `GOSTEADY_API_BASE` (HTTP API base URL), `GOSTEADY_TOKEN` (pasted
  `id_token`) **or** `GOSTEADY_USER`/`GOSTEADY_PASS` + `GOSTEADY_CLIENT_ID`
  (Portal-Customer) for best-effort auto-mint, `GOSTEADY_ENV` (dev|prod),
  `AWS_REGION` (us-east-1). Defaults target dev.

## Decisions Log

| # | Decision | Alternatives | Why |
|---|----------|--------------|-----|
| D1 | One read endpoint (`GET /admin/devices`); derive `status`/`check`/`ready` **client-side** from its rows | Per-view endpoints | Fleet is tiny; one join primitive is reusable by a future UI and keeps backend surface minimal. |
| D2 | CLI auths via **Portal-Customer** internal token, not Portal-Internal | Portal-Internal client; add Portal-Internal to authorizer audience | Portal-Internal is not in the authorizer audience (deliberate, unified-portal L1); re-adding it reverses an architecture decision. Portal-Customer USER_PASSWORD_AUTH is the documented admin-mint path. |
| D3 | Reads default to **through the API** (audited); a `--direct` flag adds a token-free boto3 read path (reads only) | Direct boto3 reads only; API only | Internal reads should be audited + the endpoint is the UI-reusable primitive — so that's the default. But the prod pool has no internal user yet, so `--direct` (operator AWS creds; CloudTrail-logged) unblocks the demo. Writes NEVER go direct. Timeline uses Logs either way. |
| D4 | No registry schema change in v1 | Add a `label` attribute now | Asset labeling deferred; avoids a write path + migration this week. |

## Open Questions
- [x] Internal-user provisioning — **resolved.** `tools/create-internal-user.sh`
      creates the Cognito user + `custom:mfa_enrolled=true` + the RoleAssignments
      row (pre-token reads that row for `custom:role`/`custom:clientId`) and
      self-verifies by minting a token. Pool MFA is `OPTIONAL` so `USER_PASSWORD_AUTH`
      auto-mint works. **MFA is attribute-based** today — real TOTP is Phase-2B
      (cognito-pre-token gates on the attribute; see script header). Operator-run
      (privileged account + password + access grant).
- [ ] **Harden internal MFA** — wire real TOTP enrollment (Phase-2B) so internal
      tokens require a true second factor, not just the `custom:mfa_enrolled` attr.
- [ ] Add an audited `GET /admin/devices/{serial}/history` endpoint later so the
      timeline stops depending on direct Logs access (post-v1).

## Changelog
| Date | Author | Change |
|------|--------|--------|
| 2026-07-12 | ops scoping session | Initial spec — scope locked (MUST set + CloudWatch dashboard; alerting/labeling/live-watch deferred); auth constraint (D2) captured. |
| 2026-07-12 | implementation | Built: `GET /admin/devices` (`_action_fleet_list` + `_fleet_row` + `_current_assignment`; `device.fleet.read` audit); route wired; `FleetHealthDashboard`; `tools/fleet.py` (ls/status/check/ready + provision/end/reset/decommission/recover); `docs/playbooks/device-fleet-ops.md`. Verified: `tsc` clean, `cdk synth` renders the dashboard + route, 19 unit tests green, no regression (78 lambda tests pass). |
| 2026-07-12 | deploy + prod | Deployed to **dev** then **prod** (`GoSteady-{Dev,Prod}-Api` + `-Observability`); 401/404 wiring smoke-test passed both. Added CLI **`--direct`** mode (`_shape_row` + `_DirectSource`; token-free boto3 reads for the demo — prod pool has 0 users) + `--env`; verified `--direct --env prod ls/check` on the live 2-unit fleet (+3 tests, 22 total). Surfaced a data-hygiene item: untyped orphan row `GS9999999981` in `gosteady-prod-devices`. |
| 2026-07-12 | prod internal user | `tools/create-internal-user.sh` (operator-run) creates the Cognito user + `custom:mfa_enrolled=true` + RoleAssignments row + self-verifies a token mint. Ran for `jace@gosteady.co` (prod, internal_admin); verified `fleet --env prod ls` round-trips through the audited API (token → authorizer → handler → `device.fleet.read`). MFA is attribute-based today (Phase-2B TOTP is the follow-up). |
| 2026-07-12 | ownership rotation | **Gap surfaced by live prod test:** ending an assignment recycles the device but (by design) KEEPS ownership — so a D2C device stays registered to the old household and a new household can't claim it via QR (`app.gosteady.co/setup/{walkerId}` → "already registered"). No operation released ownership. Added an `internal_admin`-only, audited **`release`** action (`device.ownership_released`; nulls `owningClientId`/`owningFacilityId`; precondition status ∈ {ready_to_provision, discontinued}) → device returns to the unowned pool + becomes QR-claimable. Surfaced as **"End + release"** (assigned devices, chains end→release) / **"Release ownership"** (owned+idle) on the fleet screen, `fleet release` / `fleet end --release` in the CLI. Wipe-before-reuse still holds (a new household can only claim once the device reaches ready_to_provision, post-wipe-ack). Deployed dev+prod; portal redeployed. |
| 2026-07-12 | prod cognito fix | First-prod-deploy gap: `cognito_config.dart` hardcoded the **dev** pool, so the prod portal auth'd sign-ins against the dev pool → the prod-pool user `jace@` couldn't log in (and a dev-pool token's audience would be rejected by the prod API authorizer anyway). Fixed: parameterized pool/client via `--dart-define` (dev defaults preserved) + `deploy-portal.sh` resolves them from `{Env}-Auth` (like `API_BASE_URL`). Redeployed; verified the deployed `main.dart.js` bakes the prod pool (`us-east-1_zjfP3H3U3` ×3), dev pool absent. |
| 2026-07-12 | prod portal hosting | Stood up `GoSteady-Prod-Hosting` (S3 `gosteady-prod-portal-hosting` + CloudFront `E31X2931LRPOXR` `d1f2rlwd8q9jvx.cloudfront.net` + ACM cert for `portal.gosteady.co`, DNS-validated via operator Squarespace CNAME). Deployed the portal (with the fleet screen) via `deploy-portal.sh --env=prod` — built live against the prod API, serving HTTP 200 via CloudFront. **LIVE 2026-07-12:** operator added the round-2 CNAME; `portal.gosteady.co` resolves + serves the portal (HTTP 200, valid cert, verified via SNI). Fleet board live at **`portal.gosteady.co/fleet`** (sign in as internal_admin `jace@gosteady.co`). |
| 2026-07-12 | portal fleet UI | Built the **internal fleet screen** in the Flutter portal: `FleetDevice`/`FleetDevicesResponse` models, `ApiClient` methods (`getAdminDevices` + `forceReset`/`decommissionDevice`/`recoverDevice`), `FleetRepository` (live + mock), `lib/screens/fleet_screen.dart` (table + status chips + battery/last-seen + per-device actions with confirm dialogs; internal_admin write / internal_support read-only), and the internal-role-gated `/fleet` route (first role-gate in the app). Verified in-browser (demo): board renders with color-coded chips + the force-reset confirm dialog; `flutter analyze` clean (0 errors). |

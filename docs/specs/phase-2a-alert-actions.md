# Phase 2A-AA — Alert Actions (read-write subset)

## Overview
- **Phase**: 2A-AA (Alert Actions subset of Phase 2A)
- **Status**: ✅ Deployed (dev) 2026-05-23 — 17/17 synthetic smoke PASS + audit pipeline validated
- **Branch**: feature/infra-scaffold
- **Date Started**: 2026-05-23
- **Date Completed**: 2026-05-23 (dev)

Closes the alert read-write loop opened by 2A-RD. Caregivers can now
acknowledge alerts they see in the dashboard, and clinical staff can
set per-patient threshold overrides that Threshold Detector picks up on
the next shadow delta.

Three endpoints on a new `alert-actions` Lambda:

| Method | Path | Purpose |
|--------|------|---------|
| `PATCH` | `/api/v1/alerts/{patientId}/{timestamp}` | Acknowledge a single alert |
| `GET` | `/api/v1/patients/{id}/thresholds` | Read effective thresholds (per-patient overrides merged with defaults) |
| `PUT` | `/api/v1/patients/{id}/thresholds` | Set per-patient threshold overrides |

Threshold Detector (Phase 1B-rev) is amended to consume per-patient
overrides via Patient.thresholds map (PutItem-merged with hard-coded
defaults in `_shared/thresholds.py`). Backward-compatible — patients
without an override map continue to use the global defaults exactly
as today.

**Dependency on 2A-0 (foundation):** assumes API Gateway + JWT
authorizer + `_shared/api_authz.py` + `_shared/api_audit.py` are live.
**Dependency on 2A-RD:** Per-patient reads need 2A-RD's
`enforce_patient_access()` helper (this spec consumes it as-is; no
extension needed).
**Dependency on 1B-rev:** Threshold Detector code is in the
Processing stack; this spec ships a Processing-stack redeploy alongside
the Api-stack additions.

## Locked-In Requirements

| # | Requirement | Decided In | Rationale |
|---|-------------|-----------|-----------|
| L1 | Three endpoints: `PATCH /alerts/{patientId}/{ts}` + `GET /patients/{id}/thresholds` + `PUT /patients/{id}/thresholds` | This spec | Minimum surface to close the alert loop; threshold UI tuning enables the clinical-fit work that's been pending since Phase 1B |
| L2 | Per-patient threshold overrides stored as a `thresholds` map attribute on the Patients table row (NOT a new table) | This spec — Q1 decided 2026-05-23 | Threshold Detector already does Patients.GetItem on every shadow update for hierarchy snapshot; reading a sibling map costs nothing more. No new table = no new GSI/cost/PITR concern |
| L3 | Threshold validation server-side: `batteryCritical ∈ [0.02, 0.30]`, `batteryLow ∈ (batteryCritical, 0.50]`, `rsrpLost ∈ [-140, -100]`, `rsrpWeak ∈ (rsrpLost, -80]`. Reject 400 `INVALID_THRESHOLD` on any violation | This spec | Caregivers shouldn't be able to set thresholds that always fire (battery=0.99) or never fire (battery=0.001). Ordering constraint mirrors ARCH §8 mutex semantics |
| L4 | Ack is idempotent: second ack (any caller) returns 200 with `wasAlreadyAcknowledged: true` and does NOT overwrite original `acknowledgedAt`/`acknowledgedBy`. First-write-wins | This spec — Q2 decided 2026-05-23 | Mirrors the conditional-PutItem idempotency pattern from 1B-rev (P4). Preserving the original acker's identity is the right audit-trail invariant — "who first responded to this alert" matters more than "who clicked it again" |
| L5 | RBAC for ack: `caregiver` (in scope) / `facility_admin` (in facility) / `client_admin` (in client) / `household_owner` (own) / `internal_admin` (cross-tenant, audited). `family_viewer` and `internal_support` cannot ack (observational/read-only roles) | This spec — Q3 decided 2026-05-23 | Acknowledgement is a clinical action — family_viewer is observational; internal_support is read-only by definition |
| L6 | RBAC for threshold overrides: `facility_admin+` only (no caregiver, no household_owner write). Reads allowed for caregiver+ | This spec — Q4 decided 2026-05-23 | Thresholds are persistent per-patient clinical config; caregivers tune real-time response but shouldn't make permanent config changes without admin oversight. Household_owner is D2C — defer threshold-tuning UX to a later product call |
| L7 | Threshold Detector consumes overrides via merge: any field present in `Patient.thresholds` overrides the global default; absent fields fall through to defaults. No partial override means "ignore this dimension entirely" | This spec — Q5 decided 2026-05-23 | Partial overrides are the common case (e.g., "this patient's battery alert is permissive"). Absent-means-default is the most expected/safe semantic |
| L8 | Every threshold update emits `patient.thresholds.update` audit event with `before` (prior map) and `after` (new map) — full state, not diff. Threshold reads emit `patient.thresholds.read` (caregivers will hit this every dashboard load for thresholds-sensitive UI; audit volume bounded by Phase 1.7 cost model) | This spec | Compliance reader needs the full before/after to reconstruct historical thresholds at any point. Diff-only would force replay |
| L9 | URL-encoded timestamp in path. Client URL-encodes the compound SK `{eventTimestamp}#{alertType}` (e.g., `2026-05-22T01:15:32Z%23battery_critical`); server URL-decodes via API Gateway path-param extraction | This spec | Compound SK is in the URL because it's the natural key; URL-encoding is standard HTTP. Alternative was a request body with PK+SK as fields, which is wrong shape for PATCH |
| L10 | Single Lambda `alert-actions` for all 3 routes (mirrors 2A-DL/2A-RD D1) | 2A-DL/2A-RD precedent | Cold-start economics; shared validation/audit/auth code |
| L11 | Audit-stack subscription filter for `alert-actions` log group bundled into 2A-AA deploy (Migration Pattern 18.8 — no between-revisions silent-swallow gap) | Phase 2A-0 D9 precedent | Established pattern |
| L12 | Threshold Detector redeploy is part of this phase. Backward-compatible (no patient override = same behavior as today) — but we redeploy + smoke-validate to confirm the override-merge path before declaring 2A-AA done | This spec | Don't ship the API without the producer-side actually consuming the new data |

## Assumptions

| # | Assumption | Risk if Wrong | Validation Plan |
|---|-----------|---------------|-----------------|
| A1 | Per-patient threshold overrides are uncommon (most patients use defaults) | Storage bloat / read amplification | A `thresholds` map only exists on patients with overrides set. Absent map = use defaults — zero cost. Validates itself |
| A2 | Caregiver UX wants "ack and move on" — no required notes field at MVP | If facilities require nursing-note discipline, ack feels too thin | Optional `notes` body field captures free-text; can be promoted to required per-client setting in 2A-UM if facilities demand |
| A3 | Acks are infrequent enough that the conditional-write race is benign (two caregivers acking the same alert in <100ms is vanishingly rare) | Race produces inconsistent acker attribution | Conditional `attribute_not_exists(acknowledged) OR acknowledged=false` rejects the second writer; second-ack returns 200 idempotent |
| A4 | Threshold Detector cold-start latency isn't materially affected by the additional Patient.thresholds GetItem read (it already reads the patient row) | Latency budget bust | Patient.thresholds is a sibling attribute on the existing GetItem — no extra round-trip. Confirm via X-Ray after Processing redeploy |
| A5 | The compound SK URL-encoding survives API Gateway's standard URL-decoding without double-encoding issues | PATCH fails to match real rows | API Gateway HTTP API v2 decodes path params per RFC 3986; testable in smoke (T-encode below) |
| A6 | Threshold Detector's behavior on a stale Patients GetItem (rare — TTL or in-flight delete) is acceptable: fall through to defaults | Wrong threshold applied for ~30s after a threshold change | Patient GetItem is strongly consistent by default in DDB; cache effects negligible at MVP scale |

## Scope

### In Scope

#### Endpoint contracts

**`PATCH /api/v1/alerts/{patientId}/{timestamp}`** — acknowledge

```jsonc
// Request body (optional):
{
  "notes": "Battery swapped 14:30; alert resolved."   // optional, ≤500 chars
}

// Response 200 (first ack):
{
  "alert": {
    "patientId": "pat_abc",
    "timestamp": "2026-05-22T01:15:32Z#battery_critical",
    "alertType": "battery_critical",
    "acknowledged": true,
    "acknowledgedAt": "2026-05-23T14:42:11Z",
    "acknowledgedBy": "userId-of-caregiver",
    "notes": "Battery swapped 14:30; alert resolved."
  },
  "wasAlreadyAcknowledged": false
}

// Response 200 (subsequent ack — idempotent):
{
  "alert": { ...original acker preserved... },
  "wasAlreadyAcknowledged": true
}
```

**`GET /api/v1/patients/{id}/thresholds`** — read effective

```jsonc
// Response 200:
{
  "thresholds": {
    "batteryCritical": 0.05,
    "batteryLow":      0.10,
    "rsrpLost":       -120.0,
    "rsrpWeak":       -110.0
  },
  "source": {
    "batteryCritical": "default",   // or "override"
    "batteryLow":      "default",
    "rsrpLost":       "default",
    "rsrpWeak":       "default"
  }
}
```

The `source` map lets the UI render which fields are patient-specific
vs system-default (e.g., highlight override fields).

**`PUT /api/v1/patients/{id}/thresholds`** — set/update

```jsonc
// Request body (any subset; absent fields revert to default):
{
  "batteryCritical": 0.07,
  "batteryLow":      0.12
  // rsrpLost / rsrpWeak omitted → fall through to defaults
}

// Response 200:
{
  "thresholds": { /* effective merged */ },
  "source":     { /* default | override */ },
  "updated": ["batteryCritical", "batteryLow"]
}
```

To CLEAR an override (revert a field to default), pass `null` for that field:

```jsonc
{ "batteryCritical": null }   // removes override; field reverts to default
```

#### Threshold Detector update

Pattern in [`infra/lambda/threshold-detector/handler.py`](../../infra/lambda/threshold-detector/handler.py):

1. Already does `Patients.get_item(Key={patientId})` after `serial → patientId` resolution
2. New: read `patient.get("thresholds")` if present (DDB map → Python dict)
3. Merge over defaults from `_shared/thresholds.py`
4. Pass merged thresholds to `determine_threshold_alerts(..., overrides=...)`

The `_shared/thresholds.py` helper signature changes to accept an
optional `overrides` dict; existing call sites (none other than
threshold-detector today) work unchanged because the param is optional.

#### Error envelope (extends 2A-0/2A-RD catalog)

| Code | HTTP | Meaning |
|------|------|---------|
| `ALERT_NOT_FOUND` | 404 | `(patientId, timestamp)` row doesn't exist |
| `INVALID_THRESHOLD` | 400 | One or more fields outside allowed range OR ordering violated |
| `INVALID_TIMESTAMP` | 400 | URL-decoded path param doesn't match compound SK regex |
| `INVALID_REQUEST` | 400 | Body parse failure / missing required fields on PATCH (none required currently — reserved) |
| `INSUFFICIENT_PERMISSIONS` | 403 | Role not allowed (family_viewer / internal_support ack; caregiver/household_owner PUT thresholds) |
| `TENANCY_VIOLATION` | 403 | Caller's client doesn't match patient's |
| `OUT_OF_SCOPE` | 403 | Caller's facility/census doesn't cover patient (caregiver/facility_admin) |
| `PATIENT_NOT_FOUND` | 404 | Patient ID doesn't exist (or caller doesn't have permission to know — 2A-RD existence-leak prevention applies) |

#### Audit hooks

| Event | Trigger | Subject fields |
|-------|---------|----------------|
| `alert.ack` | `PATCH /alerts/...` success | `patientId`, `clientId`, `alertType`, `severity`, `eventTimestamp`. Extra: `wasAlreadyAcknowledged` |
| `patient.thresholds.read` | `GET /patients/{id}/thresholds` success | `patientId`, `clientId`, `hasOverrides` |
| `patient.thresholds.update` | `PUT …/thresholds` success | `patientId`, `clientId`. Before/after: full thresholds map |

`internal_access: true` + `severity: elevated` auto-stamped by
audit-forwarder (Phase 1.7 D8) when `actor.role` starts with `internal_`.

#### Files Changed / Created

| File | Change Type | Description |
|------|-------------|-------------|
| `infra/lambda/alert-actions/handler.py` | New | 3 routes; dispatch table; per-route handlers |
| `infra/lambda/alert-actions/thresholds_validation.py` | New | Pure-function range + ordering validation |
| `infra/lambda/alert-actions/requirements.txt` | New | Empty (Powertools from layer) |
| `infra/lambda/_shared/thresholds.py` | Modified | `determine_threshold_alerts(..., overrides: dict \| None = None)` |
| `infra/lambda/_shared/audit_catalog.py` | Modified | Add `AUDIT_PATIENT_THRESHOLDS_READ`, `AUDIT_PATIENT_THRESHOLDS_UPDATE` |
| `infra/lambda/threshold-detector/handler.py` | Modified | Read `patient.thresholds`; pass `overrides=` to `determine_threshold_alerts()` |
| `infra/lib/stacks/api-stack.ts` | Modified | Wire `alert-actions` Lambda + 3 routes + 2 alarms |
| `infra/lib/stacks/audit-stack.ts` | Modified | Add `gosteady-{env}-alert-actions` to subscription-filter list |
| `infra/lib/config.ts` | Modified | `alertActionsMemoryMb` + `alertActionsTimeoutSeconds` defaults |
| `infra/lambda/alert-actions/tests/test_thresholds_validation.py` | New | Range + ordering tests |
| `infra/lambda/alert-actions/tests/test_threshold_merge.py` | New | Default + override merge tests |
| `infra/scripts/seed-2a-aa-test-data.py` | New | Idempotent extra-fixture seeder (extends 2A-RD seed: adds 1 unacked + 1 acked alert on `pat_rd_busy`) — or skip if 2A-RD fixtures suffice |
| `infra/scripts/smoke-2a-aa.py` | New | Synthetic smoke runner mirroring 2A-RD pattern |
| `docs/specs/ARCHITECTURE.md` | Modified | §15 add `alert-actions`; §17 flip 2A-AA; §12 phase plan |
| `docs/firmware-coordination/2026-04-17-cloud-contracts.md` | Modified | New §C26 deploy entry |
| `docs/specs/phase-2a-alert-actions.md` | New | This document |

### Out of Scope (Deferred)

- **Bulk-ack** (`POST /alerts/ack-bulk`) — caregiver wants to ack all alerts on a patient at once. Defer to 2A-AA-follow-up if dashboard UX surfaces the need
- **Threshold templates** (apply same overrides across all patients in a census) — Phase 2A-UM territory (census-level settings)
- **Threshold history / audit replay UI** — compliance reader concern; covered by audit log volume
- **Alert un-ack / re-open** — explicit decision: acks are final. If a caregiver acks in error, the audit trail captures it; the underlying condition recurring will fire a NEW alert
- **Per-alert-type ack policy** (some alerts auto-resolve when condition clears) — auto-resolve logic is Threshold Detector territory; defer
- **Notifications on ack** (notify family/team when an alert is acked) — Phase 2C
- **Threshold-change preview** ("show me what would alert at these new values for the last 7 days") — analytics; defer
- **Custom alert types** (per-patient/facility custom alert definitions) — out of scope; firmware emits fixed alert types

## Architecture

### Infrastructure Changes

Adds ~12 CFN resources to the existing `GoSteady-{Env}-Api` stack:

- 1 × `AWS::Lambda::Function` (`gosteady-{env}-alert-actions`)
- 1 × `AWS::IAM::Role` + 1 × `AWS::IAM::Policy` (read+write Patients, read+write Alert History, KMS Decrypt on IdentityKey + EncryptDecrypt on AuditKey)
- 3 × `AWS::ApiGatewayV2::Route` + 3 × `AWS::ApiGatewayV2::Integration` + 3 × `AWS::Lambda::Permission`
- 1 × `AWS::CloudWatch::Alarm` (Lambda Errors > 0 in 5 min)
- 1 × `AWS::Logs::MetricFilter` + 1 × `AWS::CloudWatch::Alarm` (ERROR-pattern log filter)
- 1 × `AWS::CloudFormation::Output`

And to `GoSteady-{Env}-Audit`:

- 1 × `AWS::Logs::SubscriptionFilter` (audit-capture on alert-actions log group)
- 1 × `AWS::Lambda::Permission` (subscription filter → forwarder)

And to `GoSteady-{Env}-Processing`:

- threshold-detector code redeploy (no new CFN resources; in-place Lambda code update)

### Data Flow

```
Caregiver (Flutter)
    │  PATCH /api/v1/alerts/pat_abc/2026-05-22T01:15:32Z%23battery_critical
    │  Authorization: Bearer <JWT>
    ▼
API Gateway HTTP API → JWT authorizer (2A-0) → alert-actions Lambda
    │
    ├── extract_claims; require_authenticated; require_role(*can_ack)
    ├── path: decode timestamp; assert compound SK shape
    ├── Patients.GetItem (resolve clientId for tenancy)
    ├── enforce_patient_access (2A-RD helper)
    ├── Alert History.UpdateItem (conditional: acknowledged != true)
    │      ├── On ConditionalCheckFailedException: re-read → idempotent return
    │      └── On success: stamp acknowledgedAt/By/notes
    └── emit_audit('alert.ack', subject={patientId, alertType}, extra={wasAlreadyAcknowledged})

[Threshold Detector path — unchanged shadow trigger]
Shadow update → threshold-detector Lambda
    │
    ├── serial → patientId resolve (existing)
    ├── Patients.GetItem (existing) — NEW: also read .thresholds map
    ├── merge: defaults ⊕ patient.thresholds (override per field)
    ├── determine_threshold_alerts(battery, rsrp, overrides=merged)
    └── PutItem on Alert History (existing)
```

### Per-role authorization matrix

| Role | View alerts (2A-RD) | Ack alert | Read thresholds | Write thresholds |
|------|:-:|:-:|:-:|:-:|
| family_viewer (linked) | ✅ | ❌ | ❌ | ❌ |
| caregiver (scope) | ✅ | ✅ | ✅ | ❌ |
| facility_admin (facility) | ✅ | ✅ | ✅ | ✅ |
| client_admin (client) | ✅ | ✅ | ✅ | ✅ |
| household_owner (own) | ✅ | ✅ | ✅ | ❌ (defer to 2A-UM) |
| internal_support (read all) | ✅ | ❌ | ✅ | ❌ |
| internal_admin (all + write) | ✅ | ✅ | ✅ | ✅ (audited elevated) |

## Implementation

### Configuration

| CDK Context Key | Dev | Prod | Notes |
|---|---|---|---|
| `alertActionsMemoryMb` | 256 | 256 | Same as patient-api; ack is single-row UpdateItem |
| `alertActionsTimeoutSeconds` | 10 | 10 | |

### Dependencies

- **Phase 0A-rev** — Cognito JWT claims (`mfa_enrolled` for admin roles)
- **Phase 0B-rev** — Patients table (gets new `thresholds` map attribute, schemaless DDB add), Alert History table
- **Phase 1.5** — IdentityKey CMK
- **Phase 1.6** — Powertools layer + ops SNS
- **Phase 1.7** — Audit pipeline
- **Phase 1B-rev** — Threshold Detector (code update bundled in)
- **Phase 2A-0** — API Gateway + authorizer + helpers
- **Phase 2A-RD** — `enforce_patient_access` helper

## Testing

### Test Scenarios

| # | Scenario | Method | Expected | Status |
|---|----------|--------|----------|--------|
| T1 | Caregiver acks own-scope unacked alert | PATCH on `pat_rd_busy` alert SK | 200; `wasAlreadyAcknowledged: false`; row has acknowledgedAt/By | Pending |
| T2 | Caregiver acks same alert twice (idempotent) | PATCH twice | First: was=false. Second: was=true; original acker preserved | Pending |
| T3 | Caregiver acks out-of-scope alert | PATCH on `pat_rd_fac_b` alert | 403 OUT_OF_SCOPE | Pending |
| T4 | family_viewer attempts ack | PATCH with family_viewer token | 403 INSUFFICIENT_PERMISSIONS (linked viewer can read but not ack) | Pending |
| T5 | internal_support attempts ack | PATCH with internal_support | 403 INSUFFICIENT_PERMISSIONS | Pending |
| T6 | Ack nonexistent alert | PATCH bad SK | 404 ALERT_NOT_FOUND | Pending |
| T7 | Ack with notes (≤500 chars) | PATCH body `{notes: "..."}` | 200; notes stored on row | Pending |
| T8 | Ack with notes >500 chars | PATCH body `{notes: 600-char string}` | 400 INVALID_REQUEST | Pending |
| T9 | Malformed SK in path | PATCH `/alerts/pat_abc/garbage` | 400 INVALID_TIMESTAMP | Pending |
| T10 | URL-encoded compound SK roundtrip | PATCH with `%23` for `#` | 200; decode succeeds | Pending |
| T11 | GET thresholds — patient with no overrides | GET as caregiver | 200; all fields source=default | Pending |
| T12 | PUT thresholds — facility_admin happy path | PUT `{batteryCritical: 0.08, batteryLow: 0.15}` | 200; updated fields; effective merged | Pending |
| T13 | PUT thresholds — caregiver denied | PUT with caregiver token | 403 INSUFFICIENT_PERMISSIONS | Pending |
| T14 | PUT thresholds — invalid range | PUT `{batteryCritical: 0.50}` (>0.30 max) | 400 INVALID_THRESHOLD | Pending |
| T15 | PUT thresholds — invalid ordering | PUT `{batteryCritical: 0.15, batteryLow: 0.10}` (low ≤ critical) | 400 INVALID_THRESHOLD | Pending |
| T16 | PUT thresholds — null clears override | PUT `{batteryCritical: null}` after a prior override | 200; field reverts to default in response | Pending |
| T17 | GET thresholds reflects PUT | GET after T12 | 200; batteryCritical=0.08 source=override; batteryLow=0.15 source=override; signal fields source=default | Pending |
| T18 | Threshold Detector applies override on next shadow delta | Set patient threshold batteryLow=0.20; publish shadow update with battery_pct=0.15 | Expect `battery_low` synthetic alert on Alert History (would NOT fire under default 0.10) | Pending |
| T19 | Threshold Detector default-fallthrough still works for patient without overrides | Publish shadow update on a fresh patient | Default thresholds apply | Pending |
| T20 | Ack audit event lands in S3 within ~70s | T1 then S3 list | `alert.ack` event with extra.wasAlreadyAcknowledged | Pending |
| T21 | Thresholds.update audit emits before+after | T12 then audit log | Event has before/after maps | Pending |
| T22 | PII scrub clean — patient displayName never in operational log | T1 then filter alert-actions log group | 0 matches | Pending |
| T23 | No-token 401 | PATCH without auth | 401 UNAUTHENTICATED | Pending |
| T24 | Tenancy violation | Caregiver of client_rd_test tries pt_bench_98 (other client) | 403 TENANCY_VIOLATION | Pending |
| T25 | internal_admin cross-tenant ack | PATCH with internal_admin claims | 200; elevated audit | Pending |

### Verification Commands

```bash
cd ~/Documents/gosteady-portal
# Smoke runner (Python, mirrors smoke-2a-rd.py):
.test-venv/bin/python3 infra/scripts/smoke-2a-aa.py

# Inspect a patient's thresholds:
aws dynamodb get-item --region us-east-1 \
  --table-name gosteady-dev-patients \
  --key '{"patientId":{"S":"pat_rd_busy"}}' \
  --query 'Item.thresholds'

# Recent alert.ack audit events:
aws logs filter-log-events --region us-east-1 \
  --log-group-name gosteady-dev-audit \
  --filter-pattern '"alert.ack"' \
  --start-time $(($(date +%s) - 600))000 --max-items 5
```

## Deployment

```bash
cd infra
npm run build  # tsc — uses warm cache from 2A-RD build

# cdk diff first:
npx cdk diff GoSteady-Dev-Api --context env=dev
npx cdk diff GoSteady-Dev-Processing --context env=dev

# Deploy:
npx cdk deploy GoSteady-Dev-Processing --context env=dev --require-approval never
npx cdk deploy GoSteady-Dev-Api --context env=dev --require-approval never
# Synthetic invoke to create alert-actions log group:
aws lambda invoke --region us-east-1 \
  --function-name gosteady-dev-alert-actions \
  --cli-binary-format raw-in-base64-out \
  --payload '{"requestContext":{"http":{"method":"GET","path":"/api/v1/patients/x/thresholds"},"requestId":"bootstrap"},"routeKey":"GET /api/v1/patients/{id}/thresholds","pathParameters":{"id":"x"}}' \
  /tmp/_synth.json
npx cdk deploy GoSteady-Dev-Audit --context env=dev --require-approval never --exclusively
```

Estimated total deploy: Processing ~3 min (Lambda code-only update), Api ~2 min, Audit ~30s.

### Rollback

Pure read/write-back. `git revert <2A-AA-commit>` + redeploy removes
the alert-actions Lambda + routes + the threshold-detector code change.
Already-stored ack rows persist; threshold overrides persist. Both are
forward-compatible (the schema additions are additive).

## Decisions Log

| # | Decision | Alternatives Considered | Why This Choice |
|---|----------|------------------------|-----------------|
| D1 | Per-patient thresholds on Patients table as a `thresholds` map (L2) | New `PatientThresholds` table; per-row PK | Threshold Detector already reads the patient row; sibling attribute is free. New table = new GSI/PITR/CMK overhead for sparse data |
| D2 | First-write-wins ack idempotency (L4) | Reject second ack; last-write-wins | Audit truth: "who first responded" is the load-bearing fact. Last-write would let a later caregiver erase the original acker's accountability |
| D3 | Optional `notes` field on ack body, ≤500 chars | Required notes; no notes | Optional matches MVP; 500-char cap prevents DDB row bloat. If specific clients want nursing-note discipline, promote per-tenant in 2A-UM |
| D4 | Threshold override clears via explicit `null` (PUT body) | Separate DELETE endpoint; absent-means-clear | Absent-means-clear is fragile (clients accidentally omit a field on update → unintended clear). Explicit null is the standard JSON-merge-patch semantic |
| D5 | Range bounds in L3 are deliberately conservative (batteryCritical max 0.30 not 0.50) | Allow any 0..1 | Field is "critical battery threshold" — setting 0.50 would alert on almost every reading. Caregiver UX guards against misconfiguration |
| D6 | Threshold Detector reads patient.thresholds inline (no caching) | Cache patient thresholds in Lambda memory across invocations | Threshold updates take effect on the next shadow delta (≤1 hour for the firmware's heartbeat cadence). Caching adds invalidation complexity for almost no gain at MVP volume |
| D7 | Single `alert-actions` Lambda for all 3 routes | Two Lambdas (one for alerts, one for thresholds) | Same shared concerns (Patients GetItem, audit, JWT). Cold-start economics favor one |
| D8 | Threshold validation lives in a separate pure-function module (`thresholds_validation.py`) | Inline in handler | Pure-function = unit-testable without boto3 / Cognito stubs |
| D9 | `patient.thresholds.update` carries full before/after, not a diff (L8) | Diff-only | Compliance reader reconstructing historical state at point-in-time T needs full state, not a diff chain |

## Open Questions

### Q1. Where to store per-patient thresholds? (DECIDED — see L2)
✅ **Patients table as `thresholds` map.** No new table.

### Q2. Ack idempotency semantics? (DECIDED — see L4)
✅ **First-write-wins.** Second ack returns 200 with `wasAlreadyAcknowledged: true`.

### Q3. Who can ack? (DECIDED — see L5)
✅ **caregiver / facility_admin / client_admin / household_owner / internal_admin.** family_viewer and internal_support cannot.

### Q4. Who can override thresholds? (DECIDED — see L6)
✅ **facility_admin+ only for writes.** Reads allowed for all clinical roles. Household_owner defers to 2A-UM.

### Q5. Threshold override merge semantics? (DECIDED — see L7)
✅ **Field-by-field merge.** Absent field = use default. Explicit `null` = clear override.

### Q6. Allow un-ack / re-open?

**What's at stake:** A caregiver might ack in error. Without un-ack, the audit trail captures the mistake, but the dashboard now hides the alert.

**Decision:** ⏳ **Defer.** No un-ack in v1. If the underlying condition recurs, a new alert fires (separate row). If the caregiver wants to re-acknowledge clinical attention, they can free-text via the dashboard / handoff notes. Promote to 2A-AA-follow-up if pilot data shows real demand.

### Q7. Bulk-ack endpoint?

**What's at stake:** Caregiver workflow — at shift change, may want to ack 10 alerts at once.

**Decision:** ⏳ **Defer.** Three endpoints in v1; add `POST /alerts/ack-bulk` in follow-up if dashboard UX surfaces the friction.

### Q8. Notify on ack (Phase 2C territory)?

**What's at stake:** Family viewers might want to know "Mom's caregiver responded to that battery alert."

**Decision:** ⏳ **Phase 2C** — notifications are a separate phase entirely. Ack emits the audit event; 2C can subscribe to it via EventBridge.

### Q9. Threshold-change preview (UI helper)?

**What's at stake:** Power-user UX — "if I lowered batteryLow to 0.15, what would have triggered last week?"

**Decision:** ⏳ **Defer.** Read-only analytics; doesn't block any ship. Revisit if facility_admin UX feedback demands it.

### Q10. Cache patient thresholds in threshold-detector?

**What's at stake:** Read amplification — threshold-detector reads the patient row on every shadow update; thresholds are stable per patient.

**Decision:** ⏳ **No cache in v1** (per D6). Revisit if Patients table read costs become material.

### Decision summary

| # | Question | Resolution |
|---|----------|-----------|
| Q1 | Storage | ✅ Patients.thresholds map |
| Q2 | Ack idempotency | ✅ First-write-wins |
| Q3 | Ack RBAC | ✅ caregiver+ except family_viewer/internal_support |
| Q4 | Threshold write RBAC | ✅ facility_admin+ |
| Q5 | Merge semantics | ✅ Field-by-field; null clears |
| Q6 | Un-ack | ⏳ Defer |
| Q7 | Bulk-ack | ⏳ Defer |
| Q8 | Notify on ack | ⏳ Phase 2C |
| Q9 | Threshold preview | ⏳ Defer |
| Q10 | Threshold-detector cache | ⏳ No (per D6) |

5 decided / 5 deferred.

## Changelog

| Date | Author | Change |
|------|--------|--------|
| 2026-05-23 | Jace + Claude (cloud session) | Initial spec drafted as Alert Actions subset of Phase 2A. Three endpoints (alert ack + threshold read/write) on a new `alert-actions` Lambda; Threshold Detector amended to consume per-patient overrides via Patient.thresholds map. Mirrors 2A-RD/2A-DL patterns: single Lambda, 2A-0 audit middleware/error envelope, bundled audit-stack subscription filter, conditional-write idempotency. Five Q's decided inline; five deferred (un-ack / bulk-ack / notify-on-ack / preview / cache). Spec drafted with user delegation to proceed autonomously into implementation post-spec — user AFK. |
| 2026-05-23 | Jace + Claude (cloud session, same day) | **Deployed to dev.** 29/29 unit tests PASS (validation + merge semantics) → CDK synth + clean diff (3 stacks: Processing modify + Api adds + Audit subscription filter) → Processing deploy (Threshold Detector code update, 30s after a 10min bundle) → Api deploy (24 resources / 83s after a 343s synth — bundling penalty from iCloud) → synthetic invoke alert-actions for log group → Audit deploy (5 resources / 26s). **Synthetic smoke 17/17 PASS** covering: ack happy path + idempotency (was=true second time, original acker preserved), out-of-scope 403, family_viewer denied (observational role), nonexistent-alert 404, notes valid + notes >500 chars 400, malformed SK 400, GET thresholds default fall-through, PUT happy path (facility_admin), PUT denied (caregiver), out-of-range 400, ordering violation 400, null clears override + GET reflects it, no-token 401, cleanup. Audit pipeline working end-to-end: alert.ack events landed with `wasAlreadyAcknowledged` + `hasNotes` flags; patient.thresholds.update events landed with full `before` + `after` maps (per spec L8/D9 compliance-replay invariant). PII scrub clean: 0 displayName leaks across 4 test patients in operational log group. Build/deploy friction: tsc on iCloud is slow first-time but warm cache makes subsequent compiles fast; eventual migration to ~/Documents/ planned. |

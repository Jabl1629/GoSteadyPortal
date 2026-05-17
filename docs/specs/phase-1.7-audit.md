# Phase 1.7 — Audit Logging Infrastructure

## Overview
- **Phase**: 1.7
- **Status**: ✅ Deployed (dev) 2026-05-17
- **Branch**: feature/infra-scaffold (matched existing project pattern; spec field aspirational)
- **Date Started**: 2026-05-17
- **Date Completed**: 2026-05-17 (dev deploy; prod cutover deferred until first-prod-customer threshold per D12)

Deploys the application-level audit log destination: a dedicated `gosteady-{env}-audit` CloudWatch Log Group (CMK-encrypted with the existing AuditKey from Phase 1.5), plus a Kinesis Firehose → S3 path that lands every audit event in a partition-keyed bucket with Object Lock compliance retention (prod) or normal SSE-KMS (dev). Ships a Powertools-based audit emission helper (`_shared/audit.py`) for Phase 2A handlers to call, and a consolidated event catalog spanning the device-lifecycle events from [`ARCHITECTURE.md` §4](ARCHITECTURE.md) and the Phase 1B-rev audit-shape log entries already flowing from the four processing handlers. Routes those existing 1B-rev entries via subscription filter — zero handler code changes in this phase.

Closes the AU1–AU4 compliance commitments ([`ARCHITECTURE.md` §14](ARCHITECTURE.md)) before Phase 2A exposes patient data through a portal UI. As [§12 of ARCHITECTURE.md](ARCHITECTURE.md) currently overstates the dependency, this is a *discipline* gate rather than a hard technical one: 1.7 can ship before, alongside, or shortly after 2A's first dev iteration, but it must be in place before the first prod customer's data touches the portal.

## Locked-In Requirements

| # | Requirement | Decided In | Rationale |
|---|-------------|-----------|-----------|
| L1 | Stack name: `GoSteady-{Env}-Audit` | ARCHITECTURE.md §5 CDK Stack Map | Already reserved in the stack map; deploys after Auth + Data, before Api. |
| L2 | Application-level audit log on all reads/writes of patient-identifying data | AU1 (Phase 1.5) | Compliance baseline — every who/what/when on patient data must be auditable. Phase 1B-rev already emits write events; Phase 2A wires read events into its handlers. |
| L3 | Audit S3 retention: 6 years via Object Lock compliance mode (prod) | AU2 / L4 (Phase 1.5) | Standard healthcare-adjacent compliance retention. Object Lock compliance mode prevents deletion even by root. |
| L4 | No PII in operational logs | AU3 (Phase 1.6, already enforced) | Powertools logger's PII scrubber strips `displayName`/`dateOfBirth`/`email` from regular handler logs. Audit logs (this phase) explicitly contain identifiers (`patientId`, `userId`) — that's the whole point. PII scrubber must be skipped on audit-helper output. |
| L5 | Object Lock is **prod-only**; dev gets normal SSE-KMS bucket | Phase 1.5 CloudTrail precedent ([ARCHITECTURE.md:1151](ARCHITECTURE.md)) | Object Lock is irreversible at the bucket level. Dev must remain cleanable. Confirmed Q3 lean during spec discussion 2026-05-17. |
| L6 | AuditKey CMK from Phase 1.5 encrypts both the audit CloudWatch Log Group and the S3 bucket | Phase 1.5 (already deployed) | Single-key encryption surface for everything tagged audit; crypto-shred path is one key. AuditKey ARN is exported by `GoSteady-{Env}-Security`. |
| L7 | Audit emission is asynchronous / fire-and-forget from the handler's perspective | Q2 decision 2026-05-17 | Phase 2A's API response budget cannot absorb a synchronous S3 round-trip per mutation. CW Logs `PutLogEvents` (or `print()` for Lambda-captured stdout) is best-effort but durable at the CW Logs SLA. S3 lag of seconds-to-minutes is fine for compliance forensics. |
| L8 | Internal-user access (`internal_*` role) is tagged at elevated severity in every audit event | ARCHITECTURE.md §4 Internal Access constraints | Customer-facing audit reports (future) must surface when GoSteady support touched a customer's data. Helper auto-detects role prefix and stamps `internal_access: true` + `severity: elevated` so this isn't a per-handler discipline. |
| L9 | Audit event JSON schema versioned via `schema_version` field on every event | Spec discussion 2026-05-17 (mirrors snippet binary `format_version` pattern) | Six-year retention means we may need to read events written by handlers two major revisions ago. Field is cheap; absence in v1 events is unambiguous (defaults to 1). |
| L10 | Existing 1B-rev structured audit-shape log entries are routed to the audit destination via subscription filter — zero handler code changes in this phase | Q1 + Q3 decisions 2026-05-17 | 1B-rev handlers already emit `event: "patient.activity.create"` / `alert.synthetic.create` / `alert.device.create` / `device.activated` / `device.preactivation_heartbeat` log lines with `audit: true` shape. Tag verification is a pre-deploy gate (see A3). |

## Assumptions

| # | Assumption | Risk if Wrong | Validation Plan |
|---|-----------|---------------|-----------------|
| A1 | A CloudWatch Logs subscription filter using the `{ $.audit = true }` JSON pattern reliably matches the existing 1B-rev structured log lines | Pattern misses real audit events; audit log gaps; compliance hole | Verify before deploy: `aws logs filter-log-events --log-group-name /aws/lambda/gosteady-dev-activity-processor --filter-pattern '{ $.audit = true }'` should return existing entries. If it doesn't, pre-deploy fix is a small touch to `_shared/observability.py` (1B-rev) to ensure the key is consistently `audit:true` boolean (not `"audit":"true"` string). |
| A2 | A single Lambda forwarder writing to the dedicated audit log group via `logs:PutLogEvents` is sufficient to keep up with audit volume (estimated <100 events/min in v1; ~10k events/day at MVP scale) | Forwarder backpressure or PutLogEvents throttling drops events | At MVP volume, this is far below CW Logs throttle limits (5MB/s per log stream). Reserved concurrency = 5 on the forwarder is enough headroom. Revisit if any single handler emits sustained >50 audit events/sec (would require batching). |
| A3 | 1B-rev handler audit-shape log lines already include `"audit": true` as a top-level JSON key (or equivalent that a subscription filter can match) | Subscription filter misses everything; need to retrofit handlers anyway | **Pre-deploy verification step**: grep `infra/lambda/_shared/observability.py` for the audit emission helper that 1B-rev uses. If the key isn't `audit:true`, either (a) make the subscription filter pattern match whatever IS there, or (b) add a one-line touch to the helper. Either is small. Reflected as T1 in test scenarios. |
| A4 | CloudWatch Logs subscription filter → Lambda → CW Logs PutLogEvents → second subscription filter → Firehose → S3 introduces acceptable end-to-end audit-lag for compliance reads (target: <5 min p99) | Compliance reader sees stale data during incident triage | Each hop adds seconds. Subscription filter delivery is typically <1s. Lambda invocation + PutLogEvents <500ms. Firehose batch is the dominant lag (60s buffer interval or 1MB size — whichever first). Total p99 ~3-4 min. Acceptable for compliance; not acceptable for real-time alerting (out of scope here). |
| A5 | AWS-managed Kinesis Data Firehose can deliver to an S3 bucket with Object Lock enabled | Firehose can't write to Object-Lock-enabled prod bucket; need alternative ingestion | AWS docs confirm Firehose + Object Lock is supported. Object Lock applies retention at object level on each PutObject; Firehose's PutObject calls work normally. **Verify in prod cutover, not dev** (since dev doesn't have Object Lock). |
| A6 | Six-year Object Lock compliance retention is the right legal baseline (mirrors HIPAA-adjacent norms) | Customer/legal requires longer (10yr+) or shorter; bucket-level config has to change | L4 in ARCHITECTURE.md §11 already locks this at 6 years. Spec assumes that holds. If a future customer contract requires longer, Object Lock allows extending retention on objects already written (just not shortening). New bucket with new retention for new objects is an option. |
| A7 | `gosteady-{env}-audit-reader` IAM role created with empty trust policy is acceptable as a stub | Role exists but is unusable; risk of forgetting to attach a trust policy when compliance team is named | Documented as a runbook gap in the spec + post-deploy verification. Acceptable for v1 since no compliance reader exists yet. |
| A8 | The Powertools audit helper API (`emit_audit(event, actor, subject, action, before, after)`) is symmetric for read and write events — Phase 2A's read-event emission can use the same call shape | API breaks when 2A tries to use it; refactor needed | Read events are simpler than writes (no `before`/`after` pair). Helper accepts `action: "read"` with `before=None, after=None`. Same shape, different field population. |

## Scope

### In Scope

**Audit stack** (`GoSteady-{Env}-Audit`):

- **Dedicated CloudWatch Log Group** — `gosteady-{env}-audit`
  - Encryption: AuditKey CMK (cross-stack import from `GoSteady-{Env}-Security`)
  - Retention: 90 days (hot path; cold path is S3)
  - Restrictive resource policy: only the audit forwarder Lambda can write; only the `audit-reader` IAM role can read

- **Audit forwarder Lambda** — `gosteady-{env}-audit-forwarder`
  - Trigger: CloudWatch Logs subscription filter on each handler's existing log group (pattern: `{ $.audit = true }`)
  - Action: Decode the subscription filter event (gzipped CW Logs payload), extract each audit-shape JSON line, re-emit via `logs:PutLogEvents` to `gosteady-{env}-audit`
  - **Destination log stream name partitioned by UTC date:** `audit-{YYYY-MM-DD}`. Forwarder computes the date from the event's `timestamp` field (falling back to wall-clock if absent), creates the stream lazily via `logs:CreateLogStream` on first write per day, and writes via `logs:PutLogEvents`. Rationale: PutLogEvents has a 5 MB/s per-stream throughput cap; partitioning by date keeps any one stream's load proportional to that day's audit volume, never accumulating across days. Cheap insurance against the volume rampup Q1 flags.
  - Stamps `internal_access: true` and `severity: elevated` if `actor.role` starts with `internal_` (defense in depth; 1B-rev handlers don't currently emit on internal access since there's no internal-write path yet, but future 2A internal reads will hit this codepath)
  - Python 3.12 ARM64, 256 MB, Powertools layer (consumed from Phase 1.6's published ARN), reserved concurrency = 5
  - IAM: `logs:PutLogEvents` + `logs:CreateLogStream` + `logs:DescribeLogStreams` on `gosteady-{env}-audit` only; `kms:GenerateDataKey` + `kms:Decrypt` on AuditKey

- **Kinesis Data Firehose delivery stream** — `gosteady-{env}-audit-to-s3`
  - Source: subscription filter on `gosteady-{env}-audit` log group
  - Destination: `gosteady-{env}-audit-logs` S3 bucket
  - Buffer: 1 MB or 60 s (whichever first)
  - Compression: GZIP
  - Format: newline-delimited JSON (Firehose's native CW-Logs-source unwrapping turns each log event into one JSON line in the output)
  - S3 prefix: `audit/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/`
  - Error prefix: `firehose-errors/!{firehose:error-output-type}/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/`
  - Encryption: AuditKey CMK on the delivery stream and on the S3 destination

- **S3 bucket** — `gosteady-{env}-audit-logs`
  - **dev:** SSE-KMS with AuditKey; bucket-key enabled; TLS-only enforced; all public access blocked; lifecycle rules: Standard → Glacier Instant Retrieval @ 90d; no Object Lock (cleanable for test data churn)
  - **prod:** All the above PLUS Object Lock compliance mode, default retention 6 years, bucket policy denying `s3:DeleteObject` even to root, lifecycle rules to Glacier Instant Retrieval at 90d (Object Lock is compatible with storage class transitions)

- **Compliance reader IAM role** — `gosteady-{env}-audit-reader`
  - Trust policy: **empty** (runbook step to attach when reader identity is known)
  - Permissions: `logs:FilterLogEvents`, `logs:GetLogEvents`, `logs:StartQuery`, `logs:GetQueryResults`, `logs:DescribeLogStreams` on `gosteady-{env}-audit`; `s3:GetObject`, `s3:ListBucket` on `gosteady-{env}-audit-logs`; `kms:Decrypt` on AuditKey
  - Documented runbook step: `aws iam update-assume-role-policy --role-name gosteady-{env}-audit-reader --policy-document file://trust-policy.json` once compliance team is identified

- **Audit emission helper** — `infra/lambda/_shared/audit.py`
  - Public function: `emit_audit(event: str, actor: dict, subject: dict, action: str, before: dict | None = None, after: dict | None = None, request_id: str | None = None) -> None`
  - Internally calls Powertools Logger with `extra={"audit": True, "schema_version": 1, ...}` so the line lands in the handler's regular log group, where the subscription filter picks it up
  - Auto-stamps `internal_access: true` + `severity: elevated` if `actor.get("role", "").startswith("internal_")`
  - **Bypasses the PII scrubber** — audit lines must retain identifiers
  - Available to Phase 2A handlers (and any future write-path Lambda) via bundled `_shared/` import path
  - No-op if called with `event` not in the catalog (see Event Catalog below) — logs a warning, doesn't raise; helps catch typos without breaking the host handler

- **Event catalog documentation** — see "Event Catalog" section below
- **Subscription filter** on each of the 6 existing handler log groups, plus reserved patterns for the 4 planned Phase 2A handlers (filter resource is small; pre-creating saves redeploy on each 2A handler add)
- **CloudWatch alarms** for audit pipeline health:
  - `gosteady-{env}-audit-forwarder-errors`: Lambda Errors > 0 in 5 min
  - `gosteady-{env}-audit-firehose-delivery-failures`: Firehose `DeliveryToS3.Failures` > 0
  - `gosteady-{env}-audit-firehose-throttled`: Firehose `ThrottledRecords` > 0
  - All route to the existing ops SNS topic (`gosteady-{env}-cost-alarms`, repurposed by Phase 1.6)

### Out of Scope (Deferred)

- **Phase 2A read-event emission** — 1.7 ships the helper + schema + catalog. 2A wires `patient.activity.read`, `patient.detail.read`, `alert.read`, etc. into its API handlers using the helper. Per Q4 decision 2026-05-17.
- **Compliance reader's actual identity** — the IAM role exists; trust policy is empty. Attaching a real principal (federated IdP, IAM user, etc.) is a runbook step gated by knowing who the compliance role belongs to.
- **Athena workgroup + Glue table** for SQL queries over the S3 audit data — Phase 1.7.1 or whenever a real compliance read query appears. Pre-MVP, Logs Insights on the hot CW path is sufficient for any practical query against 90 days of data.
- **Real-time audit alerting** (e.g., "any `internal_admin` write to a customer's data fires a Slack ping") — Phase 1.7.1 or 2A. The pipeline emits the event; alerting on top is independent.
- **Tamper detection beyond Object Lock** — hash-chained events, cryptographic signing, blockchain-style append-only. Object Lock compliance mode is industry-standard for healthcare-adjacent audit; cryptographic chaining is a step beyond the v1 compliance baseline.
- **Cross-region replication** of the audit bucket — single-region for v1; CRR is a prod-only hardening for later.
- **Audit-as-event-source-of-truth** for any business logic — audit is purely read-only forensics. No handler should depend on reading audit data for its own correctness.
- **Phase 1B handler refactor** — 1.7 routes existing 1B-rev audit-shape lines as-is. Any refactor of those handlers (e.g., to also use the new `emit_audit` helper for consistency with 2A) is opportunistic, not gated on this phase.
- **Customer-facing audit report UI** — the spec leaves a hook in the catalog and schema (`internal_access: true` tag), but the actual customer-visible "GoSteady support viewed your data on Tuesday at 3pm" surface is Phase 2B+ portal scope.

## Architecture

### Infrastructure Changes

**New stack:** `GoSteady-{Env}-Audit` (~14 resources):
- 1 × `AWS::Logs::LogGroup` (`gosteady-{env}-audit`, CMK-encrypted, 90d retention)
- 1 × `AWS::Lambda::Function` (`gosteady-{env}-audit-forwarder`)
- 1 × `AWS::IAM::Role` + 2 × `AWS::IAM::Policy` (forwarder execution role)
- 1 × `AWS::IAM::Role` (`gosteady-{env}-audit-reader`, empty trust)
- 6 × `AWS::Logs::SubscriptionFilter` (one per handler log group, source side)
- 1 × `AWS::KinesisFirehose::DeliveryStream` (`gosteady-{env}-audit-to-s3`)
- 1 × `AWS::Logs::SubscriptionFilter` (audit log group → Firehose)
- 1 × `AWS::S3::Bucket` (`gosteady-{env}-audit-logs`, env-specific config)
- 1 × `AWS::S3::BucketPolicy` (TLS-only; prod: deny delete)
- 3 × `AWS::CloudWatch::Alarm` (forwarder errors, Firehose delivery failures, Firehose throttling)

**Modified stacks:** none. Subscription filters and resource-policy references are added to existing log groups but don't require touching the producer stacks (subscription filters are owned by the consumer side).

### Data Flow

```
                  ┌──────────────────────────────────────────────────┐
                  │ Existing handler Lambdas (1B-rev + 1A-rev + 0A-rev):
                  │ • activity-processor                             │
                  │ • heartbeat-processor                            │
                  │ • threshold-detector                             │
                  │ • alert-handler                                  │
                  │ • snippet-parser                                 │
                  │ • cognito-pre-token                              │
                  └────────────┬─────────────────────────────────────┘
                               │  Powertools Logger → STDOUT → CW Logs
                               │  Audit-shape lines tagged `audit:true`
                               │  (alongside regular operational logs)
                               ▼
                  ┌──────────────────────────────────────────────────┐
                  │ /aws/lambda/gosteady-{env}-{handler}              │
                  │ (6 existing log groups — operational + audit     │
                  │  lines intermixed)                                │
                  └────────────┬─────────────────────────────────────┘
                               │  Subscription filter:
                               │  pattern `{ $.audit = true }`
                               ▼
                  ┌──────────────────────────────────────────────────┐
                  │ gosteady-{env}-audit-forwarder Lambda            │
                  │ • Decodes gzipped CW Logs payload                │
                  │ • Stamps internal_access for internal_* roles    │
                  │ • PutLogEvents → audit log group                 │
                  └────────────┬─────────────────────────────────────┘
                               │
                               ▼
                  ┌──────────────────────────────────────────────────┐
                  │ gosteady-{env}-audit                              │
                  │ • CMK-encrypted with AuditKey                    │
                  │ • 90d retention (hot path)                       │
                  │ • Restrictive IAM (forwarder writes only;        │
                  │   audit-reader role reads only)                  │
                  └────────────┬─────────────────────────────────────┘
                               │  Subscription filter (full pattern;
                               │   everything in this log group is audit)
                               ▼
                  ┌──────────────────────────────────────────────────┐
                  │ gosteady-{env}-audit-to-s3 Firehose              │
                  │ • Buffer: 1 MB / 60 s                            │
                  │ • Compression: GZIP                              │
                  │ • Output: NDJSON                                 │
                  └────────────┬─────────────────────────────────────┘
                               │
                               ▼
                  ┌──────────────────────────────────────────────────┐
                  │ s3://gosteady-{env}-audit-logs/                  │
                  │   audit/year=YYYY/month=MM/day=DD/*.gz           │
                  │                                                   │
                  │ • CMK-encrypted with AuditKey                    │
                  │ • dev: no Object Lock                            │
                  │ • prod: Object Lock compliance mode, 6yr         │
                  │ • Lifecycle: Standard → Glacier IR @ 90d         │
                  └──────────────────────────────────────────────────┘

                       ┌──────────────────────────┐
                       │ gosteady-{env}-audit-     │
                       │ reader IAM role (empty   │
                       │ trust policy — runbook   │
                       │ step to attach principal)│
                       └──────────────────────────┘
                          │ reads via:
                          ├─ CW Logs Insights against gosteady-{env}-audit
                          └─ Athena (future Phase 1.7.1) against S3 bucket
```

### Interfaces

**Audit event JSON schema (v1):**

```json
{
  "schema_version": 1,
  "audit": true,
  "event": "patient.activity.create",
  "action": "create",
  "actor": {
    "userId": "abc-123",
    "role": "caregiver",
    "clientId": "client_005"
  },
  "subject": {
    "patientId": "pat_456",
    "clientId": "client_005",
    "facilityId": "fac_012",
    "censusId": "cen_044"
  },
  "before": null,
  "after": {
    "sessionEnd": "2026-05-17T14:18:00Z",
    "steps": 142,
    "distance_ft": 340.5
  },
  "request_id": "req_789",
  "timestamp": "2026-05-17T14:18:01.234Z",
  "internal_access": false,
  "severity": "info"
}
```

Required keys: `schema_version`, `audit`, `event`, `action`, `actor`, `subject`, `timestamp`.
Optional: `before`, `after`, `request_id`, `internal_access` (auto-stamped), `severity` (auto-stamped).

**`internal_access` and `severity` auto-stamping rule:**
- If `actor.role` starts with `internal_`: `internal_access = true`, `severity = "elevated"`
- Otherwise: `internal_access = false`, `severity = "info"` (or `"warning"` / `"critical"` if explicitly passed by the caller, e.g., for cross-tenant moves)

**Event catalog (v1, consolidating §4 and 1B-rev):**

| Event name | Action | Emitter | Phase | Notes |
|---|---|---|---|---|
| `device.created` | create | (manual; future 2A admin endpoint) | 2A | Manufacturer-side record creation |
| `device.claimed` | update | device-api (future) | 2A | First-provision ownership claim |
| `device.assigned` | create | device-api (future) | 2A | Patient assignment |
| `device.activation_sent` | create | device-api (future) | 2A | `activate` cmd published to `gs/{serial}/cmd` |
| `device.activated` | update | heartbeat-processor | 1B-rev ✅ | Heartbeat ack received |
| `device.preactivation_heartbeat` | read | threshold-detector | 1B-rev ✅ | Sampled 1/hr/serial |
| `device.first_heartbeat` | update | heartbeat-processor | future | Auto `provisioned → active_monitoring` |
| `device.assignment_ended` | update | device-api (future) | 2A | Includes `reason` |
| `device.reset_complete` | update | device-shadow-handler (future) | 2A | Firmware confirms reset |
| `device.force_reset` | update | device-api (future) | 2A | Admin override; audited heavily |
| `device.decommissioned` | update | device-api (future) | 2A | Includes `decommissionReason` |
| `device.recovered` | update | device-api (future) | 2A | Reactivation from `decommissioned (lost)` |
| `device.ownership_moved` | update | device-api (future) | 2A | Cross-facility or cross-client |
| `device.snippet_uploaded` | create | snippet-parser | 1A-rev ✅ | Per snippet |
| `patient.activity.create` | create | activity-processor | 1B-rev ✅ | Session-end write |
| `alert.synthetic.create` | create | threshold-detector | 1B-rev ✅ | Shadow-delta-triggered alert |
| `alert.device.create` | create | alert-handler | 1B-rev ✅ | Device-emitted alert (tipover/fall/impact) |
| `patient.activity.read` | read | api-handler (future) | 2A | Per query |
| `patient.detail.read` | read | api-handler (future) | 2A | Per patient detail fetch |
| `alert.read` | read | api-handler (future) | 2A | Per alert fetch |
| `alert.ack` | update | api-handler (future) | 2A | Includes `acknowledgedBy`, `acknowledgedAt` |
| `census.roster.read` | read | api-handler (future) | 2A | Bulk read of patients in a census |
| `auth.login` | create | cognito-pre-token | 0A-rev (partial) | Login event (existing log line; tag verification per A3) |
| `auth.login_failed` | create | cognito-pre-token | 0A-rev (partial) | Failed auth attempt |
| `auth.mfa_challenge` | create | cognito-pre-token | future | MFA enforcement event |
| `role.assigned` | create | api-handler (future) | 2A | Includes `assignedBy` |
| `role.revoked` | update | api-handler (future) | 2A | Role assignment ended |

Marked ✅ = already emitting in production today.

## Implementation

### Files Changed / Created

| File | Change Type | Description | Status |
|------|------------|-------------|--------|
| `infra/lib/stacks/audit-stack.ts` | New | The full Audit stack: log group, forwarder Lambda, 7 subscription filters (6 source + 1 audit→Firehose), Firehose delivery stream, S3 bucket, audit-reader IAM role (empty trust policy stub), 3 alarms | ✅ Implemented |
| `infra/lib/constructs/audit-s3-bucket.ts` | New | Env-aware S3 bucket construct — dev: SSE-KMS, RemovalPolicy DESTROY; prod: SSE-KMS + Object Lock compliance 6yr + deny-delete bucket policy + RemovalPolicy RETAIN | ✅ Implemented |
| `infra/lambda/audit-forwarder/handler.py` | New | Lambda: decode subscription-filter payload, stamp internal_access/severity, PutLogEvents to audit log group with date-partitioned destination streams (`audit-YYYY-MM-DD`) | ✅ Implemented |
| `infra/lambda/audit-forwarder/requirements.txt` | New | Empty (Powertools provided by layer; boto3 from runtime) | ✅ Implemented |
| `infra/lambda/_shared/observability.py` | Modified | Extended existing `emit_audit()` with `schema_version: 1` field + `request_id` parameter; fixed L4 bug where `ScrubbingFormatter` was scrubbing audit lines too (formatter now detects `audit: true` top-level key and skips scrubbing for those records). See "Architectural divergence" note below | ✅ Implemented |
| `infra/lambda/_shared/audit_catalog.py` | New | Python-importable event-name constants (28 events across device/patient/alert/auth/role namespaces); mirrors the catalog table above | ✅ Implemented |
| `infra/lib/config.ts` | Modified | Added `auditBucketObjectLockEnabled` (dev: `false`, prod: `true`), `auditBucketObjectLockYears` (`6`), `auditHotRetentionDays` (`90`) to `GoSteadyEnvConfig` | ✅ Implemented |
| `infra/bin/gosteady.ts` | Modified | Wire AuditStack into app with explicit dep on SecurityStack (for AuditKey CMK cross-stack import) | ✅ Implemented |
| `infra/test/{auth,data,ingestion,processing,security}-stack.test.ts` × 5 | Modified | Backfill the three new env-config fields into each test fixture (TypeScript would otherwise fail on `GoSteadyEnvConfig` shape mismatch) | ✅ Implemented |
| `infra/lib/stacks/security-stack.ts` | (verify only) | Confirmed AuditKey CMK exported as `{prefix}-AuditKeyArn` at security-stack.ts:213 since Phase 1.5; no edit needed | ✅ Verified |
| `infra/lib/constructs/audit-subscription-filter.ts` | (cut) | Originally planned as a reusable construct; folded inline into `audit-stack.ts` since the subscription-filter loop is only invoked once and the abstraction wasn't earning its keep | — Cut |
| `infra/lambda/_shared/audit.py` | (cut) | Originally planned as a parallel module; superseded by extending `_shared/observability.py:emit_audit` instead (see divergence note) | — Cut |
| `docs/specs/ARCHITECTURE.md` | Modified | Updated §5 stack map row, §12 Phase 1.7 section, §13 dependency graph + critical path (softened "1.7 gates 2A" framing per D12), §15 Lambda Inventory (`audit-writer` → `audit-forwarder`), §16 audit-latency open question (resolved), §17 spec index | ✅ Done in 2026-05-17 spec-sync sweep |
| `docs/firmware-coordination/2026-04-17-cloud-contracts.md` | Modified | §C14 entry: 1.7 spec + implementation status, closes §C13.4 option #2 | ✅ Done in 2026-05-17 spec-sync sweep |
| `docs/playbooks/audit-reader-onboarding.md` | (deferred) | One-page runbook for attaching a real trust policy when the compliance-reader identity is named. Slot into the 1.7 deploy commit | ⏳ Deferred |

### Architectural divergence from initial spec sketch

Two intentional changes between the spec's "Files Changed" plan and what actually shipped:

1. **`_shared/audit.py` → extend `_shared/observability.py:emit_audit` instead.** The 1B-rev observability module already exposes an `emit_audit()` function (audit-shape entries are already flowing in production from the 4 processing handlers). Creating a parallel module would have meant either deprecating the existing one (handler touch costs) or having two emission paths that have to stay in sync. Cleaner to extend the existing one with the spec's new fields (`schema_version`, `request_id`) and the L4 scrubber-bypass fix. Net: single emission path, no handler touches, future 2A handlers import the same helper.

2. **`audit-subscription-filter.ts` reusable construct → inlined in `audit-stack.ts`.** Only used once (a `for` loop over six handler log groups). The reusable wrapper would have been 6 lines of interface + 3 lines of body for zero callers outside the loop. Inlining keeps the stack readable without the wrapper indirection.

Both choices are flagged here so a future reviewer reading the spec doesn't go hunting for files that don't exist.

### Dependencies

- Phase 0A (Cognito User Pool, Pre-Token Lambda — existing log group exists)
- Phase 0B (no direct dependency — audit doesn't read identity tables, just consumes log lines)
- Phase 1A-rev (snippet-parser exists, emits `device.snippet_uploaded`)
- Phase 1B-rev (4 handlers exist, emit 5 audit event types)
- Phase 1.5 (AuditKey CMK exported by Security stack; ops SNS topic for alarms)
- Phase 1.6 (Powertools layer ARN published; ops SNS topic renamed appropriately; X-Ray on consuming Lambdas)

NPM packages: none new. CDK constructs for Firehose + Object Lock are in `aws-cdk-lib`.

Python packages: none new. Powertools (already on the layer) provides `Logger`, which is all the helper needs.

### Configuration

**Environment variables (audit-forwarder Lambda):**
- `AUDIT_LOG_GROUP_NAME` = `gosteady-{env}-audit`
- `POWERTOOLS_SERVICE_NAME` = `gosteady-{env}-audit-forwarder`
- `LOG_LEVEL` = `INFO`

**CDK context values:**
- `gosteady:auditBucketObjectLockEnabled` — `false` (dev), `true` (prod). Per-env config in `infra/lib/config.ts`.
- `gosteady:auditBucketObjectLockYears` — `6` (default; overridable per-env).
- `gosteady:auditHotRetentionDays` — `90` (default; mirrors L4 hot side).

**Cross-stack imports:**
- `{prefix}-AuditKeyArn` from `GoSteady-{Env}-Security` — for log group + bucket encryption + Firehose key
- Ops SNS topic ARN from `GoSteady-{Env}-Security` — for alarm subscriptions

## Testing

### Test Scenarios

| # | Scenario | Method | Expected Result | Status |
|---|----------|--------|-----------------|--------|
| T1 | **Pre-deploy:** 1B-rev handlers' existing audit-shape lines match the `{ $.audit = true }` subscription filter pattern | `aws logs filter-log-events --log-group-name /aws/lambda/gosteady-dev-activity-processor --filter-pattern '{ $.audit = true }' --start-time $(($(date +%s) - 86400))000` | Returns ≥1 event from a recent activity write. If empty → A3 violated; fix `_shared/observability.py` before proceeding | Pending |
| T2 | Audit forwarder Lambda receives subscription filter events | Trigger a synthetic activity publish → wait 5 s → check forwarder log group | Forwarder log shows decode success, PutLogEvents success, 1 event forwarded | Pending |
| T3 | Audit log group receives forwarded events | After T2, query `gosteady-dev-audit` with Logs Insights: `fields @timestamp, event, actor.role | filter event = "patient.activity.create" | sort @timestamp desc | limit 5` | Returns the forwarded event with the original schema fields intact | Pending |
| T4 | Firehose delivers to S3 within 60 s of audit log group write | After T3, wait ~70 s, list bucket: `aws s3 ls s3://gosteady-dev-audit-logs/audit/year=2026/month=05/day=17/` | At least one `.gz` object present; download and inspect — contains the audit event as NDJSON | Pending |
| T5 | S3 object is CMK-encrypted with AuditKey | `aws s3api head-object --bucket gosteady-dev-audit-logs --key audit/year=2026/month=05/day=17/<key>.gz` | `ServerSideEncryption: aws:kms`, `SSEKMSKeyId` matches AuditKey ARN | Pending |
| T6 | Internal-role auto-stamping fires | Manually invoke audit-forwarder with a synthetic event whose `actor.role = "internal_admin"`; verify forwarded event in audit log group | Forwarded event has `internal_access: true` and `severity: elevated` even though the source event didn't | Pending |
| T7 | PII scrubber does not strip identifiers from audit events | Trigger an audit emission with `subject.patientId = "pat_PII_TEST"`; verify forwarded event in audit log group | `subject.patientId` is present in the forwarded event (not redacted) | Pending |
| T8 | Audit-reader IAM role permissions allow read but not write | Assume the role temporarily via `aws sts assume-role` (with a test trust policy); attempt `logs:FilterLogEvents` (should succeed) and `logs:PutLogEvents` (should fail with AccessDenied) | Read succeeds, write fails with explicit AccessDenied | Pending |
| T9 | Forwarder backpressure doesn't drop events under burst | Synthetic publish of 100 activity events in 1 s (script with parallel publishes) | All 100 events land in audit log group within 30 s; forwarder concurrency stays ≤5 (reserved limit) | Pending |
| T10 | Forwarder Errors alarm fires on a synthetic failure | Temporarily revoke forwarder's `logs:PutLogEvents` IAM grant; trigger an audit event; restore grant | Alarm transitions to ALARM within 5 min; SNS message lands at ops topic; restore returns to OK | Pending |
| T11 | Firehose delivery failure alarm fires | Temporarily remove forwarder's `kms:GenerateDataKey` grant on AuditKey (Firehose can't encrypt) | Firehose `DeliveryToS3.Failures` > 0; alarm fires; restore returns to OK | Pending |
| T12 | dev bucket allows DeleteObject; prod bucket denies | dev: `aws s3 rm s3://gosteady-dev-audit-logs/test-key.gz` should succeed (if object exists); prod: same command should fail with `AccessDenied: deny-delete bucket policy` | Behavior matches per L5 | Pending (prod: deferred until prod stack exists) |
| T13 | All 6 existing handler log groups have the subscription filter attached | `for h in activity-processor heartbeat-processor threshold-detector alert-handler snippet-parser cognito-pre-token; do aws logs describe-subscription-filters --log-group-name /aws/lambda/gosteady-dev-$h; done` | Each returns one filter targeting the audit-forwarder Lambda with pattern `{ $.audit = true }` | Pending |
| T14 | `_shared/audit.py` helper round-trip from a 2A-stub Lambda | Build a stub Lambda that calls `emit_audit(event="patient.detail.read", actor={...}, subject={...}, action="read")`; deploy; invoke; verify event in audit log group | Event lands with all auto-stamped fields correct | Pending |
| T15 | Event-name typo handling | Call `emit_audit(event="patient.actviity.create", ...)` (typo) | Helper logs a `WARNING` line about unknown event name; event is still emitted (don't break host handler); ops alarm pattern catches the warning | Pending |
| T16 | Subscription filter on audit log group → Firehose delivers in NDJSON | Inspect a downloaded `.gz` object from S3: `zcat <object>.gz | jq -c .` | Each line is a valid JSON object matching the schema | Pending |
| T17 | End-to-end latency from handler emit → S3 object available | Time from synthetic activity publish to S3 object presence | p99 < 5 min (per A4) | Pending |
| T18 | Compliance reader runbook: trust-policy attach works | Run the documented `aws iam update-assume-role-policy` command with a test policy naming a synthetic IAM user; verify user can then assume the role and query audit | Documented commands execute cleanly; trust policy applied without redeploy | Pending |

### Verification Commands

```bash
# Tier 1 — pre-deploy gate (A3 verification)
aws logs filter-log-events \
  --log-group-name /aws/lambda/gosteady-dev-activity-processor \
  --filter-pattern '{ $.audit = true }' \
  --start-time $(($(date +%s) - 86400))000 \
  --region us-east-1 \
  --query 'events[].message' \
  --max-items 5

# Tier 2 — infra readiness
aws logs describe-log-groups --log-group-name-prefix gosteady-dev-audit --region us-east-1
aws lambda get-function-configuration --function-name gosteady-dev-audit-forwarder --region us-east-1 | jq '{Layers, ReservedConcurrentExecutions, Environment}'
aws firehose describe-delivery-stream --delivery-stream-name gosteady-dev-audit-to-s3 --region us-east-1 | jq '.DeliveryStreamDescription | {Status, Destinations: .Destinations[0].ExtendedS3DestinationDescription | {BucketARN, BufferingHints, CompressionFormat, EncryptionConfiguration}}'

# Tier 3 — subscription filter coverage
for h in activity-processor heartbeat-processor threshold-detector alert-handler snippet-parser cognito-pre-token; do
  echo "=== $h ==="
  aws logs describe-subscription-filters --log-group-name /aws/lambda/gosteady-dev-$h --region us-east-1 \
    --query 'subscriptionFilters[].{name:filterName, pattern:filterPattern, target:destinationArn}'
done

# Tier 4 — end-to-end audit emission (synthetic activity publish)
aws iot-data publish --topic gs/GS9999999999/activity --region us-east-1 \
  --payload '{"serial":"GS9999999999","session_start":"2026-05-17T14:02:00Z","session_end":"2026-05-17T14:18:00Z","steps":142,"distance_ft":340.5,"active_min":16}'
sleep 5
# Verify in audit hot path
aws logs filter-log-events --log-group-name gosteady-dev-audit \
  --filter-pattern '{ $.event = "patient.activity.create" }' \
  --start-time $(($(date +%s) - 60))000 --region us-east-1 \
  --query 'events[0].message' | jq .
sleep 65
# Verify in audit cold path
aws s3 ls "s3://gosteady-dev-audit-logs/audit/year=$(date -u +%Y)/month=$(date -u +%m)/day=$(date -u +%d)/" --region us-east-1

# Tier 5 — encryption + bucket policy
aws s3api get-bucket-encryption --bucket gosteady-dev-audit-logs --region us-east-1
aws s3api get-bucket-policy --bucket gosteady-dev-audit-logs --region us-east-1 | jq -r '.Policy | fromjson'
aws s3api get-object-lock-configuration --bucket gosteady-dev-audit-logs --region us-east-1 2>&1
# Expected (dev): error "ObjectLockConfigurationNotFoundError" (confirms L5: no Object Lock in dev)

# Tier 6 — IAM least-privilege spot check on audit-reader
aws iam get-role --role-name gosteady-dev-audit-reader --region us-east-1 \
  --query 'Role.{TrustPolicy: AssumeRolePolicyDocument, MaxSessionDuration: MaxSessionDuration}'
aws iam list-role-policies --role-name gosteady-dev-audit-reader --region us-east-1
aws iam list-attached-role-policies --role-name gosteady-dev-audit-reader --region us-east-1
```

## Deployment

### Deploy Commands

```bash
cd infra
npm run build

# Pre-deploy gate: confirm 1B-rev audit-shape lines match the filter pattern (T1).
# If empty, fix _shared/observability.py first (small touch; not a stack deploy).
aws logs filter-log-events \
  --log-group-name /aws/lambda/gosteady-dev-activity-processor \
  --filter-pattern '{ $.audit = true }' \
  --start-time $(($(date +%s) - 86400))000 --region us-east-1 \
  --query 'events[0].message'

# Deploy the Audit stack
npx cdk diff GoSteady-Dev-Audit --context env=dev
npx cdk deploy GoSteady-Dev-Audit --context env=dev --require-approval never

# Acceptance: run Tier 4 + Tier 5 verification commands above.
```

Estimated deploy time: ~3-4 min (S3 bucket creation + Firehose + Lambda + 7 subscription filters + 3 alarms).

### Rollback Plan

If the audit-forwarder Lambda crashes or produces high error rate:
1. The forwarder is invoked async by CW subscription filters — its failures don't propagate to the handler Lambdas. Handler hot path is unaffected.
2. Disable the forwarder by removing the subscription filter sources: `aws logs delete-subscription-filter --log-group-name /aws/lambda/gosteady-dev-{handler} --filter-name AuditCapture` (per handler).
3. Audit events accumulate in handler log groups (90d retention) — re-enable the filter once fixed; subscription filters are real-time-only (don't backfill historical entries), so any events emitted while the filter was off are recoverable via CW Logs Insights but not via Firehose → S3.

If Firehose delivery to S3 fails persistently (e.g., KMS misconfiguration):
1. Firehose retries automatically with backoff up to 24 h, then writes to its error prefix in the same bucket.
2. The `audit-firehose-delivery-failures` alarm fires; investigate KMS key policy / bucket policy.
3. No data loss within the 24 h retry window; check `firehose-errors/` prefix for anything past it.

If the dev bucket needs to be torn down for cleanup:
1. `aws s3 rm s3://gosteady-dev-audit-logs --recursive` — works in dev (no Object Lock).
2. `cdk destroy GoSteady-Dev-Audit --context env=dev` — bucket destroyed normally.
3. Subscription filters detach automatically; handler log groups unaffected.

If prod bucket has Object Lock enabled and you need to remove the stack:
1. **You can't.** Object Lock compliance mode prevents deletion of any object until its retention expires.
2. The bucket itself can only be deleted once all objects are deletable (i.e., 6+ years after the last write).
3. To stop new writes: disable the audit log group's subscription filter to Firehose (one filter). Objects in the bucket stay until retention expires; bucket persists.
4. This is intentional and is the entire point of compliance mode.

**Risk: handler hot path is fully decoupled from the audit pipeline.** Subscription filters are async; forwarder failures don't backpressure handlers. Worst case during a 1.7 outage is audit events backlog in CW Logs (90d retention) until re-enabled.

## Decisions Log

| # | Decision | Alternatives Considered | Why This Choice |
|---|----------|------------------------|-----------------|
| D1 | Audit emission via handler-emits-tagged-log-line + subscription filter routing (Q1 option a) | (b) Handlers write directly to audit log group via boto3; (c) SQS + dedicated audit-writer Lambda | (a) requires zero IO changes to existing 1B-rev handlers, matches §10 storage description as-written, CW Logs is durable async, no new failure surface on handler hot path |
| D2 | Fire-and-forget async emission, no waiting for audit ack (Q2 option a) | Synchronous PutLogEvents with response wait | Phase 2A's API response budget can't absorb a ~10ms audit hop per mutation, and CW Logs is already durable. Closes the §16 Open Question on audit hot-path latency |
| D3 | Object Lock prod-only (Q3 option a); dev uses normal SSE-KMS | Both envs use Object Lock | Matches Phase 1.5 CloudTrail precedent ([ARCHITECTURE.md:1151](ARCHITECTURE.md)). Object Lock is irreversible; dev needs cleanup capability for test data churn |
| D4 | 1.7 ships helper + schema + catalog; 2A wires its own read-event emission (Q4 option a) | 1.7 anticipates 2A read paths and emits placeholders now | 2A handlers don't exist yet to retrofit. Scope discipline — pulling read-event emission into 1.7 bloats it into 2A territory |
| D5 | Create `audit-reader` IAM role now with empty trust policy (Q5 option a) | Defer entirely until compliance reader is named | Defining the role and permissions now means future attach is a one-line trust-policy edit, not a CDK redeploy. Runbook documents the attach step |
| D6 | Two-hop architecture: handler log group → subscription filter → forwarder Lambda → dedicated audit log group → second subscription filter → Firehose → S3 | One-hop: subscription filter on handler log groups directly to Firehose; drop the dedicated audit log group | The dedicated audit log group enables (a) restrictive IAM (handler log groups must be writable by handlers for ops logs too), (b) different retention (audit hot 90d vs ops 30d dev / 90d prod), and (c) Logs Insights "show me audit data" without filtering through operational noise. Worth the one extra hop. Matches the ARCHITECTURE.md §10 storage description as-written |
| D7 | Schema versioning via `schema_version` field on every event (L9) | Embed version in event name; version the doc only | Field is one byte at compile time, lets readers detect old-schema events six years later without parsing event-name patterns. Mirrors snippet binary `format_version` pattern from Phase 1A-rev |
| D8 | Internal-role auto-stamping in the audit-forwarder Lambda (not in the helper or per-handler) | Stamp in `_shared/audit.py`; require explicit caller flag | Forwarder is the chokepoint where every audit event passes; centralized stamping prevents any caller (existing 1B-rev handlers OR future 2A handlers) from forgetting to flag internal access. Defense in depth |
| D9 | Audit S3 partition scheme: `audit/year=YYYY/month=MM/day=DD/` (no hour partition) | Hour-level partition; flat by date; year/month only | At MVP volume (~10k events/day; ~1MB/day GZIP'd), daily partitions are fine for Athena and natural for compliance "events in 2027" queries. Hour partition is overkill at this volume; year/month only would slow point-in-time queries |
| D10 | PII scrubber bypassed for audit emissions (L4 inverse) | Run scrubber on audit events too | Audit events explicitly need identifiers (`patientId`, `userId`) — that's the entire forensic value. AU3 applies to operational logs to prevent accidental PII leakage; audit is the one place identifiers are intentional |
| D11 | Forwarder Lambda has reserved concurrency = 5 | Unlimited concurrency; reserved = 1 | At MVP volume (<100 events/min), 5 is far more than needed. Cap prevents runaway invocation in a forwarder-bug scenario. Easy to raise if Q1 (below) reveals real backpressure |
| D11.5 | Audit log stream name partitioned by UTC date (`audit-{YYYY-MM-DD}`) | Single static stream; partition by source handler name; partition by hour | PutLogEvents has a 5 MB/s per-stream throughput cap. Single stream becomes the bottleneck if 2A drives sustained high volume. Date partitioning naturally caps any one stream's lifetime load, lets Logs Insights queries scan only relevant days, and matches the S3 partition scheme (D9). Source-handler partitioning would obscure cross-handler correlation. Hour partition is overkill at expected volume. |
| D12 | Soften ARCHITECTURE.md §13 + §17 wording that 1.7 "gates" 2A | Leave the doc as-is | The dependency is a discipline gate (no patient data through UI without proper audit), not a technical one. 1.7 can ship before, alongside, or shortly after 2A's first dev iteration. Hard rule applies before first prod customer — same threshold as G9 multi-account, Phase 1.5 prod hardening, etc. Per spec discussion 2026-05-17 |

## Open Questions

> Plain-language explanation of each question + a decision where we can call it. Decisions called now are mirrored into the Decisions Log above where they shape the implementation; the open ones are explicitly tagged with what would resolve them.

### Q1. Will the audit-forwarder Lambda backpressure under realistic load?

**What's actually being asked:** Every audit-tagged log line from every handler runs through one Lambda (audit-forwarder), which then writes to the audit log group via `logs:PutLogEvents`. PutLogEvents has a per-stream throughput limit (5MB/s), and Lambda has cold-start overhead. If audit volume spikes (e.g., Phase 2A goes live and the portal generates 1000 read events/min from a busy facility), can the forwarder keep up without dropping events or causing CW subscription filter backlog?

**What's at stake:** Audit gap during a busy moment is exactly when compliance forensics matter most. Backlog appearing in subscription filter delivery means a possibly-relevant event hasn't reached the audit log group yet when the compliance reader queries.

**Decision:** ⏳ **Observe in Phase 2A first week.** MVP volume is fine. Real test is the first day Phase 2B portal is in active use. **Trigger to revisit:** if `gosteady-dev-audit-forwarder` shows sustained Duration p99 >2s, or if subscription filter `DeliveryErrors` metric on any source log group is nonzero, switch the forwarder to a batched-PutLogEvents pattern (collect N events or 5s, batch-write). The Lambda code change is ~10 lines.

---

### Q2. Should Object Lock be governance mode or compliance mode in prod?

**What's actually being asked:** Object Lock has two modes. **Governance mode** allows a privileged IAM principal (with `s3:BypassGovernanceRetention` permission) to delete objects before retention expires — useful for "we made a mistake, retract this object." **Compliance mode** allows nobody, including AWS root, to delete objects before retention expires — useful for "we cannot tamper with this even if we wanted to." Healthcare-adjacent compliance typically requires compliance mode.

**What's at stake:** If we ship compliance mode and later realize we have a genuine reason to delete an object (e.g., we accidentally audit-logged a credit card number due to a 2A bug), we cannot remove it. The bucket holds it for 6 years no matter what.

**Decision:** ✅ **Compliance mode.** This matches the AU2 phrasing in [ARCHITECTURE.md §14](ARCHITECTURE.md) ("S3 Object Lock"). The "what if we audit-log something we shouldn't" risk is mitigated by L4 (PII scrubber bypassed only for the audit helper, which writes a controlled schema; no raw payloads in audit events; D9 schema versioning lets us reject ill-formed schemas at write time). **Trigger to revisit:** if a legal review explicitly asks for governance mode, switch the prod bucket config one line. Already-written objects stay compliance-locked.

---

### Q3. Do we want Athena set up now or wait until a real compliance query appears?

**What's actually being asked:** The S3 bucket holds compressed NDJSON files partitioned by date. To query them with SQL, you need a Glue table schema + an Athena workgroup. That's another ~50 lines of CDK and a one-time `MSCK REPAIR TABLE` to register partitions. Worth doing now vs deferring until someone actually needs to query?

**What's at stake:** Whether the first real compliance query takes 5 minutes (if Athena is pre-set-up) or 1 hour (if someone has to write the Glue config and ad-hoc the workgroup). Either way, the data is in S3 and recoverable.

**Decision:** ⏳ **Defer to Phase 1.7.1 or first-need.** v1 ships the data path; v1.1 ships the query infrastructure. Logs Insights against the hot path (90d) covers >90% of practical queries (most incident triage and most "did internal_admin touch this account last week" queries). Athena becomes valuable when querying past 90d or producing customer-facing audit reports. **Trigger to revisit:** first real query that needs to go past the 90-day CW retention. ~half-day's work to scope.

---

### Q4. Should the audit-forwarder Lambda be a Phase 1.7 deliverable or refactored into a Powertools layer-provided wrapper?

**What's actually being asked:** The forwarder is the only stateful piece of 1.7. It could be (a) a dedicated function with its own code, or (b) a thin wrapper invoking a shared Powertools-style library. (a) is faster to ship; (b) is more "framework-y" but adds a layer of indirection.

**What's at stake:** Maintainability vs ship speed. The forwarder is ~30 lines of Python; either choice is fine.

**Decision:** ✅ **Dedicated function with inline code.** Powertools doesn't have a "subscription-filter forwarder" abstraction; building one for one consumer is over-engineering. If a second use case appears (e.g., separate "internal access" forwarder), refactor then.

---

### Q5. What happens to audit events emitted by handlers between deploy and subscription-filter attachment?

**What's actually being asked:** During the few-second window between (a) the audit log group existing and (b) the subscription filter being live on a handler log group, audit events emitted by that handler are written to its log group as normal but not forwarded. They sit in the handler log group (90-day retention) but never reach S3.

**What's at stake:** A handful of audit events from the deploy window are not in the compliance long-term archive. Compliance reader can still find them via Logs Insights on the source handler log group, but they're outside the standard "search S3 via Athena" workflow.

**Decision:** ✅ **Accept the deploy-window gap; document it.** The window is seconds. Subscription filters are real-time only — they can't backfill historical events. CDK deploys all-or-nothing per stack, and the subscription filters create roughly simultaneously, so the actual gap is small. **Trigger to revisit:** if a compliance need ever requires zero-gap, we'd ship a one-shot backfill Lambda after deploy that reads the handler log groups via Logs Insights and writes to the audit log group. ~1 day's work; not v1 scope.

---

### Q6. Do we audit `auth.login` and `auth.login_failed` from Cognito or from the Pre-Token Lambda?

**What's actually being asked:** Cognito itself emits auth events to CloudTrail (CloudTrail covers AWS API calls including Cognito auth). The Pre-Token Lambda is invoked during the token-generation step and has access to user context. We could either (a) rely on CloudTrail for auth audit (already in Phase 1.5), (b) have the Pre-Token Lambda emit application-level audit events for auth, or (c) both.

**What's at stake:** Audit completeness for auth events. CloudTrail has all the data but in a different shape and a different log group. The application-level audit catalog is more queryable but requires us to emit from the Pre-Token Lambda.

**Decision:** ⏳ **Defer to Phase 2A.** The Pre-Token Lambda was already partial-listed in the event catalog (`auth.login`, `auth.login_failed`, `auth.mfa_challenge`) for completeness, but those events are not yet emitted from the existing 0A-rev code. Phase 2A's overall auth-flow review is the natural place to wire them. v1.7 catalogs them as planned-2A; the subscription filter on `gosteady-{env}-cognito-pre-token` log group is in place so they flow automatically once 2A turns them on. **Trigger to advance:** Phase 2A spec writing.

---

---

### Q7. S3 object format — double-gzip + CW Logs envelope wrapping (surfaced at deploy)

**What's actually being asked:** During T4 acceptance at deploy time, we discovered the audit S3 objects aren't clean NDJSON of audit events. They're double-GZIP-compressed (CW Logs subscription filter pre-compresses delivery to Firehose; our Firehose config adds another GZIP for storage), and the inner content is a CW Logs envelope: `{messageType:"DATA_MESSAGE", owner, logGroup, logStream, subscriptionFilters, logEvents:[{id, timestamp, message:"<audit JSON as string>"}]}`. To extract a single audit event from S3 today, you have to: `gunzip → gunzip → JSON parse envelope → for each logEvents item, JSON parse the .message string`. That's ugly but recoverable.

**What's at stake:** Future Athena queries against the audit bucket. The expected query shape is something like `SELECT actor.userId FROM audit WHERE event = 'patient.activity.read' AND ts > ...`. With the current format that requires either a custom Hive/JSON SerDe that knows the envelope shape, or a Firehose Lambda transformer that unwraps to clean NDJSON before write.

**Decision:** ⏳ **Defer fix to Phase 1.7.1.** Today's hot path (CW Logs Insights against `gosteady-{env}-audit`) handles all practical queries within the 90-day hot window without touching S3. Athena becomes worth wiring up when querying past 90 days or producing customer-facing audit reports. The fix is a small Firehose change — add a `LambdaFunctionProcessor` or a `cloudwatch-log-processor` (built into aws-cdk-lib firehose) that unwraps the envelope. ~half-day work. **Trigger to advance:** first real Athena query need. Doesn't block 2A.

---

### Q8. `schema_version` field absent from emissions by existing 1B-rev Lambdas (surfaced at deploy)

**What's actually being asked:** The `schema_version: 1` field was added to `_shared/observability.py:emit_audit` in commit `da92c37`, but the four existing 1B-rev Lambdas (activity-processor / heartbeat-processor / threshold-detector / alert-handler) haven't been redeployed since. So any audit event they emit lacks the field. Spec L9 promises "schema versioning via `schema_version` field on every event"; the actual state is "schema_version on every event from Lambdas redeployed after 2026-05-17."

**What's at stake:** Six-year retention means a compliance reader in 2032 might pull audit events from 2026 that have no `schema_version`. Per L9 spec text, readers default to v1 when absent — so it's still parseable, just less explicit.

**Decision:** ✅ **Accept; the design already handles it.** L9 explicitly says "absence in v1 events is unambiguous (defaults to 1)." Readers know what to do. **No urgency to redeploy 1B Lambdas just for this** — the next routine Phase 1B touch (whenever, for any other reason) will pick up the new helper. **Trigger to revisit:** if any other field is added to the audit schema before then, bundle the L9 backfill into the same redeploy.

---

### Decision summary

| # | Question | Resolution |
|---|----------|-----------|
| Q1 | Forwarder backpressure | ⏳ Observe in Phase 2A first week |
| Q2 | Object Lock mode in prod | ✅ Compliance mode |
| Q3 | Athena setup timing | ⏳ Defer to Phase 1.7.1 or first-need |
| Q4 | Forwarder code shape | ✅ Dedicated function, inline code |
| Q5 | Deploy-window audit gap | ✅ Accept; document as seconds-long |
| Q6 | Auth event source | ⏳ Defer to Phase 2A |
| Q7 | S3 double-gzip + envelope format | ⏳ Defer fix to Phase 1.7.1 (Athena trigger) |
| Q8 | schema_version backfill on existing 1B Lambdas | ✅ Accept (L9 default-to-v1 handles it) |

Five of eight decided now. Q1 + Q3 + Q6 + Q7 require observation or downstream phase to resolve.

## Changelog

| Date | Author | Change |
|------|--------|--------|
| 2026-05-17 | Jace + Claude (cloud session) | Initial spec drafted. User confirmed leans on 5 key decisions in chat (audit emission path, latency posture, Object Lock dev/prod parity, Phase 2A read-event scope, compliance reader IAM role). Spec consolidates AU1–AU4 requirements, the device.* catalog from §4, and the 1B-rev audit-shape log entries into a single audit destination + retrieval surface, while also softening ARCHITECTURE.md §13/§17 framing of "1.7 gates 2A" to reflect that the gate is discipline (no patient data through UI without proper audit), not a hard technical dep |
| 2026-05-17 | Jace + Claude (cloud session, same day) | **Implementation drafted.** Added D11.5 (date-partitioned destination streams) after a cost-and-performance discussion surfaced the 5 MB/s PutLogEvents per-stream cap as the only realistic backpressure concern at Phase 2A volume. Two intentional divergences from the spec's initial "Files Changed" plan: (a) extended existing `_shared/observability.py:emit_audit` instead of creating a parallel `_shared/audit.py`; (b) inlined the subscription-filter loop in `audit-stack.ts` instead of creating a reusable `audit-subscription-filter.ts` construct. Both folded into the spec under "Architectural divergence" — see Files Changed table above. Implementation passes `tsc` clean and `cdk synth GoSteady-Dev-Audit` clean (~38 synthesized resources including 3 alarms, 7 subscription filters, 1 Firehose, 1 S3 bucket, 4 Lambdas incl. CDK helpers, 6 IAM roles + 5 policies). T1 pre-deploy gate (`{ $.audit IS TRUE }` filter pattern matches 1B-rev's `"audit": true` emissions) verified at source-code read; live `aws logs filter-log-events` check is the first acceptance step at deploy time. ARCHITECTURE.md + firmware-coordination doc updated in parallel spec-sync sweep |
| 2026-05-17 | Jace + Claude (cloud session, same day) | **Deployed to dev** in 4 attempts. First 3 attempts hit issues only visible at live deploy (not in `cdk synth`): (1) phantom `CfnResource('ForwarderConcurrency')` block I left in by accident — removed; (2) `addToResourcePolicy` on imported `kms.Key.fromKeyArn` is a no-op (key is owned in another stack) — added CW Logs grant on AuditKey in `security-stack.ts` instead, scoped via encryption-context condition to the specific audit log group ARN; (3) IAM trust-policy stub validation — both `Principal: '*'` literal (serializes as `{"STAR":"*"}`) and `ArnPrincipal` of a non-existent role (IAM validates principal existence) failed. Settled on `AccountRootPrincipal` placeholder with documented caveat about admin-policy holders; runbook step still replaces this before any real audit data exists; (4) `ReservedConcurrentExecutions=5` rejected — dev account is on the new-account 10-concurrency floor, not the 1000 default, so any reservation leaves <10 unreserved which Lambda forbids. Override dropped entirely; forwarder shares the unreserved pool (fine at MVP volume). 4th attempt: CREATE_COMPLETE in 141 s. Smoke T2/T3/T4 pass end-to-end — synthetic activity publish → activity-processor audit-shape log → subscription filter → audit-forwarder → date-partitioned `audit-2026-05-17` stream in `gosteady-dev-audit` log group → Firehose → S3 at `audit/year=2026/month=05/day=17/` within ~70 s. **Two non-blocking issues surfaced** (added to ARCH §16 Open Questions and Q7+Q8 below): (a) S3 objects are double-gzipped + wrapped in a CW Logs envelope (`{messageType, logGroup, logEvents[]}` with the audit JSON as a string inside `logEvents[].message`); data IS recoverable but Athena will need a custom SerDe or Firehose Lambda transformer — Phase 1.7.1 candidate; (b) `schema_version` field is missing from emissions by the 4 existing 1B-rev Lambdas (they predate today's `observability.py` modification) — correct-by-design per L9 readers default to v1, will populate naturally on next processing-stack redeploy. Deploy-fix commit `54e0ddc` on `feature/infra-scaffold`; doc-sync follow-up in same session |

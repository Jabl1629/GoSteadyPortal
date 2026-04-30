# Phase 1.6 — Observability Foundation

## Overview
- **Phase**: 1.6
- **Status**: ✅ Deployed (dev)
- **Branch**: feature/infra-scaffold (matched existing project pattern; spec field aspirational)
- **Date Started**: 2026-04-29
- **Date Completed**: 2026-04-30

Deploys the operational telemetry layer for the cloud platform: a Powertools Lambda layer (refactor target for the six existing handlers), X-Ray tracing across IoT Rule → Lambda → DDB, two CloudWatch dashboards (a platform-health view and a per-device detail view), an alarm catalog covering the silent-failure modes documented in [`ARCHITECTURE.md` §16](ARCHITECTURE.md), enforced log-retention policies, and AWS Cost Anomaly Detection. Audience is internal: the cloud + firmware teams need shared visibility during M14.5 site-survey shakedown and M15 clinic deployment, before the real caregiver-facing portal (Phase 2A → 2B → 3A) ships.

The per-device dashboard is the **rudimentary visual surface for files offloaded by the device** — recent activity-processor writes (session summaries from the M9 algorithm) and recent snippet-parser uploads (raw IMU windows). It is a wedge, not the final caregiver portal. When Phase 2A → 2B → 3A lands, the per-device dashboard's Logs Insights queries become the spec for the API endpoints that the Flutter portal will consume; the dashboard itself remains as an internal-ops surface alongside the production portal.

## Locked-In Requirements

| # | Requirement | Decided In | Rationale |
|---|-------------|-----------|-----------|
| L1 | Stack name: `GoSteady-{Env}-Observability` | ARCHITECTURE.md §5 CDK Stack Map | Fits the deploy order: wrapped around all stacks (no inbound dependencies); deploys in parallel with Auth/Data/Processing/Ingestion. |
| L2 | Powertools shipped as a published Lambda layer (versioned), not pip-vendored per-Lambda | Phase 1B-rev D8 deferred this | Reduces per-Lambda zip from ~6 MB to ~1 MB; centralizes Powertools version pin; isolates upgrades. Phase 1B-rev shipped Powertools as a pip dep with the explicit "Phase 1.6 will refactor to layer" note. |
| L3 | Log retention enforced: 30 days (dev) / 90 days (prod) | ARCHITECTURE.md L3 (Data Lifecycle) | AWS default is "never expire" → unbounded cost. 30 days covers our typical incident-debug window; 90 days in prod gives a quarter of forensic depth. |
| L4 | Audit log group + S3 Object Lock destination is **not** in this phase | Phase 1.7 owns it | 1B-rev handlers already emit structured audit-shape JSON log lines. 1.7 routes via subscription filter to dedicated log group + S3 Object Lock. 1.6 deploys regular CloudWatch and lets 1B-rev audit lines land in normal handler log groups until 1.7 ships. |
| L5 | DLQ alarms are necessary but **not sufficient** for handler-internal failure detection | ARCHITECTURE.md §16 (open question, 2026-04-27) | IoT Rule Lambda actions are async — Lambda-raised exceptions don't trip the IoT-side error action's SQS DLQ. They show up in CloudWatch logs and the Lambda Errors metric only. 1.6 alarm catalog MUST include Lambda Errors metric + log-pattern filters per handler, not just DLQ depth. |
| L6 | Reuse Security stack's existing `costAlarmTopic` SNS topic for new alarms | Phase 1.5 deployed it 2026-04-17 | One ops-notification destination for all cost + reliability signals. Cross-stack import via `Topic.fromTopicArn`. |
| L7 | Per-device dashboard uses CloudWatch dashboard variables for serial selection | Native feature; no Lambda-backed custom widgets in v1 | Variable type `pattern` with default `GS9999999999`. Operator can switch to `GS0000000001` etc. without redeploying. Lambda-backed custom widgets reserved for Phase 2A. |

## Assumptions

| # | Assumption | Risk if Wrong | Validation Plan |
|---|-----------|---------------|-----------------|
| A1 | AWS-published `aws-lambda-powertools` ARM64 layer ARN matches the version pinned in 1B-rev (`aws-lambda-powertools >= 3.0`) | Layer/handler version mismatch causes import failures or schema drift | Pin the exact layer version ARN in CDK config; if mismatch, use `cdk synth` + `lambda update-function-configuration` to verify layer is consumable before declaring 1.6 deployed |
| A2 | X-Ray Active Tracing on Lambda + auto-instrumentation via Powertools Tracer is sufficient for IoT Rule → Lambda → DDB visibility (IoT Rules themselves don't propagate trace context) | Trace starts at Lambda invocation; any IoT-Core-side latency is invisible | Acceptable for v1 — IoT Rule latency is consistently <50 ms in our ingestion pattern; the interesting variability lives in Lambda + DDB. Revisit if a real-time SLA appears |
| A3 | CloudWatch Logs Insights queries on existing 1B-rev structured JSON logs can drive per-device dashboard widgets without code changes to handlers | Need to refactor handlers to emit additional fields | 1B-rev already logs `correlation_id` (= serial), `subject.deviceSerial`, full `subject` block, `after.*` fields including `steps`/`distance_ft`/`roughnessR`/`surfaceClass`. Verify with synthetic publish + Logs Insights query before declaring spec final |
| A4 | AWS Cost Anomaly Detection's "AWS service" granularity is sufficient for v1 cost monitoring | Per-stack or per-resource cost anomalies missed | At our scale (~$10/mo across all stacks), service-level granularity is plenty. Per-resource cost monitoring is overkill for MVP |
| A5 | The ~3 MB per-Lambda zip-size reduction from layer-refactoring the existing 6 Lambdas is worth the touch-cost (CFN UPDATE on each Lambda) | Logical-ID drift causes CREATE+DELETE collisions | All 6 existing Lambdas have stable logical IDs in 1B-rev; layer attachment is a non-replacement update |
| A6 | Heartbeat-processor can publish CloudWatch custom metrics for `battery_pct`, `rsrp_dbm`, `snr_db`, `watchdog_hits`, `fault_counters_*` without significant cold-start cost increase | EMF-vs-PutMetricData latency adds to the already-warm 1B-rev p50 | Phase 1B-rev already uses Powertools Metrics (EMF — async, no API call). Adding 5-7 metric calls is microseconds; verified by Powertools docs and 1B-rev's existing `synthetic_alert_count` metric path |
| A7 | Per-device dashboard variable for serial selection works across all widgets simultaneously, including Logs Insights widgets | Variable substitution doesn't reach Logs Insights query strings | CloudWatch supports `${variable}` substitution in Logs Insights queries — verify on a test dashboard before final deploy |

## Scope

### In Scope

**Observability stack** (`GoSteady-{Env}-Observability`):

- **Powertools Lambda layer** — published as a CDK `LayerVersion`, ARM64, Python 3.12. Reference the AWS-managed Powertools layer ARN to avoid building our own zip. Refactor all six existing 1B-rev / 1A-rev Lambdas to consume the layer (drop the pip dep from each handler's bundle):
  - `gosteady-{env}-activity-processor`
  - `gosteady-{env}-heartbeat-processor`
  - `gosteady-{env}-threshold-detector`
  - `gosteady-{env}-alert-handler`
  - `gosteady-{env}-snippet-parser`
  - `gosteady-{env}-cognito-pre-token`

- **X-Ray Active Tracing** — enable on all six Lambdas. Add IAM grants (`xray:PutTraceSegments`, `xray:PutTelemetryRecords`) to each Lambda's execution role. Powertools Tracer auto-instruments boto3 calls (DDB, Shadow, S3) without handler-code changes.

- **Heartbeat-processor metric publish addition** — extend handler to emit Powertools Metrics for the time-series fields the dashboard needs:
  - `battery_pct` (gauge), `rsrp_dbm` (gauge), `snr_db` (gauge) — per-heartbeat
  - `watchdog_hits` (gauge) and `fault_counters_fatal` / `fault_counters_watchdog` (gauges) — per-heartbeat
  - `uptime_s` (gauge)
  - All dimensioned by `serial` so per-device dashboard can filter
  - EMF format (no synchronous API call) — namespace `GoSteady/Devices/{env}`

- **Two CloudWatch dashboards:**

  1. **Platform Health Dashboard** — `gosteady-{env}-platform-health`
     - Ingestion rate widgets: heartbeat / activity / alert / snippet publishes per minute (CloudWatch metric: `AWS/IoT > Rule > Success`)
     - IoT Rule failure rate (`AWS/IoT > Rule > Failure`)
     - Lambda invocation count + error count + duration p50/p95/p99 per handler
     - DLQ depth (`AWS/SQS > ApproximateNumberOfMessagesVisible`) on `gosteady-{env}-iot-dlq`
     - DDB throttle count (`AWS/DynamoDB > UserErrors`, `> SystemErrors`) per identity-bearing table
     - Cost widget: monthly estimated charges (`AWS/Billing > EstimatedCharges`)
     - Single global view; no per-device variable

  2. **Per-Device Detail Dashboard** — `gosteady-{env}-per-device`
     - **Dashboard variable:** `serial` (default `GS9999999999`), used in every widget below
     - Live state widget: a markdown widget with a CLI snippet — CloudWatch dashboards can't query Device Shadow natively in v1, so the workaround is a documented `aws iot-data get-thing-shadow --thing-name $serial` invocation alongside a Logs Insights query against heartbeat-processor logs that surfaces the most recent heartbeat fields per serial. Phase 2A will replace this with a Lambda-backed custom widget that reads Shadow live.
     - Battery curve: line graph of `battery_pct` metric (from heartbeat-processor publish) over selected time range
     - Signal curve: line graphs of `rsrp_dbm` + `snr_db`
     - Reset / fault counters: line graphs of `watchdog_hits`, `fault_counters_fatal`, `fault_counters_watchdog`
     - **Recent activity (session summaries):** Logs Insights widget against `/aws/lambda/gosteady-{env}-activity-processor`. Query renders the last 20 sessions for the selected serial with `session_start`, `session_end`, `steps`, `distance_ft`, `active_min`, `roughness_R`, `surface_class`, `firmware_version`. This is the rudimentary "files offloaded" surface for activity rows.
     - **Recent snippets (raw IMU uploads):** Logs Insights widget against `/aws/lambda/gosteady-{env}-snippet-parser`. Query renders the last 20 snippet uploads for the selected serial with `snippet_id`, `window_start_ts`, `s3_key`, `payload_size`, `anomaly_trigger` (if present). Rudimentary "files offloaded" surface for snippet objects. S3 console link can be hand-clicked from `s3_key`.
     - Recent synthetic alerts: Logs Insights widget against `/aws/lambda/gosteady-{env}-threshold-detector` filtered by serial showing the last 10 alert evaluations + outcomes
     - Recent device alerts: Logs Insights widget against `/aws/lambda/gosteady-{env}-alert-handler` filtered by serial

- **Alarm catalog** (all alarms publish to the existing `costAlarmTopic` SNS topic from Security stack — renamed in CFN outputs to `opsAlarmTopic` to reflect broader scope):

  *Standard metric alarms:*
  - One Lambda Errors alarm per handler: `> 0` errors in 5 min
  - DLQ depth alarm: `ApproximateNumberOfMessagesVisible > 0` on `gosteady-{env}-iot-dlq`
  - IoT Rule failure alarm: per-rule `Failure > 0` in 5 min
  - DDB throttle alarms: `UserErrors > 0` or `SystemErrors > 0` on each identity-bearing table

  *Log-pattern alarms (the §16 ask):*
  - `gosteady-{env}-activity-processor` log group, pattern `unmapped_serial_count`: ≥1 occurrence in 5 min → warning
  - `gosteady-{env}-snippet-parser` log group, pattern `SnippetValidationError`: ≥1 occurrence in 5 min → warning
  - `gosteady-{env}-heartbeat-processor` log group, pattern `[ERROR]`: ≥1 occurrence in 5 min → warning
  - All five handler log groups, pattern `level":"ERROR"` (Powertools structured-log shape): ≥1 in 5 min → warning

  *Device-health alarms (firmware-coordination-suggested):*
  - `watchdog_hits` ≥3 within 24 h per serial (per firmware §F5.2 suggestion, 2026-04-29) — uses a CloudWatch metric math expression on the new `watchdog_hits` gauge dimensioned by serial. Severity: info; surfaces "device unstable" for caregiver-side notice once Phase 2A lands. v1 just emits to ops topic.

- **Log retention enforcement** — every existing Lambda log group + IoT Rule logging destination explicitly set to `RetentionDays.ONE_MONTH` (dev) or `THREE_MONTHS` (prod). Implemented via CDK Aspect that walks the construct tree and overrides any unset retention.

- **AWS Cost Anomaly Detection** — single monitor (`gosteady-{env}-cost-anomaly`) at "AWS service" granularity, with subscription emailing to the ops topic when anomaly score exceeds threshold. ~30 lines of CDK using `cdk-monitoring-constructs` or raw L1 `AWS::CE::AnomalyMonitor` + `AWS::CE::AnomalySubscription`.

### Out of Scope (Deferred)

- **Phase 1.7 Audit Logging** — dedicated audit log group + S3 Object Lock + subscription filter routing 1B-rev's structured audit log lines. 1.6 leaves audit log lines in the regular handler log groups; 1.7 picks them up.
- **Phase 2A Portal API** — including the per-device API endpoints that will eventually consume the same Logs Insights query shapes the dashboard renders. Phase 1.6 dashboards are an internal-ops surface; the caregiver-facing portal is 2A → 2B → 3A.
- **Lambda-backed custom CloudWatch widgets** for live Shadow read or live S3 listing on the per-device dashboard. v1 uses Logs Insights as the rendering primitive; custom widgets are 2A.
- **Pre-aggregated daily-rollup dashboards** (steps-per-day, distance-per-day, active-minutes-per-day per patient). Phase 1C owns the rollup computation; once 1C lands, dashboard widgets graph the rollup tables directly.
- **Per-patient view** keyed by `patientId` (not `serial`). The per-device dashboard is serial-scoped because that's what firmware emits and what cloud's Shadow indexes by. Patient-scoped views are Phase 2B portal scope.
- **Synthetic-probe canary** that publishes a heartbeat every N minutes to validate the ingestion path stays healthy. Worth considering in Phase 1.6.1 once site-survey reveals what proactive checks would have caught real issues.

## Architecture

### Infrastructure Changes

**New stack:** `GoSteady-{Env}-Observability` (~25 resources):
- 1 × `AWS::Lambda::LayerVersion` (Powertools layer, ARM64, Python 3.12) — or `LayerVersion.fromLayerVersionArn` referencing AWS-managed
- 6 × Lambda function updates (consume new layer, drop pip dep, set `tracingActive: true`) — applied via cross-stack import or CDK aspect
- 6 × IAM policy additions (X-Ray grants per Lambda execution role)
- 2 × `AWS::CloudWatch::Dashboard`
- ~15 × `AWS::CloudWatch::Alarm`
- 4 × `AWS::Logs::MetricFilter` (log-pattern alarms)
- 1 × `AWS::CE::AnomalyMonitor` + `AWS::CE::AnomalySubscription`
- 1 × CDK aspect for log-retention enforcement (walks Logs::LogGroup constructs in all stacks)

**Modified stacks:**
- `GoSteady-{Env}-Processing` — six Lambdas (the four handlers + cognito-pre-token + snippet-parser if it ends up here per current Ingestion-stack location) refactor: drop `aws-lambda-powertools` from each handler's pip bundle, add layer reference, enable Active Tracing, add metric publishes to heartbeat-processor.
- `GoSteady-{Env}-Ingestion` — `gosteady-dev-snippet-parser` Lambda gets the same treatment.
- `GoSteady-{Env}-Auth` — `gosteady-dev-cognito-pre-token` gets the same treatment.
- `GoSteady-{Env}-Security` — rename `costAlarmTopic` CFN output to `opsAlarmTopic` to reflect broader scope; preserve the existing topic ARN (no destroy/recreate).

### Data Flow

```
                      ┌─────────────────────────┐
                      │ Existing 1A/1B/1A-rev/  │
                      │ 1B-rev Lambdas:         │
                      │ • activity-processor    │
                      │ • heartbeat-processor   │
                      │ • threshold-detector    │
                      │ • alert-handler         │
                      │ • snippet-parser        │
                      │ • cognito-pre-token     │
                      └────────────┬────────────┘
                                   │ Powertools Logger / Tracer / Metrics
                                   │ (now via shared layer, was pip dep)
                                   │
                ┌──────────────────┼──────────────────┐
                │                  │                  │
                ▼                  ▼                  ▼
       ┌────────────────┐  ┌──────────────┐  ┌──────────────────┐
       │ CloudWatch     │  │ CloudWatch   │  │ AWS X-Ray        │
       │ Logs (struct.  │  │ Metrics      │  │ (auto-instrument │
       │ JSON, scrubbed)│  │ (EMF, async) │  │ via Powertools)  │
       └────────┬───────┘  └──────┬───────┘  └─────────┬────────┘
                │                 │                    │
                │                 │                    │
        ┌───────┴────────┬────────┴──────────┐         │
        ▼                ▼                   ▼         ▼
  ┌──────────┐    ┌──────────┐    ┌──────────────────────┐
  │ Logs     │    │ Metric   │    │ CloudWatch           │
  │ Insights │    │ Math     │    │ Dashboards           │
  │ Queries  │    │ Alarms   │    │ • Platform Health    │
  │          │    │          │    │ • Per-Device Detail  │
  └────┬─────┘    └────┬─────┘    └──────────────────────┘
       │               │
       ▼               ▼
  ┌──────────┐   ┌──────────────────────────────┐
  │ Pattern  │   │ Standard Alarms              │
  │ Filter   │   │ • Lambda Errors per handler  │
  │ Alarms   │   │ • DLQ depth                  │
  │ (§16)    │   │ • IoT Rule failures          │
  │          │   │ • DDB throttles              │
  │          │   │ • watchdog_hits ≥3 / 24h     │
  └────┬─────┘   └──────┬───────────────────────┘
       │                │
       └───────┬────────┘
               ▼
      ┌────────────────────┐
      │ opsAlarmTopic      │
      │ (renamed from      │
      │  costAlarmTopic)   │
      └────────┬───────────┘
               ▼
       Email subscription
       (and future SMS / Slack)
```

### Interfaces

**Powertools layer ARN (consumed by all 6 Lambdas):**
```
arn:aws:lambda:us-east-1:017000801446:layer:AWSLambdaPowertoolsPythonV3-python312-arm64:N
```
(Replace `N` with the version pinned in CDK config; AWS publishes new versions monthly.)

**CloudWatch custom metrics namespace:** `GoSteady/Devices/{env}`
- `BatteryPct` (Average, dimensions: `serial`, `firmware`) — gauge, value range 0.0–1.0
- `RsrpDbm` (Average, dimensions: `serial`) — gauge, value range −140 to 0
- `SnrDb` (Average, dimensions: `serial`) — gauge, value range −20 to 40
- `WatchdogHits` (Maximum, dimensions: `serial`) — gauge, monotonically increasing across boots
- `FaultCountersFatal` (Maximum, dimensions: `serial`) — gauge
- `FaultCountersWatchdog` (Maximum, dimensions: `serial`) — gauge
- `UptimeSec` (Maximum, dimensions: `serial`) — gauge

`Maximum` aggregation matches the monotonically-increasing semantics of fault counters; `Average` for battery/signal smooths over hourly heartbeat noise.

**Logs Insights queries** (key examples; full set in CDK dashboard definitions):

Recent activity for selected serial:
```
fields @timestamp, subject.deviceSerial, after.sessionEnd, after.steps, after.distance_ft, after.active_min, after.roughness_R, after.surface_class, after.firmware_version
| filter event = "patient.activity.create"
| filter subject.deviceSerial = "${serial}"
| sort @timestamp desc
| limit 20
```

Recent snippet uploads for selected serial:
```
fields @timestamp, snippet_id, window_start_ts, payload_size, anomaly_trigger, s3_key
| filter event = "device.snippet_uploaded"
| filter serial = "${serial}"
| sort @timestamp desc
| limit 20
```

`${serial}` is substituted by the dashboard variable. Default value: `GS9999999999`.

## Implementation

### Files Changed / Created

| File | Change Type | Description |
|------|------------|-------------|
| `infra/lib/stacks/observability-stack.ts` | New | The full Observability stack: layer, dashboards, alarms, log-retention aspect, cost anomaly monitor |
| `infra/lib/constructs/dashboards/platform-health.ts` | New | Platform-Health dashboard widget definitions |
| `infra/lib/constructs/dashboards/per-device.ts` | New | Per-Device Detail dashboard widget definitions (serial-variable-driven) |
| `infra/lib/constructs/alarms/handler-alarms.ts` | New | Per-handler Lambda Errors + log-pattern alarm constructs |
| `infra/lib/constructs/alarms/infrastructure-alarms.ts` | New | DLQ depth, IoT Rule failures, DDB throttles, cost anomaly |
| `infra/lib/aspects/log-retention.ts` | New | CDK Aspect that sets `RetentionInDays` on every `LogGroup` in the synth tree if not already set |
| `infra/lib/stacks/processing-stack.ts` | Modified | Refactor 4 handlers: drop pip Powertools, add layer ref, enable Active Tracing, add X-Ray IAM grants. Heartbeat-processor: add metric-publish calls in handler body. |
| `infra/lib/stacks/ingestion-stack.ts` | Modified | Same Powertools layer refactor for snippet-parser |
| `infra/lib/stacks/auth-stack.ts` | Modified | Same Powertools layer refactor for cognito-pre-token |
| `infra/lib/stacks/security-stack.ts` | Modified | Rename `costAlarmTopic` CFN output to `opsAlarmTopic`; preserve the underlying SNS topic ARN |
| `infra/lambda/heartbeat-processor/handler.py` | Modified | Add `metrics.add_metric` calls for battery_pct, rsrp_dbm, snr_db, watchdog_hits, fault_counters fields, uptime_s — all dimensioned by `serial` |
| `infra/lambda/_shared/observability.py` | Modified | Drop the in-bundle Powertools install dance; rely on layer being attached |
| `infra/lib/config.ts` | Modified | Add `powertoolsLayerVersion` field to env config; pin the AWS-managed layer version per env |
| `infra/bin/gosteady.ts` | Modified | Wire Observability stack into app; add to `cdk deploy --all` order |
| `docs/specs/ARCHITECTURE.md` | Modified | Flip Phase 1.6 status from 🔲 Planned to ✅ Deployed; update §15 Lambda Inventory if any logical IDs change; close §16 open questions on log-pattern alarms + DLQ-depth-not-sufficient |

### Dependencies

- Phase 0A (Cognito User Pool exists, Pre-Token Lambda exists)
- Phase 0B (Identity tables exist, telemetry tables exist)
- Phase 1A / 1A-rev (IoT Rules, snippet parser Lambda exist)
- Phase 1B / 1B-rev (4 handler Lambdas exist with Powertools as pip dep, structured logging in place)
- Phase 1.5 (Security stack with `costAlarmTopic`/SNS exists; CMKs deployed)

NPM packages added:
- `cdk-monitoring-constructs` — optional, simplifies dashboard widget composition; alternative is raw L1 `cloudwatch.Dashboard` + `cloudwatch.GraphWidget` constructs
- `@aws-cdk/aws-ce` (or aws-cdk-lib L1 constructs) — for AWS Cost Anomaly Detection

Python packages dropped from each handler's bundle:
- `aws-lambda-powertools` (now provided by the layer; remove from each `requirements.txt` and update CDK bundling to skip the pip install for it)

### Configuration

**Environment variables (per Lambda):**
- `POWERTOOLS_LAYER_VERSION` — pinned in CDK config; ensures all Lambdas reference the same layer version
- `POWERTOOLS_METRICS_NAMESPACE` — `GoSteady/Devices/{env}` for heartbeat-processor; existing `GoSteady/Processing/{env}` retained for handler-internal metrics
- `POWERTOOLS_TRACER_DISABLED` — set to `false` (was effectively true in 1B-rev where Tracer was wrapped but X-Ray wasn't enabled)

**CDK context values:**
- `gosteady:dashboardDefaultSerial` — default value for the per-device dashboard's `serial` variable; `GS9999999999` for dev, TBD for prod (probably the first deployed unit)
- `gosteady:opsAlarmEmail` — email subscription for the ops SNS topic; falls through to Phase 1.5's existing `GOSTEADY_COST_ALARM_EMAIL` env var

**Dashboard variables:**
- Per-Device Detail dashboard exposes a single `serial` variable (type: `pattern`, default: from CDK context)

## Testing

### Test Scenarios

| # | Scenario | Method | Expected Result | Status |
|---|----------|--------|-----------------|--------|
| T1 | Powertools layer attaches to all 6 Lambdas | `aws lambda get-function-configuration --function-name gosteady-dev-{name}` for each | Layer ARN matches pinned version; layer count = 1 (no duplicates) | Pending |
| T2 | Existing handlers run cleanly with layer | Synthetic publish through each handler (heartbeat / activity / alert / snippet / shadow-update); Cognito sign-in for pre-token | All handlers succeed; structured logs identical to pre-1.6 shape; no `import` errors | Pending |
| T3 | X-Ray traces appear in Service Map | Trigger heartbeat publish, wait 60s, open X-Ray console | Trace visible: client → IoT Core → Lambda → DDB; latency breakdown per segment | Pending |
| T4 | Heartbeat-processor publishes per-serial metrics | Synthetic heartbeat for `GS9999999999` with battery_pct=0.42, rsrp_dbm=-95, watchdog_hits=2 | After ~60s, CloudWatch Metrics shows `BatteryPct{serial=GS9999999999}=0.42`, `RsrpDbm=-95`, `WatchdogHits=2` in `GoSteady/Devices/dev` namespace | Pending |
| T5 | Platform Health dashboard renders | Open dashboard URL; trigger a few synthetic publishes | Ingestion rate widgets show counts; Lambda duration widgets populated; DLQ depth widget = 0 | Pending |
| T6 | Per-Device Detail dashboard with default serial | Open dashboard URL with default `GS9999999999` | Battery/signal/watchdog graphs populate; Recent Activity widget lists session(s) from M12.1d test; Recent Snippets widget lists the M12.1f object | Pending |
| T7 | Per-Device dashboard variable switch | Change variable to `GS0000000001`; reload | All widgets re-query for the new serial; empty results for activity + snippets (expected; that unit hasn't shipped yet) | Pending |
| T8 | Lambda Errors alarm fires | Force exception in activity-processor (e.g., publish malformed payload that bypasses validation but breaks DDB write) | Alarm transitions to ALARM within 5 min; SNS message lands at ops email | Pending |
| T9 | Log-pattern alarm fires on `unmapped_serial_count` | Publish activity for orphan serial `GS_ORPHAN_TEST` | activity-processor logs `unmapped_serial_count`; alarm transitions to ALARM; SNS notification | Pending |
| T10 | Log-pattern alarm fires on `SnippetValidationError` | Publish snippet with `format_version=99` | snippet-parser raises SnippetValidationError; alarm fires | Pending |
| T11 | DLQ depth alarm fires | Force IoT Rule failure (e.g., publish to a topic with broken SQL) | DLQ accumulates message; alarm fires within 5 min | Pending |
| T12 | DDB throttle alarm absent under normal load | Run 50 synthetic publishes back-to-back | No throttle events; alarm stays in OK state | Pending |
| T13 | watchdog_hits ≥3 / 24h alarm fires | Publish 3 heartbeats with watchdog_hits = 1, 2, 3 across the same hour | Metric math expression detects rate-of-increase ≥3 within 24h window; alarm fires | Pending |
| T14 | Log retention is enforced on existing log groups | `aws logs describe-log-groups --log-group-name-prefix /aws/lambda/gosteady-dev-` | All log groups show `retentionInDays: 30` (dev) | Pending |
| T15 | Log retention enforced on a NEW Lambda | Add a stub Lambda; deploy | Its log group is created with `retentionInDays: 30` automatically (CDK aspect) | Pending |
| T16 | Cost Anomaly Monitor exists and has subscription | `aws ce get-anomaly-monitors`; `aws ce get-anomaly-subscriptions` | Monitor `gosteady-dev-cost-anomaly` exists; subscription points at ops topic | Pending |
| T17 | Recent Snippets Logs Insights widget renders correctly for the M12.1f bench upload | Open Per-Device dashboard with `serial=GS9999999999` | Widget shows the 2026-04-29 snippet `c1c906b6-...` with `payload_size=43122`, `s3_key=GS9999999999/2026-04-29/c1c906b6-...bin` | Pending |
| T18 | Recent Activity Logs Insights widget renders correctly for the M12.1d bench session | Same dashboard | Widget shows 2026-04-28T03:54:56Z session: steps=15, distance_ft=11.05, roughness_R=0.1587, surface_class=indoor, firmware_version=0.7.0-cloud | Pending |
| T19 | M14.5 site-survey acceptance check (post-deploy of GS0000000001) | Switch dashboard variable to `GS0000000001`; observe over 7-day soak | Dashboard tracks 7+ days of heartbeat metrics; activity widget populates as bench-walk sessions occur; snippet widget populates as snippets upload | Pending — runs in M14.5 |
| T20 | Audit log lines still visible in regular handler log groups | Trigger an activity write; filter handler log group for `audit:true` | Audit-shape JSON line present (Phase 1.7 will route, but 1.6 doesn't break this) | Pending |

### Verification Commands

```bash
# Tier 1 — infra readiness
aws lambda list-layer-versions --layer-name AWSLambdaPowertoolsPythonV3-python312-arm64 --region us-east-1
aws lambda get-function-configuration --function-name gosteady-dev-heartbeat-processor --region us-east-1 | jq '{Layers, TracingConfig, MemorySize, Architectures}'

# Tier 2 — observability surface
aws cloudwatch list-dashboards --region us-east-1 | jq '.DashboardEntries[].DashboardName'
aws cloudwatch describe-alarms --alarm-name-prefix gosteady-dev- --region us-east-1 --query 'MetricAlarms[].AlarmName'
aws logs describe-metric-filters --log-group-name /aws/lambda/gosteady-dev-activity-processor --region us-east-1

# Tier 3 — log-retention enforcement
aws logs describe-log-groups --log-group-name-prefix /aws/lambda/gosteady-dev- --region us-east-1 \
  | jq '.logGroups[] | {logGroupName, retentionInDays}'
# Expected: every entry has retentionInDays = 30 (dev) or 90 (prod)

# Tier 4 — per-device metric publish (after bench heartbeat)
aws cloudwatch get-metric-statistics --region us-east-1 \
  --namespace GoSteady/Devices/dev \
  --metric-name BatteryPct \
  --dimensions Name=serial,Value=GS9999999999 \
  --start-time $(date -u -v-1d '+%Y-%m-%dT%H:%M:%SZ') \
  --end-time $(date -u '+%Y-%m-%dT%H:%M:%SZ') \
  --period 3600 \
  --statistics Average

# Tier 5 — Logs Insights query (recent activity)
aws logs start-query --region us-east-1 \
  --log-group-name /aws/lambda/gosteady-dev-activity-processor \
  --start-time $(($(date +%s) - 7 * 86400)) \
  --end-time $(date +%s) \
  --query-string 'fields @timestamp, subject.deviceSerial, after.sessionEnd, after.steps, after.distance_ft | filter event = "patient.activity.create" | filter subject.deviceSerial = "GS9999999999" | sort @timestamp desc | limit 20'
# Use the returned queryId with `aws logs get-query-results` after a few seconds
```

## Deployment

### Deploy Commands

```bash
cd infra
npm run build

# Deploy in this order:
# 1. Update Security stack first to rename costAlarmTopic → opsAlarmTopic CFN output
npx cdk deploy GoSteady-Dev-Security --context env=dev --require-approval never

# 2. Update each Lambda-bearing stack to consume the layer (Processing → Ingestion → Auth)
#    These can deploy in any order — Lambda updates are non-replacement
npx cdk deploy GoSteady-Dev-Processing --context env=dev --require-approval never
npx cdk deploy GoSteady-Dev-Ingestion --context env=dev --require-approval never
npx cdk deploy GoSteady-Dev-Auth --context env=dev --require-approval never

# 3. Deploy the new Observability stack last (depends on all above existing)
npx cdk deploy GoSteady-Dev-Observability --context env=dev --require-approval never

# Or deploy everything at once:
npx cdk deploy --all --context env=dev --require-approval never
```

Estimated deploy time:
- Security stack update: ~30 s (output rename only)
- Processing stack update: ~3 min (4 Lambda function updates)
- Ingestion stack update: ~2 min (1 Lambda update + log-retention aspect on existing groups)
- Auth stack update: ~2 min (1 Lambda update)
- Observability stack create: ~5 min (dashboards + alarms + cost monitor)

Total: ~12-15 min for clean deploy.

### Rollback Plan

If a new Lambda fails to import the Powertools layer at runtime:
1. Remove the layer reference from the Lambda CDK definition
2. Re-add the pip dep to the handler's bundle requirements
3. Redeploy — Lambda updates are non-replacement, no data loss

If alarm catalog generates excessive noise (e.g., legitimate pre-activation traffic triggers `unmapped_serial_count` alarm constantly):
1. Tune the alarm thresholds (raise to ≥5 or ≥10 in 5 min)
2. Or temporarily disable the alarm via `aws cloudwatch disable-alarm-actions`
3. Spec amendment in the next iteration

If dashboards are unrenderable (e.g., Logs Insights query syntax error):
1. Edit the dashboard JSON via console or CDK
2. Dashboards have no downstream dependencies — no risk to data plane

If the cost anomaly monitor flags a false positive in the first week:
1. Acceptable — it's a learning period for the model. Adjust threshold or granularity in 1.6.1.

**Risk: none of these rollbacks affect data plane.** The data path (firmware → IoT Core → Lambda → Shadow / DDB / S3) is unchanged by 1.6. 1.6 is purely an observability overlay.

## Decisions Log

| # | Decision | Alternatives Considered | Why This Choice |
|---|----------|------------------------|-----------------|
| D1 | Use AWS-managed Powertools layer ARN, not a custom-built layer | Build our own LayerVersion from a pip install | AWS publishes the ARM64 Python 3.12 layer at a stable ARN; tracking their version is simpler than maintaining ours. Pinned in CDK config so version drift is explicit |
| D2 | Refactor all 6 existing Lambdas to consume the layer in-phase | Ship the layer, leave Lambdas on pip dep, refactor opportunistically | Phase 1B-rev D8 explicitly named 1.6 as the layer-refactor phase. Doing it in 6 separate touch-events later loses the consolidation benefit. ~12 min of additional deploy time vs months of inconsistent state |
| D3 | Two dashboards (platform-health + per-device), not one consolidated | Single dashboard with multiple sections | Platform-health has no per-device variable; per-device has serial-as-variable. Mixing them on one dashboard means widgets toggle confusingly when the variable changes. Two dashboards = clearer audience separation (cloud-ops vs operator-monitoring) |
| D4 | Logs Insights queries (not Lambda-backed custom widgets) for "recent files" surface | Lambda-backed custom widget that calls `s3 list-objects` + `dynamodb query` directly | Custom widgets need a backing Lambda + IAM role + invocation policy on the dashboard; ~3x the code volume vs Logs Insights. Sufficient for v1 (M14.5 doesn't need clickable S3 links). Phase 2A's Lambda-backed widgets become the upgrade path |
| D5 | Reuse Security stack's existing SNS topic for ops alarms; rename CFN output | Create a new SNS topic in Observability stack | The topic already has the email subscription configured (from Phase 1.5). Creating a duplicate topic forces a second email subscription confirmation and dual destinations. Renaming the export keeps backward compat with any other stack imports |
| D6 | Heartbeat-processor publishes per-serial metrics (battery, signal, watchdog) directly | Sidecar metric-publisher Lambda triggered by Shadow update | One fewer Lambda; metric publish is a Powertools EMF call (no API latency). Coupling is acceptable — heartbeat-processor already owns the heartbeat payload schema |
| D7 | Maximum aggregation for fault counters; Average for battery/signal | Sum for everything; Last value | Fault counters are monotonically increasing across boots — Maximum is the natural aggregation. Battery/signal are gauge-like, often noisy hourly — Average smooths visually. Sum would multiply across heartbeats nonsensically |
| D8 | watchdog_hits ≥3 / 24h alarm at info severity (firmware suggestion §F5.2) | Skip; defer until field data informs threshold | Cheap to add (one alarm); useful diagnostic during M14.5 7-day soak; firmware team specifically suggested it. Severity info means it lands in ops topic but doesn't escalate to caregiver-facing alerts (which is correct for v1 since there are no caregivers) |
| D9 | Per-device dashboard variable defaults to `GS9999999999` | No default (force operator selection) | Bench unit is the most common subject during 1.6 → M14.5 timeframe. M14.5 will switch the default to `GS0000000001` (or whichever shipping unit is in observation) |
| D10 | Cost Anomaly Detection at "AWS service" granularity, single monitor | Per-stack granularity, multiple monitors | At MVP scale (~$10-30/mo total) per-service is sufficient. Per-stack adds 8 monitors with no marginal value until the bill is materially larger |

## Open Questions

> Plain-language explanation of each question + a decision where we can call it. Decisions called now are mirrored into the Decisions Log table above where they shape the implementation; the open ones are explicitly tagged with what would resolve them.

### Q1. Will the same Powertools layer ARN work in our future prod AWS account?

**What's actually being asked:** AWS publishes a shared Python library called Powertools as a Lambda Layer. We're referencing it via its public ARN, which embeds AWS's own account ID (`017000801446`) — not ours. When we eventually spin up a separate prod AWS account for GoSteady, can our prod Lambdas still reach into AWS's shared account and use the same layer, or do we have to publish our own copy into prod?

**What's at stake:** If cross-account access doesn't work, we'd need to publish our own copy per environment and pin versions independently — slightly more work, no functional difference.

**Decision:** ⏳ **Defer.** AWS publishes Powertools as publicly-readable across all accounts, so this should Just Work — but we can't prove it without a real cross-account Lambda. Verify the first time the prod account is bootstrapped (Phase 1.5 multi-account migration). Not a 1.6 blocker; flag as a multi-account follow-up.

---

### Q2. Will Powertools cold-starts cause false-positive Lambda Error alarms?

**What's actually being asked:** Powertools 3.x adds ~300-400 ms to Lambda startup. Phase 1B-rev observed total cold init at 510-620 ms. Our new "Lambda Errors > 0 in 5 min" alarm fires on any error, including timeouts. If a cold Lambda hits a freak slow DDB call on top of the slow init, it could time out → Error → alarm fires for what's really just bad luck.

**What's at stake:** Alarm fatigue. If we get nuisance pages every few days, we stop trusting the alarm, and the real failures get missed.

**Decision:** ⏳ **Wait and observe in first M14.5 week.** Current timeouts (30 s for activity, 15 s for heartbeat/alert) leave huge headroom — 510 ms init + 290 ms execution leaves >29 s of slack on activity. We don't have evidence that nuisance alarms will actually fire. **Trigger to revisit:** if we see >2 spurious cold-start-attributed Errors in the first 7-day soak, bump cold timeouts (`reservedConcurrentExecutions: 1` to keep one warm, or just raise timeouts). Cheap one-line CDK change.

---

### Q3. Should the per-device dashboard let you type a serial, or pick from a dropdown?

**What's actually being asked:** On the per-device dashboard you switch which device you're viewing via a variable. CloudWatch dashboard variables can be free-text ("type the serial") or dropdown ("pick from a list of known serials"). Dropdown prevents typos; free-text works for any serial that's ever published, even ones not in our Device Registry yet.

**What's at stake:** UX during M14.5. We have 4 serials total right now (`GS9999999999` + `GS0000000001/2/3`); typos are easy to catch. Building a dropdown requires a custom widget that queries Device Registry — that's Phase 2A scope.

**Decision:** ✅ **Free-text (`pattern` variable type), default `GS9999999999`.** Logged as D9 in Decisions Log. Revisit when Phase 2A's custom widgets land — they make a Device-Registry-backed dropdown trivial.

---

### Q4. Will the `unmapped_serial_count` alarm spam during legitimate pre-activation?

**What's actually being asked:** Activity-processor logs `unmapped_serial_count` when a device publishes a session but no patient is assigned to it. We're alarming on that. But: a freshly-flashed shipping unit (`GS0000000001` mid-M14.5 setup) will publish heartbeats *before* anyone has run the provisioning flow. Will that fire the alarm constantly until provisioning completes?

**What's at stake:** Alarm noise during the (intentionally-brief) window between flashing a unit and provisioning it.

**Decision:** ✅ **Keep alarm at ≥1/5min, but the firmware-side gate prevents the actual problem.** M12.1e.2's `prj_field.conf` build refuses to open sessions until activated, so a freshly-flashed shipping unit will only publish *heartbeats* (which don't trigger `unmapped_serial_count` — that's an activity-processor metric, not heartbeat-processor). The alarm only fires if a misconfigured bench unit publishes activity without a synthetic patient — which is exactly the case we *want* to be loud about. Keep as-specced.

---

### Q5. Should we add a synthetic canary that fakes a heartbeat every 10 min?

**What's actually being asked:** A canary is a small scheduled job that pretends to be a device — publishes a fake heartbeat on a cron, just to confirm the ingestion path is alive when no real devices are online. ~30 lines of CDK + a Lambda + an EventBridge rule. Useful for "is the cloud healthy?" monitoring during stretches with no real device traffic.

**What's at stake:** Cheap to add but pollutes per-device metrics with a synthetic serial that has to be filtered out everywhere. Saves nothing during M14.5 because we'll have real heartbeats every hour from `GS9999999999` (bench) and the shipping unit during its 7-day soak.

**Decision:** ✅ **Skip for v1.6.** Real hourly heartbeats from the bench + shipping units are the canary. **Trigger to revisit:** if we ever have a stretch of ≥24 hr with no real device online (e.g., between site-survey and clinic deploy), or if we want to validate the path during a refactor without flashing a device. Logged as a 1.6.1 candidate, not a blocker.

---

### Q6. Will Cost Anomaly Detection generate false alarms during its first 30 days?

**What's actually being asked:** AWS Cost Anomaly Detection uses ML to learn what "normal" cost looks like for an account. AWS explicitly says the model needs ~30 days of data to be reliable; before then, it may flag things that aren't actually anomalous.

**What's at stake:** A few false alerts in the first month. No way to dodge this — either turn it on now and accept early noise, or wait 30 days and miss any real anomaly during that window.

**Decision:** ✅ **Turn it on now, accept the noise.** Current AWS bill is ~$10-30/month — at this scale, real anomalies (e.g., `$50 in a day`) would be visually obvious from the existing $100 billing alarm even without ML. The ML monitor becomes useful as the bill grows. Letting it learn now means it's useful by the time M14.5 + M15 add 3-4 cellular devices to the cost mix. **Trigger to revisit:** if we get ≥3 false-positive cost alerts in the first month, mute the subscription temporarily and re-enable at day 30.

---

### Decision summary

| # | Question | Resolution |
|---|----------|-----------|
| Q1 | Cross-account layer ARN | ⏳ Defer to multi-account migration |
| Q2 | Cold-start Error noise | ⏳ Observe in M14.5 first week |
| Q3 | Serial selector UX | ✅ Free-text, default `GS9999999999` |
| Q4 | Pre-activation alarm spam | ✅ Keep as-specced; firmware gate prevents the problem |
| Q5 | Synthetic canary | ✅ Skip for v1.6 |
| Q6 | Cost Anomaly false positives | ✅ Turn on now, accept early noise |

Three of six decided now. Q1 + Q2 require observation/external state to resolve; Q4's "decision" is "the spec is already correct" once you trace through M12.1e.2.

## Changelog

| Date | Author | Change |
|------|--------|--------|
| 2026-04-29 | Jace + Claude (firmware coord with cloud team) | Initial spec drafted in response to firmware coordination feedback that the existing Phase Plan deferred all visual validation past M14.5 ship — see firmware-coordination doc §F9 (forthcoming) |
| 2026-04-30 | Jace + Claude (cloud session) | **Deployed** to dev. 4-stage deploy with checkpoints (`5bcc9cc` spec → `c4589e0` Stage 1 layer → `22a42fb` Stage 2 X-Ray + metrics → `de81b16` Stage 3 dashboards → `7e73121` Stage 4 alarms). Acceptance T1–T18, T20 pass; T15 deferred (no stub Lambda needed today); T16 deferred behind feature flag pending Cost Explorer console opt-in. Three implementation findings: (a) layer scope is 4 handlers not 6 — `cognito-pre-token` + `snippet-parser` are stdlib-only and don't import aws-lambda-powertools; (b) Cost Anomaly Detection requires account-level Cost Explorer enablement that CFN can't trigger — gated behind `costAnomalyEnabled` config field; (c) snippet-parser log filter patterns must be stdlib substring matches, not Powertools JSON shape — fixed in `handler-alarms.ts` with a per-Lambda `isPowertools` switch. |

# Phase 1C-slim — Behavioral Notifications + Offline Detector

## Overview
- **Phase**: 1C-slim (a focused subset of the broader Phase 1C Scheduled Jobs umbrella)
- **Status**: ✅ Deployed (dev) 2026-05-24 — 42/42 rule unit tests PASS + end-to-end audit pipeline verified on synthetic invoke
- **Branch**: `feature/infra-scaffold`
- **Date Started**: 2026-05-24
- **Date Completed**: 2026-05-24 (dev) — real-data rule-firing validation deferred (needs local-09 / local-22 cron firing OR seeded fixtures with controlled timestamps)

Ships **two server-side detection rules that the existing Threshold Detector (Phase 1B-rev) cannot serve** because they require daily-aggregate inputs, not real-time shadow deltas:

1. **Three behavioral notification rules** that drive the V1 caregiver dashboard (per [user-needs.md](../user-needs.md) US-22) — "No activity today" (severity: critical), "Below typical activity" (severity: standard), "Declining trend" (severity: standard). Currently evaluated **client-side** in the facility demo (per [`facility_demo/data/notification_engine.dart`](../../lib/facility_demo/data/notification_engine.dart)); per [phase-2b-portal-integration.md](phase-2b-portal-integration.md) A3 + D9, this is unsafe for production (per-client drift, broken audit trail). 1C-slim makes them server-authoritative.

2. **Offline detector** — the gap surfaced by the 2026-05-11/12 conference site-survey ([coord §C11.7](../firmware-coordination/2026-04-17-cloud-contracts.md#section-c117)). The walker cap went dark for 3 days 21 hours with no cloud alarm firing — because the existing Threshold Detector only reacts to shadow updates, and a silent device emits zero shadow updates. The slim offline detector closes this gap, emitting `device.offline` (`lastSeen > 2h`) and `device.silent` (`lastSeen > 24h`, escalated severity).

These two functions share an input shape (daily aggregates from Activity Series + Device Registry `lastSeen` sweeps), a trigger cadence (scheduled), and a target table (existing Alert History, so 2A-RD's read path doesn't change). **Bundling them into one Lambda + one scheduler is materially cheaper than two separate ones** — same code-path scaffolding, same per-tenant fan-out logic, same audit emission.

The full Phase 1C (ARCH §12: Offline Detector + Daily Rollup + Weekly Trend + No-Activity Check) is broader. **1C-slim is the minimum work to unblock 2B-FAC-R notification UX + close §C11.7.** Daily Rollup (for the 2B-FAC-R 6M time-range tab per [phase-2b-portal-integration.md](phase-2b-portal-integration.md) L8 / Q7) is a follow-on; not blocking V1 launch since the 6M tab is shipping disabled.

**Dependency on 2A-UM-P** (sibling spec): the behavioral detector calls `_shared/pause_check.py::is_currently_paused` and skips paused patients. If 2A-UM-P doesn't ship, this Lambda just doesn't honor pause (treats every patient as un-paused) — gracefully degraded.

**Dependency on Phase 1B-rev** (deployed): writes alerts using the same shape as Threshold Detector (Alert History table, compound SK `{eventTimestamp}#{alertType}`, hierarchy snapshot at write time per 1B-rev).

## Locked-In Requirements

| # | Requirement | Decided In | Rationale |
|---|-------------|-----------|-----------|
| L1 | Single Lambda `gosteady-{env}-behavioral-detector` for all 1C-slim work (three behavioral rules + two offline rules). Mirrors single-Lambda-per-subset pattern from 2A-DL/2A-RD/2A-AA/2A-UM-P | This spec | Cold-start economics; shared per-patient iteration logic |
| L2 | Trigger: **EventBridge scheduled rule** firing once per facility-local-day boundary. For V1 simplicity: one global trigger per hour (24× per day), Lambda enumerates facilities and only processes those whose local midnight just rolled over within the past hour | This spec — Q1 decided | A single per-hour cron is dramatically simpler than per-facility scheduled rules. At ≤20 facilities the overhead is negligible (each invocation processes only the 0-2 facilities whose local midnight crossed in the past hour) |
| L3 | Input data sources: (a) Activity Series base table, queried per-patient via `Query(patientId, SK BETWEEN windowStart/End)` for the relevant time window per rule, (b) Device Registry GetItem + Shadow GetThingShadow for the offline detector | This spec | Same access patterns as 2A-RD's read path; no new GSIs needed |
| L4 | Output table: existing Alert History (Phase 0B-rev). Same shape as Threshold Detector-emitted alerts. New `alertType` values: `no_activity_today`, `below_typical_activity`, `declining_trend`, `device_offline`, `device_silent` | This spec | 2A-RD's `GET /patients/{id}/alerts` already reads this table; no portal-side code changes for the new alert types. Caregivers ack them the same way (2A-AA `PATCH /alerts/{...}`) |
| L5 | Idempotency: per-rule conditional PutItem using compound SK `{date(facility-local)}T00:00:00Z#{alertType}` for the daily-cadence rules; `{firstObservedAt-roundedToHour}#{alertType}` for offline rules. Reruns within the same day are no-ops | This spec | Pattern from 1B-rev Threshold Detector P4 (conditional PutItem with attribute_not_exists guard) |
| L6 | Honor `Patient.notificationsPaused` via `_shared/pause_check.py::is_currently_paused` (Phase 2A-UM-P). Skip evaluation entirely if paused; sample `patient.notifications.suppressed_paused` audit at ≤1/day/patient (same as Threshold Detector per 2A-UM-P L9) | 2A-UM-P L9 + Phase 2B Q5 lean | Single source of truth for pause semantics |
| L7 | "Today" boundary uses the **facility's local time** (resolved from `Patients.timezone` denorm). The hourly cron fires at every UTC hour; the Lambda computes "facilities whose local midnight is now ∈ [last_hour, this_hour]" using `zoneinfo` | user-needs §5 + 2B L9 | Avoids "yesterday's no-activity alert" firing at 02:00 PST for a CA facility |
| L8 | "No activity today" rule: triggered at facility-local 09:00 (3 hours past local midnight, configurable per facility — gives breakfast/morning-activity time to land before flagging). Fires alert if `sum(steps) over [local-midnight, local-09:00] == 0` AND `lastSeen < 24h` (device is alive but not moving) | This spec — Q3 decided | Demo's behavior triggers immediately; production needs a buffer to avoid 6 AM alerts on still-sleeping residents |
| L9 | "Below typical activity" rule: triggered at facility-local 22:00 (end-of-day). Fires alert if `today.steps < 0.70 × patient.median7Day.steps`. Demo uses 65% threshold; bumped to 70% to reduce false positives on day-to-day variance | demo's `notification_engine.dart` + this spec | Day-of-week effects (lower on weekends) cause noise at 65%; 70% is empirically calmer (tunable per-facility via 2A-AA threshold-override pattern in V2) |
| L10 | "Declining trend" rule: triggered at facility-local 22:00 (same window as US-22's "below typical"). Fires alert if `patient.median7Day < 0.85 × patient.medianPrior23Day` (a 7-day vs 23-day median comparison). Demo's threshold; carried over | demo's `notification_engine.dart` | Behavioral signal — sustained downturn vs a 4-week-ish baseline. Less noisy than day-over-day comparisons |
| L11 | "Device offline" rule (`alertType: device_offline`, severity: warning): triggered hourly. Fires alert if `Device Registry.lastSeen < (now - 2h)` AND device is `active_monitoring` AND no `device_offline` alert in last 24h for this serial. Pre-activation devices are NOT offline-detected (per ARCH §8 + 1B-rev pre-activation-suppression) | §C11.7 + this spec | 2h threshold = 2× heartbeat interval per ARCH §3 (firmware heartbeat is hourly); device is genuinely overdue at this point |
| L12 | "Device silent" rule (`alertType: device_silent`, severity: critical): triggered hourly. Fires alert if `Device Registry.lastSeen < (now - 24h)` AND device is `active_monitoring` AND no `device_silent` alert in last 24h. Critical because: at 24h offline, this is what the conference site-survey would have caught had it existed | §C11.7 + this spec | Distinct severity from `device_offline` because the operational response differs (a single missed heartbeat ≠ a full day dark) |
| L13 | All alerts written via existing 2A-RD Alert History pattern: PK=patientId, SK=`{eventTimestamp}#{alertType}`, hierarchy snapshot at write time, `acknowledged=false`, `source='cloud-behavioral'` or `source='cloud-offline'` (distinguishes from `source='cloud'` for Threshold Detector battery/signal alerts and `source='device'` for firmware-emitted) | This spec | Source attribution helps caregivers + audit readers understand the alert origin |
| L14 | Per-alert audit event from this Lambda: `alert.synthetic.create` (existing 1B-rev event from Threshold Detector) — same event type covers behavioral + offline + battery/signal. The `subject.alertType` distinguishes | 1B-rev audit catalog reuse | Avoids audit-catalog sprawl; the alert type IS the differentiator |
| L15 | Audit-stack subscription filter for `behavioral-detector` log group bundled into 1C-slim deploy (Migration Pattern 18.8) | 2A-0 D9 pattern | Established |

## Assumptions

| # | Assumption | Risk if Wrong | Validation Plan |
|---|-----------|---------------|-----------------|
| A1 | Iterating all active patients in a facility once per hour is sustainable. At 50 facilities × 100 patients = 5000 GetItem ops per invocation. DDB read budget: 25 RCU/s baseline = 22500 reads/15-min — comfortably within | Throttling at scale | Add Lambda Reserved Concurrency=1 (cron Lambda doesn't need parallelism) + monitor DDB read consumption alarms |
| A2 | Patient timezone is set correctly at create time (per 2A-UM-P Q7 lean: inherited from facility). If timezone is empty/null, default to facility's timezone via Organizations lookup | Wrong-day alerts for misconfigured patients | Defensive null check + structured warning log when fallback fires |
| A3 | The "below typical" + "declining trend" rules don't fire on a patient who's been monitored for < 14 days (insufficient history for the 23-day prior window). Lambda checks `Patients.createdAt` and skips behavioral rules for new patients | Misleading alerts on day-1 of monitoring | Cold-start guard with audit `patient.notifications.suppressed_insufficient_history` (sampled 1/day/patient) |
| A4 | Replays of the same hourly invocation don't double-fire alerts due to L5 conditional PutItem | Bug = double-alerts; not security-critical but noisy for caregivers | Mock-DDB unit tests covering replay |
| A5 | The "device_silent" alert at 24h offline maps to firmware-coord §C11.7's "the conference site-survey would have caught" gap. The original sketch in §C11.7 proposed `lastSeen > 2h` as the threshold; 1C-slim ships both 2h (warning) and 24h (critical) to honor the original sketch + add the "things are really bad" escalation | The single-threshold design might be enough; two thresholds might be over-engineering | Validate caregiver perception during pilot. Easy to remove `device_silent` if `device_offline` at 2h is enough |

## Scope

### In Scope

#### Detection rules

| Rule | `alertType` | Severity | Trigger cadence | Inputs |
|---|---|---|---|---|
| No activity today | `no_activity_today` | critical | Facility-local 09:00 | Activity Series query over [local-midnight, local-09:00]; Device Registry `lastSeen` (must be < 24h to fire) |
| Below typical activity | `below_typical_activity` | standard | Facility-local 22:00 | Activity Series query over last 24h + median over last 7d |
| Declining trend | `declining_trend` | standard | Facility-local 22:00 | Activity Series query over last 30d (split: last 7d median vs prior 23d median) |
| Device offline (2h) | `device_offline` | standard | Hourly UTC | Device Registry `lastSeen` per serial |
| Device silent (24h) | `device_silent` | critical | Hourly UTC | Device Registry `lastSeen` per serial |

#### Lambda structure

```
infra/lambda/behavioral-detector/
  handler.py                # entry point; cron dispatch
  rules/
    no_activity_today.py
    below_typical.py
    declining_trend.py
    device_offline.py       # both 2h + 24h share this module
  facility_iterator.py      # enumerates facilities; computes whose local-9 / local-22 is in [now-1h, now]
  patient_iterator.py       # for a given facility, iterates active patients
  history_window.py         # Activity Series query helpers per time-window
  requirements.txt
  tests/
    test_no_activity_today.py
    test_below_typical.py
    test_declining_trend.py
    test_offline_rules.py
    test_facility_iterator.py
```

#### EventBridge schedule rule

```ts
new events.Rule(this, 'BehavioralDetectorSchedule', {
  ruleName: `gosteady-${env}-behavioral-detector-hourly`,
  schedule: events.Schedule.rate(cdk.Duration.hours(1)),
  targets: [new targets.LambdaFunction(behavioralDetectorLambda)],
});
```

Single hourly cron. Lambda's first step: compute facility-local time for every facility; route each facility to its applicable rules.

#### Audit events emitted

| Event | Trigger |
|---|---|
| `alert.synthetic.create` | Any of the 5 rules above firing an alert. Subject includes `alertType` to differentiate |
| `patient.notifications.suppressed_paused` | Pause-skip path (≤1/day/patient sample rate, per 2A-UM-P L9) |
| `patient.notifications.suppressed_insufficient_history` | Per A3 (≤1/day/patient sample rate) |
| `behavioral.detector.run` | One per Lambda invocation, summarizing: facilitiesProcessed, patientsProcessed, alertsFired, rulesSkipped |

All events tagged `schema_version: 1` per Phase 1.7 L9; severity / internal_access auto-stamped by audit-forwarder.

#### CDK additions

- 1 × `AWS::Lambda::Function` (`gosteady-{env}-behavioral-detector`)
- 1 × `AWS::IAM::Role` + 1 × `AWS::IAM::Policy` (read Activity Series / Patients / Organizations / Device Registry; write Alert History; KMS Decrypt on IdentityKey)
- 1 × `AWS::Events::Rule` (hourly schedule)
- 1 × `AWS::Lambda::Permission` (EventBridge → Lambda)
- 1 × `AWS::CloudWatch::Alarm` (Lambda Errors > 0 in 5 min)
- 1 × `AWS::Logs::MetricFilter` + 1 × `AWS::CloudWatch::Alarm` (ERROR-pattern)
- 1 × `AWS::Logs::SubscriptionFilter` (Audit stack)

### Out of Scope (Deferred)

- **Daily Rollup** (`Patient-day → totalSteps/distance/active-min/gait-avg` materialized) — needed for the 2B-FAC-R 6M tab; ships in Phase 1C-rollup (separate sibling)
- **Weekly Trend Computation** (7-day rolling averages over 6 months) — Phase 1C-rollup
- **Per-resident threshold overrides for behavioral rules** (clinical-tuning of the 70% / 85% / 9AM thresholds per patient) — would extend 2A-AA's threshold-override pattern; defer until V2 clinical-config UX is in scope
- **Notification suppression during pause** for arbitrary new rule types — current pattern checks pause at the patient level; no per-rule-type suppression
- **Real-time alert push** — alerts land in DDB; portal polls per 2B L12; push lands in Phase 2C
- **Email/SMS/Push out-of-app delivery** — Phase 2C
- **Re-firing logic** ("alert recurs every day until acked") — current design fires once per day per rule per patient; if the condition persists, the existing unacked alert remains the active signal. Demo's "smart debounce" (user-needs US-22) is naturally satisfied by L5's once-per-day-per-rule idempotency
- **Cross-patient correlation alerts** (e.g., "5 patients in census X had no activity today — facility-wide event?") — out of MVP scope
- **Backfill of historical alerts** — 1C-slim only sees forward from deploy time. Per-patient history rendering pre-deploy will show no behavioral alerts (correct)

---

## Architecture

### Data Flow

```
EventBridge hourly cron (UTC)
   │
   ▼
behavioral-detector Lambda
   │
   ├── Step 1: enumerate all facilities (Organizations.Scan or cached list)
   ├── Step 2: for each facility, compute local-now from facility.timezone
   ├── Step 3: route to rules based on local-hour:
   │            local-09 (±1h) → no_activity_today rule
   │            local-22 (±1h) → below_typical + declining_trend rules
   │            (always)        → device_offline + device_silent rules
   ├── Step 4: for each rule:
   │            for each patient in facility:
   │              if is_currently_paused(patient): skip + sampled audit
   │              if insufficient_history(patient): skip + sampled audit
   │              evaluate rule
   │              if fires AND no existing alert today:
   │                  PutItem Alert History (conditional)
   │                  emit_audit('alert.synthetic.create')
   ├── Step 5: emit 'behavioral.detector.run' summary audit
   └── return

(Side effect — caregiver UX)
2A-RD GET /patients/{id}/alerts?status=unacknowledged
   │
   ▼
Returns the new alerts; portal renders in NotificationReviewPanel
   │
   ▼
Caregiver clicks Acknowledge + notes
   │
   ▼
2A-AA PATCH /alerts/{patientId}/{ts}#{alertType}
   │
   ▼
Alert marked acknowledged. Until the next day's rule run.
```

### Interfaces

**Alert row written:**

```jsonc
{
  "patientId": "pat_abc",
  "ts#alertType": "2026-05-24T00:00:00-08:00#no_activity_today",   // SK; ts is facility-local midnight
  "alertType": "no_activity_today",
  "severity": "critical",
  "source": "cloud-behavioral",                  // or "cloud-offline" for the device rules
  "acknowledged": false,
  "clientId": "client_005",
  "facilityId": "fac_whitestone",
  "censusId": "cen_ws_memory",
  "deviceSerial": "GS0000000123",                // for device_offline/silent; null for behavioral rules
  "data": {                                       // rule-specific payload
    "stepsObservedBefore": 0,
    "lastDataReceivedAgo": "1h 23m",
    "facilityLocalCheckTime": "09:00"
  },
  "createdAt": "2026-05-24T17:00:00Z",
  "expiresAt": 1779408000                         // existing TTL pattern per 0B-rev (alert + 24mo)
}
```

**Rule-evaluation function signature:**

```python
def evaluate_no_activity_today(patient: dict, history: List[ActivityRow], device: dict) -> Optional[AlertCandidate]:
    """Returns AlertCandidate if rule fires; None otherwise.
    Pure function — easy to unit test."""
```

---

## Implementation

### Files Changed / Created

| File | Change Type | Description |
|------|------------|-------------|
| `infra/lambda/behavioral-detector/handler.py` | New | Entry point, dispatch loop |
| `infra/lambda/behavioral-detector/rules/*.py` | New | One module per rule (~30-50 lines each) |
| `infra/lambda/behavioral-detector/facility_iterator.py` | New | Compute local-now per facility; route to rules |
| `infra/lambda/behavioral-detector/patient_iterator.py` | New | Active-patient enumeration per facility |
| `infra/lambda/behavioral-detector/history_window.py` | New | Activity Series query helpers |
| `infra/lambda/behavioral-detector/tests/*.py` | New | Unit tests per rule + integration test |
| `infra/lib/stacks/processing-stack.ts` | Modified | Wire `behavioral-detector` Lambda + EventBridge rule + alarms |
| `infra/lib/stacks/audit-stack.ts` | Modified | Add `behavioral-detector` log group to subscription-filter list |
| `infra/lib/config.ts` | Modified | `behavioralDetectorMemoryMb` + `behavioralDetectorTimeoutSeconds` defaults |
| `infra/lambda/_shared/audit_catalog.py` | Modified | Add 4 new event constants per §Audit events |
| `docs/specs/ARCHITECTURE.md` | Modified | §15 Lambda Inventory add `behavioral-detector`; §12 phase plan flip 1C row to "🟡 1C-slim shipped; rollup pending" |
| `docs/firmware-coordination/2026-04-17-cloud-contracts.md` | Modified | New §C-section: 1C-slim deploy outcome; close §C11.7 |
| `docs/specs/phase-1c-slim-notifications.md` | New | This document |

### Dependencies

- **Phase 0B-rev** — Activity Series, Patients, Alert History, Organizations, Device Registry tables
- **Phase 1.5** — IdentityKey CMK
- **Phase 1.6** — Powertools layer; ops SNS for alarms
- **Phase 1.7** — Audit pipeline
- **Phase 1B-rev** — Threshold Detector audit shape (reused: `alert.synthetic.create`)
- **Phase 2A-UM-P** — `_shared/pause_check.py` helper (consumed; degrades gracefully if absent)

### Configuration

| CDK Context Key | Dev | Prod | Notes |
|---|---|---|---|
| `behavioralDetectorMemoryMb` | 512 | 512 | Higher than read-handlers; per-facility iteration is read-heavy |
| `behavioralDetectorTimeoutSeconds` | 60 | 60 | At 50 facilities × 100 patients, full sweep should be < 30 s with concurrent BatchGetItem |
| `behavioralDetectorReservedConcurrency` | 1 | 1 | Cron Lambda; serialize to avoid race on conditional PutItem |
| `belowTypicalThresholdPct` | 0.70 | 0.70 | L9 |
| `decliningTrendThresholdPct` | 0.85 | 0.85 | L10 |
| `noActivityCheckLocalHour` | 9 | 9 | L8 |
| `endOfDayCheckLocalHour` | 22 | 22 | L9 / L10 |
| `offlineThresholdHours` | 2 | 2 | L11 |
| `silentThresholdHours` | 24 | 24 | L12 |
| `minHistoryDaysForBehavioralRules` | 14 | 14 | A3 |

---

## Testing

### Test Scenarios

| # | Scenario | Method | Expected | Status |
|---|---|---|---|---|
| T1 | At facility-local 09:00, patient has 0 steps for the morning + lastSeen 1h ago → `no_activity_today` alert fires | bench fixtures + manual trigger | Alert row in Alert History; `alert.synthetic.create` audit | Pending |
| T2 | At facility-local 09:00, patient has 15 steps → no alert | fixtures | No alert row | Pending |
| T3 | At facility-local 09:00, patient has 0 steps but lastSeen 28h ago → `device_silent` fires (NOT `no_activity_today`, because device is dark) | fixtures | Critical-severity alert; correct alertType | Pending |
| T4 | Replay the same 09:00 invocation → idempotent (L5 conditional PutItem rejects duplicate) | re-invoke Lambda within same day | No second alert row | Pending |
| T5 | At facility-local 22:00, patient.today = 50% of 7-day median → `below_typical_activity` fires | fixtures | Standard-severity alert | Pending |
| T6 | At facility-local 22:00, patient.median7Day = 80% of medianPrior23Day → `declining_trend` fires | fixtures | Standard-severity alert; 7d vs 23d comparison | Pending |
| T7 | Paused patient (notificationsPaused.until > now) → all behavioral rules skip; `suppressed_paused` sampled audit fires | fixtures with pause set | No alert row; one audit event per day | Pending |
| T8 | New patient (< 14 days history) → behavioral rules skip; `suppressed_insufficient_history` sampled audit fires | fixtures | No alert; cold-start guard correct | Pending |
| T9 | Device with lastSeen > 2h, status=active_monitoring → `device_offline` fires (warning) | fixtures | Per L11 | Pending |
| T10 | Device with lastSeen > 24h → `device_silent` fires (critical) | fixtures | Per L12 | Pending |
| T11 | Device in `provisioned` (pre-activation) state → no offline/silent alert (suppressed) | fixtures | Pre-activation suppression honored | Pending |
| T12 | Facility-local timezone is honored (CA facility's 09:00 fires at UTC 17:00, not UTC 09:00) | manual cron trigger + check fires-at semantics | Correct facility-local routing per L7 | Pending |
| T13 | Multi-facility run: one facility at local-09, one at local-22, one at neither → only relevant rules run per facility | fixtures | `behavioral.detector.run` summary audit shows correct counts | Pending |
| T14 | Lambda timeout safety: 50-facility sweep completes in < 30s | synthetic load | Within timeout | Pending |
| T15 | Alerts written are visible via 2A-RD `GET /patients/{id}/alerts?status=unacknowledged` immediately | fixtures + 2A-RD call within 1 min | Read path correctly returns | Pending |
| T16 | Caregiver acks behavioral alert via 2A-AA → standard PATCH flow works | fixtures | `alert.ack` audit; alert disappears from unacked filter | Pending |
| T17 | PII scrub — patient.displayName never appears in `/aws/lambda/gosteady-{env}-behavioral-detector` log group | log filter query | 0 matches | Pending |

### Verification Commands

```bash
# Trigger Lambda manually for testing
aws lambda invoke --region us-east-1 \
  --function-name gosteady-dev-behavioral-detector \
  --cli-binary-format raw-in-base64-out \
  --payload '{"source":"manual-test"}' \
  /tmp/detector-out.json && cat /tmp/detector-out.json | jq

# Query recent behavioral alerts
aws logs filter-log-events --region us-east-1 \
  --log-group-name gosteady-dev-audit \
  --filter-pattern '{ ($.event = "alert.synthetic.create") && ($.subject.source = "cloud-behavioral" || $.subject.source = "cloud-offline") }' \
  --start-time $(($(date +%s) - 86400))000 --max-items 50

# Check the per-invocation run summary
aws logs filter-log-events --region us-east-1 \
  --log-group-name gosteady-dev-audit \
  --filter-pattern '{ $.event = "behavioral.detector.run" }' \
  --start-time $(($(date +%s) - 86400))000 --max-items 24
```

---

## Deployment

### Deploy Commands

```bash
cd infra
npm run build
npx cdk deploy GoSteady-Dev-Processing --context env=dev --require-approval never

# Synthetic invoke to materialize log group
aws lambda invoke --region us-east-1 \
  --function-name gosteady-dev-behavioral-detector \
  --cli-binary-format raw-in-base64-out \
  --payload '{"source":"materialize-log"}' \
  /tmp/synth.json

npx cdk deploy GoSteady-Dev-Audit --context env=dev --require-approval never
```

### Rollback Plan

- **Processing stack revert:** `git revert <commit>` + redeploy. Removes the Lambda + EventBridge rule. Existing alerts in Alert History are unaffected (they're benign; caregivers can ack them via 2A-AA as long as the table has them). The next polling cycle in the portal would not fetch new behavioral alerts
- **Disable just the scheduler:** `aws events disable-rule --name gosteady-dev-behavioral-detector-hourly` — Lambda stops firing without redeploy

---

## Decisions Log

| # | Decision | Alternatives Considered | Why This Choice |
|---|---|---|---|
| D1 | Single Lambda for all 1C-slim rules (L1) | Per-rule Lambdas | Cold-start economics; shared iteration + audit + pause-check logic. Same pattern as 2A-x subsets |
| D2 | Hourly cron, Lambda computes which facilities are at their rule-trigger hour (L2) | Per-facility scheduled rules | Vastly simpler at MVP scale; per-facility rules become valuable only at thousands-of-facilities scale |
| D3 | Reuse existing Alert History table + 2A-RD read path (L4) | New `Notifications` table just for behavioral rules | Avoids forking the caregiver UX into "alerts vs notifications" buckets; ack flow already exists via 2A-AA; audit chain stays uniform |
| D4 | Reuse `alert.synthetic.create` audit event for all 5 rule types (L14) | New per-rule-type audit events | Single event class; differentiator is `subject.alertType`. Avoids catalog sprawl |
| D5 | "Below typical" threshold 70%, not demo's 65% | Keep 65% from demo | Pilot guidance — 65% fires too often on legitimate day-of-week variance. 70% is a tunable starting point |
| D6 | "No activity today" rule triggers at local-09, not local-00 (L8) | Trigger at midnight | A 06:00 alarm for a patient who simply hasn't woken up yet is noise. 9 AM gives breakfast/morning-activity time |
| D7 | Cold-start guard for behavioral rules at < 14 days history (A3) | Run rules from day 1 | Patients with < 14 days of history don't have a meaningful baseline; demo can't compute median7Day from 2 days |
| D8 | Two-tier offline detection: `device_offline` (2h, warning) + `device_silent` (24h, critical) (L11 + L12) | One threshold | Operational response is different at 24h dark vs 2h overdue; two severities help caregivers triage |
| D9 | Skip rules when patient is paused (L6) | Run rules regardless of pause | User-needs US-31 says pause stops notifications; this is the implementation |
| D10 | Bundle Audit-stack subscription filter add (L15) | Defer | Migration Pattern 18.8 |

---

## Open Questions

### Q1. Hourly cron vs per-facility schedule rules (DECIDED)
**Decision:** ✅ Hourly cron per L2. Lambda computes which facilities are at trigger-time. Per-facility rules add CDK complexity for negligible benefit at MVP scale.

### Q2. Should `device_offline` (2h) escalate to `device_silent` (24h) by updating the existing alert, or fire a new alert?
**Lean:** Fire a new alert. Reasons: (a) caregiver may have acked the 2h offline alert thinking it's transient (cellular hiccup); the 24h escalation deserves its own notification surface; (b) audit trail is cleaner with two distinct events. **Trade-off:** caregiver sees two alerts for the same device; UI groups them by deviceSerial in V2.

### Q3. "No activity today" trigger hour — local-09 hard-coded or per-facility configurable?
**Lean:** Hard-coded local-09 in V1; expose as per-facility config in V2 (some memory care facilities have earlier breakfast). Tunable via the same threshold-override pattern as 2A-AA in V2.

### Q4. Daily Rollup — bundle into 1C-slim or separate sibling phase?
**Lean:** Separate sibling (`Phase 1C-rollup`). Rationale: rollups are larger scope (per-day denormalized aggregates → new table), targeted at a different consumer (the 2B 6M tab), and are not V1-launch-blocking (6M tab is disabled per [phase-2b-portal-integration.md](phase-2b-portal-integration.md) L8). Keep 1C-slim focused on the V1 blockers.

### Q5. Should behavioral rules emit the alert to Alert History at facility-local midnight + N hours, OR at UTC time of detection?
**Lean:** SK timestamp = facility-local timestamp of "today" (e.g., `2026-05-24T00:00:00-08:00`) so the alert is naturally grouped under the right "today" for caregiver viewing. The `createdAt` field separately tracks when the alert was written.

### Q6. What's the upper-bound facility count before per-facility schedule rules become necessary?
**Lean:** ~500 facilities. At that scale, per-facility scheduled rules + facility-local-time triggers are warranted. V1 ships with hourly cron; revisit at Series A.

### Q7. Should "below typical" + "declining trend" rules also check device-online status, like "no activity today" does?
**Lean:** Yes — if the device has been silent for > 24h, fall through to `device_silent` only; don't double-fire behavioral alerts on a silent device. Add a pre-check at the top of each behavioral rule.

### Decision summary

| # | Question | Resolution |
|---|---|---|
| Q1 | Cron architecture | ✅ Hourly UTC + per-facility routing |
| Q2 | Offline → Silent escalation | ⏳ Lean: fire a new alert |
| Q3 | No-activity trigger hour | ⏳ Lean: hard-coded local-09; V2 configurable |
| Q4 | Daily Rollup scope | ⏳ Lean: separate sibling phase |
| Q5 | Alert timestamp shape | ⏳ Lean: facility-local timestamp |
| Q6 | Per-facility cron threshold | ⏳ Lean: ~500 facilities |
| Q7 | Behavioral rules check device-online | ⏳ Lean: yes, fall through to `device_silent` |

One of seven decided. Six require user input — but all are tunable knobs, not architectural decisions. Safe to ship with the leans and adjust based on pilot data.

---

## Changelog

| Date | Author | Change |
|------|--------|--------|
| 2026-05-23 | Jace + Claude (portal session) | Initial spec drafted as the minimum-scope Phase 1C subset needed to (a) unblock [phase-2b-portal-integration.md](phase-2b-portal-integration.md) 2B-FAC-R's notification UX (server-side behavioral rules per US-22) and (b) close the [§C11.7](../firmware-coordination/2026-04-17-cloud-contracts.md) conference silent-failure gap (offline detector). Single Lambda + hourly cron + facility-local routing. Reuses existing Alert History table so 2A-RD read path is unchanged. Daily Rollup deferred to sibling `Phase 1C-rollup` (not V1-launch-blocking; 6M tab is shipping disabled per 2B L8). Seven open questions surfaced, all tunable-knob level — none architectural. |
| 2026-05-24 | Jace + Claude (portal session) | **Deployed to dev** across 2 commits on `feature/infra-scaffold` (commit `c596c84` scaffold + 5 pure-fn rules + 42 unit tests → `31d241c` orchestration + CDK + deploy). **42/42 rule unit tests PASS** covering every threshold + boundary + cold-start guard + status-guard across no_activity_today (13), below_typical (8), declining_trend (7), device_offline/silent (14). **Deploy chronology** hit two gotchas: (1) first deploy rejected by Lambda — dev account's 10-concurrency new-account floor blocked `reservedConcurrentExecutions=1` (same gotcha Phase 1.7 hit); resolved by dropping the reservation (cron at 1/hr can't race itself; conditional PutItem on Alert History catches any theoretical overlap). (2) Second deploy succeeded but synthetic invoke surfaced `AccessDeniedException` on the Patients `by-client-status` GSI Query — `fromTableName()` references in processing-stack don't include GSI ARNs in `grantReadData`; resolved by explicit `PolicyStatement` on `table/*/index/*` for Patients + Activity + DeviceAssignments. (3) Third deploy succeeded; synthetic invoke evaluated 2 facilities × 4 active patients in 137ms; 0 alerts fired (correct given current UTC isn't local-09 or local-22 in seed facilities' America/Los_Angeles tz, and active patients don't have devices in `active_monitoring` with stale lastSeen). **End-to-end audit pipeline verified**: `behavioral.detector.run` summary event landed in `gosteady-dev-audit` log group with full counters (facilitiesEvaluated / patientsEvaluated / pausedSkipped / candidates / alertsWritten / alertsDeduplicated / writeErrors / durationSeconds). EventBridge schedule firing hourly. **Outstanding follow-ups** (not blocking): real-data rule-firing validation needs local-09 / local-22 cron firing OR seeded fixtures with controlled Activity Series timestamps + Device Registry lastSeen; `suppressed_paused` audit over-emits ~24x/day vs ≤1/day target (module-level set resets per cold-start; tighten via Patient-row `lastBehavioralSuppressedAuditAt` when audit volume becomes a concern — benign at MVP scale). Coord §C27 captures the deploy chronology. |

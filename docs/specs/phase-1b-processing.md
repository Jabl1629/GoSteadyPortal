# Phase 1B — Processing Logic

## Overview
- **Phase**: 1B
- **Status**: Verified
- **Branch**: feature/infra-scaffold
- **Date Started**: 2026-04-15
- **Date Completed**: 2026-04-15

Upgrades the three IoT Core Lambda handlers (activity, heartbeat, alert) from
CloudWatch-only loggers to real data-layer writers. The three handlers now
validate payloads, resolve the walker's timezone chain, write idempotently to
DynamoDB, update the device registry, and emit cloud-generated synthetic alerts
when heartbeats cross battery/signal thresholds. This closes the loop between
Phase 1A ingestion and Phase 0B data and unlocks the first real device data in
the portal.

## Locked-In Requirements
> Decisions finalized in this or prior phases that CANNOT change without
> cascading impact. Treat as immovable constraints.

| # | Requirement | Decided In | Rationale |
|---|-------------|-----------|-----------|
| L1 | Account 460223323193, region us-east-1 | Phase 0A | IoT Core + CloudFront certs |
| L2 | DynamoDB only (no RDS) for data storage | Phase 0B | Serverless, pay-per-request |
| L3 | `serialNumber` as PK on device/activity/alert | Phase 0B | Natural device identifier |
| L4 | ISO 8601 timestamps as sort keys | Phase 0B | String-sortable, human-readable |
| L5 | `gs/{serial}/{type}` MQTT topics with `thingName` injected by IoT Rule SQL | Phase 1A | Every downstream consumer relies on this shape |
| L6 | Session-based activity (session_start / session_end), not fixed intervals | Phase 1A | Respects bursty real-world walker usage |
| L7 | Activity SK = `session_end` (UTC ISO 8601) | Phase 1B | Monotonic per device; latest-session queries are cheap |
| L8 | Sessions are atomic — never split across calendar days in the raw table | Phase 1B | Preserves audit trail + dedup; daily rollup phase handles splits |
| L9 | Battery thresholds: critical < 5 %, low < 10 % | Phase 1B | Caregiver expectation + matches consumer-device conventions |
| L10 | Signal thresholds: signal_lost ≤ −120 dBm, signal_weak ≤ −110 dBm (LTE-M RSRP) | Phase 1B | nRF9151 datasheet + Nordic LTE-M field guides |
| L11 | Synthetic alerts carry `source="cloud"`; device alerts carry `source="device"` | Phase 1B | One alert table, unambiguous provenance |
| L12 | Alert SK is compound `{eventTs}#{alertType}` | Phase 1B | Two alerts within the same second (combo breach) cannot collide |
| L13 | All writes are idempotent via conditional PutItem on `(serialNumber, timestamp)` | Phase 1B | MQTT at-least-once retries must never duplicate rows |

## Assumptions
> Beliefs we're building on that haven't been fully validated.
> If any prove wrong, flag immediately — they may invalidate this phase.

| # | Assumption | Risk if Wrong | Validation Plan |
|---|-----------|---------------|-----------------|
| A1 | Firmware will not emit a second activity payload with the same `session_end` unless it is a true retry of the same session | False dedup — a legitimate second session at the same epoch second would be silently dropped | Low probability (1-second collision); monitor `[ACTIVITY][DUP]` log volume after field trials |
| A2 | Walker's timezone is stable enough that storing it on the activity row at ingest-time is acceptable | Travel / DST edge case: a row's `date` could disagree with the walker's current tz | Phase 2A UI will display tz-adjusted dates and let caregivers see the stored tz; migrate to runtime-computed dates only if this causes confusion |
| A3 | A single battery sample below threshold is a valid alert trigger (no debouncing) | Spurious transient sags could produce noisy alerts | Monitor alert noise in first week of field data; add N-of-M hysteresis in Phase 2B if needed |
| A4 | The `data` payload on device alerts is safe to round-trip into DynamoDB as a map | Firmware could someday send deeply nested structures that exceed DDB's 32-level depth limit | Keep alert payloads shallow by convention; validate depth in a future firmware contract doc |
| A5 | `battery_mv`, `firmware`, `uptime_s` are optional on heartbeat payloads | Dashboard field shows blank if firmware never sends them | Dashboard already defers to `batteryPct` as primary; `batteryMv` is diagnostic-only |
| A6 | Conditional PutItem with `attribute_not_exists` on both PK and SK is a correct idempotency gate | False positives if DDB ever has partial-item state (not possible in single-item conditional writes) | Covered by DDB's semantics; no action needed |

## Scope

### In Scope
- **Activity processor** — validates payload, resolves walker tz via
  device → walkerUserId → profile lookup chain, writes one row per session to
  the activity table with a UTC `sessionEnd` SK and a walker-local `date` GSI
  field.
- **Heartbeat processor** — validates payload, applies a partial `UpdateItem`
  to the device registry (preserving `walkerUserId` and other non-heartbeat
  fields), runs threshold checks, and writes synthetic alerts with
  `source="cloud"` and compound `{ts}#{alertType}` SKs.
- **Alert handler** — validates payload (enum-checked `alert_type` and
  `severity`), looks up `walkerUserId` off the device registry, and writes
  a conditional row with `source="device"`.
- **IAM grants** — activity processor gets read on user-profiles table;
  heartbeat processor gets write on alerts table.
- **Decimal sanitisation** — nested `data` dicts on alert payloads are
  recursively float→Decimal converted before DDB write.

### Out of Scope (Deferred)
- **EventBridge fan-out** from alert writes → Phase 2C integration stack.
- **Caregiver notification dispatch** (SMS / email / push) → Phase 2C.
- **Device-offline detection** (no heartbeat for N hours) → scheduled sweep
  Lambda in Phase 2B.
- **Daily rollups / midnight session splitting** — aggregates that split a
  16:45-to-00:15 session proportionally across two calendar days → Phase 2B.
- **FHIR Observation projection** of activity / alert events → Phase 4.
- **Debounced / N-of-M threshold hysteresis** → Phase 2B if field data shows
  noisy alerts.
- **Device activation flow** that populates `walkerUserId` on the device
  registry → Phase 2A walker onboarding.

## Architecture

### Infrastructure Changes
- **Stack**: `GoSteady-Dev-Processing` (existing, modified)
  - `ActivityProcessor` IAM policy gains: read on `UserProfiles` table.
  - `HeartbeatProcessor` IAM policy gains: write on `AlertHistory` table.
  - All three Lambda code bundles rebuilt with the new handler implementations.

### Data Flow
```
                    ┌────────────────────────────────────────┐
                    │          IoT Core MQTT topic           │
                    │   gs/{serial}/{activity|heartbeat|     │
                    │                alert}                  │
                    └────────────────┬───────────────────────┘
                                     │ IoT Rule SQL:
                                     │ SELECT *, topic(2) AS thingName
                                     ▼
        ┌──────────────────┬──────────────────┬───────────────────┐
        ▼                  ▼                  ▼                   ▼
  ActivityProcessor   HeartbeatProcessor  AlertHandler       (Phase 2C:
        │                  │                  │             EventBridge)
        │                  │                  │
        │   ┌──────────────┘                  │
        │   │                                 │
        │   │  Device → walker → profile.tz   │
        │   │  lookup chain                   │
        │   ▼                                 │
        │  DeviceRegistry (UpdateItem)        │
        │                                     │
        │  ┌── threshold breach? ──► AlertHistory (source=cloud,
        │  │                          SK = {ts}#{alertType})
        │  │
        ▼  ▼
   ActivitySeries                         AlertHistory (source=device,
   (SK = sessionEnd UTC)                   SK = {ts}#{alertType})
```

### Interfaces
- **IoT Rules** (from Phase 1A) invoke the three Lambdas. Event shape
  matches the docstring at the top of each `handler.py`.
- **DynamoDB access patterns introduced this phase:**
  - `ActivitySeries.PutItem` with `ConditionExpression=attribute_not_exists(serialNumber) AND attribute_not_exists(timestamp)`.
  - `DeviceRegistry.UpdateItem` partial `SET` (preserves `walkerUserId`, `provisionedAt`, etc.).
  - `DeviceRegistry.GetItem` for walker lookup.
  - `UserProfiles.GetItem` for timezone lookup.
  - `AlertHistory.PutItem` (both device-source and cloud-source) with same conditional.
- **Alert row schema** (new fields):
  - `source`: `"device" | "cloud"`
  - `eventTimestamp`: UTC ISO (the original sensed/derived event time).
  - `timestamp` (SK): compound `{eventTimestamp}#{alertType}`.
  - `acknowledged`: `bool` (Phase 2A will flip this).
  - `createdAt`: Lambda wall-clock at write time.
  - `data`: pass-through map (device alerts only) with float→Decimal sanitisation.

## Implementation

### Files Changed / Created
| File | Change Type | Description |
|------|------------|-------------|
| `infra/lambda/activity-processor/handler.py` | Rewritten | Validation + walker tz lookup + conditional PutItem |
| `infra/lambda/heartbeat-processor/handler.py` | Rewritten | Validation + partial UpdateItem + threshold-driven synthetic alerts |
| `infra/lambda/alert-handler/handler.py` | Rewritten | Validation + walker lookup + Decimal sanitisation + conditional PutItem |
| `infra/lib/stacks/processing-stack.ts` | Modified | Added `userProfileTable.grantReadData(activityProcessor)` and `alertTable.grantWriteData(heartbeatProcessor)` |
| `docs/specs/phase-1b-processing.md` | New | This document |

### Dependencies
- **Phase 0B** — data-layer tables must exist (`DeviceRegistry`,
  `ActivitySeries`, `AlertHistory`, `UserProfiles`).
- **Phase 1A** — IoT Rules must point at the three Lambdas and inject
  `thingName` via SQL.
- **Python stdlib only** (`boto3`, `zoneinfo`) — no new Lambda layers.

### Configuration
- Lambda environment (unchanged keys, set by CDK):
  - `DEVICE_TABLE`, `ACTIVITY_TABLE`, `ALERT_TABLE`, `USER_PROFILE_TABLE`
  - `ENVIRONMENT`
- **Threshold constants** are compiled into the Lambda (not env-var-tunable).
  Rationale: changing a medical-adjacent threshold should be a code review,
  not a console tweak.

## Testing

### Test Scenarios
| # | Scenario | Method | Expected Result | Status |
|---|----------|--------|-----------------|--------|
| T1 | Valid activity session | `aws lambda invoke` | 200 + row in activity table, `date` = walker-local | Pass |
| T2 | Activity missing `session_end` | `aws lambda invoke` | 400 `missing:session_end`, no row written | Pass |
| T2b | Activity with `steps=999999` (> MAX_STEPS) | `aws lambda invoke` | 400 `steps_out_of_range:999999` | Pass |
| T3 | Duplicate activity (same `session_end` as T1) | `aws lambda invoke` | 200 "duplicate session ignored", table still 1 row | Pass |
| T4 | Valid heartbeat, healthy values | `aws lambda invoke` | 200, device registry UpdateItem applied, no alert | Pass |
| T5 | Heartbeat with `battery_pct=0.08` | `aws lambda invoke` | 200 + `battery_low / warning` synthetic alert (source=cloud) | Pass |
| T6 | Heartbeat with `battery_pct=0.03` | `aws lambda invoke` | 200 + `battery_critical / critical` synthetic alert | Pass |
| T7 | Heartbeat with `rsrp_dbm=-112` | `aws lambda invoke` | 200 + `signal_weak / info` synthetic alert | Pass |
| T8 | Heartbeat with `rsrp_dbm=-125` | `aws lambda invoke` | 200 + `signal_lost / warning` synthetic alert | Pass |
| T9 | Combined breach (battery 0.02 AND rsrp −125) at same `ts` | `aws lambda invoke` | 200 + TWO alerts with compound SKs `{ts}#battery_critical` and `{ts}#signal_lost` | Pass |
| T9b | Heartbeat with `battery_pct=2.5` | `aws lambda invoke` | 400 `battery_pct_out_of_range:2.5`, no update | Pass |
| T10 | Valid `tipover / critical` device alert with nested `data` floats | `aws lambda invoke` | 200 + row with `data.accel_g` stored as DDB Number, source=device | Pass |
| T11 | Alert with `alert_type=earthquake` | `aws lambda invoke` | 400 `bad_alert_type:earthquake` | Pass |
| T12 | Duplicate of T10 (same `ts` + `alert_type`) | `aws lambda invoke` | 200 "duplicate alert ignored", alert table unchanged | Pass |
| T13 | Activity at `2026-04-16T02:30Z` with walker tz = `America/Los_Angeles` | `aws lambda invoke` | Row written with `date=2026-04-15` (PDT local), `timezone=America/Los_Angeles`, `walkerUserId` populated | Pass |

### Verification Commands
```bash
# Watch any handler's CloudWatch log tail during device tests
aws logs tail /aws/lambda/gosteady-dev-activity-processor --region us-east-1 --follow

# Invoke a handler directly with a sample payload
aws lambda invoke --region us-east-1 \
  --function-name gosteady-dev-heartbeat-processor \
  --cli-binary-format raw-in-base64-out \
  --payload fileb:///tmp/gs1b/hb_batt_crit.json \
  /tmp/out.json && cat /tmp/out.json

# All activity rows for a serial
aws dynamodb query --region us-east-1 --table-name gosteady-dev-activity \
  --key-condition-expression "serialNumber = :s" \
  --expression-attribute-values '{":s":{"S":"GS0000099991"}}'

# Device registry snapshot
aws dynamodb get-item --region us-east-1 --table-name gosteady-dev-devices \
  --key '{"serialNumber":{"S":"GS0000099991"}}'

# All alerts for a serial (device + cloud together)
aws dynamodb query --region us-east-1 --table-name gosteady-dev-alerts \
  --key-condition-expression "serialNumber = :s" \
  --expression-attribute-values '{":s":{"S":"GS0000099991"}}'
```

## Deployment

### Deploy Commands
```bash
cd infra
npm run build
npx cdk deploy GoSteady-Dev-Processing --context env=dev --require-approval never
```

### Rollback Plan
```bash
# Revert the three handler.py files + processing-stack.ts changes in git,
# then redeploy. CloudFormation will swap the Lambda code bundles back.
git revert <phase-1b-commit-sha>
cd infra && npm run build
npx cdk deploy GoSteady-Dev-Processing --context env=dev --require-approval never

# Table data is NOT rolled back — any rows written by the new handlers
# remain. To purge test data, scan + batch-delete or destroy the dev stack.
```

## Decisions Log
> Choices made during this phase that affect future work.

| # | Decision | Alternatives Considered | Why This Choice |
|---|----------|------------------------|-----------------|
| D1 | Activity SK = `session_end` | `session_start`; `ingestedAt`; compound `{start}#{end}` | `session_end` is strictly after `session_start`, so newest-session queries are a single `ScanIndexForward=false + Limit=1`. Start-based SK would break ordering when two sessions end within seconds of each other after being buffered offline. |
| D2 | Walker-local `date` GSI field, computed at ingest, UTC fallback when unlinked | Always-UTC date; compute at query time from tz | Caregivers think in their walker's local calendar day. Ingest-time computation avoids putting tz logic in every read path. UTC fallback preserves usefulness pre-linking. |
| D3 | Sessions are atomic (no midnight splitting in the raw table) | Split proportionally: 70 % of steps → previous day, 30 % → next day | Splitting is a lossy transform. Keep raw truth immutable; do splits in a future aggregator table where it's idempotent and recomputable. |
| D4 | Threshold breaches write synthetic alerts to the alert table (source=cloud) instead of publishing to EventBridge immediately | EventBridge-first with alerts table as subscriber; single "events" table keyed by breach type | Phase 1B has no EventBridge yet. Single alert table means caregivers see device-generated and cloud-generated concerns through the same pane. `source` field preserves provenance. When Phase 2C stands up EventBridge, the alert writer can publish-and-persist. |
| D5 | Compound SK `{eventTs}#{alertType}` on alert table | Separate SK + non-key `alertType`; UUID SK | Two alerts in the same second from the same heartbeat (combo battery + signal breach) would collide on a pure-timestamp SK. Compound key is also self-documenting in DDB console. |
| D6 | Heartbeat → device registry write is `UpdateItem` with explicit `SET` list | `PutItem` with full item | Preserves `walkerUserId`, `provisionedAt`, and any other field set by non-heartbeat flows. PutItem would clobber them. |
| D7 | Critical/low battery is mutually exclusive per heartbeat (critical suppresses low) | Fire both; fire only low; fire only critical | Caregiver UX: one actionable alert per dimension. Same pattern for signal_lost vs signal_weak. |
| D8 | Validation rejects with 400 + logs raw event; never writes partial data | Best-effort write of valid fields; dead-letter queue | Strict rejection is easiest to reason about; raw logging gives firmware team full context to diagnose. DLQ is Phase 2 concern when we add retry handling. |
| D9 | Idempotency via conditional `PutItem` only; no explicit dedup cache | Cache recent keys in Lambda memory; use DDB Streams for dedup | Conditional write is atomic and stateless — survives cold starts, scaling, retries. No extra infra. |
| D10 | Recursive float→Decimal conversion only on alert handler's nested `data` map | Force firmware to send strings; reject floats at validation; convert in every handler | Activity/heartbeat handlers fully control their item shape and can construct Decimals directly. Alert `data` is a pass-through contract with the device, so we sanitise there. |
| D11 | Thresholds hard-coded in Lambda source, not in env vars or DDB config | Per-environment env vars; per-walker thresholds in user profile | Phase 1B ships a single policy. Per-walker thresholds (e.g. "alert my caregiver only if battery < 15 %") belong in Phase 2A alongside the profile UI. |

## Open Questions
- [ ] How do we want to handle heartbeats that arrive out of order (e.g. device buffered offline for a day and now replays 24 hourly pings)? Today's `UpdateItem` will SET `lastSeen` to whatever arrives last, which may be a stale value from the buffer.
- [ ] Should the synthetic-alert logic suppress a second `battery_critical` while the prior one is still `acknowledged=false`? Currently every heartbeat below 5 % writes a fresh alert row (distinct SK).
- [ ] Do we want the `date` field on activity rows to update if a walker later sets/changes their timezone? (Currently it's frozen at ingest.)
- [ ] Once Phase 2 activation links devices, do we want to backfill `walkerUserId` / `date` on historical rows written while unlinked?

## Changelog
| Date | Author | Change |
|------|--------|--------|
| 2026-04-15 | Jace + Claude | Initial implementation, deployment, 15-scenario test pass, and spec write-up |

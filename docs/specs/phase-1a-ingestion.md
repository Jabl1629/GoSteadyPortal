# Phase 1A — IoT Core Ingestion Layer

## Overview
- **Phase**: 1A
- **Status**: Verified
- **Branch**: feature/infra-scaffold
- **Date Started**: 2026-04-15
- **Date Completed**: 2026-04-15

Deploys the full MQTT ingestion pipeline: IoT Core topic rules route device messages to Lambda processors, with a dead-letter queue for failures. Also deploys fleet provisioning for device auto-registration and an S3 bucket for OTA firmware updates. This is the first end-to-end data path from device to cloud.

## Locked-In Requirements

| # | Requirement | Decided In | Rationale |
|---|-------------|-----------|-----------|
| L1 | Serial format: `GS` + 10 digits (e.g., `GS0000001234`) | Phase 1A | Printed on device label, used as MQTT client ID and IoT Thing Name. Balances readability with product identification. No hyphens (simpler parsing). |
| L2 | MQTT topic structure: `gs/{serial}/activity\|heartbeat\|alert` | Phase 1A | Per-device topic namespace. `gs/` prefix avoids collision with AWS reserved topics. `+` wildcard in rules matches any serial. |
| L3 | Session-based activity reporting | Phase 1A | Device sends one payload when walking session ends (not hourly). Less battery drain, more natural data granularity. |
| L4 | Heartbeat interval: 1 hour | Phase 1A | Balance between battery life and staleness detection. Device sends battery, signal, firmware version every hour. |
| L5 | nRF9151 signal metrics: RSRP (dBm) and SNR (dB) | Phase 1A | Nordic nRF9151 modem reports via `AT%CESQ`. RSRP is reference signal power, SNR is signal-to-noise ratio. Not generic "signal_dbm". |
| L6 | Distance calculation on-device (not cloud) | Phase 1A | Firmware uses IMU + step length calibration. Cloud receives `distance_ft` as final value. |
| L7 | No additional sensors beyond accelerometer/gyroscope | Phase 1A | Thingy:91 X has temp/humidity/pressure but they add no value for gait monitoring. Keep payload lean. |
| L8 | IoT policy uses `${iot:Connection.Thing.ThingName}` for per-device topic restriction | Phase 1A | Device can only publish/subscribe to `gs/{its-own-serial}/*`. Prevents spoofing between devices. |
| L9 | Processing stack deploys before Ingestion stack | Phase 1A | Lambda functions must exist before IoT Rules reference their ARNs. CDK dependency: `ingestion.addDependency(processing)` |

## Assumptions

| # | Assumption | Risk if Wrong | Validation Plan |
|---|-----------|---------------|-----------------|
| A1 | Nordic Thingy:91 X supports LTE-M fleet provisioning with CSR | Devices can't auto-register; need manual cert provisioning | Test with physical device in Phase 1B hardware integration |
| A2 | IoT Rule `SELECT *, topic(2) AS thingName` reliably injects serial | Lambda receives wrong/missing thingName | Validated with test payloads via `aws iot-data publish` |
| A3 | Lambda cold starts (100-120ms) are acceptable for device data | Latency too high for real-time alerts | Acceptable — tipover alerts are not sub-second critical. Provisioned concurrency available if needed. |
| A4 | SQS DLQ is sufficient for failed rule actions | Messages lost if DLQ also fails | SQS is highly durable (11 9s). 14-day retention gives time to investigate. |
| A5 | One Lambda per topic is simpler than a single router Lambda | More Lambdas to maintain | Clear separation of concerns. Each Lambda gets exactly the IAM permissions it needs. |
| A6 | OTA firmware bucket won't be used until Phase 3+ | Bucket sits empty, minor cost | S3 standard has no minimum storage fee. Versioning ready for when firmware pipeline is built. |
| A7 | Activity payloads are < 1 KB each | IoT Rule 128 KB payload limit is not a concern | Session data is small: serial, timestamps, steps, distance, duration |

## Scope

### In Scope
- **Processing Stack** (`GoSteady-Dev-Processing`)
  - `gosteady-dev-activity-processor` Lambda (Python 3.12, 256 MB, 30s timeout)
  - `gosteady-dev-heartbeat-processor` Lambda (Python 3.12, 128 MB, 15s timeout)
  - `gosteady-dev-alert-handler` Lambda (Python 3.12, 128 MB, 15s timeout)
  - 30-day CloudWatch log retention on all Lambdas
  - Least-privilege DynamoDB grants per Lambda
  - Resource-based Lambda permissions for IoT invocation
- **Ingestion Stack** (`GoSteady-Dev-Ingestion`)
  - IoT Thing Type: `GoSteadyWalkerCap-dev`
  - IoT Device Policy: `gosteady-dev-device-policy` (per-device topic restriction)
  - 3 IoT Topic Rules: `gosteady_dev_activity`, `gosteady_dev_heartbeat`, `gosteady_dev_alert`
  - SQS Dead-Letter Queue: `gosteady-dev-iot-dlq` (14-day retention)
  - IAM roles: IoT-to-Lambda invocation, IoT-to-SQS DLQ
  - S3 OTA bucket: `gosteady-dev-firmware-ota` (versioned, encrypted, auto-delete in dev)
  - Fleet Provisioning Template: `gosteady-dev-fleet-template`
- Fix `cdk.json` app command from `ts-node` to `node bin/gosteady.js` (ts-node hangs on macOS)

### Out of Scope (Deferred)
- DynamoDB writes in Lambda handlers (Phase 1B — just logging in 1A)
- Alert threshold checking (Phase 1B)
- EventBridge event publishing (Phase 2C)
- Device shadow / desired state (Phase 3)
- OTA firmware delivery jobs (Phase 3)
- Physical device testing (Phase 1B with Thingy:91 X)
- Dedup and late-arrival handling (Phase 1B)

## Architecture

### Infrastructure Changes
- **New stack**: `GoSteady-Dev-Processing` (20 resources)
  - 3x `AWS::Lambda::Function`
  - 3x `Custom::LogRetention`
  - 3x `AWS::Lambda::Permission` (IoT invoke)
  - 3x `AWS::IAM::Role` + 3x `AWS::IAM::Policy`
  - 1x `AWS::Lambda::Function` (log retention handler)
  - 1x `AWS::IAM::Role` + `AWS::IAM::Policy` (log retention)
- **New stack**: `GoSteady-Dev-Ingestion` (19 resources)
  - 1x `AWS::IoT::ThingType`
  - 1x `AWS::IoT::Policy`
  - 3x `AWS::IoT::TopicRule`
  - 1x `AWS::IoT::ProvisioningTemplate`
  - 1x `AWS::SQS::Queue` (DLQ)
  - 1x `AWS::S3::Bucket` + policy + auto-delete custom resource
  - 3x `AWS::IAM::Role` + policies
- **Modified**: `cdk.json` — app command changed to `node bin/gosteady.js`

### Data Flow
```
┌──────────────┐     MQTT (LTE-M)      ┌──────────────┐
│  Walker Cap  │ ──────────────────────>│  IoT Core    │
│  (nRF9151)   │  gs/{serial}/activity  │  MQTT Broker │
│              │  gs/{serial}/heartbeat └──────┬───────┘
│              │  gs/{serial}/alert            │
└──────────────┘                               │
                                               │ IoT Topic Rules
                              ┌────────────────┼────────────────┐
                              │                │                │
                    ┌─────────▼───┐  ┌─────────▼───┐  ┌────────▼────┐
                    │  Activity   │  │  Heartbeat  │  │   Alert     │
                    │  Processor  │  │  Processor  │  │   Handler   │
                    │  (Lambda)   │  │  (Lambda)   │  │  (Lambda)   │
                    └─────────────┘  └─────────────┘  └─────────────┘
                           │                │                │
                     (Phase 1B)       (Phase 1B)       (Phase 1B)
                           │                │                │
                    ┌──────▼──┐      ┌──────▼──┐      ┌─────▼───┐
                    │Activity │      │ Device  │      │  Alert  │
                    │ Table   │      │ Table   │      │  Table  │
                    └─────────┘      └─────────┘      └─────────┘

                    ┌─────────┐
              ──X──>│   DLQ   │  (failed rule actions)
                    │  (SQS)  │
                    └─────────┘
```

### Interfaces

**MQTT Payloads (device → cloud)**

Activity (sent when walking session ends):
```json
{
  "serial": "GS0000001234",
  "session_start": "2026-04-15T14:02:00Z",
  "session_end": "2026-04-15T14:18:00Z",
  "steps": 142,
  "distance_ft": 340.5,
  "active_min": 16
}
```

Heartbeat (every 1 hour):
```json
{
  "serial": "GS0000001234",
  "ts": "2026-04-15T14:00:00Z",
  "battery_mv": 3850,
  "battery_pct": 0.72,
  "rsrp_dbm": -87,
  "snr_db": 12.5,
  "firmware": "1.2.0",
  "uptime_s": 86400
}
```

Alert (on tipover/fall event):
```json
{
  "serial": "GS0000001234",
  "ts": "2026-04-15T14:10:32Z",
  "alert_type": "tipover",
  "severity": "critical",
  "data": {
    "accel_g": 2.3,
    "orientation": "horizontal",
    "duration_s": 5
  }
}
```

**IoT Rule SQL** (all three rules follow this pattern):
```sql
SELECT *, topic(2) AS thingName FROM 'gs/+/activity'
```
Injects `thingName` from the MQTT topic into the Lambda event.

## Implementation

### Files Changed / Created
| File | Change Type | Description |
|------|------------|-------------|
| `infra/lib/stacks/processing-stack.ts` | Rewritten | 3 Lambda functions with DynamoDB grants, log retention, IoT invoke permissions |
| `infra/lib/stacks/ingestion-stack.ts` | Rewritten | Full IoT Core: Thing Type, Policy, 3 Rules, DLQ, Fleet Provisioning, OTA Bucket |
| `infra/bin/gosteady.ts` | Modified | Reversed Processing/Ingestion dependency; Processing deploys first |
| `infra/cdk.json` | Modified | Changed app command from `npx ts-node` to `node bin/gosteady.js` |
| `infra/lambda/activity-processor/handler.py` | Modified | Session-based payload schema (session_start/end, not ts) |
| `infra/lambda/heartbeat-processor/handler.py` | Modified | nRF9151 signal fields (rsrp_dbm, snr_db) |
| `infra/lambda/alert-handler/handler.py` | Modified | Updated serial format logging |

### Dependencies
- Phase 0A (Auth stack) — must exist
- Phase 0B (Data stack) — must exist; Processing stack references Data stack table properties
- `aws-cdk-lib/aws-iot` — IoT Core L1 constructs (CfnThingType, CfnPolicy, CfnTopicRule, CfnProvisioningTemplate)
- `aws-cdk-lib/aws-sqs` — Dead-letter queue
- `aws-cdk-lib/aws-s3` — OTA firmware bucket

### Configuration
- Lambda environment variables (all three):
  - `DEVICE_TABLE`: gosteady-dev-devices
  - `ACTIVITY_TABLE`: gosteady-dev-activity
  - `ALERT_TABLE`: gosteady-dev-alerts
  - `USER_PROFILE_TABLE`: gosteady-dev-user-profiles
  - `ENVIRONMENT`: dev
- CDK feature flag `@aws-cdk/aws-lambda:useCdkManagedLogGroup: true` — CDK auto-creates log groups; use `logRetention` prop instead of explicit `LogGroup`

## Testing

### Test Scenarios
| # | Scenario | Method | Expected Result | Status |
|---|----------|--------|-----------------|--------|
| T1 | Publish activity payload to `gs/GS0000001234/activity` | `aws iot-data publish` | Activity processor Lambda invoked | Pass |
| T2 | Publish heartbeat payload to `gs/GS0000001234/heartbeat` | `aws iot-data publish` | Heartbeat processor Lambda invoked | Pass |
| T3 | Publish alert payload to `gs/GS0000001234/alert` | `aws iot-data publish` | Alert handler Lambda invoked | Pass |
| T4 | Activity log shows correct fields | CloudWatch Logs | `[ACTIVITY] serial=GS0000001234 steps=142 active_min=16` | Pass |
| T5 | Heartbeat log shows nRF9151 signal metrics | CloudWatch Logs | `[HEARTBEAT] serial=GS0000001234 battery=0.72 rsrp=-87 snr=12.5` | Pass |
| T6 | Alert log shows tipover event | CloudWatch Logs | `[ALERT] serial=GS0000001234 type=tipover severity=critical` | Pass |
| T7 | `thingName` injected by IoT Rule SQL | CloudWatch Logs | JSON payload contains `"thingName": "GS0000001234"` | Pass |
| T8 | DLQ has zero messages | SQS console | ApproximateNumberOfMessages = 0 | Pass |
| T9 | Cold start performance acceptable | CloudWatch REPORT | Init: ~100-120ms, Execution: ~2.5ms | Pass |

### Verification Commands
```bash
# Get IoT endpoint
aws iot describe-endpoint --endpoint-type iot:Data-ATS --region us-east-1

# Publish test activity
aws iot-data publish --topic "gs/GS0000001234/activity" \
  --payload "$(echo '{"serial":"GS0000001234","session_start":"2026-04-15T14:02:00Z","session_end":"2026-04-15T14:18:00Z","steps":142,"distance_ft":340.5,"active_min":16}' | base64)" \
  --region us-east-1

# Publish test heartbeat
aws iot-data publish --topic "gs/GS0000001234/heartbeat" \
  --payload "$(echo '{"serial":"GS0000001234","ts":"2026-04-15T14:00:00Z","battery_mv":3850,"battery_pct":0.72,"rsrp_dbm":-87,"snr_db":12.5,"firmware":"1.2.0","uptime_s":86400}' | base64)" \
  --region us-east-1

# Publish test alert
aws iot-data publish --topic "gs/GS0000001234/alert" \
  --payload "$(echo '{"serial":"GS0000001234","ts":"2026-04-15T14:10:32Z","alert_type":"tipover","severity":"critical","data":{"accel_g":2.3,"orientation":"horizontal","duration_s":5}}' | base64)" \
  --region us-east-1

# Check CloudWatch logs (activity)
aws logs filter-log-events --log-group-name /aws/lambda/gosteady-dev-activity-processor \
  --start-time $(date -v-5M +%s000) --region us-east-1 --query "events[].message" --output text

# Check DLQ
aws sqs get-queue-attributes --queue-url "https://sqs.us-east-1.amazonaws.com/460223323193/gosteady-dev-iot-dlq" \
  --attribute-names ApproximateNumberOfMessages --region us-east-1

# List IoT rules
aws iot list-topic-rules --region us-east-1 --query "rules[?contains(ruleName, 'gosteady')]"

# List Lambdas
aws lambda list-functions --region us-east-1 --query "Functions[?contains(FunctionName, 'gosteady-dev')].[FunctionName,Runtime]" --output table
```

## Deployment

### Deploy Commands
```bash
cd infra
npm run build
npx cdk deploy GoSteady-Dev-Processing GoSteady-Dev-Ingestion --context env=dev --require-approval never
# CDK auto-deploys GoSteady-Dev-Data as a dependency
```

### Rollback Plan
```bash
# Destroy in reverse dependency order
npx cdk destroy GoSteady-Dev-Ingestion --context env=dev
npx cdk destroy GoSteady-Dev-Processing --context env=dev
# Data stack left intact — tables retain data
```

## Decisions Log

| # | Decision | Alternatives Considered | Why This Choice |
|---|----------|------------------------|-----------------|
| D1 | GS + 10 digits for serial format | UUID, MAC address, GS-XXXX-XXXX | Human-readable on device label, no hyphens simplifies parsing, 10B device namespace |
| D2 | Session-based activity (not hourly) | Fixed 1-hour intervals, per-step streaming | Less battery, more natural data. Session = "walker stood up, walked, sat down" |
| D3 | Separate Lambda per topic | Single router Lambda | Clearer IAM scoping, independent scaling/timeout, simpler debugging |
| D4 | RSRP + SNR (not generic dBm) | signal_strength_dbm | nRF9151 modem reports RSRP and SNR via AT%CESQ. Being specific to the hardware. |
| D5 | 1-hour heartbeat interval | 5 min, 15 min, 4 hours | Balance: 1h gives ~30-min offline detection with margin. Battery: ~24 heartbeats/day is negligible. |
| D6 | SQS DLQ for failed IoT rules | CloudWatch Logs only, S3 | SQS allows re-processing. 14-day retention. Easy to monitor with CloudWatch alarm. |
| D7 | `node bin/gosteady.js` instead of `ts-node` | Fix ts-node, use tsx | ts-node hangs indefinitely on macOS with this project. Compiled JS works instantly. No runtime penalty. |
| D8 | `logRetention` Lambda prop instead of explicit LogGroup | Explicit aws-logs.LogGroup | CDK feature flag `useCdkManagedLogGroup: true` auto-creates log groups. Explicit + auto = CloudFormation conflict. |
| D9 | Fleet provisioning (not manual cert creation) | Manual per-device certs, JITP | Scales to manufacturing. Device sends CSR on first boot, gets cert + Thing auto-created. |

## Open Questions
- [ ] Confirm Thingy:91 X supports fleet provisioning with claim certificates
- [ ] Define tipover detection algorithm parameters (accel threshold, duration) — firmware decision
- [ ] Should `cmd` topic (cloud-to-device) be reserved now or created when needed?
- [ ] Do we need message deduplication at the Lambda level? (IoT Core guarantees at-least-once)

## Changelog
| Date | Author | Change |
|------|--------|--------|
| 2026-04-15 | Jace + Claude | Initial implementation and deployment |
| 2026-04-15 | Jace + Claude | Fixed ts-node hang (cdk.json → node bin/gosteady.js) |
| 2026-04-15 | Jace + Claude | Fixed LogGroup conflict (logRetention instead of explicit LogGroup) |
| 2026-04-15 | Jace + Claude | End-to-end testing — all 3 pipelines verified |
| 2026-04-15 | Jace + Claude | Backfilled spec |

# Phase 0B — Data Layer

## Overview
- **Phase**: 0B
- **Status**: Verified
- **Branch**: feature/infra-scaffold
- **Date Started**: 2026-04-14
- **Date Completed**: 2026-04-14

Deploys four DynamoDB tables that form the core data model: device registry, activity time-series, alert history, and user profiles. These tables are referenced by every downstream stack (Processing, API, Integration).

## Locked-In Requirements

| # | Requirement | Decided In | Rationale |
|---|-------------|-----------|-----------|
| L1 | AWS account 460223323193, region us-east-1 | Phase 0A | IoT Core and CloudFront certs require us-east-1 |
| L2 | DynamoDB for all data storage (no RDS) | Phase 0B | Serverless, pay-per-request, sub-10ms reads, scales with device count |
| L3 | `serialNumber` as partition key on device/activity/alert tables | Phase 0B | Natural device identifier; all queries are per-device |
| L4 | ISO 8601 timestamps as sort keys | Phase 0B | String-sortable, timezone-aware, human-readable |
| L5 | PAY_PER_REQUEST billing for dev | Phase 0B | Zero cost when idle, no capacity planning needed |
| L6 | Separate tables (not single-table design) | Phase 0B | Clearer access patterns, easier IAM scoping per Lambda, simpler GSIs |

## Assumptions

| # | Assumption | Risk if Wrong | Validation Plan |
|---|-----------|---------------|-----------------|
| A1 | Activity data volume fits DynamoDB (< 25 KB per item) | Switch to TimeStream or S3 if items grow | Monitor item sizes after real device data flows |
| A2 | PAY_PER_REQUEST sufficient for prod launch | Cost spikes under load | Switch to PROVISIONED with auto-scaling when usage patterns clear |
| A3 | One activity row per session (not per step) | Table growth rate depends on session frequency | Estimate: 5 sessions/day x 365 days x N devices |
| A4 | `walkerUserId` populated on device/alert records | GSI `by-walker` is useless until user-device linking exists | Phase 1B device activation will populate this field |
| A5 | No cross-device queries needed (all queries scoped to one serial) | Partition key choice blocks cross-device analytics | Use DynamoDB export to S3 + Athena for analytics |

## Scope

### In Scope
- **Device Registry** (`gosteady-dev-devices`)
  - PK: `serialNumber` (String)
  - GSI `by-walker`: PK `walkerUserId`
  - Fields: firmware version, battery, signal, last_seen, status
- **Activity Time-Series** (`gosteady-dev-activity`)
  - PK: `serialNumber`, SK: `timestamp` (String, ISO 8601)
  - GSI `by-date`: PK `serialNumber`, SK `date` (YYYY-MM-DD)
  - Fields: steps, distanceFt, activeMinutes, sessionStart, sessionEnd
- **Alert History** (`gosteady-dev-alerts`)
  - PK: `serialNumber`, SK: `timestamp`
  - GSI `by-walker`: PK `walkerUserId`, SK `timestamp`
  - Fields: alertType, severity, deliveryStatus, acknowledged
- **User Profiles** (`gosteady-dev-user-profiles`)
  - PK: `userId` (String, Cognito sub)
  - Fields: notification prefs, alert thresholds, timezone

### Out of Scope (Deferred)
- TTL / data retention policies (Phase 3 — define retention rules)
- DynamoDB Streams (Phase 2C — EventBridge integration)
- Backup/export configuration (Phase 3 — compliance)
- Analytics export to S3 (Phase 4C — bulk data)

## Architecture

### Infrastructure Changes
- **New stack**: `GoSteady-Dev-Data`
  - 4x `AWS::DynamoDB::Table`
  - 3x `AWS::DynamoDB::GlobalSecondaryIndex`

### Data Flow
```
                        ┌──────────────────────┐
                        │   Device Registry    │
Phase 1A Heartbeat ────>│  PK: serialNumber    │
                        │  GSI: by-walker      │
                        └──────────────────────┘

                        ┌──────────────────────┐
                        │  Activity Series     │
Phase 1A Activity ─────>│  PK: serialNumber    │
                        │  SK: timestamp       │
                        │  GSI: by-date        │
                        └──────────────────────┘

                        ┌──────────────────────┐
                        │   Alert History      │
Phase 1A Alert ────────>│  PK: serialNumber    │
                        │  SK: timestamp       │
                        │  GSI: by-walker      │
                        └──────────────────────┘

                        ┌──────────────────────┐
Phase 2A API ──────────>│   User Profiles      │
                        │  PK: userId          │
                        └──────────────────────┘
```

### Interfaces
- Tables exposed as public properties on `DataStack` for cross-stack references:
  - `dataStack.deviceTable`
  - `dataStack.activityTable`
  - `dataStack.alertTable`
  - `dataStack.userProfileTable`

## Implementation

### Files Changed / Created
| File | Change Type | Description |
|------|------------|-------------|
| `infra/lib/stacks/data-stack.ts` | New | 4 DynamoDB tables with GSIs |

### Dependencies
- Inherits from Phase 0A (CDK project, config, app entry point)
- No additional packages

### Configuration
- `config.pitrEnabled`: false (dev), true (prod)
- `config.dynamoBillingMode`: PAY_PER_REQUEST (both envs for now)
- Dev tables use `RemovalPolicy.DESTROY`; prod uses `RETAIN`

## Testing

### Test Scenarios
| # | Scenario | Method | Expected Result | Status |
|---|----------|--------|-----------------|--------|
| T1 | All 4 tables visible in DynamoDB console | AWS Console | Tables listed with correct names | Pass |
| T2 | GSIs created on device, activity, alert tables | AWS Console | 3 GSIs visible with correct key schemas | Pass |
| T3 | Tables are PAY_PER_REQUEST billing | AWS Console | No provisioned capacity shown | Pass |
| T4 | Stack outputs exported | CLI | Table names in CloudFormation outputs | Pass |

### Verification Commands
```bash
# List all GoSteady tables
aws dynamodb list-tables --region us-east-1 --query "TableNames[?contains(@, 'gosteady-dev')]"

# Check device table schema
aws dynamodb describe-table --table-name gosteady-dev-devices --region us-east-1 \
  --query "{KeySchema: Table.KeySchema, GSIs: Table.GlobalSecondaryIndexes[].IndexName, Status: Table.TableStatus}"

# Check activity table
aws dynamodb describe-table --table-name gosteady-dev-activity --region us-east-1 \
  --query "{KeySchema: Table.KeySchema, GSIs: Table.GlobalSecondaryIndexes[].IndexName}"

# Stack outputs
aws cloudformation describe-stacks --stack-name GoSteady-Dev-Data --region us-east-1 \
  --query "Stacks[0].Outputs[].{Key: OutputKey, Value: OutputValue}" --output table
```

## Deployment

### Deploy Commands
```bash
cd infra
npm run build
npx cdk deploy GoSteady-Dev-Data --context env=dev --require-approval never
```

### Rollback Plan
```bash
npx cdk destroy GoSteady-Dev-Data --context env=dev
# Dev tables have RemovalPolicy.DESTROY — all data lost
# Prod tables have RETAIN — manual cleanup needed
```

## Decisions Log

| # | Decision | Alternatives Considered | Why This Choice |
|---|----------|------------------------|-----------------|
| D1 | Separate tables per entity | DynamoDB single-table design | Clearer mental model, easier per-Lambda IAM scoping, simpler GSIs. Single-table adds complexity without clear benefit at this scale |
| D2 | ISO 8601 string sort keys | Epoch integers, ULID | Human-readable, natively sortable as strings, standard across FHIR/HL7 |
| D3 | `serialNumber` as PK everywhere | `deviceId` (UUID) | Serial is printed on the physical device; natural identifier for manufacturing + support |
| D4 | `by-date` GSI on activity table | Query with begins_with on timestamp SK | Cleaner API: "give me all sessions on 2026-04-15" without timestamp parsing |
| D5 | User profiles separate from Cognito | Store everything in Cognito custom attributes | Cognito has 50-attribute limit and 2KB per attribute. Profiles need notification prefs, thresholds, timezone — will exceed limits |

## Open Questions
- [ ] Should activity table have TTL? (e.g., delete raw data after 2 years, keep daily rollups)
- [ ] Do we need a DynamoDB Stream on the alert table for real-time processing?
- [ ] Should `date` field on activity by-date GSI be auto-derived or explicitly set by Lambda?

## Changelog
| Date | Author | Change |
|------|--------|--------|
| 2026-04-14 | Jace + Claude | Initial implementation and deployment |
| 2026-04-15 | Jace + Claude | Backfilled spec from deployment |

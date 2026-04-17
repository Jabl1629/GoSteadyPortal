# GoSteady Portal — Master Architecture & Phase Plan

> **Last updated:** 2026-04-15 | **Branch:** `feature/infra-scaffold`
> **Repository:** [GoSteadyPortal](https://github.com/Jabl1629/GoSteadyPortal)

---

## 1. Product Context

GoSteady is a **caregiver monitoring portal** for elderly walker users. A
smart cap device (Nordic Thingy:91 X / nRF9151 SiP) attaches to a standard
walker and reports activity sessions, health heartbeats, and safety alerts
over LTE-M to AWS IoT Core. Caregivers view their linked walkers' daily
activity, device health, and time-critical events through a Flutter web
dashboard.

### Target Users
| Role | Description |
|------|-------------|
| **Walker** | Elderly person using the physical walker with the GoSteady cap device. Has an account but may not use the portal directly. |
| **Caregiver** | Family member, home-health aide, or clinical staff. Views one or more walkers' data through the portal. Receives alerts. |

### Device: GoSteady Walker Cap
| Spec | Value |
|------|-------|
| SoC / Modem | Nordic nRF9151 SiP (LTE-M / NB-IoT) |
| Dev Board | Nordic Thingy:91 X (prototyping) |
| Sensors | Accelerometer, gyroscope (IMU) |
| Connectivity | LTE-M Cat-M1 (primary), NB-IoT (fallback) |
| Signal Metrics | RSRP (dBm) + SNR (dB), Nordic-specific |
| Distance | Computed on-device via IMU + step-length calibration |
| Serial Format | `GS` + 10 digits (e.g., `GS0000001234`) — printed on device |
| Firmware OTA | S3 bucket + fleet provisioning |

---

## 2. Technical Foundation

### AWS Account & Region
| | Value | Rationale |
|---|---|---|
| **Account** | `460223323193` | Single-account for MVP; prod isolation deferred |
| **Region** | `us-east-1` | Required for IoT Core global endpoint + ACM certs for CloudFront |

### Infrastructure as Code
- **AWS CDK** (TypeScript) — `infra/` directory in the portal monorepo
- **CDK version:** 2.1118.0 / `aws-cdk-lib ^2.248.0`
- **Runtime:** `node bin/gosteady.js` (compiled TypeScript; `ts-node` avoided due to macOS compatibility issues)
- **Environment configs:** `dev` and `prod` defined in `infra/lib/config.ts`

| Config Key | Dev | Prod |
|---|---|---|
| `prefix` | `dev` | `prod` |
| `pitrEnabled` | `false` | `true` |
| `dynamoBillingMode` | `PAY_PER_REQUEST` | `PAY_PER_REQUEST` (switch to provisioned when usage patterns clear) |
| `portalDomain` | — | `portal.gosteady.co` |
| `alarmsEnabled` | `false` | `true` |

### Application Stack
| Layer | Technology |
|------|-----------|
| **Frontend** | Flutter Web (Dart) |
| **API** | API Gateway HTTP API + Lambda (Python 3.12) |
| **Auth** | Amazon Cognito User Pool (email + password) |
| **Data** | Amazon DynamoDB (4 tables + relationships table) |
| **Ingestion** | AWS IoT Core (MQTT) → Topic Rules → Lambda |
| **Processing** | AWS Lambda (Python 3.12), boto3, stdlib `zoneinfo` |
| **Notifications** | EventBridge → SNS / SES (Phase 2C) |
| **Hosting** | S3 + CloudFront (Phase 3A) |
| **Integration** | FHIR R4, HL7v2, Bulk NDJSON (Phase 4) |

---

## 3. Architecture Overview

```
                                    ┌─────────────────────────────────┐
                                    │        Walker Cap Device        │
                                    │   (Nordic Thingy:91 X / nRF9151)│
                                    └──────────┬──────────────────────┘
                                               │ LTE-M
                                               │ MQTT TLS 1.2
                                               ▼
┌──────────────────────────────────────────────────────────────────────────┐
│                         AWS IoT Core (us-east-1)                        │
│                                                                          │
│  Thing Type: GoSteadyWalkerCap-dev       Fleet Provisioning Template    │
│  IoT Policy: per-thing topic restriction  Claim Cert → Device Cert      │
│                                                                          │
│  Topic Rules (SQL: SELECT *, topic(2) AS thingName):                    │
│    gs/+/activity   → ActivityProcessor Lambda + DLQ                     │
│    gs/+/heartbeat  → HeartbeatProcessor Lambda + DLQ                    │
│    gs/+/alert      → AlertHandler Lambda + DLQ                          │
└──────┬───────────────────┬──────────────────────┬────────────────────────┘
       │                   │                      │
       ▼                   ▼                      ▼
┌──────────────┐  ┌────────────────┐  ┌──────────────────┐
│  Activity    │  │  Heartbeat     │  │  Alert           │
│  Processor   │  │  Processor     │  │  Handler         │
│              │  │                │  │                  │
│ • Validate   │  │ • Validate     │  │ • Validate       │
│ • TZ resolve │  │ • UpdateItem   │  │ • Walker lookup  │
│ • PutItem    │  │ • Thresholds   │  │ • PutItem        │
│   (activity) │  │ • Synth alerts │  │   (device alert) │
└──────┬───────┘  └──┬──────┬─────┘  └────────┬─────────┘
       │             │      │                  │
       ▼             ▼      ▼                  ▼
┌──────────────────────────────────────────────────────────────────────────┐
│                          DynamoDB Tables                                 │
│                                                                          │
│  ┌───────────────┐  ┌──────────────┐  ┌────────────┐  ┌──────────────┐ │
│  │Device Registry│  │Activity      │  │Alert       │  │User Profiles │ │
│  │PK: serial     │  │Series        │  │History     │  │PK: userId    │ │
│  │GSI: by-walker │  │PK: serial    │  │PK: serial  │  │              │ │
│  │               │  │SK: timestamp │  │SK: ts#type │  │• timezone    │ │
│  │• batteryPct   │  │GSI: by-date  │  │GSI:by-wlkr │  │• prefs       │ │
│  │• rsrpDbm      │  │              │  │            │  │              │ │
│  │• walkerUserId │  │• steps       │  │• alertType │  │              │ │
│  │• lastSeen     │  │• distanceFt  │  │• severity  │  │              │ │
│  │• firmware     │  │• activeMin   │  │• source    │  │              │ │
│  └───────────────┘  │• date (local)│  │• acked     │  └──────────────┘ │
│                     └──────────────┘  └────────────┘                    │
│                                                                          │
│  ┌──────────────────┐                                                   │
│  │Relationships     │  (Auth Stack)                                     │
│  │PK: caregiverId   │                                                   │
│  │SK: walkerId      │                                                   │
│  │GSI: walker-cg    │                                                   │
│  └──────────────────┘                                                   │
└──────────────────────────────────────────────────────────────────────────┘
       │                                              │
       ▼                                              ▼
┌──────────────────────────────────────┐  ┌──────────────────────────────┐
│   API Gateway HTTP API (Phase 2A)    │  │   Cognito User Pool          │
│   /api/v1/*  — Cognito JWT authz     │  │   • walker / caregiver roles │
│                                      │  │   • email + password         │
│   → API Handler Lambda               │  │   • custom:role on JWT       │
│     - GET /device/{serial}           │  │   • custom:linked_devices    │
│     - GET /activity/{serial}?range=  │  └──────────────────────────────┘
│     - GET /alerts/{serial}           │
│     - GET /me/walkers                │           ┌──────────────────────┐
│     - POST /device/activate          │           │  EventBridge + SNS   │
└──────────────┬───────────────────────┘           │  (Phase 2C)         │
               │                                   │  • Alert dispatch    │
               ▼                                   │  • Weekly digest     │
┌──────────────────────────────────────┐           │  • Push/SMS/Email    │
│   Flutter Web Portal                 │           └──────────────────────┘
│   S3 + CloudFront (Phase 3A)         │
│                                      │           ┌──────────────────────┐
│   • Dashboard (daily activity)       │           │  FHIR R4 API         │
│   • Device health card               │           │  (Phase 4A)          │
│   • Alert timeline                   │           │  • Patient           │
│   • Time-range toggle (24h/7d/30d)   │           │  • Observation       │
│   • Caregiver ↔ Walker linking       │           │  • Device            │
└──────────────────────────────────────┘           │  • RelatedPerson     │
                                                   └──────────────────────┘
```

---

## 4. CDK Stack Map

Eight CloudFormation stacks, deployed via CDK with `--context env=dev|prod`.

| # | Stack Name | Phase | Status | Key Resources | Depends On |
|---|-----------|-------|--------|---------------|------------|
| 1 | `GoSteady-{Env}-Auth` | 0A | **Deployed** | Cognito User Pool, Groups (walker/caregiver), Portal App Client, Relationships DDB table | — |
| 2 | `GoSteady-{Env}-Data` | 0B | **Deployed** | Device Registry, Activity Series, Alert History, User Profiles (4 DDB tables + 4 GSIs) | — |
| 3 | `GoSteady-{Env}-Processing` | 1A/1B | **Deployed** | Activity Processor, Heartbeat Processor, Alert Handler (3 Lambdas, Python 3.12) | Data |
| 4 | `GoSteady-{Env}-Ingestion` | 1A | **Deployed** | IoT Thing Type, Device Policy, 3 Topic Rules, SQS DLQ, S3 OTA Bucket, Fleet Provisioning Template | Processing |
| 5 | `GoSteady-{Env}-Notification` | 2C | Stub | EventBridge bus, SNS topics, SES templates, SQS integration queue | — |
| 6 | `GoSteady-{Env}-Api` | 2A | Stub | API Gateway HTTP API, Cognito JWT authorizer, API handler Lambda | Auth, Data |
| 7 | `GoSteady-{Env}-Hosting` | 3A | Stub | S3 bucket, CloudFront distribution, ACM cert, Route53 alias | — |
| 8 | `GoSteady-{Env}-Integration` | 4 | Stub | FHIR Projection Lambda, Outbound Lambda, Bulk Export Lambda | Data, Notification |

### Deploy Order
```
Auth ──┐
       ├──→ Api
Data ──┤
       ├──→ Processing ──→ Ingestion
       │
       └──→ Integration
              ▲
Notification ─┘

Hosting (independent)
```

### Deploy Commands
```bash
cd infra
npm run build                                                          # tsc
npx cdk deploy --all --context env=dev --require-approval never        # all stacks
npx cdk deploy GoSteady-Dev-Processing --context env=dev               # single stack
```

---

## 5. Data Model

### DynamoDB Tables

#### Device Registry (`gosteady-{env}-devices`)
| Attribute | Type | Notes |
|-----------|------|-------|
| **serialNumber** (PK) | S | `GS` + 10 digits |
| walkerUserId | S | Set when device is activated/linked |
| batteryPct | N | 0.0–1.0, updated every heartbeat |
| batteryMv | N | Raw millivolts (optional from firmware) |
| rsrpDbm | N | LTE-M RSRP, −140 to 0 |
| snrDb | N | LTE-M SNR, −20 to 40 |
| firmwareVersion | S | e.g., `"1.2.0"` |
| uptimeS | N | Seconds since last reboot |
| lastSeen | S | ISO 8601 UTC |
| lastHeartbeatAt | S | ISO 8601 UTC |
| provisionedAt | S | Set by fleet provisioning (Phase 5) |
| **GSI `by-walker`** | PK: walkerUserId | Look up device by linked user |

#### Activity Series (`gosteady-{env}-activity`)
| Attribute | Type | Notes |
|-----------|------|-------|
| **serialNumber** (PK) | S | Device serial |
| **timestamp** (SK) | S | `session_end` in UTC ISO 8601 |
| sessionStart | S | UTC ISO 8601 |
| sessionEnd | S | Same as SK |
| steps | N | 0–100,000 |
| distanceFt | N | 0–50,000 (computed on device) |
| activeMinutes | N | 0–1,440 |
| date | S | `YYYY-MM-DD` in walker's local timezone (UTC fallback) |
| timezone | S | IANA timezone used for `date` (e.g., `America/Los_Angeles`) |
| walkerUserId | S | Populated when device is linked |
| source | S | `"device"` |
| ingestedAt | S | Lambda wall-clock at write time |
| **GSI `by-date`** | PK: serialNumber, SK: date | Daily queries and rollups |

#### Alert History (`gosteady-{env}-alerts`)
| Attribute | Type | Notes |
|-----------|------|-------|
| **serialNumber** (PK) | S | Device serial |
| **timestamp** (SK) | S | Compound: `{eventTs}#{alertType}` — prevents same-second collisions |
| eventTimestamp | S | True event time (UTC ISO 8601) |
| alertType | S | `tipover`, `fall`, `impact` (device) / `battery_low`, `battery_critical`, `signal_weak`, `signal_lost` (cloud) |
| severity | S | `critical`, `warning`, `info` |
| source | S | `"device"` (from firmware) or `"cloud"` (synthetic threshold alert) |
| acknowledged | BOOL | `false` initially; flipped by caregiver action |
| walkerUserId | S | For GSI-based caregiver queries (may be null pre-linking) |
| data | M | Pass-through sensor snapshot (device alerts) or metric snapshot (cloud alerts) |
| createdAt | S | Lambda wall-clock |
| **GSI `by-walker`** | PK: walkerUserId, SK: timestamp | Caregiver dashboard "all alerts for my walkers" |

#### User Profiles (`gosteady-{env}-user-profiles`)
| Attribute | Type | Notes |
|-----------|------|-------|
| **userId** (PK) | S | Cognito `sub` |
| timezone | S | IANA timezone (e.g., `America/New_York`) |
| displayName | S | Human-readable name |
| notificationPrefs | M | Push / email / SMS toggles (Phase 2C) |
| alertThresholds | M | Per-user overrides (Phase 2A) |

#### Relationships (`gosteady-{env}-relationships`) — Auth Stack
| Attribute | Type | Notes |
|-----------|------|-------|
| **caregiverId** (PK) | S | Cognito `sub` of caregiver |
| **walkerId** (SK) | S | Cognito `sub` of walker |
| status | S | `active`, `pending`, `revoked` |
| linkedAt | S | ISO 8601 |
| **GSI `walker-caregivers`** | PK: walkerId, SK: caregiverId | Reverse lookup |

---

## 6. MQTT Payload Contracts

All payloads flow through `gs/{serialNumber}/{type}`. IoT Rule SQL injects
`thingName` from the topic so Lambdas always have a reliable device identifier.

### Activity (session-end event)
```json
{
  "serial": "GS0000001234",
  "session_start": "2026-04-15T14:02:00Z",
  "session_end":   "2026-04-15T14:18:00Z",
  "steps": 142,
  "distance_ft": 340.5,
  "active_min": 16
}
```
| Field | Required | Validation |
|-------|----------|-----------|
| `session_start` | Yes | ISO 8601, must parse |
| `session_end` | Yes | ISO 8601, must be ≥ `session_start` |
| `steps` | Yes | Integer, 0–100,000 |
| `distance_ft` | Yes | Number, 0–50,000 |
| `active_min` | Yes | Integer, 0–1,440 |

### Heartbeat (hourly)
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
| Field | Required | Validation |
|-------|----------|-----------|
| `ts` | Yes | ISO 8601, must parse |
| `battery_pct` | Yes | Float, 0.0–1.0 |
| `rsrp_dbm` | Yes | Float, −140 to 0 |
| `snr_db` | Yes | Float, −20 to 40 |
| `battery_mv` | No | Integer (diagnostic) |
| `firmware` | No | String |
| `uptime_s` | No | Integer |

### Alert (event-driven)
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
| Field | Required | Validation |
|-------|----------|-----------|
| `ts` | Yes | ISO 8601, must parse |
| `alert_type` | Yes | Enum: `tipover`, `fall`, `impact` |
| `severity` | Yes | Enum: `critical`, `warning`, `info` |
| `data` | No | Arbitrary map, floats auto-converted to DDB Decimal |

---

## 7. Threshold & Alert Policy

Heartbeat processor checks every incoming heartbeat and writes **synthetic
alerts** (`source="cloud"`) when thresholds are breached. Only the most severe
tier per dimension fires (critical suppresses low; lost suppresses weak).

| Threshold | Condition | Alert Type | Severity | Notes |
|-----------|-----------|-----------|----------|-------|
| Battery critical | `battery_pct < 0.05` | `battery_critical` | `critical` | Charge immediately |
| Battery low | `battery_pct < 0.10` | `battery_low` | `warning` | Charge soon |
| Signal lost | `rsrp_dbm ≤ −120` | `signal_lost` | `warning` | Device may be unreachable |
| Signal weak | `rsrp_dbm ≤ −110` | `signal_weak` | `info` | Consider repositioning |
| Device offline | `lastSeen > 2 hours` | `device_offline` | `warning` | **Phase 2B** — scheduled sweep |

Thresholds are hard-coded in Lambda source (not env vars). Changing them is a
code review + deploy — appropriate for a medical-adjacent product. Per-walker
threshold overrides are deferred to Phase 2A (user profile UI).

---

## 8. Phase Plan

### Legend
| Status | Meaning |
|--------|---------|
| ✅ **Deployed** | Code written, deployed to dev AWS, verified with live tests |
| 🔲 Planned | Design understood, not yet implemented |
| ⬜ Future | Broad scope defined, details TBD |

---

### Phase 0: Foundation

> Everything depends on these two stacks. They own auth and data schemas that
> every subsequent phase reads or writes.

#### Phase 0A — Auth Stack ✅
**Spec:** [`docs/specs/phase-0a-auth.md`](phase-0a-auth.md)

- Cognito User Pool with email/password sign-in
- Cognito Groups: `walker`, `caregiver`
- Custom attributes: `custom:role`, `custom:linked_devices`
- Portal App Client (public, SRP auth flow)
- DynamoDB Relationships table (caregiverId/walkerId composite key + reverse GSI)
- Branded verification email

**Key IDs:**
- User Pool: `us-east-1_ZHbhl19tQ`
- Portal Client: `1q9l9ujtsomf3ugq2tnqvdg6d7`

#### Phase 0B — Data Layer ✅
**Spec:** [`docs/specs/phase-0b-data.md`](phase-0b-data.md)

- 4 DynamoDB tables: Device Registry, Activity Series, Alert History, User Profiles
- 4 GSIs: `by-walker` (devices), `by-date` (activity), `by-walker` (alerts), `walker-caregivers` (relationships)
- PAY_PER_REQUEST billing, PITR off for dev
- Separate-table design (not single-table) for clear IAM scoping

---

### Phase 1: Data In (device → cloud)

> These phases stand up the full IoT ingestion pipeline: MQTT messages from
> the walker cap arrive at IoT Core, get routed to purpose-built Lambdas, and
> land as validated, idempotent rows in DynamoDB.

#### Phase 1A — IoT Core + Ingestion ✅
**Spec:** [`docs/specs/phase-1a-ingestion.md`](phase-1a-ingestion.md)

- IoT Thing Type: `GoSteadyWalkerCap-{env}`
- IoT Device Policy with per-thing topic restrictions
- 3 IoT Topic Rules (`gs/+/activity`, `gs/+/heartbeat`, `gs/+/alert`)
  - SQL: `SELECT *, topic(2) AS thingName FROM 'gs/+/{type}'`
  - DLQ: SQS queue (`gosteady-{env}-iot-dlq`) with 14-day retention
- S3 OTA bucket for firmware updates
- Fleet provisioning template (claim cert → device cert exchange)
- Processing stack with 3 Lambda stubs (implemented in 1B)

#### Phase 1B — Processing Logic ✅
**Spec:** [`docs/specs/phase-1b-processing.md`](phase-1b-processing.md)

- **Activity Processor:** validate → device→walker→profile timezone lookup → local-date computation → conditional PutItem (idempotent on sessionEnd)
- **Heartbeat Processor:** validate → partial UpdateItem on device registry → threshold checks → synthetic alert writes (compound SK `{ts}#{alertType}`)
- **Alert Handler:** validate enum alert_type/severity → walker lookup → float→Decimal sanitisation → conditional PutItem (`source="device"`)
- IAM grants: activity→userProfiles (read), heartbeat→alerts (write)
- 15 test scenarios verified against live AWS

#### Phase 1C — Scheduled Jobs 🔲
> Periodic data-quality and aggregation tasks. Can deploy after 1B.

- **Offline Detector** (EventBridge cron, every 60 min)
  - Scan device registry for `lastSeen > 2 hours`
  - Write `device_offline / warning` alert
- **Daily Rollup** (daily at 23:59 UTC)
  - Aggregate session rows into daily totals per device
  - Handle midnight-split sessions (proportional step/distance allocation)
  - Write `type=daily_rollup` summary rows
- **Weekly Trend Computation** (daily at 03:00 UTC)
  - 7-day rolling averages per device
  - Powers "trending up/down" indicators in portal
- **No-Activity Check** (every 30 min during 07:00–22:00 local)
  - Flag devices with linked walkers that have 0 steps in last 2 hours
  - Publish `no_activity / warning` alert

---

### Phase 2: Data Out (cloud → portal)

> These phases connect the portal frontend to real data and enable
> caregiver-facing notifications.

#### Phase 2A — Portal API 🔲
> API Gateway with Cognito JWT authorization, role-based scoping, and Lambda
> handlers for the portal's data needs.

- API Gateway HTTP API with Cognito JWT authorizer
- Lambda handlers for `/api/v1/*` routes:
  - `GET /api/v1/device/{serial}` — device health + status
  - `GET /api/v1/activity/{serial}?range=24h|7d|30d|6m` — activity data
  - `GET /api/v1/alerts/{serial}` — alert history
  - `GET /api/v1/me/walkers` — caregiver's linked walkers
  - `POST /api/v1/device/activate` — link serial to user account
  - `PATCH /api/v1/alerts/{serial}/{timestamp}` — acknowledge alert
- Role-based scoping: caregiver sees only linked walkers (via relationships table)
- Walker profile management (timezone, display name, notification prefs)

#### Phase 2B — Portal Integration 🔲
> Replace mock data in Flutter with real API calls. Auth flow in the app.

- Cognito sign-in / sign-up / token refresh in Flutter
- API client service with retry logic, auth header injection
- Replace mock data providers with real API calls
- Loading states, error handling, offline detection
- **Full loop test:** synthetic MQTT → DynamoDB → API → portal renders real data

#### Phase 2C — Notifications 🔲
> Event-driven alert dispatch to caregivers via push, SMS, and email.

- EventBridge event bus (`gosteady-{env}-events`) — central event backbone
- EventBridge rules for alert routing (by severity, type, walker)
- SNS topics for push notifications (FCM for Android, APNs for iOS)
- SES email templates for:
  - Real-time alert emails (tipover, battery critical)
  - Weekly activity digest
- Per-caregiver notification preferences (from user profile)
- SQS integration queue for downstream consumers (Phase 4)
- **Target:** synthetic tip-over → push notification arrives < 60 seconds

---

### Phase 3: Hosting & CI/CD

#### Phase 3A — Portal Hosting 🔲
> S3 + CloudFront for the Flutter web build, with CI/CD.

- S3 bucket for Flutter web build artifacts
- CloudFront distribution with:
  - ACM certificate for `portal.gosteady.co`
  - SPA error-page redirect (index.html for all 404s)
  - Cache invalidation on deploy
- Route53 alias record (if using Route53 for DNS)
- GitHub Actions pipeline:
  - On PR: `flutter build web`, CDK diff, preview deploy
  - On merge to main: build → deploy to S3 → invalidate CloudFront cache

#### Phase 3B — CI/CD Pipeline 🔲
> Automated infrastructure deployment via GitHub Actions.

- CDK diff on pull request (comment on PR)
- CDK deploy on merge to `main` (dev environment)
- Manual approval gate for prod deployment
- Python Lambda linting + unit tests in CI
- Flutter build + test in CI

---

### Phase 4: Integration Layer

> FHIR R4 and HL7v2 interoperability for healthcare system integration.
> Can start any time after Phase 1C; runs in parallel with Phases 2–3.

#### Phase 4A — FHIR R4 Projection 🔲
> Read-only FHIR R4 API that projects internal data into standard resources.

- FHIR Projection Lambda mapping internal data → FHIR R4:
  - `Patient` → walker user demographics
  - `Observation` → steps (LOINC 55423-8), distance, active minutes
  - `Device` → walker cap (serial, firmware, battery)
  - `RelatedPerson` → caregiver ↔ patient relationship
- API Gateway routes: `/fhir/R4/Patient/{id}`, `/fhir/R4/Observation?subject=...`, etc.
- FHIR R4 spec compliance validation

#### Phase 4B — Outbound Integration 🔲
> Push events to healthcare partners in their preferred format.

- SQS integration queue (fed by EventBridge from Phase 2C)
- Outbound Lambda formatting:
  - HL7v2 ADT messages (Admit/Discharge/Transfer) for safety alerts
  - HL7v2 ORU messages (Observation Result) for activity batches
  - FHIR R4 Bundle for FHIR-native consumers
- Per-partner config table:
  - Endpoint URL, format (hl7v2_oru | hl7v2_adt | fhir_bundle)
  - Auth type (basic | bearer | mTLS), credential ARN in Secrets Manager
  - Event filter, enabled flag
- Retry logic with exponential backoff + dead-letter queue

#### Phase 4C — Bulk Data Export ⬜
> Nightly FHIR NDJSON exports for analytics and compliance.

- EventBridge cron (nightly at 02:00 UTC) → Export Lambda
- Output: `s3://gosteady-{env}-export/{date}/{ResourceType}.ndjson`
- Pre-signed URL generation for external consumers
- S3 lifecycle: Glacier transition after 90 days
- FHIR Bulk Data Access IG compliance

---

### Phase 5: Firmware Handshake

> When physical Thingy:91 X boards arrive. Cannot start until boards are in hand.

#### Phase 5A — Device Onboarding ⬜
> Flash provisioning credentials and validate the fleet provisioning flow.

- Flash claim certificate onto Thingy:91 X via J-Link / MCUboot
- Test fleet provisioning: device boots → CSR → gets unique cert → appears in IoT registry
- Verify MQTT payloads match the schemas validated in Phase 1B
- Tune payload timing, battery reporting intervals
- Test OTA firmware update flow via S3

#### Phase 5B — End-to-End Validation ⬜
> Real device → IoT Core → Lambda → DynamoDB → API → portal.

- Real walker cap → real MQTT → real Lambda → real DynamoDB rows
- Real tip-over → EventBridge → SNS → caregiver's phone
- Threshold tuning with real-world battery discharge curves
- Signal-strength mapping in target environments (assisted living facilities)
- Latency measurement: device event → caregiver notification
- Battery-life validation under production heartbeat/activity cadence

---

## 9. Dependency Graph

```
Phase 0A (Auth) ─────────────────────────────────┐
                                                  ├──→ Phase 2A (API)
Phase 0B (Data) ──┬──────────────────────────────┘         │
                  │                                         ▼
                  ├──→ Phase 1A (Ingestion) ──→ Phase 1B (Processing) ──→ Phase 1C (Jobs)
                  │                                                          │
                  │                                                          ▼
                  │                                              Phase 2B (Portal Integration)
                  │                                                          │
                  │                                                          ▼
                  │                                              Phase 5A (Onboarding) ──→ Phase 5B (E2E)
                  │
                  └──→ Phase 4A (FHIR) ──→ Phase 4B (Outbound) ──→ Phase 4C (Bulk Export)
                        ▲
                        │ (needs Phase 2C for SQS feed)
Phase 2C (Notifications) ─────────────────────────────────┘

Phase 3A (Hosting)  ←── independent, can start after Flutter app exists
Phase 3B (CI/CD)    ←── independent, can start any time
```

### Critical Path (MVP: real data on a caregiver's screen)
```
0A → 0B → 1A → 1B → 2A → 2B → [Portal renders real data]
                 ✅   ✅    🔲    🔲
```

### Parallelisation Opportunities
| Track | Phases | Can Start After |
|-------|--------|----------------|
| **Core data pipeline** | 0A → 0B → 1A → 1B → 1C | — (sequential) |
| **Portal API + integration** | 2A → 2B | Phase 0B (tables exist) |
| **Notifications** | 2C | Phase 1B (alerts exist to route) |
| **Hosting + CI/CD** | 3A, 3B | Flutter app exists |
| **Interop** | 4A → 4B → 4C | Phase 1C (data exists to project) |
| **Firmware** | 5A → 5B | Boards arrive + Phase 2B complete |

---

## 10. Cumulative Locked-In Requirements

> Every locked-in requirement from every completed phase, consolidated.
> Treat these as immovable constraints for all future work.

### Global
| # | Requirement | Source |
|---|-------------|--------|
| G1 | AWS account `460223323193`, region `us-east-1` | Phase 0A |
| G2 | CDK TypeScript for all infrastructure | Phase 0A |
| G3 | DynamoDB only — no RDS, no Aurora | Phase 0B |
| G4 | Separate tables (not single-table design) | Phase 0B |
| G5 | PAY_PER_REQUEST billing for dev | Phase 0B |
| G6 | Python 3.12 for all Lambda handlers | Phase 1A |
| G7 | `node bin/gosteady.js` (not `ts-node`) | Phase 1A |

### Identity & Auth
| # | Requirement | Source |
|---|-------------|--------|
| A1 | Cognito (not Auth0/Firebase) | Phase 0A |
| A2 | Email + password sign-in only (no social/SAML) | Phase 0A |
| A3 | Two roles: `walker`, `caregiver` via Cognito Groups | Phase 0A |
| A4 | `custom:role` and `custom:linked_devices` on JWT | Phase 0A |

### Device & Ingestion
| # | Requirement | Source |
|---|-------------|--------|
| D1 | Serial format: `GS` + 10 digits | Phase 1A |
| D2 | MQTT topic: `gs/{serial}/activity\|heartbeat\|alert` | Phase 1A |
| D3 | IoT Rule SQL injects `thingName` from `topic(2)` | Phase 1A |
| D4 | Session-based activity (not fixed intervals) | Phase 1A |
| D5 | 1-hour heartbeat interval | Phase 1A |
| D6 | RSRP (dBm) + SNR (dB) from nRF9151 | Phase 1A |
| D7 | Distance computed on-device | Phase 1A |
| D8 | Processing stack deploys before Ingestion | Phase 1A |

### Data Schema
| # | Requirement | Source |
|---|-------------|--------|
| S1 | `serialNumber` as PK on device/activity/alert | Phase 0B |
| S2 | ISO 8601 string sort keys | Phase 0B |
| S3 | Activity SK = `session_end` (UTC) | Phase 1B |
| S4 | Alert SK = compound `{eventTs}#{alertType}` | Phase 1B |
| S5 | Sessions atomic (never split in raw table) | Phase 1B |

### Processing Rules
| # | Requirement | Source |
|---|-------------|--------|
| P1 | Battery: critical < 5 %, low < 10 % | Phase 1B |
| P2 | Signal: lost ≤ −120 dBm, weak ≤ −110 dBm | Phase 1B |
| P3 | Synthetic alerts: `source="cloud"`, device: `source="device"` | Phase 1B |
| P4 | All writes idempotent via conditional PutItem on (PK, SK) | Phase 1B |
| P5 | Heartbeat uses UpdateItem (not PutItem) — preserves other fields | Phase 1B |

---

## 11. Lambda Inventory

| Lambda | Stack | Phase | Status | Trigger | Runtime |
|--------|-------|-------|--------|---------|---------|
| `gosteady-{env}-activity-processor` | Processing | 1B | ✅ Implemented | IoT Rule | Python 3.12 |
| `gosteady-{env}-heartbeat-processor` | Processing | 1B | ✅ Implemented | IoT Rule | Python 3.12 |
| `gosteady-{env}-alert-handler` | Processing | 1B | ✅ Implemented | IoT Rule | Python 3.12 |
| `gosteady-{env}-api-handler` | Api | 2A | 🔲 Stub | API Gateway | Python 3.12 |
| `gosteady-{env}-scheduled-jobs` | Processing (TBD) | 1C | 🔲 Stub | EventBridge cron | Python 3.12 |
| `gosteady-{env}-fhir-projection` | Integration | 4A | 🔲 Stub | API Gateway | Python 3.12 |
| `gosteady-{env}-outbound-integration` | Integration | 4B | 🔲 Stub | SQS | Python 3.12 |
| `gosteady-{env}-bulk-export` | Integration | 4C | 🔲 Stub | EventBridge cron | Python 3.12 |

---

## 12. Open Questions (Cross-Phase)

### Immediate (should resolve before Phase 2A)
- [ ] **Out-of-order heartbeats:** Device buffered offline replays heartbeats — `UpdateItem SET lastSeen` could regress. Need `if_not_exists` or `>` condition?
- [ ] **Alert suppression:** Should a repeated `battery_critical` heartbeat create a new alert row each hour, or suppress while prior alert is unacknowledged?
- [ ] **Timezone backfill:** When Phase 2A links a device to a walker, should we backfill `walkerUserId` and recompute `date` on historical activity rows?
- [ ] **Daily rollup scope:** Define exactly which aggregation dimensions the portal needs (steps/distance/activeMin by day? by hour? both?)

### Medium-Term (Phase 2–3)
- [ ] **Multi-device per walker:** Current schema supports it, but does the portal UX need to aggregate across devices?
- [ ] **Account separation:** Move prod to a dedicated AWS account before going live?
- [ ] **WAF + rate limiting:** API Gateway rate limits and DDoS protection for portal API
- [ ] **Secrets rotation:** Partner credentials in Secrets Manager need rotation policy

### Long-Term (Phase 4–5)
- [ ] **FHIR compliance certification:** Do we need ONC/CMS certification for the FHIR API?
- [ ] **HL7v2 testing:** Which partners need HL7v2 and what are their specific ADT/ORU profiles?
- [ ] **Battery life in production:** Real-world drain rate under hourly heartbeat + session reporting
- [ ] **Manufacturing provisioning:** Fleet provisioning at scale — batch claim-cert flashing workflow

---

## 13. Spec Index

| Phase | Title | Spec File | Status |
|-------|-------|-----------|--------|
| 0A | Auth Stack | [`phase-0a-auth.md`](phase-0a-auth.md) | ✅ Deployed |
| 0B | Data Layer | [`phase-0b-data.md`](phase-0b-data.md) | ✅ Deployed |
| 1A | IoT Ingestion | [`phase-1a-ingestion.md`](phase-1a-ingestion.md) | ✅ Deployed |
| 1B | Processing Logic | [`phase-1b-processing.md`](phase-1b-processing.md) | ✅ Deployed |
| 1C | Scheduled Jobs | — | 🔲 Planned |
| 2A | Portal API | — | 🔲 Planned |
| 2B | Portal Integration | — | 🔲 Planned |
| 2C | Notifications | — | 🔲 Planned |
| 3A | Portal Hosting | — | 🔲 Planned |
| 3B | CI/CD Pipeline | — | 🔲 Planned |
| 4A | FHIR Projection | — | ⬜ Future |
| 4B | Outbound Integration | — | ⬜ Future |
| 4C | Bulk Export | — | ⬜ Future |
| 5A | Device Onboarding | — | ⬜ Future |
| 5B | End-to-End Validation | — | ⬜ Future |

---

*Template for per-phase specs: [`_TEMPLATE.md`](_TEMPLATE.md)*

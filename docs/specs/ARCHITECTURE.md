# GoSteady Portal — Master Architecture & Phase Plan

> **Last updated:** 2026-04-16 | **Branch:** `feature/infra-scaffold`
> **Repository:** [GoSteadyPortal](https://github.com/Jabl1629/GoSteadyPortal)

---

## 1. Product Context

GoSteady is a **caregiver monitoring platform** for elderly walker users. A
smart cap device (Nordic Thingy:91 X / nRF9151 SiP) attaches to a standard
walker and reports activity sessions, health heartbeats, and safety alerts
over LTE-M to AWS IoT Core. Caregivers and clinical staff view daily activity,
device health, and time-critical events through a Flutter web dashboard.

### Target Users
| Role | Description |
|------|-------------|
| **Patient** | Elderly person using the walker with the GoSteady cap. May or may not have a portal login. |
| **Family Viewer** | Family member with read access to one or more specific patients. |
| **Household Owner** | D2C primary account holder. Admin authority within their synthetic household client (invite family members, assign devices, manage billing). Softer MFA than enterprise `client_admin` to reduce D2C signup friction. |
| **Caregiver** | Facility staff (CNA, aide, nurse) with access to patients in one or more assigned censuses. |
| **Facility Admin** | DON, ED, or operations role with access to all patients in a single facility. |
| **Client Admin** | Regional director or chain operations role with access to all facilities under one client. |
| **Internal Support** | GoSteady internal — read-only access across all clients (customer support, sales, account management). |
| **Internal Admin** | GoSteady internal — full read/write access across all clients (ops, on-call engineering). Use sparingly; every action audited at elevated severity. |

### Go-to-Market Channels
- **Direct-to-consumer (D2C):** Family member buys cap retail for an at-home patient. Modeled internally as a synthetic single-household client.
- **Facility / chain:** Senior living, assisted living, memory care, hospice, home health agencies. Modeled with full Client → Facility → Census hierarchy.

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
| Firmware OTA | AWS IoT Jobs + S3 bucket + signed images (MCUboot) |
| Secure Element | Nordic CryptoCell-312 (TF-M) for cert/key storage |

---

## 2. Technical Foundation

### AWS Account & Region
| | Value | Rationale |
|---|---|---|
| **Region** | `us-east-1` | Required for IoT Core global endpoint + ACM certs for CloudFront |
| **Account: dev** | `460223323193` | Current shared dev environment |
| **Account: prod** | TBD (to be provisioned via AWS Organizations) | Isolated from dev before any prod customer data |
| **Account: shared-services** | TBD | CloudTrail aggregation, KMS, audit log destination |

> **Multi-account separation** is a Phase 1.5 deliverable. Single-account is acceptable for current dev work; **must be in place before first prod customer**.

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
| `kmsCmkEnabled` | `false` | `true` |
| `lambdaArchitecture` | `arm64` | `arm64` |
| `logRetentionDays` | `30` | `90` |

### Application Stack
| Layer | Technology |
|------|-----------|
| **Frontend** | Flutter Web (Dart) |
| **API** | API Gateway HTTP API + Lambda (Python 3.12, ARM64) |
| **Auth** | Amazon Cognito User Pool (email/password + SAML/OIDC federation) |
| **Data** | Amazon DynamoDB (separate-table design) |
| **Ingestion** | AWS IoT Core (MQTT) → Topic Rules → Lambda |
| **Device State** | AWS IoT Device Shadow (battery, signal, firmware, lastSeen) |
| **OTA** | AWS IoT Jobs + S3 + MCUboot signed images |
| **Processing** | AWS Lambda (Python 3.12, ARM64), boto3, Powertools, stdlib `zoneinfo` |
| **Notifications** | EventBridge → SNS / SES (Phase 2C) |
| **Hosting** | S3 + CloudFront + WAF (Phase 3A) |
| **Encryption** | KMS Customer-Managed Keys on identity-bearing tables and OTA bucket |
| **Observability** | Lambda Powertools, X-Ray, CloudWatch dashboards/alarms |
| **Audit** | Dedicated CloudWatch Log Group + S3 (Object Lock) for immutable application audit trail |

---

## 3. Architecture Overview

```
                                    ┌─────────────────────────────────┐
                                    │        Walker Cap Device        │
                                    │   (Nordic Thingy:91 X / nRF9151)│
                                    └──────────┬──────────────────────┘
                                               │ LTE-M, MQTT TLS 1.2
                                               │ (signed firmware via IoT Jobs)
                                               ▼
┌──────────────────────────────────────────────────────────────────────────┐
│                         AWS IoT Core (us-east-1)                        │
│                                                                          │
│  Thing Type: GoSteadyWalkerCap-{env}     Fleet Provisioning Template    │
│  IoT Policy: per-thing topic restriction  Claim Cert → Device Cert      │
│  Device Shadow: battery, signal, firmware, lastSeen                     │
│  IoT Jobs:   firmware OTA                                               │
│                                                                          │
│  Topic Rules (SQL: SELECT *, topic(2) AS thingName):                    │
│    gs/+/activity   → ActivityProcessor Lambda + DLQ                     │
│    gs/+/heartbeat  → Shadow update (no Lambda) + ThresholdDetector      │
│    gs/+/alert      → AlertHandler Lambda + DLQ                          │
└──────┬───────────────────┬──────────────────────┬────────────────────────┘
       │                   │                      │
       ▼                   ▼                      ▼
┌──────────────┐  ┌────────────────┐  ┌──────────────────┐
│  Activity    │  │  Threshold     │  │  Alert           │
│  Processor   │  │  Detector      │  │  Handler         │
│              │  │  (Shadow Δ)    │  │                  │
│ • Validate   │  │                │  │ • Validate       │
│ • Hierarchy  │  │ • Battery      │  │ • Hierarchy      │
│ • TZ resolve │  │ • Signal       │  │   resolve        │
│ • PutItem    │  │ • Synth alerts │  │ • PutItem        │
└──────┬───────┘  └────────┬───────┘  └────────┬─────────┘
       │                   │                    │
       ▼                   ▼                    ▼
┌──────────────────────────────────────────────────────────────────────────┐
│                          DynamoDB Tables                                 │
│                                                                          │
│  ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────────┐  │
│  │ Organizations    │  │ Patients         │  │ Users                │  │
│  │ (single-table:   │  │ PK: patientId    │  │ PK: userId (Cog sub) │  │
│  │  Client/Facility │  │                  │  │                      │  │
│  │  /Census)        │  │ • clientId       │  │ • clientId (1:1)     │  │
│  │                  │  │ • facilityId     │  │ • role               │  │
│  │ PK: clientId     │  │ • censusId       │  │ • timezone           │  │
│  │ SK: type#id      │  │ • timezone       │  │ • displayName        │  │
│  └──────────────────┘  │ • cognitoUserId? │  │ • prefs              │  │
│                        └──────────────────┘  └──────────────────────┘  │
│                                                                          │
│  ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────────┐  │
│  │ RoleAssignments  │  │ Device Registry  │  │ Device Assignments   │  │
│  │ PK: userId       │  │ PK: serial       │  │ PK: serial           │  │
│  │                  │  │                  │  │ SK: assignedAt       │  │
│  │ • clientId       │  │ • owningClientId │  │                      │  │
│  │ • role           │  │ • owningFacility │  │ • patientId          │  │
│  │ • facilityIds[]  │  │ • status         │  │ • censusId           │  │
│  │ • censusIds[]    │  │ • firmware       │  │ • validFrom/Until    │  │
│  │ • validFrom/Until│  │ • lastSeen       │  │ • assignedBy         │  │
│  └──────────────────┘  └──────────────────┘  └──────────────────────┘  │
│                                                                          │
│  ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────────┐  │
│  │ Activity Series  │  │ Alert History    │  │ Audit Log            │  │
│  │ PK: patientId    │  │ PK: patientId    │  │ (CloudWatch + S3     │  │
│  │ SK: timestamp    │  │ SK: ts#type      │  │  Object Lock)        │  │
│  │                  │  │                  │  │                      │  │
│  │ • clientId       │  │ • clientId       │  │ • who/what/when      │  │
│  │ • facilityId     │  │ • facilityId     │  │ • before/after state │  │
│  │ • censusId       │  │ • censusId       │  │ • immutable          │  │
│  │ • deviceSerial   │  │ • deviceSerial   │  │                      │  │
│  │ • steps/distance │  │ • severity/type  │  │                      │  │
│  └──────────────────┘  └──────────────────┘  └──────────────────────┘  │
└──────────────────────────────────────────────────────────────────────────┘
       │                                              │
       ▼                                              ▼
┌──────────────────────────────────────┐  ┌──────────────────────────────┐
│   API Gateway HTTP API + WAF         │  │   Cognito User Pool          │
│   (Phase 2A)                          │  │   • email/password           │
│                                      │  │   • SAML/OIDC federation     │
│   • Cognito JWT authorizer           │  │   • custom:clientId          │
│   • Client-scoped via JWT claims     │  │   • custom:role              │
│   • Request validation at gateway    │  │   • custom:facilities        │
│   • Audit hook on every mutation     │  │   • custom:censuses          │
└──────────────┬───────────────────────┘  └──────────────────────────────┘
               │
               ▼
┌──────────────────────────────────────┐           ┌──────────────────────┐
│   Flutter Web Portal                 │           │  EventBridge + SNS   │
│   S3 + CloudFront + OAC + WAF        │           │  (Phase 2C)         │
│   (Phase 3A)                          │           │  • Alert dispatch    │
│                                      │           │  • Weekly digest     │
│   • Multi-tenant aware               │           │  • Push/SMS/Email    │
│   • Role-based UI                    │           └──────────────────────┘
│   • Time-range toggle (24h/7d/30d)   │
└──────────────────────────────────────┘
```

---

## 4. Multi-Tenancy & Access Model

### Hierarchy

```
Client                         (legal entity / contract owner)
  └── Facility                 (physical building)
        └── Census             (unit / wing / floor)
              └── Patient      (walker user)
```

This mirrors the standard senior-living and home-health data model used by
PointClickCare, MatrixCare, AlayaCare, and others. All four levels exist from
day one — retrofitting hierarchy after launch is a quarter-long migration.

### D2C Modeling

Each direct-to-consumer household is a **synthetic single-household client**:
- `clientId: dtc_{primaryUserId}`
- One synthetic facility, one synthetic census underneath
- Same authz model as facility customers — no codepath fork

This gives D2C users perfect data isolation (a D2C user cannot even structurally see another D2C user's data — different clients, different tenancy boundary).

**A household can have multiple members.** The primary signer takes the `household_owner` role (D2C equivalent of `client_admin`, with softer MFA to reduce signup friction). Secondary family members are invited into the existing household client with `family_viewer` role — they share the same `clientId` and list the household's patients in their `linkedPatientIds`.

#### Household provisioning flows (detail deferred to Phase 2A)

Three patterns identified for D2C onboarding:

1. **Co-located setup** — walker user + primary caregiver sitting together. Walker user provisioned first; monitoring invites dispatched to caregiver email(s) for them to complete their own accounts.
2. **Caregiver-initiated** — caregiver signs up as `household_owner` and pre-configures the patient record, then sends activation invite to the walker user (who may or may not end up with their own login).
3. **Walker-initiated** — walker user signs up as `household_owner` themselves, then sends invites to family members (mechanically identical to flow 1 from the patient's side).

All three land at the same final state: one `household_owner` + N `family_viewer`s + one or more `Patient` records in a single `dtc_*` client. UX sequencing is a Phase 2A deliverable.

### Tenancy Boundary

**Client is the hard security boundary.** A user belongs to exactly one client.
This invariant is enforced at three layers:

1. **JWT** — Cognito embeds `custom:clientId` (single value). The token literally cannot grant cross-client access.
2. **API Gateway** — Custom Lambda authorizer validates path/body `clientId` matches token's `clientId` before any handler runs.
3. **DynamoDB queries** — Every query filter includes `clientId`. GSIs are partitioned by `clientId` where possible.

> **Hard rule (customer users):** A customer user cannot belong to more than one client. Cross-client coverage (e.g., regional clinician across acquired chains) requires separate accounts or a one-time admin migration.
>
> **GoSteady internal users are an explicit carve-out** — they belong to a reserved `_internal` client and have role-granted cross-tenant authority. The customer tenancy boundary is preserved (their JWT still names exactly one client: `_internal`); the cross-tenant capability is encoded in the role itself. See *Internal (GoSteady) Access* below.

### RBAC — Role + Scope

A user has exactly one role within their client. The role's scope is constrained by `scopedFacilityIds` and `scopedCensusIds` (empty set = unrestricted within parent scope).

| Role | Default Scope | Typical User |
|------|---------------|-------------|
| `family_viewer` | Specific patient(s) via separate links | Family member, grandson, daughter |
| `household_owner` | One D2C household client (full admin within it) | D2C primary user — often a family caregiver setting up for a relative; occasionally the patient themselves |
| `caregiver` | One or more censuses within one facility | CNA, aide, nurse |
| `facility_admin` | All censuses in one facility | Director of Nursing, ED |
| `client_admin` | All facilities in client | Regional director, COO |
| `internal_support` | Read-only across all clients | GoSteady customer support, sales, account management |
| `internal_admin` | Full read/write across all clients | GoSteady ops, on-call engineering |

### JWT Custom Claims

```json
{
  "sub": "cognito-uuid",
  "custom:clientId":   "client_005",
  "custom:role":       "caregiver",
  "custom:facilities": "fac_012,fac_018",
  "custom:censuses":   "cen_044,cen_045"
}
```

Empty `facilities` for a `client_admin` means all facilities in the client. Empty `censuses` for a `facility_admin` means all censuses in scoped facilities.

### Internal (GoSteady) Access

Internal employees are modeled as users belonging to a reserved client `_internal`. The role itself encodes cross-tenant authority — there is no scope-list mechanism for internal users (their scope is "everything").

Internal user JWT shape:

```json
{
  "sub": "cognito-uuid",
  "custom:clientId": "_internal",
  "custom:role":     "internal_admin"
}
```

#### Authorizer logic
```
if role.startswith("internal_"):
    is_internal = True
    can_read_any_client  = True
    can_write_any_client = (role == "internal_admin")
    log every access at elevated audit severity
else:
    is_internal = False
    enforce token.clientId == path.clientId  (customer tenancy)
```

#### Constraints on internal access
- **MFA required** on every internal account, no exceptions
- **Every cross-tenant read or write** generates an audit log entry tagged `internal_access` at elevated severity
- **No silent reads:** internal access events surface in customer-facing audit reports (when those exist) so customers can see when GoSteady support touched their data
- **Time-bounded sessions:** internal access tokens expire on shorter cadence (consider 30 min idle / 4 hr absolute)
- **No service accounts** with `internal_admin` — only human-tied identities, so audit log always names a person
- Future: break-glass workflow with explicit ticket reference required for write access (Phase 2A+)

#### Internal users are not customer users
- Internal users do not appear in customer roster queries
- Internal users have no `Patients` linkage
- Internal user accounts are managed via a separate provisioning flow (likely SSO from GoSteady's IdP) — not the customer signup path

### Patient & Device Mobility

- **Patient mobility:** Patients move between censuses (memory care → skilled nursing) and rarely between facilities. Telemetry rows store the hierarchy snapshot **at write time** — history follows the patient, not the unit. Patient-centric queries use `patientId` PK; unit-centric reporting uses denormalized `censusId`/`facilityId`/`clientId`.
- **Device mobility:** Devices are owned by a Client/Facility (inventory). Devices are *assigned* to patients temporarily via `DeviceAssignments`. Reassignment is common (Mrs. Jones's cap is reset and assigned to Mr. Smith). Assignment history is preserved for audit.

---

## 5. CDK Stack Map

Eight CloudFormation stacks (some may consolidate during the Tier 5 cleanup).
Deployed via CDK with `--context env=dev|prod`.

| # | Stack Name | Phase | Status | Key Resources | Depends On |
|---|-----------|-------|--------|---------------|------------|
| 1 | `GoSteady-{Env}-Auth` | 0A | **Deployed** (revisions pending) | Cognito User Pool, Groups, SAML/OIDC config, RoleAssignments DDB | — |
| 2 | `GoSteady-{Env}-Data` | 0B | **Deployed** (revisions pending) | Organizations, Patients, Device Registry, Device Assignments, Activity Series, Alert History, Users (DDB tables + GSIs) | — |
| 3 | `GoSteady-{Env}-Processing` | 1A/1B | **Deployed** (revisions pending) | Activity Processor, Threshold Detector, Alert Handler (3 Lambdas, Python 3.12 ARM64) | Data |
| 4 | `GoSteady-{Env}-Ingestion` | 1A | **Deployed** | IoT Thing Type, Device Policy, 3 Topic Rules, IoT Jobs config, SQS DLQ, S3 OTA Bucket, Fleet Provisioning Template | Processing |
| 5 | `GoSteady-{Env}-Security` | 1.5 | **New** | KMS CMKs, CloudTrail, multi-account guardrails | — |
| 6 | `GoSteady-{Env}-Observability` | 1.6 | **New** | Powertools layer, X-Ray config, CloudWatch dashboards, alarm catalog | All |
| 7 | `GoSteady-{Env}-Audit` | 1.7 | **New** | Audit log group (CloudWatch + S3 Object Lock), audit-writer Lambda | Auth, Data |
| 8 | `GoSteady-{Env}-Notification` | 2C | Stub | EventBridge bus, SNS topics, SES templates, SQS integration queue | — |
| 9 | `GoSteady-{Env}-Api` | 2A | Stub | API Gateway HTTP API + WAF, Cognito JWT authorizer, API handler Lambda | Auth, Data, Audit |
| 10 | `GoSteady-{Env}-Hosting` | 3A | Stub | S3 bucket, CloudFront + OAC + WAF, ACM cert, Route53 alias | — |

### Deploy Order
```
Security ──→ everything (KMS keys referenced by other stacks)

Auth ──┐
       ├──→ Audit ──→ Api ──→ (Hosting independent)
Data ──┤
       ├──→ Processing ──→ Ingestion
       │
Notification ─┘ (independent until Phase 2C)

Observability — wraps all (deployed in parallel)
```

### Deploy Commands
```bash
cd infra
npm run build                                                          # tsc
npx cdk deploy --all --context env=dev --require-approval never        # all stacks
npx cdk deploy GoSteady-Dev-Processing --context env=dev               # single stack
```

---

## 6. Data Model

### Organization Hierarchy

#### Organizations (`gosteady-{env}-organizations`) — single-table for hierarchy

| Attribute | Type | Notes |
|-----------|------|-------|
| **clientId** (PK) | S | e.g., `client_005`, `dtc_<userId>` |
| **sk** (SK) | S | One of: `META#client`, `facility#<id>`, `facility#<id>#census#<id>` |
| type | S | `client` \| `facility` \| `census` |
| parentId | S | `clientId` for facilities, `facilityId` for censuses |
| displayName | S | Human-readable |
| status | S | `active` \| `inactive` \| `archived` |
| createdAt | S | ISO 8601 |
| metadata | M | Type-specific (address, license number, bed count, etc.) |

> Single-table is justified here because everything is the same entity family (organizational structure) with one access pattern (walk down the hierarchy).

### People

#### Patients (`gosteady-{env}-patients`)

| Attribute | Type | Notes |
|-----------|------|-------|
| **patientId** (PK) | S | Opaque ID (UUID); independent of Cognito |
| clientId | S | Tenancy partition |
| facilityId | S | Current facility |
| censusId | S | Current census |
| timezone | S | IANA tz, used for activity local-date computation |
| displayName | S | First name + last initial |
| dateOfBirth | S | Optional; only collected if clinically relevant |
| status | S | `active` \| `discharged` \| `deceased` \| `archived` |
| cognitoUserId | S | **Optional** — set if patient has portal account (rare) |
| **GSI `by-client-status`** | PK: clientId, SK: status#patientId | List active patients per client |
| **GSI `by-census-status`** | PK: censusId, SK: status#patientId | Census roster |

#### Users (`gosteady-{env}-users`) — replaces User Profiles

| Attribute | Type | Notes |
|-----------|------|-------|
| **userId** (PK) | S | Cognito `sub` |
| clientId | S | Tenancy boundary — exactly one |
| timezone | S | IANA timezone for the user's UI |
| displayName | S | Human-readable name |
| email | S | Mirrored from Cognito for convenience |
| notificationPrefs | M | Push / email / SMS toggles (Phase 2C) |
| createdAt | S | ISO 8601 |
| **GSI `by-client`** | PK: clientId | List users per tenant |

#### RoleAssignments (`gosteady-{env}-role-assignments`) — replaces Relationships

| Attribute | Type | Notes |
|-----------|------|-------|
| **userId** (PK) | S | Cognito `sub` |
| clientId | S | Tenancy boundary — must match `Users.clientId` |
| role | S | `family_viewer` \| `caregiver` \| `facility_admin` \| `client_admin` \| `super_admin` |
| scopedFacilityIds | SS | Empty = all facilities in client (for `client_admin`) |
| scopedCensusIds | SS | Empty = all censuses in scoped facilities |
| linkedPatientIds | SS | For `family_viewer` only — explicit patient list |
| validFrom | S | ISO 8601 |
| validUntil | S | ISO 8601, nullable (null = indefinite) |
| assignedBy | S | userId of admin who granted the role |
| **GSI `by-client-role`** | PK: clientId, SK: role#userId | "All caregivers in client X" |

> **Cardinality:** Exactly one role assignment per user. Documented limitation: a person who wears two hats (e.g., staff + family of a resident) needs two accounts. Confirmed acceptable by product owner.

### Devices

#### Device Registry (`gosteady-{env}-devices`)

| Attribute | Type | Notes |
|-----------|------|-------|
| **serialNumber** (PK) | S | `GS` + 10 digits |
| owningClientId | S | Inventory owner (the client who bought / leases the device) |
| owningFacilityId | S | Optional — facility-level inventory tracking |
| status | S | `provisioned` \| `assigned` \| `unassigned` \| `decommissioned` \| `lost` |
| firmwareVersion | S | Last reported via Shadow |
| provisionedAt | S | Set by fleet provisioning |
| decommissionedAt | S | Set when device is retired |
| **GSI `by-owning-client`** | PK: owningClientId, SK: status#serial | Inventory queries |

> Live state (battery, signal, lastSeen, uptime) lives in **AWS IoT Device Shadow**, not in this table. Shadow is the source of truth for current device state.

#### Device Assignments (`gosteady-{env}-device-assignments`)

| Attribute | Type | Notes |
|-----------|------|-------|
| **serialNumber** (PK) | S | Device serial |
| **assignedAt** (SK) | S | ISO 8601 — supports historical query |
| patientId | S | Current/historical assignee |
| clientId | S | Snapshot at assignment time |
| facilityId | S | Snapshot at assignment time |
| censusId | S | Snapshot at assignment time |
| validFrom | S | Same as SK |
| validUntil | S | Nullable; null = currently active assignment |
| assignedBy | S | userId of admin who made the assignment |
| **GSI `by-patient`** | PK: patientId, SK: assignedAt | "All devices ever assigned to patient" |

### Telemetry

#### Activity Series (`gosteady-{env}-activity`)

| Attribute | Type | Notes |
|-----------|------|-------|
| **patientId** (PK) | S | Was `serialNumber`; now patient-centric |
| **timestamp** (SK) | S | `session_end` in UTC ISO 8601 |
| deviceSerial | S | Device that produced the session |
| clientId | S | Snapshot at write time — history follows patient |
| facilityId | S | Snapshot at write time |
| censusId | S | Snapshot at write time |
| sessionStart | S | UTC ISO 8601 |
| sessionEnd | S | Same as SK |
| steps | N | 0–100,000 |
| distanceFt | N | 0–50,000 (computed on device) |
| activeMinutes | N | 0–1,440 |
| date | S | `YYYY-MM-DD` in patient's local timezone |
| timezone | S | IANA timezone used for `date` |
| source | S | `"device"` |
| ingestedAt | S | Lambda wall-clock |
| **GSI `by-date`** | PK: patientId, SK: date | Daily queries and rollups |
| **GSI `by-census-date`** | PK: censusId, SK: date#patientId | Unit-level reporting |

#### Alert History (`gosteady-{env}-alerts`)

| Attribute | Type | Notes |
|-----------|------|-------|
| **patientId** (PK) | S | Patient-centric |
| **timestamp** (SK) | S | Compound: `{eventTs}#{alertType}` |
| deviceSerial | S | Device that produced or triggered the alert |
| clientId | S | Snapshot at write time |
| facilityId | S | Snapshot at write time |
| censusId | S | Snapshot at write time |
| eventTimestamp | S | True event time (UTC ISO 8601) |
| alertType | S | `tipover`, `fall`, `impact` (device) / `battery_low`, `battery_critical`, `signal_weak`, `signal_lost`, `device_offline` (cloud) |
| severity | S | `critical`, `warning`, `info` |
| source | S | `"device"` or `"cloud"` |
| acknowledged | BOOL | `false` initially |
| acknowledgedBy | S | userId — set when caregiver acks |
| acknowledgedAt | S | ISO 8601 |
| data | M | Sensor snapshot (device) or metric snapshot (cloud) |
| createdAt | S | Lambda wall-clock |
| **GSI `by-census-time`** | PK: censusId, SK: timestamp | Unit-level alert dashboard |
| **GSI `by-client-time`** | PK: clientId, SK: timestamp | Client-wide alert feed |

---

## 7. MQTT Payload Contracts

All payloads flow through `gs/{serialNumber}/{type}`. IoT Rule SQL injects
`thingName` from the topic so handlers always have a reliable device identifier.

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

### Heartbeat (hourly) — written to Device Shadow
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

> Heartbeat updates Device Shadow `reported` state. Threshold detection runs on shadow delta, not on every heartbeat Lambda invocation.

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

## 8. Threshold & Alert Policy

Threshold Detector subscribes to Device Shadow delta events and writes
**synthetic alerts** (`source="cloud"`) when thresholds are breached. Only the
most severe tier per dimension fires (critical suppresses low; lost suppresses weak).

| Threshold | Condition | Alert Type | Severity | Notes |
|-----------|-----------|-----------|----------|-------|
| Battery critical | `battery_pct < 0.05` | `battery_critical` | `critical` | Charge immediately |
| Battery low | `battery_pct < 0.10` | `battery_low` | `warning` | Charge soon |
| Signal lost | `rsrp_dbm ≤ −120` | `signal_lost` | `warning` | Device may be unreachable |
| Signal weak | `rsrp_dbm ≤ −110` | `signal_weak` | `info` | Consider repositioning |
| Device offline | Shadow `lastSeen > 2 hours` | `device_offline` | `warning` | Detected via IoT Events or scheduled sweep (Phase 1C) |

Thresholds are hard-coded in Lambda source. Per-walker overrides deferred to Phase 2A.

---

## 9. Encryption & Key Management

### TLS in Transit
- MQTT TLS 1.2 enforced on IoT Core
- HTTPS only on API Gateway, CloudFront
- TLS 1.3 preferred where supported

### At Rest
| Resource | Key Type | Rationale |
|----------|----------|-----------|
| Organizations, Patients, Users, RoleAssignments DDB tables | **CMK** | Identity-bearing; crypto-shred deletion possible |
| Device Assignments DDB | **CMK** | Links devices to patients |
| Activity Series, Alert History DDB | AWS-managed | High-volume telemetry; CMK cost-vs-value not justified at MVP scale |
| Device Registry DDB | AWS-managed | Inventory metadata, no PII |
| S3 OTA bucket | **CMK** | Firmware artifacts; audit-relevant |
| S3 Audit Log bucket | **CMK** + Object Lock | Compliance evidence |
| SQS DLQs | AWS-managed | Transient failure storage |
| CloudWatch Logs | AWS-managed (with log scrubbing discipline) | High volume |

**Total CMKs:** ~3 in dev, ~3 in prod. ~$3/mo per environment.

### Key Policies
- One CMK per resource family, not per resource
- Key administrators: only the GoSteady ops IAM role (separate from data plane)
- Key users: the specific Lambda execution roles that need to use that key
- Cross-account access via key policy if/when prod is in a separate account

### Rotation
- AWS-managed keys: annual auto-rotation (AWS-controlled)
- CMKs: annual auto-rotation enabled

### Crypto-Shredding Deletion
For "delete this patient" requests:
- Patient and identity records can be deleted directly (CMK still alive)
- For full crypto-shred (extreme case, e.g., facility off-boarding), schedule the per-resource CMK for deletion (7–30 day waiting period)

---

## 10. Audit Logging

### Scope
Every read or write of patient-identifying data must produce an audit record. This is application-level audit, separate from CloudTrail (which logs AWS API calls).

### What Gets Logged
- User authentication (login, logout, MFA, failed attempts)
- Patient record access (who viewed which patient)
- Activity / alert / device data access
- Mutations: assignment changes, role assignments, alert acknowledgements
- Admin actions: user provisioning, facility/census creation, device assignment
- **Every internal-user access** (any `internal_*` role) tagged at elevated severity with `internal_access: true`, regardless of read vs write
- Before/after state for any mutation

### Storage
- **Hot path:** dedicated CloudWatch Log Group `gosteady-{env}-audit`, write-only IAM for handlers, read-only for compliance role
- **Cold path:** S3 bucket with Object Lock (compliance mode, 6-year retention) for tamper-evident long-term storage
- Subscription filter copies all entries from CloudWatch → S3 in near-real-time

### Format
Structured JSON via Lambda Powertools:
```json
{
  "event":     "patient.activity.read",
  "actor":     { "userId": "...", "role": "caregiver", "clientId": "client_005" },
  "subject":   { "patientId": "...", "clientId": "client_005", "censusId": "..." },
  "action":    "read" | "create" | "update" | "delete" | "ack",
  "before":    { ... },
  "after":     { ... },
  "requestId": "...",
  "timestamp": "2026-04-16T14:00:00Z"
}
```

### What Does NOT Go in Audit Logs
- Raw telemetry payloads (size + low value)
- Full record contents (just IDs and changed fields)
- Session tokens, passwords, or other secrets

---

## 11. Data Lifecycle & Retention

### Retention by Data Type

| Data Type | Hot Storage | Archive | Hard Delete |
|-----------|-------------|---------|------------|
| Activity Series (raw sessions) | DDB, 13 months (TTL) | S3 Glacier, 6 years | After 6 years OR on patient deletion request |
| Alert History | DDB, 24 months (TTL) | S3 Glacier, 6 years | Same |
| Device Shadow | IoT Core (current state only) | n/a | When device decommissioned |
| Daily Rollups (Phase 1C) | DDB, indefinite | n/a | On patient deletion |
| Audit Logs | CloudWatch, 90 days | S3 Object Lock, 6 years | Per legal hold |
| CloudWatch Lambda Logs | 30 days dev / 90 days prod | n/a | n/a |

### Deletion Workflows

| Scenario | Action |
|----------|--------|
| Patient discharged | Set `Patients.status = discharged`. Data retained per retention table. |
| Patient deceased | Same as discharged + flag for family-portal access continuity per state law |
| Patient deletion request (D2C user opts out) | Soft delete record; schedule purge of telemetry rows; **do not** delete audit log entries |
| Facility off-boarding | Crypto-shred the Client's CMK after 30-day waiting period; data permanently inaccessible |
| Device decommissioned | Mark `Device.status = decommissioned`; clear Shadow; preserve assignment history for audit |

---

## 12. Phase Plan

### Legend
| Status | Meaning |
|--------|---------|
| ✅ **Deployed** | Code written, deployed to dev AWS, verified with live tests |
| 🔄 **Revision pending** | Originally deployed; needs update for current architecture |
| 🔲 Planned | Design understood, not yet implemented |
| ⬜ Future | Broad scope defined, details TBD |
| ❌ Cut | Removed from current roadmap |

---

### Phase 0: Foundation

#### Phase 0A — Auth Stack 🔄
**Spec:** [`phase-0a-auth.md`](phase-0a-auth.md) *(needs revision)*

**Originally deployed:**
- Cognito User Pool with email/password
- Cognito Groups: walker, caregiver
- DynamoDB Relationships table
- Branded verification email

**Revisions pending (Tier 1):**
- Add SAML/OIDC federation support (reverses original A2)
- Replace Relationships table with RoleAssignments table
- Add custom JWT claims: `clientId`, `role`, `facilities`, `censuses`
- Add Patients table (separate from Cognito Users)
- Add Cognito groups for customer roles: `family_viewer`, `caregiver`, `facility_admin`, `client_admin`
- Add Cognito groups for internal roles: `internal_support`, `internal_admin` (separate signup/provisioning flow, MFA enforced)
- Configure 15-minute idle session timeout

**Key IDs:**
- User Pool: `us-east-1_ZHbhl19tQ`
- Portal Client: `1q9l9ujtsomf3ugq2tnqvdg6d7`

#### Phase 0B — Data Layer 🔄
**Spec:** [`phase-0b-data.md`](phase-0b-data.md) *(needs revision)*

**Originally deployed:**
- 4 DynamoDB tables (devices, activity, alerts, user-profiles)
- 4 GSIs

**Revisions pending (Tier 1):**
- Add Organizations table (single-table for Client/Facility/Census)
- Split Device Registry into Device Registry (ownership) + Device Assignments (patient links)
- Add hierarchy denormalization on Activity Series, Alert History (`clientId`, `facilityId`, `censusId`)
- Migrate `walkerUserId` → `patientId` throughout
- Add new GSIs: `by-census-date`, `by-census-time`, `by-client-time`
- Apply DynamoDB TTL on Activity Series (13mo) and Alert History (24mo)

---

### Phase 1: Data In (device → cloud)

#### Phase 1A — IoT Core + Ingestion ✅
**Spec:** [`phase-1a-ingestion.md`](phase-1a-ingestion.md)

**No revisions to base ingestion. Pending additions:**
- Configure AWS IoT Jobs for OTA (replaces bare S3 OTA pattern)
- Configure Device Shadow for state tracking
- Per-thing topic restrictions verified

#### Phase 1B — Processing Logic 🔄
**Spec:** [`phase-1b-processing.md`](phase-1b-processing.md) *(needs revision)*

**Originally deployed:** Activity, Heartbeat, Alert handlers with idempotent writes.

**Revisions pending (Tier 1):**
- Refactor Heartbeat Processor → Threshold Detector (Shadow delta-triggered)
- Resolve out-of-order heartbeat handling: `UpdateItem` condition `attribute_not_exists(lastSeen) OR lastSeen < :newTs`
- Hierarchy lookup in all processors (patient → census → facility → client) with snapshot at write time
- Switch all Lambdas to ARM64 (Graviton)
- Adopt Lambda Powertools for structured logging + tracing
- Add audit log emission on all writes
- Apply log scrubbing (no PII in CloudWatch logs)

#### Phase 1C — Scheduled Jobs 🔲

- **Offline Detector** — IoT Events detector model OR EventBridge cron (every 60 min) on `lastSeen > 2hr`
- **Daily Rollup** — daily at 23:59 UTC, aggregate sessions into patient-day totals; handle midnight-split sessions
- **Weekly Trend Computation** — daily at 03:00 UTC, 7-day rolling averages
- **No-Activity Check** — every 30 min during 07:00–22:00 local

---

### Phase 1.5 — Security Foundation 🔲 **NEW**

- KMS CMKs for identity-bearing tables + S3 OTA bucket (~3 keys)
- CloudTrail with management events, 90-day CloudWatch + indefinite S3 archive
- Multi-account migration plan: dev / prod / shared-services via AWS Organizations
- IAM policy review — least-privilege audit on all Lambda execution roles
- Security baseline documented: TLS 1.2 minimum, MFA on all human accounts, no long-lived access keys

---

### Phase 1.6 — Observability Foundation 🔲 **NEW**

- Lambda Powertools for Python deployed as a layer
- Structured JSON logging across all Lambdas
- X-Ray tracing across IoT Rule → Lambda → DDB
- CloudWatch dashboards: ingestion health, alert rate, error rate, cost
- Alarm catalog: Lambda errors, DLQ depth, IoT Rule failures, DDB throttles
- Log retention enforced (30d dev / 90d prod)
- Cost anomaly detection enabled

---

### Phase 1.7 — Audit Logging Infrastructure 🔲 **NEW**

- Dedicated audit CloudWatch Log Group with restrictive IAM (write-only for handlers, read-only for compliance role)
- Subscription filter → S3 bucket with Object Lock (compliance mode, 6-year)
- Audit emission helper in Lambda Powertools wrapper
- Audit event schema documented and versioned
- Phase 1B handlers retrofitted to emit audit events on writes

---

### Phase 2: Data Out (cloud → portal)

#### Phase 2A — Portal API 🔲

- API Gateway HTTP API with WAF (rate limit, geo, SQLi/XSS rules)
- Cognito JWT authorizer extracting `clientId`, `role`, `facilities`, `censuses` claims
- **Tenant enforcement:** every handler validates path/body `clientId` matches token `clientId`; reject with 403 otherwise
- Request validation at gateway (JSON Schema)
- Lambda handlers for `/api/v1/*`:
  - `GET /api/v1/patients/{patientId}` — patient detail
  - `GET /api/v1/patients/{patientId}/activity?range=24h|7d|30d|6m`
  - `GET /api/v1/patients/{patientId}/alerts`
  - `GET /api/v1/me/patients` — patients in caller's scope
  - `POST /api/v1/devices/{serial}/assignments` — assign device to patient
  - `PATCH /api/v1/alerts/{patientId}/{timestamp}` — acknowledge alert
  - `GET /api/v1/facilities/{facilityId}/censuses/{censusId}/patients` — census roster
- All mutations emit audit events
- Per-walker threshold overrides (hooks into Threshold Detector)

#### Phase 2B — Portal Integration 🔲

- Cognito sign-in / sign-up / token refresh in Flutter
- API client service with retry logic, auth header injection
- Replace mock data with real API calls
- Loading states, error handling, offline detection
- Multi-tenant aware UI (role-driven navigation)
- **Full loop test:** synthetic MQTT → DynamoDB → API → portal renders real data

#### Phase 2C — Notifications 🔲

- EventBridge event bus (`gosteady-{env}-events`)
- EventBridge rules for alert routing (by severity, type, scope)
- SNS topics for push (FCM/APNs)
- SES email templates for real-time alerts + weekly digest
- Per-user notification preferences (from Users table)
- SQS integration queue for downstream consumers
- **Discipline:** no PII in notification payloads (use opaque IDs + portal links)
- **Target:** synthetic tip-over → push notification arrives < 60 seconds

---

### Phase 3: Hosting & CI/CD

#### Phase 3A — Portal Hosting 🔲

- S3 bucket for Flutter web build artifacts (private, OAC-only access)
- CloudFront distribution with:
  - Origin Access Control (OAC) for S3 (replaces deprecated OAI)
  - WAF web ACL (rate limit + managed rule sets)
  - Security headers policy (HSTS, CSP, X-Frame-Options, X-Content-Type-Options)
  - SPA error-page redirect (index.html for all 404s)
  - Cache invalidation on deploy
- ACM certificate for `portal.gosteady.co`
- Route53 alias record
- CloudFront price class: PriceClass_100 (US/CA/EU only) for cost

#### Phase 3B — CI/CD Pipeline 🔲

- CDK diff on PR (comment on PR)
- CDK deploy on merge to `main` (dev)
- Manual approval gate for prod
- Python Lambda linting + unit tests in CI
- Flutter build + test in CI
- Security scanning: cdk-nag, Snyk/Dependabot

---

### Phase 5: Firmware Handshake

#### Phase 5A — Device Onboarding ⬜
> When physical Thingy:91 X boards arrive.

- Flash claim certificate via J-Link / MCUboot
- Test fleet provisioning end-to-end
- Verify MQTT payloads against schemas
- **Signed firmware images** (MCUboot, ECDSA signing key in KMS)
- **Rollback protection** (anti-rollback counter)
- **Secure element use:** store device certs in nRF9151 CryptoCell-312 / TF-M secure storage
- Test OTA via AWS IoT Jobs
- Decommissioning workflow: factory reset, cert revocation, IoT registry cleanup

#### Phase 5B — End-to-End Validation ⬜

- Real walker cap → real MQTT → real Lambda → real DDB
- Real tip-over → EventBridge → SNS → caregiver phone
- Threshold tuning with real-world battery curves
- Signal-strength mapping in target environments
- Latency measurement: device event → caregiver notification
- Battery life under production cadence

---

### ❌ Cut from Roadmap

The following phases are **removed from the active plan** and reclassified as conditional future work. They will only be reopened on a triggering event (e.g., signed partner contract requiring the capability).

| Former Phase | Trigger to Reopen |
|--------------|-------------------|
| Phase 4A — FHIR R4 Projection | Signed contract with EHR-integrated partner |
| Phase 4B — Outbound HL7v2 | Partner contractually requires HL7v2 ingestion |
| Phase 4C — Bulk NDJSON Export | Concrete analytics or research customer |

---

## 13. Dependency Graph

```
Phase 0A (Auth) ──┐
                  ├──→ Phase 1.7 (Audit) ──→ Phase 2A (API)
Phase 0B (Data) ──┤                              │
                  │                              ▼
                  ├──→ Phase 1A (Ingestion) ──→ Phase 1B (Processing) ──→ Phase 1C (Jobs)
                  │                                                          │
                  │                                                          ▼
                  │                                              Phase 2B (Portal Integration)
                  │                                                          │
                  │                                                          ▼
                  │                                              Phase 5A (Onboarding) ──→ Phase 5B (E2E)
                  │
Phase 1.5 (Security) ─→ wrapped around all stacks (KMS keys referenced)
Phase 1.6 (Observability) ─→ wrapped around all stacks
Phase 2C (Notifications) ─→ depends on Phase 1B (alerts to route)
Phase 3A (Hosting)  ←── Flutter app
Phase 3B (CI/CD)    ←── any time
```

### Critical Path (MVP: real data on a caregiver's screen)
```
0A → 0B → 1A → 1B → 1.5 → 1.7 → 2A → 2B → [Portal renders real data]
🔄   🔄   ✅   🔄    🔲    🔲    🔲    🔲
```

---

## 14. Cumulative Locked-In Requirements

### Global
| # | Requirement | Source |
|---|-------------|--------|
| G1 | AWS region `us-east-1` | Phase 0A |
| G2 | CDK TypeScript for all infrastructure | Phase 0A |
| G3 | DynamoDB primary store; no RDS/Aurora | Phase 0B |
| G4 | Separate-table design (organization hierarchy is the one single-table exception) | Phase 0B |
| G5 | PAY_PER_REQUEST billing for dev | Phase 0B |
| G6 | Python 3.12 for all Lambda handlers | Phase 1A |
| G7 | Lambda architecture: ARM64 (Graviton) | Phase 1.5 |
| G8 | `node bin/gosteady.js` (not `ts-node`) | Phase 1A |
| G9 | Multi-account separation (dev / prod / shared-services) before first prod customer | Phase 1.5 |

### Identity & Auth
| # | Requirement | Source |
|---|-------------|--------|
| A1 | Cognito (not Auth0/Firebase) | Phase 0A |
| A2 | Email/password default; SAML/OIDC federation supported as opt-in per client | Revised |
| A3 | Customer roles: `patient`, `family_viewer`, `household_owner`, `caregiver`, `facility_admin`, `client_admin`. Internal roles: `internal_support`, `internal_admin`. | Multi-tenancy |
| A4 | Custom JWT claims: `clientId`, `role`, `facilities`, `censuses` | Multi-tenancy |
| A5 | One Client per customer user (hard rule); internal users belong to reserved `_internal` client | Multi-tenancy |
| A6 | 15-minute idle session timeout (customer); 30-min idle / 4-hr absolute (internal) | Phase 1.5 |
| A7 | MFA **required** for `facility_admin`, `client_admin`, `internal_*`. MFA **optional** (encouraged via UX) for `household_owner`, `caregiver`, `family_viewer`, `patient`. | Phase 1.5 |

### Tenancy
| # | Requirement | Source |
|---|-------------|--------|
| T1 | Hierarchy: Client → Facility → Census → Patient | Multi-tenancy |
| T2 | Client is the hard tenancy boundary, enforced at JWT + API + DDB layers | Multi-tenancy |
| T3 | D2C users get a synthetic single-household client (`dtc_{userId}`) | Multi-tenancy |
| T4 | Telemetry rows store hierarchy snapshot at write time (history follows patient) | Multi-tenancy |
| T5 | Device ownership and patient assignment are separate entities | Multi-tenancy |
| T6 | Internal GoSteady users belong to reserved `_internal` client; cross-tenant authority is role-based (`internal_*`); every cross-tenant access generates elevated audit entry | Multi-tenancy |

### Device & Ingestion
| # | Requirement | Source |
|---|-------------|--------|
| D1 | Serial format: `GS` + 10 digits | Phase 1A |
| D2 | MQTT topic: `gs/{serial}/{activity\|heartbeat\|alert}` | Phase 1A |
| D3 | IoT Rule SQL injects `thingName` from `topic(2)` | Phase 1A |
| D4 | Session-based activity (not fixed intervals) | Phase 1A |
| D5 | 1-hour heartbeat interval | Phase 1A |
| D6 | RSRP (dBm) + SNR (dB) from nRF9151 | Phase 1A |
| D7 | Distance computed on-device | Phase 1A |
| D8 | Processing stack deploys before Ingestion | Phase 1A |
| D9 | Device state lives in IoT Device Shadow, not DDB | Revised |
| D10 | OTA via AWS IoT Jobs with signed images (MCUboot) | Phase 5A |
| D11 | Device certs stored in nRF9151 secure element (CryptoCell-312 / TF-M) | Phase 5A |

### Data Schema
| # | Requirement | Source |
|---|-------------|--------|
| S1 | Patient-centric PK on Activity Series and Alert History (was `serialNumber`) | Revised |
| S2 | ISO 8601 string sort keys | Phase 0B |
| S3 | Activity SK = `session_end` (UTC) | Phase 1B |
| S4 | Alert SK = compound `{eventTs}#{alertType}` | Phase 1B |
| S5 | Sessions atomic (never split in raw table) | Phase 1B |
| S6 | Hierarchy denormalized on every telemetry row (`clientId`, `facilityId`, `censusId`) | Multi-tenancy |

### Processing Rules
| # | Requirement | Source |
|---|-------------|--------|
| P1 | Battery: critical < 5%, low < 10% | Phase 1B |
| P2 | Signal: lost ≤ −120 dBm, weak ≤ −110 dBm | Phase 1B |
| P3 | Synthetic alerts: `source="cloud"`; device alerts: `source="device"` | Phase 1B |
| P4 | All writes idempotent via conditional PutItem on (PK, SK) | Phase 1B |
| P5 | Heartbeat → Device Shadow (not Lambda → DDB); threshold detection via shadow delta | Revised |
| P6 | Out-of-order heartbeats handled via `attribute_not_exists OR <` condition on lastSeen | Resolved |

### Encryption
| # | Requirement | Source |
|---|-------------|--------|
| E1 | TLS 1.2+ on all transit (MQTT, HTTPS) | Phase 1.5 |
| E2 | KMS CMKs on identity-bearing DDB tables and S3 OTA bucket | Phase 1.5 |
| E3 | Annual key rotation enabled | Phase 1.5 |
| E4 | Crypto-shred deletion path documented for facility off-boarding | Phase 1.5 |

### Audit & Compliance
| # | Requirement | Source |
|---|-------------|--------|
| AU1 | Application-level audit log on all reads/writes of patient-identifying data | Phase 1.7 |
| AU2 | Audit log immutable via S3 Object Lock (compliance mode, 6-year) | Phase 1.7 |
| AU3 | No PII in operational logs (CloudWatch); enforced via Powertools log scrubber | Phase 1.6 |
| AU4 | CloudTrail enabled on all accounts with management events at minimum | Phase 1.5 |

### Data Lifecycle
| # | Requirement | Source |
|---|-------------|--------|
| L1 | Activity Series TTL: 13 months (DDB), then S3 Glacier 6yr | Phase 1.5 |
| L2 | Alert History TTL: 24 months (DDB), then S3 Glacier 6yr | Phase 1.5 |
| L3 | CloudWatch Lambda log retention: 30d dev / 90d prod | Phase 1.6 |
| L4 | Audit log retention: 6 years (S3 Object Lock) | Phase 1.7 |
| L5 | Patient deletion path supports both soft delete and crypto-shred | Phase 1.5 |

---

## 15. Lambda Inventory

| Lambda | Stack | Phase | Status | Trigger | Architecture |
|--------|-------|-------|--------|---------|--------------|
| `gosteady-{env}-activity-processor` | Processing | 1B | 🔄 Implemented (revisions pending) | IoT Rule | ARM64 |
| `gosteady-{env}-threshold-detector` | Processing | 1B | 🔄 Replaces heartbeat-processor | IoT Shadow Δ | ARM64 |
| `gosteady-{env}-alert-handler` | Processing | 1B | 🔄 Implemented (revisions pending) | IoT Rule | ARM64 |
| `gosteady-{env}-audit-writer` | Audit | 1.7 | 🔲 New | Invoked from handlers via Powertools | ARM64 |
| `gosteady-{env}-jwt-authorizer` | Api | 2A | 🔲 New | API Gateway | ARM64 |
| `gosteady-{env}-api-handler` | Api | 2A | 🔲 Stub | API Gateway | ARM64 |
| `gosteady-{env}-scheduled-jobs` | Processing | 1C | 🔲 Stub | EventBridge cron | ARM64 |
| `gosteady-{env}-offline-detector` | Processing | 1C | 🔲 Stub | IoT Events OR EventBridge cron | ARM64 |
| `gosteady-{env}-notification-dispatcher` | Notification | 2C | 🔲 Stub | EventBridge | ARM64 |

---

## 16. Open Questions

### Immediate (resolve before Phase 2A)
- [ ] **Alert suppression:** Should a repeated `battery_critical` shadow delta create a new alert each hour, or suppress while prior alert is unacknowledged? (lean: suppress with daily reminder cadence)
- [ ] **Timezone backfill:** When Phase 2A links a device to a patient, should we backfill `patientId` and recompute `date` on historical activity rows? (lean: yes, one-time migration job)
- [ ] **Daily rollup scope:** Steps/distance/active-min by day? By hour? Both?
- [ ] **Audit hot-path latency:** Acceptable to add ~10ms per mutation for synchronous audit write? Or fire-and-forget via SQS?
- [ ] **Multi-facility caregiver UX:** Single facility selector, or unified inbox across all assigned facilities?

### Medium-Term (Phase 2–3)
- [ ] **WAF rule tuning:** AWS Managed Rules baseline vs. custom rules for portal API
- [ ] **Secrets rotation:** Cadence for any partner credentials in Secrets Manager
- [ ] **Multi-device per patient:** Schema supports it, but does the portal UX need cross-device aggregation?
- [ ] **Family viewer activation flow:** Self-service link request, admin approval, or both?

### Long-Term (Phase 5+)
- [ ] **Battery life in production:** Real-world drain rate
- [ ] **Manufacturing provisioning:** Batch claim-cert flashing workflow
- [ ] **Reopening Phase 4 (FHIR/HL7v2):** Trigger criteria and partner-driven scope
- [ ] **HIPAA program formalization:** Trigger when first clinical-channel customer signs

---

## 17. Spec Index

| Phase | Title | Spec File | Status |
|-------|-------|-----------|--------|
| 0A | Auth Stack (original) | [`phase-0a-auth.md`](phase-0a-auth.md) | ✅ Deployed |
| 0A-rev | Auth Revision (multi-tenancy + RBAC + MFA) | [`phase-0a-revision.md`](phase-0a-revision.md) | 🔲 Planned |
| 0B | Data Layer | [`phase-0b-data.md`](phase-0b-data.md) | 🔄 Revision pending |
| 1A | IoT Ingestion | [`phase-1a-ingestion.md`](phase-1a-ingestion.md) | ✅ Deployed |
| 1B | Processing Logic | [`phase-1b-processing.md`](phase-1b-processing.md) | 🔄 Revision pending |
| 1C | Scheduled Jobs | — | 🔲 Planned |
| 1.5 | Security Foundation | [`phase-1.5-security.md`](phase-1.5-security.md) | 🔲 Planned (new) |
| 1.6 | Observability | — | 🔲 Planned (new) |
| 1.7 | Audit Logging | — | 🔲 Planned (new) |
| 2A | Portal API | — | 🔲 Planned |
| 2B | Portal Integration | — | 🔲 Planned |
| 2C | Notifications | — | 🔲 Planned |
| 3A | Portal Hosting | — | 🔲 Planned |
| 3B | CI/CD Pipeline | — | 🔲 Planned |
| 5A | Device Onboarding | — | ⬜ Future |
| 5B | End-to-End Validation | — | ⬜ Future |

> Phases 4A/4B/4C (FHIR, HL7v2, Bulk Export) are **cut from active roadmap**. See §12 for trigger criteria to reopen.

---

*Template for per-phase specs: [`_TEMPLATE.md`](_TEMPLATE.md)*

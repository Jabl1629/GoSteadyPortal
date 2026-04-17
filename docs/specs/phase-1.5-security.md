# Phase 1.5 — Security Foundation

## Overview
- **Phase**: 1.5
- **Status**: Planned
- **Branch**: feature/phase-1.5-security (TBD)
- **Date Started**: TBD
- **Date Completed**: TBD

Establishes the cross-cutting security primitives the rest of the platform
depends on: KMS customer-managed keys for identity-bearing data, AWS
Organizations + multi-account plan, CloudTrail for AWS API audit, Lambda
ARM64 migration, Cognito MFA + session timeout configuration, and a
least-privilege audit of all IAM roles. **This phase is gating for any
production customer data** — Phase 2A (Portal API) and Phase 1.7 (Application
Audit Logging) both depend on the CMKs and account structure delivered here.

## Locked-In Requirements
> Decisions finalized in this or prior phases that CANNOT change without
> cascading impact. Treat as immovable constraints.

| # | Requirement | Decided In | Rationale |
|---|-------------|-----------|-----------|
| L1 | AWS region `us-east-1` | Phase 0A | IoT Core endpoint + ACM for CloudFront |
| L2 | Single-account dev (`460223323193`); prod and shared-services accounts via AWS Organizations | Architecture §2 | Future BAA scoping + blast-radius isolation |
| L3 | KMS CMKs only on identity-bearing tables + S3 OTA bucket; AWS-managed keys acceptable for telemetry/log/queue | Architecture §9 | Cost-vs-value: ~3 CMKs ≈ $3/mo, full coverage would be 10× without proportional benefit |
| L4 | Annual CMK rotation enabled | Architecture §9 | AWS best practice, no operational cost |
| L5 | Crypto-shredding (CMK deletion with 7-day waiting period) is the deletion mechanism for facility off-boarding | Architecture §11 | Cleanest "right to be forgotten" primitive when paired with archived encrypted data |
| L6 | Lambda architecture: ARM64 (Graviton) | Architecture §2 | 20 % cost reduction, no Python compatibility concerns |
| L7 | Customer session: 15-min idle access token | Architecture §14 A6 | Healthcare-norm; offsets risk of unattended portal sessions |
| L8 | Internal session: 30-min idle / 4-hr absolute | Architecture §14 A6 | Tighter cap on cross-tenant access surface |
| L9 | MFA required for all admin roles (`facility_admin`, `client_admin`) and all internal roles (`internal_*`) | Architecture §14 A7 | Standard for any role with cross-patient or cross-tenant authority |
| L10 | TLS 1.2 minimum on every public surface (IoT Core, API Gateway, CloudFront, Cognito) | Architecture §9 | Minimum for HIPAA-compatibility and modern browsers |
| L11 | No long-lived IAM user access keys for human users; SSO/console access only | Architecture §14 (this phase) | Eliminates a top compromise vector |
| L12 | CloudTrail enabled in every account with management events at minimum; 90-day CloudWatch retention + indefinite S3 archive (Object Lock) | Architecture §14 AU4 | Required for compliance posture and incident forensics |

## Assumptions
> Beliefs we're building on that haven't been fully validated.
> If any prove wrong, flag immediately — they may invalidate this phase.

| # | Assumption | Risk if Wrong | Validation Plan |
|---|-----------|---------------|-----------------|
| A1 | Migrating the existing dev account into a new AWS Organization is a one-way, non-destructive operation that preserves all existing resources | Dev resources break / require recreation | Use AWS's documented invite-and-accept flow; test with a throwaway account first |
| A2 | Switching deployed Lambda functions from x86 to ARM64 via CDK redeploy is transparent (no payload incompatibility, no native binary issues in `boto3`) | Lambdas fail at runtime after switch | `boto3` is pure-Python; no native deps. Verify with one Lambda first, then bulk migrate. |
| A3 | DynamoDB tables can have their encryption swapped from AWS-managed to CMK in-place without data migration | If actually requires recreate, would need data export/import for already-deployed tables | AWS docs confirm in-place swap is supported via UpdateTable; verify on a test table first |
| A4 | Cognito User Pool MFA can be set to "Required" for specific groups via custom flow, not just pool-wide | Would force MFA on all users including patients (poor UX for elderly patients with feature phones) | Cognito supports group-aware MFA via custom auth challenges; verify with prototype |
| A5 | Annual CMK rotation does not invalidate previously-encrypted data (AWS handles transparent decryption with old key versions) | Would break decryption of historical records | AWS-documented behavior; covered by SLA |
| A6 | All current Lambda execution roles can be tightened without breaking handlers (we don't depend on any inadvertently-broad permissions) | Handlers fail in production after IAM tightening | Audit each handler's actual `boto3` calls; deploy tightened policies to dev first; have rollback ready |
| A7 | Multi-account billing consolidation is desirable (single invoice from AWS Organizations) | Some accounts may need separate billing (e.g., enterprise customer who pays directly) | Default to consolidated; revisit if a customer requires separate AWS billing |

## Scope

### In Scope
- **New stack `GoSteady-{Env}-Security`** containing:
  - 3 KMS Customer-Managed Keys (identity, firmware, audit)
  - CloudTrail trail with S3 destination (Object Lock, compliance mode)
  - Cost anomaly detection + billing alarm SNS topic
  - IAM password policy (minimum length, complexity, no reuse)
- **Modifications to existing stacks:**
  - `Auth` stack: reference identity CMK on `RoleAssignments` table; configure Cognito MFA + session lifetimes; create internal user provisioning flow
  - `Data` stack: reference identity CMK on `Patients`, `Users`, `Organizations`, `DeviceAssignments` tables (when those exist post-revision)
  - `Ingestion` stack: reference firmware CMK on S3 OTA bucket
  - `Processing` stack: switch all 3 Lambdas to `arm64`; grant `kms:Decrypt` on identity CMK to handlers that read identity tables
- **AWS Organizations setup:**
  - Create new AWS Organization in current dev account (becomes management account temporarily, will move to dedicated mgmt later)
  - OU structure created: `Workloads/Dev`, `Workloads/Prod`, `Shared/Logging`, `Shared/Security`
  - Service Control Policies (SCPs) drafted for region restriction (`us-east-1` only) and CMK protection
  - Existing dev account moved into `Workloads/Dev` OU
- **IAM least-privilege audit:**
  - Document current Lambda execution role permissions
  - Identify and remove any over-broad grants (e.g., `dynamodb:*` should be specific actions on specific tables)
  - Verify no IAM users have programmatic-only access keys
  - Verify root account access keys are absent
- **TLS 1.2 enforcement audit:**
  - IoT Core: confirm policy enforces TLS 1.2 (default since 2022, verify)
  - API Gateway: confirm minimum TLS 1.2 on custom domains (when Phase 2A lands)
  - CloudFront: minimum TLS 1.2 in viewer-policy (when Phase 3A lands)
- **Crypto-shredding deletion runbook** documented (process + commands)

### Out of Scope (Deferred)
- **Provisioning prod and shared-services AWS accounts** → deferred until first paying customer commitment is imminent (avoid running multiple empty accounts incurring CloudTrail cost)
- **Migrating existing dev resources to a dedicated dev account** → defer; current single-account dev becomes the "Dev" account in the new Org structure
- **Application-level audit logging** (every PHI read/write logged) → Phase 1.7
- **Lambda Powertools, X-Ray, structured logging, log scrubbing** → Phase 1.6
- **WAF web ACL** for portal API → Phase 2A
- **Secrets Manager rotation policies** → deferred; no secrets stored yet
- **VPC isolation** → not needed for serverless MVP; revisit if a vendor or auditor requires it
- **HIPAA BAA execution + formal HIPAA program** → triggered by first clinical-channel customer signing
- **Per-Lambda log retention enforcement** → Phase 1.6 (alongside Powertools)
- **CloudWatch alarm catalog** (DLQ depth, Lambda errors, etc.) → Phase 1.6 (cost alarms are in 1.5; ops alarms in 1.6)
- **CMK-protected backup of CloudTrail logs cross-account** → deferred until shared-services account is provisioned

## Architecture

### Infrastructure Changes

#### New Stack: `GoSteady-{Env}-Security`
- `IdentityKey` — KMS CMK, alias `gosteady/{env}/identity`
  - Key policy: ops admin role gets full admin; identity-table-touching Lambda execution roles get `Decrypt`/`GenerateDataKey`/`DescribeKey`
  - Annual rotation enabled
- `FirmwareKey` — KMS CMK, alias `gosteady/{env}/firmware`
  - Key policy: ops admin role + IoT service principal (for OTA delivery) get encrypt/decrypt
  - Annual rotation enabled
- `AuditKey` — KMS CMK, alias `gosteady/{env}/audit`
  - Pre-created for Phase 1.7 use; no consumers in 1.5
  - Annual rotation enabled
- `CloudTrailBucket` — S3 bucket, KMS-encrypted with `AuditKey`, Object Lock enabled (compliance mode, default 6-year retention), versioning on, public access blocked
- `CloudTrail` — multi-region trail, management events, log file validation enabled, S3 destination = `CloudTrailBucket`, CloudWatch Log Group with 90-day retention
- `CostAlarmTopic` — SNS topic for billing/anomaly notifications
- `CostAnomalyMonitor` + `CostAnomalySubscription` — AWS Cost Anomaly Detection on full account, threshold-based alerts via SNS
- `BillingAlarm` — CloudWatch alarm at $100/mo dev, $500/mo prod (initial values, tunable)
- `IamPasswordPolicy` — minimum 14 chars, all character classes, 90-day max age, no reuse of last 12

#### Modifications

| Existing Stack | Change |
|---|---|
| `GoSteady-{Env}-Auth` | RoleAssignments table `encryption: TableEncryption.CUSTOMER_MANAGED` referencing IdentityKey; Cognito User Pool MFA: `Required` for groups `facility_admin`, `client_admin`, `internal_*`; access token validity = 15 min (customer) / 30 min (internal) via App Client variants; refresh token validity = 30 days (customer) / 4 hr (internal); add internal-user provisioning flow (admin-create-user only, no self-signup) |
| `GoSteady-{Env}-Data` | All identity tables (when they exist post-Phase 0B revision: Patients, Users, Organizations, DeviceAssignments) get `TableEncryption.CUSTOMER_MANAGED` referencing IdentityKey |
| `GoSteady-{Env}-Ingestion` | S3 OTA bucket `encryption: BucketEncryption.KMS` referencing FirmwareKey; SQS DLQ remains AWS-managed |
| `GoSteady-{Env}-Processing` | All 3 Lambdas: `architecture: lambda.Architecture.ARM_64`; execution roles get `IdentityKey.grantDecrypt(role)` for handlers that read identity tables (activity processor reads patient/user for tz lookup) |

#### AWS Organizations
- Existing dev account becomes the management account of a new Organization (acceptable as bootstrap; can move management to a dedicated account later via account migration)
- Org features: All Features enabled (required for SCPs)
- OUs created: `Workloads`, `Workloads/Dev`, `Workloads/Prod` (empty), `Shared`, `Shared/Logging` (empty), `Shared/Security` (empty)
- Existing dev account moved into `Workloads/Dev`
- SCPs drafted (not yet attached, since they could lock out current dev work):
  - `RestrictRegionToUsEast1` — deny all actions outside `us-east-1` (with carve-outs for global services like IAM, CloudFront, Route53)
  - `ProtectKmsKeys` — deny `kms:ScheduleKeyDeletion` and `kms:DisableKey` on production CMKs except from break-glass IAM role
  - `RequireImdsv2` — deny launching EC2 without IMDSv2 (defensive even though we don't run EC2)
- SCPs reviewed but **not attached in Phase 1.5** — attaching is a Phase 2A precondition (verifying prod-bound code respects the policies)

### Data Flow / Reference Diagram

```
                    ┌─────────────────────────────────────┐
                    │   GoSteady-{Env}-Security stack     │
                    │                                     │
                    │   IdentityKey  FirmwareKey  AuditKey│
                    │       │            │           │    │
                    │   CloudTrailBucket ◄─ AuditKey      │
                    │       ▲                             │
                    │       │ writes                      │
                    │   CloudTrail (mgmt events)          │
                    │                                     │
                    │   CostAnomalyMonitor → SNS          │
                    └────────┬─────────┬──────────────────┘
                             │         │
            ┌────────────────┘         └──────────────┐
            ▼                                          ▼
   ┌──────────────────┐                       ┌──────────────────┐
   │ Auth Stack       │                       │ Data Stack       │
   │ • RoleAssignments│ ◄─ IdentityKey ───►   │ • Patients       │
   │   (CMK encrypt)  │                       │ • Users          │
   │ • Cognito MFA    │                       │ • Organizations  │
   │ • Session TTLs   │                       │ • DeviceAssign.  │
   └──────────────────┘                       │   (CMK encrypt)  │
                                              └──────────────────┘
   ┌──────────────────┐
   │ Ingestion Stack  │ ◄─ FirmwareKey
   │ • S3 OTA bucket  │
   │   (CMK encrypt)  │
   └──────────────────┘

   ┌──────────────────┐
   │ Processing Stack │
   │ • All Lambdas    │ ── grant kms:Decrypt on IdentityKey to
   │   ARM64          │     activity-processor (reads patient/user)
   └──────────────────┘
```

### Interfaces

- **CMK ARNs exported** from Security stack via CloudFormation outputs:
  - `IdentityKeyArn`, `IdentityKeyAlias`
  - `FirmwareKeyArn`, `FirmwareKeyAlias`
  - `AuditKeyArn`, `AuditKeyAlias`
- **CloudTrail S3 bucket name** exported for Phase 1.7 audit log destination reuse
- **SNS topic ARN** exported for cost alarms (other stacks may add their own subscriptions later)
- **Cognito changes:**
  - Two App Clients: `Portal-Customer` (15-min idle) and `Portal-Internal` (30-min idle, 4-hr absolute)
  - MFA setting: `OPTIONAL` at pool level, `REQUIRED` enforced via Pre-Token-Generation Lambda trigger that rejects auth for admin/internal roles without an MFA-verified session
  - User group attribute `mfa_required: true` on admin/internal groups (for clarity even though enforcement is via Lambda trigger)

## Implementation

### Files Changed / Created

| File | Change Type | Description |
|------|------------|-------------|
| `infra/lib/stacks/security-stack.ts` | New | KMS CMKs, CloudTrail, cost alarms, IAM password policy |
| `infra/lib/constructs/cmk.ts` | New | Reusable CMK construct with standard rotation/policy |
| `infra/lib/stacks/auth-stack.ts` | Modified | Reference IdentityKey on RoleAssignments; Cognito MFA + dual App Clients; pre-token-gen Lambda trigger |
| `infra/lambda/cognito-pre-token/handler.py` | New | Enforces MFA for admin/internal roles |
| `infra/lib/stacks/data-stack.ts` | Modified | Reference IdentityKey on identity-bearing tables (post-Phase 0B revision) |
| `infra/lib/stacks/ingestion-stack.ts` | Modified | Reference FirmwareKey on S3 OTA bucket |
| `infra/lib/stacks/processing-stack.ts` | Modified | `Architecture.ARM_64` on all Lambdas; `grantDecrypt` on IdentityKey for activity-processor |
| `infra/lib/config.ts` | Modified | Add `kmsCmkEnabled` flag (true for both env), `lambdaArchitecture: 'arm64'`, `cloudTrailRetentionDays`, `costAlarmThreshold` |
| `infra/bin/gosteady.ts` | Modified | Instantiate Security stack first; wire CMK ARNs to other stacks |
| `docs/runbooks/crypto-shred-deletion.md` | New | Step-by-step runbook for CMK deletion as deletion primitive |
| `docs/runbooks/aws-org-bootstrap.md` | New | One-time AWS Organizations setup steps |
| `docs/specs/phase-1.5-security.md` | New | This document |

### Dependencies
- **Phase 0A revision** must land first (RoleAssignments table exists)
- **Phase 0B revision** must land first if applying CMKs to Patients/Users/Organizations tables — alternatively, deploy Security stack first with CMKs and reference them from 0B revision
- **No NPM package additions** — uses existing `aws-cdk-lib`
- **No Python package additions** for handlers (Cognito pre-token-gen is stdlib only)

### Configuration

| CDK Context Key | Dev | Prod | Notes |
|---|---|---|---|
| `kmsCmkEnabled` | `true` | `true` | Allows easy local testing with off if needed |
| `lambdaArchitecture` | `arm64` | `arm64` | |
| `cloudTrailRetentionDays` | `90` | `90` | Hot retention; S3 archive is indefinite |
| `cloudTrailObjectLockYears` | `6` | `6` | HIPAA-compatible default |
| `costAlarmThreshold` | `100` | `500` | USD/mo, tunable as usage stabilizes |
| `costAlarmEmail` | (env-set) | (env-set) | SNS subscription target |

## Testing

### Test Scenarios

| # | Scenario | Method | Expected Result | Status |
|---|----------|--------|-----------------|--------|
| T1 | Deploy Security stack to dev | `cdk deploy GoSteady-Dev-Security` | Stack creates 3 CMKs, CloudTrail, S3 bucket with Object Lock, SNS topic, billing alarm | Pending |
| T2 | Verify CMK rotation enabled | `aws kms get-key-rotation-status --key-id <id>` | `KeyRotationEnabled: true` for all 3 keys | Pending |
| T3 | Verify CloudTrail is logging | Make any AWS console action; `aws s3 ls s3://<cloudtrail-bucket>/AWSLogs/...` | Recent log file present within 5 min | Pending |
| T4 | Verify Object Lock on CloudTrail bucket | Attempt `aws s3 rm` of a log object | Denied: object lock policy blocks delete | Pending |
| T5 | Deploy modified Auth stack with CMK ref | `cdk deploy GoSteady-Dev-Auth` | RoleAssignments table now reports CMK encryption | Pending |
| T6 | Read RoleAssignments item from a test Lambda | `aws lambda invoke` | Read succeeds (Lambda role has kms:Decrypt grant) | Pending |
| T7 | Read RoleAssignments from a Lambda WITHOUT kms:Decrypt | Manually deny grant, invoke | `AccessDeniedException` from KMS | Pending |
| T8 | Switch one Lambda to ARM64, invoke | Deploy with `architecture: ARM_64`, then invoke with prior payload | Successful invocation, identical behavior | Pending |
| T9 | Cognito MFA required for `client_admin` group | Try to authenticate as a user in client_admin group without MFA token | Auth flow forces MFA challenge | Pending |
| T10 | Cognito MFA optional for `caregiver` group | Authenticate as caregiver | Login succeeds without MFA challenge | Pending |
| T11 | Customer App Client token expiry | Login → wait 15 min idle → call API | Token expired, refresh required | Pending |
| T12 | Internal App Client absolute expiry | Login → keep refreshing 4hr → next attempt | Refresh token rejected after absolute window | Pending |
| T13 | TLS 1.0 / 1.1 connection to IoT Core | `openssl s_client -connect <endpoint>:8883 -tls1_1` | Connection refused | Pending |
| T14 | Cost alarm triggers on threshold breach | Simulate via test publish to SNS topic | Email notification received | Pending |
| T15 | AWS Organization formed, dev account in `Workloads/Dev` OU | `aws organizations list-accounts-for-parent` | Dev account listed | Pending |
| T16 | Crypto-shred test on a throwaway CMK | Schedule deletion → wait 7 days → verify any data encrypted under that key cannot be decrypted | Decrypt fails post-deletion | Pending (run on test key, not production key) |

### Verification Commands

```bash
# List all CMKs and their aliases
aws kms list-aliases --region us-east-1 \
  | jq '.Aliases[] | select(.AliasName | startswith("alias/gosteady"))'

# Check rotation status
for key in $(aws kms list-aliases --region us-east-1 \
    --query 'Aliases[?starts_with(AliasName, `alias/gosteady`)].TargetKeyId' --output text); do
  echo "Key: $key"
  aws kms get-key-rotation-status --key-id $key --region us-east-1
done

# Verify CloudTrail is enabled and logging
aws cloudtrail describe-trails --region us-east-1
aws cloudtrail get-trail-status --name gosteady-dev-cloudtrail --region us-east-1

# Verify S3 Object Lock on CloudTrail bucket
aws s3api get-object-lock-configuration --bucket gosteady-dev-cloudtrail-logs

# Confirm Lambda architecture
for fn in activity-processor heartbeat-processor alert-handler; do
  aws lambda get-function-configuration --region us-east-1 \
    --function-name gosteady-dev-$fn \
    --query '{Name:FunctionName, Arch:Architectures}'
done

# Verify Cognito User Pool MFA configuration
aws cognito-idp describe-user-pool --region us-east-1 \
  --user-pool-id us-east-1_ZHbhl19tQ \
  --query 'UserPool.{MfaConfig:MfaConfiguration, PolicyMfa:Policies.PasswordPolicy}'

# Confirm Organization is set up
aws organizations describe-organization
aws organizations list-accounts
aws organizations list-organizational-units-for-parent --parent-id <root-id>

# IAM password policy
aws iam get-account-password-policy

# Confirm no IAM users have access keys (should return empty for human-named users)
aws iam list-users --query 'Users[].UserName' --output text \
  | xargs -n1 -I {} aws iam list-access-keys --user-name {} \
       --query 'AccessKeyMetadata[].{User:UserName, KeyId:AccessKeyId, Created:CreateDate}'
```

## Deployment

### Deploy Commands

```bash
# Deploy order matters: Security first, others reference its outputs
cd infra
npm run build

# 1. Deploy Security stack first (creates CMKs that other stacks reference)
npx cdk deploy GoSteady-Dev-Security --context env=dev --require-approval never

# 2. Deploy Auth stack (references IdentityKey)
npx cdk deploy GoSteady-Dev-Auth --context env=dev --require-approval never

# 3. Deploy Data stack (references IdentityKey, requires Phase 0B revision first)
npx cdk deploy GoSteady-Dev-Data --context env=dev --require-approval never

# 4. Deploy Ingestion stack (references FirmwareKey)
npx cdk deploy GoSteady-Dev-Ingestion --context env=dev --require-approval never

# 5. Deploy Processing stack (ARM64 + kms:Decrypt grant)
npx cdk deploy GoSteady-Dev-Processing --context env=dev --require-approval never

# Or all at once (CDK resolves dep order automatically):
npx cdk deploy --all --context env=dev --require-approval never
```

### One-time AWS Organizations Setup
> Manual; not CDK-managed. See `docs/runbooks/aws-org-bootstrap.md` for full steps.

```bash
# 1. From dev account root user, create Organization
aws organizations create-organization --feature-set ALL

# 2. Create OU structure
ROOT_ID=$(aws organizations list-roots --query 'Roots[0].Id' --output text)
aws organizations create-organizational-unit --parent-id $ROOT_ID --name Workloads
aws organizations create-organizational-unit --parent-id $ROOT_ID --name Shared
# (then nest Dev/Prod under Workloads, Logging/Security under Shared)

# 3. Move dev account into Workloads/Dev
# (account is already in Org as management; move via console or CLI)
```

### Rollback Plan

```bash
# Lambda ARM64 → x86 rollback (transparent, just redeploy)
# In CDK: change architecture back to X86_64, redeploy Processing stack

# CMK encryption rollback on a DDB table (back to AWS-managed)
# This IS supported in-place via CDK redeploy:
#   table.encryption = TableEncryption.AWS_MANAGED
# Data is re-encrypted with new key transparently.

# CloudTrail rollback: simply destroy the trail
# But: keep the S3 bucket and Object-Locked logs forever (compliance evidence)

# CMK deletion rollback: schedule-deletion has a 7-30 day waiting period
# during which the deletion can be cancelled with `cancel-key-deletion`
aws kms cancel-key-deletion --key-id <key-id>

# AWS Organizations rollback: more complex
# - Removing the management account from its own org effectively dissolves the org
# - SCPs are not yet attached in Phase 1.5, so removing them is a no-op
# - If anything goes wrong with Org setup, the safest fix is: create a new OU
#   structure rather than dissolve the org

# Cognito MFA rollback: change pool config back to OPTIONAL,
# update App Client token validities, revert pre-token Lambda trigger
```

## Decisions Log

| # | Decision | Alternatives Considered | Why This Choice |
|---|----------|------------------------|-----------------|
| D1 | One Security stack containing all CMKs + CloudTrail + cost alarms | Separate stacks per concern (KMS / CloudTrail / Billing) | Single stack reduces dependency-graph complexity; security primitives change together rarely enough that bundling is cleaner. Can split later if it gets too big. |
| D2 | 3 CMKs (identity, firmware, audit), not per-resource keys | One CMK for everything; one CMK per table | Per-family scoping makes key policies meaningful (audit reads use AuditKey only, etc.) without exploding count. Crypto-shred at a useful granularity (per data domain). |
| D3 | AWS-managed keys for telemetry tables (Activity, Alerts, Devices) | CMKs for everything | Telemetry has higher KMS API call volume; CMK per-call cost would meaningfully add up. Non-identity data; lower compliance pressure. Can upgrade later if a customer requires it. |
| D4 | CloudTrail destination is a CloudFormation-managed S3 bucket in the same account, not a cross-account central log archive | Cross-account central log destination | Single-account dev today. When shared-services account is provisioned (Phase 2A+), CloudTrail destination migrates there. Avoids creating empty accounts now. |
| D5 | S3 Object Lock in compliance mode (not governance mode) | Governance mode (admins can override); no Object Lock | Compliance mode is the only mode that resists insider deletion — required for "tamper-evident" claim. 6-year default retention is HIPAA-compatible. |
| D6 | AWS Organizations created in current dev account as management account | Wait until prod to set up Org; use a dedicated mgmt account from day 1 | Bootstrapping Org in dev account is reversible and lets us create OUs and SCPs now. Migrating mgmt to a dedicated account is straightforward later. |
| D7 | SCPs drafted but NOT attached in Phase 1.5 | Attach immediately | Risk of accidentally locking out dev work. Attach in Phase 2A after verifying current code paths respect them. |
| D8 | Cognito MFA enforced via Pre-Token-Generation Lambda trigger rather than pool-wide setting | Pool-wide REQUIRED MFA (forces all users); pool-wide OPTIONAL with no enforcement | Pool-wide REQUIRED would force MFA on patients (poor UX for elderly). Pool-wide OPTIONAL with no enforcement = no security. Lambda trigger lets us enforce per-group. |
| D9 | Two Cognito App Clients (Customer + Internal) with different token validities | Single App Client with same validity for everyone | Internal user tokens carry more risk (cross-tenant). Tighter expiry (30-min idle / 4-hr absolute) for internal limits the blast radius of a stolen token. |
| D10 | Lambda ARM64 globally for all functions | x86 default; per-Lambda decision | All current Lambdas are pure-Python with no native deps — universally safe to ARM. 20% cost win. |
| D11 | Annual KMS CMK rotation (not 90-day or quarterly) | More frequent rotation | Annual is AWS default and matches HIPAA expectations. More frequent rotation has minimal additional security benefit for KMS-managed keys (which are HSM-backed). |
| D12 | IAM password policy: 14 chars min, all classes, 90-day max age, no reuse of last 12 | NIST 800-63B "long passphrase, no rotation" | NIST modern guidance argues against forced rotation, but most healthcare auditors still expect rotation. Use the conservative policy until an auditor accepts the modern one. |
| D13 | Long-lived IAM user access keys disallowed (programmatic access via roles only) | Allow keys for CI/CD users | CI/CD will use OIDC federation (GitHub Actions → IAM role assumption) in Phase 3B. No need for long-lived keys. |

## Open Questions
- [ ] **Internal user provisioning UX**: do we provision through Cognito admin-create-user only (current plan), or stand up a tiny admin tool? Probably defer the tool until Phase 2A.
- [ ] **Cost alarm thresholds**: $100/mo dev and $500/mo prod are guesses. Tune after first month of real usage.
- [ ] **AWS Organizations management account placement**: long-term, the management account should not run workloads. Plan to migrate management to a dedicated account in Phase 2A or alongside prod-account creation.
- [ ] **Pre-Token Lambda trigger latency**: adds ~50ms to every login. Acceptable. Verify in load test for portal Phase 2B.
- [ ] **CloudTrail data events**: management events only in 1.5. Data events (S3 object reads, DynamoDB item-level) cost ~$0.10 per 100k events and are useful for audit. Decide threshold for enabling — likely Phase 1.7 alongside application audit.
- [ ] **MFA enrollment UX**: TOTP-only (Authenticator app) vs TOTP + SMS fallback. SMS-MFA is cheaper to support but less secure. Lean: TOTP-only for internal; TOTP-only for customer admins; revisit SMS if onboarding friction is high.
- [ ] **Multi-region for CloudTrail**: trail is multi-region (captures all regions even though we use only `us-east-1`). Worth keeping for posture even if no other regions are in use.

## Changelog
| Date | Author | Change |
|------|--------|--------|
| 2026-04-16 | Jace + Claude | Initial spec |

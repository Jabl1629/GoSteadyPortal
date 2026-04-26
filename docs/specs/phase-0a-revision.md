# Phase 0A Revision — Multi-Tenancy, RBAC, and Internal Access

## Overview
- **Phase**: 0A (Revision)
- **Status**: Planned
- **Branch**: feature/phase-0a-revision (TBD)
- **Date Started**: TBD
- **Date Completed**: TBD
- **Supersedes**: select decisions in [`phase-0a-auth.md`](phase-0a-auth.md) — see "Reversed/Superseded Decisions" below.

Restructures the Auth stack from the original walker/caregiver model into the
full multi-tenant access model defined in [`ARCHITECTURE.md`](ARCHITECTURE.md)
§4: customer-tier RBAC (`family_viewer` / `caregiver` / `facility_admin` /
`client_admin`) plus an internal-tier (`internal_support` / `internal_admin`)
that operates outside the customer tenancy boundary. Adds MFA enforcement via
Pre-Token-Generation Lambda trigger, two App Clients (Customer + Internal)
with role-appropriate session lifetimes, SAML/OIDC federation hooks, and
replaces the `Relationships` DynamoDB table with `RoleAssignments`.

**The existing User Pool is updated in place** — App Client IDs preserved, but
new client added; new attributes/groups added; deprecated artifacts left as
inert cruft (Cognito does not support attribute or group deletion). No
migration of dev users; recreate test accounts after deploy.

## Reversed / Superseded Decisions
Tracking what changes from the original [`phase-0a-auth.md`](phase-0a-auth.md):

| Original | Status | Replacement |
|----------|--------|-------------|
| L2: Email + password sign-in (no social/SAML) | **Reversed** | Email/password remains default; SAML/OIDC federation supported as opt-in per-customer |
| L3: Two roles `walker`, `caregiver` | **Replaced** | Customer roles: `family_viewer`, `caregiver`, `facility_admin`, `client_admin`, `patient`. Internal roles: `internal_support`, `internal_admin`. |
| L4: `custom:role` on JWT | **Kept**, value set expanded |
| L5: `custom:linked_devices` on JWT | **Deprecated** (left in pool as cruft) | Replaced by `custom:clientId` + `custom:facilities` + `custom:censuses` |
| A1: Email verification sufficient (no MFA) | **Reversed** | MFA required for admin/internal roles; optional for others |
| A2: One user = one role | **Kept** (confirmed by product owner: no staff-also-family case) |
| D2: Relationships table for caregiver↔walker links | **Replaced** | RoleAssignments table (PK: userId, single row per user with scoped IDs) |
| D3: `linked_devices` on JWT for fast device list | **Replaced** | Scope-list approach (`facilities` / `censuses` claims) plus DDB lookup for family-viewer patient lists |
| Token validity: 1h access, 30d refresh | **Replaced** | Customer client: 15-min idle / 30-day refresh. Internal client: 30-min idle / 4-hr absolute. |

## Locked-In Requirements

| # | Requirement | Decided In | Rationale |
|---|-------------|-----------|-----------|
| L1 | AWS Cognito for auth | Phase 0A original | Native AWS integration retained |
| L2 | Email/password default; SAML/OIDC federation supported per-customer | Architecture A2 (revised) | Facility chains require SSO; D2C uses email/password |
| L3 | Customer roles: `patient`, `family_viewer`, `household_owner`, `caregiver`, `facility_admin`, `client_admin` | Architecture A3 | Mirrors industry RBAC for senior-living/home-health; `household_owner` added for D2C primaries (softer MFA than enterprise admins) |
| L4 | Internal roles: `internal_support`, `internal_admin` | Architecture A3, T6 | Cross-tenant authority for GoSteady staff |
| L5 | One Client per customer user (hard rule); internal users belong to reserved `_internal` client | Architecture A5, T2, T6 | Tenancy boundary enforced at JWT layer |
| L6 | Custom JWT claims: `clientId`, `role`, `facilities`, `censuses` | Architecture A4 | Authorizer fast path with no DDB lookup for common cases |
| L7 | MFA **required** for `facility_admin`, `client_admin`, `internal_*` roles; **optional** for `household_owner`, `caregiver`, `family_viewer`, `patient` | Architecture A7 | Cross-patient or cross-tenant authority requires it; D2C household primaries get softer friction since blast radius is one household |
| L8 | Two App Clients (Customer + Internal) with distinct token lifetimes (15-min idle vs 30-min idle / 4-hr absolute) | Architecture A6 | Internal access blast radius cap |
| L9 | RoleAssignments table replaces Relationships; one row per user | Architecture §6 | Per-user scope record matches the one-role-per-user invariant |
| L10 | RoleAssignments table encrypted with IdentityKey CMK | Phase 1.5 | Identity-bearing data |
| L11 | Internal users created via admin-create-user only (no self-signup) | Architecture §4 Internal Access | Provisioning is intentional, audited |
| L12 | MFA mechanism: TOTP only (no SMS) | This phase D6 | Stronger; lower cost; decisive default |

## Assumptions

| # | Assumption | Risk if Wrong | Validation Plan |
|---|-----------|---------------|-----------------|
| A1 | Cognito User Pool can have new groups, attributes, App Clients added in place without disrupting existing App Client | Existing portal client's tokens become invalid mid-revision | Cognito changes are additive; verified in AWS docs; deploy to dev with no real users |
| A2 | Pre-Token Generation Lambda V2 trigger can modify both ID and Access token claims | If only ID-token modification works, authorizer needs to use ID token instead of Access | V2 triggers documented to support both since 2023 |
| A3 | Pre-Token Lambda cold-start adds <100ms to first sign-in per session; warm < 20ms | Login feels sluggish to users | Bench in dev; provision concurrency if needed |
| A4 | Family viewer patient-link list (`linkedPatientIds` in RoleAssignments) can be looked up at API request time, not embedded in JWT | If JWT-embedded list is required for performance, we hit Cognito 2KB attribute limit for users with many linked patients | Lookup is one DDB GetItem per request, ~5ms; cache in API layer if it becomes hot |
| A5 | Existing dev Cognito users can be discarded with no migration | If business stakeholder counted on demo accounts, surprise loss | Confirm with product owner; document recreate steps |
| A6 | TOTP-only MFA (Authenticator app) is acceptable for users; no SMS fallback needed at MVP | Onboarding friction for users without smartphones | All target users have caregiver-grade smartphones; revisit if data shows abandonment |
| A7 | SAML/OIDC federation can be configured later per-customer without recreating the User Pool | Federation requires pool-level features that must exist at creation | Cognito supports adding IdPs to existing pools |
| A8 | `walker` group and `custom:linked_devices` attribute can be left in pool as inert cruft without affecting authz | Some path inadvertently honors deprecated attribute | Code review for any reference to those names; remove from CDK; flag in observability |

## Scope

### In Scope

#### Cognito User Pool (in-place updates)
- New custom attributes (additive):
  - `custom:clientId` (string, mutable, max length 64)
  - `custom:facilities` (string, mutable, max length 2048 — comma-separated facility IDs)
  - `custom:censuses` (string, mutable, max length 2048 — comma-separated census IDs)
- Existing `custom:role` attribute reused with expanded value set
- New Cognito Groups (precedence in parens, lower = higher priority):
  - `internal_admin` (1)
  - `internal_support` (2)
  - `client_admin` (3)
  - `facility_admin` (4)
  - `household_owner` (5) — D2C household primary, softer MFA
  - `caregiver` (6) — kept from original
  - `family_viewer` (7)
  - `patient` (8)
- Existing groups left as deprecated cruft:
  - `walker` (no new users; existing test users to be deleted manually post-deploy)
- MFA configuration:
  - Pool-level MFA: `OPTIONAL`
  - Per-group enforcement via Pre-Token-Generation Lambda trigger
  - Software TOTP (Authenticator app) only — SMS MFA disabled
- Federation hooks:
  - Hosted UI configured to allow IdP selection
  - SAML/OIDC IdPs added per-customer at customer-onboarding time (no IdPs configured in this phase)

#### App Clients
- **Existing client `1q9l9ujtsomf3ugq2tnqvdg6d7`** repurposed as `Portal-Customer`:
  - Access + ID token validity: 15 min
  - Refresh token validity: 30 days
  - Auth flows: `USER_SRP_AUTH`, `USER_PASSWORD_AUTH` (legacy), `REFRESH_TOKEN_AUTH`
  - OAuth flows: authorization code grant
  - Callback URLs: `http://localhost:8080`, `https://portal.gosteady.co`
- **New client `Portal-Internal`**:
  - Access + ID token validity: 30 min
  - Refresh token validity: 4 hr (absolute session cap)
  - Auth flows: `USER_SRP_AUTH`, `REFRESH_TOKEN_AUTH` (no `USER_PASSWORD_AUTH`)
  - OAuth flows: authorization code grant
  - Callback URLs: separate internal admin tool URL (TBD by ops; default `http://localhost:8090` for dev)
  - Generate client secret: yes (internal tool can hold secret server-side)

#### Pre-Token Generation Lambda (new)
- Function name: `gosteady-{env}-cognito-pre-token`
- Runtime: Python 3.12, ARM64
- Triggered on every authentication (sign-in + refresh)
- Logic:
  1. Fetch user's RoleAssignments record from DDB by `userId` (Cognito sub)
  2. If no RoleAssignment exists, deny with custom error `NO_ROLE_ASSIGNED`
  3. Validate user's group membership matches their RoleAssignments role
  4. If role ∈ {`facility_admin`, `client_admin`, `internal_support`, `internal_admin`}: require MFA verification in current auth context; else deny with `MFA_REQUIRED`. (`household_owner`, `caregiver`, `family_viewer`, `patient` are **not** MFA-gated — MFA is optional for these roles, enrolled via UX prompts.)
  5. If role ∈ `internal_*`: validate `clientId` == `"_internal"`; else deny with `TENANCY_VIOLATION`
  6. If role == `household_owner`: validate `clientId` starts with `"dtc_"`; else deny with `TENANCY_VIOLATION`
  7. Inject claims into ID + Access token: `custom:clientId`, `custom:role`, `custom:facilities`, `custom:censuses`
- IAM permissions:
  - DynamoDB: `GetItem` on RoleAssignments table
  - KMS: `Decrypt` on IdentityKey CMK
  - CloudWatch Logs: standard

#### RoleAssignments Table (new, replaces Relationships)
| Attribute | Type | Notes |
|-----------|------|-------|
| **userId** (PK) | S | Cognito `sub` |
| clientId | S | Tenancy boundary; one per user |
| role | S | One of the 7 roles |
| scopedFacilityIds | SS | Empty = all in client (for `client_admin`) |
| scopedCensusIds | SS | Empty = all in scoped facilities |
| linkedPatientIds | SS | For `family_viewer` only |
| validFrom | S | ISO 8601 |
| validUntil | S | ISO 8601, nullable |
| assignedBy | S | userId of admin who granted |
| createdAt | S | ISO 8601 |
- **GSI `by-client-role`**: PK `clientId`, SK `role#userId`
- Encryption: KMS CMK (IdentityKey from Phase 1.5 Security stack)
- Billing: PAY_PER_REQUEST
- PITR: per env config

#### Decommission Relationships Table
- Existing `gosteady-{env}-relationships` table destroyed (no production data)
- Removed from CDK; resources cleaned up via stack update

#### Branded verification email retained
- Subject and body from original 0A spec preserved

#### Self-signup configuration
- D2C signup path: enabled, default group on signup = `patient` initially with no role assignment, must complete a "household setup" flow to provision RoleAssignment + synthetic D2C client (provisioning workflow in Phase 2A)
- Facility user signup: disabled at pool level; users created by admin within their client (CLI/console for now; admin tool in Phase 2A)
- Internal user signup: disabled at pool level; admin-create-user only (CLI/console)

### Out of Scope (Deferred)

- **Patients table, Users table, Organizations table** → Phase 0B revision
- **Specific SAML/OIDC IdP configurations for individual customers** → per-customer onboarding (no fixed phase)
- **Family-viewer patient-linking workflow UI** → Phase 2A admin tools
- **Internal user provisioning UI / "admin tool"** → Phase 2A or later
- **Synthetic D2C client provisioning on patient signup** → Phase 2A (signup flow)
- **MFA enrollment UX** in the Flutter app → Phase 2B
- **Audit logging of authentication events** → Phase 1.7
- **SCP attachment** for region restriction → Phase 1.5 / Phase 2A
- **Account migration** of any existing dev test users → not migrated; recreate

## Architecture

### Infrastructure Changes

#### Stack: `GoSteady-{Env}-Auth` (modified)

| Resource | Action |
|----------|--------|
| `gosteady-{env}-users` Cognito User Pool | Modified: add custom attributes (`clientId`, `facilities`, `censuses`); add 6 groups; configure MFA `OPTIONAL` with TOTP enabled; attach Pre-Token Generation Lambda trigger |
| `Portal-Customer` App Client (existing ID retained) | Modified: rename, change token validity to 15 min |
| `Portal-Internal` App Client | New: 30-min idle / 4-hr absolute, with client secret |
| `gosteady-{env}-cognito-pre-token` Lambda | New: Python 3.12 ARM64, IAM grants for RoleAssignments + IdentityKey CMK |
| `gosteady-{env}-role-assignments` DynamoDB table | New: see schema above; CMK-encrypted |
| `gosteady-{env}-relationships` DynamoDB table | Removed |

### Data Flow

```
   Sign-in / Refresh
         │
         ▼
   ┌───────────────────────────────────────────────────────┐
   │ Cognito User Pool                                      │
   │ • Validates email/password OR SAML assertion           │
   │ • If MFA enrolled, completes MFA challenge             │
   │                                                        │
   │ ┌─────────────────────────────────────────────────┐    │
   │ │ Pre-Token Generation Lambda (V2 trigger)        │    │
   │ │ 1. GetItem RoleAssignments[userId]              │    │
   │ │ 2. Check role exists                            │    │
   │ │ 3. Enforce MFA for admin/internal roles         │    │
   │ │ 4. Validate _internal client for internal roles │    │
   │ │ 5. Inject claims: clientId, role,               │    │
   │ │    facilities, censuses                         │    │
   │ └─────────────────────────────────────────────────┘    │
   │                                                        │
   │ Returns: ID Token + Access Token + Refresh Token       │
   └────────────────────┬───────────────────────────────────┘
                        │
                        ▼
   Custom claims available to API Gateway authorizer
   without further DDB lookup
```

### Interfaces

- **Cognito User Pool ID**: `us-east-1_ZHbhl19tQ` (preserved)
- **Portal-Customer App Client ID**: `1q9l9ujtsomf3ugq2tnqvdg6d7` (preserved)
- **Portal-Internal App Client ID**: TBD on creation
- **Custom JWT claims** (in both ID and Access tokens after Pre-Token trigger):
  ```
  custom:clientId   → "client_005" | "dtc_<userId>" | "_internal"
  custom:role       → "family_viewer" | "caregiver" | "facility_admin" |
                       "client_admin" | "patient" |
                       "internal_support" | "internal_admin"
  custom:facilities → "fac_012,fac_018" (empty for unrestricted)
  custom:censuses   → "cen_044,cen_045" (empty for unrestricted)
  ```
- **DynamoDB**: `gosteady-{env}-role-assignments` (PK: userId)
- **Pre-Token Lambda errors** (custom):
  - `NO_ROLE_ASSIGNED`
  - `MFA_REQUIRED`
  - `TENANCY_VIOLATION`

## Implementation

### Files Changed / Created

| File | Change Type | Description |
|------|------------|-------------|
| `infra/lib/stacks/auth-stack.ts` | Modified | Add custom attrs, groups, second App Client, pre-token trigger; replace Relationships with RoleAssignments |
| `infra/lambda/cognito-pre-token/handler.py` | New | Pre-Token Lambda implementation |
| `infra/lambda/cognito-pre-token/requirements.txt` | New | (stdlib only — empty or boto3) |
| `infra/lib/constructs/role-assignments-table.ts` | New | DDB table construct with CMK reference |
| `infra/lib/config.ts` | Modified | Add `customerTokenIdleMinutes`, `internalTokenIdleMinutes`, `internalTokenAbsoluteMinutes` |
| `infra/bin/gosteady.ts` | Modified | Wire IdentityKey from Security stack into Auth stack |
| `lib/config/cognito_config.dart` | Modified | Token expiry handling for shorter validity |
| `lib/services/auth_service.dart` | Modified | Auto-refresh logic for 15-min tokens; MFA prompt UI hooks |
| `docs/specs/phase-0a-revision.md` | New | This document |
| `docs/runbooks/internal-user-provisioning.md` | New | Step-by-step admin-create-user flow for internal accounts |

### Dependencies

- **Phase 1.5 Security stack** — already deployed 2026-04-17. `IdentityKey` CMK (alias `gosteady/dev/identity`) is live and exported; Auth stack imports the CMK ARN via cross-stack reference for RoleAssignments table encryption.
- **Existing 0A deployment** is the starting state (additive changes only)
- **Phase 0B revision** is **not** a dependency — 0A revision can deploy independently; RoleAssignments rows with `linkedPatientIds` will reference non-existent Patient IDs until 0B lands, which is acceptable (data resolves once 0B does).
- No new NPM packages
- Pre-Token Lambda uses `boto3` (already in Lambda runtime) — no requirements.txt entries

### Configuration

| CDK Context Key | Dev | Prod | Notes |
|---|---|---|---|
| `customerTokenIdleMinutes` | `15` | `15` | |
| `internalTokenIdleMinutes` | `30` | `30` | |
| `internalTokenAbsoluteMinutes` | `240` | `240` | 4 hr |
| `customerRefreshDays` | `30` | `30` | |
| `mfaRequiredRoles` | (json array) | (json array) | `["facility_admin","client_admin","internal_support","internal_admin"]` — note: `household_owner` intentionally excluded |

## Testing

### Test Scenarios

| # | Scenario | Method | Expected Result | Status |
|---|----------|--------|-----------------|--------|
| T1 | Deploy revised Auth stack to dev | `cdk deploy GoSteady-Dev-Auth` | Stack updates: new attrs, groups, App Client, pre-token trigger; RoleAssignments table created; Relationships table removed | Pending |
| T2 | Create test customer caregiver: signup → admin-add to `caregiver` group → admin-create RoleAssignment row | AWS console + CLI | User exists, can authenticate | Pending |
| T3 | Customer caregiver signs in (no MFA, no admin role) | SRP auth | Returns tokens with `custom:clientId`, `custom:role=caregiver`, `custom:facilities`, `custom:censuses` populated | Pending |
| T4 | Customer caregiver token expires after 15 min idle | Wait, then call API | Token rejected; refresh succeeds | Pending |
| T5 | Customer `client_admin` signs in WITHOUT MFA enrolled | SRP auth | Pre-Token Lambda denies with `MFA_REQUIRED` | Pending |
| T6 | Customer `client_admin` enrolls TOTP, signs in WITH MFA | SRP + MFA challenge | Tokens returned with admin claims | Pending |
| T7 | Internal admin user provisioned via `admin-create-user` (no self-signup) | CLI | User exists in `internal_admin` group, RoleAssignment with `clientId=_internal` | Pending |
| T8 | Internal admin signs in via Portal-Internal client with MFA | SRP + MFA | Tokens returned, ID-token has `custom:clientId=_internal`, `custom:role=internal_admin` | Pending |
| T9 | Internal admin token absolute expiry after 4 hr | Wait, refresh repeatedly for 4 hr | Refresh rejected after absolute window | Pending |
| T10 | User with no RoleAssignment record signs in | SRP auth | Pre-Token Lambda denies with `NO_ROLE_ASSIGNED` | Pending |
| T11 | Internal role user with `clientId != _internal` in their RoleAssignment | (set up edge case in DDB) | Pre-Token Lambda denies with `TENANCY_VIOLATION` | Pending |
| T12 | RoleAssignments table item is encrypted with IdentityKey CMK | `aws dynamodb describe-table` | `SSEDescription.KMSMasterKeyArn` references `IdentityKey` | Pending |
| T13 | Read RoleAssignments item from a Lambda WITHOUT kms:Decrypt grant | Manually deny grant | `AccessDeniedException` from KMS | Pending |
| T14 | Self-signup as `family_viewer` (D2C) | Hosted UI signup | User created in `patient` group temporarily; needs household-setup workflow before any data access | Pending |
| T15 | Branded verification email | Email inbox | Subject: "GoSteady — Verify your email" | Pending (regression of original) |
| T16 | Existing `walker` group still present (deprecated) | `aws cognito-idp list-groups` | Returns including `walker` | Pending (intended cruft) |
| T17 | Existing `custom:linked_devices` attribute still present (deprecated) | `aws cognito-idp describe-user-pool` | Attribute listed in pool schema | Pending (intended cruft) |

### Verification Commands

```bash
# Confirm new groups exist
aws cognito-idp list-groups --user-pool-id us-east-1_ZHbhl19tQ --region us-east-1

# Confirm new custom attributes
aws cognito-idp describe-user-pool --user-pool-id us-east-1_ZHbhl19tQ --region us-east-1 \
  --query "UserPool.SchemaAttributes[?starts_with(Name, 'custom:')]"

# Confirm both App Clients exist
aws cognito-idp list-user-pool-clients --user-pool-id us-east-1_ZHbhl19tQ --region us-east-1

# Confirm Pre-Token Lambda is wired
aws cognito-idp describe-user-pool --user-pool-id us-east-1_ZHbhl19tQ --region us-east-1 \
  --query "UserPool.LambdaConfig"

# Confirm RoleAssignments table exists with CMK
aws dynamodb describe-table --table-name gosteady-dev-role-assignments --region us-east-1 \
  --query "Table.{Status:TableStatus, SSE:SSEDescription, GSIs:GlobalSecondaryIndexes[].IndexName}"

# Confirm Relationships table is removed
aws dynamodb describe-table --table-name gosteady-dev-relationships --region us-east-1 \
  || echo "Table removed (expected)"

# Test Pre-Token Lambda directly with a sample event
aws lambda invoke --function-name gosteady-dev-cognito-pre-token --region us-east-1 \
  --payload fileb:///tmp/sample-pretoken-event.json /tmp/out.json && cat /tmp/out.json
```

## Deployment

### Deploy Commands

```bash
cd infra
npm run build

# Phase 1.5 Security stack already deployed 2026-04-17 — IdentityKey CMK
# is live and referenced by Auth stack via cross-stack import.
npx cdk deploy GoSteady-Dev-Auth --context env=dev --require-approval never

# Manually create test users post-deploy (no auto-migration)
# See docs/runbooks/internal-user-provisioning.md
```

### Rollback Plan

```bash
# Auth stack rollback to pre-revision state
git revert <phase-0a-revision-commit-sha>
cd infra && npm run build
npx cdk deploy GoSteady-Dev-Auth --context env=dev --require-approval never

# Note: rollback recreates Relationships table; any RoleAssignments
# data is lost. Acceptable for dev (no production users).
# Pre-Token Lambda invocations stop on detach.
```

## Decisions Log

| # | Decision | Alternatives Considered | Why This Choice |
|---|----------|------------------------|-----------------|
| D1 | Update existing User Pool in place (vs recreate) | Destroy + recreate User Pool with all-new IDs | Existing Flutter config and verification email config preserved; deprecated cruft is harmless. Trade-off: `walker` group and `custom:linked_devices` attribute hang around forever (Cognito can't delete them). |
| D2 | Existing App Client repurposed as Portal-Customer (ID preserved) | Create entirely new App Clients for both roles | Continuity for existing Flutter app and any external test setups using the client ID. New Internal client gets a new ID anyway. |
| D3 | Two App Clients (Customer + Internal) with distinct token lifetimes | Single App Client with same lifetime for everyone | Internal access is higher-risk; tighter expiry caps blast radius of stolen token. Echo of Phase 1.5 D9. |
| D4 | MFA enforcement via Pre-Token-Generation Lambda trigger (not pool-wide) | Pool-wide REQUIRED MFA; pool-wide OPTIONAL with no enforcement | Pool-wide REQUIRED forces MFA on patients/family (poor UX for elderly users without authenticator apps). Pool-wide OPTIONAL = no security. Lambda trigger lets us enforce per-group. Echo of Phase 1.5 D8. |
| D5 | TOTP MFA only — no SMS | TOTP + SMS fallback | SMS-MFA is weaker (SIM swap, interception) and adds Pinpoint cost. Target users have caregiver-grade smartphones. Reverse if onboarding data shows abandonment. |
| D6 | RoleAssignments table is keyed by `userId` only (one row per user) | Composite key (userId, scopeId) for multi-row scope assignments | Product owner confirmed: no staff-also-family case; one role per user is the operational reality. Single-row design is simpler to query and authz. |
| D7 | Family-viewer patient-link list (`linkedPatientIds`) lives in RoleAssignments **only**, not on JWT | Embed list as `custom:patients` claim on JWT | Cognito custom attribute capped at 2048 chars. Family viewer with many linked patients (extended families, multi-generational situations) could exceed it. Looking up at API request time is one DDB GetItem (~5ms); cacheable. |
| D8 | Internal users created via `admin-create-user` only (no self-signup) | Allow self-signup with email-domain restriction (e.g., @gosteady.co only) | Email domains can be spoofed during account-creation flows; admin-create-user is intentional. Aligns with audit posture (every internal account has a creator). |
| D9 | Custom claim `custom:role` is single-value enum (not array of roles) | Multi-role claim allowing union of authorities | Confirms one-role-per-user invariant in JWT shape. Simplifies authorizer logic. |
| D10 | `custom:facilities` and `custom:censuses` are comma-separated strings, not Cognito custom attribute arrays | List-type custom attributes | Cognito doesn't natively support list types in custom attributes; comma-separated strings serialize cleanly. 2048-char limit allows ~150 facility IDs. |
| D11 | Cognito Groups are **categorization only**, not authz source | Groups are the primary authz mechanism | Groups don't support metadata or scope. Authz lives in `custom:role` + `RoleAssignments` table. Groups exist for IAM federation in future and Pre-Token validation. |
| D12 | Federation enabled at pool level but no IdPs configured in this phase | Configure a sample SAML IdP for testing | Per-customer IdP config happens at customer-onboarding time. Bare federation hooks are sufficient for the platform; no value in dummy IdP. |
| D13 | Self-signup for `patient` and `household_owner` roles allowed; all other roles admin-create only | Disable all self-signup; admin-create everything | D2C model needs frictionless signup. Household-setup workflow (Phase 2A) provisions the synthetic client and `household_owner` RoleAssignment on first login; secondary family_viewers come in via invitation from the household_owner. |
| D18 | `household_owner` is a distinct role with softer MFA, not `client_admin` with context-dependent MFA | (a) Single `client_admin` role with MFA policy that varies by clientId pattern; (b) D2C household uses `client_admin` with MFA always required; (c) Combine `family_viewer` + a "can_invite" flag | (a) would couple authority to client-type and complicate Pre-Token logic; (b) would add friction to grandson-setting-up-for-grandma; (c) fragments role definition across role + flag. Distinct role keeps Pre-Token logic clean: MFA policy is a direct property of the role enum. |
| D19 | `household_owner` validated to be in a `dtc_*` client by Pre-Token Lambda | Accept any clientId for household_owner | Defensive: prevents a misassigned household_owner in an enterprise client from having softer MFA. Symmetrical to the internal_* clientId == `_internal` check. |
| D14 | Branded verification email retained from original 0A | Switch to SES custom template | No reason to break what works; SES custom template can come later when email volume grows. |
| D15 | No data migration of existing dev users; recreate post-deploy | Backfill custom attributes for existing test users | Dev only; no real users; recreation is faster than migration scripting. |
| D16 | Pre-Token Lambda uses Python 3.12 ARM64, stdlib + boto3 only | Other runtime; layer with extra deps | Matches Phase 1.5 G6/G7 standards; cold start is best-in-class for Python; no deps means trivial bundle. |
| D17 | Pre-Token Lambda denies with custom error names (`NO_ROLE_ASSIGNED`, `MFA_REQUIRED`, `TENANCY_VIOLATION`) | Generic deny + log | Custom errors propagate to client for actionable UX (client knows whether to prompt MFA enrollment vs contact support); server-side logs show exact reason for forensics. |

## Open Questions

- [ ] **Group membership vs RoleAssignment role**: belt-and-suspenders, both must agree. If they drift (admin updates one, not the other), Pre-Token Lambda denies. Should we make group assignment derived from RoleAssignment automatically (e.g., DDB Stream → group sync)? Or keep manual and rely on admin tooling discipline?
- [ ] **Internal user MFA enrollment workflow**: how does an internal user get their TOTP secret on first login? Email QR code? In-person enrollment? Defer until Phase 2A admin tool, but document the interim CLI process.
- [ ] **RoleAssignments record provisioning for D2C users**: D2C signup currently leaves the user in `patient` or `household_owner` group with no RoleAssignment. They can't access anything until household-setup workflow runs. Decide whether household setup is a forced first-login redirect or a manual step.
- [ ] **D2C provisioning flows** (detail in Phase 2A): three patterns identified — (1) co-located setup with caregiver invites sent after, (2) caregiver-initiated with walker-user invite, (3) walker-initiated with caregiver invites. All three converge on the same data-model state; UX sequencing decision belongs in Phase 2A. See Architecture §4 "Household provisioning flows."
- [ ] **household_owner signup path**: should signup form ask "are you signing up for yourself or for someone you care for?" to pre-classify `patient` vs `household_owner` at creation? Or always start as `household_owner` and let them optionally add themselves as a patient record?
- [ ] **Token refresh strategy for offline / spotty connectivity**: 15-min idle is tight if the user's phone briefly loses signal. Confirm Flutter auto-refresh handles graceful degradation.
- [ ] **Authentication telemetry**: Pre-Token Lambda has rich context for auth success/failure metrics. Should we emit CloudWatch metrics here (Phase 1.6 territory) or just log?
- [ ] **Cognito advanced security features** (compromised-credentials check, anomaly detection): adds ~$0.05 per MAU; valuable for healthcare but not free. Decide before going to prod.

## Changelog
| Date | Author | Change |
|------|--------|--------|
| 2026-04-16 | Jace + Claude | Initial revision spec |

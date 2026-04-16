# Phase 0A — Authentication & User Management

## Overview
- **Phase**: 0A
- **Status**: Verified
- **Branch**: feature/infra-scaffold
- **Date Started**: 2026-04-14
- **Date Completed**: 2026-04-14

Deploys Cognito User Pool with walker/caregiver role groups, a portal web client, and a DynamoDB relationships table for caregiver-to-walker linking. This is the auth foundation that all future API and portal work depends on.

## Locked-In Requirements

| # | Requirement | Decided In | Rationale |
|---|-------------|-----------|-----------|
| L1 | AWS Cognito for auth (not Auth0) | Phase 0A | Native IoT Core + Lambda integration, device + human auth on same platform. Auth0 can layer in later for enterprise SSO if needed. |
| L2 | Email + password sign-in (no social/SAML) | Phase 0A | Medical-adjacent product, simplest compliant flow for MVP |
| L3 | Two roles: `walker` and `caregiver` | Phase 0A | Core product model — walker uses the device, caregiver monitors remotely |
| L4 | Custom attribute `custom:role` on user pool | Phase 0A | Stored on the JWT token, readable by Lambdas without DB lookup |
| L5 | Custom attribute `custom:linked_devices` (JSON array of serials) | Phase 0A | Quick device lookup from token without relationships table query |
| L6 | AWS account 460223323193, region us-east-1 | Phase 0A | IoT Core and CloudFront certs require us-east-1 |
| L7 | CDK TypeScript for all infrastructure | Phase 0A | Type safety, mature L2 constructs, good IoT Core support |

## Assumptions

| # | Assumption | Risk if Wrong | Validation Plan |
|---|-----------|---------------|-----------------|
| A1 | Email verification is sufficient (no phone/MFA) | Regulatory push-back if product enters clinical settings | Revisit when compliance requirements solidify |
| A2 | One user = one role (not both walker AND caregiver) | UI/permissions model breaks if someone is both | Can be extended with multi-group membership later |
| A3 | Cognito free tier (50k MAU) sufficient for development | Cost surprise | Monitor via AWS Cost Explorer |
| A4 | Relationship table accessed infrequently (caregiver dashboard load) | Hot partition if queried on every API call | GSI on walkerId covers reverse lookup; cache in API layer if needed |

## Scope

### In Scope
- Cognito User Pool with email sign-in and auto-verify
- Custom attributes: `role`, `linked_devices`
- Cognito Groups: `walker` (precedence 2), `caregiver` (precedence 1)
- Portal web client with USER_PASSWORD_AUTH and USER_SRP_AUTH flows
- OAuth2 authorization code grant with OIDC/email/profile scopes
- Callback URLs for localhost:8080 (dev) and portal.gosteady.co (prod)
- Token validity: 1h access/id, 30d refresh
- Branded verification email ("GoSteady — Verify your email")
- DynamoDB relationships table (PK: caregiverId, SK: walkerId)
- GSI `walker-caregivers` for reverse lookup
- Flutter login/signup/verify screen (on feature/auth-flow branch)

### Out of Scope (Deferred)
- MFA (Phase 3+ if needed for compliance)
- Social sign-in / SAML federation (Phase 4+ enterprise)
- Admin user management console (Phase 3)
- Password reset flow in Flutter UI (Phase 2)
- Device activation linking serial to user (Phase 1B)

## Architecture

### Infrastructure Changes
- **New stack**: `GoSteady-Dev-Auth`
  - `AWS::Cognito::UserPool` — `gosteady-dev-users`
  - `AWS::Cognito::UserPoolClient` — `gosteady-dev-portal`
  - `AWS::Cognito::UserPoolGroup` x2 — `walker`, `caregiver`
  - `AWS::DynamoDB::Table` — `gosteady-dev-relationships` + GSI `walker-caregivers`

### Data Flow
```
User (Flutter) → Cognito UserPool → JWT (id + access + refresh)
                                   ↓
                            custom:role in token
                                   ↓
                    Future: API Gateway JWT Authorizer
```

### Interfaces
- **Cognito User Pool ID**: `us-east-1_ZHbhl19tQ`
- **Portal Client ID**: `1q9l9ujtsomf3ugq2tnqvdg6d7`
- **DynamoDB**: `gosteady-dev-relationships` (caregiverId/walkerId composite key)

## Implementation

### Files Changed / Created
| File | Change Type | Description |
|------|------------|-------------|
| `infra/lib/stacks/auth-stack.ts` | New | Full auth stack: Cognito + relationships table |
| `infra/lib/config.ts` | New | Environment config (account, region, billing mode) |
| `infra/bin/gosteady.ts` | New | CDK app entry point wiring all stacks |
| `lib/config/cognito_config.dart` | New | Cognito IDs for Flutter (feature/auth-flow) |
| `lib/models/user.dart` | New | GoSteadyUser model + UserRole enum |
| `lib/services/auth_service.dart` | New | Cognito auth service (sign in/up/out, session persistence) |
| `lib/screens/login_screen.dart` | New | Login/signup/verify screen with GoSteady branding |
| `lib/main.dart` | Modified | AuthGate widget wrapping app |
| `lib/screens/dashboard_screen.dart` | Modified | User name pill + role icon + sign-out button |

### Dependencies
- `aws-cdk-lib` ^2.248.0
- `constructs` ^10.5.0
- `amazon_cognito_identity_dart_2` (Flutter, on auth-flow branch)
- `shared_preferences` (Flutter, session persistence)

### Configuration
- CDK context: `--context env=dev`
- AWS CLI profile: `jace-admin` (IAM user with AdministratorAccess)

## Testing

### Test Scenarios
| # | Scenario | Method | Expected Result | Status |
|---|----------|--------|-----------------|--------|
| T1 | Sign up new walker user | Flutter login screen | Verification email sent, account created | Pass |
| T2 | Verify email with code | Flutter verify screen | User confirmed, redirected to dashboard | Pass |
| T3 | Sign in with verified user | Flutter login screen | JWT returned, dashboard loads with user name | Pass |
| T4 | Verification email is branded | Email inbox | Subject: "GoSteady — Verify your email", body mentions GoSteady | Pass |
| T5 | Sign out | Dashboard sign-out button | Session cleared, returned to login | Pass |
| T6 | Cognito User Pool exists in console | AWS Console | Pool visible with correct settings | Pass |
| T7 | Relationships table exists | AWS Console | Table with GSI visible in DynamoDB | Pass |

### Verification Commands
```bash
# Check Cognito User Pool
aws cognito-idp describe-user-pool --user-pool-id us-east-1_ZHbhl19tQ --region us-east-1 --query "UserPool.Name"

# List Cognito groups
aws cognito-idp list-groups --user-pool-id us-east-1_ZHbhl19tQ --region us-east-1 --query "Groups[].GroupName"

# Check relationships table
aws dynamodb describe-table --table-name gosteady-dev-relationships --region us-east-1 --query "Table.TableStatus"

# List stack outputs
aws cloudformation describe-stacks --stack-name GoSteady-Dev-Auth --region us-east-1 --query "Stacks[0].Outputs"
```

## Deployment

### Deploy Commands
```bash
cd infra
npm run build
npx cdk deploy GoSteady-Dev-Auth --context env=dev --require-approval never
```

### Rollback Plan
```bash
npx cdk destroy GoSteady-Dev-Auth --context env=dev
# Note: RemovalPolicy.DESTROY on dev — all resources deleted
# Cognito users will be lost on destroy
```

## Decisions Log

| # | Decision | Alternatives Considered | Why This Choice |
|---|----------|------------------------|-----------------|
| D1 | Cognito over Auth0 | Auth0, Firebase Auth, Supabase | Native AWS integration for IoT + API Gateway; Auth0 can layer in later for enterprise SSO |
| D2 | Relationships in DynamoDB (not Cognito groups) | Cognito group membership, RDS | Groups are flat (no metadata). DynamoDB allows status, timestamps, relationship type on each link |
| D3 | `linked_devices` as custom attribute (JSON array) | Separate table lookup | Fast path: device list on JWT without DB call. Table for complex queries |
| D4 | Email-only sign-in | Username, phone | Medical-adjacent: email is the universal identifier, avoids phone number collection |
| D5 | Branded verification email in CDK | SES custom template | Simpler for MVP. SES templates for richer HTML later |

## Open Questions
- [ ] Should we enforce email domain restrictions? (e.g., only allow @hospital.org for caregivers)
- [ ] Do we need admin-created accounts (no self-signup for walkers who may not have email)?
- [ ] Token validity: 1h access token may be too short for elderly users with slow sessions

## Changelog
| Date | Author | Change |
|------|--------|--------|
| 2026-04-14 | Jace + Claude | Initial implementation and deployment |
| 2026-04-14 | Jace + Claude | Added branded verification email |
| 2026-04-15 | Jace + Claude | Backfilled spec from deployment |

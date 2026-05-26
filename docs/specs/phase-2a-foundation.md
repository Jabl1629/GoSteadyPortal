# Phase 2A-0 — Portal API Foundation

## Overview
- **Phase**: 2A-0 (foundation subset of Phase 2A)
- **Status**: ✅ Deployed (dev) 2026-05-17
- **Branch**: feature/infra-scaffold (matched existing project pattern; spec field aspirational)
- **Date Started**: 2026-05-17
- **Date Completed**: 2026-05-17 (dev; WAF deferred to Phase 3A — see Open Questions Q7 below)

Stands up the shared infrastructure that every Phase 2A subset (device-lifecycle, patient reads, alert actions, user management, internal tools) builds on: API Gateway HTTP API, WAF web ACL, Cognito JWT authorizer, custom-claim extraction conventions, shared error envelope, audit middleware that wraps Phase 1.7's `emit_audit()` helper, tenant-enforcement helper, request validation, CORS, CloudWatch access logs, X-Ray tracing, and an alarm catalog covering 4xx/5xx rates and latency p99.

Ships **one stub endpoint** (`GET /api/v1/me`) so the whole pipeline is end-to-end testable before any business endpoints exist: API Gateway routes correctly → JWT authorizer fires → custom claims are accessible in the handler → audit middleware emits → error envelope works on the 401/403 paths → access logs land in CloudWatch. Once 2A-0 is deployed and the smoke endpoint passes, the four downstream 2A subsets become 2-day sprints instead of week-long rebuilds-from-scratch.

This is **pure plumbing — no business endpoints**. The single stub endpoint exists only to validate the plumbing.

## Locked-In Requirements

| # | Requirement | Decided In | Rationale |
|---|-------------|-----------|-----------|
| L1 | Stack name: existing `GoSteady-{Env}-Api` (stub populated, not new stack) | ARCHITECTURE.md §5 CDK Stack Map | Stub already exists; this phase fills it in |
| L2 | Path prefix `/api/v1/*` for all portal routes; reserved `/admin/*` for internal-admin routes (Phase 2A-INT) | Architecture §12 Phase 2A bullets | Versioning from day one means breaking changes don't paint us into a corner |
| L3 | Cognito User Pool JWT authorizer at API Gateway level (not Lambda authorizer) | Phase 0A revision (User Pool live at `us-east-1_ZHbhl19tQ`) | API Gateway HTTP API supports JWT natively; Lambda authorizer would add cold-start and double-billing for the same verification logic |
| L4 | JWT custom claims accessible to handlers via API Gateway request context: `clientId`, `role`, `facilities`, `censuses` | Phase 0A revision Pre-Token Generation Lambda V2 (deployed 2026-04-26) | Pre-Token Lambda already injects these claims into both ID and Access tokens; handler reads them from `event.requestContext.authorizer.jwt.claims`. **Amended 2026-05-23 (Q8):** the JWT authorizer's audience list narrowed from 2 → 1 (Portal-Customer only) under the unified-portal decision in [phase-2b-portal-integration.md](phase-2b-portal-integration.md) L1. Per-route role differentiation (via `custom:role` claim) is unchanged |
| L5 | Tenant enforcement at handler level: every handler validates path/body `clientId` (where present) matches token's `custom:clientId`; reject 403 `TENANCY_VIOLATION` on mismatch. Internal roles (`internal_*`) bypass this check | ARCHITECTURE.md T2 + §4 Internal Access | The hard security boundary. Cannot live only at API Gateway — paths don't always carry `clientId`, but handlers know which DDB partition they're querying |
| L6 | Audit emission via Powertools middleware decorator wrapping every handler; uses `_shared/observability.py:emit_audit` | Phase 1.7 (deployed 2026-05-17) | Single emission path. Middleware automatically derives `actor` from JWT claims, `request_id` from API Gateway context, and stamps `internal_access` for internal roles before calling the helper (which forwards to audit-forwarder Lambda → audit log group → S3) |
| L7 | Shared error envelope shape (per phase-2a-device-lifecycle.md) — `{error: {code, message, details}}` with documented codes catalog | Phase 2A-DL spec §Interfaces | Flutter UI needs structured codes to render specific messages; codes also flow into audit logs for forensics |
| L8 | WAF with AWS Managed Rules — `AWSManagedRulesCommonRuleSet`, `AWSManagedRulesAmazonIpReputationList`, and rate-limit rule | ARCHITECTURE.md §12 Phase 2A | Baseline WAF protection without paying for managed bot-control yet (bot-control adds ~$10/mo per Web ACL — overkill at MVP) |
| L9 | CORS allowed origins from CDK config — dev: `localhost:8080` + portal preview URL; prod: `portal.gosteady.co` only | Standard | Portal-Customer Cognito App Client redirect URLs match these origins |
| L10 | CloudWatch access logs in structured JSON to a dedicated log group `/aws/apigateway/gosteady-{env}-api`, 30d dev / 90d prod retention | ARCHITECTURE.md L3 (Data Lifecycle) | Operational visibility into request rates, latency, response codes by route. Separate from handler Lambda logs |
| L11 | X-Ray Active Tracing on API Gateway + propagated to handler Lambdas | Phase 1.6 (deployed 2026-04-30) | Single Service Map for the full request path; matches the X-Ray posture already enabled on the 6 Phase 1B/1A/0A handlers |
| L12 | Alarms route to existing ops SNS topic (`gosteady-{env}-cost-alarms`, repurposed in Phase 1.6) | Phase 1.5 + 1.6 precedent | One ops destination for all platform-health signals |

## Assumptions

| # | Assumption | Risk if Wrong | Validation Plan |
|---|-----------|---------------|-----------------|
| A1 | API Gateway HTTP API JWT authorizer validates signature, issuer, audience, and expiration against the Cognito User Pool's JWKS automatically; no Lambda needed for verification | If the built-in authorizer is missing a check we need, falls back to Lambda authorizer (~+20ms cold + per-invocation cost) | AWS docs confirm: JWT authorizer on HTTP API supports `issuer` + `audience` matching + signature verification natively. Verify smoke test: an expired token returns 401 |
| A2 | Pre-Token Lambda V2's custom claims (deployed 2026-04-26 per Phase 0A revision) appear in `event.requestContext.authorizer.jwt.claims` accessible from the handler | If the claims aren't there, handlers can't enforce tenancy or pick the right scope | Verify with the stub `GET /api/v1/me` endpoint — it returns the full claim set; tested in T3 |
| A3 | WAF Managed Rules don't false-positive-block legitimate portal traffic at MVP scale | Real users get 403s and complain | AWS Managed Rules baseline rarely false-positives on JSON API traffic; the only common issue is the `SizeRestrictions_BODY` rule rejecting >8KB bodies, which our `POST /devices/{serial}/provision` payload is well under. Document the override pattern if it ever comes up |
| A4 | API Gateway HTTP API request validation via JSON Schema models is sufficient for body/query/path validation; no per-handler validation library needed | Validation gaps allow malformed input to reach handlers | API Gateway HTTP API request validation handles `required`, `type`, `enum`, `pattern`. Handlers still validate semantic constraints (e.g., "patient belongs to this client") — that's not a request-validation job |
| A5 | **Amended 2026-05-23 (Q8 / unified portal):** The Portal-Customer App Client (`1q9l9ujtsomf3ugq2tnqvdg6d7`) is the single audience for the JWT authorizer. All web users — including internal staff — sign in via this client. Per-route role differentiation happens in handler code via `custom:role`. Portal-Internal (`gvc7n839vj4ppgioamknlk21c`) is reserved for non-browser tools (CLI / server-side); it's not in the authorizer's audience list | (Original A5: both clients accepted, internal-vs-customer differentiated by role at handler level) | Per [phase-2b-portal-integration.md](phase-2b-portal-integration.md) L1, unified portal at one URL means one Cognito client at the JWT authorizer. Security boundary stays JWT-claim-based via `custom:role` |
| A6 | A single Lambda function (`gosteady-{env}-api-stub`) is enough for the foundation phase's stub endpoint; subsequent subsets add their own Lambdas | If the stub is too thin, smoke-testing the foundation is unclear | The stub returns 200 with the JWT claims it received. ~30 lines of code. Sufficient |
| A7 | Existing `GoSteady-{Env}-Api` stub stack can be populated in-place (CFN UPDATE, not destroy+recreate) | Stack-replacement loses any state | Stub only has one CfnOutput (`Status: SCAFFOLD`); no resources to preserve. Trivial UPDATE |

## Scope

### In Scope

**`GoSteady-{Env}-Api` stack** (populated, was stub):

- **API Gateway HTTP API** (`gosteady-{env}-api`):
  - Default endpoint disabled; custom domain deferred to Phase 3A (use the API Gateway-issued URL for dev)
  - CORS preflight handling via CDK `corsPreflight` config
  - Throttling: dev 25 RPS sustained / 50 burst; prod 100 / 200 (per Phase 2A-DL spec D9 config)
  - X-Ray Active Tracing enabled at the API level

- **Cognito JWT authorizer** (`PortalAuthorizer`):
  - Issuer: `https://cognito-idp.us-east-1.amazonaws.com/us-east-1_ZHbhl19tQ`
  - Audience: `1q9l9ujtsomf3ugq2tnqvdg6d7` (Portal-Customer) — **amended 2026-05-23 (Q8), narrowed from 2 → 1.** Portal-Internal client no longer in the audience list; it's reserved for non-browser tools
  - Identity source: `$request.header.Authorization` (Bearer token)
  - Attached to all routes via default authorizer (override per-route if a public path appears — none in v1)

- **WAF v2 web ACL** (`gosteady-{env}-portal-waf`):
  - AWS Managed Rules: `AWSManagedRulesCommonRuleSet`, `AWSManagedRulesAmazonIpReputationList`
  - Rate-limit rule: 2000 requests / 5 min / source IP (configurable per env)
  - Associated to the API Gateway HTTP API
  - CloudWatch metrics enabled for each rule (visibility into rule hits)

- **Stub endpoint** `GET /api/v1/me`:
  - Returns: `{ userId, clientId, role, facilities, censuses, internalAccess }` — read from JWT claims, mirrored back
  - Purpose: end-to-end pipeline smoke (route → authorizer → handler → audit → access log)
  - Audit emission: `auth.session.read` event with `actor = self`, `subject = self` (a user reading their own session info)
  - Returns 401 if no Authorization header; 401 if token invalid; 403 if claims missing required fields (catches Pre-Token Lambda bugs)

- **Stub Lambda** `gosteady-{env}-api-stub`:
  - Python 3.12 ARM64
  - Bundles `_shared/` (uses `emit_audit`, shared error envelope, JWT helpers, tenant enforcement helper)
  - Powertools layer (Phase 1.6 ARN)
  - Memory 128 MB, timeout 10 s
  - Logging: structured JSON via Powertools (matches Phase 1B-rev handlers)
  - X-Ray Active Tracing enabled

- **Shared API code modules** in `infra/lambda/_shared/` (additions to existing):
  - `api_error.py` — `ApiError` exception class + `error_response(code, message, status, details=None)` helper that produces the spec error envelope
  - `api_authz.py` — `extract_claims(event)` helper + `enforce_tenancy(claims, target_client_id)` + `is_internal(claims)` + `require_role(claims, *allowed_roles)`
  - `api_audit.py` — `audit_middleware()` Powertools-style decorator that auto-derives `actor` from JWT claims, `request_id` from API Gateway context, stamps `internal_access` for internal roles, calls `emit_audit()` from `observability.py`. Wraps every handler. On uncaught exception, emits `audit.handler.error` event before re-raising

- **Error code catalog** (initial — extended by each subset):
  - `INVALID_REQUEST` (400) — body/query/path validation failure
  - `UNAUTHENTICATED` (401) — missing/invalid token
  - `INTERNAL_SESSION_EXPIRED` (401) — internal_* role's session exceeded 4-hr absolute cap (added 2026-05-23 with Q8 amendment; app-layer enforcement via `enforce_internal_session_age` in `_shared/api_authz.py`)
  - `MFA_REQUIRED` (403) — role requires MFA per Phase 0A revision but token lacks `custom:mfa_enrolled=true`
  - `INSUFFICIENT_PERMISSIONS` (403) — role not in allowed-list for this route
  - `TENANCY_VIOLATION` (403) — `custom:clientId` doesn't match target resource's `clientId` (and not internal_*)
  - `OUT_OF_SCOPE` (403) — caregiver/facility_admin's facility/census claims don't cover the target resource
  - `NOT_FOUND` (404) — resource doesn't exist
  - `RATE_LIMITED` (429) — WAF rate-limit triggered (returned by API Gateway, surfaced through our envelope when possible)
  - `INTERNAL_ERROR` (500) — uncaught handler exception; details include `requestId` for support lookup

- **CloudWatch access logs**:
  - Log group `/aws/apigateway/gosteady-{env}-api` (CMK-encrypted not necessary — no PII in access logs by design)
  - Retention: 30d dev / 90d prod (matches L3)
  - Structured JSON format: `{requestId, requestTime, httpMethod, routeKey, status, ip, userAgent, latency, integrationLatency, error}` — no body, no headers (avoid PII leakage)

- **CloudWatch alarms** routed to ops SNS topic:
  - `gosteady-{env}-api-5xx-rate` — 5xx > 1% of requests in 5 min
  - `gosteady-{env}-api-4xx-burst` — 4xx > 50 in 5 min (catches credential-stuffing, broken UI deployments)
  - `gosteady-{env}-api-latency-p99` — p99 latency > 2000 ms in 5 min
  - `gosteady-{env}-api-stub-errors` — Stub Lambda Errors > 0 in 5 min (per-handler alarm pattern from 1.6)
  - `gosteady-{env}-api-waf-blocks` — `BlockedRequests` > 100 in 5 min (catches misconfigured rules or real attack traffic)

- **Audit event additions** (catalog grows):
  - `auth.session.read` — emitted on `GET /api/v1/me` (the stub endpoint)
  - `audit.handler.error` — emitted by middleware on uncaught exception, includes `error.type` and `error.message_redacted` (stack trace logged separately to handler log group, not audit)

### Out of Scope (Deferred)

- **Custom domain** (`api.gosteady.co` or `portal.gosteady.co/api`) — Phase 3A bundles all custom domains (CloudFront + API + portal hosting). For 2A development, the API Gateway-issued URL is fine.
- **API Gateway usage plans + API keys** — not needed at MVP since auth is JWT-only; would matter for B2B partner API access (Phase 4+ if reopened).
- **Per-route Lambda authorizers** — JWT authorizer at the API level is sufficient; per-route authz lives in handler code (per L5/Q6 of device-lifecycle spec).
- **OpenAPI spec generation / API documentation site** — useful eventually, defer until 3+ subsets are live and the API surface is meaningful.
- **Request body size limit overrides** — default 10 MB per API Gateway is fine for everything we ship in v1 (largest body is the bulk device CSV upload in 2A-INT, and even that is <100 KB).
- **Per-IP origin allowlisting** — WAF handles abusive traffic; geo-blocking is overkill for US-focused MVP.
- **API Gateway response caching** — premature optimization; revisit if a specific high-traffic read becomes hot.
- **GraphQL or any other API style** — REST is the right choice for the MVP API surface.
- **Webhooks / outbound HTTP from API endpoints** — out of scope for 2A entirely (any outbound integrations are EventBridge → SNS/SES in Phase 2C).
- **Anything customer-business — read/write endpoints for patients, devices, alerts, etc.** — those are 2A-DL, 2A-RD, 2A-AA. This subset only ships infrastructure + one stub.

## Architecture

### Infrastructure Changes

**Existing stack populated:** `GoSteady-{Env}-Api` (was: 1 CfnOutput stub; becomes: ~25 resources):

- 1 × `AWS::ApiGatewayV2::Api` (HTTP API)
- 1 × `AWS::ApiGatewayV2::Authorizer` (Cognito JWT)
- 1 × `AWS::ApiGatewayV2::Route` (`GET /api/v1/me`)
- 1 × `AWS::ApiGatewayV2::Integration` (stub Lambda integration)
- 1 × `AWS::ApiGatewayV2::Stage` (`$default` with access logging)
- 1 × `AWS::WAFv2::WebACL`
- 1 × `AWS::WAFv2::WebACLAssociation` (binds WebACL to API)
- 1 × `AWS::Logs::LogGroup` (`/aws/apigateway/gosteady-{env}-api`)
- 1 × `AWS::Lambda::Function` (`gosteady-{env}-api-stub`)
- 1 × `AWS::IAM::Role` + 1 × `AWS::IAM::Policy` (stub execution role)
- 1 × `AWS::Lambda::Permission` (API Gateway → stub Lambda)
- 5 × `AWS::CloudWatch::Alarm` (5xx, 4xx, p99, stub Errors, WAF blocks)

**Modified stacks:** none directly. Phase 1.7's audit pipeline picks up new audit events from the stub Lambda automatically via the existing subscription filter on `/aws/lambda/gosteady-{env}-api-stub` (after Audit stack's filter is updated to include it — see Subsection note below).

> **One follow-up to the Audit stack:** The Phase 1.7 deploy attached subscription filters to 6 source handler log groups. The new `api-stub` log group needs to be added. This is a 2-line CDK change in `audit-stack.ts` — either bundle into 2A-0 deploy or follow up immediately after. Lean: bundle (avoids a "between-revisions gap" per the Migration Pattern 18.8 silent-swallow risk).

### Data Flow

```
Client (Flutter / curl)
    │
    │ Authorization: Bearer <Cognito JWT>
    ▼
┌──────────────────────────────────────────┐
│ WAF web ACL                              │
│  - Common Rule Set, IP Reputation        │
│  - Rate limit (2000 / 5min / IP)         │
└──────────────┬───────────────────────────┘
               │ pass
               ▼
┌──────────────────────────────────────────┐
│ API Gateway HTTP API                     │
│  - Route: GET /api/v1/me                 │
│  - JWT Authorizer (Cognito User Pool)    │
│    - validates signature + audience      │
│    - rejects expired tokens (401)        │
│  - X-Ray Active Tracing                  │
│  - Access logs → CloudWatch              │
└──────────────┬───────────────────────────┘
               │ event.requestContext.authorizer.jwt.claims
               │   = { sub, custom:clientId, custom:role, ... }
               ▼
┌──────────────────────────────────────────┐
│ gosteady-{env}-api-stub Lambda           │
│  - Powertools Logger + Tracer + Metrics  │
│  - audit_middleware() decorator wraps    │
│    handler: derives actor from claims,   │
│    emits audit event before/after        │
│  - Handler reads claims, returns mirror  │
│  - error_response() on any ApiError      │
└──────────────┬───────────────────────────┘
               │ JSON response (or error envelope)
               ▼
            Client

[Side-channel: audit emission]
api-stub Lambda's audit-shape log line
    │
    ▼ (existing 1.7 pipeline)
Subscription filter (after audit-stack.ts edit)
    │
    ▼
audit-forwarder Lambda
    │
    ▼
gosteady-{env}-audit log group
    │
    ▼ (Firehose)
S3 audit bucket
```

### Interfaces

**Stub endpoint:**

`GET /api/v1/me`

Request: no body, `Authorization: Bearer <token>` header required

Response 200:
```json
{
  "userId": "abc-123",
  "clientId": "client_005",
  "role": "caregiver",
  "facilities": ["fac_012", "fac_018"],
  "censuses": ["cen_044", "cen_045"],
  "internalAccess": false
}
```

For internal users (`role` starts with `internal_`): `facilities` and `censuses` are empty arrays, `internalAccess: true`.

Response 401 (missing/invalid token):
```json
{
  "error": {
    "code": "UNAUTHENTICATED",
    "message": "Authorization required",
    "details": null
  }
}
```

Response 403 (claims missing — Pre-Token Lambda bug):
```json
{
  "error": {
    "code": "MFA_REQUIRED" | "TENANCY_VIOLATION",
    "message": "...",
    "details": { "missingClaim": "custom:clientId" }
  }
}
```

**`emit_audit` middleware contract:**

Wraps every handler. Behavior:
- Before handler: extracts claims from event, stamps `actor = {userId, role, clientId}` (or `actor = {system: "unauthenticated"}` if 401)
- After successful handler return: emits the configured `event` name from the route's metadata (passed to decorator) with `action` derived (`read` for GET, `create` for POST, `update` for PATCH/PUT, `delete` for DELETE)
- On `ApiError`: emits with the error's `code` in `extra.error_code`; does NOT emit a separate audit error event for 4xx (those are caller behavior, not system errors)
- On uncaught exception: emits `audit.handler.error` with redacted error type, re-raises to bubble to API Gateway as 500

## Implementation

### Files Changed / Created

| File | Change Type | Description |
|------|------------|-------------|
| `infra/lib/stacks/api-stack.ts` | Modified | Populates the existing stub: HTTP API, JWT authorizer, WAF, access logs, stub Lambda, alarms |
| `infra/lib/constructs/api-stub-lambda.ts` | New | Lambda construct for `api-stub` — reuses ProcessingLambda pattern but with API-handler env vars |
| `infra/lib/constructs/portal-waf.ts` | New | WAFv2 web ACL with managed rules + rate limit + association |
| `infra/lib/stacks/audit-stack.ts` | Modified | Add `gosteady-{env}-api-stub` to the source handler log groups list for subscription filter (per Subsection note above) |
| `infra/lambda/api-stub/handler.py` | New | Stub handler: `GET /api/v1/me` — reads JWT claims, returns mirror |
| `infra/lambda/api-stub/requirements.txt` | New | Empty (Powertools from layer; boto3 from runtime) |
| `infra/lambda/_shared/api_error.py` | New | `ApiError` exception + `error_response()` helper |
| `infra/lambda/_shared/api_authz.py` | New | `extract_claims()`, `enforce_tenancy()`, `is_internal()`, `require_role()` |
| `infra/lambda/_shared/api_audit.py` | New | `audit_middleware()` Powertools decorator wrapping `emit_audit()` |
| `infra/lambda/_shared/audit_catalog.py` | Modified | Add `auth.session.read` + `audit.handler.error` constants |
| `infra/bin/gosteady.ts` | (verify only) | Existing wire-up already has `ApiStack`; just confirm deploy order Auth → Data → Api is intact |
| `docs/specs/ARCHITECTURE.md` | Modified | Update §5 stack map row 9 (Api); update §15 Lambda Inventory with `api-stub`; flip §12 Phase 2A status to "🟡 2A-0 deployed; subsets in progress" |
| `docs/firmware-coordination/2026-04-17-cloud-contracts.md` | Modified | §C16: 2A-0 deploy outcome (cloud-only, no firmware action) |

### Dependencies

- Phase 0A revision (User Pool, App Clients, Pre-Token Lambda — all deployed 2026-04-26)
- Phase 1.5 Security (no direct dep — API access logs use AWS-managed encryption)
- Phase 1.6 Observability (Powertools layer ARN; ops SNS topic for alarms; X-Ray tracing)
- Phase 1.7 Audit Logging (audit pipeline destination for emitted events — deployed 2026-05-17)

### Configuration

| CDK Context Key | Dev | Prod | Notes |
|---|---|---|---|
| `apiThrottleBurst` | 50 | 200 | API Gateway burst RPS |
| `apiThrottleRate` | 25 | 100 | Sustained RPS |
| `apiWafRateLimitPerIp` | 2000 | 2000 | WAF rate-limit rule per 5 min / source IP (tune later) |
| `apiCorsAllowedOrigins` | `["http://localhost:8080", "http://localhost:8090"]` | `["https://portal.gosteady.co"]` | CORS allowed origins; dev includes the internal-admin tool localhost |
| `apiAccessLogRetentionDays` | 30 | 90 | Matches L3 |
| `apiLatencyP99AlarmMs` | 2000 | 1000 | Prod tighter |

## Testing

### Test Scenarios

| # | Scenario | Method | Expected Result | Status |
|---|----------|--------|-----------------|--------|
| T1 | API Gateway HTTP API exists with correct stage and authorizer | `aws apigatewayv2 get-apis` + `get-authorizers` | API listed, JWT authorizer with correct issuer + 2 audiences | Pending |
| T2 | WAF associated to the API; managed rule groups attached | `aws wafv2 list-resources-for-web-acl` + `get-web-acl` | API ARN in resources; Common + IP Reputation rule groups + rate-limit rule present | Pending |
| T3 | `GET /api/v1/me` with valid Portal-Customer token returns mirror of claims | `curl -H "Authorization: Bearer <token>" <api-url>/api/v1/me` | 200 with `{userId, clientId, role, facilities, censuses, internalAccess}` matching the token's claims | Pending |
| T4 | `GET /api/v1/me` with no Authorization header returns 401 envelope | `curl <api-url>/api/v1/me` | 401 `{"error": {"code": "UNAUTHENTICATED", ...}}` | Pending |
| T5 | `GET /api/v1/me` with expired token returns 401 | Forge or wait for an expired token | 401 with appropriate message | Pending |
| T6 | `GET /api/v1/me` with token missing `custom:clientId` returns 403 | Manually create a test user without role assignment; sign in | 403 `{"error": {"code": "TENANCY_VIOLATION", "details": {"missingClaim": "custom:clientId"}}}` | Pending |
| T7 | `GET /api/v1/me` with Portal-Internal token returns `internalAccess: true` and empty facilities/censuses | Sign in to internal App Client | 200 with internal indicators correct | Pending |
| T8 | Audit event lands in audit log group for a successful `/me` call | Run T3; query `gosteady-{env}-audit` log group | `auth.session.read` event present with `actor.userId` matching token, no PII leakage | Pending |
| T9 | CloudWatch access log entry created per request | Run T3; check `/aws/apigateway/gosteady-{env}-api` log group | JSON line with `routeKey: "GET /api/v1/me"`, `status: 200`, `requestId`, `latency` | Pending |
| T10 | X-Ray trace shows API Gateway → Lambda path | Run T3; wait 60s; open X-Ray service map | Trace visible: API Gateway → api-stub Lambda; latency breakdown | Pending |
| T11 | WAF rate-limit triggers on 2001 requests in 5 min from one IP | Burst-test (carefully — could trigger alarm noise) | After threshold, requests return 403; `waf-blocks` alarm fires | Optional / careful |
| T12 | `api-stub-errors` alarm fires on a synthetic 500 | Force the stub Lambda to raise an uncaught exception (temporary env var to crash on demand) | Alarm transitions to ALARM; SNS message lands at ops topic | Pending |
| T13 | CORS preflight OPTIONS request from allowed origin succeeds | `curl -X OPTIONS -H "Origin: http://localhost:8080" -H "Access-Control-Request-Method: GET" <api-url>/api/v1/me` | 204 with `Access-Control-Allow-Origin: http://localhost:8080`, allowed methods include `GET` | Pending |
| T14 | CORS preflight from non-allowed origin is rejected | Same as T13 but `Origin: http://evil.com` | 403 or missing CORS headers (browser blocks) | Pending |
| T15 | Audit-stack subscription filter includes the new `api-stub` log group | `aws logs describe-subscription-filters --log-group-name /aws/lambda/gosteady-{env}-api-stub` | Filter present targeting audit-forwarder; pattern `{ $.audit IS TRUE }` | Pending |
| T16 | End-to-end audit visibility — `/me` call → S3 within ~70 s | Run T3, wait ~70s, list S3 audit prefix for today | `.gz` object with the audit event inside | Pending |

### Verification Commands

```bash
# Tier 1 — API discovery
aws apigatewayv2 get-apis --region us-east-1 --query 'Items[?Name==`gosteady-dev-api`]'
API_ID=$(aws apigatewayv2 get-apis --region us-east-1 --query 'Items[?Name==`gosteady-dev-api`].ApiId' --output text)
API_URL=$(aws apigatewayv2 get-apis --region us-east-1 --query "Items[?ApiId==\`$API_ID\`].ApiEndpoint" --output text)
echo "API URL: $API_URL"

# Tier 2 — Stub endpoint (needs a real Cognito token; obtain via test user sign-in)
TOKEN="<paste-id-token>"
curl -s -H "Authorization: Bearer $TOKEN" "$API_URL/api/v1/me" | jq .

# Tier 3 — Audit event lookup
aws logs filter-log-events --region us-east-1 \
  --log-group-name gosteady-dev-audit \
  --filter-pattern '{ $.event = "auth.session.read" }' \
  --start-time $(($(date +%s) - 300))000 --max-items 3

# Tier 4 — Access log lookup
aws logs filter-log-events --region us-east-1 \
  --log-group-name /aws/apigateway/gosteady-dev-api \
  --start-time $(($(date +%s) - 300))000 --max-items 5

# Tier 5 — WAF visibility
WAF_ARN=$(aws wafv2 list-web-acls --scope REGIONAL --region us-east-1 \
  --query 'WebACLs[?Name==`gosteady-dev-portal-waf`].ARN' --output text)
aws wafv2 get-web-acl --scope REGIONAL --region us-east-1 \
  --id $(echo $WAF_ARN | cut -d/ -f4) --name gosteady-dev-portal-waf
```

## Deployment

### Deploy Commands

```bash
cd infra
npm run build

# Deploy in this order:
# 1. Audit stack (adds api-stub log group to subscription filter list)
npx cdk deploy GoSteady-Dev-Audit --context env=dev --require-approval never

# 2. API stack (populates the stub)
npx cdk deploy GoSteady-Dev-Api --context env=dev --require-approval never
```

Estimated deploy time: Audit ~30 s (one subscription filter add), API ~3-4 min (API Gateway + WAF + Lambda + alarms).

### Rollback Plan

API stack rollback is clean — no data plane, no IoT integration. `cdk destroy GoSteady-Dev-Api --context env=dev` removes the API Gateway + WAF + stub Lambda + alarms cleanly. The audit-stack edit is a single subscription filter that can be removed via diff-and-redeploy.

If WAF false-positives block legitimate traffic during 2A-DL development, the easiest mitigation is to temporarily set the WAF rule actions to `count` instead of `block` via console, then tune rule overrides in CDK before the next deploy.

## Decisions Log

| # | Decision | Alternatives Considered | Why This Choice |
|---|----------|------------------------|-----------------|
| D1 | API Gateway HTTP API (v2), not REST API (v1) | REST API has more features (request validation models, gateway responses) | HTTP API has built-in JWT authorizer, lower cost (~70% cheaper), lower latency. REST API features we'd want (request validation) exist in HTTP API too as of 2022 |
| D2 | **Amended 2026-05-23 (Q8):** Single JWT authorizer with **one** audience (Portal-Customer only). All web users sign in via this client; per-role differentiation via `custom:role` in handler code | Original D2 had both Portal-Customer + Portal-Internal audiences accepted; rejected as inconsistent with [phase-2b-portal-integration.md](phase-2b-portal-integration.md) L1 unified-portal model. Two-audience setup baked in a URL-based security obscurity layer that the rest of the architecture (JWT-claim-based) doesn't rely on | Single authorizer + single audience is simpler. Portal-Internal client repurposed for non-browser tools (CLI / server-side). For token lifetimes on `internal_*` roles, see new Q8 below |
| D3 | Single stub endpoint `GET /api/v1/me` for foundation smoke | No stub (deploy + verify via CLI only); multiple stubs (`/health`, `/version`, `/me`) | One stub covers the full pipeline including JWT claim extraction. Health check isn't useful (it's the same Lambda; if `/me` works, health works) |
| D4 | Audit middleware as a decorator using Powertools `middleware_factory` | Manual `emit_audit()` calls in every handler | Decorator means handlers can't forget; consistency is enforced at infrastructure level. Per L5 of 1.7 spec the audit emission must be on every state-changing call — making it automatic prevents drift |
| D5 | Tenant enforcement in handlers (after authorizer), not at API Gateway | Custom Lambda authorizer that pre-checks tenancy | The tenancy check needs to compare JWT claim to a resource attribute (path or DDB lookup). Pre-resolving in an authorizer adds latency and only catches the path-level case. Handlers must do this regardless; centralize via `enforce_tenancy()` helper |
| D6 | WAF Managed Rules baseline only (no bot-control) | Add `AWSManagedRulesBotControlRuleSet` | Bot-control adds ~$10/mo per Web ACL plus per-request charges. Overkill at MVP. Revisit when real bot traffic appears (Phase 3A+ as portal goes public) |
| D7 | Stub Lambda is its own function, not folded into a future device-api or patient-api Lambda | Reuse one of the upcoming subset Lambdas for the stub | Stub is throwaway-eligible once business endpoints exist — keeping it separate means deleting it later is one resource removal, not a code refactor of a real handler |
| D8 | CloudWatch access logs in structured JSON, dedicated log group | Default text format; same log group as handler Lambdas | Structured JSON enables Logs Insights queries (latency-by-route, error-rate-by-ip). Dedicated group means access logs don't compete with handler debug output for retention/storage |
| D9 | Bundle the audit-stack subscription filter edit into 2A-0 deploy | Defer to a follow-up commit | Avoids a between-revisions gap where api-stub emits audit events that don't get forwarded. Migration Pattern 18.8 (silent-swallow risk) applies — better to ship both together |
| D10 | Add `auth.session.read` to event catalog now, even though `/me` is a stub endpoint | Wait until real auth surfaces in 2A-UM | Catalog is a contract; adding it now means the audit-forwarder's known-events check won't warn on this event when 2A-UM adds login flows that emit it |

## Open Questions

> Plain-language explanation of each question + a decision where we can call it. Decisions called now are mirrored into the Decisions Log above where they shape the implementation; the open ones are explicitly tagged with what would resolve them.

### Q1. How do we obtain a real Cognito token for smoke testing without standing up the portal first?

**What's actually being asked:** Testing `GET /api/v1/me` requires a valid JWT. The Flutter portal doesn't exist yet (2B). Standing up a test-only sign-in flow is busywork.

**What's at stake:** Whether T3+T6+T7 are runnable at deploy time or have to wait for 2B.

**Decision:** ✅ **Use the AWS CLI / Cognito SDK to get a token directly.** `aws cognito-idp initiate-auth --auth-flow USER_PASSWORD_AUTH --client-id <Portal-Customer> --auth-parameters USERNAME=...,PASSWORD=...` returns a real ID + Access token. Requires a test user with a real password assigned (which we already use for synthetic Pre-Token testing). Document the command in the deploy runbook.

---

### Q2. Should the `audit_middleware` decorator emit on 4xx errors, or only on success + 5xx?

**What's actually being asked:** A 403 means "authorized user tried something they're not allowed to do." That's audit-worthy (might be probing for vulnerabilities). But a 404 means "user looked up something that doesn't exist" — usually benign typos.

**What's at stake:** Audit log volume vs. forensic coverage. If we emit on every 404, the audit log fills with user typos. If we don't emit on 403, we miss attempted privilege escalation.

**Decision:** ✅ **Emit on success + 403 + 500; skip on 400/404/429.** 403 is the access-attempt signal we care about; 500 is a system event. 400/404/429 are caller-error patterns that don't need audit retention. Document in `api_audit.py`.

---

### Q3. Do we need API Gateway Resource Policy as a defense-in-depth on top of WAF + JWT?

**What's actually being asked:** API Gateway supports a resource policy that can restrict by source VPC, IP, AWS account, etc. — separately from WAF. Redundant with WAF in our case (we don't have an enterprise VPC source list to allow) but it's another layer.

**What's at stake:** Defense in depth vs. additional resource to maintain.

**Decision:** ✅ **Skip for v1.** WAF + JWT covers the public surface area. Resource policy makes sense when there's a known source-of-truth (VPC, partner AWS account) — neither applies at MVP. Revisit if a B2B partner integration appears.

---

### Q4. Should we deploy 2A-0 to prod (when prod account exists) before 2A-DL is also ready?

**What's actually being asked:** 2A-0 alone has no business value to prod customers. Standing up an API Gateway in prod that only serves a stub endpoint is operationally weird.

**What's at stake:** Whether prod-cutover happens per-subset or only after a meaningful set is ready.

**Decision:** ⏳ **Defer the prod-cutover decision until 2A-DL or 2A-RD is also ready.** Prod cutover should ship enough surface to be useful (DL + RD at minimum). 2A-0 alone in dev is fine for dev experimentation.

---

### Q5. How does the Audit-stack subscription filter list stay current as new API Lambdas are added in later subsets?

**What's actually being asked:** Today the Audit stack hardcodes 6 source handler log groups. We're adding a 7th in this phase. 2A-DL will add `device-api`, `discharge-cascade`, `device-shadow-handler` (and the latter is a special case since it already exists from 1B-rev probably). 2A-RD adds 1+. Eventually the hardcoded list is a maintenance hazard.

**What's at stake:** Forgetting to add a log group to the filter list means that handler's audit events never reach S3 (silent gap; very hard to spot once 2A is live).

**Decision:** ⏳ **For 2A-0: bundle the explicit add as part of the deploy (D9).** For long-term: probably an aspect-based approach (any Lambda tagged `audit:capture=true` automatically gets a filter). Spec the aspect in 2A-DL or 2A-RD; this phase doesn't need it yet.

---

### Q6. Do we want a `Retry-After` header on 429 rate-limit responses?

**What's actually being asked:** WAF rate-limit rule on API Gateway doesn't add the standard `Retry-After` header by default. Clients (especially the Flutter portal) can't programmatically back off without this header.

**What's at stake:** Worse UX on legitimate users who happen to hit the rate limit (their portal would just keep retrying immediately).

**Decision:** ⏳ **Defer — add when 2B portal traffic surfaces it.** Standard HTTP retry behavior without `Retry-After` is "exponential backoff with jitter" which the Flutter client should do anyway. If we see retry-storms in practice, add a Lambda gateway response that injects the header on 429.

---

---

### Q8. Token lifetimes for `internal_*` roles under the unified-portal model (DECIDED 2026-05-23)

**What's actually being asked:** Under the original dual-client design, internal users authenticated via the Portal-Internal Cognito client which enforced **30-min idle / 4-hr absolute** token lifetimes — tighter than Portal-Customer's **15-min idle / 30-day refresh**. Under the unified-portal decision ([phase-2b-portal-integration.md](phase-2b-portal-integration.md) L1), all web users — including internal — sign in via Portal-Customer. So how do we preserve the tighter security posture for internal roles?

**Initial plan (invalid):** Have the Pre-Token Generation Lambda override the `exp` claim for `internal_*` roles to a shorter window. **This doesn't work** — Cognito's Pre-Token V2 `claimsAndScopeOverrideDetails.claimsToAddOrOverride` cannot override reserved JWT claims (`exp`, `iat`, `iss`, `aud`, `sub`). The token's actual validity is set by Cognito itself from the App Client's `idTokenValidity` / `accessTokenValidity` config and cannot be per-user customized.

**Options:**

| # | Approach | Pros | Cons |
|---|---|---|---|
| A | All web users get Portal-Customer's 15-min idle / 30-day refresh. Flutter SPA tracks user-activity timestamp for `internal_*` roles, forces re-auth at 30-min idle. Backend handlers check `iat` claim for `internal_*` and 401 if > 4h since issue (the absolute cap) | Simple; no new infra; no impact on customer-user UX | Idle-cap is client-side enforced (bypassable by a sophisticated attacker who modifies the SPA). Absolute cap is real (server-side) |
| B | Add a third Cognito App Client (Portal-Internal-Web, no secret, 30-min idle / 4-hr absolute). Authorizer accepts 2 audiences again — both public. Portal tries Portal-Customer first; if resulting role is `internal_*`, signs out and re-auths via Portal-Internal-Web | Cognito-enforced lifetimes (correct) | Double-auth UX is awkward; SPA logic to pivot mid-flow |
| C | Drop the tighter posture; all roles get 15-min idle / 30-day refresh | Trivially simple | Loosens security for highest-privileged role — likely unacceptable for prod |

**Decision:** ✅ **Option A for MVP** + **Option B (or a server-side idle-tracking mechanism) as a pre-prod hardening item**, mirroring how Phase 1.5 multi-account and 1.7 Object Lock work (dev gets the simpler version; prod adds the rigorous version before first paying customer).

**Implementation surface (deployed 2026-05-23; amended 2026-05-24 for the dual-wiring fix):**

1. **`infra/lib/stacks/api-stack.ts`** — narrow `userPoolClients` array from `[portalCustomerClient, portalInternalClient]` to `[portalCustomerClient]` only. One-line change. ✅ Deployed 2026-05-23
2. **`infra/lambda/_shared/api_authz.py`** — `enforce_internal_session_age()` helper:
   ```python
   def enforce_internal_session_age(claims: dict, max_age_seconds: int = 4 * 3600) -> None:
       """For internal_* roles, reject if token issued > max_age_seconds ago.
       Mirrors the absolute-cap that the Portal-Internal Cognito client
       used to enforce when internal users had a separate client."""
       role = claims.get("custom:role", "")
       if not role.startswith("internal_"):
           return
       iat = int(claims.get("iat", 0))
       if iat == 0 or (time.time() - iat) > max_age_seconds:
           raise ApiError(401, "INTERNAL_SESSION_EXPIRED",
                          "Internal-tier session exceeded 4-hour absolute cap. Re-authenticate.")
   ```
   ✅ Deployed 2026-05-23 with 23 unit tests passing
3. **`infra/lambda/_shared/api_audit.py`** — `audit_middleware` decorator calls `enforce_internal_session_age()` BEFORE the wrapped handler. ✅ Deployed 2026-05-23. **But this only protects handlers that USE the @audit_middleware decorator. As of the initial deploy, only `api-stub` uses it** — `device-api`, `patient-api`, `alert-actions`, and `patient-mgmt` all use a custom dispatcher pattern (explicit `emit_audit` calls per action; the decorator can't accommodate multi-event flows like provision emitting `claimed` + `assigned` + `activation_sent`).
4. **Inline call in non-middleware handlers (amended 2026-05-24)** — the four handlers above each gain a one-line `enforce_internal_session_age(claims)` call right after `require_authenticated(claims)` in their main `handler()` entry point. This is the **actual** enforcement path for every endpoint internal users would hit. Without this, the dev-deployed amendment's claim of "4-hr absolute cap on internal_* sessions enforced app-layer" was technically untrue (the helper was wired only to api-stub's `/me` endpoint, not to any data-handling endpoints). ✅ Deployed 2026-05-24
5. **`docs/specs/phase-0a-revision.md`** — addendum note added 2026-05-24: "Portal-Internal client (`gvc7n839vj4ppgioamknlk21c`) is reserved for non-browser tools (CLI / server-side admin scripts) — no longer used by browser portal under Phase 2B-L1 unified-portal decision"
6. **`docs/specs/ARCHITECTURE.md` §4 Internal Access** — clarification added 2026-05-24: internal-token lifetime enforcement for browser users now lives in `enforce_internal_session_age` (app layer, called both from `audit_middleware` AND from non-middleware handlers' entry points), not at the Cognito client config

**What's at stake:** Pre-prod gate — Option B should be revisited before the first internal customer-data access in production. Until then, Option A is acceptable in dev where the threat model is "developers + Claude operating in trusted contexts."

---

### Q7. WAF + API Gateway HTTP API v2 — hard AWS limitation (surfaced at deploy)

**What's actually being asked:** First deploy attempt failed when WAFv2 rejected the API Gateway HTTP API v2 stage ARN with "The ARN isn't valid... parameter: arn:aws:apigateway:us-east-1::/apis/{id}/stages/$default". Investigation showed **WAFv2 does not support association with API Gateway HTTP API v2 stages.** Only REST API v1, CloudFront, ALB, AppSync, Cognito User Pool. This is documented (kind of) but easy to miss when planning.

**What's at stake:** Whether to revert D1 (REST API v1 instead of HTTP API v2) and pay the 70% cost premium + lose JWT-built-in, or defer WAF entirely.

**Decision:** ✅ **Defer WAF to Phase 3A (CloudFront).** Phase 3A puts a CloudFront distribution in front of both the portal S3 bucket and the API Gateway origin. WAF associates with the CloudFront distribution and protects both. The WAF managed rules (CRS, IP reputation) only meaningfully matter at the public edge — at MVP scale, JWT auth + API Gateway stage-level throttling (50 burst / 25 sustained in dev) covers basic abuse cases.

The `portal-waf.ts` construct and `apiWafRateLimitPerIp` config field are kept in source code for Phase 3A pickup. No code is deleted — the wire-up in `api-stack.ts` is commented out with a pointer to this Q7 explanation.

---

### Decision summary

| # | Question | Resolution |
|---|----------|-----------|
| Q1 | How to get a real Cognito token for smoke | ✅ AWS CLI `cognito-idp initiate-auth` — used at deploy time, works fine |
| Q2 | Audit middleware on 4xx | ✅ Emit on success + 403 + 500; skip 400/404/429 |
| Q3 | API Gateway resource policy | ✅ Skip for v1 |
| Q4 | Prod cutover for 2A-0 alone | ⏳ Defer until 2A-DL/RD ready |
| Q5 | Subscription filter list maintenance | ⏳ Manual add for 2A-0; aspect in 2A-DL/RD |
| Q6 | `Retry-After` on 429 | ⏳ Defer until portal traffic surfaces it |
| Q7 | WAF on HTTP API v2 | ✅ Defer to Phase 3A — WAFv2 doesn't support HTTP API v2 association; CloudFront fronts both |
| Q8 | Token lifetimes for `internal_*` roles under unified-portal | ✅ Option A (app-layer enforcement) for MVP — narrow authorizer audience to 1; add `enforce_internal_session_age` helper in `api_authz.py` called from `audit_middleware`. Option B (third public App Client) revisit pre-prod |

Five of eight decided now. Q4 + Q5 + Q6 require downstream phases or production usage to inform.

## Changelog

| Date | Author | Change |
|------|--------|--------|
| 2026-05-17 | Jace + Claude (cloud session) | Initial spec drafted as the foundation subset of Phase 2A. Carves out pure-plumbing concerns (API Gateway, WAF, JWT authorizer, audit middleware, error envelope, tenant enforcement) into a subset that ships independently, so device-lifecycle / patient-reads / alert-actions / user-management can each be 2-day sprints rather than week-long rebuilds. Bundles the Audit-stack subscription-filter update for the new api-stub log group (D9) to avoid a between-revisions silent-swallow gap. |
| 2026-05-17 | Jace + Claude (cloud session, same day) | **Deployed to dev** in 4 deploy attempts. Attempt-time issues: (1) `--exclusively` flag suppressed the Auth dependency; missing cross-stack export `ExportsOutputRefUserPoolPortalInternalClient...` (auto-generated when api-stack started referencing `portalInternalClient`); (2) `--exclusively` also prevented CDK from sequencing Audit-after-Api, leading to "log group doesn't exist" on the new ApiStub subscription filter; (3) WAF couldn't associate with API Gateway HTTP API v2 — hard AWS limitation, deferred to Phase 3A per new Open Question Q7. Final flow: `cdk deploy GoSteady-Dev-Api` (brings Auth as dependency, succeeded in 65.67 s) then `cdk deploy GoSteady-Dev-Audit --exclusively` (subscription filter add, 25.5 s). Smoke validated T3 + T4 + T8 + T16 end-to-end with a synthetic Cognito test user (`2a-smoke@test.local`, caregiver role, dtc_smoke_test client). The full pipeline works: GET /api/v1/me returns claims, 401 on no-auth, audit event lands in `gosteady-dev-audit` log group with all middleware-derived fields (actor, subject, request_id, xray_trace_id, schema_version: 1, auto-stamped internal_access + severity), and propagates to S3 within ~70s. Phase 1.7 Q8 (schema_version backfill) **partially closed** — api-stub emits with schema_version: 1, proving the helper extension works; 1B-rev Lambdas still emit without it (correct per L9 default-to-v1; will populate naturally on next processing-stack touch) |
| 2026-05-23 | Jace + Claude (portal session) | **Amendment — unified portal decision.** Updated L4, A5, In-Scope/Authorizer config, and D2 to reflect that the JWT authorizer's audience list narrows from 2 (Portal-Customer + Portal-Internal) to 1 (Portal-Customer only) under [phase-2b-portal-integration.md](phase-2b-portal-integration.md) L1. Added Q8 to handle token-lifetimes for `internal_*` roles after the dual-client model goes away — Pre-Token Lambda *cannot* override the `exp` claim (Cognito sets it from App Client config), so internal-user idle / absolute-cap enforcement moves to app layer: `enforce_internal_session_age` helper in `_shared/api_authz.py` called from `audit_middleware`, plus client-side idle detection in the Flutter SPA. Pre-prod hardening item: revisit Option B (third public Cognito App Client for internal-web) before first prod customer. **Implementation effort:** ~30 lines (CDK audience-list narrowing + Python helper + middleware wiring). To deploy: `cdk deploy GoSteady-Dev-Api --context env=dev`. No data migration. |

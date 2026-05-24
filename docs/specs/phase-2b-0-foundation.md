# Phase 2B-0 — Portal Foundation

## Overview
- **Phase**: 2B-0 (foundation subset of Phase 2B)
- **Status**: 🔲 Planned
- **Branch**: `feature/2b-portal-integration` (cut from `feature/infra-scaffold` 2026-05-24; lives in worktree `~/Documents/gosteady-portal-2b/`)
- **Date Started**: TBD
- **Date Completed**: TBD

Stands up the shared Flutter-side foundation that every Phase 2B subset (facility reads, facility writes, D2C household, internal-tier UI, polish) builds on: a `FacilityRepository` interface that both the existing mock (`FacilityMockData`) and a new live (`ApiClient`-backed) implementation satisfy; an extended `AuthService` with MFA challenge handling, forgot-password, and full custom-claim extraction; a typed `ApiClient` with JWT auto-attachment, error-envelope decoding, retry/backoff, and cursor pagination; `GoRouter`-based URL state for deep links; a thin shared `AppShell` widget; and **one smoke screen** that hits `GET /api/v1/me` so the full sign-in → JWT → API Gateway → handler → render pipeline is verifiable before any business UI lands.

The phase ships **minimum-viable AWS hosting** for the live build — S3 + CloudFront + WAF baseline + ACM cert at `dev.portal.gosteady.co`. This is a deliberate scope expansion from "pure-frontend" (per user direction 2026-05-24): waiting until Phase 3A for any real-domain deploy means CORS, CSP, SPA-routing, and CDN caching edge cases get discovered all at once at launch. Doing minimum-viable hosting now lets every 2B subset get tested at a real URL as it ships. Phase 3A retains the production polish (`portal.gosteady.co` prod hostname, tightened WAF + CSP, prod observability, CI/CD automation per 3B).

The deliverable is a portal that:

1. Builds in two modes from a single screen tree — `BUILD_MODE=demo` continues to publish the unchanged-feeling investor demo at `facilitydemo.gosteady.co`; `BUILD_MODE=live` produces the development portal at `dev.portal.gosteady.co`.
2. In live mode, signs a real user in against the Phase 0A-rev Cognito pool, attaches a real JWT to every API call, decodes the 2A-0 error envelope, and renders one smoke screen at a real HTTPS URL.
3. Preserves the existing marketing-demo deploy pipeline (`tools/deploy-demo.sh` + `GoSteadyWeb` Netlify) — demo stays on Netlify, just gets a subdomain alias.
4. Deploys via a new `tools/deploy-portal.sh` script (brute-force `aws s3 sync` + `cloudfront create-invalidation /*`) until 3B replaces it with CI/CD automation.

Once 2B-0 ships, the 2B-FAC-R / 2B-FAC-W / 2B-D2C subsets become per-screen swaps from `FacilityMockData` to `LiveFacilityRepository` — each shippable to the live dev URL the same day.

This is **frontend foundation + smoke endpoint + minimum-viable hosting**. The smoke screen exists to validate the plumbing end-to-end at a real domain.

## Locked-In Requirements

| # | Requirement | Decided In | Rationale |
|---|-------------|-----------|-----------|
| L1 | **Single screen tree, dual build via `BUILD_MODE`.** No directory copy of the facility demo; no fork. `lib/main.dart` and `lib/facility_demo/main_demo.dart` both remain — both shrink to thin entry points that construct the appropriate `FacilityRepository` + `AuthService` and hand off to a shared `AppShell`. All screens consume the abstractions, never the concrete impls | This spec — supersedes umbrella [phase-2b-portal-integration.md](phase-2b-portal-integration.md) line ~197 + ~458 ("drop `lib/facility_demo/` directory; demote mock to `test_support/`") which conflicted with keeping the marketing demo URL alive | The demo at `facilitydemo.gosteady.co` is a load-bearing marketing artifact. Killing the directory kills the URL. Two thin entry points that share screens has the same code-reuse property without forking visual responsibility for the marketing demo |
| L2 | **`BUILD_MODE` is a `--dart-define` enum** with documented values `demo` and `live`. Default = `demo` (so a forgetting-the-flag developer build looks like the demo, not like a broken portal). Adding new modes (e.g., `staging`) is a one-line enum extension | This spec | Single source of truth for build-time mode; readable name; future-extensible. Boolean `USE_MOCKS=1` was the alternative, but it conflated "data source" with "deployment context" |
| L3 | **`FacilityRepository` is the data abstraction.** The existing `FacilityMockData` class becomes the canonical mock implementation; a new `LiveFacilityRepository` (in `lib/data/live_facility_repository.dart`) is the API-backed implementation. Both implement the same `FacilityRepository` interface. Screens depend only on the interface | This spec | Mock side already mirrors the eventual API shape (per [facility-demo.md §6.2](facility-demo.md)); promoting it to a named interface formalizes the contract without rewriting either side |
| L4 | **`AuthService` is extended, not replaced.** The existing class at [auth_service.dart](../../lib/services/auth_service.dart) gains MFA challenge handling (replacing today's `throw AuthException('MFA not yet supported.')` at line 59), forgot-password, and full claim extraction (today's `_extractUser` at line 156 reads only `sub`/`email`/`name`/`custom:role`; needs `custom:clientId`, `custom:facilities`, `custom:censuses`, `custom:mfa_enrolled`). File moves from `lib/services/` to `lib/auth/` to sit next to `lib/auth/user_claims.dart` and the new MFA + forgot-password handlers | Phase 0A-rev (token lifetimes + claim shape) + umbrella L2 | Cognito SDK state already lives in this class; extracting wholesale would lose session-restore + listener wiring for no benefit |
| L5 | **Two parallel `AuthService` implementations** picked at the entry point. The new `MockAuthService` (a thin rename of today's `FacilityMockAuthService` to clarify scope) and the Cognito-backed `AuthService` both implement a shared `AuthServiceInterface`. Demo entry point constructs `MockAuthService`; live entry point constructs `AuthService` | This spec | Parallels L3's repository pattern. Avoids per-build `#ifdef`-style branching inside one class |
| L6 | **`ApiClient` is the single HTTP gateway.** Single class at `lib/api/api_client.dart`. Constructor takes `AuthService` (for token attachment) + `baseUrl` (from `--dart-define=API_BASE_URL=`). No HTTP from any widget directly. All retries, error-envelope decoding, audit-failure telemetry, opportunistic token refresh live here | Umbrella L4 | Centralizes the cross-cutting HTTP concerns; one place to inject test mocks; one place to swap base URL between dev API Gateway URL and (future Phase 3A) `/api/v1` same-origin reverse-proxy |
| L7 | **Error envelope decoded at `ApiClient` level into typed `ApiException`.** `{error: {code, message, details}}` per 2A-0 L7 → `ApiException(code, message, details, httpStatus)`. Widgets catch typed exceptions and render code-specific copy. Network failures (no envelope; raw timeout / DNS / 0-byte response) surface as `ApiException(code: 'NETWORK', httpStatus: 0)` | Phase 2A-0 L7 + umbrella L5 | Flutter UI needs structured codes; one SnackBar + retry pattern in `ApiClient` rather than per-call boilerplate |
| L8 | **Token refresh: opportunistic on every API call** when the ID token is within 60 s of expiry. Failure → forced sign-out + return to login. **Sliding 15-min idle** (Portal-Customer Cognito App Client) preserved by the Cognito SDK's session management | Phase 0A-rev token-lifetime config + umbrella L6 | 60 s buffer absorbs clock skew + network latency. Forced sign-out on refresh fail is the safest semantic |
| L9 | **`GoRouter` for URL state.** Census filter / sort / view-mode / selected-unit IDs persist in URL query string; patient drill-down is a path segment (`/patients/{patientId}`). Browser back-button works; shared links restore state | Umbrella L11 + user-needs §5 Reliability | URL-as-state is the simpler implementation; localStorage adds cross-tab drift risk. No PII in URL (unit IDs / patient IDs are opaque) |
| L10 | **One smoke route in live mode**: `/dev/me` calls `GET /api/v1/me` and renders the raw claim payload. Mirrors 2A-0's `/me` stub approach. Visible only when `BUILD_MODE=live` (in demo mode the route returns a 404-equivalent inside the app). **Removed in 2B-FAC-R** once real screens are wired | This spec — mirrors umbrella's "Smoke screen" pattern + Phase 2A-0's stub strategy | Lets us verify sign-in → JWT → API Gateway → handler → claim mirror → UI render end-to-end before any business UI |
| L11 | **No PII in URLs.** Patient IDs and serials in path params are acceptable per 2A-RD spec (opaque tokens, not patient-identifying alone); `displayName` / `dateOfBirth` / `email` never appear in any URL component (path, query, hash, fragment) | user-needs §5 Privacy | URL params land in access logs (2A-0 L10) and browser history; PII there is a leak. Same rule as 2A-RD L11 |
| L12 | **Marketing demo URL migration.** `gosteady.co/facilitydemo` → `facilitydemo.gosteady.co`. Subpath build needed `--base-href /facilitydemo/`; subdomain build needs neither — both modes (`demo` and `live`) build with `--base-href /`. Old URL retains a 301 redirect for ~90 days | This spec — answers user's "decomplicate" question 2026-05-24 | Removes the `--base-href` mismatch between demo and live builds (was the only Flutter config drift between them under approach C). URL symmetry with `portal.gosteady.co`. Demo deploy continues to ship via the same `tools/deploy-demo.sh` pipeline; only `GoSteadyWeb` hosting config changes |
| L13 | **`portal.gosteady.co` is the production portal URL** (lands in Phase 3A). **`dev.portal.gosteady.co` is the development portal URL** (lands in 2B-0). Both nest under `gosteady.co` per the user-confirmed naming pattern 2026-05-24 | ARCH §2 + Phase 3A spec + user direction 2026-05-24 | Dev URL clearly signals environment; prod stays clean. Both hostnames are CNAMEs at Netlify (gosteady.co's DNS provider) pointing to their respective CloudFront distributions |
| L14 | **Minimum-viable AWS hosting in 2B-0.** New CDK stack `GoSteady-Dev-PortalHosting`: S3 + CloudFront + OAC + ACM cert (us-east-1) + baseline WAF (Common Rule Set + rate limit) + SPA 404 → `index.html` rewrite + permissive baseline CSP. **Production-grade tightening (tightened WAF + CSP + IP-reputation list + prod-grade observability + CI/CD automation + production hostname `portal.gosteady.co`) explicitly remains in Phase 3A** | This spec — user direction 2026-05-24 ("test end-to-end throughout development if we can") | Real-domain testing every commit catches CORS / CSP / SPA-routing edge cases as they appear rather than all at launch. CDK addition is ~300-500 lines in one new stack. No DDB / no Lambda changes (still pure-frontend in the application sense) |
| L15 | **Build artifacts deployed to `dev.portal.gosteady.co` via `tools/deploy-portal.sh`** (brute-force `aws s3 sync` + `cloudfront create-invalidation /*`). Production deploy to `portal.gosteady.co` is Phase 3A; CI/CD automation is Phase 3B | This spec | The script is intentionally crude — its job is to make "ship a 2B change" a 30-second mental cost so we actually do it every commit. 3B's automation is the real solution, but the manual script bridges the gap |
| L16 | **`gosteady.co` DNS stays at Squarespace Domains** (user-confirmed 2026-05-24 via DNS-panel screenshot). Domain is registered + DNS authoritative there; current A/CNAME records (`apex-loadbalancer.netlify.com`, `75.2.60.5`) point traffic at Netlify hosting for the marketing site. New subdomains (`dev.portal.gosteady.co`, `facilitydemo.gosteady.co`, future `portal.gosteady.co`) are added as CNAME records via Squarespace's DNS Settings → Custom records panel. ACM cert validation uses DNS-validation CNAMEs added the same way. No DNS migration to Route53 | User direction 2026-05-24 | Squarespace DNS supports custom CNAMEs to external hosts (confirmed by the existing `www → apex-loadbalancer.netlify.com` record). Migrating DNS to Route53 is a real one-time chore that buys little |
| L17 | **`facilitydemo.gosteady.co` stays on Netlify** (user-confirmed 2026-05-24). Migration from `gosteady.co/facilitydemo` is two changes: (a) add `facilitydemo.gosteady.co` as a custom domain on the existing Netlify site (`GoSteadyWeb`), (b) add a CNAME record at Squarespace DNS panel pointing `facilitydemo` to the Netlify-issued target (`apex-loadbalancer.netlify.com` or similar). Plus 301 redirect from the old subpath. No CDK / no S3+CF for the demo | User direction 2026-05-24 | Demo doesn't need WAF / CSP / cache-invalidation discipline; Netlify is fine. Asymmetric hosting (demo on Netlify, portal on S3+CF) is an acceptable cost for keeping demo migration trivial |

## Assumptions

| # | Assumption | Risk if Wrong | Validation Plan |
|---|-----------|---------------|-----------------|
| A1 | `amazon_cognito_identity_dart_2` v3.6.0 correctly handles the Phase 0A-rev Pre-Token Lambda V2's claims in **both** ID and Access tokens (today's `auth_service.dart` only reads ID-token claims; per 2A-0 L4 the same claims live in both) | If only the ID token carries claims, API calls authenticated with the Access token would fail tenancy checks at the handler | API Gateway HTTP API JWT authorizer uses the Access token by default. Verify in T1: hit `GET /api/v1/me` with the SDK's default Authorization header and confirm 200 with full claim set |
| A2 | The SDK supports MFA challenge interception. Today's code throws `AuthException('MFA not yet supported.')` on `CognitoUserMfaRequiredException` at [auth_service.dart:59](../../lib/services/auth_service.dart#L59); the SDK readme indicates `CognitoUser.sendMFACode(code)` continues the challenge | If the SDK can't continue the challenge cleanly, may need a custom continuation flow against Cognito InitiateAuth directly | Test against a `facility_admin` test user with MFA enrolled; if the SDK API doesn't work, fall back to `cognitoUser.respondToAuthChallenge` plumbed directly |
| A3 | `GoRouter` v14+ works on Flutter Web with path-based URL strategy (no `#` prefix) on Chrome, Safari, Firefox, Edge | Bookmarked / shared URLs may break cross-browser | Flutter docs + `url_strategy` package validate; smoke test in T6 |
| A4 | The Portal-Customer Cognito App Client (`1q9l9ujtsomf3ugq2tnqvdg6d7`) is sufficient for all 2B-0 sign-ins. Pre-Token Lambda enforces MFA + claim injection regardless of role; the same client serves customer + (future) internal users per [phase-2b-portal-integration.md L1](phase-2b-portal-integration.md) | If internal users somehow need the Portal-Internal client (with secret), the SDK's no-secret flow won't authenticate them | Per the 2026-05-23 Q8 amendment in [phase-2a-foundation.md L4](phase-2a-foundation.md), Portal-Internal is reserved for non-browser tools. Web users — including internal staff — all sign in via Portal-Customer |
| A5 | `--dart-define` is read at Flutter Web compile time and injected into the JS bundle (not a runtime env lookup that would fail in production) | Flag value is undefined at runtime; mode detection fails | Documented Flutter behavior; verified by every `flutter build web` invocation that produces a working bundle |
| A6 | A test user exists in the Cognito pool (`us-east-1_ZHbhl19tQ`) with `facility_admin` role + `mfa_enrolled=true` + a RoleAssignments row scoped to a real facility, and that facility has at least one patient with activity. Required for T1–T5 smoke validation | Smoke tests fail with NO_ROLE_ASSIGNED or 0-row Census | Cloud session has already validated 2A-RD against `pt_bench_98`; reuse that fixture. Spec lists the test-user bring-up as a Deployment prerequisite |
| A7 | Demo mock data continues to render correctly with no `--base-href` prefix (was previously baked at `/facilitydemo/`). All asset paths and route definitions are root-relative | Demo loads but assets 404 / routes break | Test by running `flutter build web -t lib/facility_demo/main_demo.dart --dart-define=BUILD_MODE=demo` (no base-href) and serving from `localhost:8080` ; check all images + chart fonts + route transitions |
| A8 | Migrating the demo URL doesn't break investor / partner deck links during the rollout window | Existing shared links break; awkward investor email | 301 redirect from `gosteady.co/facilitydemo/*` → `https://facilitydemo.gosteady.co/$1` in marketing site's `_redirects` for ≥90 days. Notify any active investor thread proactively |
| A9 | ACM cert DNS-validation CNAMEs added to Squarespace DNS resolve fast enough for the CDK deploy to complete in one shot (≤30 min total) | CDK deploy hangs indefinitely on the certificate resource; operator has to abort + retry | Per AWS docs, ACM DNS validation typically completes within minutes once the CNAME is published. Squarespace DNS TTL is 1 hr by default but propagation is typically faster than TTL. Spec calls out a pre-deploy operator action to add the validation records before `cdk deploy` so the cert validates promptly when reached |
| A10 | Squarespace DNS supports the CNAME records we need (subdomain CNAMEs to `*.cloudfront.net` AWS-issued domains; ACM validation CNAMEs with the AWS-prefixed names like `_<random>.<subdomain>.gosteady.co`) | If Squarespace rejects the AWS-format validation CNAME names, ACM validation can't complete — fallback to email validation (slower, fragile) or DNS migration to Route53 | Squarespace DNS supports standard custom CNAME records (the existing `www → apex-loadbalancer.netlify.com` proves it). Smoke-test the AWS-format validation CNAMEs during T12 below; if Squarespace can't handle them, fall back to ACM email validation as a one-off for this cert |

## Scope

### In Scope

**`lib/` library additions:**

```
lib/
  api/                              ← new
    api_client.dart                 # the single HTTP gateway (L6)
    api_models.dart                 # request/response shapes mirroring 2A-RD/2A-AA/2A-DL
    api_exception.dart              # typed exceptions per 2A-0 error envelope (L7)
    pagination.dart                 # cursor token round-tripping helper
  auth/                             ← new
    auth_service_interface.dart     # abstract AuthService contract (L5)
    auth_service.dart               # MOVED from lib/services/; extended (L4)
    mock_auth_service.dart          # renamed from lib/facility_demo/services/mock_facility_auth.dart
    user_claims.dart                # full custom-claim model (L4)
    mfa_challenge_handler.dart      # TOTP setup + verify flow
    forgot_password_handler.dart    # email-link reset
  data/                             ← new
    facility_repository.dart        # abstract FacilityRepository (L3)
    live_facility_repository.dart   # ApiClient-backed implementation (L3)
    # lib/facility_demo/data/facility_mock_data.dart implements the same interface (no move)
  state/                            ← new
    app_router.dart                 # GoRouter config — URL → page mapping (L9)
    app_state.dart                  # InheritedNotifier hub: AuthService + ApiClient + FacilityRepository + BuildMode
    build_mode.dart                 # enum + dart-define reader (L2)
  shell/                            ← new
    app_shell.dart                  # shared AuthGate + theme + router host; takes injected dependencies
  dev/                              ← new (removed in 2B-FAC-R)
    me_smoke_screen.dart            # renders raw /api/v1/me payload (L10)
```

**Routes (GoRouter):**

| Path | Page | Auth-gated? | Build mode visibility |
|---|---|---|---|
| `/sign-in` | LoginScreen | public | both |
| `/forgot-password` | Forgot-Password flow | public | live only |
| `/mfa-setup` | MFA Enrollment (for facility_admin+ first sign-in) | authed-but-not-MFA-enrolled | live only |
| `/mfa-verify` | MFA TOTP verify (every sign-in for MFA-required roles) | mid-challenge | live only |
| `/` | Redirect to Census (or smoke screen if `?smoke=1`) | gated | both |
| `/census` | CensusPage (Facility shell home — existing demo screen) | gated | both |
| `/patients/:patientId` | PatientDetailPage (overlay on top of `/census`) | gated | both |
| `/patients/:patientId/device` | DeviceDetailPage (existing screen) | gated | both |
| `/dev/me` | MeSmokeScreen (renders raw JWT claims, L10) | gated | live only |
| `*` | NotFoundPage | gated | both |

Demo mode hides the auth-recovery routes (no forgot-password / MFA setup against a mock backend) and the smoke route. The shared screens (`/census`, `/patients/:patientId`) work identically in both modes via the `FacilityRepository` injection.

**Migrate (in-place, no functional change visible to investors):**

- [lib/services/auth_service.dart](../../lib/services/auth_service.dart) → `lib/auth/auth_service.dart` + add the MFA + forgot-password handlers + full claim extraction
- [lib/facility_demo/services/mock_facility_auth.dart](../../lib/facility_demo/services/mock_facility_auth.dart) → `lib/auth/mock_auth_service.dart`. The class is renamed `FacilityMockAuthService` → `MockAuthService` and made to implement `AuthServiceInterface`. Public surface (`init`/`signIn`/`signOut`/`currentUser`/`isSignedIn`) is unchanged; the demo continues to work
- [lib/facility_demo/data/facility_mock_data.dart](../../lib/facility_demo/data/facility_mock_data.dart) → made to `implement FacilityRepository`; stays in place (this is the canonical mock for the marketing demo, not a test fixture)
- [lib/models/user.dart](../../lib/models/user.dart) → expanded `UserRole` enum to the 8-customer + 2-internal role model from Phase 0A-rev (V1 UI collapses to one Care Staff role per umbrella L13, but the data model carries the full set)
- [lib/main.dart](../../lib/main.dart) → reads `BUILD_MODE` dart-define; constructs `(AuthService, LiveFacilityRepository, ApiClient)` if `live`, else delegates to the demo entry; wires into shared `AppShell`
- [lib/facility_demo/main_demo.dart](../../lib/facility_demo/main_demo.dart) → keeps the `?w=` viewport override hack; constructs `(MockAuthService, FacilityMockData)` and hands off to the shared `AppShell`
- [lib/screens/login_screen.dart](../../lib/screens/login_screen.dart) → strip the legacy walker/caregiver signup flow ([login_screen.dart:21](../../lib/models/user.dart#L21) two-role choice removed per umbrella 2B-D2C scope); add MFA challenge step; add Forgot Password link. Signup itself is removed from the portal — D2C signup is a marketing-site flow per umbrella

**`pubspec.yaml` additions:**

- `go_router: ^14.0.0`
- `url_strategy: ^0.3.0` (path-based URLs, no `#`)
- Confirm existing pins: `amazon_cognito_identity_dart_2: ^3.6.0`, `shared_preferences: ^2.2.0`, `http: ^1.1.0` (currently the dashboard's mock data layer pulls `http` transitively; surface it as an explicit dep)
- No new dev dependencies

**`web/index.html`:**

- Add `<script>window.flutterConfiguration = { ... }</script>` only if needed for path strategy; default `url_strategy.setPathUrlStrategy()` should suffice
- Remove any `<base href="/facilitydemo/">` if present (it isn't currently; the demo passes `--base-href` at build time)

**`tools/deploy-demo.sh` modifications:**

- Drop `--base-href /facilitydemo/`; build at root
- Add `--dart-define=BUILD_MODE=demo` to the build command
- Update destination path in `GoSteadyWeb` from `GoSteadyWeb/facilitydemo/` to (eventually) the dedicated subdomain target. **Two-phase rollout:**
  1. **2B-0 ship:** script still writes to `GoSteadyWeb/facilitydemo/` (no break); demo continues to live at `gosteady.co/facilitydemo` via the existing subpath. `--base-href` is added back temporarily until the subdomain is live. This is a sequencing concession to avoid breaking the live URL during dev work
  2. **DNS-cutover follow-up (separate small task, not 2B-0):** stand up `facilitydemo.gosteady.co` (DNS + Netlify subdomain config); flip `deploy-demo.sh` to write to the new target; remove `--base-href`; add 301 redirect from old subpath to new subdomain in `_redirects`
- Build invocation simplifies to (post-cutover):
  ```bash
  flutter build web -t lib/facility_demo/main_demo.dart --dart-define=BUILD_MODE=demo
  ```

**Build invocations (target shape after cutover):**

| Mode | Entry | Flags | Output | Deploy |
|---|---|---|---|---|
| Demo (dev) | `lib/facility_demo/main_demo.dart` | `--dart-define=BUILD_MODE=demo` | `build/web/` | Local `flutter run` or `python3 -m http.server` |
| Demo (prod) | `lib/facility_demo/main_demo.dart` | `--dart-define=BUILD_MODE=demo` | `build/web/` | `tools/deploy-demo.sh` → Netlify → `facilitydemo.gosteady.co` |
| Live (dev) | `lib/main.dart` | `--dart-define=BUILD_MODE=live --dart-define=API_BASE_URL=https://<api-gw-id>.execute-api.us-east-1.amazonaws.com` | `build/web/` | Local `flutter run -d chrome` |
| Live (prod) | `lib/main.dart` | `--dart-define=BUILD_MODE=live --dart-define=API_BASE_URL=/api/v1` | `build/web/` | Phase 3A — S3 + CloudFront → `portal.gosteady.co` |

#### Hosting (minimum-viable deploy)

New CDK stack `GoSteady-Dev-PortalHosting`. Lives in `gosteady-portal/infra/lib/stacks/portal-hosting-stack.ts`. Scope is intentionally minimal — production polish (tightened WAF + CSP + IP-reputation list + prod-grade observability + production hostname) stays in Phase 3A.

**Resources:**

- **S3 bucket** `gosteady-dev-portal-hosting`:
  - All public access blocked
  - SSE-S3 (no need for CMK — Flutter bundle is public anyway once served)
  - No website-hosting mode; bucket is private, served via CloudFront OAC only
  - Versioning enabled (rollback safety)
  - Lifecycle: previous versions deleted after 30 days

- **CloudFront distribution** `dev.portal.gosteady.co`:
  - **Origin Access Control (OAC)** for S3 (not OAI — OAC is the current AWS-blessed pattern)
  - **Default root object:** `index.html`
  - **SPA 404 → `index.html` rewrite:** custom error response — 403 + 404 both rewrite to `/index.html` with HTTP 200, so deep links like `/patients/pt_bench_98` resolve correctly when refreshed
  - **Cache behavior:** default cache policy `CachingOptimized` for assets; `index.html` cached for 5 minutes max (so a deploy is visible within 5 min even without explicit invalidation, but `deploy-portal.sh` invalidates `/*` anyway)
  - **Compression:** enabled (Brotli + gzip)
  - **HTTP version:** HTTP/2 + HTTP/3
  - **PriceClass:** `PriceClass_100` (US + CA + EU only) per ARCH §3
  - **Web ACL association:** the new WAF below
  - **Logging:** disabled in dev (enable in 3A prod)

- **ACM certificate** (us-east-1, required for CloudFront viewer cert):
  - SANs: `dev.portal.gosteady.co`
  - DNS validation (validation CNAMEs added manually at Squarespace per L16 + the pre-deploy operator action below)
  - **CDK gotcha:** the cert resource takes ~30 min to validate; CDK deploy hangs on it. Operator must add the validation CNAMEs **before** `cdk deploy` to make this a single-pass deploy

- **WAF v2 web ACL** `gosteady-dev-portal-hosting-waf`:
  - `AWSManagedRulesCommonRuleSet`
  - Rate-limit rule: 2000 requests / 5 min / source IP
  - `AWSManagedRulesAmazonIpReputationList` — **deferred to 3A** (low-priority for dev portal; would block AWS IP-reputation list flagged IPs which sometimes false-positive on legitimate users)
  - CloudWatch metrics enabled per rule

- **CloudFront → S3 read permissions** via OAC + S3 bucket policy:
  - Bucket policy grants `s3:GetObject` from the CloudFront distribution only (via `AWS:SourceArn` condition)

- **Stack outputs:**
  - `DistributionDomainName` — `<random>.cloudfront.net` (the value the Squarespace CNAME points to)
  - `DistributionId` — used by `deploy-portal.sh` for invalidation
  - `BucketName` — used by `deploy-portal.sh` for sync
  - `CertificateValidationRecords` — the CNAME records to add at Squarespace (printed by CDK pre-deploy via `--require-approval` or surfaced via a manual `aws acm describe-certificate` call after the cert resource is created)

**Modified existing stack `GoSteady-Dev-Api`:**

- `apiCorsAllowedOrigins` in [infra/lib/config.ts](../../infra/lib/config.ts) gains `https://dev.portal.gosteady.co` (and existing `http://localhost:8080` stays for local dev). Single one-line config change + `cdk deploy GoSteady-Dev-Api`. Phase 2A-0's CORS preflight handler picks it up automatically per 2A-0 L9

**Operator actions (one-time setup, before `cdk deploy GoSteady-Dev-PortalHosting` completes):**

1. **Initial CDK synth + cert creation.** `cdk deploy GoSteady-Dev-PortalHosting` will create the cert resource and **hang on validation**. Either:
   - **Option A (one-shot deploy):** run `cdk synth GoSteady-Dev-PortalHosting`, find the `CertificateValidationRecords` CFN output value (or use `aws acm list-certificates` + `describe-certificate` after the cert resource is created but before validation), add the validation CNAMEs at Squarespace DNS, then run `cdk deploy` — the cert validates promptly and the deploy completes
   - **Option B (two-pass deploy):** run `cdk deploy`; let it hang briefly; in another shell pull the validation CNAMEs via `aws acm describe-certificate`; add them at Squarespace; CDK eventually picks them up
2. **Add CNAME at Squarespace DNS panel:** name `dev.portal`, type CNAME, data = CDK output `DistributionDomainName` (e.g., `d123abc456def.cloudfront.net`), TTL 1 hr default
3. **Verify HTTPS works:** `curl -I https://dev.portal.gosteady.co/` should 200 (after the bucket has at least `index.html` in it; pre-first-deploy will 403 or 404, which is expected)

**`tools/deploy-portal.sh` (new):**

```bash
#!/usr/bin/env bash
# Build and deploy gosteady-portal live build to dev.portal.gosteady.co
# Usage: ./tools/deploy-portal.sh [--build-only]
set -euo pipefail

API_URL=$(aws cloudformation describe-stacks --stack-name GoSteady-Dev-Api \
  --query 'Stacks[0].Outputs[?OutputKey==`ApiUrl`].OutputValue' --output text)

flutter build web -t lib/main.dart \
  --dart-define=BUILD_MODE=live \
  --dart-define=API_BASE_URL="$API_URL" \
  --release

if [[ "${1:-}" == "--build-only" ]]; then
  echo "Build complete at build/web/. Skipping deploy."; exit 0
fi

BUCKET=$(aws cloudformation describe-stacks --stack-name GoSteady-Dev-PortalHosting \
  --query 'Stacks[0].Outputs[?OutputKey==`BucketName`].OutputValue' --output text)
DIST_ID=$(aws cloudformation describe-stacks --stack-name GoSteady-Dev-PortalHosting \
  --query 'Stacks[0].Outputs[?OutputKey==`DistributionId`].OutputValue' --output text)

aws s3 sync build/web/ "s3://$BUCKET/" --delete
aws cloudfront create-invalidation --distribution-id "$DIST_ID" --paths "/*"
echo "Deployed to https://dev.portal.gosteady.co/"
```

**Cost estimate** (steady-state dev usage, ~10-50 page loads/day):

- S3: pennies/mo
- CloudFront: free tier covers <50 GB egress; $0.085/GB beyond. Dev load is ~negligible
- ACM cert: free
- Route53: N/A (DNS is at Squarespace)
- WAF: $5/mo per Web ACL + $0.60 per million requests + $1/mo per managed rule group. **Dominant cost ~$6-7/mo** for the Web ACL + Common Rule Set
- **Total: ~$7-10/mo** in dev

### Out of Scope (Deferred)

- **Live data on any business screen** — Census, Patient Detail, Notification Review remain mock-backed even in live mode until 2B-FAC-R wires them to `LiveFacilityRepository`. 2B-0 ships the abstraction + the smoke screen, not the wiring
- **Phase 3A production hosting polish** — production hostname `portal.gosteady.co` (separate CloudFront distribution + separate ACM cert); tightened WAF (add `AWSManagedRulesAmazonIpReputationList`, tune rate limits to production volume); tightened CSP / security headers policy; CloudFront logging enabled + observability dashboards; multi-region replication if needed
- **CI/CD automation for portal deploys (Phase 3B)** — `deploy-portal.sh` is intentionally a manual script in 2B-0. 3B adds GitHub Actions or AWS CodePipeline that runs `flutter build` + S3 sync + CloudFront invalidation on merge to main
- **DNS cutover for `facilitydemo.gosteady.co`** — operational follow-up after 2B-0 ships. Two Squarespace-panel actions + one Netlify-panel action (add custom domain on Netlify site) + 301 redirect; execution is a separate small task, not a 2B-0 code commit
- **Notification engine server-side migration** — the demo's [notification_engine.dart](../../lib/facility_demo/data/notification_engine.dart) computes 3 rules (No-activity / Below-typical / Declining-trend) client-side. Per umbrella A3, this **must move server-side** before 2B-FAC-R, gated on Phase 1C resolution. 2B-0 doesn't touch it — demo continues to compute client-side as today; live mode shows count-only badges via `openAlertCount` (per umbrella 2B-FAC-R § Notification badges paragraph) until the server-side rule engine ships
- **D2C household path** — `lib/screens/dashboard_screen.dart` (legacy D2C dashboard) is untouched in 2B-0. Its `MockDataSource` (a different class from `FacilityMockData`) stays as today. 2B-D2C subset rewires it
- **Internal-tier UI surface** — 2B-INT subset; depends on 2A-INT which doesn't have a spec yet
- **Audit-log UI** — V2 / out of 2B entirely per user-needs §6
- **Polling cadence + URL-state schema for Census** — these are 2B-FAC-R deliverables. 2B-0 wires GoRouter and proves URL-as-state works; the specific `?units=&sort=&filter=&view=` schema lands when the live Census page is wired
- **MFA enrollment UX for existing pool users** — Pre-Token Lambda enforces `mfa_enrolled=true` for facility_admin+; users created before MFA was enforced will hit the gate. 2B-0 wires the `/mfa-setup` route shell, but the visual flow (QR code + 6-digit verify + recovery codes) gets a focused design pass before T8 in this spec is run end-to-end
- **CI build guard** — verifying both demo and live builds compile clean on every PR is Phase 3B work, not 2B-0. Developer discipline: run both `flutter build web` invocations locally before pushing
- **Production deploy of live mode** — Phase 3A
- **OpenAPI / API documentation** — out of 2B entirely per umbrella

## Architecture

### Infrastructure Changes

**New CDK stack `GoSteady-Dev-PortalHosting`** (~10 resources):

- 1 × `AWS::S3::Bucket` (private; SSE-S3; versioning; lifecycle to clean old versions)
- 1 × `AWS::S3::BucketPolicy` (CloudFront OAC `AWS:SourceArn` condition)
- 1 × `AWS::CloudFront::Distribution`
- 1 × `AWS::CloudFront::OriginAccessControl`
- 1 × `AWS::CertificateManager::Certificate` (us-east-1; DNS-validated)
- 1 × `AWS::WAFv2::WebACL`
- 1 × `AWS::WAFv2::WebACLAssociation` (binds Web ACL to CloudFront)
- 3 × CFN outputs (`BucketName`, `DistributionId`, `DistributionDomainName`)

**Modified existing stack `GoSteady-Dev-Api`:**

- Add `https://dev.portal.gosteady.co` to `apiCorsAllowedOrigins` ([infra/lib/config.ts](../../infra/lib/config.ts))
- Deploy: `cdk deploy GoSteady-Dev-Api`
- Phase 2A-0's CORS preflight handler picks up the new origin automatically per 2A-0 L9

**No DDB changes; no Lambda changes; no IAM additions outside the portal-hosting stack** (still pure-frontend at the application layer).

**Squarespace DNS additions (operator-action, one-time):**

1. ACM cert validation CNAMEs (added pre-deploy per the operator-action note in §Scope; can be deleted after the cert is issued)
2. `dev.portal` → `<cf-distribution>.cloudfront.net` CNAME (persists)
3. (Follow-up task, post-2B-0) `facilitydemo` → `apex-loadbalancer.netlify.com` CNAME (or whatever Netlify issues for the new custom domain)

### Data Flow

**Sign-in (live mode):**

```
User                                                                          
  │ enters email + password on /sign-in                                        
  ▼                                                                           
LoginScreen                                                                   
  │ AuthService.signIn(email, password)                                       
  ▼                                                                           
AuthService (Cognito SDK — InitiateAuth USER_PASSWORD_AUTH)                   
  │                                                                           
  ├── 200 OK + tokens                  → emit GoSteadyUser via _extractClaims 
  │                                       → notifyListeners                   
  │                                       → GoRouter redirects to `/`         
  │                                                                           
  ├── 200 OK + challenge MFA           → route push `/mfa-verify`             
  │                                       → user enters 6-digit TOTP          
  │                                       → AuthService.completeMfaChallenge  
  │                                       → on success: same as 200 OK + tokens
  │                                                                           
  └── 4xx / 5xx                        → AuthException with code/message      
                                          → LoginScreen renders error         
```

**API call (any route in live mode):**

```
Widget                                                                        
  │ apiClient.getPatient(patientId)                                            
  ▼                                                                           
ApiClient                                                                     
  │                                                                           
  ├── 1. Read currentUser.idToken from AuthService                            
  │                                                                           
  ├── 2. If token expires < 60s, await AuthService.refresh()                  
  │       └── on failure → AuthService.signOut() + ApiException(code: 'UNAUTHENTICATED')
  │                                                                           
  ├── 3. http.get(baseUrl + path, headers: {Authorization: 'Bearer <id_token>'})
  │                                                                           
  ├── 4. Decode response                                                       
  │       ├── 2xx → parse body into typed response model                      
  │       ├── 4xx/5xx → parse {error: {code, message, details}} envelope      
  │       │              → throw ApiException(code, message, details, status) 
  │       └── network failure → throw ApiException(code: 'NETWORK', status: 0)
  │                                                                           
  └── 5. return typed response model                                           
```

**Build-mode detection (boot):**

```
flutter build web -t <main_file> --dart-define=BUILD_MODE=<demo|live> [--dart-define=API_BASE_URL=<url>]
                                                                              
At runtime:                                                                   
  BuildMode.current = BuildMode.fromDartDefine()                              
       reads const String.fromEnvironment('BUILD_MODE', defaultValue: 'demo') 
       returns BuildMode.demo or BuildMode.live                               
                                                                              
Entry point (lib/main.dart for live, lib/facility_demo/main_demo.dart for demo):
  switch (BuildMode.current) {                                                
    case BuildMode.live:                                                      
      final auth = AuthService.instance;                                      
      await auth.init();                                                      
      final apiClient = ApiClient(auth: auth, baseUrl: apiBaseUrl);           
      final repo = LiveFacilityRepository(apiClient: apiClient);              
      runApp(AppShell(auth: auth, repository: repo, apiClient: apiClient));   
    case BuildMode.demo:                                                      
      final auth = MockAuthService.instance;                                  
      await auth.init();                                                      
      final repo = FacilityMockData();                                        
      runApp(AppShell(auth: auth, repository: repo, apiClient: null));        
  }                                                                           
```

### Interfaces

#### `BuildMode` (new)

```dart
enum BuildMode {
  demo,
  live;

  static BuildMode get current {
    const raw = String.fromEnvironment('BUILD_MODE', defaultValue: 'demo');
    return BuildMode.values.firstWhere(
      (m) => m.name == raw,
      orElse: () => BuildMode.demo,
    );
  }

  bool get isLive => this == BuildMode.live;
  bool get isDemo => this == BuildMode.demo;
}
```

#### `AuthServiceInterface` (new)

```dart
abstract class AuthServiceInterface extends ChangeNotifier {
  Future<void> init();                              // restore session
  Future<GoSteadyUser> signIn(String email, String password);
  Future<void> completeMfaChallenge(String code);   // NEW in 2B-0
  Future<void> enrollMfa();                          // returns TOTP secret + QR uri
  Future<void> forgotPassword(String email);         // sends Cognito code
  Future<void> confirmForgotPassword(String email, String code, String newPassword);
  Future<void> signOut();
  Future<String?> getIdToken();                      // auto-refresh on demand
  GoSteadyUser? get currentUser;
  bool get isSignedIn;
}
```

`MockAuthService` implements all methods; MFA / forgot-password methods are no-ops or throw `UnsupportedError` in demo mode (UI routes that depend on them are hidden in demo mode per the route table above).

#### `FacilityRepository` (new)

```dart
abstract class FacilityRepository {
  // Read surface — mirrors today's FacilityMockData public methods so demo
  // screens compile unchanged. Live impl assembles equivalent values from
  // one or more ApiClient calls + caches per-screen.
  List<Facility> allFacilities();
  List<Unit> unitsForFacility(String facilityId);
  List<Unit> allUnits();
  Future<List<PatientSummary>> patientsForSelection(Set<String> selectedUnitIds);
  Future<Patient> patientById(String patientId);
  Future<DailyActivity> todayFor(String patientId);
  Future<List<DailyActivity>> last7DaysFor(String patientId);
  Future<List<DailyActivity>> last30DaysFor(String patientId);
  Future<List<WeeklyActivity>> last6MonthsFor(String patientId);
  Future<DeviceHealth> deviceFor(String patientId);
  Future<NotificationContext> notificationContextFor(String patientId);
  Future<PatientRowStats> rowStatsFor(String patientId);
  
  // Write surface added incrementally in 2B-FAC-W per umbrella
}
```

Note: the existing `FacilityMockData` methods are synchronous (return `List<...>` directly). The interface promotes them to `Future<...>` so the live impl can do real I/O. Mock impl wraps results in `Future.value(...)` — a one-line mechanical change. Screens that currently call synchronously need to `await` or use `FutureBuilder` — caught at compile time.

#### `ApiClient` (new)

```dart
class ApiClient {
  ApiClient({required AuthServiceInterface auth, required String baseUrl});

  // Reads — 2A-RD (deployed)
  Future<MePatientsResponse> getMyPatients({String? cursor, String? clientId});
  Future<PatientDetailResponse> getPatient(String patientId);
  Future<ActivityResponse> getActivity(String patientId, ActivityRange range, {String? cursor});
  Future<AlertsResponse> getAlerts(String patientId, AlertStatus status, {String? cursor});
  Future<DeviceResponse> getDevice(String serial);
  Future<CensusRosterResponse> getCensusRoster(String facilityId, String censusId, {String? cursor});

  // /me smoke (2A-0) — 2B-0 ships this single endpoint mapping
  Future<MeResponse> getMe();

  // Writes — 2A-AA + 2A-DL (deployed) — interface surface here, wiring in 2B-FAC-W
  // Writes — 2A-UM-P (deployed dev 2026-05-24 per commit e5ea6e6) — interface surface
  //          here, wiring in 2B-FAC-W. 2A-UM-H (household onboarding) + 2A-UM-S (staff
  //          user creation) are deferred follow-ups, NOT V1-blocking
}
```

#### `ApiException`

```dart
class ApiException implements Exception {
  final String code;      // e.g., "TENANCY_VIOLATION", "NETWORK"
  final String message;   // user-facing copy
  final Map<String, dynamic>? details;
  final int httpStatus;
}
```

`ApiClient` decodes every non-2xx response per the 2A-0 envelope. Network failures surface as `ApiException(code: 'NETWORK', message: 'Connection lost. Retry?', httpStatus: 0)`.

#### `GoSteadyUser`

```dart
class GoSteadyUser {
  final String userId;          // Cognito sub
  final String email;
  final String displayName;
  final UserRole role;          // full 8+2 enum (Phase 0A-rev)
  final String? clientId;       // null only for the demo's MockAuthService session
  final List<String> facilities;
  final List<String> censuses;
  final bool mfaEnrolled;
  // ID token NOT stored on this object — fetched on-demand via getIdToken()
}
```

#### URL state shape (proven, not fully wired)

GoRouter is configured at 2B-0; the Census route accepts query params per umbrella L11:

```
/census?units=cen_ws_memory,cen_ws_al_east&sort=needsReviewFirst&filter=criticalOnly&view=list
```

In 2B-0, this shape is wired but the Census page still reads its filter state from in-memory `FacilitySelection` (demo behavior). 2B-FAC-R lifts the state into the URL.

## Implementation

### Files Changed / Created

> Spelled out for 2B-0 only. Subsequent subsets get their own per-subset spec amendments. **Asterisked** files are touched by both modes' builds — every change must be tested in both `BUILD_MODE=demo` and `BUILD_MODE=live`.

| File | Change | Description |
|------|--------|-------------|
| `lib/main.dart` * | Modified | Boots in live mode if `BUILD_MODE=live`; constructs `AuthService` + `ApiClient` + `LiveFacilityRepository`; hands off to `AppShell` |
| `lib/facility_demo/main_demo.dart` * | Modified | Boots in demo mode; constructs `MockAuthService` + `FacilityMockData`; preserves `?w=` viewport override; hands off to `AppShell` |
| `lib/shell/app_shell.dart` * | New | Shared widget: theme + GoRouter + AuthGate; takes injected `AuthServiceInterface` + `FacilityRepository` + optional `ApiClient` |
| `lib/state/app_router.dart` * | New | GoRouter config — route table per §Scope; live-only routes hidden via redirect guard when `BuildMode.current == BuildMode.demo` |
| `lib/state/app_state.dart` * | New | InheritedNotifier exposing the injected dependencies + `BuildMode.current` to descendant widgets |
| `lib/state/build_mode.dart` * | New | `BuildMode` enum + `fromDartDefine()` reader |
| `lib/auth/auth_service_interface.dart` | New | Abstract contract per §Interfaces |
| `lib/auth/auth_service.dart` | Moved + Modified | From `lib/services/auth_service.dart`. Adds MFA challenge, forgot-password, full claim extraction. Implements `AuthServiceInterface` |
| `lib/auth/mock_auth_service.dart` | Moved + Modified | From `lib/facility_demo/services/mock_facility_auth.dart`. Renamed `FacilityMockAuthService` → `MockAuthService`. Implements `AuthServiceInterface` |
| `lib/auth/user_claims.dart` | New | Full custom-claim model + parser (clientId, role, facilities, censuses, mfa_enrolled) |
| `lib/auth/mfa_challenge_handler.dart` | New | TOTP setup + verify (handles `CognitoUserMfaRequiredException` continuation) |
| `lib/auth/forgot_password_handler.dart` | New | Email-code reset flow |
| `lib/api/api_client.dart` | New | Single HTTP gateway per §Interfaces. Retries (1 attempt for 5xx); refresh-on-expiry; envelope decode |
| `lib/api/api_models.dart` | New | Request / response shapes mirroring 2A-RD / 2A-AA / 2A-DL response specs |
| `lib/api/api_exception.dart` | New | Typed exceptions per L7 |
| `lib/api/pagination.dart` | New | Cursor encode/decode helper for paginated reads |
| `lib/data/facility_repository.dart` | New | Abstract `FacilityRepository` interface per §Interfaces |
| `lib/data/live_facility_repository.dart` | New | `ApiClient`-backed implementation. **Mostly stubbed in 2B-0**; methods either throw `UnimplementedError` or assemble best-effort responses from the deployed 2A-RD endpoints. 2B-FAC-R fills in the real wiring per screen |
| `lib/facility_demo/data/facility_mock_data.dart` | Modified | Add `implements FacilityRepository`. Convert sync methods to `Future<...>` returning `Future.value(...)`. No semantic change |
| `lib/models/user.dart` | Modified | Expand `UserRole` enum to 8-customer + 2-internal model from Phase 0A-rev. V1 UI still treats them uniformly per umbrella L13 |
| `lib/screens/login_screen.dart` | Modified | Strip the legacy walker/caregiver signup branch ([user.dart:21](../../lib/models/user.dart#L21) two-role choice removed). Add MFA challenge step. Add Forgot Password link |
| `lib/facility_demo/screens/facility_login_screen.dart` | Modified | Minor: confirm still uses `MockAuthService` (renamed); no UX change |
| `lib/dev/me_smoke_screen.dart` | New | Renders raw `getMe()` payload as JSON. Live-mode only. **Removed in 2B-FAC-R** per L10 |
| `pubspec.yaml` | Modified | Add `go_router`, `url_strategy` |
| `web/index.html` | Modified | Add `<script>setPathUrlStrategy()` if not auto-applied; otherwise unchanged |
| `tools/deploy-demo.sh` | Modified | Add `--dart-define=BUILD_MODE=demo`. **Pre-DNS-cutover**: retain `--base-href /facilitydemo/`. **Post-cutover**: drop the flag |
| `tools/deploy-portal.sh` | New | Build + sync to S3 + invalidate CloudFront. Manual deploy script per L15 (CI/CD is 3B) |
| `infra/lib/stacks/portal-hosting-stack.ts` | New | `GoSteady-Dev-PortalHosting` CDK stack — S3 + CloudFront + OAC + ACM + WAF baseline (see §Hosting and §Infrastructure Changes) |
| `infra/bin/gosteady.ts` | Modified | Instantiate the new `PortalHostingStack` with the `dev` env config |
| `infra/lib/config.ts` | Modified | Add `https://dev.portal.gosteady.co` to `apiCorsAllowedOrigins.dev` |
| `infra/lib/stacks/api-stack.ts` (or similar) | Modified | None expected — `apiCorsAllowedOrigins` config flows through automatically per 2A-0 L9. Listed here as the deploy target |
| `docs/specs/phase-2b-portal-integration.md` | Modified (in this PR) | Update line ~197 + ~458 to remove "drop `lib/facility_demo/`" language; link to this dedicated spec; carry forward approach-C lock-in |
| `docs/specs/ARCHITECTURE.md` | Modified (in this PR) | §12 Phase 2B: expand from flat 🔲 to subset table mirroring 2A's pattern |
| `docs/specs/phase-3a-portal-hosting.md` | Modified (follow-up) | Narrow scope: production hostname + WAF/CSP tightening + observability + multi-region. Reference 2B-0 for the dev-tier hosting foundation |

### Dependencies

**Prior phases that must be live before this phase deploys (or in this case, before smoke testing works):**

- Phase 0A-rev: Cognito User Pool with custom claims + Pre-Token Lambda V2 ✅
- Phase 1.5: KMS keys (consumed transitively by API handlers) ✅
- Phase 1.6: Powertools + X-Ray (consumed by API stub) ✅
- Phase 1.7: Audit pipeline (smoke screen emits `auth.session.read` per 2A-0) ✅
- Phase 2A-0: API Gateway HTTP API + JWT authorizer + `/me` stub endpoint ✅
- (Optional for 2B-0 smoke; required for 2B-FAC-R) Phase 2A-RD: patient read endpoints ✅

**External setup (operator action, before T1):**

- A test user in Cognito pool `us-east-1_ZHbhl19tQ` with role `facility_admin` + `mfa_enrolled=true` + RoleAssignments row scoped to a real facility + at least one patient with activity (reuse `pt_bench_98` fixture from 2A-RD validation)
- Local `flutter` SDK ≥ 3.16.0 + Chrome (for `flutter run -d chrome`)
- AWS CLI configured with credentials in the dev account (for CDK + the `deploy-portal.sh` script)

**External setup (operator action, before T12 → T17 — the hosting deploys):**

- Access to Squarespace's DNS Settings panel for `gosteady.co` (for adding the ACM validation CNAMEs and the `dev.portal` CNAME)
- ~30 min walltime for the first CDK deploy (most spent on ACM cert validation + CloudFront distribution propagation)
- Coordination check with parallel cloud session: confirm no in-flight CDK deploy on `GoSteady-Dev-Api` since we'll be deploying it once with the new CORS origin

### Configuration

| Flag | Type | Used By | Values |
|---|---|---|---|
| `BUILD_MODE` | `--dart-define` | Both entry points | `demo` (default) \| `live` |
| `API_BASE_URL` | `--dart-define` | Live mode `ApiClient` | dev: `https://<api-gw-id>.execute-api.us-east-1.amazonaws.com` ; prod (Phase 3A): `/api/v1` (same-origin reverse-proxy) |
| `POLL_CADENCE_MS` | `--dart-define` | Live mode Census polling (2B-FAC-R deliverable; declared here for the spec contract) | default `60000` |

## Testing

### Test Scenarios

| # | Scenario | Method | Expected Result | Status |
|---|----------|--------|-----------------|--------|
| T1 | Live-mode sign-in (no MFA) | `flutter run -d chrome -t lib/main.dart --dart-define=BUILD_MODE=live --dart-define=API_BASE_URL=<dev-api-url>` → sign in as a `caregiver` test user (no MFA required) | LoginScreen → 200 OK from Cognito → `/dev/me` route renders the JWT claims as JSON, including `custom:clientId`, `custom:role: caregiver`, facilities + censuses lists | Pending |
| T2 | Live-mode sign-in (MFA-required role) | Same as T1 but sign in as a `facility_admin` test user with `mfa_enrolled=true` | LoginScreen → 200 + MFA challenge → `/mfa-verify` route prompts for TOTP code → on correct code, route lands at `/dev/me` with full claims | Pending |
| T3 | Live-mode error envelope decoding | Use browser devtools to corrupt the Authorization header before clicking around | API call surfaces `ApiException(code: 'UNAUTHENTICATED', httpStatus: 401)`; UI shows the message; user is forced to sign-out + re-sign-in | Pending |
| T4 | Live-mode token refresh | Force-expire the ID token via SDK; click around | Next API call triggers refresh; success → user sees no disruption. Failed refresh → forced sign-out | Pending |
| T5 | Live-mode forgot-password | LoginScreen → "Forgot password?" link → enter email → receive code via Cognito → enter code + new password | New password works; user can sign in immediately | Pending |
| T6 | Deep-link routing | Open Chrome at `/patients/pt_bench_98` while signed out | Redirect to `/sign-in`; after sign-in, lands at `/patients/pt_bench_98` | Pending |
| T7 | Demo-mode build smoke | `flutter run -d chrome -t lib/facility_demo/main_demo.dart --dart-define=BUILD_MODE=demo` | Demo loads identically to today's `gosteady.co/facilitydemo`. Sign-in screen → click "Sign in to demo" → Census renders all 10 mock patients across both facilities. Open patient detail. `/dev/me` route returns 404. Forgot-password / MFA routes return 404 | Pending |
| T8 | Demo URL `?w=` override still works | Demo build + URL `?w=390` | Layout collapses to phone width inside grey device frame, same as today | Pending |
| T9 | `tools/deploy-demo.sh` builds clean | Run script after 2B-0 changes | Build artifact in `GoSteadyWeb/facilitydemo/` is byte-equivalent (or visually equivalent) to today's demo deploy; Netlify pushes; URL still works | Pending |
| T10 | Build flag default = demo | `flutter run -d chrome -t lib/main.dart` (no `--dart-define`) | Boots in demo mode (defensive default per L2). Logs a warning to console: `BUILD_MODE not set — defaulting to demo` | Pending |
| T11 | Both builds compile cross-version | Run `flutter build web` for both entries before any commit | Both succeed; no breakage in either | Pending (developer discipline; CI gate is Phase 3B) |
| T12 | CDK deploy of `GoSteady-Dev-PortalHosting` succeeds in one pass | Add validation CNAMEs at Squarespace per Option A pre-deploy; run `cdk deploy GoSteady-Dev-PortalHosting` | Stack reaches CREATE_COMPLETE; ACM cert validates; CloudFront distribution status `Deployed`; 3 outputs surfaced | Pending |
| T13 | First portal deploy lands at `dev.portal.gosteady.co` | After T12 + Squarespace CNAME for `dev.portal`: run `./tools/deploy-portal.sh` from a feature branch with a stub `lib/main.dart` | `https://dev.portal.gosteady.co/` returns 200 + serves Flutter bundle; sign-in screen renders; cert is valid (no browser warning) | Pending |
| T14 | API call from real domain works (CORS smoke) | After T1's local test passes: re-run the same sign-in flow at `https://dev.portal.gosteady.co/dev/me` (instead of `localhost:8080`) | Sign-in succeeds; `/dev/me` route returns 200 with full claims; no CORS preflight failure in browser devtools | Pending |
| T15 | SPA deep link works through CloudFront | Open `https://dev.portal.gosteady.co/patients/pt_bench_98` in a fresh tab | CloudFront returns `index.html` (200, not 404); Flutter app loads + routes to PatientDetailPage; redirect to `/sign-in` if not authenticated, then back after sign-in (per T6 + the SPA 404 rewrite) | Pending |
| T16 | WAF rate limit fires correctly | Send >2000 requests in 5 min from one IP via `ab` or similar | Subsequent requests get 403 from CloudFront with WAF marker | Pending (synthetic load) |
| T17 | Deploy invalidates CloudFront cache | Run `./tools/deploy-portal.sh`; check `index.html` timestamp before + after | Within 60 s of script completion, browser fetches the new bundle (verifiable via Network tab `etag` change) | Pending |

### Verification Commands

```bash
# In ~/Documents/gosteady-portal-2b/
cd ~/Documents/gosteady-portal-2b

# T1 — Live mode dev sign-in
flutter run -d chrome -t lib/main.dart \
  --dart-define=BUILD_MODE=live \
  --dart-define=API_BASE_URL=$(aws cloudformation describe-stacks --stack-name GoSteady-Dev-Api --query 'Stacks[0].Outputs[?OutputKey==`ApiUrl`].OutputValue' --output text)

# T7 — Demo mode
flutter run -d chrome -t lib/facility_demo/main_demo.dart \
  --dart-define=BUILD_MODE=demo

# T11 — Both builds compile
flutter build web -t lib/main.dart --dart-define=BUILD_MODE=live --dart-define=API_BASE_URL=stub
flutter build web -t lib/facility_demo/main_demo.dart --dart-define=BUILD_MODE=demo

# T9 — Marketing demo deploy still works (verify in a scratch checkout, do NOT push)
WEB_REPO=/tmp/GoSteadyWeb-scratch ./tools/deploy-demo.sh --skip-push
```

## Deployment

### Deploy Commands

**One-time setup (CDK hosting stack + DNS records):**

```bash
# 1. Pre-create the ACM cert + get validation CNAMEs (Option A pre-deploy)
cd ~/Documents/gosteady-portal/infra        # or worktree path

# Synth to see what'll deploy
cdk synth GoSteady-Dev-PortalHosting

# Deploy the stack — it'll hang on the cert resource while waiting for DNS validation
cdk deploy GoSteady-Dev-PortalHosting

# 2. In a second terminal, find the validation CNAMEs:
aws acm list-certificates --region us-east-1 --query 'CertificateSummaryList[?DomainName==`dev.portal.gosteady.co`]'
aws acm describe-certificate --region us-east-1 --certificate-arn <arn> \
  --query 'Certificate.DomainValidationOptions[].ResourceRecord'

# 3. Add the validation CNAMEs at Squarespace DNS Settings → Custom records
#    (Name + Data fields from the output above; type CNAME; TTL 1 hr)

# 4. CDK deploy resumes once validation completes (~5-15 min)

# 5. Get the CloudFront distribution domain from CDK outputs:
aws cloudformation describe-stacks --stack-name GoSteady-Dev-PortalHosting \
  --query 'Stacks[0].Outputs[?OutputKey==`DistributionDomainName`].OutputValue' --output text
# e.g., d123abc456def.cloudfront.net

# 6. Add CNAME at Squarespace: name=dev.portal, type=CNAME, data=<above>, TTL=1hr

# 7. Add the new origin to API Gateway CORS allow list
#    Edit infra/lib/config.ts → add 'https://dev.portal.gosteady.co' to apiCorsAllowedOrigins.dev
cdk deploy GoSteady-Dev-Api

# 8. Verify
curl -I https://dev.portal.gosteady.co/   # 403 from S3 before any deploy is fine
```

**Per-commit portal deploy:**

```bash
cd ~/Documents/gosteady-portal-2b   # or whichever portal worktree
./tools/deploy-portal.sh             # build + sync + invalidate
./tools/deploy-portal.sh --build-only  # build only, no AWS
```

**Local development against the dev API (no deploy needed):**

```bash
# Live mode (real Cognito + real API at localhost:8080)
flutter run -d chrome -t lib/main.dart \
  --dart-define=BUILD_MODE=live \
  --dart-define=API_BASE_URL=https://<dev-api-gw-id>.execute-api.us-east-1.amazonaws.com

# Demo mode (mock auth + mock data — identical to marketing demo)
flutter run -d chrome -t lib/facility_demo/main_demo.dart \
  --dart-define=BUILD_MODE=demo
```

**Marketing demo deploy (unchanged from today):**

```bash
./tools/deploy-demo.sh                # build + commit + push to GoSteadyWeb (Netlify)
./tools/deploy-demo.sh --skip-push    # build + commit, hold the push
./tools/deploy-demo.sh --build-only   # build only, no GoSteadyWeb changes
```

### Rollback Plan

- **Frontend code changes** live in `feature/2b-portal-integration` worktree. Rollback = `git revert` the merge commit
- **Portal deploys to `dev.portal.gosteady.co`** roll back by re-running `tools/deploy-portal.sh` from an earlier commit (S3 bucket versioning is enabled as belt-and-suspenders for accidental deletes)
- **Marketing demo deploy** rolls back independently via `git revert` in `GoSteadyWeb` repo + push (Netlify auto-redeploys)
- **CDK hosting stack** rolls back via `cdk destroy GoSteady-Dev-PortalHosting`. **Caveat:** CloudFront distributions take ~15-20 min to disable + delete; the bucket can't be deleted while non-empty (script either empties it first or deletes after CF disable). Better practice: roll forward by fixing the stack rather than destroying. ACM cert can't be re-validated without re-adding the same CNAMEs (or new ones; AWS rotates)
- **CORS allow-list change** on `GoSteady-Dev-Api` rolls back via `git revert` of the one-line `infra/lib/config.ts` edit + `cdk deploy GoSteady-Dev-Api`
- No DDB / Lambda / IoT changes to undo

## Decisions Log

| # | Decision | Alternatives Considered | Why This Choice |
|---|----------|------------------------|-----------------|
| D1 | Two entry points (`main.dart` + `main_demo.dart`) share a `AppShell`; data + auth injected via constructor | (a) Single entry with runtime branching on `BUILD_MODE`; (b) Physical copy of `lib/facility_demo/` to `lib/portal/`, evolve copy | (a) bakes dead code paths into both builds (the `?w=` viewport override is demo-only; live build would carry it unused). (b) immediately forks visual responsibility for the marketing demo, requires cherry-picking visual fixes between trees — and the demo is still being updated (2026-05-18 added the tile/list view toggle). Two thin entry points preserves marketing-demo invariance with zero code-sharing penalty. **Lifted from approach C proposal 2026-05-24** |
| D2 | `BUILD_MODE` enum over boolean `USE_MOCKS` | Boolean `USE_MOCKS=1` was the umbrella's implicit flag | Enum decouples "data source choice" from "deployment context." Extensible to `staging` or `internal` modes later without flag overload. Default value (`demo`) is the safer no-op for a forgetful dev run |
| D3 | `FacilityRepository` interface (abstract), not a Repository base class | Base class with `@protected` HTTP helpers + subclasses for mock and live | Mock impl pre-dates this spec and has no HTTP concerns; making it inherit from an HTTP-aware base is awkward. Interface keeps both impls fully independent |
| D4 | Convert `FacilityMockData` sync methods to `Future<...>` | Add a parallel async surface alongside the sync one | Two surfaces means screens have to know which to call. Promotion to `Future.value(...)` is a one-liner per method on the mock side; screens add `await` once. Cleaner |
| D5 | Demo URL: `gosteady.co/facilitydemo` → `facilitydemo.gosteady.co` (subdomain) | Keep subpath; live with `--base-href` mismatch between demo and live builds | Subdomain symmetry with `portal.gosteady.co`; eliminates the `--base-href` per-build divergence; decouples demo redeploys from marketing-site redeploys. Cost low: one DNS record + 301 in `_redirects`. **User-confirmed 2026-05-24** |
| D6 | Smoke screen at `/dev/me`, live-mode-only, removed in 2B-FAC-R | Keep the smoke screen forever as a diagnostic; expose to demo mode | Mirrors 2A-0's stub-endpoint posture — exists to validate the pipeline, dies after the first real screen wires successfully. Demo mode has no real JWTs to mirror — would be misleading |
| D7 | `GoRouter` over `auto_route` or hand-rolled `Navigator 2.0` | `auto_route` (code-gen heavy); raw Navigator 2.0 | `go_router` is Flutter team's blessed router for declarative + URL-state routing; deep-linking + redirect guards are first-class. `auto_route` is more powerful but code-gen overhead doesn't pay back at this scale |
| D8 | Live mode default: refuse to boot if `API_BASE_URL` is unset | Fall back to demo mode if `API_BASE_URL` is unset | Silent fallback masks a missing config; an explicit failure with a clear message is friendlier to a forgetting-the-flag developer |
| D9 | DNS cutover to `facilitydemo.gosteady.co` is a follow-up task, not in 2B-0 | Bundle cutover with 2B-0 ship | Separate ops concern; can happen before, during, or after 2B-0. Spec captures the migration plan so it's not lost. Sequencing detail in [§Scope `tools/deploy-demo.sh`](#in-scope) explains the two-phase rollout |
| D10 | `lib/screens/dashboard_screen.dart` (legacy D2C dashboard) untouched in 2B-0 | Refactor to consume `FacilityRepository` too | The legacy D2C dashboard's mock layer is a separate class (`MockDataSource`) and serves a different screen tree. Pulling it into the 2B-0 abstraction muddles scope. 2B-D2C subset handles it |
| D11 | **Pull minimum-viable hosting into 2B-0** rather than defer all of it to Phase 3A | Defer entirely to 3A per the original umbrella scope; or split out a 2B-0.5 / 3A-min phase between 2B-0 and 2B-FAC-R | Real-domain deploy from day one means every 2B subset gets tested end-to-end as it ships (CORS, CSP, SPA routing, CDN caching) — issues surface incrementally rather than all-at-launch. CDK addition is bounded (~300-500 lines in one new stack); 3A keeps the production polish (prod hostname, tightened WAF + CSP, observability dashboards, multi-region). **User direction 2026-05-24** ("violates best practice of testing end to end throughout development if we can") |
| D12 | **Squarespace DNS, not Route53.** Confirmed by user 2026-05-24 — `gosteady.co` is registered + DNS-authoritative at Squarespace; existing custom records point traffic at Netlify for the marketing site. New subdomains added at Squarespace as CNAME records | Migrate DNS to Route53 first | Squarespace DNS supports custom CNAMEs to external hosts (proven by the existing `www → apex-loadbalancer.netlify.com` record). DNS migration is real ops cost (NS-record changes + ≤48 hr propagation + nothing-can-be-broken-during-cutover) and buys little — the only real value of Route53 would be CDK-managed records, which we forgo in exchange for keeping the marketing site's DNS untouched |
| D13 | **Asymmetric hosting** — demo on Netlify (existing), portal on S3+CloudFront (new). Both subdomains added at Squarespace DNS | Move demo to S3+CloudFront too for symmetry; keep both on Netlify | The demo doesn't benefit from the things S3+CloudFront adds (WAF, custom CSP, cache invalidation discipline) — Netlify handles its needs adequately. The portal genuinely needs them. Moving the demo would be one-time work with no clear payoff. **User direction 2026-05-24** |
| D14 | **`AWSManagedRulesAmazonIpReputationList` deferred to Phase 3A** | Include in 2B-0 baseline WAF | The IP reputation list occasionally false-positives on legitimate users (corporate-NAT IPs, tor / shared-vpn endpoints). For a dev-tier URL with a small known user set, false-positives matter more than the marginal protection. 3A makes the prod call when real users are involved |
| D15 | **`deploy-portal.sh` is brute-force manual** (sync + `/*` invalidation) | Wait for 3B CI/CD automation; or implement diff-based invalidation | The script is intentionally crude — its job is to make "ship a 2B change" a 30-second mental cost so we actually use real-domain testing. CI/CD is Phase 3B; until then, a manual script that always works is better than an elaborate one that sometimes doesn't |

## Open Questions

- [x] ~~**Q1 — `facilitydemo.gosteady.co` hosting target.**~~ **Resolved 2026-05-24 (D13):** demo stays on Netlify; configure Netlify with the new subdomain as a custom-domain alias on the existing `GoSteadyWeb` site. Operator action (post-2B-0 follow-up): add the domain on Netlify + add the CNAME at Squarespace DNS + 301 from old subpath
- [ ] **Q2 — `LiveFacilityRepository` granularity in 2B-0.** Does this spec ship the full method set as `UnimplementedError` stubs (every method exists, ready for 2B-FAC-R to fill), or only the `getMe()`-equivalent + a couple of read paths? **Recommendation:** full stubs — costs ~50 LOC, gives 2B-FAC-R a per-method shipping target without re-litigating the interface. Decide during draft review
- [ ] **Q3 — MFA enrollment UX visual design.** Per §Out of Scope, the route shell ships but the visual flow (QR code rendering, 6-digit verify form, recovery codes) needs design before T2 + T8 in this spec can run end-to-end with an MFA-required role. Open: does the facility_admin test user need to enroll inside the portal, or do we cheat by enrolling them via Cognito Admin Console one time for smoke validation? **Recommendation:** enroll via Admin Console for 2B-0 smoke (one-time, on-the-test-user); ship the in-portal enrollment flow in 2B-0 follow-up or 2B-POL
- [ ] **Q4 — Smoke screen content in demo mode.** Per L10 the `/dev/me` route is hidden in demo mode (returns 404). Could instead render a "demo mode active" placeholder that exposes the build-mode flag and mock claims. **Recommendation:** keep it 404 — demo investors should never land on a dev affordance. Decide on draft review
- [ ] **Q5 — Order of operations: do we update the umbrella spec + ARCHITECTURE.md §12 in this same PR, or as a follow-up?** **Recommendation:** same PR — the umbrella's line ~197 / ~458 contradiction is a documentation foot-gun that points future readers backward. Fix it where it's read. (Both updates landed in this same drafting session 2026-05-24; close on initial review)
- [x] ~~**Q6 — Coordination with parallel cloud session on `infra/` edits.**~~ **Updated 2026-05-24:** 2A-UM-P is deployed (commit `e5ea6e6` — 27/27 smoke pass). Cloud session has moved to Phase 1C-slim (behavioral-detector scaffold). Remaining collision surface: (a) the new `portal-hosting-stack.ts` lives in its own file (no overlap with 1C-slim Lambda code); (b) `infra/lib/config.ts` CORS edit is one specific line, low conflict risk with 1C-slim's likely additions (new Lambda config + EventBridge schedule). Recommended deploy ordering: (a) let any 1C-slim merge land first; (b) rebase 2B-0 worktree on top; (c) push hosting changes
- [ ] **Q7 — Pre-deploy ACM validation operator step ergonomics.** Option A (`cdk synth` first, find validation CNAMEs from synth output, add them at Squarespace, then `cdk deploy`) requires the validation CNAMEs to be discoverable from synth — they are NOT (ACM creates them only during the deploy). Option B (deploy hangs, find them via `aws acm describe-certificate`, add them, deploy resumes) is what the spec actually documents. Verify Option B works smoothly in T12; if it's brittle, consider provisioning the cert as a separate one-off `cdk deploy` stack that hosts only the cert, ahead of the main hosting deploy

## Changelog

| Date | Author | Change |
|------|--------|--------|
| 2026-05-24 | Jace + Claude session | Initial draft. Captures approach-C (evolve demo in place) + `facilitydemo.gosteady.co` subdomain decisions made in the 2B-0 planning conversation 2026-05-24 |
| 2026-05-24 | Jace + Claude session | Pulled minimum-viable hosting into 2B-0 per user direction. Added `GoSteady-Dev-PortalHosting` CDK stack (S3 + CloudFront + OAC + ACM + baseline WAF), `tools/deploy-portal.sh`, `dev.portal.gosteady.co` URL, Squarespace DNS lock-ins (L16 / L17), operator-action prereqs for ACM cert validation, T12–T17 acceptance scenarios, decisions D11–D15 |

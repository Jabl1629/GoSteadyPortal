# Phase 3A — Portal Hosting (sketch)

## Overview
- **Phase**: 3A
- **Status**: 🔲 Planned (this is a sketch — depth comes when 2B-FAC-R approaches production)
- **Branch**: TBD
- **Date Started**: TBD
- **Date Completed**: TBD

Stands up the production hosting story for the unified portal: S3 bucket for Flutter web build artifacts → CloudFront distribution → WAF web ACL → ACM cert at `portal.gosteady.co`. Also lands the CloudFront-fronted custom domain for the API (`api.gosteady.co`) — and **finally enables WAF on the API**, which 2A-0 Q7 deferred specifically because WAFv2 can't associate with HTTP API v2 stages directly. Phase 3A's CloudFront-fronts-both pattern solves it.

**This sketch's purpose:** lock in the **2B-anticipating decisions** (CSP shape, custom-domain CORS, security headers, environment promotion) so [phase-2b-portal-integration.md](phase-2b-portal-integration.md) doesn't pick patterns that need rework when 3A lands. Full depth comes when 2B-FAC-R nears production.

**Dependency map:**
- 2B-0 + 2B-FAC-R must be substantively shippable (the bundle being hosted needs to do something real)
- Phase 1.5 multi-account separation should be in place before prod 3A (per ARCH §12)
- Phase 1.7 audit log Object Lock + compliance-reader trust policy (prod hardening — deferred per 1.7 D12)

---

## Locked-In Requirements (provisional — sketch level)

| # | Requirement | Decided In | Rationale |
|---|-------------|-----------|-----------|
| L1 | **Same origin for portal + API:** `portal.gosteady.co` serves the Flutter bundle; `portal.gosteady.co/api/*` reverse-proxies via CloudFront → API Gateway. **Or** sibling subdomains: `portal.gosteady.co` + `api.gosteady.co`. Both options eliminate CORS issues post-prod | This sketch — Q1 | Same-origin is the cleanest security posture; CSP becomes simpler; cookies (if Q2 in 2B chooses HttpOnly) work without `SameSite=None` |
| L2 | CloudFront in front of BOTH S3 (portal bundle) and API Gateway HTTP API. WAF associates with the CloudFront distribution, protecting both — closes 2A-0 Q7 | 2A-0 Q7 explicit deferral | The only way to get WAF on HTTP API v2 traffic without rebuilding as REST API v1 |
| L3 | OAC (Origin Access Control) for S3, not OAI — OAI is deprecated | Standard | AWS-recommended pattern as of 2023+ |
| L4 | Security headers via CloudFront Response Headers Policy: HSTS (`max-age=31536000; includeSubDomains; preload`), CSP (see §CSP design), X-Frame-Options DENY, X-Content-Type-Options nosniff, Referrer-Policy `strict-origin-when-cross-origin`, Permissions-Policy locking down geolocation / camera / microphone | This sketch | Mandatory baseline for a healthcare-adjacent web app; WCAG-uninvolved but security-posture-defining |
| L5 | SPA fallback: CloudFront error-page rewrite — 404 on a path that isn't an S3 object → return `/index.html` with 200. Lets Flutter's GoRouter handle the route client-side | Standard for SPA hosting | Without it, a refresh on `/patients/pat_abc` returns 404 from S3 |
| L6 | ACM cert in `us-east-1` (CloudFront requirement) for `*.gosteady.co` covering both portal + api subdomains | AWS constraint | ACM-for-CloudFront must be in us-east-1 regardless of where the origin lives |
| L7 | **CSP design — strict but workable for Flutter Web:** `default-src 'self'; script-src 'self' 'wasm-unsafe-eval'; style-src 'self' 'unsafe-inline'; connect-src 'self' https://cognito-idp.us-east-1.amazonaws.com https://api.gosteady.co; img-src 'self' data:; font-src 'self' data:; object-src 'none'; base-uri 'self'; form-action 'self'; frame-ancestors 'none';` | This sketch — Q3 | Flutter Web requires `wasm-unsafe-eval` for the CanvasKit renderer; `style-src 'unsafe-inline'` for runtime style injection. Connect-src whitelist Cognito + API. **2B implication:** any third-party analytics / Sentry would need to be added explicitly here |
| L8 | CloudFront price class: `PriceClass_100` (US/CA/EU only) | ARCH §12 explicit | Cost; covers MVP geography |
| L9 | Cache invalidation on each Flutter build deploy: `aws cloudfront create-invalidation --paths '/*'`. Eventually graduate to versioned-asset path-based invalidation (cheaper) | Standard | Full invalidation is $0.005 each — negligible at MVP deploy cadence |
| L10 | Environment promotion: `dev.portal.gosteady.co` (existing dev API Gateway) → `portal.gosteady.co` (prod, multi-account-separated) | ARCH §12 multi-account plan | Cleanest model; matches Phase 1.5 multi-account when it lands |
| L11 | Build artifacts deployed via CI (Phase 3B). Pre-3B interim: `tools/deploy-portal.sh` mirroring the existing `tools/deploy-demo.sh` pattern — `flutter build web` → `aws s3 sync` to a private bucket + cache-invalidate | Phase 3B parallel work | Manual deploy is fine pre-customer; CI is Phase 3B |
| L12 | WAF Managed Rules: `AWSManagedRulesCommonRuleSet` + `AWSManagedRulesAmazonIpReputationList` + rate-limit rule (2000 / 5 min / IP — same as 2A-0's deferred WAF config) | 2A-0 L8 config carried forward | Baseline; bot-control deferred per 2A-0 D6 |

---

## 2B-anticipating decisions (the actual purpose of this sketch)

These are the things 2B implementation needs to know **now** so the code doesn't paint itself into a corner.

### Same-origin vs cross-origin for API

**Decision:** ✅ **Same origin** — `portal.gosteady.co/api/*` reverse-proxied through CloudFront to API Gateway. Not sibling subdomains.

**Why this matters for 2B:**
- `ApiClient` `baseUrl` becomes `/api/v1` (relative path), not an absolute URL. Build flag `API_BASE_URL` becomes optional — defaults to relative. Dev still uses absolute (`http://localhost:8000/api/v1` or the dev API Gateway URL); prod uses relative
- No CORS preflight in production — same origin. Dev still needs CORS (cross-port localhost is cross-origin)
- 2B Q2 (token storage) — same-origin makes HttpOnly cookies viable as a future hardening without breaking same-site requirements
- 2A-0's `apiCorsAllowedOrigins` config gets simplified: dev keeps `localhost:8080` + dev API Gateway URL; prod can drop CORS entirely once `portal.gosteady.co` proxies to the API at the same origin

### CSP for Flutter Web

**Decision:** ✅ L7 above as the V1 baseline. Locks 2B out of:
- Inline `<script>` tags (Flutter Web doesn't emit any; safe)
- `eval()` (CanvasKit's `wasm-unsafe-eval` allowed; standard `eval()` blocked)
- Third-party-hosted scripts (any analytics / error reporting needs to be self-hosted OR added explicitly to `script-src`)

**2B implication:** Q9 in 2B (loading / empty / error states) — if we add Sentry-style telemetry, we add `https://o<id>.ingest.sentry.io` to `connect-src`. Self-hosted reporting endpoint avoids the CSP whitelist sprawl.

### Cookie posture (future-proofing)

If 2B Q2 ever moves token storage to HttpOnly cookies (the more secure path documented in Phase 2B Q2 lean), same-origin (L1) keeps the cookie posture simple: `Secure; HttpOnly; SameSite=Strict`. No need for `SameSite=None` + 3rd-party-cookie concerns.

### Internal-tier portal — does it share the same hostname?

**Decision per [phase-2b-portal-integration.md](phase-2b-portal-integration.md) L1:** Yes. Single URL for everyone; role-conditional UI in the same bundle. Internal users sign in at `portal.gosteady.co`, same as customers. The pre-prod hardening item in 2A-0 Q8 (Option B: third Cognito App Client for internal-web) doesn't change the hostname — only swaps which Cognito client the internal user authenticates through.

### Dev vs prod build differentiation

| Concern | Dev | Prod |
|---|---|---|
| `API_BASE_URL` | Dev API Gateway URL (`https://<id>.execute-api.us-east-1.amazonaws.com`) | `/api/v1` (relative) |
| Cognito client | `1q9l9ujtsomf3ugq2tnqvdg6d7` (dev pool) | Different ID for prod pool (Phase 1.5 multi-account) |
| `DEBUG_VIEWPORT` | `1` (enabled for QA) | `0` (stripped per 2B L17) |
| Source maps | Included (for dev debugging) | Stripped (smaller bundle; harder to reverse-engineer) |
| Service Worker caching | Disabled (live-reload-friendly) | Enabled (offline-tolerant) |

---

## Out of Scope (Phase 3A sketch)

- **Full per-route CloudFront behavior tuning** (cache headers per Flutter asset type) — V1 ships with the Flutter defaults; tune if asset-load latency is an issue
- **CloudFront Functions / Lambda@Edge for header injection** — Response Headers Policy (L4) covers V1 needs; defer to V2 if dynamic headers needed
- **Geo-blocking** — out per 2A-0 D6
- **Multi-region failover for the API** — out; us-east-1 only at MVP
- **CDN-level A/B testing / feature flags** — out
- **Static analytics endpoint** — out; if added, lands as a behind-`/api/analytics` ingestion path
- **Phase 3B CI/CD** — separate sibling phase; 3A ships with manual deploy script

---

## Open Questions (sketch-level)

### Q1. Same-origin reverse-proxy vs sibling subdomains? (DECIDED at sketch level)
**Decision:** ✅ Same origin per L1.

### Q2. CSP `style-src` — `'unsafe-inline'` long-term, or migrate to nonces?
**Lean:** Accept `'unsafe-inline'` for V1 — Flutter Web's runtime style injection makes nonces non-trivial. Hardening item for post-V1 if a security review flags it.

### Q3. CloudFront origin selection — public S3 bucket OR private with OAC?
**Decision:** ✅ Private + OAC per L3. Public buckets are a foot-gun.

### Q4. Web Application Firewall — bot control opt-in for V1?
**Lean:** No per 2A-0 D6 (~$10/mo + per-request). Revisit if real bot traffic appears post-launch.

### Q5. Custom error pages (Flutter not loaded / network failure)?
**Lean:** Static fallback `index.html` only — if CloudFront can't reach S3 (extremely rare), serve a tiny "Service unavailable — please retry" stub. Standard 5xx handling.

### Q6. Deploy artifact versioning — overwrite or path-based?
**Lean:** Path-based (`/build/<git-sha>/`) with `index.html` pointing at the current sha. Enables zero-downtime swap + cheap rollback (just change the pointer).

---

## Changelog

| Date | Author | Change |
|------|--------|--------|
| 2026-05-23 | Jace + Claude (portal session) | Sketch-level spec written ahead of 2B implementation. Purpose: lock in the **2B-anticipating decisions** (same-origin reverse-proxy, CSP shape, build differentiation) so 2B code doesn't pick patterns that need rework when 3A lands. Full depth + smoke acceptance criteria come when 2B-FAC-R approaches production — likely as an in-place amendment to this sketch. |

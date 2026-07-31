# GoSteady D2C User Demo — Spec

> **Status:** Built (2026-06-29); caught up to the live app + redeployed (2026-07-31) | **Branch:** `feature/infra-scaffold` | **Owner:** Jace
> **Live URL (target):** https://gosteady.co/userdemo/

---

## 1. Purpose & audience

A self-contained Flutter web build that demonstrates the **direct-to-consumer
(household / Care Circle) product** — what a family member sees when monitoring
an at-home walker user. The consumer counterpart of the facility demo
([facility-demo.md](facility-demo.md), live at `gosteady.co/facilitydemo/`).

Shown to investors and prospective D2C partners (retail, GrandPad-style
bundles). Not connected to live AWS; mock data only.

**Primary message:** "GoSteady keeps a family connected to an aging parent's
daily activity — a warm, phone-first app with one-click access to today's
walks, trends, the Care Circle, and device health."

It re-uses the polished D2C screens that were built as design-review
wireframes (the `/d2c/preview` hub) and presents them as a real,
dashboard-first app behind a one-click sign-in — the same relationship the
facility demo has to the live facility portal.

---

## 2. Scope & non-goals

### In scope
- One-click mock sign-in → signed-in consumer app.
- **Activity** (dashboard): greeting + today's stats, two trend charts
  (active minutes + distance) under the shared Today / 7-day / 30-day zoom
  stack with tap-a-day drill-down (the day zoom superseded the old
  standalone "Today's walks" tile), care note, device health. Person-icon
  toggle flips between the walker-user POV and the caregiver/Admin POV live.
- **Coach ("Steady")**: the 4th-tab AI activity coach, mock-backed — seeded
  greeting + morning note, canned warm replies, "What Steady knows" memory
  screen with editable facts/goals, tone + SMS-teaser prefs. The walker-POV
  dashboard shows the coach-nudge card until the tab is first opened.
- **History**: 30/90-day trend view.
- **Care Team**: Admin view — roster, pending invites, walk-up access
  requests (approve/deny), member management, last-Admin guard.
- **Account**: settings, notification-preferences matrix, "who's accessed
  the data" audit log, device settings.
- Phone-first framing (renders in a phone-shaped frame by default).

### Demo-appeal data choices (2026-07-31)
The seed data is deliberately best-case — partners should see a healthy,
calm household, not an ops problem:
- **No open alerts** on the dashboard (the old seed showed a "Battery is
  getting low — 12%" warning card). Alerting capability still shows via
  Account → Notification preferences.
- **Healthy device everywhere**: battery 84% (sage, not warn-orange) +
  "Excellent" signal on both the dashboard device card and Device settings.
- The customer audit log's "acknowledged a low-battery alert" row became
  "updated notification preferences".

### Non-goals
- Real Cognito / SMS-OTP (mock auth only — partners don't sign up at a booth).
- The onboarding / QR walk-up / welcome-wizard flow (the demo opens
  *inside* the signed-in app; first-run screens stay out — they remain
  reachable in the dev `/d2c/preview` hub).
- Live data, push/SMS sends, billing, real QR generation.
- Multi-walker / multi-household (V1 D2C is 1 household = 1 walker).

---

## 3. Personas & seed data

Sourced from [d2c_mock_data.dart](../../lib/d2c/data/d2c_mock_data.dart) —
the **Davis household**:

| Person | Role | In demo |
|---|---|---|
| Susan Davis | Walker user (no separate copy needed) | The monitored parent; the demo opens in her POV |
| Sarah Davis | Daughter · Admin · the signed-in viewer | The caregiver POV (toggle) |
| Michael Davis | Son · Member (read-only) | Care Team roster |
| Karen Davis | Pending invite | Care Team |
| Tom Davis | Walk-up access request (grandson) | Care Team approve/deny |

Deterministic history + today's snapshot so the shapes look identical across
reloads and partner-to-partner demos.

---

## 4. Default point of view

Opens in **Susan's (walker-user) POV** — "your activity" framing — with the
dashboard's person-icon toggle live so the presenter can flip to the
caregiver/Admin view in one tap. Care Team is shown in the Admin view (the
solo walker-user-is-also-Admin case, per [d2c.md](d2c.md) L4).

---

## 5. Code organization

```
lib/d2c/
  main_userdemo.dart        # ← demo entry point (this build)
  d2c_preview.dart          # D2CDashboardPreview (reused; gained startAsWalkerUser)
  screens/                  # polished screens, reused verbatim
    d2c_dashboard_screen.dart
    d2c_history_screen.dart
    d2c_care_team_screen.dart
    d2c_coach_screen.dart   # Coach tab + memory screen (mock-backed hosts)
    d2c_account_screens.dart
  widgets/d2c_bottom_nav.dart
  data/d2c_mock_data.dart
  data/d2c_repository.dart  # D2CMockRepository — in-memory coach/care-circle state
```

`main_userdemo.dart` is a thin entry: a mock-auth gate + a `GoRouter` that
mounts the existing polished screens at their `/d2c/preview/*` paths (so the
screens' own cross-links and the shared bottom nav resolve unchanged) and
opens on the dashboard. **No screen code was modified** beyond an additive
`startAsWalkerUser` flag on `D2CDashboardPreview`.

### Relationship to the other D2C entry points
- `lib/main.dart` (facility) mounts the same screens under `/d2c/preview/*`
  as a **wireframe index** (dev design review).
- `lib/main_d2c.dart` is the **live** consumer app (Cognito D2C pool + API),
  deployed to `dev.portal.gosteady.co/d2c/`. Its signed-in tabs are the lean,
  API-backed hosts (history list, Care Team placeholder) — *not* the polished
  screens this demo ships.
- `lib/d2c/main_userdemo.dart` (this build) is the **public mock demo** of
  the polished surface.

---

## 6. Build & run

Run locally:
```bash
flutter run -d chrome -t lib/d2c/main_userdemo.dart
```

URL viewport overrides (the product is a mobile PWA, so the demo renders in
a phone frame by default):
```
?w=390    iPhone 14 / 13 Pro
?w=430    iPhone 15 Pro Max  (default)
?w=744    iPad mini portrait
?w=full   no frame — fill the window
```

---

## 7. Deploy

Mirrors the facility demo: a `/userdemo` subdirectory of the marketing site
(Netlify), built from the `GoSteadyWeb` repo.

```bash
./tools/deploy-d2c-demo.sh                # build + commit + push
./tools/deploy-d2c-demo.sh --skip-push    # build + commit, hold the push
./tools/deploy-d2c-demo.sh --build-only   # build only, no GoSteadyWeb changes
```

The script:
1. Runs `flutter build web -t lib/d2c/main_userdemo.dart --base-href /userdemo/`
   into `/tmp/portal-d2c-demo-out/` (keeps `build/` out of the iCloud-synced
   checkout).
2. Replaces `$WEB_REPO/userdemo/` (default `~/Documents/GoSteadyWeb/userdemo/`)
   with the new artifacts.
3. Stages only the `userdemo/` subtree, commits referencing the source SHA,
   and pushes `origin/main`. Netlify auto-deploys within ~30–60 s.

This is fully independent of the facility demo's `/facilitydemo` subtree and
of the live portal's S3 bucket — no shared-bucket footgun (cf. firmware coord
§C41.3 #3, the `deploy-portal.sh` `/d2c/*` clobber).

---

## 8. What this spec is NOT

- Not the live D2C product spec — see [d2c.md](d2c.md) (umbrella) and
  [d2c-phase1-walker-activation.md](d2c-phase1-walker-activation.md).
- Not a commitment to ship the polished screens as-is to production; the live
  app's polish pass is tracked separately. This demo is a sales/partner
  artifact built on the existing wireframe screens.

---

*See [d2c.md](d2c.md) for the consumer product umbrella and
[facility-demo.md](facility-demo.md) for the facility-side counterpart.*

# D2C Timezone Capture — automatic IANA tz at claim + self-heal on load

> **Date:** 2026-07-20 | **Status:** 🟢 **Shipped to dev + prod 2026-07-20** (Option B)
> **Related:** [`d2c-claim-binding.md`](d2c-claim-binding.md) (claim flow) · [`ARCHITECTURE.md`](ARCHITECTURE.md) §Activity Series (day-bucketing) + §Device Lifecycle · [`walker-alert-suppression`](../../) (the `custom:isWalkerUser` claim this reuses) · the 2026-07-20 "Today's walks" fix (`live_d2c_repository.dart`).

---

## 1. Problem

D2C patients are created with **no `timezone`** — [`d2c-claim/handler.py`](../../infra/lambda/d2c-claim/handler.py) builds the Patient row (§ patient creation) without one, so every consumer falls back to UTC (`_shared/patient_resolution.py` → `patient.get("timezone") or "UTC"`). The synthetic D2C facility is hardcoded `"UTC"`.

Consequences for any non-UTC user:
- **Day-bucketing is UTC.** `activity-processor._local_date(session_start, tz)` computes each session's `date` via `ZoneInfo(tz)`; with `tz="UTC"` a US evening session lands on the next calendar day. This skews the "Last 7 days" chart and (pre-fix) "Today's walks".
- **Behavioral-alert timing is UTC.** `behavioral-detector` fires `no_activity_today` / `below_typical_activity` at facility-local `09:00` / `22:00`; with a UTC facility those fire in the middle of the user's night.

The backend is **already built for a real IANA zone** (`ZoneInfo`, UTC fallback on missing/invalid) — the value is simply never captured. Surfaced 2026-07-20 when "Today's walks" showed a US walker last night's sessions on `GS0002000001` (patient tz `null`).

## 2. Approach

Capture the walker's **IANA timezone automatically from the browser** — `Intl.DateTimeFormat().resolvedOptions().timeZone` (e.g. `"America/Denver"`) — and store it on the Patient row. Two entry points:

1. **At claim (new patients + intentional rotations):** the D2C app sends `timezone` in the claim body; `d2c-claim` stamps it on the Patient **and** the synthetic facility.
2. **On dashboard load — self-heal (existing patients + first non-UTC user):** if the viewer **is the walker** (`custom:isWalkerUser`) **and** the stored patient tz is null/`UTC`, the app PATCHes it once. Heals existing patients the moment they next open the app, with no blind backfill (we can't know a past tz).

## 3. Decisions (locked)

| # | Decision | Why |
|---|----------|-----|
| D1 | **IANA names** (`America/Denver`), never fixed offsets. | Matches `ZoneInfo` (activity-processor) and survives DST. The browser `Intl` API returns IANA directly. |
| D2 | **Automatic browser detection, no user picker.** | Zero friction (the product ask). A settings-screen override is a future add (§5), not V1. |
| D3 | **Active claim sets unconditionally; passive load self-heals only when stored tz is null/`UTC`.** | The claimer is actively setting up from their current location → authoritative. The passive heal must never (a) let a **cross-tz family viewer** clobber the walker's zone — gated on `isWalkerUser` — or (b) flap on **travel** — an already-real zone is left alone (an elderly walker's "day" stays their home day). |
| D4 | Store on the **Patient** row (the day-bucketing source of truth) **and** set the synthetic **facility** tz at claim. | `activity-processor`/`coach-api` bucket by patient tz; `behavioral-detector` times its windows by facility-local — set both so both are correct. |
| D5 | **No blind backfill** of existing patients or historical session `date` rows. | We cannot infer a patient's past tz. Self-heal (§4.5) covers existing patients going forward; already-written session `date`s keep their UTC value (a re-bucket job is out of scope, §5). |
| D6 | New endpoint **`PATCH /api/v1/d2c/patients/{id}/timezone`** on the **`d2c-claim`** Lambda. | `d2c-claim` already runs under the D2C authorizer with Patients R/W + IdentityKey. `patient-api` is read-only — widening its IAM for one write is worse. |
| D7 | Validate the zone is **`ZoneInfo`-loadable** before storing; drop silently otherwise. | The browser gives valid IANA, but a spoofed body shouldn't poison day-bucketing. Invalid → leave unset (UTC fallback, same as today). |

## 4. Scope — BUILD NOW

### 4.1 Frontend tz detection (`lib/util/timezone.dart`)
`detectIanaTimeZone() -> String?` via `dart:js_interop` reading `Intl.DateTimeFormat().resolvedOptions().timeZone`; `try/catch → null` (never throws into the claim/load path). Zero new package dependency (app is web-only).

### 4.2 Claim wiring
- `ApiClient.claimDevice(walkerId, {displayName, agreementVersion, timeZone})` → adds `timezone` to the body when non-null (parallels `agreementVersion`).
- `LiveD2CRepository.claim` passes `detectIanaTimeZone()`.

### 4.3 `d2c-claim` backend (claim path)
- Parse `body.timezone`; validate via `ZoneInfo` (D7).
- New Patient: set `patient_item["timezone"]`. §5.7 dedupe (reuse existing patient): heal a null/`UTC` tz (conditional update).
- Set the synthetic **facility** `timezone` on the org row (currently hardcoded `"UTC"`).
- Audit `d2c.patient.timezone_set` (value only — a tz is not PII).

### 4.4 tz-update endpoint (`d2c-claim`)
`PATCH /api/v1/d2c/patients/{id}/timezone` — body `{timezone}`.
- **Authz:** authenticated D2C caller, `custom:isWalkerUser == "true"`, and `patient.cognitoUserId == caller sub` (the walker owns their own Patient row).
- **Conditional heal:** DDB update guarded `attribute_not_exists(#tz) OR #tz = :utc` — so this endpoint can only *fill an unset zone*, never overwrite a real one (D3). Idempotent; a real-zone patient returns `200 {healed:false}`.
- Validate `ZoneInfo` (D7); `400 INVALID_TIMEZONE` otherwise.
- Audit `d2c.patient.timezone_healed`.
- Route + IAM registered in `api-stack.ts` (`d2c-claim` already has Patients R/W).

### 4.5 Frontend self-heal (dashboard host)
After the dashboard snapshot loads: if `snapshot.viewer.isWalkerUser` **and** `detectIanaTimeZone()` is non-null **and** the stored patient tz is null/`UTC` **and** differs from detected → best-effort `repository.setPatientTimezone(patientId, detected)`. Never blocks or fails the dashboard (fire-and-forget with a swallowed error). Needs the patient's stored tz on the snapshot (add `timezone` to the D2C patient projection if not already surfaced).

## 5. Out of scope (deferred, additive)
- **User-facing tz picker / manual override** in Settings (for travel or a mis-detected zone). Additive: a second writer to the same field; the claim/heal stay as the automatic default.
- **Re-bucketing historical session `date` rows** written under UTC. Only *future* sessions bucket correctly; past rows keep their stored date. A one-off backfill job (recompute `date` from `sessionStart` + the now-known tz) is possible later if the 7-day chart's older bars matter.
- **Following travel automatically** (D3) — intentional.
- **Facility-channel patients** — already inherit a real facility tz; unaffected.

## 6. Interfaces + data
- **Claim body:** `+ timezone` (S, IANA, optional).
- **Patient row:** `timezone` now populated (was absent → UTC fallback). Format: IANA string.
- **New route:** `PATCH /api/v1/d2c/patients/{id}/timezone`. New error: `INVALID_TIMEZONE`.
- **Audit:** `d2c.patient.timezone_set` (claim), `d2c.patient.timezone_healed` (endpoint).
- **IAM:** none new (`d2c-claim` already has Patients R/W).

## 7. Testing
- **Backend unit:** `ZoneInfo` validation (valid IANA passes, garbage/offset dropped); claim stamps tz on patient + facility; dedupe heals null/UTC only; endpoint authz (non-walker 403, wrong-owner 403, valid heal 200); conditional guard (real-zone patient → `healed:false`, no write).
- **Frontend:** `flutter analyze` clean; `detectIanaTimeZone()` returns a plausible zone in a browser run.
- **E2E (dev → prod):** claim with `timezone` → patient row carries it; PATCH heals a null-tz patient; confirm a US-tz session now buckets to the local day (closes the "Today's walks" root cause for real tz). Deploy order: `d2c-claim` (Api stack) → `deploy-d2c-app.sh`.

## 8. Open questions
- [ ] Surface the stored patient tz on the D2C dashboard snapshot if not already present (needed for the §4.5 heal comparison) — confirm the projection.
- [ ] Re-bucket historical sessions (§5) — worth a one-off job, or accept that only forward data is correct?
- [ ] Settings override timing — bundle now or defer to the next D2C settings pass?

## Changelog
- **2026-07-20 (shipped)** — Built + deployed dev + prod. Frontend: `lib/util/timezone.dart` (`dart:js_interop_unsafe` reading `Intl…timeZone`); claim sends `timezone`; dashboard fire-and-forget self-heal (`_maybeHealTimezone`). Backend (`d2c-claim`): `claim_logic.valid_iana_tz` (ZoneInfo-validated), `_apply_timezone` (patient + facility, force vs conditional-heal), `PATCH /api/v1/d2c/patients/{id}/timezone` (`_set_timezone`, isWalkerUser + owner gated, fills-unset-only), route in `api-stack.ts` (no new IAM). Verified: 5 `valid_iana_tz` unit tests + 23 claim-logic total; dev E2E on the endpoint (heal / idempotent-no-overwrite / non-walker 403 / wrong-owner 403 / invalid 400); browser `Intl` yields `America/Denver`; prod authz smoke (403/400). **§4.5 note:** implemented inside `live_d2c_repository.dashboard()` (has patient tz + `viewerIsWalker` + `patientId` in hand) rather than the host — no snapshot plumbing needed; OQ-1 resolved (the D2C patient projection already carries `timezone`).
- **2026-07-20** — Initial spec (Option B: capture at claim + isWalkerUser-gated self-heal on load). Authored after the "Today's walks" fix traced the root cause to unset patient timezones defaulting to UTC.

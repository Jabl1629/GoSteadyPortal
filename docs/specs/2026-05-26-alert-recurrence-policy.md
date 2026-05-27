# Alert Recurrence Policy — Suppress-Until-Acked + Auto-Ack-On-Clear

## Overview
- **Type**: cross-cutting design memo (touches 1B-rev Threshold Detector + 1C-slim Behavioral Detector + 2A-AA Alert Actions)
- **Status**: Planned (drafted 2026-05-26)
- **Branch**: feature/infra-scaffold
- **Trigger**: bench unit GS9999999998 accumulated 45 unacked `battery_critical` rows in ~45 hours — one per hourly heartbeat — making the Census + Notification Review panel essentially useless. Same shape will hit `device_offline` / `device_silent` / `signal_lost` / `signal_weak` / `battery_low` whenever the underlying condition persists across multiple detector firings.

V1 product decision (this memo): each continuous-condition alert type stays **open** until the caregiver acks it OR the system observes the condition has cleared and auto-acks it. While open, subsequent detector firings that re-evaluate the same violating condition emit zero new rows — the existing open alert is the active signal.

## Locked-In Requirements

| # | Requirement | Decided In | Rationale |
|---|-------------|-----------|-----------|
| L1 | **Per-(patient, alertType) open-alert state lives on the Patient row** as a `openAlerts: Map<alertType, {sk, openedAt}>` field. New attribute on `gosteady-{env}-patients`. Sparse — only types with currently-open alerts have entries | This memo | Avoids a new GSI on Alert History. Patient row is already read by both detectors and by alert-actions; piggybacking the state is O(1) and race-safe via conditional UpdateItem. Patient is 1:1 to device at any given time (per ARCHITECTURE §4 device-mobility model), so patient-scoped is sufficient — no need to key by `deviceSerial` |
| L2 | **Continuous-condition alerts (governed by this policy):** `battery_critical`, `battery_low`, `signal_lost`, `signal_weak` (threshold-detector); `device_offline`, `device_silent` (behavioral-detector). **Daily-cadence alerts NOT governed:** `no_activity_today`, `below_typical_activity`, `declining_trend` — each day's row is semantically distinct (it's about *that day's* data), naturally bounded to one per day by the hour-gate in `facility_iterator.rule_set_for_facility()` | This memo | The two rule families have different temporal semantics. Continuous conditions can persist indefinitely; daily ones are point-in-time observations whose row is the persistent record of that day |
| L3 | **Suppress flow:** before each PutItem of a continuous-condition alert, attempt a conditional UpdateItem on Patient that sets `openAlerts.<alertType> = {sk, openedAt}` with `ConditionExpression: attribute_not_exists(openAlerts) OR attribute_not_exists(openAlerts.<alertType>)`. On success, proceed with PutItem. On `ConditionalCheckFailedException`, log + increment a `suppressed_open_alert` metric, return without writing | This memo | Atomic claim. Two concurrent detector invocations for the same patient + alertType: one wins the claim and writes the alert; the other gets the conditional failure and bails. No duplicate rows, no orphan claims |
| L4 | **Auto-ack flow:** every detector run **also** evaluates each continuous-condition rule for its **clear** counterpart (defined per-rule in L7). When (a) the clear condition holds for this invocation AND (b) `Patient.openAlerts.<alertType>` is set: (i) `UpdateItem` on Alert row at the stored `sk`, setting `acknowledged=true`, `acknowledgedBy='system:condition_cleared'`, `acknowledgedAt=now`, with `ConditionExpression: acknowledged = :false` to guard against races with manual ack. (ii) `UpdateItem` on Patient row to `REMOVE openAlerts.<alertType>`. (iii) emit `alert.auto_acknowledged` audit | This memo | Caregiver-facing surface stays clean: one row per "thing I need to deal with." Historical audit trail records the auto-ack with a distinct `acknowledgedBy` value so post-hoc analysis can distinguish caregiver-driven acks from system-driven ones |
| L5 | **Manual-ack flow** (`PATCH /alerts/{patientId}/{ts}` in alert-actions) also calls `release_open_alert(patientId, alertType)` after the ack write succeeds — REMOVE `openAlerts.<alertType>` from Patient row. Effectively the same final-state as auto-ack; the only difference is `acknowledgedBy` (Cognito sub vs `system:condition_cleared`) | This memo | Symmetric state machine. After any kind of ack, the next condition violation can fire a fresh alert |
| L6 | **`alert.auto_acknowledged` audit event** added to `_shared/audit_catalog.py` and the Phase 1.7 audit catalog table. `subject`: `patientId`, `clientId`, `facilityId`, `censusId`, `deviceSerial`. `actor`: `{type: 'system', id: 'threshold-detector'/'behavioral-detector'}`. `before`: prior `{acknowledged: false}`. `after`: `{acknowledged: true, acknowledgedBy: 'system:condition_cleared', acknowledgedAt}` | This memo + Phase 1.7 | Every system-driven mutation of patient-visible state must emit an audit event |
| L7 | **Clear conditions — active-territories semantics.** Per shadow update, compute the *currently-active* territory per dimension; auto-ack any open slot whose territory is NOT currently active for the dimension we observed. Territories per dimension: `battery_pct < batteryCritical` → battery_critical active; `[batteryCritical, batteryLow)` → battery_low active; `>= batteryLow` → neither active. Symmetric for signal (`rsrp_dbm <= rsrpLost` → signal_lost; `(rsrpLost, rsrpWeak]` → signal_weak; `> rsrpWeak` → neither). Offline rules (behavioral-detector): `device_offline` active iff `lastSeen <= now - offlineThreshold` AND `> now - silentThreshold`; `device_silent` active iff `lastSeen <= now - silentThreshold`. Dimensions not reported in the shadow update don't get auto-acked (no signal to act on) | This memo | Active-territories handles recovery (`0.03 → 0.50`: both critical + low ack), tier change (`0.03 → 0.07`: critical acks + low fires fresh), and escalation (`0.07 → 0.03`: low acks + critical fires fresh) in a single uniform mechanism. The naive "clear-on-recovery-only" rule (literal mirror of fire-thresholds) would leave stale low-slots when battery escalates to critical |
| L8 | **State-transition examples.** Recovery (battery 0.03 → 0.50): both `battery_critical` and `battery_low` slots ack; no new alert. Tier change downward (battery 0.03 → 0.07): `battery_critical` slot acks; `battery_low` slot gets claimed by the breach-write path. Tier change upward / escalation (battery 0.07 → 0.03): `battery_low` slot acks; `battery_critical` slot gets claimed | This memo | Each tier is its own open-alert slot. Tier promotion / demotion is two state transitions: clear-then-fire. Audit trail records both as separate events with distinct `alertType` values |

## Assumptions

| # | Assumption | Risk if Wrong | Validation Plan |
|---|-----------|---------------|-----------------|
| A1 | Patient row gets `openAlerts` attribute lazily on first claim; existing patients without it work fine | Existing patients have `openAlerts = undefined`; conditional `attribute_not_exists(openAlerts)` succeeds; `SET openAlerts = if_not_exists(openAlerts, :empty), openAlerts.<type> = :rec` initializes-and-sets in one update | Migration script in `infra/scripts/ack-pre-recurrence-policy-alerts.py` also sets `openAlerts = {}` on every existing patient as defense-in-depth |
| A2 | The conditional UpdateItem to claim the openAlerts slot is cheap (sub-10ms p99) — same cost as today's per-Patient `enforce_patient_access` Query | Slow handler invocation | DDB UpdateItem is sub-10ms; the entire detector path adds ~1 round-trip; well within the 1s synthetic-alert latency tolerance (1B-rev A4) |
| A3 | The auto-ack write race (system + caregiver acking simultaneously) is rare enough that a single failed conditional ack is acceptable. First write wins; second silently bails on `acknowledged = :false` check | Both sides update the same alert row → potentially stale `acknowledgedBy` if the loser silently retries | The `ConditionExpression: acknowledged = :false` makes this idempotent. Loser's UpdateItem returns `ConditionalCheckFailedException` and we log + count `auto_ack_race_lost`; alert is already correctly acked by the winner |
| A4 | The bench unit's `battery_pct=0` is treated as "battery critical" by the threshold check, even though it's a firmware quirk (no SoC fuel gauge on AA-powered Thingy:91 X). Auto-ack would never fire because the condition never clears | Bench unit stays in `battery_critical` open state permanently; no `battery_critical` alert ever fires for any other patient with a real low battery because every shadow update is dedup'd against the bench's open slot | False — `openAlerts` is per-patient. Bench unit's open slot is on `pt_bench_98.openAlerts`, not on any other patient. Other patients fire independently. The bench-specific "stuck open" state is a known-acceptable artifact until the firmware fuel gauge lands (M14.x); ops can manually ack it if it gets in the way during demos |
| A5 | Adding `openAlerts` to the Patient row doesn't push us past DDB's 400KB item-size cap | A patient with 100+ concurrent open alert types could theoretically grow the row | We have 6 continuous-condition alert types total. Worst case 6 entries × ~50 bytes each = ~300 bytes. Well within margin |

## Scope

### In Scope
- `infra/lambda/_shared/open_alerts.py` (new) — `claim_open_alert` + `release_open_alert` + `get_open_alert_sk` + `auto_ack_alert` helpers
- `infra/lambda/threshold-detector/handler.py` — pre-write claim; post-evaluate clear-detection + auto-ack
- `infra/lambda/behavioral-detector/handler.py` — same pattern for `device_offline` + `device_silent`
- `infra/lambda/alert-actions/handler.py` — release on manual ack
- `infra/lambda/_shared/audit_catalog.py` — `AUDIT_ALERT_AUTO_ACKNOWLEDGED`
- `docs/specs/phase-1.7-audit.md` — catalog row
- `docs/specs/phase-1b-revision.md` — L7 amendment (idempotency → suppress-until-ack)
- `docs/specs/phase-1c-slim-notifications.md` — L11 + L12 amendment (implementation closes the existing spec)
- `infra/scripts/ack-pre-recurrence-policy-alerts.py` — one-off migration: bulk-ack all unacked continuous-condition alerts as `system:migration_2026_05_26`; initialize `openAlerts = {}` per patient

### Out of Scope (Deferred)
- **Per-device open-alert state** — patient-scoped suffices at MVP because patient:device is 1:1. If the model ever allows multiple concurrent devices per patient (it doesn't today), refactor `openAlerts` key to include `deviceSerial`
- **Hysteresis bands** on clear thresholds (e.g. `battery_critical` doesn't clear until `battery_pct >= 0.07` to avoid flapping at exactly 0.05). Defer until pilot data shows flapping is a real problem — current threshold values are conservative enough that real batteries don't oscillate across the boundary
- **Stale-claim cleanup** (an orphan claim with no matching Alert row, e.g. from a crashed Lambda between claim-and-PutItem). The claim itself is atomic; the only failure mode is "claim succeeded but PutItem then errored" which gets caught by the handler's try/except and triggers a manual release. Add a 30-day-old-claim sweeper if observation shows it matters
- **Re-arming the daily-cadence alerts under the same policy** — they're naturally bounded to one row per local-day per patient via the hour-gate. Re-applying the open-alert pattern to them would change semantics (each day's row is the historical record, not a transient open-state). Don't fix what isn't broken
- **Configurable cooldown override** (e.g., suppress for 4h instead of "until acked"). Future operator knob if pilots want softer suppression — adds env var + threshold-detector branch; not blocking for V1
- **Severity escalation alerts** (e.g., `battery_critical_72h`). The current `device_offline → device_silent` tier escalation works because they're two distinct alertTypes; same model could extend to battery if needed, but not in scope here

## Architecture

### Infrastructure Changes

**None.** Patient table schema is DDB-flexible; new `openAlerts` attribute lands as a map field on existing rows lazily.

### State Machine

```
       condition first violates        manual ack OR auto-ack
[no open]  ────────────────────►  [open]  ─────────────────────────►  [no open]
   ↑                                  │
   │           condition clears (system)
   └───────────────────────────  [auto-acked alert]
                                  emits audit, removes claim
```

Each `(patientId, alertType)` pair has exactly one cell in this diagram at any given time.

### Lambda call shape (threshold-detector, per shadow update)

```
Heartbeat shadow update
       │
       ▼
For each continuous-condition rule (battery_critical, battery_low, signal_lost, signal_weak):
       │
       ├── Is the rule's *violation* condition true?
       │     ├── YES → try claim_open_alert(patient, type, sk, openedAt)
       │     │           ├── claim SUCCESS → PutItem alert row + emit_audit(alert.synthetic.create)
       │     │           └── claim FAIL    → log "suppressed_open_alert" + metrics.add_metric
       │     │
       │     └── NO (rule not violating) →
       │
       └── Is the rule's *clear* condition true AND a same-type alert is open?
              ├── YES → auto_ack_alert(patient, type) [UpdateItem alert + release_open_alert + emit_audit(alert.auto_acknowledged)]
              └── NO  → no-op
```

Behavioral-detector (hourly cron) follows the same shape for `device_offline` + `device_silent`.

### Helper module contract — `_shared/open_alerts.py`

```python
def claim_open_alert(
    patient_id: str,
    alert_type: str,
    sk: str,
    opened_at: str,
) -> bool:
    """Returns True if this caller claimed the open slot; False if
    a same-type alert was already open. Atomic via conditional
    UpdateItem on Patient row."""
    ...

def release_open_alert(patient_id: str, alert_type: str) -> bool:
    """Removes the openAlerts.<type> entry. Returns True on success
    (entry existed and was removed); False if it didn't exist (caller
    can treat as no-op)."""
    ...

def get_open_alert_sk(patient_id: str, alert_type: str) -> Optional[str]:
    """Reads Patient row's openAlerts.<type>.sk. None if no open
    alert. Used to locate the Alert row for auto-ack writes."""
    ...

def auto_ack_alert(
    patient_id: str,
    alert_type: str,
    *,
    reason: str = "condition_cleared",
    actor_service: str,
    subject: dict,
) -> bool:
    """End-to-end auto-ack: looks up the Alert row via stored sk,
    sets acknowledged=true / acknowledgedBy=f'system:{reason}' /
    acknowledgedAt=now, releases the openAlerts slot, emits the
    alert.auto_acknowledged audit event. Returns True if the ack
    fired; False if no open alert was found or the alert was
    already acked (race with manual ack)."""
    ...
```

## Audit Trail

| Event | Emitted by | When | `before` | `after` |
|---|---|---|---|---|
| `alert.synthetic.create` (existing) | threshold-detector + behavioral-detector | New alert row inserted | — | `{alertType, severity, source, eventTimestamp}` |
| `alert.ack` (existing) | alert-actions | Caregiver PATCH | `{acknowledged: false}` | `{acknowledged: true, acknowledgedBy: <userId>, acknowledgedAt}` |
| **`alert.auto_acknowledged`** (NEW) | threshold-detector + behavioral-detector | Condition clears → auto-ack | `{acknowledged: false, openedAt}` | `{acknowledged: true, acknowledgedBy: 'system:condition_cleared', acknowledgedAt, durationSeconds}` |

`durationSeconds` (open-to-close) is a useful per-alert metric for ops dashboards — surfaces flapping behavior at scale.

## Testing

### Unit tests (mock-DDB, in-process)

| # | Setup | Action | Expected |
|---|---|---|---|
| T1 | Patient row with no `openAlerts` | claim_open_alert(...) | True; Patient.openAlerts.battery_critical = {sk, openedAt} |
| T2 | Patient row with openAlerts.battery_critical already set | claim_open_alert(... same type) | False; no Patient mutation |
| T3 | Patient with open battery_critical; condition clears | auto_ack_alert | Alert row's acknowledged=true; Patient.openAlerts.battery_critical absent; audit event emitted |
| T4 | Patient with open battery_critical; caregiver acks via alert-actions PATCH | manual-ack path | Alert row acknowledged; Patient.openAlerts.battery_critical absent (released by alert-actions) |
| T5 | Patient row with openAlerts.battery_critical at sk=S1; condition transitions to battery_low | threshold-detector full pass | Alert S1 auto-acked; new battery_low alert written + claim |
| T6 | Race: two concurrent threshold-detector invocations both see battery_critical | parallel claim attempts | Exactly one wins; the other's PutItem doesn't fire |

### Live validation against pt_bench_98

Pre-deploy state: 45 unacked `battery_critical` alerts; `openAlerts` field absent.

1. Run migration script: bulk-ack the 45 alerts (`acknowledgedBy='system:migration_2026_05_26'`); set `openAlerts = {}`.
2. Deploy `GoSteady-Dev-Processing` (threshold + behavioral) + `GoSteady-Dev-Api` (alert-actions).
3. Wait for next heartbeat. Verify: bench unit's `battery_pct=0` triggers exactly **one** new `battery_critical` alert; Patient.openAlerts.battery_critical set.
4. Subsequent heartbeats: zero new alerts; suppressed counter increments.
5. (Optional) Send a synthetic shadow update with `battery_pct=0.50` → verify auto-ack fires; subsequent `battery_pct=0` update fires a fresh alert.

## Deployment

```bash
# Processing stack — threshold + behavioral detectors
cd infra
AWS_REGION=us-east-1 npx cdk deploy GoSteady-Dev-Processing --context env=dev

# API stack — alert-actions (release on manual ack)
AWS_REGION=us-east-1 npx cdk deploy GoSteady-Dev-Api --context env=dev

# One-off bench cleanup
python3 infra/scripts/ack-pre-recurrence-policy-alerts.py --env=dev
```

## Decisions Log

| # | Decision | Alternatives | Rationale |
|---|---|---|---|
| D1 | Patient.openAlerts map (vs new GSI on Alert History) | (a) GSI `by-open-alert-type` on Alerts; (b) Redis lookup; (c) global Patient row attribute | DDB GSI adds infra + read costs + eventual-consistency window. Patient row is already read on every detector pass for tenancy lookup; piggybacking adds zero round-trips |
| D2 | No hysteresis on clear thresholds | (a) Add 0.02 gap (clear at 0.07 for critical at 0.05); (b) Add time-based hysteresis (must be clear for ≥1 hr) | Bench-unit data: battery_pct readings are stable (firmware reports identical value across heartbeats unless a real change). Hysteresis is solving a problem we don't have today. Add if pilot reveals flapping |
| D3 | Daily-cadence rules NOT under this policy | (a) Apply same suppress-until-ack to no_activity_today etc.; (b) Differentiate per rule | The two families have different semantics. Daily-cadence is "this day's data was bad" — the row IS the historical record. Continuous condition is "right now this is wrong" — one row per wrong-state is what caregivers want |
| D4 | Audit `acknowledgedBy='system:condition_cleared'` | (a) Use Cognito sub for system actor; (b) Use 'system' verbatim with separate reason field | The `system:` prefix is a discriminator. Caregivers / compliance can grep `acknowledgedBy LIKE 'system:%'` to filter system-driven. Reason after the colon (`condition_cleared`, `migration_2026_05_26`, etc.) gives forensic detail |
| D5 | Auto-ack runs in the same Lambda as detection (not a separate Lambda) | (a) Detection Lambda emits a "should auto-ack" event; consumer Lambda processes | One Lambda invocation = one round-trip for the heartbeat. Splitting adds latency + plumbing for zero benefit at MVP — `auto_ack_alert` is two DDB writes + one audit emit, ~15ms |
| D6 | `release_open_alert` from alert-actions on manual ack is **best-effort** — non-fatal if it fails | (a) Make ack 500-fail if release fails; (b) Add async retry | The Alert row is the source of truth for "acked yes/no". The openAlerts slot is a cache for the detectors. If release fails, the only consequence is: the next condition violation gets suppressed (false negative). On the next caregiver ack of that suppressed-but-not-actually-suppressed alert, the loop resolves itself. Low blast radius |

## Open Questions

| # | Question | Lean / Assumption | ELI5 impact |
|---|---|---|---|
| Q1 | Should `device_offline → device_silent` escalation auto-ack the `device_offline` open slot? Today they're two distinct alertTypes; both could be open simultaneously | **Lean: YES — escalate atomically.** When the detector observes lastSeen > 24h, it (a) auto-acks any open `device_offline` alert AND (b) fires a fresh `device_silent` alert. Cleaner caregiver UX (one row per device-status). The current code keeps both open simultaneously which is redundant | If "no": caregivers see two alerts ("Device offline" + "Device silent") for the same device, which is duplicative. If "yes": cleaner |
| Q2 | What about `severity` escalation within the same alertType? (Currently severity is fixed per type) | **Lean: not applicable.** All continuous-condition alertTypes have a fixed severity in `device_offline.py` etc. No within-type escalation today | Caregivers see the severity baked into the alertType name (`battery_critical` is always critical) |
| Q3 | Should the migration script set `openAlerts = {}` on every active patient, or only on patients that have unacked continuous-condition alerts? | **Lean: every active patient.** Defensive — `if_not_exists(openAlerts, :empty)` in the claim path handles missing field, but pre-initializing makes inspection easier ("does this patient have any open alerts?" → check map length, no null-check) | DDB cost difference: nil (one extra UpdateItem per patient at migration time) |

## Spec Amendments (linked specs to update)

- **phase-1b-revision.md L7** — "idempotent by `{eventTs}#{alertType}` SK" supplemented with: "If the rule's continuous-condition type matches L2 of `2026-05-26-alert-recurrence-policy.md`, the conditional PutItem is gated by `claim_open_alert` first; same-type re-fires while the prior alert is open are suppressed"
- **phase-1c-slim-notifications.md L11 + L12** — "no `device_offline`/`device_silent` alert in last 24h for this serial" is now implemented via `Patient.openAlerts` rather than a time-windowed Query
- **phase-1.7-audit.md** — add `alert.auto_acknowledged` row to the audit catalog

## Changelog

| Date | Author | Change |
|------|--------|--------|
| 2026-05-26 | Jace + Claude session | Initial draft. Triggered by 45-alert pileup on `pt_bench_98`. Locks in the suppress-until-acked + auto-ack-on-clear policy across threshold-detector + behavioral-detector + alert-actions. New `_shared/open_alerts.py` helper module; `Patient.openAlerts: Map<alertType, {sk, openedAt}>` storage. New audit event `alert.auto_acknowledged`. Migration script bulk-acks the existing bench backlog |
| 2026-05-26 | Jace + Claude session | **Implemented + deployed + live-validated against `pt_bench_98`.** Two implementation discoveries during bench-validation: (a) `_shared/open_alerts.py` originally read `os.environ["ALERTS_TABLE"]` but the detector Lambdas expose the table name as `ALERT_TABLE` (singular, predates the alert-actions plural convention); helper now reads either env var. (b) The original `SET openAlerts = if_not_exists(...), openAlerts.X = ...` UpdateExpression was rejected by DDB with `ValidationException: Two document paths overlap`; rewrote as two atomic UpdateItems (defensive `SET openAlerts = :empty` with `attribute_not_exists` guard, then the conditional claim). Validated end-to-end: (1) recovery (battery 0.03→0.50) auto-acks both battery_critical + battery_low slots, no new alert; (2) suppression — second invoke with `battery_pct=0` writes zero alerts because slot is claimed; (3) recurrence — first invoke after release creates one alert + claims slot; (4) tier change (0.03→0.07) acks critical + fires fresh low; (5) escalation handled symmetrically via active-territories semantics in L7. Migration script acked 71 pre-policy duplicate alerts across 9 dev patients (49 of those on pt_bench_98 alone), leaving exactly one most-recent per (patient, alertType) as the post-policy open slot. Coord §C33 has the full chronology |

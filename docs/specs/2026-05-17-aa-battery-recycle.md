# Design memo: AA-battery recycle — replacing charger-gated reset with wipe-ack auto-recycle

> **Status:** Decided 2026-05-17. Implementation across multiple specs + code; this memo is the rationale + decision record.
> **Affects:** ARCHITECTURE.md §1 / §4 / §7 / §14 / §15, `phase-2a-device-lifecycle.md`, firmware contract on `gs/{serial}/cmd`, Device Registry schema, `_shared/audit_catalog.py`, `heartbeat-processor` + `device-shadow-handler` + `device-api` Lambdas, firmware `cloud.c` + `activation.c`.
> **Supersedes:** ARCH DL6 ("Reset is firmware-driven on charger; no portal reset button"). 2A-DL spec A2 + A7 assumptions.

---

## 1. Why this change

The original device-lifecycle design assumed a **rechargeable LiPo battery** that needed to be plugged in to a charger between deployments. The charger-attachment moment served four jobs simultaneously:

1. Power to complete the local-data wipe reliably
2. Physical custody signal (someone deliberately plugged it in)
3. Operator intent / consent (the human is preparing it for redeployment)
4. Sanitization timing (a known moment for the wipe to fire)

Hardware direction has shifted to **replaceable disposable AA batteries** with 6–12 month life. This invalidates the charger model:

- **No charger** to plug in — the device runs off AAs until they're depleted.
- **Battery-swap is rare and unpredictable** — at most once or twice per device per year, often unrelated to patient handoff. Most between-patient transitions happen with the same battery installed.
- **Patient deployments are often shorter than battery life** — 1–2 week use cases are common. A single AA set serves 10–30+ patient cycles.

There is no longer a naturally-occurring physical event tied to between-patient handoff. The four jobs that charger-attachment did must be re-distributed.

---

## 2. New design (one paragraph)

End-assignment immediately issues a **`wipe` downlink command** to the device on `gs/{serial}/cmd`. Firmware receives it (immediately if online, or queued by the broker per persistent MQTT session if not), performs a local wipe of patient-specific data, and acknowledges via Shadow `reported.wipe_complete` + heartbeat `last_cmd_id`. Cloud observes the ack and **automatically transitions** `discontinued → ready_to_provision` gated on a small predicate set (sanity floor on battery + ack matching). The `force_reset` admin override remains for stuck firmware. The transition no longer depends on any hardware event.

---

## 3. Decisions log

| # | Decision | Alternatives | Rationale |
|---|----------|--------------|-----------|
| **D1** | Trigger: cloud-issued `wipe` downlink cmd, fired immediately on `end-assignment`. | (a) firmware-driven on cold-boot + fresh battery — invalidated by long battery life. (b) two-stage caregiver workflow ("end" + "prepare for next patient") — adds operational friction. (c) time-based quarantine — arbitrary, doesn't prove anything. | Mirrors the existing `activate` cmd pattern (D2). Cloud orchestrates; firmware acts. No reliance on physical events. |
| **D2** | Consent signal: firmware reports `wipe_complete` via Shadow `reported.wipe_complete = <wipe_id>` AND heartbeat `last_cmd_id = <wipe_id>`. Cloud transitions on ack-match. | Trust the cloud-side end-assignment alone (no firmware ack). | Wipe-ack is the durable evidence that local data was actually cleared, not just that the operator clicked a button. Symmetric with the activation pattern just shipped (§C19). |
| **D3** | Battery sanity floor at wipe-time: `battery_pct ≥ 0.10` (firmware refuses to wipe below this; retries on next wake). | 0.05 (too tight — wipe is multi-second flash I/O), 0.20 (too conservative — would block valid recycles), voltage-based instead of percentage. | 0.10 leaves margin above the `battery_critical` alert threshold (0.05) — wipe completes cleanly without flirting with brownout. Voltage-based reserved for FMEA 3.1 follow-up (nPM1300 with AAs is a known unknown). |
| **D4** | Wipe scope on firmware: **wipe** `/lfs/activation.bin`, in-progress session `.dat` buffer, calibration drift state, opportunistic snippet buffer (`/snippets/*`). **Keep** firmware image, device cert (sec_tag 201), modem cert, `boot_count`, `fault_counters`, **and the `crash_forensics` partition** (cross-deployment forensic continuity). | Wipe `crash_forensics` for cleanest slate per deployment. | Crash forensics survive reboots intentionally so we can investigate a bug that crashed an old deployment. Wiping them on every recycle would erase exactly the trail we'd want. Patient-identifying data lives entirely in `/lfs/activation.bin` + session buffer, which are wiped. |
| **D5** | No grace window / undo: end-assignment fires the wipe cmd **immediately**. | Defer wipe issuance by T (e.g. 1 h) to allow undo. | Operationally simpler; no end-assignment-was-a-mistake recovery path. Mitigation: end-assignment is already a deliberate action with a confirmation modal (Phase 2A-DL UX). If real-world misclicks emerge, add an undo affordance later as a non-breaking change. |
| **D6** | Idempotency: cmd-still-in-`outstandingWipeCmds`-map (mirror of `outstandingActivationCmds`). Successful ack REMOVEs the entry; duplicate ack is a no-op. | `attribute_not_exists` on last_wipe_at (the bug pattern we just fixed for activation). | Same pattern as the §C19 heartbeat-processor activation-ack fix. Consistency lowers cognitive load; if we change the pattern in one place we can change it in both. |
| **D7** | `device.battery_swapped` audit event: emitted on mid-deployment cold-boot detected by `boot_count` increment + `reset_reason = POWER_ON` while status ∈ {`provisioned`, `active_monitoring`}. Low severity. No state change. | Skip the audit (cheaper). | Useful operational forensics for "did the operator actually swap batteries this month or did the device power-cycle from brownout?" Cost is negligible (one extra audit row per battery swap per device — i.e. once or twice per year). |
| **D8** | `force_reset` admin override stays as the safety hatch for stuck firmware. Same RBAC as before (facility_admin+). | Remove force-reset entirely now that wipe is software-orchestrated. | The wipe-ack path can still fail (firmware bug, device permanently offline before next wake, etc.). Admins need a way to clear a stuck `discontinued` device without an ack — bypassing the wipe predicate, accepting the audit consequence. |
| **D9** | Decommission paths do NOT issue a wipe cmd. A device in `decommissioned` is by definition no longer in operational rotation; if data wipe matters at decom time, the caller end-assignments first. | Auto-wipe on decommission too. | Decommissioned devices may never come back online (`lost`, `broken`, `end_of_life`). Issuing a wipe cmd that may never be acked clutters `outstandingWipeCmds` indefinitely. Cleaner contract: wipe is a recycle-prep step, not a decom step. |
| **D10** | Cross-facility / cross-client moves: require status = `ready_to_provision` (tightens existing L15 from "rejects active_monitoring" to "requires ready_to_provision"). Caller must `end-assignment` + wait for wipe-ack first. | Allow move from `discontinued` (pre-wipe). | Tightens the invariant that ownership transfers happen only on clean (wiped) devices. Avoids carrying patient-cache residue across ownership boundaries. |

---

## 4. New MQTT contract: `wipe` downlink cmd

Topic: `gs/{serial}/cmd` (existing — same as `activate`).

```json
{
  "cmd": "wipe",
  "cmd_id": "wipe_4f8e21b3-...",
  "ts": "2026-05-17T18:30:00Z"
}
```

| Field | Required | Validation |
|-------|----------|-----------|
| `cmd` | Yes | Enum: `activate` \| `wipe` (v1 commands) |
| `cmd_id` | Yes | UUID prefixed `wipe_` for visual distinction from `act_` |
| `ts` | Yes | ISO 8601 cloud-side wall-clock at publish time |

Firmware behavior on receipt:
1. If `battery_pct < 0.10` → defer to next wake; do not ack.
2. Wipe scope per D4:
   - Remove `/lfs/activation.bin`
   - Truncate any in-progress session `.dat` writer buffer
   - Reset calibration drift state (in-memory + persisted)
   - Delete `/snippets/*` contents
3. Preserve per D4: firmware image, certs, `boot_count`, `fault_counters`, `crash_forensics` partition.
4. Write Shadow `reported.wipe_complete = <cmd_id>` and `reported.wipe_completed_at = <ISO ts>`.
5. Echo `last_cmd_id: <cmd_id>` in next heartbeat.
6. Stay in pre-activation behavior (blue LED, no session capture) until next provision/activate cycle.

Per-thing IoT policy authorizes subscribe + receive on own `gs/{thingName}/cmd` — already in place from the `activate` cmd. No policy change.

---

## 5. Cloud-side flow

### End-assignment (cloud → device)

When `device-api` handler successfully processes `POST /devices/{serial}/end-assignment`:

1. Conditional UpdateItem on Device Registry:
   - SET `status = discontinued`, `lastTransitionAt = <now>`
   - SET `outstandingWipeCmds.<wipe_id> = <now>` (creating map if absent)
   - SET `wipe_requested_at = <now>`
   - Condition: current status ∈ {`provisioned`, `active_monitoring`}
2. Close the active DeviceAssignment row (`validUntil = <now>`, `endedReason = <caller-supplied or "end-assignment">`)
3. Write Shadow `desired.activated_at = null` AND `desired.wipe_requested = <wipe_id>` (in same UpdateThingShadow call)
4. Publish to `gs/{serial}/cmd` with the wipe payload (D4 schema)
5. Emit audits: `device.assignment_ended`, `device.wipe_requested`

Atomicity: if step 4 (`iot:Publish`) fails, roll back the Shadow write (re-set `desired.activated_at`? no — already null on this path) and the `outstandingWipeCmds` map entry. Same rollback pattern as L14 activation. Return 500; retry is safe (fresh wipe_id on retry, prior orphan in map purges via TTL or admin sweep).

### Wipe-ack handling (device → cloud)

Two parallel paths converge on the same auto-recycle predicate:

**Path A: heartbeat-processor sees `last_cmd_id` echo** — symmetric with the `_try_activation_ack` we just shipped (§C19). New `_try_wipe_ack` helper (or factor shared `_try_cmd_ack`):

1. Look up `outstandingWipeCmds.<last_cmd_id>` in Device Registry
2. If match within ack window (24h) AND `battery_pct ≥ 0.10` in this heartbeat:
   - UpdateItem condition: `attribute_exists(outstandingWipeCmds.#cid)` AND `status = :disc`
   - SET `status = ready_to_provision`, `last_wipe_at = <heartbeat ts>`, `lastTransitionAt = <now>`
   - REMOVE `outstandingWipeCmds.#cid`
   - On CCFE (cmd already acked or status moved): info log, return false
3. Clear Shadow `desired.wipe_requested` (set to null)
4. Audits: `device.wipe_complete`, `device.recycled`

**Path B: device-shadow-handler sees `reported.wipe_complete` in Shadow delta** — same logic. Either path is sufficient; both firing for the same wipe_id is idempotent (second one's CCFE is benign).

Why both paths: heartbeat carries the ack reliably (existing 1B-rev path); Shadow delta is the "durable state of record" channel (per DL14 design choice). Mirrors how activation works today.

### Mid-deployment battery-swap detection (D7)

heartbeat-processor adds a check:
- Read prior `Shadow.reported.boot_count` (if any)
- If incoming heartbeat's `boot_count` > prior AND `reset_reason == "POWER_ON"`:
  - Status ∈ {`provisioned`, `active_monitoring`}? → emit `device.battery_swapped` audit (low severity, no state change)
  - Status = `discontinued` AND a wipe is pending? → no extra audit (this is the expected wipe-cycle boot)
  - Status = `ready_to_provision`? → no audit (device sitting unowned; battery swap is uninteresting)

---

## 6. State machine update

The 5-state machine itself is unchanged. Only the **transition trigger** for `discontinued → ready_to_provision` changes.

Old:
```
discontinued ──[firmware reset on charger]──> ready_to_provision
```

New:
```
discontinued ──[firmware wipe-ack: wipe_complete + battery_pct ≥ 0.10]──> ready_to_provision
                            ↑
                  fires automatically once both
                  conditions are met cloud-side
```

`force_reset` admin override path unchanged (`discontinued → ready_to_provision` bypassing the wipe predicate).

Patient discharge cascade now produces a wipe cmd for each device when the discharge-cascade Lambda calls end-assignment internally — no per-device intervention needed.

---

## 7. New invariants

| # | Invariant |
|---|-----------|
| **W1** | `Device Registry.outstandingWipeCmds` is non-empty ⟺ at least one wipe cmd has been issued for this device but not yet acked. Each entry has a 24h ack-matching window (mirrors `outstandingActivationCmds`). |
| **W2** | Shadow `desired.wipe_requested` is non-null ⟺ a wipe cmd is outstanding AND device has not yet acked. Cleared by cloud on ack receipt. Mirrors DL14's `desired.activated_at` invariant. |
| **W3** | A successful wipe-ack only fires `discontinued → ready_to_provision` if `battery_pct ≥ 0.10` in the acking heartbeat. Below floor, the ack is recorded but state stays `discontinued`. |
| **W4** | `force_reset` admin override is the only path to `ready_to_provision` that bypasses the wipe predicate. Every invocation is audited at elevated severity. |
| **W5** | Cross-facility / cross-client move requires status = `ready_to_provision`. Tightens L15. |

---

## 8. Audit events

New (added to `_shared/audit_catalog.py`):

| Event | When | Severity | Subject keys |
|-------|------|----------|--------------|
| `device.wipe_requested` | Cloud publishes wipe cmd on end-assignment | info | serialNumber, wipe_id, patient_id (last assignment) |
| `device.wipe_complete` | Cloud sees firmware ack (heartbeat or Shadow) | info | serialNumber, wipe_id, battery_pct |
| `device.recycled` | Cloud auto-transitions discontinued → ready_to_provision | info | serialNumber, last_wipe_at, prior_assignment_patientId |
| `device.battery_swapped` | Mid-deployment cold-boot detected | info (low) | serialNumber, prior_boot_count, new_boot_count, battery_pct |
| `device.wipe_failed` | Wipe ack indicates failure (firmware reports `wipe_complete=false` or similar) | warning | serialNumber, wipe_id, reason |

Deprecated:
- `device.reset_complete` — replaced by `device.wipe_complete` + `device.recycled` (semantically cleaner split). Keep the constant in the catalog for backwards compat during transition; remove on next cleanup cycle.

---

## 9. Updated FMEA / risk register

| # | Risk | Mitigation |
|---|------|------------|
| W-R1 | Device permanently offline after end-assignment → wipe never acked → stuck in `discontinued` indefinitely | New alarm: `wipe_requested_at` older than 24h with no ack. Routes to ops. Admin uses `force_reset` once retrieved. (Mirrors L16 stuck-in-provisioned alarm.) |
| W-R2 | Firmware wipe routine has a bug → reports `wipe_complete` but local data still present | Validation deferred to firmware bench test (§C20 or follow-up). Cloud trusts the ack; firmware-side test must confirm the wipe routine actually wipes. |
| W-R3 | Mid-wipe brownout → partial wipe + no ack → device stuck | D3 battery floor mitigates. If still happens (battery drops mid-wipe under floor), admin `force_reset` + manual investigation. |
| W-R4 | `outstandingWipeCmds` map grows unbounded if many wipes are issued without ack | Mirror of `outstandingActivationCmds` — same TTL/cleanup policy. Each entry has issuance timestamp; sweep entries older than the 24h window. |
| W-R5 | nPM1300 `battery_pct` reading on AAs is inaccurate → wipe defers on devices that actually have plenty of power, or fires on devices that don't | FMEA 3.1 follow-up. Mitigation: firmware reports raw `battery_mv` (already optional in heartbeat); fallback predicate uses voltage if percentage drifts more than expected. |

---

## 10. Open questions / TODOs

1. **Battery chemistry + cell count** — alkaline AA × N, or NiMH? Affects nPM1300 fuel-gauge calibration (FMEA 3.1 reframe) and the heartbeat `battery_mv` validation range. **Firmware-side question.** Not blocking architecture; affects bench characterization.
2. **Alarm threshold for stuck-wipe-pending** — analog to L16's 24h stuck-in-provisioned. Same window? Or different (since wipes should ack faster in normal storage cases)? Lean: 24h to match.
3. **W-R2 firmware-side wipe correctness validation** — bench test needs to confirm the wipe routine actually clears `/lfs/activation.bin` and the session buffer. Sequence: provision → end-assignment → inspect firmware filesystem via dump tool → confirm activation.bin gone. Coord doc follow-up.
4. **Wipe cmd retry policy on the cloud side** — if firmware never echoes, do we re-issue wipe after some interval? Lean: no — the admin `force_reset` path is the explicit re-try. Auto-retry adds complexity for marginal benefit.

---

## 11. Doc + code surface affected

See §12 (code) and §13 (docs) for the implementation punch list. High-level surface:

**Specs / docs:**
- ARCHITECTURE.md §1 (device hardware), §4 (state machine, audit events, authz matrix, discharge cascade), §7 (MQTT contracts), §14 (DL6 rewrite + new DL15), §15 (Lambda inventory), §17 (spec index)
- `phase-2a-device-lifecycle.md` (L6, A2, A7, Out-of-Scope "Force-wipe IoT command" line, multiple body sections)
- Firmware `GOSTEADY_CONTEXT.md` (battery section, FMEA 3.1, storage layout, anti-features)
- Coord doc — new §C20 entry

**Cloud code:**
- `infra/lambda/device-api/handler.py` — end-assignment now issues wipe cmd
- `infra/lambda/heartbeat-processor/handler.py` — add `_try_wipe_ack`; add `device.battery_swapped` detection on cold boot
- `infra/lambda/device-shadow-handler/handler.py` — listen for `reported.wipe_complete`; trigger transition
- `infra/lambda/_shared/audit_catalog.py` — new event constants
- IoT cmd schema validation (where applicable)
- `processing-stack.ts` / `api-stack.ts` — no major changes; perhaps an env var for ack window
- Observability stack — new alarms (wipe-ack-stuck, recycle-rate)

**Firmware code (gosteady-firmware):**
- `src/cloud.c` — handle `wipe` cmd dispatch
- `src/activation.c` — wipe routine + ack reporting
- `src/snippet.c` — wipe `/snippets/*` on wipe cmd
- Shadow read of `desired.wipe_requested` on each cellular wake
- Cold-boot detection already exists (reset_reason in heartbeat); no firmware change needed for D7

---

## 12. Changelog

| Date | Author | Change |
|------|--------|--------|
| 2026-05-17 | Jace + Claude | Initial memo. Decisions D1–D10 captured. Supersedes ARCH DL6 + 2A-DL A2/A7. |

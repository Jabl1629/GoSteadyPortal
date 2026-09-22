# Field battery analysis — GS0002000005 (2026-07-24 → 2026-09-22)

> **Status:** measured from remote telemetry only (device still deployed, unmodified `rol-0.1.0-ww`). Coord §C66.
> **Answer:** **full charge → dead ≈ 29 days** under this user's real use (measured once, 2026-07-24 → 2026-08-23); ≈ 31 days once the two offline-crash losses are removed. **Average drain ≈ 1.8 mA** (≈ 44 mAh/day of a 1350 mAh cell). The current charge (2026-09-20, unplugged before it settled) should run out **around 2026-10-14 … 10-18**.
> **Product framing:** PRD DEV-09 targets ~1 year; the field number is ~12× short. Since activation the unit has been **dead 34 % of the time** (three dead windows totalling 20 days) and delivered data ≈ 64 % of the time.

---

## 1. Data used (all pulled remotely, 2026-09-22)

| Source | What it gave |
|---|---|
| CloudWatch `GoSteady/Devices/prod`, dims `serial=GS0002000005` **+ `service=gosteady-prod-heartbeat-processor`** (both are required), 1-h period | 981 hourly `BatteryPct` / `UptimeSec` / `RsrpDbm` / `FaultCountersFatal` samples, 2026-07-18 → 09-22 (455-day retention at 1 h) |
| IoT Shadow `GS0002000005` | latest heartbeat: `battery_pct 0.818`, `battery_mv 4042`, `uptime_s 163443`, `boot_count 1392`, `reset_reason POWER_ON`, `fault_counters.fatal 3`, `watchdog 0`, RSRP −104 dBm |
| DynamoDB `gosteady-prod-activity` (scan, filtered) | 1,852 sessions (`deviceSessionKey = serial#boot_count#uptime` → boot-count timeline) |
| DynamoDB `gosteady-prod-alerts` | 43 alerts (4 `battery_low`, 3 `battery_critical`, 8 `device_offline`, 4 `device_silent`, 3 `signal_lost`, …) |
| Log group `gosteady-prod-audit` (90 d) | `device.battery_swapped` events with prior/new boot counts at every cold boot |
| Lambda logs `connection-coordinator` / `heartbeat-processor` (30 d) | every MQTT connect (40–81 per day) and exact heartbeat times (hourly, 25 retries in 15 hours) |

`battery_pct` is the firmware's OCV lookup (`battery.c` generic LiPo table, §C43), so it inverts exactly to millivolts; the mV figures below are that inversion. Charger: nPM1300 term 4.20 V / 675 mA (Thingy:91 X board DTS), cell LP803448 ≈ 1350 mAh nominal.

## 2. Timeline

| Date (UTC) | Event | Battery |
|---|---|---|
| 07-24 21:25 | Activated for the current user after a full, settled charge | 98.0 % / 4184 mV |
| 07-31 15→23 | **Offline 8 h** (device-local: GS0002000001 heartbeated every hour), then a fatal → reboot (`fatal` 0→1) | −4.3 pts in 8 h ≈ **7 mA** |
| 08-16 19:00 | Fatal → immediate reboot (`fatal` 1→2) | 14 % |
| 08-17 21:46 | `battery_low` (9.9 %) · 08-21 21:17 `battery_critical` (4.5 %) | |
| 08-23 ~07:00 | Last heartbeat → **dead #1**. Boot count 8 → 1310 inside the dead window = **1,302 brownout boots in 6.4 days** | 0.7 % / ~3.14 V |
| 08-29 16:29 | Recharged, but only to 24 % → 33 % | partial |
| 08-31 18 → 09-01 19 | **Offline 25 h**, then fatal → reboot (`fatal` 2→3); no sessions survived that window | −14.6 pts ≈ 197 mAh ≈ **8 mA** |
| 09-01 19:11 | `battery_low` · 09-05 22:36 `battery_critical` | |
| 09-06 ~21:00 | **Dead #2** | 0.8 % / ~3.16 V |
| 09-13 20:43 | Brief power-on (2 heartbeats at 1.5 %); boot count 1312 → 1389 (**77 more brownout boots**) | |
| 09-20 21:55 | Recharged to 96 %, unplugged before the CV phase settled (−55 mV in the first 6 h) | ≈ 89 % settled |
| 09-22 19:19 | Latest heartbeat | 81.8 % / 4042 mV |

Alert → action lag: low alert to dead 5.4 d / 5.1 d; dead to recharge **6.4 d and 14 d**. The alerts exist (D2C dashboard shows the walker user their own battery alerts; APP-06 outbound delivery is still a stub) but nobody acted on them in time.

## 3. Discharge behaviour

| Cycle | From | To | Days | Avg | Usage (sessions/d · active min/d) |
|---|---|---|---|---|---|
| 1 — full | 07-24 21:00 · 98.0 % · 4184 mV | 08-23 07:00 · 0.7 % · 3140 mV | **29.4** | 3.31 pts/d · 35 mV/d | 47 · 64 |
| 2 — partial | 08-29 20:00 · 33.4 % · 3694 mV | 09-06 21:00 · 0.8 % · 3160 mV | 8.0 | 4.05 pts/d (2.6 without the 25 h offline loss) | 40 · 47 |
| 3 — current | 09-20 21:00 · 96.1 % · 4169 mV | 09-22 19:00 · 81.8 % · 4042 mV | 1.9 | 7.5 pts/d (charge relaxation) · last 24 h: 2.6 pts, 31 mV | 38 · 43 |

**Time to traverse each voltage band, cycle 1** (the honest shape of the curve — the generic OCV table under-reads the 3.80→3.69 V plateau and over-reads the tail):

| 4120→4042 | 4042→3900 | 3900→3800 | 3800→3694 | 3694→3600 | 3600→3500 | 3500→3400 | 3400→3300 | 3300→3160 mV |
|---|---|---|---|---|---|---|---|---|
| 2.4 d | 3.7 d | 3.1 d | **7.2 d** | 3.9 d | 4.9 d | 1.2 d | 0.6 d | 0.5 d |

Cycle 2 over the same bands from 3694 mV: 3.0 / 2.8 / 1.7 / 0.5 / 0.1 d — faster only because the 25 h offline episode (≈ 15 pts) fell inside it; usage was lower than cycle 1. Below ~3.5 V (≈ 7 %) the cell has ~2 days left; below 3.3 V, hours.

**Where the hours go (cycle 1, 15–93 %):** quiet hours (no walking, one heartbeat) drain **0.071 pts/h** (n = 191); hours containing walking drain **0.193 pts/h** (n = 289, ≈ 9.6 such hours/day). That splits a day into ≈ 1.7 pts always-on baseline (idle electronics + hourly heartbeat connects) and ≈ 1.2 pts walking-related (session uploads, 100 Hz BMI270, green LED) — roughly **60 / 40**. A day-level regression of drop vs active minutes finds no usage slope at all within 25–140 active min/day (R² 0.10, sign negative; day-to-day noise ±2 pts): **the fixed cost dominates, so a quieter user would not buy much life.**

Why the fixed cost is high:

- **~70 connections/day**, not the 32 the §C38 bench model assumed: 24 hourly heartbeats + **38–47 session uploads** (one connect/publish/disconnect per session close; sessions are fragmented — median 0.8 min, p90 4.8 min, `AUTO_STOP_STATIONARY_S = 15`). Coordinator logs confirm 40–81 connects/day.
- **Cell-edge signal:** RSRP median −107 dBm, p10 −121; 48 % of hours ≤ −110 dBm, 12 % ≤ −120; three `signal_lost` alerts at −125/−127. Every connect runs at max TX power with long attach/TLS times, i.e. at or above the top of §C38's 0.15–0.40 mAh/connection range.
- Session LED on ≈ 66–90 min/day and BMI270 resumes ~45×/day are second-order.

The §C38 bench projection for this build was 58–89 days; the field delivers 29. The gap is entirely connection count × connection energy at this signal level.

## 4. Two failure modes that cost more than the drain rate

1. **Offline → ~8 mA → §C62 crash.** Twice (07-31, 08-31) the device lost the cloud for 8 h and 25 h, drew ≈ 7–8 mA the whole time (modem out of PSM, searching/re-attaching) and ended with the LittleFS fatal from `2026-07-31-session-storage-exhaustion.md` (`fatal` counter +1 each time, `watchdog_hits` 0, sessions from the window lost). Cost ≈ 19 pts ≈ 250 mAh ≈ **19 % of a charge in 33 hours.**
2. **No low-battery cut-off → brownout boot loop.** Firmware runs the cell down to ~3.1 V, then the nRF9151 boot-attaches, sags, resets and repeats: 1,302 boots in the first dead window, 77 in the second. The cell sat below 3.1 V for 6 and 14 days. Capacity loss is plausible but not yet provable from this data (cycle 3 tracks slightly faster at the top, slightly slower in the last 24 h; the interrupted charge confounds it).

## 5. Life estimate

- **Measured:** 29.4 d full → dead (cycle 1). Hang-corrected ≈ 31 d.
- **This user, this signal, a full settled charge:** **28–32 days** (usage is now ~20 % lighter than cycle 1, but usage barely moves the number).
- **The charge on it now (09-20, not settled ≈ 89 %):** ≈ 24–28 d → **dies 2026-10-14 … 10-18**, central 10-16, assuming no offline episode (each costs 1–2 days). Check-points: 3.80 V (50 %) ≈ Sep 29, 3.69 V (35 %) ≈ Oct 6, `battery_low` ≈ Oct 12. Dying > 3 days early confirms capacity damage from the brownout episodes.
- **Average current ≈ 1.75–1.85 mA**, i.e. exactly the §C38 "1.875 mA = 30 days" ceiling.

## 6. Levers (estimated, in order)

| # | Change | Expected effect |
|---|---|---|
| 1 | **Batch session uploads into the hourly heartbeat** (queue the ~256 B derived record; publish with the next heartbeat). Same mechanism as the §C62 fix. | −45 connects/day → −25…35 % drain → ~40 d |
| 2 | **Low-battery policy:** ≤ 5 % stop uploads/sessions, heartbeat every 6 h; ≤ 2 % send a final heartbeat and enter nPM1300 ship mode. | Ends the boot loop; protects the cell; gives the family a clean "charge me" signal |
| 3 | **Offline back-off:** when registration fails, sleep the modem 15–30 min between attempts instead of searching continuously. | Offline cost 8 mA → <1 mA; also stops feeding §C62 |
| 4 | **Session hysteresis:** `AUTO_STOP_STATIONARY_S` 15 → 60–120 s. | Fewer sessions (fewer uploads, fewer BMI270 wakes), better activity data |
| 5 | Heartbeat 1 h → 2 h | −12 connects/day ≈ −10…15 %; offline-detection latency 2 h → 4 h (ARCH threshold) |
| 6 | Antenna / placement (median −107 dBm is cell edge) | each ~6 dB ≈ halves per-connect energy |
| 7 | Deliver battery alerts to the Care Circle (APP-06 stub) | turns a 6–14 day dead window into hours |

1 + 3 + 4 together plausibly double life to ~60 days; months require rethinking connection cadence (e.g. 6-h heartbeats with PSM ≈ 100 d), which is a product trade against offline detection.

**Onomondo SoftSIM (asked about 2026-09-22):** Onomondo/Nordic's published figure is that a physical SIM adds ≈ 46 µA average in idle (module idle 52 → 9.5 µA with SoftSIM), i.e. ≈ 1.1 mAh/day ≈ 0.4 Ah/year at most — and less for us because the nRF91 powers the UICC down during PSM sleep, so the saving is mostly the per-wake SIM re-init. That is ~2 % of today's budget and ~8 % of Tier A: not a battery lever until the floor is genuinely down at tens of µA. Its real value is BOM/board area (no SIM holder on a custom cupholder_v1 PCB) and logistics (profile provisioned through Onomondo's API instead of carrier-registering physical SIMs — the §C-bring-up gotcha). Cost: the module (`onomondo/nrf-softsim` v6.x) requires **NCS ≥ 3.4.0** (we are on 3.2.4), a 32 kB `nvs_storage` partition, TF-M PSA persistent keys, a dedicated 10 kB-stack work queue, `AT%CSUS=2`, and a per-device UART provisioning step with `onomondo-softsim-cli`. Verdict: park it with the custom-board/NCS-upgrade work; do not spend it on the battery problem.

**Cloud-only quick win:** emit `battery_mv` (already in every heartbeat/Shadow) as a per-device metric next to `BatteryPct`, so future curves are read in volts without the OCV-table artefacts.

---

## 7. Calibrated energy model (fleet cross-check, 2026-09-22 later)

Adding the other six units (four production, two bench; 455-day hourly history) separates the three costs the single-device data could not:

| Evidence | Value |
|---|---|
| **Idle floor** — GS0002000003 / GS0002000004 sat unactivated for 56–58 days (24-h safety-net heartbeat only, 1.8–2.5 hb/day, no walking): 1.15 and 1.06 pts/day | **≈ 14 mAh/day ≈ 0.6 mA**, 24/7 — vs the ≈ 0.05–0.07 mA the shipping-mode design (§C40) assumed |
| **Per heartbeat connect** — bench units GS9999999981/98 at 24 hb/day and 1–6 sessions/day: 1.42–1.62 pts/day (19–22 mAh) minus the floor, over 22 extra connects | **0.23–0.34 mAh** at −90…−100 dBm; GS0002000005's quiet hours give **0.35 mAh** at −108 dBm |
| **Per session** — day-weighted fit over 10 segments, drop = 1.42 + 0.046 × sessions/day (R² 0.86); GS0002000005's own hourly split | **0.35–0.6 mAh per session** (upload connect ≈ 0.3 + sampling/LED/flash ≈ 0.1–0.15 for a 2-min session); GS0002000005 ≈ 0.45 |

Two-term fit across the same segments (drop = 1.38 + 0.034 × sessions/day + 0.0055 × session-min/day, R² 0.93): **≈ 0.45 mAh per session** (the upload connect + BMI270 wake) and **≈ 0.073 mAh per recording minute ≈ 4.4 mA while a session is open** (LED + 100 Hz sampling + raw-sample flash writes).

**GS0002000005's 44 mAh/day, decomposed:** idle floor 14 (32 %) · 24 heartbeats 8.4 (19 %) · 47 session uploads ≈ 14 (32 %) · sampling + green LED + flash ≈ 7 (16 %). The bench "58–89 days" model missed all three: the floor is 9× its assumption, connections are 70/day not 32, and each costs the top of its range at cell edge.

**Why the floor is 0.6 mA (leading suspect, config-confirmed, bench-unverified):** the deployed image (`build_rollator_gs0002000005/gosteady-firmware/zephyr/.config`) has `CONFIG_SERIAL=y`, `CONFIG_UART_CONSOLE=y`, `CONFIG_LOG_BACKEND_UART=y`, `CONFIG_UART_INTERRUPT_DRIVEN=y` and no `CONFIG_PM_DEVICE` — the console UARTE stays enabled with RX armed, which on nRF91 keeps the high-frequency clock domain up at roughly 0.4–0.7 mA. That alone matches the measured floor minus the expected ~0.07 mA of PSM modem + PMIC + ADXL367 + bridge MCU. Verify before betting the battery size on it (§9). Also confirmed from the config: no RAI (`CONFIG_LTE_RAI_REQ` unset), system mode `LTE_M_NBIOT_GPS` (offline searches sweep NB-IoT too), PSM requested 3 h / 2 s, eDRX not requested.

## 8. Highest-value optimizations (GS0002000005 profile: 47 sessions, 90 walking-min, cell-edge signal)

| # | Change | Mechanism | Saving (mAh/day) | Cost / risk |
|---|---|---|---|---|
| 1 | **Field builds: console/UART off** (`CONFIG_SERIAL=n`, `UART_CONSOLE=n`, `LOG_BACKEND_UART=n`, or `PM_DEVICE` + suspend uart0 after boot); keep RTT/flash forensics | 0.6 → ~0.1 mA floor | **−11 to −12** (−27 %) | Loses the bench console in field images (use a bench overlay). Must be measured (§9). |
| 2 | **Batch session uploads into the heartbeat** — session end writes a ~256 B derived record to a flash queue; the hourly connect drains it. This is the §C62 fix. | −45 connects/day × ~0.3 mAh | **−13** (−30 %) | Data latency ≤ 1 h. Sessions survive reboot; removes the offline-crash path. |
| 3 | **RAI on the last publish + TLS session resumption** on the remaining connects | shorter RRC tail, no full handshake | **−3** (0.35 → ~0.22 mAh/connect) | AS-RAI needs Rel-14 support at the carrier; resumption is a modem socket option. |
| 4 | **Heartbeat 1 h → 2 h** | 12 fewer connects | **−2.6** (after #3) | Offline/dead detection 2 h → 4 h, downlink cmd latency ≤ 2 h. |
| 5 | **Session LED off** (`CONFIG_GOSTEADY_SESSION_LED=n`; it was only on because of the §C38.6 bench request) | recording draws ≈ 4.4 mA (fleet fit, §7); the LED is the larger part of it — Thingy:91 X drives the RGB LED through a transistor with 39–100 Ω series resistors | **−3 to −5** now; ≈ a quarter of the optimized budget later | One-line conf change; a 50 ms blink at session start costs nothing if a cue is still wanted. |
| 6 | **Session hysteresis** `AUTO_STOP_STATIONARY_S` 15 → 60–120 s | 47 → ~15–20 sessions/day | −1 after #2 (−8 without it) | Mainly data quality (whole walks, not 0.8-min fragments). |
| 7 | Gyro off during sessions (algorithm is accel-only) | BMI270 ~0.4 mA × 1.5 h | −0.6 | none |
| 8 | **Offline back-off + low-battery policy** (sleep the modem 15–30 min between failed attaches; ≤ 5 % uploads off / 6-h heartbeat; ≤ 2 % final heartbeat + nPM1300 ship mode) | stops the 8 mA offline drain (≈ 250 mAh per 60 days at this site ≈ 1.5 Ah/year) and the brownout boot loop | 0 steady-state; **≈ −4/day equivalent** here | Mandatory for any one-year claim; also protects the cell. |
| 9 | Heartbeat 2 h → 6 h (product decision) | 4 connects/day | −1.8 more | Dead-device detection 12 h. |

**Resulting daily budgets** (LED off; idle residual 0.1–0.15 mA = 2.4–3.6; connect 0.22 mAh; recording with LED off ≈ 1.5–2.5 mA × 95 min ≈ 2–3; session overhead ≈ 0.5; time-sync/fuel-gauge/ADXL ≈ 1):

| Tier | Contents | mAh/day | On today's 1350 mAh cell |
|---|---|---|---|
| Today | as deployed | 44 | 29 d (measured) |
| A | #1 #2 #3 #5 #6 #7 #8, hourly heartbeat | **11–13** | ~100–120 d |
| B | A + 2-h heartbeat (#4) | **8–10** | ~130–170 d |
| C | B + 6-h heartbeat (#9) | **7–8** | ~170–190 d |

Firmware alone therefore reaches a season, not a year, on the present cell. Session count stops mattering once uploads are batched; walking minutes (sampling) and signal (connect energy) remain the user-dependent terms.

## 9. Battery size for one year (after optimization)

Annual energy = daily × 365 plus a 0.3 Ah coverage-loss reserve (with #8 in place). Nominal capacity = that ÷ (usable depth 0.92 × charge lost sitting a year 0.88 = 0.81) × 1.25 design margin, i.e. **nominal ≈ 1.54 × (annual + 0.3 Ah)** at 3.6–3.7 V. (Revised 2026-09-22 after review: the earlier 1.87 stacked self-discharge and calendar aging, which overlap — the irreversible part of self-discharge *is* calendar fade — and a cold-weather factor that does not fit a device used at home.)

Worked example, Tier A midpoint (12 mAh/day):

| Step | Factor | Ah |
|---|---|---|
| Electronics draw over 365 days | 12 mAh × 365 | 4.35 |
| + reserve for coverage-loss episodes (with the offline back-off in place) | + 0.3 | 4.65 — what the pack must actually deliver |
| ÷ usable depth (stop at 3.3 V under load, keep 2 % for the ship-mode beacon) | ÷ 0.92 | 5.05 |
| ÷ charge lost sitting a year on one charge — reversible self-discharge **and** calendar fade together (Li-ion at room temperature, ≈ 10–15 %) | ÷ 0.88 | 5.74 — best estimate, no margin |
| × design margin for model uncertainty (connect energy at cell edge, floor residual, user variance ±30 %) | × 1.25 | **7.2 nominal** |

A pack topped up mid-year loses most of the sitting-loss term. The margin is a policy choice: without it, Tier A is a ~5.7 Ah pack.

| Tier | Annual (Ah) | **Nominal pack** | Energy | Example |
|---|---|---|---|---|
| A (hourly heartbeat) | 4.0–4.7 | **≈ 6.5–7.5 Ah** (5.3–6.2 without margin) | ~26 Wh | 2 × 18650 (3.5 Ah) or one 7 Ah pouch, ~100 g |
| B (2-h heartbeat) | 2.9–3.7 | **≈ 5–6 Ah** (4.0–4.9 without margin) | ~20 Wh | one 21700 (5 Ah) is the no-margin point; 2 × 18650 (3 Ah) with margin |
| C (6-h heartbeat) | 2.5–2.9 | **≈ 4.5–5 Ah** (3.5–4.0 without margin) | ~17 Wh | one 21700 (5 Ah) |
| Today's firmware, LED off only | 14.6 (+1.5 offline) | ≈ 25 Ah | 90 Wh | not a product — the LED alone is ~10 % |

**The pivot is #1.** If the 0.6 mA floor is hardware rather than the console (e.g. the nRF5340 bridge or a regulator left on), add 0.5 mA × 8,760 h = 4.4 Ah/year → **+7 Ah nominal**: Tier B becomes a ~12 Ah pack. A 10-minute bench measurement decides between an 8 Ah and a 16 Ah battery.

Primary-cell options (the PRD's "replaceable" direction): a D-size Li-SOCl₂ (3.6 V, 17 Ah, ~61 Wh) with a hybrid-layer capacitor for LTE bursts covers Tier A with margin and is swapped yearly; 6 × lithium AA (L91, 3S2P ≈ 31 Wh) covers Tier B; alkaline AA is unsuitable under LTE-M pulse loads. Any of these replaces the nPM1300 Li-ion charge path with a buck/boost front end — a hardware change, not a firmware one.

## 10. What to measure this week (cheap, decisive)

1. **Idle floor on the bench:** a unit on battery (`vbus=0`), activated, no motion, between heartbeats — read the nPM1300 `AVG_CURRENT` line the `LOW_POWER` build already logs, then flash the same image with `CONFIG_SERIAL=n`/`UART_CONSOLE=n` and compare via a PPK2 or the Shadow slope over 48 h. Expect 0.6 mA → ≤ 0.1 mA.
2. **Per-connect energy at cell edge:** PPK2 trace of one heartbeat at −105…−110 dBm, with and without RAI/TLS resumption.
3. **Cycle 3 tracking on GS0002000005:** 3.80 V ≈ Sep 29, 3.69 V ≈ Oct 6, dead ≈ Oct 16 — an early death confirms cell damage from the brownout episodes and argues for #8 first.

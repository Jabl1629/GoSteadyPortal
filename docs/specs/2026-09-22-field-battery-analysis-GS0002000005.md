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

**Cloud-only quick win:** emit `battery_mv` (already in every heartbeat/Shadow) as a per-device metric next to `BatteryPct`, so future curves are read in volts without the OCV-table artefacts.

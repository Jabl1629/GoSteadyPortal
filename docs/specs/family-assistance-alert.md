# Family Assistance Alert — button → speaker → cloud → Care Circle voice + SMS (umbrella spec)

> **Status:** 🟡 **Draft v0.4 — 2026-09-18 (evening); PRD V2.3 Draft applied 2026-09-22 (§15).** **Direction change:** the DFR0534 speaker is retired (size + BOM; family-only notification does not need speech). Feedback is now a **SparkFun Qwiic Buzzer** on the P1 Qwiic connector: **20 s of beeps before the request goes out; press-and-hold 3 s cancels.** Firmware feedback layer + hold-to-cancel state machine written and compiling (coord §C64); buzzer on order; the speaker path stays selectable as an archived option (bench-proven, §C63.6). PRD V2.3 amendment text in §15. No cloud code. Written against **PRD V2.2 Draft (2026-09-18) §5** (the product authority for this feature) and the repo evidence surveyed the same day (firmware `main`@`55dbf92`, portal `feature/infra-scaffold`@`1f2c784`).
> **Scope:** A deliberate assistance button on the rollator device that (1) gives the walker user audible feedback through a small buzzer, (2) publishes an assistance request with best-available location over LTE-M, and (3) makes the cloud **concurrently call (Retell) and text (Twilio) every enrolled Care Circle member**, tracking delivery and acknowledgement in a durable incident record. **Care Circle only — no monitoring center, no EMS dispatch, no fall detection.**
> **Spans:** firmware (`gosteady-firmware`), cloud (`infra/`), consumer app (`lib/d2c/`), hardware prototype (Thingy:91 X + SparkFun Qwiic Buzzer BOB-24474).
> **Depends on (deployed):** Core Device Contract v1 (`activate`/`wipe` cmds, `last_cmd_id` echo, connection-coordinator), 1A/1B ingestion, D2C auth pool + claim, Care Circle (`d2c-care-circle.md`), Twilio SMS (`_shared/sms.py`), 1.7 audit, 2A-AA ack.
> **Adjacent gaps this feature does NOT fix but is gated by:** session-storage exhaustion (firmware spec `2026-07-31-session-storage-exhaustion.md`, coord §C62) and outbound alert delivery (PRD APP-06, Phase 2C stub). See §9.
> **Related:** [ARCHITECTURE.md](ARCHITECTURE.md) §4/§6/§7, [2026-07-01-device-types.md](2026-07-01-device-types.md) (Core vs per-type contracts), [d2c-care-circle.md](d2c-care-circle.md), [d2c.md](d2c.md), [phase-1c-slim-notifications.md](phase-1c-slim-notifications.md), coord doc §C63.

---

## 0. In one paragraph

The walker user presses the large actuator on the cupholder. The device chirps back within a few hundred milliseconds, lights its LED, and starts a **20-second beep countdown**: one beep per second, a double beep per second after 10 s, rapid beeps in the last 3 s. Meanwhile it brings the modem out of PSM and opens its MQTT session. **Pressing and holding the button for 3 seconds at any point cancels** (a steady low tone confirms the hold is registering, then a falling two-note says "cancelled"); nothing is sent. At 20 s it publishes an `assistance_request` (unique incident id, press + send timestamps, battery/radio, and whatever location it has — usually *none yet*) on a new, policy-restricted topic `gs/{serial}/assist`. The cloud writes a durable incident, projects it into the D2C dashboard as a critical alert, enqueues one voice-call job and one SMS job **per enrolled member**, and only then sends an authenticated `assist_ack` downlink — which is what makes the device play its rising "contacted" tone. Retell then places the calls and Twilio sends the texts, both stating plainly that this is a family notification and not emergency services; webhooks record who answered / got voicemail / was delivered. After the ack, the device runs a bounded GNSS acquisition and publishes a follow-up location, which triggers one follow-up SMS with a map link. Care Circle members tap "I'm on it" in the app; the incident closes when a member marks it resolved. A test mode, armed from the app, exercises the exact same path but routes only to the tester.

```
 Rollator user                 Device (nRF9151 + Qwiic Buzzer)            AWS                              Care Circle
 ─────────────                 ──────────────────────────                 ───                              ───────────
 press ──────────────────────▶ T0   power buzzer, chirp, 1 Hz beeps
                               T0   wake modem, MQTT connect (PSM exit)
                               T10  double beeps; T17 rapid beeps
 (hold 3 s = cancel)           T20  PUBLISH gs/{serial}/assist ──────────▶ assistance-dispatcher
                                                                          • put incident (idempotent)
                                                                          • project Alert History row ───▶ dashboard card
                                                                          • enqueue voice+SMS per member
                               ◀──────────────────── cmd: assist_ack ◀──── • publish ack (cmd topic)
                               rising "contacted" tone                    assistance-notifier (SQS)
                               GNSS single fix (≤180 s) ──▶ event:location  • Retell create-phone-call ─────▶ voice call
                                                                          • Twilio SMS (+status cb) ──────▶ text
                                                                          webhooks ◀── Retell / Twilio    "I'm on it" ──▶ ack
```

---

## 1. Requirements traceability (PRD V2.3 §5 → this spec)

| PRD ID | Requirement (abridged) | Where satisfied | Phase |
|---|---|---|---|
| AST-HW-01 | One large tactile actuator mechanically operating the Thingy:91 X center button | §4.2 (Button 1 = SW3 on P0.26; also the MCUboot recovery button — §4.6) | FA-0 (mech: enclosure track) |
| AST-HW-02 | Resist false actuation during rolling/braking/transport | §5.2 debounce + deliberate-press gesture; §10 T-rows; enclosure track | FA-6 |
| AST-HW-03 | ~~Speaker: intelligible speech~~ → **buzzer with distinct cadences** for countdown / cancel / ack / test / fault (PRD V2.3) | §4 Qwiic Buzzer; §5.3 pattern set | FA-0/FA-1 |
| AST-HW-04 | Ingress/cleaning/structure preserved with actuator + buzzer sound port (PRD V2.3) | Enclosure track (out of firmware/cloud scope; listed as gate) | FA-6 |
| AST-FW-01 | Validated press → Assistance Pending; start LTE + GNSS work; 20 s cancel window | §5.2 state machine (**hold 3 s to cancel**); §5.5 GNSS/LTE coexistence (why "LTE first, GNSS after ack") | FA-1 |
| AST-FW-02 | ~~Exact spoken prompts, second-press cancel~~ → **beep cadence phases at T0/T10/T17, press-and-hold 3 s cancels with distinct feedback** (PRD V2.3) | §5.2 timeline, §5.3 patterns | FA-1 |
| AST-FW-03 | Publish `assistance_request` with incident id, identity, timestamps, battery/radio, best location | §5.4 payload contract | FA-1/FA-2 |
| AST-FW-04 | Confirmation feedback only after **authenticated** ack that cloud durably accepted + started workflow; bounded retry + failure feedback; priority over routine traffic | §5.4 ack semantics; §5.3 confirmed/failed patterns; §6.3 dispatcher ordering; §5.10 priority path | FA-1/FA-2 |
| AST-FW-05 | No fix ⇒ still send; send stale fix with age; `location_status` acquiring/unavailable; follow-up location update | §5.5 location ladder; §6.3 `event:location` | FA-5 |
| AST-FW-06 | Test mode end-to-end without notifying live contacts unless enrolled as test recipients | §6.3 test arming (cloud-armed, device path identical; four-note "test complete" tone); §7 | FA-3/FA-4 |
| AST-SW-01 | One durable incident per confirmed request; concurrent routing to every enrolled member | §6.4 incident table; §6.6 fan-out | FA-2/FA-3 |
| AST-SW-02 | Each member gets both a Retell call and an SMS; channels independent | §6.6 (one SQS job per member × channel) | FA-3 |
| AST-SW-03 | Both channels include best GPS info + capture time; voice human-readable location; SMS map link + accuracy + age | §6.8 geocoding; §8 copy | FA-3/FA-5 |
| AST-SW-04 | No fix ⇒ say so; follow-up **text** when fix arrives; no second call required | §6.3 `event:location` → one follow-up SMS | FA-5 |
| AST-SW-05 | Verified phones, explicit opt-in + location consent, per-member call/SMS prefs; ≥1 eligible contact before "ready" | §6.5 data model; §6.3 readiness; §7 settings UI | FA-4 |
| AST-SW-06 | Incident preserves initiation/cancel, ack, location updates, call attempts + outcomes, SMS outcomes, member acks, closure, reconciliation | §6.4 schema; §6.7 webhooks | FA-2/FA-3 |
| AST-SW-07 | Never route to a monitoring center/EMS; copy must not imply it | §8 copy; §7 agreements; L4 | all |
| AST-OPS-01 | Supervise Retell + SMS independently of device heartbeats (synthetic tests, webhooks, credential checks) | §6.12 synthetic canary + alarms | FA-3 |
| AST-OPS-02 | Hourly heartbeat = readiness; 2 consecutive misses ⇒ not-recently-connected ⇒ **actionable** service notification | §6.12; §9 FA-3b (owner SMS for `device_offline`/`device_silent`) | FA-3b |
| AST-OPS-03 | Show last successful end-to-end test; prompt a test at activation + recurring | §7 readiness card; `Patient.assistance.lastTestAt` | FA-4 |
| AST-OPS-04 | Measure button→ack, GNSS TTFF/freshness, call acceptance/answer, SMS send/delivery, member ack, heartbeat compliance, retries, test completion | §6.12 metrics list | FA-2/FA-3 |

PRD §7 release gates that this spec owns are restated as exit criteria in §9 (FA-6). Gates it does **not** own (storage exhaustion, transport exclusion, battery claim, OTA decision) are listed in §9 "Prerequisites".

---

## 2. What we are building on (surveyed 2026-09-18)

### 2.1 Firmware (`gosteady-firmware`)
- **Button:** `sw0` = Button 1 (SW3) on **P0.26**, active-low with pull-up. `main.c` registers a GPIO edge ISR that only gives a binary semaphore; the main loop consumes it once per second and toggles a *session* (bench behaviour). **In every shipping overlay (`GOSTEADY_FIELD_MODE=y`) the button is never configured** — the ISR is not registered. Session start also refuses in pre-activation (`-EACCES`). The assistance path must not route through session start.
- **LEDs:** plain GPIO on P0.29/30/31; conventions: blue 1 Hz pulse = pre-activation wake window, solid green 3 s = activation confirmed, solid green = recording (when `SESSION_LED`). Helpers block the calling thread; nothing arbitrates LED ownership.
- **Cloud (`cloud.c`):** one `aws_iot` session guarded by `s_aws_mutex`; publishes are QoS 1 with a 30 s PUBACK wait; normal cycle is connect → publish → **1.5 s linger** → disconnect. The pre-activation wake window uses `connect_publish_stay()`, which publishes and then **holds the connection polling a flag every 500 ms** — the exact primitive an "await ack" needs. Downlink `gs/{serial}/cmd` is re-subscribed on every connect and dispatched (`json_obj_parse`) synchronously on the library thread: `activate`, `wipe`, unknown → warn. There is **no priority queue**; heartbeat and activity are peer threads racing for the mutex. Activity backlog is RAM-only, 4 deep (the `telemetry_queue` partition is carved, unimplemented).
- **Cellular:** `lte_lc_connect_async`, PSM requested (granted TAU 3 h / active 2 s); the modem stays PSM-registered between hourly heartbeats, so a wake-to-publish is seconds, not a fresh attach. RSRP/SNR via `AT+CESQ`/`%XSNRSQ`. **No GNSS code anywhere.** The `lte_link_control` default system mode (`LTE_M_NBIOT_GPS`) is not overridden, so GNSS is already in the modem system mode.
- **Budget:** rollator deployment build (`prj_rollator_pilot.conf`) = **63.05 % RAM (143,760 / 227,992 B)**, flash 26 %. Snippets are already off on the rollator for RAM. Pre-activation storage budget ≈ 48 mAh/month; **≈ 0.25 mAh per connect+publish cycle** is the reusable energy unit.
- **Version strings:** `rol-0.1.0-ww` (deployment); `.dat` header caps `firmware_version` at 15 chars.

### 2.2 Cloud (`gosteady-portal/infra`)
- **Topics + policy:** per-thing policy `gosteady-{env}-device-policy` allows publish on `heartbeat|activity|alert|snippet` and subscribe on `cmd` only; explicit ARN list, **~1558 B of the 2048 B hard limit**. Adding one more publish topic is affordable (~+95 B).
- **Device alerts:** `alert-handler` validates `ts/alert_type/severity` and dispatches the per-type enum from `_shared/device_types/`; **`rollator_platform.VALID_ALERT_TYPES` is empty** — any rollator alert publish rejects today.
- **Downlink pattern:** `{"cmd","cmd_id","ts"}` on `gs/{serial}/cmd` (QoS 1), cmd_id prefix (`act_`, `wipe_`) drives ack dispatch in `heartbeat-processor` (unknown prefixes are logged and skipped — forward-compatible), outstanding-cmd maps on the Device Registry row, Shadow `desired.*` mirror, and the **connection-coordinator** republishes outstanding cmds on every `$aws/events/presence/connected` (MQTT 3.1.1 persistent sessions expire after 1 h, so "publish once" is not delivery).
- **SMS:** `_shared/sms.py: send_sms(to_e164, body)` (stdlib urllib → Twilio Messages API; secret `gosteady/{env}/twilio`, env `TWILIO_SECRET_ARN`; from-number or Messaging Service auto-detected). **No delivery-status callback, no STOP handling, no message-SID persistence.** Live sender is a toll-free `+1833…` number.
- **Care Circle:** members are `RoleAssignments` rows (`household_owner` | `family_viewer`) under the household `clientId = dtc_{householdId}`; **`RoleAssignments.phone` holds the raw verified E.164** (CMK-encrypted, never returned by any API) — the dialable source for fan-out. No member cap (only `MAX_PENDING_INVITES=10`). An account-less walker is synthesized into the roster with **no phone**.
- **Notification stack:** `notification-stack.ts` is a scaffold with no resources. **No outbound alert delivery exists**; `Users.notificationPrefs` is documented but unwritten. **No Retell / telephony code, secret, or config exists.**
- **Walker visibility:** `patient-api/queries.py: WALKER_VISIBLE_ALERT_TYPES` is a battery-only allow-list for `custom:isWalkerUser` — a new alert type is hidden from the walker unless added.
- **Pause:** `_shared/pause_check.py` suppresses threshold/behavioral alerts while `Patient.notificationsPaused` — an assistance request must bypass it (L7).
- **Conventions:** D2C audit events are local `d2c.*` literals in the owning Lambda; routes register under `/api/v1/d2c/*` behind the `D2CUserPoolAuthorizer`; feature flags are stack env literals read with `_env_bool(...)`; e2e scripts are `infra/scripts/e2e-{feature}.py` with synthetic JWT claims injected via `lambda.invoke`.

### 2.3 Consumer app (`lib/d2c/`)
Dashboard renders `openAlerts` as `_AlertCard`s with an ack action; screens: dashboard, history, care team, coach, account; `D2CRepository` (mock + live) + `ApiClient` with `/api/v1/d2c` read prefix; routes in `d2c_routes.dart` / `d2c_app.dart`. A mock-only notification-prefs screen exists.

---

## 3. Locked-in requirements

| # | Requirement | Source | Consequence |
|---|---|---|---|
| L1 | **(amended 2026-09-18)** Feedback is a buzzer, not speech: 20 s beep countdown with phase changes at 10 s and 17 s; **press-and-hold 3 s cancels**; distinct tones for cancelled / contacted / test / failed / not-set-up (PRD V2.3, §15) | Product decision 2026-09-18 | No audio assets; cadences are firmware constants (§5.3) |
| L2 | The "contacted" tone plays **only** after an authenticated cloud ack that the incident is durable **and** the notification workflow has started | AST-FW-04 | Ack is sent by the dispatcher after PutItem + SQS enqueue succeed; broker PUBACK is **not** sufficient |
| L3 | Assistance traffic has priority over heartbeat/activity/snippet traffic | AST-FW-04 | New "priority-0" publish path opens its own cellular cycle and may reuse a live session (§5.10) |
| L4 | Care Circle only. No monitoring center, no EMS, no professional-response language anywhere (copy, app, agreements) | AST-SW-07, PRD §6 | §8 copy includes an explicit "not emergency services" line in every channel |
| L5 | Not fall detection; tip-over telemetry (ACT-06) never initiates an assistance request | PRD §4.2 / §6 | The only trigger is the deliberate button press (or an app-armed test) |
| L6 | Core Device Contract v1 is extended, not forked: new uplink class `gs/{serial}/assist`, new cmds `assist_ack` / `assist_arm` using the existing cmd envelope + `last_cmd_id` echo + coordinator republish | DT4/DT5, ARCH §7.0 | No per-type topics; walker cap can adopt later unchanged |
| L7 | An assistance request bypasses `notificationsPaused` and threshold suppression | AST-SW-01 | Dispatcher never consults `pause_check` |
| L8 | The feedback device is **power-gated**; it draws nothing between incidents | DEV-09 (1-year battery target) | VDD_EXP_BRD load switch (P0.03) is the gate; §4.4 |
| L9 | Every member phone used for fan-out is verified (SMS-OTP possession) and the member has opted in per channel with recorded consent (TCPA prior-express-consent posture) | AST-SW-05 | Fan-out reads `RoleAssignments.phone` **only** for rows with `assistancePrefs.{voice|sms}=true` + `consentedAt` |
| L10 | Location data is identity-bearing: CMK-encrypted at rest, never logged in plaintext, retention bounded | ARCH §9/§10 | Incidents table is an `IdentityTable`; PII scrubber gains `lat/lon/latitude/longitude/phone/to_number` |
| L11 | D2C-first; facility channel out of scope for v1 | APP-07 | All routes under `/api/v1/d2c/*`; no facility UI |
| L12 | Feature is flag-gated end-to-end (`ASSISTANCE_ALERTS_ENABLED`) and the device only arms after cloud readiness | AST-SW-05 | A press on an un-armed device says *"Assistance is not set up yet."* and sends nothing |
| L13 | Test incidents are distinguishable end-to-end (`isTest`, `mode:"test"` in the ack, "TEST —" prefix in copy, separate Retell agent) | AST-FW-06 | Never notifies live contacts unless enrolled as test recipients |

---

## 4. Hardware — Qwiic buzzer on the P1 connector (v0.4)

### 4.1 Feedback device: SparkFun Qwiic Buzzer (BOB-24474)

| Item | Fact (SparkFun docs + firmware/library sources, read 2026-09-18) |
|---|---|
| What it is | 1.0″ × 1.0″ Qwiic board: ATtiny84 with a magnetic buzzer, two Qwiic (JST-SH) connectors, `TRIGGER` pin, PWR/STAT LEDs |
| Interface | I²C, default address **0x34** (changeable 0x08–0x77, saved to EEPROM). Register map: `0x00` ID = **0x5E**, `0x01/0x02` firmware minor/major, `0x03/0x04` tone frequency MSB/LSB (Hz), `0x05` volume (0 off … **4 max**), `0x06/0x07` duration MSB/LSB (ms; **0 = until ACTIVE is cleared**), `0x08` ACTIVE (write 1 to sound; **self-clears when the duration elapses**), `0x09` save settings, `0x0A` address |
| Loudest pitch | resonant **2730 Hz** |
| Power | 3.3 V; **~95 mA while sounding at volume 4**; the ATtiny only IDLE-sleeps between commands, so the board is **not** a µA device — hence L8 power gating |
| Boot | no startup beep; ready within tens of ms (firmware polls the ID register) |
| Jumpers | I²C pull-ups (2.2 kΩ, three-way), PWR_LED, STAT LED, JP1 (volume resistor) — cut PWR_LED/STAT for current measurements and production |
| Cost / lead | ~$9 board + a JST-SH Qwiic cable; production replaces the board with a **discrete magnetic buzzer + transistor** on the custom PCB (D20) |

### 4.2 Wiring — nothing to cut

| Board state | Bus | Overlay | Notes |
|---|---|---|---|
| **Unmodified Thingy:91 X** (every unit except the 2026-09-18 bench board) | P1 → TXS0102 → **i2c2** (SDA P0.09 / SCL P0.08), the sensor bus shared with the ADXL367 and nPM1300 | `boards/assist_buzzer_i2c2.overlay` | The production-representative wiring. Bus power = VDD_EXP_BRD via load switch U14, enable **P0.03** (`exp_board_enable`). With the board unpowered the TXS0102 keeps it off the 1.8 V bus |
| **Cut bench board** (SB8/SB9 opened for the speaker experiment) | P1 → TXS0102 → **P0.18 (SDA) / P0.19 (SCL)**, now isolated from i2c2 → a bit-banged I²C master (Zephyr `gpio-i2c`, open-drain) | `boards/assist_buzzer_bitbang.overlay` | Same `qwiic_buzzer` node, same driver, zero code difference — the cut board stays useful for bench work. **Not** representative of production wiring |

A plain Qwiic (JST-SH 4-pin) cable connects P1 to either of the buzzer's Qwiic sockets; polarity is keyed. The Qwiic-to-Gravity cable from the speaker experiment is no longer needed.

### 4.3 What the speaker experiment established (kept for the record)
- `EXP_BOARD_PIN1` = **P0.19**, `EXP_BOARD_PIN2` = **P0.18** (schematic PCA20065 v2.0.0) — dedicated GPIOs behind P1 pins 4/3; SB8/SB9 only bridge them onto SCL/SDA.
- The nRF9151 has **no spare UARTE** (uart2 ↔ i2c2, uart3 ↔ spi3). Irrelevant for an I²C buzzer; it is why any UART peripheral would have needed the uart1 re-pin.
- The DFR0534 path is bench-proven (module boot 570 ms, both UART directions, factory clips through the speaker) and stays selectable as `GOSTEADY_ASSIST_FEEDBACK_SPEAKER` with `boards/assist_audio_uart1.overlay` (coord §C63.6). It is not the product.

### 4.4 Power gating (unchanged)
The buzzer board rides VDD_EXP_BRD and is powered from the press to the end of the outcome tone, via the `exp_board_enable` regulator (P0.03). Between incidents the rail is off: zero standing current. BUCK2 (200 mA) also feeds LED1/LED2 and the GNSS LNA; 95 mA of buzzer is within budget but must be scoped once with GNSS active (FA-5).

### 4.5 Button (unchanged) and MCUboot recovery
Button 1 = SW3 on **P0.26**, active-low, and still `mcuboot-button0` with `CONFIG_BOOT_SERIAL_ENTRANCE_GPIO=y` in the deployment image — an actuator held during a battery swap enters serial recovery. Deployment images must set `CONFIG_BOOT_SERIAL_ENTRANCE_GPIO=n` (FA-1). With hold-to-cancel now a core gesture, note the two never overlap: recovery only samples the pin during MCUboot's first milliseconds after reset.

### 4.6 Enclosure implications
A buzzer needs a small sound port or acoustic membrane instead of a speaker grille and a 70 × 30 mm speaker pocket; the 25 mm buzzer board (or a 12 mm discrete element in production) fits beside the Thingy. Loudness at the user's ear through the enclosure is a FA-6 measurement (Q17). Ingress/cleaning requirements (AST-HW-04) carry over.

### 4.7 Bench measurements still owed (FA-0)
- Buzzer board current: off rail (expect 0), idle-powered, sounding at volume 4 (expect ~95 mA) — with PWR_LED/STAT jumpers cut.
- VDD_EXP_BRD and 1V8 during a volume-4 beep (rail sag).
- GNSS TTFF trials (unchanged from v0.1).

## 5. Firmware design (`gosteady-firmware`)

### 5.1 Module map

| File | New/changed | Responsibility |
|---|---|---|
| `src/assist.c/.h` | **written (v0.4)** | Incident state machine on its own thread (`gs_assist`, prio 6, 2 KB); debounce; **hold-to-cancel** (50 ms button polling, hold tone after 0.6 s, cancel at 3 s — including the initial press); cadence ticks; stub/real transport; ack wait + retry |
| `src/feedback.h` | **written** | Feedback abstraction: `begin/end`, `countdown_start/mid`, `tick(phase)`, `hold_tone(on)`, `cancelled`, `confirmed(test)`, `failed`, `not_setup`, `fault`, `selftest`; compile-time no-ops for LED-only builds |
| `src/feedback_buzzer.c` | **written** | Qwiic Buzzer backend: I²C register writes (5-byte burst from `0x03` + ACTIVE), power gate via the `exp_board_enable` regulator, ID check on power-up, pattern set (§5.3) |
| `src/feedback_speaker.c` + `src/audio_dfr0534.c/.h` | archived | DFR0534 spoken-prompt backend (bench-proven); selectable, not built by default |
| `dts/bindings/sparkfun,qwiic-buzzer.yaml` | **written** | Minimal binding so the `qwiic_buzzer` node resolves via `I2C_DT_SPEC_GET` |
| `boards/assist_buzzer_i2c2.overlay` / `boards/assist_buzzer_bitbang.overlay` | **written** | §4.2 |
| `src/gnss.c/.h` | planned (FA-5) | Single-fix acquisition around `nrf_modem_gnss_*`; last-fix cache |
| `src/cloud.c` | planned (FA-2) | `ASSIST_TOPIC_FMT "gs/%s/assist"`; priority publish + ack wait; `assist_ack` / `assist_arm` cmds; heartbeat extras `assist_capable`, `assist_armed`, `feedback_ok`, `gnss_fix_age_s` |
| `src/main.c` | changed | Button wired under `FIELD_MODE` when `GOSTEADY_ASSIST_ENABLE`; ISR → `gs_assist_button_isr()`; feedback init + optional boot self-test; LED handed to the assist thread during incidents |
| `src/wipe.c` | planned (FA-1) | Wipe clears `/lfs/assist/*` |
| `sysbuild/mcuboot.conf` | planned (FA-1) | `CONFIG_BOOT_SERIAL_ENTRANCE_GPIO=n` for deployment overlays (§4.5) |

### 5.2 State machine and timeline

States: `IDLE → PENDING (countdown) → SENDING → AWAIT_ACK → CONFIRMED → LOCATING → IDLE`, with `CANCELLED` and `FAILED_RETRYING` side exits. One incident at a time; a press during `SENDING/AWAIT_ACK/CONFIRMED` is ignored (logged).

| t (s) | Device | Feedback | Notes |
|---|---|---|---|
| 0.00 | ISR on the press edge; 50 ms debounce (pin re-read). Not armed → `not_setup` pattern, stop | red LED on; buzzer powered (ID reply within tens of ms); **"heard you" double chirp** | Deliberate press = ≥ 50 ms |
| 0.00 | Cloud connect starts (FA-2): PSM exit + TLS + MQTT if no live session | | Connect typically 3–10 s |
| 1 … 10 | `PHASE_EARLY` | one 120 ms beep per second | |
| 10.0 | `PHASE_LATE` | 250 ms phase-marker beep, then a double beep per second | |
| 17.0 | `PHASE_FINAL` | rapid 70 ms beeps every 350 ms | urgency without alarm |
| any | **Button held ≥ 0.6 s** → steady low tone (1500 Hz) replaces the cadence; released → cadence resumes. **Held ≥ 3.0 s → CANCELLED**: falling two-note, power off, LED off, **nothing sent**. The initial press counts: never releasing it cancels at 3 s (sustained accidental pressure cannot send) | | D18 — validate with older adults (FA-6) |
| 20.0 | Build payload (§5.4), persist `/lfs/assist/pending.json` (FA-1), PUBLISH on the session opened at T0; on PUBACK → `AWAIT_ACK` | LED red+blue | |
| 20–50 | Wait ≤ 30 s for `assist_ack` matched on `incident_id` | on ack: green LED, **rising three-note** (test mode: four notes) | Ack normally < 3 s after PUBACK |
| ack+0 | Echo `cmd_id` in the next heartbeat; persist `acked` | | |
| ack+0 | `LOCATING`: release RRC (RAI if available), GNSS single fix ≤ 180 s (FA-5) | buzzer already off | §5.5 |
| fix | Publish `event:"location"`; `IDLE` | | one follow-up per incident |
| no ack | Retry at +30 s, +90 s, +210 s (same `incident_id`, `seq`++); after the 3rd miss **deep double buzz**; stay in `FAILED_RETRYING` with the modem awake ≤ 10 min; then passive retry on every connect until acked or 24 h old | | bounded energy; cloud flags late arrivals |
| reboot | `pending.json` unacked ⇒ resume `FAILED_RETRYING` at boot (never re-run the countdown) | | survives the coord §C62 crash class |

Session interaction: the incident never starts/stops a session; `session_active` is reported in the payload only.

### 5.3 Feedback pattern set (buzzer)

Design intent for older-adult legibility: one cadence per phase, always at the loud resonant pitch; outcomes use **pitch movement** (rising = good, falling = cancelled, deep and long = trouble) so they are distinguishable without counting beeps. All values are firmware constants in `feedback_buzzer.c`; volume 4 unless noted.

| Event | Pattern |
|---|---|
| Press accepted | 2 × 80 ms at 2730 Hz ("heard you") |
| Countdown 0–10 s | 120 ms beep every 1 s |
| Phase change at 10 s | one 250 ms beep, then 2 × 100 ms beeps every 1 s |
| Final 3 s | 70 ms beeps every 350 ms |
| Hold registering (≥ 0.6 s) | steady 1500 Hz tone until release or cancel |
| Cancelled | 2200 Hz 180 ms → 1000 Hz 450 ms (falling) |
| Contacted (ack) | 1500 → 2200 → 2730 Hz, 130/130/220 ms (rising) |
| Test complete | the rising three plus a fourth 2730 Hz note |
| Failed / still trying | 1000 Hz 600 ms, twice |
| Not set up | 1500 Hz 250 ms, twice, unhurried |
| Fault (feedback device absent) | LED only; heartbeat `feedback_ok:false` |

The app shows the same table as "What the beeps mean" (§7). The archived speaker backend maps the same events to its spoken prompts (`audio/prompts/`), so the state machine is backend-agnostic.

### 5.4 Device-side cloud contract

**Uplink** — topic `gs/{serial}/assist`, QoS 1, ≤ 640 B, JSON built with the existing `snprintf`/`APPEND_OR_FAIL` pattern:

```json
{
  "serial": "GS0002000001",
  "event": "request",                         // request | location | cancel (optional, D9)
  "incident_id": "b7c1…-uuid4",               // generated at T0; constant across retries
  "seq": 1,                                   // 1 = first send, 2… = retries
  "pressed_at": "2026-09-18T18:02:11Z",       // only when clock_synced (same rules as activity)
  "pressed_uptime_ms": 123456, "sent_uptime_ms": 143456, "boot_count": 9,
  "clock_synced": true, "time_source": "nitz",
  "battery_pct": 0.72, "battery_mv": 3921, "rsrp_dbm": -97, "snr_db": 6,
  "location": { "status": "unavailable" },    // fix | stale | acquiring | unavailable
  "cell": { "mcc": 310, "mnc": 410, "tac": 12345, "cell_id": 67890123 },
  "session_active": false,
  "firmware": "rol-0.2.0-ww", "device_type": "rollator_platform"
}
```
`event:"location"` carries `location: {status:"fix"|"stale", lat, lon, acc_m, captured_uptime_ms, captured_at?, age_s, source:"gnss", sats}` plus the same envelope. Time fields follow the `0.17.0-time` rules so the cloud reconstructs `pressedAt` from `ingestedAt − (sent − pressed uptime)` when unsynced.

**Downlink** — existing cmd envelope on `gs/{serial}/cmd`:

| cmd | Fields | Device behaviour |
|---|---|---|
| `assist_ack` | `cmd_id:"asst_<uuid>"`, `ts`, `incident_id`, `mode:"live"|"test"`, `status:"accepted"|"not_ready"` | Match `incident_id` to the pending incident; `accepted` → contacted tone (test variant if `mode:test`); `not_ready` → not-set-up tone and clear the armed flag; echo `cmd_id` in next heartbeat |
| `assist_arm` | `cmd_id:"asstarm_<uuid>"`, `ts`, `enabled:true|false`, `version:N` | Persist `/lfs/assist/armed.bin` = `{enabled, version}`; echo `cmd_id`; write Shadow `reported.assist_armed` |

Authentication of the ack: it arrives on the device's mutually-authenticated TLS session on a topic only AWS principals with `iot:Publish` can write (the per-thing policy grants the device subscribe/receive only). No additional signature is needed in v1 (D6).

### 5.5 Location strategy (GNSS + LTE coexistence)
- On the nRF91 the GNSS receiver and LTE time-share the radio: GNSS is **blocked while LTE is RRC-connected** and runs in RRC-idle/PSM windows (`NRF_MODEM_GNSS_EVT_BLOCKED/UNBLOCKED`). "GNSS priority mode" exists but interferes with LTE and is disabled after 40 s — wrong tool when the notification must win.
- Therefore the device does **LTE first, GNSS after the ack** (D4): the 20 s countdown is spent getting the MQTT session up, which guarantees the request leaves at T20; GNSS starts once the ack is in hand and RRC is released. Cold-start TTFF without assistance is typically 30–60 s+ outdoors and usually never indoors, so a 20 s GNSS window before publishing would rarely help and would delay the notification.
- `gnss.c`: `nrf_modem_gnss_use_case_set(MULTIPLE_HOT_START | LOW_ACCURACY)`, `fix_interval_set(0)` (single fix), `fix_retry_set(CONFIG_GOSTEADY_ASSIST_GNSS_TIMEOUT_S = 180)`; on `EVT_FIX` cache PVT (lat/lon/accuracy/sats/uptime + wall time if synced) in RAM and `/lfs/assist/lastfix.bin`; on `EVT_SLEEP_AFTER_TIMEOUT` report `unavailable`. `EVT_AGNSS_REQ` is logged only in v1 (assistance data via nRF Cloud A-GNSS is a v1.1 option, Q8).
- **Location ladder in the request:** cached fix < 15 min old → `fix`; < 24 h → `stale` (with `age_s`); else `unavailable`. The cloud additionally receives the serving-cell tuple every time; cell-based coarse location (cloud-side) is FA-5b (Q7) — the only thing that works indoors.
- Energy: GNSS acquisition ≈ 30–45 mA for ≤ 180 s ≈ 1.5–2.3 mAh — bounded per incident.
- **Wi-Fi scan positioning (FA-5c, proposed — Q7).** The Thingy:91 X carries an nRF7002 (spi3, its own nPM6001 rail, off in every GoSteady build today). NCS supports a **scan-only** mode (`CONFIG_NRF70_SCAN_ONLY`; the `cellular/location` sample runs it on this exact board). A 2.4 GHz BSSID/RSSI scan takes ~1–3 s, does not contend with LTE, and works **indoors where GNSS never will**; the cloud resolves BSSIDs (+ the serving-cell tuple) with one Google Geolocation API call, typically ±20–50 m in homes. Cost: RAM is the gate — the standalone `wifi/scan` sample is **73.5 KB RAM** on this board (measured 2026-09-18) and the incremental cost inside our tree is unmeasured against ~84 KB headroom on the pilot build; power ≈ 0.05–0.1 mAh per scan plus switching the nRF7002 rail. If it fits, the request timeline becomes: countdown → Wi-Fi scan + cell tuple (so the **initial** call/SMS already carries a usable location) → publish → ack → GNSS refinement outdoors. Decide after an in-tree RAM measurement (FA-5c gate).

### 5.6 Arming, persistence, wipe
- `/lfs/assist/armed.bin` `{enabled, version}` (written by `assist_arm`), `/lfs/assist/pending.json` (unacked incident), `/lfs/assist/lastfix.bin`. All three are wiped by the `wipe` cmd (wipe scope amendment, DL15) and cleared on de-provision (`activated_at` → null ⇒ armed := false).
- A device that is not activated is never armed (the cloud only arms `active_monitoring` devices).

### 5.7 Build integration

| Kconfig symbol | Default | Purpose |
|---|---|---|
| `GOSTEADY_ASSIST_ENABLE` | n | Compiles `assist.c`; wires the button under FIELD_MODE; new topic/cmds/heartbeat fields |
| `GOSTEADY_ASSIST_FEEDBACK` (choice) | **`_BUZZER`** | `_BUZZER` (Qwiic, `select REGULATOR`), `_SPEAKER` (archived DFR0534, selects the hidden `GOSTEADY_ASSIST_AUDIO`), `_NONE` (LED only) |
| `GOSTEADY_ASSIST_CANCEL_HOLD_MS` | 3000 | Hold-to-cancel threshold |
| `GOSTEADY_ASSIST_BUZZER_VOLUME` / `_FREQ_HZ` | 4 / 2730 | |
| `GOSTEADY_ASSIST_FEEDBACK_SELFTEST` | n | Boot-time power-up + identify + chirp (bench) |
| `GOSTEADY_ASSIST_COUNTDOWN_S` / `_MIDPROMPT_S` / `_ACK_WAIT_S` | 20 / 10 / 30 | |
| `GOSTEADY_ASSIST_STUB_CLOUD` (+ `_STUB_ACK_MS`) | y when `!CLOUD_ENABLE` | Bench: simulated ack; boots armed |
| `GOSTEADY_ASSIST_GNSS` | n | `gnss.c` (FA-5); isolable RAM/energy cost |

Overlays: `prj_assist_bench.conf` (buzzer, stub cloud) + `boards/assist_buzzer_i2c2.overlay` (unmodified board) or `boards/assist_buzzer_bitbang.overlay` (the cut bench board); `prj_assist_speaker_bench.conf` + `boards/assist_audio_uart1.overlay` (archived). Deployment: `prj_rollator_pilot.conf` gains the assist symbols behind a `prj_rollator_assist.conf` delta during FA-1–FA-5, folded in at FA-6; the `qwiic_buzzer` node moves into the base board overlay at that point. `docs/build-configurations.md` matrix updated in lockstep. Version line bumps to `rol-0.2.0-*`.

### 5.8 Energy budget (per incident, 1350 mAh reference cell)

| Term | Estimate | Basis |
|---|---|---|
| Buzzer board powered ~25 s (idle ≈ few mA; ~95 mA only while a beep sounds, ≈ 3 s cumulative) | ~0.15 mAh | to be measured (§4.7) |
| Connect + publish + ack hold ~40 s | ~0.6 mAh | 0.25 mAh/cycle + ~50 mA hold |
| GNSS ≤ 180 s | ~1.5–2.3 mAh | nRF91 GNSS tracking current |
| Follow-up publish | ~0.25 mAh | |
| **Total per incident** | **≈ 3–4 mAh (~0.3 %)** | negligible per event |
| Standing cost when armed | **0** | audio unpowered, button is a sense-edge input |
| Monthly test | ≈ 4 mAh | |
| Worst case: 10 min awake retry in no-coverage | ≈ 10–15 mAh | bounded by `RETRY_AWAKE_S` |

Conclusion: the feature is compatible with the one-year target because of L8 (zero standing current); the buzzer is cheaper per incident than the speaker was, and GNSS remains the dominant term.

### 5.9 RAM / thread budget
Rollator pilot build has ~84 KB RAM headroom. Measured 2026-09-18 on the bench build: assist thread + buzzer backend + bit-bang I²C ≈ +5.7 KB over the speaker build (120,608 B vs 114,944 B, both bench posture); `gnss.c` ~1 KB (PVT struct ~300 B, no `location` library). Expected < 8 KB total. Re-measure at each phase; the `location`/A-GNSS libraries are explicitly **not** pulled in for v1.

### 5.10 Concurrency and priority (L3)
- `assist_publish_wait_ack()` takes `s_aws_mutex` like every other publish, so it serializes with an in-flight heartbeat/activity cycle (worst case CONNECT_WAIT 60 s + PUBACK_WAIT 30 s). Mitigation in FA-1: (a) if a session is already up (linger, activity cycle, wake window), the assistance thread **reuses it** — the mutex holder checks an `assist_pending` atomic at its checkpoints and hands the session over instead of disconnecting; (b) `wait_for_cellular_ready()` gets a bounded variant for the assistance path; (c) the pre-activation wake window (holds the mutex up to 600 s) cannot coincide with an armed device (armed ⇒ activated), so no arbitration is needed there.
- Heartbeat and activity publishes queued behind an incident simply wait; nothing is dropped.
- Cmd dispatch runs on the `aws_iot` library thread: `assist_ack` handling only sets state and gives a semaphore; the audio prompt is played by `gs_assist`.

### 5.11 Bench/test hooks
- uart0 shell (bench builds): `assist press`, `assist arm on|off`, `audio play <n>`, `audio volume <v>`, `gnss fix` — the FA-1 acceptance harness.
- Test images use a stub cloud: `infra/scripts/assist-bench-ack.py` publishes `assist_ack` via `aws iot-data publish` on observing the request (FA-1, before the dispatcher exists).

---

## 6. Cloud design (`gosteady-portal/infra`)

### 6.1 Topology

```
gs/+/assist ──IoT rule gosteady_{env}_assist──▶ assistance-dispatcher (Processing stack)
   │                                              │ PutItem incidents (cond. attribute_not_exists)
   │                                              │ PutItem Alert History projection
   │                                              │ SendMessageBatch → gosteady-{env}-assistance-notify (SQS, Notification stack)
   │                                              │ iot-data publish cmd assist_ack
   │                                              └ audit + EMF metrics
   ▼
assistance-notifier (Notification stack, SQS consumer, DLQ) ──▶ Retell create-phone-call / Twilio Messages (+StatusCallback)
POST /api/v1/webhooks/retell , /webhooks/twilio/status ──▶ assistance-webhooks (Api stack, signature-verified) ──▶ UpdateItem incident
assistance-api (Api stack, D2C authorizer) ──▶ status / settings / prefs / test-arm / incidents / ack / close
heartbeat-processor: cmd_id prefix asst_ / asstarm_ ──▶ incident.deviceAckConfirmedAt / arm ack
connection-coordinator: republishes outstanding assist_arm cmds (third tuple in its loop)
EventBridge daily ──▶ assistance-canary (synthetic Retell+Twilio health) ──▶ alarm
```

### 6.2 IoT policy and rule
- `ingestion-stack.ts`: add `gs/${iot:Connection.Thing.ThingName}/assist` to `PublishUplinks` (re-check the policy size stays < 2048 B; expected ≈ 1650 B). Policy is a single named policy attached to every device cert → fleet-wide on deploy.
- New rule `gosteady_{env}_assist`: `SELECT *, topic(2) AS thingName, timestamp() AS rule_ts_ms FROM 'gs/+/assist'` → `gosteady-{env}-assistance-dispatcher`, error action → the existing IoT DLQ.
- `alert-handler` and the rollator alert enum are **untouched** (the dedicated topic keeps the device-alert path clean — D2).

### 6.3 `assistance-dispatcher` (Python 3.12 ARM64, Powertools, IdentityKey grant)
Per `event`:

**`request`**
1. Resolve patient via `_shared/patient_resolution` (serial → active assignment → patient/household). Unmapped serial → log + metric, no ack (device keeps retrying until ops fixes it — visible via alarm).
2. Time: `pressedAt` = device `pressed_at` if synced+plausible else reconstruct (`_shared/device_time` with `sent_uptime_ms − pressed_uptime_ms`). `late = ingestedAt − pressedAt > 15 min`.
3. Readiness: `ASSISTANCE_ALERTS_ENABLED` and `patient.assistance.enabled` and ≥ 1 eligible member (§6.5). If not ready → still write the incident with `status:"rejected_not_ready"` (audit + metric), publish `assist_ack{status:"not_ready"}`, **and re-arm the device to false** (this is the self-heal for a stale armed flag). No fan-out.
4. Test mode: `patient.assistance.testArmed` present and `until > now` → `isTest=true`, recipients = the arming member (+ members with `assistancePrefs.testRecipient`), consume the arm (single use).
5. `PutItem` incidents with `ConditionExpression attribute_not_exists(incidentId)`. On `ConditionalCheckFailed` (device retry or duplicate delivery): read the row, **re-publish the same ack** (`ackCmdId` stored on the row), return.
6. `PutItem` Alert History projection: `alertType:"assistance_request"`, `severity:"critical"`, `source:"device"`, `data:{incidentId, isTest, locationStatus, pressedAt}` (idempotent compound SK `{pressedAt}#assistance_request`).
7. Build recipient list from `RoleAssignments` GSI `by-client-role` on the household `clientId`: rows with `phone` present and `assistancePrefs.voice`/`sms` true and `consentedAt` set (test mode filters as in step 4). `SendMessageBatch` one message per (member, channel): `{incidentId, memberUserId, channel, attempt:1}`. Persist the notification skeleton on the incident (`notifications[]` with `status:"queued"`).
8. Publish `assist_ack` (`cmd_id asst_<uuid>`, `mode`, `status:"accepted"`), store `ackCmdId/ackSentAt`, set `status:"notifying"`.
9. Audit `d2c.assistance_requested` (+ `…_rejected_not_ready`), metrics `assistance_request_count`, `assistance_ack_latency_ms` (= now − `rule_ts_ms`), `assistance_late_arrival_count`.

**`location`** — UpdateItem `location` + append `locationHistory`; if the incident has not yet sent a follow-up and the initial notifications went out without a fix → enqueue one `sms` follow-up per SMS-eligible member (`kind:"location_update"`). Never a second call (AST-SW-04). Audit `d2c.assistance_location_updated`.

**`cancel`** (optional, D9) — record `cancelledAt` on a pre-existing incident (only possible post-transmit if we add a third-press "false alarm"; default v1: no cancel event after transmit).

Ordering guarantees L2: the ack is published only after steps 5 and 7 succeed.

### 6.4 Incident data model — `gosteady-{env}-assistance-incidents` (Data stack, `IdentityTable`, IdentityKey CMK)

| Attribute | Type | Notes |
|---|---|---|
| **incidentId** (PK) | S | Device-generated UUIDv4 (idempotency key) |
| patientId, clientId, facilityId, censusId, deviceSerial, deviceType | S | Hierarchy snapshot at write time (T4) |
| status | S | `notifying` → `notified` (all jobs terminal) → `acknowledged` → `closed`; or `rejected_not_ready`; `failed` (all channels failed) |
| isTest | BOOL | L13 |
| pressedAt, sentAt, ingestedAt, ackSentAt, deviceAckConfirmedAt | S | ISO; `timeSource` as in activity rows |
| ackCmdId | S | `asst_…`; re-sent on duplicate requests |
| seq | N | last device `seq` seen |
| battery, radio | M | snapshot from the request |
| location | M | `{status, lat, lon, accM, capturedAt, ageS, source, geocodedText, mapUrl}` — current best |
| locationHistory | L | append-only `{…, receivedAt}` |
| cell | M | serving cell tuple (for FA-5b) |
| notifications | L | one per (member, channel): `{memberUserId, displayName, phoneMask, channel, attempt, status, providerId (retell call_id / twilio sid), queuedAt, sentAt, outcome, outcomeAt, error}` — `voice` outcomes: `answered`, `voicemail`, `no_answer`, `busy`, `failed`; `sms` outcomes: `delivered`, `undelivered`, `failed`, `sent` |
| followUpSmsSentAt | S | set once |
| acknowledgedBy, acknowledgedAt, closedBy, closedAt, closeReason | S | member actions |
| firmwareVersion | S | |
| expiresAt | N | TTL = pressedAt + 24 months (mirrors Alert History, L2 lifecycle) |
| **GSI `by-patient`** | PK patientId, SK pressedAt | history + "active incident" lookup |
| **GSI `by-status`** | PK status, SK pressedAt | ops sweeps (stuck `notifying`) |

Companion changes:
- **Patient** row: `assistance: {enabled, enabledBy, enabledAt, locationConsent:{acceptedBy, acceptedAt, version}, testArmed?:{by, until, recipients[]}, lastTestAt, lastTestResult, armVersion}`.
- **RoleAssignments** member row: `assistancePrefs: {voice, sms, testRecipient, consentedAt, consentVersion}` (self-service; masked in roster reads like `phone`).
- **Device Registry**: `outstandingAssistArmCmds` map (`cmd_id → issuedAt`), `assistArmedVersion` (acked). **Shadow**: `desired.assist_enabled` (bool, invariant: true iff readiness true) mirrored by `reported.assist_armed` from firmware.

### 6.5 Readiness (single function, `_shared/assistance.py: compute_readiness(patient, members, device)`)
`ready = flag && patient.assistance.enabled && locationConsent && device.status == active_monitoring && device.assistCapable && eligibleMembers ≥ 1` where eligible = phone present ∧ (voice ∨ sms) ∧ consented. Any write that can change it (settings, prefs, member remove/leave/demote, device end-assignment, feature flag) calls `sync_device_arming(serial, ready)`: bumps `armVersion`, writes Shadow `desired.assist_enabled`, publishes `assist_arm` and records it in `outstandingAssistArmCmds` for the coordinator. `assistCapable` comes from the heartbeat extra `assist_capable:true` (persisted on Shadow `reported`, copied to the registry on first sight).

### 6.6 Fan-out — SQS `gosteady-{env}-assistance-notify` + `assistance-notifier` (Notification stack — finally un-stubbed)
- Standard queue, visibility 60 s, `maxReceiveCount 3`, DLQ `…-assistance-notify-dlq` + depth alarm. Message = `{incidentId, memberUserId, channel, attempt, kind:"initial"|"location_update"|"synthetic"}`.
- **voice:** `POST https://api.retellai.com/v2/create-phone-call` (Bearer API key from secret `gosteady/{env}/retell`) with `from_number` (Retell-owned number, env config), `to_number` (E.164 from the member row), `override_agent_id` (live vs test agent ids in config), `retell_llm_dynamic_variables` `{walker_name, member_name, pressed_time_local, location_text, location_age_text, incident_ref}`, `metadata {incidentId, memberUserId, attempt, env}`. Store `call_id`, status `sent`. Voicemail is handled by the agent's `voicemail_option` (leave the static message) → outcome `voicemail`. **Recordings disabled** (`opt_out_sensitive_data_storage`) — D13.
- **sms:** `_shared/sms.py: send_sms(to, body, status_callback=…)` (new optional param → Twilio `StatusCallback`); store the message SID, status `sent`.
- Retry matrix: provider HTTP failure → raise (SQS redelivery, 3×) then DLQ; voice `no_answer|busy|dial_failed` from the webhook → one retry after 120 s (`attempt:2`) via SQS delay; `voicemail` counts as reached (no retry). SMS `undelivered/failed` → one retry after 60 s. Everything is recorded per attempt (AST-SW-06).
- Terminal-state roll-up: when every notification is terminal → incident `status:"notified"` (or `failed` if none succeeded → `assistance_delivery_failed_count` alarm at > 0).

### 6.7 Webhooks (`assistance-webhooks`, Api stack, **no Cognito**; HTTP API routes with no authorizer)
- `POST /api/v1/webhooks/retell` — verify `x-retell-signature` with `Retell.verify(rawBody, apiKey, signature)` (SDK) and optionally the source IP `100.20.5.228`; events `call_started` / `call_ended` / `call_analyzed`; dedupe on `(event, call_id)`; map `disconnection_reason` → outcome (`user_hangup`/`agent_hangup` after > 5 s ⇒ `answered`; `voicemail_reached` ⇒ `voicemail`; `dial_no_answer` ⇒ `no_answer`; `dial_busy` ⇒ `busy`; `dial_failed`/error ⇒ `failed`). Retell retries non-2xx up to 3× within 10 s — return 200 fast, do the work inline (single UpdateItem).
- `POST /api/v1/webhooks/twilio/status` — validate `X-Twilio-Signature` (HMAC-SHA1 over URL + form params with the account **auth token**; the secret must carry `auth_token` even when API-key auth is used for sends); statuses `queued|sent|delivered|undelivered|failed`.
- Both run at 256 MB / 10 s, audit `d2c.assistance_notify_outcome`.

### 6.8 Location services
- Reverse geocoding for the voice script: **Amazon Location Service** Place Index (`SearchPlaceIndexForPosition`, Esri provider) → `location.geocodedText` ("near 4200 Speedway, Austin TX"). D11.
- SMS map link: `https://maps.google.com/?q={lat},{lon}` (opens Apple/Google Maps universally) + "±{acc} m, captured {age}".
- No fix: voice and SMS say *"Their location is not available yet."* Network-based location — **Google Geolocation API** fed with the reported cell tuple (FA-5b) and, if the firmware can afford it, Wi-Fi BSSIDs (FA-5c, §5.5) — is the indoor answer; **accepted in principle 2026-09-18 (Q7)**, provider secret `gosteady/{env}/geolocation`.
- Optional household "home address on file" is **not** included in messages in v1 (misleading when away; Q9).

### 6.9 Downlink additions
- `assist_ack` (immediate; not coordinator-republished — a device that misses it retries the request and gets a fresh ack).
- `assist_arm` (coordinator-republished via `outstandingAssistArmCmds`; swept at 24 h like the others).
- `heartbeat-processor`: prefix dispatch gains `asst_` (set `incident.deviceAckConfirmedAt`, audit `d2c.assistance_device_ack`) and `asstarm_` (remove from the outstanding map, set `assistArmedVersion`). Heartbeat extras `assist_capable/assist_armed/audio_ok/gnss_fix_age_s` land on Shadow `reported` automatically (D16 accept-all); `audio_ok:false` on an armed device raises `assistance_audio_fault_count`.

### 6.10 API (`assistance-api`, Api stack, `D2CUserPoolAuthorizer`, `audit_middleware`, tenancy via household `clientId`, patient access via `enforce_patient_access`)

| Route | Who | Does |
|---|---|---|
| `GET /api/v1/d2c/assistance/status?patientId=` | any member | readiness, reasons if not ready, eligible contact count, `lastTestAt/Result`, active incident id |
| `PUT /api/v1/d2c/assistance/settings` | `household_owner` | `{patientId, enabled, locationConsent:{accepted, version}}` → recompute readiness → arm/disarm |
| `PUT /api/v1/d2c/assistance/me/prefs` | any member | own `{voice, sms, testRecipient, consentVersion}`; consent stamped server-side |
| `POST /api/v1/d2c/assistance/test/arm` | any member (self as recipient) | `{patientId}` → `testArmed {by, until:+10 min}` (409 if an incident is active) |
| `GET /api/v1/d2c/assistance/incidents?patientId=&limit=&cursor=` | any member | history (newest first) |
| `GET /api/v1/d2c/assistance/incidents/{id}` | any member | full detail incl. per-member outcomes (phones masked) |
| `POST /api/v1/d2c/assistance/incidents/{id}/ack` | any member | "I'm on it": first-write-wins; also acks the projected alert row (extend `alert-actions` so acking the alert row acks the incident and vice-versa) |
| `POST /api/v1/d2c/assistance/incidents/{id}/close` | any member | `{reason:"resolved"|"false_alarm"|"test"}`; auto-closes test incidents after roll-up |

### 6.11 Audit events (local literals, per D2C convention)
`d2c.assistance_requested`, `d2c.assistance_rejected_not_ready`, `d2c.assistance_ack_sent`, `d2c.assistance_device_ack`, `d2c.assistance_location_updated`, `d2c.assistance_notify_sent`, `d2c.assistance_notify_outcome`, `d2c.assistance_notify_failed`, `d2c.assistance_acknowledged`, `d2c.assistance_closed`, `d2c.assistance_test_armed`, `d2c.assistance_settings_updated`, `d2c.assistance_prefs_updated`, `d2c.assistance_armed` / `_disarmed`, `d2c.assistance_canary_run`. PII scrubber key list gains `lat`, `lon`, `latitude`, `longitude`, `phone`, `to_number`, `from_number`, `geocodedText`.

### 6.12 Observability, SLOs, canary (AST-OPS-01/02/04)
Metrics (EMF, `GoSteady/Assistance/{env}`): `assistance_request_count`, `assistance_ack_latency_ms` (p50/p95), `assistance_late_arrival_count`, `assistance_gnss_fix_count` / `_no_fix_count` / `gnss_ttff_s`, `assistance_voice_attempt_count` by outcome, `assistance_sms_attempt_count` by outcome, `assistance_member_ack_latency_s`, `assistance_test_completed_count`, `assistance_delivery_failed_count`, `assistance_audio_fault_count`, `assistance_provider_error_count` by provider. Alarms: dispatcher/notifier/webhooks Lambda errors + ERROR-pattern (Phase 1.6 convention), DLQ depth > 0, `ack_latency p95 > 30 s (15 min)`, `delivery_failed_count > 0`, `provider_error_count > 0`, canary failure. Dashboard: `gosteady-{env}-assistance` (funnel: requests → acked → notified → member-acked; provider outcomes; TTFF histogram).

Canary (`assistance-canary`, EventBridge daily): creates a synthetic incident (`kind:"synthetic"`, no patient) that places one Retell call and one SMS to a GoSteady-owned test number, checks credentials, and expects a webhook within 5 min; alarm on failure. Readiness (AST-OPS-02): `device_offline` (2 h = two missed heartbeats) already fires; **delivery** of it to the household owner is FA-3b (§9).

### 6.13 Config, secrets, flags
- Secrets: `gosteady/{env}/retell` `{api_key, from_number, agent_id_live, agent_id_test, webhook_ip?}`; `gosteady/{env}/twilio` gains `auth_token` if absent (signature validation); `gosteady/{env}/geolocation` only if FA-5b picks Google.
- `config.ts`: `assistanceEnabled: boolean` (dev true / prod false until FA-6) → Lambda env `ASSISTANCE_ALERTS_ENABLED`; `assistanceRetellFromNumber`, `assistanceCanaryToNumber`, `assistanceApiMemoryMb/TimeoutSeconds`.
- Stack placement: **Data** (incidents table) → **Processing** (dispatcher, IoT-rule target; queue referenced by convention name) → **Ingestion** (policy + rule) → **Notification** (queue, DLQ, notifier, canary) → **Api** (assistance-api, webhooks, routes). Cross-stack refs by name (`Queue.fromQueueArn`), per the §18 migration lessons; deploy Notification before enabling the flag.

---

## 7. Consumer app (`lib/d2c/`, Flutter Web)

| Surface | Change |
|---|---|
| **Care Team screen** | Per-member "Assistance alerts: calls / texts" toggles (self-service; owner sees state), consent sheet on first enable (§8 consent copy), "test recipient" toggle |
| **Assistance settings** (new, under Account) | Owner: enable/disable, location-sharing consent (walker or owner on their behalf), readiness card ("Ready — 2 contacts" / "Not ready — add a contact who accepts calls or texts"), last test date + result, **Run a test** (arms for 10 min, shows live progress), **"What the beeps mean"** legend (§5.3) incl. "hold the button for 3 seconds to cancel" |
| **Dashboard** | Active-incident card pinned at top (red): timeline (requested → contacting → who answered / delivered → acknowledged), **I'm on it** and **Mark resolved**; incident location map link when available. Uses the projected Alert History row for discovery and the incident endpoint for detail |
| **History** | Incidents list (tests labelled) with detail |
| **Walker-user view** | `WALKER_VISIBLE_ALERT_TYPES` gains `assistance_request` so the walker sees their own request status (D8) |
| **Onboarding / agreements** | User + caregiver agreements gain the "family notification, not emergency services; GoSteady does not contact 911" clause (AST-SW-07); TCPA consent text at prefs enable (`d2c-user-agreement.md`, `d2c-caregiver-agreement.md` amendments) |
| **Routes / repo** | `D2CRoutes.assistance`, `…incident/:id`; `D2CRepository` gains `assistanceStatus()`, `updateAssistancePrefs()`, `armTest()`, `incidents()`, `incident(id)`, `ackIncident()`, `closeIncident()` (mock + live) |

Facility portal: none in v1 (L11).

---

## 8. Message copy (v1, subject to counsel review — Q13)

**SMS (initial, with fix):** `GoSteady: {WalkerName} pressed the assistance button on their rollator at {time} ({tz}). Location: {addressOrCoords} (±{acc} m, {age}). Map: {url}. This is a family notification, not emergency services — please check on them. Tap to respond: {appUrl}`
**SMS (initial, no fix):** `… Location is not available yet; we'll text again if it becomes available. …`
**SMS (follow-up):** `GoSteady update: {WalkerName}'s location is now available (captured {time}, ±{acc} m): {url}.`
**SMS (test):** prefixed `TEST — ` and ends `This was a test; nobody needs help.`
**Voice (Retell agent script, dynamic variables):** *"Hello {member_name}, this is GoSteady, the family assistance service for {walker_name}. {walker_name} pressed the assistance button on their rollator at {pressed_time_local}. {location_sentence} This is an automated family notification, not emergency services. Please check on {walker_name} now, and call emergency services yourself if you believe they need it. I will repeat that once."* (repeat; then *"Goodbye."*). Voicemail variant identical, prefixed with *"This is an important message from GoSteady for {member_name}."* Test variant opens with *"This is a GoSteady test call."*
**Device feedback:** beep patterns, §5.3 (no speech in the product).
**Consent (prefs enable):** "I agree to receive automated phone calls and text messages from GoSteady when {WalkerName} presses the assistance button. These are family notifications, not emergency services. Message and data rates may apply; reply STOP to opt out of texts."

---

## 9. Phasing, exit criteria, prerequisites

| Phase | Scope | Exit criteria | Depends on |
|---|---|---|---|
| **FA-0 Hardware gate** (≈ 1 week, bench) | ~~speaker path~~ proven then **retired** (§C63.6/§C64); **buzzer feedback layer + hold-to-cancel written and compiling** (`prj_assist_bench.conf` + `assist_buzzer_*.overlay`); **next:** Qwiic Buzzer arrives → plug into P1 → flash the matching overlay → verify the cadence, hold-cancel, confirmed/cancelled tones, loudness; buzzer current + rail sag; GNSS TTFF indoors/outdoors/window (10 fixes each) | Numbers recorded in coord §C64.x; energy line in §5.8 replaced with measurements | Buzzer on order (BOB-24474 + Qwiic cable) |
| **FA-1 Firmware core** | `assist.c` + audio driver + button un-gate + LED + persistence/retry + `assist_ack/arm` cmd handling + heartbeat extras + MCUboot entrance fix + shell hooks; **no GNSS**; acceptance with the bench ack stub | Bench: press → prompts at 1.5/10 s → publish at 20 s → stub ack → "Contacted care circle"; cancel path; retry path with the antenna wrapped; reboot mid-`AWAIT_ACK` resumes; RAM/flash deltas recorded; 0 faults over a 24 h soak with hourly presses | FA-0 |
| **FA-2 Cloud pipeline** | Policy + rule, incidents table, dispatcher (request/location), ack, projection, Patient/RoleAssignments fields, readiness + `assist_arm`, heartbeat/coordinator dispatch, `e2e-assistance-alert.py` (synthetic device + JWTs) | Real device: ack latency p95 < 10 s from PUBACK on dev; duplicate request ⇒ same ack; not-ready ⇒ P09 + disarm; alert card visible in the D2C app via the existing alerts read | FA-1 |
| **FA-3 Notifications** | Notification stack real: queue, notifier (Retell + Twilio + StatusCallback), webhooks, retries, roll-up, canary, alarms, dashboard | Live two-phone test: one press ⇒ both members get a call **and** a text within 60 s of the ack; outcomes visible in the incident; voicemail + no-answer + STOP cases recorded; canary green 3 days | FA-2, Retell account + number, test numbers |
| **FA-3b Readiness delivery** | Owner SMS for `device_offline`/`device_silent`/`battery_critical` on assistance-enabled households (≤ 1/day/type), riding the same notifier | `device_silent` reaches the owner's phone (closes the §C62.5 "reached nobody" gap for this cohort) | FA-3 |
| **FA-4 App** | §7 surfaces, copy, agreements, walker visibility | Owner can enable, member can consent, test runs from the app end-to-end, incident card + ack + close work on phones | FA-2/FA-3 |
| **FA-5 Location** | `gnss.c`, location ladder, `event:location`, follow-up SMS, geocoding; **FA-5b** cell-based coarse location if Q7 = yes | Outdoors: fix within 180 s in ≥ 80 % of trials; indoors: request still acked and delivered with "not available"; follow-up SMS exactly once | FA-1, FA-3 |
| **FA-6 Pilot validation** | Human-factors on installed rollators (actuator placement/force, false-press during rolling/braking/transport, **hold-to-cancel discoverability and false cancels**), buzzer loudness through the enclosure, poor-coverage runs, energy soak, counsel review, ops runbooks; fold `prj_rollator_assist` into the pilot overlay | All PRD §7 Family-Assistance gates green; prod flag flip decision | everything + enclosure track |

**Prerequisites outside this spec (PRD §7 current-product gates):** the session-storage exhaustion fix (`2026-07-31-session-storage-exhaustion.md` Options 5+2 then 1) must ship before any assistance pilot — a unit that crashes in a blackout cannot be a safety device; the `telemetry_queue` work there should share the `/lfs/assist/pending.json` durability pattern. Vehicle-transport exclusion, battery-claim validation and the OTA decision remain product gates but do not block FA-0…FA-5 engineering.

---

## 10. Test plan (acceptance rows; scripts follow `infra/scripts/e2e-*.py` conventions)

| # | Scenario | Method | Expected |
|---|---|---|---|
| T1 | HW-0 topology check | bench, meter | Reading recorded; sensors alive after any cut |
| T2 | Buzzer board current off / idle-powered / sounding | bench, current board | Off = 0 mA; idle + ~95 mA sounding logged |
| T3 | Rail sag at volume 4 | scope on VDD_EXP_BRD + 1V8 | No brownout, GNSS LNA rail stable |
| T4 | Press → cadence timing | console log + ear | chirp ≤ 0.3 s; phase change at 10.0 ± 0.2 s; rapid phase at 17.0 s; publish at 20.0 s |
| T5 | Hold-to-cancel: hold from 5 s and from 18 s; hold the initial press; release at 2.5 s (must NOT cancel) | bench | hold tone from 0.6 s; cancelled tone at 3.0 s; no publish; the 2.5 s release resumes the cadence |
| T6 | Press while not armed | bench | not-set-up tone, no publish |
| T7 | Publish at 20 s, ack, contacted tone | dev cloud | ack latency p95 < 10 s |
| T8 | No coverage (antenna wrapped) | bench | retries at +30/+90/+210 s, failed tone after the 3rd, awake ≤ 10 min, later delivery flagged `late` |
| T9 | Reboot during AWAIT_ACK | bench | resumes retry, no second countdown, one incident |
| T10 | Duplicate request (seq 2) | `e2e-assistance-alert.py` | one incident, same ack re-sent |
| T11 | Not-ready household | e2e | `rejected_not_ready`, ack `not_ready`, not-set-up tone, device disarmed |
| T12 | Fan-out to 3 members (2 voice+sms, 1 sms-only) | live phones | 5 jobs, all outcomes recorded |
| T13 | Voicemail / no answer / busy / STOP | live phones | outcomes + single retry where specified |
| T14 | Follow-up location SMS once | e2e + device | exactly one per incident |
| T15 | Test mode | app + device | only the tester notified; "TEST —" copy; four-note tone; `lastTestAt` updated |
| T16 | Member ack / close | app | alert row + incident both acked; audit |
| T17 | Pause bypass | e2e with `notificationsPaused` set | request still processed |
| T18 | Walker visibility | e2e (`isWalkerUser`) | `assistance_request` visible to walker |
| T19 | Canary | invoke | webhooks received; alarm silent |
| T20 | Wipe clears assist state | device | armed=false, no pending, no last fix after wipe-ack recycle |
| T21 | MCUboot: button held at reset | device | boots the app (no serial recovery) in deployment image |
| T22 | Energy per incident | current board | ≤ 5 mAh live; 0 standing |
| T23 | PII scrub | log search | no lat/lon/phone in operational logs |
| T24 | RAM/flash delta | build | < 8 KB RAM added on the pilot build |

---

## 11. Decisions log

| # | Decision | Alternatives | Why |
|---|---|---|---|
| D1 | Dedicated uplink topic `gs/{serial}/assist` | (a) reuse `gs/{serial}/alert` with `alert_type:"assistance_*"` and a second IoT rule; (b) Shadow | An incident has a lifecycle and non-alert events (`location`); a dedicated class keeps `alert-handler` and the per-type alert enum untouched and follows the `gs/{serial}/{class}` convention. Policy has the byte headroom |
| D2 | Ack = explicit `assist_ack` cmd sent after PutItem + enqueue | broker PUBACK; Shadow `desired` write | PUBACK only proves the broker got it (L2). Shadow deltas are only handled in bench code today; the cmd path is proven and re-subscribed on every connect |
| D3 | Device generates the incident id | cloud-minted id returned in the ack | Idempotent retries before any ack exists; the device must persist something before it has connectivity |
| D4 | LTE first, GNSS after ack | GNSS during the countdown; GNSS priority mode | Radio is shared; the notification must not wait on TTFF (AST-FW-01); cold TTFF > 20 s anyway |
| D5 | Single deliberate press starts; second press cancels; no long-press semantics | hold-to-send; double-press | Older-adult usability and the PRD's exact cancel gesture; false-press protection comes from the 20 s cancel window + actuator design, not from a hold |
| D6 | No application-layer signature on the ack in v1 | HMAC over incident id with a device key | Per-thing IoT policy + mutual TLS already make the cmd topic cloud-only; revisit with Phase 5A cert-bound ownership |
| D7 | Test mode is armed in the cloud (app) for 10 min; the device runs the identical path | device-side long-press = test; separate test button | A device-side gesture risks turning a real request into a test; cloud arming needs no device reachability and keeps prompts truthful (the ack tells the device it was a test) |
| D8 | Walker sees their own incident status | hidden (current battery-only allow-list) | Reassurance and self-check; the request is theirs |
| D9 | No `cancel` telemetry before transmit; post-transmit "false alarm" is a member action in the app | device-side third press = false alarm | Keeps the device gesture set to two presses; false alarms are cheap to close from the app; revisit after pilot data |
| D10 | Power gate via `exp_board_enable` (P0.03 → U14) | always-on; nPM1300 LDO/LSOUT | It is the switch Nordic put on that rail; zero standing current (L8) |
| D11 | Amazon Location Service for reverse geocoding; Google Maps URL for links | Google Geocoding; no geocoding (coords only) | AWS-native/CDK, cheap; the URL opens on any phone |
| D12 | Prompts pre-rendered with a neural TTS voice (Polly), same persona as the Retell agent | on-device TTS; recorded human | Consistent voice across device and phone; regenerable when copy changes |
| D13 | Retell recordings/transcripts opted out of storage | keep for QA | Minimises stored PHI-adjacent data; outcome + disconnection reason are enough for reconciliation |
| D14 | Incident TTL 24 months (hot) | no TTL | Aligns with Alert History; audit trail is retained 6 y regardless |
| D15 | **R1 (uart1 re-pin to P0.19/P0.18) — confirmed 2026-09-18** by the schematic (reading C); R2 (SC16IS750 on P1) kept as the no-surgery fallback | bit-bang; give up i2c2 | No free UARTE; the dedicated GPIOs exist, so the cheapest route wins |
| D16 | (proposed) Wi-Fi BSSID scan + cell tuple during the countdown, resolved cloud-side via Google Geolocation; GNSS only after the ack | GNSS-only; cell-only | Indoors is the common case for a rollator user; Wi-Fi is the only fast indoor fix. Gated on the in-tree RAM measurement (FA-5c) |
| D17 | **Buzzer replaces the speaker** (2026-09-18): SparkFun Qwiic Buzzer on P1 for the prototype, discrete buzzer in production | DFR0534 speaker (proven); piezo on a GPIO/PWM pin | Size + BOM; family-only notification does not need speech; I²C on the existing Qwiic bus needs no UART, no solder-bridge surgery, and keeps every unmodified unit usable. Speaker path archived, still selectable |
| D18 | **Press-and-hold 3 s cancels**, at any point in the 20 s including the initial press; a steady low tone from 0.6 s signals the hold | second press (v0.1); double press | One gesture with a clear physical meaning; sustained accidental pressure can never send; a panicked hold cancels audibly and a short re-press restarts — validate in FA-6 |
| D19 | The cut bench board keeps working via a bit-banged I²C bus on P0.18/P0.19 (`gpio-i2c`) | new Thingy:91 X now; re-solder SB8/SB9 | Same node, same driver, DT-only difference; a fresh unit is still preferred for production-representative i2c2 testing |
| D20 | Production feedback = discrete magnetic buzzer + NPN driver on the custom PCB (GPIO/PWM), same cadence code behind the feedback abstraction | keep the Qwiic board | ~$0.50 vs ~$9, no second MCU, no I²C; the abstraction makes the swap a backend file |

---

## 12. Open questions (need an answer before the phase that cites them)

- [x] **Q1 (FA-0):** ~~Have SB8/SB9 already been cut?~~ **No (2026-09-18)** — good: cut them now per §4.3 (safe, confirmed by the schematic) **before** flashing the audio image.
- [x] **Q2 (FA-0):** ~~Schematic?~~ **Provided 2026-09-18** (`pca20065-thingy91-x-2_0_0.zip`); topology resolved (§4.3). The second zip (`thingy91x_mfw-2.0.4_sdk-3.2.1`) is the modem-firmware/factory-image bundle already kept under `nordic resources/` — not needed here.
- [ ] **Q3 (FA-3):** Retell account, purchased number, and two agents (live/test) — **operator: the existing Retell number is in use on another project; a new number is being obtained (2026-09-18)**. Webhook URL per agent (recommended).
- [ ] **Q4 (FA-3):** Test phone numbers (≥ 2 real phones + one GoSteady-owned number for the canary).
- [ ] **Q5 (FA-3):** Twilio STOP handling — toll-free sender handles STOP automatically at the carrier; confirm the Messaging Service opt-out behaviour and whether an opted-out member should be flagged `sms:false` via a Twilio inbound webhook (not built).
- [ ] **Q6 (FA-3):** Voice retry policy — one retry after 120 s for no-answer/busy is proposed; PRD is silent. Also: should a member who **answered** suppress retries to others? (Proposed: no — everyone is notified; L4 puts response on the family.)
- [x] **Q7 (FA-5b/5c):** ~~Cell-based coarse location?~~ **Yes (2026-09-18)** — Google Geolocation API for cell + Wi-Fi; Wi-Fi scan-only on the nRF7002 proposed as FA-5c, gated on RAM (§5.5, D16).
- [ ] **Q8 (FA-5):** A-GNSS via nRF Cloud to cut TTFF (needs an nRF Cloud account + device JWT flow) — decide after FA-0 TTFF numbers.
- [ ] **Q9 (FA-4):** Optional "home address on file" in the household profile — include in messages when no fix, clearly labelled? Proposed v1: no.
- [ ] **Q10 (FA-2):** Member cap for fan-out (no cap exists). Proposed: notify at most 10 members per incident, oldest-joined first, and surface the cap in the app.
- [ ] **Q11 (FA-1):** Bench builds with audio lose the uart1 dump/BLE channel (R1). Acceptable, or route `control.c` through the uart0 shell for those images?
- [ ] **Q12 (FA-1):** LED colour for "assistance pending/confirmed" — proposed solid red pending, green flash on ack, off after. Conflicts with nothing today.
- [ ] **Q13 (FA-6):** Counsel review of §8 copy, TCPA consent, and the agreements clause (same open item as ai-coach Q11).
- [ ] **Q14 (FA-2):** Should `late` arrivals (> 15 min old, device was offline) still fan out? Proposed: yes, with "pressed the button {N} minutes ago; the device only just reconnected" wording.
- [ ] **Q15 (FA-6):** Recurring test cadence (PRD AST-OPS-03) — monthly prompt in-app? Also whether a test should be required at activation before arming.
- [ ] **Q16 (FA-3):** The pivot note says "before sending **the text** out" — is the Retell **voice call** still in V1 alongside SMS (PRD AST-SW-02), or is V1 SMS-only with voice later? The cloud design supports either; it changes FA-3 scope and the Retell dependency.
- [ ] **Q17 (FA-6):** Buzzer loudness target through the enclosure (dB at 0.5 m) and whether one volume level suffices, or the household should be able to pick quiet/normal/loud in the app (→ `assist_arm` carries a volume byte).

---

## 13. Risks

| Risk | Impact | Mitigation |
|---|---|---|
| SB8/SB9 cut isolates the sensor bus (reading A) | Loses wake-on-motion + fuel gauge | HW-0 before cutting; R2 fallback |
| Buzzer board idle current (ATtiny IDLE sleep) | Would dominate battery if gating fails | L8; heartbeat `feedback_ok` + P0.03 state in extras; T2 |
| 95 mA beeps on BUCK2 alongside the GNSS LNA | rail sag → GNSS dropouts | T3; beeps and GNSS never overlap in the timeline (GNSS starts after the ack) |
| Hold-to-cancel cancels a real request (panicked hold) | delayed help | audible cancel + short re-press restarts; FA-6 human-factors; consider a second confirmation beep before cancelling |
| A beep-only device is less self-explanatory than speech | user unsure what is happening | consistent cadences, app legend, onboarding card on the cupholder; a 20 s window is long enough to notice the pattern |
| No coverage at press | Request delayed | bounded awake retry + persistence + late-arrival copy; storage-exhaustion fix prerequisite |
| Provider outage (Retell/Twilio) | Silent failure | canary + alarms + DLQ; both channels independent |
| Persistent-session expiry breaks `assist_arm` delivery | Device never arms | coordinator republish (existing pattern) |
| Button shared with MCUboot recovery | Bricked-looking unit after battery swap | §4.6 fix in FA-1; T21 |
| False presses on rough terrain | Nuisance calls erode trust | 20 s cancel + actuator design + FA-6 false-press testing; "false alarm" close reason feeds tuning |
| Walker without an account has no phone | Cannot be a recipient | Only members with verified phones are recipients; readiness requires ≥ 1 |

---

## 14. Changelog

| Date | Author | Change |
|---|---|---|
| 2026-09-18 | Claude (with Jace) | Initial umbrella spec v0.1: PRD V2.2 traceability, hardware findings (no free UARTE; SB8/SB9 topology gate; power gating; MCUboot recovery on Button 1), firmware/cloud/app design, phasing FA-0…FA-6, decisions D1–D15, open questions Q1–Q15 |
| 2026-09-18 | Claude (with Jace) | v0.2: P1 topology resolved from the PCA20065 v2.0.0 schematic (EXP_BOARD_PIN1 = P0.19, PIN2 = P0.18; R1 confirmed, D15); bench harness built in firmware (`prj_assist_bench.conf`, overlay, `assist.c`, `audio_dfr0534.c`, prompt set + loader); Wi-Fi scan positioning proposed (§5.5, D16); Q1/Q2/Q7 answered, Q3 updated |
| 2026-09-18 | Claude (with Jace) | v0.3: button → speaker proven on the bench (SB8/SB9 cut, sensors intact, module boot 570 ms, factory clips through the full 20 s sequence); canonical mapping corrected to TX = P0.18 / RX = P0.19 (DFRobot `T`/`R` are host-side labels); §4.3 HW-0 result, §5.2 timeline, §9 FA-0 updated |
| 2026-09-18 | Claude (with Jace) | **v0.4 — direction change:** speaker retired for a SparkFun Qwiic Buzzer on P1 (D17); 20 s beep countdown, **press-and-hold 3 s cancels** (D18); §4 rewritten (buzzer register map, i2c2 vs bit-bang overlays, no cutting), §5.1–5.3/5.7–5.9 rewritten (feedback abstraction, cadence timeline, pattern set), tests/risks/questions updated (Q16 voice-in-V1?, Q17 loudness), §15 PRD V2.3 amendment text added. Firmware feedback layer + state machine written and compiling (coord §C64) |
| 2026-09-22 | Claude (with Jace) | **PRD V2.3 Draft created** from V2.2 by applying §15 (rows verbatim + the implied consistency edits listed there); §1 traceability retargeted to PRD V2.3; V2.2 docx left untouched |

---

## 15. PRD V2.3 amendment (proposed 2026-09-18 — **applied 2026-09-22**)

**Applied:** `GoSteady PRD V2.3 Draft - Rollator and Family Assistance.docx` (iCloud `Documents/GoSteady/`, created from V2.2, which is left untouched) carries every row below, plus the consistency edits those rows imply: the document-field table (version `2.3 Draft`, revision date and decision cutoff 2026-09-22, revision scope), the DEV-09 qualification (`speaker` → `buzzer` in the energy budget), the qualification columns of AST-HW-03 / AST-FW-02 / AST-FW-04 (speech-intelligibility wording → loudness / cadence / tone wording), the §7 gate bullet "intelligible speaker" → "buzzer", the §8 mapping header (`V2.3 disposition`), and a §10 revision-history row. §2.1 / §3 voice-call + SMS outreach is untouched (Q16 still open).

Original proposal, kept for the record — replace/append in `GoSteady PRD V2.2 Draft - Rollator and Family Assistance.docx` §5 (all rows stay `PROPOSED — FAMILY ASSISTANCE`):

| ID | Proposed V2.3 requirement text |
|---|---|
| **AST-HW-03** (replace) | The device shall include a small buzzer capable of clearly audible, distinct beep patterns for the countdown, cancellation, cloud acknowledgement, test success, not-set-up and fault states. Spoken prompts are not required. |
| **AST-HW-04** (amend) | … after adding the moving actuator and a **sound port or acoustic membrane for the buzzer**. |
| **AST-FW-02** (replace) | On a validated press the device shall immediately give a short acknowledgement beep and then beep once per second; after 10 seconds the cadence shall change to a double beep per second and in the final 3 seconds to rapid beeps. **Pressing and holding the assistance button for 3 seconds at any time before transmission — including holding the initial press — shall cancel the incident** and produce a distinct falling cancellation tone; a steady tone while the button is held shall indicate that the hold is registering. |
| **AST-FW-04** (amend) | After authenticated acknowledgement … the device shall play a distinct rising confirmation tone. It shall not play this tone before acknowledgement and shall use bounded retry plus a distinct failure tone if acknowledgement is not received. |
| **AST-FW-06** (amend) | … The test-complete feedback shall be audibly distinct from the live confirmation tone. |
| **§6 exclusions** (add) | Spoken prompts / speech output through the device: out of scope for V1 (buzzer cadences only). |
| **§7 gates** (amend) | Replace "exact 20-second and 10-second spoken prompts, intervening tone, second-press cancellation" with "the 20-second beep countdown with its 10-second and 3-second cadence changes, the 3-second press-and-hold cancellation, and the confirmation/failure tones". Add: buzzer loudness and pattern recognisability validated with older adults through the production enclosure. |
| **§2.1 / §3** (no change) | Direct family outreach by voice call and SMS is unchanged (pending Q16). |

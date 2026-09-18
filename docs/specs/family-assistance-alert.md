# Family Assistance Alert — button → speaker → cloud → Care Circle voice + SMS (umbrella spec)

> **Status:** 🟡 **Draft v0.3 — 2026-09-18.** Scoping + cross-system design. **FA-0: button → speaker PROVEN on the bench** (SB8/SB9 cut, `prj_assist_bench.conf` flashed, full 20 s sequence with the module's factory clips, module answers in 570 ms; coord §C63.6). Remaining FA-0: load the real prompts (needs a micro-USB *data* cable), current/rail-sag measurements, GNSS TTFF. No cloud code. Written against **PRD V2.2 Draft (2026-09-18) §5** (the product authority for this feature) and the repo evidence surveyed the same day (firmware `main`@`55dbf92`, portal `feature/infra-scaffold`@`1f2c784`).
> **Scope:** A deliberate assistance button on the rollator device that (1) gives the walker user spoken feedback through a speaker, (2) publishes an assistance request with best-available location over LTE-M, and (3) makes the cloud **concurrently call (Retell) and text (Twilio) every enrolled Care Circle member**, tracking delivery and acknowledgement in a durable incident record. **Care Circle only — no monitoring center, no EMS dispatch, no fall detection.**
> **Spans:** firmware (`gosteady-firmware`), cloud (`infra/`), consumer app (`lib/d2c/`), hardware prototype (Thingy:91 X + DFR0534).
> **Depends on (deployed):** Core Device Contract v1 (`activate`/`wipe` cmds, `last_cmd_id` echo, connection-coordinator), 1A/1B ingestion, D2C auth pool + claim, Care Circle (`d2c-care-circle.md`), Twilio SMS (`_shared/sms.py`), 1.7 audit, 2A-AA ack.
> **Adjacent gaps this feature does NOT fix but is gated by:** session-storage exhaustion (firmware spec `2026-07-31-session-storage-exhaustion.md`, coord §C62) and outbound alert delivery (PRD APP-06, Phase 2C stub). See §9.
> **Related:** [ARCHITECTURE.md](ARCHITECTURE.md) §4/§6/§7, [2026-07-01-device-types.md](2026-07-01-device-types.md) (Core vs per-type contracts), [d2c-care-circle.md](d2c-care-circle.md), [d2c.md](d2c.md), [phase-1c-slim-notifications.md](phase-1c-slim-notifications.md), coord doc §C63.

---

## 0. In one paragraph

The walker user presses the large actuator on the cupholder. Within ~1.5 s the speaker says *"Assistance button pressed, contacting care circle in 20 seconds."* The device immediately brings the modem out of PSM and opens its MQTT session while the countdown runs; at 10 s it plays a tone and says *"Contacting care circle in 10 seconds."* A second press cancels with distinct feedback. At 20 s it publishes an `assistance_request` (unique incident id, press + send timestamps, battery/radio, and whatever location it has — usually *none yet*) on a new, policy-restricted topic `gs/{serial}/assist`. The cloud writes a durable incident, projects it into the D2C dashboard as a critical alert, enqueues one voice-call job and one SMS job **per enrolled member**, and only then sends an authenticated `assist_ack` downlink — which is what makes the device say *"Contacted care circle."* Retell then places the calls and Twilio sends the texts, both stating plainly that this is a family notification and not emergency services; webhooks record who answered / got voicemail / was delivered. After the ack, the device runs a bounded GNSS acquisition and publishes a follow-up location, which triggers one follow-up SMS with a map link. Care Circle members tap "I'm on it" in the app; the incident closes when a member marks it resolved. A test mode, armed from the app, exercises the exact same path but routes only to the tester.

```
 Rollator user                 Device (nRF9151 + DFR0534)                 AWS                              Care Circle
 ─────────────                 ──────────────────────────                 ───                              ───────────
 press ──────────────────────▶ T0   power audio, say 20 s prompt
                               T0   wake modem, MQTT connect (PSM exit)
                               T10  tone + 10 s prompt
 (2nd press = cancel)          T20  PUBLISH gs/{serial}/assist ──────────▶ assistance-dispatcher
                                                                          • put incident (idempotent)
                                                                          • project Alert History row ───▶ dashboard card
                                                                          • enqueue voice+SMS per member
                               ◀──────────────────── cmd: assist_ack ◀──── • publish ack (cmd topic)
                               say "Contacted care circle"                assistance-notifier (SQS)
                               GNSS single fix (≤180 s) ──▶ event:location  • Retell create-phone-call ─────▶ voice call
                                                                          • Twilio SMS (+status cb) ──────▶ text
                                                                          webhooks ◀── Retell / Twilio    "I'm on it" ──▶ ack
```

---

## 1. Requirements traceability (PRD V2.2 §5 → this spec)

| PRD ID | Requirement (abridged) | Where satisfied | Phase |
|---|---|---|---|
| AST-HW-01 | One large tactile actuator mechanically operating the Thingy:91 X center button | §4.2 (Button 1 = SW3 on P0.26; also the MCUboot recovery button — §4.6) | FA-0 (mech: enclosure track) |
| AST-HW-02 | Resist false actuation during rolling/braking/transport | §5.2 debounce + deliberate-press gesture; §10 T-rows; enclosure track | FA-6 |
| AST-HW-03 | Speaker: intelligible speech + distinct tones for countdown/cancel/ack/test/fault | §4.3–4.5 DFR0534 route; §5.3 prompt set | FA-0/FA-1 |
| AST-HW-04 | Ingress/cleaning/structure preserved with actuator + sound opening | Enclosure track (out of firmware/cloud scope; listed as gate) | FA-6 |
| AST-FW-01 | Validated press → Assistance Pending; start LTE + GNSS work; 20 s cancel window | §5.2 state machine; §5.5 GNSS/LTE coexistence (why "LTE first, GNSS after ack") | FA-1 |
| AST-FW-02 | Exact spoken prompts at T0 and T10, tone, second-press cancel with distinct feedback | §5.3 prompt table (verbatim strings) | FA-1 |
| AST-FW-03 | Publish `assistance_request` with incident id, identity, timestamps, battery/radio, best location | §5.4 payload contract | FA-1/FA-2 |
| AST-FW-04 | Say "Contacted care circle" only after **authenticated** ack that cloud durably accepted + started workflow; bounded retry + failure feedback; priority over routine traffic | §5.4 ack semantics; §6.3 dispatcher ordering; §5.10 priority path | FA-1/FA-2 |
| AST-FW-05 | No fix ⇒ still send; send stale fix with age; `location_status` acquiring/unavailable; follow-up location update | §5.5 location ladder; §6.3 `event:location` | FA-5 |
| AST-FW-06 | Test mode end-to-end without notifying live contacts unless enrolled as test recipients | §6.3 test arming (cloud-armed, device path identical); §7 | FA-3/FA-4 |
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
| L1 | Prompts are **verbatim** PRD text: T0 *"Assistance button pressed, contacting care circle in 20 seconds."*; T10 tone then *"Contacting care circle in 10 seconds."*; success *"Contacted care circle."* | AST-FW-02/04 | Audio assets are fixed strings; countdown is 20 s with a 10 s mid-prompt |
| L2 | *"Contacted care circle"* is spoken **only** after an authenticated cloud ack that the incident is durable **and** the notification workflow has started | AST-FW-04 | Ack is sent by the dispatcher after PutItem + SQS enqueue succeed; broker PUBACK is **not** sufficient |
| L3 | Assistance traffic has priority over heartbeat/activity/snippet traffic | AST-FW-04 | New "priority-0" publish path opens its own cellular cycle and may reuse a live session (§5.10) |
| L4 | Care Circle only. No monitoring center, no EMS, no professional-response language anywhere (copy, app, agreements) | AST-SW-07, PRD §6 | §8 copy includes an explicit "not emergency services" line in every channel |
| L5 | Not fall detection; tip-over telemetry (ACT-06) never initiates an assistance request | PRD §4.2 / §6 | The only trigger is the deliberate button press (or an app-armed test) |
| L6 | Core Device Contract v1 is extended, not forked: new uplink class `gs/{serial}/assist`, new cmds `assist_ack` / `assist_arm` using the existing cmd envelope + `last_cmd_id` echo + coordinator republish | DT4/DT5, ARCH §7.0 | No per-type topics; walker cap can adopt later unchanged |
| L7 | An assistance request bypasses `notificationsPaused` and threshold suppression | AST-SW-01 | Dispatcher never consults `pause_check` |
| L8 | Audio module is **power-gated**; it draws nothing between incidents | DEV-09 (1-year battery target) | VDD_EXP_BRD load switch (P0.03) is the gate; §4.4 |
| L9 | Every member phone used for fan-out is verified (SMS-OTP possession) and the member has opted in per channel with recorded consent (TCPA prior-express-consent posture) | AST-SW-05 | Fan-out reads `RoleAssignments.phone` **only** for rows with `assistancePrefs.{voice|sms}=true` + `consentedAt` |
| L10 | Location data is identity-bearing: CMK-encrypted at rest, never logged in plaintext, retention bounded | ARCH §9/§10 | Incidents table is an `IdentityTable`; PII scrubber gains `lat/lon/latitude/longitude/phone/to_number` |
| L11 | D2C-first; facility channel out of scope for v1 | APP-07 | All routes under `/api/v1/d2c/*`; no facility UI |
| L12 | Feature is flag-gated end-to-end (`ASSISTANCE_ALERTS_ENABLED`) and the device only arms after cloud readiness | AST-SW-05 | A press on an un-armed device says *"Assistance is not set up yet."* and sends nothing |
| L13 | Test incidents are distinguishable end-to-end (`isTest`, `mode:"test"` in the ack, "TEST —" prefix in copy, separate Retell agent) | AST-FW-06 | Never notifies live contacts unless enrolled as test recipients |

---

## 4. Hardware — prototype path and what the bench must settle first

### 4.1 Prototype BOM (as ordered)

| Part | Role | Notes |
|---|---|---|
| DFRobot **DFR0534** Gravity MP3/voice module | Audio: 8 MB flash, MP3/WAV hardware decode, UART @ 9600, 30 volume levels, onboard amp, BUSY pin | Specs from the DFRobot datasheet (`DFR0534_Web.pdf`): 3.3–5 V; **no idle/playback current is published** → must be measured (§4.7) |
| SparkFun **CAB-28768** Qwiic (JST-SH 1 mm) → Gravity (JST-PH 2 mm) cable | Thingy:91 X P1 → DFR0534 Gravity header | Pin-for-pin: P1 1→1 … 4→4; which side is T (module TX) vs R (module RX) is verified at bench |
| DFRobot **FIT0502** 3 W / 8 Ω enclosed speaker | Load matching the DFR0534 amp | Connector family unverified (user's caveat) — confirm mating |
| Micro-USB data cable | One-time prompt upload (module mounts as a USB drive) | — |
| #11 blade + multimeter | SB8/SB9 surgery + continuity | **Do not cut before §4.3's check** |

### 4.2 Thingy:91 X facts that shape the design (Nordic HW UG 4492_037 + board DTS in NCS 3.2.4)

| Item | Fact | Implication |
|---|---|---|
| Button 1 | SW3 → nRF9151 **P0.26**, active-low, pull-up; DT alias `sw0` **and** `mcuboot-button0` | The assistance actuator; also the MCUboot serial-recovery entry pin (§4.6) |
| P1 connector | JST **SM04B-SRSS-TB** (Qwiic/STEMMA QT). Pin 1 GND, pin 2 **VDD_EXP_BRD** (3.3 V), pin 3 = `EXP_BOARD.PIN2` = **nRF9151 P0.18** (bridged to SDA by SB9), pin 4 = `EXP_BOARD.PIN1` = **nRF9151 P0.19** (bridged to SCL by SB8), both through a **TXS0102** level shifter (U24). **Resolved 2026-09-18 from schematic PCA20065 v2.0.0** (nRF9151 sheet net labels; the label column lines up with P0.20 = `nRF53_RESET` above and P0.15…12 = SPI/FLASH_CS below) | Two dedicated GPIOs — exactly what a UART needs; TXS0102 handles push-pull at 9600 baud |
| VDD_EXP_BRD | From nPM1300 **BUCK2 (3.3 V, 200 mA max)** through load switch **U14 (TCK106AG)**, enable = nRF9151 **P0.03** (`exp_board_enable`, off by default) | Free power gate for the audio module (L8). BUCK2 also feeds LED1/2 and the GNSS LNA / RF front-end switch → rail sag risk (§4.7) |
| I²C bus (i2c2) | nRF9151 SDA **P0.09** / SCL **P0.08**, 100 kHz; carries **nPM1300 (0x6b)** and **ADXL367 (0x1d)** — the fuel gauge and the wake-on-motion path | Anything that isolates the nRF9151 from this bus is fatal to the product |
| Serial instances | nRF91 shares one peripheral slot per index: UARTE0/SPIM0/TWIM0 @ 0x8000 … UARTE3/SPIM3/TWIM3 @ 0xB000. In use: **uart0** (console, P0.00/01), **uart1** (nRF5340 bridge dump channel, P0.04/05, 1 Mbaud), **i2c2 = TWIM2** (slot 2), **spi3 = SPIM3** (slot 3, flash + BMI270 + nRF7002) | **There is no free UARTE.** `uart2` collides with i2c2, `uart3` with spi3 (§4.3) |
| GNSS | Onboard GNSS antenna (A2) + LNA (U9), LNA power via U13 controlled by the modem **COEX2** pin; the board's `MODEM_ANTENNA` Kconfig (default y) issues `AT%XCOEX0=1,1,1565,1586` at modem init | GNSS hardware is ready; firmware only needs the `nrf_modem_gnss` API (§5.5) |
| Free nRF9151 GPIOs (per DTS) | P0.18, P0.19, P0.21–P0.25 (P0.21–25 are the trace pins on the P9 card edge) | Candidates for `EXP_BOARD.PIN1/2` if they are dedicated GPIOs; none is on a friendly connector otherwise |

### 4.3 Hard finding 1 — no spare UART, and the SB8/SB9 topology is not documented

**No spare UARTE.** The only viable ways to talk to the DFR0534 from the nRF9151:

| Route | How | Cost | Works when… |
|---|---|---|---|
| **R1 — re-pin uart1** ★ preferred if R-check passes | Move `uart1` from P0.04/05 (bridge) to the two P1 GPIOs at 9600 baud in assistance builds | Loses the uart1 dump/BLE-NUS bench channel in those images (already unused in every `FIELD_MODE` build) | P1 pins 3/4 are **dedicated nRF9151 GPIOs** after cutting SB8/SB9 ("reading C") |
| **R2 — I²C→UART bridge on P1** (no cut) | SC16IS750 breakout on the P1 I²C bus (0x48–0x4F, no conflict with 0x1d/0x6b); its UART drives the DFR0534, its GPIOs read BUSY; whole thing behind the same VDD_EXP_BRD gate (TXS0102's VCC-isolation keeps unpowered P1 devices off the 1.8 V bus) | +1 IC (~$5–10), ~150-line register driver, a transport abstraction so production can use a native UARTE | **Any** topology — needs no solder-bridge surgery |
| R3 — bit-banged TX on a P1 GPIO | Software UART TX (9600 8N1 is 104 µs/bit) from a dedicated thread | Jitter risk from modem-lib/sampler ISRs; RX (status) hard | Same dependency as R1; strictly worse than R1 |

**Topology — RESOLVED 2026-09-18 from the schematic** (`PCA20065_Schematic_And_PCB.pdf` v2.0.0 and the Altium `pca20065_nrf9151.SchDoc` in Nordic's "Thingy:91 X Hardware files 2.0.0"): `EXP_BOARD_PIN1` and `EXP_BOARD_PIN2` are net labels on the nRF9151 GPIO column at the **P0.19** and **P0.18** rows — dedicated GPIOs ("reading C" below). SB8/SB9 only bridge those two nets onto SCL/SDA, so cutting them is safe **and required** (closed, a UART TX on P0.19 fights the I²C master). **Route R1 selected** (D15); `boards/assist_audio_uart1.overlay` re-pins uart1 to TX P0.19 / RX P0.18 at 9600 baud.

For the record, the readings that were open before the schematic arrived:

| Reading | What SB8/SB9 sit between | Outcome |
|---|---|---|
| A | nRF9151 **P0.08/P0.09** and the shared sensor bus | ruled out — would have killed the ADXL367 + nPM1300 |
| B | the shared bus and a **floating** level-shifter net | ruled out |
| **C** ✅ | the shared bus and **dedicated GPIOs P0.19 / P0.18** | **confirmed** |

**HW-0 bench result (2026-09-18, coord §C63.6):** SB8/SB9 cut; sensors intact after the cut (ADXL367 armed, fuel gauge up, boot counter persisted); the DFR0534 header reads **`T R - +`** and the SparkFun cable lands **blue / yellow / black / red** on it — DFRobot labels `T`/`R` from the *host's* side, so **our TX = P0.18 (P1 pin 3, blue → `T`)** and **our RX = P0.19 (P1 pin 4, yellow → `R`)**. The first image had them the other way round (no reply); the swapped mapping answered the status query **~570 ms after power-up** and the full countdown played the module's factory clips at the right times. The canonical overlay now carries this mapping.

Still to do at the bench: load the real prompts (the first micro-USB cable was charge-only — the module powered but never enumerated), then the current / rail-sag / GNSS measurements below.

### 4.4 Power gating is mandatory
- The DFR0534/JQ8400-class modules idle in the **10–20 mA** range (unpublished; measure). Left powered that is 7–15 Ah/month — thousands of times the 48 mAh/month pre-activation budget. Therefore the module is powered **only** from press to end-of-prompt (plus tests), via `exp_board_enable` (P0.03) → U14 → VDD_EXP_BRD. Zephyr already models it as a `regulator-fixed`; firmware calls `regulator_enable/disable()`.
- Boot-to-ready of the module after power-up is expected at ~1–2 s (measure); the T0 prompt therefore starts ~1.5 s after the press. The LED goes on at the press itself so feedback is never silent.
- Guard against auto-play on power-up: track 01 is 100 ms of silence.

### 4.5 DFR0534 control protocol (from the DFRobot datasheet)
9600 8N1. Frame `AA <cmd> <len> <data…> <SM>`, `SM` = low byte of the sum of all preceding bytes (check: `AA 13 01 14 D2`, `AA 01 00 AB`).

| Purpose | Frame | Reply |
|---|---|---|
| Query play status | `AA 01 00 AB` | `AA 01 01 <00 stop|01 play|02 pause> SM` |
| Play / pause / stop | `AA 02 00 AC` / `AA 03 00 AD` / `AA 04 00 AE` | — |
| Play track N (1–65535) | `AA 07 02 <hi> <lo> SM` (e.g. `AA 07 02 00 08 BB`) | — |
| Play by path | `AA 08 <len> <drive> <path> SM` | — (fallback if index order proves unreliable) |
| Volume 0–30 | `AA 13 01 <vol> SM` (`AA 13 01 14 D2` = 20) | — |
| Loop mode | `AA 18 01 <mode> SM` (`03` = play once then stop) | — |
| End current op | `AA 10 00 BA` | — |
| Track count | `AA 0C 00 B6` | `AA 0C 02 <hi> <lo> SM` |
| BUSY pin | high while playing | GPIO alternative to polling `01` |

Gotchas to design around: track index follows **copy order**, not filename — copy prompts one at a time in order (or use play-by-path); set volume explicitly after every power-up; set loop mode `03` once (persist unknown); the header's T/R labels are the module's TX/RX — through the pin-for-pin cable, whichever P1 signal lands on **R** is our TX (swap in pinctrl, never in the cable).

### 4.6 MCUboot serial recovery rides the same button
The rollator pilot image builds MCUboot with `CONFIG_MCUBOOT_SERIAL=y`, `CONFIG_BOOT_SERIAL_ENTRANCE_GPIO=y` (`mcuboot-button0` = P0.26) and `BOOT_SERIAL_DETECT_DELAY=0`. **A bottom-cap actuator held while batteries are inserted (or during any reset) would trap the device in serial recovery** until the next reset. Deployment images must disable the GPIO entrance (`CONFIG_BOOT_SERIAL_ENTRANCE_GPIO=n` in a `sysbuild/mcuboot.conf` fragment for the pilot/field overlays); SWD remains the recovery path. Tracked as FA-1 work.

### 4.7 Electrical risks to measure at HW-0
- **Rail sag:** the amp's transients at 3.3 V into 8 Ω can exceed BUCK2's 200 mA on loud content, and BUCK2 also feeds the GNSS LNA and LEDs. Mitigate: volume ≤ ~20/30 for speech, 470–1000 µF bulk capacitance at the module, scope VDD_EXP_BRD and the 1.8 V rail during the loudest prompt. Production: dedicated audio rail from VSYS with its own load switch (the nPM1300's LSOUT2 is only 100 mA — not it).
- **Idle + playback current** of the DFR0534 (datasheet silent) — drives the incident energy line in §5.8.
- **Level shifter behaviour when VDD_EXP_BRD is off:** confirm P1 devices do not load SDA/SCL (TXS0102 VCC isolation); confirm the sensors keep working with the module unpowered and powered.
- **Speaker mating** (FIT0502 lead vs DFR0534 SP± pads/connector).

---

## 5. Firmware design (`gosteady-firmware`)

### 5.1 Module map

| File | New/changed | Responsibility |
|---|---|---|
| `src/assist.c/.h` | **new** | Incident state machine on its own thread (`gs_assist`, prio 6, 2 KB); button semantics; persistence of a pending incident; timing constants |
| `src/audio_dfr0534.c/.h` | **new** | Power gate (regulator API), UART transport (R1) or I²C-bridge transport (R2), command frames, `audio_play(prompt_id)`, `audio_wait_done(ms)`, self-check |
| `src/gnss.c/.h` | **new** (FA-5) | Single-fix acquisition around `nrf_modem_gnss_*`; last-fix cache (RAM + `/lfs/assist/lastfix.bin`); PVT → payload fields |
| `src/cloud.c` | changed | `ASSIST_TOPIC_FMT "gs/%s/assist"`; `gosteady_cloud_assist_publish_wait_ack()` (own cycle, modelled on `connect_publish_stay()`); cmd dispatch gains `assist_ack` + `assist_arm`; heartbeat extras `assist_capable`, `assist_armed`, `audio_ok`, `gnss_fix_age_s` |
| `src/main.c` | changed | Button wired when `CONFIG_GOSTEADY_ASSIST_ENABLE` even under `FIELD_MODE`; ISR gives `assist_button_sem` instead of the session toggle in assistance builds; LED arbitration for the assistance pattern |
| `src/wipe.c` | changed | Wipe clears `/lfs/assist/*` (armed flag, pending incident, last fix) |
| `src/version.h` | changed | `rol-0.2.0-ww` / `-pilot` / `-bench` line; changelog block |
| `boards/thingy91x_nrf9151_ns.overlay` | changed | R1: `uart1` re-pinned + `current-speed = <9600>` (assistance builds only, via a second overlay `boards/assist_uart1.overlay`); `exp_board_enable` used |
| `Kconfig`, `CMakeLists.txt`, `prj_rollator_*.conf` | changed | §5.7 |
| `sysbuild/mcuboot.conf` | **new** | `CONFIG_BOOT_SERIAL_ENTRANCE_GPIO=n` for deployment overlays (§4.6) |

### 5.2 State machine and timeline

States: `IDLE → PENDING (countdown) → SENDING → AWAIT_ACK → CONFIRMED → LOCATING → IDLE`, with `CANCELLED` and `FAILED_RETRYING` side exits. One incident at a time; a press during `SENDING/AWAIT_ACK/CONFIRMED` is ignored (logged); a press during `LOCATING` is a **new** incident only after `IDLE` (debounced).

| T (s) | Device action | Notes |
|---|---|---|
| 0.00 | ISR: 50 ms debounce (re-read after 50 ms, must still be low); ignore if not armed (`assist_armed=false`) → play *"Assistance is not set up yet."* and stop | Deliberate-press gesture: single press ≥ 50 ms. A "hold ≥ 3 s" alternative is rejected (§11 D5) |
| 0.00 | LED: solid red (assistance pending) — owns the LED until IDLE | Distinct from blue (pre-activation) and green (recording) |
| 0.00 | Power audio (P0.03 high); wake cloud: `assist_publish_wait_ack()` starts **connect now** (PSM exit + TLS + MQTT if no live session) | Connect typically 3–10 s; wait-for-cellular has no timeout today — assistance uses a bounded variant |
| ~0.6 | Prompt **P02** *"Assistance button pressed, contacting care circle in 20 seconds."* | Module boot measured **≈ 570 ms** on the bench (2026-09-18) |
| 10.0 | Tone **P03** then **P04** *"Contacting care circle in 10 seconds."* | |
| 0–20 | Second press ⇒ `CANCELLED`: play **P05** (tone + *"Cancelled."*), close the session, power audio off, LED off. **No publish** (a `cancel` telemetry event is optional, D9) | |
| 20.0 | Build payload (§5.4), persist to `/lfs/assist/pending.json`, PUBLISH (QoS 1) on the session opened at T0; on PUBACK enter `AWAIT_ACK` | If the session is still connecting, publish as soon as it is up |
| 20–50 | Wait ≤ **30 s** for `assist_ack` (cmd topic, matched on `incident_id`). On ack: play **P06** *"Contacted care circle."* (or **P08** test variant), `CONFIRMED` | Ack normally lands < 3 s after PUBACK |
| ack+0 | Echo `cmd_id` in the next heartbeat (existing `last_cmd_id` plumbing); persist `acked` | Cloud gets a second, durable confirmation |
| ack+0 | `LOCATING`: release RRC quickly (RAI `SO_RAI_NO_DATA` on the MQTT socket if supported, else wait for the network inactivity release), start GNSS single fix, retry ≤ 180 s | §5.5 |
| fix | Publish `event:"location"` (same incident id), then `IDLE`; audio off, LED off | One follow-up per incident |
| no ack | Retry publish at +30 s, +90 s, +210 s (same incident id, `seq` incremented); after the 3rd miss play **P07** *"Could not reach your care circle yet. Still trying."* and stay in `FAILED_RETRYING` with the modem awake up to **10 min** total; thereafter passive retry piggybacks every heartbeat/connect until acked or 24 h old | Bounded energy; cloud flags late arrivals |
| reboot | `pending.json` present and unacked ⇒ resume `FAILED_RETRYING` at boot (never re-run the countdown) | Survives the crash class in coord §C62 |

Session interaction: the incident never starts/stops a session; `session_active` is reported in the payload only.

### 5.3 Prompt set (audio assets, track index = copy order)

| # | File | Content | Format |
|---|---|---|---|
| 01 | `01_silence.wav` | 100 ms silence (power-up guard) | WAV 16 kHz mono PCM |
| 02 | `02_pressed_20s.wav` | *"Assistance button pressed, contacting care circle in 20 seconds."* | " |
| 03 | `03_tone.wav` | 2 × 880 Hz 150 ms beeps | " |
| 04 | `04_contacting_10s.wav` | *"Contacting care circle in 10 seconds."* | " |
| 05 | `05_cancelled.wav` | descending two-tone + *"Cancelled."* | " |
| 06 | `06_contacted.wav` | *"Contacted care circle."* | " |
| 07 | `07_retrying.wav` | *"Could not reach your care circle yet. Still trying."* | " |
| 08 | `08_test_ok.wav` | *"Test complete. Care circle contacted."* | " |
| 09 | `09_not_setup.wav` | *"Assistance is not set up yet."* | " |
| 10 | `10_fault.wav` | error tone (audio self-check fails to hear BUSY) | " |

Generated once with a neural TTS voice (Amazon Polly, same persona as the Retell agent — D12), slow rate, ≥ 70 dB SPL target at 0.5 m at volume 20/30 (validate in FA-6). Files are versioned in `gosteady-firmware/audio/` with a checksum manifest; the device reports `audio_ok` (self-check: track count == manifest count) in heartbeats.

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
| `assist_ack` | `cmd_id:"asst_<uuid>"`, `ts`, `incident_id`, `mode:"live"|"test"`, `status:"accepted"|"not_ready"` | Match `incident_id` to the pending incident; `accepted`+`live` → P06; `accepted`+`test` → P08; `not_ready` → P09 and clear armed flag; echo `cmd_id` in next heartbeat |
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
| `GOSTEADY_ASSIST_ENABLE` | n (`depends on GOSTEADY_CLOUD_ENABLE`) | Compiles `assist.c`; wires the button under FIELD_MODE; new topic/cmds/heartbeat fields |
| `GOSTEADY_ASSIST_AUDIO` | n | DFR0534 driver. `GOSTEADY_ASSIST_AUDIO_XPORT_UART1` (R1) / `_I2C_SC16IS750` (R2) choice; `#error` if `UART1` is chosen together with the dump channel in a non-FIELD build |
| `GOSTEADY_ASSIST_AUDIO_VOLUME` | 20 | 0–30 |
| `GOSTEADY_ASSIST_GNSS` | n | Compiles `gnss.c` (FA-5); isolable RAM/energy cost |
| `GOSTEADY_ASSIST_COUNTDOWN_S` / `_MIDPROMPT_S` | 20 / 10 | L1 |
| `GOSTEADY_ASSIST_ACK_WAIT_S` | 30 | per attempt |
| `GOSTEADY_ASSIST_RETRY_AWAKE_S` | 600 | active-retry window |
| `GOSTEADY_ASSIST_GNSS_TIMEOUT_S` | 180 | single-fix retry |

`CMakeLists.txt`: `target_sources_ifdef(CONFIG_GOSTEADY_ASSIST_ENABLE app PRIVATE src/assist.c)`, `…_ASSIST_AUDIO … src/audio_dfr0534.c`, `…_ASSIST_GNSS … src/gnss.c`. Overlays: `prj_rollator_pilot.conf` / `prj_rollator_field.conf` gain the assist symbols behind a new `prj_rollator_assist.conf` delta during FA-1–FA-5, folded into the pilot overlay at FA-6. `docs/build-configurations.md` matrix updated in lockstep. Version line bumps to `rol-0.2.0-*` (12 chars, fits the 15-char `.dat` cap); the pending `cap` suffix decision in `build-configurations.md` is respected (no third dimension added).

### 5.8 Energy budget (per incident, 1350 mAh reference cell)

| Term | Estimate | Basis |
|---|---|---|
| Audio module powered ~40 s incl. prompts (assume 60 mA avg) | ~0.7 mAh | to be measured (§4.7) |
| Connect + publish + ack hold ~40 s | ~0.6 mAh | 0.25 mAh/cycle + ~50 mA hold |
| GNSS ≤ 180 s | ~1.5–2.3 mAh | nRF91 GNSS tracking current |
| Follow-up publish | ~0.25 mAh | |
| **Total per incident** | **≈ 3–4 mAh (~0.3 %)** | negligible per event |
| Standing cost when armed | **0** | audio unpowered, button is a sense-edge input |
| Monthly test | ≈ 4 mAh | |
| Worst case: 10 min awake retry in no-coverage | ≈ 10–15 mAh | bounded by `RETRY_AWAKE_S` |

Conclusion: the feature is compatible with the one-year target **only** because of L8; the audio module's idle current is the single number that could break it.

### 5.9 RAM / thread budget
Rollator pilot build has ~84 KB RAM headroom. Planned additions: `gs_assist` thread 2 KB + 1 KB buffers; audio driver ~0.5 KB; `gnss.c` ~1 KB (PVT struct ~300 B, no `location` library). Expected < 6 KB. Re-measure at each phase; the `location`/A-GNSS libraries are explicitly **not** pulled in for v1.

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
| **Assistance settings** (new, under Account) | Owner: enable/disable, location-sharing consent (walker or owner on their behalf), readiness card ("Ready — 2 contacts" / "Not ready — add a contact who accepts calls or texts"), last test date + result, **Run a test** (arms for 10 min, shows live progress) |
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
**Device prompts:** §5.3.
**Consent (prefs enable):** "I agree to receive automated phone calls and text messages from GoSteady when {WalkerName} presses the assistance button. These are family notifications, not emergency services. Message and data rates may apply; reply STOP to opt out of texts."

---

## 9. Phasing, exit criteria, prerequisites

| Phase | Scope | Exit criteria | Depends on |
|---|---|---|---|
| **FA-0 Hardware gate** (≈ 1 week, bench) | ~~topology~~ done (schematic; R1); ~~bench harness~~ built; ~~cut, flash, press~~ **button → speaker PROVEN 2026-09-18** (factory clips, 570 ms module boot, both UART directions, sensors intact after the cut, speaker mates); **remaining:** load the real prompts (data cable), DFR0534 idle/playback current + rail-sag, power-gate 0 mA off, GNSS TTFF indoors/outdoors/window (10 fixes each) | Numbers recorded in coord §C63.x; energy line in §5.8 replaced with measurements | Hardware on the bench (done) |
| **FA-1 Firmware core** | `assist.c` + audio driver + button un-gate + LED + persistence/retry + `assist_ack/arm` cmd handling + heartbeat extras + MCUboot entrance fix + shell hooks; **no GNSS**; acceptance with the bench ack stub | Bench: press → prompts at 1.5/10 s → publish at 20 s → stub ack → "Contacted care circle"; cancel path; retry path with the antenna wrapped; reboot mid-`AWAIT_ACK` resumes; RAM/flash deltas recorded; 0 faults over a 24 h soak with hourly presses | FA-0 |
| **FA-2 Cloud pipeline** | Policy + rule, incidents table, dispatcher (request/location), ack, projection, Patient/RoleAssignments fields, readiness + `assist_arm`, heartbeat/coordinator dispatch, `e2e-assistance-alert.py` (synthetic device + JWTs) | Real device: ack latency p95 < 10 s from PUBACK on dev; duplicate request ⇒ same ack; not-ready ⇒ P09 + disarm; alert card visible in the D2C app via the existing alerts read | FA-1 |
| **FA-3 Notifications** | Notification stack real: queue, notifier (Retell + Twilio + StatusCallback), webhooks, retries, roll-up, canary, alarms, dashboard | Live two-phone test: one press ⇒ both members get a call **and** a text within 60 s of the ack; outcomes visible in the incident; voicemail + no-answer + STOP cases recorded; canary green 3 days | FA-2, Retell account + number, test numbers |
| **FA-3b Readiness delivery** | Owner SMS for `device_offline`/`device_silent`/`battery_critical` on assistance-enabled households (≤ 1/day/type), riding the same notifier | `device_silent` reaches the owner's phone (closes the §C62.5 "reached nobody" gap for this cohort) | FA-3 |
| **FA-4 App** | §7 surfaces, copy, agreements, walker visibility | Owner can enable, member can consent, test runs from the app end-to-end, incident card + ack + close work on phones | FA-2/FA-3 |
| **FA-5 Location** | `gnss.c`, location ladder, `event:location`, follow-up SMS, geocoding; **FA-5b** cell-based coarse location if Q7 = yes | Outdoors: fix within 180 s in ≥ 80 % of trials; indoors: request still acked and delivered with "not available"; follow-up SMS exactly once | FA-1, FA-3 |
| **FA-6 Pilot validation** | Human-factors on installed rollators (actuator placement/force, false-press during rolling/braking/transport, cancel gesture), acoustic SPL/intelligibility, poor-coverage runs, energy soak, counsel review, ops runbooks; fold `prj_rollator_assist` into the pilot overlay | All PRD §7 Family-Assistance gates green; prod flag flip decision | everything + enclosure track |

**Prerequisites outside this spec (PRD §7 current-product gates):** the session-storage exhaustion fix (`2026-07-31-session-storage-exhaustion.md` Options 5+2 then 1) must ship before any assistance pilot — a unit that crashes in a blackout cannot be a safety device; the `telemetry_queue` work there should share the `/lfs/assist/pending.json` durability pattern. Vehicle-transport exclusion, battery-claim validation and the OTA decision remain product gates but do not block FA-0…FA-5 engineering.

---

## 10. Test plan (acceptance rows; scripts follow `infra/scripts/e2e-*.py` conventions)

| # | Scenario | Method | Expected |
|---|---|---|---|
| T1 | HW-0 topology check | bench, meter | Reading recorded; sensors alive after any cut |
| T2 | Audio module current off/idle/play | bench, current board | Off = 0 mA; idle/play numbers logged |
| T3 | Rail sag at max prompt volume | scope on VDD_EXP_BRD + 1V8 | No brownout, GNSS LNA rail stable |
| T4 | Press → prompts timing | logic analyser on UART + audio out | P02 ≤ 2.0 s, P03/P04 at 10.0 ± 0.2 s |
| T5 | Cancel by second press at 5 s / 19 s | bench | P05, no publish, session closed |
| T6 | Press while not armed | bench | P09, no publish |
| T7 | Publish at 20 s, ack, P06 | dev cloud | ack latency p95 < 10 s |
| T8 | No coverage (antenna wrapped) | bench | retries at +30/+90/+210 s, P07 after 3rd, awake ≤ 10 min, later delivery flagged `late` |
| T9 | Reboot during AWAIT_ACK | bench | resumes retry, no second countdown, one incident |
| T10 | Duplicate request (seq 2) | `e2e-assistance-alert.py` | one incident, same ack re-sent |
| T11 | Not-ready household | e2e | `rejected_not_ready`, ack `not_ready`, device disarmed |
| T12 | Fan-out to 3 members (2 voice+sms, 1 sms-only) | live phones | 5 jobs, all outcomes recorded |
| T13 | Voicemail / no answer / busy / STOP | live phones | outcomes + single retry where specified |
| T14 | Follow-up location SMS once | e2e + device | exactly one per incident |
| T15 | Test mode | app + device | only the tester notified; "TEST —" copy; P08; `lastTestAt` updated |
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

---

## 13. Risks

| Risk | Impact | Mitigation |
|---|---|---|
| SB8/SB9 cut isolates the sensor bus (reading A) | Loses wake-on-motion + fuel gauge | HW-0 before cutting; R2 fallback |
| DFR0534 idle current unmeasured | Could dominate battery if gating fails | L8; heartbeat `audio_ok` + P0.03 state in extras; T2 |
| Amp transients sag BUCK2 | GNSS LNA/LED brownout, resets | T3, bulk cap, volume cap, production rail |
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

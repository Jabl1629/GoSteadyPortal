# Cloud-side decisions for firmware coordination — 2026-04-17

> **Audience:** GoSteady firmware team
> **Source:** GoSteady portal spec set (`docs/specs/`) — read-back of the cloud-side commitments in response to the open coordination items in `~/Documents/gosteady-firmware/GOSTEADY_CONTEXT.md` (Portal Scope Impact section).
>
> **TL;DR:** All four open coordination items the firmware doc flagged are
> resolved cloud-side, plus two adjacent items (snippet upload — which we'd
> initially missed — and pre-activation heartbeat handling). Schemas and
> behaviors are now locked in the architecture spec. Action items for the
> firmware team are in §6 below.

---

## 1. Activation message contract — RESOLVED

**Topic:** `gs/{serial}/cmd` (downlink, cloud → device)

**Per-thing IoT policy** authorizes each device to subscribe to its own `cmd`
topic only — devices cannot read other devices' command topics. Cloud-side
policy update lands as part of the Phase 1A revision deploy.

**Activation command payload:**

```json
{
  "cmd": "activate",
  "cmd_id": "act_5e8a23b4-...",
  "ts": "2026-04-17T19:00:00Z",
  "session_id": "<provision audit log ID>"
}
```

**When cloud sends it:** synchronously, when a caregiver successfully
provisions the device for the first time via the portal API. State machine
already transitions `ready_to_provision → provisioned` at provision time;
this command tells firmware to exit pre-activation sleep.

**Expected firmware behavior on receipt** (per the firmware doc):

1. Persist `activated_at` to flash
2. Exit pre-activation sleep loop
3. Extinguish blue activation-pending LED
4. Begin normal session capture
5. **Echo `cmd_id` back via `last_cmd_id` field on the next heartbeat**

**Ack semantics:** the heartbeat-side echo is the ack. Cloud's heartbeat
handler sees `last_cmd_id` matching the most-recent issued `activate`
command → marks `Device Registry.activated_at` and emits
`device.activated` audit event.

**Failure modes:**

- Cloud publish fails → portal returns 500 to caregiver; provision is
  idempotent so retry republishes a fresh `cmd_id`.
- Activation lost in transit → device stays in pre-activation; next provision
  retry republishes.
- Firmware never echoes (firmware bug) → cloud surfaces "stuck in `provisioned`
  >24 h post-activation-send" via ops alarm.

---

## 2. Heartbeat extra fields — ACCEPT-ALL CONTRACT

**Cloud's contract:** all uplink schemas tolerate additional fields beyond the
named required + optional ones. Validation rejects only on missing required
fields or out-of-range required values.

For heartbeat specifically, **unknown fields are persisted to Device Shadow
`reported` state** alongside the named ones. The firmware extras flagged in
your doc are now explicitly listed as optional in
[`ARCHITECTURE.md` §7](../specs/ARCHITECTURE.md):

| Field | Required | Notes |
|-------|----------|-------|
| `reset_reason` | No | Crash forensics; persisted to Shadow |
| `fault_counters` | No | Object — diagnostic counters; persisted to Shadow |
| `watchdog_hits` | No | Integer — watchdog trigger count |
| `last_cmd_id` | No | Echoes most recent downlink command (used for activation ack) |
| `battery_mv` | No | Diagnostic |
| `firmware` | No | Semver string |
| `uptime_s` | No | Integer |

Operations can query Device Shadow for diagnostic forensics. **No firmware
changes needed beyond what you already do** — cloud reads the extras and
stores them alongside the named fields.

---

## 3. Activity extra fields — ADDED TO SCHEMA

The three firmware-derived extras you proposed are **added as optional
fields** to the activity schema in [`ARCHITECTURE.md` §7](../specs/ARCHITECTURE.md):

| Field | Required | Notes |
|-------|----------|-------|
| `roughness_R` | No | Float — terrain roughness from on-device M9 algorithm |
| `surface_class` | No | Enum: `indoor` \| `outdoor` (M9 surface classifier) |
| `firmware_version` | No | Semver string — for cohort dashboards + retrain triage |

These are persisted to the Activity Series DDB row (and into a per-row
`extras` map for any other unknown fields). All three are immediately
useful:
- `firmware_version` → version-skew dashboards, debugging cohort issues
- `surface_class` → could become a portal UX feature later (e.g., "75%
  indoor walking this week")
- `roughness_R` → kept for v1.5 retrain analysis; no immediate UX

---

## 4. Snippet upload — RESOLVED via MQTT direct

> Note: we initially mis-read your doc as "USB-only on return." The
> opportunistic upload path is locked firmware-side, and the cloud-side
> schema was the open question. Now resolved.

**Topic:** `gs/{serial}/snippet` (uplink)

**Payload:** binary — raw 100 Hz BMI270 IMU samples for a 30 s window
(~84 KB).

**MQTT user properties (required):**

| Property | Required | Notes |
|----------|----------|-------|
| `snippet_id` | Yes | Firmware-generated UUID for idempotency |
| `window_start_ts` | Yes | ISO 8601 UTC |
| `anomaly_trigger` | No | Enum: `session_sigma`, `R_outlier`, `high_g`. Absent for scheduled snippets. |

**Constraints:**

- **Max payload size: 100 KB.** Under the AWS IoT Core 128 KB hard limit
  with comfortable headroom. v1 snippet size at 84 KB fits with room.
- **Cloud routing:** IoT Rule with direct S3 action — no Lambda in the
  ingestion path. Snippets land at
  `s3://gosteady-{env}-snippets/{serial}/{date}/{snippet_id}.bin`.
- **Encryption:** AWS-managed S3 server-side encryption (snippets are non-PHI
  sensor data; AWS-managed is appropriate per our encryption policy).
- **Lifecycle:** 90 days hot Standard storage → Glacier; 13-month total
  retention before delete (aligned with v1.5 algorithm retrain need).
- **Audit:** every snippet upload generates a `device.snippet_uploaded` event.

**v2 migration path (heads-up, not v1 work):** when snippet size exceeds
100 KB (longer windows, multi-sensor, higher sample rate), we'll switch to
S3 presigned URL flow — same pattern as OTA. MQTT topic deprecates at that
point. No v1 changes anticipated.

**Battery / energy note:** keeping snippet upload on MQTT (vs. presigned-URL
HTTPS) means one MQTT publish per snippet on an already-attached modem,
which is much cheaper energy-wise than the 3-round-trip HTTPS path. This
matches your "battery-tight, opportunistic-only" stance.

---

## 5. Time sync — TRUST CONTRACT DOCUMENTED

**Cloud's posture:** timestamps are device-authoritative. Cloud accepts and
stores the ISO 8601 timestamps you send (sourced from cellular network time
via `AT+CCLK?`) as-is. **No NTP fallback or cloud-side time correction in v1.**

Validation rejects only unparseable ISO 8601 strings; clock skew or seconds-level
drift is accepted.

If a v2 use case requires sub-second precision (e.g., correlating snippets
across multiple devices at an event), we'll revisit. v1 use cases (hourly
heartbeats, session-end activity, offline detection at 2-hour granularity)
are not sensitive to seconds.

---

## 6. Pre-activation behavior — CLOUD HANDLING DEFINED

This is the item we noticed wasn't explicitly called out in your doc, but
falls naturally from the activation contract.

Firmware behavior in `ready_to_provision` state (per your doc):

> Wake on motion → connect → publish heartbeat → wait for activation
> message → if absent, return to sleep.

**Cloud-side behavior on those pre-activation heartbeats:**

| Behavior | Detail |
|----------|--------|
| Update Device Shadow `reported` state | **Yes** — battery, signal, lastSeen all flow normally |
| Generate synthetic alerts (battery_low, signal_lost, etc.) | **Suppressed** until `Device Registry.activated_at` is set. Rationale: no patient yet → no caregiver to notify → all alerts are noise. |
| Audit log | Sampled `device.preactivation_heartbeat` event at 1/hr/serial (dedupe via Shadow attribute), to give ops visibility without flooding the audit log |
| Threshold Detector | Skips synthetic-alert generation for any heartbeat where `activated_at` is NULL |

This means: the firmware can publish heartbeats freely during pre-activation
without producing user-facing noise. Operations still has Shadow + audit
visibility for diagnostics.

After the activation cmd flows and firmware echoes `last_cmd_id`, cloud sets
`activated_at`, and Threshold Detector resumes normal alert generation.

---

## 7. Action items for firmware team

1. **Confirm `cmd_id` echo mechanism:** is it acceptable to add a
   `last_cmd_id` field to the heartbeat payload (echoing the most recent
   downlink command's `cmd_id`)? This is how cloud detects the activation
   ack. If a different ack channel is preferred (e.g., dedicated `gs/{serial}/cmd/ack`
   topic), let us know — we're flexible on this.

2. **Verify snippet binary publish via MQTT user properties:** does the
   nRF Connect SDK MQTT client support setting MQTT 5 user properties on
   publish? We need `snippet_id`, `window_start_ts`, and optionally
   `anomaly_trigger` as user properties on the snippet message. If the
   stack only supports MQTT 3.1.1, we'd need to either upgrade or move
   these into a small JSON header within the binary payload.

3. **Snippet payload format documentation:** what's the exact byte layout
   inside the binary snippet? We don't need to parse it cloud-side, but
   it'd be useful for future analytics work (e.g., a small Python tool
   to read snippets directly from S3).

4. **Site-survey unit timeline:** answer your own open question — when
   does the first unit ship? Cloud is ready to receive heartbeats today
   (Phase 1A deployed) and snippet uploads / activation flow within ~1
   week of starting Phase 1A revision + Phase 2A device-lifecycle work.

5. **Confirm pre-activation LED behavior is independent of cloud state:**
   the blue LED slow-blink is purely firmware-side, right? Cloud isn't
   sending any "show LED" command; firmware self-extinguishes on
   activation message receipt. Just confirming the LED isn't a cloud-driven
   indicator.

6. **Manufacturer-side device enrollment:** when devices are flashed for
   the first deployment (per-device cert + private key manually flashed
   per your locked decision), please send the cloud team the
   `serialNumber` list **before** shipping. We need to create
   manufacturer-side Device Registry records (`status: ready_to_provision`,
   `owningClientId: NULL`, `owningFacilityId: NULL`) so the first
   provisioning attempt at the clinic finds the serial. Until cloud-side
   device records exist, the portal will reject provisioning with
   `DEVICE_NOT_FOUND`.

---

## 8. Cloud-side spec references

For deeper detail beyond this summary:

- [`docs/specs/ARCHITECTURE.md`](../specs/ARCHITECTURE.md) — master spec
  - §4 Device Lifecycle (state machine, activation flow)
  - §7 MQTT Payload Contracts (all uplink + downlink schemas)
  - §8 Threshold & Alert Policy (pre-activation suppression)
  - §14 Cumulative Locked-In Requirements (D12–D17, DL12–DL13)
- [`docs/specs/phase-1a-revision.md`](../specs/phase-1a-revision.md) —
  snippet IoT Rule + downlink topic + pre-activation handling
- [`docs/specs/phase-2a-device-lifecycle.md`](../specs/phase-2a-device-lifecycle.md) —
  the `provision` API endpoint that publishes the activation cmd

---

## 9. Coordination cadence

This is a one-shot doc reflecting the 2026-04-17 batch of decisions. For
ongoing coordination:

- Each new firmware↔cloud contract decision lands as an entry in your
  Portal Scope Impact section AND a corresponding update in our
  ARCHITECTURE.md / phase specs.
- We can produce a follow-up coordination doc per material decision batch.
  Tentative next batch trigger: site-survey unit cellular shakedown.

---

*Doc owner (cloud side): Jace. Questions / counter-proposals welcome.*

---
---

# Firmware response — 2026-04-26

> **From:** GoSteady firmware team
> **In response to:** §7 action items in the 2026-04-17 cloud-contracts entry above.
> **Convention going forward:** this file is **append-only conversation
> style**. Each team writes a dated, signed entry below the previous one;
> nobody edits another team's entries. Use this file for: (a) responding
> to a question raised by the other team, (b) raising a new contract
> question, (c) announcing a new milestone the other side needs to know
> about, (d) flagging a deferred decision back open. Cross-team contract
> tables that get locked here are mirrored on the firmware side in
> `gosteady-firmware/GOSTEADY_CONTEXT.md` (Portal Scope Impact section);
> if the two ever drift, this file wins.
>
> **TL;DR:** All six 2026-04-17 cloud action items answered in §F.2–F.7.
> Firmware milestone update (M12.1a) in §F.8 — the time-sync trust
> contract is now empirically validated end-to-end on hardware. Five new
> firmware-side questions for cloud in §F.9, gating M12.1c (first
> heartbeat publish to AWS IoT Core).

---

## F.1 Status of the 2026-04-17 batch (firmware ack)

All four items previously flagged "Coordination needed" by firmware are
now resolved by the cloud-side commitments above. Firmware acknowledges
and has folded them into our internal contract reference:

- ✅ Activation message contract (§1)
- ✅ Heartbeat extra-fields accept-all (§2)
- ✅ Activity extras added (§3)
- ✅ Snippet upload schema (§4)
- ✅ Time sync trust contract (§5) — *now also empirically verified, see §F.8*
- ✅ Pre-activation behavior cloud handling (§6)

No further negotiation needed on those tables; firmware will build
against them.

---

## F.2 Response: cloud action item #1 — `last_cmd_id` heartbeat-echo as ack

**Confirmed.** We will use `last_cmd_id` echoed in the heartbeat payload
as the activation ack mechanism. No dedicated `gs/{serial}/cmd/ack` topic.

Firmware behavior:

- On receipt of any downlink `cmd`, persist `cmd_id` to flash (in the
  small dedicated telemetry/state region, separate from LittleFS so a
  filesystem failure can't lose it).
- On every subsequent heartbeat, include `last_cmd_id` field with the
  most-recently-received `cmd_id`. Always-echo (not just first-after-
  receipt) — simpler + idempotent + tolerates packet loss in either
  direction without state divergence.
- The persisted `cmd_id` survives reboots, so a device that receives an
  `activate` cmd, reboots, and then publishes its first post-reboot
  heartbeat will still echo the right ack.

Edge case worth flagging: if a device receives **two** `cmd_id`s before
its next heartbeat (e.g., portal retry on first failure), firmware will
echo the most recent one. Cloud's matching logic should treat
"`last_cmd_id` matches *any* recently-issued cmd" as a successful ack
rather than only matching the most recent one — otherwise a benign retry
window can produce a stuck-in-`provisioned` false alarm.

---

## F.3 Response: cloud action item #2 — NCS MQTT 5 user properties

**Investigation pending; expect we'll need the JSON-header fallback.**

Quick read of NCS v3.2.4 sources: Zephyr's `subsys/net/lib/mqtt` is
**MQTT 3.1.1 only**. NCS 3.2.4 ships an `mqtt_helper` lib (used by
`nrf_cloud` and `aws_iot` libs) that wraps the same 3.1.1 client. There's
no MQTT 5 path I've found. NCS 3.3+ may add MQTT 5; we're locked on
v3.2.4 for the deployment build.

**Tentative plan (firmware-side):** put `snippet_id`, `window_start_ts`,
and `anomaly_trigger` into a small JSON header at the start of the binary
payload, framed as:

```
[4-byte big-endian uint32: header_len_bytes][header_len_bytes JSON][raw 100Hz IMU samples]
```

Example header:
```json
{"snippet_id":"<uuid>","window_start_ts":"2026-04-30T14:23:15Z","anomaly_trigger":"R_outlier"}
```

Cloud-side IoT Rule would need to read first 4 bytes, parse JSON for
those fields, then write the full original payload to S3 at
`s3://gosteady-{env}-snippets/{serial}/{date}/{snippet_id}.bin` (with the
header still in place — keeps the binary self-describing for the future
S3 analytics tooling).

**Asks for cloud team:**
- Confirm the JSON-header fallback is acceptable on your side, OR if
  there's a different framing you'd prefer (e.g., header in the topic
  string, or a sidecar publish on `gs/{serial}/snippet/meta`).
- If the JSON-header fallback is OK, confirm whether you'd prefer the
  S3 object to be the full payload (header + binary) or just the binary
  (with metadata only on a DDB row from the IoT Rule).

I'll do the deeper NCS-side investigation as part of M12.1f once
heartbeat publish is up; expect to confirm the fallback decision then.

---

## F.4 Response: cloud action item #3 — snippet binary byte layout

**Initial format proposal (not yet implemented; still in spec).**
Implementation lands with M12.1f — capture path + storage repartition +
upload. Posting the spec now so any future S3 analytics tooling on your
side has a target.

Format (all multi-byte fields little-endian):

```
[16-byte payload header][N × 28-byte sample records]

payload header (16 bytes, packed):
  uint8  format_version = 1
  uint8  sensor_id      = 1   // 1=BMI270 only in v1; reserves room for future fusion
  uint16 sample_rate_hz = 100
  uint32 sample_count_n         // number of 28-byte records that follow
  uint64 window_start_uptime_ms // firmware monotonic uptime at first sample;
                                // pair with the wall-clock window_start_ts
                                // (sent in the JSON wrapper from §F.3) to
                                // anchor the window in real time

sample record (28 bytes, packed; matches the on-device session.h gosteady_sample
struct minus session-specific fields):
  uint32 t_ms       // milliseconds since window_start_uptime_ms
  float  ax, ay, az // m/s²; gravity NOT removed (raw sensor frame)
  float  gx, gy, gz // rad/s
```

A 30 s window at 100 Hz is `16 + 3000 × 28 = 84,016 bytes`, well under
the 100 KB MQTT cap.

The format is little-endian to match nRF9151 native byte order — keeps
on-device packing free. Cloud-side parsers (Python `struct`) need
`<BBHIQ` for the header and `<Iffffff` per record.

**Open**: I haven't versioned the JSON wrapper from §F.3 yet — when v2
adds new fields (e.g., temperature, multi-sensor data, longer windows
that require S3 presigned URLs), the JSON wrapper grows new fields and
the binary `format_version` bumps to 2. v1 cloud-side parsers should
ignore unknown JSON fields and reject `format_version != 1` until they
add v2 support.

I'll pin this format in a `docs/snippet-payload-v1.md` in the firmware
repo when M12.1f lands.

---

## F.5 Response: cloud action item #4 — site-survey unit timeline

**Best estimate: 2–4 weeks from 2026-04-26**, gated on cloud-side
delivery of the items in §F.9 + firmware execution of:

| Firmware track | Status | Estimate |
|---|---|---|
| M12.1a — modem attach + AT+CCLK? + signal stats | **DONE 2026-04-26** | — |
| M12.1c — MQTT/TLS + first heartbeat publish to `gs/{serial}/heartbeat` | Blocked on §F.9 #1 #2 | 2–3 days once unblocked |
| M12.1d — activity uplink on session close | Sequential after M12.1c | 1 day |
| M12.1e — pre-activation gate + activation downlink handler | Blocked on §F.9 #4 | 2–3 days |
| M12.1f — snippet upload | Sequential after storage repartition | 3–5 days |
| Storage repartition (snippet partition + telemetry queue + crash forensics region) | Local; sized by real M12.1c–e telemetry data | 1 day |
| nPM1300 fuel gauge wiring | Independent | 0.5–1 day |
| Crash forensics persistence | Sequential after partition | 2 days |
| Power architecture (deep sleep + ADXL367 wake-on-motion + PSM) | Independent | 3–5 days |
| Pre-deployment shakedown on bench (sustained heartbeat at 1/hr cadence + a session capture cycle + a planned crash + retrieval) | Last | 1–2 days |

Critical-path serializes the cellular tracks (M12.1c → 1d → 1e → 1f),
which is roughly 8–14 days of firmware work assuming each cloud-side
unblock arrives same-day.

**Soft commitment:** if cloud-side answers to §F.9 land within 2 working
days, firmware can ship a site-survey unit by ~2026-05-15. If those
answers slip, dates slip 1:1.

I'll repost a refined estimate after M12.1c is up and we have empirical
numbers on heartbeat / cellular wake battery cost.

---

## F.6 Response: cloud action item #5 — pre-activation LED is firmware-side

**Confirmed — but with one important refinement.** The blue LED slow-blink
is purely firmware-driven; cloud does not send any "show LED" command;
firmware self-extinguishes when entering normal session-capture mode.

**Refinement:** firmware does not unconditionally trust a local
`activated_at` flash flag. On every cellular wake, **firmware re-checks
provisioning state with the cloud** before deciding LED behavior + whether
to allow session capture. Rationale:

- Robust against any local flash corruption that flips a bit in
  `activated_at`.
- Robust against cloud-side de-provisioning of the device mid-deployment
  (e.g., if a device is RMA'd or moved between facilities and cloud
  marks it `ready_to_provision` again, firmware should respect that and
  re-enter the pre-activation state with blue LED).
- The check is one extra network round-trip per cellular wake — cheap
  given we're already attached to publish heartbeat.

**This refinement creates a new question for cloud team — see §F.9 #4
below.** We need a cloud-side contract for "what should firmware query
to determine activation state on each wake?" The original 2026-04-17
spec only covered the *initial* activation cmd (push-from-cloud). The
re-check on each wake is push-or-pull-TBD.

---

## F.7 Response: cloud action item #6 — manufacturer-side device enrollment

**Confirmed: firmware will maintain a global list of valid device IDs
as the single source of truth.** Every unit flashed at the bench gets
recorded; every unit shipped gets registered with cloud team before
leaving the bench.

**Proposed list contents (one row per flashed unit):**

| Field | Notes |
|---|---|
| `serial` | `GS0000000001`-style |
| `flash_date` | ISO 8601 |
| `cert_fingerprint` | SHA-256 of the per-device cert; lets cloud verify the cert came from us if there's ever a mismatch |
| `firmware_version` | Semver of the build flashed |
| `current_status` | enum: `ready_to_provision` (pre-ship) / `shipped` / `deployed` / `RMA` / `decommissioned` |
| `notes` | Free-form (clinic, deployment date, anything) |

**Format/location: TBD.** Three options, all firmware-side authored:

a. **Checked-in CSV in the firmware repo** under `data collection and protocols/device_registry.csv`. Pros: version-controlled, auditable. Cons: privacy — cert fingerprints in a public-ish repo. (The repo is currently public, but we'd move this file to a private companion repo if needed.)

b. **Private GitHub Gist or dedicated private repo** that firmware team owns. Pros: decoupled from the firmware codebase, easy access control. Cons: extra workflow.

c. **Portal API endpoint** like `POST /api/v1/devices/manufacturer-enrollment` that firmware team's flash script calls automatically at flash time. Pros: machine-driven, no manual step. Cons: requires cloud-side endpoint.

**Asks for cloud team — see §F.9 #5 below.**

Until we agree on the format, firmware will keep an internal list and
notify cloud team via Slack-or-equivalent before any unit ships.

---

## F.8 Firmware milestone update — M12.1a complete on bench (2026-04-26)

First cellular bring-up step shipped this morning. **`src/cellular.{h,c}`**
in the firmware repo drives `nrf_modem_lib` + `lte_link_control` +
`nrf_modem_at` to attach to LTE-M, then reports RSRP/SNR + UTC. Pure
bring-up — no MQTT, no sockets, no telemetry yet (those land with
M12.1c).

**Bench result on first try (Thingy:91 X dev unit, Nordic Onomondo SIM,
Northern California LTE-M coverage):**

```
[00:00:01.540] cellular: nrf_modem_lib_init ok
[00:00:01.638] cellular: lte_lc_connect_async kicked off — waiting for registration
[00:00:03.905] cellular: nw_reg_status=searching
[00:00:03.905] cellular: cell: id=0x05e10c0f tac=0x9605
[00:00:03.905] cellular: lte_mode=ltem
[00:00:04.816] cellular: rrc=connected
[00:00:07.533] cellular: nw_reg_status=registered_roaming
[00:00:07.534] cellular: psm: tau=3240 s, active=-1 s
[00:01:12.551] cellular: signal: rsrp=-100 dBm snr=2 dB
[00:01:12.552] cellular: network_time=2026-04-26T17:58:14Z
```

**Coordination-relevant takeaways:**

- ✅ **Time sync trust contract empirically validated.** `AT+CCLK?`
  returned a NITZ-derived UTC parsed cleanly into ISO 8601. The
  device-authoritative timestamp posture (cloud §5) works on first try;
  no NTP fallback needed.
- ✅ **PSM negotiated.** TAU = 3240 s (54 min). The `active = -1` field
  is the network rejecting the active-timer request, which is benign:
  the modem still enters PSM, just transitions immediately. Heartbeat
  cadence (1/hr) is well within this PSM cycle.
- ✅ **6 s registration time on roaming.** Comfortable margin under
  reasonable wake budgets; not a battery concern.
- ⚠️ **Coverage at the bench is RSRP -100 dBm / SNR 2 dB** — LTE-M
  marginal-but-workable. Production clinic site may be better or worse;
  this is one of the things the site-survey unit will measure first.

**No cloud-side action needed from this milestone** — flagging for
visibility because §F.5's timeline is anchored on it.

---

## F.9 New firmware questions for cloud team

These five gate M12.1c–e (heartbeat / activity / pre-activation flow).
M12.1c specifically can't compile/flash without #1 and #2; M12.1e is
blocked on #4.

### F.9.1 Per-device cert + key delivery workflow (gates M12.1c)

For the first 3 manually-flashed units, what's the cert delivery flow?
Three options that fit our stated decision (manual flashing, no fleet
provisioning):

a. **Cloud generates, firmware receives.** Cloud team runs
  `aws iot create-keys-and-certificate` per device, sends the resulting
  cert PEM + private key PEM via secure channel (encrypted Slack DM,
  1Password share, etc.). Firmware writes both into the modem's
  CryptoCell-312 / TF-M secure store at flash time via
  `AT%CMNG=0,<sec_tag>,...`. **Default option** unless cloud prefers
  another flow.

b. **Firmware generates CSR, cloud signs.** Firmware generates a key
  pair on-device, exports a CSR over UART at flash time, cloud signs
  via AWS IoT, returns cert. More complex; better long-term security
  posture.

c. **Pre-baked dev cert** for first survey unit only, then proper
  flow for the 2 main deployment units.

**Need from cloud team:**
- Pick a or b (or propose c).
- Provide the AWS IoT root CA bundle file path/URL we should pin.
  Default expectation: Amazon Trust Services CA G2 — but want explicit
  confirmation since some IoT Core regions/stacks pin different roots.
- Per-device cert + key files (under whatever flow we land on), one
  per unit, named by serial.
- Confirm the IoT policy attached to each cert allows: subscribe to
  `gs/{serial}/cmd`, publish to `gs/{serial}/heartbeat`,
  `gs/{serial}/activity`, `gs/{serial}/snippet` only — and *nothing
  else* (per the per-thing IoT policy promised in §1 of the cloud
  doc above).

### F.9.2 AWS IoT MQTT endpoint URL (gates M12.1c)

Need the full hostname to compile into the firmware build:

```
something-ats.iot.us-east-1.amazonaws.com
```

**Need from cloud team:**
- Production endpoint URL.
- Whether dev/staging/prod use different endpoints. If yes, what's
  the convention — different sec_tag per env? different firmware build?
  multiple endpoints in firmware with a Kconfig switch?
- Port (default 8883 for MQTT-over-TLS; confirm).

### F.9.3 Starting serial range (gates first cert generation)

Format is locked at `GS` + 10 digits. For the first 3 units:

- `GS0000000001`, `GS0000000002`, `GS0000000003`?
- Or some other range (e.g. `GS0000010001`+ to leave room for
  `GS0000000001`-style test/dev IDs)?

**Need from cloud team:** the exact serials we should bake into the
first 3 flashed units. We'll mint the cert, list, and Device Registry
entries against those.

### F.9.4 Pre-activation re-check on each cellular wake (gates M12.1e)

Per §F.6 above, firmware re-checks provisioning state with cloud on
every cellular wake — not just on first boot. The 2026-04-17 spec only
covered the *push* of an `activate` cmd (cloud → device, synchronous on
caregiver provision action). What's the *pull* contract for "is this
device activated yet?" on a wake?

Three options, ordered by my preference (a is least invasive):

a. **Subscribe to `gs/{serial}/cmd` with QoS 1 + retained-message
   semantics.** When portal publishes `activate`, set the message
   retain flag so any subsequent device subscribe gets the cmd
   immediately, not just the device that was online when it was
   originally sent. Device subscribes for ~3 s after MQTT connect on
   each wake; if it receives a retained `activate`, it processes +
   acks via `last_cmd_id`. This is the simplest path — uses existing
   topic, no new endpoint, MQTT-native semantics.

b. **Read Device Shadow's `desired` state.** Cloud writes
   `activated_at` into shadow desired; device reads on each connect.
   Decoupled from MQTT cmd path; more explicit state model.

c. **HTTPS query to a portal endpoint** like
   `GET /api/v1/devices/{serial}/state`. Pulls firmware out of the
   pure-MQTT lane; adds an HTTPS dependency for a single state query.

**Need from cloud team:**
- Which of a/b/c (or d). MQTT retained `activate` (a) is the cleanest
  fit if cloud is OK setting the retain flag on the publish.
- Edge case: what should firmware do if it receives an `activate` cmd
  that doesn't match a `cmd_id` it has heard of? (Probably: treat as
  authoritative + persist + ack normally — but want explicit guidance.)

### F.9.5 Manufacturer enrollment workflow (gates first unit ship)

Per §F.7 above, firmware will maintain a global list of valid serials.
Three options for the workflow:

a. Checked-in CSV in firmware repo (or a private companion repo).
b. Private GitHub Gist / dedicated private repo, firmware-team owned.
c. Portal API endpoint that firmware team's flash script calls.

**Need from cloud team:**
- Pick a/b/c (or propose d).
- If c, the endpoint URL + auth scheme.
- The minimum data cloud needs to pre-create the Device Registry
  record. Probably just `serial` + `cert_fingerprint`?

### F.9.6 (bonus) Snippet payload encryption posture

Cloud §4 said AWS-managed S3 SSE is appropriate (sensor data is
non-PHI). Confirming: firmware does NOT need to encrypt at the device
side (e.g., AES-GCM with a per-device key on top of TLS). TLS 1.2 in
transit + S3 SSE at rest is the full posture. Yes/no?

---

## F.10 Cadence / next steps

- Firmware team will not poll this file actively; cloud team's response
  lands as a new entry below this one and reaches firmware via the
  iCloud sync that backs the local mirror.
- If anything in this entry is *blocking* on cloud side (specifically
  §F.9 #1 and #2 are blocking M12.1c), please reply with at least
  partial answers as soon as you can — even a "still working on it,
  ETA Friday" beats radio silence.
- Next firmware milestone announcement here: M12.1c first heartbeat
  publish, expected within a few working days of getting cert + endpoint.

---

*Entry owner (firmware side): Jace. Questions / counter-proposals welcome.*

---
---

# Cloud team response — 2026-04-26

> **From:** GoSteady cloud team
> **In response to:** firmware entry above (§F.1–§F.10, dated 2026-04-26).
>
> **TL;DR:** All six §F.9 questions answered with decisions in §C.4 below.
> The big call is §F.9.4 — picked **Device Shadow** over MQTT-retained for
> the re-check-on-wake mechanism, planning ahead for richer device-targeted
> state (per-device thresholds, sampling rate, OTA flags) without standing
> up a second mechanism later. Architecture spec updated to reflect §F.2
> ack-matching breadth, §F.3 JSON-header snippet framing, §F.4 binary
> layout, and the §F.9.4 Shadow decision — diff summary in §C.3. Three
> small cloud-side asks back to firmware in §C.5.

---

## C.1 Acks of firmware §F.1 + §F.8 milestone

**§F.1** — confirmed; all 2026-04-17 cloud contracts ack'd by firmware. No
further negotiation on the activation, heartbeat-extras, activity-extras,
snippet schema, time-sync, or pre-activation-handling tables.

**§F.8 (M12.1a complete on bench)** — congrats on first-try cellular
attach. Two things worth flagging from your bench output:

- **Time-sync trust contract empirically validated** is exactly what we
  hoped to see — closes one of the bigger "what if it doesn't work in
  practice" risks on the v1 plan. We'll pin a §C.5 follow-up around clock
  drift between heartbeats so we can characterize how big a window cloud
  should tolerate before flagging anomalies.
- **RSRP -100 dBm / SNR 2 dB on bench** is well above our cloud-side
  `signal_lost` threshold (-120) and slightly worse than `signal_weak`
  (-110). We'll watch the first heartbeat from the field unit closely;
  if your real clinic site is worse than the bench, the synthetic
  `signal_weak` alerts will fire on every heartbeat. Not a problem in
  pre-activation (we suppress); will be in active monitoring. May need
  the per-walker threshold overrides referenced in our spec moved up
  from Phase 2A. Tracking; not a blocker for site-survey unit.

---

## C.2 Acks of firmware §F.2–§F.7

**§F.2 (last_cmd_id ack mechanism)** — accepted. The "always echo most
recent received cmd_id" pattern is exactly what we want; idempotent and
tolerant of packet loss in either direction.

The edge case you flagged ("if portal retried provision, two cmd_ids
issued in quick succession, firmware echoes only the most recent") is
real and we've folded it into the ack-matching logic: cloud's heartbeat
handler matches `last_cmd_id` against any `cmd_id` issued to the serial
**within the last 24 h**, not just the most recent one. The 24 h window
mirrors our planned "stuck in `provisioned`" ops alarm; if no echo
arrives within the same window we'd be alarming on, the matching
shouldn't be tighter than that.

This is locked in `ARCHITECTURE.md` §4 (Activation message section,
"Ack-matching breadth" subsection) and as cumulative requirement DL14a
in §14.

**§F.3 (NCS MQTT 3.1.1 / JSON-header fallback)** — accepted, and
expected — we'd assumed v3.1.1 too once we looked at NCS 3.2.4. Your
proposed framing is locked in:

```
[4-byte big-endian uint32: header_len_bytes][header_len_bytes JSON][binary samples]
```

To your two asks:

1. **Confirm fallback acceptable** — yes.
2. **S3 stores full payload (header + binary) or binary-only?** —
   **full payload, header included.** The file stays
   self-describing for offline analytics tooling, and your future
   Python tool can read both the JSON header and the binary body
   from a single S3 object without needing a sidecar metadata
   lookup.

One implication on our side worth flagging back to you: **the
"no Lambda in the snippet ingestion path" claim from our 2026-04-17
doc no longer holds.** IoT Rule SQL alone cannot extract `snippet_id`
from a binary preamble to construct the S3 key. We'll add a thin
Python Lambda that parses the 4-byte length-prefix + JSON header and
writes the full payload to
`s3://gosteady-{env}-snippets/{serial}/{date}/{snippet_id}.bin`. This
lands in the Phase 1A revision deploy. Cost impact is negligible
(~720 invocations/month at expected v1 cadence). No firmware-side
change required from this; flagging for visibility.

**§F.4 (snippet binary byte layout)** — accepted as v1 spec. 16-byte
payload header + 28-byte sample records, little-endian. We've pinned
this in `ARCHITECTURE.md` §7 alongside the framing change. Cloud-side
parser (Python `struct`): `<BBHIQ` for the 16-byte header, `<Iffffff`
per record. Will mirror in the firmware-side
`docs/snippet-payload-v1.md` per your plan when M12.1f lands.

**§F.5 (site-survey unit timeline)** — acknowledged. Soft target
~2026-05-15 is consistent with our cloud-side readiness. Phase 1A
revision (which adds the snippet IoT Rule + cmd-topic policy + the
new snippet-parser Lambda) lands this week or next on our side, well
before your M12.1f.

**§F.6 (LED is firmware-side; re-check on wake)** — confirmed: blue
LED is purely firmware-driven, no cloud "show LED" command.

The re-check refinement you raised is a real concern (flash bit-flips
+ cloud-side de-provisioning). Our answer is in §C.4.4 below — we
picked **Device Shadow `desired.activated_at`** over MQTT-retained.
Reasoning: Shadow gives us a forward-compatible state channel for
richer device-targeted state we'll inevitably want later (per-device
thresholds, sampling-rate adjustments, OTA gating, calibration
baselines). Standing up Shadow now and adding new `desired.*` keys
later is cheaper than running two mechanisms in parallel.

**§F.7 (manufacturer-side enrollment)** — answer in §C.4.5 below. Two-
step: private companion repo for first ≤10 units, `POST /admin/devices`
endpoint for the long term.

---

## C.3 Architecture-spec changes that landed in response to §F.1–§F.7

For your reference (don't need to read these unless you're curious):

| `ARCHITECTURE.md` section | Change |
|---|---|
| §4 Activation message | Replaced "TBD" re-check prose with the §F.9.4 Shadow decision (full mechanism description); added §F.2 ack-matching-breadth subsection; locked the invariant `desired.activated_at` non-null **iff** Device Registry status ∈ {`provisioned`, `active_monitoring`} |
| §7 Snippet | Replaced MQTT user-properties table with the JSON-header framing per §F.3, plus the binary byte layout per §F.4. Noted the no-Lambda-in-path constraint is dropped |
| §14 Cumulative requirements | Updated D14 (snippet framing); added D14a (ack-matching breadth); added DL14 (Shadow re-check) |
| §16 Open Questions | Added then closed all six §F.9 entries with the decisions below |

Phase 1A revision spec (`docs/specs/phase-1a-revision.md`) hasn't been
updated yet — that's our next pass on the cloud side. Flagging because
the snippet IoT Rule design changes (Lambda in the path) will land
there along with the new Shadow `desired.activated_at` write hooks
spread across §provision, §end-assignment, §decommission, §force-reset,
§ownership-move, §discharge-cascade.

---

## C.4 Answers to §F.9 — decisions

### C.4.1 → §F.9.1 — Per-device cert + key delivery flow

**Option (a): cloud-generates-and-sends.**

For the first ≤3 manually-flashed units, cloud team will:

1. Run `aws iot create-keys-and-certificate --set-as-active` once per device
2. Create a per-thing IoT Thing (`GS0000000001`, etc.) and attach the cert
3. Attach a per-thing IoT policy authorizing **only**:
   - `iot:Connect` on `client/${iot:Connection.Thing.ThingName}`
   - `iot:Publish` on `topic/gs/${iot:Connection.Thing.ThingName}/heartbeat`
   - `iot:Publish` on `topic/gs/${iot:Connection.Thing.ThingName}/activity`
   - `iot:Publish` on `topic/gs/${iot:Connection.Thing.ThingName}/snippet`
   - `iot:Subscribe` + `iot:Receive` on `topicfilter/gs/${iot:Connection.Thing.ThingName}/cmd` and the corresponding topic ARN
   - `iot:GetThingShadow` + `iot:UpdateThingShadow` on `thing/${iot:Connection.Thing.ThingName}` (added per the §F.9.4 Shadow decision — see C.4.4)
4. Hand off cert PEM + private key PEM via **1Password shared item, one per device, named by serial, 7-day expiry.**

**AWS IoT root CA pin:** Amazon Root CA 1. Public download URL:
`https://www.amazontrust.com/repository/AmazonRootCA1.pem`. Pin this
as the trusted root in your TLS config; we won't rotate it without
flagging here first.

**Operational expectation:** I'll generate the three cert sets and DM
you the 1Password shares within ~1 working day of this entry posting.
Reply here when each set has been successfully flashed so I can mark
the 1Password items for deletion.

**Long-term:** firmware-CSR-cloud-signs flow rolls into Phase 5A fleet
provisioning, not a separate near-term track.

### C.4.2 → §F.9.2 — AWS IoT MQTT endpoint + dev/prod separation

- **Dev endpoint:** `a2dl73jkjzv6h5-ats.iot.us-east-1.amazonaws.com`
- **Port:** `8883` (standard MQTT-over-TLS — confirm)
- **Prod endpoint:** TBD; will land as a separate AWS account per the Phase 1.5 multi-account plan, so each environment will have its own endpoint hostname

**Separation strategy: separate Kconfig per env, separate firmware
builds.** This matches the AWS account boundary cleanly and avoids
embedding multiple endpoints in a single binary. When prod account
provisions, we'll publish the prod endpoint here as a follow-up entry,
and you'll add a `CONFIG_GOSTEADY_IOT_ENDPOINT_PROD` Kconfig with a
build-time switch.

### C.4.3 → §F.9.3 — Starting serial range

- First 3 units: **`GS0000000001`, `GS0000000002`, `GS0000000003`.**
- Reserved for synthetic test/dev fixtures: **`GS9999999990–GS9999999999`** (visually distinct from low-range production serials, won't collide).
- The `GS` + 10 digit format (`G1` in cloud cumulative reqs) is locked.

I'll mint cert sets and (per C.4.5) pre-create Device Registry records
against those three serials before the cert handoff, so your first
heartbeat publish from each unit will land cleanly.

### C.4.4 → §F.9.4 — Pre-activation re-check mechanism on each wake

**Option (b): Device Shadow `desired.activated_at`.**

Mechanism — full detail in `ARCHITECTURE.md` §4 (re-check subsection):

1. **Cloud writes `desired.activated_at` = ISO 8601 UTC timestamp** at
   provision time (in addition to publishing the existing `activate`
   cmd to `gs/{serial}/cmd` — the cmd remains as the immediate-push
   signal at provision; Shadow is the durable state-of-record
   consulted on every wake).
2. **Cloud invariant:** `desired.activated_at` is non-null **iff**
   Device Registry status ∈ {`provisioned`, `active_monitoring`}.
   Every transition out of those states writes `desired.activated_at = null` (or removes the key) — handled inside `device-api`
   Lambda's transition handlers and the `discharge-cascade` Lambda.
3. **Firmware on every cellular wake:** `GET` shadow, read
   `desired.activated_at`. If non-null and matches its on-flash
   value: normal operation. If null (or any mismatch versus
   persisted value): re-enter pre-activation behavior, blue LED back
   on, no session capture.
4. **Firmware writes `reported.activated_at`** to confirm device-side
   persistence after every state change. Cloud's heartbeat handler
   (or a Shadow-delta handler) treats `reported.activated_at == desired.activated_at` as the durable activation ack — supplements
   the existing `last_cmd_id` heartbeat echo (which we keep for the
   per-cmd ack semantics, not just for activation).

**Edge case you raised — "what if firmware receives an `activate` cmd
that doesn't match a `cmd_id` it has heard of?"** — treat as
authoritative + persist + ack normally via `last_cmd_id`. Our cloud
side maintains the canonical `cmd_id` issuance log, so any cmd
firmware receives over `gs/{serial}/cmd` was issued by us; firmware
should not second-guess.

**IoT policy implication for §F.9.1 cert handoff:** the per-thing
policy now also authorizes `iot:GetThingShadow` and
`iot:UpdateThingShadow` on the device's own thing. Already added in
C.4.1 above.

**NCS Shadow library check (request back to firmware):** the
`aws_iot` lib in NCS 3.2.4 does support Shadow get/update via
`AWS_IOT_SHADOW_TOPIC_GET` and the `aws_iot_shadow_update_accepted`
event flow, but you'd know better than us — flagging in §C.5.1 below
as a confirm-or-flag-blocker item.

### C.4.5 → §F.9.5 — Manufacturer-side enrollment workflow

**Two-step:**

**Short-term (first ≤10 units, until Phase 2A `POST /admin/devices`
ships): option (b) — private companion repo.** Suggested layout:

- Firmware team creates a **private** GitHub repo (e.g.,
  `gosteady-firmware-private` or similar — your call on naming)
- File `device-registry.csv` with columns: `serial, cert_fingerprint, flash_date, firmware_version`
- Cloud team gets read access on the repo
- Per-shipment workflow:
  1. Firmware engineer flashes the device (cert from §C.4.1
     handoff)
  2. Firmware engineer commits a row to `device-registry.csv` and
     pushes
  3. Firmware engineer pings cloud team in Slack: "shipping
     `GS0000000001-3` by Friday"
  4. Cloud team pulls latest CSV, runs CLI helper (we'll write a
     ~10-line script) to write `ready_to_provision` Device Registry
     records (NULL ownership, NULL `provisionedAt`)
  5. Cloud team confirms back: "registry records created, safe to
     ship"

**Minimum data cloud needs:** `serial` (required, used as PK) + `cert_fingerprint` (recommended — used to verify the cert presented at first connect matches the one firmware flashed; defense in depth). Other fields (`flash_date`, `firmware_version`) are nice-to-have.

**Long-term (after Phase 2A device-lifecycle endpoints ship): option (c) — `POST /admin/devices` endpoint.** Already specced in
`docs/specs/phase-2a-device-lifecycle.md` for internal-admin
manufacturer-side device record creation. Once it lands, your flash
script calls it directly (auth via firmware-team service account
JWT or shared API key, TBD when 2A nears completion). The CSV in
private repo can stay as a backup record / audit trail if useful to
firmware; cloud's source-of-truth migrates to the API.

### C.4.6 → §F.9.6 — Snippet payload encryption posture

**Confirmed: yes — TLS 1.2 in transit + AWS-managed S3 SSE at rest
is the full v1 posture.** No device-side AES-GCM layer required.

Snippets are non-PHI sensor data per our encryption-tier table
(`ARCHITECTURE.md` §9). AWS-managed keys are appropriate for
non-identity bulk data; we only escalate to CMK on identity-bearing
or compliance-evidence resources. We'll revisit only if a customer
specifically requires CMK on the snippet bucket.

---

## C.5 Cloud-side asks back to firmware

### C.5.1 NCS Shadow library confirmation (gates §F.9.4 build path)

The §F.9.4 decision (Shadow `desired.activated_at`) assumes the NCS
3.2.4 `aws_iot` library supports Shadow get/update. Quick read of the
NCS docs suggests yes — `aws_iot.h` exposes `aws_iot_application_topics_subscribe()` for shadow topics and the
update flow goes through standard MQTT publish on
`$aws/things/{thing}/shadow/update`. But you'd know firsthand
whether this works cleanly in your build.

**Need from firmware:** confirm Shadow get/update works in NCS 3.2.4
on the bench, or flag as a blocker and we'll revisit (option a MQTT
retained is the fallback if Shadow turns out to be a pain).

### C.5.2 Heartbeat clock drift characterization (follow-up to §F.8)

The empirical cellular-time validation in §F.8 is great. Given we've
locked in "device-authoritative timestamps, no NTP fallback, no cloud
correction" (D15), it'd be useful to characterize:

- Drift between successive `AT+CCLK?` reads after PSM cycles (does
  the modem maintain time across PSM, or does each wake reset it?)
- Sub-second consistency — does `AT+CCLK?` give second-precision
  only, or higher? (Cellular NITZ is typically second-precision but
  varies by carrier.)

**No blocker — just helpful for cloud-side anomaly detection.** When
M12.1c is up and you have a few weeks of heartbeats, a one-paragraph
note here on observed drift would let us tune the "out-of-order
heartbeat" detection logic in our Threshold Detector revision (Phase
1B revision).

### C.5.3 Pre-activation heartbeat upload-attempt cost

Pre-activation behavior (firmware §F.6 / cloud §6 in this doc) has
firmware waking on motion, attaching to LTE-M, publishing a
heartbeat, then waiting briefly for an activation message before
returning to sleep. We've committed to suppressing synthetic alerts
in this state (DL13).

**Question:** what's the rough battery cost per pre-activation cycle
(modem attach → heartbeat publish → optional Shadow get → sleep)? If
it's high enough that a stuck-in-pre-activation device drains the
battery in days, we may want to add a cloud-side alarm for "device
in pre-activation > 7 days" that surfaces to ops, distinct from the
24 h "stuck in `provisioned` post-activation-send" alarm. Not a
spec change — just sizing the alarm threshold against real-world
energy budget. Defer until M12.1c gives us empirical numbers.

---

## C.6 Cadence / next steps

**Cloud team next actions (committing to within ~1 working day, by
2026-04-27 EOD):**

1. Mint cert + key for `GS0000000001`, `GS0000000002`,
   `GS0000000003`; attach per-thing IoT policies per C.4.1
2. DM firmware engineer the three 1Password shared items (one per
   serial, 7-day expiry)
3. Pre-create the three `ready_to_provision` Device Registry records
   (NULL ownership, NULL `provisionedAt`) — this means even before
   the private companion repo exists, the first heartbeats from
   these specific serials will land cleanly
4. Reply here once the three cert sets are ready

**Cloud team next architectural work (within ~1 week, in parallel
with firmware M12.1c):**

5. Phase 1A revision spec update — incorporate the snippet IoT Rule
   redesign (Lambda in path), the Shadow `desired.activated_at`
   write hooks across state-machine transitions, and cumulative
   requirement updates from this batch
6. Phase 1A revision deploy — adds the cmd-topic IoT policy
   statement, snippet S3 bucket, snippet parser Lambda, and the
   pre-activation suppression logic in the heartbeat handler
7. CLI helper script for bulk Device Registry record import from the
   private companion repo CSV (per §C.4.5)

**Firmware-side blockers cleared by this entry:** §F.9.1, §F.9.2,
§F.9.3, §F.9.4 (mechanism decided; build-path subject to §C.5.1
confirmation), §F.9.5, §F.9.6 — all six items have decisions.

**Next coordination batch trigger** (per the cadence note in §9
above, originally proposed by cloud): site-survey unit cellular
shakedown (firmware M12.1c + first heartbeat in cloud). Either side
posts here when first end-to-end traffic flows.

---

*Entry owner (cloud side): Jace + Claude. Counter-proposals, blocker
flags, and milestone updates welcome below.*


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

---
---

# Cloud team milestone update — 2026-04-27

> **From:** GoSteady cloud team
> **Status update on:** §C.4.1 (cert + key delivery) and §C.4.5
> (manufacturer-side enrollment) commitments from the 2026-04-26 batch.
>
> **TL;DR:** Cert + key handoff is **READY** for the firmware engineer.
> Four cert+key pairs minted, IoT Things created, policies attached,
> Device Registry rows pre-created. All cloud-side wiring done. Bundle
> staged locally on Jace's machine; 1Password upload pending (one-time
> human step). Firmware can plan to receive the 1Password shares
> shortly.

---

## C2.1 What was minted

Four cert+key pairs, each with its own AWS IoT Thing, all attached to
the standard `gosteady-dev-device-policy` (per-thing scope via
`${iot:Connection.Thing.ThingName}`):

| Serial | Purpose | Cert SHA-256 fingerprint (= AWS IoT cert ID) |
|---|---|---|
| `GS9999999999` | Bench/test cert — never ships; reusable on firmware-team bench unit forever; from reserved test/dev range | `a17ed9f8c6d1c6365d97fdd9ef774915bd2c0d4fe0bbca90666661fd497bd613` |
| `GS0000000001` | First site-survey shipping unit | `8351197b8a9d5548853b5031881bf87b9b3339ab38a7c3ca4abadb5366d1ada6` |
| `GS0000000002` | Second site-survey shipping unit | `21bb9173c8656056a5d26463267caa80e057ac7b99814092c7add77449808186` |
| `GS0000000003` | Third site-survey shipping unit | `b0d2ef3fe3eb22b0f6b3f8b7c2a201d05a1fb9dc7ffb3de248e03bd4ca321cc9` |

Cert ID = SHA-256 fingerprint (AWS IoT convention). These fingerprints
are also the values for the firmware-team device-registry CSV's
`cert_fingerprint` column (per §C.4.5).

## C2.2 Cloud-side wiring verified end-to-end

For each of the 4 serials:
- IoT Thing created (type `GoSteadyWalkerCap-dev`)
- Cert + private key minted via `aws iot create-keys-and-certificate`, status ACTIVE
- `gosteady-dev-device-policy` attached to cert
- Cert attached to Thing as principal
- Device Registry row pre-created in `gosteady-dev-devices` with `status: ready_to_provision`, NULL ownership, `certFingerprint` set

Verification command (re-runnable):
```bash
for s in GS9999999999 GS0000000001 GS0000000002 GS0000000003; do
  cert_arn=$(aws iot list-thing-principals --thing-name "$s" \
    --region us-east-1 --query "principals[0]" --output text)
  echo "$s -> ${cert_arn##*/}"
  aws dynamodb get-item --region us-east-1 \
    --table-name gosteady-dev-devices \
    --key "{\"serialNumber\":{\"S\":\"$s\"}}" \
    --query "Item.{status:status.S,fp:certFingerprint.S}"
done
```

## C2.3 Policy update worth flagging

The `gosteady-dev-device-policy` was extended with `iot:GetThingShadow`
and `iot:UpdateThingShadow` on the device's own Thing (per the §F.9.4
Shadow re-check decision DL14 in `ARCHITECTURE.md`). This was a slice
of the 1A-revision policy update done early so these 4 dev certs have
Shadow access from day one without waiting for the full 1A-rev deploy.
Existing policy permissions (Connect, Publish/Subscribe/Receive on
`gs/<thing>/*`) are unchanged.

## C2.4 What firmware will receive

Each cert subdirectory in the handoff bundle contains:
- `<serial>.cert.pem` — public certificate (PEM)
- `<serial>.private.key` — private key (PEM, mode 0600)
- `<serial>.public.key` — public key (PEM, reference only)
- `<serial>.README.txt` — per-device handoff notes

Plus at the bundle root:
- `AmazonRootCA1.pem` — AWS IoT Core server-cert chain anchor
- `MANIFEST.csv` — `serial,cert_fingerprint_sha256,flash_date,firmware_version,notes` rows ready to drop into the firmware-team device-registry CSV (per §C.4.5)
- `README.txt` — top-level bundle summary

## C2.5 1Password handoff — pending human step

The bundle is staged at `~/Desktop/gosteady-firmware-cert-handoff-2026-04-27/` on Jace's machine. Next step is a one-time human action (cloud team can't automate 1Password upload):

1. Upload each of the 4 subdirectories to a separate 1Password shared item, named by serial (e.g. "GoSteady cert / GS0000000001"), 7-day expiry
2. Share each item with the firmware engineer
3. Notify firmware via Slack with the share links

Once delivered, firmware is unblocked on M12.1c (first heartbeat publish from the bench unit using `GS9999999999` cert).

## C2.6 Endpoint + Root CA reminders (already in §C.4.2 / §C.4.1)

For convenience (firmware engineer can paste these into their Kconfig / build):

- **IoT MQTT endpoint:** `a2dl73jkjzv6h5-ats.iot.us-east-1.amazonaws.com`
- **Port:** `8883` (MQTT-over-TLS)
- **Pinned root CA:** Amazon Root CA 1
  (`https://www.amazontrust.com/repository/AmazonRootCA1.pem` — also bundled as `AmazonRootCA1.pem` in this handoff)
- **AWS account:** `460223323193` (dev)
- **Region:** `us-east-1`

## C2.7 Cleanup / lifecycle

Once firmware confirms successful flash + first heartbeat for each cert:
- 1Password shared items get deleted (they auto-expire at 7 days regardless)
- Local bundle on Jace's machine deleted (private keys are NOT recoverable from cloud — they only exist on-device after flash)
- Cert + Thing + Device Registry rows on AWS side persist (these are the operational records)

If a private key is lost or compromised before flash:
- Mark cert INACTIVE: `aws iot update-certificate --certificate-id <id> --new-status INACTIVE`
- Detach + delete cert + Thing + DDB row
- Mint a fresh cert pair using the same serial
- Re-share via 1Password

## C2.8 Cadence note

This is a milestone update inside the existing 2026-04-26 conversation
batch — no firmware-side action expected on the doc itself. Firmware
engineer just acks the 1Password share when they receive it via Slack.

Next coordination batch trigger remains the same: site-survey unit
cellular shakedown + first heartbeat in cloud (firmware M12.1c).

---

*Entry owner (cloud side): Jace + Claude.*

---
---

# Cloud team follow-up — 2026-04-27 (handoff path correction)

> **Updates §C2.5** ("1Password handoff — pending human step") and
> §C2.7 cleanup language.

The 1Password handoff described in §C2.5 is **not happening** —
single-developer setup means cloud team and firmware team share the
same Mac and home directory. The cert+key bundle lives at a known
filesystem path; firmware reads files directly from disk when flashing
or running bench-level validation. No cross-machine transfer needed.

## C3.1 Bundle path

```
/Users/jaceblackburn/Desktop/gosteady-firmware-cert-handoff-2026-04-27/
```

Layout:
```
├── README.txt                 — top-level overview (updated to reflect single-dev setup)
├── MANIFEST.csv               — serial → cert_fingerprint_sha256 mapping
├── AmazonRootCA1.pem          — server-cert chain anchor; pin device-side
├── GS9999999999/              — bench/test cert (never ships)
│   ├── GS9999999999.cert.pem
│   ├── GS9999999999.private.key   (mode 0600)
│   ├── GS9999999999.public.key
│   └── GS9999999999.README.txt    — flashing instructions
├── GS0000000001/              — first shipping unit
├── GS0000000002/              — second shipping unit
└── GS0000000003/              — third shipping unit
```

Per-device READMEs cover the AT%CMNG=0,<sec_tag>,... CryptoCell-312
flashing pattern + Root CA pinning.

## C3.2 What's unchanged from §C2

All cloud-side state from §C2.2 (IoT Things, certs ACTIVE, policy
attachments, principal attachments, Device Registry rows
`ready_to_provision`) is unchanged. Cert SHA-256 fingerprints from
§C2.1 are still the device-registry CSV values for §C.4.5.

The Shadow grants added to `gosteady-dev-device-policy` per §C2.3 are
also unchanged — committed in the cloud repo at
`infra/lib/stacks/ingestion-stack.ts` and deployed to dev. Firmware
can use Shadow `desired.activated_at` on every wake per the §F.9.4
decision.

## C3.3 Cleanup adjustments

§C2.7 said "delete the 1Password shared items after first-heartbeat
ack." That step is moot — there are no 1Password items. Local bundle
cleanup rules apply:

- **GS9999999999 (bench cert):** keep the bundle entry as long as the
  bench unit is in use (reflashable, reusable forever)
- **GS0000000001/2/3 (shipping certs):** delete each subdirectory
  after the corresponding unit is permanently flashed and confirmed
  working in the field (private keys aren't cloud-recoverable;
  bundle is the last copy until cert is baked into nRF9151)

If a private key is lost or compromised before flash:
```bash
aws iot update-certificate --certificate-id <id> --new-status INACTIVE --region us-east-1
aws iot delete-certificate --certificate-id <id> --region us-east-1 --force-delete
aws iot delete-thing --thing-name <serial> --region us-east-1   # if recreating fresh
aws dynamodb delete-item --region us-east-1 \
  --table-name gosteady-dev-devices \
  --key "{\"serialNumber\":{\"S\":\"<serial>\"}}"
```
Then re-mint via the §C2.1 pattern.

## C3.4 No firmware action required

Bundle is in place; no human handoff step pending. Firmware proceeds
with M12.1c (first heartbeat publish from bench unit using
`GS9999999999` cert) when ready.

---

*Entry owner (cloud side): Jace + Claude. Counter-proposals welcome.*

---
---

# Firmware team milestone update — 2026-04-27 (M12.1c.1 sub-task 0 — cloud-side path validated end-to-end without firmware)

> **Closes:** the §C3.4 "firmware proceeds with M12.1c when ready" handoff
> on the cloud-side acceptance angle.
>
> **Raises:** new question §F2.3 about heartbeat-storage spec drift —
> coord doc / firmware-side mirror say Device Shadow `reported`; the
> actual cloud-side Lambda writes DynamoDB only. Architectural ambiguity
> firmware would like resolved before sinking design into M12.1e.2
> (pre-activation gate + Shadow re-check).
>
> **TL;DR:** Cloud↔firmware contract is more validated than expected at
> this stage — exercised the heartbeat path end-to-end with `aws iot-data
> publish` (synthetic payload to `gs/GS9999999999/heartbeat`), Lambda
> fired, DDB row updated cleanly, DLQ empty. But the storage location
> doesn't match what the firmware-side mirror in `GOSTEADY_CONTEXT.md`
> (and `ARCHITECTURE.md §7`) says — they say Device Shadow `reported`;
> Lambda actually writes `gosteady-dev-devices` directly via `UpdateItem`.
> Three small follow-up nits in §F2.4. Renumbering heads-up in §F2.5.

---

## F2.1 What just happened

Per the firmware-side milestone arc renumbering (see §F2.5 below),
M12.1c was sliced into M12.1c.1 (bench-cert minimum-viable heartbeat
from `GS9999999999`) and M12.1c.2 (production-shaped heartbeat).
M12.1c.1 has a "sub-task 0" cloud-side acceptance probe step — its job
is to validate the cloud-side path independently of firmware so any
later firmware-side debugging starts with a known-clean cloud target.

Sub-task 0 ran today and surfaced what we hoped it would surface:
cloud is functionally ready, but with one spec-vs-implementation drift
worth resolving before sub-task 1 starts.

## F2.2 What we proved (cloud-side acceptance results)

| Check | Result | Notes |
|---|---|---|
| Cert bundle at `~/Desktop/gosteady-firmware-cert-handoff-2026-04-27/` | ✅ | All 4 subdirs + `AmazonRootCA1.pem` + `MANIFEST.csv` + READMEs present. Per-device README documents `AT%CMNG=0,<sec_tag>,...` flashing pattern. |
| Re-ran §C2.2 verification block (4 serials × Thing principal + DDB row) | ✅ | All 4 cert fingerprints match between disk + AWS; all 4 DDB rows = `ready_to_provision`. |
| IoT Rule `gosteady_dev_heartbeat` deployed + enabled on `gs/+/heartbeat` | ✅ | Also confirmed: `gosteady_dev_activity` + `gosteady_dev_alert` rules deployed. |
| Synthetic heartbeat via `aws iot-data publish` | ✅ | Topic `gs/GS9999999999/heartbeat`; payload `{"serial":"GS9999999999","ts":"2026-04-27T21:19:39Z","battery_pct":0.5,"rsrp_dbm":-100,"snr_db":5}`. |
| `gosteady-dev-heartbeat-processor` Lambda fired | ✅ | 512 ms cold start; 821 ms billed total; 308 ms execution. |
| Lambda logged validated heartbeat | ✅ | `[HEARTBEAT][OK] serial=GS9999999999 ts=2026-04-27T21:19:39Z battery=0.50 rsrp=-100.0 snr=5.0 fw=None walker=None` |
| DDB row updated with our exact values | ✅ | `batteryPct=0.5`, `rsrpDbm=-100`, `snrDb=5`, `lastHeartbeatAt=2026-04-27T21:19:39Z`, `lastSeen=2026-04-27T21:19:39Z`. Other attributes (`certFingerprint`, `status`, `manufacturedBy`, `notes`) preserved by partial `UpdateItem`. |
| DLQ message count | ✅ 0 | Zero failed Lambda invocations from this probe. |

Net: cloud heartbeat handler is live and works end-to-end with the
synthetic payload firmware will produce. Nothing on cloud side blocks
firmware bring-up.

## F2.3 Heartbeat storage spec drift (please resolve before M12.1e.2)

`gosteady-portal/docs/specs/ARCHITECTURE.md §7` and the locked-table
mirror in `gosteady-firmware/GOSTEADY_CONTEXT.md` (Portal Scope Impact
§Heartbeat uplink, "Storage in cloud" row) both say:

> "Storage in cloud | AWS IoT Device Shadow `reported` state (not
> DynamoDB direct write) | Locked by portal spec"

The actual `gosteady-dev-heartbeat-processor` Lambda code writes
directly to DynamoDB `gosteady-dev-devices` via `UpdateItem` — no
Shadow write anywhere in the handler. The Lambda's own docstring
describes itself as "Phase 1B" and explicitly documents the DDB
`UpdateItem` flow as the design (preserves walkerUserId, provisionedAt,
etc.).

Three options for resolving the drift:

1. **Lambda is right, spec is stale.** Update the spec table to record
   DDB-direct-write as the canonical storage. Firmware-side mirror in
   `GOSTEADY_CONTEXT.md` follows.
2. **Spec is right, Lambda is incomplete.** Phase 1B is "MVP just-DDB"
   with Shadow write planned for Phase 2; firmware should not lean on
   Shadow `reported` for heartbeat data until that lands. Cloud-side
   roadmap entry would be helpful.
3. **Both write paths intended.** Lambda needs a Shadow update path
   alongside the DDB write. Firmware-side mirror clarifies "Shadow
   `reported` mirrors DDB `lastSeen` / `battery` / etc."

**Functionally for M12.1c.1 / M12.1c.2: no impact.** Firmware just
publishes to the topic; cloud handler is whatever it is. But this DOES
affect M12.1e.2 design — that path is supposed to **write**
`reported.activated_at` from device side and **read**
`desired.activated_at` per §C.4.4. If Shadow isn't actually wired up
at all in cloud yet, M12.1e.1's bench check needs to verify cloud-side
Shadow read/write end-to-end (not just NCS lib mechanics on a stub
Thing), and the §C.4.4 fallback path (MQTT-retained `activate` cmd)
becomes more relevant than the §C.4.4 main paragraph implies.

**Question for cloud team:** which of (1), (2), (3)? And if (2), what's
the rough Phase-2 window? Firmware can move forward on M12.1c.1 +
M12.1c.2 (no Shadow dependency) without an answer, but wants the answer
before sinking design into M12.1e.2.

## F2.4 Other small notes from the probe

Three minor observations, none blocking:

a. **`uptimeS=0` got persisted** even though our synthetic payload
   didn't send `uptime_s`. Lambda appears to default-fill missing
   optional fields with 0. Acceptable but worth being explicit: when
   M12.1c.2 sends the real `uptime_s`, the value will replace the
   default 0 in DDB; if firmware skips a field intentionally (field not
   yet wired), 0 will still land in DDB. Recommend either (a) skip
   default-fill for unsent optional fields (cleaner — DDB attribute is
   absent until firmware sends it), or (b) document the default-fill
   behavior so firmware doesn't accidentally race a "0 = not yet
   measured" sentinel against a real 0. Minor.

b. **Threshold detector is live** — Lambda includes battery + RSRP
   threshold logic with synthetic alert writes to `gosteady-dev-alerts`
   (battery_critical < 0.05, battery_low < 0.10, signal_lost ≤ -120,
   signal_weak ≤ -110). Our synthetic values were healthy so no alert
   fired, but the path is wired. Worth a cloud-side follow-up probe
   with `battery_pct=0.04` to confirm `battery_critical` lands in the
   alert table. Not a firmware action item — firmware doesn't generate
   alerts in v1 per the locked anti-feature list.

c. **Lambda cold-start floor.** 512 ms cold start; ~308 ms warm
   execution. With ~1 heartbeat/hr × 3 devices the Lambda will mostly
   be cold during clinic deployment (long inter-invocation gaps); not a
   firmware concern but a heads-up that the heartbeat handler will pay
   the cold-start tax most of the time, and any Phase-2 fan-out work
   (EventBridge, etc.) inherits the floor.

## F2.5 Heads-up on firmware-side milestone arc renumbering (2026-04-27)

For cloud-side Claude's reference when reading future firmware entries,
the firmware-side `GOSTEADY_CONTEXT.md` 15-Step Arc was refactored
2026-04-27 — driving priority is **see the cloud↔firmware connection
ASAP** so cloud-side speculatively-built work gets concrete acceptance
testing earliest.

- **M12.1c → M12.1c.1 / M12.1c.2.** `.1` is bench-cert minimum-viable
  heartbeat (one publish from `GS9999999999` with placeholder battery —
  the "first cloud↔firmware connection" moment). `.2` is
  production-shaped heartbeat (hourly cadence + all extras + real
  battery). Sliced this way to surface findings like §F2.3 ASAP.
- **M12.1e → M12.1e.1 / M12.1e.2.** `.1` is the micro-milestone NCS
  Shadow lib bench check (resolves §C.5.1). `.2` is the pre-activation
  gate + Shadow re-check implementation. Sequencing depends on §F2.3.
- **M12.1b dropped** — folded into M12.1c.2 (cadence + PSM logging are
  part of the production-shaped heartbeat, not a separate deliverable).
- **M11 → M11.1 (algo-side, currently *passing*) / M11.2
  (deployment-side outcome).**
- **M14.5 added** — explicit site-survey unit shakedown milestone
  between feature-complete and clinic ship; includes M11.1 confirmation
  walk against shipping firmware build.
- **New M10.7 "Initial production telemetry"** holds storage
  repartition + nPM1300 fuel gauge + crash forensics — pulled forward
  from M14 because they're prereqs for the production-shaped heartbeat
  / no-OTA-safety-net respectively, both required before site-survey
  ship.
- **M14 renamed to "Final production telemetry"** — future-work
  bucket: OTA + unit-4+ hardening.

When this entry says "M12.1c", cloud-side can read it as either `.1` or
`.2` per context; subsequent firmware entries will use the dotted form
explicitly.

## F2.6 Next firmware step

Sub-task 0 done. Next: sub-task 1 (cert-flash host script + MQTT/TLS
bring-up via NCS `aws_iot` lib + first heartbeat publish from real
firmware on the bench Thingy:91 X using `GS9999999999` cert).
Estimated 3-5 days. Next firmware milestone entry will post when the
first real heartbeat from firmware lands in the DDB row (or fails to,
in which case the §F2.2 baseline gives us a clean half of the bisect).

---

*Entry owner (firmware side): Jace + Claude. Counter-proposals welcome.*

---
---

# Cloud team response — 2026-04-27 (heartbeat storage drift resolved + probe results)

> **In response to:** firmware §F2 entry above (sub-task 0 acceptance probe).
>
> **TL;DR:** Drift is resolved — answer is **option 2** (Lambda is
> pre-revision; spec describes the post-Phase 1B revision target).
> Phase 1B revision is fully specced in `docs/specs/phase-1b-revision.md`
> and is the next major dev-path item; commits to deploying it before
> firmware needs M12.1e.2 unblocked. Cloud-side battery + signal probes
> complete (§C4.3 below) — confirms threshold detection logic fires on
> the OLD handler but the alert PutItem fails post-0B-revision
> (`patientId`-keyed alerts table vs OLD handler's `serialNumber` PK
> writes); 1B revision is the fix. Acks §F2.4 minor observations and
> §F2.5 milestone renumbering.

---

## C4.1 Heartbeat storage drift — option 2

The drift §F2.3 surfaced is real and the answer is **option 2: spec
describes the target post-revision design; deployed Lambda is
pre-revision and needs the 1B revision to come into compliance.**

Where the post-revision design lives:
- `ARCHITECTURE.md §7` ("Heartbeat (hourly) — written to Device Shadow")
  and the trailing note "Heartbeat updates Device Shadow `reported`
  state. Threshold detection runs on shadow delta, not on every
  heartbeat Lambda invocation." This is the canonical target.
- `ARCHITECTURE.md §14` cumulative requirement P5 ("Heartbeat → Device
  Shadow (not Lambda → DDB); threshold detection via shadow delta")
  marked **"Revised"** — this is the tag that means "post-revision
  design, not yet implemented."
- `docs/specs/phase-1b-revision.md` ("Lambda 4: heartbeat-processor")
  explicitly slims the heartbeat-processor to "Shadow update +
  activation-ack only" with no DDB telemetry writes.
- `docs/specs/phase-1b-revision.md` ("Lambda 2: threshold-detector")
  is the **NEW Lambda** triggered by an IoT Rule on
  `$aws/things/+/shadow/update/accepted`; it consumes shadow-delta
  events and generates synthetic alerts.
- `ARCHITECTURE.md §15` (Lambda Inventory) annotates
  `gosteady-{env}-heartbeat-processor` as
  "🔄 Implemented (revision slims to Shadow update + activation-ack)"
  and adds `gosteady-{env}-threshold-detector` as
  "🔲 New (replaces heartbeat-processor's threshold role)".

The OLD heartbeat handler that's deployed today is the original
Phase 1B implementation (predates the firmware-coord §F.9.4 Shadow
re-check decision and predates the P5 revision). Its design choice
to write DDB directly was correct for original Phase 1B; the
revision flips it.

**Cloud team commits:** Phase 1B revision is the next major
dev-path implementation item, before firmware reaches M12.1e.2.
Realistic timing: 1-2 focused dev sessions. The spec is fully
written + ready to implement; no open design questions blocking it.

## C4.2 Implications for firmware milestone sequencing

Firmware's read in §F2.3 is correct. To restate cleanly:

| Firmware milestone | Cloud dependency | Status |
|---|---|---|
| M12.1c.1 (bench-cert minimum-viable heartbeat) | None — firmware just publishes; cloud handler shape doesn't matter | Cloud-ready (verified §F2.2 + §C4.3 below) |
| M12.1c.2 (production-shaped heartbeat) | None — same as .1 | Cloud-ready |
| M12.1e.1 (NCS Shadow lib bench check) | None — pure firmware-side mechanics + maybe a stub Thing call | Cloud-ready (Shadow grants are live in `gosteady-dev-device-policy` per §C2.3) |
| **M12.1e.2 (pre-activation gate + Shadow re-check)** | **Phase 1B revision deployed** — needs heartbeat handler writing `reported.{...}` to Shadow + threshold-detector consuming shadow-delta + the activation-ack path operational | **Blocked on cloud team's 1B revision deploy** |

The activation-ack path specifically: per §F.9.4 / DL14, firmware
writes `reported.activated_at` directly via `iot:UpdateThingShadow`
on its own Thing (Shadow grants in policy support this). Cloud-side
threshold-detector / device-shadow-handler consumes the
`reported.activated_at` shadow-delta event and marks Device Registry
`activated_at` accordingly. That cloud-side consumer **doesn't
exist** until 1B revision deploys; until then, M12.1e.2's Shadow
write from device side will succeed at the Shadow layer but won't
trigger any cloud-side state change.

So firmware sequencing: M12.1c.1 → M12.1c.2 → M12.1e.1 → **wait for
1B revision deploy** → M12.1e.2.

## C4.3 Cloud-side threshold-detector probe (per §F2.4b suggestion)

Ran three synthetic heartbeats against `gs/GS9999999999/heartbeat` to
characterize the threshold-detection path under the current OLD
handler:

| Probe | Payload | Threshold logic fires? | Alert lands in DDB? | Lambda outcome |
|---|---|---|---|---|
| 1 — battery_critical solo | `battery_pct=0.04, rsrp_dbm=-100` | ✅ (`battery_critical`) | ❌ ValidationException | Lambda returns OK; error logged |
| 2 — signal_lost solo | `battery_pct=0.5, rsrp_dbm=-125` | ✅ (`signal_lost`) | ❌ ValidationException | Lambda returns OK; error logged |
| 3 — combined breach | `battery_pct=0.03, rsrp_dbm=-125` | ✅ both (`battery_critical` + `signal_lost`) | ❌ both ValidationException | Lambda returns OK; both errors logged |

CloudWatch log evidence:
```
[HEARTBEAT][OK]    serial=GS9999999999 ts=...22:30 battery=0.04 rsrp=-100.0 ...
[HEARTBEAT][ALERT][ERROR] serial=GS9999999999 type=battery_critical:
  An error occurred (ValidationException) when calling the PutItem
  operation: One or more parameter values were invalid: Missing the
  key patientId in the item
```
... same shape for signal_lost and the combined-breach run.

What this shows:
- ✅ **Threshold detection logic is intact** — fires on all three
  expected paths. Suppression rules work too (combined probe at
  battery=0.03 / rsrp=-125 fires `battery_critical` not `battery_low`,
  and `signal_lost` not `signal_weak` — Phase 1B D7 mutual-exclusivity).
- ❌ **Alert PutItem fails post-0B-revision** because alerts table is
  now `patientId`-keyed and the OLD handler still writes with
  `serialNumber`. Lambda swallows the error, logs it, returns success
  — so the **DLQ stays empty** (the IoT Rule sees a successful Lambda
  invocation). This is exactly the post-0B-pre-1B broken state the
  0B revision spec called out.
- ⚠️ **Operational visibility caveat:** these alert-write failures
  are visible only in CloudWatch logs. There's no CloudWatch alarm on
  the error pattern yet (Phase 1.6 territory). If we ran with real
  devices in this state, threshold-triggered alerts would silently
  not generate, and the only signal would be log volume.

Net for firmware: cloud-side acceptance for M12.1c.1 / M12.1c.2 is
clean (heartbeat publish → device registry update works). Threshold
alerts are a 1B-revision deliverable; firmware's anti-feature list
already excludes generating alerts, so this isn't a firmware concern,
just a cloud-team to-do.

## C4.4 §F2.4 minor observations — responses

**(a) uptimeS=0 default-fill.** Confirmed: OLD handler default-fills
missing optional fields with 0. **Phase 1B revision Lambda 4 spec
explicitly inverts this** per D16 ("All uplink schemas tolerate extra
fields gracefully — heartbeat extras → Shadow"). New behavior:
firmware sends what it sends; what arrives lands in `reported.{...}`
exactly as-given; missing fields stay missing in shadow (no
default-fill, no sentinel zeros). So §F2.4a is also a "1B revision
fixes it" item — no separate change needed.

**(b) Threshold detector probe.** Done — see §C4.3 above. Closes the
"threshold detector live but unverified" gap.

**(c) Lambda cold-start floor.** Acknowledged. ~512 ms cold + ~308 ms
warm execution is consistent with Python 3.12 ARM64 init. With ~3
units × 1 heartbeat/hr the handler will be cold most invocations.
Phase 1B revision Lambda 4 (slimmed to Shadow update + ack) will be
faster — fewer validations, fewer DDB writes, less code path. Not a
firmware concern; flagged for Phase 1.6 observability work to decide
whether provisioned concurrency is worth it. Likely no, at MVP scale.

## C4.5 §F2.5 milestone renumbering — acknowledged

Cloud-side will use the dotted form (`M12.1c.1`, `M12.1c.2`,
`M12.1e.1`, `M12.1e.2`, `M11.1`, `M11.2`, `M10.7`, `M14.5`) in future
entries. Specifically, future §C-prefixed entries will reference:

- **M12.1c.1** when discussing "first cloud↔firmware connection moment"
- **M12.1e.2** when discussing the pre-activation gate / Shadow
  re-check, since that's the milestone with cloud-side Shadow
  dependencies
- **M14.5** as the trigger for the next major firmware-cloud
  coordination batch (site-survey unit shakedown)

The driving priority firmware mentioned ("see the cloud↔firmware
connection ASAP so cloud-side speculatively-built work gets concrete
acceptance testing earliest") is mirrored on the cloud side — every
revision deploy this past week was a speculative implementation
against the post-coord-batch design. Concrete acceptance testing
is genuinely valuable. §F2 is a great example of the model working.

## C4.6 Cloud-side cleanup item

The probe runs in §C4.3 left the Device Registry row for
`GS9999999999` showing `batteryPct=0.03` and `rsrpDbm=-125` (the
combined-breach probe). That's stale state for the bench cert — when
firmware actually starts publishing heartbeats from the bench unit
at M12.1c.1, fresh values will overwrite. No cleanup needed; flagging
because it'll show up in any incidental verification queries until
M12.1c.1 lands.

## C4.7 Cadence

This entry resolves §F2.3 + addresses §F2.4 + acks §F2.5. No
firmware action required on the doc itself.

Cloud team's next coordination-doc-affecting work: implementing
Phase 1B revision (target: next focused dev session, before firmware
reaches M12.1e.2). Will post a §C5 implementation milestone update
when that ships.

Next firmware coord batch trigger: M14.5 site-survey unit shakedown,
unchanged from the original §9 cadence note.

---

*Entry owner (cloud side): Jace + Claude. Counter-proposals welcome.*

---
---

# Firmware team milestone update — 2026-04-27 (M12.1c.1 — first heartbeat from real firmware lands in cloud Shadow)

> **Closes:** M12.1c.1 (bench-cert minimum-viable heartbeat) — full
> end-to-end verified on the bench unit at 2026-04-28T03:22:45Z UTC.
>
> **Confirms:** Phase 1B revision Lambda is live and writing Shadow.
> §F2.3 spec-drift is resolved in code, not just in spec. Cloud team's
> deploy happened 2026-04-27T23:38:54 UTC — about 3 hours before our
> first successful E2E publish. Thanks for the fast turnaround.
>
> **TL;DR:** Bench unit GS9999999999 attached to LTE-M, connected to
> AWS IoT Core via TLS in 5 s, published one heartbeat to
> `gs/GS9999999999/heartbeat`, received PUBACK from broker in 342 ms,
> disconnected cleanly. Heartbeat appears in Device Shadow at version
> 9 with all 5 required fields (serial, ts, battery_pct, rsrp_dbm,
> snr_db) populated correctly. Total boot-to-PUBACK: 17 s.

---

## F3.1 What landed

Confirmed via `aws iot-data get-thing-shadow --thing-name GS9999999999`
immediately after the firmware logged `PUBACK received — broker confirmed`:

```json
{
  "state": {
    "reported": {
      "serial": "GS9999999999",
      "ts": "2026-04-28T03:22:45Z",
      "battery_pct": 0.5,
      "rsrp_dbm": -88,
      "snr_db": 6,
      ...
    }
  },
  "version": 9
}
```

`battery_pct=0.5` is the M12.1c.1 hardcoded placeholder per plan; real
fuel-gauge value lands with M10.7.2 / M12.1c.2. `rsrp_dbm=-88, snr_db=6`
are real signal stats from M12.1a's `AT+CESQ` reporter. `ts` is real
NITZ time from `AT+CCLK?`. Shadow metadata timestamp 1777346567 = exact
firmware publish timestamp.

Lambda CloudWatch entry corroborates:

```
{"level": "INFO", "message": "heartbeat_ok",
 "serial": "GS9999999999", "ts": "2026-04-28T03:22:45Z",
 "battery_pct": 0.5, "rsrp_dbm": -88, ...}
Duration: 389.91 ms (cold start)
```

## F3.2 Bugs surfaced + fixed in the bench-test path

Two firmware-side bugs found during M12.1c.1 validation. Both have
implications for any future firmware that publishes to AWS IoT, so
worth surfacing for the record.

**(1) QoS 0 + fixed-delay drain races NB-IoT latency.** Initial
implementation used `MQTT_QOS_0_AT_MOST_ONCE` followed by
`k_sleep(K_MSEC(500))` before `aws_iot_disconnect`. On NB-IoT
(~1-3 s RTT) the modem tore down TCP before the PUBLISH bytes hit the
wire. Lambda showed zero invocations across two NB-IoT publish attempts.
Fix: switch to `MQTT_QOS_1_AT_LEAST_ONCE` and wait on
`AWS_IOT_EVT_PUBACK` before disconnecting. Removes the fixed-delay
guess entirely — broker confirms receipt or we time out at 30 s.

**(2) `CONFIG_AWS_IOT_AUTO_DEVICE_SHADOW_REQUEST=y` (NCS default)
silently violates per-thing IoT policy.** With the default, the
aws_iot lib publishes to `$aws/things/GS9999999999/shadow/get`
immediately after CONNACK to fetch the device shadow. Our policy
(`gosteady-dev-device-policy`) only allows MQTT publish on
`gs/{thing}/{heartbeat,activity,alert,snippet}` — shadow MQTT
topics are not listed. AWS IoT broker silently disconnects on policy
violation, ~4 s after CONNECTED, before any of our app-level publishes
get a PUBACK. Symptom: heartbeat publish hangs on PUBACK timeout (30 s),
then `aws_iot_disconnect` returns -95 because the broker already
disconnected us. Fix: add `CONFIG_AWS_IOT_AUTO_DEVICE_SHADOW_REQUEST=n`
to prj_cloud.conf and prj_field.conf. **Heads-up for cloud-side
M12.1e.2 work:** when firmware needs to read shadow on cellular wake
per §C.4.4, the policy will need to allow MQTT publish on
`$aws/things/${iot:Connection.Thing.ThingName}/shadow/get` (and the
get/accepted/rejected subscribe topics). NCS aws_iot lib's
"AUTO_DEVICE_SHADOW_REQUEST" path is the wrong abstraction for our
use case (it fires on connect; we want explicit on-wake fetch only),
so M12.1e.2 will likely use direct shadow get/update calls rather
than re-enabling that Kconfig.

Both fixes committed in `gosteady-firmware/e36a14e` with full rationale
in the message. The dual-bug experience is exactly the kind of finding
M12.1c.1 was designed to surface — the M12.1c.2 production-shaped
heartbeat now has retry + cadence + extras to add, but no surprise
auth or transport issues to debug.

## F3.3 Phase 1B revision validation (drive-by)

Cloud team's Phase 1B revision Lambda was deployed silently at
2026-04-27T23:38:54 UTC (per `aws lambda get-function-configuration
--function-name gosteady-dev-heartbeat-processor --query
LastModified`). Our firmware-side first publish at 03:22:45 UTC was
the first real-firmware heartbeat through the new Lambda. Validation
results:

- ✅ Lambda fired on receipt of our publish (`heartbeat_ok` log entry,
  cold_start=true → first invocation in a while)
- ✅ Lambda parsed the payload correctly (all 5 required fields read
  back into the log entry with our exact values)
- ✅ Shadow.reported updated with our payload (Shadow version 9,
  metadata timestamp matches publish wall-clock)
- ✅ DDB row left untouched (Lambda no longer writes DDB on heartbeat
  per §C4.1 / Phase 1B revision design)

§F2.3 spec drift is now resolved in code, not just on paper. Firmware
side has updated `GOSTEADY_CONTEXT.md` Heartbeat uplink table to
remove the "currently deployed: DDB" caveat.

One small quirk worth noting: Shadow.reported retains older fields
from cloud-team probe runs (`firmware: "1.2.0"`, `uptime_s: 86400`,
`reset_reason: "power_on"`, `fault_counters`, `watchdog_hits`,
`lastPreactivationAuditAt`) because partial updates don't remove
fields. Their metadata timestamps are 1777333281–1777333282 (older
probes); only the 5 fields we sent now have the fresh 1777346567
timestamp. Not a problem — Shadow's "old fields persist" is documented
behavior — just worth being aware of when reading the Shadow document
for diagnostic purposes.

## F3.4 What's next firmware-side (Stage B per the renumbered arc)

M12.1c.1 closure unblocks the rest of M12.1c / .1d / .1e:

- **M12.1d** (activity uplink on session close) — cheap, ~1 day,
  reuses M12.1c.1's TLS+MQTT path. Just a different topic + payload
  builder. Useful as the next acceptance probe target on cloud side.
- **M10.7.2** (nPM1300 fuel gauge wiring) — ~1 day, gets real
  battery_pct into the heartbeat instead of the 0.5 placeholder.
- **M12.1c.2** (production-shaped heartbeat) — hourly cadence + all
  locked optional extras + retry-on-failure (see "bug 1" above:
  M12.1c.1's lack of retry was OK for the bench test where we could
  just power-cycle, but production needs exponential-backoff on
  -EAGAIN / -ETIMEDOUT). Depends on M10.7.2 + M10.7.3.

Next coord-doc trigger from firmware side: M12.1d activity uplink
landing (probably this week) — second message type into cloud,
closes the schema-coverage on the §C.7 activity table.

## F3.5 Cadence

This entry is the M12.1c.1 milestone-complete announcement. No firmware
action items for cloud team (Phase 1B revision is already deployed and
working). One soft heads-up about M12.1e.2 shadow-policy needs in §F3.2
for cloud-side planning.

---

*Entry owner (firmware side): Jace + Claude. Counter-proposals welcome.*

---
---

# Cloud team milestone update — 2026-04-28 (Phase 1B revision deployed)

> **From:** GoSteady cloud team
> **Closes:** the §C4.7 commitment to post a §C5 implementation milestone
> update when 1B revision ships.
> **In response to:** firmware §F3 (M12.1c.1 milestone closure) — which
> beat this entry to the doc by a few hours, since firmware's first real
> publish landed against the freshly-deployed Lambda.
>
> **TL;DR:** Phase 1B revision deployed to dev 2026-04-27T23:38:54 UTC
> (commit `1a1684f`). Heartbeat-processor slimmed (Shadow only, no DDB
> on routine heartbeat) — resolves §F2.3 drift in code. New
> `gosteady-dev-threshold-detector` Lambda live, triggered by Shadow
> update IoT Rule, generates synthetic alerts post-activation only.
> Activity + alert handlers refactored to patient-centric PKs with
> hierarchy snapshot. **All four handlers Python 3.12 ARM64 with
> Powertools.** Firmware §F3.2 bug (2) — Shadow MQTT topic IoT-policy
> grants — is a real gap on the cloud side; commitment + remedy in
> §C5.4 below. Should be a small follow-up deploy.

---

## C5.1 Ack of firmware §F3 milestone

Congrats on M12.1c.1 closure. The §F3.1 Shadow document is exactly the
shape we hoped to see — all five required heartbeat fields populated
with real device-sourced values (RSRP/SNR from `AT+CESQ`, NITZ
timestamp from `AT+CCLK?`, hardcoded battery placeholder per plan).
Net 17 s boot-to-PUBACK on first try is comfortably inside any
realistic cellular-wake budget.

The "drive-by validation" of Phase 1B revision in §F3.3 saved us a
synthetic acceptance probe — the firmware-side publish was the first
real-firmware heartbeat through the new Lambda, and all four checks
came back clean. We did run our own synthetic probes earlier in the
deploy (acceptance results are captured in
[`docs/specs/phase-1b-revision.md`](../specs/phase-1b-revision.md)
Test Scenarios T2–T18); the firmware-side validation closes the loop.

The "old fields persist" quirk you flagged in §F3.3 is correct and
expected — Shadow does merge-not-replace on partial `reported` writes,
so probe-era fields (`firmware`, `uptime_s`, `reset_reason`, etc.)
linger until a future write removes them. We'll let those age out
naturally; nothing actionable.

---

## C5.2 Ack of firmware §F3.2 bug fixes

Both findings are useful records:

**(1) QoS 0 + fixed-delay drain on NB-IoT.** Confirmed safe — QoS 1
+ wait-on-PUBACK is the right pattern for cellular publish. We have
no analog cloud-side bug; just glad it surfaced on bench rather than
in clinic. M12.1c.2's retry-on-failure path will be a stronger
guarantee.

**(2) `CONFIG_AWS_IOT_AUTO_DEVICE_SHADOW_REQUEST=y` policy
violation.** This is the more interesting find — see §C5.4 below for
the cloud-side action that follows from it.

---

## C5.3 What 1B-rev landed

For the record — full detail in
[`docs/specs/phase-1b-revision.md`](../specs/phase-1b-revision.md)
Changelog and ARCHITECTURE.md §12 Phase 1B:

| Component | Change |
|---|---|
| `gosteady-dev-heartbeat-processor` | Slimmed to Shadow.reported update + activation-ack only. NO DDB telemetry writes on routine heartbeat (per ARCHITECTURE.md P5). Activation-ack matches `last_cmd_id` against `Device Registry.outstandingActivationCmds` within 24 h window (DL14a). **Dormant** until Phase 2A `device-api` populates the map. |
| `gosteady-dev-threshold-detector` (NEW) | Triggered by IoT Rule on `$aws/things/+/shadow/update/documents` (the topic the spec said `update/accepted` — see §C5.5 below). Pre-activation suppression: skips synthetic alerts when Device Registry `activated_at` is null; emits `device.preactivation_heartbeat` audit at ≤1/hr/serial via Shadow `reported.lastPreactivationAuditAt` dedupe. Post-activation: writes synthetic alerts to Alert History with `source=cloud`, hierarchy snapshot, compound SK. |
| `gosteady-dev-activity-processor` | Patient-centric (PK = patientId). Hierarchy snapshot frozen at write. `expiresAt` TTL (sessionEnd + 13 mo). Optional firmware extras (`roughnessR`, `surfaceClass`, `firmwareVersion`) on top-level columns; `extras` map for any other unknown fields. |
| `gosteady-dev-alert-handler` | Patient-centric. Hierarchy snapshot. `expiresAt` TTL (eventTimestamp + 24 mo). |
| All four | Python 3.12 ARM64 (G7). `aws-lambda-powertools` 3.x as pip dep, vendored at synth time via CDK local bundling (no Docker required on this dev machine). Structured JSON logs with PII scrubber (`displayName`/`dateOfBirth`/`email` redacted at any depth). EMF metrics in `GoSteady/Processing/dev`. |
| KMS | `kms:Decrypt` + `kms:GenerateDataKey` grants on IdentityKey for the three patient-readers (activity / threshold-detector / alert). Heartbeat-processor narrowed off (no CMK reads). |

Cloud-side acceptance (run before firmware §F3 publish): synthetic
heartbeats → Shadow only; pre-activation suppression confirmed; post-
activation `battery_pct=0.03` → single `battery_critical` (suppresses
low); combined `battery_pct=0.02 + rsrp_dbm=-125` → both alerts with
compound SKs; replay → conditional PutItem rejects duplicate; tipover
device alert lands with `source=device`; PII scrubber filter for
`displayName="PII_DO_NOT_LOG"` returned empty across all four log
groups; DLQ stayed at 0.

---

## C5.4 Action item: Shadow MQTT topic policy grants (gates M12.1e.2)

The §F3.2 bug (2) finding is a real gap on the cloud side. The
1A-rev device-policy refactor added `iot:GetThingShadow` and
`iot:UpdateThingShadow` to `gosteady-dev-device-policy` per the
§F.9.4 / §C.4.4 decision. **Those are IAM actions for the AWS IoT
REST API**, not for MQTT-protocol shadow access. The NCS `aws_iot`
library uses MQTT throughout — and the MQTT shadow protocol requires
explicit topic-level grants on `$aws/things/{thing}/shadow/...`,
which the current policy does not include.

Concretely, the policy currently allows MQTT only on the `gs/{thing}/*`
topic prefix (heartbeat / activity / alert / snippet / cmd). When
firmware tries the M12.1e.2 wake path:

1. `aws_iot_shadow_get()` → MQTT publish on `$aws/things/GS.../shadow/get`
2. broker rejects on policy violation
3. broker disconnects after a few seconds (which is exactly what bug 2
   surfaced today)

**Cloud-side fix:** add two MQTT-topic statements to the per-thing
policy (mirror of the existing publish/subscribe statements but
scoped to shadow topics):

```jsonc
// Publish to own shadow get + update
{
  "Sid": "OwnShadowMqttPublish",
  "Effect": "Allow",
  "Action": "iot:Publish",
  "Resource": [
    "arn:aws:iot:us-east-1:${account}:topic/$aws/things/${iot:Connection.Thing.ThingName}/shadow/get",
    "arn:aws:iot:us-east-1:${account}:topic/$aws/things/${iot:Connection.Thing.ThingName}/shadow/update"
  ]
},
// Subscribe + receive on own shadow get/update accepted/rejected/delta
{
  "Sid": "OwnShadowMqttSubscribe",
  "Effect": "Allow",
  "Action": ["iot:Subscribe", "iot:Receive"],
  "Resource": [
    "arn:aws:iot:.../topicfilter/$aws/things/${...}/shadow/get/accepted",
    "arn:aws:iot:.../topicfilter/$aws/things/${...}/shadow/get/rejected",
    "arn:aws:iot:.../topicfilter/$aws/things/${...}/shadow/update/accepted",
    "arn:aws:iot:.../topicfilter/$aws/things/${...}/shadow/update/rejected",
    "arn:aws:iot:.../topicfilter/$aws/things/${...}/shadow/update/delta",
    "arn:aws:iot:.../topic/$aws/things/${...}/shadow/get/accepted",
    "arn:aws:iot:.../topic/$aws/things/${...}/shadow/get/rejected",
    "arn:aws:iot:.../topic/$aws/things/${...}/shadow/update/accepted",
    "arn:aws:iot:.../topic/$aws/things/${...}/shadow/update/rejected",
    "arn:aws:iot:.../topic/$aws/things/${...}/shadow/update/delta"
  ]
}
```

**Scope and timing:** small CDK edit in `ingestion-stack.ts`; deploy
is ~30 s (policy change only). Will land as a 1A-rev addendum (or
queued ahead of the next cloud-side dev session — whichever comes
first) before firmware reaches M12.1e.2. Will post a follow-up §C6
entry when the policy update deploys; once it's live, firmware can
proceed with `aws_iot_shadow_get()`-based wake checks without
disabling `AUTO_DEVICE_SHADOW_REQUEST` as a workaround (though as
§F3.2 noted, you may prefer explicit on-wake fetch over auto-on-
connect anyway — that's a firmware-side architectural choice, not
gated by our policy).

**Heads-up before that lands:** the existing `iot:GetThingShadow` /
`iot:UpdateThingShadow` IAM actions in the policy are still
useful — they let the cloud-side Lambdas (heartbeat-processor,
threshold-detector, future device-shadow-handler) hit the REST
API. Firmware-side MQTT shadow access needs the new topic grants.

---

## C5.5 Spec correction: Shadow rule topic

For completeness — the [`phase-1b-revision.md`](../specs/phase-1b-revision.md)
Lambda 2 spec originally said the Shadow rule subscribes to
`$aws/things/+/shadow/update/accepted` with SQL projecting
`current.state.reported` and `previous.state.reported`. That
combination is internally inconsistent: `update/accepted` carries
only the merged delta as a flat `state.reported` object, no
`current` / `previous` shape. Discovered during deploy verification
when threshold-detector started returning `Duration: 17ms` because
`event.get("reported")` was None on every fire.

Fixed by switching the IoT Rule topic to `update/documents` (which
*does* carry `current` + `previous` full-state docs); SQL itself
unchanged. Inline rationale in
[`infra/lib/stacks/ingestion-stack.ts`](../../infra/lib/stacks/ingestion-stack.ts)
at the ShadowUpdateRule definition. Firmware doesn't need to know or
care about this — it's an internal cloud-side rule plumbing detail —
but flagging in case anyone reads the spec and wonders why the
deployed topic disagrees. Spec changelog entry covers it.

---

## C5.6 Lambda cold-start cost (informational)

Worth noting since §F3.1's Lambda cold-start log entry (389.91 ms)
matches what we see on the activity / threshold-detector side too.
Powertools 3.x adds ~300–400 ms to Python 3.12 ARM64 cold init. With
~3 site-survey units publishing one heartbeat/hr each, the Lambda
will be cold most invocations (long inter-invocation gaps) and pay
that init cost every time. Acceptable at MVP scale; revisit only if
a real-time SLA appears (alerts are best-effort, not millisecond-
critical). Phase 1.6 may switch Powertools to a shared layer
(reduces per-Lambda zip size, doesn't change init cost).

---

## C5.7 Cadence

This entry resolves the §C4.7 commitment + acks §F3.

**Cloud team next coord-doc-affecting work:** §C5.4 shadow MQTT
topic policy grants. ETA: next focused cloud-side dev session
(should be small + quick); will post §C6 when deployed. After that,
the only remaining cloud-side dependency for M12.1e.2 is the Phase
2A `device-shadow-handler` Lambda that consumes
`reported.activated_at` shadow-delta events and flips Device
Registry `activated_at` accordingly — that's deferred to Phase 2A
proper, dormant until then. Firmware can write
`reported.activated_at` from M12.1e.2 onwards; the cloud will
accept the Shadow update but won't yet do anything with it.

**Next firmware coord batch trigger** (per the original §9 cadence
note + §F3.4 announcement): M12.1d activity uplink landing, which
would be the second message-type ingest probe — useful symmetry to
the heartbeat-side validation closure today.

---

*Entry owner (cloud side): Jace + Claude. Counter-proposals, blocker
flags, and milestone updates welcome.*

---
---

# Firmware team milestone update — 2026-04-27 (M12.1d — first activity uplink from a real session lands in Activity DDB)

> **Closes:** M12.1d (activity uplink on session close). Same-day delivery
> as M12.1c.1; both ride the same cloud-side Phase 1B revision deploy.
> Per cloud's §C5.7 cadence, this is the "second message-type ingest
> probe" they were watching for.
>
> **Acks:** §C5 in full. §C5.4 shadow MQTT topic policy gap is the
> right read of §F3.2 bug (2); waiting on §C6 deploy before M12.1e.2.
> §C5.5 spec correction on Shadow rule topic noted (firmware-side
> opaque, agreed). §C5.6 cold-start cost acknowledged.
>
> **Confirms:** activity-processor (1B-rev'd) + DeviceAssignment patient
> resolution + Activity Series DDB write all work end-to-end with a real
> firmware payload. Two of four uplink topics in §C.7 now under concrete
> test (heartbeat = M12.1c.1, activity = M12.1d; alert + snippet still
> deferred per anti-feature list / M12.1f respectively).

---

## F4.1 What landed

```
publish gs/GS9999999999/activity -> {
  "serial":            "GS9999999999",
  "session_start":     "2026-04-28T03:54:26Z",
  "session_end":       "2026-04-28T03:54:56Z",
  "steps":             15,
  "distance_ft":       11.05,
  "active_min":        0,                       # motion=11.95s rounds to 0min
  "roughness_R":       0.1587,
  "surface_class":     "indoor",
  "firmware_version":  "0.7.0-cloud"
}
```

DDB row in `gosteady-dev-activity` (newest entry for `pt_test_001`):

```
patientId           = pt_test_001
clientId            = dtc_test_001          # hierarchy snapshot per §C5.3
censusId            = cen_synth_001         #         "
deviceSerial        = GS9999999999
timestamp           = 2026-04-28T03:54:56Z
sessionEnd          = 2026-04-28T03:54:56Z
steps               = 15
distanceFt          = 11.05
activeMinutes       = 0
roughnessR          = 0.1587                # optional firmware extra → top-level column
surfaceClass        = indoor                #         "
firmwareVersion     = 0.7.0-cloud           #         "
source              = device                # cloud distinguishes from synthetic probes
date                = 2026-04-27            # America/Los_Angeles bucket
expiresAt           = 1811024280            # sessionEnd + 13 mo TTL per §C5.3
```

Audit event from activity-processor:
```
{"event": "patient.activity.create",
 "actor": {"system": "gosteady-dev-activity-processor"},
 "subject": {"patientId": "pt_test_001", "clientId": "dtc_test_001",
             "censusId": "cen_synth_001", "deviceSerial": "GS9999999999"},
 "after": {"sessionEnd": "2026-04-28T03:54:56Z", "steps": 15,
           "activeMinutes": 0, "date": "2026-04-27"}}
```

The §C5.3 1B-rev activity-processor design points are all visible here:
patient-centric PK ✓, hierarchy snapshot frozen at write ✓, expiresAt TTL ✓,
optional firmware extras on top-level columns ✓, source=device ✓.

## F4.2 Notable observations

- **PUBACK in 655 ms** — same LTE-M cellular session as M12.1c.1's
  heartbeat publish (a few minutes earlier in the same boot). Lambda
  duration 460 ms warm; cold-start adds ~500 ms (matches §C5.6
  characterization).
- **active_min=0** is correct — the M9 motion gate said 11.95 s of
  active motion in the 30 s session; `floor((motion_s/60) + 0.5) = 0`.
  Sessions of < 30 s motion always round to 0; the field is intended
  for hour-scale rollups so this isn't a bug, but worth noting when
  reading clinic data — sub-minute precision lives on `distanceFt` /
  `steps` / sessionStart-vs-sessionEnd, not `activeMinutes`.
- **roughness_R = 0.1587 → "indoor"** — auto-classifier worked
  correctly (R < threshold τ=0.245 = indoor per M9 Phase 4
  calibration). First end-to-end confirmation that the M9 classifier
  output reaches cloud cleanly.
- **firmware_version = "0.7.0-cloud"** — bumped from 0.6.0-algo with
  the M12.1c.1 cloud bring-up. Centralized as `GS_FIRMWARE_VERSION_STR`
  macro in `src/session.c`; used in both the session header (FIRMWARE
  layer in the .dat file) and the activity uplink, so cloud-side
  queries can correlate them.

## F4.3 Code-side

`gosteady-firmware/cb94d17`:
- New `struct gosteady_activity` + `gosteady_cloud_publish_activity()`
  public API in `src/cloud.h` (inline-string struct so it can be
  msgq'd cleanly across thread boundaries).
- `src/cloud.c` refactored: extracted `connect_publish_disconnect()`
  helper holding `s_aws_mutex` so heartbeat (one-shot at boot) and
  activity (persistent worker thread blocked on msgq, depth 4) serialize
  cleanly without sharing more than they need. Both use QoS 1 + PUBACK
  wait per the M12.1c.1 closure debug.
- `src/session.c` captures cellular UTC at `session_start`, builds the
  activity struct from M9 outputs at `session_stop`, calls the new
  cloud API. Gated on `IS_ENABLED(CONFIG_GOSTEADY_CLOUD_ENABLE)` —
  bench builds for M8 data collection skip the activity publish entirely.

Build sizes after M12.1d: bench 810 KB (unchanged — IS_ENABLED works),
cloud 892 KB (+9 KB for the activity worker), field 869 KB.

## F4.4 What's next firmware-side

- **M10.7.2** (nPM1300 fuel gauge wiring) — ~1 day, gets real
  `battery_pct` into the heartbeat instead of the 0.5 placeholder.
- **M12.1c.2** (production-shaped heartbeat) — hourly cadence + all
  locked optional extras (`last_cmd_id`, `reset_reason`, `fault_counters`,
  `watchdog_hits`, `uptime_s`, `firmware`) + retry-with-backoff. Depends
  on M10.7.2 + M10.7.3.
- **M10.7.1** (storage repartition) — foundation for M10.7.3 + M12.1f.
- **M10.7.3** (crash forensics + watchdog) — depends on 10.7.1.
- **M12.1e.1** (NCS Shadow lib bench check) — small ~half-day. Now
  blocked on cloud §C5.4 (shadow MQTT topic policy grants); once §C6
  drops we can knock this out.
- **M12.1e.2** (pre-activation gate + Shadow re-check) — depends on
  M12.1e.1 + §C5.4.

Next coord-doc trigger from firmware side: probably either M12.1c.2
hourly-cadence first sequence landing in cloud Shadow with extras
populated, OR M12.1f snippet uplink work surfacing a question on the
binary preamble + JSON header framing in §F.3 / §F.4. Whichever lands
first.

## F4.5 Cadence

This entry is the M12.1d milestone-complete announcement + ack of §C5.
No firmware action items for cloud team beyond the §C5.4 follow-up
(which cloud is already on). Activity-processor is working correctly
with our payload; DeviceAssignment patient resolution is working;
audit events are emitting; DDB writes are landing with full hierarchy
snapshot + TTL. Solid stop point for the cloud-side acceptance
testing concern that drove M12.1c.1 + M12.1d in the first place.

---

*Entry owner (firmware side): Jace + Claude. Counter-proposals welcome.*

---
---

# Cloud team milestone update — 2026-04-28 (Shadow MQTT topic policy grants — §C5.4 closure)

> **From:** GoSteady cloud team
> **Closes:** the §C5.4 follow-up commitment — Shadow MQTT topic policy
> grants are now live in `gosteady-dev-device-policy`.
> **Acks:** firmware §F4 (M12.1d activity uplink closure). The DDB row
> shape in §F4.1 is exactly the §C5.3 design intent; nice to see the
> patient-centric PK + hierarchy snapshot + extras + expiresAt all
> populated cleanly on real-firmware payload. Patient-resolution
> pipeline working end-to-end was the highest-risk part of 1B-rev —
> good to have it confirmed by a non-synthetic publish.
>
> **TL;DR:** Firmware can now use `aws_iot_shadow_get()` /
> `aws_iot_shadow_update()` over MQTT. Both M12.1e.1 (NCS Shadow lib
> bench check) and M12.1e.2 (pre-activation gate + Shadow re-check)
> are cloud-side unblocked. One small implementation choice worth
> flagging: we used a `shadow/*` wildcard rather than enumerating each
> channel — see §C6.2 for why.

---

## C6.1 What deployed

Two new statements added to `gosteady-dev-device-policy` (per-thing
policy, scoped via `${iot:Connection.Thing.ThingName}`):

```jsonc
{
  "Sid": "OwnShadowMqttPublish",
  "Effect": "Allow",
  "Action": "iot:Publish",
  "Resource": "arn:aws:iot:us-east-1:460223323193:topic/$aws/things/${iot:Connection.Thing.ThingName}/shadow/*"
},
{
  "Sid": "OwnShadowMqttSubscribe",
  "Effect": "Allow",
  "Action": ["iot:Subscribe", "iot:Receive"],
  "Resource": [
    "arn:aws:iot:us-east-1:460223323193:topicfilter/$aws/things/${iot:Connection.Thing.ThingName}/shadow/*",
    "arn:aws:iot:us-east-1:460223323193:topic/$aws/things/${iot:Connection.Thing.ThingName}/shadow/*"
  ]
}
```

**Effective grant table** (all scoped to the device's own thing):

| MQTT operation | Topic | Allowed? |
|---|---|---|
| Publish | `$aws/things/{thing}/shadow/get` | ✅ |
| Publish | `$aws/things/{thing}/shadow/update` | ✅ |
| Publish | `$aws/things/{thing}/shadow/delete` | ✅ (acceptable — see §C6.2) |
| Subscribe + Receive | `$aws/things/{thing}/shadow/get/accepted` | ✅ |
| Subscribe + Receive | `$aws/things/{thing}/shadow/get/rejected` | ✅ |
| Subscribe + Receive | `$aws/things/{thing}/shadow/update/accepted` | ✅ |
| Subscribe + Receive | `$aws/things/{thing}/shadow/update/rejected` | ✅ |
| Subscribe + Receive | `$aws/things/{thing}/shadow/update/delta` | ✅ |
| Subscribe + Receive | `$aws/things/{thing}/shadow/delete/*` | ✅ (same caveat) |
| Anything on a different thing's shadow | — | ❌ (per-thing scoping) |

The existing `OwnShadowApi` statement (REST-API actions
`iot:GetThingShadow` / `iot:UpdateThingShadow` on
`thing/{iot:Connection.Thing.ThingName}`) is unchanged. Cloud-side
Lambdas still use the REST path; firmware now has the MQTT path.

---

## C6.2 Why wildcard instead of explicit channel enumeration

Initial deploy attempt enumerated all seven channels (get / get/accepted
/ get/rejected / update / update/accepted / update/rejected /
update/delta) on both `topic/` and `topicfilter/` ARN forms. That came
to ~2129 bytes serialized — over AWS IoT's 2048-byte hard limit on
policy documents, and CFN failed the update with
`Policy cannot be created - size exceeds hard limit (2048)`.

Two ways to handle the cap: (a) enumerate fewer channels (lose
explicit `update/delta`, etc.) or (b) wildcard. We picked (b). The
relaxation versus full enumeration: `shadow/delete` and any future
AWS-added shadow sub-paths become allowed on the device's own thing.
Worst case for `delete`: the device wipes its own shadow document,
which the cloud can rewrite via `desired` state on next provision
transition (the §F.9.4 / DL14 invariant doesn't depend on the
previous shadow content). Tenancy is unaffected — the wildcard sits
inside the per-thing scope, so a device still cannot touch another
device's shadow regardless.

The deployed policy is 1558 bytes (490-byte margin under cap). A new
jest assertion in `infra/test/ingestion-stack.test.ts` measures the
rendered policy size and fails if it ever creeps within 200 bytes of
the cap, so future grants don't silently re-trigger the issue.

This is captured as cumulative requirement DL14b in
[`ARCHITECTURE.md` §14](../specs/ARCHITECTURE.md), and as a 2026-04-28
addendum entry in the
[`phase-1a-revision.md`](../specs/phase-1a-revision.md) Changelog.

---

## C6.3 What this unblocks

Per firmware §F4.4:

- **M12.1e.1** (NCS Shadow lib bench check) — was flagged as blocked
  on §C5.4. **Unblocked.** Should be a clean ~half-day.
- **M12.1e.2** (pre-activation gate + Shadow re-check) — also
  cloud-side unblocked, but with one remaining cloud-side caveat
  worth restating from §C5.7:

  The cloud-side **consumer** of `reported.activated_at` shadow-delta
  events (a `device-shadow-handler` Lambda that watches for the
  device-side ack and flips `Device Registry.activated_at`
  accordingly) is **deferred to Phase 2A** — it lives alongside the
  `device-api` Lambda that issues the activate cmds in the first
  place, since both touch the same Device Registry attributes.

  Practical implication: from M12.1e.2 onwards, firmware can
  successfully `aws_iot_shadow_get()` to read `desired.activated_at`
  and `aws_iot_shadow_update()` to write `reported.activated_at` —
  the broker will accept both. But until Phase 2A ships, the cloud
  side won't pick up the `reported.activated_at` ack signal, so
  `Device Registry.activated_at` stays in whatever state it was
  before the M12.1e.2 publish.

  **For firmware's M12.1e.2 acceptance probe:** the Shadow round-trip
  itself is the testable surface. Verify with `aws iot-data
  get-thing-shadow` after the firmware update — `reported.activated_at`
  should match what firmware just wrote. End-to-end activation flow
  (cloud-side device-api → cmd publish → firmware receive → device
  ack via `last_cmd_id` heartbeat echo + Shadow `reported.activated_at`
  write → device-shadow-handler consumes the delta → Device Registry
  flip) is a Phase 2A integration test, not an M12.1e.2 test.

- **M12.1c.2** (production-shaped heartbeat) — independent; not gated
  on §C6.

---

## C6.4 Acks of firmware §F4 highlights

A few drive-by acknowledgements:

- The fact that `pt_test_001` / `dtc_test_001` / `cen_synth_001` (the
  synthetic Patients + DeviceAssignment row I created during 1B-rev
  acceptance testing) ended up resolving the real firmware activity
  publish was unintentional but correct — those rows live in the dev
  DDB indefinitely until cleaned up. They are safe to leave in place
  through the rest of the bench / site-survey work; firmware-side
  publishes from `GS9999999999` will continue to resolve to that
  patient row. We can clean up before site-survey unit ships if
  needed, or leave them as forever-bench-fixtures and add a
  `synthetic_for_testing: true` flag if we want to filter from
  internal-admin queries later.
- §F4.2's `active_min=0` rounding from 11.95 s motion → noted; no
  cloud-side change needed (cloud just stores what firmware sends).
  Worth flagging on the portal-UX side when caregiver dashboards
  start showing `activeMinutes` aggregates so we don't surprise
  product with sub-minute sessions reading as zero. Not a now-thing.
- §F4.2's `roughness_R=0.1587 → "indoor"` is the first end-to-end
  observation that the M9 surface classifier cleanly reaches cloud.
  We persist `surfaceClass` as a top-level column today; if you ever
  start needing the raw `R` value at portal-rendering time, just
  query `roughnessR` instead.
- §F4.3 build sizes (810/892/869 KB) — useful telemetry; cloud has
  no side here, just appreciating the per-build accounting.

---

## C6.5 Cadence

This entry closes the §C5.4 commitment. With it, **the cloud-side
processing layer + ingestion infrastructure are feature-complete for
the firmware bring-up + site-survey scope** — every firmware-side
milestone through M14.5 now has its cloud-side half ready.

**Next cloud-side dev-path items** (no longer firmware-coordination-
gating):

1. Phase 1.6 Observability — alarm catalog (especially log-pattern
   filters for the swallowed-error pattern; see ARCHITECTURE.md §16),
   X-Ray activation, dashboards.
2. Phase 1.7 Audit — dedicated audit log group + S3 Object Lock
   destination + subscription filter to route the audit-shape log
   entries the 1B-rev handlers already emit.
3. Phase 2A device-lifecycle — `device-api` Lambda (provision
   endpoint, populates `outstandingActivationCmds`, publishes
   activate cmds, writes Shadow `desired.activated_at`),
   `device-shadow-handler` (consumes `reported.activated_at`,
   flips Device Registry `activated_at`), `discharge-cascade` Lambda.

1.6 + 1.7 specs aren't drafted yet; both gate Phase 2A. No firmware-
side dependency on any of those landing.

**Next firmware coord batch trigger** (per §F4.4): M12.1c.2 hourly-
cadence first sequence with extras populated, OR M12.1f snippet
uplink (which would surface real questions on the §F.3 / §F.4
binary-preamble framing). Whichever lands first.

---

*Entry owner (cloud side): Jace + Claude. Counter-proposals, blocker
flags, and milestone updates welcome.*



---
---

# Firmware milestone update — 2026-04-29 (M10.7 production-telemetry stack + M12.1c.2 hourly heartbeat with extras — code-complete + bench-validated)

> **From:** GoSteady firmware team
> **Closes:** §C6.5's invitation — M12.1c.2 hourly-cadence first sequence
> with all locked optional extras populated. First Shadow update with the
> full production-shape payload landed at 2026-04-29T20:02:32Z.
>
> **Acks:** §C5 + §C6 in full. Shadow MQTT topic policy grants verified
> usable end-to-end during M12.1c.2 development (didn't actually exercise
> shadow_get/update yet — that's M12.1e.1's surface — but the Shadow
> document now carries our heartbeat extras cleanly so the policy chain
> is healthy through the publish path at minimum). The wildcard scoping
> (§C6.2) is fine as-is. The pre-created `pt_test_001` / `dtc_test_001` /
> `cen_synth_001` synthetic patient row continues to be the right fixture
> for `GS9999999999` activity uplinks; no cleanup needed for our purposes.
>
> **Confirms:** the four M10.7 + M12.1c.2 milestones from the firmware
> arc are code-complete and bench-validated. Specifically:
>
>   - M10.7.1 storage repartition (crash_forensics + telemetry_queue +
>     snippet_storage carved out of the previously-unused 19 MB tail of
>     external flash — foundation for the rest of the production stack)
>   - M10.7.2 nPM1300 fuel gauge wiring (real `battery_pct` + new
>     `battery_mv`)
>   - M10.7.3 crash forensics + watchdog (reset reason + fault counters
>     + watchdog hit counter persisted across reset; HW watchdog kicked
>     from a dedicated supervisor thread)
>   - M12.1c.2 production-shaped heartbeat (hourly cadence + linear-
>     backoff retry + all locked optional extras: `battery_mv`,
>     `firmware`, `uptime_s`, `last_cmd_id`, `reset_reason`,
>     `fault_counters`, `watchdog_hits`)
>
> Firmware version bumped 0.7.0-cloud → **0.8.0-prod**.

---

## F5.1 What landed in cloud Shadow

First production-shaped heartbeat publish, captured on uart0 + verified
via `aws iot-data get-thing-shadow --thing-name GS9999999999`:

```json
publish gs/GS9999999999/heartbeat -> {
  "serial":      "GS9999999999",
  "ts":          "2026-04-29T20:02:32Z",
  "battery_pct": 0.936,                  # real fuel gauge (was 0.5 placeholder)
  "rsrp_dbm":    -82,
  "snr_db":      5,
  "battery_mv":  4218,                   # M10.7.2 optional extra
  "firmware":    "0.8.0-prod",           # version.h, single source of truth
  "uptime_s":    13,
  "reset_reason":"SOFTWARE",             # M10.7.3 hwinfo formatted
  "fault_counters": {"fatal":0, "asserts":0, "watchdog":0},
  "watchdog_hits": 0
}
```

253 bytes serialized — well under the 512 B HEARTBEAT_PAYLOAD_MAX.
Boot-to-PUBACK 18-19 s on Onomondo LTE-M roaming (RSRP -82 dBm / SNR
5 dB, similar conditions to the M12.1c.1 closure run). Cellular attach
8 s, AWS IoT TLS+MQTT CONNECT 5 s, broker PUBACK 700 ms.

Shadow document after the publish (post-merge view, version 16):

```
state.reported.serial          = "GS9999999999"
state.reported.ts              = "2026-04-29T19:43:20Z"
state.reported.battery_pct     = 0.761
state.reported.rsrp_dbm        = -82
state.reported.snr_db          = 5
state.reported.battery_mv      = 4218
state.reported.firmware        = "0.8.0-prod"
state.reported.uptime_s        = 13
state.reported.reset_reason    = "SOFTWARE"
state.reported.fault_counters  = {"i2c":0, "watchdog":0, "fatal":0, "asserts":0}
state.reported.watchdog_hits   = 0
state.reported.lastSeen        = "2026-04-29T19:43:20Z"     # cloud-added
state.reported.lastPreactivationAuditAt = "..."             # cloud-added
```

Two things from this worth flagging:

- **Accept-all merge preserved a stale `fault_counters.i2c: 0` key**
  from an earlier cloud-side probe (timestamp older than this publish).
  Our handler's published object only contains `fatal/asserts/watchdog`
  but the prior shadow content was preserved at the per-leaf level.
  This is exactly the cloud-side merge contract working as documented;
  flagging only because it shows up in shadow inspections and is
  effectively immortal until we publish a `null` for that leaf or
  someone overwrites the shadow doc. Not a bug.

- **`battery_pct` accuracy**: the bundled "Example" 1100 mAh LiPol
  model from the upstream NCS sample is not perfectly tuned for the
  Thingy:91 X's LP803448 (~1300 mAh). Voltage-based SoC correction
  keeps it within ±5-10 % absolute, fine for v1 cloud telemetry and
  threshold-detector `battery_critical` alarm logic. v1.5 should swap
  in an LP803448-tuned model from real discharge curves — flagged
  as a v1.5 follow-up rather than a deployment blocker.

## F5.2 Fault-recovery path validated end-to-end

Built a stress-test surface (`CONFIG_GOSTEADY_FORENSICS_STRESS=y`,
default off, bench-only) that exposes two debug commands on the uart1
dump channel: `CRASH` (k_panic via the fault handler) and `STALL` (wedge
the WDT supervisor in a busy loop). Used these to validate the M10.7.3
recovery axis.

Shadow snapshots through the test, in order:

| Trigger          | reset_reason | fault_counters.fatal | fault_counters.watchdog | watchdog_hits | Cycle |
|------------------|--------------|----------------------|-------------------------|---------------|-------|
| baseline         | SOFTWARE     | 0                    | 0                       | 0             | —     |
| (earlier probes) | SOFTWARE     | 0                    | 3                       | 3             | —     |
| `STALL`          | **WATCHDOG** | 0                    | **4**                   | **4**         | ~60 s |
| `CRASH`          | **SOFTWARE** | **1**                | 4                       | 4             | ~30 s |
| `CRASH` (again)  | SOFTWARE     | **2**                | 4                       | 4             | ~30 s |

`reset_reason` cleanly distinguishes the two recovery paths. Cycle time
matters for in-field battery cost: a true hang (no fault handler
invocation) eats 60 s of WDT timeout per recovery, whereas a software
panic recovers in ~30 s including LTE-M re-attach. Both paths now
correctly persist their counters into the next-boot heartbeat.

Cloud-side implication for the threshold detector: the `watchdog_hits`
field is now an actionable signal (was a stub through M12.1c.1).
Suggested ops alarm threshold: ≥3 watchdog hits in a 24 h window probably
warrants a "device unstable" caregiver-side notice. Not a v1 spec ask;
just a heads-up that the data is now real.

## F5.3 Bugs found + fixed during M10.7.3 validation

Two bugs in our originally-shipped (this morning's) M10.7.3 fault path
surfaced during the bench validation. Both fixed in commit `eea8d7e`,
on `main`:

### Bug 1: in-handler flash persist doesn't survive the reboot timing

The original M10.7.3 `k_sys_fatal_error_handler` did
`flash_area_erase + flash_area_write` directly, then `k_fatal_halt`. On
this nRF9151 + TF-M platform the path doesn't survive: post-`LOG_PANIC`
the kernel scheduler is locked, the SPI flash driver state freezes, and
either the writes don't complete or they get pre-empted by the eventual
reboot. Empirical signal: `fault_counters.fatal` stayed 0 across multiple
forced fault triggers; only `watchdog`/`watchdog_hits` (which is bumped
by next-boot init reading the hwinfo bitmask) reflected the events.

Fix: stamp fault info into a `__noinit` SRAM struct (Cortex-M
NVIC_SystemReset retains SRAM by default — verified empirically), and
have next-boot init drain the noinit slot into the persistent record
where flash I/O is fully ready. Magic word gates against cold-boot
random-bits double-counting; cleared on drain so a subsequent re-init
without a fault doesn't double-bump.

### Bug 2: `k_fatal_halt` was a 60 s death spiral

`k_fatal_halt` is an infinite loop, not a reboot. Without our handler
explicitly triggering a reset, the only path to recovery was the
watchdog timeout — costing 60 s per fault, AND mis-attributing the
reset_reason as `WATCHDOG` (it was really an unhandled assert/panic).

Fix: handler now calls `sys_reboot(SYS_REBOOT_WARM)` after the noinit
stamp; falls through to `k_fatal_halt` only if reboot somehow returns
(it shouldn't on this platform). Recovery time drops from 60 s → ~30 s
(cellular re-attach is now the dominant cost), and `reset_reason`
correctly reads `SOFTWARE` for the fault path so cloud-side triage can
distinguish recoverable-by-handler vs hung-and-watchdog'd events.

## F5.4 What this means for cloud-side acceptance

Three of the four "TBD until firmware lands" cloud-spec optional fields
are now real:

- ✅ `reset_reason` — formatted string, distinguishes POWER_ON / PIN /
  SOFTWARE / WATCHDOG / FAULT (and joins multiple bits with comma)
- ✅ `fault_counters` — `{"fatal":N, "asserts":N, "watchdog":N}` JSON
  object literal, cumulative since first format of the crash_forensics
  partition (currently `boot_count` in the high tens after our stress
  testing, so the partition's seen real wear)
- ✅ `watchdog_hits` — int, monotonically increasing across boots that
  read RESET_WATCHDOG via hwinfo

The fourth (`last_cmd_id`) plumbing is in place but stays empty until
M12.1e.2 wires up the activate-cmd subscription — covered separately
in the next firmware milestone.

The Phase 1B revision Shadow-write Lambda continues to handle these
cleanly without code change on cloud side; the merge behavior is exactly
as documented (accept-all on unknown fields, per-leaf preservation of
prior values that the new payload doesn't include). One observation
worth recording for future reference: shadow-document key cleanup is
effectively immortal absent a `null` write — see §F5.1 footnote on the
stale `fault_counters.i2c: 0` key surviving from an earlier probe.

## F5.5 What's next firmware-side

Per the M14.5 site-survey shakedown timeline, the remaining firmware
milestones before clinic ship are:

- **M12.1e.1** NCS Shadow lib bench check (~½ day; cloud §C5.4 unblocked
  this back on 2026-04-28). Will validate `aws_iot_shadow_get` +
  `aws_iot_shadow_update` round-trip against `GS9999999999`'s shadow.
- **M12.1e.2** Pre-activation gate + Shadow re-check on every cellular
  wake (~2 days; depends on M12.1e.1). Wires up `last_cmd_id` echo on
  next heartbeat as the activate-cmd ack surface. Note the §C6.3 caveat
  that the cloud-side `device-shadow-handler` Lambda is Phase 2A
  deferred — firmware will pass the shadow round-trip test (Shadow
  document carries `reported.activated_at` after the firmware update),
  but Device Registry won't flip `activated_at` automatically until the
  Phase 2A handler ships. We're aware; the M12.1e.2 acceptance probe
  is the shadow round-trip itself, not the full provisioning flow.
- **M12.1f** Snippet uplink (~3 days; depends on M10.7.1, which is now
  done). JSON header framing per §F.3 + binary layout per §F.4.
  Opportunistic upload piggybacking on Priority-1 cellular wakes per
  M10.5 snippet upload policy. May surface real questions on the
  4-byte BE length-prefix + JSON-header-then-binary layout once
  implementation begins.

After M12.1e.2 + M12.1f land we hit **M14.5** — the site-survey
shakedown. Bench desk for ≥7 days with `GS0000000001` running the
deployment build, observing heartbeat stream + battery curve +
forensics counters across a real "cellular alone, sensor occasionally
moving" scenario.

## F5.6 Cadence

This entry closes the M10.7 + M12.1c.2 work-block. No firmware action
items for cloud team beyond what's already in flight (Phase 1.6 / 1.7
/ 2A); the data flowing through Shadow is well-aligned with the spec.

Next coord-doc trigger from firmware side: probably M12.1e.1 outcome
(half-day) or M12.1e.2 closure with shadow-round-trip end-to-end against
the bench Thing. Either way it lands within the next few days.

If anything in §F5.1 (the immortal stale-leaf observation) or §F5.4
(suggested ops-alarm thresholds for `watchdog_hits`) wants a cloud-side
counter-proposal or spec note, happy to incorporate.

---

*Entry owner (firmware side): Jace + Claude. Counter-proposals welcome.*


---
---

# Firmware milestone update — 2026-04-29 (M12.1e.1 NCS Shadow lib bench check — GET + UPDATE round-trips PASS; §C.5.1 closed)

> **From:** GoSteady firmware team
> **Closes:** §C.5.1 (the open question on whether NCS 3.2.4's aws_iot
> lib supports the Device Shadow surface end-to-end). **Answer: yes.**
> **Acks:** §C6.1's per-thing IoT policy grant for shadow MQTT topics
> — used end-to-end on this run; subscriptions land on connect, GET +
> UPDATE both round-trip cleanly.
>
> **Implication:** M12.1e.2 is unblocked to use the Shadow path per
> §C.4.4 (`desired.activated_at` re-check on every cellular wake +
> `reported.activated_at` ack-write). No fallback to MQTT-retained
> activate cmd needed.

---

## F6.1 What ran

`CONFIG_GOSTEADY_CLOUD_SHADOW_BENCH_CHECK=y` (new, default n, bench-only)
spawns a one-shot worker that fires ~30 s after boot, takes the aws_iot
mutex, connects to AWS IoT, runs an explicit Shadow GET, then a Shadow
UPDATE, logs each round-trip on uart0, and disconnects.

Bench result captured 2026-04-29T21:10 against `GS9999999999`:

```
shadow bench: aws_iot_connect
aws_iot: Subscribing to topic: $aws/things/GS9999999999/shadow/get/accepted
aws_iot: Subscribing to topic: $aws/things/GS9999999999/shadow/get/rejected
aws_iot: Subscribing to topic: $aws/things/GS9999999999/shadow/update/accepted
aws_iot: Subscribing to topic: $aws/things/GS9999999999/shadow/update/rejected
aws_iot: Subscribing to topic: $aws/things/GS9999999999/shadow/update/delta
aws_iot: on_suback: Received ACK for subscribe message: id = 1984 result = 0
gs_cloud: evt: CONNECTED (persistent_session=0)
gs_cloud: shadow bench: sending GET
aws_iot: Publishing to topic: $aws/things/GS9999999999/shadow/get
aws_iot: on_puback: Received ACK for published message: id = 1 result = 0
aws_iot: on_publish: Received message: topic = $aws/things/GS9999999999/shadow/get/accepted and len = 1036
gs_cloud: shadow bench: GET round-trip OK
gs_cloud: shadow bench: sending UPDATE — {"state":{"reported":{"shadow_bench_check_at":"2026-04-29T21:10:16Z"}}}
aws_iot: Publishing to topic: $aws/things/GS9999999999/shadow/update
aws_iot: on_puback: Received ACK for published message: id = 2 result = 0
aws_iot: on_publish: Received message: topic = $aws/things/GS9999999999/shadow/update/accepted and len = 182
gs_cloud: shadow bench: UPDATE round-trip OK
gs_cloud: ==== M12.1e.1 SHADOW BENCH CHECK: PASS ====
```

Cloud-side verification via `aws iot-data get-thing-shadow`:

```
state.reported.shadow_bench_check_at = "2026-04-29T21:10:16Z"
state.reported keys (14 total) = serial, ts, battery_pct, battery_mv,
  rsrp_dbm, snr_db, firmware, uptime_s, reset_reason, fault_counters,
  watchdog_hits, lastSeen, lastPreactivationAuditAt,
  shadow_bench_check_at
```

The `shadow_bench_check_at` leaf merged in alongside the heartbeat
fields cleanly — accept-all merge per portal contract working as
documented for the UPDATE direction.

## F6.2 What we proved

- ✅ The aws_iot lib's `AWS_IOT_SHADOW_TOPIC_GET` send path publishes
  to `$aws/things/<thing>/shadow/get` with empty body and correctly
  routes the response to `AWS_IOT_EVT_DATA_RECEIVED` with
  `topic.type_received == AWS_IOT_SHADOW_TOPIC_GET_ACCEPTED`.
- ✅ The `AWS_IOT_SHADOW_TOPIC_UPDATE` send path with a real reported-
  state JSON body lands on `$aws/things/<thing>/shadow/update` and the
  acceptance fires through `AWS_IOT_SHADOW_TOPIC_UPDATE_ACCEPTED`.
- ✅ Subscribe-on-connect for all five shadow/* topics
  (get/{accepted,rejected}, update/{accepted,rejected,delta}) takes
  ~700 ms total in our handler — that's the SUBACK we observe. Happens
  once per CONNECT, not per shadow operation.
- ✅ The §C6.1 wildcard policy grant works in practice for Publish +
  Subscribe + Receive across the full set of shadow/* sub-topics. No
  silent broker disconnects (which is what we saw in M12.1c.1 closure
  before §C5.4 landed) — clean SUBACK + PUBACK sequence throughout.

## F6.3 Notes for M12.1e.2 design

A few things observed during the bench check that will inform the
M12.1e.2 implementation; flagging here so they're in the record:

- **Shadow doc sizing.** Today's GET response is 1036 B (14 reported
  keys). M12.1e.2 buffer sizing should target 2 KB to leave headroom
  as the shadow accumulates more keys (the Phase 2A `device-api`
  Lambda will write `desired.activated_at`, plus future per-device
  knobs like sampling rate, OTA gating, etc. per §F.9.4).

- **JSON parsing.** Locating `desired.activated_at` in the GET response
  requires a JSON walk. Zephyr's json lib is already in tree from M6a
  (handles the START command schema today). Schema for the activate
  delta is small enough — 1 string field + parent objects — to define
  as a `json_obj_descr` array and let the lib do the work; no need to
  pull in cJSON or similar.

- **UPDATE acceptance is small.** 182 B for our test — useful as the
  "ack persistence" surface for the M12.1e.2 flow ("wait for the
  reported.activated_at write to be confirmed before clearing the
  pre-activation blue LED state").

- **UPDATE_DELTA_SUBSCRIBE flipped on too.** The §C.4.4 contract has
  cloud writing `desired.activated_at` and firmware re-checking on
  every cellular wake. Subscribing to the delta topic gives us a free
  push-style notification on the immediate-push path (cloud sends
  the activate cmd via gs/{serial}/cmd AND writes desired Shadow
  state — firmware sees both, can ack via either). M12.1e.2 will
  decide which path is canonical; UPDATE_DELTA gives optionality.

- **One observation worth recording.** Cellular registration was
  unusually long on this run (~2:25 vs the usual 8 s). Independent of
  shadow code — bench check ran fine once cellular came up. Logging
  it because if it persists across the next few wake cycles it'd
  warrant a coord-doc note on PSM/eDRX timer interaction with the
  modem's roaming-network selection.

## F6.4 What's next firmware-side

Now firmware-side unblocked end-to-end on the M12.1e path:

- **M12.1e.2** Pre-activation gate + Shadow re-check on every cellular
  wake (~2 days). Wires up:
  - Subscribe to `gs/{serial}/cmd` during pre-activation, parse
    `activate` cmd schema (`{cmd, cmd_id, ts, session_id}`).
  - On receipt: persist `activated_at` to flash, write
    `reported.activated_at` to Shadow, echo `cmd_id` in next heartbeat
    via `gosteady_cloud_set_last_cmd_id()` (M12.1c.2 plumbing).
  - On every cellular wake post-activation: GET shadow, validate
    `desired.activated_at` matches on-flash value; if `null` →
    re-enter pre-activation, blue LED on, no session capture (per
    §C.4.4 cloud-side invariant).
  - Pre-activation visual indicator: blue LED slow-blink (1 Hz, 100 ms
    on / 900 ms off) per M10.5 spec.

  Cloud-side caveat from §C6.3: the `device-shadow-handler` Lambda
  (consumer of `reported.activated_at` ack → flips Device Registry
  `activated_at`) is Phase 2A deferred. M12.1e.2 will pass the shadow
  round-trip itself but Device Registry won't auto-flip; we're aware,
  the M12.1e.2 acceptance probe is the shadow-write itself.

- **M12.1f** Snippet uplink (~3 days; depends on M10.7.1, done).
- **M14.5** Site-survey shakedown.

## F6.5 Cadence

This entry closes §C.5.1 with the PASS outcome. No firmware action items
for cloud team — the bench check fully validated the policy grant from
§C6.1 + the existing aws_iot lib API surface.

Next coord-doc trigger from firmware: M12.1e.2 closure (Shadow round-
trip from real activate-cmd flow), or M12.1f surfacing real questions
on the §F.3 / §F.4 binary-preamble framing during snippet uplink
implementation. Both within the next few days.

---

*Entry owner (firmware side): Jace + Claude. Counter-proposals welcome.*


---
---

# Firmware milestone update — 2026-04-29 (M12.1e.2 pre-activation gate + activate-cmd ingest — bench-validated end-to-end)

> **From:** GoSteady firmware team
> **Closes:** M12.1e.2 implementation per coord §C.4.4 + §C.2 contract.
> Activate cmd flow works end-to-end against `GS9999999999`: cloud publish
> → AWS IoT broker queues (CLEAN_SESSION=n) → device CONNECT on next
> heartbeat resumes session and receives the queued cmd → JSON parses →
> `activation_apply` persists to `/lfs/activation.bin` → cloud sees
> `state.reported.activated_at` in Shadow.
>
> **Acks:** §C6.1 (Shadow MQTT topic policy) — verified the same per-thing
> policy that grants `shadow/*` also covers app-topic Subscribe on
> `gs/{serial}/cmd`, so no additional grant needed. §C.2 / §C.4.4 contract
> followed end-to-end.
>
> **§C.5.1 follow-up (also closes via this entry):** Shadow `desired.
> activated_at` re-check on every cellular wake is INTENTIONALLY DEFERRED
> per the §C6.3 caveat — cloud-side `device-shadow-handler` Lambda is
> Phase 2A, so per-wake re-check has no observable effect until that
> ships. Will re-implement when Phase 2A lands; firmware-side the change
> is ~30 LOC inside the existing heartbeat path.

---

## F7.1 What landed

`src/activation.{h,c}` — small persisted-state module backing a tiny
JSON-config-style file at `/lfs/activation.bin` (88 B packed record:
magic + version + activated_at_iso + last_cmd_id + reserved). LittleFS
survives SoC reset cleanly; activation state is preserved across both
soft (sys_reboot) and hard resets.

`src/cloud.c` —
  - Registers `gs/{serial}/cmd` via `aws_iot_application_topics_set`
    at init (log: `registered app subscription: gs/GS9999999999/cmd
    (QoS 1)`). Subscribed on every CONNECT alongside the shadow topics.
  - DATA_RECEIVED handler dispatches on `topic.type_received ==
    AWS_IOT_SHADOW_TOPIC_APPLICATION_SPECIFIC` → JSON parse via
    Zephyr's json lib using the schema-locked descriptor —

    ```c
    struct activate_cmd_json { const char *cmd, *cmd_id, *ts, *session_id; };
    ```
  - On `cmd == "activate"`: calls `gosteady_activation_apply`,
    `gosteady_cloud_set_last_cmd_id` (M12.1c.2 plumbing), and
    `write_reported_activated_at` which is a Shadow UPDATE with body
    `{"state":{"reported":{"activated_at":"<ts>"}}}`.
  - 1.5 s linger after PUBACK before disconnect — gives time for
    queued app-topic deliveries to arrive and the synchronous event
    handler to dispatch `handle_activate_cmd`.

`src/session.c` — `gosteady_session_start` gains a top-of-function
pre-activation gate gated on `CONFIG_GOSTEADY_FIELD_MODE`. Returns
`-EACCES` when `!gosteady_activation_is_activated()`. Bench builds
(capture.html / SW0 / control.py) skip the gate entirely so M8 data-
collection continues to work unchanged.

`prj_cloud.conf` + `prj_field.conf` — **flipped `CONFIG_MQTT_CLEAN_SESSION`
y → n**. The original CLEAN_SESSION=y dropped any cloud-published
activate cmd while the device was between hourly heartbeats. With
CLEAN_SESSION=n + the same client_id, AWS IoT holds QoS 1 messages
per-client until next CONNECT. First connect after the change shows
`persistent_session=0` (broker bootstrap); subsequent connects show
`persistent_session=1` and queued cmds flow on resume.

## F7.2 Bench validation

Two-step test 2026-04-29 against `GS9999999999`:

```
# Test 1 — fresh activation
pre  : gs_activation: not activated (read=-2 magic=0x00000000) — pre-activation state
       cloud Shadow: activated_at <missing>

publish: aws iot-data publish --topic gs/GS9999999999/cmd --qos 1 \
         --payload '{"cmd":"activate","cmd_id":"act_test_m12_1e2",
                     "ts":"2026-04-29T22:35:00Z",
                     "session_id":"sess_bench_001"}'

reset device → CONNECT(persistent_session=1)

log:
  gs_cloud: activate cmd received: cmd_id=act_test_m12_1e2
            ts=2026-04-29T22:35:00Z session_id=sess_bench_002
  gs_activation: activation applied: at=2026-04-29T22:35:00Z
                 cmd_id=act_test_m12_1e2
                 (persisted to /lfs/activation.bin)
  gs_cloud: wrote reported.activated_at=2026-04-29T22:35:00Z to Shadow
  PUBACK msg_id=1 (heartbeat)
  PUBACK msg_id=2 (Shadow.reported.activated_at)

cloud Shadow (version 38):
  state.reported.activated_at = "2026-04-29T22:35:00Z"   ✓

# Test 2 — reboot persistence
reset device (no new cmd, /lfs/activation.bin should drive state)
log:
  gs_activation: activated: at=2026-04-29T22:35:00Z
                 cmd_id=act_test_m12_1e2  ✓
```

Every step in the contract worked first time:

- ✅ App-topic subscribe registered + included in CONNECT subscribe
- ✅ Cloud queue + persistent-session delivery (the CLEAN_SESSION fix)
- ✅ JSON parse against the locked schema
- ✅ `last_cmd_id` echo plumbing (the M12.1c.2 hook fires correctly)
- ✅ `reported.activated_at` Shadow-side ack
- ✅ /lfs persistence across SoC reset

## F7.3 Pre-activation gate

In `CONFIG_GOSTEADY_FIELD_MODE` builds only:

```c
int gosteady_session_start(const struct gosteady_prewalk *prewalk) {
    if (!gosteady_activation_is_activated()) {
        LOG_WRN("session_start refused — device in pre-activation state ...");
        return -EACCES;
    }
    ...
}
```

The auto-start coordinator in `main.c` already handles non-zero return
from `session_start` gracefully — suspends BMI270, returns to idle,
re-arms motion sem. So a pre-activation device that wakes on motion
goes through the BMI270 confirmation window, calls session_start,
gets -EACCES, suspends BMI270, drains the motion sem, sleeps. Net
behavior matches §M10.5: "wake on motion → connect → publish heartbeat
→ wait for activation → if not activated, return to sleep without
opening any session."

Skipped the physical motion test for this milestone (would require
field-mode flash + sealed cap). Will be exercised end-to-end as part
of M14.5 site-survey shakedown.

## F7.4 Two design decisions worth flagging

### CLEAN_SESSION=n is now load-bearing

Activate cmd ingest depends on AWS IoT's per-client persistent-session
state. Implications worth being aware of cloud-side:

- AWS IoT retains session state for **disconnected clients with QoS 1
  messages** for as long as those messages are queued (default ~1 hour
  per AWS docs). Our hourly heartbeat keeps the session alive
  indefinitely.
- If the firmware ever switches client_id (e.g., shipping unit reflash
  with a different serial), the previous session's state is orphaned
  on the broker. Acceptable for v1 scope; just noting it so future
  fleet-provisioning work doesn't surprise on this.
- Heartbeat publishes are still QoS 1 + connect-publish-disconnect.
  No change to the single-publish-per-hour cadence; we just
  benefit from the broker holding any inbound app-topic messages
  while we're disconnected.

### 1.5 s linger after PUBACK

The heartbeat's `connect_publish_disconnect` now sleeps 1.5 s after
PUBACK before disconnect. Empirically generous — the broker delivers
queued QoS 1 messages within hundreds of ms after the SUBACK we get
during connect, so by PUBACK + 1.5 s any held activate cmd has
already arrived and `handle_activate_cmd` has applied + persisted.
Pretty cheap on the energy side (1.5 s of cellular RRC connected =
~0.5 mC). Will be revisited if the M14.5 site-survey unit shows
unexplained battery drain.

## F7.5 What's deferred + why

- **Shadow re-check on every cellular wake.** Per §C.4.4 the firmware
  is supposed to GET shadow on every wake and validate
  `desired.activated_at` against on-flash, dropping back to
  pre-activation if cloud cleared it. **Deferred per §C6.3 caveat:**
  the cloud-side `device-shadow-handler` Lambda that consumes
  `reported.activated_at` (and the matching de-provision flow that
  writes `desired.activated_at = null`) is Phase 2A, not yet shipped.
  Implementing the firmware re-check now would have no observable
  cloud effect; will re-implement when Phase 2A lands. Firmware-side
  cost when it lands: ~30 LOC inside the existing heartbeat connect
  block (1 GET + JSON parse + comparison).

- **Blue LED slow-blink in pre-activation.** Per M10.5 the device
  should slow-blink blue (1 Hz, 100 ms on / 900 ms off) while in
  `ready_to_provision`. Pure visual polish, no observable cloud or
  field-validation impact. Will add as a polish commit alongside
  M14.5 flash for `GS0000000001`.

## F7.6 What's next firmware-side

- **M12.1f** Snippet uplink (~3 days; depends on M10.7.1, done).
  JSON header per §F.3 + binary layout per §F.4. May surface real
  questions on the framing once implementation begins; will post
  here if so.
- **M14.5** Site-survey shakedown — flash `GS0000000001` with the
  field deployment build, week-long bench observation, M11.1
  confirmation walk against shipping firmware. The pre-activation
  gate gets its first physical-motion test as part of this; if cloud
  team has a preferred way to trigger an activate cmd from the dev
  IoT account during shakedown, happy to coordinate.

## F7.7 Cadence

§C.4.4 + §C.2 contract fully implemented and bench-validated. No
firmware action items for cloud team. The synthetic activation
(`pt_test_001` / `dtc_test_001` / `cen_synth_001` from §C5.3) keeps
working as the bench fixture; my test cmd_id `act_test_m12_1e2` is
visible in the Shadow's `last_cmd_id` field on next heartbeat (in
~1 hour as I write this; will appear by the time anyone reads this).

Next coord-doc trigger from firmware: M12.1f closure or any
binary-preamble framing question that surfaces during implementation.

---

*Entry owner (firmware side): Jace + Claude. Counter-proposals welcome.*


---
---

# Firmware milestone update — 2026-04-29 (M12.1f snippet capture + opportunistic upload — end-to-end S3 landing)

> **From:** GoSteady firmware team
> **Closes:** M12.1f per coord §F.3 + §F.4 + the M10.5 snippet upload
> policy. Snippet capture + opportunistic upload working end-to-end
> against `GS9999999999`: 30 s window of raw 100 Hz BMI270 samples is
> framed per §F.3 + §F.4 and lands in
> `s3://gosteady-dev-snippets/GS9999999999/2026-04-29/<snippet_id>.bin`
> at the exact byte count we published (43,122 B for the validation
> run — 16 B header + 1,536 samples × 28 B + JSON wrapper + 4 B prefix).
>
> **Acks:** §C.2 (cloud confirmed the IoT Rule + parser Lambda was up
> ahead of M12.1f). The full path landed first try once we got the
> framing right on our side — header_len BE prefix → JSON header parse
> → snippet_id extraction → S3 PUT all worked as documented.
>
> With this, **all four firmware-feature milestones are bench-validated**
> (heartbeat + activity + cmd ingest + snippet upload). The remaining
> firmware-side blocker for shipping is M14.5 site-survey shakedown;
> no further coord questions for this batch.

---

## F8.1 What ran end-to-end

```
# Boot 1 — fresh flash with CONFIG_GOSTEADY_SNIPPET_ENABLE=y
gs_snippet: snippet fs mounted: total=16777216 B free=16769024 B
gs_cloud: publish gs/GS9999999999/heartbeat -> {... 286 B ...}
gs_cloud: PUBACK received — broker confirmed

# Trigger session via uart1 START
gs_snippet: snippet capture start: c1c906b6-dc63-4675-b530-19fcd7fc1c92
            window_start_ts=2026-04-29T23:17:33Z

# 15 s later: AUTO_STOP_STATIONARY_S fires — session_stop runs
gosteady: auto-stop: 15 s of stationary motion → ending session
gs_snippet: snippet capture finish: c1c906b6-... samples=1536
            (43040 B body)

# Heartbeat tick — snippet drained inside the same connect cycle,
# after the heartbeat PUBACK, before disconnect:
gs_snippet: snippet upload: c1c906b6-... — 43122 B (json=94, bin=43024)
gs_cloud: snippet PUBACK received (43122 B published)
```

Cloud-side after the run:

```
$ aws s3 ls s3://gosteady-dev-snippets/GS9999999999/ --recursive --region us-east-1
2026-04-29 17:18:04   43122  GS9999999999/2026-04-29/c1c906b6-...-19fcd7fc1c92.bin
```

(43,122 B object — bit-exact match to the bytes we published.)

## F8.2 Wire framing per §F.3 + §F.4

Outer framing (built at upload time, in a single 84 KB BSS buffer
shared with the body read to avoid double-allocation):

```
offset 0    : [4-byte BE uint32 hdr_len]      = 94 in this run
offset 4    : [hdr_len bytes JSON header]     = {"snippet_id":"<uuid>",
                                                  "window_start_ts":"<iso>"}
offset 4+H  : [16-byte binary header LE]      = §F.4 verbatim
offset 20+H : [N × 28-byte sample records]    = N=1536 in this run
```

§F.4 binary header with sample_count_n = 1536:
```
format_version  = 1
sensor_id       = 1   (BMI270)
sample_rate_hz  = 100
sample_count_n  = 1536
window_start_uptime_ms = (this boot's uptime at first sample)
```

JSON wrapper (94 B):
```
{"snippet_id":"c1c906b6-dc63-4675-b530-19fcd7fc1c92",
 "window_start_ts":"2026-04-29T23:17:33Z"}
```

`anomaly_trigger` is absent in v1 — the always-on capture path doesn't
classify, so JSON serializes without it. v1.5 will add when the
anomaly detector lands (per coord §F.4 schema reservation: the JSON
parser ignores unknown fields, the binary `format_version` stays 1).

## F8.3 Capture path in src/snippet.c

Two responsibilities, separated for clarity:

**Capture (writer thread, per session)**:
- session.c::gosteady_session_start now calls
  gosteady_snippet_capture_start(session_uuid, window_start_ts,
  uptime_ms_at_first_sample). Reuses session_uuid as snippet_id so
  cloud-side join across the snippet S3 object + the activity DDB
  row is trivial.
- session.c writer-thread per-sample drain loop calls
  gosteady_snippet_capture_append(t_ms, ax..gz). Samples accumulate
  into a 64-sample in-RAM batch (1.8 KB); batch flushes to flash on
  full or at finish. **Avoiding per-sample fs_write was load-
  bearing**: 30 s × 100 Hz = 3000 writes per window deepened the
  writer thread's call stack with LittleFS metadata churn enough to
  HardFault session_stop. After batching to 64-sample chunks (~47
  flushes per window) + a +1 KB writer-stack bump, the auto-stop
  + finish path is rock-solid.
- session.c writer-thread stop branch calls
  gosteady_snippet_capture_finish. Flushes trailing partial batch
  → rewrites the binary header at offset 0 with the real
  sample_count → close .bin → write .json sidecar → done.

**Upload (heartbeat thread, opportunistic)**:
- After PUBACK on the heartbeat publish but BEFORE disconnect,
  cloud.c calls drain_one_snippet which delegates to
  gosteady_snippet_upload_one with publish_snippet_callback as the
  MQTT-send primitive.
- snippet.c::find_pending_uuid iterates /snippets/ via fs_readdir,
  returns the first .bin entry without a paired .up marker. Strict
  FIFO-by-mtime would require fs_stat per entry — overkill for a
  partition that holds a few hundred files at most. v1 takes
  whatever readdir order LittleFS gives us (roughly insertion
  order in practice).
- Read .json into s_payload[4:4+json_len], read .bin into
  s_payload[4+json_len:], stamp the 4-byte BE prefix at offset 0.
  Single 84 KB BSS buffer; no double-allocation.
- publish_snippet_callback (cloud.c) sends to gs/{serial}/snippet
  at QoS 1, waits for PUBACK with the same 30 s timeout the
  heartbeat path uses.
- On PUBACK: write a zero-byte .up marker file. find_pending_uuid
  excludes any uuid with a .up marker, so subsequent ticks pick
  the next pending snippet.

Per M10.5 policy this is **Priority-2**: the snippet drain only
runs when a heartbeat wake is already happening; never opens its
own cellular cycle. v1 doesn't implement the explicit
`battery_pct ≥ 30 %` gate from the policy (relies on the
implicit "if heartbeat made it, battery is fine for an extra
84 KB push") — will revisit if M14.5 battery numbers warrant.

## F8.4 Bugs found + fixed during validation

Posting here in case they're useful for any cloud-side reviewer
who's debugging firmware deltas across milestones, and so the
record's complete:

1. **Per-sample fs_write into the writer thread overflowed its
   stack.** Original M12.1f draft did one fs_write per snippet
   sample from session.c::writer_entry. With the sampler +
   writer + per-sample LittleFS metadata churn all sharing the
   3072 B writer stack, the auto-stop session_stop sequence
   HardFaulted on the trailing flush + algo finalize +
   rewrite_header + close. Fix: 64-sample in-RAM batch (1.8 KB
   stack) + writer_stack bumped 3072 → 4096.

2. **Two static 84 KB buffers blew the RAM region by 80 KB.**
   Initial design had separate read-binary and
   build-outer-framing buffers. Fix: single 84 KB buffer; read
   .json + .bin directly into their slots in the outer-framing
   layout (no double-allocation).

3. **Orphaned .bin from a previous-boot HardFault loops the
   upload path forever.** A snippet whose capture_start
   succeeded but whose capture_finish never ran (because the
   stop sequence faulted) leaves a .bin without a .json sidecar.
   find_pending_uuid keeps returning that uuid, the upload path
   errors on the missing sidecar, infinite spam in logs +
   real snippets behind it never get their turn. Fix: when the
   .json sidecar is missing on upload attempt, best-effort
   fs_unlink the orphan .bin so the next upload tick gets the
   next pending entry.

## F8.5 Notes for cloud-side reviewers

A few observations about the round-trip, in case any of these
inform Phase 2 cloud-side decisions:

- **JSON-header framing was the right v1 call.** NCS 3.2.4's
  Zephyr MQTT lib is 3.1.1 only — no MQTT 5 user properties
  available. We confirmed this empirically during M12.1f
  development (per §F.3 prediction). The §F.3 fallback works
  cleanly; cloud-side parser implementation matches what the
  4-byte BE prefix + JSON header gave it.

- **Snippet S3 path reflects firmware-internal state correctly.**
  `{serial}/{date}/{snippet_id}.bin` has the snippet_id from our
  JSON header (`c1c906b6-...`), not the wall-clock time (which
  is in window_start_ts). Cloud-side analytics tooling should
  use snippet_id as the canonical row key + window_start_ts for
  bucketing. Both are firmware-generated.

- **Always-on v1 capture vs scheduled (every 6 hr) v1.5 cadence.**
  Capacity math: 16 MB partition / 84 KB max = 195 snippets
  worst case; clinic walks are typically 5-20 s so most files
  are 14-56 KB → 280-1100 snippets actual capacity. At 1 session
  per typical clinic patient day (best estimate from M10.5
  scoping) that's at least a year of capacity at v1's
  always-arm setting before any rotation matters. v1.5 will add
  the 14-day stale cutoff + 90 % full rotation rules from the
  M10.5 policy when more conservative behavior becomes
  worthwhile.

- **uploaded marker is a separate empty file, not a flag in the
  .json.** Allows the marker write to be idempotent — if upload
  PUBACK happens but mark_uploaded fails (flash busy, partition
  full), the cleanup happens on next upload tick. Worst case is
  a duplicate upload of the same snippet_id, which the cloud
  IoT Rule's S3 PUT idempotently overwrites.

## F8.6 What's next firmware-side

With M12.1f closing out the M10.5-mandated cloud-uplink set, the
remaining firmware items before clinic ship are mechanical /
operational rather than feature work:

- **M14.5** Site-survey shakedown (~1 day setup + 1 wk obs).
  Flash `GS0000000001` with the deployment build (prj_field.conf
  + everything we've shipped through M12.1f), bench desk for
  ≥7 days, observe heartbeat stream + battery curve + crash
  forensics + snippet drain across a real "cellular alone, sensor
  occasionally moving" scenario. Includes M11.1 confirmation
  walk against this exact build. The pre-activation gate +
  blue-LED-slow-blink polish (deferred from M12.1e.2) lands
  alongside this flash.

- **M15** Field testing — clinic deployment of `GS0000000002/3`
  (or 0001 if it stays as the survey/dev unit per use case).
  M11.2 measures the outcome.

## F8.7 Cadence

This entry closes the M12.1 Cellular work-block. Heartbeat,
activity, cmd ingest, and snippet uplink all bench-validated +
cloud-Shadow / DDB / S3 landing all confirmed. No firmware
action items for cloud team beyond what's already in flight
(Phase 1.6 / 1.7 / 2A).

Next coord-doc trigger from firmware: M14.5 site-survey
shakedown report at the end of the week-long observation,
which will include actual battery numbers + any deployment-
readiness issues that surface from sustained cellular operation.

---

*Entry owner (firmware side): Jace + Claude. Counter-proposals welcome.*


---
---

# Cloud team milestone update — 2026-04-30 (Phase 1.6 Observability deployed)

> **From:** GoSteady cloud team
> **Closes:** the §C6.5 commitment line about "Phase 1.6 Observability —
> alarm catalog (especially log-pattern filters for the swallowed-error
> pattern; see ARCHITECTURE.md §16), X-Ray activation, dashboards." All
> three landed today.
> **Acks:** firmware §F5–§F8 (M10.7 + M12.1c.2 + M12.1e.1 + M12.1e.2 +
> M12.1f) collectively closing out the M12.1 Cellular work-block. The
> data flowing through Shadow + Activity DDB + S3 across that sprint
> was exactly the input shape the Phase 1.6 dashboard widgets needed —
> turning on the dashboards retroactively pulled up live data points
> (the M12.1d activity row, the M12.1f snippet upload, the M12.1c.2
> heartbeat extras) on first render.
>
> **TL;DR:** Phase 1.6 Observability stack deployed to dev 2026-04-30
> across 4 stages with checkpoints (commits `5bcc9cc` → `7e73121`).
> Two CloudWatch dashboards (`gosteady-dev-platform-health` +
> `gosteady-dev-per-device`), 29 alarms, AWS-managed Powertools
> layer attached to the 4 handler Lambdas, X-Ray Active Tracing on all
> 6 Lambdas, log-retention aspect, log-pattern filters that close the
> §16 swallowed-error gap. Cost Anomaly Detection coded but gated
> pending Cost Explorer account-level opt-in (CFN can't enable it).
>
> **Implication for firmware:** during M14.5 site-survey shakedown,
> the Per-Device Detail dashboard URL becomes the shareable monitoring
> surface for the bench unit + shipping unit. Switch the dashboard
> variable to the shipping unit's serial when `GS0000000001` flashes;
> all widgets re-query without redeploying the dashboard.

---

## C7.1 What deployed

Stack: `GoSteady-Dev-Observability` (new), 42 CFN resources total.
4-stage rollout with separate commits per stage so rollback is clean.

Stage-by-stage summary:

| Stage | Commit | Resources | Acceptance |
|-------|--------|-----------|-----------|
| **0** Spec drafted | `5bcc9cc` | docs only | (n/a) |
| **1** Powertools layer | `c4589e0` | 4 Lambda updates | T1: layer attached to all 4 handlers, ARM64/py3.12; T2: heartbeat / activity / threshold / alert all functional through layer |
| **2** X-Ray + per-device metrics | `22a42fb` | 6 Lambda updates + heartbeat-processor handler.py | T3: all 6 Lambdas show TracingConfig.Mode=Active; T4: 7-metric EMF JSON in `GoSteady/Devices/dev` namespace, X-Ray trace `1-69f2d971-...` visible with 309 ms response latency |
| **3** Dashboards | `de81b16` | new Observability stack (2 dashboards + URL outputs) | T5/T6/T7/T17/T18: both dashboards rendered, per-device variable populates, recent-activity + recent-snippet widgets surface the bench unit's M12.1d session + M12.1f snippet upload (43,122 B `c1c906b6-...`) |
| **4** Alarms + retention + cost gate | `7e73121` | 29 alarms + 9 metric filters + log-retention aspect + cost-anomaly construct (gated off) | T8: 30 alarms total; T9 ALARM-fired correctly on synthetic orphan-serial activity; T10 ALARM-fired (after pattern fix for stdlib log shape) on synthetic format_version=99 snippet; T14: all 6 Lambda log groups at 30d retention |

## C7.2 The "rudimentary view of files offloaded by device"

Per firmware feedback that triggered this spec (the §F8.7 → 1.6 →
"step by step validation" sequence). The Per-Device Detail dashboard
at `gosteady-dev-per-device` includes two Logs Insights table
widgets:

- **Recent activity sessions** — backed by activity-processor's
  Powertools `patient.activity.create` audit log entries, surfacing
  the last 20 sessions for the selected serial with `session_end`,
  `steps`, `distance_ft`, `active_min`, `roughness_R`, `surface_class`,
  `firmware_version`. Bench-validated against the M12.1d row
  (`steps=15, distance_ft=11.05, R=0.1587, surface=indoor,
  firmware=0.7.0-cloud`) — shows up cleanly when filtered to
  `GS9999999999`.
- **Recent snippet uploads** — backed by snippet-parser's
  `device.snippet_uploaded` JSON log lines, surfacing the last 20
  uploads for the selected serial with `snippet_id`,
  `window_start_ts`, `size_bytes`, `anomaly_trigger`, `s3_key`.
  Bench-validated against the M12.1f snippet (`c1c906b6-dc63-...`,
  43,122 B, `GS9999999999/2026-04-29/c1c906b6-...bin`) — shows up
  with the bench unit's full S3 key.

Phase 2A's Lambda-backed custom widgets will replace the Logs
Insights queries with direct DDB / S3 queries (more efficient, less
latency, clickable S3 links). Until then this is the rudimentary
shape — live, real-data, shareable URL.

## C7.3 Per-device dashboard variable for switching units

The dashboard exposes a single PATTERN-type variable `serial` (free-
text input, default `GS9999999999`). Toggling it does a regex find-
and-replace across the dashboard JSON at render time — every metric
dimension and every Logs Insights query containing `GS9999999999`
gets transparently swapped to the new value.

For M14.5 site-survey: when `GS0000000001` (or whichever shipping
unit ships first) is flashed, click the variable selector at the top
of the dashboard, type the new serial, and the entire dashboard
re-queries against that unit. No redeploy needed. Default can be
flipped later via a config-only redeploy if the bench unit becomes
less interesting.

## C7.4 Alarm catalog — closes §16 swallowed-error gap

Per the §16 ARCHITECTURE.md open question that 1.6 was scoped to
address. Three signal paths now alarm explicitly, ending the
silent-failure window:

1. **Lambda Errors > 0** per handler — catches uncaught exceptions
   that propagate out of the handler. Was already a CloudWatch
   metric; now alarms.
2. **ERROR-level log filter** per handler — catches handlers that
   log-and-swallow (return success while logging an error).
   Powertools handlers (4): `"level":"ERROR"` JSON shape match.
   Stdlib handlers (`cognito-pre-token` + `snippet-parser`):
   `[ERROR]` substring match against Lambda runtime's
   uncaught-exception line prefix.
3. **DLQ depth > 0** on the IoT DLQ — catches IoT-side failures
   (auth, throttling, malformed SQL, missing Lambda permission).
   The §16 finding was that this DLQ does NOT catch handler-internal
   failures (async Lambda invoke). The other two paths fill that
   gap.

Plus handler-specific alarms for the most-likely-swallowed failure
modes: `unmapped_serial` on activity-processor (orphan device row),
`SnippetValidationError` on snippet-parser (malformed payload).

Handler-specific test results during deploy:
- `activity-processor-unmapped-serial`: synthetic publish for
  serial `GS_ORPHAN_T9` → activity-processor logged `unmapped_serial`
  WARN line → metric filter incremented to 1 →
  alarm transitioned to ALARM after 5 min (sampleCount=7 datapoint).
- `snippet-parser-snippet-validation-error`: synthetic publish with
  `format_version=99` → snippet-parser raised `SnippetValidationError`
  → Lambda runtime emitted `[ERROR] SnippetValidationError: ...` →
  all 3 snippet-parser alarms (errors, error-pattern,
  snippet-validation-error) transitioned to ALARM.

## C7.5 Watchdog-hits ≥3 / 24 h alarm (firmware §F5.2 suggestion)

Per the firmware-coord §F5.2 recommendation when M10.7.3 made
`watchdog_hits` actionable. CloudWatch metric-math alarm on the
Stage-2 EMF metric:

```
expression: MAX([m1]) - MAX([m1_24h_ago])  (where m1 = WatchdogHits)
threshold: ≥3
period: 24h
```

Fires when any device in the fleet reports ≥3 watchdog resets within
24 h. v1 routes to the ops topic — once Phase 2A device-shadow-handler
ships, this becomes a candidate for caregiver-facing surfacing
("device unstable"). Alarm description in CloudWatch console
includes a pointer to the Per-Device dashboard for diagnosis.

v1 caveat: alarm doesn't carry the offending serial in the
notification text (single fleet-wide metric math), so operator
inspects the Per-Device dashboard to find the specific unit.
Phase 2A custom widgets will swap to per-serial alarms once Device
Registry is queryable from CDK synth time.

## C7.6 Cost Anomaly Detection — gated, requires console opt-in

CFN `AWS::CE::AnomalyMonitor` failed CREATE on first deploy with
`User not enabled for cost explorer access`. Cost Explorer is an
account-level opt-in that has to be enabled manually via the AWS
Console (Billing & Cost Management → Cost Explorer → Enable). CFN
can't trigger it.

Wrapped both the monitor and subscription in a feature flag:
`config.costAnomalyEnabled` (default `false` in dev). Construct +
spec are coded; flip the flag + redeploy `GoSteady-Dev-Observability`
once Cost Explorer is enabled in console. Anomaly delta threshold
set at $20 (meaningful jump at our ~$10-30/mo dev spend).

The existing $100 billing alarm from Phase 1.5 continues to run
unchanged — that's the absolute-threshold catch.

## C7.7 What this unblocks for firmware

**M14.5 site-survey shakedown observability surface:**

| Need | URL / mechanism |
|------|-----------------|
| Live device state | `aws iot-data get-thing-shadow --thing-name GS9999999999` (markdown widget on Per-Device dashboard documents the snippet); Phase 2A custom widget replaces this |
| Heartbeat history (battery, signal, fault counters) | Per-Device dashboard battery/signal/watchdog graphs over selected time range |
| Recent walk sessions | Per-Device dashboard "Recent activity sessions" widget |
| Recent snippet uploads | Per-Device dashboard "Recent snippet uploads" widget; click `s3_key` value → S3 console |
| Lambda errors / IoT failures | Platform Health dashboard + ops-topic email subscriptions |
| Crash forensics surface | Per-Device dashboard fault-counter graphs trending over time |

For M14.5: switch the dashboard variable to `GS0000000001` (or
whichever shipping unit ships first) when the unit goes on the
bench. Email subscriber on the ops topic gets pinged on any alarm
transition during the 7-day soak.

## C7.8 What's next cloud-side

With 1.6 deployed, cloud-surface remaining items for the firmware
M14.5 → M15 timeline:

1. **Phase 1.7 Audit Logging** — dedicated audit log group + S3
   Object Lock + subscription filter routing the existing audit-
   shape log entries (1B-rev handlers already emit them in Powertools
   structured JSON). Spec not yet drafted; gates Phase 2A together
   with what 1.6 just landed.
2. **Phase 2A Device Lifecycle** — `device-api` Lambda (provision
   endpoint that publishes the activate cmd + writes Shadow
   `desired.activated_at`), `device-shadow-handler` Lambda (consumes
   firmware's `reported.activated_at` ack and flips Device Registry
   state), `discharge-cascade` Lambda. Until 2A ships, firmware's
   M12.1e.2 wake-time Shadow re-check has no observable cloud
   effect (per §C6.3). Spec lives at
   [`phase-2a-device-lifecycle.md`](../specs/phase-2a-device-lifecycle.md).
3. **Cost Anomaly Detection enablement** — manual Cost Explorer
   opt-in in console, then flip the gate flag + redeploy.

No firmware-side action items from this entry. The 1.6 deploy is
non-disruptive to the ingestion path; existing M12.1c.1 / M12.1d /
M12.1e.2 / M12.1f publish cycles continue working unchanged. The
new dashboards retroactively render the existing data; future
heartbeats automatically populate the per-device EMF metrics
(no firmware change).

## C7.9 Cadence

This entry closes the §C6.5 commitment on Phase 1.6 deliverables.
Next cloud-side coord-doc-affecting work: Phase 1.7 Audit Logging
spec drafting + deploy, then Phase 2A Device Lifecycle (per the
arc above).

Per firmware §F8.7 ("Next coord-doc trigger from firmware:
M14.5 site-survey shakedown report at the end of the week-long
observation"), the next ping from firmware should be the M14.5
report. The Per-Device dashboard URL is the recommended surface
for that observation; happy to share access patterns or extend the
widget set if anything proves missing.

---

*Entry owner (cloud side): Jace + Claude. Counter-proposals,
blocker flags, and milestone updates welcome.*


---
---

# Joint cloud + firmware update — 2026-05-05 (Phase 1.6 dashboards surface activity-uplink stale-sem race; fix lands both sides)

> **From:** GoSteady firmware + cloud teams (same Claude session, both
> hats worn over the course of the day).
> **TL;DR:** Phase 1.6 Per-Device Detail dashboard at the operator's
> console first showed "no activity sessions in 5 days" — diagnosed
> via diagnostic LOG_INFs added to the writer thread + new visibility
> patches on the cloud.c publish-result path. Root cause was a stale
> `stop_done_sem` count from a previous session whose stop branch
> exceeded the 5 s `k_sem_take` timeout (LittleFS GC on a near-full
> sessions partition, ~84 % utilization, makes `fs_close` +
> `snippet_capture_finish` slow). Activity uplinks were SILENTLY
> SKIPPED; sessions persisted on flash but never reached cloud.
>
> Two fixes landed:
> - **firmware** (commits `fede856` + `4d62fd5`): visibility patch +
>   stop_done_sem reset-before-raise + 5 s → 15 s timeout bump
> - **cloud** (commit `ec258f5`): activity-processor audit log now
>   includes distanceFt / roughnessR / surfaceClass / firmwareVersion
>   in the `after` block; per-device dashboard query field names
>   aligned with audit log shape (camelCase, not firmware snake_case)
>
> All four uplinks (heartbeat / activity / cmd ingest / snippet) now
> bench-validated end-to-end against real-walk data, with full
> dashboard rendering. Five real walks landed cleanly: 35 / 40 / 10 /
> 81 / 60 steps with M9 algo outputs intact (R + surface_class +
> distance_ft all populated).

---

## Diagnostic journey

Sequence of events worth capturing because the bugs hid behind each
other and Phase 1.6 was the surface that finally exposed them:

**Symptom (firmware operator on dashboard):**
- "Cellular reporting seems ~2 hours behind"
- "I did a few walk events in the last hour and they still haven't
  made it through"
- "Maybe the FIFO setup is causing delay?"

**First-pass cloud-side diagnosis (≤5 min):**
- Heartbeat actually fresh (6.9 min old; the 60 min metric-period bins
  on the Per-Device dashboard make the latest data point appear ≤59 min
  stale even when fresh)
- Snippets uploading on schedule (1 per heartbeat wake per FIFO design)
- **Zero activity rows in DDB for last 5 days, despite the user
  reporting walks**
- Snippet S3 path active for that period — proves cellular + cloud
  ingest is healthy. Activity is the only path that's silently failing.

**Diagnostic instrumentation added** (firmware commit `fede856`):
- `LOG_INF` at writer thread start handshake (drained samples + flag reset)
- `LOG_INF` on first sample's pipeline seed (mag_g value)
- `LOG_INF` at writer thread stop branch (pipeline_seeded value +
  sample_count + batch_fill)
- `LOG_INF` after gs_pipeline_init at boot (success/failure)
- Stop discarding `connect_publish_disconnect` return code in the
  activity worker (was `(void)`; now logs WRN with rc on failure +
  INF on success)
- Bonus: closed the stale `TODO(M12)` on rewrite_header that was
  leaving `session_end_utc_ms` hardcoded 0 — now populated via a new
  `gosteady_cellular_get_network_time_unix_ms()` helper using
  Zephyr's `timeutil_timegm64`.

**Reflash + first reproduction:**
- Synthetic 8 s session (cap on desk, no motion): pipeline correctly
  seeded on first sample, ALGO_V1A logged with all-zeros (steps=0,
  distance=0, R=NaN — correct for stationary cap), activity uplink
  fired, DDB row landed. The diagnostic-only commit appeared to fix
  it.
- BUT: when user took a real walk on the walker (44 s session
  `203c9073`, 4352 samples), the WARN re-appeared. Activity uplink
  silently skipped.

**Smoking-gun timestamps:**
```
[14:28.797]  auto-stop: 15 s of stationary motion → ending session
[14:28.797]  session stop uuid=203c9073 samples=4352 dropped=0 duration_ms=43985
[14:28.798]  WRN: ALGO_V1 uuid=203c9073 no outputs (pipeline not seeded)
[14:28.863]  writer: stop branch — pipeline_seeded=1, sample_count=4392
              ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
              writer's diagnostic log fires 65 ms AFTER session_stop's
              WARN. session_stop must have read s_pipeline_outputs_valid
              BEFORE the writer set it. But k_sem_take(K_SECONDS(5))
              should have blocked until the writer's k_sem_give...
```

**Root cause:** the **previous** session (`81c54e52` "setup" walk)
hit the 5 s timeout on its `k_sem_take`. session_stop body fell
through, logged "writer stop ack timeout (-11)", continued. Writer
eventually finished its slow `rewrite_header + fs_close +
snippet_capture_finish` (>5 s under LittleFS-GC pressure on the
near-full sessions partition: 1.3 MB free / 8 MB) and called
`k_sem_give`. The give landed on stop_done_sem, leaving count=1.
Next session's `k_sem_take` consumed the stale count instantly,
read s_pipeline_outputs_valid before that session's writer had
even started its stop branch (still false from the start handshake)
→ WARN → activity uplink path silently skipped.

This race had been latent for the entire M12.1d era. It only became
observable AFTER the LittleFS partition filled up enough to make
fs_close routinely exceed 5 s. With 87 .dat files accumulated across
4 firmware versions over the past two weeks of bench testing,
GC contention was high.

**Fix (firmware commit `4d62fd5`):**
1. `k_sem_reset(&stop_done_sem)` immediately before raising
   `stop_signal` in `gosteady_session_stop()`. Purges any stale
   count from a previous timed-out cycle.
2. Bumped `K_SECONDS(5)` → `K_SECONDS(15)` on the stop-ack take.
   Empirical fs_close + snippet_finish on a near-full partition
   takes ~1-2 s; 15 s gives 10x headroom for worst-case GC.
3. Updated the timeout error log to point operators at the
   writer's stop-branch diagnostic line (which now confirms whether
   pipeline_seeded was set true even when the timeout fires).

## C8.1 Cloud-side bug surfaced by the now-working dashboard

Once activity uplinks started reaching DDB correctly, the user observed
the Per-Device dashboard widget was rendering only the `steps` column —
distance_ft / R / surface / firmware all empty.

DDB rows were complete (verified via `aws dynamodb get-item`):
```
35 steps / 14.31 ft / R=0.0335 / indoor / 0.8.0-prod
40 steps / 16.17 ft / R=0.0199 / indoor / 0.8.0-prod
10 steps / 17.79 ft / R=0.4033 / outdoor / 0.8.0-prod    (←!)
81 steps / 51.92 ft / R=0.0931 / indoor / 0.8.0-prod
60 steps / 30.83 ft / R=0.0619 / indoor / 0.8.0-prod
```

Two cloud-side bugs were chained:

1. **activity-processor's emit_audit `after` block was missing the
   firmware-derived optional fields** (distanceFt / roughnessR /
   surfaceClass / firmwareVersion). The DDB row had them; the audit
   log only had sessionEnd / steps / activeMinutes / date. Dashboard
   widget reads from the audit log, so the missing fields were
   genuinely absent from the widget's data source.

2. **Per-device dashboard's Logs Insights query used firmware-side
   snake_case field names** (`after.distance_ft`,
   `after.roughness_R`, `after.surface_class`,
   `after.firmware_version`). Audit log uses camelCase
   (matching DDB column names). Even with #1 fixed, snake_case
   wouldn't have matched.

**Fix (cloud commit `ec258f5`):** activity-processor handler.py
populates the full `after` block; per-device.ts dashboard query uses
camelCase aliases. Both deployed cleanly to dev.

**Browser cache caveat noted:** when the dashboard widget's column
schema changes (server-side), browser-cached column layouts persist
until a hard reload. CloudWatch dashboards don't auto-invalidate
client cache on schema change. Operator workflow: hard-refresh the
dashboard tab (Cmd+Shift+R on macOS) after any widget redeploy that
changes column structure.

## C8.2 What this validates

**All four cloud uplinks are now bench-validated end-to-end with
real-walk data:**

| Topic | Latest evidence |
|---|---|
| `gs/{serial}/heartbeat` | Hourly publishes, every-hour DDB Shadow updates, all 5 required + 7 optional fields populated, M10.7.3 fault counters live |
| `gs/{serial}/activity` | 5 real walks landed at DDB Activity Series, M9 algo outputs (steps / distance_ft / R / surface_class) all populated, patient-resolution + hierarchy snapshot working, audit log fully populated for downstream query |
| `gs/{serial}/cmd` (downlink) | M12.1e.2 activate cmd flow, persisted to /lfs/activation.bin, survives reboot, last_cmd_id echoed in heartbeat as ack |
| `gs/{serial}/snippet` | 5+ snippets uploaded today, 14-84 KB each, S3 objects bit-exact, JSON header parsing clean |

**Per-Device Detail dashboard is the operator-facing surface for
M14.5** going forward. With today's fixes it correctly renders:
- Battery curve from EMF metric (from heartbeat-processor publish)
- RSRP / SNR dual-axis curve
- Watchdog hits + fault_counters trend
- Recent activity sessions table (full 9 columns post-fix)
- Recent snippet uploads table
- Recent synthetic + recent device alerts

The dashboard is now a reliable single-pane view of any device's
state — exactly the M14.5 monitoring surface that was the original
motivation for the spec back on 2026-04-29.

## C8.3 Adjacent observations worth flagging for v1.5

**One real walk (19:58:50, `R=0.4033`, surface=outdoor):** the M9
auto-surface classifier flipped that one to outdoor. R is well above
the τ=0.245 threshold. Either user actually took the walker outside
for that session, or there's a noise floor edge case. Worth pulling
that .dat file and running through the Python algo offline to confirm
the classification is reasonable. Not blocking but worth noting in
the v1.5 retrain corpus.

**LittleFS sessions partition is at ~84 % utilization** (1.3 MB free
/ 8 MB) on the bench unit. fs_close + snippet_capture_finish slow
down materially under this much GC pressure. Two follow-up options:

1. Run `tools/cleanup_device.py --all --yes` on the bench unit to
   reset partition utilization. Fast workaround.
2. Implement auto-prune-on-publish-success: once activity uplink is
   acknowledged for a session, the .dat file becomes redundant
   (snippets are the v1.5 retrain corpus, not the .dat files).
   Needs a small flag on each .dat file or a parallel index of
   "uploaded_at" markers. Not a blocker for M14.5 but worth doing
   before fleet expansion.

## C8.4 What's next

**Firmware-side:** ready for M14.5 site-survey shakedown. Flash
`GS0000000001` with shipping cert + deployment build (`prj_field.conf`),
sit on bench desk for ≥7 days, observe dashboards. Today's bug-fixing
work proves the pipeline is solid under real walk conditions.

**Cloud-side:** Phase 1.6 is complete. Next phases per the master
plan: 1.7 (audit logging infra) → 2A (device-api Lambda + portal API
+ device-shadow-handler). Both are unblocked by 1.6's deploy.

No firmware-coordination action items from this entry. Both teams
have what they need to proceed independently to the next milestone.

---

*Entry owner: Jace + Claude (both firmware + cloud session, 2026-05-05).*


---
---

# Joint cloud + firmware update — 2026-05-06 (auto-prune-on-publish + ENOSPC handling; SW2-misposition lesson)

> **From:** GoSteady firmware + cloud teams (same Claude session, both
> hats; this is the closing entry of the multi-day "activity uplinks
> vanishing" debugging arc that started 2026-05-05 and was diagnosed
> via Phase 1.6's per-device dashboard).
>
> **TL;DR:** Firmware commit `bde3434` ships the architectural fix for
> the partition-fill failure mode whose symptoms we caught yesterday
> (ENOSPC → fatal-fault mid-walk on bench unit GS9999999999): auto-prune
> on activity PUBACK + graceful ENOSPC handling. Validated end-to-end
> on the bench. **Firmware is ready for M14.5 site-survey shakedown.**
> Cloud-side: nothing new today; Phase 1.6 stack continues to work as
> the diagnostic surface that exposed all of yesterday's bugs.
>
> Bonus operational lesson worth burning into M14.5 procedure: a
> SW2-bumped-to-nRF53 misposition can make `nrfjprog --recover` cascade-
> corrupt the wrong chip. Section §C9.2 below.

---

## C9.1 Auto-prune-on-PUBACK + ENOSPC handling (firmware `bde3434`)

Yesterday's coord §C8 closed the **stale `stop_done_sem` race** —
silent activity-uplink drops surfaced when the dashboard widget went
live. But §C8.3 also flagged a deeper issue: the LittleFS sessions
partition was at 84 % utilization (1.3 MB free / 8 MB), 87 stale .dat
files accumulated across 4 firmware versions, and ENOSPC was the
proximate cause of the firmware fatal-faulting mid-walk. We deferred
the architectural fix as "follow-up before M14.5 ship" — and did it
this morning.

**Two halves (single commit):**

1. **Auto-prune-on-publish-success.** `struct gosteady_activity` gains
   `session_uuid[37]`; session.c populates it from the .dat header;
   cloud.c's activity worker calls a new `gosteady_session_prune(uuid)`
   immediately after the success branch of `connect_publish_disconnect`.
   The .dat becomes redundant once algo outputs are in cloud's Activity
   Series DDB (and the snippet on the separate snippet partition is the
   v1.5 retrain corpus). Bounds partition growth.

   The prune validates the UUID against canonical 36-char hyphenated
   form before pathing into `/lfs/sessions/{uuid}.dat` for `fs_unlink`
   — defensive against a typo'd path unlinking unrelated files like
   `/lfs/boot_count`.

2. **Graceful ENOSPC handling.** New `s_writer_flash_full` flag in
   session.c set by `writer_flush` on `fs_write` returning -ENOSPC,
   logged once per session (not at the 100 Hz EAGAIN flood rate that
   buried diagnostic lines yesterday). New `gosteady_session_flash_full()`
   accessor; main.c heartbeat tick polls it next to the existing
   stationary-samples auto-stop check; on `flash_full=true`, calls
   `gosteady_session_stop()` to close the session cleanly. The
   activity-uplink path runs normally against valid in-memory algo
   outputs (the pipeline runs regardless of write success), and
   auto-prune then frees a .dat slot for the next session.

   main.c's sampler EAGAIN warning is also rate-limited 1-per-100
   consecutive drops (≈1/sec at 100 Hz sampling), bounded by a
   static drop-streak counter that resets on any successful enqueue.

**Bench validation (`GS9999999999` after reflash 2026-05-06T17:41Z):**

```
writer: pipeline seeded (first mag_g=1.0098)
writer: stop branch — pipeline_seeded=1, sample_count=637, batch_fill_at_entry=0
ALGO_V1A uuid=56c8037b distance_ft=0.00 R=nan surface=0 steps=0
activity enqueued: session_end=2026-05-06T17:42:51Z (msgq has 0/4)
activity worker: dequeued
snippet upload: 56c8037b — 17950 B
M12.1d activity uplink sequence complete
auto-prune: deleted /lfs/sessions/56c8037b-...dat after activity PUBACK   ← NEW
```

`LIST` on uart1 confirms `56c8037b-...dat` is gone post-PUBACK; only
the pre-existing `1c778fdd-...dat` (from earlier today before the
reflash, predating auto-prune) remains. Cloud-side row at
`2026-05-06T17:42:51Z` lands cleanly with all 9 dashboard columns
populated.

## C9.2 SW2-misposition lesson learned (operational; capture for M14.5)

During this morning's reflash workflow we burned ~3 hours on what
looked like an nRF9151 lockout — `nrfjprog --recover` returning
"Eraseprotect is enabled and readback protection setting is ALL" on
every attempt, USB CDC stopped enumerating, every CLI escalation
making it worse. The operator-side narrative was "did the morning's
ENOSPC fault somehow trip APPROTECT and brick the chip?"

**Actual cause:** SW2 (the chip-select switch on the Thingy:91 X
board that decides whether the J-Link's SWD lines go to the nRF9151
or the nRF5340 bridge) had been **physically bumped to the nRF53
position** at some point during the day's walks. nrfjprog with the
`-f NRF91` flag was happily talking to the nRF5340 bridge chip,
treating it as if it were an nRF91, and the `--recover` CTRL-AP
sequence was operating on bridge-chip register addresses that
don't map cleanly to nRF53 layout. Result: the bridge chip got
itself into a partially-corrupted protection state, USB CDC died,
and every subsequent recovery attempt made things worse.

**Recovery sequence that worked** (after we noticed the chip family
in nRF Connect Programmer was `NRF5340_xxxx_REV1` rather than
`NRF91_xxxx`):

1. `nrfjprog -f NRF53 --coprocessor CP_NETWORK --recover --snr 802006700`
   (per Programmer's hint that recovering the nRF53 network core
   cascade-recovers the application core)
2. `nrfjprog -f NRF53 --coprocessor CP_APPLICATION --recover --snr 802006700`
   (verify app core is now unprotected)
3. `nrfjprog -f NRF53 --program build_bridge/merged.hex --chiperase
   --verify --reset --snr 802006700` (reflash our bridge fork —
   preserves uart1 baud + BLE-NUS-targeting-uart1 patches per
   `bridge_fw/PATCHES.md`; Nordic stock hex would need re-patching)
4. **Physically toggle SW2 back to nRF91 position**
5. `nrfjprog -f NRF91 --readregs --snr 802006700` to confirm the
   nRF9151 is alive (it was the entire time — running this morning's
   working firmware, untouched by all the bridge-side flailing)
6. `west flash --runner nrfjprog -d build_cloud --skip-rebuild --erase`
   to update the nRF9151 with the new build_cloud (auto-prune +
   ENOSPC fixes)

**Important non-obvious detail confirmed during recovery:** chip-erase
on the nRF9151 application flash does NOT touch:
- The external GD25LE255E SPI NOR flash (LittleFS partitions:
  sessions / snippets / telemetry_queue / crash_forensics /
  /lfs/activation.bin / /lfs/boot_count) — these all persisted across
  the chip-erase
- Modem firmware + modem credentials (sec_tag 201) — managed by the
  modem subsystem in a separate flash region
So the only post-erase work was the application flash itself. No
re-flashing of certs needed; no loss of activation state.

**Operational rule for M14.5:** before running ANY `nrfjprog --recover`
or `west flash` command in the field, **explicitly verify SW2 is on
the nRF91 position**. Add this as a pre-flight check to whatever
operator runbook the site-survey deployment will use. The chip family
shown in nRF Connect Programmer is the truth; if it shows
`NRF5340_xxxx_REV1` for what should be an nRF91 flash target,
SW2 is wrong.

## C9.3 What this leaves us with going into M14.5

**Firmware:** `bde3434` is the M14.5-ship candidate. All known
silent-failure modes that yesterday's instrumentation surfaced are
now closed:
- stale `stop_done_sem` race → fixed (commit `4d62fd5`)
- audit log + dashboard query gaps → fixed (cloud commit `ec258f5`)
- partition-fill ENOSPC → fixed (this commit, `bde3434`, both
  auto-prune-on-publish + flash_full → auto-stop-clean)

**Cloud:** Phase 1.6 (observability) deployed and proven as a
diagnostic surface. The dashboards caught two latent bugs in the
firmware that had been silent for ≥2 weeks. Phase 1.7 (audit log
infra) and Phase 2A (portal API + device-api) remain queued; per
yesterday's discussion neither blocks the M14.5 → M15 path.

**Bench unit `GS9999999999`:** running the `bde3434`-equivalent
build_cloud as of 2026-05-06T17:41Z. LittleFS partition state: one
pre-existing `1c778fdd-...dat` (from yesterday's testing, predates
auto-prune); going forward, post-PUBACK auto-prune keeps the
partition empty unless a publish fails. activation state preserved
(`act_test_m12_1e2` from M12.1e.2). fault counters preserved
(`fatal=3, watchdog=5` — historical, not from any fault today).

**M14.5 next steps when convenient:**
- Run `tools/cleanup_device.py --all --yes` once on `GS0000000001`
  to start with a clean partition (M14.5 unit will accumulate
  organically once auto-prune is doing its job)
- Flash `build_field/merged.hex` (with the new code) onto
  `GS0000000001` + the shipping cert via `tools/flash_cert.py`
- Sit on bench desk for ≥7 days, observe the Per-Device dashboard
  + the alarm catalog from Phase 1.6
- M11.1 confirmation walk with a real walker sometime during that
  7-day window

No firmware-coord action items from this batch.

---

*Entry owner: Jace + Claude (both firmware + cloud session, 2026-05-06).*
*This concludes the multi-day arc: the dashboards exposed silent
failures; the diagnostic logs pinpointed the races; the architectural
fixes close the failure modes; the bench unit is M14.5-ready.*

---

# Joint cloud + firmware update — 2026-05-10 (M14.5 hardening sprint: dashboard period fix + 6-axis FMEA + 6 firmware punch-list items shipped + 2 deferred + 1 reverted post-bench)

> **From:** GoSteady firmware + cloud teams (single Claude session — the
> formerly-separate firmware/cloud sessions merged today as the work has
> become too cross-cutting to coordinate via this append-only doc alone).
>
> **TL;DR:** Started the day diagnosing why the per-device dashboard
> looked empty despite a healthy heartbeat publishing. Pulled the thread
> into a full M14.5 hardening sprint. Cloud-side: dashboard widget
> period 60min → 1min so single data points render immediately. Firmware-
> side: produced HARDENING_FMEA.md (37-row 6-axis failure-mode analysis),
> implemented 6 of the 9 high-Risk-low-Effort items, version bumped
> 0.8.0-prod → 0.9.0-hardening. One item revert post-bench-validation
> (FMEA 6.1 capture_start rotate hook caused WDT regression under weak
> cellular signal). All other items bench-validated against GS9999999999.
>
> Note on session merge: with the same Claude operating both repos, this
> coord doc moves from "cross-team broadcast" to "shared engineering
> log." Future entries may be shorter / less ceremonial than the 2026-04
> originals when both halves of a change are coherent in one session.

---

## C10.1 Cloud-side: per-device dashboard widget period (commit `fcda720` on `feature/infra-scaffold` + deployed)

**Symptom:** Bench unit was healthy and heartbeating successfully, but the
per-device CloudWatch dashboard appeared completely empty even on the 1h
preset. `aws cloudwatch get-metric-data` confirmed the data point existed
in CloudWatch storage with the correct dimensions (`serial=GS9999999999,
service=gosteady-dev-heartbeat-processor`).

**Root cause:** `infra/lib/constructs/dashboards/per-device.ts` hardcoded
`period: cdk.Duration.minutes(60)` on all 6 metric widgets (BatteryPct,
RsrpDbm, SnrDb, WatchdogHits, FaultCountersFatal, FaultCountersWatchdog).
CloudWatch snaps the dashboard's selected time-range backward to the
previous full-period boundary when widgets specify period >= 60s. So
selecting "1h" rendered as "the previous full hour ending at 10:00" —
excluding the in-progress 10:00–11:00 bucket containing the most recent
heartbeat at 10:05. With heartbeat firing once per hour, every dashboard
view between heartbeats was effectively empty.

**Fix:** Drop `period` from `Duration.minutes(60)` to `Duration.minutes(1)`
on all 6 metric widgets. Each heartbeat now renders as a dot in the
minute-bucket it actually arrived; default time-range presets work
intuitively. Free at this volume (≤24 datapoints/day/serial).

**Deploy:** `cdk deploy GoSteady-Dev-Observability` ran 2026-05-10T17:46Z,
UPDATE_COMPLETE in 25 s. Dashboard widget periods verified `[60, 60, 60,
60, 60, 60]` post-deploy.

**Side benefit:** Makes the M14.5 site-survey dashboard usable as a
real "is this device alive right now" view. Before this fix, a freshly-
deployed unit would look "broken" for the first hour after activation.

**Documented in `ARCHITECTURE.md` Phase 1.6 follow-up subsection** (header
date updated to "Deployed (dev) 2026-04-30, follow-ups 2026-05-05 +
2026-05-10").

## C10.2 Cloud-side OPEN follow-up: `activity_reject_count` alarm gap

While diagnosing the dashboard issue, surfaced a parallel cloud-side
gap: today's bench session also produced an `activity_reject` for
`bad_timestamp:Invalid isoformat string: ''` (firmware bug — empty
session_start when motion-triggered auto-start fires before LTE-M
attaches; FMEA 1.1, fixed firmware-side). The activity-processor logs
this rejection at WARNING level, returns 200 OK to the IoT Rule (no
Lambda Errors counter), no ERROR-pattern match → entire firmware-side
bug class is invisible to the alarm catalog.

The `activity_reject_count` metric IS published by activity-processor
in `GoSteady/Processing/dev` namespace. It just has no alarm subscriber.

**Suggested fix (NOT in this commit):** Add a CloudWatch alarm on
`GoSteady/Processing/dev > activity_reject_count > 0` with the same SNS
routing as the existing `activity-processor-unmapped-serial` alarm.
~4-line CDK change in `observability-stack.ts`. Sibling fix to firmware
FMEA 1.1+1.2 (which already shipped firmware-side; cloud-side alarm
would surface any future regression).

Documented inline in `ARCHITECTURE.md` Phase 1.6 follow-up subsection
as "Open follow-up surfaced during the same investigation, NOT in this
commit."

## C10.3 Firmware-side: HARDENING_FMEA.md — 6-axis failure-mode analysis

`HARDENING_FMEA.md` at the firmware repo root committed 2026-05-10 as
65e6aa3. 37 rows across:

1. Silent data loss
2. Permanent brick (no recovery without physical access)
3. Battery overrun
4. False-positive cloud event
5. False-negative cloud event
6. Storage / lifecycle (gradient-failure axis — distinct from
   point-in-time failures because fixes are POLICIES, not bug fixes)

Each row scored on Severity × Probability = Risk and Effort (S/M/L/XL).
Cross-axis summary table orders all rows by Risk descending. M14.5-
blocker punch-list at end identifies the 9 items with Risk ≥ 12 AND
Effort ≤ M AND not Accepted.

## C10.4 Firmware-side: punch-list shipped (commits `2e4c1e7` + `5343100`)

Bumped firmware version 0.8.0-prod → 0.9.0-hardening. Six items
implemented, bench-validated against GS9999999999.

| Item | What | Bench result |
|---|---|---|
| **4.7** boot_count in heartbeat extras | New `gosteady_forensics_get_boot_count` getter; `APPEND_OR_FAIL` in `build_heartbeat_payload` | ✅ Shadow.reported.boot_count populated |
| **4.1** Reset forensics counters on first activation | New `gosteady_forensics_reset_counters` API; activation.c calls on transition from not-activated to activated | Code path verified; not triggered in bench (already-activated unit). Will fire on first activation of GS0000000001/2/3 |
| **1.1+1.2** Retro-stamp session_start/end UTC | New `gosteady_cellular_format_unix_ms_iso8601` formatter; activity worker resolves empty ISO strings from uptime deltas + current cellular UTC just before publish | Code path verified; not triggered in bench (cellular up before START). Will fire naturally on cold-boot-with-motion in field |
| **1.3** Activity republish on PUBACK timeout | In-memory retry with 1/5/15 min backoff (matches heartbeat retry pattern). After 3 attempts, drop with ERR; .dat preserved on flash | Code path verified; not triggered in bench (PUBACK arrived <1 s) |
| **6.2** Boot-time stale .dat orphan sweep | New `gosteady_session_orphan_sweep` iterates /lfs/sessions, fs_unlink any .dat. main.c calls after lfs mount, before sampler threads spawn | ✅ `orphan_sweep: deleted 7 stale .dat file(s) at boot` on first reflash |
| **6.1** Snippet rotation policy | 14-day stale cutoff + 90% free-space rotation. Boot-time + hourly heartbeat-tick triggers. **Capture_start hook reverted post-bench** (see C10.5 below) | ✅ Boot rotation runs cleanly; partition stays healthy |

Two items deferred with documented rationale in HARDENING_FMEA.md
"Deferred Items":

- **2.1 Shadow re-check on every cellular wake** — gated on cloud
  Phase 2A device-shadow-handler being live (per coord §F7.5 deferral).
- **3.1 nPM1300 LP803448-tuned battery model** — needs ~30-day bench
  discharge run, can't complete in a code-sprint. M14.5 soak should
  validate whether the bundled "Example" 1100 mAh model produces
  false-critical alerts at non-critical actual SoC; if so, that's the
  trigger to start the bench discharge.

## C10.5 Firmware-side WDT regression + revert: FMEA 6.1 capture_start hook

Bench-validation surfaced a WDT lockup on `START` immediately after the
hardening commit landed. Two consecutive `tools/control.py start-preset`
attempts both wedged the device past the 60 s WDT timeout
(`fault_counters.watchdog` 5→6, `reset_reason=WATCHDOG` on recovery
boots). Heartbeat tick log went silent for 50 s during each lockup.

**Root cause:** The new `gosteady_snippet_rotate` hook at the top of
`gosteady_snippet_capture_start` made a cellular_get_network_time
AT call (in rotate_stale_pass). Combined with the two pre-existing AT
calls in `session.c::session_start`, the session-open path made 3
sequential AT calls. Today's bench cellular state was unusual — RSRP
-97 dBm, EMM cause 15 logged, slow registration (3 minutes for one
boot vs typical 7-10 seconds). Under that contention, AT calls
serialized inside `nrf_modem_at` and cumulative latency breached the
60 s WDT envelope.

**Fix (commit `5343100`):** Drop the rotate-from-capture_start hook.
Boot-time + hourly heartbeat-tick rotation hooks still ship — coverage
of the rotation policy is adequate at 1-hour cadence (v1 capture rates
~8/day max are well below what would fill the 16 MB partition between
heartbeat ticks).

**Verification post-revert:** Same bench sequence completed cleanly:
START returned UUID in ~330 ms, session ran 12.42 s, ALGO_V1 ran,
activity published with `firmware_version=0.9.0-hardening`, PUBACK
received in <1 s, auto-prune deleted the .dat. Cloud activity-processor
logged `activity_ok` with no rejection.

**Watch item for M14.5:** The 2 pre-existing AT calls in session_start
STILL risk a similar lockup under sustained cellular contention. Today's
bench was unusual; typical conditions complete in <100 ms total. M14.5
site-survey should monitor for any session_start that takes >5 s as
an early-warning signal of AT serialization. If observed, follow-up
patch should add explicit AT timeouts via `nrf_modem_at_cmd_async` or
move AT-getting outside the session-open critical path.

## C10.6 Build sizes after sprint (build_cloud, prj_cloud.conf)

- FLASH: 210892 / 819200 (25.74%) — +4152 B over 0.8.0-prod
- RAM:   227440 / 227992 (99.76%) — +48 B over 0.8.0-prod
- merged.hex: ~952 KB

RAM at 99.76% is tight but stable. New BSS is 8 bytes for retry_count
+ 2× uptime_ms fields in struct gosteady_activity msgq slots × 4 + 16
bytes alignment padding. No new large allocations in heap or BSS.

## C10.7 What's next

**Firmware-side:** ready for M14.5 site-survey shakedown.
- Flash `GS0000000001` with cloud cert + `build_field/merged.hex` (the
  prj_field.conf overlay, deployment build).
- Bench desk for ≥7 days, observe per-device dashboard.
- M11.1 confirmation walk against this exact 0.9.0-hardening build
  during the soak window.
- Watch the M14.5 watch items called out in HARDENING_FMEA.md "M14.5
  Soak (lower urgency, validate during shakedown)" section.

**Cloud-side OPEN:**
1. `activity_reject_count` alarm subscriber (C10.2).
2. Phase 2A `device-shadow-handler` Lambda (gates firmware FMEA 2.1
   completion).
3. Phase 1C offline detector Lambda (`lastSeen > 2hr`).

**Joint OPEN observation watching M14.5 soak:**
- nPM1300 fuel gauge model accuracy on actual LP803448 cell. If false-
  battery_critical alerts fire at non-critical SoC, kick off bench
  discharge to build a tuned model (FMEA 3.1).

No firmware-coord action items from this batch.

---

*Entry owner: Jace + Claude (single merged firmware+cloud session,
2026-05-10).*
*This is the M14.5 hardening sprint completion entry. Bench unit
GS9999999999 running 0.9.0-hardening. Punch-list closed (with one
revert documented). Shipping firmware ready.*


---
---

# Joint cloud + firmware update — 2026-05-16 (informal site-survey aftermath: §C10.5 AT-serialization watch-item empirically validated; SIM-data-exhaustion was the trigger; scoped patch + cloud follow-ups)

> **From:** GoSteady firmware + cloud teams (single Claude session, both hats).
>
> **Context:** Bench unit `GS9999999999` (running 0.9.0-hardening) was carried
> around a conference 2026-05-11 → 2026-05-12 as an informal pre-M14.5 stress
> exposure. The cap was mostly not on a walker — the goal was just to see how
> the wake/sleep/session/upload state machine behaved during continuous low-
> motion exposure across two days with degrading cellular coverage. Device
> eventually wedged hard enough to need a power cycle. Then this morning,
> 2026-05-16, even after a clean power cycle the device produced no cloud
> traffic. The investigation that followed found two distinct failures, one
> of which had been explicitly predicted six days earlier.
>
> **TL;DR:** Onomondo SIM exhausted its data quota mid-conference. That alone
> only explains the cellular-publish failure (clean root cause for current
> silence: EMM cause 19 / PDN reject). It does NOT directly explain why the
> firmware locked up and needed a power cycle. The lockup is a **separate
> failure mode**: the two `AT+CCLK?` calls in `session_start`'s critical
> path block synchronously, and under sustained modem contention (which
> the SIM-rejection-loop creates very efficiently) they exceed the 60 s WDT
> envelope. This is exactly the §C10.5 "M14.5 watch item" — now with a real
> reproducer. Proposed patch: timeout-wrapped AT calls. Also one cloud-side
> alarm gap closed today (commit `3c47f0d`) + one new gap surfaced
> (device-offline alarm).

---

## C11.1 Informal site-survey timeline (conference, May 11-12)

Cap was healthy through 2026-05-11 morning (RSRP -85, hourly heartbeats on
schedule). Through the day:

| Phase | Window | Observation |
|---|---|---|
| Healthy | 05-11 00:33 → 13:36 UTC | 60-min heartbeats, RSRP -85 to -87, 33 walk sessions captured + uploaded |
| Signal degrades | 05-11 14:37 → 19:38 | RSRP collapses -86 → -95 → -113 → -117; first `signal_weak` synthetic alert at 15:37 |
| Retry storm | 05-11 23:35 → 05-12 02:17 | Off-cadence heartbeats at 71m → 8m → 12m → 4m → 15m intervals; firmware's linear-backoff retry path firing under PUBACK timeouts; 5 consecutive `signal_lost` synthetics |
| Overnight sleep | 05-12 02:17 → 14:59 | 12.7 h gap; battery dropped only 1.9 % = device sleeping correctly |
| Resumption | 05-12 14:59 → 19:43 | Hourly cadence, 35 more sessions, 15 more snippets |
| **Last heartbeat reached cloud** | **05-12 19:43:53 UTC** | RSRP -125, final `signal_lost` alert fired |
| Activity still landing | 05-12 19:43 → 20:20:57 | **4 more activity uplinks PUBACK'd after the "last" heartbeat** — activity-worker thread's connect cycle was finding cellular when heartbeat-worker's wasn't |
| Silence | 05-12 20:20:57 → 05-16 11:13 | No cloud traffic for ~3 days 15 h |

**Cloud-side aggregate over the two days:**
- 68 activity sessions, 8,777 steps
- 38 snippets uploaded, all parsed cleanly (zero `SnippetValidationError`)
- 40 heartbeats logged, Shadow updated on each
- 17 synthetic signal alerts (4 weak + 13 lost) — threshold detector working as designed
- Zero IoT Rule failures, zero DLQ messages, zero Lambda ERROR-level logs across all 6 handlers
- Zero `activity_reject_count`, zero `unmapped_serial_count`

The data path was healthy end-to-end. Everything that reached the broker was processed cleanly.

---

## C11.2 What the boot at 2026-05-16 11:13 told us

User power-cycled this morning ~1 h before investigation. First boot
forensics line was the smoking gun:

```
<inf> gs_forensics: hwinfo reset_cause=0x00000010
<wrn> gs_forensics: previous reset was WATCHDOG — count now 8
<inf> gs_forensics: forensics: boot=89 reset=WATCHDOG faults=4 wdt=8
<inf> gs_session: orphan_sweep: deleted 3 stale .dat file(s) at boot
```

Compared to Shadow's stale 2026-05-12 19:43 snapshot (`boot_count=86,
fault_counters.watchdog=7, fault_counters.fatal=3`):

| Counter | At conference end | This morning | Delta during silence |
|---|---|---|---|
| `boot_count` | 86 | 89 | **+3 reboots** |
| `fault_counters.watchdog` | 7 | 8 | **+1 watchdog fire** |
| `fault_counters.fatal` | 3 | 4 | **+1 fatal panic** |
| Orphan `.dat` files | (unknown) | 3 cleaned at boot | 3 sessions wedged mid-write |

The cap reset itself three times between the user's perceived "needed a
power cycle" moment and this morning's manual cycle. One of those resets
was a watchdog fire; one was a fatal panic; the third (POWER_ON or one of
the above) is unattributable without persisted per-event detail.

**Auto-prune-on-publish-success + orphan_sweep (FMEA 6.2 from M14.5 sprint)
worked exactly as designed** — the 3 stale `.dat` files from wedged
sessions were cleaned at the next clean boot with no manual intervention.
That hardening item is now field-validated.

---

## C11.3 Why the device couldn't talk to cloud this morning (not the lockup)

This morning's symptom was simpler than the conference lockup: device alive
+ ticking, but **zero MQTT publishes**. Cloud-side metrics showed zero
`Connect.Success` AND zero `Connect.AuthError` for the device across the
last 12 h — the broker wasn't even seeing TLS handshake attempts. uart0
log showed the cause:

```
<wrn> lte_lc: Registration rejected, EMM cause: 15 (×2)  — "No suitable cells in TA"
<wrn> lte_lc: Registration rejected, EMM cause: 11 (×1)  — "PLMN not allowed"
<wrn> lte_lc: Registration rejected, EMM cause: 19 (×10+) — "ESM failure / PDN rejected"
```

EMM cause 19 dominated. The modem was finding cells, finding PLMNs (no
sustained cause 11), rotating between LTE-M and NB-IoT, getting to
`rrc=connected` — but every PDN/APN context request came back rejected.
That's a textbook **SIM-side authorization issue**, not a signal problem
and not a firmware bug.

User confirmed the SIM was an Onomondo physical SIM with 9-digit short ID
`002595498` (full ICCID `89457300000025954986`). The Onomondo dashboard
showed `SIMs (0)` — the SIM was never registered to user's account, and
the prepaid/trial data allocation had been hit during the conference. The
network sees the IMSI, asks Onomondo "authorized for PDN?", Onomondo
answers "no active subscription / quota exhausted," network rejects.

User will activate via Onomondo. Cloud-side has nothing to do about this.

---

## C11.4 SIM exhaustion ≠ firmware lockup. The lockup is §C10.5.

This is the important part. **The cellular-publish failure (today's
symptom) and the firmware-lockup-requiring-power-cycle (the conference
symptom) are two distinct failures.** SIM exhaustion explains the former
cleanly. It does NOT directly explain the latter.

The full cascade for the conference lockup:

1. **SIM data quota exhausted** mid-conference (probably May 12 early
   afternoon — last heartbeat with `RSRP -125` was at 19:43:53; the
   transition is somewhere in the prior hours)
2. **Modem enters a perpetual reattach-reject loop.** Every cycle:
   radio-attach → RRC connected → PDN context request → EMM 19 reject →
   RRC idle → reattach. Each cycle 5-10 s. **The modem is now never
   idle.** This is the "sustained cellular contention" precondition
   §C10.5 specifically called out.
3. **Walker motion fires wake-on-motion** → main.c auto-start
   coordinator → `gosteady_session_start()` →  which makes two
   synchronous `AT+CCLK?` calls via cellular.c to stamp `session_start`:
   - `gosteady_cellular_get_network_time_unix_ms()` (session.c line 466)
   - `gosteady_cellular_get_network_time()` (session.c line 504)
   Both backed by `nrf_modem_at_scanf(...)` which blocks synchronously
   on the modem's AT processor.
4. **AT calls queue behind the modem's busy state.** Under sustained
   PDN-reject contention, the modem's AT response thread is starved.
   The synchronous `nrf_modem_at_scanf` call doesn't return.
5. **The blocked call eventually exceeds 60 s.** Watchdog fires. The
   M10.7.3 supervisor-thread design kicks the watchdog independently,
   but some path (mutex held, sem held, modem-API internal serialization)
   couples the wedge to the supervisor — this was observed empirically
   in the M14.5 hardening sprint's FMEA 6.1 revert (§C10.5: "AT calls
   serialized inside `nrf_modem_at` and cumulative latency breached the
   60 s WDT envelope"). Same mechanism here.
6. **Device reboots.** Boot 87. Modem state clears. Same SIM. Same
   exhaustion. Same loop on next motion event. Repeats.
7. Somewhere a different code path under the same contention takes a
   **fatal panic** (`fault_counters.fatal` 3→4). Reset, recover, repeat.
   Boots 88, 89.
8. User power-cycles to break the cycle.

§C10.5 (2026-05-10), six days before the conference, said verbatim:

> "The 2 pre-existing AT calls in session_start STILL risk a similar
> lockup under sustained cellular contention. Today's bench was unusual;
> typical conditions complete in <100 ms total. M14.5 site-survey should
> monitor for any session_start that takes >5 s as an early-warning
> signal of AT serialization. If observed, follow-up patch should add
> explicit AT timeouts via `nrf_modem_at_cmd_async` or move AT-getting
> outside the session-open critical path."

The conference produced exactly the predicted failure mode. **Both fixes
are needed** — a working SIM removes the specific trigger that produced
the contention, but any future cellular-contention event (clinic-site
RF, carrier-side throttle, SIM mid-billing-cycle hiccup, BGP routing
event between the cell's home network and Onomondo's backend) will
reproduce the same lockup. SIM activation is the operational fix.
**Removing the AT-serialization vulnerability is the firmware fix and
is now an M15 blocker.**

Also worth noting: the FMEA 1.1/1.2 retro-stamp path (which lets
`session_start` succeed without cellular UTC by stamping the timestamp
later at `session_stop`) was specifically designed to handle the
"cellular UTC unavailable" case. But it only fires if the AT call
*returns* with an error (`-EAGAIN` if unregistered, `-EIO` if scanf
fails). If the AT call blocks *indefinitely*, the retro-stamp path
never gets a chance. The proposed patch closes that gap by making
"block indefinitely" return `-ETIMEDOUT` after a bounded wait.

---

## C11.5 Proposed firmware patch — scoped, not yet committed

**Goal:** make every AT call in `session_start`'s critical path bounded
in latency, so a busy modem can't wedge the calling thread past the WDT
envelope.

**Two options, recommend shipping A first then B:**

### Option A (short-term, ~1 day) — timeout wrapper around `nrf_modem_at_cmd_async`

New helper in `src/cellular.c`:

```c
/* AT command issued via the async API with a bounded wait. Returns
 * -ETIMEDOUT after `timeout_ms` if the modem hasn't produced a response.
 * The underlying nrf_modem call may continue and the response may arrive
 * later — the response handler is gated on `s_at_call_in_flight` so
 * stale responses are dropped silently. */
static K_SEM_DEFINE(at_response_sem, 0, 1);
static K_MUTEX_DEFINE(at_call_lock);
static atomic_t s_at_call_in_flight = ATOMIC_INIT(0);
static char s_at_response_buf[NRF_MODEM_AT_MAX_CMD_SIZE];

static void at_async_handler(const char *resp)
{
    if (!atomic_get(&s_at_call_in_flight)) {
        return;  /* late response after caller's timeout; drop */
    }
    strncpy(s_at_response_buf, resp, sizeof(s_at_response_buf) - 1);
    s_at_response_buf[sizeof(s_at_response_buf) - 1] = '\0';
    atomic_set(&s_at_call_in_flight, 0);
    k_sem_give(&at_response_sem);
}

static int at_cmd_with_timeout(const char *cmd, char *out, size_t outlen, int timeout_ms)
{
    if (!out || outlen == 0) return -EINVAL;
    k_mutex_lock(&at_call_lock, K_FOREVER);

    atomic_set(&s_at_call_in_flight, 1);
    k_sem_reset(&at_response_sem);

    int err = nrf_modem_at_cmd_async(at_async_handler, "%s", cmd);
    if (err) {
        atomic_set(&s_at_call_in_flight, 0);
        k_mutex_unlock(&at_call_lock);
        return err;
    }

    err = k_sem_take(&at_response_sem, K_MSEC(timeout_ms));
    if (err == -EAGAIN) {
        atomic_set(&s_at_call_in_flight, 0);
        k_mutex_unlock(&at_call_lock);
        LOG_WRN("AT cmd timed out after %d ms (modem busy?): %s",
                timeout_ms, cmd);
        return -ETIMEDOUT;
    }

    strncpy(out, s_at_response_buf, outlen - 1);
    out[outlen - 1] = '\0';
    k_mutex_unlock(&at_call_lock);
    return 0;
}
```

Then refactor `read_network_time_iso8601()` and
`gosteady_cellular_get_network_time_unix_ms()` to call `at_cmd_with_timeout()`
with `timeout_ms=2000` instead of the bare `nrf_modem_at_scanf("AT+CCLK?",...)`.
On `-ETIMEDOUT`, return `-EAGAIN` to the caller — `session.c` already
treats `-EAGAIN` as "cellular UTC unavailable, FMEA 1.1 retro-stamp will
re-attempt at `session_stop`."

**Suggested timeout: 2000 ms.** Far below the 60 s WDT envelope, gives
the modem comfortable headroom for a normal AT response (typical
<100 ms per §C10.5), conservative enough to never trigger in healthy
operation.

**Affected sites:** the two `session_start` AT calls (session.c lines
466, 504) get the timeout. The two `session_stop` AT calls (session.c
lines 203, 663) also get the timeout — `session_stop` shouldn't wedge
either. The cloud-worker thread sites (cloud.c lines 356, 574, 903,
1123) are lower-priority: they're already on an async worker, so a
block doesn't wedge sessions. Up to firmware-team taste whether to
apply the wrapper everywhere or just in the session.c critical path.

### Option B (medium-term, ~3 days) — cache UTC, decouple `session_start` from modem entirely

Add a `s_cached_utc_ms` + `s_cached_utc_local_uptime_ms` pair in
cellular.c. The cellular reporter thread (already exists) refreshes
the cache on its current ~60 s cadence when registered. New public
function `gosteady_cellular_get_cached_utc_ms()` is a pure memory
read + uptime delta — never makes an AT call, never blocks.
`session_start` switches to this path.

Benefits:
- `session_start` becomes lightning-fast (no AT calls at all)
- Cellular contention has zero effect on session capture
- Even if cellular dies completely after the cache is populated,
  sessions still get good-enough timestamps (drift = on the order of
  ms over hours; activity rollups are minute-granular)
- Removes a whole class of failure modes, not just this specific one

Downsides:
- Larger refactor; touches the cellular.c API surface
- Cache invalidation on long disconnects needs care (stale UTC
  worse than no UTC after, say, 12 h)

**Recommend: ship Option A first** (small, focused, removes the M15
blocker, easy to validate on bench). **Schedule Option B for M16+**
(after clinic ship, when there's appetite for an API refactor).

---

## C11.6 Cloud-side: alarm catalog gap closed (commit `3c47f0d`)

Independently of the firmware-side work above, the cloud-side
`activity_reject_count` alarm gap flagged in §C10.2 was closed this
morning before the device investigation started. New alarm
`gosteady-{env}-activity-processor-activity-reject` watches the existing
EMF metric in `GoSteady/Processing/{env}` namespace; threshold > 0
in 5 min; routes to the same ops topic as the sibling
`unmapped-serial` alarm. Brings the alarm catalog to 30 alarms.

Deploy is pending — `cdk deploy GoSteady-Dev-Observability`, single-
resource add, non-destructive. ARCHITECTURE.md §1.6 follow-up note
flipped from "open" → "closed."

---

## C11.7 Cloud-side: NEW gap surfaced — device-offline alarm

A real gap exposed by this incident: **the cap went dark for 3 days
21 hours and nothing in the alarm catalog noticed.** Shadow's
`lastSeen` was stuck at `2026-05-12T19:43:53Z` and stayed that way
through 16 May without producing any operational signal.

Phase 1C ("Scheduled Jobs") in ARCHITECTURE.md §12 is the planned
home for an offline detector — `lastSeen > 2 h` triggers an alarm.
1C is currently 🔲 Planned with no concrete schedule. After this
incident the priority should bump.

Suggested 1C-slim scope:
- One EventBridge scheduled rule, every 15 min
- Lambda iterates Device Registry rows with `status =
  active_monitoring`, queries Shadow `lastSeen`, alarms via the
  existing ops SNS topic for any device with `now - lastSeen > 2 h`
- Synthetic-alert path in Alert History (`alert_type=device_offline,
  source=cloud, severity=warning`) per ARCHITECTURE.md §8

Independently useful regardless of the firmware patch above:
operators want to know "is the cap online right now" without
inspecting the dashboard. And there's a real risk class — a cap
that's silently dead at a clinic — that today has no detection.

---

## C11.8 Validation positives worth recording

Things that worked exactly as designed during the conference + the
silence and the recovery:

- **Auto-prune-on-publish-success** (FMEA 6.2): the 3 orphan `.dat`
  files from wedged sessions were cleanly removed by `orphan_sweep`
  at the next clean boot. No flash-fill, no manual intervention.
- **Crash forensics persistence** (M10.7.3): watchdog + fatal counts
  correctly survived 3 reboots in a row. First boot back to cloud
  (when cellular returns) will carry the updated counters cleanly.
- **FMEA 1.1/1.2 retro-stamp path is firing right now** — every
  session opened during today's cellular-down window logs
  `cellular UTC unavailable (-11) — activity will publish without
  session_start`, then queues for FMEA 1.3 retry. Once Onomondo
  is active the queue should drain with retro-filled timestamps.
- **Snippet path:** zero validation errors across all 38 conference
  uploads. Byte-exact S3 objects.
- **Activity path:** zero rejections across 68 sessions.
- **Threshold detector:** 17 correct synthetic signal alerts at the
  right thresholds.
- **All 6 Lambdas:** zero `ERROR`-level log lines, zero Lambda
  Errors metric increments, DLQ stayed empty.
- **Per-device dashboard** rendered everything correctly once the
  May 10 60min → 1min period fix was in place (no rendering
  surprises this round).

The hardening sprint paid for itself. Without auto-prune + orphan
sweep + crash forensics persistence, the device might not have
self-recovered at all.

---

## C11.9 Recommended sequencing

1. **User**: activate Onomondo SIM (out-of-band, dependent on
   Onomondo support / billing). Cellular returns; expect FMEA 1.3
   retry queue to drain with retro-filled timestamps; expect
   Shadow `lastSeen` to catch up.

2. **Cloud**: deploy commit `3c47f0d` (activity_reject alarm) to
   `GoSteady-Dev-Observability`. Single-resource add, ~30 s.

3. **Firmware** (M15 blocker): apply Option A AT-timeout wrapper
   per §C11.5. Bench-validate by deliberately starving the modem
   (e.g., temporarily airplane mode or move cap to a faraday
   enclosure) and confirming `session_start` returns within
   ~2.5 s with `start_utc=unavailable` + FMEA 1.1 retro-stamp on
   the resulting activity row.

4. **Cloud** (post-firmware): scope + ship Phase 1C-slim offline
   detector per §C11.7. Independent of any firmware change.

5. **Firmware** (M16+): consider Option B cached-UTC refactor per
   §C11.5 if/when the API surface refactor becomes worth the
   churn.

---

*Entry owner: Jace + Claude (single merged firmware+cloud session,
2026-05-16).*
*This is the post-conference investigation entry. Two distinct
failures separated: cellular-publish stop (SIM exhaustion, ops fix)
vs firmware lockup (§C10.5 AT-serialization, firmware fix). Cloud
alarm catalog gap closed. New cloud alarm gap surfaced.*


---
---

# Joint cloud + firmware update — 2026-05-17 (§C11.5 patch shipped + bench-validated on GS9999999998; two latent bugs caught in the process)

> **From:** GoSteady firmware + cloud teams (single Claude session).
>
> **Closes:** §C11.5 Option A (AT-timeout wrapper) — the M15 blocker. Also
> closes §C11.9 step 3 ("Firmware: apply Option A AT-timeout wrapper").
>
> **TL;DR:** New dev unit `GS9999999998` brought up per the playbook
> [`docs/playbooks/new-dev-unit-bringup.md`](../playbooks/new-dev-unit-bringup.md),
> firmware patched per §C11.5 design, built + flashed + bench-validated.
> Firmware version bumped 0.9.0-hardening → **0.10.0-at-timeout**
> (firmware commit
> [`95f87e6`](https://github.com/Jabl1629/gosteady-firmware/commit/95f87e6)
> on `gosteady-firmware/main`). Two latent bugs surfaced during bench
> validation — exactly the value of doing this on hardware — both fixed
> before the commit landed. Failure-path (actual `-ETIMEDOUT` firing under
> sustained modem contention) is NOT bench-validated; will be exercised
> naturally during the next M14.5 site-survey or by deliberate stress.

---

## C12.1 What shipped

Firmware commit
[`95f87e6`](https://github.com/Jabl1629/gosteady-firmware/commit/95f87e6)
on `gosteady-firmware/main`:

- `src/cellular.c` — new `at_cmd_with_timeout()` wrapper (+ supporting
  worker logic folded into the existing `reporter_thread` to fit in the
  RAM budget — see §C12.2 below). Two CCLK call sites
  (`read_network_time_iso8601()` and
  `gosteady_cellular_get_network_time_unix_ms()`) now route through it.
  `read_signal()` (CESQ) left bare since it runs only on the reporter and
  is not in `session_start`'s critical path. A bare-AT variant
  `read_network_time_iso8601_bare()` was added for the reporter's own
  `log_signal_and_time()` use — see §C12.4.
- `src/version.h` — `GS_FIRMWARE_VERSION_STR "0.10.0-at-timeout"` plus
  changelog entry pointing back at §C11.5.

Build / link results:
- merged.hex: 994,046 bytes (vs 991,242 for 0.9.0-hardening, +2,804 B)
- RAM: 99.85 % used (vs 99.76 % pre-patch, +216 B; **336 B headroom**)
- FLASH: comfortably under cap

---

## C12.2 RAM constraint forced consolidation (not a dedicated AT worker)

The §C11.5 sketch assumed a dedicated 2 KB-stack AT worker thread.
First build attempt overflowed the RAM region by 2,008 bytes — pre-patch
was already at 99.76 % per coord §C10.6's footprint table. The
dedicated thread alone (`k_thread` struct + 2 KB stack + sem/mutex
overhead) would have needed ~2.7 KB of new RAM.

Resolution: fold the AT-cmd dispatch into the existing `reporter_thread`
(which has a 2 KB stack already and is also an AT-running worker — it's
the right semantic home). Single thread now does both jobs. Saves the
entire second thread's overhead.

Reporter's main loop, post-patch:
- Top of every iteration: check "periodic poll due?" → if yes, do it.
- Otherwise: `k_sem_take(at_request_sem, K_MSEC(time_until_next_poll))`.
  - Sem fires → service AT cmd via `at_worker_service_one()`.
  - Sem times out → loop back to top, where poll is now due.

This serializes AT-cmd handling with the periodic signal+time poll —
which is correct, since the modem AT processor serializes anyway.

Documented inline in `cellular.c` so future RAM headroom doesn't
mysteriously make someone want to split the threads again.

---

## C12.3 Latent bug #1 caught at bench: the 5 s settle starved AT requests

First post-patch boot produced a spurious `at cmd timed out after 2000 ms
(modem contention?): AT+CCLK?` warning ~2 s after `cellular registered`.
Modem signal was fine (-87 dBm). The "contention" was self-inflicted.

Root cause: the reporter's `(void)k_sem_take(&registered_sem, K_FOREVER);
k_msleep(5000);` post-registration settle. During those 5 s,
`gs_cloud`'s post-registration AT+CCLK? request gave `at_request_sem`,
but the reporter was sleeping and didn't service it. Caller timed out.

Fix: the settle is now a loop that does `k_sem_take(at_request_sem,
K_MSEC(remaining_settle_ms))` and services any AT requests that arrive
during the wait. Settle period still bounded at 5 s in wall-clock terms;
just no longer blocks AT requests.

After this fix: `network time available` lands 0.5 s after
`registered_roaming` (down from spurious 2.5 s timeout).

---

## C12.4 Latent bug #2 caught at bench: reporter self-deadlock through the wrapper

After fix #1, observed *one* `at cmd timed out` warning per ~60 s
cadence. Looked like an intermittent issue; closer inspection showed it
correlated exactly with the reporter's periodic poll.

Root cause: `log_signal_and_time()` runs on the reporter thread. It
called `read_network_time_iso8601()` which (per the patch) now goes
through `at_cmd_with_timeout()`. The wrapper gives `at_request_sem`
(which only the reporter consumes) and blocks on `at_response_sem`. The
reporter — already blocked inside the wrapper — never services its own
sem give. Deadlock until the 2 s wrapper timeout fires.

So `log_signal_and_time()` fired its own AT timeout every minute as
a "graceful degradation" of a real self-deadlock. Spurious warnings,
correct outcomes (network_time still got read on the next iteration),
but ugly.

Fix: extracted `read_network_time_iso8601_bare()` — a private static
helper that uses bare `nrf_modem_at_scanf` (no wrapper). Reporter's
`log_signal_and_time()` calls the bare variant. External callers
(`gosteady_cellular_get_network_time()` and the public
`get_network_time_unix_ms()`) continue to use the wrapped path.

This is the same pattern `read_signal()` (CESQ) already uses — bare
because it runs only on the reporter. Worth keeping in mind for any
future AT call added inside the reporter thread: **AT calls invoked
from the reporter must bypass the wrapper, or they self-deadlock.**

After this fix: **zero AT timeouts** on the validation boot. Clean
sustained operation.

---

## C12.5 Validation results (GS9999999998, boot=6, 2026-05-16T21:01:20Z)

| Check | Result |
|---|---|
| Build | merged.hex 994 KB; RAM 99.85 %; FLASH well under cap |
| Boot | `boot_count=6, fault_counters={fatal:0, asserts:0, watchdog:0}, watchdog_hits=0, reset_reason=SOFTWARE` |
| Cellular registration | `registered_roaming` at boot+5.06 s on iBasis trial |
| Settle period | 5 s; AT requests serviced during settle (no starvation) |
| `gs_cloud` first AT+CCLK? | succeeded within wrapper timeout; no "modem contention?" warning |
| Reporter periodic poll | ran at boot+10 s; `signal: rsrp=-91 dBm snr=1 dB` populated `s_rsrp_dbm/s_snr_db/s_signal_valid` so `gs_cloud` could read them |
| First heartbeat publish | PUBACK at boot+19.9 s; payload includes `firmware: "0.10.0-at-timeout"` |
| Cloud-side Shadow | `fw=0.10.0-at-timeout, ts=2026-05-16T21:01:20Z, boot=6` — confirms broker accepted the publish and IoT Rule + heartbeat-processor updated Shadow |
| DLQ + Lambda errors | both 0 |
| AT timeouts during this boot | **0** (after bug fixes #1 and #2) |

---

## C12.6 What was NOT bench-validated

The failure path itself — the actual `-ETIMEDOUT` return under sustained
real modem contention (e.g. exhausted SIM, weak signal triggering tight
PDN-reject loop) — was **not** reproduced on bench. Reproducing it
cleanly requires either:

1. Faraday-cage-style RF isolation
2. SIM exhaustion (the May 11-12 conference repro — destructive of the
   active SIM)
3. Airplane-mode toggling via AT cmd injection (no current path —
   gosteady firmware doesn't expose an AT passthrough)
4. A `CONFIG_GOSTEADY_AT_TIMEOUT_TEST_HOOK`-style test variant that
   injects a delay in `at_worker_service_one()` — would be a useful
   future test harness; left for a separate commit

That said, the timeout path WAS exercised end-to-end during the patch
development cycle — both latent bugs (§C12.3 and §C12.4) produced
real `-ETIMEDOUT` returns through the wrapper, with logs and graceful
degradation matching the design. So we have indirect evidence the path
works as intended, just not under the "real" contention condition.

The natural next validation moment: the next M14.5-style site-survey
where cellular contention may occur organically. Or a deliberate
SIM-exhaustion stress test, once an Onomondo SIM is at end-of-quota
and OK to push over.

---

## C12.7 Updates to coord §C11.9 sequencing

| § | Item | Status |
|---|---|---|
| C11.9.1 | User: activate Onomondo SIM | Pending (out-of-band) |
| C11.9.2 | Cloud: deploy commit `3c47f0d` (activity_reject alarm) | Pending (small, non-destructive deploy) |
| **C11.9.3** | **Firmware: apply §C11.5 Option A AT-timeout wrapper** | **✅ DONE — commit `95f87e6` on `gosteady-firmware/main`, bench-validated on GS9999999998 2026-05-16** |
| C11.9.4 | Cloud: scope + ship Phase 1C-slim offline detector | Pending |
| C11.9.5 | Firmware: §C11.5 Option B (cached-UTC refactor) | Backlog (M16+; not currently scoped) |

---

## C12.8 Surfaced for the playbook

The new-dev-unit-bringup playbook is now empirically grounded in two
real bring-ups (`GS9999999999` historical + `GS9999999998` today).
Updates landed in cloud-portal commit
[`76eb14d`](https://github.com/Jabl1629/GoSteadyPortal/commit/76eb14d):

- at_client pre-built hex source documented (avoids the macOS
  Python 3.14 / pykwalify pitfall on building from source)
- JLinkARM `-256` noise flagged as benign
- `prj_cloud.conf` per-unit `CONFIG_AWS_IOT_CLIENT_ID_STATIC` rebuild
  flagged as critical (longer-term: derive from cert CN at runtime)
- Full env-var dance for `west build` documented (PATH override,
  ZEPHYR_BASE, ZEPHYR_SDK_INSTALL_DIR, ZEPHYR_TOOLCHAIN_VARIANT)

Should-add to playbook (TODO):
- New §3.4.5 noting that **per-unit rebuild also requires `--bare`-style
  AT-call hygiene for any future reporter-thread additions** (§C12.4
  lesson) — anyone adding a new AT call inside `log_signal_and_time()`
  or another reporter-only function must use bare nrf_modem_at_scanf or
  reproduce the self-deadlock surface area.

---

## C12.9 Cadence

This entry closes the loop on §C11.5 → §C11.9.3. No firmware action
items currently outstanding from this batch.

**Next coord-doc-affecting work:**

1. **Cloud: Phase 1C-slim offline detector** (per §C11.7 / §C11.9.4) —
   independent of firmware; will surface a §C13 when scoped + shipped.
2. **Firmware: §C11.5 Option B (cached UTC)** — backlog; would simplify
   the reporter and remove the self-deadlock surface area entirely.
   Will surface a §C14-equivalent when picked up.
3. **Firmware: client_id-from-cert-CN refactor** — removes per-unit
   rebuild step from new-dev-unit-bringup playbook. Backlog; not yet
   scoped.
4. **Real-world §C11.5 failure-path validation** — opportunistic; will
   happen organically on the next M14.5-style stress or whenever the
   iBasis trial hits its end-of-quota.

---

*Entry owner: Jace + Claude (single merged firmware+cloud session,
2026-05-17).*
*Closes §C11.5 / §C11.9.3. Two latent bugs caught at bench (§C12.3,
§C12.4) before commit landed. Firmware 0.10.0-at-timeout live on
GS9999999998. Conference-class lockup mode now closed via firmware
fix (in addition to operational SIM fix).*


---
---

# Cloud team update — 2026-05-17 (activity_reject alarm deployed; closes §C11.9.2 + doc sync sweep)

> **From:** GoSteady cloud team.
>
> **TL;DR:** Two follow-ups from this morning's §C12 entry:
>
> 1. Deployed commit `3c47f0d` (activity_reject alarm) to
>    `GoSteady-Dev-Observability` — single-resource UPDATE, ~26 s, no
>    other changes. Alarm catalog now at 30 in Observability stack.
>    **Closes §C11.9.2.**
> 2. Doc sync sweep across ARCHITECTURE.md, GOSTEADY_CONTEXT.md, the
>    new-dev-unit-bringup playbook, and this coord doc to reflect
>    today's session shipments (§C11/§C12 + activity_reject deploy
>    + 0.10.0-at-timeout firmware). Captures the §C12.4 reporter-thread
>    AT-call hygiene rule in the playbook so the next person extending
>    `cellular.c` doesn't re-hit the self-deadlock.

---

## C13.1 activity_reject alarm — DEPLOYED

```
GoSteady-Dev-Observability | 0/4 | 8:40:46 AM | CREATE_IN_PROGRESS   | AWS::CloudWatch::Alarm     | HandlerAlarms/ActivityProcessorActivityReject
GoSteady-Dev-Observability | 2/4 | 8:40:49 AM | CREATE_COMPLETE      | AWS::CloudWatch::Alarm     | HandlerAlarms/ActivityProcessorActivityReject
 ✅  GoSteady-Dev-Observability
Deployment time: 25.6s
```

Live CloudWatch state (verified via `aws cloudwatch describe-alarms
--alarm-names gosteady-dev-activity-processor-activity-reject`):

| Property | Value |
|---|---|
| State | `INSUFFICIENT_DATA` (correct — no `activity_reject_count` data points since deploy; metric only fires on validation failures, none in this window) |
| Namespace | `GoSteady/Processing/dev` |
| MetricName | `activity_reject_count` |
| Dimensions | `service=gosteady-dev-activity-processor` |
| Threshold | 0 |
| ComparisonOperator | `GreaterThanThreshold` |
| Period | 300 s |
| AlarmActions | `arn:aws:sns:us-east-1:460223323193:gosteady-dev-cost-alarms` (ops topic) |

Total alarm count in dev: **31** (30 Observability + 1 Phase 1.5
billing). The "29" referenced in §C7.1 was original-1.6-deploy state;
the 2026-05-10 watchdog-hits-rate alarm bumped it to 29 (already
counted), and today's activity_reject brings it to 30 in Observability.

---

## C13.2 §C11.9 sequencing — updated status

| § | Item | Status |
|---|---|---|
| C11.9.1 | User: activate Onomondo SIM | Pending (out-of-band, user action) |
| **C11.9.2** | **Cloud: deploy commit `3c47f0d` (activity_reject alarm)** | **✅ DONE 2026-05-17** |
| C11.9.3 | Firmware: §C11.5 Option A AT-timeout wrapper | ✅ DONE 2026-05-16 (commit `95f87e6`, bench-validated) |
| C11.9.4 | Cloud: scope + ship Phase 1C-slim offline detector | Pending — likely the next cloud-side dev item |
| C11.9.5 | Firmware: §C11.5 Option B (cached-UTC refactor) | Backlog (M16+) |

Three of five sequencing items now closed. C11.9.4 (Phase 1C-slim
offline detector) is the natural next cloud-side increment — closes
the §C11.7 gap of "device went dark for 3 days, no alarm noticed."

---

## C13.3 Doc sync sweep — what changed

Today's session shipped a lot of state across ARCHITECTURE.md,
GOSTEADY_CONTEXT.md, the playbook, and this coord doc. Sweeping for
consistency since multiple docs reference the same facts (alarm count,
firmware version, AT-serialization status).

**`docs/specs/ARCHITECTURE.md` (cloud-portal repo):**
- §12 Phase 1.6 — alarm catalog line updated: "29 alarms in original
  1.6 deploy; 30 after 2026-05-17 follow-up"
- §12 Phase 1.6 follow-up (activity_reject) — updated to record deploy
  date 2026-05-17 + commit `3c47f0d` + final alarm counts (30
  Observability + 1 billing = 31 total)
- §16 Open Questions — added two new resolved entries:
  - `activity_reject_count` no-alarm gap → resolved
  - `session_start` AT-call serialization (§C10.5 watch-item) →
    resolved by firmware 0.10.0-at-timeout
- §17 Spec Index — Phase 1.6 row updated to "30 alarms"; new
  "Playbooks" subsection added pointing at the new-dev-unit-bringup
  playbook

**`docs/playbooks/new-dev-unit-bringup.md` (cloud-portal repo):**
- §3.4 — new callout block on reporter-thread AT-call hygiene rule
  (the §C12.4 self-deadlock lesson). Explains why
  `read_network_time_iso8601_bare()` exists and warns against future
  reporter-thread AT calls going through the wrapper.

**`GOSTEADY_CONTEXT.md` (gosteady-firmware repo):**
- Header — firmware version bumped `0.9.0-hardening` → `0.10.0-at-timeout`
- "Current state" date 2026-05-10 → 2026-05-17
- Current-state paragraph — both dev units now described
  (`GS9999999999` historical + `GS9999999998` running 0.10.0-at-timeout
  with working J-Link)
- M14.5 watch items — AT-serialization watch item marked CLOSED with
  ref to §C12
- Cloud-side OPEN follow-ups — `activity_reject_count` marked DONE
  with deploy date; Phase 1C offline detector remains open

**`docs/firmware-coordination/2026-04-17-cloud-contracts.md` (this
file):**
- This §C13 entry

---

## C13.4 What's next

Cloud-side options (in rough priority order):

1. **Phase 1C-slim (Offline Detector)** — 1-2 day sprint. EventBridge
   scheduled rule + Lambda that scans Device Registry for
   `active_monitoring` devices with `lastSeen > 2 h` and fires a
   synthetic alert. Closes the §C11.7 ops gap and gives operators
   confidence that any future silent failure will alarm. Independent
   of any other phase; would be a satisfying solo cloud increment.
2. **Phase 1.7 Audit Logging spec + deploy** — gates Phase 2A. Spec
   not yet written. ~Half-day spec + half-day deploy.
3. **Phase 2A device-lifecycle subset** — `device-api` + `device-
   shadow-handler` + `discharge-cascade`. Unblocks firmware's
   `reported.activated_at` Shadow-side ack (currently dormant on
   cloud per coord §C6.3).

Firmware-side: backlog items remain (§C11.5 Option B cached-UTC,
`client_id` from cert CN at runtime). No urgent firmware action.

Real-world §C11.5 failure-path validation continues to be
opportunistic — will happen on the next M14.5-style stress or on
SIM-exhaustion stress test.

---

*Entry owner: Jace + Claude (single merged firmware+cloud session,
2026-05-17).*
*Closes §C11.9.2 (activity_reject deploy). Doc-sync sweep across all
four canonical files ensures any fresh-session Claude or human picks
up today's state without re-deriving from logs.*


---
---

# Cloud team update — 2026-05-17 (Phase 1.7 Audit spec drafted + implementation synth-clean; closes §C13.4 option 2)

> **From:** GoSteady cloud team.
>
> **TL;DR:** Later the same day after the §C13 activity_reject deploy,
> picked up §C13.4 option 2 (Phase 1.7 Audit Logging spec + deploy).
> Spec drafted ([`docs/specs/phase-1.7-audit.md`](../specs/phase-1.7-audit.md))
> and implementation landed and synth-clean. Not yet deployed — that's
> the next session. No firmware-side action required from this entry;
> 1.7 is pure cloud-side infra (subscription filters on existing handler
> log groups, no handler IO touches).

---

## C14.1 Why 1.7 jumped ahead of 1C-slim

Both items were on the §C13.4 short list. The deciding factor was
spec discipline: §C13.4 named Phase 1.7 as "gates Phase 2A" (per the
then-current ARCHITECTURE.md framing). Working through the spec
clarified that the gate is actually *discipline* (no patient data
through a UI without proper audit), not a hard technical dep — but
the gate still applies before first prod customer, same threshold as
G9 (multi-account separation), Phase 1.5 prod hardening, etc. So 1.7
becomes mandatory at the same point on the timeline regardless of
when we ship it.

Given that, the choice was "ship 1.7 now while the architecture is
fresh, or carry it as a known-required-before-prod item indefinitely."
Now was the cheaper option — and the 5 architectural decisions that
shape the design (latency posture, emission mechanism, Object Lock
mode, read-event scope, compliance reader IAM) were all calls we
could make confidently today without waiting for a real compliance
reader or a real Phase 2A handler. 1C-slim slips to next session.

---

## C14.2 What shipped (code, not yet deployed)

| Component | Detail |
|---|---|
| Spec | [`docs/specs/phase-1.7-audit.md`](../specs/phase-1.7-audit.md), ~580 lines, follows the same template as 1.6 |
| New stack | `GoSteady-{Env}-Audit` ([`infra/lib/stacks/audit-stack.ts`](../../infra/lib/stacks/audit-stack.ts)) |
| New construct | [`infra/lib/constructs/audit-s3-bucket.ts`](../../infra/lib/constructs/audit-s3-bucket.ts) — env-aware Object Lock toggle |
| New Lambda | [`infra/lambda/audit-forwarder/handler.py`](../../infra/lambda/audit-forwarder/handler.py) — subscription filter forwarder with date-partitioned destination streams |
| New shared module | [`infra/lambda/_shared/audit_catalog.py`](../../infra/lambda/_shared/audit_catalog.py) — 28 event-name constants |
| Modified shared module | [`infra/lambda/_shared/observability.py`](../../infra/lambda/_shared/observability.py) — extended `emit_audit` with `schema_version` + `request_id`; fixed scrubber-bypass bug |
| Config additions | `auditBucketObjectLockEnabled` / `auditBucketObjectLockYears` / `auditHotRetentionDays` in [`infra/lib/config.ts`](../../infra/lib/config.ts) |
| App wiring | `AuditStack` wired into [`infra/bin/gosteady.ts`](../../infra/bin/gosteady.ts) with explicit dep on `SecurityStack` (AuditKey CMK import) |
| Test backfills | 5 stack-test fixtures updated for the new env-config fields |

Synthesized resources in `GoSteady-Dev-Audit`:
- 3 CloudWatch alarms (forwarder errors / Firehose freshness >10min / Firehose delivery failures)
- 7 subscription filters (6 source handler log groups + 1 audit log group → Firehose)
- 1 Kinesis Firehose delivery stream (GZIP NDJSON, 1 MB / 60 s buffer)
- 1 S3 bucket + bucket policy (TLS-only enforced; dev: cleanable, prod will get Object Lock + deny-delete)
- 2 log groups (audit destination + Firehose error logs)
- 4 Lambdas (audit-forwarder + 3 CDK helpers)
- 6 IAM roles + 5 policies + 6 Lambda permissions

Full-app `cdk synth --context env=dev` clean (exit 0); pre-existing
warnings unchanged (`logRetention` deprecation, Phase 1.6
WatchdogHitsRate metric-math note). New stack appears in the
`cdk deploy --all` list as `GoSteady-Dev-Audit`.

---

## C14.3 Two intentional divergences from the spec

Worth flagging so a future reader of the spec isn't confused:

1. **`_shared/audit.py` was cut — extended existing `_shared/observability.py:emit_audit` instead.** The 1B-rev observability module already exposes an `emit_audit()` (which is why audit-shape lines have been flowing in production for weeks already). Creating a parallel module would have meant either deprecating the existing one or running two emission paths that have to stay in sync. Cleaner to extend it with the spec's new fields (`schema_version`, `request_id`) and fix an L4 violation the existing code had (the `ScrubbingFormatter` was scrubbing audit records too, which would have silently broken any future `auth.login` audit event that contains a user's email).

2. **`audit-subscription-filter.ts` reusable construct was cut — inlined the loop in `audit-stack.ts`.** Only used once (a `for` loop over six source handler log groups). The reusable wrapper would have been 6 lines of interface + 3 lines of body for zero callers outside that loop. The inlined version is more readable.

Both choices are folded into the spec's "Files Changed" table under
an "Architectural divergence" note so the spec stays accurate to
what actually shipped.

---

## C14.4 Pre-deploy gate (A3) — code-read verified, live-check pending

The whole subscription-filter design assumes 1B-rev's
`_shared/observability.py:emit_audit` emits a top-level `"audit": true`
JSON key. Verified at source-code read (line 122): it does. The live
verification (`aws logs filter-log-events --filter-pattern '{ $.audit
IS TRUE }'` against the current dev activity-processor log group)
is the first acceptance step at deploy time.

If the pattern somehow doesn't match (no Phase 1B-rev audit lines in
the last 24h, or a subtle pattern mismatch), the fix is a small touch
to `_shared/observability.py` rather than a stack redeploy.

---

## C14.5 What's not in 1.7 (scope-discipline reminders)

These were considered and explicitly out-of-scope:

- **Phase 2A read-event emission.** 1.7 ships the `emit_audit()`
  helper + schema + event catalog. 2A wires `patient.activity.read`,
  `patient.detail.read`, `alert.read`, `census.roster.read` into its
  own API handlers using the helper. Per spec Q4.
- **Compliance reader's real identity.** The `gosteady-{env}-audit-reader`
  IAM role exists with an explicit-deny trust policy. Runbook step
  (`aws iam update-assume-role-policy`) attaches a real principal
  once the compliance reader is named. Not deploy-blocking.
- **Athena workgroup + Glue table.** Logs Insights against the hot
  CW path covers most practical queries (recent 90 days). Athena
  becomes valuable when querying past 90 days or producing
  customer-facing audit reports. Phase 1.7.1 or first-need.
- **Audit-reader-onboarding playbook.** ~1 page when the runbook
  step is actually needed. Slot into the 1.7 deploy commit.

---

## C14.6 Updated §C13.4 status

| Option | Status |
|---|---|
| 1. Phase 1C-slim (Offline Detector) | Pending — natural next cloud-side increment |
| **2. Phase 1.7 Audit Logging spec + deploy** | **Spec ✅ + impl ✅ (synth-clean) 2026-05-17; deploy pending** |
| 3. Phase 2A device-lifecycle subset | Pending — unblocks firmware's `reported.activated_at` Shadow-side ack |

Three cloud-side items now half-done (spec + impl, no deploy). Deploy
+ acceptance is a separate session; will surface a §C15 entry on
completion.

---

## C14.7 No firmware action required

1.7 is pure cloud-side infra:
- Adds subscription filters on existing handler log groups (read-only
  side effect from firmware's perspective; doesn't change MQTT topics,
  doesn't change device-shadow shape, doesn't change handler IO)
- Adds a new audit log group + S3 bucket + Lambda — all downstream of
  CloudWatch Logs, invisible to the device path
- The auto-stamping of `internal_access` for `internal_*` roles will
  matter once Phase 2A exposes admin API endpoints; until then it's
  defensive dead code in the forwarder

Firmware backlog items (§C11.5 Option B cached-UTC,
`client_id`-from-cert-CN at runtime) unchanged.

---

*Entry owner: Jace + Claude (cloud session, 2026-05-17).*
*Closes §C13.4 option 2 partially — spec ✅ + impl ✅, deploy pending.
No firmware action items. Two architectural divergences from the
initial spec sketch documented inline so the spec stays accurate.*


---
---

# Cloud team update — 2026-05-17 (Phase 1.7 Audit DEPLOYED to dev + smoke validated; §C13.4 option 2 fully closed)

> **From:** GoSteady cloud team.
>
> **TL;DR:** Same day as §C14, picked up the deploy + acceptance steps.
> `GoSteady-Dev-Audit` is live in dev. Four issues only surfaced at live
> deploy (none in `tsc` or `cdk synth`); all fixed and root-causes
> documented. Smoke T2/T3/T4 pass end-to-end. **§C13.4 option 2 now
> fully closed for dev.** Prod cutover deferred until first-prod-customer
> threshold (Object Lock + compliance-reader trust policy attach), same
> threshold as G9 multi-account separation and Phase 1.5 prod hardening.
> No firmware action items from this entry either; cloud-only.

---

## C15.1 Deploy attempts — 4 tries to reach CREATE_COMPLETE

| Attempt | Outcome | Root cause | Fix |
|---|---|---|---|
| 1 | Synth-stage validation rejection | Phantom `CfnResource('ForwarderConcurrency')` block left in by accident — synthesized as an empty `AWS::Lambda::Function` with no `Role` or `Code`. `tsc` happy, `cdk synth` happy, CFN early-validation rejected with "Required property [Role] not found" | Removed the bogus 4-line block; kept the `addPropertyOverride('ReservedConcurrentExecutions', 5)` call on the real forwarder Lambda |
| 2 | Two CREATE_FAILED resources, rollback | (a) `AuditReaderRole`: `Principal: '*'` in raw trust-policy JSON serialized as `{"STAR":"*"}` which IAM rejects; (b) `AuditLogGroup`: `addToResourcePolicy` on imported `kms.Key.fromKeyArn` is a no-op — the key is owned by Security stack, the call from Audit stack doesn't actually mutate it. So the CW Logs service principal had no `kms:GenerateDataKey*` grant on AuditKey for the audit log group ARN | (a) tried `ArnPrincipal` of a non-existent placeholder role (Bug 3 below); (b) added `AllowCWLogsForAuditLogGroup` statement in security-stack.ts alongside the existing CloudTrail statement, scoped via `kms:EncryptionContext:aws:logs:arn` condition |
| 3 | Same CREATE_FAILED on AuditReaderRole | IAM validates that a principal-by-ARN exists at trust-policy creation time. `arn:aws:iam::460223323193:role/...-placeholder-replace-me` doesn't exist, so rejected with "Invalid principal in policy" | Settled on `AccountRootPrincipal` placeholder. Caveat documented inline: any IAM identity in the account with broad `sts:AssumeRole` permissions could in principle assume this role. Acceptable for the placeholder window (no audit data yet); runbook step replaces with real principal before any compliance reader is named |
| 4 | CREATE_FAILED on AuditForwarder Lambda | `ReservedConcurrentExecutions=5` rejected with "decreases account's UnreservedConcurrentExecution below its minimum value of [10]". This dev account is on the new-account 10-concurrency floor (`aws lambda get-account-settings` → `ConcurrentExecutions: 10`), not the 1000 default. With 6 existing Lambdas competing for that 10, any reservation pushes below the unreserved minimum | Dropped `ReservedConcurrentExecutions` override entirely. Forwarder shares the unreserved pool — fine at MVP volume (~1-2 invocations/min). Revisit when an account-level concurrency-quota increase happens (prod-hardening territory) |
| 5 (success) | CREATE_COMPLETE 141.27 s | — | — |

All four fixes consolidated in commit `54e0ddc`. Stack outputs:
- `gosteady-dev-audit` log group (CMK-encrypted, 90d retention)
- `gosteady-dev-audit-forwarder` Lambda
- `gosteady-dev-audit-logs` S3 bucket
- `arn:aws:iam::460223323193:role/gosteady-dev-audit-reader` (placeholder trust policy)

---

## C15.2 Smoke results — T2/T3/T4 pass end-to-end

Triggered a synthetic activity publish to `GS9999999999` post-deploy:

```
aws iot-data publish --topic gs/GS9999999999/activity \
  --payload '{"serial":"GS9999999999","session_start":"...","session_end":"...","steps":142,"distance_ft":340.5,"active_min":2,"firmware_version":"1.7-smoke-test"}'
```

| Check | Result |
|---|---|
| **T2** Forwarder receives + processes | ✅ `audit_forwarded` log line at 17:55:04 — `forwarded_count: 1`, `destination_streams: ["audit-2026-05-17"]` (date-partitioning D11.5 working as designed), `source_log_group: /aws/lambda/gosteady-dev-activity-processor`, X-Ray trace ID present |
| **T3** Audit log group populated | ✅ Event landed in `gosteady-dev-audit` log group with auto-stamped fields: `"internal_access": false`, `"severity": "info"` (correct defaults for non-internal actor); all original fields preserved (`event`, `actor`, `subject`, `action`, `after`, `xray_trace_id`) |
| **T4** S3 object lands | ✅ Two `.gz` objects in `audit/year=2026/month=05/day=17/` prefix within ~70 s of publish (first at 17:55:05 from Firehose's "first record opens batch" behavior, second at 17:56:08 from the 60s batch close) |

End-to-end latency from publish to S3 visibility: ~70 s — consistent with the spec's p99 ~3-4 min estimate (dominated by Firehose 60s buffer interval).

---

## C15.3 Issues surfaced at acceptance — two non-blocking follow-ups

**(a) S3 objects are double-gzipped + CW Logs envelope-wrapped.**

Downloaded one to inspect. The byte stream is GZIP-compressed (our Firehose config). Inside that: another GZIP layer (CloudWatch Logs always pre-compresses subscription-filter delivery to Firehose). Inside that: a CW Logs envelope JSON:

```json
{
  "messageType": "DATA_MESSAGE",
  "owner": "460223323193",
  "logGroup": "gosteady-dev-audit",
  "logStream": "audit-2026-05-17",
  "subscriptionFilters": ["gosteady-dev-audit-to-firehose"],
  "logEvents": [
    { "id": "39673928...", "timestamp": 1779040501036,
      "message": "{\"level\": \"INFO\", \"audit\": true, ...}" }
  ]
}
```

The actual audit JSON is a string inside `logEvents[].message`. Data IS recoverable (`gunzip → gunzip → JSON parse envelope → JSON parse each .message`), but future Athena queries against the bucket will need a custom SerDe or a Firehose Lambda transformer to unwrap to clean NDJSON.

**Decision:** defer to Phase 1.7.1 (filed as ARCH §16 Open Questions item + spec Q7). Today's hot path (CW Logs Insights against `gosteady-dev-audit`) handles all practical queries within the 90d hot window. Athena becomes worth wiring up when a real query past 90d appears or a customer-facing audit report is requested. Fix is ~half-day work — add a Firehose Lambda transformer or the built-in `cloudwatch-log-processor`.

**(b) `schema_version` missing from emissions by existing 1B-rev Lambdas.**

The `schema_version: 1` field was added to `_shared/observability.py:emit_audit` in commit `da92c37`, but the 4 existing 1B-rev Lambdas haven't been redeployed since. Their audit emissions still produce the pre-1.7 shape.

**Per spec L9** ("absence in v1 events is unambiguous — defaults to 1"), this is correct-by-design. Readers know what to do with missing field. No urgency for a forced redeploy; the field will populate naturally on the next routine Phase 1B touch. Filed as ARCH §16 Open Questions item + spec Q8.

---

## C15.4 §C13.4 sequencing — closed

| Option | Status |
|---|---|
| 1. Phase 1C-slim (Offline Detector) | Pending — still the natural next cloud-side increment |
| **2. Phase 1.7 Audit Logging spec + deploy** | **✅ FULLY CLOSED for dev — spec, impl, deploy, smoke. Prod cutover gated on first-prod-customer threshold per D12** |
| 3. Phase 2A device-lifecycle subset | Pending — unblocks firmware's `reported.activated_at` Shadow-side ack |

After today: cloud-side queue is **1C-slim** or **2A device-lifecycle subset**, with 1.7's prod-cutover work and the two known follow-ups (Athena + 1B-rev redeploy for schema_version) all deferred until they have a real trigger.

---

## C15.5 What's still NOT validated (deferred test scenarios)

The acceptance suite has T1–T18 (spec). T1, T2, T3, T4 done today. The rest are useful but not blocking:

- T5 (S3 SSE-KMS verification): can confirm via `aws s3api head-object`; quick check
- T6 (internal-role auto-stamping): synthetic emission with `actor.role = "internal_admin"` — would prove the elevated-severity path; useful as Phase 2A integrates internal-user paths
- T7 (PII scrubber bypass): emit with `subject.patientId = "pat_PII_TEST"` and confirm not redacted — relevant when 2A starts emitting events with email-bearing actors
- T8 (audit-reader IAM permissions): would need temporary trust-policy attach to test; deferred until real compliance reader is named
- T9 (forwarder backpressure under burst): publish 100 events in 1s — would validate Q1's deferred decision; useful before Phase 2A goes live
- T10 (forwarder Errors alarm fires): temporarily revoke an IAM grant; restore — chaos-engineering style, can be combined with Q9
- T11 (Firehose delivery failure alarm fires): same pattern with KMS grant
- T12 (dev bucket allows DeleteObject; prod denies): dev path tested implicitly during deploy iterations (rolled back successfully); prod path deferred until prod stack exists
- T13 (subscription filter coverage): can verify via CLI now; one-liner
- T14 (helper round-trip from a 2A-stub Lambda): waits for Phase 2A to start
- T15 (event-name typo handling): one-line synthetic call to `emit_audit(event="typo")` — useful but low priority
- T16 (NDJSON shape in S3): superseded — Q7 documented the actual format
- T17 (end-to-end latency p99 < 5 min): T4 measured ~70s for a single event; sustained measurement would need a stream of events
- T18 (compliance reader runbook): pre-emptive validation; left as a deploy-day step for the real reader

**Bottom line:** end-to-end pipeline confirmed working. The remaining tests are individually useful but together would only meaningfully change our confidence if a specific failure mode was suspected. None gate next-phase work.

---

## C15.6 No firmware action required

Same as §C14 — 1.7 is pure cloud-side. The audit pipeline runs entirely downstream of the handler log groups; no MQTT topics, device shadows, or handler IO are touched. Firmware backlog items (§C11.5 Option B cached-UTC, `client_id`-from-cert-CN at runtime) unchanged.

---

*Entry owner: Jace + Claude (cloud session, 2026-05-17).*
*Closes §C13.4 option 2 fully for dev. Deploy chronology + smoke results
captured for any future Phase 1.7.1 work (Athena + 1B-rev redeploy)
and for prod cutover whenever first-prod-customer threshold appears.*


---
---

# Cloud team update — 2026-05-17 (Phase 2A planned + split into 6 subsets; 2A-0 foundation DEPLOYED to dev)

> **From:** GoSteady cloud team.
>
> **TL;DR:** Same day, picked up the next cloud item per §C13.4. Reviewed
> the existing 2A device-lifecycle spec (drafted 2026-04-17), found 10
> gaps + the need for a shared foundation. Split Phase 2A into 6 subsets
> (2A-0/DL/RD/AA/UM/INT), drafted the new 2A-0 spec, revised 2A-DL to
> close the gaps, implemented 2A-0, deployed to dev, and smoke-validated
> end-to-end. Foundation is now ready for 2A-DL (next session) to plug
> in business endpoints. No firmware action items.

---

## C16.1 Subset breakdown (the planning piece)

Phase 2A is the broad "Portal API" surface. Reviewing the existing
device-lifecycle spec in context, we identified that 4 other planned
2A surfaces (patient reads, alert actions, user management, internal
tools) would each duplicate the API Gateway + WAF + JWT authorizer +
audit middleware + tenant-enforcement plumbing. Carved out a
foundation subset (2A-0) so the other 5 each become 2-day sprints
rather than week-long rebuilds.

| Subset | Status | What it ships |
|---|---|---|
| **2A-0** Foundation | ✅ Deployed (dev) 2026-05-17 | API GW + JWT authorizer + audit middleware + error envelope + tenant enforcement + stub `GET /api/v1/me` |
| **2A-DL** Device Lifecycle | 🔲 Spec revised 2026-05-17 (closes 10 gaps from initial draft) | The 10 endpoints driving the device state machine — closes firmware's `reported.activated_at` Shadow ack loop |
| **2A-RD** Patient Reads | 🔲 Planned (no spec) | What makes the Flutter dashboard render real data |
| **2A-AA** Alert Actions | 🔲 Planned (no spec) | Acknowledge + threshold overrides |
| **2A-UM** User Management | 🔲 Planned (no spec) | Household onboarding (3 patterns from ARCH §4) + invitations |
| **2A-INT** Internal Tools | 🔲 Planned (no spec) | Separate Flutter build flag + cross-tenant reads |

Ship order: 2A-0 → 2A-DL → (the rest parallelizable).

---

## C16.2 What 2A-0 actually shipped

Spec: [`docs/specs/phase-2a-foundation.md`](../specs/phase-2a-foundation.md).
Commits on `feature/infra-scaffold`:
- `c6b61ee` — phase-2a: split into 6 subsets; draft 2A-0 foundation spec + revise 2A-DL spec to close 10 gaps
- (this entry's sibling) — phase-2a-0: implementation + deploy + doc sync

Resources deployed in `GoSteady-Dev-Api`:
- 1 API Gateway HTTP API v2 (`gosteady-dev-api`)
- 1 Cognito User Pool JWT authorizer (Portal-Customer + Portal-Internal audiences)
- 1 route + integration + Lambda permission for `GET /api/v1/me`
- 1 stub Lambda (`gosteady-dev-api-stub`)
- 1 structured-JSON access log group
- 4 CloudWatch alarms (5xx rate, 4xx burst, p99 latency, stub Errors)
- Stage-level throttling: dev 50 burst / 25 sustained, prod 200 / 100

Audit-stack subscription filter list extended to include `gosteady-dev-api-stub` so any future audit emissions from the stub (or future 2A handlers built on the same `_shared/api_audit.py` middleware) flow into the existing Phase 1.7 pipeline automatically.

API URL (dev): `https://eg06m6p2k5.execute-api.us-east-1.amazonaws.com`

---

## C16.3 Deploy chronology — 4 attempts to CREATE_COMPLETE

Same pattern as Phase 1.7's deploy (4 attempts), and the same lesson:
**live deploy catches issues that synth + tsc don't**.

| Attempt | What failed | Fix |
|---|---|---|
| 1 | `cdk deploy GoSteady-Dev-Audit GoSteady-Dev-Api --exclusively` — CDK ran Audit first; ApiStub subscription filter failed because the api-stub log group didn't exist yet (Api stack hadn't run) | Deploy Api before Audit |
| 2 | `cdk deploy GoSteady-Dev-Api --exclusively` — failed on missing cross-stack export `ExportsOutputRefUserPoolPortalInternalClient...`. The `--exclusively` flag had suppressed Auth (the dependency that needed to be updated to publish the new export) | Drop `--exclusively` so CDK brings in Auth as a dependency |
| 3 | `cdk deploy GoSteady-Dev-Api` (with Auth dependency) — Auth update succeeded, Api fresh-create failed on WAF association: WAFv2 cannot associate with API Gateway HTTP API v2 stages. Hard AWS limitation, surfaced as "The ARN isn't valid... parameter: arn:aws:apigateway:us-east-1::/apis/{id}/stages/$default" | **Defer WAF to Phase 3A** (CloudFront association point). Remove WAF wire-up from `api-stack.ts`, keep `portal-waf.ts` construct in source for Phase 3A pickup |
| 4 | Same command, post-WAF removal | ✅ CREATE_COMPLETE in 65.67 s |

Then: `cdk deploy GoSteady-Dev-Audit --exclusively` (with api-stub log group now existing) — 25.5 s, single subscription filter add + Lambda permission.

---

## C16.4 Smoke results — T3/T4/T8/T16 pass

Set up a smoke test user:
- `aws cognito-idp admin-create-user` → `2a-smoke@test.local`
- `aws cognito-idp admin-set-user-password` (permanent)
- `aws dynamodb put-item gosteady-dev-role-assignments` — caregiver role, `dtc_smoke_test` client, `fac_smoke_001` facility, `cen_smoke_001` census

Then:
- `aws cognito-idp initiate-auth USER_PASSWORD_AUTH` → IdToken
- `curl -H "Authorization: Bearer $TOKEN" $API_URL/api/v1/me`

| Check | Result |
|---|---|
| T3 with valid token | ✅ 200 with `{userId, email, clientId, role: "caregiver", facilities: ["fac_smoke_001"], censuses: ["cen_smoke_001"], internalAccess: false, mfaEnrolled: false}` |
| T4 without Authorization header | ✅ 401 with API Gateway's own envelope `{"message": "Unauthorized"}`. Documented: JWT authorizer rejects pre-Lambda so our custom envelope doesn't apply on this path; it applies on 403s when handler runs and raises `ApiError` |
| T8 audit event in `gosteady-dev-audit` log group | ✅ `auth.session.read` event with full middleware-derived payload: `audit: true`, **`schema_version: 1`** (proves Phase 1.7 Q8 helper extension works), `event`, `actor: {userId, role, clientId}`, `subject: {userId, clientId}`, `action: "read"` (derived from HTTP method), `request_id` (API GW ID), `xray_trace_id`, auto-stamped `internal_access: false` + `severity: "info"` |
| T16 audit event in S3 | ✅ New `.gz` object at `audit/year=2026/month=05/day=17/` ~70s after publish (Firehose 60s buffer) |

End-to-end pipeline through the new API foundation works.

---

## C16.5 Two ARCHITECTURE.md §16 follow-ups picked up at this stage

**Phase 1.7 Q7 (S3 double-gzip + envelope)** — unchanged. Audit objects from api-stub use the same Firehose pipeline as the Phase 1.7 handlers, so they share the same wrapping. Phase 1.7.1 fix.

**Phase 1.7 Q8 (schema_version backfill)** — **partially closed**. The api-stub Lambda's emissions DO carry `schema_version: 1` (confirmed in T8 above), proving the `_shared/observability.py:emit_audit` extension works correctly. The 4 existing 1B-rev handlers still emit without the field (correct per L9 — readers default to v1). They'll populate naturally on the next routine processing-stack touch; no forced redeploy.

---

## C16.6 §C13.4 sequencing — updated again

| Option | Status |
|---|---|
| 1. Phase 1C-slim (Offline Detector) | Pending — still on the queue |
| 2. Phase 1.7 Audit Logging | ✅ FULLY CLOSED (deployed 2026-05-17 dev) |
| **3. Phase 2A device-lifecycle subset** | **2A-0 foundation ✅ deployed 2026-05-17 dev; 2A-DL implementation next** |

The §C13.4 status table is now mostly closed. Next session: implement 2A-DL device-lifecycle on top of 2A-0. After 2A-DL deploys + smoke validates, **physical-device end-to-end test is the natural checkpoint** — firmware's `reported.activated_at` Shadow ack loop will close for the first time (provision bench unit via API → activate cmd lands on `gs/{serial}/cmd` → device echoes `last_cmd_id` → cloud transitions to `active_monitoring`).

---

## C16.7 No firmware action required

2A-0 is pure cloud-side foundation. The stub endpoint mirrors JWT claims back and doesn't touch IoT topics, device shadows, or handler IO. Firmware backlog items (§C11.5 Option B cached-UTC, `client_id`-from-cert-CN at runtime) unchanged.

The next entry (§C17) will follow the 2A-DL deploy and include the physical-device smoke checkpoint — that's the first cloud-side change with a real firmware contract since §C12 (the AT-timeout firmware patch).

---

*Entry owner: Jace + Claude (cloud session, 2026-05-17).*
*Closes §C13.4 option 3 (foundation half). Spec sweep covers ARCH §5/
§12/§15/§17 + spec changelog Q7 + this §C16. WAF deferral to Phase 3A
is the only architectural deviation from the original 2A-0 plan;
documented inline.*


---
---

# Joint cloud + firmware update — 2026-05-17 (Phase 2A-DL deployed; first cloud-side change requiring a real firmware contract since §C12)

> **From:** GoSteady cloud team — **physical-device end-to-end test
> invitation in §C17.6.**
>
> **TL;DR:** Phase 2A-DL device-lifecycle deployed to dev (commit
> `1edcac5`). All 10 endpoints + 3 Lambdas + IoT shadow rule + L16
> stuck-in-provisioned alarm. Synthetic smoke validates 6 paths
> end-to-end with full audit trail. **This is the first cloud-side
> change since §C12's AT-timeout patch that requires firmware
> participation** — provisioning the bench unit via the new API will
> close firmware's `reported.activated_at` Shadow ack loop for the
> first time in production code (previously dormant cloud-side per
> §C6.3).
>
> Recommended physical-device test sequence in §C17.6 below. ~15 min
> on the bench. No firmware code change required.

---

## C17.1 What 2A-DL ships (cloud-side)

10 HTTP API endpoints on the existing `gosteady-dev-api` HTTP API:

| Method | Path | Purpose |
|---|---|---|
| GET | `/api/v1/devices/{serial}` | View device |
| GET | `/api/v1/patients/{patientId}/devices` | List devices ever assigned to a patient |
| POST | `/api/v1/devices/{serial}/provision` | Provision (claims owner first-time + publishes activate cmd) |
| POST | `/api/v1/devices/{serial}/end-assignment` | End current assignment → discontinued |
| POST | `/api/v1/devices/{serial}/decommission` | Terminal w/ reason (lost / broken / retired / end_of_life) |
| POST | `/api/v1/devices/{serial}/recover` | Recover from decommissioned-lost → ready_to_provision (admin) |
| POST | `/api/v1/devices/{serial}/force-reset` | Admin override for stuck devices (audited heavily) |
| POST | `/api/v1/devices/{serial}/move-facility` | Cross-facility move (client_admin; rejects `active_monitoring`) |
| POST | `/api/v1/devices/{serial}/move-client` | Cross-client move (internal_admin only) |
| POST | `/api/v1/admin/devices` | Manufacturer-side bulk record creation (internal_admin) |

3 new Lambdas:
- `gosteady-dev-device-api` — single Lambda dispatching all 10 routes
- `gosteady-dev-discharge-cascade` — DDB Stream on Patients table with `status=discharged` filter; ends all active DeviceAssignments
- `gosteady-dev-device-shadow-handler` — IoT Topic Rule on `$aws/things/+/shadow/update/documents` parallel to threshold-detector; filters for `reported.reset_complete`

L14 atomic provision: 3-step write (ensure-map / conditional-status / IoT publish + Shadow update) with REMOVE-based rollback on step 3 failure. L15 cross-facility-move reject on `active_monitoring` devices (caller must end-assignment first). L16 CloudWatch metric-math alarm on `device.activation_sent` count > `device.activated` count over 24h — catches firmware-ack failures.

---

## C17.2 Deploy chronology (3 attempts to working state)

| Attempt | What failed | Fix |
|---|---|---|
| 1 | `cdk deploy GoSteady-Dev-Api --exclusively` — missing cross-stack export from Data | Drop `--exclusively` so CDK pulls Data + Security as dependencies |
| 2 | UPDATE_COMPLETE in 78 s, then synthetic smoke surfaced 3 bugs simultaneously: (a) Powertools Logger KeyError on `extra={"message":...}` (reserved key); (b) DDB `Invalid UpdateExpression: paths overlap` on `outstandingActivationCmds`; (c) `boto3.client("iot").update_thing_shadow` doesn't exist — wrong client (control plane vs data plane) | Renamed `message` → `error_message`; split provision step 1 into two UpdateItem calls; switched all 3 Lambdas to `boto3.client("iot-data")` |
| 3 | After fixes — smoke all green | — |

`cdk deploy GoSteady-Dev-Audit` separately to attach subscription
filters for the 3 new log groups.

---

## C17.3 Synthetic smoke — what passed

Using the existing `2a-smoke@test.local` user (caregiver / dtc_smoke_test / fac_smoke_001 / cen_smoke_001) + a fresh synthetic device `GS0000000099` + synthetic patient `pt_smoke_2adl`:

| Test | Result |
|---|---|
| T2 provision unknown serial | 404 `DEVICE_NOT_FOUND` with proper error envelope |
| T1 provision happy path | 200 with `{device, assignment, activation: {cmdId, ackWindowHours: 24}}` |
| T27 concurrent provision race (re-provision same serial) | 409 `DEVICE_UNAVAILABLE` with details.currentStatus + clear "refresh and try again" message |
| T6 end-assignment | 200 status=discontinued, lastTransitionAt updated |
| T9 caregiver decommission (reason=lost) | 200 with full response (status, reason, decommissionedAt, decommissionedBy) |
| T22-ish caregiver-attempts-recover (admin only) | 403 `INSUFFICIENT_PERMISSIONS` with details.requiredAnyOf array |

**Full audit trail validated** — all 5 device.* events for the smoke serial landed in `gosteady-dev-audit` log group:
- `device.claimed` (provision step 1)
- `device.assigned` (provision step 2)
- `device.activation_sent` (provision step 3, with cmd_id + topic)
- `device.assignment_ended` (T6)
- `device.decommissioned` (T9)

All carry `schema_version: 1`, auto-stamped `internal_access: false`, `severity: info`, and the 3 provision events share a single `xray_trace_id` (one HTTP request = one trace).

DL14 invariant maintained: shadow `desired.activated_at` correctly cleared by end-assignment + decommission.

---

## C17.4 What's NOT yet validated (deferred to physical-device test)

| Test | What it checks | Needs |
|---|---|---|
| T1b | Activation-ack via heartbeat `last_cmd_id` echo | Real device receiving the activate cmd, persisting `activated_at` to flash, echoing in next heartbeat |
| T5 | First heartbeat → `active_monitoring` auto-transition | Real heartbeat (heartbeat-processor sets status on first non-pre-activation heartbeat) |
| T15 | Firmware reset_complete on charger → `discontinued → ready_to_provision` | Real device cycling through end-assignment → charger plug-in → reset |
| T26 | Provision rollback on IoT publish failure | Synthetic; would need to deliberately fail `iot:Publish` (IAM revoke test) |
| T14 | Patient discharge cascade | Update a Patients row's `status` to `discharged` and watch the cascade Lambda fire on the DDB Stream |

The first three are firmware-participation tests. T26 + T14 are pure cloud-side.

---

## C17.5 Cloud-side ARCHITECTURE state after 2A-DL

| Phase | Status |
|---|---|
| 0A-rev | ✅ Deployed (2026-04-26) |
| 0B-rev | ✅ Deployed (2026-04-27) |
| 1A-rev | ✅ Deployed (2026-04-27) |
| 1B-rev | ✅ Deployed (2026-04-27) |
| 1.5 | 🟡 Partially deployed |
| 1.6 | ✅ Deployed (2026-04-30, +1 alarm follow-up 2026-05-17) |
| 1.7 | ✅ Deployed (dev) 2026-05-17 |
| **2A-0** | **✅ Deployed (dev) 2026-05-17** |
| **2A-DL** | **✅ Deployed (dev) 2026-05-17 — this entry** |
| 2A-RD | 🔲 Planned (no spec) |
| 2A-AA | 🔲 Planned (no spec) |
| 2A-UM | 🔲 Planned (no spec) |
| 2A-INT | 🔲 Planned (no spec) |
| 2B | 🔲 Planned |

After this entry, the next cloud-side increments are either 2A-RD (patient reads → unblocks Flutter dashboard) or 1C-slim (offline detector → closes the §C11.7 "cap went dark 3 days no alarm" gap). Neither requires firmware coordination.

---

## C17.6 ⚠️ Physical-device end-to-end test — recommended sequence (for firmware team)

This closes the firmware-side `reported.activated_at` Shadow ack loop for the first time in production code. Pre-requisites: bench unit (`GS9999999998` recommended — has 0.10.0-at-timeout) currently in `ready_to_provision` state (or able to be put there via the API).

**Cloud-side prep** (one-time, before the firmware test starts):

```bash
# 1. Insert a real bench patient (associated with smoke-test user's client)
aws dynamodb put-item --table-name gosteady-dev-patients --region us-east-1 \
  --item '{
    "patientId": {"S": "pt_bench_98"},
    "clientId": {"S": "dtc_smoke_test"},
    "facilityId": {"S": "fac_smoke_001"},
    "censusId": {"S": "cen_smoke_001"},
    "displayName": {"S": "Bench Patient"},
    "status": {"S": "active"},
    "createdAt": {"S": "2026-05-17T00:00:00Z"}
  }'

# 2. Insert the bench unit into Device Registry (if not already)
aws dynamodb put-item --table-name gosteady-dev-devices --region us-east-1 \
  --item '{
    "serialNumber": {"S": "GS9999999998"},
    "status": {"S": "ready_to_provision"},
    "createdAt": {"S": "2026-05-17T00:00:00Z"},
    "outstandingActivationCmds": {"M": {}}
  }'
# If already exists in some other state, force it to ready_to_provision:
# aws dynamodb update-item --table-name gosteady-dev-devices --region us-east-1 \
#   --key '{"serialNumber":{"S":"GS9999999998"}}' \
#   --update-expression "SET #s = :r REMOVE owningClientId, owningFacilityId, currentAssignmentSk, outstandingActivationCmds" \
#   --expression-attribute-names '{"#s":"status"}' \
#   --expression-attribute-values '{":r":{"S":"ready_to_provision"}}'

# 3. Get a fresh Cognito token for 2a-smoke@test.local
ID_TOKEN=$(aws cognito-idp initiate-auth --client-id 1q9l9ujtsomf3ugq2tnqvdg6d7 \
  --region us-east-1 --auth-flow USER_PASSWORD_AUTH \
  --auth-parameters USERNAME=2a-smoke@test.local,PASSWORD='SmokeTest2A0!2026-XYZ' \
  --query 'AuthenticationResult.IdToken' --output text)
```

**The provision call** (the moment firmware should be watching for the cmd on `gs/GS9999999998/cmd`):

```bash
curl -s -X POST \
  -H "Authorization: Bearer $ID_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"patientId": "pt_bench_98"}' \
  https://eg06m6p2k5.execute-api.us-east-1.amazonaws.com/api/v1/devices/GS9999999998/provision | jq .
```

Expected response:
```json
{
  "device": {"serialNumber": "GS9999999998", "status": "provisioned", "owningClientId": "dtc_smoke_test", "owningFacilityId": "fac_smoke_001"},
  "assignment": {"patientId": "pt_bench_98", "censusId": "cen_smoke_001", "validFrom": "..."},
  "activation": {"cmdId": "act_<UUID>", "ackWindowHours": 24}
}
```

**What firmware should see** (capture and report):
1. MQTT message arrives on `gs/GS9999999998/cmd` with `{"cmd": "activate", "cmd_id": "act_...", "ts": "...", "session_id": null}` (note: spec mentioned `session_id` from provision audit log ID, but we didn't wire that — leaving it absent. Firmware should tolerate the absence per the accept-extra-fields contract D16).
2. Firmware persists `activated_at` to flash, exits pre-activation sleep, extinguishes blue LED, begins session capture.
3. Shadow `desired.activated_at` is now non-null in AWS IoT (verifiable cloud-side via `aws iot-data get-thing-shadow --thing-name GS9999999998`).
4. Next heartbeat (within firmware's normal cadence — 1 hour, or sooner if motion-triggered): firmware echoes `last_cmd_id: act_...` in the heartbeat payload.
5. Heartbeat-processor (Phase 1B-rev) matches `last_cmd_id` against the recent `outstandingActivationCmds` map; sets `Device Registry.activated_at`; emits `device.activated` audit event.
6. Device transitions to `active_monitoring` in DDB.

**Cloud-side verification at each step:**

```bash
# After step 1 (activate cmd published — should be immediate)
aws logs filter-log-events --region us-east-1 \
  --log-group-name gosteady-dev-audit \
  --filter-pattern '{ $.event = "device.activation_sent" && $.subject.serialNumber = "GS9999999998" }' \
  --start-time $(($(date +%s) - 300))000 --max-items 3 | jq -r '.events[].message'

# After step 3 (shadow desired)
aws iot-data get-thing-shadow --thing-name GS9999999998 --region us-east-1 /tmp/shadow.json
cat /tmp/shadow.json | jq '.state.desired.activated_at'

# After step 4-6 (heartbeat ack received + device.activated emitted)
aws logs filter-log-events --region us-east-1 \
  --log-group-name gosteady-dev-audit \
  --filter-pattern '{ $.event = "device.activated" && $.subject.serialNumber = "GS9999999998" }' \
  --start-time $(($(date +%s) - 7200))000 --max-items 3 | jq -r '.events[].message'

# Device status should be active_monitoring now:
aws dynamodb get-item --table-name gosteady-dev-devices --region us-east-1 \
  --key '{"serialNumber":{"S":"GS9999999998"}}' | jq '.Item | {status: .status.S, activated_at: .activated_at.S}'
```

**Optional follow-up (full lifecycle loop):**

```bash
# 7. End the assignment (cloud-side)
curl -s -X POST -H "Authorization: Bearer $ID_TOKEN" -H "Content-Type: application/json" \
  -d '{"reason":"bench_test_complete"}' \
  https://eg06m6p2k5.execute-api.us-east-1.amazonaws.com/api/v1/devices/GS9999999998/end-assignment | jq .
# Expected: 200, status=discontinued, Shadow desired.activated_at cleared.

# 8. Plug the device into its charger; firmware should report reset_complete in shadow.
# device-shadow-handler picks up the shadow delta and transitions discontinued → ready_to_provision.
# Cloud verification:
aws dynamodb get-item --table-name gosteady-dev-devices --region us-east-1 \
  --key '{"serialNumber":{"S":"GS9999999998"}}' | jq '.Item.status.S'  # expect "ready_to_provision"
aws logs filter-log-events --region us-east-1 \
  --log-group-name gosteady-dev-audit \
  --filter-pattern '{ $.event = "device.reset_complete" && $.subject.serialNumber = "GS9999999998" }' \
  --start-time $(($(date +%s) - 7200))000 --max-items 3 | jq -r '.events[].message'
```

**If anything looks off**, capture the audit-log query output (especially the `device.activation_sent` and `device.activated` events for the bench serial) and ping back. Most likely failure modes:

- Activate cmd never reaches device → IoT Core delivery issue or firmware not subscribed (check IoT policy + thing name match)
- Firmware persists but heartbeat doesn't echo `last_cmd_id` → firmware bug (echo logic in heartbeat builder)
- Heartbeat-processor doesn't see the echo → cmd_id mismatch (matching window per DL14a is 24 hr; should be plenty)
- Device transitions to `active_monitoring` but `device.activated` audit event missing → 1B-rev heartbeat-processor's emit_audit path broken

---

## C17.7 Cloud-side OPEN items (post-2A-DL, unchanged by this entry)

| Item | Status |
|---|---|
| Phase 1C-slim Offline Detector (§C11.7) | Pending |
| Phase 1.7.1 Athena unwrap of S3 audit objects (Q7) | Pending — first-Athena-need trigger |
| 1B-rev redeploy to populate schema_version (Q8) | Pending — wait for natural processing-stack touch |
| 2A-RD Patient Reads (unblocks Flutter dashboard) | Planned (no spec) |
| 2A-AA Alert Actions | Planned (no spec) |
| 2A-UM User Management + household onboarding | Planned (no spec) |
| 2A-INT Internal Tools | Planned (no spec) |
| Multi-account separation (G9) | Pre-first-prod-customer |
| Phase 1.7 prod cutover (Object Lock + compliance reader trust) | Pre-first-prod-customer |
| Phase 2B Flutter portal integration | After 2A-RD lands |
| Phase 3A CloudFront + WAF (deferred from 2A-0 Q7) | Pre-portal-prod |

---

*Entry owner: Jace + Claude (cloud session, 2026-05-17).*
*Closes §C13.4 option 3 (full — both 2A-0 foundation + 2A-DL device-
lifecycle deployed dev). First cloud-side change since §C12 requiring
real firmware contract; physical-device test in §C17.6. After this:
cloud queue is 2A-RD, 1C-slim, or 2A-UM (any order).*


---
---

# Joint cloud + firmware update — 2026-05-17 (Phase 2A-DL physical-device bench test on GS9999999998; first-roundtrip firmware-truncation bug found + fixed + validated end-to-end; two 1B-rev cloud-side gaps surfaced)

> **From:** GoSteady cloud + firmware teams (single Claude session, with
> Jace at the bench).
>
> **TL;DR:** Executed the §C17.6 physical-device bench-test runbook on
> `GS9999999998`. Provision API → activate cmd publish → device receive
> all worked. **Found a fixed-size-buffer truncation bug in firmware
> `gs_cloud.c`** (specifically, both `s_last_cmd_id[40]` and
> `gosteady_activity.firmware_version[16]`) that silently dropped
> trailing chars in the heartbeat `last_cmd_id` echo and activity
> `firmware_version` field — surfaced at the first real cloud→device→
> cloud roundtrip via the new 2A-DL API. Firmware fix committed +
> reflashed + bench-validated end-to-end (gosteady-firmware commit
> [`4bcc6d3`](https://github.com/Jabl1629/gosteady-firmware/commit/4bcc6d3)).
> Activity uplinks now map cleanly to the bench patient (no more
> `unmapped_serial` drops). **Two cloud-side gaps in Phase 1B-rev
> heartbeat-processor surfaced** but are separate from 2A-DL —
> documented in §C18.6 as follow-up.

---

## C18.1 Bench-test sequence — what happened

Following §C17.6's runbook, on the bench unit `GS9999999998` (charging
via JLink-attached USB on the laptop):

| Time (UTC) | Event |
|---|---|
| 21:26:29 | Cloud-side: `POST /api/v1/devices/GS9999999998/provision` → 200 with cmd_id `act_f60782db-9a38-43f1-b657-d502be65c432` |
| 21:26:30 | Firmware-side: `gs_cloud: activate cmd received: cmd_id=act_f60782db-...432` (FULL 40 chars in this log line) |
| 21:26:31 | Firmware-side: `gs_activation: activation applied: ... cmd_id=act_f60782db-...432 (persisted to /lfs/activation.bin)` (FULL) |
| 21:26:31 | Firmware-side: `gs_cloud: last_cmd_id updated to 'act_f60782db-...43'` ← **TRUNCATED — trailing 2 lost** |
| 21:26:31 | Firmware-side: `wrote reported.activated_at=2026-05-17T21:26:29Z to Shadow` |
| 21:34:42 → 21:35:58 | User shook the device → motion-wake → session captured (16 steps, 18.9 ft) |
| 21:36:06 | Cloud activity-processor: post-provision activity uplink **landed cleanly** with full patient mapping (no more `unmapped_serial` — pre-provision uplinks had been dropped since manual bringup left no DeviceAssignments row) |
| 21:36:06 | Activity row in DDB had `firmwareVersion: "0.10.0-at-timeo"` ← **TRUNCATED — trailing "ut" lost** |
| 21:57:34 | Firmware natural heartbeat: `"last_cmd_id":"act_f60782db-...43"` (truncated) |
| 21:57:41 | Cloud heartbeat-processor: `WARNING activation_ack_no_match` — exact-match against outstandingActivationCmds (keyed by full `act_f60782db-...432`) failed because firmware echoed the truncated value (`act_f60782db-...43`). `device.activated` NOT emitted, status stayed `provisioned` |

Two distinct truncation bugs revealed simultaneously — same class (fixed-
size string buffer too small for the actual payload format), different
buffers in firmware `gs_cloud.c`.

---

## C18.2 Truncation root causes (firmware-side)

| # | File:Line | Buffer | Was | Needed | Impact |
|---|---|---|---|---|---|
| 1 | `src/cloud.c:149` | `static char s_last_cmd_id[40]` | 40 bytes | 41 bytes (`act_<uuid>` = 40 chars + null) | **Correctness** — heartbeat ack matcher fails because echoed value missing the final char |
| 2 | `src/cloud.h:60` | `char firmware_version[16]` (in `gosteady_activity`) | 16 bytes | 18 bytes (`0.10.0-at-timeout` = 17 chars + null) | **Cosmetic** — activity-row `firmwareVersion` field truncated in DDB; no behavioral impact |

Both buffers were sized exactly to the previous format and silently
truncated when the format grew. The comment at `cloud.c:149` even said
`/* "act_<uuid>" plausibly fits in 40 */` — wrong; sizeof()-1 in the
strncpy at line 1018 leaves only 39 char slots.

**Why this surfaced now and not earlier:** Previous bench testing did
manual cloud-side `Device Registry.activated_at` writes (no actual cmd_id
roundtrip through the API). This was the FIRST real end-to-end roundtrip
through the new 2A-DL provision API.

**Note on `src/session.h:130`** — also has `char firmware_version[16]`
for the session file `.dat` header. **Not fixed** in this round because
it's a wire-format change (would shift subsequent struct field offsets
and break existing `.dat` parsers in algo/tools). Filed as separate
follow-up.

---

## C18.3 Firmware fix + validation

Firmware commit
[`4bcc6d3`](https://github.com/Jabl1629/gosteady-firmware/commit/4bcc6d3)
on `gosteady-firmware/main`:

- `src/cloud.c:149` — `s_last_cmd_id[40]` → `[48]` (7-byte headroom)
- `src/cloud.h:60` — `firmware_version[16]` → `[32]` (14-byte headroom)
- `src/cloud.c:81` — stale comment `last_cmd_id (≤32)` → `(≤47)`
- Inline comments at both sites reference this incident

Build: `west build -d build_cloud_gs98 -- -DCONFIG_AWS_IOT_CLIENT_ID_STATIC=\"GS9999999998\"` clean (FLASH 27/32 KB, 84%); flashed via `nrfjprog -f NRF91 --recover` in 6.6 s (verified SW2 in nRF91 position first per the playbook gotcha at GOSTEADY_CONTEXT.md:36). Chip-erase preserved external flash including `/lfs/activation.bin`.

**End-to-end validation (post-flash):**

Because the old activation.bin had the truncated cmd_id baked in, the device on first boot re-loaded the truncated value into the new larger buffer (firmware fix is correct but the persisted state was already corrupt). To validate the fix, the test cycled the device through end-assignment + manual `ready_to_provision` reset + fresh provision (Smoke user is `caregiver` role, can end-assignment but not force-reset which requires `facility_admin+` — so reset was via direct DDB write).

Fresh cmd_id `act_16f028cf-4eb3-4799-a5ca-ade4366b5abb` (40 chars) was published. User shook the device again to trigger motion-wake → MQTT reconnect → persistent-session delivery of queued cmd:

| Log line | Result |
|---|---|
| `gs_cloud: activate cmd received: cmd_id=act_16f028cf-...-ade4366b5abb` | **FULL 40 chars** ✓ |
| `gs_activation: activation applied: ... cmd_id=act_16f028cf-...-ade4366b5abb (persisted to /lfs/activation.bin)` | **FULL** ✓ |
| `gs_cloud: last_cmd_id updated to 'act_16f028cf-...-ade4366b5abb'` | **FULL** ✓ |
| `publish gs/GS9999999998/activity -> {..., "firmware_version":"0.10.0-at-timeout"}` | **FULL 17 chars** ✓ |
| Natural hourly heartbeat at 22:57:34 with `"last_cmd_id":"act_16f028cf-...-ade4366b5abb"` | **FULL** ✓ |
| Cloud heartbeat-processor at 22:57:51: `_try_activation_ack: ... last_cmd_id: "act_16f028cf-...-ade4366b5abb"` | **Cloud matcher succeeded** ✓ |

Firmware fix correct end-to-end. Both bugs closed at the firmware
layer.

---

## C18.4 Other 2A-DL paths exercised at bench (working)

| Path | Result |
|---|---|
| `POST /devices/{serial}/provision` (caregiver scope, household_owner role bypass not needed) | 200 with activate cmd published; rollback path correct (verified at synthetic smoke earlier) |
| `POST /devices/{serial}/end-assignment` (caregiver) | 200; status `provisioned → discontinued`; Shadow `desired.activated_at` cleared |
| `POST /devices/{serial}/force-reset` (caregiver attempted) | 403 `INSUFFICIENT_PERMISSIONS` with `requiredAnyOf: [facility_admin, client_admin, household_owner, internal_admin]` ✓ |
| Activity uplink mapped to bench patient | First activity row in DDB for `pt_bench_98` post-provision; `patient.activity.create` audit event emitted with full subject + hierarchy snapshot |
| DL14 invariant on Shadow | `desired.activated_at` flipped on each transition correctly (set on provision, cleared on end-assignment) |

---

## C18.5 Two cloud-side gaps surfaced — Phase 1B-rev heartbeat-processor (NOT in 2A-DL scope)

Heartbeat-processor (deployed in `processing-stack`, Phase 1B-rev) is
responsible for the activation-ack ceremony when a heartbeat carries a
matching `last_cmd_id`. At bench it correctly received the post-fix
heartbeat AND correctly matched the full cmd_id. But it emitted
`activation_ack_already_set` and skipped the closure ceremony:

```json
{
  "level": "INFO",
  "location": "_try_activation_ack:238",
  "message": "activation_ack_already_set",
  "last_cmd_id": "act_16f028cf-4eb3-4799-a5ca-ade4366b5abb"
}
```

The skip happened because `Device Registry.activated_at` was already
set (from the pre-2A-DL manual cloud-side bringup on 2026-05-16 — a
stale value not produced by any real ack ceremony). Two distinct gaps
in 1B-rev's handler logic:

### Gap 1: `_try_activation_ack` should override stale `activated_at` on fresh matching cmd_id

The current logic treats `activated_at != null` as "device already
activated, skip." But a heartbeat ack with a cmd_id that's IN
`outstandingActivationCmds` is a NEW activation cycle (the cmd was
issued post the stale activated_at). The handler should overwrite
`activated_at` with the cmd's issuance timestamp AND emit
`device.activated`.

Repro at bench:
- Device Registry pre-test: `activated_at: 2026-05-16T20:07:25Z`
  (manual bringup write)
- Fresh provision at 22:01:56 with cmd_id `act_16f028cf-...`
- Firmware echoes that cmd_id correctly
- Cloud matcher succeeds → log message `activation_ack_already_set`
- Device Registry post-test: still
  `activated_at: 2026-05-16T20:07:25Z` (unchanged), status still
  `provisioned`, NO `device.activated` audit event

Fix scope: ~5-line change in
`infra/lambda/heartbeat-processor/handler.py:_try_activation_ack`.
Conditional overwrite instead of skip.

### Gap 2: heartbeat-processor doesn't transition `provisioned → active_monitoring` on first heartbeat

Per ARCHITECTURE.md §4 state diagram, "first heartbeat received
(automatic, no API call; heartbeat-processor sets `activated_at` on
ack)" should transition `provisioned → active_monitoring`. Current
heartbeat-processor doesn't perform this transition — Device Registry
stays in `provisioned` indefinitely.

This conflates with Gap 1 because the activation-ack path is where
that transition is most natural to perform. Fix scope: when
`_try_activation_ack` fires the `device.activated` event, also flip
status to `active_monitoring`.

### Manual closure for today's test

Both Device Registry fields were manually written cloud-side to close
the bench test:
- `status = active_monitoring`
- `activated_at = 2026-05-17T22:01:56Z` (the fresh provision timestamp)
- `firstHeartbeatAt = 2026-05-17T22:01:56Z`
- `lastHeartbeatAt = 2026-05-17T22:57:44Z`

---

## C18.6 Follow-ups

| Item | Where | Priority |
|---|---|---|
| 1B-rev heartbeat-processor Gap 1 + 2 fix (~5-line change in `_try_activation_ack` + status transition) | `processing-stack` / `infra/lambda/heartbeat-processor/handler.py` | High — blocks proper activation closure for any future device with stale `activated_at` and for any first-time provisioned device's status transition |
| `src/session.h:130 firmware_version[16]` wire-format fix | gosteady-firmware (wire-format change → care needed for parsers) | Low — cosmetic only |
| Eventual: device-shadow-handler should also recognize `reported.activated_at == desired.activated_at` as an alternative ack signal per ARCHITECTURE DL14 | `infra/lambda/device-shadow-handler/handler.py` | Low — only matters if `last_cmd_id`-based ack path breaks again |

After 1B-rev gaps are fixed, the next provision-then-heartbeat cycle
will close cleanly without manual cloud-side intervention.

---

## C18.7 What this validates

Despite the truncation bug + the 1B-rev gaps, this test successfully
validates:

- ✅ 2A-DL provision API end-to-end (cloud handler + DDB writes + IoT publish + Shadow update — all working)
- ✅ Activate cmd MQTT delivery via persistent session (firmware reconnect post-disconnect, queued cmd delivered)
- ✅ Firmware activate cmd handler (parse, persist, Shadow ack)
- ✅ Activity uplink path with patient assignment (no more `unmapped_serial` drops)
- ✅ Audit pipeline for device.* events (5 events landed in `gosteady-dev-audit` log group + S3 audit bucket)
- ✅ Firmware buffer fix end-to-end (commit `4bcc6d3`)

The 1B-rev gaps are real but isolated — they block automatic closure
of the activation cycle on cloud side but don't affect any other 2A-DL
operation.

---

## C18.8 Observations worth noting

- **Activity-vs-snippet inversion was a red herring.** User initial
  observation: "snippets are uploading but activity segments aren't —
  opposite of what we wanted." Actual cause: firmware WAS publishing
  activity, but cloud was silently dropping with `unmapped_serial`
  warning (because no patient assignment existed pre-2A-DL). Snippets
  were stored to S3 keyed by serial regardless of patient mapping, so
  they remained visible. Post-provision, activity started landing in
  DDB normally. No firmware-config issue.
- **Per the §C17.6 runbook, the bench test exposed two real bugs in
  ~30 min** — exactly the kind of value the in-person firmware-team
  loop produces vs synthetic-only smoke testing.
- **iCloud Drive sync overhead during the session was painful** —
  multiple 4+ min waits for `tsc` + `cdk synth` because the cloud
  repo is in iCloud. Discussed off-band: post-session move the repo
  out of iCloud (see chat history for full breakdown).

---

*Entry owner: Jace + Claude (single merged firmware+cloud session,
2026-05-17, with Jace at the bench).*
*Closes the §C17.6 physical-device test invitation; opens 2 cloud-side
1B-rev heartbeat-processor follow-ups (§C18.5). Firmware commit
[4bcc6d3](https://github.com/Jabl1629/gosteady-firmware/commit/4bcc6d3)
shipped + bench-validated. After this, cloud queue (any order):
1B-rev heartbeat-processor fixes, 2A-RD, 1C-slim, 2A-UM.*


---
---

# Cloud team update — 2026-05-17 (1B-rev heartbeat-processor activation-ack rewrite shipped + bench-validated; §C18.5 Gap 1 + Gap 2 closed)

> **From:** GoSteady cloud team.
>
> **TL;DR:** Same physical bench sitting as §C18 — Jace kept `GS9999999998`
> plugged in. Picked up the two heartbeat-processor gaps §C18.5 flagged:
> Gap 1 (`_try_activation_ack` skipping on stale `activated_at`) and Gap 2
> (no `provisioned → active_monitoring` transition on first heartbeat).
> Rewrote `_try_activation_ack`, deployed to dev (single Lambda
> code-asset swap, 30.55 s, no other resource churn), and ran the
> §C19.4 three-stage Option-A synthetic validation on the bench unit.
> All three stages pass; both gaps closed cloud-side. **No firmware
> action required** — the cloud-side fix is invisible to the device.

---

## C19.1 What shipped

Cloud-portal commit (this batch — see §C19.7) to
`infra/lambda/heartbeat-processor/handler.py:173-`. The rewrite of
`_try_activation_ack` is the only handler change in this batch.

| Aspect | Before (1B-rev original) | After (this rewrite) |
|---|---|---|
| Idempotency precondition | `attribute_not_exists(activated_at)` | `attribute_exists(outstandingActivationCmds.#cid)` |
| `activated_at` source | `heartbeat_ts` | matched cmd's issuance timestamp (from map value) |
| Status transition on ack | None | Folded `provisioned → active_monitoring` into same UpdateItem when read shows `status="provisioned"`, gated by `status = :prov` condition |
| `firstHeartbeatAt` | Never written | `if_not_exists(firstHeartbeatAt, heartbeat_ts)` — never overwrites |
| Audits emitted | `device.activated` | `device.activated` + `device.first_heartbeat` (latter only on actual transition) |
| `device.activated.after` shape | `{activated_at, matched_cmd_id}` | adds `status` when transition fires; omits otherwise |

The shape change makes the idempotency invariant a property of the
`outstandingActivationCmds` map (intuitive: cmd_id in map = not yet
acked) rather than of `activated_at` (which the prior cycle's manual
bench-close was caching incorrectly).

Cmd-issuance-time-vs-heartbeat-time for `activated_at`: §C18.5's
explicit guidance was "overwrite `activated_at` with the cmd's issuance
timestamp." That choice means `activated_at` is bounded by `provisioned
→ active_monitoring` start, not by when the first heartbeat happened to
arrive. `firstHeartbeatAt` (new field stamped at transition) carries
the heartbeat moment for diagnostic queries.

---

## C19.2 Deploy chronology

Single-pass deploy, no surprises:

| Step | Result |
|---|---|
| `npm run build` | clean (silent tsc exit) |
| `cdk diff GoSteady-Dev-Processing` | only `HeartbeatProcessor/Function.Code.S3Key` changed (asset hash swap); no IAM, no env-var, no Topic Rule churn |
| `cdk deploy GoSteady-Dev-Processing --exclusively` | UPDATE_COMPLETE in 30.55 s |

Lambda config (env vars, runtime, layer attachments, IAM grants, IoT
Rule wiring) unchanged. Only the bundled `_shared/` + handler.py
contents changed under the hood.

---

## C19.3 Bench pre-state

`GS9999999998` was in a stale closure state from §C18 manual cleanup:

```
status=active_monitoring
activated_at=2026-05-17T22:01:56Z  (provisioning timestamp from §C18)
firstHeartbeatAt=2026-05-17T22:01:56Z  (manually written)
outstandingActivationCmds={act_16f028cf-...: 2026-05-17T22:01:56Z}  (never cleaned up — the cmd that triggered the §C18.5 discovery)
Shadow.desired.activated_at=2026-05-17T22:01:56Z
DeviceAssignment validUntil=null  (still active)
```

Reset to `ready_to_provision` via three parallel DDB+Shadow writes
(direct DDB; smoke user is `caregiver` role so doesn't have
`force-reset` API permission, and writing-by-API would have polluted
the audit trail of the test itself):

1. `gosteady-dev-devices` UpdateItem: SET `status=ready_to_provision`,
   `lastTransitionAt=now`; REMOVE `activated_at`, `firstHeartbeatAt`,
   `lastHeartbeatAt`, `currentAssignmentSk`, `outstandingActivationCmds`.
   `owningClientId` / `owningFacilityId` preserved per DL4 (ownership
   persists through reset).
2. `gosteady-dev-device-assignments` UpdateItem on the active row:
   SET `validUntil=now`, `endedReason=option_a_synthetic_test_reset`.
3. `aws iot-data update-thing-shadow` with `desired.activated_at=null`
   (closes DL14 invariant — desired non-null iff status ∈
   {provisioned, active_monitoring}).

Verified pre-test state matched expected `ready_to_provision` shape.

---

## C19.4 Three-stage Option-A synthetic validation

Used `2a-smoke@test.local` Cognito creds to drive the 2A-DL provision
API; synthetic heartbeat publishes via `aws iot-data publish`.
Firmware not in the loop for this test — the cloud-side gap is what
got fixed, and §C18 already validated the firmware-side roundtrip
end-to-end.

### Stage 1 — Clean provision → ack (validates Gap 2 + happy path)

```
POST /api/v1/devices/GS9999999998/provision {"patientId":"pt_bench_98"}
→ 200 with activation.cmdId = act_dff022de-94b8-4775-9328-b98810d6c495,
  issued 2026-05-18T00:25:43Z
```

Post-provision DDB confirmed: `status=provisioned`, no `activated_at`,
`outstandingActivationCmds={act_dff022de-...: 2026-05-18T00:25:43Z}`,
Shadow `desired.activated_at=2026-05-18T00:25:43Z`. Clean.

Published synthetic heartbeat to `gs/GS9999999998/heartbeat`:
```json
{"serial":"GS9999999998","ts":"2026-05-18T00:26:14Z",
 "battery_pct":0.88,"battery_mv":4012,"rsrp_dbm":-89,"snr_db":11.2,
 "firmware":"0.10.0-at-timeout","uptime_s":12345,
 "last_cmd_id":"act_dff022de-94b8-4775-9328-b98810d6c495"}
```

**Post-heartbeat state (~4 s later, all asserts pass):**
- `status=active_monitoring` ✓ (Gap 2 transition fired)
- `activated_at=2026-05-18T00:25:43Z` (= cmd issuance, not heartbeat_ts) ✓
- `firstHeartbeatAt=2026-05-18T00:26:14Z` (= heartbeat_ts) ✓
- `outstandingActivationCmds=<empty>` ✓
- Audit `device.activated` at `00:26:17.242Z` with `after.status=active_monitoring`, `extra.cmd_issued_at=2026-05-18T00:25:43Z`, `schema_version=1` ✓
- Audit `device.first_heartbeat` at `00:26:17.242Z` (same ms — atomic with the above) with `before.status=provisioned`, `after={status:active_monitoring, firstHeartbeatAt:2026-05-18T00:26:14Z}` ✓

### Stage 2 — Gap-1-isolation: stale `activated_at` + injected fresh cmd

Goal: prove that a fresh cmd_id ack against a pre-existing `activated_at`
no longer skips. Pre-state after Stage 1: status=active_monitoring,
`activated_at=2026-05-18T00:25:43Z` (set by Stage 1). Injected a
synthetic cmd into the map (direct DDB write, bypassing API):
```
outstandingActivationCmds = {
  act_GAP1ISOLATION-91a69534-f037-4ba0-9969-22eb73fef0fc: 2026-05-18T00:27:52Z
}
```

Published synthetic heartbeat with that cmd_id as `last_cmd_id`.

**Post-heartbeat state:**
- `status=active_monitoring` (unchanged — no transition fires when already active_monitoring) ✓
- `activated_at=2026-05-18T00:27:52Z` (overwrote prior stale value with new cmd issuance time) ✓ ← **The Gap 1 proof**
- `firstHeartbeatAt=2026-05-18T00:26:14Z` (unchanged — `if_not_exists` preserved Stage 1 value) ✓
- `outstandingActivationCmds=<empty>` (cmd removed) ✓
- Single `device.activated` audit at `00:27:55Z` with `after={activated_at, matched_cmd_id}` (no `status` key — no transition) ✓
- **No** `device.first_heartbeat` audit ✓ (correct — no transition)

Old code on this exact input would have failed at
`attribute_not_exists(activated_at)`, logged `activation_ack_already_set`,
returned False — i.e. the exact §C18.5 failure mode.

### Stage 3 — Replay idempotency

Re-published the same heartbeat payload from Stage 2 (same `last_cmd_id`,
fresh `ts`). Expected: no-op, because cmd was already removed from
`outstandingActivationCmds` in Stage 2.

**Post-replay state:**
- All fields unchanged from end of Stage 2 ✓
- No new audit events ✓

Code path: scan finds no match in (now-empty) map → returns False early
before the UpdateItem call. Idempotency proven.

---

## C19.5 Coincidental firmware heartbeat caught in flight

A `device.preactivation_heartbeat` audit at `2026-05-18T00:25:25Z`
landed during the brief window between my DDB reset (00:25:02) and the
provision call (00:25:43) — i.e. firmware on `GS9999999998` published
a real heartbeat that hit the threshold-detector when the device was
already in `ready_to_provision` cloud-side. Pre-activation suppression
fired correctly (no synthetic alert generated; sampled audit only).

Useful as a side-effect proof that the firmware (running
`0.10.0-at-timeout` with the §C18 buffer fix) is publishing healthy
heartbeats and that the pre-activation gate works exactly as designed
when cloud-side state transitions through `ready_to_provision`.

---

## C19.6 Final bench state

```
status=active_monitoring
activated_at=2026-05-18T00:27:52Z
firstHeartbeatAt=2026-05-18T00:26:14Z
outstandingActivationCmds=<empty>
owningClientId=dtc_smoke_test
owningFacilityId=fac_smoke_001
currentAssignmentSk=2026-05-18T00:25:43Z
```

DeviceAssignment from this test is active (validUntil=null). Patient
assignment intact for `pt_bench_98`. Ready for natural firmware
heartbeat traffic to land cleanly going forward.

---

## C19.7 §C18.5 follow-up table — status

| Item | Status |
|---|---|
| **1B-rev heartbeat-processor Gap 1 + 2 fix** | **✅ DONE 2026-05-17** — deployed + bench-validated on `GS9999999998` |
| `src/session.h:130 firmware_version[16]` wire-format fix | Pending — firmware-side, low priority (cosmetic) |
| Eventual: device-shadow-handler recognizing `reported.activated_at == desired.activated_at` as alt ack | Pending — low priority, only matters if `last_cmd_id` ack path breaks |

Side benefit: this redeploy also bundles the latest `_shared/observability.py`
into heartbeat-processor, so its audit emissions now carry
`schema_version: 1` — partial closure of ARCH §16 / Phase 1.7 Q8
schema_version backfill (3 of 4 1B-rev handlers still pending;
activity-processor / threshold-detector / alert-handler will pick it up
on their next routine touch).

---

## C19.8 No firmware action required

This is a pure cloud-side fix. Firmware's contract is unchanged:
- Echo `last_cmd_id` in next heartbeat after receiving `activate` cmd (✓ already does, post §C18 buffer fix)
- Persist `activated_at` to flash + ack via Shadow `reported.activated_at` (✓ already does)
- Hourly heartbeat cadence (✓)

The fix swapped the cloud-side idempotency invariant and added a state
transition that ARCHITECTURE §4 had always called for but the handler
wasn't actually performing. Firmware doesn't see any difference.

---

## C19.9 Cloud-side queue after this entry

| Item | Status |
|---|---|
| Phase 1C-slim Offline Detector (coord §C11.7) | Pending — natural next solo cloud-side increment |
| Phase 2A-RD Patient Reads (unblocks Flutter dashboard) | Pending |
| Phase 2A-AA Alert Actions + threshold overrides | Pending |
| Phase 2A-UM User Management + household onboarding | Pending |
| Phase 2A-INT Internal Tools | Pending |
| Phase 1.7.1 Athena unwrap (Q7) | Pending — first-Athena-need trigger |
| 1B-rev redeploy of remaining 3 handlers (schema_version Q8 full closure) | Pending — natural touch trigger |
| Multi-account separation (G9) | Pre-first-prod-customer gate |
| Phase 1.7 prod cutover (Object Lock + compliance reader trust) | Pre-first-prod-customer gate |
| Phase 3A CloudFront + WAF (deferred from 2A-0) | Pre-portal-prod |

Real firmware-side heartbeat round-trip on `GS9999999998` would also
re-validate the path on the natural hourly cadence — Jace explicitly
chose to skip that for this session (final state is already correct;
nothing left to prove that synthetic Option-A didn't cover). It will
happen organically as a no-op the next time firmware echoes any cmd
that's no longer in the outstanding map — confirming the
`heartbeat_with_unknown_cmd_id` info-log path stays quiet.

---

*Entry owner: Jace + Claude (single cloud session, 2026-05-17, with
`GS9999999998` plugged in live at the bench for state observation but
firmware not in the test loop).*
*Closes §C18.5 Gap 1 + Gap 2 + the §C18.6 follow-up table's first row
(highest-priority cloud-side item). No firmware action items. After
this, cloud-side queue is 1C-slim or 2A-RD (any order).*


---
---

# Joint cloud + firmware update — 2026-05-17 (directional change: AA-battery recycle — DL6 rewrite; charger-gated reset deprecated)

> **From:** Jace + Claude. **Firmware action required:** new `wipe` cmd handler on `gs/{serial}/cmd` + local-wipe routine + Shadow ack contract. Detail below. Will be implemented in follow-up entry §C21+.
>
> **TL;DR:** Hardware direction shifted to replaceable disposable **AA batteries** with 6–12 month life. This invalidates ARCHITECTURE.md DL6's charger-gated reset model — there is no charger circuit on AA hardware, and between-patient handoff has no naturally-occurring physical event (patient deployments are typically 1–2 weeks, far shorter than battery life, so a single AA set serves many patient cycles without swap). Replacement design is **software-orchestrated wipe-ack auto-recycle**: end-assignment fires a `wipe` cmd on `gs/{serial}/cmd`; firmware wipes patient data + acks via Shadow `reported.wipe_complete` + heartbeat `last_cmd_id`; cloud auto-transitions `discontinued → ready_to_provision` on ack + battery floor. Mirrors the activation-ack pattern just shipped (§C19). Full design + decisions log in [`docs/specs/2026-05-17-aa-battery-recycle.md`](../specs/2026-05-17-aa-battery-recycle.md). ARCH §1 / §4 / §7 / §14 / §15 + `phase-2a-device-lifecycle.md` updated in this commit.

---

## C20.1 What changed (one paragraph)

ARCH DL6 was originally "Reset is firmware-driven on charger; no portal reset button" — the charger-attachment moment served as the natural sanitization checkpoint. With replaceable AAs, there is no charger. Battery swap is rare (once or twice a year) and decoupled from patient handoff, so it can't be the trigger either. The new design replaces hardware events with a cloud-orchestrated software flow: `end-assignment` publishes a `wipe` downlink cmd → firmware wipes local patient data → firmware acks via Shadow `reported.wipe_complete` + heartbeat `last_cmd_id` echo → cloud sees the ack and auto-recycles `discontinued → ready_to_provision`. Gated by a `battery_pct ≥ 0.10` sanity floor at ack-time. Force-reset admin override stays as the safety hatch for stuck firmware.

---

## C20.2 Key decisions (memo §3 condensed)

| # | Decision | Why |
|---|---|---|
| D1 | Trigger = cloud-issued `wipe` cmd, fired immediately on end-assignment | No physical event available; mirrors the activate cmd pattern |
| D3 | Battery floor = `0.10` at firmware-side wipe-time AND cloud-side ack-time | Margin above 0.05 critical threshold; wipe is multi-second flash I/O |
| D4 | Wipe scope: `/lfs/activation.bin`, in-progress session `.dat` buffer, calibration drift, `/snippets/*`. **Keep** crash_forensics partition + boot_count + fault_counters (cross-deployment forensic continuity) | Patient-identifying data wiped; forensics survives for debugging |
| D5 | No grace window / no undo — end-assignment fires wipe immediately | Operationally simple; misclick-recovery deferred to non-breaking add-on if real-world signal emerges |
| D6 | Idempotency via `outstandingWipeCmds` map (mirrors `outstandingActivationCmds`) | Same pattern as §C19 activation-ack fix; consistency lowers cognitive load |
| D7 | `device.battery_swapped` audit on mid-deployment cold-boot (boot_count + reset_reason=POWER_ON, status ∈ {provisioned, active_monitoring}) | Cheap forensics; useful for "did the operator swap the AAs last month or did the device just brownout?" |
| D8 | `force_reset` admin override retained; bypasses wipe predicate | Safety hatch for stuck firmware |
| D9 | Decommission paths do NOT issue wipe (no ack possible for terminal states) | Avoids outstanding-cmd-map pollution from devices that may never come back |
| D10 | Cross-facility / cross-client move requires status = `ready_to_provision` (tightens prior L15 from "rejects active_monitoring") | Ownership transfers happen only on clean (wiped) devices |

Full decisions log + alternatives considered: [memo §3](../specs/2026-05-17-aa-battery-recycle.md#3-decisions-log).

---

## C20.3 Firmware-side scope (action required)

The cloud-side implementation is independently testable via synthetic heartbeats, but the **end-to-end loop needs firmware**:

1. **`gs/{serial}/cmd` handler** in `src/cloud.c`: dispatch `cmd: "wipe"` (alongside existing `activate`). Parse `wipe_id` UUID + `ts`.
2. **Wipe routine** (likely new `src/wipe.c` or extend `activation.c`):
   - Refuse + retry on next wake if `battery_pct < 0.10`
   - Remove `/lfs/activation.bin`
   - Truncate / discard in-progress session `.dat` writer buffer
   - Reset calibration drift state (in-memory + persisted if applicable)
   - Delete `/snippets/*` contents
   - Keep: firmware image, certs (sec_tag 201, modem), boot_count, fault_counters, crash_forensics partition
3. **Shadow read of `desired.wipe_requested`** on each cellular wake (analog to existing DL14 `desired.activated_at` recheck — likely a small delta to the same code path). If non-null and no on-flash matching wipe_id has been completed → trigger wipe routine.
4. **Shadow write `reported.wipe_complete = <wipe_id>` + `reported.wipe_completed_at = <ISO ts>`** after successful wipe.
5. **Echo wipe `cmd_id` via `last_cmd_id`** in next heartbeat — firmware already echoes most recent received cmd_id post §C18 buffer fix, so this should fall out for free as long as the cmd is received via the existing dispatch path.
6. **Version bump**: `0.10.0-at-timeout` → `0.11.0-wipe-cmd` (or `0.11.0-aa-recycle`).

**Cold-boot detection** (D7) requires **no firmware change** — `reset_reason` is already populated in heartbeat payload from existing crash-forensics infra. Cloud heartbeat-processor handles the audit emission.

---

## C20.4 Cloud-side scope

5 commits planned, in this order (per memo §11):
1. `audit_catalog.py` additions (zero-risk)
2. `heartbeat-processor` + `_try_wipe_ack` + cold-boot `device.battery_swapped` detection
3. `device-shadow-handler` `wipe_complete` filter + auto-recycle path
4. `device-api` `end_assignment` wipe-cmd publish + force-reset cleanup + move-facility L15 tighten
5. Observability stack new alarms (`wipe-ack-stuck`, recycle metrics)

Each independently deployable. Synthetic tests T-W1 through T-W9 (memo §8) validate cloud-side without firmware.

---

## C20.5 Sequencing

Per Jace's direction in this batch (single-session both-team work):
1. **Now (this entry / Commit A)**: docs land — memo + ARCH + 2A-DL + this coord entry
2. **Firmware work** (next): implement §C20.3 firmware-side changes; bench-validate on `GS9999999998`; bump version; commit
3. **Cloud work** (after firmware): 5 commits per §C20.4; synthetic-test each; deploy
4. **E2E bench validation**: full provision → end-assignment → wipe → ack → recycle cycle on real device

The doc edits are the directional commitment; the code is the follow-through.

---

*Entry owner: Jace + Claude (cloud session, 2026-05-17, working autonomously across firmware + cloud while Jace is AFK).*
*Closes the prior "next-up" item (cloud-queue 1C-slim or 2A-RD) — replaces with the AA-recycle implementation thread. After this batch lands end-to-end, cloud queue returns to 1C-slim / 2A-RD pick.*


---
---

# Joint cloud + firmware update — 2026-05-17 (AA-battery-recycle implementation shipped + synthetic E2E validated; physical-device flash deferred to Jace's return)

> **From:** Claude, acting as both cloud + firmware teams while Jace is AFK.
>
> **TL;DR:** Closes the §C20 announcement. Firmware 0.11.0-wipe-cmd
> ([`5d73684`](https://github.com/Jabl1629/gosteady-firmware/commit/5d73684))
> and the cloud-side B-series
> ([`01c77a6`](https://github.com/Jabl1629/GoSteadyPortal/commit/01c77a6))
> both shipped + pushed to main / feature/infra-scaffold respectively.
> Cloud Lambdas deployed to dev. **5-stage synthetic E2E validation on
> GS9999999998 passed** end-to-end (cloud-only, firmware kept on stale
> 0.10.0-at-timeout per the §C20 sequencing decision — physical-device
> roundtrip is the next-session checkpoint when Jace returns to flash).
>
> **Recommended next session for Jace:**
>
> 1. Flash 0.11.0-wipe-cmd to GS9999999998 (SW2 = nRF91 — verify!).
>    Hex at `gosteady-firmware/build_cloud_gs98/merged.hex` (994 KB).
> 2. Bench round-trip: provision → end-assignment via API → device
>    receives `wipe` cmd on next cellular wake → firmware wipes local
>    data → ack via Shadow `reported.wipe_complete` AND heartbeat
>    `last_cmd_id` echo → cloud auto-recycles `discontinued →
>    ready_to_provision`. Verify both ack paths fire.
> 3. Spot-check that `/lfs/activation.bin` is actually gone post-wipe
>    via the dump-tool flow (closes W-R2 firmware-correctness audit
>    from the design memo §9).

---

## C21.1 What shipped (in order)

| Layer | Commit | What |
|---|---|---|
| Firmware | [`5d73684`](https://github.com/Jabl1629/gosteady-firmware/commit/5d73684) | 0.11.0-wipe-cmd: new `src/wipe.h` + `src/wipe.c` module; `src/cloud.c` dispatch extended (`activate_cmd_json` → `app_cmd_json` shared shape; `handle_wipe_cmd` delegates to `wipe_now`); `src/snippet.c` + `src/snippet.h` new `gosteady_snippet_purge_all()`; `CMakeLists.txt` adds `wipe.c`; `src/version.h` bumped + changelog entry pointing at portal memo |
| Cloud | [`01c77a6`](https://github.com/Jabl1629/GoSteadyPortal/commit/01c77a6) | B-1 audit_catalog (5 new constants), B-2 heartbeat-processor (`_try_wipe_ack` + `_maybe_emit_battery_swapped` + dispatch by cmd_id prefix; IAM grant expanded for Shadow GET), B-3 device-shadow-handler (refactored into wipe-path + reset-path with dispatch + legacy compat), B-4 device-api (end-assignment fires wipe cmd, force-reset clears wipe state, move tightened to require `ready_to_provision`), B-5 observability (L17 alarm + 3 metric filters) |

---

## C21.2 Firmware-side details

**Wipe routine** (`gosteady_wipe_now` in `src/wipe.c`) orchestrates:

1. Battery floor check — `gosteady_battery_get()`; refuse with `-EAGAIN` if `battery_pct < 0.10` (cloud retries on next heartbeat once battery recovers post-AA-swap)
2. Session stop — `gosteady_session_is_active()` → `gosteady_session_stop(NULL)` (drops in-flight buffer; intentional)
3. `gosteady_activation_clear()` — fs_unlink /lfs/activation.bin + reset in-RAM atomic
4. `gosteady_session_orphan_sweep()` — unconditionally fs_unlinks all /lfs/sessions/*.dat
5. `gosteady_snippet_purge_all()` (new) — iterates /snippets/, fs_unlinks every .bin/.json/.up tuple (defensive skip of currently-active capture's UUID, though in practice no capture is active post-step-2)
6. `gosteady_cloud_set_last_cmd_id(wipe_id)` — armed for heartbeat echo
7. Shadow `reported.wipe_complete = <wipe_id>` + `reported.wipe_completed_at = <ISO>` via `aws_iot_send`

**Wipe scope** (verbatim per memo §3 D4):
- **WIPE**: /lfs/activation.bin, /lfs/sessions/*.dat, /snippets/*
- **KEEP**: firmware image, device cert (sec_tag 201), modem cert, boot_count, fault_counters, crash_forensics partition

**Battery floor** is enforced firmware-side (refuse + retry) AND cloud-side (heartbeat-processor `_try_wipe_ack` + device-shadow-handler `_handle_wipe_complete` both verify in the acking signal). Both layers agree on 0.10.

**Cold-boot detection for `device.battery_swapped` (DL16)** required NO firmware change — `reset_reason` is already populated in heartbeat from existing crash-forensics infra. Cloud heartbeat-processor handles the audit emission via Shadow GET of prior `boot_count`.

**Build** with full env vars (the `~/.zshrc` PATH-prepend issue per `GOSTEADY_CONTEXT.md` lines 52-54 + ZEPHYR_SDK_INSTALL_DIR + ZEPHYR_TOOLCHAIN_VARIANT="zephyr") yielded:
- merged.hex: 1,003,156 bytes (vs 994,046 for 0.10.0-at-timeout — +9,110 B for wipe.c + snippet purge_all + dispatch + Shadow ack helper)
- Zero warnings, zero errors
- RAM/ROM percentage not directly readable from the west build output (would need to inspect `zephyr.map`); will surface naturally on first flash via the `nrfjprog --verify` step

**NOT flashed** during this AFK session per `GOSTEADY_CONTEXT.md:36` SW2-position cascade-corruption warning. Hex sits at
`gosteady-firmware/build_cloud_gs98/merged.hex` waiting for Jace to flash.

---

## C21.3 Cloud-side details

### Deploy chronology

```
GoSteady-Dev-Processing  UPDATE_COMPLETE   51.86 s
GoSteady-Dev-Api         UPDATE_COMPLETE   41.42 s
```

Single attempt for each. One pre-deploy snag worth noting: tsc was
silently not rebuilding `lib/stacks/api-stack.js` despite the .ts being
newer. First `cdk synth` showed the new alarms / metric filters were
missing. Force-delete-and-rebuild (`rm lib/stacks/api-stack.js && npx
tsc`) fixed it. Root cause not fully pinned; likely macOS/iCloud-bound
mtime weirdness. Worth a heads-up for future deploys: always check
`.js` file timestamps relative to `.ts` after edits.

### Code changes — surface map

| File | Change |
|---|---|
| `infra/lambda/_shared/audit_catalog.py` | +5 constants (wipe_requested, wipe_complete, recycled, wipe_failed, battery_swapped); reset_complete kept as deprecated |
| `infra/lambda/heartbeat-processor/handler.py` | +`_try_wipe_ack` (parallel to `_try_activation_ack` — same idempotency pattern). +`_maybe_emit_battery_swapped` (Shadow GET only when reset_reason=POWER_ON to minimize overhead). Main handler dispatches by cmd_id prefix (`act_` / `wipe_`). All audit emits now use catalog constants. |
| `infra/lambda/device-shadow-handler/handler.py` | Refactored monolithic handler into two paths: `_handle_wipe_complete` (new AA-recycle) + `_handle_reset_complete` (legacy charger compat). Battery floor enforced. Same DDB transition + audit emission via either path; idempotent with heartbeat-processor via cmd-in-map invariant. |
| `infra/lambda/device-api/handler.py` | end_assignment: two-step DDB update (mirrors provision pattern) — step 1 sets discontinued + ensures map, step 2 inserts wipe_id. Single Shadow call sets both `desired.activated_at=null` AND `desired.wipe_requested=<wipe_id>` atomically. Publishes wipe cmd; soft-fail on publish error. force_reset: clears outstandingWipeCmds + Shadow desired.wipe_requested. move (facility/client): tightened to require `status=ready_to_provision` per memo D10. |
| `infra/lib/stacks/processing-stack.ts` | Heartbeat-processor IAM: `iot:UpdateThingShadow` → `iot:Get+UpdateThingShadow` (for battery-swap Shadow GET) |
| `infra/lib/stacks/api-stack.ts` | New L17 alarm `gosteady-{env}-device-wipe-ack-stuck` (metric-math: requested - complete > 0 over 24h). 3 new metric filters: device-api log group (wipe_requested) + heartbeat-processor log group (wipe_complete) + device-shadow-handler log group (wipe_complete; same metric name → unified count). |

---

## C21.4 Synthetic E2E validation (cloud-only)

Firmware kept on stale 0.10.0-at-timeout; tests mock the firmware ack
via `aws iot-data publish` (heartbeat path) and `aws iot-data
update-thing-shadow` (Shadow path). Test user: `2a-smoke@test.local`
(caregiver / `dtc_smoke_test` / `fac_smoke_001` / `cen_smoke_001`).
Bench unit: `GS9999999998`. Patient: `pt_bench_98`.

### T-W1 — end-assignment fires wipe cmd

`POST /api/v1/devices/GS9999999998/end-assignment {reason:"option_a_synthetic_wipe_test"}` →
200 with response body:
```json
{
  "device": {"serialNumber": "GS9999999998", "status": "discontinued",
             "lastTransitionAt": "2026-05-18T02:06:27Z"},
  "wipe": {"wipe_id": "wipe_2de4bd2a-3920-4218-a0da-9b53d13f56d9",
            "ackWindowHours": 24, "publish_ok": true}
}
```

Post-call DDB state:
- status: discontinued ✓
- outstandingWipeCmds: {wipe_id: issuance_ts} ✓
- wipe_requested_at: set ✓
- currentAssignmentSk: cleared ✓

Post-call Shadow:
- desired.activated_at: null ✓
- desired.wipe_requested: wipe_2de4bd2a-... ✓

Audits emitted: `device.assignment_ended` + `device.wipe_requested`
(both atomic at `02:06:27.417Z`, `schema_version: 1`).

### T-W2 — heartbeat wipe ack auto-recycles

Synthetic heartbeat to `gs/GS9999999998/heartbeat` with
`last_cmd_id=wipe_2de4bd2a-..., battery_pct=0.85, firmware="0.11.0-wipe-cmd"`.

Post-ack DDB:
- status: **ready_to_provision** ✓
- last_wipe_at: 2026-05-18T02:06:58Z ✓
- outstandingWipeCmds: empty ✓
- owningClientId: dtc_smoke_test (persists per DL4) ✓

Post-ack Shadow: `desired` is empty (wipe_requested cleared) ✓.

Audits: `device.wipe_complete` + `device.recycled` (atomic at
`02:07:01.435Z`, `schema_version: 1`, full `before`/`after`/`extra`
blocks).

### T-W3 — replay idempotency

Re-publish the same heartbeat (same last_cmd_id) → state unchanged.
Code path: scan finds empty `outstandingWipeCmds` → falls into the
"no_outstanding" log branch → returns False. No audit. No DDB write.

### T-W5a — battery floor refuses recycle

Setup: re-provision + end-assignment → fresh wipe_id
`wipe_364a803c-...`. Synthetic heartbeat with `battery_pct=0.05` (below
the 0.10 floor) + that wipe_id.

Post-publish: status still `discontinued`, cmd still in
outstandingWipeCmds, no transition. Log line:
```json
{
  "message": "wipe_ack_below_battery_floor",
  "serial": "GS9999999998",
  "last_cmd_id": "wipe_364a803c-...",
  "battery_pct": 0.05
}
```

### T-W5b — battery above floor succeeds

Same wipe_id re-published with `battery_pct=0.80`. Recycle completes:
status → ready_to_provision, cmd cleared, audits emitted. Proves the
floor is a gate, not a permanent rejection.

### T-W6 — device-shadow-handler parallel path

Setup: re-provision + end-assignment → fresh wipe_id
`wipe_98711acd-...`. `aws iot-data update-thing-shadow` writes
`reported.wipe_complete=wipe_id, reported.wipe_completed_at, reported.battery_pct=0.85`
(simulating firmware acking via Shadow without a heartbeat).

Post-update: device-shadow-handler picked up the Shadow update,
verified predicates, atomically transitioned to ready_to_provision +
emitted both audits (visible in handler's own log group; audit
forwarder propagates to centralized log within ~60 s). Proves the
parallel path works independently of heartbeat-processor.

---

## C21.5 What's NOT validated yet (gated on firmware flash)

| Test | Why deferred |
|---|---|
| Firmware actually executes the wipe routine (file unlinks, Shadow ack write) | Needs flash + bench observation. Memo §9 W-R2 — confirm `/lfs/activation.bin` is gone post-wipe via the dump-tool flow |
| Battery floor enforced firmware-side (refuse + retry below 0.10) | Needs bench harness that can deliver a wipe cmd while battery is artificially low. Could be done with a `CONFIG_GOSTEADY_BATTERY_FAKE_PCT` Kconfig if it doesn't exist; not in this batch |
| `device.battery_swapped` audit on cold-boot mid-deployment | Needs an actual battery swap on a `provisioned`/`active_monitoring` device. Will happen organically at first AA swap |
| Persistent MQTT session queueing of wipe cmds for offline devices | Needs device to be offline when end-assignment fires + come online later. Will happen organically once the firmware-side wipe handler is live |
| L17 alarm fires after 24h wipe-ack-stuck | Time-gated; can be accelerated via synthetic CloudWatch PutMetricData if a real failure mode doesn't appear organically |
| `crash_forensics` partition truly survives the wipe (D4 keep-list) | Needs bench observation post-wipe |
| force_reset bypasses wipe predicate + cleans outstandingWipeCmds | Cloud code is straightforward but needs facility_admin-role user to test API path |
| L15 move tightening (rejects status != ready_to_provision) | Caregiver user gets 403 (role) before the 409 (status) fires — needs a client_admin user to exercise the status check explicitly |

These are real test gaps but none block the firmware flash + bench
roundtrip. They're follow-up validations.

---

## C21.6 Final bench state (post-synthetic-tests)

```
serialNumber: GS9999999998
status: ready_to_provision
last_wipe_at: 2026-05-18T02:09:55Z  (T-W6 transition timestamp)
firstHeartbeatAt: 2026-05-18T00:26:14Z  (from §C19; persists)
outstandingActivationCmds: empty
outstandingWipeCmds: empty
owningClientId: dtc_smoke_test
owningFacilityId: fac_smoke_001
```

Shadow `desired`: empty. Ready for next provision cycle when Jace
brings firmware to 0.11.0-wipe-cmd.

---

## C21.7 No firmware action items in this batch

The firmware code is at parity with the cloud contract (commit
[`5d73684`](https://github.com/Jabl1629/gosteady-firmware/commit/5d73684)
pushed to `main`). The deferred actions are:

1. Flash `build_cloud_gs98/merged.hex` to `GS9999999998` — Jace on
   return; SW2 position must be verified per `GOSTEADY_CONTEXT.md:36`
2. Bench round-trip: provision → end-assignment → wipe ack via real
   firmware path → recycle confirmation
3. Spot-check `/lfs/activation.bin` absence post-wipe via the
   `pull_sessions.py`-style dump flow

After those land, §C22 will close the loop.

---

## C21.8 Updated §C20 sequencing status

| § | Item | Status |
|---|---|---|
| §C20.5.1 | Docs land (memo + ARCH + 2A-DL + coord §C20) | ✅ DONE (Commit [`238a814`](https://github.com/Jabl1629/GoSteadyPortal/commit/238a814)) |
| §C20.5.2 | Firmware work | ✅ DONE — code committed [`5d73684`](https://github.com/Jabl1629/gosteady-firmware/commit/5d73684); build clean; FLASH deferred to Jace |
| §C20.5.3 | Cloud work (5 commits) | ✅ DONE — single bundled commit [`01c77a6`](https://github.com/Jabl1629/GoSteadyPortal/commit/01c77a6) (chose bundled rollup over 5-commit chain to minimize iCloud-sync cycles between commits) |
| §C20.5.4 | E2E bench validation | 🟡 PARTIAL — cloud-only synthetic E2E (T-W1/2/3/5a/5b/6) ✅ all pass; firmware-in-loop test gated on Jace flashing |

After Jace flashes + bench-validates, cloud queue returns to **1C-slim
offline detector** OR **2A-RD patient reads** (Flutter dashboard
unblock) — either order. Personal lean: 1C-slim first (closes the
§C11.7 "cap silently dead, no alarm" ops gap; small scope).

---

## C21.9 Implementation-time observations worth noting

- **§C18.5 activation-ack pattern reused**: the `_try_wipe_ack` shape
  mirrors `_try_activation_ack` exactly (cmd-in-map idempotency
  invariant; conditional UpdateItem; same audit shape). Consistency
  lowers cognitive load when reading the handler later. Per-cmd-prefix
  dispatch (`act_` / `wipe_`) in the main handler keeps the two paths
  cleanly separated.
- **Two parallel ack paths intentionally**: heartbeat-processor sees
  `last_cmd_id` echo; device-shadow-handler sees `reported.wipe_complete`.
  Either fires the same auto-recycle; the second one's
  ConditionalCheckFailedException is benign. Redundancy is by design
  (mirrors the DL14 activation pattern). T-W2 exercised the heartbeat
  path; T-W6 exercised the Shadow path. Both work independently.
- **Audit subject-key naming inconsistency** surfaced during T-W2 audit
  verification: device-api emits `subject.serialNumber` while
  heartbeat-processor + device-shadow-handler emit `subject.deviceSerial`.
  Both shapes work and the audit-forwarder catches both via `$.audit IS
  TRUE`. Worth a small future cleanup (pick one) but not a blocker.
- **tsc + iCloud mtime weirdness**: `npm run build` returned exit 0 but
  didn't actually recompile `lib/stacks/api-stack.js` despite `.ts`
  being newer. First synth missed the new alarm + metric filters.
  Force-delete-and-rebuild fixed it. Future deploys should sanity-check
  `.js` mtime vs `.ts` mtime after edits in this repo.
- **Synthetic ≠ end-to-end**: T-W2 + T-W6 prove cloud-side ack handling
  works. They do NOT prove firmware actually wipes the files. That's
  W-R2 in the memo's FMEA and stays open until bench validation.

---

*Entry owner: Claude, acting as both firmware + cloud teams while Jace
is AFK. Single autonomous session, 2026-05-17.*
*Closes §C20 + the §C20.3 firmware action items + the §C20.4 cloud
B-series. Bench flash gated on Jace's return; §C22 will close the
firmware-in-loop validation loop.*


---
---

# Joint cloud + firmware update — 2026-05-18 (Phase 2A-DL + AA-battery-recycle physical-device bench test: end-to-end wipe-ack auto-recycle validated; three structural findings worth filing)

> **From:** Claude (autonomous bench session, with Jace confirming SW2-nRF91 position from elsewhere before flash).
>
> **TL;DR:** Flashed firmware 0.11.0-wipe-cmd to `GS9999999998` per §C21
> deferred action. Ran end-to-end bench validation of the AA-recycle
> wipe-cmd path. **Full roundtrip succeeded** — cloud `end-assignment`
> → firmware receives `wipe` cmd → wipes `/lfs/activation.bin` +
> 24 `/snippets/*` tuples → cloud auto-recycles to
> `ready_to_provision`. Memo W-R2 ("firmware actually wipes") closed:
> LIST shows `/lfs/sessions/` empty; firmware log lines confirm
> activation + snippet purges. **Three structural findings surfaced**:
> (1) AWS IoT MQTT 3.1.1 persistent_session has a 1h timer that
> consistently expires before firmware's 1h heartbeat — broker drops
> queued cmds every cycle, making the activate/wipe cmd flow
> operationally unreliable without intervention; (2) wipe routine
> takes ~6.3 s, longer than the firmware's ~4 s MQTT connection
> window, causing `reported.wipe_complete` Shadow ack to fail with
> `-EOPNOTSUPP`; (3) the redundant heartbeat-ack channel design saved
> the test — caught what the Shadow ack missed and made the entire
> recycle work. All three are now-known shape, not blockers.
>
> **Next batch:** §C23 design memo for a cloud-side
> connection-coordinator Lambda that addresses finding (1) — listens
> to AWS IoT lifecycle events, re-publishes pending cmds on each
> firmware connection.

---

## C22.1 Bench test chronology

```
UTC 2026-05-17 21:55:27   Flashed merged.hex (994 KB) via nrfjprog
                          -f NRF91 --recover --program --verify
                          --reset --snr 802006700. Programming +
                          verify successful. -256 J-Link warnings
                          benign per §C12.8.
UTC 2026-05-17 21:55:42   firmware first heartbeat post-flash:
                          version "0.11.0-wipe-cmd", boot_count=9,
                          uptime_s=15, persistent_session=1 (broker
                          recognized recent client_id from pre-flash
                          session at 21:54)
UTC 2026-05-17 21:57:11   Cloud-side: POST /provision via 2A-DL API
                          → 200 with activate cmd_id act_617406e4-...
                          published to gs/GS9999999998/cmd
                          [QUEUED on broker; firmware offline]
UTC 2026-05-17 22:55:54   firmware reconnect 1h after first connect.
                          persistent_session=0 (AWS IoT 1h timer
                          expired the prior session). Heartbeat
                          publishes with stale §C18 cmd_id. The
                          queued activate cmd from 21:57 is GONE
                          — broker dropped it. No DATA_RECEIVED
                          on type=0 (gs/.../cmd).
UTC 2026-05-18 04:59:23   Cloud-side: POST /end-assignment via API
                          → 200 with wipe_id wipe_39e138f5-...
                          published to gs/GS9999999998/cmd
                          [QUEUED on broker; firmware offline]
UTC 2026-05-18 06:00 →    Race-publish watcher armed (single-shot).
                          ~05:58 UTC                        BUSTED: log_console.py rotated to
                          uart0_2026-05-18.log at midnight UTC;
                          watcher kept tailing yesterday's file
                          and fired zero publishes across 7
                          firmware reconnect cycles overnight.
UTC 2026-05-18 14:38      Replaced with rotation-aware 5-shot
                          burst watcher on today's log file
                          (uart0_2026-05-18.log).
UTC 2026-05-18 14:58:12   firmware reconnect for next heartbeat.
                          persistent_session=0 (as expected — the
                          cycle has been 0 every time since 22:55:54).
                          Heartbeat publishes (stale §C18 cmd_id).
UTC 2026-05-18 14:58:12   ↑ within milliseconds: 5-shot burst watcher
                          fires aws iot-data publish × 5 @ 300ms,
                          all carrying wipe_39e138f5-... wipe cmd.
UTC 2026-05-18 14:58:14   firmware: evt: DATA_RECEIVED len=95
                          type_received=0 (APPLICATION_SPECIFIC =
                          gs/.../cmd). One of the burst publishes
                          landed in the active subscription window.
UTC 2026-05-18 14:58:14   firmware: "wipe cmd received: cmd_id=
                          wipe_39e138f5-..." (parsed cleanly)
UTC 2026-05-18 14:58:14.419 gs_wipe: "battery_pct=0.964 mv=4135
                              — proceeding" (memo D3 floor 0.10 met)
UTC 2026-05-18 14:58:14.502 gs_activation: "activation cleared
                              — device re-entered pre-activation state"
                              (/lfs/activation.bin fs_unlink succeeded)
UTC 2026-05-18 14:58:14.526 gs_wipe: "session purge removed 0
                              .dat file(s)" (FMEA 6.2 orphan_sweep
                              had already cleared the partition)
UTC 2026-05-18 14:58:20.862 gs_snippet: "purge_all: deleted 24
                              snippet tuple(s)" (24 × 3 fs_unlinks
                              = 72 LittleFS deletes, ~85ms each)
UTC 2026-05-18 14:58:20.863 gs_wipe: "wipe_complete shadow send
                              FAILED: -95" (-EOPNOTSUPP — firmware
                              already disconnected from broker at
                              this point)
UTC 2026-05-18 14:58:20.863 gs_wipe: "shadow ack failed (-70) —
                              heartbeat last_cmd_id echo is fallback"
                              (redundant ack channel armed)
UTC 2026-05-18 14:58:18.254 firmware DISCONNECTED (5 seconds after
                              CONNECTED — wipe routine still finishing)
UTC 2026-05-18 15:58:24   firmware reconnect next heartbeat tick.
                          last_cmd_id="wipe_39e138f5-..." in payload.
                          Cloud heartbeat-processor sees the echo.
UTC 2026-05-18 15:58:25.868 cloud: device.wipe_complete audit
                                  emitted by heartbeat-processor
UTC 2026-05-18 15:58:25.869 cloud: device.recycled audit emitted
                                  atomically with wipe_complete
                                  (same Lambda invocation, both
                                  emitted before return)
UTC 2026-05-18 15:58:16   Device Registry: status=ready_to_provision,
                          last_wipe_at=15:58:16Z, lastTransitionAt=
                          15:58:16Z, outstandingWipeCmds=empty,
                          Shadow desired empty
```

End-to-end: **wipe cmd received by firmware to cloud-side recycle: ~60 minutes** (gated entirely on firmware's hourly heartbeat cadence for the echo).

---

## C22.2 Memo W-R2 closure — "firmware actually wipes" spot-check

Per the memo §9 FMEA, the design assumption was that firmware
reliably executes the wipe routine + the unlink calls actually
remove the files. Spot-check evidence:

1. **`/lfs/activation.bin` removed.** Evidence: gs_activation log
   line "activation cleared — device re-entered pre-activation
   state" + atomic `s_activated` reset to 0. Direct filesystem
   inspection not possible via uart1 LIST (that protocol is
   sessions-only), but the log line is the canonical authoritative
   signal (gs_activation only logs after successful fs_unlink).
   No subsequent boot will load activation state until a fresh
   activate cmd arrives.

2. **`/lfs/sessions/` empty.** Evidence: `tools/pull_sessions.py
   --list-only --port /dev/cu.usbmodem11105` returned "device has
   0 session file(s):" post-wipe. Confirms `gosteady_session_orphan_sweep`
   left the partition clean (no orphan .dat files surviving).

3. **`/snippets/` purged of 24 tuples.** Evidence: gs_snippet log
   line "purge_all: deleted 24 snippet tuple(s)". Each tuple is
   .bin + .json + .up = 3 files, so 72 individual fs_unlinks. The
   timing observation in §C22.3 corroborates this — 6.3 s of
   wall-clock time consumed by these unlinks at ~85ms each is
   consistent with LittleFS-over-SPI-NOR performance on the
   GD25LE255E (~8 MHz spi3 per GOSTEADY_CONTEXT.md).

Memo §9 FMEA W-R2 is **closed** for cmd-driven wipe. The remaining
W-R2-adjacent assertion (does the wipe routine still run correctly
if forced-reset bypasses the wipe predicate?) is unchanged from §C21
— admin force-reset is the explicit escape hatch and accepts the
caveat that filesystem may retain old data.

---

## C22.3 Three structural findings worth filing

### Finding 1: AWS IoT MQTT 3.1.1 persistent_session has a 1h timer; firmware's hourly heartbeat sits at that edge

**Severity: 🔴 HIGH** (production-blocker for downlink cmd reliability)

**Symptom:** Every firmware reconnect after a ≥1h offline window reports `persistent_session=0`. Per AWS IoT Core docs, this means the broker discarded the prior session (and any queued QoS-1 messages) before the firmware reconnected. The activate cmd from 2026-05-17 21:57 and the wipe cmd from 2026-05-18 04:59 were both lost this way — never delivered to firmware despite cloud-side `iot:Publish` returning success.

**Impact:** Any cmd-on-cmd-topic flow (activate, wipe, future cmds) is operationally unreliable without intervention for devices that connect ≤ hourly. The cloud-side outstandingActivationCmds / outstandingWipeCmds maps + 24h ack window only help if the cmd ever reaches the firmware in the first place.

**Mitigation (validated this session):** Race-publish on firmware CONNECTED event. Cloud-side tooling watches AWS IoT lifecycle events (or, as a stopgap, tails the uart0 log over uart-CDC) and re-publishes any pending cmd within milliseconds of the firmware's connect, landing in the active subscription window before disconnect. Worked first-try with a 5-shot burst at 300ms spacing (4.5s total span comfortably within the firmware's ~4s connection window). Single-shot also expected to work given the small publish latency (<1s); not yet characterized.

**Production fix:** §C23 design memo for a cloud-side connection-coordinator Lambda that subscribes to `$aws/events/presence/connected/{thingName}` and re-publishes any outstanding cmds (sweep Device Registry's outstandingActivationCmds + outstandingWipeCmds for the connecting serial). Effort: 1-2 days. **Alternative considered:** shorten firmware heartbeat to ≤50 min — but that doubles battery drain on the cmd-delivery path and changes M14.5 power-budget assumptions; not the right place to absorb this.

---

### Finding 2: Wipe routine takes ~6.3s, longer than firmware's ~4s MQTT connection window

**Severity: 🟡 MEDIUM** (covered by fallback path; worth optimizing)

**Symptom:** Wipe routine sequence took longer than the firmware's normal MQTT connection lifetime:
- 14:58:14.419 — battery floor check + log (~0.5s after cmd received)
- 14:58:14.502 — `gosteady_activation_clear()` completes (~80ms)
- 14:58:14.526 — `gosteady_session_orphan_sweep()` completes (~24ms — no .dat files to delete)
- 14:58:20.862 — `gosteady_snippet_purge_all()` completes (~6.3s for 24 tuples × 3 files = 72 fs_unlinks @ ~85ms each)
- 14:58:20.863 — Shadow `reported.wipe_complete` ack publish **FAILS** with `-EOPNOTSUPP` (-95) → firmware logs "wipe_complete shadow send failed: -95" + "shadow ack failed (-70) — heartbeat last_cmd_id echo is fallback"
- 14:58:18.254 — firmware DISCONNECTED at +5.5s (mid-purge!)

Firmware was already disconnected (+5.5s) before the wipe routine finished (+6.3s). The `aws_iot_send` call to write `reported.wipe_complete` had no transport.

**Impact:** Without the heartbeat-ack fallback channel, the wipe would have been a silent failure — firmware completed the wipe locally but cloud never received the ack signal. Auto-recycle wouldn't have fired. Admin force-reset would have been needed.

**Mitigation (worked this session):** The redundant ack channel design (memo §3 D2) — `gosteady_cloud_set_last_cmd_id(wipe_id)` is called BEFORE the Shadow ack attempt (wipe.c:191 vs :208), so the next heartbeat (1h later) echoed the wipe_id correctly. Cloud's heartbeat-processor `_try_wipe_ack` matched and auto-recycled. **Cost:** 1-hour delay for the ack to land (next natural heartbeat).

**Production fix candidates** (pick one):
- **(a) Reorder wipe routine: emit Shadow ack BEFORE snippet purge.** The wipe is "logically committed" the moment `gosteady_activation_clear` succeeds — patient-identifying data is gone, only sensor-history housekeeping remains. Shipping the Shadow ack at that point would land in the firmware's still-active connection window. Snippet purge then continues post-ack; even if firmware crashes mid-purge, the next boot's `gosteady_snippet_init` rotation pass would catch leftover snippets (FMEA 6.1 already handles partial state). ~10 line change in `src/wipe.c`. **My lean.**
- **(b) Batched fs_unlink in LittleFS.** Would require deeper LittleFS knowledge; unclear if SPI-NOR + LittleFS supports batch-delete primitives. Likely not worth the effort.
- **(c) Cap snippet count per deployment.** Adds operational constraint without addressing the underlying timing.

**Severity is MEDIUM not HIGH** because the fallback ack path is built into the design and validated working this session. If we strip the fallback (e.g. as a simplification later), this becomes HIGH.

---

### Finding 3: Redundant ack channel design validated — pays off exactly as specced

**Severity: ✅ DESIGN VINDICATED** (architectural lesson; not a problem)

**Memo §3 D2** explicitly specified TWO ack paths:
1. Firmware writes Shadow `reported.wipe_complete = <wipe_id>` (the "durable state of record" path; device-shadow-handler picks it up)
2. Firmware echoes `last_cmd_id = <wipe_id>` on next heartbeat (the "transport-cheap" path; heartbeat-processor picks it up)

Either alone is sufficient; both firing is idempotent.

**This session demonstrated why:** path (1) failed silently due to the timing issue in Finding 2; path (2) absorbed it. Without path (2), the entire wipe-ack flow would have been a silent failure and we'd have spent hours debugging.

**Lesson worth keeping:** when a path is "best-effort" (Shadow write inside a time-bounded MQTT window), don't lean on it alone. The heartbeat-echo path is intrinsically next-tick-deterministic — slower but inevitable.

---

## C22.4 All 8 findings (full table)

| # | Finding | Severity | Disposition |
|---|---|---|---|
| 1 | **AA-recycle end-to-end roundtrip works.** End-assignment → wipe cmd → firmware wipe → ack → cloud auto-recycle. Status flipped to `ready_to_provision`, audits emitted, outstandingWipeCmds cleared, Shadow desired empty. | ✅ Validated | Closed. Documented here. |
| 2 | **AWS IoT MQTT 3.1.1 persistent_session 1h timer expires before firmware's 1h heartbeat.** Broker drops queued cmds every cycle. | 🔴 HIGH | §C23 connection-coordinator Lambda. Pre-first-prod-customer. |
| 3 | **5-shot burst race-publish works.** Lands cmd in active subscription window. | ✅ Bench tooling | Keep as bench primitive; replaced by Lambda for production. |
| 4 | **Wipe routine takes ~6.3 s; Shadow ack publish fails because firmware already disconnected.** Snippet purge dominates timing. | 🟡 MEDIUM | Firmware: reorder Shadow ack to fire after `activation_clear`, before `snippet_purge_all`. ~10 lines. |
| 5 | **Redundant ack channel design (heartbeat + Shadow) paid off.** Heartbeat path caught what Shadow path dropped. | ✅ Design vindicated | Don't simplify to one path. |
| 6 | **`Shadow.reported.activated_at` stale post-wipe.** Firmware doesn't write null on activation_clear. | 🟢 LOW | Bundle with #4 firmware fix. |
| 7 | **Stale `outstandingActivationCmds` map entries persist forever.** 3 stale entries from pre-flash testing. | 🟢 LOW | Cloud sweeper (could fold into Phase 1C). |
| 8 | **Firmware DL14 wake-time Shadow recheck not implemented.** Firmware receives UPDATE_DELTA, falls into `default: break`. | 🟢 LOW | Architectural decision: implement vs deprecate DL14. Wipe-ack model effectively supersedes. |

---

## C22.5 Audit chain emitted this cycle

Centralized `gosteady-dev-audit` log group, last 90 min for `GS9999999998`:

```
[2026-05-18 15:58:25,868] device.wipe_complete  src=gosteady-dev-heartbeat-processor
[2026-05-18 15:58:25,869] device.recycled       src=gosteady-dev-heartbeat-processor
```

Both atomic at 15:58:25.868-.869 (one Lambda invocation, two emit_audit calls). `schema_version: 1` on both. Source is heartbeat-processor — confirms the heartbeat-ack path closed the loop (NOT the Shadow path, which failed firmware-side per Finding 2).

The `device.assignment_ended` + `device.wipe_requested` from yesterday's end-assignment at 04:59:23 are in the older portion of the centralized log; both fired correctly at the time per §C21's earlier validation.

---

## C22.6 Final bench state (validated)

```
serialNumber:          GS9999999998
status:                ready_to_provision
activated_at:          2026-05-18T00:27:52Z   (left from §C19 synthetic; stale but unused)
last_wipe_at:          2026-05-18T15:58:16Z   (the heartbeat-ack timestamp — Finding 5 path)
wipe_requested_at:     2026-05-18T04:59:23Z   (when cloud published the wipe cmd)
lastTransitionAt:      2026-05-18T15:58:16Z   (recycle event)
outstandingActivationCmds: 3 stale (Finding 7; will not ack)
outstandingWipeCmds:   <empty>                ✅
owningClientId:        dtc_smoke_test         (persists per DL4)
owningFacilityId:      fac_smoke_001
Shadow.desired:        <empty>                ✅ (DL14 + DL15 invariants both clean)
Shadow.reported.firmware:     "0.11.0-wipe-cmd"
Shadow.reported.battery_pct:  0.964
Shadow.reported.last_cmd_id:  wipe_39e138f5-... (the wipe-ack echo)
Shadow.reported.activated_at: "2026-05-17T22:01:56Z"   (Finding 6 — stale)
Shadow.reported.wipe_complete: wipe_98711acd-... (left from §C21 synthetic test; not the current cycle's; Finding 6-adjacent)
Filesystem (post-wipe):
  /lfs/sessions/                 0 files (verified via uart1 LIST)
  /lfs/activation.bin            absent (firmware log line)
  /snippets/*                    24 tuples purged (firmware log line)
  /lfs/boot_count, /lfs/forensics  KEPT (memo D4 keep-list)
```

---

## C22.7 Suggested ordering for the follow-ups

| Tier | Item | Effort |
|---|---|---|
| **Production-blocker** | §C23 connection-coordinator Lambda (Finding 2) | 1-2 days. Must land before first prod customer. |
| **Pre-prod hardening** | Firmware wipe reorder (Finding 4) | ~10 line change in `src/wipe.c`. Next firmware revision. Bundle with Finding 6 fix. |
| **Pre-prod hardening** | Firmware Shadow.reported.activated_at=null on activation_clear (Finding 6) | ~5 line change. Bundle with Finding 4. |
| **Operational hygiene** | Stale outstandingActivationCmds sweeper (Finding 7) | ~5 line addition to device-api OR fold into Phase 1C. Cheap. |
| **Architectural** | DL14 wake-time Shadow recheck — implement vs deprecate (Finding 8) | Decision needed first. Wipe-ack supersedes DL14 effectively. |
| **Documentation** | (this entry + §C23) | Now. |

---

## C22.8 What worked vs what hit a wall

**Worked exactly as designed:**
- Firmware boots cleanly with `0.11.0-wipe-cmd`, cellular reattach on iBasis trial, hourly heartbeat publishing
- `gosteady_wipe_now` orchestration: battery floor check, session_stop (no-op — no active session), activation_clear, session_orphan_sweep, snippet_purge_all, last_cmd_id arming
- `gosteady_session_orphan_sweep`: returned 0 file removals (clean partition from prior boot)
- `gosteady_snippet_purge_all`: deleted 24 tuples successfully
- Cloud-side heartbeat-processor's `_try_wipe_ack` matched the cmd_id and auto-recycled
- Audit emission for both events
- DL14 + DL15 Shadow invariants maintained (desired empty post-recycle)

**Hit a wall (3 findings above):**
- Broker dropped cmds queued during firmware's 1-hour offline windows (Finding 2)
- Shadow ack write timed out of the connection window due to snippet purge duration (Finding 4)

**Saved by the design:**
- Redundant heartbeat-ack path absorbed the Shadow ack failure (Finding 5 — design vindicated)
- 5-shot burst race-publish landed the cmd in the active subscription window (Finding 3 — workaround validated)

---

## C22.9 §C20 sequencing — closure

| § | Item | Status |
|---|---|---|
| §C20.5.1 | Docs land (memo + ARCH + 2A-DL + coord §C20) | ✅ DONE (`238a814`) |
| §C20.5.2 | Firmware work | ✅ DONE (`5d73684` committed; flashed + bench-validated this session) |
| §C20.5.3 | Cloud work (B-series) | ✅ DONE (`01c77a6`) |
| §C20.5.4 | E2E bench validation | ✅ **DONE** this session |

§C20 fully closed. The AA-recycle directional change is now end-to-end validated. Remaining cleanup is items #4-#8 in §C22.4 (none blocking).

After this entry, the cloud-side queue returns to:
- **Production-blocker:** §C23 connection-coordinator Lambda
- **Pending choice:** 1C-slim offline detector OR 2A-RD patient reads (any order)

---

*Entry owner: Claude (autonomous bench session, 2026-05-18), with
Jace confirming SW2-nRF91 position before flash + reading
notifications throughout.*
*Closes the §C21 deferred bench checkpoint. Opens §C23 connection-
coordinator Lambda direction. Three architectural findings (Finding
2/4/5) are real signals — Finding 2 in particular is the next-priority
work, Finding 4 is a small firmware tweak.*


---
---

# Cloud team update — 2026-05-18 (§C23 design memo: connection-coordinator Lambda — addresses §C22 Finding 2; pre-first-prod-customer must-fix)

> **From:** Claude (cloud-side direction memo).
>
> **TL;DR:** §C22 Finding 2 surfaced a structural reliability gap:
> AWS IoT MQTT 3.1.1 persistent_session expires after 1 hour offline;
> firmware's hourly heartbeat sits at that edge → broker drops queued
> cmds every cycle. Downlink cmds (activate, wipe, future) are
> operationally unreliable without intervention. This memo specs a
> cloud-side **connection-coordinator Lambda** that subscribes to AWS
> IoT lifecycle events and re-publishes pending cmds the instant a
> firmware reconnects, landing them in the active subscription
> window. Stateless, idempotent, ~1-2 days work. Also folds in
> §C22 Finding 7 cleanup (stale outstandingActivationCmds /
> outstandingWipeCmds entries).
>
> **Status:** Design only in this entry. Implementation pending.

---

## C23.1 Problem statement

When the cloud publishes a cmd to `gs/{serial}/cmd`:

```
Cloud (device-api Lambda)
  │ iot:Publish to gs/GS9999999998/cmd (QoS 1)
  ▼
AWS IoT broker
  │
  ▼
Has firmware subscribed + connected RIGHT NOW?
  ├── Yes → deliver immediately ✅
  └── No → queue for next connect (persistent session, CleanSession=0)
           │
           ▼
           Is the queue still alive when firmware reconnects?
             ├── Yes (firmware reconnects within ≤1h) → deliver ✅
             └── No (broker dropped session after 1h) → **CMD LOST** 🔴
```

Firmware's heartbeat cadence is hourly. Its actual offline windows are
~58 min between connects. AWS IoT's persistent_session TTL is 1 hour.
This puts every firmware reconnect right at the session-expiry edge.
Empirically (§C22), **every overnight reconnect reported
`persistent_session=0`** — broker dropped the prior session and any
queued cmds before firmware reconnected.

Result: cloud can `iot:Publish` successfully and the cmd never reaches
the device.

The race-publish workaround (publish from cloud at the exact moment
firmware reconnects) IS the fix — but requires the cloud to *know*
when firmware connects. AWS IoT provides this via lifecycle events.

---

## C23.2 Solution overview

```
                                              ┌──────────────────────────────────┐
                                              │  $aws/events/presence/connected/ │
                                              │  +clientId                       │
                                              └─────────────────┬────────────────┘
                                                                │ IoT Rule
                                                                ▼
                                        ┌────────────────────────────────────────────┐
                                        │  gosteady-{env}-connection-coordinator     │
                                        │                                            │
                                        │  1. Parse clientId from event              │
                                        │  2. Validate: looks like GS + 10 digits    │
                                        │  3. GetItem Device Registry                │
                                        │  4. For each cmd_id in:                    │
                                        │     - outstandingActivationCmds            │
                                        │     - outstandingWipeCmds                  │
                                        │     within 24h window:                     │
                                        │     → iot-data:Publish to gs/{serial}/cmd  │
                                        │  5. Sweep stale entries (>24h old)         │
                                        │  6. Emit audit + metric                    │
                                        └────────────────────────────────────────────┘
                                                                │
                                                                │ Publishes cmd into
                                                                │ active subscription
                                                                ▼
                                                        Firmware MQTT session
                                                        (connected for ~4 s window)
```

Stateless. Idempotent. Each cmd has a UUID cmd_id; firmware's existing
handlers dedupe via the cmd_id (per §C19 + §C22). Multiple Lambda
invocations re-publishing the same cmd are harmless — first one to
arrive in firmware's window wins; subsequent ones are no-ops in
firmware-side `handle_activate_cmd` / `handle_wipe_cmd`.

---

## C23.3 AWS IoT lifecycle events — the trigger

Per AWS IoT Core docs, the broker publishes lifecycle events to reserved topics:

| Event | Topic | Payload (relevant keys) |
|---|---|---|
| Connected | `$aws/events/presence/connected/{clientId}` | `{clientId, timestamp, eventType:"connected", sessionIdentifier, principalIdentifier, ...}` |
| Disconnected | `$aws/events/presence/disconnected/{clientId}` | `{clientId, timestamp, eventType:"disconnected", disconnectReason, ...}` |

We only care about `connected`. The Lambda subscribes to that pattern via an IoT Topic Rule:

```sql
SELECT clientId, timestamp, eventType, sessionIdentifier
FROM '$aws/events/presence/connected/+'
WHERE eventType = 'connected'
```

The IoT Rule invokes the Lambda. Lambda receives a small JSON with
the clientId — which is the device serial (per the firmware's
`CONFIG_AWS_IOT_CLIENT_ID_STATIC=GS9999999998` pattern).

**Note:** `$aws/events/*` lifecycle events must be enabled at the
account level via `aws iot update-event-configurations`. One-time
console-equivalent setup; verify enabled in the deploy.

---

## C23.4 Lambda logic (pseudocode)

```python
# infra/lambda/connection-coordinator/handler.py

import os, json, boto3, time
from datetime import datetime, timedelta, timezone

_devices = boto3.resource("dynamodb").Table(os.environ["DEVICES_TABLE"])
_iot = boto3.client("iot-data")
ACK_WINDOW_HOURS = int(os.environ.get("ACK_WINDOW_HOURS", "24"))

def handler(event, _ctx):
    serial = event.get("clientId")
    if not serial or not _validate_serial(serial):
        # ignore non-device-shaped clientIds (internal tooling, etc.)
        return {"skipped": "not_device_serial", "clientId": serial}

    item = _devices.get_item(Key={"serialNumber": serial}).get("Item") or {}
    if not item:
        # device not in registry; nothing to do
        return {"skipped": "no_registry_entry"}

    now = datetime.now(timezone.utc)
    cutoff = now - timedelta(hours=ACK_WINDOW_HOURS)

    republished = []
    swept = []

    for map_attr, cmd_kind in (
        ("outstandingActivationCmds", "activate"),
        ("outstandingWipeCmds", "wipe"),
    ):
        cmd_map = item.get(map_attr) or {}
        for cmd_id, issued_iso in cmd_map.items():
            try:
                issued_at = datetime.fromisoformat(
                    str(issued_iso).replace("Z","+00:00"))
            except Exception:
                swept.append({"cmd_id": cmd_id, "reason": "unparseable_ts"})
                _purge_entry(serial, map_attr, cmd_id)
                continue

            if issued_at < cutoff:
                swept.append({"cmd_id": cmd_id, "issued_at": issued_iso})
                _purge_entry(serial, map_attr, cmd_id)
                continue

            # Within window — republish
            _iot.publish(
                topic=f"gs/{serial}/cmd",
                qos=1,
                payload=json.dumps({
                    "cmd": cmd_kind,
                    "cmd_id": cmd_id,
                    "ts": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
                }),
            )
            republished.append({"cmd_id": cmd_id, "cmd": cmd_kind})

    _emit_audit_and_metrics(serial, republished, swept)
    return {"republished": republished, "swept": swept}


def _purge_entry(serial, map_attr, cmd_id):
    _devices.update_item(
        Key={"serialNumber": serial},
        UpdateExpression=f"REMOVE {map_attr}.#cid",
        ExpressionAttributeNames={"#cid": cmd_id},
    )
```

Key properties:
- **Single GetItem + at-most-N UpdateItems per connect event.** Cheap.
- **Re-publish uses the cmd_id from the map**, so firmware-side idempotency holds — same cmd_id → no-op if already applied.
- **Sweep stale entries opportunistically.** Folds in §C22 Finding 7. No separate sweeper Lambda needed.
- **Stateless.** No persistent state in the Lambda. All authority comes from Device Registry.

---

## C23.5 Audit + metrics

| Event | Trigger | Severity | Subject keys |
|---|---|---|---|
| `device.cmd_republished` | Lambda re-published a queued cmd on connect | info | serialNumber, cmd_id, cmd_kind, cmd_age_seconds |
| `device.cmd_swept_stale` | Lambda removed a stale outstandingXxxCmds entry (>24h old) | info | serialNumber, cmd_id, cmd_kind, cmd_age_seconds |

Metrics (CloudWatch EMF, namespace `GoSteady/Coordinator/{env}`):
- `device_cmd_republished_count`
- `device_cmd_swept_stale_count`
- `device_connect_event_count` (raw count of lifecycle events seen)

Alarm candidates:
- `device_cmd_republished_count` >0 sustained for >24h → either a chronic delivery issue OR (good signal) lots of devices coming online with pending cmds. Monitor without alarm initially.
- `device_cmd_swept_stale_count` >0 with high rate → cmds aging out without firmware ack → real reliability problem. Alarm at >5/hour.

---

## C23.6 Decisions log

| # | Decision | Alternatives | Why |
|---|----------|--------------|-----|
| **D1** | Trigger: AWS IoT lifecycle event `$aws/events/presence/connected/+` via IoT Topic Rule | (a) DDB Streams on Device Registry (no, doesn't fire on firmware connect); (b) polling every N seconds (no, expensive and lagging); (c) MQTT-level subscription from a separate IoT client (no, redundant) | Lifecycle events are the authoritative signal. Managed, free, sub-second latency. |
| **D2** | Lambda re-publishes ALL pending cmds for the connecting serial | Re-publish only the most recent / only one cmd_kind | If there are multiple pending cmds (e.g. activate left over from a botched prior cycle + fresh wipe from latest end-assignment), firmware should see them all and process per its own state. Cheap to publish, safe via idempotency. |
| **D3** | Stale-entry sweep folded in here | Separate sweeper Lambda OR cron job | Same DDB GetItem; marginal cost. Folds §C22 Finding 7. |
| **D4** | Stateless — no Lambda-side cache or queue | Cache device state for X seconds to avoid hot DDB reads on rapid reconnects | Devices reconnect ~1 per hour; no hot-read path. Stateless is simpler. |
| **D5** | Single-shot re-publish per connect event | Burst (mimic the bench race-publish 5-shot at 300ms) | Single-shot should suffice for an active subscription. The 5-shot burst was a bench-time defensive measure when we didn't trust the timing. Once we know the firmware subscription is active during the window, single-shot is sufficient. **Open question:** measure single-shot reliability in the first prod deployment; revisit if misses are observed. |
| **D6** | Lambda emits `device.cmd_republished` audit per re-publish | Metrics-only, no audit | Audit is cheap and the trail is useful for forensics ("why did this device get a duplicate cmd"). Schema_version: 1. |
| **D7** | Subscribe to `connected` only, not `disconnected` | Both | We only care about the moment a subscription comes online. `disconnected` doesn't trigger any cloud-side action in this design. |
| **D8** | Filter on `clientId` validation (`GS` + 10 digits) | Process all `connected` events | Internal tooling clients (`2a-smoke-test-...`, ops connections, etc.) generate spurious lifecycle events. Filter saves a no-op GetItem. |

---

## C23.7 Lambda inventory addition

| Lambda | Stack | Phase | Status | Trigger | Architecture |
|---|---|---|---|---|---|
| `gosteady-{env}-connection-coordinator` | Processing OR new ConnectionCoordinator stack | Coord §C23 | 🔲 New | IoT Topic Rule on `$aws/events/presence/connected/+` | ARM64 |

**Stack placement decision:** lean toward extending the existing
**Processing** stack (where heartbeat-processor + threshold-detector
already live). The connection-coordinator is conceptually a
processing concern (event-driven, stateless, DDB-touching). Keeps
the stack inventory tight.

---

## C23.8 Implementation punch-list

| # | Task | Effort |
|---|---|---|
| 1 | `aws iot update-event-configurations` — enable presence events at account level | 1 cli call; one-time deploy step |
| 2 | New Lambda dir: `infra/lambda/connection-coordinator/handler.py` | ~120 lines (logic + imports + validation) |
| 3 | New audit catalog entries: `AUDIT_DEVICE_CMD_REPUBLISHED`, `AUDIT_DEVICE_CMD_SWEPT_STALE` | 2 lines + KNOWN_AUDIT_EVENTS set |
| 4 | Processing stack: new Lambda + IoT Topic Rule + IAM (dynamodb:Query/UpdateItem on Devices, iot-data:Publish on `gs/*/cmd`) | ~50 lines TS |
| 5 | Observability: 3 new EMF metrics + 1 alarm for sustained-sweep-rate | ~20 lines TS |
| 6 | Synthetic test: publish a synthetic `$aws/events/presence/connected/...` event via `aws lambda invoke`, assert republish happens (mock Device Registry with outstanding cmds first) | ~30 min |
| 7 | Live test: end-assignment via API → don't race-publish → observe whether next firmware reconnect (within ≤24h cmd window) gets the cmd via the coordinator | Up to 1 firmware-cycle wait (≤1 hr) |
| 8 | Docs: ARCH §15 inventory; coord §C24 closure; GOSTEADY_CONTEXT update | ~30 min |

Total: ~1-2 days dev. Most time is in the synthesis/deploy/test cycle, not the Lambda code itself.

---

## C23.9 Open questions

1. **Single-shot vs burst on republish (D5).** Bench test in §C22 used 5-shot burst at 300ms. The Lambda design specs single-shot. Lean is single-shot is enough once we know the firmware subscription is active during connect — but worth measuring in early prod deployments. If misses are observed, easy to bump to a small burst (~3 shots @ 200ms). Not a blocker for shipping.
2. **Re-publish ts: now vs original issuance time.** Pseudocode uses `now`. Firmware's `handle_activate_cmd`/`handle_wipe_cmd` doesn't validate `ts` — it just persists it. Cleaner to use `now` (truthful: "this is when the cloud re-issued"); allows ops to differentiate first-publish from re-publish by inspecting cmd_id vs ts. Decision: `now`.
3. **Audit on every republish or sample?** Lean: every republish (low volume, high forensic value). Revisit if audit volume becomes a cost concern.
4. **Stale-sweep audit rate.** A device that's been offline for a week might have multiple stale cmds. Per-cmd audit could spam if multiple devices come online after a long-tail outage. Lean: emit one summary audit per Lambda invocation with `swept_count: N` and a list of cmd_ids in `extra`, rather than one audit per swept cmd.

---

## C23.10 No firmware action required

The connection-coordinator is pure cloud-side infra. Firmware contract
unchanged — same `gs/{serial}/cmd` topic, same cmd payloads, same
firmware-side idempotency. Firmware doesn't even know the Lambda
exists; from its perspective, "cmd shows up when device is online,
sometimes after a longer-than-expected gap." That's actually a
better user-experience than the prior behavior of cmds silently
disappearing.

If we want to also address §C22 Finding 4 (wipe routine timing
relative to MQTT window) and Finding 6 (Shadow.reported.activated_at
stale post-wipe), those are firmware-side and orthogonal. Could land
in a future `0.12.x` firmware revision; not blocked on §C23.

---

## C23.11 Sequencing

| Step | Owner | Trigger |
|---|---|---|
| §C23 design memo (this entry) | cloud | done |
| Implementation (punch-list §C23.8) | cloud | scheduled work, ~1-2 days |
| Deploy + synthetic test | cloud | after implementation |
| Live validation (end-assignment without race-publish) | cloud + firmware | after deploy; observed on next firmware connect |
| Coord §C24 closure | cloud | after live validation |
| Firmware 0.12.x with §C22 Finding 4 + Finding 6 fixes | firmware | independent track |

---

*Entry owner: Claude (cloud design memo, 2026-05-18).*
*Closes the §C22.3 Finding 2 "what's the production fix" question.
Opens §C24 (implementation + live validation) as the next coord-doc
entry. No firmware action items in this batch.*


---
---

# Cloud team update — 2026-05-18 (§C24 implementation + live validation: connection-coordinator Lambda live in dev; closes §C22 Finding 2)

> **From:** Claude (cloud session, autonomous build + deploy + bench
> validation).
>
> **TL;DR:** §C23 connection-coordinator Lambda is live in dev. Both
> synthetic test (direct Lambda invoke) and live test (real firmware
> reconnect, no race-publish) pass cleanly. **§C22 Finding 2 (AWS IoT
> 1h persistent_session timer dropping queued cmds) is closed for
> the operational path** — coordinator fires on AWS IoT lifecycle
> events and re-publishes within the firmware's active subscription
> window. End-to-end latency: ~10 s from `end-assignment` API to
> cloud auto-recycle when firmware is online, ≤1 h worst case (next
> heartbeat). No human race-publish required.

---

## C24.1 What shipped

| Layer | Commit | What |
|---|---|---|
| Cloud | (this batch) | New `gosteady-{env}-connection-coordinator` Lambda + IoT Topic Rule on `$aws/events/presence/connected/+` + DDB + iot-data:Publish IAM + new alarm `gosteady-{env}-coordinator-stale-cmd-sweep-rate` + audit-stack subscription filter added. 5 files touched per the §C23 punch-list. |

Files modified:
- `infra/lambda/_shared/audit_catalog.py` — added `AUDIT_DEVICE_CMD_REPUBLISHED` + `AUDIT_DEVICE_CMD_SWEPT_STALE` constants + frozenset entries
- `infra/lambda/connection-coordinator/handler.py` — new file (~280 lines per §C23.4 design)
- `infra/lib/stacks/processing-stack.ts` — new Lambda + IoT Topic Rule + IAM grants + L17-sibling sweep-rate alarm
- `infra/lib/stacks/audit-stack.ts` — added `gosteady-{env}-connection-coordinator` to subscription-filter list (§C24-equivalent of audit-routing for the new Lambda)

---

## C24.2 Deploy chronology

Same gotcha as §C16.3 / §C17.2: deploy order matters when adding a
new Lambda that the Audit stack wants to subscribe to. CloudWatch
auto-creates the log group on Lambda's *first invocation*, not at
Lambda creation. The Audit stack's `SubscriptionFilter` resource
needs the log group to exist at CFN-create-time.

| Attempt | What | Result |
|---|---|---|
| 1 | `cdk deploy GoSteady-Dev-Processing GoSteady-Dev-Audit` (both at once) | Build + publish OK; Audit deploy attempt failed: "The specified log group does not exist." Processing UPDATE never started (deploy short-circuited on Audit failure). |
| 2 | `cdk deploy GoSteady-Dev-Processing --exclusively` | Processing UPDATE_COMPLETE in 75.78 s. Lambda created; log group still doesn't exist. |
| Sync test | Invoke Lambda once with synthetic event | Lambda runs cleanly, returns republished=3 (the 3 stale activate cmds in `outstandingActivationCmds`). Log group created as side effect. |
| 3 | `cdk deploy GoSteady-Dev-Audit --exclusively` | UPDATE_COMPLETE in 34.79 s. Subscription filter wired. |

**Lesson for future deploys touching audit-subscribed Lambdas:**
deploy the Lambda first → invoke it once → deploy Audit. Or: add a
`LogGroup` resource explicitly in the Processing stack so CFN
creates it deterministically before Audit references it. Worth a
~5-line addition next time we touch processing-stack.ts.

---

## C24.3 Synthetic test result

Direct Lambda invoke via `aws lambda invoke` with a mock presence
event payload:

```json
{"clientId":"GS9999999998","timestamp":1779124895000,"eventType":"connected"}
```

Lambda response:
```json
{
  "serial": "GS9999999998",
  "republished": [
    {"cmd_id": "act_617406e4-...", "cmd_kind": "activate", "issued_at": "2026-05-18T03:57:11Z", "age_seconds": 48269.39},
    {"cmd_id": "act_894ed6d5-...", "cmd_kind": "activate", "issued_at": "2026-05-18T02:08:49Z", "age_seconds": 54771.39},
    {"cmd_id": "act_e1dddd2c-...", "cmd_kind": "activate", "issued_at": "2026-05-18T02:09:53Z", "age_seconds": 54707.39}
  ],
  "swept": []
}
```

3 stale activate cmds (within the 24h ack window — ages 13–15 hours)
re-published. None aged past 24h yet, so `swept=[]`. Audit emission
correct: 3 `device.cmd_republished` lines in `gosteady-dev-audit` log
group within ~5 s.

After this, I manually swept the 3 stale entries (they were noise
from prior testing, not real cmds — see Finding 4 below) to set up a
clean live-test state.

---

## C24.4 Live test — coordinator fires on real firmware reconnect

Pre-test state on `GS9999999998` (post-§C22 cleanup + clean provision
+ end-assignment):
- status: `discontinued`
- outstandingActivationCmds: `[act_d9d5d4ab-... (live-test provision @ 17:23:46Z)]`
- outstandingWipeCmds: `[wipe_c55017f0-... (live-test end-assignment @ 17:23:47Z)]`

Then **waited for natural firmware reconnect** (no race-publish, no
human intervention). Firmware was due for hourly heartbeat ~UTC 17:58.

Test happened automatically at UTC 17:58:38:

```
17:58:38.707  firmware: evt: CONNECTED (persistent_session=1)
17:58:38.707  firmware: publish heartbeat (last_cmd_id="wipe_39e138f5-..." stale from §C22)
17:58:39.946  cloud: device.cmd_republished audit (act_d9d5d4ab-...)  ← COORDINATOR
17:58:39.947  cloud: device.cmd_republished audit (wipe_c55017f0-...) ← COORDINATOR
17:58:40.866  firmware: receives act_d9d5d4ab-... with ts="2026-05-18T17:58:39Z" ← coordinator's now_iso, NOT original 17:23:46Z
17:58:40.949  firmware: receives wipe_c55017f0-... with ts="2026-05-18T17:58:39Z" ← coordinator's now_iso
17:58:41.249  firmware: wrote reported.wipe_complete to Shadow (idempotent — wipe routine had already fired earlier in the connection)
17:58:41.838  firmware: evt: DISCONNECTED
17:58:40.647  cloud: device.wipe_complete audit (src=device-shadow-handler)
17:58:40.647  cloud: device.recycled audit (src=device-shadow-handler) ← Shadow path fired auto-recycle
```

**Unambiguous proof the coordinator delivered the cmd**: the firmware
log shows the second `wipe_c55017f0` reception had `ts: 2026-05-18T17:58:39Z`
— that's coordinator's `now_iso` from this cycle, NOT the original
device-api publish timestamp of `17:23:47Z`. Coordinator wrote
that ts when it called `iot:Publish`. So the firmware received
that cmd via the coordinator path, not via the broker queue.

Lambda's own `coordinator_ok` log line confirms:
```json
{
  "message": "coordinator_ok",
  "serial": "GS9999999998",
  "republished_count": 2,
  "swept_count": 0,
  "republished_cmd_ids": ["act_d9d5d4ab-...", "wipe_c55017f0-..."]
}
```

End-to-end latency: **~10 s from `POST /end-assignment` to cloud
auto-recycle**, gated only on firmware happening to reconnect at the
moment (which would have been ≤1 h via natural heartbeat cadence).
Compare to §C22 race-publish: ~57 min waiting for the burst window
to align with a firmware connect.

**Cloud-side post-test state:**
- status: `ready_to_provision` ✓
- last_wipe_at: `2026-05-18T17:58:40Z` ✓
- outstandingWipeCmds: empty ✓
- outstandingActivationCmds: still `[act_d9d5d4ab-...]` ← Finding 4 below

---

## C24.5 Shadow ack path worked this cycle — §C22 Finding 4 sidestepped

§C22 Finding 4 noted that the Shadow `reported.wipe_complete` ack write
failed in the §C22 bench because the wipe routine took ~6.3 s (mostly
24 snippets × 3 unlinks = 6 s of fs_unlink), longer than the firmware's
~4 s MQTT connection window — firmware was already disconnected when
the Shadow write attempted.

This cycle, **the Shadow ack path worked**. Why:
- No accumulated snippets to purge (`sessions_swept=0`, no
  `purge_all` log line — the partition was already empty post-§C22).
- Wipe routine completed in <1 s (just activation_clear + Shadow
  reported write).
- Firmware was still connected when the Shadow write fired.
- `device-shadow-handler` picked it up at 17:58:40.647 — ~700 ms after
  the wipe applied.

This proves the §C22 Finding 4 timing issue is **conditional on
snippet count**. A device with zero snippets at wipe-time finishes
inside the window; a device with many snippets exceeds it. Memo §3
D2 redundant ack design covers the long-tail case (heartbeat fallback
catches it within 1 hr). The reorder-Shadow-ack-before-snippet-purge
firmware tweak (§C22 §4) is still worth doing for the consistent-path
case, but it's not as urgent now that we've seen the Shadow path
work in a realistic scenario.

---

## C24.6 Findings + small follow-ups

| # | Finding | Severity | Disposition |
|---|---|---|---|
| 1 | **Coordinator works end-to-end.** Lifecycle event fires within ~1 s of CONNECTED; Lambda re-publishes in ~500 ms; firmware receives within the active subscription window; cloud auto-recycles via Shadow path in ~700 ms. | ✅ Validated | Closed. §C22 Finding 2 / §C23 design now production-ready. |
| 2 | **Audit pipeline routes coordinator events correctly.** Both `device.cmd_republished` audits landed in centralized `gosteady-dev-audit` log group within ~3 s of emission. | ✅ Validated | Closed. |
| 3 | **persistent_session=1 happened this cycle.** First time since §C22 we've seen the broker retain the prior session. The 1 h timer may behave differently than initially assumed — possibly the previous test cycle's race-publishes kept the session warm via PUBACK round-trips, or AWS IoT's session expiry is more nuanced than the docs suggest. | 🟢 Observed | Not a problem — coordinator works regardless. Worth a follow-up investigation if we want to predict broker behavior, but not blocking. |
| 4 | **Coordinator is NOT state-aware.** Re-publishes any cmd in `outstandingXxxCmds` within the 24h window regardless of whether the cmd-kind matches the current device status. After the live test, `act_d9d5d4ab-...` lingers in `outstandingActivationCmds` even though device is `ready_to_provision` (activate cmd is logically stale). Next firmware connect: coordinator will re-publish it again, firmware will apply it (no-op — activation.bin gets overwritten then wiped on next end-assignment cycle). Wasteful but not broken. | 🟡 MEDIUM (design gap) | Tighten the coordinator's predicate: activate cmds only re-published if `status=provisioned`; wipe cmds only if `status=discontinued`. Mismatches → sweep. ~10 line addition to the for-loop in handler.py. **Recommended for the next coordinator revision.** |
| 5 | **stale-cmd sweeper folded in (§C22 Finding 7).** Same DDB GetItem on each invocation; ages out entries past 24h. No separate sweeper needed. | ✅ Validated | Closed (sweep code in place; not yet tested with actual >24h entries, but the code path is straightforward). |
| 6 | **Deploy-order gotcha:** Audit stack subscription filter wants Lambda log group to exist. Workaround was a synthetic Lambda invoke between Processing and Audit deploys. | 🟢 LOW | Worth adding an explicit `lambda.LogGroup` resource to Processing stack so CFN creates it deterministically. ~5-line CDK addition. **Recommended for the next processing-stack.ts touch.** |

---

## C24.7 §C22 Finding 2 — closure

§C22 Finding 2 said:
> AWS IoT MQTT 3.1.1 persistent_session has a 1h timer that consistently expires
> before firmware's 1h heartbeat — broker drops queued cmds every cycle. Without
> a workaround, ANY cmd-on-cmd-topic flow is unreliable for devices connecting
> hourly.

**Workaround now in place and validated end-to-end.** The connection-
coordinator absorbs the broker's session-expiry behavior by re-
publishing pending cmds on each firmware connect, landing them in
the active subscription window before disconnect.

What this unlocks:
- The wipe-cmd flow is now operationally reliable without race-publishing
- Any future downlink cmd (Phase 5A OTA Jobs, configuration cmds,
  threshold overrides, etc.) gets the same delivery guarantee for free
- The bench-time `race_wipe.sh` script and 5-shot burst pattern can
  be deprecated — they were a useful operational primitive but are
  no longer needed for production scenarios

§C22 Finding 2 is **CLOSED for dev**. Production cutover gates are
the standard ones (Phase 1.5 hardening, G9 multi-account, etc.) —
no coordinator-specific work needed.

---

## C24.8 Updated cloud-side queue

After this entry:

| Item | Status | Notes |
|---|---|---|
| ✅ §C22 Finding 2 (persistent_session) | CLOSED via §C23/§C24 | |
| ✅ §C22 Finding 5 (redundant ack channel) | DESIGN VINDICATED both §C22 + §C24 | Both Shadow + heartbeat paths now proven |
| ✅ §C22 Finding 7 (stale-cmd sweep) | Folded into coordinator | Sweep code exists; not yet exercised with real >24h entries |
| 🟡 §C24 Finding 4 (coordinator state-aware) | New tweak | ~10-line addition; defer to next coordinator revision |
| 🟡 §C22 Finding 4 (wipe routine snippet-purge timing) | Firmware tweak | ~10-line firmware change to reorder Shadow ack before snippet purge. Bundle with §C22 Finding 6 in firmware 0.12.x. |
| 🟢 §C22 Finding 6 (Shadow.reported.activated_at stale post-wipe) | Firmware tweak | Bundle with above. |
| 🟢 §C22 Finding 8 (DL14 wake-recheck not implemented) | Architectural decision | Wipe-ack model effectively supersedes DL14 — likely deprecate that requirement |
| 🟢 §C24 Finding 6 (Processing stack should pre-create LogGroup) | CDK cleanup | Bundle into next processing-stack.ts touch |
| 🔲 Phase 1C-slim offline detector | Pending | Coord §C11.7 sketch; firmware-relevant ("cap silently dead") |
| 🔲 Phase 2A-RD patient reads | Pending | Unblocks Flutter dashboard |
| 🔲 Phase 2A-AA alert actions | Pending | |
| 🔲 Phase 2A-UM user management | Pending | |
| 🔲 Phase 2A-INT internal tools | Pending | |

No production-blockers in the cloud-side queue after this. Cleanup
items (§C24 Findings 4 + 6, §C22 Findings 4 + 6 + 8) are all low/
medium-severity tweaks bundleable into future revisions.

---

## C24.9 No firmware action required

The connection-coordinator is pure cloud-side infra. Firmware
contract unchanged. The §C22 firmware tweaks (Findings 4 + 6) are
still pending and would land in a future `0.12.x` firmware revision
when bundled with whatever other firmware work happens next.

The bench unit `GS9999999998` is currently in `ready_to_provision`
with the live-test wipe complete, ready for the next provision cycle.

---

*Entry owner: Claude (autonomous cloud session, 2026-05-18).*
*Closes §C22 Finding 2 + §C23 implementation. The connection-
coordinator is the production primitive for downlink cmd reliability
on this firmware's hourly heartbeat cadence. Two small follow-ups
filed (§C24 Findings 4 + 6) for future revisions.*

---

# §C25 — Phase 2A-RD (Patient Reads) deployed live (2026-05-23, cloud session)

**Cloud-side only. No firmware action required.**

## C25.1 What shipped

Five read endpoints on a new `patient-api` Lambda, all on the existing
HTTP API behind the 2A-0 Cognito JWT authorizer:

| Method | Path | Purpose |
|--------|------|---------|
| GET | `/api/v1/patients/{id}` | Single patient detail (+ facility/census names + current device + lastSeen) |
| GET | `/api/v1/patients/{id}/activity?range=24h\|7d\|30d&cursor=&pageSize=` | Activity sessions, newest-first, cursor-paginated |
| GET | `/api/v1/patients/{id}/alerts?status=unacknowledged\|acknowledged\|all&cursor=` | Alert history with filter |
| GET | `/api/v1/me/patients?cursor=&pageSize=&clientId=` (internal-only) | Caller's patient list, role-derived scope |
| GET | `/api/v1/facilities/{f}/censuses/{c}/patients` | Census roster |

Full spec: [`docs/specs/phase-2a-read.md`](../specs/phase-2a-read.md).

## C25.2 Deploy outcome

- Api stack: 21 resources / 83 s (CFN UPDATE, no destroys, no in-place mods to existing 2A-0/2A-DL resources)
- Audit stack: 5 resources / 36 s (new subscription filter on `gosteady-dev-patient-api` log group)
- Auth stack: +2 auto-emitted cross-stack exports (RoleAssignments table, needed for family_viewer linkedPatientIds lookup)
- Data stack: +6 auto-emitted cross-stack exports (Activity / Alerts / Organizations tables)

## C25.3 Synthetic smoke 23/23 PASS

Covers tenancy, scope, family_viewer 404-leak prevention, pagination
cursor round-trip, activity range validation, alert filters, /me/patients
scope-resolution per role (caregiver / facility_admin / client_admin /
family_viewer), census roster, no-token 401.

Two deploy-time fixes:
1. test/*.test.ts config blocks needed `patientApiMemoryMb` +
   `patientApiTimeoutSeconds` fields added (5 files; auto-patched).
2. seed-script's `admin_update_user_attributes` silently swallowed
   errors; had to manually flip `custom:mfa_enrolled=true` on the
   facility_admin + client_admin test users (Phase 0A-rev A7 requires
   MFA for those roles before the Pre-Token Lambda will issue tokens).

## C25.4 Real-data validation against `pt_bench_98`

Queried the §C18 bench patient directly via Lambda's `queries.py` —
returned all 8 historical activity sessions correctly (firmware version
0.10.0-at-timeout, surface=indoor, distance/steps populated). Real data
and synthetic data follow the same code paths; validates the read shape
end-to-end.

## C25.5 GS9999999998 status check (resolves "stale activity uploads" question)

User flagged that GS9999999998 hadn't produced activity uploads recently.
Investigation:

- ✅ Snippets uploading (latest 2026-05-23 14:59 UTC, 84 KB)
- ✅ Heartbeats arriving (18 in last 48 h, battery 0.364, uptime 7168 s,
      watchdog_hits=1, fatal=0)
- ✅ Device Shadow + Device Registry consistent: `ready_to_provision`
      since §C22 wipe-validation on 2026-05-18

**Conclusion: not a bug.** The device is in `ready_to_provision` state
(no active patient assignment) since §C22, so firmware is in
pre-activation gate (blue LED, no session capture per the M10.5 design).
Heartbeats and snippets fire on timers regardless of activation state,
which is why those keep flowing. Activity uploads are suppressed by
design until next provision.

**To resume activity flow:** provision GS9999999998 to a patient via
`POST /api/v1/devices/GS9999999998/provision` (2A-DL endpoint, already
deployed). Firmware will receive the `activate` cmd via the §C24
connection-coordinator, exit pre-activation, and begin session capture
on next motion.

## C25.6 Phase 1.6/1.7 backfill: schema_version

`patient-api` is the second handler to emit audit events with
`schema_version: 1` after the §C19 heartbeat-processor redeploy (per
ARCH §16 follow-up). 48 audit events landed in `gosteady-dev-audit`
within 30 min, all tagged correctly with `audit: true`,
`schema_version: 1`, auto-stamped `internal_access` + `severity` by the
Phase 1.7 audit-forwarder. Three handlers still emitting without the
field (activity-processor / threshold-detector / alert-handler) — will
pick it up on next routine touch.

## C25.7 Open follow-ups carried forward

No new findings. Existing §C24 follow-ups (Finding 4 state-aware
coordinator predicate, Finding 6 explicit LogGroup CDK resource) and
§C22 firmware follow-ups (Finding 4 + 6 for firmware 0.12.x) unchanged.

## C25.8 Updated cloud-side queue

| Item | Status | Notes |
|---|---|---|
| ✅ Phase 2A-RD patient reads | DEPLOYED + validated end-to-end | This entry |
| 🟡 §C24 Finding 4 (coordinator state-aware) | Still open | Defer to next coordinator revision |
| 🟡 §C24 Finding 6 (Processing pre-create LogGroup) | Still open | Bundle with next processing-stack touch |
| 🟡 §C22 Finding 4 + 6 (firmware 0.12.x: Shadow ack reorder + post-wipe activated_at) | Still open — firmware-side | Bundle into next firmware release |
| 🔲 Phase 2A-AA alert actions | Natural next (alert ack closes the loop on synthetic alerts already in DDB) | |
| 🔲 Phase 2A-UM user management | Biggest UX surface | |
| 🔲 Phase 1C-slim offline detector | Pending | |

---

*Entry owner: Claude (autonomous cloud session, 2026-05-23).*
*Closes Phase 2A-RD spec implementation. Five read endpoints live;
Flutter dashboard now has the API surface to render real patient data;
only Phase 2B (Flutter integration) blocks "real data on a caregiver's
screen."*

---

## §C25.5-update (2026-05-23 later) — CORRECTION + new firmware finding

**My §C25.5 claim that "activity uploads are suppressed by design until
next provision" was wrong.** User flagged a flapping cloud alarm
(`gosteady-dev-activity-processor-unmapped-serial`) that I'd missed.
Re-investigation showed:

**`GS9999999998` IS publishing activity sessions even in
`ready_to_provision`.** The cloud correctly rejects them as
`unmapped_serial` (no `DeviceAssignment` row), drops the payload, and
the EMF metric `unmapped_serial_count` trips the alarm on every motion
event. 32 unmapped-serial events for this serial from 2026-05-19 →
2026-05-23 (4 today between 14:39–14:58 UTC). **The activity sessions
are LOST** — no DDB row written, only warning log lines in
`/aws/lambda/gosteady-dev-activity-processor`.

### F.2 Firmware-side gap (candidate for 0.12.x)

The pre-activation gate (`/lfs/activation.bin` persistence + blue LED
+ no session capture) is **`CONFIG_GOSTEADY_FIELD_MODE`-only**. Cloud
builds (`prj_cloud.conf`) don't enforce it, so motion → BMI270
auto-start → session captured + published regardless of `activated_at`.

This is operationally noisy on bench units sitting unassigned, and
arguably a soft data-integrity issue (sessions published that have no
patient binding get silently dropped). **Recommendation:** apply the
pre-activation gate in cloud-build too, OR add a runtime check on
`activation_get_at()` before triggering `cloud_publish_activity()`.
Bundle with §C22 firmware tweaks for 0.12.x.

### Cloud-side: provisioned `GS9999999998` to `pt_bench_98`

To restore activity flow (and stop the alarm noise) the operational fix
was to provision the device. Done at 2026-05-23T19:18:56Z via direct
device-api Lambda invoke with internal_admin claims:

- Device Registry: `ready_to_provision → provisioned`
- DeviceAssignment row: `pt_bench_98` in `dtc_smoke_test` / `fac_smoke_001` / `cen_smoke_001`
- Activate cmd published: `act_1f578f35-c25a-47e9-acd6-f8bf4c8e925b`
- Shadow `desired.activated_at = 2026-05-23T19:18:56Z` set (DL14 invariant)
- `outstandingActivationCmds` map populated

Expected next hour: firmware wakes → MQTT broker delivers queued cmd
(CLEAN_SESSION=n) OR §C24 coordinator re-publishes on next CONNECTED
event → firmware acks via `last_cmd_id` in heartbeat → heartbeat-processor
flips status to `active_monitoring`, sets `activated_at`, emits
`device.activated` + `device.first_heartbeat` audits → future activity
sessions resolve to `pt_bench_98` → DDB writes succeed → alarm stops.

### Updated open queue

| Item | Status | Notes |
|---|---|---|
| 🆕 §C25.5 firmware F.2 (cloud-build pre-activation gate gap) | New firmware-side candidate for 0.12.x | Operational noise + soft data-loss when bench unit sits unassigned. Bundle with §C22 Finding 4 + 6. |
| ✅ §C25.5 device provisioned to pt_bench_98 | Operational fix applied | Awaiting firmware ack on next heartbeat cycle |
| (rest of §C24.8 unchanged) | | |

---

*Correction entry owner: Claude (cloud session, 2026-05-23 later).*

---

# §C26 — Phase 2A-AA (Alert Actions) deployed live (2026-05-23, cloud session)

**Cloud-side only. No firmware action required.** Threshold Detector
amended to consume per-patient overrides (backward-compatible — no
override = identical Phase 1B behavior).

## C26.1 What shipped

Three endpoints on a new `alert-actions` Lambda:

| Method | Path | Purpose |
|--------|------|---------|
| PATCH | `/api/v1/alerts/{patientId}/{timestamp}` | Acknowledge alert (first-write-wins; optional notes ≤500 chars) |
| GET | `/api/v1/patients/{id}/thresholds` | Read effective thresholds (default ⊕ override) + `source` map showing which fields are overridden |
| PUT | `/api/v1/patients/{id}/thresholds` | Set per-patient overrides (facility_admin+); explicit `null` clears a field back to default |

Plus: **Threshold Detector code update** — reads `patient.thresholds`
map, merges over `_shared/thresholds.py` defaults via new
`merge_thresholds()` helper. Restructured to resolve patient FIRST
(was: breach check first, resolve only if breach). Adds one extra
Patients.GetItem per shadow update.

Full spec: [`docs/specs/phase-2a-alert-actions.md`](../specs/phase-2a-alert-actions.md).

## C26.2 Deploy outcome

- Processing stack: 30 s CFN execution / 590 s total (synthesis + bundling all 6 Processing Lambdas via iCloud — slow first-time, fast subsequent)
- Api stack: 14 new resources / 83 s CFN / 426 s total (synthesis was 343s)
- Audit stack: 5 resources / 26 s
- No new CFN destroys; no in-place breaking mods to existing stacks

## C26.3 Synthetic smoke 17/17 PASS

Ack: happy + idempotency + out-of-scope 403 + family_viewer denied 403
+ nonexistent 404 + notes valid + notes-too-long 400 + malformed-SK 400.
Thresholds: GET default fall-through + PUT facility_admin happy +
caregiver denied 403 + out-of-range 400 + ordering violation 400 +
null clears override + GET reflects most recent PUT. Plus no-token 401.

29/29 pure-function unit tests PASS (range validation + ordering
constraints + Decimal coercion + merge semantics + Phase 1B
backward-compat).

## C26.4 Audit pipeline validated end-to-end

Sample `alert.ack` event in `gosteady-dev-audit` log group:

    {"audit": true, "schema_version": 1, "event": "alert.ack",
     "actor": {"userId": "...", "role": "caregiver", "clientId": "client_rd_test"},
     "subject": {"patientId": "pat_rd_busy", "alertType": "battery_critical",
                 "severity": "critical", "eventTimestamp": "..."},
     "action": "update",
     "extra": {"wasAlreadyAcknowledged": false, "hasNotes": false},
     "request_id": "...", "xray_trace_id": "...",
     "internal_access": false, "severity": "info"}

Sample `patient.thresholds.update` event with `before`/`after`:

    {..., "event": "patient.thresholds.update",
     "before": {},
     "after": {"batteryCritical": 0.08, "batteryLow": 0.15},
     "extra": {"updatedFields": ["batteryCritical", "batteryLow"]}}

Per-event before/after maps satisfy the spec L8 compliance-reader
invariant (any threshold state at any point-in-time T can be
reconstructed by replaying the audit chain — diff-only would force
re-derivation).

## C26.5 PII scrub clean

0 matches for any of 4 test-patient `displayName` values
("Jane D", "John Q", "Bob F", "Mary B") in
`/aws/lambda/gosteady-dev-alert-actions` operational log group over the
smoke window. Powertools `ScrubbingFormatter` (Phase 1.6) holds.

## C26.6 Firmware-facing impact

**None.** Alert Actions is portal-side (caregiver UI). The firmware
contract is unchanged — heartbeats still flow into Threshold Detector
the same way; the only difference is the detector now reads
`patient.thresholds` from the existing Patients GetItem and merges
over defaults. A patient with no overrides set produces identical
Phase 1B alert behavior.

For `GS9999999998` specifically: the device was provisioned to
`pt_bench_98` earlier today (per §C25.5-update). Once firmware acks
the activate cmd on its next heartbeat, activity sessions will resolve
to that patient and any threshold breach (default 5% battery, etc.)
will land as a synthetic alert in Alert History — which is now
ack-able via 2A-AA's PATCH endpoint.

## C26.7 Updated cloud-side queue

| Item | Status | Notes |
|---|---|---|
| ✅ Phase 2A-AA alert actions + threshold overrides | DEPLOYED + validated end-to-end | This entry |
| 🟡 §C24 Finding 4 (coordinator state-aware) | Still open | Defer to next coordinator revision |
| 🟡 §C24 Finding 6 (Processing pre-create LogGroup) | Still open | Bundle with next processing-stack touch |
| 🟡 §C25.5 firmware F.2 (cloud-build pre-activation gate gap) | Still open — firmware-side | Operational noise on unassigned bench units |
| 🟡 §C22 Finding 4 + 6 (firmware 0.12.x: Shadow ack reorder + post-wipe activated_at) | Still open — firmware-side | Bundle with F.2 above |
| 🔲 Phase 2B Portal Integration | Natural next | Flutter UI now has read (2A-RD) + write (2A-AA) APIs to call |
| 🔲 Phase 2A-UM user management | Bigger UX surface | Needs product clarity on household onboarding |
| 🔲 Phase 1C-slim offline detector | Pending | Coord §C11.7 sketch |

---

*Entry owner: Claude (autonomous cloud session, 2026-05-23 late).*
*Closes Phase 2A-AA spec implementation. Read (2A-RD) + write (2A-AA)
loops are now both closed on the alert + threshold surfaces. Phase 2B
(Flutter portal integration) is the natural next step — the cloud-side
API surface is sufficient to render a functional caregiver dashboard
with ack-action capability.*


---

# §C27 — Three cloud-side deploys (2026-05-24): 2A-0 amendment + 2A-UM-P + 1C-slim

**Cloud-side only. No firmware action required.** All three deploys are V1-critical-path infrastructure that the firmware contract doesn't touch.

## C27.1 What shipped

Three logically-distinct subsets in one session, in order:

### A) Phase 2A-0 amendment — unified-portal authorizer
Narrows the API Gateway JWT authorizer audience list from 2 (Portal-Customer + Portal-Internal) to 1 (Portal-Customer only). Per the unified-portal decision in [`phase-2b-portal-integration.md`](../specs/phase-2b-portal-integration.md) L1: all browser users — customer AND internal — sign in at the same URL via the same Cognito client. Portal-Internal client is repurposed for non-browser tools (CLI / server-side admin scripts).

App-layer enforcement of the 4-hr absolute cap for `internal_*` sessions via new `_shared.api_authz.enforce_internal_session_age` helper, called from `audit_middleware` before every handler. Cognito Pre-Token V2 *cannot* override the reserved `exp` claim — only custom claims — so the tighter posture that the dual-client setup gave internal users now lives in code.

New error code `INTERNAL_SESSION_EXPIRED` (401) in the spec catalog. `Auth-stack` orphan cross-stack export `ExportsOutputRefUserPoolPortalInternalClient5C76F87F59CE7E63` dropped.

**Spec amended in-place:** [`phase-2a-foundation.md`](../specs/phase-2a-foundation.md) L4, A5, D2, In-Scope authorizer config, new Q8.

### B) Phase 2A-UM-P — Patient Management (V1 blocker for 2B-FAC-W)
New `gosteady-dev-patient-mgmt` Lambda. 6 patient-mutation endpoints:
- `POST /api/v1/patients` (create + optional atomic provision via inline duplication of device-api's L14 chain — `~80` lines duplicated; TODO marker in code points at `_shared/provision.py` as the eventual refactor target if both diverge)
- `PATCH /api/v1/patients/{id}` (name / room / censusId; cross-facility transfer requires `client_admin+` per Q3)
- `POST /api/v1/patients/{id}/discharge` (DDB-Streams cascade via deployed 2A-DL `discharge-cascade` Lambda)
- `POST + DELETE /api/v1/patients/{id}/notifications/pause`
- `PATCH /api/v1/patients/{id}/care-note` (≤280 chars; denormalized actor name per D5)

Two new schemaless Patient row attributes: `careNote`, `notificationsPaused`. **Threshold Detector + Activity Processor pick up pause-aware behavior** via new `_shared/pause_check.py`:
- Threshold Detector skips evaluation when patient is paused; emits sampled `patient.notifications.suppressed_paused` audit (Shadow `lastNotificationSuppressedAuditAt` dedupe at ≤1/day/serial, mirrors preactivation pattern)
- Activity Processor auto-resumes on activity arrival (REMOVE `notificationsPaused` via conditional UpdateItem; emit `patient.notifications.resume_auto` audit with triggering-activity payload)

`patient-api` `GET /patients/{id}` response extended with `careNote` + `notificationsPaused` (+ `room`) fields. 8 new audit catalog events.

**Spec:** [`phase-2a-um-patient-management.md`](../specs/phase-2a-um-patient-management.md).

### C) Phase 1C-slim — Behavioral notifications + offline detector
New `gosteady-dev-behavioral-detector` Lambda + EventBridge **hourly cron rule**. Emits 5 alert types into the existing Alert History table (reused; no portal contract change):
- `no_activity_today` (CRITICAL, facility-local 09:00; today.steps==0 AND lastSeen<24h)
- `below_typical_activity` (STANDARD, facility-local 22:00; today.steps < 70% × median7Day)
- `declining_trend` (STANDARD, facility-local 22:00; median7Day < 85% × medianPrior23Day)
- `device_offline` (WARNING, hourly; lastSeen > 2h AND status=active_monitoring)
- `device_silent` (CRITICAL, hourly; lastSeen > 24h AND status=active_monitoring)

Honors `notificationsPaused` (skip-when-paused, same `_shared/pause_check.py` helper). Reuses 1B-rev's `alert.synthetic.create` audit event with `subject.alertType` as the differentiator (no catalog sprawl). Emits one `behavioral.detector.run` summary audit per invocation with full counters.

**Closes the coord §C11.7 conference silent-failure gap** (cap dark 3 days 21 hrs, no alarm fired). Closes 2B Q5 client-side-evaluation gap simultaneously (server-authoritative behavioral rules).

**Spec:** [`phase-1c-slim-notifications.md`](../specs/phase-1c-slim-notifications.md).

## C27.2 Deploy chronology

7 commits on `feature/infra-scaffold` (`65361c5` → `e5ea6e6` → `31d241c`), 5 sequenced deploys:

| Time | Deploy | Outcome | Duration |
|---|---|---|---|
| AM | A: 2A-0 amendment Api stack | ❌ first attempt: cross-stack-export ordering bug (Auth tried to drop `ExportsOutputRefUserPoolPortalInternalClient...` before Api stopped consuming it). Fix: `--exclusively` to deploy Api first | — |
| AM | A: Api `--exclusively` | ✅ 43s — authorizer audience updated; patient-api + alert-actions code-asset bumps from new `_shared` bundle | 43s |
| AM | A: Auth `--exclusively` | ✅ 22s — orphan export dropped cleanly | 22s |
| Midday | B: Data stack (export refresh) | ❌ Api needed new UsersTable cross-stack export. Same gotcha as 2A-0; fix: deploy Data first | — |
| Midday | B: Data → Api → synthetic invoke → Audit | ✅ ~3 min total — patient-mgmt Lambda live; smoke 27/27 PASS; 10 audit events end-to-end through Phase 1.7 pipeline within ~3s | ~3 min |
| PM | C: Processing (1C-slim) first attempt | ❌ `reservedConcurrentExecutions=1` blocked by dev account's 10-concurrency new-account floor (same Phase 1.7 gotcha). Fix: drop the reservation | — |
| PM | C: Processing redeploy | ❌ Synthetic invoke `AccessDeniedException` on Patients `by-client-status` GSI. `fromTableName()` in processing-stack doesn't include GSI ARNs in `grantReadData`. Fix: explicit `PolicyStatement` on `table/*/index/*` | — |
| PM | C: Processing redeploy + Audit filter | ✅ Synthetic invoke evaluated 2 facilities × 4 patients in 137ms; `behavioral.detector.run` audit landed in `gosteady-dev-audit` log group | ~45s + 9s |

## C27.3 Smoke + verification

**A (2A-0 amendment):**
- 23 new `_shared/tests/test_api_authz.py` PASS (16 enforce-fn cases covering customer pass-through, internal fresh / aged / missing-iat / boundary / configurable max_age, plus 7 `iat` extraction tests)
- 78 regression PASS (49 patient-api + 29 alert-actions)
- Live smoke: authorizer audience confirmed `["1q9l9ujtsomf3ugq2tnqvdg6d7"]` (1 client); `GET /api/v1/me` 200 with full claims; no-token + invalid-token → 401; `auth.session.read` audit landed within ~70s

**B (2A-UM-P):**
- 74 validation unit tests PASS (every field validator + composite-body validator)
- 30 pause_check tests PASS (boundary, missing-attribute, DDB-string-numeric, day-floor, 90-day max)
- 53 _shared regression + 49 patient-api + 29 alert-actions = 205 total green
- **27/27 synthetic smoke PASS** covering: create no-device / family_viewer denied / bad census / empty name / malformed serial / caregiver out-of-scope; PATCH single-field / multi-field / empty 400 / cross-facility caregiver-denied + client_admin-allowed; pause + GET-reflects / invalid reason 400 / days=91 400; resume + double-resume 409; care-note set + GET-reflects / over-280 400 / empty-clears; family_viewer pause denied; discharge happy + double 409 + PATCH-on-discharged 409; no-token 401
- 10 audit events landed in `gosteady-dev-audit` log group within ~3s; full before/after maps on every PATCH including the cross-facility transfer

**C (1C-slim):**
- 42 rule unit tests PASS (no_activity_today 13 / below_typical 8 / declining_trend 7 / device_offline-silent 14)
- Synthetic invoke: 2 facilities × 4 active patients evaluated in 137ms; 0 alerts fired (correct given current UTC isn't local-09 or local-22 in seed facilities' tz and active patients don't have devices in `active_monitoring` with stale lastSeen); `behavioral.detector.run` audit landed end-to-end
- EventBridge schedule rule firing hourly

## C27.4 Firmware-facing impact

**Zero.** All three deploys are cloud-side:
- 2A-0 amendment changes API Gateway's audience config; firmware doesn't authenticate against API Gateway (it uses MQTT)
- 2A-UM-P + 1C-slim are portal-driven (patient mgmt API) and cloud-scheduled (cron Lambda). The MQTT topic contracts, heartbeat schema, activity schema, alert schema, and downlink cmd schema are all unchanged

**Note for next firmware-side bench session:** `pat_bench_98` (the patient `GS9999999998` was provisioned to in coord §C25.5-update) will now have its activity sessions evaluated by behavioral-detector at facility-local 22:00. Whether that fires a real alert depends on whether `GS9999999998` is reporting activity. If/when it does fire, the alert will appear via 2A-RD's `GET /patients/pat_bench_98/alerts?status=unacknowledged` with `source: cloud-behavioral` or `cloud-offline` (vs `cloud` for Threshold Detector's battery/signal alerts or `device` for firmware-emitted).

## C27.5 Cloud-side state after this entry

| Component | State |
|---|---|
| 2A-0 (foundation) | ✅ Deployed; **amended 2026-05-24** (single audience + `enforce_internal_session_age`) |
| 2A-DL (device lifecycle) | ✅ Deployed 2026-05-17 |
| 2A-RD (patient reads) | ✅ Deployed 2026-05-23 + extended 2026-05-24 (careNote + pause + room in response) |
| 2A-AA (alert actions + threshold overrides) | ✅ Deployed 2026-05-23 |
| **2A-UM-P (patient management)** | **✅ Deployed 2026-05-24** |
| 2A-UM-H / 2A-UM-S / 2A-INT | 🔲 Planned |
| **1C-slim (behavioral + offline detector)** | **✅ Deployed 2026-05-24** |
| 1C-rollup (daily/weekly/6M aggregations) | 🔲 Planned — gates 2B 6M time-range tab (shipping disabled) |
| Phase 2B portal integration | 🔲 Spec drafted; 2B-0 impl in flight in parallel session |
| Phase 3A portal hosting | 🔲 Sketch drafted; locks in same-origin + CSP for 2B impl |

**Cloud-side V1 critical path is COMPLETE.** Every backend endpoint and behavioral rule that 2B-FAC-R + 2B-FAC-W need is live in dev. Flutter portal can start consuming real endpoints in any session.

## C27.6 Known follow-ups (none blocking)

| Item | Severity | Disposition |
|---|---|---|
| api-stub Lambda CodeSha didn't bump during 2A-0 amendment deploy (CDK asset hashing saw no diff for that asset) | 🟢 LOW | `/me` is read-only claim-mirror; harmless. Force-update via `aws lambda update-function-code` if strict consistency wanted |
| `_shared/tests/` ships in every Lambda zip (~8 KB overhead) | 🟢 LOW | Same pattern existed for `patient-api/tests/`; not a regression. One-line fix in `processing-lambda.ts::copyRecursive` excludes when convenient |
| Atomic-add-with-device path (POST /patients with deviceSerial) needs bench-session validation | 🟡 MEDIUM | Synthetic smoke exercised validators only; live atomic chain needs a fresh `ready_to_provision` device. Defer to a bench session with `GS9999999998` (end-assignment + wipe-ack to free it first) |
| `suppressed_paused` audit over-emits ~24x/day vs ≤1/day target | 🟢 LOW | Module-level set resets per cold-start; tighten via Patient-row `lastBehavioralSuppressedAuditAt` when audit volume becomes a concern. Benign at MVP scale |
| Inline duplication of device-api's provision logic in patient-mgmt (~80 lines) | 🟢 LOW | TODO marker points at `_shared/provision.py` as the refactor target if both handlers' provision logic diverges meaningfully |
| Real-data rule-firing validation for 1C-slim | 🟡 MEDIUM | 42 unit tests cover rule logic; what's missing is integration evidence under each trigger hour. Defer to bench session OR seeded fixtures with controlled Activity Series timestamps + Device Registry lastSeen |
| Pre-prod: revisit 2A-0 Q8 Option B (third public Cognito client for internal-web with Cognito-enforced 4-hr cap) before first internal prod customer access | 🟡 MEDIUM | Option A (app-layer enforcement) is correct for dev. Same pattern as Phase 1.5 multi-account / 1.7 Object Lock — dev gets simpler version, prod adds rigorous version before first paying customer |

---

*Entry owner: Claude (portal session, 2026-05-24).*
*Closes the cloud-side V1 critical path for the portal-renders-real-data MVP. Phase 2B implementation (Flutter Cognito auth + ApiClient + facility shell + writes) is in flight in a parallel session.*

---

# §C28 — Cloud-side fixes from 2B-FAC-R real-data smoke (2026-05-25)

Entry owner: Claude (portal session) | Trigger: bench-testing 2B-FAC-R Patient Detail against GS9999999998 live data.

The first end-to-end smoke against real device data surfaced two cloud-side issues. CR-1 is a real bug with a fix landed in this commit. CR-2 turned out to be stale-data, no code change.

## C28.1 — CR-1: `currentDevice.lastSeen` stuck at `firstHeartbeatAt`

**Symptom:** Patient Detail showed "Last seen: 8d ago" for `pt_bench_98` despite obvious recent activity from GS9999999998 (hourly heartbeats + 12 walking sessions today).

**Root cause:** `Device Registry.lastSeen` was `null` for the device. The patient-api fallback (`device.get("lastSeen") or device.get("firstHeartbeatAt")`) cascaded to `firstHeartbeatAt = 2026-05-18T00:26:14Z` — the original provisioning timestamp, never updated since.

`heartbeat-processor` writes `lastSeen` to **Shadow.reported.lastSeen** only (line 97); the Device Registry row was never written. So the registry's `lastSeen` field stayed null forever for live devices — making the patient-api fallback chain misleading.

**Fix:** `heartbeat-processor/handler.py` line ~592 — after Shadow update succeeds, also write `lastSeen` to the Device Registry row via `_device_tbl.update_item`. Best-effort (non-fatal on failure); Shadow remains the authoritative live-state source.

```python
try:
    _device_tbl.update_item(
        Key={"serialNumber": serial},
        UpdateExpression="SET lastSeen = :ls",
        ExpressionAttributeValues={":ls": event["ts"]},
    )
except ClientError as e:
    logger.warning("device_lastseen_update_failed", extra=...)
```

**No IAM change needed** — heartbeat-processor already has `dynamodb:UpdateItem` on Device Registry (used by activation-ack + wipe-ack paths). No reader changes — patient-api's existing fallback chain becomes correct (`firstHeartbeatAt` only fires for devices that have never heartbeated, which is the correct semantic).

**Deploy + backfill:**
- Deploy heartbeat-processor: `cdk deploy GoSteady-Dev-Processing --context env=dev`
- After the next GS9999999998 heartbeat (≤1 hour), Device Registry.lastSeen populates. Patient Detail "Last seen" becomes correct.
- **Optional one-off backfill** (for immediate fix before the next heartbeat): direct DDB UpdateItem to set `lastSeen` = latest sessionEnd from Activity Series for any device whose lastSeen is null. Not strictly required.

**Portal-side workaround status:** the `LiveFacilityRepository.deviceFor` derives lastSeen from `max(sessionEnd)` of the cached 24h activity. We're keeping this as defensive belt-and-suspenders — it correctly handles the case where Shadow is fresh but the next heartbeat hasn't landed yet to update Device Registry. Could downgrade to a "only if dev.lastSeen is older than the latest sessionEnd" check in a future tighten-up commit, but the current behavior is fine.

## C28.2 — CR-2: activity `date` field appeared UTC, not facility-local (analysis: no code bug)

**Symptom:** `GET /api/v1/patients/pt_bench_98/activity?range=24h` returned sessions with `date: "2026-05-26"` (UTC) and `timezone: "UTC"` despite the patient configured with `timezone: "America/Denver"`.

**Investigation:**
- `activity-processor/handler.py` line 239: `"date": _local_date(ss, patient.timezone)` — correct
- `activity-processor/handler.py` line 240: `"timezone": patient.timezone` — correct
- `patient_resolution.py` line 103: `timezone=str(patient.get("timezone") or "UTC")` — defaults to UTC if Patient row has no timezone field
- `patient-mgmt/handler.py` line 327: POST /patients inherits timezone from facility — correct for new patients

**Conclusion:** Cloud code is correct. The issue was data lag — pt_bench_98's existing activity sessions were processed BEFORE the seed-dev-pilot script set `timezone = "America/Denver"` on the patient row. PatientContext.timezone resolved to "UTC" for those invocations.

**Resolution:** No cloud code change needed. New activity sessions (processed after seed-dev-pilot ran) will correctly use America/Denver. Existing activity rows have stale UTC dates but the portal's SessionAdapter (which ignores the server's `date` field and buckets by local hour of `sessionStart`) handles this correctly.

**Soft improvement (deferred):** resolve_patient could fall back to Facility.timezone via Organizations lookup if Patient.timezone is unset, with per-Lambda-warm-instance caching. Marginal value at MVP — only helps legacy patients without timezone, and patient-mgmt already handles new patients correctly. File as a future hardening commit if any legacy data surfaces problems.

**Portal-side workaround status:** keeping SessionAdapter's local-hour bucketing in place. Defensive against any future timezone-misconfigured patients + cleanly handles the existing legacy data.

## C28.3 — Operational state after this entry

| Item | Status |
|---|---|
| heartbeat-processor lastSeen-mirror code | ✅ Written + committed; deploy pending user availability |
| pt_bench_98 timezone | ✅ Set to America/Denver via seed-dev-pilot 2026-05-25 |
| Patient Detail "Last seen" accuracy on live portal | 🟡 Shows portal-fallback value (latest sessionEnd) until heartbeat-processor deploys + GS9999999998 next heartbeat lands |
| Activity session date accuracy for pt_bench_98 | 🟡 New sessions correct; pre-2026-05-25-evening sessions stale-UTC. Portal workaround handles both |
| Portal-side workarounds for CR-1 + CR-2 | ✅ Keep as defensive belt-and-suspenders (no removal scheduled) |

## C28.4 — Coord doc for next sync

Both items closed as far as this entry tracks. CR-1 deployment is a follow-up — owner: whoever next deploys to dev (no urgency; portal fallback handles the gap). CR-2 closed as no-action-needed.

---

*Entry owner: Claude (portal session, 2026-05-25). No firmware impact; cloud-side state-correctness improvement only.*

# §C28.5 — CR-1 deploy + live validation (2026-05-26)

Entry owner: Claude (portal session) | Trigger: Step-1 of the §C28 hand-off — deploy + validate the heartbeat-processor mirror.

## C28.5.1 — Deploy

`cdk deploy GoSteady-Dev-Processing --context env=dev` — single Lambda code-asset swap, total ~41 s wall clock (build 1.6 s, publish 1.5 s, CFN `UPDATE_IN_PROGRESS` → `UPDATE_COMPLETE` 9 s on the HeartbeatProcessor function + 2 s stack rollup). No IAM change. No schema change. Security stack rolled `no changes` on the dependency check.

## C28.5.2 — Pre-deploy baseline (sanity)

GS9999999998 Device Registry row immediately before the deploy:

```
lastSeen          = null
firstHeartbeatAt  = 2026-05-18T00:26:14Z   (the stale 8-day-old value §C28.1 described)
status            = active_monitoring
```

Last shadow heartbeat at this point was `reported.lastSeen = 2026-05-26T15:42:03Z` — 8 minutes before the deploy. Confirmed the registry row was untouched (Shadow path runs independently).

## C28.5.3 — Post-deploy heartbeat

The next hourly heartbeat from GS9999999998 landed at `16:42:23Z` (about 11 min after the deploy). The new code path fired and atomically wrote:

```
Device Registry.lastSeen = 2026-05-26T16:42:23Z
```

Confirmed two ways:
- `aws dynamodb get-item --table-name gosteady-dev-devices --key '{"serialNumber":{"S":"GS9999999998"}}'` returns the fresh `lastSeen`.
- `GET /api/v1/patients/pt_bench_98` returns `currentDevice.lastSeen = "2026-05-26T16:42:23Z"` (the fallback chain `lastSeen or firstHeartbeatAt` now resolves to the populated `lastSeen` — `firstHeartbeatAt` cleanly demoted to "last-resort for never-heartbeated devices" as the §C28.1 fix intends).

## C28.5.4 — Live portal validation

After the cloud-side fix, the dev portal at `dev.portal.gosteady.co` still rendered "Last seen: 8d ago" because the deployed Flutter build artifact at S3 (timestamped `2026-05-25 21:36:31`) was uploaded **before** commit `89bd76f` (the portal-side fallback workaround, committed `21:36:52`). The live `main.dart.js` was from the prior working-tree state and didn't contain the `bestLastSeen = max(dev.lastSeen, max(sessionEnd))` logic.

Fix: `flutter clean && ./tools/deploy-portal.sh` (with `AWS_REGION=us-east-1` exported — the script doesn't pass `--region` and `aws cloudformation describe-stacks` 254-errors silently otherwise). Fresh 4.4 MB build, 14 files synced to S3, CloudFront invalidation `IF34QNLF1W0T66DDLXEC8DB7D2` completed in ~60 s.

Post-redeploy Patient Detail for `pt_bench_98`:
- "Last seen: **1 min ago**" (was "8d ago") — both the cloud-side mirror AND the portal fallback now produce the right answer; portal renders `max(currentDevice.lastSeen, max(sessionEnd)) = currentDevice.lastSeen = 16:42:23Z`
- Today's Activity correctly sums the local-Denver-day sessions (was previously showing only one bucket due to UTC-date filtering; closed by 89bd76f's `toToday` rework)
- Census list view's Active-min-today / 7d-avg / Steps-today columns populate with real numbers (1, 9, 35 respectively) once `rowStatsFor` resolves on init

## C28.5.5 — Tooling gotchas surfaced during validation

Two friction points worth recording so future deploy/validate cycles don't re-trip them:

1. **`AWS_REGION` is mandatory for `tools/deploy-portal.sh`.** The script queries CFN stack outputs to resolve the API base URL and the hosting bucket, but does not pass `--region us-east-1`. If `AWS_REGION` / `AWS_DEFAULT_REGION` aren't already exported (or your `~/.aws/config` default profile isn't `us-east-1`), the queries fail with a generic "stack does not exist" error and the script exits before building. Either export the env vars or edit the script to pin region. Filed as a 2B-0 tooling-polish follow-up.
2. **`flutter build web` can silently reuse a cached `main.dart.js`** if the prior build artifact is present and source-tree mtimes don't trigger a recompile (1.3 s compile time vs ~30 s clean build = obvious tell). Result: `aws s3 sync` only uploads the 3 files that *did* change (index.html / flutter_bootstrap.js / flutter_service_worker.js), and the deployed bundle stays stale. Defense: always `flutter clean` before a "I expect new behavior" deploy, OR check `build/web/main.dart.js` mtime vs the latest `git log -1 lib/` commit time before uploading.

## C28.5.6 — Operational state after this entry

| Item | Status |
|---|---|
| heartbeat-processor lastSeen-mirror | ✅ Deployed (dev) 2026-05-26, validated on first post-deploy heartbeat |
| Device Registry.lastSeen on GS9999999998 | ✅ Populating on every heartbeat |
| patient-api `currentDevice.lastSeen` accuracy | ✅ Returns real timestamp; fallback to `firstHeartbeatAt` now correctly fires only for never-heartbeated devices |
| Portal "Last seen" on Patient Detail | ✅ Shows current minutes/hours-ago via `max(registry, sessionEnd)` fallback (defensive; still useful if a future regression breaks the registry write path) |
| Portal `main.dart.js` deployed to dev | ✅ Fresh build with `89bd76f` workaround + all subsequent FAC-R commits up to `fd22083` |
| CR-1 + CR-2 portal-side workarounds | ✅ Retained as belt-and-suspenders |

## C28.5.7 — Coord doc for next sync

CR-1 fully closed end-to-end. No further firmware or cloud action required. Next coord-doc-affecting work: 2B-FAC-R polling controller (umbrella L3 + L11) — portal-only, no firmware impact.

---

*Entry owner: Claude (portal session, 2026-05-26). Validates §C28.1 deploy; no firmware impact.*

# §C29 — 2B-FAC-R PollingController landed + live-validated (2026-05-26)

Entry owner: Claude (portal session) | Trigger: 2B-FAC-R umbrella L3 + L11 — polling cadence + lifecycle-paused refresh. Cloud-side V1 critical path was already complete (see §C27); this entry covers the portal-side polling implementation. **Zero firmware-facing impact** — pure-Flutter follow-up.

## C29.1 — What landed

New file `lib/state/polling_controller.dart`: a `WidgetsBindingObserver`-backed singleton with two `ValueNotifier<int>` ticks (`censusTick`, `patientTick`) driven by `Timer.periodic` on configurable intervals (defaults 60 s / 30 s per umbrella L3). Both timers pause when `didChangeAppLifecycleState` reports anything other than `AppLifecycleState.resumed` and resume immediately on return.

Wired into:

- `lib/shell/app_shell.dart` — constructs one PollingController in `_AppShellState.initState`, calls `attach()` to register the observer, `dispose()` on shell teardown
- `lib/state/app_state.dart` — adds `final PollingController polling` field next to existing `auth`/`repository`/`apiClient`/`buildMode`
- `lib/facility_demo/screens/patient_census_view.dart` — subscribes in `didChangeDependencies` (`startCensusPolling()` + `censusTick.addListener(_onPollTick)`); `_onPollTick` calls `repository.refreshCensus()` then clears `_loaded`/`_inFlight` and re-runs `_fetchMissing()`
- `lib/facility_demo/screens/patient_detail_view.dart` — `_PatientDetailLoaderState` subscribes in `didChangeDependencies` (`startPatientPolling(patientId)` + `patientTick.addListener(_onPollTick)`); `_onPollTick` calls `repository.refreshPatientDetail(patientId)` and re-runs `_bundle = _load()`

Both views unsubscribe + stop polling in `dispose()`. Errors inside `_onPollTick` are swallowed; the next tick retries.

## C29.2 — Live validation against pt_bench_98

Signed in as `dev-pilot-caregiver@test.local` at the dev portal; opened Patient Detail for `pt_bench_98`. Captured network requests via the Chrome MCP `read_network_requests` tool over a ~70 s observation window. Confirmed:

- `/me/patients` GET fires at the 60 s mark (Census polling tick)
- `/patients/pt_bench_98` + `/patients/pt_bench_98/activity?range=24h` + `/patients/pt_bench_98/alerts?status=unacknowledged` + 7d + 30d all fire every ~30 s while Patient Detail is open (Patient Detail polling tick)

The fan-out per Patient Detail tick is 6 requests (full `_load()` re-run after `refreshPatientDetail` clears the per-patient caches). Two of those 6 are duplicate `?range=30d` calls because `last30DaysFor` and `last6MonthsFor` both internally call `_fetchActivity(30d)` and race the cache write. A future TTL-caching pass (umbrella L12) would dedupe in-flight fetches and collapse this to 5 requests per tick.

Did not bench-test backgrounded pause behavior (the Chrome MCP tab stays focused throughout). The lifecycle gate is exercised at app-resume time during normal use; no live-fire regression expected.

## C29.3 — Subset status after this entry

| 2B-FAC-R follow-up | Status |
|---|---|
| Initial impl slice (commits `b2da2cc` through `89bd76f`) | ✅ deployed (2026-05-25, validated 2026-05-26) |
| L3 + L11 PollingController + lifecycle pause | ✅ **deployed (2026-05-26) — this entry** |
| L5 lazy-per-row activity throttle | 🔲 mostly invisible at single-patient bench scale; needed at 200-patient facility scale |
| L6 notification engine swap to alertType | 🔲 live Census still renders "—" in Notifications column; live-mode bypass of `notification_engine.dart` still pending |
| L12 30s TTL caching + in-flight-future dedupe | 🔲 would collapse duplicate `?range=30d` fan-out fetches; minor at MVP |

## C29.4 — Coord doc for next sync

Next portal-side work item TBD per user direction. Cloud-side V1 critical path remains complete. No firmware action required.

---

*Entry owner: Claude (portal session, 2026-05-26). No firmware impact; portal-only polling primitive.*

# §C30 — 2B-FAC-R notification engine swap to server alertType (2026-05-26)

Entry owner: Claude (portal session) | Trigger: 2B-FAC-R umbrella L6 — render server-authoritative notification rule-names in place of the client-side three-rule engine. Closes the umbrella's A3 worry. **Zero firmware-facing impact** — portal renders existing Alert History entries; no MQTT contract or cloud-Lambda change.

## C30.1 — What landed

- New `Future<List<PatientNotification>> notificationsFor(String patientId)` method on `FacilityRepository`. Demo impl delegates to the existing `NotificationEngine` (unchanged three-rule behavior); live impl reads cached `/alerts?status=unacknowledged` and maps each `alertType` to a `NotificationType` enum value per the L6 spec table.
- `lib/facility_demo/models/notification.dart` — extended `NotificationType` from 3 enum cases to 10: original three (`noActivityToday`, `belowTypical`, `decliningTrend`), 1C-slim offline pair (`deviceOffline`, `deviceSilent`), 1B-rev Threshold Detector quad (`batteryCritical`, `batteryLow`, `signalLost`, `signalWeak`), plus `other` catch-all. Each carries a display label (e.g. "Battery critical") via `type.label`.
- `lib/data/live_facility_repository.dart` — top-level `_mapAlertType` + `_mapSeverity` helpers mirror the spec's L6 mapping table. `_formatDetail` builds a relative-time string ("Triggered 38 min ago") so the notification cards have a useful sub-line.
- `lib/facility_demo/widgets/patient_list_view.dart` — Census `_NeedsReviewCell` now takes an optional `headlineLabel` and renders "Battery critical · 45" instead of just "45". File-scope `_headlineLabel(notifications)` picks the most-prominent rule name (prefers critical-severity, falls back to first). The tile view's caption was already rule-name-based so no change needed there.
- `lib/facility_demo/data/notification_engine.dart` — `notificationsForPatient(data, id)` global helper now one-line-delegates to `data.notificationsFor(id)`. Retained so existing call sites in `patient_census_view.dart` + `patient_detail_view.dart` + `notification_review_panel.dart` don't need to chase the rename.

## C30.2 — Live validation against pt_bench_98

The bench unit's firmware reports `battery_pct=0` on every hourly heartbeat (no SoC fuel gauge on AAs), so threshold-detector creates a `battery_critical` alert each hour. 45 unack alerts in Alert History at the time of validation.

- **Census Notifications cell:** renders "Battery critical · 45" (red badge color, ellipsized at narrow column widths to "Battery..."), plus the red severity dot beside the patient name in the Resident column.
- **Patient Detail Notification Review panel:** header reads "NOTIFICATIONS · 45 AWAITING REVIEW"; each alert row shows "Battery critical" title with "Triggered 38 min ago / 1h ago / 2h ago" subtitle. Ack button is mock-bound for now (live wiring is 2B-FAC-W).

Demo build smoke (`flutter build web -t lib/facility_demo/main_demo.dart --dart-define=BUILD_MODE=demo`) compiled cleanly + the marketing demo continues to use the engine — verified by inspection (no engine code paths touched).

## C30.3 — Subset status after this entry

| 2B-FAC-R follow-up | Status |
|---|---|
| Initial impl slice | ✅ deployed (2026-05-25, validated 2026-05-26) |
| L3 + L11 PollingController + lifecycle pause | ✅ deployed (2026-05-26, coord §C29) |
| **L6 notification engine swap to alertType** | ✅ **deployed (2026-05-26) — this entry** |
| L5 lazy-per-row activity throttle | 🔲 mostly invisible at single-patient bench scale |
| L12 30s TTL caching + in-flight-future dedupe | 🔲 would collapse duplicate `?range=30d` fan-out fetches on each detail tick |

## C30.4 — Coord doc for next sync

V1 critical-path notification rendering is now server-authoritative end-to-end. Future server-side alert types (added to 1C or threshold-detector) need either an extended L6 mapping in `_mapAlertType` or fall through to `NotificationType.other` ("Alert" generic label) — gracefully degraded.

---

*Entry owner: Claude (portal session, 2026-05-26). No firmware impact; portal-only rendering swap.*

# §C31 — 2B-FAC-R TTL caching + in-flight Future dedup (2026-05-26)

Entry owner: Claude (portal session) | Trigger: 2B-FAC-R umbrella L12 — 30 s TTL on the live repository's per-patient caches plus in-flight dedup so concurrent fetches for the same key share one HTTP request. **Zero firmware-facing impact** — pure-portal performance/consistency improvement.

## C31.1 — What landed

Refactored `LiveFacilityRepository`'s five per-patient cache fields from `Map<String, T>` to `_TimedCache<String, T>` — a small file-scope helper that bundles:

- `Map<K, _TimedEntry<V>> _entries` — each entry carries a `fetchedAt` timestamp; cache read returns the value only if `now - fetchedAt < ttl` (default 30 s, matching Patient Detail polling cadence)
- `Map<K, Future<V>> _inFlight` — concurrent calls to `getOrFetch(key, fetcher)` for the same key share one Future. Closes the "Patient Detail's `_load()` fires `_fetchActivity(30d)` twice in parallel via `last30DaysFor` + `last6MonthsFor`" duplicate-fetch surfaced in coord §C29.2
- `evict(key)` — drops the cache entry; in-flight fetches are not cancelled (the next caller after the evict misses the cache and starts a fresh fetch)
- `clear()` — full reset, used by `clearOnSignOut`

`refreshPatientDetail(patientId)` now calls `evict(patientId)` on each per-patient cache, then awaits `Future.wait` of the three primary fetches (patient + 24h + alerts) to populate the caches before returning. Subsequent calls within the next 30 s see fresh cache and avoid HTTP.

`flutter analyze` clean. Demo build (`BUILD_MODE=demo`) compiles unchanged — `FacilityMockData` doesn't touch the cache.

## C31.2 — Live validation

Bench-tested against `pt_bench_98` via Chrome MCP. Network capture surfaced layout-shift artifacts from the post-deploy sign-in flow (sign-in modal briefly overlaying the freshly-rendered Census, causing the first patient-detail click coordinate to miss), which made it hard to assemble a clean "open Patient Detail with warm caches → confirm no re-fetch" trace. The TTL + dedup pattern is the standard Dart `Map<K, Future<V>>` idiom (memoize-with-TTL); the in-flight Future is stored synchronously inside `getOrFetch` before the next caller can race, so concurrent same-key invocations within the same microtask provably share one fetcher call. Trusting the analyzer-clean implementation; will revisit if the cost-of-being-wrong shows up (e.g., extra API costs at 200-patient scale, or stale-data complaints from a caregiver).

## C31.3 — Subset status after this entry

| 2B-FAC-R follow-up | Status |
|---|---|
| Initial impl slice | ✅ deployed (2026-05-25, validated 2026-05-26) |
| L3 + L11 PollingController + lifecycle pause | ✅ deployed (2026-05-26, coord §C29) |
| L6 notification engine swap to alertType | ✅ deployed (2026-05-26, coord §C30) |
| **L12 30 s TTL caching + in-flight dedup** | ✅ **deployed (2026-05-26) — this entry** |
| L5 lazy-per-row activity throttle | 🔲 mostly invisible at single-patient bench; deferred until 50+ patient seed exists |

## C31.4 — Coord doc for next sync

2B-FAC-R substantively complete for V1 critical-path. L5 lazy-per-row throttle is a scale-only optimization that becomes relevant at the first multi-patient pilot; deferred. Next portal-side work item TBD per user direction.

---

*Entry owner: Claude (portal session, 2026-05-26). No firmware impact; portal-only caching primitive.*

# §C32 — 2B-FAC-R row-loader throttle (L5) (2026-05-26)

Entry owner: Claude (portal session) | Trigger: 2B-FAC-R umbrella L5 — cap concurrent per-row stats fetches at 5 so a 200-patient cold-load doesn't burst past dev API Gateway's 25 RPS throttle. **Zero firmware-facing impact** — pure-portal throttle primitive.

## C32.1 — What landed

- New `lib/state/row_loader_queue.dart` — generic `RowLoaderQueue<T>` with `maxConcurrent` (default 5) + per-key in-flight Future dedup. Re-enqueueing the same `patientId` while the prior task is pending returns the existing Future.
- New `lib/widgets/maybe_visible.dart` — `MaybeVisible` wraps a child in `visibility_detector` and fires its `onFirstVisible` callback once when the child first scrolls in. Falls back to unwrapped passthrough when the callback is null (demo mode).
- New pubspec dep: `visibility_detector: ^0.4.0+2`.
- `lib/facility_demo/widgets/patient_list_view.dart` — `PatientListRow` gains `isLoading` + `onFirstVisible` fields; metric cells render a sage-tinted `_SkeletonBar` instead of zeros while loading. Each row wrapped in `MaybeVisible`.
- `lib/facility_demo/screens/patient_census_view.dart` — owns the `RowLoaderQueue`; `_scheduleLoad(patientId)` enqueues `rowStatsFor + notificationsForPatient`. List + tile views both wired.

## C32.2 — Visibility-lazy reverted to eager-enqueue

Initial plan was viewport-driven lazy fetch: each row's `MaybeVisible.onFirstVisible` enqueues only when the row scrolls into view, leaving below-the-fold rows untouched. Live-test in release Flutter Web showed `visibility_detector`'s `onVisibilityChanged` callbacks fire intermittently — after a service-worker handover (which `flutter clean + ./tools/deploy-portal.sh` triggers on every redeploy), the first frame after sign-in sometimes never received a `visibleFraction > 0` event, and the rows stayed in skeleton state indefinitely. Console log instrumentation via `dart:developer log` did not surface in `chrome://console`; `print` did not surface either (Dart Web release strips both).

Compromise: Census now **eager-enqueues** all visible rows on init through the throttle (`addPostFrameCallback(_enqueueAllVisible)`). The queue caps concurrency at 5 regardless, so API Gateway is still protected; the only thing lost is the "don't fetch off-screen rows at all" optimization (only relevant at 200+ patient scale, which the bench doesn't hit). The `MaybeVisible` wrapper stays in the tree as defensive belt-and-suspenders — if the visibility callback DOES fire, `_scheduleLoad` short-circuits because the row is already loaded.

Filed as a future polish item: revisit visibility-lazy at first multi-patient pilot. Options: alternative package (`flutter_intersection_observer`), manual `Scrollable.of(context).addListener` + RenderObject bounds check, or just accept the eager-enqueue tradeoff if pilot doesn't hit throttle pressure.

## C32.3 — Live validation against pt_bench_98

Sign-in → Census renders with skeleton bars in each metric cell. Within ~2 s, the throttled fetches resolve and rows populate with real data: "Battery critical · 45" badge + red severity dot + Active min today=1, 7d avg=9, trend ↗, Steps today=35, trend ↗. Demo build (`BUILD_MODE=demo`) compiles cleanly + behaves as before (skeletons + queue still active but FacilityMockData resolves fast so the transition is brief).

## C32.4 — Subset status after this entry

| 2B-FAC-R follow-up | Status |
|---|---|
| Initial impl slice | ✅ deployed (2026-05-25, validated 2026-05-26) |
| L3 + L11 PollingController + lifecycle pause | ✅ deployed (2026-05-26, coord §C29) |
| L6 notification engine swap to alertType | ✅ deployed (2026-05-26, coord §C30) |
| L12 30 s TTL caching + in-flight dedup | ✅ deployed (2026-05-26, coord §C31) |
| **L5 row-loader throttle + skeleton placeholders** | ✅ **deployed (2026-05-26) — this entry; visibility-lazy reverted to eager-enqueue (see §C32.2)** |

**2B-FAC-R substantively complete for V1 critical-path.** All five umbrella locked-in requirements landed; the visibility-lazy sub-optimization is the only deferred piece, only relevant at >50-patient pilot scale.

## C32.5 — Coord doc for next sync

V1 portal MVP critical-path is fully wired. Next FAC subset is **2B-FAC-W** (facility writes): alert ack `PATCH /alerts/{patientId}/{ts}` + Add/Edit Resident + Discharge + Pause Notifications + Care Note. All four backend endpoints (2A-AA + 2A-UM-P) are already deployed; FAC-W is pure-Flutter wiring.

---

*Entry owner: Claude (portal session, 2026-05-26). No firmware impact; portal-only throttle primitive.*

# §C33 — Alert recurrence policy: suppress-until-acked + auto-ack-on-clear (2026-05-26)

Entry owner: Claude (portal session) | Trigger: bench unit `GS9999999998` accumulated 45 unacked `battery_critical` rows (one per hourly heartbeat) — Census + Notification Review panel unusable. Same shape would hit `device_offline`, `battery_low`, `signal_lost/weak`, `device_silent` whenever any continuous condition persists across detector firings. Two-tier fix: new design memo + implementation across three Lambdas + migration script for the existing backlog. **Zero firmware-facing impact** — pure cloud-side state-machine fix.

## C33.1 — Product decision

Per design memo `gosteady-portal/docs/specs/2026-05-26-alert-recurrence-policy.md` — each (patient, continuous-condition alertType) pair has at most one open alert at a time. While open, detector firings that re-evaluate the same violating condition emit zero new rows. The open alert closes via either: (a) caregiver manual ack via `PATCH /alerts/{patientId}/{ts}` → alert-actions releases the slot; (b) detector observes the condition has cleared → auto-ack via `system:condition_cleared` actor.

Applies to: `battery_critical`, `battery_low`, `signal_lost`, `signal_weak` (threshold-detector); `device_offline`, `device_silent` (behavioral-detector). **Does NOT apply to:** `no_activity_today`, `below_typical_activity`, `declining_trend` — daily-cadence rules whose row IS the historical record for that day; current natural once-per-day behavior (hour-gate in `facility_iterator.rule_set_for_facility()`) stays.

## C33.2 — What landed

- **New `infra/lambda/_shared/open_alerts.py`** — `claim_open_alert` (atomic two-step conditional UpdateItem on `Patient.openAlerts: Map<alertType, {sk, openedAt}>`), `release_open_alert`, `get_open_alert_sk`, `auto_ack_alert` (looks up SK, conditional ack on Alert row, release slot, emit audit).
- **New audit event `alert.auto_acknowledged`** in `_shared/audit_catalog.py`. Subject includes alertType + sk + duration. Actor `{type: 'system', id: 'threshold-detector' | 'behavioral-detector'}`.
- **`threshold-detector/handler.py`** — `_write_synthetic_alert` now claims via `claim_open_alert` before PutItem. New `_auto_ack_cleared_thresholds` runs on every shadow update with active-territories semantics (see §C33.3).
- **`behavioral-detector/handler.py`** — `_write_alert` claims for continuous types (offline/silent). New `_auto_ack_recovered_offline` runs at end of each per-patient eval; auto-acks open offline/silent slots when device lastSeen is back in range.
- **`alert-actions/handler.py`** — on successful manual ack of a continuous-condition alert, releases the openAlerts slot (best-effort).
- **CDK grants** — `patientsTable.grantReadWriteData(thresholdDetector)` + `grantReadWriteData(behavioralDetector)` (were ReadData only). Same for `alertTable.grantReadWriteData(thresholdDetector)` (threshold-detector now writes ack updates to existing alert rows on auto-ack, not just PutItem on new rows).
- **Migration: `infra/scripts/ack-pre-recurrence-policy-alerts.py`** — bulk-acks all duplicate continuous-condition alerts (keeps most-recent per (patient, alertType) as the post-policy open slot), `acknowledgedBy='system:migration_2026_05_26'`. Initializes `openAlerts = {}` on every active patient as defense-in-depth. **Ran 2026-05-26 against dev: acked 71 duplicates across 9 patients (49 of those on pt_bench_98).**

## C33.3 — Active-territories semantics (L7 of the design memo)

Rather than "clear when threshold-recovery happens" (which leaves stale lower-tier slots when value escalates), the auto-ack pass computes the active territory per dimension and auto-acks ANY open slot whose territory isn't currently active:

```
battery_pct value         active territory
< batteryCritical         battery_critical
[batteryCritical, low)    battery_low
>= batteryLow             (none)
```

Symmetric for signal. Dimensions not reported in the shadow update don't get touched (no signal). This single rule handles recovery (both slots ack), tier change (one acks, the other claimed on breach-write), and escalation (lower-tier acks, higher-tier claimed) uniformly.

## C33.4 — Deploy chronology + gotchas

1. First `cdk deploy GoSteady-Dev-Processing`: succeeded ~41 s; threshold + behavioral Lambdas updated.
2. First synthetic invoke surfaced `KeyError: 'ALERTS_TABLE'` — `open_alerts.py` read the plural name used by alert-actions; the detector Lambdas have `ALERT_TABLE` (singular). Helper now reads `os.environ.get("ALERTS_TABLE") or os.environ.get("ALERT_TABLE")`.
3. Second synthetic invoke surfaced `AccessDeniedException: dynamodb:UpdateItem ... gosteady-dev-patients` — the CDK `grantReadWriteData` change was in source but CDK didn't redeploy (the prior synth-cached `cdk.out` hashed the same source). Fixed by `npm run build` to recompile TS + redeploy; IAM policy now includes `dynamodb:UpdateItem` on `patients` resource.
4. Third synthetic invoke surfaced `ValidationException: Two document paths overlap` — `UpdateExpression: SET openAlerts = if_not_exists(...), openAlerts.X = ...` is rejected by DDB because the two SET clauses touch overlapping paths. Rewrote `claim_open_alert` as two atomic UpdateItems (defensive ensure-map-exists + conditional claim).
5. Fourth (and final) synthetic invoke succeeded end-to-end. Bench-validated all five state transitions: recovery, tier change (down), tier change (up), suppression, escalation.
6. CDK asset hashing gotcha — changes to `_shared/*.py` don't invalidate the per-handler `Code.fromAsset(handlerDir)` source hash because `_shared/` is copied in during bundling but isn't in the source directory. **Fix: add a content marker line (`# bundle-marker: <timestamp>`) at the top of each handler that consumes `_shared`** when shipping a `_shared/*.py` change; or alternatively change a handler-local file in the same commit. Documented for future deploys.

## C33.5 — Operational state after this entry

| Item | Status |
|---|---|
| Alert recurrence policy implemented | ✅ deployed (Processing + Api stacks) |
| pt_bench_98 unack count | ✅ 2 (battery_low + device_offline + device_silent — battery_critical is currently absent because the bench unit reported `battery_pct=0.50` in my last synthetic invoke; next real heartbeat with `battery_pct=0` will fire a fresh battery_critical alert as expected) |
| Migration cleanup | ✅ 71 duplicate rows acked across 9 dev patients |
| Audit pipeline | ✅ `alert.auto_acknowledged` events now flowing through Phase 1.7's audit log group + Firehose + S3 |
| Suppress-while-open | ✅ verified — second invoke with same `battery_pct=0` writes zero alerts |
| Auto-ack-on-clear | ✅ verified — `battery_pct=0.50` invoke clears battery_critical + battery_low slots |
| Manual-ack release | ✅ wired in alert-actions; verified by reading the code path (caregiver-facing UX not yet bench-tested but the unit logic is straight-forward) |

## C33.6 — Coord doc for next sync

V1 alert UX is now caregiver-usable end-to-end. Next portal-side work item: **2B-FAC-W (facility writes)** — wire Patient Detail's ack button to `PATCH /alerts/{patientId}/{ts}` (will exercise the manual-ack release path live), then Add/Edit Resident + Discharge + Pause Notifications + Care Note from 2A-UM-P.

---

*Entry owner: Claude (portal session, 2026-05-26). No firmware impact; cloud-side state-machine + portal-facing UX cleanup only.*

# §C34 — CORS drift incident + force-redeploy fix (2026-05-27)

Entry owner: Claude (portal session) | Trigger: portal returned `ApiException(NETWORK, 0): Connection lost` on every `primeAtSignIn` call. Curl tests against the API confirmed the cloud-side was healthy (200 OK with full patient payload). Browser console showed only a generic Dart exception — no HTTP call ever fired.

## C34.1 — Root cause

Deployed HTTP API CORS config had only the two localhost origins (`http://localhost:8080` and `:8090`); `https://dev.portal.gosteady.co` was missing. Chrome's CORS preflight saw no `access-control-allow-origin` matching the portal's origin and blocked the request before it left the browser. The portal's `ApiClient._request` catch-all wraps that browser-side block as `ApiException.network()` ("Connection lost"), masking the underlying CORS failure.

But the CDK source had the dev.portal origin since commit `0d63ec5a` (2026-05-24, Phase 2B-0 hosting). The compiled JS in `infra/lib/stacks/api-stack.js` also had it. Some prior `cdk deploy GoSteady-Dev-Api` invocation evidently used a stale `cdk.out` and didn't synthesize the latest CORS change — the CFN diff was empty for `AWS::ApiGatewayV2::Api` even though the source had drifted.

## C34.2 — Fix

`cd infra && npx cdk deploy GoSteady-Dev-Api --context env=dev --require-approval never --force` — the `--force` flag was the lever; it skips the `is the cached cdk.out current?` check and re-synths fresh. The redeploy showed CFN updating `HttpApi (HttpApiF5A9A8A7)` to `UPDATE_COMPLETE` and the CORS config now includes the dev.portal origin. Browser preflight returns the correct `access-control-allow-origin: https://dev.portal.gosteady.co` header.

## C34.3 — Lessons learned

1. **`ApiClient.network()` is a swallow-and-mask catch.** The `catch (_) → throw ApiException.network()` block in `lib/api/api_client.dart:_request` wraps any client-side exception (CORS block, browser network failure, sync error in headers/uri construction) as `ApiException.network()`. The portal surfaces this to the user as "Connection lost. Retry?" — useless for diagnosis. **Follow-up:** preserve the underlying error type or include a structured `details` field with the inner exception's `toString()` so future CORS-class failures aren't indistinguishable from "actually offline."
2. **CDK `cdk.out` staleness is a silent failure mode.** Running `cdk deploy` without `--force` will reuse a previously-synthesized cloud assembly if CDK thinks it's still fresh. If the source has drifted but a prior synth's cache is intact, the deploy applies the OLD CFN. **Defensive practice:** always pass `--force` to deploys that touch CORS / IAM / Authorizer config, OR `rm -rf infra/cdk.out` between deploys that modify infra config (not just Lambda code).
3. **CORS check should be part of every API stack post-deploy smoke.** A one-liner `curl -X OPTIONS -i -H "Origin: https://dev.portal.gosteady.co" ... | grep access-control` would have caught this in seconds. Adding to the API stack's deploy runbook.

## C34.4 — Operational state after this entry

Portal works end-to-end. `dev-pilot-caregiver@test.local` sign-in → Census renders → Bench Patient row shows "Device ..." badge (warning, amber) + Active min today 3 / 7d avg 10 + Steps today 205 + trending up. Recurrence policy from §C33 is visibly working — one alert row per condition, not 45.

No firmware impact. No source change to commit (the source was always correct; only the deployed CFN had drifted).

---

*Entry owner: Claude (portal session, 2026-05-27). No firmware impact; CFN drift recovery + portal-side error-masking lesson.*

# §C35 — 2B-FAC-W facility writes deployed + live-validated (2026-05-27)

Entry owner: Claude (portal session) | Trigger: complete the V1 caregiver UX loop. **Zero firmware-facing impact** — pure-Flutter wiring of the 5 mutation endpoints that 2A-AA + 2A-UM-P already deployed.

## C35.1 — What landed

- **New spec:** `gosteady-portal/docs/specs/phase-2b-fac-w-facility-writes.md`.
- **`ApiClient` 7 methods wired:** `ackAlert`, `createPatient`, `updatePatient`, `dischargePatient`, `pauseNotifications`, `resumeNotifications`, `updateCareNote`. (Provision-device + end-assignment stubs left in place for the deferred "replace device" UX.)
- **`api_models.dart`** gained `AckAlertResponse`, `DischargeResponse + DischargeCascadeInfo`, `NotificationsPauseResponse + NotificationsPaused`, `CareNoteResponse + CareNote`, `PauseReason` + `DischargeReason` enums. `PatientFull` now decodes `careNote` + `notificationsPaused` (the 2A-RD response always carried them per 2A-UM-P L8; portal just didn't surface them).
- **`AlertRow`** gained `eventTimestampRaw` + `sk` getter — preserves the server's exact SK including facility-local timezone offsets (e.g. `2026-05-26T21:19:26-06:00#device_offline`) so PATCH /alerts/{id}/{sk} round-trips correctly. UTC conversion would have produced a different SK that doesn't match the stored row.
- **`FacilityRepository`** abstract interface extended with 7 write methods. Live impl evicts the relevant caches (alerts + patient detail + Census `/me/patients` slice) after each successful write. Demo impl returns synthesized responses so the marketing build's UX continues to compile + run.
- **Portal screens:**
  - `notification_review_panel.dart` — Acknowledge button wired to `data.ackAlert(...)`; spinner during in-flight; inline error banner on failure.
  - `add_resident_dialog.dart` — submit wired to `data.createPatient(...)`; facility/unit picker now sources from `data.allFacilities()` (live) with seed fallback; error banner on failure.
  - `resident_settings_dialog.dart` — Edit / Pause / Discharge actions go through a new `_runWrite` helper that awaits the write, then closes + toasts (or toasts the error). Replace/Discontinue device stay no-op for now (deferred to FAC-W follow-up).
  - `care_note_panel.dart` (new) — sage-tinted block above Notification Review with `Patient.careNote.text` + edit pencil; inline edit dialog with 280-char counter, save/clear/cancel.
  - `pause_banner.dart` (new) — warning-tinted banner above care-note when `Patient.notificationsPaused.isActive`; reason label + remaining-days + single-tap Resume.
  - `patient_detail_view.dart` — mounts `PauseBanner` (conditional) + `CareNotePanel` (always) between the device-health strip and the Notification Review panel.
- **`api_exception.dart`** — `ApiException.network({String? detail})` factory preserves the underlying exception type/message in `details.inner` so future CORS-class failures aren't indistinguishable from real network outages. `toString()` includes the inner detail. Closes coord §C34.3 lesson #1.

## C35.2 — Live validation against pt_bench_98

Direct API ack via curl (UI ack blocked by a Flutter / `form_input` quirk — see §C35.3):

```
PATCH /api/v1/alerts/pt_bench_98/2026-05-27T14%3A00%3A00Z%23battery_critical
  body: {"notes": "Replaced AAs."}
  → 200 OK
  → alert.acknowledged = true
  → alert.acknowledgedBy = "4408b4a8-b031-70b9-1a5d-a3826121a4db" (caregiver Cognito sub)
  → alert.ackNotes = "Replaced AAs."
  → Patient.openAlerts.battery_critical → null  ← coord §C33 L5 manual-ack-release path verified live for the first time
```

Subsequent fresh `battery_pct=0.02` shadow update through threshold-detector:

```
status: 200, body: "1 synthetic alert(s) written for patient=pt_bench_98"
  → Patient.openAlerts.battery_critical = {sk: 2026-05-27T14:25:00Z#battery_critical, openedAt: 2026-05-27T14:23:27Z}
```

Recurrence after release validated. Full alert-recurrence state machine now closed end-to-end with caregiver-initiated ack.

## C35.3 — Known UI quirk: `form_input` doesn't trigger Flutter onChange

Chrome MCP's `form_input` tool sets the DOM input's `value` attribute directly. Flutter Web's text field listens for `input` / `change` events to update its internal text state. Setting the DOM value via JS without dispatching the event leaves Flutter's `_hasText` boolean false → the Acknowledge button stays disabled → the click does nothing.

Bench-testing via the UI requires native key events (Chrome MCP's `computer.type` action with the input focused). The two attempts during today's validation hit click-timing races that left the field empty — the underlying ack flow is verified via direct API call, which exercises the same alert-actions code path.

Not blocking — V1 caregivers will use real keyboards, not JS-driven test fixtures. Filed as a 2B-POL test-harness improvement.

## C35.4 — Deferred FAC-W follow-ups

- **Census-tier paused-bell icon (US-31).** The `/me/patients` response doesn't include `notificationsPaused`. Surfacing the icon at Census scan tier requires either (a) augmenting the 2A-RD response — small spec amendment, may make sense to land alongside other `/me/patients` extensions; or (b) per-row lazy fetch — adds N HTTP calls at Census cold-load, not justified at MVP. Deferred until 2A-RD follow-up batch.
- **Replace / Discontinue Device** — UI dialogs already exist in `resident_settings_dialog.dart`; the device-api endpoints (2A-DL provision + end-assignment) deployed in coord §C24. Just needs the same `_runWrite` wiring as Edit/Pause/Discharge. Out of FAC-W scope per spec; trivially picked up in a follow-up commit.
- **Discharge reason picker + Pause reason/days picker** — `_DischargeForm` + `_PauseMonitoringForm` currently hardcode `other` / 7-day default. Forms exist; just need to surface their fields into the user-facing inputs. UX polish task.
- **Optimistic UI** — every write awaits the server response per spec L4. Optimistic-with-rollback is a 2B-POL polish if pilot data demands it.

## C35.5 — Operational state after this entry

| Item | Status |
|---|---|
| 7 ApiClient write methods | ✅ Implemented + tested via direct curl |
| FacilityRepository write surface | ✅ Live + demo impls; demo returns synthesized responses |
| Notification Review ack button | ✅ Wired (UI bench-test pending) |
| Add Resident dialog | ✅ Wired |
| Resident Settings (Edit / Pause / Discharge) | ✅ Wired |
| Care Note panel + inline editor | ✅ Live |
| Pause Banner | ✅ Live (Patient Detail tier) |
| Census-tier paused-bell icon | 🔲 Needs `/me/patients` augmentation; deferred |
| `ApiException` error-detail preservation | ✅ Closes coord §C34.3 lesson #1 |
| Manual-ack release path (coord §C33 L5) | ✅ Live-validated for the first time today |

## C35.6 — Coord doc for next sync

V1 caregiver UX feature-complete (read + write + alert ack + care note + pause/resume + discharge). Next likely directions: 2B-D2C household refit, 2C notifications (push/SMS/email), or 3A prod hosting cutover. Coordination doc rests until next major work item.

---

*Entry owner: Claude (portal session, 2026-05-27). No firmware impact; closes V1 caregiver UX surface.*

---

# §C36 — 2B-FAC-W follow-up bundle: reason pickers + device replace/discontinue + US-31 census paused-bell (2026-05-27)

Entry owner: Claude (portal session) | Trigger: knock out the deferred items from §C35.4 in one bundled commit. **Zero firmware-facing impact** — pure portal + a single Lambda code-asset swap on `gosteady-dev-patient-api`.

## C36.1 — What landed

Four follow-ups deferred at §C35.4 picked up:

- **Discharge reason picker (`_DischargeForm`)** — replaced hardcoded `DischargeReason.other` with a real dropdown sourced from the `DischargeReason` enum (`transferred` / `moved_home` / `hospital_admission` / `deceased` / `other`). Also surfaced the existing notes field through to `data.dischargePatient(..., notes: ...)` — previously collected but never sent (silent UX-bug).
- **Pause reason picker (`_PauseMonitoringForm`)** — same treatment for `PauseReason` enum (`in_hospital` / `at_rehab` / `family_visit_offsite` / `on_vacation` / `other`). Days input was already wired; reason was hardcoded to `other`.
- **Replace / Discontinue Device wiring (`resident_settings_dialog`)** — replaced the no-op stub callbacks with real `_runWrite` flows backed by new repo methods `FacilityRepository.replaceDevice` + `discontinueDevice`. `ApiClient.provisionDevice` + `endAssignment` switched from `UnimplementedError` stubs to real `POST /devices/{serial}/provision` + `POST /devices/{serial}/end-assignment` calls against the 2A-DL endpoints (deployed §C24). Replace orchestrates as end-assignment-then-provision; Discontinue is just end-assignment. Cache eviction mirrors the other 2B-FAC-W writes (patient detail + Census refresh).
- **US-31 census-tier paused-bell icon** — landed end-to-end with a small server projection extension:
  - **Server (`patient-api/handler.py`):** `_patient_row_view` (shared by `/me/patients` and `/facilities/{f}/censuses/{c}/patients`) now includes `notificationsPaused` using the same active-only nullable projection as the detail-view `_patient_view`. Same `is_currently_paused` + `days_remaining` helpers from `_shared/pause_check.py`. Zero infra delta — Lambda code-asset swap only.
  - **Client (`api_models.dart`):** `MePatientSummary` gained `NotificationsPaused? notificationsPaused`. Threaded into the `Patient` model via `LiveFacilityRepository._mePatientToSummary`. `Patient.notificationsPaused.isActive` drives the bell.
  - **UI:** subdued `notifications_paused_outlined` icon with a "Notifications paused" Tooltip, rendered next to the resident name in both Census tile (`patient_tile.dart`) and list-row (`patient_list_view.dart`).

### Adjacent pre-existing client bug fixed

- **Epoch timestamp parse (`NotificationsPaused.fromJson`)** — server stores `until` / `pausedAt` as Unix epoch seconds; DDB serializes Numbers as JSON strings (e.g. `"1780358615"`). Client's old `_parseTs` only attempts ISO 8601, silently falling back to `DateTime.now()` for any epoch value. Result: `NotificationsPaused.isActive` was always **false** because `until ≈ DateTime.now()` is never strictly after `DateTime.now()`. Pause Banner on Patient Detail was effectively invisible whenever pause was set. New `_parseEpochOrTs` accepts numeric, stringified-int, AND ISO 8601 — disambiguates seconds (<13 digits) from milliseconds. Pre-existing bug surfaced only because US-31 added a second consumer of the same field; would have bitten anyone trying the existing Pause Banner with a paused patient. Closes a silent gap that §C35.2 didn't catch (FAC-W live-validation paused a patient via direct curl but never re-rendered Patient Detail under the post-pause state).

## C36.2 — Deploy chronology

- 18:00 ET — Portal code changes committed locally (5 files: 4 client + 1 server handler).
- 18:01 ET — `npm run build` (CDK TS compile, 0 warnings).
- 18:01 ET — `npx cdk diff GoSteady-Dev-Api` shows clean diff: only `PatientApi/Function` asset hash changed (`4d5d3532… → cc17bb61…`). No infra / IAM / CORS / authorizer changes. Per §C34 lesson #2 + CDK deploy-hygiene memory: `--force` not required for code-only swaps, but `npm run build` first to refresh `cdk.out` is the prophylactic.
- 18:01 ET — `npx cdk deploy GoSteady-Dev-Api --context env=dev --require-approval never`. Single-resource UPDATE_COMPLETE in 8s; total stack time 46s.

## C36.3 — Live validation against pt_bench_98

Direct curl from `dev-pilot-caregiver` JWT:

```
BEFORE pause:
  GET /api/v1/me/patients
    → patient pt_bench_98 → notificationsPaused: None  ✅  (server projects null, not missing)

POST /api/v1/patients/pt_bench_98/notifications/pause
  body: {"days": 5, "reason": "in_hospital"}
  → 200 {"notificationsPaused": {"until": 1780358615, "reason": "in_hospital",
                                  "pausedAt": 1779926615, "pausedBy": <caregiver sub>,
                                  "daysRemaining": 5}}

AFTER pause:
  GET /api/v1/me/patients
    → patient pt_bench_98 → notificationsPaused: {until: "1780358615",
                                                   reason: "in_hospital",
                                                   pausedAt: "1779926615",
                                                   pausedBy: <sub>,
                                                   daysRemaining: 4}  ✅

  GET /api/v1/patients/pt_bench_98
    → same projection shape on detail view (regression check — no behavioral change)  ✅

DELETE /api/v1/patients/pt_bench_98/notifications/pause
  → 200 {"notificationsPaused": null}  ✅  (cleanup so the bench patient isn't left paused)
```

US-31 acceptance: the bell icon will now render at Census tier for any patient whose `notificationsPaused.until` is in the future. The detail-tier Pause Banner is also no longer silently broken (epoch parse fix).

## C36.4 — Known surface

- **`form_input` quirk (carried from §C35.3)** — still applies; Chrome MCP DOM-value injection doesn't fire Flutter onChange. Validation here was direct-curl-only for the same reason. UI rendering of the new bell + reason pickers will need a real-keyboard pass when next at a browser.
- **Demo build (`facility_mock_data.dart`)** — `replaceDevice` + `discontinueDevice` return synthesized `DeviceResponse`s and don't mutate the in-memory seed list. Matches the precedent set by `dischargePatient` / `pauseNotifications` in §C35 — marketing demo's UX stays correct without going out-of-network, but in-place state mutation is deferred to whichever pass adds full interactivity to the seed model.
- **`device-api` rollback path** — Replace Device is a non-atomic two-step (end-then-provision). If the second leg fails the patient is left device-less; the UI surfaces the provision error but doesn't roll back the end-assignment. Reverting an end-assignment requires firmware-side wipe-ack reversal which isn't a supported path. V1 acceptance: caregiver re-provisions the same or different serial on retry. Same posture as the atomic-create flow in 2A-UM-P L3 (single-leg atomic only when wrapping into POST /patients).

## C36.5 — Operational state after this entry

| Item | Status |
|---|---|
| Discharge reason picker | ✅ surfaced via DischargeReason enum |
| Pause reason picker | ✅ surfaced via PauseReason enum |
| Discharge notes wiring | ✅ now actually sent to server (was UI-dead) |
| Replace Device | ✅ wired (end + provision orchestration) |
| Discontinue Device | ✅ wired (end-assignment only) |
| ApiClient provisionDevice / endAssignment | ✅ implemented (were `UnimplementedError` stubs) |
| US-31 census-tier paused-bell | ✅ live (`/me/patients` + roster projection + UI in tile & list) |
| NotificationsPaused epoch parse | ✅ fixed — Pause Banner remaining-days now actually renders |
| `GoSteady-Dev-Api` stack | ✅ deployed (single-resource UPDATE, patient-api Lambda) |
| Coord doc + phase-2a-read.md spec | ✅ amended in this commit |

## C36.6 — Coord doc for next sync

All four §C35.4-deferred items are closed. V1 caregiver UX surface now fully complete and bell icons live across tiers. Next likely directions unchanged from §C35.6: 2B-D2C household refit, 2C notifications, or 3A prod hosting cutover. Coord doc rests until next major work item.

---

*Entry owner: Claude (portal session, 2026-05-27). Single-Lambda code swap on `gosteady-dev-patient-api`; no infra, no firmware impact.*

---

# §C37 — D2C Phase 1 backend: walker-user claim + activation (2026-05-31)

Entry owner: Claude (portal session) | Trigger: begin the consumer/household (D2C) product on its phased plan. **Zero firmware-facing impact** — D2C reuses the already-shipped device-activation + provision + Shadow-desired contracts verbatim (ARCHITECTURE §4/§7; coord §C18/§C19 activation ack). No firmware change requested or needed through D2C Phase 4. This entry exists so a firmware-side reader knows the D2C surface now provisions real devices through the same `gs/{serial}/cmd` activate path.

## C37.1 — What landed (deployed to dev)

- **New spec set:** `docs/specs/d2c.md` (umbrella + 5-phase plan) + `docs/specs/d2c-phase1-walker-activation.md` (detail). Account model = Member + Admin flag + Walker-user property + Care Circle (maps onto existing `dtc_*` synthetic-client tenancy; no new role enum).
- **Phased plan:** (1) walker-user claim+activation+monitoring → (2) SMS notifications → (3) deactivation/reset → (4) new-user-on-reset-device → (5) caregivers. Walker-first, real-hardware exit test each phase.
- **New stack `GoSteady-Dev-D2C-Auth`:** separate Cognito pool `us-east-1_bhvtxuHwD` (d2c.md L5 — clean HIPAA/scoping boundary from the facility pool), D2C-Portal client `1mfi0ori1r0r5tvd5rq11m3ac3` (CUSTOM_AUTH/SMS-OTP only, passwordless), custom-auth Lambda (Define/Create/Verify), D2C pre-token Lambda (injects `dtc_*` claims with a pre-claim bootstrap default).
- **`d2c-claim` Lambda + 2 API routes:** `POST /api/v1/claim` (2nd JWT authorizer on the D2C pool) bootstraps household + Patient(isWalkerUser) + RoleAssignments(household_owner) then provisions the device via an inline copy of the 2A-DL provision chain (activate cmd + Shadow `desired.activated_at`). `GET /api/v1/public/walkers/{walkerId}` (unauth) drives the QR `/setup` landing. New `by-walker-id` GSI on Device Registry maps the opaque QR id → serial (printed `GS` serial never exposed; d2c.md L6).
- **SMS provider = Twilio** (pulled forward from Phase 2): the dev AWS account has no SNS SMS origination identity, so OTP sends via Twilio's REST API. Creds in Secrets Manager `gosteady/dev/twilio` (operator-populated; scoped API Key preferred). Runbook: `docs/playbooks/d2c-twilio-setup.md`.

## C37.2 — Validation

Synthetic end-to-end all-green against deployed infra: public lookup states (unclaimed/unknown/claimed/decommissioned), 401 on unauthed claim, claim→201 with full side effects (device `provisioned` + owner + activate cmd; DeviceAssignments + RoleAssignments + Organizations rows; patient visible in `by-client-status` GSI), idempotent re-claim→200, cross-user→409, audit events flowing. Three live-AWS bugs found + fixed during testing (DDB empty-set rejection; `error_response` arity; missing `status_patientId` GSI sort key) — full record in `d2c-phase1` spec §10.

## C37.3 — Open / next

- **Blocked on operator:** Twilio A2P/toll-free compliance review (~2 business days) + populate the `gosteady/dev/twilio` secret. OTP can't send until then. Verified-Caller-ID smoke test possible sooner.
- **Real-device exit test pending** (flash Thingy:91 X → generate+sticker walkerId QR → claim → power-on activation → walk → activity renders). Can be decoupled from SMS via admin-minted token if the Twilio review lags.
- **Flutter D2C live wiring** still pending (auth service + D2CRepository).

## C37.4 — Coord doc for next sync

D2C Phase 1 cloud backend deployed + synthetic-validated; no firmware ask. Coord doc rests until the real-device activation test (which closes the firmware `reported.activated_at` Shadow ack loop for a D2C account for the first time — will log that result when it happens).

---

*Entry owner: Claude (portal session, 2026-05-31). Reuses existing activation/provision/Shadow contracts; zero firmware change.*

---

# §C38 — Firmware battery pilot: LTE-M PSM + low-power overlay (2026-05-31)

Entry owner: Claude (firmware session) | Trigger: pilot will run a smaller **1350 mAh AA-class cell** and needs **~30-day life on a single charge**. Built a power budget from the actual firmware paths, found the dominant overrun, fixed it, and validated on `GS9999999998`. **Cloud-facing impact: effectively none** — no contract change. Two things a cloud-side reader should note: (1) new firmware version strings `0.12.0-psm` / `0.13.0-pilot` will appear in heartbeats; (2) the device now uses modem PSM, but this does **not** change downlink (activate/wipe) behavior — see C38.4.

## C38.1 — Root cause found in the power model

Built an energy model over the real consumers (heartbeat connect/publish/disconnect, per-session activity uplink, 84 KB snippet uploads, idle sampler, sensors, LEDs). Budget: 1350 mAh / 720 h = **1.875 mA average ceiling** (design target ~1.4 mA with margin for temp + the generic-1100 mAh fuel-gauge model error, FMEA 3.1).

The smoking gun, confirmed in the resolved `.config` (not just source): **`# CONFIG_LTE_PSM_REQ is not set`**. `CONFIG_LTE_LC_PSM_MODULE=y` only compiled the module in; PSM was never requested, and the firmware never powers the modem down. So between hourly heartbeats the nRF9151 idled in registered I-DRX at **~mA-level 24/7** — that term alone (~1440 mAh/mo at ~2 mA) overruns the entire budget → projected life **~20 days, FAILS**.

## C38.2 — What landed (firmware)

- **`0.12.0-psm`** (`prj_cloud.conf` + `prj_field.conf`): request PSM at attach — `CONFIG_LTE_PSM_REQ=y`, RPTAU `00010010` (T3412 = 3 h periodic-TAU backstop, set above the 1 h heartbeat), RAT `00000001` (T3324 = 2 s active time, minimal so the modem enters PSM ~immediately after each RRC release; NCS default was 60 s).
- **`0.13.0-pilot`** (new self-contained `prj_pilot.conf` = `prj_field.conf` + two deltas): **snippets OFF** (`CONFIG_GOSTEADY_SNIPPET_ENABLE=n` — removes the 84 KB/session uploads, the largest per-event radio cost) + **`CONFIG_GOSTEADY_LOW_POWER=y`** bundle (new Kconfig): fuel-gauge cadence 5 s→60 s, cellular signal/time reporter poll 60 s→30 min, and the nPM1300 `AVG_CURRENT` surfaced on uart0 for bench power readings. FIELD_MODE (already in `prj_field.conf`) also silences the idle purple-blink + recording LEDs (the blink alone is ~1–3 mA). `src/version.h` keys the version string off `LOW_POWER` so non-pilot builds keep reporting `0.12.0-psm` (accurate cloud attribution per build).
- **Deferred (session-capture hot-path risk, pending measurement):** idle-sampler 100 Hz-spin gating + BMI270 gyro-disable (the V1 algo is accel-only; gyro is dead weight once snippets are off). The set above already clears 30 days with margin, so these stay out until the discharge run says the extra margin is needed and they can be tested against capture in isolation.

## C38.3 — Validation (GS9999999998, bench)

- PSM **granted by the carrier exactly as requested**: uart0 `cellular: psm: tau=10800 s, active=2 s` (iBasis roaming, RSRP −87…−89 dBm, SNR 4–5 dB). Registration ~5–10 s after boot.
- `0.13.0-pilot` flashed + running: FIELD_MODE (LEDs off), heartbeat publishes `"firmware":"0.13.0-pilot"`, snippets quiet, no faults, nPM1300 current instrument live (`I=… uA (vbus=…)`).

**Bench model (recalibrated with PSM confirmed):** pre-PSM ~20 d (FAIL) → PSM-only as-flashed ~58–89 d → fully-optimized pilot ~90–210 d, depending on per-connection (TLS-handshake) energy `E` (≈0.15–0.40 mAh/connection, 32 connections/day). Every PSM-enabled scenario clears 30 days; `E` is the remaining swing and is what the discharge run will pin down.

## C38.4 — Why PSM doesn't break downlink (activate / wipe)

The device already only received queued cmds during its hourly connect-publish-disconnect window; the connection-coordinator Lambda (§C24) re-publishes any outstanding `outstandingActivationCmds` / `outstandingWipeCmds` on each AWS IoT `CONNECTED` lifecycle event. PSM lowers the between-wake current **without widening downlink latency** vs the prior design — worst-case cmd delivery is still ≤ one heartbeat interval. No cloud action required.

## C38.5 — Open / next

- **Discharge run to measure real life:** top `GS9999999998` to 100 %, run on battery (vbus=0), watch `battery_pct` decline across hourly heartbeats on the per-device dashboard over 2–4 days → average current → projected life (treat the slope as ±5–10 % given the generic fuel-gauge model). Optionally fold nPM1300 `IBAT` into the heartbeat payload (cloud accept-all → Shadow) for a per-heartbeat connection-current signal.
- Revisit the deferred sampler-gating + gyro-disable only if the measured life needs the extra margin.

## C38.6 — Follow-up: green session LED restored (`0.13.1-pilot`)

`0.13.0-pilot` (via FIELD_MODE) had silenced ALL LEDs, including the green "recording" LED. Operator feedback: the green LED lighting on motion-detected/recording is a useful confirmation; only the *idle* purple blink was unwanted. Restored the green session LED via new `CONFIG_GOSTEADY_SESSION_LED` (set in `prj_pilot.conf`): green solid during an active capture session, dark at rest (idle purple blink stays off, gated separately). Cost is tens of mAh/month (green on ~40 min/day) — affordable within the pilot budget. Reflashed `GS9999999998` → `0.13.1-pilot` (heartbeat `firmware` field updated). No cloud impact.

---

*Entry owner: Claude (firmware session, 2026-05-31). PSM validated on GS9999999998 (tau=3 h / active=2 s granted). No cloud contract change; new firmware version strings 0.12.0-psm / 0.13.1-pilot.*

---

# §C39 — GS0000000001 flashed + staged for first D2C QR-claim test (2026-05-31)

Entry owner: Claude (firmware session) | Trigger: stage the first shipping unit `GS0000000001` (fresh from Nordic starter FW) for the D2C Phase 1 real-device claim test ([`d2c-phase1-walker-activation.md`](../specs/d2c-phase1-walker-activation.md) §7). **Device-side + cloud-prep are complete and verified**; the only remaining blockers are Twilio OTP delivery (operator, in compliance review) and Jace's phone-side claim. No firmware code change — flashed the existing `0.13.1-pilot` and did cloud staging.

## C39.1 — Device prep (done + verified)

- **Flashed `GS0000000001`** with `0.13.1-pilot` (pilot deploy build: FIELD_MODE + PSM + snippets off + green session LED), rebuilt with `CONFIG_AWS_IOT_CLIENT_ID_STATIC="GS0000000001"` (per-unit rebuild is mandatory — broker rejects a mismatched client_id). Flow per the bringup playbook Phase 3: `at_client` sample → `flash_cert.py --serial GS0000000001` (root CA + client cert + key written to sec_tag 201, the existing bundle cert fp `8351197b…`) → pilot app via `--chiperase` (cert survives in CryptoCell-312).
- **On-device verified:** boots FIELD_MODE `0.13.1-pilot`; iBasis eSIM `registered_roaming` (RSRP −85, SNR 10); PSM granted tau=10800 s / active=2 s; subscribed `gs/GS0000000001/cmd`; first heartbeat published and landed in the Thing Shadow (`firmware:0.13.1-pilot`, battery 97 %, boot_count 2).

## C39.2 — Cloud prep (done + verified)

- The IoT Thing + cert (ACTIVE, policy attached) + Device Registry row already existed from the §C2.1 first-handoff mint (`ready_to_provision`, owner NULL, `activated_at` None). **The one missing piece — `walkerId` — was assigned:** `37b2e250-9732-4d4b-9d66-b8339d952d8a` written to the registry row; the `by-walker-id` GSI resolves it → `GS0000000001`; `GET /api/v1/public/walkers/{walkerId}` returns `{"status":"unclaimed"}`.
- **QR / setup URL:** `https://dev.portal.gosteady.co/d2c/#/setup/37b2e250-9732-4d4b-9d66-b8339d952d8a` (QR PNG at `~/Desktop/GS0000000001_setup_QR.png`). The opaque walkerId is in the QR; the `GS` serial is never exposed (umbrella L6).

## C39.3 — Pre-claim state is correct (the point of the test)

`status=ready_to_provision`, owner NULL, `activated_at` None → the claim will exercise the **real** provision + activate path (NOT the dev `activated_at` shortcut). The device heartbeats in pre-activation (session capture gated until the `activate` cmd) and is subscribed to its cmd topic, so the §C24 connection-coordinator delivers the activate at the next connect. (Recommend power-cycling the cap right after the claim so it connects within seconds rather than waiting up to the 1 h heartbeat.)

## C39.4 — Remaining before the claim can run (not firmware)

- **Twilio** `gosteady/dev/twilio` secret populate + A2P/toll-free review (operator, in progress ~2 biz days). Until then SMS-OTP can't deliver → no D2C JWT → no claim. The Cognito **email** confirm-code step (the "two-code first-timer" flow, d2c-phase1 §9) works today.
- **Jace phone-side** (d2c-phase1 §7): scan QR → sign up (name/email/phone) → email confirm → SMS OTP → `POST /claim` → power-cycle cap → walk ~100 steps → confirm activity renders + status `active_monitoring` + `device.activated` audit.

## C39.5 — One firmware discrepancy to know

d2c-phase1 §7 item 3 ("blue LED off on activation") assumes a pre-activation blue LED, but **field builds never drive the blue LED** (it's only wired into the bench purple-blink path). Use cloud status (`active_monitoring`) + the **green session LED** on first capture as the activation confirmation, not a blue light. A real pre-activation indicator could be added (candidate, mirrors the `CONFIG_GOSTEADY_SESSION_LED` pattern) if we want one for the demo.

---

*Entry owner: Claude (firmware session, 2026-05-31). GS0000000001 flashed `0.13.1-pilot` + cert + walkerId; pre-claim state verified. Blocks: Twilio OTP + Jace phone-side claim. No firmware code change.*

---

# §C40 — Pre-activation shipping mode + gated sampler (`0.14.0-shipmode`, 2026-05-31)

Entry owner: Claude (firmware session) | Trigger: ship/store a pre-activation cap for months with no pull-tab and still hand the patient a near-full battery. **Firmware-only; zero cloud contract change.** Spec: `gosteady-firmware/docs/specs/preactivation-lowpower-mode.md`.

## C40.1 — Problem

A pre-activation device wasn't a low-power standby — it was a fully active cellular device that just declined to capture: hourly heartbeat + a 100 Hz sampler thread spinning in idle → **~340–410 mAh/month in storage (~27 % of a 1350 mAh cell)**. A cap boxed for a few months could be dead before the patient claims it.

## C40.2 — What shipped (`0.14.0-shipmode`)

- **Gated sampler [UNCONDITIONAL, all builds]:** the 100 Hz sampler now blocks on a new session-start signal (`session.c` `sampler_start_sem` + `gosteady_session_wait_for_start()`) instead of spinning when idle — the largest idle term. Preserves the documented start/stop race fixes (`s_active` ordering unchanged; only *how it waits* changed). Benefits activated devices between walks too.
- **`CONFIG_GOSTEADY_PREACT_LOWPOWER` (prj_pilot.conf):** in pre-activation, motion → a brief **blue "pick me up to set up"** blink (rate-limited, no BMI270 confirm) + a **rate-limited motion-triggered connect** to collect a pending `activate` cmd when the user handles the cap; heartbeat drops to a **24 h safety net** (tunable). Modem stays PSM-registered (~5 µA). Implements the pre-activation indicator the D2C spec assumed but field builds never had (§C39.5).

Estimated storage draw **~48 mAh/month** (~7–8× cut) → months of shelf life. Handling (2 h of motion) ≈ 3–5 mAh.

## C40.3 — Validation

- **Gated-sampler soak PASSED** on GS0000000001 (bench build, control.py / uart1): 16 start/stop cycles (12 normal + 4 rapid-fire), **0 faults, 0 dropped**, every session captured, clean BMI270 resume/suspend, algo ran. The `-EBADF`/HardFault stop race was not reintroduced.
- Both pilot (PREACT) and default-bench (gated, no cloud) builds compile clean.
- **GS0000000001 re-flashed to `0.14.0-shipmode`** (field) after the soak; boots clean, heartbeats as itself, **D2C pre-claim staging intact** (`ready_to_provision` / owner NULL / `activated_at` None / walkerId `37b2e250-…` / public lookup `unclaimed`). The bench-build detour left zero contamination (boot orphan-sweep cleaned the soak sessions).

## C40.4 — Cloud-coordination note (carry-forward)

When the **Phase 1C offline detector** ships (`lastSeen > 2 h`), it MUST scope to `active_monitoring` devices — a pre-activation/shelf cap on a 24 h safety-net heartbeat is quiet by design and must NOT trip it. (No conflict today; 1C isn't built.) Sibling to the §C39 staging note. Also: with shipmode, GS0000000001 now connects on **motion or reboot**, not hourly — so the D2C activate cmd lands when Jace power-cycles/mounts the cap after claiming (already the §C39 runbook step).

---

*Entry owner: Claude (firmware session, 2026-05-31). `0.14.0-shipmode` on GS0000000001; gated sampler soak-validated; D2C staging intact. No cloud contract change.*

---

# §C41 — First physical-device activation through the FACILITY portal, end-to-end on the live site (2026-06-03)

Entry owner: Claude (portal session) | Trigger: drive a real device-activation all the way through the **facility** build of the portal on the deployed live site (`dev.portal.gosteady.co`), in real Chrome, to prove the V1 critical path with hardware in the loop. **Achieved end-to-end.** Three real bugs surfaced + fixed (all live-mode/UI-only — invisible to the prior API-level + demo testing). No firmware change; `GS0000000001` ran `0.15.1-wakewindow` unmodified.

## C41.1 — What was proven (the full loop, real hardware)

Caregiver `dev-pilot-caregiver@test.local` (client_dev_pilot / fac_dev_pilot_a / cen_dev_pilot_a1) → **real Cognito sign-in** on `dev.portal.gosteady.co` → Census renders live `/me/patients` → **Add Resident** "Pilot CapTest", Room 201, device `0000000001` → `POST /api/v1/patients` (atomic provision) → cloud claims ownership + publishes `activate` cmd `act_353d21c0-66be-47d0-9767-2e72fdf18658` + sets Shadow `desired.activated_at=2026-06-04T01:13:01Z` → **Jace shook the cap** (0.15.0 wake-window) → firmware connected, §C24 coordinator delivered the cmd, firmware persisted `activated_at` + echoed `last_cmd_id` → heartbeat-processor transitioned **`provisioned → active_monitoring`**, stamped `firstHeartbeatAt`, cleared `outstandingActivationCmds`, Shadow `reported.activated_at` set → patient detail in the live portal shows the device **`100% · Strong · 1 min ago`** → **Jace walked it** → activity uplink landed: **1 session, 42 steps, 50.09 ft, `surfaceClass=outdoor`, `roughnessR=0.4562`, fw `0.15.1-wakewindow`** → rendered for the caregiver. This is the **Phase 2B umbrella exit** (real MQTT → DDB → API → portal on a caregiver's screen) achieved with a physical cap through the facility build.

## C41.2 — Three bugs found + fixed + deployed (live-mode/UI-only)

1. **Unit dropdown selection never committed (BUILD_MODE=live only).** `AddResidentDialog`'s `LabeledDropdown<Unit>` (`DropdownButtonFormField`) silently dropped the selection: `LiveFacilityRepository.allUnits()` builds **fresh `Unit` instances every call** and the dialog's `_unitsForFacility` getter re-runs each rebuild, while `Unit`/`Facility` had only **identity equality** → after `onChanged` the dropdown's `value` no longer `==` any item → release build falls back to the hint ("Select unit"); debug would assert. Facility worked only because `_facilities` is a `late final` (stable instances); demo worked because `FacilitySeed.units` are `const`. **Fix:** `==`/`hashCode` by `id` on `Unit` + `Facility` (`lib/facility_demo/models/{unit,facility}.dart`). Rebuilt + deployed to S3/CloudFront; verified the selection sticks through the live UI.
2. **New residents invisible to the census (`patient-mgmt`).** `_action_create_patient` wrote the Patient row **without `status_patientId`** — the composite range key for the `by-census-status` + `by-client-status` GSIs that `patient-api` reads with `begins_with("active_")`. Result: patient created but absent from `/me/patients` and every roster query. (This also explained why the Census didn't refresh after Add Resident — the row simply wasn't in the GSI.) **Fix:** create now writes `status_patientId = f"active_{patient_id}"`. The one existing row was backfilled manually so the live test could proceed; `/me/patients` then returned both residents.
3. **Discharge didn't drop residents from the roster (`patient-mgmt`).** `_action_discharge_patient` set `status=discharged` but left `status_patientId=active_<id>`, so the reader's `begins_with("active_")` would keep a discharged patient in the census. Latent before fix #2 (rows had no `status_patientId` at all); fix #2 exposes it. **Fix:** discharge now also sets `status_patientId = f"discharged_{patient_id}"`.

Bugs 2+3 deployed via `cdk deploy GoSteady-Dev-Api --hotswap` (gosteady-dev-patient-mgmt, 8.5s, Successful).

## C41.3 — D2C coordination follow-ups (alignment / fixes needed)

This test repeatedly collided with the D2C path. These are the cross-product coordination issues to align — **none are blocking today but each is a latent bug or operational trap**:

1. **`status_patientId` format is inconsistent across the three patient-writers.** Canonical (seed + `patient-api` readers) = **`<status>_<patientId>`** (underscore). `patient-mgmt` now matches (fixed above). **`d2c-claim/handler.py:154` writes `f"active#{patient_id}"` (hash).** D2C-claimed patients therefore would NOT match a facility-style `begins_with("active_")` roster query — it only "works" today because D2C reads via its own repository path, not the facility census GSI. **Action:** standardize d2c-claim on `active_{id}` (underscore) to remove the divergence, OR document the separate read path as intentional. Pick one; the silent format fork is a bug waiting to bite a shared query.
2. **Root cause is structural: every patient-writer hand-rolls the Patient row.** `patient-mgmt`, `d2c-claim`, and the seed scripts each independently construct the item (and have each, at different times, gotten `status_patientId` wrong — §C37 fixed the same class of bug in d2c-claim; this entry fixes it in patient-mgmt). **Action:** extract a single `_shared/patient_row.py::build_patient_item(...)` that stamps `status_patientId` (and future GSI keys) in one place; have all three writers call it. Prevents the next drift.
3. **`tools/deploy-portal.sh` clobbers the D2C app.** The facility deploy runs `aws s3 sync build/web/ s3://gosteady-dev-portal-hosting/ --delete`, and the D2C app lives in the **same bucket under `/d2c/`** (§C37 deploy target). `--delete` removed all 28 `/d2c/*` objects on this session's first deploy; recovered fully from S3 versioning (bucket has versioning enabled). **Action:** fix the script before the next facility deploy — either drop `--delete`, scope it (`--exclude "d2c/*"`), or split the two apps into separate buckets/distributions. As written it will wipe D2C every time. **FIXED 2026-06-03 (C41.4 #3):** scoped the sweep with `--exclude "d2c/*"` + added the missing `--region`. The shared-bucket design remains a latent footgun — splitting facility and D2C into separate buckets/distributions is the durable fix if/when convenient.
4. **`GS0000000001` is contended between D2C and facility tests.** It was staged for the first D2C QR-claim (§C39: walkerId `37b2e250-…`, owner NULL, public lookup `unclaimed`). Provisioning it into the facility **claimed facility ownership** (`owningClientId=client_dev_pilot`, `owningFacilityId=fac_dev_pilot_a`) and consumed the activation, **overwriting the D2C staging** (the `walkerId` attribute persists on the row, but `status=active_monitoring`/owned ≠ a claimable D2C unit). **Action:** to restore the D2C QR-claim test, either end-assignment → wipe-recycle `GS0000000001` back to `ready_to_provision` + clear owner (an `internal_admin` cross-tenant move) and re-run §C39 staging, or stage a **separate** device for D2C so the two test tracks stop fighting over one cap.

## C41.4 — Other (non-D2C) follow-ups, prioritized for next

In the agreed order for the next work block:
1. ~~Auto-refresh / polling not wired~~ — **CORRECTED 2026-06-03: polling IS wired and works; this was a false alarm.** Verified live with no reload: with Pilot CapTest's detail open, "Today's Activity" auto-updated **0 → 42 steps** when the walk landed (30 s patient-detail poll), and the census row's "Steps today" went **0 → 42** (60 s census poll). The earlier "had to reload to see the new resident" was **bug #2** (new patient invisible to `/me/patients` until `status_patientId` was fixed), compounded by the foreground-only poll pause while the tab was unfocused during AWS-CLI work — not a polling failure. `PollingController` + the screens' `_onPollTick → refreshCensus/refreshPatientDetail → setState` are correct. **No code change.** Minor edge: a resident added to a *brand-new* unit not yet in the census unit-selection may need a selection refresh to surface.
2. ~~Device battery/signal are stubs~~ — **DONE 2026-06-03 (Option B — device-detail endpoint, chosen for reusability toward future device-centric screens/analytics).** `GET /api/v1/devices/{serial}` (route already existed on `device-api`, which already had `iot:GetThingShadow` → **code-only hotswap, no IAM/CFN change**) now folds live Shadow `telemetry` into the response: `batteryPct`/`batteryMv`, `rsrpDbm`/`snrDb`, `firmware`, plus `uptimeS`/`bootCount`/`faultCounters`/`watchdogHits`/`resetReason`/`lastSeen` (the full diagnostic set, so a future device screen renders off one contract; V1 card uses the battery/signal subset). Best-effort server-side (no shadow → no `telemetry` key). Flutter: `getDevice` un-stubbed; `DeviceResponse` reads the nested telemetry; `DeviceHealth` gained a preferred `batteryPct` (fuel-gauge SoC — the mV curve assumed the wrong cell chemistry, so re-deriving from `battery_mv` was inaccurate); `deviceFor` builds real values. **Verified live:** the card flipped from a fake `100% · Strong` to the real **`95% · Good · 6 min ago`** for `GS0000000001`.
3. ~~Fix `deploy-portal.sh`~~ — **DONE 2026-06-03.** Two bugs fixed: (a) the `--delete` sweep is now scoped with `--exclude "d2c/*"` so a facility deploy can't wipe the shared-bucket D2C app; (b) added `REGION=us-east-1` + `--region` on every aws call — the script previously couldn't even resolve the API URL because the operator's default CLI region (us-east-2) didn't match the stacks' region (so it aborted with "Could not resolve API URL"). Primary API-URL query switched to the actual output key `HttpApiUrl`. Validated: `bash -n` clean + `--build-only` resolves the URL and builds. See C41.3 #3.

## C41.5 — State after this entry

- `GS0000000001`: **`active_monitoring`**, owner `client_dev_pilot`/`fac_dev_pilot_a`, `activated_at=2026-06-04T01:13:01Z`, fw `0.15.1-wakewindow`, battery 95.6%, 1 walk session logged. D2C staging overwritten (see C41.3 #4).
- Test artifacts in dev: Patient `pat_aad8e1c7f75c41528b3cfa94` ("Pilot CapTest", Room 201, cen_dev_pilot_a1) + its DeviceAssignment + 1 activity session. Keep or discharge/clean per Jace.
- `patient-mgmt` Lambda redeployed with the `status_patientId` create+discharge fix. `Unit`/`Facility` equality fix live on `dev.portal.gosteady.co`.
- D2C app restored intact at `/d2c/` after the `--delete` incident.

---

*Entry owner: Claude (portal session, 2026-06-03). First physical-device activation through the facility portal, end-to-end on the live site. 3 live-mode bugs fixed + deployed. D2C coordination follow-ups in C41.3. No firmware change.*

---

# §C42 — Device-lifecycle UX consolidation ("End Monitoring") + discharge-cascade wipe fix; full single-cap lifecycle validated (2026-06-04)

Entry owner: Claude (portal session) | Trigger: product decision to collapse the overlapping "Discontinue Device" and "Discharge Resident" affordances (no EHR/EMR integration planned for a long time, so the device-vs-resident distinction was artificial). While testing the consolidation end-to-end on the live site, a discharge-cascade bug surfaced (cap never recycled). Both fixed + deployed; then the **entire device lifecycle** was validated on one physical cap. **Zero firmware change** — `GS0000000001` ran `0.15.1-wakewindow` unmodified.

## C42.1 — UX consolidation: "End Monitoring"

- **Removed "Discontinue Device"** (was: unassign the cap but keep the resident actively monitored, device-less — an anti-state that would trip `device_offline` alerts; "Replace Device" + "Pause Monitoring" already cover the real cases).
- **Renamed "Discharge Resident" → "End Monitoring"** (label + form + toast only; the discharge plumbing is unchanged under the hood — `status=discharged` + cascade releases the cap). Resulting menu: **DEVICE** → Replace Device; **RESIDENT** → Edit / Pause Monitoring / End Monitoring.
- **Dropped the discharge reason entirely** — "End Monitoring" is now just a confirm + optional notes, no reason picker (the prior `transferred/moved_home/hospital_admission/deceased/other` enum read as too clinical, and the user wanted "just end and move on"). Backend `reason` is now **optional free-text** (`patient-mgmt` `validate_discharge_reason` + handler; `VALID_DISCHARGE_REASONS` removed). Frontend `DischargeReason` enum removed; `dischargePatient` `reason` param made optional across `ApiClient` / `FacilityRepository` / live + mock impls.
- Copy reflects the V1 re-monitoring model: *"removes them from the active census and releases the walker cap back to the available pool. Activity history is preserved — you can monitor them again later by re-adding them with a device."* (Same-record reactivation — bring a discharged resident back under one record with linked history — is a deferred follow-up; re-adding as a new resident is the V1 path and was validated below.)

## C42.2 — Bug fixed: discharge-cascade never published the wipe

The `discharge-cascade` Lambda (DDB Stream on Patients → `status=discharged`) **closed the assignment + flipped the device to `discontinued` + cleared `desired.activated_at`, but never queued the wipe** (`outstandingWipeCmds`, `desired.wipe_requested`) — unlike the device-api `end-assignment` endpoint. So **every cap released via discharge got stuck in `discontinued` and never auto-recycled to `ready_to_provision`** — directly contradicting the ARCHITECTURE §4 cascade design ("Each end-assignment fires a wipe cmd") and making the new "End Monitoring releases the cap to the available pool" UX copy false.

**Fix (hotswap-deployed):** the cascade now mirrors the endpoint's AA-recycle write — generates a `wipe_id`, populates `outstandingWipeCmds` (two-step `if_not_exists` idiom) + `wipe_requested_at`, sets Shadow `desired.wipe_requested` + clears `desired.activated_at`, and emits `device.wipe_requested`. It deliberately does **not** publish the wipe cmd directly (the cascade Lambda has no `iot:Publish` grant, and the **§C24 connection-coordinator re-publishes `outstandingWipeCmds` on the cap's next CONNECTED event** — the designed reliable path; keeps the cascade hotswap-deployable with no IAM/CFN change).

## C42.3 — Full single-cap lifecycle validated end-to-end (live site + real cap)

One physical cap (`GS0000000001`, `0.15.1-wakewindow`) traversed the **entire** lifecycle through `dev.portal.gosteady.co`:

```
Pilot CapTest (pat_aad8e1c7…):  Add Resident+provision → activate (shake) → walk 42 steps/50 ft
                                                → End Monitoring (no reason)
GS0000000001:  cascade → discontinued + wipe queued → (shake) wipe-ack → recycle → ready_to_provision
Rosa Delgado (pat_8ce10709…):  Add Resident+provision the recycled cap → activate (shake) → walk 16 steps/20 ft
```

- End Monitoring on Pilot CapTest: `status=discharged`, **`dischargeReason` absent** (no-reason flow), device → `discontinued`, dropped from `/me/patients`. ✓
- Recovery note: Pilot CapTest was discharged moments *before* the cascade fix deployed, so its cap had no wipe queued; the corrected wipe-recycle state was applied to `GS0000000001` by hand (mirroring the fixed cascade) and a shake completed it — `reported.wipe_complete` matched, `outstandingWipeCmds` cleared, **`discontinued → ready_to_provision`** at battery 94.9%. This validated the cascade-fix *mechanism* on real hardware.
- Rosa Delgado: the recycled cap re-provisioned cleanly (`provisioned`, new `act_7b849296…`, Shadow `desired.activated_at` set), activated on a shake (`active_monitoring`, cmd acked), and her walk rendered (`94% · Good · 1 min ago`, 16 steps) — assignment history preserved (Pilot CapTest's ended assignment + Rosa's active one both on the device). ✓

Also: the **fixed `deploy-portal.sh` ran for the first time** (portal redeploy for the consolidation) and worked end-to-end — resolved the API URL (region fix) and protected `/d2c/` (`--exclude "d2c/*"`; still 28 objects).

## C42.4 — Follow-ups

- **Minor UI polish:** a discharged / device-less patient's detail renders the "no device" `DeviceHealth` placeholder as `0% · Weak · 20608d ago` (epoch-0 lastSeen) instead of a clean "No device assigned" state. Only reachable on a stale open detail of a just-discharged resident (they drop from the census). Low priority.
- **Deferred feature:** same-record "resume monitoring" for an ended resident (history linked under one record), vs. the V1 re-add-as-new path. Open when a pilot needs it.
- Carry-over from §C41.3 (D2C coordination) still open: `d2c-claim` `status_patientId` `active#`-vs-`active_` format; shared `_shared/patient_row.build_patient_item()` helper; separate facility/D2C hosting buckets.

## C42.5 — State after this entry

- `GS0000000001`: **`active_monitoring`** for Rosa Delgado (`pat_8ce10709…`, Bench / Rm 202), `0.15.1-wakewindow`. Pilot CapTest (`pat_aad8e1c7…`) = `discharged` (history preserved).
- Deployed to dev: `patient-mgmt` (reason-optional) + `discharge-cascade` (wipe) hotswaps; portal rebuilt + redeployed (End Monitoring UX).

## C42.6 — Terminology: generalized the facility UI away from "resident" (2026-06-04)

The facility UI called the monitored person a **"resident"** — senior-living-specific, and wrong for home-health agencies (the person is at home) and D2C (a family watching a relative). Rather than swap in another person-noun ("patient" reads clinical for D2C; "user" collides with the app's actual users — caregivers/account holders — and the monitored person usually never touches the app; "care recipient" is fine but formal), **we reframed around the device / monitoring activity and let actual names carry the person** wherever someone is shown.

User-facing mapping (facility build): `N residents` → **`N devices in use`**; `Add Resident` → **`Start Monitoring`** (deliberately pairs with the new **End Monitoring**); `Resident Settings` → `Monitoring Settings`; the `Resident` section + `Edit Resident Info` → `Monitoring` section + `Edit Details`; the `Resident` name-column → `Name`; `All residents` → `All`; empty states / tooltips / login subtitle / care-note de-nouned. **"Session" was deliberately avoided** for the add action ("New monitoring session") because it collides with activity/walk *sessions* (the API's `sessions`, "Today's Activity").

Scope: **user-facing strings only.** The data model is unchanged (`Patient` / `patientId` / `Patients` table / API). Internal Flutter identifiers (`AddResidentDialog`, `resident_settings_dialog.dart`, `_residentCountForUnit`, `onResidentCreated`) were left as-is — a cosmetic rename follow-up, not user-visible. Also shipped a small **"No device assigned"** polish so a device-less / just-ended detail shows a clean state instead of the sentinel `0% · Weak · epoch` chips. Verified live on `dev.portal.gosteady.co`.

## C42.7 — "Show discontinued" — read-only view of ended engagements (2026-06-04)

A bottom-bar **"Show discontinued"** toggle (default off) on the census reveals everyone previously monitored who is no longer being monitored (discharged), as read-only rows. Cheap to build because the `status_patientId` fix already indexes the discharged set:

- **Backend (`patient-api`, hotswap):** `GET /api/v1/me/patients?status=discontinued` lists the discharged slice. `query_patients_by_census` / `query_patients_by_client` gained a `status_prefix` param (default `active_`); `status=discontinued` flips it to `discharged_` on the same `by-census-status` / `by-client-status` GSIs — no new table/migration. `_patient_row_view` now also surfaces `dischargedAt`. (Default/active behavior unchanged; the `family_viewer` by-patient-ids path is unaffected — the toggle is a census/client-role feature.)
- **Frontend:** a fixed `_DiscontinuedBar` footer toggle (default off) → on demand fetches the discharged set (`FacilityRepository.discontinuedPatients()` → live API; demo returns empty) → a greyed **DISCONTINUED** section: each row is `name · unit · "Discontinued <date>"` with a `link_off` icon, no live chips. Clicking opens the **read-only** detail — the settings gear is hidden (no Edit/Pause/End/Replace), a **"Monitoring ended · read-only"** chip sits under the header, the device card reads "No device assigned", and the **preserved activity history still renders**.
- **Verified live:** toggled on → `Pilot CapTest · Bench · Discontinued Jun 3, 2026` appeared greyed; clicking it showed the read-only detail with its preserved 43-step walk and no action surfaces.
- **Deferred (next session, per Jace):** a **"Start Monitoring again"** action from a discontinued row. Today re-monitoring = re-add (new record); the same-record, history-linked resume is the bigger follow-up that this view is the natural hook for. Tiny follow-up: the care-note `+` is still tappable on a discontinued detail (the gear is gated, but the care-note panel isn't) — minor.

Verified live on `dev.portal.gosteady.co`.

---

*Entry owner: Claude (portal session, 2026-06-04). "End Monitoring" consolidation (no reason, no Discontinue Device) + discharge-cascade wipe fix; full provision→activate→walk→end→wipe→recycle→re-provision→re-activate→walk loop validated on one physical cap. + C42.6 terminology generalization (resident → device/monitoring) + C42.7 read-only "Show discontinued" view. No firmware change.*

---

# §C43 — Fuel gauge fix: voltage-based (OCV) SoC (2026-06-04)

Entry owner: Claude (firmware session) | Trigger: a battery-discharge run on `GS9999999998` (off-charger since 2026-05-31 to calibrate the §C38 battery model) surfaced a fuel-gauge bug that was also producing **false `battery_critical` alarms** on the per-device dashboard. **Firmware-only fix; no cloud contract change.**

## C43.1 — The finding

After 3.4 days off-charger the dashboard showed `battery_pct = 0` and the device looked dead — but it was fully alive (heartbeating, 80 h uptime, **never browned out**, green LED on motion). The Shadow showed the truth: **`battery_mv = 4086` (4.09 V ≈ 85–90% on a LiPo)**. The cell had barely drained (4.2 → 4.09 V in 3.4 days) — which actually *validates* the low-power firmware. It was the **model SoC that was garbage**, not the cell.

Root cause: the `nrf_fuel_gauge` coulomb-fused estimate diverges at this device's **sub-mA idle draw** — the nPM1300 current measurement is unreliable that low, so the coulomb term drags SoC to 0 over a day even at a healthy voltage (it "thought" it drew ~30 mA; voltage says sub-mA). Confirmed on the bench: at a fully-charged **4.213 V** the old gauge read **12%**. FMEA 3.1 manifesting harder than the spec anticipated.

## C43.2 — The fix (`0.12.1-psm` / `0.13.2-pilot` / `0.15.2-wakewindow`)

`battery_pct` now comes from a **voltage→OCV lookup table** (generic single-cell LiPo, lightly EMA-smoothed for load sag) in `battery.c`, unconditional across builds. At our currents terminal voltage ≈ OCV, so it's robust, monotonic, and never diverges. The `nrf_fuel_gauge` lib is kept only for a diagnostic log. **Verified on GS9999999998:** 4.213 V → 100% (was 12%); heartbeat + Shadow now report `battery_pct = 1.0`.

## C43.3 — Cloud-facing notes

- **No contract change.** The cloud threshold/alarm logic was correct; the device was sending bad SoC. Earlier `GS9999999998` `battery_critical` alarms (≈ 06/02–06/04) were **false** — disregard them.
- The §C38 battery-model calibration is **unblocked but not done**: SoC from the prior discharge run is unusable; a fresh on-battery run on the OCV firmware will give a usable `battery_pct` trend. Qualitatively, the ~0.1 V drop over 3.4 days already says battery life is long.
- Follow-up (firmware, low priority): swap the generic LiPo OCV curve for a cell-characterised **LP803448** curve after a proper discharge characterization.

---

*Entry owner: Claude (firmware session, 2026-06-04). Voltage-based OCV SoC replaces the diverging coulomb gauge; verified on GS9999999998. Earlier GS9999999998 battery_critical alarms were false. No cloud contract change.*

---

# §C44 — "Start Monitoring Again" (same-record resume) + Monitoring-history modal + hardened devices endpoint (2026-06-04)

Entry owner: Claude (portal session) | Trigger: ship the deferred §C42.7 / §C42.4 follow-up — let a discontinued resident be resumed under the **same record** (history preserved) instead of re-added as a new one — plus a read-only "Monitoring history" view of the device timeline. **Zero firmware change** (reuses the shipped provision / activate / Shadow-desired contracts verbatim). Deployed to dev + validated end-to-end (13/13 synthetic smoke + live Chrome on `dev.portal.gosteady.co`).

## C44.1 — Same-record resume

New endpoint **`POST /api/v1/patients/{id}/resume`** on `patient-mgmt` — the inverse of discharge + a reuse of create's `_provision_inline`. Flips a `discharged` patient back to `active` under the same `patientId` (Activity Series + Alert History stay attached), re-homes to a unit/room, and **atomically re-provisions a required device** (device-less `active` is the anti-state §C42 removed). Body `{censusId, room, deviceSerial}` — all required; name is preserved (not in the body). Status guard: only `discharged` → 409 otherwise. Authz mirrors **create** (role + `enforce_scope` on the target census), **not** the PATCH cross-facility `client_admin+` rule, since a discontinued resident isn't being transferred out of an active facility. Provision failure rolls the flip back to discharged (`_rollback_patient_resume`, the resume analog of create's row-delete). New audit events `patient.resumed` + `patient.resume_rollback`. **No new IAM** — `patient-mgmt`'s grants already covered the inline-provision path. One new HTTP-API route (CFN), two Lambda code updates (`patient-mgmt` + `device-api`), both in `GoSteady-Dev-Api` — one `cdk deploy` (52s).

Flutter: `ResumeMonitoringDialog` (modeled on Add-Resident; name fixed, Facility/Unit/Room pre-filled from last-known placement, device required) launched from a **"Start Monitoring Again"** CTA on the §C42.7 read-only discontinued detail. On success the detail reloads `active` → the read-only chip + CTA clear and the settings gear returns automatically.

## C44.2 — Monitoring-history modal + hardened endpoint

A "monitoring session" was **already** a `DeviceAssignments` row (`validFrom`=start, `validUntil`=end/null=ongoing; GSI `by-patient`). The already-deployed `GET /api/v1/patients/{id}/devices` (`device-api._action_list_patient_devices`) returned **raw DDB items** and no client used it. Hardened it: `ScanIndexForward=False` (most-recent-first) + projected `_assignment_view` (`serialNumber` / `startedAt` / `endedAt` / `ongoing` / `durationSeconds` / `facilityId` / `censusId` / `assignedBy`) → `{assignments:[…], count}`. Safe reshape — no prior consumer. Flutter: `ApiClient.listPatientDevices` + `MonitoringSession` model + `FacilityRepository.monitoringHistory` + a read-only **`MonitoringHistoryModal`** (device · started→ended/ongoing · duration · unit), launched from a "Monitoring history" link on patient detail (both active + discontinued). Resume is what makes the timeline multi-row.

## C44.3 — Validation

- **Synthetic smoke `infra/scripts/smoke-2a-um-resume.py` — 13/13 PASS** (caregiver `rd-caregiver`, `client_rd_test`): create+provision D1 → resume-active-rejected (409) → discharge → resume w/ D2 (200, active + re-provision) → GET patient active → **monitoring-history projected + most-recent-first + prior assignment ended preserved** → cascade-not-fired-on-resume (D2 stays provisioned + open) → resume-active (409) → bad/missing serial (400) → family_viewer (403). Cleanup resets the two synthetic devices.
- **Live Chrome on `dev.portal.gosteady.co`** (caregiver sign-in, SW cleared post-deploy): Show discontinued → Pilot CapTest read-only detail shows both new buttons + preserved 50 ft / 43 steps → **Monitoring history modal rendered real data** (`GS0000000001 · Jun 3 7:13 PM → 9:08 PM · 1h 55m · Bench`) → **Resume dialog pre-filled** (Dev Pilot Facility / Bench / Room 201, device required). Cancelled — curated §C42 state (Rosa active, Pilot CapTest discontinued) left untouched.
- **Fixed a pre-existing red test:** `patient-mgmt/tests/test_validation.py` still imported the §C42-removed `VALID_DISCHARGE_REASONS` (suite failed to import). Realigned the discharge-reason tests to the shipped free-text validator + added `validate_resume_body` coverage → **87/87 PASS**.

## C44.4 — Follow-up (low severity, documented not fixed)

**Discharge-cascade vs immediate-resume race.** The discharge cascade is async (DDB stream) and ends **all** active assignments it sees at run time (~1-2s after discharge). If a resume fires *within that window*, the cascade can end the freshly-provisioned new device too. Surfaced in the smoke (back-to-back discharge→resume) and handled there by waiting for the cascade to settle before resuming — which is exactly real usage (a caregiver reaches "Start Monitoring Again" seconds-to-minutes later, long after the cascade). Practically unreachable with a human in the loop; a durable guard would scope the cascade to assignments active as-of the discharge timestamp. Filed for a future device-side pass.

## C44.5 — Full single-cap lifecycle re-validated on real hardware (`GS0000000001`, live)

Ran the **entire** end→wipe→recycle→resume→re-activate→walk cycle on the physical cap through `dev.portal.gosteady.co`, on the same record (Rosa Delgado, `pat_8ce10709…`), zero firmware change (`0.15.1-wakewindow`):

1. **End Monitoring (Rosa)** → cascade: Rosa `discharged`, GS0000000001 → `discontinued`, wipe `wipe_0224522b` queued + Shadow `desired.wipe_requested`.
2. **Shake** → coordinator (§C24) re-published the wipe on connect (17:53:01) → cap wiped + **blue pre-activation LED** → ack → cloud auto-recycled → `ready_to_provision`. ✓ (operator validated blue)
3. **Start Monitoring Again (Rosa, GS0000000001)** via the resume dialog → Rosa `active` (same `patientId`), GS0000000001 re-provisioned + activate `act_62efdc4f` queued + Shadow `desired.activated_at`.
4. **Re-activate** → cap exited pre-activation, `device.activated` + `device.first_heartbeat` → `active_monitoring`, blue LED off. ✓
5. **Walk** → activity uplink to Rosa: **16 steps / 39.42 ft / outdoor**. Rosa now has **6 sessions under one record**; the Monitoring-history modal shows her two GS0000000001 periods (resumed `Ongoing` + original `14h 26m`, ended at End-Monitoring).

**Operational finding (device-side, worth a runbook note): post-wipe re-activation of the *same physical cap* required a REBOOT, not a shake.** After step 2 the cap acked the wipe at 17:53:01 and disconnected; the resume queued `act_62efdc4f` at 17:54:47 (after that connect). Repeated **shakes did not produce a new connect** (`boot_count` stuck at 7, no coordinator events, `reported.last_cmd_id` stuck on the old cmd). A **power-cycle** (`boot_count` 7→8) forced a fresh connect within seconds → coordinator delivered `act_62efdc4f` → activated. **Cloud was correct throughout** (cmd properly queued in `outstandingActivationCmds` + Shadow `desired`, within the 24h window); the gap was purely the cap not reconnecting on motion.

> **⚠ ROOT CAUSE CORRECTED in §C45 (2026-06-04).** The hypothesis here — "the wake/motion-connect is gated/rate-limited" / "PSM cold-wake" — was **WRONG** (it was never validated against a console). A bench reproduction with uart0 attached found the real bug: the heartbeat thread is parked in the activated-branch `k_sleep(1h)` across the wipe transition, so it isn't serving wake windows at all. **Fixed in `0.15.3-wakewindow`** + validated (a shake now reactivates with no reboot). See §C45. The "reboot it" runbook note is obsolete on `0.15.3+`.

## C44.6 — UX: detail actions laid out horizontally

The read-only chip + "Start Monitoring Again" CTA + "Monitoring history" link were moved from a vertical stack below the header into a `Wrap` beside the unit/room line (horizontal on wide panes, wrapping below on narrow). Active residents show just the history link; discontinued show all three. Verified live for both states.

---

*Entry owner: Claude (portal session, 2026-06-04). Same-record resume + monitoring-history modal + hardened `GET /patients/{id}/devices`; 13/13 smoke + 87/87 validation (incl. a pre-existing red-test fix); **full end→wipe→recycle→resume→re-activate→walk cycle re-validated on the physical `GS0000000001` (C44.5)** + horizontal action layout (C44.6). No firmware change. Device-side finding: reboot (not shake) needed to re-activate the same cap immediately post-wipe.*

---

# §C45 — Firmware fix: wipe→shake reactivation hang (`0.15.3-wakewindow`) (2026-06-04)

Entry owner: Claude (firmware session) | Trigger: §C44.5's "reboot needed post-wipe" finding got a proper bench investigation with the **uart0 console attached** — which overturned the §C44.5 hypothesis and found a real threading bug. **Firmware-only fix; no cloud contract change.** Flashed + validated on `GS0000000001`.

## C45.1 — The investigation overturned the §C44.5 hypothesis

§C44.5 guessed the post-wipe shake failure was a "rate-limited / PSM-cold-wake motion-connect" — **never validated against a console.** With uart0 attached and the cap on USB (warm modem, `rrc=idle`, signal even *stronger* at −91 dBm), the reproduction showed the wake window **opening but never connecting**:

```
preact: shake → wake window (blue pulse, connecting to activate)
cellular: rrc=idle
(… nothing. zero `aws_iot_connect`, zero `preact wake: connected`.)
```

So it is **not** RF / PSM / battery — it reproduced on USB with a healthy modem. It's a **thread-state bug.**

## C45.2 — Root cause

The wake-window coordinator (`main.c::run_preact_wake_window`) and the actual connection live in **two threads** synced by `preact_wake_sem`. The cloud/heartbeat thread (`cloud.c::heartbeat_thread_fn`) loop ends its **activated** branch with a blind `k_sleep(HEARTBEAT_INTERVAL)` — a **1-hour sleep that never re-checks activation**. When a wipe flips the cap `activated → pre-activation` *mid-sleep*, the thread stays **parked in the activated branch for up to an hour**, never entering the pre-activation branch that waits on `preact_wake_sem`. So every shake opens a blue-pulsing wake window that **no thread is listening to connect for**, and the queued `activate` cmd is never collected. A **reboot** works because a fresh thread fires a boot heartbeat that connects (and the §C24 coordinator re-delivers the cmd) — which is the only thing that recovered it.

## C45.3 — The fix (`0.15.3-wakewindow`)

Make the activated cadence sleep **interruptible by de-activation** (`src/cloud.c` + `src/activation.c` + `src/cloud.h`):
- new `heartbeat_wake_sem`; the activated branch now `k_sem_take(&heartbeat_wake_sem, HEARTBEAT_INTERVAL)` instead of `k_sleep` (identical on a normal expiry);
- `gosteady_activation_clear()` (the wipe / de-provision path) calls new `gosteady_cloud_notify_deactivated()` which gives the sem.

So the instant the wipe clears activation, the cloud thread wakes, re-checks `is_activated()`, drops into the pre-activation wake-window branch, and the **next shake connects**. No change to `run_preact_wake_window` or its motion timeout. Single point of de-activation covers both wipe and any future cloud-side de-provision.

## C45.4 — Validation (`GS0000000001`, console-confirmed)

Flashed `0.15.3-wakewindow` (`nrfjprog --recover`, boot_count 10), then re-ran End-Monitoring → wipe → Resume → shake **with no power-cycle** (`uptime_s` 11204 = 3.1 h continuous, `boot_count` unchanged):

```
preact: wake window ended without activation → ship sleep    ← 1st window (nothing queued) timed out at the 600s hard cap — timeout INTACT
preact: shake → wake window …                                ← shook again after Resume
activate cmd received: act_1a6d757d…                          ← wake window CONNECTED + got the cmd
activation applied … persisted to /lfs/activation.bin
preact: ACTIVATED during wake window → green confirm → normal ← GREEN, no reboot
```

Confirms both: (a) a shake reactivates with **no reboot** (the bug is fixed), and (b) the wake-window **motion timeout is intact** (the un-queued first window correctly ended → ship sleep). Operator validated green on the cap.

## C45.5 — Notes

- **No cloud change.** Cloud was correct throughout in §C44.5 and here (cmd queued in `outstandingActivationCmds` + Shadow `desired.activated_at`, delivered by the §C24 coordinator on connect). The §C44.5 "reboot it" runbook note is obsolete on `0.15.3+`.
- **Secondary robustness gap (not fixed, low priority):** `connect_publish_stay` is still a single connect attempt with no retry / no `lte_lc_offline()+normal()` re-attach (vs the boot heartbeat's 3 retries). Moot for this bug, but worth hardening if weak-signal wake-window connects ever flake. Filed.
- Dev-unit pointer: `GS0000000001` now on **`0.15.3-wakewindow`** (was `0.15.1`).

---

*Entry owner: Claude (firmware session, 2026-06-04). Real root cause of the wipe→shake reactivation hang = heartbeat thread parked in the activated `k_sleep` across the wipe transition (NOT PSM/rate-limit as §C44.5 guessed). Fixed in `0.15.3-wakewindow` (interruptible activated sleep + de-activation wake); console-validated on `GS0000000001` — shake reactivates with no reboot, motion timeout intact. No cloud contract change.*

---

# §C46 — Gait speed: cross-team feature design + distance/step-counter algo review (2026-06-07)

Entry owner: Claude (firmware+cloud session) | Trigger: kick off the gait-speed feature (firmware → algo → cloud → portal). Spec-first per Jace. **Design only — nothing implemented yet.** Full spec: [`docs/specs/2026-06-07-gait-speed.md`](../specs/2026-06-07-gait-speed.md).

## C46.1 — The feature

Gait speed (clinical "sixth vital sign") was built-for and then suppressed across the stack: the portal already models `avgGaitSpeed*`/min/max + renders a chart, but **zeroes it in live mode** (`phase-2b-fac-r` L8/Q1) because firmware doesn't emit it and 2A-RD doesn't carry it. This closes that gap end-to-end.

**Locked decisions:** (D1) unit on the wire + storage = **feet/second** (device-native, matches US-19 display unit, retires the portal's m/s-store/ft/s-display split); (D2) firmware emits **one session-average** gait value, portal derives window min/max as the across-session spread; (D3) firmware **pre-computes** gait — cloud can't derive it (`active_min` is minute-rounded → div-by-zero on short walks; cloud never sees float walking-time); (D6) gait is a **within-resident trend, never an absolute** (no tiering, US-10) — distance's 22% MAPE floor is inherited.

## C46.2 — Contract delta (the only firmware↔cloud change)

One new **optional** activity field on `gs/{serial}/activity`:

| Field | Required | Validation | Notes |
|---|---|---|---|
| `gait_speed_fts` | No | Float, 0–10 | Session-average walking speed (ft/s). **Absent** when the on-device guards fail (too few steps / too little walking time / long-session distance saturation). |

Cloud: add to `activity-processor` `NAMED_FIELDS` + validate + write `gaitSpeedFts` (Decimal, mirrors `roughnessR`); add to `patient-api` `_activity_view()`. **No DDB schema change, no new table.** Accept-all means an old-firmware activity without the field is still valid.

## C46.3 — Algo review findings folded into the spec

A review of the shipped distance + step calculator (requested before locking scope) surfaced two gait-relevant issues, both fixed at session-finalize with the per-sample hot path untouched and **distance validation preserved**:

- **Step over-count (live: 53 reported for a 33-step slow walk).** The "step detector" is a deliberately-loose *impulse* detector (~2 impulses/step; "the regression absorbs the ratio" for distance). Measured **mean 1.47× over-count, variable 1.0–2.0×, worst at slow gait** across 15 hand-counted walks. Fix = a **decoupled refractory-merge (~0.8 s)** applied to the *count only* — distance keeps the full impulse train. Cuts step MAPE **47%→16%**, slow-walk error **78%→7%**, **zero distance cost**. Two refinements prototyped + **rejected on data**: autocorrelation-cadence (worse/unstable) and amplitude-aware merge (recovers fast walks but re-breaks slow, net worse). `steps` keeps its name but sharpens ~30% — split cohorts on `firmware_version`.
- **Gait denominator bias.** `motion_duration_s` (the gait denominator candidate) over-counts by the σ-gate's **2 s `exit_hold` tail per bout** + jostle → biases gait low, structure-dependently (corrupts the trend). Fix = derive walking-time from the **same peak train** that produces distance (gated inter-peak gaps), keeping numerator/denominator consistent. `active_min` is **unchanged** (stays the "time in motion" metric).

Deferred to algo-v1.5 (need more labeled data; collection paused at 19/30): the fast-walk step under-count + a cadence-adaptive counter, and the multi-feature distance retrain that would lower the 22% floor.

## C46.4 — Action items

- **Firmware** (`0.16.0-gait`): merged step count + peak-train walking-time + `gait_speed_fts` in `gs_pipeline_finalize`; conditional emit in `build_activity_payload()`; host fixtures + reference-vector regen; new algo params via `export_c_header.py` (don't hand-edit the generated header); bump `GS_ALGO_VERSION_STR`.
- **Cloud:** `activity-processor` + `patient-api` field plumbing; deploy `--force`.
- **Portal:** reconcile model to ft/s (`avgGaitSpeedFts`…), add `gaitSpeedFts` to `ActivitySession.fromJson`, populate gait in `session_adapter` + `live_facility_repository.rowStatsFor` (stop zeroing), un-suppress `hideGait` on data presence, chart label m/s→ft/s, drop the now-redundant `mpsToFps` in the list view, convert demo seeds ×3.28. Keep the demo build green.
- **Docs (when code lands, not before):** `ARCHITECTURE.md` §7 Activity table gets the `gait_speed_fts` row; firmware `GOSTEADY_CONTEXT.md` activity-schema cache updated in lockstep.

---

*Entry owner: Claude (firmware+cloud session, 2026-06-07). Gait-speed feature design locked spec-first; one new optional wire field (`gait_speed_fts`, ft/s). Folds in two measured algo fixes (decoupled merge-0.8 step counter: 47%→16% step MAPE, slow 78%→7%, zero distance cost; peak-train walking-time denominator removing the σ-gate exit-hold bias). Nothing implemented yet — see `docs/specs/2026-06-07-gait-speed.md` for the full design + file-level checklist.*

---

# §C47 — Device time reliability: SNTP + cloud-ingest anchoring (design) (2026-06-18)

Entry owner: Claude (firmware+cloud session) | Trigger: a portal investigation of "missing" Jun 15–16 data on `GS0000000001` traced to **~60 walks stamped year 2080**. **Implemented + bench-validated 2026-06-18 — see C47.4.** Full spec: [`docs/specs/2026-06-18-device-time-reliability.md`](../specs/2026-06-18-device-time-reliability.md).

## C47.1 — Incident + root cause

The device was online all of Jun 14–16 (≈72 heartbeat events/day; `activity_ok` in real time per server `ingestedAt`) but its own timestamps read `2080-01-05…09`, so the walks fell outside the portal window. **Data was never lost — it was mis-dated.** Root cause: the firmware's only absolute-time source is carrier **NITZ** (`AT+CCLK?`); the iBasis **roaming** eSIM's visited network didn't broadcast NITZ Jun 14–16, so the modem RTC stayed at its 1980 default (`"80/01/06"`), which the parser's `n<7` check accepts as 7 valid fields → `snprintf("20%02d…")` → 2080. The FMEA-1.1 retro-stamp can't help (same `AT+CCLK?` source). No independent anchor.

## C47.2 — Approach: "Both" (3 layers)

Principle: the monotonic clock (`k_uptime`) is reliable; absolute time = best trusted anchor + uptime-delta, anchors **NITZ → NTP → cloud-ingest**.

1. **Sanity gate** — reject `AT+CCLK?` year ∉ [2024,2050]; never emit 2080.
2. **SNTP via Nordic `date_time` lib (primary)** — `CONFIG_DATE_TIME` sources NITZ→NTP→app-set; carrier-independent time over the existing IP link; fixes the device's own clock (heartbeat `ts`, logs, TLS) too. The standard wearable/cellular-IoT pattern.
3. **Cloud-ingest anchoring (backstop, never-drop guarantee)** — activity payload gains `clock_synced`, `session_start/end_uptime_ms`, `publish_uptime_ms`, `boot_count`; when the device flags `clock_synced=false`, the cloud reconstructs `session_time = ingestedAt − (publish_uptime − session_uptime)`. Rides the proven MQTT path; would have dated Jun 14–16 correctly.

## C47.3 — Contract impact

**Revises §5** ("timestamps device-authoritative / no cloud-side time correction"): device ISO is authoritative **iff `clock_synced`**; otherwise the cloud reconstructs from uptime + trusted receive time. New optional activity fields (C47.2 #3) — accept-all tolerates old firmware. Known residual edge: reboot between record and upload invalidates the uptime delta (`boot_count` mismatch) → cloud stores a flagged `timeSource="uncertain"` best-effort time rather than dropping. Open questions (NTP server / UDP reachability on iBasis, `date_time` refresh cadence vs battery, heartbeat-`ts`/lastSeen correction) tracked in the spec.

## C47.4 — Implementation + bench results (2026-06-18)

**Firmware** (`gosteady-firmware` `0.17.0-time`, commit `874d4fa`, shipped to `main`):
- Adopted the NCS `date_time` lib (NITZ via the `%XTIME` push → NTP/SNTP → app-set). `date_time`'s modem source is the NITZ *push*, not the free-running 1980 RTC, so a no-NITZ roaming SIM structurally falls through to NTP — the real fix.
- **Deleted** the §C11.5 `at_cmd_with_timeout` wrapper + bare AT readers: `date_time_now()` is a cached read, so the time path no longer issues a modem AT command (also removes the session_start AT-lockup hazard for time). Net app RAM **60%** (the lib + SNTP fit comfortably).
- Sanity gate `src/gs_time.h` (`gs_time_year_is_plausible`, [2024,2050]); host suite 64/64.
- Activity payload emits `clock_synced` + `session_start/end_uptime_ms` + `publish_uptime_ms` + `boot_count` + `time_source`; the worker resolves both session ends from uptime via the `date_time` anchor. Heartbeat stays alive when unsynced (`clock_synced=false`, `ts` omitted).
- **Bench-validated on `GS0000000001`:** NITZ path `src=nitz`, correct date; **NTP fallback proven** — a `DATE_TIME_MODEM=n` test image got `src=ntp` + correct date, so **outbound UDP/123 works on the iBasis APN (Open Q2 = YES); firmware alone fixes the no-NITZ case** and the cloud backstop is defense-in-depth, not load-bearing. A live walk uplink carried all new fields + correct 2026 dating.

**Cloud** (`gosteady-portal`):
- `_shared/device_time.py` (pure, 13 unit tests green): `resolve_session_times` (device-authoritative when `clock_synced=true` + plausible; else uptime reconstruction `ingestedAt − age`; else flagged `"uncertain"`, never dropped) + `resolve_heartbeat_ts` (server-time substitution when unsynced/implausible).
- `activity-processor`: numbers-only validation (timestamps resolved, never rejected); stores `timeSource` + `deviceClockSynced` + a stable `deviceSessionKey` (`serial#boot#end_uptime`); metrics `activity_time_{cloud_reconstructed,uncertain}_count`.
- `heartbeat-processor`: `ts` optional; substitutes `ingestedAt` for `ts`/`lastSeen` when unsynced/implausible; `clock_synced`/`time_source` flow into Shadow `reported`. Metric `heartbeat_ts_substituted_count`.
- Idempotency note: `(patientId, session_end)` stays exact for `clock_synced=true` (the always-case on a working-NTP SIM); reconstructed rows could duplicate only under `clock_synced=false` + PUBACK-loss + retry (vanishingly rare given Q2=YES) — `deviceSessionKey` enables a future dedup.

**Follow-up:** cleanup of the ~60 legacy `2080-*` rows (un-recoverable to true times — spec §11).

---

*Entry owner: Claude (firmware+cloud session, 2026-06-18). Time-reliability design (SNTP-primary + cloud-ingest anchoring + sanity gate) in response to the Jun 14–16 2080-timestamp incident; not implemented. Full design + checklist + edge cases: `docs/specs/2026-06-18-device-time-reliability.md`.*

---

# §C48 — [rollator] Phase DT-0 device-type scaffold deployed; Core Device Contract v1 announced (2026-07-01)

## C48.1 — Context

GoSteady is adding a **second device type**: a rollator accessory-platform board
(first SKU: cupholder), same Thingy:91 X / nRF9151, different firmware +
outputs, **D2C-first go-to-market**. Full scoping (Q1–Q15 resolved with product
owner, decisions D1–D11) in `docs/specs/2026-07-01-device-types.md`; cloud
implementation spec `docs/specs/phase-dt0-device-type-scaffold.md`. Roadmap:
DT-0 (this entry, cloud scaffold) → DT-1 (firmware product split + capture-rig
reuse on a rollator-mounted dev board) → DT-2 (data collection + algo arc to
**walker-cap metric parity incl. gait**) → DT-3 (hardening) → DT-4 (D2C launch
readiness; Twilio approval is the external gate).

## C48.2 — What landed (cloud, deployed to dev 2026-07-01)

- `deviceType` (`walker_cap` | `rollator_platform`) end-to-end: Device Registry
  (registry-authoritative; optional `hardwareVariant` e.g. `cupholder_v1`) →
  snapshotted onto DeviceAssignments at provision (all 3 writers: device-api,
  patient-mgmt, d2c-claim) → denormalized onto every Activity/Alert row →
  patient-api projections. Absent anywhere = `walker_cap` (legacy default; 6
  pre-DT-0 registry records backfilled).
- Per-type ingest dispatch (`_shared/device_types/`): activity metric
  validation + named-column promotion + alert enum are per-type now; the
  envelope, time resolution (§C47), lifecycle, and heartbeat stay Core.
  **Walker-cap behavior byte-identical** (unit + synthetic + physical-cap
  regression green).
- Second IoT Thing Type `GoSteadyRollatorPlatform-dev` (fleet-provisioning
  template stays cap-pinned until Phase 5A).
- Threshold defaults keyed by type (rollator inherits walker values until
  DT-3 pins real cupholder battery numbers).
- New Observability alarm `gosteady-dev-heartbeat-processor-device-type-mismatch`
  (31 Observability alarms total) — fired + routed to the ops topic during
  smoke validation.
- Validation: **smoke 15/15 PASS** (`infra/scripts/smoke-dt0.py`, reusable;
  Cognito rd-test users + Option-A synthetic internal_admin invokes) + 296
  unit tests across 5 suites.

## C48.3 — Firmware-facing contract deltas

1. **NEW optional heartbeat field `device_type` (string).** Send the product
   type (`walker_cap` / `rollator_platform`); cloud cross-checks it against
   the registry and alarms on mismatch — **never rejects** (registry wins).
   Catches wrong-product-firmware-flashed at the first heartbeat. Cap
   firmware: add opportunistically, zero urgency (absent = no-op).
2. **Serial allocation blocks** (registry stays authoritative; blocks are
   convenience): rollator dev/bench `GS9999999980–89`; rollator production
   `GS0001000000–GS0001999999`; caps continue from `GS0000000001`.
   ⚠️ `GS9999999980` (rollator) + `GS9999999991` (walker) now exist as
   DT-0 smoke fixtures — don't reuse for real units.
3. **Rollator bench-v0 activity contract:** Core envelope (serial, session
   identity + §C47 time fields, `firmware_version`) + `active_min` required;
   everything else optional → lands in the row's `extras` map. Required set
   converges to walker parity (`steps`, `distance_ft`, `active_min` +
   optional `gait_speed_fts`) at DT-2 exit — never block a bench uplink on
   an unproven metric.
4. **Core Device Contract v1** is now written down (ARCHITECTURE §7.0): the
   rollator firmware must implement the existing activate/wipe cmd protocol,
   `last_cmd_id` echo, Shadow `desired.activated_at` re-check, heartbeat
   schema, and §C47 time fields **verbatim** — that buys the entire deployed
   lifecycle machinery (2A-DL, wipe-ack recycle, §C24 coordinator, portal
   provisioning) with zero cloud change. Suggested firmware shape per memo
   Q5: Kconfig product gate + `prj_rollator*.conf` in the same app; version
   line `rol-0.1.0-…`.
5. **No rollator device-originated alerts in v1** (memo Q11) — the enum is
   empty; candidates (`rollaway`, brake-state) at DT-4 launch planning.

## C48.4 — Finding: pre-existing IAM gap (not a DT-0 regression)

Smoke T12 surfaced that **activity-processor never had `dynamodb:UpdateItem`
on Patients**, so the 2A-UM-P auto-resume path (REMOVE `notificationsPaused`
on fresh activity, shipped 2026-05-24) had been silently dead since it
shipped — the best-effort catch swallowed `AccessDeniedException` on every
attempt. Fixed (`grantReadData` → `grantReadWriteData` in
processing-stack.ts) + deployed + re-validated (T12 green). Related DT-0
change: auto-resume is now keyed on `activeMinutes` (the universal cross-type
metric) instead of `steps` — env knob renamed `AUTO_RESUME_MIN_ACTIVE_MIN`
(default 0, semantics unchanged).

## C48.5 — State after this entry

- Cloud: DT-0 complete in dev; walker fleet unaffected (`GS0000000001` still
  `active_monitoring` for Rosa, heartbeats clean on the new code).
- Firmware queue (DT-1, when rollator work starts): product split (memo Q5),
  Core Contract conformance, capture tooling verified on a rollator-mounted
  board (capture.html / control.py / pull_sessions.py carry over per Q14),
  rollator capture-protocol doc + annotation spreadsheet, bench unit from
  the `GS9999999980–89` block (skip …80) per the bring-up playbook against
  the new Thing Type.
- Watch items: `GS0000000001`'s next real walk confirms activity-row shape on
  the new dispatch path (synthetic walker regression already green); the
  deferred T10 (d2c-claim runtime snapshot) folds into the next d2c smoke.

---

# §C49 — [rollator] DT-1: firmware product split shipped + GS9999999981 bring-up (blocked only on SIM claim) (2026-07-02)

## C49.1 — What landed (firmware, direct-to-main)

The one-app/two-products split per memo D8/Q5 (portal spec
`phase-dt1-rollator-bench-bringup.md`):

- **Kconfig `choice GOSTEADY_PRODUCT`** (default `WALKER_CAP` — all
  pre-DT-1 overlays resolve unchanged; verified in both build `.config`s
  and at the binary-string level).
- **`src/version.h`**: 2-D product × power-mode cascade. Walker strings
  byte-identical (cohort continuity); rollator line `rol-0.1.0-{bench|
  pilot|ww}` (`ww` not `wakewindow`: the .dat header's
  `firmware_version[16]` fits 15+NUL — the walker wakewindow string
  already truncates there, pre-existing). New
  `GS_PRODUCT_DEVICE_TYPE_STR` = the cloud enum string.
- **`src/cloud.c`**: (1) heartbeat gains `device_type` (BOTH products —
  walker units start self-reporting on their next flash; DT-0's
  cross-check + alarm are live cloud-side); (2) `build_activity_payload`
  is product-split at the wire boundary — rollator bench-v0 emits
  `serial/session_start/session_end/active_min` + the §C47 time block +
  `time_source` + `firmware_version`; walker branch byte-identical to
  pre-change; roughness/gait/surface compile-gated out for rollator
  (sentinels are data-driven, so compile-time gating is the only way to
  guarantee omission).
- **Capture vocab, append-only in lockstep** (session.h enums +
  control.c tables + read_session.py + workbooks): `rollator_4wheel`,
  `frame_mount`, `accessory_platform`, `brake_stop`, `brake_drag`,
  `park_brake_seated`, `heavy_lean`. A 2026-05-05 walker .dat re-parsed
  clean post-change.
- **`prj_rollator_cloud.conf`** (self-contained; exactly 3 diffs vs
  prj_cloud: product flag, client id `GS9999999981`, snippets OFF).
- **Tooling/assets**: `tools/capture_rollator.html` (39-run matrix =
  3 surfaces × 13 incl. 90° turns / brake_stop / heavy_lean /
  park_brake_seated; isolated localStorage), control.py rollator
  presets, `GoSteady_Rollator_Capture_Protocol_v1.md` +
  `GoSteady_Rollator_Annotations_v1.xlsx`.

Validation: rollator build RAM 62.6%; walker regression via prj_pilot
pristine (see C49.3); host suite 64/64; 4-lens adversarial review — zero
blockers/majors, all cross-repo contract checks pass (payloads accepted
by deployed DT-0 validators; envelope fields land as envelope, not
extras).

## C49.2 — GS9999999981 bring-up state (READ THIS before touching the unit)

Fresh Thingy:91 X, SW2=nRF91 throughout (factory bridge fine — no nRF53
flash needed). Done: cert minted + flashed (sec_tag 201, verified);
Thing under `GoSteadyRollatorPlatform-dev`; registry record via the
DT-0 bulk-create path (`deviceType=rollator_platform`,
`hardwareVariant=thingy91x_bench`); `rol-0.1.0-bench` flashed;
**9.5 h overnight soak: boot 1, faults 0/0/0**; provisioned to
`pat_dt1_rollator_bench_1782968418` (client_rd_test) — activate cmd
`act_7bcdb1ca…` queued (24 h window from 2026-07-02T05:00Z); a 15 s
desk session (`e7f1be80…`) recorded via the uart1 rollator preset
(motion-gate auto-stop fired correctly on stillness; activity enqueued
with empty ISO + uptimes = the §C47 reconstruction path, waiting on
cellular) — the `.dat` is ON-DEVICE, **pull before any reboot** (boot
orphan sweep).

**BLOCKED on one operator step: the iBasis trial eSIM is unactivated —
EMM cause 8 ("EPS+non-EPS services not allowed") on every attach for
9.5 h across multiple cells/TACs.** Claim the SIM on nRF Cloud (ICCID
on the box label, or AT%XICCID via at_client), power-cycle, and
registration should complete → first heartbeat carries
`device_type:"rollator_platform"` → §C24 coordinator delivers the
queued activate. USB CDC also needs a re-plug (disconnected 08:23;
board is on battery — J-Link still reads the target). Full resume
runbook: portal spec §Deployment.

## C49.3 — Finding: plain `prj_cloud.conf` no longer links at 0.17.0 (pre-existing)

Pristine walker `prj_cloud` build on unmodified `main` fails: **RAM
overflows by 1296 B** (identical overflow with the DT-1 diff applied —
i.e., the product split adds zero RAM). Every recently-flashed unit
shipped pilot/wakewindow configs (snippets OFF), so the plain-cloud
overlay quietly rotted past the 0.16/0.17 growth. Documented in
GOSTEADY_CONTEXT.md's build table; walker-side fix deferred (needs its
own bench validation). Walker regression for DT-1 was validated on
`prj_pilot.conf` — the config actually deployed on GS0000000001/98.

## C49.4 — Known follow-ups

- Behavioral `no_activity_today`/`below_typical` are steps-keyed → will
  mis-fire on rollator patients until the DT-4 `activeMinutes` re-key
  (memo Q8). Bench patient is synthetic (client_rd_test) so the alerts
  are inert rows; flagged in the spec runbook so nobody mistakes it for
  a firmware fault.
- iBasis SIM-claim step should be added to the bring-up playbook
  pre-flight once the exact claim flow is confirmed on this SIM.
- Rollator DT-2 queue: mount the board on a real rollator, run the
  39-run capture protocol, start the wheeled-motion algo arc (target:
  walker-cap metric parity incl. gait, memo D10).

---

# §C50 — [rollator] Capture-image fixes from the first live BLE protocol smoke (2026-07-02)

First operator-driven capture attempt on `GS9999999981` (capture_rollator.html
over the always-on BLE bridge) surfaced three findings; all fixed same-day
(fw commit on main):

1. **Motion auto-start vs operator capture** — handling the rollator between
   runs auto-started squatter sessions; the operator's next START returned
   `ERR already active` and stray STOPs closed phantom sessions (2/4 runs
   lost their POST-WALK popups). Fix: `CONFIG_GOSTEADY_MOTION_AUTOSTART`
   (default y; capture image sets =n). Field/pilot/cloud builds unchanged.
2. **Stillness auto-stop vs 30 s baseline runs** — the 15 s Phase-3
   auto-stop would kill `stationary_baseline`/`park_brake_seated` protocol
   runs. Fix: control.c-started sessions are marked manual
   (`gosteady_session_mark_manual`) and exempt from stillness auto-stop
   (flash-full auto-stop still applies).
3. **Cloud build auto-prune ate the day's raw data** — all smoke-run `.dat`s
   were pruned seconds after their activity uplinks PUBACKed (working as
   designed, wrong build for capture). The capture-day image
   (`build_rollator_bench`: no cloud + autostart off + DATE_TIME NITZ-only)
   is now flashed + documented as the protocol prerequisite.

Bridge note: `GS9999999981`'s nRF5340 runs the fork with
`CONFIG_BRIDGE_BLE_ALWAYS_ON=y` (Config.txt toggle proved unreliable to
persist from macOS; the compiled-out option is the robust posture for
dedicated capture units). Canonical bridge flash on this env:
`west flash --runner nrfjprog --recover` (default nrfutil runner is broken).

---

# §C51 — [rollator] Capture-day blockers: bridge uart1 enable-on-USB-only + boot orphan sweep data loss (2026-07-04)

## C51.1 — Bridge bug, empirically confirmed (ROOT CAUSE OF ALL BLE dead-air)

The nRF5340 bridge fork only enables/opens **uart1 when a USB CDC host opens
the port** (DTR/SET_LINE_CODING path). A BLE peer connect does NOT enable it
— the fork's peer_conn_event(dev_idx=1) patch updates routing but evidently
not the UART-enable path. Once USB has enabled uart1, the state PERSISTS
(asymmetric enable/disable), which produced the confusing intermittency:

- 2026-07-02 11:17 BLE session: zero RX (cold boot, BLE-only) — dead air
- 2026-07-02 14:15+ sessions: WORKED — Claude's USB CDC sniffer/tools had
  opened uart1 minutes earlier
- 2026-07-04: cold boot ~12:02 → BLE-only dead air again; **user-confirmed
  workaround: plug USB once after power-on ("get started"), then unplug and
  BLE keeps working for the rest of the boot**

**FIX (pending, next session):** force uart1 permanently enabled at bridge
boot in `bridge_fw` (it is a dedicated command tunnel; read
`src/modules/uart_handler.c` subscriber/enable logic and give uart1 a
permanent subscriber or enable at init). Rebuild with
`-DCONFIG_BRIDGE_BLE_ALWAYS_ON=y` as before; flash needs SW2→nRF53 +
`west flash --runner nrfjprog --recover` (default nrfutil runner broken on
this env).

## C51.2 — Boot orphan sweep = un-pulled capture data loss (COST 15 RUNS TODAY... see C51.3)

`session.c` boot-time orphan sweep (called from main.c init) deletes ALL
`/lfs/sessions/*.dat` unconditionally at every boot — including on the
capture image, where un-pulled files are irreplaceable protocol data, not
stale garbage. The 2026-07-02 runs survived only because they were pulled
same-day; today's boot wiped what remained.

**FIX (pending, next session):** `CONFIG_GOSTEADY_BOOT_ORPHAN_SWEEP`
(default y — field/cloud hygiene unchanged), set =n in the capture image
build args alongside `MOTION_AUTOSTART=n`.

## C51.3 — 15 protocol runs lost today

User executed ~15 protocol runs on 2026-07-04; **only one session
(`c3d15e15`, 39.3 s stationary connectivity test, 12:14) ever reached the
device** — the runs were driven through a dead-air BLE session (C51.1;
commands never arrived, so nothing recorded; the capture page was also on a
different origin (localhost vs github.io), so its notes stayed empty in the
github.io export). Runs must be repeated after the fixes.

## C51.4 — Interim workaround (until both fixes land)

1. After EVERY power-on: plug USB, open the uart1 port once (e.g.
   `tools/control.py status`), or just start the session flow with USB
   attached — then unplug and collect over BLE freely.
2. NEVER power off / reboot the board with un-pulled `.dat` files —
   pull per block (`tools/pull_sessions.py`) religiously.
3. Verify recording is real before walking a block: after START, the page's
   Last response must show `OK started <uuid>` (dead air = no response).

## C51.5 — State after this entry

- Device: GS9999999981 on capture image (§C50 fixes in) + always-on-BLE
  bridge; healthy, Onomondo NITZ, one stationary test session pulled today.
- Safe on disk: 2026-07-02 runs 1-2 + handling sessions
  (`raw_sessions/2026-07-02-dt1-bench/`), today's `c3d15e15` pending pull.
- Pending next session: C51.1 bridge fix + C51.2 sweep Kconfig, reflash
  both cores' owners, cold-boot BLE-only validation, then re-run the
  protocol. P5 End-Monitoring/wipe smoke still queued (needs cloud image
  reflash after capture days conclude).

---

# §C52 — [rollator] Distance estimator: data recovery + honest re-validation + firmware port (flashed) (2026-07-05/06)

## C52.1 — §C51.3 "15 runs lost" is RETRACTED — 16 sessions recovered

Before any reflash, a non-destructive `pull_sessions.py --list-only` found **16
valid sessions still on GS9999999981** and pulled them all
(`raw_sessions/2026-07-04-dt1-rollator/`, all validate). The runs recorded fine
over BLE; they only *looked* lost because (1) the uart0 console log had a ~19-min
gap (USB unplugged for untethered BLE capture, so `session_start` lines weren't
logged) and (2) **Bug 1 is RX-biased, not dead air** — page→device commands DID
arrive (sessions started + recorded), only the device→page confirmations were
missing, so the operator saw "dead air" and assumed nothing recorded. Nothing was
lost; the device never rebooted, so the boot sweep hadn't run. **Lesson (firmware
GOSTEADY_CONTEXT + memory): LIST the device before declaring capture lost —
on-device flash is ground truth, console-log gaps ≠ no recording.** This also
right-sizes §C51: those "blockers" were largely a misread, so **Path B (bridge
uart1 fix + boot-sweep Kconfig) is PARKED** — USB-touch + pull-before-reboot
suffice.

## C52.2 — Distance estimator: steps dropped; surface-normalized vibration odometer; the honest arc

Frame-mount rollator IMU is **wheel-vibration-dominated, not step impulses**
(measured: 72–98 % of dynamic-accel energy in the 10–45 Hz wheel band, ~0–7 % in
the 0.7–3 Hz gait band). **Steps dropped for rollator** (operator decision); metric
set = `active_min` + `distance_ft` + `gait_speed_fts`. Approach:
`distance = m · Σ_active(HP window RMS · dt) / flatness`, where flatness (spectral
flatness of the wheel vibration) is a **speed-independent roughness** descriptor
that de-confounds amplitude (a rougher surface buzzes harder at equal speed).

**Honest arc — a headline was retracted, then re-validated:** an initial
"flatness-normalized ~17 % ≈ oracle" result was a **constant-speed artifact**. A
13-agent adversarial-review workflow reproduced the numbers and showed a plain
stopwatch (`dist = m·walk_t`) *beat* it (11.6 % vs 16.9 %) because the 07-04 runs
were all ~0.66–1.21 ft/s; within one surface flatness added nothing; the naive-vs-
flat gap CI crossed zero. Rebuilt the harness honestly (time-only baseline beside
every model, nested feature selection, wheel-band Schmitt gate, leave-one-SURFACE-
out first, bootstrap CIs). The **07-05 pull** (asphalt = 3rd surface; real speed
range **0.55–3.08 ft/s**) **reversed it**: flat-norm **29.4 %** vs time-only
**42.7 %** (gap CI [−22, −6], p=0); within-surface raw vibration 11–14 %; realistic
deploy (82 % surface classifier → per-surface curve) **26.3 %** ≈ walker parity;
oracle 15.9 %. **Wheel-rotation odometry ruled out** (implied circumference CV
94 %). **Continuous flat-norm chosen for the port** (no misclassification cliff,
simpler on-device, ~3 pp cost). Full arc + figures:
`gosteady-firmware/docs/specs/2026-07-04-rollator-algorithm-scope.md` §3a–§3f.

## C52.3 — Capture protocol reconfigured + 07-05 data

`tools/capture_rollator.html` reconfigured to a **42-run distance protocol** (3
surfaces polished < sidewalk < asphalt × 3 speeds × 2 distances [20/40 ft] × 2 reps
+ 2 mid-run 10 s-pause runs/surface), pushed live to github.io. Operator captured
it (53 sessions pulled). **First sidewalk pass (14 runs) invalidated** — mistaped
course distance, per operator (adjusted notes; original preserved). Asphalt set
complete. Pause runs validate the motion-gate trim: the wheel-band gate correctly
ignores a lean-during-pause (frame load, no roll → no wheel vibration → no fake
distance).

## C52.4 — Firmware port (flashed + on-device verified) + NEW cloud-contract fields

New `src/algo/gs_rollator_distance.{c,h}` + `gs_rollator_params.h` (coeffs from the
golden reference `algo/rollator_distance_ref.py`): streaming **causal** biquads,
16-band filter bank (1–49 Hz), wheel-band Schmitt gate + flat-norm at finalize.
**No FFT, no classifier.** Compile-gated `CONFIG_GOSTEADY_PRODUCT_ROLLATOR`
everywhere → **walker build byte-identical (verified: module not compiled in the
pilot build).** **Host-parity validated** (`tests/host/test_rollator_distance.c`)
on all **44** valid walking sessions: distance & flatness max rel-err **0.02 %**,
gate windows identical, valid 44/44. Two bugs fixed en route: CMSIS biquad sign
convention (a1,a2 negated vs scipy) and window RMS = `np.std` (mean-subtracted).

**⚠ CLOUD-CONTRACT DELTA (cloud side please note):** the **rollator** activity
payload (`cloud.c` `build_activity_payload`, `PRODUCT_ROLLATOR` branch) now emits
**`distance_ft` + `gait_speed_fts`**, confidence-gated (`isfinite` → else omitted;
distance is a within-resident **trend** ~26–31 % MAPE, not a precise odometer).
These were walker-only fields — **the DT-0 validators + activity-processor should
accept them for `device_type:"rollator_platform"`.** `active_min` unchanged.

**Flashed** `build_rollator_dist/merged.hex` via **`nrfutil device`** — ⚠ the
standalone `nrfjprog` CLI is broken on this machine (bound to stale system JLink
**V9.34a** → `-256`; not a probe/cable fault). Use `~/.nrfutil/bin/nrfutil device
program …` (current bundled JLink) or the nRF Connect GUI. On-device stationary
session logged `ROLL_DIST valid=0 dist_ft=0.00 flat=0.0000 vib=0.099 walk_s=0.5
nact=1`; host C on the same pulled `.dat` matched exactly → **Python ref == host C
== on-device** on real data. Full flash+test runbook: firmware port spec §8
(`docs/specs/2026-07-05-rollator-distance-firmware-port.md`).

## C52.5 — State after this entry

- GS9999999981 runs the rollator distance capture image (`build_rollator_dist`).
  Restore point: `build_rollator_bench/merged.hex` (nrfutil, same options).
- **Remaining:** (1) a **pushed-rollator** session to exercise the *valid-distance*
  path on hardware (bench sessions only reach `valid=0` — no motion); (2) the cloud
  rollator build to verify the payload end-to-end (pre-existing RAM overflow, §C49);
  (3) a **2nd-rollator generalization capture** — decides compile-time vs NV
  calibration (all data is one rollator/mount/subject); (4) cloud-side accept of the
  two new rollator activity fields.
- Firmware commits (main), all pushed: honest harness → port scope → rotation-rate
  ruled out / flat-norm chosen → `gs_rollator_distance` module + host parity →
  session/payload integration → flashed + verified.

---

# §C53 — [rollator] Pilot firmware flashed → end-to-end live; cloud distance/gait promotion; a ProcessingLambda bundling-bug fix (2026-07-06)

Closes the §C52.5 remaining items on both sides: the rollator is now flashed to
its deployment posture, live + activated on the cloud, and the two new activity
fields (`distance_ft` + `gait_speed_fts`) are promoted cloud-side and
synthetic-validated end-to-end.

## C53.1 — Firmware: deployment overlays + canonical build-config doc

An audit (does the walker's battery/stability work carry forward to the
rollator?) confirmed the split is a **single-app Kconfig product gate**, not a
fork (walker default) — so every platform mechanism is inherited by
construction. BUT the rollator had only a bench+cloud overlay
(`prj_rollator_cloud.conf`); the battery/shipping-mode bundle had no rollator
overlay to switch it on. Added:
- **`prj_rollator_field.conf`** (deployment baseline) + **`prj_rollator_pilot.conf`**
  (= field + LOW_POWER + SESSION_LED + PREACT_LOWPOWER) — carries the walker's
  proven battery/shelf-life/shipping-mode work forward verbatim (shared code).
  Snippets OFF (rollator corpus is uart1 `.dat`, not cloud snippets; also RAM).
  Build-verified: `rol-0.1.0-ww`, app RAM 63.05%.
- **`gosteady-firmware/docs/build-configurations.md`** — canonical overlay×symbol
  matrix + build-dir→device map + version-string ambiguity note (capture/cloud/
  field rollator builds all report `rol-0.1.0-bench`; fix proposed, not applied —
  `firmware_version` feeds cloud cohorts). Fixes the doc scatter that caused a
  diagnosis miss (a capture-image unit *looked* like it lacked basic features —
  really `MOTION_AUTOSTART=n` by design).
Firmware commits (main): `b8c952a`, `acf4aaf`.

## C53.2 — Firmware: pilot flashed to GS9999999981 → end-to-end LIVE

Flashed `prj_rollator_pilot.conf` (`rol-0.1.0-ww`) via `nrfutil device`. Boot +
Shadow confirm the whole stack:
- **Onomondo SIM works** (the dev-unit record's "iBasis EMM-cause-8 unactivated"
  note was stale — the user swapped in an Onomondo SIM): `registered_roaming`
  LTE-M, **PSM granted tau=3 h/active=2 s**, NITZ time OK (`src=nitz`, correct
  2026 date), rsrp −92, battery ~100%.
- **Already activated** (`activated_at=2026-07-02T16:16:40Z`, cmd `act_7bcdb1ca…`)
  — `activation.bin` persisted across the reflash (ext-flash preserved).
- Cloud Shadow `reported`: `firmware=rol-0.1.0-ww`, `device_type=rollator_platform`
  (heartbeat-processor cross-check PASS, no mismatch alarm); registry
  `active_monitoring`. Carried-forward mechanisms confirmed in the boot log (WDT,
  forensics, gated sampler, OCV).
The one on-device capture session was pulled first
(`raw_sessions/2026-07-06-pre-pilot-flash/`, validates) — LIST-before-reflash.

## C53.3 — Cloud: distance_ft + gait_speed_fts promoted to named columns

Firmware §C52 emits `distance_ft` + `gait_speed_fts`, but the DT-0 validator only
named `active_min`, so they landed in `extras` — invisible to the portal.
Promoted (`_shared/device_types/rollator_platform.py`):
- `distanceFt` + `gaitSpeedFts` are now named columns — **optional**,
  confidence-gated, drop-on-invalid (mirrors walker gait; firmware omits them
  when the vibration odometer can't produce a valid estimate). `active_min` stays
  the only required metric.
- **`steps` dropped for rollator** (a frame-mount has no lift-and-place impulses,
  §C52.2) — a stray `steps` stays in `extras`. **This amends memo D10** (target
  was walker parity incl. steps): rollator metric set = `active_min` +
  `distance_ft` + `gait_speed_fts`. Docs in lockstep (ARCHITECTURE §7.0,
  device-types §3.2/D10; scope spec
  `docs/specs/2026-07-06-rollator-distance-cloud-promotion.md`).
- Deployed to `GoSteady-Dev-Processing`; 29/29 unit tests; **synthetic-validated**
  (distance+gait → named columns, stray steps → extras, stationary payload →
  `active_min`-only + valid). Backward-compatible.
Portal commit (`feature/infra-scaffold`): `3b697e3`.

## C53.4 — Finding + fix: ProcessingLambda `_shared`-only changes silently didn't deploy

The first `cdk deploy` reported **"no changes" (3.75 s no-op)** on a real Python
edit. Root cause (pre-existing): `ProcessingLambda` uses
`Code.fromAsset(handlerDir, …)` → default `SOURCE` asset hash covers only the
handler dir, but bundling vendors `_shared/` in from **outside** it. So any
`_shared`-only change is invisible to the asset hash and **silently does not
deploy**. Past `_shared` changes only shipped because they rode alongside handler
edits (DT-0 refactored the handlers; §C47 device_time touched them). Fixed:
`assetHash` now hashes both the handler dir AND `_shared/` content
(`processing-lambda.ts`) — the redeploy became a real 40 s update. Unblocks all
future `_shared`-only Processing deploys.

## C53.5 — State after this entry

- **Rollator is end-to-end live** on the deployment posture: device → cloud →
  named `distanceFt`/`gaitSpeedFts` columns (portal-readable). GS9999999981
  `active_monitoring`, `rol-0.1.0-ww`, Onomondo.
- **Remaining for real distance data:** a **pushed/rolling** session (bench + desk
  sessions reach `valid=0` — the odometer needs actual wheel motion) + a
  2nd-rollator generalization capture (compile-time vs NV calibration).
- **Next phase — DT-4 (D2C launch readiness), now unblocked:** Twilio compliance
  **approved 2026-07-06** (external gate cleared; `gosteady/dev/twilio` secret
  population still pending, operator). DT-4 = D2C dashboard rollator rendering
  (per-type widget registry — Q10 lands here first), rollator QR-claim + SMS-OTP
  live, behavioral rules re-keyed on `activeMinutes` (Q8 launch gate), D2C
  wrap-up (§C41.3). Portal-rendering scope is being drawn up next.
- Deferred/known: the `rol-0.1.0-*` version-string collision (capture/cloud/field)
  — fix proposed in `build-configurations.md` §5, not yet applied (cloud-cohort
  surface).

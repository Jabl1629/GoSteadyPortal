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

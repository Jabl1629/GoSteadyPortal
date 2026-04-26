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

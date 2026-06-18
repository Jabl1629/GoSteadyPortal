# Device Time Reliability — cross-team design spec (firmware + cloud)

> **Status:** Design (this doc). **Not implemented.** Approved approach:
> "Both" — SNTP-primary + cloud-ingest anchoring backstop + sanity gate.
> **Repos:** `gosteady-firmware` (time acquisition + payload) · `gosteady-portal`
> (activity-processor reconstruction + contract).
> **Coord log:** `2026-04-17-cloud-contracts.md` §C47.
> **Revises:** the §5 "timestamps are device-authoritative / no cloud-side time
> correction" trust contract.

---

## 1. Why — the Jun 14–16 incident

`GS0000000001` (Rosa) recorded ~60 walks on Jun 14–16 that are in the cloud but
**stamped year 2080**, so they fall outside the portal's window and looked like
"missing days." Established from the cloud:

- The device was **online the whole time** — ~72 heartbeat events/day, and
  `activity_ok` writes in real time (server `ingestedAt` = Jun 14–17).
- The device's own timestamps read `2080-01-05…09`. Mapping real-ingest → device
  date shows a clean 2080 excursion Jun 14–16, correct again Jun 17.

**Root cause:** the firmware's *only* absolute-time source is carrier **NITZ**
via `AT+CCLK?` (`grep` confirms no SNTP compiled in). The SIM is an iBasis
**global roaming** eSIM; NITZ is optional in 3GPP and the visited network(s)
Jun 14–16 didn't broadcast it. With no NITZ the nRF9151 modem RTC sits at its
**1980 default**, so `AT+CCLK?` returns `"80/01/06,…"`. Two code gaps let that
through:

1. `cellular.c::read_network_time_iso8601()` only rejects a *malformed* reply
   (`n<7`). `"80/01/06"` is 7 well-formed fields → `snprintf("20%02d…")` →
   **2080**. No plausibility check on the year.
2. The **FMEA-1.1 retro-stamp** (`cloud.c` activity worker, ~L1130) recomputes
   times as `cellular_now − uptime_delta` — but `cellular_now` is the *same*
   `AT+CCLK?` source, so it inherits the garbage. There is no independent anchor.

---

## 2. Goals / non-goals

**Goals**
- Correct device timestamps regardless of whether the carrier provides NITZ.
- **Never drop or mis-date activity**, even in total wall-clock failure.
- Fix the device's *own* clock too (heartbeat `ts`, logs, TLS cert window).

**Non-goals**
- Sub-second accuracy (day/hour granularity is what the product needs).
- GNSS-based time (no GNSS in v1).
- Recovering the existing 2080 rows (separate cleanup, §11).

---

## 3. Principle

The device's **monotonic clock (`k_uptime`) is always reliable**; only the
absolute *anchor* failed. So: **absolute time = best-available trusted anchor +
uptime-delta**, with anchors in priority **NITZ → NTP → cloud-ingest**. Sessions
already capture `session_start_uptime_ms` / `session_end_uptime_ms`
(`session.c`), so the backbone exists.

---

## 4. Design — three layers

### 4.1 Sanity gate (firmware) — stop 2080 at the source

Validate the parsed `AT+CCLK?` time before use: year ∈ **[2024, 2050]** (+ basic
month/day bounds). Out of range ⇒ treat as **unsynced** (return the existing
`-EAGAIN` "no cellular UTC" path; set `clock_synced=false`). Applies to all three
read paths: `read_network_time_iso8601()`, `…_bare()`,
`gosteady_cellular_get_network_time_unix_ms()`. Mostly subsumed once §4.2 lands
(date_time validates internally) but kept as a hard floor — nothing year<2024
ever reaches a timestamp.

### 4.2 SNTP via Nordic `date_time` lib (firmware primary)

Adopt the NCS **`date_time`** library (`CONFIG_DATE_TIME=y`), which Nordic ships
for exactly this: it sources time **NITZ → NTP → app-set**, in priority, and
auto-refreshes. This replaces the bespoke `AT+CCLK?` math:

- `date_time_update_async()` on LTE attach (and a periodic refresh / on-demand
  when stale).
- `date_time_now(&unix_ms)` for "now"; **`date_time_uptime_to_unix_time_ms()`**
  converts a stored session `k_uptime` value to absolute UTC using the synced
  anchor — this *is* the retro-stamp, but anchored to NTP when NITZ is absent.
- NTP runs over the already-attached data link (one small UDP round-trip; DNS
  already works — we resolve the AWS IoT host). Carrier-independent.

Effect: the device's clock is simply correct wherever it has data, the standard
way. All timestamps (heartbeat `ts`, session ISO, logs) derive from `date_time`.

**Power (pilot/low-power build):** NTP is one UDP exchange on an
already-up modem. Refresh cadence must be tuned for the 30-day budget — e.g.,
refresh on attach + only when the cached time is older than a threshold, not a
fixed short interval. Quantify in the bench model (Open Q3).

### 4.3 Cloud-ingest anchoring (cloud backstop) — the never-drop guarantee

For the residual case where **NITZ and NTP both fail** (dead spot, UDP blocked),
the device still uploads over its proven MQTT/TLS path. The activity payload
carries the monotonic uptimes + a sync flag; the cloud reconstructs absolute time
from its **trusted receive time**:

```
if not clock_synced and boot_count_at_publish == boot_count_at_record:
    age_end   = publish_uptime_ms - session_end_uptime_ms
    age_start = publish_uptime_ms - session_start_uptime_ms
    session_end   = ingestedAt - age_end
    session_start = ingestedAt - age_start
    timeSource = "cloud_reconstructed"
```

`ingestedAt` is server-authoritative; `k_uptime` is monotonic-reliable, so this
is accurate to the upload latency (seconds normally; correct even for a long
*same-boot* upload delay). This is what would have correctly dated the Jun 14–16
walks.

---

## 5. Wire contract delta — `gs/{serial}/activity`

New optional fields (firmware emits when relevant; cloud accept-all tolerates
absence from old firmware):

| Field | Type | Notes |
|---|---|---|
| `clock_synced` | bool | true if `session_*` ISO came from a *valid* NITZ/NTP time; false ⇒ cloud should reconstruct |
| `session_start_uptime_ms` | uint | `k_uptime` at session start (already tracked on-device) |
| `session_end_uptime_ms` | uint | `k_uptime` at session end (already tracked) |
| `publish_uptime_ms` | uint | `k_uptime` at publish (anchor for the age delta) |
| `boot_count` | uint | guards against reboot-between-record-and-upload (already in heartbeat) |
| `time_source` | string | (optional) `nitz` \| `ntp` \| `unsynced` — observability |

The existing `session_start` / `session_end` ISO stay; they're authoritative
**iff** `clock_synced=true`.

---

## 6. Cloud-side changes (`infra/lambda/activity-processor`)

- Read the new fields. If `clock_synced=false` (or the device ISO year is
  implausible) **and** `boot_count` matches between record/publish ⇒ reconstruct
  per §4.3; else (reboot mismatch) mark `timeSource="uncertain"` and store with a
  best-effort `ingestedAt`-derived time + a flag (never drop — §9).
- Persist `timeSource` on the Activity row for observability + a dashboard
  breakdown (how often we fall back).
- **Heartbeat `ts` / lastSeen:** decide whether the heartbeat-processor should
  also ignore a 2080 `ts` and use `ingestedAt` for `lastSeen` (Open Q4) so the
  portal's device-health time can't show 2080.

---

## 7. Firmware changes (`gosteady-firmware`)

- `prj_*.conf`: `CONFIG_DATE_TIME=y` (+ NTP server / refresh-interval Kconfig).
- `cellular.c`: replace `AT+CCLK?` reads with `date_time` API; add the §4.1
  sanity gate; expose `clock_synced` + a `now_uptime` helper.
- `session.c` / `cloud.{h,c}`: thread `clock_synced`, the session/publish uptimes,
  and `boot_count` into the activity payload + `build_activity_payload()`.
- `version.h` bump (e.g., `0.17.0-time`).
- `GOSTEADY_CONTEXT.md` + `ARCHITECTURE.md` §7 + coord §C47 updated in lockstep
  **when the code lands**.

---

## 8. Invariants

- **No timestamp with year < 2024 ever reaches the wire.**
- **Activity is never dropped** for lack of time — it gets NITZ, else NTP, else
  cloud-reconstructed, else a flagged best-effort time.
- Within a boot, uptime anchoring is exact to the upload latency.
- `clock_synced=true` ⇒ device ISO is authoritative (cloud does not override).

---

## 9. Edge cases (the ones we walked through)

| Case | Handling |
|---|---|
| NITZ absent (roaming) | NTP (§4.2) supplies time; clock_synced=true |
| NITZ **and** NTP both fail | cloud-ingest reconstruction (§4.3); clock_synced=false |
| **Reboot between record and upload** | `boot_count` mismatch ⇒ uptime delta invalid ⇒ can't reconstruct ⇒ store with `timeSource="uncertain"` + best-effort time, **flagged, not dropped**. (Bounded: sessions normally upload same-boot; cross-reboot unsent data is already at risk — FMEA 6.3 queue unbuilt.) |
| Long *same-boot* upload delay | Handled — uptime spans the delay; reconstruction stays correct |
| Crystal drift | Negligible at day/hour granularity |
| Device self-clock (heartbeat ts / logs / TLS) | Fixed by §4.2 (NTP). If NTP also fails, lastSeen can fall back to `ingestedAt` cloud-side (Open Q4) |
| Mid-session NITZ loss | uptime anchoring covers both ends from one valid reference |

---

## 10. Validation plan

- **Firmware unit/host:** sanity-gate parse (reject `80/01/06`, accept `26/06/18`);
  uptime→unix conversion.
- **Cloud unit:** reconstruction math (`ingestedAt − age`), boot-mismatch →
  uncertain, clock_synced=true passthrough.
- **Bench:** force the no-NITZ condition (SIM/cell without NITZ, or disable) →
  confirm NTP sets the clock; force a 2080 `AT+CCLK?` → confirm sanity gate +
  reconstruction; block NTP too → confirm cloud reconstruction dates correctly.
- **Re-walk** on `GS0000000001` and confirm correct dating end-to-end.

---

## 11. Out of scope / follow-ups

- **Cleanup of the existing ~60 `2080-*` rows** (real Jun 14–16 walks). They're
  un-recoverable to true times (device clock was the only source at the time);
  options: leave (invisible) or delete. Separate task.
- Patient-timezone "today" definition (viewer-tz vs facility-tz) — separate
  portal fix already discussed.
- Persistent cross-reboot telemetry queue (FMEA 6.3).
- GNSS time.

---

## 12. Open questions

| # | Question | Lean |
|---|----------|------|
| Q1 | NTP server: Nordic default pool vs `time.aws.com` vs `pool.ntp.org`? | Nordic default + one explicit fallback; verify UDP/123 reachability on the iBasis SIM at bench |
| Q2 | Does the iBasis roaming APN allow outbound UDP/NTP at all? | Bench-test; if blocked, the cloud backstop (§4.3) carries it and SNTP is best-effort |
| Q3 | `date_time` refresh cadence vs the 30-day pilot battery budget | Refresh on attach + when stale only; quantify in bench model |
| Q4 | Should the cloud also correct heartbeat `ts`/`lastSeen` (so device-health can't show 2080)? | Lean yes — cheap heartbeat-processor guard using `ingestedAt` |
| Q5 | When `clock_synced=true`, should the cloud still cross-check device ISO vs uptime-reconstruction to *detect* drift? | Optional observability; off by default |

---

*Owner: Claude (firmware+cloud session, 2026-06-18). Approach = SNTP-primary
(`date_time` lib) + cloud-ingest anchoring backstop + sanity gate. Triggered by
the Jun 14–16 2080-timestamp incident on `GS0000000001`. Design only — no code.*

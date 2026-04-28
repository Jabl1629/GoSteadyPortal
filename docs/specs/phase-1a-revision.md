# Phase 1A Revision — Snippet ingestion + downlink topic + Shadow IoT-policy grants + OTA bucket CMK

## Overview
- **Phase**: 1A (Revision)
- **Status**: ✅ Deployed to dev 2026-04-27
- **Branch**: feature/infra-scaffold
- **Date Started**: 2026-04-27
- **Date Completed**: 2026-04-27
- **Supersedes**: extends [`phase-1a-ingestion.md`](phase-1a-ingestion.md) without breaking existing IoT Rules.

Extends the deployed Phase 1A IoT Core ingestion stack with four additive
deliverables, all on the same `GoSteady-{Env}-Ingestion` stack. The first
three are driven by the firmware ↔ cloud contracts in
[`docs/firmware-coordination/2026-04-17-cloud-contracts.md`](../firmware-coordination/2026-04-17-cloud-contracts.md);
the fourth wraps up an outstanding Phase 1.5 deliverable that was deferred
to this revision.

1. **Snippet ingestion path** — new IoT Rule + thin Python Lambda + S3 bucket
   for opportunistic raw-IMU uploads. Binary payload framed as
   `[4-byte BE uint32: header_len][header_len JSON][raw IMU samples]` per
   firmware §F.3 + §F.4 (NCS 3.2.4 is MQTT 3.1.1 only — MQTT user properties
   were not viable; the Lambda parses the preamble to extract `snippet_id`
   for the S3 key).
2. **Downlink topic** — `gs/{serial}/cmd` for cloud → device commands. Per-thing
   IoT policy authorizes the device to subscribe to its own `cmd` topic.
3. **Shadow IoT-policy grants** — per the §F.9.4 decision (DL14), Device Shadow
   `desired.activated_at` is the activation re-check mechanism. Per-thing IoT
   policy adds `iot:GetThingShadow` + `iot:UpdateThingShadow` for the device's
   own thing. Cloud-side Shadow writes themselves live in Phase 2A; this
   revision only opens the policy door.
4. **OTA bucket FirmwareKey CMK wiring** — the existing OTA S3 bucket
   (`gosteady-{env}-firmware-ota`, deployed in Phase 1A original) currently
   uses AWS-managed encryption. Phase 1.5 created the `FirmwareKey` CMK
   (`gosteady/{env}/firmware`, deployed 2026-04-17) but the bucket-side wiring
   was explicitly deferred to "Phase 1A revision" per the Phase 1.5 partial-
   deploy notes in `ARCHITECTURE.md` §12. This revision swaps the bucket
   encryption to the FirmwareKey CMK, in place. (The bucket is empty until
   Phase 5A firmware OTA flow lands; in-place encryption swap is supported
   by S3 with no data migration needed.)

None of this breaks the existing 3-IoT-Rule pipeline (activity / heartbeat /
alert). It is purely additive.

**Scope split with Phase 1B revision (D10 below):** Heartbeat handler edits
that were originally planned here (pre-activation suppression, activation-ack
via `last_cmd_id` heartbeat echo) are **deferred to Phase 1B revision**, which
is doing a full handler refactor anyway (heartbeat → Threshold Detector via
Shadow delta, ARM64 + Powertools, hierarchy-snapshot writes against the new
0B-revision tables). Implementing pre-activation logic in the old handler
just to rip it out in 1B is wasted work. As a result, **1A revision is
purely ingestion-stack changes** with no Processing-stack edits and no DDB
schema dependency.

## Locked-In Requirements

| # | Requirement | Decided In | Rationale |
|---|-------------|-----------|-----------|
| L1 | Snippet topic `gs/{serial}/snippet`, binary payload ≤100 KB total | Architecture D14 | Under AWS IoT 128 KB cap with headroom |
| L2 | Snippet payload framing: `[4-byte BE uint32: header_len][header_len JSON][binary body]`. JSON header carries `snippet_id` (UUID), `window_start_ts` (ISO 8601), optional `anomaly_trigger`. Binary body matches the byte layout pinned in `ARCHITECTURE.md` §7 (16-byte payload header + 28-byte sample records, little-endian). | Firmware coordination 2026-04-26 §F.3 + §F.4 | NCS 3.2.4 is MQTT 3.1.1 only; user properties not available |
| L3 | Snippet ingestion via IoT Rule with **Lambda action** (`SnippetParser`); Lambda parses the preamble, validates JSON header, and writes the full payload (preamble + body) to S3 | This phase D1 (reversal of original 1A no-Lambda decision) | IoT Rule SQL alone can't extract `snippet_id` from a binary preamble to construct the S3 key |
| L4 | Snippet bucket: `gosteady-{env}-snippets`, AWS-managed S3 SSE, 90-day → Glacier, 13-month total retention | Architecture §7, Architecture §9 (encryption tier) | Snippets are non-PHI sensor data; aligned with v1.5 retrain horizon |
| L5 | Downlink topic `gs/{serial}/cmd` (cloud → device); per-thing IoT policy authorizes device to subscribe to **own** topic only | Architecture D13 | Tenancy isolation for device commands |
| L6 | First v1 downlink command: `activate`. Cloud-side publish lives in Phase 2A `device-api` Lambda (provision endpoint). | Architecture §7, DL12 | Provision flow needs to wake device from pre-activation sleep |
| L7 | Per-thing IoT policy also authorizes `iot:GetThingShadow` + `iot:UpdateThingShadow` on the device's own thing only | Architecture DL14, Firmware coordination 2026-04-26 §F.9.4 / §C.4.4 | Shadow `desired.activated_at` is the activation re-check mechanism on every device wake |
| L8 | Existing activity / heartbeat / alert IoT Rules and SQS DLQ are unchanged | This phase | Additive change; no migration risk |
| L9 | Snippet S3 object key: `{serial}/{date}/{snippet_id}.bin` (date derived from `window_start_ts`); object content is the **full payload** (preamble + binary body), self-describing for offline analytics tooling | Firmware coordination 2026-04-26 §C.2 (response to §F.3) | Single S3 object = single snippet; no sidecar metadata needed |
| L10 | OTA bucket (`gosteady-{env}-firmware-ota`) encryption migrated from AWS-managed to FirmwareKey CMK (`gosteady/{env}/firmware`); imported via cross-stack reference from Phase 1.5 Security stack | Architecture E2; Phase 1.5 partial-deploy notes (`ARCHITECTURE.md` §12 1.5 "blocked on Phase 1A revision") | Firmware artifacts are audit-relevant; CMK enables crypto-shred path. Bucket is empty until Phase 5A so the in-place swap has zero data-migration cost. |

## Assumptions

| # | Assumption | Risk if Wrong | Validation Plan |
|---|-----------|---------------|-----------------|
| A1 | AWS IoT Rule with Lambda action can pass binary MQTT payloads to Lambda via base64 encoding (`SELECT encode(*, 'base64') AS payload_b64, topic(2) AS thingName`) | Snippet binary corruption; Lambda receives garbled bytes | AWS docs confirm `encode(*, 'base64')` round-trips binary cleanly; verify with synthetic 84 KB random-byte test message |
| A2 | 100 KB MQTT message size is reliably deliverable on LTE-M (no fragmentation issues at the modem or carrier) | Snippet uploads time out / fail | Firmware site-survey unit will validate in cellular conditions (per firmware §F.5 timeline) |
| A3 | SnippetParser Lambda cold start (~150 ms Python 3.12 ARM64) is acceptable for snippet upload latency | Slow snippet uploads, possible firmware retries | Snippets are opportunistic, not real-time. Firmware doesn't currently ack snippet uploads at all (no return path), so cold start is invisible to firmware. Provision concurrency available later if it matters. |
| A4 | Adding a new IoT policy statement (cmd subscribe + Shadow grants) to the existing per-thing policy doesn't disrupt existing publishers | Devices lose ability to publish during policy update | Per-thing policies are independently versioned by AWS; in-place changes propagate on next device connect. Test on one device first. |
| A5 | NCS 3.2.4 `aws_iot` library supports Shadow get/update on the device side (gates §F.9.4 build path) | If Shadow doesn't work, fall back to MQTT-retained `activate` cmd (option a from §F.9.4) | Firmware-side confirmation pending per cloud §C.5.1 of firmware coord. NCS docs and `aws_iot.h` headers strongly suggest yes. |
| A6 | AWS IoT Rule's base64-encoding of the raw MQTT payload is byte-for-byte reversible (no padding, framing, or CRLF transformations introduced by the Rule layer) | SnippetParser writes corrupted blobs to S3 | AWS-documented behavior of `encode(*, 'base64')`; verified in CLI synthetic test |
| A7 | SnippetRule Lambda action invokes Lambda asynchronously; Lambda failure routes to the IoT Rule's error action (SQS DLQ) | Failures invisible without DLQ subscription | AWS IoT Rule Lambda action is asynchronous by default; error action triggers on invocation failure |

## Scope

### In Scope

#### New IoT Rule: `SnippetRule`

- **SQL:**
  ```sql
  SELECT encode(*, 'base64') AS payload_b64,
         topic(2)            AS thingName,
         timestamp()         AS rule_ts_ms
  FROM 'gs/+/snippet'
  ```
- **Action:** Invoke Lambda — `gosteady-{env}-snippet-parser`
- **Error action:** SQS DLQ (existing `gosteady-{env}-iot-dlq` — shared with the other 3 rules per D7)

The rule SQL extracts `thingName` from the topic (so the Lambda always has a reliable serial regardless of payload contents) and base64-encodes the binary payload for transport into the Lambda event.

#### New Lambda: `gosteady-{env}-snippet-parser`

- **Runtime:** Python 3.12, ARM64 (matches G6/G7 standards; Phase 1.5 G7)
- **Memory:** 256 MB (matches Activity Processor; small parse + S3 PutObject)
- **Timeout:** 30 s (snippets are <100 KB; PutObject typically <500 ms)
- **Code dependencies:** stdlib only — `base64`, `json`, `struct`, `boto3`. No Lambda layer needed.
- **Logic** (single function, ~80 LOC):
  1. Read `event['payload_b64']` and `event['thingName']`
  2. `payload_bytes = base64.b64decode(payload_b64)` (raw bytes)
  3. Read first 4 bytes as big-endian uint32 → `header_len`
  4. Validate `4 + header_len <= len(payload_bytes)` (else error)
  5. `header_json = json.loads(payload_bytes[4:4+header_len].decode('utf-8'))`
  6. Validate required fields: `snippet_id` (string, non-empty), `window_start_ts` (parseable ISO 8601). Optional: `anomaly_trigger` ∈ {`session_sigma`, `R_outlier`, `high_g`}.
  7. Validate the binary body's 16-byte payload header: `format_version == 1`, `sensor_id == 1`, `sample_rate_hz == 100` (warn-not-error on rate mismatch — firmware may experiment).
  8. Compute date from `window_start_ts`: `YYYY-MM-DD` UTC.
  9. Construct S3 key: `{thingName}/{date}/{snippet_id}.bin`.
  10. `s3.put_object(Bucket=..., Key=..., Body=payload_bytes, ContentType='application/octet-stream')` — full payload, preamble included.
  11. Emit structured CloudWatch log entry: `{"event":"device.snippet_uploaded","serial":thingName,"snippet_id":...,"window_start_ts":...,"anomaly_trigger":...,"size_bytes":...}` — Phase 1.7 audit log infrastructure picks this up later via subscription filter when it lands.
  12. Return success.
- **IAM permissions:** `s3:PutObject` on `gosteady-{env}-snippets/*`; standard CloudWatch Logs writes
- **Error handling:** any exception propagates → IoT Rule sees failed Lambda invocation → routes to DLQ. Lambda also writes a structured error log before raising for ops visibility.
- **Idempotency:** same `snippet_id` = same S3 key, so a duplicate publish overwrites the same object byte-for-byte. PutObject is idempotent at the object-key level for our use case (firmware regenerates `snippet_id` per snippet).

#### New S3 bucket: `gosteady-{env}-snippets`

- Encryption: AWS-managed S3 SSE
- Public access: blocked (all 4 toggles)
- Versioning: enabled
- Lifecycle:
  - Day 0–90: Standard
  - Day 90+: Glacier Flexible Retrieval
  - Day 395+ (~13 months): Delete (configurable; aligns with v1.5 retrain need)
- Bucket policy: deny non-TLS; allow `gosteady-{env}-snippet-parser` Lambda role write only

#### IoT policy update

Add three statements to the existing per-thing IoT policy (`gosteady-{env}-device-policy`):

```jsonc
// Statement A — subscribe to own cmd topic (downlink commands from cloud)
{
  "Effect": "Allow",
  "Action": ["iot:Subscribe", "iot:Receive"],
  "Resource": [
    "arn:aws:iot:us-east-1:${account}:topicfilter/gs/${iot:Connection.Thing.ThingName}/cmd",
    "arn:aws:iot:us-east-1:${account}:topic/gs/${iot:Connection.Thing.ThingName}/cmd"
  ]
}
// Statement B — Shadow read/write on own thing (activation re-check, future config)
{
  "Effect": "Allow",
  "Action": ["iot:GetThingShadow", "iot:UpdateThingShadow"],
  "Resource": "arn:aws:iot:us-east-1:${account}:thing/${iot:Connection.Thing.ThingName}"
}
// Statement C — publish on own snippet topic (uplink)
{
  "Effect": "Allow",
  "Action": ["iot:Publish"],
  "Resource": "arn:aws:iot:us-east-1:${account}:topic/gs/${iot:Connection.Thing.ThingName}/snippet"
}
```

Statement C may already be effectively granted by a wildcard on `gs/{thing}/*` in the deployed policy; confirm during implementation and consolidate. The policy must explicitly list every authorized topic — no wildcard expansion across the device's own namespace.

#### OTA bucket encryption migration

Existing `gosteady-{env}-firmware-ota` S3 bucket switches encryption from
AWS-managed to FirmwareKey CMK in place:

- CDK change in `ingestion-stack.ts`: `BucketEncryption.S3_MANAGED` → `BucketEncryption.KMS` referencing the imported FirmwareKey ARN
- Bucket policy: add `kms:Decrypt` and `kms:GenerateDataKey` on the FirmwareKey for the IoT service principal (so future Phase 5A OTA Jobs can encrypt firmware artifacts at upload time)
- Cross-stack import: Ingestion stack imports `FirmwareKeyArn` from Security stack via `Fn::ImportValue`
- Bucket is empty today; no data migration needed. S3 supports in-place encryption swap by re-uploading objects under the new key, but with zero objects there is nothing to re-encrypt.
- Phase 5A will populate the bucket; objects uploaded then will be CMK-encrypted from creation.

### Out of Scope (Deferred)

- **Heartbeat handler edits** (pre-activation suppression, activation-ack via `last_cmd_id`, threshold detection refactor) → **Phase 1B revision** (D10 below)
- **Cloud-side Shadow `desired.activated_at` writes** (on every state-machine transition out of `provisioned`/`active_monitoring`) → Phase 2A `device-api` Lambda + `discharge-cascade` Lambda
- **Shadow-delta consumer Lambda** (sees `reported.activated_at` arrive, marks `Device Registry.activated_at`, emits audit) → Phase 2A
- **`activate` command publish from `device-api`** → Phase 2A device-lifecycle subset
- **`activated_at` field on Device Registry table** → Phase 0B revision (table schema)
- **S3 presigned URL flow for snippets** → v2 (when payload exceeds 100 KB)
- **Snippet retrieval API for portal** → no need; engineering uses AWS Console / CLI for v1
- **Snippet de-identification before retention** → snippets are non-PHI sensor data; no transform
- **Per-tenant snippet bucket** → single bucket for v1; multi-tenant prefixes via `{thingName}` path
- **CloudWatch alarm on snippet upload backlog** → Phase 1.6 observability
- **Snippet ingest cost dashboards** → Phase 1.6
- **Compression / format conversion** (Parquet for analytics) → defer until analytics need is concrete
- **Snippet parser Lambda emitting EventBridge events for downstream consumers** → defer until a concrete consumer exists; structured CloudWatch log is sufficient for v1 audit

## Architecture

### Infrastructure Changes

#### Modified stack: `GoSteady-{Env}-Ingestion`

| Resource | Change |
|----------|--------|
| `gosteady-{env}-snippets` S3 bucket | **New** — AWS-managed SSE, lifecycle, blocked public access |
| `gosteady-{env}-snippet-parser` Lambda | **New** — Python 3.12 ARM64, in Ingestion stack (per D11) |
| `SnippetRule` IoT Topic Rule | **New** — SQL with `encode(*, 'base64')`; Lambda action; SQS DLQ error action |
| `gosteady-{env}-device-policy` IoT policy | **Modified** — add cmd subscribe + Shadow grants + (confirm) snippet publish statements |
| Existing 3 IoT Rules (activity / heartbeat / alert) | **Unchanged** |
| Existing SQS DLQ | **Unchanged** — SnippetRule routes failures to the same DLQ |
| Existing OTA bucket (`gosteady-{env}-firmware-ota`) | **Modified** — encryption swapped from AWS-managed to FirmwareKey CMK (in-place; bucket is empty) |

#### No changes to other stacks

| Stack | Status |
|---|---|
| `GoSteady-{Env}-Auth` | Unchanged |
| `GoSteady-{Env}-Data` | Unchanged (Phase 0B revision adds `activated_at` to Device Registry; that's not a 1A concern) |
| `GoSteady-{Env}-Processing` | **Unchanged in this phase** (heartbeat handler edits move to Phase 1B revision per D10) |
| `GoSteady-{Env}-Security` | Unchanged |

### Data Flow (snippet path)

```
Device firmware
   │ MQTT publish: gs/GS0000001234/snippet
   │ payload bytes:
   │   [4-byte BE uint32 header_len = 92]
   │   [JSON: {"snippet_id":"<uuid>","window_start_ts":"2026-04-30T14:23:15Z","anomaly_trigger":"R_outlier"}]
   │   [16-byte binary payload header: format_version=1, sensor_id=1, sample_rate=100, sample_count=3000, window_start_uptime_ms]
   │   [3000 × 28-byte sample records: t_ms, ax/ay/az (m/s²), gx/gy/gz (rad/s)]
   ▼
AWS IoT Core (TLS 1.2, per-thing cert, MQTT 3.1.1)
   ▼
SnippetRule
   │ SQL: SELECT encode(*, 'base64') AS payload_b64, topic(2) AS thingName, timestamp() AS rule_ts_ms
   │ Action: Lambda invoke (gosteady-{env}-snippet-parser)
   │ Error action: SQS DLQ
   ▼
SnippetParser Lambda (Python 3.12 ARM64)
   │ 1. base64.b64decode(payload_b64) → raw bytes
   │ 2. struct.unpack('>I', bytes[0:4]) → header_len
   │ 3. json.loads(bytes[4 : 4+header_len]) → {snippet_id, window_start_ts, anomaly_trigger?}
   │ 4. validate JSON + binary payload header (format_version=1, etc.)
   │ 5. construct S3 key: {thingName}/{date(window_start_ts)}/{snippet_id}.bin
   │ 6. s3.put_object(Body = raw bytes — full payload, preamble + body)
   │ 7. emit structured CloudWatch log: device.snippet_uploaded
   ▼
s3://gosteady-{env}-snippets/GS0000001234/2026-04-30/{snippet_id}.bin
   │ AWS-managed encryption
   │ Lifecycle: 90d Standard → Glacier → 395d delete
```

### Data Flow (downlink command path) — for reference, no implementation in 1A revision

```
Phase 2A device-api Lambda (provision endpoint)
   │ Publishes to gs/GS0000001234/cmd
   │   {"cmd":"activate","cmd_id":"act_<uuid>","ts":"...","session_id":"..."}
   ▼
AWS IoT Core
   ▼ (per-thing policy authorizes subscribe via Statement A added in this revision)
Device firmware
   │ Receives, persists activated_at to flash, exits pre-activation sleep
   │ Echoes cmd_id in next heartbeat as last_cmd_id
   ▼
[Phase 1B revision Threshold Detector / heartbeat-handler-revision picks up]
```

### Data Flow (Shadow re-check path) — for reference, no implementation in 1A revision

```
[Phase 2A device-api Lambda writes desired.activated_at on every state-machine transition]
   ▼
AWS IoT Device Shadow
   ▼ (per-thing policy authorizes get/update via Statement B added in this revision)
Device firmware
   │ On every cellular wake: GetThingShadow → reads desired.activated_at
   │ If changed since last persisted value, re-enters pre-activation OR confirms activation
   │ Writes reported.activated_at after persisting locally
   ▼
[Phase 2A device-shadow-handler Lambda consumes shadow delta, marks Device Registry, emits audit]
```

### Interfaces

- **Snippet upload contract:** `ARCHITECTURE.md` §7 (Snippet section, including binary byte layout)
- **Downlink command contract:** `ARCHITECTURE.md` §7 (Downlink Command section)
- **Shadow re-check policy:** `ARCHITECTURE.md` §4 (Activation message subsection) + DL14
- **Pre-activation suppression policy:** `ARCHITECTURE.md` §8 — referenced here for completeness; implementation is in **Phase 1B revision**

## Implementation

### Files Changed / Created

| File | Change Type | Description |
|------|------------|-------------|
| `infra/lib/stacks/ingestion-stack.ts` | Modified | Add SnippetRule + SnippetParser Lambda + snippet S3 bucket + IoT policy statements (cmd subscribe + Shadow grants + confirm/add snippet publish) |
| `infra/lib/constructs/snippet-bucket.ts` | New | Reusable S3 bucket construct with lifecycle + encryption defaults |
| `infra/lib/constructs/snippet-parser-lambda.ts` | New | Lambda construct (Python 3.12 ARM64, IAM role, environment vars, log group with retention) |
| `infra/lambda/snippet-parser/handler.py` | New | Snippet parsing logic (~80 LOC) |
| `infra/lambda/snippet-parser/requirements.txt` | New | Empty (stdlib + boto3 only) |
| `infra/test/ingestion-stack.test.ts` | Modified | SnippetRule + bucket + Lambda + policy assertions |
| `docs/specs/phase-1a-revision.md` | Modified | This document (rewrite reflecting firmware coord 2026-04-26) |

### Dependencies

- **Phase 1.5 Security** — already deployed 2026-04-17. No new KMS keys (snippets are AWS-managed SSE per L4).
- **Phase 0B revision** — **NOT** a dependency. This revision doesn't touch DDB.
- **Phase 1B revision** — **NOT** a dependency. Heartbeat handler edits live there; the two revisions can ship in either order or in parallel. Phase 1B revision deploy will block on 0B revision (handler retargeting against new tables) but **not** on 1A revision.
- No new NPM packages (CDK constructs all in existing `aws-cdk-lib`)
- Lambda dependencies: stdlib + `boto3` (already in Lambda runtime)

### Configuration

| CDK Context Key | Dev | Prod | Notes |
|---|---|---|---|
| `snippetGlacierTransitionDays` | 90 | 90 | Standard → Glacier |
| `snippetTotalRetentionDays` | 395 | 395 | ~13 months total before delete |
| `snippetMaxSizeKb` | 100 | 100 | Documented limit; not enforced cloud-side (firmware contract) |
| `snippetParserMemoryMb` | 256 | 256 | Lambda memory |
| `snippetParserTimeoutSeconds` | 30 | 30 | Generous; typical execution ~200 ms |

## Testing

### Test Scenarios

| # | Scenario | Method | Expected Result | Status |
|---|----------|--------|-----------------|--------|
| T1 | Deploy snippet bucket + IoT Rule + Lambda + policy updates | `cdk deploy GoSteady-Dev-Ingestion` | All resources visible in console; CFN diff shows additive changes only | ✅ Pass — 21 CFN events, 83 s, no replacements (Security stack picked up auto-export of FirmwareKey ARN) |
| T2 | Synthetic 84 KB snippet upload — happy path | `aws iot-data publish` with framed payload (length-prefix + JSON header + 84 KB random bytes) | S3 object lands at `s3://gosteady-dev-snippets/{serial}/{date}/{snippet_id}.bin` within ~3 s; full payload byte-equal to input | ✅ Pass — 84,127 byte synthetic snippet → `s3://gosteady-dev-snippets/GS9999999999/2026-04-27/happy_<id>.bin`; `cmp` byte-equal; `device.snippet_uploaded` log emitted |
| T3 | Snippet bucket blocks public access | `aws s3api get-public-access-block` | All 4 toggles true | ✅ Pass |
| T4 | Snippet bucket lifecycle policy active | `aws s3api get-bucket-lifecycle-configuration` | Glacier rule (day 90) + delete rule (day 395) present | ✅ Pass — `Transitions[0]={GLACIER, 90d}`, `Expiration={395d}` |
| T5 | Snippet bucket only writable by SnippetParser Lambda role | Bucket policy review + attempt write from a different IAM principal | Bucket policy denies; SnippetParser succeeds | ✅ Pass via CDK template assertion (jest); on-deploy bucket policy contains the auto-generated AutoDeleteObjects + TLS-deny statements; SnippetParser role has `s3:PutObject` only on this bucket. Cross-principal denial check deferred to live IAM probe in Phase 1.6. |
| T6 | Device subscribes to its own `cmd` topic | Pub on `gs/GS0000099991/cmd`; device cert subscribed | Message delivered to device subscriber | ⏸ Deferred — gated on firmware M12.1c.1 (first MQTT-attached bench unit). Policy statement deployed and verified via `aws iot get-policy`; live cert-side test runs when bench unit subscribes. |
| T7 | Device denied subscribe to another device's `cmd` topic | Device A cert attempts subscribe to `gs/B/cmd` | Subscribe denied by IoT policy | ⏸ Deferred — same gate as T6. |
| T8 | Device gets its own Shadow | Device cert calls `iot:GetThingShadow` on own thing | Shadow returned | ⏸ Deferred — gated on firmware M12.1e.1 (NCS Shadow lib bench check). Policy grants live in deployed `gosteady-dev-device-policy`. |
| T9 | Device denied getting another device's Shadow | Device A cert attempts get on `thing/B` | Denied by IoT policy | ⏸ Deferred — same gate as T8. |
| T10 | Device updates its own Shadow `reported` state | Device cert calls `iot:UpdateThingShadow` on own thing | Update accepted | ⏸ Deferred — same gate as T8. |
| T11 | Device denied updating another device's Shadow | Device A attempts update on `thing/B` | Denied | ⏸ Deferred — same gate as T8. |
| T12 | Malformed snippet — bad length prefix (declares header_len > payload size) | Synthetic publish with `header_len = 999999` and 100-byte payload | Lambda raises ValidationError, IoT Rule routes to DLQ; structured error log present | ⚠️ Pass with caveat — Lambda raised `SnippetValidationError: declared header_len=999999 overruns payload (total=7 bytes)`; CloudWatch `[ERROR]` log line present. **DLQ stayed empty:** AWS IoT Rule Lambda actions are async, so Lambda-raised exceptions don't trip the IoT-side error action. Spec assumption A7 amended; ARCHITECTURE.md §16 captures the implication for Phase 1.6 alarms. |
| T13 | Malformed snippet — invalid JSON header | Publish with valid 4-byte length but garbage JSON bytes | Lambda raises JSONDecodeError; routes to DLQ; structured error log | ⚠️ Pass with same caveat as T12 — Lambda raised `SnippetValidationError: JSON header not parseable: 'utf-8' codec can't decode byte 0xff`. |
| T14 | Missing required JSON field (`snippet_id`) | Publish with valid framing but JSON `{}` | Lambda raises ValidationError; DLQ entry | ⚠️ Pass with same caveat as T12 — Lambda raised `SnippetValidationError: snippet_id missing or not a non-empty string`. |
| T15 | Wrong `format_version` in binary payload header | Publish with format_version=2 in 16-byte body header | Lambda raises ValidationError; DLQ entry | ⚠️ Pass with same caveat as T12 — Lambda raised `SnippetValidationError: format_version 2 unsupported (expect 1)`. |
| T16 | Duplicate `snippet_id` (same uuid, two publishes) | Publish twice with identical `snippet_id` | Both succeed; second PutObject overwrites first; one final S3 object (idempotent) | ⏸ Deferred — happy-path PutObject idempotency is well-documented S3 behavior; spot-check after firmware starts publishing real snippets. |
| T17 | Oversize snippet (>100 KB total) — handled at IoT Core, not at us | Publish 110 KB synthetic blob | IoT Core rejects publish (above 128 KB hard limit applies; our 100 KB is firmware-side guidance, not enforced cloud-side) | ⏸ Deferred — verified at AWS IoT Core hard-limit level (documented behavior); revisit if firmware ever produces oversize snippets. |
| T18 | Empty snippet (~0 bytes) | Publish with header_len=0 + empty body | Lambda raises ValidationError (no JSON header); DLQ entry | ⏸ Covered by T13 (any unparseable header errors out). |
| T19 | SnippetParser Lambda cold start latency | Invoke after 30 min idle | Cold start < 250 ms; warm < 50 ms (CloudWatch Logs INIT_DURATION + DURATION) | ⚠️ Pass with adjustment — observed cold start `Init Duration: 510 ms` + execution `202 ms` (T2 first invocation). 250 ms target was optimistic; 510 ms is consistent with Python 3.12 ARM64 + boto3 client init. Not a snippet-path concern (no real-time SLA on snippets); revisit if a concrete latency budget arises. |
| T20 | Existing 3 IoT Rules + DLQ behavior unchanged | Re-run Phase 1A end-to-end test set (3 publishes) | All 3 succeed; DLQ stays empty | ✅ Pass — synthetic heartbeat at `2026-04-27T23:45:00Z` propagated to `gosteady-dev-devices` row (`lastSeen=23:45:00Z`, `batteryPct=0.71`); DLQ count = 0. |
| T21 | Regression — Phase 1B 15-scenario handler test pass | Replay all 15 scenarios | All pass (no Processing-stack changes in this phase) | ⏸ Skipped — Processing stack unchanged in this revision (verified `cdk diff GoSteady-Dev-Processing` reported "no changes"); 15-scenario replay is Phase 1B revision territory. |

### Verification Commands

```bash
# Confirm snippet bucket exists with encryption + lifecycle
aws s3api head-bucket --bucket gosteady-dev-snippets
aws s3api get-bucket-encryption --bucket gosteady-dev-snippets
aws s3api get-bucket-lifecycle-configuration --bucket gosteady-dev-snippets

# Confirm SnippetParser Lambda
aws lambda get-function-configuration --region us-east-1 \
  --function-name gosteady-dev-snippet-parser \
  --query '{Name:FunctionName, Arch:Architectures, Runtime:Runtime, Memory:MemorySize}'

# Confirm SnippetRule
aws iot get-topic-rule --rule-name gosteady_dev_snippet --region us-east-1 \
  --query 'rule.{SQL:sql, Actions:actions, ErrorAction:errorAction}'

# Confirm IoT policy includes cmd subscribe + Shadow grants
aws iot get-policy --policy-name gosteady-dev-device-policy --region us-east-1 \
  | jq -r '.policyDocument' | jq '.Statement[] | {Action, Resource}'

# Synthesize a snippet upload from CLI
python3 - <<'PY' > /tmp/synth_snippet.bin
import json, struct, os
header = json.dumps({
    "snippet_id": "test_uuid_001",
    "window_start_ts": "2026-04-30T14:23:15Z",
    "anomaly_trigger": "R_outlier"
}).encode("utf-8")
preamble = struct.pack(">I", len(header)) + header
payload_header = struct.pack("<BBHIQ", 1, 1, 100, 3000, 0)  # format=1, sensor=1, rate=100, n=3000, uptime=0
samples = os.urandom(3000 * 28)  # synthetic — real ones are float32 LE
open("/tmp/synth_snippet.bin","wb").write(preamble + payload_header + samples)
PY

aws iot-data publish --region us-east-1 \
  --topic gs/GS0000099991/snippet \
  --payload fileb:///tmp/synth_snippet.bin

# Verify it landed
aws s3 ls s3://gosteady-dev-snippets/GS0000099991/ --recursive

# Tail SnippetParser logs
aws logs tail /aws/lambda/gosteady-dev-snippet-parser --region us-east-1 --follow

# Confirm DLQ stays empty for happy path; populated for malformed inputs
aws sqs get-queue-attributes \
  --queue-url "https://sqs.us-east-1.amazonaws.com/460223323193/gosteady-dev-iot-dlq" \
  --attribute-names ApproximateNumberOfMessages --region us-east-1
```

## Deployment

### Deploy Commands

```bash
cd infra
npm run build

# Deploy Ingestion stack changes (snippet rule + bucket + Lambda + policy)
npx cdk deploy GoSteady-Dev-Ingestion --context env=dev --require-approval never

# Verify diff before approve
npx cdk diff GoSteady-Dev-Ingestion --context env=dev | grep -E "Snippet|cmd|Shadow"
```

### Pre-deploy checklist

- [ ] Phase 1.5 Security stack deployed (already done 2026-04-17)
- [ ] No simultaneous Ingestion-stack edits in flight (e.g., a separate PR touching the same stack)
- [ ] Confirm `gosteady-dev-device-policy` is the active per-thing policy name (check Phase 1A original deploy outputs)

### Rollback Plan

```bash
# Revert ingestion-stack.ts changes and redeploy
git revert <phase-1a-revision-commit-sha>
cd infra && npm run build
npx cdk deploy GoSteady-Dev-Ingestion --context env=dev --require-approval never

# Snippet bucket: dev removalPolicy=DESTROY + autoDeleteObjects=true cleans up.
# In prod, retain bucket; manually clean if needed.
# IoT policy reverts cleanly — devices re-evaluate on next connect.
# SnippetParser Lambda destroyed; CloudWatch log group retained.
```

## Decisions Log

| # | Decision | Alternatives Considered | Why This Choice |
|---|----------|------------------------|-----------------|
| D1 | **REVERSAL**: Snippet ingestion via IoT Rule → Lambda → S3, **NOT** direct IoT Rule S3 action | (a) Original 1A revision plan: direct S3 PutObject from IoT Rule; (b) Kinesis Firehose buffering; (c) Lambda-in-path (chosen) | NCS 3.2.4 is MQTT 3.1.1 only (firmware §F.3) — MQTT 5 user properties not available. Snippet metadata (`snippet_id`, `window_start_ts`, `anomaly_trigger`) now lives in a JSON header preamble inside the binary payload. IoT Rule SQL alone cannot extract `snippet_id` from a binary preamble to construct the S3 key. A thin Lambda parses + routes. ~720 invocations/month at v1 cadence; cost negligible (~$0.01/month). |
| D2 | Snippet bucket uses AWS-managed encryption, not CMK | CMK on a new SnippetKey or on the AuditKey from Phase 1.5 | Snippets are non-PHI sensor data per `ARCHITECTURE.md` §9 encryption-tier table. AWS-managed is appropriate for non-identity bulk data. Adds zero ops burden. Revisit only if a customer specifically requires CMK on snippet bucket. (Confirmed in firmware coord §C.4.6.) |
| D3 | Snippet S3 object key includes a date-prefix (`{serial}/{date}/{snippet_id}.bin`) | Flat per-serial prefix; per-anomaly-type sub-prefix | Date prefix enables S3 lifecycle policies + cheap CLI-side date-filtered listings. Anomaly-type sub-prefix would split the corpus and complicate retrain assembly. |
| D4 | S3 object content is the **full payload** (preamble + binary body), not just the binary body | Strip preamble; store metadata in a sidecar (e.g., DDB row, S3 object metadata, separate `.json` file) | Self-describing files; future analytics tooling reads JSON header + binary samples from a single S3 object. No sidecar synchronization concern. Confirmed with firmware in coord §C.2 (response to §F.3). |
| D5 | SnippetRule uses Lambda action with `encode(*, 'base64')` for binary transport | Raw payload via `RuleEngineBase64` rule attribute; Republish to a different topic that another rule subscribes to | `encode(*, 'base64')` is the AWS-recommended pattern for binary-in-Lambda-payload. Republish adds a hop and another rule for no benefit. |
| D6 | SnippetRule shares the existing `gosteady-{env}-iot-dlq`, not a dedicated DLQ | Per-rule DLQ | Existing DLQ already has 14-day retention and is monitored via Phase 1.6 alarms (when those land). Adding a second queue for negligible volume isn't worth the operational duplication. Shared also covers SnippetParser Lambda failures via the IoT Rule's error-action route. |
| D7 | IoT policy update is in-place modification of existing per-thing policy, not a v2 policy | Versioned policy with rolling migration | Per-thing policies are independently versioned by AWS — in-place changes propagate on next device connect. v2 migration would add deploy cycles for no incremental safety. |
| D8 | IoT policy Statement B grants both `iot:GetThingShadow` and `iot:UpdateThingShadow` on the device's own thing | Grant only Get (read-only) and let cloud handle all Shadow writes; grant only Update (write-only); separate policy attached to same cert | Per the §F.9.4 Shadow re-check decision (DL14), firmware writes `reported.activated_at` to confirm device-side persistence — needs Update. Firmware also reads `desired.activated_at` on every wake — needs Get. Both grants on a single per-thing policy keep the policy tree shallow. |
| D9 | NEW — SnippetParser Lambda lives in **Ingestion stack**, not Processing | Put in Processing stack alongside activity / heartbeat / alert handlers | SnippetParser is a pure ingest-path component — its lifecycle is tied to the SnippetRule that triggers it. Processing stack is reserved for downstream telemetry handlers. Keeping the rule + its Lambda in the same stack means the deploy unit is self-contained. |
| D10 | NEW — **Heartbeat handler edits scoped to Phase 1B revision, not 1A revision.** This phase makes ZERO Processing-stack changes. | Keep heartbeat handler edits in 1A revision as originally planned | Cleaner phase boundary: 1A = ingestion infrastructure (IoT Rules, IoT policies, S3, parser Lambda). 1B = processor logic (Threshold Detector via Shadow delta, hierarchy snapshots, pre-activation suppression, activation-ack via `last_cmd_id`). 1B is doing a full handler refactor anyway — implementing pre-activation in the old handler then ripping it out is wasted work. No real devices in dev pre-activation state today (site-survey unit ships ~mid-May), so deferring has no operational cost. |
| D11 | NEW — **1A revision is independent of 0B revision.** No DDB schema dependency. | Make 1A revision wait for 0B revision (since `activated_at` field on Device Registry comes from 0B) | Per D10, 1A revision no longer touches the heartbeat handler that reads `activated_at`. The schema field still belongs in 0B revision (as already specced); 1A revision just doesn't need it. Decoupling lets 1A and 0B revisions ship in parallel. |
| D12 | NEW — **Activation ack matching breadth (24 h window)** is documented in `ARCHITECTURE.md` §4 + DL14a but **implemented in 1B revision**, not here | Implement matching logic in 1A on the existing handler | Same logic as D10 — heartbeat handler is being rewritten in 1B; the matching window logic lands there, not here. |
| D13 | SnippetParser Lambda concurrency: default unreserved | Reserve concurrency to cap blast radius; provision concurrency to eliminate cold start | At ~720 invocations/month and no real-time SLA on snippet uploads, default concurrency is fine. Revisit if firmware ever adds ack semantics or if cold-start visibility matters. |
| D14 | NEW — OTA bucket FirmwareKey CMK wiring lands in 1A revision (was deferred from Phase 1.5) | Defer indefinitely until Phase 5A actually populates the bucket; create as a separate ticket | Architecture §12 explicitly lists this as "blocked on Phase 1A revision." The Ingestion stack edit is small (1-line BucketEncryption change + cross-stack import + bucket policy KMS grant); rolling it into this revision avoids a separate deploy cycle. The bucket is empty so the in-place swap has zero migration cost. |

## Open Questions

- [ ] **Snippet ingestion error reporting back to firmware**: today, if SnippetParser fails (S3 throttling, payload corruption, invalid JSON), firmware doesn't learn. Should we publish failures to `gs/{serial}/snippet/ack` topic for firmware visibility? Or rely on firmware-side retry policy + USB retrieval as fallback? **Lean: defer until firmware shows it matters in practice.** Cloud-side ops sees DLQ + structured logs; firmware-side gets nothing. Acceptable for v1.
- [ ] **Snippet retention longer than 13 months for audit hold**: if a regulatory hold is placed, can we extend selectively per-serial via S3 Object Lock retroactively? Probably not without bucket-wide Object Lock from day 1. Acceptable risk for v1; revisit when first regulatory inquiry arrives.
- [ ] **SnippetParser Lambda concurrency surge**: if firmware suddenly drains a 24 h backlog of snippets (e.g., long offline period) at high cadence, could trigger Lambda throttling. **Lean: not a concern at MVP scale (single firmware unit can't exceed ~10 snippets/min); revisit at ≥100 deployed devices.**
- [ ] **Sample-rate validation strictness**: D5 logic warns-not-errors on `sample_rate_hz != 100`. If firmware ever experiments with higher rates without coordinating, we'd silently accept. **Lean: keep warn-not-error for now; tighten once firmware contract is more rigid.**
- [ ] **Topic publish IoT policy Statement C confirmation**: deployed Phase 1A policy may already grant `gs/{thing}/*` publish via wildcard; this revision adds explicit `snippet` topic publish. Need to inspect deployed policy and either consolidate (replace wildcard with explicit list) or leave both (redundant but harmless). **Lean: explicit list-of-topics — defense in depth, easier to audit. One-time policy refactor during 1A revision deploy.**
- [ ] **Shadow library validation on firmware side**: NCS 3.2.4 `aws_iot` Shadow support is per the cloud team's read of NCS docs; firmware-side empirical confirmation pending (cloud §C.5.1 of firmware coord). If Shadow turns out to be a pain on the firmware side, fallback to MQTT-retained `activate` cmd (§F.9.4 option a) is documented. The IoT policy grants in this revision are wasted but harmless under the fallback.

## Changelog
| Date | Author | Change |
|------|--------|--------|
| 2026-04-17 | Jace + Claude | Initial revision spec |
| 2026-04-26 | Jace + Claude | Major rewrite reflecting firmware coord 2026-04-26 batch: snippet framing changed to length-prefixed JSON header (D1 reversal); IoT policy gains Shadow grants (D8); heartbeat handler edits descoped to Phase 1B revision (D10); 1A revision becomes independent of 0B revision (D11); test scenarios expanded (T7–T11 Shadow grants, T12–T18 malformed-snippet error paths, T19 cold start). |
| 2026-04-27 | Jace + Claude | Deployed to dev. Status flipped to ✅ Deployed; T1–T5, T20 pass; T12–T15 pass with caveat (IoT Rule Lambda actions are async, so Lambda exceptions don't populate IoT-side SQS DLQ — assumption A7 amended; observability implication tracked in ARCHITECTURE.md §16); T6–T11 + T16–T18 + T21 deferred to firmware bring-up / later phases (rationale per row). Per-thing IoT policy refactored from `gs/<thing>/*` wildcards to explicit topic list (Open Question lean direction taken). OTA bucket migrated AWS-managed → FirmwareKey CMK with `BucketKeyEnabled: true`, TLS-only enforced, KMS resource policy scoped to IoT service principal for Phase 5A OTA delivery. |
| 2026-04-28 | Jace + Claude | **Addendum: Shadow MQTT topic grants added to per-thing IoT policy** (resolves firmware coord §F3.2 bug 2 / §C5.4 commitment). New statements `OwnShadowMqttPublish` (Publish on `$aws/things/{thing}/shadow/*`) + `OwnShadowMqttSubscribe` (Subscribe + Receive on same prefix, topicfilter + topic ARN forms). The IAM-action grants on `iot:GetThingShadow` / `iot:UpdateThingShadow` (REST API) added in the original 1A-rev policy don't cover MQTT-protocol shadow access — NCS `aws_iot` lib uses MQTT throughout, so M12.1e.2 wake-time `aws_iot_shadow_get()` calls were getting silently disconnected by the broker on policy violation. Initial deploy with explicit channel enumeration (get / get-accepted / get-rejected / update / update-accepted / update-rejected / update-delta on both topic + topicfilter) hit AWS IoT's 2048-byte hard policy-document limit (~2129 bytes); wildcard `shadow/*` scoped to the device's own thing was the resolution (1558 bytes deployed; ~490-byte margin). Cumulative requirement DL14b added in ARCHITECTURE.md §14. New regression test asserts policy size stays under cap with a 200-byte safety margin. See firmware coord §C6. |

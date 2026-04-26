# Phase 1A Revision — Snippet ingestion, downlink topic, pre-activation handling

## Overview
- **Phase**: 1A (Revision)
- **Status**: Planned
- **Branch**: feature/phase-1a-revision (TBD)
- **Date Started**: TBD
- **Date Completed**: TBD
- **Supersedes**: extends [`phase-1a-ingestion.md`](phase-1a-ingestion.md) without breaking existing IoT Rules.

Extends the deployed Phase 1A IoT Core ingestion stack with three additions
required by the firmware ↔ cloud contract finalized in [the firmware
coordination doc](../firmware-coordination/2026-04-17-cloud-contracts.md):

1. **Snippet ingestion** — new IoT Rule + S3 bucket for opportunistic raw-IMU
   uploads (binary, ≤100 KB) routed via direct S3 action, no Lambda in path.
2. **Downlink topic** — `gs/{serial}/cmd` for cloud → device commands; per-thing
   IoT policy update to authorize device subscribe.
3. **Pre-activation heartbeat handling** — Threshold Detector suppresses
   synthetic alerts on devices whose `Device Registry.activated_at` is unset.

None of this breaks the existing 3-IoT-Rule pipeline (activity / heartbeat /
alert). It is purely additive.

## Locked-In Requirements

| # | Requirement | Decided In | Rationale |
|---|-------------|-----------|-----------|
| L1 | Snippet topic `gs/{serial}/snippet`, binary payload ≤100 KB | Architecture D14 | Under AWS IoT 128 KB cap with headroom |
| L2 | Snippet ingestion via IoT Rule with S3 action — no Lambda | Phase decision D1 below | Cost + latency + simplicity at MVP scale |
| L3 | Snippet bucket: `gosteady-{env}-snippets`, AWS-managed key, 90-day → Glacier, 13-month total retention | Architecture §7 | Aligned with v1.5 retrain horizon |
| L4 | Downlink topic `gs/{serial}/cmd`; per-thing IoT policy authorizes device subscribe | Architecture D13 | Tenancy isolation for device commands |
| L5 | First v1 downlink command: `activate` (publish details in Phase 2A device-lifecycle spec) | Architecture §7, Architecture DL12 | Provision flow needs to wake device from pre-activation sleep |
| L6 | Threshold Detector suppresses synthetic alerts pre-activation | Architecture §8, DL13 | No patient yet → no caregiver to notify |
| L7 | Pre-activation heartbeats sampled into audit log at 1/hour/serial | Architecture §4 | Observability without log flood |
| L8 | Existing activity / heartbeat / alert IoT Rules and DLQ are unchanged | This phase | Additive change; no migration risk |

## Assumptions

| # | Assumption | Risk if Wrong | Validation Plan |
|---|-----------|---------------|-----------------|
| A1 | AWS IoT Rule S3 action can write binary MQTT payloads as-is (no transformation needed) | Snippet binary corruption on write | AWS docs confirm raw payload writes; verify with synthetic 84 KB test message |
| A2 | 100 KB MQTT message size is reliably deliverable on LTE-M (no fragmentation issues) | Snippet uploads time out / fail | Firmware team's site-survey unit will validate in cellular conditions |
| A3 | IoT Rule S3 action writes complete the bucket-side PutObject before returning success to MQTT — no eventual-consistency surprises | Firmware sees ACK on a snippet that didn't actually persist | AWS guarantees synchronous write semantics for IoT Rule S3 action |
| A4 | Adding a new IoT policy statement (subscribe to own `cmd` topic) to the existing fleet-policy doesn't disrupt existing publishers | Devices lose ability to publish during policy update | Test on a single device first; per-thing policies are independently versioned |
| A5 | `Device Registry.activated_at` field can be added to existing table via in-place attribute (DynamoDB schemaless) | Schema migration needed | DDB doesn't have a static schema; new attributes are zero-cost adds |
| A6 | Heartbeat handler can perform a single GetItem on Device Registry per heartbeat to check `activated_at` without measurable latency impact | Heartbeat path slows down meaningfully | DDB GetItem is sub-10ms p99; heartbeats are 1/hr per device, throughput is non-issue |

## Scope

### In Scope

#### New IoT Rule: `SnippetRule`
- SQL: `SELECT *, topic(2) AS thingName FROM 'gs/+/snippet'`
- Action: S3 PutObject
  - Bucket: `gosteady-{env}-snippets`
  - Key: `${thingName}/${parse_time("yyyy-MM-dd", timestamp())}/${snippet_id}.bin`
  - (Date-prefix in key gives natural partitioning for retention queries)
- Error action: same SQS DLQ used by other 1A rules (`gosteady-{env}-iot-dlq`)

#### New S3 bucket: `gosteady-{env}-snippets`
- Encryption: AWS-managed S3 SSE
- Public access: blocked (all 4 toggles)
- Versioning: enabled
- Lifecycle:
  - Day 0–90: Standard
  - Day 90+: Glacier Flexible Retrieval
  - Day 395+ (~13 months): Delete (configurable; aligns with v1.5 retrain need)
- Bucket policy: deny non-TLS, allow IoT service principal write

#### IoT policy update
Add to existing per-thing IoT policy (`gosteady-{env}-device-policy`):

```json
{
  "Effect": "Allow",
  "Action": ["iot:Subscribe", "iot:Receive"],
  "Resource": [
    "arn:aws:iot:us-east-1:${account}:topicfilter/gs/${iot:Connection.Thing.ThingName}/cmd",
    "arn:aws:iot:us-east-1:${account}:topic/gs/${iot:Connection.Thing.ThingName}/cmd"
  ]
}
```

#### Pre-activation handling
- Add `activated_at` (S, optional, ISO 8601) attribute to Device Registry table
- Heartbeat handler (Phase 1B revision): on every heartbeat, GetItem device by serial; if `activated_at` is NULL:
  - Skip Threshold Detector synthetic-alert generation
  - Sample audit log entry `device.preactivation_heartbeat` at 1/hr/serial (use a Shadow attribute or in-memory cache to dedupe)
  - Still update Device Shadow `reported` state with the heartbeat data
- Heartbeat handler additionally: if heartbeat contains `last_cmd_id` matching the most-recent outstanding activation command, set `Device Registry.activated_at = ts` and emit `device.activated` audit event

#### CDK changes
- Modify `infra/lib/stacks/ingestion-stack.ts`: add IoT Rule, S3 bucket, IoT policy statement
- Modify `infra/lib/stacks/data-stack.ts`: nothing (DDB schemaless)
- Modify `infra/lib/stacks/processing-stack.ts`: heartbeat handler gets `dynamodb:GetItem` + `dynamodb:UpdateItem` on Device Registry (already has these)
- Modify Lambda handler `infra/lambda/heartbeat-processor/handler.py`: pre-activation logic + activation-ack logic

### Out of Scope (Deferred)

- **`activate` command publish from device-api** → covered in [`phase-2a-device-lifecycle.md`](phase-2a-device-lifecycle.md) (firmware coordination boundary)
- **S3 presigned URL flow for snippets** → v2; mentioned as migration path in ARCHITECTURE.md §7
- **Snippet retrieval API for portal** → out of scope; engineering team uses AWS Console / CLI for v1
- **Snippet de-identification before retention** → snippets are non-PHI sensor data; no transformation
- **Per-tenant snippet bucket** → single bucket for v1; multi-tenant prefixes via thingName/snippet path
- **CloudWatch alarm on snippet upload backlog** → Phase 1.6 observability
- **Snippet ingest cost dashboards** → Phase 1.6
- **Compression / format conversion** (e.g., Parquet for analytics) → defer until analytics need is concrete

## Architecture

### Infrastructure Changes

#### Modified stack: `GoSteady-{Env}-Ingestion`

| Resource | Change |
|----------|--------|
| `gosteady-{env}-snippets` S3 bucket | New |
| `SnippetRule` IoT Topic Rule | New |
| `gosteady-{env}-device-policy` IoT policy | Modified — add cmd-topic subscribe statement |
| Existing 3 IoT Rules (activity / heartbeat / alert) | **Unchanged** |
| Existing SQS DLQ | **Unchanged** — SnippetRule uses the same DLQ as error action |
| Existing OTA bucket | **Unchanged** |

#### Modified stack: `GoSteady-{Env}-Processing`
| Resource | Change |
|----------|--------|
| Heartbeat handler | Pre-activation suppression logic + activation-ack handling |
| Activity / Alert handlers | **Unchanged** |

### Data Flow (snippet path)

```
Device firmware
   │ MQTT publish: gs/GS0000001234/snippet (binary, 84 KB, props: snippet_id, ts, anomaly_trigger)
   ▼
AWS IoT Core
   │ TLS 1.2, per-thing cert
   ▼
SnippetRule (IoT Rule, SQL: SELECT *, topic(2) AS thingName)
   │ Action: S3 PutObject
   ▼
s3://gosteady-{env}-snippets/GS0000001234/2026-04-17/{snippet_id}.bin
   │ AWS-managed encryption
   │ Lifecycle: 90d Glacier → 395d delete
   │
   └─→ Audit event device.snippet_uploaded (via S3 → EventBridge bridge in Phase 1.7)
```

### Data Flow (pre-activation handling)

```
Device firmware (in pre-activation, woke on motion)
   │ MQTT publish: gs/GS0000001234/heartbeat (battery_pct=0.65, etc.)
   ▼
AWS IoT Core → existing HeartbeatRule → Heartbeat handler Lambda
   │
   ├── GetItem Device Registry by serial
   │     activated_at = NULL → pre-activation mode
   │
   ├── UpdateItem Device Shadow.reported (battery, signal, lastSeen) — always
   │
   ├── Skip Threshold Detector (no synthetic alerts)
   │
   └── Sample audit: emit device.preactivation_heartbeat at 1/hr/serial
       (dedup via Shadow attribute lastPreactivationAuditAt)

[Later, after caregiver provisions device]

Device firmware receives gs/GS0000001234/cmd activation message
Device firmware persists activated_at locally
Device firmware sends next heartbeat with last_cmd_id: "act_5e8a..."
   ▼
Heartbeat handler:
   ├── GetItem Device Registry by serial → activated_at still NULL
   ├── Heartbeat has last_cmd_id matching outstanding activation
   ├── UpdateItem Device Registry: SET activated_at = heartbeat.ts
   ├── Emit audit device.activated
   ├── Threshold Detector now eligible to fire (post-activation)
   └── Continue normal heartbeat processing
```

### Interfaces

- **Snippet upload contract:** ARCHITECTURE.md §7 Snippet section
- **Downlink command contract:** ARCHITECTURE.md §7 Downlink Command section
- **Pre-activation suppression policy:** ARCHITECTURE.md §8

## Implementation

### Files Changed / Created

| File | Change Type | Description |
|------|------------|-------------|
| `infra/lib/stacks/ingestion-stack.ts` | Modified | Add SnippetRule + snippet S3 bucket + IoT policy statement for cmd subscribe |
| `infra/lib/constructs/snippet-bucket.ts` | New | Reusable S3 bucket construct with lifecycle + encryption defaults |
| `infra/lambda/heartbeat-processor/handler.py` | Modified | Pre-activation suppression + activation-ack handling |
| `infra/test/ingestion-stack.test.ts` | New (or modified) | Snippet rule + bucket + policy assertions |
| `docs/specs/phase-1a-revision.md` | New | This document |

### Dependencies

- **Phase 1.5 Security** — already deployed; no new KMS keys needed (AWS-managed for snippets)
- **Phase 0B revision (in-progress)** — Device Registry needs `activated_at` attribute; can deploy independently (DDB schemaless)
- **Phase 1B revision** — heartbeat-processor handler is also being revised for hierarchy snapshots; coordinate change-set ordering

### Configuration

| CDK Context Key | Dev | Prod | Notes |
|---|---|---|---|
| `snippetGlacierTransitionDays` | 90 | 90 | Standard → Glacier |
| `snippetTotalRetentionDays` | 395 | 395 | ~13 months total before delete |
| `snippetMaxSizeKb` | 100 | 100 | Documented limit; not enforced (firmware contract) |

## Testing

### Test Scenarios

| # | Scenario | Method | Expected Result | Status |
|---|----------|--------|-----------------|--------|
| T1 | Deploy snippet bucket + IoT Rule | `cdk deploy GoSteady-Dev-Ingestion` | New bucket + rule visible in console | Pending |
| T2 | Publish synthetic 84 KB binary message to `gs/{serial}/snippet` | `aws iot-data publish` with binary payload | S3 object appears at `s3://gosteady-dev-snippets/{serial}/{date}/{snippet_id}.bin` within 5s | Pending |
| T3 | Snippet bucket blocks public access | `aws s3api get-public-access-block` | All 4 toggles true | Pending |
| T4 | Snippet bucket lifecycle policy active | `aws s3api get-bucket-lifecycle-configuration` | Glacier rule + delete rule present | Pending |
| T5 | Device subscribes to its own `cmd` topic | Publish `gs/GS0000001234/cmd`; device with matching cert subscribed | Message delivered | Pending |
| T6 | Device denied subscribe to another device's `cmd` topic | Device A attempts subscribe to `gs/B/cmd` | Subscribe denied by IoT policy | Pending |
| T7 | Pre-activation heartbeat: no battery alert fires | Heartbeat for device with `activated_at=NULL`, `battery_pct=0.03` | No `battery_critical` alert in DDB; Shadow updated | Pending |
| T8 | Pre-activation heartbeat: audit event logged | Same as T7 | One `device.preactivation_heartbeat` audit event | Pending |
| T9 | Pre-activation heartbeat sampling | Send 5 heartbeats within 30 min for unactivated device | Only 1 audit event emitted; Shadow updated 5 times | Pending |
| T10 | Activation ack flow | Provision device (publishes activate cmd); then send heartbeat with `last_cmd_id` matching | `Device Registry.activated_at` set; `device.activated` audit event | Pending |
| T11 | Post-activation: threshold alerts fire normally | Activated device sends heartbeat with `battery_pct=0.03` | `battery_critical` alert generated | Pending |
| T12 | Heartbeat with stale / unknown `last_cmd_id` | Send heartbeat with `last_cmd_id: act_NEVER_ISSUED` | No state change; processed as normal heartbeat; no warning | Pending |
| T13 | SnippetRule failure routes to DLQ | Send malformed snippet payload | Error visible in `gosteady-{env}-iot-dlq` | Pending |
| T14 | Existing activity / heartbeat / alert paths untouched | Run Phase 1B regression suite (15 scenarios) | All 15 still pass | Pending |

### Verification Commands

```bash
# Confirm snippet bucket exists with encryption + lifecycle
aws s3api head-bucket --bucket gosteady-dev-snippets
aws s3api get-bucket-encryption --bucket gosteady-dev-snippets
aws s3api get-bucket-lifecycle-configuration --bucket gosteady-dev-snippets

# List recent snippet uploads
aws s3 ls s3://gosteady-dev-snippets/ --recursive --human-readable | head -20

# Confirm SnippetRule
aws iot get-topic-rule --rule-name gosteady-dev-snippet-rule

# Confirm IoT policy includes cmd-subscribe
aws iot get-policy --policy-name gosteady-dev-device-policy \
  | jq -r '.policyDocument' | jq '.Statement[] | select(.Action[]? | contains("Subscribe"))'

# Synthesize a snippet upload from CLI (binary payload)
dd if=/dev/urandom of=/tmp/synth_snippet.bin bs=1024 count=84
aws iot-data publish \
  --topic gs/GS0000099991/snippet \
  --payload fileb:///tmp/synth_snippet.bin \
  --user-properties '[{"name":"snippet_id","value":"test_uuid_001"},{"name":"window_start_ts","value":"2026-04-17T19:00:00Z"}]'

# Verify it landed
aws s3 ls s3://gosteady-dev-snippets/GS0000099991/ --recursive

# Tail heartbeat handler logs to watch pre-activation flow
aws logs tail /aws/lambda/gosteady-dev-heartbeat-processor --region us-east-1 --follow
```

## Deployment

### Deploy Commands

```bash
cd infra
npm run build

# Deploy ingestion stack changes (snippet rule + bucket + policy)
npx cdk deploy GoSteady-Dev-Ingestion --context env=dev --require-approval never

# Deploy processing stack changes (heartbeat handler revision)
npx cdk deploy GoSteady-Dev-Processing --context env=dev --require-approval never

# Verify both
npx cdk diff --all --context env=dev | grep -E "Snippet|cmd|activated_at"
```

### Rollback Plan

```bash
# Revert ingestion-stack.ts and heartbeat-processor changes
git revert <phase-1a-revision-commit-sha>
cd infra && npm run build
npx cdk deploy GoSteady-Dev-Ingestion GoSteady-Dev-Processing \
  --context env=dev --require-approval never

# Snippet bucket: dev removalPolicy=DESTROY + autoDeleteObjects=true cleans up.
# In prod, retain bucket; manually clean if needed.
# IoT policy reverts cleanly — devices re-evaluate on next connect.
```

## Decisions Log

| # | Decision | Alternatives Considered | Why This Choice |
|---|----------|------------------------|-----------------|
| D1 | Snippet ingestion via IoT Rule S3 action — no Lambda in the path | (a) Lambda processes + writes to S3; (b) IoT Rule writes to Kinesis Firehose → S3; (c) Lambda writes to single multi-tenant bucket via app logic | Direct S3 action is the cheapest, lowest-latency, fewest-moving-parts option for a pure write-to-storage path. Lambda would add cost + cold-start + a failure surface for zero benefit at MVP scale. Firehose adds buffering complexity unneeded for ~720 snippets/month. |
| D2 | Snippet bucket uses AWS-managed encryption, not CMK | CMK on AuditKey or new SnippetKey | Snippets are non-PHI sensor data. Per ARCHITECTURE.md §9 cost-vs-value table, AWS-managed keys are appropriate for non-identity bulk data. Adds zero ops burden; revisit if a customer requires CMK. |
| D3 | Pre-activation heartbeat audit sampled to 1/hr/serial via Shadow attribute dedupe | Always emit; never emit; sample to specific cadence configured per environment | 1/hr matches heartbeat cadence — captures presence without flooding the audit log. Shadow attribute (`lastPreactivationAuditAt`) is a natural dedupe primitive that doesn't need a new DDB read/write. |
| D4 | `activated_at` lives on Device Registry, not DeviceAssignments | Field on assignment row | Device Registry is the live state for the device; activation is a device-lifecycle property, not an assignment property. Even after multiple assignments over time, `activated_at` reflects the original device-cloud handshake. |
| D5 | Activation-ack handling lives in heartbeat handler, not a separate Lambda | Dedicated activation-ack handler | Heartbeats already carry `last_cmd_id`; bolting the ack check onto the existing path saves a Lambda. The conditional logic adds <5ms to heartbeat processing. |
| D6 | Snippet object key includes a date-prefix (`{serial}/{date}/{snippet_id}.bin`) | Flat per-serial prefix; per-anomaly-type sub-prefix | Date prefix enables S3 lifecycle policies + cheap CLI-side date-filtered listings. Anomaly-type sub-prefix would split the corpus and complicate retrain assembly. |
| D7 | SnippetRule shares the existing iot-dlq, not a dedicated DLQ | Per-rule DLQ | Existing DLQ already has 14-day retention and is monitored. Adding a second queue for negligible volume isn't worth the operational duplication. |
| D8 | IoT policy update is in-place modification of existing per-thing policy, not a v2 policy | Versioned policy with rolling migration | Per-thing policies are independently versioned by AWS — in-place changes propagate on next device connect. v2 migration would add 2-3 deploy cycles for no incremental safety. |

## Open Questions

- [ ] **Snippet ingestion error reporting back to firmware**: today, if SnippetRule fails (S3 throttling, payload corruption), firmware doesn't learn. Should we publish failures to `gs/{serial}/snippet/ack` topic for firmware visibility? Or rely on firmware-side retry policy + USB retrieval as fallback? Lean: defer until firmware shows it matters in practice.
- [ ] **Snippet retention longer than 13 months for audit hold**: if a regulatory hold is placed, can we extend selectively per-serial via S3 Object Lock retroactively? Probably not without bucket-wide Object Lock from day 1. Acceptable risk for v1.
- [ ] **`activated_at` rollback on decommission?**: when a device is decommissioned and later recovered (`decommissioned (lost)` → `ready_to_provision`), does `activated_at` reset? Lean: yes — recovery is essentially a re-issue, and the device should re-enter pre-activation flow on next provision. Confirm in 0B revision.
- [ ] **Pre-activation heartbeats from a stuck-firmware device** (firmware bug, never receives activation cmd): how long before operations are alerted? Lean: 24h after `device.activation_sent` with no `device.activated` triggers an ops alert via Phase 1.6 alarms.

## Changelog
| Date | Author | Change |
|------|--------|--------|
| 2026-04-17 | Jace + Claude | Initial revision spec |

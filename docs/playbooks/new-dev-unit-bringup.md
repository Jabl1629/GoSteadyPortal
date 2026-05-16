# Playbook — Bring up a new dev unit (Thingy:91 X)

> **Scope:** Provision a fresh, never-used Thingy:91 X as a GoSteady dev/bench
> unit. Covers cloud-side cert + Thing + Device Registry prep, firmware-side
> cert flash, application reflash, and first-heartbeat verification.
>
> **Out of scope:** Shipping (`GS0000000001-3` range) units — those follow
> mostly the same flow but with different ownership semantics and a real
> provisioning + activation flow once Phase 2A ships. See
> [`phase-2a-device-lifecycle.md`](../specs/phase-2a-device-lifecycle.md)
> for that.
>
> **Source-of-truth docs this consolidates** (don't duplicate — reference them):
> - [`ARCHITECTURE.md`](../specs/ARCHITECTURE.md) §4 (device lifecycle), §14 (DL12-14, requirements)
> - [`firmware-coordination/2026-04-17-cloud-contracts.md`](../firmware-coordination/2026-04-17-cloud-contracts.md)
>   §C.4.1 (cert minting decision), §C.4.3 (serial ranges), §C.4.5 (manufacturer enrollment),
>   §C2.1-C2.7 (the first cert-handoff bundle), §C6.1 (Shadow MQTT topic grants),
>   §C9.2 (SW2 caution), §C11 (post-conference forensics, AT-serialization watch item)
> - [`tools/flash_cert.py`](https://github.com/Jabl1629/gosteady-firmware) docstring (in firmware repo)

---

## TL;DR — the four phases

1. **Cloud-side prep** (~5 min, automatable): mint cert + key, create IoT Thing,
   attach policy, write Device Registry row, append to handoff bundle
2. **Add to bundle** (~1 min): copy artifacts into the per-developer cert bundle directory
3. **Firmware-side flash** (~15 min, on bench with device + J-Link): flash NCS
   `at_client` sample → run `flash_cert.py` → reflash gosteady cloud build
4. **Cloud-side verification** (~5 min): confirm first heartbeat lands in Shadow,
   Per-Device dashboard widgets populate, no DLQ messages

---

## Pre-flight checklist

Before starting, confirm:

- [ ] Brand-new Thingy:91 X with **all J-Link pins intact** (the bench unit's
  pins broke; new units are how we keep an unblocked firmware-iteration path)
- [ ] **SW2 in the nRF91 position.** Critical — see §C9.2 cascade-corruption
  warning. Moving SW2 mid-bringup voids the recovery path.
- [ ] USB cable that supports data (not charge-only)
- [ ] Either the bundled iBasis trial eSIM OR a physical SIM you can install
  in the nano-SIM tray
- [ ] AWS dev credentials active (`aws sts get-caller-identity` returns
  account `460223323193`)
- [ ] Firmware repo synced + cloud build available at
  `~/Documents/gosteady-firmware/build_cloud/merged.hex`
- [ ] NCS `at_client` sample built and available at
  `/opt/nordic/ncs/v3.2.4/nrf/samples/cellular/at_client/build/zephyr/merged.hex`
  (one-time setup if not — see [Troubleshooting](#troubleshooting))
- [ ] Existing cert bundle directory exists at
  `~/Desktop/gosteady-firmware-cert-handoff-2026-04-27/` (created in §C2.4;
  per-developer secret store)

---

## Choosing a serial

Per coord §C.4.3 + ARCH §14:

| Range | Use | Notes |
|---|---|---|
| `GS9999999990` – `GS9999999999` | **Dev / test fixtures** | Visually distinct from production; won't collide with low-range serials |
| `GS0000000001` – `GS0000000003` | First three shipping units | Already minted (coord §C2.1) |
| `GS0000000004` and up | Future shipping production | Allocate sequentially |

**Rule of thumb for dev units:** allocate from the top of the test range
downward — `GS9999999999` first (taken by bench), `GS9999999998` next,
`GS9999999997` after that, etc. Check existing Things first:

```bash
aws iot list-things --region us-east-1 --thing-type-name GoSteadyWalkerCap-dev \
  --query 'things[].thingName' --output text
```

The next available test serial = `GS9999999999 - (count of GS9999999xxx already taken)`.

---

## Phase 1 — Cloud-side prep

> Set `SERIAL` once at the top, the rest of the commands use it. The whole
> phase can also be wrapped into `tools/bringup-dev-unit.sh <serial>` —
> consider scripting after the third manual run.

```bash
SERIAL=GS9999999998   # adjust per the serial allocation step above
REGION=us-east-1
ACCOUNT=460223323193
POLICY=gosteady-dev-device-policy
THING_TYPE=GoSteadyWalkerCap-dev
TABLE=gosteady-dev-devices
BUNDLE=~/Desktop/gosteady-firmware-cert-handoff-2026-04-27
```

### 1.1 Mint cert + key

```bash
mkdir -p "$BUNDLE/$SERIAL"
aws iot create-keys-and-certificate --region $REGION --set-as-active \
  --certificate-pem-outfile  "$BUNDLE/$SERIAL/$SERIAL.cert.pem" \
  --public-key-outfile       "$BUNDLE/$SERIAL/$SERIAL.public.key" \
  --private-key-outfile      "$BUNDLE/$SERIAL/$SERIAL.private.key" \
  --query '{arn:certificateArn,id:certificateId,fp:certificateId}' \
  --output table
chmod 0600 "$BUNDLE/$SERIAL/$SERIAL.private.key"
```

> The cert ID **is** the SHA-256 fingerprint of the certificate (AWS IoT
> convention). Save it — it's also the value for the MANIFEST.csv
> `cert_fingerprint_sha256` column.

Capture the ARN + fingerprint into shell variables for the next steps:

```bash
CERT_ARN=$(aws iot list-certificates --region $REGION \
  --query "certificates[?status=='ACTIVE'] | [?contains(certificateArn, '$(date +%Y)')]" \
  --output text | head -1 | awk '{print $2}')
# ↑ rough heuristic; safer to copy from the table above into:
#   CERT_ARN=arn:aws:iot:us-east-1:460223323193:cert/<fingerprint>
CERT_ID=${CERT_ARN##*/}
echo "CERT_ARN=$CERT_ARN"
echo "CERT_ID=$CERT_ID"
```

### 1.2 Create IoT Thing

```bash
aws iot create-thing --region $REGION \
  --thing-name "$SERIAL" --thing-type-name "$THING_TYPE"
```

### 1.3 Attach policy to cert, attach cert to Thing

The per-thing policy `gosteady-dev-device-policy` already covers everything
the firmware needs (Connect, Publish/Subscribe/Receive on `gs/<thing>/*`,
plus Shadow MQTT topics on `$aws/things/<thing>/shadow/*` — per coord
§C2.3 and §C6.1). No new policy needed.

```bash
aws iot attach-policy   --region $REGION --policy-name "$POLICY" --target "$CERT_ARN"
aws iot attach-thing-principal --region $REGION --thing-name "$SERIAL" --principal "$CERT_ARN"
```

### 1.4 Write Device Registry row

```bash
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
aws dynamodb put-item --region $REGION --table-name $TABLE --item "{
  \"serialNumber\":     {\"S\": \"$SERIAL\"},
  \"status\":           {\"S\": \"ready_to_provision\"},
  \"certFingerprint\":  {\"S\": \"$CERT_ID\"},
  \"manufacturedBy\":   {\"S\": \"GoSteady-dev-bringup\"},
  \"notes\":            {\"S\": \"dev/test fixture from reserved range; never ships\"},
  \"activated_at\":     {\"S\": \"$NOW\"}
}"
```

> **Dev-only shortcut:** writing `activated_at` directly bypasses the formal
> `ready_to_provision → provisioned → active_monitoring` state machine and
> the activate-cmd flow (Phase 2A `device-api` Lambda, not yet built). Without
> `activated_at` set, threshold-detector suppresses synthetic alerts for the
> device (per ARCH §8 / DL13 pre-activation suppression). For dev units you
> typically want signal/battery alerts visible during bench testing, so set
> this directly. **Production units must NOT take this shortcut** — they go
> through the formal activate cmd flow (coord §F.9.4 / DL14).

### 1.5 Verify cloud-side state

```bash
# All four together — should all return the same fingerprint or success
aws iot describe-certificate --region $REGION --certificate-id "$CERT_ID" \
  --query 'certificateDescription.status' --output text
# Expect: ACTIVE

aws iot list-thing-principals --region $REGION --thing-name "$SERIAL" \
  --query 'principals[0]' --output text
# Expect: $CERT_ARN

aws iot list-attached-policies --region $REGION --target "$CERT_ARN" \
  --query 'policies[*].policyName' --output text
# Expect: gosteady-dev-device-policy

aws dynamodb get-item --region $REGION --table-name $TABLE \
  --key "{\"serialNumber\":{\"S\":\"$SERIAL\"}}" \
  --query 'Item.{status:status.S,fp:certFingerprint.S,act:activated_at.S}'
# Expect: status=ready_to_provision, fp=<expected>, act=<now>
```

---

## Phase 2 — Update the handoff bundle

The bundle at `~/Desktop/gosteady-firmware-cert-handoff-2026-04-27/` is the
per-developer secret store. It's **not in git** (private keys live here)
and the path is shared on the single-developer Mac via filesystem (per coord §C3.1
— if the team ever grows beyond one developer, the cross-machine handoff
goes back to 1Password shared items per §C2.5).

### 2.1 Write per-device README

```bash
cat > "$BUNDLE/$SERIAL/$SERIAL.README.txt" <<EOF
GoSteady firmware cert handoff — $(date -u +%Y-%m-%d)
============================================
Serial:           $SERIAL
Cert ARN:         $CERT_ARN
SHA-256 fp:       $CERT_ID

IoT Thing:        $SERIAL (type GoSteadyWalkerCap-dev)
IoT Policy:       gosteady-dev-device-policy
                  (per-thing scope via \${iot:Connection.Thing.ThingName};
                   covers connect, publish/subscribe/receive on gs/<thing>/*,
                   and Get/UpdateThingShadow + MQTT shadow topics on
                   thing/<thing> and \$aws/things/<thing>/shadow/*)

AWS environment:  account 460223323193 (dev), region us-east-1
IoT endpoint:     a2dl73jkjzv6h5-ats.iot.us-east-1.amazonaws.com:8883
AWS IoT Root CA:  Amazon Root CA 1 (../AmazonRootCA1.pem in this bundle)

Files in this directory:
  $SERIAL.cert.pem     public certificate (PEM); flash to nRF9151 secure store
  $SERIAL.private.key  private key (PEM); flash to nRF9151 secure store; mode 0600
  $SERIAL.public.key   public key (PEM); reference only — not needed by firmware

For the firmware engineer:
  - Use AT%CMNG=0,201,... to write cert + key into modem CryptoCell-312
  - tools/flash_cert.py --serial $SERIAL handles the AT dance
  - Pin Amazon Root CA 1 (../AmazonRootCA1.pem) as the trusted server cert root
EOF
```

### 2.2 Append MANIFEST row

```bash
echo "$SERIAL,$CERT_ID,$(date -u +%Y-%m-%d),TBD,dev/test fixture (reserved range; never ships)" \
  >> "$BUNDLE/MANIFEST.csv"
```

Confirm:

```bash
tail -2 "$BUNDLE/MANIFEST.csv"
ls "$BUNDLE/$SERIAL/"
```

---

## Phase 3 — Firmware-side flash

**Device on USB + SW2 confirmed in nRF91 position.**

### 3.1 Confirm USB enumeration

```bash
ls /dev/cu.usbmodem*
# Expect two ports: usbmodem*102 (uart0, 115200) + usbmodem*105 (uart1, 1Mbaud)
```

If only one port enumerates or the device shows up as `NRF5340` instead of
`NRF91` in nRF Connect Programmer, SW2 is likely in the wrong position —
**stop and re-check** before any nrfjprog command (see §C9.2).

### 3.2 Flash NCS at_client sample (temporary AT shell)

`flash_cert.py` talks to the modem's AT interface, which gosteady firmware
doesn't expose. The standard approach is to temporarily flash Nordic's
`at_client` sample, run the cert flash, then reflash gosteady. The cert
survives in CryptoCell-312 across the firmware swap.

**Easiest source: Nordic ships a pre-built at_client hex with the SDK 3.2.1
firmware bundle.** Use that instead of building yourself:

```bash
# Source path (Nordic-shipped pre-built):
SRC="/Users/jaceblackburn/Library/Mobile Documents/com~apple~CloudDocs/Documents/GoSteady/[Legacy] firmware_algo_development/nordic resources/thingy91x_mfw-2.0.4_sdk-3.2.1/img_app_bl/thingy91x_at_client_2026-02-24_d8887f6f.hex"

# Copy out of iCloud first to avoid mid-flash download lag:
cp "$SRC" /tmp/at_client.hex

# Flash:
nrfjprog -f NRF91 --program /tmp/at_client.hex --chiperase --verify --reset
```

> **JLinkARM noise is benign.** nrfjprog frequently prints ~10 lines of
> `[error] [SeggerBackend] - JLinkARM.dll reported error -256 ...` BEFORE
> the actual flash output. These are part of nrfjprog's chip-family probe
> sequence — it tries multiple device profiles before settling on NRF91.
> The flash + verify steps after them are what matter; if those complete
> with `Applying system reset. Run.`, the flash succeeded.

> Alternative: building at_client from source (`west build -b thingy91x/nrf9151/ns`
> inside `/opt/nordic/ncs/v3.2.4/nrf/samples/cellular/at_client/`) has been
> finicky on macOS — homebrew's Python 3.14 gets picked up by mcuboot's sub-
> build instead of NCS's toolchain Python 3.12, and crashes on missing
> `pykwalify`. See [Troubleshooting](#troubleshooting) for the env override
> if you need to build from source. The pre-built hex avoids this entirely.

### 3.3 Run cert flash tool

```bash
cd ~/Documents/gosteady-firmware
tools/flash_cert.py --serial $SERIAL
```

What this does (per flash_cert.py docstring):
- Writes root CA → sec_tag 201, type 0 (`AT%CMNG=0,201,0,...`)
- Writes client cert → sec_tag 201, type 1
- Writes private key → sec_tag 201, type 2
- Verifies each write succeeded
- Cert lives in CryptoCell-312 secure store, survives chiperase

Expected output: per-step `OK` lines for each write. Anything else → see
[Troubleshooting](#troubleshooting).

### 3.4 Build gosteady with the right client_id, then flash

> **⚠️ Critical: the existing `build_cloud/merged.hex` is hardcoded for
> `GS9999999999` (bench unit serial).** Look at `prj_cloud.conf`:
> `CONFIG_AWS_IOT_CLIENT_ID_STATIC="GS9999999999"`. The firmware uses this
> Kconfig value as the MQTT client ID AND for constructing every uplink
> topic (`gs/{client_id}/heartbeat` etc.). If you flash the existing
> `build_cloud/` to a different unit, the broker will reject the connection
> with `-128` because the cert + Thing are scoped to one serial but the
> firmware announces another. **You MUST rebuild with `-DCONFIG_AWS_IOT_CLIENT_ID_STATIC=\"$SERIAL\"`
> per unit.**

```bash
# Build with the correct serial baked in (out-of-tree build dir per unit
# avoids clobbering build_cloud/ which is GS9999999999's binary)
TOOLCHAIN=/opt/nordic/ncs/toolchains/185bb0e3b6
cd /opt/nordic/ncs/v3.2.4 && \
PATH="$TOOLCHAIN/opt/python@3.12/bin:$TOOLCHAIN/bin:$TOOLCHAIN/opt/zephyr-sdk/arm-zephyr-eabi/bin:$PATH" \
ZEPHYR_BASE=/opt/nordic/ncs/v3.2.4/zephyr \
ZEPHYR_SDK_INSTALL_DIR=$TOOLCHAIN/opt/zephyr-sdk \
ZEPHYR_TOOLCHAIN_VARIANT=zephyr \
  $TOOLCHAIN/bin/west build \
  -d ~/Documents/gosteady-firmware/build_cloud_${SERIAL,,} \
  -b thingy91x/nrf9151/ns \
  ~/Documents/gosteady-firmware \
  -- -DEXTRA_CONF_FILE=prj_cloud.conf \
     -DCONFIG_AWS_IOT_CLIENT_ID_STATIC=\"$SERIAL\"
# Build takes ~3-5 min on M1. Out-of-tree build dir = build_cloud_gs9999999998 etc.

# Then flash:
nrfjprog -f NRF91 \
  --program ~/Documents/gosteady-firmware/build_cloud_${SERIAL,,}/merged.hex \
  --chiperase --verify --reset
```

> **Why the env-var dance:** Nordic's CMake setup on macOS can't find its
> own Zephyr SDK without `ZEPHYR_SDK_INSTALL_DIR` set, and CMake's
> `find_program(Python3)` picks up homebrew's Python 3.14 over NCS's
> Python 3.12 unless the toolchain bin dir is prepended to PATH. The
> long PATH override + 3 env vars above replicate what VSCode's "nRF
> Connect for VS Code" extension or Nordic's `nrfutil` would do
> automatically. See [Troubleshooting](#troubleshooting) for individual
> error symptoms.

> `--chiperase` wipes the application flash (overwriting `at_client` with
> gosteady) but does NOT touch CryptoCell-312 (cert survives) nor the
> external SPI NOR (LittleFS partitions survive — though on a fresh unit
> there's nothing to preserve there yet).

> **Longer-term firmware improvement worth queueing:** derive client_id at
> runtime from the cert's CN field (which equals the AWS IoT Thing name).
> Removes the per-unit rebuild step entirely. Until that lands, expect to
> rebuild per unit.

### 3.5 Watch first boot via uart0

In one terminal:

```bash
cd ~/Documents/gosteady-firmware
/opt/nordic/ncs/toolchains/185bb0e3b6/bin/python3 tools/log_console.py --echo
```

Expected boot sequence (first ~30 s):

```
*** Booting nRF Connect SDK v3.2.4-... ***
<inf> spi_nor: GD25LE255E@0: 32 MiBy flash
<inf> ADXL367: ADXL367 passed self-test
<inf> gs_session: gs_pipeline_init: ok
<inf> gosteady: GoSteady firmware starting (build ...)
<inf> gs_forensics: hwinfo reset_cause=0x00000010
<wrn> gs_forensics: previous reset was POWER_ON — count now 0   ← fresh unit
<inf> gs_forensics: forensics: boot=1 reset=POWER_ON faults=0 wdt=0   ← fresh unit
<inf> gosteady: bmi270: suspended at boot (idle until session start)
<inf> gosteady: adxl367 wake-on-motion armed
<inf> littlefs: ... lfs mounted ...
<inf> gosteady: boot_count = 1 (persisted to /lfs/boot_count)   ← first ever
<inf> gs_session: orphan_sweep: deleted 0 stale .dat file(s) at boot
<inf> gs_snippet: snippet fs mounted: total=16777216 B free=16769024 B
<inf> gs_battery: nrf_fuel_gauge version: 1.1.0
<inf> gs_battery: ... fuel gauge initialized: v0=..., t0=..., i0=...
<inf> cellular: nrf_modem_lib_init ok
<inf> cellular: lte_lc_connect_async kicked off — waiting for registration
<inf> gs_cloud: registered app subscription: gs/GS9999999998/cmd (QoS 1)
<inf> gs_cloud: cloud_init OK; heartbeat + activity workers spawned

# ~5-10 s later:
<inf> cellular: nw_reg_status=searching
<inf> cellular: nw_reg_status=registered_home   (or registered_roaming)
<inf> gs_cloud: cellular registered → publish first heartbeat
<inf> gs_cloud: PUBACK received — broker confirmed
```

`boot_count = 1` and `fault_counters` all zero are the fresh-unit
signature. If anything else, the unit may have been used before — verify
with the supplier.

---

## Phase 4 — Cloud-side verification

### 4.1 Shadow has reported state

```bash
aws iot-data get-thing-shadow --thing-name $SERIAL --region us-east-1 /tmp/shadow.json
python3 -c "import json; d=json.load(open('/tmp/shadow.json')); \
  r=d['state']['reported']; \
  print(f'  ts={r.get(\"ts\")}\n  battery_pct={r.get(\"battery_pct\")}\n  rsrp_dbm={r.get(\"rsrp_dbm\")}\n  firmware={r.get(\"firmware\")}\n  boot_count={r.get(\"boot_count\")}')"
```

Expected: timestamp within last few minutes, battery_pct ≈ shipped charge
state (Thingy:91 X ships at 50-70% usually), rsrp_dbm typical for your
office signal, boot_count = 1.

### 4.2 Heartbeat-processor log

```bash
aws logs filter-log-events --region us-east-1 \
  --log-group-name /aws/lambda/gosteady-dev-heartbeat-processor \
  --start-time $(python3 -c "import time; print(int((time.time()-300)*1000))") \
  --filter-pattern "\"$SERIAL\"" \
  --output text --query 'events[].message' | head -5
```

Expect a `heartbeat_ok` JSON log line with the cap's serial in the last few
minutes.

### 4.3 Per-Device dashboard toggle

Open https://console.aws.amazon.com/cloudwatch/home?region=us-east-1#dashboards:name=gosteady-dev-per-device
and set the `serial` variable at the top to the new serial. All widgets
should populate within ~1 min of the first heartbeat (BatteryPct, RsrpDbm,
SnrDb appear immediately as per-minute metrics; fault counters appear once
the unit has been up for an hour).

### 4.4 DLQ + Lambda Errors should be 0

```bash
aws cloudwatch get-metric-statistics --region us-east-1 \
  --namespace AWS/SQS --metric-name ApproximateNumberOfMessagesVisible \
  --dimensions Name=QueueName,Value=gosteady-dev-iot-dlq \
  --start-time $(date -u -v-1H +%Y-%m-%dT%H:%M:%SZ) \
  --end-time   $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period 300 --statistics Maximum \
  --query 'Datapoints[?Maximum > `0`]' --output json
# Expect: []
```

---

## Watch items / known gotchas

### SW2 — never touch unless you mean it (per coord §C9.2)

SW2 routes J-Link SWD to nRF91 (default) or nRF53 (bridge core). Moving it
mid-bringup cascades to nrfjprog operating on the wrong chip-family register
map, partially-corrupts the bridge core, kills USB CDC enumeration, and
needs a multi-step recovery via `nrfjprog -f NRF53 --coprocessor` flags.
On a fresh unit with intact J-Link pins, recovery is possible — but
unnecessary. **Just don't move SW2.**

### iBasis trial size — 10 MB lifetime, snippets dominate

Default Thingy:91 X ships with an iBasis IoT eSIM, 10 MB lifetime free
trial (NOT monthly). Per-payload sizes:

| Uplink | Bytes | Cumulative for 10 MB |
|---|---|---|
| Heartbeat | ~250 B | ~40,000 heartbeats (= 4.5 years at hourly cadence) |
| Activity uplink | ~150 B | ~70,000 sessions |
| Snippet | 50-84 KB | ~125-200 snippets |

**Snippets dominate by a factor of ~300.** During bench bringup, consider:

```
# in build_cloud's prj.conf or via west build -- -DCONFIG_GOSTEADY_SNIPPET_ENABLE=n
CONFIG_GOSTEADY_SNIPPET_ENABLE=n
```

…until you're past initial bringup. With snippets off, the iBasis trial
will last months even under heavy bench usage. Re-enable when you
specifically need snippet-path validation.

This is also why the May 11-12 conference exhausted the Onomondo SIM
(38 snippets × ~70 KB avg = ~2.7 MB, plus heartbeats + activity + retry
storm — and Onomondo's trial allocation is comparable to iBasis's).

### SIM selection (physical vs eSIM)

Thingy:91 X has both a physical nano-SIM slot AND an iBasis eSIM. The
firmware doesn't currently force a selection — the modem picks whichever
has signal + a valid profile. With NO physical SIM installed, the modem
falls back to eSIM (the desired path for a fresh dev unit using the iBasis
trial). With a physical Onomondo SIM installed, the modem prefers it.

If you ever need to force eSIM despite a physical SIM being present, the
AT command is `AT%XSIM=0` (eSIM) vs `AT%XSIM=1` (physical) — but firmware
would need a Kconfig + boot-time AT call to apply it. Not currently exposed.

### Activation state on dev units (the §1.4 shortcut)

The `activated_at` Device Registry shortcut described in §1.4 is dev-only.
It bypasses:
- Phase 2A `device-api` Lambda's `provision` endpoint (not built yet)
- The `cmd_id` echo / `last_cmd_id` ack flow (coord §F.2 / DL14a)
- Shadow `desired.activated_at` re-check on cellular wake (coord §F.9.4 / DL14)

For production / shipping units, the full flow per ARCH §4 "Activation
message section" is mandatory. Don't write `activated_at` directly to
shipping unit DDB rows — it defeats the audit trail and pre-activation
suppression invariants.

### §C11.5 AT-serialization watch item

A fresh dev unit with working J-Link pins is the natural place to
bench-validate the §C11.5 firmware patch (timeout-wrapped AT calls in
session_start). The proposed validation: deliberately starve the modem
(airplane mode mid-session, or move cap into a Faraday enclosure) and
confirm session_start returns within ~2.5 s with `start_utc=unavailable`
and FMEA 1.1 retro-stamp on the resulting activity row. Mark the new dev
unit as the patch-validation target so it doesn't accidentally get used
for unrelated bench work in parallel.

---

## Decommissioning a dev unit

When retiring a dev unit (e.g., end of useful life, certificate compromised,
swap to a new generation board):

```bash
SERIAL=GS9999999998   # the retiring unit
CERT_ARN=$(aws iot list-thing-principals --region us-east-1 --thing-name "$SERIAL" \
  --query 'principals[0]' --output text)
CERT_ID=${CERT_ARN##*/}

# 1. Detach principal + policy
aws iot detach-thing-principal --region us-east-1 --thing-name "$SERIAL" --principal "$CERT_ARN"
aws iot detach-policy --region us-east-1 --policy-name gosteady-dev-device-policy --target "$CERT_ARN"

# 2. Deactivate then delete cert
aws iot update-certificate --region us-east-1 --certificate-id "$CERT_ID" --new-status INACTIVE
aws iot delete-certificate --region us-east-1 --certificate-id "$CERT_ID" --force-delete

# 3. Delete Thing
aws iot delete-thing --region us-east-1 --thing-name "$SERIAL"

# 4. Delete Device Registry row
aws dynamodb delete-item --region us-east-1 --table-name gosteady-dev-devices \
  --key "{\"serialNumber\":{\"S\":\"$SERIAL\"}}"

# 5. Delete bundle directory (private keys NOT recoverable from cloud)
rm -rf "$HOME/Desktop/gosteady-firmware-cert-handoff-2026-04-27/$SERIAL"

# 6. Remove MANIFEST entry (manual edit)
$EDITOR "$HOME/Desktop/gosteady-firmware-cert-handoff-2026-04-27/MANIFEST.csv"
```

Per coord §C3.3: physical bundle deletion is the only way to lose the
private key. AWS only ever held it transiently during `create-keys-and-certificate`.

---

## Troubleshooting

### `at_client` sample not built

```bash
cd /opt/nordic/ncs/v3.2.4/nrf/samples/cellular/at_client
west build -b thingy91x/nrf9151/ns
```

### `flash_cert.py` times out or hangs

Common causes:
- Wrong USB port. `flash_cert.py` defaults to `/dev/cu.usbmodem*102` (uart0).
  Confirm with `ls /dev/cu.usbmodem*`. If only `/dev/cu.usbmodem105` enumerates
  (uart1 only), SW2 is wrong or at_client sample didn't take.
- DTR not asserted. `flash_cert.py` handles this; if you wrote a custom
  serial-reading script, ensure `ser.dtr = True` before any AT commands.
- at_client sample wasn't loaded. Re-run §3.2.

### Cellular never registers (`nw_reg_status` stays `searching`)

- Verify SIM. Physical SIM tray should click in correctly; on fresh units
  with only the eSIM, no physical SIM is fine.
- Move to a window or higher floor — Thingy:91 X PCB antennas are weak
  indoors.
- Per coord §C11, if you see repeated `EMM cause: 19` warnings, the SIM is
  out of data quota (regardless of provider — iBasis trial exhausted is
  the same symptom as Onomondo exhausted).

### Lambda fires but DDB row never appears

- Check `aws dynamodb get-item ...` (see §1.5). If the row exists but
  Shadow update isn't happening, IoT Rule may be misconfigured — check
  `gosteady_dev_heartbeat` rule status.
- Per coord §C8 / §C10.5, swallowed errors in older handlers could mask
  this. The §1.6 alarm catalog should catch any new instances; if not,
  see ARCHITECTURE.md §18.8 (silent-swallow risk pattern).

### Wrong serial picked up by handler

The IoT Rule SQL injects `thingName` from the topic path (`topic(2)`). If
the firmware-side `serial` field in the payload doesn't match the Thing
name on the cert, the handler uses `thingName` as ground truth (per ARCH
§7 universal conventions). Mismatch warrants checking the firmware-side
serial Kconfig — it should be derived from cert metadata, not hardcoded.

---

## References

- **Coord doc** — [`2026-04-17-cloud-contracts.md`](../firmware-coordination/2026-04-17-cloud-contracts.md)
  - §C.4.1 — Per-device cert + key delivery decision (cloud-generates-and-sends)
  - §C.4.3 — Serial range allocations
  - §C.4.5 — Manufacturer-side enrollment workflow
  - §C2.1-C2.7 — First cert-handoff bundle (the template this playbook follows)
  - §C2.3 — Shadow REST grants in device policy
  - §C3 — Single-developer handoff path (bundle on local disk, no 1Password)
  - §C6.1 — Shadow MQTT topic grants in device policy
  - §C9.2 — SW2 misposition cascade-corruption warning
  - §C11 — Conference forensics + §C10.5 AT-serialization watch item

- **Architecture spec** — [`ARCHITECTURE.md`](../specs/ARCHITECTURE.md)
  - §4 — Device lifecycle state machine + activation message
  - §5 — CDK stack map (Auth, Data, Processing, Ingestion stacks)
  - §7 — MQTT payload contracts
  - §8 — Threshold + alert policy (pre-activation suppression)
  - §14 — Cumulative locked-in requirements (DL1-14, D1-17)
  - §18.8 — Silent-swallow risk pattern during revision gaps

- **Firmware repo** — `~/Documents/gosteady-firmware/`
  - `tools/flash_cert.py` — cert + key + root CA flash via AT shell
  - `tools/log_console.py` — uart0 logger with auto-reconnect
  - `tools/control.py` — uart1 session-control protocol (`STATUS`, `LIST`, etc.)
  - `src/cellular.c` — modem init, AT calls, registration handling
  - `src/cloud.c` — heartbeat + activity workers, AWS IoT lib glue

- **Existing cert bundle** — `~/Desktop/gosteady-firmware-cert-handoff-2026-04-27/`
  - Per-developer secret store; not in git; deletable + recreatable
  - MANIFEST.csv tracks what's been minted

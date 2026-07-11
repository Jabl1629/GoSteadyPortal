# Playbook — Rollator firmware flash (prod unit)

> **Scope:** flash a **prod rollator** (first unit: `GS0002000001`) so it connects
> to prod AWS IoT as its baked serial, receives the D2C claim's activate cmd, and
> records sessions. The **cloud side is already done** by
> [`tools/bringup-prod-unit.sh`](../../tools/bringup-prod-unit.sh) +
> [`new-prod-unit-bringup.md`](new-prod-unit-bringup.md) (cert/Thing/prod-policy +
> `ready_to_provision` row + walkerId). This covers the **bench/firmware half**.
>
> **Shared mechanics — don't duplicate, follow these:**
> - [`new-dev-unit-bringup.md` §3](new-dev-unit-bringup.md#phase-3--firmware-side-flash)
>   — the flash dance (at_client → flash_cert.py → rebuild-with-serial → nrfjprog),
>   SW2 caution (§C9.2), USB enumeration, first-boot console expectations.
> - `gosteady-firmware/docs/build-configurations.md` — the overlay × symbol matrix
>   + build-dir → device map (the source of truth for which image is which).

---

## Two decisions before you flash

### Decision 1 — which physical unit becomes `GS0002000001`

The prod serial + prod cert get **baked/flashed onto a physical rollator**. Options:

- **Reflash the existing rollator `GS9999999981` → `GS0002000001`** *(recommended
  for the first unit).* Its **Onomondo SIM** (working, PSM tau=3 h granted) and
  hardware are already proven (coord §C52 / GOSTEADY_CONTEXT). The dev registry's
  `GS9999999981` row goes orphaned — harmless dev cruft (decommission later if you
  want it clean). Chip-erase preserves the SIM + external flash; only the app image
  + the sec_tag-201 cert change.
- **A separate physical rollator** — needs a working SIM installed first (a fresh
  Thingy's iBasis eSIM needs activation — DT-1 A2, `EMM cause 8` = unactivated
  trial; the Onomondo path is the proven one).

### Decision 2 — which build overlay

**All rollator *cloud* builds carry the pre-activation gate + activate-cmd handling**
(Core Device Contract v1 — DT-1 L1), so any of them will take the D2C claim's
activate cmd. They differ only in *posture*:

| Overlay (build dir) | Posture | Validated? | Best for |
|---|---|---|---|
| **`prj_rollator_cloud.conf`** (`build_rollator_gs81/`) → `rol-0.1.0-bench` | bench+cloud, autowake + green session LED, **uart0 console ON** (debuggable), **no shake-mode** — activates directly on the cloud cmd, snippets off | ✅ **DT-1, to the activate boundary** (2026-07-02, coord §C49) | ← **the first activation test** |
| `prj_rollator_field.conf` → `rol-0.1.0-bench` | deployment (dark), no low-power / shake | authored, not bench-built (subset of pilot) | dark deployment w/o battery mode |
| `prj_rollator_pilot.conf` (`build_rollator_pilot/`) → `rol-0.1.0-ww` | deployment target: dark + LOW_POWER + SESSION_LED + **PREACT shake-to-activate** | builds/fits (63.05 % RAM); ⚠ **PREACT wake/shake thresholds are walker-tuned, NOT validated for rollator wheel vibration** — DT-3 / spec A3 | real deployment — **after DT-3** |

**Recommendation:** flash **`prj_rollator_cloud.conf`** for the first prod
activation. It's the image DT-1 already drove through provision→activate, its
uart0 console is on (you can watch the whole loop), and it activates directly on
the claim's cloud cmd — no dependence on the unvalidated PREACT shake path. Move to
`prj_rollator_pilot` / `_field` for actual deployment, gated on the **DT-3 PREACT
bench validation** (a real open item, not a formality — rollator wheel vibration ≠
walker lift-and-place).

---

## Flash (bench; SW2 = nRF91 — verify first, see §C9.2)

**1. Cert → modem sec_tag 201.** Flash Nordic `at_client` first (temporary AT
shell — [dev §3.2](new-dev-unit-bringup.md#32-flash-ncs-at_client-sample-temporary-at-shell)),
then point `flash_cert.py` at the **prod** bundle:

```bash
cd ~/Documents/gosteady-firmware
tools/flash_cert.py --serial GS0002000001 --bundle ~/Desktop/gosteady-prod-cert-handoff
```
> ⚠ The prod bundle **must contain `AmazonRootCA1.pem`** (`flash_cert.py` resolves
> `<bundle>/AmazonRootCA1.pem`). The bring-up script stages it automatically for
> new units; **`GS0002000001` was provisioned before that fix**, so if it's
> missing: `cp ~/Desktop/gosteady-firmware-cert-handoff-2026-04-27/AmazonRootCA1.pem ~/Desktop/gosteady-prod-cert-handoff/`.

**2. Rebuild the image with THIS serial baked** (the overlay default is
`GS9999999981` — the `-D` override is **mandatory** or the broker rejects the
connection `-128`, dev §3.4):

```bash
# (toolchain env per new-dev-unit-bringup.md §3.4 / GOSTEADY_CONTEXT Dev environment)
west build -b thingy91x/nrf9151/ns -d build_rollator_gs0002000001 \
  ~/Documents/gosteady-firmware \
  -- -DEXTRA_CONF_FILE=prj_rollator_cloud.conf \
     -DCONFIG_AWS_IOT_CLIENT_ID_STATIC='"GS0002000001"'
```

**3. Flash** (chip-erase preserves the sec_tag-201 cert + external flash):

```bash
nrfjprog -f NRF91 --program build_rollator_gs0002000001/merged.hex \
  --chiperase --verify --reset --snr 802006700
```

**4. Watch first boot** (`tools/log_console.py`): clean boot, `rol-0.1.0-bench`,
LTE `registered_roaming` (Onomondo), NITZ time OK, **heartbeat PUBACK**. Endpoint
is unchanged (`a2dl73jkjzv6h5-ats…` — shared account).

---

## Verify (prod side)

**First heartbeat landed + right product:**
```bash
aws iot-data get-thing-shadow --thing-name GS0002000001 --region us-east-1 /tmp/s.json && \
python3 -c "import json;r=json.load(open('/tmp/s.json'))['state']['reported'];print('device_type',r.get('device_type'),'ts',r.get('ts'),'batt',r.get('battery_pct'))"
# expect device_type=rollator_platform (heartbeat-processor cross-checks vs the
# registry — a wrong-product flash trips the DT-0 mismatch alarm), recent ts.
```
```bash
aws logs filter-log-events --region us-east-1 \
  --log-group-name /aws/lambda/gosteady-prod-heartbeat-processor \
  --start-time $(python3 -c "import time;print(int((time.time()-600)*1000))") \
  --filter-pattern '"GS0002000001"' --query 'events[].message' --output text | head
```

**Then the full claim→activate (the DT-5 exit bar):** open the claim URL
`https://app.gosteady.co/setup/c7e589c0-eb65-4336-8757-e9182f60f5d5` on a phone →
SMS-OTP sign-up → **claim** → provisions the device + fires the activate cmd → the
device echoes `last_cmd_id` + exits pre-activation → **walk** → activity uplink
(`active_min`, no steps) → the household **dashboard** shows the session. That loop
on a real prod rollator is the **first real activation** (coord §C57.3 #5).

---

## Firmware-coordination notes

- **Version-string collision:** `rol-0.1.0-bench` = `prj_rollator_cloud` **and**
  `_field` **and** the capture image (build-configurations.md §5) — telemetry
  can't tell them apart. Track which image is on `GS0002000001` out-of-band.
- **Per-unit rebuild:** client-id-from-cert-CN (which would kill the per-unit
  `-D` rebuild) is queued but not shipped (DT-1 §Deferred) — the `-D` override is
  mandatory per unit until then.
- **DT-3 PREACT validation** blocks moving this unit to the pilot/deployment image;
  it is the genuine remaining firmware risk in the "physical activation loop"
  (coord §C57.2). Do it before any real rollator *ships*.

# Playbook — Bring up a new PRODUCTION unit

> **Scope:** Provision a real, shippable GoSteady unit into **prod** and get it
> to `ready_to_provision` with a D2C claim link, ready for firmware flash + a
> real household claim. Prod analogue of
> [`new-dev-unit-bringup.md`](new-dev-unit-bringup.md); read that for the shared
> mechanics (cert store, SW2 caution, flash_cert, SIM notes) — this doc covers
> only the **prod deltas** and the **D2C walkerId/QR** step.
>
> **Cloud side is scripted:** [`tools/bringup-prod-unit.sh`](../../tools/bringup-prod-unit.sh).
> It is idempotent-safe and reusable — device #1 and device #1000 use the same path.

---

## What's different from the dev bring-up (3 things)

1. **Prod IoT resources.** `gosteady-prod-device-policy`, table `gosteady-prod-devices`,
   thing types `GoSteadyRollatorPlatform-prod` / `GoSteadyWalkerCap-prod`.
   **The IoT endpoint is UNCHANGED** (`a2dl73jkjzv6h5-ats.iot.us-east-1.amazonaws.com`)
   — prod is the *same* AWS account (460223323193) as dev, so the broker is shared.
   Isolation is downstream: each env's processor only acts on serials in **its own**
   registry and drops "unmapped" serials, so a serial that lives only in the prod
   registry is handled by prod and ignored by dev (coord §C57). Use a **fresh serial**
   that has never been in the dev registry.

2. **No `activated_at` shortcut.** Dev writes `activated_at` directly to skip the
   activate flow. **Prod must NOT** — shipping units go through the formal
   `ready_to_provision → provisioned → active_monitoring` path. For D2C, the
   household's **claim** drives provision + the activate cmd. Writing `activated_at`
   by hand defeats the audit trail + pre-activation alert suppression.

3. **Server-minted walkerId + QR/claim-link.** The device row is created through the
   **internal_admin bulk-create Lambda** (`device-api::_action_admin_create`), which
   now CSPRNG-mints an opaque UUIDv4 `walkerId` (QR-provisioning spec §4, "the
   load-bearing change") into the sparse `by-walker-id` GSI. The QR encodes
   `https://app.gosteady.co/setup/{walkerId}` — never the `GS##########` serial.
   *Deferred for the first units (fleet-only):* printed short-code fallback + its
   GSI, and claim-binding-to-buyer-phone (QR spec §2-3).

---

## Choosing a prod serial

The `GS##########` serial is baked into firmware (client_id) and is the manufacturing
anchor. Prod serials must be **distinct from the dev/test ranges** so they can't
collide on the shared broker:

| Range | Use |
|---|---|
| `GS9999999980`–`GS9999999999` | dev/test fixtures (walker + rollator bench) — **never prod** |
| `GS0000000001`–`GS0000000003` | first three facility pilot walkers (used) |
| `GS0000000004`+ | facility/walker shipping |
| `GS0002000001`+ | **prod D2C rollators** — allocate sequentially (first allocations `GS0002000001`–`GS0002000005`, 2026-07) |

> **Block decision (recorded 2026-07-17):** prod D2C rollators allocate
> sequentially from `GS0002000001` — visually distinct from facility `GS0000…`
> and the dev/test `GS9999…` ranges. Never reuse a walkerId/serial across units
> (the sparse GSI must stay collision-free).

---

## Pre-reqs

- Prod stacks deployed (Security…Api, Ingestion — all `CREATE_COMPLETE`).
- `aws sts get-caller-identity` → account `460223323193` (the script guards this).
- **For the QR / claim to actually work:** `app.gosteady.co` DNS + ACM must resolve
  live (see [move-to-prod §C57.3 #4]) and `gosteady/prod/twilio` must be populated
  (SMS-OTP sign-up). Cloud provisioning below works without these; the *claim test*
  needs them.
- **Register each Onomondo SIM on the carrier side BEFORE the firmware flash.** An
  unregistered Onomondo SIM presents at the bench as *undetectable* — `AT%XSIM: 0`
  and `AT+CPIN?`/`AT%XICCID`/`AT+CIMI` all `ERROR` (looks like a seating fault, but
  it isn't). Once activated on Onomondo it reads normally and attaches (roaming,
  AT&T LTE-M) in ~30 s. Activation can lag a few minutes to propagate, so kick it
  off early. (Bit us on GS0002000002 — coord §C59.3.) The SIM and the baked
  cert/serial are independent — any registered Onomondo SIM works in any board.

---

## Run it

```bash
./tools/bringup-prod-unit.sh <SERIAL> [rollator_platform|walker_cap] [hardwareVariant]
# e.g.
./tools/bringup-prod-unit.sh GS0002000001 rollator_platform thingy91x_bench
```

The script: guards the account + fresh Thing → mints cert/key (bundle at
`~/Desktop/gosteady-prod-cert-handoff/<serial>/`) → creates the Thing + attaches the
prod policy → **creates the row + mints the walkerId server-side** → renders a QR
(`qrencode` or `pip install qrcode[pil]`, best-effort) → verifies the registry row →
prints the **firmware handoff** + the **claim URL**.

---

## Firmware handoff (bench — the physical half)

**Rollator:** follow **[`rollator-firmware-flash.md`](rollator-firmware-flash.md)** —
it covers the two decisions (which physical unit → serial; which build overlay,
with the PREACT-validation caveat), the cert flash (with the prod-bundle root-CA
gotcha), the serial-baked rebuild, and the prod-side first-heartbeat +
claim→activate verification. In short: `flash_cert.py` (cert → sec_tag 201) →
`west build … -DCONFIG_AWS_IOT_CLIENT_ID_STATIC="<SERIAL>"` → `nrfjprog … --chiperase`
→ confirm the heartbeat lands in the prod Shadow. Walker units follow
[new-dev-unit-bringup.md §3](new-dev-unit-bringup.md#phase-3--firmware-side-flash)
with the prod cert bundle.

---

## Full-flow claim test (the DT-5 exit bar)

With `app.gosteady.co` live + `gosteady/prod/twilio` populated:

1. Open the claim URL (`https://app.gosteady.co/setup/{walkerId}`) on a real phone.
2. Phone-first SMS-OTP sign-up → **claim** → provisions the device (status →
   `provisioned`) + fires the activate cmd → device exits pre-activation.
3. Walk → session auto-starts on motion → activity uplink → **dashboard** shows the
   rollator session (active-min / distance / gait — no steps).

That claim→activate→walk→dashboard loop, on a real prod device, is the first real
activation (coord §C57.3 #5).

---

## Decommission (recycle a prod serial)

Same shape as [new-dev-unit-bringup.md §Decommissioning](new-dev-unit-bringup.md#decommissioning-a-dev-unit)
but against `gosteady-prod-*` (detach principal/policy → INACTIVE + delete cert →
delete Thing → delete registry row → delete bundle dir). A recycled serial keeps its
old walkerId out of the GSI (the row is gone); a re-bringup mints a **new** walkerId.

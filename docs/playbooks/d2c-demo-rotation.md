# Playbook — D2C demo device rotation (pilot operator)

> **Scope:** rotating the ~5 physical rollator units between demo/pilot
> participants who never purchased them. Implements [d2c-claim-binding.md
> §5.11](../specs/d2c-claim-binding.md). Every unit is **reserved for a
> specific phone** before its participant scans the QR, so a claim always
> lands on the intended person — never on whoever scans first (the pilot
> "leaked-QR land-grab").
>
> Two operator surfaces, same audited `device-api`:
> - **CLI** — [`tools/fleet.py`](../../tools/fleet.py) (`bind` / `rotate` / `ready`).
> - **Fleet screen** — `dev.portal.gosteady.co/fleet` → the `⋯` menu
>   ("Rotate to next participant…" / "Bind to participant…").
>
> Setup + auth are identical to [`device-fleet-ops.md`](device-fleet-ops.md)
> (paste an internal_admin `id_token`; `fleet ls` to confirm).

---

## The mental model (read once)

A hand-off is **two halves**:

1. **Targeting** — *who* may claim next. Set by reserving the device to the
   next participant's phone (`claimBoundPhone`). Only that phone's **verified**
   account passes the claim.
2. **State** — *when* it's claimable. A rotated-out device fires a **wipe** and
   is not claimable again until firmware **acks the wipe** and it recycles to
   `ready_to_provision`. **This is not instant** — the unit must be powered and
   in LTE range to ack.

The golden rule: **reserve every unit before its participant arrives**, so the
wipe-ack wait happens off the critical path, not while someone waits to scan.

---

## Before the demo (pre-stage all units)

For each unit + its assigned participant's phone:

```bash
./tools/fleet.py ls                       # see the fleet + reservations
./tools/fleet.py bind GS00000000XX --phone +15125550100
```

Confirm every unit shows **`reserved •••-1234`** (fleet screen) or in the CLI
board. A unit still showing **`open (unbound)`** is claimable by anyone — bind
it. Then verify each is claimable *now*:

```bash
./tools/fleet.py ready GS00000000XX       # expects ready_to_provision, healthy
```

> Fresh-from-manufacturer units are already `ready_to_provision` + unowned, so
> `bind` is all they need. A unit returning from a *previous* participant must
> finish its wipe-ack recycle first (see rotation below).

---

## During the demo — one participant to the next

**If the unit is fresh / already idle** (never claimed, or already recycled):
it's reserved from pre-staging. The participant scans the QR → the `/setup`
page shows **"Set up this rollator for the phone ending in •••-1234?"** → they
verify by SMS and claim. Done.

**To hand a unit from participant A to participant B** — one command:

```bash
# --patient is A's patientId (from `fleet status GS…`); discharging it stops
# stale "low activity" alerts firing at A after hand-off.
./tools/fleet.py rotate GS00000000XX --phone +1512555NEW --patient pat_d2c_…
```

or Fleet screen → `⋯` → **"Rotate to next participant…"** → type B's phone.

This chains: **end assignment (fires wipe) → discharge A's patient → atomic
release + reserve-for-B**. B cannot claim until the unit acks the wipe:

```bash
./tools/fleet.py ready GS00000000XX       # wait for "wipe?" to clear → ready
```

Then B scans, verifies, claims. If you're rotating between back-to-back
participants, **rotate the outgoing unit the moment A finishes** and hand B a
*different, already-reserved* unit — don't make B wait on the wipe-ack.

---

## When something goes wrong

| Symptom | What happened | Fix |
|---|---|---|
| Participant's scan says **"reserved for •••-XXXX"** with the **wrong** last-4 | Bound to the wrong phone | `fleet bind GS… --phone +1…correct` (re-bind; allowed while unowned) |
| Scan says **"reserved for a different phone"** / claim gives **403** | Participant's account phone ≠ bound phone, or their phone isn't SMS-verified | Confirm the phone; re-bind to the phone they actually used, or have them sign in with the bound number |
| Claim gives **409 "already set up"** | Unit is still `discontinued` — **wipe not acked yet** | `fleet ready GS…`; if the unit is powered + in range, wait for the ack. Hand them a pre-reserved spare meanwhile. |
| Unit **stuck** `discontinued` for >a few min, `wipe?` won't clear | Unit was off/dead past its wipe window; the cloud **re-issues** the wipe on its next connect (§5.6) | Power-cycle the unit so it reconnects. Last resort: `fleet reset GS…` (force-reset — **skips wipe verification**, so the unit may still hold prior data; audited). |
| Claim gives **409 DEVICE_OWNED** | A previous participant still *owns* it (you ran `end` but not `rotate`/`release`) | `fleet rotate GS… --phone +1…` (or `fleet bind` after a `release`) |
| **No-show** after you reserved a unit | Reservation has no expiry | Leave it (it stays reserved), `fleet bind GS… --clear` to free it, or re-bind to the next person |
| OTP text never arrives | Twilio/SMS issue at the venue | Pre-demo: send yourself a test OTP. See [`d2c-twilio-setup.md`](d2c-twilio-setup.md). |

**Never** use `fleet release` (bare) mid-demo unless you mean **open
self-claim** — it drops the reservation and anyone with the QR can grab the
unit. `rotate` is the safe hand-off; `release` is the deliberate "make this
open to anyone" lever (and the CLI/UI both warn).

---

## After the demo

- Units you want to keep reserved: leave them.
- Units returning to the shelf: `fleet bind GS… --clear` (or decommission per
  [`device-fleet-ops.md`](device-fleet-ops.md) if a unit is broken).
- Every action here is audited (`device.claim_bound`, `device.ownership_released`,
  `device.assignment_ended`, `d2c.claim_rejected_*`) — the trail is the record
  of who held which unit when.

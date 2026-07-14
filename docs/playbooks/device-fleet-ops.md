# Playbook — Device fleet ops (pilot operator)

> **Scope:** day-to-day operation of the live device fleet during the D2C
> rollator pilot — see every device, diagnose a stuck one, and safely set up /
> reset units between users. The tool is [`tools/fleet.py`](../../tools/fleet.py);
> design + decisions in [`docs/specs/device-fleet-ops-tooling.md`](../specs/device-fleet-ops-tooling.md).
>
> `fleet.py` calls the **audited `device-api` endpoints** — it never writes
> DDB/IoT directly, so every action lands in the audit trail and respects the
> lifecycle state machine.

---

## Setup (once)

```bash
# 1. Auth — paste an internal_admin id_token (from an authenticated browser
#    session: DevTools → Application → Cognito idToken). This is the reliable
#    path when internal accounts enforce MFA (see spec D2/A2).
export GOSTEADY_TOKEN='eyJ...'
export GOSTEADY_ENV=dev            # or prod
# API base auto-resolves from the {Env}-PortalApiUrl CFN output; override with
# export GOSTEADY_API_BASE=https://xxxx.execute-api.us-east-1.amazonaws.com

# (dev / non-MFA alternative — auto-mint instead of pasting a token:)
# export GOSTEADY_USER=ops@gosteady.co GOSTEADY_PASS=... \
#        GOSTEADY_CLIENT_ID=<Portal-Customer client id>

./tools/fleet.py ls        # confirm auth works
```

`fleet.py` is stdlib-only; it shells out to the `aws` CLI for token auto-mint,
API-base resolution, and the audit timeline. No `pip install`.

### Token-free reads (`--direct`) — the fast path for prod / demos
If the target pool has no `internal_admin` user yet (e.g. the prod facility
pool), skip the token entirely for **reads** — `--direct` reads the registry +
Shadows via your AWS creds:
```bash
./tools/fleet.py --direct --env prod ls
./tools/fleet.py --direct --env prod status GS0002000001
./tools/fleet.py --direct --env prod check GS0002000001 --expect-type rollator_platform
```
`--direct` covers `ls`/`status`/`check`/`ready` only. **Writes** (provision / end
/ reset / …) always go through the audited API, so they need the token above.
(needs `boto3`.)

### Enabling writes — one-time internal user
Writes go through the Cognito-authorized API, so they need an `internal_admin`
user (IAM creds can't call it). A working internal token needs three things —
a Cognito user, `custom:mfa_enrolled=true`, and a `RoleAssignments` row (the
token's `custom:role`/`custom:clientId` come from that row). The script does all
three + verifies:
```bash
./tools/create-internal-user.sh ops@gosteady.co prod internal_admin
# creates the user, prompts for a password, writes the RoleAssignments row,
# then mints a token and prints the decoded role claim to prove it works.
```
Then export the auto-mint env it prints (`GOSTEADY_USER/PASS/CLIENT_ID`) and the
CLI mints a fresh token per run — `fleet reset GS…` etc. work.

⚠ **MFA is attribute-based today** (real TOTP enrollment is Phase-2B — see the
script header). The `custom:mfa_enrolled=true` attribute satisfies the current
Pre-Token gate but isn't a real second factor yet. Fine for a controlled pilot;
harden before wider internal access.

---

## The pilot loop

### 1. Bring up + flash a unit
Cloud side: [`new-prod-unit-bringup.md`](new-prod-unit-bringup.md)
(`tools/bringup-prod-unit.sh`). Firmware: [`rollator-firmware-flash.md`](rollator-firmware-flash.md).
This tool does **not** replace those — it starts where they end.

### 2. Pre-ship gate (don't ship a dead unit)
```bash
./tools/fleet.py check GS0002000001 --expect-type rollator_platform
```
Asserts: `ready_to_provision` · has connected (shadow present) · heartbeat
recently · deviceType matches · `walkerId` present (QR resolvable) · battery ≥10%.
**Ship only on `GO ✓`.**

### 3. Hand off / activation
The household claims via QR → SMS-OTP → `POST /claim` provisions + fires activate.
Watch it land (great to run live on a handoff call):
```bash
./tools/fleet.py status GS0002000001
```
Look for `status: active_monitoring`, a fresh `lastSeen`, and `activated_at` set.
If it sticks in `provisioned`, see **Troubleshooting**.

### 4. Monitor (steady state)
```bash
./tools/fleet.py ls                     # the board: status/battery/last-seen/patient
./tools/fleet.py ls --status active_monitoring
```
Passive glance: the **`gosteady-{env}-fleet-health`** CloudWatch dashboard
(battery / who's-reporting / signal / stuck-in-provisioned / stuck-wipe across
all units — new units appear automatically).

### 5. Reset between users (the core recycle)
```bash
# a. End the current assignment — fires the wipe cmd automatically.
./tools/fleet.py end GS0002000001 --reason pilot_rotation

# b. The device auto-recycles to ready_to_provision once firmware acks the wipe.
#    Confirm it's genuinely safe for the NEXT user (status + wipe-verified +
#    battery + actually-alive):
./tools/fleet.py ready GS0002000001
```
`ready` is the guard against handing User B a device still mid-recycle or still
holding User A's cached data — it fails if the wipe hasn't been acked.

**Same household again?** On `GO ✓`, just re-provision it (`fleet provision GS… --patient …`,
or the **Provision** button). Ownership stays with the household — that's by design
(end/recycle deliberately keep ownership).

**Rotating to a DIFFERENT household?** End alone is *not* enough — the device stays
registered to the old household, and the new household's QR claim will hit
"already registered to …". You must also **release ownership**:
```bash
./tools/fleet.py end GS0002000001 --release --reason pilot_rotation   # end + release in one go
# or, if already ended/idle:
./tools/fleet.py release GS0002000001
```
On the fleet screen this is the **"End + release (rotate)"** / **"Release ownership (rotate)"**
menu item. After release the device returns to the unowned pool; once it recycles to
`ready_to_provision`, the same QR sticker (`walkerId` persists) is claimable by the new
household. Wipe-before-reuse still holds — a new household can't claim until the wipe-ack
lands the device in `ready_to_provision`.

### 6. Stuck device (wipe never acked)
A unit returned powered-off / dead-battery / out-of-coverage never acks the wipe
and sits in `discontinued` (`FLAGS: wipe?` on the board). Swap batteries / power
it on if you can; otherwise force it:
```bash
./tools/fleet.py reset GS0002000001      # admin override → ready_to_provision (audited)
```

### 7. End of life
```bash
./tools/fleet.py decommission GS0002000001 --reason broken   # or lost | retired | end_of_life
./tools/fleet.py recover GS0002000001                        # only for reason=lost
```

---

## Troubleshooting

| Symptom | Command | What to look for |
|---|---|---|
| "App shows no data" | `fleet status GS…` | `status` (should be `active_monitoring`), fresh `lastSeen`, an active `assignment.patient`. Stale `lastSeen` → device offline (check SIM/coverage). |
| Won't activate (stuck) | `fleet status GS…` | `pending: activation outstanding` + old `lastSeen` → device never received/acked the activate cmd. Re-fire: `fleet provision` again (idempotent), or check it's online. |
| Won't recycle after end | `fleet ready GS…` | `wipe pending` → firmware hasn't acked. Power it on; else `fleet reset`. |
| Whole fleet health | `fleet ls` + dashboard | `FLAGS` column (`wipe?`/`act?`), battery, last-seen age. |
| Who touched this device | `fleet status GS…` | the audit **timeline** at the bottom (claimed → assigned → activated → …). |

**External dead-ends (not this tool):** a device that won't connect at all is
usually the **SIM** (Onomondo/iBasis activation + coverage) — start at the SIM
dashboard. Sign-up failures are **Twilio** OTP delivery. Firmware version is
ambiguous from telemetry (`rol-0.1.0-bench` = 3 builds) — track which image is on
which unit out-of-band.

---

## Notes / limits (v1)

- **Deferred:** operator push-alerts (silent/battery/stuck → Slack/SMS), asset
  labels (who has which unit), live-`watch`, and a browser UI. See the spec's
  *Out of Scope*.
- **Writes** need an `internal_admin` token; **`internal_support`** can run the
  read commands (`ls`/`status`/`check`/`ready`) only.
- The **timeline** reads the `device-api` CloudWatch log group directly (needs
  `logs:FilterLogEvents`); everything else goes through the API.

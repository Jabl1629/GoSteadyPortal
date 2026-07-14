#!/usr/bin/env python3
"""
fleet.py — GoSteady internal device fleet ops CLI (pilot operator tool).

A thin, dependency-free CLI over the audited `device-api` endpoints. It answers
the three questions a pilot operator asks all day:

    what's the whole fleet doing?     fleet ls
    what's wrong with this one?        fleet status GS0002000001
    is it safe to ship / reuse?        fleet check GS...   /   fleet ready GS...

...and wraps the lifecycle commands (provision / end / reset / decommission /
recover) so they go through the API — preserving state-machine validation,
audit emission, and the Shadow desired-state invariants. NEVER writes DDB/IoT
directly. Spec: docs/specs/device-fleet-ops-tooling.md.

────────────────────────────────────────────────────────────────────────────
AUTH (important — see spec D2):
  The device-api authorizer only accepts tokens from the **Portal-Customer**
  Cognito app client. Authenticate as an `internal_admin` user one of two ways:

    1. Paste an id_token you already have (e.g. from an authenticated browser
       session — DevTools → Application → the Cognito idToken):
         export GOSTEADY_TOKEN='eyJ...'
    2. Best-effort auto-mint (dev / non-MFA users only):
         export GOSTEADY_USER='ops@gosteady.co'
         export GOSTEADY_PASS='...'
         export GOSTEADY_CLIENT_ID='<Portal-Customer client id>'
       (If the account enforces MFA, auto-mint bails — use option 1.)

DIRECT MODE (token-free reads):
  `--direct` reads the registry + Shadows directly via your AWS creds — no
  token, no Cognito user needed. Applies to ls/status/check/ready only; writes
  still go through the audited API. Great for `--env prod` when the prod pool
  has no internal user yet:  ./fleet.py --direct --env prod ls

CONFIG (env vars, all overridable by flags):
  GOSTEADY_ENV        dev | prod            (default: dev; or --env)
  GOSTEADY_API_BASE   https://xxx.execute-api...  (default: resolved from the
                      {Env}-PortalApiUrl CloudFormation output via `aws`)
  GOSTEADY_TOKEN      internal id_token (see AUTH)
  AWS_REGION          (default: us-east-1)

Requires: python3 (stdlib only) + the `aws` CLI on PATH (used for token
auto-mint, API-base resolution, and the audit timeline).
────────────────────────────────────────────────────────────────────────────
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone
from typing import Any

REGION = os.environ.get("AWS_REGION", "us-east-1")
ENV = os.environ.get("GOSTEADY_ENV", "dev")

# Health thresholds (operator-tunable via flags on check/ready).
DEFAULT_MAX_SEEN_AGE_S = 24 * 3600  # "recently seen" window
DEFAULT_MIN_BATTERY = 0.10          # sanity floor (matches the recycle DL floor)


# ── Pure helpers (unit-tested in tools/test_fleet.py) ───────────────────


def _as_float(v: Any) -> float | None:
    """Coerce a battery/number value (DDB Decimals arrive as strings) to float."""
    if v is None:
        return None
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def age_seconds(iso: Any, *, now: datetime | None = None) -> int | None:
    """Whole seconds since an ISO-8601 UTC timestamp; None if unparseable."""
    if not iso:
        return None
    now = now or datetime.now(timezone.utc)
    try:
        t = datetime.fromisoformat(str(iso).replace("Z", "+00:00"))
    except (ValueError, TypeError):
        return None
    if t.tzinfo is None:
        t = t.replace(tzinfo=timezone.utc)
    return max(0, int((now - t).total_seconds()))


def fmt_age(seconds: int | None) -> str:
    """Human age: '—' / '12s' / '4m' / '3h' / '2d'."""
    if seconds is None:
        return "—"
    if seconds < 60:
        return f"{seconds}s"
    if seconds < 3600:
        return f"{seconds // 60}m"
    if seconds < 86400:
        return f"{seconds // 3600}h"
    return f"{seconds // 86400}d"


def short_type(device_type: Any) -> str:
    return {"rollator_platform": "rollator", "walker_cap": "walker"}.get(
        str(device_type or ""), str(device_type or "?")
    )


def check_assertions(
    row: dict[str, Any],
    *,
    expect_type: str | None = None,
    max_seen_age_s: int = DEFAULT_MAX_SEEN_AGE_S,
    now: datetime | None = None,
) -> list[tuple[str, bool, str]]:
    """
    PRE-SHIP health gate: is a freshly-flashed unit safe to send to a user?

    Returns [(check_name, ok, detail)]. Pure — testable with a fixed `now`.
    """
    tele = row.get("telemetry") or {}
    seen_age = age_seconds(tele.get("lastSeen"), now=now)
    batt = _as_float(tele.get("batteryPct"))
    out: list[tuple[str, bool, str]] = []

    out.append((
        "status is ready_to_provision",
        row.get("status") == "ready_to_provision",
        f"status={row.get('status')}",
    ))
    out.append((
        "device has connected (has shadow telemetry)",
        bool(tele),
        "shadow present" if tele else "no shadow — never connected",
    ))
    out.append((
        f"heartbeat within {fmt_age(max_seen_age_s)}",
        seen_age is not None and seen_age <= max_seen_age_s,
        f"lastSeen {fmt_age(seen_age)} ago" if seen_age is not None else "never seen",
    ))
    if expect_type:
        out.append((
            f"deviceType == {expect_type}",
            row.get("deviceType") == expect_type,
            f"deviceType={row.get('deviceType')}",
        ))
    out.append((
        "walkerId present (QR resolvable)",
        bool(row.get("walkerId")),
        f"walkerId={row.get('walkerId') or '—'}",
    ))
    if batt is not None:
        out.append((
            "battery healthy (≥10%)",
            batt >= DEFAULT_MIN_BATTERY,
            f"battery={batt:.0%}",
        ))
    return out


def ready_assertions(
    row: dict[str, Any],
    *,
    max_seen_age_s: int = DEFAULT_MAX_SEEN_AGE_S,
    min_battery: float = DEFAULT_MIN_BATTERY,
    now: datetime | None = None,
) -> list[tuple[str, bool, str]]:
    """
    READY-FOR-NEXT-USER gate: safe to hand this unit to the next pilot user?

    The core guard against handing User B a device still mid-recycle or still
    holding User A's cached data. Pure — testable with a fixed `now`.
    """
    tele = row.get("telemetry") or {}
    seen_age = age_seconds(tele.get("lastSeen"), now=now)
    batt = _as_float(tele.get("batteryPct"))
    was_owned = bool(row.get("owningClientId"))  # went through a prior user
    out: list[tuple[str, bool, str]] = []

    out.append((
        "recycled to ready_to_provision",
        row.get("status") == "ready_to_provision",
        f"status={row.get('status')}",
    ))
    out.append((
        "no wipe pending (recycle completed)",
        not row.get("wipePending"),
        "wipe pending — not yet acked; force-reset if device won't come online"
        if row.get("wipePending") else "clear",
    ))
    out.append((
        "no activation pending",
        not row.get("activationPending"),
        "activation still outstanding" if row.get("activationPending") else "clear",
    ))
    # Wipe verification: only meaningful for a previously-owned unit. A fresh,
    # never-provisioned unit has no wipe_complete (nothing to wipe) and is
    # trivially safe.
    if was_owned:
        out.append((
            "wipe verified (firmware acked a wipe)",
            bool(tele.get("wipeComplete")),
            f"wipe_complete={tele.get('wipeComplete') or '— (unverified!)'}",
        ))
    out.append((
        f"seen within {fmt_age(max_seen_age_s)} (actually alive)",
        seen_age is not None and seen_age <= max_seen_age_s,
        f"lastSeen {fmt_age(seen_age)} ago" if seen_age is not None else "never seen",
    ))
    if batt is not None:
        out.append((
            f"battery ≥ {min_battery:.0%}",
            batt >= min_battery,
            f"battery={batt:.0%}",
        ))
    return out


# ── Config resolution + HTTP ────────────────────────────────────────────


def _aws(args: list[str]) -> str:
    """Run an `aws` CLI command, return stdout. Raises SystemExit on failure."""
    try:
        res = subprocess.run(
            ["aws", *args, "--region", REGION, "--output", "json"],
            capture_output=True, text=True, check=True,
        )
        return res.stdout
    except FileNotFoundError:
        _die("`aws` CLI not found on PATH (needed for token mint / API-base / timeline).")
    except subprocess.CalledProcessError as exc:
        _die(f"aws {' '.join(args[:2])} failed: {exc.stderr.strip() or exc.stdout.strip()}")


def _resolve_base(explicit: str | None) -> str:
    base = explicit or os.environ.get("GOSTEADY_API_BASE")
    if base:
        return base.rstrip("/")
    # Fall back to the CloudFormation output.
    stack = f"GoSteady-{ENV.capitalize()}-Api"
    out = _aws([
        "cloudformation", "describe-stacks", "--stack-name", stack,
        "--query", "Stacks[0].Outputs[?ExportName=='" + f"{ENV}-PortalApiUrl" + "'].OutputValue",
    ])
    try:
        vals = json.loads(out)
        if vals:
            return str(vals[0]).rstrip("/")
    except (json.JSONDecodeError, IndexError):
        pass
    _die(
        "Could not resolve the API base URL. Set GOSTEADY_API_BASE or pass "
        "--api-base (e.g. https://xxxx.execute-api.us-east-1.amazonaws.com)."
    )


def _get_token(explicit: str | None) -> str:
    tok = explicit or os.environ.get("GOSTEADY_TOKEN")
    if tok:
        return tok.strip().removeprefix("Bearer ").strip()
    # Best-effort auto-mint (USER_PASSWORD_AUTH on the Portal-Customer client).
    user = os.environ.get("GOSTEADY_USER")
    pw = os.environ.get("GOSTEADY_PASS")
    client_id = os.environ.get("GOSTEADY_CLIENT_ID")
    if not (user and pw and client_id):
        _die(
            "No internal token. Set GOSTEADY_TOKEN (paste an internal id_token), "
            "or GOSTEADY_USER/GOSTEADY_PASS/GOSTEADY_CLIENT_ID to auto-mint. See "
            "`fleet.py --help` AUTH."
        )
    out = _aws([
        "cognito-idp", "initiate-auth",
        "--auth-flow", "USER_PASSWORD_AUTH",
        "--client-id", client_id,
        "--auth-parameters", f"USERNAME={user},PASSWORD={pw}",
    ])
    try:
        data = json.loads(out)
    except json.JSONDecodeError:
        _die("Unexpected cognito response during auto-mint.")
    if "ChallengeName" in data:
        _die(
            f"Cognito returned a challenge ({data['ChallengeName']}) — likely MFA. "
            "Auto-mint can't complete it; paste a token via GOSTEADY_TOKEN instead."
        )
    tok = (data.get("AuthenticationResult") or {}).get("IdToken")
    if not tok:
        _die("Auto-mint returned no IdToken.")
    return tok


def _shape_row(
    device: dict[str, Any],
    telemetry: dict[str, Any] | None,
    assignment: dict[str, Any] | None,
) -> dict[str, Any]:
    """
    Shape a raw registry item (+ joined live state) into a fleet row — the
    client-side mirror of the backend `_fleet_row` (device-api/handler.py), used
    by --direct mode so its output is identical to the API's. Pure/testable.
    """
    keep = (
        "serialNumber", "status", "deviceType", "hardwareVariant",
        "owningClientId", "owningFacilityId", "walkerId",
        "activated_at", "firstHeartbeatAt", "lastTransitionAt",
        "wipe_requested_at", "decommissionReason", "decommissionedAt",
    )
    row = {k: v for k, v in device.items() if k in keep}
    row.setdefault("deviceType", "walker_cap")
    oa = device.get("outstandingActivationCmds") or {}
    ow = device.get("outstandingWipeCmds") or {}
    row["outstandingActivationCmds"] = oa
    row["outstandingWipeCmds"] = ow
    row["activationPending"] = bool(oa) and row.get("status") == "provisioned"
    row["wipePending"] = bool(ow)
    if telemetry is not None:
        row["telemetry"] = telemetry
    if assignment is not None:
        row["currentAssignment"] = assignment
    return row


class _DirectSource:
    """
    Token-free read path: scan the `gosteady-{env}-devices` registry + join
    Shadows/assignments directly via boto3 (ambient AWS creds). Duck-types
    `_Client` for `GET /admin/devices` only — writes are refused (they must go
    through the audited API so the state machine + audit + Shadow invariants
    hold). Spec D3 / playbook.
    """

    _FIELD_MAP = {
        "battery_pct": "batteryPct", "battery_mv": "batteryMv",
        "rsrp_dbm": "rsrpDbm", "snr_db": "snrDb", "firmware": "firmware",
        "ts": "lastSeen", "wipe_complete": "wipeComplete",
        "activated_at": "reportedActivatedAt", "last_cmd_id": "lastCmdId",
    }

    def __init__(self, env: str) -> None:
        try:
            import boto3  # lazy: only --direct needs it
        except ImportError:
            _die("--direct needs boto3 (`pip install boto3`), or use the API/token path.")
        self.ddb = boto3.resource("dynamodb", region_name=REGION)
        self.iot = boto3.client("iot-data", region_name=REGION)
        self.devices = self.ddb.Table(f"gosteady-{env}-devices")
        self.assignments = self.ddb.Table(f"gosteady-{env}-device-assignments")

    def request(self, method: str, path: str, body: dict[str, Any] | None = None) -> Any:
        if method != "GET" or not path.startswith("/api/v1/admin/devices"):
            _die("--direct is read-only (ls/status/check/ready). Writes go through the "
                 "audited API — drop --direct and set GOSTEADY_TOKEN.")
        status_f = type_f = None
        if "?" in path:
            from urllib.parse import parse_qs, urlparse
            q = parse_qs(urlparse(path).query)
            status_f = (q.get("status") or [None])[0]
            type_f = (q.get("deviceType") or [None])[0]
        rows: list[dict[str, Any]] = []
        scan_kwargs: dict[str, Any] = {}
        while True:
            res = self.devices.scan(**scan_kwargs)
            for d in res.get("Items", []):
                if status_f and d.get("status") != status_f:
                    continue
                if type_f and (d.get("deviceType") or "walker_cap") != type_f:
                    continue
                serial = d.get("serialNumber", "")
                rows.append(_shape_row(d, self._shadow(serial), self._assignment(serial, d)))
            lek = res.get("LastEvaluatedKey")
            if not lek:
                break
            scan_kwargs["ExclusiveStartKey"] = lek
        rows.sort(key=lambda r: (str(r.get("status", "")), str(r.get("serialNumber", ""))))
        return {"devices": rows, "count": len(rows)}

    def _shadow(self, serial: str) -> dict[str, Any] | None:
        try:
            r = self.iot.get_thing_shadow(thingName=serial)
            rep = json.loads(r["payload"].read()).get("state", {}).get("reported", {}) or {}
        except self.iot.exceptions.ResourceNotFoundException:
            return None
        except Exception:  # noqa: BLE001 — telemetry is best-effort
            return None
        out = {camel: rep[snake] for snake, camel in self._FIELD_MAP.items() if snake in rep}
        return out or None

    def _assignment(self, serial: str, device: dict[str, Any]) -> dict[str, Any] | None:
        sk = device.get("currentAssignmentSk")
        if not sk:
            return None
        try:
            a = self.assignments.get_item(
                Key={"serialNumber": serial, "assignedAt": sk}).get("Item")
        except Exception:  # noqa: BLE001
            return None
        if not a:
            return None
        return {"patientId": a.get("patientId"), "facilityId": a.get("facilityId"),
                "censusId": a.get("censusId"),
                "startedAt": a.get("validFrom") or a.get("assignedAt")}


class _Client:
    def __init__(self, base: str, token: str) -> None:
        self.base = base
        self.token = token

    def request(self, method: str, path: str, body: dict[str, Any] | None = None) -> Any:
        url = f"{self.base}{path}"
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(url, data=data, method=method)
        req.add_header("Authorization", f"Bearer {self.token}")
        req.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                return json.loads(resp.read() or b"{}")
        except urllib.error.HTTPError as exc:
            raw = exc.read().decode(errors="replace")
            try:
                err = json.loads(raw).get("error", {})
                code, msg = err.get("code", "?"), err.get("message", raw)
            except json.JSONDecodeError:
                code, msg = str(exc.code), raw
            if exc.code == 401:
                _die(f"401 {code}: {msg}\n(Token expired/invalid — refresh GOSTEADY_TOKEN.)")
            _die(f"API {exc.code} {code}: {msg}")
        except urllib.error.URLError as exc:
            _die(f"Network error calling {url}: {exc.reason}")


def _timeline(serial: str, limit: int = 20) -> list[dict[str, Any]]:
    """Best-effort audit timeline for a serial from the device-api log group."""
    lg = f"/aws/lambda/gosteady-{ENV}-device-api"
    try:
        out = _aws([
            "logs", "filter-log-events",
            "--log-group-name", lg,
            "--filter-pattern", f'"{serial}"',
            "--query", "events[].message",
        ])
        msgs = json.loads(out)
    except SystemExit:
        return []
    events: list[dict[str, Any]] = []
    for m in msgs:
        try:
            rec = json.loads(m)
        except (json.JSONDecodeError, TypeError):
            continue
        if rec.get("audit") is True and rec.get("event", "").startswith("device."):
            events.append(rec)
    events.sort(key=lambda e: e.get("timestamp", ""))
    return events[-limit:]


# ── Output ──────────────────────────────────────────────────────────────


def _die(msg: str) -> None:
    print(f"error: {msg}", file=sys.stderr)
    raise SystemExit(1)


def _print_table(rows: list[dict[str, Any]]) -> None:
    hdr = f"{'SERIAL':<12} {'TYPE':<8} {'STATUS':<18} {'BATT':>5} {'SEEN':>5}  {'PATIENT':<20} FLAGS"
    print(hdr)
    print("-" * len(hdr))
    for r in rows:
        tele = r.get("telemetry") or {}
        batt = _as_float(tele.get("batteryPct"))
        seen = fmt_age(age_seconds(tele.get("lastSeen")))
        assignment = r.get("currentAssignment") or {}
        patient = assignment.get("patientId") or "—"
        flags = []
        if r.get("wipePending"):
            flags.append("wipe?")
        if r.get("activationPending"):
            flags.append("act?")
        if (r.get("decommissionReason")):
            flags.append(str(r.get("decommissionReason")))
        print(
            f"{r.get('serialNumber',''):<12} {short_type(r.get('deviceType')):<8} "
            f"{str(r.get('status','')):<18} {(f'{batt:.0%}' if batt is not None else '—'):>5} "
            f"{seen:>5}  {str(patient):<20} {','.join(flags)}"
        )
    print(f"\n{len(rows)} device(s).")


def _print_gate(title: str, serial: str, checks: list[tuple[str, bool, str]]) -> int:
    print(f"{title}: {serial}\n")
    all_ok = True
    for name, ok, detail in checks:
        mark = "✓" if ok else "✗"
        all_ok = all_ok and ok
        print(f"  [{mark}] {name}"+(f"  ({detail})" if detail else ""))
    verdict = "GO ✓" if all_ok else "NO-GO ✗"
    print(f"\n  → {verdict}")
    return 0 if all_ok else 1


def _confirm(action: str, serial: str, *, hard: bool, assume_yes: bool) -> None:
    if assume_yes:
        return
    if hard:
        ans = input(f"{action} {serial} is IRREVERSIBLE. Type the serial to confirm: ").strip()
        if ans != serial:
            _die("confirmation did not match; aborted.")
    else:
        ans = input(f"{action} {serial}? [y/N] ").strip().lower()
        if ans not in ("y", "yes"):
            _die("aborted.")


# ── Commands ─────────────────────────────────────────────────────────────


def _fleet(client: _Client, status: str | None = None, device_type: str | None = None) -> list[dict[str, Any]]:
    q = []
    if status:
        q.append(f"status={status}")
    if device_type:
        q.append(f"deviceType={device_type}")
    path = "/api/v1/admin/devices" + (("?" + "&".join(q)) if q else "")
    return client.request("GET", path).get("devices", [])


def _one(client: _Client, serial: str) -> dict[str, Any]:
    for r in _fleet(client):
        if r.get("serialNumber") == serial:
            return r
    _die(f"{serial} not found in the fleet.")


def cmd_ls(client: _Client, args: argparse.Namespace) -> int:
    rows = _fleet(client, status=args.status, device_type=args.type)
    if args.json:
        print(json.dumps(rows, indent=2, default=str))
    else:
        _print_table(rows)
    return 0


def cmd_status(client: _Client, args: argparse.Namespace) -> int:
    row = _one(client, args.serial)
    if args.json:
        print(json.dumps(row, indent=2, default=str))
        return 0
    tele = row.get("telemetry") or {}
    asg = row.get("currentAssignment") or {}
    print(f"Device {row.get('serialNumber')}  ({short_type(row.get('deviceType'))})")
    print(f"  status        {row.get('status')}")
    print(f"  owner         client={row.get('owningClientId') or '—'} facility={row.get('owningFacilityId') or '—'}")
    print(f"  walkerId      {row.get('walkerId') or '—'}")
    print(f"  assignment    patient={asg.get('patientId') or '—'} since={asg.get('startedAt') or '—'}")
    print(f"  activated_at  {row.get('activated_at') or '—'}")
    print("  live shadow:")
    if tele:
        batt = _as_float(tele.get("batteryPct"))
        print(f"    battery     {f'{batt:.0%}' if batt is not None else '—'}   rsrp={tele.get('rsrpDbm','—')} snr={tele.get('snrDb','—')}")
        print(f"    lastSeen    {tele.get('lastSeen','—')}  ({fmt_age(age_seconds(tele.get('lastSeen')))} ago)")
        print(f"    firmware    {tele.get('firmware','—')}  lastCmdId={tele.get('lastCmdId','—')}")
        print(f"    wipe_complete {tele.get('wipeComplete','—')}")
    else:
        print("    (no shadow — device has never connected)")
    pend = []
    if row.get("activationPending"):
        pend.append(f"activation outstanding: {list((row.get('outstandingActivationCmds') or {}).keys())}")
    if row.get("wipePending"):
        pend.append(f"wipe outstanding: {list((row.get('outstandingWipeCmds') or {}).keys())}")
    print(f"  pending       {'; '.join(pend) if pend else 'none'}")
    print("\n  timeline (audit events):")
    tl = _timeline(args.serial)
    if not tl:
        print("    (none found in the device-api log group)")
    for e in tl:
        extra = e.get("extra") or {}
        note = ", ".join(f"{k}={v}" for k, v in extra.items() if k in ("reason", "wipe_id", "cmd_id", "decommissionReason", "previousState"))
        print(f"    {e.get('timestamp','?')}  {e.get('event','?')}"+(f"  ({note})" if note else ""))
    return 0


def cmd_check(client: _Client, args: argparse.Namespace) -> int:
    row = _one(client, args.serial)
    return _print_gate("PRE-SHIP CHECK", args.serial,
                       check_assertions(row, expect_type=args.expect_type,
                                        max_seen_age_s=args.max_age))


def cmd_ready(client: _Client, args: argparse.Namespace) -> int:
    row = _one(client, args.serial)
    return _print_gate("READY-FOR-NEXT-USER", args.serial,
                       ready_assertions(row, max_seen_age_s=args.max_age))


def cmd_provision(client: _Client, args: argparse.Namespace) -> int:
    # No confirm: provision is the routine happy-path command and is fully
    # reversible via `end`. Destructive ops (end/reset/decommission) still prompt.
    res = client.request("POST", f"/api/v1/devices/{args.serial}/provision",
                         {"patientId": args.patient})
    print(f"✓ provisioned {args.serial} → patient {args.patient} (activate cmd sent)")
    if args.json:
        print(json.dumps(res, indent=2))
    return 0


def cmd_end(client: _Client, args: argparse.Namespace) -> int:
    action = "end + release" if args.release else "end assignment on"
    _confirm(action, args.serial, hard=False, assume_yes=args.yes)
    res = client.request("POST", f"/api/v1/devices/{args.serial}/end-assignment",
                         {"reason": args.reason})
    wipe = (res.get("wipe") or {})
    print(f"✓ ended assignment on {args.serial} → discontinued; wipe cmd {wipe.get('wipe_id','?')} sent "
          f"(publish_ok={wipe.get('publish_ok')}). It auto-recycles once firmware acks.")
    if args.release:
        client.request("POST", f"/api/v1/devices/{args.serial}/release", {})
        print(f"✓ released ownership of {args.serial} — claimable by a new household once recycled")
    return 0


def cmd_release(client: _Client, args: argparse.Namespace) -> int:
    _confirm("release ownership of", args.serial, hard=False, assume_yes=args.yes)
    client.request("POST", f"/api/v1/devices/{args.serial}/release", {})
    print(f"✓ released ownership of {args.serial} — now claimable by a new household via QR")
    return 0


def cmd_reset(client: _Client, args: argparse.Namespace) -> int:
    _confirm("FORCE-RESET", args.serial, hard=False, assume_yes=args.yes)
    res = client.request("POST", f"/api/v1/devices/{args.serial}/force-reset",
                         {"reason": args.reason})
    print(f"✓ force-reset {args.serial} → ready_to_provision (audited). {res.get('note','')}")
    return 0


def cmd_decommission(client: _Client, args: argparse.Namespace) -> int:
    irreversible = args.reason in ("broken", "retired", "end_of_life")
    _confirm(f"decommission ({args.reason})", args.serial, hard=irreversible, assume_yes=args.yes)
    client.request("POST", f"/api/v1/devices/{args.serial}/decommission",
                   {"reason": args.reason})
    tail = " (recoverable via `fleet recover`)" if args.reason == "lost" else ""
    print(f"✓ decommissioned {args.serial} (reason={args.reason}){tail}")
    return 0


def cmd_recover(client: _Client, args: argparse.Namespace) -> int:
    _confirm("recover", args.serial, hard=False, assume_yes=args.yes)
    client.request("POST", f"/api/v1/devices/{args.serial}/recover", {})
    print(f"✓ recovered {args.serial} → ready_to_provision")
    return 0


# ── argparse ─────────────────────────────────────────────────────────────


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="fleet", description="GoSteady device fleet ops CLI")
    p.add_argument("-e", "--env", help="dev | prod (else GOSTEADY_ENV, default dev)")
    p.add_argument("--direct", action="store_true",
                   help="read the registry+shadows via AWS creds (no token; READS only)")
    p.add_argument("--api-base", help="API base URL (else GOSTEADY_API_BASE / CFN output)")
    p.add_argument("--token", help="internal id_token (else GOSTEADY_TOKEN / auto-mint)")
    sub = p.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("ls", help="fleet status board")
    s.add_argument("--status", help="filter by lifecycle status")
    s.add_argument("--type", help="filter by deviceType")
    s.add_argument("--json", action="store_true")
    s.set_defaults(fn=cmd_ls)

    s = sub.add_parser("status", help="single-device diagnosis + audit timeline")
    s.add_argument("serial")
    s.add_argument("--json", action="store_true")
    s.set_defaults(fn=cmd_status)

    s = sub.add_parser("check", help="pre-ship health gate (go/no-go)")
    s.add_argument("serial")
    s.add_argument("--expect-type", dest="expect_type", help="assert deviceType (e.g. rollator_platform)")
    s.add_argument("--max-age", type=int, default=DEFAULT_MAX_SEEN_AGE_S, help="max lastSeen age (s)")
    s.set_defaults(fn=cmd_check)

    s = sub.add_parser("ready", help="ready-for-next-user gate (wipe-verified)")
    s.add_argument("serial")
    s.add_argument("--max-age", type=int, default=DEFAULT_MAX_SEEN_AGE_S, help="max lastSeen age (s)")
    s.set_defaults(fn=cmd_ready)

    s = sub.add_parser("provision", help="assign device to a patient (fires activate)")
    s.add_argument("serial")
    s.add_argument("--patient", required=True, help="patientId")
    s.add_argument("--yes", action="store_true")
    s.add_argument("--json", action="store_true")
    s.set_defaults(fn=cmd_provision)

    s = sub.add_parser("end", help="end assignment (fires wipe → auto-recycle)")
    s.add_argument("serial")
    s.add_argument("--reason", default="manual")
    s.add_argument("--release", action="store_true",
                   help="also release ownership → claimable by a new household (rotation)")
    s.add_argument("--yes", action="store_true")
    s.set_defaults(fn=cmd_end)

    s = sub.add_parser("release", help="release ownership → device claimable by a new household")
    s.add_argument("serial")
    s.add_argument("--yes", action="store_true")
    s.set_defaults(fn=cmd_release)

    s = sub.add_parser("reset", help="force-reset a stuck device (admin override)")
    s.add_argument("serial")
    s.add_argument("--reason", default="ops_force_reset")
    s.add_argument("--yes", action="store_true")
    s.set_defaults(fn=cmd_reset)

    s = sub.add_parser("decommission", help="retire a unit (lost/broken/retired/end_of_life)")
    s.add_argument("serial")
    s.add_argument("--reason", required=True, choices=["lost", "broken", "retired", "end_of_life"])
    s.add_argument("--yes", action="store_true")
    s.set_defaults(fn=cmd_decommission)

    s = sub.add_parser("recover", help="recover a lost-decommissioned unit")
    s.add_argument("serial")
    s.add_argument("--yes", action="store_true")
    s.set_defaults(fn=cmd_recover)

    return p


def main(argv: list[str] | None = None) -> int:
    global ENV
    args = build_parser().parse_args(argv)
    if args.env:
        ENV = args.env
    if args.direct:
        client: Any = _DirectSource(ENV)
    else:
        client = _Client(_resolve_base(args.api_base), _get_token(args.token))
    return args.fn(client, args)


if __name__ == "__main__":
    sys.exit(main())

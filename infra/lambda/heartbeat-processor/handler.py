"""
Heartbeat Processor Lambda — Phase 1B revision (slim)

Triggered by: IoT Rule on gs/+/heartbeat
IoT Rule SQL: SELECT *, topic(2) AS thingName FROM 'gs/+/heartbeat'

Phase 1B revision changes (vs deployed Phase 1B original):
  - NO DDB writes on routine heartbeat — Shadow.reported is the canonical
    live-state store per architecture P5.
  - NO threshold detection — moved to the new threshold-detector Lambda
    triggered by Shadow update/accepted (D1).
  - NO synthetic alerts here.
  - Activation-ack path: when the heartbeat carries `last_cmd_id`, look
    up Device Registry's `outstandingActivationCmds` map (populated by
    Phase 2A device-api Lambda); if a non-expired entry matches within
    the 24 h window (DL14a / L9), set `Device Registry.activated_at` via
    conditional UpdateItem and emit a `device.activated` audit event.
    Until Phase 2A lands, the map is empty and this path is dormant.
  - All extras (reset_reason, fault_counters, watchdog_hits, etc.) flow
    into Shadow.reported as-given per D14 / D16 accept-all contract.
"""

from __future__ import annotations

import json
import os
from datetime import datetime, timedelta, timezone
from decimal import Decimal
from typing import Any

import boto3
from botocore.exceptions import ClientError

from _shared import audit_logger, emit_audit, get_logger, get_metrics
from _shared.device_time import resolve_heartbeat_ts
from _shared.audit_catalog import (
    AUDIT_DEVICE_ACTIVATED,
    AUDIT_DEVICE_BATTERY_SWAPPED,
    AUDIT_DEVICE_FIRST_HEARTBEAT,
    AUDIT_DEVICE_RECYCLED,
    AUDIT_DEVICE_WIPE_COMPLETE,
)
from _shared.observability import make_device_metrics
from aws_lambda_powertools.metrics import MetricUnit

# ── Configuration ────────────────────────────────────────────────
DEVICE_TABLE = os.environ["DEVICE_TABLE"]
ENVIRONMENT = os.environ.get("ENVIRONMENT", "dev")
ACK_WINDOW_HOURS = int(os.environ.get("ACTIVATION_ACK_WINDOW_HOURS", "24"))

# `ts` is no longer required: firmware 0.17.0-time omits it when the device
# clock is unsynced (clock_synced=false), and the cloud substitutes its trusted
# receive time (spec §6 / Open-Q4). The signal/battery fields stay required.
REQUIRED_FIELDS = ("battery_pct", "rsrp_dbm", "snr_db")

logger = get_logger()
metrics = get_metrics()

_iot_data = boto3.client("iot-data")
_ddb = boto3.resource("dynamodb")
_device_tbl = _ddb.Table(DEVICE_TABLE)


def _parse_iso(ts: str) -> datetime:
    return datetime.fromisoformat(ts.replace("Z", "+00:00"))


def _validate(event: dict) -> tuple[bool, str]:
    for f in REQUIRED_FIELDS:
        if f not in event:
            return False, f"missing:{f}"
    # ts is optional + resolved (never rejected) by resolve_heartbeat_ts — a
    # missing/implausible ts under clock_synced=false gets the server time.
    try:
        pct = float(event["battery_pct"])
        rsrp = float(event["rsrp_dbm"])
        snr = float(event["snr_db"])
    except (TypeError, ValueError) as e:
        return False, f"bad_number:{e}"
    if not 0.0 <= pct <= 1.0:
        return False, f"battery_pct_out_of_range:{pct}"
    if not -140 <= rsrp <= 0:
        return False, f"rsrp_out_of_range:{rsrp}"
    if not -20 <= snr <= 40:
        return False, f"snr_out_of_range:{snr}"
    return True, "ok"


def _shadow_reported(event: dict, effective_ts_iso: str) -> dict[str, Any]:
    """
    Build the Shadow.reported payload from the heartbeat — accept all fields
    per D16. JSON-serializable types only (no Decimal); Shadow stores numbers
    natively.

    `ts` and `lastSeen` are set to `effective_ts_iso` (the server receive time
    when the device clock was unsynced), so device-health never shows a
    1980/2080 ts or a missing one. `clock_synced` / `time_source` flow through
    from the event for observability.
    """
    SKIP = {"thingName"}
    reported: dict[str, Any] = {
        k: v for k, v in event.items() if k not in SKIP
    }
    reported["ts"] = effective_ts_iso
    reported["lastSeen"] = effective_ts_iso
    return reported


def _emit_device_telemetry_metrics(serial: str, event: dict) -> None:
    """
    Emit per-device CloudWatch metrics for the Per-Device Detail dashboard
    (Phase 1.6 §Architecture). Namespace `GoSteady/Devices/{env}`, dimensioned
    by serial.

    Required-field gauges (always emit; payload already validated):
      - BatteryPct, RsrpDbm, SnrDb

    Optional-field gauges (emit when present in the heartbeat):
      - UptimeSec, WatchdogHits, FaultCountersFatal, FaultCountersWatchdog

    Failure to emit is non-fatal: logged at debug, never raises (we don't
    want metric publishing failures to fail the heartbeat-handler invocation).
    """
    try:
        device_metrics = make_device_metrics(serial)

        # Required heartbeat gauges
        device_metrics.add_metric(
            name="BatteryPct", unit=MetricUnit.NoUnit, value=float(event["battery_pct"]),
        )
        device_metrics.add_metric(
            name="RsrpDbm", unit=MetricUnit.NoUnit, value=float(event["rsrp_dbm"]),
        )
        device_metrics.add_metric(
            name="SnrDb", unit=MetricUnit.NoUnit, value=float(event["snr_db"]),
        )

        # Optional top-level gauges
        for evt_key, metric_name in (
            ("uptime_s", "UptimeSec"),
            ("watchdog_hits", "WatchdogHits"),
        ):
            if evt_key in event:
                try:
                    device_metrics.add_metric(
                        name=metric_name,
                        unit=MetricUnit.Count,
                        value=float(event[evt_key]),
                    )
                except (TypeError, ValueError):
                    logger.debug(
                        "device_metric_skipped",
                        extra={"serial": serial, "metric": metric_name, "value": event[evt_key]},
                    )

        # Optional fault_counters object (firmware coord §F5.1)
        fault_counters = event.get("fault_counters")
        if isinstance(fault_counters, dict):
            for fc_key, metric_name in (
                ("fatal", "FaultCountersFatal"),
                ("watchdog", "FaultCountersWatchdog"),
            ):
                if fc_key in fault_counters:
                    try:
                        device_metrics.add_metric(
                            name=metric_name,
                            unit=MetricUnit.Count,
                            value=float(fault_counters[fc_key]),
                        )
                    except (TypeError, ValueError):
                        logger.debug(
                            "device_metric_skipped",
                            extra={
                                "serial": serial,
                                "metric": metric_name,
                                "value": fault_counters[fc_key],
                            },
                        )

        device_metrics.flush_metrics()
    except Exception as exc:  # noqa: BLE001 — never let metrics fail a heartbeat
        logger.warning(
            "device_metrics_emit_failed",
            extra={"serial": serial, "error": str(exc)},
        )


def _try_activation_ack(serial: str, last_cmd_id: str, heartbeat_ts: datetime) -> bool:
    """
    Look up Device Registry's `outstandingActivationCmds` map; if any entry
    matches `last_cmd_id` within the last ACK_WINDOW_HOURS, record activation
    via conditional UpdateItem. Returns True if activation was recorded this
    invocation.

    Idempotency comes from "cmd still in the map": once the first ack removes
    it, a duplicate heartbeat ack falls out at the scan step (no match) or
    fails the conditional UpdateItem (cmd no longer in map). A stale
    `activated_at` from a prior cycle is overwritten — a cmd_id appearing in
    `outstandingActivationCmds` was issued during a fresh provision, so by
    construction it represents a new activation cycle (per firmware coord
    §C18.5 Gap 1).

    When the device's current status is `provisioned`, this also performs
    the `provisioned → active_monitoring` state transition and stamps
    `firstHeartbeatAt`, fusing what ARCHITECTURE.md §4 names the
    `device.first_heartbeat` event into the same atomic write (§C18.5 Gap 2).
    """
    try:
        item = _device_tbl.get_item(Key={"serialNumber": serial}).get("Item") or {}
    except ClientError as e:
        logger.exception("activation_ack_lookup_failed", extra={"serial": serial, "error": str(e)})
        return False

    outstanding: dict[str, str] = item.get("outstandingActivationCmds") or {}
    cutoff = heartbeat_ts - timedelta(hours=ACK_WINDOW_HOURS)

    matched_issued_at: str | None = None
    for cmd_id, issued_iso in outstanding.items():
        if cmd_id != last_cmd_id:
            continue
        try:
            issued_at = _parse_iso(str(issued_iso))
        except (TypeError, ValueError):
            continue
        if issued_at >= cutoff:
            matched_issued_at = str(issued_iso)
            break

    if matched_issued_at is None:
        if outstanding:
            logger.warning(
                "activation_ack_no_match",
                extra={
                    "serial": serial,
                    "last_cmd_id": last_cmd_id,
                    "outstanding_count": len(outstanding),
                },
            )
        else:
            # Either Phase 2A hasn't issued a cmd yet, or an earlier heartbeat
            # already acked this one and removed it from the map.
            logger.info(
                "heartbeat_with_unknown_cmd_id",
                extra={"serial": serial, "last_cmd_id": last_cmd_id},
            )
        return False

    activated_iso = _parse_iso(matched_issued_at).astimezone(timezone.utc).strftime(
        "%Y-%m-%dT%H:%M:%SZ"
    )
    first_heartbeat_iso = heartbeat_ts.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    current_status = item.get("status")
    will_transition_status = current_status == "provisioned"

    set_clauses = ["activated_at = :a"]
    expr_names: dict[str, str] = {"#cid": last_cmd_id}
    expr_values: dict[str, Any] = {":a": activated_iso}
    condition_parts = ["attribute_exists(outstandingActivationCmds.#cid)"]

    if will_transition_status:
        set_clauses.append("#s = :am")
        set_clauses.append("firstHeartbeatAt = if_not_exists(firstHeartbeatAt, :fhb)")
        expr_names["#s"] = "status"
        expr_values[":am"] = "active_monitoring"
        expr_values[":fhb"] = first_heartbeat_iso
        condition_parts.append("#s = :prov")
        expr_values[":prov"] = "provisioned"

    update_expr = f"SET {', '.join(set_clauses)} REMOVE outstandingActivationCmds.#cid"
    condition_expr = " AND ".join(condition_parts)

    try:
        _device_tbl.update_item(
            Key={"serialNumber": serial},
            UpdateExpression=update_expr,
            ConditionExpression=condition_expr,
            ExpressionAttributeNames=expr_names,
            ExpressionAttributeValues=expr_values,
        )
    except ClientError as e:
        if e.response["Error"]["Code"] == "ConditionalCheckFailedException":
            # Either the cmd was already acked (removed from map) or the
            # status changed concurrently (rare — only `device-api` writes
            # to status, and only via provision/end-assignment/decommission).
            logger.info(
                "activation_ack_skipped",
                extra={
                    "serial": serial,
                    "last_cmd_id": last_cmd_id,
                    "read_status": current_status,
                },
            )
            return False
        logger.exception("activation_ack_write_failed", extra={"serial": serial})
        raise

    activated_after: dict[str, Any] = {
        "activated_at": activated_iso,
        "matched_cmd_id": last_cmd_id,
    }
    if will_transition_status:
        activated_after["status"] = "active_monitoring"

    emit_audit(
        AUDIT_DEVICE_ACTIVATED,
        subject={"deviceSerial": serial},
        action="update",
        after=activated_after,
        extra={"cmd_issued_at": matched_issued_at},
    )
    metrics.add_metric(name="device_activated_count", unit=MetricUnit.Count, value=1)

    if will_transition_status:
        emit_audit(
            AUDIT_DEVICE_FIRST_HEARTBEAT,
            subject={"deviceSerial": serial},
            action="update",
            before={"status": "provisioned"},
            after={
                "status": "active_monitoring",
                "firstHeartbeatAt": first_heartbeat_iso,
            },
        )
        metrics.add_metric(
            name="device_first_heartbeat_count", unit=MetricUnit.Count, value=1
        )

    return True


def _try_wipe_ack(serial: str, last_cmd_id: str, heartbeat_ts: datetime,
                   battery_pct: float) -> bool:
    """
    Sibling of `_try_activation_ack` for the AA-battery-recycle design
    (firmware coord §C20 / portal `docs/specs/2026-05-17-aa-battery-recycle.md`).

    Look up Device Registry's `outstandingWipeCmds.<last_cmd_id>`. If present
    within the 24h ack window AND device is currently in `discontinued` AND
    `battery_pct >= 0.10` in the acking heartbeat, atomically:
      - SET status = ready_to_provision
      - SET last_wipe_at = <heartbeat ts>
      - SET lastTransitionAt = <heartbeat ts>
      - REMOVE outstandingWipeCmds.<last_cmd_id>
      - Clear Shadow desired.wipe_requested

    Emits `device.wipe_complete` + `device.recycled` audits. Returns True if
    the recycle happened, False otherwise (no match in map / battery floor
    not met / status not discontinued / ConditionalCheckFailedException).

    Idempotency mirrors the activation-ack pattern (DL15): cmd-in-map is the
    invariant. First successful ack REMOVEs the entry; duplicate falls out at
    the scan step or at the conditional check.
    """
    # Battery floor — sanity check at ack time (mirrors firmware-side floor
    # in `gosteady_wipe_now` per portal memo D3). Wipe may have completed
    # firmware-side just before brownout; refuse to auto-recycle from a
    # device that's about to die. Cloud will see the next ack-bearing
    # heartbeat once battery recovers.
    if battery_pct is None or float(battery_pct) < 0.10:
        logger.info(
            "wipe_ack_below_battery_floor",
            extra={
                "serial": serial,
                "last_cmd_id": last_cmd_id,
                "battery_pct": battery_pct,
            },
        )
        return False

    try:
        item = _device_tbl.get_item(Key={"serialNumber": serial}).get("Item") or {}
    except ClientError as e:
        logger.exception("wipe_ack_lookup_failed", extra={"serial": serial, "error": str(e)})
        return False

    outstanding: dict[str, str] = item.get("outstandingWipeCmds") or {}
    cutoff = heartbeat_ts - timedelta(hours=ACK_WINDOW_HOURS)

    matched_issued_at: str | None = None
    for cmd_id, issued_iso in outstanding.items():
        if cmd_id != last_cmd_id:
            continue
        try:
            issued_at = _parse_iso(str(issued_iso))
        except (TypeError, ValueError):
            continue
        if issued_at >= cutoff:
            matched_issued_at = str(issued_iso)
            break

    if matched_issued_at is None:
        if outstanding:
            logger.warning(
                "wipe_ack_no_match",
                extra={
                    "serial": serial,
                    "last_cmd_id": last_cmd_id,
                    "outstanding_count": len(outstanding),
                },
            )
        else:
            logger.info(
                "wipe_ack_no_outstanding",
                extra={"serial": serial, "last_cmd_id": last_cmd_id},
            )
        return False

    current_status = item.get("status")
    if current_status != "discontinued":
        # Wipe-ack against a non-discontinued device shouldn't happen in a
        # well-formed flow — log + bail. Could be a stale cmd_id echo from
        # a previous cycle that wasn't cleaned up; force_reset clears that.
        logger.warning(
            "wipe_ack_wrong_status",
            extra={
                "serial": serial,
                "last_cmd_id": last_cmd_id,
                "current_status": current_status,
            },
        )
        return False

    wiped_at_iso = heartbeat_ts.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    try:
        _device_tbl.update_item(
            Key={"serialNumber": serial},
            UpdateExpression=(
                "SET #s = :rp, last_wipe_at = :w, lastTransitionAt = :w "
                "REMOVE outstandingWipeCmds.#cid"
            ),
            ConditionExpression=(
                "attribute_exists(outstandingWipeCmds.#cid) AND #s = :disc"
            ),
            ExpressionAttributeNames={"#cid": last_cmd_id, "#s": "status"},
            ExpressionAttributeValues={
                ":rp": "ready_to_provision",
                ":w": wiped_at_iso,
                ":disc": "discontinued",
            },
        )
    except ClientError as e:
        if e.response["Error"]["Code"] == "ConditionalCheckFailedException":
            logger.info(
                "wipe_ack_skipped",
                extra={
                    "serial": serial,
                    "last_cmd_id": last_cmd_id,
                    "read_status": current_status,
                },
            )
            return False
        logger.exception("wipe_ack_write_failed", extra={"serial": serial})
        raise

    # Clear Shadow desired.wipe_requested (best-effort — non-fatal on failure;
    # device-shadow-handler's path will pick it up on the same ack or admin
    # force_reset will eventually clean it up).
    try:
        _iot_data.update_thing_shadow(
            thingName=serial,
            payload=json.dumps({"state": {"desired": {"wipe_requested": None}}}).encode("utf-8"),
        )
    except ClientError as e:
        logger.warning(
            "wipe_ack_shadow_desired_clear_failed",
            extra={"serial": serial, "error": str(e)},
        )

    emit_audit(
        AUDIT_DEVICE_WIPE_COMPLETE,
        subject={"deviceSerial": serial},
        action="update",
        after={
            "last_wipe_at": wiped_at_iso,
            "matched_cmd_id": last_cmd_id,
            "battery_pct": float(battery_pct),
        },
        extra={"cmd_issued_at": matched_issued_at},
    )
    emit_audit(
        AUDIT_DEVICE_RECYCLED,
        subject={"deviceSerial": serial},
        action="update",
        before={"status": "discontinued"},
        after={"status": "ready_to_provision", "last_wipe_at": wiped_at_iso},
    )
    metrics.add_metric(name="device_wipe_complete_count", unit=MetricUnit.Count, value=1)
    metrics.add_metric(name="device_recycled_count", unit=MetricUnit.Count, value=1)
    return True


def _check_device_type(serial: str, event: dict) -> None:
    """
    Phase DT-0 (memo Q7 / spec L8): firmware self-reports `device_type` in
    the heartbeat; cross-check it against the registry-authoritative
    Device Registry value. Mismatch → warn log + `device_type_mismatch_count`
    EMF metric (alarmed in Observability) — NEVER reject; the registry wins.
    Catches wrong-firmware-flashed-on-this-board at the first heartbeat.

    Cost discipline: only runs when the field is present (pre-DT-1 firmware
    never sends it → zero overhead), and the GetItem projects a single
    attribute. Best-effort: any read failure is a debug log, not an error.
    """
    reported_type = event.get("device_type")
    if not isinstance(reported_type, str) or not reported_type:
        return

    try:
        resp = _device_tbl.get_item(
            Key={"serialNumber": serial},
            ProjectionExpression="deviceType",
        )
        item = resp.get("Item")
    except ClientError as e:
        logger.debug(
            "device_type_check_read_failed",
            extra={"serial": serial, "error": str(e)},
        )
        return

    if item is None:
        # Unregistered serial — other paths own that signal; nothing to
        # compare against.
        return

    registry_type = item.get("deviceType") or "walker_cap"  # D9 legacy default
    if reported_type != registry_type:
        logger.warning(
            "device_type_mismatch",
            extra={
                "serial": serial,
                "reportedType": reported_type,
                "registryType": registry_type,
            },
        )
        metrics.add_metric(
            name="device_type_mismatch_count", unit=MetricUnit.Count, value=1
        )


def _maybe_emit_battery_swapped(serial: str, event: dict) -> None:
    """
    DL16 / portal memo D7: emit `device.battery_swapped` audit when a
    mid-deployment cold boot is detected (boot_count increment +
    `reset_reason == "POWER_ON"`) while status ∈ {provisioned, active_monitoring}.

    Low-severity forensics — no state change. Useful for operations to
    distinguish "operator swapped the AAs last month" from "device
    brownout-rebooted."

    Strategy: only does the (slightly expensive) Shadow GET when
    reset_reason == "POWER_ON" — keeps the per-heartbeat overhead near zero
    for the common case (heartbeats with reset_reason == "SOFTWARE" or
    absent).
    """
    reset_reason = event.get("reset_reason")
    current_boot_count = event.get("boot_count")
    if reset_reason != "POWER_ON" or current_boot_count is None:
        return

    # Read prior boot_count from Shadow.reported BEFORE writing the new
    # heartbeat (handler caller must invoke this before update_thing_shadow).
    prior_boot_count: int | None = None
    prior_status: str | None = None
    try:
        resp = _iot_data.get_thing_shadow(thingName=serial)
        doc = json.loads(resp["payload"].read())
        reported = doc.get("state", {}).get("reported", {}) or {}
        prior_boot_count = reported.get("boot_count")
    except _iot_data.exceptions.ResourceNotFoundException:
        # No shadow yet — first heartbeat for this device; can't detect.
        return
    except (ClientError, KeyError, ValueError, AttributeError) as e:
        logger.debug(
            "battery_swap_shadow_read_failed",
            extra={"serial": serial, "error": str(e)},
        )
        return

    if prior_boot_count is None:
        return

    try:
        if int(current_boot_count) <= int(prior_boot_count):
            return  # not an increment — likely the same boot reporting again
    except (TypeError, ValueError):
        return

    # Need device status to decide whether this is a mid-deployment swap
    # (worth auditing) vs pre-activation cold-boot (expected, not worth audit).
    try:
        item = _device_tbl.get_item(Key={"serialNumber": serial}).get("Item") or {}
        prior_status = item.get("status")
    except ClientError as e:
        logger.debug(
            "battery_swap_status_read_failed",
            extra={"serial": serial, "error": str(e)},
        )
        return

    if prior_status not in ("provisioned", "active_monitoring"):
        # Pre-activation or post-recycle cold-boots are expected — no audit.
        return

    emit_audit(
        AUDIT_DEVICE_BATTERY_SWAPPED,
        subject={"deviceSerial": serial},
        action="event",
        extra={
            "priorBootCount": int(prior_boot_count),
            "newBootCount": int(current_boot_count),
            "resetReason": reset_reason,
            "batteryPct": event.get("battery_pct"),
            "status": prior_status,
        },
    )
    metrics.add_metric(name="device_battery_swapped_count", unit=MetricUnit.Count, value=1)


@logger.inject_lambda_context(log_event=False, correlation_id_path="thingName")
@metrics.log_metrics(capture_cold_start_metric=True)
def handler(event: dict, _context):
    serial = event.get("serial") or event.get("thingName") or "UNKNOWN"

    ok, reason = _validate(event)
    if not ok:
        logger.warning("heartbeat_reject", extra={"serial": serial, "reason": reason})
        metrics.add_metric(name="heartbeat_reject_count", unit=MetricUnit.Count, value=1)
        return {"statusCode": 400, "body": f"invalid payload: {reason}"}

    # spec §6 / Open-Q4: resolve the effective timestamp. When the device clock
    # was synced + its ts plausible, use it; otherwise substitute our trusted
    # receive time so lastSeen / device-health never shows 1980/2080 and a
    # no-time device still registers as alive.
    ingested_at = datetime.now(timezone.utc)
    effective_ts, used_ingest = resolve_heartbeat_ts(event, ingested_at)
    heartbeat_ts = effective_ts
    effective_ts_iso = effective_ts.strftime("%Y-%m-%dT%H:%M:%SZ")
    if used_ingest:
        logger.info(
            "heartbeat_ts_substituted",
            extra={
                "serial": serial,
                "clock_synced": event.get("clock_synced"),
                "deviceTs": event.get("ts"),
                "effectiveTs": effective_ts_iso,
            },
        )
        metrics.add_metric(
            name="heartbeat_ts_substituted_count", unit=MetricUnit.Count, value=1
        )

    # Battery-swap detection must read prior Shadow BEFORE we overwrite it.
    _maybe_emit_battery_swapped(serial, event)

    # DT-0: registry cross-check of the firmware's self-reported device_type
    # (no-op when the field is absent — pre-DT-1 firmware). The field itself
    # still flows into Shadow.reported below via the D16 accept-all build.
    _check_device_type(serial, event)

    reported = _shadow_reported(event, effective_ts_iso)

    try:
        _iot_data.update_thing_shadow(
            thingName=serial,
            payload=json.dumps({"state": {"reported": reported}}).encode("utf-8"),
        )
    except ClientError as e:
        logger.exception("shadow_update_failed", extra={"serial": serial, "error": str(e)})
        metrics.add_metric(name="shadow_update_error_count", unit=MetricUnit.Count, value=1)
        raise

    # Mirror lastSeen into Device Registry — 2A-RD /patients/{id}
    # surfaces this in currentDevice.lastSeen. Without this write, the
    # registry row's lastSeen stayed null forever (Shadow was the only
    # writer), and patient-api's `lastSeen or firstHeartbeatAt` fallback
    # returned the stale firstHeartbeatAt value, showing "8d ago" on
    # actively-heartbeating devices (CR-1, see coord doc).
    #
    # Best-effort: Shadow remains the authoritative live-state source;
    # a failed Device Registry write is non-fatal so we don't lose the
    # heartbeat itself.
    try:
        _device_tbl.update_item(
            Key={"serialNumber": serial},
            UpdateExpression="SET lastSeen = :ls",
            ExpressionAttributeValues={":ls": effective_ts_iso},
        )
    except ClientError as e:
        logger.warning(
            "device_lastseen_update_failed",
            extra={"serial": serial, "error": str(e)},
        )

    metrics.add_metric(name="heartbeat_count", unit=MetricUnit.Count, value=1)

    _emit_device_telemetry_metrics(serial, event)

    last_cmd_id = event.get("last_cmd_id")
    if isinstance(last_cmd_id, str) and last_cmd_id:
        # Dispatch ack path by cmd_id prefix. `act_` and `wipe_` are the two
        # downlink cmd kinds in v1 (ARCH §7). Unknown prefix logs + skips;
        # cloud is forward-compatible with new cmds added on the firmware side.
        if last_cmd_id.startswith("act_"):
            _try_activation_ack(serial, last_cmd_id, heartbeat_ts)
        elif last_cmd_id.startswith("wipe_"):
            try:
                battery_pct_val = float(event.get("battery_pct"))
            except (TypeError, ValueError):
                battery_pct_val = 0.0
            _try_wipe_ack(serial, last_cmd_id, heartbeat_ts, battery_pct_val)
        else:
            logger.info(
                "heartbeat_with_unknown_cmd_prefix",
                extra={"serial": serial, "last_cmd_id": last_cmd_id},
            )

    logger.info(
        "heartbeat_ok",
        extra={
            "serial": serial,
            "ts": effective_ts_iso,
            "clock_synced": event.get("clock_synced"),
            "battery_pct": event.get("battery_pct"),
            "rsrp_dbm": event.get("rsrp_dbm"),
        },
    )
    return {"statusCode": 200, "body": f"heartbeat accepted for {serial}"}

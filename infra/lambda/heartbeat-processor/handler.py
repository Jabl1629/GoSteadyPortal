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
from _shared.observability import make_device_metrics
from aws_lambda_powertools.metrics import MetricUnit

# ── Configuration ────────────────────────────────────────────────
DEVICE_TABLE = os.environ["DEVICE_TABLE"]
ENVIRONMENT = os.environ.get("ENVIRONMENT", "dev")
ACK_WINDOW_HOURS = int(os.environ.get("ACTIVATION_ACK_WINDOW_HOURS", "24"))

REQUIRED_FIELDS = ("ts", "battery_pct", "rsrp_dbm", "snr_db")

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
    try:
        _parse_iso(event["ts"])
    except (TypeError, ValueError) as e:
        return False, f"bad_timestamp:{e}"
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


def _shadow_reported(event: dict) -> dict[str, Any]:
    """
    Build the Shadow.reported payload from the heartbeat — accept all fields
    per D16. JSON-serializable types only (no Decimal); Shadow stores numbers
    natively.
    """
    SKIP = {"thingName"}
    reported: dict[str, Any] = {
        k: v for k, v in event.items() if k not in SKIP
    }
    reported["lastSeen"] = event["ts"]
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
        "device.activated",
        subject={"deviceSerial": serial},
        action="update",
        after=activated_after,
        extra={"cmd_issued_at": matched_issued_at},
    )
    metrics.add_metric(name="device_activated_count", unit=MetricUnit.Count, value=1)

    if will_transition_status:
        emit_audit(
            "device.first_heartbeat",
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


@logger.inject_lambda_context(log_event=False, correlation_id_path="thingName")
@metrics.log_metrics(capture_cold_start_metric=True)
def handler(event: dict, _context):
    serial = event.get("serial") or event.get("thingName") or "UNKNOWN"

    ok, reason = _validate(event)
    if not ok:
        logger.warning("heartbeat_reject", extra={"serial": serial, "reason": reason})
        metrics.add_metric(name="heartbeat_reject_count", unit=MetricUnit.Count, value=1)
        return {"statusCode": 400, "body": f"invalid payload: {reason}"}

    heartbeat_ts = _parse_iso(event["ts"])
    reported = _shadow_reported(event)

    try:
        _iot_data.update_thing_shadow(
            thingName=serial,
            payload=json.dumps({"state": {"reported": reported}}).encode("utf-8"),
        )
    except ClientError as e:
        logger.exception("shadow_update_failed", extra={"serial": serial, "error": str(e)})
        metrics.add_metric(name="shadow_update_error_count", unit=MetricUnit.Count, value=1)
        raise

    metrics.add_metric(name="heartbeat_count", unit=MetricUnit.Count, value=1)

    _emit_device_telemetry_metrics(serial, event)

    last_cmd_id = event.get("last_cmd_id")
    if isinstance(last_cmd_id, str) and last_cmd_id:
        _try_activation_ack(serial, last_cmd_id, heartbeat_ts)

    logger.info(
        "heartbeat_ok",
        extra={
            "serial": serial,
            "ts": event["ts"],
            "battery_pct": event.get("battery_pct"),
            "rsrp_dbm": event.get("rsrp_dbm"),
        },
    )
    return {"statusCode": 200, "body": f"heartbeat accepted for {serial}"}

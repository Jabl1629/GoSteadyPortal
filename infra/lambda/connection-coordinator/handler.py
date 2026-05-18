"""
Connection-coordinator Lambda — coord §C23.

Triggered by an IoT Topic Rule subscribing to AWS IoT lifecycle events:
  `$aws/events/presence/connected/+clientId`

Addresses firmware-coord §C22 Finding 2: AWS IoT MQTT 3.1.1
persistent_session has a 1-hour expiry on disconnect. Firmware's
hourly heartbeat cadence consistently lands at that edge, so the
broker drops queued QoS-1 cmds between firmware connects.

This Lambda watches for firmware connect events and immediately
re-publishes any outstanding cmds for that device, landing them in
the active subscription window before the firmware disconnects.

Stateless: queries Device Registry on each invocation. Idempotent:
re-publishes use the same cmd_id, and firmware-side handlers
(handle_activate_cmd / handle_wipe_cmd / gosteady_wipe_now / etc.)
dedupe on cmd_id — duplicate publishes are no-ops firmware-side.

Also folds in §C22 Finding 7: stale outstandingActivationCmds /
outstandingWipeCmds entries (>24h old, past the ack window) are
swept opportunistically on the same DDB GetItem.

Audit + metrics:
  - device.cmd_republished — per cmd re-published
  - device.cmd_swept_stale — summary per Lambda invocation (single
    audit listing N swept cmd_ids, NOT one audit per swept entry)
  - device_cmd_republished_count, device_cmd_swept_stale_count,
    device_connect_event_count — CloudWatch EMF metrics in
    GoSteady/Coordinator/{env}
"""

from __future__ import annotations

import json
import os
import re
from datetime import datetime, timedelta, timezone
from typing import Any

import boto3
from botocore.exceptions import ClientError

from _shared import emit_audit, get_logger, get_metrics
from _shared.audit_catalog import (
    AUDIT_DEVICE_CMD_REPUBLISHED,
    AUDIT_DEVICE_CMD_SWEPT_STALE,
)
from aws_lambda_powertools.metrics import MetricUnit

# ── Configuration ────────────────────────────────────────────────
DEVICE_TABLE = os.environ["DEVICE_TABLE"]
ENVIRONMENT = os.environ.get("ENVIRONMENT", "dev")
ACK_WINDOW_HOURS = int(os.environ.get("ACK_WINDOW_HOURS", "24"))

#: Matches GoSteady serial format `GS` + 10 digits (ARCH D1). The
#: lifecycle-event clientId is the MQTT client_id which firmware sets
#: to the serial via `CONFIG_AWS_IOT_CLIENT_ID_STATIC`. Internal
#: tooling, ops connections, and synthetic test clients use other
#: client_id shapes and should be filtered out before any DDB hit.
_SERIAL_RE = re.compile(r"^GS\d{10}$")

logger = get_logger()
metrics = get_metrics()

_iot_data = boto3.client("iot-data")
_ddb = boto3.resource("dynamodb")
_device_tbl = _ddb.Table(DEVICE_TABLE)


def _parse_iso(ts: str) -> datetime:
    return datetime.fromisoformat(ts.replace("Z", "+00:00"))


def _now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _publish_cmd(serial: str, cmd_kind: str, cmd_id: str, now_iso: str) -> None:
    """Re-publish a cmd to gs/{serial}/cmd. Raises on IoT publish failure
    (Lambda surfaces the error → IoT Rule retries per its config)."""
    payload = json.dumps({"cmd": cmd_kind, "cmd_id": cmd_id, "ts": now_iso})
    _iot_data.publish(
        topic=f"gs/{serial}/cmd",
        qos=1,
        payload=payload,
    )


def _sweep_entry(serial: str, map_attr: str, cmd_id: str) -> None:
    """Remove a single entry from `outstandingActivationCmds` or
    `outstandingWipeCmds`. Non-fatal on failure; logged for visibility."""
    try:
        _device_tbl.update_item(
            Key={"serialNumber": serial},
            UpdateExpression=f"REMOVE {map_attr}.#cid",
            ExpressionAttributeNames={"#cid": cmd_id},
        )
    except ClientError as e:
        logger.warning(
            "coordinator_sweep_failed",
            extra={
                "serial": serial,
                "map_attr": map_attr,
                "cmd_id": cmd_id,
                "error": str(e),
            },
        )


@logger.inject_lambda_context(log_event=False, correlation_id_path="clientId")
@metrics.log_metrics(capture_cold_start_metric=True)
def handler(event: dict, _context) -> dict:
    """
    IoT Rule event shape (when the Rule SQL is `SELECT clientId,
    timestamp, eventType FROM '$aws/events/presence/connected/+'
    WHERE eventType = 'connected'`):

        {
          "clientId": "GS9999999998",
          "timestamp": 1779040000000,
          "eventType": "connected"
        }
    """
    metrics.add_metric(name="device_connect_event_count", unit=MetricUnit.Count, value=1)

    serial = event.get("clientId")
    event_type = event.get("eventType", "connected")

    if event_type != "connected":
        # Defense in depth: the Rule SQL filters but a misconfigured
        # rule could send us a disconnected event.
        logger.info("coordinator_skip_non_connected", extra={"clientId": serial, "eventType": event_type})
        return {"skipped": "non_connected_event", "clientId": serial}

    if not serial or not _SERIAL_RE.match(str(serial)):
        # Internal tooling, ops connections, synthetic test clients
        # all have non-device-shaped clientIds. No-op.
        logger.debug("coordinator_skip_non_serial", extra={"clientId": serial})
        return {"skipped": "non_device_clientId", "clientId": serial}

    try:
        item = _device_tbl.get_item(Key={"serialNumber": serial}).get("Item") or {}
    except ClientError as e:
        logger.exception(
            "coordinator_device_lookup_failed",
            extra={"serial": serial, "error": str(e)},
        )
        # Re-raise so the IoT Rule sees the failure and can retry / DLQ.
        raise

    if not item:
        # Connect event for a device not yet in registry. Manufacturer-side
        # enrollment may not have happened yet, or this is a stale test
        # client. No-op without alarm.
        logger.info("coordinator_no_registry_entry", extra={"serial": serial})
        return {"skipped": "no_registry_entry", "serial": serial}

    now = datetime.now(timezone.utc)
    now_iso = now.strftime("%Y-%m-%dT%H:%M:%SZ")
    cutoff = now - timedelta(hours=ACK_WINDOW_HOURS)

    republished: list[dict[str, Any]] = []
    swept: list[dict[str, Any]] = []

    for map_attr, cmd_kind in (
        ("outstandingActivationCmds", "activate"),
        ("outstandingWipeCmds", "wipe"),
    ):
        cmd_map = item.get(map_attr) or {}
        for cmd_id, issued_iso in cmd_map.items():
            try:
                issued_at = _parse_iso(str(issued_iso))
            except (TypeError, ValueError):
                # Unparseable timestamp — sweep defensively. Should never
                # happen with cloud-side device-api as the writer.
                swept.append({
                    "cmd_id": cmd_id,
                    "cmd_kind": cmd_kind,
                    "reason": "unparseable_ts",
                    "value": str(issued_iso),
                })
                _sweep_entry(serial, map_attr, cmd_id)
                continue

            if issued_at < cutoff:
                # Past the 24h ack window — sweep.
                swept.append({
                    "cmd_id": cmd_id,
                    "cmd_kind": cmd_kind,
                    "issued_at": str(issued_iso),
                    "age_hours": round((now - issued_at).total_seconds() / 3600, 2),
                })
                _sweep_entry(serial, map_attr, cmd_id)
                continue

            # Within window — re-publish.
            try:
                _publish_cmd(serial, cmd_kind, cmd_id, now_iso)
            except ClientError as e:
                logger.exception(
                    "coordinator_publish_failed",
                    extra={
                        "serial": serial,
                        "cmd_id": cmd_id,
                        "cmd_kind": cmd_kind,
                        "error": str(e),
                    },
                )
                # Continue to next cmd — don't let one publish failure
                # block the rest. IoT Rule retry is the safety net.
                continue

            age_seconds = (now - issued_at).total_seconds()
            republished.append({
                "cmd_id": cmd_id,
                "cmd_kind": cmd_kind,
                "issued_at": str(issued_iso),
                "age_seconds": round(age_seconds, 2),
            })

    # ── Metrics ──────────────────────────────────────────────────
    metrics.add_metric(
        name="device_cmd_republished_count",
        unit=MetricUnit.Count,
        value=len(republished),
    )
    metrics.add_metric(
        name="device_cmd_swept_stale_count",
        unit=MetricUnit.Count,
        value=len(swept),
    )

    # ── Audits ───────────────────────────────────────────────────
    # Per-republish audit — useful forensics when investigating a
    # "device got cmd X at time Y" question.
    for r in republished:
        emit_audit(
            AUDIT_DEVICE_CMD_REPUBLISHED,
            subject={"deviceSerial": serial},
            action="event",
            extra={
                "cmd_id": r["cmd_id"],
                "cmd_kind": r["cmd_kind"],
                "issued_at": r["issued_at"],
                "age_seconds": r["age_seconds"],
            },
        )

    # Summary audit for stale sweeps — single audit per invocation per
    # decision D9 (avoids spam on long-tail-outage reconnects where
    # many stale cmds might exist). Empty array → no audit emitted.
    if swept:
        emit_audit(
            AUDIT_DEVICE_CMD_SWEPT_STALE,
            subject={"deviceSerial": serial},
            action="event",
            extra={
                "swept_count": len(swept),
                "entries": swept,
            },
        )

    logger.info(
        "coordinator_ok",
        extra={
            "serial": serial,
            "republished_count": len(republished),
            "swept_count": len(swept),
            "republished_cmd_ids": [r["cmd_id"] for r in republished],
        },
    )
    return {
        "serial": serial,
        "republished": republished,
        "swept": swept,
    }

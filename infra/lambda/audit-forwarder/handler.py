"""
Audit forwarder — Phase 1.7.

Triggered by CloudWatch Logs subscription filter (`{ $.audit = true }`)
on each handler's log group. Decodes the gzipped subscription-filter
payload, parses each `audit:true` log line, stamps internal-access
severity if the actor's role is internal_*, and writes the events to
the dedicated `gosteady-{env}-audit` log group via PutLogEvents.

Destination log stream is partitioned by UTC date (`audit-YYYY-MM-DD`)
to keep any one stream's throughput under the CW Logs 5 MB/s per-stream
cap regardless of total volume. Streams are created lazily on first
write per day. The forwarder's own log group + the date-partitioned
audit streams together form the hot path; Firehose ships from the
audit log group to S3 (cold/immutable path) via a second subscription
filter set up at the stack level.

Failure posture: best-effort per event. A single bad event is logged
at WARNING and skipped; the rest of the batch proceeds. Hard failures
(KMS denial, throttling, audit log group missing) raise so the Lambda
Errors alarm catches them.
"""

from __future__ import annotations

import base64
import gzip
import json
import os
import re
from datetime import datetime, timezone
from typing import Any

import boto3
from aws_lambda_powertools import Logger

ENV = os.environ.get("ENVIRONMENT", "dev")
SERVICE = os.environ.get("POWERTOOLS_SERVICE_NAME", f"gosteady-{ENV}-audit-forwarder")
AUDIT_LOG_GROUP_NAME = os.environ.get(
    "AUDIT_LOG_GROUP_NAME", f"gosteady-{ENV}-audit"
)

logger = Logger(service=SERVICE)
_logs_client = boto3.client("logs")

# Date-partitioned destination streams. We track which streams we've
# already created in this Lambda's container so we don't pay the
# `CreateLogStream` round-trip on every invocation. The cache survives
# warm invocations; cold starts re-discover via the create-then-ignore-
# ResourceAlreadyExistsException pattern.
_created_streams: set[str] = set()

_INTERNAL_ROLE_RE = re.compile(r"^internal_")


def _ensure_stream(stream_name: str) -> None:
    """Create the destination log stream if not already present in this container."""
    if stream_name in _created_streams:
        return
    try:
        _logs_client.create_log_stream(
            logGroupName=AUDIT_LOG_GROUP_NAME,
            logStreamName=stream_name,
        )
    except _logs_client.exceptions.ResourceAlreadyExistsException:
        pass
    _created_streams.add(stream_name)


def _stream_name_for(event_payload: dict[str, Any]) -> str:
    """Pick the destination stream from the event's timestamp; fall back to wall-clock."""
    ts_str = event_payload.get("timestamp")
    if isinstance(ts_str, str):
        # Tolerate both `2026-05-17T14:18:01Z` and `2026-05-17T14:18:01.234Z`.
        date_part = ts_str[:10]
        if re.fullmatch(r"\d{4}-\d{2}-\d{2}", date_part):
            return f"audit-{date_part}"
    return f"audit-{datetime.now(timezone.utc).strftime('%Y-%m-%d')}"


def _maybe_stamp_internal_access(event_payload: dict[str, Any]) -> dict[str, Any]:
    """Auto-stamp internal_access + elevated severity when actor.role is internal_*."""
    actor = event_payload.get("actor") or {}
    role = actor.get("role") if isinstance(actor, dict) else None
    is_internal = isinstance(role, str) and _INTERNAL_ROLE_RE.match(role) is not None
    if is_internal:
        event_payload["internal_access"] = True
        # Don't downgrade an explicit "critical" or "warning" severity.
        if event_payload.get("severity") not in {"critical", "warning"}:
            event_payload["severity"] = "elevated"
    else:
        # Set defaults only if absent — don't clobber an explicit severity.
        event_payload.setdefault("internal_access", False)
        event_payload.setdefault("severity", "info")
    return event_payload


def _decode_subscription_filter_payload(event: dict[str, Any]) -> dict[str, Any]:
    """Subscription filter delivery wraps a gzip+base64 payload under `awslogs.data`."""
    awslogs = event.get("awslogs") or {}
    data_b64 = awslogs.get("data")
    if not data_b64:
        raise ValueError("subscription-filter event missing awslogs.data")
    raw = base64.b64decode(data_b64)
    decompressed = gzip.decompress(raw)
    return json.loads(decompressed)


def _build_put_log_events_batch(log_events: list[dict[str, Any]]) -> dict[str, list[dict[str, Any]]]:
    """
    Group decoded subscription-filter log events by destination stream
    (UTC date). Returns {stream_name: [{timestamp, message}, ...]}.

    A single subscription-filter delivery typically contains 1-N events
    from the same source stream, so most batches end up with one or two
    destination streams in practice. Across-day deliveries (e.g., a UTC
    midnight crossing) cleanly split.
    """
    batched: dict[str, list[dict[str, Any]]] = {}
    for evt in log_events:
        message = evt.get("message")
        if not isinstance(message, str):
            logger.warning("subscription_filter_event_missing_message", extra={"event": evt})
            continue
        try:
            parsed = json.loads(message)
        except (json.JSONDecodeError, TypeError) as exc:
            logger.warning(
                "audit_event_not_json", extra={"reason": str(exc), "message_prefix": message[:120]}
            )
            continue
        if not isinstance(parsed, dict) or parsed.get("audit") is not True:
            # Subscription filter shouldn't deliver these (pattern is `{ $.audit = true }`),
            # but defensive guard prevents accidentally forwarding non-audit lines.
            logger.warning(
                "filtered_event_missing_audit_marker",
                extra={"message_prefix": message[:120]},
            )
            continue
        stamped = _maybe_stamp_internal_access(parsed)
        stream_name = _stream_name_for(stamped)
        # CW PutLogEvents wants millisecond epoch + serialized JSON.
        ts_ms = evt.get("timestamp")
        if not isinstance(ts_ms, int):
            ts_ms = int(datetime.now(timezone.utc).timestamp() * 1000)
        batched.setdefault(stream_name, []).append(
            {"timestamp": ts_ms, "message": json.dumps(stamped, default=str)}
        )
    return batched


def _put(stream_name: str, entries: list[dict[str, Any]]) -> None:
    """
    PutLogEvents in timestamp order. CW Logs requires ascending order
    within a batch. We sort defensively in case subscription-filter
    delivery interleaves events (it shouldn't, but cheap insurance).
    """
    entries.sort(key=lambda e: e["timestamp"])
    _ensure_stream(stream_name)
    _logs_client.put_log_events(
        logGroupName=AUDIT_LOG_GROUP_NAME,
        logStreamName=stream_name,
        logEvents=entries,
    )


def handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    """
    Lambda entry point.

    The subscription-filter trigger delivers events asynchronously, so
    Lambda runtime retries on uncaught exceptions (twice) before
    routing to a dead-letter destination if configured. We don't
    configure a DLQ on the forwarder for v1 — the upstream
    `audit-forwarder-errors` alarm catches sustained failures.
    """
    try:
        decoded = _decode_subscription_filter_payload(event)
    except (ValueError, json.JSONDecodeError, gzip.BadGzipFile) as exc:
        logger.exception("subscription_filter_payload_decode_failed", extra={"error": str(exc)})
        raise

    log_events = decoded.get("logEvents") or []
    if not log_events:
        return {"forwarded": 0, "streams": []}

    batched = _build_put_log_events_batch(log_events)
    forwarded = 0
    for stream_name, entries in batched.items():
        _put(stream_name, entries)
        forwarded += len(entries)
    logger.info(
        "audit_forwarded",
        extra={
            "forwarded_count": forwarded,
            "destination_streams": sorted(batched.keys()),
            "source_log_group": decoded.get("logGroup"),
        },
    )
    return {"forwarded": forwarded, "streams": sorted(batched.keys())}

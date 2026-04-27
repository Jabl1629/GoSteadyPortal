"""
Powertools wrapper for Phase 1B handlers — structured logging,
tracing, metrics, audit emission, PII scrubbing.

Phase 1.6 will move Powertools into a shared Lambda layer and wire X-Ray
sampling. Until then, Powertools ships as a pip dependency in each
Lambda zip (per spec D8) and the Tracer is initialized but X-Ray-inert
because no tracing role is granted yet.

PII keys stripped from operational CloudWatch logs (per L14, AU3):
  displayName, dateOfBirth, email
Operational identifiers (patientId, clientId, serial, cmd_id, etc.)
are kept — they are not PII per the architecture.
"""

from __future__ import annotations

import json
import os
from datetime import datetime, timezone
from typing import Any

from aws_lambda_powertools import Logger, Metrics, Tracer
from aws_lambda_powertools.logging.formatter import LambdaPowertoolsFormatter

ENV = os.environ.get("ENVIRONMENT", "dev")
SERVICE = os.environ.get("POWERTOOLS_SERVICE_NAME", "gosteady-processing")

# PII keys to scrub at any nesting depth (L14, D16).
PII_KEYS = frozenset({"displayName", "dateOfBirth", "email"})


def _scrub(value: Any) -> Any:
    """Recursively replace PII-keyed values with the marker `[REDACTED]`."""
    if isinstance(value, dict):
        return {
            k: ("[REDACTED]" if k in PII_KEYS else _scrub(v))
            for k, v in value.items()
        }
    if isinstance(value, list):
        return [_scrub(v) for v in value]
    return value


class ScrubbingFormatter(LambdaPowertoolsFormatter):
    """Powertools formatter with PII redaction applied to every log record."""

    def serialize(self, log: dict) -> str:  # type: ignore[override]
        return json.dumps(_scrub(log), default=str)


_logger: Logger | None = None
_tracer: Tracer | None = None
_metrics: Metrics | None = None


def get_logger() -> Logger:
    global _logger
    if _logger is None:
        _logger = Logger(service=SERVICE, logger_formatter=ScrubbingFormatter())
    return _logger


def get_tracer() -> Tracer:
    global _tracer
    if _tracer is None:
        # Disabled flag keeps the Tracer wrapped but inert until Phase 1.6
        # turns on X-Ray. Decorators still work; they just don't emit spans.
        _tracer = Tracer(service=SERVICE, disabled=os.environ.get("POWERTOOLS_TRACER_DISABLED") == "true")
    return _tracer


def get_metrics() -> Metrics:
    global _metrics
    if _metrics is None:
        _metrics = Metrics(namespace=f"GoSteady/Processing/{ENV}", service=SERVICE)
    return _metrics


def audit_logger() -> Logger:
    """Same Logger instance, used for audit emissions; Phase 1.7 routes via subscription filter."""
    return get_logger()


def emit_audit(
    event: str,
    *,
    actor: dict[str, Any] | None = None,
    subject: dict[str, Any] | None = None,
    action: str = "create",
    before: dict[str, Any] | None = None,
    after: dict[str, Any] | None = None,
    extra: dict[str, Any] | None = None,
) -> None:
    """
    Emit a single structured audit log entry.

    Phase 1.7 will subscribe-filter this entry from CloudWatch into the
    dedicated audit log group + S3 Object Lock destination. Until then
    these lines live in the regular handler log group.
    """
    payload: dict[str, Any] = {
        "audit": True,
        "event": event,
        "actor": actor or {"system": SERVICE},
        "subject": subject or {},
        "action": action,
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }
    if before is not None:
        payload["before"] = before
    if after is not None:
        payload["after"] = after
    if extra is not None:
        payload["extra"] = extra
    get_logger().info("audit_event", extra=_scrub(payload))

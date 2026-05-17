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
from aws_lambda_powertools.metrics import EphemeralMetrics

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
    """
    Powertools formatter with PII redaction applied to every log record —
    EXCEPT audit-tagged records, which retain identifiers by design (Phase 1.7 L4).

    Audit events explicitly carry identifiers (`patientId`, `userId`, `email`
    for auth events, etc.) — that's the entire forensic value. Scrubbing them
    would silently break the compliance audit trail. The bypass is keyed on
    a top-level `audit:true` marker present on every audit emission via
    `emit_audit()` below.
    """

    def serialize(self, log: dict) -> str:  # type: ignore[override]
        if isinstance(log, dict) and log.get("audit") is True:
            return json.dumps(log, default=str)
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


def make_device_metrics(serial: str) -> EphemeralMetrics:
    """
    Per-invocation per-device telemetry metrics (Phase 1.6).

    Lives in the `GoSteady/Devices/{env}` namespace, dimensioned by `serial`,
    so the Per-Device Detail dashboard's GraphWidgets can filter by serial
    without dragging the processing-internal metrics in. EphemeralMetrics
    is the Powertools-documented pattern for "separate metric buffer with
    a different namespace from the default Metrics singleton" — flush is
    manual.

    Caller is responsible for calling `.flush_metrics()` before the Lambda
    returns, otherwise the EMF JSON is never written to stdout.
    """
    m = EphemeralMetrics(namespace=f"GoSteady/Devices/{ENV}", service=SERVICE)
    m.set_default_dimensions(serial=serial)
    return m


def audit_logger() -> Logger:
    """Same Logger instance, used for audit emissions; Phase 1.7 routes via subscription filter."""
    return get_logger()


#: Current audit schema version. Bump when changing the on-wire shape.
#: Readers should default to 1 for events without an explicit field.
AUDIT_SCHEMA_VERSION = 1


def emit_audit(
    event: str,
    *,
    actor: dict[str, Any] | None = None,
    subject: dict[str, Any] | None = None,
    action: str = "create",
    before: dict[str, Any] | None = None,
    after: dict[str, Any] | None = None,
    extra: dict[str, Any] | None = None,
    request_id: str | None = None,
) -> None:
    """
    Emit a single structured audit log entry.

    Phase 1.7 routes these entries via subscription filter into the dedicated
    `gosteady-{env}-audit` log group, where a Firehose subscription delivers
    them to the audit S3 bucket (Object Lock compliance mode in prod).

    The PII scrubber that ScrubbingFormatter applies to operational logs is
    bypassed for any record with `audit:true` — audit events must retain
    identifiers (patientId / userId / email / etc.) to be useful as
    compliance evidence. L4 of phase-1.7-audit.md.

    The `internal_access` + elevated-severity tags are auto-stamped by the
    audit-forwarder Lambda (centralized defense in depth — see D8 of the
    1.7 spec), not by callers here.
    """
    payload: dict[str, Any] = {
        "audit": True,
        "schema_version": AUDIT_SCHEMA_VERSION,
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
    if request_id is not None:
        payload["request_id"] = request_id
    # No pre-scrub: ScrubbingFormatter detects `audit:true` and skips scrubbing.
    get_logger().info("audit_event", extra=payload)

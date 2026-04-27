"""
Shared Python helpers for Phase 1B processing handlers.

Bundled into each Lambda zip at synth time by the ProcessingLambda CDK
construct. All four handlers (`activity-processor`, `heartbeat-processor`,
`threshold-detector`, `alert-handler`) import from this package as
`from _shared.<module> import ...`.
"""

from _shared.observability import (  # noqa: F401
    audit_logger,
    emit_audit,
    get_logger,
    get_metrics,
    get_tracer,
)
from _shared.patient_resolution import (  # noqa: F401
    PatientContext,
    PatientResolutionError,
    resolve_patient,
)
from _shared.thresholds import (  # noqa: F401
    BATTERY_CRITICAL,
    BATTERY_LOW,
    RSRP_LOST,
    RSRP_WEAK,
    determine_threshold_alerts,
)

"""
Audit event name catalog — Phase 1.7.

Importable string constants for every audit event the platform emits.
Mirrors the catalog table in `docs/specs/phase-1.7-audit.md`. Callers
should use these constants instead of bare strings so typos surface at
import time rather than as silently-misrouted audit events.

When adding a new event:
  1. Add the constant here under the appropriate section.
  2. Add the row to the catalog table in phase-1.7-audit.md.
  3. Wire the `emit_audit(event=AUDIT_<NAME>, ...)` call in the producing
     Lambda.
"""

from __future__ import annotations

# ── Device lifecycle (ARCHITECTURE.md §4) ─────────────────────────────
AUDIT_DEVICE_CREATED = "device.created"
AUDIT_DEVICE_CLAIMED = "device.claimed"
AUDIT_DEVICE_ASSIGNED = "device.assigned"
AUDIT_DEVICE_ACTIVATION_SENT = "device.activation_sent"
AUDIT_DEVICE_ACTIVATED = "device.activated"
AUDIT_DEVICE_PREACTIVATION_HEARTBEAT = "device.preactivation_heartbeat"
AUDIT_DEVICE_FIRST_HEARTBEAT = "device.first_heartbeat"
AUDIT_DEVICE_ASSIGNMENT_ENDED = "device.assignment_ended"
AUDIT_DEVICE_RESET_COMPLETE = "device.reset_complete"
AUDIT_DEVICE_FORCE_RESET = "device.force_reset"
AUDIT_DEVICE_DECOMMISSIONED = "device.decommissioned"
AUDIT_DEVICE_RECOVERED = "device.recovered"
AUDIT_DEVICE_OWNERSHIP_MOVED = "device.ownership_moved"
AUDIT_DEVICE_SNIPPET_UPLOADED = "device.snippet_uploaded"
# Phase 2A-DL additions (2026-05-17):
AUDIT_DEVICE_PROVISION_ROLLBACK = "device.provision_rollback"  # L14 — provision rolled back on IoT publish failure
AUDIT_DEVICE_STUCK_IN_PROVISIONED = "device.stuck_in_provisioned"  # L16 — alarm-emitted, not handler-emitted
# AA-battery-recycle additions (2026-05-17, coord §C20 + docs/specs/2026-05-17-aa-battery-recycle.md):
AUDIT_DEVICE_WIPE_REQUESTED = "device.wipe_requested"  # Cloud published wipe cmd on end-assignment
AUDIT_DEVICE_WIPE_COMPLETE = "device.wipe_complete"    # Firmware acked wipe via Shadow or heartbeat
AUDIT_DEVICE_RECYCLED = "device.recycled"              # Cloud auto-transitioned discontinued → ready_to_provision
AUDIT_DEVICE_WIPE_FAILED = "device.wipe_failed"        # Firmware reported wipe failure (warning severity)
AUDIT_DEVICE_BATTERY_SWAPPED = "device.battery_swapped"  # Mid-deployment cold-boot detected — no state change
# Connection-coordinator additions (2026-05-18, coord §C23 — addresses §C22 Finding 2 + Finding 7):
AUDIT_DEVICE_CMD_REPUBLISHED = "device.cmd_republished"  # Coordinator Lambda re-published a queued cmd on firmware connect
AUDIT_DEVICE_CMD_SWEPT_STALE = "device.cmd_swept_stale"  # Coordinator Lambda removed a stale outstandingXxxCmds entry (>24h old)

# ── Patient / activity / alert (Phase 1B-rev + Phase 2A) ──────────────
AUDIT_PATIENT_ACTIVITY_CREATE = "patient.activity.create"
AUDIT_PATIENT_ACTIVITY_READ = "patient.activity.read"
AUDIT_PATIENT_DETAIL_READ = "patient.detail.read"
AUDIT_PATIENT_LIST_READ = "patient.list.read"  # Phase 2A-RD: GET /me/patients; count-only subject per spec D8
AUDIT_ALERT_SYNTHETIC_CREATE = "alert.synthetic.create"
AUDIT_ALERT_DEVICE_CREATE = "alert.device.create"
AUDIT_ALERT_READ = "alert.read"
AUDIT_ALERT_ACK = "alert.ack"
AUDIT_CENSUS_ROSTER_READ = "census.roster.read"
AUDIT_PATIENT_THRESHOLDS_READ = "patient.thresholds.read"  # Phase 2A-AA
AUDIT_PATIENT_THRESHOLDS_UPDATE = "patient.thresholds.update"  # Phase 2A-AA: full before/after per spec L8

# ── Auth (Phase 0A-rev partial; Phase 2A wires up the rest) ───────────
AUDIT_AUTH_LOGIN = "auth.login"
AUDIT_AUTH_LOGIN_FAILED = "auth.login_failed"
AUDIT_AUTH_MFA_CHALLENGE = "auth.mfa_challenge"
AUDIT_AUTH_SESSION_READ = "auth.session.read"  # Phase 2A-0 stub endpoint (GET /api/v1/me)

# ── API middleware (Phase 2A-0) ───────────────────────────────────────
AUDIT_HANDLER_ERROR = "audit.handler.error"  # uncaught handler exception

# ── Role assignment (Phase 2A) ────────────────────────────────────────
AUDIT_ROLE_ASSIGNED = "role.assigned"
AUDIT_ROLE_REVOKED = "role.revoked"


#: Frozen set of all known event names. The audit-forwarder uses this
#: as a sanity check when stamping events; callers using `emit_audit()`
#: with an unknown name still emit (helper logs a warning, doesn't raise),
#: but spotting the divergence here lets ops catch typos at deploy time.
KNOWN_AUDIT_EVENTS = frozenset(
    {
        AUDIT_DEVICE_CREATED,
        AUDIT_DEVICE_CLAIMED,
        AUDIT_DEVICE_ASSIGNED,
        AUDIT_DEVICE_ACTIVATION_SENT,
        AUDIT_DEVICE_ACTIVATED,
        AUDIT_DEVICE_PREACTIVATION_HEARTBEAT,
        AUDIT_DEVICE_FIRST_HEARTBEAT,
        AUDIT_DEVICE_ASSIGNMENT_ENDED,
        AUDIT_DEVICE_RESET_COMPLETE,
        AUDIT_DEVICE_FORCE_RESET,
        AUDIT_DEVICE_DECOMMISSIONED,
        AUDIT_DEVICE_RECOVERED,
        AUDIT_DEVICE_OWNERSHIP_MOVED,
        AUDIT_DEVICE_SNIPPET_UPLOADED,
        AUDIT_DEVICE_PROVISION_ROLLBACK,
        AUDIT_DEVICE_STUCK_IN_PROVISIONED,
        AUDIT_DEVICE_WIPE_REQUESTED,
        AUDIT_DEVICE_WIPE_COMPLETE,
        AUDIT_DEVICE_RECYCLED,
        AUDIT_DEVICE_WIPE_FAILED,
        AUDIT_DEVICE_BATTERY_SWAPPED,
        AUDIT_DEVICE_CMD_REPUBLISHED,
        AUDIT_DEVICE_CMD_SWEPT_STALE,
        AUDIT_PATIENT_ACTIVITY_CREATE,
        AUDIT_PATIENT_ACTIVITY_READ,
        AUDIT_PATIENT_DETAIL_READ,
        AUDIT_PATIENT_LIST_READ,
        AUDIT_ALERT_SYNTHETIC_CREATE,
        AUDIT_ALERT_DEVICE_CREATE,
        AUDIT_ALERT_READ,
        AUDIT_ALERT_ACK,
        AUDIT_CENSUS_ROSTER_READ,
        AUDIT_PATIENT_THRESHOLDS_READ,
        AUDIT_PATIENT_THRESHOLDS_UPDATE,
        AUDIT_AUTH_LOGIN,
        AUDIT_AUTH_LOGIN_FAILED,
        AUDIT_AUTH_MFA_CHALLENGE,
        AUDIT_AUTH_SESSION_READ,
        AUDIT_HANDLER_ERROR,
        AUDIT_ROLE_ASSIGNED,
        AUDIT_ROLE_REVOKED,
    }
)

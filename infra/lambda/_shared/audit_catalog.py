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
AUDIT_DEVICE_OWNERSHIP_RELEASED = "device.ownership_released"  # internal_admin un-claim → owningClientId/Facility null; device becomes QR-claimable again (D2C rotation)
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
# Phase DT-0 (2026-07-01, docs/specs/phase-dt0-device-type-scaffold.md):
AUDIT_DEVICE_TYPE_CHANGED = "device.type_changed"  # internal_admin re-typed a registry record (dev: CLI runbook; endpoint deferred to first-need)
# Device fleet ops tooling (2026-07-12, docs/specs/device-fleet-ops-tooling.md):
AUDIT_DEVICE_FLEET_READ = "device.fleet.read"  # internal cross-tenant fleet scan (GET /admin/devices); count-only subject, mirrors patient.list.read
# D2C claim-binding + rotation (2026-07-13, docs/specs/d2c-claim-binding.md §7):
AUDIT_DEVICE_CLAIM_BOUND = "device.claim_bound"  # claimBoundPhone set (operator bind / release-and-bind); extra carries the MASKED phone only
AUDIT_DEVICE_CLAIM_BINDING_CLEARED = "device.claim_binding_cleared"  # claimBoundPhone explicitly cleared (bind {phone: null})
AUDIT_DEVICE_WIPE_REISSUED = "device.wipe_reissued"  # Coordinator minted a FRESH wipe cmd for a still-discontinued device whose prior wipe was swept (§5.6 un-strand)

# ── Patient / activity / alert (Phase 1B-rev + Phase 2A) ──────────────
AUDIT_PATIENT_ACTIVITY_CREATE = "patient.activity.create"
AUDIT_PATIENT_ACTIVITY_READ = "patient.activity.read"
AUDIT_PATIENT_DETAIL_READ = "patient.detail.read"
AUDIT_PATIENT_LIST_READ = "patient.list.read"  # Phase 2A-RD: GET /me/patients; count-only subject per spec D8
AUDIT_ALERT_SYNTHETIC_CREATE = "alert.synthetic.create"
AUDIT_ALERT_DEVICE_CREATE = "alert.device.create"
AUDIT_ALERT_READ = "alert.read"
AUDIT_ALERT_ACK = "alert.ack"
# Alert recurrence policy (2026-05-26-alert-recurrence-policy.md L6):
# emitted by threshold-detector + behavioral-detector when a
# continuous-condition alert's underlying condition clears and the
# system auto-acks the open alert. Distinct from AUDIT_ALERT_ACK so
# downstream consumers can filter system-driven acks from caregiver-
# driven ones via the `actor.type == 'system'` discriminator alone.
AUDIT_ALERT_AUTO_ACKNOWLEDGED = "alert.auto_acknowledged"
AUDIT_CENSUS_ROSTER_READ = "census.roster.read"
AUDIT_PATIENT_THRESHOLDS_READ = "patient.thresholds.read"  # Phase 2A-AA
AUDIT_PATIENT_THRESHOLDS_UPDATE = "patient.thresholds.update"  # Phase 2A-AA: full before/after per spec L8

# ── Patient management (Phase 2A-UM-P) ────────────────────────────────
AUDIT_PATIENT_CREATED = "patient.created"  # POST /patients (atomic create + optional provision)
AUDIT_PATIENT_CREATE_ROLLBACK = "patient.create_rollback"  # Patient row deleted after downstream provision failed
AUDIT_PATIENT_UPDATE = "patient.update"  # PATCH /patients/{id} — name / room / cross-facility transfer
AUDIT_PATIENT_DISCHARGE = "patient.discharge"  # POST /patients/{id}/discharge — cascades to device end-assignment via 2A-DL Lambda
AUDIT_PATIENT_RESUMED = "patient.resumed"  # POST /patients/{id}/resume — discharged→active flip (same record) + atomic re-provision
AUDIT_PATIENT_RESUME_ROLLBACK = "patient.resume_rollback"  # Patient flipped back to discharged after the re-provision failed
AUDIT_PATIENT_NOTIFICATIONS_PAUSE = "patient.notifications.pause"
AUDIT_PATIENT_NOTIFICATIONS_RESUME_MANUAL = "patient.notifications.resume_manual"  # DELETE /pause
AUDIT_PATIENT_NOTIFICATIONS_RESUME_AUTO = "patient.notifications.resume_auto"  # Activity Processor saw activity during pause window
AUDIT_PATIENT_NOTIFICATIONS_SUPPRESSED_PAUSED = "patient.notifications.suppressed_paused"  # Detector skipped a paused patient (sampled ≤1/day/patient per spec L9)
AUDIT_PATIENT_CARE_NOTE_UPDATE = "patient.care_note.update"  # PATCH /care-note (set/clear); full before/after per spec L14

# ── Behavioral detector (Phase 1C-slim) ──────────────────────────────
AUDIT_BEHAVIORAL_DETECTOR_RUN = "behavioral.detector.run"  # One per cron invocation; summarizes counts (facilitiesEvaluated, patientsEvaluated, alertsWritten, ...)

# ── Auth (Phase 0A-rev partial; Phase 2A wires up the rest) ───────────
AUDIT_AUTH_LOGIN = "auth.login"
AUDIT_AUTH_LOGIN_FAILED = "auth.login_failed"
AUDIT_AUTH_MFA_CHALLENGE = "auth.mfa_challenge"
AUDIT_AUTH_SESSION_READ = "auth.session.read"  # Phase 2A-0 stub endpoint (GET /api/v1/me)
# User-analytics (docs/specs/user-analytics.md) — wires the auth funnel.
# NOTE: the three stdlib trigger Lambdas (d2c-custom-auth, cognito-pre-token,
# d2c-pre-token) do NOT bundle _shared, so they hardcode these strings inline
# (with a back-reference comment). Keep the literals in sync with this catalog.
AUDIT_AUTH_OTP_REQUESTED = "auth.otp_requested"  # CreateAuthChallenge sent a FRESH D2C SMS-OTP (funnel numerator; resend-dedup at query time)
AUDIT_AUTH_OTP_VERIFY_FAILED = "auth.otp_verify_failed"  # wrong D2C OTP code submitted
AUDIT_AUTH_TOKEN_REFRESH = "auth.token_refresh"  # Pre-Token RefreshTokens trigger (both pools) — densifies the #4 active-time proxy

# ── User analytics reads (docs/specs/user-analytics.md) ───────────────
AUDIT_ANALYTICS_OVERVIEW_READ = "analytics.overview.read"  # internal cross-tenant population KPIs; count-only subject
AUDIT_ANALYTICS_USERS_READ = "analytics.users.read"  # internal per-user analytics table / drill-down; count-only subject

# ── Internal residents roster (docs/specs/user-analytics.md §pilot view) ──
AUDIT_RESIDENTS_LIST_READ = "residents.list.read"  # internal cross-tenant active-D2C roster; count-only subject

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
        AUDIT_DEVICE_TYPE_CHANGED,
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
        # Phase 2A-UM-P:
        AUDIT_PATIENT_CREATED,
        AUDIT_PATIENT_CREATE_ROLLBACK,
        AUDIT_PATIENT_UPDATE,
        AUDIT_PATIENT_DISCHARGE,
        AUDIT_PATIENT_RESUMED,
        AUDIT_PATIENT_RESUME_ROLLBACK,
        AUDIT_PATIENT_NOTIFICATIONS_PAUSE,
        AUDIT_PATIENT_NOTIFICATIONS_RESUME_MANUAL,
        AUDIT_PATIENT_NOTIFICATIONS_RESUME_AUTO,
        AUDIT_PATIENT_NOTIFICATIONS_SUPPRESSED_PAUSED,
        AUDIT_PATIENT_CARE_NOTE_UPDATE,
        # Phase 1C-slim:
        AUDIT_BEHAVIORAL_DETECTOR_RUN,
        AUDIT_AUTH_LOGIN,
        AUDIT_AUTH_LOGIN_FAILED,
        AUDIT_AUTH_MFA_CHALLENGE,
        AUDIT_AUTH_SESSION_READ,
        AUDIT_AUTH_OTP_REQUESTED,
        AUDIT_AUTH_OTP_VERIFY_FAILED,
        AUDIT_AUTH_TOKEN_REFRESH,
        AUDIT_ANALYTICS_OVERVIEW_READ,
        AUDIT_ANALYTICS_USERS_READ,
        AUDIT_RESIDENTS_LIST_READ,
        AUDIT_HANDLER_ERROR,
        AUDIT_ROLE_ASSIGNED,
        AUDIT_ROLE_REVOKED,
    }
)

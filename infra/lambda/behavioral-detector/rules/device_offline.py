"""
"Device offline" + "Device silent" rules — Phase 1C-slim, spec L11 + L12.

Triggers hourly (not facility-local-time-bound — applies to every device
regardless of local time).

Two-tier escalation:
  - device_offline  (severity WARNING):  lastSeen > 2h  ago
  - device_silent   (severity CRITICAL): lastSeen > 24h ago

Only fires for devices currently in `active_monitoring` state. Pre-activation
devices (`provisioned` not yet acked) are NOT offline-detected per ARCH §8
+ 1B-rev pre-activation suppression — same rationale: a device that hasn't
yet ack'd its activation can't be "offline" yet.

Severity escalation: when a device crosses from 2h-offline to 24h-silent,
we fire a NEW alert (device_silent) rather than updating the existing
device_offline. Per spec Q2 lean: caregiver may have acked the 2h alert
thinking it's transient; the 24h escalation deserves its own UX surface.
Audit trail is cleaner with two distinct events.

The single `evaluate()` function returns whichever rule (if any) fires,
in escalation order: silent first (more severe), then offline.
"""

from __future__ import annotations

from typing import Any, Optional

from .types import (
    ALERT_DEVICE_OFFLINE,
    ALERT_DEVICE_SILENT,
    DEFAULT_OFFLINE_THRESHOLD_HOURS,
    DEFAULT_SILENT_THRESHOLD_HOURS,
    SEVERITY_CRITICAL,
    SEVERITY_WARNING,
    SOURCE_OFFLINE,
    AlertCandidate,
)


def evaluate(
    *,
    device_status: str,
    device_last_seen_epoch: Optional[int],
    now_epoch: int,
    local_now_iso: str,
    offline_threshold_hours: int = DEFAULT_OFFLINE_THRESHOLD_HOURS,
    silent_threshold_hours: int = DEFAULT_SILENT_THRESHOLD_HOURS,
) -> Optional[AlertCandidate]:
    """
    Returns AlertCandidate for whichever tier fires (silent > offline > none).

    Args:
      device_status: Device Registry status field. Must equal 'active_monitoring'
        for any rule to fire (pre-activation suppression).
      device_last_seen_epoch: Device Registry lastSeen in epoch seconds.
        None → device has never reported → won't fire (caller should
        treat as separate "never-activated" condition handled elsewhere).
      now_epoch: current epoch seconds (caller-injected for determinism).
      local_now_iso: ISO 8601 in facility-local time.
      offline_threshold_hours: trigger threshold for device_offline (warning).
      silent_threshold_hours: trigger threshold for device_silent (critical).
    """
    if device_status != "active_monitoring":
        return None
    if device_last_seen_epoch is None:
        return None
    hours_offline = (now_epoch - device_last_seen_epoch) / 3600
    if hours_offline >= silent_threshold_hours:
        return AlertCandidate(
            alert_type=ALERT_DEVICE_SILENT,
            severity=SEVERITY_CRITICAL,
            source=SOURCE_OFFLINE,
            event_timestamp_iso=local_now_iso,
            data={
                "lastSeenEpoch": device_last_seen_epoch,
                "hoursOffline": round(hours_offline, 1),
                "thresholdHours": silent_threshold_hours,
            },
        )
    if hours_offline >= offline_threshold_hours:
        return AlertCandidate(
            alert_type=ALERT_DEVICE_OFFLINE,
            severity=SEVERITY_WARNING,
            source=SOURCE_OFFLINE,
            event_timestamp_iso=local_now_iso,
            data={
                "lastSeenEpoch": device_last_seen_epoch,
                "hoursOffline": round(hours_offline, 1),
                "thresholdHours": offline_threshold_hours,
            },
        )
    return None

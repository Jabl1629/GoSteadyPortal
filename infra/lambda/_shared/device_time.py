"""
Device time-reliability helpers (cloud side of the 2026-06-18 spec, coord §C47).

Firmware 0.17.0-time sources absolute UTC from the NCS ``date_time`` lib
(NITZ → NTP → app-set) and, alongside the device ISO ``session_start`` /
``session_end`` / ``ts``, now emits:

  clock_synced (bool), session_start_uptime_ms, session_end_uptime_ms,
  publish_uptime_ms, boot_count, time_source.

When the device clock was synced, its ISO times are authoritative. When it was
NOT (``clock_synced=false``) — or the device ISO is implausible (the legacy
2080 case from pre-0.17.0 firmware on a no-NITZ roaming SIM) — the cloud
reconstructs absolute time from its own trusted receive time (``ingested_at``)
minus the device's monotonic uptime age. The device's ``k_uptime`` is always
reliable; only the absolute anchor failed. Activity is **never dropped** for
lack of time: worst case it gets a flagged best-effort time.

Pure module: only stdlib ``datetime``. No boto3 / powertools / ``_shared``
imports, so it unit-tests in isolation.
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

# Plausible-year window — mirrors the firmware-side gate in
# gosteady-firmware/src/gs_time.h ([2024, 2050]).
PLAUSIBLE_MIN_YEAR = 2024
PLAUSIBLE_MAX_YEAR = 2050

# Reconstruction age ceiling. The firmware uptimes are uint32 milliseconds and
# wrap at ~49.7 days; an age beyond this is treated as a wrapped/garbage value
# (refuse to reconstruct rather than emit a wildly wrong time).
_MAX_AGE_MS = 60 * 86_400 * 1000  # 60 days
# A device-reported duration longer than this is not trusted for the
# best-effort "uncertain" fallback.
_MAX_DURATION = timedelta(days=1)

# time_source values the cloud assigns (distinct from the firmware's
# "nitz"/"ntp"/"unsynced", which pass through when the device clock is trusted).
TIME_SOURCE_DEVICE = "device"                 # device ISO trusted, no firmware time_source given
TIME_SOURCE_RECONSTRUCTED = "cloud_reconstructed"
TIME_SOURCE_UNCERTAIN = "uncertain"


def year_plausible(dt: datetime | None) -> bool:
    """True iff ``dt`` falls in the plausible-year window [2024, 2050]."""
    return dt is not None and PLAUSIBLE_MIN_YEAR <= dt.year <= PLAUSIBLE_MAX_YEAR


def parse_iso(ts) -> datetime | None:
    """Parse an ISO-8601 string to an aware UTC datetime, or None if it is
    missing / not a string / unparseable. Never raises."""
    if not isinstance(ts, str) or not ts:
        return None
    try:
        dt = datetime.fromisoformat(ts.replace("Z", "+00:00"))
    except (TypeError, ValueError):
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc)


def _to_int(value):
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def _try_reconstruct(event: dict, ingested_at: datetime):
    """Reconstruct (session_start, session_end) from the monotonic uptimes +
    the trusted receive time. Returns a (start, end) tuple or None if the
    uptimes are missing / inconsistent / wrapped.

    spec §4.3:
        age_end   = publish_uptime_ms - session_end_uptime_ms
        age_start = publish_uptime_ms - session_start_uptime_ms
        session_end   = ingested_at - age_end
        session_start = ingested_at - age_start
    """
    pub = _to_int(event.get("publish_uptime_ms"))
    su = _to_int(event.get("session_start_uptime_ms"))
    eu = _to_int(event.get("session_end_uptime_ms"))
    if pub is None or su is None or eu is None:
        return None
    if pub <= 0 or eu <= 0 or su < 0:
        return None

    age_end = pub - eu
    age_start = pub - su
    # Ages must be non-negative and correctly ordered (start older than end).
    # A negative or out-of-order value means a uint32 wrap or a corrupt
    # payload — refuse rather than emit garbage.
    if age_end < 0 or age_start < 0 or age_start < age_end:
        return None
    if age_start > _MAX_AGE_MS:
        return None

    start = ingested_at - timedelta(milliseconds=age_start)
    end = ingested_at - timedelta(milliseconds=age_end)
    if not (year_plausible(start) and year_plausible(end)):
        return None
    return start, end


def resolve_session_times(event: dict, ingested_at: datetime):
    """Resolve the authoritative (session_start, session_end, time_source) for
    an activity event. Never raises; always returns usable aware-UTC datetimes
    with start <= end (the never-drop guarantee).

    Decision order:
      1. Device clock trusted (clock_synced != False) AND device ISO plausible
         → use the device ISO. time_source = firmware's value, else "device".
      2. Otherwise reconstruct from uptimes + ingested_at → "cloud_reconstructed".
      3. Otherwise best-effort: preserve the device-reported duration if sane,
         anchored at ingested_at → "uncertain" (flagged, not dropped).
    """
    clock_synced = event.get("clock_synced")  # True / False / None (pre-0.17 fw)
    dev_start = parse_iso(event.get("session_start"))
    dev_end = parse_iso(event.get("session_end"))
    device_ok = (
        dev_start is not None
        and dev_end is not None
        and dev_end >= dev_start
        and year_plausible(dev_start)
        and year_plausible(dev_end)
    )

    if clock_synced is not False and device_ok:
        src = event.get("time_source")
        if not isinstance(src, str) or not src:
            src = TIME_SOURCE_DEVICE
        return dev_start, dev_end, src

    recon = _try_reconstruct(event, ingested_at)
    if recon is not None:
        return recon[0], recon[1], TIME_SOURCE_RECONSTRUCTED

    # Cannot reconstruct (legacy unsynced firmware with no uptimes, or
    # inconsistent uptimes). Preserve the reported duration if we have a sane
    # one so the session length stays meaningful; anchor the end at ingest.
    if dev_start is not None and dev_end is not None and timedelta(0) <= (dev_end - dev_start) <= _MAX_DURATION:
        return ingested_at - (dev_end - dev_start), ingested_at, TIME_SOURCE_UNCERTAIN
    return ingested_at, ingested_at, TIME_SOURCE_UNCERTAIN


def resolve_heartbeat_ts(event: dict, ingested_at: datetime):
    """Resolve the effective heartbeat timestamp. Returns
    (effective_ts: datetime, used_ingest: bool).

    When the device clock was synced and its ``ts`` is plausible, use it.
    Otherwise (clock_synced=false, or a missing/implausible ts) substitute the
    server receive time, so device-health ``lastSeen`` never shows 1980/2080
    and a device with no time still registers as alive (spec §6 / Open-Q4).
    """
    clock_synced = event.get("clock_synced")  # True / False / None (pre-0.17 fw)
    ts = parse_iso(event.get("ts"))
    if clock_synced is not False and year_plausible(ts):
        return ts, False
    return ingested_at, True

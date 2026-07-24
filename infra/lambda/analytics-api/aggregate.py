"""
Pure aggregation core for the internal user-analytics dashboard.

Everything here is side-effect-free and unit-testable without AWS — the
handler feeds it raw rows (DDB activity + CloudWatch Logs Insights audit
events) and gets back the shaped metrics. Keeping the math here (not in
queries.py / handler.py) is deliberate: the funnel + sessionization logic is
the part most worth testing, per docs/specs/user-analytics.md T1-T3.

Metric definitions (locked with the operator 2026-07-21):
  #1 offloads       — 1 Activity Series row = 1 session; bucket by day + hour.
  #2 logins         — count of auth.login events, split by extra.method.
  #3 otp abandoned  — auth.otp_requested with no auth.login(sms_otp) within a
                      15-min window; resends inside the window collapse to one
                      funnel entry (resend-dedup).
  #4 active time    — sessionize a user's audit READ + token_refresh + login
                      timestamps by a 30-min idle gap; Σ(last-first) per session.
  #5 coach turns    — count of coach.chat.turn events.
"""

from __future__ import annotations

from collections import defaultdict
from datetime import datetime, timezone
from typing import Any, Iterable

# Idle gap that splits one user's activity into separate sessions. 30 min
# matches the customer token idle window (user-analytics.md L3 / #4).
ACTIVE_SESSION_GAP_SECONDS = 30 * 60

# OTP request→login window. Also the resend-dedup window: two requests for the
# same user within this span are one funnel entry (user-analytics.md #3, 15 min
# = OTP validity).
OTP_WINDOW_SECONDS = 15 * 60

# Audit read events that count as "actively looking at the data" for the #4
# proxy, plus the token_refresh / login heartbeats that densify it.
ACTIVE_SIGNAL_EVENTS = frozenset({
    "auth.login",
    "auth.token_refresh",
    "auth.session.read",
    "patient.list.read",
    "patient.detail.read",
    "patient.activity.read",
    "alert.read",
    "census.roster.read",
    "coach.chat.turn",
})


def parse_epoch(value: Any) -> float | None:
    """Best-effort epoch-seconds from an ISO-8601 string, epoch int/float, or ms.

    Tolerates trailing 'Z', fractional seconds, and the CloudWatch Logs Insights
    '@timestamp' form 'YYYY-MM-DD HH:MM:SS.mmm' (space separator, no zone → UTC).
    """
    if value is None or value == "":
        return None
    if isinstance(value, (int, float)):
        # Heuristic: treat >1e12 as epoch-millis (Insights sometimes returns ms).
        return float(value) / 1000.0 if value > 1e12 else float(value)
    if not isinstance(value, str):
        return None
    s = value.strip().replace("Z", "+00:00")
    # Insights '@timestamp' uses a space between date and time.
    if " " in s and "T" not in s:
        s = s.replace(" ", "T", 1)
    try:
        dt = datetime.fromisoformat(s)
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.timestamp()


def hour_of_day(value: Any) -> int | None:
    ep = parse_epoch(value)
    if ep is None:
        return None
    return datetime.fromtimestamp(ep, tz=timezone.utc).hour


# ── #1 offloads ────────────────────────────────────────────────────────

def bucket_offloads(rows: Iterable[dict[str, Any]]) -> dict[str, Any]:
    """Total + per-day (patient-local `date`) + per-hour-of-day (UTC) counts.

    Each Activity Series row is exactly one offload, so this is a row count
    sliced two ways. `date` is the patient-local calendar day already stamped
    on the row; the hour histogram buckets session_end (`timestamp`) by UTC hour.
    """
    per_day: dict[str, int] = defaultdict(int)
    per_hour: dict[int, int] = defaultdict(int)
    total = 0
    for r in rows:
        total += 1
        d = r.get("date")
        if d:
            per_day[str(d)] += 1
        h = hour_of_day(r.get("timestamp") or r.get("sessionEnd"))
        if h is not None:
            per_hour[h] += 1
    return {
        "total": total,
        "perDay": [{"date": k, "count": per_day[k]} for k in sorted(per_day)],
        "perHour": [{"hour": h, "count": per_hour.get(h, 0)} for h in range(24)],
    }


def offloads_by_user(rows: Iterable[dict[str, Any]],
                     patient_to_user: dict[str, str]) -> dict[str, int]:
    """Count offloads per USER, mapping each row's patientId → userId.

    Rows whose patient has no known user (e.g. an account-less walker) fall
    into the sentinel key '' so the caller can surface an 'unattributed' bucket.
    """
    out: dict[str, int] = defaultdict(int)
    for r in rows:
        uid = patient_to_user.get(r.get("patientId", ""), "")
        out[uid] += 1
    return dict(out)


# ── #4 active time ─────────────────────────────────────────────────────

def sessionize(epochs: Iterable[float], gap_seconds: int = ACTIVE_SESSION_GAP_SECONDS
               ) -> tuple[int, float]:
    """Split one user's event epochs into sessions by idle gap.

    Returns (session_count, active_seconds). active_seconds sums (last-first)
    per session — a lone event contributes 0 (a single ping isn't a duration).
    This is the coarse #4 proxy: we can't see continuous screen-time, only the
    span bracketed by audit reads + token refreshes.
    """
    ts = sorted(e for e in epochs if e is not None)
    if not ts:
        return 0, 0.0
    sessions: list[tuple[float, float]] = []
    start = prev = ts[0]
    for t in ts[1:]:
        if t - prev > gap_seconds:
            sessions.append((start, prev))
            start = t
        prev = t
    sessions.append((start, prev))
    return len(sessions), float(sum(end - s for s, end in sessions))


# ── #3 OTP funnel ──────────────────────────────────────────────────────

def _collapse_requests(times: list[float], window: int) -> list[float]:
    """Resend-dedup: collapse requests <= `window` apart into one entry."""
    entries: list[float] = []
    last: float | None = None
    for t in sorted(times):
        if last is None or t - last > window:
            entries.append(t)
        last = t
    return entries


def otp_funnel_by_user(
    requested_by_user: dict[str, list[float]],
    sms_login_by_user: dict[str, list[float]],
    verify_failed_by_user: dict[str, list[float]],
    window: int = OTP_WINDOW_SECONDS,
) -> dict[str, dict[str, int]]:
    """Per-user OTP funnel. A collapsed request is 'completed' iff an SMS-OTP
    login for the same user lands in [request, request+window]."""
    out: dict[str, dict[str, int]] = {}
    users = set(requested_by_user) | set(sms_login_by_user) | set(verify_failed_by_user)
    for u in users:
        reqs = _collapse_requests(requested_by_user.get(u, []), window)
        logins = sorted(sms_login_by_user.get(u, []))
        completed = 0
        for r in reqs:
            if any(r <= lg <= r + window for lg in logins):
                completed += 1
        requested = len(reqs)
        out[u] = {
            "requested": requested,
            "completed": completed,
            "abandoned": max(0, requested - completed),
            "verifyFailed": len(verify_failed_by_user.get(u, [])),
        }
    return out


def funnel_totals(per_user: dict[str, dict[str, int]]) -> dict[str, Any]:
    requested = sum(v["requested"] for v in per_user.values())
    completed = sum(v["completed"] for v in per_user.values())
    abandoned = sum(v["abandoned"] for v in per_user.values())
    verify_failed = sum(v["verifyFailed"] for v in per_user.values())
    return {
        "requested": requested,
        "completed": completed,
        "abandoned": abandoned,
        "verifyFailed": verify_failed,
        # Rounded 0-1; None when nothing was requested (avoid divide-by-zero /
        # a misleading 0% when the denominator is empty).
        "abandonmentRate": round(abandoned / requested, 4) if requested else None,
    }


# ── event-stream reshaping (audit rows → per-user structures) ──────────

def index_events(events: Iterable[dict[str, Any]]) -> dict[str, Any]:
    """One pass over the raw audit event rows → the per-user structures every
    metric needs. Each event row is a dict with at least 'event', 'uid', 'ts'
    (epoch float), and optionally 'method'.

    Returns a dict with:
      logins_by_method: dict[method -> count]
      login_epochs_by_user, requested_by_user, verify_failed_by_user,
      sms_login_by_user, active_epochs_by_user, coach_by_user: dict[uid -> ...]
      users_seen: set[uid]
    """
    logins_by_method: dict[str, int] = defaultdict(int)
    login_epochs_by_user: dict[str, list[float]] = defaultdict(list)
    requested_by_user: dict[str, list[float]] = defaultdict(list)
    verify_failed_by_user: dict[str, list[float]] = defaultdict(list)
    sms_login_by_user: dict[str, list[float]] = defaultdict(list)
    active_epochs_by_user: dict[str, list[float]] = defaultdict(list)
    coach_by_user: dict[str, int] = defaultdict(int)
    users_seen: set[str] = set()

    for e in events:
        name = e.get("event", "")
        uid = e.get("uid", "") or ""
        ts = e.get("ts")
        if uid:
            users_seen.add(uid)
        if name in ACTIVE_SIGNAL_EVENTS and ts is not None and uid:
            active_epochs_by_user[uid].append(ts)
        if name == "auth.login":
            method = e.get("method") or "unknown"
            logins_by_method[method] += 1
            if uid and ts is not None:
                login_epochs_by_user[uid].append(ts)
                if method == "sms_otp":
                    sms_login_by_user[uid].append(ts)
        elif name == "auth.otp_requested":
            if uid and ts is not None:
                requested_by_user[uid].append(ts)
        elif name == "auth.otp_verify_failed":
            if uid and ts is not None:
                verify_failed_by_user[uid].append(ts)
        elif name == "coach.chat.turn":
            if uid:
                coach_by_user[uid] += 1

    return {
        "logins_by_method": dict(logins_by_method),
        "login_epochs_by_user": dict(login_epochs_by_user),
        "requested_by_user": dict(requested_by_user),
        "verify_failed_by_user": dict(verify_failed_by_user),
        "sms_login_by_user": dict(sms_login_by_user),
        "active_epochs_by_user": dict(active_epochs_by_user),
        "coach_by_user": dict(coach_by_user),
        "users_seen": users_seen,
    }

"""
Coach-daily theme evaluators — AI Coach C2 §5.2 (+ C3 weekly recap).

Pure functions over computed Features → Optional[CoachTheme]. Positive-and-
gentle counterparts to behavioral-detector's decline rules. Consolidated in
one module (the coach themes are simpler + closely related) rather than one
file per rule; each is independently unit-tested.
"""
from __future__ import annotations

from typing import Optional

from features import Features
from .types import (
    CoachTheme,
    DEFAULT_ABOVE_TYPICAL_MARGIN,
    DEFAULT_IMPROVING_MARGIN,
    DEFAULT_QUIET_DAYS_FOR_NUDGE,
    MIN_ACTIVE_DAYS,
    PRIORITY_CELEBRATE,
    PRIORITY_ENCOURAGE,
    PRIORITY_NUDGE,
    PRIORITY_RECAP,
    STREAK_MILESTONES,
    THEME_ABOVE_TYPICAL,
    THEME_IMPROVING_TREND,
    THEME_QUIET_NUDGE,
    THEME_STREAK_MILESTONE,
    THEME_WEEKLY_RECAP,
)


def eval_above_typical(f: Features, *, margin: float = DEFAULT_ABOVE_TYPICAL_MARGIN) -> Optional[CoachTheme]:
    """Celebrate a day well above the 7-day median."""
    if f.active_days < MIN_ACTIVE_DAYS or f.median7 <= 0 or f.today <= 0:
        return None
    if f.today > int(f.median7 * (1 + margin)):
        return CoachTheme(
            theme_type=THEME_ABOVE_TYPICAL, priority=PRIORITY_CELEBRATE,
            event_timestamp_iso=f.local_now_iso,
            data={"todayActiveMinutes": f.today, "median7Day": f.median7},
        )
    return None


def eval_improving_trend(f: Features, *, margin: float = DEFAULT_IMPROVING_MARGIN) -> Optional[CoachTheme]:
    """Encourage a rising 7-day vs prior-23-day median."""
    if f.active_days < MIN_ACTIVE_DAYS or f.median_prior23 <= 0:
        return None
    if f.median7 > int(f.median_prior23 * (1 + margin)):
        return CoachTheme(
            theme_type=THEME_IMPROVING_TREND, priority=PRIORITY_ENCOURAGE,
            event_timestamp_iso=f.local_now_iso,
            data={"median7Day": f.median7, "medianPriorWeeks": f.median_prior23},
        )
    return None


def eval_streak_milestone(f: Features) -> Optional[CoachTheme]:
    """Celebrate hitting a consecutive-active-day milestone."""
    if f.streak in STREAK_MILESTONES:
        return CoachTheme(
            theme_type=THEME_STREAK_MILESTONE, priority=PRIORITY_CELEBRATE,
            event_timestamp_iso=f.local_now_iso,
            data={"streakDays": f.streak},
        )
    return None


def eval_quiet_nudge(
    f: Features, *, quiet_days: int = DEFAULT_QUIET_DAYS_FOR_NUDGE, device_online: bool = True
) -> Optional[CoachTheme]:
    """Gently nudge after a quiet stretch — only for established users on an
    online device (never a brand-new user, never a dead device)."""
    if f.active_days < MIN_ACTIVE_DAYS or not device_online or f.today != 0:
        return None
    total_quiet = 1  # today is 0
    for d in reversed(f.per_day):
        if d == 0:
            total_quiet += 1
        else:
            break
    if total_quiet >= quiet_days:
        return CoachTheme(
            theme_type=THEME_QUIET_NUDGE, priority=PRIORITY_NUDGE,
            event_timestamp_iso=f.local_now_iso,
            data={"quietDays": total_quiet},
        )
    return None


def eval_weekly_recap(f: Features) -> Optional[CoachTheme]:
    """A lowest-priority weekly summary (C3). Fires on the recap day if there
    is any history to summarize."""
    if f.active_days < 1:
        return None
    return CoachTheme(
        theme_type=THEME_WEEKLY_RECAP, priority=PRIORITY_RECAP,
        event_timestamp_iso=f.local_now_iso,
        data={
            "last7ActiveMinutes": f.last7,
            "bestDayActiveMinutes": f.best,
            "activeDaysLast7": sum(1 for d in f.per_day[-7:] if d > 0),
        },
    )

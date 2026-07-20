"""
Message-worthiness selection — AI Coach C2 §5.3. Code (not the model) picks
at most one theme per day, by priority. The ≥48 h frequency cap is enforced
in the handler (needs a DB read); this stays pure.
"""
from __future__ import annotations

from typing import Optional

from features import Features
from rules import themes
from rules.types import (
    CoachTheme,
    THEME_ABOVE_TYPICAL,
    THEME_IMPROVING_TREND,
    THEME_QUIET_NUDGE,
    THEME_STREAK_MILESTONE,
    THEME_WEEKLY_RECAP,
)

# Deterministic tie-break within a priority tier (earlier = preferred).
_ORDER = (
    THEME_STREAK_MILESTONE,
    THEME_ABOVE_TYPICAL,
    THEME_IMPROVING_TREND,
    THEME_QUIET_NUDGE,
    THEME_WEEKLY_RECAP,
)


def select_theme(
    f: Features, *, is_recap_day: bool = False, device_online: bool = True
) -> Optional[CoachTheme]:
    """Pick ≤1 theme for the day (celebrate > encourage > gentle-nudge >
    weekly-recap). Returns None on a quiet day → the coach stays silent."""
    candidates: list[CoachTheme] = []
    for t in (
        themes.eval_above_typical(f),
        themes.eval_improving_trend(f),
        themes.eval_streak_milestone(f),
        themes.eval_quiet_nudge(f, device_online=device_online),
    ):
        if t is not None:
            candidates.append(t)
    if is_recap_day:
        r = themes.eval_weekly_recap(f)
        if r is not None:
            candidates.append(r)
    if not candidates:
        return None
    candidates.sort(
        key=lambda t: (t.priority, len(_ORDER) - _ORDER.index(t.theme_type)),
        reverse=True,
    )
    return candidates[0]

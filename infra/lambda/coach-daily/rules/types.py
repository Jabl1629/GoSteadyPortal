"""
Shared types for coach-daily theme evaluators — AI Coach C2 (§5.2) + C3 recap.

Each theme evaluator is a pure function: takes computed activity features +
local time, returns Optional[CoachTheme] or None. No DDB, no clock, no env —
trivially unit-testable, mirroring behavioral-detector/rules/types.py.

The handler turns a selected CoachTheme into the LLM copywrite prompt (numbers
come from `data`, which is also the output-lint allow-list) and the inbox
PutItem. Deterministic triggers choose the moment; the LLM only writes words.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

# Theme priority — higher wins the day. Umbrella D6.3: celebrate > encourage >
# gentle-nudge > weekly-recap.
PRIORITY_CELEBRATE = 40   # above-typical, streak milestone, personal best
PRIORITY_ENCOURAGE = 30   # improving trend
PRIORITY_NUDGE = 20       # gentle quiet-day nudge
PRIORITY_RECAP = 10       # weekly recap (C3)

# Theme type constants (become the inbox item's themeType + audit extra).
THEME_ABOVE_TYPICAL = "above_typical_activity"
THEME_IMPROVING_TREND = "improving_trend"
THEME_STREAK_MILESTONE = "streak_milestone"
THEME_QUIET_NUDGE = "quiet_nudge"
THEME_WEEKLY_RECAP = "weekly_recap"

# Cold-start guard — same 14-day floor as the behavioral rules.
MIN_ACTIVE_DAYS = 14

# Tunable margins (overridable via handler env).
DEFAULT_ABOVE_TYPICAL_MARGIN = 0.25   # today > 7d median × (1 + margin)
DEFAULT_IMPROVING_MARGIN = 0.15       # 7d median > prior-23d median × (1 + margin)
STREAK_MILESTONES = (3, 5, 7, 14, 21, 30, 60, 100)
DEFAULT_QUIET_DAYS_FOR_NUDGE = 2      # consecutive zero-activity days (device online)
DEFAULT_RECAP_DOW = 6                  # Sunday (Python weekday(): Mon=0 … Sun=6)


@dataclass(frozen=True)
class CoachTheme:
    theme_type: str
    priority: int
    # ISO 8601 facility-local (with tz offset). Audit + the date bucket for the
    # once-per-day inbox SK are derived from this.
    event_timestamp_iso: str
    # The numbers the copywrite may cite — and the ONLY numerals the output
    # lint permits in the generated note (C1-D4 anti-hallucination).
    data: dict[str, Any] = field(default_factory=dict)

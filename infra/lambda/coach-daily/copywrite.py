"""
Proactive-note copywrite — AI Coach C2 §5.4 (+ C3 goal-aware).

Builds the LLM prompt from the selected theme + its exact numbers + the memory
profile + active goals, and calls the shared CoachLLM. The generated note runs
the SAME C1 §6 output lint (the handler owns that); build_allowlist supplies the
numerals the lint permits. Numbers come ONLY from theme.data (anti-hallucination).
"""
from __future__ import annotations

from typing import Any

from _shared import coach_prompts
from rules.types import (
    THEME_ABOVE_TYPICAL,
    THEME_IMPROVING_TREND,
    THEME_QUIET_NUDGE,
    THEME_STREAK_MILESTONE,
    THEME_WEEKLY_RECAP,
    CoachTheme,
)

_THEME_BRIEF = {
    THEME_ABOVE_TYPICAL: "They were more active than usual today. Celebrate it warmly.",
    THEME_IMPROVING_TREND: "Their activity has been trending up over the past week. Encourage them.",
    THEME_STREAK_MILESTONE: "They have kept up a streak of active days. Celebrate the milestone.",
    THEME_QUIET_NUDGE: "It has been a quiet few days. Gently and warmly invite a short walk — no guilt, no pressure.",
    THEME_WEEKLY_RECAP: "Give a short, warm recap of their week with one encouraging thought.",
}


def build_allowlist(theme: CoachTheme) -> frozenset[str]:
    """The numeral strings the output lint will permit in the generated note:
    the theme's own numbers, plus structural calendar references (week/month)
    so phrasing like 'this week' / 'the last 7 days' isn't falsely dropped.
    These calendar numbers are never activity claims."""
    allow: set[str] = {"7", "30"}
    for v in theme.data.values():
        if isinstance(v, bool):
            continue
        if isinstance(v, int):
            allow.add(str(v))
    return frozenset(allow)


def build_prompt(
    theme: CoachTheme, *, memory_text: str = "", goals_text: str = "", tone: str | None = None
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    """(system blocks, messages) for CoachLLM.chat. No cachePoint — one-shot
    per patient. Tone is the C3 warm/direct toggle (appended, cache-safe)."""
    persona = coach_prompts.SYSTEM_PROMPT
    system: list[dict[str, Any]] = [{"text": persona}]
    if tone == "direct":
        system.append({"text": "Write in a warm but direct register — fewer words, still kind, never clinical."})

    numbers = ", ".join(f"{k}={v}" for k, v in theme.data.items())
    context = f"Background for you (not shown to the user):\n"
    if memory_text:
        context += f"\nWhat you know about them:\n{memory_text}\n"
    if goals_text:
        context += f"\nTheir goals:\n{goals_text}\n"
    context += (
        f"\nToday's situation: {_THEME_BRIEF.get(theme.theme_type, 'Encourage them warmly.')}\n"
        f"The only activity numbers you may use (never invent any others): {numbers}\n"
    )
    system.append({"text": context})

    instruction = (
        "Write today's short note to this person as Steady. Two to four warm, plain "
        "sentences. Mention their activity using only the numbers given. End with one "
        "open, friendly question. Do not give medical advice or use any numbers not listed above."
    )
    messages = [{"role": "user", "content": [{"text": instruction}]}]
    return system, messages


def copywrite(llm: Any, theme: CoachTheme, *, memory_text: str = "", goals_text: str = "", tone: str | None = None) -> str:
    """Call the model; raises CoachLLMError on failure (handler falls back)."""
    system, messages = build_prompt(theme, memory_text=memory_text, goals_text=goals_text, tone=tone)
    return llm.chat(system=system, messages=messages, max_tokens=300, temperature=0.7).strip()

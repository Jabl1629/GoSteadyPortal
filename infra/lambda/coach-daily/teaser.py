"""
SMS teaser body + opt-in gate — AI Coach C2 §5.6/§5.7. Best-effort: the inbox
note is the source of truth, so the teaser never fails the run. Opt-in defaults
OFF (Q2a) — the teaser only sends when the user explicitly enabled coach SMS.
"""
from __future__ import annotations

from typing import Any


def teaser_body(app_base_url: str) -> str:
    base = (app_base_url or "https://app.gosteady.co").rstrip("/")
    return (
        "Your GoSteady coach noticed something good today \U0001F45F "
        f"See your note: {base}/coach  Reply STOP to opt out."
    )


def opted_in(user_row: dict[str, Any] | None) -> bool:
    """True only if Users.prefs.coach.coachSmsTeaser == True (default OFF)."""
    if not user_row:
        return False
    prefs = user_row.get("prefs") or {}
    coach = prefs.get("coach") or {} if isinstance(prefs, dict) else {}
    return coach.get("coachSmsTeaser") is True

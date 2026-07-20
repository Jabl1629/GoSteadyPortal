"""
Context assembly — AI Coach C1 §5.3 / D3. Deterministic; the model sees only
what we hand it (no agentic tools). The static persona stays a stable,
prompt-cacheable system block; memory + the activity digest go in a second,
dynamic system block; conversation turns follow as Converse messages.
"""
from __future__ import annotations

import os
from typing import Any

from _shared import coach_prompts

# Prompt caching (5-min TTL) on the static persona block. Default OFF until
# validated against a Bedrock-accessible model: the coach fail-closes to a
# scripted line on ANY Converse error, so an unverified cachePoint would
# silently degrade every chat. Flip COACH_PROMPT_CACHE=true to A/B it once
# Anthropic model access is live (dev test 2026-07-19).
USE_CACHE_POINT = os.environ.get("COACH_PROMPT_CACHE", "false").lower() == "true"


def build_system(
    memory_text: str, digest_text: str, *, tone: str | None = None
) -> list[dict[str, Any]]:
    """Converse system blocks: static persona (+ cache point) then dynamic
    context. `tone` is reserved for C3's warm/direct toggle; C1 ships one
    warm voice, so it is accepted and ignored here."""
    blocks: list[dict[str, Any]] = [{"text": coach_prompts.SYSTEM_PROMPT}]
    if USE_CACHE_POINT:
        blocks.append({"cachePoint": {"type": "default"}})
    context = "Background for you (not shown to the user):\n"
    if memory_text:
        context += f"\nWhat you know about them:\n{memory_text}\n"
    context += (
        "\nTheir recent activity — use ONLY these numbers, and never invent any:\n"
        f"{digest_text}\n"
    )
    blocks.append({"text": context})
    return blocks


def build_messages(
    turns: list[dict[str, Any]], user_message: str
) -> list[dict[str, Any]]:
    """Alternating user/assistant Converse messages: last-N turns + the new
    message. Coalesces consecutive same-role turns and drops a leading
    assistant (Converse requires strict alternation starting with user)."""
    raw: list[dict[str, Any]] = []
    for t in turns:
        text = t.get("text", "")
        if not text:
            continue
        role = "assistant" if t.get("role") == "coach" else "user"
        raw.append({"role": role, "content": [{"text": text}]})
    raw.append({"role": "user", "content": [{"text": user_message}]})
    return _coalesce(raw)


def _coalesce(msgs: list[dict[str, Any]]) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    for m in msgs:
        if out and out[-1]["role"] == m["role"]:
            out[-1]["content"].extend(m["content"])
        else:
            out.append({"role": m["role"], "content": list(m["content"])})
    while out and out[0]["role"] == "assistant":
        out.pop(0)
    return out

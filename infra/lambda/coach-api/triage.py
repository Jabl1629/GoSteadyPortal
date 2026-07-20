"""
Input triage — AI Coach C1 §6.2. Classify a user message BEFORE any Opus
call; high-risk classes get a scripted, non-generative reply.

Defense in depth: a deterministic keyword/pattern screen runs FIRST and is
authoritative for the highest-risk classes (self-harm, emergency, abuse) —
we never rely solely on the LLM to catch a crisis. A Haiku classifier then
handles nuance for anything the screen marks 'ok'. Fail-safe: on classifier
error the deterministic result stands.
"""
from __future__ import annotations

from dataclasses import dataclass

from _shared import coach_prompts

# Deterministic high-risk phrases (substring match on a space-padded,
# lowercased message). Includes the oblique elderly self-harm idioms called
# out in the umbrella red-team set ("tired of being a burden").
_SELF_HARM: tuple[str, ...] = (
    "kill myself", "end my life", "end it all", "want to die", "wanna die",
    "don't want to live", "dont want to live", "not want to live",
    "don't want to be here", "dont want to be here", "better off dead",
    "suicide", "suicidal", "harm myself", "hurt myself", "take my own life",
    "tired of being a burden", "burden to everyone", "burden to my family",
    "burden on my family", "no reason to go on", "can't go on", "cant go on",
    "nothing to live for",
)
_EMERGENCY: tuple[str, ...] = (
    "i've fallen", "ive fallen", "i have fallen", "i fell and", "i just fell",
    "can't get up", "cant get up", "can't breathe", "cant breathe",
    "chest pain", "call 911", "i'm bleeding", "im bleeding",
    "having a heart attack", "having a stroke", "i think i'm having a stroke",
    "i'm badly hurt", "im badly hurt", "help me now", "i'm choking", "im choking",
)
_ABUSE: tuple[str, ...] = (
    "being abused", "hits me", "hurts me on purpose", "won't feed me",
    "wont feed me", "afraid of my caregiver", "scared of my caregiver",
    "neglecting me", "locked me in", "threatens me",
)
_MEDICAL: tuple[str, ...] = (
    "my medication", "my meds", "should i take", "is this normal",
    "my doctor said", "my blood pressure", "diagnos", "symptom",
    "prescription", "dosage", "feel dizzy", "dizziness", "swollen",
    "my knee hurts", "my hip hurts", "chest hurts", "short of breath",
)


@dataclass(frozen=True)
class TriageResult:
    cls: str
    scripted: str | None  # non-None ⇒ return verbatim, skip the model


def _screen(message: str) -> str:
    low = " " + (message or "").lower() + " "
    if any(p in low for p in _SELF_HARM):
        return "self-harm"
    if any(p in low for p in _EMERGENCY):
        return "emergency"
    if any(p in low for p in _ABUSE):
        return "abuse-neglect"
    if any(p in low for p in _MEDICAL):
        return "medical"
    return "ok"


def triage(message: str, *, llm: object | None = None) -> TriageResult:
    """Classify `message`. `llm` (optional) is a CoachLLM used only to refine
    a deterministic 'ok'; its failure never changes the safe result."""
    cls = _screen(message)
    if cls == "ok" and llm is not None:
        try:
            label = llm.classify(message)  # type: ignore[attr-defined]
        except Exception:  # noqa: BLE001 — safety path must never crash the turn
            label = "ok"
        if label in ("medical", "emergency", "self-harm", "abuse-neglect", "off-scope"):
            cls = label
    return TriageResult(cls=cls, scripted=coach_prompts.SCRIPTED_BY_CLASS.get(cls))

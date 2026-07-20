"""
Coach output lint — AI Coach C1 §6.4. Deterministic post-LLM checks.

Runs on every *generated* coach reply before it is shown or persisted.
Scripted responses in coach_prompts bypass this — they are pre-vetted.
Pure functions, unit-tested; no model calls, no I/O.

On any hard failure the caller regenerates once, then falls back to a
scripted line. Checks:
  - length:   <= MAX_SENTENCES sentences and <= MAX_CHARS chars
  - banned:   no disease / diagnosis / treatment language (FDA general-
              wellness claim discipline, C1 L11)
  - identity: never claims to be human / a person / a professional
  - numerals: every digit-run must be in the allow-list built from the
              deterministic activity digest (anti-hallucination, C1-D4) —
              the model may not invent statistics
  - contact:  no URLs or phone numbers (our crisis lines only appear in
              scripted replies, which skip this lint)
"""
from __future__ import annotations

import re
from dataclasses import dataclass

MAX_SENTENCES = 4
MAX_CHARS = 600

# Disease / diagnosis / treatment language, matched case-insensitively as
# substrings. Deliberately broad — a false positive merely triggers one
# regenerate. "supports strength / balance / staying active" uses none of
# these. Word fragments (e.g. "diagnos") catch inflections.
_BANNED_CLAIM_TERMS: tuple[str, ...] = (
    "diagnos", "cure", " treat", "treats", "treatment", "prevent",
    "reduce the risk", "reduces the risk", "reduces your risk", "lower the risk",
    "lowers the risk", "arthritis", "osteoporosis", "dementia", "alzheimer",
    "parkinson", "diabetes", "blood pressure", "hypertension", "stroke",
    "heart disease", "heart attack", "depression", "anxiety", "prescri",
    "medication", "medicine", "disease", "illness", "symptom",
    "fall risk", "prevent falls", "reduce falls",
)

# Phrases that would breach the "never claim to be human" integrity rule.
_HUMAN_CLAIM_PATTERNS: tuple[str, ...] = (
    r"\bi ?a?'?m (a )?(real )?(human|person|man|woman|nurse|doctor|therapist)\b",
    r"\bas a (nurse|doctor|human|person|friend and)\b",
    r"\bi ?a?'?m not an ai\b",
    r"\bi am real\b",
    r"\bi'?m a real\b",
)

_URL_RE = re.compile(r"https?://|www\.|\b[\w-]+\.(?:com|org|net|io|co|gov|edu)\b", re.I)
# 7+ digit phone-shaped runs; won't match small activity counts or years.
_PHONE_RE = re.compile(r"(?:\+?1[-.\s]?)?\(?\d{3}\)?[-.\s]?\d{3}[-.\s]?\d{4}")
_DIGIT_RUN_RE = re.compile(r"\d+")
_SENTENCE_SPLIT_RE = re.compile(r"[.!?]+(?:\s|$)")


@dataclass(frozen=True)
class LintResult:
    ok: bool
    reasons: tuple[str, ...] = ()


def lint_reply(
    text: str,
    *,
    allowlist: frozenset[str] | set[str] = frozenset(),
) -> LintResult:
    """Return LintResult(ok, reasons). `allowlist` is the set of numeral
    strings the digest computed; any other digit-run in the reply fails."""
    reasons: list[str] = []
    stripped = (text or "").strip()
    if not stripped:
        return LintResult(ok=False, reasons=("empty",))

    if len(stripped) > MAX_CHARS:
        reasons.append("too_long_chars")
    sentences = [s for s in _SENTENCE_SPLIT_RE.split(stripped) if s.strip()]
    if len(sentences) > MAX_SENTENCES:
        reasons.append("too_many_sentences")

    low = stripped.lower()
    for term in _BANNED_CLAIM_TERMS:
        if term in low:
            reasons.append(f"banned_claim:{term.strip()}")
            break
    for pat in _HUMAN_CLAIM_PATTERNS:
        if re.search(pat, low):
            reasons.append("identity_violation")
            break

    allow = {str(a) for a in allowlist}
    for run in _DIGIT_RUN_RE.findall(stripped):
        if run not in allow:
            reasons.append(f"ungrounded_number:{run}")
            break

    if _URL_RE.search(stripped):
        reasons.append("contains_url")
    if _PHONE_RE.search(stripped):
        reasons.append("contains_phone")

    return LintResult(ok=not reasons, reasons=tuple(reasons))

"""
Post-turn memory extraction — AI Coach C3 §5.3. Best-effort Haiku pass that
refreshes the rolling SUMMARY and proposes new PROFILE#/GOAL# items
(source='extracted'). NEVER clobbers a source='user' item (C3-D4/L2): new
items get fresh ids and near-duplicates of existing text are skipped.

Runs only every EXTRACT_EVERY_N turns to bound cost + latency; fully wrapped so
a failure never affects the chat turn. Bedrock-blocked ⇒ simply writes nothing.
"""
from __future__ import annotations

import json
import re
import uuid
from datetime import datetime, timezone
from typing import Any

EXTRACT_EVERY_N = 4  # extract on every 4th user turn

_EXTRACT_SYSTEM = (
    "You maintain a small memory profile for an AI activity coach's older-adult user. "
    "Read the recent conversation and reply with STRICT JSON only (no prose, no code fences), "
    "with exactly these keys:\n"
    '  "summary": a warm running summary of who they are and what they are working toward '
    "(<= 280 characters), or an empty string if there is nothing to say;\n"
    '  "facts": an array of at most 3 short new profile facts worth remembering '
    '(e.g. "walks with her daughter on Tuesdays");\n'
    '  "goals": an array of at most 2 activity goals the user has clearly stated '
    '(e.g. "walk to the mailbox and back every day").\n'
    "Only include items clearly grounded in the conversation. Use empty arrays if nothing is new. "
    "Never include medical, diagnostic, or sensitive-health content."
)


def _now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _norm(t: Any) -> str:
    return re.sub(r"\s+", " ", str(t or "").strip().lower())


def _parse_json(raw: str) -> dict[str, Any] | None:
    s = (raw or "").strip()
    start, end = s.find("{"), s.rfind("}")
    if start < 0 or end <= start:
        return None
    try:
        obj = json.loads(s[start : end + 1])
        return obj if isinstance(obj, dict) else None
    except (ValueError, TypeError):
        return None


def extract_and_store(llm: Any, memory_table: Any, patient_id: str, turns: list[dict[str, Any]], existing: Any) -> int:
    """Returns the number of memory items written (0 on any failure/no-op)."""
    convo = "\n".join(f"{t.get('role')}: {t.get('text')}" for t in turns if t.get("text"))[-4000:]
    if not convo.strip():
        return 0
    try:
        raw = llm.chat(
            system=[{"text": _EXTRACT_SYSTEM}],
            messages=[{"role": "user", "content": [{"text": convo}]}],
            max_tokens=400,
            temperature=0.0,
        )
    except Exception:  # noqa: BLE001 — extraction never affects the chat turn
        return 0
    data = _parse_json(raw)
    if data is None:
        return 0

    written = 0
    summary = str(data.get("summary") or "").strip()
    if summary:
        try:
            memory_table.put_item(Item={
                "patientId": patient_id, "itemId": "SUMMARY",
                "text": summary[:280], "source": "extracted", "updatedAt": _now(),
            })
            written += 1
        except Exception:  # noqa: BLE001
            pass

    seen = {_norm(f.get("text")) for f in existing.facts} | {_norm(g.get("text")) for g in existing.goals}
    for prefix, items in (("PROFILE#", data.get("facts") or []), ("GOAL#", data.get("goals") or [])):
        if not isinstance(items, list):
            continue
        for text in items[:3]:
            text = str(text or "").strip()
            if not text or _norm(text) in seen:
                continue
            now = _now()
            try:
                memory_table.put_item(Item={
                    "patientId": patient_id, "itemId": f"{prefix}{uuid.uuid4().hex[:12]}",
                    "text": text[:300], "source": "extracted", "createdAt": now, "updatedAt": now,
                })
                seen.add(_norm(text))
                written += 1
            except Exception:  # noqa: BLE001
                pass
    return written

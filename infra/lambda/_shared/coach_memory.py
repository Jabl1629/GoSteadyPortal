"""
Shared CoachMemory reader — AI Coach. Used by coach-daily (copywrite context)
and coach-api C3 extraction. CoachMemory: PK patientId, SK itemId —
'PROFILE#<id>' facts, 'GOAL#<id>' goals (C3), 'SUMMARY' singleton.
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from boto3.dynamodb.conditions import Key


@dataclass(frozen=True)
class CoachMemoryView:
    summary: str = ""
    facts: tuple[dict[str, Any], ...] = ()
    goals: tuple[dict[str, Any], ...] = ()

    def profile_text(self) -> str:
        parts: list[str] = []
        if self.summary:
            parts.append(self.summary)
        for f in self.facts:
            t = f.get("text")
            if t:
                parts.append(f"- {t}")
        return "\n".join(parts)

    def goals_text(self) -> str:
        return "\n".join(f"- {g.get('text')}" for g in self.goals if g.get("text"))


def load(memory_table: Any, patient_id: str) -> CoachMemoryView:
    res = memory_table.query(KeyConditionExpression=Key("patientId").eq(patient_id))
    summary = ""
    facts: list[dict[str, Any]] = []
    goals: list[dict[str, Any]] = []
    for it in res.get("Items", []):
        sk = str(it.get("itemId", ""))
        if sk == "SUMMARY":
            summary = it.get("text", "") or ""
        elif sk.startswith("GOAL#"):
            goals.append(it)
        elif sk.startswith("PROFILE#"):
            facts.append(it)
    facts.sort(key=lambda f: f.get("createdAt", ""))
    goals.sort(key=lambda g: g.get("createdAt", ""))
    return CoachMemoryView(summary=summary, facts=tuple(facts), goals=tuple(goals))

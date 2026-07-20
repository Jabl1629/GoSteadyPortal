"""
Coach memory + transcript persistence — AI Coach C1 §5.1 / §5.2 / D4.

CoachMemory : PK patientId, SK itemId — 'PROFILE#<id>' facts (+ 'GOAL#<id>'
              reserved for C3) and a 'SUMMARY' singleton. No TTL (L9).
CoachMessages: PK patientId, SK 'TURN#<ts>#<msgId>' chat turns
              ('INBOX#<date>' reserved for C2). CMK + 12-mo TTL (L9).

User-edited facts are authoritative (source='user'); C3's extraction must not
clobber them. C1 does not auto-write the SUMMARY — memory is transcript +
user-CRUD facts + last-N-turn context (C1-D7); richer extraction is C3.
"""
from __future__ import annotations

import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Any

from boto3.dynamodb.conditions import Key

TRANSCRIPT_TTL_DAYS = 365  # ~12 months (C1 L9)


def _now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


@dataclass(frozen=True)
class Memory:
    facts: tuple[dict[str, Any], ...] = ()
    summary: str = ""

    def as_text(self) -> str:
        parts: list[str] = []
        if self.summary:
            parts.append(self.summary)
        for f in self.facts:
            t = f.get("text")
            if t:
                parts.append(f"- {t}")
        return "\n".join(parts)


def load_memory(memory_table: Any, patient_id: str) -> Memory:
    res = memory_table.query(KeyConditionExpression=Key("patientId").eq(patient_id))
    facts: list[dict[str, Any]] = []
    summary = ""
    for item in res.get("Items", []):
        sk = str(item.get("itemId", ""))
        if sk == "SUMMARY":
            summary = item.get("text", "") or ""
        elif sk.startswith(("PROFILE#", "GOAL#")):
            facts.append(item)
    facts.sort(key=lambda f: f.get("createdAt", ""))
    return Memory(facts=tuple(facts), summary=summary)


def recent_turns(
    messages_table: Any, patient_id: str, *, limit: int = 12
) -> list[dict[str, Any]]:
    """Last `limit` chat turns, chronological (oldest→newest)."""
    res = messages_table.query(
        KeyConditionExpression=Key("patientId").eq(patient_id)
        & Key("sk").begins_with("TURN#"),
        ScanIndexForward=False,
        Limit=limit,
    )
    items = res.get("Items", [])
    items.reverse()
    return items


def thread(
    messages_table: Any, patient_id: str, *, limit: int = 50
) -> list[dict[str, Any]]:
    res = messages_table.query(
        KeyConditionExpression=Key("patientId").eq(patient_id)
        & Key("sk").begins_with("TURN#"),
        ScanIndexForward=False,
        Limit=limit,
    )
    items = res.get("Items", [])
    items.reverse()
    return items


def persist_turn(
    messages_table: Any,
    *,
    patient_id: str,
    role: str,
    text: str,
    flags: list[str] | None = None,
    model_id: str = "",
    prompt_version: str = "",
) -> dict[str, Any]:
    ts = _now_iso()
    msg_id = uuid.uuid4().hex[:12]
    expires = int(
        (datetime.now(timezone.utc) + timedelta(days=TRANSCRIPT_TTL_DAYS)).timestamp()
    )
    item: dict[str, Any] = {
        "patientId": patient_id,
        "sk": f"TURN#{ts}#{msg_id}",
        "role": role,
        "kind": "chat",
        "text": text,
        "flags": list(flags or []),
        "createdAt": ts,
        "expiresAt": expires,
    }
    if role == "coach":
        item["modelId"] = model_id
        item["promptVersion"] = prompt_version
    messages_table.put_item(Item=item)
    return item


def create_fact(
    memory_table: Any, patient_id: str, text: str, *, kind: str = "profile"
) -> dict[str, Any]:
    now = _now_iso()
    prefix = "GOAL#" if kind == "goal" else "PROFILE#"  # C3: goals
    item_id = f"{prefix}{uuid.uuid4().hex[:12]}"
    item = {
        "patientId": patient_id,
        "itemId": item_id,
        "text": text,
        "source": "user",
        "createdAt": now,
        "updatedAt": now,
    }
    memory_table.put_item(Item=item)
    return item

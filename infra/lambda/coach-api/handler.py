"""
coach-api Lambda — AI Coach C1 text chat + memory (ai-coach-c1-text-chat.md).

Routes (all bound to the D2C pool authorizer):
  POST   /api/v1/d2c/coach/chat             one chat turn
  GET    /api/v1/d2c/coach/thread           transcript
  GET    /api/v1/d2c/coach/memory           {facts, summary}
  POST   /api/v1/d2c/coach/memory           add a profile fact
  PATCH  /api/v1/d2c/coach/memory/{factId}  edit a profile fact
  DELETE /api/v1/d2c/coach/memory/{factId}  delete a profile fact

Chat pipeline: resolve the caller's own walker Patient (DDB-authoritative)
→ kill switch → triage (scripted reply for high-risk, no model call) →
assemble context (persona + memory + deterministic digest + last-N turns) →
Bedrock (Opus 4.8) → output lint (regenerate once, else scripted fallback) →
persist + audit. Mirrors care-circle/handler.py. PII-free logs (T17): IDs and
counts only — never prompt or reply text.
"""
from __future__ import annotations

import json
import os
from datetime import datetime, timezone
from typing import Any

import boto3
from botocore.exceptions import ClientError
from boto3.dynamodb.conditions import Key

from _shared.api_authz import extract_claims, require_authenticated
from _shared.api_error import ApiError, error_response, ok_response
from _shared.observability import emit_audit, get_logger
from _shared import coach_memory, coach_prompts
from _shared.coach_guardrails import lint_reply
from _shared.coach_llm import CoachLLM, CoachLLMError

import assembly
import digest
import extract
import memory as memory_store
from triage import triage

logger = get_logger()

# ── env + clients ──────────────────────────────────────────────────────

COACH_MESSAGES_TABLE = os.environ["COACH_MESSAGES_TABLE"]
COACH_MEMORY_TABLE = os.environ["COACH_MEMORY_TABLE"]
ACTIVITY_TABLE = os.environ["ACTIVITY_TABLE"]
PATIENTS_TABLE = os.environ["PATIENTS_TABLE"]
USERS_TABLE = os.environ.get("USERS_TABLE")  # C3: coach prefs (tone) live on Users.prefs.coach
COACH_MODEL_ID = os.environ.get("COACH_MODEL_ID", "us.anthropic.claude-opus-4-8")
COACH_ENABLED = os.environ.get("COACH_ENABLED", "true").lower() == "true"
COACH_ALLOWLIST = {
    p.strip() for p in os.environ.get("COACH_ALLOWLIST", "").split(",") if p.strip()
}
RECENT_TURNS = int(os.environ.get("COACH_RECENT_TURNS", "12"))
MAX_MESSAGE_CHARS = 2000

_ddb = boto3.resource("dynamodb")
_messages = _ddb.Table(COACH_MESSAGES_TABLE)
_memory = _ddb.Table(COACH_MEMORY_TABLE)
_activity = _ddb.Table(ACTIVITY_TABLE)
_patients = _ddb.Table(PATIENTS_TABLE)
_users = _ddb.Table(USERS_TABLE) if USERS_TABLE else None

_llm = CoachLLM(model_id=COACH_MODEL_ID)

# Audit event names — local literals (care-circle D13 convention).
AUDIT_CHAT_TURN = "coach.chat.turn"
AUDIT_TRIAGE_FLAGGED = "coach.triage.flagged"
AUDIT_MEMORY_UPDATED = "coach.memory.updated"
AUDIT_PREFS_UPDATED = "coach.prefs.updated"
AUDIT_KILLSWITCH = "coach.killswitch.blocked"

_HIGH_RISK = {"self-harm", "emergency", "abuse-neglect", "medical"}


# ── router ─────────────────────────────────────────────────────────────

def handler(event: dict[str, Any], context: Any) -> dict[str, Any]:  # noqa: ARG001
    claims = extract_claims(event)
    try:
        require_authenticated(claims)
        route = event.get("routeKey", "")
        params = event.get("pathParameters") or {}
        if route == "POST /api/v1/d2c/coach/chat":
            return _chat_turn(event, claims)
        if route == "GET /api/v1/d2c/coach/thread":
            return _get_thread(event, claims)
        if route == "GET /api/v1/d2c/coach/inbox":
            return _get_inbox(event, claims)
        if route == "GET /api/v1/d2c/coach/memory":
            return _get_memory(event, claims)
        if route == "POST /api/v1/d2c/coach/memory":
            return _create_fact(event, claims)
        if route == "PATCH /api/v1/d2c/coach/memory/{factId}":
            return _edit_fact(event, claims, params.get("factId", ""))
        if route == "DELETE /api/v1/d2c/coach/memory/{factId}":
            return _delete_fact(event, claims, params.get("factId", ""))
        if route == "GET /api/v1/d2c/coach/prefs":
            return _get_prefs(event, claims)
        if route == "PATCH /api/v1/d2c/coach/prefs":
            return _patch_prefs(event, claims)
        raise ApiError(code="NOT_FOUND", message=f"Unknown route {route}", status=404)
    except ApiError as e:
        logger.warning("coach_error", extra={"code": e.code, "status": e.status})
        return error_response(e.code, e.message, e.status, e.details)


# ── walker-patient resolution (DDB-authoritative, L12) ────────────────

def _resolve_patient(claims: dict[str, Any]) -> dict[str, Any]:
    """The caller's OWN walker Patient record. C1 = the walker is the account
    holder (Q2b household deferred). Prefer Patients.cognitoUserId == userId
    (set exactly when the owner is the walker); fall back to the sole active
    patient in a single-walker household."""
    client_id = claims.get("clientId", "")
    user_id = claims.get("userId", "")
    actives = _active_patients(client_id)
    for p in actives:
        if p.get("cognitoUserId") == user_id:
            return p
    if len(actives) == 1:
        return actives[0]
    raise ApiError(
        code="COACH_NO_WALKER",
        message="Steady is available to the walker on the account.",
        status=404,
    )


def _active_patients(client_id: str) -> list[dict[str, Any]]:
    if not client_id:
        return []
    res = _patients.query(
        IndexName="by-client-status",
        KeyConditionExpression="clientId = :c AND begins_with(status_patientId, :ap)",
        ExpressionAttributeValues={":c": client_id, ":ap": "active_"},
    )
    return res.get("Items", [])


def _ensure_enabled(
    patient: dict[str, Any], claims: dict[str, Any], event: dict[str, Any]
) -> None:
    """Kill switch: global flag + per-patient coachEnabled + trial allow-list.
    Gates chat only; reads/memory-CRUD stay available so the user always
    controls their data."""
    patient_id = patient.get("patientId")
    blocked = (
        not COACH_ENABLED
        or patient.get("coachEnabled") is False
        or (COACH_ALLOWLIST and patient_id not in COACH_ALLOWLIST)
    )
    if blocked:
        emit_audit(
            AUDIT_KILLSWITCH,
            actor=_actor(claims),
            subject={"patientId": patient_id, "clientId": claims.get("clientId")},
            action="event",
            request_id=_request_id(event),
        )
        raise ApiError(
            code="COACH_DISABLED", message="Coach is currently unavailable.", status=403
        )


# ── chat turn ──────────────────────────────────────────────────────────

def _chat_turn(event: dict[str, Any], claims: dict[str, Any]) -> dict[str, Any]:
    body = _parse_body(event)
    message = (body.get("message") or "").strip()
    if not message:
        raise ApiError(code="INVALID_REQUEST", message="message is required", status=400)
    if len(message) > MAX_MESSAGE_CHARS:
        raise ApiError(code="INVALID_REQUEST", message="message is too long", status=400)

    patient = _resolve_patient(claims)
    _ensure_enabled(patient, claims, event)
    patient_id = patient["patientId"]
    client_id = claims.get("clientId")

    result = triage(message, llm=_llm)
    memory_store.persist_turn(
        _messages,
        patient_id=patient_id,
        role="user",
        text=message,
        flags=[result.cls] if result.cls != "ok" else None,
    )

    # High-risk / redirect → scripted, non-generative reply (no model call).
    if result.scripted is not None:
        memory_store.persist_turn(
            _messages,
            patient_id=patient_id,
            role="coach",
            text=result.scripted,
            flags=[result.cls],
            prompt_version=coach_prompts.PROMPT_VERSION,
        )
        if result.cls in _HIGH_RISK:
            emit_audit(
                AUDIT_TRIAGE_FLAGGED,
                actor=_actor(claims),
                subject={"patientId": patient_id, "clientId": client_id},
                action="event",
                extra={"class": result.cls},
                request_id=_request_id(event),
            )
        emit_audit(
            AUDIT_CHAT_TURN,
            actor=_actor(claims),
            subject={"patientId": patient_id, "clientId": client_id},
            action="create",
            extra={"flagged": True, "class": result.cls, "scripted": True},
            request_id=_request_id(event),
        )
        return ok_response({"reply": result.scripted, "flagged": True})

    # 'ok' → generated, grounded reply.
    mem = coach_memory.load(_memory, patient_id)          # C3: profile + goals
    memory_text = mem.profile_text()
    if mem.goals_text():
        memory_text += f"\nTheir goals:\n{mem.goals_text()}"
    tz = patient.get("timezone") or "UTC"
    today_rows = digest.query_today(_activity, patient_id=patient_id, tz_name=tz)
    hist_rows = digest.query_history(_activity, patient_id=patient_id, tz_name=tz)
    dig = digest.build_digest(today_rows, hist_rows, tz_name=tz)
    turns = memory_store.recent_turns(_messages, patient_id, limit=RECENT_TURNS)

    system = assembly.build_system(memory_text, dig.text, tone=_coach_tone(claims))
    messages = assembly.build_messages(turns, message)
    reply = _generate(system, messages, dig.allowlist)

    memory_store.persist_turn(
        _messages,
        patient_id=patient_id,
        role="coach",
        text=reply,
        model_id=COACH_MODEL_ID,
        prompt_version=coach_prompts.PROMPT_VERSION,
    )
    _maybe_extract(patient_id, claims, event, turns_before=len(turns))
    emit_audit(
        AUDIT_CHAT_TURN,
        actor=_actor(claims),
        subject={"patientId": patient_id, "clientId": client_id},
        action="create",
        extra={"flagged": False, "turnCount": len(turns) + 1},
        request_id=_request_id(event),
    )
    return ok_response({"reply": reply, "flagged": False})


def _generate(
    system: list[dict[str, Any]],
    messages: list[dict[str, Any]],
    allowlist: frozenset[str],
) -> str:
    """Call the model, lint, regenerate once, else a scripted fallback."""
    for attempt in range(2):
        try:
            reply = _llm.chat(system=system, messages=messages).strip()
        except CoachLLMError:
            return coach_prompts.SCRIPTED_LLM_ERROR
        result = lint_reply(reply, allowlist=allowlist)
        if result.ok:
            return reply
        logger.warning(
            "coach_lint_failed",
            extra={"attempt": attempt, "reasons": list(result.reasons)},
        )
    return coach_prompts.SCRIPTED_LINT_FALLBACK


# ── thread + memory routes ─────────────────────────────────────────────

def _get_thread(event: dict[str, Any], claims: dict[str, Any]) -> dict[str, Any]:
    patient = _resolve_patient(claims)
    items = memory_store.thread(_messages, patient["patientId"])
    return ok_response({"messages": [_msg_view(m) for m in items]})


def _get_inbox(event: dict[str, Any], claims: dict[str, Any]) -> dict[str, Any]:
    """The latest proactive note written by coach-daily (C2). None when none yet."""
    patient = _resolve_patient(claims)
    res = _messages.query(
        KeyConditionExpression=Key("patientId").eq(patient["patientId"])
        & Key("sk").begins_with("INBOX#"),
        ScanIndexForward=False, Limit=1,
    )
    items = res.get("Items", [])
    if not items:
        return ok_response({"note": None})
    m = items[0]
    return ok_response({"note": {
        "id": m.get("sk"),
        "date": str(m.get("sk", "")).split("#", 1)[-1],
        "text": m.get("text"),
        "themeType": m.get("themeType"),
        "createdAt": m.get("createdAt"),
    }})


def _get_memory(event: dict[str, Any], claims: dict[str, Any]) -> dict[str, Any]:
    patient = _resolve_patient(claims)
    mem = memory_store.load_memory(_memory, patient["patientId"])
    return ok_response(
        {"facts": [_fact_view(f) for f in mem.facts], "summary": mem.summary}
    )


def _create_fact(event: dict[str, Any], claims: dict[str, Any]) -> dict[str, Any]:
    patient = _resolve_patient(claims)
    body = _parse_body(event)
    text = (body.get("text") or "").strip()
    if not text:
        raise ApiError(code="INVALID_REQUEST", message="text is required", status=400)
    if len(text) > 500:
        raise ApiError(code="INVALID_REQUEST", message="text is too long", status=400)
    kind = "goal" if str(body.get("kind", "")).lower() == "goal" else "profile"  # C3 goals
    item = memory_store.create_fact(_memory, patient["patientId"], text, kind=kind)
    emit_audit(
        AUDIT_MEMORY_UPDATED,
        actor=_actor(claims),
        subject={
            "patientId": patient["patientId"],
            "clientId": claims.get("clientId"),
            "itemId": item["itemId"],
        },
        action="create",
        request_id=_request_id(event),
    )
    return ok_response({"fact": _fact_view(item)}, status=201)


def _edit_fact(
    event: dict[str, Any], claims: dict[str, Any], fact_id: str
) -> dict[str, Any]:
    if not fact_id:
        raise ApiError(code="INVALID_REQUEST", message="factId is required", status=400)
    patient = _resolve_patient(claims)
    body = _parse_body(event)
    text = (body.get("text") or "").strip()
    if not text:
        raise ApiError(code="INVALID_REQUEST", message="text is required", status=400)
    item_id = _normalize_item_id(fact_id)
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    _memory.update_item(
        Key={"patientId": patient["patientId"], "itemId": item_id},
        UpdateExpression=(
            "SET #t = :t, #s = :src, updatedAt = :u, "
            "createdAt = if_not_exists(createdAt, :u)"
        ),
        ExpressionAttributeNames={"#t": "text", "#s": "source"},
        ExpressionAttributeValues={":t": text, ":src": "user", ":u": now},
    )
    emit_audit(
        AUDIT_MEMORY_UPDATED,
        actor=_actor(claims),
        subject={
            "patientId": patient["patientId"],
            "clientId": claims.get("clientId"),
            "itemId": item_id,
        },
        action="update",
        request_id=_request_id(event),
    )
    return ok_response({"fact": {"factId": item_id, "text": text, "source": "user"}})


def _delete_fact(
    event: dict[str, Any], claims: dict[str, Any], fact_id: str
) -> dict[str, Any]:
    if not fact_id:
        raise ApiError(code="INVALID_REQUEST", message="factId is required", status=400)
    patient = _resolve_patient(claims)
    item_id = _normalize_item_id(fact_id)
    _memory.delete_item(Key={"patientId": patient["patientId"], "itemId": item_id})
    emit_audit(
        AUDIT_MEMORY_UPDATED,
        actor=_actor(claims),
        subject={
            "patientId": patient["patientId"],
            "clientId": claims.get("clientId"),
            "itemId": item_id,
        },
        action="delete",
        request_id=_request_id(event),
    )
    return ok_response({"factId": item_id, "deleted": True})


# ── prefs + extraction (C3) ────────────────────────────────────────────

def _read_coach_prefs(uid: str) -> dict[str, Any]:
    if _users is None or not uid:
        return {}
    try:
        row = _users.get_item(Key={"userId": uid}).get("Item") or {}
    except ClientError:
        return {}
    prefs = row.get("prefs") or {}
    return (prefs.get("coach") or {}) if isinstance(prefs, dict) else {}


def _coach_tone(claims: dict[str, Any]) -> str | None:
    """C3 warm/direct toggle from Users.prefs.coach.tone (default warm ⇒ None)."""
    tone = _read_coach_prefs(claims.get("userId", "")).get("tone")
    return tone if tone in ("warm", "direct") else None


def _maybe_extract(
    patient_id: str, claims: dict[str, Any], event: dict[str, Any], *, turns_before: int
) -> None:
    """C3 §5.3: best-effort post-turn extraction every Nth turn. Never affects
    the turn; Bedrock-blocked ⇒ silently writes nothing."""
    if (turns_before + 1) % extract.EXTRACT_EVERY_N != 0:
        return
    try:
        turns = memory_store.recent_turns(_messages, patient_id, limit=RECENT_TURNS)
        existing = coach_memory.load(_memory, patient_id)
        n = extract.extract_and_store(
            _llm, _memory, patient_id,
            [{"role": t.get("role"), "text": t.get("text")} for t in turns],
            existing,
        )
        if n:
            emit_audit(
                AUDIT_MEMORY_UPDATED, actor=_actor(claims),
                subject={"patientId": patient_id, "clientId": claims.get("clientId")},
                action="update", extra={"extracted": n}, request_id=_request_id(event),
            )
    except Exception:  # noqa: BLE001 — extraction never affects the chat turn
        logger.warning("coach_extract_failed")


def _get_prefs(event: dict[str, Any], claims: dict[str, Any]) -> dict[str, Any]:
    _resolve_patient(claims)  # authz: caller must be a coach-eligible walker
    coach = _read_coach_prefs(claims.get("userId", ""))
    return ok_response({
        "tone": coach.get("tone", "warm"),
        "coachSmsTeaser": bool(coach.get("coachSmsTeaser", False)),
    })


def _patch_prefs(event: dict[str, Any], claims: dict[str, Any]) -> dict[str, Any]:
    if _users is None:
        raise ApiError(code="COACH_PREFS_UNAVAILABLE", message="Preferences are unavailable.", status=503)
    _resolve_patient(claims)
    uid = claims.get("userId", "")
    body = _parse_body(event)
    updates: dict[str, Any] = {}
    if "tone" in body:
        tone = str(body.get("tone", "")).lower()
        if tone not in ("warm", "direct"):
            raise ApiError(code="INVALID_REQUEST", message="tone must be 'warm' or 'direct'", status=400)
        updates["tone"] = tone
    if "coachSmsTeaser" in body:
        updates["coachSmsTeaser"] = bool(body["coachSmsTeaser"])
    if not updates:
        raise ApiError(code="INVALID_REQUEST", message="no valid preferences provided", status=400)

    _ensure_prefs_coach(uid)
    names: dict[str, str] = {"#p": "prefs", "#c": "coach"}
    vals: dict[str, Any] = {}
    sets: list[str] = []
    for i, (k, v) in enumerate(updates.items()):
        names[f"#k{i}"] = k
        vals[f":v{i}"] = v
        sets.append(f"#p.#c.#k{i} = :v{i}")
    _users.update_item(
        Key={"userId": uid},
        UpdateExpression="SET " + ", ".join(sets),
        ExpressionAttributeNames=names,
        ExpressionAttributeValues=vals,
    )
    emit_audit(
        AUDIT_PREFS_UPDATED, actor=_actor(claims),
        subject={"userId": uid, "clientId": claims.get("clientId")},
        action="update", extra={"keys": list(updates.keys())}, request_id=_request_id(event),
    )
    return ok_response({"updated": list(updates.keys()), **updates})


def _ensure_prefs_coach(uid: str) -> None:
    """Create the prefs + prefs.coach maps if absent so the nested SET works
    (OQ-5: first writer of Users.prefs)."""
    if _users is None:
        return
    try:
        _users.update_item(
            Key={"userId": uid},
            UpdateExpression="SET #p = if_not_exists(#p, :e)",
            ExpressionAttributeNames={"#p": "prefs"},
            ExpressionAttributeValues={":e": {}},
        )
        _users.update_item(
            Key={"userId": uid},
            UpdateExpression="SET #p.#c = if_not_exists(#p.#c, :e)",
            ExpressionAttributeNames={"#p": "prefs", "#c": "coach"},
            ExpressionAttributeValues={":e": {}},
        )
    except ClientError:
        pass


# ── views + helpers ────────────────────────────────────────────────────

def _msg_view(m: dict[str, Any]) -> dict[str, Any]:
    return {
        "id": m.get("sk"),
        "role": m.get("role"),
        "text": m.get("text"),
        "createdAt": m.get("createdAt"),
        "flagged": bool(m.get("flags")),
    }


def _fact_view(f: dict[str, Any]) -> dict[str, Any]:
    item_id = str(f.get("itemId", ""))
    return {
        "factId": item_id,
        "text": f.get("text"),
        "source": f.get("source", "user"),
        "kind": "goal" if item_id.startswith("GOAL#") else "profile",
    }


def _normalize_item_id(fact_id: str) -> str:
    return fact_id if fact_id.startswith(("PROFILE#", "GOAL#")) else f"PROFILE#{fact_id}"


def _actor(claims: dict[str, Any]) -> dict[str, Any]:
    return {
        "userId": claims.get("userId", ""),
        "role": claims.get("role", ""),
        "clientId": claims.get("clientId", ""),
    }


def _request_id(event: dict[str, Any]) -> str:
    return (event.get("requestContext") or {}).get("requestId", "")


def _parse_body(event: dict[str, Any]) -> dict[str, Any]:
    raw = event.get("body") or "{}"
    try:
        return json.loads(raw)
    except (ValueError, TypeError):
        raise ApiError(
            code="INVALID_REQUEST", message="Body must be valid JSON", status=400
        )

"""
coach-daily Lambda — AI Coach C2 proactive message (+ C3 weekly recap).

Hourly EventBridge cron. Structural sibling of behavioral-detector: D2C
facility→patient iteration, a local-hour gate (COACH_LOCAL_HOUR), pause /
kill-switch / cold-start skips, conditional-PutItem dedupe, run-summary audit.
Adds positive+gentle themes → LLM copywrite → C1 §6 output lint → inbox write
(≤1/patient-local-day) → optional, opt-in SMS teaser.

Deterministic triggers choose the moment; the LLM only writes the words. Numbers
come only from the theme; the lint rejects any others. PII-free logs (T17): IDs
and counts only, never note text. Fail-closed: any copywrite error skips the
patient (no broken send) rather than crashing the sweep.
"""
from __future__ import annotations

import os
from datetime import date, datetime, timedelta, timezone
from typing import Any

import boto3
from botocore.exceptions import ClientError
from boto3.dynamodb.conditions import Key

from _shared.observability import emit_audit, get_logger
from _shared.pause_check import is_currently_paused
from _shared.coach_llm import CoachLLM, CoachLLMError
from _shared.coach_guardrails import lint_reply
from _shared import coach_memory, coach_prompts
from _shared.sms import SmsSendError, send_sms

import copywrite
import features
import teaser
from iterate import list_active_patients, list_facilities
from selection import select_theme
from rules.types import MIN_ACTIVE_DAYS

logger = get_logger()

# ── env + clients ──────────────────────────────────────────────────────

COACH_ENABLED = os.environ.get("COACH_ENABLED", "true").lower() == "true"
# Separate gate for the proactive sweep (vs chat's COACH_ENABLED). Default OFF
# so a deploy never begins autonomous proactive sends before human review — flip
# COACH_DAILY_ENABLED=true when ready to go live.
COACH_DAILY_ENABLED = os.environ.get("COACH_DAILY_ENABLED", "false").lower() == "true"
COACH_LOCAL_HOUR = int(os.environ.get("COACH_LOCAL_HOUR", "13"))
COACH_RECAP_DOW = int(os.environ.get("COACH_RECAP_DOW", "6"))       # Sunday
COACH_MIN_GAP_DAYS = max(1, int(os.environ.get("COACH_MIN_GAP_HOURS", "48")) // 24)
COACH_MODEL_ID = os.environ.get("COACH_MODEL_ID", "us.anthropic.claude-opus-4-8")
D2C_APP_BASE_URL = os.environ.get("D2C_APP_BASE_URL", "https://app.gosteady.co")
TRANSCRIPT_TTL_DAYS = 365

_ddb = boto3.resource("dynamodb")
_orgs = _ddb.Table(os.environ["ORGANIZATIONS_TABLE"])
_patients = _ddb.Table(os.environ["PATIENTS_TABLE"])
_activity = _ddb.Table(os.environ["ACTIVITY_TABLE"])
_messages = _ddb.Table(os.environ["COACH_MESSAGES_TABLE"])
_memory = _ddb.Table(os.environ["COACH_MEMORY_TABLE"])
_users = _ddb.Table(os.environ["USERS_TABLE"]) if os.environ.get("USERS_TABLE") else None

_llm = CoachLLM(model_id=COACH_MODEL_ID)

AUDIT_MESSAGE_SENT = "coach.message.sent"
AUDIT_DAILY_RUN = "coach.daily.run"


def handler(event: dict[str, Any], context: Any) -> dict[str, Any]:  # noqa: ARG001
    summary: dict[str, int] = {
        "facilitiesEvaluated": 0, "facilitiesSkipped": 0, "patientsEvaluated": 0,
        "killswitchSkipped": 0, "pausedSkipped": 0, "coldStartSkipped": 0,
        "freqCapSkipped": 0, "noThemeSkipped": 0, "llmError": 0, "lintDropped": 0,
        "alreadySentSkipped": 0, "messagesSent": 0, "teasersSent": 0,
        "teaserFailed": 0, "writeErrors": 0,
    }
    if not (COACH_ENABLED and COACH_DAILY_ENABLED):
        logger.info("coach_daily_disabled",
                    extra={"coachEnabled": COACH_ENABLED, "dailyEnabled": COACH_DAILY_ENABLED})
        return {"disabled": True}

    for facility in list_facilities(_orgs):
        if facility.local_now.hour != COACH_LOCAL_HOUR:
            summary["facilitiesSkipped"] += 1
            continue
        summary["facilitiesEvaluated"] += 1
        is_recap_day = facility.local_now.weekday() == COACH_RECAP_DOW
        for patient in list_active_patients(_patients, facility=facility):
            summary["patientsEvaluated"] += 1
            try:
                _process_patient(patient, facility, is_recap_day, summary)
            except Exception:  # noqa: BLE001 — one bad patient must not abort the sweep
                summary["writeErrors"] += 1
                logger.exception("coach_daily_patient_error",
                                 extra={"patientId": patient.get("patientId")})

    emit_audit(AUDIT_DAILY_RUN, action="observe", extra=summary)
    logger.info("coach_daily_done", extra=summary)
    return {"summary": summary}


def _process_patient(
    patient: dict[str, Any], facility: Any, is_recap_day: bool, summary: dict[str, int]
) -> None:
    pid = patient["patientId"]
    if patient.get("coachEnabled") is False:
        summary["killswitchSkipped"] += 1
        return
    if is_currently_paused(patient):
        summary["pausedSkipped"] += 1
        return

    now = facility.local_now
    today_rows = features.query_today(_activity, patient_id=pid, tz_name=facility.timezone, now=now)
    hist_rows = features.query_history(_activity, patient_id=pid, tz_name=facility.timezone, now=now)
    f = features.compute_features(today_rows, hist_rows, now=now)

    if f.active_days < MIN_ACTIVE_DAYS and not is_recap_day:
        summary["coldStartSkipped"] += 1
        return
    if _wrote_within_gap(pid, now):
        summary["freqCapSkipped"] += 1
        return

    theme = select_theme(f, is_recap_day=is_recap_day, device_online=True)
    if theme is None:
        summary["noThemeSkipped"] += 1
        return

    mem = coach_memory.load(_memory, pid)
    tone = _tone_for(patient)
    allowlist = copywrite.build_allowlist(theme)
    note = _copywrite_linted(theme, mem, tone, allowlist, summary)
    if note is None:
        return

    if not _write_inbox(pid, patient, note, theme, now):
        summary["alreadySentSkipped"] += 1
        return
    summary["messagesSent"] += 1
    emit_audit(
        AUDIT_MESSAGE_SENT,
        subject={"patientId": pid, "clientId": patient.get("clientId")},
        action="create",
        extra={"themeType": theme.theme_type},
    )
    _maybe_teaser(patient, summary)


def _copywrite_linted(theme, mem, tone, allowlist, summary) -> str | None:
    """Copywrite → lint → regenerate once → else drop (quiet is always safe)."""
    for attempt in range(2):
        try:
            note = copywrite.copywrite(
                _llm, theme, memory_text=mem.profile_text(),
                goals_text=mem.goals_text(), tone=tone,
            )
        except CoachLLMError:
            summary["llmError"] += 1
            return None
        if lint_reply(note, allowlist=allowlist).ok:
            return note
    summary["lintDropped"] += 1
    return None


def _tone_for(patient: dict[str, Any]) -> str | None:
    """C3 warm/direct toggle from Users.prefs.coach.tone (default warm)."""
    if _users is None:
        return None
    uid = patient.get("cognitoUserId")
    if not uid:
        return None
    try:
        row = _users.get_item(Key={"userId": uid}).get("Item") or {}
    except ClientError:
        return None
    prefs = row.get("prefs") or {}
    coach = prefs.get("coach") or {} if isinstance(prefs, dict) else {}
    return coach.get("tone")


def _wrote_within_gap(pid: str, now: datetime) -> bool:
    """True if a proactive note was written within the last COACH_MIN_GAP_DAYS."""
    res = _messages.query(
        KeyConditionExpression=Key("patientId").eq(pid) & Key("sk").begins_with("INBOX#"),
        ScanIndexForward=False, Limit=1,
    )
    items = res.get("Items", [])
    if not items:
        return False
    try:
        last = date.fromisoformat(str(items[0].get("sk", "")).split("#", 1)[1])
    except (ValueError, IndexError):
        return False
    return (now.date() - last).days < COACH_MIN_GAP_DAYS


def _write_inbox(pid, patient, note, theme, now) -> bool:
    sk = f"INBOX#{now.date().isoformat()}"
    expires = int((datetime.now(timezone.utc) + timedelta(days=TRANSCRIPT_TTL_DAYS)).timestamp())
    item = {
        "patientId": pid, "sk": sk, "role": "coach", "kind": "proactive",
        "text": note, "themeType": theme.theme_type, "modelId": COACH_MODEL_ID,
        "promptVersion": coach_prompts.PROMPT_VERSION,
        "createdAt": now.strftime("%Y-%m-%dT%H:%M:%S%z"), "expiresAt": expires,
    }
    try:
        _messages.put_item(
            Item=item,
            ConditionExpression="attribute_not_exists(patientId) AND attribute_not_exists(#sk)",
            ExpressionAttributeNames={"#sk": "sk"},
        )
        return True
    except ClientError as exc:
        if exc.response["Error"]["Code"] == "ConditionalCheckFailedException":
            return False
        raise


def _maybe_teaser(patient: dict[str, Any], summary: dict[str, int]) -> None:
    """Best-effort, opt-in SMS teaser. Never fails the run. No opt-in ⇒ no send."""
    if _users is None:
        return
    uid = patient.get("cognitoUserId")
    if not uid:
        return
    try:
        user_row = _users.get_item(Key={"userId": uid}).get("Item")
    except ClientError:
        return
    if not teaser.opted_in(user_row):
        return
    phone = (user_row or {}).get("phoneNumber") or (user_row or {}).get("phone")
    if not phone:
        return
    try:
        send_sms(phone, teaser.teaser_body(D2C_APP_BASE_URL))
        summary["teasersSent"] += 1
    except SmsSendError:
        summary["teaserFailed"] += 1  # best-effort; the inbox note already landed

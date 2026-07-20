"""
Coach LLM adapter — the single seam for every model call (AI Coach C1 D1/L2).

Speaks the Amazon Bedrock Converse API via boto3. We deliberately do NOT use
`anthropic[bedrock]`: it drags `pydantic-core` native wheels that the repo's
Docker-less local Lambda bundling (processing-lambda.ts) cannot build for the
Lambda Linux/ARM64 target. boto3 is already in the runtime, speaks a
Messages-shaped API, and keeps coach-api dependency-free (C1-D8 / OQ-3
resolved). Swapping to the first-party API or a different model is a change
confined to this module.

Fail-closed like _shared/sms.py: any Bedrock error raises CoachLLMError, which
the handler turns into a calm scripted line. Never logs prompt or completion
bodies — token counts only (T17).
"""
from __future__ import annotations

import os
from typing import Any

import boto3
from botocore.exceptions import BotoCoreError, ClientError

from .observability import get_logger

logger = get_logger()

DEFAULT_MODEL_ID = os.environ.get("COACH_MODEL_ID", "us.anthropic.claude-opus-4-8")
DEFAULT_TRIAGE_MODEL_ID = os.environ.get(
    "COACH_TRIAGE_MODEL_ID", "us.anthropic.claude-haiku-4-5-20251001-v1:0"
)

TRIAGE_CLASSES: tuple[str, ...] = (
    "ok", "medical", "emergency", "self-harm", "abuse-neglect", "off-scope",
)


class CoachLLMError(RuntimeError):
    """Model call failed. Callers MUST fail closed (scripted reply)."""


class CoachLLM:
    def __init__(
        self,
        *,
        model_id: str = DEFAULT_MODEL_ID,
        triage_model_id: str = DEFAULT_TRIAGE_MODEL_ID,
        client: Any = None,
    ) -> None:
        self._model_id = model_id
        self._triage_model_id = triage_model_id
        self._client = client  # injectable for tests; lazily built otherwise

    @property
    def client(self) -> Any:
        if self._client is None:
            self._client = boto3.client("bedrock-runtime")
        return self._client

    def chat(
        self,
        *,
        system: list[dict[str, Any]],
        messages: list[dict[str, Any]],
        max_tokens: int = 400,
        temperature: float = 0.7,
    ) -> str:
        """One coach reply. `system` is a list of Converse system blocks
        (static persona + optional cachePoint + dynamic context); `messages`
        is the alternating user/assistant list."""
        out = self._converse(self._model_id, system, messages, max_tokens, temperature)
        return _extract_text(out)

    def classify(self, message: str) -> str:
        """Fast safety triage (Haiku). Returns one of TRIAGE_CLASSES; anything
        unrecognized maps to 'ok'. The handler's deterministic screen is the
        authoritative catch for high-risk, so a soft 'ok' here is safe."""
        system = [{"text": _TRIAGE_SYSTEM}]
        messages = [{"role": "user", "content": [{"text": message}]}]
        out = self._converse(
            self._triage_model_id, system, messages, max_tokens=8, temperature=0.0
        )
        text = _extract_text(out).strip().lower()
        label = text.split()[0].strip(".,!") if text else "ok"
        return label if label in TRIAGE_CLASSES else "ok"

    def _converse(
        self,
        model_id: str,
        system: list[dict[str, Any]],
        messages: list[dict[str, Any]],
        max_tokens: int,
        temperature: float,
    ) -> dict[str, Any]:
        try:
            resp = self.client.converse(
                modelId=model_id,
                system=system,
                messages=messages,
                inferenceConfig={"maxTokens": max_tokens, "temperature": temperature},
            )
        except (ClientError, BotoCoreError) as exc:  # truncate; no bodies (T17)
            logger.warning(
                "coach_llm_error",
                extra={"error": str(exc)[:200], "modelId": model_id},
            )
            raise CoachLLMError(f"Bedrock converse failed: {str(exc)[:200]}") from exc
        usage = resp.get("usage", {}) or {}
        logger.info(
            "coach_llm_call",
            extra={
                "modelId": model_id,
                "inputTokens": usage.get("inputTokens"),
                "outputTokens": usage.get("outputTokens"),
                "cacheReadTokens": usage.get("cacheReadInputTokens"),
            },
        )
        return resp


def _extract_text(resp: dict[str, Any]) -> str:
    try:
        blocks = resp["output"]["message"]["content"]
    except (KeyError, TypeError):
        return ""
    return "".join(b.get("text", "") for b in blocks if isinstance(b, dict))


_TRIAGE_SYSTEM = (
    "You are a safety classifier for messages sent to an AI walking coach used by "
    "older adults. Read the user's message and reply with EXACTLY ONE lowercase label "
    "and nothing else:\n"
    "- self-harm: any hint of suicide, self-harm, not wanting to live, or being a burden\n"
    "- emergency: a fall, injury, chest pain, trouble breathing, or immediate danger\n"
    "- abuse-neglect: being hurt, neglected, or unsafe with a caregiver\n"
    "- medical: symptoms, medications, diagnoses, or medical questions\n"
    "- off-scope: finance, legal, purchases, or clearly unrelated topics\n"
    "- ok: anything else, including normal chat about walking, activity, and daily life\n"
    "When unsure between a risky label and ok, choose the risky label."
)

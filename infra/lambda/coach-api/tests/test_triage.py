"""
Triage tests — AI Coach C1 §6.2 / §8 T2. The deterministic screen must catch
the highest-risk classes on its own (defense in depth), including the oblique
elderly self-harm idioms from the red-team set.

    cd infra/lambda && python3 -m pytest coach-api/tests/test_triage.py -q
"""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

_LAMBDA_DIR = Path(__file__).resolve().parents[2]  # infra/lambda
_COACH_DIR = Path(__file__).resolve().parents[1]    # coach-api
sys.path.insert(0, str(_LAMBDA_DIR))
sys.path.insert(0, str(_COACH_DIR))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import _stub_powertools  # noqa: F401,E402

from triage import triage  # noqa: E402


class _StubLLM:
    def __init__(self, label: str, *, raise_it: bool = False) -> None:
        self._label = label
        self._raise = raise_it

    def classify(self, message: str) -> str:
        if self._raise:
            raise RuntimeError("bedrock down")
        return self._label


class TriageScreenTest(unittest.TestCase):
    def test_self_harm_idioms_caught_without_llm(self):
        for msg in (
            "I'm just so tired of being a burden to my family",
            "Honestly I don't want to live anymore",
            "sometimes I feel like everyone would be better off dead",
            "I've been thinking about suicide",
        ):
            r = triage(msg)  # no llm — deterministic screen only
            self.assertEqual(r.cls, "self-harm", msg)
            self.assertIsNotNone(r.scripted)
            self.assertIn("988", r.scripted)

    def test_emergency_caught(self):
        r = triage("I've fallen and I can't get up")
        self.assertEqual(r.cls, "emergency")
        self.assertIn("911", r.scripted)

    def test_abuse_caught(self):
        r = triage("I'm scared of my caregiver, he hurts me")
        self.assertEqual(r.cls, "abuse-neglect")
        self.assertIsNotNone(r.scripted)

    def test_medical_redirected(self):
        r = triage("should i take my blood pressure medication before walking?")
        self.assertEqual(r.cls, "medical")
        self.assertIsNotNone(r.scripted)

    def test_ok_message_passes_through(self):
        r = triage("I walked to the mailbox today and it felt great!")
        self.assertEqual(r.cls, "ok")
        self.assertIsNone(r.scripted)


class TriageLLMTest(unittest.TestCase):
    def test_llm_refines_ok_to_off_scope(self):
        r = triage("what do you think about the stock market?", llm=_StubLLM("off-scope"))
        self.assertEqual(r.cls, "off-scope")
        self.assertIsNotNone(r.scripted)

    def test_deterministic_high_risk_ignores_llm(self):
        # Screen catches self-harm; a misfiring llm can't downgrade it.
        r = triage("I want to die", llm=_StubLLM("ok"))
        self.assertEqual(r.cls, "self-harm")

    def test_llm_error_is_failsafe(self):
        r = triage("just chatting about my dog", llm=_StubLLM("", raise_it=True))
        self.assertEqual(r.cls, "ok")  # error → deterministic result stands


if __name__ == "__main__":
    unittest.main()

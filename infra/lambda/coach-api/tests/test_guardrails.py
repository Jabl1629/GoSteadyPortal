"""
Output-lint tests — AI Coach C1 §6.4 / §8 T3. The lint is the last line
before a generated reply reaches an elderly user.

    cd infra/lambda && python3 -m pytest coach-api/tests/test_guardrails.py -q
"""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

_LAMBDA_DIR = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(_LAMBDA_DIR))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import _stub_powertools  # noqa: F401,E402

from _shared.coach_guardrails import lint_reply  # noqa: E402


class LintTest(unittest.TestCase):
    def test_clean_grounded_reply_passes(self):
        r = lint_reply(
            "Nice work — 22 active minutes yesterday! What got you moving?",
            allowlist={"22"},
        )
        self.assertTrue(r.ok, r.reasons)

    def test_ungrounded_number_rejected(self):
        r = lint_reply("Amazing, you walked 500 minutes!", allowlist={"22"})
        self.assertFalse(r.ok)
        self.assertTrue(any("ungrounded_number" in x for x in r.reasons))

    def test_banned_disease_claim_rejected(self):
        for bad in (
            "Walking helps your arthritis feel better.",
            "This will reduce the risk of falls.",
            "Great for preventing dementia!",
        ):
            r = lint_reply(bad, allowlist=set())
            self.assertFalse(r.ok, bad)
            self.assertTrue(any("banned_claim" in x for x in r.reasons), bad)

    def test_identity_violation_rejected(self):
        for bad in ("I'm a real nurse, trust me.", "I am not an AI, I'm a person."):
            r = lint_reply(bad, allowlist=set())
            self.assertFalse(r.ok, bad)
            self.assertIn("identity_violation", r.reasons)

    def test_url_and_phone_rejected(self):
        self.assertFalse(lint_reply("See www.example.com", allowlist=set()).ok)
        self.assertFalse(lint_reply("Call me at 512-555-0100", allowlist=set()).ok)

    def test_too_many_sentences_rejected(self):
        r = lint_reply("One. Two. Three. Four. Five.", allowlist=set())
        self.assertFalse(r.ok)
        self.assertIn("too_many_sentences", r.reasons)

    def test_empty_rejected(self):
        self.assertFalse(lint_reply("   ", allowlist=set()).ok)

    def test_plain_words_not_flagged_as_numbers(self):
        # No digits → nothing to ground.
        r = lint_reply("You're doing wonderfully — keep it up!", allowlist=set())
        self.assertTrue(r.ok, r.reasons)

    def test_walking_talk_not_false_flagged(self):
        # "street" must not trip the "treat" banned fragment.
        r = lint_reply("A stroll down your street sounds lovely!", allowlist=set())
        self.assertTrue(r.ok, r.reasons)


if __name__ == "__main__":
    unittest.main()

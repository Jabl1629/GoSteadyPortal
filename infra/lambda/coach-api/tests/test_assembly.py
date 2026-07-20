"""
Context-assembly tests — AI Coach C1 §5.3. The static persona must stay a
stable (cacheable) block; conversation turns must be strictly alternating and
start with user (Converse requirement).

    cd infra/lambda && python3 -m pytest coach-api/tests/test_assembly.py -q
"""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

_LAMBDA_DIR = Path(__file__).resolve().parents[2]
_COACH_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(_LAMBDA_DIR))
sys.path.insert(0, str(_COACH_DIR))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import _stub_powertools  # noqa: F401,E402

import assembly  # noqa: E402


class BuildSystemTest(unittest.TestCase):
    def test_persona_first_then_context(self):
        blocks = assembly.build_system("walks with her daughter", "Yesterday: 22 minutes.")
        self.assertIn("Steady", blocks[0]["text"])
        joined = " ".join(b.get("text", "") for b in blocks)
        self.assertIn("22", joined)
        self.assertIn("daughter", joined)

    def test_no_cache_point_by_default(self):
        # cachePoint defaults OFF until validated against a live model
        # (dev e2e 2026-07-19: coach fail-closes on any Converse error, so an
        # unverified cache block would silently degrade every chat).
        blocks = assembly.build_system("", "digest")
        self.assertFalse(any("cachePoint" in b for b in blocks))


class BuildMessagesTest(unittest.TestCase):
    def test_leading_assistant_dropped_and_coalesced(self):
        turns = [
            {"role": "coach", "text": "hi there"},
            {"role": "user", "text": "a"},
            {"role": "user", "text": "b"},
        ]
        msgs = assembly.build_messages(turns, "c")
        self.assertEqual(msgs[0]["role"], "user")  # leading assistant removed
        # a, b, c are all user turns → coalesced into one message
        self.assertEqual(len(msgs), 1)
        self.assertEqual(len(msgs[0]["content"]), 3)

    def test_alternation_preserved(self):
        turns = [
            {"role": "user", "text": "how am I doing?"},
            {"role": "coach", "text": "great!"},
        ]
        msgs = assembly.build_messages(turns, "thanks")
        roles = [m["role"] for m in msgs]
        self.assertEqual(roles, ["user", "assistant", "user"])

    def test_empty_turns_skipped(self):
        msgs = assembly.build_messages([{"role": "user", "text": ""}], "hello")
        self.assertEqual(len(msgs), 1)
        self.assertEqual(msgs[0]["role"], "user")


if __name__ == "__main__":
    unittest.main()

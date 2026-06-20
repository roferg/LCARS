"""Mission-Log per-bug model-override NORMALIZER (S74 follow-up).

The bug: the web Mission-Log per-bug override silently DROPPED any value that
wasn't already `<scope>:<tier>` — a logged bug skips Align, so plain language
("Opus 4.8", "keep it cheap") had no normalizer and was discarded, leaving the
child on the wrong (default Sonnet) model with no error.

The fix mirrors how a MISSION works: Align's worker normalizes the captain's
plain language to a structured `<scope>:<tier>` (skills/lcars-file/SKILL.md
:183-186). A logged bug gets the SAME normalization via a HYBRID normalizer:
  1. passthrough an already-structured `<scope>:<tier>`,
  2. deterministic parse of common plain language,
  3. one bounded worker call (the same instruction Align uses) as a fallback,
  4. NEVER silent-drop — an unparseable value surfaces an error.

These tests stub the worker fallback (a plain callable) so they cost ZERO tokens.
"""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from lcars_serve.actions import normalize_override  # noqa: E402


class DeterministicTest(unittest.TestCase):
    """Step 1 (passthrough) + step 2 (deterministic parse) — no worker needed."""

    def _norm(self, raw):
        # the fallback MUST NOT be reached for these — pass a poison callable.
        def _poison(_raw):
            raise AssertionError(
                "deterministic path should not reach the LLM fallback for %r"
                % raw)
        return normalize_override(raw, worker=_poison)

    def test_passthrough_structured(self):
        self.assertEqual(self._norm("all:opus"),
                         {"scope": "all", "tier": "opus"})

    def test_passthrough_structured_case_and_space(self):
        self.assertEqual(self._norm("  Reasoning:OPUS "),
                         {"scope": "reasoning", "tier": "opus"})

    def test_opus_4_8(self):
        self.assertEqual(self._norm("Opus 4.8"),
                         {"scope": "all", "tier": "opus"})

    def test_bare_opus(self):
        self.assertEqual(self._norm("opus"),
                         {"scope": "all", "tier": "opus"})

    def test_use_opus_the_whole_way(self):
        self.assertEqual(self._norm("use Opus the whole way"),
                         {"scope": "all", "tier": "opus"})

    def test_keep_it_cheap(self):
        self.assertEqual(self._norm("keep it cheap"),
                         {"scope": "all", "tier": "sonnet"})

    def test_reasoning_on_opus(self):
        self.assertEqual(self._norm("reasoning on opus"),
                         {"scope": "reasoning", "tier": "opus"})

    def test_cheap_implementation(self):
        self.assertEqual(self._norm("cheap implementation"),
                         {"scope": "implementation", "tier": "sonnet"})

    def test_sonnet_4_6(self):
        self.assertEqual(self._norm("use 4.6"),
                         {"scope": "all", "tier": "sonnet"})

    def test_blank_is_none(self):
        # an empty / blank steer is "no override" (NOT an error) — caller skips it.
        self.assertIsNone(self._norm(""))
        self.assertIsNone(self._norm("   "))
        self.assertIsNone(normalize_override(None, worker=None))


class LLMFallbackTest(unittest.TestCase):
    """Step 3 — a tier-less phrasing the deterministic parser can't map goes to a
    bounded worker call applying the SAME Align instruction; its reply is parsed."""

    def test_fallback_reached_when_no_tier_found(self):
        seen = {}

        def _worker(raw):
            seen["raw"] = raw
            return "reasoning:opus"

        # no tier word here → deterministic is inconclusive → fallback.
        out = normalize_override("make the thinking smarter", worker=_worker)
        self.assertEqual(out, {"scope": "reasoning", "tier": "opus"})
        self.assertIn("make the thinking smarter", seen.get("raw", ""))

    def test_fallback_reply_can_be_fenced_or_noisy(self):
        def _worker(_raw):
            return 'some prose\n```json\n"all:sonnet"\n```\n'
        # the worker reply is parsed leniently for a <scope>:<tier>.
        out = normalize_override("dial it back a notch", worker=_worker)
        self.assertEqual(out, {"scope": "all", "tier": "sonnet"})

    def test_fallback_null_returns_none(self):
        def _worker(_raw):
            return "null"
        self.assertIsNone(normalize_override("asdfqwer zzz", worker=_worker))

    def test_fallback_unparseable_returns_none(self):
        def _worker(_raw):
            return "I could not determine the model."
        self.assertIsNone(normalize_override("???", worker=_worker))

    def test_no_worker_and_inconclusive_returns_none(self):
        # no fallback wired + deterministic inconclusive ⇒ None (never a guess).
        self.assertIsNone(normalize_override("be smart about it", worker=None))


if __name__ == "__main__":
    unittest.main()

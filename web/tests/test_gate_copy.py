"""S157 x #93 — the gate card's "Why you're seeing this" copy, per escalationType.

BUG-027 made this copy TYPE-AWARE precisely so one gate does not read like
another: a regression gate must not read as a strategic call. S157 then added a
new type the board had never seen, `environment` — the full-suite gate could not
re-run the suites against a trustworthy dependency environment, so it attributed
the break to NO ticket and dispatched NO worker.

The `default` branch caught it safely, but its copy says the harness "needs your
decision to proceed". That is false twice over for this gate: nothing about the
work is being decided, and the fault is not in any ticket's code. A human staring
at the card should not have to expand the technical detail to learn that.

These drive the REAL whyCopyForGate() out of the shipping board.js through a
sandboxed vm (ADR-007: no build step, no jsdom), so the assertions are about what
ships rather than a transcription of it.
"""
import json
import os
import subprocess
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
HARNESS = os.path.join(HERE, "board_gatecopy_harness.js")


def _copy_for(types):
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as fh:
        json.dump(types, fh)
        spec = fh.name
    try:
        out = subprocess.run(["node", HARNESS, spec],
                             capture_output=True, text=True, check=True)
    finally:
        os.unlink(spec)
    data = json.loads(out.stdout)
    assert not data["bootErrors"], "board.js failed to boot: %s" % data["bootErrors"]
    return data["copy"]


class GateCopyTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.copy = _copy_for(["environment", "regression", "cap", "scope", None,
                              "some-type-nobody-has-invented-yet"])

    # --- the new type -----------------------------------------------------
    def test_environment_says_it_is_the_toolchain_not_the_code(self):
        c = self.copy["environment"]
        self.assertIn("TOOLCHAIN", c)
        low = c.lower()
        self.assertIn("not your code", low)

    def test_environment_says_no_ticket_is_implicated(self):
        self.assertIn("no ticket is implicated", self.copy["environment"].lower())

    def test_environment_tells_the_operator_what_to_actually_do(self):
        # The actionable repair, matching what the CLI prints for the same gate.
        c = self.copy["environment"]
        self.assertIn("lcars update", c)
        self.assertIn("run the mission again", c.lower())

    def test_environment_does_not_ask_for_a_decision(self):
        # The generic default copy asks the operator to decide and answer; this
        # gate asks for neither, and saying so would be the same class of lie the
        # type-aware copy exists to prevent.
        low = self.copy["environment"].lower()
        self.assertNotIn("needs your decision", low)
        self.assertNotIn("answer below", low)

    def test_environment_is_distinct_from_the_default(self):
        self.assertNotEqual(self.copy["environment"], self.copy["__default__"])

    # --- everything else is untouched -------------------------------------
    def test_default_branch_still_catches_genuinely_unknown_types(self):
        unknown = self.copy["some-type-nobody-has-invented-yet"]
        self.assertEqual(unknown, self.copy["__default__"])
        self.assertIn("needs your decision", unknown.lower())

    def test_the_established_types_are_unchanged(self):
        self.assertIn("two of your changes conflict", self.copy["regression"])
        self.assertIn("automatic-retry limit", self.copy["cap"])
        self.assertIn("strategic/scope call", self.copy["scope"])

    def test_every_type_opens_with_the_same_stem(self):
        # The type-aware branches differ in what they SAY, not in how the card
        # introduces them.
        for key, text in self.copy.items():
            self.assertTrue(text.startswith("Why you’re seeing this — "),
                            "%s copy lost the shared opening: %r" % (key, text[:40]))


if __name__ == "__main__":
    unittest.main()

"""S214 fix round 1, D4 — THE MODEL TIER AND ITS EXPLANATION MUST AGREE.

Measured on the captain's own missions: `modelMix` reported `"tier": "opus"`
on all six stages while the `why` under the table said

    "…so both criticalities are low and the default ramp keeps every stage on
    Sonnet."

He reads both. One of them is untrue.

WHICH ONE IS RIGHT: THE TIER. It is not a fallback and not a default — it is a
RESOLUTION. `estimate.json.models` really does say `sonnet` on all six stages,
and `effective_tier` maps the mission's engine and that logical tier through
the alias policy the harness itself uses (`skills/lcars-run/run.sh`'s
`alias_for_tier`). On copilot BOTH logical tiers resolve to `claude-opus-5.5`,
so Opus is genuinely what runs.

WHY THEY DISAGREED. They are two facts from two records that never met. The
tier comes from the alias resolution; the `why` is a verbatim copy of the
estimator's own `rationale`, free prose written by a model that is never told
which engine the mission runs on — so it narrates the LOGICAL ramp it chose
and knows nothing about what that ramp resolves to.

THE CURE READS THE RESOLUTION, IT DOES NOT RE-READ THE PROSE. Nothing here
greps the rationale for the word "Sonnet" — a regex over a sentence measures
wording, not meaning, and this project has already watched one such classifier
fall over on a reworded corpus. The trigger is the recorded fact that the
resolution MOVED a stage off the tier the estimator picked. When it moved, the
estimator's ramp sentence is not a description of this run, and the table says
so. When nothing moved there is nothing to reconcile and the prose stands
exactly as it is.

No gh, no network, no model, no worker.
"""
import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))

from lcars_serve import board  # noqa: E402

# The captain's mission …004, verbatim off his disk.
REAL_RATIONALE = (
    "Blast radius is a single module - no callers outside it - so both "
    "criticalities are low and the default ramp keeps every stage on Sonnet.")

SIX_SONNET = {k: "sonnet" for k in
              ("research", "validate", "plan", "planReview", "implement",
               "verify")}


def _mix(models, rationale, engine, aliases=None):
    return board.model_mix_from_estimate(
        {"models": models, "rationale": rationale},
        engine=engine, model_aliases=aliases)


class TheCopilotMissionTheCaptainRead(unittest.TestCase):
    """Six Sonnet rows in the estimate, a copilot engine, and a rationale that
    talks about Sonnet. This is mission …004 exactly."""

    def setUp(self):
        self.rows = _mix(SIX_SONNET, REAL_RATIONALE, "copilot")

    def test_every_stage_really_does_run_on_opus(self):
        """The tier was never the lie — pin it so the cure cannot 'agree' by
        breaking the true half."""
        self.assertEqual({"opus"}, {r["tier"] for r in self.rows})
        self.assertEqual(6, len(self.rows))

    def test_the_explanation_no_longer_claims_the_stages_run_on_sonnet(self):
        why = self.rows[0]["why"]
        self.assertIsNotNone(why)
        tail = why[len(REAL_RATIONALE):]
        self.assertTrue(
            tail.strip(),
            "the rationale still stands alone, contradicting the tier beside it")

    def test_the_explanation_names_the_tier_the_table_shows(self):
        self.assertIn("Opus", self.rows[0]["why"])

    def test_the_estimators_own_reasoning_is_not_thrown_away(self):
        """He should still be told WHY it was sized the way it was — that half
        of the sentence is true and is the only record of the sizing."""
        self.assertIn("both criticalities are low", self.rows[0]["why"])

    def test_every_row_carries_the_same_reconciled_sentence(self):
        """The front end shows the first non-empty `why` as one note under the
        whole table; the rows must not disagree among themselves."""
        self.assertEqual(1, len({r["why"] for r in self.rows}))


class NothingMovedNothingSaid(unittest.TestCase):
    """A claude mission's tiers pass straight through. There is no
    contradiction, so there is nothing to add and the prose is untouched."""

    def test_a_claude_mission_keeps_its_rationale_verbatim(self):
        rows = _mix(SIX_SONNET, REAL_RATIONALE, "claude")
        self.assertEqual({"sonnet"}, {r["tier"] for r in rows})
        self.assertEqual(REAL_RATIONALE, rows[0]["why"])

    def test_a_repo_that_aliases_copilot_back_to_sonnet_keeps_it_verbatim(self):
        """The repo's own `modelAliases` override is honoured by the
        resolution, so on such a repo the ramp really does keep every stage on
        Sonnet and the estimator's sentence is simply true."""
        rows = _mix(SIX_SONNET, REAL_RATIONALE, "copilot",
                    aliases={"copilot": {"sonnet": "claude-sonnet-4.6"}})
        self.assertEqual({"sonnet"}, {r["tier"] for r in rows})
        self.assertEqual(REAL_RATIONALE, rows[0]["why"])

    def test_an_opus_estimate_on_copilot_is_unmoved_and_unannotated(self):
        rows = _mix({k: "opus" for k in SIX_SONNET}, REAL_RATIONALE, "copilot")
        self.assertEqual({"opus"}, {r["tier"] for r in rows})
        self.assertEqual(REAL_RATIONALE, rows[0]["why"])


class NoProseIsParsedAndNoneIsInvented(unittest.TestCase):

    def test_a_rationale_that_never_mentions_a_model_is_still_reconciled(self):
        """The trigger is the RESOLUTION, not the wording. A rationale that
        says nothing about models still sits under a table of Opus rows that
        the estimator scored Sonnet, and the reader is owed the resolution."""
        rows = _mix(SIX_SONNET, "Blast radius is a single module.", "copilot")
        self.assertIn("Opus", rows[0]["why"])
        self.assertIn("Blast radius is a single module.", rows[0]["why"])

    def test_a_reworded_rationale_is_reconciled_just_the_same(self):
        """The same fact in different words. A classifier keyed off the
        sentence would miss this one; a cure keyed off the record cannot."""
        reworded = ("Nothing here reaches beyond one file, which is why I "
                    "left the whole run on the cheaper tier.")
        rows = _mix(SIX_SONNET, reworded, "copilot")
        self.assertIn("Opus", rows[0]["why"])
        self.assertIn(reworded, rows[0]["why"])

    def test_no_rationale_at_all_stays_none(self):
        """No prose is no contradiction. The github adapter deliberately sends
        `why: None` and its board must stay byte-identical."""
        rows = board.model_mix_from_estimate({"models": SIX_SONNET},
                                             engine="copilot")
        self.assertEqual({"opus"}, {r["tier"] for r in rows})
        self.assertEqual({None}, {r["why"] for r in rows})

    def test_a_mission_with_no_models_map_is_still_None(self):
        self.assertIsNone(board.model_mix_from_estimate(
            {"rationale": REAL_RATIONALE}, engine="copilot"))


class AMixedTableSaysSomethingTrueAboutAllOfIt(unittest.TestCase):
    """Only some stages moved, and they did not all land on one tier. Naming a
    single tier would be untrue, so the note points at the table instead."""

    def test_the_note_never_names_a_tier_it_cannot_stand_behind(self):
        rows = _mix({"research": "sonnet", "implement": "opus"},
                    REAL_RATIONALE, "copilot",
                    aliases={"copilot": {"sonnet": "claude-haiku-4",
                                         "opus": "claude-opus-4.8"}})
        self.assertEqual("haiku", rows[0]["tier"])
        self.assertEqual("opus", rows[1]["tier"])
        why = rows[0]["why"]
        self.assertNotIn("Opus", why)
        self.assertNotIn("Sonnet", why[len(REAL_RATIONALE):])
        self.assertIn("this table", why)


if __name__ == "__main__":
    unittest.main()

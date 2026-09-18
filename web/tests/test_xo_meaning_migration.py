"""S213 FIX ROUND 3, D4-RESIDUAL — THE MIGRATION GAP.

Round 1 cured D4 at the PRODUCER: `xo-score.py` now writes `scoreMeaning`
beside the score, off the same ledger, so an all-untested verdict says in its
own words that nothing here is vouched for. That half holds.

But every mission scored BEFORE that round has no `scoreMeaning` at all, and
the board explained those scores with one fixed sentence per word — MEDIUM's
claimed "the primary flow works end to end". The captain's own repos are full
of such missions: `roferg/groutwork-capstone` alone holds seven, one of them a
MEDIUM whose eleven criteria are ALL untested. He opens it and is told the
primary flow works. Nobody ever saw that flow.

THE RULE THIS FILE PINS: a surface must never assert what no record supports.

  1. A RECORDED `scoreMeaning` is read back, unchanged. Always.
  2. With none recorded, the sentence is DERIVED FROM THE LEDGER THAT IS
     THERE — an older `verdict.json` still carries its `counts` (and its
     `criteria` to tally if it does not). A sentence built from those counts
     states only arithmetic the record itself holds. It is not boilerplate and
     it is not a reading of anybody's prose.
  3. With NO usable ledger, NOTHING IS SAID. No `meaning` rides the card, the
     tooltip is empty, and the captain is told nothing rather than something
     false. A comforting sentence in that hole is the defect, not the cure.

No gh, no network, no model, no worker.
"""
import json
import os
import shutil
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))

from tests import _fixtures as fx  # noqa: E402
from lcars_serve.local_adapter import LocalAdapter  # noqa: E402

MID = "lcars-20260917-004-fea3"
FALSE = "primary flow works end to end"


class MigrationBase(unittest.TestCase):
    """A mission scored before fix round 1: a verdict on disk with NO
    `scoreMeaning`, and a state.json whose `numberOne` block has no `meaning`
    either — which is every mission Number One has ever looked at until
    tonight."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        fx.plant_simple(self.tmp, MID, stage="verify", issue=8,
                        title="the grout calculator")

    def plant(self, verdict, score="medium"):
        path = os.path.join(fx.mission_dir(self.tmp, MID), "state.json")
        doc = json.load(open(path))
        doc["numberOne"] = {"status": "finished", "engine": "copilot",
                            "score": score}
        with open(path, "w") as fh:
            json.dump(doc, fh)
        if verdict is not None:
            xodir = os.path.join(fx.mission_dir(self.tmp, MID), "xo")
            os.makedirs(xodir, exist_ok=True)
            with open(os.path.join(xodir, "verdict.json"), "w") as fh:
                json.dump(verdict, fh)

    def block(self):
        cards = [c for c in LocalAdapter(self.tmp).board()["missions"]
                 if c["id"] == MID]
        self.assertTrue(cards, "the mission is not on the board at all")
        return cards[0].get("numberOne") or {}

    def meaning(self):
        return self.block().get("meaning", "")


class ARecordedMeaningIsStillReadBack(MigrationBase):
    """THE CONTROL. Fix round 1's cure must not regress."""

    def test_the_recorded_sentence_wins_and_is_unchanged(self):
        said = ("I could not check anything on your list, so nothing here is "
                "vouched for — this is not a clean bill of health")
        self.plant({"score": "medium", "scoreMeaning": said,
                    "counts": {"met": 0, "gap": 0, "untested": 11,
                               "contradictions": 0},
                    "criteria": [], "gaps": []})
        self.assertEqual(said, self.meaning())


class AnOlderVerdictIsExplainedByItsOwnCounts(MigrationBase):
    """THE DEFECT, on the real shape. These counts are copied from the
    captain's own `groutwork-capstone` missions, read off his disk."""

    def test_an_all_untested_medium_never_claims_a_flow_nobody_saw(self):
        # lcars-20260917-004: MEDIUM, eleven criteria, every one untested.
        self.plant({"score": "medium",
                    "counts": {"met": 0, "gap": 0, "untested": 11,
                               "contradictions": 0},
                    "criteria": [], "gaps": []})
        said = self.meaning()
        self.assertTrue(said, "the card says nothing at all about the score")
        self.assertNotIn(FALSE, said)
        self.assertIn("11", said)
        self.assertIn("could not check", said)

    def test_a_mixed_ledger_says_what_its_counts_support(self):
        # lcars-20260917-007: MEDIUM, 21 met, 8 untested.
        self.plant({"score": "medium",
                    "counts": {"met": 21, "gap": 0, "untested": 8,
                               "contradictions": 0},
                    "criteria": [], "gaps": []})
        said = self.meaning()
        self.assertNotIn(FALSE, said)
        self.assertIn("21", said)
        self.assertIn("8", said)
        self.assertIn("29", said)

    def test_a_clean_ledger_says_so_and_claims_nothing_more(self):
        # lcars-20260917-006: HIGH, 31 met, nothing else.
        self.plant({"score": "high",
                    "counts": {"met": 31, "gap": 0, "untested": 0,
                               "contradictions": 0},
                    "criteria": [], "gaps": []}, score="high")
        said = self.meaning()
        self.assertIn("31", said)
        self.assertNotIn("could not check", said)

    def test_a_gapped_ledger_names_the_gap(self):
        # lcars-20260917-003: LOW, 5 met, 1 gap.
        self.plant({"score": "low",
                    "counts": {"met": 5, "gap": 1, "untested": 0,
                               "contradictions": 1},
                    "criteria": [], "gaps": []}, score="low")
        said = self.meaning()
        self.assertIn("5", said)
        self.assertIn("1", said)
        self.assertIn("6", said)

    def test_counts_missing_are_tallied_off_the_criteria_themselves(self):
        """An older schema still carries the rows; the arithmetic is the
        record's, not a guess about it."""
        self.plant({"score": "medium", "criteria": [
            {"id": "a", "status": "met"}, {"id": "b", "status": "met"},
            {"id": "c", "status": "gap"}, {"id": "d", "status": "untested"}]})
        said = self.meaning()
        self.assertNotIn(FALSE, said)
        self.assertIn("4", said)
        self.assertIn("2", said)


class WithNothingToDeriveFromNothingIsSaid(MigrationBase):
    """A surface must never assert what no record supports. `absent`, never a
    reassuring sentence in the hole."""

    def test_a_verdict_with_no_ledger_at_all_asserts_nothing(self):
        # lcars-20260917-001 on his disk: LOW, no counts, no criteria.
        self.plant({"score": "low", "derivation": "the app never came up",
                    "criteria": [], "gaps": []}, score="low")
        self.assertNotIn("meaning", self.block())

    def test_no_verdict_on_disk_at_all_asserts_nothing(self):
        self.plant(None, score="medium")
        self.assertNotIn("meaning", self.block())

    def test_an_unreadable_verdict_asserts_nothing(self):
        self.plant(None, score="medium")
        xodir = os.path.join(fx.mission_dir(self.tmp, MID), "xo")
        os.makedirs(xodir, exist_ok=True)
        with open(os.path.join(xodir, "verdict.json"), "w") as fh:
            fh.write("{not json at all")
        self.assertNotIn("meaning", self.block())

    def test_and_the_detail_view_asserts_nothing_either(self):
        self.plant(None, score="medium")
        mi = LocalAdapter(self.tmp).mission(MID)
        self.assertNotIn("meaning", mi.get("numberOne") or {})


class TheDetailViewCarriesTheSameSentence(MigrationBase):
    """The tab's score word falls back to this same block field, so the card
    and the tab cannot disagree about what the word means (C8)."""

    def test_the_derived_sentence_rides_the_detail_too(self):
        self.plant({"score": "medium",
                    "counts": {"met": 0, "gap": 0, "untested": 11,
                               "contradictions": 0},
                    "criteria": [], "gaps": []})
        mi = LocalAdapter(self.tmp).mission(MID)
        self.assertEqual(self.meaning(), mi["numberOne"]["meaning"])
        self.assertNotIn(FALSE, mi["numberOne"]["meaning"])


if __name__ == "__main__":
    unittest.main()

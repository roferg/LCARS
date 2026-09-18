"""S213 C1, the data half — THE CARD IS A SIGNAL, NOT A TRANSCRIPT.

Measured on the real board before this session: the Verify card carried Number
One's entire 150-word verdict, ran several screens tall, and buried the cost
pills, the difficulty pills and both buttons beneath it. A column you cannot
scan is not a board.

The cure needs ONE LINE on the card, and the line has to be one that CANNOT
contradict the score beside it (C8). So it is not a truncation of the worker's
prose — it is the `derivation`, the sentence `xo-score.py` writes in the same
breath as the score, off the same ledger, by the same rule. Two things said by
one piece of code cannot disagree.

  * `numberOne.headline` is RECORDED by `xo.sh`'s one finisher and travels on
    the board shape, beside `score`.
  * A mission scored BEFORE this session carries no `headline` in its state —
    so the adapter falls back to the `derivation` its own `xo/verdict.json`
    already holds. Still a recorded field; still never a reading of prose.

No gh, no network, no model, no worker.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))

from tests import _fixtures as fx  # noqa: E402
from lcars_serve import board  # noqa: E402
from lcars_serve.local_adapter import LocalAdapter  # noqa: E402

XO_SCRIPT = os.path.normpath(os.path.join(
    HERE, "..", "..", "skills", "lcars-xo", "xo.sh"))
MID = "lcars-20260917-301"

LONG = ("Captain, this build is a code-only engine change — two pure "
        "coordinate functions, a factory method, a Camera type field, and "
        "their unit tests — none of which shows up on a screen, and the PRD "
        "deliberately leaves the editor wiring that would exercise them out "
        "of scope. The example game does render fine, so the engine compiles "
        "and runs, but that proves nothing about the new methods.")
SHORT = ("I could not check the main thing you asked for — your test suite "
         "never ran.")


def _plant_xo(root, mid, block):
    path = os.path.join(fx.mission_dir(root, mid), "state.json")
    with open(path) as fh:
        lines = fh.read().splitlines(True)
    lines.insert(1, '  "numberOne": %s,\n' % json.dumps(block))
    with open(path, "w") as fh:
        fh.writelines(lines)
    return path


class TheBoardShapeCarriesTheHeadline(unittest.TestCase):

    def test_headline_rides_the_card_block(self):
        blk = board.xo_block({"status": "engaged", "score": "medium",
                              "note": LONG, "headline": SHORT})
        self.assertEqual(SHORT, blk["headline"])

    def test_a_block_with_no_headline_simply_has_none(self):
        blk = board.xo_block({"status": "engaged", "score": "medium",
                              "note": LONG})
        self.assertNotIn("headline", blk)


class TheAdapterFallsBackToTheRecordedDerivation(unittest.TestCase):
    """A mission Number One scored before this session has a verdict on disk
    and no headline in its state. The sentence is already recorded — read it,
    do not invent one and do not read the prose."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        fx.plant_simple(self.tmp, MID, stage="verify", issue=8,
                        title="worldToScreen / screenToWorld")
        _plant_xo(self.tmp, MID, {"status": "engaged", "engine": "copilot",
                                  "score": "medium", "note": LONG})
        xodir = os.path.join(fx.mission_dir(self.tmp, MID), "xo")
        os.makedirs(xodir, exist_ok=True)
        with open(os.path.join(xodir, "verdict.json"), "w") as fh:
            json.dump({"score": "medium", "derivation": SHORT,
                       "criteria": [], "gaps": [], "summary": LONG}, fh)
        self.adapter = LocalAdapter(self.tmp)

    def _card(self):
        cards = [c for c in self.adapter.board()["missions"]
                 if c["id"] == MID]
        self.assertTrue(cards, "the mission is not on the board at all")
        return cards[0]

    def test_the_card_gets_the_one_line(self):
        self.assertEqual(SHORT, self._card()["numberOne"]["headline"])

    def test_a_recorded_headline_wins_over_the_fallback(self):
        path = os.path.join(fx.mission_dir(self.tmp, MID), "state.json")
        doc = json.load(open(path))
        doc["numberOne"]["headline"] = "the recorded one"
        with open(path, "w") as fh:
            json.dump(doc, fh)
        self.assertEqual("the recorded one",
                         LocalAdapter(self.tmp).board()["missions"][0]
                         ["numberOne"]["headline"])

    def test_no_verdict_on_disk_means_no_headline_not_a_guess(self):
        os.remove(os.path.join(fx.mission_dir(self.tmp, MID), "xo",
                               "verdict.json"))
        self.assertNotIn("headline",
                         LocalAdapter(self.tmp).board()["missions"][0]
                         ["numberOne"])


# The RECORDING half — that `xo.sh`'s one finisher actually writes this field
# on a real drive — is proven where every other xo.sh behaviour is, against a
# real evaluate with a stubbed worker: `tests/lcars-xo.test.sh`, B-HEADLINE.
# A grep of the script here would only measure a correlate of it.


if __name__ == "__main__":
    unittest.main()

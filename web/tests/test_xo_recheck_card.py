"""S225 fix — THE CARD SHOWS THE CURRENT GRADE, NOT THE FIRST LOOK'S.

The captain's DX-scorecard mission was looked at twice. First look: 29 of 34
verified, 1 broken → MEDIUM. Re-check after the fixes landed: 30 of 34, 0
broken → HIGH. An improvement, MEDIUM → HIGH.

The board CARD read the FIRST look's grade (`xo/verdict.json`) while the REPORT
pane read the re-check (`xo/second/verdict.json`, surfaced as `score2`). So the
same mission, at the same moment, said MEDIUM on its card and HIGH in its own
report — and the captain read the card's superseded MEDIUM as a demotion of the
report's HIGH.

`xo.sh` already treats `score2` as the current score (xo.sh:747); the report
pane already draws the second verdict entire (board.js S224). This makes the
CARD agree with both: when a re-check exists, the card's grade — and the
headline/meaning/axes that ride beside it — come off the re-check's ledger.

CONTROL: a mission looked at ONCE has no `xo/second/verdict.json`, so nothing
changes for it. That is every mission on disk that was never re-checked, and
every verdict written before the second look existed.

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

MID = "lcars-20260921-777-dx01"

FIRST_LINE = ("one broken control still stands between this and shipping — "
              "the rest of the list is in the build.")
FIRST_MEANING = "There is a stated criterion the build does not meet"
SECOND_LINE = "everything you asked for is in the build, and each one works."
SECOND_MEANING = "Every stated criterion is met."


def _plant_xo(root, mid, block):
    path = os.path.join(fx.mission_dir(root, mid), "state.json")
    with open(path) as fh:
        lines = fh.read().splitlines(True)
    lines.insert(1, '  "numberOne": %s,\n' % json.dumps(block))
    with open(path, "w") as fh:
        fh.writelines(lines)
    return path


def _plant_verdict(root, mid, doc, second=False):
    xodir = os.path.join(fx.mission_dir(root, mid), "xo")
    if second:
        xodir = os.path.join(xodir, "second")
    os.makedirs(xodir, exist_ok=True)
    path = os.path.join(xodir, "verdict.json")
    with open(path, "w") as fh:
        json.dump(doc, fh)
    return path


class TheReCheckGradeIsTheCardGrade(unittest.TestCase):
    """The captain's DX-scorecard mission, reproduced: MEDIUM → HIGH."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        fx.plant_simple(self.tmp, MID, stage="verify", issue=7,
                        title="DX scorecard")
        # The state block is the FIRST look's copy (`score`), plus the
        # re-check's `score2` that `xo.sh` recorded without disturbing `score`.
        _plant_xo(self.tmp, MID, {
            "status": "finished", "score": "medium", "score2": "high",
            "headline": FIRST_LINE, "lastAction": "re-checked 20:41"})
        # THE FIRST LOOK — 29 of 34, 1 broken → MEDIUM.
        _plant_verdict(self.tmp, MID, {
            "score": "medium", "derivation": FIRST_LINE,
            "scoreMeaning": FIRST_MEANING,
            "counts": {"met": 29, "gap": 1, "untested": 4},
            "criteria": [], "summary": "first look"})
        # THE RE-CHECK — 30 of 34, 0 broken → HIGH. Never reverted.
        _plant_verdict(self.tmp, MID, {
            "score": "high", "derivation": SECOND_LINE,
            "scoreMeaning": SECOND_MEANING,
            "counts": {"met": 30, "gap": 0, "untested": 4},
            "criteria": [], "summary": "re-check"}, second=True)

    def _card(self):
        cards = [c for c in LocalAdapter(self.tmp).board()["missions"]
                 if c["id"] == MID]
        self.assertTrue(cards, "the mission is not on the board at all")
        return cards[0]

    def test_the_card_shows_the_recheck_high_not_the_first_look_medium(self):
        self.assertEqual("high", self._card()["numberOne"]["score"])

    def test_the_card_and_the_report_agree_on_the_current_grade(self):
        card = self._card()["numberOne"]
        # The report pane (board.js S224) and `xo.sh` both take the current
        # grade from the re-check. The re-check's own ledger records `high`;
        # the card must land on that same word rather than the first look's.
        second = os.path.join(fx.mission_dir(self.tmp, MID),
                              "xo", "second", "verdict.json")
        with open(second) as fh:
            self.assertEqual("high", json.load(fh)["score"])
        self.assertEqual("high", card["score"])

    def test_the_recheck_sentence_rides_beside_the_recheck_grade(self):
        """A grade that reverted to the re-check must not wear the first
        look's sentence — that is the S214 whole-block-is-stale rule, applied
        to the newer look instead of the older one."""
        xo = self._card()["numberOne"]
        self.assertEqual(SECOND_LINE, xo["headline"])
        self.assertEqual(SECOND_MEANING, xo["meaning"])


class AMissionLookedAtOnceIsUnchanged(unittest.TestCase):
    """THE CONTROL. No `xo/second/verdict.json` ⇒ the only grade there is."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        fx.plant_simple(self.tmp, MID, stage="verify", issue=7, title="Once")
        _plant_xo(self.tmp, MID, {"status": "finished", "score": "medium",
                                  "headline": "the state's own sentence"})
        _plant_verdict(self.tmp, MID, {
            "score": "medium", "derivation": FIRST_LINE,
            "counts": {"met": 29, "gap": 1, "untested": 4},
            "criteria": [], "summary": "only look"})

    def _card(self):
        return [c for c in LocalAdapter(self.tmp).board()["missions"]
                if c["id"] == MID][0]

    def test_the_only_grade_is_unchanged(self):
        self.assertEqual("medium", self._card()["numberOne"]["score"])

    def test_the_states_own_headline_still_wins_when_they_agree(self):
        self.assertEqual("the state's own sentence",
                         self._card()["numberOne"]["headline"])


if __name__ == "__main__":
    unittest.main()

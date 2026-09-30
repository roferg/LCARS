"""S214 fix round 1, D1 — THE CARD'S SCORE WORD IS THE RECORDED ONE.

Measured on the captain's own disk, across all seven scored missions in
`groutwork-capstone`: six agreed, and one did not. Mission …003 carried
`state.numberOne.score = "high"` while its own `xo/verdict.json` recorded
`"low"` — so the board drew `◈ NUMBER ONE · HIGH` in reassuring teal directly
above that mission's own headline, *"the build does not do what the PRD itself
asks for … What you set out to get is not there yet."*

WHAT ACTUALLY WENT WRONG THERE. Nothing re-derived the word from a ratio. That
mission was looked at TWICE — the first look scored it high, the second scored
it low — and the second look's `state.json` write was later reverted to the
first look's block by a writer holding a stale copy of the file. The ledger,
`xo/verdict.json`, was never reverted: it still says low, with the counts and
the gap that make it low.

SO THE STATE BLOCK IS A COPY, AND COPIES GO STALE. `xo-score.py` is the
producer: it decides the score and writes it, with the sentence it derives in
the same breath, into `xo/verdict.json`. That file is THE RECORD. The card
reads the record.

WHEN THE COPY AND THE RECORD DISAGREE, THE WHOLE COPY IS STALE — not just its
score. A block that reverted reverted entire, so the `headline` and `meaning`
sitting beside a stale score are the stale look's sentences too, and they come
off the record as well. When the two agree there is nothing to choose between
and S213's precedence stands exactly as it was.

NOTHING HERE COUNTS ANYTHING. The one thing this must never do is read the
ledger's `counts` and work a score out of them — that is the second opinion
whose existence is the defect.

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

MID = "lcars-20260917-003-fea3"

# Mission …003's own words, off the captain's disk.
LOW_LINE = ("the build does not do what the PRD itself asks for — the TILES "
            "section text and Import button are hidden behind a black box. "
            "What you set out to get is not there yet.")
LOW_MEANING = "There is a stated criterion the build does not meet"
HIGH_LINE = "everything you asked for is in the build, and I have a picture of each one."


def _plant_xo(root, mid, block):
    path = os.path.join(fx.mission_dir(root, mid), "state.json")
    with open(path) as fh:
        lines = fh.read().splitlines(True)
    lines.insert(1, '  "numberOne": %s,\n' % json.dumps(block))
    with open(path, "w") as fh:
        fh.writelines(lines)
    return path


def _plant_verdict(root, mid, doc):
    xodir = os.path.join(fx.mission_dir(root, mid), "xo")
    os.makedirs(xodir, exist_ok=True)
    path = os.path.join(xodir, "verdict.json")
    with open(path, "w") as fh:
        json.dump(doc, fh)
    return path


class TheRecordedScoreWins(unittest.TestCase):
    """The reverted-block case, reproduced from the captain's mission …003."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        fx.plant_simple(self.tmp, MID, stage="verify", issue=3,
                        title="Editor shell UI audit")
        # The STALE COPY — the first look's block, put back after the second.
        _plant_xo(self.tmp, MID, {
            "since": "2026-09-17T03:23:43Z", "status": "finished",
            "score": "high", "headline": HIGH_LINE,
            "evaluatedAt": "2026-09-17T03:23:43Z",
            "lastAction": "looked 20:23"})
        # THE RECORD — the second look's ledger, which was never reverted.
        # Its counts would ratio to "high" (5 of 6 met); its recorded score
        # is "low", and the recorded score is the only one that may be read.
        _plant_verdict(self.tmp, MID, {
            "score": "low", "workerScore": "low", "scoreDisagreed": False,
            "derivation": LOW_LINE, "scoreMeaning": LOW_MEANING,
            "counts": {"met": 5, "gap": 1, "untested": 0,
                       "contradictions": 1},
            "criteria": [], "gaps": [], "summary": "…"})

    def _card(self, root=None):
        cards = [c for c in LocalAdapter(root or self.tmp).board()["missions"]
                 if c["id"] == MID]
        self.assertTrue(cards, "the mission is not on the board at all")
        return cards[0]

    def test_the_card_shows_the_recorded_low_not_the_stale_high(self):
        self.assertEqual("low", self._card()["numberOne"]["score"])

    def test_a_ledger_that_would_ratio_to_high_still_renders_its_recorded_low(self):
        """The captain's explicit pin. 5 of 6 met is a ratio that any
        arithmetic would call high; the ledger recorded low, so the card says
        low. If this ever goes green while the counts are being read, the
        second opinion is back."""
        card = self._card()
        self.assertEqual("low", card["numberOne"]["score"])
        self.assertNotEqual("high", card["numberOne"]["score"])

    def test_the_stale_headline_does_not_survive_beside_the_recorded_score(self):
        """A block that reverted reverted entire: the sentence beside the
        stale word is the stale look's sentence, and the captain would read a
        LOW score explained by 'everything you asked for is in the build'."""
        xo = self._card()["numberOne"]
        self.assertEqual(LOW_LINE, xo["headline"])
        self.assertEqual(LOW_MEANING, xo["meaning"])

    def test_the_detail_view_says_the_same_word_as_the_card(self):
        detail = LocalAdapter(self.tmp).mission(MID)
        self.assertEqual("low", detail["numberOne"]["score"])


class TheCopyIsLeftAloneWhenItAgrees(unittest.TestCase):
    """Six of the captain's seven agreed. Nothing about them may change."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        fx.plant_simple(self.tmp, MID, stage="verify", issue=3, title="Agreeing")
        _plant_xo(self.tmp, MID, {"status": "finished", "score": "high",
                                  "headline": "the state's own sentence"})
        _plant_verdict(self.tmp, MID, {
            "score": "high", "derivation": HIGH_LINE,
            "criteria": [], "gaps": [], "summary": "…"})

    def test_the_score_is_unchanged(self):
        card = [c for c in LocalAdapter(self.tmp).board()["missions"]
                if c["id"] == MID][0]
        self.assertEqual("high", card["numberOne"]["score"])

    def test_the_states_own_headline_still_wins_when_they_agree(self):
        """S213's precedence, untouched. There is no staleness to detect."""
        card = [c for c in LocalAdapter(self.tmp).board()["missions"]
                if c["id"] == MID][0]
        self.assertEqual("the state's own sentence", card["numberOne"]["headline"])


class WithNoRecordNothingIsInvented(unittest.TestCase):

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        fx.plant_simple(self.tmp, MID, stage="verify", issue=3, title="No ledger")

    def _card(self):
        return [c for c in LocalAdapter(self.tmp).board()["missions"]
                if c["id"] == MID][0]

    def test_no_verdict_on_disk_leaves_the_recorded_block_exactly_as_it_is(self):
        _plant_xo(self.tmp, MID, {"status": "finished", "score": "high"})
        self.assertEqual("high", self._card()["numberOne"]["score"])

    def test_an_unreadable_verdict_changes_nothing(self):
        _plant_xo(self.tmp, MID, {"status": "finished", "score": "high"})
        xodir = os.path.join(fx.mission_dir(self.tmp, MID), "xo")
        os.makedirs(xodir, exist_ok=True)
        with open(os.path.join(xodir, "verdict.json"), "w") as fh:
            fh.write("{not json at all")
        self.assertEqual("high", self._card()["numberOne"]["score"])

    def test_a_verdict_with_no_score_in_it_changes_nothing(self):
        _plant_xo(self.tmp, MID, {"status": "finished", "score": "high"})
        _plant_verdict(self.tmp, MID, {"criteria": [], "gaps": [],
                                       "summary": "…"})
        self.assertEqual("high", self._card()["numberOne"]["score"])

    def test_an_opted_out_mission_gets_no_score_from_an_old_ledger(self):
        """`lcars xo off <id>` writes a block carrying nothing but `optOut`,
        and board.xo_block answers None for it. A ledger on disk is a fact
        about a look that happened; it does not put Number One back on a card
        the captain took it off."""
        _plant_xo(self.tmp, MID, {"optOut": True})
        _plant_verdict(self.tmp, MID, {"score": "low", "derivation": LOW_LINE,
                                       "criteria": [], "gaps": [],
                                       "summary": "…"})
        self.assertNotIn("numberOne", self._card())


class TheCaptainsSevenMissions(unittest.TestCase):
    """The real data, reduced to the two files that decide this and copied out
    of `groutwork-capstone` byte-for-byte on the fields that matter. Every one
    of the seven must render the score its own ledger recorded — …003
    included, which is the one that did not."""

    FIXTURES = os.path.join(HERE, "fixtures", "s214-real-missions.json")

    def setUp(self):
        with open(self.FIXTURES) as fh:
            self.real = json.load(fh)
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        for i, m in enumerate(self.real):
            fx.plant_simple(self.tmp, m["id"], stage="verify", issue=i + 1,
                            title=m["title"])
            _plant_xo(self.tmp, m["id"], m["stateNumberOne"])
            _plant_verdict(self.tmp, m["id"], m["verdict"])
        self.cards = {c["id"]: c
                      for c in LocalAdapter(self.tmp).board()["missions"]}

    def test_all_seven_are_on_the_board(self):
        self.assertEqual(7, len(self.real))
        self.assertEqual(sorted(m["id"] for m in self.real),
                         sorted(self.cards))

    def test_every_card_says_what_its_own_ledger_recorded(self):
        for m in self.real:
            with self.subTest(mission=m["id"]):
                self.assertEqual(m["verdict"]["score"],
                                 self.cards[m["id"]]["numberOne"]["score"])

    def test_the_one_that_disagreed_is_still_in_the_fixture(self):
        """If this fixture is ever refreshed from a repaired disk the proof
        quietly becomes a tautology. Pin the disagreement itself."""
        odd = [m for m in self.real
               if m["stateNumberOne"].get("score") != m["verdict"]["score"]]
        self.assertEqual(1, len(odd), "the 1-in-7 disagreement is gone")
        self.assertEqual("high", odd[0]["stateNumberOne"]["score"])
        self.assertEqual("low", odd[0]["verdict"]["score"])
        self.assertEqual("low", self.cards[odd[0]["id"]]["numberOne"]["score"])


if __name__ == "__main__":
    unittest.main()

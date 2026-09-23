"""S225 — THE REPORT RAIL IS THREE QUESTIONS, NOT ONE GRADE.

The scorer now splits every ledger row into three groups and answers three
different questions about them:

  person   — "Can a person do what it promises?"   GRADED. This one, and only
             this one, is the grade at the top of the report.
  drawing  — "Does it look like your drawing?"     GRADED, but it never sets
             the headline.
  contract — "Is the contract covered?"            **NOT GRADED AT ALL.** It
             is `39 of 58 answered` — a fact about how much of the ticket
             contract could be answered, not a verdict on the build.

The old rail drew ONE bar over `verdict.counts`, which is the WHOLE ledger
lumped together: 58 ticket ACs that nobody could observe dragged the same bar
as the 30 things a person actually does. A reader could not tell which of the
three questions the grey was about, and the contract's coverage looked exactly
like a grade it is not.

Four things this file pins, and each is a fault that was possible before it:

  1. THE CONTRACT GROUP RENDERS NO GRADE and nothing shaped like one. This is
     the point of the change. A `HIGH`/`MEDIUM`/`LOW` word anywhere inside the
     contract block is a failure however it got there.
  2. AN EMPTY GROUP IS NOT DRAWN. A mission with no drawing must never render
     "Does it look like your drawing? — LOW". The scorer deliberately omits
     `grade` from an empty non-headline graded group; drawing a default in its
     place would invent a verdict nobody reached.
  3. "I COULDN'T SET IT UP" IS ITS OWN STATE. It is OUR failure — a seed that
     could not reach the screen — not a doubt about his build, and it may not
     be a fifth shade of the "couldn't see it" grey. Four outcomes, four
     distinguishable segments, every drawn count written out.
  4. A VERDICT WITH NO `groups` STILL RENDERS. Missions scored before today
     exist on the captain's machine; the old rail is what they get.

A NODE DOM IS A STUB OF A BROWSER. This proves the wiring, the order and the
arithmetic. Whether it PAINTS — and what it looks like at the rail's real
~240px — is the real-Chrome drive's half, and nothing here can stand in for it.
"""
import json
import os
import shutil
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))

from tests.test_xo_surfaces import (  # noqa: E402
    TAB_HARNESS, HEADLINE, _run, _cls_of, _all_text, _flatten)

GRADE_WORDS = ("HIGH", "MEDIUM", "LOW")

# ── THE REAL NUMBERS ────────────────────────────────────────────────────────
# Lifted from a replayed verdict on disk, not invented: person 26/1/0/3 of 30,
# drawing 1/3/4/6 of 14, contract 39 of 58 covered with 22 backed by tests.
# The re-check moves person to 25/0/2/3 (medium → high) and contract's coverage
# DOWN to 17 of 58 — coverage falling while the grade rises is exactly the
# shape one lumped bar could never show.
PERSON_Q = "Can a person do what it promises?"
DRAWING_Q = "Does it look like your drawing?"
CONTRACT_Q = "Is the contract covered?"


def group(kind, q, aside, total, w, d, cs, cu, **extra):
    g = {"question": q, "kind": kind, "aside": aside, "total": total,
         "worked": w, "didntWork": d, "couldntSee": cs, "couldntSetUp": cu,
         "met": w, "gap": d, "untested": cs + cu,
         "ids": ["x-%d" % i for i in range(total)]}
    g.update(extra)
    return g


def groups_first():
    return {
        "person": group("graded", PERSON_Q,
                        "This is the grade at the top of this report.",
                        30, 26, 1, 0, 3, grade="medium", rule="medium-open",
                        isHeadline=True),
        "drawing": group("graded", DRAWING_Q,
                         "A fault here is real, but it rarely stops anyone "
                         "using the thing, so it does not set the grade.",
                         14, 1, 3, 4, 6, grade="medium", rule="medium-open"),
        "contract": group("coverage", CONTRACT_Q,
                          "This is not a grade. It is how much of the ticket "
                          "contract I could answer at all.",
                          58, 39, 0, 13, 6,
                          covered=39, uncovered=19, backedByTests=22),
    }


def groups_second():
    return {
        "person": group("graded", PERSON_Q,
                        "This is the grade at the top of this report.",
                        30, 25, 0, 2, 3, grade="high", rule="high-clean",
                        isHeadline=True),
        "drawing": group("graded", DRAWING_Q, "It does not set the grade.",
                         14, 8, 0, 0, 6, grade="high", rule="high-clean"),
        "contract": group("coverage", CONTRACT_Q,
                          "This is not a grade.", 58, 17, 0, 35, 6,
                          covered=17, uncovered=41, backedByTests=0),
    }


MY_CHECKING_NOTE = ("These are gaps in my checking, not a fault in your "
                    "build. They are mine to fix — nothing here is counted "
                    "against you.")


def my_checking():
    return {
        "note": MY_CHECKING_NOTE,
        "couldntSee": [
            {"id": "t-001-ac1", "group": "contract",
             "name": "The Kpi interface exposes optional previousValue…",
             "why": "your tests ran, but none I could see is named for this",
             "defeatedBy": "unobservable"}],
        "couldntSetUp": [
            {"id": "prd-5", "group": "person",
             "name": "Refresh-all lives in an amber warning box…",
             "why": "every KPI in the loaded snapshot is manual, so the "
                    "box's populated state cannot be reached with this seed.",
             "defeatedBy": "unreachable"}],
        "total": 2,
    }


JOURNAL = [{"action": "rescored", "at": "2026-09-21T07:37:34Z"},
           {"action": "scored", "at": "2026-09-21T05:15:38Z"}]


class GroupBase(unittest.TestCase):

    def setUp(self):
        if shutil.which("node") is None:
            self.skipTest("node not available")

    def look(self, second=False, **over):
        """A mission Number One has looked at — once, or twice."""
        v1 = {"score": "medium", "scoreGroup": "person",
              "derivation": HEADLINE,
              "scoreMeaning": "the first look's sentence",
              "counts": {"met": 66, "gap": 4, "untested": 32},
              "groups": groups_first(), "myChecking": my_checking(),
              "criteria": [], "gaps": [], "alsoChecked": []}
        v1.update(over.pop("verdict", {}))
        report = {"score": "medium", "status": "finished", "engine": "copilot",
                  "verdict": v1, "journal": JOURNAL, "logs": []}
        if second:
            v2 = {"score": "high", "scoreGroup": "person",
                  "derivation": "the re-check's own sentence.",
                  "scoreMeaning": "the point of it worked this time",
                  "counts": {"met": 50, "gap": 0, "untested": 52},
                  "groups": groups_second(), "myChecking": my_checking(),
                  "criteria": [], "gaps": [], "alsoChecked": []}
            v2.update(over.pop("verdict2", {}))
            report["verdict2"] = v2
            report["score2"] = "high"
        report.update(over.pop("report", {}))
        mi = {"id": "lcars-20260920-001", "issue": 9, "stage": "verify",
              "title": "the MBR builder",
              "numberOne": {"status": "finished", "engine": "copilot",
                            "score": report.get("score2") or report["score"],
                            "headline": HEADLINE, "report": report}}
        return _run(TAB_HARNESS, mi, json.dumps({"columns": {}}))

    # helpers -----------------------------------------------------------
    def blocks(self, out):
        return _cls_of(out["pane"], " xo-group ")

    def block(self, out, which):
        hit = [b for b in self.blocks(out)
               if ("xo-group-" + which) in (b.get("cls") or "")]
        self.assertEqual(1, len(hit), "no single %s block" % which)
        return hit[0]


class S225_ThreeQuestionsNotOneGrade(GroupBase):

    def test_one_block_per_group_in_the_scorers_own_order(self):
        out = self.look()
        got = [b["cls"] for b in self.blocks(out)]
        self.assertEqual(3, len(got), got)
        self.assertIn("xo-group-person", got[0])
        self.assertIn("xo-group-drawing", got[1])
        self.assertIn("xo-group-contract", got[2])

    def test_every_group_carries_its_own_question(self):
        out = self.look()
        self.assertIn(PERSON_Q, _all_text(self.block(out, "person")))
        self.assertIn(DRAWING_Q, _all_text(self.block(out, "drawing")))
        self.assertIn(CONTRACT_Q, _all_text(self.block(out, "contract")))

    def test_the_headline_pill_is_the_person_grade_and_one_word(self):
        out = self.look()
        chips = _cls_of(out["pane"], " xo-grade-chip ")
        self.assertEqual(1, len(chips), "the headline is not one chip")
        self.assertEqual("MEDIUM", chips[0]["text"].strip())
        self.assertIn("s-medium", chips[0]["cls"])

    def test_the_graded_groups_show_their_own_grade(self):
        out = self.look()
        self.assertIn("MEDIUM", _all_text(self.block(out, "person")))
        self.assertIn("MEDIUM", _all_text(self.block(out, "drawing")))

    # ── 1. THE CONTRACT IS NOT A GRADE ─────────────────────────────────
    def test_the_contract_block_renders_no_grade_word_at_all(self):
        out = self.look()
        text = _all_text(self.block(out, "contract"))
        for w in GRADE_WORDS:
            self.assertNotIn(w, text,
                             "the contract block said %r — it has no grade" % w)

    def test_the_contract_block_carries_no_grade_shaped_node(self):
        out = self.look()
        for n in _flatten(self.block(out, "contract")):
            cls = " " + (n.get("cls") or "") + " "
            self.assertNotIn(" xo-group-grade ", cls)
            self.assertNotIn(" xo-grade-chip ", cls)

    def test_the_contract_says_how_much_was_answered(self):
        out = self.look()
        text = _all_text(self.block(out, "contract"))
        self.assertIn("39 of 58", text)
        self.assertIn("22", text, "backed by your tests is not on screen")

    # ── 2. AN EMPTY GROUP IS NOT DRAWN ─────────────────────────────────
    def test_a_group_with_nothing_in_it_is_skipped_entirely(self):
        g = groups_first()
        g["drawing"] = group("graded", DRAWING_Q, "no drawing", 0, 0, 0, 0, 0)
        out = self.look(verdict={"groups": g})
        got = [b["cls"] for b in self.blocks(out)]
        self.assertEqual(2, len(got), got)
        self.assertNotIn(DRAWING_Q, _all_text(out["pane"]))

    def test_a_graded_group_with_no_recorded_grade_invents_none(self):
        g = groups_first()
        g["drawing"].pop("grade")
        g["drawing"].pop("rule")
        out = self.look(verdict={"groups": g})
        blk = self.block(out, "drawing")
        self.assertFalse(_cls_of(blk, " xo-group-grade "),
                         "a grade was drawn for a group that records none")
        self.assertIn(DRAWING_Q, _all_text(blk))

    # ── 3. FOUR OUTCOMES, FOUR STATES ──────────────────────────────────
    def test_couldnt_set_it_up_is_its_own_segment_not_a_shade_of_grey(self):
        out = self.look()
        person = self.block(out, "person")
        segs = _cls_of(person, " xo-seg ")
        kinds = set()
        for s in segs:
            for k in ("xo-seg-w", "xo-seg-d", "xo-seg-c", "xo-seg-u"):
                if k in s["cls"]:
                    kinds.add(k)
        # person is 26 worked / 1 didn't / 0 couldn't-see / 3 couldn't-set-up:
        # three drawn segments, and the set-up one is NOT the couldn't-see one.
        self.assertIn("xo-seg-w", kinds)
        self.assertIn("xo-seg-d", kinds)
        self.assertIn("xo-seg-u", kinds)
        self.assertNotIn("xo-seg-c", kinds, "a zero segment was drawn")

    def test_every_drawn_count_is_written_out_in_words(self):
        out = self.look()
        text = _all_text(self.block(out, "person"))
        self.assertIn("26", text)
        self.assertIn("worked", text)
        self.assertIn("1", text)
        self.assertIn("didn't work", text)
        self.assertIn("3", text)
        self.assertIn("couldn't set up", text)
        # 0 couldn't-see is not drawn, so it is not claimed either
        self.assertNotIn("couldn't see", text)

    def test_a_first_look_draws_one_bar_per_group_and_claims_no_delta(self):
        out = self.look()
        for which in ("person", "drawing", "contract"):
            self.assertEqual(1, len(_cls_of(self.block(out, which), " xo-bar ")),
                             which)
        self.assertFalse(_cls_of(out["pane"], " xo-count-d "),
                         "a delta was claimed off one look")

    def test_a_re_check_draws_both_looks_per_group_on_one_scale(self):
        out = self.look(second=True)
        for which in ("person", "drawing", "contract"):
            bars = _cls_of(self.block(out, which), " xo-bar ")
            self.assertEqual(2, len(bars), which)
            self.assertIn("xo-bar-was", bars[0]["cls"])
            self.assertNotIn("xo-bar-was", bars[1]["cls"])
        # person: 26 of 30 worked then, 25 of 30 now — same denominator, so
        # the widths are comparable as drawn.
        person = self.block(out, "person")
        segs = [s for s in _cls_of(person, " xo-seg ") if "xo-seg-w" in s["cls"]]
        self.assertEqual(2, len(segs))
        self.assertAlmostEqual(26 / 30.0 * 100,
                               float(segs[0]["style"]["width"].rstrip("%")), 1)
        self.assertAlmostEqual(25 / 30.0 * 100,
                               float(segs[1]["style"]["width"].rstrip("%")), 1)

    def test_the_re_check_grade_is_the_one_on_the_headline(self):
        out = self.look(second=True)
        chips = _cls_of(out["pane"], " xo-grade-chip ")
        self.assertEqual("HIGH", chips[0]["text"].strip())
        self.assertIn("HIGH", _all_text(self.block(out, "person")))

    def test_coverage_falling_while_the_grade_rises_is_both_on_screen(self):
        out = self.look(second=True)
        self.assertIn("17 of 58", _all_text(self.block(out, "contract")))

    # ── 4. MY CHECKING IS MINE, NOT A FAULT IN HIS BUILD ───────────────
    def test_what_i_could_not_check_is_surfaced_as_mine_to_fix(self):
        out = self.look()
        mine = _cls_of(out["pane"], " xo-mine ")
        self.assertEqual(1, len(mine), "myChecking never reached the screen")
        text = _all_text(mine[0])
        self.assertIn(MY_CHECKING_NOTE, text)
        self.assertIn("Refresh-all lives in an amber warning box", text)

    def test_nothing_is_said_about_my_checking_when_there_is_none(self):
        out = self.look(verdict={"myChecking": None})
        self.assertFalse(_cls_of(out["pane"], " xo-mine "))


class S225_TheOldShapeStillRenders(GroupBase):
    """Missions scored before today have no `groups` at all. They keep the
    rail they were drawn with — degrade, never crash, and never a blank pane.
    """

    def test_a_verdict_with_no_groups_draws_the_old_single_bar(self):
        out = self.look(verdict={"groups": None, "myChecking": None})
        self.assertFalse(self.blocks(out), "a group block was invented")
        self.assertEqual(1, len(_cls_of(out["pane"], " xo-bar ")))
        self.assertEqual(3, len(_cls_of(out["pane"], " xo-legend-row ")))
        self.assertIn("102 things you asked for", _all_text(out["pane"]))

    def test_a_malformed_groups_value_does_not_take_the_pane_down(self):
        out = self.look(verdict={"groups": "not an object"})
        self.assertTrue(_cls_of(out["pane"], " xo-rail "))
        self.assertEqual(1, len(_cls_of(out["pane"], " xo-grade-chip ")))

    def test_a_group_missing_every_count_is_skipped_not_crashed(self):
        g = groups_first()
        g["drawing"] = {"question": DRAWING_Q, "kind": "graded"}
        out = self.look(verdict={"groups": g})
        self.assertEqual(2, len(self.blocks(out)))


if __name__ == "__main__":
    unittest.main()

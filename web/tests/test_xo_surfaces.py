"""S213 GROUP C — what the captain actually SEES. C1, C2, C3 and C8.

Three surfaces, three faults, all measured on his real board:

  **C1 — the card was a transcript.** It carried Number One's entire 150-word
  verdict, ran several screens tall, and buried the cost pills, the difficulty
  pills and both buttons beneath it. It becomes a SIGNAL: one pill carrying the
  SCORE, one line of verdict, and an explicit way in.

  **C2 — the tab led with the wrong thing.** It opened on "Also checked, fine —
  no gaps found on this look" above a MEDIUM score whose real finding was that
  nothing could be tested at all. The verdict LEADS; `alsoChecked` goes LAST
  and is LABELLED as reassurance about things nobody asked about.

  **C3 — every criterion says HOW it was settled.** `I could not check this`
  with no evidence must read differently from `met — a picture` and from
  `met — your tests`. The kind is RECORDED by whatever settled the criterion
  (xo-score.py, S211); nothing here re-derives it by reading a note.

  **C8 — NOTHING shows a verdict that contradicts the score.** This is the
  regression test for the fault that made the session necessary, and it is a
  real assertion, not a comment: the one line on the card and the one sentence
  the tab leads with are both the ledger's own `derivation`, the sentence
  written in the same breath as the score, off the same ledger, by the same
  rule in the same function. Two things said by one piece of code cannot
  disagree — so the test pins that they ARE that one thing, and that the
  reassurance text can never occupy either position.

A NODE DOM IS A STUB OF A BROWSER. These prove the wiring and the ORDER; a real
browser is the other half and the tester's job.
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

CARD_HARNESS = os.path.join(HERE, "board_card_harness.js")
TAB_HARNESS = os.path.join(HERE, "board_xo_tab_harness.js")
BOARD_JS = os.path.join(os.path.dirname(HERE), "static", "board.js")

LONG = ("Captain, this build is a code-only engine change — two pure "
        "coordinate functions, a factory method, a Camera type field, and "
        "their unit tests — none of which shows up on a screen, and the PRD "
        "deliberately leaves the editor/example wiring that would exercise "
        "them out of scope. The example game does render fine, so the engine "
        "compiles and runs, but that proves nothing about the new methods. "
        "The decisive evidence would have been your vitest suite, and it "
        "never ran: vitest: command not found, exit 127 before a single test "
        "executed — a broken runner invocation, not a failing test. So every "
        "criterion is honestly untested.")
HEADLINE = ("I could not check the main thing you asked for — your test "
            "suite never ran, so nothing about the new methods was actually "
            "verified.")
# 2,673 characters, as planted by the tester on a real board.
RAMBLE = (("Captain, I want to walk you through everything I did here because "
           "there is rather a lot of it and none of it is simple. ") * 12
          + "None of it could be tested.")
REASSURANCE = ("The header, the tile readout and the map canvas all paint as "
               "before. Not part of what you asked for.")


def _run(harness, payload, *extra):
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as fh:
        json.dump(payload, fh)
        spec = fh.name
    try:
        proc = subprocess.run(["node", harness, spec] + list(extra),
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if proc.returncode != 0:
            raise AssertionError("harness failed: %s"
                                 % proc.stderr.decode("utf-8", "replace"))
        return json.loads(proc.stdout.decode("utf-8"))
    finally:
        os.unlink(spec)


def _flatten(node, out=None):
    out = [] if out is None else out
    if not node:
        return out
    out.append(node)
    for kid in node.get("children") or []:
        _flatten(kid, out)
    return out


def _all_text(node):
    return " ".join(n.get("text") or "" for n in _flatten(node))


def _cls_of(node, needle):
    return [n for n in _flatten(node)
            if needle in (" " + (n.get("cls") or "") + " ")]


class CardBase(unittest.TestCase):

    def setUp(self):
        if shutil.which("node") is None:
            self.skipTest("node not available")

    def card(self, **over):
        m = {
            "id": "lcars-20260917-401", "issue": 8, "stage": "verify",
            "title": "Add worldToScreen / screenToWorld to the engine camera",
            "numberOne": {"status": "engaged", "engine": "copilot",
                          "score": "medium", "note": LONG,
                          "headline": HEADLINE},
            "pills": {"cost": {"label": "$0.42–$1.44", "level": "low"},
                      "reasoning": {"label": "REASON ●○○ LOW", "level": "low"},
                      "implementation": {"label": "IMPL ●○○ LOW",
                                         "level": "low"}},
        }
        m["numberOne"].update(over.pop("numberOne", {}))
        m.update(over)
        return _run(CARD_HARNESS, m)


class C1_TheCardIsASignalNotATranscript(CardBase):

    def test_the_transcript_is_not_on_the_card_at_all(self):
        card = self.card()
        self.assertNotIn(LONG[:60], _all_text(card))

    def test_one_line_of_verdict_in_its_own_voice_is(self):
        card = self.card()
        lines = _cls_of(card, " xo-verdict-line ")
        self.assertEqual(1, len(lines))
        self.assertEqual(HEADLINE, _all_text(lines[0]).strip())

    def test_the_score_rides_one_pill_that_names_number_one(self):
        card = self.card()
        pills = _cls_of(card, " xo-score ")
        self.assertEqual(1, len(pills))
        self.assertEqual("◈ NUMBER ONE · MEDIUM", pills[0]["text"])

    def test_the_old_engaged_pill_no_longer_doubles_up_beside_it(self):
        text = _all_text(self.card())
        self.assertNotIn("◈ NUMBER ONE · ENGAGED", text)
        self.assertNotIn("INTENT MATCH · MEDIUM", text)

    def test_there_is_an_explicit_way_into_the_full_report(self):
        card = self.card()
        reads = [n for n in _flatten(card)
                 if "Read the full report" in (n.get("text") or "")]
        self.assertEqual(1, len(reads))
        self.assertIn("xo-read-report", reads[0]["cls"])

    # ── FIX ROUND 1, D1: AT ANY LENGTH ──────────────────────────────────
    # The tester planted a verdict of 2,673 characters — a rambling worker
    # `why`, the exact shape this session guards against — and the card drew
    # all of them: 91 wrapped lines, 1,752 px tall in a 200 px column, every
    # other mission pushed off the screen. Nothing truncated at ANY length.
    # C1 is a promise about every verdict, not about short ones.

    def test_a_punishing_verdict_is_still_one_line_on_the_card(self):
        card = self.card(numberOne={"headline": RAMBLE})
        line = _cls_of(card, " xo-verdict-line ")
        self.assertEqual(1, len(line))
        shown = _all_text(line[0]).strip()
        self.assertLess(len(shown), 220,
                        "the card is carrying a transcript again")
        self.assertTrue(shown.endswith("…"), shown[-40:])
        self.assertTrue(RAMBLE.startswith(shown[:60]),
                        "the line is not the start of the recorded sentence")

    def test_and_the_rest_of_it_is_not_hiding_on_the_card_somewhere(self):
        card = self.card(numberOne={"headline": RAMBLE})
        self.assertNotIn(RAMBLE[-80:], _all_text(card))

    def test_the_way_into_the_whole_thing_is_still_right_there(self):
        card = self.card(numberOne={"headline": RAMBLE})
        reads = [n for n in _flatten(card)
                 if "Read the full report" in (n.get("text") or "")]
        self.assertEqual(1, len(reads))

    def test_a_normal_length_verdict_is_not_cut_at_all(self):
        card = self.card()
        line = _cls_of(card, " xo-verdict-line ")[0]
        self.assertEqual(HEADLINE, _all_text(line).strip())

    def test_the_cost_and_difficulty_pills_are_still_on_the_card(self):
        text = _all_text(self.card())
        self.assertIn("$0.42–$1.44", text)
        self.assertIn("REASON ●○○ LOW", text)
        self.assertIn("IMPL ●○○ LOW", text)

    def test_a_mission_with_no_score_yet_still_says_who_has_the_conn(self):
        card = self.card(numberOne={"score": None, "headline": None,
                                    "note": None})
        text = _all_text(card)
        self.assertIn("◈ NUMBER ONE · ENGAGED", text)
        self.assertIn("Number One has the conn", text)

    def test_a_short_escalation_note_is_still_shown(self):
        card = self.card(numberOne={"status": "escalated", "score": None,
                                    "headline": None,
                                    "note": "a bug it filed got stuck"})
        self.assertIn("a bug it filed got stuck", _all_text(card))

    def test_an_escalation_note_survives_even_beside_an_older_score(self):
        """FOUND ON THE REAL BOARD, not by a unit test. A mission Number One
        scored LOW and then escalated carries BOTH — and the note is the news:
        it is what it needs him to do. `xo_finish` writes the transcript into
        `note` only on an ENGAGED mission, so ENGAGED is the one status whose
        note the card hides; every other status's note is a short sentence
        somebody wrote for him."""
        card = self.card(numberOne={"status": "escalated", "score": "low",
                                    "headline": None,
                                    "note": "a bug it filed got stuck before "
                                            "it could be fixed"})
        text = _all_text(card)
        self.assertIn("a bug it filed got stuck", text)
        self.assertIn("◈ NUMBER ONE · LOW", text)

    def test_but_an_engaged_missions_transcript_is_still_hidden(self):
        card = self.card(numberOne={"status": "engaged", "score": "medium",
                                    "note": LONG, "headline": HEADLINE})
        self.assertNotIn(LONG[:60], _all_text(card))

    def test_a_card_with_no_number_one_at_all_is_unchanged(self):
        plain = _run(CARD_HARNESS,
                     {"id": "x", "issue": 1, "stage": "verify", "title": "t"})
        self.assertNotIn("NUMBER ONE", _all_text(plain))


class D4_TheScoreWordCannotAssertAFlowNobodySaw(CardBase):
    """FIX ROUND 1, D4 — measured on the captain's own board.

    A mission whose verdict was "nothing could be tested — the calculator never
    rendered", every criterion untested, wore MEDIUM; hovering MEDIUM said, in
    these words, "The primary flow works end to end; some criteria gap or could
    not be tested, none blocking the stated goal". The primary flow was never
    seen. It is the fault the whole session exists to kill, relocated from the
    alsoChecked line into a tooltip — and it was the NORMAL path, because an
    all-untested ledger is scored MEDIUM by design.

    The cure is not better copy for MEDIUM. It is that the sentence is decided
    where the score is, off the same ledger, and merely READ here."""

    def _title(self, card, cls):
        hits = _cls_of(card, cls)
        self.assertTrue(hits, "no element with %r on the card" % cls)
        return hits[0].get("title") or ""

    def test_the_recorded_meaning_is_what_the_pill_says(self):
        said = ("I could not check anything on your list, so nothing here is "
                "vouched for")
        card = self.card(numberOne={"meaning": said})
        self.assertEqual(said, self._title(card, " xo-score "))

    def test_and_it_never_claims_a_flow_nobody_saw(self):
        card = self.card(numberOne={
            "meaning": "I could not check anything on your list, so nothing "
                       "here is vouched for"})
        self.assertNotIn("primary flow works", self._title(card, " xo-score "))

    def test_a_mission_with_nothing_recorded_asserts_nothing(self):
        """FIX ROUND 3, D4-RESIDUAL — and this test is the round-1 test
        INVERTED, on purpose.

        Round 1 kept the three fixed sentences as a last resort and pinned
        them here, reasoning that a blank tooltip would be its own defect. It
        is not. A tooltip that says nothing tells the captain nothing; MEDIUM's
        fixed sentence told him his primary flow worked on a build nobody could
        check, and the tester found it still doing exactly that on a mission
        scored before round 1 — which is every mission on his real disk.

        Where a ledger exists the sentence is DERIVED FROM IT, by the adapter,
        off the recorded counts (see test_xo_meaning_migration.py). Where there
        is no ledger at all — a REMOTE card whose score came off a GitHub
        label, a verdict that never got written — the honest answer is silence.
        A surface must never assert what no record supports."""
        card = self.card(numberOne={"meaning": None})
        self.assertEqual("", self._title(card, " xo-score "))

    def test_the_false_sentence_is_not_in_the_shipping_board_at_all(self):
        """Not "no path reaches it" — it is not THERE to be reached."""
        with open(BOARD_JS, encoding="utf-8") as fh:
            src = fh.read()
        self.assertNotIn("primary flow works", src)
        self.assertNotIn("XO_SCORE_MEANING", src)


class TabBase(unittest.TestCase):

    def setUp(self):
        if shutil.which("node") is None:
            self.skipTest("node not available")

    def mi(self, **over):
        verdict = {
            "score": "medium",
            "derivation": HEADLINE,
            "summary": LONG,
            "counts": {"met": 2, "gap": 0, "untested": 2,
                       "contradictions": 0},
            "criteria": [
                {"id": "prd-1", "text": "worldToScreen converts correctly",
                 "status": "untested", "evidence": "none",
                 "note": "your test suite never ran", "primary": True},
                {"id": "prd-2", "text": "screenToWorld is its inverse",
                 "status": "untested", "evidence": "none",
                 "note": "your test suite never ran", "primary": True},
                {"id": "prd-3", "text": "Camera exposes the new field",
                 "status": "met", "evidence": "tests",
                 "testQuote": "✓ camera.spec.ts (4)", "note": "the suite says so"},
                {"id": "prd-4", "text": "The example game still runs",
                 "status": "met", "evidence": "picture", "shot": "shot-01",
                 "note": "I saw it render"},
                {"id": "prd-5", "text": "The toolbar rows line up",
                 "status": "gap", "evidence": "measurement", "shot": "shot-02",
                 "note": "the second row sits 9px low"},
            ],
            "gaps": [],
            "alsoChecked": [REASSURANCE],
        }
        verdict.update(over.pop("verdict", {}))
        mi = {
            "id": "lcars-20260917-401", "issue": 8, "stage": "verify",
            "title": "worldToScreen / screenToWorld",
            "numberOne": {"status": "engaged", "engine": "copilot",
                          "score": "medium", "headline": HEADLINE,
                          "report": {"score": "medium", "status": "engaged",
                                     "engine": "copilot", "verdict": verdict,
                                     "logs": [], "shotsDir": "look-1",
                                     "journal": []}},
        }
        mi["numberOne"].update(over.pop("block", {}))
        mi.update(over)
        return _run(TAB_HARNESS, mi)


class C2_TheVerdictLeadsAndReassuranceGoesLast(TabBase):

    def test_the_score_is_the_first_thing_on_the_pane(self):
        out = self.mi()
        self.assertTrue(out["paneText"],
                        "the pane rendered nothing at all")
        self.assertIn("MEDIUM", out["paneText"][0].upper())

    def test_the_one_honest_sentence_comes_before_the_full_text(self):
        text = out_texts = self.mi()["paneText"]
        joined = " ⇢ ".join(text)
        self.assertIn(HEADLINE, joined)
        self.assertLess(joined.index(HEADLINE), joined.index(LONG[:40]))
        del out_texts

    def test_also_checked_is_the_last_block_on_the_pane(self):
        out = self.mi()
        lead = out["paneText"][0]
        self.assertNotIn("Also checked", lead)
        idx = [i for i, t in enumerate(out["paneText"])
               if REASSURANCE[:40] in t]
        self.assertTrue(idx, "the reassurance is not shown at all")
        # Nothing about the verdict may come after it.
        after = " ".join(out["paneText"][idx[0] + 1:])
        self.assertNotIn(HEADLINE, after)
        self.assertNotIn(LONG[:40], after)

    def test_also_checked_is_LABELLED_as_what_it_is(self):
        out = self.mi()
        blocks = _cls_of(out["pane"], " xo-also ")
        self.assertEqual(1, len(blocks))
        label = _all_text(blocks[0])
        self.assertIn("Also checked", label)
        self.assertIn("nothing wrong found", label.lower())

    def test_a_look_with_no_also_checked_shows_no_such_block(self):
        out = self.mi(verdict={"alsoChecked": []})
        self.assertEqual([], _cls_of(out["pane"], " xo-also "))

    def test_the_number_one_tab_is_still_last_in_the_bar(self):
        out = self.mi()
        self.assertEqual("xo", out["tabs"][-1]["key"])


class C3_EveryCriterionSaysHowItWasSettled(TabBase):

    def rows(self):
        out = self.mi()
        rows = _cls_of(out["pane"], " xo-crit-row ")
        return {_all_text(r): r for r in rows}, out

    def test_there_is_a_row_per_criterion(self):
        out = self.mi()
        self.assertEqual(5, len(_cls_of(out["pane"], " xo-crit-row ")))

    def test_tests_and_a_picture_are_different_words(self):
        rows, _ = self.rows()
        tested = [t for t in rows if "Camera exposes" in t][0]
        pictured = [t for t in rows if "example game still runs" in t][0]
        self.assertIn("your tests", tested)
        self.assertIn("a picture", pictured)
        self.assertNotEqual("your tests", "a picture")

    def test_a_measured_box_is_a_third_word(self):
        rows, _ = self.rows()
        measured = [t for t in rows if "toolbar rows line up" in t][0]
        self.assertIn("a measured box", measured)

    def test_an_unchecked_criterion_claims_no_evidence_at_all(self):
        rows, _ = self.rows()
        unchecked = [t for t in rows if "worldToScreen converts" in t][0]
        for word in ("a picture", "your tests", "a measured box"):
            self.assertNotIn(word, unchecked)
        # S216: the captain's own outcome word, "couldn't check".
        self.assertIn("couldn't check", unchecked.lower())

    def test_the_harness_vocabulary_never_reaches_him(self):
        # In OUR labels. The worker's own prose is quoted verbatim and this
        # board does not police the words Number One chose — it polices the
        # ones it writes itself, which is where "UNTESTED — —" used to sit.
        out = self.mi()
        for row in _cls_of(out["pane"], " xo-crit-row "):
            verdicts = _cls_of(row, " xo-crit-verdict ")
            self.assertTrue(verdicts)
            for v in verdicts:
                self.assertNotIn("untested", (v["text"] or "").lower())
        heads = _cls_of(out["pane"], " xo-crit-head ")
        self.assertNotIn("untested", _all_text(heads[0]).lower())

    def test_the_evidence_word_is_read_off_the_record_not_the_note(self):
        # Same NOTE, opposite RECORD: the word must follow the record.
        out = self.mi(verdict={"criteria": [
            {"id": "a", "text": "the one row", "status": "met",
             "evidence": "tests", "note": "I saw it in the screenshot"}]})
        row = _cls_of(out["pane"], " xo-crit-row ")[0]
        self.assertIn("your tests", _all_text(row))
        self.assertNotIn("a picture", _all_text(row))


class D4_TheTabSaysTheSameThingAsTheCard(TabBase):

    def _word_title(self, out):
        words = _cls_of(out["pane"], " xo-score-word ")
        self.assertTrue(words, "the tab has no score word at all")
        return words[0].get("title") or ""

    def test_the_tab_reads_the_ledgers_own_sentence(self):
        said = ("I could not check anything on your list, so nothing here is "
                "vouched for")
        self.assertEqual(said,
                         self._word_title(self.mi(verdict={"scoreMeaning": said})))

    def test_and_never_the_fixed_sentence_about_a_primary_flow(self):
        out = self.mi(verdict={
            "scoreMeaning": "I could not check anything on your list, so "
                            "nothing here is vouched for"})
        self.assertNotIn("primary flow works", self._word_title(out))

    def test_an_older_verdict_falls_back_to_the_line_the_card_carries(self):
        """FIX ROUND 3, D4-RESIDUAL. No `scoreMeaning` in the verdict — a
        mission scored before round 1 — so the word reads the same block field
        the CARD reads, which the adapter has already derived off this
        verdict's own counts. One sentence, both surfaces, so they cannot
        disagree about what the word means (C8)."""
        said = ("Of the 29 things on your list, 21 checked out and 8 I could "
                "not check")
        out = self.mi(block={"meaning": said})
        self.assertEqual(said, self._word_title(out))
        self.assertNotIn("primary flow works", self._word_title(out))

    def test_a_recorded_meaning_still_wins_over_that_fallback(self):
        said = "the ledger's own sentence"
        out = self.mi(verdict={"scoreMeaning": said},
                      block={"meaning": "the derived one"})
        self.assertEqual(said, self._word_title(out))

    def test_with_nothing_recorded_anywhere_the_word_asserts_nothing(self):
        self.assertEqual("", self._word_title(self.mi()))


class C8_NoSurfaceContradictsTheScore(TabBase):
    """THE REGRESSION TEST FOR THE FAULT THAT MADE THIS SESSION NECESSARY."""

    def test_the_tab_can_never_lead_with_the_reassurance(self):
        # The exact shape that produced the real defect: a MEDIUM whose real
        # finding is "nothing could be tested", with a comforting alsoChecked.
        out = self.mi(verdict={"alsoChecked": [
            "Also checked, fine — no gaps found on this look."]})
        lead = " ".join(out["paneText"][:3])
        self.assertNotIn("no gaps found", lead)
        self.assertIn(HEADLINE.split("—")[0].strip(), " ".join(out["paneText"][:4]))

    def test_the_old_no_gaps_found_sentence_is_gone_from_the_board(self):
        src = open(os.path.join(HERE, "..", "static", "board.js")).read()
        self.assertNotIn("Also checked, fine — no gaps found on this look",
                         src)

    def test_a_look_with_nothing_to_report_still_leads_with_its_verdict(self):
        out = self.mi(verdict={"criteria": [], "alsoChecked": [REASSURANCE],
                               "score": "high",
                               "derivation": "everything you asked for is in "
                                             "the build, and I have a picture "
                                             "of each one."})
        joined = " ⇢ ".join(out["paneText"])
        self.assertLess(joined.index("everything you asked for"),
                        joined.index(REASSURANCE[:30]))

    def test_the_card_line_and_the_tab_lede_are_the_same_sentence(self):
        if shutil.which("node") is None:
            self.skipTest("node not available")
        tab = self.mi()
        card = _run(CARD_HARNESS, {
            "id": "lcars-20260917-401", "issue": 8, "stage": "verify",
            "title": "worldToScreen / screenToWorld",
            "numberOne": {"status": "engaged", "engine": "copilot",
                          "score": "medium", "note": LONG,
                          "headline": HEADLINE}})
        card_line = _all_text(_cls_of(card, " xo-verdict-line ")[0]).strip()
        lede = _all_text(_cls_of(tab["pane"], " xo-lede ")[0]).strip()
        self.assertEqual(card_line, lede)

    def test_the_score_word_on_the_card_matches_the_score_on_the_tab(self):
        tab = self.mi()
        card = _run(CARD_HARNESS, {
            "id": "x", "issue": 8, "stage": "verify", "title": "t",
            "numberOne": {"status": "engaged", "score": "medium",
                          "headline": HEADLINE}})
        pill = _cls_of(card, " xo-score ")[0]["text"]
        self.assertIn("MEDIUM", pill)
        self.assertIn("MEDIUM", _all_text(_cls_of(tab["pane"],
                                                  " xo-score-word ")[0]).upper())


if __name__ == "__main__":
    unittest.main()

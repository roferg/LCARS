"""S292 — AN ESCALATION IS A DECISION, NOT A DOCUMENT.

Measured on the captain's own 2880x1626 board capture: when Mission #11
escalated, Number One's whole escalation was drawn INLINE in the kanban card —
his plain-English explanation, then the formal gate text with its (a)/(b)/(c)
options and the source citations behind them. Over a thousand characters of
11px mono in a ~260px column (about 28 characters to a line). The card filled
the entire column height, was STILL clipped at the bottom, and the three
options he was being asked to choose between were off the screen, while every
other column sat empty.

A status object was being used as a document viewer, on the one surface where
the product asks him to decide.

His words: *"That escalation UI crammed into the card is horrible. We need to
fix that so you click to see the details as part of answering the escalation."*

So three claims, and each is paired with a control that answers DIFFERENTLY:

  1. THE CARD CARRIES A SUMMARY. A long escalation is clipped on a sentence
     boundary with the truncation SAID OUT LOUD (how much is not shown), so a
     cut-off wall can never be mistaken for the whole message.
     CONTROL: a SHORT note still renders inline, verbatim, with no marker — the
     stand-down line the board has always drawn is untouched.

  2. THERE IS A WAY IN. The clipped card grows one `.xo-read-report` button —
     the idiom the verdict case already uses — at its own tab stop.
     CONTROL: a short note grows no such button.

  3. THE FULL ESCALATION IS ON THE TAB, WHOLE. Nothing the card used to show
     may be lost: this is a MOVE, not a trim. The (a)/(b)/(c) options and the
     citation quote are all on the ◈ Number One tab, at real width.
     CONTROL: an ENGAGED mission's note is a worker TRANSCRIPT, not news, and
     gets no escalation block anywhere.

  4. AND HE CAN READ IT WHILE ANSWERING. The respond modal — the surface that
     already posts to `/api/mission/<id>/respond` — carries the whole
     escalation beside the answer box.
     CONTROL: an ordinary gate with no Number One on it is unchanged.

A NODE DOM IS A STUB OF A BROWSER. These prove the WIRING; the picture is the
browser drive's job (and the tester's).
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
DETAIL_HARNESS = os.path.join(HERE, "board_detail_harness.js")

# The REAL escalation off the captain's board, at its real shape and length:
# Number One's own explanation, the quoted source it is grounded in, and then
# the formal decision with its three lettered options.
REAL = (
    "Two things stopped this, and the first one is yours. The design document "
    "handed over from the drawing session says a note carries a LIST of tags — "
    "\"Each note record carries an `id`, an ISO-8601 UTC `timestamp`, a `tags` "
    "array (possibly empty), and a `text` string — the four fields the mockup "
    "renders per card\" — and the picture agrees with it: 4 of the 10 cards in "
    "the mockup show two tag chips each (#wildlife + #trail, #camp + #gear, "
    "#gear + #bug, #weather + #trail). The app you have today stores exactly "
    "ONE tag per note — a single nullable field, with one `--tag` option on "
    "`tricorder add` — so those four cards cannot be produced by the data that "
    "exists. DECISION NEEDED — reply (a), (b) or (c). (a) BUILD IT ANYWAY. "
    "(b) CUT the parts that depend on it. (c) CHANGE THE REPO'S DATA FIRST, "
    "then build it as drawn."
)

# The control: the short note this board has drawn inline since S201 and must
# go on drawing inline, unchanged.
SHORT = "a bug it filed got stuck before it could be fixed"


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


def _squash(text):
    return " ".join(str(text).split())


class EscalationBase(unittest.TestCase):

    def setUp(self):
        if shutil.which("node") is None:
            self.skipTest("node not available")

    def card(self, **over):
        m = {
            "id": "lcars-20261016-011", "issue": 11, "stage": "validate",
            "title": "Draw the notes board the mockup shows",
            "awaiting": True,
            "numberOne": {"status": "escalated", "engine": "copilot",
                          "note": REAL},
            "pills": {"cost": {"label": "$0.42–$1.44", "level": "low"},
                      "reasoning": {"label": "REASON ●○○ LOW", "level": "low"},
                      "implementation": {"label": "IMPL ●○○ LOW",
                                         "level": "low"}},
        }
        m["numberOne"].update(over.pop("numberOne", {}))
        m.update(over)
        return _run(CARD_HARNESS, m)

    def mi(self, **over):
        m = {
            "id": "lcars-20261016-011", "issue": 11, "stage": "validate",
            "title": "Draw the notes board the mockup shows",
            "awaiting": True,
            "question": "DECISION NEEDED — reply (a), (b) or (c).",
            "numberOne": {"status": "escalated", "engine": "copilot",
                          "note": REAL},
        }
        m["numberOne"].update(over.pop("numberOne", {}))
        m.update(over)
        return m


class TheCardCarriesASummaryNotTheDocument(EscalationBase):

    def test_the_whole_escalation_is_not_on_the_card(self):
        text = _all_text(self.card())
        self.assertNotIn(REAL[-120:], text,
                         "the tail of the wall is still on the card")
        self.assertNotIn("(a) BUILD IT ANYWAY", text,
                         "the options he must choose between are on the card, "
                         "which is where they were off the bottom of it")

    def test_the_card_still_says_what_is_being_asked(self):
        """A summary, not a blank. He has to be able to tell, from the card
        alone, whether this one needs him right now."""
        notes = _cls_of(self.card(), " xo-note ")
        self.assertEqual(1, len(notes))
        said = _squash(notes[0]["text"])
        self.assertTrue(said, "the card says nothing about the escalation")
        self.assertIn("Two things stopped this", said)

    def test_the_summary_fits_the_column_it_is_read_in(self):
        """~260px at 11px mono is about 28 characters a line. A few lines of
        that is the budget; the capture that started this ran past a thousand
        characters and was still clipped."""
        notes = _cls_of(self.card(), " xo-note ")
        said = _squash(notes[0]["text"])
        self.assertLessEqual(len(said), 150,
                             "the card note is %d characters — still a wall"
                             % len(said))

    def test_the_cut_is_visible_and_counted(self):
        """He must never mistake a cut-off wall for the whole message, so the
        clip says so in words AND says how much is missing."""
        card = self.card()
        marks = _cls_of(card, " xo-note-cut ")
        self.assertEqual(1, len(marks), "nothing on the card admits the cut")
        said = marks[0]["text"]
        self.assertIn("clipped", said.lower())
        missing = len(_squash(REAL)) - len(_squash(
            _cls_of(card, " xo-note ")[0]["text"]).rstrip(" …"))
        self.assertIn(str(missing), said,
                      "the marker does not say how much is not shown: %r"
                      % said)

    def test_the_cut_lands_on_a_sentence(self):
        said = _squash(_cls_of(self.card(), " xo-note ")[0]["text"])
        self.assertTrue(said.endswith("…"), said)
        self.assertTrue(said.rstrip(" …").endswith("."),
                        "the clip cut a sentence in half: %r" % said)

    def test_the_cost_pill_and_the_answer_control_are_not_buried_under_it(self):
        """On the capture the wall pushed everything below it off the bottom of
        a column every other column had room to spare in."""
        text = _all_text(self.card())
        self.assertIn("$0.42–$1.44", text)
        self.assertIn("Answer ▸", text)
        self.assertIn("Draw the notes board the mockup shows", text)

    # ── CONTROL ─────────────────────────────────────────────────────────
    def test_a_short_escalation_note_is_still_drawn_whole_and_unmarked(self):
        """THE CONTROL, and it answers differently: a note that FITS is the
        board's existing behaviour and nothing about it moves. If this arm and
        the long one printed the same answer the clip would be unconditional —
        a rewrite of every stand-down line on the board."""
        card = self.card(numberOne={"note": SHORT})
        notes = _cls_of(card, " xo-note ")
        self.assertEqual(1, len(notes))
        self.assertEqual(SHORT, notes[0]["text"],
                         "a short note was altered")
        self.assertEqual([], _cls_of(card, " xo-note-cut "),
                         "a note that fits was marked as clipped")


class ThereIsAWayIntoIt(EscalationBase):

    def _reads(self, card):
        return [n for n in _flatten(card)
                if n.get("tag") == "button"
                and " xo-read-report " in (" " + (n.get("cls") or "") + " ")]

    def test_the_clipped_card_offers_one_way_in(self):
        reads = self._reads(self.card())
        self.assertEqual(1, len(reads),
                         "expected exactly one way in, got %r"
                         % [n["text"] for n in reads])
        self.assertIn("escalation", reads[0]["text"].lower(),
                      "the button does not say what it opens: %r"
                      % reads[0]["text"])

    def test_the_way_in_is_a_real_control_with_its_own_tab_stop(self):
        read = self._reads(self.card())[0]
        self.assertEqual("button", read["tag"])
        self.assertFalse(read["disabled"],
                         "the one way into the escalation is disabled")

    def test_a_scored_mission_that_escalated_still_offers_exactly_one(self):
        """FOUND ON THE REAL BOARD once before (S278): a card that grows a
        SECOND orange button opening the same tab costs him a second tab stop
        and says nothing new. A mission scored LOW and then escalated has both
        a report and an escalation, and must still end with one."""
        reads = self._reads(self.card(numberOne={"score": "low"}))
        self.assertEqual(1, len(reads),
                         "two ways into one tab: %r"
                         % [n["text"] for n in reads])
        self.assertIn("escalation", reads[0]["text"].lower())

    def test_the_button_never_promises_a_surface_that_refuses_the_note(self):
        """THE INVARIANT. A clip is a promise that the rest is one click away.
        The tab declines an ENGAGED mission's note — it is the worker
        TRANSCRIPT, which is why the card hides it on a scored card — so an
        engaged card must not be clipped either: it would grow a button onto a
        pane that says "Number One hasn't looked at this one yet". Same long
        note as the escalated arm, opposite answer, which is the control."""
        card = self.card(numberOne={"status": "engaged"})
        self.assertEqual([], self._reads(card),
                         "a button onto a pane that will not draw the note")
        self.assertEqual([], _cls_of(card, " xo-note-cut "))

    def test_a_remote_done_card_is_not_clipped_either(self):
        """The other half of the same invariant: openDetail short-circuits a
        remote done card to its GitHub issue (S278), so there is no local pane
        to put the remainder in. It keeps the whole note."""
        card = self.card(stage="done", remote=True, readOnly=True,
                         numberOne={"status": "escalated"})
        self.assertEqual([], _cls_of(card, " xo-note-cut "))
        self.assertIn("(a) BUILD IT ANYWAY", _all_text(card))

    # ── CONTROL ─────────────────────────────────────────────────────────
    def test_a_short_note_grows_no_way_in(self):
        """THE CONTROL: there is nothing hidden, so there is nothing to open,
        so the card gains no control at all. A different answer from the arm
        above — which is the whole point of having it."""
        self.assertEqual([], self._reads(self.card(numberOne={"note": SHORT})))


class TheCardNamesTheDecisionItIsAsking(EscalationBase):
    """S292 FIX ROUND 2 — MEASURED ON THE ROUND-1 CAPTURE.

    Round 1 cut the wall down to its first ~140 characters and the card came
    out reading *"Two things stopped this, and the first one is yours. …"* —
    the opening of Number One's PROSE. It is shorter, and it says nothing
    about what is being asked. Two escalations open at once would print the
    same generic sentence on both cards, so the captain still has to open each
    one to find out which decision is which.

    The sentence that names the decision was already in the payload:
    BUG-027's `gate.humanSummary`, which the respond modal has used as its
    HEADLINE since it was introduced, and which the card used nowhere. So the
    card prefers it — and ONLY where a clip was already being made, so every
    invariant round 1 established still holds.

    Each claim is paired with a control that answers DIFFERENTLY: with a
    summary, the decision; without one, the round-1 prose excerpt, unchanged.
    """

    # The purpose-written one-liner the harness puts in pending.json for the
    # very escalation REAL is the prose of.
    SUMMARY = ("The drawing wants a LIST of tags per note; the app stores "
               "one. Build it anyway, cut the parts that need it, or change "
               "the data first?")
    # A SECOND, different decision — the whole point is that two cards read
    # differently.
    OTHER = ("The regression gate says #47 re-broke the tag filter test. "
             "Revert #47, fix it forward, or ship with that test skipped?")

    def gated(self, summary=None, **over):
        over.setdefault("gate", {
            "humanSummary": self.SUMMARY if summary is None else summary,
            "escalationType": "scope"})
        return self.card(**over)

    def said(self, card):
        notes = _cls_of(card, " xo-note ")
        self.assertEqual(1, len(notes), "expected one note line on the card")
        return _squash(notes[0]["text"])

    def mark(self, card):
        marks = _cls_of(card, " xo-note-cut ")
        return _squash(marks[0]["text"]) if marks else ""

    def test_the_card_says_which_decision_this_is(self):
        said = self.said(self.gated())
        self.assertEqual(_squash(self.SUMMARY), said,
                         "the card is not showing the sentence that names the "
                         "decision: %r" % said)
        self.assertNotIn("Two things stopped this", said,
                         "the card is still leading with the prose preamble")

    def test_two_open_escalations_read_differently(self):
        """THE POINT, stated as the captain would check it. Same long prose
        note on both cards — only the decision differs — and the two cards
        must not print the same sentence. Round 1 fails this: both read
        "Two things stopped this, and the first one is yours. …"."""
        one = self.said(self.gated())
        two = self.said(self.gated(summary=self.OTHER))
        self.assertNotEqual(one, two,
                            "both escalation cards read %r — he still has to "
                            "open each one to tell them apart" % one)
        self.assertIn("LIST of tags", one)
        self.assertIn("#47", two)

    def test_the_marker_does_not_claim_a_truncation_that_did_not_happen(self):
        """The round-1 marker counts the characters cut off the END of what is
        shown. When the card shows a DIFFERENT sentence instead, nothing was
        cut off it — "52 of 818" would be a number measuring nothing. The
        marker must still say there is more and how much, without pretending
        the shown text is the head of it."""
        card = self.gated()
        mark = self.mark(card)
        self.assertTrue(mark, "nothing on the card admits there is more")
        self.assertNotIn("more characters", mark.lower(),
                         "the marker still reads as a truncation of the shown "
                         "sentence: %r" % mark)
        self.assertIn("summary", mark.lower(),
                      "the marker does not say the card is showing a summary: "
                      "%r" % mark)
        self.assertIn(str(len(_squash(REAL))), mark,
                      "the marker does not say how much is waiting: %r" % mark)
        self.assertFalse(self.said(card).endswith("…"),
                         "a sentence that was not cut ends in an ellipsis")

    def test_there_is_still_one_way_in(self):
        reads = [n for n in _flatten(self.gated())
                 if n.get("tag") == "button"
                 and " xo-read-report " in (" " + (n.get("cls") or "") + " ")]
        self.assertEqual(1, len(reads),
                         "expected one way in, got %r"
                         % [n["text"] for n in reads])
        self.assertIn("escalation", reads[0]["text"].lower())

    def test_the_whole_escalation_is_still_not_on_the_card(self):
        text = _all_text(self.gated())
        self.assertNotIn("(a) BUILD IT ANYWAY", text)
        self.assertNotIn(REAL[-120:], text)

    def test_an_absurd_summary_cannot_rebuild_the_wall(self):
        """`humanSummary` is UNTRUSTED PAYLOAD TEXT. It gets the same budget
        the note gets, or this whole change hands the wall back through a
        different field."""
        card = self.gated(summary="Decide. " + ("very long sentence " * 120))
        said = self.said(card)
        self.assertTrue(said.startswith("Decide."),
                        "the summary is not the sentence on the card: %r"
                        % said)
        self.assertLessEqual(len(said), 150,
                             "a %d-character summary is back to a wall"
                             % len(said))
        self.assertTrue(said.endswith("…"), said)
        self.assertIn("clipped", self.mark(card).lower(),
                      "the summary was cut and the card does not say so: %r"
                      % self.mark(card))

    def test_the_summary_is_escaped_and_sanitised_like_the_note(self):
        """UX-33: no CLI syntax on a GUI surface. The modal already puts this
        exact field through `sanitizeGateText`; the card must not render it
        raw, or one payload reads two ways on two surfaces."""
        said = self.said(self.gated(
            summary="Answer it with `lcars respond 11` or it stalls."))
        self.assertIn("Answer it with", said,
                      "the summary is not the sentence on the card: %r" % said)
        self.assertNotIn("lcars respond", said, said)

    def test_a_summary_that_sanitises_away_falls_back_to_the_prose(self):
        card = self.gated(summary="`lcars respond 11`")
        self.assertIn("Two things stopped this", self.said(card))
        self.assertIn("more characters", self.mark(card).lower())

    # ── CONTROLS ────────────────────────────────────────────────────────
    def test_without_a_summary_the_prose_excerpt_is_exactly_round_one(self):
        """THE CONTROL, and it answers differently: a gate that carries no
        `humanSummary` (an older pending.json, or a stage that writes none)
        keeps the round-1 behaviour to the character — the prose clipped on a
        sentence boundary, with the counted marker. If this arm printed the
        same thing as the one above, the preference would be unconditional."""
        card = self.card()
        said = self.said(card)
        self.assertTrue(said.startswith("Two things stopped this"), said)
        self.assertTrue(said.endswith("…"), said)
        mark = self.mark(card)
        self.assertIn("clipped", mark.lower())
        self.assertIn("more characters", mark.lower())
        missing = len(_squash(REAL)) - len(said.rstrip(" …"))
        self.assertIn(str(missing), mark, mark)
        self.assertNotEqual(said, _squash(self.SUMMARY))

    def test_a_short_note_is_still_verbatim_even_with_a_summary(self):
        """THE SECOND CONTROL. The summary substitutes for a CLIP, never for
        the note: where nothing was being hidden there is nothing to summarise,
        and the stand-down line the board has drawn since S201 is untouched.
        Same gate as the arm above, opposite answer."""
        card = self.gated(numberOne={"note": SHORT})
        self.assertEqual(SHORT, _cls_of(card, " xo-note ")[0]["text"])
        self.assertEqual([], _cls_of(card, " xo-note-cut "))
        self.assertEqual([], [n for n in _flatten(card)
                              if n.get("tag") == "button" and
                              " xo-read-report " in
                              (" " + (n.get("cls") or "") + " ")])

    def test_an_engaged_transcript_is_not_relabelled_with_a_summary(self):
        """THE THIRD CONTROL, holding the round-1 invariant: a card the detail
        surface will not open for is never clipped, so there is no clip for a
        summary to stand in for — and no button promising a pane that refuses
        the note. Same gate, opposite answer."""
        card = self.gated(numberOne={"status": "engaged"})
        self.assertEqual([], _cls_of(card, " xo-note-cut "))
        self.assertNotIn(_squash(self.SUMMARY), _all_text(card))

    def test_a_remote_done_card_keeps_its_whole_note(self):
        """The other half of that invariant (S278): no local pane, so no clip
        and no substitution — the note stays whole."""
        card = self.gated(stage="done", remote=True, readOnly=True)
        self.assertEqual([], _cls_of(card, " xo-note-cut "))
        self.assertIn("(a) BUILD IT ANYWAY", _all_text(card))


class TheFullEscalationIsOnTheTab(EscalationBase):

    def tab(self, **over):
        return _run(TAB_HARNESS, self.mi(**over))

    def test_the_escalation_is_there_whole(self):
        out = self.tab()
        text = _squash(_all_text(out["pane"]))
        self.assertIn(_squash(REAL), text,
                      "the escalation was trimmed on the way to the tab — "
                      "this is a MOVE, not a trim")

    def test_the_options_he_must_choose_between_are_legible(self):
        text = _squash(_all_text(self.tab()["pane"]))
        for opt in ("(a) BUILD IT ANYWAY",
                    "(b) CUT the parts that depend on it",
                    "(c) CHANGE THE REPO'S DATA FIRST"):
            self.assertIn(opt, text, opt)

    def test_the_source_it_cites_survives(self):
        text = _squash(_all_text(self.tab()["pane"]))
        self.assertIn("an ISO-8601 UTC `timestamp`", text)
        self.assertIn("#wildlife + #trail", text)

    def test_it_leads_the_tab_and_says_it_is_an_escalation(self):
        out = self.tab()
        self.assertTrue(out["paneText"], "the pane rendered nothing")
        lead = " ".join(out["paneText"][:2]).lower()
        self.assertIn("escalat", lead,
                      "the tab does not open on the thing he came to read: %r"
                      % out["paneText"][:2])

    def test_an_escalation_with_no_verdict_yet_is_still_shown(self):
        """A mission can escalate before anything is scored. The pane used to
        answer that with "Number One hasn't looked at this one yet" — which is
        both wrong and the only copy of the escalation gone."""
        out = self.tab()
        text = _all_text(out["pane"])
        self.assertNotIn("hasn't looked at this one yet", text)
        self.assertEqual(1, len(_cls_of(out["pane"], " xo-escalation ")))

    # ── CONTROLS ────────────────────────────────────────────────────────
    def test_an_engaged_transcript_is_not_published_as_an_escalation(self):
        """THE CONTROL, answering differently. `xo_finish` writes the worker's
        TRANSCRIPT into `note` while a mission is ENGAGED — it is not news and
        nobody wrote it for him. The card has always hidden it; the tab must
        not promote it to an escalation."""
        out = self.tab(numberOne={"status": "engaged"})
        self.assertEqual([], _cls_of(out["pane"], " xo-escalation "))
        self.assertNotIn("(a) BUILD IT ANYWAY", _all_text(out["pane"]))

    def test_a_mission_with_no_note_at_all_still_says_so(self):
        """THE OTHER CONTROL: the pane's existing sentence for a mission
        Number One has engaged and not yet looked at is untouched."""
        out = self.tab(numberOne={"note": None})
        self.assertIn("hasn't looked at this one yet", _all_text(out["pane"]))
        self.assertEqual([], _cls_of(out["pane"], " xo-escalation "))


class HeCanReadItWhileAnsweringIt(EscalationBase):
    """The half the captain explicitly asked for — "as part of ANSWERING the
    escalation". The answer path already exists end to end (the card's
    `Answer ▸` → openRespond → POST /api/mission/<id>/respond → respond.sh);
    what it never carried was the escalation it is answering."""

    def respond(self, **over):
        return _run(DETAIL_HARNESS, self.mi(**over), "respond")

    def test_the_answering_surface_opens(self):
        out = self.respond()
        self.assertEqual(1, out["opened"])
        self.assertTrue(any("/api/mission/lcars-20261016-011" in f
                            for f in out["fetches"]), out["fetches"])

    def test_the_whole_escalation_is_beside_the_answer_box(self):
        out = self.respond()
        text = _squash(_all_text(out["overlay"]))
        self.assertIn(_squash(REAL), text,
                      "he is asked to decide without the thing he is deciding")
        self.assertEqual(1, len(_cls_of(out["overlay"], " xo-escalation ")))

    def test_the_gate_question_is_still_the_headline(self):
        text = _all_text(self.respond()["overlay"])
        self.assertIn("DECISION NEEDED", text)

    def test_the_answer_control_is_still_there(self):
        nodes = _flatten(self.respond()["overlay"])
        self.assertTrue([n for n in nodes if n.get("tag") == "textarea"],
                        "the answer box is gone")
        self.assertTrue([n for n in nodes
                         if "Submit & Resume" in (n.get("text") or "")],
                        "the submit control is gone")

    # ── CONTROL ─────────────────────────────────────────────────────────
    def test_an_ordinary_gate_with_no_number_one_is_unchanged(self):
        """THE CONTROL: most gates are the pipeline's own, with no Number One
        anywhere near them. That modal must gain nothing."""
        out = _run(DETAIL_HARNESS, {
            "id": "lcars-20261016-012", "issue": 12, "stage": "research",
            "title": "A gate nobody delegated", "awaiting": True,
            "question": "Over the 20-question cap — which matter?"}, "respond")
        self.assertEqual([], _cls_of(out["overlay"], " xo-escalation "))
        self.assertIn("Over the 20-question cap",
                      _all_text(out["overlay"]))


if __name__ == "__main__":
    unittest.main()

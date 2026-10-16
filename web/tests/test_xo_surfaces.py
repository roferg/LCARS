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
import threading
import unittest
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))

CARD_HARNESS = os.path.join(HERE, "board_card_harness.js")
TAB_HARNESS = os.path.join(HERE, "board_xo_tab_harness.js")
BOARD_JS = os.path.join(os.path.dirname(HERE), "static", "board.js")


class InterruptedReportSurfaces(unittest.TestCase):
    """One artifact predicate, exercised through HTTP, shipping DOM, and CLI."""

    def test_cli_surfaces_unreadable_reports_without_downgrading_full(self):
        from tests import _fixtures as fx

        with tempfile.TemporaryDirectory(dir=os.environ.get("TMPDIR")) as root:
            subprocess.run(["git", "init", "-q", root], check=True)
            fx.write_json(os.path.join(root, ".git", "lcars", "config.json"), {})
            mid = "m-unreadable-report"
            fx.plant_simple(root, mid, stage="verify", issue=1)
            xo = os.path.join(fx.mission_dir(root, mid), "xo")
            os.makedirs(xo, exist_ok=True)
            cases = (
                ("invalid-full", b"\xff", b"Preserved partial evidence.", "report.md"),
                ("invalid-partial", None, b"\xff", "partial-report.md"),
                ("missing", None, None, None),
                ("valid-full", b"Completed full report.", b"\xff", None),
            )
            for name, full, partial, unreadable in cases:
                with self.subTest(artifacts=name):
                    for filename, data in (("report.md", full),
                                           ("partial-report.md", partial)):
                        path = os.path.join(xo, filename)
                        if os.path.exists(path):
                            os.unlink(path)
                        if data is not None:
                            with open(path, "wb") as fh:
                                fh.write(data)
                    cli = subprocess.run(
                        ["bash", "skills/lcars-xo/xo.sh", "report", mid],
                        env=dict(os.environ, GIT_DIR=os.path.join(root, ".git")),
                        text=True, capture_output=True)
                    if unreadable:
                        self.assertEqual(cli.returncode, 1, cli.stdout)
                        self.assertEqual(cli.stdout, "")
                        self.assertIn("cannot read", cli.stderr.lower())
                        self.assertIn(os.path.join(xo, unreadable), cli.stderr)
                        self.assertNotIn("Traceback", cli.stderr)
                    else:
                        self.assertEqual(cli.returncode, 0, cli.stderr)
                        self.assertEqual(cli.stderr, "")
                        self.assertEqual("Completed full report." in cli.stdout,
                                         name == "valid-full")
                        self.assertNotIn("Preserved partial evidence.", cli.stdout)

    def test_report_availability_and_precedence_on_every_read_surface(self):
        from tests import _fixtures as fx
        from tests.test_xo_toggle import plant_number_one
        from lcars_serve.local_adapter import LocalAdapter
        from lcars_serve.server import make_server

        full = "Completed look: the toolbar was checked."
        partial = "Unfinished evidence: the toolbar disappeared."
        states = (("verify", "engaged"), ("done", "engaged"),
                  ("verify", "stood-down"), ("verify", "escalated"))
        artifacts = (("partial", False, True), ("full", True, False),
                     ("none", False, False), ("both", True, True))
        with tempfile.TemporaryDirectory() as root:
            subprocess.run(["git", "init", "-q", root], check=True)
            fx.write_json(os.path.join(root, ".git", "lcars", "config.json"), {})
            expected = {}
            for stage, status in states:
                for name, has_full, has_partial in artifacts:
                    mid = "m-%s-%s-%s" % (stage, status, name)
                    fx.plant_simple(root, mid, stage=stage, issue=len(expected) + 1)
                    plant_number_one(root, mid, {
                        "status": status, "engine": "copilot", "score": "high",
                        "evaluatedAt": "2026-10-15T10:00:00Z"})
                    d = fx.mission_dir(root, mid)
                    # No journal is required to read preserved evidence.
                    if status != "engaged" or stage == "done":
                        fx.write_jsonl(os.path.join(d, "number-one.jsonl"), [{
                            "at": "2026-10-15T10:01:00Z", "action": "stopped",
                            "detail": "The operator interrupted this look."}])
                    if has_full:
                        fx.write(os.path.join(d, "xo", "report.md"), full)
                        fx.write_json(os.path.join(d, "xo", "verdict.json"),
                                      {"score": "high", "summary": full})
                    if has_partial:
                        fx.write(os.path.join(d, "xo", "partial-report.md"), partial)
                    expected[mid] = ("full" if has_full else
                                     "partial" if has_partial else "none")
            server = make_server(LocalAdapter(root), host="127.0.0.1", port=0,
                                 poll_interval=0.05)
            threading.Thread(target=server.serve_forever, daemon=True).start()
            try:
                def get(path):
                    url = "http://127.0.0.1:%d%s" % (server.server_address[1], path)
                    with urllib.request.urlopen(url, timeout=15) as response:
                        return json.load(response)

                cards = {m["id"]: m for column in get("/api/board")["columns"].values()
                         for m in column}
                aggregate = get("/api/xo/report")
                modal = _run(os.path.join(HERE, "board_xo_report_harness.js"),
                             {"reportData": aggregate})
                for mid, kind in expected.items():
                    detail = get("/api/mission/" + mid)
                    card = _run(CARD_HARNESS, cards[mid])
                    tab = _run(TAB_HARNESS, detail)
                    cli = subprocess.run(
                        ["bash", os.path.join(os.getcwd(), "skills/lcars-xo/xo.sh"),
                         "report", mid], cwd=root, text=True, capture_output=True)
                    env = dict(os.environ, MISSION_DIR=fx.mission_dir(root, mid),
                               MISSION_ID=mid, STATE=os.path.join(
                                   fx.mission_dir(root, mid), "state.json"))
                    comment = subprocess.run(
                        ["bash", "-c", '. "$1"; cm_render_number_one', "bash",
                         "skills/lcars-run/comment-mirror.sh"],
                        env=env, text=True, capture_output=True)
                    with self.subTest(mission=mid, surface="cli-exit"):
                        self.assertEqual(cli.returncode, 0, cli.stderr)
                    for surface, actual in (
                        ("card-payload", cards[mid]["numberOne"].get("reportKind")),
                        ("detail-payload", detail["numberOne"].get(
                            "report", {}).get("kind")),
                        ("aggregate-api", next((r["kind"] for r in aggregate.get(
                            "reports", []) if r["id"] == mid), None)),
                    ):
                        with self.subTest(mission=mid, surface=surface):
                            self.assertEqual(actual or "none", kind)
                    controls = [n for n in _flatten(card)
                                if "xo-read-report" in n.get("cls", "").split()]
                    with self.subTest(mission=mid, surface="card-control"):
                        self.assertEqual(bool(controls), kind != "none")
                        if kind == "partial":
                            self.assertIn("partial", json.dumps(controls).lower())
                            self.assertIn("INTERRUPTED", _all_text(card))
                            self.assertFalse(_cls_of(card, "xo-score"))
                    if kind == "partial":
                        with self.subTest(mission=mid, surface="aggregate-grade"):
                            group = next((m for m in aggregate["missions"]
                                          if m["id"] == mid), {})
                            self.assertIsNone(group.get("score"))
                    for surface, text in (
                        ("detail-render", _all_text(tab["pane"])),
                        ("cli-output", cli.stdout),
                        ("living-comment", comment.stdout),
                    ):
                        with self.subTest(mission=mid, surface=surface):
                            self.assertEqual(full in text, kind == "full")
                            self.assertEqual(partial in text, kind == "partial")
                            if kind == "partial":
                                self.assertIn("INTERRUPTED", text)
                                self.assertIn("not a verdict", text.lower())
                                self.assertNotIn("HIGH", text)
                    if kind != "none":
                        with self.subTest(mission=mid, surface="aggregate-render"):
                            self.assertIn(full if kind == "full" else partial,
                                          json.dumps(modal))
            finally:
                server.shutdown()
                server.server_close()

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

    def test_the_verdict_line_is_no_longer_on_the_card(self):
        """The captain asked for the grade alone. The verdict line — the
        ledger's derivation drawn under the pill in `.xo-verdict-line` — was
        exactly the "extra text" he called out: "I don't think we need all
        that extra text there." It comes off the card entirely. It is not
        lost: the same sentence still LEADS the ◈ Number One tab (the report),
        which is where the detail now belongs. This assertion used to require
        the line ON the card; it now requires it OFF."""
        card = self.card()
        self.assertEqual([], _cls_of(card, " xo-verdict-line "))
        self.assertNotIn(HEADLINE, _all_text(card))

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

    # ── A PUNISHING VERDICT NEVER REACHES THE CARD ──────────────────────
    # The tester once planted a verdict of 2,673 characters — a rambling
    # worker `why` — and an earlier card drew all of them: 91 wrapped lines,
    # 1,752 px tall. The cure then was to clamp the line to one; the cure now
    # is that there is no line to clamp. A transcript cannot reach the card
    # because the card carries no verdict line at all.

    def test_a_punishing_verdict_never_reaches_the_card(self):
        card = self.card(numberOne={"headline": RAMBLE})
        self.assertEqual([], _cls_of(card, " xo-verdict-line "))
        self.assertNotIn(RAMBLE[:60], _all_text(card))

    def test_and_the_rest_of_it_is_not_hiding_on_the_card_somewhere(self):
        card = self.card(numberOne={"headline": RAMBLE})
        self.assertNotIn(RAMBLE[-80:], _all_text(card))

    def test_the_way_into_the_whole_thing_is_still_right_there(self):
        card = self.card(numberOne={"headline": RAMBLE})
        reads = [n for n in _flatten(card)
                 if "Read the full report" in (n.get("text") or "")]
        self.assertEqual(1, len(reads))

    def test_a_normal_length_headline_is_also_off_the_card(self):
        card = self.card()
        self.assertEqual([], _cls_of(card, " xo-verdict-line "))
        self.assertNotIn(HEADLINE, _all_text(card))

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


class DoneMissionsKeepTheirReport(TabBase):

    def test_done_with_stale_engaged_status_keeps_the_historical_report(self):
        result = self.mi(stage="done")
        self.assertIn({"text": "◈ Number One", "key": "xo"}, result["tabs"])
        text = _all_text(result["pane"])
        self.assertIn("MEDIUM", text)
        self.assertIn(HEADLINE, text)
        self.assertIn("worldToScreen converts correctly", text)
        self.assertNotIn("NUMBER ONE · ENGAGED", text)
        self.assertNotIn("has the conn", text)
        self.assertNotIn("Stand down", text)


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
    """S223: each criterion is now its own boxed block (`.xo-item`); how it
    was settled is said in the evidence cell — the real screenshot when there
    is one, otherwise a sentence naming the RECORDED kind (never the note)."""

    def rows(self):
        out = self.mi()
        rows = _cls_of(out["pane"], " xo-item ")
        return {_all_text(r): r for r in rows}, out

    def test_there_is_a_row_per_criterion(self):
        out = self.mi()
        self.assertEqual(5, len(_cls_of(out["pane"], " xo-item ")))

    def test_tests_and_a_picture_are_different_words(self):
        rows, _ = self.rows()
        tested = [t for t in rows if "Camera exposes" in t][0]
        pictured = [t for t in rows if "example game still runs" in t][0]
        self.assertIn("your tests", tested)
        self.assertIn("picture", pictured.lower())
        self.assertNotIn("your tests", pictured)

    def test_a_measured_box_is_a_third_word(self):
        rows, _ = self.rows()
        measured = [t for t in rows if "toolbar rows line up" in t][0]
        self.assertIn("a measured box", measured)

    def test_an_unchecked_criterion_claims_no_evidence_at_all(self):
        rows, _ = self.rows()
        unchecked = [t for t in rows if "worldToScreen converts" in t][0]
        for word in ("your tests", "a measured box"):
            self.assertNotIn(word, unchecked)
        # S216: the captain's own outcome word, "couldn't check".
        self.assertIn("couldn't check", unchecked.lower())

    def test_the_harness_vocabulary_never_reaches_him(self):
        # In OUR labels — the outcome chips this board writes itself.
        out = self.mi()
        chips = _cls_of(out["pane"], " xo-ochip ")
        self.assertEqual(5, len(chips))
        for c in chips:
            self.assertNotIn("untested", (c["text"] or "").lower())

    def test_the_evidence_word_is_read_off_the_record_not_the_note(self):
        # Same NOTE, opposite RECORD: the word must follow the record.
        out = self.mi(verdict={"criteria": [
            {"id": "a", "text": "the one row", "status": "met",
             "evidence": "tests", "note": "I saw it in the screenshot"}]})
        row = _cls_of(out["pane"], " xo-item ")[0]
        ev = _all_text(_cls_of(row, " xo-ev ")[0])
        self.assertIn("your tests", ev)
        self.assertNotIn("a picture", ev)


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
        # S224 — the grade and its numbers now lead as a RAIL (a word, a
        # denominator and a legend of counts) before the sentence beside it,
        # so the window is counted in text nodes, not in blocks. The claim is
        # unchanged and is the one that matters: the honest sentence is at the
        # top of the pane and the reassurance is nowhere near it.
        lead = " ".join(out["paneText"][:14])
        self.assertNotIn("no gaps found", lead)
        self.assertIn(HEADLINE.split("—")[0].strip(), lead)
        # and it is the first SENTENCE on the pane — nothing prose-like runs
        # ahead of it.
        self.assertEqual(HEADLINE, _all_text(_cls_of(out["pane"], " xo-lede ")[0]).strip())

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

    def test_the_card_carries_no_verdict_line_while_the_tab_still_ledes(self):
        """C8's guarantee — the card can never contradict the score — now
        holds TRIVIALLY, because the card shows only the grade. The verdict
        line that used to sit on the card (and had to match the tab lede so
        the two could not disagree) is gone; the derivation still ledes the
        tab, which is where the reader goes for it. This assertion used to
        require card_line == tab_lede; it now requires the card to have no
        line at all while the tab keeps its lede."""
        if shutil.which("node") is None:
            self.skipTest("node not available")
        tab = self.mi()
        card = _run(CARD_HARNESS, {
            "id": "lcars-20260917-401", "issue": 8, "stage": "verify",
            "title": "worldToScreen / screenToWorld",
            "numberOne": {"status": "engaged", "engine": "copilot",
                          "score": "medium", "note": LONG,
                          "headline": HEADLINE}})
        self.assertEqual([], _cls_of(card, " xo-verdict-line "))
        self.assertNotIn(HEADLINE, _all_text(card))
        lede = _all_text(_cls_of(tab["pane"], " xo-lede ")[0]).strip()
        self.assertEqual(HEADLINE, lede)

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


OBS = [
    {"kind": "crowding", "px": 7,
     "message": "the Cancel button and the unlabeled button are crowded "
                "together — 7 px between them",
     "screen": "http://localhost:5173/#mbr/build", "reportedUnder": "layout"},
    {"kind": "oversized-icon", "part": "Back to builder",
     "says": "the \"Back to builder\" button holds an icon 41px tall inside a "
             "control only 30px tall",
     "message": "the \"Back to builder\" button holds an icon 41px tall inside "
                "a control only 30px tall",
     "screen": "http://localhost:5173/#mbr/preview",
     "reportedUnder": "measured"},
    {"kind": "carried-value", "shot": "shot-walk-01-j1",
     "message": "August 2026 became September 2026 after I clicked \"pull data "
                "& start\" — the month did not carry from one screen to the next",
     "screen": "http://localhost:5173/#mbr/collect",
     "reportedUnder": "measured"},
]


class DC_TheMeasurementsAreONTheBoard(TabBase):
    """S220 fix round 2, D-C — `verdict.observations` reaches the reader.

    The tester served a scored run through the real daemon, opened every
    filter and every disclosure, and dumped 46.8k characters of rendered
    text. Not one observation was in it: not the month that did not carry,
    not the 41px icon, not even the two crowding lines that predate this
    round. The data was on disk in `verdict.observations` the whole time —
    the reader simply never rendered the array.

    These are the wiring half (a node DOM is a browser stub); the browser
    dump is the other half and the tester's.
    """

    def test_a_measured_finding_is_drawn_in_its_own_words(self):
        text = _all_text(self.mi(verdict={"observations": OBS})["pane"])
        self.assertIn("the month did not carry", text)
        self.assertIn("an icon 41px tall", text)
        self.assertIn("crowded together", text)

    def test_both_buckets_get_the_headings_report_md_uses(self):
        text = _all_text(self.mi(verdict={"observations": OBS})["pane"])
        self.assertIn("What I measured on your drawing", text)
        self.assertIn("Things I noticed that are not on your list", text)

    def test_the_top_of_the_report_points_at_them(self):
        # S224: still said at the top, still says the rule — but as ONE
        # clause on the counts line, not the paragraph it used to be. The
        # captain's words: "that rule stays true and stays stated, but it
        # does not need a paragraph above the fold."
        out = self.mi(verdict={"observations": OBS})
        line = _cls_of(out["pane"], " xo-measured-lede ")
        self.assertEqual(1, len(line), "the measurements line is gone")
        text = _all_text(line[0])
        # S224 — it is a COUNT, so it lives in the rail with the other counts,
        # under the bar it is explicitly not part of. Same rule, said shorter.
        self.assertIn("plus 2 I measured", text)
        self.assertIn("never moves the grade", text)
        # and it is ONE line, not a block of prose.
        self.assertLess(len(text), 120, "it grew back into a paragraph")
        rail = _cls_of(out["pane"], " xo-rail ")[0]
        self.assertEqual(1, len(_cls_of(rail, " xo-measured-lede ")),
                         "it is not in the rail with the counts it qualifies")

    def test_they_are_reachable_by_a_filter_of_their_own(self):
        out = self.mi(verdict={"observations": OBS})
        labels = [n["text"] for n in _cls_of(out["pane"], " xo-filter ")]
        # S224: the chip says the total it actually filters. S220 fix round 3
        # (F3) joined the two numbers with "2 + 1" ON THE CHIP, and the
        # captain could not read it as a label. Both numbers survive — in
        # words, on the line under the row, where the 108 is also explained.
        self.assertIn("I measured · 3", labels)
        self.assertNotIn("I measured · 2 + 1", labels)
        # and All counts what is actually in the list: 5 criteria + 3.
        self.assertIn("All · 8", labels)

    def test_the_other_denominators_are_explained_where_they_appear(self):
        """S224 — three true numbers, none of them a surprise.

        `All · 8` is not the 5 things he asked for and not the 3 measured,
        and it used to arrive with nothing to join it to either. One muted
        line under the chip row it belongs to does the joining, and carries
        the 2/1 split the "I measured" chip stopped spelling out."""
        out = self.mi(verdict={"observations": OBS})
        keys = _cls_of(out["pane"], " xo-filters-key ")
        self.assertEqual(1, len(keys), "nothing explains All · 8")
        text = _all_text(keys[0])
        self.assertIn("All · 8", text)
        self.assertIn("5 things you asked for", text)
        self.assertIn("3 I measured", text)
        self.assertIn("2 came from your drawing", text)
        self.assertIn("1 more I simply noticed", text)
        self.assertIn("never change your grade", text)

    def test_no_measurements_means_no_key_line_to_explain(self):
        # With nothing measured, All is the criteria count and needs no
        # reconciling — an explanation of an identity is noise.
        out = self.mi()
        self.assertEqual([], _cls_of(out["pane"], " xo-filters-key "))

    def test_the_counts_line_adds_up_to_the_one_number_that_leads(self):
        """S224 — ONE denominator is the spine, and the chips match it.

        It read "79 of 101 checked · 3 didn't work · 22 I couldn't check"
        over a chip row saying "Worked · 76": three denominators, all right,
        and reconciling them was subtraction he had to do. The spine is now
        the things HE asked for, and the outcomes under it add up to it —
        and since the captain called the row of four numbers "too smashed to
        parse", it is drawn as a bar with the counts written out beside it."""
        out = self.mi(verdict={"observations": OBS})
        rail = _cls_of(out["pane"], " xo-rail ")
        self.assertEqual(1, len(rail), "there is no rail of numbers")
        text = _all_text(rail[0])
        # the fixture: 2 met, 0 gap, 2 untested → 4 asked for
        self.assertIn("4 things you asked for", text)
        self.assertIn("2 worked", text)
        self.assertIn("2 I couldn't check", text)
        # the old shape, which he had to reconcile by hand, is gone
        self.assertNotIn("of 4 checked", text)

    def test_every_count_is_written_out_and_never_only_a_colour(self):
        """Colour is never the only channel: one legend row per outcome, the
        count in the row, in the fixed order worked / didn't / couldn't."""
        out = self.mi(verdict={"observations": OBS})
        rows = _cls_of(out["pane"], " xo-legend-row ")
        self.assertEqual(3, len(rows))
        said = [_all_text(r) for r in rows]
        self.assertIn("2", said[0])
        self.assertIn("worked", said[0])
        self.assertIn("didn't work", said[1])
        self.assertIn("I couldn't check", said[2])

    def test_one_look_draws_ONE_bar_and_claims_no_deltas(self):
        out = self.mi(verdict={"observations": OBS})
        self.assertEqual(1, len(_cls_of(out["pane"], " xo-bar ")))
        self.assertEqual([], _cls_of(out["pane"], " xo-legend-d "))
        self.assertNotIn("First look", _all_text(out["pane"]))

    def test_they_are_NOT_counted_as_scored_gaps(self):
        # S210 stands: a measurement never moves the grade and is never
        # dressed as a criterion that failed.
        out = self.mi(verdict={"observations": OBS})
        labels = [n["text"] for n in _cls_of(out["pane"], " xo-filter ")]
        self.assertIn("Didn't work · 1", labels)   # the one real gap, alone
        blocks = _cls_of(out["pane"], " xo-obs ")
        self.assertEqual(3, len(blocks))
        for b in blocks:
            self.assertIn("does not change your grade", _all_text(b))

    def test_a_verdict_with_no_observations_grows_no_such_block(self):
        out = self.mi()
        self.assertEqual([], _cls_of(out["pane"], " xo-obs "))
        self.assertEqual([], _cls_of(out["pane"], " xo-measured-lede "))
        self.assertNotIn("I measured against", _all_text(out["pane"]))
        labels = [n["text"] for n in _cls_of(out["pane"], " xo-filter ")]
        self.assertIn("All · 5", labels)


class S224_TheHeaderIsTheGradeTheReasonAndWhatNeedsHim(TabBase):
    """S224 — the captain, looking at his own scored report: *"that's a hot
    mess visually and trying to take context away, we need to improve that
    UX."*

    Five blocks of prose arrived before a single piece of evidence, and two
    of them were hedges ABOUT the prose beside them (the measurements
    caveat and the summing-up's self-audit). The grade's own one-line reason
    was the fourth thing down. Meanwhile `verdict.escalations` — the look's
    "these are yours to decide", the one thing on the page that needs a
    decision — was in report.md and in the terminal and NOWHERE on the board.

    The target shape: the grade, ONE sentence of why, and what needs him.
    Everything else folds — folds, not disappears. A node DOM is a browser
    stub, so this proves the wiring and the order; the real-Chrome drive at
    both widths is the other half.
    """

    ESC = ["The next-up month jumped from 'August 2026' on the start card to "
           "'September 2026' on the collect screens — worth the captain's eye."]

    def test_what_needs_him_is_on_the_board_at_all(self):
        out = self.mi(verdict={"escalations": self.ESC})
        box = _cls_of(out["pane"], " xo-needs ")
        self.assertEqual(1, len(box), "the escalation is still not drawn")
        text = _all_text(box[0])
        self.assertIn("yours to decide", text)
        self.assertIn("The next-up month jumped", text)

    def test_it_is_said_in_the_looks_own_words_not_a_rewrite(self):
        out = self.mi(verdict={"escalations": self.ESC})
        self.assertIn(self.ESC[0], _all_text(_cls_of(out["pane"], " xo-needs ")[0]))

    def test_it_sits_with_the_grade_before_any_of_the_prose(self):
        # S224: the header is a two-column rail now, so what needs him is a
        # child of the right-hand column rather than of the pane. The claim is
        # the same one and it is read in DOCUMENT order, which is what a
        # reader actually meets.
        out = self.mi(verdict={"escalations": self.ESC})
        order = [(n.get("cls") or "") for n in _flatten(out["pane"])]
        self.assertTrue(any("xo-needs" in c for c in order))
        needs = [i for i, c in enumerate(order) if "xo-needs" in c][0]
        grade = [i for i, c in enumerate(order) if "xo-grade-chip" in c][0]
        self.assertLess(grade, needs, "the grade must still lead")
        for later in ("xo-more", "xo-items-wrap", "xo-showme"):
            idx = [i for i, c in enumerate(order) if later in c]
            if idx:
                self.assertLess(needs, idx[0],
                                "%s came before what needs him" % later)

    def test_no_escalation_no_block(self):
        self.assertEqual([], _cls_of(self.mi()["pane"], " xo-needs "))

    def test_everything_else_is_behind_ONE_door_that_says_what_it_holds(self):
        out = self.mi(verdict={"observations": OBS})
        folds = [n for n in _flatten(out["pane"]) if n["tag"] == "details"]
        self.assertEqual(1, len(folds), "expected exactly one top-level fold")
        label = _all_text(folds[0])
        # the door is labelled with what is behind it, not "more…"
        self.assertIn("what I made of it", label)
        self.assertIn("where my summing-up falls short", label)

    def test_the_self_audit_is_still_reachable_word_for_word(self):
        # It was expensive honesty. It folds; it does not go.
        out = self.mi(verdict={"observations": OBS})
        cav = _cls_of(out["pane"], " xo-full-caveat ")
        self.assertEqual(1, len(cav))
        self.assertIn("is not the whole count", _all_text(cav[0]))
        # …and it is inside the fold, not competing with the grade.
        folds = [n for n in _flatten(out["pane"]) if n["tag"] == "details"]
        self.assertIn("is not the whole count", _all_text(folds[0]))

    def test_the_summing_up_folds_too(self):
        out = self.mi()
        folds = [n for n in _flatten(out["pane"]) if n["tag"] == "details"]
        self.assertIn(LONG[:40], _all_text(folds[0]))
        # and nothing of it is left loose as a direct child of the pane
        order = [(n.get("cls") or "") for n in out["pane"]["children"]]
        self.assertNotIn("xo-full", order)
        self.assertNotIn("xo-full-caveat", order)

    def test_the_second_score_sits_with_the_grade_it_modifies(self):
        """It used to be the LAST child of the verdict row, which parked it
        against the far right margin — the captain read it as debris."""
        out = _run(TAB_HARNESS, self._with_score2())
        col = _cls_of(out["pane"], " xo-gradecol ")
        self.assertEqual(1, len(col), "there is no grade column")
        kids = [(n.get("cls") or "") for n in col[0]["children"]]
        self.assertTrue(any("xo-grade-chip" in c for c in kids))
        self.assertTrue(any("xo-score2" in c for c in kids),
                        "the second score is not with the grade")
        # S225: the chip names the FIRST grade as the BEFORE state ("before the
        # fixes") instead of floating the old, two-way "after the fixes" beside
        # it. This _with_score2 fixture is a same-grade re-check (low → low), so
        # the chip reads "unchanged from LOW before the fixes".
        self.assertIn("before the fixes", _all_text(col[0]))

    def _with_score2(self):
        mi = {
            "id": "lcars-20260920-001", "issue": 9, "stage": "verify",
            "title": "second look",
            "numberOne": {"status": "finished", "engine": "copilot",
                          "score": "low", "headline": HEADLINE,
                          "report": {"score": "low", "score2": "low",
                                     "status": "finished", "engine": "copilot",
                                     "verdict": {"score": "low",
                                                 "derivation": HEADLINE,
                                                 "counts": {"met": 1, "gap": 1,
                                                            "untested": 1},
                                                 "criteria": [], "gaps": [],
                                                 "alsoChecked": []},
                                     "logs": [], "shotsDir": "look-1",
                                     "journal": []}},
        }
        return mi


class S224_TheNumbersAreAShapeAndTheGradeMoves(TabBase):
    """S224 — the two-column rail, and the question the old screen could not
    answer: *"how did its grading change?"*

    A mission looked at twice had a SECOND verdict on disk and on the payload
    (`report.verdict2`) the whole time, and this pane never opened it: it drew
    the FIRST look's grade, counts, ledger and summing-up with one `after the
    fixes` chip as the only hint. So the numbers on screen were the stale ones
    and nothing said what had moved.

    Two states, and the difference between them is a RECORD, not a guess: a
    first look draws ONE bar and claims no deltas; a re-check draws two on the
    same scale, with the deltas as arithmetic on two recorded tallies.

    A node DOM is a browser stub — this proves the wiring, the order and the
    arithmetic; the real-Chrome drive at 1600px and 400px is the other half.
    """

    # Four bugs filed; their child Missions are on the board, and the stage
    # each one RECORDS is what "fixed" means here. Nothing reads a sentence.
    LOGS = [{"n": 1, "mission": "child-1", "criterion": "prd-1",
             "title": "the buttons wrap", "shots": []},
            {"n": 2, "mission": "child-2", "criterion": "prd-5",
             "title": "the icon is 1.45x its button", "shots": []}]
    BOARD = {"columns": {"done": [{"id": "child-1", "stage": "done"},
                                  {"id": "child-2", "stage": "done"}]}}
    HALF = {"columns": {"done": [{"id": "child-1", "stage": "done"}],
                        "implement": [{"id": "child-2", "stage": "implement"}]}}
    JOURNAL = [{"action": "rescored", "at": "2026-09-21T07:37:34Z"},
               {"action": "scored", "at": "2026-09-21T05:15:38Z"}]

    def regrade(self, board=None, **over):
        """A mission with BOTH looks recorded: 2 met / 1 gap / 2 untested on
        the first, 3 met / 0 gap / 2 untested on the re-check."""
        v1 = {"score": "low", "derivation": HEADLINE,
              "scoreMeaning": "the first look's sentence",
              "counts": {"met": 2, "gap": 1, "untested": 2},
              "criteria": [], "gaps": [], "alsoChecked": []}
        v2 = {"score": "low", "derivation": "the re-check's own sentence.",
              "scoreMeaning": "I still could not check the point of it",
              "summary": "All the gaps I filed are fixed.",
              "counts": {"met": 3, "gap": 0, "untested": 2},
              "criteria": [], "gaps": [], "alsoChecked": []}
        v2.update(over.pop("verdict2", {}))
        report = {"score": "low", "score2": "low", "status": "finished",
                  "engine": "copilot", "verdict": v1, "verdict2": v2,
                  "logs": self.LOGS, "shotsDir": "look-2",
                  "journal": self.JOURNAL}
        report.update(over.pop("report", {}))
        mi = {"id": "lcars-20260920-001", "issue": 9, "stage": "verify",
              "title": "the MBR builder",
              "numberOne": {"status": "finished", "engine": "copilot",
                            "score": "low", "headline": HEADLINE,
                            "report": report}}
        args = [json.dumps(self.BOARD if board is None else board)]
        return _run(TAB_HARNESS, mi, *args)

    # ── the rail ───────────────────────────────────────────────────────────
    def test_the_numbers_live_in_a_rail_and_the_words_get_the_width(self):
        out = self.mi()
        self.assertEqual(1, len(_cls_of(out["pane"], " xo-rail ")))
        self.assertEqual(1, len(_cls_of(out["pane"], " xo-vtext ")))
        # the grade is in the rail, the sentence is in the column
        self.assertEqual(1, len(_cls_of(_cls_of(out["pane"], " xo-rail ")[0],
                                        " xo-grade-chip ")))
        self.assertEqual(1, len(_cls_of(_cls_of(out["pane"], " xo-vtext ")[0],
                                        " xo-lede ")))

    def test_the_chips_that_filter_the_list_are_the_last_control_in_the_column(self):
        out = self.mi()
        col = _cls_of(out["pane"], " xo-vtext ")[0]
        show = _cls_of(col, " xo-showme ")
        self.assertEqual(1, len(show), "the Show me bar is not in the column")
        self.assertTrue(_cls_of(show[0], " xo-filter "),
                        "the chips did not come with it")
        self.assertEqual("xo-showme", (col["children"][-1].get("cls") or ""))

    # ── two bars, one scale ────────────────────────────────────────────────
    def test_a_re_check_draws_the_first_look_and_the_now_on_one_scale(self):
        out = self.regrade()
        bars = _cls_of(out["pane"], " xo-bar ")
        self.assertEqual(2, len(bars), "expected the first look and the now")
        self.assertIn("xo-bar-was", bars[0]["cls"])
        self.assertNotIn("xo-bar-was", bars[1]["cls"])
        text = _all_text(_cls_of(out["pane"], " xo-rail ")[0])
        self.assertIn("First look", text)
        self.assertIn("Now", text)
        # SAME SCALE, and that is the whole point of drawing two: the first
        # look's "worked" is 2 of the SAME 5, not 2 of its own 5-that-happens-
        # to-match. A zero segment is not drawn at all — an invisible child
        # would still claim its 2px gap.
        def widths(bar):
            return [k["style"].get("width") for k in bar["children"]]
        self.assertEqual(["40%", "20%", "40%"], widths(bars[0]))
        self.assertEqual(["60%", "40%"], widths(bars[1]))

    def test_the_bar_says_when_each_look_happened_off_the_journal(self):
        out = self.regrade()
        text = _all_text(_cls_of(out["pane"], " xo-rail ")[0])
        # 05:15Z and 07:37Z, rendered in the reader's own clock — the HOUR is
        # local, so this asserts the minutes the record carries.
        self.assertIn(":15", text)
        self.assertIn(":37", text)

    def test_with_no_journal_entry_it_says_when_nothing(self):
        out = self.regrade(report={"journal": []})
        text = _all_text(_cls_of(out["pane"], " xo-rail ")[0])
        self.assertIn("First look", text)
        self.assertNotIn("First look ·", text)

    def test_the_legend_gains_the_deltas_and_they_are_subtraction(self):
        out = self.regrade()
        rows = [_all_text(r) for r in _cls_of(out["pane"], " xo-legend-row ")]
        self.assertIn("+1", rows[0])          # met 2 → 3
        self.assertIn("\u22121", rows[1])     # gap 1 → 0, a REAL minus sign
        self.assertIn("no change", rows[2])   # untested 2 → 2
        # and the counts shown are the NOW ones, not the first look's
        self.assertIn("3", rows[0])
        self.assertIn("0", rows[1])

    def test_a_first_look_never_grows_a_second_bar_or_a_delta(self):
        out = self.mi()
        self.assertEqual(1, len(_cls_of(out["pane"], " xo-bar ")))
        self.assertEqual([], _cls_of(out["pane"], " xo-legend-d "))

    # ── the badge ──────────────────────────────────────────────────────────
    def test_the_badge_is_the_current_grade_and_the_chip_says_what_it_was(self):
        out = self.regrade(report={"score": "medium", "score2": "low"})
        col = _cls_of(out["pane"], " xo-gradecol ")[0]
        self.assertIn("LOW", _all_text(_cls_of(col, " xo-grade-chip ")[0]))
        # S225: the chip named the first grade with a two-way "after the fixes
        # · was MEDIUM" that, under a LOW badge, read as "after the fixes it
        # was MEDIUM" — the OLD grade masquerading as the new one. It now names
        # MEDIUM as the BEFORE state and shows the direction: this build went
        # MEDIUM → LOW, a demotion, drawn "▼ down from MEDIUM before the fixes".
        chip = _all_text(_cls_of(col, " xo-score2 ")[0])
        self.assertIn("before the fixes", chip)
        self.assertIn("MEDIUM", chip)
        self.assertIn("down from", chip)
        self.assertNotIn("after the fixes", chip)

    def test_the_re_check_is_the_verdict_the_pane_renders(self):
        out = self.regrade()
        self.assertEqual("the re-check's own sentence.",
                         _all_text(_cls_of(out["pane"], " xo-lede ")[0]).strip())
        self.assertNotIn(HEADLINE, _all_text(out["pane"]))

    # ── what changed ───────────────────────────────────────────────────────
    def test_what_changed_appears_ONLY_when_a_second_score_exists(self):
        self.assertEqual([], _cls_of(self.mi()["pane"], " xo-changed "))
        self.assertEqual(1, len(_cls_of(self.regrade()["pane"], " xo-changed ")))

    def test_the_filed_and_fixed_counts_are_the_childrens_recorded_stages(self):
        text = _all_text(_cls_of(self.regrade()["pane"], " xo-changed ")[0])
        self.assertIn("2 bugs filed · 2 fixed.", text)
        half = _all_text(_cls_of(self.regrade(board=self.HALF)["pane"],
                                 " xo-changed ")[0])
        self.assertIn("2 bugs filed · 1 fixed.", half)

    def test_with_no_child_on_the_board_it_says_filed_and_claims_nothing_else(self):
        """A number nobody recorded is not a number."""
        text = _all_text(_cls_of(self.regrade(board={"columns": {}})["pane"],
                                 " xo-changed ")[0])
        self.assertIn("2 bugs filed.", text)
        self.assertNotIn("fixed", text)

    def test_why_it_is_still_low_is_the_recorded_sentence_verbatim(self):
        text = _all_text(_cls_of(self.regrade()["pane"], " xo-changed ")[0])
        self.assertIn("Why it's still LOW:", text)
        self.assertIn("I still could not check the point of it", text)

    def test_a_grade_that_moved_says_so_instead(self):
        out = self.regrade(report={"score": "low", "score2": "medium"})
        text = _all_text(_cls_of(out["pane"], " xo-changed ")[0])
        self.assertIn("Why it's now MEDIUM, was LOW:", text)

    def test_with_no_recorded_sentence_it_writes_none(self):
        out = self.regrade(verdict2={"scoreMeaning": ""})
        text = _all_text(_cls_of(out["pane"], " xo-changed ")[0])
        self.assertIn("2 bugs filed · 2 fixed.", text)
        self.assertNotIn("Why it's", text)

    def test_what_changed_comes_after_the_sentence_and_before_what_needs_him(self):
        out = self.regrade(verdict2={"escalations": ["yours to decide, this"]})
        order = [(n.get("cls") or "") for n in _flatten(out["pane"])]
        i = lambda k: [j for j, c in enumerate(order) if k in c][0]
        self.assertLess(i("xo-lede"), i("xo-changed"))
        self.assertLess(i("xo-changed"), i("xo-needs"))

    def test_a_second_score_with_no_second_verdict_is_still_only_one_bar(self):
        """The chip has always keyed off `score2` alone and still does — but
        a bar needs tallies, and a verdict nobody recorded has none."""
        out = self.regrade(report={"verdict2": None})
        self.assertEqual(1, len(_cls_of(out["pane"], " xo-bar ")))
        self.assertEqual([], _cls_of(out["pane"], " xo-changed "))
        self.assertEqual(1, len(_cls_of(out["pane"], " xo-score2 ")))


class S224_ThePicturesComeFromTheLookOnTheScreen(TabBase):
    """S224 fix round 1, D4 — the captain: *"What happened to the pictures
    being inline?"*

    Every ledger row on his re-checked mission read "The picture for this one
    (recheck-walk-01-j1) isn't on this laptop any more" over a file sitting on
    his disk. S224 made this pane draw the SECOND verdict; its shots were taken
    into the re-check's own directory, and they were still being asked for from
    the first look's. `shotsDir` stays the first look's — the gaps it FILED
    were filed there and their thumbnails were never broken — so the fix is a
    second directory used for the ledger and nothing else.

    A node DOM is a browser stub: this proves which URL each thumbnail asks
    for. That the image then LOADS (`naturalWidth > 0`) is the real-Chrome
    drive's half, and the route composition is proven end to end against a real
    server in `test_xo_shot_route.py`.
    """

    V2_CRIT = [{"id": "prd-1", "text": "the month carries", "status": "gap",
                "evidence": "picture", "shot": "recheck-walk-01-j1",
                "note": "August became September"}]
    V1_CRIT = [{"id": "prd-1", "text": "the month carries", "status": "gap",
                "evidence": "picture", "shot": "shot-walk-01-j1",
                "note": "August became September"}]
    LOGS = [{"n": 1, "mission": "child-1", "criterion": "prd-1",
             "title": "the month does not carry", "shots": ["shot-walk-01-j1"],
             "status": "held"}]

    def twice(self, **over):
        v1 = {"score": "low", "derivation": HEADLINE,
              "counts": {"met": 0, "gap": 1, "untested": 0},
              "criteria": self.V1_CRIT, "gaps": [], "alsoChecked": []}
        v2 = {"score": "low", "derivation": "the re-check's own sentence.",
              "counts": {"met": 0, "gap": 1, "untested": 0},
              "criteria": self.V2_CRIT, "gaps": [], "alsoChecked": [],
              "observations": [{"says": "the month did not carry",
                                "kind": "carried-value",
                                "shot": "recheck-walk-01-j1"}]}
        report = {"score": "low", "score2": "low", "status": "finished",
                  "engine": "copilot", "verdict": v1, "verdict2": v2,
                  "logs": self.LOGS, "shotsDir": "look-1",
                  "shotsDir2": "recheck-3", "journal": []}
        report.update(over)
        mi = {"id": "lcars-20260920-001-8cb0", "issue": 9, "stage": "verify",
              "title": "the MBR builder",
              "numberOne": {"status": "finished", "engine": "copilot",
                            "score": "low", "headline": HEADLINE,
                            "report": report}}
        return _run(TAB_HARNESS, mi)

    def _srcs(self, node):
        return [n["src"] for n in _flatten(node)
                if n["tag"] == "img" and n.get("src")]

    def test_a_ledger_row_asks_for_the_re_checks_own_directory(self):
        out = self.twice()
        item = _cls_of(out["pane"], " xo-item ")[0]
        srcs = self._srcs(item)
        self.assertEqual(1, len(srcs), "the row drew no picture at all")
        self.assertIn("/recheck-3/recheck-walk-01-j1.png", srcs[0])
        self.assertNotIn("/look-1/", srcs[0],
                         "the re-check's shot was asked for from the first look")

    def test_a_measured_finding_with_a_shot_draws_it_too(self):
        """The captain also sees "No picture — a measured box settled this
        one" — right when the record has no shot, wrong when it has one."""
        out = self.twice()
        obs = _cls_of(out["pane"], " xo-obs ")
        self.assertTrue(obs, "the measured finding is not on the pane")
        srcs = self._srcs(obs[0])
        self.assertEqual(1, len(srcs))
        self.assertIn("/recheck-3/", srcs[0])
        self.assertNotIn("No picture", _all_text(obs[0]))

    def test_the_filed_gaps_thumbnails_still_come_off_the_first_look(self):
        """These were never broken and must not be 'fixed'. The gap was filed
        ON the first look; its picture is the one that look took."""
        out = self.twice()
        srcs = [s for s in self._srcs(out["pane"]) if "shot-walk-01-j1" in s]
        self.assertTrue(srcs, "the filed gap's thumbnail vanished")
        for s in srcs:
            self.assertIn("/look-1/", s)

    def test_one_look_only_still_reads_its_own_directory(self):
        out = self.twice(score2=None, verdict2=None, shotsDir2=None)
        srcs = self._srcs(_cls_of(out["pane"], " xo-item ")[0])
        self.assertIn("/look-1/shot-walk-01-j1.png", srcs[0])

    def test_no_second_directory_on_the_payload_changes_nothing(self):
        """An older daemon, or a re-check whose directory could not be
        resolved: the pane falls back rather than composing a broken URL."""
        out = self.twice(shotsDir2=None)
        srcs = self._srcs(_cls_of(out["pane"], " xo-item ")[0])
        self.assertIn("/look-1/recheck-walk-01-j1.png", srcs[0])


if __name__ == "__main__":
    unittest.main()

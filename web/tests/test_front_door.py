"""S184 — ESTABLISH VISION: the day-zero front door.

TWO things are under test, and the FIRST one is the captain's blocking
criterion, written before the front door itself existed:

  1. THE BOARD STILL RENDERS. A repo with a working test foundation (`ready`),
     an initialized-but-unconfigured repo (`unconfigured`), a view-only build,
     the GitHub adapter, and — the case measured on the captain's own machine —
     a repo whose foundation verdict LOCKS but which already has missions on its
     board (`Flappy-Bird`: initialized, `untested`, two live missions). Every one
     of those renders the normal board with working controls. The front door
     eating a healthy repo's board is the worst thing this session could ship.

  2. THE FRONT DOOR REPLACES THE BOARD, but only where there is nothing to put
     on it: no columns in the DOM, the three screens of the captain's approved
     mockup, real detected facts on the `untested` screen, and a recommendation
     that can be REFUSED — with the override being what lands.

The adapter half (`meta.frontDoor`) and the render half (board.js through the
REAL `render()`) are both driven, because the rule is a conjunction and either
half getting it wrong deletes a board.
"""
import json
import os
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from tests import _fixtures as fx  # noqa: E402
from tests import test_log_filing_band as css  # noqa: E402
from lcars_serve.local_adapter import LocalAdapter  # noqa: E402

_HARNESS = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                        "board_frontdoor_harness.js")
_REPO_ROOT = os.path.normpath(os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", ".."))
_EV = os.path.join(_REPO_ROOT, "skills", "lcars-init", "establish-vision.sh")


# ── the render harness ─────────────────────────────────────────────────────
def _render(board, readonly=False, act=None, **kw):
    payload = {"board": board, "readonly": readonly, "act": act}
    payload.update(kw)
    fd, path = tempfile.mkstemp(suffix=".json")
    with os.fdopen(fd, "w") as fh:
        json.dump(payload, fh)
    try:
        proc = subprocess.run(["node", _HARNESS, path], stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, timeout=60)
    finally:
        os.unlink(path)
    if proc.returncode != 0:
        raise AssertionError("harness failed: %s"
                             % proc.stderr.decode("utf-8", "replace"))
    return json.loads(proc.stdout.decode("utf-8"))


STAGES = ["align", "research", "validate", "plan", "plan-review", "schedule",
          "implement", "verify", "done"]
# The number of columns a HEALTHY board paints — board.js's STAGE_META, read
# from the shipping file rather than restated, so this suite cannot pass a build
# whose column set has silently changed.
_BOARD_JS = os.path.join(_REPO_ROOT, "web", "static", "board.js")


def _column_count():
    src = open(_BOARD_JS, encoding="utf-8").read()
    block = src.split("var STAGE_META = [", 1)[1].split("];", 1)[0]
    return len([ln for ln in block.splitlines() if ln.strip().startswith("[")])


COLUMNS = _column_count()


def _board(meta=None, missions=()):
    cols = {}
    ms = []
    for m in missions:
        cols.setdefault(m.get("stage", "align"), []).append(m)
        ms.append(m)
    return {"stages": STAGES, "columns": cols, "missions": ms,
            "meta": dict(meta or {})}


def _card(mid, stage="plan"):
    return {"id": mid, "title": "a real mission", "stage": stage,
            "type": "feature", "awaitingHuman": False, "paused": False}


def _flatten(node, out=None):
    if out is None:
        out = []
    if node:
        out.append(node)
        for c in node.get("children", []):
            _flatten(c, out)
    return out


def _text(node):
    return " | ".join(n["text"] for n in _flatten(node) if n.get("text"))


# ── fixture repos on disk, for the ADAPTER half ────────────────────────────
def _git_repo(root):
    os.makedirs(root, exist_ok=True)
    for cmd in (["git", "init", "-q"],
                ["git", "config", "user.email", "t@t"],
                ["git", "config", "user.name", "t"],
                ["git", "commit", "-q", "--allow-empty", "-m", "init"]):
        subprocess.run(cmd, cwd=root, stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL)
    return root


def _config(root, test_command="null"):
    p = os.path.join(root, ".git", "lcars", "config.json")
    fx.write(p, '{\n  "model": "claude-sonnet",\n  "stack": "unknown",\n'
                '  "testCommand": %s\n}\n' % test_command)


class BoardStillRendersTest(unittest.TestCase):
    """THE CAPTAIN'S BLOCKING CRITERION. Written first, kept green throughout."""

    def test_ready_repo_renders_the_board_with_working_controls(self):
        b = _board(meta={"adapter": "local"}, missions=[_card("m-1")])
        res = _render(b)
        self.assertEqual(res["columns"], COLUMNS,
                         "a ready repo must render every stage column")
        self.assertEqual(res["cards"], 1)
        self.assertTrue(res["frontDoorHidden"], "no front door on a ready repo")
        self.assertNotIn("on-front-door", res["bodyClasses"])
        self.assertFalse(res["fileBtn"]["disabled"],
                         "▦ FILE MISSION must stay live on a ready repo")

    def test_unconfigured_repo_renders_the_board_with_working_controls(self):
        # `unconfigured` = a test system EXISTS, LCARS just has no command for
        # it. S183 deliberately ALLOWS it, so it carries a testReadiness block
        # and NO foundation key — and therefore no front door.
        b = _board(meta={"adapter": "local",
                         "testReadiness": {"status": "missing",
                                           "suggestion": "npx vitest run",
                                           "testCommand": None}},
                   missions=[_card("m-1")])
        res = _render(b)
        self.assertEqual(res["columns"], COLUMNS)
        self.assertTrue(res["frontDoorHidden"])
        self.assertFalse(res["fileBtn"]["disabled"])

    def test_unconfigured_EMPTY_repo_still_renders_the_board(self):
        """The nastiest regression shape: nothing on the board AND no command
        configured. `unconfigured` means the repo HAS a test system, so it can
        take a normal mission — the empty board (and its ▦ FILE MISSION) is the
        correct screen, not an invitation to re-found the project."""
        b = _board(meta={"adapter": "local",
                         "testReadiness": {"status": "missing",
                                           "suggestion": "bundle exec rspec",
                                           "testCommand": None}})
        res = _render(b)
        self.assertEqual(res["columns"], COLUMNS)
        self.assertTrue(res["frontDoorHidden"])
        self.assertFalse(res["fileBtn"]["disabled"])

    def test_foundationless_repo_WITH_missions_still_renders_the_board(self):
        """`Flappy-Bird`, measured on the captain's machine 2026-09-05: an
        INITIALIZED repo, foundation verdict `untested`, TWO real missions on
        its board. The board does not render until there is something to put on
        it — and here there is. S183's lock applies to it instead."""
        b = _board(meta={"adapter": "local", "foundation": "untested",
                         "testReadiness": {"status": "unknown",
                                           "suggestion": None,
                                           "testCommand": None,
                                           "foundation": "untested"}},
                   missions=[_card("m-1", "plan"), _card("m-2", "implement")])
        res = _render(b)
        self.assertEqual(res["columns"], COLUMNS,
                         "a foundationless repo WITH missions keeps its board")
        self.assertEqual(res["cards"], 2, "both missions must still be visible")
        self.assertTrue(res["frontDoorHidden"])
        self.assertNotIn("on-front-door", res["bodyClasses"])
        # …and S183's lock is what protects it, exactly as today.
        self.assertTrue(res["fileBtn"]["disabled"])
        self.assertIn("Establish Vision", res["fileBtn"]["reason"])

    def test_view_only_build_never_gets_the_front_door(self):
        """A view-only board cannot write, and the front door is an invitation
        to DO something. S183's lock is what that build shows instead."""
        b = _board(meta={"adapter": "local", "foundation": "greenfield",
                         "frontDoor": {"foundation": "greenfield",
                                       "stackLabel": "not recognised",
                                       "sourceFiles": 0}})
        res = _render(b, readonly=True)
        self.assertEqual(res["columns"], COLUMNS)
        self.assertTrue(res["frontDoorHidden"])

    def test_github_adapter_never_gets_the_front_door(self):
        b = _board(meta={"adapter": "github", "foundation": "greenfield",
                         "frontDoor": {"foundation": "greenfield",
                                       "stackLabel": "not recognised",
                                       "sourceFiles": 0}})
        res = _render(b)
        self.assertEqual(res["columns"], COLUMNS)
        self.assertTrue(res["frontDoorHidden"])

    def test_the_door_LIFTS_when_a_mission_lands_mid_session(self):
        """A verdict (or a board) that changes WHILE the board is open. The
        front door is re-decided on EVERY render, so the initialization mission
        landing drops it with nothing to reload."""
        fd = {"foundation": "greenfield", "stackLabel": "not recognised",
              "sourceFiles": 0}
        door = _render(_board(meta={"adapter": "local",
                                    "foundation": "greenfield",
                                    "frontDoor": fd}))
        self.assertEqual(door["columns"], 0)
        landed = _render(_board(meta={"adapter": "local",
                                      "foundation": "greenfield",
                                      "frontDoor": fd},
                                missions=[_card("m-1", "align")]))
        self.assertEqual(landed["columns"], COLUMNS)
        self.assertEqual(landed["cards"], 1)
        self.assertTrue(landed["frontDoorHidden"])


class FrontDoorRendersTest(unittest.TestCase):
    """THE FRONT DOOR REPLACES THE BOARD — the three screens of the mockup."""

    GREENFIELD = {"adapter": "local", "foundation": "greenfield",
                  "frontDoor": {"foundation": "greenfield", "stack": "unknown",
                                "stackLabel": "not recognised",
                                "sourceFiles": 0, "testRunner": None}}
    UNTESTED = {"adapter": "local", "foundation": "untested",
                "frontDoor": {"foundation": "untested", "stack": "js",
                              "stackLabel": "JavaScript / Node",
                              "sourceFiles": 47, "testRunner": None}}

    def test_greenfield_renders_the_front_door_and_ZERO_columns(self):
        res = _render(_board(meta=self.GREENFIELD))
        self.assertEqual(res["columns"], 0,
                         "no columns in the DOM on a day-zero repo")
        self.assertEqual(res["cards"], 0)
        self.assertFalse(res["frontDoorHidden"])
        self.assertIn("on-front-door", res["bodyClasses"])

    def test_greenfield_screen_asks_ONE_question_with_ONE_primary_action(self):
        res = _render(_board(meta=self.GREENFIELD))
        txt = _text(res["frontDoor"])
        self.assertIn("New project", txt)
        self.assertIn("What are we building?", txt)
        self.assertIn("Establish vision", txt)
        self.assertIn("Paste a spec instead", txt)
        self.assertIn("lcars update --test-command", txt)
        # the free-text field is there, and NOTHING is greyed out.
        box = [n for n in _flatten(res["frontDoor"]) if n["tag"] == "textarea"]
        self.assertEqual(len(box), 1)
        greyed = [n for n in _flatten(res["frontDoor"])
                  if n["tag"] == "button" and n["disabled"]]
        self.assertEqual(greyed, [], "nothing is withheld on screen 1")

    def test_untested_screen_does_NOT_ask_what_we_are_building(self):
        res = _render(_board(meta=self.UNTESTED))
        txt = _text(res["frontDoor"])
        self.assertNotIn("What are we building", txt,
                         "it can SEE the code — asking is the harness admitting "
                         "it did not look")
        self.assertIn("I can see the code.", txt)
        self.assertIn("I can't prove a change.", txt)
        box = [n for n in _flatten(res["frontDoor"]) if n["tag"] == "textarea"]
        self.assertEqual(box, [], "no idea box on the untested screen")

    def test_untested_found_panel_names_the_REAL_stack_and_file_count(self):
        res = _render(_board(meta=self.UNTESTED))
        txt = _text(res["frontDoor"])
        self.assertIn("JavaScript / Node", txt)
        self.assertIn("47", txt)
        self.assertIn("none found", txt)
        self.assertIn("not possible yet", txt)

    def test_untested_screen_promises_the_code_is_not_touched(self):
        res = _render(_board(meta=self.UNTESTED))
        self.assertIn("Your code is not touched", _text(res["frontDoor"]))

    def test_no_refusal_modal_and_no_dimmed_controls_on_the_front_door(self):
        res = _render(_board(meta=self.GREENFIELD))
        txt = _text(res["frontDoor"])
        self.assertNotIn("NO TEST FOUNDATION", txt)
        self.assertNotIn("cannot run a normal mission", txt)


class BandOnTheFrontDoorTest(unittest.TestCase):
    """FIX ROUND 1 / D1 — the band is part of the shape.

    Measured in real headed Chrome on the first build: the front door promised
    "nothing is being withheld" while ⬡ HOLODECK and ▦ FILE MISSION sat greyed
    out in the band six inches above it — the captain's original complaint about
    S183's board, still on screen. Brief item 1: no dimmed controls.

    THE ASSERTION THAT WOULD HAVE CAUGHT IT is the one that looks at the WHOLE
    document rather than inside #frontDoor, so that is the shape of it here.
    """

    GREENFIELD = FrontDoorRendersTest.GREENFIELD
    BAND = ["deployMainBtn", "mainDeploy", "holodeckBtn", "fileBtn", "helpBtn"]

    def test_no_VISIBLE_disabled_control_anywhere_on_the_front_door(self):
        res = _render(_board(meta=self.GREENFIELD))
        showing = [c for c in res["controls"] if c["disabled"] and not c["hidden"]]
        self.assertEqual(
            showing, [],
            "a day-zero screen must carry no greyed-out control anywhere — "
            "found: %r" % (showing,))

    def test_the_board_controls_are_hidden_from_the_band(self):
        res = _render(_board(meta=self.GREENFIELD))
        for cid in self.BAND:
            self.assertTrue(res["band"][cid]["hidden"],
                            "%s must not sit in the band on the front door" % cid)

    def test_the_band_keeps_its_controls_on_a_normal_board(self):
        """Presentation-only, and only here. A healthy board is unchanged."""
        res = _render(_board(meta={"adapter": "local"}, missions=[_card("m-1")]))
        for cid in self.BAND:
            self.assertFalse(res["band"][cid]["hidden"],
                             "%s must come back the moment the board renders" % cid)
        self.assertFalse(res["band"]["fileBtn"]["disabled"])

    def test_the_band_comes_BACK_when_the_door_lifts(self):
        """The door lifting is an SSE tick, not a reload — the restore has to
        happen on the same path the hide did."""
        fd = {"foundation": "greenfield", "stackLabel": "not recognised",
              "sourceFiles": 0}
        meta = {"adapter": "local", "foundation": "greenfield", "frontDoor": fd}
        door = _render(_board(meta=meta))
        self.assertTrue(door["band"]["fileBtn"]["hidden"])
        landed = _render(_board(meta=meta, missions=[_card("m-1", "align")]))
        for cid in self.BAND:
            self.assertFalse(landed["band"][cid]["hidden"])

    def test_S183s_lock_is_still_painted_underneath(self):
        """Hidden, never disarmed: `paintFoundationLock` still runs on the front
        door, so the control it protects is locked as well as out of sight and
        the board path cannot inherit a half-painted state."""
        res = _render(_board(meta=self.GREENFIELD))
        self.assertTrue(res["fileBtn"]["disabled"])
        self.assertIn("Establish Vision", res["fileBtn"]["reason"])


class SliceIsANounPhraseTest(unittest.TestCase):
    """FIX ROUND 1 / D3 — the template supplies the sentence; `slice` completes
    it. A live model's output shape is a lottery (S175), so assume prose."""

    META = FrontDoorRendersTest.GREENFIELD

    def _fence_line(self, slice_text):
        rec = {"stack": "Vite + React + Vitest", "reasons": ["r"],
               "slice": slice_text, "deferred": ["budgets"]}
        res = _render(_board(meta=self.META), act="recommend", rec=rec)
        lines = [n["text"] for n in _flatten(res["frontDoor"])
                 if n["text"].startswith("One thin vertical slice")]
        self.assertEqual(len(lines), 1)
        return lines[0]

    def test_a_noun_phrase_renders_as_one_clean_sentence(self):
        line = self._fence_line("importing a CSV row and showing it")
        self.assertEqual(
            line,
            "One thin vertical slice that proves both: importing a CSV row and "
            "showing it.")

    def test_a_model_that_hands_back_PROSE_does_not_double_the_label(self):
        """The exact string measured in the drive, label and all."""
        line = self._fence_line(
            "A running app, a working test system, and one thin slice that "
            "proves both \u2014 importing a CSV row and showing it.")
        self.assertEqual(
            line,
            "One thin vertical slice that proves both: importing a CSV row and "
            "showing it.")
        self.assertNotIn("..", line)
        self.assertEqual(line.lower().count("thin"), 1,
                         "the label must be said once, not twice")

    def test_a_trailing_full_stop_is_never_doubled(self):
        self.assertNotIn("..", self._fence_line("the app boots."))
        self.assertNotIn("..", self._fence_line("the app boots"))
        self.assertNotIn("..", self._fence_line("the app boots.  "))

    def test_an_empty_slice_falls_back_to_a_readable_sentence(self):
        line = self._fence_line("")
        self.assertTrue(line.endswith("."))
        self.assertNotIn("..", line)


class RecommendationTest(unittest.TestCase):
    """Screen 3 — the recommendation, the scope fence, and the override."""

    META = FrontDoorRendersTest.GREENFIELD
    REC = {"stack": "Vite + React + Vitest",
           "reasons": ["Your spending dashboard and charts are a browser UI.",
                       "\"Bank sync\" is async data you'll want to fake in a test."],
           "slice": "the app boots and renders its shell",
           "deferred": ["budgets", "Plaid bank sync", "savings goals"],
           "idea": "a website that does personal finance stuff"}

    def _screen(self):
        return _render(_board(meta=self.META), act="recommend", rec=self.REC)

    def test_the_recommendation_is_named_and_reasoned(self):
        txt = _text(self._screen()["frontDoor"])
        self.assertIn("Vite + React + Vitest", txt)
        self.assertIn("spending dashboard", txt)
        self.assertIn("Bank sync", txt)

    def test_the_scope_fence_is_IN_THE_RENDERED_OUTPUT(self):
        txt = _text(self._screen()["frontDoor"])
        self.assertIn("What this first mission builds", txt)
        self.assertIn("running skeleton", txt)
        self.assertIn("test system", txt)
        self.assertIn("thin vertical slice", txt)

    def test_the_deferred_features_are_NAMED_as_deferred_on_screen(self):
        txt = self._screen()["frontDoor"]
        flat = _text(txt)
        for feature in ("budgets", "Plaid bank sync", "savings goals"):
            self.assertIn(feature, flat)
        self.assertIn("becomes a normal mission once the foundation lands", flat)

    def test_choose_a_different_stack_sits_BESIDE_accept(self):
        """A recommendation the captain cannot refuse is a decision. Both
        controls are buttons, both are enabled, and they are siblings in ONE
        actions row — never an override behind a menu."""
        res = self._screen()
        rows = [n for n in _flatten(res["frontDoor"])
                if "fd-actions" in (n["cls"] or "").split()]
        self.assertEqual(len(rows), 1)
        labels = [c["text"] for c in rows[0]["children"] if c["tag"] == "button"]
        self.assertIn("✓ Accept & file mission", labels)
        self.assertIn("⇄ Choose a different stack", labels)
        for c in rows[0]["children"]:
            self.assertFalse(c["disabled"])

    def test_accepting_files_the_mission_with_the_recommended_stack(self):
        res = _render(_board(meta=self.META), act="accept", rec=self.REC)
        posts = [f for f in res["fetches"] if f["method"] == "POST"]
        self.assertTrue(posts, "accept must dispatch a filing")
        self.assertEqual(posts[0]["url"], "/api/vision/file")
        body = json.loads(posts[0]["body"])
        self.assertEqual(body["stack"], "Vite + React + Vitest")
        self.assertEqual(body["deferred"], self.REC["deferred"])
        self.assertEqual(body["slice"], self.REC["slice"])

    def test_the_OVERRIDE_is_what_lands(self):
        res = _render(_board(meta=self.META), act="override", rec=self.REC,
                      override="SvelteKit + Playwright")
        posts = [f for f in res["fetches"] if f["method"] == "POST"]
        self.assertTrue(posts, "the override must dispatch a filing")
        self.assertEqual(posts[0]["url"], "/api/vision/file")
        body = json.loads(posts[0]["body"])
        self.assertEqual(body["stack"], "SvelteKit + Playwright")
        self.assertNotEqual(body["stack"], self.REC["stack"])

    def test_the_grill_runs_the_EXISTING_align_console_in_vision_mode(self):
        """Brief item 5: reuse the Align machinery, never a second interviewer.
        The proof is the endpoint it posts to."""
        res = _render(_board(meta=self.META), act="submit",
                      text="a website that does personal finance stuff")
        posts = [f for f in res["fetches"] if f["method"] == "POST"]
        self.assertTrue(posts)
        self.assertEqual(posts[0]["url"], "/api/align/start")
        body = json.loads(posts[0]["body"])
        self.assertTrue(body["vision"], "the grill must run in VISION mode")
        self.assertIn("personal finance", body["idea"])


class TurnsTheDaemonActuallySendsTest(unittest.TestCase):
    """D10 — THE HARNESS DRIVES THE REAL RESPONSE, NOT AN IMAGINED ONE.

    Every screen-3 test above reaches the recommendation with
    `act="recommend", rec={...}` — it calls the RENDERER directly and supplies
    the field the server never sent. That is why three blockers survived 36
    green tests and died on the first turn in real Chrome:

      D1  the client read `t.sid`; the daemon sends `sessionId`. Every answer
          re-opened a brand-new grill (19 live turns, 19 fresh session ids,
          ZERO resumes).
      D2  nothing anywhere could produce a `recommendation`, so screen 3 was
          unreachable (0 of 19 live turns; 0 missions filed from the board).
      D3  `question` is an OBJECT and was appended as one — the captain read
          `[object Object]` on every turn of both live runs.

    So the payloads below are COPIED FROM `actions.py`'s own `out = {...}`
    dicts (`_align_turn`'s question return and its vision return), not from
    this test's imagination, and they are fed through `frontDoorSubmit` →
    `frontDoorTurn` → the repaint.
    """

    META = FrontDoorRendersTest.GREENFIELD
    SID = "9f2c41ab77de"

    # `_align_turn`'s question return, verbatim in shape:
    #   {"sessionId": sid, "status": "question", "question": q, "prd": sess.prd}
    # `question` is the worker's own dict — text + choices + recommended, as
    # measured on every live turn in tests/drives/s184/logs/live3|live4.
    Q1 = {"sessionId": SID, "status": "question",
          "question": {
              "text": "Let's pin down what this actually is before we talk "
                      "stack — my read is a budget/expense tracker. Does that "
                      "match what's in your head?",
              "choices": ["Budget/expense tracker (log & categorize spending)",
                          "Investment / portfolio tracking",
                          "Something else"],
              "recommended": "Budget/expense tracker (log & categorize "
                             "spending)"},
          "prd": "# Mission: Establish foundation\n\n**Type:** feature\n"}
    Q2 = {"sessionId": SID, "status": "question",
          "question": {"text": "Which of those do you want the first slice to "
                               "touch?"},
          "prd": "# Mission: Establish foundation\n\n**Type:** feature\n"}
    # `_align_turn`'s VISION return — the shape this round adds.
    REC = {"sessionId": SID, "status": "recommendation",
           "recommendation": {
               "stack": "Vite + React + Vitest",
               "reasons": ["Your spending dashboard and charts are a browser UI.",
                           "\"Bank sync\" is async data you'll want to fake."],
               "slice": "importing a CSV row and showing it",
               "deferred": ["budgets", "Plaid bank sync"]},
           "prd": "# Mission: Establish foundation\n\n**Type:** feature\n"}

    def _grill(self, turns, responses):
        return _render(_board(meta=self.META), act="grill", turns=turns,
                       responses=responses)

    def _posts(self, res):
        """Every POST the page made EXCEPT board.js's boot write-probe
        (`probeWrites` — a bare POST /api/mission with an empty body, whose
        only job is to learn whether the write layer is live)."""
        return [f for f in res["fetches"]
                if f["method"] == "POST" and f["url"] != "/api/mission"]

    def test_the_SECOND_answer_RESUMES_the_session_instead_of_restarting_it(self):
        """D1. The measured defect: turn 2 posted to /api/align/start again with
        the captain's ANSWER as a fresh idea, so the grill forgot everything —
        including a stack it had just locked in — forever."""
        res = self._grill(["a website that does personal finance stuff",
                           "yes, a budget tracker"],
                          [self.Q1, self.Q2])
        posts = self._posts(res)
        self.assertEqual(len(posts), 2, "two answers must be two POSTs")
        self.assertEqual(posts[0]["url"], "/api/align/start")
        self.assertEqual(
            posts[1]["url"], "/api/align/%s/answer" % self.SID,
            "the second turn must RESUME the session the daemon opened — a "
            "second /api/align/start is a brand-new grill with no memory")
        self.assertEqual(json.loads(posts[1]["body"])["answer"],
                         "yes, a budget tracker")

    def test_the_QUESTION_TEXT_is_what_reaches_the_screen(self):
        """D3. Measured in real headed Chrome on EVERY grill turn of both live
        runs: the captain was shown the literal string `[object Object]`."""
        res = self._grill(["a website that does personal finance stuff"],
                          [self.Q1])
        txt = _text(res["frontDoor"])
        self.assertNotIn("[object Object]", txt,
                         "the question object was appended instead of its text")
        self.assertIn("budget/expense tracker", txt)

    def test_the_models_CHOICES_are_offered_as_selectable_options(self):
        """The live model returned `choices` on most turns and the screen threw
        every one of them away, leaving a free-text box under a question that
        had already listed its answers."""
        res = self._grill(["a website that does personal finance stuff"],
                          [self.Q1])
        buttons = [n["text"] for n in _flatten(res["frontDoor"])
                   if n["tag"] == "button"]
        self.assertTrue(
            any("Investment / portfolio tracking" in b for b in buttons),
            "the model's choices are not on screen as options: %r" % buttons)

    def test_choosing_an_option_ANSWERS_with_it_on_the_same_session(self):
        res = _render(_board(meta=self.META), act="choose",
                      text="a website that does personal finance stuff",
                      choice="Investment / portfolio tracking",
                      responses=[self.Q1, self.Q2])
        posts = self._posts(res)
        self.assertEqual(len(posts), 2)
        self.assertEqual(posts[1]["url"], "/api/align/%s/answer" % self.SID)
        self.assertEqual(json.loads(posts[1]["body"])["answer"],
                         "Investment / portfolio tracking")

    def test_a_RECOMMENDATION_turn_advances_the_captain_to_screen_3(self):
        """D2. The whole point of the door: 0 of 19 live turns got here, and 0
        missions were filed from the viewscreen."""
        res = self._grill(["a website that does personal finance stuff",
                           "yes, a budget tracker"],
                          [self.Q1, self.REC])
        # …and it got here on the SAME session, which is the other half of the
        # measured failure: a recommendation reached by re-opening the grill is
        # a recommendation for a conversation that never happened.
        self.assertEqual(self._posts(res)[1]["url"],
                         "/api/align/%s/answer" % self.SID)
        txt = _text(res["frontDoor"])
        self.assertIn("Vite + React + Vitest", txt)
        self.assertIn("What this first mission builds", txt)
        self.assertIn("importing a CSV row and showing it", txt)
        self.assertIn("Plaid bank sync", txt)
        labels = [n["text"] for n in _flatten(res["frontDoor"])
                  if n["tag"] == "button"]
        self.assertIn("✓ Accept & file mission", labels)

    def test_a_REAL_grill_files_the_mission_end_to_end(self):
        """The whole viewscreen road in one test: idea → question → answer →
        recommendation → ✓ Accept → `/api/vision/file`. This is what the live
        drive could not do once in 19 turns."""
        res = _render(_board(meta=self.META), act="grill",
                      turns=["a website that does personal finance stuff",
                             "yes, a budget tracker"],
                      responses=[self.Q1, self.REC, {"board": {}}],
                      then="accept")
        posts = self._posts(res)
        self.assertEqual([p["url"] for p in posts],
                         ["/api/align/start",
                          "/api/align/%s/answer" % self.SID,
                          "/api/vision/file"])
        body = json.loads(posts[2]["body"])
        self.assertEqual(body["stack"], "Vite + React + Vitest")
        self.assertEqual(body["slice"], "importing a CSV row and showing it")
        self.assertEqual(body["deferred"], ["budgets", "Plaid bank sync"])
        self.assertIn("personal finance", body["idea"],
                      "the captain's own words must reach the vision doc")

    def test_the_grill_screen_says_a_CONVERSATION_is_under_way(self):
        """D6 — the grill wore screen 1's heading ('WHAT ARE WE BUILDING?' over
        'Describe it however you like…') while a completely different question
        was being asked underneath it."""
        res = self._grill(["a website that does personal finance stuff"],
                          [self.Q1])
        txt = _text(res["frontDoor"])
        self.assertNotIn("What are we building?", txt,
                         "the grill still wears screen 1's heading")
        self.assertNotIn("Describe it however you like", txt,
                         "the grill still wears screen 1's lede")


class AdapterFrontDoorTest(unittest.TestCase):
    """The daemon half: `meta.frontDoor` is POSITIVE and NARROW."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()

    def _adapter(self, root):
        return LocalAdapter(root, establish_vision_script=_EV)

    def test_blank_repo_gets_a_front_door_payload(self):
        root = _git_repo(os.path.join(self.tmp, "blank"))
        meta = self._adapter(root).board()["meta"]
        self.assertEqual(meta.get("foundation"), "greenfield")
        self.assertEqual(meta["frontDoor"]["foundation"], "greenfield")
        self.assertEqual(meta["frontDoor"]["sourceFiles"], 0)
        self.assertIsNone(meta["frontDoor"]["testRunner"])

    def test_untested_repo_payload_carries_REAL_detection(self):
        root = _git_repo(os.path.join(self.tmp, "react"))
        fx.write(os.path.join(root, "package.json"),
                 '{"name":"a","scripts":{"dev":"vite"},'
                 '"dependencies":{"react":"^18"}}\n')
        fx.write(os.path.join(root, "src", "App.jsx"), "export default 1\n")
        fx.write(os.path.join(root, "src", "main.jsx"), "export const x=1\n")
        meta = self._adapter(root).board()["meta"]
        self.assertEqual(meta["frontDoor"]["foundation"], "untested")
        self.assertEqual(meta["frontDoor"]["stack"], "js")
        # FIX ROUND 1 / D4 — the LABEL is framework-level, not the classifier
        # key. This panel's whole job is to prove LCARS looked at the code, and
        # "JavaScript / Node" on a real React app proves it did not look far.
        self.assertEqual(meta["frontDoor"]["stackLabel"], "React")
        self.assertGreaterEqual(meta["frontDoor"]["sourceFiles"], 3)

    def test_the_captains_measured_case_reads_React_plus_Vite_TypeScript(self):
        """His repo, his panel: a real Vite+React+TS app must be NAMED."""
        root = _git_repo(os.path.join(self.tmp, "reactvitets"))
        fx.write(os.path.join(root, "package.json"),
                 '{"name":"a","dependencies":{"react":"^18","react-dom":"^18"},'
                 '"devDependencies":{"vite":"^5","typescript":"^5"}}\n')
        fx.write(os.path.join(root, "tsconfig.json"), "{}\n")
        fx.write(os.path.join(root, "src", "App.tsx"), "export const a=1\n")
        meta = self._adapter(root).board()["meta"]
        self.assertEqual(meta["frontDoor"]["stackLabel"],
                         "React + Vite \u00b7 TypeScript")

    def test_a_plain_node_repo_keeps_the_honest_coarse_fallback(self):
        """Nothing more specific found ⇒ say the true coarse thing, never guess
        a framework that is not there."""
        root = _git_repo(os.path.join(self.tmp, "plainnode"))
        fx.write(os.path.join(root, "package.json"),
                 '{"name":"a","dependencies":{"express":"^4"}}\n')
        fx.write(os.path.join(root, "src", "i.js"), "const a=1\n")
        meta = self._adapter(root).board()["meta"]
        self.assertEqual(meta["frontDoor"]["stackLabel"], "JavaScript / Node")

    def test_a_repo_WITH_missions_gets_NO_front_door_key(self):
        """The `Flappy-Bird` shape, at the adapter. The lock still rides
        `meta.foundation`; the board-replacing key does not appear."""
        root = _git_repo(os.path.join(self.tmp, "withm"))
        fx.write(os.path.join(root, "package.json"), '{"name":"g"}\n')
        fx.write(os.path.join(root, "src", "a.js"), "const a=1\n")
        _config(root)
        fx.write_json(os.path.join(root, ".git", "lcars", "missions", "m-1",
                                   "state.json"),
                      {"id": "m-1", "title": "t", "stage": "plan",
                       "type": "feature", "created": "2026-01-01T00:00:00Z"})
        meta = self._adapter(root).board()["meta"]
        self.assertEqual(meta.get("foundation"), "untested",
                         "S183's lock still applies")
        self.assertNotIn("frontDoor", meta,
                         "the board must not be replaced — it has a card on it")

    def test_a_ready_repo_carries_NEITHER_key(self):
        root = _git_repo(os.path.join(self.tmp, "ready"))
        fx.write(os.path.join(root, "package.json"),
                 '{"name":"a","scripts":{"test":"vitest run"},'
                 '"devDependencies":{"vitest":"^1"}}\n')
        fx.write(os.path.join(root, "src", "a.js"), "const a=1\n")
        _config(root, '"npx vitest run"')
        meta = self._adapter(root).board()["meta"]
        self.assertNotIn("frontDoor", meta)
        self.assertNotIn("foundation", meta)

    def test_a_missing_helper_never_replaces_a_board(self):
        """An absence of information is never a reason to take the board away."""
        root = _git_repo(os.path.join(self.tmp, "nohelper"))
        ad = LocalAdapter(root, establish_vision_script="/nope/missing.sh")
        meta = ad.board()["meta"]
        self.assertNotIn("frontDoor", meta)

    # ── S195: the ENGINE facts ride the same payload ──────────────────────
    def _with_bins(self, claude, copilot):
        """Pin what this machine 'has', through the SAME env seams `lcars init`
        verifies the claude CLI through — so the assertion is about the
        detector, not about whichever CLIs happen to be installed here."""
        old = {k: os.environ.get(k)
               for k in ("LCARS_CLAUDE_BIN", "LCARS_COPILOT_BIN")}

        def restore():
            for k, v in old.items():
                if v is None:
                    os.environ.pop(k, None)
                else:
                    os.environ[k] = v
        self.addCleanup(restore)
        os.environ["LCARS_CLAUDE_BIN"] = claude
        os.environ["LCARS_COPILOT_BIN"] = copilot

    def _fake_bin(self, name):
        p = os.path.join(self.tmp, "bin", name)
        fx.write(p, "#!/bin/sh\nexit 0\n")
        os.chmod(p, 0o755)
        return p

    def test_the_front_door_payload_carries_the_INSTALLED_engines(self):
        root = _git_repo(os.path.join(self.tmp, "engines"))
        self._with_bins(self._fake_bin("claude"), self._fake_bin("copilot"))
        fd = self._adapter(root).board()["meta"]["frontDoor"]
        self.assertEqual(fd["engines"], ["claude", "copilot"])
        self.assertEqual(fd["engine"], "claude")

    def test_an_engine_that_is_not_installed_is_left_out_of_the_payload(self):
        root = _git_repo(os.path.join(self.tmp, "engines1"))
        self._with_bins(os.path.join(self.tmp, "nope-claude"),
                        self._fake_bin("copilot"))
        fd = self._adapter(root).board()["meta"]["frontDoor"]
        self.assertEqual(fd["engines"], ["copilot"])
        self.assertEqual(fd["engine"], "copilot",
                         "the one available engine is the preselection")



# ══════════════════════════════════════════════════════════════════════════
# THE HOLODECK FLOOR UNDER THE FRONT DOOR
# ══════════════════════════════════════════════════════════════════════════
class VisionGrillDaemonTest(unittest.TestCase):
    """D2 + D4 + D9 — the DAEMON half of the grill, driven with a stub worker.

    D2: nothing anywhere could produce a `recommendation`. The align envelope's
        OUTPUT CONTRACT offered only `question` and `done`; the foundation
        brief's "WHAT TO HAND BACK" had no JSON slot and no parser. Screen 3 was
        unreachable — 0 of 19 live turns, 0 missions filed from the board.
    D4: and a vision-mode `done` finalized through `file.sh --prd` with NO
        `--initialization`, so it would have been refused by the S183 foundation
        gate (exit 4) on the very repo the mission exists to give a foundation.
    D9: the prompt carried two contradictory fences — SKILL.md's STEP 0 ("run
        foundation-gate.sh, STOP on exit 20") under a brief saying the opposite.

    A LIVE MODEL'S OUTPUT SHAPE IS A LOTTERY (S175). So the parser is tested
    against the shapes a real model plausibly returns — the ideal object, the
    same thing hung off the question, newline-separated prose instead of lists,
    and a slice handed back as a whole sentence — not only the one we asked for.
    Zero spend: the worker is `test_align_endpoints._worker_stub`, a bash script.
    """

    @classmethod
    def setUpClass(cls):
        from tests import test_align_endpoints as ae
        cls.ae = ae

    def setUp(self):
        import shutil
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, True)
        _git_repo(self.tmp)
        self.turns = os.path.join(self.tmp, "turns.txt")
        self.prompts = os.path.join(self.tmp, "prompts.txt")
        self.argvs = os.path.join(self.tmp, "argv.txt")
        self.rec_file = os.path.join(self.tmp, "rec-file.txt")
        self.scripts = {"file": self.ae._file_record_stub(self.rec_file)}
        self.worker = self.ae._worker_stub(self.turns, self.prompts, self.argvs)
        from lcars_serve.actions import Actions
        self.actions = Actions(repo_root=self.tmp, scripts=self.scripts,
                               worker_bin=self.worker)

    def _give_it_a_foundation(self):
        """The CONTROL repo for the normal-mission tests. A vision grill is
        exempt from the S183 foundation gate; an ordinary one is refused by it
        (correctly), so a normal-path control has to run somewhere the gate lets
        the console open at all."""
        _config(self.tmp, '"npm test"')

    def _set_turns(self, *blobs):
        with open(self.turns, "w") as fh:
            for i, b in enumerate(blobs):
                if i:
                    fh.write("===TURN===\n")
                fh.write(json.dumps(b) + "\n")

    def _filed_argv(self):
        if not os.path.exists(self.rec_file):
            return ""
        with open(self.rec_file) as fh:
            return fh.read()

    def _prompt(self):
        with open(self.prompts) as fh:
            return fh.read()

    # ── D2: the recommendation is READ off the turn ────────────────────────
    IDEAL = {"status": "recommendation",
             "recommendation": {
                 "stack": "Vite + React + Vitest",
                 "reasons": ["Your spending dashboard is a browser UI.",
                             "Bank sync is async data you'll want to fake."],
                 "slice": "importing a CSV row and showing it",
                 "deferred": ["budgets", "Plaid bank sync"]},
             "prd": "# Mission: Foundation\n\n**Type:** feature\n"}

    def test_a_vision_turn_hands_the_RECOMMENDATION_back_to_the_board(self):
        self._set_turns(self.IDEAL)
        out = self.actions.align_start("a personal finance site", vision=True)
        self.assertEqual(out["status"], "recommendation")
        rec = out["recommendation"]
        self.assertEqual(rec["stack"], "Vite + React + Vitest")
        self.assertEqual(rec["slice"], "importing a CSV row and showing it")
        self.assertEqual(rec["deferred"], ["budgets", "Plaid bank sync"])
        self.assertEqual(len(rec["reasons"]), 2)
        self.assertIn("sessionId", out)

    def test_a_recommendation_HUNG_OFF_THE_QUESTION_is_still_read(self):
        """One of the honest shapes: the model keeps its `question` wrapper and
        posts the hand-back inside it."""
        self._set_turns({"status": "question",
                         "question": {"text": "Here's my recommendation.",
                                      "recommendation": self.IDEAL["recommendation"]},
                         "prd": "# Mission: F\n"})
        out = self.actions.align_start("a personal finance site", vision=True)
        self.assertEqual(out["status"], "recommendation")
        self.assertEqual(out["recommendation"]["stack"], "Vite + React + Vitest")

    def test_PROSE_instead_of_lists_is_accepted(self):
        """The brief asks for reasons and deferred features 'one per line'. A
        real model hands back a newline-joined string about as often as a JSON
        array — and may bullet them."""
        self._set_turns({"status": "recommendation",
                         "recommendation": {
                             "stack": "Vite + React + Vitest",
                             "reasons": "- It is a browser UI.\n- Async data.",
                             "slice": "importing a CSV row and showing it",
                             "deferred": "budgets\nPlaid bank sync\n"}})
        rec = self.actions.align_start("x", vision=True)["recommendation"]
        self.assertEqual(rec["reasons"], ["It is a browser UI.", "Async data."])
        self.assertEqual(rec["deferred"], ["budgets", "Plaid bank sync"])

    def test_a_SENTENCE_slice_is_normalised_exactly_as_the_CLI_normalises_it(self):
        """`ev_norm_slice` and `frontDoorSlice` already strip the restated
        label; the daemon must not be the third opinion."""
        self._set_turns({"status": "recommendation",
                         "recommendation": {
                             "stack": "Vite + React + Vitest",
                             "slice": "One thin vertical slice that proves "
                                      "both: importing a CSV row and showing "
                                      "it."}})
        rec = self.actions.align_start("x", vision=True)["recommendation"]
        self.assertEqual(rec["slice"], "importing a CSV row and showing it")

    def test_a_recommendation_with_NO_STACK_is_not_a_recommendation(self):
        """`stack` is the one field the whole screen is about. Without it the
        turn is still a question and the grill goes on."""
        self._set_turns({"status": "question",
                         "question": {"text": "What are we building?",
                                      "recommendation": {"reasons": ["x"]}},
                         "prd": "# Mission: F\n"})
        out = self.actions.align_start("x", vision=True)
        self.assertEqual(out["status"], "question")
        self.assertNotIn("recommendation", out)

    def test_a_NORMAL_align_turn_NEVER_grows_a_recommendation(self):
        """The blast radius. Hand an ORDINARY mission's console a turn carrying
        BOTH a well-formed question and a recommendation object: it must read
        the question, exactly as it always did, and the new key must not leak
        into the response. Nothing about a normal mission changes."""
        self._give_it_a_foundation()
        self._set_turns({"status": "question",
                         "question": {"text": "Global or per-course?",
                                      "recommendation": self.IDEAL["recommendation"]},
                         "recommendation": self.IDEAL["recommendation"],
                         "prd": "# Mission: G\n\n**Type:** feature\n"})
        out = self.actions.align_start("add a leaderboard", vision=False)
        self.assertEqual(out["status"], "question")
        self.assertEqual(out["question"]["text"], "Global or per-course?")
        self.assertNotIn("recommendation", out)

    # ── D4: a vision DONE files through the INITIALIZATION path ────────────
    DONE = {"status": "done",
            "prd": "# Mission: Establish the foundation\n\n"
                   "**Type:** feature\n\n**Goal:** a foundation\n\n"
                   "**Acceptance Criteria:**\n- it boots\n\n"
                   "**Out of Scope:** features\n\n**Constraints:** none\n"}

    def test_a_vision_DONE_files_through_the_INITIALIZATION_path(self):
        self._set_turns(self.DONE)
        self.actions.align_start("a personal finance site", vision=True)
        self.assertIn("--initialization", self._filed_argv(),
                      "a vision-mode filing without --initialization is "
                      "refused by the S183 foundation gate (exit 4)")

    def test_a_NORMAL_done_turn_is_NEVER_an_initialization_filing(self):
        self._give_it_a_foundation()
        self._set_turns(self.DONE)
        self.actions.align_start("add a leaderboard", vision=False)
        self.assertNotIn("--initialization", self._filed_argv())

    # ── D9: ONE fence in the prompt, not two ───────────────────────────────
    def test_the_vision_prompt_CANCELS_skill_step_0(self):
        self._set_turns({"status": "question",
                         "question": {"text": "What are we building?"},
                         "prd": "# Mission: F\n"})
        self.actions.align_start("a personal finance site", vision=True)
        p = self._prompt()
        self.assertIn("foundation-gate.sh", p,
                      "SKILL.md STEP 0 is in the prompt (it is loaded whole)")
        self.assertIn("ESTABLISH VISION — MODE OVERRIDE", p,
                      "…and nothing cancels it, so the prompt carries two "
                      "contradictory fences")
        self.assertIn("recommendation", p.lower())

    def test_a_NORMAL_prompt_gains_nothing(self):
        self._give_it_a_foundation()
        self._set_turns({"status": "question",
                         "question": {"text": "Which leaderboard?"},
                         "prd": "# Mission: F\n"})
        self.actions.align_start("add a leaderboard", vision=False)
        self.assertNotIn("ESTABLISH VISION — MODE OVERRIDE", self._prompt())


class OverrideFieldTest(unittest.TestCase):
    """D7 — the override screen's ONE-LINE input wore the textarea's box.

    `renderFrontDoorOverride` paints an `<input class="fd-field">` holding a
    stack name. `.fd-field` was written for the ask/grill TEXTAREA and carries
    `min-height:132px` + `resize:vertical`, so the captain's single line of
    text floated at the top of a 130px-tall empty well and the screen read as
    broken. Artifact: tests/drives/s184/shots/override/override.png.
    """

    @classmethod
    def setUpClass(cls):
        cls.rules, _ = css.load_stylesheets(css.CSS_SHEETS)

    def _applies_to(self, tag):
        """Every unconditional `.fd-field` rule that CAN match a `<tag>` — a
        rule qualified with a different element name cannot."""
        out = []
        for r in self.rules:
            sel = r.selector
            if ".fd-field" not in sel or r.conditional:
                continue
            for other in ("textarea", "input"):
                if other != tag and (other + ".fd-field") in sel:
                    break
            else:
                out.append(r)
        return out

    def _prop(self, tag, prop):
        got = None
        for r in self._applies_to(tag):
            for p, v, _imp in r.decls:
                if p == prop:
                    got = v
        return got

    def test_the_override_input_is_NOT_given_a_textareas_height(self):
        mh = self._prop("input", "min-height")
        if mh is None:
            return
        n = float(mh.replace("px", "").strip() or 0)
        self.assertLessEqual(
            n, 48,
            "the single-line override input is %s tall — one line of text in "
            "an empty well" % mh)

    def test_the_override_input_is_not_resizable_like_a_textarea(self):
        self.assertIn(self._prop("input", "resize"), (None, "none"))

    def test_the_ASK_textarea_keeps_the_box_it_was_designed_with(self):
        """The other half: this fix must not shrink the box the idea is typed
        into. It is the measure of the whole first screen."""
        self.assertEqual(self._prop("textarea", "min-height"), "132px")
        self.assertEqual(self._prop("textarea", "resize"), "vertical")


class HolodeckFloorTest(unittest.TestCase):
    """The front door stands on the same deck grid as the empty holodeck.

    A rule-existence check cannot see a pixel — the screenshots do that. What
    it CAN catch is the defect this change exists to prevent: TWO copies of the
    floor drifting apart the first time either one is tuned. So the assertion
    is not "both have a grid", it is "both read the SAME single definition, and
    that definition still expands to what the deck shipped with".
    """

    LINE = "rgba(45,227,199,.13)"
    STEP = "48px"
    STOPS = "rgba(3,6,8,.97) 0%,rgba(3,6,8,.85) 45%,rgba(3,6,8,0) 78%"

    @classmethod
    def setUpClass(cls):
        cls.rules, _ = css.load_stylesheets(css.CSS_SHEETS)
        with open(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                               "..", "static", "board.css")) as fh:
            cls.text = fh.read()
        # `load_stylesheets` only harvests custom properties off :root/html; the
        # deck's own props live on `body.lcars-serve` (ADR-007 — a local prop,
        # not a forked --lcars-* token), so harvest those too.
        cls.vars = {}
        for r in cls.rules:
            if r.selector == "body.lcars-serve":
                for prop, value, _imp in r.decls:
                    if prop.startswith("--"):
                        cls.vars[prop] = value

    def _decl(self, selector, prop):
        got = None
        for r in self.rules:
            if r.selector.replace(" ", "") != selector or r.conditional:
                continue
            for p, v, _imp in r.decls:
                if p == prop:
                    got = v
        self.assertIsNotNone(got, "no %s on %s" % (prop, selector))
        return got

    def _flat(self, value):
        return "".join(css.resolve_value(value, self.vars).split())

    def test_the_floor_has_exactly_one_definition(self):
        """The whole point. Every number that makes the grid a grid appears in
        the sheet ONCE — in the token block — so `.holo-empty` and
        `.front-door` cannot be tuned into two different decks."""
        body = css._strip_css_comments(self.text)
        self.assertEqual(body.count(self.LINE), 1,
                         "the grid line colour is written more than once")
        self.assertEqual(body.count("0 0/var(--holo-floor-step)"), 2,
                         "the two gradient layers must both read the step var")
        self.assertEqual(body.count(self.STEP), 1,
                         "the 48px grid spacing is written more than once")
        self.assertEqual("".join(body.split()).count(
            "".join(self.STOPS.split())), 1,
            "the mask stops are written more than once")

    def test_the_tokens_still_expand_to_the_deck_that_shipped(self):
        """The byte-identity guard. `.holo-empty` is a shipped surface; the
        refactor is only allowed to move where the numbers live."""
        floor = self._flat("var(--holo-floor)")
        self.assertEqual(
            floor,
            "".join(("linear-gradient(%s 1px,transparent 1px) 0 0/%s %s,"
                     "linear-gradient(90deg,%s 1px,transparent 1px) 0 0/%s %s,"
                     "%s"
                     % (self.LINE, self.STEP, self.STEP,
                        self.LINE, self.STEP, self.STEP,
                        self._flat("var(--lcars-black)"))).split()))
        self.assertEqual(
            self._flat("var(--holo-floor-mask)"),
            "".join(("radial-gradient(ellipse 62%% 58%% at 50%% 50%%,%s)"
                     % self.STOPS).split()))
        # the wide variant is the SAME curve on a bigger box — only the extent
        # may differ, and it is checked by subtraction so a hand-edited stop
        # cannot slip into it.
        self.assertEqual(
            self._flat("var(--holo-floor-mask-wide)")
                .replace("".join(self.STOPS.split()), "@"),
            "radial-gradient(ellipse92%96%at50%50%,@)")

    def test_the_empty_deck_reads_the_shared_floor(self):
        self.assertEqual(self._decl(".holo-empty", "background"),
                         "var(--holo-floor)")
        self.assertEqual(self._decl(".holo-empty::before", "background"),
                         "var(--holo-floor-mask)")

    def test_the_front_door_stands_on_the_same_floor(self):
        bg = self._decl(".front-door", "background")
        self.assertIn("var(--holo-floor)", bg,
                      "the front door has no deck grid under it")
        self.assertIn("var(--holo-floor-mask-wide)", bg,
                      "the front door has no scrim, so the grid competes "
                      "with the copy")

    def test_the_front_door_takes_the_mask_SIZED_TO_ITS_OWN_BOX(self):
        """The one thing that legitimately differs between the two surfaces.
        The deck's landing pane is a column inside a split; the front door is
        the whole frame. A percentage extent is a fraction of the box it is
        painted on, so re-using the deck's 62%/58% here leaves the tall
        recommendation screen's kicker and first reasons OUTSIDE the fade —
        measured, not argued. The fade CURVE is still the shared one."""
        bg = "".join(self._decl(".front-door", "background").split())
        self.assertNotIn("var(--holo-floor-mask),", bg,
                         "the front door is wearing the deck-sized mask")

    def test_the_mask_sits_ABOVE_the_grid_on_the_front_door(self):
        """Background layers paint first-listed on TOP. A mask stacked under
        the grid is a mask that does nothing."""
        bg = "".join(self._decl(".front-door", "background").split())
        self.assertLess(bg.index("var(--holo-floor-mask-wide)"),
                        bg.index("var(--holo-floor)"))

    def test_the_front_door_scrim_is_NOT_a_scrolling_overlay(self):
        """`.front-door` carries its own overflow-y:auto for the tall
        recommendation screen. An absolutely-positioned ::before is laid out
        against the SCROLLED padding box and would slide away from the copy;
        the background cannot. This is the reason the two surfaces apply the
        same values through different mechanisms."""
        self.assertEqual(self._decl(".front-door", "overflow-y"), "auto")
        self.assertFalse(
            [r for r in self.rules if r.selector == ".front-door::before"],
            "the front door grew a ::before overlay — it will scroll off the "
            "recommendation screen")



# ══════════════════════════════════════════════════════════════════════════
# S195 — THE ENGINE PICKER
# ══════════════════════════════════════════════════════════════════════════
def _with_engines(meta, engines=("claude", "copilot"), engine="claude"):
    """A front-door payload carrying the daemon's engine facts."""
    m = json.loads(json.dumps(meta))
    m["frontDoor"]["engines"] = list(engines)
    m["frontDoor"]["engine"] = engine
    return m


class EnginePickerTest(unittest.TestCase):
    """S195 — the choice of CLI is made ON THE FRONT DOOR, before the grill.

    Three rules, and each is a rule rather than a taste:

      1. ONLY WHAT IS INSTALLED IS OFFERED. The list is the daemon's, computed
         by the same `command -v` seam `lcars init` verifies the claude CLI
         through — a picker offering a CLI this machine does not have is a way
         to file a mission that cannot run.
      2. ONE ENGINE IS NOT A CHOICE. With a single CLI installed there is no
         picker; the door SAYS which engine will run it, because silence there
         reads as "LCARS picked something and won't say what".
      3. THE PICK RIDES EVERYTHING IT SHOULD. The grill's first turn, and the
         filing — one choice, made once, in the place the decision occurs.
    """

    GF = FrontDoorRendersTest.GREENFIELD
    UT = FrontDoorRendersTest.UNTESTED

    def _opts(self, res):
        return [n for n in _flatten(res["frontDoor"])
                if "opt" in (n["cls"] or "").split()]

    def _selected(self, res):
        return [n["text"] for n in self._opts(res)
                if "sel" in (n["cls"] or "").split()]

    # ── 1. it is THERE, on BOTH doors ──────────────────────────────────────
    def test_the_picker_renders_on_the_greenfield_door(self):
        res = _render(_board(meta=_with_engines(self.GF)))
        labels = [n["text"] for n in self._opts(res)]
        self.assertEqual(len(labels), 2, "both installed engines must be offered")
        self.assertTrue(any("Claude" in t for t in labels), labels)
        self.assertTrue(any("Copilot" in t for t in labels), labels)
        self.assertIn("Engine", _text(res["frontDoor"]))

    def test_the_picker_renders_on_the_untested_door_too(self):
        """The `untested` screen asks nothing about the product — but the
        engine is not a question about the product, it is how the mission runs,
        and that door files a mission exactly like the other one."""
        res = _render(_board(meta=_with_engines(self.UT)))
        labels = [n["text"] for n in self._opts(res)]
        self.assertEqual(len(labels), 2, "the untested door needs it too")
        self.assertIn("Engine", _text(res["frontDoor"]))

    # ── 2. only what is installed, and no pointless picker ─────────────────
    def test_an_engine_this_machine_does_not_have_is_NEVER_offered(self):
        res = _render(_board(meta=_with_engines(self.GF, engines=("copilot",),
                                                engine="copilot")))
        txt = _text(res["frontDoor"])
        self.assertNotIn("Claude", txt,
                         "a CLI that is not installed must not be offered")

    def test_one_engine_states_which_one_rather_than_offering_a_choice(self):
        res = _render(_board(meta=_with_engines(self.GF, engines=("copilot",),
                                                engine="copilot")))
        self.assertEqual(self._opts(res), [],
                         "a one-option picker is not a choice")
        self.assertIn("Copilot", _text(res["frontDoor"]),
                      "it must SAY which engine will run it")

    def test_the_single_engine_is_still_what_gets_POSTed(self):
        res = _render(_board(meta=_with_engines(self.GF, engines=("copilot",),
                                                engine="copilot")),
                      act="submit", text="a personal finance site")
        body = json.loads([f for f in res["fetches"]
                           if f["method"] == "POST"][0]["body"])
        self.assertEqual(body["engine"], "copilot")

    def test_no_engine_installed_offers_nothing_and_posts_nothing(self):
        res = _render(_board(meta=_with_engines(self.GF, engines=(), engine="")),
                      act="submit", text="a personal finance site")
        self.assertEqual(self._opts(res), [])
        body = json.loads([f for f in res["fetches"]
                           if f["method"] == "POST"][0]["body"])
        self.assertNotIn("engine", body,
                         "with nothing to pick, the daemon's own default stands")

    # ── the preselection ───────────────────────────────────────────────────
    def test_the_repos_configured_engine_is_what_is_preselected(self):
        res = _render(_board(meta=_with_engines(self.GF, engine="copilot")))
        sel = self._selected(res)
        self.assertEqual(len(sel), 1, "exactly one option is selected")
        self.assertIn("Copilot", sel[0])

    def test_the_default_preselection_is_the_daemons(self):
        res = _render(_board(meta=_with_engines(self.GF, engine="claude")))
        self.assertIn("Claude", self._selected(res)[0])

    # ── 3. the pick rides the grill AND the filing ─────────────────────────
    def test_the_chosen_engine_is_POSTed_to_align_start(self):
        res = _render(_board(meta=_with_engines(self.GF)), act="submit",
                      text="a website that does personal finance stuff")
        post = [f for f in res["fetches"] if f["method"] == "POST"][0]
        self.assertEqual(post["url"], "/api/align/start")
        body = json.loads(post["body"])
        self.assertTrue(body["vision"])
        self.assertEqual(body["engine"], "claude")

    def test_clicking_the_OTHER_engine_changes_what_the_grill_runs_on(self):
        """The discriminating half: a picker that renders but never changes the
        POST is a decoration."""
        res = _render(_board(meta=_with_engines(self.GF)), pickEngine="Copilot",
                      act="submit", text="a personal finance site")
        body = json.loads([f for f in res["fetches"]
                           if f["method"] == "POST"][0]["body"])
        self.assertEqual(body["engine"], "copilot")

    def test_the_choice_survives_a_repaint(self):
        """SSE repaints the door constantly (`frontDoorRepaint`). A pick held in
        the DOM instead of in `frontDoorState` is lost on the next tick — the
        exact class of bug the override screen already had (D-override)."""
        res = _render(_board(meta=_with_engines(self.GF)), pickEngine="Copilot")
        self.assertIn("Copilot", self._selected(res)[0])

    def test_the_engine_rides_the_FILING_too(self):
        """It powers the grill AND every stage of the mission it files, so the
        filing endpoint carries it as well — that is what becomes
        `state.json.workerBin`."""
        t = TurnsTheDaemonActuallySendsTest
        res = _render(_board(meta=_with_engines(t.META)), act="grill",
                      pickEngine="Copilot",
                      turns=["a personal finance site", "yes"],
                      responses=[t.Q1, t.REC, {"board": {}}],
                      then="accept")
        posts = [f for f in res["fetches"] if f["method"] == "POST"]
        self.assertEqual(posts[-1]["url"], "/api/vision/file")
        self.assertEqual(json.loads(posts[-1]["body"])["engine"], "copilot")

    def test_the_picker_is_withdrawn_while_the_opening_turn_is_in_flight(self):
        """A click during "◐ THINKING…" would change the engine the FILING uses
        after the grill had already opened on another one — two engines on one
        mission, which is exactly what file.sh's engine header forbids, and
        nothing on screen would say so."""
        res = _render(_board(meta=_with_engines(self.GF)), act="busy",
                      text="a personal finance site")
        self.assertEqual(self._opts(res), [])
        self.assertIn("THINKING", _text(res["frontDoor"]))

    def test_the_picker_is_gone_once_the_conversation_has_started(self):
        """The choice is made BEFORE the grill. Showing it mid-interview would
        offer a switch that cannot be honoured — the session is already warm on
        the engine it opened with."""
        t = TurnsTheDaemonActuallySendsTest
        res = _render(_board(meta=_with_engines(t.META)), act="grill",
                      turns=["a personal finance site"], responses=[t.Q1])
        self.assertEqual(self._opts(res), [],
                         "the picker must not follow the captain into the grill")

    # ── REGRESSION: a board without the daemon's engine facts ──────────────
    def test_a_payload_with_no_engine_facts_renders_exactly_as_before(self):
        """An older daemon, a github/read-only build, or a `--facts` that could
        not answer. Nothing is rendered and nothing is posted, so the surface is
        byte-identical to S184's."""
        res = _render(_board(meta=self.GF), act="submit", text="an idea")
        self.assertEqual(self._opts(res), [])
        self.assertNotIn("Engine", _text(res["frontDoor"]))
        body = json.loads([f for f in res["fetches"]
                           if f["method"] == "POST"][0]["body"])
        self.assertNotIn("engine", body)

    def test_a_healthy_board_never_grows_an_engine_picker(self):
        res = _render(_board(meta={"adapter": "local"}, missions=[_card("m-1")]))
        self.assertEqual(res["columns"], COLUMNS)
        self.assertTrue(res["frontDoorHidden"])
        self.assertEqual(self._opts(res), [])


class VisionEngineDaemonTest(unittest.TestCase):
    """S195 — the daemon half of the picker: ONE choice, made once, obeyed by
    every worker the front door causes.

    The engine reaches the daemon on `/api/align/start` and is held on the
    session, so `/api/align/<sid>/answer` needs no engine field of its own — the
    thing to prove is therefore not that the later endpoints CARRY it but that
    the later TURNS RUN ON IT. Proven by which binary was invoked, not by a flag
    in an argv: two recording stubs, one per engine, each with its own log.

    Zero spend: both engines are bash scripts.
    """

    @classmethod
    def setUpClass(cls):
        from tests import test_align_endpoints as ae
        cls.ae = ae

    def setUp(self):
        import shutil
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, True)
        _git_repo(self.tmp)
        self.turns = os.path.join(self.tmp, "turns.txt")
        self.prompts = os.path.join(self.tmp, "prompts.txt")
        # TWO engines, TWO argv logs — the only honest way to answer "which CLI
        # actually ran". `default_argv` is the daemon's fallback: any line in it
        # is the captain's choice having been dropped on the floor.
        self.default_argv = os.path.join(self.tmp, "argv-default.txt")
        self.copilot_argv = os.path.join(self.tmp, "argv-copilot.txt")
        self.rec_file = os.path.join(self.tmp, "rec-file.txt")
        self.rec_ev = os.path.join(self.tmp, "rec-ev.txt")
        self.scripts = {"file": self.ae._file_record_stub(self.rec_file),
                        "establish_vision": self.ae._file_record_stub(self.rec_ev)}
        self.default_bin = self.ae._worker_stub(self.turns, self.prompts,
                                                self.default_argv)
        self.copilot_bin = self.ae._copilot_worker_stub(self.turns, self.prompts,
                                                        self.copilot_argv)
        from lcars_serve.actions import Actions
        self.actions = Actions(repo_root=self.tmp, scripts=self.scripts,
                               worker_bin=self.default_bin)

    def _set_turns(self, *blobs):
        with open(self.turns, "w") as fh:
            for i, b in enumerate(blobs):
                if i:
                    fh.write("===TURN===\n")
                fh.write(json.dumps(b) + "\n")

    def _spawns(self, path):
        if not os.path.exists(path):
            return 0
        with open(path) as fh:
            return len([ln for ln in fh if ln.startswith("ARGV: ")])

    def _ev_argv(self):
        if not os.path.exists(self.rec_ev):
            return ""
        with open(self.rec_ev) as fh:
            return fh.read()

    Q = {"status": "question", "question": {"text": "Which stack?"},
         "prd": "# Mission: Foundation\n\n**Type:** feature\n"}

    def test_the_front_doors_engine_runs_the_FIRST_grill_turn(self):
        self._set_turns(self.Q)
        self.actions.align_start("a personal finance site", vision=True,
                                 engine=self.copilot_bin)
        self.assertEqual(self._spawns(self.copilot_argv), 1)
        self.assertEqual(self._spawns(self.default_argv), 0,
                         "the daemon default ran instead of the captain's pick")

    def test_and_EVERY_LATER_TURN_runs_on_it_too(self):
        """The `answer` endpoint takes no engine — the session holds it. So the
        thing that must be true is that turns 2 and 3 hire the SAME CLI."""
        self._set_turns(self.Q, self.Q, self.Q)
        out = self.actions.align_start("a personal finance site", vision=True,
                                       engine=self.copilot_bin)
        sid = out["sessionId"]
        self.actions.align_answer(sid, "vitest")
        self.actions.align_answer(sid, "yes")
        self.assertEqual(self._spawns(self.copilot_argv), 3)
        self.assertEqual(self._spawns(self.default_argv), 0,
                         "a later turn re-homed onto the daemon default")

    def test_no_engine_still_runs_the_daemon_default(self):
        """REGRESSION — a door with nothing to pick behaves as it did before."""
        self._set_turns(self.Q)
        self.actions.align_start("a personal finance site", vision=True)
        self.assertEqual(self._spawns(self.default_argv), 1)
        self.assertEqual(self._spawns(self.copilot_argv), 0)

    # ── the filing ────────────────────────────────────────────────────────
    def test_vision_file_PINS_the_chosen_engine_on_the_filed_mission(self):
        """`--engine`, not `$LCARS_WORKER_BIN`: file.sh's own header records
        that the flag is the strongest signal there is, and that it "came to be
        silently ignored on the --prd lane" — which is the lane this files
        through."""
        self.actions.vision_file(idea="a personal finance site",
                                 stack="Vite + React + Vitest",
                                 engine="copilot")
        argv = self._ev_argv()
        self.assertIn("--file", argv)
        self.assertIn("--engine copilot", argv)

    def test_vision_file_without_an_engine_is_byte_identical(self):
        self.actions.vision_file(idea="a personal finance site",
                                 stack="Vite + React + Vitest")
        self.assertNotIn("--engine", self._ev_argv())


if __name__ == "__main__":
    unittest.main()

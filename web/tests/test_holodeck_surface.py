"""S125 — THE HOLODECK SURFACE: the jailed preview route, the program list, and
the board's holodeck view.

Two halves, both in this one file so the session's fix-loop suite is one command:

  1. SERVER — the new GET family (`/api/holodeck`, `/api/holodeck/<sid>`,
     `/api/holodeck/<sid>/preview/<path>`) driven over a real socket against a
     real daemon, with the S124 recording worker stub behind it. The preview
     route is the ONE place the daemon serves bytes a MODEL wrote, so the jail
     gets the attention: traversal, absolute paths, a SYMLINK inside the room
     pointing out of it, NUL bytes, unknown types, and the security headers that
     make same-origin model HTML survivable.

  2. DOM — the shipping `board.js` booted in a node vm (board_holodeck_harness.js,
     the `board_*_harness.js` convention) so the deck's real render functions are
     exercised: the band control, the three panes, the composer, the preview
     iframe's src AND its sandbox flags, the empty state, the grounding dialog's
     mode, the filter chips, and D7's three failure states.

WHAT THIS FILE CANNOT SEE, stated plainly because the last time nobody wrote it
down it cost three fix rounds (S163): the node harness calls the render functions
ITSELF. It can never tell a working page from a blank one, and it sees no CSS at
all. `tests/drives/browser/holodeck.sh` is the half that opens real Chrome,
clicks into the deck, and MEASURES what painted. Run it.
"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest
import urllib.error
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from tests import _fixtures as fx  # noqa: E402
# S162's cascade resolver, imported as a MODULE so its own TestCases are not
# re-collected here: FL-006 is a legibility fix, and "the rule is in the
# stylesheet" is exactly the claim that shipped an invisible amber warning.
from tests import test_log_filing_band as css  # noqa: E402
from tests.test_holodeck_endpoints import _make_stub, _file_record_stub  # noqa: E402
from lcars_serve.local_adapter import LocalAdapter  # noqa: E402
from lcars_serve.server import make_server  # noqa: E402
from lcars_serve.actions import Actions  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
HARNESS = os.path.join(HERE, "board_holodeck_harness.js")
NODE = shutil.which("node")


# ════════════════════════════════════════════════════════════════════════════
# 1. THE SERVER HALF
# ════════════════════════════════════════════════════════════════════════════
class SurfaceBase(unittest.TestCase):
    read_only = False

    def setUp(self):
        # S169 fix round 2 — the hand-off CHECK is off for this base, for the
        # same reason as `HolodeckBase`: `promote` would spawn a worker off the
        # shared canned-turn queue. See test_holodeck_endpoints.HolodeckBase.
        self._old_check = os.environ.get("LCARS_HOLODECK_HANDOFF_CHECK")
        os.environ["LCARS_HOLODECK_HANDOFF_CHECK"] = "0"
        self.addCleanup(self._restore_check)
        self.tmp = tempfile.mkdtemp()
        self.repo = os.path.join(self.tmp, "target-repo")
        os.makedirs(self.repo)
        fx.plant_simple(self.repo, "m-001", stage="verify", issue=142)
        self.holo_root = os.path.join(self.tmp, "holo-root")
        os.makedirs(self.holo_root)
        self.adapter = LocalAdapter(self.repo)

        self.bindir = os.path.join(self.tmp, "bin")
        os.makedirs(self.bindir)
        self.turns_path = os.path.join(self.tmp, "turns.json")
        self.cfg_path = os.path.join(self.tmp, "stub-cfg.json")
        with open(self.cfg_path, "w") as fh:
            json.dump({"turns": self.turns_path,
                       "promptLog": os.path.join(self.tmp, "prompts.txt"),
                       "argvLog": os.path.join(self.tmp, "argv.jsonl")}, fh)
        self._set_turns({"stdout": "ok"})
        self.claude_bin = _make_stub(self.bindir, "claude", self.cfg_path)

        self.scripts = {}
        for key in ("file", "log", "resolve"):
            self.scripts[key] = _file_record_stub(
                os.path.join(self.tmp, "rec-%s.txt" % key))

        self.actions = None
        if not self.read_only:
            self.actions = Actions(repo_root=self.repo, scripts=self.scripts,
                                   worker_bin=self.claude_bin,
                                   holodeck_root=self.holo_root)
        self.httpd = make_server(self.adapter, host="127.0.0.1", port=0,
                                 poll_interval=0.05, actions=self.actions)
        self.port = self.httpd.server_address[1]
        self.thread = threading.Thread(target=self.httpd.serve_forever,
                                       daemon=True)
        self.thread.start()

    def _restore_check(self):
        if self._old_check is None:
            os.environ.pop("LCARS_HOLODECK_HANDOFF_CHECK", None)
        else:
            os.environ["LCARS_HOLODECK_HANDOFF_CHECK"] = self._old_check

    def tearDown(self):
        self.httpd.shutdown()
        self.httpd.server_close()
        shutil.rmtree(self.tmp, ignore_errors=True)

    # -- helpers -------------------------------------------------------------
    def _set_turns(self, *turns):
        with open(self.turns_path, "w") as fh:
            json.dump(list(turns), fh)
        idx = self.turns_path + ".idx"
        if os.path.exists(idx):
            os.unlink(idx)

    def _url(self, path):
        return "http://127.0.0.1:%d%s" % (self.port, path)

    def _post(self, path, obj=None, timeout=20):
        data = json.dumps(obj if obj is not None else {}).encode("utf-8")
        req = urllib.request.Request(
            self._url(path), data=data, method="POST",
            headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return r.status, json.loads(r.read())
        except urllib.error.HTTPError as exc:
            return exc.code, json.loads(exc.read())

    def _get(self, path, timeout=20):
        """(status, body-bytes, headers)."""
        try:
            with urllib.request.urlopen(self._url(path), timeout=timeout) as r:
                return r.status, r.read(), dict(r.headers)
        except urllib.error.HTTPError as exc:
            return exc.code, exc.read(), dict(exc.headers)

    def _get_json(self, path):
        status, body, _h = self._get(path)
        return status, json.loads(body)

    def _start(self, program="Nav rail"):
        status, body = self._post("/api/holodeck/start",
                                  {"program": program,
                                   "engine": self.claude_bin})
        self.assertEqual(status, 200, body)
        return body["state"]["sessionId"], body["state"]


class ProgramListTest(SurfaceBase):
    def test_the_list_is_empty_until_a_program_is_started(self):
        status, body = self._get_json("/api/holodeck")
        self.assertEqual(status, 200)
        self.assertEqual(body["programs"], [])

    def test_starting_via_the_api_creates_the_sidecar_and_lists_the_program(self):
        sid, state = self._start("Tile picker sidebar")
        sidecar = os.path.join(self.holo_root, "target-repo-holodeck")
        # D6: the sidecar is a REAL local git repo, created on first use.
        self.assertTrue(os.path.isdir(os.path.join(sidecar, ".git")))
        self.assertEqual(state["sidecar"], sidecar)
        self.assertEqual(state["sidecarName"], "target-repo-holodeck")
        self.assertGreaterEqual(state["commits"], 1)
        status, body = self._get_json("/api/holodeck")
        self.assertEqual(status, 200)
        self.assertEqual(len(body["programs"]), 1)
        prog = body["programs"][0]
        self.assertEqual(prog["sessionId"], sid)
        self.assertEqual(prog["program"], "Tile picker sidebar")
        # everything is a DRAFT this session, and that is the honest answer —
        # the sent/done lifecycle is S126/S127 and is not faked here.
        self.assertEqual(prog["status"], "draft")
        self.assertEqual(prog["turnCount"], 0)
        # nothing has been written yet, so there is no preview file — the UI's
        # cue for the empty state instead of a broken iframe.
        self.assertIsNone(prog["previewFile"])

    def test_a_turn_that_writes_the_mockup_becomes_the_preview_file(self):
        self._set_turns({"stdout": "Built it.",
                         "writes": [{"path": "mockup.html",
                                     "content": "<h1>deck</h1>"}]})
        sid, _ = self._start()
        status, body = self._post("/api/holodeck/%s/say" % sid,
                                  {"text": "make a nav rail"})
        self.assertEqual(status, 200, body)
        self.assertEqual([c["path"] for c in body["state"]["filesChanged"]],
                         ["nav-rail/mockup.html"])
        self.assertEqual(body["state"]["previewFile"], "mockup.html")
        status, one = self._get_json("/api/holodeck/%s" % sid)
        self.assertEqual(status, 200)
        self.assertEqual(one["previewFile"], "mockup.html")
        self.assertEqual(one["turnCount"], 1)
        self.assertEqual(one["turns"][0]["text"], "make a nav rail")

    def test_an_html_under_another_name_is_still_previewable(self):
        self._set_turns({"stdout": "Built it.",
                         "writes": [{"path": "sidebar.html", "content": "<i>x"}]})
        sid, _ = self._start()
        self._post("/api/holodeck/%s/say" % sid, {"text": "go"})
        _s, one = self._get_json("/api/holodeck/%s" % sid)
        self.assertEqual(one["previewFile"], "sidebar.html")

    def test_an_unknown_program_is_a_readable_404(self):
        status, body = self._get_json("/api/holodeck/nope")
        self.assertEqual(status, 404)
        self.assertIn("no such holodeck program", body["error"])


# ════════════════════════════════════════════════════════════════════════════
# S125 FIX ROUND 1 — THE RECOMMENDED PATH (D12)
#
# `This project's look` is the DEFAULT and it is badged RECOMMENDED, and until
# this round it was the one path that could never write a mockup: `sess.mode`
# was set once at start and never moved off "grounding", so every later turn
# kept the read-only posture (no write tool, cwd = the captain's PROJECT, no
# `--add-dir` grant on copilot) and the engine answered "I can't write files —
# save this yourself". The turn returned `status: "ok"`.
#
# The cure is NOT to mutate one session's posture mid-flight (S124 made the two
# postures separate sessions deliberately: different tools AND different cwds).
# After the ONE opening grounding pass, the program opens a FRESH warm DESIGN
# session — its own session-id, cwd = the program's room, write tools — with the
# grounding on disk beside it as `basis.md`.
# ════════════════════════════════════════════════════════════════════════════
class GroundedProgramTest(SurfaceBase):
    BASIS = "## Colours\n`--ink: #101318` (tokens.css)\nNo light theme.\n"

    def _argv_log(self):
        path = os.path.join(self.tmp, "argv.jsonl")
        if not os.path.exists(path):
            return []
        with open(path) as fh:
            return [json.loads(ln) for ln in fh if ln.strip()]

    def _ground(self, program="Nav rail"):
        status, body = self._post("/api/holodeck/start",
                                  {"program": program, "mode": "grounding",
                                   "engine": self.claude_bin})
        self.assertEqual(status, 200, body)
        return body["state"]["sessionId"], body["state"]

    def test_the_turn_after_grounding_writes_a_real_mockup_in_the_room(self):
        """The whole defect, end to end: the RECOMMENDED path must produce a
        file. The stub writes `mockup.html` relative to its cwd — so if the turn
        still ran in the grounding posture it would land in the captain's
        PROJECT and come back as a stray write, not as the program's mockup."""
        self._set_turns({"stdout": self.BASIS},
                        {"stdout": "Built the rail.",
                         "writes": [{"path": "mockup.html",
                                     "content": "<h1>rail</h1>"}]})
        sid, _ = self._ground()
        status, body = self._post("/api/holodeck/%s/say" % sid,
                                  {"text": "make the rail"})
        self.assertEqual(status, 200, body)
        state = body["state"]
        self.assertEqual(state["status"], "ok", state)
        self.assertEqual([c["path"] for c in state["filesChanged"]],
                         ["nav-rail/mockup.html"])
        self.assertEqual(state["previewFile"], "mockup.html")
        room = os.path.join(self.holo_root, "target-repo-holodeck", "nav-rail")
        with open(os.path.join(room, "mockup.html")) as fh:
            self.assertEqual(fh.read(), "<h1>rail</h1>")
        # and the grounding it was built from is still there, beside it.
        self.assertTrue(os.path.isfile(os.path.join(room, "basis.md")))

    def test_the_design_turn_is_a_fresh_warm_session_in_the_design_posture(self):
        self._set_turns({"stdout": self.BASIS},
                        {"stdout": "Built it.",
                         "writes": [{"path": "mockup.html", "content": "<i>x"}]})
        sid, _ = self._ground()
        self._post("/api/holodeck/%s/say" % sid, {"text": "go"})
        log = self._argv_log()
        self.assertEqual(len(log), 2, log)
        ground, design = log[0]["argv"], log[1]["argv"]
        # the GROUNDING pass: read-only, in the captain's project.
        self.assertEqual(log[0]["cwd"], os.path.realpath(self.repo))
        self.assertIn("Write", ground[ground.index("--disallowedTools") + 1])
        # the DESIGN turn: its OWN session (never a --resume across the switch),
        # write tools, and cwd = the program's room.
        self.assertIn("--session-id", design)
        self.assertNotIn("--resume", design)
        self.assertNotEqual(design[design.index("--session-id") + 1],
                            ground[ground.index("--session-id") + 1])
        self.assertIn("Write", design[design.index("--allowedTools") + 1])
        self.assertNotIn("Write", design[design.index("--disallowedTools") + 1])
        room = os.path.join(self.holo_root, "target-repo-holodeck", "nav-rail")
        self.assertEqual(log[1]["cwd"], os.path.realpath(room))

    def test_the_grounding_pass_is_exactly_one_turn_and_the_basis_is_not_rewritten(self):
        self._set_turns({"stdout": self.BASIS},
                        {"stdout": "Built it.",
                         "writes": [{"path": "mockup.html", "content": "<i>x"}]})
        sid, _ = self._ground()
        self._post("/api/holodeck/%s/say" % sid, {"text": "go"})
        room = os.path.join(self.holo_root, "target-repo-holodeck", "nav-rail")
        with open(os.path.join(room, "basis.md")) as fh:
            basis = fh.read()
        self.assertIn("`--ink: #101318`", basis)
        self.assertNotIn("Built it.", basis)
        _s, one = self._get_json("/api/holodeck/%s" % sid)
        # the program still SAYS it was grounded (the header chip, D12) even
        # though the posture it now runs in is design.
        self.assertTrue(one["grounded"])
        self.assertEqual(one["mode"], "design")
        self.assertEqual(one["basisFile"], "basis.md")

    def test_the_design_prompt_carries_the_grounding_it_was_made_of(self):
        self._set_turns({"stdout": self.BASIS}, {"stdout": "ok"})
        sid, _ = self._ground()
        self._post("/api/holodeck/%s/say" % sid, {"text": "go"})
        with open(os.path.join(self.tmp, "prompts.txt")) as fh:
            prompts = fh.read().split("===PROMPT===")
        self.assertIn("basis.md", prompts[2])

    def test_a_program_that_was_never_grounded_says_so(self):
        sid, state = self._start("Blank deck thing")
        self.assertFalse(state["grounded"])
        self.assertIsNone(state["basisFile"])


class TurnCannotWriteTest(SurfaceBase):
    """The second half of the defect: a turn that CANNOT write must never come
    back as a cheerful `ok`. The captain is never told to hand-save a file into
    his own project."""

    CANT_WRITE = (
        "I can't write files (read-only, no write tool), so here is the "
        "complete mockup.html for you to save:\n\n"
        "```html\n<!doctype html>\n<html><body><h1>Nav rail</h1></body></html>\n"
        "```\n\nSave this as mockup.html at the project root when ready.\n")

    def test_a_design_turn_that_answered_with_the_file_instead_of_writing_it(self):
        self._set_turns({"stdout": self.CANT_WRITE})
        sid, _ = self._start()
        status, body = self._post("/api/holodeck/%s/say" % sid, {"text": "go"})
        self.assertEqual(status, 200, body)
        state = body["state"]
        self.assertNotEqual(state["status"], "ok")
        self.assertEqual(state["status"], "wrote-nothing")
        self.assertTrue(state.get("warning"), state)
        self.assertEqual(state["warning"]["kind"], "no-write")
        msg = state["warning"]["message"]
        self.assertIn("nothing was saved", msg.lower())
        # it must never repeat the engine's instruction to hand-save.
        self.assertIn("never", msg.lower())

    def test_a_conversational_turn_that_wrote_nothing_is_still_ok(self):
        """A turn that only ANSWERS a question changed no files and that is
        correct — the surfaced state is for a turn that produced a whole file it
        could not save, not for every fileless turn."""
        self._set_turns({"stdout": "Amber reads warmer than teal here."})
        sid, _ = self._start()
        status, body = self._post("/api/holodeck/%s/say" % sid, {"text": "?"})
        self.assertEqual(status, 200, body)
        self.assertEqual(body["state"]["status"], "ok")
        self.assertIsNone(body["state"].get("warning"))


class OneRoomOneProgramTest(SurfaceBase):
    def test_two_programs_cannot_share_one_room(self):
        sid, _ = self._start("Nav rail")
        status, body = self._post("/api/holodeck/start",
                                  {"program": "Nav rail",
                                   "engine": self.claude_bin})
        self.assertEqual(status, 409, body)
        self.assertIn("already", body["error"].lower())
        self.assertIn("Nav rail", body["error"])
        _s, listing = self._get_json("/api/holodeck")
        self.assertEqual(len(listing["programs"]), 1)

    def test_a_name_that_slugs_the_same_is_the_same_room(self):
        self._start("Nav rail")
        status, body = self._post("/api/holodeck/start",
                                  {"program": "NAV  RAIL",
                                   "engine": self.claude_bin})
        self.assertEqual(status, 409, body)

    def test_a_different_program_is_a_different_room(self):
        self._start("Nav rail")
        status, body = self._post("/api/holodeck/start",
                                  {"program": "Tile picker",
                                   "engine": self.claude_bin})
        self.assertEqual(status, 200, body)
        _s, listing = self._get_json("/api/holodeck")
        dirs = sorted(p["programDir"] for p in listing["programs"])
        self.assertEqual(len(set(dirs)), 2)

    # ── FIX ROUND 2: the two holes round 1's cure left ───────────────────────
    def test_a_name_that_only_LOOKS_different_is_still_the_same_program(self):
        """`_slug` drops everything but `[a-z0-9]`, so names that a captain
        reads as identical could still slug apart and open a second card. The
        check now compares the NORMALIZED display name (NFKC + casefold +
        collapsed whitespace), which catches the easy half."""
        self._start("Tile picker")
        for twin in ("Ｔｉｌｅ ｐｉｃｋｅｒ",       # full-width — NFKC folds it
                     "tile  PICKER ",           # case + spacing
                     "Tile\tpicker"):           # a tab is whitespace
            status, body = self._post("/api/holodeck/start",
                                      {"program": twin,
                                       "engine": self.claude_bin})
            self.assertEqual(status, 409, "%r opened a twin card: %r"
                             % (twin, body))
        _s, listing = self._get_json("/api/holodeck")
        self.assertEqual(len(listing["programs"]), 1)

    def test_a_confusable_name_that_gets_through_is_LEGIBLE(self):
        """A Cyrillic `а` is not a homoglyph hunt LCARS wins, and refusing a
        name a captain honestly typed is worse than showing him which room it
        landed in. So it opens — and every card names its ROOM."""
        self._start("Tile picker sidebar")
        status, body = self._post("/api/holodeck/start",
                                  {"program": "Tile picker sidebаr",
                                   "engine": self.claude_bin})
        self.assertEqual(status, 200, body)
        _s, listing = self._get_json("/api/holodeck")
        rooms = sorted(p["room"] for p in listing["programs"])
        self.assertEqual(len(set(rooms)), 2, rooms)
        for p in listing["programs"]:
            self.assertTrue(p["room"], "a card with no room cannot be told "
                                       "apart from its twin")

    def test_re_creating_an_ended_programs_name_DISCLOSES_the_old_room(self):
        """End a program, start one with the same name, and it silently adopts
        the old room: `turnCount: 0` beside a `previewFile` showing the previous
        program's mockup. Refusing would burn the name forever, so it is said
        out loud instead."""
        sid, first = self._start("Nav rail")
        room = first["programDir"]
        with open(os.path.join(room, "mockup.html"), "w") as fh:
            fh.write("<b>the first program's work</b>")
        self._post("/api/holodeck/%s/end" % sid)
        status, body = self._post("/api/holodeck/start",
                                  {"program": "Nav rail",
                                   "engine": self.claude_bin})
        self.assertEqual(status, 200, body)
        state = body["state"]
        self.assertEqual(state["previewFile"], "mockup.html")
        notice = state.get("roomNotice")
        self.assertTrue(notice, "the room's contents were adopted in SILENCE: %r"
                        % state)
        msg = notice["message"]
        self.assertIn("mockup.html", msg)
        self.assertIn("already holds", msg.lower())
        self.assertNotIn("Traceback", msg)

    def test_a_genuinely_empty_room_says_nothing_at_all(self):
        _sid, state = self._start("Nav rail")
        self.assertIsNone(state.get("roomNotice"), state)


class RetryIsNeverADeadEndTest(SurfaceBase):
    """S125 FIX ROUND 2 · N4 — `sess.started` was set the instant `Popen`
    returned, so a first turn that died BEFORE the CLI opened its session left
    the program permanently unusable: RETRY TURN `--resume`d an id that never
    existed, failed for that reason, and the only escape was ending the program.
    Both real CLIs refuse to resume an unknown id. Measured live with a stub
    that does the same."""

    def _argv(self):
        rows = []
        path = os.path.join(self.tmp, "argv.jsonl")
        if os.path.exists(path):
            with open(path) as fh:
                for line in fh:
                    if line.strip():
                        rows.append(json.loads(line))
        return rows

    @staticmethod
    def _session_flags(argv):
        """(opening?, the id it used) for one recorded spawn."""
        for i, a in enumerate(argv):
            if a == "--session-id" and i + 1 < len(argv):
                return True, argv[i + 1]
            if a == "--resume" and i + 1 < len(argv):
                return False, argv[i + 1]
            if a.startswith("--session-id="):
                return True, a.split("=", 1)[1]
            if a.startswith("--resume="):
                return False, a.split("=", 1)[1]
        return None, None

    def test_a_turn_that_never_opened_a_session_is_retried_by_OPENING_one(self):
        """FIX ROUND 3 — THE NOISY DEATH, which is the ORDINARY one.

        Round 2 wrote this with a SILENT death (`{"stdout": ""}`), and the cure
        it proved (`reply or changed or a clean exit`) was blind to every real
        one: the daemon merges stderr into stdout, so a bad token, an expired
        auth or a rate limit at startup all arrive as a NON-EMPTY reply — the id
        was kept and the retry resumed a session that never existed. The very
        next test in this file already used a noisy stub; this one now does too.
        """
        self._set_turns({"stdout": "Error: authentication failed\n", "exit": 1},
                        {"stdout": "Built the rail.\n"})  # the retry
        sid, _ = self._start("Nav rail")
        status, body = self._post("/api/holodeck/%s/say" % sid, {"text": "go"})
        self.assertEqual(status, 502, body)
        status, body = self._post("/api/holodeck/%s/say" % sid, {"text": "go"})
        self.assertEqual(status, 200, body)
        spawns = [self._session_flags(r["argv"] if isinstance(r, dict) else r)
                  for r in self._argv()]
        self.assertEqual(len(spawns), 2, spawns)
        self.assertTrue(spawns[0][0], "turn 1 must OPEN a session")
        self.assertTrue(spawns[1][0],
                        "the retry RESUMED a session that never existed — the "
                        "program is a permanent dead end: %r" % (spawns,))
        self.assertNotEqual(spawns[0][1], spawns[1][1],
                            "the retry re-used the id of a session that may "
                            "never have been created")

    def test_a_SILENT_death_before_the_session_opened_is_retried_too(self):
        """The other shape, kept: a worker that dies saying nothing at all.
        Both must re-mint — the noisy one is the shape that hid the defect, the
        silent one is the shape round 2 was written against."""
        self._set_turns({"stdout": "", "exit": 2},
                        {"stdout": "Built the rail.\n"})
        sid, _ = self._start("Nav rail")
        status, body = self._post("/api/holodeck/%s/say" % sid, {"text": "go"})
        self.assertEqual(status, 502, body)
        status, body = self._post("/api/holodeck/%s/say" % sid, {"text": "go"})
        self.assertEqual(status, 200, body)
        spawns = [self._session_flags(r["argv"] if isinstance(r, dict) else r)
                  for r in self._argv()]
        self.assertEqual([s[0] for s in spawns], [True, True], spawns)
        self.assertNotEqual(spawns[0][1], spawns[1][1])

    def test_a_turn_that_worked_is_resumed_as_before(self):
        self._set_turns({"stdout": "Built the rail.\n"},
                        {"stdout": "Widened it.\n"})
        sid, _ = self._start("Nav rail")
        self._post("/api/holodeck/%s/say" % sid, {"text": "go"})
        self._post("/api/holodeck/%s/say" % sid, {"text": "wider"})
        spawns = [self._session_flags(r["argv"] if isinstance(r, dict) else r)
                  for r in self._argv()]
        self.assertEqual([s[0] for s in spawns], [True, False], spawns)
        self.assertEqual(spawns[0][1], spawns[1][1])

    def test_a_dead_turn_never_prints_an_exit_code(self):
        """D7 and board.js both say no stack traces and NO EXIT CODES. Round 1's
        banner read "(claude exited -9)" — a number that answers neither
        question a captain has and that he cannot act on."""
        self._set_turns({"stdout": "error: connection reset by peer\n",
                         "exit": 1})
        sid, _ = self._start("Nav rail")
        status, body = self._post("/api/holodeck/%s/say" % sid, {"text": "go"})
        self.assertEqual(status, 502, body)
        err = body["error"]
        self.assertNotIn("exited", err)
        self.assertNotRegex(err, r"-?\d+\)")
        self.assertIn("safe", err.lower())
        self.assertIn("still running", err.lower())

    def test_a_retried_line_is_not_said_twice_in_the_transcript(self):
        """N6, on the daemon's side: `/say` appended a turn per call, so the
        retry of a turn that produced nothing left the captain's line in the
        transcript twice."""
        # The dying worker PRINTS — measured live: `boom` on stderr, which the
        # daemon merges into stdout, so the failed turn has a non-empty reply.
        # A rule keyed off "the reply is empty" passes the unit test and lets
        # the duplicate straight through in the product.
        self._set_turns({"stdout": "boom\n", "exit": 2},
                        {"stdout": "Built the rail.\n"})
        sid, _ = self._start("Nav rail")
        self._post("/api/holodeck/%s/say" % sid, {"text": "make it wider"})
        status, body = self._post("/api/holodeck/%s/say" % sid,
                                  {"text": "make it wider"})
        self.assertEqual(status, 200, body)
        _s, state = self._get_json("/api/holodeck/%s" % sid)
        said = [t["text"] for t in state["turns"] if t["text"] == "make it wider"]
        self.assertEqual(len(said), 1, state["turns"])

    def test_two_different_lines_are_both_kept(self):
        self._set_turns({"stdout": "one\n"}, {"stdout": "two\n"})
        sid, _ = self._start("Nav rail")
        self._post("/api/holodeck/%s/say" % sid, {"text": "first"})
        self._post("/api/holodeck/%s/say" % sid, {"text": "second"})
        _s, state = self._get_json("/api/holodeck/%s" % sid)
        self.assertEqual([t["text"] for t in state["turns"]],
                         ["first", "second"])


class ListHeaderTest(SurfaceBase):
    """What the SURFACE needs before a program exists: where the sidecar is (D6
    wants the full path, not a basename) and what will actually run (the New
    Program dialog printed a hardcoded `sonnet tier`, which is false on
    copilot — `_holodeck_model` returns claude-opus-4.8 there)."""

    def test_the_empty_list_still_names_the_sidecar_path_in_full(self):
        _s, body = self._get_json("/api/holodeck")
        self.assertEqual(body["programs"], [])
        self.assertEqual(body["sidecar"],
                         os.path.join(self.holo_root, "target-repo-holodeck"))
        self.assertEqual(body["sidecarName"], "target-repo-holodeck")
        # the DISPLAY form is the same path with $HOME folded to `~` — the
        # board cannot work that out (it has no home directory), and a raw
        # /Users/... path in the empty state is noise the captain must parse.
        self.assertTrue(body["sidecarDisplay"].endswith("target-repo-holodeck"))

    def test_the_display_path_folds_home_to_a_tilde(self):
        home = os.path.expanduser("~")
        self.assertEqual(
            self.actions._display_path(os.path.join(home, "Projects", "x")),
            os.path.join("~", "Projects", "x"))
        self.assertEqual(self.actions._display_path("/opt/x"), "/opt/x")

    def test_the_list_names_the_engine_and_the_model_that_will_run(self):
        _s, body = self._get_json("/api/holodeck")
        self.assertEqual(body["engine"], self.claude_bin)
        self.assertEqual(body["engineName"], "claude")
        self.assertEqual(body["model"], "sonnet")

    def test_the_model_is_the_daemons_own_source_of_truth_per_engine(self):
        from lcars_serve.actions import _holodeck_model
        self.assertEqual(_holodeck_model("/usr/bin/copilot"), "claude-opus-4.8")
        self.assertEqual(_holodeck_model("/usr/bin/claude"), "sonnet")

    def test_the_list_publishes_the_tier_of_EVERY_engine_the_dialog_offers(self):
        """S127: the New Program dialog PICKS the engine, so the tier it prints
        follows the pick and not the daemon's own default. The mapping has ONE
        home — `_holodeck_model` — and is PUBLISHED here rather than copied
        into board.js, which is how the hardcoded `sonnet tier` lie happened
        the first time."""
        from lcars_serve.actions import _holodeck_model
        _s, body = self._get_json("/api/holodeck")
        self.assertEqual(body["models"], {"claude": _holodeck_model("claude"),
                                          "copilot": _holodeck_model("copilot")})
        # …and it really is the per-engine truth, not the daemon's one tier.
        self.assertEqual(body["models"]["claude"], "sonnet")
        self.assertEqual(body["models"]["copilot"], "claude-opus-4.8")

    def test_the_published_tiers_do_not_follow_the_daemons_own_engine(self):
        """The daemon here runs CLAUDE. If `models` were derived from
        `self.worker_bin` in any way, copilot's entry would read `sonnet` and
        the dialog would print a flattering lie the moment copilot is picked."""
        _s, body = self._get_json("/api/holodeck")
        self.assertEqual(body["engineName"], "claude")
        self.assertNotEqual(body["models"]["copilot"], body["models"]["claude"])


class CommitCountTest(SurfaceBase):
    def test_the_turn_payload_counts_the_commit_it_just_made(self):
        self._set_turns({"stdout": "Built it.",
                         "writes": [{"path": "mockup.html", "content": "<i>x"}]})
        sid, state = self._start()
        before = state["commits"]
        _s, body = self._post("/api/holodeck/%s/say" % sid, {"text": "go"})
        after = body["state"]["commits"]
        self.assertEqual(after, before + 1)
        _s, one = self._get_json("/api/holodeck/%s" % sid)
        self.assertEqual(one["commits"], after)


class NoEngineCopyTest(unittest.TestCase):
    """D7 voice: an error must never tell the captain to do something the
    surface cannot do — AND never hide the thing it can.

    Fix round 1 rewrote this message to name the daemon restart, because the
    New Program dialog had ONE field (a name) and no engine control at all.
    S127 gave it one, so "stop the viewscreen and restart it" stopped being the
    only road and became the WRONG first instruction: it sends the captain to
    kill his board for something a control in front of him now does."""

    def _msg(self):
        tmp = tempfile.mkdtemp()
        try:
            acts = Actions(repo_root=tmp, scripts={}, worker_bin="")
            with self.assertRaises(Exception) as ctx:
                acts.holodeck_start(program="x")
            return str(ctx.exception)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_the_no_engine_message_names_the_picker_the_dialog_now_has(self):
        msg = self._msg()
        low = msg.lower()
        self.assertIn("engine picker", low, msg)
        self.assertIn("new program", low, msg)

    def test_it_no_longer_sends_him_to_restart_the_board_as_the_only_road(self):
        msg = self._msg()
        low = msg.lower()
        self.assertNotIn("stop it and restart", low, msg)
        # the daemon-wide default is still A road — it is how every program on
        # this viewscreen gets an engine without picking one — so it is kept,
        # second, and still names the variable that sets it.
        self.assertIn("LCARS_WORKER_BIN", msg)

    def test_an_engine_that_is_not_on_this_machine_still_says_so_plainly(self):
        tmp = tempfile.mkdtemp()
        try:
            acts = Actions(repo_root=tmp, scripts={}, worker_bin="")
            with self.assertRaises(Exception) as ctx:
                acts.holodeck_start(program="x", engine="no-such-cli-xyz")
            msg = str(ctx.exception)
            self.assertIn("no-such-cli-xyz", msg)
            self.assertIn("not an executable", msg)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)


class PreviewJailTest(SurfaceBase):
    def setUp(self):
        SurfaceBase.setUp(self)
        self._set_turns({"stdout": "Built it.",
                         "writes": [{"path": "mockup.html",
                                     "content": "<h1>THE DECK</h1>"}]})
        self.sid, _ = self._start()
        self._post("/api/holodeck/%s/say" % self.sid, {"text": "go"})
        self.room = os.path.join(self.holo_root, "target-repo-holodeck",
                                 "nav-rail")

    def test_the_real_file_is_served_with_the_hardening_headers(self):
        status, body, headers = self._get(
            "/api/holodeck/%s/preview/mockup.html" % self.sid)
        self.assertEqual(status, 200)
        # D3: the bytes come from the FILE on disk, not from the reply text.
        self.assertEqual(body, b"<h1>THE DECK</h1>")
        self.assertEqual(headers["Content-Type"], "text/html; charset=utf-8")
        self.assertEqual(headers["X-Content-Type-Options"], "nosniff")
        csp = headers["Content-Security-Policy"]
        self.assertIn("default-src 'none'", csp)
        self.assertIn("connect-src 'none'", csp)
        self.assertIn("form-action 'none'", csp)
        self.assertIn("frame-ancestors 'self'", csp)
        # untrusted content is never handed to another origin to read.
        self.assertNotIn("Access-Control-Allow-Origin", headers)

    def test_dot_dot_traversal_is_refused(self):
        for attempt in ("../README.md", "../../target-repo/board.css",
                        "a/../../README.md", "..%2fREADME.md"):
            status, body, _h = self._get(
                "/api/holodeck/%s/preview/%s" % (self.sid, attempt))
            self.assertIn(status, (403, 404),
                          "%s leaked (HTTP %d)" % (attempt, status))
            self.assertNotIn(b"holodeck sidecar", body,
                             "%s served the sidecar README" % attempt)

    def test_an_absolute_path_is_refused(self):
        # `//etc/passwd` survives the router as a leading-empty segment; the
        # jail must refuse it on its own terms.
        for attempt in ("/etc/passwd", "//etc/passwd"):
            status, body, _h = self._get(
                "/api/holodeck/%s/preview/%s" % (self.sid, attempt))
            self.assertIn(status, (403, 404), attempt)
            self.assertNotIn(b"root:", body)

    def test_a_symlink_out_of_the_room_is_refused(self):
        secret = os.path.join(self.tmp, "secret.html")
        with open(secret, "w") as fh:
            fh.write("<b>NOT YOURS</b>")
        link = os.path.join(self.room, "escape.html")
        os.symlink(secret, link)
        status, body, _h = self._get(
            "/api/holodeck/%s/preview/escape.html" % self.sid)
        self.assertEqual(status, 403)
        self.assertNotIn(b"NOT YOURS", body)

    def test_a_symlinked_directory_out_of_the_room_is_refused(self):
        outside = os.path.join(self.tmp, "outside")
        os.makedirs(outside)
        with open(os.path.join(outside, "x.html"), "w") as fh:
            fh.write("<b>NOT YOURS</b>")
        os.symlink(outside, os.path.join(self.room, "away"))
        status, body, _h = self._get(
            "/api/holodeck/%s/preview/away/x.html" % self.sid)
        self.assertEqual(status, 403)
        self.assertNotIn(b"NOT YOURS", body)

    def test_a_null_byte_is_refused(self):
        status, _b, _h = self._get(
            "/api/holodeck/%s/preview/mockup.html%%00.png" % self.sid)
        self.assertIn(status, (400, 403, 404))

    def test_a_missing_file_is_a_readable_404_not_a_stack(self):
        status, body, _h = self._get(
            "/api/holodeck/%s/preview/nothing.html" % self.sid)
        self.assertEqual(status, 404)
        msg = json.loads(body)["error"]
        self.assertIn("nothing.html", msg)
        self.assertNotIn("Traceback", msg)

    def test_an_unserved_type_is_refused_rather_than_guessed(self):
        with open(os.path.join(self.room, "secrets.env"), "w") as fh:
            fh.write("TOKEN=hunter2")
        status, body, _h = self._get(
            "/api/holodeck/%s/preview/secrets.env" % self.sid)
        self.assertEqual(status, 415)
        self.assertNotIn(b"hunter2", body)

    def test_a_preview_for_an_unknown_session_is_a_404(self):
        status, _b, _h = self._get("/api/holodeck/deadbeef/preview/mockup.html")
        self.assertEqual(status, 404)

    def test_one_programs_room_cannot_read_anothers(self):
        status, other = self._post("/api/holodeck/start",
                                   {"program": "Other deck",
                                    "engine": self.claude_bin})
        self.assertEqual(status, 200, other)
        osid = other["state"]["sessionId"]
        status, body, _h = self._get(
            "/api/holodeck/%s/preview/../nav-rail/mockup.html" % osid)
        self.assertIn(status, (403, 404))
        self.assertNotIn(b"THE DECK", body)


class ReadOnlyDaemonTest(SurfaceBase):
    read_only = True

    def test_no_holodeck_write_is_possible_and_the_reads_are_absent(self):
        # S172 — `duplicate` is a WRITE like its siblings and must be refused
        # by the SAME door, not by a second rule of its own.
        for path in ("/api/holodeck/start", "/api/holodeck/x/say",
                     "/api/holodeck/x/end", "/api/holodeck/duplicate"):
            status, body = self._post(path, {"program": "p", "text": "t"})
            self.assertEqual(status, 403, path)
            self.assertFalse(body["ok"])
        # …and the surface's reads are not there either: a read-only build holds
        # no sessions, so it says 404 rather than pretending to have a deck.
        for path in ("/api/holodeck", "/api/holodeck/x",
                     "/api/holodeck/x/preview/mockup.html"):
            status, _b, _h = self._get(path)
            self.assertEqual(status, 404, path)

    def test_the_board_itself_still_reads_normally(self):
        status, body = self._get_json("/api/board")
        self.assertEqual(status, 200)
        self.assertIn("columns", body)


# ════════════════════════════════════════════════════════════════════════════
# 2. THE DOM HALF — the shipping board.js, booted in node
# ════════════════════════════════════════════════════════════════════════════
def _harness(payload):
    """Run board_holodeck_harness.js with `payload` and return its JSON."""
    fd, path = tempfile.mkstemp(suffix=".json")
    with os.fdopen(fd, "w") as fh:
        json.dump(payload, fh)
    try:
        proc = subprocess.run([NODE, HARNESS, path], stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE)
        if proc.returncode != 0:
            raise AssertionError("harness failed:\n%s"
                                 % proc.stderr.decode("utf-8", "replace"))
        return json.loads(proc.stdout.decode("utf-8"))
    finally:
        os.unlink(path)


PROG = {"sessionId": "s1", "program": "Light / dark theme toggle",
        "mode": "grounding", "status": "draft", "turnCount": 2,
        "previewFile": "mockup.html", "sidecar": "/tmp/groutwork-holodeck",
        "sidecarName": "groutwork-holodeck", "commits": 14,
        "engine": "/usr/bin/claude", "programDir": "/tmp/x/light-dark",
        "openedAt": 1, "lastTouched": 2,
        "turns": [{"text": "The editor needs a light mode.",
                   "reply": "Built both states."},
                  {"text": "Warmer accent.", "reply": "Moved to amber."}]}


@unittest.skipIf(NODE is None, "node not installed")
class DeckRenderTest(unittest.TestCase):
    def test_the_band_carries_the_holodeck_control_and_it_toggles_its_label(self):
        out = _harness({"act": "band"})
        self.assertEqual(out["boardLabel"], "⬡ HOLODECK")
        self.assertEqual(out["deckLabel"], "▦ BOARD")
        # D1: it REPLACES the board content in the same frame. The frame's own
        # furniture — brand, connection pill, rail — is never touched.
        self.assertTrue(out["boardHiddenOnDeck"])
        self.assertFalse(out["boardHiddenOnBoard"])
        self.assertTrue(out["deckHiddenOnBoard"])

    def test_the_deck_has_three_panes_in_the_mocks_order(self):
        """The three panes are unchanged and in the mock's order. S128 adds two
        children between and after them: `deck-split`, D2's amended chat ⇄
        preview handle (which is a grid COLUMN, hence its place in this list),
        and `holo-scrim`, Q3's click-away for the program drawer (out of flow —
        it takes no track)."""
        out = _harness({"act": "deck", "programs": [PROG], "activeId": "s1"})
        self.assertEqual(out["paneClasses"],
                         ["programs", "holo-chat", "deck-split", "preview",
                          "holo-scrim"])
        self.assertIn("deckview", out["deckviewClass"])
        self.assertNotIn("solo", out["deckviewClass"])

    def test_with_no_program_selected_the_deck_is_the_empty_state(self):
        out = _harness({"act": "deck", "programs": [], "activeId": None})
        # no handle: a solo deck has neither a chat nor a preview to split.
        self.assertEqual(out["paneClasses"],
                         ["programs", "holo-empty", "holo-scrim"])
        self.assertIn("solo", out["deckviewClass"])
        # D6: the sidecar path is named ONCE, here, and says what it is.
        self.assertIn("HOLODECK", out["emptyText"].upper())
        self.assertIn("PROGRAM STANDING BY", out["emptyText"].upper())
        self.assertIn("groutwork-holodeck", out["emptyText"])
        self.assertIn("local git", out["emptyText"])
        self.assertIn("pushed only if you ask", out["emptyText"])

    def test_the_chat_renders_both_speakers_and_the_files_a_turn_changed(self):
        out = _harness({"act": "deck", "programs": [PROG], "activeId": "s1",
                        "filesChanged": [{"path": "light-dark/mockup.html",
                                          "status": "modified"},
                                         {"path": "light-dark/concept.md",
                                          "status": "added"}]})
        self.assertEqual(out["turnWho"], ["YOU", "HOLODECK", "YOU", "HOLODECK"])
        self.assertIn("The editor needs a light mode.", out["turnBodies"][0])
        self.assertEqual(out["fileChips"], ["mockup.html", "concept.md"])
        self.assertTrue(out["hasComposer"])
        self.assertEqual(out["sendLabel"], "SEND ▸")

    def test_a_turn_in_flight_shows_the_WORKING_state_and_claims_no_more(self):
        """S169 (FL-015) — it used to say RENDERING ON THE HOLODECK, over a turn
        on which the captain had asked a question. A turn in flight is a turn in
        flight; whether anything is being rendered is not known on either side
        until something has been written."""
        out = _harness({"act": "deck", "programs": [PROG], "activeId": "s1",
                        "busy": True})
        self.assertIn("WORKING ON THE HOLODECK", out["workingText"].upper())
        self.assertNotIn("RENDER", out["workingText"].upper())
        self.assertTrue(out["sendDisabled"])

    def test_the_preview_is_an_iframe_over_the_jailed_route_and_is_sandboxed(self):
        out = _harness({"act": "deck", "programs": [PROG], "activeId": "s1"})
        self.assertTrue(out["iframeSrc"].startswith(
            "/api/holodeck/s1/preview/mockup.html"))
        # THE SECURITY PROPERTY, asserted as one thing: scripts yes (the mock
        # switches its own views), same-origin NEVER — together they would
        # re-grant everything the sandbox took away.
        self.assertIn("allow-scripts", out["iframeSandbox"])
        self.assertNotIn("allow-same-origin", out["iframeSandbox"])
        self.assertNotIn("allow-top-navigation", out["iframeSandbox"])
        self.assertNotIn("allow-popups", out["iframeSandbox"])
        self.assertNotIn("allow-forms", out["iframeSandbox"])

    def test_a_turn_that_changed_the_mockup_refreshes_the_iframe(self):
        out = _harness({"act": "previewRefresh", "programs": [PROG],
                        "activeId": "s1",
                        "filesChanged": [{"path": "light-dark/mockup.html",
                                          "status": "modified"}]})
        # D3: refreshed because the FILE changed — the src is re-pointed with a
        # new cache-buster, never re-rendered from the reply text.
        self.assertNotEqual(out["srcBefore"], out["srcAfter"])
        self.assertTrue(out["srcAfter"].startswith(
            "/api/holodeck/s1/preview/mockup.html?"))

    def test_a_turn_that_changed_nothing_leaves_the_preview_alone(self):
        out = _harness({"act": "previewRefresh", "programs": [PROG],
                        "activeId": "s1", "filesChanged": []})
        self.assertEqual(out["srcBefore"], out["srcAfter"])

    def test_a_program_with_no_mockup_gets_an_empty_state_not_a_dead_iframe(self):
        prog = dict(PROG, previewFile=None)
        out = _harness({"act": "deck", "programs": [prog], "activeId": "s1"})
        self.assertIsNone(out["iframeSrc"])
        self.assertIn("NOTHING ON THE HOLODECK YET", out["previewText"].upper())

    def test_the_program_list_shows_turns_and_recency_in_plain_language(self):
        out = _harness({"act": "deck", "programs": [PROG], "activeId": "s1"})
        self.assertIn("Light / dark theme toggle", out["listNames"])
        self.assertIn("⬡ 2 turns", out["listMeta"][0])
        # D6: after the empty state the sidecar is a name + a commit count only.
        self.assertIn("groutwork-holodeck", out["sidecarChip"])
        self.assertIn("14 commits", out["sidecarChip"])

    def test_the_filter_chips_count_and_actually_filter(self):
        progs = [PROG, dict(PROG, sessionId="s2", program="Tile picker")]
        out = _harness({"act": "filter", "programs": progs, "activeId": "s1"})
        self.assertEqual(out["chipLabels"], ["ALL 2", "DRAFT 2", "SENT 0",
                                             "DONE 0"])
        self.assertEqual(out["shownForAll"], 2)
        self.assertEqual(out["shownForDraft"], 2)
        self.assertEqual(out["shownForSent"], 0)

    def test_the_new_program_dialog_asks_what_and_what_from(self):
        out = _harness({"act": "newProgram"})
        self.assertIn("WHAT ARE WE DESIGNING", out["text"].upper())
        self.assertEqual(out["choiceIds"], ["grounding", "screenshot", "design"])
        # D12: this project's look is the DEFAULT.
        self.assertEqual(out["selected"], "grounding")
        # …and the screenshot option is not a control that errors when clicked:
        # S124's holodeck_start rejects images with a 400, so it is visibly
        # disabled WITH the reason.
        self.assertTrue(out["screenshotDisabled"])
        # S169 FIX ROUND 1 — the reason no longer DENIES the feature. This
        # session taught the composer to take a pasted screenshot, which made
        # the old sentence ("the holodeck cannot take pasted images yet") false
        # four inches from a control that works. The START road really is not
        # built, so the refusal survives; it now names where paste DOES work.
        reason = out["screenshotReason"].lower()
        self.assertNotIn("cannot take pasted images", reason)
        self.assertIn("cannot be started from an image", reason)
        self.assertIn("chat", reason)

    def test_the_dialog_posts_the_mode_the_captain_picked(self):
        for pick, mode in (("grounding", "grounding"), ("design", "design")):
            out = _harness({"act": "newProgramSubmit", "pick": pick,
                            "program": "Nav rail"})
            self.assertEqual(out["path"], "/api/holodeck/start")
            self.assertEqual(out["body"]["mode"], mode)
            self.assertEqual(out["body"]["program"], "Nav rail")

    def test_no_dead_controls_ship_on_the_deck(self):
        out = _harness({"act": "deck", "programs": [PROG], "activeId": "s1"})
        # Everything not yet real is ABSENT or disabled WITH a reason. The
        # INTENT toggle and SEND TO ALIGN are S126/S127; CAPTURE SCREENS is
        # unruled. Whatever is on screen either does something or says why not.
        for ctl in out["controls"]:
            self.assertTrue(
                ctl["wired"] or (ctl["disabled"] and ctl["reason"]),
                "dead control: %r" % ctl["label"])

    # ── D7 — the failure states: CHROME here, the account from the daemon ────
    def test_holodeck_offline_shows_the_daemons_account_and_a_retry(self):
        msg = ("the claude worker stopped mid-turn — your program is safe, "
               "every earlier turn is committed, and the chat is still "
               "running; say it again to retry.")
        out = _harness({"act": "state", "kind": "offline", "message": msg})
        self.assertEqual(out["bannerClass"], "holo-banner down")
        self.assertEqual(out["label"], "HOLODECK OFFLINE")
        self.assertEqual(out["text"], msg)
        self.assertEqual(out["actionLabel"], "RETRY TURN")
        self.assertTrue(out["actionWired"])

    def test_write_refused_renders_the_daemons_account_and_nothing_else(self):
        msg = ("Your program is safe — everything in the holodeck sidecar is "
               "intact and the chat is still running. While that turn was "
               "running, 1 file(s) changed in your project, outside the "
               "holodeck: /Users/x/groutwork/src/theme.css.")
        out = _harness({"act": "state", "kind": "refused",
                        "paths": ["/Users/x/groutwork/src/theme.css"],
                        "message": msg})
        self.assertEqual(out["bannerClass"], "holo-banner refuse")
        self.assertEqual(out["label"], "WRITE REFUSED")
        self.assertEqual(out["text"], msg)

    # ── FIX ROUND 3 — one title per warning kind ─────────────────────────────
    # Both daemon warnings arrived under "TURN NOT CERTIFIED". For a `no-write`
    # turn that is simply false: its audit ran and completed, nothing was left
    # uncertified — the engine answered with the file instead of writing it. The
    # body text was right, only the title lied, which is the half a captain
    # reads first.
    NO_WRITE_MSG = ("That turn answered with the file's contents instead of "
                    "writing it, so nothing was saved and the preview has not "
                    "moved.")
    AUDIT_MSG = ("LCARS could not finish checking your project for changes "
                 "made outside the holodeck this turn.")

    def test_a_wrote_nothing_turn_is_NOT_titled_turn_not_certified(self):
        out = _harness({"act": "sayWarning", "programs": [PROG],
                        "activeId": "s1", "status": "wrote-nothing",
                        "warning": {"kind": "no-write",
                                    "message": self.NO_WRITE_MSG}})
        self.assertEqual(out["bannerKind"], "no-write", out)
        self.assertEqual(out["label"], "NOTHING WAS WRITTEN", out)
        self.assertNotIn("CERTIF", out["label"] or "")
        # the daemon's account is still the only body text.
        self.assertEqual(out["text"], self.NO_WRITE_MSG)

    def test_a_degraded_audit_IS_still_titled_turn_not_certified(self):
        out = _harness({"act": "sayWarning", "programs": [PROG],
                        "activeId": "s1", "status": "unverified",
                        "warning": {"kind": "audit-incomplete",
                                    "message": self.AUDIT_MSG}})
        self.assertEqual(out["bannerKind"], "unverified", out)
        self.assertEqual(out["label"], "TURN NOT CERTIFIED", out)
        self.assertEqual(out["text"], self.AUDIT_MSG)

    def test_an_unknown_warning_kind_still_gets_the_cautious_banner(self):
        out = _harness({"act": "sayWarning", "programs": [PROG],
                        "activeId": "s1", "status": "unverified",
                        "warning": {"kind": "something-new-in-S126",
                                    "message": self.AUDIT_MSG}})
        self.assertEqual(out["bannerKind"], "unverified", out)
        self.assertEqual(out["text"], self.AUDIT_MSG)

    def test_view_only_disables_the_control_with_the_reason_not_silently(self):
        out = _harness({"act": "viewOnly"})
        self.assertTrue(out["present"], "the control must not vanish silently")
        self.assertTrue(out["disabled"])
        self.assertIn("read-only view", out["title"].lower())
        self.assertIn("writes files", out["title"].lower())
        self.assertEqual(out["bannerClass"], "holo-banner ro")
        self.assertIn("open the board locally", out["bannerText"].lower())

    def test_a_write_board_shows_no_view_only_banner_and_an_enabled_control(self):
        out = _harness({"act": "viewOnly", "writes": True})
        self.assertFalse(out["disabled"])
        self.assertTrue(out["bannerHidden"])


@unittest.skipIf(NODE is None, "node not installed")
class DeckCopyAndChromeTest(unittest.TestCase):
    """S125 FIX ROUND 1 — the four surface defects that are all one class: the
    board SAYING something it had not measured."""

    def test_the_empty_state_names_the_sidecar_path_in_full(self):
        """D6's reason for naming the sidecar at all is that the captain must be
        able to BACK IT UP. A basename is not a location; mock screen 2 shows
        `~/Projects/groutwork-holodeck` and its annotation makes that the
        decision ("the only place a path is shown")."""
        out = _harness({"act": "deck", "programs": [], "activeId": None,
                        "sidecarDisplay": "~/Projects/groutwork-holodeck"})
        self.assertIn("~/Projects/groutwork-holodeck", out["emptyText"])

    def test_the_empty_state_falls_back_to_a_name_it_actually_knows(self):
        out = _harness({"act": "deck", "programs": [], "activeId": None,
                        "sidecarDisplay": ""})
        self.assertIn("groutwork-holodeck", out["emptyText"])

    def test_the_dialog_states_the_model_that_will_actually_run(self):
        """`One cheap pass · sonnet tier · read-only` was HARDCODED and is false
        on copilot, where `_holodeck_model` returns claude-opus-4.8. The readout
        must come from the daemon."""
        out = _harness({"act": "newProgram", "engineName": "copilot",
                        "model": "claude-opus-4.8"})
        self.assertIn("claude-opus-4.8", out["footText"])
        self.assertIn("copilot", out["footText"])
        self.assertNotIn("sonnet", out["footText"].lower())

    def test_the_dialog_claims_no_tier_it_has_not_been_told(self):
        out = _harness({"act": "newProgram", "engineName": "", "model": ""})
        self.assertNotIn("sonnet", out["footText"].lower())
        self.assertIn("read-only", out["footText"].lower())

    def test_the_dialog_claims_no_tier_when_the_daemon_named_none(self):
        """S127 keeps fix round 1's rule under a PICKED engine: with no tier
        published for the engine in hand, the line names the engine and stops.
        A guess here is the readout-lie class in its purest form."""
        out = _harness({"act": "newProgram", "engineName": "", "model": ""})
        self.assertIn("copilot", out["footText"].lower())
        self.assertNotIn("claude-opus", out["footText"].lower())

    def test_the_grounded_chip_opens_the_basis_it_is_named_for(self):
        """D12: "the program header links to it". It was an inert SPAN — the
        basis was reachable only by scrolling the raw transcript."""
        out = _harness({"act": "deck", "programs": [dict(
            PROG, grounded=True, basisFile="basis.md")], "activeId": "s1"})
        self.assertEqual(out["groundChipTag"], "a")
        self.assertEqual(out["groundChipHref"],
                         "/api/holodeck/s1/preview/basis.md")

    def test_a_grounded_program_with_no_basis_yet_offers_no_dead_link(self):
        out = _harness({"act": "deck", "programs": [dict(
            PROG, grounded=True, basisFile=None)], "activeId": "s1"})
        self.assertEqual(out["groundChipHref"], None)
        self.assertTrue(out["groundChipReason"])

    def test_an_ungrounded_program_has_no_chip_at_all(self):
        out = _harness({"act": "deck", "programs": [dict(
            PROG, mode="design", grounded=False, basisFile=None)],
            "activeId": "s1"})
        self.assertEqual(out["groundChipTag"], None)


@unittest.skipIf(NODE is None, "node not installed")
class ReplyRenderTest(unittest.TestCase):
    """The chat showed the engine's markdown SOURCE and its tool trace. Mock
    screen 4 is clean prose. This is model-authored text going into the board's
    own DOM, so it is rendered as NODES — `innerHTML` on a reply would be an
    injection hole dressed as a readability fix."""

    MD = ("# Nav rail\n\n"
          "● List directory .\n"
          "└ 3 files found\n"
          "● Create mockup.html +68\n\n"
          "Built the rail with **two** states.\n\n"
          "- collapsed, 56px\n"
          "- expanded, 216px\n\n"
          "| token | value |\n| --- | --- |\n| accent | #2de3c7 |\n\n"
          "```html\n<nav class=\"rail\"></nav>\n```\n")

    def _reply(self, text):
        prog = dict(PROG, turns=[{"text": "go", "reply": text}])
        return _harness({"act": "deck", "programs": [prog], "activeId": "s1"})

    def test_the_markdown_is_rendered_not_printed(self):
        out = self._reply(self.MD)
        body = out["replyText"]
        self.assertNotIn("**", body)
        self.assertNotIn("# Nav rail", body)
        self.assertIn("Nav rail", body)
        self.assertIn("two", body)
        tags = out["replyTags"]
        self.assertIn("h4", tags)
        self.assertIn("ul", tags)
        self.assertIn("table", tags)
        self.assertIn("pre", tags)

    def test_the_engines_tool_trace_never_reaches_the_chat(self):
        out = self._reply(self.MD)
        body = out["replyText"]
        for leak in ("List directory", "3 files found", "Create mockup.html +68"):
            self.assertNotIn(leak, body)

    def test_a_paragraph_of_plain_prose_is_not_dropped(self):
        """The browser-only defect the first cut of this renderer shipped: it
        guarded `if (para.children.length)` before appending a paragraph, and in
        a real browser `children` is ELEMENTS ONLY — so a paragraph with no
        bold, code or links in it had no element children and was silently
        thrown away. Two of three replies rendered as fragments in Chrome while
        every assertion here was green (the stub had text nodes in `children`).
        The stub is now element-only, so this test can see it."""
        out = self._reply("Built the rail.\n\n"
                          "It carries no styling marks at all.\n\n"
                          "Say the word and I will widen it.\n")
        self.assertIn("It carries no styling marks at all.", out["replyText"])
        self.assertIn("Say the word and I will widen it.", out["replyText"])
        self.assertEqual(out["replyTags"].count("p"), 3)

    def test_prose_that_merely_starts_with_a_bullet_glyph_survives(self):
        out = self._reply("● The accent reads warmer than teal.\n")
        self.assertIn("accent reads warmer", out["replyText"])

    def test_model_text_is_never_written_as_html(self):
        out = self._reply("<img src=x onerror=alert(1)> and <b>bold</b>\n")
        self.assertIn("<img src=x onerror=alert(1)>", out["replyText"])
        self.assertEqual(out["replyInnerHtmlCalls"], 0)
        self.assertNotIn("img", out["replyTags"])


@unittest.skipIf(NODE is None, "node not installed")
class ReplyNeverLosesTextTest(unittest.TestCase):
    """S125 FIX ROUND 2 · N1 — THE CLEANER SILENTLY DELETED REAL PROSE.

    Round 1 dropped every line matching `/^\\s*[└⎿├│]/`. A captain sketched a
    rail layout in chat and got back `┌────────────┐` alone: the `│ SWATCHES │`
    body and the closing `└────┘` were destroyed with nothing on screen to say
    so. That is the second generation of the same guess, and a third regex would
    be beaten too — so the MECHANISM changed. Recognized activity is FOLDED, not
    filtered, and the segments together are always the whole reply.

    The KNOWN MISSES are encoded here on purpose: a future, cleverer recognizer
    may reclassify these lines, but it can never again make them disappear."""

    def _reply(self, text):
        prog = dict(PROG, turns=[{"text": "go", "reply": text}])
        return _harness({"act": "deck", "programs": [prog], "activeId": "s1"})

    DIAGRAM = ("Here is the shape I have in mind:\n\n"
               "┌────────────┐\n"
               "│  SWATCHES  │\n"
               "├────────────┤\n"
               "│  PREVIEW   │\n"
               "└────────────┘\n\n"
               "The rail sits to the left of both.\n")

    def test_an_ascii_diagram_survives_whole(self):
        out = self._reply(self.DIAGRAM)
        for line in ("┌────────────┐", "│  SWATCHES  │", "├────────────┤",
                     "│  PREVIEW   │", "└────────────┘"):
            self.assertIn(line.strip(), out["replyAllText"],
                          "the diagram lost a row: %r" % line)
        self.assertIn("The rail sits to the left of both.", out["replyText"])
        self.assertEqual(out["traceBlocks"], [],
                         "a diagram is not tool activity")

    def test_a_bulleted_design_note_that_starts_with_a_tool_verb_survives(self):
        """`● Read …` and `● Update …` — a bullet glyph plus a word that happens
        to be a tool verb. Both were eaten. Both are sentences."""
        out = self._reply(
            "Two things before you sign this off.\n\n"
            "● Read the swatch labels before you decide the accent.\n"
            "● Update the radius only if the swatches move with it.\n\n"
            "Then it is yours.\n")
        self.assertIn("swatch labels before you decide", out["replyText"])
        self.assertIn("radius only if the swatches move", out["replyText"])

    def test_recognized_tool_activity_is_folded_not_deleted(self):
        out = self._reply("● List directory .\n"
                          "└ 3 files found\n"
                          "● Create mockup.html +68\n\n"
                          "Built the rail with two states.\n")
        # out of the prose…
        self.assertNotIn("List directory", out["replyText"])
        self.assertNotIn("3 files found", out["replyText"])
        self.assertIn("Built the rail with two states.", out["replyText"])
        # …but STILL THERE, collapsed, and openable.
        blob = "\n".join(out["traceBlocks"])
        for line in ("● List directory .", "└ 3 files found",
                     "● Create mockup.html +68"):
            self.assertIn(line, blob)
        self.assertEqual(out["traceHidden"], [True])
        self.assertIn("tool activity", out["traceSummaries"][0])

    def test_nothing_the_model_wrote_is_ever_dropped(self):
        """The guarantee, stated as a test over every fixture in this file: the
        rendered node holds every non-blank line of the reply."""
        for name, text in (("diagram", self.DIAGRAM),
                           ("trace", ReplyRenderTest.MD),
                           ("mixed", "● Read the notes\n┌──┐\n│ok│\n└──┘\n")):
            out = self._reply(text)
            painted = out["replyAllText"]
            for line in text.split("\n"):
                bare = line.strip().strip("`")
                if not bare or bare.startswith("|") or bare.startswith("#") \
                        or bare.startswith("-") or bare.startswith("*"):
                    continue     # markdown SOURCE is rendered, not printed
                self.assertIn(bare.replace("**", ""), painted,
                              "%s lost: %r" % (name, line))

    def test_a_fences_declared_filename_reaches_the_screen(self):
        """S126 (#8). The turn prompt asks for ```file:<path> when a write tool
        fails, and the DAEMON writes those blocks — so the info string names the
        file the captain is looking at. The render dropped it, leaving a bare
        slab of HTML with nothing saying which file it became."""
        out = self._reply("Here you go.\n\n"
                          "```html file:mockup.html\n<nav class=\"rail\"></nav>\n```\n")
        self.assertEqual(out["fenceInfos"], ["html file:mockup.html"])
        self.assertIn("mockup.html", out["replyAllText"])
        # and the block itself is untouched — the label is added, nothing moved.
        self.assertEqual(out["preTexts"], ["<nav class=\"rail\"></nav>"])

    def test_a_fence_with_no_info_string_gets_no_empty_label(self):
        out = self._reply("Here you go.\n\n```\n<nav></nav>\n```\n")
        self.assertEqual(out["fenceInfos"], [])
        self.assertEqual(out["preTexts"], ["<nav></nav>"])

    def test_the_fence_label_is_a_text_node_like_everything_else(self):
        out = self._reply("```<img src=x onerror=alert(1)>\nhi\n```\n")
        self.assertEqual(out["replyInnerHtmlCalls"], 0)
        self.assertEqual(out["fenceInfos"], ["<img src=x onerror=alert(1)>"])
        self.assertNotIn("img", out["replyTags"])

    def test_folded_activity_is_still_never_written_as_html(self):
        out = self._reply("● Read <img src=x onerror=alert(1)>/evil.txt\n")
        self.assertEqual(out["replyInnerHtmlCalls"], 0)
        self.assertIn("<img src=x onerror=alert(1)>",
                      "\n".join(out["traceBlocks"]) + out["replyAllText"])
        self.assertNotIn("img", out["replyTags"])


@unittest.skipIf(NODE is None, "node not installed")
class OneVoiceBannerTest(unittest.TestCase):
    """S125 FIX ROUND 2 · N2/N3 — every banner said everything twice, and the
    client's half re-asserted the authorship claim round 1 had just cured on the
    server. The client's parallel copy is DELETED: chrome here, account there."""

    SERVER_REFUSAL = (
        "Your program is safe — everything in the holodeck sidecar is intact "
        "and the chat is still running. While that turn was running, 1 file(s) "
        "changed in your project, outside the holodeck: /Users/x/g/src/theme.css. "
        "LCARS watches the files, not who touched them — it cannot tell whether "
        "the holodeck went outside its room or something else on your machine "
        "did.")

    def test_the_refusal_says_each_thing_once(self):
        out = _harness({"act": "state", "kind": "refused",
                        "paths": ["/Users/x/g/src/theme.css"],
                        "message": self.SERVER_REFUSAL})
        text = out["text"]
        self.assertEqual(text.count("/Users/x/g/src/theme.css"), 1)
        self.assertEqual(text.lower().count("your program is safe"), 1)
        self.assertEqual(text.lower().count("chat is still running"), 1)
        self.assertLess(len(text), 900,
                        "round 1's refusal banner ran to 1208 characters")

    def test_the_client_makes_no_claim_about_who_touched_the_files(self):
        """The client used to say the holodeck 'never touches your project, and
        nothing out there has been changed or removed by LCARS' — an AUTHORSHIP
        claim, directly above the server's 'LCARS watches the files, not who
        touched them'. The detection is a before/after walk; it sees a change,
        never an author."""
        out = _harness({"act": "state", "kind": "refused",
                        "paths": ["/Users/x/g/src/theme.css"],
                        "message": self.SERVER_REFUSAL})
        low = out["text"].lower()
        self.assertNotIn("never touches your project", low)
        self.assertNotIn("changed or removed by lcars", low)

    def test_an_unverified_turn_is_the_daemons_sentence_verbatim(self):
        msg = ("LCARS could not fully check your project for stray writes this "
               "turn — it stopped after 5 files.")
        out = _harness({"act": "state", "kind": "unverified", "message": msg})
        self.assertEqual(out["text"], msg)
        self.assertEqual(out["label"], "TURN NOT CERTIFIED")


@unittest.skipIf(NODE is None, "node not installed")
class RetrySaysItOnceTest(unittest.TestCase):
    """S125 FIX ROUND 2 · N6 — RETRY TURN appended the captain's line a second
    time, so the transcript showed him saying it twice. He said it once."""

    def test_retry_does_not_repeat_the_captains_line(self):
        prog = dict(PROG, turns=[])
        out = _harness({"act": "retry", "programs": [prog], "activeId": "s1",
                        "text": "make the rail wider"})
        self.assertEqual(out["retryLabel"], "RETRY TURN")
        self.assertEqual(out["saidCount"], 1,
                         "the transcript shows it twice: %r" % out["turnTexts"])
        self.assertEqual(out["posts"], 2, "the retry must still be sent")


@unittest.skipIf(NODE is None, "node not installed")
class ProgramListIsLegibleTest(unittest.TestCase):
    """S125 FIX ROUND 2 — a name the collision check cannot honestly refuse (a
    homoglyph) must at least be TELLABLE APART on the list. The room is the
    discriminator, and it was not on screen."""

    def test_each_card_names_its_room(self):
        a = dict(PROG, sessionId="s1", program="Tile picker sidebar",
                 room="tile-picker-sidebar")
        b = dict(PROG, sessionId="s2", program="Tile picker sidebаr",
                 room="tile-picker-sidebr")
        out = _harness({"act": "deck", "programs": [a, b], "activeId": "s1"})
        joined = " ".join(out["listMeta"])
        self.assertIn("tile-picker-sidebar", joined)
        self.assertIn("tile-picker-sidebr", joined)

    def test_the_room_reuse_disclosure_is_its_own_banner(self):
        msg = ("This program's room already holds work from an earlier program "
               "of the same name: 2 file(s) — concept.md, mockup.html.")
        out = _harness({"act": "state", "kind": "notice", "message": msg})
        self.assertEqual(out["bannerClass"], "holo-banner note")
        self.assertEqual(out["text"], msg)
        self.assertNotEqual(out["label"], "HOLODECK OFFLINE")


# ════════════════════════════════════════════════════════════════════════════
# S126 — THE DECK'S HALF OF DURABLE PROGRAMS
#
# The daemon now reads the sidecar, so the program list has two kinds of card:
# a LIVE conversation and a room ON DISK the daemon has never held. The second
# kind is the whole point of the session, and the honesty bar is specific: it
# must never read as a resumed session, because it is not one.
# ════════════════════════════════════════════════════════════════════════════
DISK_PROG = {"sessionId": None, "onDisk": True, "program": "Tile picker",
             "room": "tile-picker", "status": "draft", "turnCount": 7,
             "previewFile": "mockup.html", "sidecarName": "groutwork-holodeck",
             "commits": 14, "engine": "/usr/bin/claude",
             "programDir": "/tmp/x/tile-picker", "conceptFile": "concept.md",
             "openedAt": 1, "lastTouched": 1, "turns": []}


@unittest.skipIf(NODE is None, "node not installed")
class DurableDeckTest(unittest.TestCase):
    def test_a_room_on_disk_is_listed_beside_the_live_conversations(self):
        out = _harness({"act": "deck", "programs": [PROG, DISK_PROG],
                        "activeId": "s1"})
        self.assertIn("Tile picker", out["listNames"])
        self.assertIn("Light / dark theme toggle", out["listNames"])

    def test_the_list_says_when_each_program_was_last_WORKED(self):
        """D8 — "which one was that" is the question a captain asks days later,
        and a bare relative time answers a different one."""
        out = _harness({"act": "deck", "programs": [PROG, DISK_PROG],
                        "activeId": "s1"})
        joined = " ".join(out["listMeta"])
        self.assertIn("last worked", joined.lower())
        # old work falls back to a stardate rather than "20,000 days ago".
        self.assertIn("stardate", joined.lower())

    def test_a_room_on_disk_says_it_is_not_a_running_conversation(self):
        out = _harness({"act": "deck", "programs": [PROG, DISK_PROG],
                        "activeId": "s1"})
        rows = {r["name"]: r for r in out["listRows"]}
        self.assertTrue(rows["Tile picker"]["onDisk"])
        self.assertFalse(rows["Light / dark theme toggle"]["onDisk"])

    def test_clicking_a_room_on_disk_asks_the_daemon_to_reopen_it(self):
        out = _harness({"act": "openDisk", "programs": [PROG, DISK_PROG],
                        "activeId": "s1", "room": "tile-picker"})
        self.assertEqual(out["path"], "/api/holodeck/open")
        self.assertEqual(out["body"], {"room": "tile-picker"})

    def test_a_reopened_program_is_announced_as_a_FRESH_worker(self):
        """S125's finding #2 in a new place. The deck adds no words of its own
        (the one-voice rule) — it renders the daemon's account, which says
        `fresh`, and it must never print or imply a session id."""
        msg = ("Picked this program back up from its room on disk. The "
               "conversation that built it is over — the claude that answers "
               "your next turn is a fresh one, handed the whole transcript "
               "(7 turns) as context.")
        out = _harness({"act": "state", "kind": "restart", "message": msg})
        self.assertEqual(out["text"], msg)
        self.assertNotEqual(out["label"], "HOLODECK OFFLINE")
        self.assertNotIn("resumed", (out["label"] or "").lower())
        self.assertNotIn("resumed", out["text"].lower())

    def test_a_program_can_be_deleted_and_the_deck_says_it_is_recoverable(self):
        out = _harness({"act": "deleteProgram", "programs": [PROG, DISK_PROG],
                        "activeId": "s1", "room": "tile-picker"})
        # it CONFIRMS first — and the confirmation's whole job is to say the
        # archive keeps it, so the answer is not frightening.
        self.assertIn("tile-picker", out["confirmText"])
        low = out["confirmText"].lower()
        self.assertTrue("git" in low or "history" in low, out["confirmText"])
        self.assertEqual(out["path"], "/api/holodeck/delete")
        self.assertEqual(out["body"], {"room": "tile-picker"})

    def test_the_confirmation_does_not_promise_more_than_delete_can_do(self):
        """FIX ROUND 3, defect 1. The daemon's reply used to promise a recovery
        that did not exist; this dialog made the same promise one step earlier,
        flatly and in advance — "nothing is destroyed". It now describes the
        mechanism: the program is recorded FIRST, and if it cannot be recorded
        nothing is removed."""
        out = _harness({"act": "deleteProgram", "programs": [PROG, DISK_PROG],
                        "activeId": "s1", "room": "tile-picker",
                        "stopAtConfirm": True})
        text = out["confirmText"]
        low = text.lower()
        self.assertNotIn("nothing is destroyed", low, text)
        # it says the recording happens BEFORE the room goes…
        self.assertIn("first", low, text)
        # …and what happens when that cannot be done.
        self.assertTrue("refus" in low or "will not" in low, text)

    def test_nothing_is_deleted_until_the_confirmation_is_taken(self):
        out = _harness({"act": "deleteProgram", "programs": [PROG, DISK_PROG],
                        "activeId": "s1", "room": "tile-picker",
                        "stopAtConfirm": True})
        self.assertIsNone(out["path"])

    def test_the_concept_doc_is_readable_when_the_program_has_one(self):
        """The same argument that made `basis.md` a link in S125: a document
        that is handed to a Mission and that the captain cannot open is one he
        cannot correct.

        S127 (FL-007) — THE CLAIM IS UNCHANGED; WHERE IT IS READ MOVED. This
        used to assert an `<a target="_blank">` into a browser tab of raw
        markdown, which is the defect the captain reported: the control is
        drawn as half of a segmented toggle, so it must behave as one. The
        readability requirement is asserted here against the toggle, and the
        panel itself is `IntentIsARealToggleTest`.
        """
        out = _harness({"act": "intentToggle",
                        "programs": [dict(PROG, conceptFile="concept.md")],
                        "activeId": "s1"})
        # still fetched over the SAME jailed route the old link pointed at.
        self.assertIn("/api/holodeck/s1/preview/concept.md", out["fetched"])
        self.assertFalse(out["afterIntent"]["intentHidden"])
        self.assertTrue(out["afterIntent"]["intentHtml"])

    def test_with_no_concept_doc_the_intent_control_says_why_not(self):
        out = _harness({"act": "deck", "programs": [dict(PROG,
                                                         conceptFile=None)],
                        "activeId": "s1"})
        self.assertEqual(out["intentTag"], "span")
        reason = out["intentReason"].lower()
        self.assertIn("concept.md", reason)
        # and it no longer claims the holodeck does not write one — it does.
        self.assertNotIn("not writing concept.md", reason)

    def test_the_intent_reason_covers_an_EMPTY_concept_doc_too(self):
        """FIX ROUND 2 — `conceptFile` is now null for an EMPTY concept.md as
        well as a missing one (a control that opens a blank tab is worse than
        no control). So this sentence is read by a captain who may be looking
        at a concept.md in his own room: it must not tell him the file is not
        there."""
        out = _harness({"act": "deck", "programs": [dict(PROG,
                                                         conceptFile=None)],
                        "activeId": "s1"})
        low = out["intentReason"].lower()
        self.assertNotIn("has no concept.md", low)
        self.assertNotIn("does not exist", low)

    def test_a_turn_that_moved_the_mockup_without_a_concept_doc_says_so(self):
        out = _harness({"act": "conceptAudit", "programs": [PROG],
                        "activeId": "s1",
                        "conceptAudit": {
                            "status": "missing", "file": "concept.md",
                            "message": "The mockup changed but this program "
                                       "still has no concept.md."}})
        self.assertIn("concept.md", out["conceptNote"])
        self.assertIn("no concept.md", out["conceptNote"])

    def test_a_clean_concept_audit_puts_no_warning_on_the_turn(self):
        out = _harness({"act": "conceptAudit", "programs": [PROG],
                        "activeId": "s1",
                        "conceptAudit": {"status": "ok", "file": "concept.md",
                                         "updated": True,
                                         "message": "concept.md was updated."}})
        self.assertEqual(out["conceptNote"], "")

    def test_no_dead_controls_ship_on_the_deck_with_disk_programs(self):
        out = _harness({"act": "deck", "programs": [PROG, DISK_PROG],
                        "activeId": "s1"})
        for ctl in out["controls"]:
            self.assertTrue(
                ctl["wired"] or (ctl["disabled"] and ctl["reason"]),
                "dead control: %r" % ctl["label"])


# ════════════════════════════════════════════════════════════════════════════
# FIX ROUND 2 · DEFECT 5 — ONE VOICE, ABOUT THE SAME FACT
#
# On a program picked back up the header showed `WARM · CLAUDE` two inches
# under a banner saying the conversation is over and the next worker is a fresh
# one. "Warm" is the exact word for the thing that did NOT survive. The pill
# was ASSERTING warmth; the daemon has always KNOWN it (`sess.started` — the
# same evidence N4's cure is keyed off), and now says so on the payload.
# ════════════════════════════════════════════════════════════════════════════
@unittest.skipIf(NODE is None, "node not installed")
class WarmPillTellsTheTruthTest(unittest.TestCase):
    def test_a_warm_program_still_says_warm(self):
        out = _harness({"act": "deck", "programs": [dict(PROG, warm=True)],
                        "activeId": "s1"})
        self.assertIn("WARM", out["headPill"].upper())
        self.assertIn("CLAUDE", out["headPill"].upper())

    def test_a_program_picked_back_up_does_NOT_claim_to_be_warm(self):
        out = _harness({"act": "deck",
                        "programs": [dict(PROG, warm=False, restarted=True)],
                        "activeId": "s1"})
        self.assertNotIn("WARM", out["headPill"].upper())
        # it still names the engine — that half was never in doubt.
        self.assertIn("CLAUDE", out["headPill"].upper())
        # and it says what IS true, rather than going silent.
        self.assertTrue(out["headPillReason"], out)

    def test_a_program_that_has_not_spoken_yet_does_not_claim_to_be_warm(self):
        out = _harness({"act": "deck",
                        "programs": [dict(PROG, warm=False, turns=[])],
                        "activeId": "s1"})
        self.assertNotIn("WARM", out["headPill"].upper())

    def test_the_pill_does_not_restate_the_restart_banner_in_its_own_words(self):
        """ONE VOICE (fix round 3). The banner is the whole account of a warm
        restart — the conversation is over, the next worker is fresh, and it is
        handed the transcript as context. The pill's tooltip said that last
        part again, in different words, two inches below it. The tooltip's job
        is the PILL's own fact: whether a session is open."""
        out = _harness({"act": "deck",
                        "programs": [dict(PROG, warm=False, restarted=True)],
                        "activeId": "s1"})
        reason = out["headPillReason"]
        low = reason.lower()
        self.assertTrue(reason, out)
        for echoed in ("transcript", "context", "spent"):
            self.assertNotIn(echoed, low, reason)
        # it still says the one thing the pill is about.
        self.assertIn("session", low, reason)

    def test_the_first_turn_that_opens_the_session_turns_the_pill_warm(self):
        """The daemon answers `warm` on the turn payload, so the pill must not
        wait for the next poll to stop contradicting the screen."""
        out = _harness({"act": "sayWarning", "programs": [dict(PROG,
                                                               warm=False)],
                        "activeId": "s1", "status": "ok", "warm": True})
        self.assertIn("WARM", out["headPill"].upper())


# ════════════════════════════════════════════════════════════════════════════
# S127 — THE ENGINE PICKER IN ⬡ NEW PROGRAM
#
# The captain opened the viewscreen with no $LCARS_WORKER_BIN and EVERY program
# died on a 502 telling him to go and restart the daemon. He could not run one
# program on claude and the next on copilot without a restart between them —
# which is the whole holodeck premise ("he never sees the plumbing") failing at
# the first click. The daemon already took an engine on `/api/holodeck/start`;
# nothing in front of him could name one.
#
# It copies the FILE console's picker exactly — `.choice` / `.opt` / sel /
# aria-pressed / keyActivable — because that is the picker he already knows,
# and S140 made it keyboard-operable.
# ════════════════════════════════════════════════════════════════════════════
MODELS = {"claude": "sonnet", "copilot": "claude-opus-4.8"}


@unittest.skipIf(NODE is None, "node not installed")
class NewProgramEnginePickerTest(unittest.TestCase):
    def test_the_dialog_offers_both_engines(self):
        out = _harness({"act": "newProgram"})
        labels = " ".join(out["engineOpts"]).lower()
        self.assertIn("claude", labels)
        self.assertIn("copilot", labels)

    def test_the_picker_is_keyboard_operable_like_the_file_consoles(self):
        """S140 made every picker a Tab stop that Enter/Space activates. A new
        picker that is mouse-only is that guarantee regressing."""
        out = _harness({"act": "newProgram"})
        self.assertEqual(out["engineRoles"], ["button", "button"])
        self.assertEqual(out["engineTabIndex"], ["0", "0"])
        self.assertEqual(sorted(out["enginePressed"]), ["false", "true"])

    def test_it_preselects_the_engine_the_daemon_was_started_with(self):
        """A daemon started `LCARS_WORKER_BIN=claude` must behave EXACTLY as it
        does today — the picker is a new freedom, not a new surprise."""
        for name in ("claude", "copilot"):
            out = _harness({"act": "newProgram", "engineName": name,
                            "models": MODELS})
            self.assertEqual(len(out["engineSel"]), 1, out["engineOpts"])
            self.assertIn(name, out["engineSel"][0].lower())

    def test_an_unconfigured_daemon_preselects_the_FREE_engine(self):
        """THE MONEY DEFAULT. The holodeck is explicitly the cheap room; copilot
        is free for this captain and claude is billed. With nothing configured,
        the selection sitting under his cursor must not be the one that spends."""
        out = _harness({"act": "newProgram", "engineName": "", "model": "",
                        "models": MODELS})
        self.assertEqual(len(out["engineSel"]), 1)
        self.assertIn("copilot", out["engineSel"][0].lower())

    def test_the_start_body_carries_the_engine_he_picked(self):
        for engine in ("claude", "copilot"):
            out = _harness({"act": "newProgramSubmit", "pick": "grounding",
                            "engine": engine, "models": MODELS})
            self.assertEqual(out["path"], "/api/holodeck/start")
            self.assertEqual(out["body"]["engine"], engine, out["body"])
            # …and the mode it has always sent is untouched.
            self.assertEqual(out["body"]["mode"], "grounding")

    def test_the_engine_can_be_picked_without_a_mouse(self):
        for key in ("Enter", " "):
            out = _harness({"act": "newProgramSubmit", "pick": "grounding",
                            "engine": "claude", "viaKey": key,
                            "models": MODELS})
            self.assertEqual(out["body"]["engine"], "claude", key)

    def test_a_daemon_default_still_reaches_the_body_untouched(self):
        """Nothing is picked, the daemon runs claude: the start body says
        claude. The picker cannot quietly move a configured daemon."""
        out = _harness({"act": "newProgramSubmit", "pick": "grounding",
                        "engineName": "claude", "models": MODELS})
        self.assertEqual(out["body"]["engine"], "claude")

    def test_keeping_the_daemons_engine_sends_the_daemons_OWN_binary(self):
        """A daemon started `LCARS_WORKER_BIN=/opt/wrap/claude` must behave
        EXACTLY as it does today. Sending the bare name `claude` would hand the
        program to whichever claude $PATH happens to find — a different binary,
        chosen by a control the captain never touched."""
        out = _harness({"act": "newProgramSubmit", "pick": "grounding",
                        "engineName": "claude", "engineBin": "/opt/wrap/claude",
                        "models": MODELS})
        self.assertEqual(out["body"]["engine"], "/opt/wrap/claude")

    def test_picking_the_OTHER_engine_sends_that_engine_by_name(self):
        """…and the daemon's binary does NOT follow him to the other engine."""
        out = _harness({"act": "newProgramSubmit", "pick": "grounding",
                        "engineName": "claude", "engineBin": "/opt/wrap/claude",
                        "engine": "copilot", "models": MODELS})
        self.assertEqual(out["body"]["engine"], "copilot")


@unittest.skipIf(NODE is None, "node not installed")
class NewProgramFooterIsOneSentenceTest(unittest.TestCase):
    """FL-001 — the footer hint was assembled ONCE at build time and never
    rebuilt, so it lied in two directions the moment either choice moved.

    Every assertion here is about the sentence CHANGING. An assertion that only
    checked the wording of one state is exactly what let FL-001 ship: the line
    read perfectly true for the option that happened to be selected."""

    def test_the_tier_follows_the_PICKED_engine_not_the_daemons(self):
        out = _harness({"act": "newProgramFoot", "engineName": "claude",
                        "model": "sonnet", "models": MODELS,
                        "clicks": [{"engine": "copilot"}]})
        first, second = out["foots"][0], out["foots"][1]
        self.assertNotEqual(first, second, out["foots"])
        self.assertIn("sonnet", first.lower())
        self.assertIn("claude-opus-4.8", second)
        self.assertNotIn("sonnet", second.lower())

    def test_picking_back_returns_the_sentence_it_started_with(self):
        out = _harness({"act": "newProgramFoot", "engineName": "claude",
                        "models": MODELS,
                        "clicks": [{"engine": "copilot"},
                                   {"engine": "claude"}]})
        self.assertEqual(out["foots"][0], out["foots"][2], out["foots"])
        self.assertNotEqual(out["foots"][0], out["foots"][1])

    def test_a_blank_deck_stops_claiming_a_read_only_pass(self):
        """THE FL-001 DEFECT ITSELF. `· read-only` was appended unconditionally
        and describes a read that never happens on Blank deck — no pass is made
        over the captain's project at all."""
        out = _harness({"act": "newProgramFoot", "models": MODELS,
                        "engineName": "copilot",
                        "clicks": [{"mode": "design"}]})
        grounded, blank = out["foots"][0], out["foots"][1]
        self.assertNotEqual(grounded, blank, out["foots"])
        self.assertIn("read-only", grounded.lower())
        self.assertNotIn("read-only", blank.lower())

    def test_going_back_to_this_projects_look_restores_the_read_only_claim(self):
        out = _harness({"act": "newProgramFoot", "models": MODELS,
                        "engineName": "copilot",
                        "clicks": [{"mode": "design"},
                                   {"mode": "grounding"}]})
        self.assertIn("read-only", out["foots"][2].lower())
        self.assertEqual(out["foots"][0], out["foots"][2], out["foots"])

    def test_mode_and_engine_move_the_SAME_sentence(self):
        """ONE FUNCTION, ONE SENTENCE. S125 lost two fix rounds to a cure that
        added a second string beside the first — both rendered, one true."""
        out = _harness({"act": "newProgramFoot", "models": MODELS,
                        "engineName": "claude",
                        "clicks": [{"mode": "design"}, {"engine": "copilot"}]})
        self.assertEqual(out["footHints"], 1, out["foots"])
        last = out["foots"][3 - 1]
        self.assertIn("claude-opus-4.8", last)
        self.assertNotIn("read-only", last.lower())
        self.assertEqual(len(set(out["foots"])), 3, out["foots"])


# ════════════════════════════════════════════════════════════════════════════
# FIX ROUND 5 — THE DECK'S HALF OF "WHICH ENGINE BUILT THIS"
#
# `holoOpen` posted `{room}` and nothing else, so the daemon had only its own
# default to fall back on. The deck now relays the engine it was HANDED for
# that program — never one it picked — and the pill says plainly when the
# record does not name one, instead of letting the default read as the answer.
# ════════════════════════════════════════════════════════════════════════════
@unittest.skipIf(NODE is None, "node not installed")
class DeckRelaysTheRecordedEngineTest(unittest.TestCase):
    def test_reopening_sends_the_engine_the_program_was_built_on(self):
        prog = dict(DISK_PROG, engine="/usr/bin/copilot", engineRecorded=True)
        out = _harness({"act": "openDisk", "programs": [PROG, prog],
                        "activeId": "s1", "room": "tile-picker"})
        self.assertEqual(out["path"], "/api/holodeck/open")
        self.assertEqual(out["body"], {"room": "tile-picker",
                                       "engine": "/usr/bin/copilot"})

    def test_a_reopen_ignores_a_DIFFERING_daemon_default(self):
        """S127 GUARD. The New Program dialog now carries an engine selection
        with a default of its own, and a reopen must be blind to it: the record
        wins. Driven with the daemon's engine set to CLAUDE (billed) and the
        program built on COPILOT (free) — the direction that spends."""
        prog = dict(DISK_PROG, engine="/usr/bin/copilot", engineRecorded=True)
        out = _harness({"act": "openDisk", "programs": [PROG, prog],
                        "activeId": "s1", "room": "tile-picker",
                        "engineName": "claude", "models": MODELS})
        self.assertEqual(out["body"], {"room": "tile-picker",
                                       "engine": "/usr/bin/copilot"})

    def test_a_record_that_names_no_engine_sends_none(self):
        """It relays a FACT or nothing. Sending the default here would make the
        deck a second source of truth for the engine, and an explicit engine
        outranks the record — so this would silently pin the wrong CLI."""
        prog = dict(DISK_PROG, engineRecorded=False)
        out = _harness({"act": "openDisk", "programs": [PROG, prog],
                        "activeId": "s1", "room": "tile-picker"})
        self.assertEqual(out["body"], {"room": "tile-picker"})

    def test_the_pill_says_the_program_was_designed_on_this_engine(self):
        out = _harness({"act": "deck",
                        "programs": [dict(PROG, engineRecorded=True)],
                        "activeId": "s1"})
        self.assertIn("CLAUDE", out["headPill"].upper())
        self.assertIn("designed on", out["headPillReason"].lower(),
                      out["headPillReason"])

    def test_the_pill_never_claims_an_engine_the_record_does_not_name(self):
        """HONEST DEGRADATION. Every program built before this round has no
        engine in its record; "designed on claude" would be an invention."""
        out = _harness({"act": "deck",
                        "programs": [dict(PROG, engineRecorded=False)],
                        "activeId": "s1"})
        reason = out["headPillReason"]
        low = reason.lower()
        # the CLAIM, in the exact words the recorded branch uses, is absent…
        self.assertNotIn("it is the engine this program was designed on", low,
                         reason)
        # …and what replaces it is the plain fact that nobody knows.
        self.assertTrue("does not say" in low or "not recorded" in low, reason)
        # it still names what WILL answer — going silent is its own dishonesty.
        self.assertIn("CLAUDE", out["headPill"].upper())


# ════════════════════════════════════════════════════════════════════════════
# FIX ROUND 5 — COPILOT'S FAILED TOOL BLOCK, IN THE CHAT
#
# `HOLO_TOOL_LINE` matched `[●⏺◆]`, so the `✗` head copilot really printed
# rendered as a design decision in the middle of the captain's conversation.
# The chat FOLDS (one click restores it); nothing here can delete a character.
# ════════════════════════════════════════════════════════════════════════════
@unittest.skipIf(NODE is None, "node not installed")
class FailedToolBlockFoldsTest(unittest.TestCase):
    REPLY = ("I'll add a Density toggle chip.\n\n"
             "✗ Edit mockup.html\n"
             "  └ Multiple matches found\n\n"
             "I added a `.compact` class on the board.")

    def _out(self):
        prog = dict(PROG, turns=[{"text": "compact it", "reply": self.REPLY}])
        return _harness({"act": "deck", "programs": [prog], "activeId": "s1"})

    def test_a_failed_tool_block_is_not_shown_as_a_design_decision(self):
        out = self._out()
        self.assertNotIn("✗ Edit mockup.html", out["replyText"])
        # (the backticks are rendered as inline code, so the projection has
        # the words without them)
        self.assertIn(".compact class on the board", out["replyText"])

    def test_it_is_folded_and_never_deleted(self):
        out = self._out()
        self.assertIn("✗ Edit mockup.html",
                      "\n".join(out["traceBlocks"]))
        self.assertIn("Multiple matches found", out["replyAllText"])

    def test_a_failed_shaped_sentence_is_still_prose(self):
        """The recognizer's own rule is unchanged: a tool VERB and an
        ARGUMENT-shaped tail. `✗ Delete the old rail` is a sentence."""
        prog = dict(PROG, turns=[{"text": "x", "reply":
                                  "✗ Delete the old rail it never shipped"}])
        out = _harness({"act": "deck", "programs": [prog], "activeId": "s1"})
        self.assertIn("✗ Delete the old rail", out["replyText"])


# ════════════════════════════════════════════════════════════════════════════
# FIX ROUND 2 · DEFECT 6 — THE MORNING STATE
#
# Yesterday's program is in the list on the left and the whole main area reads
# HOLODECK / PROGRAM STANDING BY / "Describe a screen…" / ＋ NEW PROGRAM.
# Nothing tells the captain to click the program on the left, and the one
# prominent button is the wrong move: under the same name it triggers the
# room-reuse disclosure, under a different one it splits his work in two.
#
# THE GUARD IS CORRECT AND UNTOUCHED — it deliberately auto-selects only a LIVE
# program, because auto-selecting an archived one hands him a composer that
# 404s. The gap is the copy.
# ════════════════════════════════════════════════════════════════════════════
@unittest.skipIf(NODE is None, "node not installed")
class MorningStateTest(unittest.TestCase):
    def test_with_programs_waiting_the_deck_says_to_pick_one_up(self):
        out = _harness({"act": "deck", "programs": [DISK_PROG],
                        "activeId": None})
        low = out["emptyText"].lower()
        self.assertIn("left", low, out["emptyText"])
        self.assertTrue("pick" in low or "click" in low, out["emptyText"])
        # it no longer opens with the words for a deck that has never been used.
        self.assertNotIn("describe a screen", low)

    def test_it_says_what_the_one_prominent_button_would_actually_do(self):
        out = _harness({"act": "deck", "programs": [DISK_PROG],
                        "activeId": None})
        low = out["emptyText"].lower()
        self.assertIn("new program", low)
        # the two outcomes he cannot see coming, in his words.
        self.assertIn("same name", low)
        self.assertTrue("different name" in low or "new name" in low, low)

    def test_a_deck_that_has_never_been_used_keeps_its_opening_words(self):
        """The control: the first-run empty state is D6's and is unchanged."""
        out = _harness({"act": "deck", "programs": [], "activeId": None})
        low = out["emptyText"].lower()
        self.assertIn("describe a screen", low)
        self.assertIn("program standing by", low)
        self.assertNotIn("on the left", low)

    def test_the_new_program_control_is_still_there_and_still_works(self):
        """The cure is copy. The control the captain reaches for on a deck with
        programs on it must not have moved or gone dead."""
        out = _harness({"act": "deck", "programs": [DISK_PROG],
                        "activeId": None})
        labels = [c["label"] for c in out["emptyControls"]]
        self.assertTrue(any("New Program" in l for l in labels), labels)
        for ctl in out["emptyControls"]:
            self.assertTrue(ctl["wired"] or (ctl["disabled"] and ctl["reason"]),
                            "dead control: %r" % ctl["label"])


@unittest.skipIf(NODE is None, "node not installed")
class RefusedTurnStillReportsTheTranscriptTest(unittest.TestCase):
    """FIX ROUND 2 — `refused` outranks every other status and the deck renders
    that branch alone, so a turn that was refused AND lost its transcript said
    nothing about the transcript. The daemon composes one account (it already
    appends rather than overwrites on the warning path); this proves the deck
    puts the whole of it on the screen."""

    REFUSAL = (
        "Your program is safe — everything in the holodeck sidecar is intact "
        "and the chat is still running. While that turn was running, 1 file(s) "
        "changed in your project, outside the holodeck: /Users/x/g/src/theme.css. "
        "LCARS watches the files, not who touched them. LCARS could not append "
        "this turn's exchange to transcript.md — the written record of the "
        "conversation is missing this turn.")

    def test_the_captain_learns_his_conversation_was_not_recorded(self):
        out = _harness({"act": "sayWarning", "programs": [PROG],
                        "activeId": "s1", "status": "refused",
                        "refused": {"message": self.REFUSAL,
                                    "paths": ["/Users/x/g/src/theme.css"]},
                        "warning": {"kind": "transcript-unwritten",
                                    "message": "unused — refused outranks it"}})
        self.assertEqual(out["bannerKind"], "refused")
        self.assertIn("transcript.md", out["text"])
        self.assertIn("/Users/x/g/src/theme.css", out["text"])
        # …once. One account, from one place.
        self.assertEqual(out["text"].count("transcript.md"), 1, out["text"])


# ════════════════════════════════════════════════════════════════════════════
# S127 — THE HAND-OFF ON THE DECK
#
# What this half can prove: which controls exist, whether each is WIRED or
# visibly off WITH a reason, what the dialog says, and — the one that matters —
# exactly what the browser PUTS ON THE WIRE. The last is the security claim of
# the whole round: the page sends a session id and never a path.
#
# What it cannot see (S163's lesson, said again rather than rediscovered): it
# calls the render functions itself and has no CSS, so a bar painted off-screen
# or a band the same colour as its background passes every line below.
# `tests/drives/browser/holodeck.sh` is the other half.
# ════════════════════════════════════════════════════════════════════════════
READY = dict(PROG, handoffReady=True, handoffBlocked="", conceptFile="concept.md")
NOT_READY = dict(PROG, handoffReady=False, conceptFile=None, handoffBlocked=(
    "There is no concept.md in this program's room yet, so there is nothing "
    "to hand over."))
SENT = dict(READY, status="sent", lifecycle="sent", missionId="m-014",
            handoffReady=False)

REQ1 = '**Turn 2:** "Cmd-K opens it, Escape closes it."'
REQ2 = '**Turn 5:** "It has to remember what I ran last time."'
Q1 = "What belongs in the command list?"
Q2 = "Should the palette be reachable from a mission card too?"
# S171 — THE SHAPE THE DAEMON NOW SENDS: his opening description of the
# program, verbatim and whole (its first line is the mission's title), then the
# derived sections. It is deliberately NOT the numbered quote list any more —
# a fixture that keeps the old shape tests a brief the product cannot produce.
BRIEF = ("A command palette for the board. Cmd-K opens it, Escape closes it, "
         "and it remembers what I ran last time.")

SEED = {
    "sessionId": "s1", "program": "Command palette", "room": "command-palette",
    "engine": "claude",
    "brief": BRIEF,
    # S171 — `summarySource` and `missingRequirements` are gone from the
    # payload with the drafting ladder and the literal-word check.
    "requirements": [{"id": "r1", "text": REQ1}, {"id": "r2", "text": REQ2}],
    "questions": [{"id": "q1", "text": Q1}, {"id": "q2", "text": Q2}],
    "scope": "look+behaviour", "scopeOptions": ["look+behaviour", "look-only"],
    "guidance": ("## How to read the attached mockup\n\n"
                 "- HOW MUCH TO BUILD: look AND behaviour.\n"
                 "- Where the mockup and the brief disagree, the brief "
                 "OVERRIDES the mockup.\n"
                 "- Matching it visually is an ACCEPTANCE CRITERION.\n"),
    "rides": [{"name": "mockup.html", "what": "the look and the flow"},
              {"name": "concept.md", "what": "decisions and declared flows"}],
}


@unittest.skipIf(NODE is None, "node not installed")
class HandoffDeckTest(unittest.TestCase):
    def test_a_ready_program_offers_SEND_TO_ALIGN_and_it_is_wired(self):
        out = _harness({"act": "handoffBar", "programs": [READY],
                        "activeId": "s1"})
        self.assertTrue(out["barPresent"])
        send = [c for c in out["barControls"]
                if "send to align" in c["label"].lower()]
        self.assertEqual(len(send), 1, out["barControls"])
        self.assertTrue(send[0]["wired"], send[0])
        self.assertFalse(send[0]["disabled"])

    def test_a_program_with_nothing_to_hand_over_is_OFF_WITH_THE_REASON(self):
        """Never a control that does nothing when you click it — and never a
        reason this side invented: the sentence is the daemon's."""
        out = _harness({"act": "handoffBar", "programs": [NOT_READY],
                        "activeId": "s1"})
        send = [c for c in out["barControls"]
                if "send to align" in c["label"].lower()][0]
        self.assertFalse(send["wired"])
        self.assertTrue(send["disabled"])
        self.assertEqual(send["reason"], NOT_READY["handoffBlocked"])
        self.assertIn("concept.md", out["barText"])

    def test_a_view_only_board_cannot_send(self):
        out = _harness({"act": "handoffBar", "programs": [READY],
                        "activeId": "s1", "writes": False})
        send = [c for c in out["barControls"]
                if "send to align" in c["label"].lower()][0]
        self.assertTrue(send["disabled"], send)

    def test_clicking_it_asks_the_daemon_BY_SESSION_ID_AND_SENDS_NO_PATH(self):
        out = _harness({"act": "sendClick", "programs": [READY],
                        "activeId": "s1"})
        self.assertTrue(out["found"])
        self.assertEqual(out["path"], "/api/holodeck/s1/promote")
        blob = json.dumps(out["body"] or {})
        for leak in ("/", "mockup.html", "concept.md", "holodeck"):
            self.assertNotIn(leak, blob, "%s leaked in %s" % (leak, blob))

    # -- the lock (D11) ------------------------------------------------------
    def test_a_SENT_program_has_a_lock_band_INSTEAD_of_a_composer(self):
        """Replaced, not greyed out: a disabled input invites 'why can't I type
        here?'; a band that says what happened answers it first."""
        out = _harness({"act": "handoffBar", "programs": [SENT],
                        "activeId": "s1"})
        self.assertFalse(out["hasComposer"])
        self.assertTrue(out["lockPresent"])
        self.assertIn("m-014", out["lockText"])
        self.assertIn("read-only", out["lockText"].lower())

    def test_a_sent_program_shows_no_send_control_at_all(self):
        out = _harness({"act": "handoffBar", "programs": [SENT],
                        "activeId": "s1"})
        self.assertEqual([c for c in out["barControls"]
                          if "send to align" in c["label"].lower()], [])
        self.assertIn("m-014", out["barText"])

    # ── FIX ROUND 3 · THE DEFECT THE CAPTAIN FOUND IN A MINUTE ──────────────
    # S172 built ⧉ Duplicate on the program CARD and reworded the daemon's
    # refusal to point at it — and left S127's placeholder standing HERE, in
    # the locked program's own chat pane, greyed out and saying the thing he
    # had just been told exists is "not built yet". Both S172 testers drove the
    # card; nobody opened a locked program and read the room he was standing
    # in. These tests are that room.
    def test_the_DUPLICATE_hatch_in_the_locked_pane_is_LIVE(self):
        """The escape hatch is BUILT now, so the control in the locked pane is
        a live control — not a placeholder apologising for itself."""
        out = _harness({"act": "handoffBar", "programs": [SENT],
                        "activeId": "s1"})
        dup = [c for c in out["lockControls"]
               if "duplicate" in c["label"].lower()]
        self.assertEqual(len(dup), 1, out["lockControls"])
        self.assertTrue(dup[0]["wired"], dup[0])
        self.assertFalse(dup[0]["disabled"], dup[0])
        self.assertNotIn("not built", (dup[0]["reason"] or "").lower())

    def test_the_locked_pane_names_DUPLICATION_as_the_way_on(self):
        """The paragraph above the control used to end at "this is read-only".
        A captain reading it needs the road out named in the same breath — the
        words the daemon's own refusal already uses."""
        out = _harness({"act": "handoffBar", "programs": [SENT],
                        "activeId": "s1"})
        low = out["lockText"].lower()
        # what it must NOT say any more: the two sentences that told him the
        # feature does not exist and to go start something else.
        self.assertNotIn("not built", low)
        self.assertNotIn("different name", low)
        # …and what it must say instead: what duplicating gives him.
        self.assertIn("duplicate", low)
        self.assertIn("conversation", low)
        self.assertIn("editable", low)

    def test_the_locked_panes_hatch_takes_THE_SAME_ROAD_as_the_card(self):
        """One mechanism, not two. Driven end to end off the LOCK BAND's own
        control: the same confirmation opens and the same POST comes out."""
        out = _harness({"act": "duplicateProgram", "programs": [SENT],
                        "activeId": "s1", "from": "lock"})
        self.assertTrue(out["lockPresent"])
        self.assertTrue(out["hasControl"])
        self.assertTrue(out["confirmText"])
        self.assertTrue(out["hasNameField"])
        self.assertEqual(out["path"], "/api/holodeck/duplicate")
        self.assertEqual(out["body"], {"room": "light-dark"})

    def test_a_read_only_daemon_still_disables_the_locked_panes_hatch(self):
        """Duplicating WRITES — a new room, committed to the sidecar. A
        view-only board must not offer it, from the pane any more than from
        the card."""
        out = _harness({"act": "handoffBar", "programs": [SENT],
                        "activeId": "s1", "writes": False})
        dup = [c for c in out["lockControls"]
               if "duplicate" in c["label"].lower()]
        self.assertEqual(len(dup), 1, out["lockControls"])
        self.assertTrue(dup[0]["disabled"], dup[0])

    def test_the_card_reads_sent_and_carries_its_mission(self):
        out = _harness({"act": "handoffBar", "programs": [SENT],
                        "activeId": "s1"})
        self.assertIn("sent", [s.lower() for s in out["statusChips"]])
        self.assertIn("▦ m-014", out["missionChips"])

    def test_a_draft_program_still_has_its_composer(self):
        """The control — without it, a deck that lost the composer entirely
        would pass the lock test."""
        out = _harness({"act": "handoffBar", "programs": [READY],
                        "activeId": "s1"})
        self.assertTrue(out["hasComposer"])
        self.assertFalse(out["lockPresent"])


@unittest.skipIf(NODE is None, "node not installed")
class HandoffGateTest(unittest.TestCase):
    """S171 — ▶ SEND TO ALIGN IS A GATE WITH A WAIT, driven by the daemon.

    The captain's design, after driving S170 on his own program: *"making that
    step a gated wait that retriggers behind a wait guard if you keep chatting
    with the composer."* S170 started the pass when the DIALOG opened, so a
    mid-design look cost him a pass and the wait lived inside a dialog.

    Every state below is `p.derive`, published by `_holodeck_meta`. NOTHING
    here is a client-side flag and nothing is a timer — that is FL-009 and
    FL-017 for the third time.

    What this half cannot see: whether any of it is on screen, or whether the
    disabled button is genuinely unclickable where it sits. That is
    `tests/drives/browser/handoff.sh`, in real Chrome, hit-tested.
    """

    NONE = dict(READY, derive={"state": "none"})
    RUNNING = dict(READY, derive={"state": "running", "startedAt": 1000.0,
                                  "now": 1042.0})
    DONE = dict(READY, derive={"state": "done", "ok": True,
                               "changes": ["today a → mock b",
                                           "today c → mock d"]})
    FAILED = dict(READY, derive={"state": "done", "ok": False, "changes": [],
                                 "why": "no worker engine is configured"})
    OFF = dict(READY, derive={"state": "off"})

    def _bar(self, prog):
        return _harness({"act": "handoffBar", "programs": [prog],
                         "activeId": "s1"})

    # -- state 1: nothing derived yet ---------------------------------------
    def test_with_NO_change_list_the_control_offers_to_GENERATE_one(self):
        out = self._bar(self.NONE)
        self.assertEqual(out["barGate"], "none")
        self.assertIn("generate", (out["sendLabel"] or "").lower())
        self.assertTrue(out["sendWired"])
        self.assertFalse(out["sendDisabled"])

    def test_clicking_GENERATE_posts_to_derive_and_NOT_to_promote(self):
        """The whole gate in one assertion: the pass is started by a CLICK on
        this control, so opening the hand-off dialog can no longer spend."""
        out = _harness({"act": "gateClick", "programs": [self.NONE],
                        "activeId": "s1"})
        self.assertTrue(out["found"])
        self.assertEqual(out["path"], "/api/holodeck/s1/derive")
        self.assertEqual(out["postCount"], 1)

    # -- state 2: a pass is in flight ---------------------------------------
    def test_while_it_RUNS_the_control_says_so_and_is_DISABLED(self):
        out = self._bar(self.RUNNING)
        self.assertEqual(out["barGate"], "running")
        self.assertIn("generating", (out["sendLabel"] or "").lower())
        self.assertTrue(out["sendDisabled"], out["sendLabel"])
        self.assertFalse(out["sendWired"])

    def test_the_running_state_carries_a_LOADING_INDICATOR(self):
        """"Generating…" with nothing moving beside it is a label, not a
        state. The bars are the same node the chat pane uses."""
        self.assertTrue(self._bar(self.RUNNING)["barSpinner"])
        self.assertFalse(self._bar(self.DONE)["barSpinner"])

    def test_the_disabled_control_CANNOT_fire_anything(self):
        """Not styled as though it cannot — actually cannot. A click on it
        must put nothing at all on the wire."""
        out = _harness({"act": "gateClick", "programs": [self.RUNNING],
                        "activeId": "s1"})
        self.assertTrue(out["found"])
        self.assertTrue(out["disabled"])
        self.assertEqual(out["postCount"], 0, out["path"])

    def test_the_running_hint_says_he_may_WALK_AWAY(self):
        """The daemon owns the pass and the room persists the answer, so this
        is a fact — and it is the reason the wait is acceptable at all."""
        low = self._bar(self.RUNNING)["barText"].lower()
        self.assertIn("reload", low)
        self.assertIn("restart", low)

    # -- state 3: it landed --------------------------------------------------
    def test_when_it_LANDS_the_control_becomes_SEND_TO_ALIGN(self):
        out = self._bar(self.DONE)
        self.assertEqual(out["barGate"], "ready")
        self.assertIn("send to align", (out["sendLabel"] or "").lower())
        self.assertTrue(out["sendWired"])
        self.assertFalse(out["sendDisabled"])
        self.assertIn("2 changes", out["barText"])

    def test_and_THAT_click_opens_the_hand_off_dialog(self):
        out = _harness({"act": "gateClick", "programs": [self.DONE],
                        "activeId": "s1"})
        self.assertEqual(out["path"], "/api/holodeck/s1/promote")

    # -- invalidation --------------------------------------------------------
    def test_a_further_composer_turn_returns_it_to_GENERATE(self):
        """INVALIDATION IS A FACT, NOT A FLAG. The daemon's fingerprint covers
        `mockup.html`, so a turn that redraws it stops matching the stored
        answer and the peek reports `none` — which this side renders. Nothing
        on the browser side has to notice a turn happened, and that is why the
        state cannot drift out of step with what was actually derived."""
        ready = self._bar(self.DONE)
        self.assertEqual(ready["barGate"], "ready")
        # …the very same program after a turn, as the daemon then reports it.
        after = self._bar(self.NONE)
        self.assertEqual(after["barGate"], "none")
        self.assertIn("generate", (after["sendLabel"] or "").lower())

    # -- THE ROAD THROUGH A DEAD ENGINE --------------------------------------
    def test_a_FAILED_pass_still_lets_him_SEND(self):
        """S170 built "filing is never blocked" and proved it with an `ast`
        test. Gating reverses that deliberately — so a pass that did not answer
        must never strand a ready program on the deck. The PRIMARY control is
        live here; the failure is reported beside it, in the daemon's words.

        S172 — AND THIS IS NOW THE WHOLE ARGUMENT, not half of it. The escape
        hatch is deleted, so if this control were ever disabled on a failed
        pass an engine outage really would strand a finished design."""
        out = self._bar(self.FAILED)
        self.assertEqual(out["barGate"], "failed")
        self.assertIn("send to align", (out["sendLabel"] or "").lower())
        self.assertTrue(out["sendWired"])
        self.assertFalse(out["sendDisabled"])
        self.assertIn("no worker engine is configured", out["barText"])

    def test_the_SEND_WITHOUT_hatch_IS_GONE_FROM_EVERY_STATE(self):
        """S172 — THE CLAIM IS INVERTED, BECAUSE THE PRODUCT IS.

        This test asserted the opposite: `Send without the change list` had to
        be present on `none`, `running` and `failed`. The captain has deleted
        it — *"we don't need the send without change list one."* It is not
        deleted from the test, because the test is what stops it coming back.
        """
        for prog, gate in ((self.NONE, "none"), (self.RUNNING, "running"),
                           (self.FAILED, "failed"), (self.DONE, "ready")):
            out = self._bar(prog)
            self.assertFalse(out["skipPresent"], gate)

    def test_the_PRIMARY_goes_straight_to_the_dialog_on_a_FAILED_pass(self):
        """What the hatch used to do, done by the control that is still there.
        It is the same `promote` the ready path reaches — one filing road, so
        there is nothing here that can rot while the main one is maintained."""
        out = _harness({"act": "gateClick", "programs": [self.FAILED],
                        "activeId": "s1", "which": "handoff-send"})
        self.assertTrue(out["found"])
        self.assertFalse(out["disabled"])
        self.assertEqual(out["path"], "/api/holodeck/s1/promote")

    def test_the_bar_TELLS_HIM_the_primary_is_the_road_through(self):
        """A live button he does not know to press is not a road. With the
        hatch gone the hint has to name it."""
        out = self._bar(self.FAILED)
        self.assertIn("▶ Send to Align still works", out["barText"])
        self.assertNotIn("without a change list", out["barText"])

    def test_a_failed_pass_can_be_RETRIED_and_the_retry_is_FORCED(self):
        """A failure is persisted like any other answer, so without this a
        captain whose engine was down for a minute would read "could not read
        your project" until he redrew the mockup. `force` is what clears it,
        and it is only ever reached by him asking."""
        out = _harness({"act": "gateClick", "programs": [self.FAILED],
                        "activeId": "s1", "which": "handoff-retry"})
        self.assertTrue(out["found"])
        self.assertEqual(out["path"], "/api/holodeck/s1/derive")
        self.assertEqual(out["body"], {"force": True})
        # …and it is offered NOWHERE else: a retry beside a good list is an
        # invitation to spend for nothing.
        for prog in (self.NONE, self.RUNNING, self.DONE):
            self.assertFalse(self._bar(prog)["retryPresent"])

    # -- switched off --------------------------------------------------------
    def test_with_the_derivation_OFF_the_gate_is_not_there_at_all(self):
        """Gating on a pass that will never run is a door with no handle."""
        out = self._bar(self.OFF)
        self.assertEqual(out["barGate"], "off")
        self.assertIn("send to align", (out["sendLabel"] or "").lower())
        self.assertTrue(out["sendWired"])

    def test_a_program_with_NOTHING_TO_HAND_OVER_is_still_off_with_a_reason(
            self):
        """The S127 rule outranks the gate: no mockup, no hand-off, and the
        sentence is the daemon's."""
        out = self._bar(dict(NOT_READY, derive={"state": "none"}))
        send = [c for c in out["barControls"]
                if "send to align" in c["label"].lower()][0]
        self.assertTrue(send["disabled"])
        self.assertEqual(send["reason"], NOT_READY["handoffBlocked"])
        self.assertFalse(out["skipPresent"])

    def test_no_dead_controls_in_ANY_gate_state(self):
        for prog in (self.NONE, self.RUNNING, self.DONE, self.FAILED,
                     self.OFF):
            for ctl in self._bar(prog)["barControls"]:
                self.assertTrue(
                    ctl["wired"] or ctl["disabled"] or ctl["reason"],
                    "dead control: %r" % ctl["label"])


@unittest.skipIf(NODE is None, "node not installed")
class HandoffDialogTest(unittest.TestCase):
    def test_it_opens_PRE_SEEDED_so_the_next_action_is_one_click(self):
        out = _harness({"act": "handoffDialog", "seed": SEED,
                        "stopBeforeFile": True})
        self.assertEqual(out["briefValue"], SEED["brief"])
        self.assertTrue(out["fileFound"])
        self.assertEqual(out["rides"], ["mockup.html", "concept.md"])

    def test_the_guidance_is_shown_VERBATIM_before_he_sends(self):
        """S128: the pinned sentence changed with `_HANDOFF_PRECEDENCE` (A4a).
        The old one — "…the brief wins." — is the wording a cold worker read as
        "the brief is exhaustive" while discarding the captain's theme."""
        out = _harness({"act": "handoffDialog", "seed": SEED,
                        "stopBeforeFile": True})
        self.assertEqual(out["guidance"], SEED["guidance"])
        self.assertIn("the brief OVERRIDES the mockup", out["guidance"])

    def test_the_build_scope_is_a_choice_defaulting_to_look_plus_behaviour(self):
        out = _harness({"act": "handoffDialog", "seed": SEED,
                        "stopBeforeFile": True})
        self.assertEqual(out["choiceIds"], ["look+behaviour", "look-only"])
        self.assertEqual(out["selected"], "look+behaviour")

    def test_FILE_MISSION_sends_the_brief_the_scope_and_the_SESSION_ID(self):
        out = _harness({"act": "handoffDialog", "seed": SEED,
                        "rewrite": "My own words about the palette."})
        self.assertEqual(out["filePath"], "/api/park")
        self.assertEqual(out["fileBody"]["idea"],
                         "My own words about the palette.")
        self.assertEqual(out["fileBody"]["holodeck"], "s1")
        self.assertEqual(out["fileBody"]["holodeckScope"], "look+behaviour")

    def test_the_file_body_carries_NO_PATH(self):
        out = _harness({"act": "handoffDialog", "seed": SEED})
        blob = json.dumps(out["fileBody"])
        for leak in ("mockup.html", "concept.md", "/tmp", "holodeck-"):
            self.assertNotIn(leak, blob, blob)

    def test_picking_look_only_re_asks_the_DAEMON_for_the_guidance(self):
        """The block is never rewritten on this side: what he reads and what
        the Mission is given have to be the same words."""
        out = _harness({"act": "handoffDialog", "seed": SEED,
                        "pickScope": "look-only", "stopBeforeFile": True})
        self.assertEqual(out["selectedAfter"], "look-only")
        self.assertEqual(out["guidanceRefetch"]["path"],
                         "/api/holodeck/s1/promote")
        self.assertEqual(out["guidanceRefetch"]["body"]["scope"], "look-only")

    def test_the_chosen_scope_reaches_the_filing(self):
        out = _harness({"act": "handoffDialog", "seed": SEED,
                        "pickScope": "look-only"})
        self.assertEqual(out["fileBody"]["holodeckScope"], "look-only")

    def test_an_empty_brief_is_refused_without_filing(self):
        out = _harness({"act": "handoffDialog", "seed": dict(SEED, brief=""),
                        "rewrite": "   "})
        self.assertIsNone(out["filePath"], out)
        self.assertIn("brief", out["text"].lower())


# ════════════════════════════════════════════════════════════════════════════
# S128 (FL-011) — THE INTENT HAND-OVER, ON THE DECK
#
# The daemon half is in `test_holodeck_endpoints.py`. This half is the last
# screen the captain sees before a design becomes a mission: it has to put the
# open questions in front of him, and it has to make a dropped requirement
# impossible to walk past.
#
# WHAT IT CANNOT SEE (the S163 lesson, said again): there is no CSS in this
# process. Every claim below is about which nodes exist and what they say. A
# warning band rendered in muted grey below the fold, or one that loses a
# specificity tie to `.hint`, passes all of it — that is `tests/drives/browser/`
# and the captain's own eyes. "Un-missable" is asserted here as CONTENT and
# POSITION only.
# ════════════════════════════════════════════════════════════════════════════
@unittest.skipIf(NODE is None, "node not installed")
class HandoffOpenQuestionsDeckTest(unittest.TestCase):
    """A2 — the five questions that died at the S127 hand-off."""

    def test_every_open_question_is_shown_before_he_files(self):
        out = _harness({"act": "handoffDialog", "seed": SEED,
                        "stopBeforeFile": True})
        self.assertIn(Q1, out["text"])
        self.assertIn(Q2, out["text"])

    def test_each_question_gets_a_box_he_can_answer_it_in(self):
        """Answering five questions costs less than one wrong build — but only
        if he can answer them WITHOUT leaving the dialog."""
        out = _harness({"act": "handoffDialog", "seed": SEED,
                        "stopBeforeFile": True})
        self.assertEqual([q["qid"] for q in out["questions"]], ["q1", "q2"])

    def test_the_questions_are_the_LAST_thing_before_the_file_button(self):
        """Position is the whole design: they are what he reads with his hand
        on the button, not a panel he scrolled past on the way in."""
        out = _harness({"act": "handoffDialog", "seed": SEED,
                        "stopBeforeFile": True})
        self.assertEqual(out["lastFieldHolo"], "handoff-questions")

    def test_his_answers_ride_with_the_filing_KEYED_BY_THE_DAEMONS_ID(self):
        out = _harness({"act": "handoffDialog", "seed": SEED,
                        "answers": {"q1": "Only board verbs."}})
        self.assertEqual(out["fileBody"]["holodeckAnswers"],
                         {"q1": "Only board verbs."})

    def test_an_unanswered_question_sends_no_answer_for_itself(self):
        """Silence must stay silence all the way down. An empty string filed as
        an "answer" is exactly the settled-by-nobody decision being cured."""
        out = _harness({"act": "handoffDialog", "seed": SEED,
                        "answers": {"q1": "   "}})
        self.assertEqual(out["fileBody"].get("holodeckAnswers", {}), {})

    def test_the_dialog_SAYS_what_happens_to_one_he_leaves_blank(self):
        out = _harness({"act": "handoffDialog", "seed": SEED,
                        "stopBeforeFile": True})
        low = out["questionsText"].lower()
        self.assertIn("open", low)
        self.assertTrue("blank" in low or "unanswered" in low, low)
        # …and that it is NOT taken as agreement.
        self.assertTrue("decision" in low or "settled" in low
                        or "assume" in low, low)

    def test_a_program_with_no_open_questions_shows_no_empty_panel(self):
        out = _harness({"act": "handoffDialog",
                        "seed": dict(SEED, questions=[]),
                        "stopBeforeFile": True})
        self.assertEqual(out["questions"], [])
        self.assertEqual(out["questionsText"], "")

    def test_a_filing_with_no_answers_at_all_sends_no_answers_key(self):
        out = _harness({"act": "handoffDialog", "seed": SEED})
        self.assertEqual(out["fileBody"].get("holodeckAnswers", {}), {})


@unittest.skipIf(NODE is None, "node not installed")
class HandoffQuestionsReachHimTest(unittest.TestCase):
    """S128 FIX ROUND 1, D1 — the questions were LAST in the DOM and never on
    screen. Measured in real Chrome: the modal body is 1812px tall, the visible
    window is 443–677px depending on viewport, the questions block starts
    546–780px BELOW the fold, and ▦ File Mission is laid out and clickable in
    the sticky footer from first paint. The tester clicked it at scrollTop 0 and
    filed. Nothing on screen said the questions existed.

    The cure is a CUE IN THE STICKY FOOTER — the one region that is on screen at
    every scroll position and every viewport — beside the button he is about to
    press, and it is a control that takes him to them. Filing is still allowed
    (a hard block at the last click of a design session is the wrong shape, and
    the daemon already carries an unanswered question in marked STILL OPEN).
    What is no longer possible is filing without KNOWING.

    WHAT THIS CANNOT SEE: there is no CSS here and nothing is laid out. That the
    footer is sticky, that the cue is legible, and that it is on screen at
    900x640 is measured only by the browser rig."""

    def test_the_open_questions_are_COUNTED_IN_THE_STICKY_FOOTER(self):
        out = _harness({"act": "handoffDialog", "seed": SEED,
                        "stopBeforeFile": True})
        self.assertIsNotNone(out["qcue"], out["footText"])
        self.assertTrue(out["qcue"]["inFoot"], out["qcue"])
        self.assertIn("2", out["qcue"]["text"])
        self.assertIn("open question", out["qcue"]["text"].lower())

    def test_the_cue_is_a_CONTROL_that_takes_him_to_them(self):
        """A count he cannot act on is a count he scrolls past. It has to be the
        way there, not a label about a place he still has to find."""
        out = _harness({"act": "handoffDialog", "seed": SEED,
                        "clickCue": True, "stopBeforeFile": True})
        self.assertTrue(out["qcue"]["wired"], out["qcue"])
        self.assertTrue(out["cueFound"])
        holos = [s["holo"] for s in out["cueScrolled"]]
        self.assertIn("handoff-questions", holos, out["cueScrolled"])
        # …and it lands him IN the first one he has not answered.
        self.assertEqual([f["qid"] for f in out["cueFocused"]], ["q1"],
                         out["cueFocused"])

    def test_an_UNANSWERED_question_makes_the_cue_a_warning(self):
        out = _harness({"act": "handoffDialog", "seed": SEED,
                        "stopBeforeFile": True})
        self.assertEqual(out["qcue"]["open"], "2", out["qcue"])
        self.assertIn("open", out["qcue"]["cls"], out["qcue"])

    def test_the_count_FALLS_as_he_answers_them(self):
        """The control on the warning: a band that never changes is a band he
        stops reading. It has to still mean something on the day it fires."""
        out = _harness({"act": "handoffDialog", "seed": SEED,
                        "answers": {"q1": "Only board verbs."},
                        "stopBeforeFile": True})
        self.assertEqual(out["qcue"]["open"], "1", out["qcue"])
        self.assertIn("1", out["qcue"]["text"])

    def test_answering_ALL_of_them_clears_the_warning_entirely(self):
        out = _harness({"act": "handoffDialog", "seed": SEED,
                        "answers": {"q1": "Only board verbs.", "q2": "Yes."},
                        "stopBeforeFile": True})
        self.assertEqual(out["qcue"]["open"], "0", out["qcue"])
        self.assertNotIn("open", out["qcue"]["cls"], out["qcue"])

    def test_a_program_with_no_open_questions_gets_NO_cue(self):
        out = _harness({"act": "handoffDialog",
                        "seed": dict(SEED, questions=[]),
                        "stopBeforeFile": True})
        self.assertIsNone(out["qcue"], out["footText"])

    def test_the_cue_does_NOT_block_the_filing(self):
        """The daemon carries an unanswered question in marked STILL OPEN. A
        hard stop here would strand him at the last click of a design session,
        which is exactly the shape the round rejected for the requirements."""
        out = _harness({"act": "handoffDialog", "seed": SEED})
        self.assertEqual(out["filePath"], "/api/park")

    def test_the_questions_are_STILL_the_last_field_before_the_button(self):
        """The cue is an addition, not a move: the questions stay the thing he
        reads with his hand on the button."""
        out = _harness({"act": "handoffDialog", "seed": SEED,
                        "stopBeforeFile": True})
        self.assertEqual(out["lastFieldHolo"], "handoff-questions")


@unittest.skipIf(NODE is None, "node not installed")
class FailedFilingIsVisibleTest(unittest.TestCase):
    """S128 FIX ROUND 1, D2 — a filing that FAILED reported nothing. Measured:
    the POST returned 502, `.errline` was populated and `hidden:false` at
    y=1879 — 1,115px below the bottom of the visible modal body — and a sweep of
    every .errline/.verdict/.banner intersecting the viewport returned []. The
    button reverted from "Filing…" to "▦ File Mission" and that was all.

    Two cures. The dialog-local one: the error line lives in the STICKY FOOTER,
    with the button that failed, so it cannot be scrolled away from. The shared
    one: `showErr` — which every modal in board.js uses — asks the browser to
    bring the line into view, so the class is cured for the eight other dialogs
    that append their errline into the scrolling `.modal-body`."""

    def test_the_error_line_lives_in_the_STICKY_FOOTER_with_the_button(self):
        out = _harness({"act": "handoffDialog", "seed": SEED,
                        "stopBeforeFile": True})
        self.assertIn("modal-foot", out["errParentCls"] or "",
                      "errline is in %r — the scrolling body" % out["errParentCls"])

    def test_showErr_BRINGS_THE_LINE_INTO_VIEW(self):
        """The shared half. Driven here through the refusal path (the fetch stub
        cannot replay a 502), but the function is board.js's ONE error-surfacing
        call — curing it cures every dialog that has an errline."""
        out = _harness({"act": "handoffDialog", "seed": dict(SEED, brief=""),
                        "rewrite": "   "})
        self.assertTrue(out["errShown"], out)
        self.assertTrue(out["errScrolled"],
                        "showErr made the line visible without bringing it "
                        "into view — exactly the 502 the tester could not see")


@unittest.skipIf(NODE is None, "node not installed")
class HandoffNoRequirementChecklistTest(unittest.TestCase):
    """S171 — A3's ✓/⚠ CHECKLIST IS GONE, AND SO IS ITS BAND.

    What was here: seven tests over a panel that listed every captured
    requirement beside the brief, marked each ✓ or ⚠ by containment on the
    captain's literal words, and warned in amber when one was not in the box.
    It was built for FL-011 and it worked.

    It is deleted because the thing it measured left. His words are no longer
    QUOTED IN THE BRIEF (the numbered "in your own words" list went with the
    same feedback), so every row would read ⚠ on every hand-off — a panel of
    warnings that are all false, beside ▦ FILE MISSION. The captain named both
    surfaces in one sentence, and the reasoning plus the accepted risk is
    written out in actions.py where `_handoff_missing` used to be.

    What stays proven below: no dead controls anywhere in the dialog. And what
    replaces the guarantee is structural, not another check — `concept.md`
    rides to the Mission with `## WHAT IT MUST DO` complete and attributed,
    which `HandoffRidesTest` and the endpoint suite pin.
    """

    def test_the_dialog_no_longer_shows_a_requirement_CHECKLIST(self):
        out = _harness({"act": "handoffDialog", "seed": SEED,
                        "stopBeforeFile": True})
        self.assertEqual(out["reqRows"], [], out["reqRows"])
        self.assertEqual(out["missingText"], "")

    def test_a_brief_he_rewrites_to_ONE_LINE_raises_no_warning_at_all(self):
        """The exact input the old panel went amber on — and the reason it had
        to go: this is now what EVERY hand-off looks like."""
        out = _harness({"act": "handoffDialog", "seed": SEED,
                        "rewrite": "Cmd-K opens it, Escape closes it.",
                        "stopBeforeFile": True})
        self.assertEqual(out["missingText"], "")
        self.assertTrue(out["missingHidden"], out)

    def test_it_still_does_NOT_block_the_filing(self):
        out = _harness({"act": "handoffDialog", "seed": SEED,
                        "rewrite": "Cmd-K opens it, Escape closes it."})
        self.assertEqual(out["filePath"], "/api/park")

    def test_no_dead_controls_anywhere_in_the_hand_off_dialog(self):
        out = _harness({"act": "handoffDialog", "seed": SEED,
                        "stopBeforeFile": True})
        for ctl in out["controls"]:
            self.assertTrue(ctl["wired"] or ctl["disabled"] or ctl["reason"],
                            "dead control: %r" % ctl["label"])


@unittest.skipIf(NODE is None, "node not installed")
class BoardUntouchedTest(unittest.TestCase):
    def test_the_board_renders_normally_while_the_deck_exists(self):
        """The deck is additive: with the holodeck never opened, render() paints
        the same columns and cards it always did."""
        out = _harness({"act": "boardRender"})
        self.assertEqual(out["columnCount"], 9)
        self.assertEqual(out["cardCount"], 1)
        self.assertFalse(out["deckVisible"])


# ════════════════════════════════════════════════════════════════════════════
# S127 FIELD LEDGER — FL-003 / FL-006 / FL-007, all three in the PREVIEW PANE
# ════════════════════════════════════════════════════════════════════════════
GROUNDED_EMPTY = dict(PROG, previewFile=None, grounded=True,
                      basisFile="basis.md")


@unittest.skipIf(NODE is None, "node not installed")
class GroundedEmptyPreviewTest(unittest.TestCase):
    """FL-003 — a successful grounding pass must not read as "nothing happened".

    The captain ran a pass that SUCCEEDED (8.5kB of source-cited `basis.md`,
    committed) and landed on the same two sentences a blank-deck program shows:
    "Nothing on the holodeck yet / Ask for a screen and it will appear here."
    His words were "I don't understand." A grounding pass builds no mockup —
    that is correct — so the empty state is where the deck has to SAY so.
    """

    def test_a_grounded_program_with_no_mockup_names_the_pass(self):
        out = _harness({"act": "deck", "programs": [GROUNDED_EMPTY],
                        "activeId": "s1"})
        low = out["previewText"].lower()
        self.assertIn("ground", low, out["previewText"])
        # …and it is NOT the blank-deck sentence any more.
        self.assertNotIn("nothing on the holodeck yet", low)

    def test_the_grounded_empty_state_says_why_the_stage_is_empty(self):
        """The one fact that turns "nothing happened" into "step one of two":
        a grounding pass reads, it does not draw."""
        out = _harness({"act": "deck", "programs": [GROUNDED_EMPTY],
                        "activeId": "s1"})
        low = out["previewText"].lower()
        self.assertTrue("no mockup" in low or "builds no" in low
                        or "does not build" in low, out["previewText"])

    def test_the_grounded_empty_state_says_the_next_move(self):
        out = _harness({"act": "deck", "programs": [GROUNDED_EMPTY],
                        "activeId": "s1"})
        low = out["previewText"].lower()
        self.assertIn("describe", low, out["previewText"])

    def test_basis_md_is_reachable_from_the_pane_he_is_looking_at(self):
        """The chip that already links `basis.md` sits in the CHAT pane head and
        the captain did not find it. The link has to be in the empty preview."""
        out = _harness({"act": "deck", "programs": [GROUNDED_EMPTY],
                        "activeId": "s1"})
        self.assertEqual(out["previewBasisTag"], "a")
        self.assertEqual(out["previewBasisHref"],
                         "/api/holodeck/s1/preview/basis.md")

    def test_the_two_basis_controls_are_ONE_mechanism(self):
        """The S125 trap this cure had to dodge: a second link beside the chip,
        with its own URL and its own wording, is two mechanisms for one file.
        Both are built by one function, so they can never disagree about where
        the file is."""
        out = _harness({"act": "deck", "programs": [GROUNDED_EMPTY],
                        "activeId": "s1"})
        self.assertEqual(out["groundChipHref"], out["previewBasisHref"])

    def test_a_grounded_program_with_no_basis_yet_offers_no_dead_link(self):
        """Same rule the chip already keeps: `basisFile` is the daemon saying
        the file is really there. Without it the empty state must still name the
        pass and say why there is nothing to read."""
        out = _harness({"act": "deck",
                        "programs": [dict(GROUNDED_EMPTY, basisFile=None)],
                        "activeId": "s1"})
        self.assertIn("ground", out["previewText"].lower())
        self.assertNotEqual(out["previewBasisTag"], "a")
        self.assertTrue(out["previewBasisReason"], out)

    def test_an_ungrounded_program_keeps_the_blank_deck_wording(self):
        """The generic empty state is CORRECT for a blank-deck program, and the
        branch must not swallow it."""
        out = _harness({"act": "deck",
                        "programs": [dict(PROG, previewFile=None, mode="design",
                                          grounded=False, basisFile=None)],
                        "activeId": "s1"})
        self.assertIn("NOTHING ON THE HOLODECK YET", out["previewText"].upper())
        self.assertIsNone(out["previewBasisTag"])

    def test_a_grounded_program_WITH_a_mockup_shows_the_mockup(self):
        """The branch is on the EMPTY state only — a grounded program that has
        since drawn something still gets its iframe."""
        out = _harness({"act": "deck",
                        "programs": [dict(PROG, grounded=True,
                                          basisFile="basis.md")],
                        "activeId": "s1"})
        self.assertTrue(out["iframeSrc"].startswith(
            "/api/holodeck/s1/preview/mockup.html"))
        # and `basis.md` is still reachable — from the chip, which is why the
        # chip could not simply be retired in favour of the empty state.
        self.assertEqual(out["groundChipHref"],
                         "/api/holodeck/s1/preview/basis.md")

    def test_no_dead_controls_in_the_grounded_empty_preview(self):
        out = _harness({"act": "deck", "programs": [GROUNDED_EMPTY],
                        "activeId": "s1"})
        for ctl in out["previewControls"]:
            self.assertTrue(ctl["wired"] or ctl["disabled"] or ctl["reason"],
                            "dead control: %r" % ctl["label"])


@unittest.skipIf(NODE is None, "node not installed")
class IntentIsARealToggleTest(unittest.TestCase):
    """FL-007 — INTENT is drawn as half of a segmented control and behaved as a
    link into a browser tab of raw markdown. D14 specifies the toggle: the
    preview pane swaps between the mockup and the captured intent.
    """

    CONCEPT = dict(PROG, conceptFile="concept.md")

    def test_the_intent_pill_no_longer_opens_a_browser_tab(self):
        out = _harness({"act": "deck", "programs": [self.CONCEPT],
                        "activeId": "s1"})
        self.assertIsNone(out["intentTarget"])
        self.assertIsNone(out["intentHref"])
        self.assertTrue(out["intentWired"])

    def test_both_halves_of_the_segmented_control_carry_their_state(self):
        out = _harness({"act": "deck", "programs": [self.CONCEPT],
                        "activeId": "s1"})
        # two buttons, PREVIEW is the one you are looking at.
        self.assertEqual(out["pvToggleOn"], [True, False])
        self.assertEqual(out["pvTogglePressed"], ["true", "false"])

    def test_clicking_intent_renders_concept_md_in_the_pane(self):
        out = _harness({"act": "intentToggle", "programs": [self.CONCEPT],
                        "activeId": "s1"})
        self.assertTrue(out["intentWired"], out)
        # the bytes come over the SAME jailed preview route the link used.
        self.assertIn("/api/holodeck/s1/preview/concept.md", out["fetched"])
        st = out["afterIntent"]
        self.assertTrue(st["intentPresent"])
        self.assertFalse(st["intentHidden"])
        self.assertTrue(st["mockHidden"], "the mockup must step aside")
        self.assertEqual(st["on"], [False, True])
        self.assertEqual(st["pressed"], ["false", "true"])

    def test_the_concept_doc_is_RENDERED_not_dumped_as_source(self):
        """Reusing the board's own markdown renderer, not a second one: a
        heading arrives as a heading and a numbered requirement as a list item.
        """
        out = _harness({"act": "intentToggle", "programs": [self.CONCEPT],
                        "activeId": "s1",
                        "concept": "## What it must do\n\n"
                                   "1. It remembers what you picked.\n"})
        html = out["afterIntent"]["intentHtml"] or ""
        self.assertIn("<h4>", html, html)
        self.assertIn("<li>It remembers what you picked.</li>", html, html)
        self.assertNotIn("## What it must do", html)

    def test_switching_back_leaves_the_mockup_exactly_where_it_was(self):
        """The whole reason the two views live side by side in one stage: a
        re-render would destroy the iframe and reload a mockup that never
        changed."""
        out = _harness({"act": "intentToggle", "programs": [self.CONCEPT],
                        "activeId": "s1", "back": True})
        self.assertEqual(out["afterBack"]["iframeSrc"], out["iframeSrcAtStart"])
        self.assertEqual(out["nonceAtEnd"], out["nonceAtStart"])
        self.assertFalse(out["afterBack"]["mockHidden"])
        self.assertTrue(out["afterBack"]["intentHidden"])
        self.assertEqual(out["afterBack"]["on"], [True, False])

    def test_flipping_back_to_intent_does_not_refetch_the_same_bytes(self):
        out = _harness({"act": "intentToggle", "programs": [self.CONCEPT],
                        "activeId": "s1", "back": True})
        self.assertEqual(out["fetchedOnBack"], [])
        self.assertEqual(out["fetchedOnSecondIntent"], [])
        self.assertTrue(out["afterSecondIntent"]["intentPresent"])
        self.assertFalse(out["afterSecondIntent"]["intentHidden"])
        # …and the document is still on screen, not an empty panel.
        self.assertIn("<li>", out["afterSecondIntent"]["intentHtml"] or "")

    def test_a_re_render_while_intent_is_up_keeps_intent_up(self):
        """A turn lands and `renderDeck` rebuilds the pane. A toggle whose only
        memory is the DOM silently flips back to the mockup underneath him."""
        out = _harness({"act": "intentToggle", "programs": [self.CONCEPT],
                        "activeId": "s1", "rerender": True})
        st = out["afterRerender"]
        self.assertFalse(st["intentHidden"], st)
        self.assertTrue(st["mockHidden"], st)
        self.assertEqual(st["on"], [False, True])

    def test_a_turn_that_rewrote_concept_md_drops_the_stale_bytes(self):
        """Same discipline as the mockup (D3): the panel refreshes because the
        FILE changed, never because a reply said it had."""
        out = _harness({"act": "intentToggle", "programs": [self.CONCEPT],
                        "activeId": "s1", "rerender": True,
                        "filesChangedAfter": [{"path": "light-dark/concept.md",
                                               "status": "modified"}]})
        self.assertIn("/api/holodeck/s1/preview/concept.md",
                      out["fetchedAfterChange"])

    def test_a_program_with_no_concept_doc_keeps_the_visibly_off_state(self):
        """FIX ROUND 2's cure, preserved. `conceptFile` is withheld for an EMPTY
        concept.md as well as a missing one, and the sentence a captain reads
        must not tell him a file he can see is not there."""
        out = _harness({"act": "deck",
                        "programs": [dict(PROG, conceptFile=None)],
                        "activeId": "s1"})
        self.assertEqual(out["intentTag"], "span")
        self.assertFalse(out["intentWired"])
        low = out["intentReason"].lower()
        self.assertIn("concept.md", low)
        self.assertNotIn("has no concept.md", low)
        self.assertNotIn("does not exist", low)
        self.assertNotIn("not writing concept.md", low)

    def test_the_intent_panel_does_not_exist_without_a_concept_doc(self):
        out = _harness({"act": "intentToggle",
                        "programs": [dict(PROG, conceptFile=None)],
                        "activeId": "s1"})
        self.assertFalse(out["afterIntent"]["intentPresent"])
        self.assertFalse(out["afterIntent"]["mockHidden"])

    def test_a_concept_doc_that_cannot_be_read_says_so(self):
        out = _harness({"act": "intentToggle", "programs": [self.CONCEPT],
                        "activeId": "s1", "fetchFails": True})
        low = out["afterIntent"]["intentText"].lower()
        self.assertIn("concept.md", low)
        self.assertTrue("could not" in low or "cannot" in low, low)

    def test_the_iframe_sandbox_is_untouched_by_the_toggle(self):
        """The load-bearing security property of this pane. `allow-scripts`
        WITHOUT `allow-same-origin` — the toggle moved the iframe into a
        sibling of the intent panel and must not have loosened it."""
        out = _harness({"act": "deck", "programs": [self.CONCEPT],
                        "activeId": "s1"})
        self.assertIn("allow-scripts", out["iframeSandbox"])
        self.assertNotIn("allow-same-origin", out["iframeSandbox"])


@unittest.skipIf(NODE is None, "node not installed")
class ChatPreviewSplitTest(unittest.TestCase):
    """S128 — D2 AMENDED 2026-08-05 (captain, S127 live drive): the chat ⇄
    preview boundary is a PERSISTED DRAG HANDLE.

        "I need some way to resize the chat window to give the mock render more
         room. This becomes more important if I make the window full screen.
         Then the chat takes up a comical amount of room."

    `1.15fr : 1fr` grew the chat WITHOUT BOUND — on a 2560px display ~1250px of
    chat against a ~70-character readable line, every pixel past that spent on
    the one pane that cannot use it while the preview, which D2 itself calls
    "the point", starved.

    WHAT THESE TESTS CANNOT PROVE, said here rather than discovered later: this
    process has NO CSS and lays nothing out. Every assertion below reads a
    number board.js computed or an attribute it wrote. None of them can tell you
    a pane got wider, that the handle is visible or grabbable, or that a real
    pointer drag moves anything. Only headless Chrome, MEASURING the two panes'
    widths before and after, can say that.
    """

    def test_the_handle_sits_between_chat_and_preview_and_nowhere_else(self):
        out = _harness({"act": "split", "programs": [PROG], "activeId": "s1"})
        self.assertTrue(out["present"], "no chat ⇄ preview handle on the deck")
        # The 216px program list is EXPLICITLY not part of this split (D2
        # amendment, last line) — so there is exactly one handle, and it is
        # between the chat and the preview.
        self.assertEqual(out["paneOrder"],
                         ["programs", "holo-chat", "deck-split", "preview",
                          "holo-scrim"])

    def test_a_solo_deck_has_no_handle_because_there_is_nothing_to_split(self):
        out = _harness({"act": "split", "programs": [], "activeId": None})
        self.assertFalse(out["present"])
        self.assertNotIn("deck-split", out["paneOrder"])

    def test_the_default_split_favours_the_preview(self):
        """The one thing inside the ruling that is NOT the handle: the handle
        needs a starting position, and `1.15 : 1` (chat 53.5%) is a poor one at
        large widths. A preview-favouring default is permitted and wanted; a
        CAP on the chat's growth is not, and is asserted absent below."""
        out = _harness({"act": "split", "programs": [PROG], "activeId": "s1"})
        chat = float(out["initial"]["chatFr"].replace("fr", ""))
        pv = float(out["initial"]["pvFr"].replace("fr", ""))
        self.assertLess(chat, pv,
                        "the default split gives the chat %r against the "
                        "preview's %r — the preview is the point" % (chat, pv))
        self.assertAlmostEqual(chat + pv, 1.0, places=3)
        # nothing is persisted until the captain moves it: a default is not a
        # choice, and writing one would make a later change of default invisible
        # to every deck that had ever been opened.
        self.assertIsNone(out["initial"]["stored"])

    def test_a_stored_split_survives_the_reload(self):
        """The whole reason D2's original reasoning did not survive: 'a decision
        the captain has to make every session' is answered by persisting it."""
        out = _harness({"act": "split", "programs": [PROG], "activeId": "s1",
                        "storage": {"lcars-holo-split": "0.66"}})
        self.assertEqual(out["initial"]["chatFr"][:4], "0.66")
        self.assertEqual(out["initial"]["valueNow"], "66")

    def test_a_corrupt_stored_split_falls_back_instead_of_breaking_the_deck(self):
        for junk in ("", "banana", "NaN", "-3"):
            out = _harness({"act": "split", "programs": [PROG], "activeId": "s1",
                            "storage": {"lcars-holo-split": junk}})
            chat = float(out["initial"]["chatFr"].replace("fr", ""))
            self.assertTrue(0.0 < chat < 1.0,
                            "%r in storage produced %r" % (junk, chat))

    def test_neither_pane_can_be_dragged_to_nothing(self):
        """…and therefore the handle is reachable again after ANY drag: it is a
        grid COLUMN between two panes that both keep a floor, not an overlay
        that can be pushed off the edge."""
        low = _harness({"act": "split", "programs": [PROG], "activeId": "s1",
                        "setTo": 0.001})
        high = _harness({"act": "split", "programs": [PROG], "activeId": "s1",
                         "setTo": 0.999})
        lo = float(low["afterSet"]["chatFr"].replace("fr", ""))
        hi = float(high["afterSet"]["chatFr"].replace("fr", ""))
        self.assertGreater(lo, 0.05, "the chat can be dragged to nothing")
        self.assertLess(hi, 0.95, "the preview can be dragged to nothing")

    def test_a_drag_clamps_the_same_way_the_setter_does(self):
        """The pointermove handler's ARITHMETIC, through the pure function it
        calls. `holoSplitFromDrag(startChatPx, dx, total)`.

        FIX ROUND 1 rewrote the expectations here in PIXELS. A 1200px span with
        a 360px preview floor cannot legally go past 0.70 — the old `0.75`
        assertion was the dead band, written down as if it were correct."""
        span = 1200
        out = _harness({"act": "split", "programs": [PROG], "activeId": "s1",
                        "drags": [[600, 0, span], [600, 300, span],
                                  [600, -2000, span], [600, 2000, span]]})
        self.assertAlmostEqual(out["drags"][0]["frac"], 0.5, places=3)
        for d in out["drags"]:
            chat_px = d["frac"] * span
            self.assertGreaterEqual(round(chat_px, 3), 340)
            self.assertGreaterEqual(round(span - chat_px, 3), 360)
        # an unreachable drag lands ON the bound, not short of it — the handle
        # goes as far as the floors allow and no further.
        self.assertAlmostEqual(out["drags"][2]["frac"] * span, 341, places=3)
        self.assertAlmostEqual(span - out["drags"][3]["frac"] * span, 361,
                               places=3)
        # …and a 300px pull that is legal is honoured in full.
        self.assertAlmostEqual(out["drags"][1]["frac"] * span, 839, places=3)

    def test_a_drag_toward_the_preview_leaves_no_dead_band(self):
        """FIX ROUND 1 — the defect the node harness could not see, MEASURED in
        headless Chrome against the first cut.

        `minmax(340px, 0.25fr)`: when the fr max resolves BELOW the px min
        (0.25fr of 1293 = 323 < 340) the chat track correctly clamps to 340 —
        but grid resolves the preview's 0.75fr against the ORIGINAL free space,
        not the space the clamp released. The surplus is never redistributed.
        At viewport 1600 the tracks measured `216px 340px 7px 714.75px` against
        a 1516px deck: a 238px DEAD BAND on the right.

        The user-visible result was the exact opposite of the request — drag
        left to give the mock render more room, get a big empty band.

        The cure is to clamp in JS against the LIVE span so no fr track can ever
        ask for less than its floor. What this test proves is that the numbers
        handed to the grid are always in range; that the band is gone is a
        Chrome measurement.
        """
        span = 1293  # the measured chat+preview span at viewport 1600
        out = _harness({"act": "clamp", "cases": [
            {"f": 0.25, "total": span},
            {"startChatPx": 543, "dx": -300, "total": span},
        ]})
        for case in out["cases"]:
            self.assertGreaterEqual(round(case["chatPx"], 3), out["chatMinPx"],
                                    "the chat track asks for %.2fpx against a "
                                    "%dpx floor — grid clamps it and strands "
                                    "the surplus" % (case["chatPx"],
                                                     out["chatMinPx"]))
            self.assertGreaterEqual(round(case["pvPx"], 3), out["pvMinPx"])
            self.assertAlmostEqual(case["sum"], 1.0, places=9)
            self.assertAlmostEqual(case["chatPx"] + case["pvPx"], span,
                                   places=6,
                                   msg="the two tracks must account for the "
                                       "whole span — the leftover IS the dead "
                                       "band")

    def test_a_drag_toward_the_chat_leaves_no_dead_band_either(self):
        span = 1293
        out = _harness({"act": "clamp", "cases": [
            {"f": 0.97, "total": span},
            {"startChatPx": 543, "dx": 2000, "total": span},
        ]})
        for case in out["cases"]:
            self.assertGreaterEqual(round(case["pvPx"], 3), out["pvMinPx"],
                                    "the preview track asks for %.2fpx against "
                                    "a %dpx floor" % (case["pvPx"],
                                                      out["pvMinPx"]))
            self.assertGreaterEqual(round(case["chatPx"], 3), out["chatMinPx"])
            self.assertAlmostEqual(case["chatPx"] + case["pvPx"], span,
                                   places=6)

    def test_a_split_stored_on_a_WIDER_window_is_clamped_on_reload(self):
        """The same bug with NO DRAG AT ALL. A 0.25 the captain set at 2560px is
        replayed into a 1100px window on the next reload, where 0.25 is below
        the chat's floor — and the dead band appears on a deck nobody touched.
        This is why the clamp lives in the setter and the applier, not only in
        the drag."""
        narrow = 1009  # the measured chat+preview span at viewport 1100
        out = _harness({"act": "clamp",
                        "cases": [{"f": 0.25, "total": narrow}]})
        case = out["cases"][0]
        self.assertGreaterEqual(round(case["chatPx"], 3), out["chatMinPx"])
        self.assertGreaterEqual(round(case["pvPx"], 3), out["pvMinPx"])
        self.assertAlmostEqual(case["chatPx"] + case["pvPx"], narrow, places=6)

    def test_a_container_too_narrow_for_both_floors_degrades_predictably(self):
        """Below chat-floor + preview-floor there is NO split that satisfies
        both, so the bounds collapse. The choice is stated rather than emergent:
        the span is divided in PROPORTION TO THE TWO FLOORS, so neither pane is
        singled out to absorb the shortfall, and it is the same number whatever
        was stored or dragged."""
        tiny = 500  # narrower than 340 + 360
        out = _harness({"act": "clamp", "cases": [
            {"f": 0.05, "total": tiny},
            {"f": 0.95, "total": tiny},
            {"f": 0.42, "total": tiny},
        ]})
        expect = out["chatMinPx"] / float(out["chatMinPx"] + out["pvMinPx"])
        for case in out["cases"]:
            self.assertTrue(case["degraded"],
                            "%dpx must be reported as the degraded case" % tiny)
            self.assertAlmostEqual(case["frac"], expect, places=6)
            self.assertAlmostEqual(case["sum"], 1.0, places=9)
            self.assertAlmostEqual(case["chatPx"] + case["pvPx"], tiny,
                                   places=6)

    def test_the_bounds_are_derived_from_the_floors_not_hardcoded(self):
        out = _harness({"act": "clamp", "cases": [
            {"f": 0.5, "total": 1293}, {"f": 0.5, "total": 2337}]})
        for case, total in zip(out["cases"], (1293, 2337)):
            lo, hi = case["bounds"]
            self.assertGreaterEqual(lo * total, out["chatMinPx"])
            self.assertGreaterEqual((1 - hi) * total, out["pvMinPx"])
            self.assertFalse(case["degraded"])
        # a wider container permits a narrower chat, which is the whole point:
        # the bound is a PIXEL floor expressed as a fraction, not a fraction.
        self.assertLess(out["cases"][1]["bounds"][0],
                        out["cases"][0]["bounds"][0])

    def test_a_press_arms_the_drag_and_a_release_lets_it_go(self):
        """The lifecycle, through the REAL pointerdown handler. A drag that
        never un-registers its listeners is a handle that follows the cursor
        after you let go — and a drag that persists on every move writes to
        storage sixty times a second for one decision.

        This proves the WIRING. It cannot prove a browser delivers a pointer
        event or that any pane moved: the two widths below are told to the
        stub, not measured."""
        out = _harness({"act": "split", "programs": [PROG], "activeId": "s1",
                        "drag": {"chatPx": 600, "pvPx": 600, "dx": 240}})
        armed = out["dragArmed"]
        self.assertEqual(armed["move"], 1, "a press registers no pointermove")
        self.assertEqual(armed["up"], 1)
        self.assertEqual(armed["cancel"], 1,
                         "a cancelled pointer (a system gesture, a lost focus) "
                         "would leave the drag armed forever")
        self.assertIn("dragging", armed["viewClass"])
        # mid-gesture the split MOVES and NOTHING is written…
        self.assertIsNone(armed["stored"])
        during = float(out["duringDrag"]["chatFr"].replace("fr", ""))
        self.assertAlmostEqual(during, 0.70, places=2)
        self.assertIsNone(out["duringDrag"]["stored"])
        # …and the release writes once, and lets go.
        after = out["afterDrag"]
        self.assertEqual((after["move"], after["up"], after["cancel"]),
                         (0, 0, 0), "the drag never released the document")
        self.assertNotIn("dragging", after["viewClass"])
        self.assertAlmostEqual(float(after["stored"]), during, places=4)

    def test_the_handle_is_keyboard_operable(self):
        """It is a control, and every other control on this deck is."""
        out = _harness({"act": "split", "programs": [PROG], "activeId": "s1",
                        "keys": ["ArrowRight", "ArrowRight", "ArrowLeft"]})
        self.assertEqual(out["tabindex"], "0")
        # the standard window-splitter pattern, so a screen reader says what
        # this is and where it is rather than "group".
        self.assertEqual(out["role"], "separator")
        self.assertEqual(out["orientation"], "vertical")
        self.assertTrue(out["label"])
        base = float(out["initial"]["chatFr"].replace("fr", ""))
        first = float(out["keys"]["ArrowRight"]["chatFr"].replace("fr", ""))
        self.assertGreater(first, base, "ArrowRight must widen the chat")
        # …and a nudge PERSISTS, exactly as a drag does. A keyboard user who has
        # to re-set the split on every reload has an inaccessible control.
        self.assertIsNotNone(out["keys"]["ArrowRight"]["stored"])
        self.assertAlmostEqual(float(out["keys"]["ArrowRight"]["stored"]),
                               first, places=4)

    def test_arrow_keys_move_the_split_in_the_direction_they_point(self):
        out = _harness({"act": "split", "programs": [PROG], "activeId": "s1",
                        "keys": ["ArrowLeft"]})
        base = float(out["initial"]["chatFr"].replace("fr", ""))
        left = float(out["keys"]["ArrowLeft"]["chatFr"].replace("fr", ""))
        self.assertLess(left, base,
                        "ArrowLeft must give the PREVIEW the room — it is the "
                        "pane the captain is dragging towards")

    def test_a_double_click_resets_to_the_default(self):
        out = _harness({"act": "split", "programs": [PROG], "activeId": "s1",
                        "storage": {"lcars-holo-split": "0.75"},
                        "dblclick": True})
        self.assertEqual(out["initial"]["chatFr"][:4], "0.75")
        after = float(out["afterDblclick"]["chatFr"].replace("fr", ""))
        pv = float(out["afterDblclick"]["pvFr"].replace("fr", ""))
        self.assertLess(after, pv, "the reset must land on the DEFAULT split, "
                                   "which favours the preview")
        # and the reset is itself persisted — otherwise a reload undoes it.
        self.assertAlmostEqual(float(out["afterDblclick"]["stored"]), after,
                               places=4)

    def test_the_handle_says_what_it_does(self):
        out = _harness({"act": "split", "programs": [PROG], "activeId": "s1"})
        low = out["title"].lower()
        self.assertTrue(low, "the handle has no tooltip at all")
        self.assertIn("drag", low)
        self.assertIn("double", low)

    def test_the_handle_is_not_a_dead_control(self):
        out = _harness({"act": "split", "programs": [PROG], "activeId": "s1"})
        for ctl in out["controls"]:
            self.assertTrue(ctl["wired"] or (ctl["disabled"] and ctl["reason"]),
                            "dead control: %r" % ctl["label"])


@unittest.skipIf(NODE is None, "node not installed")
class ProgramDrawerTest(unittest.TestCase):
    """S128 — Q3, RESOLVED 2026-08-05 (captain, S127 live drive): below the
    breakpoint the PROGRAM LIST collapses to a drawer. Chat and preview keep the
    full width; the list is the pane least needed moment-to-moment.

    The PREVIEW never becomes a toggle at any width — D2's "the preview is the
    point, it must be permanently visible" survives everywhere, and there is a
    test below that says so.

    WHAT THESE CANNOT PROVE: there is no CSS here, so nothing below can tell you
    the drawer slides in, that it is on top of the panes, or that it is hidden
    at all above the breakpoint. They prove the CONTROL exists, is a real
    button, flips one class, and — the part that matters most — does NOT
    re-render the deck.
    """

    def test_a_control_opens_the_drawer_and_it_is_a_real_button(self):
        out = _harness({"act": "drawer", "programs": [PROG], "activeId": "s1"})
        self.assertGreaterEqual(out["toggleCount"], 1,
                                "nothing opens the program drawer")
        # a real <button> is keyboard-operable by the browser itself. This is
        # NOT wrapped in keyActivable: on a <button> that idiom fires click
        # TWICE for one Enter (native + the shim), which on a toggle is a
        # visible no-op.
        self.assertEqual(set(out["toggleTags"]), {"button"})
        self.assertTrue(any("PROGRAM" in t.upper() for t in out["toggleText"]),
                        "the control must name what it opens: %r"
                        % (out["toggleText"],))
        self.assertTrue(out["toggleTitle"])

    def test_the_toggle_states_whether_the_drawer_is_open(self):
        out = _harness({"act": "drawer", "programs": [PROG], "activeId": "s1"})
        self.assertEqual(out["expandedBefore"], ["false"])
        self.assertEqual(out["expandedAfter"], ["true"])
        self.assertNotIn("drawer-open", out["classBefore"])
        self.assertIn("drawer-open", out["classAfter"])

    def test_opening_the_drawer_does_not_rebuild_the_deck(self):
        """The requirement in one assertion: opening the drawer must not lose
        the deck's state or the chat's SCROLL POSITION. A re-render replaces the
        transcript node, and a replaced node is a scroll position back at the
        top. The marker is stamped on the live node and looked for again."""
        out = _harness({"act": "drawer", "programs": [PROG], "activeId": "s1"})
        self.assertTrue(out["transcriptSurvived"],
                        "the toggle re-rendered the deck — the chat's scroll "
                        "position is gone with it")
        self.assertTrue(out["previewSurvived"],
                        "the toggle rebuilt the preview iframe — the mockup "
                        "reloads under a captain who was reading it")
        self.assertEqual(out["turnCountAfter"], 4)

    def test_the_scrim_closes_it_because_that_is_the_gesture_people_make(self):
        out = _harness({"act": "drawer", "programs": [PROG], "activeId": "s1",
                        "closeByScrim": True})
        self.assertTrue(out["scrimPresent"])
        self.assertNotIn("drawer-open", out["classAfterScrim"])
        self.assertEqual(out["expandedAfterScrim"], ["false"])

    def test_the_empty_deck_can_open_the_drawer_too(self):
        """The morning state is SOLO — no chat header to hang the control on —
        and it is exactly the state in which a captain wants the list."""
        out = _harness({"act": "drawer", "programs": [], "activeId": None})
        self.assertGreaterEqual(out["toggleCount"], 1)
        self.assertIn("drawer-open", out["classAfter"])

    def test_the_drawer_toggle_is_not_a_dead_control(self):
        out = _harness({"act": "drawer", "programs": [PROG], "activeId": "s1"})
        for ctl in out["controls"]:
            self.assertTrue(ctl["wired"] or (ctl["disabled"] and ctl["reason"]),
                            "dead control: %r" % ctl["label"])


class DeckLayoutCssTest(unittest.TestCase):
    """The stylesheet half of S128. A rule-existence check is weak evidence and
    is said to be: it cannot resolve a media query, cannot lay out a grid, and
    cannot see a pixel. What it CAN catch is the class of defect that has cost
    this project rounds before — a rule that was never written, a rule the
    ruling forbids, and an old rule left behind to fight the new one.
    """

    @classmethod
    def setUpClass(cls):
        cls.rules, cls.vars = css.load_stylesheets(css.CSS_SHEETS)
        with open(os.path.join(os.path.dirname(HERE), "static",
                               "board.css")) as fh:
            cls.text = fh.read()
        with open(os.path.join(os.path.dirname(HERE), "static",
                               "board.js")) as fh:
            cls.js = fh.read()

    def _rules(self, selector):
        return [r for r in self.rules
                if r.selector.replace(" ", "") == selector]

    def _decl(self, rule, prop):
        for p, v, _imp in rule.decls:
            if p == prop:
                return v
        return None

    def _merged(self, selector, conditional):
        """Last-wins across every rule for `selector` at the given conditional-
        ness. A selector legitimately appears in more than one @media block —
        the drawer's own, and the reduced-motion one — and reading only the last
        rule would report whichever happened to be written second."""
        out = {}
        for r in self._rules(selector):
            if bool(r.conditional) != bool(conditional):
                continue
            for p, v, _imp in r.decls:
                out[p] = v
        return out

    def test_the_split_is_a_variable_not_a_hardcoded_ratio(self):
        base = [r for r in self._rules(".deckview") if not r.conditional]
        self.assertTrue(base, "no unconditional .deckview rule")
        cols = self._decl(base[-1], "grid-template-columns")
        self.assertIn("--holo-chat-fr", cols)
        self.assertIn("--holo-pv-fr", cols)
        self.assertNotIn("1.15fr", cols,
                         "the fixed 1.15 : 1 ratio is still in the sheet")

    def test_both_panes_keep_a_floor(self):
        base = [r for r in self._rules(".deckview") if not r.conditional]
        cols = self._decl(base[-1], "grid-template-columns")
        self.assertEqual(cols.count("minmax("), 2,
                         "each of chat and preview needs a minmax() floor so "
                         "neither can be dragged to nothing: %r" % cols)

    def test_the_px_floors_are_ONE_pair_shared_by_the_stylesheet_and_the_js(self):
        """FIX ROUND 1. The JS clamp and the `minmax()` safety net have to agree
        on the same two numbers or they fight: a JS floor above the CSS one
        wastes room, a JS floor BELOW it re-opens the dead band the clamp
        exists to close. The first cut had a second, different pair for narrow
        windows — that is exactly the drift this asserts away."""
        js = self.js
        chat_min = int(re.search(r"HOLO_CHAT_MIN_PX\s*=\s*(\d+)", js).group(1))
        pv_min = int(re.search(r"HOLO_PV_MIN_PX\s*=\s*(\d+)", js).group(1))
        cols = [self._decl(r, "grid-template-columns") for r in
                self._rules(".deckview")]
        cols = [c for c in cols if c and "minmax(" in c]
        self.assertTrue(cols, "no .deckview rule sizes the two fr tracks")
        for c in cols:
            mins = re.findall(r"minmax\(var\((--[\w-]+),(\d+)px\)", c)
            self.assertEqual([m[1] for m in mins],
                             [str(chat_min), str(pv_min)],
                             "the stylesheet's floors %r do not match the JS "
                             "pair (%d, %d): %r" % (mins, chat_min, pv_min, c))
            # …and both rules must reach for the SAME two variables, so a later
            # override lands on the JS clamp's numbers too.
            self.assertEqual([m[0] for m in mins],
                             ["--holo-chat-min", "--holo-pv-min"])

    def test_the_chat_column_is_NOT_capped(self):
        """HONOUR THE RULING EXACTLY. The captain chose the handle ALONE,
        explicitly over an option that ALSO auto-capped the chat's growth: he
        wants the control, not a rule guessing for him. This test is the guard
        on that, because a max-width is the obvious thing a later session will
        'helpfully' add."""
        for sel in (".deckview", ".holo-chat", ".deckview.holo-chat"):
            for rule in self._rules(sel):
                self.assertIsNone(self._decl(rule, "max-width"),
                                  "%s caps the chat — D2's amendment forbids "
                                  "it" % sel)
        base = [r for r in self._rules(".deckview") if not r.conditional]
        cols = self._decl(base[-1], "grid-template-columns")
        # a max on the chat track is the same cap wearing a different hat.
        self.assertNotIn("clamp(", cols)
        self.assertNotIn("min(", cols)

    def test_solo_still_has_its_own_two_column_rule(self):
        """`.deckview.solo` has no chat and no preview. The split is carried in
        custom properties precisely so this rule is never overridden by an
        inline `grid-template-columns` the JS wrote."""
        solo = [r for r in self._rules(".deckview.solo") if not r.conditional]
        self.assertTrue(solo)
        self.assertEqual(self._decl(solo[-1], "grid-template-columns"),
                         "216px 1fr")

    def test_the_handle_is_a_real_grabbable_column(self):
        rule = self._rules(".deck-split")
        self.assertTrue(rule, "no .deck-split rule in the sheet")
        self.assertEqual(self._decl(rule[-1], "cursor"), "col-resize")
        # a pointer drag on a touch/trackpad surface scrolls the page instead
        # of dragging unless the element opts out.
        self.assertEqual(self._decl(rule[-1], "touch-action"), "none")

    def test_the_drawer_breakpoint_is_the_one_the_captain_named(self):
        """~1200px is the captain's approximation. This is the number he
        changes; it is asserted so a silent drift is a failing test."""
        self.assertIn("@media (max-width:1199px)", self.text)

    def test_the_old_narrow_rule_is_GONE(self):
        """The old narrow rule kept all three panes and squeezed the list to
        170px. It was the honest minimum while Q3 was UNRULED; Q3 now has a
        ruling, and two answers to the same problem in one sheet is how a layout
        ends up depending on which one the cascade happened to pick.

        Read off the PARSED rules, not the raw text, so the comment explaining
        the deletion cannot itself keep this test red."""
        for rule in self._rules(".deckview"):
            cols = (self._decl(rule, "grid-template-columns") or "")
            self.assertNotIn("170px", cols)
            self.assertNotIn("1.05fr", cols)
        # exactly one narrow breakpoint for the deck now, and it is the drawer's
        self.assertNotIn("1100px", self.text.replace("max-width 1100", ""))

    def test_the_drawer_pane_is_lifted_out_of_the_grid(self):
        drawer = self._merged(".programs", conditional=True)
        self.assertTrue(drawer, "no conditional .programs rule — the program "
                                "list never becomes a drawer")
        self.assertEqual(drawer.get("position"), "absolute")
        # hidden, not merely translated: an off-screen pane that is still
        # `visible` is still in the tab order, and Tab walks the captain into a
        # list he cannot see.
        self.assertEqual(drawer.get("visibility"), "hidden")
        opened = self._merged(".deckview.drawer-open.programs", conditional=True)
        self.assertTrue(opened, "nothing brings the drawer back")
        self.assertEqual(opened.get("visibility"), "visible")
        self.assertEqual(opened.get("transform"), "none")

    def test_the_drawer_is_anchored_to_the_deck_it_covers(self):
        base = [r for r in self._rules(".deckview") if not r.conditional]
        self.assertEqual(self._decl(base[-1], "position"), "relative",
                         "an absolutely-positioned drawer on a STATIC parent "
                         "escapes to the nearest positioned ancestor")

    def test_the_preview_never_becomes_a_toggle_at_any_width(self):
        """D2 holds everywhere. If a narrow rule ever hides the preview, this
        is the test that says so."""
        for rule in self._rules(".preview"):
            self.assertNotEqual(self._decl(rule, "display"), "none")
        for sel in (".deckview.drawer-open.preview", ".deckview.preview"):
            for rule in self._rules(sel):
                self.assertNotEqual(self._decl(rule, "display"), "none")

    def test_the_drawer_control_is_absent_until_it_is_needed(self):
        """It is rendered at every width — that is what lets the toggle be a
        class flip instead of a re-render — so the stylesheet is the only thing
        keeping it off a wide screen, where the list is already on show."""
        base = [r for r in self._rules(".holo-drawer-btn") if not r.conditional]
        self.assertTrue(base)
        self.assertEqual(self._decl(base[-1], "display"), "none")
        narrow = [r for r in self._rules(".holo-drawer-btn") if r.conditional]
        self.assertTrue(narrow, "the control is never shown at any width")
        self.assertNotEqual(self._decl(narrow[-1], "display"), "none")


class EmptyPreviewIsLegibleTest(unittest.TestCase):
    """FL-006 — the empty preview's copy sat directly on `.pv-stage`'s 22px holo
    grid with no scrim, so the grid lines ran through the glyphs.

    ⚠ WHAT THIS TEST CANNOT DO. The colour below is a REAL cascade resolution
    against the shipping stylesheets (the S162 machinery from
    test_log_filing_band), so "the rule exists but loses" is caught. The SCRIM
    is not: `::before` and `>` are outside the resolver, and no test in this
    file can see a rendered pixel. `tests/drives/browser/holodeck.sh` is the
    half that measures whether the grid actually stops under the words.
    """

    # `.pv-stage > .pv-none > p`, with the ancestry index.html and renderDeck
    # really build. Ancestry is half of a descendant-selector resolution.
    CHAIN = [("html", frozenset()),
             ("body", frozenset(["lcars-serve"])),
             ("div", frozenset(["deck-host"])),
             ("div", frozenset(["deckview"])),
             ("div", frozenset(["preview"])),
             ("div", frozenset(["pv-stage"])),
             ("div", frozenset(["pv-none"]))]

    @classmethod
    def setUpClass(cls):
        cls.rules, cls.vars = css.load_stylesheets(css.CSS_SHEETS)

    def _rule(self, selector):
        found = [r for r in self.rules if r.selector.replace(" ", "") == selector]
        self.assertTrue(found, "no rule for %r" % selector)
        return found[-1]

    def _decl(self, rule, prop):
        for p, v, _imp in rule.decls:
            if p == prop:
                return v
        return None

    def test_the_body_copy_resolves_to_the_bright_text_not_the_dim_one(self):
        chain = self.CHAIN + [("p", frozenset())]
        colour = css.rgb(css.computed("color", chain, self.rules, self.vars))
        self.assertEqual(colour, css.TEXT,
                         "the empty preview's paragraph resolves to %r — the "
                         "landing state it is meant to match uses --lcars-text"
                         % (colour,))
        self.assertNotEqual(colour, css.TEXT_DIM)

    def test_pv_none_is_positioned_so_a_scrim_can_hang_off_it(self):
        """The half a rule-existence check CAN catch: a `::before` with
        `inset:0` on a STATIC parent escapes to the nearest positioned ancestor
        and scrims the wrong box — the rule ships, the words stay unreadable."""
        self.assertEqual(self._decl(self._rule(".pv-none"), "position"),
                         "relative")

    def test_the_empty_preview_carries_the_landing_state_scrim(self):
        rule = self._rule(".pv-none::before")
        self.assertEqual(self._decl(rule, "position"), "absolute")
        self.assertEqual(self._decl(rule, "inset"), "0")
        self.assertIn("radial-gradient", self._decl(rule, "background") or "")
        # a SCRIM, not an opaque panel: the grid is the deck's identity and has
        # to survive at the edges. The landing state's own gradient ends at 0.
        self.assertIn(",0)", (self._decl(rule, "background") or "")
                      .replace(" ", ""))
        # …and it must never eat a click meant for the pane.
        self.assertEqual(self._decl(rule, "pointer-events"), "none")

    def test_the_copy_sits_ABOVE_the_scrim(self):
        """`.holo-empty > *{position:relative;z-index:1}` is the other half of
        the idiom — without it the scrim paints over the words it exists to
        make readable."""
        rule = self._rule(".pv-none>*")
        self.assertEqual(self._decl(rule, "position"), "relative")
        self.assertEqual(self._decl(rule, "z-index"), "1")

    def test_the_intent_panel_gets_the_same_treatment(self):
        """FL-007 puts a whole rendered document on the same grid."""
        rule = self._rule(".pv-intent::before")
        self.assertIn("radial-gradient", self._decl(rule, "background") or "")
        self.assertEqual(self._decl(self._rule(".pv-intent"), "position"),
                         "relative")


# ════════════════════════════════════════════════════════════════════════════
# S128 (FL-002 / FL-004) — WORK IN FLIGHT, ON EVERY SURFACE THAT OUTLIVES IT
# ════════════════════════════════════════════════════════════════════════════
# S169 (FL-015): `busyLabel` here mirrors the daemon's own copy — see
# `_holodeck_busy_copy`, whose wording is pinned in test_holodeck_endpoints.
# A fixture that keeps the OLD sentence while the daemon moves is S128's
# cross-language drift with the two homes one directory apart.
BUSY_PROG = dict(PROG, busy=True, busySince=1.0, busyFor=132.0,
                 busyLabel="Still working — this turn started about 2 "
                           "minutes ago",
                 busyReason="This program has been working on a turn for "
                            "about 2 minutes. The holodeck runs one turn at a "
                            "time in a room, so Send comes back the moment "
                            "this one lands. You can leave the deck.")


@unittest.skipIf(NODE is None, "node not installed")
class ReturningDeckTest(unittest.TestCase):
    """A deck that re-renders mid-turn read exactly like an idle one.

    `HOLO.busy` is this tab's own memory of its own send: a reload, a second
    tab, or a return from the board has none of it, while the daemon would
    correctly refuse the next `/say`. Everything below is driven off the
    DAEMON's fact (`busy`/`busyLabel`/`busyReason` on the program payload),
    never off a client-side clock.
    """

    def test_a_deck_that_re_rendered_MID_TURN_still_says_it_is_working(self):
        out = _harness({"act": "deck", "programs": [BUSY_PROG],
                        "activeId": "s1"})
        self.assertEqual(out["workingText"], BUSY_PROG["busyLabel"])
        # …and it says roughly HOW LONG, which is the only thing that tells a
        # captain "it is still going" apart from "it hung".
        self.assertIn("2 minutes", out["workingText"])

    def test_Send_is_disabled_with_the_DAEMONS_reason_not_an_invented_one(self):
        out = _harness({"act": "deck", "programs": [BUSY_PROG],
                        "activeId": "s1"})
        self.assertTrue(out["sendDisabled"])
        self.assertEqual(out["sendReason"], BUSY_PROG["busyReason"])
        self.assertEqual(out["sendTitle"], BUSY_PROG["busyReason"])

    def test_an_IDLE_program_is_untouched_by_any_of_it(self):
        """The control. `PROG` carries no busy keys at all — the daemon only
        publishes them while a turn is in flight — so this is the assertion
        that the whole feature is INVISIBLE the rest of the time."""
        out = _harness({"act": "deck", "programs": [PROG], "activeId": "s1"})
        self.assertFalse(out["sendDisabled"])
        self.assertEqual(out["sendReason"], "")
        self.assertEqual(out["workingText"], "")
        self.assertEqual(out["sendLabel"], "SEND ▸")


@unittest.skipIf(NODE is None, "node not installed")
class NewProgramInFlightTest(unittest.TestCase):
    """FL-004 — the dialog's busy state died with the dialog, and so did failure."""

    def test_the_dialog_shows_a_thinking_indicator_while_it_opens_the_deck(self):
        """The captain asked for this in those words. It reuses `.holo-working`
        — the idiom the chat pane already renders — rather than inventing a
        second spinner."""
        out = _harness({"act": "newProgramSubmit", "pick": "grounding",
                        "engine": "copilot", "program": "Nav rail"})
        self.assertIsNotNone(out["dialogWorking"])
        self.assertFalse(out["dialogWorkingHidden"])
        self.assertIn("deck", out["dialogWorking"].lower())
        # the animated bars are the existing idiom's own markup, not a new one.
        self.assertEqual(out["dialogWorkingBars"], 4)
        self.assertEqual(out["dialogWorkingRole"], "status")
        # and the button half that already existed is unchanged.
        self.assertTrue(out["runDisabled"])

    def test_a_start_that_FAILS_lands_somewhere_the_dialog_cannot_take_with_it(self):
        msg = "the copilot worker stopped before it wrote basis.md"
        out = _harness({"act": "newProgramFail", "error": msg,
                        "programs": [], "activeId": None})
        # while the dialog is open it still says so in its own error line…
        self.assertEqual(out["dialogErr"], msg)
        self.assertTrue(out["runReEnabled"])
        self.assertTrue(out["dialogWorkingHidden"])
        # …and CLOSING it does not throw the failure away.
        self.assertTrue(out["bannerPresent"])
        self.assertEqual(out["bannerText"], msg)
        self.assertIn("refuse", out["bannerClass"])
        self.assertTrue(out["bannerLabel"].strip())

    def test_the_failure_reuses_the_decks_OWN_banner_channel(self):
        """Not a second notification path. `holoSetBanner` is the one the deck
        already has, and its kind table is where the title comes from."""
        out = _harness({"act": "newProgramFail", "programs": [],
                        "activeId": None})
        self.assertEqual(out["bannerKind"], "start-failed")


@unittest.skipIf(NODE is None, "node not installed")
class BandActivityTest(unittest.TestCase):
    """FL-002, off-deck: `board.py` had no holodeck awareness at all, so the
    board could not show that the program you left running is still running."""

    META = {"count": 1,
            "message": "The holodeck is working: “Nav rail” has been "
                       "rendering for about 4 minutes. Carry on here — it "
                       "keeps running and saves itself.",
            "working": [{"sessionId": "s1", "program": "Nav rail",
                         "room": "nav-rail", "busy": True, "busySince": 1.0,
                         "busyFor": 240.0}]}

    def test_the_band_control_carries_an_indicator_while_a_program_works(self):
        out = _harness({"act": "bandActivity", "metas": [self.META]})
        state = out["states"][0]
        self.assertTrue(state["working"])
        self.assertEqual(state["dots"], 1)
        # the LABEL is untouched: the indicator is a mark ON the control, not a
        # relabelling of it.
        self.assertEqual(state["label"], "⬡ Holodeck")

    def test_the_words_are_the_DAEMONS_and_name_the_program(self):
        out = _harness({"act": "bandActivity", "metas": [self.META]})
        state = out["states"][0]
        self.assertEqual(state["title"], self.META["message"])
        self.assertIn("Nav rail", state["ariaLabel"] or "")

    def test_the_indicator_GOES_OUT_when_the_turn_lands(self):
        """The assertion a single flattering frame cannot make. A board with no
        `meta.holodeck` is what the daemon sends the moment nothing is in
        flight, and the dot has to follow it down."""
        out = _harness({"act": "bandActivity", "metas": [self.META, None]})
        self.assertTrue(out["states"][0]["working"])
        self.assertFalse(out["states"][1]["working"])
        self.assertEqual(out["states"][1]["dots"], 0)
        self.assertIsNone(out["states"][1]["ariaLabel"])
        self.assertEqual(out["states"][1]["title"],
                         "the holodeck — design a mockup in chat")

    def test_a_board_with_no_holodeck_meta_is_the_control(self):
        """Every board this daemon served before S128 — and every board a
        read-only build serves now — has no `meta.holodeck` at all."""
        out = _harness({"act": "bandActivity", "metas": [None]})
        self.assertFalse(out["states"][0]["working"])
        self.assertEqual(out["states"][0]["dots"], 0)

    def test_a_view_only_board_still_refuses_the_deck_with_its_reason(self):
        """D7 outranks the indicator: a board that cannot run a program must
        not sprout an activity dot claiming one is running."""
        out = _harness({"act": "bandActivity", "metas": [self.META],
                        "writes": False})
        state = out["states"][0]
        self.assertTrue(state["disabled"])
        self.assertFalse(state["working"])
        self.assertIn("read-only", state["title"])


class InFlightCssTest(unittest.TestCase):
    """The activity dot's motion, and the reduced-motion escape this project
    gates every animation on. A rule-existence check, and honest about it: no
    test in this file can see a pixel — `tests/drives/browser/holodeck.sh` is
    the half that measures whether the dot painted at all."""

    @classmethod
    def setUpClass(cls):
        cls.rules, cls.vars = css.load_stylesheets(css.CSS_SHEETS)

    def _merged(self, selector, conditional):
        out = {}
        for r in self.rules:
            if r.selector.replace(" ", "") != selector:
                continue
            if bool(r.conditional) != bool(conditional):
                continue
            for p, v, _imp in r.decls:
                out[p] = v
        return out

    def test_the_dot_animates(self):
        decls = self._merged(".topbar.btn.working.holo-dot", False)
        self.assertTrue(decls, "no unconditional rule for the band's dot")
        self.assertIn("animation", decls)

    def test_and_stops_for_prefers_reduced_motion(self):
        decls = self._merged(".topbar.btn.working.holo-dot", True)
        self.assertEqual(decls.get("animation"), "none",
                         "the dot keeps animating under "
                         "prefers-reduced-motion:reduce")


# ════════════════════════════════════════════════════════════════════════════
# S169 (FL-013 + FL-014) — THE COMPOSER'S UNSENT TURN
#
# In the captain's words, on the S128 re-drive: "I was typing text, but hadn't
# sent it in the holodeck, I switched back to the board to deploy main, and when
# I came back my text was gone." And, one line later: "I can't paste in images
# in my chat."
#
# They are ONE object's state and are tested as one: the draft and the pasted
# screenshot are the same unsent turn, and both were lost for the same reason —
# they lived only in a DOM node `renderDeck` rebuilds on every turn, program
# switch, banner and deck re-entry.
#
# THE NODE IDENTITY IS ASSERTED ALONGSIDE THE VALUE. "The text survived" is
# worth nothing if the pane was simply never rebuilt: that is the shape in which
# this check would pass on a product that had not been fixed at all.
# ════════════════════════════════════════════════════════════════════════════
OTHER = dict(PROG, sessionId="s2", program="Tile picker",
             programDir="/tmp/x/tile-picker",
             turns=[{"text": "Swatch grid.", "reply": "Done."}])


@unittest.skipIf(NODE is None, "node not installed")
class ComposerKeepsTheUnsentTurnTest(unittest.TestCase):
    def _run(self, **kw):
        cfg = {"act": "composer", "programs": [PROG, OTHER], "activeId": "s1",
               "otherId": "s2"}
        cfg.update(kw)
        return _harness(cfg)

    DRAFT = "The tile editor needs a modern toolbar, and it has to remember"

    def test_a_re_render_does_not_eat_what_he_typed(self):
        out = self._run(type=self.DRAFT, after=["render"])
        after = out["steps"][-1]
        self.assertTrue(after["rebuilt"],
                        "the pane was not rebuilt, so this proves nothing "
                        "about a draft surviving a rebuild")
        self.assertEqual(after["value"], self.DRAFT)

    def test_the_board_round_trip_he_actually_described(self):
        """⬡ HOLODECK → ▦ BOARD → ⬡ HOLODECK. His exact journey."""
        out = self._run(type=self.DRAFT, after=["deckRoundTrip"])
        after = out["steps"][-1]
        self.assertTrue(after["rebuilt"])
        self.assertEqual(after["value"], self.DRAFT)

    def test_switching_programs_and_back_keeps_each_ones_own_draft(self):
        """The report named the board round-trip; the mechanism said ANY
        repaint. This is the trigger a single-slot guard (`pvSid`'s shape)
        would have cured the report on and left the defect in."""
        out = self._run(type=self.DRAFT, after=["switch"])
        after = out["steps"][-1]
        self.assertTrue(after["rebuilt"])
        self.assertEqual(after["value"], self.DRAFT)
        # and it is filed under THAT program, not globally
        self.assertEqual(out["drafts"]["s1"]["text"], self.DRAFT)
        self.assertNotIn("s2", out["drafts"])

    def test_a_banner_arriving_does_not_eat_it_either(self):
        out = self._run(type=self.DRAFT, after=["banner"])
        after = out["steps"][-1]
        self.assertTrue(after["rebuilt"])
        self.assertEqual(after["value"], self.DRAFT)

    def test_the_drawer_toggle_does_not_rebuild_the_pane_at_all(self):
        """MEASURED, not assumed. Q3's drawer is a class flip on the live DOM
        precisely so it is not a re-render — so it was never a trigger, and
        this records that rather than leaving it a guess."""
        out = self._run(type=self.DRAFT, after=["drawer"])
        after = out["steps"][-1]
        self.assertFalse(after["rebuilt"])
        self.assertEqual(after["value"], self.DRAFT)

    def test_sending_the_turn_clears_the_draft(self):
        out = self._run(type=self.DRAFT, after=["send"])
        self.assertEqual(out["sendBody"]["text"], self.DRAFT)
        self.assertEqual(out["steps"][-1]["value"], "")
        self.assertNotIn("s1", out["drafts"])

    def test_enter_sends_the_same_turn_and_clears_it_too(self):
        out = self._run(type=self.DRAFT, after=["enter"])
        self.assertEqual(out["sendBody"]["text"], self.DRAFT)
        self.assertNotIn("s1", out["drafts"])


@unittest.skipIf(NODE is None, "node not installed")
class ComposerTakesAPastedImageTest(unittest.TestCase):
    """FL-014. The daemon has had an honest refusal for a pasted holodeck image
    since S124 — and the captain could never read it, because there was no
    paste handler on this textarea at all, so the clipboard event was never
    harvested and nothing was ever sent. A pasted image did NOTHING, in
    silence: the exact thing board.js's own header forbids."""

    def _run(self, **kw):
        cfg = {"act": "composer", "programs": [PROG, OTHER], "activeId": "s1",
               "otherId": "s2", "paste": True}
        cfg.update(kw)
        return _harness(cfg)

    def test_a_pasted_image_becomes_a_chip_on_the_composer(self):
        out = self._run()
        self.assertEqual(out["steps"][0]["chips"], ["[Image #1]"])

    def test_the_image_survives_a_re_render_like_the_text_does(self):
        """The same defect as FL-013 one field over: `attachImagePaster` kept
        its list in a closure that dies with the node. Half a restored draft —
        the words back, the screenshot silently gone — is worse than none, so
        the chip is asserted back on screen too."""
        out = self._run(type="make it look like this", after=["render"])
        after = out["steps"][-1]
        self.assertTrue(after["rebuilt"])
        self.assertEqual(after["value"], "make it look like this")
        self.assertEqual(after["chips"], ["[Image #1]"])
        self.assertEqual(len(after["images"]), 1)

    def test_the_image_rides_the_turn_it_was_pasted_on(self):
        """The holodeck RESUMES a warm session and feeds only what he typed, so
        an image that missed its own turn would never reach the model."""
        out = self._run(type="like this", after=["send"])
        body = out["sendBody"]
        self.assertEqual(body["text"], "like this")
        self.assertEqual(len(body["images"]), 1)
        self.assertEqual(body["images"][0]["type"], "image/png")
        self.assertEqual(body["images"][0]["dataB64"], "QUJD")
        self.assertTrue(out["sendPath"].endswith("/api/holodeck/s1/say"))

    def test_an_unsupported_paste_says_so_instead_of_vanishing(self):
        out = self._run(pasteType="image/tiff")
        self.assertEqual(out["steps"][0]["chips"], [])
        self.assertFalse(out["errHidden"])
        self.assertIn("PNG", out["errText"])

    def test_an_oversized_paste_says_so_too(self):
        out = self._run(pasteSize=99 * 1024 * 1024)
        self.assertEqual(out["steps"][0]["chips"], [])
        self.assertFalse(out["errHidden"])
        self.assertIn("8 MB", out["errText"])

    def test_a_turn_with_no_paste_sends_no_images_key_at_all(self):
        """The regression guard: an ordinary turn's request body must be
        byte-identical to what it was before this existed."""
        out = _harness({"act": "composer", "programs": [PROG, OTHER],
                        "activeId": "s1", "otherId": "s2",
                        "type": "just words", "after": ["send"]})
        self.assertNotIn("images", out["sendBody"])


@unittest.skipIf(NODE is None, "node not installed")
class IntentPanelScrollsInsideItsScrimTest(unittest.TestCase):
    """FL-016, the DOM half. The scrim must hang off a box that does NOT
    scroll, with the document scrolling above it. This says nothing about
    pixels — `tests/drives/browser/holodeck.sh` measures the composited colour
    at the bottom of a long document, which is the only evidence that matters."""

    def test_the_document_lives_in_a_scroller_inside_the_scrim_box(self):
        prog = dict(PROG, conceptFile="concept.md")
        out = _harness({"act": "intentBoxes", "programs": [prog],
                        "activeId": "s1"})
        self.assertTrue(out["panelPresent"])
        self.assertEqual(out["panelChildren"], ["pv-intent-scroll"],
                         "the scrim box must hold exactly the scroller — a "
                         "second child of .pv-intent is content the scrim's "
                         "own containing block is sized around")
        self.assertTrue(out["docInsideScroll"])
        # and the ONE markdown look is untouched (`setMd`'s `.md`), not a
        # second style started inside the new container.
        self.assertTrue(out["mdInsideScroll"])
        self.assertIn("What it must do", out["mdHtml"])


class IntentScrimCssTest(unittest.TestCase):
    """The stylesheet half of FL-016, and the reason it is worth asserting: the
    bug was ONE element carrying both `overflow:auto` and `position:relative`,
    which makes it both the scroll container and the scrim's containing block.
    An absolutely-positioned child of a scroll container is sized to the padding
    box and scrolls with the content, so the darkening slid off and everything
    past the first screen sat bare on the deck's grid."""

    @classmethod
    def setUpClass(cls):
        cls.rules, cls.vars = css.load_stylesheets(css.CSS_SHEETS)

    def _merged(self, selector):
        out = {}
        for r in self.rules:
            if r.selector.replace(" ", "") != selector or r.conditional:
                continue
            for p, v, _imp in r.decls:
                out[p] = v
        return out

    def test_the_scrim_box_does_not_scroll(self):
        decls = self._merged(".pv-intent")
        self.assertTrue(decls, "no unconditional .pv-intent rule")
        self.assertEqual(decls.get("position"), "relative")
        self.assertNotIn(
            "overflow", decls,
            "`.pv-intent` is the scrim's containing block; giving it "
            "`overflow:auto` again puts the scrim back on the scrolling box "
            "and it will slide off exactly as it did (FL-016)")

    def test_the_scroller_is_a_different_box(self):
        decls = self._merged(".pv-intent.pv-intent-scroll")
        self.assertTrue(decls, "no rule for the intent panel's scroller")
        self.assertEqual(decls.get("overflow"), "auto")
        self.assertNotIn("position", decls,
                         "the scroller must not become a containing block too")

    def test_the_fill_is_uniform_where_text_sits(self):
        """The other half of FL-016. `ellipse 78% 74% at 50% 45%` was tuned for
        ONE screen and is down to rgba(...,.55) at its own edges, so legibility
        degraded before the scrim even left. A scrim that no longer moves has
        to hold everywhere text can be."""
        before = self._merged(".pv-intent::before")
        bg = before.get("background", "")
        alphas = re.findall(r"rgba\(3,\s*6,\s*8,\s*\.(\d+)\)", bg)
        self.assertTrue(alphas, "the intent scrim lost its rgba(3,6,8,…) fill")
        weakest = min(float("0." + a) for a in alphas)
        self.assertGreaterEqual(
            weakest, 0.85,
            "the weakest stop in the intent scrim is %s — the old ellipse fell "
            "to .55 at its edges and the captain read his own requirements "
            "through it" % weakest)


# ════════════════════════════════════════════════════════════════════════════
# S169 (FL-015) — THE COMPOSER'S OPTIONAL DECLARATION, AND THE OUTCOME NOTE
#
# The captain asked the holodeck what it meant by the events tab. It answered
# him AND rebuilt part of the mockup he had not asked it to touch, and nothing
# on the screen said so.
#
# Two things live here. The AFFORDANCE — his own explicit declaration of the
# turn's shape, which a rewording cannot defeat — and the OUTCOME NOTE, which is
# the daemon stating what the turn actually did.
#
# THE TRAP, named so nobody re-introduces it: there is NO question-vs-
# instruction classifier anywhere in this feature, on either side. S156's regex
# classifier fell from 14/14 to 5/14 the moment a tester reworded its own corpus
# preserving meaning. Nothing here reads his sentence.
# ════════════════════════════════════════════════════════════════════════════
@unittest.skipIf(NODE is None, "node not installed")
class ComposerDeclaresAskOrBuildTest(unittest.TestCase):
    def _run(self, **kw):
        cfg = {"act": "composer", "programs": [PROG, OTHER], "activeId": "s1",
               "otherId": "s2"}
        cfg.update(kw)
        return _harness(cfg)

    def test_both_halves_are_on_the_composer_with_BUILD_selected(self):
        """OPTIONAL BY CONSTRUCTION: the control opens on BUILD, so a captain
        who never touches it gets exactly today's behaviour. If asking required
        flipping a switch, it would become the switch he forgot and blamed."""
        out = self._run()
        self.assertEqual([o["intent"] for o in out["intentOpts"]],
                         ["build", "ask"])
        self.assertEqual([o["pressed"] for o in out["intentOpts"]],
                         ["true", "false"])
        self.assertEqual(out["sendLabel"], "Send ▸")
        # and it says what each half MEANS, in the deck's own words.
        ask = out["intentOpts"][1]
        self.assertIn("answers and changes nothing", ask["title"])

    def test_declaring_ASK_shows_on_the_control_AND_on_the_send_verb(self):
        """A declaration with no feedback is a switch he flips and then wonders
        about. The verb on the button is the feedback, and it is read off the
        same draft field the POST reads, so the two cannot disagree."""
        out = self._run(type="what is the events tab?", after=["ask"])
        self.assertEqual([o["pressed"] for o in out["intentOpts"]],
                         ["false", "true"])
        self.assertTrue(out["intentOpts"][1]["on"])
        self.assertEqual(out["sendLabel"], "Ask ▸")

    def test_the_declaration_rides_the_turn_it_was_made_on(self):
        out = self._run(type="what is the events tab?", after=["ask", "send"])
        self.assertEqual(out["sendBody"]["intent"], "ask")
        self.assertEqual(out["sendBody"]["text"], "what is the events tab?")
        self.assertTrue(out["sendPath"].endswith("/api/holodeck/s1/say"))

    def test_enter_carries_the_declaration_too(self):
        """Two send paths, one reading. A composer where the button asks and
        the Enter key builds is worse than no control."""
        out = self._run(type="why that spacing?", after=["ask", "enter"])
        self.assertEqual(out["sendBody"]["intent"], "ask")

    def test_an_undeclared_turn_still_declares_BUILD_explicitly(self):
        out = self._run(type="widen the rail", after=["send"])
        self.assertEqual(out["sendBody"]["intent"], "build")

    def test_the_declaration_survives_a_repaint_like_the_rest_of_the_draft(self):
        """It is the third field of ONE unsent turn — what he typed, what he
        pasted, what shape it is — so it lives in `HOLO.drafts[sid]` beside
        them and not in a fourth store. A declaration that a re-render eats is
        FL-013 again, one field over."""
        out = self._run(type="what is this?", after=["ask", "render"])
        self.assertTrue(out["steps"][-1]["rebuilt"])
        self.assertEqual(out["drafts"]["s1"]["intent"], "ask")
        self.assertEqual([o["pressed"] for o in out["intentOpts"]],
                         ["false", "true"])
        self.assertEqual(out["sendLabel"], "Ask ▸")

    def test_it_is_PER_PROGRAM_like_the_rest_of_the_draft(self):
        out = self._run(type="what is this?", after=["ask", "switch"])
        self.assertEqual(out["drafts"]["s1"]["intent"], "ask")
        self.assertNotIn("s2", out["drafts"])

    def test_sending_RESETS_it_so_ASK_never_leaks_into_the_next_turn(self):
        """It is a per-TURN declaration, not a mode. A sticky ASK would be
        worse than no control at all: he flips it once, types "make the rail
        wider" three turns later, and gets an answer."""
        out = self._run(type="what is this?", after=["ask", "send"])
        self.assertNotIn("s1", out["drafts"])
        self.assertEqual([o["pressed"] for o in out["intentOpts"]],
                         ["true", "false"])

    def test_he_can_change_his_mind_back(self):
        out = self._run(type="widen the rail", after=["ask", "build", "send"])
        self.assertEqual(out["sendBody"]["intent"], "build")


@unittest.skipIf(NODE is None, "node not installed")
class TurnOutcomeIsOnTheTurnTest(unittest.TestCase):
    """The half that would have caught the defect when it happened.

    The daemon reads both facts off the audit it already runs; this side
    renders its sentence and invents nothing (the one-voice rule — S125 lost
    two rounds to a client banner beside the daemon's).
    """

    ASKED = {"intent": "ask", "wrote": False, "files": [],
             "message": "Answered — nothing was written. The mockup and the "
                        "concept doc are exactly as they were."}
    DRIFT = {"intent": "ask", "wrote": True, "files": ["mockup.html"],
             "message": "You marked this turn a question, and it wrote "
                        "mockup.html anyway. The design moved on a turn you "
                        "did not direct — look at the preview before you "
                        "build on it."}

    def test_a_turn_that_wrote_nothing_says_so_on_the_turn(self):
        out = _harness({"act": "turnOutcome", "programs": [PROG],
                        "activeId": "s1", "turnOutcome": self.ASKED})
        self.assertTrue(out["outcomePresent"])
        self.assertIn("Nothing written", out["outcomeLabel"])
        self.assertIn("nothing was written", out["outcomeText"])
        self.assertIn(" no", out["outcomeClass"])

    def test_a_declared_question_that_wrote_is_marked_as_DRIFT(self):
        out = _harness({"act": "turnOutcome", "programs": [PROG],
                        "activeId": "s1", "turnOutcome": self.DRIFT})
        self.assertTrue(out["outcomePresent"])
        self.assertIn("Changed on a question", out["outcomeLabel"])
        self.assertIn("mockup.html", out["outcomeText"])
        self.assertIn(" drift", out["outcomeClass"])

    def test_the_words_are_the_DAEMONS_verbatim(self):
        out = _harness({"act": "turnOutcome", "programs": [PROG],
                        "activeId": "s1", "turnOutcome": self.DRIFT})
        self.assertIn(self.DRIFT["message"], out["outcomeText"])

    def test_an_ordinary_build_turn_draws_no_note_at_all(self):
        """The daemon withholds the SENTENCE on a plain build turn that wrote —
        the file chips already say it, and a note that speaks every turn is a
        note people stop reading. This asserts the client draws nothing when
        the daemon says nothing, rather than inventing its own rule."""
        out = _harness({"act": "turnOutcome", "programs": [PROG],
                        "activeId": "s1",
                        "turnOutcome": {"intent": "build", "wrote": True,
                                        "files": ["mockup.html"],
                                        "message": ""}})
        self.assertFalse(out["outcomePresent"])

    def test_a_turn_with_no_outcome_at_all_is_byte_identical_to_before(self):
        out = _harness({"act": "turnOutcome", "programs": [PROG],
                        "activeId": "s1", "turnOutcome": None})
        self.assertFalse(out["outcomePresent"])


class OutcomeNoteIsLegibleTest(unittest.TestCase):
    """S162's lesson, applied before it can bite: a rule that tests green and
    never reaches the screen. The DRIFT note is the one that matters, so it
    must not resolve to muted metadata the way S162's amber warning did."""

    @classmethod
    def setUpClass(cls):
        cls.rules, cls.vars = css.load_stylesheets(css.CSS_SHEETS)

    def _merged(self, selector):
        out = {}
        for r in self.rules:
            if r.selector.replace(" ", "") != selector or r.conditional:
                continue
            for p, v, _imp in r.decls:
                out[p] = v
        return out

    def test_the_drift_note_has_a_background_of_its_own_not_just_ink(self):
        decls = self._merged(".holo-outcome.drift")
        self.assertTrue(decls, "no rule for the drift outcome note")
        self.assertIn("background", decls)
        self.assertIn("border-left", decls)

    def test_the_two_readings_are_visually_distinct(self):
        drift = self._merged(".holo-outcome.drift")
        calm = self._merged(".holo-outcome.no")
        self.assertTrue(calm)
        self.assertNotEqual(drift.get("background"), calm.get("background"))

    def test_the_label_takes_its_own_colour_rather_than_inheriting(self):
        """S162 exactly: `.card .no` tied on specificity and won on source
        order, so the warning rendered in the muted metadata colour."""
        # `_merged` strips spaces, so a descendant selector arrives joined.
        self.assertIn("color", self._merged(".holo-outcome.drift.cl"))
        self.assertIn("color", self._merged(".holo-outcome.no.cl"))

    def test_the_selected_half_of_the_intent_control_is_not_ink_alone(self):
        decls = self._merged(".composer.holo-intent.iopt.on")
        self.assertTrue(decls, "no rule for the selected intent half")
        self.assertIn("background", decls)


# ════════════════════════════════════════════════════════════════════════════
# S170 — THE DERIVATION BAND: THE WAIT, MADE HONEST AND WALK-AWAY-ABLE
#
# The daemon half is in `test_holodeck_endpoints.py` (the captain's real room,
# the fail-safe ladder, the durable record). This half is the last screen he
# sees before a design becomes a mission, and its whole job here is:
#
#   · the running state SAYS HE CAN LEAVE — the sentence the stage is for;
#   · "the pass produced a list" and "the pass could not run" never look alike,
#     because the second means a section of his brief is MISSING;
#   · the brief updates when the pass lands, and NEVER over something he typed;
#   · nothing on this screen claims a comparison the daemon did not make.
#
# WHAT THIS PROCESS CANNOT SEE, said again: there is no CSS and no layout here.
# "Above the box" is asserted as DOM ORDER; "visible", "amber" and "not behind a
# nested scrollbar" belong to tests/drives/browser/handoff.sh.
# ════════════════════════════════════════════════════════════════════════════
DERIVED = [
    "today the toolbar is 48px tall → the mockup grows it to 52px",
    "today there is no theme control and the app is dark-only → the mockup "
    "adds a sun/moon toggle button and a full light theme",
]


def _seed_derive(derive, **extra):
    return dict(SEED, derive=derive, **extra)


@unittest.skipIf(NODE is None, "node not installed")
class HandoffDeriveBandTest(unittest.TestCase):
    def _band(self, derive, **extra):
        out = _harness({"act": "handoffDialog",
                        "seed": _seed_derive(derive, **extra),
                        "stopBeforeFile": True})
        return out, out["check"]

    def test_OFF_renders_NOTHING(self):
        """A captain who turned it off must not be shown a box about it."""
        _out, band = self._band({"state": "off"})
        self.assertTrue(band["hidden"], band)

    def test_RUNNING_TELLS_HIM_HE_CAN_WALK_AWAY(self):
        """THE SENTENCE THE WHOLE STAGE IS FOR. S169's band said "Reading these
        lines back against the mockup…" — a spinner, which tells a captain
        nothing about whether he may leave. The wait was ALREADY 154–220s; what
        was missing was any way to know it was safe to close the dialog."""
        _out, band = self._band({"state": "running"})
        self.assertFalse(band["hidden"])
        self.assertEqual(band["state"], "running")
        t = band["text"]
        self.assertIn("CLOSE THIS AND WALK AWAY IF YOU LIKE", t)
        self.assertIn("keeps running", t)
        self.assertIn("survives a reload and a restart", t)
        self.assertIn("a few minutes", t)
        # …and it says what is MISSING from the brief meanwhile, because a
        # captain who files now files without a change list.
        self.assertIn("send the brief without one", t)
        self.assertNotIn("✓", t)
        # AND IT IS SHORT. Three sentences, no second paragraph: this band
        # pushes the captain's own draft down the first screen, and its first
        # version cost him a visible line at 1440x677 and two at 1280x613
        # (measured by tests/drives/browser/handoff.sh, which is the only thing
        # in this repo that can see it).
        self.assertLess(len(t), 320, t)

    def test_RUNNING_shows_ELAPSED_from_the_DAEMONS_OWN_CLOCK(self):
        """Never a timestamp this side subtracts against its own — that is the
        class of bug `busyFor` was built to avoid (S128/FL-002). Without BOTH
        numbers it says nothing rather than guessing."""
        _out, band = self._band({"state": "running", "startedAt": 1000,
                                 "now": 1045})
        self.assertIn("started 45s ago", band["text"])
        _out, quiet = self._band({"state": "running", "startedAt": 1000})
        self.assertNotIn("ago", quiet["text"])

    def test_DONE_says_WHAT_IT_READ_and_WHY_THE_LIST_IS_SHORT(self):
        _out, band = self._band({"state": "done", "ok": True,
                                 "changes": DERIVED})
        t = band["text"]
        self.assertEqual(band["state"], "done")
        self.assertIn("stood in your project", t)
        self.assertIn("2 changes", t)
        # the rule that makes a short list READ as a short list rather than as
        # a list that lost something — the captain's actual complaint.
        self.assertIn("produces no line", t)
        self.assertIn("shorter than the design chat", t)

    def test_FAILED_IS_NOT_MISTAKEN_FOR_DONE(self):
        """The one that would quietly undo the round: a pass that could not run
        must never render like one that did, because a section of his brief is
        not there and only this band can tell him."""
        _out, band = self._band({"state": "done", "ok": False,
                                 "why": "it did not answer within 420s"})
        self.assertEqual(band["state"], "failed")
        self.assertNotIn("done", band["cls"])
        self.assertNotIn("✓", band["text"])
        self.assertIn("could not read your project", band["text"])
        self.assertIn("420s", band["text"])
        self.assertIn("Nothing is blocked", band["text"])

    def test_an_EMPTY_derivation_is_reported_as_what_it_IS(self):
        """Not a failure and not a clean result. On a design somebody spent an
        afternoon on, "nothing differs" is far likelier to be a bad pass than a
        true finding, and the band says exactly that."""
        _out, band = self._band({"state": "done", "ok": True, "changes": []})
        self.assertEqual(band["state"], "done")
        self.assertIn("found nothing different", band["text"])
        self.assertIn("much more likely to be a bad pass", band["text"])
        self.assertNotIn("✓", band["text"])

    def test_the_band_is_ABOVE_the_brief_box_and_BELOW_the_hint(self):
        """POSITION IS THE CLAIM. The box takes the height of the draft (S169
        fix round 1), so anything under it is ~800px down at a one-screen
        viewport. Under the hint, because the hint says what the draft IS and
        this says what is happening to it."""
        out, _band = self._band({"state": "running"})
        order = out["briefFieldOrder"]
        self.assertIn("handoff-derive", order, order)
        self.assertIn("handoff-brief", order, order)
        hint = [i for i, n in enumerate(order) if n == "hint"]
        self.assertTrue(hint, order)
        self.assertLess(hint[0], order.index("handoff-derive"), order)
        self.assertLess(order.index("handoff-derive"),
                        order.index("handoff-brief"), order)

    def test_the_band_NEVER_COMPOSES_THE_DRAFT(self):
        """The daemon writes the brief; this renders what came back. Whatever
        state the band is in, the box holds the daemon's text verbatim.

        WHAT THIS PROCESS CANNOT REACH, said out loud: what happens when the
        derivation LANDS while the dialog is open. The harness's fetch stub
        never resolves — deliberately, so nothing races an assertion — so the
        poll's callback (`briefLanded`: replace the draft if he has not touched
        it, APPEND the daemon's own change block if he has, never overwrite)
        cannot be driven from here. It is measured in real Chrome instead, in
        both directions: `tests/drives/browser/handoff.sh`'s `typed` product
        run types into the box while the pass runs and requires BOTH his words
        and the derived change to survive, and its `brief-clobbers-his-edits`
        red control removes the pristine test and is verified to go red."""
        for d in ({"state": "off"}, {"state": "running"},
                  {"state": "done", "ok": False, "why": "x"},
                  {"state": "done", "ok": True, "changes": DERIVED}):
            out = _harness({"act": "handoffDialog", "seed": _seed_derive(d),
                            "stopBeforeFile": True})
            self.assertEqual(out["briefValue"], SEED["brief"], d)

    def test_RUNNING_really_does_ASK_AGAIN(self):
        """A spinner that never resolves is worse than no band. It comes back
        to `promote` — the endpoint that already owns this question — rather
        than to a second road that would have to be kept in step with the
        draft, which is now the thing the pass PRODUCES."""
        out = _harness({"act": "handoffDialog",
                        "seed": _seed_derive({"state": "running"}),
                        "stopBeforeFile": True, "pollCheck": True})
        self.assertEqual(out.get("pollErrors"), [], out.get("pollErrors"))
        polls = out["checkPolls"]
        self.assertTrue(polls, out)
        self.assertEqual(polls[0]["url"], "/api/holodeck/s1/promote")
        self.assertEqual(polls[0]["body"]["scope"], "look+behaviour")

    def test_a_SETTLED_derivation_does_NOT_keep_asking(self):
        """The control. A poll that fires whatever the daemon said is a worker
        spawned on a loop for a dialog nobody is reading."""
        for d in ({"state": "off"},
                  {"state": "done", "ok": True, "changes": DERIVED},
                  {"state": "done", "ok": False, "why": "x"}):
            out = _harness({"act": "handoffDialog", "seed": _seed_derive(d),
                            "stopBeforeFile": True, "pollCheck": True})
            self.assertEqual(out["checkPolls"], [], d)

    def test_the_hand_off_can_be_FILED_in_EVERY_state(self):
        """FAIL-SAFE on this side too. A verification step that can block a
        hand-off is worse than the defect it cures — and this one produces a
        section of the brief, so "blocked" would mean a captain stuck at the
        last click of a design session."""
        for d in ({"state": "off"}, {"state": "running"},
                  {"state": "done", "ok": False, "why": "x"},
                  {"state": "done", "ok": True, "changes": []},
                  {"state": "done", "ok": True, "changes": DERIVED}):
            out = _harness({"act": "handoffDialog", "seed": _seed_derive(d)})
            self.assertEqual(out["filePath"], "/api/park", d)
            self.assertEqual(out["fileBody"]["holodeck"], "s1", d)


@unittest.skipIf(NODE is None, "node not installed")
class HandoffHintTellsTheTruthTest(unittest.TestCase):
    """The line four inches above the box.

    S169 fix round 2 took out a claim the daemon could not make ("18 CHANGES
    THE MOCKUP MAKES TO TODAY'S APP" over a list read out of `## Decisions`).
    S170 makes half of that claim TRUE and the other half false in the other
    direction: the change list really is read off his project, and his words
    and the implied items still come out of the concept doc. So the sentence
    names both sources, and the counts are still the daemon's own.
    """

    SEED3 = dict(SEED, changes=["a", "b", "c"], implied=["x"],
                 outOfScope=["z"])

    def test_it_says_the_CHANGES_were_READ_OFF_HIS_PROJECT(self):
        out = _harness({"act": "handoffDialog", "seed": self.SEED3,
                        "stopBeforeFile": True})
        hint = out["briefHint"]
        self.assertIn("3 changes read off your project", hint)
        self.assertIn("1 the mockup implies", hint)
        self.assertIn("1 out of scope", hint)

    def test_it_no_longer_calls_the_LIST_a_reading_of_the_DESIGN_CHAT(self):
        out = _harness({"act": "handoffDialog", "seed": self.SEED3,
                        "stopBeforeFile": True})
        hint = out["briefHint"]
        self.assertNotIn("the design chat recorded", hint)
        self.assertNotIn("Drafted from your concept doc", hint)

    def test_the_COUNTS_are_still_the_daemons_own(self):
        """The half that must not regress: the sentence cannot claim something
        the draft does not contain, so the numbers come from the daemon's sets
        and are never counted on this side.

        S171 — AND HIS OWN WORDS ARE NAMED, NOT COUNTED. The brief's head is
        his opening description whole, so "2 things you said" would be
        counting quoted fragments that are no longer in the box."""
        out = _harness({"act": "handoffDialog", "seed": self.SEED3,
                        "stopBeforeFile": True})
        self.assertIn("your own words", out["briefHint"])
        self.assertNotIn("things you said", out["briefHint"])


@unittest.skipIf(NODE is None, "node not installed")
class HandoffCueStopsCryingWolfTest(unittest.TestCase):
    """`⚠ 2 OPEN QUESTIONS UNANSWERED — READ THEM FIRST`, in amber, beside ▦
    FILE MISSION — the single most prominent thing in the dialog, and on the
    2026-08-07 capstone it was FALSE: both questions were settled in their own
    text and one was then re-asked at a real human gate.

    It was also guaranteed to fire: nothing is answered when the dialog opens.
    A warning that is always on is not a warning, and it trains the captain to
    click past the strip where a real finding would appear.
    """

    def test_it_no_longer_opens_with_a_WARNING(self):
        out = _harness({"act": "handoffDialog", "seed": SEED,
                        "stopBeforeFile": True})
        cue = out["qcue"]
        self.assertNotIn("⚠", cue["text"])
        self.assertNotIn("unanswered", cue["text"].lower())

    def test_it_STILL_says_they_exist_and_is_STILL_a_control(self):
        """S128's job for it is untouched: filing without KNOWING they exist
        must stay impossible, and it must take him to them."""
        out = _harness({"act": "handoffDialog", "seed": SEED,
                        "stopBeforeFile": True, "clickCue": True})
        cue = out["qcue"]
        self.assertIn("2", cue["text"])
        self.assertIn("open question", cue["text"].lower())
        self.assertTrue(cue["inFoot"], cue)
        self.assertTrue(cue["wired"], cue)
        self.assertTrue(out["cueScrolled"], out)

    def test_the_COUNT_still_falls_as_he_answers(self):
        out = _harness({"act": "handoffDialog", "seed": SEED,
                        "answers": {"q1": "Only board verbs."},
                        "stopBeforeFile": True})
        self.assertEqual(out["qcue"]["open"], "1", out["qcue"])
        self.assertIn("1 open question", out["qcue"]["text"])

    def test_ALL_ANSWERED_is_still_the_tick(self):
        out = _harness({"act": "handoffDialog", "seed": SEED,
                        "answers": {"q1": "a", "q2": "b"},
                        "stopBeforeFile": True})
        self.assertIn("✓", out["qcue"]["text"])
        self.assertNotIn("open", out["qcue"]["cls"], out["qcue"])

    def test_the_questions_hint_no_longer_promises_STILL_OPEN(self):
        """The daemon stopped writing that marker (`_handoff_questions_block`);
        a dialog still promising it would be describing a product that no
        longer exists."""
        out = _harness({"act": "handoffDialog", "seed": SEED,
                        "stopBeforeFile": True})
        self.assertNotIn("STILL OPEN", out["questionsText"])
        self.assertIn("NO ANSWER RECORDED", out["questionsText"])


class HandoffScrollerCssTest(unittest.TestCase):
    """ONE SCROLLER IN THIS DIALOG, and it is `.modal-body`.

    Fix round 1 cured the brief textarea and MISSED `.handoff-guidance` — the
    box carrying the entire precedence rule, the paragraph that tells every
    stage the mockup wins on look and that a "kept X" line is the account being
    wrong. MEASURED in real Chrome on the capstone: clientHeight 228 against
    scrollHeight 729. 69% of it hidden.

    A rule-existence check is weak evidence and is said to be: it cannot lay
    out a box or measure a pixel. tests/drives/browser/handoff.sh is where the
    numbers come from. What this catches is the rule coming back.
    """

    @classmethod
    def setUpClass(cls):
        cls.rules, cls.vars = css.load_stylesheets(css.CSS_SHEETS)

    def _decls(self, selector):
        out = {}
        for r in self.rules:
            if r.selector.replace(" ", "") == selector:
                for p, v, _imp in r.decls:
                    out[p] = v
        return out

    def test_the_guidance_box_has_NO_HEIGHT_CAP(self):
        d = self._decls(".handoff-guidance")
        self.assertTrue(d, "the rule vanished entirely")
        self.assertNotIn("max-height", d, d)
        self.assertNotIn("height", d, d)

    def test_it_is_NOT_A_SCROLL_CONTAINER_ON_EITHER_AXIS(self):
        """`overflow-x:auto` alone makes it one on BOTH axes — a non-`visible`
        value on one axis computes the other to `auto` — so leaving it would
        keep the machinery one `max-height` away from returning."""
        d = self._decls(".handoff-guidance")
        for prop in ("overflow", "overflow-x", "overflow-y"):
            self.assertNotIn(prop, d, d)

    def test_the_text_still_cannot_push_the_dialog_WIDER(self):
        """What `overflow-x:auto` was really for. A long unbroken selector or
        path in that block must wrap, not scroll and not stretch."""
        d = self._decls(".handoff-guidance")
        self.assertEqual(d.get("white-space"), "pre-wrap", d)
        self.assertEqual(d.get("overflow-wrap"), "anywhere", d)

    def test_the_brief_box_is_still_uncapped_too(self):
        """Fix round 1's cure, pinned from here so a later session cannot
        re-cap one box while uncapping the other."""
        for r in self.rules:
            if "handoff-brief" in r.selector:
                for p, _v, _i in r.decls:
                    self.assertNotEqual(p, "max-height", r.selector)


class HandoffCheckCssTest(unittest.TestCase):
    """The derivation band's four states have to be four different things on
    screen. This can only say the rules exist and differ; handoff.sh measures
    the composited pixels."""

    @classmethod
    def setUpClass(cls):
        cls.rules, cls.vars = css.load_stylesheets(css.CSS_SHEETS)

    def _decls(self, selector):
        out = {}
        for r in self.rules:
            if r.selector.replace(" ", "") == selector:
                for p, v, _imp in r.decls:
                    out[p] = v
        return out

    def test_the_band_exists_and_hides_when_hidden(self):
        self.assertTrue(self._decls(".field.handoff-derive"))
        self.assertEqual(
            self._decls(".field.handoff-derive[hidden]").get("display"), "none")

    def test_RUNNING_is_AMBER_and_carries_its_OWN_background(self):
        """S162's lesson on this exact surface: a band that ties `.hint` on
        specificity and loses on source order renders as muted metadata. This
        rule is more specific than `.field .hint` and paints its own band, so
        it cannot be quietly demoted by a neighbour.

        S170 MOVED THE AMBER FROM `flagged` TO `running`, deliberately. It is
        no longer "wait a moment" — it is "a section of your brief is not here
        yet and you may walk away", which is the sentence the whole stage
        exists to deliver."""
        d = self._decls(".field.handoff-derive.running")
        self.assertIn("amber", d.get("border-color", ""))
        self.assertIn("rgba(255,170,0", d.get("background", "").replace(" ", ""))

    def test_DONE_is_a_DIFFERENT_COLOUR_from_running(self):
        done = self._decls(".field.handoff-derive.done")
        running = self._decls(".field.handoff-derive.running")
        self.assertTrue(done, "the done state has no rule of its own")
        self.assertNotEqual(done.get("border-color"),
                            running.get("border-color"))
        self.assertNotIn("background", done, done)

    def test_the_CUE_is_no_longer_painted_as_a_WARNING(self):
        """It kept its prominence and lost the amber. The amber in this dialog
        now belongs to the two bands that report something MEASURED."""
        d = self._decls(".modal-foot.handoff-foot.btn.qcue.open")
        self.assertTrue(d, "the open state lost its rule entirely")
        blob = " ".join(d.values())
        self.assertNotIn("amber", blob, d)
        self.assertNotIn("255,170,0", blob.replace(" ", ""), d)
        # …and it is still visually distinct from the answered state.
        base = self._decls(".modal-foot.handoff-foot.btn.qcue")
        self.assertNotEqual(base.get("border-left"), d.get("border-left"))


# ── S172: ⧉ DUPLICATE on the deck ───────────────────────────────────────────
# The control has to be reachable from a LOCKED card — that is the state it was
# built for. A sent program refuses every turn (it is the exact design a mission
# was briefed on), so duplicating it is the only way to keep designing from a
# design that already shipped; a control rendered on drafts only would be absent
# in precisely the case it exists for.
SENT_PROG = dict(DISK_PROG, program="Command palette", room="command-palette",
                 programDir="/tmp/x/command-palette", status="sent",
                 lifecycle="sent", missionId="m-777")

DUPED_PROG = dict(DISK_PROG, sessionId="s2", onDisk=False,
                  program="Command palette (copy)",
                  room="command-palette-copy",
                  programDir="/tmp/x/command-palette-copy",
                  grounded=True, basisFile="basis.md",
                  basisInherited=True,
                  basisNotice=("This program's basis.md came over with the "
                               "duplicate: it is what LCARS read out of the "
                               "project for “Command palette”, not a fresh "
                               "look at it."),
                  duplicatedFrom={"room": "command-palette",
                                  "program": "Command palette",
                                  "missionId": "m-777", "at": "now"})


@unittest.skipIf(NODE is None, "node not installed")
class DuplicateControlTest(unittest.TestCase):
    def test_a_LOCKED_card_carries_the_duplicate_control(self):
        out = _harness({"act": "deck", "programs": [SENT_PROG],
                        "activeId": None})
        row = out["listRows"][0]
        self.assertTrue(any("Duplicate" in c for c in row["controls"]),
                        row["controls"])

    def test_the_confirmation_says_the_chat_comes_over_before_the_button(self):
        out = _harness({"act": "duplicateProgram", "programs": [SENT_PROG],
                        "room": "command-palette", "stopAtConfirm": True})
        self.assertTrue(out["hasControl"])
        text = out["confirmText"]
        low = text.lower()
        self.assertIn("command-palette", text)
        # the RULING, said before he commits to it.
        self.assertIn("conversation", low, text)
        # and the two things that would otherwise surprise him later.
        self.assertIn("m-777", text)
        self.assertIn("change list", low, text)

    def test_nothing_is_duplicated_until_the_confirmation_is_taken(self):
        out = _harness({"act": "duplicateProgram", "programs": [SENT_PROG],
                        "room": "command-palette", "stopAtConfirm": True})
        # the control was really clicked and a dialog really opened — otherwise
        # "no POST" is a claim about a button that is not there.
        self.assertTrue(out["hasControl"])
        self.assertTrue(out["confirmText"])
        self.assertIsNone(out["path"])

    def test_a_blank_name_posts_the_ROOM_alone_and_lets_the_daemon_name_it(self):
        """The daemon is the only side that can see which rooms are taken, and
        a duplicate is where a collision is likeliest — the obvious name is
        derived from one that already exists. Blank is the road that cannot
        collide, and the field says so."""
        out = _harness({"act": "duplicateProgram", "programs": [SENT_PROG],
                        "room": "command-palette"})
        self.assertTrue(out["hasNameField"])
        self.assertIn("blank", (out["namePlaceholder"] or "").lower())
        self.assertEqual(out["path"], "/api/holodeck/duplicate")
        self.assertEqual(out["body"], {"room": "command-palette"})

    def test_a_typed_name_is_posted_as_the_copys_own(self):
        out = _harness({"act": "duplicateProgram", "programs": [SENT_PROG],
                        "room": "command-palette", "name": "Palette mark II"})
        self.assertEqual(out["body"], {"room": "command-palette",
                                       "program": "Palette mark II"})

    def test_the_card_says_WHAT_a_duplicate_came_from(self):
        """"Which one was that" is the question the program list exists to
        answer, and two cards that look alike is exactly what duplicating
        produces."""
        out = _harness({"act": "deck", "programs": [DUPED_PROG, SENT_PROG],
                        "activeId": "s2"})
        rows = {r["name"]: r for r in out["listRows"]}
        dup = rows["Command palette (copy)"]
        self.assertIn("Command palette", dup["prow"])
        # the PARENT's mission is in the title, not on the face of a card whose
        # own chip reads `draft` — it is the parent's number, not this one's.
        self.assertNotIn("m-777", dup["prow"])
        self.assertIn("m-777", dup["dupTitle"])
        self.assertIn("command-palette", dup["dupTitle"])
        # …and an ordinary program grows no such chip.
        self.assertIsNone(rows["Command palette"]["dupTitle"])


class DuplicateChipReachesTheScreenTest(unittest.TestCase):
    """A class with no rule behind it renders as unstyled default text, and a
    rule that loses on specificity or source order never reaches the screen at
    all (S162's amber warning). The node harness sees no CSS, so the rule is
    asserted here — and the pixels are `tests/drives/browser/holodeck.sh`."""

    @classmethod
    def setUpClass(cls):
        cls.rules, cls.vars = css.load_stylesheets(css.CSS_SHEETS)

    def _decls(self, selector):
        out = {}
        for r in self.rules:
            if r.selector.replace(" ", "") == selector:
                for p, v, _imp in r.decls:
                    out[p] = v
        return out

    def test_the_chat_headers_lineage_chip_has_a_rule_of_its_own(self):
        """FIX ROUND 1 (D7). A class with no rule behind it is unstyled default
        text, and this one sits beside `.ground-chip` — same selector depth, so
        neither can lose to the other on specificity or source order."""
        mine = self._decls(".cont-chip")
        self.assertTrue(mine, "the .cont-chip rule is missing entirely")
        self.assertTrue(self._decls(".ground-chip"))
        self.assertIn("color", mine, mine)
        self.assertIn("border", mine, mine)
        # it WRAPS: the parent is named with a whole idea sentence, and a chip
        # that ellipsises that answers "which one was that" with nothing.
        self.assertNotEqual(mine.get("white-space"), "nowrap", mine)

    def test_the_lineage_chip_has_a_rule_at_the_same_depth_as_its_neighbours(self):
        mine = self._decls(".prog.prow.pdup")
        self.assertTrue(mine, "the .pdup rule is missing entirely")
        # the same selector depth as the chips it sits between, so it cannot
        # lose to either of them on specificity or source order.
        for neighbour in (".prog.prow.pdisk", ".prog.prow.pmission"):
            self.assertTrue(self._decls(neighbour), neighbour)
        self.assertIn("color", mine, mine)
        self.assertIn("font-size", mine, mine)


@unittest.skipIf(NODE is None, "node not installed")
class InheritedBasisIsNotThisProjectsGroundingTest(unittest.TestCase):
    """TRAP 2 on the surface. The chip asserted "▣ grounded in <repo>" off
    `grounded` alone, and on a duplicate that is a claim about a pass that never
    ran here — usually over a project that has moved since."""

    def test_the_chip_says_the_grounding_was_INHERITED(self):
        out = _harness({"act": "deck", "programs": [DUPED_PROG],
                        "activeId": "s2"})
        text = (out["groundChipText"] or "").lower()
        self.assertIn("inherited", text, out["groundChipText"])
        self.assertIn("stale", text, out["groundChipText"])
        self.assertNotIn("grounded in", text, out["groundChipText"])
        # ONE VOICE: the explanation is the daemon's own sentence, verbatim.
        self.assertEqual(out["groundChipTitle"], DUPED_PROG["basisNotice"])
        # …and it is still a LINK, so the inherited basis stays readable.
        self.assertEqual(out["groundChipTag"], "a")

    def test_the_chat_header_says_WHOSE_conversation_is_in_the_pane(self):
        """FIX ROUND 1 (D7). The duplicate's pane opens holding the PARENT's
        whole chat, and the only thing that ever said so was the banner — which
        is transient. After one refresh the header named this program, the turns
        under it were somebody else's, and nothing joined the two up."""
        out = _harness({"act": "deck", "programs": [DUPED_PROG],
                        "activeId": "s2"})
        self.assertIsNotNone(out["contChipText"],
                             "no lineage chip in the chat header")
        self.assertIn("Command palette", out["contChipText"])
        # the parent's MISSION is in the title, not on the face of a header
        # belonging to a program that was never filed.
        self.assertNotIn("m-777", out["contChipText"])
        self.assertIn("m-777", out["contChipTitle"])
        self.assertIn("command-palette", out["contChipTitle"])
        # ONE VOICE: it states the lineage. "Nothing is binding" is the
        # banner's sentence and the worker's instruction, not a third copy.
        self.assertNotIn("inherited grounding", out["contChipText"].lower())

    def test_an_ordinary_program_grows_no_lineage_chip_in_its_header(self):
        prog = dict(DUPED_PROG)
        prog.pop("duplicatedFrom", None)
        out = _harness({"act": "deck", "programs": [prog], "activeId": "s2"})
        self.assertIsNone(out["contChipText"])

    def test_an_ordinary_grounded_program_still_names_the_project(self):
        prog = dict(DUPED_PROG)
        for key in ("basisInherited", "basisNotice", "duplicatedFrom"):
            prog.pop(key, None)
        out = _harness({"act": "deck", "programs": [prog], "activeId": "s2"})
        self.assertIn("grounded in", (out["groundChipText"] or "").lower())
        self.assertIn("basis.md", out["groundChipTitle"])


if __name__ == "__main__":
    unittest.main()

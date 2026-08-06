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
        for path in ("/api/holodeck/start", "/api/holodeck/x/say",
                     "/api/holodeck/x/end"):
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
        out = _harness({"act": "deck", "programs": [PROG], "activeId": "s1"})
        self.assertEqual(out["paneClasses"], ["programs", "holo-chat", "preview"])
        self.assertIn("deckview", out["deckviewClass"])
        self.assertNotIn("solo", out["deckviewClass"])

    def test_with_no_program_selected_the_deck_is_the_empty_state(self):
        out = _harness({"act": "deck", "programs": [], "activeId": None})
        self.assertEqual(out["paneClasses"], ["programs", "holo-empty"])
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

    def test_a_turn_in_flight_shows_the_rendering_state(self):
        out = _harness({"act": "deck", "programs": [PROG], "activeId": "s1",
                        "busy": True})
        self.assertIn("RENDERING ON THE HOLODECK", out["workingText"].upper())
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
        self.assertIn("cannot take pasted images yet",
                      out["screenshotReason"].lower())

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

SEED = {
    "sessionId": "s1", "program": "Command palette", "room": "command-palette",
    "engine": "claude",
    "brief": "Build a Cmd-K command palette overlay for the board.",
    "summarySource": "Hand-off summary",
    "scope": "look+behaviour", "scopeOptions": ["look+behaviour", "look-only"],
    "guidance": ("## How to read the attached mockup\n\n"
                 "- HOW MUCH TO BUILD: look AND behaviour.\n"
                 "- Where the mockup and the brief disagree, the brief wins.\n"
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

    def test_the_DUPLICATE_hatch_is_named_and_honestly_off(self):
        """It is the designed escape hatch and it is not built — so it is shown
        disabled saying exactly that, rather than hidden or dead on click."""
        out = _harness({"act": "handoffBar", "programs": [SENT],
                        "activeId": "s1"})
        dup = [c for c in out["lockControls"]
               if "duplicate" in c["label"].lower()]
        self.assertEqual(len(dup), 1, out["lockControls"])
        self.assertFalse(dup[0]["wired"])
        self.assertIn("not built yet", dup[0]["reason"].lower())

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
class HandoffDialogTest(unittest.TestCase):
    def test_it_opens_PRE_SEEDED_so_the_next_action_is_one_click(self):
        out = _harness({"act": "handoffDialog", "seed": SEED,
                        "stopBeforeFile": True})
        self.assertEqual(out["briefValue"], SEED["brief"])
        self.assertTrue(out["fileFound"])
        self.assertEqual(out["rides"], ["mockup.html", "concept.md"])

    def test_the_guidance_is_shown_VERBATIM_before_he_sends(self):
        out = _harness({"act": "handoffDialog", "seed": SEED,
                        "stopBeforeFile": True})
        self.assertEqual(out["guidance"], SEED["guidance"])
        self.assertIn("Where the mockup and the brief disagree, the brief wins.",
                      out["guidance"])

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


if __name__ == "__main__":
    unittest.main()

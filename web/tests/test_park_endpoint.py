"""Park & Align (S137) — the board's /api/park write path + the parked-mission
Align-start (grill-completion) variant.

`POST /api/park {idea, engine}` dispatches `file.sh --park` (the backlog-fast
pre-PRD standby lane, S136). `POST /api/align/start {missionId}` seeds the warm
grill from the parked mission's idea.md and, on the done turn, dispatches
`file.sh --complete <id> --prd ...` (grill-completion IN PLACE) — NOT a fresh
`--prd` filing. Read-only builds 403 both.

Each skill call is an env-injected RECORDING STUB, so we assert the exact
dispatch (argv/engine) with ZERO model / gh / git spend.
"""
import json
import os
import sys
import tempfile
import threading
import unittest
import urllib.error
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from tests import _fixtures as fx  # noqa: E402
from lcars_serve.local_adapter import LocalAdapter  # noqa: E402
from lcars_serve.server import make_server  # noqa: E402
from lcars_serve.actions import Actions  # noqa: E402


def _record_stub(record_path):
    """A bash stub that records "$@" (argv), env, and every --idea/--prd file's
    CONTENT, then exits 0. APPENDS a block per invocation."""
    fd, path = tempfile.mkstemp(suffix=".sh")
    os.close(fd)
    script = r'''#!/usr/bin/env bash
{
  printf "ARGV: %s\n" "$*"
  printf "ENV_WORKER_BIN: %s\n" "${LCARS_WORKER_BIN:-}"
  prev=""
  for a in "$@"; do
    if [ "$prev" = "--idea" ] || [ "$prev" = "--prd" ]; then
      printf "FILE[%s]:\n" "$prev"
      cat "$a" 2>/dev/null
      printf "\nENDFILE\n"
    fi
    prev="$a"
  done
} >> "REC"
exit 0
'''.replace("REC", record_path)
    with open(path, "w") as fh:
        fh.write(script)
    os.chmod(path, 0o755)
    return path


def _worker_stub(turns_path, prompt_log):
    """Cold-worker stub: pops the next canned turn off `turns_path` (blobs split
    on ===TURN===) and prints it; records the prompt it saw. Zero spend."""
    fd, path = tempfile.mkstemp(suffix=".sh")
    os.close(fd)
    script = r'''#!/usr/bin/env bash
prompt=""
prev=""
for a in "$@"; do
  if [ "$prev" = "-p" ]; then prompt="$a"; fi
  prev="$a"
done
printf "===PROMPT===\n%s\n" "$prompt" >> "PROMPTLOG"
idx_file="TURNS.idx"
i=0
[ -f "$idx_file" ] && i=$(cat "$idx_file")
awk -v want="$i" 'BEGIN{n=0} /^===TURN===$/{n++; next} {if(n==want) print}' "TURNS"
echo $((i+1)) > "$idx_file"
exit 0
'''.replace("PROMPTLOG", prompt_log).replace("TURNS", turns_path)
    with open(path, "w") as fh:
        fh.write(script)
    os.chmod(path, 0o755)
    return path


class ParkBase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.adapter = LocalAdapter(self.tmp)
        self.rec_file = os.path.join(self.tmp, "rec-file.txt")
        self.turns_path = os.path.join(self.tmp, "turns.txt")
        self.prompt_log = os.path.join(self.tmp, "prompts.txt")
        self.scripts = {"file": _record_stub(self.rec_file)}
        self.worker_bin = _worker_stub(self.turns_path, self.prompt_log)
        self.actions = Actions(repo_root=self.tmp, scripts=self.scripts,
                               worker_bin=self.worker_bin)
        self.httpd = make_server(self.adapter, host="127.0.0.1", port=0,
                                 poll_interval=0.05, actions=self.actions)
        self.port = self.httpd.server_address[1]
        self.thread = threading.Thread(target=self.httpd.serve_forever,
                                       daemon=True)
        self.thread.start()

    def tearDown(self):
        self.httpd.shutdown()
        self.httpd.server_close()

    def _post(self, path, obj=None, timeout=10):
        url = "http://127.0.0.1:%d%s" % (self.port, path)
        data = json.dumps(obj if obj is not None else {}).encode("utf-8")
        req = urllib.request.Request(url, data=data, method="POST",
                                     headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, json.loads(r.read())

    def _record(self):
        if not os.path.exists(self.rec_file):
            return ""
        with open(self.rec_file) as fh:
            return fh.read()

    def _set_turns(self, *blobs):
        with open(self.turns_path, "w") as fh:
            for i, b in enumerate(blobs):
                if i:
                    fh.write("===TURN===\n")
                fh.write(json.dumps(b) + "\n")

    def _prompts(self):
        if not os.path.exists(self.prompt_log):
            return ""
        with open(self.prompt_log) as fh:
            return fh.read()


class ParkEndpointTest(ParkBase):
    def test_park_requires_idea(self):
        with self.assertRaises(urllib.error.HTTPError) as cm:
            self._post("/api/park", {})
        self.assertEqual(cm.exception.code, 400)

    def test_park_dispatches_file_park(self):
        status, body = self._post("/api/park",
                                  {"idea": "Add a dark mode toggle"})
        self.assertEqual(status, 200)
        self.assertTrue(body["ok"])
        rec = self._record()
        self.assertIn("--park", rec)
        # the idea rides --idea <file>, and the file carries the idea text.
        self.assertIn("--idea", rec)
        self.assertIn("Add a dark mode toggle", rec)
        # NO PRD, NO estimate at park time — a --prd must never be dispatched.
        self.assertNotIn("--prd", rec)

    def test_park_threads_engine_as_flag_claude(self):
        """file.sh --park takes the engine as the --engine FLAG (do_park), not the
        LCARS_WORKER_BIN env that file_mission uses."""
        status, _ = self._post("/api/park",
                               {"idea": "Add X", "engine": "claude"})
        self.assertEqual(status, 200)
        rec = self._record()
        self.assertIn("--engine claude", rec)

    def test_park_threads_engine_as_flag_copilot(self):
        status, _ = self._post("/api/park",
                               {"idea": "Add Y", "engine": "copilot"})
        self.assertEqual(status, 200)
        self.assertIn("--engine copilot", self._record())

    def test_park_no_engine_omits_flag(self):
        status, _ = self._post("/api/park", {"idea": "Add Z"})
        self.assertEqual(status, 200)
        self.assertNotIn("--engine", self._record())


class ParkedAlignStartTest(ParkBase):
    def _done_prd(self):
        return ("# Mission: Dark mode\n\n**Type:** feature\n"
                "**Goal:** Add a dark mode toggle.\n"
                "**Acceptance Criteria:**\n- toggles theme\n"
                "**Out of Scope:**\n- none\n**Constraints:**\n- reuse tokens\n")

    def test_parked_align_start_seeds_from_idea_md(self):
        fx.plant_parked(self.tmp, "m-park", issue=200,
                        idea="Add a dark mode toggle to settings")
        self._set_turns(
            {"status": "question",
             "question": {"text": "System-follow or manual?",
                          "recommended": "manual"},
             "prd": "# Mission: Dark mode\n\n**Type:** feature\n"})
        status, body = self._post("/api/align/start", {"missionId": "m-park"})
        self.assertEqual(status, 200)
        self.assertEqual(body["state"]["status"], "question")
        # the worker prompt was seeded from the parked idea.md, not the (absent)
        # request idea.
        self.assertIn("Add a dark mode toggle to settings", self._prompts())

    def test_parked_align_done_dispatches_complete_not_fresh_file(self):
        fx.plant_parked(self.tmp, "m-park", issue=200)
        prd = self._done_prd()
        self._set_turns(
            {"status": "question",
             "question": {"text": "Scope?", "recommended": "manual"},
             "prd": "# Mission: Dark mode\n\n**Type:** feature\n"},
            {"status": "done", "prd": prd},
        )
        _, start = self._post("/api/align/start", {"missionId": "m-park"})
        sid = start["state"]["sessionId"]
        _, done = self._post("/api/align/%s/answer" % sid, {"answer": "manual"})
        self.assertEqual(done["state"]["status"], "done")
        rec = self._record()
        # file.sh --complete <id> --prd ... — grill-completion IN PLACE.
        self.assertIn("--complete m-park", rec)
        self.assertIn("--prd", rec)
        self.assertIn("Add a dark mode toggle.", rec)
        # it must NOT be a fresh filing (a bare --prd with no --complete).
        self.assertNotIn("--park", rec)

    def test_parked_align_inherits_persisted_engine(self):
        # the parked mission's persisted engine (state.json.workerBin) drives the
        # grill AND is threaded to the --complete dispatch as $LCARS_WORKER_BIN.
        # (We persist the worker STUB path as the engine so the grill runs it with
        # zero real spend — same convention as the align-endpoint suite.)
        fx.plant_parked(self.tmp, "m-park", issue=200,
                        worker_bin=self.worker_bin)
        prd = self._done_prd()
        self._set_turns({"status": "done", "prd": prd})
        # the FIRST turn already returns done → start reports done immediately.
        _, start = self._post("/api/align/start", {"missionId": "m-park"})
        self.assertEqual(start["state"]["status"], "done")
        rec = self._record()
        self.assertIn("--complete m-park", rec)
        self.assertIn("ENV_WORKER_BIN: %s" % self.worker_bin, rec)

    def test_parked_align_unknown_mission_is_404(self):
        with self.assertRaises(urllib.error.HTTPError) as cm:
            self._post("/api/align/start", {"missionId": "nope"})
        self.assertEqual(cm.exception.code, 404)

    def test_plain_align_start_unchanged_no_mission_id(self):
        """Regression: a normal (no missionId) align_start files a FRESH mission
        via --prd (never --complete)."""
        self._set_turns({"status": "done", "prd": self._done_prd()})
        _, start = self._post("/api/align/start", {"idea": "Gamify the site"})
        self.assertEqual(start["state"]["status"], "done")
        rec = self._record()
        self.assertIn("--prd", rec)
        self.assertNotIn("--complete", rec)


class ParkReadOnlyTest(unittest.TestCase):
    """View-only / github build → /api/park and the parked align-start 403; the
    board still renders (the write layer is off, actions=None)."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        fx.plant_parked(self.tmp, "m-park", issue=200)
        self.adapter = LocalAdapter(self.tmp)
        self.httpd = make_server(self.adapter, host="127.0.0.1", port=0,
                                 poll_interval=0.05, actions=None)
        self.port = self.httpd.server_address[1]
        self.thread = threading.Thread(target=self.httpd.serve_forever,
                                       daemon=True)
        self.thread.start()

    def tearDown(self):
        self.httpd.shutdown()
        self.httpd.server_close()

    def _post_403(self, path, obj):
        url = "http://127.0.0.1:%d%s" % (self.port, path)
        data = json.dumps(obj).encode("utf-8")
        req = urllib.request.Request(url, data=data, method="POST",
                                     headers={"Content-Type": "application/json"})
        with self.assertRaises(urllib.error.HTTPError) as cm:
            urllib.request.urlopen(req, timeout=5)
        self.assertEqual(cm.exception.code, 403)

    def test_park_declined_when_read_only(self):
        self._post_403("/api/park", {"idea": "Add a dark mode toggle"})

    def test_parked_align_start_declined_when_read_only(self):
        self._post_403("/api/align/start", {"missionId": "m-park"})

    def test_board_still_renders_view_only(self):
        url = "http://127.0.0.1:%d/api/board" % self.port
        with urllib.request.urlopen(url, timeout=5) as r:
            data = json.loads(r.read())
        self.assertIn("columns", data)


if __name__ == "__main__":
    unittest.main()

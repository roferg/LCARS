"""S70-B — the interactive Align grilling console + Mission-Log authoring.

The Align bridge is STATEFUL and MULTI-TURN: each turn spawns ONE cold worker
(engine = $LCARS_WORKER_BIN) feeding the EXISTING `lcars-file` Align grilling
instructions + the accumulated transcript, and returns the next question (or a
DONE+PRD). On DONE the session dispatches `file.sh --prd <tmp>` (ADR-002 —
dispatch, never reimplement Stage logic). The Mission-Log authoring half spawns
ONE worker with the `lcars-log` STEP-1 split instructions to author N bug PRDs,
returns them as a preview, then `log/run` dispatches `log.sh`/`resolve-logs`.

Every worker / skill call is env-injected and stubbable: the worker engine is a
recording stub that emits canned turns (Q1, Q2, DONE+PRD) and writes the prompt
it SAW to a file so we can assert the align instructions + idea + accumulated
transcript reached it — with ZERO real spend.

stdlib only; the daemon runs on an ephemeral localhost port inside the test.
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


def _file_record_stub(record_path):
    """A bash stub standing in for file.sh / log.sh: records argv AND, for every
    `--prd <path>` and `--adr <path>` it sees, the FILE CONTENT (so the test can
    assert the assembled PRD reached the script). Exits 0.
    """
    fd, path = tempfile.mkstemp(suffix=".sh")
    os.close(fd)
    script = r'''#!/usr/bin/env bash
{
  printf "ARGV: %s\n" "$*"
  prev=""
  for a in "$@"; do
    if [ "$prev" = "--prd" ] || [ "$prev" = "--adr" ]; then
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
    """A bash stub standing in for $LCARS_WORKER_BIN cold-worker turns.

    It is invoked once per Align turn as `<bin> -p <prompt> ...`. It APPENDS the
    prompt it saw to `prompt_log` (so the test asserts the align instructions +
    idea + accumulated transcript reached it), then pops the NEXT canned turn off
    `turns_path` (a file with one JSON blob per turn, separated by a line
    `===TURN===`) and prints it to stdout. Zero spend.
    """
    fd, path = tempfile.mkstemp(suffix=".sh")
    os.close(fd)
    script = r'''#!/usr/bin/env bash
# capture the prompt: it follows the -p flag.
prompt=""
prev=""
for a in "$@"; do
  if [ "$prev" = "-p" ]; then prompt="$a"; fi
  prev="$a"
done
{
  printf "===PROMPT===\n%s\n" "$prompt"
} >> "PROMPTLOG"
# pop the next canned turn (everything up to the next ===TURN=== marker).
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


class AlignBase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        # an existing mission so /api/board has content and ids are sane.
        fx.plant_simple(self.tmp, "m-001", stage="verify", issue=142)
        self.adapter = LocalAdapter(self.tmp)

        # worker turn script + prompt log.
        self.turns_path = os.path.join(self.tmp, "turns.txt")
        self.prompt_log = os.path.join(self.tmp, "prompts.txt")

        # recording file.sh / log.sh stubs.
        self.records = {}
        self.scripts = {}
        for key in ("file", "log", "resolve"):
            rec = os.path.join(self.tmp, "rec-%s.txt" % key)
            self.records[key] = rec
            self.scripts[key] = _file_record_stub(rec)

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

    def _set_turns(self, *blobs):
        """Write the canned worker turns (one JSON blob per turn)."""
        with open(self.turns_path, "w") as fh:
            for i, b in enumerate(blobs):
                if i:
                    fh.write("===TURN===\n")
                fh.write(json.dumps(b) + "\n")

    def _post(self, path, obj=None, timeout=10):
        url = "http://127.0.0.1:%d%s" % (self.port, path)
        data = json.dumps(obj if obj is not None else {}).encode("utf-8")
        req = urllib.request.Request(url, data=data, method="POST",
                                     headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, json.loads(r.read())

    def _prompts(self):
        if not os.path.exists(self.prompt_log):
            return ""
        with open(self.prompt_log) as fh:
            return fh.read()

    def _record(self, key):
        p = self.records[key]
        if not os.path.exists(p):
            return ""
        with open(p) as fh:
            return fh.read()


class AlignStartTest(AlignBase):
    def test_start_spawns_worker_and_returns_question(self):
        self._set_turns({
            "status": "question",
            "question": {"text": "Global or per-course leaderboard?",
                         "choices": ["Per-course", "Global"],
                         "recommended": "Per-course"},
            "prd": "# Mission: Gamification\n\n**Type:** feature\n",
        })
        status, body = self._post(
            "/api/align/start",
            {"idea": "Add XP, badges and a leaderboard"})
        self.assertEqual(status, 200)
        self.assertTrue(body["ok"])
        st = body["state"]
        self.assertIn("sessionId", st)
        self.assertEqual(st["status"], "question")
        self.assertEqual(st["question"]["text"],
                         "Global or per-course leaderboard?")
        self.assertEqual(st["question"]["recommended"], "Per-course")
        # the worker invocation went through the injectable seam AND carried the
        # existing align grilling instructions + the idea.
        prompts = self._prompts()
        self.assertIn("Add XP, badges and a leaderboard", prompts)
        # the worker prompt must carry the existing Align grilling instructions.
        self.assertTrue("align" in prompts.lower() or "grill" in prompts.lower(),
                        "worker prompt must carry the Align grilling instructions")

    def test_start_without_idea_is_400(self):
        with self.assertRaises(urllib.error.HTTPError) as cm:
            self._post("/api/align/start", {})
        self.assertEqual(cm.exception.code, 400)


class AlignAnswerTest(AlignBase):
    def test_answer_carries_transcript_then_next_question(self):
        self._set_turns(
            {"status": "question",
             "question": {"text": "Global or per-course?", "recommended": "Per-course"},
             "prd": "# Mission: G\n\n**Type:** feature\n"},
            {"status": "question",
             "question": {"text": "How is XP awarded?", "recommended": "On completion"},
             "prd": "# Mission: G\n\n**Type:** feature\n**Goal:** ...\n"},
        )
        _, start = self._post("/api/align/start", {"idea": "Gamify the site"})
        sid = start["state"]["sessionId"]
        _, ans = self._post("/api/align/%s/answer" % sid,
                            {"answer": "Per-course for now"})
        self.assertEqual(ans["state"]["status"], "question")
        self.assertEqual(ans["state"]["question"]["text"], "How is XP awarded?")
        # the SECOND worker turn must have received the accumulated transcript:
        # both the prior question AND the captain's answer.
        prompts = self._prompts()
        self.assertIn("Global or per-course?", prompts)
        self.assertIn("Per-course for now", prompts)
        # the partial PRD comes back for the live right-panel.
        self.assertIn("Goal", ans["state"]["prd"])

    def test_answer_unknown_session_is_404(self):
        with self.assertRaises(urllib.error.HTTPError) as cm:
            self._post("/api/align/no-such-session/answer", {"answer": "x"})
        self.assertEqual(cm.exception.code, 404)


class AlignDoneTest(AlignBase):
    def test_done_dispatches_file_script_with_prd(self):
        prd = ("# Mission: Gamification\n\n**Type:** feature\n"
               "**Goal:** Add XP and a leaderboard.\n"
               "**Acceptance Criteria:**\n- XP awarded\n"
               "**Out of Scope:**\n- none\n**Constraints:**\n- reuse svc\n")
        self._set_turns(
            {"status": "question",
             "question": {"text": "Scope?", "recommended": "Per-course"},
             "prd": "# Mission: Gamification\n\n**Type:** feature\n"},
            {"status": "done", "prd": prd},
        )
        _, start = self._post("/api/align/start", {"idea": "Gamify"})
        sid = start["state"]["sessionId"]
        _, done = self._post("/api/align/%s/answer" % sid,
                             {"answer": "Per-course"})
        self.assertEqual(done["state"]["status"], "done")
        # file.sh was dispatched with --prd carrying the ASSEMBLED PRD content.
        rec = self._record("file")
        self.assertIn("--prd", rec)
        self.assertIn("Add XP and a leaderboard.", rec)
        # the result hands back a fresh board so the card lands in Align.
        self.assertIn("board", done["state"])

    def test_done_with_adr_and_override_passes_both(self):
        prd = ("# Mission: Gamification\n\n**Type:** feature\n**Goal:** g\n"
               "**Acceptance Criteria:**\n- a\n**Out of Scope:**\n- n\n"
               "**Constraints:**\n- c\n")
        adr = ("# Architecture Decision Records: Gamification\n\n"
               "## ADR-001: Use existing XP service\n\n"
               "**Context:** ...\n**Decision:** ...\n"
               "**Alternatives considered:** ...\n**Consequences:** ...\n")
        self._set_turns(
            {"status": "done", "prd": prd, "adr": adr,
             "modelOverride": "all:opus"},
        )
        _, start = self._post("/api/align/start", {"idea": "Gamify deeply"})
        # the FIRST turn already returned done — start reports done immediately.
        self.assertEqual(start["state"]["status"], "done")
        rec = self._record("file")
        self.assertIn("--adr", rec)
        self.assertIn("Use existing XP service", rec)
        self.assertIn("all:opus", rec)


class LogAuthoringTest(AlignBase):
    def test_log_with_text_authors_children_via_worker(self):
        # the worker authors TWO bug PRDs to its outdir; the daemon parses them
        # into a preview WITHOUT persisting (no log.sh dispatch on preview).
        bug1 = ("# Mission: XP not awarded on video completion\n\n"
                "**Type:** bug\n**Goal:** Award XP on video complete.\n"
                "**Acceptance Criteria:**\n- xp\n**Out of Scope:**\n- n\n"
                "**Constraints:**\n- c\n")
        bug2 = ("# Mission: Leaderboard flicker on first load\n\n"
                "**Type:** bug\n**Goal:** No flicker.\n"
                "**Acceptance Criteria:**\n- ok\n**Out of Scope:**\n- n\n"
                "**Constraints:**\n- c\n")
        self._set_turns({"bugs": [bug1, bug2]})
        status, body = self._post(
            "/api/mission/m-001/log",
            {"text": "XP isn't awarded for videos. Also leaderboard flickers."})
        self.assertEqual(status, 200)
        st = body["state"]
        self.assertEqual(st["count"], 2)
        titles = sorted(c["title"] for c in st["children"])
        self.assertEqual(titles, ["Leaderboard flicker on first load",
                                  "XP not awarded on video completion"])
        # the worker carried the lcars-log split instructions + the report text.
        prompts = self._prompts()
        self.assertIn("flickers", prompts)
        self.assertTrue("bug" in prompts.lower())
        # PREVIEW must NOT persist — no log.sh dispatch yet.
        self.assertEqual(self._record("log"), "")

    def test_log_without_text_falls_back_to_linked_children(self):
        # no text → read-only preview of already-linked children, no worker.
        _plant_bug(self.tmp, "m-bug1", parent="m-001", issue=201)
        status, body = self._post("/api/mission/m-001/log", {})
        self.assertEqual(status, 200)
        self.assertEqual(body["state"]["count"], 1)
        # the worker was never spawned for the read-only fallback.
        self.assertEqual(self._prompts(), "")


class ViewOnlyAlignTest(unittest.TestCase):
    """View-only / github mode → the interactive endpoints 403; board renders."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        fx.plant_simple(self.tmp, "m-001", stage="align", issue=142)
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

    def test_align_start_declined_when_read_only(self):
        url = "http://127.0.0.1:%d/api/align/start" % self.port
        req = urllib.request.Request(
            url, data=b'{"idea":"x"}', method="POST")
        with self.assertRaises(urllib.error.HTTPError) as cm:
            urllib.request.urlopen(req, timeout=5)
        self.assertEqual(cm.exception.code, 403)

    def test_board_still_renders_view_only(self):
        url = "http://127.0.0.1:%d/api/board" % self.port
        with urllib.request.urlopen(url, timeout=5) as r:
            data = json.loads(r.read())
        self.assertIn("columns", data)


def _plant_bug(root, mid, *, parent, issue, stage="plan"):
    d = fx.mission_dir(root, mid)
    fx.write_json(os.path.join(d, "state.json"), {
        "id": mid, "type": "bug", "title": "Bug " + mid, "stage": stage,
        "created": "2026-06-14T10:00:00Z", "githubIssue": issue,
        "parentMission": parent, "linked": True,
        "branch": "lcars/%s" % mid, "base": "main",
    })


if __name__ == "__main__":
    unittest.main()

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
import base64
import glob
import http.client
import json
import os
import subprocess
import sys
import tempfile
import threading
import time
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


def _worker_stub(turns_path, prompt_log, argv_log=None):
    """A bash stub standing in for $LCARS_WORKER_BIN cold-worker turns.

    It is invoked once per Align turn as `<bin> -p <prompt> ...`. It APPENDS the
    prompt it saw to `prompt_log` (so the test asserts the align instructions +
    idea + accumulated transcript reached it). It ALSO appends the FULL argv it
    saw to `argv_log` (one line per invocation), so a test can assert the warm
    session flags (`--session-id`/`--resume` + the uuid) and count spawns. Then
    it pops the NEXT canned turn off `turns_path` (a file with one JSON blob per
    turn, separated by a line `===TURN===`) and prints it to stdout. Zero spend.
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
# record the FULL argv (one line per invocation) so tests can assert the warm
# session flags + count spawns. Each arg is space-joined; uuids/flags survive.
if [ -n "ARGVLOG" ]; then
  printf "ARGV: %s\n" "$*" >> "ARGVLOG"
fi
# pop the next canned turn (everything up to the next ===TURN=== marker).
idx_file="TURNS.idx"
i=0
[ -f "$idx_file" ] && i=$(cat "$idx_file")
awk -v want="$i" 'BEGIN{n=0} /^===TURN===$/{n++; next} {if(n==want) print}' "TURNS"
echo $((i+1)) > "$idx_file"
exit 0
'''.replace("PROMPTLOG", prompt_log).replace("TURNS", turns_path).replace(
        "ARGVLOG", argv_log or "")
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

        # worker turn script + prompt log + argv log (warm-session assertions).
        self.turns_path = os.path.join(self.tmp, "turns.txt")
        self.prompt_log = os.path.join(self.tmp, "prompts.txt")
        self.argv_log = os.path.join(self.tmp, "argv.txt")

        # recording file.sh / log.sh stubs.
        self.records = {}
        self.scripts = {}
        for key in ("file", "log", "resolve"):
            rec = os.path.join(self.tmp, "rec-%s.txt" % key)
            self.records[key] = rec
            self.scripts[key] = _file_record_stub(rec)

        self.worker_bin = _worker_stub(self.turns_path, self.prompt_log,
                                       self.argv_log)
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

    def _argvs(self):
        """The list of argv blocks the worker stub recorded — one per invocation,
        in order. Each block starts at an `ARGV: ` marker and runs until the next
        one (the recorded argv can span many lines because the prompt contains
        newlines), so a test can count spawns and inspect the trailing session
        flags (`--session-id`/`--resume` + uuid).
        """
        if not os.path.exists(self.argv_log):
            return []
        with open(self.argv_log) as fh:
            raw = fh.read()
        blocks = []
        for chunk in raw.split("ARGV: "):
            if chunk.strip():
                blocks.append(chunk.rstrip("\n"))
        return blocks

    def _prompt_turns(self):
        """The per-invocation worker prompts, split on the stub's ===PROMPT===
        marker (in order). Lets a test inspect the OPENING vs CONTINUATION
        prompts separately."""
        raw = self._prompts()
        chunks = [c for c in raw.split("===PROMPT===\n")]
        return [c.rstrip("\n") for c in chunks if c.strip()]


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
        # BUG-B: the SECOND worker turn RESUMES the warm session, so it carries
        # the captain's latest answer but does NOT re-feed the prior transcript
        # (that context already lives in the session — the re-feed is gone).
        prompts = self._prompts()
        self.assertIn("Per-course for now", prompts)
        # the partial PRD comes back for the live right-panel.
        self.assertIn("Goal", ans["state"]["prd"])

    def test_closing_flag_round_trips_to_the_question(self):
        """BUG-015: the grill's final 'anything else before I file?' check-in is
        flagged closing:true on the question turn; the daemon must pass it through
        UNCHANGED so the Align console can swap to the 'estimating & creating
        mission' loading copy when the captain answers it (the slow estimate runs
        inside that POST)."""
        self._set_turns(
            {"status": "question",
             "question": {"text": "How is XP awarded?",
                          "recommended": "On completion"},
             "prd": "# Mission: G\n\n**Type:** feature\n"},
            {"status": "question",
             "question": {"text": "Anything else before I file this?",
                          "recommended": "Go ahead", "closing": True},
             "prd": "# Mission: G\n\n**Type:** feature\n**Goal:** ...\n"},
        )
        _, start = self._post("/api/align/start", {"idea": "Gamify the site"})
        sid = start["state"]["sessionId"]
        # the opening question is a normal grill turn — not closing.
        self.assertFalse(start["state"]["question"].get("closing"))
        _, ans = self._post("/api/align/%s/answer" % sid,
                            {"answer": "On completion"})
        self.assertEqual(ans["state"]["status"], "question")
        # the closing check-in carries the flag through verbatim.
        self.assertTrue(ans["state"]["question"]["closing"])

    def test_answer_unknown_session_is_404(self):
        with self.assertRaises(urllib.error.HTTPError) as cm:
            self._post("/api/align/no-such-session/answer", {"answer": "x"})
        self.assertEqual(cm.exception.code, 404)

    def test_empty_answer_proceeds_does_not_400(self):
        """BUG-073: an EMPTY answer = 'nothing to add / accept the
        recommendation / proceed'. The endpoint must NOT 400 (require text); it
        must advance the turn, feeding the warm worker a 'proceed' signal (the
        grill already handles 'proceed'/'go ahead')."""
        self._set_turns(
            {"status": "question",
             "question": {"text": "How is XP awarded?",
                          "recommended": "On completion"},
             "prd": "# Mission: G\n\n**Type:** feature\n"},
            {"status": "question",
             "question": {"text": "Anything else before I file this?",
                          "recommended": "Go ahead", "closing": True},
             "prd": "# Mission: G\n\n**Type:** feature\n**Goal:** ...\n"},
        )
        _, start = self._post("/api/align/start", {"idea": "Gamify the site"})
        sid = start["state"]["sessionId"]
        # empty answer must be accepted and advance to the next question.
        status, ans = self._post("/api/align/%s/answer" % sid, {"answer": ""})
        self.assertEqual(status, 200)
        self.assertEqual(ans["state"]["status"], "question")
        self.assertEqual(ans["state"]["question"]["text"],
                         "Anything else before I file this?")
        # the worker turn must have carried a proceed/accept signal (not blank),
        # so the grill knows the captain had nothing to add.
        cont = self._prompt_turns()[1]
        self.assertTrue(
            "proceed" in cont.lower() or "accept" in cont.lower()
            or "nothing to add" in cont.lower(),
            "an empty answer must reach the worker as a proceed/accept signal")

    def test_missing_answer_field_proceeds(self):
        """BUG-073: a body with NO answer field at all is also 'proceed' — the
        captain hit Submit with an empty box (the client may omit the key)."""
        self._set_turns(
            {"status": "question",
             "question": {"text": "How is XP awarded?",
                          "recommended": "On completion"},
             "prd": "# Mission: G\n\n**Type:** feature\n"},
            {"status": "question",
             "question": {"text": "Anything else before I file this?",
                          "closing": True},
             "prd": "# Mission: G\n\n**Type:** feature\n**Goal:** ...\n"},
        )
        _, start = self._post("/api/align/start", {"idea": "Gamify the site"})
        sid = start["state"]["sessionId"]
        status, ans = self._post("/api/align/%s/answer" % sid, {})
        self.assertEqual(status, 200)
        self.assertEqual(ans["state"]["status"], "question")


class AlignClosingQuestionTest(AlignBase):
    """BUG-072: the final-confirm (closing) question must be a CONCISE lead-in —
    it must NOT inline the entire PRD body. The PRD already flows to the `prd`
    field (rendered in the live 'PRD · BUILDING LIVE' right panel); duplicating
    it into the question text is redundant. The daemon must strip a PRD body the
    worker inlines into the closing question so only the lead-in survives, while
    the `prd` field keeps the full PRD."""

    _FULL_PRD = ("# Mission: Gamification\n\n"
                 "**Type:** feature\n\n"
                 "**Goal:** Add XP, badges and a leaderboard.\n\n"
                 "**Acceptance Criteria:**\n- XP is awarded on completion\n"
                 "- Badges unlock at thresholds\n\n"
                 "**Out of Scope:**\n- Social sharing\n\n"
                 "**Constraints:**\n- Reuse the existing XP service\n")

    def test_closing_question_does_not_inline_full_prd_body(self):
        # the worker (mis)behaves like the bug report: it inlines the WHOLE PRD
        # into the closing question text AND also returns it in the prd field.
        bad_question = (
            "Perfect. Here's the complete PRD I'll file — anything else before "
            "I lock it?\n\n" + self._FULL_PRD)
        self._set_turns(
            {"status": "question",
             "question": {"text": "How is XP awarded?",
                          "recommended": "On completion"},
             "prd": "# Mission: Gamification\n\n**Type:** feature\n"},
            {"status": "question",
             "question": {"text": bad_question, "closing": True},
             "prd": self._FULL_PRD},
        )
        _, start = self._post("/api/align/start", {"idea": "Gamify the site"})
        sid = start["state"]["sessionId"]
        _, ans = self._post("/api/align/%s/answer" % sid,
                            {"answer": "On completion"})
        self.assertEqual(ans["state"]["status"], "question")
        qtext = ans["state"]["question"]["text"]
        # the concise lead-in survives ...
        self.assertIn("anything else", qtext.lower())
        # ... but the PRD body sections must NOT be duplicated into the question.
        self.assertNotIn("Acceptance Criteria", qtext,
                         "closing question must not inline the PRD body")
        self.assertNotIn("Out of Scope", qtext)
        self.assertNotIn("Reuse the existing XP service", qtext)
        # the full PRD still flows to the prd field (the live right panel).
        self.assertIn("Acceptance Criteria", ans["state"]["prd"])
        self.assertIn("Reuse the existing XP service", ans["state"]["prd"])

    def test_clean_closing_question_is_left_untouched(self):
        # a worker that already keeps the closing question concise must pass
        # through verbatim (the strip is a no-op when there's no inlined PRD).
        clean = ("Perfect — the complete PRD is on the right. Anything else "
                 "before I lock it?")
        self._set_turns(
            {"status": "question",
             "question": {"text": "How is XP awarded?",
                          "recommended": "On completion"},
             "prd": "# Mission: Gamification\n\n**Type:** feature\n"},
            {"status": "question",
             "question": {"text": clean, "closing": True},
             "prd": self._FULL_PRD},
        )
        _, start = self._post("/api/align/start", {"idea": "Gamify the site"})
        sid = start["state"]["sessionId"]
        _, ans = self._post("/api/align/%s/answer" % sid,
                            {"answer": "On completion"})
        self.assertEqual(ans["state"]["question"]["text"], clean)


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


import re  # noqa: E402


_UUID_RE = re.compile(
    r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")


def _session_flag(argv):
    """Return (kind, uuid) for one recorded argv line: kind in
    {"open","resume",None}. claude uses space-form (`--session-id <uuid>` /
    `--resume <uuid>`); copilot uses equals-form (`--session-id=<uuid>` etc).
    """
    toks = argv.split()
    for i, t in enumerate(toks):
        if t == "--session-id" and i + 1 < len(toks):
            return "open", toks[i + 1]
        if t == "--resume" and i + 1 < len(toks):
            return "resume", toks[i + 1]
        if t.startswith("--session-id="):
            return "open", t.split("=", 1)[1]
        if t.startswith("--resume="):
            return "resume", t.split("=", 1)[1]
    return None, None


class AlignWarmSessionTest(AlignBase):
    """BUG-B: the Align console drives ONE warm, resumable worker session — UI
    Align == CLI Align. No per-question cold respawn, no transcript re-feed."""

    def _three_question_done(self):
        self._set_turns(
            {"status": "question",
             "question": {"text": "Q1 global or per-course?", "recommended": "Per-course"},
             "prd": "# Mission: G\n\n**Type:** feature\n"},
            {"status": "question",
             "question": {"text": "Q2 how is XP awarded?", "recommended": "On completion"},
             "prd": "# Mission: G\n\n**Type:** feature\n**Goal:** ...\n"},
            {"status": "done",
             "prd": ("# Mission: G\n\n**Type:** feature\n**Goal:** g\n"
                     "**Acceptance Criteria:**\n- a\n**Out of Scope:**\n- n\n"
                     "**Constraints:**\n- c\n")},
        )

    def test_start_plus_answers_reuse_one_warm_session(self):
        self._three_question_done()
        _, start = self._post("/api/align/start", {"idea": "Gamify the site"})
        sid = start["state"]["sessionId"]
        _, a1 = self._post("/api/align/%s/answer" % sid, {"answer": "Per-course"})
        self.assertEqual(a1["state"]["status"], "question")
        _, a2 = self._post("/api/align/%s/answer" % sid, {"answer": "On completion"})
        self.assertEqual(a2["state"]["status"], "done")

        argvs = self._argvs()
        # start + 2 answers = 3 worker spawns.
        self.assertEqual(len(argvs), 3, "expected exactly 3 worker turns")
        flags = [_session_flag(a) for a in argvs]
        kinds = [k for k, _ in flags]
        uuids = [u for _, u in flags]
        # exactly ONE opening (--session-id) and TWO continuations (--resume).
        self.assertEqual(kinds, ["open", "resume", "resume"],
                         "first turn opens the session, rest resume it")
        # and they are all the SAME uuid (one warm session reused).
        self.assertTrue(uuids[0], "opening turn must carry a session uuid")
        self.assertTrue(_UUID_RE.fullmatch(uuids[0]),
                        "session uuid must be canonical (valid for both engines)")
        self.assertEqual(set(uuids), {uuids[0]},
                         "every turn must resume the SAME session uuid")

    def test_continuation_turn_does_not_refeed_transcript_or_skill(self):
        self._three_question_done()
        _, start = self._post("/api/align/start", {"idea": "Gamify the site"})
        sid = start["state"]["sessionId"]
        self._post("/api/align/%s/answer" % sid, {"answer": "Per-course pick"})

        prompts = self._prompt_turns()
        self.assertEqual(len(prompts), 2)
        opening, cont = prompts[0], prompts[1]
        # the OPENING turn carries the full grill (envelope + SKILL.md + idea).
        self.assertIn("Gamify the site", opening)
        # the CONTINUATION prompt carries the captain's answer ...
        self.assertIn("Per-course pick", cont)
        # ... but NOT the re-fed transcript / envelope / SKILL.md (the whole point).
        self.assertNotIn("=== the interview so far", cont)
        self.assertNotIn("OUTPUT CONTRACT", cont)
        from lcars_serve.actions import _load_skill, _FILE_SKILL
        skill = _load_skill(_FILE_SKILL)
        # a distinctive chunk of the SKILL.md must NOT be re-fed on continuation.
        marker = "relentless, one-question-at-a-time"
        if marker in skill:
            self.assertNotIn(marker, cont,
                             "SKILL.md must not be re-fed on resume")
        # the continuation prompt is SHORT relative to the opening (no re-feed).
        self.assertLess(len(cont), len(opening) // 2)

    def test_opening_turn_drives_skill_md_not_a_daemon_copy(self):
        # the grilling SOURCE is SKILL.md — assert its content reached turn 1.
        self._three_question_done()
        self._post("/api/align/start", {"idea": "Gamify the site"})
        opening = self._prompt_turns()[0]
        from lcars_serve.actions import _load_skill, _FILE_SKILL
        skill = _load_skill(_FILE_SKILL)
        self.assertTrue(skill.strip(), "SKILL.md must be readable")
        # a distinctive phrase from the SKILL.md grill prose must be present.
        self.assertIn("relentless, one-question-at-a-time", opening)

    def test_done_dispatches_file_with_picked_engine(self):
        self._three_question_done()
        engine = self.worker_bin  # the per-session engine.
        _, start = self._post("/api/align/start",
                              {"idea": "Gamify", "engine": engine})
        sid = start["state"]["sessionId"]
        self._post("/api/align/%s/answer" % sid, {"answer": "a1"})
        _, done = self._post("/api/align/%s/answer" % sid, {"answer": "a2"})
        self.assertEqual(done["state"]["status"], "done")
        rec = self._record("file")
        self.assertIn("--prd", rec)
        self.assertIn("**Goal:** g", rec)

    def test_cancel_reaps_the_session(self):
        self._three_question_done()
        _, start = self._post("/api/align/start", {"idea": "Gamify the site"})
        sid = start["state"]["sessionId"]
        # cancel the console.
        status, body = self._post("/api/align/%s/cancel" % sid, {})
        self.assertEqual(status, 200)
        self.assertTrue(body["ok"])
        # the sid is gone from the in-memory map (no leaked mapping).
        self.assertNotIn(sid, self.actions._align)
        # a subsequent answer to the reaped session 404s.
        with self.assertRaises(urllib.error.HTTPError) as cm:
            self._post("/api/align/%s/answer" % sid, {"answer": "late"})
        self.assertEqual(cm.exception.code, 404)


class AlignToolNoiseTest(AlignBase):
    """BUG — the grill console blanked mid-interview (DX-Scorecard, 2026-07-29).

    A copilot Align turn is supposed to be a PURE REASONING turn that prints ONE
    JSON object. On the field mission the OPENING turn did exactly that (0 tool
    calls) but the CONTINUATION turn used copilot's builtin `view` tool ten times
    — its tools-denied posture (`--available-tools=`) did not hold — so its stdout
    carried tool activity BEFORE the real turn. `_extract_json` took the FIRST
    balanced `{...}` it could parse, which was a tool ARGUMENT object
    (`{"path": "..."}`), so the daemon shipped a turn with `question == {}`:
      • the console rendered its "What would you like to refine?" fallback with an
        empty PRD panel and NO error — a dead console the captain kept typing into;
      • `sess.last_question` became `{}` (falsy), so `align_overlay` stopped
        advertising RESUME ALIGN and the mission lost its way back in.

    The daemon must read the worker's ACTUAL turn out of noisy stdout, and must
    never hand the console a question it cannot render.
    """

    def _set_raw_turns(self, *blobs):
        """Canned turns as RAW STDOUT text (not json.dumps'd), so a test can
        reproduce a turn whose stdout carries tool noise around the JSON."""
        with open(self.turns_path, "w") as fh:
            for i, b in enumerate(blobs):
                if i:
                    fh.write("===TURN===\n")
                fh.write(b.rstrip("\n") + "\n")

    # the real shape of the field failure: copilot renders each builtin tool call
    # to stdout, and its argument blob is itself a balanced, parseable JSON object.
    TOOL_NOISE = (
        '● view {"path":"fbd0bc0450062fdf63e4ec389d8cf1b3ad5d2e667ac4ef60"}\n'
        '  └ read 4491 bytes\n'
        '● view {"path":"src/data/config.json","command":"view"}\n'
        '  └ read 812 bytes\n'
    )

    def test_tool_noise_before_the_turn_does_not_blank_the_console(self):
        q1 = json.dumps({
            "status": "question",
            "question": {"text": "Nested buckets or flat metrics?",
                         "choices": ["Nested", "Flat"],
                         "recommended": "Nested"},
            "prd": "# Mission: MBR Platform\n\n**Type:** feature\n",
        })
        # turn 2: the worker reasoned WITH TOOLS, so its stdout carries tool
        # argument objects ahead of the real turn.
        turn2 = json.dumps({
            "status": "question",
            "question": {"text": "Roster-only config.json, or full shape?",
                         "choices": ["Roster-only", "Full shape"],
                         "recommended": "Roster-only"},
            "prd": "# Mission: MBR Platform\n\n**Type:** feature\n"
                   "**Goal:** the sharpened goal\n",
        })
        self._set_raw_turns(q1, self.TOOL_NOISE + turn2)

        _, start = self._post("/api/align/start", {"idea": "MBR platform"})
        sid = start["state"]["sessionId"]
        self.assertEqual(start["state"]["question"]["text"],
                         "Nested buckets or flat metrics?")

        status, body = self._post("/api/align/%s/answer" % sid,
                                  {"answer": "Nested"})
        self.assertEqual(status, 200)
        st = body["state"]
        # the REAL turn is what reaches the console — not the tool-argument blob.
        self.assertEqual(st["status"], "question")
        self.assertEqual(st["question"]["text"],
                         "Roster-only config.json, or full shape?")
        self.assertEqual(st["question"]["choices"], ["Roster-only", "Full shape"])
        # …and the live PRD panel keeps building instead of going blank.
        self.assertIn("**Goal:** the sharpened goal", st["prd"])

    def test_tool_noise_leaves_the_mission_resumable(self):
        """The mission must keep its RESUME ALIGN way back in: a turn read out of
        noisy stdout still records a CONCRETE open question, so `align_overlay`
        keeps advertising the live session (it requires a truthy last_question)."""
        q1 = json.dumps({
            "status": "question",
            "question": {"text": "Nested buckets or flat metrics?"},
            "prd": "# Mission: MBR Platform\n",
        })
        turn2 = json.dumps({
            "status": "question",
            "question": {"text": "Roster-only config.json, or full shape?"},
            "prd": "# Mission: MBR Platform\n**Goal:** sharpened\n",
        })
        self._set_raw_turns(q1, self.TOOL_NOISE + turn2)
        _, start = self._post("/api/align/start", {"idea": "MBR platform"})
        sid = start["state"]["sessionId"]
        self._post("/api/align/%s/answer" % sid, {"answer": "Nested"})
        sess = self.actions._align[sid]
        self.assertTrue(sess.last_question,
                        "a parsed turn must leave a truthy last_question so the "
                        "board keeps advertising RESUME ALIGN")
        self.assertEqual(sess.last_question.get("text"),
                         "Roster-only config.json, or full shape?")

    def test_unreadable_turn_is_an_error_not_a_blank_console(self):
        """When NO turn can be read out of the worker's stdout, the console must
        SAY so (502 → the error line + a re-armed Submit) rather than render an
        empty question with an empty PRD and leave the captain typing into a
        console that is already dead."""
        q1 = json.dumps({
            "status": "question",
            "question": {"text": "Nested buckets or flat metrics?"},
            "prd": "# Mission: MBR Platform\n",
        })
        # stdout with ONLY tool noise — the worker never printed a turn.
        self._set_raw_turns(q1, self.TOOL_NOISE)
        _, start = self._post("/api/align/start", {"idea": "MBR platform"})
        sid = start["state"]["sessionId"]
        with self.assertRaises(urllib.error.HTTPError) as cm:
            self._post("/api/align/%s/answer" % sid, {"answer": "Nested"})
        self.assertEqual(cm.exception.code, 502)

        # the session SURVIVES the bad turn at its previous question, so the
        # captain can simply answer again (and RESUME ALIGN still works).
        sess = self.actions._align[sid]
        self.assertEqual(sess.last_question.get("text"),
                         "Nested buckets or flat metrics?")
        self.assertIn("# Mission: MBR Platform", sess.prd)

    def test_turn_without_a_question_is_an_error_not_a_blank_console(self):
        """A turn that parses but carries no usable question is equally dead on
        screen — reject it at the seam instead of shipping `question: {}`."""
        q1 = json.dumps({
            "status": "question",
            "question": {"text": "Nested buckets or flat metrics?"},
            "prd": "# Mission: MBR Platform\n",
        })
        self._set_raw_turns(q1, json.dumps({"status": "question",
                                            "question": {"text": "   "}}))
        _, start = self._post("/api/align/start", {"idea": "MBR platform"})
        sid = start["state"]["sessionId"]
        with self.assertRaises(urllib.error.HTTPError) as cm:
            self._post("/api/align/%s/answer" % sid, {"answer": "Nested"})
        self.assertEqual(cm.exception.code, 502)
        # the previous question is intact — the console is answerable again.
        sess = self.actions._align[sid]
        self.assertEqual(sess.last_question.get("text"),
                         "Nested buckets or flat metrics?")

    def test_done_turn_is_still_read_out_of_noisy_stdout(self):
        """The closing turn files the mission — it must survive tool noise too,
        or the grill dies at the finish line."""
        q1 = json.dumps({
            "status": "question",
            "question": {"text": "Nested buckets or flat metrics?"},
            "prd": "# Mission: MBR Platform\n",
        })
        done = json.dumps({
            "status": "done",
            "prd": "# Mission: MBR Platform\n\n**Type:** feature\n",
        })
        self._set_raw_turns(q1, self.TOOL_NOISE + done)
        _, start = self._post("/api/align/start", {"idea": "MBR platform"})
        sid = start["state"]["sessionId"]
        status, body = self._post("/api/align/%s/answer" % sid,
                                  {"answer": "Nested"})
        self.assertEqual(status, 200)
        self.assertEqual(body["state"]["status"], "done")
        # file.sh ran with the assembled PRD.
        self.assertIn("# Mission: MBR Platform", self._record("file"))


def _copilot_worker_stub(turns_path, prompt_log, argv_log=None):
    """Same recording worker stub as `_worker_stub`, but its FILENAME contains
    "copilot" so `_session_args` selects the copilot branch (engine selection is
    by basename). Lets a test assert the copilot warm-Align flag discipline
    (`--no-ask-user --disable-builtin-mcps --no-custom-instructions`) reaches the
    invocation with ZERO real spend.
    """
    d = tempfile.mkdtemp()
    path = os.path.join(d, "copilot")
    script = r'''#!/usr/bin/env bash
prompt=""
prev=""
for a in "$@"; do
  if [ "$prev" = "-p" ]; then prompt="$a"; fi
  prev="$a"
done
{
  printf "===PROMPT===\n%s\n" "$prompt"
} >> "PROMPTLOG"
if [ -n "ARGVLOG" ]; then
  printf "ARGV: %s\n" "$*" >> "ARGVLOG"
fi
idx_file="TURNS.idx"
i=0
[ -f "$idx_file" ] && i=$(cat "$idx_file")
awk -v want="$i" 'BEGIN{n=0} /^===TURN===$/{n++; next} {if(n==want) print}' "TURNS"
echo $((i+1)) > "$idx_file"
exit 0
'''.replace("PROMPTLOG", prompt_log).replace("TURNS", turns_path).replace(
        "ARGVLOG", argv_log or "")
    with open(path, "w") as fh:
        fh.write(script)
    os.chmod(path, 0o755)
    return path


class AlignCopilotFlagsTest(AlignBase):
    """S72 — the warm-Align copilot invocation must carry the SAME MCP-discipline
    flags as the cold Stage workers (skills/lcars-run/worker-adapter.sh): copilot
    re-booting its builtin MCP servers + custom instructions on every turn halved
    throughput (26.3s → 13.1s/turn). The copilot branch of `_session_args` must
    add `--no-ask-user --disable-builtin-mcps --no-custom-instructions`; claude
    and the cold one-shot (Log) path stay UNCHANGED.

    S72 BUG-FIX — the Align grill is a PURE REASONING task (idea + SKILL.md
    envelope → JSON turn); it needs NO repo tools. With `--allow-all-tools`
    copilot used its `bash` tool to EMIT the JSON turn, so its final stdout
    message was prose-only ("Next question emitted...") and the daemon found no
    parseable JSON ⇒ "the Align worker returned no parseable turn". Denying tools
    (`--available-tools=`, one argv token whose value is empty) makes copilot emit
    the raw JSON directly. The copilot branch must DROP `--allow-all-tools` and
    ADD `--available-tools=`.
    """

    _COPILOT_FLAGS = ("--no-ask-user", "--disable-builtin-mcps",
                      "--no-custom-instructions")
    _NO_TOOLS_FLAG = "--available-tools="

    def setUp(self):
        super().setUp()
        # a copilot-named engine so _session_args takes the copilot branch.
        self.copilot_bin = _copilot_worker_stub(
            self.turns_path, self.prompt_log, self.argv_log)

    def _three_question_done(self):
        self._set_turns(
            {"status": "question",
             "question": {"text": "Q1?", "recommended": "Per-course"},
             "prd": "# Mission: G\n\n**Type:** feature\n"},
            {"status": "question",
             "question": {"text": "Q2?", "recommended": "On completion"},
             "prd": "# Mission: G\n\n**Type:** feature\n**Goal:** ...\n"},
            {"status": "done",
             "prd": ("# Mission: G\n\n**Type:** feature\n**Goal:** g\n"
                     "**Acceptance Criteria:**\n- a\n**Out of Scope:**\n- n\n"
                     "**Constraints:**\n- c\n")},
        )

    def test_copilot_opening_turn_carries_mcp_discipline_flags(self):
        self._three_question_done()
        _, start = self._post("/api/align/start",
                              {"idea": "Gamify", "engine": self.copilot_bin})
        opening = self._argvs()[0]
        toks = opening.split()
        # the opening turn opens the session AND fences the MCP machinery off,
        # AND denies tools (pure-reasoning grill ⇒ JSON emitted directly).
        self.assertNotIn("--allow-all-tools", toks,
                         "copilot Align grill must NOT grant tools — tools let "
                         "copilot emit the JSON via bash, hiding it from stdout")
        self.assertIn(self._NO_TOOLS_FLAG, toks,
                      "copilot Align grill must deny tools via %s"
                      % self._NO_TOOLS_FLAG)
        kind, uuid = _session_flag(opening)
        self.assertEqual(kind, "open")
        self.assertTrue(_UUID_RE.fullmatch(uuid))
        for flag in self._COPILOT_FLAGS:
            self.assertIn(flag, toks,
                          "copilot opening turn must carry %s" % flag)

    def test_copilot_continuation_turn_carries_mcp_discipline_flags(self):
        self._three_question_done()
        _, start = self._post("/api/align/start",
                              {"idea": "Gamify", "engine": self.copilot_bin})
        sid = start["state"]["sessionId"]
        self._post("/api/align/%s/answer" % sid, {"answer": "Per-course"})
        cont = self._argvs()[1]
        toks = cont.split()
        kind, _ = _session_flag(cont)
        self.assertEqual(kind, "resume",
                         "second turn must RESUME the warm copilot session")
        self.assertNotIn("--allow-all-tools", toks,
                         "copilot continuation must NOT grant tools either")
        self.assertIn(self._NO_TOOLS_FLAG, toks,
                      "copilot continuation must deny tools via %s"
                      % self._NO_TOOLS_FLAG)
        for flag in self._COPILOT_FLAGS:
            self.assertIn(flag, toks,
                          "copilot continuation turn must carry %s" % flag)

    def test_claude_turn_omits_copilot_only_flags(self):
        # regression guard: the claude path (default worker_bin, no "copilot" in
        # its basename) must NOT pick up the copilot MCP-discipline flags.
        self._three_question_done()
        _, start = self._post("/api/align/start", {"idea": "Gamify"})
        sid = start["state"]["sessionId"]
        self._post("/api/align/%s/answer" % sid, {"answer": "Per-course"})
        for argv in self._argvs():
            toks = argv.split()
            for flag in self._COPILOT_FLAGS + (self._NO_TOOLS_FLAG,):
                self.assertNotIn(flag, toks,
                                 "claude path must not carry %s" % flag)
            # claude already works tool-free; its warm-session argv stays the
            # pure space-form --session-id / --resume (no extra flags).
            kind, _ = _session_flag(argv)
            self.assertIn(kind, ("open", "resume"))


class AlignModelParityTest(AlignBase):
    """S78 CHANGE 3 — the Align grill must pass `--model <m>` resolved from the
    mission ENGINE, mirroring alias_for_tier's per-engine DEFAULT (copilot is
    opus-safe → claude-opus-4.8; claude → its sonnet default). Previously the
    grill ran each CLI's BARE default (no --model), so the grill was not at CLI
    parity with the pipeline. The flag is ADDITIVE (space-form for both engines);
    the S72 tools-denied / session flags stay intact.
    """

    def _three_question_done(self):
        self._set_turns(
            {"status": "question",
             "question": {"text": "Q1?", "recommended": "Per-course"},
             "prd": "# Mission: G\n\n**Type:** feature\n"},
            {"status": "done",
             "prd": ("# Mission: G\n\n**Type:** feature\n**Goal:** g\n"
                     "**Acceptance Criteria:**\n- a\n**Out of Scope:**\n- n\n"
                     "**Constraints:**\n- c\n")},
        )

    @staticmethod
    def _model_of(argv):
        toks = argv.split()
        for i, t in enumerate(toks):
            if t == "--model" and i + 1 < len(toks):
                return toks[i + 1]
        return None

    def test_copilot_align_turn_carries_opus_safe_model(self):
        self._three_question_done()
        copilot_bin = _copilot_worker_stub(
            self.turns_path, self.prompt_log, self.argv_log)
        self._post("/api/align/start",
                   {"idea": "Gamify", "engine": copilot_bin})
        opening = self._argvs()[0]
        toks = opening.split()
        self.assertEqual(self._model_of(opening), "claude-opus-4.8",
                         "copilot Align grill must run opus-safe (--model "
                         "claude-opus-4.8), mirroring alias_for_tier")
        # the S72 tools-denied flags must still be present (additive --model).
        self.assertIn("--available-tools=", toks)
        self.assertIn("--no-ask-user", toks)
        self.assertIn("--disable-builtin-mcps", toks)
        self.assertIn("--no-custom-instructions", toks)

    def test_claude_align_turn_carries_sonnet_model(self):
        self._three_question_done()
        # default worker_bin is a claude-named stub.
        self._post("/api/align/start", {"idea": "Gamify"})
        opening = self._argvs()[0]
        self.assertEqual(self._model_of(opening), "sonnet",
                         "claude Align grill must run its sonnet default "
                         "(--model sonnet)")


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

    def test_align_start_with_image_still_403_view_only(self):
        # S91: an attached image must NOT bypass the view-only write block — the
        # write layer is off (actions=None), so it 403s before any image guard.
        url = "http://127.0.0.1:%d/api/align/start" % self.port
        body = json.dumps({"idea": "x", "images": [_img()]}).encode("utf-8")
        req = urllib.request.Request(url, data=body, method="POST",
                                     headers={"Content-Type": "application/json"})
        with self.assertRaises(urllib.error.HTTPError) as cm:
            urllib.request.urlopen(req, timeout=5)
        self.assertEqual(cm.exception.code, 403)


# ── S91: pasted-image hand-off into the ONE shared _worker_turn seam ──────────
_IMG_BYTES = b"\x89PNG\r\n\x1a\n_S91_IMAGE_PAYLOAD_73294_"


def _img(data=_IMG_BYTES, ctype="image/png", name="shot.png"):
    """A {name,type,dataB64} image-paste entry (the postWrite body shape)."""
    return {"name": name, "type": ctype,
            "dataB64": base64.b64encode(data).decode("ascii")}


def _staged_imgs(root):
    """Every image the daemon has staged (lcars-img-*).

    S160 fix-loop: the scratch lives under `.git/lcars/tmp/`, NOT in the working
    tree. It used to sit in the repo root, where the base-freshness guard's
    `git status --porcelain` counted LCARS's own staging as the captain's
    untracked work and refused the fast-forward it was about to make.
    """
    return sorted(glob.glob(
        os.path.join(root, ".git", "lcars", "tmp", "lcars-img-*")))


def _tree_scratch(root):
    """Anything LCARS has left lying in the WORKING TREE. Must always be empty:
    a harness artifact in the captain's tree is dirt the guard blames on them."""
    return sorted(glob.glob(os.path.join(root, "lcars-*")))


class ImagePasteGrillTest(AlignBase):
    """S91 — an image pasted into the File/Align grill reaches the conversational
    worker through the ONE shared `_worker_turn` seam. The DEFAULT worker_bin is
    a non-copilot stub, so this exercises the CLAUDE branch: the staged abs path
    is referenced in the PROMPT text (claude views it with Read; the grill is not
    tools-denied). Bytes are staged for real; the session reaps them on done."""

    def test_claude_grill_references_staged_path_in_prompt(self):
        # a single QUESTION turn keeps the session alive (no done-reap yet) so we
        # can inspect the on-disk staged file.
        self._set_turns(
            {"status": "question",
             "question": {"text": "What's broken?", "recommended": "x"},
             "prd": "# Mission: G\n\n**Type:** bug\n"})
        status, _ = self._post("/api/align/start",
                               {"idea": "fix this", "images": [_img()]})
        self.assertEqual(status, 200)
        # exactly ONE real file staged; bytes match the input.
        staged = _staged_imgs(self.tmp)
        self.assertEqual(len(staged), 1)
        # …and it is NOT in the working tree: LCARS's own staging must never
        # read as the captain's untracked work (S160 fix-loop).
        self.assertEqual(_tree_scratch(self.tmp), [])
        with open(staged[0], "rb") as fh:
            self.assertEqual(fh.read(), _IMG_BYTES)
        # claude REFERENCES the abs path in the prompt text (Read-tool hand-off).
        prompt = self._prompt_turns()[0]
        self.assertIn(staged[0], prompt)
        self.assertIn("attached images", prompt.lower())
        # the claude path must NOT add a copilot --attachment flag.
        self.assertNotIn("--attachment", self._argvs()[0])

    def test_done_turn_threads_attach_to_file_script(self):
        # S92: an image pasted DURING the grill becomes a durable mission
        # attachment — on the done turn the session's accumulated staged images
        # are threaded to file.sh as a repeated `--attach <path>`.
        self._set_turns(
            {"status": "question",
             "question": {"text": "Q?", "recommended": "x"},
             "prd": "# Mission: G\n\n**Type:** bug\n"},
            {"status": "done",
             "prd": ("# Mission: G\n\n**Type:** bug\n**Goal:** g\n"
                     "**Acceptance Criteria:**\n- a\n**Out of Scope:**\n- n\n"
                     "**Constraints:**\n- c\n")})
        _, start = self._post("/api/align/start",
                              {"idea": "fix this", "images": [_img()]})
        sid = start["state"]["sessionId"]
        _, done = self._post("/api/align/%s/answer" % sid, {"answer": "go"})
        self.assertEqual(done["state"]["status"], "done")
        rec = self._record("file")
        self.assertIn("--prd", rec)
        self.assertIn("--attach", rec)
        self.assertIn("lcars-img-", rec)

    def test_done_turn_without_image_threads_no_attach(self):
        # Regression: a grill with no image files with NO --attach.
        self._set_turns(
            {"status": "done",
             "prd": ("# Mission: G\n\n**Type:** bug\n**Goal:** g\n"
                     "**Acceptance Criteria:**\n- a\n**Out of Scope:**\n- n\n"
                     "**Constraints:**\n- c\n")})
        self._post("/api/align/start", {"idea": "no image"})
        self.assertNotIn("--attach", self._record("file"))

    def test_done_turn_reaps_staged_images(self):
        self._set_turns(
            {"status": "question",
             "question": {"text": "Q?", "recommended": "x"},
             "prd": "# Mission: G\n\n**Type:** bug\n"},
            {"status": "done",
             "prd": ("# Mission: G\n\n**Type:** bug\n**Goal:** g\n"
                     "**Acceptance Criteria:**\n- a\n**Out of Scope:**\n- n\n"
                     "**Constraints:**\n- c\n")})
        _, start = self._post("/api/align/start",
                              {"idea": "fix this", "images": [_img()]})
        # staged + present while the grill session is open.
        self.assertEqual(len(_staged_imgs(self.tmp)), 1)
        sid = start["state"]["sessionId"]
        _, done = self._post("/api/align/%s/answer" % sid, {"answer": "go"})
        self.assertEqual(done["state"]["status"], "done")
        # the session ended → its staged images are reaped (no working-tree leak).
        self.assertEqual(_staged_imgs(self.tmp), [])

    def test_no_image_turn_is_byte_identical(self):
        # regression (test #4): a turn with NO image stages nothing, adds no
        # --attachment flag, and leaves the prompt text untouched.
        self._set_turns(
            {"status": "question",
             "question": {"text": "Q?", "recommended": "x"},
             "prd": "# Mission: G\n\n**Type:** bug\n"})
        self._post("/api/align/start", {"idea": "no image here"})
        self.assertEqual(_staged_imgs(self.tmp), [])
        prompt = self._prompt_turns()[0]
        self.assertNotIn("attached images", prompt.lower())
        self.assertNotIn("--attachment", self._argvs()[0])


class ImagePasteCopilotGrillTest(AlignBase):
    """S91 — the COPILOT branch: the image rides natively via `--attachment
    <path>` (repeatable), tools stay denied (`--available-tools=`), and the
    prompt text is NOT augmented (no Read-tool note)."""

    def setUp(self):
        super().setUp()
        self.copilot_bin = _copilot_worker_stub(
            self.turns_path, self.prompt_log, self.argv_log)

    def test_copilot_grill_attaches_image_via_flag(self):
        self._set_turns(
            {"status": "question",
             "question": {"text": "Q?", "recommended": "x"},
             "prd": "# Mission: G\n\n**Type:** bug\n"})
        status, _ = self._post(
            "/api/align/start",
            {"idea": "fix this", "engine": self.copilot_bin, "images": [_img()]})
        self.assertEqual(status, 200)
        staged = _staged_imgs(self.tmp)
        self.assertEqual(len(staged), 1)
        toks = self._argvs()[0].split()
        # native --attachment <staged path>; tools-denied posture intact.
        self.assertIn("--attachment", toks)
        i = toks.index("--attachment")
        self.assertEqual(toks[i + 1], staged[0])
        self.assertIn("--available-tools=", toks)
        # copilot prompt is NOT augmented with the claude path-in-prompt note.
        self.assertNotIn("attached images", self._prompt_turns()[0].lower())


class ImagePasteLogTest(AlignBase):
    """S91 — the Mission-Log split runs through the SAME seam on the cold
    (session_id=None) path; a pasted image reaches it and is cleaned up after the
    one-shot turn (no session to read it across)."""

    def test_log_split_references_staged_path_and_cleans_up(self):
        bug = ("# Mission: Crash on load\n\n**Type:** bug\n**Goal:** g\n"
               "**Acceptance Criteria:**\n- a\n**Out of Scope:**\n- n\n"
               "**Constraints:**\n- c\n")
        self._set_turns({"bugs": [bug]})
        status, body = self._post(
            "/api/mission/m-001/log",
            {"text": "it crashes — see the screenshot", "images": [_img()]})
        self.assertEqual(status, 200)
        self.assertEqual(body["state"]["count"], 1)
        # the staged path reached the claude log-split PROMPT ...
        prompt = self._prompts()
        self.assertRegex(prompt, r"lcars-img-\S+",
                         "log-split prompt must reference the staged image path")
        self.assertIn("attached images", prompt.lower())
        # ... and the cold one-shot turn cleaned the staged file up (no leak).
        self.assertEqual(_staged_imgs(self.tmp), [])


class ImageGuardTest(AlignBase):
    """S91 — the daemon guards: an oversize body 413s before it is read; a
    non-image content-type 415s before the worker; neither reaches the worker."""

    def test_oversize_body_is_413_and_worker_untouched(self):
        # spoof a large Content-Length (rejected on the header, before the body
        # is read) — no need to actually ship 12 MB+ over the socket.
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        conn.putrequest("POST", "/api/align/start")
        conn.putheader("Content-Type", "application/json")
        conn.putheader("Content-Length", str(13 * 1024 * 1024))
        conn.endheaders()
        conn.send(b'{"idea":"x"}')
        resp = conn.getresponse()
        resp.read()
        conn.close()
        self.assertEqual(resp.status, 413)
        # the worker was never spawned, nothing staged.
        self.assertEqual(self._argvs(), [])
        self.assertEqual(_staged_imgs(self.tmp), [])

    def test_bad_content_type_is_415_and_worker_untouched(self):
        with self.assertRaises(urllib.error.HTTPError) as cm:
            self._post("/api/align/start",
                       {"idea": "x",
                        "images": [_img(ctype="image/svg+xml", name="x.svg")]})
        self.assertEqual(cm.exception.code, 415)
        # rejected before the worker; nothing spawned, nothing staged.
        self.assertEqual(self._argvs(), [])
        self.assertEqual(_staged_imgs(self.tmp), [])

    def test_bad_content_type_on_log_is_415(self):
        with self.assertRaises(urllib.error.HTTPError) as cm:
            self._post("/api/mission/m-001/log",
                       {"text": "bug", "images": [_img(ctype="text/plain")]})
        self.assertEqual(cm.exception.code, 415)
        self.assertEqual(self._argvs(), [])


class AlignResumeTest(AlignBase):
    """Park & Align (F2 — resume mid-grill): GET /api/align/<sid> restores a
    backgrounded grill at its current open question (choices included), and the
    board overlay stamps `alignResume` onto the parked mission's card so RESUME
    survives a page reload. In-memory only (dies with the daemon)."""

    def _get(self, path, timeout=10):
        url = "http://127.0.0.1:%d%s" % (self.port, path)
        with urllib.request.urlopen(url, timeout=timeout) as r:
            return r.status, json.loads(r.read())

    def _two_questions(self):
        self._set_turns(
            {"status": "question",
             "question": {"text": "Q1 global or per-course?",
                          "choices": ["Per-course", "Global"],
                          "recommended": "Per-course"},
             "prd": "# Mission: G\n\n**Type:** feature\n"},
            {"status": "question",
             "question": {"text": "Q2 how is XP awarded?",
                          "choices": ["On completion", "Per action"],
                          "recommended": "On completion"},
             "prd": "# Mission: G\n\n**Type:** feature\n**Goal:** ...\n"},
        )

    def test_align_state_returns_stored_last_question_and_prd(self):
        self._two_questions()
        _, start = self._post("/api/align/start", {"idea": "Gamify the site"})
        sid = start["state"]["sessionId"]
        # advance one turn so the OPEN question is Q2 (with its choices).
        self._post("/api/align/%s/answer" % sid, {"answer": "Per-course"})
        status, state = self._get("/api/align/%s" % sid)
        self.assertEqual(status, 200)
        self.assertEqual(state["status"], "question")
        # the FULL question comes back — text + choices, so resume restores buttons.
        self.assertEqual(state["question"]["text"], "Q2 how is XP awarded?")
        self.assertEqual(state["question"]["choices"],
                         ["On completion", "Per action"])
        self.assertIn("Goal", state["prd"])  # the live partial PRD.
        # GET is a READ — it must NOT reap the session (a later answer still works).
        self.assertIn(sid, self.actions._align)

    def test_align_state_unknown_sid_is_404(self):
        with self.assertRaises(urllib.error.HTTPError) as cm:
            self._get("/api/align/no-such-session")
        self.assertEqual(cm.exception.code, 404)

    def test_actions_align_state_direct_unknown_sid_raises(self):
        from lcars_serve.actions import ActionError
        with self.assertRaises(ActionError) as cm:
            self.actions.align_state("nope")
        self.assertEqual(cm.exception.status, 404)

    def _live_session(self, mission_id="m-001"):
        """A resumable session — one with a concrete open question stored."""
        from lcars_serve.actions import _AlignSession
        sess = _AlignSession(idea="x", engine=None, mission_id=mission_id)
        sess.last_question = {"text": "Q1?", "choices": ["a", "b"]}
        return sess

    def test_align_overlay_stamps_resume_on_parked_card(self):
        sid = "sess-xyz"
        self.actions._align[sid] = self._live_session("m-001")
        board = {"columns": {"align": [{"id": "m-001"}, {"id": "m-002"}]}}
        out = self.actions.align_overlay(board)
        self.assertEqual(out["columns"]["align"][0].get("alignResume"),
                         {"sid": sid})
        # the OTHER card (no live session) is untouched.
        self.assertNotIn("alignResume", out["columns"]["align"][1])

    def test_align_overlay_no_sessions_is_byte_identical(self):
        board = {"columns": {"align": [{"id": "m-001"}]}}
        before = json.dumps(board, sort_keys=True)
        out = self.actions.align_overlay(board)
        self.assertEqual(json.dumps(out, sort_keys=True), before,
                         "no live sessions → the board is returned unchanged")

    def test_align_overlay_skips_done_session(self):
        from lcars_serve.actions import _AlignSession
        sess = _AlignSession(idea="x", engine=None, mission_id="m-001")
        sess.done = True
        self.actions._align["done-sid"] = sess
        board = {"columns": {"align": [{"id": "m-001"}]}}
        out = self.actions.align_overlay(board)
        self.assertNotIn("alignResume", out["columns"]["align"][0],
                         "a done session must not stamp a resume flag")

    def test_align_overlay_skips_session_with_no_question_yet(self):
        # A freshly-created session (opening turn still in flight, last_question None)
        # is NOT advertised as resumable — else RESUME reopens an empty console.
        from lcars_serve.actions import _AlignSession
        self.actions._align["fresh"] = _AlignSession(
            idea="x", engine=None, mission_id="m-001")  # no last_question
        board = {"columns": {"align": [{"id": "m-001"}]}}
        out = self.actions.align_overlay(board)
        self.assertNotIn("alignResume", out["columns"]["align"][0],
                         "a session with no open question yet must not offer RESUME")
        self.assertIsNone(self.actions.align_session_sid("m-001"))

    def test_board_endpoint_carries_align_overlay(self):
        # end-to-end: a live parked session shows up on GET /api/board.
        self.actions._align["live-1"] = self._live_session("m-001")
        _, board = self._get("/api/board")
        cards = []
        for col in board.get("columns", {}).values():
            cards.extend(col)
        m1 = [c for c in cards if c.get("id") == "m-001"]
        self.assertTrue(m1, "m-001 must be on the board")
        self.assertEqual(m1[0].get("alignResume"), {"sid": "live-1"})

    def test_align_overlay_mission_stamps_single_detail(self):
        self.actions._align["sess-d"] = self._live_session("m-001")
        out = self.actions.align_overlay_mission({"id": "m-001"})
        self.assertEqual(out.get("alignResume"), {"sid": "sess-d"})
        # a mission with no live session is returned unchanged.
        self.assertNotIn("alignResume",
                         self.actions.align_overlay_mission({"id": "m-999"}))

    def test_mission_detail_endpoint_carries_align_overlay(self):
        # The captain's bug: the CARD showed RESUME but the DETAIL modal didn't,
        # because /api/mission/<id> never ran through the overlay. Now it does.
        self.actions._align["live-d"] = self._live_session("m-001")
        _, detail = self._get("/api/mission/m-001")
        self.assertEqual(detail.get("id"), "m-001")
        self.assertEqual(detail.get("alignResume"), {"sid": "live-d"},
                         "the detail payload must mirror the board's alignResume "
                         "so the DETAIL modal shows RESUME ALIGN")

    def test_mission_detail_endpoint_no_session_has_no_resume(self):
        _, detail = self._get("/api/mission/m-001")
        self.assertNotIn("alignResume", detail,
                         "no live session → the detail payload is unchanged")


# ════════════════════════════════════════════════════════════════════════════
# S128 / FL-009 (the RELOAD half) — THE DAEMON PUBLISHES THE IN-FLIGHT TURN
#
# The client half of FL-009 is done: the START ALIGNMENT guard's lifetime is the
# request's lifetime, released by the /api/align/start POST settling rather than
# by a 60s clock. But that guard is CLIENT MEMORY. Reload the board mid-scan and
# it is gone, and the card re-arms to START ALIGNMENT on a turn that is still
# running — the same lie FL-009 is about, through a different door, and a
# re-click still spawns a second real worker.
#
# `alignResume` cannot close it: it is deliberately withheld until a question
# exists, so for exactly the duration of the OPENING turn nothing is published.
#
# The cure follows f667ce8's in-flight-fact discipline (`busy`/`busySince`/
# `busyFor` on the holodeck shape): the DAEMON owns "a turn is running" and the
# surface reads it. `_AlignSession.turn_started` is stamped around the worker
# call and `align_overlay` / `align_overlay_mission` publish `alignBusy`.
# ════════════════════════════════════════════════════════════════════════════
class AlignInFlightOverlayTest(AlignBase):
    """The `alignBusy` fact: what publishes it, and — the honesty half — what
    stops publishing it."""

    def _scanning(self, mission_id="m-001", ago=95.0):
        """A session whose OPENING turn is in flight: no question yet, a start."""
        from lcars_serve.actions import _AlignSession
        sess = _AlignSession(idea="x", engine=None, mission_id=mission_id)
        sess.turn_started = time.time() - ago
        return sess

    def _board(self, *ids):
        return {"columns": {"align": [{"id": i} for i in ids]}}

    def test_overlay_publishes_the_in_flight_turn(self):
        self.actions._align["sess-run"] = self._scanning()
        out = self.actions.align_overlay(self._board("m-001", "m-002"))
        busy = out["columns"]["align"][0].get("alignBusy")
        self.assertIsInstance(busy, dict,
                              "a reloaded card must be able to read the in-flight "
                              "turn off the board shape — client memory is gone")
        self.assertGreaterEqual(busy["for"], 95,
                                "the elapsed seconds are the daemon's, not a "
                                "client's guess about when it clicked")
        self.assertAlmostEqual(busy["since"], time.time() - 95, delta=5)
        # the OTHER card has no session at all.
        self.assertNotIn("alignBusy", out["columns"]["align"][1])
        # and the opening turn still has no question, so RESUME is still withheld.
        self.assertNotIn("alignResume", out["columns"]["align"][0])

    def test_a_turn_that_is_over_publishes_nothing(self):
        # THE HONESTY BOUNDARY. `turn_started` is None the moment the worker call
        # settles, so a turn that DIED stops reading as "still scanning" and the
        # card honestly re-arms to START ALIGNMENT — there really is nothing
        # running. A fact that could never be cleared would be a worse lie than
        # the one it replaced.
        sess = self._scanning()
        sess.turn_started = None
        self.actions._align["sess-dead"] = sess
        out = self.actions.align_overlay(self._board("m-001"))
        self.assertNotIn("alignBusy", out["columns"]["align"][0])

    def test_a_landed_question_hands_over_to_resume(self):
        # Once a question exists the card has something better to say (RESUME
        # ALIGN), and a continuation turn running under it must not steal that
        # affordance away. `alignBusy` is the OPENING turn's fact only.
        sess = self._scanning()
        sess.last_question = {"text": "Q1?"}
        self.actions._align["sess-q"] = sess
        out = self.actions.align_overlay(self._board("m-001"))
        card = out["columns"]["align"][0]
        self.assertNotIn("alignBusy", card)
        self.assertEqual(card.get("alignResume"), {"sid": "sess-q"})

    def test_a_done_session_publishes_nothing(self):
        sess = self._scanning()
        sess.done = True
        self.actions._align["sess-done"] = sess
        out = self.actions.align_overlay(self._board("m-001"))
        self.assertNotIn("alignBusy", out["columns"]["align"][0])

    def test_an_idle_board_is_byte_identical(self):
        # ADDITIVE BY CONSTRUCTION, exactly as `_busy_fields` is: the key is
        # ABSENT when idle, so every board every earlier test pins is unmoved.
        board = self._board("m-001")
        before = json.dumps(board, sort_keys=True)
        out = self.actions.align_overlay(board)
        self.assertEqual(json.dumps(out, sort_keys=True), before)

    def test_mission_detail_mirrors_the_in_flight_fact(self):
        self.actions._align["sess-d"] = self._scanning()
        out = self.actions.align_overlay_mission({"id": "m-001"})
        self.assertIsInstance(out.get("alignBusy"), dict,
                              "the DETAIL modal must mirror the card (the "
                              "align_overlay_mission lesson)")
        self.assertNotIn("alignBusy",
                         self.actions.align_overlay_mission({"id": "m-999"}))

    def test_board_endpoint_carries_it(self):
        self.actions._align["live-b"] = self._scanning()
        url = "http://127.0.0.1:%d/api/board" % self.port
        with urllib.request.urlopen(url, timeout=10) as r:
            board = json.loads(r.read())
        cards = []
        for col in board.get("columns", {}).values():
            cards.extend(col)
        m1 = [c for c in cards if c.get("id") == "m-001"]
        self.assertTrue(m1, "m-001 must be on the board")
        self.assertIsInstance(m1[0].get("alignBusy"), dict,
                              "a freshly-loaded tab reads the in-flight turn "
                              "straight off GET /api/board")

    # ── what OWNS the fact: the worker call itself ─────────────────────────
    def _observe(self, mission_id="m-001"):
        return self.actions.align_overlay(
            self._board(mission_id))["columns"]["align"][0].get("alignBusy")

    def test_the_worker_call_is_what_sets_and_clears_the_fact(self):
        from lcars_serve.actions import _AlignSession
        sess = _AlignSession(idea="x", engine=None, mission_id="m-001")
        self.actions._align["s"] = sess
        seen = {}

        def fake_turn(*a, **kw):
            seen["during"] = self._observe()
            return json.dumps({"status": "question",
                               "question": {"text": "Q1?"}, "prd": ""})

        self.actions._worker_turn = fake_turn
        self.actions._align_turn("s", sess)
        self.assertIsInstance(seen["during"], dict,
                              "WHILE the worker turn runs, the fact is published")
        self.assertIsNone(self._observe(),
                          "…and the turn settling is what withdraws it")

    def test_a_turn_that_dies_stops_reading_as_scanning(self):
        # The dead-daemon-adjacent case, daemon-side: an engine that blows up
        # mid-turn must not leave a card insisting it is still scanning forever.
        from lcars_serve.actions import _AlignSession
        sess = _AlignSession(idea="x", engine=None, mission_id="m-001")
        self.actions._align["s"] = sess

        def boom(*a, **kw):
            raise RuntimeError("the engine died mid-turn")

        self.actions._worker_turn = boom
        with self.assertRaises(RuntimeError):
            self.actions._align_turn("s", sess)
        self.assertIsNone(self._observe(),
                          "a turn that died is NOT a turn still in flight")


# ════════════════════════════════════════════════════════════════════════════
# S169 (FL-017) — FINALIZING & COSTING WAS FL-009 WITH A FIVE-MINUTE FUSE
#
# The closing answer POST does not end at the worker call: it then runs the cold
# cost estimator and `file.sh --complete <id>` IN PLACE, which is minutes.
# `turn_started` is scoped to the worker call only, so nothing was published for
# that whole window — and `board.js` filled the silence with
# `FINALIZING_TIMEOUT_MS = 300000`, a client-side guess that on expiry cleared
# its own band and re-armed the card. A run that was still going, presented as
# one that had stopped, with a real second worker waiting behind the re-click.
# The captain hit it live on the S128 drive ("OK the mission is costing after
# the grill"). FL-009's ruling applies verbatim: *"do NOT just raise the number.
# A bigger constant is the same guess with a longer fuse."*
#
# So the daemon owns this fact too, on exactly `alignBusy`'s discipline: stamped
# around the dispatch, withdrawn in its `finally`, published additively, with NO
# copy of the client's wording.
# ════════════════════════════════════════════════════════════════════════════
class AlignFinalizingOverlayTest(AlignBase):
    def _board(self, *ids):
        return {"columns": {"align": [{"id": i} for i in ids]}}

    def _finalizing(self, mission_id="m-001", ago=210.0):
        """A session in the window the client used to guess at: the grill is
        DONE, the worker call is over, and the file.sh dispatch is running."""
        from lcars_serve.actions import _AlignSession
        sess = _AlignSession(idea="x", engine=None, mission_id=mission_id)
        sess.done = True
        sess.finalize_started = time.time() - ago
        return sess

    def test_overlay_publishes_the_in_flight_finalize(self):
        self.actions._align["s-fin"] = self._finalizing()
        out = self.actions.align_overlay(self._board("m-001", "m-002"))
        fin = out["columns"]["align"][0].get("alignFinalizing")
        self.assertIsInstance(fin, dict,
                              "a reloaded card must read the running finalize "
                              "off the board shape — client memory is gone")
        self.assertGreaterEqual(fin["for"], 210)
        self.assertAlmostEqual(fin["since"], time.time() - 210, delta=5)
        self.assertNotIn("alignFinalizing", out["columns"]["align"][1])

    def test_it_cannot_collide_with_scanning_or_resume(self):
        """One card, one true state. A finalizing session is `done` and its
        worker call is over, so `alignBusy` and `alignResume` are structurally
        silent — asserted rather than assumed."""
        self.actions._align["s-fin"] = self._finalizing()
        card = self.actions.align_overlay(self._board("m-001"))["columns"]["align"][0]
        self.assertIn("alignFinalizing", card)
        self.assertNotIn("alignBusy", card)
        self.assertNotIn("alignResume", card)

    def test_an_idle_board_is_byte_identical(self):
        board = self._board("m-001")
        before = json.dumps(board, sort_keys=True)
        out = self.actions.align_overlay(board)
        self.assertEqual(json.dumps(out, sort_keys=True), before)

    def test_mission_detail_mirrors_it(self):
        self.actions._align["s-fin"] = self._finalizing()
        out = self.actions.align_overlay_mission({"id": "m-001"})
        self.assertIsInstance(out.get("alignFinalizing"), dict)
        self.assertNotIn("alignResume", out)
        self.assertNotIn("alignFinalizing",
                         self.actions.align_overlay_mission({"id": "m-999"}))

    def test_board_endpoint_carries_it(self):
        self.actions._align["live-f"] = self._finalizing()
        url = "http://127.0.0.1:%d/api/board" % self.port
        with urllib.request.urlopen(url, timeout=10) as r:
            board = json.loads(r.read())
        cards = []
        for col in board.get("columns", {}).values():
            cards.extend(col)
        m1 = [c for c in cards if c.get("id") == "m-001"]
        self.assertTrue(m1)
        self.assertIsInstance(m1[0].get("alignFinalizing"), dict)

    # ── what OWNS the fact: the dispatch itself, released by an EVENT ───────
    def _observe(self, mission_id="m-001"):
        return self.actions.align_overlay(
            self._board(mission_id))["columns"]["align"][0].get("alignFinalizing")

    def _done_turn(self):
        return json.dumps({"status": "done",
                           "prd": "# Mission: x\n\n**Type:** feature\n"})

    def test_the_dispatch_is_what_sets_and_clears_the_fact(self):
        """THE WHOLE CURE, in one test. No clock decides this: the fact exists
        for exactly as long as `file.sh` is running, and the dispatch RETURNING
        is what withdraws it."""
        from lcars_serve.actions import _AlignSession
        sess = _AlignSession(idea="x", engine=None, mission_id="m-001")
        self.actions._align["s"] = sess
        seen = {}
        self.actions._worker_turn = lambda *a, **kw: self._done_turn()

        def fake_complete(*a, **kw):
            seen["during"] = self._observe()
            return {"columns": {}}

        self.actions._complete_from_align = fake_complete
        self.actions._align_turn("s", sess)
        self.assertIsInstance(seen["during"], dict,
                              "WHILE file.sh runs, the fact is published")
        self.assertGreaterEqual(seen["during"]["for"], 0)
        self.assertIsNone(self._observe(),
                          "…and the dispatch settling is what withdraws it")

    def test_a_finalize_that_DIES_stops_reading_as_finalizing(self):
        """The honesty boundary, and the reason the `finally` is not optional.
        A fact that could never be cleared is a worse lie than the timer was."""
        from lcars_serve.actions import _AlignSession
        sess = _AlignSession(idea="x", engine=None, mission_id="m-001")
        self.actions._align["s"] = sess
        self.actions._worker_turn = lambda *a, **kw: self._done_turn()

        def boom(*a, **kw):
            raise RuntimeError("the estimator died")

        self.actions._complete_from_align = boom
        with self.assertRaises(RuntimeError):
            self.actions._align_turn("s", sess)
        self.assertIsNone(self._observe())

    def test_a_daemon_with_no_sessions_publishes_nothing(self):
        """THE SAFETY NET, and it is a FACT rather than a timer's opinion. The
        sessions are in-memory by contract, so a daemon restarted mid-finalize
        has none — the card reads parked and clickable again, which is the
        honest answer because that dispatch is gone with the process."""
        self.actions._align.clear()
        self.assertIsNone(self._observe())


# ════════════════════════════════════════════════════════════════════════════
# S127 BLOCKER — A PARKED MISSION'S NON-IMAGE ATTACHMENTS ARE NOT IMAGES
#
# The holodeck hand-off parks a mission whose DURABLE attachments are an HTML
# mockup and a markdown concept doc. `align_start` seeded EVERY durable
# attachment into the opening grill turn, and that seam is the IMAGE road —
# copilot's `--attachment`. Measured on copilot CLI 1.0.79-4:
#
#   --attachment file type not supported (must be an image or native document):
#   …/attachment-01.html
#
# so the opening turn died on spawn and a holodeck-born mission could not be
# aligned at all. The correct reasoning was already in `align_start`, in the
# grill-first holodeck branch, which deliberately keeps its files OUT of the
# per-turn argv and puts the brief in the idea TEXT. It was applied to one road
# and not the other.
#
# The mockup and the concept doc still reach the cold stages by absolute path
# through `attachments_extra_block` (skills/lcars-run/run.sh) — the road that
# was actually proven for them. Nothing about state.json or attachments/ moves.
# ════════════════════════════════════════════════════════════════════════════
class ParkedSeedIsImagesOnlyTest(AlignBase):
    QUESTION = {"status": "question",
                "question": {"text": "Which screens?", "recommended": "both"},
                "prd": "# Mission: Tile picker\n\n**Type:** feature\n"}

    def _plant(self, mid, rels):
        """A parked mission whose durable attachments really exist on disk —
        `_parked_attachment_paths` skips anything that is not a file, so a
        fixture that only writes state.json proves nothing."""
        d = fx.plant_parked(self.tmp, mid, issue=201, attachments=rels)
        for rel in rels:
            ap = os.path.join(d, rel)
            os.makedirs(os.path.dirname(ap), exist_ok=True)
            with open(ap, "wb") as fh:
                fh.write(b"x")
        return d

    def _copilot(self):
        return _copilot_worker_stub(self.turns_path, self.prompt_log,
                                    self.argv_log)

    # ── copilot: the road that actually died ────────────────────────────────
    def test_a_mockup_and_a_concept_doc_never_reach_the_attachment_argv(self):
        self._plant("m-holo", ["attachments/attachment-01.html",
                               "attachments/attachment-02.md"])
        self._set_turns(self.QUESTION)
        status, body = self._post("/api/align/start",
                                  {"missionId": "m-holo",
                                   "engine": self._copilot()})
        self.assertEqual(status, 200)
        self.assertEqual(body["state"]["status"], "question")
        argv = self._argvs()[0]
        # NB the argv holds the whole `-p <prompt>`, and the Align prompt names
        # plenty of its own `.md` files (SKILL.md, prd.md) — so the assertion is
        # about the ATTACHMENT flag and these two files by name, not about the
        # substring ".md" appearing anywhere in a 20KB argv.
        self.assertNotIn("--attachment", argv, argv[-500:])
        self.assertNotIn("attachment-01.html", argv)
        self.assertNotIn("attachment-02.md", argv)

    def test_an_all_image_parked_mission_is_UNCHANGED(self):
        d = self._plant("m-shots", ["attachments/attachment-01.png",
                                    "attachments/attachment-02.jpg"])
        self._set_turns(self.QUESTION)
        status, _ = self._post("/api/align/start",
                               {"missionId": "m-shots",
                                "engine": self._copilot()})
        self.assertEqual(status, 200)
        toks = self._argvs()[0].split()
        want = [os.path.join(d, "attachments/attachment-01.png"),
                os.path.join(d, "attachments/attachment-02.jpg")]
        got = [toks[i + 1] for i, t in enumerate(toks) if t == "--attachment"]
        self.assertEqual(got, want, toks)

    def test_a_mixed_mission_seeds_the_screenshot_and_skips_the_mockup(self):
        d = self._plant("m-mixed", ["attachments/attachment-01.png",
                                    "attachments/attachment-02.html",
                                    "attachments/attachment-03.md"])
        self._set_turns(self.QUESTION)
        status, _ = self._post("/api/align/start",
                               {"missionId": "m-mixed",
                                "engine": self._copilot()})
        self.assertEqual(status, 200)
        toks = self._argvs()[0].split()
        got = [toks[i + 1] for i, t in enumerate(toks) if t == "--attachment"]
        self.assertEqual(got,
                         [os.path.join(d, "attachments/attachment-01.png")],
                         toks)

    # ── claude: a different mechanism, the same lie ─────────────────────────
    def test_the_claude_prompt_never_calls_a_mockup_an_attached_image(self):
        """Claude takes images as ABS PATHS listed under "attached images" in
        the prompt. Listing an HTML mockup there does not fail on spawn — it
        does something worse: it tells the grill a design document is a
        screenshot, and points it at the very file the holodeck branch
        deliberately keeps out of the conversation."""
        self._plant("m-holo", ["attachments/attachment-01.html",
                               "attachments/attachment-02.md"])
        self._set_turns(self.QUESTION)
        status, _ = self._post("/api/align/start", {"missionId": "m-holo"})
        self.assertEqual(status, 200)
        prompt = self._prompt_turns()[0]
        self.assertNotIn("attached images", prompt.lower(), prompt[-400:])
        self.assertNotIn("attachment-01.html", prompt)
        self.assertNotIn("attachment-02.md", prompt)

    def test_the_claude_prompt_still_lists_a_parked_SCREENSHOT(self):
        d = self._plant("m-shots", ["attachments/attachment-01.png"])
        self._set_turns(self.QUESTION)
        status, _ = self._post("/api/align/start", {"missionId": "m-shots"})
        self.assertEqual(status, 200)
        prompt = self._prompt_turns()[0]
        self.assertIn("attached images", prompt.lower())
        self.assertIn(os.path.join(d, "attachments/attachment-01.png"), prompt)

    # ── the durable record is untouched ─────────────────────────────────────
    def test_the_mission_still_RECORDS_every_attachment_it_was_parked_with(self):
        """The filter is about the per-turn argv ONLY. `state.json` and the
        attachments/ dir stay complete — they are how the mockup reaches the
        cold stages (`attachments_extra_block`), which is the road that was
        proven for it."""
        self._plant("m-mixed", ["attachments/attachment-01.png",
                                "attachments/attachment-02.html"])
        self._set_turns(self.QUESTION)
        self._post("/api/align/start", {"missionId": "m-mixed"})
        rels = self.actions._parked_attachment_paths("m-mixed")
        self.assertEqual([os.path.basename(p) for p in rels],
                         ["attachment-01.png", "attachment-02.html"])


class ImagePathPredicateTest(unittest.TestCase):
    """The predicate reads BOTH halves of the ONE existing table
    (`_IMAGE_SUFFIX`: allow-listed content type → staged suffix). No second list
    of extensions — a second mechanism beside an existing one is what cost S125
    two fix rounds and killed S126's tool-trace stripper."""

    def test_every_staged_suffix_the_daemon_itself_writes_is_an_image(self):
        from lcars_serve.actions import _IMAGE_SUFFIX, _is_image_path
        for suffix in set(_IMAGE_SUFFIX.values()):
            self.assertTrue(_is_image_path("/x/shot" + suffix), suffix)

    def test_a_jpeg_a_captain_attached_from_the_cli_is_still_an_image(self):
        """`.jpeg` is never a suffix LCARS writes (it stages `.jpg`), but it is
        a real screenshot a captain can `--attach`, and its content type is on
        the same allow-list. Dropping it would be a new bug in the cure."""
        from lcars_serve.actions import _is_image_path
        self.assertTrue(_is_image_path("/x/shot.JPEG"))

    def test_the_holodeck_hand_offs_own_file_types_are_not(self):
        from lcars_serve.actions import _is_image_path
        for name in ("mockup.html", "concept.md", "notes.txt", "a"):
            self.assertFalse(_is_image_path("/x/" + name), name)


# ════════════════════════════════════════════════════════════════════════════
# S128 · FL-010, THE FIFTH HOME OF "ATTACHED IMAGES"
#
# The sibling batch cured four copies of this lie in `skills/` and consolidated
# them into ONE shared bash rule (`lcars_attach_kind` / `lcars_attach_heading`,
# skills/lcars-init/lcars-common.sh). The scan that guards those four only
# covers `skills/`, so it cannot see the fifth: the daemon's own interactive
# Align turn, which builds the claude prompt's path list under a heading that
# says "images" whatever actually rides.
#
# Different literal, different mechanism, same lie — and this one is on the
# holodeck's hand-off path, the FIRST thing that reads a program's mockup. (The
# copilot branch passes `--attachment` per file and spells no noun at all, so it
# is unaffected and is asserted unchanged below.)
# ════════════════════════════════════════════════════════════════════════════
class ClaudePromptNamesWhatRidesTest(AlignBase):
    COMMON = os.path.join(
        os.path.dirname(os.path.dirname(os.path.dirname(
            os.path.abspath(__file__)))),
        "skills", "lcars-init", "lcars-common.sh")

    def _turn(self, paths, engine=None):
        """Drive the ONE seam directly. The endpoint road filters non-images out
        before they get here (the S127 blocker fix), so the endpoint cannot
        produce the input this wording is wrong for — the seam can."""
        self._set_turns({"status": "question",
                         "question": {"text": "Q?", "recommended": "x"},
                         "prd": "# Mission: G\n\n**Type:** bug\n"})
        self.actions._worker_turn("SOME PROMPT",
                                  engine=engine or self.worker_bin,
                                  image_paths=paths)
        return self._prompts()

    def test_a_mockup_is_never_announced_as_an_attached_image(self):
        prompt = self._turn(["/tmp/a/attachment-01.html"])
        self.assertNotIn("attached images", prompt.lower(), prompt[-400:])
        self.assertIn("attached files", prompt.lower())
        self.assertIn("/tmp/a/attachment-01.html", prompt)

    def test_one_mockup_among_screenshots_still_demotes_the_noun(self):
        prompt = self._turn(["/tmp/a/attachment-01.png",
                             "/tmp/a/attachment-02.html"])
        self.assertNotIn("attached images", prompt.lower(), prompt[-400:])
        self.assertIn("attached files", prompt.lower())

    def test_an_all_screenshot_turn_still_says_images(self):
        prompt = self._turn(["/tmp/a/attachment-01.png",
                             "/tmp/a/attachment-02.jpg"])
        self.assertIn("attached images", prompt.lower())

    def test_a_turn_with_no_attachments_says_nothing_at_all(self):
        prompt = self._turn([])
        self.assertNotIn("attached", prompt.lower())

    def test_the_copilot_branch_still_spells_no_noun(self):
        copilot = _copilot_worker_stub(self.turns_path, self.prompt_log,
                                       self.argv_log)
        prompt = self._turn(["/tmp/a/attachment-01.html"], engine=copilot)
        self.assertNotIn("attached", prompt.lower())
        self.assertIn("--attachment", self._argvs()[0])

    def _bash_heading(self, paths):
        proc = subprocess.run(
            ["bash", "-c", '. "$1"; lcars_attach_heading "${@:2}"', "_",
             self.COMMON] + list(paths),
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        out = (proc.stdout or b"").decode().strip().lower()
        self.assertIn(out, ("## attached images", "## attached files"), out)
        return out[3:]

    # THE FILE TYPES BOTH SURFACES REALLY MEET: what LCARS itself stages
    # (`_IMAGE_SUFFIX`) and what a holodeck hand-off parks (mockup + concept).
    SHARED = [["/x/a.png"], ["/x/a.jpg", "/x/b.jpeg"], ["/x/a.html"],
              ["/x/a.png", "/x/b.html"], ["/x/a.md"], ["/x/a.png", "/x/b.md"],
              ["/x/a.gif", "/x/b.webp"], ["/x/a.HTML"], ["/x/a.PNG"],
              ["/x/a"], ["/x/a.txt", "/x/b.png"], ["/x/a.htm"]]
    # Where they DO differ, on purpose: bash calls `.svg`/`.bmp`/`.heic` images;
    # the daemon's image road is the narrower allow-list of what it can actually
    # stage and pass, so it calls them files. That direction is the safe one and
    # the assertion below pins it.
    DIVERGENT = [["/x/a.svg"], ["/x/a.bmp"], ["/x/a.heic"]]

    def test_the_daemon_and_the_shipped_bash_rule_agree_on_every_shared_case(self):
        """THE DRIFT CATCHER. Two surfaces classify the same files: this daemon,
        and `lcars_attach_heading` in the skills. They are written in different
        languages, neither imports the other, and they can absolutely drift —
        so the agreement is MEASURED against the shipped bash on every file type
        the hand-off actually carries, not asserted in a comment."""
        from lcars_serve.actions import _attach_heading
        self.assertTrue(os.path.isfile(self.COMMON), self.COMMON)
        for paths in self.SHARED:
            self.assertEqual(_attach_heading(paths), self._bash_heading(paths),
                             paths)

    def test_where_they_differ_the_daemon_is_the_stricter_one(self):
        """The guarantee that survives drift: the daemon may call something a
        FILE that bash calls an image, and never the other way round. The lie
        FL-010 is about only has one direction."""
        from lcars_serve.actions import _attach_heading
        for paths in self.SHARED + self.DIVERGENT:
            if self._bash_heading(paths) == "attached files":
                self.assertEqual(_attach_heading(paths), "attached files", paths)


def _plant_bug(root, mid, *, parent, issue, stage="plan"):
    d = fx.mission_dir(root, mid)
    fx.write_json(os.path.join(d, "state.json"), {
        "id": mid, "type": "bug", "title": "Bug " + mid, "stage": stage,
        "created": "2026-06-14T10:00:00Z", "githubIssue": issue,
        "parentMission": parent, "linked": True,
        "branch": "lcars/%s" % mid, "base": "main",
    })



# ════════════════════════════════════════════════════════════════════════════
# S178 LIVE BLOCKER — A GATE THAT FIRES MUST NOT BE A DEAD END
#
# MEASURED on the captain's own repo (mission lcars-20260829-002, issue 177):
# he parked a mission, answered ten grill questions through the viewscreen's
# Align console, and on the closing turn the console dispatched
# `file.sh --complete`, which REFUSED the PRD — correctly: it had dropped 5 of
# the design brief's 14 open questions, and those questions are what the Plan
# Stage reads. The gate's judgement was right. Everything after it was wrong:
#
#   • the drafted PRD was written to a TEMP path and unlinked in a `finally`
#     that runs on failure too, so the only copy died in daemon memory. The
#     live mission dir held idea.md, state.json, attachments/ and NO PRD.
#   • `sess.done` was set BEFORE the dispatch and only cleared by the pop that
#     the raise skipped, so the session survived STRANDED: `align_session_sid`
#     requires `not sess.done`, the card lost ▹ RESUME ALIGN and offered START
#     ALIGNMENT — re-grilling him from question 1. (Card 177 had no
#     `alignResume`; card 176, which did not fail, did.)
#   • nothing tried to fix the PRD. The captain did not write it — a worker did
#     — and he was left with no move at all.
#
# The standing rule is that every gate SELF-HEALS first and the human is the
# backstop. So: the draft is persisted, a failed finalize leaves the grill
# resumable, and a REDRAFTABLE refusal is handed back to the warm Align worker
# for up to two repair turns. The classifier is the EXIT STATUS (file.sh exits 3
# for "the PRD itself is wrong", 1 for everything else) and never the wording —
# S165's ruling, because prose drifts and a message-matcher is the road that
# loses.
# ════════════════════════════════════════════════════════════════════════════
_GATE_MSG = ("lcars file: PRD drops 5 of the design brief's 14 open question(s) "
             "from its 'Open questions from the design session' section. "
             "Missing: - Which model should the MBR builder use?")
_ENV_MSG = "lcars file: gh: could not authenticate — run `gh auth login`."

_EXIT_PLAN_STUB = r"""#!/usr/bin/env bash
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
idx_file="PLAN.idx"
i=0
[ -f "$idx_file" ] && i=$(cat "$idx_file")
echo $((i+1)) > "$idx_file"
line="$(awk -v want="$i" 'NR==want+1{print}' "PLAN" 2>/dev/null)"
code="${line%% *}"
[ -n "$code" ] || code=0
if [ "$code" != "0" ]; then
  printf '%b\n' "${line#* }" >&2
  exit "$code"
fi
exit 0
"""


def _file_exit_plan_stub(record_path, plan_path):
    """file.sh, with a SCRIPTED exit code per invocation.

    `plan_path` holds one `<code> <message>` line per call, consumed in order
    (a missing/blank line means a clean exit 0). Records the same ARGV/FILE
    blocks `_file_record_stub` does, so a test can read back the PRD each
    dispatch actually carried — which is how the healed PRD is proven to be a
    DIFFERENT document, not the same one re-sent.
    """
    fd, path = tempfile.mkstemp(suffix=".sh")
    os.close(fd)
    script = _EXIT_PLAN_STUB.replace("REC", record_path).replace("PLAN",
                                                                 plan_path)
    with open(path, "w") as fh:
        fh.write(script)
    os.chmod(path, 0o755)
    return path


class AlignFinalizeHealTest(AlignBase):
    MID = "m-parked"

    QUESTION = {"status": "question",
                "question": {"text": "Anything else before I file?",
                             "closing": True},
                "prd": "# Mission: MBR builder\n\n**Type:** feature\n"}
    BAD_PRD = "# Mission: MBR builder\n\n**Type:** feature\n\nDROPS THE QUESTIONS\n"
    GOOD_PRD = ("# Mission: MBR builder\n\n**Type:** feature\n\n"
                "## Open questions from the design session\n"
                "- STILL OPEN: Which model should the MBR builder use?\n")

    def setUp(self):
        super().setUp()
        fx.plant_parked(self.tmp, self.MID, issue=177,
                        title="Rebuild the MBR builder")
        self.plan_path = os.path.join(self.tmp, "file-exit-plan.txt")
        self.scripts["file"] = _file_exit_plan_stub(self.records["file"],
                                                    self.plan_path)
        self.actions.scripts["file"] = self.scripts["file"]

    # ── helpers ────────────────────────────────────────────────────────────
    def _plan(self, *lines):
        with open(self.plan_path, "w") as fh:
            for ln in lines:
                fh.write(ln + "\n")

    def _done(self, prd):
        return {"status": "done", "prd": prd}

    def _drive_to_close(self):
        """Start the parked grill and land on its closing question."""
        status, body = self._post("/api/align/start", {"missionId": self.MID})
        self.assertEqual(status, 200)
        return body["state"]["sessionId"]

    def _dispatch_count(self):
        return self._record("file").count("ARGV: ")

    def _dispatched_prds(self):
        """The PRD text of every `--prd` file.sh was actually handed, in order."""
        out = []
        for chunk in self._record("file").split("FILE[--prd]:\n")[1:]:
            out.append(chunk.split("\nENDFILE\n")[0])
        return out

    def _draft_path(self):
        return os.path.join(self.tmp, ".git", "lcars", "missions", self.MID,
                            "prd-draft.md")

    def _card(self):
        url = "http://127.0.0.1:%d/api/board" % self.port
        with urllib.request.urlopen(url, timeout=10) as r:
            board = json.loads(r.read())
        for col in board.get("columns", {}).values():
            for c in col:
                if c.get("id") == self.MID:
                    return c
        self.fail("no card for %s on the board" % self.MID)

    def _answer(self, sid):
        return self._post("/api/align/%s/answer" % sid, {"answer": "go"})

    # ── CURE 3: a REDRAFTABLE refusal is healed, once ──────────────────────
    def test_an_exit_3_is_healed_by_one_repair_turn_and_then_files(self):
        self._set_turns(self.QUESTION, self._done(self.BAD_PRD),
                        self._done(self.GOOD_PRD))
        self._plan("3 " + _GATE_MSG, "0")
        sid = self._drive_to_close()
        status, body = self._answer(sid)
        self.assertEqual(status, 200)
        self.assertEqual(body["state"]["status"], "done")
        # TWO dispatches: the refused one, then the healed one.
        self.assertEqual(self._dispatch_count(), 2, self._record("file"))
        self.assertEqual([t.strip() for t in self._dispatched_prds()],
                         [self.BAD_PRD.strip(), self.GOOD_PRD.strip()])
        # exactly ONE repair turn on the WARM session (opening + closing + heal).
        self.assertEqual(len(self._argvs()), 3, self._argvs())
        self.assertIn("--resume", self._argvs()[2])

    def test_the_repair_turn_hands_the_gates_own_message_to_the_worker(self):
        """The worker is told WHAT was refused — verbatim. Nothing else in the
        daemon knows which questions were dropped; only the gate does."""
        self._set_turns(self.QUESTION, self._done(self.BAD_PRD),
                        self._done(self.GOOD_PRD))
        self._plan("3 " + _GATE_MSG, "0")
        self._answer(self._drive_to_close())
        repair = self._prompt_turns()[2]
        self.assertIn("Which model should the MBR builder use?", repair)
        self.assertIn("Open questions from the design session", repair)

    def test_the_repair_turn_carries_EVERY_missing_question_verbatim(self):
        """CURE 6 — SURGICAL, because the refusal already is. The gate prints
        `Missing:` followed by every question it wants, one per line; the tail
        of that list is precisely what went missing the first time, so a
        summary ("you dropped 5 of 14") would hand the worker back the same
        recall test that lost them."""
        missing = ["Q ten: does a locked value stay locked next month?",
                   "Q eleven: what sorts the KPI list by default?",
                   "Q twelve: is there an undo for Lock in value?",
                   "Q thirteen: does the sidebar collapse on narrow screens?",
                   "Q fourteen: what does the amber state on a tile mean?"]
        gate = ("lcars file: PRD drops 5 of the design brief's 14 open "
                "question(s) from its 'Open questions from the design "
                "session' section. Missing:\\n"
                + "\\n".join("  - " + q for q in missing))
        self._set_turns(self.QUESTION, self._done(self.BAD_PRD),
                        self._done(self.GOOD_PRD))
        self._plan("3 " + gate, "0")
        status, _b = self._answer(self._drive_to_close())
        self.assertEqual(status, 200)
        repair = self._prompt_turns()[2]
        for q in missing:
            self.assertIn(q, repair, q)
        self.assertIn("- STILL OPEN: <the question>", repair)
        self.assertIn("Missing:", repair)

    def test_a_healed_filing_settles_the_session_exactly_like_a_clean_one(self):
        self._set_turns(self.QUESTION, self._done(self.BAD_PRD),
                        self._done(self.GOOD_PRD))
        self._plan("3 " + _GATE_MSG, "0")
        sid = self._drive_to_close()
        self._answer(sid)
        self.assertNotIn(sid, self.actions._align, "the session must be popped")
        self.assertFalse(os.path.exists(self._draft_path()),
                         "a filing that SUCCEEDED leaves no draft behind")

    # ── CURE 3: the cap, and what the captain is left holding ──────────────
    def test_two_failures_exhaust_the_cap_and_leave_it_resumable(self):
        self._set_turns(self.QUESTION, self._done(self.BAD_PRD),
                        self._done(self.BAD_PRD), self._done(self.BAD_PRD))
        self._plan("3 " + _GATE_MSG, "3 " + _GATE_MSG, "3 " + _GATE_MSG)
        sid = self._drive_to_close()
        with self.assertRaises(urllib.error.HTTPError) as cm:
            self._answer(sid)
        detail = cm.exception.read().decode()
        # THREE dispatches — the original plus the two heals, and no more.
        self.assertEqual(self._dispatch_count(), 3, self._record("file"))
        # the gate's own message reaches the console: he sees WHAT is unresolved.
        self.assertIn("Which model should the MBR builder use?", detail)
        # …and the grill is still his to resume.
        sess = self.actions._align.get(sid)
        self.assertIsNotNone(sess, "the session must survive a failed finalize")
        self.assertFalse(sess.done, "…and must not be stranded done=True")
        self.assertTrue(sess.last_question,
                        "…with the closing question intact, so RESUME lands "
                        "him exactly where he was")
        self.assertEqual(self.actions.align_session_sid(self.MID), sid)
        self.assertIn("alignResume", self._card())
        self.assertNotIn("alignFinalizing", self._card())

    def test_the_drafted_prd_survives_on_disk(self):
        """CURE 1. The captain did not write this PRD and cannot retype it."""
        self._set_turns(self.QUESTION, self._done(self.BAD_PRD),
                        self._done(self.BAD_PRD), self._done(self.BAD_PRD))
        self._plan("3 " + _GATE_MSG, "3 " + _GATE_MSG, "3 " + _GATE_MSG)
        with self.assertRaises(urllib.error.HTTPError):
            self._answer(self._drive_to_close())
        self.assertTrue(os.path.exists(self._draft_path()), self._draft_path())
        with open(self._draft_path(), encoding="utf-8") as fh:
            self.assertIn("DROPS THE QUESTIONS", fh.read())

    def test_the_exhaustion_message_says_where_the_draft_is(self):
        self._set_turns(self.QUESTION, self._done(self.BAD_PRD),
                        self._done(self.BAD_PRD), self._done(self.BAD_PRD))
        self._plan("3 " + _GATE_MSG, "3 " + _GATE_MSG, "3 " + _GATE_MSG)
        with self.assertRaises(urllib.error.HTTPError) as cm:
            self._answer(self._drive_to_close())
        self.assertIn("prd-draft.md", cm.exception.read().decode())

    # ── the EXIT STATUS is the classifier, not the wording ─────────────────
    def test_an_environment_failure_triggers_NO_repair_turn(self):
        """Exit 1 is `gh` being down, a missing mission, a dead git. Redrafting
        the PRD cannot clear any of those — retrying just burns tokens."""
        self._set_turns(self.QUESTION, self._done(self.BAD_PRD),
                        self._done(self.GOOD_PRD))
        self._plan("1 " + _ENV_MSG)
        sid = self._drive_to_close()
        with self.assertRaises(urllib.error.HTTPError) as cm:
            self._answer(sid)
        self.assertIn("could not authenticate", cm.exception.read().decode())
        self.assertEqual(self._dispatch_count(), 1)
        self.assertEqual(len(self._argvs()), 2,
                         "no repair turn may run for an environment failure")

    def test_an_environment_failure_still_leaves_it_resumable_with_the_draft(self):
        """CUREs 1 and 2 are NOT conditional on the heal — they are what makes
        ANY failed finalize survivable."""
        self._set_turns(self.QUESTION, self._done(self.BAD_PRD))
        self._plan("1 " + _ENV_MSG)
        sid = self._drive_to_close()
        with self.assertRaises(urllib.error.HTTPError):
            self._answer(sid)
        sess = self.actions._align.get(sid)
        self.assertIsNotNone(sess)
        self.assertFalse(sess.done)
        self.assertIn("alignResume", self._card())
        self.assertTrue(os.path.exists(self._draft_path()))

    # ── the heal is VISIBLE, on the surface that already exists ────────────
    def test_a_running_heal_shows_on_the_finalizing_surface(self):
        """Not a new band, not a new gate: the SAME `alignFinalizing` fact the
        card already renders, carrying how many repairs have been tried."""
        self._set_turns(self.QUESTION, self._done(self.BAD_PRD),
                        self._done(self.GOOD_PRD))
        self._plan("3 " + _GATE_MSG, "0")
        sid = self._drive_to_close()
        seen = {}
        real = self.actions._worker_turn

        def spy(prompt, *a, **kw):
            if "REFUSED" in prompt:
                seen["fin"] = self.actions._align_finalizing_for_mission(self.MID)
            return real(prompt, *a, **kw)

        self.actions._worker_turn = spy
        self._answer(sid)
        self.assertIn("fin", seen, "the repair turn never ran")
        self.assertGreaterEqual(seen["fin"].get("heals", 0), 1,
                                "a heal in flight must be readable off the card")

    def test_an_ordinary_finalize_publishes_no_heal_count(self):
        """Additive by construction: a filing with nothing to heal is
        byte-identical to the board every earlier test pins."""
        from lcars_serve.actions import _AlignSession
        sess = _AlignSession(idea="x", engine=None, mission_id=self.MID)
        sess.done = True
        sess.finalize_started = time.time()
        self.actions._align["s-fin"] = sess
        self.assertNotIn("heals",
                         self.actions._align_finalizing_for_mission(self.MID))

    # ── a CLEAN filing is untouched ────────────────────────────────────────
    def test_a_clean_filing_is_unchanged(self):
        self._set_turns(self.QUESTION, self._done(self.GOOD_PRD))
        self._plan("0")
        sid = self._drive_to_close()
        status, body = self._answer(sid)
        self.assertEqual(status, 200)
        self.assertEqual(body["state"]["status"], "done")
        self.assertIn("board", body["state"])
        self.assertEqual(self._dispatch_count(), 1)
        self.assertEqual(len(self._argvs()), 2, "no extra worker turn")
        self.assertNotIn(sid, self.actions._align)
        self.assertFalse(os.path.exists(self._draft_path()))
        self.assertNotIn("healed", body["state"])

    def test_a_clean_filing_leaves_no_scratch_prd_behind(self):
        """The temp PRD is still cleaned up on the SUCCESS path — the change is
        that a FAILURE stops destroying it, not that we started leaking."""
        self._set_turns(self.QUESTION, self._done(self.GOOD_PRD))
        self._plan("0")
        self._answer(self._drive_to_close())
        scratch = os.path.join(self.tmp, ".git", "lcars", "tmp")
        left = glob.glob(os.path.join(scratch, "lcars-prd-*.md"))
        self.assertEqual(left, [], left)


class AlignFreshFilingDraftTest(AlignBase):
    """The FRESH-FILING lane (`file.sh --prd`) has no mission dir to write a
    draft into — file.sh is what MINTS the mission. So the best it can do is
    STOP DESTROYING the temp PRD: on failure the scratch file under
    `.git/lcars/tmp/` survives instead of being unlinked, and the refusal names
    it. It is recoverable by path, not by mission id."""

    BAD_PRD = "# Mission: Fresh\n\n**Type:** feature\n\nDROPS THE QUESTIONS\n"

    def setUp(self):
        super().setUp()
        self.plan_path = os.path.join(self.tmp, "file-exit-plan.txt")
        self.scripts["file"] = _file_exit_plan_stub(self.records["file"],
                                                    self.plan_path)
        self.actions.scripts["file"] = self.scripts["file"]

    def _plan(self, *lines):
        with open(self.plan_path, "w") as fh:
            for ln in lines:
                fh.write(ln + "\n")

    def _scratch_prds(self):
        return sorted(glob.glob(os.path.join(
            self.tmp, ".git", "lcars", "tmp", "lcars-prd-*.md")))

    def test_a_failed_fresh_filing_keeps_the_prd_in_scratch(self):
        self._set_turns({"status": "question",
                         "question": {"text": "Anything else?"},
                         "prd": self.BAD_PRD},
                        {"status": "done", "prd": self.BAD_PRD},
                        {"status": "done", "prd": self.BAD_PRD},
                        {"status": "done", "prd": self.BAD_PRD})
        self._plan("3 " + _GATE_MSG, "3 " + _GATE_MSG, "3 " + _GATE_MSG)
        _, body = self._post("/api/align/start", {"idea": "a fresh idea"})
        sid = body["state"]["sessionId"]
        with self.assertRaises(urllib.error.HTTPError) as cm:
            self._post("/api/align/%s/answer" % sid, {"answer": "go"})
        detail = cm.exception.read().decode()
        left = self._scratch_prds()
        self.assertEqual(len(left), 1,
                         "ONE surviving draft — the newest — not one per heal")
        with open(left[0], encoding="utf-8") as fh:
            self.assertIn("DROPS THE QUESTIONS", fh.read())
        self.assertIn(left[0], detail,
                      "the refusal must name where the draft survived")
        sess = self.actions._align.get(sid)
        self.assertIsNotNone(sess)
        self.assertFalse(sess.done)

    def test_a_clean_fresh_filing_still_cleans_up(self):
        self._set_turns({"status": "question",
                         "question": {"text": "Anything else?"},
                         "prd": self.BAD_PRD},
                        {"status": "done", "prd": self.BAD_PRD})
        self._plan("0")
        _, body = self._post("/api/align/start", {"idea": "a fresh idea"})
        sid = body["state"]["sessionId"]
        status, _out = self._post("/api/align/%s/answer" % sid, {"answer": "go"})
        self.assertEqual(status, 200)
        self.assertEqual(self._scratch_prds(), [])
        self.assertNotIn(sid, self.actions._align)


class SkillExitCodeIsCarriedTest(AlignBase):
    """`_run` must hand the caller the skill's OWN exit code. Without it the
    daemon can only classify a refusal by matching its prose, which is the
    road S165 already proved loses."""

    def _stub(self, code, msg):
        fd, path = tempfile.mkstemp(suffix=".sh")
        os.close(fd)
        with open(path, "w") as fh:
            fh.write("#!/usr/bin/env bash\necho %r >&2\nexit %d\n" % (msg, code))
        os.chmod(path, 0o755)
        return path

    def test_the_exit_code_reaches_the_caller(self):
        from lcars_serve.actions import ActionError
        self.actions.scripts["file"] = self._stub(3, "bad prd")
        with self.assertRaises(ActionError) as cm:
            self.actions._run("file", ["--prd", "/x"])
        self.assertEqual(cm.exception.skill_exit, 3)
        # …and the existing contract is untouched.
        self.assertEqual(cm.exception.status, 502)
        self.assertIn("exited 3", cm.exception.message)

    def test_an_ordinary_failure_still_reads_1(self):
        from lcars_serve.actions import ActionError
        self.actions.scripts["file"] = self._stub(1, "gh is down")
        with self.assertRaises(ActionError) as cm:
            self.actions._run("file", ["--prd", "/x"])
        self.assertEqual(cm.exception.skill_exit, 1)

    def test_an_untouched_action_error_reads_none(self):
        from lcars_serve.actions import ActionError
        self.assertIsNone(ActionError(400, "x").skill_exit)



# ════════════════════════════════════════════════════════════════════════════
# S178 CURES 4 + 5 — WHY THE WORKER DROPPED THE 5 QUESTIONS
#
# Cures 1–3 are the net under the failure. These two are the failure's cause,
# and they are PROMPT PROSE, so what follows can only prove the brief now SAYS
# the right thing. It cannot prove a worker stops dropping the tail — that is a
# live drive against the captain's real 14-question brief, and it is stated as
# unproven rather than implied by a green suite.
#
# CAUSE 1 (cure 4). `_HANDOFF_IMPLIED_NOTE` ended "answer them, correct them,
# or delete them" — read verbatim by the Align worker out of the filed idea.md,
# directly above bucket 2's items — while `lcars_prd_questions_gate` refuses a
# PRD that drops any of them. The brief authorised the one move the gate treats
# as fatal.
#
# CAUSE 2 (cure 5). The 5 lost items were 10–14: the contiguous TAIL of the
# 14-item list, not a section and not a category. The mitigation is a COUNT the
# worker can check itself against, over both homes, taken through the same read
# the gate uses.
# ════════════════════════════════════════════════════════════════════════════

# The captain's real doc shape: 2 in `## Open questions`, 12 in bucket 2.
_CONCEPT_2_PLUS_12 = """# MBR builder

## Open questions

- What makes a KPI "carried" from one month to the
  next when the source sheet changes?
- Which model should the MBR builder use?

## WHAT IT MUST DO — BEHAVIOUR ONLY

### 1. Requirements (captain's words)

1. (T1) Render the builder screen.
2. (T2) Save a draft.

### 2. Implied by the mockup, not yet settled

- What do Preview and View actually do?
- Does the Lock in value button commit immediately?
- Is the KPI list scrollable or paged?
- What happens to a KPI with no source row?
- Does the header show the month or the quarter?
- Can two people edit the same MBR at once?
- Is the export PDF or XLSX?
- Does a locked value stay locked next month?
- What sorts the KPI list by default?
- Is there an undo for Lock in value?
- Does the sidebar collapse on narrow screens?
- What does the amber state on a tile mean?

### 3. Out of scope

- Redesigning the login screen
"""

_CONCEPT_NO_IMPLIED = """# Tile picker

## Open questions

- Should the picker remember the last tile?

## WHAT IT MUST DO — BEHAVIOUR ONLY

### 1. Requirements (captain's words)

1. (T1) Show the tiles.

### 3. Out of scope

- The login screen
"""

_CONCEPT_NOTHING_UNSETTLED = """# Quiet program

## WHAT IT MUST DO — BEHAVIOUR ONLY

### 1. Requirements (captain's words)

1. (T1) Show the tiles.

### 3. Out of scope

- The login screen
"""


class HandoffImpliedNoteTest(unittest.TestCase):
    """CURE 4 — the brief may no longer authorise the deletion the gate
    forbids. Prose assertions: they pin what the worker READS, not what it
    does."""

    def test_the_note_no_longer_offers_deletion(self):
        from lcars_serve.actions import _HANDOFF_IMPLIED_NOTE
        low = _HANDOFF_IMPLIED_NOTE.lower()
        self.assertNotIn("or delete them", low)
        self.assertIn("do not delete", low)

    def test_the_note_says_where_every_item_must_END_UP(self):
        """A prohibition on its own leaves the worker nowhere to put the item.
        The note has to name the destination the gate actually measures."""
        from lcars_serve.actions import _HANDOFF_IMPLIED_NOTE
        self.assertIn("Open questions from the design session",
                      _HANDOFF_IMPLIED_NOTE)
        self.assertIn("STILL OPEN", _HANDOFF_IMPLIED_NOTE)
        self.assertIn("RESOLVED with the captain", _HANDOFF_IMPLIED_NOTE)

    def test_the_destination_it_names_is_the_gates_own_heading(self):
        """THE DRIFT CATCHER. The section this note sends items to is spelled
        in the shipped bash as `LCARS_PRD_QUESTIONS_HEADING`. Two homes, two
        languages — pin them together or they drift."""
        common = os.path.join(
            os.path.dirname(os.path.dirname(os.path.dirname(
                os.path.abspath(__file__)))),
            "skills", "lcars-init", "lcars-common.sh")
        proc = subprocess.run(
            ["bash", "-c",
             '. "$1"; printf %s "$LCARS_PRD_QUESTIONS_HEADING"', "_", common],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        heading = proc.stdout.decode().strip()
        self.assertTrue(heading, "could not read the heading out of the skill")
        from lcars_serve.actions import _HANDOFF_IMPLIED_NOTE
        self.assertIn(heading, _HANDOFF_IMPLIED_NOTE)

    def test_the_NOT_YOUR_WORDS_framing_is_untouched(self):
        """FL-011's whole point, and it was NOT the bug. Bucket 2 stays marked
        and stays its own bucket."""
        from lcars_serve.actions import (_HANDOFF_IMPLIED_NOTE,
                                         _HANDOFF_IMPLIED_TITLE)
        self.assertEqual(_HANDOFF_IMPLIED_TITLE,
                         "## Implied by the mockup — NOT things you said")
        self.assertIn("never as your words", _HANDOFF_IMPLIED_NOTE)
        self.assertIn("IMPLIED", _HANDOFF_IMPLIED_NOTE)

    def test_a_brief_with_NO_implied_items_is_byte_identical(self):
        """The note has exactly one entry point — `_handoff_section`, which
        returns "" for an empty bucket. So a program whose design session
        implied nothing gets a brief this change cannot have touched, pinned
        here as a whole string rather than asserted in a comment."""
        from lcars_serve.actions import (_handoff_brief, _handoff_section,
                                         _handoff_titled, _HANDOFF_CHANGE_TITLE,
                                         _HANDOFF_CHANGE_NOTE,
                                         _HANDOFF_SCOPE_TITLE,
                                         _HANDOFF_SCOPE_NOTE,
                                         _HANDOFF_IMPLIED_TITLE,
                                         _HANDOFF_IMPLIED_NOTE)
        brief = _handoff_brief(_CONCEPT_NO_IMPLIED, "the picker",
                               ["The rail moves left"], [])
        expected = _handoff_titled("\n\n".join([
            _handoff_section(_HANDOFF_CHANGE_TITLE, _HANDOFF_CHANGE_NOTE,
                             ["The rail moves left"]),
            _handoff_section(_HANDOFF_SCOPE_TITLE, _HANDOFF_SCOPE_NOTE,
                             ["The login screen"])]), "the picker")
        self.assertEqual(brief, expected)
        self.assertNotIn(_HANDOFF_IMPLIED_TITLE, brief)
        self.assertNotIn(_HANDOFF_IMPLIED_NOTE, brief)

    def test_a_brief_WITH_implied_items_carries_the_new_note(self):
        from lcars_serve.actions import _handoff_brief, _HANDOFF_IMPLIED_NOTE
        brief = _handoff_brief(_CONCEPT_2_PLUS_12, "the MBR builder", [], [])
        self.assertIn(_HANDOFF_IMPLIED_NOTE, brief)
        self.assertIn("What does the amber state on a tile mean?", brief)


class HandoffCarryForwardChecklistTest(unittest.TestCase):
    """CURE 5 — the count, and that it is the GATE'S count."""

    COMMON = os.path.join(
        os.path.dirname(os.path.dirname(os.path.dirname(
            os.path.abspath(__file__)))),
        "skills", "lcars-init", "lcars-common.sh")

    def _bash_unsettled(self, text):
        """What the SHIPPED gate reads out of the same doc — the authority."""
        d = tempfile.mkdtemp()
        p = os.path.join(d, "concept.md")
        with open(p, "w") as fh:
            fh.write(text)
        proc = subprocess.run(
            ["bash", "-c", '. "$1"; lcars_concept_open_questions "$2"', "_",
             self.COMMON, p],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        out = proc.stdout.decode()
        return [ln for ln in out.split("\n") if ln.strip()]

    def test_the_count_matches_the_captains_real_2_plus_12_shape(self):
        from lcars_serve.actions import _handoff_unsettled
        self.assertEqual(len(_handoff_unsettled(_CONCEPT_2_PLUS_12)), 14)

    def test_the_daemons_read_agrees_with_the_shipped_gate(self):
        """THE DRIFT CATCHER, and the reason a count is safe to print at all.
        A checklist that is short by one is worse than no checklist: it tells
        the worker it is finished while the gate is about to refuse."""
        from lcars_serve.actions import _handoff_unsettled
        for doc in (_CONCEPT_2_PLUS_12, _CONCEPT_NO_IMPLIED,
                    _CONCEPT_NOTHING_UNSETTLED):
            self.assertEqual(_handoff_unsettled(doc), self._bash_unsettled(doc),
                             doc.splitlines()[0])

    def test_the_block_names_the_total_and_both_homes(self):
        from lcars_serve.actions import _handoff_carry_forward_block
        blk = _handoff_carry_forward_block(_CONCEPT_2_PLUS_12)
        self.assertIn("all 14 unsettled items", blk)
        self.assertIn("2 under the concept doc's `## Open questions`", blk)
        self.assertIn("12 under `## WHAT IT MUST DO`", blk)
        self.assertIn("AGAINST 14 BEFORE YOU FILE", blk)

    def test_the_block_names_the_destination_and_the_two_entry_shapes(self):
        from lcars_serve.actions import _handoff_carry_forward_block
        blk = _handoff_carry_forward_block(_CONCEPT_2_PLUS_12)
        self.assertIn("Open questions from the design session", blk)
        self.assertIn("- STILL OPEN: <the item>", blk)
        self.assertIn("- RESOLVED with the captain: <what was decided>", blk)
        # …and that carrying one forward UNANSWERED is complete. The gate wants
        # the questions to survive, not to be answered (SKILL.md's ruling).
        self.assertIn("do NOT need an answer", blk)

    def test_it_does_NOT_reprint_the_questions(self):
        """ONE HOME EACH still holds. This is an instruction and a count — a
        second copy of fourteen bullets is exactly the over-long box that gets
        skimmed."""
        from lcars_serve.actions import _handoff_carry_forward_block
        blk = _handoff_carry_forward_block(_CONCEPT_2_PLUS_12)
        self.assertNotIn("What do Preview and View actually do?", blk)
        self.assertNotIn("Which model should the MBR builder use?", blk)

    def test_a_doc_with_NOTHING_unsettled_produces_NOTHING(self):
        from lcars_serve.actions import _handoff_carry_forward_block
        self.assertEqual(
            _handoff_carry_forward_block(_CONCEPT_NOTHING_UNSETTLED), "")
        self.assertEqual(_handoff_carry_forward_block(""), "")

    def test_the_mission_idea_carries_it_after_the_questions_block(self):
        from lcars_serve.actions import Actions
        idea = Actions._handoff_idea("HIS WORDS", "look+behaviour", _CONCEPT_2_PLUS_12,
                                     {})
        self.assertIn("all 14 unsettled items", idea)
        self.assertLess(idea.index("Open questions from the design session"),
                        idea.index("all 14 unsettled items"))

    def test_an_idea_with_nothing_unsettled_is_byte_identical(self):
        """The no-op case, pinned as a whole string: his words, then the
        guidance, and nothing this session added in between."""
        from lcars_serve.actions import Actions, _handoff_guidance
        idea = Actions._handoff_idea("HIS WORDS", "look+behaviour",
                                     _CONCEPT_NOTHING_UNSETTLED, {})
        self.assertEqual(idea, "HIS WORDS\n\n" + _handoff_guidance("look+behaviour"))


class AlignHealAnswerIsSurgicalTest(unittest.TestCase):
    """CURE 6 — the repair turn hands over the gate's OWN list, and mirrors the
    repair `skills/lcars-file/SKILL.md` already prescribes for the CLI lane."""

    SKILL = os.path.join(
        os.path.dirname(os.path.dirname(os.path.dirname(
            os.path.abspath(__file__)))),
        "skills", "lcars-file", "SKILL.md")

    def test_it_asks_for_a_STILL_OPEN_entry_per_named_question(self):
        from lcars_serve.actions import _ALIGN_HEAL_ANSWER
        self.assertIn("Missing:", _ALIGN_HEAL_ANSWER)
        self.assertIn("- STILL OPEN: <the question>", _ALIGN_HEAL_ANSWER)
        self.assertIn("Open questions from the design session",
                      _ALIGN_HEAL_ANSWER)
        self.assertIn("all of them, including the last", _ALIGN_HEAL_ANSWER)

    def test_it_forbids_a_re_grill(self):
        """The cost the captain actually paid twice: a completed alignment
        thrown away over a heading."""
        from lcars_serve.actions import _ALIGN_HEAL_ANSWER
        low = _ALIGN_HEAL_ANSWER.lower()
        self.assertIn("do not re-grill", low)
        self.assertIn("do not restart the interview", low)
        self.assertIn("do not ask another question", low)

    def test_it_says_a_STILL_OPEN_entry_needs_no_answer(self):
        from lcars_serve.actions import _ALIGN_HEAL_ANSWER
        self.assertIn("do NOT need the captain", _ALIGN_HEAL_ANSWER)
        self.assertIn("do NOT need an answer", _ALIGN_HEAL_ANSWER)

    def test_it_carries_the_refusal_VERBATIM_not_a_summary(self):
        from lcars_serve.actions import _ALIGN_HEAL_ANSWER
        gate = ("PRD drops 5 of the design brief's 14 open question(s) …\n"
                "Missing:\n  - Q ten\n  - Q eleven\n  - Q twelve\n"
                "  - Q thirteen\n  - Q fourteen")
        built = _ALIGN_HEAL_ANSWER % gate
        for q in ("Q ten", "Q eleven", "Q twelve", "Q thirteen", "Q fourteen"):
            self.assertIn(q, built)

    def test_it_mirrors_the_repair_SKILL_MD_already_prescribes(self):
        """The daemon lane and the CLI lane must not describe two different
        repairs for one refusal."""
        with open(self.SKILL, encoding="utf-8") as fh:
            skill = fh.read()
        from lcars_serve.actions import _ALIGN_HEAL_ANSWER
        self.assertIn("- STILL OPEN: <the question>", skill)
        self.assertIn("NEVER RE-GRILL", skill)
        for phrase in ("STILL OPEN", "Open questions from the design session"):
            self.assertIn(phrase, skill)
            self.assertIn(phrase, _ALIGN_HEAL_ANSWER)


if __name__ == "__main__":
    unittest.main()

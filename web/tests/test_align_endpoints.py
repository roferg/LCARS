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
    """Every image the daemon has staged under repo_root (lcars-img-*)."""
    return sorted(glob.glob(os.path.join(root, "lcars-img-*")))


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
        # exactly ONE real file staged under repo_root; bytes match the input.
        staged = _staged_imgs(self.tmp)
        self.assertEqual(len(staged), 1)
        with open(staged[0], "rb") as fh:
            self.assertEqual(fh.read(), _IMG_BYTES)
        # claude REFERENCES the abs path in the prompt text (Read-tool hand-off).
        prompt = self._prompt_turns()[0]
        self.assertIn(staged[0], prompt)
        self.assertIn("attached images", prompt.lower())
        # the claude path must NOT add a copilot --attachment flag.
        self.assertNotIn("--attachment", self._argvs()[0])

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

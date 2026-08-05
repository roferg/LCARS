"""S124 — the HOLODECK worker seam: warm, resumable, cheap chat turns that write
mockup files into a SIDECAR git repo (never the target project).

Mirrors `test_align_endpoints.py`'s discipline: every worker call goes through a
RECORDING STUB that captures the FULL argv (as JSON, one line per invocation),
the `-p` prompt, and its cwd — so every per-engine flag assertion below costs
ZERO tokens. The stub can also WRITE files (inside the sidecar, or deliberately
outside it) so the post-turn filesystem audit is exercised against real bytes on
disk rather than a mocked walk.

The postures asserted here are the S124 SPIKE RECORD (18 live turns, both
engines, 2026-08-04), not guesses:

  claude  design    -p … --session-id|--resume <uuid> (SPACE form)
                       --allowedTools Read,Grep,Glob,Write,Edit
                       --output-format text --dangerously-skip-permissions
                       --model sonnet          cwd = the program dir
  copilot design    -p … --session-id=|--resume=<uuid> (EQUALS form)
                       --available-tools view,grep,glob,create,edit
                       --allow-all-tools --no-ask-user --disable-builtin-mcps
                       --no-custom-instructions --add-dir <sidecar>
                       --model claude-opus-4.8  cwd = the program dir
  either  grounding READ-ONLY tools, NO write tool at all, NO --add-dir of the
                    target repo, cwd = the target repo; the DAEMON writes basis.md.

And the one hard regression guard: **`bash`/`Bash` appears in NO holodeck argv,
in any mode, on either engine.** That was the actual root cause of the S72
bash-dump (copilot used bash as its reply channel) — not tools in general.

stdlib only; the daemon runs on an ephemeral localhost port inside the test.
"""
import json
import os
import shutil
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


# ── the recording worker stub ────────────────────────────────────────────────
# A python stub (not bash) because a holodeck turn must be able to WRITE files:
# expressing "this turn creates <path> with <content>" in bash quoting is how a
# fixture starts lying. Canned turns are a JSON list; each is
#   {"stdout": "...", "writes": [{"path": "<abs or cwd-relative>", "content": "..."}]}
#   {"sleep": <s>}                        a turn that runs long (timeout/cancel)
#   {"spawn": {"delay": <s>, "path": p}}  a GRANDCHILD in the same process group
#       that writes `path` after `delay` — the only way to tell a kill of the
#       worker from a kill of its process GROUP.
#   {"preWrites": [...]}                  files written BEFORE the sleep — a turn
#       that has already put real bytes on disk when LCARS stops it mid-flight.
# `writes` happen AFTER the sleep, so "the file never appeared" is real proof
# the process was stopped rather than merely abandoned.
_STUB_SRC = r'''#!/usr/bin/env python3
import json, os, subprocess, sys, time

CFG = json.loads(open(%(cfg)r).read())
argv = sys.argv[1:]
with open(CFG["argvLog"], "a") as fh:
    fh.write(json.dumps({"bin": os.path.basename(sys.argv[0]),
                         "argv": argv, "cwd": os.getcwd()}) + "\n")
prompt = ""
for i, a in enumerate(argv):
    if a == "-p" and i + 1 < len(argv):
        prompt = argv[i + 1]
        break
with open(CFG["promptLog"], "a") as fh:
    fh.write("===PROMPT===\n" + prompt + "\n")

turns = json.loads(open(CFG["turns"]).read())
idx_path = CFG["turns"] + ".idx"
i = 0
if os.path.exists(idx_path):
    try:
        i = int(open(idx_path).read().strip() or 0)
    except ValueError:
        i = 0
with open(idx_path, "w") as fh:
    fh.write(str(i + 1))
turn = turns[i] if i < len(turns) else (turns[-1] if turns else {})


def write_all(items):
    for w in items:
        p = w["path"]
        if not os.path.isabs(p):
            p = os.path.join(os.getcwd(), p)
        d = os.path.dirname(p)
        if d and not os.path.isdir(d):
            os.makedirs(d)
        with open(p, "w") as fh:
            fh.write(w.get("content", ""))


write_all(turn.get("preWrites", []))

spawn = turn.get("spawn")
if spawn:
    # deliberately NOT start_new_session: it stays in this stub's process
    # group, so only a killpg reaches it.
    subprocess.Popen(
        [sys.executable, "-c",
         "import sys,time;time.sleep(float(sys.argv[1]));"
         "open(sys.argv[2],'w').write('x')",
         str(spawn.get("delay", 1)), spawn["path"]])
if turn.get("sleep"):
    time.sleep(float(turn["sleep"]))

write_all(turn.get("writes", []))

sys.stdout.write(turn.get("stdout", ""))
sys.exit(int(turn.get("exit", 0)))
'''


def _make_stub(bindir, name, cfg_path):
    path = os.path.join(bindir, name)
    with open(path, "w") as fh:
        fh.write(_STUB_SRC % {"cfg": cfg_path})
    os.chmod(path, 0o755)
    return path


def _file_record_stub(record_path):
    """The file.sh/log.sh recording stub (same shape as test_align_endpoints)."""
    fd, path = tempfile.mkstemp(suffix=".sh")
    os.close(fd)
    script = ('#!/usr/bin/env bash\nprintf "ARGV: %%s\\n" "$*" >> %s\nexit 0\n'
              % json.dumps(record_path))
    with open(path, "w") as fh:
        fh.write(script)
    os.chmod(path, 0o755)
    return path


# ── the reply fixtures: REAL CAPTURED OUTPUT, never invented ─────────────────
# Round 0's copilot fixtures were written from imagination and the cleaner's
# regexes were then shaped to match them, so the cleaner tested green in both
# directions while being a COMPLETE NO-OP against real copilot stdout (and,
# on claude, deleting real prose). Everything below is transcribed VERBATIM
# from live `/say` payloads captured 2026-08-04 (copilot CLI 1.0.79-1) — only
# whole lines from the MIDDLE of the tool list are dropped, so the first and
# last lines keep their exact shape. Do not "tidy" these to suit a regex; if a
# pattern does not match this text, the pattern is wrong.
CLAUDE_NOISE = "Warning: no stdin data received in 3s, continuing without it\n"

# The two properties round 0 got wrong and this fixture pins:
#   • the tool list starts INLINE on the head line, after a `●` bullet;
#   • the continuation rows are indented and there are ~30 of them.
COPILOT_PREAMBLE = (
    "● Disabled tools: Kusto-acr, Kusto-advisor, Kusto-aks, Kusto-appconfig, Kusto-applens,\n"
    "  Kusto-applicationinsights, Kusto-appservice, Kusto-arm, Kusto-azd, Kusto-azurebackup,\n"
    "  Kusto-azuremigrate, Kusto-azureterraform, Kusto-azureterraformbestpractices, Kusto-bicepschema,\n"
    "  Kusto-monitor, Kusto-mysql, Kusto-policy, Kusto-postgres, Kusto-pricing, Kusto-quota, Kusto-redis,\n"
    "   Kusto-resilience, Kusto-resourcehealth, Kusto-role, Kusto-search, Kusto-servicebus,\n"
    "  Slack-slack_search_public_and_private, Slack-slack_search_users, bash, create, edit,\n"
    "  slack-slack_search_public, slack-slack_search_public_and_private, slack-slack_search_users, sql,\n"
    "  stop_bash, task, web_fetch, workiq-accept_eula, workiq-ask, workiq-call_function,\n"
    "  workiq-search_paths, workiq-update_entity, write_agent\n"
    "\n"
)

# copilot prints one of these per tool call. It is NOT stripped: it is the
# engine's own short account of what it did, and a rule that eats lines
# starting with `●` is a rule that eats prose starting with a bullet. It is
# here so the fixtures keep the real shape AROUND the prose.
COPILOT_ACTIVITY = "● Create mockup.html +27\n\n"

# COLUMN-ALIGNED, NO COLONS. Round 0's `_FOOTER_HEAD` required `AI Credits:`,
# `Tokens:`, `Resume:` — every pattern missed every real line.
COPILOT_FOOTER = (
    "\n\n"
    "Changes    +27 -0\n"
    "AI Credits 7.86 (29s)\n"
    "Tokens     ↑ 16.6k (7.9k cached, 8.7k written) • ↓ 811 (36 reasoning)\n"
    "Resume     copilot --resume=a3a5ad9b-79a2-4a24-835c-3eb98b9769b7\n"
)


class HolodeckBase(unittest.TestCase):
    read_only = False

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        # the TARGET repo (the captain's project) — the thing the sidecar exists
        # to protect. A real git dir so `_git_dir()`/scratch behave normally.
        self.repo = os.path.join(self.tmp, "target-repo")
        os.makedirs(self.repo)
        fx.plant_simple(self.repo, "m-001", stage="verify", issue=142)
        with open(os.path.join(self.repo, "board.css"), "w") as fh:
            fh.write(":root{--lcars-amber:#ff9c00;}\n")

        # the injected sidecar ROOT — tests never touch ~/Projects.
        self.holo_root = os.path.join(self.tmp, "holo-root")
        os.makedirs(self.holo_root)

        self.adapter = LocalAdapter(self.repo)

        self.bindir = os.path.join(self.tmp, "bin")
        os.makedirs(self.bindir)
        self.turns_path = os.path.join(self.tmp, "turns.json")
        self.prompt_log = os.path.join(self.tmp, "prompts.txt")
        self.argv_log = os.path.join(self.tmp, "argv.jsonl")
        self.cfg_path = os.path.join(self.tmp, "stub-cfg.json")
        with open(self.cfg_path, "w") as fh:
            json.dump({"turns": self.turns_path, "promptLog": self.prompt_log,
                       "argvLog": self.argv_log}, fh)
        self._set_turns({"stdout": "ok"})
        self.claude_bin = _make_stub(self.bindir, "claude", self.cfg_path)
        self.copilot_bin = _make_stub(self.bindir, "copilot", self.cfg_path)

        self.records = {}
        self.scripts = {}
        for key in ("file", "log", "resolve"):
            rec = os.path.join(self.tmp, "rec-%s.txt" % key)
            self.records[key] = rec
            self.scripts[key] = _file_record_stub(rec)

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

    # -- helpers --------------------------------------------------------------
    def _set_turns(self, *turns):
        with open(self.turns_path, "w") as fh:
            json.dump(list(turns), fh)
        idx = self.turns_path + ".idx"
        if os.path.exists(idx):
            os.unlink(idx)

    def _post(self, path, obj=None, timeout=20):
        url = "http://127.0.0.1:%d%s" % (self.port, path)
        data = json.dumps(obj if obj is not None else {}).encode("utf-8")
        req = urllib.request.Request(
            url, data=data, method="POST",
            headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, json.loads(r.read())

    def _post_raw(self, path, obj=None, timeout=20):
        """POST that returns (status, body) even for an error response."""
        try:
            return self._post(path, obj, timeout=timeout)
        except urllib.error.HTTPError as exc:
            return exc.code, json.loads(exc.read())

    def _calls(self):
        """The recorded worker invocations, in order: {bin, argv, cwd}."""
        if not os.path.exists(self.argv_log):
            return []
        out = []
        with open(self.argv_log) as fh:
            for line in fh:
                if line.strip():
                    out.append(json.loads(line))
        return out

    def _prompts(self):
        if not os.path.exists(self.prompt_log):
            return []
        with open(self.prompt_log) as fh:
            raw = fh.read()
        return [c.rstrip("\n") for c in raw.split("===PROMPT===\n") if c.strip()]

    @staticmethod
    def _flag_value(argv, flag):
        """The token after `flag` (space form), or None."""
        for i, a in enumerate(argv):
            if a == flag and i + 1 < len(argv):
                return argv[i + 1]
        return None

    @staticmethod
    def _prefixed(argv, prefix):
        """The value of an equals-form flag `--x=<v>`, or None."""
        for a in argv:
            if a.startswith(prefix):
                return a[len(prefix):]
        return None

    def _sidecar(self):
        return os.path.join(self.holo_root, "target-repo-holodeck")


# ── 1. warm resume + the per-engine design posture ───────────────────────────
class DesignPostureTest(HolodeckBase):
    def test_claude_design_start_say_say_warm_resume_and_tools(self):
        self._set_turns({"stdout": "First pass is up."},
                        {"stdout": "Made it teal."},
                        {"stdout": "Tightened the spacing."})
        status, body = self._post("/api/holodeck/start",
                                  {"program": "Nav rail", "engine": self.claude_bin})
        self.assertEqual(status, 200)
        sid = body["state"]["sessionId"]
        # design start opens the program and spends NOTHING — the first `say` is
        # the OPENING worker turn.
        self.assertEqual(self._calls(), [])

        self._post("/api/holodeck/%s/say" % sid, {"text": "Draft a nav rail"})
        self._post("/api/holodeck/%s/say" % sid, {"text": "Make it teal"})
        calls = self._calls()
        self.assertEqual(len(calls), 2, calls)

        first, second = calls[0]["argv"], calls[1]["argv"]
        # claude uses the SPACE form; the same uuid opens then resumes.
        opened = self._flag_value(first, "--session-id")
        resumed = self._flag_value(second, "--resume")
        self.assertTrue(opened, first)
        self.assertEqual(opened, resumed)
        self.assertIsNone(self._flag_value(first, "--resume"))
        self.assertIsNone(self._flag_value(second, "--session-id"))

        for argv in (first, second):
            self.assertEqual(self._flag_value(argv, "--allowedTools"),
                             "Read,Grep,Glob,Write,Edit")
            # `--allowedTools` is a PRE-APPROVAL list, not a restriction, and
            # `--dangerously-skip-permissions` waives what is left — measured
            # 2026-08-04: claude created a file with `--allowedTools
            # Read,Grep,Glob --dangerously-skip-permissions`. `--disallowedTools`
            # is the flag that actually refuses. The design room MAY write (it
            # builds the mockup), so only the shell is denied here.
            self.assertEqual(self._flag_value(argv, "--disallowedTools"),
                             "Bash,NotebookEdit")
            self.assertEqual(self._flag_value(argv, "--output-format"), "text")
            self.assertIn("--dangerously-skip-permissions", argv)
            self.assertEqual(self._flag_value(argv, "--model"), "sonnet")
            # claude has NO sandbox — it must never be handed --add-dir either.
            self.assertNotIn("--add-dir", argv)

        # cwd is the program dir inside the sidecar, never the target repo.
        for call in calls:
            self.assertTrue(
                os.path.realpath(call["cwd"]).startswith(
                    os.path.realpath(self._sidecar())), call["cwd"])
            self.assertNotEqual(os.path.realpath(call["cwd"]),
                                os.path.realpath(self.repo))

    def test_copilot_design_uses_equals_form_and_its_own_tool_posture(self):
        self._set_turns({"stdout": COPILOT_PREAMBLE + "Up." + COPILOT_FOOTER},
                        {"stdout": COPILOT_PREAMBLE + "Revised." + COPILOT_FOOTER})
        status, body = self._post(
            "/api/holodeck/start",
            {"program": "Nav rail", "engine": self.copilot_bin})
        sid = body["state"]["sessionId"]
        self._post("/api/holodeck/%s/say" % sid, {"text": "Draft a nav rail"})
        self._post("/api/holodeck/%s/say" % sid, {"text": "Make it teal"})
        calls = self._calls()
        self.assertEqual(len(calls), 2, calls)
        first, second = calls[0]["argv"], calls[1]["argv"]

        opened = self._prefixed(first, "--session-id=")
        resumed = self._prefixed(second, "--resume=")
        self.assertTrue(opened, first)
        self.assertEqual(opened, resumed)

        for argv in (first, second):
            self.assertEqual(self._flag_value(argv, "--available-tools"),
                             "view,grep,glob,create,edit")
            # `edit` is REQUIRED: copilot's `create` cannot overwrite (measured
            # on CLI 1.0.79-1), and turn 2 of any design chat is an overwrite.
            self.assertIn("edit",
                          self._flag_value(argv, "--available-tools").split(","))
            for flag in ("--allow-all-tools", "--no-ask-user",
                         "--disable-builtin-mcps", "--no-custom-instructions"):
                self.assertIn(flag, argv)
            # the sandbox grant is the SIDECAR only — never the target repo.
            grants = [argv[i + 1] for i, a in enumerate(argv)
                      if a == "--add-dir" and i + 1 < len(argv)]
            self.assertTrue(grants, argv)
            for g in grants:
                self.assertTrue(
                    os.path.realpath(g).startswith(
                        os.path.realpath(self._sidecar())), g)
            self.assertEqual(self._flag_value(argv, "--model"),
                             "claude-opus-4.8")

    def test_unknown_session_and_bad_mode_are_refused(self):
        st, body = self._post_raw("/api/holodeck/nope/say", {"text": "hi"})
        self.assertEqual(st, 404)
        self.assertFalse(body["ok"])
        st, body = self._post_raw("/api/holodeck/start",
                                  {"program": "X", "mode": "sudo"})
        self.assertEqual(st, 400)
        st, body = self._post_raw("/api/holodeck/start", {"program": "  "})
        self.assertEqual(st, 400)


# ── 2. the S72 root-cause regression guard ───────────────────────────────────
class NoBashEverTest(HolodeckBase):
    """`bash`/`Bash` must appear in NO holodeck argv, in any mode, on either
    engine. The S72 bash-dump was NOT caused by tools in general — it was caused
    by copilot using `bash` as its reply channel. Granting it back reopens that
    failure AND hands a chat worker arbitrary shell. Do not delete this test."""

    def _argv_tokens(self, call):
        """Every GRANT token in the argv, split on the separators a tool list
        can use — so `--available-tools a,bash,c` is caught as surely as a bare
        `Bash`.

        The binary path, the prompt body and the DENY list are excluded: naming
        `Bash` in `--disallowedTools` is the opposite of granting it, and a test
        that cannot tell those two apart would force the fix for defect 1 to be
        reverted to stay green."""
        argv = call["argv"]
        toks = []
        skip = False
        for i, a in enumerate(argv):
            if skip:
                skip = False
                continue
            if a == "-p":
                skip = True   # the prompt body may legitimately say "bash"
                continue
            if a == "--disallowedTools":
                skip = True   # a denial, not a grant
                continue
            if a.startswith("--disallowedTools="):
                continue
            for piece in a.replace("=", ",").replace(" ", ",").split(","):
                if piece:
                    toks.append(piece)
        return toks

    def test_no_bash_is_granted_and_on_claude_it_is_actively_denied(self):
        """WHAT THIS TEST CAN AND CANNOT PROVE.

        It reads the real argv the daemon built (via the recording stub) and
        checks two things: no GRANT list names a shell, and — on claude — a
        `--disallowedTools` naming Bash is actually present. The second half is
        the one that matters: round 0 asserted only the first, which stays green
        on an argv that hands the worker a shell anyway, because claude's
        `--allowedTools` is a pre-approval list and
        `--dangerously-skip-permissions` waives the rest.

        WHAT IT STILL CANNOT SEE: whether the CLI honours the flag. That was
        measured by hand against the live binary on 2026-08-04 (`--disallowedTools
        Write,Edit,Bash,NotebookEdit` → "BLOCKED — I have no file-writing
        capability… no Write tool and no Bash/shell tool available", no file
        created; without it, the same turn CREATED a file). No stub can prove
        that, and no argv assertion should be read as proving it.
        """
        seen = 0
        claude_calls = 0
        for engine in (self.claude_bin, self.copilot_bin):
            for mode in ("design", "grounding"):
                self._set_turns({"stdout": "fine"}, {"stdout": "fine"})
                # the program name carries the ENGINE as well as the mode: since
                # S125's fix round, two live programs cannot share one room
                # (they would write the same mockup.html and show as two
                # indistinguishable cards), and this loop opens four at once.
                _, body = self._post("/api/holodeck/start",
                                     {"program": "P-%s-%s"
                                      % (os.path.basename(engine), mode),
                                      "engine": engine, "mode": mode})
                sid = body["state"]["sessionId"]
                self._post("/api/holodeck/%s/say" % sid, {"text": "go"})
        for call in self._calls():
            seen += 1
            toks = [t.lower() for t in self._argv_tokens(call)]
            self.assertNotIn("bash", toks, call)
            if call["bin"] == "claude":
                claude_calls += 1
                denied = self._flag_value(call["argv"], "--disallowedTools")
                self.assertTrue(denied, call)
                self.assertIn("Bash", denied.split(","), call)
                self.assertIn("NotebookEdit", denied.split(","), call)
        self.assertGreaterEqual(seen, 4, "every mode/engine must have spawned")
        self.assertGreaterEqual(claude_calls, 2,
                                "the claude legs must have spawned")

    def test_the_guard_actually_fires_and_is_not_a_no_op(self):
        """A calibration case: argvs it MUST reject and argvs it MUST pass.
        Without the known-LOSS half, an always-green guard reads identically to
        a working one; without the known-WIN half, an always-red one does too.

        The known-WIN argvs are BUILT BY THE PRODUCT (`_holodeck_args`), not
        typed here, so a posture change cannot leave this test agreeing with a
        product it no longer describes."""
        from lcars_serve.actions import (_assert_no_bash, _holodeck_model,
                                         ActionError, Actions as _A)
        # known LOSS — the exact shapes a future edit could reintroduce.
        for bad in (["/x/claude", "-p", "hi", "--allowedTools",
                     "Read,Write,Bash", "--disallowedTools", "NotebookEdit"],
                    ["/x/copilot", "-p", "hi", "--available-tools",
                     "view,create,bash"],
                    ["/x/copilot", "-p", "hi", "--available-tools=view,bash"],
                    ["/x/claude", "-p", "hi", "--allowedTools", "Bash",
                     "--disallowedTools", "NotebookEdit"]):
            with self.assertRaises(ActionError):
                _assert_no_bash(bad)
        # known LOSS — a claude argv with NO deny list at all. This is the shape
        # round 0 shipped: it names no shell, and the worker gets one anyway.
        with self.assertRaises(ActionError):
            _assert_no_bash(["/x/claude", "-p", "hi", "--allowedTools",
                             "Read,Grep,Glob,Write,Edit", "--output-format",
                             "text", "--dangerously-skip-permissions"])
        # known LOSS — a claude argv carrying NEITHER list (D3, round 1). Round
        # 1 required the deny list only when `--allowedTools` was PRESENT, so a
        # later edit dropping the allow list would have retired the requirement
        # silently: the guard would stop guarding with nobody editing it. The
        # requirement keys off the ENGINE, so this argv must still be refused.
        with self.assertRaises(ActionError):
            _assert_no_bash(["/x/claude", "-p", "hi", "--output-format", "text",
                             "--dangerously-skip-permissions"])
        # ...and the same shape on COPILOT is fine: `--available-tools` IS a
        # restriction there, and copilot has no `--disallowedTools` to carry.
        _assert_no_bash(["/x/copilot", "-p", "hi", "--available-tools",
                         "view,grep,glob,create,edit"])
        # known WIN — the REAL postures, straight out of the product.
        for bin_ in ("/x/bin/claude", "/x/bin/copilot"):
            for mode in ("design", "grounding"):
                for opening in (True, False):
                    cmd = ([bin_, "-p", "never run bash for me"]
                           + _A._holodeck_args(bin_, mode, "abc-123", opening,
                                               "/tmp/room")
                           + ["--model", _holodeck_model(bin_)])
                    _assert_no_bash(cmd)

    def test_claude_grounding_denies_the_write_tools_it_does_not_merely_omit_them(self):
        """DEFECT 1 (round 0, falsified live). Omitting Write/Edit from
        `--allowedTools` does NOT make a claude turn read-only — the flag is a
        pre-approval list and `--dangerously-skip-permissions` waives what is
        left. The grounding pass runs in the CAPTAIN'S REAL PROJECT, so this is
        the one posture where the difference is money."""
        self._set_turns({"stdout": "basis"})
        self._post("/api/holodeck/start",
                   {"program": "P", "engine": self.claude_bin,
                    "mode": "grounding"})
        argv = self._calls()[0]["argv"]
        self.assertEqual(self._flag_value(argv, "--allowedTools"),
                         "Read,Grep,Glob")
        denied = self._flag_value(argv, "--disallowedTools")
        self.assertEqual(denied, "Write,Edit,Bash,NotebookEdit")
        # every write channel the CLI has, denied by name.
        for writer in ("Write", "Edit", "Bash", "NotebookEdit"):
            self.assertIn(writer, denied.split(","), argv)


# ── 3. the post-turn filesystem audit (the ONLY real fence on claude) ────────
class AuditTest(HolodeckBase):
    def _start_design(self, engine=None):
        _, body = self._post("/api/holodeck/start",
                             {"program": "Nav rail",
                              "engine": engine or self.claude_bin})
        return body["state"]["sessionId"]

    def test_sidecar_write_is_reported_in_files_changed(self):
        self._set_turns(
            {"stdout": "Wrote the mockup.",
             "writes": [{"path": "mockup.html", "content": "<h1>one</h1>"}]},
            {"stdout": "Revised it.",
             "writes": [{"path": "mockup.html", "content": "<h1>two</h1>"}]},
        )
        sid = self._start_design()
        _, body = self._post("/api/holodeck/%s/say" % sid, {"text": "draft"})
        st = body["state"]
        paths = [f["path"] for f in st["filesChanged"]]
        self.assertTrue(any(p.endswith("mockup.html") for p in paths), st)
        self.assertEqual(
            [f["status"] for f in st["filesChanged"] if
             f["path"].endswith("mockup.html")], ["added"])
        self.assertEqual(st.get("refused"), None)
        self.assertEqual(st["reply"].strip(), "Wrote the mockup.")

        # turn 2 OVERWRITES the same file → reported as modified, not added.
        _, body = self._post("/api/holodeck/%s/say" % sid, {"text": "teal it"})
        st = body["state"]
        rows = [f for f in st["filesChanged"] if f["path"].endswith("mockup.html")]
        self.assertEqual([r["status"] for r in rows], ["modified"], st)

    def test_write_outside_the_sidecar_is_refused_and_the_session_survives(self):
        stray = os.path.join(self.repo, "src", "stolen.html")
        self._set_turns(
            {"stdout": "Done (I put it in your project).",
             "writes": [{"path": stray, "content": "<h1>nope</h1>"}]},
            {"stdout": "Sorry — back in the sidecar.",
             "writes": [{"path": "mockup.html", "content": "<h1>ok</h1>"}]},
        )
        sid = self._start_design()
        _, body = self._post("/api/holodeck/%s/say" % sid, {"text": "draft"})
        st = body["state"]
        self.assertEqual(st["status"], "refused", st)
        ref = st["refused"]
        self.assertIn(stray, ref["paths"])
        # LCARS voice (D7): lead with what SURVIVED, name the exact path, no
        # stack trace, and never claim the sidecar's own work was lost.
        msg = ref["message"]
        low = msg.lower()
        self.assertIn(stray, msg)
        self.assertTrue("still running" in low or "still open" in low, msg)
        self.assertTrue("safe" in low, msg)
        self.assertNotIn("Traceback", msg)
        # DEFECT 5 — it must REPORT what changed, never ACCUSE the worker. The
        # audit is a before/after walk of the whole repo during the turn: it
        # cannot tell the worker from the captain's editor autosave, a linter, a
        # dev server or an `npm install` in the very project being designed for.
        # (Measured: a control write from a separate shell produced "A turn wrote
        # outside the holodeck… LCARS did not put them there".)
        self.assertNotIn("a turn wrote", low)
        self.assertNotIn("did not put them there", low)
        self.assertIn("cannot tell", low)
        self.assertIn("changed", low)
        # the stray write is NOT laundered into filesChanged.
        self.assertTrue(all(not f["path"].endswith("stolen.html")
                            for f in st["filesChanged"]), st)

        # THE SESSION SURVIVES: the very next turn works and resumes warm.
        _, body = self._post("/api/holodeck/%s/say" % sid, {"text": "again"})
        st2 = body["state"]
        self.assertEqual(st2["status"], "ok", st2)
        self.assertTrue(any(f["path"].endswith("mockup.html")
                            for f in st2["filesChanged"]), st2)
        calls = self._calls()
        self.assertEqual(self._flag_value(calls[0]["argv"], "--session-id"),
                         self._flag_value(calls[1]["argv"], "--resume"))


# ── 4. grounding mode (D12) ──────────────────────────────────────────────────
class GroundingTest(HolodeckBase):
    BASIS = ("## Design language\n\n"
             "- `--lcars-amber: #ff9c00` — 1 occurrence in board.css\n\n"
             "## What I did NOT find\n\n- no light theme; the project is dark-only.\n")

    def test_claude_grounding_is_read_only_and_daemon_writes_basis(self):
        """The read-only posture, as far as an argv can show it.

        Round 0's version asserted ONLY that Write/Edit were absent from
        `--allowedTools` and called that "structurally impossible" — the
        captain falsified it live: that argv plus
        `--dangerously-skip-permissions` created a file. The deny list below is
        what was measured actually refusing. What this test still cannot see is
        whether the CLI honours it (see NoBashEverTest for that measurement)."""
        self._set_turns({"stdout": CLAUDE_NOISE + self.BASIS})
        _, body = self._post("/api/holodeck/start",
                             {"program": "Nav rail", "engine": self.claude_bin,
                              "mode": "grounding"})
        st = body["state"]
        calls = self._calls()
        self.assertEqual(len(calls), 1, calls)
        argv = calls[0]["argv"]
        self.assertEqual(self._flag_value(argv, "--allowedTools"),
                         "Read,Grep,Glob")
        tools = self._flag_value(argv, "--allowedTools").split(",")
        denied = (self._flag_value(argv, "--disallowedTools") or "").split(",")
        for writer in ("Write", "Edit", "Bash", "NotebookEdit"):
            self.assertNotIn(writer, tools)
            self.assertIn(writer, denied, argv)
        self.assertNotIn("--add-dir", argv)
        # cwd IS the target repo (read-only), by design.
        self.assertEqual(os.path.realpath(calls[0]["cwd"]),
                         os.path.realpath(self.repo))

        # the DAEMON writes basis.md — the worker has no write tool at all.
        basis = os.path.join(st["programDir"], "basis.md")
        self.assertTrue(os.path.exists(basis), st)
        with open(basis) as fh:
            written = fh.read()
        self.assertIn("--lcars-amber", written)
        self.assertNotIn("no stdin data received", written)
        self.assertTrue(any(f["path"].endswith("basis.md")
                            for f in st["filesChanged"]), st)

    def test_copilot_grounding_never_add_dirs_the_target_repo(self):
        self._set_turns({"stdout": COPILOT_PREAMBLE + self.BASIS + COPILOT_FOOTER})
        _, body = self._post("/api/holodeck/start",
                             {"program": "Nav rail", "engine": self.copilot_bin,
                              "mode": "grounding"})
        st = body["state"]
        argv = self._calls()[0]["argv"]
        self.assertEqual(self._flag_value(argv, "--available-tools"),
                         "view,grep,glob")
        tools = self._flag_value(argv, "--available-tools").split(",")
        for writer in ("create", "edit", "write", "bash"):
            self.assertNotIn(writer, tools)
        # `--add-dir` grants WRITE, not just read (measured) — granting the
        # target repo would hand the holodeck the captain's real project.
        self.assertNotIn("--add-dir", argv)
        for a in argv:
            self.assertNotEqual(os.path.realpath(a) if os.path.isabs(a) else a,
                                os.path.realpath(self.repo))
        # basis.md is the DURABLE artifact — it outlives the program and is what
        # a later design turn is built from. With the REAL captured preamble and
        # footer (round 0's were invented), this is where a no-op cleaner shows
        # up as ~40 lines of MCP tool dump and a credit footer committed into the
        # captain's design archive.
        basis = os.path.join(st["programDir"], "basis.md")
        with open(basis) as fh:
            written = fh.read()
        self.assertIn("--lcars-amber", written)
        self.assertNotIn("Disabled tools", written)
        self.assertNotIn("Kusto-", written)
        self.assertNotIn("workiq-", written)
        self.assertNotIn("AI Credits", written)
        self.assertNotIn("Resume ", written)
        self.assertNotIn("Tokens ", written)


# ── 5. the fenced-block fallback (a degradation path, not the default) ───────
class FencedFallbackTest(HolodeckBase):
    def test_fenced_file_blocks_are_written_by_the_daemon(self):
        reply = (
            "My `create` tool refused to overwrite the file, so here it is in "
            "full — please give me an edit tool.\n\n"
            "```html file:mockup.html\n"
            "<!doctype html><title>rail</title>\n"
            "```\n\n"
            "```file:notes/summary.md\n"
            "# Nav rail\n"
            "Teal, 64px.\n"
            "```\n"
            "That's everything.\n")
        self._set_turns({"stdout": reply})
        _, body = self._post("/api/holodeck/start",
                             {"program": "Nav rail", "engine": self.copilot_bin})
        sid = body["state"]["sessionId"]
        _, body = self._post("/api/holodeck/%s/say" % sid, {"text": "draft"})
        st = body["state"]
        paths = sorted(f["path"] for f in st["filesChanged"])
        self.assertTrue(any(p.endswith("mockup.html") for p in paths), st)
        self.assertTrue(any(p.endswith("notes/summary.md") for p in paths), st)
        pd = st["programDir"]
        with open(os.path.join(pd, "mockup.html")) as fh:
            self.assertIn("<!doctype html>", fh.read())
        with open(os.path.join(pd, "notes", "summary.md")) as fh:
            self.assertIn("Teal, 64px.", fh.read())
        # same contract as a native write.
        for row in st["filesChanged"]:
            self.assertIn(row["status"], ("added", "modified", "deleted"))

    def test_a_fenced_block_cannot_escape_the_program_dir(self):
        reply = ("```file:../../../../etc/pwned.conf\nboom\n```\n"
                 "```file:/tmp/lcars-holodeck-should-not-exist\nboom\n```\n")
        self._set_turns({"stdout": reply})
        _, body = self._post("/api/holodeck/start",
                             {"program": "Nav rail", "engine": self.claude_bin})
        sid = body["state"]["sessionId"]
        _, body = self._post("/api/holodeck/%s/say" % sid, {"text": "draft"})
        st = body["state"]
        self.assertEqual(st["status"], "refused", st)
        self.assertEqual(st["filesChanged"], [])
        self.assertFalse(os.path.exists("/tmp/lcars-holodeck-should-not-exist"))

    def test_a_plain_code_fence_with_no_declared_path_writes_nothing(self):
        self._set_turns({"stdout": "Here's the idea:\n\n```html\n<b>hi</b>\n```\n"})
        _, body = self._post("/api/holodeck/start",
                             {"program": "Nav rail", "engine": self.claude_bin})
        sid = body["state"]["sessionId"]
        _, body = self._post("/api/holodeck/%s/say" % sid, {"text": "draft"})
        self.assertEqual(body["state"]["filesChanged"], [])
        self.assertEqual(body["state"]["status"], "ok")


# ── 6. reply parsing survives realistic noisy stdout ─────────────────────────
class NoisyReplyTest(HolodeckBase):
    def test_claude_stdin_warning_is_not_part_of_the_reply(self):
        self._set_turns({"stdout": CLAUDE_NOISE + "The rail is up. Refresh."})
        _, body = self._post("/api/holodeck/start",
                             {"program": "P", "engine": self.claude_bin})
        sid = body["state"]["sessionId"]
        _, body = self._post("/api/holodeck/%s/say" % sid, {"text": "go"})
        self.assertEqual(body["state"]["reply"].strip(),
                         "The rail is up. Refresh.")

    def test_the_fixtures_are_the_real_captured_shape(self):
        """The fixtures ARE the product's specification here, so pin the two
        properties round 0 got wrong. Both regexes were written against invented
        text and the text was then shaped to match them, so the cleaner tested
        green while doing nothing at all to real copilot output."""
        head = COPILOT_PREAMBLE.split("\n")[0]
        # the tool list is INLINE on the head line, after a bullet — it is NOT
        # a bare `Disabled tools:` line with the list beneath it.
        self.assertTrue(head.startswith("● Disabled tools: "), head)
        self.assertGreater(len(head), 60, head)
        rest = COPILOT_PREAMBLE.split("\n")[1:-2]
        self.assertGreaterEqual(len(rest), 5, rest)
        for line in rest:
            self.assertTrue(line.startswith(" "), repr(line))
        # the footer is COLUMN-ALIGNED (every value starts at column 12) and
        # carries NO colons. Note `AI Credits` is padded with a SINGLE space —
        # a `\s{2,}` rule would miss exactly that row.
        rows = [l for l in COPILOT_FOOTER.split("\n") if l.strip()]
        self.assertEqual([r[:11].strip() for r in rows],
                         ["Changes", "AI Credits", "Tokens", "Resume"])
        for row in rows:
            self.assertNotIn(":", row[:11], row)
            self.assertEqual(row[10], " ", row)
            self.assertTrue(row[11:].strip(), row)

    def test_copilot_preamble_and_footer_are_stripped(self):
        self._set_turns({"stdout": COPILOT_PREAMBLE + COPILOT_ACTIVITY
                         + "The rail is up. Refresh.\n" + COPILOT_FOOTER})
        _, body = self._post("/api/holodeck/start",
                             {"program": "P", "engine": self.copilot_bin})
        sid = body["state"]["sessionId"]
        _, body = self._post("/api/holodeck/%s/say" % sid, {"text": "go"})
        reply = body["state"]["reply"]
        self.assertNotIn("Disabled tools", reply)
        self.assertNotIn("Kusto-", reply)
        self.assertNotIn("workiq-", reply)
        self.assertNotIn("AI Credits", reply)
        self.assertNotIn("Resume ", reply)
        self.assertNotIn("--resume=", reply)
        # what SURVIVES: the prose, and copilot's own one-line account of the
        # tool call. Nothing else.
        self.assertEqual(reply.strip(),
                         "● Create mockup.html +27\n\nThe rail is up. Refresh.")
        # the RAW stdout is still available — never assume stdout starts at
        # byte 0, and never throw away what the engine actually said.
        self.assertIn("Disabled tools", body["state"]["raw"])

    def test_the_footer_cutter_never_eats_real_prose(self):
        """Calibration — a known TRIM and a known KEEP. Without both halves, a
        cleaner that trims nothing and one that trims everything read the same.

        Round 0's KEEP case ended with `Anything else?`, which is exactly the
        line that SHIELDS the failing shape. The shape measured eating real
        prose live on claude is a footer-shaped sentence as the **last** line —
        near-inevitable when the turn prompt says "REPLY SHORT: a sentence or
        two"."""
        from lcars_serve.actions import _clean_reply
        # known TRIM — the real copilot footer.
        self.assertEqual(_clean_reply("Done.\n" + COPILOT_FOOTER), "Done.")
        self.assertEqual(
            _clean_reply(COPILOT_PREAMBLE + "Done.\n" + COPILOT_FOOTER), "Done.")
        # known KEEP — measured live: this reply lost its last sentence.
        eaten = ("I kept the palette you already had.\n"
                 "Tokens: I reused your amber and teal rather than inventing "
                 "new ones.")
        self.assertEqual(_clean_reply(eaten), eaten)
        for keep in ("Total duration: the animation now runs 200ms.",
                     "Resume: pick this back up whenever you like.",
                     "Changes: none — I only read the file.",
                     "I made two Changes: the rail is teal and 64px wide.\n"
                     "Total duration of the animation is 200ms now.\n"
                     "Anything else?"):
            self.assertEqual(_clean_reply(keep), keep)
        # …and a lone footer-shaped row with no `Resume` line under it is prose
        # too: only the complete, contiguous, trailing block is a footer.
        self.assertEqual(_clean_reply("All set.\nChanges    +27 -0"),
                         "All set.\nChanges    +27 -0")

    def test_a_fenced_block_buried_in_noise_is_still_found(self):
        self._set_turns({"stdout": COPILOT_PREAMBLE
                         + "Here you go.\n\n```file:mockup.html\n<b>hi</b>\n```\n"
                         + COPILOT_FOOTER})
        _, body = self._post("/api/holodeck/start",
                             {"program": "P", "engine": self.copilot_bin})
        sid = body["state"]["sessionId"]
        _, body = self._post("/api/holodeck/%s/say" % sid, {"text": "go"})
        st = body["state"]
        self.assertTrue(any(f["path"].endswith("mockup.html")
                            for f in st["filesChanged"]), st)

    def test_a_dead_worker_is_surfaced_and_the_program_survives(self):
        """D7 HOLODECK OFFLINE — a turn that died must not read as a good turn.
        But a turn that DIED AFTER writing keeps its work: the bytes are on
        disk, and throwing them away to keep the status tidy loses real work."""
        self._set_turns({"stdout": "error: connection reset by peer\n",
                         "exit": 1},
                        {"stdout": "half-done\n", "exit": 1,
                         "writes": [{"path": "mockup.html", "content": "<b>x</b>"}]},
                        {"stdout": "recovered"})
        _, body = self._post("/api/holodeck/start",
                             {"program": "P", "engine": self.claude_bin})
        sid = body["state"]["sessionId"]
        st, body = self._post_raw("/api/holodeck/%s/say" % sid, {"text": "go"})
        self.assertEqual(st, 502)
        low = body["error"].lower()
        self.assertIn("safe", low)
        self.assertIn("still running", low)
        self.assertNotIn("Traceback", body["error"])
        # died, but the file landed → the turn is kept.
        st, body = self._post_raw("/api/holodeck/%s/say" % sid, {"text": "again"})
        self.assertEqual(st, 200)
        self.assertEqual(body["state"]["exitCode"], 1)
        self.assertTrue(any(f["path"].endswith("mockup.html")
                            for f in body["state"]["filesChanged"]))
        # and the program is still usable.
        st, _ = self._post_raw("/api/holodeck/%s/say" % sid, {"text": "more"})
        self.assertEqual(st, 200)

    def test_an_empty_reply_is_an_error_not_a_silent_success(self):
        self._set_turns({"stdout": CLAUDE_NOISE})
        _, body = self._post("/api/holodeck/start",
                             {"program": "P", "engine": self.claude_bin})
        sid = body["state"]["sessionId"]
        st, body = self._post_raw("/api/holodeck/%s/say" % sid, {"text": "go"})
        self.assertEqual(st, 502)
        self.assertFalse(body["ok"])
        # …and the session is still usable.
        self._set_turns({"stdout": "back"})
        st, body = self._post_raw("/api/holodeck/%s/say" % sid, {"text": "again"})
        self.assertEqual(st, 200)


# ── 7. sidecar bootstrap ─────────────────────────────────────────────────────
class SidecarBootstrapTest(HolodeckBase):
    def test_sidecar_is_created_beside_the_repo_as_a_git_repo_and_is_idempotent(self):
        _, body = self._post("/api/holodeck/start", {"program": "Nav rail"})
        st = body["state"]
        side = self._sidecar()
        self.assertEqual(os.path.realpath(st["sidecar"]),
                         os.path.realpath(side))
        self.assertTrue(os.path.isdir(os.path.join(side, ".git")))
        head = subprocess.run(["git", "-C", side, "rev-parse", "HEAD"],
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        self.assertEqual(head.returncode, 0, head.stdout)
        first = head.stdout.strip()

        # a SECOND program in the same repo re-uses the sidecar, does not
        # re-init it, and does not lose the first commit.
        _, body2 = self._post("/api/holodeck/start", {"program": "Cards"})
        self.assertEqual(os.path.realpath(body2["state"]["sidecar"]),
                         os.path.realpath(side))
        head2 = subprocess.run(["git", "-C", side, "rev-parse", "HEAD"],
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        self.assertEqual(head2.stdout.strip(), first)
        self.assertNotEqual(body["state"]["programDir"],
                            body2["state"]["programDir"])

    def test_bootstrap_writes_nothing_outside_the_injected_root(self):
        before = set()
        for dirpath, dirnames, filenames in os.walk(self.repo):
            for f in filenames:
                before.add(os.path.join(dirpath, f))
        self._post("/api/holodeck/start", {"program": "Nav rail"})
        after = set()
        for dirpath, dirnames, filenames in os.walk(self.repo):
            for f in filenames:
                after.add(os.path.join(dirpath, f))
        self.assertEqual(before, after,
                         "the holodeck must never write into the target repo")
        # everything it DID create is under the injected root.
        self.assertTrue(os.path.isdir(self._sidecar()))
        self.assertEqual(sorted(os.listdir(self.holo_root)),
                         ["target-repo-holodeck"])

    def test_end_drops_the_session_and_leaves_the_files(self):
        self._set_turns({"stdout": "done",
                         "writes": [{"path": "mockup.html", "content": "x"}]})
        _, body = self._post("/api/holodeck/start", {"program": "Nav rail"})
        sid = body["state"]["sessionId"]
        pd = body["state"]["programDir"]
        self._post("/api/holodeck/%s/say" % sid, {"text": "go"})
        _, body = self._post("/api/holodeck/%s/end" % sid)
        self.assertEqual(body["state"]["status"], "ended")
        self.assertTrue(os.path.exists(os.path.join(pd, "mockup.html")))
        st, _ = self._post_raw("/api/holodeck/%s/say" % sid, {"text": "more"})
        self.assertEqual(st, 404)


# ── 7b. a turn that never ends (DEFECT 6) ────────────────────────────────────
class HungTurnTest(HolodeckBase):
    """A holodeck turn had NO timeout and NO cancel. Measured: with a worker
    mid-turn, `POST /end` returned `{"ok": true}` while the process stayed alive
    and kept writing into a sidecar for a session that no longer existed, and the
    originating `/say` hung forever. A hung turn must end as a legible LCARS
    message — S125 is putting a browser in front of this, and an infinite spinner
    is the one outcome a browser cannot recover from."""

    def setUp(self):
        HolodeckBase.setUp(self)
        self._old_timeout = os.environ.get("LCARS_HOLODECK_TURN_TIMEOUT")
        self._old_settle = os.environ.get("LCARS_HOLODECK_END_SETTLE_TIMEOUT")

    def tearDown(self):
        for name, old in (("LCARS_HOLODECK_TURN_TIMEOUT", self._old_timeout),
                          ("LCARS_HOLODECK_END_SETTLE_TIMEOUT",
                           self._old_settle)):
            if old is None:
                os.environ.pop(name, None)
            else:
                os.environ[name] = old
        HolodeckBase.tearDown(self)

    def _start(self):
        _, body = self._post("/api/holodeck/start",
                             {"program": "Nav rail", "engine": self.claude_bin})
        return body["state"]["sessionId"]

    def test_a_turn_past_the_timeout_is_stopped_and_reported(self):
        late = os.path.join(self.tmp, "late-write.txt")
        grandchild = os.path.join(self.tmp, "grandchild.txt")
        os.environ["LCARS_HOLODECK_TURN_TIMEOUT"] = "1"
        self._set_turns({"stdout": "thinking...\n", "sleep": 6,
                         "spawn": {"delay": 2, "path": grandchild},
                         "writes": [{"path": late, "content": "x"}]})
        sid = self._start()
        began = time.time()
        st, body = self._post_raw("/api/holodeck/%s/say" % sid, {"text": "go"},
                                  timeout=30)
        took = time.time() - began
        self.assertEqual(st, 504, body)
        self.assertLess(took, 15, "the turn was not stopped near its limit")
        low = body["error"].lower()
        self.assertIn("safe", low)
        self.assertNotIn("Traceback", body["error"])
        self.assertTrue("stopped" in low or "gave up" in low, body["error"])
        # THE PROOF the process was really killed, not merely abandoned: the
        # stub writes `late` only AFTER its sleep, and its grandchild (same
        # process group, so only a killpg reaches it) writes after 2s.
        time.sleep(7)
        self.assertFalse(os.path.exists(late),
                         "the worker outlived the timeout and kept writing")
        self.assertFalse(os.path.exists(grandchild),
                         "the worker's process GROUP outlived the timeout")
        # and the program is still usable afterwards.
        self._set_turns({"stdout": "back"})
        os.environ["LCARS_HOLODECK_TURN_TIMEOUT"] = "60"
        st, _ = self._post_raw("/api/holodeck/%s/say" % sid, {"text": "again"})
        self.assertEqual(st, 200)

    def test_end_kills_a_turn_in_flight_instead_of_lying_about_it(self):
        late = os.path.join(self.tmp, "after-end.txt")
        os.environ["LCARS_HOLODECK_TURN_TIMEOUT"] = "60"
        self._set_turns({"stdout": "working\n", "sleep": 6,
                         "writes": [{"path": late, "content": "x"}]})
        sid = self._start()
        out = {}

        def _say():
            out["r"] = self._post_raw("/api/holodeck/%s/say" % sid,
                                      {"text": "go"}, timeout=45)
        t = threading.Thread(target=_say)
        t.start()
        deadline = time.time() + 10
        while not self._calls() and time.time() < deadline:
            time.sleep(0.05)
        self.assertTrue(self._calls(), "the worker never spawned")

        st, body = self._post("/api/holodeck/%s/end" % sid)
        self.assertEqual(st, 200)
        self.assertTrue(body["state"].get("stoppedTurn"), body)
        t.join(20)
        self.assertFalse(t.is_alive(),
                         "POST /say never returned — the hung turn is still hung")
        code, resp = out["r"]
        self.assertNotEqual(code, 200, resp)
        self.assertNotIn("Traceback", resp["error"])
        time.sleep(7)
        self.assertFalse(os.path.exists(late),
                         "the worker kept running (and writing) after `end`")

    # -- D2: `end` and the turn it stopped must describe the SAME bytes -------
    def _say_in_flight(self, sid, out):
        """Start a `/say` in a thread and return once its worker has really
        spawned AND written its file — so what follows is a genuine mid-turn
        `end`, not a race with a turn that had not started."""
        def _say():
            out["r"] = self._post_raw("/api/holodeck/%s/say" % sid,
                                      {"text": "go"}, timeout=60)
        t = threading.Thread(target=_say)
        t.start()
        deadline = time.time() + 15
        while time.time() < deadline:
            if self._calls() and os.path.exists(self.written):
                break
            time.sleep(0.05)
        self.assertTrue(os.path.exists(self.written),
                        "the turn never wrote its file — nothing to under-report")
        return t

    def _in_flight_turn(self):
        """A turn that writes ONE real file and then keeps running."""
        os.environ["LCARS_HOLODECK_TURN_TIMEOUT"] = "120"
        self._set_turns({"stdout": "working\n",
                         "preWrites": [{"path": "mockup.html",
                                        "content": "<b>x</b>"}],
                         "sleep": 20})
        sid = self._start()
        self.written = os.path.join(self._sidecar(), "nav-rail", "mockup.html")
        return sid

    def test_end_mid_turn_reports_the_files_that_turn_had_already_written(self):
        """DEFECT 2 (round 1, measured live). `POST /end` during an in-flight
        turn answered `{"files": [], "stoppedTurn": true}` while the 409 from
        the same stopped turn — one second later, about the same bytes —
        correctly said "The 1 file(s) it had already written are saved and
        committed", and the file WAS in the commit. `end` is the surface a
        captain who walked away is left with; it must not under-report."""
        sid = self._in_flight_turn()
        out = {}
        t = self._say_in_flight(sid, out)
        _, body = self._post("/api/holodeck/%s/end" % sid, timeout=60)
        state = body["state"]
        self.assertTrue(state.get("stoppedTurn"), state)
        self.assertTrue(state.get("filesSettled"), state)
        self.assertTrue(any(f.endswith("mockup.html")
                            for f in state["files"]), state)
        t.join(40)
        self.assertFalse(t.is_alive(), "POST /say never returned")
        code, resp = out["r"]
        self.assertNotEqual(code, 200, resp)
        # the two surfaces agree about the same bytes — and it really is a
        # commit, not just a file on disk.
        self.assertIn("1 file", resp["error"])
        porcelain = subprocess.run(["git", "-C", self._sidecar(), "status",
                                    "--porcelain"], stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT)
        self.assertEqual(porcelain.stdout.decode().strip(), "")

    def test_end_that_cannot_wait_for_the_audit_says_so(self):
        """The honest fallback: if `end` genuinely cannot wait for the in-flight
        turn's audit, it must SAY the list may be short rather than print a
        confident empty one."""
        os.environ["LCARS_HOLODECK_END_SETTLE_TIMEOUT"] = "0"
        sid = self._in_flight_turn()
        out = {}
        t = self._say_in_flight(sid, out)
        _, body = self._post("/api/holodeck/%s/end" % sid, timeout=60)
        state = body["state"]
        self.assertFalse(state.get("filesSettled"), state)
        msg = state["warning"]["message"]
        self.assertIn("may be missing", msg.lower())
        self.assertNotIn("Traceback", msg)
        t.join(40)
        self.assertFalse(t.is_alive(), "POST /say never returned")


# ── 7b-2. the copy on a turn LCARS stopped (D4) ──────────────────────────────
class StoppedTurnCopyTest(unittest.TestCase):
    """Two lying sentences, both introduced in round 1's cures."""

    def test_two_different_limits_do_not_render_as_the_same_duration(self):
        from lcars_serve.actions import _stopped_turn_error
        _, m90 = _stopped_turn_error("/x/bin/claude", 90, True, [])
        _, m150 = _stopped_turn_error("/x/bin/claude", 150, True, [])
        # `%.0f` on limit/60 printed BOTH of these as "2 minutes".
        self.assertNotEqual(m90, m150)
        self.assertIn("90 seconds", m90)
        self.assertNotIn("minute", m90)
        self.assertIn("2.5 minutes", m150)
        _, m1200 = _stopped_turn_error("/x/bin/claude", 1200, True, [])
        self.assertIn("20 minutes", m1200)

    def test_the_engine_is_named_in_a_sentence_not_a_bare_parenthetical(self):
        from lcars_serve.actions import _stopped_turn_error
        _, msg = _stopped_turn_error("/x/bin/claude", 1200, True, [])
        self.assertNotIn("(claude)", msg)
        self.assertIn("claude worker", msg)


# ── 7c. a start that cannot possibly run (DEFECT 7) ──────────────────────────
class NoEngineTest(HolodeckBase):
    def test_start_without_an_engine_fails_early_and_creates_nothing(self):
        from lcars_serve.actions import ActionError
        acts = Actions(repo_root=self.repo, scripts=self.scripts,
                       worker_bin=None, holodeck_root=self.holo_root)
        with self.assertRaises(ActionError) as caught:
            acts.holodeck_start(program="Nav rail")
        self.assertIn("engine", caught.exception.message.lower())
        # NOTHING may be created by a start that cannot run: round 0 built the
        # sidecar git repo AND the program dir, returned 200 with
        # `"engine": null`, and only 502'd on the first `say`.
        self.assertEqual(os.listdir(self.holo_root), [])

    def test_start_with_an_engine_that_is_not_there_fails_early_too(self):
        from lcars_serve.actions import ActionError
        acts = Actions(repo_root=self.repo, scripts=self.scripts,
                       worker_bin=self.claude_bin, holodeck_root=self.holo_root)
        missing = os.path.join(self.tmp, "no-such-cli")
        with self.assertRaises(ActionError) as caught:
            acts.holodeck_start(program="Nav rail", engine=missing)
        self.assertIn(missing, caught.exception.message)
        self.assertEqual(os.listdir(self.holo_root), [])

    def test_a_good_start_still_reports_a_real_engine(self):
        _, body = self._post("/api/holodeck/start",
                             {"program": "Nav rail", "engine": self.claude_bin})
        self.assertTrue(body["state"]["engine"])


# ── 7d. a turn LCARS could not fully check (DEFECT 8) ────────────────────────
class AuditIncompleteTest(HolodeckBase):
    """`auditComplete: false` was a bare boolean nobody surfaced: the turn came
    back `status: "ok"` with normal `filesChanged` and no message, and in that
    state a stray write is simply NOT DETECTED. Degrading the fence must never
    read the same as a clean turn."""

    def setUp(self):
        HolodeckBase.setUp(self)
        # a project with more files than the cap. It is THIS walk — the one over
        # the captain's real project — whose truncation means a stray write goes
        # unseen, so that is the walk the test truncates. The sidecar (README +
        # the program's mockup) stays under the cap and is checked normally.
        for i in range(8):
            with open(os.path.join(self.repo, "extra-%d.css" % i), "w") as fh:
                fh.write("/* %d */\n" % i)
        self._old_cap = os.environ.get("LCARS_HOLODECK_AUDIT_MAX_FILES")
        os.environ["LCARS_HOLODECK_AUDIT_MAX_FILES"] = "4"

    def tearDown(self):
        if self._old_cap is None:
            os.environ.pop("LCARS_HOLODECK_AUDIT_MAX_FILES", None)
        else:
            os.environ["LCARS_HOLODECK_AUDIT_MAX_FILES"] = self._old_cap
        HolodeckBase.tearDown(self)

    def test_a_truncated_audit_is_a_visible_state_not_a_silent_ok(self):
        self._set_turns({"stdout": "Wrote it.",
                         "writes": [{"path": "mockup.html", "content": "<b>x</b>"}]})
        _, body = self._post("/api/holodeck/start",
                             {"program": "Nav rail", "engine": self.claude_bin})
        sid = body["state"]["sessionId"]
        _, body = self._post("/api/holodeck/%s/say" % sid, {"text": "go"})
        st = body["state"]
        self.assertFalse(st["auditComplete"], st)
        # a consumer that only knows "ok" must NOT read this as a clean turn.
        self.assertNotEqual(st["status"], "ok", st)
        msg = st["warning"]["message"]
        self.assertIn("could not fully check", msg.lower())
        self.assertNotIn("Traceback", msg)
        # the work still landed and is still reported — a degraded fence is not
        # a reason to throw the captain's mockup away.
        self.assertTrue(any(f["path"].endswith("mockup.html")
                            for f in st["filesChanged"]), st)

    def _sidecar_status(self):
        """`git status --porcelain` inside the sidecar — empty means the turn's
        work is COMMITTED, not merely sitting on disk."""
        out = subprocess.run(["git", "-C", self._sidecar(), "status",
                              "--porcelain"], stdout=subprocess.PIPE,
                             stderr=subprocess.STDOUT)
        return out.stdout.decode().strip()

    def test_the_project_cap_never_truncates_the_holodecks_own_room(self):
        """DEFECT 1 (round 1, measured live). `_audit_cap()` fed ALL FOUR walks,
        so the cap that exists to bound the walk over the CAPTAIN'S PROJECT also
        truncated the walk over the sidecar — the program's own small room. With
        the cap forced low a real copilot design turn wrote `mockup.html`, the
        response carried `filesChanged: []`, and because `_sidecar_commit`
        no-ops on an empty list the file was left UNCOMMITTED — all under a
        warning claiming "everything the turn wrote in the holodeck is listed".
        """
        os.environ["LCARS_HOLODECK_AUDIT_MAX_FILES"] = "1"
        self._set_turns({"stdout": "Wrote it.",
                         "writes": [{"path": "mockup.html",
                                     "content": "<b>x</b>"},
                                    {"path": "notes.md", "content": "# n\n"}]})
        _, body = self._post("/api/holodeck/start",
                             {"program": "Nav rail", "engine": self.claude_bin})
        sid = body["state"]["sessionId"]
        _, body = self._post("/api/holodeck/%s/say" % sid, {"text": "go"})
        st = body["state"]
        # the STRAY check over the project is the thing that degraded...
        self.assertFalse(st["auditComplete"], st)
        self.assertNotEqual(st["status"], "ok", st)
        # ...and the turn's own output is listed anyway.
        names = sorted(os.path.basename(f["path"]) for f in st["filesChanged"])
        self.assertEqual(names, ["mockup.html", "notes.md"], st)
        # and COMMITTED. This is the half the empty list silently skipped.
        self.assertEqual(self._sidecar_status(), "")
        # and the copy does not claim a completeness the code cannot deliver.
        msg = st["warning"]["message"]
        self.assertNotIn("everything the turn wrote", msg.lower())
        self.assertIn("your project", msg.lower())
        self.assertIn("listed and saved", msg.lower())

    def test_the_two_caps_are_separate_knobs_and_say_different_things(self):
        """The other side of D1: a sidecar bound may exist, but it must be its
        OWN knob — and when IT is the walk that truncated, the message must say
        so instead of blaming the project walk."""
        from lcars_serve.actions import _audit_incomplete_message
        repo_only = _audit_incomplete_message(12, None)
        side_only = _audit_incomplete_message(None, 7)
        both = _audit_incomplete_message(12, 7)
        self.assertIn("listed and saved", repo_only.lower())
        self.assertIn("$LCARS_HOLODECK_AUDIT_MAX_FILES", repo_only)
        # a truncated SIDECAR walk must never be reported as a clean file list.
        self.assertNotIn("listed and saved", side_only.lower())
        self.assertIn("$LCARS_HOLODECK_SIDECAR_MAX_FILES", side_only)
        self.assertNotIn("your project", side_only.lower())
        self.assertIn("your project", both.lower())
        self.assertNotIn("listed and saved", both.lower())

    def test_a_complete_audit_carries_no_warning(self):
        """The other half of the calibration: with the cap raised, the SAME turn
        is a plain `ok` with no warning at all."""
        os.environ["LCARS_HOLODECK_AUDIT_MAX_FILES"] = "20000"
        self._set_turns({"stdout": "Wrote it.",
                         "writes": [{"path": "mockup.html", "content": "<b>x</b>"}]})
        _, body = self._post("/api/holodeck/start",
                             {"program": "Nav rail", "engine": self.claude_bin})
        sid = body["state"]["sessionId"]
        _, body = self._post("/api/holodeck/%s/say" % sid, {"text": "go"})
        st = body["state"]
        self.assertTrue(st["auditComplete"], st)
        self.assertEqual(st["status"], "ok", st)
        self.assertIsNone(st.get("warning"), st)


# ── 7e. grounding turn accounting + basis pollution (DEFECT 9) ───────────────
class GroundingAccountingTest(HolodeckBase):
    BASIS = "# Basis\n\n`--lcars-amber: #ff9c00` in board.css.\n"

    def _log(self):
        out = subprocess.run(["git", "-C", self._sidecar(), "log",
                              "--format=%s"], stdout=subprocess.PIPE,
                             stderr=subprocess.STDOUT)
        return out.stdout.decode().strip().splitlines()

    def test_the_grounding_pass_counts_as_turn_one(self):
        self._set_turns({"stdout": self.BASIS},
                        {"stdout": "It also has a pill radius."})
        _, body = self._post("/api/holodeck/start",
                             {"program": "Nav rail", "engine": self.claude_bin,
                              "mode": "grounding"})
        self.assertEqual(body["state"]["turnCount"], 1, body)
        sid = body["state"]["sessionId"]
        _, body = self._post("/api/holodeck/%s/say" % sid,
                             {"text": "what about radius?"})
        self.assertEqual(body["state"]["turnCount"], 2, body)
        # round 0 got TWO commits both labelled `turn 1`.
        subjects = [s for s in self._log() if "turn" in s]
        self.assertEqual(sorted(subjects),
                         ["holodeck(Nav rail): turn 1"], self._log())

    def test_a_grounding_follow_up_never_edits_the_durable_basis(self):
        """`basis.md` is the durable grounding artifact. Round 0 appended ANY
        grounding reply to it, so a refusal — real text, no grounding content —
        became a permanent `## Follow-up (turn 1)` section of the captain's
        design archive. The daemon cannot judge whether a reply is grounding or
        conversation, so the mechanical rule is: the OPENING pass writes the
        basis and nothing else ever touches it."""
        refusal = ("I won't attempt that write. My instructions for this task "
                   "are explicit: I am READ-ONLY. No file was created.")
        self._set_turns({"stdout": self.BASIS}, {"stdout": refusal})
        _, body = self._post("/api/holodeck/start",
                             {"program": "Nav rail", "engine": self.claude_bin,
                              "mode": "grounding"})
        sid = body["state"]["sessionId"]
        basis = os.path.join(body["state"]["programDir"], "basis.md")
        with open(basis) as fh:
            before = fh.read()
        self.assertIn("--lcars-amber", before)
        _, body = self._post("/api/holodeck/%s/say" % sid,
                             {"text": "now write GROUNDING_NOTE.md"})
        # the captain still SEES the refusal in the reply…
        self.assertIn("READ-ONLY", body["state"]["reply"])
        with open(basis) as fh:
            after = fh.read()
        # …but it is not in the archive.
        self.assertEqual(before, after)
        self.assertNotIn("Follow-up", after)
        self.assertNotIn("won't attempt", after)


# ── 8. read-only build ───────────────────────────────────────────────────────
class ReadOnlyTest(HolodeckBase):
    read_only = True

    def test_every_holodeck_route_403s_on_a_read_only_daemon(self):
        for path, body in (("/api/holodeck/start", {"program": "P"}),
                           ("/api/holodeck/abc/say", {"text": "hi"}),
                           ("/api/holodeck/abc/end", {})):
            st, resp = self._post_raw(path, body)
            self.assertEqual(st, 403, path)
            self.assertFalse(resp["ok"])
            self.assertIn("read-only", resp["error"])
        # and nothing was created.
        self.assertEqual(os.listdir(self.holo_root), [])


# ── 9. the Align grill is untouched ──────────────────────────────────────────
class AlignUntouchedTest(unittest.TestCase):
    """The holodeck copies the warm-turn PATTERN; it must never mutate it. The
    real regression guard is `tests.test_align_endpoints` staying green — this
    pins the two shapes the holodeck was most tempted to 'improve'."""

    def test_session_args_still_denies_tools_for_copilot_align(self):
        args = Actions._session_args("/x/bin/copilot", "abc-123", True)
        self.assertEqual(args, ["--session-id=abc-123", "--available-tools=",
                                "--no-ask-user", "--disable-builtin-mcps",
                                "--no-custom-instructions"])
        args = Actions._session_args("/x/bin/claude", "abc-123", False)
        self.assertEqual(args, ["--resume", "abc-123"])
        self.assertEqual(Actions._session_args("/x/bin/claude", None, True), [])


if __name__ == "__main__":
    unittest.main()

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
import re
import shlex
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
        # round 0 got TWO commits both labelled `turn 1`. Since S126 EVERY turn
        # commits (the exchange goes into transcript.md even when no file was
        # written) and the message carries the turn's own summary — so the
        # property to hold is that each commit names its OWN turn number, which
        # is what round 0 got wrong.
        subjects = [s for s in self._log() if "turn" in s]
        self.assertEqual(len(subjects), 2, self._log())
        nums = sorted(s.split("turn ", 1)[1].split(" ", 1)[0] for s in subjects)
        self.assertEqual(nums, ["1", "2"], self._log())
        self.assertTrue(any("grounding" in s for s in subjects), self._log())
        self.assertTrue(any("what about radius?" in s for s in subjects),
                        self._log())

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


# ════════════════════════════════════════════════════════════════════════════
# S126 — DURABLE PROGRAMS
#
# Everything below runs against a REAL git repo in a tmpdir (`git_bin` defaults
# to the real `git`, `holodeck_root` is injected at the sidecar's parent). That
# is deliberate: half of what this session is about is what the WORKING TREE
# does under two racing turns, and a stubbed git cannot see a dirty tree.
# ════════════════════════════════════════════════════════════════════════════
class DurableBase(HolodeckBase):
    """Helpers every S126 suite needs: real git reads over the sidecar."""

    def _git(self, *args):
        proc = subprocess.run([self.git_bin_path(), "-C", self._sidecar()]
                              + list(args),
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        return proc.returncode, (proc.stdout or b"").decode("utf-8", "replace")

    @staticmethod
    def git_bin_path():
        return shutil.which("git") or "git"

    def _log(self):
        _rc, out = self._git("log", "--format=%s")
        return [l for l in out.splitlines() if l.strip()]

    def _porcelain(self):
        _rc, out = self._git("status", "--porcelain")
        return [l for l in out.splitlines() if l.strip()]

    def _room(self, slug="nav-rail"):
        return os.path.join(self._sidecar(), slug)

    def _transcript(self, slug="nav-rail"):
        path = os.path.join(self._room(slug), "transcript.md")
        if not os.path.exists(path):
            return None
        with open(path) as fh:
            return fh.read()

    def _start(self, program="Nav rail", mode="design", engine=None):
        """`engine` defaults to claude. S126 fix round 4 made the on-disk
        strip PER-ENGINE, so a suite that only ever starts one CLI proves the
        rule for one CLI — every trace claim below names the engine it drove."""
        status, body = self._post("/api/holodeck/start",
                                  {"program": program, "mode": mode,
                                   "engine": engine or self.claude_bin})
        self.assertEqual(status, 200, body)
        return body["state"]["sessionId"], body["state"]

    def _list(self):
        url = "http://127.0.0.1:%d/api/holodeck" % self.port
        with urllib.request.urlopen(url, timeout=20) as r:
            return json.loads(r.read())

    def _get(self, path):
        url = "http://127.0.0.1:%d%s" % (self.port, path)
        with urllib.request.urlopen(url, timeout=20) as r:
            return json.loads(r.read())

    def _restart_daemon(self):
        """Stand up a SECOND daemon over the same sidecar root — the honest
        stand-in for a restart, because it shares nothing in memory.

        Lives here rather than on one suite because a restart is the event
        EVERY durable claim in S126 is about."""
        self.httpd.shutdown()
        self.httpd.server_close()
        self.thread.join(10)
        self.actions = Actions(repo_root=self.repo, scripts=self.scripts,
                               worker_bin=self.claude_bin,
                               holodeck_root=self.holo_root)
        self.httpd = make_server(self.adapter, host="127.0.0.1", port=0,
                                 poll_interval=0.05, actions=self.actions)
        self.port = self.httpd.server_address[1]
        self.thread = threading.Thread(target=self.httpd.serve_forever,
                                       daemon=True)
        self.thread.start()


# ── S126 #1 — the program's room IS the record ───────────────────────────────
class TranscriptOnDiskTest(DurableBase):
    """Every turn appends the exchange to `transcript.md` and commits the room.

    S125 already committed per turn (`_commit_turn`/`_sidecar_commit`) and the
    room already existed at `<sidecar>/<slug>/`. What was missing is the thing
    that makes the archive READABLE and REPLAYABLE: the conversation itself.
    """

    def test_every_turn_appends_the_exchange_to_the_transcript(self):
        self._set_turns({"stdout": "First pass is up.",
                         "writes": [{"path": "mockup.html", "content": "<h1>1"}]},
                        {"stdout": "Made it teal.",
                         "writes": [{"path": "mockup.html", "content": "<h1>2"}]})
        sid, _ = self._start()
        self._post("/api/holodeck/%s/say" % sid, {"text": "Draft a nav rail"})
        self._post("/api/holodeck/%s/say" % sid, {"text": "Make it teal"})
        text = self._transcript()
        self.assertIsNotNone(text, "no transcript.md in the program's room")
        # both sides of both exchanges, in the order they were said, once each.
        for fragment in ("Draft a nav rail", "First pass is up.",
                         "Make it teal", "Made it teal."):
            self.assertEqual(text.count(fragment), 1,
                             "%r appears %d times" % (fragment,
                                                      text.count(fragment)))
        self.assertLess(text.index("Draft a nav rail"), text.index("Make it teal"))
        # it names the program, so a room on disk can say what it is.
        self.assertIn("Nav rail", text)

    def test_each_turn_is_one_commit_whose_message_summarises_it(self):
        self._set_turns({"stdout": "Up.", "writes": [{"path": "mockup.html",
                                                      "content": "<h1>1"}]},
                        {"stdout": "Teal.", "writes": [{"path": "mockup.html",
                                                        "content": "<h1>2"}]})
        sid, _ = self._start()
        before = len(self._log())
        self._post("/api/holodeck/%s/say" % sid, {"text": "Draft a nav rail"})
        after_one = self._log()
        self.assertEqual(len(after_one) - before, 1, after_one)
        self._post("/api/holodeck/%s/say" % sid, {"text": "Make it teal"})
        log = self._log()
        self.assertEqual(len(log) - before, 2, log)
        # newest first: the message is a SUMMARY of the turn, not a serial number.
        self.assertIn("Make it teal", log[0])
        self.assertIn("Draft a nav rail", log[1])
        for line in log[:2]:
            self.assertIn("Nav rail", line)

    def test_a_turn_that_wrote_no_file_is_still_recorded_and_committed(self):
        """A conversational turn changes no mockup — and is still part of the
        program's story. Before this, `_sidecar_commit` returned early on an
        empty file list, so the exchange existed only in daemon memory."""
        self._set_turns({"stdout": "Amber reads warmer than teal here."})
        sid, _ = self._start()
        before = len(self._log())
        status, body = self._post("/api/holodeck/%s/say" % sid,
                                  {"text": "amber or teal?"})
        self.assertEqual(status, 200, body)
        self.assertEqual(body["state"]["status"], "ok")
        self.assertEqual(len(self._log()) - before, 1)
        text = self._transcript()
        self.assertIn("amber or teal?", text)
        self.assertIn("Amber reads warmer", text)

    def test_the_transcript_is_not_reported_as_a_file_the_worker_changed(self):
        """`filesChanged` is the WORKER's output, and the transcript is LCARS's
        own bookkeeping. Mixing them puts a `transcript.md` chip on every turn
        in the chat and makes the audit read as if the model wrote it."""
        self._set_turns({"stdout": "Built it.",
                         "writes": [{"path": "mockup.html", "content": "<h1>x"}]})
        sid, _ = self._start()
        _s, body = self._post("/api/holodeck/%s/say" % sid, {"text": "go"})
        self.assertEqual([c["path"] for c in body["state"]["filesChanged"]],
                         ["nav-rail/mockup.html"])

    def test_the_sidecar_is_left_clean_after_every_turn(self):
        self._set_turns({"stdout": "Built it.",
                         "writes": [{"path": "mockup.html", "content": "<h1>x"}]},
                        {"stdout": "Just talking."})
        sid, _ = self._start()
        self._post("/api/holodeck/%s/say" % sid, {"text": "go"})
        self.assertEqual(self._porcelain(), [])
        self._post("/api/holodeck/%s/say" % sid, {"text": "and?"})
        self.assertEqual(self._porcelain(), [])

    def test_a_retried_line_is_written_to_the_transcript_once(self):
        """S125's N6 rule, carried onto disk: a turn that DIED and was retried
        is the same turn. A transcript that records the captain saying it twice
        is a durable version of the defect S125 cured in memory."""
        self._set_turns({"stdout": "boom", "exit": 1},
                        {"stdout": "Second time worked.",
                         "writes": [{"path": "mockup.html", "content": "<h1>x"}]})
        sid, _ = self._start()
        st, _b = self._post_raw("/api/holodeck/%s/say" % sid,
                                {"text": "Draft a nav rail"})
        self.assertEqual(st, 502)
        self._post("/api/holodeck/%s/say" % sid, {"text": "Draft a nav rail"})
        text = self._transcript()
        self.assertEqual(text.count("Draft a nav rail"), 1, text)
        self.assertIn("Second time worked.", text)

    def test_the_grounding_pass_is_recorded_as_the_turn_it_is(self):
        self._set_turns({"stdout": "Tokens: --lcars-amber #ff9c00 (board.css)"})
        sid, _ = self._start("Nav rail", mode="grounding")
        text = self._transcript()
        self.assertIsNotNone(text)
        self.assertIn("--lcars-amber", text)
        self.assertIn("grounding", text.lower())
        self.assertIn("grounding", self._log()[0].lower())


# ── S126 #6 — the engine's tool trace never becomes DURABLE content ──────────
# The chat pane FOLDS the trace (S125: a misclassification costs a click). A
# FILE cannot fold, and these two files are read by a person and by the next
# worker: `transcript.md` is replayed into a warm restart's opening prompt and
# `basis.md` is what the design turns are built from, so a `└ 3 files found`
# in either is a durable instruction to nobody.
#
# FIX ROUND 4 — THE CORPUS IS THE ENGINES' OWN BYTES, NOT AN INVENTED FIXTURE.
# Rounds 1–3 all sharpened a recognizer that guessed which lines were plumbing
# from their SHAPE, and every round's fixtures were written by hand. A live
# drive on both real CLIs (2026-08-05) measured that rule wrong in BOTH
# directions, and the raw replies it produced are committed verbatim under
# `web/tests/fixtures/s126-live/`. Every claim in this section is measured
# against those bytes: inventing the corpus is exactly how the old rule came to
# model a copilot version that no longer exists.
_LIVE_FIXTURES = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                              "fixtures", "s126-live")


def _live(name):
    with open(os.path.join(_LIVE_FIXTURES, name)) as fh:
        return fh.read()


# ── the KNOWN MISSES, measured — every line here was DESTROYED on a real drive
# On BOTH engines the captain asked for a terse next-turn checklist in `●`
# bullets ("verb then the file, nothing else" — his words) and got one. The old
# rule could not tell that from a tool call, and deleted it off his transcript
# with nothing on screen saying so.
#
# claude wrote five (`claude-checklist-reply.txt`); two survived.
CLAUDE_CHECKLIST_DESTROYED = ["● Read mockup.html",
                              "● Update mockup.html",
                              "● Update concept.md"]
CLAUDE_CHECKLIST_SURVIVED = ["● Measure mockup.html", "● Preview mockup.html"]
# copilot wrote three (`copilot-checklist-reply.txt`); one survived.
COPILOT_CHECKLIST_DESTROYED = ["● Update mockup.html", "● Update concept.md"]
COPILOT_CHECKLIST_SURVIVED = ["● Verify mockup.html"]

# The prose-shaped bullets from the earlier rounds' hand-written corpus. They
# are kept because each one is a family the round-1 rule tripped on, and they
# must still survive — now on BOTH engines, which is the half round 1a's
# single-engine corpus could not see.
KNOWN_MISSES = [
    # (a) a filename in a sentence — the normal way to name a token file
    "● Read tokens.css before you pick an accent.",
    # (b) a parenthetical aside
    "● Move the swatches (they are too tight).",
    # (c) a quoted label — the normal way to write UI copy
    '● Write "collapsed" under the rail icon.',
    # (d) a backticked label
    "● Edit the label to read `SWATCHES`.",
    # (e) a filename, then more sentence
    "● Read board.css and copy the amber into the rail.",
    # (f) a `+N` token that is a spacing value, not a diff counter
    "● Delete the +2 spacing rule; it doubles the gap.",
] + CLAUDE_CHECKLIST_DESTROYED + COPILOT_CHECKLIST_DESTROYED

# What copilot's CLI ACTUALLY prints, lifted byte for byte out of
# `copilot-grounding-reply.txt`. Two forms and no third: a head bullet with its
# two-space-indented `│` argument rows and the `└` row that closes the block,
# and a write's one-line activity row carrying the CLI's diff counters.
COPILOT_TOOL_BLOCKS = ("● List directory .\n"
                       "  └ 15 files found\n"
                       "\n"
                       "/ Search (glob)\n"
                       '  │ "web/**/*.{css,scss,html,js,ts,jsx,tsx,vue,svelte}"\n'
                       "  └ 18 files found\n"
                       "\n"
                       "● Read board.css\n"
                       "  │ web/static/board.css\n"
                       "  └ L1:200 (200 lines read)\n"
                       "\n"
                       "● Edit mockup.html +8 -6\n")

# The shape the old rule modelled — one-line `●` calls with an unindented `└`
# under them. Kept as CLAUDE_TRACE for the tests that still name it, because
# the measured claude posture emits NO trace at all and this is now simply
# text that must survive claude untouched.
CLAUDE_TRACE = ("● List directory .\n"
                "└ 3 files found\n"
                "● Read board.css\n"
                "  └ 214 lines\n"
                "● Create mockup.html +68\n")


class LiveCorpusTest(DurableBase):
    """The engines' own bytes, replayed through the stripper.

    This class is the round's floor: if it and the product both go green on
    invented fixtures but red here, the fixtures were the problem."""

    def _strip(self, text, engine):
        from lcars_serve.actions import _strip_tool_trace
        return _strip_tool_trace(text, engine)

    # -- claude: measured to emit NO trace, so the strip is pure subtraction --
    def test_every_captured_claude_reply_survives_byte_for_byte(self):
        """MEASURED, not assumed: over a 107-line grounding pass, a turn with
        an ASCII diagram, and a checklist turn, claude's raw stdout IS what
        belongs on disk. Any deletion here is a loss and can never be a gain."""
        for name in ("claude-grounding-reply.txt", "claude-diagram-reply.txt",
                     "claude-checklist-reply.txt"):
            text = _live(name)
            self.assertEqual(self._strip(text, self.claude_bin),
                             text.strip("\n"), name)

    def test_the_claude_checklist_the_old_rule_destroyed_is_whole(self):
        text = _live("claude-checklist-reply.txt")
        got = self._strip(text, self.claude_bin)
        for line in CLAUDE_CHECKLIST_DESTROYED + CLAUDE_CHECKLIST_SURVIVED:
            self.assertIn(line, got, line)

    # -- copilot: its CLI changed shape, so the block parser is the cure -----
    def test_the_copilot_checklist_the_old_rule_destroyed_is_whole(self):
        text = _live("copilot-checklist-reply.txt")
        got = self._strip(text, self.copilot_bin)
        for line in COPILOT_CHECKLIST_DESTROYED + COPILOT_CHECKLIST_SURVIVED:
            self.assertIn(line, got, line)

    def test_a_real_grounding_basis_has_no_plumbing_left_in_it(self):
        """THE 58. The old rule saw only the one-line `●` shape, so 58 of the
        193 lines of a real `basis.md` were leftover CLI rows. Counted, not
        spot-checked, so a partial cure cannot read as a whole one."""
        got = self._strip(_live("copilot-grounding-reply.txt"),
                          self.copilot_bin).split("\n")
        left = [l for l in got
                if l.startswith(("● ", "/ ", "  │ ", "  └ "))]
        self.assertEqual(left, [], "%d CLI rows survived into basis.md" % len(left))

    def test_the_real_grounding_prose_is_all_still_there(self):
        """The calibration's other half: the same reply's PROSE, byte for
        byte and in order. Without this, a stripper that ate the whole file
        would pass the check above."""
        src = _live("copilot-grounding-reply.txt").split("\n")
        prose = [l for l in src
                 if l.strip() and not l.startswith(("● ", "/ ", "  │ ", "  └ "))]
        got = [l for l in self._strip(_live("copilot-grounding-reply.txt"),
                                      self.copilot_bin).split("\n") if l.strip()]
        self.assertEqual(got, prose)

    def test_a_copilot_turn_keeps_its_diagram_and_its_notes(self):
        """The whole turn, as copilot printed it: nine `● Edit …` activity
        rows (trace), a fenced ASCII diagram whose rows use the SAME `  │`
        indent the CLI's argument rows use, and four `●` design notes the
        captain dictated the style of."""
        got = self._strip(_live("copilot-turn-raw.txt"), self.copilot_bin)
        for note in ("● Move the switch (it crowds the version pill at 1280px)",
                     "● Read board.css before you touch --frame-color",
                     '● The label reads "AUTO", not "Auto"',
                     "● Bash the cross-fade — delete it, don't gate it"):
            self.assertIn(note, got, note)
        for row in ("  │  <head>",
                    "  │    │  1. NO-FLASH SCRIPT  (inline, blocking)        │◀──┐   │",
                    "  └─────────────────────────────────────────────────────────────┘"):
            self.assertIn(row, got, row)
        # …and the trace it DID carry is gone. Both halves or neither proves.
        for gone in ("● Edit mockup.html +8 -6", "● Edit concept.md +9"):
            self.assertNotIn(gone, got, gone)

    def test_a_pasted_copilot_block_inside_a_fence_is_content(self):
        """A fence is the captain quoting, not the CLI speaking. Measured in
        the corpus: copilot's own diagrams arrive fenced and their rows share
        the continuation indent exactly."""
        text = ("Here is what it printed at me:\n\n"
                "```\n" + COPILOT_TOOL_BLOCKS + "```\n\n"
                "Why is it reading board.css twice?\n")
        self.assertEqual(self._strip(text, self.copilot_bin), text.strip("\n"))

    def test_only_a_copilot_tool_block_can_ever_be_removed(self):
        """The GUARANTEE, stated structurally rather than by example. Whatever
        the input, a line this dropped came out of a run whose LAST row was the
        CLI's own `  └ ` result row, or was a one-line write activity row
        ending in diff counters. Nothing else can be lost."""
        from lcars_serve.actions import (_COPILOT_ARG_ROW, _COPILOT_BLOCK_HEAD,
                                         _COPILOT_RESULT_ROW,
                                         _COPILOT_WRITE_ROW)
        corpus = "\n".join([_live("copilot-grounding-reply.txt"),
                            _live("copilot-turn-raw.txt"),
                            _live("copilot-checklist-reply.txt"),
                            "\n".join(KNOWN_MISSES), CLAUDE_TRACE])
        kept = set(self._strip(corpus, self.copilot_bin).split("\n"))
        for line in corpus.split("\n"):
            if line in kept or not line.strip():
                continue
            self.assertTrue(
                _COPILOT_WRITE_ROW.match(line) or _COPILOT_BLOCK_HEAD.match(line)
                or _COPILOT_ARG_ROW.match(line) or _COPILOT_RESULT_ROW.match(line),
                "dropped a line that is not part of a copilot tool block: %r"
                % line)

    def test_the_known_misses_survive_on_both_engines(self):
        """The old rule's damage, run through both paths. One engine's corpus
        proves one engine — round 1a's did, and the copilot half was the half
        that had rotted."""
        for engine in (self.claude_bin, self.copilot_bin):
            for note in KNOWN_MISSES:
                self.assertEqual(self._strip(note, engine), note,
                                 "%s: %s" % (os.path.basename(engine), note))
            block = "\n".join(KNOWN_MISSES)
            got = self._strip(block, engine)
            for note in KNOWN_MISSES:
                self.assertIn(note, got, note)


class PersistedProseTest(DurableBase):
    """What lands on disk is the conversation, not the engine's plumbing."""

    # -- the recognizer itself, on both engines' recorded shapes -------------
    def test_a_claude_reply_reaches_disk_untouched(self):
        """THE MEASUREMENT, as a rule: claude emits no tool trace in this
        posture, so the stripper takes nothing from it. If claude ever starts
        emitting trace the cost is leftover noise in a file — an annoyance —
        and never a deleted design decision, which is unrecoverable."""
        from lcars_serve.actions import _strip_tool_trace
        text = CLAUDE_TRACE + "\nBuilt the rail.\n"
        self.assertEqual(_strip_tool_trace(text, self.claude_bin),
                         text.strip("\n"))

    def test_the_copilot_block_shape_is_recognized_as_trace(self):
        """`_clean_reply` deliberately KEEPS copilot's per-tool activity line —
        it is the engine's own account and belongs in the chat. On disk it is
        plumbing."""
        from lcars_serve.actions import _clean_reply, _strip_tool_trace
        raw = (COPILOT_PREAMBLE + COPILOT_ACTIVITY
               + "The rail is up. Refresh.\n" + COPILOT_FOOTER)
        chat = _clean_reply(raw)
        self.assertIn("● Create mockup.html +27", chat)
        self.assertEqual(_strip_tool_trace(chat, self.copilot_bin),
                         "The rail is up. Refresh.")
        self.assertEqual(
            _strip_tool_trace(COPILOT_TOOL_BLOCKS + "\nThe rail is up.\n",
                              self.copilot_bin),
            "The rail is up.")

    def test_an_unknown_engine_is_treated_as_the_safe_one(self):
        """No engine, or a CLI nobody has measured, strips NOTHING — the same
        direction the rest of the daemon already defaults in (`_is_copilot`)."""
        from lcars_serve.actions import _strip_tool_trace
        text = COPILOT_TOOL_BLOCKS + "\nThe rail is up.\n"
        for engine in (None, "", "/usr/local/bin/some-new-cli"):
            self.assertEqual(_strip_tool_trace(text, engine), text.strip("\n"))

    def test_a_captains_ascii_diagram_is_never_touched(self):
        """S125 fix round 3's defect, as a disk-side regression guard: a
        continuation glyph standing alone is somebody drawing a box."""
        from lcars_serve.actions import _strip_tool_trace
        drawing = ("Here is the shape I have in mind:\n\n"
                   "┌────────────┐\n"
                   "│  SWATCHES  │\n"
                   "├────────────┤\n"
                   "│  PREVIEW   │\n"
                   "└────────────┘\n")
        for engine in (self.claude_bin, self.copilot_bin):
            self.assertEqual(_strip_tool_trace(drawing, engine),
                             drawing.rstrip("\n"))

    def test_a_bulleted_design_note_is_prose_not_trace(self):
        from lcars_serve.actions import _strip_tool_trace
        for keep in ("● Read the swatch labels before you decide the accent.",
                     "● Update the radius only if the swatches move.",
                     "● Create a second state only when he asks for one",
                     "◆ Move the rail left and the preview grows."):
            for engine in (self.claude_bin, self.copilot_bin):
                self.assertEqual(_strip_tool_trace(keep, engine), keep)

    def test_nothing_that_is_not_trace_loses_a_character(self):
        """The calibration: a known STRIP and a known KEEP, and the kept lines
        byte-identical. Without both halves a stripper that removes nothing and
        one that removes everything read exactly the same."""
        from lcars_serve.actions import _strip_tool_trace
        prose = ["# Tile picker",
                 "",
                 "Built it with **two** states and a `rail` class.",
                 "",
                 "│ this line is a drawing, not a tool call",
                 "",
                 "- collapsed, 56px",
                 "- expanded, 216px"]
        mixed = COPILOT_TOOL_BLOCKS + "\n".join(prose)
        got = _strip_tool_trace(mixed, self.copilot_bin).split("\n")
        self.assertEqual([l for l in got if l.strip()],
                         [l for l in prose if l.strip()])
        # …and a result row that is NOT under a head of the CLI's own is a
        # drawing, and is kept.
        after = "Built the rail.\n  └ this is the bottom of my sketch\n"
        self.assertEqual(_strip_tool_trace(after, self.copilot_bin),
                         after.rstrip("\n"))

    # -- and now the two files it is applied to ------------------------------
    def test_the_transcript_carries_the_prose_and_not_the_trace(self):
        self._set_turns({"stdout": COPILOT_TOOL_BLOCKS + "\nBuilt the rail.\n",
                         "writes": [{"path": "mockup.html", "content": "<h1>1"}]})
        sid, _ = self._start(engine=self.copilot_bin)
        self._post("/api/holodeck/%s/say" % sid, {"text": "Draft a nav rail"})
        text = self._transcript()
        self.assertIn("Built the rail.", text)
        for leak in ("List directory", "15 files found", "Search (glob)",
                     "L1:200", "Edit mockup.html"):
            self.assertNotIn(leak, text)

    def test_the_basis_carries_the_prose_and_not_the_trace(self):
        self._set_turns({"stdout": COPILOT_TOOL_BLOCKS
                         + "\n## Colour\n\n- `--lcars-amber` #ff9c00\n"})
        self._start("Nav rail", mode="grounding", engine=self.copilot_bin)
        with open(os.path.join(self._room(), "basis.md")) as fh:
            basis = fh.read()
        self.assertIn("--lcars-amber", basis)
        for leak in ("List directory", "15 files found", "Search (glob)",
                     "Edit mockup.html"):
            self.assertNotIn(leak, basis)

    def test_a_claude_transcript_keeps_every_line_the_model_wrote(self):
        """The measured half. A claude turn's reply reaches the record whole —
        including the five-line checklist the old rule took three lines out
        of."""
        self._set_turns({"stdout": _live("claude-checklist-reply.txt"),
                         "writes": [{"path": "mockup.html", "content": "<h1>1"}]})
        sid, _ = self._start()
        self._post("/api/holodeck/%s/say" % sid, {"text": "Give me a checklist"})
        text = self._transcript()
        for line in CLAUDE_CHECKLIST_DESTROYED + CLAUDE_CHECKLIST_SURVIVED:
            self.assertIn(line, text, line)

    def test_the_chat_still_gets_the_trace_it_folds(self):
        """The two surfaces are cured in DIFFERENT places on purpose. The chat
        folds (recoverable by a click); only the FILE strips. A cure in
        `_clean_reply` would have taken the fold's contents away with it."""
        self._set_turns({"stdout": COPILOT_TOOL_BLOCKS + "\nBuilt the rail.\n"})
        sid, _ = self._start(engine=self.copilot_bin)
        _s, body = self._post("/api/holodeck/%s/say" % sid, {"text": "go"})
        self.assertIn("● List directory .", body["state"]["reply"])
        self.assertIn("  └ 15 files found", body["state"]["reply"])

    def test_a_warm_restart_replays_prose_not_plumbing(self):
        """The transcript IS the next worker's context section, so trace on
        disk is trace in the prompt — the durable half of this defect."""
        self._set_turns({"stdout": COPILOT_TOOL_BLOCKS + "\nBuilt the rail.\n",
                         "writes": [{"path": "mockup.html", "content": "<h1>1"}]},
                        {"stdout": "Reopened."})
        sid, _ = self._start(engine=self.copilot_bin)
        self._post("/api/holodeck/%s/say" % sid, {"text": "Draft a nav rail"})
        self._post("/api/holodeck/%s/end" % sid, {})
        status, body = self._post("/api/holodeck/open",
                                  {"room": "nav-rail", "engine": self.copilot_bin})
        self.assertEqual(status, 200, body)
        sid2 = body["state"]["sessionId"]
        self._post("/api/holodeck/%s/say" % sid2, {"text": "carry on"})
        prompt = self._prompts()[-1]
        self.assertIn("Built the rail.", prompt)
        for leak in ("List directory", "15 files found", "Edit mockup.html"):
            self.assertNotIn(leak, prompt)

    def test_a_basis_that_is_ALL_trace_is_kept_whole_rather_than_emptied(self):
        """The one place the strip yields. An empty `basis.md` breaks D12's
        chip and hands the design turns nothing; a reply the recognizer ate
        ENTIRELY is far likelier to be a misclassification than a grounding
        pass that reported nothing. Keep, and let the captain see it."""
        self._set_turns({"stdout": COPILOT_TOOL_BLOCKS})
        self._start("Nav rail", mode="grounding", engine=self.copilot_bin)
        with open(os.path.join(self._room(), "basis.md")) as fh:
            basis = fh.read()
        self.assertIn("List directory", basis)


# ── FIX ROUND 4 — THE KNOWN MISSES, ON DISK ──────────────────────────────────
# The classes above prove the recognizer. These drive the same corpus through
# the two FILES, because a cure in the helper that never reaches `transcript.md`
# is not a cure (S156's lesson: encode the KNOWN MISSES or the number lies).
ENGINE_ACTIVITY_THEN_DRAWING = (
    "● Create mockup.html +27\n"
    "│  SWATCHES  │\n"
    "├────────────┤\n"
    "│  PREVIEW   │\n"
    "└────────────┘\n"
    "\n"
    + "\n".join(KNOWN_MISSES[:4]) + "\n"
    "\n"
    "That is the layout I settled on.\n")


class ProseLossKnownMissesTest(DurableBase):
    """The captain's own words, in the shapes a DESIGN chat actually uses."""

    def test_every_known_miss_survives_byte_for_byte(self):
        from lcars_serve.actions import _strip_tool_trace
        for engine in (self.claude_bin, self.copilot_bin):
            for note in KNOWN_MISSES:
                self.assertEqual(_strip_tool_trace(note, engine), note, note)

    def test_the_known_misses_survive_inside_a_reply_too(self):
        """One at a time is the easy case. In a real reply they arrive in a
        block, directly under the engine's activity line — which is where the
        run-continuation half of the defect lives."""
        from lcars_serve.actions import _strip_tool_trace
        for engine in (self.claude_bin, self.copilot_bin):
            got = _strip_tool_trace("● Create mockup.html +27\n"
                                    + "\n".join(KNOWN_MISSES)
                                    + "\nThat is the layout I settled on.\n",
                                    engine)
            for note in KNOWN_MISSES:
                self.assertIn(note, got, note)
            self.assertIn("That is the layout I settled on.", got)

    def test_a_drawing_directly_under_an_activity_line_is_kept_whole(self):
        """The common case, not a rare one: copilot prints
        `● Create mockup.html +27` immediately above what it has to say."""
        from lcars_serve.actions import _strip_tool_trace
        got = _strip_tool_trace(ENGINE_ACTIVITY_THEN_DRAWING, self.copilot_bin)
        for row in ("│  SWATCHES  │", "├────────────┤", "│  PREVIEW   │",
                    "└────────────┘"):
            self.assertIn(row, got, row)

    def test_the_activity_line_is_still_stripped(self):
        """The calibration's other half. Without a known STRIP beside the
        known KEEPs, a recognizer that removes nothing reads as a cure."""
        from lcars_serve.actions import _strip_tool_trace
        got = _strip_tool_trace(ENGINE_ACTIVITY_THEN_DRAWING, self.copilot_bin)
        self.assertNotIn("● Create mockup.html +27", got)
        self.assertEqual(
            _strip_tool_trace(COPILOT_TOOL_BLOCKS + "\nBuilt it.\n",
                              self.copilot_bin), "Built it.")

    def test_a_result_row_never_carries_the_run_past_prose(self):
        """`  └ 15 files found` is the row that CLOSES a block. `└────────┘` is
        the bottom of a box: it is not the CLI's own row, so nothing after it is
        swallowed."""
        from lcars_serve.actions import _strip_tool_trace
        text = ("● Read board.css\n"
                "  │ web/static/board.css\n"
                "  └ L1:200 (200 lines read)\n"
                "┌────────────┐\n"
                "│  SWATCHES  │\n"
                "└────────────┘\n"
                "Use that grid.\n")
        got = _strip_tool_trace(text, self.copilot_bin)
        self.assertNotIn("L1:200", got)
        for row in ("┌────────────┐", "│  SWATCHES  │", "└────────────┘",
                    "Use that grid."):
            self.assertIn(row, got, row)

    def test_a_sentence_bullet_inside_a_proven_run_still_survives(self):
        """A run does not become a licence to delete the next bullet that
        happens to start with a verb."""
        from lcars_serve.actions import _strip_tool_trace
        got = _strip_tool_trace("● Read board.css\n"
                                "  │ web/static/board.css\n"
                                "  └ L1:200 (200 lines read)\n"
                                "● Move the swatches (they are too tight).\n",
                                self.copilot_bin)
        self.assertNotIn("L1:200", got)
        self.assertIn("● Move the swatches (they are too tight).", got)

    def test_a_sentence_under_a_removed_tool_line_survives(self):
        """FIX ROUND 3's known miss, carried forward. A ONE-ENTRY file tree is
        what an engine draws directly under its own `● List directory .`, and
        that row is exactly where the captain annotates what he found."""
        from lcars_serve.actions import _strip_tool_trace
        note = "└ tokens.css — the only file, and the accent lives in it"
        note2 = "⎿ keep this one; it is the only swatch that reads at 12px"
        for engine in (self.claude_bin, self.copilot_bin):
            got = _strip_tool_trace("● List directory .\n" + note + "\n", engine)
            self.assertIn(note, got, note)
            got2 = _strip_tool_trace("● Read board.css\n" + note2 + "\n", engine)
            self.assertIn(note2, got2, note2)

    def test_the_other_bullet_glyphs_are_never_trace(self):
        """`⏺` and `◆` were inside the old verb rule and are outside the new
        one entirely: neither CLI prints them, so a line opening with one is
        somebody writing. Carried forward from the round-1a guarantee corpus,
        with the two verb-shaped bullets that rule KEPT only by accident."""
        from lcars_serve.actions import _strip_tool_trace
        for keep in ("⏺ Read", "◆ Copy the rail into the second state.",
                     "● Bash npm run build", "● Search for the amber token",
                     "Plain prose with (parens), a `tick` and board.css in it."):
            for engine in (self.claude_bin, self.copilot_bin):
                self.assertEqual(_strip_tool_trace(keep, engine), keep, keep)

    def test_a_head_with_no_result_row_under_it_is_prose(self):
        """FIX ROUND 4. The `  └ ` row is REQUIRED, and that requirement is what
        lets the parser be structural instead of clever: a bullet the CLI never
        closed is a captain writing, whatever verb he opened with."""
        from lcars_serve.actions import _strip_tool_trace
        text = ("● Read board.css before you touch --frame-color\n"
                "  │ it is the only place the gold is spelled out\n")
        self.assertEqual(_strip_tool_trace(text, self.copilot_bin),
                         text.rstrip("\n"))

    def test_a_note_ABOVE_a_sketch_row_survives_too(self):
        """The hole a bare LOOKAHEAD would open. A `└` under a bullet is only a
        result row when it is the CLI's own — two-space indent, closing a head
        the CLI printed. The captain's sketch row is neither."""
        from lcars_serve.actions import _strip_tool_trace
        text = ("● Move the swatches (they are too tight).\n"
                "└ and tuck the caption under here\n")
        for engine in (self.claude_bin, self.copilot_bin):
            self.assertEqual(_strip_tool_trace(text, engine), text.rstrip("\n"))

    # -- and the same corpus through the two FILES it is applied to ----------
    def test_the_transcript_keeps_the_known_misses(self):
        self._set_turns({"stdout": ENGINE_ACTIVITY_THEN_DRAWING,
                         "writes": [{"path": "mockup.html", "content": "<h1>x"}]})
        sid, _ = self._start(engine=self.copilot_bin)
        self._post("/api/holodeck/%s/say" % sid, {"text": "Draw me the layout."})
        text = self._transcript()
        for note in KNOWN_MISSES[:4]:
            self.assertIn(note, text, note)
        self.assertIn("│  SWATCHES  │", text)
        self.assertNotIn("● Create mockup.html +27", text)

    def test_the_basis_keeps_the_known_misses(self):
        self._set_turns({"stdout": "# Basis\n\n"
                                   + "\n\n".join(KNOWN_MISSES)
                                   + "\n\nEnd of basis.\n"})
        self._start("Nav rail", mode="grounding", engine=self.copilot_bin)
        with open(os.path.join(self._room(), "basis.md")) as fh:
            basis = fh.read()
        for note in KNOWN_MISSES:
            self.assertIn(note, basis, note)


# ── FIX ROUND 4 — A PROGRAM'S RECORD NAMES ONLY ITS OWN FILES ────────────────
# Measured on the live drive, and only reproducible with two programs open at
# once — which no stubbed round had exercised. The Theme Switcher's
# `transcript.md` permanently recorded
#   `_Files this turn: command-palette/basis.md, command-palette/transcript.md,
#    concept.md, mockup.html_`
# — two of those belong to the OTHER room. The turn's git commit is correctly
# scoped (`git add -- <room>`), so nothing on disk was wrong; the durable
# record simply lied about who did what, forever.
class TranscriptNamesOnlyItsOwnFilesTest(DurableBase):

    def _files_line(self, slug):
        text = self._transcript(slug) or ""
        rows = [l for l in text.split("\n") if l.startswith("_Files this turn:")]
        return rows[-1] if rows else ""

    def test_a_concurrent_programs_files_never_enter_the_record(self):
        self._set_turns(
            {"stdout": "A.", "writes": [{"path": "mockup.html", "content": "a"}]},
            # B's turn writes into B's room AND, because the audit diffs the
            # WHOLE sidecar, A's room is in the same snapshot window.
            {"stdout": "B.", "writes": [{"path": "mockup.html", "content": "b"},
                                        {"path": "../nav-rail/concept.md",
                                         "content": "# stolen"}]})
        sid_a, _ = self._start("Nav rail")
        sid_b, _ = self._start("Tile picker")
        self._post("/api/holodeck/%s/say" % sid_a, {"text": "go"})
        self._post("/api/holodeck/%s/say" % sid_b, {"text": "go"})
        line = self._files_line("tile-picker")
        self.assertIn("mockup.html", line)
        self.assertNotIn("nav-rail", line,
                         "Tile picker's record claims Nav rail's files: %r"
                         % line)

    def test_the_programs_own_files_are_all_still_named(self):
        """The other half: narrowing the list must not start dropping the
        program's own multi-file turn."""
        self._set_turns({"stdout": "Built it.",
                         "writes": [{"path": "mockup.html", "content": "<h1>x"},
                                    {"path": "assets/rail.svg", "content": "<svg/>"},
                                    {"path": "concept.md", "content": "# c"}]})
        sid, _ = self._start("Nav rail")
        self._post("/api/holodeck/%s/say" % sid, {"text": "go"})
        line = self._files_line("nav-rail")
        for rel in ("mockup.html", "assets/rail.svg", "concept.md"):
            self.assertIn(rel, line, rel)


# ── FIX ROUND 1a — a transcript that could NOT be written says so ────────────
class TranscriptWriteFailureTest(DurableBase):
    """The whole promise of this round is "your work is on disk". This is the
    one path where the conversation is NOT, and round 1 returned `ok`."""

    def _block_the_transcript(self):
        # a DIRECTORY where the file goes: `open(path, "a")` raises
        # IsADirectoryError (an OSError) exactly as a full disk or a bad
        # permission would, with no monkeypatching of the daemon.
        #
        # FIX ROUND 2 — the file now EXISTS from the moment the program is
        # named (defect 4: that heading is where the captain's name lives), so
        # it is removed first. The blockage this sets up, and every assertion
        # below it, is unchanged.
        path = os.path.join(self._room(), "transcript.md")
        if os.path.isfile(path):
            os.unlink(path)
        os.makedirs(path, exist_ok=True)

    def test_a_transcript_that_cannot_be_written_is_not_reported_as_ok(self):
        self._set_turns({"stdout": "Built the rail.",
                         "writes": [{"path": "mockup.html", "content": "<h1>x"}]})
        sid, _ = self._start()
        self._block_the_transcript()
        _s, body = self._post("/api/holodeck/%s/say" % sid, {"text": "go"})
        state = body["state"]
        self.assertNotEqual(state["status"], "ok", state)
        warn = state.get("warning")
        self.assertTrue(warn, "a silent transcript failure: %r" % (state,))
        low = (warn.get("message") or "").lower()
        # names the file, says the design work itself is safe, and never leaks
        # a stack trace or a python exception class at the captain.
        self.assertIn("transcript", low)
        self.assertIn("mockup", low)
        for jargon in ("traceback", "oserror", "errno", "isadirectory"):
            self.assertNotIn(jargon, low, jargon)

    def test_the_turn_still_keeps_the_work_that_did_land(self):
        """Best-effort stays best-effort: a filesystem hiccup must not throw
        away a mockup that was written."""
        self._set_turns({"stdout": "Built the rail.",
                         "writes": [{"path": "mockup.html", "content": "<h1>x"}]})
        sid, _ = self._start()
        self._block_the_transcript()
        st, body = self._post_raw("/api/holodeck/%s/say" % sid, {"text": "go"})
        self.assertEqual(st, 200, body)
        self.assertTrue(os.path.isfile(os.path.join(self._room(),
                                                    "mockup.html")))

    def test_a_healthy_turn_carries_no_transcript_warning(self):
        """The control. Without it, a daemon that warns on EVERY turn would
        pass the two tests above."""
        self._set_turns({"stdout": "Built the rail.",
                         "writes": [{"path": "mockup.html", "content": "<h1>x"}]})
        sid, _ = self._start()
        _s, body = self._post("/api/holodeck/%s/say" % sid, {"text": "go"})
        self.assertEqual(body["state"]["status"], "ok", body["state"])
        self.assertIsNone(body["state"].get("warning"))

    # ── FIX ROUND 2 — a turn that was BOTH refused AND unrecorded ────────────
    # `refused` outranks every other status and the surface renders that branch
    # alone, so a turn that also lost its transcript said nothing about it: the
    # captain would never learn his conversation was not recorded. The account
    # of what happened is composed HERE, in one voice, the way the warning path
    # already appends rather than overwrites.
    def test_a_refused_turn_that_also_lost_the_transcript_says_BOTH(self):
        stray = os.path.join(self.repo, "src", "stolen.html")
        self._set_turns({"stdout": "Done (I put it in your project).",
                         "writes": [{"path": stray, "content": "<h1>nope"},
                                    {"path": "mockup.html", "content": "<h1>x"}]})
        sid, _ = self._start()
        self._block_the_transcript()
        _s, body = self._post("/api/holodeck/%s/say" % sid, {"text": "go"})
        state = body["state"]
        self.assertEqual(state["status"], "refused", state)
        msg = state["refused"]["message"]
        low = msg.lower()
        # the refusal is still the whole refusal…
        self.assertIn(stray, msg)
        self.assertIn("cannot tell", low)
        # …and the captain is still told the conversation was not recorded.
        self.assertIn("transcript.md", msg)
        self.assertFalse(state.get("transcriptWritten", True), state)
        for jargon in ("traceback", "oserror", "errno", "isadirectory"):
            self.assertNotIn(jargon, low, jargon)

    def test_a_refused_turn_whose_transcript_WAS_written_says_only_that(self):
        """The control: the refusal must not grow a transcript sentence when
        nothing went wrong with the transcript."""
        stray = os.path.join(self.repo, "src", "stolen.html")
        self._set_turns({"stdout": "Done (I put it in your project).",
                         "writes": [{"path": stray, "content": "<h1>nope"},
                                    {"path": "mockup.html", "content": "<h1>x"}]})
        sid, _ = self._start()
        _s, body = self._post("/api/holodeck/%s/say" % sid, {"text": "go"})
        state = body["state"]
        self.assertEqual(state["status"], "refused", state)
        self.assertNotIn("transcript.md", state["refused"]["message"])


# ── FIX ROUND 1a — an EMPTY concept.md is not a concept doc ──────────────────
class EmptyConceptDocTest(DurableBase):
    """S127 hands this file to Align. "It exists" is too low a bar to call ok."""

    def test_a_zero_byte_concept_doc_does_not_audit_ok(self):
        self._set_turns({"stdout": "Built it.",
                         "writes": [{"path": "mockup.html", "content": "<h1>x"},
                                    {"path": "concept.md", "content": ""}]})
        sid, _ = self._start()
        _s, body = self._post("/api/holodeck/%s/say" % sid, {"text": "go"})
        audit = body["state"]["conceptAudit"]
        self.assertNotEqual(audit["status"], "ok", audit)
        # the surface only renders the notice for `missing`, so an empty doc
        # has to arrive under that status or the captain never sees it.
        self.assertEqual(audit["status"], "missing", audit)
        self.assertIn("empty", (audit["message"] or "").lower())
        # and it does not claim the doc was updated alongside the mockup.
        self.assertNotIn("was updated alongside", audit["message"])

    def test_a_whitespace_only_concept_doc_does_not_audit_ok(self):
        self._set_turns({"stdout": "Built it.",
                         "writes": [{"path": "mockup.html", "content": "<h1>x"},
                                    {"path": "concept.md", "content": "\n\n  \n"}]})
        sid, _ = self._start()
        _s, body = self._post("/api/holodeck/%s/say" % sid, {"text": "go"})
        self.assertEqual(body["state"]["conceptAudit"]["status"], "missing")

    # ── FIX ROUND 2 — and it is not OFFERED as something to read either ─────
    # `conceptFile` is what makes the deck's ▤ Intent control openable. It was
    # keyed off existence alone, so on the very turn the audit correctly said
    # "there is a file in the room with nothing in it" the control opened that
    # blank file in a new tab. Never a name the surface then shows nothing for
    # (`basisFile`'s rule, applied to the other document).
    def test_an_empty_concept_doc_is_not_offered_as_something_to_read(self):
        self._set_turns({"stdout": "Built it.",
                         "writes": [{"path": "mockup.html", "content": "<h1>x"},
                                    {"path": "concept.md", "content": "\n \n"}]})
        sid, _ = self._start()
        _s, body = self._post("/api/holodeck/%s/say" % sid, {"text": "go"})
        self.assertIsNone(body["state"]["conceptFile"], body["state"])

    def test_a_real_concept_doc_IS_offered(self):
        self._set_turns({"stdout": "Built it.",
                         "writes": [{"path": "mockup.html", "content": "<h1>x"},
                                    {"path": "concept.md",
                                     "content": "# Nav rail\n\n## The problem\n"}]})
        sid, _ = self._start()
        _s, body = self._post("/api/holodeck/%s/say" % sid, {"text": "go"})
        self.assertEqual(body["state"]["conceptFile"], "concept.md")

    def test_the_listing_off_disk_makes_the_same_call(self):
        """One rule, both readers — a live card and a restarted one disagreeing
        about the same file is how the two copies of this question started
        drifting in the first place."""
        self._set_turns({"stdout": "Built it.",
                         "writes": [{"path": "mockup.html", "content": "<h1>x"},
                                    {"path": "concept.md", "content": ""}]})
        sid, _ = self._start()
        self._post("/api/holodeck/%s/say" % sid, {"text": "go"})
        self._restart_daemon()
        self.assertIsNone(self._list()["programs"][0]["conceptFile"])
        with open(os.path.join(self._room(), "concept.md"), "w") as fh:
            fh.write("# Nav rail\n")
        self.assertEqual(self._list()["programs"][0]["conceptFile"],
                         "concept.md")

    def test_a_concept_doc_with_words_in_it_still_audits_ok(self):
        """The control: the cure must not condemn a real concept doc."""
        self._set_turns({"stdout": "Built it.",
                         "writes": [{"path": "mockup.html", "content": "<h1>x"},
                                    {"path": "concept.md",
                                     "content": "# Nav rail\n\n## The problem\n"}]})
        sid, _ = self._start()
        _s, body = self._post("/api/holodeck/%s/say" % sid, {"text": "go"})
        audit = body["state"]["conceptAudit"]
        self.assertEqual(audit["status"], "ok", audit)
        self.assertTrue(audit["updated"])


# ── S126 #3 — the concept.md contract ────────────────────────────────────────
class ConceptContractTest(DurableBase):
    def test_the_opening_design_prompt_states_the_concept_md_contract(self):
        self._set_turns({"stdout": "Up."})
        sid, _ = self._start()
        self._post("/api/holodeck/%s/say" % sid, {"text": "go"})
        prompt = self._prompts()[0]
        self.assertIn("concept.md", prompt)
        low = prompt.lower()
        # D6/D14's sections…
        for section in ("the problem", "decisions", "open questions",
                        "hand-off summary"):
            self.assertIn(section, low, section)
        # …the intent capture and its THREE buckets, in the captain's own words…
        self.assertIn("WHAT IT MUST DO", prompt)
        self.assertIn("out of scope", low)
        self.assertIn("implied", low)
        self.assertIn("own words", low)
        # …and D4's declared flow, with a concrete shape to copy.
        self.assertIn("DECLARED FLOW", prompt)
        self.assertIn("→", prompt)

    def test_a_turn_that_changed_the_mockup_without_a_concept_doc_is_audited(self):
        self._set_turns({"stdout": "Built it.",
                         "writes": [{"path": "mockup.html", "content": "<h1>x"}]})
        sid, _ = self._start()
        _s, body = self._post("/api/holodeck/%s/say" % sid, {"text": "go"})
        audit = body["state"].get("conceptAudit")
        self.assertTrue(audit, "the mockup moved with no concept audit at all")
        self.assertEqual(audit["status"], "missing")
        self.assertIn("concept.md", audit["message"])
        # AND IT DID NOT FABRICATE ONE. An audit that writes the file it is
        # auditing certifies nothing.
        self.assertFalse(os.path.exists(os.path.join(self._room(),
                                                     "concept.md")))

    def test_a_turn_that_kept_the_concept_doc_current_audits_clean(self):
        self._set_turns({"stdout": "Built it.",
                         "writes": [{"path": "mockup.html", "content": "<h1>x"},
                                    {"path": "concept.md",
                                     "content": "# Nav rail\n\n## The problem\n"}]})
        sid, _ = self._start()
        _s, body = self._post("/api/holodeck/%s/say" % sid, {"text": "go"})
        audit = body["state"]["conceptAudit"]
        self.assertEqual(audit["status"], "ok")
        self.assertTrue(audit["updated"])

    def test_a_turn_that_did_not_touch_the_mockup_is_not_audited(self):
        self._set_turns({"stdout": "Amber reads warmer."})
        sid, _ = self._start()
        _s, body = self._post("/api/holodeck/%s/say" % sid, {"text": "?"})
        self.assertEqual(body["state"]["conceptAudit"]["status"],
                         "not-applicable")

    def test_a_grounding_pass_is_not_held_to_the_concept_contract(self):
        self._set_turns({"stdout": "Tokens: --x #fff"})
        _sid, state = self._start("Nav rail", mode="grounding")
        self.assertEqual(state["conceptAudit"]["status"], "not-applicable")


# ── S126 #5 (S125 ledger) — the concurrency guard lives in the DAEMON ────────
class TurnConcurrencyTest(DurableBase):
    """Two overlapping `/say` on ONE program both spawned a worker with
    `--resume <same uuid>`, the second overwrote `sess.proc`, and `end` could
    report a settled file list about a live turn. The deck guards this
    client-side (`HOLO.busy`) only. Persistence raises the stakes: every turn
    now commits the room, so two racing turns fight over one working tree."""

    def _say_async(self, sid, text, out, key):
        def run():
            try:
                out[key] = self._post_raw("/api/holodeck/%s/say" % sid,
                                          {"text": text}, timeout=60)
            except Exception as exc:            # pragma: no cover - diagnostic
                out[key] = ("EXC", str(exc))
        t = threading.Thread(target=run)
        t.start()
        return t

    def test_a_second_turn_on_one_program_is_refused_while_the_first_runs(self):
        self._set_turns({"sleep": 2.5, "stdout": "One.",
                         "writes": [{"path": "mockup.html", "content": "<h1>1"}]},
                        {"stdout": "Two."})
        sid, _ = self._start()
        out = {}
        first = self._say_async(sid, "Draft a nav rail", out, "a")
        # give the first turn time to be IN FLIGHT (its stub sleeps 2.5s).
        time.sleep(0.8)
        st, body = self._post_raw("/api/holodeck/%s/say" % sid,
                                  {"text": "Make it teal"}, timeout=60)
        first.join(60)
        self.assertEqual(st, 409, body)
        msg = body["error"]
        self.assertNotIn("Traceback", msg)
        # LEGIBLE, IN THE CAPTAIN'S LANGUAGE: what is happening, that his line
        # was not lost, and what to do. No uuid, no `sess.proc`, no lock names.
        low = msg.lower()
        self.assertIn("turn", low)
        for jargon in ("sess.", "lock", "mutex", "thread", "resume"):
            self.assertNotIn(jargon, low, jargon)
        # the first turn still landed normally.
        self.assertEqual(out["a"][0], 200, out["a"])
        self.assertEqual(out["a"][1]["state"]["status"], "ok")

    def test_the_refused_turn_leaves_no_trace_and_no_dirty_tree(self):
        self._set_turns({"sleep": 2.5, "stdout": "One.",
                         "writes": [{"path": "mockup.html", "content": "<h1>1"}]},
                        {"stdout": "Two."})
        sid, _ = self._start()
        out = {}
        first = self._say_async(sid, "Draft a nav rail", out, "a")
        time.sleep(0.8)
        self._post_raw("/api/holodeck/%s/say" % sid, {"text": "Make it teal"},
                       timeout=60)
        first.join(60)
        # ONE worker was spawned, not two.
        self.assertEqual(len(self._calls()), 1, self._calls())
        text = self._transcript()
        self.assertNotIn("Make it teal", text)
        self.assertEqual(self._porcelain(), [])
        # and the transcript shows the captain saying his line once.
        _s, one = self._post("/api/holodeck/%s/end" % sid)
        self.assertEqual(one["state"]["turns"], 1)

    def test_the_guard_releases_when_the_turn_lands(self):
        self._set_turns({"stdout": "One."}, {"stdout": "Two."})
        sid, _ = self._start()
        st1, _b1 = self._post_raw("/api/holodeck/%s/say" % sid, {"text": "a"})
        st2, _b2 = self._post_raw("/api/holodeck/%s/say" % sid, {"text": "b"})
        self.assertEqual((st1, st2), (200, 200))

    def test_the_guard_releases_when_the_turn_FAILS(self):
        """A guard that leaks on the error path bricks the program — which is
        exactly the dead-end class S125's N4 fix was about."""
        self._set_turns({"stdout": "boom", "exit": 1}, {"stdout": "Recovered."})
        sid, _ = self._start()
        st1, _b1 = self._post_raw("/api/holodeck/%s/say" % sid, {"text": "a"})
        self.assertEqual(st1, 502)
        st2, b2 = self._post_raw("/api/holodeck/%s/say" % sid, {"text": "a"})
        self.assertEqual(st2, 200, b2)

    def test_two_DIFFERENT_programs_may_still_run_at_once(self):
        """The guard is per PROGRAM. Two rooms are two working directories and
        the deck is allowed to have two conversations going."""
        self._set_turns({"sleep": 1.5, "stdout": "One.",
                         "writes": [{"path": "mockup.html", "content": "<h1>1"}]},
                        {"sleep": 1.5, "stdout": "Two.",
                         "writes": [{"path": "mockup.html", "content": "<h1>2"}]})
        sid_a, _ = self._start("Nav rail")
        sid_b, _ = self._start("Tile picker")
        out = {}
        ta = self._say_async(sid_a, "one", out, "a")
        tb = self._say_async(sid_b, "two", out, "b")
        ta.join(60)
        tb.join(60)
        self.assertEqual(out["a"][0], 200, out["a"])
        self.assertEqual(out["b"][0], 200, out["b"])
        # both rooms committed, and the tree is clean — no lost commit from two
        # `git add -A` runs colliding on one index.
        self.assertEqual(self._porcelain(), [])
        self.assertTrue(os.path.exists(os.path.join(self._room("nav-rail"),
                                                    "mockup.html")))
        self.assertTrue(os.path.exists(os.path.join(self._room("tile-picker"),
                                                    "mockup.html")))


# ── S126 #2 — resume from disk ───────────────────────────────────────────────
class ResumeFromDiskTest(DurableBase):
    """A daemon restart used to lose every program. The rooms were always on
    disk; nothing read them back."""

    def _worked_program(self):
        self._set_turns({"stdout": "First pass is up.",
                         "writes": [{"path": "mockup.html", "content": "<h1>1"}]},
                        {"stdout": "Made it teal.",
                         "writes": [{"path": "mockup.html", "content": "<h1>2"}]})
        sid, _ = self._start("Nav rail")
        self._post("/api/holodeck/%s/say" % sid, {"text": "Draft a nav rail"})
        self._post("/api/holodeck/%s/say" % sid, {"text": "Make it teal"})
        return sid

    def test_a_program_survives_the_daemon_that_made_it(self):
        old_sid = self._worked_program()
        self._restart_daemon()
        listing = self._list()
        self.assertEqual(len(listing["programs"]), 1, listing)
        p = listing["programs"][0]
        self.assertEqual(p["program"], "Nav rail")
        self.assertEqual(p["room"], "nav-rail")
        self.assertEqual(p["turnCount"], 2)
        self.assertEqual(p["previewFile"], "mockup.html")
        # HONEST: there is no live session, and the list says so rather than
        # handing out an id that resolves to nothing.
        self.assertIsNone(p["sessionId"])
        self.assertTrue(p["onDisk"])
        self.assertNotEqual(p.get("sessionId"), old_sid)

    def test_a_live_program_is_listed_once_not_twice(self):
        self._worked_program()
        listing = self._list()
        rooms = [p["room"] for p in listing["programs"]]
        self.assertEqual(rooms, ["nav-rail"], listing)
        self.assertTrue(listing["programs"][0]["sessionId"])
        self.assertFalse(listing["programs"][0]["onDisk"])

    def test_reopening_rebuilds_the_program_with_a_FRESH_worker_session(self):
        self._worked_program()
        first_uuid = self._flag_value(self._calls()[0]["argv"], "--session-id")
        self._restart_daemon()
        self._set_turns({"stdout": "Picked it back up."})
        status, body = self._post("/api/holodeck/open", {"room": "nav-rail"})
        self.assertEqual(status, 200, body)
        state = body["state"]
        sid = state["sessionId"]
        self.assertTrue(sid)
        self.assertEqual(state["program"], "Nav rail")
        self.assertEqual(state["turnCount"], 2)
        self.assertEqual([t["text"] for t in state["turns"]],
                         ["Draft a nav rail", "Make it teal"])
        # the next turn OPENS a new worker session — it never resumes an id the
        # CLI on the other side of a restart has no record of.
        self._post("/api/holodeck/%s/say" % sid, {"text": "keep going"})
        last = self._calls()[-1]["argv"]
        opened = self._flag_value(last, "--session-id")
        self.assertTrue(opened, last)
        self.assertNotEqual(opened, first_uuid)
        self.assertIsNone(self._flag_value(last, "--resume"))

    def test_the_reopened_prompt_carries_the_transcript_as_context(self):
        self._worked_program()
        self._restart_daemon()
        self._set_turns({"stdout": "Picked it back up."})
        _s, body = self._post("/api/holodeck/open", {"room": "nav-rail"})
        sid = body["state"]["sessionId"]
        self._post("/api/holodeck/%s/say" % sid, {"text": "keep going"})
        prompt = self._prompts()[-1]
        self.assertIn("Draft a nav rail", prompt)
        self.assertIn("Made it teal.", prompt)
        self.assertIn("transcript.md", prompt)
        # and it TELLS the worker it remembers none of this itself.
        low = prompt.lower()
        self.assertIn("fresh", low)

    def test_reopening_never_claims_a_session_that_does_not_exist(self):
        """S125's finding #2, in a new place: `reply` proved nothing then; a
        SESSION ID proves nothing here. A warm restart is a fresh worker
        carrying the history, and saying otherwise is the same dishonesty."""
        old_sid = self._worked_program()
        self._restart_daemon()
        _s, body = self._post("/api/holodeck/open", {"room": "nav-rail"})
        state = body["state"]
        note = state.get("warmRestart")
        self.assertTrue(note, "a rebuilt program said nothing about being one")
        msg = note["message"]
        low = msg.lower()
        self.assertIn("fresh", low)
        self.assertTrue("transcript" in low or "history" in low, msg)
        # it never prints an id, and never the dead one.
        self.assertNotIn(old_sid, msg)
        self.assertNotIn(state["sessionId"], msg)
        self.assertNotIn("resumed", low)
        self.assertTrue(state["warmRestart"])
        self.assertTrue(state.get("restarted"))

    def test_reopening_a_program_that_is_already_open_returns_the_live_one(self):
        sid = self._worked_program()
        _s, body = self._post("/api/holodeck/open", {"room": "nav-rail"})
        self.assertEqual(body["state"]["sessionId"], sid)
        # it is NOT a restart — nothing was rebuilt.
        self.assertFalse(body["state"].get("warmRestart"))

    def test_reopening_an_unknown_room_is_a_readable_404(self):
        self._worked_program()
        st, body = self._post_raw("/api/holodeck/open", {"room": "nope"})
        self.assertEqual(st, 404)
        self.assertNotIn("Traceback", body["error"])

    def test_a_room_name_cannot_climb_out_of_the_sidecar(self):
        self._worked_program()
        for room in ("../target-repo", "/etc", "nav-rail/../..", ".git"):
            st, body = self._post_raw("/api/holodeck/open", {"room": room})
            self.assertIn(st, (403, 404), (room, st, body))

    def test_the_grounded_flag_and_basis_survive_a_restart(self):
        self._set_turns({"stdout": "Tokens: --lcars-amber #ff9c00"},
                        {"stdout": "Built it.",
                         "writes": [{"path": "mockup.html", "content": "<h1>x"}]})
        sid, _ = self._start("Nav rail", mode="grounding")
        self._post("/api/holodeck/%s/say" % sid, {"text": "go"})
        self._restart_daemon()
        p = self._list()["programs"][0]
        self.assertTrue(p["grounded"])
        self.assertEqual(p["basisFile"], "basis.md")


# ── S126 #4 — delete keeps the history ───────────────────────────────────────
class DeleteProgramTest(DurableBase):
    def _worked_program(self):
        self._set_turns({"stdout": "Built it.",
                         "writes": [{"path": "mockup.html",
                                     "content": "<h1>keep me"}]})
        sid, _ = self._start("Nav rail")
        self._post("/api/holodeck/%s/say" % sid, {"text": "go"})
        return sid

    def test_delete_removes_the_room_and_commits_it(self):
        self._worked_program()
        before = len(self._log())
        status, body = self._post("/api/holodeck/delete", {"room": "nav-rail"})
        self.assertEqual(status, 200, body)
        self.assertFalse(os.path.isdir(self._room()))
        self.assertEqual(len(self._log()) - before, 1)
        self.assertEqual(self._porcelain(), [])
        self.assertEqual(self._list()["programs"], [])

    def test_the_deleted_program_is_still_in_the_history(self):
        self._worked_program()
        _s, body = self._post("/api/holodeck/delete", {"room": "nav-rail"})
        sha = body["state"]["commit"]
        self.assertTrue(sha)
        rc, out = self._git("show", "%s^:nav-rail/mockup.html" % sha)
        self.assertEqual(rc, 0, out)
        self.assertIn("keep me", out)
        # and the captain is told, in one sentence, how to get it back — naming
        # the commit that PROVABLY holds the room (fix round 3), which is the
        # one his checkout has to name, not the one the deletion landed in.
        msg = body["state"]["message"]
        self.assertIn("nav-rail", msg)
        _rc, parent = self._git("rev-parse", "--short=7", "%s^" % sha)
        self.assertIn(parent.strip(), msg)

    def test_delete_refuses_while_that_program_has_a_turn_in_flight(self):
        self._set_turns({"sleep": 2.5, "stdout": "One.",
                         "writes": [{"path": "mockup.html", "content": "<h1>1"}]})
        sid, _ = self._start("Nav rail")
        out = {}

        def run():
            out["a"] = self._post_raw("/api/holodeck/%s/say" % sid,
                                      {"text": "go"}, timeout=60)
        t = threading.Thread(target=run)
        t.start()
        time.sleep(0.8)
        st, body = self._post_raw("/api/holodeck/delete", {"room": "nav-rail"})
        t.join(60)
        self.assertEqual(st, 409, body)
        self.assertTrue(os.path.isdir(self._room()))
        self.assertNotIn("Traceback", body["error"])

    def test_delete_closes_a_live_but_idle_program_too(self):
        sid = self._worked_program()
        st, _b = self._post("/api/holodeck/delete", {"room": "nav-rail"})
        self.assertEqual(st, 200)
        st2, _b2 = self._post_raw("/api/holodeck/%s/say" % sid, {"text": "hi"})
        self.assertEqual(st2, 404)

    def test_deleting_an_unknown_room_is_a_readable_404(self):
        self._worked_program()
        st, body = self._post_raw("/api/holodeck/delete", {"room": "nope"})
        self.assertEqual(st, 404)
        self.assertNotIn("Traceback", body["error"])

    def test_delete_cannot_be_aimed_outside_the_sidecar(self):
        self._worked_program()
        keep = os.path.join(self.repo, "board.css")
        for room in ("../target-repo", "/etc", "nav-rail/../..", ".git", ""):
            st, body = self._post_raw("/api/holodeck/delete", {"room": room})
            self.assertIn(st, (400, 403, 404), (room, st, body))
        self.assertTrue(os.path.exists(keep))
        self.assertTrue(os.path.isdir(os.path.join(self._sidecar(), ".git")))


# ════════════════════════════════════════════════════════════════════════════
# FIX ROUND 3 · DEFECT 1 — DELETE NEVER DESTROYS WHAT IT CALLS RECOVERABLE
#
# Reproduced twice by the tester. Start a program; its first turn dies (an
# expired token — the most ordinary failure this product has); delete it.
# LCARS answered `recoverable: true` and printed
#
#     git -C … checkout <sha>^ -- ghost-deck
#
# and that exact command answered `pathspec 'ghost-deck' did not match any
# file(s) known to git`. The room was gone for good.
#
# THE MECHANISM: `git rm --ignore-unmatch` silently does NOTHING on an
# UNTRACKED room; `shutil.rmtree` then destroyed it; and the `git add -A`
# afterwards swept up UNRELATED untracked files, so the commit succeeded,
# `committed` came back true, and `recoverable` was read off evidence about
# somebody else's files.
#
# Fix round 2 made this the ORDINARY case rather than an edge: `_ensure_
# transcript` puts the program's own record in the room the moment it is named,
# and `_is_program_room` makes such a room deletable. So "deletable but never
# committed" is now every program whose first turn has not landed — including
# exactly the dead-first-turn program `_ensure_transcript` was written for.
#
# THE BAR: LCARS must never destroy something while promising it is
# recoverable. Either it is genuinely in the archive's history before the room
# goes, or the captain is told plainly that this one cannot be brought back and
# nothing is removed.
# ════════════════════════════════════════════════════════════════════════════
class DeleteNeverDestroysWhatItCallsRecoverableTest(DurableBase):

    def _dead_first_turn(self):
        """The failure the tester drove: the engine dies at startup, so the
        room and its `transcript.md` exist and NOTHING has been committed."""
        self._set_turns({"stdout": "Error: authentication failed", "exit": 1})
        sid, _ = self._start()
        self._post_raw("/api/holodeck/%s/say" % sid,
                       {"text": "Draft a nav rail"})
        return sid

    def _printed_command(self, message):
        """The command LCARS actually printed, as argv."""
        found = re.findall(r"`([^`]+)`", message or "")
        self.assertTrue(found, "the reply printed no command: %r" % message)
        return shlex.split(found[0])

    def _run_printed_command(self, message):
        proc = subprocess.run(self._printed_command(message),
                              stdout=subprocess.PIPE,
                              stderr=subprocess.STDOUT)
        return proc.returncode, (proc.stdout or b"").decode("utf-8", "replace")

    def test_the_room_of_a_dead_first_turn_really_is_untracked(self):
        """The calibration. Without it every test below could be passing on a
        room git happened to be holding already, and prove nothing."""
        self._dead_first_turn()
        self.assertTrue(os.path.isdir(self._room()))
        self.assertTrue(os.path.isfile(os.path.join(self._room(),
                                                    "transcript.md")))
        rc, out = self._git("ls-files", "--error-unmatch", "nav-rail")
        self.assertNotEqual(rc, 0,
                            "the room was already tracked, so this suite is "
                            "not measuring the reported defect: %s" % out)

    def test_the_recovery_command_it_prints_ACTUALLY_BRINGS_IT_BACK(self):
        self._dead_first_turn()
        _s, body = self._post("/api/holodeck/delete", {"room": "nav-rail"})
        state = body["state"]
        self.assertTrue(state["recoverable"], state)
        self.assertFalse(os.path.isdir(self._room()))
        rc, out = self._run_printed_command(state["message"])
        self.assertEqual(rc, 0, "the command LCARS printed failed: %s" % out)
        text = self._transcript()
        self.assertIsNotNone(text, "the command ran but nothing came back")
        self.assertIn("Nav rail", text)

    def test_it_either_keeps_it_recoverable_or_keeps_it(self):
        """THE BAR, stated structurally. Whatever the sidecar's state, one of
        two things is true after a delete: the program is in history and the
        printed command brings it back, or it is still on disk. There is no
        third answer in which LCARS destroyed it and said otherwise."""
        self._dead_first_turn()
        # the captain's own untracked file, sitting in HIS archive: the thing
        # `git add -A` used to stage so the delete commit "succeeded".
        with open(os.path.join(self._sidecar(), "notes-i-keep.txt"), "w") as fh:
            fh.write("mine\n")
        _s, body = self._post("/api/holodeck/delete", {"room": "nav-rail"})
        state = body["state"]
        if state["recoverable"]:
            rc, out = self._run_printed_command(state["message"])
            self.assertEqual(rc, 0, "recoverable: true, and the command it "
                                    "printed failed: %s" % out)
            self.assertIsNotNone(self._transcript(),
                                 "recoverable: true, the command ran, and the "
                                 "program did not come back")
        else:
            self.assertTrue(os.path.isdir(self._room()),
                            "LCARS destroyed a room it says it cannot bring "
                            "back: %s" % state.get("message"))

    def test_when_it_cannot_be_recorded_nothing_is_removed(self):
        """The other half of the bar, taken for real. With git unusable the
        program CANNOT be put in history — so it is not removed, and the
        captain is told that in plain English rather than handed a command
        that will not work."""
        self._dead_first_turn()
        self.actions.git_bin = os.path.join(self.repo, "no-such-git")
        st, body = self._post_raw("/api/holodeck/delete", {"room": "nav-rail"})
        self.assertEqual(st, 502, body)
        err = body["error"]
        self.assertNotIn("Traceback", err)
        self.assertIn("nav-rail", err)
        self.assertIn("recoverable", err.lower())
        # and it is STILL THERE.
        self.assertTrue(os.path.isdir(self._room()))
        self.assertIn("Nav rail", self._transcript())

    def test_the_delete_stages_only_this_programs_room(self):
        """"Leave my files alone." A delete is not an occasion to commit the
        captain's own archive for him — and leaning on his files is how the
        old commit "succeeded" over a room it had never recorded."""
        self._dead_first_turn()
        mine = os.path.join(self._sidecar(), "notes-i-keep.txt")
        with open(mine, "w") as fh:
            fh.write("mine\n")
        self._post("/api/holodeck/delete", {"room": "nav-rail"})
        rc, _out = self._git("ls-files", "--error-unmatch", "notes-i-keep.txt")
        self.assertNotEqual(rc, 0, "the delete committed the captain's own file")
        self.assertTrue(os.path.isfile(mine))


# ════════════════════════════════════════════════════════════════════════════
# FIX ROUND 3 — "LEAVE MY FILES ALONE" (the captain's ruling)
#
# The tester measured a turn commit reading `holodeck(Ensuite Floor Picker —
# v2 (Deck 5)!): turn 4 — Tighten it.` that recorded a `notes/roadmap.md` he
# had dropped in the archive AND a SECOND program's `transcript.md`. The
# round's headline claim is that the sidecar's git log IS the program's audit
# trail; a log that attributes the captain's own files to a design turn he
# never made is not one.
#
# The ruling, in his words: a turn commits ONLY that program's own room.
# Anything he drops in the sidecar himself stays untouched and uncommitted —
# it is his repo and he commits it when he wants.
# ════════════════════════════════════════════════════════════════════════════
class TurnCommitsOnlyItsOwnRoomTest(DurableBase):

    def _tracked(self, path):
        rc, _out = self._git("ls-files", "--error-unmatch", path)
        return rc == 0

    def test_a_turn_never_commits_the_captains_own_files(self):
        self._set_turns({"stdout": "Built it.",
                         "writes": [{"path": "mockup.html", "content": "<h1>1"}]})
        sid, _ = self._start()
        os.makedirs(os.path.join(self._sidecar(), "notes"), exist_ok=True)
        with open(os.path.join(self._sidecar(), "notes", "roadmap.md"), "w") as fh:
            fh.write("# my roadmap\n")
        self._post("/api/holodeck/%s/say" % sid, {"text": "go"})
        self.assertTrue(self._tracked("nav-rail/mockup.html"))
        self.assertFalse(self._tracked("notes/roadmap.md"),
                         "the turn commit swept up the captain's own file")
        # untouched, and still exactly where he put it.
        with open(os.path.join(self._sidecar(), "notes", "roadmap.md")) as fh:
            self.assertEqual(fh.read(), "# my roadmap\n")

    def test_a_turn_never_commits_another_programs_room(self):
        self._set_turns({"stdout": "Built it.",
                         "writes": [{"path": "mockup.html", "content": "<h1>1"}]},
                        {"stdout": "Built it.",
                         "writes": [{"path": "mockup.html", "content": "<h1>2"}]})
        sid_a, _ = self._start("Nav rail")
        sid_b, _ = self._start("Tile picker")
        # B's room exists and is untracked; A now takes a turn.
        self._post("/api/holodeck/%s/say" % sid_a, {"text": "go"})
        self.assertTrue(self._tracked("nav-rail/transcript.md"))
        self.assertFalse(self._tracked("tile-picker/transcript.md"),
                         "Nav rail's turn committed Tile picker's room")

    def test_a_turn_commits_everything_the_program_produced(self):
        """The other half of the narrowing: it must not start dropping the
        worker's OWN output. A multi-file turn lands whole."""
        self._set_turns({"stdout": "Tokens: --lcars-amber #ff9c00"},
                        {"stdout": "Built it.",
                         "writes": [{"path": "mockup.html", "content": "<h1>x"},
                                    {"path": "assets/rail.svg",
                                     "content": "<svg/>"},
                                    {"path": "notes.md", "content": "# n"}]})
        sid, _ = self._start("Nav rail", mode="grounding")
        self._post("/api/holodeck/%s/say" % sid, {"text": "go"})
        for rel in ("nav-rail/mockup.html", "nav-rail/assets/rail.svg",
                    "nav-rail/notes.md", "nav-rail/transcript.md",
                    "nav-rail/basis.md"):
            self.assertTrue(self._tracked(rel), "%s was never committed" % rel)
        self.assertEqual([p for p in self._porcelain()
                          if p.split()[-1].startswith("nav-rail")], [])


# ════════════════════════════════════════════════════════════════════════════
# FIX ROUND 2 · DEFECT 4 — THE NAME THE CAPTAIN TYPED IS THE PROGRAM'S NAME
#
# Reproduced: start `Ensuite Floor Picker` (design mode — the room is created
# and nothing is written), restart the daemon, and the list reads `ensuite
# floor picker`. Say one thing and that name is CEMENTED: the transcript is
# created with `# ensuite floor picker`, every later commit message reads
# `holodeck(ensuite floor picker): …`, and so does the delete confirmation.
#
# The room slug is DERIVED and LOSSY. The name already had exactly one durable
# home — `transcript.md`'s `# ` heading — and it was simply written too late,
# so any program whose first turn had not landed (including one whose first
# turn DIED, the most ordinary failure this product has) had nowhere to keep
# the name at all.
# ════════════════════════════════════════════════════════════════════════════
class ProgramNameSurvivesTest(DurableBase):
    NAME = "Ensuite Floor Picker"
    ROOM = "ensuite-floor-picker"

    def test_the_name_is_on_disk_the_moment_the_captain_types_it(self):
        self._start(self.NAME)
        text = self._transcript(self.ROOM)
        self.assertIsNotNone(text, "the program's room records nothing about "
                                   "the program until its first turn lands")
        self.assertTrue(text.startswith("# %s" % self.NAME), text[:80])

    def test_a_program_never_spoken_to_keeps_its_name_across_a_restart(self):
        self._start(self.NAME)
        self._restart_daemon()
        progs = self._list()["programs"]
        self.assertEqual(len(progs), 1, progs)
        self.assertEqual(progs[0]["program"], self.NAME)
        self.assertEqual(progs[0]["room"], self.ROOM)
        self.assertEqual(progs[0]["turnCount"], 0)

    def test_a_program_whose_first_turn_DIED_keeps_its_name(self):
        """The ordinary failure: the engine dies at startup, so no turn ever
        landed and nothing but the room existed to read a name back out of."""
        self._set_turns({"stdout": "Error: authentication failed", "exit": 1})
        sid, _ = self._start(self.NAME)
        st, _b = self._post_raw("/api/holodeck/%s/say" % sid, {"text": "go"})
        self.assertEqual(st, 502)
        self._restart_daemon()
        self.assertEqual(self._list()["programs"][0]["program"], self.NAME)

    def test_reopening_it_does_not_cement_the_slug_into_the_git_log(self):
        self._start(self.NAME)
        self._restart_daemon()
        self._set_turns({"stdout": "Picked it back up.",
                         "writes": [{"path": "mockup.html", "content": "<h1>x"}]})
        _s, body = self._post("/api/holodeck/open", {"room": self.ROOM})
        self.assertEqual(body["state"]["program"], self.NAME)
        sid = body["state"]["sessionId"]
        self._post("/api/holodeck/%s/say" % sid, {"text": "keep going"})
        text = self._transcript(self.ROOM)
        self.assertTrue(text.startswith("# %s" % self.NAME), text[:80])
        self.assertNotIn(self.NAME.lower(), text)
        self.assertIn(self.NAME, self._log()[0])
        self.assertNotIn(self.NAME.lower(), self._log()[0])

    def test_the_delete_confirmation_names_the_program_he_typed(self):
        """Both halves of it: the name the deck puts in the dialog, and the
        name the commit message carries. (A program never spoken to has
        nothing committed to remove, so this works one that has.)"""
        self._set_turns({"stdout": "Up.",
                         "writes": [{"path": "mockup.html", "content": "<h1>1"}]})
        sid, _ = self._start(self.NAME)
        self._post("/api/holodeck/%s/say" % sid, {"text": "draft it"})
        self._restart_daemon()
        _s, body = self._post("/api/holodeck/delete", {"room": self.ROOM})
        self.assertEqual(body["state"]["program"], self.NAME)
        self.assertIn(self.NAME, self._log()[0])
        self.assertNotIn(self.NAME.lower(), self._log()[0])

    def test_a_worked_program_still_reads_its_name_from_its_transcript(self):
        """The control: the header is written ONCE, at naming time, and the
        first turn must not write a second one or renumber anything."""
        self._set_turns({"stdout": "Up.",
                         "writes": [{"path": "mockup.html", "content": "<h1>1"}]})
        sid, _ = self._start(self.NAME)
        self._post("/api/holodeck/%s/say" % sid, {"text": "draft it"})
        text = self._transcript(self.ROOM)
        self.assertEqual(text.count("# %s" % self.NAME), 1, text)
        self.assertEqual(text.count("## Turn 1 ·"), 1, text)
        self.assertIn("draft it", text)

    def test_a_room_LCARS_cannot_write_into_is_refused_before_it_is_adopted(self):
        """The name has to land somewhere. A room that cannot take the
        program's own record cannot take a mockup either, so this is refused
        where the engine check is — before anything is adopted — rather than
        answering 200 and losing the name silently."""
        sidecar = self.actions._ensure_sidecar(self.repo)
        os.makedirs(os.path.join(sidecar, self.ROOM, "transcript.md"))
        st, body = self._post_raw("/api/holodeck/start",
                                  {"program": self.NAME,
                                   "engine": self.claude_bin})
        self.assertEqual(st, 502, body)
        low = body["error"].lower()
        self.assertIn("transcript.md", low)
        for jargon in ("traceback", "oserror", "errno", "isadirectory"):
            self.assertNotIn(jargon, low, jargon)


# ════════════════════════════════════════════════════════════════════════════
# FIX ROUND 2 · DEFECT 7 — THE SIDECAR IS THE CAPTAIN'S ARCHIVE
#
# LCARS advertises the sidecar to the captain as HIS — a git repo beside his
# project that he can back up and keep things in — so he will keep things in
# it. A dropped `screenshots-i-saved/` was listed as a program called
# `screenshots i saved` with 0 turns and a working ⌫ DELETE that `git rm`'d it.
# A program is a room with the program's own record in it, not "any directory".
# ════════════════════════════════════════════════════════════════════════════
class OnlyProgramsAreProgramsTest(DurableBase):
    FOLDER = "screenshots-i-saved"

    def _worked_program(self):
        self._set_turns({"stdout": "Built it.",
                         "writes": [{"path": "mockup.html", "content": "<h1>x"}]})
        sid, _ = self._start("Nav rail")
        self._post("/api/holodeck/%s/say" % sid, {"text": "go"})
        return sid

    def _plant_folder(self):
        d = os.path.join(self._sidecar(), self.FOLDER)
        os.makedirs(d, exist_ok=True)
        shot = os.path.join(d, "kitchen.png")
        with open(shot, "w") as fh:
            fh.write("not really a png")
        return d, shot

    def test_a_folder_the_captain_kept_here_is_not_listed_as_a_program(self):
        self._worked_program()
        self._plant_folder()
        self._restart_daemon()
        rooms = [p["room"] for p in self._list()["programs"]]
        self.assertEqual(rooms, ["nav-rail"], rooms)

    def test_his_own_folder_cannot_be_deleted_through_the_deck(self):
        self._worked_program()
        folder, shot = self._plant_folder()
        st, body = self._post_raw("/api/holodeck/delete", {"room": self.FOLDER})
        self.assertIn(st, (403, 404), (st, body))
        self.assertTrue(os.path.isfile(shot), "LCARS deleted the captain's own "
                                              "files out of his archive")
        self.assertNotIn("Traceback", body["error"])
        self.assertIn(self.FOLDER, body["error"])

    def test_his_own_folder_cannot_be_opened_as_a_program(self):
        self._worked_program()
        self._plant_folder()
        st, body = self._post_raw("/api/holodeck/open", {"room": self.FOLDER})
        self.assertIn(st, (403, 404), (st, body))
        self.assertNotIn("Traceback", body["error"])

    def test_a_real_program_is_still_listed_opened_and_deleted(self):
        """The control: the cure must not make the product's own rooms
        unreachable."""
        self._worked_program()
        self._plant_folder()
        self._restart_daemon()
        self.assertEqual(self._list()["programs"][0]["program"], "Nav rail")
        self._set_turns({"stdout": "Back."})
        st, _b = self._post("/api/holodeck/open", {"room": "nav-rail"})
        self.assertEqual(st, 200)
        st2, _b2 = self._post("/api/holodeck/delete", {"room": "nav-rail"})
        self.assertEqual(st2, 200)
        self.assertFalse(os.path.isdir(self._room()))


# ════════════════════════════════════════════════════════════════════════════
# FIX ROUND 2 · DEFECT 5 — "WARM" IS A FACT, NOT A DECORATION
#
# The chat header's `WARM · CLAUDE` pill sat two inches under the warm-restart
# banner saying the conversation is over and the next worker is fresh. "Warm"
# is the exact word for the thing that did NOT survive. `sess.started` is the
# daemon's own answer to "is there a worker session to resume" — it is now on
# the payload so the pill can read it instead of asserting it.
# ════════════════════════════════════════════════════════════════════════════
class WarmIsMeasuredTest(DurableBase):
    def test_a_program_that_has_not_spoken_yet_is_not_warm(self):
        _sid, state = self._start()
        self.assertFalse(state["warm"], state)

    def test_a_turn_that_opened_the_session_is_warm(self):
        self._set_turns({"stdout": "Up.",
                         "writes": [{"path": "mockup.html", "content": "<h1>1"}]})
        sid, _ = self._start()
        _s, body = self._post("/api/holodeck/%s/say" % sid, {"text": "go"})
        self.assertTrue(body["state"]["warm"], body["state"])

    def test_a_turn_that_died_before_opening_a_session_is_not_warm(self):
        """The same evidence S125's N4 cure keyed off: a reply proves nothing,
        so neither does the pill."""
        self._set_turns({"stdout": "Error: authentication failed", "exit": 1},
                        {"stdout": "Second time worked.",
                         "writes": [{"path": "mockup.html", "content": "<h1>x"}]})
        sid, _ = self._start()
        st, _b = self._post_raw("/api/holodeck/%s/say" % sid, {"text": "go"})
        self.assertEqual(st, 502)
        self.assertFalse(self._get("/api/holodeck/%s" % sid)["warm"])

    def test_a_program_picked_back_up_is_not_warm_until_it_speaks_again(self):
        self._set_turns({"stdout": "Up.",
                         "writes": [{"path": "mockup.html", "content": "<h1>1"}]})
        sid, _ = self._start()
        self._post("/api/holodeck/%s/say" % sid, {"text": "go"})
        self._restart_daemon()
        self._set_turns({"stdout": "Back.",
                         "writes": [{"path": "mockup.html", "content": "<h1>2"}]})
        _s, body = self._post("/api/holodeck/open", {"room": "nav-rail"})
        state = body["state"]
        # the banner and the pill must not contradict each other on one screen.
        self.assertTrue(state["warmRestart"])
        self.assertFalse(state["warm"], state)
        _s2, body2 = self._post("/api/holodeck/%s/say" % state["sessionId"],
                                {"text": "keep going"})
        self.assertTrue(body2["state"]["warm"])

    def test_a_room_read_off_disk_is_never_warm(self):
        self._set_turns({"stdout": "Up.",
                         "writes": [{"path": "mockup.html", "content": "<h1>1"}]})
        sid, _ = self._start()
        self._post("/api/holodeck/%s/say" % sid, {"text": "go"})
        self._restart_daemon()
        self.assertFalse(self._list()["programs"][0]["warm"])


# ════════════════════════════════════════════════════════════════════════════
# FIX ROUND 5 — A PROGRAM REMEMBERS WHICH ENGINE BUILT IT (the money bug)
#
# MEASURED LIVE, not inferred. A program called "Ticket Detail" was designed
# end to end on claude. After a daemon restart the list read
# `engine: /opt/homebrew/bin/copilot`, the warm-restart banner told the captain
# "the copilot that answers your next turn", and the next turn really did run
# on copilot — its reply carried copilot tool blocks, which claude never emits.
#
# The reverse direction is the expensive one and is the reason this was cured
# rather than ledgered: a program built on FREE copilot silently reopening on
# BILLED claude, in a room whose whole stated posture is "this is the cheap
# one". This repo's engine has arrived from three places with a different
# winner per path before, and it has produced repeated money bugs.
#
# The suite drives the REVERSE (copilot-built, claude-default daemon) precisely
# because that is the direction that spends.
# ════════════════════════════════════════════════════════════════════════════
class EngineIsRememberedTest(DurableBase):
    """The engine that built a program survives the daemon that ran it."""

    def _built_on_copilot(self):
        """One design turn on copilot, then the daemon dies. The replacement
        daemon's default is CLAUDE (see `_restart_daemon`), so anything that
        reads claude back out of this program is the money bug."""
        self._set_turns({"stdout": "First pass is up.",
                         "writes": [{"path": "mockup.html",
                                     "content": "<h1>1"}]})
        sid, _ = self._start("Ticket detail", engine=self.copilot_bin)
        self._post("/api/holodeck/%s/say" % sid, {"text": "Draft the detail"})
        return sid

    # -- the record itself ---------------------------------------------------
    def test_the_engine_is_recorded_in_the_programs_own_record(self):
        """THE SAME DURABLE HOME THE NAME HAS. Not a sidecar metadata file —
        adding a mechanism beside an existing one has already cost this feature
        two rounds."""
        self._built_on_copilot()
        text = self._transcript("ticket-detail")
        self.assertTrue(text)
        self.assertIn(os.path.basename(self.copilot_bin), text)
        # …and NOTHING ELSE ON DISK HOLDS IT. One durable home, the same one
        # the name has: no sidecar json, no per-room metadata file.
        room = self._room("ticket-detail")
        holders = []
        for name in sorted(os.listdir(room)):
            path = os.path.join(room, name)
            if not os.path.isfile(path):
                continue
            with open(path, errors="replace") as fh:
                if self.copilot_bin in fh.read():
                    holders.append(name)
        self.assertEqual(holders, ["transcript.md"], sorted(os.listdir(room)))

    def test_the_engine_is_recorded_the_moment_the_program_is_named(self):
        """A program whose FIRST TURN DIED still knows what it was opened on —
        the same reason the name is written at start rather than on turn 1."""
        self._start("Ticket detail", engine=self.copilot_bin)
        text = self._transcript("ticket-detail")
        self.assertTrue(text)
        self.assertIn(os.path.basename(self.copilot_bin), text)

    # -- S127: THE PICKER'S HALF, at the one moment it applies ----------------
    def test_the_engine_the_dialog_PICKED_spends_on_that_engine_from_turn_one(self):
        """S127 put an engine picker in the New Program dialog, and the daemon
        end of it is this: an engine named in the START body outranks the
        daemon's own `$LCARS_WORKER_BIN` for the very first turn, not just for
        the record. The daemon here defaults to CLAUDE (billed); the pick is
        COPILOT (free), so anything that runs claude is the invoice bug."""
        self._set_turns({"stdout": "First pass is up."})
        sid, _ = self._start("Ticket detail", engine=self.copilot_bin)
        self._post("/api/holodeck/%s/say" % sid, {"text": "Draft the detail"})
        self.assertEqual(self._calls()[-1]["bin"],
                         os.path.basename(self.copilot_bin), self._calls()[-1])

    def test_the_picker_sets_the_engine_at_CREATE_time_only(self):
        """The picker's default must never leak into a REOPEN. A program built
        on copilot reopens on copilot even though a later start picked claude —
        the record outranks anything the dialog last had selected."""
        self._built_on_copilot()
        self._start("Other program", engine=self.claude_bin)
        _s, body = self._post("/api/holodeck/open", {"room": "ticket-detail"})
        self.assertEqual(body["state"]["engine"], self.copilot_bin,
                         body["state"])

    # -- THE MONEY BUG, in the three places it showed itself ------------------
    def test_a_copilot_program_reopens_on_copilot_not_the_daemon_default(self):
        self._built_on_copilot()
        self._restart_daemon()
        _s, body = self._post("/api/holodeck/open", {"room": "ticket-detail"})
        self.assertEqual(body["state"]["engine"], self.copilot_bin,
                         body["state"])

    def test_the_next_turn_after_a_restart_SPENDS_on_the_engine_it_was_built_on(self):
        """THE MONEY. Everything above is a readout; this is the invoice."""
        self._built_on_copilot()
        self._restart_daemon()
        self._set_turns({"stdout": "Back."})
        _s, body = self._post("/api/holodeck/open", {"room": "ticket-detail"})
        sid = body["state"]["sessionId"]
        self._post("/api/holodeck/%s/say" % sid, {"text": "keep going"})
        # the stub records the basename it was invoked as — WHICH CLI RAN.
        self.assertEqual(self._calls()[-1]["bin"],
                         os.path.basename(self.copilot_bin), self._calls()[-1])

    def test_the_warm_restart_banner_names_the_engine_that_will_answer(self):
        self._built_on_copilot()
        self._restart_daemon()
        _s, body = self._post("/api/holodeck/open", {"room": "ticket-detail"})
        msg = body["state"]["warmRestart"]["message"]
        self.assertIn(os.path.basename(self.copilot_bin), msg)
        self.assertNotIn(os.path.basename(self.claude_bin), msg)

    def test_the_archive_listing_says_which_engine_built_each_program(self):
        self._built_on_copilot()
        self._restart_daemon()
        p = self._list()["programs"][0]
        self.assertEqual(p["engine"], self.copilot_bin, p)
        self.assertTrue(p["engineRecorded"], p)

    def test_a_reopened_copilot_program_still_strips_copilot_trace_on_disk(self):
        """The engine is not a label — it decides behaviour. Reopened under a
        claude-default daemon, this program's tool blocks were being written
        into the captain's own record as prose."""
        self._built_on_copilot()
        self._restart_daemon()
        self._set_turns({"stdout": _live("copilot-failed-edit-reply.txt")})
        _s, body = self._post("/api/holodeck/open", {"room": "ticket-detail"})
        sid = body["state"]["sessionId"]
        self._post("/api/holodeck/%s/say" % sid, {"text": "keep going"})
        text = self._transcript("ticket-detail")
        self.assertNotIn("✗ Edit mockup.html", text)
        self.assertIn("decision T4 in concept.md", text)

    # -- the resolution rule, in the order it is stated ----------------------
    def test_an_explicit_engine_wins_over_the_recorded_one(self):
        self._built_on_copilot()
        self._restart_daemon()
        _s, body = self._post("/api/holodeck/open",
                              {"room": "ticket-detail",
                               "engine": self.claude_bin})
        self.assertEqual(body["state"]["engine"], self.claude_bin)

    def test_a_record_that_predates_this_falls_back_and_SAYS_it_does_not_know(self):
        """HONEST DEGRADATION. Every program written before this round has no
        engine in its record, and "built on claude" would be an invention."""
        self._built_on_copilot()
        # A PRE-ROUND-5 RECORD, written out exactly as the old header wrote it:
        # the name heading, the boilerplate, and the turns. Nothing else.
        path = os.path.join(self._room("ticket-detail"), "transcript.md")
        with open(path, "w") as fh:
            fh.write("# Ticket detail\n\n"
                     "The holodeck's record of this program: one entry per "
                     "turn, in the order it happened.\n"
                     "\n## Turn 1 · 2026-08-05T00:00:00Z\n"
                     "\n**Captain:** Draft the detail\n"
                     "\n**Holodeck:** First pass is up.\n")
        self._restart_daemon()
        p = self._list()["programs"][0]
        self.assertEqual(p["engine"], self.claude_bin, p)
        self.assertFalse(p["engineRecorded"], p)
        _s, body = self._post("/api/holodeck/open", {"room": "ticket-detail"})
        state = body["state"]
        self.assertEqual(state["engine"], self.claude_bin)
        self.assertFalse(state["engineRecorded"])
        msg = state["warmRestart"]["message"]
        self.assertIn(os.path.basename(self.claude_bin), msg)
        # it never claims the program was BUILT on it.
        low = msg.lower()
        self.assertTrue("does not say" in low or "no record" in low
                        or "not recorded" in low, msg)

    def test_a_live_program_reports_its_engine_as_recorded(self):
        sid = self._built_on_copilot()
        state = self._get("/api/holodeck/%s" % sid)
        self.assertEqual(state["engine"], self.copilot_bin)
        self.assertTrue(state["engineRecorded"])


# ════════════════════════════════════════════════════════════════════════════
# FIX ROUND 5 — COPILOT'S THIRD BLOCK FORM
#
# The comment above `_COPILOT_BLOCK_HEAD` asserted "TWO FORMS AND NO THIRD".
# A live copilot drive printed a third — the FAILED tool block — and it sat
# verbatim in a real `transcript.md`, rendered to the captain as prose:
#
#     ✗ Edit mockup.html
#       └ Multiple matches found
#
# The bytes are committed at `copilot-failed-edit-reply.txt`.
# ════════════════════════════════════════════════════════════════════════════
class CopilotFailedBlockTest(DurableBase):
    def _strip(self, text, engine):
        from lcars_serve.actions import _strip_tool_trace
        return _strip_tool_trace(text, engine)

    def test_the_failed_block_copilot_really_printed_is_not_prose(self):
        got = self._strip(_live("copilot-failed-edit-reply.txt"),
                          self.copilot_bin)
        self.assertNotIn("✗ Edit mockup.html", got)
        self.assertNotIn("Multiple matches found", got)

    def test_the_prose_of_that_same_turn_is_whole(self):
        """Both halves or neither proves. These two sentences are the captain's
        entire turn once the plumbing is out."""
        got = self._strip(_live("copilot-failed-edit-reply.txt"),
                          self.copilot_bin)
        for line in ("I'll add a Density toggle chip so the `.compact` class "
                     "is reachable, then record the decision.",
                     "I added a `.compact` class on the board that halves card "
                     "padding (10px 14px → 5px 7px), reachable via a new "
                     "Compact chip in the topbar, and recorded it as decision "
                     "T4 in concept.md. The board now toggles density in place "
                     "without changing the lanes or the accent-bar motif."):
            self.assertIn(line, got, line)

    def test_a_failed_head_the_cli_never_closed_is_the_captain_writing(self):
        """THE SAME STRUCTURAL RULE, not a guess: the `└` row is REQUIRED. A
        `✗` bullet with no closing row is somebody making a point."""
        note = "✗ Delete the old rail (it never shipped)."
        for engine in (self.claude_bin, self.copilot_bin):
            self.assertEqual(self._strip(note, engine), note,
                             os.path.basename(engine))

    def test_claude_never_loses_a_failed_shaped_bullet(self):
        text = _live("copilot-failed-edit-reply.txt")
        self.assertEqual(self._strip(text, self.claude_bin), text.strip("\n"))

    def test_the_code_no_longer_asserts_a_third_form_cannot_exist(self):
        """The comment was FALSE and the code was reading as authority. A
        claim nobody can check is the thing that let this survive a round."""
        from lcars_serve.actions import _COPILOT_BLOCK_HEAD
        import lcars_serve.actions as actions
        with open(actions.__file__.replace(".pyc", ".py")) as fh:
            src = fh.read()
        # the assertion itself is gone (it may still be QUOTED as the thing
        # that was wrong — that is a record, not a claim)…
        self.assertNotIn("TWO FORMS AND NO THIRD:", src)
        # …the third form is named with the bytes that prove it…
        self.assertIn("copilot-failed-edit-reply.txt", src)
        # …and the parser knows the head copilot actually printed.
        self.assertTrue(_COPILOT_BLOCK_HEAD.match("✗ Edit mockup.html"))


class DurableReadOnlyTest(HolodeckBase):
    read_only = True

    def test_the_new_write_routes_are_refused_on_a_read_only_daemon(self):
        for path, body in (("/api/holodeck/open", {"room": "x"}),
                           ("/api/holodeck/delete", {"room": "x"}),
                           # S127 — the hand-off is a WRITE like its siblings.
                           ("/api/holodeck/abc123/promote", {})):
            st, resp = self._post_raw(path, body)
            self.assertEqual(st, 403, path)
            self.assertIn("read-only", resp["error"])
        self.assertEqual(os.listdir(self.holo_root), [])


# ════════════════════════════════════════════════════════════════════════════
# S127 — THE HAND-OFF: SEND TO ALIGN
#
# The captain's acceptance bar, in his own words: he describes what he wants,
# the holodeck handles the attachments ITSELF, the File console comes up
# already good to go, and the card lands on the board. "He never types a file
# path, never juggles --attach, never copies a file, and never sees the
# plumbing."
#
# The security property that bar implies, and which everything below is really
# testing: the BROWSER NEVER SENDS A FILESYSTEM PATH. It sends the program's
# session id and nothing else; the daemon re-resolves that program's room and
# expands it to `--attach` arguments through the SAME jail `holodeck_preview`
# uses. A path in the request body would be a path the page could choose.
# ════════════════════════════════════════════════════════════════════════════

# The file.sh stub the hand-off suites need. The plain `_file_record_stub`
# records `$*` and exits — enough for "was it called", useless for "what did it
# actually receive", because the PRD/idea text arrives as a TEMP FILE that the
# daemon unlinks in a `finally`. This one snapshots the CONTENT of every
# `--prd`/`--idea`/`--adr` file before returning, and (when asked) MINTS a
# mission directory so the lifecycle's "record the mission id" claim is tested
# against a mission that really appeared rather than against a mock.
_FILE_STUB_SRC = r'''import json, os, sys

CFG = json.loads(open(%(cfg)r).read())
argv = sys.argv[1:]
rec = {"argv": argv, "files": {}}
for i, a in enumerate(argv):
    if a in ("--prd", "--idea", "--adr") and i + 1 < len(argv):
        try:
            with open(argv[i + 1]) as fh:
                rec["files"][a] = fh.read()
        except OSError:
            rec["files"][a] = None
if CFG.get("mint"):
    mid = CFG["mint"]
    d = os.path.join(os.getcwd(), ".git", "lcars", "missions", mid)
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "state.json"), "w") as fh:
        json.dump({"id": mid, "stage": "align", "title": "from the holodeck"}, fh)
rec["exit"] = int(CFG.get("exit", 0))
with open(CFG["record"], "a") as fh:
    fh.write(json.dumps(rec) + "\n")
sys.exit(int(CFG.get("exit", 0)))
'''


class HandoffBase(DurableBase):
    """A program whose room holds a real mockup + a real concept doc.

    The fixtures are TRANSCRIBED from the shape a live holodeck turn actually
    produces (`<sidecar>/command-palette/`, 2026-08-05): the mockup opens with
    the self-describing "VISUAL REFERENCE ONLY" comment the turn prompt asks
    for, and the concept doc carries the real section headings — including the
    `## Hand-off summary` the seeded brief is built from.
    """

    MOCKUP = ("<!doctype html>\n"
              "<!--\n"
              "  VISUAL REFERENCE ONLY — this is a mockup, not shipping code.\n"
              "-->\n"
              "<html><body><h1>Command palette</h1></body></html>\n")
    SUMMARY = ("Build a Cmd-K command palette overlay for the board: a centred "
               "panel with a search input, a fuzzy-matched command list, and "
               "the most recently run command pinned alone at the top.")
    CONCEPT = ("# Command Palette\n\n"
               "## The problem\n\nThe captain wants a palette.\n\n"
               "## Decisions\n\n- **Turn 2:** Cmd-K opens it.\n\n"
               "## Open questions\n\n1. What is the command list?\n\n"
               "## WHAT IT MUST DO — BEHAVIOUR ONLY\n\n### 1. Requirements\n\n"
               "- **Turn 2:** \"Cmd-K opens it, Escape closes it.\"\n\n"
               "## DECLARED FLOW\n\n`board` → `Cmd-K` → `palette open`\n\n"
               "## Hand-off summary\n\n" + SUMMARY + "\n")

    mint = "m-777"
    file_exit = 0

    def setUp(self):
        super(HandoffBase, self).setUp()
        self.file_cfg = os.path.join(self.tmp, "file-stub-cfg.json")
        with open(self.file_cfg, "w") as fh:
            json.dump({"record": self.records["file"], "mint": self.mint,
                       "exit": self.file_exit}, fh)
        # The daemon dispatches every skill as `bash <script>` (`_resolve_run`),
        # so the SCRIPT stays bash and hands off to python for the JSON work —
        # expressing "snapshot this temp file's contents" in bash quoting is how
        # a fixture starts lying.
        py = os.path.join(self.tmp, "file-stub.py")
        with open(py, "w") as fh:
            fh.write(_FILE_STUB_SRC % {"cfg": self.file_cfg})
        with open(self.scripts["file"], "w") as fh:
            fh.write('#!/usr/bin/env bash\nexec %s %s "$@"\n'
                     % (shlex.quote(sys.executable), shlex.quote(py)))
        os.chmod(self.scripts["file"], 0o755)

    # -- helpers -------------------------------------------------------------
    def _filed(self):
        """Every recorded file.sh dispatch: {argv, files}."""
        p = self.records["file"]
        if not os.path.exists(p):
            return []
        out = []
        with open(p) as fh:
            for line in fh:
                if line.strip():
                    out.append(json.loads(line))
        return out

    @staticmethod
    def _attached(rec):
        argv = rec["argv"]
        return [argv[i + 1] for i, a in enumerate(argv)
                if a == "--attach" and i + 1 < len(argv)]

    def _program(self, mockup=True, concept=True):
        """Open a program and put the hand-off files in its room. The files are
        written through a real TURN (the stub's `writes`), not planted behind
        the daemon's back — a hand-off must work on a room the product made."""
        writes = []
        if mockup:
            writes.append({"path": "mockup.html", "content": self.MOCKUP})
        if concept:
            writes.append({"path": "concept.md", "content": self.CONCEPT})
        self._set_turns({"stdout": "Built the palette.", "writes": writes})
        sid, _ = self._start(program="Command palette")
        self._post("/api/holodeck/%s/say" % sid, {"text": "draft it"})
        return sid

    def _promote(self, sid, **body):
        return self._post_raw("/api/holodeck/%s/promote" % sid, body)


# ── 1. the SEND TO ALIGN action itself ──────────────────────────────────────
class PromoteTest(HandoffBase):
    def test_it_refuses_a_program_with_no_mockup_in_LCARS_voice(self):
        sid = self._program(mockup=False)
        st, body = self._promote(sid)
        self.assertEqual(st, 409, body)
        msg = body["error"]
        self.assertIn("mockup.html", msg)
        # it says what the captain should DO — not just what is wrong.
        self.assertRegex(msg.lower(), r"ask|describe|chat")
        for jargon in ("traceback", "oserror", "errno", "none", "exception"):
            self.assertNotIn(jargon, msg.lower(), jargon)

    def test_it_refuses_a_program_with_no_concept_doc(self):
        sid = self._program(concept=False)
        st, body = self._promote(sid)
        self.assertEqual(st, 409, body)
        self.assertIn("concept.md", body["error"])

    def test_it_names_BOTH_when_both_are_missing(self):
        sid = self._program(mockup=False, concept=False)
        st, body = self._promote(sid)
        self.assertEqual(st, 409, body)
        self.assertIn("mockup.html", body["error"])
        self.assertIn("concept.md", body["error"])

    def test_an_unknown_program_is_a_clean_404(self):
        st, body = self._promote("nosuchsession")
        self.assertEqual(st, 404, body)
        self.assertIn("no such holodeck program", body["error"])

    # -- the payload: a PRE-SEEDED File console ------------------------------
    def test_the_brief_is_seeded_from_the_concept_hand_off_summary(self):
        sid = self._program()
        st, body = self._promote(sid)
        self.assertEqual(st, 200, body)
        state = body["state"]
        self.assertIn(self.SUMMARY, state["brief"])
        self.assertEqual(state["summarySource"], "Hand-off summary")

    def test_the_guidance_carries_the_precedence_rule_VERBATIM(self):
        sid = self._program()
        _st, body = self._promote(sid)
        self.assertIn(
            "Where the mockup and the brief disagree, the brief wins.",
            body["state"]["guidance"])

    def test_the_guidance_says_the_mockup_is_look_and_flow_only_and_fake(self):
        sid = self._program()
        _st, body = self._promote(sid)
        g = body["state"]["guidance"]
        self.assertIn("look and flow", g.lower())
        self.assertIn("internals are deliberately fake", g.lower())
        self.assertIn("not an implementation", g.lower())

    def test_visual_fidelity_arrives_as_an_ACCEPTANCE_CRITERION(self):
        """S127's Failure 1 is GRADED, not hoped for — the precedent is this
        repo's own board, vendored from a mockup with 'high visual fidelity'
        an explicit acceptance bar."""
        sid = self._program()
        _st, body = self._promote(sid)
        self.assertIn("acceptance criterion", body["state"]["guidance"].lower())

    def test_the_default_build_scope_is_look_plus_behaviour(self):
        sid = self._program()
        _st, body = self._promote(sid)
        self.assertEqual(body["state"]["scope"], "look+behaviour")
        self.assertIn("look-only", body["state"]["scopeOptions"])

    def test_look_only_carries_a_no_functional_change_constraint(self):
        sid = self._program()
        _st, body = self._promote(sid, scope="look-only")
        self.assertEqual(body["state"]["scope"], "look-only")
        self.assertIn("no functional change",
                      body["state"]["guidance"].lower())

    def test_look_plus_behaviour_says_the_brief_defines_what_it_must_do(self):
        sid = self._program()
        _st, body = self._promote(sid)
        g = body["state"]["guidance"].lower()
        self.assertIn("what it must do", g)
        self.assertNotIn("no functional change", g)

    def test_an_unknown_scope_is_refused_rather_than_silently_defaulted(self):
        sid = self._program()
        st, body = self._promote(sid, scope="just-the-vibes")
        self.assertEqual(st, 400, body)
        self.assertIn("look-only", body["error"])

    def test_the_payload_lists_what_rides_along_BY_NAME(self):
        sid = self._program()
        _st, body = self._promote(sid)
        self.assertEqual([r["name"] for r in body["state"]["rides"]],
                         ["mockup.html", "concept.md"])

    def test_the_payload_contains_NO_FILESYSTEM_PATH_AT_ALL(self):
        """The captain never sees the plumbing — and a path the page can read
        is a path the page can send back. The whole payload is searched, not
        one field, because a leak is a leak wherever it lands."""
        sid = self._program()
        _st, body = self._promote(sid)
        blob = json.dumps(body["state"])
        for leak in (self.tmp, self.holo_root, self._sidecar(), self._room(),
                     os.sep + "Users", "/tmp/"):
            self.assertNotIn(leak, blob, leak)

    def test_promote_spawns_no_worker_and_writes_no_mission_state(self):
        sid = self._program()
        before = len(self._calls())
        self._promote(sid)
        self.assertEqual(len(self._calls()), before)
        self.assertEqual(self._filed(), [])


# ── 2. the attachments ride, and the browser never names a path ─────────────
class HandoffAttachmentsTest(HandoffBase):
    def _room_files(self):
        # realpath'd: the jail resolves symlinks (that IS the check), and on
        # macOS `/var` is a symlink to `/private/var`.
        return [os.path.realpath(os.path.join(self._room("command-palette"), n))
                for n in ("mockup.html", "concept.md")]

    def test_park_attaches_the_mockup_and_the_concept_by_SESSION_ID_alone(self):
        sid = self._program()
        st, _body = self._post("/api/park", {"idea": "build the palette",
                                             "holodeck": sid})
        self.assertEqual(st, 200)
        recs = self._filed()
        self.assertEqual(len(recs), 1, recs)
        self.assertEqual(self._attached(recs[0]), self._room_files())

    def test_file_mission_attaches_them_too(self):
        sid = self._program()
        self._post("/api/mission", {"idea": "build the palette",
                                    "holodeck": sid})
        recs = self._filed()
        self.assertEqual(self._attached(recs[0]), self._room_files())

    def test_the_guidance_reaches_the_filed_text_verbatim(self):
        """The DAEMON appends it, not the browser: what the console showed and
        what the mission is told are then the same words by construction."""
        sid = self._program()
        self._post("/api/park", {"idea": "build the palette", "holodeck": sid})
        text = self._filed()[0]["files"]["--idea"]
        self.assertIn("build the palette", text)
        self.assertIn("Where the mockup and the brief disagree, the brief wins.",
                      text)
        self.assertIn("acceptance criterion", text.lower())

    def test_the_chosen_scope_reaches_the_filed_text(self):
        sid = self._program()
        self._post("/api/park", {"idea": "reskin it", "holodeck": sid,
                                 "holodeckScope": "look-only"})
        text = self._filed()[0]["files"]["--idea"]
        self.assertIn("no functional change", text.lower())

    def test_a_mission_with_NO_holodeck_is_completely_unchanged(self):
        self._post("/api/park", {"idea": "something ordinary"})
        rec = self._filed()[0]
        self.assertEqual(self._attached(rec), [])
        self.assertNotIn("mockup", rec["files"]["--idea"].lower())

    # -- the jail ------------------------------------------------------------
    def test_a_CRAFTED_program_id_cannot_reach_a_file_outside_the_sidecar(self):
        """A traversal, an absolute path and a room name are all just strings
        the page could put in `holodeck`. None of them resolves to anything —
        the id is a key into the daemon's OWN session table, so nothing the
        browser types can name a file."""
        self._program()
        outside = os.path.join(self.repo, "secret.txt")
        with open(outside, "w") as fh:
            fh.write("classified")
        for crafted in ("../../etc/passwd", "/etc/passwd", outside,
                        "command-palette", "..", ".", "nav-rail/../../.."):
            st, body = self._post_raw("/api/park", {"idea": "x",
                                                    "holodeck": crafted})
            self.assertEqual(st, 404, "%s → %s" % (crafted, body))
            self.assertIn("no such holodeck program", body["error"])
        # …and nothing was filed on any of those attempts.
        self.assertEqual(self._filed(), [])

    def test_a_SYMLINKED_mockup_pointing_out_of_the_room_is_refused(self):
        """The realpath re-check `holodeck_preview` already does, reused rather
        than rewritten: a symlink normpaths clean and only shows up there."""
        sid = self._program()
        room = self._room("command-palette")
        outside = os.path.join(self.repo, "not-a-mockup.html")
        with open(outside, "w") as fh:
            fh.write("<h1>the captain's real file")
        os.unlink(os.path.join(room, "mockup.html"))
        os.symlink(outside, os.path.join(room, "mockup.html"))
        st, body = self._promote(sid)
        self.assertEqual(st, 403, body)
        self.assertEqual(self._filed(), [])
        st, body = self._post_raw("/api/park", {"idea": "x", "holodeck": sid})
        self.assertEqual(st, 403, body)
        self.assertEqual(self._filed(), [])

    def test_a_SYMLINKED_concept_doc_pointing_out_of_the_room_is_refused(self):
        sid = self._program()
        room = self._room("command-palette")
        outside = os.path.join(self.repo, "elsewhere.md")
        with open(outside, "w") as fh:
            fh.write("# not this")
        os.unlink(os.path.join(room, "concept.md"))
        os.symlink(outside, os.path.join(room, "concept.md"))
        st, _body = self._promote(sid)
        self.assertEqual(st, 403)


# ── 3. the program LIFECYCLE: sending LOCKS it (D11) ────────────────────────
class HandoffLifecycleTest(HandoffBase):
    def test_a_sent_program_reads_sent_and_carries_its_mission(self):
        sid = self._program()
        self.assertEqual(self._get("/api/holodeck/%s" % sid)["status"], "draft")
        _st, body = self._post("/api/park", {"idea": "go", "holodeck": sid})
        self.assertEqual(body["state"]["holodeck"]["status"], "sent")
        self.assertEqual(body["state"]["holodeck"]["missionId"], self.mint)
        state = self._get("/api/holodeck/%s" % sid)
        self.assertEqual(state["status"], "sent")
        self.assertEqual(state["missionId"], self.mint)

    def test_the_lock_SURVIVES_a_daemon_restart(self):
        sid = self._program()
        before = sorted(os.listdir(self._room("command-palette")))
        self._post("/api/park", {"idea": "go", "holodeck": sid})
        self.assertEqual(sorted(os.listdir(self._room("command-palette"))),
                         before)
        self._restart_daemon()
        rooms = {p["room"]: p for p in self._list()["programs"]}
        self.assertEqual(rooms["command-palette"]["status"], "sent")
        self.assertEqual(rooms["command-palette"]["missionId"], self.mint)
        # …and it is remembered in the ONE durable home the program already
        # has. No second metadata file — that is the money bug S126 cured.
        self.assertEqual(sorted(os.listdir(self._room("command-palette"))),
                         before)
        self.assertIn("transcript.md", before)

    def test_reopening_a_sent_room_keeps_it_sent(self):
        sid = self._program()
        self._post("/api/park", {"idea": "go", "holodeck": sid})
        self._restart_daemon()
        _st, body = self._post("/api/holodeck/open", {"room": "command-palette"})
        # `lifecycle`, not `status`: a reopen payload's `status` is the TURN's
        # ("standing-by"), which is why the lifecycle has a key of its own.
        self.assertEqual(body["state"]["lifecycle"], "sent")
        self.assertEqual(body["state"]["missionId"], self.mint)

    def test_a_sent_program_refuses_further_turns_in_LCARS_language(self):
        sid = self._program()
        self._post("/api/park", {"idea": "go", "holodeck": sid})
        before = len(self._calls())
        st, body = self._post_raw("/api/holodeck/%s/say" % sid,
                                  {"text": "make it wider"})
        self.assertEqual(st, 409, body)
        msg = body["error"]
        self.assertIn(self.mint, msg)
        self.assertIn("DUPLICATE TO KEEP DESIGNING", msg)
        for jargon in ("traceback", "409", "actionerror"):
            self.assertNotIn(jargon, msg.lower(), jargon)
        # and no worker was spawned for the refused turn.
        self.assertEqual(len(self._calls()), before)

    def test_a_sent_program_cannot_be_sent_twice(self):
        sid = self._program()
        self._post("/api/park", {"idea": "go", "holodeck": sid})
        st, body = self._promote(sid)
        self.assertEqual(st, 409, body)
        self.assertIn(self.mint, body["error"])

    def test_a_DRAFT_program_still_takes_turns(self):
        """The control — without it a daemon that refused every turn would
        pass the lock test."""
        sid = self._program()
        st, body = self._post_raw("/api/holodeck/%s/say" % sid,
                                  {"text": "make it wider"})
        self.assertEqual(st, 200, body)

    def test_the_transcript_records_the_hand_off_where_the_ENGINE_is_recorded(self):
        sid = self._program()
        self._post("/api/park", {"idea": "go", "holodeck": sid})
        text = self._transcript("command-palette")
        self.assertIn(self.mint, text)
        # the record's HEADER, above the first turn — the same place, and the
        # same reason, as the engine line.
        head = text.split("## Turn", 1)[0]
        self.assertIn(self.mint, head)
        # nothing a model wrote was rewritten.
        self.assertIn("**Captain:** draft it", text)


class HandoffThroughTheGrillTest(HandoffBase):
    """The OTHER road: ▹ FILE & BEGIN ALIGNMENT rather than ▦ FILE MISSION.

    Both must carry the artifacts, or one of the two buttons on the console
    silently drops them — which is the exact shape of a green-but-wrong.
    """

    def _grill_reply(self, obj):
        self._set_turns({"stdout": json.dumps(obj)})

    def test_a_grill_started_from_the_holodeck_files_with_the_attachments(self):
        sid = self._program()
        self._grill_reply({"status": "done", "prd": "# PRD\n\nbuild it"})
        st, body = self._post("/api/align/start",
                              {"idea": "build the palette", "holodeck": sid,
                               "engine": self.claude_bin})
        self.assertEqual(st, 200, body)
        self.assertEqual(body["state"]["status"], "done", body)
        rec = self._filed()[0]
        self.assertEqual(
            self._attached(rec),
            [os.path.realpath(os.path.join(self._room("command-palette"), n))
             for n in ("mockup.html", "concept.md")])

    def test_the_grill_is_told_the_guidance_in_its_opening_turn(self):
        sid = self._program()
        self._grill_reply({"status": "question",
                           "question": {"text": "which screens?"}})
        self._post("/api/align/start",
                   {"idea": "build the palette", "holodeck": sid,
                    "engine": self.claude_bin})
        prompt = self._prompts()[-1]
        self.assertIn("Where the mockup and the brief disagree, the brief wins.",
                      prompt)

    def test_it_locks_the_program_when_the_grill_completes(self):
        sid = self._program()
        self._grill_reply({"status": "done", "prd": "# PRD\n\nbuild it"})
        _st, body = self._post("/api/align/start",
                               {"idea": "build it", "holodeck": sid,
                                "engine": self.claude_bin})
        self.assertEqual(body["state"]["holodeck"]["missionId"], self.mint)
        self.assertEqual(self._get("/api/holodeck/%s" % sid)["status"], "sent")

    def test_a_program_ENDED_mid_grill_still_files_and_SAYS_what_was_lost(self):
        """A finished grill's PRD cost real tokens and exists nowhere else.
        Refusing at the done branch to protect an attachment would throw it
        away — so the mission is filed, and the response says plainly that the
        artifacts did not ride."""
        sid = self._program()
        self._grill_reply({"status": "question",
                           "question": {"text": "which screens?"}})
        _st, body = self._post("/api/align/start",
                               {"idea": "build it", "holodeck": sid,
                                "engine": self.claude_bin})
        asid = body["state"]["sessionId"]
        self._post("/api/holodeck/%s/end" % sid, {})   # he closed the program
        self._grill_reply({"status": "done", "prd": "# PRD\n\nbuild it"})
        st, body = self._post("/api/align/%s/answer" % asid, {"answer": "go"})
        self.assertEqual(st, 200, body)
        self.assertEqual(len(self._filed()), 1, self._filed())
        self.assertEqual(self._attached(self._filed()[0]), [])
        warn = body["state"]["holodeck"]["warning"]
        self.assertIn("did NOT ride", warn)
        self.assertFalse(body["state"]["holodeck"]["locked"])

    def test_a_LOCKED_program_is_refused_BEFORE_a_grill_worker_is_spawned(self):
        sid = self._program()
        self._post("/api/park", {"idea": "go", "holodeck": sid})
        before = len(self._calls())
        st, body = self._post_raw("/api/align/start",
                                  {"idea": "again", "holodeck": sid,
                                   "engine": self.claude_bin})
        self.assertEqual(st, 409, body)
        self.assertEqual(len(self._calls()), before)


class HandoffFailedFilingTest(HandoffBase):
    file_exit = 1

    def test_a_filing_that_FAILED_leaves_the_program_a_draft(self):
        """A lock is a claim that a mission holds this exact design. If no
        mission was filed, the claim is false — and the captain would be locked
        out of the program for nothing."""
        sid = self._program()
        st, body = self._post_raw("/api/park", {"idea": "go", "holodeck": sid})
        self.assertNotEqual(st, 200, body)
        self.assertEqual(self._get("/api/holodeck/%s" % sid)["status"], "draft")
        st, _b = self._post_raw("/api/holodeck/%s/say" % sid, {"text": "more"})
        self.assertEqual(st, 200)


if __name__ == "__main__":
    unittest.main()

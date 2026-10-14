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
import base64
import json
import os
import re
import shlex
import shutil
import struct
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import unittest.mock
import urllib.error
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from tests import _fixtures as fx  # noqa: E402
from lcars_serve.local_adapter import LocalAdapter  # noqa: E402
from lcars_serve.server import make_server  # noqa: E402
from lcars_serve.actions import Actions, _program_room, _SLUG_MAX  # noqa: E402


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
    # S169 fix round 2. `promote` now spawns ONE bounded read-only worker to
    # read the drafted change list back against the mockup. Every base below
    # drives a STUBBED engine off a shared queue of canned turns, so leaving it
    # on would have `promote` quietly consume the next turn out from under the
    # test that queued it — a fixture lying about which turn ran. The classes
    # that exercise the check turn it on explicitly and stub a reply for it.
    handoff_check = "0"

    def setUp(self):
        self._old_check = os.environ.get("LCARS_HOLODECK_HANDOFF_CHECK")
        os.environ["LCARS_HOLODECK_HANDOFF_CHECK"] = self.handoff_check
        self.addCleanup(self._restore_check)
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

    def _restore_check(self):
        if self._old_check is None:
            os.environ.pop("LCARS_HOLODECK_HANDOFF_CHECK", None)
        else:
            os.environ["LCARS_HOLODECK_HANDOFF_CHECK"] = self._old_check

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


def _blank_runs(text):
    """The lengths of every run of 2+ consecutive blank lines, in order."""
    runs, run = [], 0
    for line in text.split("\n"):
        if not line.strip():
            run += 1
            continue
        if run >= 2:
            runs.append(run)
        run = 0
    if run >= 2:
        runs.append(run)
    return runs


class BlankScarTest(DurableBase):
    """S128 / FL-005 (a) — the HOLE a removed tool block leaves behind.

    Confirmed LIVE, not from a fixture: a real grounding pass wrote a
    `basis.md` of 120 lines, 49 of them blank, with the model's narration
    ("Let me read the actual styles and components") floating over the gaps
    where copilot's tool blocks used to be.

    The cure asks NOTHING about prose. It looks at exactly one property of a
    line — whether it is blank — and only ever at the lines immediately
    following a removal the STRUCTURAL parser already made. It can never delete
    a character the model wrote, only blank lines that were separating a block
    from the text around it."""

    def _strip(self, text, engine):
        from lcars_serve.actions import _strip_tool_trace
        return _strip_tool_trace(text, engine)

    def test_the_live_grounding_reply_arrives_with_no_double_blanks(self):
        """THE 49. Measured both ways so a partial cure cannot read as a whole
        one: copilot's own captured reply has NO run of 2+ blank lines before
        the strip, so every run after it is a scar the strip itself made."""
        raw = _live("copilot-grounding-reply.txt")
        self.assertEqual(_blank_runs(raw), [],
                         "the fixture itself has a double blank — the "
                         "measurement below would not mean what it says")
        got = self._strip(raw, self.copilot_bin)
        self.assertEqual(_blank_runs(got), [],
                         "%d blank-line scars left in basis.md"
                         % len(_blank_runs(got)))

    def test_a_removal_never_costs_the_model_a_line(self):
        """The other half: the same reply's PROSE, byte for byte and in order,
        blank lines included where the model put them singly."""
        raw = _live("copilot-grounding-reply.txt")
        prose = [l for l in raw.replace("\r\n", "\n").split("\n")
                 if l.strip() and not l.startswith(("● ", "/ ", "  │ ", "  └ "))]
        got = [l for l in self._strip(raw, self.copilot_bin).split("\n")
               if l.strip()]
        self.assertEqual(got, prose)

    def test_a_paragraph_break_the_model_wrote_survives(self):
        """A single blank line between two paragraphs is the model writing, and
        a removal beside it collapses to ONE blank — never to none."""
        text = ("The rail is up.\n"
                "\n"
                "● Read board.css\n"
                "  │ web/static/board.css\n"
                "  └ L1:200 (200 lines read)\n"
                "\n"
                "Now the swatches.\n")
        self.assertEqual(self._strip(text, self.copilot_bin),
                         "The rail is up.\n\nNow the swatches.")

    def test_a_deliberate_blank_run_with_no_removal_beside_it_is_untouched(self):
        """Nothing is collapsed where nothing was removed. A model that wrote
        three blank lines in a row keeps all three."""
        text = ("The rail is up.\n\n\n\nNow the swatches.\n")
        for engine in (self.claude_bin, self.copilot_bin):
            self.assertEqual(self._strip(text, engine), text.strip("\n"),
                             os.path.basename(engine))

    def test_blank_lines_inside_a_fence_are_never_collapsed(self):
        """S125 shipped a cleverer regex that silently deleted ASCII diagrams,
        and it was cured by deletion. A fence is the captain quoting: the
        collapse cannot reach inside one, because no removal happens there."""
        text = ("Here is the shape:\n"
                "\n"
                "```\n"
                "┌────────────┐\n"
                "\n"
                "\n"
                "│  SWATCHES  │\n"
                "└────────────┘\n"
                "```\n"
                "\n"
                "● Edit mockup.html +8 -6\n"
                "\n"
                "Done.\n")
        got = self._strip(text, self.copilot_bin)
        self.assertIn("┌────────────┐\n\n\n│  SWATCHES  │", got)
        self.assertNotIn("● Edit mockup.html +8 -6", got)
        self.assertEqual(got.split("```")[-1], "\n\nDone.")

    def test_a_reply_that_is_only_tool_blocks_leaves_no_leading_blank(self):
        from lcars_serve.actions import _strip_tool_trace
        self.assertEqual(
            _strip_tool_trace(COPILOT_TOOL_BLOCKS + "\nThe rail is up.\n",
                              self.copilot_bin),
            "The rail is up.")


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
        for section in ("the problem", "decisions", "open questions"):
            self.assertIn(section, low, section)
        # …the intent capture and its THREE buckets, in the captain's own words…
        self.assertIn("WHAT IT MUST DO", prompt)
        self.assertIn("out of scope", low)
        self.assertIn("implied", low)
        self.assertIn("own words", low)
        # …and D4's declared flow, with a concrete shape to copy.
        self.assertIn("DECLARED FLOW", prompt)
        self.assertIn("→", prompt)

    def test_the_contract_no_longer_asks_for_a_section_nothing_reads(self):
        """S128. `## Hand-off summary` was the ONE paragraph `promote` used to
        draft the brief from, and it was never maintained turn by turn — which
        is FL-011, the defect that cost the captain his theme. The brief is now
        built from `## WHAT IT MUST DO`, which IS maintained.

        Nothing reads the summary any more, so the contract must stop asking
        for it: an unmaintained section the product still requests is how the
        defect walks back in — the next reader assumes something downstream
        needs it.

        S171 — AND THE FALLBACK LADDER THAT USED TO NAME IT IS GONE TOO.
        `_HANDOFF_SECTIONS` was deleted with `_handoff_head`; the brief's head
        is the captain's own opening description now, so there is no list of
        sections a draft can be composed from and nothing to assert against.
        The claim is made directly instead: the WHOLE MODULE never names the
        summary."""
        from lcars_serve import actions as A
        from lcars_serve.actions import _CONCEPT_CONTRACT
        self.assertNotIn("hand-off summary", _CONCEPT_CONTRACT.lower())
        self.assertNotIn("handoff summary", _CONCEPT_CONTRACT.lower())
        # and the reason it can go: no consumer, stated as an assertion. Read
        # off the source, so a new reader of it goes red here.
        src = open(A.__file__).read()
        for line in src.split("\n"):
            bare = line.strip()
            if bare.startswith("#") or bare.startswith("*"):
                continue
            self.assertNotIn("Hand-off summary", bare, line)
        self._set_turns({"stdout": "Up."})
        sid, _ = self._start()
        self._post("/api/holodeck/%s/say" % sid, {"text": "go"})
        self.assertNotIn("hand-off summary", self._prompts()[0].lower())

    def test_the_section_the_brief_IS_built_from_is_still_demanded(self):
        """The other half: dropping the stale section must not quietly drop the
        live one. `WHAT IT MUST DO` is what `promote` reads."""
        from lcars_serve.actions import (_CONCEPT_CONTRACT,
                                         _HANDOFF_REQ_HEADING,
                                         _HANDOFF_QUESTION_HEADING)
        self.assertIn(_HANDOFF_REQ_HEADING, _CONCEPT_CONTRACT)
        self.assertIn(_HANDOFF_QUESTION_HEADING, _CONCEPT_CONTRACT)

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

    def test_safety_refusal_is_409_when_git_cannot_record_the_room(self):
        self._dead_first_turn()
        # A healthy git repo with an ignored room: add refuses, and ls-tree
        # correctly reports that deletion would be unrecoverable.
        with open(os.path.join(self._sidecar(), ".gitignore"), "w") as fh:
            fh.write("nav-rail/\n")
        st, body = self._post_raw("/api/holodeck/delete", {"room": "nav-rail"})
        self.assertEqual(st, 409, body)
        self.assertIn("NOTHING HAS BEEN REMOVED", body["error"])
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


class RoomNameTest(DurableBase):
    """S128 / FL-005 (b) — a room name cut at a WORD, not at character 48.

    Measured live: a program started from a whole idea sentence got the room
    `i-want-to-give-the-top-tool-bar-and-edit-selecti`, and that string is its
    permanent identity in the captain's archive.

    THE HAZARD this suite exists for: `_slug` is the on-disk directory name of
    every program he has ALREADY made, so changing the algorithm naively
    orphans them. Every test below that says "still works" drives the real
    endpoints against a room planted under the OLD naming."""

    LONG = ("I want to give the top tool bar and edit selection a much "
            "cleaner treatment")
    OLD_ROOM = "i-want-to-give-the-top-tool-bar-and-edit-selecti"
    NEW_ROOM = "i-want-to-give-the-top-tool-bar-and-edit"

    def _plant_legacy_room(self, name=None, room=None):
        """A room exactly as an older LCARS left it: the legacy directory name,
        with the program's own record in it."""
        room = room or self.OLD_ROOM
        sidecar = self.actions._ensure_sidecar(self.repo)
        d = os.path.join(sidecar, room)
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "transcript.md"), "w") as fh:
            fh.write("# %s\n\n**Engine:** claude\n\n"
                     "## Turn 1 · 2026-08-05 10:00\n\n"
                     "**Captain:** draft it\n\n**LCARS:** Drafted.\n"
                     % (name or self.LONG))
        return d

    # ── the cosmetic half ──────────────────────────────────────────────────
    def test_a_long_name_is_cut_at_a_word_not_mid_word(self):
        from lcars_serve.actions import _slug
        got = _slug(self.LONG)
        self.assertEqual(got, self.NEW_ROOM)
        self.assertLessEqual(len(got), 48)

    def test_the_slug_keeps_every_safety_property_it_claims(self):
        from lcars_serve.actions import _slug
        for name in ("", "   ", "///", "...", "---", None, "!!!", "\x00"):
            got = _slug(name)
            self.assertTrue(got, repr(name))
            for bad in ("/", "\\", "\x00"):
                self.assertNotIn(bad, got, repr(name))
            self.assertNotIn(got, (".", ".."), repr(name))
        # a single word longer than the cap has no boundary to fall back to,
        # so it is still hard-cut — never returned over length.
        long_word = "a" * 200
        self.assertEqual(_slug(long_word), "a" * 48)
        self.assertEqual(len(_slug("../../etc/passwd " + long_word)), 48)

    def test_a_short_name_slugs_exactly_as_it_always_did(self):
        from lcars_serve.actions import _slug, _slug_legacy
        for name in ("Nav rail", "Tile picker", "Ensuite Floor Picker",
                     "command palette", "A" * 48):
            self.assertEqual(_slug(name), _slug_legacy(name), name)

    def test_a_new_program_gets_the_word_boundary_room(self):
        self._start(self.LONG)
        rooms = [p["room"] for p in self._list()["programs"]]
        self.assertEqual(rooms, [self.NEW_ROOM], rooms)

    # ── the durability half: the rooms he already has ──────────────────────
    def test_an_existing_room_is_still_the_room_for_the_same_name(self):
        """THE REGRESSION THAT MATTERS. Start a program whose name slugged the
        old way, and it must land back in the room it already has — not in a
        second room beside it with the old work stranded."""
        old = self._plant_legacy_room()
        with open(os.path.join(old, "mockup.html"), "w") as fh:
            fh.write("<h1>the work he already did")
        _sid, state = self._start(self.LONG)
        self.assertEqual(state["room"], self.OLD_ROOM, state)
        sidecar = self.actions._ensure_sidecar(self.repo)
        self.assertFalse(os.path.isdir(os.path.join(sidecar, self.NEW_ROOM)),
                         "a second room was created beside the captain's")
        # and it is disclosed as the reuse it is, not silently adopted.
        self.assertEqual((state.get("roomNotice") or {}).get("kind"),
                         "room-reused", state.get("roomNotice"))
        self.assertEqual(state["previewFile"], "mockup.html", state)

    def test_an_existing_room_still_reopens_by_its_room_name(self):
        """`open` never re-slugs — it takes the room off the program list — so
        this is the property the cure could not have broken. Proven, not
        assumed."""
        self._plant_legacy_room()
        rooms = [p["room"] for p in self._list()["programs"]]
        self.assertEqual(rooms, [self.OLD_ROOM], rooms)
        _s, body = self._post("/api/holodeck/open", {"room": self.OLD_ROOM})
        self.assertEqual(body["state"]["room"], self.OLD_ROOM)
        self.assertEqual(body["state"]["program"], self.LONG)

    def test_a_new_room_wins_once_it_exists(self):
        """A program first made AFTER the cure keeps its word-boundary room
        even if a legacy-named directory turns up later — the resolver only
        falls back when there is nothing else to fall back from."""
        self._start(self.LONG)
        self._plant_legacy_room()
        self._restart_daemon()
        _sid, state = self._start(self.LONG)
        self.assertEqual(state["room"], self.NEW_ROOM, state)


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
    for, and the concept doc carries the real section headings.

    S128: `## Hand-off summary` is DELIBERATELY STALE here — it talks about a
    search input the requirements never ask for and says nothing about the
    theme in requirement 2. That is not sloppiness in the fixture; it is the
    FL-011 defect reproduced in miniature. The turn prompt maintains
    `WHAT IT MUST DO` on every turn and does not maintain the summary, so a
    brief drafted from the summary is a snapshot of an older conversation.
    """

    MOCKUP = ("<!doctype html>\n"
              "<!--\n"
              "  VISUAL REFERENCE ONLY — this is a mockup, not shipping code.\n"
              "-->\n"
              "<html><body><h1>Command palette</h1></body></html>\n")
    SUMMARY = ("Build a Cmd-K command palette overlay for the board: a centred "
               "panel with a search input, a fuzzy-matched command list, and "
               "the most recently run command pinned alone at the top.")
    REQ1 = "**Turn 2:** \"Cmd-K opens it, Escape closes it.\""
    REQ2 = "**Turn 5:** \"It has to remember what I ran last time.\""
    Q1 = "What belongs in the command list?"
    Q2 = "Should the palette be reachable from a mission card too?"
    CONCEPT = ("# Command Palette\n\n"
               "## The problem\n\nThe captain wants a palette.\n\n"
               "## Decisions\n\n- **Turn 2:** Cmd-K opens it.\n\n"
               "## Open questions\n\n- " + Q1 + "\n- " + Q2 + "\n\n"
               "## WHAT IT MUST DO — BEHAVIOUR ONLY\n\n### 1. Requirements\n\n"
               "- " + REQ1 + "\n- " + REQ2 + "\n\n"
               "### 2. Implied by the mockup, not yet settled\n\n"
               "- Q: is the pinned row real?\n\n"
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

    # S170 — SEED A FINISHED DERIVATION, the way the product itself would.
    #
    # The change list no longer comes out of the concept doc, so a test that
    # wants one has to make one EXIST. It is written through the DAEMON'S OWN
    # persistence road (`_handoff_derive_write`, at the daemon's own
    # fingerprint) rather than by stubbing a method — so every test that uses
    # this is also, incidentally, a test that the durable record is found and
    # read back. A seeded room spawns no worker: `_handoff_derive_state` finds
    # the record before it ever reaches the enabled check.
    def _seed_changes(self, sid, changes, ok=True, why=""):
        sess = self.actions._holodeck[sid]
        fp = self.actions._handoff_derive_fingerprint(sess.program_dir,
                                                      sess.target_repo)
        self.assertTrue(self.actions._handoff_derive_write(
            sess.program_dir, fp,
            {"ok": ok, "changes": list(changes), "why": why,
             "engine": "copilot"}))
        return fp


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
    def test_the_brief_is_seeded_from_the_CAPTURED_REQUIREMENTS(self):
        """S128 (FL-011). This used to assert the brief came from
        `## Hand-off summary`, and that assertion was the defect written down
        as a requirement: the turn prompt maintains `WHAT IT MUST DO` and does
        NOT maintain the summary, so the old source is a snapshot of an older
        conversation. The captain's own words are what must travel.

        S171 — AND HIS OWN WORDS ARE NOW THE ONES HE TYPED HIMSELF. The head
        of the brief was a numbered list of quoted fragments read out of
        bucket 1, which he measured as a timeline. It is his opening
        description of the program, byte-for-byte, and nothing rewrites it."""
        sid = self._program()
        st, body = self._promote(sid)
        self.assertEqual(st, 200, body)
        state = body["state"]
        self.assertEqual(state["brief"].split("\n")[0], "Command palette")
        self.assertNotIn("summarySource", state)

    def test_the_STALE_hand_off_summary_is_not_the_brief(self):
        """The negative half, and the one that fails on the old code: the
        summary's own sentences must not be what the mission opens with."""
        sid = self._program()
        _st, body = self._promote(sid)
        self.assertNotIn(self.SUMMARY, body["state"]["brief"])
        self.assertNotIn("fuzzy-matched", body["state"]["brief"])

    def test_the_guidance_carries_the_precedence_rule_VERBATIM(self):
        """S128 (A4a). The old assertion pinned "…the brief wins." — a sentence
        a cold worker read as "the brief is EXHAUSTIVE" and used to discard a
        requirement the mockup had and the brief had lost. The rule still
        resolves the tie; it no longer claims completeness."""
        sid = self._program()
        _st, body = self._promote(sid)
        g = body["state"]["guidance"]
        self.assertIn("the brief OVERRIDES the mockup", g)
        self.assertIn("not a claim that the brief is exhaustive", g)

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
        self.assertIn("the brief OVERRIDES the mockup", text)
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
        # S172 — the refusal NAMES THE WAY ON, by the label of the control that
        # does it. It used to name a road that did not exist ("⧉ DUPLICATE TO
        # KEEP DESIGNING … is not built yet, so for now start a new program
        # under a different name"); it is built now, so this pins the control's
        # own words and the fact that the refusal points somewhere real.
        self.assertIn("⧉ DUPLICATE", msg)
        self.assertIn("way on", msg)
        self.assertIn("stays exactly as it was handed over", msg)
        self.assertNotIn("not built", msg.lower())
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
        self.assertIn("the brief OVERRIDES the mockup", prompt)

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


# ════════════════════════════════════════════════════════════════════════════
# S128 (FL-011) — THE INTENT HAND-OVER
#
# The hand-off transmitted perfectly and what it transmitted was not the
# captain's. Four claims, each with its own suite below:
#
#   A1  the brief is drafted from the CAPTURED REQUIREMENTS, not a prose
#       paragraph the turn prompt never regenerates.
#   A2  `## Open questions` reach the captain BEFORE he files, and an
#       unanswered one arrives in the mission AS an open question.
#   A3  a captured requirement can never leave silently.
#   A4  a mock/brief disagreement is EVIDENCE, not a decision to make.
#
# WHAT THIS FILE CANNOT PROVE: A4(b) is guidance text — a model-choice layer.
# These tests prove the words exist and reach the mission verbatim. Whether a
# cold worker OBEYS them is only measurable on a live drive.
# ════════════════════════════════════════════════════════════════════════════
class HandoffRequirementsTest(HandoffBase):
    """A1 — the brief comes from `WHAT IT MUST DO`, and degrades honestly."""

    def _concept(self, text):
        """Rewrite the program's concept doc through a real turn."""
        self._set_turns({"stdout": "ok",
                         "writes": [{"path": "concept.md", "content": text}]})
        return text

    def test_the_payload_carries_the_requirement_SET_itself(self):
        """Not just the assembled prose: the surface has to be able to show
        each captured requirement and whether it survived the captain's edit."""
        sid = self._program()
        _st, body = self._promote(sid)
        reqs = body["state"]["requirements"]
        self.assertEqual(len(reqs), 2, reqs)
        self.assertTrue(all(r["id"] and r["text"] for r in reqs), reqs)
        self.assertIn("Escape closes it", reqs[0]["text"])
        self.assertIn("remember what I ran last time", reqs[1]["text"])

    def test_each_requirement_keeps_its_TURN_attribution(self):
        """"attributed to the turn it was said in" is half of why the captain
        recognises it as his — stripping it leaves anonymous prose."""
        sid = self._program()
        _st, body = self._promote(sid)
        self.assertIn("Turn 2", body["state"]["requirements"][0]["text"])
        self.assertIn("Turn 5", body["state"]["requirements"][1]["text"])

    def test_a_MULTI_LINE_requirement_survives_as_one_requirement(self):
        """A live concept doc wraps at ~78 columns, so most requirements are
        two or three physical lines. Splitting on newlines would shatter one
        requirement into three and then "lose" two of them at the A3 gate."""
        sid = self._program()
        self._concept(
            "# P\n\n## WHAT IT MUST DO\n\n### 1. Requirements\n\n"
            "1. \"Can we add a light and dark mode, and can the toggle live\n"
            "   in the toolbar next to Save?\" — T3.\n"
            "2. \"Nothing else changes.\" — T4.\n")
        self._post("/api/holodeck/%s/say" % sid, {"text": "update it"})
        _st, body = self._promote(sid)
        reqs = body["state"]["requirements"]
        self.assertEqual(len(reqs), 2, reqs)
        self.assertIn("in the toolbar next to Save", reqs[0]["text"])
        self.assertIn("light and dark mode", reqs[0]["text"])

    def test_a_concept_with_no_requirements_still_hands_back_HIS_WORDS(self):
        """S171 — THE DEGRADATION LADDER IS GONE, and this is what replaced it.

        It used to fall to `## The problem` and then to the doc's first
        paragraph, publishing `summarySource` so a fallback could never be
        passed off as the real thing. That was the right discipline for a head
        DRAFTED OUT OF A MODEL-WRITTEN DOCUMENT — and `## The problem` is model
        prose about the captain ("The captain wants a cleaner chrome…"), which
        is exactly what he ruled out. There is no rung below his own opening
        description because he always typed one."""
        sid = self._program()
        self._concept("# P\n\n## The problem\n\nHe wants a palette badly.\n")
        self._post("/api/holodeck/%s/say" % sid, {"text": "update it"})
        _st, body = self._promote(sid)
        self.assertEqual(body["state"]["brief"], "Command palette")
        self.assertNotIn("wants a palette badly", body["state"]["brief"])

    def test_a_concept_with_nothing_usable_still_hands_back_a_draft(self):
        sid = self._program()
        self._concept("Just one loose paragraph and no headings at all.\n")
        self._post("/api/holodeck/%s/say" % sid, {"text": "update it"})
        _st, body = self._promote(sid)
        self.assertEqual(body["state"]["brief"], "Command palette")
        self.assertNotIn("loose paragraph", body["state"]["brief"])

    def test_the_captured_requirements_reach_the_FILED_MISSION_verbatim(self):
        """S171 — BY THE ATTACHMENT, not by the idea text.

        The brief no longer quotes him, so `idea.md` no longer carries the
        numbered list. `concept.md` rides to the Mission with `## WHAT IT MUST
        DO` complete and turn-attributed, and every stage reads it — which is
        the structural guarantee that replaced `_handoff_missing`."""
        sid = self._program()
        _st, promo = self._promote(sid)
        self._post("/api/park", {"idea": promo["state"]["brief"],
                                 "holodeck": sid})
        rec = self._filed()[0]
        self.assertNotIn("Cmd-K opens it, Escape closes it.",
                         rec["files"]["--idea"])
        doc = [a for a in self._attached(rec) if a.endswith("concept.md")][0]
        with open(doc) as fh:
            text = fh.read()
        self.assertIn("Cmd-K opens it, Escape closes it.", text)
        self.assertIn("remember what I ran last time", text)


class HandoffOpenQuestionsTest(HandoffBase):
    """A2 — the questions the product asked itself must reach the captain."""

    def test_the_open_questions_ride_in_the_promote_payload(self):
        sid = self._program()
        _st, body = self._promote(sid)
        qs = body["state"]["questions"]
        self.assertEqual([q["text"] for q in qs], [self.Q1, self.Q2])
        self.assertEqual(len(set(q["id"] for q in qs)), 2, qs)

    def test_an_UNANSWERED_question_arrives_as_an_OPEN_QUESTION(self):
        """The S127 failure exactly: five questions died at the hand-off and
        every downstream stage read their silence as a settled decision."""
        sid = self._program()
        self._post("/api/park", {"idea": "build the palette", "holodeck": sid})
        text = self._filed()[0]["files"]["--idea"]
        self.assertIn(self.Q1, text)
        self.assertIn(self.Q2, text)
        low = text.lower()
        self.assertIn("open question", low)
        # S169 fix round 2 — the marker is `NO ANSWER RECORDED`, not `STILL
        # OPEN`. What this test is FOR is unchanged: an unanswered question must
        # arrive marked, and must not read as a decision. What changed is that
        # the mark states the daemon's one fact instead of asserting the
        # question is undecided — see `_handoff_questions_block`, and
        # `S169FalseStillOpenTest` below for the measurement that forced it.
        self.assertIn("no answer recorded", low)
        self.assertIn("never settle one yourself", low)

    def test_an_ANSWERED_question_arrives_as_the_CAPTAINS_OWN_ANSWER(self):
        sid = self._program()
        _st, promo = self._promote(sid)
        qid = promo["state"]["questions"][0]["id"]
        self._post("/api/park", {"idea": "build the palette", "holodeck": sid,
                                 "holodeckAnswers": {qid: "Only board verbs."}})
        text = self._filed()[0]["files"]["--idea"]
        self.assertIn("Only board verbs.", text)
        # …and it is attributed to HIM, not left to read as the product's own
        # decision — which is the whole failure being cured.
        answered = text.split(self.Q1, 1)[1].split(self.Q2, 1)[0]
        self.assertIn("captain", answered.lower())
        # the OTHER question is untouched and still open.
        self.assertIn(self.Q2, text)

    def test_an_answered_and_an_unanswered_question_read_DIFFERENTLY(self):
        """The control. A block that printed every question the same way would
        pass both tests above and still hand a cold stage five decisions."""
        sid = self._program()
        _st, promo = self._promote(sid)
        qid = promo["state"]["questions"][0]["id"]
        self._post("/api/park", {"idea": "go", "holodeck": sid,
                                 "holodeckAnswers": {qid: "Only board verbs."}})
        text = self._filed()[0]["files"]["--idea"]
        first = text.split(self.Q1, 1)[1].split(self.Q2, 1)[0]
        second = text.split(self.Q2, 1)[1]
        self.assertNotIn("NO ANSWER RECORDED", first.upper())
        self.assertIn("NO ANSWER RECORDED", second.upper())

    def test_a_blank_answer_is_treated_as_NO_ANSWER(self):
        sid = self._program()
        _st, promo = self._promote(sid)
        qid = promo["state"]["questions"][0]["id"]
        self._post("/api/park", {"idea": "go", "holodeck": sid,
                                 "holodeckAnswers": {qid: "   "}})
        text = self._filed()[0]["files"]["--idea"]
        first = text.split(self.Q1, 1)[1].split(self.Q2, 1)[0]
        self.assertIn("NO ANSWER RECORDED", first.upper())

    def test_an_answer_for_a_question_that_does_not_exist_is_ignored(self):
        """The ids are the DAEMON's, re-derived from the concept doc it reads
        at filing time. A crafted key cannot inject prose into the mission."""
        sid = self._program()
        self._post("/api/park", {"idea": "go", "holodeck": sid,
                                 "holodeckAnswers": {"q99": "INJECTED"}})
        self.assertNotIn("INJECTED", self._filed()[0]["files"]["--idea"])

    def test_a_concept_with_no_open_questions_adds_no_block(self):
        sid = self._program()
        self._set_turns({"stdout": "ok", "writes": [
            {"path": "concept.md",
             "content": "# P\n\n## WHAT IT MUST DO\n\n### 1. Requirements\n\n"
                        "- \"Just build it.\"\n"}]})
        self._post("/api/holodeck/%s/say" % sid, {"text": "update it"})
        _st, body = self._promote(sid)
        self.assertEqual(body["state"]["questions"], [])
        self._post("/api/park", {"idea": "go", "holodeck": sid})
        text = self._filed()[0]["files"]["--idea"]
        self.assertNotIn("Open questions", text)


class HandoffRequirementCheckIsGONETest(HandoffBase):
    """S171 — A3'S LITERAL-WORD CHECK IS DELETED, AND THAT IS THE TEST.

    What was here: eight tests over `_handoff_missing`, a containment test on
    the captain's own words that named every captured requirement his brief did
    not contain, warned about it on the surface, and carried it into the
    Mission verbatim under `## Captured requirements NOT IN THE BRIEF above`.

    It is gone because his literal words are no longer IN the brief — the
    numbered "in your own words" list left it this session — so it would report
    nearly every requirement as missing on every hand-off, which is the
    cry-wolf failure this round has already cured once (S169 fix round 2, the
    open-questions cue). Nothing smarter replaced it: a similarity or
    paraphrase check is S156 (14/14 → 5/14 on a reworded corpus), S147 (four
    parser generations) and S157 (five guards). The full reasoning, and the
    risk that was accepted by name, is in actions.py where the function was.

    These four tests hold the DELETION down and pin the structural guarantee
    that took its place.
    """

    def test_no_captured_requirement_block_reaches_the_filed_idea(self):
        sid = self._program()
        self._post("/api/park", {"holodeck": sid,
                                 "idea": "Cmd-K opens it, Escape closes it."})
        text = self._filed()[0]["files"]["--idea"]
        self.assertNotIn("not in the brief", text.lower())
        self.assertNotIn("Captured requirements", text)

    def test_a_brief_that_drops_everything_files_WITHOUT_A_WARNING(self):
        """The exact input that used to fire, and the reason it had to go:
        after S171 this is what a NORMAL hand-off looks like."""
        sid = self._program()
        _st, body = self._post("/api/park", {"holodeck": sid, "idea": "go"})
        holo = body["state"]["holodeck"]
        self.assertNotIn("missingRequirements", holo)
        self.assertNotIn("warning", holo, holo.get("warning"))

    def test_the_promote_payload_no_longer_publishes_missingRequirements(self):
        sid = self._program()
        _st, body = self._promote(sid)
        self.assertNotIn("missingRequirements", body["state"])

    def test_HIS_WORDS_STILL_REACH_THE_MISSION_and_this_is_how(self):
        """THE STRUCTURAL GUARANTEE THAT REPLACED THE CHECK, and the reason
        deleting it is not re-opening FL-011.

        `concept.md` rides to the Mission as an attachment, with
        `## WHAT IT MUST DO` complete, numbered and turn-attributed. Every
        stage reads it. What stopped is a TIMELINE being pasted into the brief
        as though it were the specification."""
        sid = self._program()
        self._post("/api/park", {"holodeck": sid, "idea": "go"})
        attached = self._attached(self._filed()[0])
        self.assertTrue(any(a.endswith("concept.md") for a in attached),
                        attached)
        room = [a for a in attached if a.endswith("concept.md")][0]
        with open(room) as fh:
            doc = fh.read()
        self.assertIn("remember what I ran last time", doc)
        self.assertIn("Cmd-K opens it, Escape closes it.", doc)


class HandoffDisagreementTest(HandoffBase):
    """A4 — a mock/brief disagreement is a signal, not a rule to apply.

    These prove the WORDS are present and travel verbatim. They cannot prove a
    cold worker obeys them; that is a live drive's job.
    """

    def test_the_precedence_rule_is_an_OVERRIDE_not_a_completeness_claim(self):
        sid = self._program()
        _st, body = self._promote(sid)
        g = body["state"]["guidance"]
        self.assertIn("the brief OVERRIDES the mockup", g)
        self.assertIn("not a claim that the brief is exhaustive", g)
        # the reading that caused FL-011 is now contradicted in the same breath.
        self.assertIn("the brief can be missing something the mockup has", g)

    def test_the_guidance_tells_a_cold_stage_to_ESCALATE_a_disagreement(self):
        sid = self._program()
        _st, body = self._promote(sid)
        g = body["state"]["guidance"].lower()
        self.assertIn("escalate", g)
        self.assertIn("lcars:awaiting-human", g)
        self.assertIn("lost", g)
        self.assertNotIn("resolve it yourself", g.replace(
            "rather than resolving it yourself", ""))

    def test_the_escalation_instruction_is_in_BOTH_build_scopes(self):
        """A reskin can lose a requirement exactly as easily as a build, and a
        rule that only exists on one branch is a rule with a hole in it."""
        sid = self._program()
        for scope in ("look+behaviour", "look-only"):
            _st, body = self._promote(sid, scope=scope)
            self.assertIn("lcars:awaiting-human",
                          body["state"]["guidance"].lower(), scope)

    def test_the_escalation_instruction_reaches_the_FILED_mission(self):
        sid = self._program()
        self._post("/api/park", {"idea": "go", "holodeck": sid})
        text = self._filed()[0]["files"]["--idea"]
        self.assertIn("lcars:awaiting-human", text.lower())
        self.assertIn("the brief OVERRIDES the mockup", text)

    def test_it_is_spelled_ONCE(self):
        """FL-010's lesson applied before it can happen again: the sentence has
        one home, so the deck and the mission cannot drift apart."""
        from lcars_serve import actions as A
        self.assertIn(A._HANDOFF_PRECEDENCE, A._HANDOFF_SCOPE_TEXT[
            "look+behaviour"])
        self.assertIn(A._HANDOFF_PRECEDENCE, A._HANDOFF_SCOPE_TEXT["look-only"])


class S127EvidenceTest(HandoffBase):
    """THE ACCEPTANCE FIXTURE — the real `concept.md` off the failed capstone.

    `web/tests/fixtures/s127-capstone/concept.md` is a byte copy of the doc the
    holodeck actually wrote for mission `lcars-20260806-001` on 2026-08-06. Its
    `## Hand-off summary` says "built strictly on the existing dark palette"
    and "Nothing new is coloured"; its `WHAT IT MUST DO` bucket 1 says, in the
    captain's own words, "Can we add a light and dark mode?". The filed
    `idea.md` beside it (`idea-as-filed.md`) is the summary and nothing else.
    """

    FIXTURE = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                           "fixtures", "s127-capstone")

    @classmethod
    def setUpClass(cls):
        super(S127EvidenceTest, cls).setUpClass()
        with open(os.path.join(cls.FIXTURE, "concept.md")) as fh:
            cls.CONCEPT = fh.read()
        with open(os.path.join(cls.FIXTURE, "idea-as-filed.md")) as fh:
            cls.FILED_IN_S127 = fh.read()

    def test_the_fixture_is_the_real_failure_and_not_a_tidied_copy(self):
        """Pin the two facts the whole session turns on. If someone 'fixes' the
        fixture, every claim below becomes a claim about nothing."""
        self.assertIn("Can we add a light and dark mode?", self.CONCEPT)
        self.assertIn("Nothing new is coloured", self.CONCEPT)
        # what S127 actually filed: the stale summary, theme-free.
        self.assertNotIn("light and dark", self.FILED_IN_S127.lower())
        self.assertIn("Nothing new is coloured", self.FILED_IN_S127)

    def test_the_THEME_requirement_is_still_CAPTURED(self):
        """FL-011's headline. It was stated verbatim twice and appeared in
        neither `idea.md` nor `prd.md`, which then put "any new colour beyond
        the existing dark palette" explicitly OUT OF SCOPE.

        S171 — IT NO LONGER RIDES IN THE BRIEF, and this test says so
        deliberately rather than being deleted. The brief stopped carrying a
        numbered list of his quoted fragments (a timeline, by his own
        measurement); the concept doc still captures every one of them and
        RIDES TO THE MISSION as an attachment. What is proven here is that the
        capture is intact — the ride is proven by
        `HandoffRequirementCheckIsGONETest`."""
        sid = self._program()
        _st, body = self._promote(sid)
        blob = " ".join(r["text"] for r in body["state"]["requirements"])
        self.assertIn("Can we add a light and dark mode?", blob)
        self.assertIn("Can we use lighter blues along with white in light mode?",
                      blob)

    def test_ALL_FOUR_captured_requirements_are_still_READ(self):
        sid = self._program()
        _st, body = self._promote(sid)
        reqs = body["state"]["requirements"]
        self.assertEqual(len(reqs), 4, [r["text"] for r in reqs])
        blob = " ".join(r["text"] for r in reqs)
        self.assertIn("Text needs to be black in", blob)

    def test_the_STALE_summary_sentences_never_reach_the_brief(self):
        sid = self._program()
        _st, body = self._promote(sid)
        brief = body["state"]["brief"]
        self.assertNotIn("Nothing new is coloured", brief)
        self.assertNotIn("built strictly on the existing dark palette", brief)

    def test_the_FIVE_open_questions_are_put_in_front_of_the_captain(self):
        """The five he flagged at Verify, in the doc all along, never asked."""
        sid = self._program()
        _st, body = self._promote(sid)
        qs = [q["text"] for q in body["state"]["questions"]]
        self.assertEqual(len(qs), 5, qs)
        blob = " ".join(qs).lower()
        for topic in ("mode switcher", "visibility toggle", "tile search",
                      "project glyph", "status bar"):
            self.assertIn(topic, blob, topic)

    def test_the_theme_survives_all_the_way_into_the_filed_mission(self):
        """S171 — BY THE ATTACHMENT ROAD, which is the guarantee that replaced
        the literal-word check. The mission is handed `concept.md`, and the
        theme is in it twice in his own words. It is not in `idea.md` any more
        because the brief no longer quotes him — see the block above
        `_handoff_missing`'s old home for the risk that was accepted."""
        sid = self._program()
        _st, promo = self._promote(sid)
        self._post("/api/park", {"idea": promo["state"]["brief"],
                                 "holodeck": sid})
        rec = self._filed()[0]
        doc = [a for a in self._attached(rec) if a.endswith("concept.md")][0]
        with open(doc) as fh:
            text = fh.read()
        self.assertIn("Can we add a light and dark mode?", text)
        self.assertIn("lighter blues along with white in light mode", text)


# ════════════════════════════════════════════════════════════════════════════
# S128 FIX ROUND 1 (batch F2) — what two live testers found in the machinery
# the round above shipped. Four defects, each with its own suite.
#
#   D3  every holodeck-born mission was TITLED `## What it must do — in your
#       own words` (the brief's own heading, read as the first idea line).
#   D5  a REWORDED bucket-1 sub-heading matched nothing, so the fallback
#       promoted bucket 2 ("not yet settled") to "what you said".
#   D4  the requirement rows showed RAW MARKDOWN in the one panel whose job is
#       "in your own words".
#   L-2 the room-collision disclosure stated something that can be false.
# ════════════════════════════════════════════════════════════════════════════
class HandoffTitleTest(HandoffBase):
    """D3 — a holodeck-born mission's PERMANENT identity, on the board and on
    GitHub. `_title_from_idea` (and file.sh, on the park road) take the first
    line of the idea, and the drafted brief opened with a markdown heading."""

    @staticmethod
    def _first_line(text):
        return (text or "").strip().split("\n")[0].strip()

    def _concept(self, sid, text):
        self._set_turns({"stdout": "ok",
                         "writes": [{"path": "concept.md", "content": text}]})
        self._post("/api/holodeck/%s/say" % sid, {"text": "update it"})

    def test_the_drafted_brief_does_not_OPEN_with_a_markdown_heading(self):
        sid = self._program()
        _st, body = self._promote(sid)
        first = self._first_line(body["state"]["brief"])
        self.assertFalse(first.startswith("#"), first)
        self.assertNotIn("What it must do — in your own words", first)

    def test_the_brief_OPENS_with_the_program_name(self):
        """The program name is what the CAPTAIN typed and it is what names his
        room; the first requirement is a turn-attributed quote and reads as one.
        A non-holodeck filing titles itself from the first idea line, so the
        cure is to make that line a real title rather than to special-case the
        title derivation on one road and not the other (file.sh owns the
        park road's, and it is not this session's file)."""
        sid = self._program()
        _st, body = self._promote(sid)
        self.assertEqual(self._first_line(body["state"]["brief"]),
                         "Command palette")

    def test_the_PARKED_mission_idea_opens_with_the_program_name(self):
        sid = self._program()
        _st, promo = self._promote(sid)
        self._post("/api/park", {"idea": promo["state"]["brief"],
                                 "holodeck": sid})
        idea = self._filed()[0]["files"]["--idea"]
        self.assertEqual(self._first_line(idea), "Command palette")

    def test_the_FILED_mission_PRD_is_titled_with_the_program_name(self):
        """The shim caught `issue create --title ## What it must do — in your
        own words`. This is the assertion that would have stopped it."""
        sid = self._program()
        _st, promo = self._promote(sid)
        self._post("/api/mission", {"idea": promo["state"]["brief"],
                                    "holodeck": sid})
        prd = self._filed()[0]["files"]["--prd"]
        self.assertIn("# Mission: Command palette", prd)
        self.assertNotIn("# Mission: #", prd)

    def test_the_brief_opens_with_HIS_OWN_WORDS_and_no_list(self):
        """S171 — the numbered list under the heading is what he was deleting
        by hand before sending. What the box opens with is what he typed."""
        sid = self._program()
        _st, body = self._promote(sid)
        brief = body["state"]["brief"]
        self.assertNotIn("what it must do", brief.lower())
        self.assertNotIn("**Turn 2:**", brief)
        self.assertEqual(self._first_line(brief), "Command palette")

    def test_a_THIN_concept_doc_is_titled_too(self):
        """A doc with nothing usable in it files a mission exactly the same
        way. A cure that only covered one road would leave two titles wrong."""
        sid = self._program()
        for concept in ("# P\n\n## The problem\n\nHe wants a palette.\n",
                        "Just one loose paragraph and no headings at all.\n"):
            self._concept(sid, concept)
            _st, body = self._promote(sid)
            self.assertEqual(self._first_line(body["state"]["brief"]),
                             "Command palette", concept)


class HandoffBucketFallbackTest(HandoffBase):
    """D5 — the round's OWN defect class: unstated things promoted to stated.

    The fixture is the tester's: a plausible paraphrase of the contract's own
    prose for bucket 1 (`### 1. Stated behaviour, in the captain's own words`),
    which matched neither `_HANDOFF_REQ_BUCKETS` entry.
    """

    STATED = ("It has to have a light and a dark theme.",
              "The default is dark.",
              "The toggle lives in the top-right corner, next to Save.")
    REWORDED = (
        "# Theme toggle\n\n"
        "## Open questions\n\n- Does the choice persist?\n\n"
        "## WHAT IT MUST DO — behaviour only\n\n"
        "### 1. Stated behaviour, in the captain's own words\n\n"
        "1. **Turn 1:** \"It has to have a light and a dark theme.\" — T1\n"
        "2. **Turn 2:** \"The default is dark.\" — T2\n"
        "3. **Turn 4:** \"The toggle lives in the top-right corner, next to\n"
        "   Save.\" — T4\n\n"
        "### 2. Implied by the mockup, not yet settled\n\n"
        "- A system-follows-OS option might be wanted.\n\n"
        "### 3. Out of scope\n\n"
        "- Per-page theme overrides.\n\n"
        "## DECLARED FLOW\n\n`board` → `toggle`\n")

    def _concept(self, sid, text):
        self._set_turns({"stdout": "ok",
                         "writes": [{"path": "concept.md", "content": text}]})
        self._post("/api/holodeck/%s/say" % sid, {"text": "update it"})

    def _reqs(self, text):
        from lcars_serve.actions import _handoff_requirements
        return _handoff_requirements(text)

    def test_a_reworded_bucket_1_heading_yields_EXACTLY_the_stated_three(self):
        got = self._reqs(self.REWORDED)
        self.assertEqual(len(got), 3, got)
        for want in self.STATED:
            self.assertTrue(any(want in g for g in got), (want, got))

    def test_bucket_2_CONTENT_is_never_a_stated_requirement(self):
        """"behaviour the mockup suggests that nobody has actually stated",
        displayed with a green ✓ under "what you said, in your own words"."""
        got = self._reqs(self.REWORDED)
        for g in got:
            self.assertNotIn("system-follows-OS", g, got)
            self.assertNotIn("Per-page theme overrides", g, got)

    def test_a_sub_heading_is_NEVER_folded_into_a_requirement(self):
        """The continuation-line rule ate bucket 2's own heading and hung it
        off the end of requirement 3."""
        for g in self._reqs(self.REWORDED):
            self.assertNotIn("###", g, g)
            self.assertNotIn("Implied by the mockup", g, g)

    # ── S169 CHANGED WHERE BUCKET 2 GOES, AND ONLY THAT ─────────────────────
    # These two used to assert that bucket 2's content reached NEITHER the brief
    # nor the mission. That was S128's rule and S128 says why: bucket 2 was
    # excluded "pending a dedup rule". The dedup rule is now written, and that
    # exclusion turned out to be the defect — the drawn-but-unwired half of a
    # mockup lives in bucket 2 and reached nobody.
    #
    # THE D5 CLAIM ITSELF IS UNCHANGED and is what these still hold: bucket 2 is
    # never a STATED requirement, never in the requirement set, and never in the
    # region of the brief headed "what it must do — in your own words". It
    # travels in its own section, marked IMPLIED. S170 — and bucket 3 now
    # travels too, in ITS own section headed "do not touch these"; what must
    # never happen is either of them reading as something he SAID.
    def test_bucket_2_never_reaches_the_deck_as_something_he_SAID(self):
        sid = self._program()
        self._concept(sid, self.REWORDED)
        _st, body = self._promote(sid)
        brief = body["state"]["brief"]
        said = brief.split("## Implied by the mockup", 1)[0]
        self.assertNotIn("system-follows-OS", said)
        self.assertNotIn("Per-page theme overrides", said)
        self.assertIn("Per-page theme overrides",
                      brief.split("## Out of scope", 1)[1])
        texts = [r["text"] for r in body["state"]["requirements"]]
        self.assertEqual(len(texts), 3, texts)
        self.assertNotIn("system-follows-OS", " ".join(texts))
        # …and it IS carried, in its own bucket, which is S169's cure.
        self.assertEqual(body["state"]["implied"],
                         ["A system-follows-OS option might be wanted."])

    def test_what_reaches_the_FILED_mission_is_MARKED_or_not_there(self):
        sid = self._program()
        self._concept(sid, self.REWORDED)
        _st, promo = self._promote(sid)
        self._post("/api/park", {"idea": promo["state"]["brief"],
                                 "holodeck": sid})
        text = self._filed()[0]["files"]["--idea"]
        self.assertIn("system-follows-OS", text)
        marked = text.split("## Implied by the mockup", 1)[1]
        self.assertIn("system-follows-OS", marked)
        self.assertIn("IMPLIED", marked)
        # S170 — the out-of-scope item reaches the mission too, and ONLY under
        # its own heading. It is the sentence that keeps an implementer out of
        # the thing the captain ruled out, and a diff cannot produce it.
        said = text.split("## Implied by the mockup", 1)[0]
        self.assertNotIn("Per-page theme overrides", said)
        self.assertIn("Per-page theme overrides",
                      text.split("## Out of scope", 1)[1])

    # -- the fallback's INTENT, kept -----------------------------------------
    def test_a_section_with_NO_sub_buckets_is_STILL_the_list(self):
        """"a doc that keeps the heading and drops the structure must not read
        as 'he asked for nothing'" — the reason the fallback exists."""
        got = self._reqs("# P\n\n## WHAT IT MUST DO\n\n"
                         "- \"It has to have a light and a dark theme.\" — T1\n"
                         "- \"The default is dark.\" — T2\n")
        self.assertEqual(len(got), 2, got)

    def test_a_named_bucket_1_is_untouched_by_the_new_rule(self):
        """The real S127 doc writes `### 1. Requirements (captain's words)` and
        goes down the MATCHED road, not the fallback. Proven, not assumed."""
        got = self._reqs(self.REWORDED.replace(
            "### 1. Stated behaviour, in the captain's own words",
            "### 1. Requirements (captain's words)"))
        self.assertEqual(len(got), 3, got)
        for g in got:
            self.assertNotIn("system-follows-OS", g)

    def test_a_section_whose_ONLY_bucket_is_bucket_2_yields_NOTHING(self):
        """Degrade toward EXCLUDING: a doc that lost bucket 1 entirely must
        report no stated requirements, not report bucket 2's as stated."""
        got = self._reqs("# P\n\n## WHAT IT MUST DO\n\n"
                         "### 2. Implied by the mockup, not yet settled\n\n"
                         "- Maybe a system-follows-OS option.\n")
        self.assertEqual(got, [], got)

    def test_an_OUT_OF_SCOPE_only_section_yields_NOTHING(self):
        got = self._reqs("# P\n\n## WHAT IT MUST DO\n\n"
                         "### Out of scope\n\n- Per-page theme overrides.\n")
        self.assertEqual(got, [], got)

    def test_a_preamble_ABOVE_the_first_bucket_still_counts(self):
        """Structure, not wording: everything up to the SECOND sub-heading is
        bucket 1's region, wherever the model put the list."""
        got = self._reqs("# P\n\n## WHAT IT MUST DO\n\n"
                         "- \"The default is dark.\" — T2\n\n"
                         "### Everything else we thought of\n\n"
                         "- \"Light mode too.\" — T3\n\n"
                         "### 2. Implied by the mockup, not yet settled\n\n"
                         "- Maybe a system-follows-OS option.\n")
        blob = " ".join(got)
        self.assertIn("The default is dark.", blob)
        self.assertIn("Light mode too.", blob)
        self.assertNotIn("system-follows-OS", blob)


class HandoffPlainTextTest(HandoffBase):
    """D4 — the panel whose entire job is "what you said, in your own words"
    was showing him bold markers he never typed. Normalised in the DAEMON so
    the brief and the dialog agree by construction."""

    def test_a_requirement_row_carries_NO_RAW_MARKDOWN(self):
        sid = self._program()
        _st, body = self._promote(sid)
        for r in body["state"]["requirements"]:
            self.assertNotIn("**", r["text"], r["text"])

    def test_the_PRE_DRAFTED_BRIEF_carries_none_either(self):
        sid = self._program()
        _st, body = self._promote(sid)
        self.assertNotIn("**", body["state"]["brief"])

    def test_the_TURN_ATTRIBUTION_survives_IN_THE_CAPTURE(self):
        """Load-bearing: it is half of why the captain recognises the sentence
        as his.

        S171 — AND IT IS NOW ONLY IN THE CAPTURE, never in the brief. The turn
        stamps are precisely what made the brief read as a timeline; they
        belong on the record, which rides to the Mission as `concept.md`."""
        sid = self._program()
        _st, body = self._promote(sid)
        reqs = body["state"]["requirements"]
        self.assertIn("Turn 2:", reqs[0]["text"])
        self.assertIn("Turn 5:", reqs[1]["text"])
        self.assertNotIn("Turn 2:", body["state"]["brief"])


class LiveMarkdownIsNormalisedTest(HandoffBase):
    """D4 on the REAL doc, which is where the defect is bigger than reported.

    The live S127 `concept.md` puts markdown emphasis through the OPEN
    QUESTIONS as well as the requirements — `**mode switcher**`,
    `**per-row visibility toggle**`, `**tile search**` — so the dialog that
    asks the captain five questions before he files was showing him asterisks
    too. Its requirements use the OTHER attribution shape (a trailing
    `— T3.`, not a leading `**Turn 3:**`); both must survive.
    """

    @classmethod
    def setUpClass(cls):
        super(LiveMarkdownIsNormalisedTest, cls).setUpClass()
        with open(os.path.join(S127EvidenceTest.FIXTURE, "concept.md")) as fh:
            cls.CONCEPT = fh.read()

    def test_the_fixture_really_does_carry_the_markup(self):
        """Pin it, or every claim below is a claim about nothing."""
        self.assertIn("**mode switcher**", self.CONCEPT)
        self.assertIn("**per-row visibility toggle**", self.CONCEPT)

    def test_the_OPEN_QUESTIONS_reach_the_captain_plain(self):
        sid = self._program()
        _st, body = self._promote(sid)
        qs = body["state"]["questions"]
        self.assertEqual(len(qs), 5, qs)
        for q in qs:
            self.assertNotIn("**", q["text"], q["text"])
        blob = " ".join(q["text"] for q in qs)
        self.assertIn("mode switcher", blob)
        self.assertIn("per-row visibility toggle", blob)

    def test_the_questions_stay_plain_in_the_FILED_mission(self):
        sid = self._program()
        self._post("/api/park", {"idea": "go", "holodeck": sid})
        text = self._filed()[0]["files"]["--idea"]
        block = text.split("Open questions from the design session", 1)[1]
        self.assertNotIn("**", block)
        self.assertIn("mode switcher", block)

    def test_the_TRAILING_turn_attribution_survives(self):
        """`"Can we add a light and dark mode?" — T3.` — the attribution is a
        trailing `— T<n>` here, not a leading `**Turn N:**`."""
        sid = self._program()
        _st, body = self._promote(sid)
        texts = [r["text"] for r in body["state"]["requirements"]]
        self.assertEqual(len(texts), 4, texts)
        self.assertTrue(any(t.endswith("— T3.") for t in texts), texts)
        self.assertTrue(any(t.endswith("— T1.") for t in texts), texts)

    def test_a_BACKTICKED_name_is_left_alone(self):
        """`prefers-color-scheme` is the captain naming a thing, and the brief
        is markdown by the time it lands in `idea.md`. Emphasis markers are
        removed; code spans are not."""
        from lcars_serve.actions import _md_plain
        self.assertEqual(_md_plain("follow the OS `prefers-color-scheme`?"),
                         "follow the OS `prefers-color-scheme`?")
        self.assertEqual(_md_plain("keep snake_case and foo_bar intact"),
                         "keep snake_case and foo_bar intact")

    def test_a_LITERAL_asterisk_in_his_sentence_survives(self):
        """The single-`*` emphasis rule was written, measured eating
        `a*b and 2*3`, and deleted. This is the guard on that deletion — a
        pair-matching rule spans from one literal asterisk to the next."""
        from lcars_serve.actions import _md_plain
        for keep in ("width is a*b and the grid is 2*3",
                     "match *.css and *.js under web/",
                     "**bold** but a*b stays"):
            self.assertEqual(_md_plain(keep).count("*"),
                             keep.count("*") - (4 if "**" in keep else 0),
                             keep)


class RoomReuseDisclosureTest(DurableBase):
    """L-2 — the disclosure must be TRUE. The word-boundary slug can discard
    up to 24 characters of distinguishing text, so two DIFFERENT names can
    share a room; "an earlier program of the same name" is then false.

    The slug algorithm is NOT changed — it was proven safe against the
    captain's existing archive. This is the wording only.
    """

    def _notice(self, program_dir):
        from lcars_serve.actions import Actions
        return Actions._room_already_holds_work(program_dir)

    def _room_with(self, name, program="Alpha rail"):
        from lcars_serve.actions import _transcript_header
        d = os.path.join(self.tmp, name)
        os.makedirs(d)
        with open(os.path.join(d, "transcript.md"), "w") as fh:
            fh.write(_transcript_header(program))
        with open(os.path.join(d, "mockup.html"), "w") as fh:
            fh.write("<h1>earlier work")
        return d

    def test_it_no_longer_CLAIMS_the_earlier_program_shared_this_name(self):
        msg = self._notice(self._room_with("shared-room"))
        self.assertNotIn("of the same name", msg)

    def test_it_NAMES_the_earlier_program_when_the_room_says_who_it_was(self):
        msg = self._notice(self._room_with("shared-room", "Alpha rail"))
        self.assertIn("Alpha rail", msg)

    def test_an_UNNAMEABLE_room_still_discloses_without_claiming_a_name(self):
        d = os.path.join(self.tmp, "nameless")
        os.makedirs(d)
        with open(os.path.join(d, "mockup.html"), "w") as fh:
            fh.write("<h1>earlier work")
        msg = self._notice(d)
        self.assertTrue(msg)
        self.assertNotIn("of the same name", msg)
        self.assertIn("mockup.html", msg)

    def test_it_still_says_WHAT_is_in_there_and_HOW_MUCH(self):
        """The reason the disclosure exists, unchanged: the preview he is about
        to see is somebody else's, and his next turn builds on it."""
        msg = self._notice(self._room_with("shared-room"))
        self.assertIn("mockup.html", msg)
        self.assertIn("2 file(s)", msg)
        low = msg.lower()
        self.assertIn("nothing has been deleted", low)
        self.assertIn("builds on it", low)

    def test_an_EMPTY_room_still_discloses_nothing(self):
        d = os.path.join(self.tmp, "empty-room")
        os.makedirs(d)
        self.assertEqual(self._notice(d), "")

    def test_the_live_reuse_banner_still_fires_end_to_end(self):
        """The endpoint half — the wording change must not cost the banner."""
        self._start("Nav rail")
        self._restart_daemon()
        _sid, state = self._start("Nav rail")
        notice = state.get("roomNotice") or {}
        self.assertEqual(notice.get("kind"), "room-reused", state)
        self.assertIn("Nav rail", notice.get("message", ""))


class TildeFenceTest(DurableBase):
    """L-3 — `~~~` is a CommonMark fence and was not protected.

    The comment above `_strip_copilot_tool_blocks` asserts "A FENCE IS THE
    CAPTAIN QUOTING, NOT THE CLI SPEAKING, so nothing inside one is touched" —
    true only of backtick fences, so three lines of a captain's diagram were
    silently deleted and an empty `~~~ ~~~` pair left behind. Recognising one
    more delimiter is STRUCTURAL; no prose is inspected.
    """

    TILDE = ("Diagram:\n\n~~~\n● Read x.css\n  │ a\n  └ b\n~~~\n\nend.\n")

    def test_a_TILDE_fenced_diagram_survives_byte_for_byte(self):
        from lcars_serve.actions import _strip_tool_trace
        for engine in (self.claude_bin, self.copilot_bin):
            self.assertEqual(_strip_tool_trace(self.TILDE, engine),
                             self.TILDE.rstrip("\n"), engine)

    def test_a_LONGER_tilde_fence_is_a_fence_too(self):
        from lcars_serve.actions import _strip_tool_trace
        text = "Look:\n\n~~~~\n● Read x.css\n  └ 1 file found\n~~~~\n\nok.\n"
        self.assertEqual(_strip_tool_trace(text, self.copilot_bin),
                         text.rstrip("\n"))

    def test_a_BACKTICK_fence_is_still_protected(self):
        """The control this cure could have broken."""
        from lcars_serve.actions import _strip_tool_trace
        text = "Diagram:\n\n```\n● Read x.css\n  │ a\n  └ b\n```\n\nend.\n"
        self.assertEqual(_strip_tool_trace(text, self.copilot_bin),
                         text.rstrip("\n"))

    def test_a_tilde_inside_a_BACKTICK_fence_does_not_close_it(self):
        from lcars_serve.actions import _strip_tool_trace
        text = "```\n~~~\n● Read x.css\n  └ 1 file found\n```\n"
        self.assertEqual(_strip_tool_trace(text, self.copilot_bin),
                         text.rstrip("\n"))

    def test_a_REAL_tool_block_OUTSIDE_a_fence_is_still_removed(self):
        """The calibration half: without it a stripper that fences everything
        and one that fences nothing read the same."""
        from lcars_serve.actions import _strip_tool_trace
        text = ("● Read board.css\n  │ web/static/board.css\n"
                "  └ L1:200 (200 lines read)\n\nThe rail is up.\n")
        self.assertEqual(_strip_tool_trace(text, self.copilot_bin),
                         "The rail is up.")


# ── S128 (FL-002 / FL-004) — THE IN-FLIGHT FACT IS THE DAEMON'S ─────────────
class InFlightDisclosureTest(DurableBase):
    """You may walk away from a running turn — nothing ever said you could.

    `sess.busy` was claimed under `_holodeck_lock` and surfaced NOWHERE, so a
    deck that re-rendered mid-turn (a reload, a second tab, a return from the
    board) read exactly like an idle one while the daemon would correctly refuse
    the next `/say`. This suite is the daemon half of the cure: the fact, its
    clock and the SENTENCE that goes with it are published on the program
    payload and on the board's own meta — and are ABSENT the rest of the time,
    because an idle program's payload must not move a byte.
    """

    BUSY_KEYS = ("busy", "busySince", "busyFor", "busyLabel", "busyReason")

    def _busy_keys(self, prog):
        return sorted(k for k in self.BUSY_KEYS if k in prog)

    def _prog(self, listing, name="Nav rail"):
        for p in listing["programs"]:
            if p["program"] == name:
                return p
        raise AssertionError("no program %r in %s" % (name, listing))

    def _say_async(self, sid, text, out, key="a"):
        def run():
            try:
                out[key] = self._post_raw("/api/holodeck/%s/say" % sid,
                                          {"text": text}, timeout=60)
            except Exception as exc:            # pragma: no cover - diagnostic
                out[key] = ("EXC", str(exc))
        t = threading.Thread(target=run)
        t.start()
        return t

    # -- the idle shape does not move ----------------------------------------
    def test_an_IDLE_programs_payload_carries_no_in_flight_keys(self):
        """THE ADDITIVE CONTRACT. Every other key on this payload was already
        being read by S124–S127 tests; a busy flag stamped `false` on every
        idle program would be a new key on the one shape those tests pin."""
        sid, _ = self._start()
        prog = self._prog(self._list())
        self.assertEqual(self._busy_keys(prog), [])
        self.assertNotIn("busy", json.dumps(prog))
        self.assertEqual(self._busy_keys(self._get("/api/holodeck/%s" % sid)),
                         [])

    def test_a_room_on_disk_is_never_reported_as_working(self):
        """A room the daemon is not holding has no conversation, so it cannot
        be mid-turn — and the disk shape must say so by the SAME rule the live
        one uses, or a restart and a live card start disagreeing about a lock."""
        sid, _ = self._start()
        self._post("/api/holodeck/%s/end" % sid)
        prog = self._prog(self._list())
        self.assertTrue(prog["onDisk"])
        self.assertEqual(self._busy_keys(prog), [])

    def test_an_idle_board_is_returned_byte_identical(self):
        """`holodeck_overlay` follows `align_overlay`'s discipline: with nothing
        in flight the board it is handed comes back unchanged."""
        self._start()
        board = self._get("/api/board")
        self.assertNotIn("holodeck", board["meta"])

    # -- and a turn in flight says so -----------------------------------------
    def test_a_program_MID_TURN_publishes_the_fact_its_clock_and_the_reason(self):
        self._set_turns({"sleep": 2.5, "stdout": "One.",
                         "writes": [{"path": "mockup.html", "content": "<h1>1"}]})
        sid, _ = self._start()
        out = {}
        t = self._say_async(sid, "Draft a nav rail", out)
        try:
            time.sleep(0.8)
            prog = self._prog(self._list())
            self.assertEqual(prog["busy"], True)
            # the CLOCK, as the daemon's own two numbers: when it started
            # (epoch seconds) and how long it has been going AT READ TIME. The
            # second is what a client renders, so it never has to agree with
            # the daemon about what o'clock it is.
            self.assertAlmostEqual(prog["busySince"], time.time(), delta=10)
            self.assertGreater(prog["busyFor"], 0.2)
            self.assertLess(prog["busyFor"], 30)
            # the SENTENCES. Both the deck's working line and the reason Send
            # is disabled come from here — the client may not invent either.
            self.assertTrue(prog["busyLabel"].strip())
            self.assertIn("ago", prog["busyLabel"].lower())
            reason = prog["busyReason"]
            self.assertIn("turn", reason.lower())
            for jargon in ("sess.", "mutex", "thread", "busy=", "409"):
                self.assertNotIn(jargon, reason.lower(), jargon)
            # …and the same fact on the single-program read the deck uses.
            one = self._get("/api/holodeck/%s" % sid)
            self.assertEqual(one["busy"], True)
        finally:
            t.join(60)
        self.assertEqual(out["a"][0], 200, out["a"])

    def test_the_board_itself_says_a_program_is_working(self):
        """OFF THE DECK. `board.py` had no holodeck awareness at all, so the
        one surface a captain is looking at while he waits could not tell him
        anything was happening."""
        self._set_turns({"sleep": 2.5, "stdout": "One."})
        sid, _ = self._start()
        out = {}
        t = self._say_async(sid, "Draft a nav rail", out)
        try:
            time.sleep(0.8)
            meta = self._get("/api/board")["meta"]["holodeck"]
            self.assertEqual(meta["count"], 1)
            self.assertEqual(meta["working"][0]["program"], "Nav rail")
            self.assertEqual(meta["working"][0]["sessionId"], sid)
            self.assertGreater(meta["working"][0]["busyFor"], 0.2)
            self.assertIn("Nav rail", meta["message"])
        finally:
            t.join(60)

    def test_the_fact_CLEARS_the_moment_the_turn_lands(self):
        self._set_turns({"sleep": 1.0, "stdout": "One."})
        sid, _ = self._start()
        out = {}
        t = self._say_async(sid, "Draft a nav rail", out)
        t.join(60)
        self.assertEqual(out["a"][0], 200, out["a"])
        self.assertEqual(self._busy_keys(self._prog(self._list())), [])
        self.assertNotIn("holodeck", self._get("/api/board")["meta"])

    def test_the_turns_OWN_answer_never_claims_to_be_working(self):
        """The payload of a `/say` is built inside `_run_turn`, while the claim
        is still held — so the naive version told the client the turn it was
        answering was still in flight. By the time those bytes are read the
        claim is released, which makes it a lie about the reader's own turn."""
        self._set_turns({"stdout": "One."})
        sid, _ = self._start()
        _st, body = self._post("/api/holodeck/%s/say" % sid, {"text": "go"})
        self.assertEqual(self._busy_keys(body["state"]), [])

    def test_the_fact_survives_the_client_that_started_it_going_away(self):
        """The whole point of FL-002: leave, come back, and the deck can still
        be told the truth by the daemon that never stopped working."""
        self._set_turns({"sleep": 2.0, "stdout": "One."})
        sid, _ = self._start()
        out = {}
        t = self._say_async(sid, "Draft a nav rail", out)
        try:
            time.sleep(0.7)
            first = self._prog(self._list())["busyFor"]
            time.sleep(0.7)
            second = self._prog(self._list())["busyFor"]
            self.assertGreater(second, first)
        finally:
            t.join(60)


# ════════════════════════════════════════════════════════════════════════════
# S169 — THE BRIEF CARRIES EVERYTHING THE MOCKUP CHANGES.
#
# THE MEASUREMENT. The S128 drive filed a real mission from a real program and
# went Align→Verify hands-off, 9/9 tickets green. The captain then put the
# built app beside his mockup: the light/dark theme and the wired status bar
# had landed and almost none of the LOOK had — top bar unrestyled, mode glyphs
# missing, Objects mode still carrying a top tab strip where the mockup has a
# left-hand object list. Off that mission's own plan.json: NOT ONE of the nine
# tickets carried a mockup-referencing acceptance criterion.
#
# Everything that survived was a STATED requirement; everything lost lived only
# in the picture. And the room had it written down the whole time — `##
# Decisions` names the left-hand object list, the mode pills and the single
# reconciled accent, and bucket 2 names the un-wired status bar. `promote` read
# neither. These suites are that room, byte for byte.
# ════════════════════════════════════════════════════════════════════════════
class S128DriveEvidenceTest(HandoffBase):
    """THE ACCEPTANCE FIXTURE — the real `concept.md` off the S128 drive.

    `web/tests/fixtures/s128-drive/concept.md` is a byte copy of the doc the
    holodeck wrote for the program the captain then compared against the built
    app on 2026-08-06. The three things the build got WRONG are all in it, and
    all in `## Decisions`, which the hand-off used to discard.
    """

    FIXTURE = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                           "fixtures", "s128-drive")

    @classmethod
    def setUpClass(cls):
        super(S128DriveEvidenceTest, cls).setUpClass()
        with open(os.path.join(cls.FIXTURE, "concept.md")) as fh:
            cls.CONCEPT = fh.read()

    def _brief(self):
        sid = self._program()
        _st, body = self._promote(sid)
        return body["state"]

    def test_the_fixture_is_the_real_room_and_not_a_tidied_copy(self):
        """Pin what the whole suite turns on. If someone 'fixes' the fixture,
        every claim below becomes a claim about nothing."""
        self.assertIn("left object list", self.CONCEPT)
        # wrapped at ~78 columns in the real doc, as every live one is —
        # `_md_items` folds it back into one decision.
        self.assertIn("pills for\n  mode tabs", self.CONCEPT)
        self.assertIn("Reconcile the dual accent", self.CONCEPT)
        # …and none of the three is anywhere in what he SAID.
        stated = self.CONCEPT.split("### 1. Requirements", 1)[1]
        stated = stated.split("### 2.", 1)[0]
        for lost in ("object list", "pills", "accent"):
            self.assertNotIn(lost, stated, lost)

    # S170 — THE THREE THINGS ARE STILL THE BAR, AND THEY NOW ARRIVE FROM THE
    # OTHER DIRECTION. S169 pinned them by reading `## Decisions` out of this
    # fixture; the change list is derived from a diff now, so what this suite
    # can honestly pin is that a derived list REACHES the brief intact and
    # reaches the FILED mission. The three sentences below are the derivation's
    # own output shape (`today X → mockup Y`) for the same three things the
    # built app got wrong.
    DERIVED = [
        "today Objects mode carries a top tab strip → the mockup gives it a "
        "left object list, centre sprite preview and right inspector",
        "today mode tabs are square 4px-radius buttons → the mockup uses "
        "pills for mode tabs",
        "today the Object Creator is indigo while the rest of the app is blue "
        "→ the mockup uses one blue primary everywhere",
    ]

    def _brief_with_changes(self):
        sid = self._program()
        self._seed_changes(sid, self.DERIVED)
        _st, body = self._promote(sid)
        return sid, body["state"]

    def test_the_THREE_THINGS_THE_BUILD_GOT_WRONG_reach_the_brief(self):
        """The headline. Each one lived only in the picture, and the mission
        was never told about any of them."""
        _sid, state = self._brief_with_changes()
        brief = state["brief"]
        self.assertIn("left object list", brief)
        self.assertIn("pills for mode tabs", brief)
        self.assertIn("one blue primary", brief)
        self.assertEqual(state["changes"], self.DERIVED)

    def test_the_CONVERSATIONS_OWN_LOG_no_longer_reaches_the_brief(self):
        """S170's inversion, stated as a fact about this fixture. `##
        Decisions` is still in the concept doc, is still maintained, and is now
        read by NOTHING on the drafting road — so a line that lives only there
        does not appear in the brief. This is the test that goes red the day
        somebody re-adds the transcription road beside the diff."""
        _sid, state = self._brief_with_changes()
        self.assertIn("Nudge radii up", self.CONCEPT)
        self.assertNotIn("Nudge radii up", state["brief"])
        self.assertNotIn("decisions", state)

    def test_the_UNWIRED_half_reaches_the_brief_too(self):
        """The captain's own words on this: "It needs to not just be there, but
        wire up the data. I wrote that in this time, so that's why it got it."
        A status bar that is drawn and not wired is a bucket-2 item."""
        brief = self._brief()["brief"]
        self.assertIn("bottom status bar", brief)
        self.assertIn("Saved 2m ago", brief)

    def test_his_own_words_are_still_first_and_STILL_CAPTURED(self):
        """S171 — BUCKET 1 IS STILL READ AND IS NO LONGER PASTED IN.

        It is his words quoted turn by turn, which is exactly the timeline he
        deletes by hand before sending (*"they had my whole chat about the
        close button vs x"*). What leads the brief is the description he typed
        himself, verbatim; the capture is intact and rides to the Mission in
        `concept.md`. Both halves are asserted, because losing either is a
        different defect."""
        _sid, state = self._brief_with_changes()
        brief = state["brief"]
        self.assertEqual(len(state["requirements"]), 3, state["requirements"])
        head = brief.split("## What the mockup changes", 1)[0]
        self.assertNotIn("— T1", head)
        self.assertNotIn("## What it must do", head)
        self.assertTrue(head.strip())
        blob = " ".join(r["text"] for r in state["requirements"])
        for said in ("give the tile editor a more modern UI look",
                     "add a light/dark mode",
                     "I don't want to touch the tile canvas at all"):
            self.assertIn(said, blob, said)
        # …and the attribution survives WHERE IT BELONGS — on the capture.
        self.assertIn("T1", blob)

    def test_the_implied_half_is_MARKED_and_never_laundered_into_his_words(self):
        """FL-011's subject, and it must not be lost while curing this. An
        implied item that reads as something he said arrives silent and
        authoritative — which is the failure this whole hand-off exists to
        prevent."""
        brief = self._brief()["brief"]
        head, implied = brief.split("## Implied by the mockup", 1)
        self.assertIn("NOT things you said", implied.split("\n", 1)[0])
        self.assertIn("IMPLIED", implied)
        self.assertNotIn("Saved 2m ago", head)

    def test_the_brief_stays_SKIMMABLE(self):
        """The trap this change walks into is a box so long nobody reads it,
        and being ignored is the same outcome as not shipping it.

        S170 MOVES THIS NUMBER THE RIGHT WAY, which is the captain's actual
        complaint: `## Decisions` on his real room is 21 bullets of
        conversation, and a diff of the same program is shorter because
        everything the mockup leaves alone produces no line."""
        _sid, state = self._brief_with_changes()
        brief = state["brief"]
        self.assertLessEqual(len(brief.split("\n")), 45, brief)
        self.assertLessEqual(len(brief), 3600, len(brief))

    def test_everything_in_the_brief_reaches_the_FILED_mission(self):
        sid = self._program()
        self._seed_changes(sid, self.DERIVED)
        _st, promo = self._promote(sid)
        self._post("/api/park", {"idea": promo["state"]["brief"],
                                 "holodeck": sid})
        text = self._filed()[0]["files"]["--idea"]
        for lost in ("left object list", "pills for mode tabs",
                     "one blue primary", "bottom status bar"):
            self.assertIn(lost, text, lost)
        # S171 — and no requirement-loss block rides any more (deleted with
        # `_handoff_missing`); the concept doc carries his words instead.
        self.assertNotIn("not in the brief", text.lower())


class HandoffChangeListTest(HandoffBase):
    """The change list — DERIVED FROM A DIFF, not transcribed from a log.

    S169 read it out of `## Decisions`. The captain then drove that output on
    his own program and found it was "a lot of my ramble back and forth": that
    section is a log of the CONVERSATION, so it faithfully records him
    correcting THE MOCKUP, and downstream those corrections read as
    instructions to change the real app. See the block above
    `_HANDOFF_DECISIONS_HEADING` for the four measured examples.

    So the list is now produced by a bounded read-only pass standing in the
    captain's own repo (`_handoff_derive_*`), and `_handoff_brief` is a pure
    assembler over whatever that pass returned. These tests are about the
    ASSEMBLY; the pass itself is `S170DerivationTest` and the live drive.
    """

    CHANGES = ["today mode tabs are square buttons → the mockup uses pills",
               "today Objects mode has a top tab strip → the mockup gives it "
               "a left-hand object list"]

    def _concept(self, sid, text):
        self._set_turns({"stdout": "ok",
                         "writes": [{"path": "concept.md", "content": text}]})
        self._post("/api/holodeck/%s/say" % sid, {"text": "update it"})

    DOC = ("# P\n\n## Decisions\n\n"
           "- **T2** Mode tabs become pills; the top bar loses its divider.\n"
           "- **T3** Objects mode gets a left-hand object list.\n\n"
           "## WHAT IT MUST DO\n\n### 1. Requirements\n\n"
           "- \"Give it a modern look.\"\n\n"
           "### 2. Implied by the mockup, not yet settled\n\n"
           "- Q: does the toggle persist?\n")

    def test_the_changes_ride_in_the_payload_as_a_SET(self):
        sid = self._program()
        self._concept(sid, self.DOC)
        self._seed_changes(sid, self.CHANGES)
        _st, body = self._promote(sid)
        self.assertEqual(body["state"]["changes"], self.CHANGES)

    def test_the_payload_no_longer_carries_a_DECISIONS_KEY(self):
        """THE KEY WAS RENAMED, NOT REFILLED, and that is deliberate: a client
        still reading `decisions` gets nothing rather than something that reads
        the same and is a different thing. `changes` is a diff against the
        captain's repo; `decisions` was an account of a conversation."""
        sid = self._program()
        self._concept(sid, self.DOC)
        _st, body = self._promote(sid)
        self.assertNotIn("decisions", body["state"])
        self.assertIn("changes", body["state"])

    def test_the_CONVERSATION_LOG_is_not_the_change_list_any_more(self):
        """The defect, pinned on a doc built to reproduce it. `## Decisions`
        here names two real changes and NEITHER reaches the brief, because
        nothing on the drafting road reads that section."""
        sid = self._program()
        self._concept(sid, self.DOC)
        _st, body = self._promote(sid)
        self.assertEqual(body["state"]["changes"], [])
        self.assertNotIn("loses its divider", body["state"]["brief"])

    def test_a_MOCK_RELATIVE_correction_simply_HAS_NO_LINE(self):
        """THE ACCEPTANCE SHAPE, in miniature and structural.

        The captain's own example: *"it says a bare x icon needs to say close,
        but the existing one says close and I just told the holodeck to fix its
        mock to add the close button back in."* The concept doc records that
        correction. A DIFF of the finished mockup against an app that already
        has a labelled Close button produces NOTHING for it — there is no
        difference to report — so the line does not need to be recognised,
        reworded or filtered. It is simply absent.

        NOTE WHAT IS **NOT** HERE: no code reads a change line and decides
        anything about it. S156 lost a session to a classifier (14/14 → 5/14 on
        a reworded corpus), S147 four parser generations, S157 five guards.
        """
        sid = self._program()
        self._concept(sid, "# P\n\n## Decisions\n\n"
                           "- **T3** Add a Close button to the toolbar, right "
                           "of Save — today the editor already has a "
                           "close-project control; the mock now models it "
                           "correctly as a labeled \"Close\" button.\n\n"
                           "## WHAT IT MUST DO\n\n### 1. Requirements\n\n"
                           "- \"Give it a modern look.\"\n")
        # The pass, standing in the repo, found one real difference and had
        # nothing to say about the Close button.
        self._seed_changes(sid, ["today mode tabs are square buttons → the "
                                 "mockup uses pills"])
        _st, body = self._promote(sid)
        brief = body["state"]["brief"]
        self.assertNotIn("Close", brief)
        self.assertIn("pills", brief)

    def test_a_pass_that_found_NOTHING_says_LESS_rather_than_inventing(self):
        """The failure mode this road is chosen for. No derivation, no change
        section — never a plausible-looking one back-filled from the log."""
        sid = self._program()
        self._concept(sid, "# P\n\n## Decisions\n\n- **T1** Everything.\n\n"
                           "## WHAT IT MUST DO\n\n"
                           "### 1. Requirements\n\n- \"Just build it.\"\n")
        _st, body = self._promote(sid)
        self.assertEqual(body["state"]["changes"], [])
        self.assertNotIn("What the mockup changes", body["state"]["brief"])

    def test_the_change_list_is_MARKED_as_READ_OFF_THE_PROJECT(self):
        sid = self._program()
        self._concept(sid, self.DOC)
        self._seed_changes(sid, self.CHANGES)
        _st, body = self._promote(sid)
        brief = body["state"]["brief"]
        # The heading names its provenance — the captain's app, not the chat.
        self.assertIn("## What the mockup changes about your app as it is "
                      "today", brief)
        # …and the caption states the rule that makes the list readable.
        self.assertIn("produces no line here", brief)
        self.assertIn("the picture wins", brief)

    def test_the_change_list_comes_AFTER_his_own_words(self):
        """He reads his own words first — they are what he recognises, and the
        rest is the product's draft of what he drew."""
        sid = self._program()
        self._concept(sid, self.DOC)
        self._seed_changes(sid, self.CHANGES)
        _st, body = self._promote(sid)
        brief = body["state"]["brief"]
        # S171 — HIS OWN WORDS ARE THE FIRST LINE, not a section: the numbered
        # `## What it must do — in your own words` list is what he called a
        # timeline. The ORDER claim survives, measured against the head.
        self.assertLess(brief.index("Command palette"),
                        brief.index("## What the mockup changes"))
        self.assertLess(brief.index("## What the mockup changes"),
                        brief.index("## Implied by the mockup"))


class HandoffOutOfScopeTest(HandoffBase):
    """Bucket 3 — what the work must NOT touch.

    S170, from the captain's own design: `## Decisions` demotes to "why a
    change was chosen, PLUS the explicit out-of-scope". The out-of-scope half
    is the part a diff structurally CANNOT produce — a diff reports
    differences, and "do not touch the tile canvas" is a statement about what
    must produce no difference at all. So it rides in its own named block, read
    off the concept doc's bucket 3.
    """

    DOC = ("# P\n\n## WHAT IT MUST DO\n\n### 1. Requirements\n\n"
           "- \"Give it a modern look.\"\n\n"
           "### 2. Implied by the mockup, not yet settled\n\n"
           "- Q: does the toggle persist?\n\n"
           "### 3. Out of scope\n\n"
           "- The tile canvas rendering — left untouched.\n"
           "- OS-preference detection and theme persistence.\n")

    def _concept(self, sid, text):
        self._set_turns({"stdout": "ok",
                         "writes": [{"path": "concept.md", "content": text}]})
        self._post("/api/holodeck/%s/say" % sid, {"text": "update it"})

    def test_bucket_3_rides_as_its_own_named_block(self):
        sid = self._program()
        self._concept(sid, self.DOC)
        _st, body = self._promote(sid)
        state = body["state"]
        self.assertEqual(state["outOfScope"],
                         ["The tile canvas rendering — left untouched.",
                          "OS-preference detection and theme persistence."])
        self.assertIn("## Out of scope — do not touch these", state["brief"])
        self.assertIn("tile canvas rendering", state["brief"])

    def test_it_is_LAST_so_it_never_pushes_his_own_words_down(self):
        sid = self._program()
        self._concept(sid, self.DOC)
        _st, body = self._promote(sid)
        brief = body["state"]["brief"]
        self.assertLess(brief.index("## Implied by the mockup"),
                        brief.index("## Out of scope"))

    def test_bucket_3_is_NEVER_promoted_into_things_he_SAID(self):
        """The FL-011 rule, applied to the new block: an out-of-scope item is
        not a requirement and must never read as one."""
        sid = self._program()
        self._concept(sid, self.DOC)
        _st, body = self._promote(sid)
        state = body["state"]
        for r in state["requirements"]:
            self.assertNotIn("tile canvas", r["text"])
        head = state["brief"].split("## Implied by the mockup", 1)[0]
        self.assertNotIn("tile canvas", head)

    def test_a_doc_with_NO_bucket_3_gets_NO_BLOCK(self):
        sid = self._program()
        _st, body = self._promote(sid)
        self.assertEqual(body["state"]["outOfScope"], [])
        self.assertNotIn("## Out of scope", body["state"]["brief"])


class HandoffImpliedTest(HandoffBase):
    """Bucket 2 — behaviour the mockup implies that nobody has stated.

    The machinery already existed and was thrown away: S128 excluded bucket 2
    from the brief pending a dedup rule, and that exclusion is the defect.
    """

    def _concept(self, sid, text):
        self._set_turns({"stdout": "ok",
                         "writes": [{"path": "concept.md", "content": text}]})
        self._post("/api/holodeck/%s/say" % sid, {"text": "update it"})

    def test_the_implied_items_ride_in_the_payload_as_a_SET(self):
        sid = self._program()
        _st, body = self._promote(sid)
        self.assertEqual(body["state"]["implied"],
                         ["Q: is the pinned row real?"])

    def test_an_implied_item_is_NEVER_a_captured_requirement(self):
        """The line FL-011 is about. Bucket 2 must not become "what you said" —
        the requirement SET is the captain's own words and nothing else."""
        sid = self._program()
        _st, body = self._promote(sid)
        for r in body["state"]["requirements"]:
            self.assertNotIn("pinned row", r["text"])

    def test_a_concept_with_no_bucket_2_adds_no_section(self):
        sid = self._program()
        self._concept(sid, "# P\n\n## WHAT IT MUST DO\n\n"
                           "### 1. Requirements\n\n- \"Just build it.\"\n")
        _st, body = self._promote(sid)
        self.assertEqual(body["state"]["implied"], [])
        self.assertNotIn("Implied by the mockup", body["state"]["brief"])

    def test_bucket_3_out_of_scope_is_NOT_carried_as_implied(self):
        """Bucket 3 is what he explicitly ruled out. S170 gives it its own
        named block (`HandoffOutOfScopeTest`) — what must NEVER happen is it
        arriving as something the mockup IMPLIES, which reads as a thing to
        build rather than a thing to leave alone."""
        sid = self._program()
        self._concept(sid, "# P\n\n## WHAT IT MUST DO\n\n"
                           "### 1. Requirements\n\n- \"Just build it.\"\n\n"
                           "### 2. Implied by the mockup, not yet settled\n\n"
                           "- Q: does the toggle persist?\n\n"
                           "### 3. Out of scope\n\n"
                           "- The canvas renderer, ruled out at T1.\n")
        _st, body = self._promote(sid)
        self.assertEqual(body["state"]["implied"],
                         ["Q: does the toggle persist?"])
        self.assertEqual(body["state"]["outOfScope"],
                         ["The canvas renderer, ruled out at T1."])
        brief = body["state"]["brief"]
        self.assertNotIn("canvas renderer",
                         brief.split("## Out of scope", 1)[0])


class HandoffDedupTest(HandoffBase):
    """THE DEDUP RULE — why S128 deferred bucket 2 in the first place.

    The captain must not skim the same sentence three times; an over-long box
    is how the whole thing gets ignored. Carried by the FIRST road that claims
    it — requirements, then open questions (their own panel), then the derived
    change list, then implied, then out of scope — dropping only on whole-word
    CONTAINMENT, never similarity, and only when the thing already on screen
    says at least as much.

    S170 — THE THIRD ROAD IS NOW THE DIFF. The rule is unchanged and its input
    moved: what used to be `## Decisions` bullets is now the derivation's
    output, seeded here through the daemon's own durable record.
    """

    def _concept(self, sid, text):
        self._set_turns({"stdout": "ok",
                         "writes": [{"path": "concept.md", "content": text}]})
        self._post("/api/holodeck/%s/say" % sid, {"text": "update it"})

    HEAD = ("# P\n\n## Open questions\n\n%s\n\n"
            "## WHAT IT MUST DO\n\n### 1. Requirements\n\n%s\n\n"
            "### 2. Implied by the mockup, not yet settled\n\n%s\n")

    def _doc(self, questions="- A question nobody repeats anywhere?",
             reqs="- \"Just build the whole thing.\"",
             implied="- Q: something nobody repeats anywhere?"):
        return self.HEAD % (questions, reqs, implied)

    def _run(self, changes=("A change nobody repeats anywhere.",), **doc):
        """Write the concept doc, seed the derivation, promote. IN THAT ORDER —
        the fingerprint covers `concept.md`, so seeding before the write would
        key the record to a document that is about to be replaced."""
        sid = self._program()
        self._concept(sid, self._doc(**doc))
        self._seed_changes(sid, list(changes))
        _st, body = self._promote(sid)
        return body["state"]

    def test_an_implied_item_REPEATING_an_open_question_is_dropped(self):
        """It has its own panel, its own answer box and its own STILL OPEN
        block in the filed mission. Twice is once too many."""
        st = self._run(
            questions="- Should the theme toggle persist across sessions?",
            implied="- Should the theme toggle persist across sessions?")
        self.assertEqual(st["implied"], [])
        self.assertEqual(st["brief"].count("theme toggle persist"), 0)

    def test_a_DERIVED_CHANGE_repeating_something_he_SAID_is_dropped(self):
        st = self._run(reqs="- \"The mode tabs should become pills.\"",
                       changes=["The mode tabs should become pills."])
        self.assertEqual(st["changes"], [])

    def test_an_implied_item_REPEATING_a_derived_change_is_dropped(self):
        """Settled beats unsettled: showing a change the diff already found as
        "not yet settled" would be the surface contradicting itself."""
        st = self._run(changes=["Objects mode gets a left-hand object list."],
                       implied="- Objects mode gets a left-hand object list.")
        self.assertEqual(st["changes"],
                         ["Objects mode gets a left-hand object list."])
        self.assertEqual(st["implied"], [])

    def test_a_SHORTER_restatement_inside_a_longer_one_is_dropped(self):
        """Whole-word containment, in ONE direction only — the thing already on
        screen must say at least as much as the thing being dropped."""
        st = self._run(
            changes=["Objects mode gets a left-hand object list, with the "
                     "sprite preview in the centre and an inspector right."],
            implied="- Objects mode gets a left-hand object list")
        self.assertEqual(st["implied"], [])

    def test_the_LONGER_one_is_NEVER_dropped_for_a_shorter_one(self):
        """The direction that matters. Dropping the detailed line because a
        summary of it already appeared is a silent loss, and silent loss is the
        entire defect class this session exists to cure."""
        st = self._run(
            changes=["Objects mode gets a left-hand object list"],
            implied="- Objects mode gets a left-hand object list, with the "
                    "sprite preview in the centre and an inspector right.")
        self.assertEqual(len(st["implied"]), 1, st["implied"])
        self.assertIn("sprite preview", st["implied"][0])

    def test_a_SHORT_line_is_only_dropped_on_an_EXACT_repeat(self):
        """A three-word line is too small to be safely matched inside another
        sentence, so containment does not apply to it. `_HANDOFF_DEDUP_MIN_
        WORDS` is that floor, and this is what it buys."""
        st = self._run(changes=["Pills, not tabs, everywhere in the chrome."],
                       implied="- Pills, not tabs")
        self.assertEqual(st["implied"], ["Pills, not tabs"])

    def test_DIFFERENT_things_are_all_kept(self):
        """The control. A dedup that dropped everything would pass every test
        above and hand the captain an empty change list."""
        st = self._run()
        self.assertEqual(len(st["changes"]), 1)
        self.assertEqual(len(st["implied"]), 1)
        self.assertEqual(len(st["questions"]), 1)
        self.assertEqual(len(st["requirements"]), 1)

    def test_a_line_repeated_INSIDE_the_derived_list_is_shown_once(self):
        st = self._run(changes=["Objects mode gets a left-hand object list.",
                                "Objects mode gets a left-hand object list."])
        self.assertEqual(len(st["changes"]), 1)


class HandoffContractTest(HandoffBase):
    """The turn prompt has to ASK for what the hand-off now reads.

    The other half of the dedup rule lives here: a reworded twin ("keep the
    status bar?" vs "is a status bar in scope, or noise?") is not catchable by
    containment and must never be caught by a similarity score — so the
    contract tells the design worker to write each undecided thing in exactly
    ONE of the two lists.
    """

    def test_the_contract_asks_DECISIONS_for_the_REASONING_not_the_path(self):
        """S170 — `## Decisions` is the EXPLANATION now, and the contract says
        so at the far end of the model too. The captain's measured complaint is
        that the section records him correcting the MOCKUP, so the contract
        names that shape and forbids it by example."""
        from lcars_serve.actions import _CONCEPT_CONTRACT
        self.assertIn("REASONING RECORD, not the change list", _CONCEPT_CONTRACT)
        self.assertIn("NEVER THE PATH", _CONCEPT_CONTRACT)
        self.assertIn("T1 mock had a two-part", _CONCEPT_CONTRACT)

    def test_the_contract_no_longer_calls_DECISIONS_the_change_list(self):
        """The line that made S169's road look correct from inside the
        product. Leaving it would tell every future design worker to keep
        writing the log the brief no longer reads."""
        from lcars_serve.actions import _CONCEPT_CONTRACT
        self.assertNotIn("THIS IS THE CHANGE LIST", _CONCEPT_CONTRACT)

    def test_the_contract_gives_each_undecided_thing_ONE_HOME(self):
        from lcars_serve.actions import _CONCEPT_CONTRACT
        self.assertIn("ONE HOME EACH", _CONCEPT_CONTRACT)
        self.assertIn("exactly one of the two places", _CONCEPT_CONTRACT)

    def test_the_contract_names_the_DRAWN_but_UNWIRED_case(self):
        """The captain's own example — a status bar that exists and is not
        wired to anything."""
        from lcars_serve.actions import _CONCEPT_CONTRACT
        self.assertIn("WIRES UP", _CONCEPT_CONTRACT)

    def test_the_sections_the_daemon_reads_are_the_sections_it_ASKS_FOR(self):
        """The FL-011 shape: a brief drafted from a section nothing maintains.
        Every heading the hand-off reads must be one the turn prompt demands."""
        from lcars_serve.actions import (_CONCEPT_CONTRACT,
                                         _HANDOFF_DECISIONS_HEADING,
                                         _HANDOFF_IMPLIED_BUCKETS)
        self.assertIn("## " + _HANDOFF_DECISIONS_HEADING, _CONCEPT_CONTRACT)
        self.assertIn(_HANDOFF_IMPLIED_BUCKETS[1], _CONCEPT_CONTRACT)


# ════════════════════════════════════════════════════════════════════════════
# S169 FIX ROUND 1 — THE CHANGE LIST ASSERTED A CHANGE WAS **NOT** MADE
#
# THE MEASUREMENT, on the tester's live copilot drive of 2026-08-06. The brief
# the shipping daemon produced for a real program room contained:
#
#     - Turn 2 — Kept the `.brand` "Waypoint" label and the "New trip" button
#       from the existing topbar; kept the `6/12/16px` spacing rhythm and
#       `system-ui`.
#
# THAT IS FALSE, and `web/tests/fixtures/s169-drive/` is the byte copy that
# proves it: the mockup in the SAME room renders
# `<span class="brand">Way<span class="dot">•</span>point</span>` with an accent
# `.dot`, and turns the "New trip" button into `class="primary"` — accent-filled
# and `font-weight:700` — against a repo whose top bar is a plain
# `<span class="brand">Waypoint</span>`.
#
# WHY IT IS WORSE THAN AN OMISSION. An implementer who reads "kept … from the
# existing topbar" LEAVES THE TOP BAR ALONE — which is precisely what the
# captain complained about after the S128 build ("top bar unrestyled"), arrived
# at by a new route. And it was AMPLIFIED: `_HANDOFF_PRECEDENCE` told every
# stage the brief OVERRIDES the mockup, so the false line WON over the picture
# that contradicts it.
#
# ── THE CURE, AND WHY IT IS NOT A CLASSIFIER ────────────────────────────────
#
# Nothing added here reads the captain's sentence, the model's sentence, or the
# mockup's markup and decides anything. There is no keyword test for "kept", no
# similarity score, no `basis.md` parser — S156 fell 14/14 → 5/14 on a
# meaning-preserving rewording, S147 lost four generations of a source parser,
# S157 five versions of a guard, and this would have been the sixth.
#
# What changed is WHO IS THE AUTHORITY, stated structurally:
#
#   1. `_HANDOFF_PRECEDENCE` is now SPLIT BY DOMAIN. The brief still overrides
#      on WHAT IT MUST DO; on HOW IT LOOKS the MOCKUP overrides the brief,
#      because the mockup is the artifact and the brief is an ACCOUNT of the
#      conversation that drew it. That is a fact about the two documents, true
#      of every program, and it defuses the amplification without inspecting a
#      single line of either one.
#   2. `_HANDOFF_DISAGREEMENT` now covers the CONTRADICTION direction. It only
#      ever named the omission case ("the mockup shows something the brief never
#      mentions"), which is not the shape of this defect at all.
#   3. The change list's caption stops asserting what the daemon cannot know.
#      "Today's app does none of it" is a claim about the captain's code; the
#      daemon never reads `basis.md` and cannot verify one word of it.
#   4. `_CONCEPT_CONTRACT` is tightened too — and DELIBERATELY NOT ALONE. S169's
#      build wave already sharpened it once (the `today X → now Y` rule) and
#      this program was written by a live worker UNDER that contract; wording
#      at the far end of a model is measured insufficient on its own.
#
# WHAT IS DELIBERATELY NOT CURED: the false line still reaches the brief. The
# daemon cannot tell a true "kept" from a false one, so it does not try —
# `test_the_false_line_STILL_RIDES` pins that as the honest outcome. What it can
# do is stop the line outranking the picture, and stop the surface vouching for
# it.
# ════════════════════════════════════════════════════════════════════════════
class S169FalseKeptLineTest(HandoffBase):
    """The tester's real program room, against the shipping hand-off path."""

    FIXTURE = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                           "fixtures", "s169-drive")
    FALSE_LINE = ("Kept the `.brand` \"Waypoint\" label and the \"New trip\" "
                  "button from")

    @classmethod
    def setUpClass(cls):
        super(S169FalseKeptLineTest, cls).setUpClass()
        with open(os.path.join(cls.FIXTURE, "concept.md")) as fh:
            cls.CONCEPT = fh.read()
        with open(os.path.join(cls.FIXTURE, "mockup.html")) as fh:
            cls.MOCK = fh.read()
        # the room gets the REAL mockup too, so the program the hand-off runs
        # on is the tester's program and not a stand-in wearing its concept doc.
        cls.MOCKUP = cls.MOCK

    def _brief(self):
        sid = self._program()
        _st, body = self._promote(sid)
        return body["state"]

    def test_the_fixture_is_the_real_room_and_the_line_really_is_FALSE(self):
        """Pin the evidence. If someone 'fixes' the fixture, every claim below
        becomes a claim about nothing."""
        # the doc SAYS the top bar was kept…
        self.assertIn("Kept the `.brand` \"Waypoint\" label", self.CONCEPT)
        self.assertIn("kept the `6/12/16px` spacing rhythm", self.CONCEPT)
        # …and the mockup in the same room plainly changed it.
        self.assertIn("Way<span class=\"dot\">", self.MOCK)
        self.assertIn(".brand .dot{color:var(--accent)}", self.MOCK)
        self.assertIn("class=\"primary\"", self.MOCK)
        # …against a top bar that `basis.md` — the program's own reading of the
        # captain's repo, in the same room — records as a plain label and a
        # plain button. THE DAEMON NEVER READS THIS FILE; it is here so a human
        # auditing the fixture can see the claim really is false, and so the
        # evidence cannot be quietly edited out from under the tests above.
        with open(os.path.join(self.FIXTURE, "basis.md")) as fh:
            basis = fh.read()
        self.assertIn("a `.brand` label (\"Waypoint\") plus a `<button id="
                      "\"new\">New trip</button>`", basis)
        self.assertIn("No brand colour, no accent", basis)

    def test_the_false_line_NO_LONGER_RIDES_and_NOTHING_DETECTED_IT(self):
        """S170 — AND THIS IS WHAT THE INVERSION BOUGHT.

        S169 pinned the opposite ("the line rides") as its honest outcome: the
        daemon could not verify a claim about the captain's code, so it did not
        try, and three live passes plus three prompt sharpenings failed to flag
        this one. The line is gone now — and READ HOW. Nothing detected it,
        nothing scored it, nothing matched "kept". It is gone because
        `## Decisions` IS NO LONGER READ BY THE DRAFTING ROAD AT ALL. That is
        the same structural move that deletes the captain's own examples: a
        diff of the finished mockup against his repo has nothing to say about a
        sentence in a conversation log.

        WHAT IS STILL TRUE, and is not claimed away: a DERIVED line can be
        wrong. What it cannot be is wrong about a document nobody read."""
        brief = self._brief()["brief"]
        self.assertNotIn(self.FALSE_LINE, brief)
        self.assertNotIn("kept the `6/12/16px` spacing rhythm", brief)
        # …and the mechanism is absence, not filtering: the sentence is still
        # in the concept doc, untouched, in the room the mission is handed.
        self.assertIn(self.FALSE_LINE, self.CONCEPT)

    def test_NO_CLASSIFIER_was_added_to_achieve_that(self):
        """The control on the control. S156 fell 14/14 → 5/14 on a
        meaning-preserving rewording of its own corpus; S147 lost four parser
        generations; S157 five guards. A reworded twin of the false line must
        behave IDENTICALLY — which it does, because nothing looks at it."""
        import lcars_serve.actions as A
        src = open(A.__file__).read()
        for banned in ("\"kept\"", "'kept'", "\"unchanged\"",
                       "'unchanged'", "\"carried over\""):
            self.assertNotIn(banned + " in ", src, banned)
        # and the drafting road takes the change list as an ARGUMENT — there is
        # nowhere for a filter to live between the pass and the box.
        import inspect
        sig = inspect.signature(A._handoff_brief)
        self.assertIn("changes", sig.parameters)

    def test_the_caption_no_longer_asserts_what_the_daemon_CANNOT_KNOW(self):
        """"Today's app does none of it" is a claim about code the daemon has
        never opened, printed directly above a line saying a thing was KEPT."""
        brief = self._brief()["brief"]
        self.assertNotIn("Today's app does none of it", brief)
        self.assertNotIn("does none of it", brief)

    def test_the_caption_says_what_the_SECTION_IS_instead(self):
        """S170 — and it may now say the thing S169's caption was forbidden to
        say, because it has become true: this list IS a reading of the
        captain's repository. What it must ALSO say is the rule that makes the
        list readable — that anything left alone produces no line."""
        from lcars_serve.actions import _HANDOFF_CHANGE_NOTE
        sid = self._program()
        self._seed_changes(sid, ["today the brand is a plain label → the "
                                 "mockup gives it an accent dot"])
        _st, body = self._promote(sid)
        brief = body["state"]["brief"]
        self.assertIn(_HANDOFF_CHANGE_NOTE, brief)
        low = _HANDOFF_CHANGE_NOTE.lower()
        self.assertIn("read off your project", low)
        self.assertIn("produces no line here", low)
        # …and it must say the picture wins, right where he reads the list.
        self.assertIn("mockup", low)

    def test_the_change_list_is_SUBORDINATE_TO_THE_MOCKUP_on_LOOK(self):
        """The mechanism. Where the list and the picture disagree about how
        something LOOKS, the picture is the authority — because the picture is
        the artifact and the list is an account of the talk that produced it."""
        from lcars_serve.actions import _HANDOFF_PRECEDENCE
        p = _HANDOFF_PRECEDENCE
        # the S128 half, untouched: an override, never a completeness claim.
        self.assertIn("OVERRIDES the mockup", p)
        self.assertIn("not a claim that the brief is exhaustive", p)
        # the S169 half: it is an override about BEHAVIOUR, and LOOK goes the
        # other way.
        self.assertIn("WHAT IT MUST DO", p)
        self.assertIn("HOW IT LOOKS", p)
        self.assertIn("the mockup is the authority", p)
        self.assertIn("OVERRIDES the brief", p)

    def test_a_CONTRADICTION_is_evidence_the_stage_must_not_settle(self):
        """`_HANDOFF_DISAGREEMENT` only ever named the OMISSION direction — the
        mockup showing something the brief never mentions. This defect is the
        other one: the brief saying something the mockup contradicts."""
        from lcars_serve.actions import _HANDOFF_DISAGREEMENT
        d = _HANDOFF_DISAGREEMENT
        self.assertIn("CONTRADICTS", d.upper())
        self.assertIn("unchanged", d.lower())
        self.assertIn("ESCALATE", d)

    def test_the_precedence_rule_reaches_the_MISSION_and_the_CAPTAIN(self):
        """Both readers, from the one constant — the deck's visible guidance
        block and the idea the mission is actually filed with."""
        from lcars_serve.actions import _HANDOFF_PRECEDENCE
        sid = self._program()
        _st, promo = self._promote(sid)
        self.assertIn(_HANDOFF_PRECEDENCE, promo["state"]["guidance"])
        self._post("/api/park", {"idea": promo["state"]["brief"],
                                 "holodeck": sid})
        self.assertIn(_HANDOFF_PRECEDENCE,
                      self._filed()[0]["files"]["--idea"])

    def test_a_KEPT_line_can_no_longer_REACH_the_change_list_at_all(self):
        """S169 fought this with contract wording at the far end of a model —
        measured insufficient three times over. S170 removes the road: the
        change list is not written by the design worker any more, so no
        sentence it writes can become one, however it is worded."""
        sid = self._program()
        self._seed_changes(sid, ["today the brand is a plain label → the "
                                 "mockup gives it an accent dot"])
        _st, body = self._promote(sid)
        self.assertEqual(body["state"]["changes"],
                         ["today the brand is a plain label → the mockup "
                          "gives it an accent dot"])
        self.assertNotIn("Kept the `.brand`", body["state"]["brief"])

    def test_what_was_DRAWN_but_never_DISCUSSED_is_absent_and_that_is_SAID(self):
        """`.map-scale`, `.rail-head`, the 6px radii and the uppercase micro
        labels are all in the mockup and in NO section of the concept doc, so
        no declared list could carry them.

        S170 — AND THIS IS THE OTHER HALF OF WHAT THE DIFF BUYS. A derived list
        is not bounded by what the conversation happened to mention: a pass
        standing in the repo can report a scale bar the chat never discussed.
        What is pinned here is the FIXTURE'S evidence — both elements really
        are in the drawing and in no section of the doc — so a future reader
        can see why the declared road could never have reached them."""
        for drawn in ("map-scale", "rail-head"):
            self.assertIn(drawn, self.MOCK, drawn)
            self.assertNotIn(drawn, self.CONCEPT, drawn)


# ════════════════════════════════════════════════════════════════════════════
# S169 (FL-014) — A PASTED IMAGE REACHES THE ENGINE
#
# Found by the captain on the S128 re-drive: "I can't paste in images in my
# chat." It was MISSING, not broken — and it was a DECLARED gap: `holodeck_say`
# already took an `images` parameter and opened with an honest refusal. He could
# never read that sentence, because with no paste handler on the composer the
# clipboard event was never harvested and nothing was ever sent.
#
# WHAT IS ASSERTED HERE, and why it is the whole point: the per-engine ARGV.
# "The daemon accepted the image" is not the claim — S91 measured that copilot
# takes `--attachment <path>` natively while claude reads a path named in the
# prompt with its Read tool, and threading it the WRONG way per CLI is a turn
# where the engine simply never sees the screenshot and says something
# plausible anyway. Zero tokens: the recording stub captures the full argv.
# ════════════════════════════════════════════════════════════════════════════
_PNG_B64 = ("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8"
            "z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")


class PastedImageReachesTheEngineTest(HolodeckBase):
    def _start(self, engine=None, program="Nav rail"):
        _, body = self._post("/api/holodeck/start",
                             {"program": program,
                              "engine": engine or self.claude_bin})
        return body["state"]["sessionId"]

    def _room(self, program="nav-rail"):
        # REALPATH: the staged path comes back through `_room_file_path`, the
        # preview route's jail, which resolves symlinks — and on macOS the
        # tempdir's own /var → /private/var link is enough to make a plain
        # join() disagree with what is actually on the argv.
        return os.path.realpath(os.path.join(self._sidecar(), program))

    @staticmethod
    def _img(name="kitchen reference.png", ctype="image/png"):
        return {"name": name, "type": ctype, "dataB64": _PNG_B64}

    def test_claude_gets_the_path_in_the_prompt_and_no_attachment_flag(self):
        """claude's design posture already allows Read
        (`_HOLODECK_TOOLS[("claude","design")]`), so the abs path is NAMED and
        the engine opens it itself — no tool exception, no new flag."""
        sid = self._start()
        status, body = self._post("/api/holodeck/%s/say" % sid,
                                  {"text": "make it look like this",
                                   "images": [self._img()]})
        self.assertEqual(status, 200)
        argv = self._calls()[-1]["argv"]
        self.assertNotIn("--attachment", argv)
        staged = os.path.join(self._room(), "attachments",
                              "kitchen-reference.png")
        self.assertTrue(os.path.isfile(staged), os.listdir(self._room()))
        prompt = self._prompts()[-1]
        self.assertIn(staged, prompt)
        self.assertIn("attached images", prompt)
        self.assertIn("Read tool", prompt)
        # and the file really is the bytes he pasted, not a placeholder
        with open(staged, "rb") as fh:
            self.assertEqual(fh.read(), base64.b64decode(_PNG_B64))

    def test_copilot_gets_a_native_attachment_flag_and_a_clean_prompt(self):
        """copilot's holodeck turn runs on a fixed `--available-tools` list with
        no file viewer on it, so the image MUST ride natively — a path in the
        prompt would name a file it cannot open."""
        sid = self._start(engine=self.copilot_bin)
        status, _body = self._post("/api/holodeck/%s/say" % sid,
                                   {"text": "like this",
                                    "images": [self._img()]})
        self.assertEqual(status, 200)
        argv = self._calls()[-1]["argv"]
        staged = os.path.join(self._room(), "attachments",
                              "kitchen-reference.png")
        self.assertIn("--attachment", argv)
        self.assertEqual(argv[argv.index("--attachment") + 1], staged)
        self.assertNotIn(staged, self._prompts()[-1])

    def test_two_pastes_ride_as_two_repeated_flags_in_paste_order(self):
        sid = self._start(engine=self.copilot_bin)
        self._post("/api/holodeck/%s/say" % sid,
                   {"text": "these two",
                    "images": [self._img("a.png"), self._img("b.png")]})
        argv = self._calls()[-1]["argv"]
        got = [argv[i + 1] for i, a in enumerate(argv) if a == "--attachment"]
        self.assertEqual([os.path.basename(p) for p in got],
                         ["a.png", "b.png"])

    def test_the_image_lands_in_the_PROGRAM_ROOM_not_the_scratch_dir(self):
        """A holodeck program IS the archive — there is no mission to copy a
        durable attachment into — so the reference a mockup was designed from
        lives beside the mockup, in the room, where the room's own per-turn
        commit sweeps it up."""
        sid = self._start()
        self._post("/api/holodeck/%s/say" % sid,
                   {"text": "this", "images": [self._img()]})
        staged = os.path.join(self._room(), "attachments",
                              "kitchen-reference.png")
        self.assertTrue(os.path.isfile(staged))
        scratch = os.path.join(self.repo, ".git", "lcars", "tmp")
        strays = [f for f in (os.listdir(scratch)
                              if os.path.isdir(scratch) else [])
                  if f.startswith("lcars-img-")]
        self.assertEqual(strays, [], "the holodeck staged into the grill's "
                                     "reap-on-exit scratch dir")

    def test_the_room_commit_carries_it_so_a_reopen_still_has_it(self):
        sid = self._start()
        self._post("/api/holodeck/%s/say" % sid,
                   {"text": "this", "images": [self._img()]})
        self._post("/api/holodeck/%s/end" % sid)
        tracked = subprocess.run(
            ["git", "ls-files"], cwd=self._sidecar(),
            stdout=subprocess.PIPE).stdout.decode()
        self.assertIn("nav-rail/attachments/kitchen-reference.png", tracked)
        # …and re-opening the room off disk finds it there
        status, _ = self._post("/api/holodeck/open", {"room": "nav-rail"})
        self.assertEqual(status, 200)
        self.assertTrue(os.path.isfile(
            os.path.join(self._room(), "attachments",
                         "kitchen-reference.png")))

    def test_it_is_NOT_reported_back_as_a_file_the_worker_wrote(self):
        """The paste is staged BEFORE the turn's audit snapshot on purpose. A
        captain's own screenshot appearing in `filesChanged` would read as the
        model having written it, which is the authorship lie the whole audit
        exists to avoid."""
        sid = self._start()
        _, body = self._post("/api/holodeck/%s/say" % sid,
                             {"text": "this", "images": [self._img()]})
        paths = [f["path"] for f in body["state"]["filesChanged"]]
        self.assertEqual([p for p in paths if "attachments" in p], [])

    def test_a_hostile_filename_cannot_leave_the_room(self):
        sid = self._start()
        self._post("/api/holodeck/%s/say" % sid,
                   {"text": "this",
                    "images": [self._img(name="../../../etc/passwd.png")]})
        room = os.path.realpath(self._room())
        got = os.listdir(os.path.join(room, "attachments"))
        self.assertEqual(got, ["passwd.png"], got)

    def test_a_second_paste_of_the_same_name_does_not_overwrite_the_first(self):
        """A room is REOPENED. Two `Screenshot.png`s a week apart are two
        different references, and the mockup was designed from the first."""
        sid = self._start()
        for _ in range(2):
            self._post("/api/holodeck/%s/say" % sid,
                       {"text": "this", "images": [self._img("shot.png")]})
        got = sorted(os.listdir(os.path.join(self._room(), "attachments")))
        self.assertEqual(got, ["shot-2.png", "shot.png"])

    def test_a_turn_with_no_image_is_BYTE_IDENTICAL_to_before(self):
        """The regression guard. No image ⇒ no flag, no prompt text, no
        attachments directory created at all."""
        sid = self._start()
        self._post("/api/holodeck/%s/say" % sid, {"text": "plain words"})
        argv = self._calls()[-1]["argv"]
        self.assertNotIn("--attachment", argv)
        self.assertNotIn("attached", self._prompts()[-1])
        self.assertFalse(os.path.isdir(os.path.join(self._room(),
                                                    "attachments")))

    def test_a_paste_that_is_not_base64_is_refused_in_plain_english(self):
        sid = self._start()
        status, body = self._post_raw(
            "/api/holodeck/%s/say" % sid,
            {"text": "this", "images": [{"name": "x.png", "type": "image/png",
                                         "dataB64": "not base64!!"}]})
        self.assertEqual(status, 400)
        self.assertIn("base64", body["error"])
        # and the turn never ran, so the program is not left claimed
        status, _ = self._post("/api/holodeck/%s/say" % sid, {"text": "again"})
        self.assertEqual(status, 200)

    def test_a_SENT_program_still_refuses_the_turn_before_any_image_is_written(self):
        """The D11 lock is checked before the claim and before staging: a
        locked program must not have a file written into its room."""
        sid = self._start()
        self._post("/api/holodeck/%s/say" % sid, {"text": "draft"})
        # the lock is read off the record's HEADER (`_parse_sent`), so the line
        # goes where a real hand-off puts it.
        path = os.path.join(self._room(), "transcript.md")
        with open(path) as fh:
            text = fh.read()
        head, sep, rest = text.partition("\n## ")
        with open(path, "w") as fh:
            fh.write(head + "\n\n_Sent to Align: mission `m-009` at "
                     "2026-08-06T09:00:00Z_ — handed over.\n" + sep + rest)
        status, _body = self._post_raw("/api/holodeck/%s/say" % sid,
                                       {"text": "more",
                                        "images": [self._img("late.png")]})
        self.assertEqual(status, 409)
        attach = os.path.join(self._room(), "attachments")
        self.assertFalse(os.path.isdir(attach) and os.listdir(attach))

    def test_the_bash_guard_still_holds_with_an_attachment_on_the_argv(self):
        sid = self._start(engine=self.copilot_bin)
        self._post("/api/holodeck/%s/say" % sid,
                   {"text": "this", "images": [self._img()]})
        argv = self._calls()[-1]["argv"]
        self.assertFalse([a for a in argv if re.search(r"\bbash\b", a, re.I)],
                         argv)


# ════════════════════════════════════════════════════════════════════════════
# S169 FIX ROUND 1 — ONE BAD PASTE BRICKED A PROGRAM FOREVER
#
# THE DEFECT, shipped by the FL-014 work directly above and found by the tester
# on 2026-08-06. He pasted a 78-byte PNG; copilot's API answered `CAPIError: 400
# Could not process image`; and because a holodeck turn `--resume`s a warm
# session, that image stayed IN the conversation. Every later turn died
# identically — WITH NO ATTACHMENT AT ALL. The program was permanently dead
# under a banner advising "say it again to retry", which could never work, and
# the only escape was deleting the program.
#
# REPRODUCED BY HAND AGAINST LIVE COPILOT while curing it (free engine, guard
# shim on PATH, 2026-08-06):
#
#   1. a fresh session fed the tester's exact bytes  → `CAPIError: 400 Could
#      not process image`, exit 1;
#   2. `--resume`ing THAT session with a plain "Say OK." and NO attachment →
#      the identical 400. The session is poisoned, permanently;
#   3. an INTACT hand-built 2×2 PNG, and 4×4, 8×8, 16×16, 32×32 → all fine.
#      So it is NOT a size threshold, and a size floor would have been an
#      invented number the measurement had already falsified.
#
# `web/tests/fixtures/s169-drive/poisoned-paste.png` is the tester's exact file.
# It is a CORRUPT PNG: its one `IDAT` chunk fails its own CRC32 and its zlib
# stream is truncated. That is what the cure checks — the format's own integrity
# rule, not a threshold and not a classifier.
#
# THREE THINGS ARE CURED HERE, and they are three because the defect had three
# separate failures stacked on it:
#   PREVENTION — a damaged image never reaches a session (`_image_defect`, in
#       `_decode_image`, which is the ONE door every paste road already used).
#   RECOVERY   — a session an attachment may have poisoned is RE-MINTED, using
#       S126's existing warm-restart machinery (fresh id + `_replay_clause`
#       hands the new worker the whole transcript). Nothing new was built.
#   THE BANNER — it quoted `raw.splitlines()[-1]`, and copilot ALWAYS ends with
#       a fixed footer, so "It said:" was structurally guaranteed to print a
#       resume command and never the error. It now shows the TAIL and says that
#       is what it is, which needs no knowledge of any CLI's decoration.
# ════════════════════════════════════════════════════════════════════════════
_POISON_PNG = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                           "fixtures", "s169-drive", "poisoned-paste.png")


class PoisonedPasteTest(HolodeckBase):
    """The tester's exact bytes, against the shipping paste road."""

    @classmethod
    def setUpClass(cls):
        super(PoisonedPasteTest, cls).setUpClass()
        with open(_POISON_PNG, "rb") as fh:
            cls.POISON = fh.read()
        cls.POISON_B64 = base64.b64encode(cls.POISON).decode("ascii")

    def _start(self, engine=None, program="Trip board"):
        _, body = self._post("/api/holodeck/start",
                             {"program": program,
                              "engine": engine or self.copilot_bin})
        return body["state"]["sessionId"]

    def _room(self, program="trip-board"):
        return os.path.realpath(os.path.join(self._sidecar(), program))

    def _state(self, sid):
        url = "http://127.0.0.1:%d/api/holodeck/%s" % (self.port, sid)
        with urllib.request.urlopen(url, timeout=20) as r:
            return json.loads(r.read())

    # ── the evidence ────────────────────────────────────────────────────────
    def test_the_fixture_is_the_testers_file_and_it_really_is_CORRUPT(self):
        """Pin what every claim below turns on. It is a 2×2 PNG whose picture
        data fails the checksum the format carries for exactly this purpose."""
        from lcars_serve.actions import _image_defect
        self.assertEqual(len(self.POISON), 78)
        self.assertEqual(self.POISON[:8], b"\x89PNG\r\n\x1a\n")
        self.assertIn("checksum", _image_defect(self.POISON))

    def test_an_INTACT_tiny_png_is_NOT_refused(self):
        """The measurement that keeps this from becoming a size floor: live
        copilot took an intact 2×2 without complaint, twice. Refusing small
        images would be an invented threshold — and a wrong one."""
        from lcars_serve.actions import _image_defect
        self.assertEqual(_image_defect(base64.b64decode(_PNG_B64)), "")

    def test_an_UNRECOGNISED_format_is_left_alone_not_refused(self):
        """The surface must not claim knowledge it does not have. A format this
        cannot parse is not judged."""
        from lcars_serve.actions import _image_defect
        self.assertEqual(_image_defect(b"\x00\x01not-a-known-container"), "")

    def test_the_OTHER_THREE_FORMATS_are_checked_too_and_are_not_decoration(self):
        """The composer's allow-list is PNG/JPEG/GIF/WEBP. A check that only
        really looked at PNG would be three quarters decoration, and the first
        `.jpg` paste would walk straight past it. Each arm is the format's own
        completeness rule: a JPEG ends with its EOI marker, a GIF with its
        trailer, a WEBP holds the byte count its RIFF header declares."""
        from lcars_serve.actions import _image_defect
        self.assertIn("JPEG", _image_defect(b"\xff\xd8\xff\xe0" + b"\x00" * 40))
        self.assertIn("GIF", _image_defect(b"GIF89a" + b"\x00" * 20))
        self.assertEqual(_image_defect(b"GIF89a" + b"\x00" * 20 + b"\x3b"), "")
        webp = b"RIFF" + struct.pack("<I", 5000) + b"WEBP" + b"\x00" * 10
        self.assertIn("WEBP", _image_defect(webp))
        self.assertEqual(_image_defect(b"\xff\xd8\xff\xe0" + b"\x00" * 40
                                       + b"\xff\xd9"), "")

    def test_a_ZERO_BYTE_paste_is_named_rather_than_written_out(self):
        from lcars_serve.actions import _image_defect
        self.assertIn("empty", _image_defect(b""))

    # ── PREVENTION ──────────────────────────────────────────────────────────
    def test_a_damaged_paste_is_refused_in_plain_english_before_anything_runs(self):
        sid = self._start()
        status, body = self._post_raw(
            "/api/holodeck/%s/say" % sid,
            {"text": "make it look like this",
             "images": [{"name": "shot.png", "type": "image/png",
                         "dataB64": self.POISON_B64}]})
        self.assertEqual(status, 400, body)
        msg = body["error"]
        self.assertIn("shot.png", msg)
        self.assertIn("damaged", msg)
        # plain English: no stack trace, no CRC hex, and it says what to DO.
        self.assertNotIn("Traceback", msg)
        self.assertRegex(msg.lower(), r"take the screenshot again|drag")

    def test_the_refused_paste_reaches_NO_ENGINE_and_NO_ROOM(self):
        """The whole point of catching it here: nothing spawned, nothing on
        disk, and above all nothing in the warm session."""
        sid = self._start()
        before = len(self._calls())
        self._post_raw("/api/holodeck/%s/say" % sid,
                       {"text": "this",
                        "images": [{"name": "shot.png", "type": "image/png",
                                    "dataB64": self.POISON_B64}]})
        self.assertEqual(len(self._calls()), before)
        attach = os.path.join(self._room(), "attachments")
        self.assertFalse(os.path.isdir(attach) and os.listdir(attach))

    def test_the_program_is_still_usable_after_a_refused_paste(self):
        """A refusal is not a brick. The claim is released and the very next
        turn works."""
        sid = self._start()
        self._post_raw("/api/holodeck/%s/say" % sid,
                       {"text": "this",
                        "images": [{"name": "shot.png", "type": "image/png",
                                    "dataB64": self.POISON_B64}]})
        status, _ = self._post("/api/holodeck/%s/say" % sid,
                               {"text": "just words then"})
        self.assertEqual(status, 200)

    def test_EVERY_paste_road_is_guarded_not_just_the_holodeck(self):
        """The check lives in `_decode_image`, the one door all three roads
        already came through — the Align grill and the Mission Log get it for
        free, and the defect cannot come back through an unguarded one."""
        from lcars_serve.actions import Actions
        import inspect
        src = inspect.getsource(Actions._decode_image)
        self.assertIn("_image_defect", src)

    # ── RECOVERY ────────────────────────────────────────────────────────────
    def _fail_next_turn(self):
        self._set_turns({"stdout": "Execution failed: CAPIError: 400 Could not "
                                   "process image (Request ID: F68E:80C6D)\n"
                                   "\n\nChanges    +0 -0\n"
                                   "AI Credits 0 (7s)\n"
                                   "Resume     copilot --resume=796ade4f",
                         "exit": 1})

    def test_a_failed_ATTACHMENT_turn_RE_MINTS_the_warm_session(self):
        """The recovery. A poisoned session can never be resumed back to life,
        so the next turn must open a FRESH one — S126's warm-restart machinery,
        turned on in place rather than rebuilt."""
        sid = self._start()
        self._set_turns({"stdout": "opened"})
        self._post("/api/holodeck/%s/say" % sid, {"text": "hello"})
        state = self._state(sid)
        self.assertTrue(state["warm"], state)
        self._fail_next_turn()
        status, body = self._post_raw(
            "/api/holodeck/%s/say" % sid,
            {"text": "like this", "images": [{"name": "ok.png",
                                              "type": "image/png",
                                              "dataB64": _PNG_B64}]})
        self.assertEqual(status, 502, body)
        # the session is no longer warm — the next turn OPENS one.
        state = self._state(sid)
        self.assertFalse(state["warm"], state)

    def test_the_fresh_session_is_handed_the_WHOLE_TRANSCRIPT(self):
        """Recovery that forgot the conversation would not be recovery. The
        replay is S126's, reached by the same `restarted` flag `holodeck_open`
        sets — no second code path."""
        sid = self._start()
        self._set_turns({"stdout": "opened"})
        self._post("/api/holodeck/%s/say" % sid,
                   {"text": "a dark trip board please"})
        self._fail_next_turn()
        self._post_raw("/api/holodeck/%s/say" % sid,
                       {"text": "like this",
                        "images": [{"name": "ok.png", "type": "image/png",
                                    "dataB64": _PNG_B64}]})
        self._set_turns({"stdout": "back"})
        self._post("/api/holodeck/%s/say" % sid, {"text": "carry on"})
        prompt = self._prompts()[-1]
        self.assertIn("picking this program back up", prompt)
        self.assertIn("you are a FRESH session", prompt)
        self.assertIn("a dark trip board please", prompt)

    def test_the_banner_SAYS_the_session_was_reset_and_what_to_do(self):
        sid = self._start()
        self._set_turns({"stdout": "opened"})
        self._post("/api/holodeck/%s/say" % sid, {"text": "hello"})
        self._fail_next_turn()
        _st, body = self._post_raw(
            "/api/holodeck/%s/say" % sid,
            {"text": "like this", "images": [{"name": "ok.png",
                                              "type": "image/png",
                                              "dataB64": _PNG_B64}]})
        msg = body["error"]
        self.assertIn("ok.png", msg)
        self.assertIn("fresh", msg.lower())
        self.assertIn("transcript", msg.lower())
        # the advice that could NEVER work is gone from this branch.
        self.assertNotIn("say it again to retry", msg)
        # …and the FACT rides beside the sentence, so the page never has to
        # read the wording to decide what to do with the attachment.
        self.assertTrue(body.get("sessionReset"), body)

    def test_a_failed_turn_with_NO_attachment_keeps_its_warm_session(self):
        """The regression guard on the trigger. Re-minting on every failure
        would throw away a warm session — and pay for a full replay — every
        time a network blip drops a turn. The trigger is a FACT off this turn's
        argv: did it carry an attachment."""
        sid = self._start()
        self._set_turns({"stdout": "opened"})
        self._post("/api/holodeck/%s/say" % sid, {"text": "hello"})
        self._fail_next_turn()
        _st, body = self._post_raw("/api/holodeck/%s/say" % sid,
                                   {"text": "no picture here"})
        state = self._state(sid)
        self.assertTrue(state["warm"], state)
        self.assertFalse(body.get("sessionReset"), body)

    # ── THE BANNER QUOTES THE REAL ERROR ────────────────────────────────────
    def test_the_banner_carries_the_ERROR_not_the_resume_command(self):
        """THE HEADLINE of this half. The tail below is a live copilot failure,
        verbatim: the reason is four non-empty lines above a fixed footer, and
        `splitlines()[-1]` could never once have reached it."""
        sid = self._start()
        self._set_turns({"stdout": "opened"})
        self._post("/api/holodeck/%s/say" % sid, {"text": "hello"})
        self._fail_next_turn()
        _st, body = self._post_raw("/api/holodeck/%s/say" % sid,
                                   {"text": "and now"})
        msg = body["error"]
        self.assertIn("CAPIError: 400 Could not process image", msg)
        self.assertIn("The last thing it printed", msg)
        # …and it never claims to have identified the error.
        self.assertNotIn("It said:", msg)

    def test_the_tail_rule_knows_NOTHING_about_any_CLI(self):
        """The road not taken, pinned. Matching copilot's "Changes"/"AI
        Credits"/"Resume" footer is a per-engine corpus that goes stale the
        moment a CLI reflows it — S126 already lost a captured fixture that
        way. The rule is "show the last few lines and say so"."""
        from lcars_serve.actions import _engine_tail
        import inspect
        src = inspect.getsource(_engine_tail)
        for cli_word in ("copilot", "claude", "AI Credits", "Resume"):
            self.assertNotIn(cli_word, src, cli_word)
        # it drops blank padding, keeps order, and is bounded.
        self.assertEqual(_engine_tail("a\n\n\nb\nc\n\n", lines=2), "b\nc")
        self.assertEqual(_engine_tail("", lines=4), "")
        big = "\n".join("line%d" % i for i in range(400))
        self.assertLessEqual(len(_engine_tail(big)), 900)


# ════════════════════════════════════════════════════════════════════════════
# S169 FIX ROUND 1 — THE RECORD NAMES WHAT HE ATTACHED
#
# Found on the same drive. He pasted a sketch and said "This sketch is the look
# I want"; the turn worked; and after a reload the reopened chat showed no chip
# and `transcript.md` — the program's PERMANENT record, the thing a later
# session is handed — never mentioned an image at all. A future session reads
# his sentence pointing at nothing.
#
# It is the same information-loss class as the rest of this round, inside this
# session's own new feature, and it is a MATCHED PAIR: `_transcript_entry`
# writes the line, `_parse_transcript` reads it back, and `_turns_payload` is
# the one projection every consumer sees.
# ════════════════════════════════════════════════════════════════════════════
class AttachmentIsInTheRecordTest(HolodeckBase):
    def _start(self, program="Paste probe"):
        _, body = self._post("/api/holodeck/start",
                             {"program": program, "engine": self.copilot_bin})
        return body["state"]["sessionId"]

    def _room(self, program="paste-probe"):
        return os.path.realpath(os.path.join(self._sidecar(), program))

    def _state(self, sid):
        url = "http://127.0.0.1:%d/api/holodeck/%s" % (self.port, sid)
        with urllib.request.urlopen(url, timeout=20) as r:
            return json.loads(r.read())

    def _say_with_image(self, sid, name="sketch.png"):
        self._set_turns({"stdout": "Here is what I see in the sketch."})
        return self._post("/api/holodeck/%s/say" % sid,
                          {"text": "This sketch is the look I want.",
                           "images": [{"name": name, "type": "image/png",
                                       "dataB64": _PNG_B64}]})

    def test_the_TURN_PAYLOAD_names_it(self):
        sid = self._start()
        self._say_with_image(sid)
        turns = self._state(sid)["turns"]
        self.assertEqual(turns[-1].get("attachments"), ["sketch.png"])

    def test_TRANSCRIPT_MD_names_it(self):
        """The durable half. This file is replayed into the next worker and
        handed to Align, so an image it never mentions is an image the next
        session does not know existed."""
        sid = self._start()
        self._say_with_image(sid)
        with open(os.path.join(self._room(), "transcript.md")) as fh:
            text = fh.read()
        self.assertIn("_Attached this turn: sketch.png_", text)
        self.assertIn("This sketch is the look I want.", text)

    def test_a_REOPENED_program_still_names_it(self):
        """The measurement was taken after a reload. The record is the only
        thing that survives, so the chip has to come back out of it."""
        sid = self._start()
        self._say_with_image(sid)
        self._post("/api/holodeck/%s/end" % sid)
        _st, body = self._post("/api/holodeck/open", {"room": "paste-probe"})
        turns = body["state"]["turns"]
        self.assertEqual(turns[-1].get("attachments"), ["sketch.png"])
        # …and his words are still HIS — the new line must not be absorbed into
        # what he said (which is why it sits above it, not below).
        self.assertEqual(turns[-1]["text"], "This sketch is the look I want.")

    def test_a_turn_with_NO_image_carries_no_key_at_all(self):
        """Additive: every payload every earlier test pins stays byte-identical
        on the road that has no attachment."""
        sid = self._start()
        self._set_turns({"stdout": "ok"})
        self._post("/api/holodeck/%s/say" % sid, {"text": "plain words"})
        turns = self._state(sid)["turns"]
        self.assertNotIn("attachments", turns[-1])
        with open(os.path.join(self._room(), "transcript.md")) as fh:
            self.assertNotIn("_Attached this turn:", fh.read())


# ════════════════════════════════════════════════════════════════════════════
# S169 FIX ROUND 1 — TWO SURFACES, ONE PRODUCT
#
# The New Program dialog disabled its "A screenshot" road with "⚠ Not yet: the
# holodeck cannot take pasted images yet, so this would fail the moment you
# clicked Run" — while the composer four inches away invites "paste a
# screenshot" and works. That copy was made stale BY THIS SESSION. The START
# road genuinely is not built (there is no turn to attach to), so the refusal
# survives; what changes is that it stops denying the feature and names where
# the road actually is.
# ════════════════════════════════════════════════════════════════════════════
class StartFromImageRefusalIsHonestTest(HolodeckBase):
    def test_the_daemon_still_REFUSES_a_start_carrying_an_image(self):
        status, body = self._post_raw(
            "/api/holodeck/start",
            {"program": "P", "engine": self.copilot_bin,
             "images": [{"name": "a.png", "type": "image/png",
                         "dataB64": _PNG_B64}]})
        self.assertEqual(status, 400, body)

    def test_but_it_no_longer_says_the_holodeck_cannot_take_images(self):
        _st, body = self._post_raw(
            "/api/holodeck/start",
            {"program": "P", "engine": self.copilot_bin,
             "images": [{"name": "a.png", "type": "image/png",
                         "dataB64": _PNG_B64}]})
        msg = body["error"]
        self.assertNotIn("cannot take pasted images", msg)
        # it points at the road that WORKS, by name.
        self.assertIn("chat", msg.lower())
        self.assertRegex(msg.lower(), r"paste .*first turn|composer")


# ════════════════════════════════════════════════════════════════════════════
# S169 (FL-015) — YOU CAN ASK THE HOLODECK SOMETHING
#
# The captain, on the S128 drive: *"I asked it what is it mean by the events tab
# and it's doing a long 'rendering to holodeck' turn."* And, sharpening it: *"To
# be clear it answered my question, but also spent a lot of time on the events
# tab. Would be better to answer and let me guide then waste time on a render
# update."* So the answer was not suppressed — the mockup MOVED on a turn he had
# not directed, which is unrequested design drift into the artifact that becomes
# an acceptance criterion for real work.
#
# WHAT A STUB CAN AND CANNOT PROVE, said plainly. Whether a worker actually
# answers-then-stops is a MODEL choice, and no stub on this PATH can stand in
# for it — the live leg does that. What is proven here is the two things a unit
# test genuinely owns:
#
#   1. THE PROMPT CONTENT. Every design turn — opening envelope and continuation
#      alike — is handed the answer-then-stop rule, and a turn the captain
#      DECLARED a question is handed a flat instruction to write nothing. The
#      recording stub captures the whole `-p` prompt, so the live leg can diff
#      what a real worker was handed against exactly these strings.
#   2. THE OBSERVABLE OUTCOME. "He asked, and nothing was written" is published
#      by the daemon off the audit it already runs, and so is "he asked, and it
#      wrote anyway" — the shape that would have caught this on the drive.
#
# AND WHAT IS DELIBERATELY ABSENT: a classifier. There is a test below that
# holds that line explicitly, because it is the one cure this defect invites and
# the one this project has lost sessions to (S156: 14/14 → 5/14 on a reworded
# corpus).
# ════════════════════════════════════════════════════════════════════════════
def _flat(text):
    """The prompt with its line wrapping collapsed.

    The rule is authored as a wrapped paragraph, so a sentence like "Do not also
    make an improvement while you are in there" spans a newline in the real
    argv. Asserting the wrapped form would pin the wrapping rather than the
    words, and the next reflow would go red for nothing.
    """
    return " ".join(str(text).split())


class AskDoesNotBuildTest(HolodeckBase):
    def _start(self, engine=None, program="Nav rail"):
        _, body = self._post("/api/holodeck/start",
                             {"program": program,
                              "engine": engine or self.claude_bin})
        return body["state"]["sessionId"]

    # -- 1. the prompt --------------------------------------------------------
    def test_the_opening_envelope_carries_answer_then_stop(self):
        self._set_turns({"stdout": "Here it is."})
        sid = self._start()
        self._post("/api/holodeck/%s/say" % sid, {"text": "draft a nav rail"})
        prompt = _flat(self._prompts()[-1])
        self.assertIn("NOT EVERY TURN IS A BUILD TURN", prompt)
        self.assertIn("ANSWER HIM AND CHANGE NOTHING", prompt)
        # the exact thing that happened: it answered AND improved something.
        self.assertIn("Do not also make an improvement while you are in there",
                      prompt)
        # and the reply-length rule must stand down for an answer, or he gets a
        # diff summary where he wanted a sentence.
        self.assertIn("REPLY SHORT ON A BUILD TURN", prompt)
        self.assertIn("the short-reply rule does not apply to an answer",
                      prompt)

    def test_the_continuation_no_longer_orders_a_change_unconditionally(self):
        """The defect, in one line. Every follow-up turn used to open with
        `Make the change, then reply…` before the envelope was even considered.
        """
        self._set_turns({"stdout": "one"}, {"stdout": "two"})
        sid = self._start()
        self._post("/api/holodeck/%s/say" % sid, {"text": "draft it"})
        self._post("/api/holodeck/%s/say" % sid,
                   {"text": "what do you mean by the events tab?"})
        prompt = _flat(self._prompts()[-1])
        self.assertNotIn("Make the change, then reply", prompt)
        self.assertIn("NOT EVERY TURN IS A BUILD TURN", prompt)
        self.assertIn("If that is a direction, make the change", prompt)
        # his sentence still arrives verbatim — nothing rewrites what he said.
        self.assertIn("what do you mean by the events tab?", prompt)

    def test_a_declared_question_is_told_flatly_to_write_nothing(self):
        self._set_turns({"stdout": "one"}, {"stdout": "It groups events."})
        sid = self._start()
        self._post("/api/holodeck/%s/say" % sid, {"text": "draft it"})
        self._post("/api/holodeck/%s/say" % sid,
                   {"text": "what is the events tab?", "intent": "ask"})
        prompt = _flat(self._prompts()[-1])
        self.assertIn("THE CAPTAIN DECLARED THIS TURN A QUESTION", prompt)
        self.assertIn("ANSWER HIM AND CHANGE NOTHING", prompt)
        self.assertIn("do not write any file at all this turn", prompt)
        self.assertIn("there is no short-reply rule on this turn", prompt)

    def test_a_declared_question_on_the_OPENING_turn_gets_the_same_declaration(self):
        """The opening turn is reachable from the composer too — a program whose
        first turn died, or a warm restart. The declaration must not fall out of
        the envelope branch."""
        self._set_turns({"stdout": "It is the third pane."})
        sid = self._start()
        self._post("/api/holodeck/%s/say" % sid,
                   {"text": "what is in this room already?", "intent": "ask"})
        prompt = _flat(self._prompts()[-1])
        self.assertIn("THE CAPTAIN DECLARED THIS TURN A QUESTION", prompt)
        self.assertNotIn("NOT EVERY TURN IS A BUILD TURN", prompt)

    def test_an_unknown_or_absent_intent_degrades_to_the_default_branch(self):
        """The control is OPTIONAL by construction: he must never have to flip a
        switch to ask a question, or it becomes the thing he forgets and blames.
        Anything that is not the explicit declaration reads as `build`, whose
        prompt already carries answer-then-stop."""
        self._set_turns({"stdout": "a"}, {"stdout": "b"}, {"stdout": "c"})
        sid = self._start()
        self._post("/api/holodeck/%s/say" % sid, {"text": "draft it"})
        for body in ({"text": "x"}, {"text": "y", "intent": "QUESTION?"}):
            self._post("/api/holodeck/%s/say" % sid, body)
            prompt = _flat(self._prompts()[-1])
            self.assertIn("NOT EVERY TURN IS A BUILD TURN", prompt)
            self.assertNotIn("THE CAPTAIN DECLARED THIS TURN A QUESTION",
                             prompt)

    def test_the_grounding_pass_is_untouched(self):
        """A grounding turn has no write tool at all, so answer-then-stop is
        already the only thing it can do. Adding the clause there would be
        wording for wording's sake."""
        self._set_turns({"stdout": "# Design basis\n\nnothing found"})
        _, body = self._post("/api/holodeck/start",
                             {"program": "Tile picker", "mode": "grounding",
                              "engine": self.claude_bin})
        self.assertEqual(body["state"]["status"], "ok", body)
        prompt = _flat(self._prompts()[0])
        self.assertNotIn("NOT EVERY TURN IS A BUILD TURN", prompt)
        self.assertIn("You are READ-ONLY", prompt)

    def test_NOTHING_reads_his_sentence_to_decide_the_turn_shape(self):
        """THE TRAP, held open on purpose.

        Two sentences that mean the same thing, phrased as differently as a
        captain phrases things, sent with NO declaration. A classifier is a
        thing that would treat them differently; a declaration cannot. The
        prompts must be identical but for his own words."""
        self._set_turns(*[{"stdout": "ok"}] * 4)
        sid = self._start()
        self._post("/api/holodeck/%s/say" % sid, {"text": "draft it"})
        said = []
        for text in ("What do you mean by the events tab?",
                     "Curious about the reasoning behind that events tab.",
                     "Add a second row of swatches to the tile picker."):
            self._post("/api/holodeck/%s/say" % sid, {"text": text})
            said.append(self._prompts()[-1].replace(text, "<HIS SENTENCE>"))
        self.assertEqual(len(set(said)), 1,
                         "the prompt differs by more than the captain's own "
                         "words — something is reading his sentence")

    # -- 2. the observable outcome -------------------------------------------
    def test_a_turn_that_wrote_nothing_SAYS_SO(self):
        """The silence that hid the defect. A turn that changed no file was
        indistinguishable from one that quietly redesigned a tab until the
        captain opened the preview."""
        self._set_turns({"stdout": "The events tab groups the run's events."})
        sid = self._start()
        _, body = self._post("/api/holodeck/%s/say" % sid,
                             {"text": "what is the events tab?",
                              "intent": "ask"})
        oc = body["state"]["turnOutcome"]
        self.assertEqual(oc["intent"], "ask")
        self.assertFalse(oc["wrote"])
        self.assertEqual(oc["files"], [])
        self.assertIn("nothing was written", oc["message"].lower())

    def test_a_DECLARED_question_that_wrote_anyway_is_named_as_drift(self):
        """The defect itself, made visible. He declared a question; the turn
        wrote the mockup regardless. The daemon reads that off its own audit —
        it does not take the reply's word for it."""
        self._set_turns({"stdout": "Answered — and tidied the tab.",
                         "writes": [{"path": "mockup.html",
                                     "content": "<!doctype html>drift"}]})
        sid = self._start()
        _, body = self._post("/api/holodeck/%s/say" % sid,
                             {"text": "what is the events tab?",
                              "intent": "ask"})
        oc = body["state"]["turnOutcome"]
        self.assertEqual(oc["intent"], "ask")
        self.assertTrue(oc["wrote"])
        self.assertEqual(oc["files"], ["mockup.html"])
        self.assertIn("mockup.html", oc["message"])
        self.assertIn("a turn you did not direct", oc["message"])

    def test_an_ordinary_build_turn_that_wrote_says_nothing_extra(self):
        """The fact is always published; the SENTENCE is not. The chat already
        prints a file chip per file, and a note that speaks on every turn is a
        note people stop reading (the `conceptAudit` lesson)."""
        self._set_turns({"stdout": "Built it.",
                         "writes": [{"path": "mockup.html",
                                     "content": "<!doctype html>ok"}]})
        sid = self._start()
        _, body = self._post("/api/holodeck/%s/say" % sid,
                             {"text": "draft a nav rail"})
        oc = body["state"]["turnOutcome"]
        self.assertEqual(oc["intent"], "build")
        self.assertTrue(oc["wrote"])
        self.assertEqual(oc["message"], "")

    def test_the_outcome_names_only_THIS_program_s_files(self):
        """`changed` is a diff of the WHOLE sidecar, so a second program writing
        at the same moment lands in this turn's snapshot window. The outcome and
        the durable transcript line read the SAME rule (`_room_scoped_files`) —
        two copies is how they start disagreeing about one turn."""
        self._set_turns({"stdout": "one"},
                        {"stdout": "answering",
                         "writes": [{"path": "../tile-picker/mockup.html",
                                     "content": "someone else's work"}]})
        sid = self._start()
        self._post("/api/holodeck/%s/say" % sid, {"text": "draft it"})
        _, body = self._post("/api/holodeck/%s/say" % sid,
                             {"text": "what is the events tab?",
                              "intent": "ask"})
        oc = body["state"]["turnOutcome"]
        self.assertEqual(oc["files"], [], oc)
        self.assertFalse(oc["wrote"])

    def test_the_TURN_LIST_carries_the_outcome_so_a_refresh_restores_it(self):
        """FOUND BY THE CHROME RIG, 2026-08-06, and it is why this is here.

        `holoRefresh()` replaces the deck's whole program list with `GET
        /api/holodeck`, so anything the client merged onto a turn from the POST
        response survives exactly one render. The note read "nothing was
        written" for about a second and then vanished — a surface where whether
        the captain sees the fact depends on how fast his daemon answered is
        worse than one that never says it. The daemon owns the fact, so the
        daemon's list carries it."""
        self._set_turns({"stdout": "Answered."})
        sid = self._start()
        _, body = self._post("/api/holodeck/%s/say" % sid,
                             {"text": "what is the events tab?",
                              "intent": "ask"})
        self.assertFalse(body["state"]["turnOutcome"]["wrote"])
        url = "http://127.0.0.1:%d/api/holodeck" % self.port
        with urllib.request.urlopen(url, timeout=10) as r:
            listing = json.loads(r.read())
        prog = [p for p in listing["programs"] if p.get("sessionId") == sid][0]
        last = prog["turns"][-1]
        self.assertEqual(last["turnOutcome"]["intent"], "ask")
        self.assertIn("nothing was written", last["turnOutcome"]["message"])

    def test_a_turn_with_no_outcome_omits_the_key_entirely(self):
        """ADDITIVE BY CONSTRUCTION: a warm-restarted program's turns are
        replayed from `transcript.md`, which records no outcome, so every
        payload every earlier test pins is byte-identical."""
        self._set_turns({"stdout": "ok"})
        sid = self._start()
        url = "http://127.0.0.1:%d/api/holodeck" % self.port
        with urllib.request.urlopen(url, timeout=10) as r:
            listing = json.loads(r.read())
        prog = [p for p in listing["programs"] if p.get("sessionId") == sid][0]
        for t in prog["turns"]:
            self.assertNotIn("turnOutcome", t)

    def test_the_no_write_warning_keeps_the_only_voice_about_a_turn(self):
        """ONE VOICE PER TURN. A turn whose engine answered with the file's
        CONTENTS instead of writing it already has a better account of itself —
        it says WHY — so the outcome's sentence stands down beside it. The FACT
        stays on the payload."""
        self._set_turns({"stdout": "Save this yourself:\n\n```html\n"
                                   "<!doctype html>\n```\n"})
        sid = self._start()
        _, body = self._post("/api/holodeck/%s/say" % sid,
                             {"text": "draft a nav rail"})
        self.assertEqual(body["state"]["status"], "wrote-nothing")
        self.assertEqual(body["state"]["warning"]["kind"], "no-write")
        self.assertEqual(body["state"]["turnOutcome"]["message"], "")
        self.assertFalse(body["state"]["turnOutcome"]["wrote"])


# ════════════════════════════════════════════════════════════════════════════
# S169 (FL-015, second half) — THE WORKING COPY STOPS ASSERTING "RENDERING"
#
# The captain watched a long turn go by under a banner saying it was RENDERING,
# on a turn where he had asked a question. The daemon knows a turn is RUNNING;
# it knows nothing about what kind of turn it is until something has been
# written. That is `f667ce8`'s in-flight-fact discipline — the daemon publishes
# what is true, the client never invents a reason — applied to the one string
# that was still guessing.
# ════════════════════════════════════════════════════════════════════════════
class WorkingCopyIsHonestTest(unittest.TestCase):
    def test_the_daemon_s_busy_label_says_working_not_rendering(self):
        from lcars_serve.actions import _holodeck_busy_copy
        label, reason = _holodeck_busy_copy(215)
        self.assertIn("Still working", label)
        self.assertNotIn("rendering", label.lower())
        # the REASON is about the lock, not about what the turn is doing, and
        # was never a "rendering" claim — it must stay exactly as honest.
        self.assertIn("one turn at a time", reason)

    def test_the_board_band_does_not_claim_a_render_either(self):
        from lcars_serve.actions import _holodeck_working_message
        one = _holodeck_working_message([{"program": "Nav rail",
                                          "busyFor": 240}])
        self.assertNotIn("rendering", one.lower())
        self.assertIn("Nav rail", one)
        many = _holodeck_working_message([{"program": "Nav rail",
                                           "busyFor": 240},
                                          {"program": "Tile picker",
                                           "busyFor": 10}])
        self.assertNotIn("rendering", many.lower())
        self.assertIn("2 holodeck programs", many)


# ════════════════════════════════════════════════════════════════════════════
# S170 — THE CHANGE LIST IS A DIFF AGAINST THE REAL APP, NOT A TRANSCRIPT
#
# THE MEASUREMENT. The captain drove S169's output on his own program and read
# the brief back: *"The text it puts in is a lot of my ramble back and forth.
# It reads with things like when I asked it to draw the undo/redo buttons
# closer to how they are today. Or it says a bare x icon needs to say close,
# but the existing one says close and I just told the holodeck to fix its mock
# to add the close button back in instead of just an x."*
#
# `web/tests/fixtures/s170-tile-editor/` is the byte copy of that room. The
# root cause is one sentence: `## Decisions` IS A LOG OF THE CONVERSATION —
# THE PATH — NOT A DESCRIPTION OF THE END STATE. It faithfully records the
# turns where he was correcting THE MOCKUP, and downstream those corrections
# read as instructions to change the REAL APP. Four of its 21 bullets are
# mock-versus-mock; one of them ("Remove the Layer-properties panel that the T1
# mock added") is a NO-OP against his product, because that panel never existed
# in it and an implementer would hunt for something to delete.
#
# ── WHAT WAS BUILT ─────────────────────────────────────────────────────────
#
# S169's promote-time pass KEEPS its posture, its jail, its polling and its
# fail-safe behaviour, and CHANGES ITS JOB: it used to read a list back against
# the drawing and flag lines, and it now PRODUCES the list, by standing in the
# captain's repository and reporting the difference between the app as it
# actually is and the finished mockup. There is no second mechanism beside it.
#
# WHY THAT DELETES THE DEFECT CLASS WITHOUT A DETECTOR: a correction that
# restores today's behaviour produces NO LINE, because there is no difference
# to report. Both of the captain's examples vanish; nothing has to recognise
# them. S156 fell 14/14 → 5/14 on a reworded corpus, S147 lost four parser
# generations, S157 five guards — and none of that road is walked here.
#
# AND IT STILL CANNOT BE A GATE. A verification step that can block a hand-off
# is worse than the defect it cures. Every failure below ends the same way: he
# gets his brief, the band says plainly that the change list is not there, and
# ▦ FILE MISSION fires.
# ════════════════════════════════════════════════════════════════════════════
class HandoffDeriveParseTest(unittest.TestCase):
    """Reading the change list out of a reply. STRICT, and the strictness IS
    the fail-safe: anything this does not understand is not an answer."""

    def _p(self, reply):
        from lcars_serve.actions import _handoff_derive_parse
        return _handoff_derive_parse(reply)

    def test_it_reads_the_lines_after_the_marker_and_only_those(self):
        out = self._p("I opened the toolbar and read Toolbar.tsx.\n"
                      "today the toolbar is h-12\n"          # working out
                      "=== CHANGES ===\n"
                      "today the toolbar is 48px tall → the mockup makes it "
                      "52px\n"
                      "today there is no theme control → the mockup adds a "
                      "sun/moon icon button\n")
        self.assertEqual(out, [
            "today the toolbar is 48px tall → the mockup makes it 52px",
            "today there is no theme control → the mockup adds a sun/moon "
            "icon button"])

    def test_NO_MARKER_is_NO_ANSWER_and_never_the_working_out(self):
        """THE FAIL-SAFE THAT MATTERS MOST, and it is why this cannot reuse
        S169's fallback. S169's flagger could scan a whole reply because a
        stray line either matched `<n>|VERDICT|…` or did not. Here EVERY line
        is a candidate — so a reply with no marker would hand the captain a
        brief made of somebody thinking aloud."""
        self.assertIsNone(self._p(
            "I read the mockup and the app. The toolbar is taller, the theme "
            "is new, and the tabs are pills. Hope that helps!"))
        self.assertIsNone(self._p(""))
        self.assertIsNone(self._p(None))

    def test_an_EMPTY_block_is_a_real_answer_and_not_a_failure(self):
        """"Nothing differs" is a thing a pass can honestly return. It is
        vanishingly unlikely on a real program and the SURFACE says so loudly
        — but the parser must not turn it into an unusable reply, because that
        would report a failure that did not happen."""
        self.assertEqual(self._p("looked at everything\n=== CHANGES ===\n"), [])
        self.assertEqual(self._p("=== CHANGES ===\n\n   \n"), [])

    def test_it_survives_the_decoration_a_model_actually_adds(self):
        out = self._p("=== CHANGES ===\n"
                      "- today the tabs are square → the mockup uses pills\n"
                      "* today the rail is flat → the mockup groups it\n"
                      "1. today there is no brand → the mockup adds one\n"
                      "  • today the radius is 4px → the mockup uses 6px\n")
        self.assertEqual(len(out), 4, out)
        self.assertTrue(all(c.startswith("today ") for c in out), out)

    def test_headings_fences_and_rules_are_NOT_changes(self):
        out = self._p("=== CHANGES ===\n"
                      "```\n"
                      "## Toolbar\n"
                      "---\n"
                      "===\n"
                      "today the tabs are square → the mockup uses pills\n")
        self.assertEqual(out,
                         ["today the tabs are square → the mockup uses pills"])

    def test_the_LAST_marker_wins_so_a_quoted_one_cannot_open_the_block(self):
        out = self._p("I will end with === CHANGES === as asked.\n"
                      "here is my working out, which is not a change\n"
                      "=== CHANGES ===\n"
                      "today the tabs are square → the mockup uses pills\n")
        self.assertEqual(out,
                         ["today the tabs are square → the mockup uses pills"])

    def test_a_line_is_BOUNDED_and_so_is_the_list(self):
        from lcars_serve.actions import (_HANDOFF_DERIVE_MAX_LINE,
                                         _HANDOFF_DERIVE_MAX_CHANGES)
        out = self._p("=== CHANGES ===\n" + "today x → y " + ("z" * 5000))
        self.assertEqual(len(out[0]), _HANDOFF_DERIVE_MAX_LINE)
        many = self._p("=== CHANGES ===\n"
                       + "\n".join("today %d → y" % i for i in range(200)))
        self.assertEqual(len(many), _HANDOFF_DERIVE_MAX_CHANGES)

    def test_a_multi_line_reply_is_JOINED_per_line_not_per_paragraph(self):
        """One line is one change. A model that wraps its own line would
        produce two, and that is a shape the prompt forbids rather than
        something this guesses at — pinned so nobody adds a re-joiner that
        guesses at sentence boundaries."""
        out = self._p("=== CHANGES ===\n"
                      "today   the tabs    are square\n")
        self.assertEqual(out, ["today the tabs are square"])


# ════════════════════════════════════════════════════════════════════════════
# S172 — WHAT THE PASS FOUND AND DECLARED IT WAS NOT REPORTING
#
# THE CAPTAIN, driving S171 on his own room: his mockup adds zoom / fit buttons
# and a hover x/y pill OVER the canvas; his out-of-scope bucket says "the tile
# canvas rendering — left as an untouched placeholder well"; the pass suppressed
# the chrome along with the canvas and NEITHER REACHED THE CHANGE LIST.
#
# He ruled the suppression FAIR — *"to be fair, I did say don't touch the
# canvas"* — and asked for the other thing: *"Let's bank that as a question it
# should have asked me in the send to align dialog."*
#
# So the pass DECLARES its own suppressions, exactly as the planner declares
# `changesScreenAppearance`. Nothing below reads a line and decides anything
# about it; the marker is the whole mechanism, which is the one shape that has
# worked here every time.
# ════════════════════════════════════════════════════════════════════════════
class HandoffDeriveAskParseTest(unittest.TestCase):
    """Reading the DECLARED questions out of the same reply."""

    def _a(self, reply):
        from lcars_serve.actions import _handoff_derive_asks
        return _handoff_derive_asks(reply)

    def _c(self, reply):
        from lcars_serve.actions import _handoff_derive_parse
        return _handoff_derive_parse(reply)

    REPLY = ("I read the canvas overlay and MapCanvas.tsx.\n"
             "=== ASK ===\n"
             "- the mockup adds zoom / fit buttons over the canvas — in or "
             "out?\n"
             "- the mockup shows a hover x/y pill over the canvas — in or "
             "out?\n"
             "=== CHANGES ===\n"
             "- today the toolbar is 48px tall → the mockup makes it 52px\n")

    def test_the_two_blocks_are_read_APART(self):
        """THE ACCEPTANCE PAIR, in one assertion: the questions come back AND
        the change list does not assert them as changes."""
        self.assertEqual(self._a(self.REPLY), [
            "the mockup adds zoom / fit buttons over the canvas — in or out?",
            "the mockup shows a hover x/y pill over the canvas — in or out?"])
        self.assertEqual(self._c(self.REPLY), [
            "today the toolbar is 48px tall → the mockup makes it 52px"])

    def test_NO_ASK_MARKER_IS_SILENCE_and_never_an_unusable_reply(self):
        """The asymmetry with the change block, and it is deliberate: a reply
        with no change marker is UNUSABLE (`None`); a reply with no ask marker
        declared nothing, which is the ordinary answer and is also what every
        reply written before this block existed says."""
        self.assertEqual(self._a("=== CHANGES ===\ntoday a → b"), [])
        self.assertEqual(self._a(""), [])
        self.assertEqual(self._a(None), [])

    def test_an_EMPTY_ask_block_is_the_SAME_as_none(self):
        r = "=== ASK ===\n=== CHANGES ===\ntoday a → b"
        self.assertEqual(self._a(r), [])
        self.assertEqual(self._c(r), ["today a → b"])

    def test_the_CHANGE_BLOCK_IS_STILL_TERMINAL_and_that_is_the_failsafe(self):
        """The one property every fail-safe on this road hangs on: everything
        after the LAST change marker is the answer. A second block was not
        allowed to weaken it — so the ask block is read BETWEEN its own marker
        and the change marker, and a stray ask marker inside the working out
        cannot swallow the change list."""
        r = ("I will write === ASK === at the end as instructed.\n"
             "=== ASK ===\n"
             "the mockup adds a status bar over the canvas — in or out?\n"
             "=== CHANGES ===\n"
             "today the tabs are square → the mockup uses pills\n")
        self.assertEqual(self._c(r),
                         ["today the tabs are square → the mockup uses pills"])
        self.assertEqual(self._a(r), [
            "the mockup adds a status bar over the canvas — in or out?"])

    def test_the_QUESTIONS_ARE_BOUNDED_HARDER_THAN_THE_CHANGES(self):
        """A pass that hands back thirty questions has handed the work back to
        him, which is the failure the holodeck exists to prevent."""
        from lcars_serve.actions import _HANDOFF_DERIVE_MAX_ASKS
        r = ("=== ASK ===\n"
             + "\n".join("is thing %d in or out?" % i for i in range(50))
             + "\n=== CHANGES ===\ntoday a → b\n")
        self.assertEqual(len(self._a(r)), _HANDOFF_DERIVE_MAX_ASKS)
        self.assertLess(_HANDOFF_DERIVE_MAX_ASKS, 40)

    def test_it_survives_the_same_decoration_the_change_block_does(self):
        r = ("=== ASK ===\n"
             "```\n## Canvas\n---\n"
             "1. is the zoom row in or out?\n"
             "  • is the hover pill in or out?\n"
             "=== CHANGES ===\ntoday a → b\n")
        self.assertEqual(self._a(r), ["is the zoom row in or out?",
                                      "is the hover pill in or out?"])


class HandoffDerivePromptTest(unittest.TestCase):
    """The prompt is the whole mechanism, so it is pinned like one."""

    def _p(self):
        from lcars_serve.actions import _handoff_derive_prompt
        return _handoff_derive_prompt("/room/mockup.html", "/room/concept.md",
                                      "/room/basis.md")

    def test_it_names_the_files_by_ABSOLUTE_PATH(self):
        """The cwd is the CAPTAIN'S REPO. A bare `mockup.html` would resolve to
        nothing — or, worse, to a same-named file in his project."""
        p = self._p()
        self.assertIn("/room/mockup.html", p)
        self.assertIn("/room/concept.md", p)
        self.assertIn("/room/basis.md", p)

    def test_it_says_the_WORKING_DIRECTORY_IS_THE_REAL_APP(self):
        self.assertIn("YOUR WORKING DIRECTORY IS THE REAL APPLICATION",
                      self._p())

    def test_the_CODE_outranks_basis_md(self):
        """S169 rejected the derivation road because `basis.md` is a prose
        summary and reading it means guessing at meaning. It was right — so
        `basis.md` is context and the repo is the authority, said in the
        prompt where the pass can act on it."""
        p = self._p()
        self.assertIn("THE CODE WINS", p)
        self.assertIn("may be stale", p)

    def test_it_pins_the_IMPLEMENTATION_BAN(self):
        """THE TRAP. A mockup is a FICTION — fake data, invented internals, no
        real state — and the app is an implementation. Without this the pass
        reports "the app has no renderStops()" and "the mock uses inline CSS
        and the app uses Tailwind" as changes.

        S171 WIDENED THE PASS TO BEHAVIOUR AND THIS BAN DID NOT MOVE. It is
        the reason the widening is safe: what a thing DOES and what it is
        CONNECTED TO is in, HOW IT IS BUILT is out — including, now, how
        behaviour is built."""
        p = self._p()
        self.assertIn("NEVER REPORT IMPLEMENTATION", p)
        for banned in ("frameworks", "build tools", "selector names",
                       "fake data", "utility"):
            self.assertIn(banned, p, banned)
        # …and the behaviour half of the same ban.
        self.assertIn("HOW behaviour is implemented", p)
        for banned in ("state stores", "hooks", "endpoints"):
            self.assertIn(banned, p, banned)

    def test_it_pins_FUNCTIONALITY_and_WIRING_as_changes(self):
        """S171, and it is a real S128 defect: the mission built a status bar
        that EXISTED and was wired to nothing. A diff of a mockup against a
        repo cannot see "wired" — the mock has fake internals by design — so
        the knowledge is in the conversation, which this pass already reads.

        The captain's bar: *"the change list must cover functionality and
        flow, not just look — the wired status bar, not just a status bar that
        exists."*"""
        p = self._p()
        self.assertIn("WHAT A THING IS WIRED TO", p)
        self.assertIn("LOOK, FLOW AND BEHAVIOUR", p)
        self.assertIn("A thing that only LOOKS right is not built", p)
        # his own example, in the prompt's own words
        self.assertIn("\"There is a status bar\" is not the change", p)
        # …and the line is drawn in BOTH directions, in one sentence.
        self.assertIn("what it is CONNECTED TO are changes. HOW IT IS BUILT "
                      "is not", p)

    def test_the_NO_OP_rule_covers_BEHAVIOUR_too(self):
        """The widening must not reopen the door the no-op rule closed. A
        thing the app already DOES, that the mockup does not change, is
        silence — or every hand-off regrows a list of "still works" lines."""
        p = self._p()
        self.assertIn("THAT RULE COVERS BEHAVIOUR EXACTLY AS IT COVERS LOOK", p)
        for banned in ('"still works"', '"remains wired to"'):
            self.assertIn(banned, p, banned)

    def test_it_pins_A_NO_OP_PRODUCES_NO_LINE(self):
        """The rule that deletes the captain's defect. Read the wording: it is
        an instruction about what to WRITE, not a filter over what was
        written — there is no detector anywhere in this road."""
        p = self._p()
        self.assertIn("THERE IS NO LINE FOR IT", p)
        self.assertIn("is SILENCE", p)
        for banned in ('"unchanged"', '"kept"', '"still present"'):
            self.assertIn(banned, p, banned)

    def test_it_forbids_talking_about_EARLIER_DRAFTS_OF_THE_MOCKUP(self):
        """The captain's two examples verbatim — the T1 mock's toggle and the
        Layer-properties panel the T1 mock added. Both are mock-versus-mock,
        and against his real app the second is a no-op."""
        p = self._p()
        self.assertIn("THE DESIGN CHAT ARGUED WITH ITSELF", p)
        self.assertIn("an earlier draft", p)
        self.assertIn("removed FROM THE MOCKUP", p)
        self.assertIn("never seen the design chat", p)

    def test_DECISIONS_is_given_as_the_WHY_and_refused_as_the_WHAT(self):
        p = self._p()
        # S171 — and it is now ALSO given as the source of BEHAVIOUR, because
        # a picture cannot show what a control is wired to and the concept
        # doc's flow + must-do sections can.
        self.assertIn("USE IT FOR WHY, FOR BEHAVIOUR AND FOR SCOPE", p)
        self.assertIn("DO NOT use it as the list of changes", p)
        self.assertIn("DECLARED FLOW", p)
        self.assertIn("WHAT IT MUST DO", p)

    def test_it_asks_for_the_shape_the_parser_READS(self):
        from lcars_serve.actions import (_handoff_derive_parse,
                                         _HANDOFF_DERIVE_MARKER)
        p = self._p()
        self.assertIn(_HANDOFF_DERIVE_MARKER, p)
        # …and a reply in the shape it asks for really does parse.
        self.assertEqual(
            _handoff_derive_parse(_HANDOFF_DERIVE_MARKER
                                  + "\ntoday a → the mockup b, because c"),
            ["today a → the mockup b, because c"])

    def test_it_tells_the_worker_it_WRITES_NOTHING(self):
        self.assertIn("You write NOTHING", self._p())

    def test_S172_it_asks_the_pass_to_DECLARE_WHAT_IT_DROPPED(self):
        """The whole of item 1 lives in this prompt, because the pass is the
        only party that knows it dropped something."""
        from lcars_serve.actions import (_HANDOFF_DERIVE_ASK_MARKER,
                                         _HANDOFF_DERIVE_MAX_ASKS)
        p = self._p()
        self.assertIn(_HANDOFF_DERIVE_ASK_MARKER, p)
        self.assertIn("SAY SO. DO NOT DROP IT", p)
        self.assertIn("WRITE IT DOWN AS A QUESTION", p)
        self.assertIn(str(_HANDOFF_DERIVE_MAX_ASKS), p)
        # …and the CHANGE block is still the LAST thing in the reply, which is
        # the fail-safe the second block was not allowed to weaken.
        self.assertLess(p.index(_HANDOFF_DERIVE_ASK_MARKER + "\n"),
                        p.rindex("=== CHANGES ===\n"))
        self.assertIn("NOTHING MAY FOLLOW THIS", p)

    def test_S172_the_out_of_scope_RULING_IS_STILL_BINDING(self):
        """He ruled the suppression FAIR. The cure must not widen the diff —
        the pass still honours his scope and still reads it for intent, it just
        stops throwing the finding away."""
        p = self._p()
        self.assertIn("out-of-scope list is binding and you must honour it", p)
        self.assertIn("DO NOT report a change to something he ruled", p)
        self.assertIn("conservative reading", p)

    def test_S172_the_question_block_CANNOT_READ_AS_AN_ESCALATION(self):
        """It is a line he skims, not a gate. The prompt says so to the only
        party that could turn it into one."""
        p = self._p()
        self.assertIn("nothing you write here stops anything", p)
        self.assertIn("if nothing was ambiguous, write none", p)
        self.assertIn("it is not a failure", p)


class S170DeriveBase(HandoffBase):
    """THE CAPTAIN'S REAL ROOM, with the derivation switched on.

    `web/tests/fixtures/s170-tile-editor/` is a byte copy of
    `~/Projects/groutwork-holodeck/give-the-tile-editor-a-more-modern-ui-look-
    and/` taken on 2026-08-07 while he was using it. No absolute path is read
    at test time.
    """

    handoff_check = "1"
    FIXTURE = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                           "fixtures", "s170-tile-editor")
    ROOM = "give-the-tile-editor-a-more-modern-ui-look"
    # The pass's own output shape, for the three real changes in his room.
    DERIVED = [
        "today every colour is a hardcoded Tailwind class or inline hex → the "
        "mockup drives every chrome surface from one themeable token set",
        "today the editor is dark-only → the mockup adds a light theme the "
        "toolbar's sun/moon button switches to",
        "today ModeSwitcher and MapSwitcher are two separate bars → the mockup "
        "merges them into one 42px row with pill map tabs",
    ]

    @classmethod
    def setUpClass(cls):
        base = getattr(super(S170DeriveBase, cls), "setUpClass", None)
        if base:
            base()
        for name, attr in (("concept.md", "CONCEPT"),
                           ("mockup.html", "MOCKUP"),
                           ("basis.md", "BASIS")):
            with open(os.path.join(cls.FIXTURE, name)) as fh:
                setattr(cls, attr, fh.read())

    def _room(self, name="Give the tile editor a more modern UI look"):
        """A program whose room holds all THREE real files, written through a
        real TURN — the derivation must run on a room the product made."""
        self._set_turns({"stdout": "Drew it.", "writes": [
            {"path": "mockup.html", "content": self.MOCKUP},
            {"path": "concept.md", "content": self.CONCEPT},
            {"path": "basis.md", "content": self.BASIS}]})
        sid, _ = self._start(program=name)
        self._post("/api/holodeck/%s/say" % sid, {"text": "draw it"})
        return sid

    def _reply(self, changes=None):
        from lcars_serve.actions import _HANDOFF_DERIVE_MARKER
        return ("I read the toolbar, the mode switcher and the map tabs.\n"
                + _HANDOFF_DERIVE_MARKER + "\n"
                + "\n".join("- %s" % c for c in (changes or self.DERIVED))
                + "\n")

    def _derive(self, sid, **body):
        return self._post_raw("/api/holodeck/%s/derive" % sid, body)

    def _settled(self, sid, tries=200, scope=None, force=False):
        """Start the pass the way the DECK does, then poll `promote`.

        S171 — THE FIRST LINE IS THE GATE, and it is what changed. `promote`
        used to start the pass; it peeks now, so a helper that only polled it
        would sit on `none` for ever and every test below would be measuring a
        pass that was never asked for. ▶ SEND TO ALIGN posts `derive`; the
        dialog then reads what that produced, exactly as this does.

        Nothing here reaches inside the daemon for a private handle."""
        self._derive(sid, **({"force": True} if force else {}))
        body = {} if scope is None else {"scope": scope}
        for _ in range(tries):
            _st, out = self._promote(sid, **body)
            state = out["state"]
            if (state.get("derive") or {}).get("state") != "running":
                return state
            time.sleep(0.05)
        raise AssertionError("the derivation never settled")


class S170FixtureEvidenceTest(S170DeriveBase):
    """PIN THE FIXTURE. If someone 'fixes' it, every claim below is about
    nothing — and this fixture is the captain's own words made checkable."""

    handoff_check = "0"

    def test_the_TWO_MOCK_VERSUS_MOCK_lines_really_are_in_his_doc(self):
        self.assertIn("T1 mock had a two-segment\n  light/dark toggle → now "
                      "one button", self.CONCEPT)
        self.assertIn("Remove the Layer-properties panel that the T1 mock "
                      "added", self.CONCEPT)

    def test_the_HALF_HONEST_close_button_line_really_is_in_his_doc(self):
        """The sharpest one, because the truth is in the qualifier and THE
        HEADLINE IS WHAT GETS ACTED ON."""
        self.assertIn("Add a Close button to the toolbar", self.CONCEPT)
        self.assertIn("today the editor already has a close-project",
                      self.CONCEPT)

    def test_the_UNDO_REDO_line_pulls_the_mock_TOWARD_today(self):
        self.assertIn("Redraw Undo/Redo as the simpler rounded hook-arrow "
                      "style (matching the", self.CONCEPT)

    def test_the_REAL_changes_are_in_there_too(self):
        """The control. A cure that dropped everything would pass every test
        above and hand him an empty brief."""
        for real in ("net-new CSS-variable token layer",
                     "Add a light theme alongside dark",
                     "single merged tab row 42px",
                     "pill-shaped map tabs",
                     "Add a brand block"):
            self.assertIn(real, self.CONCEPT, real)

    def test_NONE_of_the_21_bullets_reaches_the_brief_any_more(self):
        """THE ACCEPTANCE ASSERTION, stated at the level the captain stated it.
        `## Decisions` is not read by the drafting road, so his ramble is gone
        — all of it, including the four mock-relative bullets — and what
        replaces it comes from the diff."""
        sid = self._room()
        _st, out = self._promote(sid)
        brief = out["state"]["brief"]
        for gone in ("T1 mock had a two-segment",
                     "Remove the Layer-properties panel",
                     "Add a Close button to the toolbar",
                     "Redraw Undo/Redo as the simpler rounded hook-arrow",
                     "net-new CSS-variable token layer"):
            self.assertNotIn(gone, brief, gone)
        self.assertNotIn("decisions", out["state"])


class S170DerivationTest(S170DeriveBase):
    """THE CURE, end to end on his room."""

    def _drive(self, changes=None):
        sid = self._room()
        self._set_turns({"stdout": self._reply(changes)})
        return sid, self._settled(sid)

    def test_the_derived_list_becomes_the_change_section_of_the_brief(self):
        _sid, state = self._drive()
        d = state["derive"]
        self.assertEqual(d["state"], "done")
        self.assertTrue(d["ok"], d)
        self.assertEqual(d["changes"], self.DERIVED)
        self.assertEqual(state["changes"], self.DERIVED)
        brief = state["brief"]
        self.assertIn("## What the mockup changes about your app as it is "
                      "today", brief)
        for c in self.DERIVED:
            self.assertIn(c, brief)

    def test_a_MOCK_RELATIVE_correction_produces_NO_LINE_AND_NO_TRACE(self):
        """The captain's own two examples, on his own room. They are absent
        because THERE IS NOTHING TO REPORT — the app never had a
        Layer-properties panel and it already has a labelled Close control —
        not because anything recognised them."""
        _sid, state = self._drive()
        brief = state["brief"]
        for gone in ("Layer-properties", "Close button", "hook-arrow",
                     "two-segment"):
            self.assertNotIn(gone, brief, gone)

    def test_the_REAL_changes_still_arrive(self):
        _sid, state = self._drive()
        brief = state["brief"]
        for real in ("token set", "light theme", "42px row", "pill map tabs"):
            self.assertIn(real, brief, real)

    def test_the_brief_got_SHORTER_than_the_conversation_it_replaced(self):
        """The captain's complaint was volume as much as content — "a lot of my
        ramble back and forth". 21 conversation bullets in, a diff out."""
        from lcars_serve.actions import _md_section, _md_items
        log = _md_items(_md_section(self.CONCEPT, "Decisions", prefix=True))
        self.assertEqual(len(log), 21, len(log))
        _sid, state = self._drive()
        self.assertLess(len(state["changes"]), len(log))

    def test_the_worker_STANDS_IN_THE_REPO_and_is_READ_ONLY_and_COLD(self):
        """The four properties that make this a diff rather than a second
        design turn:

          IN THE REPO  cwd is the TARGET PROJECT, so "today" is the app as it
                       actually is — not `basis.md`'s summary of how it was
                       when the program started. This is the S170 change.
          READ-ONLY    no write channel at all, in either directory.
          COLD         a FRESH session id, never `--resume` of the design chat.
                       A warm worker would answer out of its memory of what it
                       MEANT to draw.
          GRANTED THE ROOM  `--add-dir` on the program dir, because the drawing
                       is half the diff and it is not in the cwd.
        """
        sid = self._room()
        design = list(self._calls())
        self._set_turns({"stdout": self._reply()})
        self._settled(sid)
        new = self._calls()[len(design):]
        passes = [c for c in new
                  if any("=== CHANGES ===" in a for a in c["argv"])]
        self.assertEqual(len(passes), 1, new)
        argv, cwd = passes[0]["argv"], passes[0]["cwd"]
        # IN THE REPO — and emphatically NOT in the program's room.
        self.assertEqual(os.path.realpath(cwd), os.path.realpath(self.repo))
        self.assertFalse(cwd.endswith(self.ROOM), cwd)
        # READ-ONLY.
        self.assertEqual(self._flag_value(argv, "--allowedTools"),
                         "Read,Grep,Glob")
        self.assertEqual(self._flag_value(argv, "--disallowedTools"),
                         "Write,Edit,Bash,NotebookEdit")
        # COLD.
        self.assertNotIn("--resume", argv)
        self.assertIsNotNone(self._flag_value(argv, "--session-id"))
        design_sids = set()
        for c in design:
            for flag in ("--session-id", "--resume"):
                v = self._flag_value(c["argv"], flag)
                if v:
                    design_sids.add(v)
        self.assertNotIn(self._flag_value(argv, "--session-id"), design_sids)

    def test_the_worker_is_POINTED_AT_the_drawing_BY_ABSOLUTE_PATH(self):
        self._drive()
        prompt = [p for p in self._prompts() if "=== CHANGES ===" in p][-1]
        room = os.path.join(self._sidecar(), self.ROOM)
        self.assertIn(os.path.join(room, "mockup.html"), prompt)
        self.assertIn(os.path.join(room, "concept.md"), prompt)
        self.assertIn(os.path.join(room, "basis.md"), prompt)

    def test_a_room_with_NO_basis_still_runs_and_SAYS_so(self):
        """`basis.md` is context, not a dependency — that is the whole reason
        this stopped being read as the source of truth."""
        self._set_turns({"stdout": "Drew it.", "writes": [
            {"path": "mockup.html", "content": self.MOCKUP},
            {"path": "concept.md", "content": self.CONCEPT}]})
        sid, _ = self._start(program="No basis here")
        self._post("/api/holodeck/%s/say" % sid, {"text": "draw it"})
        self._set_turns({"stdout": self._reply()})
        state = self._settled(sid)
        self.assertTrue(state["derive"]["ok"], state["derive"])
        prompt = [p for p in self._prompts() if "=== CHANGES ===" in p][-1]
        self.assertIn("there is no basis file", prompt)

    def test_a_SECOND_open_of_the_same_dialog_spawns_NO_SECOND_WORKER(self):
        """The cost rule, and it matters more now: this pass is 154–220s and it
        reads a whole repository. He opens the dialog, reads it, picks the
        other build scope and reads it again — that must not be three passes."""
        sid = self._room()
        self._set_turns({"stdout": self._reply()})
        self._settled(sid)
        spawned = len(self._calls())
        for _ in range(3):
            self.assertEqual(self._settled(sid)["changes"], self.DERIVED)
        self.assertEqual(len(self._calls()), spawned)
        self._settled(sid, scope="look-only")
        self.assertEqual(len(self._calls()), spawned)

    def test_a_REDRAWN_mockup_is_DERIVED_AGAIN(self):
        """The other half of the cache rule, and the one that would rot
        silently: a stale change list on a redrawn mockup describes a design
        that no longer exists."""
        sid = self._room()
        self._set_turns({"stdout": self._reply()})
        self._settled(sid)
        spawned = len(self._calls())
        self._set_turns({"stdout": "Redrew it.", "writes": [
            {"path": "mockup.html",
             "content": self.MOCKUP + "\n<!-- v2 -->\n"}]})
        self._post("/api/holodeck/%s/say" % sid, {"text": "again"})
        self._set_turns({"stdout": self._reply(["today a → the mockup b"])})
        state = self._settled(sid)
        self.assertGreater(len(self._calls()), spawned + 1)
        self.assertEqual(state["changes"], ["today a → the mockup b"])


class S170DeriveIsWalkAwayableTest(S170DeriveBase):
    """THE WAIT, AND THE FACT THAT HE CAN LEAVE IT.

    The captain's design: *"make send to align a stage with wait time … I know
    this means it can take a few minutes and we can make it so it can walk away,
    but I feel like that would yield a better result."*
    """

    def test_the_gate_answers_IMMEDIATELY_with_a_RUNNING_state(self):
        """The pass is 154–220s. Nothing waits on it — the click returns at
        once, saying what is happening.

        S171 — AND THE CLICK IS `derive`, NOT `promote`. ▶ SEND TO ALIGN on
        the deck starts it; the dialog only reads it."""
        sid = self._room()
        self._set_turns({"sleep": 30, "stdout": self._reply()})
        t0 = time.time()
        self._derive(sid)
        _st, out = self._promote(sid)
        self.assertLess(time.time() - t0, 5.0)
        self.assertEqual(out["state"]["derive"]["state"], "running")
        self.assertGreater(out["state"]["derive"]["startedAt"], 0)
        self.assertGreaterEqual(out["state"]["derive"]["now"],
                                out["state"]["derive"]["startedAt"])

    def test_a_RUNNING_pass_still_hands_him_a_BRIEF_HE_CAN_FILE(self):
        """NEVER A GATE. The change list is the part still being worked out;
        his words, what the mockup implies and what is out of scope are all
        there, and ▦ FILE MISSION fires."""
        sid = self._room()
        self._set_turns({"sleep": 30, "stdout": self._reply()})
        self._derive(sid)
        _st, out = self._promote(sid)
        brief = out["state"]["brief"]
        self.assertTrue(brief.strip())
        self.assertEqual(brief.split("\n")[0],
                         "Give the tile editor a more modern UI look")
        self.assertNotIn("## What the mockup changes", brief)
        st, _b = self._post("/api/park", {"idea": brief, "holodeck": sid})
        self.assertEqual(st, 200)
        self.assertEqual(len(self._filed()), 1)

    def _passes(self):
        return [c for c in self._calls()
                if any("=== CHANGES ===" in a for a in c["argv"])]

    def test_the_pass_KEEPS_RUNNING_when_he_walks_away_and_comes_back(self):
        """He closes the dialog (or reloads the page — the client keeps no
        state either way) and asks again later. The DAEMON owns the pass, so
        the second ask joins the one already in flight rather than starting a
        second.

        COUNTED ON THE PASSES THEMSELVES, not on the total call count: the
        pass runs on its own thread, so a total taken while it is still
        spawning is a number that moves under the test."""
        sid = self._room()
        self._set_turns({"sleep": 1.0, "stdout": self._reply()})
        self._derive(sid)
        _st, first = self._promote(sid)
        self.assertEqual(first["state"]["derive"]["state"], "running")
        for _ in range(4):
            _st, again = self._promote(sid)
            self.assertEqual(again["state"]["derive"]["state"], "running")
        state = self._settled(sid)
        self.assertEqual(state["changes"], self.DERIVED)
        self.assertEqual(len(self._passes()), 1, self._passes())

    def test_the_brief_is_COMPLETE_when_he_comes_back(self):
        sid = self._room()
        self._set_turns({"stdout": self._reply()})
        state = self._settled(sid)
        for c in self.DERIVED:
            self.assertIn(c, state["brief"])


class S170DeriveSurvivesTheDaemonTest(S170DeriveBase):
    """DURABILITY — the captain's own question, asked mid-session: *"If the
    daemon closes by accident while I walk away are we still good?"*

    S169's cache was in-memory and disposable, which was defensible when the
    result was a hint about a list he already had. It is not defensible now:
    the result IS a section of his brief, it costs 154–220s, and a walk-away is
    exactly when nobody is watching the daemon.
    """

    def _record_path(self, sid):
        sess = self.actions._holodeck[sid]
        return os.path.join(sess.program_dir, "handoff-changes.json")

    def _fresh_daemon(self):
        """A brand-new `Actions` — the shape a RESTARTED DAEMON PROCESS has.

        Built exactly the way `setUp` builds the live one, so the only thing
        that differs is that its caches are empty. That is the whole claim:
        nothing in memory, and the answer still there."""
        return Actions(repo_root=self.repo, scripts=self.scripts,
                       worker_bin=self.claude_bin,
                       holodeck_root=self.holo_root)

    def test_a_FINISHED_pass_is_WRITTEN_INTO_THE_PROGRAM_ROOM(self):
        """The room is a durable git repo S126 already commits per turn, and it
        is the right home for a fact about this program. NOT `.git/lcars/` —
        that is mission state, and no mission exists yet."""
        sid = self._room()
        self._set_turns({"stdout": self._reply()})
        self._settled(sid)
        with open(self._record_path(sid)) as fh:
            rec = json.load(fh)
        self.assertTrue(rec["ok"])
        self.assertEqual(rec["changes"], self.DERIVED)
        self.assertTrue(rec["fingerprint"])

    def test_a_RESTARTED_DAEMON_finds_it_and_he_does_NOT_WAIT_TWICE(self):
        """THE HEADLINE. A brand-new `Actions` — the shape a fresh daemon
        process has — with an empty cache, opening the same room: the answer is
        there, and NO WORKER IS SPAWNED."""
        sid = self._room()
        self._set_turns({"stdout": self._reply()})
        self._settled(sid)
        sess = self.actions._holodeck[sid]
        fresh = self._fresh_daemon()
        self.assertEqual(fresh._handoff_derives, {})
        spawned = len(self._calls())
        state = fresh._handoff_derive_state(sess)
        self.assertEqual(state["state"], "done")
        self.assertTrue(state["ok"])
        self.assertEqual(state["changes"], self.DERIVED)
        self.assertTrue(state["fromDisk"])
        self.assertEqual(len(self._calls()), spawned)

    def test_the_FINGERPRINT_carries_NO_SESSION_ID(self):
        """The bug this would otherwise have. A restarted daemon mints a NEW
        session id for the same room, so a session-keyed record could never be
        found again — the durability would be theatre that passes its own unit
        test."""
        sid = self._room()
        sess = self.actions._holodeck[sid]
        fp = self.actions._handoff_derive_fingerprint(sess.program_dir,
                                                      sess.target_repo)
        self.assertNotIn(sid, fp)
        # …and asking again under a different session id gives the same key.
        self.assertEqual(fp, self.actions._handoff_derive_fingerprint(
            sess.program_dir, sess.target_repo))

    def test_a_pass_that_was_IN_FLIGHT_when_the_daemon_died_is_NOT_persisted(
            self):
        """A persisted "running" with no process behind it is a surface
        asserting a state it cannot know — the FL-009/FL-017 family this round
        has cured twice. A fresh daemon owns no in-flight pass, so it must not
        find one. NO TIMER AND NO STALENESS CONSTANT: FL-009's ruling is that a
        bigger constant is the same guess with a longer fuse."""
        sid = self._room()
        self._set_turns({"sleep": 30, "stdout": self._reply()})
        self._derive(sid)
        _st, out = self._promote(sid)
        self.assertEqual(out["state"]["derive"]["state"], "running")
        self.assertFalse(os.path.exists(self._record_path(sid)))

    def test_a_REDRAWN_mockup_invalidates_the_PERSISTED_record_too(self):
        """The fingerprint is the correctness guarantee, and it has to hold
        across a restart or the durability becomes a way to serve a stale
        answer for ever."""
        sid = self._room()
        self._set_turns({"stdout": self._reply()})
        self._settled(sid)
        sess = self.actions._holodeck[sid]
        self._set_turns({"stdout": "Redrew.", "writes": [
            {"path": "mockup.html",
             "content": self.MOCKUP + "\n<!-- v2 -->\n"}]})
        self._post("/api/holodeck/%s/say" % sid, {"text": "again"})
        fresh = self._fresh_daemon()
        fp = fresh._handoff_derive_fingerprint(sess.program_dir,
                                               sess.target_repo)
        self.assertIsNone(fresh._handoff_derive_read(sess.program_dir, fp))

    def test_a_REWORDED_PROMPT_invalidates_it_too(self):
        """A reworded prompt asks a different question, so an answer to the old
        one must not be served as an answer to the new one."""
        import lcars_serve.actions as A
        sid = self._room()
        sess = self.actions._holodeck[sid]
        before = self.actions._handoff_derive_fingerprint(sess.program_dir,
                                                          sess.target_repo)
        old = A._HANDOFF_DERIVE_PROMPT
        try:
            A._HANDOFF_DERIVE_PROMPT = old + "\nand one more thing\n"
            after = self.actions._handoff_derive_fingerprint(
                sess.program_dir, sess.target_repo)
        finally:
            A._HANDOFF_DERIVE_PROMPT = old
        self.assertNotEqual(before, after)

    def test_a_CORRUPT_record_behaves_EXACTLY_like_NO_RECORD(self):
        """FAIL-SAFE, applied to durability. A bad file on disk must never be
        worse than no file on disk — he gets his brief and the pass is offered
        again."""
        sid = self._room()
        self._set_turns({"stdout": self._reply()})
        self._settled(sid)
        sess = self.actions._holodeck[sid]
        fp = self.actions._handoff_derive_fingerprint(sess.program_dir,
                                                      sess.target_repo)
        for junk in ("", "{", "null", "[]", '{"fingerprint": "x"}',
                     '{"fingerprint": %r, "changes": "nope"}' % fp,
                     '{"fingerprint": %r, "changes": [1, 2]}' % fp):
            with open(self._record_path(sid), "w") as fh:
                fh.write(junk)
            self.assertIsNone(
                self.actions._handoff_derive_read(sess.program_dir, fp),
                junk)
        # …and with the room's record garbage, the dialog still works.
        with open(self._record_path(sid), "w") as fh:
            fh.write("{ broken")
        self.actions._handoff_derives.clear()
        self._set_turns({"stdout": self._reply()})
        state = self._settled(sid)
        self.assertEqual(state["changes"], self.DERIVED)

    def test_an_UNWRITABLE_room_does_not_break_the_pass(self):
        """Persistence is best-effort. A room LCARS cannot write costs him the
        durability and nothing else."""
        sid = self._room()
        sess = self.actions._holodeck[sid]
        fp = self.actions._handoff_derive_fingerprint(sess.program_dir,
                                                      sess.target_repo)
        self.assertFalse(self.actions._handoff_derive_write(
            os.path.join(sess.program_dir, "nope", "nope"), fp,
            {"ok": True, "changes": ["x"]}))
        self._set_turns({"stdout": self._reply()})
        self.assertEqual(self._settled(sid)["changes"], self.DERIVED)


class S170DeriveFailsSafeTest(S170DeriveBase):
    """Every way the pass can fail, and the same outcome each time: the captain
    gets his brief, the band SAYS the change list is not there, and the filing
    goes."""

    def _expect_unusable(self, sid):
        state = self._settled(sid)
        d = state["derive"]
        self.assertEqual(d["state"], "done")
        self.assertFalse(d["ok"], d)
        self.assertEqual(d["changes"], [])
        self.assertTrue(d["why"], d)
        # the brief is still a brief — his own opening words lead it — and
        # the filing is not blocked
        self.assertTrue(state["brief"].strip())
        self.assertEqual(state["brief"].split("\n")[0],
                         "Give the tile editor a more modern UI look")
        self.assertNotIn("## What the mockup changes", state["brief"])
        st, _b = self._post("/api/park", {"idea": state["brief"],
                                          "holodeck": sid})
        self.assertEqual(st, 200)
        return d

    def test_a_worker_that_NARRATES_instead_of_answering(self):
        sid = self._room()
        self._set_turns({"stdout": "I read the mockup. Lots has changed!"})
        why = self._expect_unusable(sid)["why"]
        self.assertIn("never wrote its change list", why)

    def test_a_worker_that_DIES(self):
        sid = self._room()
        self._set_turns({"stdout": "Error: authentication failed", "exit": 1})
        self._expect_unusable(sid)

    def test_a_worker_that_NEVER_COMES_BACK(self):
        old = os.environ.get("LCARS_HOLODECK_HANDOFF_CHECK_TIMEOUT")
        os.environ["LCARS_HOLODECK_HANDOFF_CHECK_TIMEOUT"] = "1"
        try:
            sid = self._room()
            self._set_turns({"sleep": 30, "stdout": "too late"})
            why = self._expect_unusable(sid)["why"]
            self.assertIn("stopped", why)
        finally:
            if old is None:
                os.environ.pop("LCARS_HOLODECK_HANDOFF_CHECK_TIMEOUT", None)
            else:
                os.environ["LCARS_HOLODECK_HANDOFF_CHECK_TIMEOUT"] = old

    def test_there_is_NO_ENGINE_at_all(self):
        sid = self._room()
        self.actions.worker_bin = None
        with self.actions._holodeck_lock:
            self.actions._holodeck[sid].engine = None
        why = self._expect_unusable(sid)["why"]
        self.assertIn("engine", why)

    def test_the_PROJECT_HAS_GONE_AWAY(self):
        """S170's own new failure mode: the pass stands in the captain's repo,
        so a repo that is not there is a pass that cannot run. It says which."""
        sid = self._room()
        with self.actions._holodeck_lock:
            self.actions._holodeck[sid].target_repo = os.path.join(
                self.tmp, "no-such-project")
        why = self._expect_unusable(sid)["why"]
        self.assertIn("no-such-project", why)

    def test_an_exception_INSIDE_the_pass_cannot_pin_the_dialog(self):
        """A bare `except` in `_handoff_derive_run` is the mechanism, not
        laziness: anything escaping that thread would leave the entry at
        "running" forever and the deck would poll a spinner nothing can
        resolve."""
        sid = self._room()
        real = self.actions._handoff_derive_spawn

        def explode(*_a, **_k):
            raise RuntimeError("boom")

        self.actions._handoff_derive_spawn = explode
        try:
            why = self._expect_unusable(sid)["why"]
            self.assertIn("RuntimeError", why)
        finally:
            self.actions._handoff_derive_spawn = real

    def test_a_pass_that_finds_NOTHING_is_reported_as_what_it_IS(self):
        """Not a failure and not a clean result. On a program somebody spent an
        afternoon drawing, "nothing differs" is far likelier to be a bad pass
        than a true finding — so `ok` is true, `changes` is empty, and the
        brief simply has no change section."""
        from lcars_serve.actions import _HANDOFF_DERIVE_MARKER
        sid = self._room()
        self._set_turns({"stdout": "I looked.\n" + _HANDOFF_DERIVE_MARKER
                                   + "\n"})
        state = self._settled(sid)
        self.assertTrue(state["derive"]["ok"])
        self.assertEqual(state["derive"]["changes"], [])
        self.assertNotIn("## What the mockup changes", state["brief"])
        st, _b = self._post("/api/park", {"idea": state["brief"],
                                          "holodeck": sid})
        self.assertEqual(st, 200)


class S170DeriveIsNOTAGateTest(S170DeriveBase):
    """WHAT THE DERIVATION IS AND IS NOT, pinned — REWRITTEN FOR S171.

    S170's claim was "the derivation can never block a hand-off, anywhere".
    THAT CLAIM IS NO LONGER TRUE AND IT IS NOT SUPPOSED TO BE: the captain
    asked for a gate — *"making that step a gated wait that retriggers behind a
    wait guard if you keep chatting with the composer"* — so ▶ SEND TO ALIGN
    waits for the pass by design. Leaving these tests asserting the old
    property would have made them lie about the product.

    THE TWO HALVES OF THE HONEST CONTRACT, and both are held below:

      1. THE FILING PATH STILL NEVER READS IT. `file_mission`, `park`,
         `align_start` and `_handoff_idea` do not consult the derivation in
         any state — the gate is a UI affordance on the deck, not a rule
         inside a filing road. So every mission that reaches a filing endpoint
         is filed, whatever the pass did, and the `ast` test still proves it.
      2. THERE IS ALWAYS A COMPLETE, SENDABLE BRIEF. `promote` answers one in
         EVERY derivation state — none, running, failed, empty, done — and it
         files. A pass that never answers costs him a section of the draft and
         nothing else.

    ── S172 REWROTE PART OF (2), BECAUSE THE PRODUCT CHANGED ────────────────

    This class used to say the road through was `Send without the change list`
    on the deck. THE CAPTAIN DELETED THAT CONTROL — *"we don't need the send
    without change list one"* — so a test naming it would have been asserting
    a button that is not there.

    WHAT IS ASSERTED NOW IS WHAT IS ACTUALLY TRUE, and it is two smaller
    claims rather than one big one:

      2a. `promote` still answers a sendable brief in all five states, and
          `/api/park` still files it. That is the daemon's half and it is
          exactly what it was — proven below on the same matrix.
      2b. THE DECK'S ROAD THROUGH A FAILED PASS IS THE PRIMARY CONTROL. On
          `failed`, ▶ SEND TO ALIGN is live (`holoHandoffBar`), so an engine
          outage cannot strand a ready program. Proven by reading the bar's
          own source, because that is where the claim lives — and by
          `tests/drives/browser/handoff.sh` in a real browser, which is the
          only thing that can prove it is CLICKABLE where it sits.

    WHAT IS HONESTLY NO LONGER TRUE, stated rather than quietly dropped: while
    a pass is RUNNING there is no way past the wait. The daemon bounds it at
    420s and the room keeps the answer, so the worst case is a wait, not a lost
    program — but it is a wait he cannot skip, and that is the captain's own
    trade.
    """

    def test_NOTHING_in_the_FILING_path_reads_the_derivation(self):
        """If a filing road ever consulted it, this would be a gate — and a
        gate a bounded model pass can close is a design session the captain
        cannot get out of. `promote` publishes it; the runner and its helpers
        produce it. NOBODY ELSE — above all not `_handoff_idea`, `file_mission`
        or `park`."""
        import ast
        import lcars_serve.actions as A
        tree = ast.parse(open(A.__file__).read())
        readers = set()
        for node in ast.walk(tree):
            if not isinstance(node, ast.FunctionDef):
                continue
            # IDENTIFIERS AND STRING SUBSCRIPTS, never `ast.dump` of the whole
            # node: a dump includes the DOCSTRING, so a function that merely
            # explains where the derivation comes from reads as one that
            # consults it. That is a test failing on prose, which teaches the
            # next reader to delete the comment rather than the coupling.
            for sub in ast.walk(node):
                name = ""
                if isinstance(sub, ast.Attribute):
                    name = sub.attr
                elif isinstance(sub, ast.Name):
                    name = sub.id
                elif (isinstance(sub, ast.Constant)
                        and isinstance(sub.value, str)):
                    name = sub.value if sub.value == "derive" else ""
                if name in ("_handoff_derive_state", "derive"):
                    readers.add(node.name)
        allowed = {"holodeck_promote", "_handoff_derive_state",
                   # S171 — the gate's own endpoint and the deck payload that
                   # renders it. NEITHER IS A FILING ROAD: `holodeck_derive`
                   # starts the pass and answers its state, `_holodeck_meta`
                   # publishes that state so the button can be drawn from a
                   # fact. Nothing here decides whether a mission may be filed.
                   "holodeck_derive", "_holodeck_meta",
                   "_handoff_derive_forget",
                   "_handoff_derive_run", "_handoff_derive_spawn",
                   "_handoff_derive_read", "_handoff_derive_write",
                   "_handoff_derive_fingerprint", "_handoff_derive_prompt",
                   "_handoff_derive_parse", "_handoff_derive_enabled",
                   "_handoff_derive_timeout", "_handoff_changes",
                   "_holodeck_args"}
        self.assertEqual(readers - allowed, set(), sorted(readers - allowed))

    def test_NO_CLASSIFIER_reads_a_change_line_and_decides_anything(self):
        """The road S156 (14/14 → 5/14 on a reworded corpus), S147 (four parser
        generations) and S157 (five guards) burned four sessions on. A derived
        line goes from the pass into the box; nothing in between inspects it."""
        import ast
        import inspect
        import lcars_serve.actions as A
        # S172 — AND THE QUESTION ROAD IS HELD TO THE SAME BAR. It is the same
        # reply, read by the same line reader; nothing anywhere decides that a
        # line IS a question. The pass declares it — see the block at
        # `_HANDOFF_DERIVE_ASK_MARKER`.
        for fn in (A._handoff_brief, A._handoff_parts, A._handoff_derive_parse,
                   A._handoff_derive_asks, A._handoff_derive_lines):
            src = inspect.getsource(fn)
            for banned in ("kept", "unchanged", "carried over", "similar",
                           "difflib", "SequenceMatcher"):
                self.assertNotIn(banned, src.lower(), (fn.__name__, banned))
        # …and the only regexes on this road are structural (list decoration).
        tree = ast.parse(inspect.getsource(A._handoff_derive_lines))
        self.assertEqual(
            sorted(n.func.attr for n in ast.walk(tree)
                   if isinstance(n, ast.Call)
                   and isinstance(n.func, ast.Attribute)
                   and n.func.attr in ("match", "search", "sub", "findall")),
            ["search", "sub"])
        # …and the ask parser itself does no matching AT ALL: it is two string
        # splits on a marker the prompt names.
        tree = ast.parse(inspect.getsource(A._handoff_derive_asks))
        self.assertEqual(
            [n.func.attr for n in ast.walk(tree)
             if isinstance(n, ast.Call) and isinstance(n.func, ast.Attribute)
             and n.func.attr in ("match", "search", "sub", "findall")], [])

    def test_a_SENDABLE_BRIEF_exists_in_EVERY_derivation_state(self):
        """S171 — THE HONEST REWRITE of "filing is never blocked in ANY state".

        The old test asserted a property the captain has since asked us to
        reverse: ▶ SEND TO ALIGN now waits for the pass. Deleting the test
        would have deleted the guarantee with it, and leaving it would have
        left it asserting something false. So it asserts the guarantee that
        MUST survive the gate — that a complete, sendable brief is always
        available and always files.

        The matrix is the same five states, and the road each one takes is
        `promote` — the one endpoint every deck control that opens the dialog
        reaches — then `/api/park`.

        S172 — AND `running` NO LONGER CLAIMS TO BE REACHABLE FROM THE DECK.
        The escape hatch that reached it is deleted. `promote` still answers a
        sendable brief mid-pass (proven below, and it is what makes a future
        cancel or a second tab safe), but the sentence that used to say "the
        deck's `Send without the change list` is this exact call" is gone
        because that control is gone. See `test_the_DECK_S_ROAD_THROUGH…`."""
        from lcars_serve.actions import _HANDOFF_DERIVE_MARKER
        for i, stdout in enumerate(("nonsense", _HANDOFF_DERIVE_MARKER,
                                    self._reply())):
            # A DISTINCT PROGRAM EACH TIME: one room, one program (S124 fix
            # round 1), so reusing the name is a 409 and not a finding.
            sid = self._room(name="Filing matrix %d" % i)
            self._set_turns({"stdout": stdout})
            state = self._settled(sid)
            self.assertTrue(state["brief"].strip(), stdout[:40])
            st, _b = self._post("/api/park", {"idea": state["brief"],
                                              "holodeck": sid})
            self.assertEqual(st, 200, stdout[:40])
        # …NOT DERIVED AT ALL, which is the state a fresh draft starts in and
        # the one the gate holds him at. The draft is complete and files; what
        # the deck offers him there is one click that starts the pass.
        sid = self._room(name="Filing matrix none")
        _st, out = self._promote(sid)
        self.assertEqual(out["state"]["derive"]["state"], "none")
        self.assertTrue(out["state"]["brief"].strip())
        st, _b = self._post("/api/park", {"idea": out["state"]["brief"],
                                          "holodeck": sid})
        self.assertEqual(st, 200)
        # …and RUNNING, which never settles inside this test. THE ENGINE BEING
        # SLOW OR WEDGED MUST NOT MAKE A READY PROGRAM UNFILEABLE.
        sid = self._room(name="Filing matrix running")
        self._set_turns({"sleep": 30, "stdout": self._reply()})
        self._derive(sid)
        _st, out = self._promote(sid)
        self.assertEqual(out["state"]["derive"]["state"], "running")
        st, _b = self._post("/api/park", {"idea": out["state"]["brief"],
                                          "holodeck": sid})
        self.assertEqual(st, 200)

    def test_the_DECK_S_ROAD_THROUGH_A_FAILED_PASS_IS_THE_PRIMARY(self):
        """S172 — the other half of claim 2, and the reason the hatch could go.

        The bar's `failed` branch must leave ▶ SEND TO ALIGN LIVE — with a real
        click handler, not a disabled control with an explanation — because it
        is now the ONLY way off a dead engine. This reads the source rather
        than the DOM on purpose: a node harness has no CSS and cannot tell a
        live button from one painted to look live, and the browser rig
        (`tests/drives/browser/handoff.sh`) owns that claim with a hit test.
        What is proven HERE is that the branch exists and that the hatch is
        really gone from every state."""
        import os
        js = open(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                               "..", "static", "board.js")).read()
        start = js.index("function holoHandoffBar(")
        bar = js[start:js.index("\nfunction ", start + 10)]
        # THE HATCH IS GONE. `handoff-skip` was its handle everywhere — the
        # bar built it, the browser rig pressed it — so its absence from the
        # whole file is the check; the prose ABOUT the deletion stays, and a
        # test that failed on a comment would teach the next reader to delete
        # the explanation rather than the control.
        self.assertNotIn("handoff-skip", js)
        self.assertNotIn("Send without the change list\"", js)
        self.assertNotIn("holoBtn(\"Send without", js)
        # …and the failed state falls THROUGH to the live send, which is the
        # `else` branch carrying `holoPromote`.
        self.assertIn('} else if (gate === "running") {', bar)
        self.assertIn("holoPromote(p.sessionId)", bar)
        # …with the retry beside it, and BOTH controls the same size class.
        self.assertIn('holoBtn("↻ Try the change list again", "big"', bar)
        self.assertIn('holoBtn("▶ Send to Align", "go big"', bar)

    def test_the_derivation_worker_touches_NOTHING_IN_THE_PROGRAMS_ROOM(self):
        """The room holds `mockup.html` and `concept.md` — the two documents
        the whole diff is made of. A pass that could edit the drawing it is
        reading is the one outcome worse than no pass.

        WHAT THIS TEST CAN AND CANNOT PROVE, said plainly. The stub worker
        OBEYS NO TOOL FLAG: it writes wherever it is told, so its landing in
        the cwd below is evidence about the CWD and about nothing else. The
        actual fence is the CLI's own tool surface, pinned on the argv by
        `S170DerivePostureTest` and measured against the live binaries in the
        S124 spike. What IS proven here is the daemon's half: whatever the
        worker does, the room the drawing lives in gains exactly one file and
        it is LCARS's own durable record."""
        sid = self._room()
        room = os.path.join(self._sidecar(), self.ROOM)

        def snap(d):
            return {f: open(os.path.join(d, f), "rb").read()
                    for f in sorted(os.listdir(d))
                    if os.path.isfile(os.path.join(d, f))}

        before_room = snap(room)
        self._set_turns({"stdout": self._reply(),
                         "writes": [{"path": "WORKER-WROTE-THIS.txt",
                                     "content": "x"}]})
        self._settled(sid)
        after_room = snap(room)
        self.assertEqual(set(after_room) - set(before_room),
                         {"handoff-changes.json"})
        for name, data in before_room.items():
            self.assertEqual(after_room[name], data, name)
        # …and the stub's write landed in the pass's CWD, which is the
        # captain's project — the S170 change, observed rather than asserted.
        self.assertTrue(os.path.isfile(
            os.path.join(self.repo, "WORKER-WROTE-THIS.txt")))


class S171GateTest(S170DeriveBase):
    """▶ SEND TO ALIGN IS A GATE WITH A WAIT — the daemon's half.

    THE CAPTAIN'S DESIGN, after driving S170 on his own program: *"making that
    step a gated wait that retriggers behind a wait guard if you keep chatting
    with the composer."*

    S170 started the pass from `promote` — i.e. the moment the hand-off dialog
    opened. Two costs, and he paid both: a look that went back to drawing burnt
    a pass, and the wait lived inside a dialog. The pass is now started by ONE
    endpoint, reached by ONE control, and every other reader peeks.

    What this proves: which call spends and which cannot; that the published
    state is what the button is drawn from; that a composer turn invalidates a
    finished answer as a FACT about the files; and that a failure is
    retryable rather than permanent. What it cannot see is any of it on
    screen — `tests/drives/browser/handoff.sh` owns that.
    """

    # ── PROMOTE NO LONGER SPENDS ────────────────────────────────────────────
    def _spawned(self, want, tries=100):
        """How many worker calls have been recorded, waiting for `want`.

        `derive` answers as soon as the thread is STARTED, so a bare count
        immediately afterwards races the exec. Waiting for the number it should
        reach makes a shortfall a real failure and a surplus visible."""
        for _ in range(tries):
            got = len(self._calls())
            if got >= want:
                return got
            time.sleep(0.05)
        return len(self._calls())

    def test_opening_the_HAND_OFF_DIALOG_spawns_NOTHING(self):
        """The defect this closes: he opened it mid-design to look, and a
        154-220s pass started behind it."""
        sid = self._room()
        before = len(self._calls())
        _st, out = self._promote(sid)
        self.assertEqual(len(self._calls()), before)
        self.assertEqual(out["state"]["derive"], {"state": "none"})

    def test_reading_the_DECK_spawns_nothing_either(self):
        """The program list is read on every refresh. A peek that could spend
        would be a pass per repaint."""
        sid = self._room()
        before = len(self._calls())
        body = self._get("/api/holodeck")
        self.assertEqual(len(self._calls()), before)
        prog = [p for p in body["programs"] if p.get("sessionId") == sid][0]
        self.assertEqual(prog["derive"], {"state": "none"})

    def test_CHANGING_THE_BUILD_SCOPE_spawns_nothing(self):
        """The dialog re-asks `promote` on every scope click. Under S170 that
        was free only because the fingerprint had not moved; it is now free by
        construction."""
        sid = self._room()
        before = len(self._calls())
        for scope in ("look-only", "look+behaviour", "look-only"):
            self._promote(sid, scope=scope)
        self.assertEqual(len(self._calls()), before)

    # ── THE ONE ROAD THAT DOES ──────────────────────────────────────────────
    def test_the_DERIVE_endpoint_is_what_starts_it(self):
        sid = self._room()
        self._set_turns({"sleep": 30, "stdout": self._reply()})
        before = len(self._calls())
        st, body = self._derive(sid)
        self.assertEqual(st, 200, body)
        self.assertEqual(body["state"]["derive"]["state"], "running")
        self.assertEqual(self._spawned(before + 1), before + 1)

    def test_a_SECOND_click_joins_the_pass_and_does_not_start_another(self):
        """A double click, a second tab, a reload. One draft, one pass."""
        sid = self._room()
        self._set_turns({"sleep": 30, "stdout": self._reply()})
        self._derive(sid)
        before = len(self._calls())
        _st, body = self._derive(sid)
        self.assertEqual(body["state"]["derive"]["state"], "running")
        self.assertEqual(len(self._calls()), before)

    def test_when_it_LANDS_the_deck_says_so_and_carries_the_changes(self):
        sid = self._room()
        self._set_turns({"stdout": self._reply()})
        self._settled(sid)
        body = self._get("/api/holodeck")
        prog = [p for p in body["programs"] if p.get("sessionId") == sid][0]
        self.assertEqual(prog["derive"]["state"], "done")
        self.assertTrue(prog["derive"]["ok"])
        self.assertEqual(prog["derive"]["changes"], self.DERIVED)

    def test_a_program_with_NO_MOCKUP_is_refused_before_it_spends(self):
        """There is nothing to diff against an empty room, and a spawn would
        burn minutes to say so."""
        self._set_turns({"stdout": "nothing drawn yet"})
        sid, _ = self._start(program="Empty room")
        self._post("/api/holodeck/%s/say" % sid, {"text": "hello"})
        before = len(self._calls())
        st, body = self._derive(sid)
        self.assertEqual(st, 409, body)
        self.assertIn("nothing to hand over", body["error"])
        self.assertEqual(len(self._calls()), before)

    # ── INVALIDATION IS A FACT ABOUT THE FILES ──────────────────────────────
    def test_a_FURTHER_COMPOSER_TURN_returns_the_gate_to_none(self):
        """THE WAIT GUARD, in his words. Nothing remembers to clear a flag:
        the fingerprint covers `mockup.html`, so a redraw simply stops matching
        the stored answer."""
        sid = self._room()
        self._set_turns({"stdout": self._reply()})
        state = self._settled(sid)
        self.assertTrue(state["derive"]["ok"])
        # …he draws one more turn.
        self._set_turns({"stdout": "Moved the toolbar.", "writes": [
            {"path": "mockup.html",
             "content": self.MOCKUP + "\n<!-- one more turn -->\n"}]})
        self._post("/api/holodeck/%s/say" % sid, {"text": "move it"})
        _st, out = self._promote(sid)
        self.assertEqual(out["state"]["derive"], {"state": "none"})
        self.assertNotIn("## What the mockup changes", out["state"]["brief"])

    def test_and_the_INVALIDATED_gate_can_be_re_generated(self):
        sid = self._room()
        self._set_turns({"stdout": self._reply()})
        self._settled(sid)
        self._set_turns({"stdout": "Moved it.", "writes": [
            {"path": "mockup.html", "content": self.MOCKUP + "\n<!--x-->\n"}]})
        self._post("/api/holodeck/%s/say" % sid, {"text": "move it"})
        self._set_turns({"stdout": self._reply(["today A → the mockup B"])})
        state = self._settled(sid)
        self.assertEqual(state["derive"]["changes"], ["today A → the mockup B"])

    # ── A FAILURE IS NOT PERMANENT ──────────────────────────────────────────
    def test_a_FAILED_pass_is_RETRYABLE_with_force(self):
        """Without this, a captain whose engine was down for one minute reads
        "LCARS could not read your project" until he redraws the mockup — the
        persisted record is keyed on the FILES, and they have not changed."""
        sid = self._room()
        self._set_turns({"stdout": "no marker here at all"})
        state = self._settled(sid)
        self.assertFalse(state["derive"]["ok"])
        # a plain re-ask reads the persisted failure back and spends nothing.
        before = len(self._calls())
        _st, body = self._derive(sid)
        self.assertFalse(body["state"]["derive"]["ok"])
        self.assertEqual(len(self._calls()), before)
        # …and HIS explicit retry clears it and runs again.
        self._set_turns({"stdout": self._reply()})
        state = self._settled(sid, force=True)
        self.assertTrue(state["derive"]["ok"])
        self.assertEqual(state["derive"]["changes"], self.DERIVED)

    def test_force_NEVER_deletes_a_record_that_is_not_THIS_drafts(self):
        """The room is the captain's archive. A retry may only ever clear the
        answer it is about to replace."""
        import json as _json
        sid = self._room()
        self._set_turns({"stdout": "no marker"})
        self._settled(sid)
        room = os.path.join(self._sidecar(), self.ROOM)
        path = os.path.join(room, "handoff-changes.json")
        with open(path) as fh:
            rec = _json.load(fh)
        rec["fingerprint"] = "a-different-draft-entirely"
        with open(path, "w") as fh:
            _json.dump(rec, fh)
        self._set_turns({"sleep": 30, "stdout": self._reply()})
        self._derive(sid, force=True)
        self.assertTrue(os.path.isfile(path))
        with open(path) as fh:
            self.assertEqual(_json.load(fh)["fingerprint"],
                             "a-different-draft-entirely")

    # ── A SENT PROGRAM CANNOT SPEND ─────────────────────────────────────────
    def test_a_SENT_program_refuses_the_derivation(self):
        sid = self._room()
        self._set_turns({"stdout": self._reply()})
        state = self._settled(sid)
        self._post("/api/park", {"idea": state["brief"], "holodeck": sid})
        before = len(self._calls())
        st, body = self._derive(sid)
        self.assertEqual(st, 409, body)
        self.assertEqual(len(self._calls()), before)


class S172AskedNotDroppedTest(S170DeriveBase):
    """THE BIG ONE, END TO END, ON THE CAPTAIN'S OWN ROOM.

    `web/tests/fixtures/s170-tile-editor/` is a byte copy of the room he was
    driving. Its `## Out of scope` really does say *"The tile canvas rendering
    — left as an untouched placeholder well"*, its `## WHAT IT MUST DO` bucket
    2 really is the `(none — …)` placeholder, and the two things that went
    missing were canvas CHROME: the zoom / fit row and the hover x/y pill.

    THE ACCEPTANCE PAIR, and it has to be both halves at once:
      · the zoom buttons and the hover pill COME BACK, as questions, in
        `## Implied by the mockup`;
      · the change list STILL DOES NOT ASSERT THEM as changes.
    """

    # The pass's own reply, in the shape S172 asks for: the three real changes
    # in his room, and the two things his scope made ambiguous — declared.
    ASKS = [
        "the mockup adds zoom in / zoom out / fit buttons and a 100% readout "
        "over the canvas — in or out, given the canvas is out of scope?",
        "the mockup shows a hover x/y tile pill over the canvas, and the app "
        "already computes that value without displaying it — in or out?",
    ]

    def _reply(self, changes=None, asks=None):
        from lcars_serve.actions import (_HANDOFF_DERIVE_MARKER,
                                         _HANDOFF_DERIVE_ASK_MARKER)
        return (
            "I read Toolbar.tsx, MapCanvas.tsx and canvas/editorCanvas.ts.\n"
            + _HANDOFF_DERIVE_ASK_MARKER + "\n"
            + "\n".join("- %s" % a for a in
                        (self.ASKS if asks is None else asks))
            + "\n" + _HANDOFF_DERIVE_MARKER + "\n"
            + "\n".join("- %s" % c for c in (changes or self.DERIVED)) + "\n")

    def test_the_QUESTIONS_reach_the_brief_and_the_CHANGE_LIST_DOES_NOT(self):
        from lcars_serve.actions import (_HANDOFF_IMPLIED_TITLE,
                                         _HANDOFF_CHANGE_TITLE)
        sid = self._room()
        self._set_turns({"stdout": self._reply()})
        state = self._settled(sid)
        brief = state["brief"]
        # 1. THEY CAME BACK, and they came back in bucket 2 — the section whose
        #    caption already says these are IMPLIED and not his words.
        self.assertEqual(state["implied"], self.ASKS, state["implied"])
        self.assertIn(_HANDOFF_IMPLIED_TITLE, brief)
        for ask in self.ASKS:
            self.assertIn(ask, brief)
        # 2. …AND THE CHANGE LIST STILL DOES NOT ASSERT THEM. The section
        #    between the two headings is the whole change list, and neither
        #    control appears in it.
        i = brief.index(_HANDOFF_CHANGE_TITLE)
        j = brief.index(_HANDOFF_IMPLIED_TITLE)
        self.assertLess(i, j)
        changes_section = brief[i:j]
        for word in ("zoom", "fit button", "hover", "100%"):
            self.assertNotIn(word, changes_section.lower(), word)
        self.assertEqual(state["changes"], self.DERIVED)
        # 3. …and the brief still files.
        st, _b = self._post("/api/park", {"idea": brief, "holodeck": sid})
        self.assertEqual(st, 200)

    def test_a_question_is_MARKED_IMPLIED_and_never_laundered_into_his_words(
            self):
        """FL-011, and the reason bucket 2 exists at all. A derived question
        must arrive under the caption that says nobody said it — a line the
        captain reads as his own requirement is worse than no line."""
        from lcars_serve.actions import (_HANDOFF_IMPLIED_TITLE,
                                         _HANDOFF_IMPLIED_NOTE)
        sid = self._room()
        self._set_turns({"stdout": self._reply()})
        brief = self._settled(sid)["brief"]
        head = brief.index(_HANDOFF_IMPLIED_TITLE)
        self.assertIn(_HANDOFF_IMPLIED_NOTE, brief[head:])
        self.assertIn("NOT things you said", _HANDOFF_IMPLIED_TITLE)
        for ask in self.ASKS:
            self.assertGreater(brief.index(ask), head)

    def test_a_pass_that_DECLARES_NOTHING_shows_NO_SECTION_AT_ALL(self):
        """The ordinary answer, and the placeholder cure in the same
        assertion: his room's bucket 2 is `- (none — …)`, so with no declared
        questions there is nothing to show — and a heading, a caption and a
        bullet saying nothing is exactly what he was reading."""
        from lcars_serve.actions import _HANDOFF_IMPLIED_TITLE
        sid = self._room()
        self._set_turns({"stdout": self._reply(asks=[])})
        state = self._settled(sid)
        self.assertEqual(state["implied"], [])
        self.assertNotIn(_HANDOFF_IMPLIED_TITLE, state["brief"])
        self.assertNotIn("(none —", state["brief"])
        self.assertNotIn("Implied by the mockup", state["brief"])

    def test_the_QUESTIONS_are_NOT_A_GATE_and_set_nothing_pending(self):
        """It is a line he skims. `promote` publishes no new state, the mission
        files immediately, and nothing anywhere is awaiting a human."""
        sid = self._room()
        self._set_turns({"stdout": self._reply()})
        state = self._settled(sid)
        self.assertTrue(state["derive"]["ok"])
        # the derivation's own block carries them as data and NOTHING else
        # changes shape: no pending flag, no question record, no gate.
        self.assertEqual(state["derive"]["asks"], self.ASKS)
        for key in ("awaitingHuman", "pending", "blocked", "gate"):
            self.assertNotIn(key, state["derive"])
        st, body = self._post("/api/park", {"idea": state["brief"],
                                            "holodeck": sid})
        self.assertEqual(st, 200, body)

    def test_the_QUESTIONS_survive_the_DAEMON_dying(self):
        """They cost the same 154-220s the change list does, so they are
        persisted with it or the walk-away is only half true."""
        import json
        import os
        sid = self._room()
        self._set_turns({"stdout": self._reply()})
        self._settled(sid)
        room = os.path.join(self._sidecar(), self.ROOM)
        with open(os.path.join(room, "handoff-changes.json")) as fh:
            rec = json.load(fh)
        self.assertEqual(rec["asks"], self.ASKS)

    def test_a_record_written_BEFORE_this_key_existed_is_still_GOOD(self):
        """A missing `asks` degrades to no questions, never to no answer.
        Throwing away a change list over a missing second list would be the
        fail-safe clause inverted."""
        import json
        import os
        sid = self._room()
        self._set_turns({"stdout": self._reply()})
        self._settled(sid)
        room = os.path.join(self._sidecar(), self.ROOM)
        path = os.path.join(room, "handoff-changes.json")
        with open(path) as fh:
            rec = json.load(fh)
        fp = rec["fingerprint"]
        rec.pop("asks")
        with open(path, "w") as fh:
            json.dump(rec, fh)
        from lcars_serve.actions import Actions
        back = Actions._handoff_derive_read(room, fp)
        self.assertEqual(back["changes"], self.DERIVED)
        self.assertEqual(back["asks"], [])
        # …and so is a record whose `asks` is the wrong shape entirely.
        rec["asks"] = {"nope": 1}
        with open(path, "w") as fh:
            json.dump(rec, fh)
        back = Actions._handoff_derive_read(room, fp)
        self.assertEqual(back["changes"], self.DERIVED)
        self.assertEqual(back["asks"], [])


class S172EmptyBucketShowsNothingTest(HandoffBase):
    """THE `(none — …)` PLACEHOLDER, and the rule the captain gave for it.

    S170 ledgered it; his own brief for this round puts it in scope: *"If a
    section has no real items, show nothing at all — no heading, no caption."*

    A bullet whose WHOLE text is bracketed is the writer talking ABOUT the
    list, not writing in it. That is a test on DELIMITERS — the same class as
    stripping the `-` a model puts in front of a good line — and it reads no
    words, so there is no corpus to reword past it (S156, 14/14 → 5/14).
    """

    handoff_check = "0"

    DOC = ("# P\n\n## WHAT IT MUST DO\n\n"
           "### 1. Requirements (captain's words)\n"
           "1. **T1** \"Make it modern.\"\n\n"
           "### 2. Implied by the mockup, not yet settled\n"
           "%s\n\n"
           "### 3. Out of scope\n"
           "%s\n")

    def _parts(self, implied, scope):
        from lcars_serve.actions import _handoff_parts
        return _handoff_parts(self.DOC % (implied, scope))

    def test_a_wholly_bracketed_bullet_is_NOT_an_item(self):
        _r, _c, implied, scope = self._parts(
            "- (none — the dirty-state binding and the canvas-overlay "
            "ownership questions from T1 were answered by the captain in T2.)",
            "- (nothing was ruled out.)")
        self.assertEqual(implied, [])
        self.assertEqual(scope, [])

    def test_and_the_SECTION_then_shows_NOTHING_AT_ALL(self):
        """Not an empty heading with a caption under it. `_handoff_section`
        already returns "" for no items — the cure is that the aside stops
        counting as one."""
        from lcars_serve.actions import _handoff_brief
        brief = _handoff_brief(
            self.DOC % ("- (none — answered in T2.)", "- (none.)"), "P")
        self.assertNotIn("Implied by the mockup", brief)
        self.assertNotIn("Out of scope", brief)
        self.assertNotIn("(none", brief)

    def test_A_REAL_ITEM_WITH_BRACKETS_IN_IT_IS_STILL_AN_ITEM(self):
        """The control. A cure that dropped anything with a bracket in it
        would silently eat his real out-of-scope line, which names three CSS
        colours in backticks and brackets."""
        _r, _c, implied, scope = self._parts(
            "- Does the theme persist across sessions (and default to OS)?",
            "- The tile canvas (its rendering and colours) is untouched (T1).")
        self.assertEqual(
            implied,
            ["Does the theme persist across sessions (and default to OS)?"])
        self.assertEqual(
            scope,
            ["The tile canvas (its rendering and colours) is untouched (T1)."])

    def test_the_CONTRACT_tells_the_design_worker_to_leave_it_EMPTY(self):
        """The durable half. Filtering fixes the rooms already written this
        way; the contract stops new ones being written that way at all."""
        from lcars_serve.actions import _CONCEPT_CONTRACT
        self.assertIn("AN EMPTY BUCKET IS EMPTY", _CONCEPT_CONTRACT)
        self.assertIn("(none —", _CONCEPT_CONTRACT)


class S170DeriveIsSWITCHABLETest(S170DeriveBase):
    handoff_check = "0"

    def test_OFF_spawns_NOTHING_and_SAYS_it_is_off(self):
        """`$LCARS_HOLODECK_HANDOFF_CHECK=0` — S169's env var name, kept
        deliberately: it is the switch every suite in this repo already sets,
        and renaming it would silently start spawning workers inside test runs
        that thought they had opted out.

        The band must be able to tell "off" from "found nothing": a captain who
        turned it off and a captain looking at an empty list are in completely
        different positions."""
        sid = self._room()
        before = len(self._calls())
        _st, out = self._promote(sid)
        self.assertEqual(out["state"]["derive"], {"state": "off"})
        self.assertEqual(len(self._calls()), before)
        self.assertTrue(out["state"]["brief"].strip())
        self.assertNotIn("## What the mockup changes", out["state"]["brief"])


class S170DerivePostureTest(HolodeckBase):
    def test_the_derive_posture_is_the_GROUNDING_posture_not_a_third_one(self):
        """Reuse, not invention. Grounding is not merely the closest precedent
        now — it is the SAME posture in the SAME place: one cold read-only pass
        standing in the captain's project, whose output the daemon owns."""
        from lcars_serve.actions import _HOLODECK_TOOLS, _HOLODECK_DENY
        for engine in ("claude", "copilot"):
            self.assertEqual(_HOLODECK_TOOLS[(engine, "derive")],
                             _HOLODECK_TOOLS[(engine, "grounding")], engine)
        self.assertEqual(_HOLODECK_DENY[("claude", "derive")],
                         _HOLODECK_DENY[("claude", "grounding")])

    def test_no_derive_posture_grants_a_WRITE_TOOL(self):
        from lcars_serve.actions import _HOLODECK_TOOLS
        for engine in ("claude", "copilot"):
            tools = _HOLODECK_TOOLS[(engine, "derive")].lower()
            for w in ("write", "edit", "create", "bash"):
                self.assertNotIn(w, tools, (engine, tools))

    def test_copilot_gets_the_ROOM_as_its_ONE_grant(self):
        """`--add-dir` grants WRITE on copilot (measured) — and the direction
        here is the safe one: the cwd is the captain's project and the GRANT is
        LCARS's own sidecar room, so the only directory it could make writable
        is one LCARS owns. It cannot make even that writable, because
        `view,grep,glob` holds no write tool. Without the grant the pass cannot
        open `mockup.html`, which is half the diff."""
        from lcars_serve.actions import Actions
        args = Actions._holodeck_args("copilot", "derive", "sid-1", True,
                                      "/side/room")
        self.assertIn("--add-dir", args)
        self.assertEqual(args[args.index("--add-dir") + 1], "/side/room")

    def test_derive_is_NOT_a_session_mode(self):
        """`_HOLODECK_MODES` is what the START endpoint will accept. The
        derivation is a pass the daemon runs, never a room he can open."""
        from lcars_serve.actions import _HOLODECK_MODES
        self.assertNotIn("derive", _HOLODECK_MODES)
        st, body = self._post_raw("/api/holodeck/start",
                                  {"program": "x", "mode": "derive"})
        self.assertEqual(st, 400)
        self.assertIn("derive", body["error"].lower())


# ════════════════════════════════════════════════════════════════════════════
# S169 FIX ROUND 2 — A FALSE "⚠ STILL OPEN", AND IT COST A REAL HUMAN GATE
#
# THE MEASUREMENT, off the same capstone. `idea.md` — the byte copy is
# `web/tests/fixtures/s169-capstone/idea.md` — was filed carrying:
#
#     1. Q: Is emerald/green the right brand accent? Settled T3: keep emerald.
#        ⚠ STILL OPEN — he was not asked, or did not answer. Treat as undecided.
#     2. Q: (Theme default/persistence — settled T3, moved to Decisions.)
#        ⚠ STILL OPEN — he was not asked, or did not answer. Treat as undecided.
#
# Both were SETTLED IN THEIR OWN TEXT, three words to the left of the stamp, and
# the captain had answered emerald verbatim in an earlier turn. The stamp
# manufactured an Align question he had already answered.
#
# It is the symmetric twin of the defect fix round 1 cured — the daemon counting
# bullets without reading them — pointing the other way, and this one has a
# price: a human interrupted for nothing is how a walk-away pipeline stops being
# one.
#
# ── THE CURE, AND WHY IT IS NOT A CLASSIFIER ───────────────────────────────
#
# There is no test anywhere for the word "settled", no similarity score, no
# parse of the bullet. Two strands, both structural:
#
#   1. `_CONCEPT_CONTRACT` — a settled question LEAVES `## Open questions`. The
#      bullet is deleted and the answer written into `## Decisions` with its
#      turn; never annotated in place, never left as a tombstone. The bucket
#      then MEANS "nobody has answered these", and the daemon can go on counting
#      bullets, which is all it has ever done.
#   2. The stamp states the daemon's ONE FACT — no answer was typed — and stops
#      asserting the two things it cannot know: that he was not asked (the
#      promote dialog puts every one of these in front of him with its own
#      answer box) and that the question is undecided (only the line says that,
#      and the daemon does not read it).
# ════════════════════════════════════════════════════════════════════════════
class S169FalseStillOpenTest(HandoffBase):
    FIXTURE = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                           "fixtures", "s169-capstone")

    @classmethod
    def setUpClass(cls):
        base = getattr(super(S169FalseStillOpenTest, cls), "setUpClass", None)
        if base:
            base()
        with open(os.path.join(cls.FIXTURE, "idea.md")) as fh:
            cls.IDEA = fh.read()
        with open(os.path.join(cls.FIXTURE, "concept.md")) as fh:
            cls.CAPSTONE_CONCEPT = fh.read()

    def test_the_fixture_is_the_real_filing_and_the_stamp_really_was_FALSE(self):
        """Pin the evidence before pinning the cure."""
        self.assertIn("Is emerald/green the right brand accent? Settled T3: "
                      "keep emerald.", self.IDEA)
        self.assertIn("(Theme default/persistence — settled T3, moved to "
                      "Decisions.)", self.IDEA)
        self.assertIn("⚠ STILL OPEN — he was not asked, or did not answer.",
                      self.IDEA)
        # …and the doc that produced it left both settled entries sitting in the
        # open-questions bucket, which is what the contract now forbids.
        qs = self.CAPSTONE_CONCEPT.split("## Open questions", 1)[1]
        qs = qs.split("\n## ", 1)[0]
        self.assertIn("Settled T3: keep emerald", qs)
        self.assertIn("moved to Decisions", qs)

    def test_the_stamp_no_longer_claims_HE_WAS_NOT_ASKED(self):
        """The promote dialog puts every one of these in front of him with its
        own answer box, so half of that disjunction is provably false on the
        road the captain actually uses."""
        sid = self._program()
        self._post("/api/park", {"idea": "go", "holodeck": sid})
        text = self._filed()[0]["files"]["--idea"]
        self.assertNotIn("he was not asked", text)
        self.assertNotIn("Treat as undecided", text)

    def test_the_stamp_states_the_ONE_FACT_the_daemon_HAS(self):
        sid = self._program()
        self._post("/api/park", {"idea": "go", "holodeck": sid})
        text = self._filed()[0]["files"]["--idea"]
        self.assertIn("NO ANSWER RECORDED at filing", text)
        self.assertIn("typed nothing in the box", text)

    def test_it_sends_the_reader_to_the_LINE_before_a_human_gate(self):
        """The question's own words are quoted directly above the stamp — on
        the capstone they contained the answer. A stage must read them before
        spending a gate, and must not be ORDERED to raise one."""
        sid = self._program()
        self._post("/api/park", {"idea": "go", "holodeck": sid})
        text = self._filed()[0]["files"]["--idea"]
        block = text.split("## Open questions from the design session", 1)[1]
        self.assertIn("READ THE QUESTION'S OWN LINE FIRST", block)
        self.assertIn("must not be asked", block)
        self.assertIn("only for one the line leaves genuinely undecided", block)

    def test_the_OLD_HARM_is_still_prevented(self):
        """The reason the stamp existed at all (S128/FL-011 b): silence must
        never read as agreement, and a stage must never settle a question by
        taking whatever the mockup happens to show."""
        sid = self._program()
        self._post("/api/park", {"idea": "go", "holodeck": sid})
        text = self._filed()[0]["files"]["--idea"]
        low = text.lower()
        self.assertIn("never settle one yourself", low)
        self.assertIn("never treat one as agreed because nobody objected", low)
        self.assertIn("lcars:awaiting-human", low)

    def test_the_CONTRACT_moves_a_settled_question_OUT_of_the_bucket(self):
        """The structural strand, and the one that stops the false stamp at
        source: `## Open questions` means "nobody has answered these", so the
        daemon counting its bullets is correct by construction."""
        from lcars_serve.actions import _CONCEPT_CONTRACT
        c = _CONCEPT_CONTRACT
        self.assertIn("THE MOMENT ONE IS SETTLED IT LEAVES THIS LIST", c)
        self.assertIn("Delete the bullet outright", c)
        self.assertIn("`## Decisions`", c)
        self.assertIn("Never annotate a question in place", c)
        self.assertIn("tombstone", c)

    def test_the_contract_quotes_the_TWO_REAL_SHAPES_it_forbids(self):
        """Both came off the capstone doc verbatim. A rule stated abstractly is
        a rule a model reads past — these are the two sentences it actually
        wrote, shown back to it."""
        from lcars_serve.actions import _CONCEPT_CONTRACT
        self.assertIn("Settled T3: keep emerald", _CONCEPT_CONTRACT)
        self.assertIn("settled T3, moved", _CONCEPT_CONTRACT)

    WORDS = ("settled", "unchanged", "kept", "carried over")

    def test_there_is_NO_SETTLED_OR_KEPT_DETECTOR_IN_THE_CODE(self):
        """THE PIN, and it is STRUCTURAL rather than a grep.

        The road not taken, and it stays not taken: S156 fell 14/14 → 5/14 on a
        meaning-preserving rewording of its own corpus, S147 lost four
        generations of a source parser, S157 five versions of a guard, and S169
        fix round 1 declined to build this guard deliberately. The daemon must
        never decide, from a bullet's WORDING, that a question is settled — nor,
        from a change line's wording, that it claims something was kept.

        A plain grep of the file cannot say that: these words are all over the
        comments, the concept-doc contract and the check's prompt, and SAYING
        them to a model is the opposite of matching them in code. So this walks
        the AST and looks at the only two places a wording test can live — a
        regular expression, and a comparison — and asserts no string constant
        reachable from either one names any of them.
        """
        import ast
        import lcars_serve.actions as A
        tree = ast.parse(open(A.__file__).read())
        suspect = []
        for node in ast.walk(tree):
            is_re = (isinstance(node, ast.Call)
                     and isinstance(node.func, ast.Attribute)
                     and isinstance(node.func.value, ast.Name)
                     and node.func.value.id == "re")
            if not (is_re or isinstance(node, ast.Compare)):
                continue
            for sub in ast.walk(node):
                if isinstance(sub, ast.Constant) and isinstance(sub.value, str):
                    low = sub.value.lower()
                    for w in self.WORDS:
                        if w in low:
                            suspect.append((w, sub.value[:120]))
        self.assertEqual(suspect, [], suspect)

    def test_that_pin_is_NOT_VACUOUS(self):
        """The control. If the words vanished from the file entirely the test
        above would pass while the product had lost the two places it is
        SUPPOSED to say them — to a model, in prose."""
        from lcars_serve.actions import (_CONCEPT_CONTRACT,
                                         _HANDOFF_DERIVE_PROMPT)
        self.assertIn("kept", _CONCEPT_CONTRACT.lower())
        self.assertIn("SETTLED", _CONCEPT_CONTRACT)
        # S170 — the derivation prompt is where "unchanged"/"kept" are now
        # SAID to a model, and saying them is the opposite of matching them.
        self.assertIn("unchanged", _HANDOFF_DERIVE_PROMPT)
        self.assertIn("kept", _HANDOFF_DERIVE_PROMPT)


# ══ S172 — DUPLICATE A PROGRAM, CARRYING ITS HISTORY ════════════════════════
#
# A SENT program is locked forever (`_refuse_if_sent`), and duplicate-to-keep-
# designing was ruled in S123 and never built. The captain's ruling for this
# round is that the duplicate BRINGS THE CHAT OVER: it is a CONTINUATION of an
# old design, not a clean copy of its outputs, so a worker in the new room knows
# WHY the mockup looks the way it does.
#
# Everything here rides S126's existing roads — `_ensure_sidecar`, the room, the
# sidecar git repo, and `holodeck_open`'s warm-restart replay. There is no
# second copy mechanism, and these suites are written to fail if one appears.
class DuplicateBase(HandoffBase):
    """A program with a REAL room: mockup, concept doc, basis and an
    attachment, all written by a real TURN rather than planted behind the
    daemon's back (HandoffBase's rule, for the same reason)."""

    BASIS = ("# What the project already looks like\n\n"
             "- amber is `--lcars-amber: #ff9c00`\n")
    SHOT = "PNG-BYTES-STAND-IN"

    def _drafted(self, program="Command palette"):
        self._set_turns({"stdout": "Built the palette.",
                         "writes": [{"path": "mockup.html",
                                     "content": self.MOCKUP},
                                    {"path": "concept.md",
                                     "content": self.CONCEPT},
                                    {"path": "basis.md",
                                     "content": self.BASIS},
                                    {"path": "attachments/shot.png",
                                     "content": self.SHOT}]})
        sid, _state = self._start(program=program)
        st, body = self._post("/api/holodeck/%s/say" % sid,
                              {"text": "draft the palette"})
        self.assertEqual(st, 200, body)
        return sid

    def _sent(self, program="Command palette"):
        """…and then FILED, by the product's own road, so the room carries a
        real sent record and a real `handoff-changes.json`."""
        sid = self._drafted(program)
        self._seed_changes(sid, ["- the palette replaces the ⌘ button"])
        _st, body = self._post("/api/park", {"idea": "go", "holodeck": sid})
        self.assertEqual(body["state"]["holodeck"]["status"], "sent", body)
        return sid

    def _dup(self, room="command-palette", **body):
        return self._post_raw("/api/holodeck/duplicate",
                              dict(room=room, **body))

    def _rooms(self):
        return sorted(n for n in os.listdir(self._sidecar())
                      if not n.startswith(".")
                      and os.path.isdir(os.path.join(self._sidecar(), n)))

    def _snapshot(self, room):
        """Every byte in a room, keyed by relative path."""
        out = {}
        base = self._room(room)
        for r, dirs, files in os.walk(base):
            dirs[:] = [d for d in dirs if d != ".git"]
            for f in files:
                p = os.path.join(r, f)
                with open(p, "rb") as fh:
                    out[os.path.relpath(p, base)] = fh.read()
        return out

    def _entry(self, room):
        for p in self._list()["programs"]:
            if p["room"] == room:
                return p
        raise AssertionError("no program in room %r: %s"
                             % (room, [p["room"]
                                       for p in self._list()["programs"]]))


class DuplicateCarriesTheProgramTest(DuplicateBase):
    def test_it_makes_a_NEW_room_carrying_the_artifacts_and_the_chat(self):
        self._sent()
        st, body = self._dup()
        self.assertEqual(st, 200, body)
        room = body["state"]["room"]
        self.assertNotEqual(room, "command-palette")
        self.assertIn(room, self._rooms())
        got = self._snapshot(room)
        # the OUTPUTS, byte-identical.
        self.assertEqual(got["mockup.html"].decode(), self.MOCKUP)
        self.assertEqual(got["concept.md"].decode(), self.CONCEPT)
        self.assertEqual(got[os.path.join("attachments", "shot.png")].decode(),
                         self.SHOT)
        # THE CHAT (the captain's ruling): the conversation comes over, so a
        # worker in the new room knows why the mockup looks like this.
        chat = got["transcript.md"].decode()
        self.assertIn("draft the palette", chat)
        self.assertIn("Built the palette.", chat)

    def test_the_ORIGINAL_is_not_touched_by_any_of_it(self):
        self._sent()
        before = self._snapshot("command-palette")
        st, _b = self._dup()
        self.assertEqual(st, 200)
        self.assertEqual(self._snapshot("command-palette"), before)
        # …and it is still the locked record of what was actually filed.
        orig = self._entry("command-palette")
        self.assertEqual(orig["lifecycle"], "sent")
        self.assertEqual(orig["missionId"], self.mint)

    def test_the_duplicate_reads_DRAFT_and_can_be_typed_into(self):
        self._sent()
        _st, body = self._dup()
        room = body["state"]["room"]
        entry = self._entry(room)
        # `draft` because it HAS NO SENT RECORD — not because anything
        # special-cased it. `_handoff_state` is the one function that decides.
        self.assertEqual(entry["lifecycle"], "draft")
        self.assertEqual(entry["missionId"], "")
        self._set_turns({"stdout": "Widened it."})
        st, said = self._post("/api/holodeck/%s/say" % body["state"]["sessionId"],
                              {"text": "make it wider"})
        self.assertEqual(st, 200, said)

    def test_the_duplicate_and_its_lineage_survive_a_daemon_restart(self):
        self._sent()
        _st, body = self._dup()
        room = body["state"]["room"]
        self._restart_daemon()
        entry = self._entry(room)
        self.assertEqual(entry["lifecycle"], "draft")
        self.assertEqual(entry["duplicatedFrom"]["room"], "command-palette")
        self.assertEqual(entry["duplicatedFrom"]["missionId"], self.mint)
        # ONE DURABLE HOME. No second metadata file appeared beside the record.
        self.assertNotIn("duplicate.json", self._snapshot(room))

    def test_the_duplicate_is_RECORDED_in_the_archive_like_every_room_op(self):
        self._sent()
        before = len(self._log())
        _st, body = self._dup()
        self.assertTrue(body["state"]["committed"], body)
        log = self._log()
        self.assertEqual(len(log) - before, 1, log)
        self.assertIn("duplicat", log[0].lower())
        self.assertIn("command-palette", log[0])

    def test_a_room_that_is_not_a_program_is_refused_by_the_SAME_door(self):
        self._sent()
        os.makedirs(os.path.join(self._sidecar(), "screenshots-i-saved"))
        st, body = self._dup(room="screenshots-i-saved")
        self.assertEqual(st, 403, body)
        st, body = self._dup(room="../../etc")
        self.assertEqual(st, 403, body)
        st, body = self._dup(room="no-such-room")
        self.assertEqual(st, 404, body)


class DuplicateDropsTheDerivationTest(DuplicateBase):
    """TRAP 1. `handoff-changes.json` is a derivation of the OLD draft against
    the repo AS IT WAS at filing time. Carrying it would need the S170/S171
    fingerprint to be wrong for it to ever be read back — so the duplicate
    starts with NO derivation and the gate offers to generate one."""

    # the pass is SWITCHED ON here, so `none` is the daemon saying "there is no
    # derivation for this program" rather than "the pass is disabled". `promote`
    # only ever PEEKS (S171), so nothing spawns.
    handoff_check = "1"

    def test_the_derivation_does_NOT_come_over(self):
        self._sent()
        self.assertIn("handoff-changes.json",
                      self._snapshot("command-palette"))
        _st, body = self._dup()
        self.assertNotIn("handoff-changes.json",
                         self._snapshot(body["state"]["room"]))

    def test_the_gate_on_the_duplicate_reads_NONE(self):
        self._sent()
        _st, body = self._dup()
        sid = body["state"]["sessionId"]
        st, promoted = self._promote(sid)
        self.assertEqual(st, 200, promoted)
        draft = promoted["state"]
        self.assertEqual(draft["derive"]["state"], "none", draft["derive"])
        self.assertEqual(draft["changes"], [])


class DuplicateSaysTheBasisIsInheritedTest(DuplicateBase):
    """TRAP 2. `basis.md` is stale BY CONSTRUCTION here: duplicate after the
    mission merged and the app has moved, so the basis describes what the
    project used to be. The ruling taken is CARRY IT AND SAY SO — in the room,
    in the payload the deck renders, and in what the worker is told."""

    def test_the_copied_basis_carries_the_warning_and_names_where_it_came_from(self):
        self._sent()
        _st, body = self._dup()
        text = self._snapshot(body["state"]["room"])["basis.md"].decode()
        self.assertIn("INHERITED", text.upper())
        self.assertIn("STALE", text.upper())
        self.assertIn("Command palette", text)
        # the grounding itself is still all there — marked, not truncated.
        self.assertIn("--lcars-amber: #ff9c00", text)

    def test_the_ORIGINAL_basis_is_left_exactly_as_it_was(self):
        self._sent()
        self._dup()
        self.assertEqual(
            self._snapshot("command-palette")["basis.md"].decode(), self.BASIS)

    def test_the_payload_the_deck_renders_says_it(self):
        self._sent()
        _st, body = self._dup()
        entry = self._entry(body["state"]["room"])
        self.assertTrue(entry["basisInherited"], entry)
        self.assertIn("Command palette", entry["basisNotice"])
        self.assertIn("stale", entry["basisNotice"].lower())
        # …and an ordinary grounded program says nothing of the kind.
        self.assertNotIn("basisInherited", self._entry("command-palette"))

    def test_a_duplicate_with_no_basis_claims_no_inherited_grounding(self):
        self._sent()
        os.unlink(os.path.join(self._room("command-palette"), "basis.md"))
        _st, body = self._dup()
        entry = self._entry(body["state"]["room"])
        self.assertNotIn("basisInherited", entry)
        self.assertNotIn("basisNotice", entry)


class DuplicateHistoryIsNotBindingTest(DuplicateBase):
    """TRAP 3. The inherited transcript must not read as SETTLED — he is
    duplicating precisely because he wants to change something. `_replay_clause`
    tells a REOPENED program to "carry on from where it stops; do not start the
    mockup over", which is right for a reopen and actively wrong here."""

    def _first_prompt_after_duplicate(self):
        self._sent()
        _st, body = self._dup()
        self._set_turns({"stdout": "Widened it."})
        st, said = self._post(
            "/api/holodeck/%s/say" % body["state"]["sessionId"],
            {"text": "make it wider"})
        self.assertEqual(st, 200, said)
        return self._prompts()[-1]

    def test_the_worker_is_told_this_is_a_NEW_program_and_nothing_binds_it(self):
        prompt = self._first_prompt_after_duplicate()
        self.assertIn("NEW PROGRAM", prompt.upper())
        self.assertIn("nothing in", prompt.lower())
        self.assertIn("binding", prompt.lower())
        # the reopen sentence is exactly the wrong one here.
        self.assertNotIn("do not start the mockup over", prompt)

    def test_the_history_is_still_HANDED_OVER_in_full(self):
        prompt = self._first_prompt_after_duplicate()
        self.assertIn("draft the palette", prompt)
        self.assertIn("Built the palette.", prompt)

    def test_it_says_the_ORIGINAL_is_untouched_and_names_its_mission(self):
        prompt = self._first_prompt_after_duplicate()
        # NOT "the mission id appears somewhere in the prompt" — the duplicated
        # transcript carries its OWN lineage line, so the plain reopen clause
        # would satisfy that while saying none of this. These are the words
        # only the duplicate's framing writes.
        self.assertIn("filed as mission `%s`" % self.mint, prompt)
        self.assertIn("UNTOUCHED and stays exactly as it was handed over",
                      prompt)

    def test_it_warns_the_worker_the_inherited_basis_may_be_stale(self):
        prompt = self._first_prompt_after_duplicate()
        self.assertIn("basis.md", prompt)
        self.assertIn("stale", prompt.lower())

    def test_a_PLAIN_REOPEN_still_says_carry_on_where_it_stops(self):
        """The regression guard on the branch above: the reopen road is
        untouched, and its sentence is the one it always had."""
        self._drafted()
        self._restart_daemon()
        _st, body = self._post("/api/holodeck/open",
                               {"room": "command-palette"})
        self._set_turns({"stdout": "Widened it."})
        self._post("/api/holodeck/%s/say" % body["state"]["sessionId"],
                   {"text": "make it wider"})
        prompt = self._prompts()[-1]
        self.assertIn("do not start the mockup over", prompt)
        self.assertNotIn("binding", prompt.lower())


class DuplicateNamingTest(DuplicateBase):
    """TRAP 4. Names slug into DIRECTORY names, and a duplicate makes a
    collision likelier than anywhere else in the product: the obvious default
    name is derived from one that already exists. Two duplicates must land in
    two rooms, and an occupied room must be REFUSED, never overwritten."""

    def test_duplicating_TWICE_lands_in_two_different_rooms(self):
        self._sent()
        _st, first = self._dup()
        _st, second = self._dup()
        a, b = first["state"]["room"], second["state"]["room"]
        self.assertNotEqual(a, b)
        for room in (a, b):
            self.assertIn("transcript.md", self._snapshot(room))
        self.assertEqual(len(self._rooms()), 3, self._rooms())

    def test_the_second_duplicate_did_not_overwrite_the_first(self):
        self._sent()
        _st, first = self._dup()
        room = first["state"]["room"]
        sid = first["state"]["sessionId"]
        self._set_turns({"stdout": "Widened it.",
                         "writes": [{"path": "mockup.html",
                                     "content": "<h1>widened"}]})
        self._post("/api/holodeck/%s/say" % sid, {"text": "make it wider"})
        kept = self._snapshot(room)
        self._dup()
        self.assertEqual(self._snapshot(room), kept)

    def test_an_EXPLICIT_name_that_is_ALREADY_A_PROGRAMS_NAME_is_refused(self):
        """The one refusal left on the named road (fix round 1). A room being
        taken is walked past — two different names landing in one room is the
        `_SLUG_MAX` cut, not a clash, and refusing it told the captain to pick a
        different name about a name that already was one. A name that is
        ALREADY a program's name is a different thing: two cards he could not
        tell apart. Nothing is written over either way."""
        self._sent()
        before = self._snapshot("command-palette")
        st, body = self._dup(program="Command palette")
        self.assertEqual(st, 409, body)
        msg = body["error"]
        self.assertIn("command-palette", msg)
        self.assertIn("Command palette", msg)
        for jargon in ("traceback", "errno", "oserror", "409"):
            self.assertNotIn(jargon, msg.lower(), jargon)
        # NOTHING was written over, and no room was left behind by the refusal.
        self.assertEqual(self._snapshot("command-palette"), before)
        self.assertEqual(self._rooms(), ["command-palette"])

    def test_names_that_COLLAPSE_to_one_room_get_TWO_rooms_not_one(self):
        """The ledgered legacy: a name with no ASCII in it slugs to the shared
        `program` room. That is not cured here — but a duplicate must never land
        two programs in ONE room, so the second gets a room of its own and the
        first is left exactly as it was."""
        self._sent()
        st, first = self._dup(program="日本語")
        self.assertEqual(st, 200, first)
        room = first["state"]["room"]
        kept = self._snapshot(room)
        st, second = self._dup(program="中文")
        self.assertEqual(st, 200, second)
        self.assertNotEqual(second["state"]["room"], room)
        self.assertEqual(second["state"]["program"], "中文")
        # the first program is untouched, and each is a whole program.
        self.assertEqual(self._snapshot(room), kept)
        self.assertIn("mockup.html", self._snapshot(second["state"]["room"]))

    def test_the_chosen_name_is_the_programs_own_and_is_in_its_record(self):
        self._sent()
        _st, body = self._dup(program="Command palette, mark II")
        self.assertEqual(body["state"]["program"], "Command palette, mark II")
        chat = self._snapshot(body["state"]["room"])["transcript.md"].decode()
        self.assertTrue(chat.startswith("# Command palette, mark II"), chat[:80])


class DuplicateLineageTest(DuplicateBase):
    def test_the_duplicate_records_WHICH_program_and_WHICH_mission(self):
        self._sent()
        _st, body = self._dup()
        got = body["state"]["duplicatedFrom"]
        self.assertEqual(got["room"], "command-palette")
        self.assertEqual(got["program"], "Command palette")
        self.assertEqual(got["missionId"], self.mint)

    def test_a_duplicate_of_a_DRAFT_records_no_mission_rather_than_guessing(self):
        self._drafted()
        _st, body = self._dup()
        self.assertEqual(body["state"]["duplicatedFrom"]["missionId"], "")

    def test_an_ordinary_program_carries_no_lineage_key_at_all(self):
        self._sent()
        self.assertNotIn("duplicatedFrom", self._entry("command-palette"))

    def test_the_duplicate_of_a_duplicate_points_at_its_OWN_parent(self):
        self._sent()
        _st, first = self._dup()
        _st, second = self._dup(room=first["state"]["room"])
        self.assertEqual(second["state"]["duplicatedFrom"]["room"],
                         first["state"]["room"])


class LockedRefusalNamesTheBuiltRoadTest(DuplicateBase):
    def test_the_lock_no_longer_says_duplicate_is_unbuilt(self):
        """S127's refusal said "⧉ DUPLICATE TO KEEP DESIGNING … is not built
        yet, so for now start a new program under a different name". It is
        built now, and a product that describes its own road as missing is the
        one-voice defect this round would otherwise ship."""
        sid = self._sent()
        st, body = self._post_raw("/api/holodeck/%s/say" % sid,
                                  {"text": "make it wider"})
        self.assertEqual(st, 409, body)
        msg = body["error"]
        self.assertIn("DUPLICATE", msg.upper())
        self.assertNotIn("not built", msg.lower())
        self.assertNotIn("for now", msg.lower())


# ══ FIX ROUND 1 ═════════════════════════════════════════════════════════════
class DuplicateOfARealLengthNameTest(DuplicateBase):
    """D1 — THE ROOM IS THE THING THAT HAS TO BE DIFFERENTIATED.

    `_slug` caps a room at `_SLUG_MAX` (48) characters, and every program the
    captain actually has is named with his whole idea sentence — so a "(copy N)"
    differentiator that lives only in the DISPLAY NAME falls off the far side of
    the cut and every candidate room collapses back onto the SOURCE room. On his
    real program the measured result was: 500 tries, one distinct room, and that
    room was the source's. The blank-name road — the one the dialog itself
    recommends — spun 500 stats and reported "there are already hundreds of
    copies" with ZERO copies in existence.

    `DuplicateNamingTest` above could never see it: it names every program
    "Command palette" (15 characters), nowhere near the cap. So this suite uses
    the captain's REAL program name and nothing shorter.

    FIX ROUND 2 (F1) — AND IT NOW REALLY IS HIS. Fix round 1 wrote that
    sentence over a 51-character stand-in: past the 48-character cap, so D1 was
    genuinely exercised, but barely half the length of the name he actually has.
    A fixture that under-measures while its own docstring says it is the real
    thing is the ticked-but-false class this round keeps producing, so the
    string below is copied verbatim out of his archive
    (`groutwork-holodeck/give-the-tile-editor-a-more-modern-ui-look-and`) — 114
    characters. It is what turned up N1: the name guard is blind to a
    duplicate's room, and it is blind only once the room has to be TRIMMED to
    fit the marker, which a 51-character name never reaches.
    """

    # His actual program, verbatim, in room
    # `give-the-tile-editor-a-more-modern-ui-look-and`.
    LONG = ("Give the tile editor a more modern UI look and add a light/dark "
            "mode. I don't want to touch the tile canvas at all")

    def _src(self, sid):
        return os.path.basename(self.actions._holodeck[sid].program_dir)

    def test_two_duplicates_land_in_two_rooms_NEITHER_of_them_the_sources(self):
        sid = self._sent(program=self.LONG)
        src = self._src(sid)
        # the premise: the name really is at the cap, so this is the case the
        # short-name suite cannot reach.
        self.assertEqual(len(src), _SLUG_MAX - 2, src)
        kept = self._snapshot(src)
        st, first = self._dup(room=src)
        self.assertEqual(st, 200, first)
        st, second = self._dup(room=src)
        self.assertEqual(st, 200, second)
        a, b = first["state"]["room"], second["state"]["room"]
        self.assertNotEqual(a, src)
        self.assertNotEqual(b, src)
        self.assertNotEqual(a, b)
        self.assertEqual(sorted(self._rooms()), sorted([src, a, b]))
        # each copy is a whole program in its own right…
        for room in (a, b):
            self.assertIn("transcript.md", self._snapshot(room))
            self.assertIn("mockup.html", self._snapshot(room))
            # …its room still says which program it is a copy OF, and says it
            # is a copy, and stays inside the cap every other room obeys.
            self.assertLessEqual(len(room), _SLUG_MAX, room)
            self.assertIn("copy", room)
            self.assertTrue(room.startswith("give-the-tile-editor"), room)
        # and nothing was written into the one that was filed.
        self.assertEqual(self._snapshot(src), kept)

    def test_the_two_copies_are_told_apart_by_NAME_as_well_as_by_room(self):
        sid = self._sent(program=self.LONG)
        src = self._src(sid)
        _st, first = self._dup(room=src)
        _st, second = self._dup(room=src)
        names = [first["state"]["program"], second["state"]["program"]]
        self.assertNotEqual(names[0], names[1])
        for name in names:
            self.assertTrue(name.startswith(self.LONG), name)
            self.assertIn("copy", name.lower())

    def test_the_default_road_does_not_claim_it_ran_out_of_names(self):
        """The blank-name path is the one the dialog recommends, and on his real
        program it was the one that could not work at all."""
        sid = self._sent(program=self.LONG)
        st, body = self._dup(room=self._src(sid))
        self.assertEqual(st, 200, body)
        self.assertNotIn("run out of free names", json.dumps(body).lower())

    def test_an_EXPLICIT_long_name_that_only_COLLIDES_BY_TRUNCATION_is_kept(self):
        """A genuinely different name that happens to slug onto an occupied room
        is not a name clash — it is the 48-character cut. Refusing it told the
        captain to "duplicate it under a different name" about a name that WAS
        different."""
        sid = self._sent(program=self.LONG)
        src = self._src(sid)
        wanted = self.LONG + " version two"
        st, body = self._dup(room=src, program=wanted)
        self.assertEqual(st, 200, body)
        self.assertEqual(body["state"]["program"], wanted)
        self.assertNotEqual(body["state"]["room"], src)
        chat = self._snapshot(body["state"]["room"])["transcript.md"].decode()
        self.assertTrue(chat.startswith("# " + wanted), chat[:100])

    def test_the_lineage_chip_still_names_the_parent_it_came_from(self):
        sid = self._sent(program=self.LONG)
        _st, body = self._dup(room=self._src(sid))
        entry = self._entry(body["state"]["room"])
        self.assertEqual(entry["duplicatedFrom"]["room"], self._src(sid))
        self.assertEqual(entry["duplicatedFrom"]["program"], self.LONG)


class DuplicateBehavesEXACTLYAsItsSourceDoesTest(DuplicateBase):
    """D4 — a duplicate LAUNDERED a symlink through the preview jail.

    The copy loop skipped TOP-LEVEL symlinks (its comment: copying one "would
    put that same escape in a second room") and then handed subdirectories to
    `shutil.copytree(..., symlinks=False)`, which DEREFERENCES them. So the copy
    was BOTH more permissive and more lossy than the thing it copied, in the two
    directions at once:

      • a nested symlink out of the room became a REAL FILE in the duplicate —
        the original's preview correctly refused it and the duplicate served
        the bytes;
      • a top-level symlinked asset silently VANISHED from a copy the dialog
        promised carries "anything you pasted in".

    The rule is one sentence: A DUPLICATE BEHAVES EXACTLY AS ITS SOURCE DOES.
    Both directions are tested, because a cure for either one alone is the same
    defect facing the other way.
    """

    def _raw(self, path):
        """(status, body-bytes) — the preview route serves FILES, not JSON."""
        url = "http://127.0.0.1:%d%s" % (self.port, path)
        try:
            with urllib.request.urlopen(url, timeout=20) as r:
                return r.status, r.read()
        except urllib.error.HTTPError as exc:
            return exc.code, exc.read()

    def _preview(self, sid, rel):
        return self._raw("/api/holodeck/%s/preview/%s" % (sid, rel))

    def test_an_ESCAPING_symlink_is_refused_by_the_copy_as_by_the_source(self):
        src_sid = self._sent()
        outside = os.path.join(self.holo_root, "not-yours.html")
        with open(outside, "w") as fh:
            fh.write("<b>NOT YOURS</b>")
        os.symlink(outside, os.path.join(self._room("command-palette"),
                                         "attachments", "leak.html"))
        _st, body = self._dup()
        dup_sid, room = body["state"]["sessionId"], body["state"]["room"]
        # the SOURCE refuses it — that is the behaviour being matched.
        st, got = self._preview(src_sid, "attachments/leak.html")
        self.assertEqual(st, 403, got)
        self.assertNotIn(b"NOT YOURS", got)
        # …and so does the copy.
        st, got = self._preview(dup_sid, "attachments/leak.html")
        self.assertNotEqual(st, 200, got)
        self.assertNotIn(b"NOT YOURS", got)
        # it is still a LINK in the copy, not a laundered regular file.
        self.assertTrue(os.path.islink(
            os.path.join(self._room(room), "attachments", "leak.html")))

    def test_a_symlinked_ASSET_still_reaches_the_copy(self):
        """The same rule facing the other way: the dialog promises the copy
        carries "anything you pasted in", so an asset that is a link in the
        source must be there — and readable — in the copy."""
        src_sid = self._sent()
        os.symlink("mockup.html",
                   os.path.join(self._room("command-palette"), "shot.html"))
        st, want = self._preview(src_sid, "shot.html")
        self.assertEqual(st, 200, want)
        _st, body = self._dup()
        dup_sid, room = body["state"]["sessionId"], body["state"]["room"]
        st, got = self._preview(dup_sid, "shot.html")
        self.assertEqual(st, 200, got)
        self.assertEqual(got, want)
        # and it resolves to the COPY's own file, not back into the source.
        link = os.path.join(self._room(room), "shot.html")
        self.assertTrue(os.path.islink(link))
        self.assertEqual(os.path.realpath(link),
                         os.path.realpath(os.path.join(self._room(room),
                                                       "mockup.html")))

    def test_a_symlinked_DIRECTORY_out_of_the_room_is_not_laundered_either(self):
        src_sid = self._sent()
        outside = os.path.join(self.holo_root, "elsewhere")
        os.makedirs(outside)
        with open(os.path.join(outside, "x.html"), "w") as fh:
            fh.write("<b>NOT YOURS</b>")
        os.symlink(outside, os.path.join(self._room("command-palette"), "away"))
        st, got = self._preview(src_sid, "away/x.html")
        self.assertEqual(st, 403, got)
        _st, body = self._dup()
        st, got = self._preview(body["state"]["sessionId"], "away/x.html")
        self.assertNotEqual(st, 200, got)
        self.assertNotIn(b"NOT YOURS", got)

    def _rewritten_file_is_not_a_link(self, name):
        """The files the duplicate road EDITS must arrive as bytes, not links.

        Carried as a link, the write would go straight through it and edit
        whatever it points at — the source's own copy, or a file outside the
        room entirely, which is the one thing every other line in the copy loop
        is careful not to do.
        """
        self._sent()
        room = self._room("command-palette")
        elsewhere = os.path.join(self.holo_root, "not-in-any-room-" + name)
        os.rename(os.path.join(room, name), elsewhere)
        os.symlink(elsewhere, os.path.join(room, name))
        with open(elsewhere) as fh:
            before = fh.read()
        _st, body = self._dup()
        copy = os.path.join(self._room(body["state"]["room"]), name)
        self.assertFalse(os.path.islink(copy), name)
        with open(elsewhere) as fh:
            self.assertEqual(fh.read(), before, name)

    def test_the_RECORD_is_never_carried_as_a_link(self):
        """`_write_duplicate_record` gives the copy its own name and lineage."""
        self._rewritten_file_is_not_a_link("transcript.md")

    def test_the_BASIS_is_never_carried_as_a_link(self):
        """`_mark_basis_inherited` banners the copied grounding."""
        self._rewritten_file_is_not_a_link("basis.md")

    def test_an_ORDINARY_room_still_copies_as_real_bytes(self):
        """The control: nothing here turns the ordinary copy into links."""
        self._sent()
        _st, body = self._dup()
        room = self._room(body["state"]["room"])
        for rel in ("mockup.html", "concept.md",
                    os.path.join("attachments", "shot.png")):
            path = os.path.join(room, rel)
            self.assertTrue(os.path.isfile(path), rel)
            self.assertFalse(os.path.islink(path), rel)


class DuplicateSpeaksWithONEVoiceAboutTheBasisTest(DuplicateBase):
    """D2 — the prompt told the worker the OPPOSITE of trap 2, first and louder.

    S172 cured the deck three ways for the inherited basis and never touched
    `_basis_clause`, which still fired on a duplicate. In ONE prompt the worker
    read, in this order:

        START FROM THE GROUNDING: `basis.md` … is what LCARS read out of the
        captain's real project … READ IT FIRST and build to it

    and then, about a thousand characters later at the tail of a long
    paragraph, "One caution about the files: `basis.md` … may be STALE." Two
    voices, the wrong one first and in the imperative — and on a duplicate the
    first one is a claim about a project that has since moved.
    """

    def _dup_prompt(self):
        self._sent()
        _st, body = self._dup()
        self._set_turns({"stdout": "Widened it."})
        st, said = self._post(
            "/api/holodeck/%s/say" % body["state"]["sessionId"],
            {"text": "make it wider"})
        self.assertEqual(st, 200, said)
        return self._prompts()[-1]

    def test_the_duplicate_is_NOT_told_to_start_from_the_grounding(self):
        prompt = self._dup_prompt()
        self.assertNotIn("START FROM THE GROUNDING", prompt)
        self.assertNotIn("READ IT FIRST and build to it", prompt)

    def test_the_basis_is_called_INHERITED_and_STALE_exactly_once(self):
        prompt = self._dup_prompt()
        self.assertIn("INHERITED", prompt.upper())
        self.assertIn("stale", prompt.lower())
        # ONE voice: the caution is stated once, not once per clause.
        self.assertEqual(prompt.lower().count("may be stale"), 1, prompt)

    def test_the_worker_is_still_told_the_basis_is_THERE_and_worth_reading(self):
        """Not cured by deletion: the grounding is the one document that makes a
        design correctable, so the prompt must still point at it."""
        prompt = self._dup_prompt()
        self.assertIn("basis.md", prompt)

    def test_an_ORDINARY_grounded_program_gets_the_SAME_clause_it_always_had(self):
        """The regression guard on the branch above."""
        self._drafted()
        self._restart_daemon()
        _st, body = self._post("/api/holodeck/open",
                               {"room": "command-palette"})
        self._set_turns({"stdout": "Widened it."})
        self._post("/api/holodeck/%s/say" % body["state"]["sessionId"],
                   {"text": "make it wider"})
        prompt = self._prompts()[-1]
        self.assertIn("START FROM THE GROUNDING", prompt)
        self.assertIn("READ IT FIRST and build to it", prompt)
        self.assertNotIn("INHERITED", prompt.upper())
        self.assertNotIn("stale", prompt.lower())


class DuplicateRoomIsCLAIMEDNotJustCheckedTest(DuplicateBase):
    """D6 — two duplicates racing for one free room.

    Picking a free room and then creating it are two steps, and between them
    another request can win the same name. That surfaced as `FileExistsError`
    inside the makedirs guard and came out as a 502 "could not create the new
    program's room" — a plumbing failure reported for an ordinary collision the
    naming loop already knows how to walk past.

    The race is reproduced exactly, and deterministically, by making the room
    exist between the check and the create.
    """

    def _racing_makedirs(self, times=1):
        """`os.makedirs` that loses the room to a rival the first `times` calls
        — which is what a second duplicate landing in the gap looks like."""
        real = os.makedirs
        state = {"n": 0}

        def fake(path, *a, **kw):
            if state["n"] < times and os.path.dirname(path) == self._sidecar():
                state["n"] += 1
                real(path, *a, **kw)          # the rival wins it, for real
                raise FileExistsError(17, "File exists", path)
            return real(path, *a, **kw)
        return fake, state

    def test_a_lost_race_takes_the_NEXT_free_name_not_a_502(self):
        self._sent()
        fake, state = self._racing_makedirs()
        with unittest.mock.patch("os.makedirs", fake):
            st, body = self._dup()
        self.assertEqual(state["n"], 1)         # the race really happened
        self.assertEqual(st, 200, body)
        room = body["state"]["room"]
        self.assertNotEqual(room, "command-palette")
        self.assertIn("transcript.md", self._snapshot(room))

    def test_a_lost_race_on_an_EXPLICIT_name_keeps_the_NAME_and_moves_the_room(self):
        """The captain's name is his — a lost race moves the ROOM, never the
        name, and never reports plumbing at him."""
        self._sent()
        fake, state = self._racing_makedirs()
        with unittest.mock.patch("os.makedirs", fake):
            st, body = self._dup(program="Command palette, mark II")
        self.assertEqual(state["n"], 1)
        self.assertEqual(st, 200, body)
        self.assertEqual(body["state"]["program"], "Command palette, mark II")
        self.assertNotEqual(body["state"]["room"], "command-palette-mark-ii")
        self.assertIn("transcript.md", self._snapshot(body["state"]["room"]))

    def test_a_room_LOST_to_a_rival_is_never_written_into(self):
        """The whole point of claiming by creation: the loser must not put its
        mockup in the winner's room."""
        self._sent()
        fake, _state = self._racing_makedirs()
        with unittest.mock.patch("os.makedirs", fake):
            st, body = self._dup()
        self.assertEqual(st, 200, body)
        # the rival's room really exists and is still EMPTY — nothing was
        # copied into it on the way past.
        rival = os.path.join(self._sidecar(), "command-palette-copy")
        self.assertTrue(os.path.isdir(rival))
        self.assertEqual(os.listdir(rival), [])
        self.assertNotEqual(body["state"]["room"], "command-palette-copy")


# ══ FIX ROUND 2 ═════════════════════════════════════════════════════════════
class DuplicateNameGuardSeesTheCopysRoomTest(DuplicateBase):
    """N1 — the fix loop made the name guard blind to every duplicate's room.

    Fix round 1's D1 cure BUILDS a duplicate's room (trim the slug, then append
    the marker where the cut cannot eat it) while `_program_room` still SLUGS
    one — so on a name long enough to need trimming the two disagree, and the
    name guard was only ever looking in `_program_room(wanted)`. It therefore
    never looked in the room a duplicate actually lives in.

    The road is one the captain walks by hand: he copies the name the deck is
    showing him and types it into the dialog. Measured on his real program:
    HTTP 200, a second room, and a second card reading the same name as the
    first — while the guard's own message promises "Two cards with one name is a
    pair you cannot tell apart, so nothing has been copied."

    Driven on `DuplicateOfARealLengthNameTest`'s fixture — his real program
    name, the one string this is visible at. At "Command palette" the defect
    does not exist at all: nothing is trimmed, so `_program_room` and
    `_duplicate_room` agree and the guard looks in the right room by accident.
    """

    LONG = DuplicateOfARealLengthNameTest.LONG

    def _src(self, sid):
        return os.path.basename(self.actions._holodeck[sid].program_dir)

    def _dup_named(self, room, name):
        return self._dup(room=room, program=name)

    def test_the_name_the_deck_is_SHOWING_him_is_refused_not_duplicated(self):
        sid = self._sent(program=self.LONG)
        src = self._src(sid)
        _st, first = self._dup(room=src)
        shown = first["state"]["program"]        # what the card now reads
        copy_room = first["state"]["room"]
        # the premise: the copy's room is NOT the one its name slugs to, which
        # is the whole reason the guard could not see it.
        self.assertNotEqual(copy_room, _program_room(self._sidecar(), shown))
        rooms = self._rooms()
        st, body = self._dup_named(src, shown)
        self.assertEqual(st, 409, body)
        # …and it says WHERE the name already lives — the copy's room, not the
        # source's, which is the sentence that was wrong.
        self.assertIn(copy_room, body["error"])
        self.assertIn(shown, body["error"])
        # nothing was copied and no room was left behind by the refusal.
        self.assertEqual(self._rooms(), rooms)

    def test_no_two_cards_on_the_deck_can_end_up_reading_the_same_name(self):
        """The property the 409 exists for, asserted over the DECK rather than
        over the message: whatever the road, the program list never holds two
        names a captain cannot tell apart."""
        sid = self._sent(program=self.LONG)
        src = self._src(sid)
        _st, first = self._dup(room=src)
        shown = first["state"]["program"]
        self._dup_named(src, shown)              # refused, or not — either way
        self._dup_named(src, shown.upper())      # …and case is not a difference
        names = [p["program"] for p in self._list()["programs"]]
        self.assertEqual(len(names), len(set(n.lower() for n in names)), names)

    def test_the_BLANK_road_never_lands_on_a_name_he_typed_himself(self):
        """The same blindness one road over, and reachable without a race.

        `_claim_duplicate_room` walks free ROOMS and names each candidate
        "X (copy N)" — so if he has already typed that name onto a copy, and the
        `_SLUG_MAX` cut put it in some OTHER room, the blank road hands out a
        name that is already on the deck. Two cards, one name, one captain, no
        concurrency: exactly what the 409 beside it exists to prevent.
        """
        sid = self._sent(program=self.LONG)
        src = self._src(sid)
        st, typed = self._dup_named(src, self.LONG + " (copy)")
        self.assertEqual(st, 200, typed)
        st, blank = self._dup(room=src)
        self.assertEqual(st, 200, blank)
        self.assertNotEqual(blank["state"]["program"], typed["state"]["program"])
        names = [p["program"] for p in self._list()["programs"]]
        self.assertEqual(len(names), len(set(names)), names)

    def test_the_SOURCES_own_name_is_still_refused_from_its_own_room(self):
        """The case fix round 1 did catch, kept: a long name's own room is
        found by `_program_room` and must go on being refused."""
        sid = self._sent(program=self.LONG)
        src = self._src(sid)
        st, body = self._dup_named(src, self.LONG)
        self.assertEqual(st, 409, body)
        self.assertIn(src, body["error"])

    def test_a_name_that_is_NOBODYS_is_still_kept_exactly_as_typed(self):
        """The guard widened, not tightened: the only refusal is a name that is
        ALREADY a program's. A different name that merely collides on the
        48-character cut is still walked past and still kept verbatim."""
        sid = self._sent(program=self.LONG)
        src = self._src(sid)
        self._dup(room=src)
        wanted = self.LONG + " version two"
        st, body = self._dup_named(src, wanted)
        self.assertEqual(st, 200, body)
        self.assertEqual(body["state"]["program"], wanted)

    def test_the_guard_reads_a_ROOM_it_cannot_slug_its_way_to(self):
        """Directly on the helper: a program sitting in a room whose name has
        nothing to do with its own (the copy case, and every legacy room) is
        still found by name. `_program_room` alone can never reach it."""
        sid = self._sent(program=self.LONG)
        src = self._src(sid)
        _st, first = self._dup(room=src)
        sidecar = self._sidecar()
        self.assertEqual(
            self.actions._named_program_room(sidecar,
                                             first["state"]["program"]),
            first["state"]["room"])
        self.assertEqual(self.actions._named_program_room(sidecar, self.LONG),
                         src)
        self.assertEqual(
            self.actions._named_program_room(sidecar, "nobody's program"), "")


# ── S175: THE DESIGN DECLARES WHAT IT ASSUMES OF THE REPO ───────────────────
#
# MEASURED on lcars-20260814-001. The mockup draws an MBR builder in which 11 of
# 14 KPIs are collected AUTOMATICALLY — an amber "Update all automatically"
# sweep box, an AUTO tag per KPI, a per-KPI Collect → Collecting… → Updated
# cycle, an "as of <date>" stamp. DX-Scorecard's `data/config.json` carries 19
# KPIs and ZERO with a non-empty `aiUpdateInstructions`; every one is manual, an
# invariant its own ADR-002 and `src/config.ai-instructions.test.ts` enforce ON
# PURPOSE. Three tickets and most of a fourth built surfaces that repo can never
# display. Every gate green. The captain, clicking through, could not tell a
# broken build from a screen this repo cannot render — and neither could the
# session that studied it, until it opened the config.
#
# The cure is the same shape D4 already chose for flows and S174 chose for
# criteria: DECLARE IT, never infer it. The model that drew the picture is the
# only party that knows what the picture assumes, and it knows at the moment it
# draws; nothing downstream can reverse-engineer it out of the markup.
class S175DataPreconditionsContractTests(unittest.TestCase):
    """Part A — `_CONCEPT_CONTRACT` carries the DATA PRECONDITIONS section."""

    def contract(self):
        from lcars_serve.actions import _CONCEPT_CONTRACT
        return _CONCEPT_CONTRACT

    def test_the_contract_names_the_section(self):
        self.assertIn("## DATA PRECONDITIONS", self.contract())

    def test_it_is_STATED_never_inferred(self):
        """The FLOW section already earned this lesson and says so; the data
        section is worded the same way."""
        c = self.contract()
        self.assertIn("never inferred", c.lower())

    def test_an_unreachable_screen_is_named_as_the_cost(self):
        """Not "the screen is wrong" — UNREACHABLE. That distinction is the
        whole reason the captain could not diagnose it by clicking."""
        self.assertIn("UNREACHABLE", self.contract().upper())

    def test_each_precondition_is_ONE_CHECKABLE_SENTENCE(self):
        self.assertIn("ONE CHECKABLE SENTENCE", self.contract())

    def test_an_uncheckable_sentence_is_reported_back_UNCHECKED(self):
        self.assertIn("UNCHECKED", self.contract())

    def test_an_EMPTY_section_is_still_ALLOWED(self):
        """An empty section must stay legal — behaviour 1 requires Validate to
        be untouched by one, so the contract must never push a model into
        inventing preconditions it does not have.

        FIX ROUND 2 changed the WORDING this pins. It used to read "AN EMPTY
        SECTION IS CORRECT AND COMMON", last and emphatic, and a live turn took
        it on a design whose own header strip draws "18 of 27 On automatic".
        Permission survives; the advertisement that empty is the NORMAL case
        does not, and a disqualifier now sits in front of it."""
        c = self.contract()
        self.assertIn("EMPTY IS ALLOWED", c)
        self.assertNotIn("CORRECT AND COMMON", c)

    def test_an_empty_section_is_the_HEADING_AND_NOTHING(self):
        """The contract's own empty-bucket rule, restated here rather than
        assumed: never a bullet explaining why it is empty."""
        c = self.contract()
        low = c.lower()
        i = low.index("data preconditions")
        tail = c[i:]
        self.assertIn("NOTHING under it", tail)

    def test_it_carries_a_worked_example_of_a_precondition(self):
        """A section with no example is a section a model fills with prose."""
        self.assertIn("automated collection instruction", self.contract())



# ── S175 FIX ROUND 2: WHAT A LIVE HOLODECK ACTUALLY WROTE ──────────────────
#
# Four real turns on `claude-opus-4.8`, through a real daemon, grounded on the
# real DX-Scorecard (2026-08-26). Their concept.md files are fixtures at
# tests/fixtures/s175-live/. Three of the four sections were WRONG in a way the
# contract invited:
#
#   A  assumes repo data — wrote the heading and NOTHING. It had just written
#      four bucket-2 questions that are literally data assumptions ("the header
#      strip's counts … assume this data is queryable live"), on a design whose
#      own header draws "18 of 27 On automatic / 9 Still manual / 67%". It took
#      "AN EMPTY SECTION IS CORRECT AND COMMON" at its word.
#   C  wrote three good PLAIN SENTENCES, because the prose said "ONE CHECKABLE
#      SENTENCE EACH" while the form was shown only by backticked example.
#   A+C+D all stated SHAPE assumptions (a field exists) and NOT ONE stated the
#      assumption the screen is actually built on: that a substantial number of
#      KPIs are CURRENTLY on automatic. In a repo that HAS the fields and has
#      none populated, every one of their lines comes back TRUE and the
#      unreachable screen ships — the original failure, with the feature on.
class S175FixRound2ContractTests(unittest.TestCase):
    """The contract states the FORM as a rule, disqualifies a lazy empty, keeps
    its own hands off bucket 2, and asks for VALUES as well as fields."""

    def contract(self):
        from lcars_serve.actions import _CONCEPT_CONTRACT
        return _CONCEPT_CONTRACT

    def section(self):
        c = self.contract()
        return c[c.index("## DATA PRECONDITIONS"):]

    # 2a — the form is a RULE, not an example the prose contradicts
    def test_the_form_is_stated_as_a_rule(self):
        self.assertIn("MARKDOWN BULLET", self.section())

    def test_the_rule_is_shown_in_the_form_it_asks_for(self):
        """A worked example that IS a bullet, so the shape and the words agree."""
        self.assertIn("- most KPIs carry an automated collection instruction",
                      self.section())

    def test_one_checkable_sentence_each_survives_as_the_content_rule(self):
        self.assertIn("ONE CHECKABLE SENTENCE", self.section())

    # 2b — empty is allowed, but no longer advertised as the common case
    def test_empty_is_no_longer_called_COMMON(self):
        """'CORRECT AND COMMON' was last, emphatic, and granted permission —
        and the live turn A took it on a data-dependent design."""
        self.assertNotIn("CORRECT AND COMMON", self.section())

    def test_empty_is_still_ALLOWED(self):
        self.assertIn("EMPTY IS ALLOWED", self.section())

    def test_the_disqualifier_is_stated(self):
        sec = self.section()
        self.assertIn("count", sec.lower())
        self.assertIn("THIS SECTION IS NOT EMPTY", sec)

    def test_the_disqualifier_comes_BEFORE_the_permission_to_be_empty(self):
        """Turn A read the permission last. Order is the fix."""
        sec = self.section()
        self.assertLess(sec.index("THIS SECTION IS NOT EMPTY"),
                        sec.index("EMPTY IS ALLOWED"))

    # 2c — the bucket-2 boundary, said out loud
    def test_it_says_which_way_the_bucket_2_split_goes(self):
        sec = self.section()
        self.assertIn("bucket 2", sec)
        self.assertIn("ONE-HOME-EACH", sec)

    def test_a_repo_data_assumption_belongs_here_even_if_also_asked(self):
        self.assertIn("even if you also asked about it", self.section())

    # 2d — a promise became an instruction
    def test_it_asks_the_model_to_NAME_the_field_or_file(self):
        sec = self.section()
        self.assertIn("NAME THE FIELD OR THE FILE YOU EXPECT", sec)

    def test_it_still_warns_that_an_uncheckable_line_comes_back_UNCHECKED(self):
        self.assertIn("UNCHECKED", self.section())

    # 3 — the gap every live turn shared
    def test_it_asks_for_the_VALUES_assumption_not_only_the_fields(self):
        sec = self.section()
        self.assertIn("THE VALUES", sec)
        self.assertIn("NOT ONLY THE FIELDS", sec)

    def test_it_names_the_populated_but_empty_repo_as_the_reason(self):
        """A repo can have every field named and none of them filled in."""
        self.assertIn("none of them filled in", self.section())

    def test_it_gives_the_worked_VALUES_example_from_the_measurement(self):
        self.assertIn("CURRENTLY on automatic", self.section())

    # what must not regress from round 1
    def test_it_still_says_STATED_never_inferred(self):
        self.assertIn("never inferred", self.contract().lower())

    def test_it_still_names_UNREACHABLE_as_the_cost(self):
        self.assertIn("UNREACHABLE", self.contract().upper())

    def test_the_declaration_principle_survives_the_trim(self):
        """FIX ROUND 3 cut the two rationale paragraphs — argument aimed at a
        source reader, sitting in the tail position turn A demonstrably weights
        most. The PRINCIPLE stays, in one line instead of four: a model can act
        on "write it down", not on an explanation of why the pipeline needs it."""
        self.assertIn("STATED, never inferred", self.section())

    def test_an_empty_section_is_still_the_heading_and_NOTHING(self):
        self.assertIn("NOTHING under it", self.section())

    def test_the_bucket_stays_short(self):
        """FIX ROUND 3 trimmed it 37 -> 24 lines. It was the longest bucket in
        the contract, and VALUES — the instruction all four live turns dropped —
        was last, longest and most abstract. Length is the failure mode."""
        self.assertLessEqual(len(self.section().rstrip("\n").split("\n")), 26)

    def test_the_numbered_sub_items_are_gone(self):
        """The 1./2. numbering inside a bucket that had just demanded markdown
        bullets is what invited a live model to express the split as `### Shape`
        / `### Values` sub-headings — which the parser then shipped to the
        Validator as preconditions (D-C)."""
        sec = self.section()
        self.assertNotIn("1. THE SHAPE", sec)
        self.assertNotIn("2. THE VALUES", sec)


if __name__ == "__main__":
    unittest.main()

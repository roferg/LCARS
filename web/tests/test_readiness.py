"""S146 — test-readiness legibility on the viewscreen.

Covers:
  • the ADDITIVE meta.testReadiness block (LocalAdapter): present with
    {status, suggestion, testCommand} when unready, ABSENT when ready (old
    payloads byte-identical), degraded to absent on any helper failure;
  • the /api/config/* write endpoints: dispatch to `lcars update`'s verbs via
    the SCRIPT_ENV seam (argv recorded — the daemon never reimplements config
    logic in Python), CLI/endpoint convergence on config.json, plain-English
    failures, read-only 403s;
  • the front-end surfaces via the node-vm harness
    (board_readiness_harness.js): the banner strip (repair vs bootstrap voice,
    read-only affordance hiding, zero UI when ready) and the File console
    (warning above the idea box, ⚡ FIX one-click walk, manual override, SSE
    re-verdict clearing in place with the typed idea preserved, filing/parking
    never blocked).

stdlib only; NO model/gh spend — every skill dispatch is a recording stub.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from tests import _fixtures as fx  # noqa: E402
from lcars_serve.local_adapter import LocalAdapter  # noqa: E402
from lcars_serve.server import make_server  # noqa: E402
from lcars_serve.actions import Actions, ActionError  # noqa: E402

_HARNESS = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                        "board_readiness_harness.js")
_REPO_ROOT = os.path.normpath(os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", ".."))
_UPDATE_SH = os.path.join(_REPO_ROOT, "skills", "lcars-update", "update.sh")


def _readiness_stub(tmp, payload):
    """A stub readiness.sh printing `payload` (a JSON-able dict) for --json."""
    path = os.path.join(tmp, "readiness-stub.sh")
    with open(path, "w") as fh:
        fh.write("#!/usr/bin/env bash\n"
                 "printf '%s\\n' '" + json.dumps(payload) + "'\n")
    os.chmod(path, 0o755)
    return path


def _touch_config(tmp):
    cfg = os.path.join(tmp, ".git", "lcars", "config.json")
    os.makedirs(os.path.dirname(cfg), exist_ok=True)
    with open(cfg, "w") as fh:
        fh.write('{\n  "testCommand": null\n}\n')
    return cfg


MISSING = {"status": "missing", "suggestion": "make test", "testCommand": None}
BROKEN = {"status": "broken", "suggestion": None,
          "testCommand": "gulp-legacy test"}
UNKNOWN = {"status": "unknown", "suggestion": None, "testCommand": None}
READY = {"status": "ready", "suggestion": None, "testCommand": "make test"}
# S147 (carried S146 defect): a repo with SEVERAL stacks — real test systems,
# just more than one — is NOT greenfield. It gets its own CHOOSE voice, and
# `candidates` carries the pickable commands so choosing costs ZERO tokens
# (the old ⚡ FIX here dispatched a PAID discovery worker to choose, which is
# exactly what the "LCARS will not choose for you" line promised it would not).
# FIX ROUND 1 / D3 — the SECOND AXIS the board ignored. `readinessCopy`
# branched on `status === "unknown"` alone and printed the greenfield bootstrap
# line over a tested npm-workspaces monorepo, with ▦ FILE MISSION enabled
# beside it. These three carry the same `unknown` status and three different
# foundations, and each must read TRUE.
UNKNOWN_UNCONFIGURED = {"status": "unknown", "suggestion": None,
                        "testCommand": None, "foundation": "unconfigured",
                        "foundationWhy": "a test framework in package.json"}
UNKNOWN_UNTESTED = {"status": "unknown", "suggestion": None,
                    "testCommand": None, "foundation": "untested",
                    "foundationWhy": "this repo has code and no test system"}
UNKNOWN_GREENFIELD = {"status": "unknown", "suggestion": None,
                      "testCommand": None, "foundation": "greenfield",
                      "foundationWhy": "this repo is empty"}
# and the npm-default placeholder: a DETECTED candidate over no test system.
MISSING_UNTESTED = {"status": "missing",
                    "suggestion": 'npm test -- ${LCARS_TESTS_DIR:-}',
                    "testCommand": None, "foundation": "untested",
                    "foundationWhy": "this repo has code and no test system"}
AMBIGUOUS = {"status": "ambiguous", "suggestion": None, "testCommand": None,
             "stacks": "rust,js",
             "candidates": ["cargo test", "npm test -- ${LCARS_TESTS_DIR:-}"]}
# the same verdict reached through ONE stack that cannot pin its runner — a
# dotnet repo with two test projects (D6).
AMBIGUOUS_DOTNET = {
    "status": "ambiguous", "suggestion": None, "testCommand": None,
    "stacks": "tests/A.Tests/A.Tests.csproj,tests/B.Tests/B.Tests.csproj",
    "candidates": ["dotnet test tests/A.Tests/A.Tests.csproj",
                   "dotnet test tests/B.Tests/B.Tests.csproj"]}


class TestMetaTestReadiness(unittest.TestCase):
    """The additive meta block — absent when ready, present when unready."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        fx.plant_simple(self.tmp, "m-001", stage="align")
        _touch_config(self.tmp)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def _meta(self, payload):
        stub = _readiness_stub(self.tmp, payload)
        adapter = LocalAdapter(self.tmp, readiness_script=stub)
        return adapter.board()["meta"]

    def test_ready_repo_has_no_testReadiness_key_at_all(self):
        meta = self._meta(READY)
        self.assertNotIn("testReadiness", meta)

    def test_ready_meta_byte_identical_to_pre_s146_shape(self):
        # a ready repo's meta serialises byte-identically whether or not the
        # readiness helper exists (zero payload drift on ready repos).
        meta_ready = self._meta(READY)
        broken_script = os.path.join(self.tmp, "nonexistent.sh")
        adapter = LocalAdapter(self.tmp, readiness_script=broken_script)
        meta_degraded = adapter.board()["meta"]
        self.assertEqual(json.dumps(meta_ready, sort_keys=True),
                         json.dumps(meta_degraded, sort_keys=True))

    def test_missing_carries_status_suggestion_testcommand(self):
        meta = self._meta(MISSING)
        self.assertEqual(meta["testReadiness"],
                         {"status": "missing", "suggestion": "make test",
                          "testCommand": None})

    def test_broken_carries_the_stored_command(self):
        meta = self._meta(BROKEN)
        self.assertEqual(meta["testReadiness"]["status"], "broken")
        self.assertEqual(meta["testReadiness"]["testCommand"],
                         "gulp-legacy test")

    def test_unknown_greenfield_present_with_no_suggestion(self):
        meta = self._meta(UNKNOWN)
        self.assertEqual(meta["testReadiness"]["status"], "unknown")
        self.assertIsNone(meta["testReadiness"]["suggestion"])
        # S147: `stacks`/`candidates` ride ONLY the ambiguous verdict — every
        # other payload stays byte-identical to S146.
        self.assertNotIn("stacks", meta["testReadiness"])
        self.assertNotIn("candidates", meta["testReadiness"])

    def test_ambiguous_forwards_the_candidate_stacks(self):
        meta = self._meta(AMBIGUOUS)
        self.assertEqual(meta["testReadiness"], dict(AMBIGUOUS))

    def test_ambiguous_forwards_the_pickable_candidate_commands(self):
        # Without these the board can only offer ⚡ FIX, which for this state
        # dispatches a paid discovery worker to make the choice LCARS just
        # said it would not make.
        meta = self._meta(AMBIGUOUS_DOTNET)
        self.assertEqual(meta["testReadiness"]["candidates"],
                         AMBIGUOUS_DOTNET["candidates"])

    def test_helper_garbage_degrades_to_absent(self):
        path = os.path.join(self.tmp, "garbage.sh")
        with open(path, "w") as fh:
            fh.write("#!/usr/bin/env bash\necho 'not json at all'\n")
        os.chmod(path, 0o755)
        adapter = LocalAdapter(self.tmp, readiness_script=path)
        self.assertNotIn("testReadiness", adapter.board()["meta"])

    def test_config_write_moves_the_fingerprint(self):
        # the sanctioned setter rewrites config.json; SSE must push, so the
        # fingerprint must move on a config-only change.
        stub = _readiness_stub(self.tmp, READY)
        adapter = LocalAdapter(self.tmp, readiness_script=stub)
        before = adapter.fingerprint()
        cfg = os.path.join(self.tmp, ".git", "lcars", "config.json")
        with open(cfg, "w") as fh:
            fh.write('{\n  "testCommand": "make test"\n}\n')
        future = os.path.getmtime(cfg) + 10
        os.utime(cfg, (future, future))
        self.assertNotEqual(before, adapter.fingerprint())


def _tracking_stub(tmp):
    """A stub readiness.sh whose verdict REFLECTS the repo it runs in (cwd —
    `missing` + the make candidate when a Makefile exists, `unknown` otherwise)
    and which counts every invocation, so tests can assert the memo bounds the
    shell-outs."""
    path = os.path.join(tmp, "readiness-tracking.sh")
    counter = os.path.join(tmp, "readiness-calls.txt")
    with open(path, "w") as fh:
        fh.write(
            "#!/usr/bin/env bash\n"
            "echo run >> '" + counter + "'\n"
            "if [ -f Makefile ]; then\n"
            "  printf '%s\\n' '" + json.dumps(MISSING) + "'\n"
            "else\n"
            "  printf '%s\\n' '" + json.dumps(UNKNOWN) + "'\n"
            "fi\n")
    os.chmod(path, 0o755)
    return path, counter


class TestBoardVerdictStaleness(unittest.TestCase):
    """D2 (S146 fix loop): the readiness memo must invalidate when
    detection-relevant repo state changes (a stack/runner marker file
    appearing, changing, or vanishing), not only on config.json's mtime —
    the CLI verdict (readiness.sh) and the board must never disagree.
    Bounded: NO-change requests never re-shell the helper (SSE polls
    /api/board frequently), asserted via the stub's call count."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        fx.plant_simple(self.tmp, "m-001", stage="align")
        _touch_config(self.tmp)
        self.stub, self.counter = _tracking_stub(self.tmp)
        self.adapter = LocalAdapter(self.tmp, readiness_script=self.stub)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def _calls(self):
        try:
            with open(self.counter) as fh:
                return len(fh.read().splitlines())
        except OSError:
            return 0

    def _makefile(self):
        return os.path.join(self.tmp, "Makefile")

    def test_marker_appearing_reverdicts_next_board(self):
        # greenfield first: the board says unknown, matching the CLI.
        meta = self.adapter.board()["meta"]
        self.assertEqual(meta["testReadiness"]["status"], "unknown")
        # a Makefile lands (config.json untouched) — the CLI verdict flips to
        # missing with the candidate; the NEXT board must agree.
        with open(self._makefile(), "w") as fh:
            fh.write("test:\n\t@echo ok\n")
        meta = self.adapter.board()["meta"]
        self.assertEqual(meta["testReadiness"]["status"], "missing")
        self.assertEqual(meta["testReadiness"]["suggestion"], "make test")

    def test_marker_appearing_moves_the_fingerprint(self):
        before = self.adapter.fingerprint()
        with open(self._makefile(), "w") as fh:
            fh.write("test:\n\t@echo ok\n")
        self.assertNotEqual(before, self.adapter.fingerprint(),
                            "a detection-marker appearing must move the "
                            "fingerprint so SSE pushes an update to passive "
                            "browsers")

    def test_marker_vanishing_reverdicts_and_moves_fingerprint(self):
        with open(self._makefile(), "w") as fh:
            fh.write("test:\n\t@echo ok\n")
        self.assertEqual(
            self.adapter.board()["meta"]["testReadiness"]["status"], "missing")
        fp_with = self.adapter.fingerprint()
        os.remove(self._makefile())
        self.assertEqual(
            self.adapter.board()["meta"]["testReadiness"]["status"], "unknown")
        self.assertNotEqual(fp_with, self.adapter.fingerprint(),
                            "a marker vanishing must move the fingerprint too")

    def test_nested_dotnet_project_moves_the_fingerprint(self):
        # S147/D5: `dotnet new xunit -o MyApp.Tests` writes the ONLY project one
        # directory down with no root solution. detect_stack now sees that
        # (bounded recursion), so the board's marker memo has to see it too —
        # otherwise a C# repo's verdict goes stale against the CLI's, which is
        # exactly the divergence the S146 D2 contract forbids.
        before = self.adapter.fingerprint()
        d = os.path.join(self.tmp, "MyApp.Tests")
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "MyApp.Tests.csproj"), "w") as fh:
            fh.write('<Project Sdk="Microsoft.NET.Sdk"></Project>\n')
        self.assertNotEqual(before, self.adapter.fingerprint(),
                            "a csproj one directory down is a detection "
                            "marker for the CLI, so it must move the memo")

    def test_dotnet_build_output_is_not_a_marker(self):
        # obj/ carries a copy of the csproj on every build; counting it would
        # re-verdict (and re-shell) on every compile.
        d = os.path.join(self.tmp, "App", "obj", "Debug")
        os.makedirs(d, exist_ok=True)
        before = self.adapter.fingerprint()
        with open(os.path.join(d, "App.csproj"), "w") as fh:
            fh.write('<Project Sdk="Microsoft.NET.Sdk"></Project>\n')
        self.assertEqual(before, self.adapter.fingerprint(),
                         "obj/ build output must not be a detection marker")

    def test_no_change_requests_do_not_reshell(self):
        for _ in range(5):
            self.adapter.board()
        self.assertEqual(self._calls(), 1,
                         "5 unchanged board renders must shell readiness ONCE")
        with open(self._makefile(), "w") as fh:
            fh.write("test:\n\t@echo ok\n")
        for _ in range(5):
            self.adapter.board()
        self.assertEqual(self._calls(), 2,
                         "one marker change re-shells exactly once more")


def _record_stub(record_path, exit_code=0, stdout=""):
    """A bash stub recording argv + stdin, echoing `stdout`, exiting
    `exit_code`."""
    fd, path = tempfile.mkstemp(suffix=".sh")
    os.close(fd)
    script = (
        '#!/usr/bin/env bash\n'
        '{ printf "ARGV: %s\\n" "$*"; } >> "' + record_path + '"\n'
        + ('printf "%s\\n" ' + json.dumps(stdout) + '\n' if stdout else '')
        + 'exit ' + str(exit_code) + '\n'
    )
    with open(path, "w") as fh:
        fh.write(script)
    os.chmod(path, 0o755)
    return path


class ConfigEndpointBase(unittest.TestCase):
    exit_code = 0
    stdout = "  ✓ TEST SYSTEMS ONLINE — missions will be proof-gated with: make test"

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        fx.plant_simple(self.tmp, "m-001", stage="align")
        _touch_config(self.tmp)
        self.adapter = LocalAdapter(
            self.tmp, readiness_script=_readiness_stub(self.tmp, READY))
        self.record = os.path.join(self.tmp, "rec-update.txt")
        self.scripts = {
            "update": _record_stub(self.record, self.exit_code, self.stdout),
        }
        self.actions = Actions(repo_root=self.tmp, scripts=self.scripts)
        # keep the Actions' internal reader cheap + deterministic too.
        self.actions._reader = self.adapter
        self.httpd = make_server(self.adapter, host="127.0.0.1", port=0,
                                 poll_interval=0.05, actions=self.actions)
        self.port = self.httpd.server_address[1]
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    def tearDown(self):
        self.httpd.shutdown()
        self.httpd.server_close()
        shutil.rmtree(self.tmp, ignore_errors=True)

    def _post(self, path, obj=None):
        url = "http://127.0.0.1:%d%s" % (self.port, path)
        data = json.dumps(obj if obj is not None else {}).encode("utf-8")
        req = urllib.request.Request(
            url, data=data, method="POST",
            headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=10) as r:
                return r.status, json.loads(r.read())
        except urllib.error.HTTPError as e:
            return e.code, json.loads(e.read())

    def _rec(self):
        if not os.path.exists(self.record):
            return ""
        with open(self.record) as fh:
            return fh.read()


class TestConfigEndpointsDispatch(ConfigEndpointBase):
    def test_fix_tests_dispatches_the_fix_verb(self):
        status, body = self._post("/api/config/fix-tests")
        self.assertEqual(status, 200)
        self.assertTrue(body["ok"])
        self.assertIn("ARGV: --fix-tests", self._rec())
        # the script's own report rides the response for the console/banner.
        self.assertIn("TEST SYSTEMS ONLINE", body["state"]["output"])
        # and the fresh board rides along (re-verdicted meta).
        self.assertIn("board", body["state"])

    def test_test_command_dispatches_the_setter_verb(self):
        status, body = self._post("/api/config/test-command",
                                  {"testCommand": "make test"})
        self.assertEqual(status, 200)
        self.assertTrue(body["ok"])
        self.assertIn("ARGV: --test-command make test", self._rec())

    def test_probe_tests_dispatches_the_probe_verb(self):
        status, body = self._post("/api/config/probe-tests")
        self.assertEqual(status, 200)
        self.assertIn("ARGV: --probe-tests", self._rec())

    def test_empty_test_command_rejected_before_dispatch(self):
        status, body = self._post("/api/config/test-command",
                                  {"testCommand": "   "})
        self.assertEqual(status, 400)
        self.assertFalse(body["ok"])
        self.assertIn("empty test command", body["error"])
        self.assertEqual(self._rec(), "")  # stub never invoked

    def test_cli_and_endpoint_converge_byte_identically_on_config(self):
        """The endpoint IS the CLI verb: running update.sh --test-command via
        the endpoint and via a direct CLI call produce byte-identical
        config.json files (the ONE sanctioned writer, no Python reimpl)."""
        def make_repo():
            repo = tempfile.mkdtemp()
            subprocess.run(["git", "init", "-q"], cwd=repo, check=True)
            cfg = os.path.join(repo, ".git", "lcars", "config.json")
            os.makedirs(os.path.dirname(cfg))
            with open(cfg, "w") as fh:
                fh.write('{\n  "model": "claude-sonnet",\n'
                         '  "testCommand": null,\n'
                         '  "created": "2020-01-01T00:00:00Z"\n}\n')
            return repo, cfg

        repo_a, cfg_a = make_repo()
        repo_b, cfg_b = make_repo()
        try:
            # endpoint path (real update.sh wired through Actions)
            actions = Actions(repo_root=repo_a,
                              scripts={"update": _UPDATE_SH})
            actions.set_test_command("echo converge")
            # CLI path
            subprocess.run(["bash", _UPDATE_SH, "--test-command",
                            "echo converge"],
                           cwd=repo_b, check=True,
                           stdout=subprocess.DEVNULL,
                           stderr=subprocess.STDOUT)
            with open(cfg_a, "rb") as fa, open(cfg_b, "rb") as fb:
                self.assertEqual(fa.read(), fb.read())
        finally:
            shutil.rmtree(repo_a, ignore_errors=True)
            shutil.rmtree(repo_b, ignore_errors=True)


class TestConfigEndpointFailure(ConfigEndpointBase):
    exit_code = 1
    stdout = ("  ⚠ TEST SYSTEMS SET BUT UNVERIFIED — the command is "
              "configured, but the probe reported fail; not declaring ready.")

    def test_failure_surfaces_the_scripts_plain_report(self):
        status, body = self._post("/api/config/fix-tests")
        self.assertEqual(status, 502)
        self.assertFalse(body["ok"])
        self.assertIn("SET BUT UNVERIFIED", body["error"])
        # plain English, never a stack trace / raw internals.
        self.assertNotIn("Traceback", body["error"])
        self.assertNotIn("exited", body["error"])


class TestProbeOutcomeStatus(ConfigEndpointBase):
    def test_a_real_failing_suite_is_a_409_not_a_server_fault(self):
        subprocess.run(["git", "init", "-q", self.tmp], check=True)
        cfg = os.path.join(self.tmp, ".git", "lcars", "config.json")
        with open(cfg, "w") as fh:
            json.dump({"testCommand": "printf 'suite failed\\n'; exit 1"}, fh)
        self.actions.scripts["update"] = _UPDATE_SH
        status, body = self._post("/api/config/probe-tests")
        self.assertEqual(status, 409, body)
        self.assertFalse(body["ok"])
        self.assertIn("PROBE FAILED", body["error"])
        self.assertIn("suite failed", body["error"])

    def test_only_the_refusal_envelope_is_a_409(self):
        for code, output, expected in (
                (1, "lcars update: arbitrary refusal wording", 409),
                (1, "a traceback that never went through die", 502),
                (127, "lcars update: missing binary", 502),
                (2, "lcars update: syntax error", 502)):
            with self.subTest(code=code, output=output):
                self.actions.scripts["update"] = _record_stub(
                    self.record, code, output)
                status, body = self._post("/api/config/probe-tests")
                self.assertEqual(status, expected, body)
                self.assertFalse(body["ok"])


class TestConfigEndpointsReadOnly(unittest.TestCase):
    """A read-only build 403s every new write endpoint."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        fx.plant_simple(self.tmp, "m-001", stage="align")
        adapter = LocalAdapter(
            self.tmp, read_only=True,
            readiness_script=_readiness_stub(self.tmp, READY))
        self.httpd = make_server(adapter, host="127.0.0.1", port=0,
                                 poll_interval=0.05, actions=None)
        self.port = self.httpd.server_address[1]
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    def tearDown(self):
        self.httpd.shutdown()
        self.httpd.server_close()
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_all_three_endpoints_403(self):
        import urllib.error
        for path in ("/api/config/fix-tests", "/api/config/test-command",
                     "/api/config/probe-tests"):
            req = urllib.request.Request(
                "http://127.0.0.1:%d%s" % (self.port, path),
                data=b"{}", method="POST",
                headers={"Content-Type": "application/json"})
            try:
                with urllib.request.urlopen(req, timeout=10) as r:
                    self.fail("expected 403 for %s, got %d" % (path, r.status))
            except urllib.error.HTTPError as e:
                self.assertEqual(e.code, 403, path)


def _run_harness(mode, tr, readonly=False, foundation=None, holodeck=None):
    fd, path = tempfile.mkstemp(suffix=".json")
    with os.fdopen(fd, "w") as fh:
        json.dump({"tr": tr, "foundation": foundation,
                   "holodeck": holodeck}, fh)
    argv = ["node", _HARNESS, mode, path]
    if readonly:
        argv.append("readonly")
    try:
        proc = subprocess.run(argv, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, timeout=60)
    finally:
        os.unlink(path)
    if proc.returncode != 0:
        raise AssertionError("harness failed: %s" %
                             proc.stderr.decode("utf-8", "replace"))
    return json.loads(proc.stdout.decode("utf-8"))


def _flatten(node, out=None):
    if out is None:
        out = []
    if node:
        out.append(node)
        for c in node.get("children", []):
            _flatten(c, out)
    return out


def _texts(node):
    return " | ".join(n["text"] for n in _flatten(node) if n.get("text"))


def _find_cls(node, cls):
    return [n for n in _flatten(node) if cls in (n.get("cls") or "").split()]


class TestBannerRender(unittest.TestCase):
    """The band strip: repair vs bootstrap voice, ready ⇒ zero UI."""

    def test_ready_absent_block_renders_nothing(self):
        res = _run_harness("banner", None)
        self.assertTrue(res["hidden"])
        self.assertEqual(res["banner"]["children"], [])

    def test_broken_shows_repair_voice_with_fix_button(self):
        res = _run_harness("banner", BROKEN)
        self.assertFalse(res["hidden"])
        txt = _texts(res["banner"])
        self.assertIn("TEST SYSTEMS OFFLINE", txt)
        self.assertIn("⚡ FIX TEST SYSTEMS", txt)
        self.assertIn("gulp-legacy test", txt)

    def test_missing_shows_suggestion_and_fix(self):
        res = _run_harness("banner", MISSING)
        txt = _texts(res["banner"])
        self.assertIn("TEST SYSTEMS OFFLINE", txt)
        self.assertIn("make test", txt)
        self.assertIn("⚡ FIX TEST SYSTEMS", txt)

    def test_unknown_shows_bootstrap_voice_no_action_item(self):
        res = _run_harness("banner", UNKNOWN)
        txt = _texts(res["banner"])
        self.assertIn("engineering crew", txt)
        self.assertNotIn("OFFLINE", txt)
        self.assertNotIn("FIX TEST SYSTEMS", txt)
        # the two voices must never blur.
        repair = _texts(_run_harness("banner", BROKEN)["banner"])
        self.assertNotEqual(txt, repair)

    def test_unconfigured_repo_is_never_called_greenfield(self):
        """FIX ROUND 1 / D3. MEASURED on a real npm-workspaces monorepo with
        three tested packages: the board read "◇ NO TEST SYSTEMS FOUND … Start
        it with Establish Vision" while ▦ FILE MISSION sat enabled beside it.
        The CLI line was already cured; the board ignored the `foundation` in
        the same payload."""
        txt = _texts(_run_harness("banner", UNKNOWN_UNCONFIGURED)["banner"])
        self.assertNotIn("NO TEST SYSTEMS FOUND", txt)
        self.assertNotIn("engineering crew", txt)
        self.assertNotIn("Establish Vision", txt)
        self.assertIn("HAS a test system", txt)
        self.assertIn("a test framework in package.json", txt)

    def test_untested_repo_reads_as_code_without_tests(self):
        """`untested` is not greenfield either — the repo already exists."""
        txt = _texts(_run_harness("banner", UNKNOWN_UNTESTED)["banner"])
        self.assertNotIn("NO TEST SYSTEMS FOUND", txt)
        self.assertIn("code", txt)
        self.assertIn("Establish Vision", txt)

    def test_greenfield_keeps_the_shipped_bootstrap_voice(self):
        txt = _texts(_run_harness("banner", UNKNOWN_GREENFIELD)["banner"])
        self.assertIn("NO TEST SYSTEMS FOUND", txt)
        self.assertIn("engineering crew", txt)

    def test_a_placeholder_test_script_is_not_a_detected_candidate(self):
        """The npm-default `"test": "echo … && exit 1"` produces a DETECTED
        candidate over a repo with no test system. Offering it as one while the
        band controls are locked tells the captain two different stories."""
        txt = _texts(_run_harness("banner", MISSING_UNTESTED)["banner"])
        self.assertNotIn("detected candidate", txt)
        self.assertIn("code", txt)

    def test_ambiguous_is_never_the_greenfield_bootstrap_voice(self):
        # S147: the defect this closes — an ambiguous repo WITH test infra used
        # to render "NO TEST SYSTEMS FOUND / the crew will establish them",
        # which is false. It must read as a choice the captain has to make.
        res = _run_harness("banner", AMBIGUOUS)
        txt = _texts(res["banner"])
        self.assertNotIn("engineering crew", txt)
        self.assertNotIn("NO TEST SYSTEMS FOUND", txt)
        self.assertIn("MULTIPLE TEST SYSTEMS DETECTED", txt)
        self.assertIn("rust,js", txt)
        # …while still differing from BOTH neighbouring voices.
        self.assertNotEqual(txt, _texts(_run_harness("banner", UNKNOWN)["banner"]))
        self.assertNotEqual(txt, _texts(_run_harness("banner", BROKEN)["banner"]))

    def test_ambiguous_offers_a_pick_not_the_worker_dispatching_fix(self):
        # S147/D8: ⚡ FIX on this state posts /api/config/fix-tests, which
        # hires a PAID discovery crew to choose. The affordance has to MATCH
        # the promise: show the detected candidates and let the captain pick.
        txt = _texts(_run_harness("banner", AMBIGUOUS_DOTNET)["banner"])
        self.assertNotIn("⚡ FIX TEST SYSTEMS", txt)
        for cand in AMBIGUOUS_DOTNET["candidates"]:
            self.assertIn(cand, txt)

    def test_ambiguous_pick_sets_that_exact_command_and_spends_nothing(self):
        res = _run_harness("bannerpick", AMBIGUOUS_DOTNET)
        posts = [f for f in res["fetches"] if f["method"] == "POST"]
        self.assertEqual(len(posts), 1, posts)
        self.assertEqual(posts[0]["url"], "/api/config/test-command")
        self.assertEqual(json.loads(posts[0]["body"])["testCommand"],
                         AMBIGUOUS_DOTNET["candidates"][0])
        self.assertNotIn("/api/config/fix-tests",
                         [f["url"] for f in res["fetches"]])

    def test_ambiguous_file_console_uses_the_choose_voice_too(self):
        # CLI/board/File-console must all agree (the ADR-002 parity rule).
        ov = _run_harness("file", AMBIGUOUS)["overlay"]
        txt = _texts(_find_cls(ov, "file-readiness")[0])
        self.assertIn("MULTIPLE TEST SYSTEMS DETECTED", txt)
        self.assertNotIn("engineering crew", txt)
        self.assertNotIn("⚡ FIX TEST SYSTEMS", txt)
        for cand in AMBIGUOUS["candidates"]:
            self.assertIn(cand, txt)

    def test_ambiguous_file_console_pick_sets_the_command_no_worker(self):
        res = _run_harness("filepick", AMBIGUOUS_DOTNET)
        posts = [f for f in res["fetches"] if f["method"] == "POST"]
        self.assertEqual([p["url"] for p in posts], ["/api/config/test-command"])
        self.assertEqual(json.loads(posts[0]["body"])["testCommand"],
                         AMBIGUOUS_DOTNET["candidates"][0])
        # the typed idea is never touched by a readiness action
        self.assertEqual(res["idea"], "my precious idea")

    def test_ambiguous_readonly_shows_the_choice_without_the_affordance(self):
        txt = _texts(_run_harness("banner", AMBIGUOUS_DOTNET,
                                  readonly=True)["banner"])
        self.assertIn("MULTIPLE TEST SYSTEMS DETECTED", txt)
        self.assertNotIn("USE", txt)

    def test_readonly_hides_the_fix_affordance_keeps_the_status(self):
        res = _run_harness("banner", BROKEN, readonly=True)
        txt = _texts(res["banner"])
        self.assertIn("TEST SYSTEMS OFFLINE", txt)
        self.assertNotIn("FIX TEST SYSTEMS", txt)


class TestFileConsole(unittest.TestCase):
    """The file-time fix: warning above the idea box, one-click walk, SSE
    re-verdict, filing/parking never blocked, ready byte-identical."""

    def test_unready_console_warns_above_the_idea_box(self):
        res = _run_harness("file", MISSING)
        overlay = res["overlay"]
        blocks = _find_cls(overlay, "file-readiness")
        self.assertEqual(len(blocks), 1)
        txt = _texts(blocks[0])
        self.assertIn("TEST SYSTEMS OFFLINE", txt)
        # the fix button + the manual override input are present.
        flat = _flatten(blocks[0])
        self.assertTrue(any(n["text"] == "⚡ FIX TEST SYSTEMS" for n in flat))
        self.assertTrue(any(n["tag"] == "input" for n in flat))
        # the override input pre-fills with the suggestion.
        inputs = [n for n in flat if n["tag"] == "input"]
        self.assertEqual(inputs[0]["value"], "make test")
        # the block sits BEFORE the idea textarea in the modal body.
        modal_body = _find_cls(overlay, "modal-body")[0]
        kids = modal_body["children"]
        block_i = next(i for i, k in enumerate(kids)
                       if "file-readiness" in (k.get("cls") or ""))
        idea_i = next(i for i, k in enumerate(kids)
                      if any(n["tag"] == "textarea" for n in _flatten(k)))
        self.assertLess(block_i, idea_i)

    def test_ready_console_byte_identical_to_today(self):
        # with NO meta block the console must contain no readiness node and be
        # structurally identical to a plain openFile.
        a = _run_harness("file", None)["overlay"]
        self.assertEqual(_find_cls(a, "file-readiness"), [])
        b = _run_harness("file", None)["overlay"]
        self.assertEqual(json.dumps(a, sort_keys=True),
                         json.dumps(b, sort_keys=True))
        # and an unready console differs ONLY by the readiness block: dropping
        # it yields the ready console byte-for-byte.
        c = _run_harness("file", MISSING)["overlay"]
        modal_body = _find_cls(c, "modal-body")[0]
        modal_body["children"] = [
            k for k in modal_body["children"]
            if "file-readiness" not in (k.get("cls") or "")]
        self.assertEqual(json.dumps(a, sort_keys=True),
                         json.dumps(c, sort_keys=True))

    def test_greenfield_console_uses_bootstrap_voice(self):
        res = _run_harness("file", UNKNOWN)
        block = _find_cls(res["overlay"], "file-readiness")[0]
        txt = _texts(block)
        self.assertIn("engineering crew", txt)
        self.assertNotIn("OFFLINE", txt)
        # and it differs from the repair copy.
        repair = _texts(_find_cls(_run_harness("file", MISSING)["overlay"],
                                  "file-readiness")[0])
        self.assertNotEqual(txt, repair)

    def test_one_click_fix_clears_warning_in_place_idea_preserved(self):
        res = _run_harness("fileclick", MISSING)
        # exactly ONE fix POST walked the whole suggest-or-discover→set→probe.
        fixes = [f for f in res["fetches"]
                 if f["url"] == "/api/config/fix-tests"]
        self.assertEqual(len(fixes), 1)
        # the warning cleared IN PLACE (console still open, ONLINE line shown).
        block = _find_cls(res["overlay"], "file-readiness")[0]
        self.assertIn("online", block["cls"])
        self.assertIn("TEST SYSTEMS ONLINE", _texts(block))
        self.assertNotIn("OFFLINE", _texts(block))
        # the typed idea survived.
        self.assertEqual(res["idea"], "my precious idea")

    def test_failed_fix_reports_plainly_and_leaves_input_ready(self):
        res = _run_harness("filefail", MISSING)
        block = _find_cls(res["overlay"], "file-readiness")[0]
        flat = _flatten(block)
        # plain report shown…
        self.assertIn("SET BUT UNVERIFIED", _texts(block))
        # …the override input is still there and the fix button re-armed.
        self.assertTrue(any(n["tag"] == "input" for n in flat))
        fix = [n for n in flat if n["text"] == "⚡ FIX TEST SYSTEMS"]
        self.assertEqual(len(fix), 1)
        self.assertFalse(fix[0]["disabled"])
        self.assertEqual(res["idea"], "my precious idea")

    def test_manual_override_posts_the_typed_command(self):
        res = _run_harness("fileset", MISSING)
        sets = [f for f in res["fetches"]
                if f["url"] == "/api/config/test-command"]
        self.assertEqual(len(sets), 1)
        self.assertIn("bash run-my-suite.sh", sets[0]["body"])
        self.assertEqual(res["idea"], "my precious idea")

    def test_sse_reverdict_clears_warning_keeps_idea(self):
        res = _run_harness("filesse", BROKEN)
        block = _find_cls(res["overlay"], "file-readiness")[0]
        self.assertIn("TEST SYSTEMS ONLINE", _texts(block))
        self.assertNotIn("OFFLINE", _texts(block))
        self.assertEqual(res["idea"], "my precious idea")

    def test_parking_proceeds_in_every_unready_state(self):
        for tr in (MISSING, BROKEN, UNKNOWN):
            res = _run_harness("filepark", tr)
            parks = [f for f in res["fetches"] if f["url"] == "/api/park"]
            self.assertEqual(len(parks), 1,
                             "park blocked under %s" % tr["status"])

    def test_readonly_console_shows_status_without_affordances(self):
        res = _run_harness("file", BROKEN, readonly=True)
        block = _find_cls(res["overlay"], "file-readiness")[0]
        flat = _flatten(block)
        self.assertIn("TEST SYSTEMS OFFLINE", _texts(block))
        self.assertFalse(any(n["tag"] == "input" for n in flat))
        self.assertFalse(any(n["text"] == "⚡ FIX TEST SYSTEMS" for n in flat))


# ── S183: THE FOUNDATION GATE on the viewscreen ────────────────────────
# The board is a VIEWPORT, never a reimplementation: a repo the CLI refuses to
# file against must be refused here too, in the same words, decided by the same
# seam (skills/lcars-init/foundation-gate.sh). These run against REAL git repos
# in real states — the verdict is a property of the working tree, so a faked one
# would prove nothing about the thing under test.
_GATE_SH = os.path.join(_REPO_ROOT, "skills", "lcars-init", "foundation-gate.sh")


def _git_repo(tmp, testcmd="null"):
    """A REAL initialized git repo with an LCARS config, at `tmp`."""
    os.makedirs(tmp, exist_ok=True)
    subprocess.run(["git", "init", "-q", tmp], check=True)
    subprocess.run(["git", "-C", tmp, "config", "user.email", "t@t"], check=True)
    subprocess.run(["git", "-C", tmp, "config", "user.name", "t"], check=True)
    cfgdir = os.path.join(tmp, ".git", "lcars")
    os.makedirs(os.path.join(cfgdir, "missions"), exist_ok=True)
    with open(os.path.join(cfgdir, "config.json"), "w") as fh:
        fh.write('{\n  "model": "claude-sonnet",\n  "projectName": "p",\n'
                 '  "testCommand": %s\n}\n' % testcmd)
    return tmp


def _recording_stub(path, log):
    with open(path, "w") as fh:
        fh.write('#!/usr/bin/env bash\nprintf "%s\\n" "$*" >> "' + log + '"\n'
                 'exit 0\n')
    os.chmod(path, 0o755)
    return path


class FoundationLockRenderTest(unittest.TestCase):
    """S183 — the board's own lock: ▦ FILE MISSION and ⬡ HOLODECK are DISABLED
    with the reason SAID, and the File console refuses instead of offering an
    idea box. The button state is what a real browser is driven against, so it
    is asserted here as state, and by the tester in a real browser."""

    def test_greenfield_locks_both_band_controls_with_a_reason(self):
        res = _run_harness("lock", None, foundation="greenfield")
        for key in ("fileBtn", "holodeckBtn"):
            self.assertTrue(res[key]["disabled"], "%s not locked" % key)
            self.assertIn("Establish Vision", res[key]["reason"])
            self.assertEqual(res[key]["title"], res[key]["reason"])

    def test_untested_locks_too_and_names_the_real_state(self):
        res = _run_harness("lock", None, foundation="untested")
        self.assertTrue(res["fileBtn"]["disabled"])
        self.assertIn("code but no test system", res["fileBtn"]["reason"])

    def test_the_holodeck_stays_locked_after_its_own_painter_runs(self):
        """FIX ROUND 1 / D2. MEASURED in real headed Chrome: #holodeckBtn
        carried class="btn go foundation-locked" and disabled:false, opacity:1,
        cursor:pointer — and CLICKING IT OPENED THE DECK. render() paints the
        foundation lock (board.js:1655) and then renderHolodeckActivity
        (:1659), whose holoPaintBandBtn set `disabled = (writesActive ===
        false)` and removed data-reason unconditionally. Two painters own one
        button; the button's state needs ONE owner that considers both."""
        res = _run_harness("lock", None, foundation="greenfield")
        b = res["holodeckBtn"]
        self.assertTrue(b["disabled"], "the holodeck survived its own painter")
        self.assertIn("Establish Vision", b["reason"])
        self.assertEqual(b["title"], b["reason"])

    def test_a_working_program_indicator_cannot_unlock_the_holodeck(self):
        """…and neither can the activity indicator, which repaints the same
        button off meta.holodeck on every SSE tick."""
        res = _run_harness("lock", None, foundation="untested",
                           holodeck={"count": 1, "message": "a program is working"})
        b = res["holodeckBtn"]
        self.assertTrue(b["disabled"])
        self.assertIn("test system", b["reason"])
        self.assertNotIn("a program is working", b["title"])

    def test_the_lock_lifts_when_the_foundation_lands(self):
        """The lock must LIFT as well as apply — an initialization mission
        landing clears meta.foundation and the next render unlocks the deck."""
        res = _run_harness("lock", None, foundation=None,
                           holodeck={"count": 0})
        self.assertFalse(res["holodeckBtn"]["disabled"])
        self.assertEqual(res["holodeckBtn"]["reason"], "")

    def test_a_repo_with_a_foundation_leaves_the_controls_alone(self):
        res = _run_harness("lock", None, foundation=None)
        self.assertFalse(res["fileBtn"]["disabled"])
        self.assertEqual(res["fileBtn"]["reason"], "")

    def test_the_file_console_refuses_instead_of_taking_an_idea(self):
        res = _run_harness("lock", None, foundation="greenfield")
        flat = _flatten(res["overlay"])
        self.assertFalse(any(n["tag"] == "textarea" for n in flat),
                         "a locked repo still offered an idea box")
        self.assertIn("Establish Vision", _texts(res["overlay"]))


class FoundationGateEndpointTest(unittest.TestCase):
    """POST /api/mission, /api/park, /api/holodeck/start on a repo with no
    foundation: REFUSED in the seam's own words, having dispatched NOTHING."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.repo = _git_repo(os.path.join(self.tmp, "repo"))
        self.log = os.path.join(self.tmp, "dispatch.log")
        stub = _recording_stub(os.path.join(self.tmp, "stub.sh"), self.log)
        self.actions = Actions(repo_root=self.repo,
                               scripts={"file": stub,
                                        "foundation_gate": _GATE_SH})

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def _dispatches(self):
        if not os.path.isfile(self.log):
            return []
        with open(self.log) as fh:
            return [l for l in fh.read().splitlines() if l.strip()]

    def test_file_endpoint_refuses_on_a_greenfield_repo(self):
        with self.assertRaises(ActionError) as cm:
            self.actions.file_mission("build me a thing")
        self.assertEqual(cm.exception.status, 409)
        self.assertIn("Establish Vision", cm.exception.message)
        self.assertEqual(cm.exception.data.get("foundation"), "greenfield")
        self.assertEqual(self._dispatches(), [],
                         "a skill was dispatched on a refused filing")

    def test_park_endpoint_refuses_with_the_same_shape(self):
        with self.assertRaises(ActionError) as cm:
            self.actions.park_mission("build me a thing")
        self.assertEqual(cm.exception.status, 409)
        self.assertIn("Establish Vision", cm.exception.message)
        self.assertEqual(self._dispatches(), [])

    def test_holodeck_entry_is_locked(self):
        with self.assertRaises(ActionError) as cm:
            self.actions.holodeck_start(program="a mockup")
        self.assertEqual(cm.exception.status, 409)
        self.assertIn("Establish Vision", cm.exception.message)

    def test_untested_repo_is_refused_too(self):
        os.makedirs(os.path.join(self.repo, "src"))
        with open(os.path.join(self.repo, "src", "app.js"), "w") as fh:
            fh.write("console.log(1);\n")
        with self.assertRaises(ActionError) as cm:
            self.actions.file_mission("build me a thing")
        self.assertEqual(cm.exception.data.get("foundation"), "untested")

    def test_board_meta_carries_the_lock(self):
        meta = LocalAdapter(self.repo).board()["meta"]
        self.assertEqual(meta.get("foundation"), "greenfield")
        self.assertEqual(meta["testReadiness"].get("foundation"), "greenfield")

    def test_board_meta_locks_a_repo_that_was_never_init(self):
        """FIX ROUND 3 (F2). The lock must not depend on `lcars init` having
        been run. A pristine repo carries no `.git/lcars/config.json`, and
        `_test_readiness` reports NOTHING on one by design (S146) — S183 hung
        `meta.foundation` off that same payload, so on the repo a captain is
        MOST likely to open the board against, both band controls rendered
        enabled and ▦ FILE MISSION opened the idea box. The CLI gate answers
        rc=20 on this very repo, so the verdict never needed a config file."""
        never = os.path.join(self.tmp, "never-init")
        os.makedirs(os.path.join(never, "src"))
        subprocess.run(["git", "init", "-q", never], check=True)
        with open(os.path.join(never, "src", "app.js"), "w") as fh:
            fh.write("console.log(1);\n")
        meta = LocalAdapter(never).board()["meta"]
        self.assertEqual(meta.get("foundation"), "untested")
        # …and `testReadiness` keeps its S146 meaning EXACTLY: no config file
        # ⇒ no block, so nothing that already reads it changes behaviour.
        self.assertNotIn("testReadiness", meta)

    def test_a_never_init_repo_that_HAS_tests_is_not_locked(self):
        """The same path must not become a wall: a repo with a real test
        system is `unconfigured`, which was never a locked verdict."""
        never = os.path.join(self.tmp, "never-init-tested")
        os.makedirs(os.path.join(never, "src"))
        subprocess.run(["git", "init", "-q", never], check=True)
        with open(os.path.join(never, "package.json"), "w") as fh:
            fh.write('{"name":"a","devDependencies":{"vitest":"^2.0.0"}}\n')
        with open(os.path.join(never, "src", "app.test.js"), "w") as fh:
            fh.write("test('x', () => {});\n")
        meta = LocalAdapter(never).board()["meta"]
        self.assertIsNone(meta.get("foundation"))

    def test_a_repo_with_a_foundation_files_exactly_as_before(self):
        ready = _git_repo(os.path.join(self.tmp, "ready"), testcmd='"true"')
        log = os.path.join(self.tmp, "ready.log")
        actions = Actions(repo_root=ready,
                          scripts={"file": _recording_stub(
                              os.path.join(self.tmp, "ready-stub.sh"), log),
                              "foundation_gate": _GATE_SH})
        actions.file_mission("build me a thing")
        with open(log) as fh:
            self.assertIn("--prd", fh.read())
        self.assertIsNone(LocalAdapter(ready).board()["meta"].get("foundation"))

    def test_gate_degrades_to_allow_when_it_cannot_answer(self):
        """A missing helper must never become a wall (no verdict => allowed)."""
        log = os.path.join(self.tmp, "degraded.log")
        actions = Actions(repo_root=self.repo,
                          scripts={"file": _recording_stub(
                              os.path.join(self.tmp, "deg-stub.sh"), log),
                              "foundation_gate": os.path.join(
                                  self.tmp, "no-such-gate.sh")})
        actions.file_mission("build me a thing")
        with open(log) as fh:
            self.assertIn("--prd", fh.read())


if __name__ == "__main__":
    unittest.main()

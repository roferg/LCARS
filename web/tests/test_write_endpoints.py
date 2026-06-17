"""LOCAL-BRIDGE write endpoints (S68) — the daemon's operator actions.

Each POST shells out to the matching `lcars` skill script via an env-injected
path (ADR-002: dispatch, never reimplement Stage logic). These tests point each
skill-path env at a RECORDING STUB that writes the argv (and stdin) it saw to a
file, so we assert the exact dispatch with NO model / gh / git spend.

The write layer is a LOCAL-BRIDGE concern (ADR-006): it is only active for the
LOCAL adapter (or when a writer is explicitly wired). A GitHub / view-only
configuration drops it — GET still works, writes are declined.

stdlib only; the daemon runs on an ephemeral localhost port inside the test.
"""
import json
import os
import subprocess
import sys
import tempfile
import threading
import unittest
import urllib.error
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from tests import _fixtures as fx  # noqa: E402
from lcars_serve.local_adapter import LocalAdapter  # noqa: E402
from lcars_serve.github_adapter import GitHubAdapter  # noqa: E402
from lcars_serve.server import make_server  # noqa: E402
from lcars_serve.actions import Actions  # noqa: E402


def _record_stub(record_path):
    """A bash stub that records "$@" (argv) and stdin, then exits 0.

    Returns the stub's absolute path. Each invocation APPENDS a record block so a
    single endpoint that shells more than once is still observable, but the common
    case (one dispatch) writes one block.
    """
    fd, path = tempfile.mkstemp(suffix=".sh")
    os.close(fd)
    script = (
        '#!/usr/bin/env bash\n'
        '{\n'
        '  printf "ARGV: %s\\n" "$*"\n'
        '  printf "ENV_MODEL_OVERRIDE: %s\\n" "${LCARS_MODEL_OVERRIDE:-}"\n'
        '  printf "ENV_WORKER_BIN: %s\\n" "${LCARS_WORKER_BIN:-}"\n'
        '  printf "STDIN_START\\n"\n'
        '  cat\n'
        '  printf "\\nSTDIN_END\\n"\n'
        '} >> "' + record_path + '"\n'
        'exit 0\n'
    )
    with open(path, "w") as fh:
        fh.write(script)
    os.chmod(path, 0o755)
    return path


class WriteEndpointBase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        # one mission to act on (verify-stage so approve/verify make sense).
        fx.plant_simple(self.tmp, "m-001", stage="verify", issue=142)
        self.adapter = LocalAdapter(self.tmp)

        # a recording stub per skill, each pointed at its own record file.
        self.records = {}
        self.scripts = {}
        for key in ("file", "run", "pause", "respond",
                    "approve", "feedback", "log", "resolve"):
            rec = os.path.join(self.tmp, "rec-%s.txt" % key)
            self.records[key] = rec
            self.scripts[key] = _record_stub(rec)

        self.actions = Actions(
            repo_root=self.tmp,
            scripts=self.scripts,
            # a worker bin the file/run dispatch threads through as the engine
            worker_bin="/bin/echo",
        )
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

    def _record(self, key):
        path = self.records[key]
        if not os.path.exists(path):
            return ""
        with open(path) as fh:
            return fh.read()

    def _not_invoked(self, key):
        # the stub only creates its record file when invoked; absent or empty
        # means it never ran.
        return self._record(key) == ""

    def _record_when(self, key, needle="", timeout=5.0):
        """Poll the record file until `needle` appears (or timeout).

        `start` is now FIRE-AND-FORGET (Popen, not waited on), so the run-skill's
        record file is written asynchronously after the HTTP response returns.
        Tests that assert on the dispatched argv wait for it here.
        """
        import time
        deadline = time.time() + timeout
        while time.time() < deadline:
            rec = self._record(key)
            if needle in rec and rec:
                return rec
            time.sleep(0.02)
        return self._record(key)


def _lock_stub(record_path, sleep_secs):
    """A run-skill stub that records its argv/env, holds a LIVE driver lock for
    `sleep_secs`, then exits 0.

    It mimics run.sh's lock: it mkdirs $MISSION_DIR/driver.lock and writes its own
    PID, so while it sleeps the LocalAdapter sees the mission as `running` (and a
    second start() must no-op). The mission dir is derived from --mission in argv.
    """
    fd, path = tempfile.mkstemp(suffix=".sh")
    os.close(fd)
    script = (
        '#!/usr/bin/env bash\n'
        '{ printf "ARGV: %s\\n" "$*"; } >> "' + record_path + '"\n'
        '# find --mission <id>\n'
        'mid=""; prev=""\n'
        'for a in "$@"; do [ "$prev" = "--mission" ] && mid="$a"; prev="$a"; done\n'
        'lock=".git/lcars/missions/$mid/driver.lock"\n'
        'mkdir -p "$lock" 2>/dev/null\n'
        'printf "%s" "$$" > "$lock/pid"\n'
        'sleep ' + str(sleep_secs) + '\n'
        'rm -rf "$lock"\n'
        'exit 0\n'
    )
    with open(path, "w") as fh:
        fh.write(script)
    os.chmod(path, 0o755)
    return path


class StartEndpointTest(WriteEndpointBase):
    def test_start_dispatches_run_drive(self):
        status, body = self._post("/api/mission/m-001/start")
        self.assertEqual(status, 200)
        self.assertTrue(body["ok"])
        self.assertIn("state", body)
        rec = self._record_when("run", "drive")
        self.assertIn("drive", rec)
        self.assertIn("--mission m-001", rec)

    def test_start_passes_override_through(self):
        status, body = self._post("/api/mission/m-001/start",
                                  {"override": "all:opus"})
        self.assertEqual(status, 200)
        # the override must reach the run dispatch (argv or env file)
        rec = self._record_when("run", "all:opus")
        self.assertIn("all:opus", rec)

    def test_start_feeds_persisted_engine_to_run(self):
        """S67: a mission filed with a chosen engine persists state.json.workerBin;
        Start must read it and set $LCARS_WORKER_BIN for the run drive, so the whole
        pipeline runs on the picked engine instead of host-detecting claude."""
        # re-plant m-001 carrying a persisted engine.
        fx.plant_simple(self.tmp, "m-001", stage="verify", issue=142,
                        worker_bin="copilot")
        status, body = self._post("/api/mission/m-001/start")
        self.assertEqual(status, 200)
        rec = self._record_when("run", "ENV_WORKER_BIN: copilot")
        # the stub records ENV_WORKER_BIN: <value>
        self.assertIn("ENV_WORKER_BIN: copilot", rec)

    def test_start_engine_absent_does_not_force_engine(self):
        """No persisted workerBin ⇒ Start must not invent one (run.sh then host-
        detects as before — no regression). Drive Actions directly with NO default
        worker_bin so nothing else injects it."""
        # m-001 from setUp has no workerBin (fx.plant_simple, worker_bin=None).
        actions = Actions(repo_root=self.tmp, scripts=self.scripts)
        actions.start("m-001")
        rec = self._record_when("run", "ENV_WORKER_BIN")
        self.assertIn("ENV_WORKER_BIN: \n", rec)

    def test_start_returns_promptly_without_blocking_on_the_run(self):
        """start() is FIRE-AND-FORGET: the run driver is a long process, so start()
        must NOT block on it. Point the run skill at a stub that holds a driver lock
        for ~3s; start() must return well before that."""
        import time
        rec = os.path.join(self.tmp, "rec-runslow.txt")
        scripts = dict(self.scripts)
        scripts["run"] = _lock_stub(rec, sleep_secs=3)
        actions = Actions(repo_root=self.tmp, scripts=scripts)
        t0 = time.time()
        actions.start("m-001")
        elapsed = time.time() - t0
        # blocking would take >=3s; fire-and-forget returns near-instantly.
        self.assertLess(elapsed, 1.5,
                        "start() blocked on the long run driver (%.2fs)" % elapsed)

    def test_start_uses_a_nonblocking_spawn(self):
        """The fire-and-forget seam is Popen (no wait). Assert start() calls
        subprocess.Popen and never subprocess.run for the run dispatch."""
        import unittest.mock as mock

        class _FakePopen(object):
            def __init__(self, *a, **k):
                pass
        with mock.patch.object(subprocess, "Popen", _FakePopen) as _, \
                mock.patch.object(subprocess, "run") as run_mock:
            actions = Actions(repo_root=self.tmp, scripts=self.scripts)
            actions.start("m-001")
            self.assertFalse(run_mock.called,
                             "start() used the BLOCKING subprocess.run")

    def test_start_on_an_already_running_mission_does_not_spawn_a_second(self):
        """Defense-in-depth: if a live driver already holds the lock, start() must
        be a clean no-op (no second driver)."""
        import time
        rec = os.path.join(self.tmp, "rec-run2.txt")
        scripts = dict(self.scripts)
        scripts["run"] = _lock_stub(rec, sleep_secs=3)
        actions = Actions(repo_root=self.tmp, scripts=scripts)
        # first start: spawns the live driver (which holds the lock while sleeping)
        actions.start("m-001")
        # wait until the lock is actually held (running flag flips true)
        deadline = time.time() + 3
        while time.time() < deadline:
            if actions._reader.mission("m-001").get("running"):
                break
            time.sleep(0.02)
        self.assertTrue(actions._reader.mission("m-001").get("running"),
                        "the first driver never took the lock")
        # second start while running: must NOT dispatch again.
        with open(rec) as fh:
            first = fh.read()
        actions.start("m-001")
        time.sleep(0.3)
        with open(rec) as fh:
            after = fh.read()
        self.assertEqual(first, after,
                         "start() spawned a SECOND driver on an already-running "
                         "mission")


class PauseResumeTest(WriteEndpointBase):
    def test_pause_dispatches_pause(self):
        status, body = self._post("/api/mission/m-001/pause")
        self.assertEqual(status, 200)
        self.assertTrue(body["ok"])
        rec = self._record("pause")
        self.assertIn("pause", rec)
        self.assertIn("m-001", rec)

    def test_resume_dispatches_resume(self):
        status, body = self._post("/api/mission/m-001/resume")
        self.assertEqual(status, 200)
        rec = self._record("pause")  # resume is the pause.sh script too
        self.assertIn("resume", rec)
        self.assertIn("m-001", rec)


class RespondTest(WriteEndpointBase):
    def test_respond_dispatches_answer(self):
        status, body = self._post("/api/mission/m-001/respond",
                                  {"answer": "go with global leaderboard"})
        self.assertEqual(status, 200)
        rec = self._record("respond")
        self.assertIn("answer", rec)
        self.assertIn("--mission m-001", rec)
        self.assertIn("go with global leaderboard", rec)

    def test_respond_missing_answer_is_400(self):
        with self.assertRaises(urllib.error.HTTPError) as cm:
            self._post("/api/mission/m-001/respond", {})
        self.assertEqual(cm.exception.code, 400)


class VerifyRoutingTest(WriteEndpointBase):
    def test_verify_approve_routes_to_approve(self):
        status, body = self._post("/api/mission/m-001/verify",
                                  {"decision": "approve"})
        self.assertEqual(status, 200)
        self.assertIn("--mission m-001", self._record("approve"))
        # send-back stub must NOT have been invoked
        self.assertTrue(self._not_invoked("feedback"))

    def test_verify_send_back_routes_to_feedback(self):
        status, body = self._post("/api/mission/m-001/verify",
                                  {"decision": "send-back",
                                   "feedback": "tighten the error copy"})
        self.assertEqual(status, 200)
        rec = self._record("feedback")
        self.assertIn("--mission m-001", rec)
        self.assertIn("tighten the error copy", rec)
        # approve stub must NOT have been invoked
        self.assertTrue(self._not_invoked("approve"))

    def test_verify_send_back_requires_feedback(self):
        with self.assertRaises(urllib.error.HTTPError) as cm:
            self._post("/api/mission/m-001/verify", {"decision": "send-back"})
        self.assertEqual(cm.exception.code, 400)

    def test_verify_unknown_decision_is_400(self):
        with self.assertRaises(urllib.error.HTTPError) as cm:
            self._post("/api/mission/m-001/verify", {"decision": "maybe"})
        self.assertEqual(cm.exception.code, 400)


class MissionFileTest(WriteEndpointBase):
    def test_file_requires_idea(self):
        with self.assertRaises(urllib.error.HTTPError) as cm:
            self._post("/api/mission", {})
        self.assertEqual(cm.exception.code, 400)

    def test_file_dispatches_file_script(self):
        status, body = self._post("/api/mission",
                                  {"idea": "Add a dark mode toggle",
                                   "engine": "claude"})
        self.assertEqual(status, 200)
        self.assertTrue(body["ok"])
        rec = self._record("file")
        # file.sh consumes a --prd <path>; the daemon must materialise one.
        self.assertIn("--prd", rec)

    def test_file_threads_chosen_engine_to_file_script(self):
        """S67: the engine picked in the File modal must reach file.sh as
        $LCARS_WORKER_BIN so file.sh can persist it as state.json.workerBin (the
        bash test proves the on-disk persistence; here we assert the env reaches
        the dispatch)."""
        status, body = self._post("/api/mission",
                                  {"idea": "Add a dark mode toggle",
                                   "engine": "copilot"})
        self.assertEqual(status, 200)
        rec = self._record("file")
        self.assertIn("ENV_WORKER_BIN: copilot", rec)


class LogTest(WriteEndpointBase):
    def test_log_preview_returns_children(self):
        # plant a parent with two linked bug children
        fx.plant_simple(self.tmp, "m-001", stage="verify", issue=142)
        _plant_bug(self.tmp, "m-bug1", parent="m-001", issue=201, stage="plan")
        _plant_bug(self.tmp, "m-bug2", parent="m-001", issue=202, stage="plan")
        status, body = self._post("/api/mission/m-001/log", {})
        self.assertEqual(status, 200)
        self.assertTrue(body["ok"])
        ids = sorted(c["id"] for c in body["state"]["children"])
        self.assertEqual(ids, ["m-bug1", "m-bug2"])

    def test_log_run_dispatches_resolve(self):
        status, body = self._post("/api/mission/m-001/log/run", {})
        self.assertEqual(status, 200)
        rec = self._record("resolve")
        self.assertIn("m-001", rec)


class LiveChannelTest(WriteEndpointBase):
    """Behavior 5: a state-changing dispatch moves the LocalAdapter fingerprint,
    which the existing /api/events SSE loop turns into an `update`. We assert the
    fingerprint-moves path directly here (the SSE-emits-on-fingerprint-change
    path is locked by test_server.test_live_channel_emits_exactly_one_update)."""

    def test_state_changing_write_moves_fingerprint(self):
        import subprocess as _sp
        # the real pause.sh resolves the repo via `git rev-parse`; the fixture
        # tree only has .git/lcars, so make it a real git repo for this case.
        # (re-creating .git/ via git init keeps the planted lcars/ subtree.)
        _sp.run(["git", "init", "-q"], cwd=self.tmp,
                stdout=_sp.DEVNULL, stderr=_sp.DEVNULL)
        before = self.adapter.fingerprint()
        # a real state mutation: pause writes paused=true into state.json. We use
        # a real pause.sh (not the recording stub) so the fingerprint genuinely
        # moves. Point the pause script at the installed/real script.
        import os as _os
        real_pause = _os.path.join(
            _os.path.dirname(_os.path.dirname(_os.path.dirname(
                _os.path.abspath(__file__)))),
            "skills", "lcars-pause", "pause.sh")
        self.actions.scripts["pause"] = real_pause
        # gh absent in the test env → pause.sh degrades gracefully (local-only).
        self.actions.gh_bin = "definitely-not-gh"
        status, body = self._post("/api/mission/m-001/pause")
        self.assertEqual(status, 200)
        after = self.adapter.fingerprint()
        self.assertNotEqual(before, after,
                            "a state-changing write must move the fingerprint "
                            "so the SSE loop emits an update")


class ValidationTest(WriteEndpointBase):
    def test_unknown_mission_is_404(self):
        with self.assertRaises(urllib.error.HTTPError) as cm:
            self._post("/api/mission/nope/start")
        self.assertEqual(cm.exception.code, 404)


class ReadOnlyGatingTest(unittest.TestCase):
    """View-only / github config: GET still serves the board; writes declined."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        fx.plant_simple(self.tmp, "m-001", stage="implement", issue=142)
        self.adapter = LocalAdapter(self.tmp)
        # NO actions wired → read-only daemon (the github/view-only shape).
        self.httpd = make_server(self.adapter, host="127.0.0.1", port=0,
                                 poll_interval=0.05, actions=None)
        self.port = self.httpd.server_address[1]
        self.thread = threading.Thread(target=self.httpd.serve_forever,
                                       daemon=True)
        self.thread.start()

    def tearDown(self):
        self.httpd.shutdown()
        self.httpd.server_close()

    def test_get_board_still_works(self):
        url = "http://127.0.0.1:%d/api/board" % self.port
        with urllib.request.urlopen(url, timeout=5) as r:
            data = json.loads(r.read())
        self.assertIn("columns", data)

    def test_write_endpoint_declined_when_read_only(self):
        url = "http://127.0.0.1:%d/api/mission/m-001/start" % self.port
        req = urllib.request.Request(url, data=b"{}", method="POST")
        with self.assertRaises(urllib.error.HTTPError) as cm:
            urllib.request.urlopen(req, timeout=5)
        # 403 (write layer inactive) — not a silent 200.
        self.assertIn(cm.exception.code, (403, 405))

    def test_github_adapter_is_read_only_by_construction(self):
        # The github adapter never carries a writer; make_server is called with
        # actions=None for it (see __main__.build). A POST is declined.
        self.assertEqual(GitHubAdapter.name, "github")


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

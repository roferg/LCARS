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
import base64
import json
import os
import subprocess
import sys
import tempfile
import threading
import unittest
import urllib.error
import urllib.request


def _img(data=b"\x89PNG\r\n\x1a\n_S92_", ctype="image/png", name="shot.png"):
    """A {name,type,dataB64} image-paste entry (the postWrite body shape)."""
    return {"name": name, "type": ctype,
            "dataB64": base64.b64encode(data).decode("ascii")}

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
        '  printf "ENV_WORKER_MODEL_SET: %s\\n" "${LCARS_WORKER_MODEL+yes}"\n'
        '  printf "ENV_WORKER_MODEL: %s\\n" "${LCARS_WORKER_MODEL:-}"\n'
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
                    "approve", "feedback", "log", "resolve", "launch"):
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


def _sleep_stub(record_path, sleep_secs):
    """A stub that records its argv/env, sleeps `sleep_secs`, then exits 0.

    Used to prove a dispatch is FIRE-AND-FORGET: if the caller blocked on it the
    call would take >= sleep_secs; if it spawns detached the caller returns at once.
    """
    fd, path = tempfile.mkstemp(suffix=".sh")
    os.close(fd)
    script = (
        '#!/usr/bin/env bash\n'
        '{\n'
        '  printf "ARGV: %s\\n" "$*"\n'
        '  printf "ENV_WORKER_BIN: %s\\n" "${LCARS_WORKER_BIN:-}"\n'
        '} >> "' + record_path + '"\n'
        'sleep ' + str(sleep_secs) + '\n'
        'exit 0\n'
    )
    with open(path, "w") as fh:
        fh.write(script)
    os.chmod(path, 0o755)
    return path


def _launch_stub(record_path, *, spawn_real=False, fail=False):
    """A stub for skills/lcars-launch/launch.sh (S109).

    Records its argv/env (so a test can assert the mission id + hint + engine
    reached the dispatch), then writes a launch.json into the target mission dir
    (derived from the first positional arg + cwd=repo_root), mirroring launch.sh's
    contract. Modes:
      * default            → status=running record (no real process; pid/pgid
                             omitted so the daemon tracks nothing to kill).
      * spawn_real=True    → spawn a REAL long-lived process in its OWN process
                             group (perl POSIX::setsid, PGID==PID, like launch.sh)
                             and record its pid/pgid — so the daemon has a real
                             pgid to group-kill on shutdown and the test can prove
                             the pid is dead afterward.
      * fail=True          → status=failed record + a human message, exit 1 (as
                             launch.sh dies on a discovery/liveness failure).
    A `--stop` invocation kills the recorded pgid (best-effort) and rewrites the
    record to status=stopped. Returns the stub's absolute path.
    """
    fd, path = tempfile.mkstemp(suffix=".sh")
    os.close(fd)
    if fail:
        write_body = (
            '  printf \'{"status":"failed","target":"","url":"",\' > "$lj"\n'
            '  printf \'"message":"could not determine how to start this app '
            '— no dev script was found. Try naming the app as a hint."}\' >> "$lj"\n'
            '  printf "\\n" >> "$lj"\n'
            '  exit 1\n'
        )
    elif spawn_real:
        write_body = (
            "  perl -e 'use POSIX qw(setsid); eval { setsid(); }; exec @ARGV' -- "
            "sleep 300 >/dev/null 2>&1 &\n"
            '  pid=$!\n'
            '  printf \'{"status":"running","target":"fake app",'
            '"url":"http://localhost:9931",'
            '"howToStop":"stop it from the board","command":"sleep 300",'
            '"cwd":".","pid":%s,"pgid":%s,"message":"the app is running."}\\n\' '
            '"$pid" "$pid" > "$lj"\n'
            '  exit 0\n'
        )
    else:
        write_body = (
            '  printf \'{"status":"running","target":"fake app",'
            '"url":"http://localhost:9931",'
            '"howToStop":"stop it from the board",'
            '"message":"the app is running."}\\n\' > "$lj"\n'
            '  exit 0\n'
        )
    script = (
        '#!/usr/bin/env bash\n'
        '{\n'
        '  printf "ARGV: %s\\n" "$*"\n'
        '  printf "ENV_WORKER_BIN: %s\\n" "${LCARS_WORKER_BIN:-}"\n'
        '} >> "' + record_path + '"\n'
        'mid=""; stop=0\n'
        'for a in "$@"; do\n'
        '  case "$a" in\n'
        '    --stop) stop=1 ;;\n'
        '    --*) ;;\n'
        '    *) [ -z "$mid" ] && mid="$a" ;;\n'
        '  esac\n'
        'done\n'
        'lj=".git/lcars/missions/$mid/launch.json"\n'
        'mkdir -p ".git/lcars/missions/$mid"\n'
        'if [ "$stop" -eq 1 ]; then\n'
        '  if [ -f "$lj" ]; then\n'
        '    pgid=$(sed -n \'s/.*"pgid"[: ]*\\([0-9][0-9]*\\).*/\\1/p\' "$lj" | head -1)\n'
        '    [ -n "$pgid" ] && kill -TERM -"$pgid" 2>/dev/null || true\n'
        '  fi\n'
        '  printf \'{"status":"stopped","target":"fake app","url":"",'
        '"message":"the app has been stopped."}\\n\' > "$lj"\n'
        '  exit 0\n'
        'fi\n'
        + write_body
    )
    with open(path, "w") as fh:
        fh.write(script)
    os.chmod(path, 0o755)
    return path


def _pid_alive(pid):
    """True iff `pid` is a live process (os.kill(pid, 0) does not raise ESRCH)."""
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except OSError:
        return False
    return True


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

    def test_start_strips_inherited_daemon_wide_model_pin(self):
        """S78: a daemon launched with LCARS_WORKER_MODEL set must NOT leak that
        pin into a mission's run — Start strips it so the mission SELF-RESOLVES
        from engine + estimate.json + overrides (no global clobber across all
        stages of all missions). m-001 has no persisted workerModel."""
        import unittest.mock as mock
        with mock.patch.dict(os.environ, {"LCARS_WORKER_MODEL": "somepin"}):
            actions = Actions(repo_root=self.tmp, scripts=self.scripts)
            actions.start("m-001")
        rec = self._record_when("run", "ENV_WORKER_MODEL_SET")
        # the inherited pin must be ABSENT from the child env (stripped, not "").
        self.assertIn("ENV_WORKER_MODEL_SET: \n", rec,
                      "daemon-wide LCARS_WORKER_MODEL leaked into the run "
                      "(it must be stripped so the mission self-resolves)")

    def test_start_feeds_persisted_per_mission_model_no_global_clobber(self):
        """S78: a mission with state.json.workerModel spawns its run WITH that
        per-mission LCARS_WORKER_MODEL, while a DIFFERENT mission (no workerModel)
        in the SAME daemon spawns WITHOUT it — proving per-mission resolution and
        no shared global state, even if the daemon inherited a pin."""
        import unittest.mock as mock
        fx.plant_simple(self.tmp, "m-pinned", stage="verify", issue=143,
                        worker_model="opus")
        fx.plant_simple(self.tmp, "m-free", stage="verify", issue=144)
        rec_pinned = os.path.join(self.tmp, "rec-pinned.txt")
        rec_free = os.path.join(self.tmp, "rec-free.txt")
        scripts_pinned = dict(self.scripts)
        scripts_pinned["run"] = _record_stub(rec_pinned)
        scripts_free = dict(self.scripts)
        scripts_free["run"] = _record_stub(rec_free)
        with mock.patch.dict(os.environ, {"LCARS_WORKER_MODEL": "daemonpin"}):
            Actions(repo_root=self.tmp, scripts=scripts_pinned).start("m-pinned")
            Actions(repo_root=self.tmp, scripts=scripts_free).start("m-free")
        import time
        deadline = time.time() + 5.0
        while time.time() < deadline:
            if (os.path.exists(rec_pinned) and os.path.exists(rec_free)):
                break
            time.sleep(0.02)
        with open(rec_pinned) as fh:
            pinned = fh.read()
        with open(rec_free) as fh:
            free = fh.read()
        # the pinned mission carries ITS OWN model (not the daemon pin).
        self.assertIn("ENV_WORKER_MODEL: opus\n", pinned)
        # the free mission carries NO model — the daemon pin did not leak.
        self.assertIn("ENV_WORKER_MODEL_SET: \n", free,
                      "the free mission inherited a global pin (clobber)")

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
        # BUG-040: approve is fire-and-forget (Popen) → poll for its async record.
        self.assertIn("--mission m-001", self._record_when("approve", "m-001"))
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

    def test_reapprove_dispatches_approve_reapprove(self):
        """BUG-067: the Reapprove gate (heal converged → awaiting-reapprove) must
        dispatch the engine's MERGE-ONLY reapprove path — approve.sh --reapprove —
        fire-and-forget (per BUG-051 capture). Assert the spawn argv."""
        fx.plant_simple(self.tmp, "m-001", stage="verify", issue=142,
                        reconcile_status="awaiting-reapprove",
                        awaiting_human=True,
                        reconcile_note="re-tested green (8/8). Reapprove to merge.")
        status, body = self._post("/api/mission/m-001/reapprove")
        self.assertEqual(status, 200)
        rec = self._record_when("approve", "m-001")
        self.assertIn("--mission m-001", rec)
        self.assertIn("--reapprove", rec)
        # never the send-back path.
        self.assertTrue(self._not_invoked("feedback"))

    def test_reapprove_threads_persisted_engine(self):
        """The reapprove spawn inherits the mission's persisted engine
        ($LCARS_WORKER_BIN) so the merge-only path runs on the right CLI."""
        fx.plant_simple(self.tmp, "m-001", stage="verify", issue=142,
                        reconcile_status="awaiting-reapprove",
                        awaiting_human=True, worker_bin="copilot")
        status, _ = self._post("/api/mission/m-001/reapprove")
        self.assertEqual(status, 200)
        rec = self._record_when("approve", "m-001")
        self.assertIn("ENV_WORKER_BIN: copilot", rec)

    def test_reapprove_unknown_mission_is_404(self):
        with self.assertRaises(urllib.error.HTTPError) as cm:
            self._post("/api/mission/nope/reapprove")
        self.assertEqual(cm.exception.code, 404)

    def test_verify_send_back_requires_feedback(self):
        with self.assertRaises(urllib.error.HTTPError) as cm:
            self._post("/api/mission/m-001/verify", {"decision": "send-back"})
        self.assertEqual(cm.exception.code, 400)

    def test_verify_unknown_decision_is_400(self):
        with self.assertRaises(urllib.error.HTTPError) as cm:
            self._post("/api/mission/m-001/verify", {"decision": "maybe"})
        self.assertEqual(cm.exception.code, 400)

    # ── BUG-031: send-back on a Mission-Log re-verify gate is NON-destructive ──
    def test_verify_send_back_on_bug_child_feedbacks_bug_and_respawns_resolve(self):
        """Case A: `mid` is a logged-bug CHILD (parentMission set). Send-back must
        re-fix the BUG (feedback on the child), then re-drive the parent's batch
        fire-and-forget (`resolve --parent <parent>` — the bare drive form, NOT
        `complete`). It MUST NOT feedback the parent or touch its stage/PR."""
        fx.plant_simple(self.tmp, "m-001", stage="verify", issue=142)
        _plant_bug(self.tmp, "m-bug1", parent="m-001", issue=201, stage="verify")
        status, _ = self._post("/api/mission/m-bug1/verify",
                               {"decision": "send-back",
                                "feedback": "fix the off-by-one"})
        self.assertEqual(status, 200)
        # feedback was applied to the BUG, not the parent.
        fb = self._record("feedback")
        self.assertIn("--mission m-bug1", fb)
        self.assertNotIn("--mission m-001", fb)
        self.assertIn("fix the off-by-one", fb)
        # the batch was re-driven (fire-and-forget) on the PARENT, bare form.
        res = self._record_when("resolve", "m-001")
        self.assertIn("--parent m-001", res)
        self.assertNotIn("complete", res)

    def test_verify_send_back_on_bug_child_threads_parent_engine(self):
        """Case A engine: the resolve respawn inherits the PARENT's persisted
        engine as LCARS_WORKER_BIN (mirrors the approve branch)."""
        fx.plant_simple(self.tmp, "m-001", stage="verify", issue=142,
                        worker_bin="copilot")
        _plant_bug(self.tmp, "m-bug1", parent="m-001", issue=201, stage="verify")
        status, _ = self._post("/api/mission/m-bug1/verify",
                               {"decision": "send-back",
                                "feedback": "fix the off-by-one"})
        self.assertEqual(status, 200)
        res = self._record_when("resolve", "ENV_WORKER_BIN: copilot")
        self.assertIn("--parent m-001", res)
        self.assertIn("ENV_WORKER_BIN: copilot", res)

    def test_verify_send_back_on_parent_feedbacks_each_child_not_parent(self):
        """Case B: `mid` is the PARENT consolidated re-verify gate (no
        parentMission, has linked non-done bug children). Send-back must apply the
        feedback to EACH child, NONE to the parent, and re-drive `resolve --parent
        <mid>` ONCE. The parent's verified state / PR stays intact."""
        fx.plant_simple(self.tmp, "m-001", stage="verify", issue=142)
        _plant_bug(self.tmp, "m-bug1", parent="m-001", issue=201, stage="verify")
        _plant_bug(self.tmp, "m-bug2", parent="m-001", issue=202, stage="verify")
        status, _ = self._post("/api/mission/m-001/verify",
                               {"decision": "send-back",
                                "feedback": "redo both fixes"})
        self.assertEqual(status, 200)
        fb = self._record("feedback")
        self.assertIn("--mission m-bug1", fb)
        self.assertIn("--mission m-bug2", fb)
        # the PARENT itself must NOT be fed back.
        self.assertNotIn("--mission m-001", fb)
        self.assertIn("redo both fixes", fb)
        # the batch re-drove once on the parent.
        res = self._record_when("resolve", "m-001")
        self.assertIn("--parent m-001", res)
        self.assertNotIn("complete", res)

    def test_verify_send_back_on_plain_mission_unchanged(self):
        """Case C: a plain top-level verify mission (no parent, no children) —
        UNCHANGED: feedback on itself, resolve NOT invoked."""
        # setUp's m-001 is a plain verify mission with no parent/children.
        status, _ = self._post("/api/mission/m-001/verify",
                               {"decision": "send-back",
                                "feedback": "tighten the error copy"})
        self.assertEqual(status, 200)
        self.assertIn("--mission m-001", self._record("feedback"))
        self.assertTrue(self._not_invoked("resolve"))

    def test_verify_approve_dispatches_the_merge_skill(self):
        """S75: the `approve` decision now dispatches approve.sh whose job is the
        MERGE (open PR → merged → Done). The endpoint contract is unchanged
        (routes to approve.sh); we lock that an in-review mission's approve still
        reaches approve.sh — the merge signal — and not feedback.sh."""
        # an in-review mission: stage verify, an open PR recorded.
        fx.plant_simple(self.tmp, "m-001", stage="verify", issue=142,
                        pr_url="https://github.com/acme/repo/pull/77",
                        pr_number=77, review="open")
        status, body = self._post("/api/mission/m-001/verify",
                                  {"decision": "approve"})
        self.assertEqual(status, 200)
        # BUG-040: approve is fire-and-forget (Popen) → poll for its async record.
        self.assertIn("--mission m-001", self._record_when("approve", "m-001"))
        self.assertTrue(self._not_invoked("feedback"))

    def test_verify_card_carries_pr_and_review_state(self):
        """The board card the verify endpoint returns (mission state) must carry
        the open PR + the in-review state so the front end can show the PR link
        and the Merge PR action."""
        fx.plant_simple(self.tmp, "m-001", stage="verify", issue=142,
                        pr_url="https://github.com/acme/repo/pull/77",
                        pr_number=77, review="open")
        # the board read surfaces the in-review fields on the card.
        board = self.adapter.board()
        card = next(c for c in board["missions"] if c["id"] == "m-001")
        self.assertEqual(card["prUrl"], "https://github.com/acme/repo/pull/77")
        self.assertEqual(card["review"], "open")


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

    def test_file_threads_attached_image_path_to_file_script(self):
        """S92: an image pasted on the File idea box is staged under repo_root and
        threaded to file.sh as a repeated `--attach <staged path>` so file.sh
        persists it as a durable mission attachment."""
        status, body = self._post(
            "/api/mission",
            {"idea": "Add a dark mode toggle", "images": [_img()]})
        self.assertEqual(status, 200)
        rec = self._record("file")
        self.assertIn("--attach", rec)
        # the threaded path is a staged lcars-img-* file under repo_root.
        self.assertIn("lcars-img-", rec)

    def test_file_without_image_threads_no_attach(self):
        """Regression: a no-image file call is byte-identical (no --attach)."""
        status, _ = self._post("/api/mission", {"idea": "Add a dark mode toggle"})
        self.assertEqual(status, 200)
        self.assertNotIn("--attach", self._record("file"))

    def test_file_with_image_reaps_staged_temp(self):
        """The staged temp copy is reaped after file.sh has copied it in (the
        record stub is a no-op cp, so nothing should leak under repo_root)."""
        import glob
        self._post("/api/mission",
                   {"idea": "x", "images": [_img()]})
        self.assertEqual(glob.glob(os.path.join(self.tmp, "lcars-img-*")), [])


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
        # BUG-G: resolve is now FIRE-AND-FORGET (_spawn), so its record is written
        # asynchronously after the POST returns — poll for it like the start tests.
        rec = self._record_when("resolve", "m-001")
        self.assertIn("m-001", rec)

    # ── S74: the review panel carries the estimate per logged bug ─────────────
    def test_log_preview_children_carry_estimate_pills_and_model(self):
        """The Mission-Log review response must surface, PER bug, the cost pill +
        two difficulty pills + the suggested per-stage model mix — REUSING the
        same board.py components a Mission card/Launch panel uses. The estimate
        is read off each filed child's estimate.json (file-then-review flow)."""
        fx.plant_simple(self.tmp, "m-001", stage="verify", issue=142)
        _plant_bug(self.tmp, "m-bug1", parent="m-001", issue=201, stage="plan",
                   estimate=fx.ESTIMATE_CLAUDE)
        status, body = self._post("/api/mission/m-001/log", {})
        self.assertEqual(status, 200)
        kids = {c["id"]: c for c in body["state"]["children"]}
        c = kids["m-bug1"]
        # ONE cost pill
        self.assertIn("pills", c)
        self.assertIsNotNone(c["pills"].get("cost"))
        # TWO difficulty pills (reasoning + implementation)
        self.assertIsNotNone(c["pills"].get("reasoning"))
        self.assertIsNotNone(c["pills"].get("implementation"))
        self.assertEqual(c["pills"]["reasoning"]["level"], "medium")
        self.assertEqual(c["pills"]["implementation"]["level"], "high")
        # the suggested per-stage model map (the same shape Launch renders).
        # Mission-log-grounding round: a logged bug now walks the FULL pipeline
        # (Research grounding → Validate → …), so its review-panel mix KEEPS the
        # Research + Validate rows (driven purely by the 6-stage estimate.json).
        self.assertTrue(c.get("modelMix"))
        stage_order = [row["stage"] for row in c["modelMix"]]
        self.assertEqual(stage_order,
                         ["Research", "Validate", "Plan",
                          "Plan Review", "Implement", "Verify"])
        stages = {row["stage"]: row["tier"] for row in c["modelMix"]}
        self.assertIn("Research", stages)
        self.assertIn("Validate", stages)
        self.assertEqual(stages.get("Plan Review"), "sonnet")

    def test_log_preview_child_without_estimate_degrades_gracefully(self):
        """A child with no estimate.json yet must still list — with a null/absent
        cost pill — never crash the panel (estimator-unavailable parity)."""
        fx.plant_simple(self.tmp, "m-001", stage="verify", issue=142)
        _plant_bug(self.tmp, "m-bug1", parent="m-001", issue=201, stage="plan")
        status, body = self._post("/api/mission/m-001/log", {})
        self.assertEqual(status, 200)
        c = {x["id"]: x for x in body["state"]["children"]}["m-bug1"]
        self.assertIn("pills", c)
        self.assertIsNone(c["pills"].get("cost"))
        self.assertIsNone(c.get("modelMix"))

    def test_log_preview_child_surfaces_persisted_override(self):
        """When the captain steered a bug's model, the persisted override must
        ride the review-panel child so the panel can pre-fill its field."""
        fx.plant_simple(self.tmp, "m-001", stage="verify", issue=142)
        _plant_bug(self.tmp, "m-bug1", parent="m-001", issue=201, stage="plan",
                   estimate=fx.ESTIMATE_CLAUDE, override="all:opus")
        status, body = self._post("/api/mission/m-001/log", {})
        c = {x["id"]: x for x in body["state"]["children"]}["m-bug1"]
        self.assertEqual(c.get("override"), "all:opus")

    # ── S74: a dedicated FILE step (file-then-review-then-run) ────────────────
    def test_log_file_files_children_with_per_bug_overrides(self):
        """`log_file` files the authored bugs via log.sh (blocking, so the
        estimator runs + the children exist on return) and threads each captain
        override to log.sh via the EXACT file.sh lever (--model-override paired
        positionally with --prd). It returns the enriched filed children for the
        review panel; it does NOT resolve (Run Fixes does that)."""
        actions = Actions(repo_root=self.tmp, scripts=self.scripts)
        actions.log_file("m-001",
                         prds=["# Bug: a\n\nbody a", "# Bug: b\n\nbody b"],
                         overrides=["all:opus", ""])
        log_rec = self._record("log")
        self.assertIn("--parent m-001", log_rec)
        # the file.sh override lever, paired per PRD
        self.assertIn("--model-override all:opus", log_rec)
        # log_file must NOT dispatch resolve (review happens first)
        self.assertTrue(self._not_invoked("resolve"))

    def test_log_file_threads_attached_image_to_log_script(self):
        """S92: an image pasted into the Mission-Log box rides /log/file and is
        threaded to log.sh as a repeated `--attach <staged path>` so every filed
        bug gets it as a durable attachment."""
        actions = Actions(repo_root=self.tmp, scripts=self.scripts)
        actions.log_file("m-001", prds=["# Bug: a\n\nbody a"],
                         overrides=[""], images=[_img()])
        log_rec = self._record("log")
        self.assertIn("--parent m-001", log_rec)
        self.assertIn("--attach", log_rec)
        self.assertIn("lcars-img-", log_rec)

    def test_log_file_without_image_threads_no_attach(self):
        """Regression: a no-image log_file is byte-identical (no --attach)."""
        actions = Actions(repo_root=self.tmp, scripts=self.scripts)
        actions.log_file("m-001", prds=["# Bug: a\n\nbody a"], overrides=[""])
        self.assertNotIn("--attach", self._record("log"))

    def test_log_file_with_image_reaps_staged_temp(self):
        import glob
        actions = Actions(repo_root=self.tmp, scripts=self.scripts)
        actions.log_file("m-001", prds=["# Bug: a\n\nbody a"],
                         overrides=[""], images=[_img()])
        self.assertEqual(glob.glob(os.path.join(self.tmp, "lcars-img-*")), [])

    def test_log_run_threads_per_bug_overrides_to_log(self):
        """The explicit one-shot file & run path (confirm=True) must also carry
        per-bug overrides into log.sh so a captain who steers then confirms in one
        call still persists each steer."""
        actions = Actions(repo_root=self.tmp, scripts=self.scripts)
        actions.log_run("m-001", prds=["# Bug: a\n\nb"],
                        overrides=["reasoning:opus"], confirm=True)
        log_rec = self._record("log")
        self.assertIn("--model-override reasoning:opus", log_rec)

    # ── S74 follow-up CHANGE 4: with the override box living in the POST-File
    # breakdown, the captain edits the steers AFTER the bugs are filed, then
    # clicks Run Fixes with NO prds (the bugs already exist). Those override
    # values must still thread to each ALREADY-FILED child — persisted as
    # state.json.modelOverride, the EXACT lever run.sh's active_model_override
    # reads — so resolve-logs drives each child on the captain's chosen model. ──
    def test_log_run_applies_post_file_overrides_to_filed_children(self):
        import json
        fx.plant_simple(self.tmp, "m-001", stage="verify", issue=142)
        _plant_bug(self.tmp, "m-bug1", parent="m-001", issue=201, stage="plan",
                   estimate=fx.ESTIMATE_CLAUDE)
        _plant_bug(self.tmp, "m-bug2", parent="m-001", issue=202, stage="plan",
                   estimate=fx.ESTIMATE_CLAUDE)
        actions = Actions(repo_root=self.tmp, scripts=self.scripts)
        # no prds (already filed); overrides pair positionally with the children
        # in the same order the review panel renders them (_linked_children order).
        actions.log_run("m-001", prds=[], overrides=["all:opus", "reasoning:sonnet"])
        # each child's state.json now carries the persisted modelOverride.
        def _ov(mid):
            p = os.path.join(fx.mission_dir(self.tmp, mid), "state.json")
            with open(p) as fh:
                return json.load(fh).get("modelOverride")
        self.assertEqual(_ov("m-bug1"), {"scope": "all", "tier": "opus"})
        self.assertEqual(_ov("m-bug2"), {"scope": "reasoning", "tier": "sonnet"})
        # and resolve was still dispatched for the batch. resolve is fire-and-
        # forget (BUG-G _spawn), so poll for its async record instead of an
        # immediate read (deflakes a race against the detached Popen).
        self.assertIn("m-001", self._record_when("resolve", "m-001"))

    def test_log_run_blank_post_file_override_leaves_child_unsteered(self):
        """A blank override at Run Fixes must not stamp a steer (no-op), and must
        not clobber an override the captain set at File time."""
        import json
        fx.plant_simple(self.tmp, "m-001", stage="verify", issue=142)
        _plant_bug(self.tmp, "m-bug1", parent="m-001", issue=201, stage="plan",
                   estimate=fx.ESTIMATE_CLAUDE, override="all:opus")
        actions = Actions(repo_root=self.tmp, scripts=self.scripts)
        actions.log_run("m-001", prds=[], overrides=[""])
        p = os.path.join(fx.mission_dir(self.tmp, "m-bug1"), "state.json")
        with open(p) as fh:
            ov = json.load(fh).get("modelOverride")
        self.assertEqual(ov, {"scope": "all", "tier": "opus"})

    # ── S74 FOLLOW-UP: plain-language per-bug overrides are NORMALIZED (not
    # silently dropped). A logged bug skips Align, so the daemon gives the
    # override the SAME normalization Align's worker gives a Mission: passthrough
    # structured → deterministic parse → bounded worker fallback → never drop. ──
    def test_log_run_normalizes_plain_language_override_end_to_end(self):
        """A plain-language steer on a logged bug must end up as the correct
        {scope,tier} in the child's state.json (so run.sh active_model_override
        would resolve Opus). 'Opus 4.8' is deterministic → no worker needed."""
        import json
        fx.plant_simple(self.tmp, "m-001", stage="verify", issue=142)
        _plant_bug(self.tmp, "m-bug1", parent="m-001", issue=201, stage="plan",
                   estimate=fx.ESTIMATE_CLAUDE)
        actions = Actions(repo_root=self.tmp, scripts=self.scripts)
        # poison the worker turn: a deterministic value must NOT call out.
        actions._worker_turn = lambda *a, **k: (_ for _ in ()).throw(
            AssertionError("deterministic override must not hit the worker"))
        result = actions.log_run("m-001", prds=[], overrides=["Opus 4.8"])
        p = os.path.join(fx.mission_dir(self.tmp, "m-bug1"), "state.json")
        with open(p) as fh:
            self.assertEqual(json.load(fh).get("modelOverride"),
                             {"scope": "all", "tier": "opus"})
        # the response carries the RESOLVED steer per child (so the UI can echo it)
        resolved = result.get("overrides")
        self.assertTrue(resolved, "log_run must report the resolved overrides")
        r0 = resolved[0]
        self.assertEqual(r0.get("id"), "m-bug1")
        self.assertEqual(r0.get("resolved"), {"scope": "all", "tier": "opus"})
        self.assertIn("opus", (r0.get("label") or "").lower())
        self.assertIsNone(r0.get("error"))

    def test_log_run_uses_worker_fallback_for_tierless_phrasing(self):
        """A tier-less phrasing the deterministic parser can't map goes to ONE
        bounded worker call (the reused daemon worker seam); its reply is parsed
        and persisted to the child's modelOverride."""
        import json
        fx.plant_simple(self.tmp, "m-001", stage="verify", issue=142,
                        worker_bin="copilot")
        _plant_bug(self.tmp, "m-bug1", parent="m-001", issue=201, stage="plan",
                   estimate=fx.ESTIMATE_CLAUDE)
        actions = Actions(repo_root=self.tmp, scripts=self.scripts)
        seen = {}

        def _fake_turn(prompt, engine=None, **k):
            seen["engine"] = engine
            seen["prompt"] = prompt
            return "reasoning:opus"

        actions._worker_turn = _fake_turn
        result = actions.log_run("m-001", prds=[],
                                 overrides=["make the thinking smarter"])
        # the fallback reused the daemon worker seam, on the PARENT's engine.
        self.assertEqual(seen.get("engine"), "copilot")
        p = os.path.join(fx.mission_dir(self.tmp, "m-bug1"), "state.json")
        with open(p) as fh:
            self.assertEqual(json.load(fh).get("modelOverride"),
                             {"scope": "reasoning", "tier": "opus"})
        self.assertEqual(result["overrides"][0].get("resolved"),
                         {"scope": "reasoning", "tier": "opus"})

    def test_log_run_unparseable_override_surfaces_error_no_silent_drop(self):
        """Unparseable input + worker returns 'null' ⇒ the response carries a
        normalization ERROR and the child's modelOverride is NOT set to a wrong
        value (never silent-drop onto the default model)."""
        import json
        fx.plant_simple(self.tmp, "m-001", stage="verify", issue=142)
        _plant_bug(self.tmp, "m-bug1", parent="m-001", issue=201, stage="plan",
                   estimate=fx.ESTIMATE_CLAUDE)
        actions = Actions(repo_root=self.tmp, scripts=self.scripts)
        actions._worker_turn = lambda *a, **k: "null"
        result = actions.log_run("m-001", prds=[], overrides=["asdf qwer zzz"])
        # NO modelOverride was written (no wrong/default value stamped).
        p = os.path.join(fx.mission_dir(self.tmp, "m-bug1"), "state.json")
        with open(p) as fh:
            self.assertNotIn("modelOverride", json.load(fh))
        # the error is surfaced per child so the panel can show it.
        r0 = result["overrides"][0]
        self.assertEqual(r0.get("id"), "m-bug1")
        self.assertIsNone(r0.get("resolved"))
        self.assertTrue(r0.get("error"),
                        "an unparseable override must carry a normalization error")
        self.assertIn("asdf qwer zzz", r0["error"])

    def test_log_file_normalizes_plain_language_before_log_sh(self):
        """File-time path: a plain-language override must be NORMALIZED to
        <scope>:<tier> BEFORE it threads to log.sh (which dies on a bad value).
        log.sh therefore receives the structured form."""
        actions = Actions(repo_root=self.tmp, scripts=self.scripts)
        actions._worker_turn = lambda *a, **k: (_ for _ in ()).throw(
            AssertionError("deterministic override must not hit the worker"))
        actions.log_file("m-001",
                         prds=["# Bug: a\n\nbody a"],
                         overrides=["use Opus the whole way"])
        log_rec = self._record("log")
        # the structured form reached log.sh, NOT the raw plain language.
        self.assertIn("--model-override all:opus", log_rec)
        self.assertNotIn("Opus the whole way", log_rec)

    # ── BUG-C: the Log worker inherits the PARENT mission's persisted engine ──
    def test_log_author_uses_parent_persisted_engine(self):
        """`_log_author` must drive its worker turn on the PARENT's persisted
        engine (state.json.workerBin) — the Log dialog has no engine picker, and
        the daemon has no default engine, so without inheritance Preview errors
        'no worker engine configured'."""
        # parent filed with copilot; the daemon itself carries NO default engine.
        fx.plant_simple(self.tmp, "m-001", stage="verify", issue=142,
                        worker_bin="copilot")
        actions = Actions(repo_root=self.tmp, scripts=self.scripts)  # worker_bin=None
        seen = {}

        def _fake_turn(prompt, engine=None, outdir=None, image_paths=None):
            seen["engine"] = engine
            # a minimal valid worker JSON so _log_author parses one bug.
            return '{"bugs": ["# Bug: thing\\n\\nbody"]}'

        actions._worker_turn = _fake_turn
        out = actions.log_preview("m-001", text="the save button is broken")
        self.assertEqual(seen.get("engine"), "copilot")
        self.assertTrue(out["authored"])
        self.assertEqual(out["count"], 1)

    def test_log_author_no_parent_engine_falls_back(self):
        """No persisted parent engine ⇒ fall back to the existing behaviour
        (engine=None → _worker_turn uses the daemon default, or errors if none).
        Assert we pass engine=None, not crash before the worker turn."""
        # m-001 from setUp has NO workerBin.
        actions = Actions(repo_root=self.tmp, scripts=self.scripts)
        seen = {}

        def _fake_turn(prompt, engine=None, outdir=None, image_paths=None):
            seen["engine"] = engine
            return '{"bugs": ["# Bug: x\\n\\nb"]}'

        actions._worker_turn = _fake_turn
        actions.log_preview("m-001", text="broken thing")
        self.assertIsNone(seen.get("engine"))

    def test_log_run_threads_parent_engine_to_log_and_resolve(self):
        """`log_run` must set LCARS_WORKER_BIN=<parent engine> for BOTH the
        log.sh dispatch (so each child bug mission persists workerBin=parent) AND
        the resolve-logs dispatch (so the children run on the parent engine)."""
        fx.plant_simple(self.tmp, "m-001", stage="verify", issue=142,
                        worker_bin="copilot")
        actions = Actions(repo_root=self.tmp, scripts=self.scripts)  # no default
        actions.log_run("m-001", prds=["# Bug: save\n\nthe save fails"],
                        confirm=True)
        # log.sh filing stays BLOCKING → its record is present synchronously.
        log_rec = self._record("log")
        self.assertIn("ENV_WORKER_BIN: copilot", log_rec)
        self.assertIn("--parent m-001", log_rec)
        # resolve is FIRE-AND-FORGET (BUG-G) → poll for its async record.
        res_rec = self._record_when("resolve", "ENV_WORKER_BIN: copilot")
        self.assertIn("ENV_WORKER_BIN: copilot", res_rec)
        self.assertIn("m-001", res_rec)

    def test_log_run_no_parent_engine_does_not_force_engine(self):
        """No persisted parent engine ⇒ log_run must not invent one (the dispatch
        env's LCARS_WORKER_BIN stays whatever the daemon default is — empty here)."""
        actions = Actions(repo_root=self.tmp, scripts=self.scripts)  # no default
        actions.log_run("m-001", prds=["# Bug: x\n\nb"], confirm=True)
        log_rec = self._record("log")
        self.assertIn("ENV_WORKER_BIN: \n", log_rec)

    # ── BUG-G (backend): the resolve-logs dispatch is FIRE-AND-FORGET ──────────
    def test_log_run_returns_promptly_without_blocking_on_resolve(self):
        """log_run() must NOT block on resolve-logs (which drives the WHOLE batch —
        minutes). Point the resolve skill at a stub that sleeps ~3s; log_run must
        return well before that (the children are filed blocking, the resolve drive
        is detached)."""
        import time
        rec = os.path.join(self.tmp, "rec-resolveslow.txt")
        scripts = dict(self.scripts)
        scripts["resolve"] = _sleep_stub(rec, sleep_secs=3)
        actions = Actions(repo_root=self.tmp, scripts=scripts)
        t0 = time.time()
        actions.log_run("m-001", prds=["# Bug: x\n\nb"], confirm=True)
        elapsed = time.time() - t0
        # blocking would take >=3s; fire-and-forget returns near-instantly.
        self.assertLess(elapsed, 1.5,
                        "log_run blocked on the long resolve drive (%.2fs)"
                        % elapsed)

    def test_log_run_resolve_uses_a_nonblocking_spawn(self):
        """The resolve dispatch must go through Popen (no wait), while the log.sh
        filing of children stays BLOCKING (subprocess.run). Assert the resolve
        dispatch is the ONLY thing on Popen and log.sh stays on subprocess.run."""
        import unittest.mock as mock

        run_calls = []
        popen_calls = []

        class _FakeCompleted(object):
            returncode = 0
            stdout = b""

        def _rec_run(cmd, *a, **k):
            run_calls.append(cmd)
            return _FakeCompleted()

        class _FakePopen(object):
            def __init__(self, cmd, *a, **k):
                popen_calls.append(cmd)

        with mock.patch.object(subprocess, "Popen", _FakePopen), \
                mock.patch.object(subprocess, "run", _rec_run):
            actions = Actions(repo_root=self.tmp, scripts=self.scripts)
            actions.log_run("m-001", prds=["# Bug: x\n\nb"], confirm=True)

        def _is(key, cmds):
            script = self.scripts[key]
            return any(script in cmd for cmd in cmds)

        # log.sh filing stays BLOCKING (children must exist on return).
        self.assertTrue(_is("log", run_calls),
                        "log.sh filing must stay blocking (subprocess.run)")
        self.assertFalse(_is("log", popen_calls),
                         "log.sh filing must NOT be fire-and-forget")
        # resolve-logs is FIRE-AND-FORGET (Popen, not run).
        self.assertTrue(_is("resolve", popen_calls),
                        "resolve-logs must be dispatched via Popen (_spawn)")
        self.assertFalse(_is("resolve", run_calls),
                         "resolve-logs must NOT block (subprocess.run)")

    def test_log_run_files_children_blocking_then_spawns_resolve(self):
        """The children must exist (filed via log.sh, blocking) by the time log_run
        returns, even though resolve is detached. Use the real recording stubs:
        the log record is present synchronously; resolve is spawned with the engine
        env preserved (BUG-D)."""
        fx.plant_simple(self.tmp, "m-001", stage="verify", issue=142,
                        worker_bin="copilot")
        actions = Actions(repo_root=self.tmp, scripts=self.scripts)
        actions.log_run("m-001", prds=["# Bug: save\n\nthe save fails"],
                        confirm=True)
        # log.sh ran synchronously (blocking) → its record is present immediately.
        log_rec = self._record("log")
        self.assertIn("--parent m-001", log_rec)
        self.assertIn("ENV_WORKER_BIN: copilot", log_rec)
        # resolve is fire-and-forget → poll for its async record, engine preserved.
        res_rec = self._record_when("resolve", "ENV_WORKER_BIN: copilot")
        self.assertIn("ENV_WORKER_BIN: copilot", res_rec)
        self.assertIn("m-001", res_rec)

    # ── BUG-059: filing a logged bug HOLDS for the human cost review ──────────
    # Filing computes the estimate but must NOT auto-proceed into running the
    # fix — the captain reviews the cost, may re-steer the model, then clicks an
    # explicit Go. So `log/run` with prds (but no confirm) FILES + estimates and
    # stops; resolve is dispatched ONLY on the explicit Go (a re-post with no
    # prds, the bugs already filed) or the explicit confirm power path. ─────────
    def test_log_run_with_prds_does_not_dispatch_before_confirm(self):
        """Filing via /log/run (prds, no confirm) must FILE the children + return
        their estimates but NOT dispatch resolve-logs — the human gate. (BUG-059:
        the captain hit File and walked away and it had already dispatched.)"""
        fx.plant_simple(self.tmp, "m-001", stage="verify", issue=142)
        actions = Actions(repo_root=self.tmp, scripts=self.scripts)
        out = actions.log_run("m-001", prds=["# Bug: save\n\nthe save fails"],
                              overrides=["all:opus"])
        # the bug WAS filed (so its estimate gets computed) ...
        log_rec = self._record("log")
        self.assertIn("--parent m-001", log_rec)
        self.assertIn("--model-override all:opus", log_rec)
        # ... and the response carries the filed children for the cost review.
        self.assertTrue(out.get("filed"))
        self.assertIn("children", out)
        # but resolve-logs was NOT dispatched — filing HELD for the human Go.
        # (poll briefly: a fire-and-forget spawn would show up async if it ran.)
        self.assertEqual(self._record_when("resolve", "m-001", timeout=0.5), "",
                         "filing must HOLD — resolve must not run before the Go")

    def test_log_run_endpoint_with_prds_does_not_dispatch_before_confirm(self):
        """Over HTTP: POST /log/run {prds} (no confirm) files + estimates and
        HOLDS — no resolve dispatch (the daemon gate, end to end)."""
        status, body = self._post(
            "/api/mission/m-001/log/run",
            {"prds": ["# Bug: save\n\nthe save fails"]})
        self.assertEqual(status, 200)
        self.assertTrue(body["ok"])
        self.assertTrue(body["state"].get("filed"))
        self.assertIn("--parent m-001", self._record("log"))
        self.assertEqual(self._record_when("resolve", "m-001", timeout=0.5), "",
                         "the endpoint must HOLD on filing — no auto-run")

    def test_log_run_explicit_go_after_filing_dispatches(self):
        """The explicit Go: with the bugs ALREADY filed (no prds), /log/run
        applies the reviewed override and DISPATCHES resolve-logs (the human
        confirmed after seeing the estimate)."""
        import json
        fx.plant_simple(self.tmp, "m-001", stage="verify", issue=142)
        _plant_bug(self.tmp, "m-bug1", parent="m-001", issue=201, stage="plan",
                   estimate=fx.ESTIMATE_CLAUDE)
        actions = Actions(repo_root=self.tmp, scripts=self.scripts)
        actions.log_run("m-001", prds=[], overrides=["all:opus"])
        # the reviewed override is persisted onto the already-filed child ...
        p = os.path.join(fx.mission_dir(self.tmp, "m-bug1"), "state.json")
        with open(p) as fh:
            self.assertEqual(json.load(fh).get("modelOverride"),
                             {"scope": "all", "tier": "opus"})
        # ... and NOW resolve-logs is dispatched (the Go).
        self.assertIn("m-001", self._record_when("resolve", "m-001"))

    def test_log_run_confirm_power_path_files_and_dispatches(self):
        """The explicit one-shot power path: confirm=True files the children AND
        dispatches resolve in one call (the deliberate file-and-go, not the
        default UI flow)."""
        fx.plant_simple(self.tmp, "m-001", stage="verify", issue=142)
        actions = Actions(repo_root=self.tmp, scripts=self.scripts)
        actions.log_run("m-001", prds=["# Bug: save\n\nthe save fails"],
                        confirm=True)
        self.assertIn("--parent m-001", self._record("log"))
        self.assertIn("m-001", self._record_when("resolve", "m-001"))

    # ── per-bug image routing: the split worker maps "image N" wording to bugs;
    # the daemon does the DETERMINISTIC orphaned∪explicit union. ────────────────
    def _log_argv_tokens(self):
        """The tokens of the (single) log.sh ARGV line the record stub captured."""
        rec = self._record("log")
        for line in rec.splitlines():
            if line.startswith("ARGV: "):
                return line[len("ARGV: "):].split()
        return []

    def test_log_author_old_string_schema_gives_every_bug_all_images(self):
        """Legacy `{"bugs":["<md>", ...]}` (no imageRefs) + K pasted images ⇒ each
        child carries the FULL image set (all orphaned → all-to-all)."""
        actions = Actions(repo_root=self.tmp, scripts=self.scripts)
        actions._worker_turn = lambda *a, **k: (
            '{"bugs": ["# Mission: A\\n\\n**Type:** bug\\nbody",'
            ' "# Mission: B\\n\\n**Type:** bug\\nbody"]}')
        out = actions.log_preview("m-001", text="two bugs",
                                  images=[_img(), _img()])
        kids = out["children"]
        self.assertEqual([c["images"] for c in kids], [[1, 2], [1, 2]])
        self.assertEqual([c["imageRefs"] for c in kids], [[], []])

    def test_log_author_per_bug_refs_route_and_orphan_goes_to_all(self):
        """New object schema: bug A refs image 1, image 2 referenced by nobody ⇒
        A gets {1,2}, B gets {2} (the orphan reaches all)."""
        actions = Actions(repo_root=self.tmp, scripts=self.scripts)
        actions._worker_turn = lambda *a, **k: (
            '{"bugs": [{"prd":"# Mission: A\\n\\n**Type:** bug\\nb","imageRefs":[1]},'
            ' {"prd":"# Mission: B\\n\\n**Type:** bug\\nb"}]}')
        out = actions.log_preview("m-001", text="two bugs",
                                  images=[_img(), _img()])
        kids = out["children"]
        self.assertEqual(kids[0]["images"], [1, 2])   # explicit {1} ∪ orphan {2}
        self.assertEqual(kids[1]["images"], [2])      # orphan {2} only
        self.assertEqual(kids[0]["imageRefs"], [1])
        self.assertEqual(kids[1]["imageRefs"], [])

    def test_log_author_all_assigned_leaves_unmentioned_bug_empty(self):
        """Every image assigned to SOME bug ⇒ a bug the report tied to no image
        carries NOTHING (no orphans to fall back on)."""
        actions = Actions(repo_root=self.tmp, scripts=self.scripts)
        actions._worker_turn = lambda *a, **k: (
            '{"bugs": [{"prd":"# Mission: A\\n\\n**Type:** bug\\nb","imageRefs":[1]},'
            ' {"prd":"# Mission: B\\n\\n**Type:** bug\\nb","imageRefs":[2]},'
            ' {"prd":"# Mission: C\\n\\n**Type:** bug\\nb"}]}')
        out = actions.log_preview("m-001", text="three bugs",
                                  images=[_img(), _img()])
        kids = out["children"]
        self.assertEqual(kids[0]["images"], [1])
        self.assertEqual(kids[1]["images"], [2])
        self.assertEqual(kids[2]["images"], [])       # unmentioned → nothing

    def test_file_children_no_refs_threads_all_images_as_globals(self):
        """No refs (or none supplied) + K images ⇒ every image threaded as a GLOBAL
        --attach BEFORE the first --prd — byte-identical to the pre-routing dispatch
        (log.sh gives globals to all bugs)."""
        actions = Actions(repo_root=self.tmp, scripts=self.scripts)
        actions.log_file("m-001",
                         prds=["# Bug: a\n\nbody a", "# Bug: b\n\nbody b"],
                         overrides=["", ""],
                         images=[_img(), _img()])
        toks = self._log_argv_tokens()
        first_prd = toks.index("--prd")
        before = [toks[i + 1] for i, t in enumerate(toks[:first_prd])
                  if t == "--attach"]
        after = [toks[i + 1] for i, t in enumerate(toks)
                 if t == "--attach" and i > first_prd]
        self.assertEqual(len(before), 2, "both images must be global (pre --prd)")
        self.assertEqual(after, [], "no per-bug (post --prd) attaches with no refs")

    def test_file_children_routes_orphan_global_and_explicit_positional(self):
        """image_refs=[[1],[]] with 2 images ⇒ image 2 is orphaned (global, before
        the first --prd); image 1 is bug-0 explicit (positional, right after bug-0's
        --prd); nothing after bug-1's --prd."""
        actions = Actions(repo_root=self.tmp, scripts=self.scripts)
        actions.log_file("m-001",
                         prds=["# Bug: a\n\nbody a", "# Bug: b\n\nbody b"],
                         overrides=["", ""],
                         images=[_img(), _img()],
                         image_refs=[[1], []])
        toks = self._log_argv_tokens()
        prd_positions = [i for i, t in enumerate(toks) if t == "--prd"]
        self.assertEqual(len(prd_positions), 2)
        p0, p1 = prd_positions
        # exactly one GLOBAL --attach before the first --prd (the orphan, image 2)
        globals_ = [i for i, t in enumerate(toks[:p0]) if t == "--attach"]
        self.assertEqual(len(globals_), 1)
        # exactly one --attach between bug-0's --prd and bug-1's --prd (image 1)
        between = [i for i in range(p0 + 1, p1) if toks[i] == "--attach"]
        self.assertEqual(len(between), 1)
        # nothing attached after bug-1's --prd
        after1 = [i for i in range(p1 + 1, len(toks)) if toks[i] == "--attach"]
        self.assertEqual(after1, [])
        # and the two staged sources are distinct (orphan != explicit)
        self.assertNotEqual(toks[globals_[0] + 1], toks[between[0] + 1])


class RouteImagesUnitTest(unittest.TestCase):
    """The pure deterministic routing formula (union = explicit ∪ orphaned)."""

    def test_no_refs_all_orphaned(self):
        from lcars_serve.actions import _route_images
        orphaned, explicit, union = _route_images([[], []], 2)
        self.assertEqual(orphaned, [1, 2])
        self.assertEqual(explicit, [[], []])
        self.assertEqual(union, [[1, 2], [1, 2]])

    def test_one_orphan_among_assigned(self):
        from lcars_serve.actions import _route_images
        orphaned, explicit, union = _route_images([[1], []], 2)
        self.assertEqual(orphaned, [2])          # image 2 referenced by nobody
        self.assertEqual(union, [[1, 2], [2]])

    def test_all_assigned_empty_bug_gets_nothing(self):
        from lcars_serve.actions import _route_images
        orphaned, explicit, union = _route_images([[1], [2], []], 2)
        self.assertEqual(orphaned, [])
        self.assertEqual(union, [[1], [2], []])

    def test_out_of_range_and_dupe_refs_are_dropped(self):
        from lcars_serve.actions import _route_images
        # 9 is out of range (n=2), duplicate 1s collapse.
        orphaned, explicit, union = _route_images([[1, 1, 9], []], 2)
        self.assertEqual(explicit, [[1], []])
        self.assertEqual(orphaned, [2])
        self.assertEqual(union, [[1, 2], [2]])

    def test_no_images_all_empty(self):
        from lcars_serve.actions import _route_images
        orphaned, explicit, union = _route_images([[], []], 0)
        self.assertEqual(orphaned, [])
        self.assertEqual(union, [[], []])


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


class LaunchEndpointTest(WriteEndpointBase):
    """S109: the daemon dispatches `lcars launch` and OWNS the launched app's
    lifecycle — Stop kills it, and daemon shutdown kills everything it launched."""

    def tearDown(self):
        # Safety net: reap any real launch this test spawned so no sleep leaks.
        try:
            self.actions.shutdown_launches()
        except Exception:
            pass
        super(LaunchEndpointTest, self).tearDown()

    def _rebuild_with_launch(self, **stub_kw):
        """Point the launch skill at a real launch stub and rebuild the server
        (actions is closure-captured at make_server time)."""
        self.scripts["launch"] = _launch_stub(self.records["launch"], **stub_kw)
        try:
            os.unlink(self.records["launch"])
        except OSError:
            pass
        self.httpd.shutdown()
        self.thread.join()
        self.httpd.server_close()
        self.actions = Actions(repo_root=self.tmp, scripts=self.scripts,
                               worker_bin="/bin/echo")
        from lcars_serve.server import make_server as _mk
        self.httpd = _mk(self.adapter, host="127.0.0.1", port=0,
                         poll_interval=0.05, actions=self.actions)
        self.port = self.httpd.server_address[1]
        self.thread = threading.Thread(target=self.httpd.serve_forever,
                                       daemon=True)
        self.thread.start()

    def _mission_launch_json(self, mid):
        return os.path.join(fx.mission_dir(self.tmp, mid), "launch.json")

    # ── 1: launch dispatch + the additive board/detail `launch` field ─────────
    def test_launch_dispatches_script_with_hint_and_surfaces_launch_field(self):
        self._rebuild_with_launch()
        status, body = self._post("/api/mission/m-001/launch",
                                  {"hint": "the game in web"})
        self.assertEqual(status, 200)
        self.assertTrue(body["ok"])
        # the mission id + hint reached the launch skill's argv.
        rec = self._record("launch")
        self.assertIn("m-001", rec)
        self.assertIn("the game in web", rec)
        # launch.json now sits in the mission dir (written by the stub).
        self.assertTrue(os.path.exists(self._mission_launch_json("m-001")))
        # the board carries the additive `launch` {status,target,url,message}.
        _, board = self._get("/api/board")
        card = next(c for c in board["missions"] if c["id"] == "m-001")
        self.assertEqual(card["launch"]["status"], "running")
        self.assertEqual(card["launch"]["target"], "fake app")
        self.assertEqual(card["launch"]["url"], "http://localhost:9931")
        self.assertIn("running", card["launch"]["message"])
        # the mission detail carries it too.
        _, detail = self._get("/api/mission/m-001")
        self.assertEqual(detail["launch"]["status"], "running")

    def test_launch_threads_persisted_engine(self):
        fx.plant_simple(self.tmp, "m-001", stage="verify", issue=142,
                        worker_bin="copilot")
        self._rebuild_with_launch()
        status, _ = self._post("/api/mission/m-001/launch", {})
        self.assertEqual(status, 200)
        self.assertIn("ENV_WORKER_BIN: copilot", self._record("launch"))

    def test_launch_unknown_mission_is_404(self):
        self._rebuild_with_launch()
        with self.assertRaises(urllib.error.HTTPError) as cm:
            self._post("/api/mission/nope/launch", {})
        self.assertEqual(cm.exception.code, 404)

    # ── S110: in-flight guard — a duplicate launch while one is spinning up ────
    def test_concurrent_launch_dispatches_only_once_inflight_guard(self):
        """A second launch POST arriving WHILE the first is still spinning up
        (the SSE-lagged card lets the captain click RUN twice) must be an
        idempotent no-op — NOT a second concurrent `lcars launch`, which would
        spawn a duplicate app. Hold one launch mid-dispatch and prove a second
        launch() no-ops (returns a board) and the dispatch fires EXACTLY ONCE."""
        calls = []
        started = threading.Event()
        release = threading.Event()

        def fake_run(key, args, env_extra=None):
            calls.append(key)
            if key == "launch":
                # thread-1 is now PAST the guard, inside the dispatch; hold it
                # "in flight" until the second call has had its chance to race.
                started.set()
                release.wait(5)
            return 0

        self.actions._run = fake_run

        results = {}

        def first():
            results["a"] = self.actions.launch("m-001")

        t1 = threading.Thread(target=first, daemon=True)
        t1.start()
        self.assertTrue(started.wait(5), "first launch never reached dispatch")

        # second launch arrives WHILE the first is still in flight → no-op board.
        results["b"] = self.actions.launch("m-001")
        self.assertIn("board", results["b"])

        release.set()
        t1.join(5)
        self.assertFalse(t1.is_alive(), "first launch thread never finished")

        self.assertEqual([k for k in calls if k == "launch"], ["launch"],
                         "the in-flight guard let a duplicate launch dispatch")
        # the finally: cleared the in-flight mark, so a fresh launch dispatches.
        self.actions.launch("m-001")
        self.assertEqual(len([k for k in calls if k == "launch"]), 2)

    def test_launch_inflight_seed_no_ops_then_finally_clears(self):
        """Seeded (non-threaded) form of the guard: a mission already marked
        in-flight no-ops WITHOUT dispatching; a normal launch dispatches once and
        clears the in-flight mark in its finally."""
        calls = []

        def fake_run(key, args, env_extra=None):
            calls.append(key)
            return 0

        self.actions._run = fake_run
        # simulate a launch already in flight for this mission.
        self.actions._launching = {"m-001"}
        out = self.actions.launch("m-001")
        self.assertIn("board", out)
        self.assertNotIn("launch", calls)
        # nothing in flight now → the launch DOES dispatch once and clears itself.
        self.actions._launching = set()
        self.actions.launch("m-001")
        self.assertEqual(calls.count("launch"), 1)
        self.assertNotIn("m-001", self.actions._launching)

    # ── 2: stop dispatch + daemon-owned lifecycle (shutdown kills the app) ────
    def test_launch_stop_dispatches_stop(self):
        self._rebuild_with_launch()
        status, body = self._post("/api/mission/m-001/launch/stop", {})
        self.assertEqual(status, 200)
        self.assertTrue(body["ok"])
        rec = self._record("launch")
        self.assertIn("--stop", rec)
        self.assertIn("m-001", rec)

    def test_daemon_shutdown_kills_a_still_running_launch(self):
        """The daemon OWNS the launch: a fake app started via launch survives in
        its own process group; shutdown_launches() must group-kill it so nothing
        is orphaned. Assert the recorded pid is DEAD afterward."""
        scripts = dict(self.scripts)
        scripts["launch"] = _launch_stub(self.records["launch"], spawn_real=True)
        actions = Actions(repo_root=self.tmp, scripts=scripts,
                          worker_bin="/bin/echo")
        self.actions = actions  # tearDown reaps it too
        actions.launch("m-001")
        with open(self._mission_launch_json("m-001")) as fh:
            rec = json.load(fh)
        pid = rec["pid"]
        self.assertTrue(_pid_alive(pid), "the fake app never started")
        # the daemon tracked its process group ...
        self.assertIn("m-001", actions._launches)
        # ... and shutdown group-kills it — nothing orphaned.
        actions.shutdown_launches()
        import time
        deadline = time.time() + 3
        while time.time() < deadline and _pid_alive(pid):
            time.sleep(0.05)
        self.assertFalse(_pid_alive(pid),
                         "the launched app was orphaned by daemon shutdown")
        # the tracking table is cleared and shutdown is safe to call twice.
        self.assertNotIn("m-001", actions._launches)
        actions.shutdown_launches()

    def test_stop_kills_and_double_stop_is_a_clean_no_op(self):
        scripts = dict(self.scripts)
        scripts["launch"] = _launch_stub(self.records["launch"], spawn_real=True)
        actions = Actions(repo_root=self.tmp, scripts=scripts,
                          worker_bin="/bin/echo")
        self.actions = actions
        actions.launch("m-001")
        with open(self._mission_launch_json("m-001")) as fh:
            pid = json.load(fh)["pid"]
        actions.launch_stop("m-001")
        # the mission was pruned from the tracking table ...
        self.assertNotIn("m-001", actions._launches)
        # ... and a second stop is a clean no-op (idempotent, no raise).
        actions.launch_stop("m-001")
        self.assertNotIn("m-001", actions._launches)

    # ── failure path: a failed launch surfaces a readable message, no trace ───
    def test_launch_failure_surfaces_message_not_a_stack_trace(self):
        self._rebuild_with_launch(fail=True)
        status, body = self._post("/api/mission/m-001/launch", {})
        # the failure is surfaced as a readable launch record, not a 5xx/trace.
        self.assertEqual(status, 200)
        _, board = self._get("/api/board")
        card = next(c for c in board["missions"] if c["id"] == "m-001")
        self.assertEqual(card["launch"]["status"], "failed")
        self.assertTrue(card["launch"]["message"])
        self.assertNotIn("Traceback", json.dumps(body))
        self.assertNotIn("Traceback", json.dumps(card))

    # ── 3/4: read-only 403 + the additive field is truly additive ─────────────
    def test_launch_declined_when_read_only(self):
        httpd = make_server(self.adapter, host="127.0.0.1", port=0,
                            poll_interval=0.05, actions=None)
        port = httpd.server_address[1]
        t = threading.Thread(target=httpd.serve_forever, daemon=True)
        t.start()
        try:
            url = "http://127.0.0.1:%d/api/mission/m-001/launch" % port
            req = urllib.request.Request(url, data=b"{}", method="POST")
            with self.assertRaises(urllib.error.HTTPError) as cm:
                urllib.request.urlopen(req, timeout=5)
            self.assertEqual(cm.exception.code, 403)
        finally:
            httpd.shutdown()
            httpd.server_close()

    def test_mission_without_launch_json_has_no_launch_key(self):
        # a fresh mission (no launch.json) renders with NO `launch` key at all.
        card = self.adapter.mission("m-001")
        self.assertNotIn("launch", card)
        board = self.adapter.board()
        bcard = next(c for c in board["missions"] if c["id"] == "m-001")
        self.assertNotIn("launch", bcard)

    def _get(self, path, timeout=5):
        url = "http://127.0.0.1:%d%s" % (self.port, path)
        with urllib.request.urlopen(url, timeout=timeout) as r:
            return r.status, json.loads(r.read())


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

    def test_file_with_image_declined_when_read_only(self):
        # S92: an attached image must NOT bypass the view-only write block — the
        # write layer is off (actions=None), so /api/mission 403s before any
        # image is staged.
        url = "http://127.0.0.1:%d/api/mission" % self.port
        body = json.dumps({"idea": "x", "images": [_img()]}).encode("utf-8")
        req = urllib.request.Request(url, data=body, method="POST",
                                     headers={"Content-Type": "application/json"})
        with self.assertRaises(urllib.error.HTTPError) as cm:
            urllib.request.urlopen(req, timeout=5)
        self.assertIn(cm.exception.code, (403, 405))

    def test_github_adapter_is_read_only_by_construction(self):
        # The github adapter never carries a writer; make_server is called with
        # actions=None for it (see __main__.build). A POST is declined.
        self.assertEqual(GitHubAdapter.name, "github")


def _plant_bug(root, mid, *, parent, issue, stage="plan", estimate=None,
               override=None):
    d = fx.mission_dir(root, mid)
    state = {
        "id": mid, "type": "bug", "title": "Bug " + mid, "stage": stage,
        "created": "2026-06-14T10:00:00Z", "githubIssue": issue,
        "parentMission": parent, "linked": True,
        "branch": "lcars/%s" % mid, "base": "main",
    }
    if override is not None:
        scope, _, tier = override.partition(":")
        state["modelOverride"] = {"scope": scope, "tier": tier}
    fx.write_json(os.path.join(d, "state.json"), state)
    if estimate is not None:
        fx.write_json(os.path.join(d, "estimate.json"), estimate)


def _plant_pending(root, mid, *, stage="implement", question="reconcile?",
                   human_summary=None, escalation_type=None,
                   technical_detail=None):
    """Write a pending.json gate envelope for `mid` (BUG-027/BUG-028 tests)."""
    d = fx.mission_dir(root, mid)
    pending = {"stage": stage, "question": question}
    if human_summary is not None:
        pending["humanSummary"] = human_summary
    if escalation_type is not None:
        pending["escalationType"] = escalation_type
    if technical_detail is not None:
        pending["technicalDetail"] = technical_detail
    fx.write_json(os.path.join(d, "pending.json"), pending)


class RespondResumeTest(WriteEndpointBase):
    """BUG-028: answering a gate must RECORD the answer AND re-dispatch the run
    (the "& Resume" must be real), clearing the stale pending.json."""

    def _arm_run_lock(self):
        # point the run + resolve skills at a lock stub so the fire-and-forget
        # spawn records its argv (and the mission doesn't look already-running).
        # `actions` is closure-captured at make_server time, so REBUILD the server
        # with the rearmed Actions rather than mutating the live handler.
        for key in ("run", "resolve"):
            self.scripts[key] = _lock_stub(self.records[key], 0.05)
            try:
                os.unlink(self.records[key])
            except OSError:
                pass
        self.httpd.shutdown()
        self.thread.join()
        self.httpd.server_close()
        self.actions = Actions(repo_root=self.tmp, scripts=self.scripts,
                               worker_bin="/bin/echo")
        from lcars_serve.server import make_server as _mk
        self.httpd = _mk(self.adapter, host="127.0.0.1", port=0,
                         poll_interval=0.05, actions=self.actions)
        self.port = self.httpd.server_address[1]
        self.thread = threading.Thread(target=self.httpd.serve_forever,
                                       daemon=True)
        self.thread.start()

    def test_top_level_respond_redispatches_run_drive(self):
        # a top-level mission parked at a gate (resume pointer align, in-flight
        # implement) with a pending.json on disk.
        fx.plant_simple(self.tmp, "m-001", stage="implement", issue=142,
                        awaiting_human=True, pending_question="reconcile?")
        _plant_pending(self.tmp, "m-001", stage="implement")
        self._arm_run_lock()
        status, _ = self._post("/api/mission/m-001/respond",
                               {"answer": "reconcile by keeping the lock"})
        self.assertEqual(status, 200)
        # the answer was recorded via respond.sh
        self.assertIn("--mission m-001", self._record("respond"))
        # and the run driver was re-dispatched (fire-and-forget) for THIS mission
        run_rec = self._record_when("run", "m-001")
        self.assertIn("drive", run_rec)
        self.assertIn("--mission m-001", run_rec)
        # a top-level mission must NOT route through resolve-logs
        self.assertTrue(self._not_invoked("resolve"))
        # the stale pending.json is gone
        self.assertFalse(os.path.exists(
            os.path.join(fx.mission_dir(self.tmp, "m-001"), "pending.json")))

    def test_parented_bug_respond_resumes_resolve_logs_on_parent(self):
        # a logged-bug child parked at a gate: respond must resume the PARENT's
        # resolve-logs batch, NOT a standalone run drive on the child.
        fx.plant_simple(self.tmp, "m-001", stage="verify", issue=142,
                        worker_bin="/usr/bin/copilot")
        _plant_bug(self.tmp, "m-bug1", parent="m-001", issue=201,
                   stage="implement")
        # mark the child awaiting + give it a pending.json.
        bd = fx.mission_dir(self.tmp, "m-bug1")
        st = json.load(open(os.path.join(bd, "state.json")))
        st["awaitingHuman"] = True
        st["pendingQuestion"] = "reconcile?"
        fx.write_json(os.path.join(bd, "state.json"), st)
        _plant_pending(self.tmp, "m-bug1", stage="implement")
        self._arm_run_lock()
        status, _ = self._post("/api/mission/m-bug1/respond",
                               {"answer": "ok"})
        self.assertEqual(status, 200)
        # resolve-logs resumed on the PARENT
        res_rec = self._record_when("resolve", "m-001")
        self.assertIn("--parent m-001", res_rec)
        # the child's own run driver must NOT be spawned
        self.assertTrue(self._not_invoked("run"))
        # the child's stale pending.json is cleared
        self.assertFalse(os.path.exists(os.path.join(bd, "pending.json")))


class VerifyBugFoldTest(WriteEndpointBase):
    """BUG-030: a parented bug's Verify "accept" must FOLD via resolve-logs
    `complete` (no per-bug PR merge); a top-level mission still merges.

    BUG-032: the per-bug Verify must fold ONLY that one bug — it dispatches the
    SINGLE-bug mode (`complete --parent <p> --bug <mid>`), NOT the bulk
    `complete --parent <p>` that folds every sibling at once."""

    def test_parented_bug_approve_folds_via_resolve_complete(self):
        fx.plant_simple(self.tmp, "m-001", stage="verify", issue=142,
                        worker_bin="/usr/bin/copilot")
        _plant_bug(self.tmp, "m-bug1", parent="m-001", issue=201, stage="verify")
        _plant_bug(self.tmp, "m-bug2", parent="m-001", issue=202, stage="verify")
        status, _ = self._post("/api/mission/m-bug1/verify",
                               {"decision": "approve"})
        self.assertEqual(status, 200)
        res_rec = self._record("resolve")
        self.assertIn("complete", res_rec)
        self.assertIn("--parent m-001", res_rec)
        # BUG-032: it must target THIS one bug (single-bug mode), not the bulk
        # all-remaining accept. The dispatched argv carries --bug m-bug1, and it
        # must NOT name the sibling m-bug2 (one click ≠ whole batch).
        self.assertIn("--bug m-bug1", res_rec)
        self.assertNotIn("m-bug2", res_rec)
        # it must NOT merge a per-bug PR via approve.sh
        self.assertTrue(self._not_invoked("approve"))
        # and the parent's engine is inherited on the fold dispatch
        self.assertIn("ENV_WORKER_BIN: /usr/bin/copilot", res_rec)

    def test_top_level_approve_still_merges_via_approve(self):
        fx.plant_simple(self.tmp, "m-001", stage="verify", issue=142)
        status, _ = self._post("/api/mission/m-001/verify",
                               {"decision": "approve"})
        self.assertEqual(status, 200)
        # approve is now FIRE-AND-FORGET (BUG-040) → its record is written
        # asynchronously after the POST returns; poll for it.
        self.assertIn("--mission m-001", self._record_when("approve", "m-001"))
        # a top-level mission must NOT route to resolve-logs complete
        self.assertTrue(self._not_invoked("resolve"))


class ApproveNonBlockingTest(WriteEndpointBase):
    """BUG-040: the Merge (approve) click must be NON-BLOCKING. When a reconcile/
    self-heal runs, approve.sh can take minutes; the HTTP request must dispatch
    fire-and-forget (Popen, _spawn) and return promptly so the dialog never spins.
    """

    def test_approve_returns_promptly_without_blocking_on_the_merge(self):
        """Point the approve skill at a stub that sleeps ~3s; verify(approve) must
        return well before that (fire-and-forget), not block on the long merge."""
        import time
        rec = os.path.join(self.tmp, "rec-approveslow.txt")
        scripts = dict(self.scripts)
        scripts["approve"] = _sleep_stub(rec, sleep_secs=3)
        actions = Actions(repo_root=self.tmp, scripts=scripts)
        t0 = time.time()
        actions.verify("m-001", "approve")
        elapsed = time.time() - t0
        self.assertLess(elapsed, 1.5,
                        "verify(approve) blocked on the long merge (%.2fs)"
                        % elapsed)

    def test_approve_uses_a_nonblocking_spawn(self):
        """The fire-and-forget seam for approve is Popen (no wait): assert
        verify(approve) on a top-level mission dispatches approve.sh via Popen
        and never subprocess.run."""
        import unittest.mock as mock

        run_calls = []
        popen_calls = []

        class _FakeCompleted(object):
            returncode = 0
            stdout = b""

        def _rec_run(cmd, *a, **k):
            run_calls.append(cmd)
            return _FakeCompleted()

        class _FakePopen(object):
            def __init__(self, cmd, *a, **k):
                popen_calls.append(cmd)

        with mock.patch.object(subprocess, "Popen", _FakePopen), \
                mock.patch.object(subprocess, "run", _rec_run):
            actions = Actions(repo_root=self.tmp, scripts=self.scripts)
            actions.verify("m-001", "approve")

        script = self.scripts["approve"]
        self.assertTrue(any(script in cmd for cmd in popen_calls),
                        "approve.sh must be dispatched via Popen (_spawn)")
        self.assertFalse(any(script in cmd for cmd in run_calls),
                         "approve.sh must NOT block (subprocess.run)")

    def test_approve_returns_current_mission_state_immediately(self):
        """verify(approve) returns the mission state promptly (the dialog closes
        on dispatch and the board/SSE reflects the evolving state)."""
        fx.plant_simple(self.tmp, "m-001", stage="verify", issue=142,
                        pr_url="https://github.com/acme/repo/pull/77",
                        pr_number=77, review="open")
        result = self.actions.verify("m-001", "approve")
        # a mission/board state is returned (not an exception/hang).
        self.assertTrue("mission" in result or "board" in result)


def _emit_stub(record_path, marker):
    """A fire-and-forget stub that PRINTS a marker to stdout/stderr (so a test can
    assert the spawn CAPTURED it) and also records its argv. Used to prove _spawn
    redirects child output to a durable log instead of /dev/null (BUG-051)."""
    fd, path = tempfile.mkstemp(suffix=".sh")
    os.close(fd)
    script = (
        '#!/usr/bin/env bash\n'
        '{ printf "ARGV: %s\\n" "$*"; } >> "' + record_path + '"\n'
        'printf "' + marker + '\\n"\n'          # to stdout
        'printf "' + marker + '-ERR\\n" >&2\n'  # to stderr (merged via STDOUT)
        'exit 0\n'
    )
    with open(path, "w") as fh:
        fh.write(script)
    os.chmod(path, 0o755)
    return path


class SpawnCaptureTest(WriteEndpointBase):
    """BUG-051: the fire-and-forget _spawn must NOT discard the detached child's
    output (approve/reconcile/driver, incl. the die reason) — it must be captured
    to a durable per-run log under .git/lcars/ so the cause survives."""

    def test_spawn_gives_popen_a_real_file_handle_not_devnull(self):
        """Assert _spawn hands subprocess.Popen a real writable file object for
        stdout — never subprocess.DEVNULL."""
        import unittest.mock as mock

        captured = {}

        class _FakePopen(object):
            def __init__(self, *a, **k):
                captured["stdout"] = k.get("stdout")
                captured["stderr"] = k.get("stderr")

        with mock.patch.object(subprocess, "Popen", _FakePopen):
            actions = Actions(repo_root=self.tmp, scripts=self.scripts)
            actions._spawn("run", ["drive", "--mission", "m-001"])

        self.assertIsNot(captured.get("stdout"), subprocess.DEVNULL,
                         "_spawn discarded child stdout to DEVNULL")
        # a real captured file handle, not the int DEVNULL sentinel
        self.assertTrue(hasattr(captured.get("stdout"), "fileno"),
                        "_spawn did not give Popen a real file handle for stdout")

    def test_spawn_writes_child_output_to_a_captured_log_under_git_lcars(self):
        """End-to-end: the detached child's stdout/stderr land in a durable log
        file under .git/lcars/, not /dev/null."""
        import time
        rec = os.path.join(self.tmp, "rec-emit.txt")
        scripts = dict(self.scripts)
        scripts["run"] = _emit_stub(rec, "DIE-REASON-cherry-pick-failed")
        actions = Actions(repo_root=self.tmp, scripts=scripts)
        actions._spawn("run", ["drive", "--mission", "m-001"])

        log_path = os.path.join(self.tmp, ".git", "lcars", "logs",
                                "spawn-run-m-001.log")
        deadline = time.time() + 5
        contents = ""
        while time.time() < deadline:
            if os.path.exists(log_path):
                with open(log_path) as fh:
                    contents = fh.read()
                if "DIE-REASON-cherry-pick-failed" in contents:
                    break
            time.sleep(0.02)

        self.assertTrue(os.path.exists(log_path),
                        "no captured spawn log was written under .git/lcars/logs")
        self.assertIn("DIE-REASON-cherry-pick-failed", contents,
                      "the detached child's stdout was not captured to the log")
        self.assertIn("DIE-REASON-cherry-pick-failed-ERR", contents,
                      "the detached child's stderr was not captured to the log")


if __name__ == "__main__":
    unittest.main()

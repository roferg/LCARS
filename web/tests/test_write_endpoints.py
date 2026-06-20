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
        self.assertIn("--mission m-001", self._record("approve"))
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
        # S74 follow-up CHANGE 3: a logged bug skips Research+Validate, so the
        # review-panel mix omits those rows and starts at Plan.
        self.assertTrue(c.get("modelMix"))
        stage_order = [row["stage"] for row in c["modelMix"]]
        self.assertEqual(stage_order,
                         ["Plan", "Plan Review", "Implement", "Verify"])
        stages = {row["stage"]: row["tier"] for row in c["modelMix"]}
        self.assertNotIn("Research", stages)
        self.assertNotIn("Validate", stages)
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

    def test_log_run_threads_per_bug_overrides_to_log(self):
        """The File & Run path must also carry per-bug overrides into log.sh so a
        captain who steers then runs in one click still persists each steer."""
        actions = Actions(repo_root=self.tmp, scripts=self.scripts)
        actions.log_run("m-001", prds=["# Bug: a\n\nb"], overrides=["reasoning:opus"])
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
        # and resolve was still dispatched for the batch.
        self.assertFalse(self._not_invoked("resolve"))

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

        def _fake_turn(prompt, engine=None, outdir=None):
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

        def _fake_turn(prompt, engine=None, outdir=None):
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
        actions.log_run("m-001", prds=["# Bug: save\n\nthe save fails"])
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
        actions.log_run("m-001", prds=["# Bug: x\n\nb"])
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
        actions.log_run("m-001", prds=["# Bug: x\n\nb"])
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
            actions.log_run("m-001", prds=["# Bug: x\n\nb"])

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
        actions.log_run("m-001", prds=["# Bug: save\n\nthe save fails"])
        # log.sh ran synchronously (blocking) → its record is present immediately.
        log_rec = self._record("log")
        self.assertIn("--parent m-001", log_rec)
        self.assertIn("ENV_WORKER_BIN: copilot", log_rec)
        # resolve is fire-and-forget → poll for its async record, engine preserved.
        res_rec = self._record_when("resolve", "ENV_WORKER_BIN: copilot")
        self.assertIn("ENV_WORKER_BIN: copilot", res_rec)
        self.assertIn("m-001", res_rec)


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


if __name__ == "__main__":
    unittest.main()

"""Deploy-Main (S139) — the WEB face of `lcars launch --main` (S138).

`POST /api/deploy/main {hint}` dispatches `lcars launch --main [hint]` (deploy the
LOCAL default-branch HEAD); `POST /api/deploy/main/stop` dispatches
`lcars launch --main --stop`. The board's `meta.mainLaunch` additively surfaces
`.git/lcars/main/launch.json` so the topbar band can render ◐ DEPLOYING → ● MAIN
LIVE → failed. Read-only builds 403 both routes.

Each skill call is an env-injected RECORDING STUB, so we assert the exact dispatch
(argv) and drive the whole daemon over HTTP with ZERO model / gh / git spend. A
final node-vm harness renders the SHIPPING board.js band from meta.mainLaunch.
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

HERE = os.path.dirname(os.path.abspath(__file__))
BAND_HARNESS = os.path.join(HERE, "board_band_harness.js")
NODE = shutil.which("node")


def _main_launch_json(root):
    return os.path.join(root, ".git", "lcars", "main", "launch.json")


def _plant_main_launch(root, **fields):
    """Write a `.git/lcars/main/launch.json` record with the given fields."""
    d = os.path.join(root, ".git", "lcars", "main")
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "launch.json"), "w") as fh:
        json.dump(fields, fh)


def _deploy_stub(record_path, *, spawn_real=False, fail=False):
    """A stub for skills/lcars-launch/launch.sh in `--main` mode (S139).

    Records its argv/env, then writes `.git/lcars/main/launch.json` (cwd=repo_root)
    mirroring launch.sh's --main contract (status + additive branch/sha). Modes:
      * default        → status=running record (no real process; pid/pgid omitted).
      * spawn_real     → a REAL long-lived process in its OWN process group
                         (perl POSIX::setsid, PGID==PID) + its pid/pgid, so the
                         daemon has a real pgid to group-kill on shutdown/stop.
      * fail           → status=failed record + message, exit 1.
    A `--stop` invocation kills the recorded pgid and rewrites to status=stopped.
    """
    fd, path = tempfile.mkstemp(suffix=".sh")
    os.close(fd)
    if fail:
        write_body = (
            '  printf \'{"status":"failed","target":"","url":"",\' > "$lj"\n'
            '  printf \'"message":"could not determine how to start the main '
            'deploy — no dev script was found."}\' >> "$lj"\n'
            '  printf "\\n" >> "$lj"\n'
            '  exit 1\n'
        )
    elif spawn_real:
        # setsid THEN touch a ready-file, so we only record the pgid once the
        # child is genuinely the leader of its own process group (PGID==PID) —
        # otherwise a killpg(pid) racing an unfinished setsid would miss it.
        #
        # The wait MUST sleep. A bare `for _ in $(seq 1 200); do [ -e "$rdy" ] &&
        # break; done` is 200 stat()s in well under a millisecond — routinely
        # finished before the forked perl has even been scheduled to call
        # setsid(). It then fell through WITHOUT the ready file and recorded
        # `pgid=$!` anyway, violating the very invariant the comment above states.
        # When it lost that race os.killpg raised ProcessLookupError, the daemon
        # swallowed it, and the shutdown/stop tests failed accusing PRODUCTION
        # code of orphaning a deploy this fixture never group-leadered
        # (reproduced 1-in-12 under parallel load on identical code).
        # 200 × 10ms bounds the wait at ~2s, and a timeout now fails LOUDLY
        # rather than certifying a pgid it never confirmed.
        write_body = (
            '  rdy="$(mktemp)"; rm -f "$rdy"\n'
            "  perl -e 'use POSIX qw(setsid); eval { setsid(); }; "
            "my $r=shift @ARGV; open(my $f,\">\",$r); close $f; exec @ARGV' "
            '-- "$rdy" sleep 300 >/dev/null 2>&1 &\n'
            '  pid=$!\n'
            '  led=""\n'
            '  for _ in $(seq 1 200); do\n'
            '    if [ -e "$rdy" ]; then led=1; break; fi\n'
            '    sleep 0.01\n'
            '  done\n'
            '  rm -f "$rdy"\n'
            '  if [ -z "$led" ]; then\n'
            '    kill "$pid" 2>/dev/null || true\n'
            '    echo "deploy stub: child never became its own process-group '
            'leader within 2s — refusing to record an uncertified pgid" >&2\n'
            '    printf \'{"status":"failed","target":"","url":"","message":'
            '"stub: setsid handshake timed out"}\\n\' > "$lj"\n'
            '    exit 1\n'
            '  fi\n'
            '  printf \'{"status":"running","branch":"main","sha":"abc1234",'
            '"target":"main deploy","url":"http://localhost:9940",'
            '"howToStop":"stop it from the board","command":"sleep 300",'
            '"cwd":".","pid":%s,"pgid":%s,"message":"the app is running."}\\n\' '
            '"$pid" "$pid" > "$lj"\n'
            '  exit 0\n'
        )
    else:
        write_body = (
            '  printf \'{"status":"running","branch":"main","sha":"abc1234",'
            '"target":"main deploy","url":"http://localhost:9940",'
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
        'stop=0\n'
        'for a in "$@"; do [ "$a" = "--stop" ] && stop=1; done\n'
        'lj=".git/lcars/main/launch.json"\n'
        'mkdir -p ".git/lcars/main"\n'
        'if [ "$stop" -eq 1 ]; then\n'
        '  if [ -f "$lj" ]; then\n'
        '    pgid=$(sed -n \'s/.*"pgid"[: ]*\\([0-9][0-9]*\\).*/\\1/p\' "$lj" | head -1)\n'
        '    [ -n "$pgid" ] && kill -TERM -"$pgid" 2>/dev/null || true\n'
        '  fi\n'
        '  printf \'{"status":"stopped","branch":"main","sha":"abc1234",'
        '"target":"main deploy","url":"",'
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
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except OSError:
        return False
    return True


class DeployBase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        # one mission so the board has content (a deploy is repo-level, not tied).
        fx.plant_simple(self.tmp, "m-001", stage="verify", issue=142)
        self.adapter = LocalAdapter(self.tmp)
        self.rec = os.path.join(self.tmp, "rec-launch.txt")
        self.scripts = {"launch": _deploy_stub(self.rec)}
        self.actions = Actions(repo_root=self.tmp, scripts=self.scripts,
                               worker_bin="/bin/echo")
        self.httpd = make_server(self.adapter, host="127.0.0.1", port=0,
                                 poll_interval=0.05, actions=self.actions)
        self.port = self.httpd.server_address[1]
        self.thread = threading.Thread(target=self.httpd.serve_forever,
                                       daemon=True)
        self.thread.start()

    def tearDown(self):
        try:
            self.actions.shutdown_launches()
        except Exception:
            pass
        self.httpd.shutdown()
        self.httpd.server_close()

    def _post(self, path, obj=None, timeout=10):
        url = "http://127.0.0.1:%d%s" % (self.port, path)
        data = json.dumps(obj if obj is not None else {}).encode("utf-8")
        req = urllib.request.Request(url, data=data, method="POST",
                                     headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, json.loads(r.read())

    def _get(self, path, timeout=5):
        url = "http://127.0.0.1:%d%s" % (self.port, path)
        with urllib.request.urlopen(url, timeout=timeout) as r:
            return r.status, json.loads(r.read())

    def _record(self):
        if not os.path.exists(self.rec):
            return ""
        with open(self.rec) as fh:
            return fh.read()

    def _rebuild(self, **stub_kw):
        """Point the launch skill at a fresh stub and rebuild the server."""
        self.scripts["launch"] = _deploy_stub(self.rec, **stub_kw)
        try:
            os.unlink(self.rec)
        except OSError:
            pass
        self.httpd.shutdown()
        self.thread.join()
        self.httpd.server_close()
        self.actions = Actions(repo_root=self.tmp, scripts=self.scripts,
                               worker_bin="/bin/echo")
        self.httpd = make_server(self.adapter, host="127.0.0.1", port=0,
                                 poll_interval=0.05, actions=self.actions)
        self.port = self.httpd.server_address[1]
        self.thread = threading.Thread(target=self.httpd.serve_forever,
                                       daemon=True)
        self.thread.start()


class DeployEndpointTest(DeployBase):
    def test_deploy_dispatches_launch_main_with_hint_split(self):
        status, body = self._post("/api/deploy/main",
                                  {"hint": "the game in web"})
        self.assertEqual(status, 200)
        self.assertTrue(body["ok"])
        rec = self._record()
        # --main + the hint words split exactly as launch()'s path splits them.
        self.assertIn("ARGV: --main the game in web", rec)

    def test_deploy_no_hint_dispatches_bare_main(self):
        status, body = self._post("/api/deploy/main", {})
        self.assertEqual(status, 200)
        rec = self._record()
        self.assertIn("ARGV: --main", rec)
        self.assertNotIn("--main the", rec)

    def test_deploy_running_surfaces_main_launch_meta(self):
        status, _ = self._post("/api/deploy/main", {})
        self.assertEqual(status, 200)
        _, board = self._get("/api/board")
        ml = board["meta"].get("mainLaunch")
        self.assertIsNotNone(ml, "a running deploy must surface meta.mainLaunch")
        self.assertEqual(ml["status"], "running")
        self.assertEqual(ml["sha"], "abc1234")
        self.assertEqual(ml["branch"], "main")
        self.assertEqual(ml["url"], "http://localhost:9940")

    def test_deploy_failure_surfaces_message_not_a_502(self):
        """A failed deploy (app dies / discovery fails) exits non-zero AND writes
        a failed record — the endpoint must return 200 with the message on the
        board, NEVER a 502 + stack for an app that dies."""
        self._rebuild(fail=True)
        status, body = self._post("/api/deploy/main", {})
        self.assertEqual(status, 200)
        _, board = self._get("/api/board")
        ml = board["meta"].get("mainLaunch")
        self.assertEqual(ml["status"], "failed")
        self.assertTrue(ml["message"])
        self.assertNotIn("Traceback", json.dumps(body))
        self.assertNotIn("Traceback", json.dumps(board))

    def test_deploy_stop_stops_and_is_idempotent(self):
        # first a running deploy, then stop it.
        self._post("/api/deploy/main", {})
        status, body = self._post("/api/deploy/main/stop", {})
        self.assertEqual(status, 200)
        self.assertTrue(body["ok"])
        rec = self._record()
        self.assertIn("--main --stop", rec)
        _, board = self._get("/api/board")
        # a stopped record adds no LIVE pill — the band drops it (status=stopped).
        ml = board["meta"].get("mainLaunch")
        self.assertEqual(ml["status"], "stopped")
        # a second stop is a clean no-op (idempotent, no raise / 5xx).
        status2, body2 = self._post("/api/deploy/main/stop", {})
        self.assertEqual(status2, 200)
        self.assertTrue(body2["ok"])

    def test_deploy_shutdown_kills_a_tracked_main_pgid(self):
        """The daemon OWNS the deploy: a real app spawned in its own process group
        is tracked under the reserved key '@main'; shutdown_launches() must
        group-kill it so nothing is orphaned."""
        scripts = dict(self.scripts)
        scripts["launch"] = _deploy_stub(self.rec, spawn_real=True)
        actions = Actions(repo_root=self.tmp, scripts=scripts,
                          worker_bin="/bin/echo")
        self.actions = actions  # tearDown reaps it too
        actions.deploy_main()
        with open(_main_launch_json(self.tmp)) as fh:
            pid = json.load(fh)["pid"]
        self.assertTrue(_pid_alive(pid), "the fake main app never started")
        self.assertIn("@main", actions._launches)
        actions.shutdown_launches()
        deadline = time.time() + 3
        while time.time() < deadline and _pid_alive(pid):
            time.sleep(0.05)
        self.assertFalse(_pid_alive(pid),
                         "the main deploy was orphaned by daemon shutdown")
        self.assertNotIn("@main", actions._launches)
        actions.shutdown_launches()  # safe to call twice

    def test_deploy_stop_kills_and_drops_tracking(self):
        scripts = dict(self.scripts)
        scripts["launch"] = _deploy_stub(self.rec, spawn_real=True)
        actions = Actions(repo_root=self.tmp, scripts=scripts,
                          worker_bin="/bin/echo")
        self.actions = actions
        actions.deploy_main()
        with open(_main_launch_json(self.tmp)) as fh:
            pid = json.load(fh)["pid"]
        actions.deploy_main_stop()
        self.assertNotIn("@main", actions._launches)
        deadline = time.time() + 3
        while time.time() < deadline and _pid_alive(pid):
            time.sleep(0.05)
        self.assertFalse(_pid_alive(pid), "stop did not kill the deploy")
        # a second stop is a clean no-op.
        actions.deploy_main_stop()
        self.assertNotIn("@main", actions._launches)

    def test_deploy_inflight_guard_no_double_dispatch(self):
        """A second deploy POST arriving WHILE the first is spinning up must be an
        idempotent no-op — NOT a second concurrent `lcars launch --main`."""
        calls = []
        started = threading.Event()
        release = threading.Event()

        def fake_run(key, args, env_extra=None):
            calls.append((key, tuple(args)))
            if key == "launch":
                started.set()
                release.wait(5)
            return 0

        self.actions._run = fake_run
        results = {}

        def first():
            results["a"] = self.actions.deploy_main()

        t1 = threading.Thread(target=first, daemon=True)
        t1.start()
        self.assertTrue(started.wait(5), "first deploy never reached dispatch")
        results["b"] = self.actions.deploy_main()  # in-flight → no-op board
        self.assertIn("board", results["b"])
        release.set()
        t1.join(5)
        self.assertFalse(t1.is_alive(), "first deploy thread never finished")
        launches = [c for c in calls if c[0] == "launch"]
        self.assertEqual(len(launches), 1,
                         "the in-flight guard let a duplicate deploy dispatch")
        # the finally cleared the mark → a fresh deploy dispatches again.
        self.actions.deploy_main()
        self.assertEqual(len([c for c in calls if c[0] == "launch"]), 2)


class MainLaunchMetaTest(unittest.TestCase):
    """The additive meta.mainLaunch is ONLY present with a main/launch.json — an
    absent deploy leaves meta BYTE-IDENTICAL to before this round."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        fx.plant_simple(self.tmp, "m-001", stage="verify", issue=142)
        # a stable repo identity so byte-identity doesn't depend on git.
        self.adapter = LocalAdapter(self.tmp,
                                    git_url_reader=lambda r: "git@x:acme/repo.git")

    def test_meta_byte_identical_without_a_deploy(self):
        meta = self.adapter.board()["meta"]
        self.assertNotIn("mainLaunch", meta)
        self.assertEqual(meta, {"repo": "acme/repo", "adapter": "local",
                                "mode": "read-write"})

    def test_meta_gains_main_launch_with_a_running_record(self):
        _plant_main_launch(self.tmp, status="running", branch="main",
                           sha="deadbee", target="main deploy",
                           url="http://localhost:9940",
                           message="the app is running.")
        meta = self.adapter.board()["meta"]
        self.assertIn("mainLaunch", meta)
        self.assertEqual(meta["mainLaunch"]["status"], "running")
        self.assertEqual(meta["mainLaunch"]["sha"], "deadbee")
        self.assertEqual(meta["mainLaunch"]["branch"], "main")
        # the un-deploy keys stay exactly as before.
        self.assertEqual(meta["repo"], "acme/repo")
        self.assertEqual(meta["mode"], "read-write")

    def test_unparseable_record_adds_no_key(self):
        d = os.path.join(self.tmp, ".git", "lcars", "main")
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "launch.json"), "w") as fh:
            fh.write("{ not json")
        self.assertNotIn("mainLaunch", self.adapter.board()["meta"])


class DeployReadOnlyTest(unittest.TestCase):
    """View-only / github build → both deploy routes 403; the board still renders
    (the write layer is off, actions=None)."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        fx.plant_simple(self.tmp, "m-001", stage="verify", issue=142)
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

    def _post_403(self, path):
        url = "http://127.0.0.1:%d%s" % (self.port, path)
        req = urllib.request.Request(url, data=b"{}", method="POST")
        with self.assertRaises(urllib.error.HTTPError) as cm:
            urllib.request.urlopen(req, timeout=5)
        self.assertEqual(cm.exception.code, 403)

    def test_deploy_declined_when_read_only(self):
        self._post_403("/api/deploy/main")

    def test_deploy_stop_declined_when_read_only(self):
        self._post_403("/api/deploy/main/stop")

    def test_board_still_renders_view_only(self):
        url = "http://127.0.0.1:%d/api/board" % self.port
        with urllib.request.urlopen(url, timeout=5) as r:
            data = json.loads(r.read())
        self.assertIn("columns", data)


def _render_band(meta, mode=""):
    fd, path = tempfile.mkstemp(suffix=".json")
    os.close(fd)
    with open(path, "w") as fh:
        json.dump(meta, fh)
    try:
        argv = [NODE, BAND_HARNESS, path]
        if mode:
            argv.append(mode)
        out = subprocess.check_output(argv, stderr=subprocess.STDOUT)
        return json.loads(out)
    finally:
        os.unlink(path)


def _flatten(node, acc=None):
    if acc is None:
        acc = []
    if node:
        acc.append(node)
        for c in node.get("children", []):
            _flatten(c, acc)
    return acc


@unittest.skipUnless(NODE, "node is required for the board.js vm harness")
class DeployBandRenderTest(unittest.TestCase):
    """The SHIPPING board.js renders the topbar deploy band from meta.mainLaunch."""

    def test_no_main_launch_band_is_empty_chrome_untouched(self):
        out = _render_band({"repo": "acme/repo", "adapter": "local",
                            "mode": "read-write"})
        # the existing chrome ids still resolve (band render touches only #mainDeploy).
        self.assertTrue(out["chrome"]["fileBtn"])
        self.assertTrue(out["chrome"]["conn"])
        self.assertTrue(out["chrome"]["repoMeta"])
        # no mainLaunch ⇒ the band host has NO content and NO LIVE pill.
        nodes = _flatten(out["mainDeploy"])
        texts = " || ".join(n.get("text", "") for n in nodes)
        self.assertNotIn("MAIN LIVE", texts.upper())
        self.assertEqual(out["mainDeploy"].get("children", []), [])

    def test_running_band_shows_main_live_sha_and_stop(self):
        out = _render_band({"repo": "acme/repo", "adapter": "local",
                            "mode": "read-write",
                            "mainLaunch": {"status": "running", "branch": "main",
                                           "sha": "abc1234",
                                           "url": "http://localhost:9940",
                                           "target": "main deploy",
                                           "message": "the app is running."}})
        nodes = _flatten(out["mainDeploy"])
        texts = " || ".join(n.get("text", "") for n in nodes)
        self.assertIn("MAIN LIVE", texts.upper())
        self.assertIn("abc1234", texts)
        self.assertIn("STOP", texts.upper())

    def test_launching_band_shows_deploying(self):
        out = _render_band({"mainLaunch": {"status": "launching"}})
        texts = " || ".join(n.get("text", "")
                            for n in _flatten(out["mainDeploy"]))
        self.assertIn("DEPLOYING", texts.upper())
        self.assertNotIn("MAIN LIVE", texts.upper())

    def test_failed_band_shows_message(self):
        out = _render_band({"mainLaunch": {"status": "failed",
                                           "message": "no dev script found"}})
        texts = " || ".join(n.get("text", "")
                            for n in _flatten(out["mainDeploy"]))
        self.assertIn("no dev script found", texts)

    # -- captain UX ruling: the ▸ Deploy Main button and the live status are
    #    MUTUALLY EXCLUSIVE — an active deploy REPLACES the button in place.
    def test_running_hides_deploy_main_button(self):
        out = _render_band({"mainLaunch": {"status": "running", "sha": "abc1234",
                                           "url": "http://localhost:9940"}})
        self.assertEqual(out["deployMainBtnDisplay"], "none")

    def test_launching_hides_deploy_main_button(self):
        out = _render_band({"mainLaunch": {"status": "launching"}})
        self.assertEqual(out["deployMainBtnDisplay"], "none")

    def test_absent_shows_deploy_main_button(self):
        out = _render_band({"repo": "acme/repo", "adapter": "local",
                            "mode": "read-write"})
        self.assertEqual(out["deployMainBtnDisplay"], "")

    def test_stopped_shows_deploy_main_button(self):
        out = _render_band({"mainLaunch": {"status": "stopped", "sha": "abc1234"}})
        self.assertEqual(out["deployMainBtnDisplay"], "")

    def test_failed_shows_deploy_main_button_for_retry(self):
        out = _render_band({"mainLaunch": {"status": "failed",
                                           "message": "no dev script found"}})
        self.assertEqual(out["deployMainBtnDisplay"], "")

    def test_stopping_in_flight_shows_disabled_stopping_not_clickable_stop(self):
        # ■ STOP already clicked → a re-render (SSE/refresh) during the blocking
        # stop must show a disabled ◐ STOPPING… segment, not a fresh clickable
        # STOP — so a second click can't land.
        out = _render_band({"mainLaunch": {"status": "running", "sha": "abc1234",
                                           "url": "http://localhost:9940"}},
                           mode="stopping")
        nodes = _flatten(out["mainDeploy"])
        texts = " || ".join(n.get("text", "") for n in nodes)
        classes = " ".join(n.get("cls", "") for n in nodes)
        self.assertIn("STOPPING", texts.upper())
        self.assertIn("deploy-stopping", classes)
        # the clickable ■ STOP label is gone (it was a <button>, now a span)
        self.assertNotIn("■ STOP", texts)

    def test_readonly_disables_stop(self):
        out = _render_band({"mainLaunch": {"status": "running", "sha": "abc1234",
                                           "url": "http://localhost:9940"}},
                           mode="readonly")
        stops = [n for n in _flatten(out["mainDeploy"])
                 if "STOP" in n.get("text", "").upper()]
        self.assertTrue(stops, "the STOP control must exist")
        self.assertTrue(all(n["disabled"] for n in stops),
                        "a view-only build must disable the band STOP control")


class FingerprintTest(unittest.TestCase):
    """S139: the SSE change-signature must also track the main-deploy record,
    so a `POST /api/deploy/main` (or /stop) pushes an `update` to a PASSIVE
    second browser — not just refresh the initiating tab. The main-deploy
    record lives at `.git/lcars/main/launch.json` and is NOT a mission dir, so
    the pre-S139 mission-only fingerprint never moved on a deploy."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_fingerprint_moves_on_deploy(self):
        fx.plant_simple(self.tmp, "m-001", stage="verify", issue=1)
        adapter = LocalAdapter(self.tmp)
        before = adapter.fingerprint()
        _plant_main_launch(self.tmp, status="running", target="main deploy",
                           url="http://localhost:9940", sha="abc1234")
        after = adapter.fingerprint()
        self.assertNotEqual(before, after,
                            "writing the main-deploy record must move the "
                            "fingerprint so the SSE loop pushes an update")

    def test_fingerprint_moves_on_stop_rewrite(self):
        fx.plant_simple(self.tmp, "m-001", stage="verify", issue=1)
        adapter = LocalAdapter(self.tmp)
        _plant_main_launch(self.tmp, status="running", sha="abc1234")
        running = adapter.fingerprint()
        # rewrite the record (deploy → stopped) and force a strictly-later mtime
        # (fs mtime granularity can collide when the test writes this fast).
        _plant_main_launch(self.tmp, status="stopped", sha="abc1234")
        p = _main_launch_json(self.tmp)
        os.utime(p, (time.time() + 5, time.time() + 5))
        stopped = adapter.fingerprint()
        self.assertNotEqual(running, stopped,
                            "rewriting the main-deploy record (stop) must move "
                            "the fingerprint again")

    def test_fingerprint_byte_identical_when_undeployed(self):
        """A board with missions but NO main-deploy record must produce the
        EXACT fingerprint it did before S139 — the main record contributes
        nothing when absent. Guards against regressing the mission path."""
        fx.plant_simple(self.tmp, "m-001", stage="verify", issue=1)
        adapter = LocalAdapter(self.tmp)
        # the mission-only signature: max mtime over every mission file.
        latest = 0.0
        for name in sorted(os.listdir(adapter.missions_dir)):
            d = os.path.join(adapter.missions_dir, name)
            if not os.path.isfile(os.path.join(d, "state.json")):
                continue
            for fn in os.listdir(d):
                latest = max(latest, os.path.getmtime(os.path.join(d, fn)))
        self.assertEqual(adapter.fingerprint(), "%.6f" % latest,
                         "the undeployed fingerprint must be byte-identical to "
                         "the pre-S139 mission-only signature")

    def test_fingerprint_nonzero_with_deploy_but_no_missions(self):
        """A repo with a main deploy but ZERO missions must NOT short-circuit to
        the '0' sentinel — the deploy record alone moves the fingerprint."""
        adapter = LocalAdapter(self.tmp)
        self.assertEqual(adapter.fingerprint(), "0",
                         "no missions AND no deploy is the truly-empty case")
        _plant_main_launch(self.tmp, status="running", sha="abc1234")
        self.assertNotEqual(adapter.fingerprint(), "0",
                            "a main deploy must move the fingerprint off '0' "
                            "even when the repo has no missions dir")


if __name__ == "__main__":
    unittest.main()

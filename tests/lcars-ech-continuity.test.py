"""S316 durable proof at the ECH CLI, process, evidence, and playbook seams."""
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = Path(os.environ.get("LCARS_ECH_SCRIPT", ROOT / "skills/lcars-eeh/ech.sh"))
PLAYBOOK = ROOT / "skills/lcars-eeh/HOLOGRAM-COMMAND-MODE.md"


class Continuity(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="lcars-s316-", dir="/tmp")
        self.addCleanup(self.scratch.cleanup)
        self.repo = Path(self.scratch.name)
        subprocess.run(["git", "init", "-qb", "main", str(self.repo)], check=True)
        self.data = self.repo / ".git/lcars"
        self.ap = self.data / "autopilot.json"
        self.write(self.ap, {
            "scope": ["M1"], "missions": {"M1": {"id": "m1"}},
            "drivers": {}, "questions": {}, "pending": {},
            "push": {"mode": "local-only"}, "testCommand": "true",
        })
        self.write(self.data / "config.json", {"testCommand": "true", "engine": "copilot"})
        self.state = self.data / "missions/m1/state.json"
        self.write(self.state, {"stage": "verify", "branch": "main"})
        self.env = dict(os.environ, LCARS_ECH_CWD=str(self.repo), TMPDIR=str(self.repo),
                        LCARS_ECH_WATCH_INTERVAL="0.1", LCARS_ECH_WAIT_LIMIT="1")

    @staticmethod
    def write(path, body):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(body))

    def run_ech(self, *args, rc=0, script=SCRIPT):
        result = subprocess.run(["bash", str(script), *args], env=self.env, cwd=self.repo,
                                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, text=True, timeout=15)
        self.assertEqual(result.returncode, rc, result.stdout)
        return result.stdout

    def spawn(self, args, **kwargs):
        proc = subprocess.Popen(args, stdin=subprocess.DEVNULL, **kwargs)
        def stop():
            if proc.poll() is None:
                proc.terminate()
            proc.wait(timeout=10)
        self.addCleanup(stop)
        return proc

    def watch(self):
        log = self.repo / "watch-output"
        stream = log.open("w")
        self.addCleanup(stream.close)
        proc = self.spawn(["bash", str(SCRIPT), "watch"], env=self.env,
                          stdout=stream, stderr=subprocess.STDOUT)
        return proc, log

    def wait_for(self, predicate, seconds=8):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            if predicate():
                return
            time.sleep(0.05)
        self.fail("condition did not become true within %ss" % seconds)

    def test_verify_gives_executable_move_and_continuation(self):
        out = self.run_ech("next")
        self.assertIn("RUN NOW: lcars-ech live-check m1 --type <types>", out)
        self.assertIn("THEN: record both verdicts", out)
        self.assertIn("lcars-ech policy --mission m1", out)
        self.assertIn("lcars-ech land m1", out)
        self.assertIn("lcars-ech next", out)
        self.assertIn("Verify is not completion", out)

    def test_watch_stays_on_free_slot_and_exits_for_human(self):
        proc, log = self.watch()
        self.wait_for(lambda: "WAKE: slot available" in log.read_text())
        self.assertIsNone(proc.poll(), log.read_text())
        self.run_ech("ask", "scope decision needed", "--mission", "-")
        self.assertEqual(proc.wait(timeout=8), 10)
        self.assertIn("HUMAN NEEDED", log.read_text())
        self.assertIn("scope decision needed", log.read_text())
        self.run_ech("watch", "--limit", "1", rc=1)

    def fill_slots(self):
        drivers = {}
        for name in ("busy1", "busy2"):
            proc = self.spawn(["sleep", "60"])
            drivers[name] = {"pid": proc.pid}
        self.run_ech("record", "drivers", json.dumps(drivers))

    def test_watch_wakes_on_failed_mission_even_with_full_slots(self):
        self.fill_slots()
        proc, log = self.watch()
        time.sleep(0.5)
        self.assertNotIn("WAKE:", log.read_text())
        self.write(self.state, {"stage": "failed", "failedStage": "implement",
                                "failedAt": "2026-10-24T09:00:00Z",
                                "failedReason": "worker failed"})
        self.wait_for(lambda: "WAKE: failed mission m1" in log.read_text())
        self.assertIn("implement", log.read_text())
        self.assertIsNone(proc.poll())

    def test_watch_suppresses_failed_wake_while_drive_lock_is_live(self):
        self.fill_slots()
        owner = self.spawn(["sleep", "60"])
        lock = self.state.parent / "driver.lock"
        lock.mkdir()
        (lock / "pid").write_text(str(owner.pid))
        self.write(self.state, {"stage": "failed", "failedStage": "implement"})
        proc, log = self.watch()
        self.wait_for(lambda: "timerless guard active" in log.read_text())
        time.sleep(1)
        self.assertNotIn("WAKE: failed mission", log.read_text())
        owner.terminate()
        owner.wait(timeout=5)
        self.wait_for(lambda: "WAKE: failed mission m1" in log.read_text())
        self.assertIsNone(proc.poll())

    def test_watch_wakes_on_stale_failure_fields_outside_failed_stage(self):
        self.fill_slots()
        self.write(self.state, {"stage": "implement", "failedStage": "research",
                                "failedReason": "previous attempt failed"})
        proc, log = self.watch()
        self.wait_for(lambda: "WAKE: failed mission m1" in log.read_text())
        self.assertIn("previous attempt failed", log.read_text())
        self.assertIsNone(proc.poll())

    def test_managed_watch_outlives_injected_old_bound_on_monotonic_clock(self):
        self.fill_slots()
        start = time.monotonic()
        self.run_ech("watch", "start")
        self.addCleanup(lambda: self.run_ech("watch", "stop"))
        pid = json.loads(self.ap.read_text())["watch"]["pid"]
        self.run_ech("await", "--limit", "1", rc=124)
        time.sleep(max(0, 2 * int(self.env["LCARS_ECH_WAIT_LIMIT"]) + 0.1
                       - (time.monotonic() - start)))
        elapsed = time.monotonic() - start
        self.assertGreater(elapsed, 2 * int(self.env["LCARS_ECH_WAIT_LIMIT"]))
        os.kill(pid, 0)
        out = self.run_ech("watch", "status")
        self.assertIn("running", out)
        self.assertIn(str(pid), out)
        self.run_ech("watch", "start")
        self.assertEqual(json.loads(self.ap.read_text())["watch"]["pid"], pid)
        self.run_ech("watch", "stop")
        self.assertIn("not running", self.run_ech("watch", "status"))

    @staticmethod
    def pid_running(pid):
        result = subprocess.run(["ps", "-p", str(pid), "-o", "stat="],
                                capture_output=True, text=True, check=False)
        return result.returncode == 0 and not result.stdout.lstrip().startswith("Z")

    def stop_recorded_watch(self):
        pid = json.loads(self.ap.read_text()).get("watch", {}).get("pid")
        if pid and self.pid_running(pid):
            os.kill(pid, 15)
            self.wait_for(lambda: not self.pid_running(pid))

    def test_watch_identity_survives_equivalent_paths(self):
        alias = self.repo / "source"
        alias.symlink_to(SCRIPT.parent, target_is_directory=True)
        self.addCleanup(self.stop_recorded_watch)
        self.run_ech("watch", "start", script=alias / SCRIPT.name)
        pid = json.loads(self.ap.read_text())["watch"]["pid"]
        relative = os.path.relpath(SCRIPT.resolve(), self.repo.resolve())
        status = self.run_ech("watch", "status", script=relative)
        self.assertNotIn("not running", status)
        self.assertIn("running (pid %s)" % pid, status)
        self.assertIn("already running", self.run_ech("watch", "start", script=relative))
        self.assertEqual(json.loads(self.ap.read_text())["watch"]["pid"], pid)
        self.run_ech("watch", "stop", script=relative)
        self.assertFalse(self.pid_running(pid), "stop returned before termination")
        self.assertIn("not running", self.run_ech("watch", "status", script=relative))

    def test_watch_status_does_not_invent_a_running_guard(self):
        self.assertIn("not running", self.run_ech("watch", "status"))
        proc = self.spawn(["true"])
        proc.wait(timeout=5)
        self.run_ech("record", "watch.pid", str(proc.pid))
        self.assertIn("not running", self.run_ech("watch", "status"))

    def test_watch_stop_refuses_unconfirmed_termination(self):
        self.addCleanup(self.stop_recorded_watch)
        self.run_ech("watch", "start")
        pid = json.loads(self.ap.read_text())["watch"]["pid"]
        self.wait_for(lambda: "timerless guard active" in
                      (self.data / "autopilot/watch.log").read_text())
        os.kill(pid, signal.SIGSTOP)
        self.addCleanup(lambda: self.pid_running(pid) and os.kill(pid, signal.SIGCONT))
        out = self.run_ech("watch", "stop", rc=1)
        self.assertNotIn("stopped recorded guard", out)
        self.assertIn("could not confirm", out)
        self.assertEqual(json.loads(self.ap.read_text())["watch"]["pid"], pid)
        self.assertTrue(self.pid_running(pid))

    def test_no_verb_kills_by_broad_pattern(self):
        source = SCRIPT.read_text()
        assertion = r"(?m)^(?![ \t]*#)[^\n]*\b(?:pkill|killall)\b"
        self.assertNotRegex(source, assertion)
        self.assertRegex("  pkill -f guard", assertion)
        self.assertRegex('printf "# cleanup\\n"; pkill -f guard', assertion)
        kills = [line for line in source.splitlines()
                 if not line.lstrip().startswith("#") and re.search(r"\bkill ", line)]
        self.assertTrue(kills)
        for line in kills:
            self.assertRegex(line, r'kill (?:-[09] )?-?"\$(?:pid|p|w|sleeper)"')

    def test_refused_heartbeat_starts_timerless_fallback(self):
        cron = self.repo / "crontab"
        cron.write_text('#!/bin/bash\n[ "$1" = -l ] && exit 1\nexec sleep 60\n')
        cron.chmod(0o755)
        self.env.update(LCARS_CRONTAB_BIN=str(cron), LCARS_ECH_CRONTAB_TIMEOUT="1")
        self.addCleanup(lambda: self.run_ech("watch", "stop"))
        out = self.run_ech("heartbeat", "install", rc=11)
        self.assertIn("FALLBACK: timerless watcher", out)
        self.assertIn("DO NOT STOP THE RUN", out)
        self.assertIn("do not raise it with the captain", out)
        self.assertIn("running", self.run_ech("watch", "status"))
        pid = json.loads(self.ap.read_text())["watch"]["pid"]
        os.kill(pid, 0)
        self.run_ech("heartbeat", "install", rc=11)
        self.assertEqual(json.loads(self.ap.read_text())["watch"]["pid"], pid)

    def test_playbook_names_the_written_watch_log(self):
        self.addCleanup(self.stop_recorded_watch)
        out = self.run_ech("watch", "start")
        relative = ".git/lcars/autopilot/watch.log"
        self.assertIn(str(self.repo / relative), out)
        self.assertTrue((self.repo / relative).is_file())
        text = PLAYBOOK.read_text()
        self.assertIn("`" + relative + "`", text)
        self.assertNotIn(".git/lcars/watch.log", text)

    def test_immediate_heartbeat_refusal_starts_timerless_fallback(self):
        cron = self.repo / "crontab"
        cron.write_text('#!/bin/bash\necho "crontab: permission denied" >&2\nexit 1\n')
        cron.chmod(0o755)
        self.env.update(LCARS_CRONTAB_BIN=str(cron), LCARS_ECH_CRONTAB_TIMEOUT="1")
        self.addCleanup(self.stop_recorded_watch)
        out = self.run_ech("heartbeat", "install", rc=11)
        self.assertIn("crontab: permission denied", out)
        self.assertIn("FALLBACK: timerless watcher", out)
        self.assertIn("DO NOT STOP THE RUN", out)
        self.assertIn("do not raise it with the captain", out)
        status = self.run_ech("watch", "status")
        self.assertNotIn("not running", status)
        pid = json.loads(self.ap.read_text())["watch"]["pid"]
        self.assertTrue(self.pid_running(pid))
        self.run_ech("heartbeat", "install", rc=11)
        self.assertEqual(json.loads(self.ap.read_text())["watch"]["pid"], pid)

    def test_live_check_pairs_every_target_and_refuses_uncontrolled_green(self):
        subprocess.run(["git", "-C", str(self.repo), "-c", "user.name=Tester",
                        "-c", "user.email=test@example.com", "commit", "-qm", "seed",
                        "--allow-empty"], check=True)
        out = self.run_ech("live-check", "m1", "--type", "cli,web,workflow")
        self.assertIn("TARGET web:2", out)
        self.assertIn("KNOWN-FAIL CONTROL web:2", out)
        self.assertIn("login wall", out)
        evidence = self.data / "missions/m1/live-check"
        manifest = evidence / "checks.json"
        rows = json.loads(manifest.read_text())
        self.assertEqual(len(rows), 25)
        for row in rows:
            control_input = Path(row["control"]["input"])
            self.assertTrue(control_input.is_file())
            if row["id"].startswith("web:"):
                self.assertIn("<h1>Sign in</h1>", control_input.read_text())
            row["detector"] = "inspect the expected product output"
            for role, verdict in (("target", "pass"), ("control", "fail")):
                path = evidence / (row["id"].replace(":", "-") + "-" + role + ".txt")
                path.write_text(role + " observed\n")
                row[role].update(verdict=verdict, evidence=str(path.resolve()),
                                 observation=role + " content inspected")
        target_only = json.loads(json.dumps(rows))
        del target_only[0]["control"]
        self.write(manifest, target_only)
        self.run_ech("live-check", "done", "m1", "--verdict", "pass", rc=1)
        self.run_ech("live-check", "done", "m1", "--verdict", "bugs", rc=1)

        self.assertNotIn("verdict", json.loads(self.ap.read_text())["liveChecks"]["m1"])
        for wrong in ("pass", None):
            rows[0]["control"]["verdict"] = wrong
            self.write(manifest, rows)
            self.run_ech("live-check", "done", "m1", "--verdict", "pass", rc=1)
        rows[0]["control"]["verdict"] = "fail"
        for role, field, wrong in (
                ("control", "evidence", rows[0]["target"]["evidence"]),
                ("control", "evidence", str(evidence / "missing.txt")),
                ("target", "observation", "")):
            original = rows[0][role][field]
            rows[0][role][field] = wrong
            self.write(manifest, rows)
            self.run_ech("live-check", "done", "m1", "--verdict", "pass", rc=1)
            rows[0][role][field] = original
        self.write(manifest, rows[:-1])
        self.run_ech("live-check", "done", "m1", "--verdict", "pass", rc=1)
        self.write(manifest, rows)
        done = self.run_ech("live-check", "done", "m1", "--verdict", "pass")
        for row in rows:
            self.assertIn(row["id"] + ": target=pass control=fail", done)
        record = json.loads(self.ap.read_text())["liveChecks"]["m1"]
        self.assertEqual(record["checks"], rows)
        self.run_ech("live-check", "m1", "--type", "web")
        self.assertNotIn("verdict", json.loads(self.ap.read_text())["liveChecks"]["m1"])
        self.run_ech("live-check", "done", "m1", "--verdict", "pass", rc=1)

    def test_numbered_control_enumeration_and_board_rules_have_teeth(self):
        text = PLAYBOOK.read_text()
        for rule in ("A green check carries a control", "Enumerate, don't sample",
                     "Read the board"):
            self.assertRegex(text, r"(?m)^\d+\. \*\*" + re.escape(rule))
        self.assertIn("every ticket", text)
        self.assertIn("checks.json", text)
        self.assertIn("REFUSED", text)
        self.assertIn("never invent a completion metric", text)
        self.assertIn("known to fail", text)
        self.assertIn("same detector", text)


if __name__ == "__main__":
    unittest.main()

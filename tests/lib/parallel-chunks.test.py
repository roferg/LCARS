"""S372: public seat handoffs, real concurrent drivers and Git collisions."""
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import time
import unittest


ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("handoff", ROOT / "tests/lib/chunk-handoff.test.py")
handoff = importlib.util.module_from_spec(spec)
spec.loader.exec_module(handoff)


class ParallelChunks(unittest.TestCase):
    setUpClass = classmethod(handoff.ChunkHandoff.setUpClass.__func__)
    tearDownClass = classmethod(handoff.ChunkHandoff.tearDownClass.__func__)
    setUp = handoff.ChunkHandoff.setUp
    tearDown = handoff.ChunkHandoff.tearDown
    git = handoff.ChunkHandoff.git
    write = staticmethod(handoff.ChunkHandoff.write)
    ap = handoff.ChunkHandoff.ap
    ech = handoff.ChunkHandoff.ech
    start_ech = handoff.ChunkHandoff.start_ech
    finish_process = staticmethod(handoff.ChunkHandoff.finish_process)
    succeeds = handoff.ChunkHandoff.succeeds
    mint = handoff.ChunkHandoff.mint
    file = handoff.ChunkHandoff.file

    def test_parallel_brief_names_shared_cap_and_bounded_wait(self):
        first = self.mint("fish")
        first_brief = self.data / "delegates" / first / "BRIEF.md"
        original = first_brief.read_bytes()
        for unit, tier in (("water", "T1"), ("banks", "T2")):
            seat = self.mint(unit, tier)
            brief = (self.data / "delegates" / seat / "BRIEF.md").read_text()
            with self.subTest(tier=tier):
                self.assertIn("two concurrent Missions across ALL seats", brief)
                self.assertIn("exec --await --limit 600", brief)
                self.assertIn("124", brief)
                self.assertIn("BLOCKED:", brief)
                self.assertIn("does not reserve", brief)
                self.assertIn("not a Mission-completion wait", " ".join(brief.split()))
                self.assertIn("INTEGRATION HANDOFF", brief)
                self.assertIn("MAIN ECH owns cross-chunk integration", brief)
                self.assertIn("no re-integrate verb", brief)
        self.assertEqual(first_brief.read_bytes(), original)

    def test_capped_seat_gets_a_runnable_bounded_exit_not_a_poll(self):
        self.write(self.data / "missions/m-third/state.json", {
            "id": "m-third", "stage": "research", "branch": "lcars/m-third",
        })
        self.succeeds(self.ech("record", "missions.fish.id", "m-third"))
        seat = self.mint("fish")
        holders = [subprocess.Popen(["sleep", "180"]) for _ in range(2)]
        for process in holders:
            self.addCleanup(self.finish_process, process)
        self.succeeds(self.ech("record", "drivers", json.dumps({
            "a": {"pid": holders[0].pid}, "b": {"pid": holders[1].pid},
        })))
        before = self.ap()
        refused = self.ech("drive", "m-third", seat=seat)
        self.assertEqual(refused.returncode, 11, refused.stdout)
        self.assertIn("2/2", refused.stdout)
        self.assertIn("exec --await --limit 600", refused.stdout)
        self.assertIn("not queued", refused.stdout)
        self.assertEqual(self.ap(), before)
        start = time.monotonic()
        expired = self.ech("exec", "--await", "--limit", "1", seat=seat)
        elapsed = time.monotonic() - start
        self.assertEqual(expired.returncode, 124, expired.stdout)
        self.assertGreaterEqual(elapsed, 1)
        self.assertLess(elapsed, 20)
        self.assertIn("beat " + seat, expired.stdout)
        self.assertIn("Do not restart", expired.stdout)
        self.assertEqual(self.ap(), before)
        holders[1].terminate()
        holders[1].wait(timeout=5)
        free = self.ech("exec", "--await", "--limit", "0", seat=seat)
        self.assertEqual(free.returncode, 0, free.stdout)
        self.assertIn("does not reserve", free.stdout)
        self.assertEqual(self.ap(), before)

    def wait_for(self, predicate, description, limit=180):
        deadline = time.monotonic() + limit
        while time.monotonic() < deadline:
            if predicate():
                return
            time.sleep(0.1)
        self.fail("timed out waiting for " + description)

    def stop_drivers(self):
        rows = subprocess.run(
            ["ps", "-axo", "pid=,ppid=,command="],
            env=dict(os.environ, LC_ALL="C"), capture_output=True, text=True,
            errors="replace", check=True).stdout.splitlines()
        owned = {int(v["pid"]) for v in self.ap().get("drivers", {}).values()
                 if v.get("pid")}
        descendants = set(owned)
        while True:
            added = {int(row.split(None, 2)[0]) for row in rows
                     if len(row.split(None, 2)) == 3
                     and int(row.split(None, 2)[1]) in descendants}
            if added <= descendants:
                break
            descendants |= added
        for pid in sorted(descendants, reverse=True):
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass

    def test_concurrent_chunks_collide_and_recovery_names_integration_owner(self):
        (self.repo / "shared.txt").write_text("river\n")
        (self.repo / "CONTEXT.md").write_text("Two independent river changes.\n")
        self.git("add", "shared.txt", "CONTEXT.md")
        self.git("commit", "-qm", "shared river base")
        seed = self.git("rev-parse", "HEAD").stdout.strip()
        self.git("checkout", "-q", "--detach", seed)
        worker = self.bin / "fake-worker"
        worker.write_text("""#!/usr/bin/env python3
import json, os
from pathlib import Path
import re, subprocess, sys, time
repo = Path(os.environ["LCARS_ECH_CWD"])
prompt = "\\n".join(sys.argv[1:])
match = re.search(r"/missions/(m-(?:left|right))/", prompt)
if not match or os.environ.get("LCARS_WORKER_ROLE") != "validate":
    sys.exit("unexpected worker dispatch: " + os.environ.get("LCARS_WORKER_ROLE", ""))
mid = match[1]
data = repo / ".git/lcars"
with (data / "worker-visits").open("a") as log:
    log.write(mid + "\\n")
(data / (mid + ".ready")).touch()
deadline = time.monotonic() + 150
while not (data / "release-workers").exists():
    if time.monotonic() > deadline:
        sys.exit("concurrent drive barrier expired")
    time.sleep(0.05)
def git(*args):
    return subprocess.run(["git", "-C", str(repo), *args], check=True,
                          capture_output=True, text=True).stdout.strip()
wt = data / mid
git("worktree", "add", "-q", str(wt), "lcars/" + mid)
try:
    (wt / "shared.txt").write_text(mid + "\\n")
    subprocess.run(["git", "-C", str(wt), "add", "shared.txt"], check=True)
    subprocess.run(["git", "-C", str(wt), "commit", "-qm", mid + " river change"],
                   check=True)
finally:
    git("worktree", "remove", str(wt))
(data / (mid + ".edited")).touch()
out = Path(os.environ["LCARS_WORK_OUT"])
(out / "scope.txt").write_text("Fixture stops after its concurrent branch edit.\\n")
""")
        worker.chmod(0o755)
        self.env.update(LCARS_WORKER_BIN=str(worker), LCARS_WORKER_CLI="claude",
                        LCARS_WORKER_TRIES="1", LCARS_NOTIFY="true",
                        LCARS_NOTIFY_NO_DESKTOP="1", LCARS_VERSION_CHECK_BIN="/dev/null")
        seats = {}
        for unit, mid in (("fish", "m-left"), ("water", "m-right")):
            self.git("branch", "lcars/" + mid, seed)
            self.write(self.data / "missions" / mid / "state.json", {
                "id": mid, "stage": "validate", "type": "feature", "title": mid,
                "branch": "lcars/" + mid, "base": "main", "githubIssue": 1,
                "workerBin": str(worker), "engine": "claude",
            })
            (self.data / "missions" / mid / "prd.md").write_text(self.prd.read_text())
            self.succeeds(self.ech("record", "missions." + unit + ".id", mid))
            seats[mid] = self.mint(unit)
        third = "m-third"
        self.write(self.data / "missions" / third / "state.json", {
            "id": third, "stage": "validate", "branch": "lcars/" + third,
        })
        self.succeeds(self.ech("record", "missions.banks.id", third))
        third_seat = self.mint("banks")
        self.addCleanup(self.stop_drivers)
        # Both *real* run.sh drivers reach fake AI CLIs and stay live together.
        launches = [self.start_ech("drive", mid, seat=seat) for mid, seat in seats.items()]
        for process in launches:
            output, _ = process.communicate(timeout=90)
            self.assertEqual(process.returncode, 0, output)
        self.wait_for(lambda: all((self.data / (m + ".ready")).exists() for m in seats),
                      "both concurrent AI workers")
        owners = [int(self.ap()["drivers"][mid]["pid"]) for mid in seats]
        self.assertEqual(len(set(owners)), 2)
        for pid in owners:
            os.kill(pid, 0)
        print("  COLLISION: two real driver owners live together: " + str(owners), flush=True)
        refused = self.ech("drive", third, seat=third_seat)
        self.assertEqual(refused.returncode, 11, refused.stdout)
        self.assertIn("exec --await --limit 600", refused.stdout)
        expired = self.ech("exec", "--await", "--limit", "1", seat=third_seat)
        self.assertEqual(expired.returncode, 124, expired.stdout)
        self.assertNotIn(third, self.ap()["drivers"])
        print("  THIRD SEAT: " + refused.stdout.strip(), flush=True)
        print("  THIRD WAIT: " + expired.stdout.strip(), flush=True)
        (self.data / "release-workers").touch()
        self.wait_for(lambda: all(self.ap()["drivers"][m].get("exitedAt") for m in seats),
                      "both real drivers to finish")
        for mid in seats:
            self.assertTrue((self.data / (mid + ".edited")).exists())
            self.assertEqual(self.git("show", "lcars/" + mid + ":shared.txt").stdout,
                             mid + "\n")
            state = json.loads((self.data / "missions" / mid / "state.json").read_text())
            self.assertTrue(state["awaitingHuman"])
        # Integrate the first chunk, then the second drive must merge its peer.
        left = self.git("rev-parse", "lcars/m-left").stdout.strip()
        right = self.git("rev-parse", "lcars/m-right").stdout.strip()
        self.git("update-ref", "refs/heads/main", left, seed)
        state_path = self.data / "missions/m-right/state.json"
        before_recovery = json.loads(state_path.read_text())
        before_recovery["awaitingHuman"] = False
        before_recovery.pop("pendingQuestion", None)
        self.write(state_path, before_recovery)
        self.succeeds(self.ech("drive", "m-right", seat=seats["m-right"]))
        self.wait_for(lambda: bool(self.ap()["drivers"]["m-right"].get("exitedAt")),
                      "real recovery merge to park")
        directory = self.data / "missions/m-right"
        self.assertTrue((directory / "recovery-diagnosis.txt").is_file())
        self.assertTrue((directory / "recovery-question.txt").is_file())
        diagnosis = (directory / "recovery-diagnosis.txt").read_text()
        question = (directory / "recovery-question.txt").read_text()
        state = json.loads((directory / "state.json").read_text())
        self.assertIn("CONFLICT", diagnosis)
        self.assertIn("shared.txt", diagnosis)
        self.assertTrue(state["awaitingHuman"])
        self.assertIn("CONFLICT", state["pendingQuestion"])
        self.assertEqual(self.git("rev-parse", "lcars/m-right").stdout.strip(), right)
        self.assertEqual(self.git("rev-parse", "main").stdout.strip(), left)
        self.assertEqual((self.repo / "shared.txt").read_text(), "river\n")
        self.assertFalse(list(directory.glob("reanchor.*")))
        self.assertFalse((directory / "driver.lock").exists())
        self.assertNotIn("reconcile", self.git("worktree", "list").stdout)
        self.assertCountEqual((self.data / "worker-visits").read_text().splitlines(),
                              ["m-left", "m-right"])
        print("  RECOVERY REFUSAL: " + question, flush=True)
        self.assertIn("INTEGRATION HANDOFF", question)
        self.assertIn("MAIN ECH owns cross-chunk integration", question)
        self.assertIn("no re-integrate verb", question)
        self.assertIn("BLOCKED:", question)
        self.assertIn("answer this gate", question)


if __name__ == "__main__":
    unittest.main(verbosity=2)

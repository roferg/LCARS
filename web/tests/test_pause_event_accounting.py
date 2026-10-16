"""Real pause writers must give the unchanged board clock every transition."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import unittest
import urllib.request
from unittest import mock

from lcars_serve.actions import Actions
from lcars_serve.board import active_seconds
from lcars_serve.local_adapter import LocalAdapter
from lcars_serve.server import make_server

ROOT = Path(__file__).resolve().parents[2]
PAUSE = ROOT / "skills/lcars-pause/pause.sh"
XO = ROOT / "skills/lcars-xo/xo.sh"
ECH = ROOT / "skills/lcars-eeh/ech.sh"


class MissionFixture(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="pause-events-", dir=".")
        self.addCleanup(self.tmp.cleanup)
        self.repo = Path(self.tmp.name)
        self.parent = "m-parent-" + self.repo.name
        self.child = "m-child-" + self.repo.name
        subprocess.run(["git", "init", "-q", str(self.repo)], check=True)
        self.lcars = self.repo / ".git/lcars"
        self.missions = self.lcars / "missions"
        self.missions.mkdir(parents=True)
        self.write_json(self.lcars / "config.json", {
            "testCommand": "true",
            "numberOne": {"enabled": True, "engine": "claude"},
        })
        self.stub = self.repo / "noop.sh"
        self.stub.write_text("#!/usr/bin/env bash\nexit 0\n")
        self.stub.chmod(0o755)
        self.env = dict(os.environ, LCARS_GH_BIN="true",
                        LCARS_OWNER_ENFORCE="0", LCARS_XO_ENFORCE="0",
                        LCARS_PAUSE_RESUME="0", LCARS_XO_CENSUS_GAP="0",
                        LCARS_XO_SWEEP_ON_START="0",
                        LCARS_CLAUDE_BIN=str(self.stub.resolve()))
        self.plant(self.parent)
        self.plant(self.child, type="bug", parentMission=self.parent)
        (self.missions / self.parent / "xo").mkdir()
        self.write_json(self.missions / self.parent / "xo/logs.json",
                        [{"mission": self.child}])

    def write_json(self, path, value):
        path.write_text(json.dumps(value, indent=2) + "\n")

    def plant(self, mid, **fields):
        directory = self.missions / mid
        directory.mkdir()
        state = dict(id=mid, stage="implement", type="feature", title="Clock fixture",
                     numberOne={"status": "engaged"})
        state.update(fields)
        self.write_json(directory / "state.json", state)
        self.append(mid, "stage_start", 100)

    def append(self, mid, kind, ts):
        with (self.missions / mid / "events.jsonl").open("a") as fh:
            fh.write(json.dumps({"ts": ts, "mission": mid,
                                 "stage": "implement", "type": kind}) + "\n")

    def events(self, mid):
        return [json.loads(line) for line in
                (self.missions / mid / "events.jsonl").read_text().splitlines()]

    def state(self, mid):
        return json.loads((self.missions / mid / "state.json").read_text())

    def run_skill(self, script, *args, ts=120):
        result = subprocess.run(["bash", str(script), *args], cwd=self.repo,
                                env=dict(self.env, LCARS_NOW=str(ts)),
                                text=True, capture_output=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result.stdout

    def assert_transition(self, mid, kind, ts):
        events = [ev for ev in self.events(mid) if ev["type"] == kind]
        self.assertEqual(len(events), 1, "%s: missing/duplicate %s event" % (mid, kind))
        self.assertEqual(events[0]["ts"], ts)
        self.assertEqual(events[0]["mission"], mid)
        self.assertEqual(events[0]["stage"], "implement")
        self.assertTrue(events[0]["detail"])
        ledger = (self.missions / mid / "operator-writes.tsv").read_text()
        self.assertIn("events.jsonl\t", ledger)

    def seed_resume(self):
        for mid in (self.parent, self.child):
            state = self.state(mid)
            state["paused"] = True
            self.write_json(self.missions / mid / "state.json", state)
            self.append(mid, "paused", 120)
        (self.missions / self.parent / "xo-stop").write_text(
            f"stop fixture\nmission {self.parent}\nself paused-by-us\n"
            f"child {self.child} paused-by-us\n")


class PauseWriterControls(MissionFixture):
    def test_b_cli_pause_resume_excludes_span(self):
        self.run_skill(PAUSE, "pause", self.parent)
        self.assertTrue(self.state(self.parent)["paused"])
        self.assert_transition(self.parent, "paused", 120)
        self.assertEqual(active_seconds(self.events(self.parent), now=8400), 20)
        self.run_skill(PAUSE, "pause", self.parent, ts=200)
        self.assert_transition(self.parent, "paused", 120)
        self.run_skill(PAUSE, "resume", self.parent, ts=7320)
        self.assertFalse(self.state(self.parent).get("paused", False))
        self.assert_transition(self.parent, "resumed", 7320)
        self.run_skill(PAUSE, "resume", self.parent, ts=7330)
        self.assert_transition(self.parent, "resumed", 7320)
        self.append(self.parent, "stage_done", 7340)
        self.assertEqual(active_seconds(self.events(self.parent), now=8400), 40)

    def test_c_never_paused_is_unchanged(self):
        self.append(self.parent, "stage_done", 7340)
        before = active_seconds(self.events(self.parent), now=8400)
        self.run_skill(XO, "off")
        self.assertFalse(self.state(self.parent).get("paused", False))
        self.assertEqual([e["type"] for e in self.events(self.parent)],
                         ["stage_start", "stage_done"])
        self.assertEqual(before, 7240)
        self.assertEqual(active_seconds(self.events(self.parent), now=8400), before)

    def test_d_human_gate_still_excludes_span(self):
        self.append(self.parent, "gate", 120)
        self.assertEqual(active_seconds(self.events(self.parent), now=8400), 20)
        self.run_skill(XO, "off")
        self.append(self.parent, "stage_start", 7320)
        self.append(self.parent, "stage_done", 7340)
        self.assertEqual(active_seconds(self.events(self.parent), now=8400), 40)


class PauseEndpointAccounting(MissionFixture):
    def test_viewscreen_pause_resume_excludes_span(self):
        actions = Actions(repo_root=str(self.repo.resolve()),
                          scripts={"pause": str(PAUSE), "run": str(self.stub.resolve())},
                          gh_bin="true")
        server = make_server(LocalAdapter(str(self.repo.resolve())),
                             host="127.0.0.1", port=0, actions=actions)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        children = []
        spawn = actions._spawn

        def tracked_spawn(*args, **kwargs):
            child = spawn(*args, **kwargs)
            children.append(child)
            return child

        try:
            with mock.patch.dict(os.environ, self.env), \
                    mock.patch.object(actions, "_spawn", side_effect=tracked_spawn):
                for action, ts, kind in (("pause", 120, "paused"),
                                         ("resume", 7320, "resumed")):
                    with mock.patch.dict(os.environ, {"LCARS_NOW": str(ts)}):
                        request = urllib.request.Request(
                            "http://127.0.0.1:%d/api/mission/%s/%s" %
                            (server.server_address[1], self.parent, action), data=b"{}",
                            headers={"Content-Type": "application/json"}, method="POST")
                        with urllib.request.urlopen(request, timeout=10) as response:
                            self.assertEqual(response.status, 200)
                            self.assertTrue(json.load(response)["ok"])
                    self.assertEqual(self.state(self.parent).get("paused", False),
                                     action == "pause")
                    self.assert_transition(self.parent, kind, ts)
                    if action == "pause":
                        self.assertEqual(active_seconds(self.events(self.parent), now=8400), 20)
            self.append(self.parent, "stage_done", 7340)
            self.assertEqual(active_seconds(self.events(self.parent), now=8400), 40)
        finally:
            for child in children:
                child.wait(timeout=10)
            server.shutdown()
            server.server_close()
            thread.join()


class PauseShellAccounting(MissionFixture):
    def test_a_xo_pause_parent_and_linked_child(self):
        self.run_skill(XO, "off", self.parent)
        for mid in (self.parent, self.child):
            with self.subTest(mission=mid):
                self.assertTrue(self.state(mid)["paused"])
                self.assert_transition(mid, "paused", 120)
                self.assertEqual(active_seconds(self.events(mid), now=8400), 20)

    def test_a_xo_resume_parent_and_linked_child(self):
        self.seed_resume()
        self.run_skill(XO, "on", self.parent, ts=7320)
        for mid in (self.parent, self.child):
            with self.subTest(mission=mid):
                self.assertFalse(self.state(mid).get("paused", False))
                self.assert_transition(mid, "resumed", 7320)
                self.append(mid, "stage_done", 7340)
                self.assertEqual(active_seconds(self.events(mid), now=8400), 40)

    def test_a_xo_repo_on_resumes_recorded_pauses(self):
        self.seed_resume()
        self.run_skill(XO, "on", "--engine", "claude", ts=7320)
        for mid in (self.parent, self.child):
            with self.subTest(mission=mid):
                self.assertFalse(self.state(mid).get("paused", False))
                self.assert_transition(mid, "resumed", 7320)
                self.append(mid, "stage_done", 7340)
                self.assertEqual(active_seconds(self.events(mid), now=8400), 40)

    def test_a_xo_round_trip_excludes_two_hour_pause(self):
        self.run_skill(XO, "off", self.parent)
        self.run_skill(XO, "on", self.parent, ts=7320)
        for mid in (self.parent, self.child):
            with self.subTest(mission=mid):
                self.append(mid, "stage_done", 7340)
                self.assertEqual(active_seconds(self.events(mid), now=8400), 40)

    def test_a_ech_land_hygiene_emits_pause(self):
        for mid in (self.parent, self.child):
            state = self.state(mid)
            state["stage"] = "done"
            self.write_json(self.missions / mid / "state.json", state)
        self.run_skill(ECH, "init", "--spec", "fixture")
        self.env["LCARS_APPROVE_SCRIPT"] = str(self.stub.resolve())
        self.env["LCARS_XO_SCRIPT"] = str(XO)
        output = self.run_skill(ECH, "land", self.parent)
        self.assertIn(f"releasing folded child {self.child} (xo off)", output)
        self.assertTrue(self.state(self.child)["paused"])
        events = [e for e in self.events(self.child) if e["type"] == "paused"]
        self.assertEqual(len(events), 1, "the ECH hygiene: missing paused event")
        self.assertEqual((events[0]["ts"], events[0]["stage"]), (120, "done"))
        self.assertEqual(active_seconds(self.events(self.child), now=8400), 20)
        self.run_skill(XO, "on", self.child, ts=7320)
        resumed = [e for e in self.events(self.child) if e["type"] == "resumed"]
        self.assertEqual(len(resumed), 1)
        self.assertEqual((resumed[0]["ts"], resumed[0]["stage"]), (7320, "done"))
        self.append(self.child, "stage_done", 7340)
        self.assertEqual(active_seconds(self.events(self.child), now=8400), 40)

    def test_already_paused_child_is_not_resumed_or_reemitted(self):
        state = self.state(self.child)
        state["paused"] = True
        self.write_json(self.missions / self.child / "state.json", state)
        self.append(self.child, "paused", 110)
        self.run_skill(XO, "off", self.parent)
        self.run_skill(XO, "on", self.parent, ts=7320)
        self.assertTrue(self.state(self.child)["paused"])
        self.assertEqual([e["type"] for e in self.events(self.child)],
                         ["stage_start", "paused"])
        self.assertEqual(active_seconds(self.events(self.child), now=8400), 10)

    def test_stale_resume_marker_does_not_emit_transition(self):
        (self.missions / self.parent / "xo-stop").write_text(
            f"self paused-by-us\nchild {self.child} paused-by-us\n")
        self.run_skill(XO, "on", self.parent, ts=7320)
        for mid in (self.parent, self.child):
            self.assertEqual([e["type"] for e in self.events(mid)], ["stage_start"])


if __name__ == "__main__":
    unittest.main()

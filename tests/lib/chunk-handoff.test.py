"""S370: real seats, filing, ownership gates and briefs; no model spend."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[2]
BASE = "b89dbeab58918a5160e0ab3953a5207edd042e40"


class ChunkHandoff(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tree = tempfile.TemporaryDirectory(prefix="s370-skills-")
        cls.skills = Path(cls.tree.name) / "skills"
        shutil.copytree(Path(os.environ.get("LCARS_TEST_SKILLS", ROOT / "skills")), cls.skills)

    @classmethod
    def tearDownClass(cls):
        cls.tree.cleanup()

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="s370-")
        self.addCleanup(self.tmp.cleanup)
        self.repo = Path(self.tmp.name)
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.name", "Tester")
        self.git("config", "user.email", "t@example.com")
        self.git("commit", "-qm", "seed", "--allow-empty")
        self.data = self.repo / ".git/lcars"
        self.write(self.data / "config.json", {
            "engine": "copilot", "cloneId": "c10ec10ec10ec10e",
            "numberOne": {"enabled": False}, "testCommand": "true",
        })
        self.write(self.data / "autopilot.json", {
            "spec": "spec.md", "engine": "copilot", "scope": ["fish", "water"],
            "missions": {}, "questions": {}, "pending": {},
        })
        (self.repo / "spec.md").write_text("Fish survive changes in river level.\n")
        self.prd = self.repo / "fish.md"
        self.prd.write_text("""# Mission: Fish follow the river level

**Type:** feature
**Seam:** none
**Goal:** Fish survive changes in river level.
**Acceptance Criteria:**
- Fish move with the river level.
**Out of Scope:**
- Other chunks.
**Constraints:**
- Number One stays off.
""")
        self.bin = self.repo / "bin"
        self.bin.mkdir()
        gh = self.bin / "gh"
        gh.write_text("#!/bin/bash\n"
                      "if [ \"$1 $2\" = 'issue create' ]; then\n"
                      "  echo https://github.com/example/test/issues/999\nfi\n")
        gh.chmod(0o755)
        for name in ("claude", "copilot"):
            p = self.bin / name
            p.write_text("#!/bin/bash\n"
                         "echo MODEL-SPEND-FUSE >> \"$LCARS_ECH_CWD/spend.log\"\nexit 97\n")
            p.chmod(0o755)
        self.env = dict(os.environ, LCARS_ECH_CWD=str(self.repo),
                        LCARS_GH_BIN=str(gh), LCARS_RUN_BIN=str(self.repo / "no-estimator"),
                        LCARS_VERSION_CHECK="0", LCARS_OWNER_ENFORCE="0",
                        LCARS_XO_ENFORCE="0", LCARS_DATE="20261123",
                        PATH=str(self.bin) + os.pathsep + os.environ["PATH"])
        self.env.pop("LCARS_ECH_AS", None)
        self.env.pop("LCARS_LOG_SCRIPT", None)

    def tearDown(self):
        self.assertFalse((self.repo / "spend.log").exists(), "model CLI invoked")

    def git(self, *args):
        return subprocess.run(["git", *args], cwd=self.repo, check=True,
                              capture_output=True, text=True)

    @staticmethod
    def write(path, value):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(value, indent=2))

    def ap(self):
        return json.loads((self.data / "autopilot.json").read_text())

    def ech(self, *args, seat=None):
        process = self.start_ech(*args, seat=seat)
        out, _ = process.communicate(timeout=300)
        return subprocess.CompletedProcess(process.args, process.returncode, out)

    def start_ech(self, *args, seat=None):
        env = dict(self.env)
        if seat:
            env["LCARS_ECH_AS"] = seat
        process = subprocess.Popen(
            ["bash", str(self.skills / "lcars-eeh/ech.sh"), *args],
            cwd=self.repo, env=env, stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        self.addCleanup(self.finish_process, process)
        return process

    @staticmethod
    def finish_process(process):
        if process.poll() is None:
            process.kill()
        process.communicate()

    def succeeds(self, result):
        self.assertEqual(result.returncode, 0, result.stdout)
        return result.stdout

    def mint(self, unit, tier="T1", *args):
        self.succeeds(self.ech("tier", unit, "--tier", tier, "--why", "one owned chunk"))
        before = set(self.ap().get("delegates", {}))
        self.succeeds(self.ech("delegate", unit, *args))
        after = self.ap()["delegates"]
        added = set(after) - before
        self.assertEqual(len(added), 1)
        return added.pop()

    def file(self, seat):
        before = set((self.data / "missions").glob("*/state.json"))
        self.succeeds(self.ech("exec", "lcars-file/file.sh", "--prd", str(self.prd),
                               seat=seat))
        added = set((self.data / "missions").glob("*/state.json")) - before
        self.assertEqual(len(added), 1)
        return added.pop().parent.name

    def test_seedless_owner_can_receive_one_sibling_validator(self):
        driver = self.mint("fish")
        self.assertEqual(self.ap()["delegates"][driver]["mission"], "")
        mid = self.file(driver)
        self.succeeds(self.ech("record", "missions.fish.id", mid))
        self.succeeds(self.ech("delegate", "fish", "--validate", "--trigger", "wide",
                               "--why", "the river machinery is shared"))
        validators = {k: v for k, v in self.ap()["delegates"].items() if v.get("validates")}
        self.assertEqual(len(validators), 1)
        vid, validator = next(iter(validators.items()))
        self.assertEqual(validator["validatorFor"], driver)
        self.assertEqual(validator["depth"], 1)
        self.succeeds(self.ech("record", "missions.water.id", mid))
        self.succeeds(self.ech("tier", "water", "--tier", "T1", "--why", "same work"))
        second = self.ech("delegate", "water", "--validate", "--trigger", "wide",
                          "--why", "another label for the same work")
        self.assertNotEqual(second.returncode, 0)
        self.assertIn("ALREADY THE VALIDATION PASS", second.stdout)
        self.assertEqual(set(self.ap()["delegates"]), {driver, vid})

    def wait_for(self, path, process):
        deadline = time.monotonic() + 180
        while not path.exists():
            if process.poll() is not None:
                self.fail(process.communicate()[0])
            if time.monotonic() >= deadline:
                self.fail("filing never reached forge barrier: " + str(path))
            time.sleep(0.05)

    def owner(self, mid):
        result = subprocess.run(
            ["bash", "-c", '. "$1"; lcars_chunk_owner "$2" "$3"', "owner",
             str(self.skills / "lcars-eeh/chunk-owners.sh"), str(self.data), mid],
            capture_output=True, text=True, check=True)
        return result.stdout

    def test_concurrent_real_filings_never_transfer_to_the_other_seat(self):
        first = self.mint("fish")
        second = self.mint("water")
        # Hold the first real filing after state creation, while the second files
        # and returns. Both before/after windows overlap on the broken build.
        gh = self.bin / "gh"
        gh.write_text("""#!/usr/bin/env python3
import os
from pathlib import Path
import sys
import time
if sys.argv[1:3] == ["issue", "create"]:
    repo = Path(os.environ["LCARS_ECH_CWD"])
    seat = os.environ.get("LCARS_ECH_AS", "main")
    (repo / ("at-forge-" + seat)).touch()
    if seat == "d1":
        deadline = time.monotonic() + 180
        while not (repo / "release-first").exists():
            if time.monotonic() >= deadline:
                sys.exit("forge barrier timed out")
            time.sleep(0.05)
    print("https://github.com/example/test/issues/999")
""")
        args = ("exec", "lcars-file/file.sh", "--prd", str(self.prd))
        start = time.monotonic()
        a = self.start_ech(*args, seat=first)
        self.wait_for(self.repo / ("at-forge-" + first), a)
        first_ids = set((self.data / "missions").glob("*/state.json"))
        self.assertEqual(len(first_ids), 1)
        b = self.start_ech(*args, seat=second)
        self.wait_for(self.repo / ("at-forge-" + second), b)
        self.assertIsNone(a.poll(), "first filing must still be in flight")
        bout, _ = b.communicate(timeout=180)
        self.succeeds(subprocess.CompletedProcess(b.args, b.returncode, bout))
        second_ids = set((self.data / "missions").glob("*/state.json")) - first_ids
        self.assertEqual(len(second_ids), 1, "two filings must create distinct Missions")
        (self.repo / "release-first").touch()
        aout, _ = a.communicate(timeout=180)
        self.succeeds(subprocess.CompletedProcess(a.args, a.returncode, aout))
        ma = first_ids.pop().parent.name
        mb = second_ids.pop().parent.name
        print("  real overlapping filings: %.1fs; %s=%s, %s=%s" %
              (time.monotonic() - start, first, ma, second, mb), flush=True)
        self.assertEqual(self.owner(ma), first)
        self.assertEqual(self.owner(mb), second)
        for seat, own, sibling in ((first, ma, mb), (second, mb, ma)):
            self.succeeds(self.ech("live-check", own, "--type", "cli", seat=seat))
            refused = self.ech("live-check", sibling, "--type", "cli", seat=seat)
            self.assertNotEqual(refused.returncode, 0)
            self.assertIn("NOT IN YOUR CHUNK", refused.stdout)
            # Pause through the product so the REAL factory driver can reach its
            # safe boundary without starting a worker. Only the AI/forge are fake.
            pause = subprocess.run(
                ["bash", str(self.skills / "lcars-pause/pause.sh"), "pause", own],
                cwd=self.repo, env=self.env, capture_output=True, text=True, timeout=180)
            self.succeeds(subprocess.CompletedProcess(pause.args, pause.returncode,
                                                      pause.stdout + pause.stderr))
            self.succeeds(self.ech("drive", own, seat=seat))
            deadline = time.monotonic() + 180
            while not self.ap().get("drivers", {}).get(own, {}).get("exitedAt"):
                if time.monotonic() >= deadline:
                    self.fail("real paused driver did not exit: " + own)
                time.sleep(0.1)
            self.assertEqual(self.ap()["drivers"][own]["exitCode"], 0)
            log = (self.data / "autopilot" / ("drive-" + own + ".log")).read_text()
            self.assertIn("paused", log.lower())
            refused = self.ech("drive", sibling, seat=seat)
            self.assertNotEqual(refused.returncode, 0)
            self.assertIn("NOT IN YOUR CHUNK", refused.stdout)

    def test_chunk_goal_travels_in_both_tier_briefs_and_the_sibling_brief(self):
        source = self.repo / "chunk-goal.md"
        original = ("Fish remain in the river at every supported water level.\n"
                    "## 5. This is goal text, not another brief section\n"
                    "- Low water keeps the surviving fish visible.\n")
        source.write_text(original)
        first = None
        for unit, tier in (("fish", "T1"), ("water", "T2")):
            seat = self.mint(unit, tier, "--goal", str(source))
            first = first or seat
            record = self.ap()["delegates"][seat]
            brief = (self.data / "delegates" / seat / "BRIEF.md").read_text()
            self.assertEqual(record["goalSource"], "chunk-goal")
            self.assertIn("goal", record["briefParts"])
            self.assertEqual(record["goalRel"], ".git/lcars/delegates/" + seat + "/GOAL.md")
            self.assertEqual((self.repo / record["goalRel"]).read_text(), original)
            self.assertIn("Fish remain in the river at every supported water level.", brief)
            self.assertIn("\\## 5. This is goal text", brief)
            self.assertNotIn("THIS BRIEF CARRIES NO GOAL", brief)
        source.write_text("A later edit must not change the handed-off goal.\n")
        mid = self.file(first)
        self.succeeds(self.ech("record", "missions.fish.id", mid))
        before = set(self.ap()["delegates"])
        self.succeeds(self.ech("delegate", "fish", "--validate", "--trigger", "wide",
                               "--why", "shared river machinery"))
        validator = (set(self.ap()["delegates"]) - before).pop()
        record = self.ap()["delegates"][validator]
        brief = (self.data / "delegates" / validator / "BRIEF.md").read_text()
        self.assertEqual(record["goalSource"], "chunk-goal")
        self.assertEqual((self.repo / record["goalRel"]).read_text(), original)
        self.assertIn("Fish remain in the river at every supported water level.", brief)
        self.assertNotIn("A later edit", brief)
        self.assertIn("YOUR JOB IS NOT TO MAKE THAT TRUE", brief)

    def test_invalid_chunk_goal_is_refused_before_any_mint_write(self):
        self.succeeds(self.ech("tier", "fish", "--tier", "T1", "--why", "one chunk"))
        before = (self.data / "autopilot.json").read_bytes()
        blank = self.repo / "blank.md"
        blank.write_text(" \n\t\n")
        for source in (self.repo / "missing.md", blank, self.repo):
            with self.subTest(source=source.name):
                result = self.ech("delegate", "fish", "--goal", str(source))
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("goal", result.stdout.lower())
                self.assertEqual((self.data / "autopilot.json").read_bytes(), before)
                self.assertFalse(any((self.data / "delegates").glob("*/BRIEF.md")))

    def test_real_park_receipt_assigns_only_the_new_mission(self):
        seat = self.mint("fish")
        self.succeeds(self.ech("exec", "lcars-file/file.sh", "--park",
                               "Fish remain in the river", seat=seat))
        states = list((self.data / "missions").glob("*/state.json"))
        self.assertEqual(len(states), 1)
        self.assertTrue(json.loads(states[0].read_text())["prdPending"])
        self.assertEqual(self.owner(states[0].parent.name), seat)
        self.assertEqual(list((self.data / "autopilot").glob("filing.*")), [])

    def test_real_log_batch_receipts_keep_every_bug_with_its_driver(self):
        self.write(self.data / "missions/m-parent/state.json", {
            "id": "m-parent", "title": "River", "stage": "verify",
            "githubIssue": 1, "type": "feature", "branch": "main", "base": "main",
        })
        self.succeeds(self.ech("record", "missions.fish.id", "m-parent"))
        seat = self.mint("fish")
        bug = self.repo / "bug.md"
        bug.write_text(self.prd.read_text().replace("**Type:** feature", "**Type:** bug"))
        self.succeeds(self.ech("exec", "lcars-log/log.sh", "--parent", "m-parent",
                               "--prd", str(bug), "--prd", str(bug), seat=seat))
        bugs = [p for p in (self.data / "missions").glob("*/state.json")
                if p.parent.name != "m-parent"]
        self.assertEqual(len(bugs), 2)
        for state in bugs:
            self.assertEqual(json.loads(state.read_text())["parentMission"], "m-parent")
            self.assertEqual(self.owner(state.parent.name), seat)
        self.assertEqual(list((self.data / "autopilot").glob("filing.*")), [])

    def test_single_chunk_main_and_driver_match_pre_session_bytes(self):
        baseline = self.repo / "baseline-skills"
        shutil.copytree(self.skills, baseline)
        old = subprocess.run(
            ["git", "show", BASE + ":skills/lcars-eeh/ech.sh"],
            cwd=ROOT, check=True, capture_output=True, text=True).stdout
        (baseline / "lcars-eeh/ech.sh").write_text(old)
        date = self.bin / "date"
        date.write_text('#!/bin/bash\nif [ "$*" = "+%s" ]; then echo 1800000000; '
                        'else exec /bin/date "$@"; fi\n')
        date.chmod(0o755)
        self.write(self.data / "missions/m-solo/state.json", {
            "id": "m-solo", "title": "River", "stage": "verify",
            "type": "feature", "branch": "main", "githubIssue": 1,
        })
        shutil.copyfile(self.prd, self.data / "missions/m-solo/prd.md")
        self.succeeds(self.ech("record", "missions.fish.id", "m-solo"))
        self.succeeds(self.ech("tier", "fish", "--tier", "T1", "--why", "one chunk"))
        saved = (self.data / "autopilot.json").read_bytes()
        current = self.skills

        def capture(skills):
            self.skills = skills
            result = {"mint": self.succeeds(self.ech("delegate", "fish"))}
            result["brief"] = (self.data / "delegates/d1/BRIEF.md").read_text()
            result["record"] = (self.data / "autopilot.json").read_text()
            for verb in ("delegates", "status", "stalled", "next"):
                result[verb] = self.succeeds(self.ech(verb))
            return {key: value.replace(str(skills), "<SKILLS>") for key, value in result.items()}

        try:
            before = capture(baseline)
            shutil.rmtree(self.data / "delegates/d1")
            (self.data / "autopilot.json").write_bytes(saved)
            after = capture(current)
        finally:
            self.skills = current
        self.assertIn("MINTED: d1", before["mint"])
        self.assertIn("Fish survive changes in river level.", before["brief"])
        for surface in before:
            with self.subTest(surface=surface):
                self.assertEqual(after[surface], before[surface])


if __name__ == "__main__":
    unittest.main(verbosity=2)

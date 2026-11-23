"""S369: real ECH filing doors, real log, fake forge and no model spend."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class MissionSelector(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tree = tempfile.TemporaryDirectory(prefix="s369-skills-")
        cls.skills = Path(cls.tree.name) / "skills"
        shutil.copytree(Path(os.environ.get("LCARS_TEST_SKILLS", ROOT / "skills")), cls.skills)
        override = os.environ.get("LCARS_ECH_SCRIPT")
        if override:
            shutil.copyfile(override, cls.skills / "lcars-eeh/ech.sh")

    @classmethod
    def tearDownClass(cls):
        cls.tree.cleanup()

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="s369-")
        self.addCleanup(self.tmp.cleanup)
        self.repo = Path(self.tmp.name)
        subprocess.run(["git", "init", "-q", "-b", "main", str(self.repo)], check=True)
        for key, value in (("user.name", "Tester"), ("user.email", "t@example.com")):
            subprocess.run(["git", "-C", str(self.repo), "config", key, value], check=True)
        subprocess.run(["git", "-C", str(self.repo), "commit", "-qm", "seed",
                        "--allow-empty"], check=True)
        self.data = self.repo / ".git/lcars"
        self.write(self.data / "config.json", {
            "engine": "copilot", "cloneId": "c10ec10ec10ec10e",
            "numberOne": {"enabled": False}, "testCommand": "true",
        })
        self.mission("m-mine", title="the engine", issue=10)
        self.mission("m-theirs", title="the river", issue=20)
        self.mission("bug-001", title="Finding in the engine", issue=111,
                     parent="m-mine")
        self.ap = {
            "spec": "spec.md", "engine": "copilot", "scope": ["mine", "theirs"],
            "missions": {"mine": {"id": "m-mine"}, "theirs": {"id": "m-theirs"}},
            "questions": {}, "pending": {},
            "units": {"mine": {"tier": "T1"}, "theirs": {"tier": "T1"}},
            "validations": {"m-mine": {"round": 1}},
            "delegates": {
                "d1": {"id": "d1", "unit": "mine", "tier": "T1", "status": "minted",
                       "mission": "m-mine", "mintedBy": "main", "depth": 1},
                "v1": {"id": "v1", "unit": "mine", "tier": "T1", "status": "minted",
                       "mission": "m-mine", "mintedBy": "main", "depth": 1,
                       "validates": "mine", "validatorFor": "d1", "validationRound": 2,
                       "recheckScope": ["bug-001"], "filed": ["bug-001"]},
            },
        }
        self.save_ap()
        for seat in ("d1", "v1"):
            directory = self.data / "delegates" / seat
            directory.mkdir(parents=True)
            (directory / "BRIEF.md").write_text("# Fixture seat\n")
            (directory / "OPEN").touch()
        self.prd = self.repo / "bug.md"
        self.prd.write_text("""# Mission: The selector gate disagrees with filing

**Type:** bug
**Seam:** none
**Goal:** Filing uses the Mission the gate bounded.
**Acceptance Criteria:**
- Observed live: the selector was refused at the exec door.
- A known in-scope finding can receive a linked child.
**Out of Scope:**
- Other chunks.
**Constraints:**
- Number One stays off.
""")
        self.bin = self.repo / "bin"
        self.bin.mkdir()
        gh = self.bin / "gh"
        gh.write_text("#!/bin/bash\n"
                      "printf '%s\\n' \"$*\" >> \"$LCARS_ECH_CWD/forge.log\"\n"
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
                        LCARS_VERSION_CHECK= "0", LCARS_OWNER_ENFORCE="0",
                        LCARS_XO_ENFORCE="0", LCARS_DATE="20261122",
                        PATH=str(self.bin) + os.pathsep + os.environ["PATH"])
        self.env.pop("LCARS_ECH_AS", None)
        self.env.pop("LCARS_LOG_SCRIPT", None)

    def tearDown(self):
        self.assertFalse((self.repo / "spend.log").exists(), "model CLI invoked")

    @staticmethod
    def write(path, value):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(value, indent=2))

    def mission(self, mid, title, issue, parent=None):
        value = {"id": mid, "title": title, "githubIssue": issue, "stage": "verify",
                 "type": "bug" if parent else "feature", "branch": "main"}
        if parent:
            value["parentMission"] = parent
        self.write(self.data / "missions" / mid / "state.json", value)

    def save_ap(self):
        self.write(self.data / "autopilot.json", self.ap)

    def ech(self, *args, seat="v1"):
        env = dict(self.env)
        if seat:
            env["LCARS_ECH_AS"] = seat
        return subprocess.run(["bash", str(self.skills / "lcars-eeh/ech.sh"), *args],
                              cwd=self.repo, env=env, stdin=subprocess.DEVNULL,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                              text=True, timeout=180)

    def states(self):
        return [json.loads(p.read_text()) for p in (self.data / "missions").glob("*/state.json")]

    def test_log_and_resolve_logs_share_a_decoded_title_selector(self):
        self.mission("tabbed", title="thing\tselected", issue=40)
        for script in ("lcars-log/log.sh", "lcars-resolve-logs/resolve-logs.sh"):
            with self.subTest(script=script):
                args = ["--parent", "thing\tselected"]
                if script == "lcars-log/log.sh":
                    args += ["--prd", str(self.prd)]
                result = subprocess.run(
                    ["bash", str(self.skills / script), *args], cwd=self.repo, env=self.env,
                    stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT, text=True, timeout=180)
                self.assertEqual(result.returncode, 0, result.stdout)
                if script == "lcars-log/log.sh":
                    # The next door must not drive the child we just filed.
                    child = next(s for s in self.states() if s.get("parentMission") == "tabbed")
                    child["stage"] = "done"
                    self.write(self.data / "missions" / child["id"] / "state.json", child)

    def test_target_consumes_the_gate_resolution_without_a_second_lookup(self):
        selector = self.skills / "lcars-eeh/mission-selector.py"
        args = ["python3", str(selector), str(self.data / "missions"), "active", "Finding in"]
        first = subprocess.run(args, env=self.env, capture_output=True, text=True, check=True)
        self.mission("other", title="Finding in another place", issue=114)
        # A fresh lookup is now ambiguous; the bound handoff still names bug-001.
        unbound = subprocess.run(args, env=self.env, capture_output=True, text=True)
        self.assertNotEqual(unbound.returncode, 0, unbound.stdout)
        env = dict(self.env, LCARS_MISSION_RESOLUTION=first.stdout)
        result = subprocess.run(
            ["bash", str(self.skills / "lcars-log/log.sh"), "--parent", "Finding in",
             "--prd", str(self.prd)], cwd=self.repo, env=env, stdin=subprocess.DEVNULL,
            capture_output=True, text=True, timeout=180)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(len([s for s in self.states()
                              if s.get("parentMission") == "bug-001"]), 1)

    def test_a_handoff_for_another_selector_is_not_reused(self):
        selector = self.skills / "lcars-eeh/mission-selector.py"
        first = subprocess.run(
            ["python3", str(selector), str(self.data / "missions"), "active", "bug-001"],
            env=self.env, capture_output=True, text=True, check=True)
        env = dict(self.env, LCARS_MISSION_RESOLUTION=first.stdout)
        result = subprocess.run(
            ["bash", str(self.skills / "lcars-log/log.sh"), "--parent", "m-theirs",
             "--prd", str(self.prd)], cwd=self.repo, env=env, stdin=subprocess.DEVNULL,
            capture_output=True, text=True, timeout=180)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((self.repo / "forge.log").exists())

    def test_in_scope_title_selector_reaches_the_same_parent(self):
        result = self.ech("exec", "lcars-log/log.sh", "--parent", "Finding in",
                          "--prd", str(self.prd))
        self.assertEqual(result.returncode, 0, result.stdout)
        children = [s for s in self.states() if s.get("parentMission") == "bug-001"]
        self.assertEqual(len(children), 1, result.stdout)

    def test_file_bug_resolves_the_in_scope_issue_before_bounding(self):
        result = self.ech("file-bug", "--parent", "#111", "--prd", str(self.prd))
        self.assertEqual(result.returncode, 0, result.stdout)
        children = [s for s in self.states() if s.get("parentMission") == "bug-001"]
        self.assertEqual(len(children), 1, result.stdout)

    def test_scope_entry_newline_does_not_authorize_its_sibling_fragment(self):
        mid = "finding\nm-theirs"
        self.mission(mid, title="one unusual finding", issue=333, parent="m-mine")
        path = self.data / "missions" / mid / "state.json"
        state = json.loads(path.read_text())
        state["stage"] = "done"
        self.write(path, state)
        self.ap["delegates"]["v1"]["recheckScope"] = [mid]
        self.save_ap()
        result = self.ech("exec", "lcars-log/log.sh", "--parent", "m-theirs",
                          "--prd", str(self.prd))
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("OUTSIDE YOUR RE-CHECK", result.stdout)
        self.assertFalse((self.repo / "forge.log").exists(), result.stdout)

    def assert_loose_exec_lookup(self, seat):
        result = self.ech("exec", "lcars-log/log.sh", "--parent", "THE RIVER",
                          "--prd", str(self.prd), seat=seat)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(len([s for s in self.states()
                              if s.get("parentMission") == "m-theirs"]), 1)

    def test_driver_keeps_its_loose_exec_lookup(self):
        self.assert_loose_exec_lookup("d1")

    def test_main_keeps_its_loose_exec_lookup(self):
        self.assert_loose_exec_lookup(None)

    def test_first_pass_can_file_against_its_whole_chunk(self):
        self.ap["delegates"]["v1"].pop("recheckScope")
        self.ap["delegates"]["v1"]["validationRound"] = 1
        self.save_ap()
        for door in ("file-bug", "exec"):
            with self.subTest(door=door):
                args = ("exec", "lcars-log/log.sh") if door == "exec" else ("file-bug",)
                result = self.ech(*args, "--parent", "m-mine", "--prd", str(self.prd))
                self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(len([s for s in self.states()
                              if s.get("parentMission") == "m-mine"]), 3)

    def test_narrowed_validator_refuses_empty_ambiguous_and_unknown_selectors(self):
        self.mission("bug-002", title="Finding in the river", issue=112, parent="m-theirs")
        for door in ("file-bug", "exec"):
            args = ("exec", "lcars-log/log.sh") if door == "exec" else ("file-bug",)
            for selector in ("", "Finding in", "missing-mission"):
                with self.subTest(door=door, selector=selector):
                    result = self.ech(*args, "--parent", selector, "--prd", str(self.prd))
                    self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertFalse((self.repo / "forge.log").exists())

    def test_bad_scope_shape_is_refused_instead_of_widened(self):
        for scope in (None, "bug-001", [""]):
            self.ap["delegates"]["v1"]["recheckScope"] = scope
            self.save_ap()
            with self.subTest(scope=scope):
                result = self.ech("exec", "lcars-log/log.sh", "--parent", "bug-001",
                                  "--prd", str(self.prd))
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertIn("cannot read the recorded re-check scope", result.stdout)
        self.assertFalse((self.repo / "forge.log").exists())

    def test_out_of_scope_aliases_are_refused_on_both_filing_doors(self):
        for door in ("file-bug", "exec"):
            args = ("exec", "lcars-log/log.sh") if door == "exec" else ("file-bug",)
            for selector in ("THE RIVER", "#20", "m-theirs", "m-mine", "#10",
                             "theirs\nbug-001"):
                with self.subTest(door=door, selector=selector):
                    result = self.ech(*args, "--parent", selector, "--prd", str(self.prd))
                    self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertFalse((self.repo / "forge.log").exists())

    def test_narrowed_validator_can_file_below_its_own_finding(self):
        self.mission("followup", title="Nested repair", issue=113, parent="bug-001")
        for door in ("file-bug", "exec"):
            args = ("exec", "lcars-log/log.sh") if door == "exec" else ("file-bug",)
            with self.subTest(door=door):
                result = self.ech(*args, "--parent", "followup", "--prd", str(self.prd))
                self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(len([s for s in self.states()
                              if s.get("parentMission") == "followup"]), 2)

    def test_a_whole_newline_scope_entry_can_receive_a_valid_linked_child(self):
        mid = "odd\nfinding\n"
        self.mission(mid, title="Imported finding", issue=333, parent="m-mine")
        self.ap["delegates"]["v1"]["recheckScope"] = [mid]
        self.save_ap()
        for door in ("file-bug", "exec"):
            args = ("exec", "lcars-log/log.sh") if door == "exec" else ("file-bug",)
            with self.subTest(door=door):
                result = self.ech(*args, "--parent", mid, "--prd", str(self.prd))
                self.assertEqual(result.returncode, 0, result.stdout)
                self.assertTrue(any(s.get("parentMission") == mid for s in self.states()))

    def test_ancestry_does_not_trim_a_newline_into_an_in_scope_parent(self):
        self.mission("bug-001\n", title="Different finding", issue=333, parent="m-mine")
        self.mission("followup", title="Other finding's child", issue=334, parent="bug-001\n")
        result = self.ech("exec", "lcars-log/log.sh", "--parent", "followup",
                          "--prd", str(self.prd))
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("OUTSIDE YOUR RE-CHECK", result.stdout)
        self.assertFalse((self.repo / "forge.log").exists())

    def assert_literal_scope(self, mid):
        self.mission(mid, title="Another in-chunk finding", issue=333, parent="m-mine")
        result = self.ech("exec", "lcars-log/log.sh", "--parent", mid,
                          "--prd", str(self.prd))
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("OUTSIDE YOUR RE-CHECK", result.stdout)
        self.assertFalse((self.repo / "forge.log").exists())

    def test_a_dot_in_an_identifier_is_not_a_regular_expression(self):
        self.assert_literal_scope("bug.001")

    def test_a_newline_in_a_selector_is_not_several_patterns(self):
        self.assert_literal_scope("bug-001\nextra")

    def test_every_other_allowlisted_script_is_refused_to_a_validator(self):
        for script, args in (
            ("lcars-file/file.sh", ("--prd", str(self.prd))),
            ("lcars-run/run.sh", ("drive", "--mission", "bug-001")),
            ("lcars-respond/respond.sh", ("--mission", "bug-001", "--answer", "yes")),
            ("lcars-resolve-logs/resolve-logs.sh", ("--parent", "Finding in")),
        ):
            with self.subTest(script=script):
                result = self.ech("exec", script, *args)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertIn("NOT AN ACT A VALIDATION PASS MAY PERFORM", result.stdout)
        self.assertFalse((self.repo / "forge.log").exists())

    def test_empty_recorded_scope_is_not_a_fresh_pass(self):
        self.ap["delegates"]["v1"]["recheckScope"] = []
        self.save_ap()
        for door in ("file-bug", "exec"):
            args = ("exec", "lcars-log/log.sh") if door == "exec" else ("file-bug",)
            with self.subTest(door=door):
                result = self.ech(*args, "--parent", "bug-001", "--prd", str(self.prd))
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertIn("OUTSIDE YOUR RE-CHECK", result.stdout)
        self.assertFalse((self.repo / "forge.log").exists())

    def test_top_level_and_driver_file_bug_keep_the_exact_parent_precheck(self):
        for seat in ("d1", None):
            with self.subTest(seat=seat):
                result = self.ech("file-bug", "--parent", "#111",
                                  "--prd", str(self.prd), seat=seat)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertIn("no parent mission", result.stdout)
        self.assertFalse((self.repo / "forge.log").exists())

    def test_revalidate_reports_entries_without_word_or_line_splitting(self):
        mids = ["finding with spaces *", "finding\nm-theirs"]
        for issue, mid in enumerate(mids, 400):
            self.mission(mid, title="unusual finding", issue=issue, parent="m-mine")
        self.ap["delegates"]["v1"]["filed"] = mids
        self.save_ap()
        result = self.ech("revalidate", "v1", seat=None)
        self.assertEqual(result.returncode, 0, result.stdout)
        bounded = result.stdout.split("BOUNDED TO WHAT IT FILED — and to nothing else:\n", 1)[1]
        self.assertEqual(bounded.split("\n\n", 1)[0].splitlines(),
                         ["  finding with spaces *", r"  finding\nm-theirs"])

    def test_beat_requires_one_real_delegate_key_before_any_write(self):
        before = (self.data / "autopilot.json").read_bytes()
        result = self.ech("beat", "d1\nghost-nobody-minted", "progress", seat=None)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("beat: no delegate", result.stdout)
        self.assertEqual((self.data / "autopilot.json").read_bytes(), before)
        self.assertFalse((self.data / "delegates/d1/beats.jsonl").exists())

    def test_only_a_whole_run_wide_question_parks_everything(self):
        self.ap["questions"] = {
            "q1": {"id": "q1", "mission": "m-mine\n-\n", "what": "one Mission",
                   "raisedAt": 1},
        }
        self.save_ap()
        result = self.ech("next", seat=None)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertNotIn("NOTHING ELSE IS OFFERED", result.stdout)
        self.ap["questions"]["q1"]["mission"] = "-"
        self.save_ap()
        result = self.ech("next", seat=None)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("NOTHING ELSE IS OFFERED", result.stdout)

    def test_heartbeat_does_not_confuse_a_repo_path_prefix_with_this_repo(self):
        table = self.repo / "crontab.txt"
        neighbor = "17 * * * * echo neighbor # LCARS-ECH " + str(self.repo) + "-neighbor\n"
        table.write_text(neighbor)
        cron = self.bin / "crontab"
        cron.write_text('#!/bin/bash\n'
                        'if [ "$1" = -l ]; then cat "$LCARS_ECH_CWD/crontab.txt"\n'
                        'else cat "$1" > "$LCARS_ECH_CWD/crontab.txt"; fi\n')
        cron.chmod(0o755)
        self.env["LCARS_CRONTAB_BIN"] = str(cron)
        result = self.ech("heartbeat", "status", seat=None)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("not installed", result.stdout)
        result = self.ech("heartbeat", "remove", seat=None)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(table.read_text(), neighbor)

    def test_heartbeat_identity_may_itself_contain_the_marker(self):
        nested = self.repo / "repo # LCARS-ECH nested"
        nested.mkdir()
        shutil.move(self.repo / ".git", nested / ".git")
        self.repo = nested
        self.env["LCARS_ECH_CWD"] = str(nested)
        table = nested / "crontab.txt"
        table.write_text("")
        cron = self.bin / "crontab"
        cron.write_text('#!/bin/bash\n'
                        'if [ "$1" = -l ]; then cat "$LCARS_ECH_CWD/crontab.txt"\n'
                        'else cat "$1" > "$LCARS_ECH_CWD/crontab.txt"; fi\n')
        cron.chmod(0o755)
        self.env["LCARS_CRONTAB_BIN"] = str(cron)
        result = self.ech("heartbeat", "install", seat=None)
        self.assertEqual(result.returncode, 0, result.stdout)
        result = self.ech("heartbeat", "status", seat=None)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("heartbeat: installed", result.stdout)
        result = self.ech("heartbeat", "remove", seat=None)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(table.read_text(), "")


if __name__ == "__main__":
    unittest.main(verbosity=2)

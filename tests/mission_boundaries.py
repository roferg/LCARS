import json
import os
from pathlib import Path
import subprocess
import tempfile
import sys
import time
import unittest
from unittest.mock import patch


ROOT = Path(os.environ.get("LCARS_BOUNDARIES_ROOT", Path(__file__).resolve().parents[1]))


class Boundaries(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.repo = Path(self.tmp.name)
        subprocess.run(["git", "init", "-q", str(self.repo)], check=True)
        self.lcars = self.repo / ".git/lcars"
        self.missions = self.lcars / "missions"
        self.missions.mkdir(parents=True)
        (self.lcars / "config.json").write_text('{"numberOne":{"enabled":false}}')
        self.gh = self.repo / "gh"
        self.gh.write_text(
            '#!/bin/sh\nprintf "%s\\n" "$*" >>"$GH_LOG"\n'
            'case "$1 $2" in\n'
            ' "pr view") printf \'{"state":"%s","mergedAt":null}\\n\' "$GH_PR_STATE";;\n'
            ' "issue create") echo https://github.com/acme/repo/issues/43;;\n'
            'esac\n'
        )
        self.gh.chmod(0o755)
        self.env = dict(os.environ, LCARS_GH_BIN=str(self.gh),
                        GH_LOG=str(self.repo / "gh.log"), GH_PR_STATE="MERGED",
                        LCARS_RUN_BIN=str(self.repo / "no-estimator"),
                        LCARS_OWNER_ENFORCE="0", LCARS_XO_ENFORCE="0",
                        LCARS_XO_DRIVE="0", LCARS_VERSION_CHECK="0",
                        LCARS_COMMENT_MIRROR="/dev/null")
        for key in ("LCARS_SKILLS_DEST", "LCARS_AGENTS_DEST", "LCARS_COPILOT_PLUGINS_DIR"):
            self.env[key] = str(self.repo / "unused-install")
        # A missing shim must fail before any drive can resolve a real worker.
        shims = ROOT / "tests/lib/shims/deploy-watcher"
        for name in ("claude", "copilot"):
            self.assertTrue(os.access(shims / name, os.X_OK))
        self.env["PATH"] = str(shims) + os.pathsep + self.env["PATH"]
        self.env["LCARS_DRIVE_SHIM_LOG"] = str(self.repo / "workers.log")
        self.addCleanup(self.check_workers)

    def check_workers(self):
        log = self.repo / "workers.log"
        self.assertFalse(log.exists() and log.read_text(), "unexpected worker invocation")

    def mission(self, mid="parent", **fields):
        directory = self.missions / mid
        directory.mkdir(exist_ok=True)
        state = dict(id=mid, title="Example Mission", stage="verify",
                     type="feature", githubIssue=42, branch="lcars/" + mid)
        state.update(fields)
        (directory / "state.json").write_text(json.dumps(state, indent=2) + "\n")
        return directory

    def run_script(self, script, *args):
        return subprocess.run(["bash", str(ROOT / "skills" / script), *args],
                              cwd=self.repo, env=self.env, stdin=subprocess.DEVNULL,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                              text=True, timeout=90)

    def assert_bypass(self, output):
        self.assertIn("parent", output)
        self.assertIn("MERGE BYPASS", output)
        self.assertIn("logged bugs", output)
        self.assertIn("lcars approve", output)

    def test_merge_contradiction_status(self):
        mission = self.mission(prUrl="https://github.com/acme/repo/pull/77",
                               prNumber=77, review="open")
        before = (mission / "state.json").read_bytes()
        for args in ((), ("--once", "parent")):
            with self.subTest(args=args):
                result = self.run_script("lcars-status/status.sh", *args)
                self.assertEqual(result.returncode, 0, result.stdout)
                self.assert_bypass(result.stdout)
                self.assertEqual((mission / "state.json").read_bytes(), before)
        self.env["GH_PR_STATE"] = "OPEN"
        self.assertNotIn("MERGE BYPASS",
                         self.run_script("lcars-status/status.sh").stdout)

    def test_empty_mission_set_has_no_merge_error(self):
        self.missions.rmdir()
        (self.lcars / "autopilot.json").write_text('{"scope":[]}')
        result = self.run_script("lcars-eeh/ech.sh", "next")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("NEXT:", result.stdout)
        self.assertNotIn("MERGE CHECK UNAVAILABLE", result.stdout)

    def test_merge_contradiction_inbox_and_ech(self):
        mission = self.mission(prUrl="https://github.com/acme/repo/pull/77",
                               review="open")
        (self.lcars / "autopilot.json").write_text(json.dumps({
            "scope": ["M0"], "missions": {"M0": {"id": "parent"}}}))
        before = (mission / "state.json").read_bytes()
        for script, args in (
                ("lcars-answer/answer.sh", ()),
                ("lcars-eeh/eeh.sh", ()),
                ("lcars-eeh/ech.sh", ("status",)),
                ("lcars-eeh/ech.sh", ("next",)),
                ("lcars-eeh/ech.sh", ("report",))):
            with self.subTest(script=script, args=args):
                result = self.run_script(script, *args)
                self.assert_bypass(result.stdout)
                self.assertEqual((mission / "state.json").read_bytes(), before)
                if args == ("report",):
                    self.assert_bypass(
                        (self.lcars / "autopilot/report.html").read_text())

    def test_merge_contradiction_drive_never_repairs(self):
        mission = self.mission(prUrl="https://github.com/acme/repo/pull/77",
                               prNumber=77, review="open", paused=True)
        before = (mission / "state.json").read_bytes()
        result = self.run_script("lcars-run/run.sh", "drive", "--mission", "parent")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assert_bypass(result.stdout)
        self.assertEqual((mission / "state.json").read_bytes(), before)
        self.assertNotIn("add-label", (self.repo / "gh.log").read_text())

    def test_merge_contradiction_web(self):
        sys.path.insert(0, str(ROOT / "web"))
        from lcars_serve.local_adapter import LocalAdapter
        mission = self.mission(prUrl="https://github.com/acme/repo/pull/77",
                               review="open")
        before = (mission / "state.json").read_bytes()
        with patch.dict(os.environ, self.env):
            adapter = LocalAdapter(str(self.repo), git_url_reader=lambda: "",
                                   readiness_script="/dev/null")
            deadline = time.monotonic() + 5
            while True:
                card = adapter.mission("parent")
                if card.get("mergeHealth") or time.monotonic() > deadline:
                    break
                time.sleep(0.05)
            self.assert_bypass((card.get("mergeHealth") or {}).get("message", ""))
            self.assertEqual(card["stage"], "verify")
            self.assertEqual((mission / "state.json").read_bytes(), before)
            payload = self.repo / "card.json"
            payload.write_text(json.dumps({"mission": card}))
            for mode in ("card", "detail"):
                result = subprocess.run(
                    ["node", str(ROOT / "web/tests/board_basefresh_harness.js"),
                     mode, str(payload)], capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assert_bypass(result.stdout)

    def test_duplicate_bug_requires_explicit_decision(self):
        self.mission(stage="implement")
        prd = self.repo / "bug.md"
        prd.write_text("# Mission: Same symptom\n\n**Type:** bug\n"
                       "**Goal:** Restore the missing control.\n"
                       "**Acceptance Criteria:**\n- The control works.\n")
        script = "lcars-log/log.sh"
        args = ("--parent", "parent", "--prd", str(prd))
        first = self.run_script(script, *args)
        self.assertEqual(first.returncode, 0, first.stdout)
        children = [p for p in self.missions.iterdir() if p.name != "parent"]
        self.assertEqual(len(children), 1)
        first_id = children[0].name
        before = (children[0] / "state.json").read_bytes()
        second = self.run_script(script, *args)
        self.assertNotEqual(second.returncode, 0, second.stdout)
        self.assertIn(first_id, second.stdout)
        self.assertIn("Same symptom", second.stdout)
        self.assertIn("--confirm-distinct", second.stdout)
        self.assertNotRegex(second.stdout, r"(?m)^  lcars-")
        self.assertEqual(len(list(self.missions.iterdir())), 2)
        self.assertEqual((children[0] / "state.json").read_bytes(), before)
        confirmed = self.run_script(script, "--confirm-distinct", *args)
        self.assertEqual(confirmed.returncode, 0, confirmed.stdout)
        self.assertIn(first_id, confirmed.stdout)
        self.assertEqual(sum(line.startswith("  lcars-")
                             for line in confirmed.stdout.splitlines()), 1,
                         confirmed.stdout)
        later = [p for p in self.missions.iterdir()
                 if p.name not in ("parent", first_id)]
        self.assertEqual(len(later), 1)
        state = json.loads((later[0] / "state.json").read_text())
        self.assertEqual(state["duplicateReview"], [first_id])

    def test_open_siblings_are_candidates_without_matching_prose(self):
        self.mission(stage="implement")
        sibling = self.mission("older-bug", type="bug", parentMission="parent",
                               title="Completely different wording", stage="research")
        prd = self.repo / "bug.md"
        prd.write_text("# Mission: Missing icon\n**Type:** bug\n")
        args = ("--parent", "parent", "--prd", str(prd))
        blocked = self.run_script("lcars-log/log.sh", *args)
        self.assertNotEqual(blocked.returncode, 0, blocked.stdout)
        self.assertIn("older-bug", blocked.stdout)
        state = json.loads((sibling / "state.json").read_text())
        state["stage"] = "done"
        (sibling / "state.json").write_text(json.dumps(state))
        self.mission("elsewhere", stage="implement")
        self.mission("unrelated", type="bug", parentMission="elsewhere")
        allowed = self.run_script("lcars-log/log.sh", *args)
        self.assertEqual(allowed.returncode, 0, allowed.stdout)

    def test_retire_archives_intact_lists_and_releases_only_its_claim(self):
        mission = self.mission("stuck", stage="research")
        (mission / "nested").mkdir()
        (mission / "nested/evidence.bin").write_bytes(b"\x00keep\xff")
        before = {p.relative_to(mission): p.read_bytes()
                  for p in mission.rglob("*") if p.is_file()}
        owners = self.lcars / "chunk-owners"
        owners.write_text("stuck\td0\nother\td0\nstuck\td1\n")
        legacy = self.lcars / "missions-archived/legacy"
        legacy.mkdir(parents=True)
        (legacy / "state.json").write_text('{"id":"legacy","title":"Old archive"}')
        # Both directories predate this retirement.
        canonical = self.lcars / "archived-missions"
        canonical.mkdir()
        old = canonical / "old"
        old.mkdir()
        (old / "state.json").write_text('{"id":"old"}')
        result = self.run_script("lcars-eeh/ech.sh", "retire", "stuck",
                                 "--reason", "Worker cannot make progress")
        self.assertEqual(result.returncode, 0, result.stdout)
        archived = canonical / "stuck"
        self.assertFalse(mission.exists())
        self.assertTrue(archived.is_dir(), result.stdout)
        for path, content in before.items():
            self.assertEqual((archived / path).read_bytes(), content)
        reason = json.loads((archived / "retirement.json").read_text())
        self.assertEqual(reason["reason"], "Worker cannot make progress")
        self.assertTrue(reason["retiredAt"])
        self.assertEqual(owners.read_text(), "other\td0\n")
        listed = self.run_script("lcars-eeh/ech.sh", "retire", "--list")
        self.assertEqual(listed.returncode, 0, listed.stdout)
        listed_ids = {line.split()[0] for line in listed.stdout.splitlines()}
        self.assertEqual(listed_ids, {"stuck", "legacy", "old"})
        self.assertIn("Worker cannot make progress", listed.stdout)


if __name__ == "__main__":
    unittest.main()

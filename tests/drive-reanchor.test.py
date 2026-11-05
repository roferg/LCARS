#!/usr/bin/env python3
"""Real drive boundary: local git, pure fake workers, no model or forge calls."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path.cwd()
RUN = os.environ.get("LCARS_RUN_SCRIPT", str(ROOT / "skills/lcars-run/run.sh"))
SCRATCH = Path("tests/drives/s348")
# Untouched pre-S348 baseline, not HEAD's parent (which changes after commits).
# LCARS_S348_PARENT can supply the same baseline from another local git ref.
PARENT_COMMIT = os.environ.get(
    "LCARS_S348_PARENT", "69ad7ee8cbabe9c38d9bf170d83547c876f09553",
)


class DriveReanchor(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        SCRATCH.mkdir(parents=True, exist_ok=True)
        parent = SCRATCH / "parent"
        if parent.exists() or parent.is_symlink():
            raise RuntimeError(
                f"comparison path {parent} already exists; refusing to reuse or remove it"
            )
        subprocess.check_call(
            ["git", "worktree", "add", "--detach", str(parent), PARENT_COMMIT],
            stdin=subprocess.DEVNULL, timeout=90,
        )
        # Class cleanup runs even when a positive control fails.
        cls.addClassCleanup(
            subprocess.check_call,
            ["git", "worktree", "remove", "--force", str(parent)],
            stdin=subprocess.DEVNULL, timeout=90,
        )

    def setUp(self):
        SCRATCH.mkdir(parents=True, exist_ok=True)
        self.home = Path(tempfile.mkdtemp(prefix="reach-", dir=SCRATCH))
        self.repo = self.home / "repo"
        self.repo.mkdir()
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.name", "test")
        self.git("config", "user.email", "test@example.com")
        (self.repo / "shared").write_text("original\n")
        self.git("add", ".")
        self.git("commit", "-qm", "base")
        self.initial = self.git("rev-parse", "HEAD")
        self.git("checkout", "-qb", "lcars/m-001")
        (self.repo / "mission").write_text("mission\n")
        self.git("add", ".")
        self.git("commit", "-qm", "mission")
        (self.repo / "mission-two").write_text("second mission commit\n")
        self.git("add", ".")
        self.git("commit", "-qm", "second mission commit")
        self.old = self.git("rev-parse", "HEAD")
        self.git("checkout", "-q", "main")
        (self.repo / "incoming").write_text("base\n")
        self.git("add", ".")
        self.git("commit", "-qm", "incoming")
        self.base = self.git("rev-parse", "HEAD")
        self.mdir = self.repo / ".git/lcars/missions/m-001"
        self.mdir.mkdir(parents=True)
        self.state = self.mdir / "state.json"
        self.state.write_text(json.dumps({
            "id": "m-001", "type": "feature", "title": "Reach",
            "stage": "research", "branch": "lcars/m-001", "base": "main",
        }, indent=2) + "\n")
        (self.repo / ".git/lcars/config.json").write_text(json.dumps({
            "model": "claude-sonnet", "testCommand": "true",
        }, indent=2) + "\n")
        (self.repo / ".git/lcars/context-pack.md").write_text("# Context\n")
        (self.mdir / "prd.md").write_text(
            "# Mission: Reach\n\n**Type:** feature\n**Goal:** Add the route.\n"
            "**Acceptance Criteria:**\n- GET /about returns 200.\n"
            "**Out of Scope:**\n- Redesign.\n**Constraints:**\n- Existing router.\n"
        )
        (self.mdir / "validated-plan.md").write_text("# Validated Plan\n\nAdd the route.\n")
        (self.mdir / "estimate.json").write_text(json.dumps({
            "schemaVersion": 1, "reasoningCriticality": "low",
            "implCriticality": "low", "models": {
                key: "sonnet" for key in
                ("research", "validate", "plan", "planReview", "implement", "verify")
            }, "deviations": [], "estimatorModel": "opus",
        }))
        self.fake = self.home / "fake"
        self.fake.write_text("#!/usr/bin/env bash\nexit 0\n")
        self.fake.chmod(0o755)
        self.worker = self.home / "worker"
        self.worker.write_text("""#!/usr/bin/env python3
import json, os
from pathlib import Path
import subprocess
role = os.environ.get("LCARS_WORKER_ROLE", "")
with open(os.environ["RECORD"], "a") as f:
    tip = subprocess.check_output(["git", "rev-parse", "lcars/m-001"], text=True).strip()
    incoming = subprocess.run(["git", "cat-file", "-e", "lcars/m-001:incoming"]).returncode
    f.write(json.dumps({"role": role, "tip": tip, "incoming": incoming}) + "\\n")
out = Path(os.environ["LCARS_WORK_OUT"])
if role == "research-questions":
    (out / "questions.txt").write_text("")
elif role == "validate":
    (out / "validated-plan.md").write_text(
        "# Validated Plan\\n\\n## Synthesis\\nAdd the route.\\n\\n"
        "## Decisions\\n- Existing router.\\n\\n## Rationale\\n- Reuse routing.\\n")
elif role == "plan":
    (out / "plan.json").write_text(json.dumps([{
        "id": "t-001", "title": "Add route", "description": "Wire the existing router.",
        "acceptanceCriteria": ["GET /about returns 200"],
        "estimatedReadLoc": 10, "estimatedTestLoc": 10, "estimatedNewLoc": 10,
        "dependencies": [], "rationale": "Deliver the route."
    }], indent=2))
""")
        self.worker.chmod(0o755)
        self.record = self.home / "workers.jsonl"

    def tearDown(self):
        self.git("worktree", "prune")
        shutil.rmtree(self.home)

    def git(self, *args):
        return subprocess.check_output(
            ["git", "-C", str(self.repo), *args], text=True,
            stderr=subprocess.STDOUT,
        ).strip()

    def drive(self, stage="research", base="main", git_bin="git", **extra_env):
        state = json.loads(self.state.read_text())
        state.update(stage=stage, base=base)
        self.state.write_text(json.dumps(state, indent=2) + "\n")
        env = dict(os.environ, LCARS_VERSION_CHECK="0", LCARS_WORKER_HANG_SECS="0",
                   LCARS_WORKER_CLI="claude", LCARS_GH_BIN=str(ROOT / self.fake),
                   LCARS_NOTIFY=str(ROOT / self.fake), LCARS_RUN_BIN=str(ROOT / self.fake),
                   LCARS_WORKER_BIN=str(ROOT / self.worker), LCARS_GIT_BIN=git_bin,
                   RECORD=str(ROOT / self.record), TMPDIR=str(ROOT / self.home))
        env.update(extra_env)
        before = self.git("rev-parse", "lcars/m-001")
        captured_base = self.git("rev-parse", base)
        behind = self.git("rev-list", "--count", before + ".." + captured_base)
        ahead = self.git("rev-list", "--count", captured_base + ".." + before)
        result = subprocess.run(
            ["bash", RUN, "drive", "--mission", "m-001", "--step"],
            cwd=self.repo, env=env, stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=90,
        )
        (self.home / "drive.log").write_text(result.stdout)
        if os.environ.get("LCARS_S348_EVIDENCE"):
            with open(os.environ["LCARS_S348_EVIDENCE"], "a") as f:
                f.write(json.dumps({
                    "test": self.id(), "stage": stage, "rc": result.returncode,
                    "old": self.old, "base": self.base,
                    "capturedBase": captured_base, "before": before,
                    "behind": behind, "ahead": ahead,
                    "tip": self.git("rev-parse", "lcars/m-001"),
                    "state": json.loads(self.state.read_text()),
                    "workers": self.record.read_text() if self.record.exists() else "",
                    "output": result.stdout,
                }) + "\n")
        return result

    def test_research_recovers_and_advances(self):
        result = self.drive()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(json.loads(self.state.read_text())["stage"], "validate", result.stdout)
        workers = [json.loads(line) for line in self.record.read_text().splitlines()]
        self.assertEqual(workers[0]["incoming"], 0)
        self.assertNotEqual(workers[0]["tip"], self.old)
        self.assert_preserved()
        events = [json.loads(line) for line in (self.mdir / "events.jsonl").read_text().splitlines()]
        self.assertEqual([event["stage"] for event in events if event["type"] == "selfheal_reanchor"],
                         ["research"])
        self.assert_clean_recovery()

    def test_remote_tracking_base_recovers(self):
        self.git("update-ref", "refs/remotes/origin/main", self.base)
        initial = self.initial
        self.git("checkout", "-q", "--detach", initial)
        self.git("update-ref", "refs/heads/main", initial)
        result = self.drive(base="origin/main")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(json.loads(self.state.read_text())["stage"], "validate", result.stdout)
        self.assertEqual(self.git("merge-base", self.base, "lcars/m-001"), self.base)

    def assert_clean_recovery(self):
        self.assertEqual(len(self.git("worktree", "list", "--porcelain").split("worktree ")) - 1, 1)
        self.assertEqual(list(self.mdir.glob("reanchor.*")), [])
        self.assertFalse((self.repo / ".git/lcars/replay.lock").exists())

    def wrapper(self, body):
        wrapper = self.home / "git-wrapper"
        wrapper.write_text("#!/usr/bin/env bash\n" + body + '\nexec git "$@"\n')
        wrapper.chmod(0o755)
        return str(ROOT / wrapper)

    def assert_preserved(self):
        self.assertEqual(self.git("merge-base", self.old, "lcars/m-001"), self.old)
        self.assertEqual(self.git("merge-base", self.base, "lcars/m-001"), self.base)

    def test_validate_recovers_preserving_both_tips_and_advances(self):
        result = self.drive(stage="validate")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(json.loads(self.state.read_text())["stage"], "plan", result.stdout)
        self.assert_preserved()
        self.assert_clean_recovery()

    def test_plan_recovers_preserving_both_tips_and_advances(self):
        result = self.drive(stage="plan")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(json.loads(self.state.read_text())["stage"], "plan-review", result.stdout)
        self.assert_preserved()
        self.assert_clean_recovery()

    def test_concurrent_advance_is_recorded_without_retry_or_dereference(self):
        race = self.git("commit-tree", self.git("rev-parse", "lcars/m-001^{tree}"),
                        "-p", self.old, "-m", "concurrent fix")
        calls = self.home / "cas.log"
        wrapper = self.wrapper("""
if [ "$1" = update-ref ]; then
  printf '%s\\n' "$*" >>"$UPDATE_LOG"
  git update-ref refs/heads/lcars/m-001 "$RACE_SHA" || exit 1
fi
""")
        result = self.drive(git_bin=wrapper, RACE_SHA=race, UPDATE_LOG=str(ROOT / calls))
        self.assertEqual(result.returncode, 0, result.stdout)
        state = json.loads(self.state.read_text())
        self.assertTrue(state.get("awaitingHuman"), result.stdout)
        self.assertIn("mission tip changed", state["pendingQuestion"])
        self.assertEqual(self.git("rev-parse", "lcars/m-001"), race)
        self.assertEqual(self.git("merge-base", self.old, race), self.old)
        attempts = calls.read_text().splitlines()
        self.assertEqual(len(attempts), 1)
        self.assertIn("--no-deref", attempts[0])
        self.assertTrue(attempts[0].endswith(self.old))
        self.assertIn("selfheal_refused", (self.mdir / "events.jsonl").read_text())
        self.assertFalse(self.record.exists())
        self.assert_clean_recovery()

    def test_worktree_creation_error_parks_and_cleans_up(self):
        wrapper = self.wrapper("""
if [ "$1" = worktree ] && [ "${2:-}" = add ]; then
  printf 'injected worktree creation error\\n' >&2
  exit 2
fi
""")
        result = self.drive(git_bin=wrapper)
        self.assertEqual(result.returncode, 0, result.stdout)
        state = json.loads(self.state.read_text())
        self.assertTrue(state.get("awaitingHuman"), result.stdout)
        self.assertIn("injected worktree creation error", state["pendingQuestion"])
        self.assertEqual(self.git("rev-parse", "lcars/m-001"), self.old)
        self.assertFalse(self.record.exists())
        self.assert_clean_recovery()

    def test_changed_base_refuses_and_cleans_up(self):
        new_base = self.git("commit-tree", self.git("rev-parse", "main^{tree}"),
                            "-p", self.base, "-m", "new base")
        wrapper = self.wrapper("""
if [ "$1" = worktree ] && [ "${2:-}" = remove ]; then
  git update-ref refs/heads/main "$NEW_BASE" || exit 1
fi
""")
        result = self.drive(git_bin=wrapper, NEW_BASE=new_base)
        self.assertEqual(result.returncode, 0, result.stdout)
        state = json.loads(self.state.read_text())
        self.assertTrue(state.get("awaitingHuman"), result.stdout)
        self.assertIn("base changed during the merge", state["pendingQuestion"])
        self.assertEqual(self.git("rev-parse", "lcars/m-001"), self.old)
        self.assertFalse(self.record.exists())
        self.assert_clean_recovery()

    def test_term_during_creation_cleans_worktree_and_mutex(self):
        wrapper = self.wrapper("""
if [ "$1" = worktree ] && [ "${2:-}" = add ]; then
  git "$@" || exit 1
  kill -TERM "$PPID"
  exit 143
fi
""")
        result = self.drive(git_bin=wrapper)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertTrue(json.loads(self.state.read_text()).get("awaitingHuman"), result.stdout)
        self.assertIn("status 143", json.loads(self.state.read_text())["pendingQuestion"])
        self.assertEqual(self.git("rev-parse", "lcars/m-001"), self.old)
        self.assertFalse(self.record.exists())
        self.assert_clean_recovery()

    def test_positive_controls_are_byte_identical_at_lossless_seam(self):
        parent = SCRATCH / "parent/skills/lcars-init/lcars-common.sh"
        self.assertTrue(parent.is_file(), "mandatory positive-control parent is missing")
        script = """
. "$1"
lcars_base_advance_mission_branch "$2" "$3"
lcars_base_branch_note_drive "$2" "$3"
printf 'move=%s behind=%s ahead=%s\\n' "$LCARS_MB_MOVE" "$LCARS_MB_BEHIND" "$LCARS_MB_AHEAD"
"""
        current = ROOT / "skills/lcars-init/lcars-common.sh"
        def observe(common, branch, base):
            return subprocess.check_output(
                ["bash", "-c", script, "control", str(common), branch, base],
                cwd=self.repo, text=True,
            )
        self.git("branch", "level", self.old)
        self.assertEqual(observe(current, "lcars/m-001", "level"),
                         observe(ROOT / parent, "lcars/m-001", "level"))
        own_output = observe(current, "lcars/m-001", "main")
        self.assertIn("DESTROY", own_output)
        self.assertEqual(own_output, observe(ROOT / parent, "lcars/m-001", "main"))
        self.assertEqual(self.git("rev-parse", "lcars/m-001"), self.old)
        initial = self.initial
        self.git("branch", "empty", initial)
        output = observe(current, "empty", "main")
        self.assertEqual(self.git("rev-parse", "empty"), self.base)
        self.git("update-ref", "refs/heads/empty", initial, self.base)
        self.assertEqual(output, observe(ROOT / parent, "empty", "main"))
        self.assertEqual(self.git("rev-parse", "empty"), self.base)

    def test_level_and_empty_drive_output_is_byte_identical_to_parent(self):
        global RUN
        parent_run = ROOT / SCRATCH / "parent/skills/lcars-run/run.sh"
        self.assertTrue(parent_run.is_file(), "mandatory positive-control parent is missing")
        current_run = RUN
        self.git("branch", "preserved-mission-tip", self.old)
        self.git("branch", "level", self.old)
        for base in ("level", "main"):
            with self.subTest(base=base):
                start = self.old if base == "level" else self.initial
                tip = self.git("rev-parse", "lcars/m-001")
                self.git("update-ref", "refs/heads/lcars/m-001", start, tip)
                current = self.drive(stage="align", base=base)
                after = self.git("rev-parse", "lcars/m-001")
                self.git("update-ref", "refs/heads/lcars/m-001", start, after)
                try:
                    RUN = str(parent_run)
                    previous = self.drive(stage="align", base=base)
                finally:
                    RUN = current_run
                self.assertEqual(current.returncode, previous.returncode)
                self.assertEqual(current.returncode, 0, current.stdout)
                self.assertEqual(current.stdout,
                                 previous.stdout.replace(str(parent_run), current_run))
                self.assertNotIn("RECOVERY", current.stdout)
                self.assertEqual(json.loads(self.state.read_text())["stage"], "validate")

    def test_conflict_parks_for_human_without_dispatch(self):
        self.git("checkout", "-q", "lcars/m-001")
        (self.repo / "shared").write_text("mission edit\n")
        self.git("add", ".")
        self.git("commit", "-qm", "mission edit")
        self.old = self.git("rev-parse", "HEAD")
        self.git("checkout", "-q", "main")
        (self.repo / "shared").write_text("base edit\n")
        self.git("add", ".")
        self.git("commit", "-qm", "base edit")
        self.base = self.git("rev-parse", "HEAD")
        result = self.drive()
        self.assertEqual(result.returncode, 0, result.stdout)
        state = json.loads(self.state.read_text())
        self.assertTrue(state.get("awaitingHuman"), result.stdout)
        self.assertEqual(state["stage"], "research")
        self.assertIn("Resolve the merge with a human", state["pendingQuestion"])
        self.assertEqual(self.git("rev-parse", "lcars/m-001"), self.old)
        self.assertFalse(self.record.exists())
        self.assert_clean_recovery()


if __name__ == "__main__":
    unittest.main()

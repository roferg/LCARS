#!/usr/bin/env bash
# S377: real adapter + real git/mission records; only the forge is replaced.
set -euo pipefail
python3 - "$@" <<'PY'
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path.cwd()
ADAPTER = Path(os.environ.get("LCARS_HOST_ADAPTER", "skills/lcars-run/host-adapter.sh")).resolve()
APPROVE = Path(os.environ.get("LCARS_APPROVE_SCRIPT", "skills/lcars-approve/approve.sh")).resolve()
SCRATCH = ROOT / ".s377"
SCRATCH.mkdir(exist_ok=True)


class MergeDoor(unittest.TestCase):
    def setUp(self):
        self.repo = Path(tempfile.mkdtemp(prefix="merge-door-", dir=SCRATCH))
        subprocess.run(["git", "init", "-q", str(self.repo)], check=True)
        self.missions = self.repo / ".git/lcars/missions"
        self.parent = "lcars-parent"
        self.child = "lcars-bug"
        self.record(self.parent, stage="verify", title="Parent", type="feature",
                    branch="lcars/" + self.parent, prUrl="https://example.test/pull/77",
                    prNumber=77)
        self.record(self.child, stage="implement", type="bug",
                    parentMission=self.parent, title="Fix the missing control")
        self.log = self.repo / "gh.log"
        self.gh = self.repo / "gh"
        self.gh.write_text("""#!/usr/bin/env bash
printf '%s\\n' "$*" >>"$GH_LOG"
if [ "$1 $2" = "pr view" ]; then
  [ "${LOOKUP_FAIL:-0}" = 0 ] || exit 1
  printf '%s\\n' "$PR_HEAD"
fi
""")
        self.gh.chmod(0o755)
        self.env = dict(os.environ, LCARS_GH_BIN=str(self.gh),
                        GH_LOG=str(self.log), PR_HEAD="lcars/" + self.parent,
                        LCARS_VERSION_CHECK="0", LCARS_OWNER_ENFORCE="0")

    def tearDown(self):
        shutil.rmtree(self.repo)

    def record(self, mid, **fields):
        path = self.missions / mid / "state.json"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(dict(id=mid, **fields), indent=2))

    def merge(self, *args):
        return subprocess.run(["bash", str(ADAPTER), "pr-merge", *args],
                              cwd=self.repo, env=self.env, text=True,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    def calls(self):
        return self.log.read_text() if self.log.exists() else ""

    def test_open_child_refuses_head(self):
        result = self.merge("--head", "lcars/" + self.parent)
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("pr merge ", self.calls())
        self.assertIn(self.child, result.stderr)
        self.assertIn("Fix the missing control", result.stderr)
        self.assertIn("lcars resolve-logs " + self.parent, result.stderr)
        self.assertRegex(result.stderr.strip(), r" — run: bash .+ --parent lcars-parent$")

    def test_open_child_refuses_number_and_positional(self):
        for args in [("--number", "77"), ("77",),
                     ("--number", "77", "--head", "unrelated")]:
            with self.subTest(args=args):
                result = self.merge(*args)
                self.assertNotEqual(result.returncode, 0, result.stderr)
                self.assertNotIn("pr merge ", self.calls())
                self.assertIn(self.child, result.stderr)

    def test_same_merge_succeeds_after_child_closed(self):
        for selector in [("--head", "lcars/" + self.parent), ("--number", "77")]:
            with self.subTest(selector=selector):
                self.record(self.child, stage="implement", type="bug",
                            parentMission=self.parent, title="Still open")
                self.assertNotEqual(self.merge(*selector).returncode, 0)
                self.assertNotIn("pr merge ", self.calls())
                self.record(self.child, stage="done", type="bug",
                            parentMission=self.parent, title="Closed")
                result = self.merge(*selector, "--method", "squash")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("pr merge " + selector[1] + " --squash", self.calls())
                self.log.unlink()

    def test_non_lcars_pr_is_unaffected(self):
        self.env["PR_HEAD"] = "feature/ordinary"
        for selector in [("--head", "feature/ordinary"), ("--number", "88")]:
            with self.subTest(selector=selector):
                result = self.merge(*selector)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("pr merge " + selector[1] + " --merge", self.calls())

    def test_unresolved_mission_is_unaffected(self):
        for branch in ["lcars/not-recorded", ""]:
            with self.subTest(branch=branch):
                self.env["PR_HEAD"] = branch
                result = self.merge("--number", "89")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("pr merge 89 --merge", self.calls())
        self.env["LOOKUP_FAIL"] = "1"
        result = self.merge("--number", "90")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("pr merge 90 --merge", self.calls())

    def test_folded_child_does_not_block(self):
        self.record(self.child, stage="verify", type="bug", parentMission=self.parent,
                    foldedInto=self.parent, title="Already included")
        result = self.merge("--head", "lcars/" + self.parent)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("pr merge ", self.calls())

    def test_owner_may_finish_but_closed_owner_cannot_bypass(self):
        lcars = self.missions.parent
        seat = lcars / "delegates/d1"
        seat.mkdir(parents=True)
        (seat / "BRIEF.md").write_text("Own and drive the logged fix")
        (seat / "OPEN").touch()
        (lcars / "chunk-owners").write_text(self.child + "\td1\n")
        result = self.merge("--head", "lcars/" + self.parent)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("driven by sub-ECH d1", result.stderr)
        self.assertIn("pr merge ", self.calls())
        self.log.unlink()
        (seat / "OPEN").unlink()
        result = self.merge("--head", "lcars/" + self.parent)
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("pr merge ", self.calls())

    def test_unreadable_record_still_refuses(self):
        (self.missions / self.child / "state.json").write_text("broken JSON")
        result = self.merge("--head", "lcars/" + self.parent)
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("pr merge ", self.calls())
        self.assertIn("cannot be read", result.stderr)
        self.assertRegex(result.stderr.strip(), r" — run: bash .+ --mission lcars-parent$")

    def test_approve_and_adapter_print_identical_refusal(self):
        adapter = self.merge("--head", "lcars/" + self.parent)
        approve = subprocess.run(["bash", str(APPROVE), "--mission", self.parent],
                                 cwd=self.repo, env=self.env, text=True, capture_output=True)
        self.assertNotEqual(approve.returncode, 0, approve.stdout + approve.stderr)
        self.assertEqual(approve.stderr, adapter.stderr)
        self.assertNotIn("pr merge ", self.calls())


unittest.main(argv=["merge-door", *__import__("sys").argv[1:]], verbosity=2)
PY

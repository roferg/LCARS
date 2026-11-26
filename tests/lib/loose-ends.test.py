"""S371: real preflight, policy, Verify, git push and isolated installation."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import time
import unittest


ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("handoff", ROOT / "tests/lib/chunk-handoff.test.py")
handoff = importlib.util.module_from_spec(spec)
spec.loader.exec_module(handoff)


class LooseEnds(unittest.TestCase):
    setUpClass = classmethod(handoff.ChunkHandoff.setUpClass.__func__)
    tearDownClass = classmethod(handoff.ChunkHandoff.tearDownClass.__func__)
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

    def setUp(self):
        handoff.ChunkHandoff.setUp(self)
        ap = self.ap()
        ap.update(push={"mode": "local-only"}, launchDir=str(self.repo), testCommand="true")
        self.write(self.data / "autopilot.json", ap)
        gh = self.bin / "gh"
        gh.write_text("""#!/bin/bash
printf '%s\\n' "$*" >> "$LCARS_ECH_CWD/forge.log"
case "$1 $2" in
  'pr create') echo https://github.com/example/test/pull/42 ;;
  'pr edit') [ ! -f "$LCARS_ECH_CWD/review-fails" ] ;;
  'issue create') echo https://github.com/example/test/issues/999 ;;
  *) echo '[]' ;;
esac
""")
        gh.chmod(0o755)
        self.env["LCARS_CLAUDE_BIN"] = str(self.bin / "claude")
        self.env["LCARS_COPILOT_BIN"] = str(self.bin / "copilot")
        for name in ("claude", "copilot"):
            p = self.bin / name
            p.write_text("""#!/bin/bash
printf '%s\\n' "$*" >> "$LCARS_ECH_CWD/cli-probes.log"
[ "$*" = --version ] && { echo 'test CLI'; exit 0; }
echo MODEL-SPEND-FUSE >> "$LCARS_ECH_CWD/spend.log"
exit 97
""")
            p.chmod(0o755)

    def run_script(self, relative, *args, timeout=120):
        return subprocess.run(["bash", str(self.skills / relative), *args],
                              cwd=self.repo, env=self.env, stdin=subprocess.DEVNULL,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                              text=True, timeout=timeout)

    def mission(self, mid, branch="lcars/mine", **extra):
        self.write(self.data / "missions" / mid / "state.json",
                   dict(id=mid, stage="verify", title=mid, branch=branch, base="main", **extra))

    def test_preflight_preserves_recorded_false_and_siblings(self):
        original = {"enabled": False, "engine": "copilot", "model": "kept",
                    "settledAt": 17, "captainsRuling": "OFF"}
        self.succeeds(self.ech("record", "numberOne", json.dumps(original)))
        self.succeeds(self.ech("preflight"))
        for key, value in original.items():
            self.assertEqual(self.ap()["numberOne"][key], value, key)
        config = json.loads((self.data / "config.json").read_text())
        self.assertFalse(config["numberOne"]["enabled"])
        self.assertFalse((self.repo / "spend.log").exists())
        self.succeeds(self.ech("preflight"))
        self.assertFalse(self.ap()["numberOne"]["enabled"])

    def test_fresh_init_is_off_and_preflight_does_not_opt_in(self):
        (self.data / "config.json").unlink()
        self.succeeds(self.run_script("lcars-init/init.sh"))
        config = json.loads((self.data / "config.json").read_text())
        self.assertFalse(config["numberOne"]["enabled"])
        self.succeeds(self.ech("preflight"))
        self.assertFalse(json.loads((self.data / "config.json").read_text())["numberOne"]["enabled"])
        self.assertFalse(self.ap()["numberOne"]["enabled"])

    def test_policy_off_uses_recorded_live_verdict_not_stale_xo(self):
        self.mission("m-mine")
        self.write(self.data / "missions/m-mine/xo/verdict.json",
                   {"score": "low", "recommendation": "send-back"})
        for live, action in (("pass", "merge"), ("bugs", "send-back")):
            self.succeeds(self.ech("record", "liveChecks.m-mine.verdict", live))
            output = self.succeeds(self.ech("policy", "--mission", "m-mine",
                                           "--live-check", live))
            self.assertIn("ACTION: " + action, output)
            self.assertIn("OFF", output)
        missing = self.ech("policy", "--mission", "m-missing", "--live-check", "pass")
        self.assertNotEqual(missing.returncode, 0)
        self.assertIn("NO live check", missing.stdout)
        mismatch = self.ech("policy", "--mission", "m-mine", "--live-check", "pass")
        self.assertNotEqual(mismatch.returncode, 0)
        self.assertIn("disagree", mismatch.stdout)
        self.succeeds(self.ech("record", "liveChecks.m-mine.verdict", "pass"))
        config = json.loads((self.data / "config.json").read_text())
        config["numberOne"]["enabled"] = True
        self.write(self.data / "config.json", config)
        self.succeeds(self.ech("policy", "--mission", "m-mine", "--live-check", "pass",
                               "--verdict", "high"))
        (self.data / "missions/m-mine/xo/verdict.json").unlink()
        enabled = self.ech("policy", "--mission", "m-mine", "--live-check", "pass")
        self.assertNotEqual(enabled.returncode, 0)
        self.assertIn("--verdict", enabled.stdout)
        fabricated = self.ech("policy", "--mission", "m-mine", "--live-check", "pass",
                              "--verdict", "off")
        self.assertNotEqual(fabricated.returncode, 0)
        self.assertIn("OFF", fabricated.stdout)

    def prepare_pr(self):
        remote = self.repo / "origin.git"
        subprocess.run(["git", "init", "-q", "--bare", str(remote)], check=True)
        self.git("remote", "add", "origin", str(remote))
        self.git("checkout", "-qb", "lcars/mine")
        (self.repo / "product").write_text("delivered\n")
        self.git("add", "product")
        self.git("commit", "-qm", "deliver")
        self.git("checkout", "-q", "main")
        self.mission("m-mine")
        return remote

    def test_verify_requests_declared_review_and_retries_failure_without_second_pr(self):
        self.prepare_pr()
        (self.repo / "AGENTS.md").write_text("Every PR MUST request a Copilot code review.\n")
        missing = self.run_script("lcars-run/run.sh", "open-pr", "--mission", "m-mine")
        self.assertNotEqual(missing.returncode, 0)
        self.assertIn("prReviewers", missing.stdout)
        config = json.loads((self.data / "config.json").read_text())
        config["prReviewers"] = ["@copilot", "owner/team", "reviewer"]
        self.write(self.data / "config.json", config)
        (self.repo / "review-fails").touch()
        refused = self.run_script("lcars-run/run.sh", "open-pr", "--mission", "m-mine")
        self.assertNotEqual(refused.returncode, 0)
        self.assertIn("review", refused.stdout.lower())
        self.assertEqual(self.git("branch", "--show-current").stdout.strip(), "main")
        (self.repo / "review-fails").unlink()
        self.succeeds(self.run_script("lcars-run/run.sh", "open-pr", "--mission", "m-mine"))
        self.succeeds(self.run_script("lcars-run/run.sh", "open-pr", "--mission", "m-mine"))
        calls = (self.repo / "forge.log").read_text().splitlines()
        self.assertEqual(sum(row.startswith("pr create ") for row in calls), 1)
        requests = [row for row in calls if row.startswith("pr edit ")]
        prefix = "pr edit https://github.com/example/test/pull/42 --add-reviewer "
        self.assertEqual(requests, [prefix + reviewer for reviewer in
                                   ("@copilot", "@copilot", "owner/team", "reviewer")])
        state = json.loads((self.data / "missions/m-mine/state.json").read_text())
        self.assertEqual(state["prUrl"], "https://github.com/example/test/pull/42")
        self.assertTrue(state["prReviewRequest"])
        self.assertEqual(state["review"], "open")

    def test_seat_refresh_tests_exact_branch_then_pushes_without_merging(self):
        remote = self.prepare_pr()
        self.succeeds(self.ech("record", "missions.fish.id", "m-mine"))
        seat = self.mint("fish")
        self.mission("m-theirs", branch="lcars/theirs")
        self.git("branch", "lcars/theirs", "lcars/mine")
        for mid in ("m-theirs", "main"):
            refused = self.ech("exec", "--refresh", mid, seat=seat)
            self.assertNotEqual(refused.returncode, 0)
        self.succeeds(self.ech("record", "testCommand", "test -f product && exit 7"))
        failed = self.ech("exec", "--refresh", "m-mine", seat=seat)
        self.assertNotEqual(failed.returncode, 0)
        self.assertIn("suite", failed.stdout)
        absent = subprocess.run(["git", "--git-dir", str(remote), "show-ref"],
                                capture_output=True, text=True)
        self.assertNotEqual(absent.returncode, 0)
        self.succeeds(self.ech("record", "testCommand", "test -f product"))
        self.succeeds(self.ech("exec", "--refresh", "m-mine", seat=seat))
        tip = self.git("rev-parse", "lcars/mine").stdout.strip()
        published = subprocess.run(["git", "--git-dir", str(remote), "rev-parse", "lcars/mine"],
                                   check=True, capture_output=True, text=True).stdout.strip()
        self.assertEqual(published, tip)
        refs = subprocess.run(["git", "--git-dir", str(remote), "for-each-ref", "--format=%(refname)"],
                              check=True, capture_output=True, text=True).stdout.splitlines()
        self.assertEqual(refs, ["refs/heads/lcars/mine"])
        self.assertEqual(self.git("branch", "--show-current").stdout.strip(), "main")
        self.assertEqual(json.loads((self.data / "missions/m-mine/state.json").read_text())["stage"],
                         "verify")
        self.succeeds(self.ech("delegate", "fish", "--validate", "--trigger", "wide",
                               "--why", "shared river machinery"))
        validator = next(key for key, row in self.ap()["delegates"].items() if row.get("validates"))
        denied = self.ech("exec", "--refresh", "m-mine", seat=validator)
        self.assertNotEqual(denied.returncode, 0)
        self.assertIn("validation pass", denied.stdout)

    def test_seat_await_is_bounded_and_only_waits_for_a_parallel_slot(self):
        seat = self.mint("fish")
        self.succeeds(self.ech("record", "drivers", json.dumps({
            "a": {"pid": os.getpid()}, "b": {"pid": os.getpid()},
        })))
        start = time.monotonic()
        before = self.ap()
        full = self.ech("exec", "--await", "--limit", "1", seat=seat)
        self.assertEqual(full.returncode, 124, full.stdout)
        self.assertGreaterEqual(time.monotonic() - start, 1)
        self.assertLess(time.monotonic() - start, 20)
        self.assertIn("2", full.stdout)
        self.assertEqual(self.ap(), before)
        self.succeeds(self.ech("record", "drivers.b.pid", ""))
        free = self.succeeds(self.ech("exec", "--await", "--limit", "0", seat=seat))
        self.assertIn("slot is free", free)

    def test_refresh_rejects_success_shaped_failure_and_a_moving_head(self):
        remote = self.prepare_pr()
        self.succeeds(self.ech("record", "missions.fish.id", "m-mine"))
        seat = self.mint("fish")
        for command in ("printf 'FAILED\\n'", "exit 9",
                        "git checkout -q --detach main"):
            self.succeeds(self.ech("record", "testCommand", command))
            result = self.ech("exec", "--refresh", "m-mine", seat=seat)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("NOTHING pushed", result.stdout)
        original = self.git("rev-parse", "lcars/mine").stdout.strip()
        self.git("checkout", "-q", "lcars/mine")
        self.git("commit", "-qm", "later change", "--allow-empty")
        moved = self.git("rev-parse", "HEAD").stdout.strip()
        self.git("checkout", "-q", "main")
        self.git("update-ref", "refs/heads/lcars/mine", original)
        self.succeeds(self.ech("record", "testCommand",
                               'git -C "$LCARS_ECH_CWD" update-ref refs/heads/lcars/mine ' + moved))
        refused = self.ech("exec", "--refresh", "m-mine", seat=seat)
        self.assertNotEqual(refused.returncode, 0)
        self.assertIn("head moved", refused.stdout)
        refs = subprocess.run(["git", "--git-dir", str(remote), "show-ref"],
                              capture_output=True, text=True)
        self.assertNotEqual(refs.returncode, 0)

    def test_worktree_install_refuses_live_agents_and_eeh_names_every_dangling_link(self):
        source = Path(os.environ.get("LCARS_TEST_SOURCE", ROOT))
        tree = self.repo / "source"
        subprocess.run(["git", "-C", str(ROOT), "worktree", "add", "--detach",
                        str(tree), "HEAD"], check=True, capture_output=True)
        self.addCleanup(subprocess.run, ["git", "-C", str(ROOT), "worktree", "remove",
                                         "--force", str(tree)], capture_output=True)
        shutil.copy2(source / "install.sh", tree / "install.sh")
        shutil.copy2(self.skills / "lcars-eeh/eeh.sh", tree / "skills/lcars-eeh/eeh.sh")
        home = self.repo / "home"
        home.mkdir()
        env = dict(self.env, HOME=str(home), LCARS_BIN_DEST=str(home / "bin"),
                   LCARS_SKILLS_DEST=str(home / "skills"),
                   LCARS_COPILOT_PLUGINS_DIR=str(home / "plugins"),
                   LCARS_COPILOT_CONFIG=str(home / "copilot.json"))
        env["PATH"] = str(home / "bin") + os.pathsep + env["PATH"]
        for key in ("LCARS_INSTALL_PREFIX", "LCARS_AGENTS_DEST"):
            env.pop(key, None)

        def install():
            return subprocess.run(["bash", str(tree / "install.sh")], cwd=tree, env=env,
                                  stdin=subprocess.DEVNULL, capture_output=True,
                                  text=True, timeout=180)

        refused = install()
        self.assertNotEqual(refused.returncode, 0)
        self.assertIn("worktree", refused.stdout + refused.stderr)
        self.assertFalse((home / ".claude/agents/ech.md").is_symlink())
        env["LCARS_AGENTS_DEST"] = str(home / "isolated-agents")
        self.succeeds(install())
        link = home / "isolated-agents/ech.md"
        self.assertTrue(link.resolve().is_file())
        link.unlink()
        link.symlink_to(home / "missing-ech.md")
        other = home / "isolated-agents/other.md"
        other.symlink_to(home / "missing-other.md")
        skill = home / "skills/lcars-extra"
        skill.symlink_to(tree / "skills/no-such-skill")
        plugin = home / "plugins/lcars"
        plugin.unlink()
        plugin.symlink_to(home / "missing-plugin")
        env.update(LCARS_REPO=str(tree), LCARS_EEH_CWD=str(self.repo))
        diagnostic = subprocess.run(["bash", str(tree / "skills/lcars-eeh/eeh.sh")],
                                    cwd=self.repo, env=env, stdin=subprocess.DEVNULL,
                                    capture_output=True, text=True, timeout=120)
        self.assertIn("DANGLING", diagnostic.stdout)
        self.assertIn(str(link), diagnostic.stdout)
        self.assertIn(str(other), diagnostic.stdout)
        self.assertIn("DANGLING installed skill: " + str(skill), diagnostic.stdout)
        self.assertIn("DANGLING installed plugin: " + str(plugin), diagnostic.stdout)
        rejected = install()
        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn("DANGLING installed link: " + str(other), rejected.stdout + rejected.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)

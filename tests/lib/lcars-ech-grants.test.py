"""S315 public seams: ECH verbs, durable records, and the seat's playbook."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]  # tests/lib/<file> -> repo root
SCRIPT = Path(os.environ.get("LCARS_ECH_SCRIPT", ROOT / "skills/lcars-eeh/ech.sh"))
PLAYBOOK = ROOT / "skills/lcars-eeh/HOLOGRAM-COMMAND-MODE.md"


class Grants(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="lcars-s315-")
        self.addCleanup(self.scratch.cleanup)
        self.repo = Path(self.scratch.name)
        subprocess.run(["git", "init", "-q", str(self.repo)], check=True)
        self.data = self.repo / ".git/lcars"
        self.data.mkdir()
        self.ap = self.data / "autopilot.json"
        self.write(self.ap, {
            "startedAt": 1792800000, "engine": "copilot", "scope": [],
            "missions": {}, "drivers": {}, "questions": {}, "pending": {},
            "push": {"mode": "local-only"}, "launchDir": str(self.repo),
            "testCommand": "true",
        })
        self.write(self.data / "config.json", {
            "engine": "copilot", "numberOne": {"enabled": False},
        })
        self.calls = self.repo / "calls"
        self.calls.touch()
        self.notify = self.repo / "notify"
        self.notify.write_text('#!/bin/bash\nprintf "ping\\n" >> "$LCARS_ECH_CWD/pings"\n')
        self.approve = self.repo / "approve.sh"
        self.approve.write_text("""#!/bin/bash
printf '%s\\n' "$*" >> "$LCARS_ECH_CWD/calls"
printf '%s\\n' "$PWD" > "$LCARS_ECH_CWD/approve-cwd"
if [ -f "$LCARS_ECH_CWD/refusal" ]; then
  cat "$LCARS_ECH_CWD/refusal"
  exit 1
fi
python3 - "$LCARS_ECH_CWD" "$@" <<'PY'
import json, pathlib, sys
root, args = pathlib.Path(sys.argv[1]), sys.argv[2:]
m = args[args.index("--mission") + 1]
p = root / ".git/lcars/missions" / m / "state.json"
d = json.loads(p.read_text())
if "--reapprove" in args:
    d["stage"] = "done"
    print("approved with the recorded sign-off")
else:
    d["reconcileStatus"] = "awaiting-reapprove"
    d["awaitingHuman"] = True
    print("reconciled green; awaiting reapprove")
p.write_text(json.dumps(d))
PY
""")
        self.xo = self.repo / "xo.sh"
        self.xo.write_text('#!/bin/bash\nprintf "xo %s\\n" "$*" >> "$LCARS_ECH_CWD/calls"\nprintf "%s\\n" "$PWD" > "$LCARS_ECH_CWD/xo-cwd"\n')
        self.env = dict(os.environ, LCARS_ECH_CWD=str(self.repo),
                        LCARS_APPROVE_SCRIPT=str(self.approve),
                        LCARS_XO_SCRIPT=str(self.xo), LCARS_NOTIFY=str(self.notify),
                        LCARS_ECH_GRANTED_BY="captain", TMPDIR=str(self.repo))
        self.notify.chmod(0o755)
        self.mission("m1")
        self.mission("m2")

    @staticmethod
    def write(path, body):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(body))

    def mission(self, name):
        self.write(self.data / "missions" / name / "state.json",
                   {"id": name, "stage": "verify", "branch": "lcars/" + name})

    def run_ech(self, *args, rc=0):
        result = subprocess.run(["bash", str(SCRIPT), *args], env=self.env,
                                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, text=True, timeout=20,
                                start_new_session=True)
        self.assertEqual(result.returncode, rc, result.stdout)
        return result.stdout

    def record(self):
        return json.loads(self.ap.read_text())

    def decisions(self):
        path = self.data / "decisions.jsonl"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def own_check(self, mission="m1"):
        evidence = self.data / "missions" / mission / "live-check"
        evidence.mkdir(parents=True, exist_ok=True)
        (evidence / "01-cli.txt").write_text("fixture live check: pass\n")
        (evidence / "control.txt").write_text("fixture known-fail control: fail\n")
        targets = ["cli:" + str(n) for n in range(1, 10)]
        rows = [{"id": target, "detector": "inspect fixture product output",
                 "target": {"verdict": "pass", "evidence": str(evidence / "01-cli.txt"),
                            "observation": "product output present"},
                 "control": {"verdict": "fail", "evidence": str(evidence / "control.txt"),
                             "observation": "product output absent",
                             "knownFailure": "missing product output"}} for target in targets]
        self.write(evidence / "checks.json", rows)
        self.run_ech("record", "liveChecks." + mission,
                     json.dumps({"evidence": str(evidence), "types": ["cli"], "targets": targets}))
        self.run_ech("live-check", "done", mission, "--verdict", "pass")
        return evidence

    def test_04_ungranted_reapprove_stops_once_with_four_fields(self):
        for _ in range(2):
            output = self.run_ech("land", "m1", rc=10)
            self.assertIn("ungranted-reapprove", output)
        questions = self.record()["questions"]
        self.assertEqual(len(questions), 1)
        q = next(iter(questions.values()))
        for key in ("what", "why", "command", "rollback"):
            self.assertTrue(q[key], key)
        self.assertIn("--mission m1 --reapprove", q["command"])
        self.assertEqual(self.record()["pending"], q)
        self.assertEqual((self.repo / "pings").read_text().splitlines(), ["ping"])
        self.assertNotIn("--reapprove", self.calls.read_text())
        self.assertFalse(self.decisions())

    def test_05_mission_scope_records_authority_but_refuses_another_mission(self):
        self.own_check("m2")
        self.run_ech("grant", "reapprove", "--mission", "m1", "--once")
        grant = self.record()["grants"][0]
        self.assertEqual(grant["action"], "reapprove")
        self.assertEqual(grant["scope"], "mission")
        self.assertEqual(grant["mission"], "m1")
        self.assertEqual(grant["duration"], "once")
        self.assertEqual(grant["who"], "captain")
        self.assertIsInstance(grant["grantedAt"], int)
        self.assertEqual(grant["runStartedAt"], self.record()["startedAt"])
        self.run_ech("status")
        self.assertEqual(self.record()["grants"][0], grant)
        self.run_ech("land", "m2", rc=10)
        q = self.record()["pending"]
        self.assertEqual(q["mission"], "m2")
        self.assertIn("--mission m2 --reapprove", q["command"])
        self.assertNotIn("--reapprove", self.calls.read_text())
        self.assertFalse([d for d in self.decisions() if d.get("kind") == "granted-action"])
        self.assertNotIn("usedAt", self.record()["grants"][0])

    def test_06a_hand_rolled_gh_pr_merge_is_never_grantable(self):
        before = self.record()
        output = self.run_ech("grant", "gh pr merge", "--mission", "m1", rc=1)
        self.assertIn("action 'gh pr merge' is forbidden", output)
        self.assertEqual(self.record(), before)
        self.assertEqual(self.calls.read_text(), "")
        self.assertIn("A grant never authorises a hand-rolled `gh pr merge`.",
                      PLAYBOOK.read_text())

    def test_06b_permission_classifier_refusal_has_no_second_route(self):
        self.own_check()
        self.run_ech("grant", "reapprove", "--mission", "m1")
        self.write(self.data / "missions/m1/state.json",
                   {"id": "m1", "stage": "verify", "reconcileStatus": "awaiting-reapprove"})
        (self.repo / "refusal").write_text("permission classifier blocked the merge\n")
        self.run_ech("land", "m1", rc=10)
        self.assertEqual(self.calls.read_text().splitlines(), ["--mission m1"])
        self.assertIn("permission classifier blocked", self.record()["pending"]["what"])
        self.assertIn("never-list", self.record()["pending"]["why"])
        self.assertFalse([d for d in self.decisions() if d.get("kind") == "granted-action"])
        self.assertNotIn("usedAt", self.record()["grants"][0])
        self.assertIn("A grant never authorises a second route around a permission-classifier refusal.",
                      PLAYBOOK.read_text())

    def test_06c_lcars_merits_refusal_is_not_overridden_by_a_grant(self):
        self.own_check()
        self.run_ech("grant", "reapprove", "--run")
        self.write(self.data / "missions/m1/state.json",
                   {"id": "m1", "stage": "verify", "reconcileStatus": "awaiting-reapprove"})
        (self.repo / "refusal").write_text("LCARS refused on its merits: failing suite\n")
        self.run_ech("land", "m1", rc=10)
        self.assertEqual(self.calls.read_text().splitlines(), ["--mission m1"])
        self.assertIn("LCARS refused on its merits: failing suite",
                      self.record()["pending"]["what"])
        self.assertIn("never-list", self.record()["pending"]["why"])
        self.assertFalse([d for d in self.decisions() if d.get("kind") == "granted-action"])
        self.assertNotIn("usedAt", self.record()["grants"][0])
        self.assertIn("A grant never authorises a merge LCARS refused on its merits.",
                      PLAYBOOK.read_text())

    def test_02_03_07_granted_reapprove_runs_ledgers_and_never_reasks(self):
        live_evidence = self.own_check()
        self.run_ech("grant", "reapprove", "--mission", "m1")
        grant = self.record()["grants"][0]
        output = self.run_ech("land", "m1")
        self.assertIn("landed m1", output)
        self.assertEqual(self.calls.read_text().splitlines(),
                         ["--mission m1", "--mission m1 --reapprove"])
        entries = [d for d in self.decisions() if d.get("kind") == "granted-action"]
        self.assertEqual(len(entries), 1)
        decision = entries[0]
        self.assertEqual(decision["grant"], grant["id"])
        self.assertEqual(decision["mission"], "m1")
        self.assertEqual(decision["action"], "reapprove")
        self.assertEqual(decision["argv"],
                         ["bash", str(self.approve), "--mission", "m1", "--reapprove"])
        self.assertIn("--mission m1 --reapprove", decision["command"])
        self.assertEqual(decision["output"], "approved with the recorded sign-off")
        self.assertEqual(decision["exitCode"], 0)
        self.assertEqual(Path(decision["evidence"]).read_text().strip(), decision["output"])
        self.assertEqual(decision["liveEvidence"], str(live_evidence))
        self.assertTrue(self.record()["grants"][0]["usedAt"])
        self.assertEqual(self.record()["questions"], {})
        self.assertEqual(self.record()["pending"], {})
        self.assertNotIn("QUESTION FOR THE CAPTAIN", output)
        self.assertFalse((self.repo / "pings").exists())
        self.assertEqual(self.decisions()[-1]["what"], "merged")

    def test_02b_granted_command_executes_in_the_target_checkout(self):
        self.own_check()
        self.run_ech("grant", "reapprove", "--mission", "m1")
        self.run_ech("land", "m1")
        self.assertEqual(Path((self.repo / "approve-cwd").read_text().strip()).resolve(),
                         self.repo.resolve())

    def test_once_grant_is_consumed_even_across_new_seats(self):
        self.own_check()
        self.run_ech("grant", "reapprove")
        self.assertEqual(self.record()["grants"][0]["scope"], "run")
        self.run_ech("land", "m1")
        spent = self.record()["grants"][0]
        self.mission("m1")
        self.run_ech("land", "m1", rc=10)
        self.assertEqual(self.record()["grants"][0], spent)
        self.assertEqual(self.calls.read_text().count("--reapprove"), 1)

    def test_run_grant_can_act_for_two_missions_but_not_a_new_run(self):
        self.run_ech("grant", "reapprove", "--run")
        for mission in ("m1", "m2"):
            self.own_check(mission)
            self.run_ech("land", mission)
        self.assertEqual(self.record()["grants"][0]["uses"], 2)
        self.assertEqual(self.record()["questions"], {})
        self.run_ech("record", "startedAt", "1792800001")
        self.mission("m1")
        self.run_ech("land", "m1", rc=10)
        self.assertEqual(self.record()["grants"][0]["uses"], 2)
        self.assertEqual(self.calls.read_text().count("--reapprove"), 2)

    def test_granted_refusal_is_ledgered_without_retry_or_false_merge(self):
        self.own_check()
        self.run_ech("grant", "reapprove", "--mission", "m1")
        original = self.approve.read_text()
        for rc in (1, 0):
            with self.subTest(reapprove_exit=rc):
                self.mission("m1")
                self.run_ech("grant", "reapprove", "--mission", "m1")
                self.approve.write_text(
                    '#!/bin/bash\nif [ "${3-}" = "--reapprove" ]; then\n'
                    'printf "%s\\n" "$*" >> "$LCARS_ECH_CWD/calls"\n'
                    'echo "LCARS refused reapprove on its merits"\n'
                    f'exit {rc}\nfi\n' + original)
                self.run_ech("land", "m1", rc=10)
                entry = self.decisions()[-1]
                self.assertEqual(entry["kind"], "granted-action")
                self.assertEqual(entry["exitCode"], rc)
                self.assertIn("LCARS refused reapprove on its merits", entry["output"])
                self.assertTrue(Path(entry["evidence"]).is_file())
                self.assertIn("LCARS refused the granted reapprove",
                              self.record()["pending"]["what"])
        self.assertEqual(self.calls.read_text().count("--reapprove"), 2)
        self.assertFalse([d for d in self.decisions() if d.get("what") == "merged"])

    def test_number_one_cannot_replace_own_live_evidence_for_a_grant(self):
        self.run_ech("grant", "reapprove", "--mission", "m1")
        self.write(self.data / "missions/m1/xo/verdict.json", {"verdict": "high"})
        self.run_ech("record", "liveChecks.m1",
                     '{"verdict":"pass","evidence":"/nonexistent-lcars-s315-evidence"}')
        self.run_ech("land", "m1", rc=10)
        self.assertIn("own live check", self.record()["pending"]["what"])
        self.assertNotIn("--reapprove", self.calls.read_text())
        self.assertNotIn("usedAt", self.record()["grants"][0])
        self.own_check()
        self.run_ech("land", "m1")
        self.assertEqual(len(self.record()["questions"]), 1)
        self.assertTrue(self.record()["questions"]["q1"]["answeredAt"])
        self.assertEqual(self.record()["pending"], {})

    def test_legacy_boolean_is_not_a_grant(self):
        self.own_check()
        self.run_ech("record", "preauthorised.manualMergeWhenApproveHitsKnownBug", "true")
        self.run_ech("land", "m1", rc=10)
        self.assertNotIn("--reapprove", self.calls.read_text())

    def test_grant_does_not_clear_an_unrecognised_gate(self):
        self.own_check()
        self.run_ech("grant", "reapprove", "--mission", "m1")
        self.approve.write_text(self.approve.read_text().replace(
            'd["reconcileStatus"] = "awaiting-reapprove"',
            'd["reconcileStatus"] = "merge-failed"'))
        self.run_ech("land", "m1", rc=10)
        self.assertNotIn("--reapprove", self.calls.read_text())
        self.assertNotIn("usedAt", self.record()["grants"][0])

    def test_invalid_grants_do_not_change_authority(self):
        before = self.record()
        for args in (("reapprove", "--mission", "missing"),
                     ("reapprove", "--once", "--run"),
                     ("reapprove", "--mission"),
                     ("please merge anything",)):
            with self.subTest(args=args):
                self.run_ech("grant", *args, rc=1)
                self.assertEqual(self.record(), before)

    def test_08_number_one_preflight_recommends_on_once_without_a_tty(self):
        self.write(self.data / "config.json",
                   {"engine": "claude", "numberOne": {"enabled": False}})
        output = self.run_ech("preflight")
        self.assertIn("proceeding", output)
        self.assertIn("RECOMMENDED: ON", output)
        decision = self.record()["numberOne"]
        self.assertTrue(decision["enabled"])
        self.assertEqual(decision["engine"], "copilot")
        self.assertTrue(decision["settledAt"])
        self.assertTrue(decision["appliedAt"])
        self.run_ech("preflight")
        self.assertEqual(self.calls.read_text().splitlines(),
                         ["xo on --engine copilot --sweep"])
        section = PLAYBOOK.read_text().split("## 1. The alignment round", 1)[1].split("\n## 2.", 1)[0]
        row = next(line for line in section.splitlines() if line.startswith("| 6 |"))
        for text in ("Number One", "RECOMMENDED", "ON", "run", "PROCEEDS"):
            self.assertIn(text, row)

    def test_08b_number_one_applies_to_the_target_checkout(self):
        self.run_ech("preflight")
        self.assertEqual(Path((self.repo / "xo-cwd").read_text().strip()).resolve(),
                         self.repo.resolve())

    def test_number_one_off_and_failed_application_are_persisted(self):
        self.run_ech("record", "numberOne",
                     '{"choice":"off","enabled":false,"engine":"copilot","settledAt":1}')
        original = self.xo.read_text()
        self.xo.write_text('#!/bin/bash\necho "Number One could not apply OFF"\nexit 1\n')
        self.run_ech("preflight", rc=10)
        self.assertFalse(self.record()["numberOne"]["enabled"])
        self.assertNotIn("appliedAt", self.record()["numberOne"])
        self.assertIn("Number One", self.record()["pending"]["why"])
        self.xo.write_text(original)
        self.run_ech("preflight")
        self.run_ech("preflight")
        self.assertEqual(self.calls.read_text().splitlines(), ["xo off"])
        self.assertEqual(self.record()["pending"], {})
        self.assertEqual(len(self.record()["questions"]), 1)

    def test_09_merge_policy_and_landing_agree_that_a_grant_acts(self):
        text = PLAYBOOK.read_text()
        policy = text.split("## 6a. The merge policy", 1)[1].split("\n## 7.", 1)[0]
        landing = text.split("## 7. Land it", 1)[1].split("\n## 8.", 1)[0]
        for section in (policy, landing):
            self.assertIn("A grant acts, and is ledgered.", section)
            self.assertIn("An ungranted refusal raises one pre-staged question and stops that milestone.",
                          section)
        for contradiction in ("the mode never gives it", "the question still gets",
                              "His OK is what runs it, not the pre-authorisation alone"):
            self.assertNotIn(contradiction, landing)
        self.assertIn("The hologram's own live check is REQUIRED before every merge.", policy)
        self.assertIn("Number One's recommendation is not a substitute for having looked.", policy)


if __name__ == "__main__":
    unittest.main()

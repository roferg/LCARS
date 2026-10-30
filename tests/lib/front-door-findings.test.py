"""S323 locks OF5/OF6/OF1/OF3 at the front doors that produced the findings."""
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
from urllib.error import HTTPError


ROOT = Path(__file__).resolve().parents[2]  # tests/lib/<file> -> repo root
RUN = ROOT / "skills/lcars-run/run.sh"
ECH = ROOT / "skills/lcars-eeh/ech.sh"
QUESTION = "Should the palette also open from a mission card?"
QUESTIONS = "## Open questions from the design session\n\n"
PRD = ("# Mission: Palette\n\n**Type:** feature\n\n## Goal\n\nBuild a palette.\n\n"
       "## Acceptance Criteria\n\n- The palette opens.\n\n"
       "## Out of Scope\n\n- Other controls.\n\n## Constraints\n\n- Reuse the router.\n\n")
sys.path.insert(0, str(ROOT / "web"))
from tests.test_holodeck_endpoints import HandoffBase


class FrontDoor(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="lcars-s323-")
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)
        self.repo = self.home / "repo"
        self.repo.mkdir()
        self.bin = self.home / "bin"
        self.bin.mkdir()
        self.env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
                        LCARS_VERSION_CHECK="0", LCARS_HOLODECK_HANDOFF_CHECK="0",
                        LCARS_WORKER_CLI="copilot", LCARS_WORKER_HANG_SECS="0",
                        LCARS_WORKER_TRIES="1", LCARS_ECH_CWD=str(self.repo))
        self.command("git", "init", "-qb", "main")
        self.command("git", "config", "user.email", "test@example.invalid")
        self.command("git", "config", "user.name", "Test")
        (self.repo / "CONTEXT.md").write_text("# Fixture\n")
        self.command("git", "add", ".")
        self.command("git", "commit", "-qm", "fixture")
        self.data = self.repo / ".git/lcars"
        self.data.mkdir()
        self.write(self.data / "config.json", {"testCommand": "true", "engine": "copilot",
                                              "numberOne": {"enabled": False}})
        # Fence both engine names; only an explicitly injected adapter may run.
        for name in ("copilot", "claude"):
            self.executable(name, '#!/bin/sh\necho FENCE >&2\nexit 97\n')
        self.env["LCARS_WORKER_BIN"] = str(self.bin / "copilot")
        self.env["LCARS_COPILOT_BIN"] = str(self.bin / "copilot")
        self.env["LCARS_CLAUDE_BIN"] = str(self.bin / "claude")
        self.env["LCARS_GH_BIN"] = str(self.executable("gh", "#!/bin/sh\nexit 0\n"))

    @staticmethod
    def write(path, value):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(value, indent=2) + "\n")

    def executable(self, name, text):
        path = self.bin / name
        path.write_text(text)
        path.chmod(0o755)
        return path

    def command(self, *args, rc=0):
        proc = subprocess.run(args, cwd=self.repo, env=self.env, text=True,
                              stdin=subprocess.DEVNULL, capture_output=True, timeout=40)
        output = proc.stdout + proc.stderr
        self.assertNotIn("FENCE", output, output)
        if rc is not None:
            self.assertEqual(proc.returncode, rc, output)
        return proc

    def plan(self, entries=None, mission=None):
        if mission is None:
            mission = self.data / "missions/m-001"
            self.write(mission / "state.json", {
                "id": "m-001", "type": "feature", "title": "Palette",
                "stage": "plan", "branch": "main", "base": "main", "githubIssue": None})
            (mission / "prd.md").write_text("# Palette\n\n" + QUESTIONS + entries)
        else:
            state = json.loads((mission / "state.json").read_text())
            state.update(stage="plan", githubIssue=None)
            self.write(mission / "state.json", state)
        (mission / "validated-plan.md").write_text("# Validated\n\nBuild the palette.\n")
        plan = self.home / "plan.json"
        self.write(plan, [{
            "id": "t-001", "title": "Palette", "description": "Build the palette.",
            "acceptanceCriteria": [{"text": "The palette opens.",
                                    "drawnAt": "the Command palette heading"}],
            "changesScreenAppearance": True, "dependencies": [],
            "estimatedReadLoc": 10, "estimatedTestLoc": 10, "estimatedNewLoc": 10,
            "establishesSharedInfrastructure": False, "rationale": "One behavior."}])
        self.env["LCARS_WORKER_ADAPTER"] = str(self.executable("adapter", """#!/bin/sh
[ "$1" = spawn ] || exit 0
printf '%s\\n' "$5" > "$S323_PROMPT"
cp "$S323_PLAN" "$4/plan.json"
"""))
        prompt = self.home / "prompt"
        prompt.unlink(missing_ok=True)
        self.env.update(S323_PROMPT=str(prompt), S323_PLAN=str(plan))
        proc = self.command("bash", str(RUN), "plan", "--mission", mission.name, rc=None)
        print("OF5 real Plan rc=%s\n%s" % (
            proc.returncode, proc.stdout + proc.stderr), flush=True)
        return proc, prompt, mission

    def filing_env(self):
        self.env["LCARS_GH_BIN"] = str(self.executable("filing-gh", """#!/bin/sh
if [ "$1 $2" = 'issue create' ]; then
 echo https://github.com/owner/repo/issues/314
fi
"""))
        self.env["LCARS_RUN_BIN"] = str(self.executable("estimate", "#!/bin/sh\nexit 0\n"))

    def file_prd(self, text, concept=None):
        self.filing_env()
        prd = self.home / "prd.md"
        prd.write_text(text)
        args = ["bash", str(ROOT / "skills/lcars-file/file.sh"),
                "--prd", str(prd), "--engine", "copilot"]
        if concept is not None:
            attachment = self.home / "concept.md"
            attachment.write_text(concept)
            args += ["--attach", str(attachment)]
        before = set((self.data / "missions").glob("*"))
        proc = self.command(*args, rc=None)
        after = set((self.data / "missions").glob("*"))
        print("real CLI filing rc=%s\n%s" % (
            proc.returncode, proc.stdout + proc.stderr), flush=True)
        return proc, next(iter(after - before), None)

    def file_http(self, idea, concept=None):
        case = HandoffBase()
        case.setUp()
        self.addCleanup(case.doCleanups)
        self.addCleanup(case.tearDown)
        self.repo = Path(case.repo)
        self.data = self.repo / ".git/lcars"
        self.env["LCARS_ECH_CWD"] = str(self.repo)
        self.command("git", "init", "-qb", "main")
        self.command("git", "config", "user.email", "test@example.invalid")
        self.command("git", "config", "user.name", "Test")
        self.command("git", "add", "board.css")
        self.command("git", "commit", "-qm", "fixture")
        self.write(self.data / "config.json", {"testCommand": "true", "engine": "copilot",
                                              "numberOne": {"enabled": False}})
        self.filing_env()
        case.actions.scripts["file"] = str(ROOT / "skills/lcars-file/file.sh")
        before = set((self.data / "missions").iterdir())
        payload = {"idea": idea, "engine": "copilot"}
        with patch.dict(os.environ, self.env):
            if concept is not None:
                case.CONCEPT = concept
                payload["holodeck"] = case._program()
            try:
                status, body = case._post("/api/mission", payload)
            except HTTPError as error:
                with error:
                    status, body = error.code, json.load(error)
        after = set((self.data / "missions").iterdir())
        print("real HTTP filing status=%s\n%s" % (
            status, body if status != 200 else "filed"), flush=True)
        return status, body, next(iter(after - before), None)

    def test_N1_native_http_template_reaches_plan(self):
        for marker in ("STILL OPEN: ", "RESOLVED with the captain: "):
            with self.subTest(marker=marker):
                entry = marker + QUESTION
                if marker.startswith("RESOLVED"):
                    entry += " - DECIDED: no."
                status, body, mission = self.file_http(
                    "Build a palette.\n\n" + QUESTIONS + "- " + entry + "\n")
                self.assertEqual(status, 200, body)
                self.assertIn("**Acceptance Criteria:**", (mission / "prd.md").read_text())
                proc, prompt, _ = self.plan(mission=mission)
                self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
                self.assertEqual("  1. " + QUESTION in prompt.read_text(),
                                 marker.startswith("STILL OPEN"))
                self.assertEqual(json.loads((mission / "state.json").read_text())["stage"],
                                 "plan-review")

    def test_N2_bold_question_label_cannot_hide_source_question(self):
        source = ("## WHAT IT MUST DO\n\n"
                  "### 2. Implied by the mockup, not yet settled\n\n"
                  "**Question:**\n\n- " + QUESTION + "\n")
        proc, mission = self.file_prd(PRD, source)
        self.assertEqual(proc.returncode, 3, proc.stdout + proc.stderr)
        self.assertIsNone(mission, "refusal minted a mission")
        self.assertIn(QUESTION, proc.stderr)
        # The same source must also allow a properly declared persisted PRD into Plan.
        proc, mission = self.file_prd(PRD + QUESTIONS + "- STILL OPEN: " + QUESTION + "\n",
                                      source)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        proc, prompt, _ = self.plan(mission=mission)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn("  1. " + QUESTION, prompt.read_text())

    def test_N3_known_source_question_cannot_silently_disappear_at_plan(self):
        source = "## Open questions\n\n- " + QUESTION + "\n"
        for prefix in ("", "> ", "\u2014 "):
            with self.subTest(prefix=prefix):
                proc, mission = self.file_prd(PRD + QUESTIONS + prefix + QUESTION + "\n",
                                              source)
                if proc.returncode:
                    self.assertEqual(proc.returncode, 3, proc.stdout + proc.stderr)
                    self.assertIsNone(mission)
                    continue
                proc, prompt, _ = self.plan(mission=mission)
                if proc.returncode:
                    self.assertFalse(prompt.exists())
                    self.assertIn(QUESTION, proc.stderr)
                else:
                    self.assertTrue("  1. " + QUESTION in prompt.read_text(),
                                    "Plan silently lost a known source question")

    def test_N4_unindented_soft_wrap_survives_filing_and_plan(self):
        proc, mission = self.file_prd(
            PRD + QUESTIONS + "- STILL OPEN: Should the palette also open\n"
            "from a mission card?\n", "## Open questions\n\n- " + QUESTION + "\n")
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        proc, prompt, _ = self.plan(mission=mission)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertTrue("  1. " + QUESTION + "\n" in prompt.read_text(),
                        "Plan truncated the soft-wrapped question")

    def test_N5_fenced_example_cannot_suppress_real_http_handoff(self):
        idea = ("Build a palette. Documentation example only:\n\n```markdown\n" + QUESTIONS
                + "- RESOLVED with the captain: " + QUESTION + " - DECIDED: no.\n```\n")
        status, body, mission = self.file_http(idea, "## Open questions\n\n- " + QUESTION + "\n")
        self.assertEqual(status, 200, body)
        self.assertIsNotNone(mission, "accepted hand-off did not mint a mission")
        prd = (mission / "prd.md").read_text()
        declarations = re.sub(r"(?ms)^```[^\n]*\n.*?^```[ \t]*(?:\n|$)", "", prd)
        self.assertEqual(len(re.findall(
            r"(?m)^## Open questions from the design session[ \t]*$", declarations)), 1, prd)
        proc, prompt, _ = self.plan(mission=mission)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertTrue("  1. " + QUESTION in prompt.read_text(),
                        "documentation example replaced the real unanswered handoff")
        self.assertEqual(json.loads((mission / "state.json").read_text())["stage"],
                         "plan-review")

    def test_fenced_source_example_without_attachment_files_through_cli(self):
        for fence in ("```", "~~~"):
            with self.subTest(fence=fence):
                proc, mission = self.file_prd(
                    PRD + "Documentation example only:\n\n" + fence + "markdown\n"
                    "## Open questions\n\n- Is this example syntax correct?\n" + fence + "\n")
                self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
                self.assertIsNotNone(mission)
                proc, prompt, _ = self.plan(mission=mission)
                self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
                self.assertNotIn(
                    "## The brief left these questions OPEN", prompt.read_text())
                self.assertNotIn("  1. Is this example syntax correct?", prompt.read_text())
                self.assertEqual(json.loads((mission / "state.json").read_text())["stage"],
                                 "plan-review")

    def test_fenced_source_example_without_attachment_files_through_http(self):
        for fence in ("```", "~~~"):
            with self.subTest(fence=fence):
                status, body, mission = self.file_http(
                    "Build a palette. Documentation example only:\n\n" + fence + "markdown\n"
                    "## Open questions\n\n- Is this example syntax correct?\n" + fence + "\n")
                self.assertEqual(status, 200, body)
                self.assertIsNotNone(mission)
                proc, prompt, _ = self.plan(mission=mission)
                self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
                self.assertNotIn(
                    "## The brief left these questions OPEN", prompt.read_text())
                self.assertNotIn("  1. Is this example syntax correct?", prompt.read_text())
                self.assertEqual(json.loads((mission / "state.json").read_text())["stage"],
                                 "plan-review")

    def test_OF5_three_measured_plan_variants(self):
        bullets = "".join("- RESOLVED with the captain: Question %d? - DECIDED: yes.\n"
                          % n for n in range(1, 7))
        prose = "These questions were answered with the captain during Align.\n\n"
        for name, entries, still_open in (
                ("six resolved plus prose", prose + bullets, False),
                ("six resolved without prose", bullets, False),
                ("prose and one still open", prose + bullets.replace(
                    "RESOLVED with the captain: Question 1? - DECIDED: yes.",
                    "STILL OPEN: Question 1?"), True)):
            with self.subTest(variant=name):
                proc, prompt, mission = self.plan(entries)
                self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
                self.assertEqual(json.loads((mission / "state.json").read_text())["stage"],
                                 "plan-review")
                self.assertTrue(prompt.exists(), "real Plan never reached its worker")
                self.assertEqual("  1. Question 1?" in prompt.read_text(), still_open)

    def test_OF5_refusal_counts_declared_bullets_not_prose(self):
        entries = "This is explanatory prose, not an entry.\n\n" + "".join(
            "- RESOLVED with the captain: Question %d? - DECIDED: yes.\n" % n
            for n in range(1, 7)) + "- Which colour?\n"
        proc, prompt, _ = self.plan(entries)
        self.assertNotEqual(proc.returncode, 0)
        self.assertFalse(prompt.exists())
        self.assertIn("6 of 7", proc.stderr)
        self.assertIn("Which colour?", proc.stderr)
        self.assertNotIn("NOT ONE", proc.stderr)

    def test_OF5_prose_does_not_become_part_of_a_wrapped_question_or_decision(self):
        proc, prompt, mission = self.plan(
            "- STILL OPEN: Should the palette open\n  from a mission card?\n\n"
            "This prose is not part of that question.\n\n"
            "- RESOLVED with the captain: Keep the\n  keyboard shortcut? - DECIDED: yes.\n\n"
            "This prose is not part of that decision.\n")
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn("  1. Should the palette open from a mission card?", prompt.read_text())
        self.assertNotIn("This prose", prompt.read_text())
        self.env["LCARS_ATT_TEST_DIR"] = str(mission)
        decisions = self.command("bash", str(RUN), "resolved-decisions-test")
        self.assertEqual(decisions.stdout,
                         "Keep the keyboard shortcut? - DECIDED: yes.\n")

    def test_OF6_three_filing_attempts_through_http_and_real_file(self):
        question = "Should the palette also open from a mission card?"
        concept = ("# Palette\n\n## Open questions\n\n- " + question +
                   "\n\n## WHAT IT MUST DO\n\n"
                   "### 2. Implied by the mockup, not yet settled\n\n- " + question + "\n")
        declared = ("## Open questions from the design session\n\n"
                    "- RESOLVED with the captain: " + question + " - DECIDED: no.\n")
        for name, idea, use_holodeck, expected in (
                ("1 correct section must not be duplicated",
                 "Build the palette.\n\n" + declared, True, 200),
                ("2 deleting the demanded section must refuse",
                 "Build the palette.\n\n" + concept, False, 502),
                ("3 issue 314 implied item without section must refuse",
                 "Build the palette.\n\n## Implied by the mockup - NOT things you said\n\n"
                 "- " + question + "\n\n## Hand-off contract\n\n"
                 "Every item here has to reach the Mission's PRD under "
                 "`## Open questions from the design session`. Filing REFUSES a PRD "
                 "that drops any of them.\n", False, 502)):
            with self.subTest(attempt=name):
                case = HandoffBase()
                case.setUp()
                try:
                    repo = Path(case.repo)
                    subprocess.run(["git", "init", "-qb", "main", str(repo)], check=True)
                    self.write(repo / ".git/lcars/config.json", {
                        "testCommand": "true", "workerBin": "copilot",
                        "numberOne": {"enabled": False}})
                    forge = self.executable("filing-gh", """#!/bin/sh
echo "$*" >> "$S323_FORGE"
if [ "$1 $2" = 'issue create' ]; then
 echo https://github.com/owner/repo/issues/314
fi
""")
                    estimator = self.executable("estimate", "#!/bin/sh\nexit 0\n")
                    env = dict(self.env, LCARS_GH_BIN=str(forge),
                               LCARS_RUN_BIN=str(estimator),
                               S323_FORGE=str(self.home / "forge.log"))
                    case.actions.scripts["file"] = str(ROOT / "skills/lcars-file/file.sh")
                    payload = {"idea": idea, "engine": "copilot"}
                    before = set((repo / ".git/lcars/missions").iterdir())
                    forge_log = self.home / "forge.log"
                    forge_log.unlink(missing_ok=True)
                    with patch.dict(os.environ, env):
                        if use_holodeck:
                            case.CONCEPT = concept
                            payload["holodeck"] = case._program()
                        try:
                            status, body = case._post("/api/mission", payload)
                        except HTTPError as error:
                            with error:
                                status, body = error.code, json.load(error)
                    print("OF6 %s HTTP %s\n%s" % (
                        name, status, body if status != 200 else "filed"), flush=True)
                    after = set((repo / ".git/lcars/missions").iterdir())
                    self.assertEqual(status, expected, str(body) if status != 200 else "filed")
                    if expected == 200:
                        self.assertEqual(len(after - before), 1)
                        mission = (after - before).pop()
                        prd = (mission / "prd.md").read_text()
                        self.assertEqual(prd.count(
                            "\n## Open questions from the design session\n"), 1, prd)
                        self.assertIn("- RESOLVED with the captain: " + question, prd)
                        self.assertNotIn("\n- STILL OPEN:", prd)
                        self.assertIn("issue create", forge_log.read_text())
                    else:
                        self.assertEqual(after, before, "refusal minted a mission")
                        self.assertFalse(forge_log.exists(), "refusal reached the forge")
                        self.assertIn("Open questions from the design session", str(body))
                        self.assertIn(question, str(body))
                        self.assertIn("left 1 question(s)", str(body))
                finally:
                    case.tearDown()
                    case.doCleanups()

    def test_OF1_ech_init_uninitialized_repo_names_recovery_command(self):
        (self.data / "config.json").unlink()
        proc = self.command("bash", str(ECH), "init", "--spec", "spec.md",
                            "--scope", "M0", "--engine", "copilot", rc=10)
        output = proc.stdout + proc.stderr
        print("OF1 real ECH init rc=%s\n%s" % (proc.returncode, output), flush=True)
        self.assertIn("6. Number One", output)
        self.assertIn("lcars init", output)
        self.assertIn("lcars-ech preflight", output)
        self.assertFalse((self.data / "config.json").exists())
        state = json.loads((self.data / "autopilot.json").read_text())
        self.assertEqual(state["numberOne"]["choice"], "on")
        self.assertNotIn("appliedAt", state["numberOne"])
        questions = [q for q in state["questions"].values()
                     if "Number One" in q.get("why", "")]
        self.assertEqual(len(questions), 1, state["questions"])
        self.assertIn("lcars init", questions[0]["why"])
        init = ROOT / "skills/lcars-init/init.sh"
        self.assertEqual(questions[0]["command"], "bash %s && lcars-ech preflight" % init)
        self.executable("copilot", """#!/bin/sh
if [ "$1" = --version ]; then echo 'GitHub Copilot CLI 1.0.103'; exit 0; fi
echo FENCE >&2
exit 97
""")
        self.command("bash", str(init))
        self.command("bash", str(ECH), "record", "push.mode", "local-only")
        self.command("bash", str(ECH), "preflight")
        self.assertTrue(json.loads((self.data / "config.json").read_text())[
            "numberOne"]["enabled"])
        self.assertIn("appliedAt", json.loads(
            (self.data / "autopilot.json").read_text())["numberOne"])

    def test_OF6_parked_idea_questions_cannot_evaporate_during_align(self):
        question = "Should the palette open from a mission card?"
        idea = self.home / "idea.md"
        idea.write_text("Build the palette.\n\n"
                        "## Implied by the mockup - NOT things you said\n\n- " + question)
        self.env["LCARS_GH_BIN"] = str(self.executable("filing-gh", """#!/bin/sh
if [ "$1 $2" = 'issue create' ]; then
 echo https://github.com/owner/repo/issues/314
fi
"""))
        self.env["LCARS_RUN_BIN"] = str(self.executable("estimate", "#!/bin/sh\nexit 0\n"))
        file_script = ROOT / "skills/lcars-file/file.sh"
        self.command("bash", str(file_script), "--park", "--idea", str(idea))
        mission, = (self.data / "missions").iterdir()
        prd = self.home / "prd.md"
        prd.write_text("# Mission: Palette\n\n**Type:** feature\n\n## Goal\n\n"
                       "Build the palette.\n\n## Acceptance Criteria\n\n- It opens.\n\n"
                       "## Out of Scope\n\n- Other controls.\n\n## Constraints\n\n- Reuse.\n")
        before = (mission / "state.json").read_bytes()
        refused = self.command("bash", str(file_script), "--complete", mission.name,
                                "--prd", str(prd), rc=None)
        print("OF6 park -> Align drops source questions rc=%s\n%s" % (
            refused.returncode, refused.stdout + refused.stderr), flush=True)
        self.assertEqual(refused.returncode, 3, refused.stdout + refused.stderr)
        self.assertIn(question, refused.stderr)
        self.assertEqual((mission / "state.json").read_bytes(), before)
        self.assertFalse((mission / "prd.md").exists())
        with prd.open("a") as stream:
            stream.write("\n## Open questions from the design session\n\n"
                         "- RESOLVED with the captain: " + question + " - DECIDED: no.\n")
        self.command("bash", str(file_script), "--complete", mission.name, "--prd", str(prd))
        self.assertIn(question, (mission / "prd.md").read_text())

    def test_OF3_after_merge_step_does_not_park_first_filing(self):
        self.write(self.data / "autopilot.json", {
            "scope": ["M0"], "missions": {}, "drivers": {}, "questions": {},
            "pending": {}, "push": {"mode": "local-only"}, "testCommand": "true"})
        step = {"what": "Publish the release", "instructions": "Publish after merge",
                "neededBy": "after M0 merges", "done": False}
        self.command("bash", str(ECH), "record", "captainOnlySteps", json.dumps([step]))
        proc = self.command("bash", str(ECH), "next")
        print("OF3 after recording after-merge step, before filing:\n" + proc.stdout,
              flush=True)
        self.assertIn("NEXT: file M0", proc.stdout)
        self.assertNotIn("NEXT: captain-step", proc.stdout)
        status = self.command("bash", str(ECH), "status").stdout
        self.assertIn("after M0 merges", status)
        self.command("bash", str(ECH), "record", "missions.M0.id", "m0")
        state = self.data / "missions/m0/state.json"
        self.write(state, {"id": "m0", "stage": "verify"})
        self.assertIn("NEXT: verify-gate m0", self.command(
            "bash", str(ECH), "next").stdout)
        self.write(state, {"id": "m0", "stage": "done"})
        due = self.command("bash", str(ECH), "next").stdout
        self.assertIn("NEXT: captain-step", due)
        self.assertIn("Publish the release", due)
        self.assertFalse(json.loads((self.data / "autopilot.json").read_text())[
            "captainOnlySteps"][0]["done"])
        for outcome in ({"done": True}, {"declined": True, "declinedReason": "Not releasing"}):
            self.command("bash", str(ECH), "record", "captainOnlySteps",
                         json.dumps([dict(step, **outcome)]))
            self.assertIn("NEXT: done", self.command("bash", str(ECH), "next").stdout)

    def test_OF3_unreadable_deadline_refuses_before_recording(self):
        self.write(self.data / "autopilot.json", {
            "scope": ["M0"], "missions": {}, "questions": {}, "captainOnlySteps": []})
        for needed in ("sometime later", "after M9 merges"):
            with self.subTest(neededBy=needed):
                before = (self.data / "autopilot.json").read_bytes()
                proc = self.command("bash", str(ECH), "record", "captainOnlySteps",
                                    json.dumps([{"what": "Release", "neededBy": needed,
                                                 "done": False}]), rc=None)
                print("OF3 invalid neededBy rc=%s\n%s" % (
                    proc.returncode, proc.stdout + proc.stderr), flush=True)
                self.assertNotEqual(proc.returncode, 0)
                self.assertIn("neededBy", proc.stderr)
                self.assertIn("lcars-ech record captainOnlySteps", proc.stderr)
                self.assertEqual((self.data / "autopilot.json").read_bytes(), before)


if __name__ == "__main__":
    unittest.main(verbosity=2)

"""S373: real pre-filing decisions; the ECH's semantic judgement is supplied, not simulated."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[2]
BASE = "d1da5ad5482b6688590001819c09f403006c6dfa"
spec = importlib.util.spec_from_file_location("handoff", ROOT / "tests/lib/chunk-handoff.test.py")
handoff = importlib.util.module_from_spec(spec)
spec.loader.exec_module(handoff)


class ChunkingDecision(unittest.TestCase):
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

    def ready_to_file(self):
        self.succeeds(self.ech("record", "chunkingBaseline", "[]"))

    def decide(self, chunks, trigger, why):
        return self.ech("chunking", "--chunks", str(chunks),
                        "--trigger", trigger, "--why", why)

    def test_pair_records_split_and_single_slice_before_real_filing(self):
        self.ready_to_file()
        (self.repo / "app.py").write_text("def heading(river):\n    return 'River'\n")
        (self.repo / "model.py").write_text("river = {'name': 'Nile', 'level': 1}\n")
        self.git("add", "app.py", "model.py")
        self.git("commit", "-qm", "existing shared river modules")
        cases = [
            ("""# River simulation
Five independently acceptable features:
1. Fish follow changing water levels (app.py, model.py).
2. Flood warnings use those levels (app.py, model.py).
3. Habitat survives a saved-game reload (app.py, model.py, storage.py).
4. A water-level slider updates the simulation (app.py, model.py).
5. Reset restores the initial river (app.py, model.py, storage.py).
The features collide in app.py and model.py; sequence their shared-file edits.
""", 5, "unit-of-work",
             "Five separately acceptable behaviours do not fit one unit of work; shared app.py and model.py edits require sequencing, not one undivided chunk."),
            ("""# River label
When a saved river has a name, show that name in its existing heading.
Change the existing heading renderer and its assertion in app.py only.
No new workflow, persistence behaviour, module or independent delivery.
""", 1, "none",
             "One existing heading and its assertion form a single estimable slice; no module boundary, useful parallelism or independence requirement warrants a split."),
        ]
        for text, count, trigger, why in cases:
            with self.subTest(chunks=count):
                (self.repo / "spec.md").write_text(text)
                # The AI is outside this proof surface: these are declared ECH judgements.
                output = self.succeeds(self.decide(count, trigger, why))
                record = self.ap()["chunking"]
                self.assertEqual(record["chunks"], count)
                self.assertEqual(record["trigger"], trigger)
                self.assertEqual(record["why"], why)
                self.assertEqual(record["spec"], "spec.md")
                self.assertIsInstance(record["at"], int)
                self.assertIn("CHUNKS: " + str(count), output)
                self.assertIn("TRIGGER: " + trigger, output)
                self.assertIn("WHY: " + why, output)
                self.assertFalse(list((self.data / "missions").glob("*/state.json")))
                print("RECORDED DECISION: " + json.dumps(record, sort_keys=True), flush=True)
        ledger = self.ap()["chunkingLedger"]
        self.assertEqual([v["chunks"] for v in ledger.values()], [5, 1])
        self.assertEqual([v["why"] for v in ledger.values()], [c[3] for c in cases])
        result = self.ech("exec", "lcars-file/file.sh", "--prd", str(self.prd))
        self.succeeds(result)
        self.assertEqual(len(list((self.data / "missions").glob("*/state.json"))), 1)

    def test_next_stops_at_the_decision_before_offering_file(self):
        self.ready_to_file()
        before = (self.data / "autopilot.json").read_bytes()
        output = self.succeeds(self.ech("next", "--all"))
        self.assertIn("NEXT: chunking", output)
        self.assertIn("--chunks", output)
        self.assertIn("--trigger", output)
        self.assertIn("--why", output)
        self.assertNotIn("NEXT: file", output)
        self.assertNotIn("NEXT: holodeck", output)
        self.assertNotIn("PLAN (in order):", output)
        self.assertEqual((self.data / "autopilot.json").read_bytes(), before)
        self.succeeds(self.decide(1, "none", "One existing heading is one slice."))
        after = self.succeeds(self.ech("next", "--all"))
        self.assertIn("NEXT: file", after)
        self.assertNotIn("NEXT: chunking", after)

    def test_only_the_five_declared_triggers_and_explicit_one_chunk_are_accepted(self):
        for trigger in ("not-estimable", "unit-of-work", "module-boundary",
                        "parallelism", "independence"):
            with self.subTest(trigger=trigger):
                self.succeeds(self.decide(2, trigger, "The declared axis applies to this work."))
                self.assertEqual(self.ap()["chunking"]["trigger"], trigger)
        self.succeeds(self.decide(1, "none", "One estimable slice needs no split."))
        before = (self.data / "autopilot.json").read_bytes()
        for count, trigger in ((2, "size"), (2, "large"), (2, "unknown"),
                               (2, "none"), (1, "parallelism")):
            with self.subTest(chunks=count, trigger=trigger):
                result = self.decide(count, trigger, "A reason cannot legitimise this trigger.")
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertIn("chunking:", result.stdout)
                self.assertEqual((self.data / "autopilot.json").read_bytes(), before)

    def test_reason_is_required_for_both_answers_and_refusals_write_nothing(self):
        for count, trigger in ((1, "none"), (2, "not-estimable")):
            for why in (None, "", " \t\r\n", "a reason\nanother line", "a reason\n"):
                with self.subTest(chunks=count, why=why):
                    before = (self.data / "autopilot.json").read_bytes()
                    args = ["chunking", "--chunks", str(count), "--trigger", trigger]
                    if why is not None:
                        args += ["--why", why]
                    result = self.ech(*args)
                    self.assertNotEqual(result.returncode, 0, result.stdout)
                    self.assertIn("--why", result.stdout)
                    self.assertEqual((self.data / "autopilot.json").read_bytes(), before)

    def test_count_is_positive_and_invalid_arguments_terminate_without_writing(self):
        for args in ([], ["--chunks"], ["--chunks", "1.5"], ["--chunks", "two"], ["--why"],
                     ["--trigger"], ["--unknown", "yes"]):
            with self.subTest(args=args):
                before = (self.data / "autopilot.json").read_bytes()
                result = self.ech("chunking", *args)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertIn("chunking:", result.stdout)
                self.assertEqual((self.data / "autopilot.json").read_bytes(), before)
        for count in ("0", "-1"):
            before = (self.data / "autopilot.json").read_bytes()
            result = self.decide(count, "parallelism", "These could run independently.")
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertIn("--chunks", result.stdout)
            self.assertEqual((self.data / "autopilot.json").read_bytes(), before)

    def test_decision_is_not_backfilled_after_a_mission_exists(self):
        self.write(self.data / "missions/m-existing/state.json",
                   {"id": "m-existing", "stage": "research"})
        before = (self.data / "autopilot.json").read_bytes()
        result = self.decide(1, "none", "This would be a retrospective judgement.")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("before", result.stdout.lower())
        self.assertEqual((self.data / "autopilot.json").read_bytes(), before)

    def test_new_run_still_decides_when_the_repo_has_older_missions(self):
        self.write(self.data / "missions/m-older/state.json",
                   {"id": "m-older", "stage": "done"})
        result = self.ech("init", "--force", "--spec", "spec.md",
                          "--scope", "fish", "--engine", "copilot")
        self.assertIn(result.returncode, (0, 10), result.stdout)
        self.assertEqual(self.ap()["chunkingBaseline"], ["m-older"])
        for key in self.ap().get("questions", {}):
            self.succeeds(self.ech("answered", key, "Local test run; no remote required."))
        output = self.succeeds(self.ech("next"))
        self.assertIn("NEXT: chunking", output)
        self.succeeds(self.decide(1, "none", "One new slice, unrelated to the older Mission."))
        self.assertEqual(self.ap()["chunking"]["chunks"], 1)

    def test_docs_put_the_decision_before_filing_and_define_the_axes(self):
        doc = (self.skills / "lcars-eeh/DELEGATION.md").read_text()
        section = doc.split("## THE CHUNKING DECISION", 1)[1].split("\n## ", 1)[0]
        for term in ("NOT ESTIMABLE", "spike", "DOES NOT FIT ONE UNIT OF WORK",
                     "CROSSES A MODULE BOUNDARY", "PARALLELISM WORTH HAVING",
                     "INDEPENDENCE REQUIRED", "Size-as-proxy", "not a trigger",
                     "ONE CHUNK", "--why", "before any Mission"):
            self.assertIn(term, section)
        playbook = (self.skills / "lcars-eeh/HOLOGRAM-COMMAND-MODE.md").read_text()
        filing = playbook.split("## 4. File a milestone through the front door", 1)[1]
        self.assertIn("CHUNKING DECISION FIRST", filing)
        self.assertLess(filing.index("CHUNKING DECISION"), filing.index("file.sh"))

    def test_single_chunk_without_validator_is_byte_identical_from_the_base(self):
        baseline = self.repo / "baseline-skills"
        shutil.copytree(self.skills, baseline)
        old = subprocess.run(["git", "show", BASE + ":skills/lcars-eeh/ech.sh"],
                             cwd=ROOT, check=True, capture_output=True, text=True).stdout
        (baseline / "lcars-eeh/ech.sh").write_text(old)
        date = self.bin / "date"
        date.write_text('#!/bin/bash\nif [ "$*" = "+%s" ]; then echo 1800000000; '
                        'else exec /bin/date "$@"; fi\n')
        date.chmod(0o755)
        self.ready_to_file()
        self.succeeds(self.decide(1, "none", "One existing heading is one slice."))
        current = self.skills
        saved = (self.data / "autopilot.json").read_bytes()

        def capture(skills):
            self.skills = skills
            result = {"next": self.succeeds(self.ech("next", "--all"))}
            result["tier"] = self.succeeds(self.ech(
                "tier", "fish", "--tier", "T1", "--why", "one owned slice"))
            result["mint"] = self.succeeds(self.ech("delegate", "fish"))
            result["brief"] = (self.data / "delegates/d1/BRIEF.md").read_text()
            result["record"] = (self.data / "autopilot.json").read_text()
            for verb in ("delegates", "status", "stalled"):
                result[verb] = self.succeeds(self.ech(verb))
            return {k: v.replace(str(skills), "<SKILLS>") for k, v in result.items()}

        try:
            before = capture(baseline)
            shutil.rmtree(self.data / "delegates/d1")
            (self.data / "autopilot.json").write_bytes(saved)
            after = capture(current)
        finally:
            self.skills = current
        self.assertIn("NEXT: file", before["next"])
        self.assertIn("MINTED: d1", before["mint"])
        for surface in before:
            with self.subTest(surface=surface):
                self.assertEqual(after[surface], before[surface])

    def test_legacy_main_ech_next_is_unchanged_without_a_decision(self):
        baseline = self.repo / "baseline-skills"
        shutil.copytree(self.skills, baseline)
        old = subprocess.run(["git", "show", BASE + ":skills/lcars-eeh/ech.sh"],
                             cwd=ROOT, check=True, capture_output=True, text=True).stdout
        (baseline / "lcars-eeh/ech.sh").write_text(old)
        current = self.skills
        try:
            self.skills = baseline
            before = self.succeeds(self.ech("next", "--all")).replace(str(baseline), "<SKILLS>")
            self.skills = current
            after = self.succeeds(self.ech("next", "--all")).replace(str(current), "<SKILLS>")
        finally:
            self.skills = current
        self.assertIn("NEXT: file", before)
        self.assertEqual(after, before)


if __name__ == "__main__":
    unittest.main(verbosity=2)

"""Mutation tests for the document-claim gate, using disposable document copies."""

import contextlib
import io
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

import doc_claims


ROOT = Path(__file__).resolve().parents[2]
SUITE = ROOT / "tests/doc-claims.test.sh"
GATE = ROOT / "tests/lib/doc_claims.py"
DOCUMENTS = (
    "HOLOGRAM-COMMAND-MODE.md", "DELEGATION.md", "ORCHESTRATION.md",
    "delegate-brief.md",
)


class DocClaimsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="lcars-doc-claims-")
        self.addCleanup(self.temp.cleanup)
        self.docs = Path(self.temp.name)
        for name in DOCUMENTS:
            shutil.copyfile(ROOT / "skills/lcars-eeh" / name, self.docs / name)

    def gate(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            status = doc_claims.check(self.docs)
        return subprocess.CompletedProcess(
            ["doc_claims.check", str(self.docs)], status, output.getvalue(), ""
        )

    def plant(self, text, name="DELEGATION.md"):
        path = self.docs / name
        original = path.read_text()
        path.write_text(original + "\n" + text + "\n")
        return f"{name}:{len(original.splitlines()) + 2}"

    def test_02_bogus_verb_diagnoses_document_line_and_dispatch(self):
        location = self.plant("Run `lcars-ech s357-no-such-verb`.")
        result = self.gate()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(f"FAIL {self.docs / location}", result.stdout)
        self.assertIn("lcars-ech s357-no-such-verb", result.stdout)
        self.assertIn("dispatch has", result.stdout)

    def test_03_flag_must_belong_to_that_verbs_parser(self):
        location = self.plant(
            "Run `lcars-ech tier U --tier T1 --why reason --s357-no-such-flag`."
        )
        result = self.gate()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(f"FAIL {self.docs / location}", result.stdout)
        self.assertIn("--s357-no-such-flag", result.stdout)
        self.assertIn("tier parser accepts", result.stdout)
        self.assertNotIn("'lcars-ech tier --tier':", result.stdout)
        self.assertNotIn("'lcars-ech tier --why':", result.stdout)

    def test_04_environment_name_requires_a_code_read(self):
        location = self.plant("Set `LCARS_S357_NO_SUCH_VARIABLE=1`.")
        result = self.gate()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(f"FAIL {self.docs / location}", result.stdout)
        self.assertIn("LCARS_S357_NO_SUCH_VARIABLE", result.stdout)
        self.assertIn("no environment read under skills/", result.stdout)

    def test_05_docs_pointer_executes_the_real_resolver(self):
        location = self.plant("Read `lcars-eeh docs s357-no-such-doc`.")
        result = self.gate()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(f"FAIL {self.docs / location}", result.stdout)
        self.assertIn("no such document 's357-no-such-doc'", result.stdout)

    def test_docs_shorthand_is_not_silently_ignored(self):
        location = self.plant("Read `docs s357-no-such-shorthand`.")
        result = self.gate()
        self.assertIn(f"FAIL {self.docs / location}", result.stdout)
        self.assertIn("no such document 's357-no-such-shorthand'", result.stdout)

    def test_06_stripping_each_document_trips_its_fixed_minimum(self):
        for name in DOCUMENTS:
            with self.subTest(document=name):
                path = self.docs / name
                original = path.read_text()
                path.write_text("# stripped\n" + "Run `lcars-ech status`.\n" * 50)
                try:
                    result = self.gate()
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(f"FAIL {path}:1: minimum resolved claims", result.stdout)
                    self.assertIn("got 1 distinct", result.stdout)
                finally:
                    path.write_text(original)

    def test_deleting_a_document_has_a_named_minimum_diagnosis(self):
        path = self.docs / "ORCHESTRATION.md"
        path.unlink()
        result = self.gate()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(f"FAIL {path}:1: minimum resolved claims", result.stdout)
        self.assertIn("document is missing", result.stdout)

    def test_07_unclassifiable_claim_and_coverage_are_explicit(self):
        location = self.plant("Run `lcars-ech <choose-a-verb> --s357-unbound`.")
        result = self.gate()
        self.assertIn(f"UNCHECKED {self.docs / location}", result.stdout)
        self.assertIn("lcars-ech <choose-a-verb>", result.stdout)
        counts = re.search(r"COVERAGE TOTAL: checked=(\d+) skipped=(\d+)", result.stdout)
        self.assertIsNotNone(counts)
        self.assertGreater(int(counts[1]), 0)
        self.assertGreater(int(counts[2]), 0)

    def test_computed_or_bare_command_is_reported_as_unchecked(self):
        location = self.plant('Run `lcars-ech "$verb"` rather than inventing a verb.')
        result = self.gate()
        self.assertIn(f"UNCHECKED {self.docs / location}: 'lcars-ech'", result.stdout)
        self.assertIn("no concrete verb", result.stdout)

    def test_08_saved_status_survives_label_substitution(self):
        result = subprocess.run(
            ["bash", str(SUITE), "--assertion-control"],
            cwd=ROOT, capture_output=True, text=True, timeout=5,
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("FAIL assertion-control: expected exit 0, got 1", result.stdout)

    def test_09_merge_runner_discovers_fast_offline_gate(self):
        self.plant("Run `lcars-ech s357-runner-must-fail`.")
        runners = self.docs / "runner"
        binaries = self.docs / "bin"
        runners.mkdir()
        binaries.mkdir()
        forbidden_log = self.docs / "forbidden.log"
        docs_log = self.docs / "resolver.log"
        for name in ("claude", "copilot", "gh", "curl", "git"):
            stub = binaries / name
            stub.write_text("#!/bin/bash\nprintf '%s\\n' " + shlex.quote(name)
                            + " >> " + shlex.quote(str(forbidden_log)) + "\nexit 93\n")
            stub.chmod(0o755)
        bash = binaries / "bash"
        bash.write_text(
            '#!/bin/bash\ncase "${1:-}:${2:-}" in\n*/eeh.sh:docs)\n'
            "printf 'docs resolver\\n' >> " + shlex.quote(str(docs_log))
            + '\n;;\nesac\nexec /bin/bash "$@"\n'
        )
        bash.chmod(0o755)
        (runners / SUITE.name).write_text(
            "#!/bin/bash\nexec " + shlex.join(
                [sys.executable, str(GATE), "--docs-dir", str(self.docs)]
            ) + "\n"
        )
        env = dict(os.environ, PATH=str(binaries) + os.pathsep + os.environ["PATH"])
        start = time.monotonic()
        result = subprocess.run(
            ["/bin/bash", str(ROOT / "tests/run.sh"), str(runners)],
            cwd=ROOT, env=env, capture_output=True, text=True, timeout=15,
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("SUITE doc-claims.test.sh", result.stdout)
        self.assertRegex(result.stdout, r"RESULT doc-claims.test.sh elapsed=\d+s exit=1")
        self.assertIn("SOME SUITES FAILED", result.stdout)
        self.assertTrue(docs_log.is_file(), "the real docs oracle must use the counting PATH")
        self.assertFalse(forbidden_log.exists(), "no network, engine, or git command may run")
        self.assertLess(time.monotonic() - start, 15)
        print(f"PROOF 9: runner discovered doc-claims.test.sh; "
              f"docs resolver calls={len(docs_log.read_text().splitlines())}; "
              f"forbidden calls=0; elapsed={time.monotonic() - start:.2f}s")

    def test_paths_require_real_code_references_not_just_prose(self):
        first = self.plant("Read `skills/lcars-eeh/s357-missing.sh`.")
        second = self.plant("Read `.git/lcars/s357-missing.json`.")
        result = self.gate()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(f"FAIL {self.docs / first}", result.stdout)
        self.assertIn(f"FAIL {self.docs / second}", result.stdout)
        self.assertIn("skills/lcars-eeh/s357-missing.sh", result.stdout)
        self.assertIn(".git/lcars/s357-missing.json", result.stdout)
        self.assertIn("no code I/O reference", result.stdout)

    # --- S358 fix round 2, defect 4: the flag model reads EVERY arm ---------
    # `lcars-eeh docs` grew a `--part-of` arm in the SAME one-line `case` that
    # `--path|-p` lives in. The model captured only the first two flags, so the
    # gate called `--part-of` unaccepted — and the first line of prose that
    # documented the feature would have turned the build red. Measured by
    # calling the model directly, not inferred.
    def test_docs_flag_model_reads_every_arm_of_the_case(self):
        accepted = doc_claims.flags_for("lcars-eeh", "docs", "")
        self.assertIn("--path", accepted)
        self.assertIn("--part-of", accepted)

    # THE KNOWN-GOOD CONTROL, and the one that matters: a regex widened until
    # it matches anything is worse than the bug it cured. The model must still
    # REFUSE a flag the code does not have.
    def test_docs_flag_model_still_rejects_a_flag_the_code_lacks(self):
        accepted = doc_claims.flags_for("lcars-eeh", "docs", "")
        self.assertNotIn("--not-a-real-flag", accepted)
        self.assertNotIn("--tier", accepted)
        self.assertTrue(
            accepted <= {"--path", "--part-of"},
            f"the model accepts flags the case does not declare: {accepted}",
        )

    # And the consequence, end to end: a prose document may now DOCUMENT the
    # flag and the gate stays green. Planted into a disposable copy, so nothing
    # is left behind in the shipped documents.
    def test_prose_may_document_the_part_of_flag_and_the_gate_stays_green(self):
        self.plant("Ask `lcars-eeh docs --part-of` with a whole heading line.")
        result = self.gate()
        self.assertNotRegex(result.stdout, r"FAIL [^\n]*--part-of")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("KIND flag: checked=", result.stdout)
        self.assertIn("failed=0; minimum-failures=0", result.stdout)

    # CONTROL for the test above: the plant really does reach the flag checker,
    # so its green means something. The same sentence with a flag `docs` does
    # not have must RED, and the diagnosis must name the accepted set.
    def test_a_bogus_docs_flag_in_prose_still_reds_the_gate(self):
        location = self.plant(
            "Ask `lcars-eeh docs --not-a-real-flag` with a whole heading line.")
        result = self.gate()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(f"FAIL {self.docs / location}", result.stdout)
        self.assertIn("--not-a-real-flag", result.stdout)
        self.assertIn("docs parser accepts --part-of, --path", result.stdout)

    # REGRESSION GUARD for the previous round's half-fix: the arms must stay on
    # ONE line, because this literal-matching model is what reads them. The
    # comment in eeh.sh says so; this makes the claim fail loudly.
    def test_the_docs_case_arms_stay_on_one_line(self):
        code = (ROOT / "skills/lcars-eeh/eeh.sh").read_text()
        # The CODE line, not the comment above it that quotes the same literal.
        arm = next((line for line in code.splitlines()
                    if re.match(r"\s*case .* in --path\|-p\)", line)), None)
        self.assertIsNotNone(arm, "the literal `in --path|-p)` is no longer contiguous")
        self.assertIn("--part-of)", arm, "the --part-of arm left the one-line case")
        self.assertIn("esac", arm, "the case no longer closes on its own line")

    def test_installer_only_variable_is_unchecked_not_a_fake_contradiction(self):
        location = self.plant("The installer reads `LCARS_BIN_DEST`.")
        result = self.gate()
        self.assertIn(f"UNCHECKED {self.docs / location}: 'LCARS_BIN_DEST'", result.stdout)
        self.assertIn("installer-only read at install.sh:", result.stdout)
        self.assertNotRegex(result.stdout, r"FAIL [^\n]+: 'LCARS_BIN_DEST'")


if __name__ == "__main__":
    unittest.main(verbosity=2)

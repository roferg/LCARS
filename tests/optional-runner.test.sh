#!/usr/bin/env bash
# Exercises tests/lib/optional_runner.py with real interpreter probes.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$ROOT/tests/lib" <<'PY'
import contextlib
import io
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, sys.argv[1])
from optional_runner import runner_available


class OptionalRunnerTests(unittest.TestCase):
    def probe(self, executable, module=None):
        results = []
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            available = runner_available(
                "optional case", executable, "optional module",
                "set LCARS_OPTIONAL_PYTHON=/path/to/python",
                module=module, results=results)
        return available, results, output.getvalue()

    def assert_skip(self, executable, module=None):
        available, results, output = self.probe(executable, module)
        self.assertFalse(available)
        self.assertEqual(len(results), 1)
        self.assertTrue(results[0]["skipped"])
        self.assertFalse(results[0]["passed"])
        self.assertIn("SKIPPED optional case", output)
        self.assertIn("missing optional dependency optional module", output)
        self.assertIn("set LCARS_OPTIONAL_PYTHON=/path/to/python", output)
        self.assertIn(results[0]["reason"], output)

    def test_missing_executable_skips(self):
        self.assert_skip("lcars-nonexistent-optional-runner")

    def test_missing_module_skips(self):
        self.assert_skip(sys.executable, "lcars_nonexistent_optional_module")

    def test_nonexecutable_path_skips(self):
        with tempfile.TemporaryDirectory() as temp:
            runner = Path(temp) / "python"
            runner.write_text("not executable\n")
            self.assert_skip(str(runner), "json")

    def test_available_module_is_not_counted_as_a_pass(self):
        self.assertEqual(self.probe(sys.executable, "json"), (True, [], ""))

    def test_available_executable_needs_no_import(self):
        self.assertEqual(self.probe(sys.executable), (True, [], ""))

    def test_unlaunchable_runner_skips(self):
        with patch("optional_runner.subprocess.run", side_effect=OSError("cannot launch")):
            self.assert_skip(sys.executable, "json")

    def test_timed_out_probe_skips(self):
        with patch("optional_runner.subprocess.run",
                   side_effect=subprocess.TimeoutExpired("probe", 15)):
            self.assert_skip(sys.executable, "json")


unittest.main(argv=[sys.argv[0]], verbosity=2)
PY

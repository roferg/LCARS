#!/usr/bin/env bash
# Real Git, real unittest/Go/Jest, and the public proof-gate entry points.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export LCARS_RUN_SCRIPT="${LCARS_RUN_SCRIPT:-$ROOT/skills/lcars-run/run.sh}"
export LCARS_WORKER_BIN=copilot
python3 - <<'PY'
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class FixtureAccounting(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.repo = Path(self.tmp.name)
        scratch = tempfile.TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        self.env = dict(os.environ, LCARS_GH_BIN="true", LCARS_GIT_BIN="git",
                        LCARS_GATE_TIMEOUT="30", PYTHONDONTWRITEBYTECODE="1",
                        CI="true", LCARS_PROOF_WT_BASE=scratch.name)
        self.git("init", "-q")
        self.git("config", "user.email", "test@example.invalid")
        self.git("config", "user.name", "test")

    def call(self, *args):
        return subprocess.run(args, cwd=self.repo, env=self.env, text=True,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT)

    def git(self, *args):
        result = self.call("git", *args)
        self.assertEqual(result.returncode, 0, result.stdout)
        return result.stdout.strip()

    def write(self, name, content):
        path = self.repo / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)

    def commit(self):
        self.git("add", ".")
        self.git("commit", "-qm", "snapshot")
        return self.git("rev-parse", "HEAD")

    def result(self, tests, edits, flip="expected"):
        self.write(".git/lcars/missions/m-001/state.json",
                   '{"id":"m-001","stage":"implement","type":"feature"}')
        self.td = self.repo / ".git/lcars/missions/m-001/tickets/t-001"
        self.td.mkdir(parents=True, exist_ok=True)
        (self.td / "result.json").write_text(json.dumps(dict(
            ticketId="t-001", passed=True, attempts=1, summary="fixture change",
            newTests=tests, testEdits=[dict(path=p, reason="fixture update") for p in edits],
            flipFlop=flip, flipFlopReason="fixture only")))

    def gate(self, command, marker):
        result = self.call("bash", os.environ["LCARS_RUN_SCRIPT"], command,
                           "--mission", "m-001", "--ticket", "t-001",
                           "--sha", self.parent)
        lines = [line for line in result.stdout.splitlines() if line.startswith(marker + "=")]
        self.assertTrue(lines, result.stdout)
        return int(lines[-1].split("=")[1]), result.stdout

    def assert_proof(self, fixture):
        rc, output = self.gate("declared-edits-guard-test", "DERC")
        self.assertEqual(rc, 0, output)
        rc, output = self.gate("flip-flop-gate-test", "FFRC")
        artifact = json.loads((self.td / "flip-flop.json").read_text())
        self.assertEqual(rc, 0, output + json.dumps(artifact, indent=2))
        self.assertEqual(artifact["verdict"], "pass", artifact)
        exclusions = artifact["declaredRan"]["excluded"]
        self.assertIn(fixture, [entry["path"] for entry in exclusions], artifact)
        self.assertTrue(next(e["reason"] for e in exclusions if e["path"] == fixture))
        self.assertFalse(artifact["declaredRan"]["unaccounted"], artifact)
        self.assertFalse((Path(self.env["LCARS_PROOF_WT_BASE"]) / "t-001-parent").exists())

    def python_ticket(self, read=False, sibling=False):
        self.env.update(LCARS_STACK="py",
                        LCARS_TEST_CMD='python3 -m unittest discover -s "$LCARS_TESTS_DIR"')
        self.write("calc.py", "def value(): return 1\n")
        self.write("tests/fixtures/page.html", "<p>before</p>\n")
        if sibling:
            self.write("tests/test_neighbor.py",
                       "import unittest\nclass Neighbor(unittest.TestCase):\n def test_ok(self): self.assertTrue(True)\n")
        self.parent = self.commit()
        self.write("calc.py", "def value(): return 2\n")
        code = ("import unittest\nfrom calc import value\nclass Proof(unittest.TestCase):\n"
                " def test_value(self): self.assertEqual(value(), 2)\n")
        if read:
            code += (" def test_fixture(self):\n  from pathlib import Path\n"
                     "  self.assertIn('after', Path('tests/fixtures/page.html').read_text())\n")
        self.write("tests/test_value.py", code)
        self.write("tests/fixtures/page.html", "<p>after</p>\n")
        self.commit()
        self.result(["tests/test_value.py"], ["tests/fixtures/page.html"])

    def test_unread_fixture_is_excluded_but_must_be_declared(self):
        self.python_ticket()
        # Parent: declaration succeeds but flip-flop is INCONCLUSIVE. Removing
        # the declaration cannot change the diff-derived flip-flop scope.
        self.result(["tests/test_value.py"], [])
        rc, output = self.gate("declared-edits-guard-test", "DERC")
        self.assertEqual(rc, 1, output)
        self.assertIn("tests/fixtures/page.html", output)
        self.result(["tests/test_value.py"], ["tests/fixtures/page.html"])
        self.assert_proof("tests/fixtures/page.html")

    def test_read_fixture_is_not_required_to_contribute_an_executed_test(self):
        self.python_ticket(read=True)
        self.assert_proof("tests/fixtures/page.html")

    def test_fixture_does_not_force_its_own_invocation_beside_untouched_tests(self):
        self.python_ticket(sibling=True)
        self.assert_proof("tests/fixtures/page.html")

    def test_executable_python_file_remains_unaccounted(self):
        self.python_ticket()
        self.write("tests/test_hidden.py",
                   "import unittest\nclass Hidden(unittest.TestCase):\n def test_hidden(self): self.fail('hidden')\n"
                   "def load_tests(loader, tests, pattern): return unittest.TestSuite()\n")
        self.commit()
        self.result(["tests/test_value.py", "tests/test_hidden.py"], ["tests/fixtures/page.html"])
        rc, output = self.gate("flip-flop-gate-test", "FFRC")
        self.assertNotEqual(rc, 0, output)
        artifact = json.loads((self.td / "flip-flop.json").read_text())
        self.assertNotIn("tests/test_hidden.py",
                         [e["path"] for e in artifact["declaredRan"]["excluded"]], artifact)

    def test_not_applicable_with_new_tests_still_refused(self):
        self.python_ticket()
        self.result(["tests/test_value.py"], ["tests/fixtures/page.html"], "not-applicable")
        result = self.call("bash", os.environ["LCARS_RUN_SCRIPT"], "proof-validate-result-test",
                           "--ticket", "t-001", "--result", str(self.td / "result.json"))
        self.assertIn("PVRC=1", result.stdout)

    def test_fixture_only_cannot_supply_proof(self):
        self.python_ticket()
        self.git("rm", "tests/test_value.py")
        self.commit()
        self.result([], ["tests/fixtures/page.html", "tests/test_value.py"])
        rc, output = self.gate("flip-flop-gate-test", "FFRC")
        self.assertEqual(rc, 2, output)
        artifact = json.loads((self.td / "flip-flop.json").read_text())
        self.assertIn("no executable test file", artifact["reason"])
        self.assertEqual([e["path"] for e in artifact["declaredRan"]["excluded"]],
                         ["tests/fixtures/page.html"])

    def test_unknown_wrapper_cannot_exclude_a_fixture(self):
        self.python_ticket()
        self.env["LCARS_TEST_CMD"] = 'bash -c \'python3 -m unittest discover -s "$LCARS_TESTS_DIR"\''
        rc, output = self.gate("flip-flop-gate-test", "FFRC")
        self.assertEqual(rc, 2, output)
        artifact = json.loads((self.td / "flip-flop.json").read_text())
        self.assertEqual(artifact["declaredRan"]["excluded"], [], artifact)

    @unittest.skipUnless(shutil.which("go"), "Go unavailable")
    def test_go_golden_is_not_used_as_package_directory(self):
        self.env.update(LCARS_STACK="go")
        self.write("go.mod", "module example.invalid/fixture\n\ngo 1.21\n")
        self.write("value.go", 'package fixture\nfunc Value() string { return "before" }\n')
        self.write("test/testdata/value.golden", "before\n")
        self.parent = self.commit()
        self.write("value.go", 'package fixture\nfunc Value() string { return "after" }\n')
        self.write("test/value_test.go", '''package fixture_test
import ("testing"; "os"; "strings"; f "example.invalid/fixture")
func TestValue(t *testing.T) {
 b,e := os.ReadFile("testdata/value.golden")
 if e != nil { t.Fatal(e) }
 if f.Value() != strings.TrimSpace(string(b)) || f.Value() != "after" { t.Fatal("wrong value") }
}
''')
        self.write("test/testdata/value.golden", "after\n")
        self.commit()
        self.result(["test/value_test.go"], ["test/testdata/value.golden"])
        self.assert_proof("test/testdata/value.golden")

    @unittest.skipUnless(os.environ.get("S340_JEST_BIN"), "set S340_JEST_BIN for real Jest")
    def test_jest_snapshot_is_excluded_not_the_test_source(self):
        jest = os.environ.get("S340_JEST_BIN")
        self.env.update(LCARS_STACK="js", LCARS_TEST_CMD=f'{jest} --runInBand "$LCARS_TESTS_DIR"')
        self.write("package.json", '{"name":"fixture","private":true,"scripts":{"test":"jest"}}')
        self.write("value.js", "module.exports = () => 'before';\n")
        snap = "__tests__/__snapshots__/value.test.js.snap"
        self.write(snap, '// Jest Snapshot v1, https://jestjs.io/docs/snapshot-testing\n\nexports[`value 1`] = `"before"`;\n')
        self.parent = self.commit()
        self.write("value.js", "module.exports = () => 'after';\n")
        self.write("__tests__/value.test.js",
                   "test('value', () => expect(require('../value')()).toMatchSnapshot());\n"
                   "test('after', () => expect(require('../value')()).toBe('after'));\n")
        self.write(snap, '// Jest Snapshot v1, https://jestjs.io/docs/snapshot-testing\n\nexports[`value 1`] = `"after"`;\n')
        self.commit()
        self.result(["__tests__/value.test.js"], [snap])
        self.assert_proof(snap)
        self.env["PATH"] += os.pathsep + str(Path(jest).parent)
        self.env["LCARS_TEST_CMD"] = 'npm test -- --runInBand "$LCARS_TESTS_DIR"'
        self.assert_proof(snap)

    @unittest.skipUnless(os.environ.get("S340_JEST_BIN"), "set S340_JEST_BIN for real Jest")
    def test_jest_configured_snapshot_extension_can_execute_tests_and_is_not_excluded(self):
        jest = os.environ.get("S340_JEST_BIN")
        self.env.update(LCARS_STACK="js", LCARS_TEST_CMD=f'{jest} --runInBand "$LCARS_TESTS_DIR"')
        self.write("package.json", '{"name":"fixture","private":true}')
        self.write("jest.config.js",
                   "module.exports = {testMatch: ['**/*.snap'], moduleFileExtensions: ['js', 'json', 'snap']};\n")
        self.write("value.js", "module.exports = 1;\n")
        self.parent = self.commit()
        self.write("value.js", "module.exports = 2;\n")
        self.write("__tests__/value.snap", "test('value', () => expect(require('../value')).toBe(2));\n")
        self.commit()
        self.result(["__tests__/value.snap"], [])
        rc, output = self.gate("flip-flop-gate-test", "FFRC")
        artifact = json.loads((self.td / "flip-flop.json").read_text())
        # Jest executes this as a test AND flags it as an obsolete snapshot.
        # Its nonzero exit must remain a failure, never an excluded fixture.
        self.assertEqual(rc, 1, output + json.dumps(artifact, indent=2))
        self.assertEqual(artifact["executed"]["tip"], "1", artifact)
        self.assertEqual(artifact["declaredRan"]["excluded"], [], artifact)

    @unittest.skipUnless(shutil.which("rspec"), "RSpec unavailable")
    def test_rspec_keeps_fixture_edit_visible_without_claiming_it_executed(self):
        self.env.update(LCARS_STACK="ruby")
        self.write("Gemfile", "source 'https://rubygems.org'\ngem 'rspec'\n")
        self.write("value.rb", "VALUE = 'before'\n")
        self.write("spec/fixtures/value.txt", "before\n")
        self.parent = self.commit()
        self.write("value.rb", "VALUE = 'after'\n")
        self.write("spec/fixtures/value.txt", "after\n")
        self.write("spec/value_spec.rb",
                   "require_relative '../value'\nRSpec.describe 'value' do\n"
                   " it('matches fixture') { expect(VALUE).to eq(File.read('spec/fixtures/value.txt').strip) }\n"
                   " it('changes') { expect(VALUE).to eq('after') }\nend\n")
        self.commit()
        self.result(["spec/value_spec.rb"], ["spec/fixtures/value.txt"])
        self.assert_proof("spec/fixtures/value.txt")


unittest.main(verbosity=2)
PY

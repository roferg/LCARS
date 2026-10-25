#!/usr/bin/env bash
# S321 findings and round 3 regressions, driven through real repos and runners.
# LCARS_S321_PYTEST_PYTHON can select an existing pytest-enabled interpreter.
# Missing optional pytest, Go, or Node runners are SKIPPED, not passed or failed.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$ROOT" "${LCARS_RUN_SCRIPT:-$ROOT/skills/lcars-run/run.sh}" <<'PY'
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import uuid

root, runner = map(Path, sys.argv[1:])
sys.path.insert(0, str(root / "tests/lib"))
from optional_runner import runner_available

keep = os.environ.get("LCARS_S321_EVIDENCE")
out = Path(keep) if keep else root / ".git" / ("s321-findings-" + uuid.uuid4().hex)
out.mkdir(parents=True)
scratch = out / "scratch"
scratch.mkdir()
env = dict(os.environ, TMPDIR=str(scratch), LCARS_GH_BIN="true",
           LCARS_GATE_TIMEOUT="15")
for key, rel in {
    "LCARS_STATE_LIB": "lcars-init/lcars-state.sh",
    "LCARS_HOST_ADAPTER": "lcars-run/host-adapter.sh",
    "LCARS_COMMENT_MIRROR": "lcars-run/comment-mirror.sh",
    "LCARS_ISSUE_BODY_LIB": "lcars-run/issue-body.sh",
    "LCARS_OWNERSHIP_LIB": "lcars-run/ownership.sh",
    "LCARS_WORKER_ADAPTER": "lcars-run/worker-adapter.sh",
    "LCARS_RENDER_LIB": "lcars-status/render.sh",
}.items():
    env[key] = str(root / "skills" / rel)


def run(args, cwd=root, check=True):
    return subprocess.run(args, cwd=cwd, env=env, check=check,
                          capture_output=True, text=True, timeout=65)


def write(repo, rel, text):
    path = repo / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)


def commit(repo, message):
    run(["git", "add", "-A"], repo)
    run(["git", "commit", "-qm", message], repo)


def fixture(name):
    base = out / name
    run(["bash", str(root / "tests/fixtures/mkflatrepo.sh"), "--dir", str(base),
         "--files", "2", "--sleep", "0", "--tip", "none"])
    return base / "repo"


unit = 'python3 -m unittest discover -s "$LCARS_TESTS_DIR" -p "test_*.py"'
test = ("import unittest\nfrom src.value import value\n"
        "class Ticket(unittest.TestCase):\n"
        "    def test_value(self):\n        self.assertEqual(value(), 1)\n")
red_test = ("import unittest\nclass ReallyRed(unittest.TestCase):\n"
            "    def test_fails(self):\n        self.assertEqual(1, 2)\n")


def python_repo(name, marker=False, existing=False):
    repo = fixture(name)
    write(repo, ".gitignore", "__pycache__/\n")
    write(repo, "src/value.py", "def value():\n    return 0\n")
    if marker:
        write(repo, "tests/__init__.py", "")
    if existing:
        write(repo, "tests/test_existing.py", test)
    commit(repo, "parent")
    parent = run(["git", "rev-parse", "HEAD"], repo).stdout.strip()
    write(repo, "src/value.py", "def value():\n    return 1\n")
    write(repo, "tests/test_ticket.py", test)
    return repo, parent


def configure(repo, command, files, stack):
    path = repo / ".git/lcars/config.json"
    config = json.loads(path.read_text())
    config.update(testCommand=command, stack=stack)
    path.write_text(json.dumps(config, indent=2) + "\n")
    write(repo, ".git/lcars/missions/m-001/tickets/t-001/result.json",
          json.dumps(dict(ticketId="t-001", passed=True, newTests=files,
                          testEdits=[], flipFlop="expected")))


results = []


def gate(repo, parent, command, files, stack="py"):
    commit(repo, "ticket")
    configure(repo, command, files, stack)
    proc = run(["bash", str(runner), "flip-flop-gate-test", "--mission", "m-001",
                "--ticket", "t-001", "--sha", parent], repo, check=False)
    (repo.parent / "gate.log").write_text(proc.stdout + proc.stderr)
    data = json.loads((repo / ".git/lcars/missions/m-001/tickets/t-001/flip-flop.json").read_text())
    (repo.parent / "gate.json").write_text(json.dumps(data, indent=2) + "\n")
    return data


def check(name, assertion):
    try:
        assertion()
    except Exception as exc:
        results.append(dict(case=name, passed=False, error=str(exc)))
        print("  FAIL", name, str(exc), flush=True)
    else:
        results.append(dict(case=name, passed=True))
        print("  ok  ", name, flush=True)
    (out / "results.json").write_text(json.dumps(results, indent=2) + "\n")


def expect(condition, evidence):
    assert condition, evidence


try:
    for odd in ("test failing.py", "test-failing.py"):
        repo, parent = python_repo("F1-" + odd)
        rel = "tests/" + odd
        write(repo, rel, red_test)
        direct = run(["python3", "-m", "unittest", rel], repo, check=False)
        (repo.parent / "direct.log").write_text(direct.stdout + direct.stderr)
        data = gate(repo, parent, unit, ["tests/test_ticket.py", rel])
        check("F1 " + odd, lambda: (
            expect(direct.returncode == 1 and "AssertionError" in direct.stderr, direct),
            expect(data["verdict"] == "inconclusive", data),
            expect(rel not in {e["path"] for e in data["declaredRan"]["excluded"]}, data)))

    repo, parent = python_repo("A-load-tests-hidden-method", marker=True)
    rel = "tests/test_hidden.py"
    write(repo, rel, red_test +
          "def load_tests(loader, tests, pattern):\n"
          "    return unittest.TestSuite()\n")
    direct = run(["python3", "-m", "unittest", "tests.test_hidden.ReallyRed.test_fails"],
                 repo, check=False)
    (repo.parent / "direct.log").write_text(direct.stdout + direct.stderr)
    data = gate(repo, parent, unit, ["tests/test_ticket.py", rel])
    check("A load_tests cannot prove a failing method absent", lambda: (
        expect(direct.returncode == 1 and "FAILED (failures=1)" in direct.stderr, direct),
        expect(data["verdict"] == "inconclusive", data),
        expect(rel in data["declaredRan"]["unaccounted"], data),
        expect(rel not in {e["path"] for e in data["declaredRan"]["excluded"]}, data)))

    repo, parent = python_repo("F2-duplicate-pattern", existing=True)
    write(repo, "tests/test_ticket.py", red_test)
    data = gate(repo, parent, unit + ' -p "test_existing.py" -v', ["tests/test_ticket.py"])
    check("F2 last pattern must select declared file", lambda: (
        expect(data["verdict"] == "fail", data),
        expect("test_fails" in data["tip"]["tail"] and
               "test_value" not in data["tip"]["tail"], data)))

    name = "F3 Go assertion is RED without count"
    if runner_available(name, "go", "Go", "install Go and add go to PATH", results=results):
        repo = fixture("F3-go-red")
        write(repo, "go.mod", "module example.com/lcarsproof\n\ngo 1.20\n")
        write(repo, "value.go", "package proof\nfunc Value() int { return 0 }\n")
        commit(repo, "Go parent")
        parent = run(["git", "rev-parse", "HEAD"], repo).stdout.strip()
        write(repo, "value.go", "package proof\nfunc Value() int { return 1 }\n")
        write(repo, "value_test.go", 'package proof\nimport "testing"\n'
              'func TestValue(t *testing.T) { if Value() != 2 { t.Fatal("value mismatch") } }\n')
        data = gate(repo, parent, "go test ./...", ["value_test.go"], "go")
        check(name, lambda: (
            expect("--- FAIL: TestValue" in data["tip"]["tail"], data),
            expect(data["verdict"] == "fail" and "TIP leg is RED" in data["reason"], data)))

    name = "F3 Node dot assertion is RED without count"
    if runner_available(name, "node", "Node.js", "install Node.js and add node to PATH", results=results):
        repo = fixture("F3-node-dot-red")
        parent = run(["git", "rev-parse", "HEAD"], repo).stdout.strip()
        write(repo, "tests/ticket.test.js",
              "const {test}=require('node:test'); const assert=require('node:assert');\n"
              "test('real failing test',()=>assert.equal(1,2));\n")
        data = gate(repo, parent, 'node --test --test-reporter=dot "$LCARS_TESTS_DIR"',
                    ["tests/ticket.test.js"], "js")
        check(name, lambda: (
            expect("ERR_ASSERTION" in data["tip"]["tail"], data),
            expect(data["verdict"] == "fail" and "TIP leg is RED" in data["reason"], data)))

    name = "B pytest quiet runner-reported failure is RED"
    pytest_python = os.environ.get("LCARS_S321_PYTEST_PYTHON", sys.executable)
    if runner_available(name, pytest_python, "pytest",
                        "supply LCARS_S321_PYTEST_PYTHON=/path/to/python "
                        "with pytest installed", module="pytest", results=results):
        repo = fixture("B-pytest-quiet-red")
        parent = run(["git", "rev-parse", "HEAD"], repo).stdout.strip()
        write(repo, "tests/test_ticket.py", "def test_fail():\n    assert 1 == 2\n")
        data = gate(repo, parent, shlex.quote(pytest_python) +
                    ' -m pytest -q "$LCARS_TESTS_DIR"', ["tests/test_ticket.py"])
        check(name, lambda: (
            expect("FAILED tests/test_ticket.py::test_fail" in data["tip"]["tail"], data),
            expect("1 failed in " in data["tip"]["tail"], data),
            expect(data["verdict"] == "fail" and "TIP leg is RED" in data["reason"], data)))

    for name, body in (
        ("error", 'throw new Error("real failure");'),
        ("named-assertion", 'const e = new Error("real failure"); '
                            'e.name = "AssertionError"; throw e;'),
    ):
        label = "B Node dot " + name + " is RED"
        if not runner_available(label, "node", "Node.js", "install Node.js and add node to PATH", results=results):
            continue
        repo = fixture("B-node-dot-" + name)
        parent = run(["git", "rev-parse", "HEAD"], repo).stdout.strip()
        write(repo, "tests/ticket.test.js",
              "const {test}=require('node:test');\n"
              "test('registered failure',()=>{" + body + "});\n")
        data = gate(repo, parent, 'node --test --test-reporter=dot "$LCARS_TESTS_DIR"',
                    ["tests/ticket.test.js"], "js")
        check(label, lambda: (
            expect("Failed tests:" in data["tip"]["tail"] and
                   "registered failure" in data["tip"]["tail"], data),
            expect(data["verdict"] == "fail" and "TIP leg is RED" in data["reason"], data)))

    for name, text in (
        ("assertion-token", "AssertionError [ERR_ASSERTION] is example text"),
        ("neutral", "ordinary example text"),
    ):
        repo = fixture("B-passing-doctest-" + name)
        parent = run(["git", "rev-parse", "HEAD"], repo).stdout.strip()
        write(repo, "tests/test_ticket.py",
              '"""\n>>> print(' + repr(text) + ')\n' + text + '\n"""\n')
        direct = run(["python3", "-m", "doctest", "-v", "tests/test_ticket.py"],
                     repo, check=False)
        (repo.parent / "direct.log").write_text(direct.stdout + direct.stderr)
        data = gate(repo, parent, 'python3 -m doctest -v "$LCARS_TESTS_DIR"; exit 1',
                    ["tests/test_ticket.py"])
        check("B passing doctest " + name + " is not failure evidence", lambda: (
            expect(direct.returncode == 0 and "Test passed." in direct.stdout, direct),
            expect(text in data["tip"]["tail"] and "Test passed." in data["tip"]["tail"], data),
            expect(data["tip"]["rc"] == 1 and data["verdict"] == "inconclusive", data)))

    repo, parent = python_repo("F4-dollar-top", marker=True)
    data = gate(repo, parent, unit + ' -t "$PWD"', ["tests/test_ticket.py"])
    replay = run(["bash", "-c", data["tip"]["cmd"]], repo, check=False)
    (repo.parent / "replay.log").write_text(replay.stdout + replay.stderr)
    check("F4 preserve shell expansion and paste-back", lambda: (
        expect(data["verdict"] == "pass", data),
        expect(replay.returncode == 0 and "Ran 1 test" in replay.stderr, replay)))

    for reporter in ("dot", "tap"):
        name = "boot failure remains inconclusive (" + reporter + ")"
        if not runner_available(name, "node", "Node.js", "install Node.js and add node to PATH", results=results):
            continue
        repo = fixture("boot-" + reporter)
        parent = run(["git", "rev-parse", "HEAD"], repo).stdout.strip()
        write(repo, "tests/ticket.test.js", "require('lcars-nonexistent-module');\n")
        data = gate(repo, parent, 'node --test --test-reporter=' + reporter + ' "$LCARS_TESTS_DIR"',
                    ["tests/ticket.test.js"], "js")
        check(name, lambda:
              expect(data["verdict"] == "inconclusive", data))

    repo, parent = python_repo("directory-byte-identity")
    # Two nested files select an ancestor; a flat pair in this repo selects files.
    (repo / "tests/test_ticket.py").unlink()
    files = ["tests/unit/test_one.py", "tests/unit/test_two.py"]
    for rel in files:
        write(repo, rel, test)
    data = gate(repo, parent, unit, files)
    expected = "cd '%s' && LCARS_TESTS_DIR='%s/tests/unit' bash -c '%s'" % (repo, repo, unit)
    check("ancestor command byte identity", lambda: (
        expect(data["verdict"] == "pass", data),
        expect(data["tip"]["cmd"] == expected, data["tip"]["cmd"])))
finally:
    (out / "results.json").write_text(json.dumps(results, indent=2) + "\n")
    skipped = sum(r.get("skipped", False) for r in results)
    passed = sum(r["passed"] for r in results)
    print(f"{passed} passed; {len(results) - passed - skipped} failed; "
          f"{skipped} skipped", flush=True)
    if not keep:
        shutil.rmtree(out)
sys.exit(0 if all(r["passed"] or r.get("skipped", False) for r in results) else 1)
PY

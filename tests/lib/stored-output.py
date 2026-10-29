"""Stored-output declarations through the public proof-gate hooks."""
import json
import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile


SOURCE = Path(__file__).resolve().parents[2]
SCRIPT = Path(os.environ.get("LCARS_RUN_SCRIPT", SOURCE / "skills/lcars-run/run.sh"))
temporary = None if os.environ.get("LCARS_STORED_OUTPUT_LOG") else tempfile.TemporaryDirectory(prefix="lcars-stored-")
DEST = Path(os.environ["LCARS_STORED_OUTPUT_LOG"] if temporary is None else temporary.name)
DEST.mkdir(parents=True, exist_ok=True)
DEPS = Path(os.environ.get("LCARS_STORED_OUTPUT_DEPS", DEST / "missing-deps"))
shim = DEST / "shim"
shim.mkdir(exist_ok=True)
for engine in ("claude", "copilot"):
    path = shim / engine
    path.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "' + str(DEST / (engine + ".calls")) + '"\nexit 93\n')
    path.chmod(0o755)
ENV = dict(os.environ, PATH=f"{shim}:{DEPS}/gems/bin:{os.environ['PATH']}",
           LCARS_WORKER_BIN="copilot", LCARS_GH_BIN="true", LCARS_GIT_BIN="git",
           LCARS_GATE_TIMEOUT="30", PYTHONDONTWRITEBYTECODE="1", CI="true")
if (DEPS / "gems").exists():
    ENV.update(GEM_HOME=str(DEPS / "gems"), GEM_PATH=str(DEPS / "gems"))
FAILURES = []
ROWS = []


def run(label, argv, cwd=SOURCE, extra=None):
    p = subprocess.run(argv, cwd=cwd, env=dict(ENV, **(extra or {})),
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                       text=True, timeout=100)
    (DEST / (label + ".txt")).write_text(p.stdout)
    (DEST / (label + ".command.json")).write_text(json.dumps(
        dict(argv=list(map(str, argv)), cwd=str(cwd), exit=p.returncode), indent=2))
    return p


def check(condition, message):
    print(("PASS " if condition else "FAIL ") + message, flush=True)
    if not condition:
        FAILURES.append(message)


def checked(label, argv, repo):
    p = run(label, argv, repo)
    if p.returncode:
        raise RuntimeError((label, p.returncode, p.stdout))
    return p.stdout.strip()


def write(repo, name, content):
    path = repo / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content)


control = run("claude-control", ["claude", "--model", "refusal-control"])
check(control.returncode == 93, "Claude shim refuses with exit 93")


def case(name, files, change, fixture, tests, stack, command, contradiction=False,
         parent_only=False):
    repo = DEST / name
    repo.mkdir()
    for args in (["init", "-q"], ["config", "user.email", "s341@example.invalid"],
                 ["config", "user.name", "S341 control"]):
        checked(name + "-git-" + args[0], ["git", *args], repo)
    for path, content in files.items():
        write(repo, path, content)
    checked(name + "-add-parent", ["git", "add", "."], repo)
    checked(name + "-commit-parent", ["git", "commit", "-qm", "parent"], repo)
    parent = checked(name + "-parent", ["git", "rev-parse", "HEAD"], repo)
    for path, content in change.items():
        write(repo, path, content)
    checked(name + "-add-tip", ["git", "add", "."], repo)
    checked(name + "-commit-tip", ["git", "commit", "-qm", "ticket"], repo)
    td = repo / ".git/lcars/missions/m-001/tickets/t-001"
    td.mkdir(parents=True)
    write(repo, ".git/lcars/missions/m-001/state.json",
          '{"id":"m-001","stage":"implement","type":"feature"}')
    edits = [dict(path=p, reason="Ticket amendment") for p in change
             if (p in files or p == fixture) and p.startswith(("tests/", "__tests__/", "test/", "spec/"))]
    next(e for e in edits if e["path"] == fixture)["kind"] = "stored-output"
    result = dict(ticketId="t-001", passed=True, attempts=1, summary="Real gate control",
                  newTests=tests, testEdits=edits, flipFlop="expected")
    extra = dict(LCARS_STACK=stack, LCARS_TEST_CMD=command,
                 LCARS_PROOF_WT_BASE=str(DEST / (name + "-scratch")))
    common = ["--mission", "m-001", "--ticket", "t-001", "--sha", parent]

    def gate(label, hook, marker):
        p = run(name + "-" + label, ["bash", str(SCRIPT), hook, *common], repo, extra)
        match = re.search(rf"^{marker}=(\d+)$", p.stdout, re.M)
        check(p.returncode == 0 and match is not None, name + " hook exit/marker " + label)
        return int(match[1]) if match else -1, p.stdout

    (td / "result.json").write_text(json.dumps(result))
    valid = run(name + "-valid", ["bash", str(SCRIPT), "proof-validate-result-test",
                "--ticket", "t-001", "--result", str(td / "result.json")], repo, extra)
    check(valid.returncode == 0 and "PVRC=0" in valid.stdout, name + " explicit declaration validates")
    derc, _ = gate("declared", "declared-edits-guard-test", "DERC")
    recorded = json.loads((td / "test-edits.json").read_text())
    check(derc == 0 and any(e["path"] == fixture for e in recorded), name + " edit recorded")
    check(any(e.get("kind") == "stored-output" and e["path"] == fixture for e in recorded),
          name + " stored-output kind recorded")
    ffrc, text = gate("flip-flop", "flip-flop-gate-test", "FFRC")
    artifact = json.loads((td / "flip-flop.json").read_text())
    (DEST / (name + "-flip-flop.json")).write_text(json.dumps(artifact, indent=2))
    exclusions = artifact["declaredRan"]["excluded"]
    check(any(e["path"] == fixture and "stored-output" in e["reason"] for e in exclusions),
          name + " explicit exclusion with reason")
    if contradiction:
        check(ffrc == 1 and fixture in artifact["reason"] and "contradict" in artifact["reason"],
              name + " contradicted declaration REFUSED with FFRC=1")
        observed = artifact.get("storedOutput", {}).get("runs", [])
        leg = "parent" if parent_only else "tip"
        check(any(r["leg"] == leg and r["rc"] != 0 and fixture in r.get("contradicted", [])
                  for r in observed), name + " real failing " + leg + " discovery recorded")
    else:
        check(ffrc == 0 and artifact["tip"]["rc"] == 0 and artifact["parent"]["rc"] != 0,
              name + " deadlock clears with green tip/red parent")
        (td / "proof-tests.sha256").write_text("".join(
            hashlib.sha256((repo / p).read_bytes()).hexdigest() + "  " + p + "\n"
            for p in tests + [e["path"] for e in edits]))
        write(repo, ".git/lcars/missions/m-001/waves.json",
              json.dumps(dict(waves=[dict(wave=1, tickets=[dict(id="t-001", issue=None)])]), indent=2))
        fsrc, _ = gate("retest", "full-suite-gate-test", "FSRC")
        check(fsrc == 0 and (td / "stored-output-committed.json").exists(),
              name + " shared pre-merge recheck clears and observes declaration")
        if stack == "py":
            branch = checked(name + "-branch", ["git", "branch", "--show-current"], repo)
            write(repo, ".git/lcars/missions/m-001/state.json", json.dumps(
                dict(id="m-001", stage="implement", type="feature", branch=branch)))
            pcrc, _ = gate("post-commit", "post-commit-gate-test", "PCRC")
            check(pcrc == 0, name + " post-commit accounting clears")
    result["testEdits"] = [e for e in edits if e["path"] != fixture]
    (td / "result.json").write_text(json.dumps(result))
    underc, untext = gate("undeclared", "declared-edits-guard-test", "DERC")
    check(underc == 1 and fixture in untext, name + " undeclared edit FAIL names path")
    result["testEdits"] = edits
    result.update(flipFlop="not-applicable", flipFlopReason="Refusal control")
    (td / "result.json").write_text(json.dumps(result))
    p = run(name + "-not-applicable", ["bash", str(SCRIPT), "proof-validate-result-test",
            "--ticket", "t-001", "--result", str(td / "result.json")], repo, extra)
    check(p.returncode == 0 and "PVRC=1" in p.stdout, name + " nonempty newTests still refuses waiver")
    result["flipFlop"] = "expected"
    result["testEdits"] = [dict(e, **({"kind": "guess"} if e["path"] == fixture else {})) for e in edits]
    (td / "result.json").write_text(json.dumps(result))
    p = run(name + "-bad-kind", ["bash", str(SCRIPT), "proof-validate-result-test",
            "--ticket", "t-001", "--result", str(td / "result.json")], repo, extra)
    check("PVRC=1" in p.stdout and "kind" in p.stdout, name + " invalid kind rejected")
    if not contradiction and stack != "ruby":
        result["testEdits"] = [{k: v for k, v in e.items() if k != "kind"} for e in edits]
        (td / "result.json").write_text(json.dumps(result))
        plain, _ = gate("no-kind", "flip-flop-gate-test", "FFRC")
        plain_artifact = json.loads((td / "flip-flop.json").read_text())
        check(plain != 0 and not any(e["path"] == fixture for e in plain_artifact["declaredRan"]["excluded"]),
              name + " no declaration never excludes stored output")
    check(len(checked(name + "-worktrees", ["git", "worktree", "list", "--porcelain"], repo)
              .split("worktree ")) == 2, name + " parent scratch pruned")
    if name == "python-unread":
        checked(name + "-remove-proof", ["git", "rm", "tests/test_product.py"], repo)
        checked(name + "-data-only-commit", ["git", "commit", "-qm", "data-only control"], repo)
        result.update(newTests=[], testEdits=edits)
        (td / "result.json").write_text(json.dumps(result))
        empty, _ = gate("data-only", "flip-flop-gate-test", "FFRC")
        check(empty == 2, "stored output alone cannot supply executable proof")
    ROWS.append(dict(case=name, FFRC=ffrc, DERC=derc, undeclaredDERC=underc,
                     parent=parent, artifact=artifact))


pycmd = 'python3 -m unittest discover -s "$LCARS_TESTS_DIR"'
pytest = ("import unittest\nfrom product import answer\nclass Product(unittest.TestCase):\n"
          " def test_answer(self): self.assertEqual(answer(), 2)\n")
for read in (False, True):
    code = pytest
    if read:
        code += (" def test_fixture(self):\n  from pathlib import Path\n"
                 "  self.assertIn('after', Path('tests/fixtures/page.html').read_text())\n")
    case("python-read" if read else "python-unread",
         {"product.py": "def answer(): return 1\n", "tests/fixtures/page.html": "<p>before</p>\n"},
         {"product.py": "def answer(): return 2\n", "tests/test_product.py": code,
          "tests/fixtures/page.html": "<p>after</p>\n"},
         "tests/fixtures/page.html", ["tests/test_product.py"], "py", pycmd)

case("python-new-golden", {"product.py": "def answer(): return 1\n"},
     {"product.py": "def answer(): return 2\n",
      "tests/test_product.py": pytest + " def test_fixture(self):\n  from pathlib import Path\n  self.assertIn('after', Path('tests/fixtures/page.html').read_text())\n",
      "tests/fixtures/page.html": "<p>after</p>\n"},
     "tests/fixtures/page.html", ["tests/test_product.py"], "py", pycmd)

docs = ("import doctest\nfrom pathlib import Path\n"
        "def load_tests(loader, tests, pattern):\n"
        " tests.addTests(doctest.DocFileSuite(str(Path(__file__).with_name("
        "'requirements.txt')), module_relative=False))\n return tests\n")
for parent_only in (False, True):
    case("python-doctest-parent" if parent_only else "python-doctest",
         {"product.py": "def answer(): return 1\n", "tests/test_docs.py": docs,
          "tests/requirements.txt": ">>> 2 + 2\n" + ("5\n" if parent_only else "4\n")},
         {"product.py": "def answer(): return 2\n", "tests/test_product.py": pytest,
          "tests/requirements.txt": ">>> 2 + 2\n" + ("4\n" if parent_only else "5\n")},
         "tests/requirements.txt", ["tests/test_product.py"], "py", pycmd, True, parent_only)

case("python-failure", {"product.py": "def answer(): return 1\n",
     "tests/test_lie.py": "import unittest\nclass Lie(unittest.TestCase):\n def test_lie(self): self.assertEqual(4,4)\n"},
     {"product.py": "def answer(): return 2\n", "tests/test_product.py": pytest,
      "tests/test_lie.py": "import unittest\nclass Lie(unittest.TestCase):\n def test_lie(self): self.assertEqual(4,5)\n"},
     "tests/test_lie.py", ["tests/test_product.py"], "py", pycmd, True)
case("python-error", {"product.py": "def answer(): return 1\n",
     "tests/test_lie.py": "import unittest\nclass Lie(unittest.TestCase):\n def test_lie(self): pass\n"},
     {"product.py": "def answer(): return 2\n", "tests/test_product.py": pytest,
      "tests/test_lie.py": "import unittest\nclass Lie(unittest.TestCase):\n def test_lie(self): raise RuntimeError('broken')\n"},
     "tests/test_lie.py", ["tests/test_product.py"], "py", pycmd, True)

jest = DEPS / "node_modules/.bin/jest"
if not jest.exists():
    found = shutil.which("jest")
    jest = Path(found) if found else None
if jest:
    snap = "__tests__/__snapshots__/value.test.js.snap"
    header = "// Jest Snapshot v1, https://jestjs.io/docs/snapshot-testing\n\n"
    case("jest-snapshot", {"package.json": '{"name":"s341","private":true}',
         "value.js": "module.exports = () => 'before';\n", snap: header + 'exports[`value 1`] = `"before"`;\n'},
         {"value.js": "module.exports = () => 'after';\n",
          "__tests__/value.test.js": "test('value', () => expect(require('../value')()).toMatchSnapshot());\ntest('new', () => expect(require('../value')()).toBe('after'));\n",
          snap: header + 'exports[`value 1`] = `"after"`;\n'}, snap,
         ["__tests__/value.test.js"], "js", f'{jest} --runInBand "$LCARS_TESTS_DIR"')
    case("jest-failure", {"package.json": '{"name":"s341","private":true}',
         "value.js": "module.exports = () => 'before';\n",
         "__tests__/lie.test.js": "test('lie', () => expect(4).toBe(4));\n"},
         {"value.js": "module.exports = () => 'after';\n",
          "__tests__/value.test.js": "test('new', () => expect(require('../value')()).toBe('after'));\n",
          "__tests__/lie.test.js": "test('lie', () => expect(4).toBe(5));\n"},
         "__tests__/lie.test.js", ["__tests__/value.test.js"], "js",
         f'{jest} --runInBand "$LCARS_TESTS_DIR"', True)
    case("jest-error", {"package.json": '{"name":"s341","private":true}',
         "value.js": "module.exports = () => 'before';\n",
         "__tests__/lie.test.js": "test('lie', () => expect(4).toBe(4));\n"},
         {"value.js": "module.exports = () => 'after';\n",
          "__tests__/value.test.js": "test('new', () => expect(require('../value')()).toBe('after'));\n",
          "__tests__/lie.test.js": "throw new Error('broken');\n"},
         "__tests__/lie.test.js", ["__tests__/value.test.js"], "js",
         f'{jest} --runInBand "$LCARS_TESTS_DIR"', True)
else:
    print("SKIP Jest: set LCARS_STORED_OUTPUT_DEPS to existing dependencies", flush=True)

if shutil.which("go"):
    case("go-golden", {"go.mod": "module example.invalid/s341\n\ngo 1.21\n",
         "test/value.go": 'package example\nfunc Value() string { return "before" }\n',
         "test/testdata/value.golden": "before\n"},
         {"test/value.go": 'package example\nfunc Value() string { return "after" }\n',
          "test/value_test.go": 'package example\nimport ("testing"; "os"; "strings")\nfunc TestValue(t *testing.T) { b,e := os.ReadFile("testdata/value.golden"); if e != nil { t.Fatal(e) }; if Value() != strings.TrimSpace(string(b)) { t.Fatal("golden mismatch") }; if Value() != "after" { t.Fatal("old value") } }\n',
          "test/testdata/value.golden": "after\n"}, "test/testdata/value.golden",
         ["test/value_test.go"], "go", "go test -count=1 -v ./test")
    for build_error in (False, True):
        case("go-error" if build_error else "go-failure",
             {"go.mod": "module example.invalid/s341\n\ngo 1.21\n",
              "value.go": "package example\nfunc Value() int { return 1 }\n",
              "test/value_test.go": 'package example\nimport "testing"\nfunc TestLie(t *testing.T) {}\n'},
             {"value.go": "package example\nfunc Value() int { return 2 }\n",
              "test/product_test.go": 'package example\nimport ("testing"; product "example.invalid/s341")\nfunc TestProduct(t *testing.T) { if product.Value()!=2 { t.Fatal("old value") } }\n',
              "test/value_test.go": ('package example\nvar broken = missingSymbol\n' if build_error else
                                     'package example\nimport "testing"\nfunc TestLie(t *testing.T) { t.Fatal("broken") }\n')},
             "test/value_test.go", ["test/product_test.go"], "go", "go test -count=1 -v ./test", True)
else:
    print("SKIP Go: runner unavailable", flush=True)

rspec = DEPS / "gems/bin/rspec"
if not rspec.exists():
    found = shutil.which("rspec")
    rspec = Path(found) if found else None
if rspec:
    case("rspec-fixture", {"Gemfile": "source 'https://rubygems.org'\ngem 'rspec'\n",
         "value.rb": "VALUE = 'before'\n", "spec/fixtures/value.txt": "before\n"},
         {"value.rb": "VALUE = 'after'\n",
          "spec/value_spec.rb": "require_relative '../value'\nRSpec.describe 'value' do\n it('matches fixture') { expect(VALUE).to eq(File.read('spec/fixtures/value.txt').strip) }\n it('is new') { expect(VALUE).to eq('after') }\nend\n",
          "spec/fixtures/value.txt": "after\n"}, "spec/fixtures/value.txt",
         ["spec/value_spec.rb"], "ruby", f'{rspec} "$LCARS_TESTS_DIR"')
    for load_error in (False, True):
        case("rspec-error" if load_error else "rspec-failure",
             {"Gemfile": "source 'https://rubygems.org'\ngem 'rspec'\n",
              "value.rb": "VALUE = 'before'\n",
              "spec/lie_spec.rb": "RSpec.describe('lie') { it('passes') { expect(4).to eq(4) } }\n"},
             {"value.rb": "VALUE = 'after'\n",
              "spec/value_spec.rb": "require_relative '../value'\nRSpec.describe('value') { it('new') { expect(VALUE).to eq('after') } }\n",
              "spec/lie_spec.rb": ("raise 'broken'\n" if load_error else
                                   "RSpec.describe('lie') { it('fails') { expect(4).to eq(5) } }\n")},
             "spec/lie_spec.rb", ["spec/value_spec.rb"], "ruby", f'{rspec} "$LCARS_TESTS_DIR"', True)
else:
    print("SKIP RSpec: set LCARS_STORED_OUTPUT_DEPS to existing dependencies", flush=True)

calls = (DEST / "claude.calls").read_text().splitlines()
check(calls == ["--model refusal-control"], "Claude count: 1 deliberate, 0 incidental")
(DEST / "summary.json").write_text(json.dumps(dict(rows=ROWS, failures=FAILURES, claudeCalls=calls), indent=2))
print(f"{len(FAILURES)} failures; evidence: {DEST}", flush=True)
if temporary is not None:
    temporary.cleanup()
raise SystemExit(bool(FAILURES))

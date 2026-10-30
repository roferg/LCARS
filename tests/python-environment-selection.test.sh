#!/usr/bin/env bash
# Real init and persisted commands; no installed third-party packages needed.
set -uo pipefail
ROOT="${LCARS_S322_SOURCE_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
python3 - "$ROOT" "${1:-all}" <<'PY'
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile

root = Path(sys.argv[1])
selection = sys.argv[2]
passed = failed = 0


def run(args, repo, **overrides):
    env = dict(os.environ, LCARS_GH_BIN="true", LCARS_CLAUDE_BIN="/not-installed",
               LCARS_COPILOT_BIN="true", LCARS_WORKER_BIN="copilot",
               LCARS_PROBE_TIMEOUT="5", LCARS_INIT_SKIP_PROBE="")
    env.update(overrides)
    return subprocess.run(args, cwd=repo, env=env, text=True,
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=45)


def prove(base, working):
    repo = base / f"{working} repo's"
    repo.mkdir()
    repo = repo.resolve()
    assert run(["git", "init", "-q"], repo).returncode == 0
    (repo / "pyproject.toml").write_text('[project]\nname = "suite"\nversion = "0.1"\n')
    (repo / ".gitignore").write_text(".venv/\n__pycache__/\n")
    (repo / "tests").mkdir()
    (repo / "tests/test_dependency.py").write_text(
        "import unittest\nimport captain_dependency\n"
        "class Suite(unittest.TestCase):\n"
        "    def test_dependency(self):\n"
        "        self.assertEqual(captain_dependency.answer, 42)\n")
    active = repo / ".venv"
    testenv = repo / ".git/lcars/testenv"
    for target in (active, testenv):
        result = run([sys.executable, "-m", "venv", "--without-pip", str(target)], repo)
        assert result.returncode == 0, result.stdout
    good, bad = (active, testenv) if working == "active" else (testenv, active)
    result = run([str(good / "bin/python"), "-c",
                  "import site; print(site.getsitepackages()[0])"], repo)
    assert result.returncode == 0, result.stdout
    (Path(result.stdout.strip()) / "captain_dependency.py").write_text("answer = 42\n")
    env = dict(PATH=str(active / "bin") + os.pathsep + os.environ["PATH"],
               VIRTUAL_ENV=str(active), PYTHONPATH="", PYTHONHOME="")
    args = ["-m", "unittest", "discover", "-s", "tests"]
    for interpreter, expected in ((good / "bin/python", 0), (bad / "bin/python", 1)):
        result = run([str(interpreter), *args], repo, **env)
        print(f"CONTROL {interpreter}: exit {result.returncode}\n{result.stdout}", flush=True)
        assert result.returncode == expected, result.stdout
        assert ("Ran 1 test" if expected == 0 else "No module named 'captain_dependency'") in result.stdout
    result = run(["bash", str(root / "skills/lcars-init/init.sh")], repo, **env)
    print(f"INIT exit {result.returncode}\n{result.stdout}", flush=True)
    assert result.returncode == 0, result.stdout
    config = repo / ".git/lcars/config.json"
    command = json.loads(config.read_text())["testCommand"]
    print(f"RECORDED {command}", flush=True)
    result = run(["bash", "-c", command], repo, **env)
    print(f"PERSISTED COMMAND exit {result.returncode}\n{result.stdout}", flush=True)
    assert result.returncode == 0 and "Ran 1 test" in result.stdout, result.stdout
    assert shlex.split(command)[0] == str(good / "bin/python"), command
    assert "TEST SYSTEMS ONLINE" in run(
        ["bash", str(root / "skills/lcars-init/init.sh")], repo, **env).stdout
    assert run(["git", "add", "."], repo).returncode == 0
    result = run(["git", "-c", "user.name=Test", "-c", "user.email=t@t",
                  "commit", "-qm", "real dependency suite"], repo)
    assert result.returncode == 0, result.stdout
    tree = base / f"{working} gate worktree"
    result = run(["git", "worktree", "add", "--detach", str(tree)], repo)
    assert result.returncode == 0, result.stdout
    result = run(["bash", "-c", command], tree, **dict(env, LCARS_TESTS_DIR=str(tree / "tests")))
    print(f"FRESH WORKTREE exit {result.returncode}\n{result.stdout}", flush=True)
    assert result.returncode == 0 and "Ran 1 test" in result.stdout, result.stdout
    data = json.loads(config.read_text())
    captain = shlex.quote(str(bad / "bin/python")) + " -m unittest discover -s tests"
    data.update(testCommand=captain, gateTimeout=777)
    config.write_text(json.dumps(data, indent=2) + "\n")
    result = run(["bash", str(root / "skills/lcars-init/init.sh")], repo, **env)
    assert result.returncode == 0, result.stdout
    data = json.loads(config.read_text())
    assert data["testCommand"] == captain and data["gateTimeout"] == 777, data
    assert "TEST SYSTEMS ONLINE" not in result.stdout, result.stdout
    print("CAPTAIN command and gateTimeout=777 preserved, failed probe not verified", flush=True)
    del data["testCommand"]
    config.write_text(json.dumps(data, indent=2) + "\n")
    result = run(["bash", str(root / "skills/lcars-init/init.sh")], repo,
                 **dict(env, LCARS_INIT_SKIP_PROBE="1"))
    assert result.returncode == 0 and "probing" not in result.stdout, result.stdout
    print("SKIP runs no environment probes", flush=True)
    (Path(run([str(good / "bin/python"), "-c",
               "import site; print(site.getsitepackages()[0])"], repo).stdout.strip())
     / "captain_dependency.py").unlink()
    data = json.loads(config.read_text())
    del data["testCommand"]
    config.write_text(json.dumps(data, indent=2) + "\n")
    result = run(["bash", str(root / "skills/lcars-init/init.sh")], repo, **env)
    assert result.returncode == 0, result.stdout
    data = json.loads(config.read_text())
    assert shlex.split(data["testCommand"])[0] == str(testenv / "bin/python"), data
    assert data["gateTimeout"] == 777, data
    assert "TEST SYSTEMS ONLINE" not in result.stdout and "PROBE FAILED" in result.stdout
    print("NO PASS preserves original command and captain budget; failure stays visible", flush=True)


def prove_skipped(base, working):
    repo = base / working
    repo.mkdir()
    repo = repo.resolve()
    assert run(["git", "init", "-q"], repo).returncode == 0
    (repo / "pyproject.toml").write_text('[project]\nname = "suite"\nversion = "0.1"\n')
    (repo / "tests").mkdir()
    (repo / "tests/test_dependency.py").write_text(
        "import importlib.util\nimport unittest\n"
        "class Suite(unittest.TestCase):\n"
        "    @unittest.skipUnless(importlib.util.find_spec('captain_dependency'), 'dependency absent')\n"
        "    def test_dependency(self):\n"
        "        import captain_dependency\n"
        "        self.assertEqual(captain_dependency.answer, 42)\n")
    testenv = repo / ".git/lcars/testenv"
    result = run([sys.executable, "-m", "venv", "--without-pip", str(testenv)], repo)
    assert result.returncode == 0, result.stdout
    env = dict(PYTHONPATH="", PYTHONHOME="", VIRTUAL_ENV="")
    active = repo / ".venv"
    if working != "only-skipped":
        result = run([sys.executable, "-m", "venv", "--without-pip", str(active)], repo)
        assert result.returncode == 0, result.stdout
        result = run([str(active / "bin/python"), "-c",
                      "import site; print(site.getsitepackages()[0])"], repo)
        assert result.returncode == 0, result.stdout
        (Path(result.stdout.strip()) / "captain_dependency.py").write_text("answer = 42\n")
        env.update(PATH=str(active / "bin") + os.pathsep + os.environ["PATH"],
                   VIRTUAL_ENV=str(active))
    args = ["-m", "unittest", "discover", "-s", "tests"]
    result = run([str(testenv / "bin/python"), *args], repo, **env)
    print(f"SKIPPED CONTROL exit {result.returncode}\n{result.stdout}", flush=True)
    assert result.returncode == 0 and "OK (skipped=1)" in result.stdout, result.stdout
    if working == "mixed-pass":
        (repo / "tests/test_real.py").write_text(
            "import unittest\nclass Real(unittest.TestCase):\n"
            "    def test_real(self):\n        self.assertEqual(6 * 7, 42)\n")
    if working != "only-skipped":
        result = run([str(active / "bin/python"), *args], repo, **env)
        print(f"EXECUTED CONTROL exit {result.returncode}\n{result.stdout}", flush=True)
        assert result.returncode == 0 and "skipped=" not in result.stdout, result.stdout
    result = run(["bash", str(root / "skills/lcars-init/init.sh")], repo, **env)
    print(f"INIT exit {result.returncode}\n{result.stdout}", flush=True)
    assert result.returncode == 0, result.stdout
    command = json.loads((repo / ".git/lcars/config.json").read_text())["testCommand"]
    print(f"RECORDED {command}", flush=True)
    persisted = run(["bash", "-c", command], repo, **env)
    print(f"PERSISTED COMMAND exit {persisted.returncode}\n{persisted.stdout}", flush=True)
    assert persisted.returncode == 0, persisted.stdout
    if working == "only-skipped":
        assert "PROBE INCONCLUSIVE" in result.stdout, "entirely skipped suite not inconclusive"
        assert "probing alternative Python environment" in result.stdout, "search stopped on skips"
        for false_claim in ("PROBE COMPLETE", "TEST SYSTEMS ONLINE", "verified by a live run"):
            assert false_claim not in result.stdout, result.stdout
        assert "OK (skipped=1)" in persisted.stdout, persisted.stdout
    else:
        expected = testenv if working == "mixed-pass" else active
        assert shlex.split(command)[0] == str(expected / "bin/python"), command
        assert "PROBE COMPLETE" in result.stdout and "verified by a live run" in result.stdout
        if working == "skip-then-pass":
            assert "probing alternative Python environment" in result.stdout, result.stdout
            assert "skipped=" not in persisted.stdout, persisted.stdout
        else:
            assert "Ran 2 tests" in persisted.stdout and "OK (skipped=1)" in persisted.stdout


def prove_expected_failure(base, working):
    repo = (base / working)
    repo.mkdir()
    repo = repo.resolve()
    assert run(["git", "init", "-q"], repo).returncode == 0
    (repo / "pyproject.toml").write_text('[project]\nname = "suite"\nversion = "0.1"\n')
    (repo / "tests").mkdir()
    (repo / "tests/test_dependency.py").write_text(
        "import importlib.util\nimport unittest\n"
        "expected = (unittest.expectedFailure\n"
        "            if importlib.util.find_spec('captain_dependency') is None\n"
        "            else lambda test: test)\n"
        "class Suite(unittest.TestCase):\n"
        "    @expected\n"
        "    def test_dependency(self):\n"
        "        import captain_dependency\n"
        "        self.assertEqual(captain_dependency.answer, 42)\n")
    testenv = repo / ".git/lcars/testenv"
    active = repo / ".venv"
    for target in (testenv, active):
        result = run([sys.executable, "-m", "venv", "--without-pip", str(target)], repo)
        assert result.returncode == 0, result.stdout
    result = run([str(active / "bin/python"), "-c",
                  "import site; print(site.getsitepackages()[0])"], repo)
    assert result.returncode == 0, result.stdout
    (Path(result.stdout.strip()) / "captain_dependency.py").write_text("answer = 42\n")
    env = dict(PATH=str(active / "bin") + os.pathsep + os.environ["PATH"],
               VIRTUAL_ENV=str(active), PYTHONPATH="", PYTHONHOME="",
               TMPDIR=str(base))
    args = ["-m", "unittest", "discover", "-s", "tests"]
    for interpreter, summary in ((testenv / "bin/python", "OK (expected failures=1)"),
                                 (active / "bin/python", "\nOK\n")):
        result = run([str(interpreter), *args], repo, **env)
        print(f"CONTROL {interpreter}: exit {result.returncode}\n{result.stdout}", flush=True)
        assert result.returncode == 0 and "Ran 1 test" in result.stdout, result.stdout
        assert summary in result.stdout, result.stdout
    if working == "mixed-xfail":
        # Prove the boundary on the same command before adding a genuine pass.
        result = run(["bash", str(root / "skills/lcars-init/init.sh")], repo,
                     **dict(env, LCARS_INIT_SKIP_PROBE="1"))
        assert result.returncode == 0, result.stdout
        result = run(["bash", str(root / "skills/lcars-update/update.sh"),
                      "--probe-tests"], repo, **env)
        print(f"EXPECTED-FAILURE-ONLY PROBE exit {result.returncode}\n{result.stdout}", flush=True)
        assert result.returncode != 0 and "PROBE INCONCLUSIVE" in result.stdout, (
            "expected-failure-only suite was certified before adding a genuine pass")
        for false_claim in ("PROBE COMPLETE", "TEST SYSTEMS ONLINE", "verified by a live run"):
            assert false_claim not in result.stdout, result.stdout
        (repo / "tests/test_real.py").write_text(
            "import unittest\nclass Real(unittest.TestCase):\n"
            "    def test_real(self):\n        self.assertEqual(6 * 7, 42)\n")
    result = run(["bash", str(root / "skills/lcars-init/init.sh")], repo, **env)
    print(f"INIT exit {result.returncode}\n{result.stdout}", flush=True)
    assert result.returncode == 0, result.stdout
    command = json.loads((repo / ".git/lcars/config.json").read_text())["testCommand"]
    print(f"RECORDED {command}", flush=True)
    persisted = run(["bash", "-c", command], repo, **env)
    print(f"PERSISTED COMMAND exit {persisted.returncode}\n{persisted.stdout}", flush=True)
    assert persisted.returncode == 0, persisted.stdout
    expected = testenv if working == "mixed-xfail" else active
    assert shlex.split(command)[0] == str(expected / "bin/python"), command
    assert "PROBE COMPLETE" in result.stdout and "verified by a live run" in result.stdout
    if working == "xfail-then-pass":
        assert "PROBE INCONCLUSIVE" in result.stdout, result.stdout
        assert "probing alternative Python environment" in result.stdout, result.stdout
        assert "expected failures=" not in persisted.stdout, persisted.stdout
    else:
        assert "Ran 2 tests" in persisted.stdout, persisted.stdout
        assert "OK (expected failures=1)" in persisted.stdout, persisted.stdout
        assert "probing alternative Python environment" not in result.stdout, result.stdout
        result = run(["bash", str(root / "skills/lcars-update/update.sh"),
                      "--probe-tests"], repo, **env)
        print(f"MIXED PROBE exit {result.returncode}\n{result.stdout}", flush=True)
        assert result.returncode == 0 and "PROBE COMPLETE" in result.stdout, result.stdout


with tempfile.TemporaryDirectory(prefix="lcars-python-selection-") as temp:
    for working in ("active", "testenv"):
        if selection not in ("all", working):
            continue
        try:
            prove(Path(temp), working)
        except AssertionError as error:
            failed += 1
            print(f"FAIL {working} is the only working environment: {error}", flush=True)
        else:
            passed += 1
            print(f"PASS {working} is the only working environment", flush=True)
    for working in ("only-skipped", "skip-then-pass", "mixed-pass"):
        if selection not in ("all", working):
            continue
        try:
            prove_skipped(Path(temp), working)
        except AssertionError as error:
            failed += 1
            print(f"FAIL {working}: {error}", flush=True)
        else:
            passed += 1
            print(f"PASS {working}", flush=True)
    for working in ("xfail-then-pass", "mixed-xfail"):
        if selection not in ("all", working):
            continue
        try:
            prove_expected_failure(Path(temp), working)
        except AssertionError as error:
            failed += 1
            print(f"FAIL {working}: {error}", flush=True)
        else:
            passed += 1
            print(f"PASS {working}", flush=True)

print(f"{passed} passed; {failed} failed", flush=True)
sys.exit(bool(failed))
PY

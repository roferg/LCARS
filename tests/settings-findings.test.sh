#!/usr/bin/env bash
# S322: OF11/OF4/OF2 at real init, probe, and settings-file boundaries.
# OF2 skips without real PyYAML; LCARS_S322_YAML_PYTHON selects an interpreter.
set -uo pipefail
ROOT="${LCARS_S322_SOURCE_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
python3 - "$ROOT" "${1:-all}" "$(cd "$(dirname "$0")/lib" && pwd)" <<'PY'
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

root = Path(sys.argv[1])
selection = sys.argv[2]
sys.path.insert(0, sys.argv[3])
from optional_runner import runner_available

passed = failed = 0
skips = []


def run(args, repo, **overrides):
    env = dict(os.environ, LCARS_GH_BIN="true", LCARS_CLAUDE_BIN="/not-installed",
               LCARS_COPILOT_BIN="true", LCARS_WORKER_BIN="copilot",
               TMPDIR=str(repo.parent))
    env.update(overrides)
    return subprocess.run(args, cwd=repo, env=env, text=True,
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=40)


def check(name, fn):
    global passed, failed
    try:
        fn()
    except (AssertionError, ValueError) as error:
        failed += 1
        print(f"FAIL {name}: {error}", flush=True)
    else:
        passed += 1
        print(f"PASS {name}", flush=True)


def init(repo, **env):
    return run(["bash", str(root / "skills/lcars-init/init.sh")], repo, **env)


def update(repo, *args, **env):
    return run(["bash", str(root / "skills/lcars-update/update.sh"), *args], repo, **env)


def config(repo):
    return repo / ".git/lcars/config.json"


def new_repo(base, name):
    repo = base / name
    repo.mkdir()
    assert run(["git", "init", "-q"], repo).returncode == 0
    return repo


with tempfile.TemporaryDirectory(prefix="lcars-s322-") as temp:
    base = Path(temp)
    if selection in ("all", "A"):
        repo = new_repo(base, "slow")
        (repo / "tests").mkdir()
        (repo / "tests/test_slow.py").write_text(
            "import time\nimport unittest\nclass SlowSuite(unittest.TestCase):\n"
            "    def test_elapsed(self):\n"
            "        start = time.monotonic()\n"
            "        time.sleep(4)\n"
            "        self.assertGreater(time.monotonic() - start, 3.5)\n")
        (repo / "Makefile").write_text("test:\n\t@python3 -m unittest discover -s tests\n")
        result = init(repo, LCARS_GATE_TIMEOUT_DEFAULT="2", LCARS_PROBE_TIMEOUT="2")

        def timeout_seeds():
            assert "PROBE TIMED OUT" in result.stdout, result.stdout
            value = json.loads(config(repo).read_text())["gateTimeout"]
            assert isinstance(value, int) and value > 2, f"timed-out suite left gateTimeout={value!r}"
            assert "exceeded 2s" in result.stdout, result.stdout
            assert "time it yourself" not in result.stdout, result.stdout
        check("OF11 init timeout actually seeds a larger gate bound", timeout_seeds)

        def probe_seeds():
            data = json.loads(config(repo).read_text())
            data["gateTimeout"] = None
            config(repo).write_text(json.dumps(data, indent=2) + "\n")
            result = update(repo, "--probe-tests", LCARS_GATE_TIMEOUT_DEFAULT="2",
                            LCARS_PROBE_TIMEOUT="2")
            assert result.returncode != 0, "timeout was reported as verified"
            value = json.loads(config(repo).read_text())["gateTimeout"]
            assert isinstance(value, int) and value > 2, f"probe timeout left gateTimeout={value!r}"
        check("OF11 update probe timeout seeds without claiming a pass", probe_seeds)

        def repair_seeds():
            data = json.loads(config(repo).read_text())
            data.update(testCommand=None, gateTimeout=None)
            config(repo).write_text(json.dumps(data, indent=2) + "\n")
            result = update(repo, "--fix-tests", LCARS_GATE_TIMEOUT_DEFAULT="2",
                            LCARS_PROBE_TIMEOUT="2")
            assert result.returncode != 0 and "PROBE TIMED OUT" in result.stdout, result.stdout
            value = json.loads(config(repo).read_text())["gateTimeout"]
            assert isinstance(value, int) and value > 2, f"repair timeout left gateTimeout={value!r}"
        check("OF11 repair probe also records its exceeded bound", repair_seeds)

        def pass_and_preserve():
            data = json.loads(config(repo).read_text())
            data["gateTimeout"] = None
            config(repo).write_text(json.dumps(data, indent=2) + "\n")
            result = update(repo, "--probe-tests", LCARS_GATE_TIMEOUT_DEFAULT="2",
                            LCARS_PROBE_TIMEOUT="6")
            value = json.loads(config(repo).read_text())["gateTimeout"]
            assert result.returncode == 0 and isinstance(value, int) and value > 4, result.stdout
            data["gateTimeout"] = 700
            config(repo).write_text(json.dumps(data, indent=2) + "\n")
            result = update(repo, "--probe-tests", LCARS_GATE_TIMEOUT_DEFAULT="2",
                            LCARS_PROBE_TIMEOUT="2")
            assert result.returncode != 0, result.stdout
            assert json.loads(config(repo).read_text())["gateTimeout"] == 700
        check("OF11 completed measurements still seed, captain settings still win", pass_and_preserve)

        def sanctioned_set():
            result = update(repo, "--gate-timeout", "700")
            assert result.returncode == 0, result.stdout
            assert json.loads(config(repo).read_text())["gateTimeout"] == 700
            before = config(repo).read_bytes()
            for args in [[], [""], ["0"], ["-1"], ["1.5"], ["abc"], ["3601"],
                         ["999999999999999999999"], ["--model", "wrong"]]:
                result = update(repo, "--gate-timeout", *args)
                assert result.returncode != 0, (args, result.stdout)
                assert config(repo).read_bytes() == before, f"invalid {args} changed settings"
                assert "--gate-timeout" in result.stdout, result.stdout
            for args in [["--test-command", "echo run", "--gate-timeout", "700"],
                         ["--gate-timeout", "700", "--probe-tests"]]:
                result = update(repo, *args)
                assert result.returncode != 0, f"mixed verbs accepted: {args}"
                assert config(repo).read_bytes() == before, f"mixed {args} changed settings"
        check("OF11 sanctioned gate timeout writer validates before writing", sanctioned_set)

        def defaults():
            result = run(["bash", "-c",
                          '. "$1"; printf "%s/%s" "$(lcars_gate_timeout_default)" "$PROBE_TIMEOUT"',
                          "bash", str(root / "skills/lcars-init/lcars-common.sh")], repo)
            assert result.stdout == "500/500", result.stdout
        check("OF11 shipped probe window and gate default move together", defaults)

    if selection in ("all", "B"):
        repo = new_repo(base, "multiline")
        assert init(repo, LCARS_INIT_SKIP_PROBE="1").returncode == 0
        data = json.loads(config(repo).read_text())
        data["numberOne"] = {"enabled": False}
        config(repo).write_text(json.dumps(data, indent=2) + "\n")

        def number_one_roundtrip():
            result = run(["bash", str(root / "skills/lcars-xo/xo.sh"),
                          "on", "--engine", "copilot"], repo)
            assert result.returncode == 0, result.stdout
            text = config(repo).read_text()
            try:
                actual = json.loads(text)
            except ValueError as error:
                raise AssertionError(f"writer exited 0 but JSON read-back failed: {error}\n{text}") from error
            assert actual["numberOne"] == {"enabled": True, "engine": "copilot"}, actual
            assert {k: v for k, v in actual.items() if k != "numberOne"} == {
                k: v for k, v in data.items() if k != "numberOne"}
        check("OF4 Number One replaces the whole multiline value, not its opening line", number_one_roundtrip)

        def merge_roundtrip():
            config(repo).write_text(json.dumps(data, indent=2) + "\n")
            result = update(repo)
            assert result.returncode == 0, result.stdout
            assert json.loads(config(repo).read_text())["numberOne"] == {"enabled": False}
            result = init(repo, LCARS_INIT_SKIP_PROBE="1")
            assert result.returncode == 0, result.stdout
            assert json.loads(config(repo).read_text())["numberOne"] == {"enabled": False}
        check("OF4 init and update preserve multiline objects on schema merge", merge_roundtrip)

        def refuses_invalid():
            config(repo).write_text(json.dumps(data, indent=2) + "\n")
            before = config(repo).read_bytes()
            result = run(["bash", "-c",
                          '. "$1"; lcars_config_set_or_add_raw "$2" numberOne \'{"enabled":\'',
                          "bash", str(root / "skills/lcars-init/lcars-common.sh"),
                          str(config(repo))], repo)
            assert result.returncode != 0, "invalid JSON write exited 0"
            assert config(repo).read_bytes() == before, "failed write changed settings"
            assert result.stdout.strip(), "write failed without a diagnostic"
            config(repo).write_text('{\n  "numberOne": {"enabled": true}\n    "enabled": false\n  },\n}\n')
            before = config(repo).read_bytes()
            result = update(repo, "--gate-timeout", "700")
            assert result.returncode != 0, "corrupt input was accepted"
            assert config(repo).read_bytes() == before, "corrupt input was half-rewritten"
        check("OF4 unreadable input or output fails without replacing settings", refuses_invalid)

    yaml_python = os.environ.get("LCARS_S322_YAML_PYTHON", sys.executable)
    of2_name = "OF2 fresh init records the working PyYAML interpreter, also usable in gate worktrees"
    if selection in ("all", "C") and runner_available(
            of2_name, yaml_python, "PyYAML",
            "supply LCARS_S322_YAML_PYTHON=/path/to/python with PyYAML installed",
            module="yaml", results=skips):
        repo = new_repo(base, "python repo's")
        (repo / "pyproject.toml").write_text('[project]\nname = "suite"\nversion = "0.1"\n')
        tests = repo / "tests"
        tests.mkdir()
        (tests / "__init__.py").write_text("")
        for name in ["hub_workflow", "one", "two", "three", "four", "five", "six"]:
            (tests / f"test_{name}.py").write_text(
                "import unittest\nimport yaml\nclass Suite(unittest.TestCase):\n"
                "    def test_yaml(self):\n"
                "        self.assertEqual(yaml.safe_load('enabled: true'), {'enabled': True})\n")
        bare = base / "bare"
        testenv = repo / ".git/lcars/testenv"
        for target in [bare, testenv]:
            result = run([sys.executable, "-m", "venv", "--without-pip", str(target)], repo)
            assert result.returncode == 0, result.stdout
        result = run([yaml_python, "-c", "import yaml; print(yaml.__path__[0])"], repo)
        assert result.returncode == 0, "OF2 requires real PyYAML; set LCARS_S322_YAML_PYTHON:\n" + result.stdout
        site = run([str(testenv / "bin/python"), "-c",
                    "import site; print(site.getsitepackages()[0])"], repo).stdout.strip()
        shutil.copytree(result.stdout.strip(), Path(site) / "yaml")
        path = str(bare / "bin") + os.pathsep + os.environ["PATH"]
        bare_result = run(["python3", "-m", "unittest", "tests.test_hub_workflow"], repo, PATH=path)
        assert bare_result.returncode != 0 and "ModuleNotFoundError: No module named 'yaml'" in bare_result.stdout, bare_result.stdout
        print("OF2 measured bare-interpreter symptom:\n" + bare_result.stdout, flush=True)

        def selects_working_environment():
            result = init(repo, PATH=path)
            assert result.returncode == 0, result.stdout
            command = json.loads(config(repo).read_text())["testCommand"]
            assert "testenv/bin/python" in command, f"recorded unusable command: {command}"
            assert "TEST SYSTEMS ONLINE" in result.stdout, result.stdout
            result = run(["bash", "-c", command], repo, PATH=path)
            assert result.returncode == 0 and "Ran 7 tests" in result.stdout, result.stdout
            run(["git", "add", "tests", "pyproject.toml"], repo)
            result = run(["git", "-c", "user.name=Test", "-c", "user.email=t@t",
                          "commit", "-qm", "real python suite"], repo)
            assert result.returncode == 0, result.stdout
            tree = base / "gate worktree"
            result = run(["git", "worktree", "add", "--detach", str(tree)], repo)
            assert result.returncode == 0, result.stdout
            result = run(["bash", "-c", command], tree, PATH=path,
                         LCARS_TESTS_DIR=str(tree / "tests"))
            assert result.returncode == 0 and "Ran 7 tests" in result.stdout, result.stdout
        check(of2_name, selects_working_environment)

print(f"{passed} passed; {failed} failed; {len(skips)} skipped")
sys.exit(bool(failed))
PY

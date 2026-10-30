#!/usr/bin/env bash
# S325: the real post-commit gate must run only the declared Python files.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$ROOT" "${LCARS_RUN_SCRIPT:-$ROOT/skills/lcars-run/run.sh}" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

root, runner = map(Path, sys.argv[1:])
with tempfile.TemporaryDirectory(prefix="lcars-postcommit-") as tmp:
    base = Path(tmp)
    repo = base / "repo"
    env = dict(os.environ, LCARS_GH_BIN="true", LCARS_GIT_BIN="git")

    def run(args, check=True):
        return subprocess.run(args, cwd=repo if repo.exists() else root,
                              env=env, capture_output=True, text=True,
                              check=check, timeout=60)

    run(["bash", str(root / "tests/fixtures/mkflatrepo.sh"),
         "--dir", str(base), "--files", "3", "--sleep", "0", "--tip", "none"])
    env["PATH"] = str(base / "shim") + os.pathsep + env["PATH"]
    mission = repo / ".git/lcars/missions/m-001"
    ticket = mission / "tickets/t-001"
    config_path = repo / ".git/lcars/config.json"
    config = json.loads(config_path.read_text())
    command = 'python3 -m unittest discover -s "$LCARS_TESTS_DIR"'
    config.update(stack="py", testCommand=command)
    config_path.write_text(json.dumps(config, indent=2) + "\n")
    state = json.loads((mission / "state.json").read_text())
    state["branch"] = "main"
    (mission / "state.json").write_text(json.dumps(state) + "\n")
    (repo / ".gitignore").write_text("__pycache__/\n")
    (repo / "src/value.py").write_text("def value():\n    return 42\n")
    for index in range(3):
        (repo / f"tests/test_undeclared_{index}.py").write_text(
            'raise AssertionError("undeclared test must never run")\n')
    files = ["tests/test_ticket_a.py", "tests/test_ticket_b.py"]
    for rel in files:
        (repo / rel).write_text(
            "import unittest\nfrom src.value import value\n"
            "class Ticket(unittest.TestCase):\n"
            "    def test_value(self):\n        self.assertEqual(value(), 42)\n")
    run(["git", "add", "-A"])
    run(["git", "commit", "-qm", "committed Python ticket in cluttered tests folder"])
    (ticket / "proof-tests.sha256").write_text("".join(
        hashlib.sha256((repo / rel).read_bytes()).hexdigest() + " " + rel + "\n"
        for rel in files))
    def gate(label):
        result = run(["bash", str(runner), "post-commit-gate-test",
                      "--mission", "m-001", "--ticket", "t-001"])
        output = result.stdout + result.stderr
        print(label + "\n" + output, end="", flush=True)
        return output

    output = gate("committed Python ticket, cluttered tests/")
    assert "PCRC=0\n" in output, "committed declared Python tests must pass"
    assert "proof scope: files" in output.lower() or "DECLARED FILES" in output, output

    def zero(command):
        config["testCommand"] = command
        config_path.write_text(json.dumps(config, indent=2) + "\n")
        output = gate("zero collection: " + command)
        assert "PCRC=6\n" in output, output
        assert "could not run the tests" in output.lower(), output
        assert "implementation is NOT present" not in output, output
        signal = (mission / "pc-test-signal.txt").read_text()
        assert "could not run the tests" in signal.lower(), signal
        assert "implementation is NOT present" not in signal, signal

    zero(command + " -k no_such_test")
    # A wrapper is deliberately not adapted; unittest cannot discover from a file.
    zero(command + "; exit 1")
    # A directory scope must retain the command's exact quoting and expansions.
    owned = repo / "tests/owned"
    owned.mkdir()
    for rel in files:
        (repo / rel).rename(owned / Path(rel).name)
    files = ["tests/owned/" + Path(rel).name for rel in files]
    run(["git", "add", "-A"])
    run(["git", "commit", "-qm", "nested declared tests"])
    (ticket / "proof-tests.sha256").write_text("".join(
        hashlib.sha256((repo / rel).read_bytes()).hexdigest() + " " + rel + "\n"
        for rel in files))
    zero(command + " -k no_such_test; exit 1")
    config["testCommand"] = command + ' -p "test_*.py" -k "$LCARS_S325_FILTER"'
    config_path.write_text(json.dumps(config, indent=2) + "\n")
    env["LCARS_S325_FILTER"] = "test_value"
    assert "PCRC=0\n" in gate("unchanged directory command with shell expansion")
    (repo / "src/value.py").write_text("def value():\n    return 0\n")
    run(["git", "add", "-A"])
    run(["git", "commit", "-qm", "implementation genuinely absent"])
    output = gate("genuine missing implementation")
    assert "PCRC=1\n" in output, output
    assert "implementation is NOT present on the committed branch" in output, output
    assert not (base / "worker-calls.log").read_text().strip(), "no worker may run"
    print("1 passed; 0 failed — real post-commit gate, Python, cluttered tests/")
PY

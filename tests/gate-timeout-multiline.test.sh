#!/usr/bin/env bash
# Real update -> real flip-flop gate, with a suite slower than the default.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$ROOT" <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(sys.argv[1])


def run(args, repo, check=True, **overrides):
    env = dict(os.environ, LCARS_GH_BIN="true", LCARS_CLAUDE_BIN="/not-installed",
               LCARS_COPILOT_BIN="true", LCARS_WORKER_BIN="copilot",
               LCARS_GATE_TIMEOUT="", LCARS_GATE_TIMEOUT_DEFAULT="2")
    env.update(overrides)
    result = subprocess.run(args, cwd=repo, env=env, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=60)
    print(f"COMMAND {args}\nEXIT {result.returncode}\n{result.stdout}", flush=True)
    if check:
        assert result.returncode == 0, result.stdout
    return result.stdout


with tempfile.TemporaryDirectory(prefix="lcars-gate-multiline-") as temp:
    base = Path(temp)
    run(["bash", str(root / "tests/fixtures/mkflatrepo.sh"), "--dir", str(base),
         "--files", "2", "--sleep", "2", "--tip", "flat2"], root)
    repo = base / "repo"
    config = repo / ".git/lcars/config.json"
    data = json.loads(config.read_text())
    data["gateTimeout"] = 30
    text = json.dumps(data, indent=2) + "\n"
    parent = run(["git", "rev-parse", "HEAD~1"], repo).strip()
    failed = 0
    formats = {
        "next-line-value": '"gateTimeout":\n\n    VALUE',
        "split-colon": '"gateTimeout"\n    :\n    VALUE',
        "escaped-key": '"gate\\u0054imeout":\n    VALUE',
    }
    selection = os.environ.get("LCARS_TIMEOUT_FORMAT", "")
    for name, template in formats.items():
        if selection and name != selection:
            continue
        for value in ("30", '"30"'):
            try:
                before = text.replace('"gateTimeout": 30', template.replace("VALUE", value))
                config.write_text(before)
                run(["bash", str(root / "skills/lcars-update/update.sh"),
                     "--gate-timeout", "31"], repo)
                assert json.loads(config.read_text())["gateTimeout"] == 31
                expected = before.replace(template.replace("VALUE", value),
                                          template.replace("VALUE", "31"))
                assert config.read_text() == expected, config.read_text()
                raw = run(["bash", "-c",
                           '. "$1"; lcars_config_get_raw "$2" gateTimeout',
                           "_", str(root / "skills/lcars-init/lcars-common.sh"),
                           str(config)], repo).strip()
                assert raw == "31", raw
                # Also exercise the gate's documented quoted-numeric coercion.
                if value.startswith('"'):
                    config.write_text(expected.replace(template.replace("VALUE", "31"),
                                                       template.replace("VALUE", '"31"')))
                run(["bash", str(root / "skills/lcars-run/run.sh"), "flip-flop-gate-test",
                     "--mission", "m-001", "--ticket", "t-001", "--sha", parent],
                    repo, check=False)
                artifact = repo / ".git/lcars/missions/m-001/tickets/t-001/flip-flop.json"
                actual = json.loads(artifact.read_text())
                print(f"ARTIFACT {json.dumps(actual, indent=2)}", flush=True)
                assert actual["gate"]["timeoutSecs"] == 31, actual["gate"]
                assert actual["gate"]["timeoutSource"] == "config", actual["gate"]
                assert actual["verdict"] == "pass", actual["reason"]
                assert actual["tip"]["rc"] == 0, actual["tip"]
                assert actual["parent"]["rc"] != 0, actual["parent"]
            except AssertionError as error:
                failed += 1
                print(f"FAIL {name} {value}: {error}", flush=True)
            else:
                print(f"PASS {name} {value} is consumed by the real gate", flush=True)
    if selection in ("", "budget"):
        data["gateTimeout"] = None
        config.write_text(json.dumps(data, indent=2) + "\n")
        output = run(["bash", str(root / "skills/lcars-init/init.sh")], repo,
                     LCARS_TESTS_DIR="tests", LCARS_PROBE_TIMEOUT="20",
                     LCARS_INIT_SKIP_PROBE="", LCARS_GATE_TIMEOUT_DEFAULT="1")
        assert "verified by a live run" in output, output
        assert json.loads(config.read_text())["gateTimeout"] == 30
        run(["bash", str(root / "skills/lcars-run/run.sh"), "flip-flop-gate-test",
             "--mission", "m-001", "--ticket", "t-001", "--sha", parent], repo,
            LCARS_GATE_TIMEOUT_DEFAULT="1")
        artifact = repo / ".git/lcars/missions/m-001/tickets/t-001/flip-flop.json"
        actual = json.loads(artifact.read_text())
        print(f"SEEDED ARTIFACT {json.dumps(actual, indent=2)}", flush=True)
        assert actual["verdict"] == "pass", actual["reason"]
        assert actual["gate"]["timeoutSecs"] == 30, actual["gate"]
        assert actual["gate"]["timeoutSource"] == "config", actual["gate"]
        print("PASS init seeds 30 and the real gate consumes it and passes", flush=True)
        run(["bash", str(root / "skills/lcars-update/update.sh"),
             "--gate-timeout", "1"], repo)
        run(["bash", str(root / "skills/lcars-run/run.sh"), "flip-flop-gate-test",
             "--mission", "m-001", "--ticket", "t-001", "--sha", parent],
            repo, check=False)
        actual = json.loads(artifact.read_text())
        print(f"INTERRUPTED ARTIFACT {json.dumps(actual, indent=2)}", flush=True)
        assert actual["gate"]["timeoutSecs"] == 1, actual["gate"]
        assert actual["gate"]["timeoutSource"] == "config", actual["gate"]
        assert actual["verdict"] == "inconclusive", actual["reason"]
        assert actual["tip"]["rc"] == 98, actual["tip"]
        print("PASS explicit budget 1 interrupts a 2s test: inconclusive, never pass", flush=True)
    sys.exit(bool(failed))
PY

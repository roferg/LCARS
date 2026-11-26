#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec python3 - "$ROOT" "$@" <<'PY'
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

root = Path(sys.argv[1])
only = set(sys.argv[2:])
tests = [
    "test_merge_contradiction_status",
    "test_merge_contradiction_inbox_and_ech",
    "test_merge_contradiction_drive_never_repairs",
    "test_merge_contradiction_web",
]
retire = "test_retire_archives_intact_lists_and_releases_only_its_claim"
duplicates = [
    "test_duplicate_bug_requires_explicit_decision",
    "test_open_siblings_are_candidates_without_matching_prose",
]

with tempfile.TemporaryDirectory(prefix="s376-mutants-") as temporary:
    tree = Path(temporary)
    for name in ("skills", "web"):
        shutil.copytree(root / name, tree / name,
                        ignore=shutil.ignore_patterns("__pycache__", "node_modules"))
    shutil.copytree(root / "tests/lib/shims", tree / "tests/lib/shims")
    env = dict(os.environ, LCARS_BOUNDARIES_ROOT=str(tree),
               LCARS_XO_DRIVE="0", LCARS_OWNER_ENFORCE="0", LCARS_VERSION_CHECK="0",
               LCARS_COMMENT_MIRROR="/dev/null")

    def replace_once(text, old, new):
        assert text.count(old) == 1, (old, text.count(old))
        return text.replace(old, new, 1)

    def remove_candidates(text):
        start = text.index("  local reviewed\n")
        end = text.index("  local id; id=", start)
        return text[:start] + '  local reviewed="[]"\n\n' + text[end:]

    def run_mutant(name, relative, mutate, selected, gate=False):
        if only and name not in only:
            return
        path = tree / relative
        original = path.read_text()
        changed = mutate(original)
        assert changed != original, name + " did not mutate anything"
        path.write_text(changed)
        try:
            if gate:
                gate_env = dict(env, LCARS_RUN_SCRIPT=str(path), LCARS_VERIFY_PR_FOCUS="gate")
                shims = tree / "tests/lib/shims/deploy-watcher"
                gate_env["PATH"] = str(shims) + os.pathsep + gate_env["PATH"]
                gate_env["LCARS_DRIVE_SHIM_LOG"] = str(tree / "workers.log")
                command = ["bash", str(root / "tests/lcars-verify-pr.test.sh")]
                result = subprocess.run(command, env=gate_env, stdin=subprocess.DEVNULL,
                                        capture_output=True, text=True, timeout=180)
                required = ["FAIL", "gate and notification name approve", "1 failed"]
                workers = tree / "workers.log"
                assert not workers.exists() or not workers.read_text(), "worker invoked"
            else:
                command = ["bash", str(root / "tests/mission-boundaries.test.sh")]
                command += ["Boundaries." + test for test in selected]
                result = subprocess.run(command, env=env, stdin=subprocess.DEVNULL,
                                        capture_output=True, text=True, timeout=240)
                required = ["FAIL: " + test for test in selected]
            output = result.stdout + result.stderr
            log_dir = os.environ.get("LCARS_MUTATION_LOG_DIR")
            if log_dir:
                Path(log_dir).mkdir(parents=True, exist_ok=True)
                (Path(log_dir) / (name + ".log")).write_text(output)
            if result.returncode != 1 or any(marker not in output for marker in required):
                print(output, file=sys.stderr)
                raise AssertionError(name + " survived or did not reach its assertions")
            print("CAUGHT %s: %s" % (name, ", ".join(selected) if not gate else "Verify gate"),
                  flush=True)
        finally:
            path.write_text(original)

    run_mutant("gate-loses-approve-verb", "skills/lcars-run/run.sh",
               lambda t: t.replace("approve with lcars approve $MISSION_ID",
                                   "review and merge by hand"), [], gate=True)
    run_mutant("detector-removed", "skills/lcars-status/merge-health.py",
               lambda t: replace_once(t, '    mid = state.get("id", "(unnamed Mission)")',
                                      '    return None\n    mid = state.get("id", "(unnamed Mission)")'),
               tests)
    run_mutant("missing-missions-treated-as-state-file", "skills/lcars-status/merge-health.py",
               lambda t: replace_once(
                   t, 'paths = [source] if source.name == "state.json" else sorted(source.glob("*/state.json"))',
                   'paths = sorted(source.glob("*/state.json")) if source.is_dir() else [source]'),
               ["test_empty_mission_set_has_no_merge_error"])
    run_mutant("card-warning-removed", "web/static/board.js",
               lambda t: replace_once(t, '    pills.appendChild(mergePill);',
                                      "    /* deliberately omit the card warning */"),
               [tests[3]])
    run_mutant("card-warning-becomes-paragraph", "web/static/board.js",
               lambda t: replace_once(t, '    pills.appendChild(mergePill);',
                                      '    card.appendChild(el("p", "det-stagefailure", m.mergeHealth.message));'),
               [tests[3]])
    run_mutant("detail-warning-removed", "web/static/board.js",
               lambda t: replace_once(t, '    head.appendChild(el("p", "det-stagefailure", mi.mergeHealth.message));',
                                      "    /* deliberately omit the detail warning */"),
               [tests[3]])
    run_mutant("sibling-check-removed", "skills/lcars-log/log.sh", remove_candidates, duplicates)
    run_mutant("closed-bugs-treated-as-open", "skills/lcars-log/log.sh",
               lambda t: replace_once(t, 'and state.get("stage") != "done"', "and True"),
               [duplicates[1]])
    run_mutant("other-parents-treated-as-siblings", "skills/lcars-log/log.sh",
               lambda t: replace_once(t, 'state.get("parentMission") == parent', "True"),
               [duplicates[1]])
    run_mutant("retire-deletes-instead-of-moving", "skills/lcars-eeh/ech.sh",
               lambda t: replace_once(t, '  mv "$source" "$dest" ||',
                                      '  rm -r "$source" ||'), [retire])
    run_mutant("retire-list-ignores-legacy", "skills/lcars-eeh/ech.sh",
               lambda t: replace_once(t, 'for name in ("archived-missions", "missions-archived"):',
                                      'for name in ("archived-missions",):'), [retire])
    run_mutant("retire-keeps-claim", "skills/lcars-eeh/ech.sh",
               lambda t: replace_once(t, '  lcars_chunk_forget "$LCARS_DIR" "$m" \\',
                                      '  true \\'), [retire])
    run_mutant("retire-loses-reason", "skills/lcars-eeh/ech.sh",
               lambda t: replace_once(t, 'json.dump({"reason": sys.argv[2],',
                                      'json.dump({"reason": "",'), [retire])
print("All selected deliberately broken variants were caught; source checkout unchanged.")
PY

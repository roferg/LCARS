#!/usr/bin/env python3
"""Read-only comparison of recorded Mission state with its PR's forge state."""
import argparse
import json
import os
from pathlib import Path
import subprocess


def check(state, cwd=None):
    mid = state.get("id", "(unnamed Mission)")
    pr = state.get("prUrl") or state.get("prNumber")
    if not pr or state.get("stage") == "done":
        return None
    try:
        result = subprocess.run(
            [os.environ.get("LCARS_GH_BIN", "gh"), "pr", "view", str(pr),
             "--json", "state,mergedAt"],
            cwd=cwd, stdin=subprocess.DEVNULL, capture_output=True, text=True,
            timeout=5, env=dict(os.environ, GH_PROMPT_DISABLED="1"))
        if result.returncode:
            raise ValueError(result.stderr.strip() or "forge query failed")
        remote = json.loads(result.stdout)
        if not isinstance(remote, dict) or "state" not in remote:
            raise ValueError("forge returned no PR state")
    except (OSError, ValueError, subprocess.TimeoutExpired) as error:
        return {"status": "unknown", "message":
                f"MERGE CHECK UNAVAILABLE: {mid}: {error}. "
                "Check forge access and run lcars status again."}
    if remote["state"] != "MERGED" and not remote.get("mergedAt"):
        return None
    return {"status": "bypass", "message":
            f"MERGE BYPASS: {mid}: PR {pr} is MERGED but the Mission record "
            f"still says stage={state.get('stage')}, review={state.get('review')}. "
            "STOP: inspect its logged bugs for stranded fixes and explicitly "
            "retire/re-file unfinished work; do not approve this merged PR again. "
            f"Future merges must start with lcars approve {mid} or the LCARS web UI. "
            "Record unchanged."}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--refuse-bypass", action="store_true")
    parser.add_argument("paths", nargs="*")
    args = parser.parse_args()
    findings = {}
    for path in args.paths:
        source = Path(path)
        paths = [source] if source.name == "state.json" else sorted(source.glob("*/state.json"))
        for state_path in paths:
            with state_path.open() as stream:
                state = json.load(stream)
            finding = check(state)
            if finding:
                findings[state.get("id", state_path.parent.name)] = finding
    if args.json:
        print(json.dumps(findings))
    else:
        for finding in findings.values():
            print(finding["message"])
    if args.refuse_bypass and any(f["status"] == "bypass" for f in findings.values()):
        raise SystemExit(1)


if __name__ == "__main__":
    main()

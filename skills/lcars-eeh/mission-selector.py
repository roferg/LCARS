#!/usr/bin/env python3
"""Resolve one Mission once; a gated target consumes the bound resolution."""
import json
import os
from pathlib import Path
import sys


def resolve(directory, policy, selector):
    if policy != "active":
        raise ValueError("unknown Mission resolution policy: " + policy)
    root = Path(directory).resolve()
    binding = {"directory": str(root), "policy": policy, "selector": selector}
    handoff = os.environ.get("LCARS_MISSION_RESOLUTION")
    if handoff:
        result = json.loads(handoff)
        if not isinstance(result, dict) or any(
            result.get(key) != value for key, value in binding.items()
        ):
            raise ValueError("Mission resolution does not match this target's selector")
        if not isinstance(result.get("id"), str) or not isinstance(result.get("mission"), dict):
            raise ValueError("invalid Mission resolution")
        return result
    if not selector:
        raise ValueError("no Mission selector — WILL NOT GUESS")
    matches = []
    needle = selector.removeprefix("#").lower()
    for path in sorted(root.glob("*/state.json")):
        mission = json.loads(path.read_text())
        if mission.get("stage") == "done":
            continue
        mid = mission.get("id") or path.parent.name
        issue = str(mission.get("githubIssue", ""))
        if not (needle in mid.lower()
                or needle in mission.get("title", "").lower()
                or selector.removeprefix("#") == issue):
            continue
        matches.append(dict(binding, id=path.parent.name, mission=mission))
    if not matches:
        raise ValueError('no active Mission matches "%s" — WILL NOT GUESS' % selector)
    if len(matches) > 1:
        raise ValueError('"%s" matches more than one active Mission — WILL NOT GUESS' % selector)
    return matches[0]


if __name__ == "__main__":
    try:
        print(json.dumps(resolve(*sys.argv[1:])))
    except (OSError, ValueError, TypeError) as error:
        print("lcars: Mission selector: " + str(error), file=sys.stderr)
        sys.exit(1)

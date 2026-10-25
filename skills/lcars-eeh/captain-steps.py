"""Read declared captain-step deadlines; never infer timing from step prose."""
import json
from pathlib import Path
import re
import sys


def scheduled_steps(state, steps, missions):
    if not isinstance(steps, list) or any(not isinstance(s, dict) for s in steps):
        raise ValueError("captainOnlySteps must be an array of step objects")
    for step in steps:
        deadline = step.get("neededBy", "")
        if not isinstance(deadline, str):
            raise ValueError("neededBy must be a string")
        match = re.fullmatch(r"(before|after) ([^\s]+)( drives| merges)?", deadline)
        if deadline and (not match or
                         (match[1] == "after" and match[3] != " merges") or
                         (match[1] == "before" and match[3] not in (None, " drives"))):
            raise ValueError("unsupported neededBy %r" % deadline)
        due = True
        if match:
            milestone = match[2]
            if milestone not in state.get("scope", []):
                raise ValueError("neededBy names milestone %r outside the run's scope" % milestone)
            if match[1] == "after":
                mid = (state.get("missions", {}).get(milestone) or {}).get("id")
                due = False
                if mid:
                    path = missions / mid / "state.json"
                    # An unfiled/missing mission has not recorded a merge.
                    if path.exists():
                        due = json.loads(path.read_text()).get("stage") == "done"
        yield step, due


def main():
    ledger, missions, mode, command = sys.argv[1:5]
    state = json.loads(Path(ledger).read_text())
    try:
        steps = json.loads(sys.argv[5]) if mode == "check" else state.get("captainOnlySteps", [])
        scheduled = list(scheduled_steps(state, steps, Path(missions)))
    except (ValueError, OSError) as error:
        message = (
            "%s. Run `%s record captainOnlySteps '<json-array>'` with neededBy "
            "`after M0 merges`, `before M0 drives` (or `before M0`), naming a "
            "milestone in scope; omit neededBy for an immediate step." % (error, command))
        if mode == "check":
            print("the ECH: " + message + " Nothing was recorded.", file=sys.stderr)
            return 1
        # Legacy records must not silently run early or disappear.
        print("Invalid captainOnlySteps record: " + message)
        return 0
    for step, due in scheduled:
        if step.get("done") or step.get("declined"):
            continue
        what = step.get("what") or "an unnamed captain-only step"
        if mode == "due" and due:
            print(what)
            break
        if mode == "status":
            print("    %s: %s%s" % (
                "due" if due else "deferred", what,
                " (%s)" % step["neededBy"] if step.get("neededBy") else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())

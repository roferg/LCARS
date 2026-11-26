"""Permit only S371's explicitly retired unsafe preflight wording."""
from pathlib import Path
import subprocess
import sys

repo, baseline = sys.argv[1:]
path = "skills/lcars-eeh/HOLOGRAM-COMMAND-MODE.md"
diff = subprocess.run(
    ["git", "--no-pager", "-c", "color.ui=false", "-C", repo,
     "diff", baseline, "--", path],
    check=True, capture_output=True, text=True,
).stdout
removed = [line for line in diff.splitlines()
           if line.startswith("-") and not line.startswith("---") and len(line) > 1]
retired = """-| 6 | Number One: RECOMMENDED **ON**, using the run's engine | PROCEEDS on the recommended default, ON; runs `xo on --engine <run-engine> --sweep` once and records the choice |
-No tty means proceed on ON without waiting for input; an explicit OFF is
-preserved too. The decision and its engine live in `autopilot.json.numberOne`;""".splitlines()
if removed != retired:
    print("Unexpected playbook removals in " + str(Path(repo) / path), file=sys.stderr)
    print("\n".join(removed), file=sys.stderr)
    sys.exit(1)
